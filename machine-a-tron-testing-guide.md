# Testing NICo with machine-a-tron (No Hardware Required)

machine-a-tron is NICo's built-in simulation tool. It runs entirely in the
cluster, spawns virtual BMC endpoints (bmc-mock, a Redfish mock server),
sends simulated DHCP requests, and drives the full NICo state machine — no
physical servers, switches, or OOB network required.

This guide takes a site profile from a fresh install to **NoDpu hosts in
`Ready` state** (2, by default — see `host_count` in Configuration
Reference).

## Quick Start

Prerequisite: the site profile is deployed (`make deploy-site
SITE_NAME=<name>`, from the root README). machine-a-tron's Kubernetes
resources are already wired into the site chart's kustomize render, so
they exist as soon as the site profile installs — they just need an image
and some credentials before anything progresses.

```bash
make build-machine-a-tron       # ~10 min: compiles the Rust binary in-cluster
make bootstrap-machine-a-tron   # seeds BMC/UEFI credentials bmc-mock expects (idempotent)
make machine-a-tron-status      # poll this — expect Ready within 5-10 min
```

`make machine-a-tron-status` runs `nico-admin-cli managed-host show`.
Expect one row per configured host (2, by default — see `host_count` in
Configuration below), each ending in `Ready`:

```
+---+-------------------------------------------------------------+-------+
|   | Machine IDs (H/D)                                           | State |
+===+=============================================================+=======+
| H | fm100httli6fgcnklvrotjdcuj4oriv04ufsjfgkrs2m885po661hs54p6g | Ready |
+---+-------------------------------------------------------------+-------+
| H | fm100htvsnbobe6rf86cnhrgjv07auh489f58s4jm9abau4utao6om9d8hg | Ready |
+---+-------------------------------------------------------------+-------+
```

If a row isn't progressing, jump to Troubleshooting below.

## What This Tests, and What It Doesn't

| Capability | Covered |
|---|---|
| DHCP discovery, Redfish exploration, BMC credential rotation, BIOS config | Yes |
| NoDpu host reaching `Ready` | Yes |
| DPU discovery/boot (`os_fsm: DpuAgent`, reaches `MachineUp`) | Yes |
| DPU-equipped **host** reaching `Ready` | **No** — structural limitation #1 |
| Tenant instance allocation for a NoDpu host | **No** — structural limitation #2 |
| Real DHCP relay/switches, vendor Redfish quirks, real BMC timing, physical network (MetalLB/VLAN/OOB) | No — all simulated |

**Structural limitations (not bugs — don't try to fix these):**

1. **DPU-equipped hosts (`dpu_per_host_count > 0`) never reach `Ready`.**
   machine-a-tron simulates the DPU-side agent but not a host-side Scout
   agent. Getting past `WaitingForCleanup/HostCleanup` requires a real
   Scout (boots on the bare-metal host OS after PXE, wipes storage,
   reboots, calls back into `nico-api`) to set `last_cleanup_time` —
   nothing ever does that for a machine-a-tron host, so it sits in
   `HostCleanup` forever, retried every ~2s with zero progress.
2. **NoDpu hosts (the ones that do reach `Ready`) can't be allocated to a
   tenant.** `nico-admin-cli instance allocate`'s machine picker requires a
   network interface whose PCI vendor string contains "mellanox" (i.e. a
   DPU/SmartNIC) — which a NoDpu host doesn't have by definition. You can
   fully discover+Ready a NoDpu host, or fully boot a DPU, but not both on
   the same host with machine-a-tron alone.

## Configuration Reference

The working config is already checked in — you shouldn't need to touch
these files for a standard 2-host NoDpu run. Reference them if you're
changing host counts, adding DPU groups, or debugging.

**`helm/nvidia-infra-controller-site/kustomize/machine-a-tron.yaml`**
(`mat.toml`, in the ConfigMap):

```toml
carbide_api_url = "https://nico-api.nvidia-infra-controller-site.svc.cluster.local:1079"
interface = "NOTUSED"              # required but unused with use_single_bmc_mock
use_pxe_api = true                 # simulate PXE via API, no real PXE server needed
use_single_bmc_mock = true         # required for K8s: all BMCs behind one Service
bmc_mock_port = 1266
mock_bmc_ssh_server = true
persist_dir = "/tmp/machine-a-tron-data"   # emptyDir — resets on pod restart
register_expected_machines = true  # auto-registers mock hosts as ExpectedMachines

[machines.config]
host_count = 2
dpu_per_host_count = 0             # 0 = NoDpu mode; auto-registers dpu_mode: NoDpu
template_dir = "/opt/machine-a-tron/templates"   # MUST be per-group, not top-level
oob_dhcp_relay_address = "192.168.2.1"
admin_dhcp_relay_address = "192.168.252.1"
```

Two gotchas if you edit this:
- `template_dir` only works inside `[machines.<name>]`. At the top level
  it's silently ignored and machine-a-tron falls back to a compiled-in
  path that doesn't exist in the image, failing with `Unable to read
  dev/machine-a-tron/templates/dhcp_discovery.json`.
- **ConfigMap changes don't auto-apply** — there's no Reloader watching
  it. After editing + redeploying, also run:
  `oc rollout restart deployment/machine-a-tron -n nvidia-infra-controller-site`

For mixed scenarios, add more `[machines.<name>]` sections (each DPU group
will boot its DPUs but the host still can't reach `Ready`, per limitation
#1 above).

**`helm/nvidia-infra-controller-site/values.yaml`**
(`nico-core.nico-api.siteConfig.nicoApiSiteConfig`) — every line here is a
hard requirement, not tuning:

```toml
bypass_rbac = true
initial_domain_name = "nico.local"   # without this, [networks.*] below are silently never created
attestation_enabled = false          # no real Scout to send measured-boot/TPM reports
tpm_required = false

[site_explorer]
run_interval = "10s"
allow_zero_dpu_hosts = true          # without this, NoDpu discoveries are dropped on the floor
bmc_proxy = "machine-a-tron-bmc-mock.nvidia-infra-controller-site.svc.cluster.local:1266"

[networks.oob]                       # must cover mat.toml's oob_dhcp_relay_address
type = "underlay"
prefix = "192.168.2.0/24"
gateway = "192.168.2.1"
mtu = 1500
reserve_first = 10

[networks.admin]                     # must cover mat.toml's admin_dhcp_relay_address
type = "admin"
prefix = "192.168.252.0/24"
gateway = "192.168.252.1"
mtu = 9000
reserve_first = 10
```
## Vault Prerequisites

`nico-api` needs three things enabled in Vault before machine-a-tron can
work at all — `helm/nvidia-infra-controller-site/templates/vault-init.yaml`
sets all three up automatically as a post-install hook, but **only on
Vault's first-ever initialization** (it no-ops on every later run, so it
won't retroactively fix an already-initialized Vault):

1. **KV v2** at `secrets/` — BMC/DB credential storage.
2. **PKI** at `nicoca/` with a `nico-cluster` role (`require_cn=false`,
   `allowed_uri_sans=spiffe://*`) — needed for `DiscoverMachine` to issue
   machine/DPU mTLS certs, independent of `attestation_enabled`.
3. **Kubernetes auth**, with a `nico-api` role bound to the `nico-api`
   service account. Vault's own `vault` service account holds the
   `system:auth-delegator` binding needed to call the Kubernetes
   TokenReview API — `token_reviewer_jwt` is deliberately left unset in
   the config so Vault falls back to its own pod's token (which kubelet
   keeps refreshed), rather than a literal captured value that would go
   stale.

If you're working against a site whose Vault predates this file, apply
the equivalent `vault` CLI commands by hand once — copy them out of
`vault-init.yaml` and run inside `vault-0` with the root token from the
`vault-unseal-secret` Secret.

## Observing Progress

```bash
make machine-a-tron-status                              # managed hosts + state
```

Or the underlying CLI directly, for more detail (`nico-admin-cli` is
bundled in the `nico-api` pod; its default target doesn't exist here, so
the connection flags are mandatory):

```bash
CLI() {
  oc exec -n nvidia-infra-controller-site deploy/nico-api -- /opt/nico/nico-admin-cli \
    --carbide-api https://nico-api.nvidia-infra-controller-site.svc.cluster.local:1079 \
    --client-cert-path /run/secrets/spiffe.io/tls.crt \
    --client-key-path /run/secrets/spiffe.io/tls.key \
    --forge-root-ca-path /run/secrets/spiffe.io/ca.crt \
    "$@"
}

CLI managed-host show                        # all managed hosts + state
CLI --extended machine show <machine-id>     # full detail + state history
CLI --extended expected-machine show         # machines registered by machine-a-tron
CLI machine-interfaces show                  # MAC/IP allocations
```

(Define `CLI` as a function, not a variable — `CLI="oc exec ..."` followed
by `$CLI managed-host show` is prone to zsh parsing the whole thing as one
command name with embedded spaces.)

The admin web UI works too, mounted under `/admin` on the same mTLS port
(1079) as gRPC — not at bare paths, and not over plain `http://`. A client
cert is requested but not enforced (`bypass_rbac = true`), so a plain
`curl -sk` works from inside the cluster or via `oc port-forward
svc/nico-api -n nvidia-infra-controller-site 1079:1079`:

```
https://nico-api.nvidia-infra-controller-site.svc.cluster.local:1079/admin/managed-host.json
https://nico-api.nvidia-infra-controller-site.svc.cluster.local:1079/admin/machine/<id>/state-history
```

**What "done" looks like** for a NoDpu host: `STATE: READY`, clean state
history with no `Failed`/error entries, and `sku generate`/`redfish
bios-attrs`/`machine-validation on-demand start` all succeed against it.
`instance allocate` will *not* find it usable (limitation #2).

Expected flow (`dpu_per_host_count = 0`):

```
DHCP Discovery → Site Explorer probes bmc-mock via Redfish
  → ManagedHost created (dpus: [])
    → HostInitializing/WaitingForPlatformConfiguration → PollingBiosSetup
      → SetBootOrder → WaitingForLockdown (skips DPU-down wait, no DPUs)
        → BomValidating/MatchingSku → Ready
```

Cold start typically takes 5–10 minutes end-to-end, almost entirely real
wait timers (not something to interrupt).

## Troubleshooting Reference

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to read dev/machine-a-tron/templates/dhcp_discovery.json` | `template_dir` set at top level of `mat.toml` | Move it into the `[machines.<name>]` section |
| `No network segment defined for relay addresses: [x.x.x.x]` | No `[networks.*]` segment covers that relay IP | Add/fix a `[networks.<name>]` entry whose `prefix` contains it |
| `No domain configured, skipping initial network creation` | `initial_domain_name` unset | Set it |
| `Cannot create managed host for explored endpoint with no DPUs: ...disallowed by config` | `site_explorer.allow_zero_dpu_hosts` unset (defaults false) | Set `allow_zero_dpu_hosts = true` |
| Host stuck in `HostInitializing/Measuring { WaitingForMeasurements }` | `attestation_enabled = true` (default), no real Scout to send measurements | Set `attestation_enabled = false`, `tpm_required = false` |
| `Failed to generate client certificate: ... Vault ... 403/404/400` on `DiscoverMachine` | Vault PKI (`nicoca`) not enabled/misconfigured | See Vault Prerequisites |
| `Missing credential machines/bmc/site/root` | BMC credentials not bootstrapped | `make bootstrap-machine-a-tron` |
| Vault login returns bare `permission denied` (403) on any `nico-admin-cli credential` command | Kubernetes auth reviewer JWT stale/misconfigured (see Vault Prerequisites) — reproduce directly with `vault write auth/kubernetes/login role=nico-api jwt=<sa-token>` against `vault-0`, since Vault doesn't log auth failures by default | Confirm the `system:auth-delegator` ClusterRoleBinding targets SA `vault` (not a one-shot Job's SA), and that `token_reviewer_jwt` is unset in `auth/kubernetes/config` |
| Redfish GET returns 403 `Factory-default password must be changed` | `site-wide-root` password equals a vendor's factory-default password | Rotate `site-wide-root` to a distinct password |
| `Site explorer will not explore this endpoint to avoid lockout` | A prior bad-credential attempt got cached | `CLI site-explorer clear-error <ip>` (no port) |
| Host stuck in `WaitingForCleanup/HostCleanup`, retried every ~2s, zero progress | DPU-equipped host — needs a real Scout (limitation #1) | Switch that machine group to `dpu_per_host_count = 0` |
| A state is stuck 5+ min with no errors, then suddenly progresses | Real wait timers gate reprocessing | Just wait |
| Still stuck after 5+ min with nothing logged | Some "wait" states (`Measuring`, `WaitingForLockdown`) only get reprocessed on a `nico-api` restart, not by polling | `oc rollout restart deployment/nico-api -n nvidia-infra-controller-site` |
| After restarting machine-a-tron, DHCP fails with `Network segment mismatch for existing MAC address` | Stale `machine_interfaces`/`expected_machine` rows from a previous run | See Resetting the Simulation |
| `instance allocate` reports "No available machines" for a `Ready` host | No "mellanox"-vendor NIC (limitation #2) | Not fixable with machine-a-tron alone |
| Redfish GET starts 401ing on a previously-`Ready` host after `machine-validation on-demand`/reboot | bmc-mock resets to factory-default credentials across a simulated reboot; nico-api's cached rotated credential no longer matches | `CLI site-explorer clear-error <ip>`; if it re-fails immediately, re-run `make bootstrap-machine-a-tron` |
| After a full reset + restart, a known MAC gets a straight 401 (not the "factory default" 403) on its first probe | nico-api stores a per-MAC BMC credential in Vault (`machines/bmc/<mac>/root`) on first successful rotation; machine-a-tron reuses the same deterministic MACs every restart, but its `emptyDir`-backed bmc-mock resets to factory-default each time, so the stale Vault entry no longer matches. Deleting `machine_interfaces`/`expected_machine`/`managed_host` does **not** clear this | `CLI credential delete-bmc --kind=bmc-root --mac-address <mac>` for every MAC before restarting — see Resetting the Simulation, step 4 |

## Resetting the Simulation

machine-a-tron's own state resets on pod restart (`persist_dir` is an
`emptyDir`), but `nico-api`'s database keeps every machine/interface/
expected-machine record from the previous run — restarting machine-a-tron
alone causes new DHCP requests to collide with those stale records. To
start clean:

```bash
CLI managed-host show                                   # note the Machine IDs (H rows) first
CLI machine force-delete --machine <host-machine-id>     # 1. force-delete every managed host

CLI machine-interfaces show                              # 2. delete orphaned interfaces
CLI machine-interfaces delete <interface-id>             #    (Associated Node ID empty = orphaned)

CLI --extended expected-machine show                     # 3. delete stale expected-machine entries
CLI expected-machine delete <bmc-mac-address>            #    (these accumulate across runs)

CLI credential delete-bmc --kind=bmc-root --mac-address <bmc-mac-address>  # 4. clear stale per-MAC
                                                                            #    Vault credential — easy
                                                                            #    to miss, see Troubleshooting

oc rollout restart deployment/machine-a-tron -n nvidia-infra-controller-site  # 5. fresh DHCP/MAC cycle
```

Then `make machine-a-tron-status` — expect a fresh `ManagedHost` per
configured host within 1–2 minutes, `Ready` within 5–10. The very first
Redfish probe of a freshly-registered endpoint hitting the
factory-default 403 once is normal; clear it with `CLI site-explorer
clear-error <ip>` if it doesn't resolve on its own within a minute.

## Also Watch For

- **Postgres disk usage**: the site's `nico-site-core-pg-instance1-*-pgdata`
  PVC (20Gi default) can fill with unarchived WAL if pgbackrest archiving
  isn't succeeding — heavy iteration (restarts, force-deletes, credential
  churn) grows this noticeably. Check with `oc exec
  nico-site-core-pg-instance1-<suffix>-0 -n nvidia-infra-controller-site -c
  pgbackrest -- df -h /pgdata`. If full, Postgres crash-loops with `could
  not write lock file "postmaster.pid": No space left on device` and every
  DB call hangs/times out.
