# Testing NICo with machine-a-tron (No Hardware Required)

## Overview

machine-a-tron is NICo's built-in simulation tool that runs entirely in
software inside the Kubernetes cluster. It spawns virtual BMC endpoints
(bmc-mock) backed by a Redfish mock server, sends simulated DHCP requests,
and drives the full NICo state machine — no physical servers, switches, or
OOB network required.

## What It Tests

| Capability | Covered |
|---|---|
| DHCP discovery (simulated relay) | Yes |
| Redfish exploration (bmc-mock) | Yes |
| BMC credential rotation | Yes |
| BIOS configuration (Redfish PATCH) | Yes |
| State machine progression to Ready | Yes |
| Expected machine matching | Yes |
| NoDpu host flow | Yes (`dpu_per_host_count = 0`) |

## What It Does NOT Test

- Real DHCP relay / switch configuration
- Vendor-specific Redfish quirks (Dell, Lenovo, HPE, Supermicro)
- Actual BIOS changes persisting across reboot
- Real BMC timing and latency (mock responds instantly)
- Physical network plumbing (MetalLB, VLAN, OOB)

## Prerequisites

- SNO or OpenShift cluster with NICo cloud + site profiles deployed
- machine-a-tron container image built from upstream source
- mTLS certificates (SPIFFE or cert-manager) for API communication

## Deployment

machine-a-tron runs as a Deployment inside the NICo namespace. The upstream
repo provides a DevSpace manifest at:

```
helm/vendor/infra-controller/dev/deployment/devspace/machine-a-tron.yaml
```

It creates:
- **ServiceAccount** `machine-a-tron`
- **ConfigMap** with `mat.toml` configuration
- **Certificate** for mTLS (SPIFFE URI or cert-manager)
- **Service** `machine-a-tron-bmc-mock` exposing Redfish (port 1266) and SSH (port 22)
- **Deployment** running the `machine-a-tron` binary

## Configuration

### NoDpu Test Config (mat.toml)

```toml
carbide_api_url = "https://nico-api.nico-system.svc.cluster.local:1079"
tui_enabled = false
log_file = "/tmp/mat.log"
use_pxe_api = true
use_single_bmc_mock = true
bmc_mock_port = 1266
register_expected_machines = true

[machines.config]
host_count = 1
dpu_per_host_count = 0
vpc_count = 0
subnets_per_vpc = 0
dpu_reboot_delay = 10
host_reboot_delay = 10
oob_dhcp_relay_address = "192.168.2.1"
admin_dhcp_relay_address = "192.168.252.1"
```

Setting `dpu_per_host_count = 0` automatically registers expected machines
with `dpu_mode: NoDpu`.

### Key Config Options

| Field | Default | Description |
|---|---|---|
| `carbide_api_url` | (required) | NICo API endpoint |
| `interface` | (required) | Network interface for BMC IP aliases (`cni0` in K8s, `lo0` on macOS) |
| `use_single_bmc_mock` | false | All BMCs behind one K8s Service (required for K8s) |
| `use_pxe_api` | false | Simulate PXE via API (avoids needing a real PXE server) |
| `register_expected_machines` | true | Auto-register mock hosts as expected machines |
| `bmc_mock_port` | 2000 | Port for bmc-mock Redfish HTTPS |
| `mock_bmc_ssh_server` | false | Enable mock BMC SSH server |
| `persist_dir` | None | Persist machine state between restarts |
| `cleanup_on_quit` | false | Delete machines from API on shutdown |

### Multiple Machine Groups

You can define mixed scenarios with multiple `[machines.<name>]` sections:

```toml
[machines.no-dpu-hosts]
host_count = 3
dpu_per_host_count = 0
vpc_count = 0
subnets_per_vpc = 0
dpu_reboot_delay = 10
host_reboot_delay = 10
oob_dhcp_relay_address = "192.168.2.1"
admin_dhcp_relay_address = "192.168.252.1"

[machines.dpu-hosts]
host_count = 2
dpu_per_host_count = 2
vpc_count = 1
subnets_per_vpc = 1
dpu_reboot_delay = 20
host_reboot_delay = 20
oob_dhcp_relay_address = "192.168.2.1"
admin_dhcp_relay_address = "192.168.252.1"
```

## NICo Site Configuration

The NICo site-explorer must be configured to reach the bmc-mock endpoint:

```toml
[site_explorer]
override_target_port = 1266
```

Or via Helm values, the BMC proxy should point to:

```
machine-a-tron-bmc-mock.nico-system.svc.cluster.local:1266
```

## NoDpu State Machine Flow

When machine-a-tron runs with `dpu_per_host_count = 0`, NICo processes
each simulated host through:

```
DHCP Discovery (simulated relay with fake giaddr)
  → Site Explorer probes bmc-mock via Redfish
    → ManagedHost created (dpus: [])
      → DpuDiscoveringState (skips immediately — no DPUs)
        → HostInit/WaitingForPlatformConfiguration
          → HostInit/PollingBiosSetup
            → HostInit/SetBootOrder (NoDpu error silently ignored)
              → BomValidating/MatchingSku
                → Ready
```

## Observing Progress

### CLI Commands

```bash
# Managed hosts with state (Core gRPC)
nico-admin-cli managed-host show --all

# Machine list (REST API)
nicocli machine list --output table

# Specific machine details
nicocli machine get <machine-id>

# Expected machines
nicocli expected-machine list --output table
```

### Web UI

```
http://<carbide-api>/managed-host              # All managed hosts (HTML)
http://<carbide-api>/managed-host.json          # All managed hosts (JSON)
http://<carbide-api>/managed-host/<id>          # Host detail
http://<carbide-api>/machine/<id>/state-history # State transitions
http://<carbide-api>/expected-machine           # Expected machines
```

### What "Done" Looks Like

A successfully provisioned NoDpu host shows:
- `status: Ready`
- `isUsableByTenant: true`
- State history shows clean transitions with no error states

## Network Connectivity Requirements (In-Cluster)

machine-a-tron needs to reach:

| Endpoint | Purpose |
|---|---|
| `nico-api:1079` | NICo API for machine registration, DHCP, state machine |

NICo needs to reach:

| Endpoint | Purpose |
|---|---|
| `machine-a-tron-bmc-mock:1266` | Redfish queries from site-explorer |
| `machine-a-tron-bmc-mock:22` | BMC SSH (optional) |

All traffic stays inside the cluster. No external network setup required.

## Building the Image

machine-a-tron is a Rust binary in the upstream monorepo. Build with:

```bash
# From helm/vendor/infra-controller/
cargo build -p carbide-machine-a-tron --bin machine-a-tron --release
```

Or use the DevSpace Dockerfile at:

```
dev/deployment/devspace/Dockerfile.machine-a-tron
```

The image includes:
- `machine-a-tron` binary
- BMC mock data templates (`dell_poweredge_r750.tar.gz`, `nvidia_dpu.tar.gz`)
- Runtime: `debian:bookworm-slim` with iproute2, ca-certificates, libssl3
