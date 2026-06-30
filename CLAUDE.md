# ncp-dsx-nico-deploy — AI Assistant Guide

## What This Is

Red Hat deployment artifacts for NVIDIA NICo (Infra Controller), part of the
DSX OS platform, targeting NVIDIA Cloud Partners (NCP). This repo does NOT
fork upstream — it installs upstream Helm charts directly with values overrides
and provides a thin Red Hat infrastructure layer (Crunchy PostgreSQL, RHBK
Keycloak, Vault HA, ESO, OpenShift Routes).

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

### Design Principle

Upstream charts are installed directly — never wrapped or re-packaged. Our
downstream layer is cleanly separated into four concerns:

1. **Values overrides** (`helm/values/`) — config deltas for upstream charts
2. **Infrastructure charts** (`helm/infra-cloud/`, `helm/infra-site/`) — Red Hat
   components (Crunchy PG, RHBK, Vault HA, ESO, Routes)
3. **Kustomize patches** (`helm/kustomize/`) — fixes for upstream templates
   (each patch maps to one upstream contribution PR)
4. **Prereqs** (`helm/nvidia-infra-controller-prereqs/`) — OLM operator subscriptions

### Deployment Topology

```
nico-rest namespace (management plane — upstream nico-rest chart)
├── nico-rest-api                    ← upstream
├── nico-rest-cloud-worker           ← upstream
├── nico-rest-site-worker            ← upstream
├── nico-rest-site-manager           ← upstream
├── nico-rest-cert-manager           ← upstream
├── nico-rest-db (migration job)     ← upstream
├── Temporal server v1.2.0           ← upstream chart from go.temporal.io
├── nico-cloud-pg (Crunchy PG18)     ← infra-cloud (nico, temporal, keycloak DBs)
├── OpenShift Routes                 ← infra-cloud
└── ESO ExternalSecrets              ← infra-cloud

rhbk-operator namespace (Keycloak — deployed by infra-cloud)
├── Keycloak (RHBK operator CRD, TLS via cert-manager)
└── KeycloakRealmImport (nico realm, nico-rest + ncx-service clients)

nico-system namespace (per-site, edge — upstream nico + site-agent charts)
├── nico-api (Core gRPC API)         ← upstream
├── nico-dhcp, nico-dns, nico-pxe    ← upstream
├── nico-ssh-console-rs              ← upstream
├── nico-hardware-health             ← upstream
├── nico-dsx-exchange-consumer       ← upstream
├── nico-bmc-proxy                   ← upstream
├── nico-flow (PSM/NSM sidecars)     ← upstream
├── nico-rest-site-agent             ← upstream (connects to cloud Temporal)
├── NATS (MQTT for DSX Exchange)     ← infra-site
├── Vault HA (3-node Raft)           ← infra-site
├── Vault Transit (auto-unseal)      ← infra-site
├── nico-site-pg (Crunchy PG15)      ← infra-site (nico, flow, psm, nsm DBs)
└── ESO ExternalSecrets              ← infra-site
```

### TLS Architecture

Self-signed CA chain via cert-manager, with Vault PKI for Core services:

```
nico-bootstrap-issuer (self-signed)
  └── nico-root-ca Certificate (10-year CA, ECDSA P-256)
        ├── nico-rest-ca-issuer (ClusterIssuer) → REST services, Temporal certs
        ├── site-issuer (ClusterIssuer) → Vault TLS certs (pre-Vault bootstrap)
        └── imported into Vault PKI (nicoca mount)
              └── vault-nico-issuer (Vault PKI ClusterIssuer) → Core services
```

### Vault Configuration

- **Primary:** 3-node HA Raft cluster with TLS, cert-reload sidecar (UBI-minimal)
- **Auto-unseal:** Transit Vault (dedicated standalone instance, transit key `autounseal`)
- **PKI:** `nicoca` engine with `nico-cluster` role (SPIFFE URI SANs)
- **Auth:** AppRole for Core API (`nico-vault-policy`), K8s auth for cert-manager
- **KV:** `secrets/` mount with factory-default BMC credential seeds
- **Flow tokens:** Periodic tokens for PSM/NSM with scoped policies

### Prerequisites (installed by prereqs chart)

| Component | OLM source | Purpose |
|---|---|---|
| cert-manager | `redhat-operators` | TLS certificate lifecycle |
| Crunchy PostgreSQL | `certified-operators` | Managed PostgreSQL clusters |
| RHBK (Keycloak) | `redhat-operators` | Identity and access management |
| External Secrets Operator | `redhat-operators` | Cross-namespace secret sync |

## Directory Structure

```
docker/ubi/                          UBI-based Dockerfiles for all NICo images
helm/
  vendor/infra-controller/           Upstream git submodule (read-only)
  nvidia-infra-controller-prereqs/   OLM operators + ClusterIssuers + ESO
  values/                            Values overrides for upstream charts
    nico-rest.yaml                     REST API, workflow, site-manager, credsmgr
    temporal.yaml                      Temporal server (co-located in nico-rest ns)
    nico-core.yaml                     Core tier (all services enabled)
    nico-rest-site-agent.yaml          Site-agent (Temporal client)
  infra-cloud/                       Red Hat cloud infrastructure add-ons
    templates/
      cnpg-cluster.yaml                Consolidated PG (nico, temporal, keycloak)
      keycloak/                        RHBK Keycloak CRDs + TLS
      routes.yaml                      OpenShift Routes
      eso-external-secrets.yaml        CA cert sync via ESO
      temporal-certificate.yaml        Temporal server TLS cert
  infra-site/                        Red Hat site infrastructure add-ons
    templates/
      cnpg-cluster.yaml                Consolidated PG (nico, flow, psm, nsm)
      vault-init.yaml                  Vault config (PKI, AppRole, KV, Flow tokens)
      vault-transit.yaml               Transit Vault (auto-unseal service)
      vault-*-tls-cert.yaml            TLS certs (listener, Raft, transit)
      site-issuer.yaml                 site-issuer ClusterIssuer
      eso-external-secrets.yaml        nico-roots CA sync via ESO
      core-stubs.yaml                  AppRole placeholder secret
  kustomize/
    nico-rest/                       Patches for upstream nico-rest chart
      patches/                         DB migration, Keycloak wait, CA trust, SCC
    nico-core/                       Patches for upstream nico Core chart
      patches/                         Crunchy secret keys, SCC, migrations
  plugins/
    kustomize-post-renderer/         YAML dedup + kustomize build script
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
# Build
make docker-build-ubi       Build REST images locally
make docker-build-core      Build Core + admin-cli images locally
make helm-dep-build         Build Helm chart dependencies
make helm-lint              Lint all charts + validate upstream rendering
make helm-template          Template all charts (dry-run)

# Deploy — Cloud profile
make deploy-prereqs         Install OLM operators and ClusterIssuers
make deploy-cloud-infra     Deploy PG, Keycloak, Routes, ESO (nico-rest ns)
make deploy-temporal        Deploy Temporal server (nico-rest ns)
make deploy-cloud           Deploy upstream nico-rest chart (nico-rest ns)
make deploy-all-cloud       All cloud steps in order

# Deploy — Site profile
make deploy-site-infra      Deploy PG, Vault HA, NATS, ESO (nico-system ns)
make deploy-site            Deploy upstream Core chart (nico-system ns)
make deploy-site-agent      Register site + deploy site-agent (nico-system ns)
make deploy-flow            Deploy upstream Flow chart (nico-system ns)
make deploy-all-site        All site steps in order

# Operations
make status                 Show pod status across all namespaces
make undeploy               Tear down everything
```

## PostgreSQL

Two consolidated Crunchy PostgresCluster instances:

- **Cloud** (`nico-cloud-pg`, PG18): databases `nico`, `temporal`,
  `temporal_visibility`, `keycloak` — users `nico`, `temporal`, `keycloak`
- **Site** (`nico-site-pg`, PG15 pinned to `ubi9-15.15-2550`): databases `nico`,
  `flow`, `psm`, `nsm` — user `nico`

PG15 is pinned for Core because upstream validates against Spilo-15. PG17/PG18
break Core's Rust sqlx migrations (SQL function inlining in `CREATE INDEX`).

## Keycloak Realm

Realm `nico` (aligned with upstream `helm-prereqs/keycloak/realm-configmap.yaml`):
- `nico-rest` client: human users (standardFlow + directAccess + serviceAccount)
- `ncx-service` client: M2M only (client_credentials grant, 30min token TTL)
- Roles: `ncx:NICO_PROVIDER_ADMIN`, `ncx:NICO_TENANT_ADMIN`, `ncx:NICO_PROVIDER_VIEWER`
- Single user: `service-account-ncx-service` (auto-created, has `oidc_id` attribute)
- RHBK 26.x requires explicit `Client ID` protocol mapper on `ncx-service`
- Keycloak route uses `reencrypt` with CA cert injected via Helm `lookup`
- Token issuer must match `externalBaseURL` — fetch tokens via the external route
- Admin password auto-generated via `randAlphaNum` + `lookup` (stable across upgrades)

## Upstream Contribution Path

Each kustomize patch maps to one upstream PR:

| Patch | Upstream change |
|---|---|
| `fix-core-security-context` | Remove SYS_PTRACE from nico-api |
| `fix-dsx-exchange-consumer-security-context` | Remove SYS_PTRACE from dsx-exchange-consumer |
| `fix-credsmgr-securitycontext` | Null securityContext on credsmgr |
| `fix-core-secret-keys`, `fix-core-deployment-keys` | Support `user` key (Crunchy) alongside `username` |
| `fix-flow-secret-keys` | Same for Flow containers |
| `fix-core-migration` | Add pg_isready init container, increase backoffLimit |
| `fix-db-sslmode`, `fix-db-pullpolicy`, `fix-db-migrate-args` | DB migration robustness |
| `fix-api-wait-keycloak` | Init container waiting for Keycloak OIDC |
| `fix-api-trust-ca` | CA bundle init container for internal TLS trust |

## Conventions

- Apache 2.0 license header on all files
- `git commit -s` (signed-off-by) required
- Image names: `nico-*` prefix (not `carbide-*`)
- Upstream charts installed directly — never wrapped or re-packaged
- Our layer: values overrides + infra charts + kustomize patches
- OpenShift 4.21+ primary target
- Production defaults always (no dev flags, no hardcoded credentials)
