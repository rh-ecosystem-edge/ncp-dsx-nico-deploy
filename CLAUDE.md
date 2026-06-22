# ncp-dsx-nico-deploy — AI Assistant Guide

## What This Is

Red Hat deployment artifacts for NVIDIA NICo (Infra Controller), part of the
DSX OS platform, targeting NVIDIA Cloud Partners (NCP). This repo does NOT
fork upstream — it builds UBI-based container images from upstream source and
provides Helm charts with Red Hat-preferred components (SPIFFE, CloudNativePG,
RHBK).

## Upstream Repos (read-only, never modified)

| Repo | What we consume |
|---|---|
| `github.com/NVIDIA/infra-controller` | Go/Rust source (monorepo: REST API, site-agent, Core) |

Local clones expected at:
- `~/Code/github.com/NVIDIA/infra-controller`
- `~/Code/github.com/NVIDIA/ncx-infra-controller-core`

## Related Repos (we own)

| Repo | Purpose |
|---|---|
| `fabiendupont/nvidia-ncx-infra-controller-operator` | Kubernetes operator (alternative deployment path, same images) |
| `fabiendupont/nvidia-ncx-infra-controller-ui` | NCP Portal UI (React/PatternFly) |

## Architecture

### Deployment Topology

NICo separates into two profiles deployed in separate namespaces (matching
production where they run on different clusters):

```
nvidia-infra-controller-cloud namespace (management plane)
├── nico-rest-api
├── nico-rest-cloud-worker (cloud Temporal queue)
├── nico-rest-site-worker  (per-site Temporal queues)
├── nico-rest-site-manager
├── nico-rest-cert-manager (credsmgr — issues site-agent Temporal certs)
├── nico-rest-db (migration job)
├── Temporal server (official chart v1.2.0, Temporal 1.31.0)
├── temporal-pg (Crunchy PostgreSQL)
└── nico-cloud-pg (Crunchy PostgreSQL — NICo REST data)

rhbk-operator namespace (Keycloak)
├── Keycloak (RHBK operator CRD, TLS via cert-manager)
├── keycloak-pg (Crunchy PostgreSQL)
└── KeycloakRealmImport (nico-dev realm with OIDC client)

nvidia-infra-controller-site namespace (per-site, edge)
├── nico-rest-site-agent → connects to cloud's Temporal via OTP certs
├── nico-core (bare metal management: carbide-api, DHCP, PXE, DNS)
├── nico-site-core-pg (Crunchy PostgreSQL — Core data only)
└── Vault (HashiCorp, standalone — BMC credential storage)
```

The cloud profile hosts the single Temporal instance. Per-site Temporal
namespaces (named by site UUID) are created dynamically by the REST API
at site registration. Site-agents bootstrap with an OTP to get mTLS certs
for connecting to cloud's Temporal. Operators (cert-manager, CNPG, RHBK)
are installed as pre-install hooks with `enabled` flags for single-cluster
dev deployments.

### TLS Modes

Two mutually exclusive TLS backends:

- **SPIFFE** (recommended): SPIRE issues short-lived SVIDs, auto-rotated.
  spiffe-helper sidecar in every pod. `nico-rest-cert-manager` disabled.
  On OpenShift: Zero Trust Workload Identity Manager operator.
  On Kind/vanilla K8s: community SPIRE Helm chart.

- **certManager**: cert-manager issues certificates from a ClusterIssuer.
  `nico-rest-cert-manager` (credsmgr) manages internal CA.
  Temporal uses separate certs per virtual host.

### Prerequisites (installed by prereqs chart)

| Component | OLM mode (OpenShift) | Cloud | Site |
|---|---|---|---|
| cert-manager | `redhat-operators` | yes | yes |
| Crunchy PostgreSQL | `certified-operators` | yes | yes |
| RHBK (Keycloak) | `redhat-operators` | yes | no |

## Directory Structure

```
docker/ubi/                          UBI-based Dockerfiles for all NICo REST images
helm/
  nvidia-infra-controller-prereqs/   Operators + ClusterIssuers
  nvidia-infra-controller-cloud/     Cloud profile (Temporal, Keycloak, REST)
  nvidia-infra-controller-site/      Site profile (Core, site-agent, Vault)
Makefile                             Build, deploy, test targets
```

## Container Images

All images use UBI base, published to `quay.io/fdupont-redhat/nico-*`.

| Image | Base | Binary |
|---|---|---|
| nico-rest-api | ubi9/ubi-micro | api + nicocli |
| nico-rest-workflow | ubi9/ubi-micro | workflow |
| nico-rest-site-agent | ubi9/ubi-micro | site-agent |
| nico-rest-site-manager | ubi9/ubi-micro | sitemgr |
| nico-rest-cert-manager | ubi9/ubi-micro | credsmgr |
| nico-rest-db | ubi9/ubi-micro | migrations |
| nico-flow | ubi9/ubi-micro | flow |
| nico-psm | ubi9/ubi-micro | psm |
| nico-nsm | ubi9/ubi-minimal | nsm + scripts + sshpass |

Build: `make docker-build-ubi`
Push: `make docker-push-ubi`

## Key Makefile Targets

```
make docker-build-ubi    Build all 9 UBI images
make docker-push-ubi     Push to quay.io/fdupont-redhat
make helm-dep-build      Build Helm chart dependencies
make helm-lint           Lint all charts
make helm-template       Template all charts (dry-run)
make deploy-prereqs      Install operators and ClusterIssuers
make deploy-cloud        Deploy cloud profile (Temporal, Keycloak, REST)
make deploy-site         Deploy site profile (Core, site-agent, Vault)
```

## Conventions

- Apache 2.0 license header on all files
- `git commit -s` (signed-off-by) required
- Image names: `nico-*` prefix (not `carbide-*`)
- Helm charts: one prereqs chart + one chart per profile
- OpenShift 4.21+ primary target, vanilla K8s secondary
