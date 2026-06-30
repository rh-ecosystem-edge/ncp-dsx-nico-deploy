# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: docker-build-ubi docker-push-ubi helm-dep-build helm-lint helm-template
.PHONY: deploy-prereqs deploy-cloud-infra deploy-temporal deploy-cloud
.PHONY: deploy-site-infra deploy-site deploy-site-agent deploy-flow
.PHONY: deploy-all-cloud deploy-all-site status undeploy

# Upstream source repo (git submodule, read-only)
UPSTREAM ?= helm/vendor/infra-controller

# Upstream chart paths
NICO_REST_CHART := $(UPSTREAM)/rest-api/helm/charts/nico-rest
NICO_CORE_CHART := $(UPSTREAM)/helm
NICO_SITE_AGENT_CHART := $(UPSTREAM)/rest-api/helm/charts/nico-rest-site-agent
NICO_FLOW_CHART := $(UPSTREAM)/helm/charts/nico-flow

# Image configuration
IMAGE_REGISTRY ?= quay.io/fdupont-redhat
IMAGE_TAG ?= latest
DOCKERFILE_DIR := docker/ubi

# Cluster ingress domain (auto-detected from OpenShift)
CLUSTER_DOMAIN ?= $(shell oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

# Kustomize post-renderer for upstream chart patches
POST_RENDERER := helm/plugins/kustomize-post-renderer/render.sh
CLOUD_KUSTOMIZE := $(CURDIR)/helm/kustomize/nico-rest
SITE_KUSTOMIZE := $(CURDIR)/helm/kustomize/nico-core

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

# =============================================================================
# Helm Charts
# =============================================================================

helm-dep-build:
	git submodule update --init
	helm dependency build helm/infra-site/

helm-lint:
	helm lint helm/nvidia-infra-controller-prereqs/
	helm lint helm/infra-cloud/
	helm lint helm/infra-site/
	helm template nico-rest $(NICO_REST_CHART) -n nico-rest -f helm/values/nico-rest.yaml > /dev/null
	helm template nico-core $(NICO_CORE_CHART) -n nico-system -f helm/values/nico-core.yaml > /dev/null

helm-template:
	@echo "--- prereqs ---"
	helm template prereqs helm/nvidia-infra-controller-prereqs/
	@echo "--- infra-cloud ---"
	helm template infra-cloud helm/infra-cloud/ -n nico-rest
	@echo "--- temporal ---"
	helm template temporal $(NICO_REST_CHART)/../../../temporal-helm/temporal -n nico-rest \
		-f helm/values/temporal.yaml 2>/dev/null || \
		echo "(temporal chart not available locally — add repo with: helm repo add temporal https://go.temporal.io/helm-charts)"
	@echo "--- nico-rest (upstream) ---"
	helm template nico-rest $(NICO_REST_CHART) -n nico-rest \
		-f helm/values/nico-rest.yaml \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)
	@echo "--- infra-site ---"
	helm template infra-site helm/infra-site/ -n nico-system
	@echo "--- nico-core (upstream) ---"
	helm template nico-core $(NICO_CORE_CHART) -n nico-system \
		-f helm/values/nico-core.yaml \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)
	@echo "--- nico-rest-site-agent (upstream) ---"
	helm template site-agent $(NICO_SITE_AGENT_CHART) -n nico-system \
		-f helm/values/nico-rest-site-agent.yaml

# =============================================================================
# Deploy — Cloud Profile
# =============================================================================

deploy-prereqs:
	helm upgrade --install nvidia-infra-controller-prereqs \
		helm/nvidia-infra-controller-prereqs/ \
		--wait --timeout 15m

deploy-cloud-infra: helm-dep-build
	helm upgrade --install -n nico-rest nico-rest-infra \
		helm/infra-cloud/ \
		--create-namespace --wait --timeout 10m

deploy-temporal:
	helm repo add temporal https://go.temporal.io/helm-charts 2>/dev/null || true
	helm upgrade --install -n nico-rest temporal temporal/temporal \
		--version 1.2.0 --wait --timeout 10m \
		-f helm/values/temporal.yaml

deploy-cloud:
	helm upgrade --install -n nico-rest nico-rest \
		$(NICO_REST_CHART) --wait --timeout 10m \
		-f helm/values/nico-rest.yaml \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

deploy-all-cloud: deploy-prereqs deploy-cloud-infra deploy-temporal deploy-cloud

# =============================================================================
# Deploy — Site Profile
# =============================================================================

deploy-site-infra: helm-dep-build
	helm upgrade --install -n nico-system nico-site-infra \
		helm/infra-site/ \
		--create-namespace --wait --timeout 15m

deploy-site:
	helm upgrade --install -n nico-system nico-core \
		$(NICO_CORE_CHART) --wait --timeout 10m \
		-f helm/values/nico-core.yaml \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)

# Site configuration
SITE_NAME ?=
SITE_DESCRIPTION ?= Managed by Helm
KC_URL := https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN)
API_URL := https://nico-rest-api-nico-rest.$(CLUSTER_DOMAIN)

deploy-site-agent:
ifndef SITE_ID
ifndef SITE_NAME
	$(error Usage: make deploy-site-agent SITE_NAME=<name> or make deploy-site-agent SITE_ID=<existing-uuid>)
endif
endif
	@SITE_ID_VAL="$(SITE_ID)"; \
	if [ -z "$$SITE_ID_VAL" ]; then \
		echo "=== Acquiring service-account token ===" && \
		TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
			-d "grant_type=client_credentials" \
			-d "client_id=ncx-service" \
			-d "client_secret=$$(oc get secret keycloak-client-secret -n nico-rest -o jsonpath='{.data.keycloak-client-secret}' | base64 -d)" \
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
		oc create namespace nico-system 2>/dev/null || true && \
		CA_CERT=$$(oc get secret nico-root-ca-secret -n cert-manager \
			-o jsonpath='{.data.ca\.crt}' | base64 -d) && \
		oc delete secret site-registration -n nico-system 2>/dev/null || true && \
		oc create secret generic site-registration \
			-n nico-system \
			--from-literal=site-uuid="$$SITE_ID_VAL" \
			--from-literal=otp="$$OTP" \
			--from-literal=creds-url=https://nico-rest-site-manager.nico-rest:8100/v1/sitecreds \
			--from-literal=cacert="$$CA_CERT"; \
	fi && \
	echo "=== Deploying site-agent ===" && \
	helm upgrade --install -n nico-system nico-rest-site-agent \
		$(NICO_SITE_AGENT_CHART) --wait --timeout 5m \
		-f helm/values/nico-rest-site-agent.yaml \
		--set envConfig.CLUSTER_ID=$$SITE_ID_VAL \
		--set envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=$$SITE_ID_VAL \
		--set envConfig.TEMPORAL_SUBSCRIBE_QUEUE=$$SITE_ID_VAL \
		--set bootstrap.enabled=true

deploy-flow:
	helm upgrade --install -n nico-system nico-flow \
		$(NICO_FLOW_CHART) --wait --timeout 5m \
		-f helm/values/nico-core.yaml

deploy-all-site: deploy-site-infra deploy-site deploy-flow

# =============================================================================
# Status and Cleanup
# =============================================================================

status:
	@echo "=== Operators ===" && \
	echo "cert-manager:  $$(oc get pods -n cert-manager --no-headers 2>&1 | grep -c Running) running" && \
	echo "rhbk-operator: $$(oc get pods -n rhbk-operator --no-headers 2>&1 | grep -c Running) running" && \
	echo "pgo:           $$(oc get pods -n openshift-operators --no-headers 2>&1 | grep -c 'pgo.*Running') running" && \
	echo "" && \
	echo "=== Cloud (nico-rest) ===" && \
	oc get pods -n nico-rest --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Keycloak ===" && \
	oc get pods -n rhbk-operator --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Site (nico-system) ===" && \
	oc get pods -n nico-system --no-headers 2>/dev/null | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' || \
	echo "(not deployed)"

undeploy:
	helm uninstall -n nico-system nico-flow 2>/dev/null || true
	helm uninstall -n nico-system nico-rest-site-agent 2>/dev/null || true
	helm uninstall -n nico-system nico-core 2>/dev/null || true
	helm uninstall -n nico-system nico-site-infra 2>/dev/null || true
	oc delete namespace nico-system 2>/dev/null || true
	helm uninstall -n nico-rest nico-rest 2>/dev/null || true
	helm uninstall -n nico-rest temporal 2>/dev/null || true
	helm uninstall -n nico-rest nico-rest-infra 2>/dev/null || true
	oc delete namespace nico-rest 2>/dev/null || true
	oc delete namespace rhbk-operator 2>/dev/null || true
	helm uninstall nvidia-infra-controller-prereqs 2>/dev/null || true
