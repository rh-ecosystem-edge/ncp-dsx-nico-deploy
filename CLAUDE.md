# ncp-dsx-nico-deploy — AI Assistant Guide

## What This Is

Red Hat deployment artifacts for NVIDIA NICo (Infra Controller), part of the
DSX OS platform, targeting NVIDIA Cloud Partners (NCP). This repo does NOT
fork upstream — it builds UBI-based container images from upstream source and
provides Helm charts with Red Hat-preferred components (SPIFFE, Crunchy PostgreSQL,
RHBK).

## Upstream Repos (read-only, never modified)

| Repo | What we consume |
|---|---|
| `github.com/NVIDIA/infra-controller` | Go/Rust source (monorepo: REST API, site-agent, Core) |

Vendored as git submodule at `helm/vendor/infra-controller`.

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
└── KeycloakRealmImport (nico realm, nico-rest + ncx-service clients)

nvidia-infra-controller-site namespace (per-site, edge)
├── nico-rest-site-agent → connects to cloud's Temporal via OTP certs
├── nico-core (bare metal management: carbide-api, DHCP, PXE, DNS)
├── nico-site-core-pg (Crunchy PostgreSQL — Core data only)
└── Vault (HashiCorp, standalone — BMC credential storage)
```

The cloud profile hosts the single Temporal instance. Per-site Temporal
namespaces (named by site UUID) are created dynamically by the REST API
at site registration. Site-agents bootstrap with an OTP to get mTLS certs
for connecting to cloud's Temporal. Operators (cert-manager, Crunchy PGO, RHBK)
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

All images use UBI 10 base, built by Konflux. Dockerfiles in `docker/ubi/`.

| Image | Base | Binary |
|---|---|---|
| nico-rest-api | ubi10/ubi-micro | api + nicocli |
| nico-rest-workflow | ubi10/ubi-micro | workflow |
| nico-rest-site-agent | ubi10/ubi-micro | site-agent |
| nico-rest-site-manager | ubi10/ubi-micro | sitemgr |
| nico-rest-cert-manager | ubi10/ubi-micro | credsmgr |
| nico-rest-db | ubi10/ubi-micro | migrations |
| nico-flow | ubi10/ubi-micro | flow |
| nico-psm | ubi10/ubi-micro | psm |
| nico-nsm | ubi10/ubi-minimal | nsm + scripts + sshpass |
| nico-core | ubi10/ubi-minimal | carbide-api, dns, bmc-proxy |
| nico-admin-cli | ubi10/ubi-micro | nico-admin-cli (Core gRPC CLI) |
| nicocli | ubi10/ubi-micro | nicocli (REST API CLI, from OpenAPI) |

Local build: `make docker-build-ubi` (requires submodule checkout)

## Key Makefile Targets

```
make docker-build-ubi    Build REST images locally
make docker-build-core   Build Core + admin-cli images locally
make helm-dep-build      Build Helm chart dependencies
make helm-lint           Lint all charts
make helm-template       Template all charts (dry-run)
make deploy-prereqs      Install operators and ClusterIssuers
make deploy-cloud        Deploy cloud profile (Temporal, Keycloak, REST)
make deploy-site         Deploy site profile (Core, site-agent, Vault)
```

## PostgreSQL Versions

Cloud profile (REST API, Temporal, Keycloak): **PG18** via Crunchy PGO 5.8.8 default
image. PGO 5.8.8 has broken PG15/PG16 image digests; PG17 and PG18 work.

Site profile (Core): **PG15** pinned to `ubi9-15.15-2550`. Upstream validates
against PG15 (Spilo-15). PG17/PG18 break Core's Rust sqlx migrations due to
SQL function inlining during `CREATE INDEX` within multi-statement queries
(extension functions like `uuid_nil()` aren't visible to the inliner).

## Keycloak Realm

Realm `nico` (aligned with upstream `helm-prereqs/keycloak/realm-configmap.yaml`):
- `nico-rest` client: human users (standardFlow + directAccess + serviceAccount)
- `ncx-service` client: M2M only (client_credentials grant, 30min token TTL)
- Roles: `ncx:NICO_PROVIDER_ADMIN`, `ncx:NICO_TENANT_ADMIN`, `ncx:NICO_PROVIDER_VIEWER`
- Single user: `service-account-ncx-service` (auto-created, has `oidc_id` attribute)
- RHBK 26.x requires explicit `Client ID` protocol mapper on `ncx-service`
  (PGO auto-generated mappers are overwritten when `protocolMappers` is specified)
- Keycloak route uses `reencrypt` with CA cert injected via Helm `lookup`
- Token issuer must match `externalBaseURL` — fetch tokens via the external route

## Conventions

- Apache 2.0 license header on all files
- `git commit -s` (signed-off-by) required
- Image names: `nico-*` prefix (not `carbide-*`)
- Helm charts: one prereqs chart + one chart per profile
- OpenShift 4.21+ primary target, vanilla K8s secondary
