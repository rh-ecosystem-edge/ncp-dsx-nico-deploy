# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: check-prereqs
.PHONY: docker-build-ubi docker-push-ubi docker-build-core docker-push-core docker-build-nicocli docker-push-nicocli helm-dep-build helm-lint helm-template
.PHONY: build-machine-a-tron bootstrap-machine-a-tron machine-a-tron-status
.PHONY: deploy-prereqs deploy-cloud-infra deploy-cloud
.PHONY: deploy-site-infra vault-init ensure-ssh-host-key deploy-site deploy-site-agent deploy-flow
.PHONY: deploy-all-cloud patch-keycloak-route bootstrap-org deploy-all-site status undeploy
.PHONY: reset-dpu-endpoint

# Upstream source repo (git submodule, read-only)
UPSTREAM ?= helm/vendor/infra-controller

# Upstream chart paths
NICO_REST_CHART := $(UPSTREAM)/helm/rest/nico-rest
NICO_CORE_CHART := $(UPSTREAM)/helm
NICO_SITE_AGENT_CHART := $(UPSTREAM)/helm/rest/nico-rest-site-agent
NICO_FLOW_CHART := $(UPSTREAM)/helm/charts/nico-flow
NICO_TEMPORAL_CHART := $(UPSTREAM)/rest-api/temporal-helm/temporal

# Image configuration
IMAGE_REGISTRY ?= quay.io/fdupont-redhat
IMAGE_TAG ?= latest
DOCKERFILE_DIR := docker/ubi

# Namespace the machine-a-tron BuildConfig/ImageStream/Deployment live in.
MAT_NAMESPACE ?= nico-system

# machine-a-tron TEST overlay. Layers the RBAC/host-discovery bypass flags and
# emulator networks onto the site profile — TEST/DEV ONLY, never a real site.
# Opt in with `make deploy-site MAT=1` (see machine-a-tron-testing-guide.md).
# Off by default so `make deploy-site` cannot ship the bypass flags.
MAT_VALUES := helm/values/nico-core-mat.yaml
MAT ?=
MAT_VALUES_FLAG := $(if $(MAT),-f $(MAT_VALUES),)

# Site-config values layered onto nico-core.yaml. The base disables siteConfig
# (no pools) so `make deploy-site` never silently ships RBAC bypasses; Core
# exits without resource pools, so a real deploy MUST supply them. Default is
# the production overlay (pools/networks, no bypass); MAT=1 swaps to the
# machine-a-tron overlay, which carries its own pools + emulator bypass flags.
# Override with SITE_VALUES=<file> for a site-specific config.
SITE_VALUES ?= helm/values/nico-core-site.yaml
SITE_CONFIG_FLAG := $(if $(MAT),-f $(MAT_VALUES),-f $(SITE_VALUES))

# Vault topology auto-selection. HA (3-node Raft) needs >=3 schedulable nodes;
# a single-node (SNO/VM) or 2-node cluster falls back to standalone Vault (file
# storage) so the default `make deploy-all-site` works everywhere without a
# separate -crc variant. Detection runs `oc get nodes`; if oc is unreachable
# (count 0) it defaults to standalone, which deploys anywhere. Force explicitly
# with VAULT_MODE=ha or VAULT_MODE=standalone.
NODE_COUNT := $(shell oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
VAULT_MODE ?= $(if $(filter-out 0 1 2,$(NODE_COUNT)),ha,standalone)
# CRC_VAULT_OVERRIDES is defined further down; use recursive '=' so it resolves
# at recipe time regardless of definition order.
VAULT_OVERRIDES = $(if $(filter standalone,$(VAULT_MODE)),$(CRC_VAULT_OVERRIDES),)

# Cluster ingress domain (auto-detected from OpenShift)
CLUSTER_DOMAIN ?= $(shell oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

# Kustomize post-renderer for upstream chart patches
POST_RENDERER_DIR := $(CURDIR)/helm/plugins/kustomize-post-renderer
POST_RENDERER := kustomize-post-renderer
export PATH := $(POST_RENDERER_DIR):$(PATH)
CLOUD_KUSTOMIZE := $(CURDIR)/helm/kustomize/nico-rest
INFRA_CLOUD_KUSTOMIZE := $(CURDIR)/helm/kustomize/infra-cloud
SITE_KUSTOMIZE := $(CURDIR)/helm/kustomize/nico-core

# =============================================================================
# Secrets Management
# =============================================================================

# Generate Keycloak client secret once per make session
# Same secret used across all targets in a single make invocation
KEYCLOAK_CLIENT_SECRET := $(shell openssl rand -base64 32)

# =============================================================================
# Prerequisites
# =============================================================================

# Verifies local tools this Makefile shells out to, including the pyyaml
# module kustomize-post-renderer needs (missing it fails post-render with
# an error Helm swallows).
check-prereqs:
	@echo "=== Checking required tools ===" && \
	MISSING=0; \
	for bin in oc helm kustomize podman python3 git curl jq ssh-keygen; do \
		if command -v $$bin >/dev/null 2>&1; then \
			echo "  [OK]      $$bin ($$(command -v $$bin))"; \
		else \
			echo "  [MISSING] $$bin"; \
			MISSING=1; \
		fi; \
	done; \
	if python3 -c "import yaml" >/dev/null 2>&1; then \
		echo "  [OK]      python3 module: yaml (pyyaml)"; \
	else \
		echo "  [MISSING] python3 module: yaml (pyyaml)"; \
		echo "            install with: pip3 install --user --break-system-packages pyyaml"; \
		MISSING=1; \
	fi; \
	if oc whoami >/dev/null 2>&1; then \
		echo "  [OK]      oc is logged in to $$(oc whoami --show-server 2>/dev/null)"; \
		SC=$$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null); \
		if [ -n "$$SC" ]; then \
			echo "  [OK]      default StorageClass: $$SC"; \
		else \
			echo "  [MISSING] no default StorageClass — PG, Vault, NATS, and Temporal PVCs will fail"; \
			MISSING=1; \
		fi; \
	else \
		echo "  [MISSING] oc is not logged in to a cluster"; \
		echo "            (skipping default StorageClass check)"; \
		MISSING=1; \
	fi; \
	echo "" && \
	if [ $$MISSING -eq 1 ]; then \
		echo "One or more prerequisites are missing. See README.md Prerequisites section." && \
		exit 1; \
	else \
		echo "All prerequisites satisfied."; \
	fi

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

docker-build-nicocli:
	podman build --platform linux/amd64 \
		-t $(IMAGE_REGISTRY)/nicocli:$(IMAGE_TAG) \
		-f $(DOCKERFILE_DIR)/Dockerfile.nicocli $(UPSTREAM)/rest-api

docker-push-nicocli:
	podman push $(IMAGE_REGISTRY)/nicocli:$(IMAGE_TAG)

# nico-core/nico-admin-cli build on UBI and need a live RHEL subscription to
# `dnf install rust-toolset` mid-build (see Dockerfile.nico-core) — unlike the
# plain-Debian machine-a-tron image, there's no way around this. Provide your
# own RHSM org ID / activation key as plain files (never as --build-arg, which
# would bake them into image history); the Dockerfile mounts them as ephemeral
# BuildKit secrets that never touch a layer.
RHSM_ORG_FILE ?= /tmp/rhsm_org
RHSM_ACTIVATIONKEY_FILE ?= /tmp/rhsm_activationkey

docker-build-core:
	podman build \
		--secret id=rhsm_org,src=$(RHSM_ORG_FILE) \
		--secret id=rhsm_activationkey,src=$(RHSM_ACTIVATIONKEY_FILE) \
		-t $(IMAGE_REGISTRY)/nico-core:$(IMAGE_TAG) \
		-f $(DOCKERFILE_DIR)/Dockerfile.nico-core $(UPSTREAM)
	podman build \
		--secret id=rhsm_org,src=$(RHSM_ORG_FILE) \
		--secret id=rhsm_activationkey,src=$(RHSM_ACTIVATIONKEY_FILE) \
		-t $(IMAGE_REGISTRY)/nico-admin-cli:$(IMAGE_TAG) \
		-f $(DOCKERFILE_DIR)/Dockerfile.nico-admin-cli $(UPSTREAM)

docker-push-core:
	podman push $(IMAGE_REGISTRY)/nico-core:$(IMAGE_TAG)
	podman push $(IMAGE_REGISTRY)/nico-admin-cli:$(IMAGE_TAG)

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
# NOTE: --api-url replaced --carbide-api upstream (v2.2.0-pr); --carbide-api
# is gone entirely (--carbide-url is the closest surviving alias).
NICO_ADMIN_CLI := oc exec -n $(MAT_NAMESPACE) deploy/nico-api -- /opt/nico/nico-admin-cli \
	--api-url https://nico-api.$(MAT_NAMESPACE).svc.cluster.local:1079 \
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
	helm repo add temporal https://go.temporal.io/helm-charts 2>/dev/null || true
	helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
	helm repo add nats https://nats-io.github.io/k8s/helm/charts/ 2>/dev/null || true
	helm repo update >/dev/null
	helm dependency build helm/infra-cloud/
	helm dependency build helm/infra-site/

helm-lint: helm-dep-build
	helm lint helm/nvidia-infra-controller-prereqs/
	helm lint helm/infra-cloud/
	helm lint helm/infra-site/
	helm template nico-rest $(NICO_REST_CHART) -n nico-rest -f helm/values/nico-rest.yaml > /dev/null
	helm template nico-core $(NICO_CORE_CHART) -n nico-system -f helm/values/nico-core.yaml > /dev/null
	helm template nico-core $(NICO_CORE_CHART) -n nico-system -f helm/values/nico-core.yaml -f $(MAT_VALUES) > /dev/null

helm-template: helm-dep-build
	@echo "--- prereqs ---"
	helm template prereqs helm/nvidia-infra-controller-prereqs/
	@echo "--- infra-cloud ---"
	helm template infra-cloud helm/infra-cloud/ -n nico-rest \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(INFRA_CLOUD_KUSTOMIZE)
	@echo "--- temporal ---"
	helm template temporal $(NICO_TEMPORAL_CHART) -n nico-rest \
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
		-f helm/values/nico-core.yaml $(SITE_CONFIG_FLAG) \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)
	@echo "--- nico-rest-site-agent (upstream) ---"
	helm template site-agent $(NICO_SITE_AGENT_CHART) -n nico-system \
		-f helm/values/nico-rest-site-agent.yaml

# =============================================================================
# Deploy — Cloud Profile
# =============================================================================

deploy-prereqs:
	helm upgrade --install -n default nvidia-infra-controller-prereqs \
		helm/nvidia-infra-controller-prereqs/ \
		--wait --timeout 15m

deploy-cloud-infra: helm-dep-build
	helm upgrade --install -n nico-rest nico-rest-infra \
		helm/infra-cloud/ \
		--create-namespace --wait --timeout 10m \
		--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)" \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(INFRA_CLOUD_KUSTOMIZE)

deploy-cloud:
	helm upgrade --install -n nico-rest nico-rest \
		$(NICO_REST_CHART) --wait --timeout 10m \
		-f helm/values/nico-rest.yaml \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)" \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

# All-in-one cloud deployment - runs prereqs, infra, and app in sequence
# Inlined to ensure same secret is used for both helm commands
deploy-all-cloud: deploy-prereqs helm-dep-build
	@echo "=========================================="
	@echo "Deploying Cloud Infrastructure"
	@echo "=========================================="
	helm upgrade --install -n nico-rest nico-rest-infra \
		helm/infra-cloud/ \
		--create-namespace --wait --timeout 10m \
		--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)" \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(INFRA_CLOUD_KUSTOMIZE)
	@echo ""
	@echo "=========================================="
	@echo "Deploying Cloud Application"
	@echo "=========================================="
	helm upgrade --install -n nico-rest nico-rest \
		$(NICO_REST_CHART) --wait --timeout 10m \
		-f helm/values/nico-rest.yaml \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)" \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)
	@echo ""
	$(MAKE) patch-keycloak-route
	$(MAKE) bootstrap-org
	@echo "✅ Cloud deployment complete!"

patch-keycloak-route:
	@echo "=== Patching Keycloak route with CA certificate ==="
	@CA=$$(oc get secret nico-root-ca-secret -n cert-manager \
		-o jsonpath='{.data.tls\.crt}' | base64 -d) && \
	oc patch route keycloak -n rhbk-operator \
		--type merge -p "$$(jq -n --arg ca "$$CA" '{"spec":{"tls":{"destinationCACertificate":$$ca}}}')"
	@echo "=== Keycloak route patched ==="

bootstrap-org:
	@echo "=== Bootstrapping NICo organization ==="
	@API_URL="https://nico-rest-api-nico-rest.$(CLUSTER_DOMAIN)" && \
	KC_URL="https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN)" && \
	_ADMIN_USER=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
		-o jsonpath='{.data.username}' | base64 -d) && \
	_ADMIN_PASS=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
		-o jsonpath='{.data.password}' | base64 -d) && \
	_ADMIN_TOKEN=$$(curl -sk -X POST "$$KC_URL/realms/master/protocol/openid-connect/token" \
		-d grant_type=password -d client_id=admin-cli \
		-d "username=$$_ADMIN_USER" -d "password=$$_ADMIN_PASS" | jq -r .access_token) && \
	_CLIENT_UUID=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
		"$$KC_URL/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id') && \
	_CLIENT_SECRET=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
		"$$KC_URL/admin/realms/nico/clients/$$_CLIENT_UUID" | jq -r .secret) && \
	TOKEN=$$(curl -sk -X POST "$$KC_URL/realms/nico/protocol/openid-connect/token" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_id=ncx-service" \
		--data-urlencode "client_secret=$$_CLIENT_SECRET" \
		| jq -r .access_token) && \
	{ [ -n "$$API_URL" ] && [ -n "$$TOKEN" ] && [ "$$TOKEN" != null ] || \
		{ echo "ERROR: API_URL or TOKEN not set"; exit 1; }; } && \
	curl -sk -H "Authorization: Bearer $$TOKEN" \
		"$$API_URL/v2/org/ncx/nico/infrastructure-provider/current" | jq . && \
	curl -sk -H "Authorization: Bearer $$TOKEN" \
		"$$API_URL/v2/org/ncx/nico/tenant/current" | jq .
	@echo "=== Organization bootstrapped ==="

# =============================================================================
# Deploy — Site Profile
# =============================================================================

deploy-site-infra: helm-dep-build
	@echo "=== Vault topology: $(VAULT_MODE) (detected $(NODE_COUNT) node(s)) ==="
	helm upgrade --install -n nico-system nico-site-infra \
		helm/infra-site/ \
		--create-namespace --timeout 15m \
		$(VAULT_OVERRIDES)

vault-init:
	@echo "=== Initializing Vault (one-time) ===" && \
	NS=nico-system && \
	V=vault-0 && \
	echo "Waiting for Vault pod..." && \
	until oc get pod $$V -n $$NS -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do sleep 5; done && \
	if oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"initialized".*true'; then \
		echo "Vault already initialized" && \
		if oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*true'; then \
			echo "Unsealing..." && \
			UK=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.unseal-key}' | base64 -d) && \
			oc exec $$V -n $$NS -- vault operator unseal -tls-skip-verify "$$UK"; \
		fi && \
		RT=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.root-token}' | base64 -d); \
	else \
		echo "Initializing Vault..." && \
		INIT=$$(oc exec $$V -n $$NS -- vault operator init -tls-skip-verify -key-shares=1 -key-threshold=1 -format=json) && \
		UK=$$(echo "$$INIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['unseal_keys_b64'][0])") && \
		RT=$$(echo "$$INIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])") && \
		echo "Unsealing..." && \
		oc exec $$V -n $$NS -- vault operator unseal -tls-skip-verify "$$UK" && \
		oc create secret generic vault-unseal-secret -n $$NS \
			--from-literal=unseal-key="$$UK" --from-literal=root-token="$$RT" --from-literal=token="$$RT" \
			--dry-run=client -o yaml | oc apply -f - && \
		echo "Restarting Vault for postStart auto-unseal..." && \
		oc delete pod $$V -n $$NS && sleep 10 && \
		until oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*false'; do sleep 5; done; \
	fi && \
	echo "Ensuring all Vault Raft replicas are unsealed..." && \
	UK=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.unseal-key}' | base64 -d) && \
	for pod in $$(oc get pods -n $$NS -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].metadata.name}'); do \
		if oc exec $$pod -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*true'; then \
			echo "Unsealing $$pod (postStart only auto-unseals on pod (re)start, and only $$V is restarted above)..." && \
			oc exec $$pod -n $$NS -- vault operator unseal -tls-skip-verify "$$UK" >/dev/null; \
		fi; \
	done && \
	echo "=== Configuring Vault ===" && \
	oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true && \
		vault secrets enable -path=secrets kv-v2 2>/dev/null || true && \
		printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"0penBmc\"}}' | vault kv put secrets/machines/all_dpus/factory_default/bmc-metadata-items/root - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_dpus/factory_default/uefi-metadata-items/auth - && \
		printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"0penBmc\"}}' | vault kv put secrets/machines/bmc/site/root - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_dpus/site_default/uefi-metadata-items/auth - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_hosts/site_default/uefi-metadata-items/auth - && \
		vault secrets enable -path=nicoca pki 2>/dev/null || true && \
		vault secrets tune -max-lease-ttl=87600h nicoca" && \
	echo "Importing CA into Vault PKI..." && \
	CA_CERT=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d) && \
	CA_KEY=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.key}' | base64 -d) && \
	echo "$$CA_CERT" > /tmp/vault-ca-bundle.pem && echo "$$CA_KEY" >> /tmp/vault-ca-bundle.pem && \
	oc cp /tmp/vault-ca-bundle.pem $$NS/$$V:/tmp/ca-bundle.pem -c vault && rm /tmp/vault-ca-bundle.pem && \
	oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true && \
		vault write nicoca/config/ca pem_bundle=@/tmp/ca-bundle.pem && \
		vault write nicoca/roles/nico-cluster allow_any_name=true allowed_uri_sans='spiffe://*' max_ttl=720h ttl=720h key_type=ec key_bits=256 require_cn=false use_csr_common_name=true && \
		vault auth enable kubernetes 2>/dev/null || true && \
		vault write auth/kubernetes/config kubernetes_host=https://\$$KUBERNETES_SERVICE_HOST:\$$KUBERNETES_SERVICE_PORT && \
		echo 'path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\", \"update\"] }' | vault policy write cert-manager-nico-policy - && \
		vault write auth/kubernetes/role/cert-manager-nico-issuer bound_service_account_names=cert-manager-vault-nicoca-issuer bound_service_account_namespaces=cert-manager policies=cert-manager-nico-policy ttl=1h && \
		echo 'path \"nicoca*\" { capabilities = [\"read\", \"list\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\", \"update\"] } path \"nicoca/issue/nico-cluster\" { capabilities = [\"create\", \"update\"] } path \"secrets/data/*\" { capabilities = [\"read\", \"list\"] } path \"secrets/data/machines*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/machines/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/metadata/machines/*\" { capabilities = [\"delete\"] } path \"secrets/destroy/machines/*\" { capabilities = [\"delete\"] } path \"secrets/data/ufm/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/nmxm/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/bgp/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] }' | vault policy write nico-vault-policy - && \
		vault write auth/kubernetes/role/nico-api bound_service_account_names=nico-api bound_service_account_namespaces=nico-system policies=nico-vault-policy ttl=1h && \
		vault auth enable approle 2>/dev/null || true && \
		vault write auth/approle/role/nico token_policies=nico-vault-policy token_ttl=1h token_max_ttl=4h" && \
	echo "Creating AppRole credentials..." && \
	ROLE_ID=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; vault read -field=role_id auth/approle/role/nico/role-id") && \
	SECRET_ID=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; vault write -f -field=secret_id auth/approle/role/nico/secret-id") && \
	oc patch secret nico-vault-approle-tokens -n $$NS --type=merge \
		-p "{\"stringData\":{\"VAULT_ROLE_ID\":\"$$ROLE_ID\",\"VAULT_SECRET_ID\":\"$$SECRET_ID\"}}" && \
	echo "Creating Flow PSM/NSM tokens..." && \
	PSM_TOKEN=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; \
		echo 'path \"secrets/data/psm/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] } path \"secrets/metadata/psm/*\" { capabilities = [\"read\",\"list\",\"delete\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\",\"update\"] }' | vault policy write psm-vault-policy - >/dev/null && \
		vault token create -orphan -policy=psm-vault-policy -period=24h -field=token") && \
	NSM_TOKEN=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; \
		echo 'path \"secrets/data/nsm/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] } path \"secrets/metadata/nsm/*\" { capabilities = [\"read\",\"list\",\"delete\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\",\"update\"] }' | vault policy write nsm-vault-policy - >/dev/null && \
		vault token create -orphan -policy=nsm-vault-policy -period=24h -field=token") && \
	oc create secret generic psm-vault-token -n $$NS --from-literal=token="$$PSM_TOKEN" --dry-run=client -o yaml | oc apply -f - && \
	oc create secret generic nsm-vault-token -n $$NS --from-literal=token="$$NSM_TOKEN" --dry-run=client -o yaml | oc apply -f - && \
	echo "Creating cert-manager Vault SA..." && \
	oc create sa cert-manager-vault-nicoca-issuer -n cert-manager --dry-run=client -o yaml | oc apply -f - && \
	echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"vault-nicoca-issuer-token","namespace":"cert-manager","annotations":{"kubernetes.io/service-account.name":"cert-manager-vault-nicoca-issuer"}},"type":"kubernetes.io/service-account-token"}' | oc apply -f - && \
	echo "Creating vault-nico-issuer ClusterIssuer..." && \
	CA_B64=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}') && \
	echo "{\"apiVersion\":\"cert-manager.io/v1\",\"kind\":\"ClusterIssuer\",\"metadata\":{\"name\":\"vault-nico-issuer\"},\"spec\":{\"vault\":{\"path\":\"nicoca/sign/nico-cluster\",\"server\":\"https://vault.nico-system.svc:8200\",\"caBundle\":\"$$CA_B64\",\"auth\":{\"kubernetes\":{\"role\":\"cert-manager-nico-issuer\",\"mountPath\":\"/v1/auth/kubernetes\",\"secretRef\":{\"name\":\"vault-nicoca-issuer-token\",\"key\":\"token\"}}}}}}" | oc apply -f - && \
	echo "=== Vault fully configured ==="

# nico-ssh-console-rs expects a pre-existing `ssh-host-key` Secret that no
# chart in this repo creates.
ensure-ssh-host-key:
	@oc get secret ssh-host-key -n nico-system >/dev/null 2>&1 || ( \
		TMPDIR=$$(mktemp -d) && \
		trap "rm -rf $$TMPDIR" EXIT && \
		ssh-keygen -t ed25519 -N "" -f "$$TMPDIR/ssh_host_ed25519_key" -q && \
		oc create namespace nico-system --dry-run=client -o yaml | oc apply -f - && \
		oc create secret generic ssh-host-key -n nico-system \
			--from-file=ssh_host_ed25519_key="$$TMPDIR/ssh_host_ed25519_key" \
			--from-file=ssh_host_ed25519_key_pub="$$TMPDIR/ssh_host_ed25519_key.pub" \
	)

deploy-site: ensure-ssh-host-key
	helm upgrade --install -n nico-system nico-core \
		$(NICO_CORE_CHART) --wait --timeout 10m \
		-f helm/values/nico-core.yaml $(SITE_CONFIG_FLAG) \
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
		_ADMIN_USER=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
			-o jsonpath='{.data.username}' | base64 -d) && \
		_ADMIN_PASS=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
			-o jsonpath='{.data.password}' | base64 -d) && \
		_ADMIN_TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/master/protocol/openid-connect/token" \
			-d grant_type=password -d client_id=admin-cli \
			-d "username=$$_ADMIN_USER" -d "password=$$_ADMIN_PASS" | jq -r .access_token) && \
		_CLIENT_UUID=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
			"$(KC_URL)/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id') && \
		_CLIENT_SECRET=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
			"$(KC_URL)/admin/realms/nico/clients/$$_CLIENT_UUID" | jq -r .secret) && \
		TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
			--data-urlencode "grant_type=client_credentials" \
			--data-urlencode "client_id=ncx-service" \
			--data-urlencode "client_secret=$$_CLIENT_SECRET" \
			| jq -r .access_token) && \
		{ [ -n "$$TOKEN" ] && [ "$$TOKEN" != null ] || { echo "ERROR: failed to acquire token"; exit 1; }; } && \
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
		--set bootstrap.enabled=true

deploy-flow:
	helm upgrade --install -n nico-system nico-flow \
		$(NICO_FLOW_CHART) --wait --timeout 5m \
		-f helm/values/nico-core.yaml $(MAT_VALUES_FLAG)

deploy-all-site: deploy-site-infra vault-init deploy-site deploy-flow

# =============================================================================
# CRC (single-node) — overrides for local development on CodeReady Containers
# =============================================================================

CRC_VAULT_OVERRIDES := --set vault.server.ha.enabled=false \
	--set vault.server.standalone.enabled=true \
	--set-string 'vault.server.standalone.config=listener "tcp" { address = "[::]:8200"\n tls_cert_file = "/vault/userconfig/vault-tls/tls.crt"\n tls_key_file = "/vault/userconfig/vault-tls/tls.key"\n tls_client_ca_file = "/vault/userconfig/vault-tls/ca.crt"\n}\nstorage "file" { path = "/vault/data" }\ndisable_mlock = true'

deploy-cloud-infra-crc: helm-dep-build
	helm upgrade --install -n nico-rest nico-rest-infra \
		helm/infra-cloud/ \
		--create-namespace --wait --timeout 10m \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(INFRA_CLOUD_KUSTOMIZE)

deploy-site-infra-crc: helm-dep-build
	helm upgrade --install -n nico-system nico-site-infra \
		helm/infra-site/ \
		--create-namespace --wait --timeout 15m \
		$(CRC_VAULT_OVERRIDES)

deploy-all-cloud-crc: deploy-prereqs deploy-cloud-infra-crc deploy-cloud
deploy-all-site-crc: deploy-site-infra-crc vault-init deploy-site deploy-flow

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

## reset-dpu-endpoint BMC_IP=<ip> — Re-trigger preingestion for a static-IP DPU whose
## preingestion_state is stuck at "complete" but has no machine record (e.g. after a
## site-pg crash). Resets the forge explored_endpoint back to initial state so
## site-explorer runs the full preingestion cycle again.
reset-dpu-endpoint:
	@[ -n "$(BMC_IP)" ] || { echo "Usage: make reset-dpu-endpoint BMC_IP=<ip>"; exit 1; }
	$(eval _SITE_PG_POD := $(shell oc get pods -n nico-system \
	  -l postgres-operator.crunchydata.com/role=master \
	  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1))
	$(eval _NICO_PASS := $(shell oc get secret nico-site-pg-pguser-nico -n nico-system \
	  -o jsonpath='{.data.password}' | base64 -d))
	@echo "Resetting preingestion state for $(BMC_IP) on pod $(_SITE_PG_POD)..."
	oc exec $(_SITE_PG_POD) -n nico-system -c database -- \
	  env PGPASSWORD="$(_NICO_PASS)" psql -U nico -d nico -h 127.0.0.1 -c \
	  "UPDATE explored_endpoints \
	   SET preingestion_state = '{\"state\": \"initial\"}'::jsonb, \
	       exploration_requested = true \
	   WHERE address = '$(BMC_IP)';" 2>&1
	@echo "Done — site-explorer will re-run preingestion for $(BMC_IP) within ~2 minutes."

undeploy:
	bash cleanup.sh
