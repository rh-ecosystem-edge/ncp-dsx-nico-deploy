# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

.PHONY: docker-build-ubi docker-push-ubi helm-dep-build helm-lint helm-template
.PHONY: deploy-prereqs deploy-cloud deploy-site

# Upstream source repo (for building images)
UPSTREAM ?= helm/vendor/infra-controller

# Image configuration
IMAGE_REGISTRY ?= quay.io/fdupont-redhat
IMAGE_TAG ?= latest
DOCKERFILE_DIR := docker/ubi

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

deploy-site: helm-dep-build
ifndef SITE_ID
	$(error SITE_ID is required. Usage: make deploy-site SITE_ID=<uuid>)
endif
	helm upgrade --install -n nvidia-infra-controller-site nvidia-infra-controller-site \
		helm/nvidia-infra-controller-site/ \
		--timeout 15m \
		--set nico-rest-site-agent.envConfig.CLUSTER_ID=$(SITE_ID) \
		--set nico-rest-site-agent.envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=$(SITE_ID) \
		--set nico-rest-site-agent.envConfig.TEMPORAL_SUBSCRIBE_QUEUE=$(SITE_ID) \
		--set nico-rest-site-agent.bootstrap.enabled=true \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)

# Full deployment sequence:
#   1. make deploy-prereqs                  (operators + ClusterIssuers)
#   2. make deploy-cloud                    (management plane + Temporal + Keycloak)
#   3. Create site via REST API, retrieve site UUID + OTP
#   4. Create namespace + bootstrap secret  (see README.md)
#   5. make deploy-site SITE_ID=<uuid>      (Core + site-agent with bootstrap)
