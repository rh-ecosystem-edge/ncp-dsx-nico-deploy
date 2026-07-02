# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: docker-build-ubi docker-push-ubi helm-dep-build helm-lint helm-template
.PHONY: deploy-prereqs deploy-cloud-infra deploy-cloud
.PHONY: deploy-site-infra vault-init deploy-site deploy-site-agent deploy-flow
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
POST_RENDERER_DIR := $(CURDIR)/helm/plugins/kustomize-post-renderer
POST_RENDERER := kustomize-post-renderer
export PATH := $(POST_RENDERER_DIR):$(PATH)
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

deploy-cloud:
	helm upgrade --install -n nico-rest nico-rest \
		$(NICO_REST_CHART) --wait --timeout 10m \
		-f helm/values/nico-rest.yaml \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

deploy-all-cloud: deploy-prereqs deploy-cloud-infra deploy-cloud

# =============================================================================
# Deploy — Site Profile
# =============================================================================

deploy-site-infra: helm-dep-build
	helm upgrade --install -n nico-system nico-site-infra \
		helm/infra-site/ \
		--create-namespace --timeout 15m

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
	echo "=== Configuring Vault ===" && \
	oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true && \
		vault secrets enable -path=secrets kv-v2 2>/dev/null || true && \
		vault kv put secrets/machines/all_dpus/factory_default/bmc-metadata-items/root UsernamePassword='{\"username\":\"root\",\"password\":\"0penBmc\"}' && \
		vault kv put secrets/machines/all_dpus/factory_default/uefi-metadata-items/auth UsernamePassword='{\"username\":\"\",\"password\":\"bluefield\"}' && \
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
		--create-namespace --wait --timeout 10m

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
