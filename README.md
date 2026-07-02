# NVIDIA Infra Controller — Red Hat Deployment

Red Hat deployment artifacts for [NVIDIA Infra Controller (NICo)](https://docs.nvidia.com/infra-controller/documentation/home).
Installs upstream Helm charts directly with values overrides and a thin
Red Hat infrastructure layer — Crunchy PostgreSQL, RHBK Keycloak, Vault HA,
External Secrets Operator, and OpenShift Routes.

## Prerequisites

- OpenShift 4.21+
- `oc` and `helm` CLI tools
- Git submodule initialized (`git submodule update --init`)

## Deployment

### 1. Operators and ClusterIssuers

Installs cert-manager, Crunchy PGO, RHBK, and ESO operators via OLM.
Creates the self-signed CA chain and ClusterIssuers.

```bash
make deploy-prereqs
```

### 2. Cloud Infrastructure

Deploys PostgreSQL (nico, temporal, keycloak databases), RHBK Keycloak
with realm import, Temporal server, OpenShift Routes, and ESO secrets.

```bash
make deploy-cloud-infra        # or deploy-cloud-infra-crc for single-node
```

### 3. NICo REST API

Installs the upstream `nico-rest` chart with values overrides and
kustomize patches (Keycloak wait, CA trust, SCC fixes).

```bash
make deploy-cloud
```

### 4. Site Infrastructure

Deploys PostgreSQL (nico, flow, psm, nsm databases), Vault (HA Raft for
production, standalone for CRC), NATS, and ESO secrets.

```bash
make deploy-site-infra         # HA Raft (3 nodes, production)
make deploy-site-infra-crc     # standalone (single-node, CRC)
```

### 5. Initialize Vault

One-time step. Initializes Vault, unseals it, stores the unseal key in a
Secret (for postStart auto-unseal on restarts), then configures: PKI engine
(nicoca), AppRole auth, KV seeding, Flow tokens, and the `vault-nico-issuer`
ClusterIssuer.

For production, replace the postStart unseal with cloud KMS (AWS/GCP/Azure)
or an external Transit Vault. See `helm/infra-site/values.yaml` for details.

```bash
make vault-init
```

### 6. NICo Core

Installs the upstream `nico` chart with values overrides and kustomize
patches (Crunchy secret keys, SCC fixes, migration fixes).

```bash
make deploy-site
```

### 7. Register a Site and Deploy Site-Agent

```bash
make deploy-site-agent SITE_NAME=my-site
```

To deploy to an existing site (skips registration):

```bash
make deploy-site-agent SITE_ID=<existing-uuid>
```

### Full Deploy (all steps)

```bash
make deploy-all-cloud          # steps 1-3
make deploy-all-site           # steps 4-7 (without site-agent)
```

### Status

```bash
make status
```

### Teardown

```bash
make undeploy
```

## Architecture

Upstream charts are installed directly — never wrapped. Our downstream
layer provides only Red Hat-specific infrastructure:

```
helm/
  vendor/infra-controller/           Upstream (git submodule, read-only)
  values/                            Values overrides for upstream charts
  infra-cloud/                       Red Hat add-ons: Crunchy PG, Keycloak, Temporal, Routes, ESO
  infra-site/                        Red Hat add-ons: Vault HA, PG, NATS, ESO
  kustomize/                         Patches for upstream templates (SCC, Crunchy keys)
  nvidia-infra-controller-prereqs/   OLM operator subscriptions
```

| Namespace | What deploys there |
|---|---|
| `nico-rest` | REST API, Temporal, PG (cloud), Keycloak Routes |
| `nico-system` | Core services, site-agent, Flow, Vault HA, PG (site), NATS |
| `rhbk-operator` | Keycloak (RHBK operator) |

### Vault

3-node HA Raft cluster with TLS via cert-manager. Vault PKI engine
(`nicoca`) issues certificates for Core services via the `vault-nico-issuer`
ClusterIssuer. Initialized and unsealed by `make vault-init` (one-time step).
PostStart hook auto-unseals on pod restarts from a stored unseal key.

For production, replace with cloud KMS or external Transit Vault.

### PostgreSQL

Two consolidated Crunchy PostgresCluster instances with cert-manager TLS:
- **Cloud** (PG18): `nico`, `temporal`, `temporal_visibility`, `keycloak` databases
- **Site** (PG15): `nico`, `flow`, `psm`, `nsm` databases

## Container Images

UBI 10-based images built by Konflux. Dockerfiles in `docker/ubi/`.

```bash
make docker-build-ubi    # REST images
make docker-build-core   # Core + admin-cli images
```

## CLI Tools

**nicocli** — REST API client:

```bash
oc run nicocli --rm -it --restart=Never \
  --image=<registry>/nicocli:latest \
  -- --keycloak-url https://keycloak-rhbk-operator.<domain> \
     --keycloak-realm nico --client-id ncx-service \
     --base-url https://nico-rest-api-nico-rest.<domain> \
     site list --org ncx
```

**nico-admin-cli** — Core gRPC client:

```bash
oc run nico-admin-cli --rm -it --restart=Never \
  -n nico-system \
  --image=<registry>/nico-admin-cli:latest \
  -- site-explorer get-report
```

## License

Apache License 2.0
