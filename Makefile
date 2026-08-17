# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: docker-build-ubi docker-push-ubi helm-dep-build helm-lint helm-template
.PHONY: build-machine-a-tron bootstrap-machine-a-tron machine-a-tron-status
.PHONY: deploy-prereqs deploy-cloud deploy-site status undeploy

# Upstream source repo (for building images)
UPSTREAM ?= helm/vendor/infra-controller

# Image configuration
IMAGE_REGISTRY ?= quay.io/fdupont-redhat
IMAGE_TAG ?= latest
DOCKERFILE_DIR := docker/ubi

# Namespace the machine-a-tron BuildConfig/ImageStream/Deployment live in.
MAT_NAMESPACE ?= nvidia-infra-controller-site

# Cluster ingress domain (auto-detected from OpenShift)
CLUSTER_DOMAIN ?= $(shell oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

# Post-renderer for Kustomize patches
POST_RENDERER := kustomize-post-renderer
CLOUD_KUSTOMIZE := $(CURDIR)/helm/nvidia-infra-controller-cloud/kustomize
SITE_KUSTOMIZE := $(CURDIR)/helm/nvidia-infra-controller-site/kustomize

# =============================================================================
# Container Images
# =============================================================================

docker-build-ubi:
	@for img in nico-rest-api nico-rest-workflow nico-rest-site-manager nico-rest-site-agent \
		nico-rest-db nico-rest-cert-manager nico-flow nico-psm nico-nsm; do \
		echo "Building $$img..." && \
		podman build -t $(IMAGE_REGISTRY)/$$img:$(IMAGE_TAG) \
			-f $(DOCKERFILE_DIR)/Dockerfile.$$img $(UPSTREAM)/rest-api; \
	done

docker-build-core:
	podman build -t $(IMAGE_REGISTRY)/nico-core:$(IMAGE_TAG) \
		-f $(DOCKERFILE_DIR)/Dockerfile.nico-core $(UPSTREAM)
	podman build -t $(IMAGE_REGISTRY)/nico-admin-cli:$(IMAGE_TAG) \
		-f $(DOCKERFILE_DIR)/Dockerfile.nico-admin-cli $(UPSTREAM)

docker-push-ubi:
	@for img in nico-rest-api nico-rest-workflow nico-rest-site-manager nico-rest-site-agent \
		nico-rest-db nico-rest-cert-manager nico-flow nico-psm nico-nsm; do \
		echo "Pushing $$img..." && \
		podman push $(IMAGE_REGISTRY)/$$img:$(IMAGE_TAG); \
	done

# machine-a-tron is dev/test tooling only, built as an amd64 Linux binary.
# Cross-arch podman/qemu emulation on Apple Silicon is unreliable for Rust
# builds, so this builds in-cluster via an OpenShift Build on a real amd64
# node and pushes straight to the internal registry (no external registry
# needed). The Dockerfile is copied into the submodule only for the duration
# of the upload, since oc's binary Docker strategy requires it inside the
# build context.
build-machine-a-tron:
	oc get bc machine-a-tron -n $(MAT_NAMESPACE) >/dev/null 2>&1 || \
		oc new-build --binary --strategy=docker --name=machine-a-tron -n $(MAT_NAMESPACE)
	cp docker/testing/Dockerfile.machine-a-tron $(UPSTREAM)/Dockerfile
	oc start-build machine-a-tron -n $(MAT_NAMESPACE) --from-dir=$(UPSTREAM) --wait; \
		rc=$$?; rm -f $(UPSTREAM)/Dockerfile; exit $$rc

# `nico-admin-cli` bundled in the nico-api pod, using its own mounted mTLS
# client certs. Its default target (carbide-api.forge-system) doesn't exist
# here, so the connection flags are mandatory. See machine-a-tron-testing-guide.md.
NICO_ADMIN_CLI := oc exec -n $(MAT_NAMESPACE) deploy/nico-api -- /opt/nico/nico-admin-cli \
	--carbide-api https://nico-api.$(MAT_NAMESPACE).svc.cluster.local:1079 \
	--client-cert-path /run/secrets/spiffe.io/tls.crt \
	--client-key-path /run/secrets/spiffe.io/tls.key \
	--forge-root-ca-path /run/secrets/spiffe.io/ca.crt

# Bootstraps the BMC/UEFI credentials machine-a-tron's bmc-mock validates
# against (crates/bmc-mock/src/lib.rs). Idempotent: safe to re-run, existing
# credentials just fail with "already exists" (ignored).
bootstrap-machine-a-tron:
	oc rollout status deployment/nico-api -n $(MAT_NAMESPACE) --timeout=5m
	$(NICO_ADMIN_CLI) credential add-bmc --kind=site-wide-root --username root --password 'SiteR00t-P@ssw0rd' || true
	$(NICO_ADMIN_CLI) credential add-host-factory-default --vendor dell --username root --password factory_password || true
	$(NICO_ADMIN_CLI) credential add-dpu-factory-default --username root --password 0penBmc || true
	$(NICO_ADMIN_CLI) credential add-uefi --kind=dpu --password=mock-uefi-password || true
	$(NICO_ADMIN_CLI) credential add-uefi --kind=host --password=mock-uefi-password || true

# Managed hosts + state, straight from Core gRPC. Empty rows are normal
# until machine-a-tron's DHCP/discovery cycle catches up (a few minutes).
machine-a-tron-status:
	$(NICO_ADMIN_CLI) managed-host show

# =============================================================================
# Helm Charts
# =============================================================================

helm-dep-build:
	git submodule update --init
	helm dependency build helm/nvidia-infra-controller-cloud/
	helm dependency build helm/nvidia-infra-controller-site/

helm-lint: helm-dep-build
	helm lint helm/nvidia-infra-controller-prereqs/
	helm lint helm/nvidia-infra-controller-cloud/
	helm lint helm/nvidia-infra-controller-site/

helm-template: helm-dep-build
	@echo "--- nvidia-infra-controller-prereqs ---"
	helm template nvidia-infra-controller-prereqs helm/nvidia-infra-controller-prereqs/
	@echo "--- nvidia-infra-controller-cloud ---"
	helm template nvidia-infra-controller-cloud helm/nvidia-infra-controller-cloud/ \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)
	@echo "--- nvidia-infra-controller-site ---"
	helm template nvidia-infra-controller-site helm/nvidia-infra-controller-site/ \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)

# =============================================================================
# Deploy (works on OpenShift/CRC and Kind with OLM)
# =============================================================================

deploy-prereqs:
	helm upgrade --install nvidia-infra-controller-prereqs \
		helm/nvidia-infra-controller-prereqs/ \
		--wait --timeout 15m

deploy-cloud: helm-dep-build
	helm upgrade --install -n nvidia-infra-controller-cloud nvidia-infra-controller-cloud \
		helm/nvidia-infra-controller-cloud/ \
		--create-namespace --wait --timeout 15m \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

# Site configuration
SITE_NAME ?=
SITE_DESCRIPTION ?= Managed by Helm
KC_URL := https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN)
API_URL := https://nico-rest-api-nvidia-infra-controller-cloud.$(CLUSTER_DOMAIN)

deploy-site: helm-dep-build
ifndef SITE_ID
ifndef SITE_NAME
	$(error Usage: make deploy-site SITE_NAME=<name> or make deploy-site SITE_ID=<existing-uuid>)
endif
endif
	@SITE_ID_VAL="$(SITE_ID)"; \
	if [ -z "$$SITE_ID_VAL" ]; then \
		echo "=== Acquiring service-account token ===" && \
		TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
			-d "grant_type=client_credentials" \
			-d "client_id=ncx-service" \
			-d "client_secret=nico-local-secret" \
			| python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])") && \
		echo "=== Bootstrapping org ===" && \
		curl -sk -H "Authorization: Bearer $$TOKEN" \
			"$(API_URL)/v2/org/ncx/nico/service-account/current" > /dev/null && \
		echo "=== Creating site: $(SITE_NAME) ===" && \
		SITE_JSON=$$(curl -sk -X POST -H "Authorization: Bearer $$TOKEN" \
			-H "Content-Type: application/json" \
			-d '{"name":"$(SITE_NAME)","description":"$(SITE_DESCRIPTION)"}' \
			"$(API_URL)/v2/org/ncx/nico/site") && \
		SITE_ID_VAL=$$(echo "$$SITE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") && \
		OTP=$$(echo "$$SITE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['registrationToken'])") && \
		echo "Site ID: $$SITE_ID_VAL" && \
		echo "=== Creating namespace and bootstrap secret ===" && \
		oc create namespace nvidia-infra-controller-site 2>/dev/null || true && \
		CA_CERT=$$(oc get secret nico-root-ca-secret -n cert-manager \
			-o jsonpath='{.data.ca\.crt}' | base64 -d) && \
		oc delete secret site-registration -n nvidia-infra-controller-site 2>/dev/null || true && \
		oc create secret generic site-registration \
			-n nvidia-infra-controller-site \
			--from-literal=site-uuid="$$SITE_ID_VAL" \
			--from-literal=otp="$$OTP" \
			--from-literal=creds-url=https://nico-rest-site-manager.nvidia-infra-controller-cloud:8100/v1/sitecreds \
			--from-literal=cacert="$$CA_CERT"; \
	fi && \
	echo "=== Deploying site profile ===" && \
	helm upgrade --install -n nvidia-infra-controller-site nvidia-infra-controller-site \
		helm/nvidia-infra-controller-site/ \
		--create-namespace --timeout 15m \
		--set nico-rest-site-agent.envConfig.CLUSTER_ID=$$SITE_ID_VAL \
		--set nico-rest-site-agent.envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=$$SITE_ID_VAL \
		--set nico-rest-site-agent.envConfig.TEMPORAL_SUBSCRIBE_QUEUE=$$SITE_ID_VAL \
		--set nico-rest-site-agent.bootstrap.enabled=true \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)

# =============================================================================
# Full deployment and status
# =============================================================================

status:
	@echo "=== Operators ===" && \
	echo "cert-manager:  $$(oc get pods -n cert-manager --no-headers 2>&1 | grep -c Running) running" && \
	echo "rhbk-operator: $$(oc get pods -n rhbk-operator --no-headers 2>&1 | grep -c Running) running" && \
	echo "pgo:           $$(oc get pods -n openshift-operators --no-headers 2>&1 | grep -c 'pgo.*Running') running" && \
	echo "" && \
	echo "=== Cloud ===" && \
	oc get pods -n nvidia-infra-controller-cloud --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Keycloak ===" && \
	oc get pods -n rhbk-operator --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Site ===" && \
	oc get pods -n nvidia-infra-controller-site --no-headers 2>/dev/null | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' || \
	echo "(not deployed)"

undeploy:
	helm uninstall -n nvidia-infra-controller-site nvidia-infra-controller-site 2>/dev/null || true
	oc delete namespace nvidia-infra-controller-site 2>/dev/null || true
	helm uninstall -n nvidia-infra-controller-cloud nvidia-infra-controller-cloud 2>/dev/null || true
	oc delete namespace nvidia-infra-controller-cloud 2>/dev/null || true
	oc delete namespace rhbk-operator 2>/dev/null || true
	helm uninstall nvidia-infra-controller-prereqs 2>/dev/null || true
