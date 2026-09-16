# NVIDIA Infra Controller — Red Hat Deployment

Red Hat deployment artifacts for [NVIDIA Infra Controller (NICo)](https://docs.nvidia.com/infra-controller/documentation/home).
Installs upstream Helm charts directly with values overrides and a thin
Red Hat infrastructure layer — Crunchy PostgreSQL, RHBK Keycloak, Vault HA,
External Secrets Operator, and OpenShift Routes.

## Prerequisites

- OpenShift 4.21+
- `oc`, `helm`, `kustomize`, `podman`, `python3`, `git`, `curl`, `jq` and
  `ssh-keygen` tools.
- Git submodule initialized (`git submodule update --init`)
- A **default StorageClass** with dynamic RWO provisioning. The PostgreSQL,
  Vault, NATS, and Temporal PVCs use `storageClass: null` (the cluster
  default), so one must exist. Managed clouds ship this (e.g. ROSA →
  `gp3-csi`); a bare cluster (SNO on a VM, self-managed bare metal) needs a
  provisioner installed and marked default first — LVM Storage (LVMS) or
  OpenShift Data Foundation. See `minimal-setup-requirements.md`.

Verify all required tools are installed. Some checks (cluster login, default
StorageClass) require an active cluster session (`oc login` or
`export KUBECONFIG=...`):

```bash
make check-prereqs
```

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

The cloud profile is single-instance (no HA) and runs as-is on a single node.

```bash
make deploy-cloud-infra
```

### 3. NICo REST API

Installs the upstream `nico-rest` chart with values overrides and
kustomize patches (Keycloak wait, CA trust, SCC fixes).

```bash
make deploy-cloud
```

### Post-Deploy (Cloud)

These steps run automatically as part of `make deploy-all-cloud`. If you
ran steps 1–3 individually, run them manually:

```bash
make patch-keycloak-route   # fixes Keycloak route 503 (reencrypt TLS)
make bootstrap-org          # creates Infrastructure Provider and Tenant
```

**`patch-keycloak-route`** injects the self-signed CA certificate into the
Keycloak route's `destinationCACertificate`. Without it, the OpenShift router
cannot verify Keycloak's backend TLS and the route returns 503.

**`bootstrap-org`** fetches the authoritative `ncx-service` client secret
from the Keycloak admin API (not the K8s secret, which may be stale), obtains
a token, then calls the infrastructure-provider and tenant bootstrap endpoints.
The org name (`ncx`) is derived from the Keycloak realm role prefix
(`ncx:NICO_PROVIDER_ADMIN`).

### 4. Site Infrastructure

Deploys PostgreSQL (nico, flow, psm, nsm databases), Vault, NATS, and ESO
secrets.

```bash
make deploy-site-infra
```

Vault topology is auto-selected from the cluster's node count: **3-node HA
Raft** on clusters with ≥3 schedulable nodes, **standalone** (file storage) on
single-node (SNO/VM) or 2-node clusters — so the same command works everywhere.
Force it with `make deploy-site-infra VAULT_MODE=ha|standalone`.
`make deploy-site-infra-crc` remains as an explicit standalone alias.

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

`deploy-site` layers a site-config overlay onto `nico-core.yaml`. The base
disables `siteConfig` (no resource pools) so it never silently ships RBAC
bypasses — but Core exits without pools, so a config is always supplied:

- **default** → `helm/values/nico-core-site.yaml` (production pools/networks,
  no bypass). Override with `make deploy-site SITE_VALUES=<your-site>.yaml`.
- **`make deploy-site MAT=1`** → `helm/values/nico-core-mat.yaml`
  (machine-a-tron emulator: pools **plus** bypass flags — test/dev only).

> **Per-cluster values.** Two settings in these files are cluster-specific and
> must be set for the target cluster before onboarding real hardware:
> the DHCP hook IPs in `nico-core.yaml` (`nameservers` / `provisioningServer`
> must be *this* cluster's `nico-dns` / `nico-pxe` ClusterIPs —
> `oc get svc nico-dns nico-pxe -n nico-system`), and the network/pool ranges
> in the site-config overlay. The shipped values are valid placeholders so the
> stack comes up on any cluster with no hardware attached, but PXE/discovery
> will use stale addresses until you set the real ones.

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
make deploy-all-cloud          # steps 1-3 + patch-keycloak-route + bootstrap-org
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

## Utility Scripts

### cleanup.sh — Full teardown

Removes all Helm releases, PostgreSQL clusters, PVCs, Keycloak, Vault, namespaces,
ClusterIssuers, and cert-manager resources. Keeps OLM subscriptions so operators
are not re-downloaded on the next deployment. Prompts for confirmation before
proceeding.

```bash
bash cleanup.sh
```

Use this instead of `make undeploy` when resources are stuck in `Terminating`
(the script removes finalizers and force-deletes namespaces).

### validate-machines.sh — Validate sites and machine count

Connects to the currently logged-in cluster, acquires a `ncx-service` token
from Keycloak via the admin API, then calls the NICo REST API directly with
`curl` to list sites and machines per site. No extra image build required.

```bash
bash validate-machines.sh
```

The script uses the active `oc` session and will fail fast with a clear error
if no cluster is configured.

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

**nicocli** — REST API client (auto-generated from OpenAPI, site/org management).

```bash
oc run nicocli --rm -it --restart=Never \
  --image=<registry>/nicocli:latest \
  -- --keycloak-url https://keycloak-rhbk-operator.<domain> \
     --keycloak-realm nico --client-id ncx-service \
     --base-url https://nico-rest-api-nico-rest.<domain> \
     site list --org ncx
```

To run as a standalone pod via `oc run`, build and push the `nicocli`
image first (`docker/ubi/Dockerfile.nicocli`), then use the image with
`--base-url https://nico-rest-api.nico-rest.svc:8388` (the fully qualified
Service name, since the pod may not run in the `nico-rest` namespace where
the short name `nico-rest-api` resolves). Note: OpenShift requires
security context overrides (`runAsNonRoot`, `drop: ALL`, etc.) for the
restricted PodSecurity policy.

**nico-admin-cli** — Core gRPC client (bare metal management, host discovery).
Only relevant after deploying the site profile. It's bundled in the
`nico-api` pod, which has its own client certs mounted at
`/run/secrets/spiffe.io/` — the CLI's *default* target is
`carbide-api.forge-system`, a dev-environment address that doesn't exist
here, so the `--api-url`/cert flags below are not optional:

```bash
oc exec -n nico-system deploy/nico-api -- /opt/nico/nico-admin-cli \
  --api-url https://nico-api.nico-system.svc.cluster.local:1079 \
  --client-cert-path /run/secrets/spiffe.io/tls.crt \
  --client-key-path /run/secrets/spiffe.io/tls.key \
  --forge-root-ca-path /run/secrets/spiffe.io/ca.crt \
  machine-interfaces show
```

`machine-interfaces show` is a good sanity check that Core is up and
reachable at any stage — it returns an empty table (rather than an error)
until machines/DPUs have actually registered interfaces, so a working-but-
empty response confirms the API is up and TLS-reachable even before any
hardware (or machine-a-tron) has been discovered. Note it does *not* prove
server-side mTLS enforcement: the machine-a-tron site config sets
`bypass_rbac = true` and requests but does not require client certificates,
so a success here says nothing about client-cert authentication.

## License

Apache License 2.0
