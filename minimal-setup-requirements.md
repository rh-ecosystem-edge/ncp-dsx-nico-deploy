# NICo Minimal Test Bed — Resource Requirements

## Overview

Single-node test bed for NICo with:
- **Cloud side**: OCP SNO (Single Node OpenShift) running the NICo cloud profile in minimal configuration (no HA)
- **Site side**: Single DPU worker connected via BMC, zero-trust PXE, no DPF

This document covers the **cloud side** resource planning.

---

## NICo Application Components (nvidia-infra-controller-cloud namespace)

All replicas set to 1 (no HA). Components marked with `*` have **no resource
requests** in the charts — estimates are based on typical runtime behavior
under light load.

### Components with Chart-Defined Resources

| Component | CPU Req | Mem Req | CPU Lim | Mem Lim | Replicas |
|-----------|---------|---------|---------|---------|----------|
| nico-rest-api | 100m | 128Mi | 500m | 512Mi | 1 |
| nico-rest-cloud-worker | 100m | 128Mi | 500m | 512Mi | 1 |
| nico-rest-site-worker | 100m | 128Mi | 500m | 512Mi | 1 |
| nico-rest-site-manager | 50m | 64Mi | 250m | 256Mi | 1 |
| nico-rest-cert-manager | 50m | 64Mi | 250m | 256Mi | 1 |
| nico-rest-db (job) | 50m | 64Mi | 100m | 128Mi | N/A |
| **Subtotal** | **450m** | **576Mi** | **2100m** | **2176Mi** | |

### Components Without Chart-Defined Resources (Estimated)

| Component | Est. CPU | Est. Memory | Notes |
|-----------|----------|-------------|-------|
| Temporal frontend | ~200m | ~400Mi | Go, single replica |
| Temporal history | ~200m | ~400Mi | Heaviest Temporal service |
| Temporal matching | ~100m | ~256Mi | Light at low scale |
| Temporal worker | ~100m | ~256Mi | Internal housekeeping |
| Temporal admin-tools | ~50m | ~128Mi | Mostly idle |
| nico-cloud-pg (PG18) | ~250m | ~512Mi | Crunchy 1-instance, small dataset |
| temporal-pg (PG18) | ~250m | ~512Mi | Crunchy 1-instance |
| keycloak-pg (PG18) | ~100m | ~256Mi | Tiny realm DB |
| Keycloak (RHBK) | ~500m | ~768Mi | Java/Quarkus — memory hungry |
| **Subtotal** | **~1750m** | **~3.4Gi** | |

---

## OLM-Managed Operators

| Operator | Est. CPU | Est. Memory | Notes |
|----------|----------|-------------|-------|
| cert-manager | ~150m | ~384Mi | controller + webhook + cainjector (3 pods) |
| Crunchy PGO 5.8.x | ~100m | ~256Mi | Single controller pod |
| RHBK operator | ~100m | ~256Mi | Single controller pod |
| **Subtotal** | **~350m** | **~896Mi** | |

---

## NICo Workload Total

| | CPU | Memory |
|--|-----|--------|
| Chart-defined requests | 450m | 576Mi |
| Estimated (no requests set) | ~1750m | ~3.4Gi |
| Operators | ~350m | ~896Mi |
| **Total NICo workload** | **~2.5 vCPU** | **~4.8 GiB** |

---

## OCP SNO Platform Overhead

| Platform Layer | Est. CPU | Est. Memory | Notes |
|----------------|----------|-------------|-------|
| API server + etcd | ~1.5 CPU | ~4 GiB | etcd is memory-bound |
| Controllers + scheduler | ~0.5 CPU | ~1 GiB | |
| OVN/SDN networking | ~0.5 CPU | ~0.5 GiB | |
| Ingress controller | ~0.2 CPU | ~0.3 GiB | |
| DNS + node agents | ~0.3 CPU | ~0.5 GiB | |
| OLM framework | ~0.2 CPU | ~0.3 GiB | |
| Console + OAuth | ~0.3 CPU | ~0.5 GiB | |
| Monitoring (Prometheus stack) | ~2 CPU | ~4 GiB | Can disable to save ~6 GiB |
| Machine config + other | ~0.5 CPU | ~1 GiB | |
| **SNO total (monitoring ON)** | **~6 vCPU** | **~12 GiB** | |
| **SNO total (monitoring OFF)** | **~4 vCPU** | **~8 GiB** | |

---

## Grand Total & Recommendation

| Scenario | vCPUs | Memory |
|----------|-------|--------|
| Minimum viable (monitoring OFF) | ~7 vCPU | ~13 GiB |
| Comfortable (monitoring OFF, headroom) | 12 vCPU | 24 GiB |
| With monitoring ON | 16 vCPU | 32 GiB |

### Recommended: 16 vCPU / 32 GiB RAM

Rationale:
- Keycloak and Temporal spike significantly during startup (JVM warmup, schema migrations)
- The 3 PostgreSQL instances have no resource limits — without headroom they compete for memory under pressure
- SNO runs both control plane and workloads on one node, so contention is real
- 16/32 gives room to enable monitoring when debugging, and to run `oc debug` or temporary pods without eviction pressure

### Leaner Option: 12 vCPU / 24 GiB RAM

Works with monitoring disabled and the understanding that Temporal startup may
be slower and occasional PG memory pressure is possible.

### Disk

120 GiB minimum (50 GiB OCP platform + 12 GiB PG PVCs + image layers + etcd).

---

## Node Topology Options

The cloud-side workload (OCP platform + full NICo cloud profile, no HA) can be
spread across different node counts. More nodes separate the control plane from
workloads, reducing contention and improving resilience, at the cost of more
hardware and inter-node networking.

| Nodes | Topology | Per-Node Spec | Total CPU | Total RAM | Monitoring | Trade-offs |
|-------|----------|---------------|-----------|-----------|------------|------------|
| **1 (SNO)** | Control plane + all NICo on one node | 16 vCPU / 32 GiB | 16 vCPU | 32 GiB | Optional (tight if ON) | Simplest setup; no scheduling flexibility — startup spikes (Keycloak, Temporal, etcd compaction) all compete on one node |
| **2** | 1 control plane + 1 worker | CP: 8 vCPU / 16 GiB, Worker: 8 vCPU / 16 GiB | 16 vCPU | 32 GiB | OFF recommended | NICo runs on dedicated worker, no control-plane contention; CP node can be smaller since it only runs platform + operators |
| **3 (compact)** | 3 control-plane nodes (schedulable) | 8 vCPU / 16 GiB each | 24 vCPU | 48 GiB | ON comfortably | HA control plane (etcd quorum); NICo pods spread across all 3; overkill for a minimal test bed but supports monitoring and debugging tools without pressure |
| **4** | 3 control-plane + 1 dedicated worker | CP: 4 vCPU / 8 GiB each, Worker: 8 vCPU / 16 GiB | 20 vCPU | 40 GiB | ON comfortably | Full HA control plane with clean workload isolation; most resilient but heaviest footprint — only justified if you need control-plane HA for the test bed |

### Notes

- **1 node (SNO)** is the recommended choice for this minimal test bed — it
  satisfies all requirements with a single 16/32 machine and avoids the
  complexity of multi-node networking and storage.
- **2 nodes** is the sweet spot if you have the hardware and want to avoid
  control-plane contention during NICo startup storms.
- **3-4 nodes** provide HA control plane (etcd quorum requires 3 members) but
  are unnecessary for a test bed with no HA requirement on the application side.
- Disk per node: 120 GiB for SNO; for multi-node, 80 GiB per CP node +
  120 GiB for worker nodes hosting PG PVCs.
