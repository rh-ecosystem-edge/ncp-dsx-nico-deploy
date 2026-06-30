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

### 2. Cloud Profile

Deploys the management plane: PostgreSQL, Keycloak, Temporal, and the
NICo REST API into the `nico-rest` namespace.

```bash
make deploy-all-cloud
```

Or step by step:

```bash
make deploy-cloud-infra   # PG, Keycloak, Routes, ESO
make deploy-temporal       # Temporal server
make deploy-cloud          # Upstream nico-rest chart
```

### 3. Site Profile

Deploys the site tier: PostgreSQL, Vault HA, NATS, Core services, and the
site-agent into the `nico-system` namespace.

```bash
make deploy-all-site
```

Or step by step:

```bash
make deploy-site-infra                   # PG, Vault HA, NATS, ESO
make deploy-site                         # Upstream Core chart
make deploy-site-agent SITE_NAME=my-site # Register site + deploy agent
make deploy-flow                         # Flow rack orchestrator
```

To deploy a site-agent for an existing site (skips registration):

```bash
make deploy-site-agent SITE_ID=<existing-uuid>
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
  infra-cloud/                       Red Hat add-ons: Crunchy PG, Keycloak, Routes, ESO
  infra-site/                        Red Hat add-ons: Vault HA, PG, NATS, ESO
  kustomize/                         Patches for upstream templates (SCC, Crunchy keys)
  nvidia-infra-controller-prereqs/   OLM operator subscriptions
```

| Namespace | What deploys there |
|---|---|
| `nico-rest` | REST API, Temporal, PG (cloud), Routes |
| `nico-system` | Core services, site-agent, Flow, Vault HA, PG (site), NATS |
| `rhbk-operator` | Keycloak (RHBK operator) |

### Vault

3-node HA Raft cluster with Transit auto-unseal. TLS via cert-manager.
Vault PKI engine (`nicoca`) issues certificates for Core services via
the `vault-nico-issuer` ClusterIssuer.

### PostgreSQL

Two consolidated Crunchy PostgresCluster instances:
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
