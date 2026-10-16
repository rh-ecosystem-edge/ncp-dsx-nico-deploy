<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# End-to-End Test: NICo + KubeVirt + vbmc-rs + Metal3 on self-managed SNO

> **⚠️ UNVALIDATED**: This runbook covers the KubeVirt track which has not been
> recently validated against the current codebase. It is preserved for reference
> only. The actively maintained e2e runbook is
> [`docs/e2e-libvirt-openshift.md`](docs/e2e-libvirt-openshift.md).
> Credentials and passwords shown below (e.g. `nicolab`, `admin`) are lab
> placeholders only — **do not use in production**.

**Status:** Phases 0–8 complete (2026-09-21). The `make e2e-*` targets are
defined incrementally as each phase is built. Two parallel provisioning tracks
are planned: **Track 1** (NICo is the authoritative provisioner, BMO is a passive
inventory layer) and **Track 2** (NICo is the hardware intelligence oracle,
Ironic is the OS deployer, BMO fully manages post-provisioning). Track 1 Phases
9–10 are next; Track 2 Phases 11–12 follow.

## Goal

Provision an OpenShift **worker node** end-to-end through the real NICo
hardware path — no physical servers — on a **self-managed Single-Node
OpenShift (SNO)** cluster running in a libvirt VM. A nested KubeVirt VM stands
in for the bare-metal host; `vbmc-rs` presents it as a Redfish BMC; NICo
discovers it, drives it to `Ready`, and (on tenant instance allocation)
PXE-installs **RHCOS + OpenShift worker ignition** so the VM joins the cluster;
Metal3 **adopts** the result as a `BareMetalHost`.

This is the hardware-backed sibling of
[`machine-a-tron-testing-guide.md`](machine-a-tron-testing-guide.md): it swaps
NICo's internal `bmc-mock` for **real KubeVirt VMs fronted by vbmc-rs**, and
extends past `Ready` into an actual node join and Metal3 reflection.

## Why SNO instead of CRC (platform decision, 2026-09-14)

CRC *is* single-node OpenShift under the hood — same OVN, same MCS firewall,
same components — but it is **packaged and frozen** for laptop use and is
explicitly not meant to gain nodes. The blockers hit during the CRC de-risk
spike were all CRC-packaging artifacts, not OpenShift limitations:

- `api-int.crc.testing` resolves to the `br-ex` address (192.168.127.2) from
  cluster context, not the machine-network node IP.
- The libvirt network is fixed and not meant to be extended; a second host on
  the machine L2 can't easily be placed.
- MCS (`22623/22624`) has `REJECT` rules — but **only in the FORWARD and OUTPUT
  chains, not INPUT**. A host sitting *on the machine network* and connecting to
  the node's machine IP directly (an INPUT-path connection) is allowed; the CRC
  spike only failed because the traffic was routed (FORWARD) or from the node's
  own OUTPUT path.

A self-managed SNO removes all three: **we own the machine network, DNS
(`api`/`api-int`/`*.apps`), and DHCP**, and worker expansion is a *documented,
supported* Red Hat procedure ("Adding worker nodes to single-node OpenShift").
The same MCS firewall exists, but on the machine-network INPUT path it behaves
as designed. Cost: install time and we run DNS/networking ourselves — cheap on
this host (32 cores, 125 GB, ~113 GB free; CRC already torn down).

**Worker model: (A) nested KubeVirt VMs + standalone vbmc-rs (KubeVirt API
backend).** The "bare-metal host" is a KubeVirt VM inside SNO; a standalone
vbmc-rs presents it as a Redfish BMC and drives power via the KubeVirt
subresource API (start/stop/restart). This is the only model that powers on a
*stopped* VM (see decision #5). (Rejected: the vbmc-rs sidecar+aggregator model —
per-VM libvirt sidecar in virt-launcher + aggregator — which can't list or start
a stopped VM; and host-libvirt sibling VMs, which diverge from the KubeVirt-native
shape. Sidecar hot-telemetry is folded into the future smart-hybrid,
fabiendupont/vbmc-rs#26.)

## Two provisioning tracks

Both NICo and Ironic are OS-agnostic provisioners — both can install RHCOS,
plain RHEL, Ubuntu, or any cloud image. The differentiator is **who owns the
machine lifecycle**, not the OS choice.

**Track 1 — NICo is the authoritative provisioner (Phases 9–10):**
NICo owns discovery → attestation → BIOS config → OS install (nico-pxe +
qcow-imager or coreos-installer) → OCP join. BMO is a passive inventory
reflection layer (`externallyProvisioned: true`); Ironic does not participate.
MAPNI (Phase 10) automates the NICo REST API calls that drive this lifecycle.

**Track 2 — NICo as hardware oracle, Ironic as OS deployer (Phases 11–12):**
NICo owns the hardware-intelligence layer: Scout discovery, TPM attestation,
BIOS drift detection, BMC credential rotation, GPU health inventory. Once the
machine reaches `Ready`, NICo's role ends. A handoff controller pushes NICo
hardware data to `BareMetalHost` annotations/labels, then Ironic takes over:
boots IPA (via virtual media in our setup), writes any OS image (plain RHEL,
Ubuntu, or RHCOS without ignition), cloud-init handles first-boot. BMO fully
manages the machine post-provisioning (power, reprovisioning, decommission).

Key challenge in Track 2: nico-pxe and Ironic's ramdisk-server both want to
serve the provisioning segment. The handoff requires silencing nico-pxe for the
target machine's MAC once NICo reaches `Ready`, then letting Ironic's IPA boot
via virtual media (which bypasses PXE entirely in `provisioningNetwork: Disabled`
mode — Ironic mounts its IPA ISO via Redfish VirtualMedia).

## Chain

### Track 1 (NICo provisions)

```
KubeVirt VM  (blank disk + NICs on NICo provisioning L2 + machine L2; nested in SNO)
   ▲ Redfish: power on/off/cycle (real), boot-override (accepted/echoed)
vbmc-rs  (standalone; KubeVirt API backend → start/stop/restart subresources)
   ▲ Redfish power/boot-order  +  PXE/iPXE + DHCP on provisioning L2
NICo site  (nico-api discovers via BMC → Scout discovery OS → Ready
            → tenant instance allocate w/ openshift-coreos template + qcow-imager
            → VM boots RHCOS installer → coreos-installer writes disk → reboots
            → ignition from MCS → joins OpenShift as worker node)
   ▲ NICo REST API (nicocli / MAPNI Phase 10)
Metal3/BMO  (ExternallyProvisioned: NICo provisioned, BMO reflects inventory)
   ▼
OpenShift (SNO): worker node Ready (192-168-253-12.nico.local, v1.35.6)
```

### Track 2 (NICo discovers, Ironic provisions)

```
KubeVirt VM  (blank disk + NICs on NICo provisioning L2 + machine L2; nested in SNO)
   ▲ Redfish power/boot-order
vbmc-rs  (standalone; KubeVirt API backend)
   ▲ Redfish (discovery phase: NICo)
NICo site  (Scout discovery → attestation → GPU inventory → Ready)
   ▼ hardware data (GPU, BIOS, attestation result) pushed to BMH annotations
handoff controller  (future; creates BMH from NICo machine at Ready)
   ▼
Metal3/BMO + Ironic  (IPA boots via Redfish VirtualMedia → writes OS image → cloud-init)
   ▼
Provisioned host: plain RHEL / Ubuntu / RHCOS (not necessarily an OCP node)
```

## Key design decisions (evidence-backed)

1. **NICo provisions; Metal3 adopts.** NICo owns OS deployment via its own
   PXE/iPXE + Redfish boot-order/power. The provider's BMH mapper hard-codes
   `ExternallyProvisioned: true` and sets no `spec.Image`
   (`machine-api-provider-nvidia .../baremetalhost/mapper.go:79`), i.e. the BMH
   is inventory, not a provisioning driver. Provider is used **as-is**.

2. **Provisioning is PXE/iPXE + Redfish boot-order — NOT virtual media.**
   NICo sets boot source via Redfish (`set_boot_override`,
   `change_boot_order`, targeting a NIC by MAC —
   `infra-controller/crates/redfish/src/libredfish/instrumented.rs:239-307`),
   power-cycles (`crates/machine-controller/src/redfish.rs`), and the host
   netboots NICo's iPXE server. Virtual media exists only in NICo's
   `crates/bmc-mock` test harness, not the production path.

3. **RHCOS worker join uses the raw-iPXE tenant OS variant.**
   `InstanceOperatingSystemConfig` (proto
   `rest-api/proto/core/src/v1/nico_nico.proto:3073`) is a `oneof` of
   `InlineIpxe` / `os_image_id` / `operating_system_id`, and the tenant path is
   OS-agnostic by design (`docs/glossary.md:30-36`). Use `InlineIpxe` pointing
   at the RHCOS live kernel/initramfs with `coreos.inst.*` +
   `ignition.config.url`. **Ignition rides in kernel args**, not the NICo
   `user_data` field (that field is cloud-init, which RHCOS ignores).

4. **vbmc-rs boot-override is a functional no-op — the VM's static bootOrder
   drives PXE.** vbmc-rs accepts/echoes a `Pxe` `BootSourceOverrideTarget`
   (`vbmc-rs src/redfish/systems.rs:446,655`) but no libvirt/KubeVirt backend
   acts on it (only the `Cd`+virtual-media path does, `power.rs:40`). NICo's
   real dependency — Redfish **power-cycle** — *is* implemented
   (`vm_boot`/`vm_reboot`). So: configure the KubeVirt VM's `bootOrder` with the
   **provisioning NIC first** (blank disk falls through to PXE anyway); NICo's
   ignored override + real power-cycle yields a netboot; once RHCOS is on disk,
   it boots from disk. No vbmc-rs code change required for v1. (Future
   enhancement: honor `Pxe`/`UefiTargetBootSourceOverride` in the libvirt
   backend — vbmc-rs is our repo, but out of scope here.)

5. **vbmc-rs KubeVirt API backend (not sidecar+aggregator).** A standalone
   vbmc-rs (`backend = "kube_virt"`) maps Redfish power to the KubeVirt
   subresource API (`virtualmachines/start|stop|restart`). This is the only model
   that can power on a **stopped** VM — the sidecar+aggregator model discovers
   only *ready virt-launcher pods*, and a stopped VM has no VMI/pod/libvirtd/
   domain, so it can't even list it. NICo/Metal3 need exactly a boot-from-off via
   Redfish, so the API backend is required. vbmc-rs firmware is synthetic and
   backend-independent, so RMS gets the same firmware surface as in sidecar mode;
   the sidecar's only edge — hot telemetry on *running* VMs — isn't consumed here.
   The smart-hybrid (aggregator doing API lifecycle **and** proxying to a sidecar
   when the VM is up) is tracked upstream: fabiendupont/vbmc-rs#26. Deployed
   CUDN-homed (nico-bmc, no ClusterIP), dual-homed like RMS: default net
   northbound (kube-apiserver subresource calls), nico-bmc southbound (BMC).

6. **Zero-DPU / HostInband mode.** Same host model machine-a-tron uses
   (`dpu_per_host_count = 0`, HostInband segment) so a NoDpu host can reach
   `Ready` and be allocated — no simulated/real DPU needed.

## SNO cluster & sizing

Host (measured 2026-09-14): 32 cores, 125 GB RAM (~113 GB free), CRC torn down.
Tooling present: `openshift-install` 4.20.8, `oc`/`kubectl` (`~/.local/bin`),
`virsh`/`virt-install`/`qemu-img`/`genisoimage`/`nmcli`, pull secret at
`~/pull-secret.json`.

| Component | Footprint | Notes |
|---|---|---|
| SNO VM | 16 vCPU / 40 GB / 120 GB disk | `host-passthrough` CPU for **nested virt** |
| CNV/KubeVirt | in-cluster | KVM-accelerated via nested virt |
| NICo cloud + site | in-cluster | REST/Temporal/PG + Core/Vault/NATS/PG |
| Metal3 (BMO/Ironic) | in-cluster | adoption only |
| Nested worker VM(s) | ~8 GB / 2–4 vCPU each | one to start |

Total comfortably under 113 GB. SNO's 40 GB is the practical floor for the full
NICo + CNV + Metal3 stack plus one worker VM; bump if a second worker is added.

## Networking design (now fully under our control)

A dedicated libvirt NAT network is the machine network; **we run its DNS and
DHCP** (libvirt's dnsmasq), so `api`/`api-int`/`*.apps` resolve to the SNO node
IP and there is no br-ex indirection.

- **Cluster / machine network** `nico-e2e` (proposed `192.168.130.0/24`):
  - SNO node: static `192.168.130.10` (MAC-reserved DHCP lease).
  - DNS records (libvirt dnsmasq): `api.sno.nico.test` →`.10`,
    `api-int.sno.nico.test` → `.10`, wildcard `*.apps.sno.nico.test` → `.10`
    (via `<dnsmasq:options>address=/apps.sno.nico.test/192.168.130.10`).
  - Base domain `nico.test`, cluster name `sno` (→ `sno.nico.test`).
- **NICo provisioning segment(s)** — VM provisioning NIC + `nico-dhcp` (Kea) +
  `nico-pxe` reachable on an OVN secondary network (NAD/CUDN) inside SNO, as in
  the machine-a-tron config (`oob`/`admin`/`host_inband`). Kea advertises
  DNS/NTP/provisioning (option 6) pointing at the real `nico-dns`/`nico-pxe`
  addresses (`helm/values/nico-core.yaml`).
- **BMC network** — vbmc-rs aggregator reachable at the BMC IP NICo expects
  (`ExpectedMachine.bmc_ip_address` / MAC → credential lookup); vbmc-rs's chart
  provisions a CUDN for its BMC net (`bmcNetwork.cudn`).
- **Worker node IP** — the nested worker VM gets an IP on the **cluster/machine
  network** (`192.168.130.0/24`) so the SNO control plane reaches kubelet:10250
  and MCS via the INPUT path. Bridge/macvlan onto the SNO VM's machine NIC, or a
  second libvirt network the worker VM also attaches to.

## SNO install (agent-based, Phase 0)

1. Create libvirt network `nico-e2e` with our DNS records + a MAC-reserved lease
   for the SNO node.
2. `install-config.yaml`: 1 control-plane replica, 0 compute, `platform: none`,
   `baseDomain: nico.test`, `metadata.name: sno`,
   `machineNetwork: 192.168.130.0/24`, `~/pull-secret.json`, SSH key.
3. `agent-config.yaml`: `rendezvousIP: 192.168.130.10`, host entry mapping the
   SNO VM MAC → `.10`.
4. `openshift-install agent create image` → `agent.x86_64.iso`.
5. `virt-install` the SNO VM (16 vCPU / 40 GB / 120 GB, `host-passthrough`, NIC
   on `nico-e2e` with the reserved MAC) booting the ISO.
6. `openshift-install agent wait-for install-complete`; export kubeconfig.

## Phased plan (each phase = Make target(s) + a runbook section)

| Phase | Track | Target(s) | Outcome | Status |
|---|---|---|---|---|
| 0. SNO + prereqs | — | `e2e-sno`, `e2e-prereqs` | SNO up (agent-based, OCP 4.22.9); CNV (KVM-accelerated) + CDI; MetalLB | ✅ done |
| 1. NICo cloud | — | `deploy-all-cloud` + post-deploy | Management plane up; org bootstrapped | ✅ done |
| 2. NICo site | — | `deploy-all-site` (no MAT) | Site plane up, `siteConfig` for real hosts (zero-DPU/HostInband) | ✅ done |
| 3. Networks (spike) | — | `e2e-networks` | FRR ToR + MetalLB VIPs; DHCP relay on ToR; provisioning + BMC L2 proven | ✅ done |
| 4. KubeVirt VM | — | `e2e-vms` | Blank-disk VM, provisioning NIC first in `bootOrder`, machine NIC on nico-e2e | ✅ done |
| 5. vbmc-rs | — | `e2e-vbmc` | vbmc-rs (KubeVirt API backend); Redfish BMC at 192.168.2.20; power/cycle working | ✅ done |
| 6. Discover→Ready | — | `e2e-run` / `e2e-status` | unbound .forge DNS; Scout discovers → `Ready` (V29); qcow-imager.efi in blob tree | ✅ done |
| 7. Allocate + join | T1 | `e2e-allocate` | NICo instance (openshift-coreos template); coreos-installer via nico-pxe; worker joins OCP | ✅ done 2026-09-21 |
| 8. BMO — adopt existing | T1 | `e2e-bmo` | BMO deployed; `BareMetalHost` ExternallyProvisioned; BMO power-controls via Redfish (vbmc-rs ClusterIP) | ✅ done 2026-09-21 |
| 9. NICo — fresh provision cycle | T1 | `e2e-reprovision` | Decommission existing instance; NICo re-discovers + re-provisions new worker from scratch; BMO re-adopts | ✅ done 2026-09-21 (⚠ booted existing RHCOS — UEFI HTTP Boot path needs fix) |
| 10. MAPNI — full integration | T1 | `e2e-mapni` | MAPNI deployed; `Machine` CRD → NICo allocation → BMH sync → OCP worker; full declarative lifecycle | planned |
| 11. Ironic — plain Linux provision | T2 | `e2e-ironic` | NICo discovers + attests new VM → Ready; Ironic provisions plain RHEL via IPA + virtual media + cloud-init; BMO fully manages | planned |
| 12. Handoff controller | T2 | `e2e-handoff` | Automated handoff: NICo hardware data (GPU, attestation) pushed to BMH annotations on Ready; Ironic triggered | planned |
| — | — | `e2e-clean` | Tear down VMs, vbmc-rs, networks, instance | |

### Key learnings from Phases 6–7 (captured for Phase 8+)

- **vbmc-rs vendor**: must be set to `"redvirt"` in `[defaults]` so NICo's
  site-explorer recognises the emulator (NICO-SITEEXPLORER-122 otherwise).
- **WaitingForRebootToReady DB unlock**: the site-explorer does not detect
  a ForceRestart power-cycle event; manually set `restart_verified=true` in
  the machines table via psql to unblock the state machine.
- **nicocli wrapper**: `hack/nicocli` auto-fetches the Keycloak token and
  mounts the OCP ingress CA (`~/.config/nico/ocp-ingress-ca.crt`).
  REST API allocation sequence: InstanceType → machine association →
  Allocation (Reserved constraint) → VPC (FLAT) → OperatingSystem →
  Instance (targeted by machineId, autoNetwork=true).
- **RHCOS rootfs**: serve from nico-pxe blob tree (downloaded via pod network
  at 227 MB/s) not from the internet via the worker's provisioning NIC
  (~1.5 MB/s through the ToR chain).
- **Provisioning NIC never-default**: MachineConfig
  `10-worker-provisioning-nic-never-default` (ipv4.never-default=true on
  02:00:00:AA:CC:01) is required so NetworkManager does not install the
  provisioning gateway as the preferred default route — that gateway has no
  internet access and blocks nodeip-configuration from pulling OCP images.
- **libvirt nico-e2e dnsmasq**: add `address=/carbide-pxe.forge/192.0.2.13`
  etc. as `<dnsmasq:options>` so the machine NIC's DNS resolver knows the
  `.forge` names. Do NOT use `server=/forge/` forwarding — the host routing
  does not reach MetalLB VIPs.
- **UEFI HTTP Boot DHCPOFFER not reaching VM (Phase 9 fresh install blocker)**:
  nico-dhcp sends DHCPOFFER to 192.168.253.1:67 (ToR relay). ToR dnsmasq
  forwards it as a broadcast on net1. But the broadcast doesn't reach the VM
  through the nicoprov0 OVN secondary bridge — the VM's provisioning NIC MAC
  (02:00:00:aa:cc:01) is not in the nicoprov0 FDB, so the DHCPOFFER is dropped
  at the bridge. As a result UEFI HTTP Boot fails after a few DISCOVERs and the
  machine falls back to disk (existing RHCOS), re-joining OCP without a fresh
  install. Suspected cause: the veth connecting the VM's prov NIC to nicoprov0
  may not be learning the VM MAC (promisc/FDB issue similar to the machine-net0
  promisc issue from Phase 7). Fix to investigate: `ip link set nicoprov0 promisc on`
  on the SNO node, or check that the veth on nicoprov0 is in the right bridge
  VLAN / FDB state.
- **nico-e2e network restart hazard**: `net-destroy + net-start` disconnects
  all VM vnet interfaces; hot-detach/reattach each NIC on nico-sno AND nico-tor
  after restart. Add a static DHCP reservation for the ToR MAC (52:54:00:f2:a0:01
  → 192.168.130.5) before restarting; update MetalLB BGPPeer if the ToR IP
  changes.
- **WaitingForRebootToReady (provisioning AND decommission)**: NICo's
  site-explorer polls Redfish for power state but **never creates a Redfish
  event subscription** on vbmc-rs (`/redfish/v1/EventService/Subscriptions` is
  always empty). vbmc-rs push delivery IS implemented (src/events/subscriptions.rs
  + reqwest POST to subscriber endpoint), but NICo never subscribes. As a result
  the site-explorer misses ForceRestart/On transitions and the machine stalls in
  `WaitingForRebootToReady`. Fix: `UPDATE machines SET last_reboot_requested =
  jsonb_set(last_reboot_requested, '{restart_verified}', 'true'), last_reboot_time
  = NOW() WHERE id = '<machine_id>';` via psql on nico-site-pg. Required both
  during instance boot (Phase 7) and during instance decommission (Phase 9).
  Upstream fix: NICo site-explorer should `POST /redfish/v1/EventService/Subscriptions`
  on BMC discovery to receive push notifications.
- **Crunchy PG SCC loss after reboot**: After SNO reboot or PGO pod force-delete,
  the `anyuid` SCC ClusterRoleBinding for postgres service accounts is lost.
  Fix: `oc adm policy add-scc-to-user anyuid system:serviceaccount:nico-rest:nico-cloud-pg-instance
  system:serviceaccount:nico-rest:nico-cloud-pg-pgbackrest` (and same for
  nico-system/nico-site-pg-*). Then annotate the StatefulSets to force pod
  recreation.
- **SNO disk pressure (85% threshold)**: After extended use the 120 GB SNO VM
  disk fills up (container image overlay + 25 GB worker VM disk + hostpath PVCs).
  Fix: `sudo virsh blockresize nico-sno /path/to/sno.qcow2 180G` (online resize),
  then `sudo growpart /dev/vda 4 && sudo xfs_growfs /var` inside the SNO VM.
- **Worker VM runStrategy**: KubeVirt VM has `runStrategy: Always` which causes it
  to auto-restart on SNO reboot and re-join OCP as an unexpected worker node,
  attracting pod scheduling. During Phase 9 decommission, set to `Halted` after
  stopping; reset to `Manual` before reprovisioning.
- **Pod scheduling to dead worker**: If the worker node is NotReady/deleted but
  pods were recently scheduled there, force-delete all stranded pods with
  `oc get pods -A --field-selector=spec.nodeName=<dead-node>` + `oc delete pod
  --force --grace-period=0`. Also delete crashlooping pods that started on the
  dead node so they reschedule to SNO.

Existing cloud/site targets are reused verbatim; new `e2e-*` targets cover only
the SNO/KubeVirt/vbmc-rs/Metal3 additions and orchestration.

## Runbook — exact command sequences

All commands assume:
- `export KUBECONFIG=~/nico-e2e-sno/install/auth/kubeconfig`
- `REPO=~/Code/github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy`
- Host prerequisites: `virsh`, `virt-install`, `qemu-img`, `genisoimage`,
  `openshift-install` 4.20+, pull secret at `~/pull-secret.json`
- Resource IDs (MACHINE_ID, INSTANCE_TYPE_ID, SITE_ID, TENANT_ID, VPC_ID, OS_ID)
  are cluster-specific and fetched via `nicocli` after each fresh deployment.
  The values from the 2026-09-21 install are documented in the Phase 7 runbook
  section for reference, but **will differ on every rebuild**.

### Phase 0: Libvirt networks

Three networks are needed:

**nico-e2e** (machine/cluster network, NAT, 192.168.130.0/24):
```xml
<!-- Save as /tmp/nico-e2e.xml -->
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>nico-e2e</name>
  <forward mode='nat'><nat><port start='1024' end='65535'/></nat></forward>
  <bridge name='virbr-nico' stp='on' delay='0'/>
  <domain name='nico.test' localOnly='yes'/>
  <dns>
    <host ip='192.168.130.10'>
      <hostname>api.sno.nico.test</hostname>
      <hostname>api-int.sno.nico.test</hostname>
    </host>
  </dns>
  <ip address='192.168.130.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.130.20' end='192.168.130.200'/>
      <!-- SNO node gets .10 by MAC -->
      <host mac='52:54:00:e2:e0:10' name='sno' ip='192.168.130.10'/>
      <!-- ToR gets .5 by MAC (prevents BGPPeer break on network restart) -->
      <host mac='52:54:00:f2:a0:01' name='nico-tor' ip='192.168.130.5'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/apps.sno.nico.test/192.168.130.10'/>
    <!-- .forge DNS for provisioning-NIC path (machine NIC uses these) -->
    <dnsmasq:option value='address=/carbide-pxe.forge/192.0.2.13'/>
    <dnsmasq:option value='address=/carbide-static-pxe.forge/192.0.2.13'/>
    <dnsmasq:option value='address=/carbide-api.forge/192.0.2.10'/>
  </dnsmasq:options>
</network>
```
```bash
sudo virsh net-define /tmp/nico-e2e.xml
sudo virsh net-autostart nico-e2e
sudo virsh net-start nico-e2e
```

**nico-prov** (provisioning L2, isolated, no DHCP — dnsmasq relay on ToR serves it):
```bash
sudo virsh net-define /dev/stdin <<'EOF'
<network>
  <name>nico-prov</name>
  <bridge name='virbr-prov' stp='on' delay='0'/>
</network>
EOF
sudo virsh net-autostart nico-prov
sudo virsh net-start nico-prov
```

### Phase 0: ToR VM

Uses RHEL 9.8 KVM guest image with cloud-init. Download to `~/Downloads/rhel-9.8-x86_64-kvm.qcow2`.

```bash
mkdir -p ~/nico-e2e-sno/spike-frr
cp ~/Downloads/rhel-9.8-x86_64-kvm.qcow2 ~/nico-e2e-sno/spike-frr/nico-tor.qcow2
qemu-img resize ~/nico-e2e-sno/spike-frr/nico-tor.qcow2 20G
```

Create `~/nico-e2e-sno/spike-frr/user-data`:
```yaml
#cloud-config
hostname: nico-tor
fqdn: nico-tor.nico.test
ssh_pwauth: true
users:
  - name: cloud-user
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: nicolab
write_files:
  - path: /etc/sysctl.d/99-ipforward.conf
    content: |
      net.ipv4.ip_forward=1
  - path: /root/frr.conf
    content: |
      frr defaults traditional
      hostname nico-tor
      log syslog informational
      !
      router bgp 64512
       bgp router-id 192.168.130.5
       no bgp ebgp-requires-policy
       neighbor 192.168.130.10 remote-as 64513
       address-family ipv4 unicast
        neighbor 192.168.130.10 activate
       exit-address-family
      !
      line vty
runcmd:
  - sysctl --system
  - dnf -y install frr dnsmasq iproute tcpdump bind-utils
  - install -m0640 -o frr -g frr /root/frr.conf /etc/frr/frr.conf
  - sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
  - systemctl enable --now frr
```

Create `~/nico-e2e-sno/spike-frr/network-config`:
```yaml
version: 2
ethernets:
  net0:
    match:
      macaddress: "52:54:00:f2:a0:01"
    set-name: net0
    addresses: [192.168.130.5/24]
    routes:
      - to: 0.0.0.0/0
        via: 192.168.130.1
    nameservers:
      addresses: [192.168.130.1, 1.1.1.1]
  net1:
    match:
      macaddress: "52:54:00:f2:a0:02"
    set-name: net1
    addresses: [192.168.253.1/24]
```

```bash
# Create seed ISO for cloud-init
echo "instance-id: nico-tor" > ~/nico-e2e-sno/spike-frr/meta-data
genisoimage -output ~/nico-e2e-sno/spike-frr/seed.iso \
  -volid cidata -joliet -rock \
  ~/nico-e2e-sno/spike-frr/user-data \
  ~/nico-e2e-sno/spike-frr/meta-data \
  ~/nico-e2e-sno/spike-frr/network-config

# Create ToR VM (sudo required — must be in system libvirt session, not user session)
sudo virt-install --name nico-tor \
  --memory 2048 --vcpus 2 \
  --disk ~/nico-e2e-sno/spike-frr/nico-tor.qcow2 \
  --disk ~/nico-e2e-sno/spike-frr/seed.iso,device=cdrom \
  --network network=nico-e2e,mac=52:54:00:f2:a0:01 \
  --network network=nico-prov,mac=52:54:00:f2:a0:02 \
  --os-variant rhel9-unknown --import --noautoconsole
```

After first boot, configure the dnsmasq DHCP relay for the provisioning segment:
```bash
# SSH to ToR
ssh cloud-user@192.168.130.5  # password: nicolab

sudo tee /etc/dnsmasq.d/nico-relay.conf <<'EOF'
# NICo e2e DHCP relay: giaddr 192.168.253.1 (net1), relay to nico-dhcp MetalLB VIP.
# IMPORTANT: do NOT add bind-interfaces here — nico-dhcp replies arrive via net0
# (machine network) addressed to 192.168.253.1, not via net1 directly.
# bind-interfaces causes SO_BINDTODEVICE=net1 which drops those replies.
port=0
interface=net1
dhcp-relay=192.168.253.1,192.0.2.11
log-dhcp
EOF
sudo systemctl enable --now dnsmasq
```

### Phase 0: SNO VM

```bash
mkdir -p ~/nico-e2e-sno/install
```

Create `~/nico-e2e-sno/install-config.yaml`:
```yaml
apiVersion: v1
baseDomain: nico.test
metadata:
  name: sno
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 192.168.130.0/24
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '<contents of ~/pull-secret.json>'
sshKey: '<contents of ~/.ssh/id_rsa.pub>'
```

Create `~/nico-e2e-sno/agent-config.yaml`:
```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: sno
rendezvousIP: 192.168.130.10
hosts:
- hostname: sno
  interfaces:
  - name: enp1s0
    macAddress: 52:54:00:e2:e0:10
  networkConfig:
    interfaces:
    - name: enp1s0
      type: ethernet
      state: up
      mac-address: 52:54:00:e2:e0:10
      ipv4:
        enabled: true
        address:
        - ip: 192.168.130.10
          prefix-length: 24
        dhcp: false
      ipv6:
        enabled: false
    # Provisioning uplink — no IP during install; bridge (nicoprov0) configured post-install
    - name: enp2s0
      type: ethernet
      state: up
      mac-address: 52:54:00:e2:e0:11
      ipv4:
        enabled: false
      ipv6:
        enabled: false
    # Machine-net bridge uplink — no IP during install; bridge configured post-install
    # ALL NICs on the same subnet must have ipv4.enabled: false or the agent installer
    # raises "Address networks are overlapping" and refuses to install.
    - name: enp3s0
      type: ethernet
      state: up
      mac-address: 52:54:00:a4:c3:99
      ipv4:
        enabled: false
      ipv6:
        enabled: false
    dns-resolver:
      config:
        server:
        - 192.168.130.1
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: 192.168.130.1
        next-hop-interface: enp1s0
```

```bash
# Create agent ISO
cp ~/nico-e2e-sno/install-config.yaml ~/nico-e2e-sno/install/
cp ~/nico-e2e-sno/agent-config.yaml ~/nico-e2e-sno/install/
openshift-install agent create image --dir ~/nico-e2e-sno/install/

# Create SNO disks: OS disk (180G) + LVM storage disk (200G for Crunchy PG, Vault, NATS PVCs)
qemu-img create -f qcow2 ~/nico-e2e-sno/sno.qcow2 180G
qemu-img create -f qcow2 ~/nico-e2e-sno/sno-lvm.qcow2 200G

# Create SNO VM (3 NICs: machine, provisioning uplink, machine-net bridge; 2 disks)
sudo virt-install --name nico-sno \
  --memory 40960 --vcpus 16 \
  --cpu host-passthrough \
  --disk ~/nico-e2e-sno/sno.qcow2,bus=virtio \
  --disk ~/nico-e2e-sno/sno-lvm.qcow2,bus=virtio \
  --disk ~/nico-e2e-sno/install/agent.x86_64.iso,device=cdrom \
  --network network=nico-e2e,mac=52:54:00:e2:e0:10 \
  --network network=nico-prov,mac=52:54:00:e2:e0:11 \
  --network network=nico-e2e,mac=52:54:00:a4:c3:99 \
  --os-variant rhel9-unknown --import --noautoconsole \
  --boot hd,cdrom

# Wait for install (30-60 min)
openshift-install agent wait-for install-complete --dir ~/nico-e2e-sno/install/
export KUBECONFIG=~/nico-e2e-sno/install/auth/kubeconfig
```

### Phase 0: OCP pre-requisites

**Step 1 — LVM Storage (CSI for Crunchy PG, Vault, NATS PVCs).**
The second disk (`vdb`/200G) must be dedicated to LVM. `hostpath-csi` is NOT used —
it requires `privileged` SCC for workloads; LVM Storage isolates privilege to the CSI
daemonset only, and workloads consume ordinary PVCs without elevated access.

```bash
# Install LVM Storage operator
oc apply -f - << 'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  channel: stable-4.22
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for operator
until oc get csv -n openshift-storage 2>/dev/null | grep -q Succeeded; do sleep 10; done

# Create LVMCluster targeting vdb
oc apply -f - << 'EOF'
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
      deviceSelector:
        paths:
        - /dev/vdb
      default: true
EOF

# Wait for lvms-vg1 StorageClass
until oc get storageclass lvms-vg1 2>/dev/null | grep -q lvms; do sleep 10; done
echo "lvms-vg1 StorageClass ready"
```

**Step 2 — CNV (KubeVirt/HyperConverged Operator) for nested worker VMs.**

```bash
oc apply -f - << 'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cnv-operatorgroup
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

until oc get csv -n openshift-cnv 2>/dev/null | grep -q Succeeded; do sleep 15; done

oc apply -f - << 'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

until oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; do
  sleep 15
done
echo "CNV ready"
```

**Step 3 — NICo prereqs (OLM operators + ClusterIssuers).**

```bash
cd $REPO
# Grant anyuid SCC to Crunchy PG (RHBK operator installs this but sometimes loses it)
# Note: run again after any SNO reboot — see Post-reboot recovery section
oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:nico-rest:nico-cloud-pg-instance \
  system:serviceaccount:nico-rest:nico-cloud-pg-pgbackrest \
  system:serviceaccount:nico-system:nico-site-pg-instance \
  system:serviceaccount:nico-system:nico-site-pg-pgbackrest

make deploy-prereqs     # OLM operators: cert-manager, Crunchy PG, RHBK, ESO, MetalLB
```

### Phase 1: NICo cloud

```bash
cd $REPO
make deploy-cloud-infra  # PG + Keycloak + Temporal + Routes + ESO
# Keycloak route CA cert is now injected automatically via the post-install hook
# (infra-cloud/templates/keycloak-route.yaml, hook-weight 15, after setup-issuers).
# No manual patch step needed.
DEPLOY_IMAGE_REPO=quay.io/fdupont-redhat make deploy-cloud  # nico-rest chart
# Bootstrap org (see CLAUDE.md for full token fetch sequence)
```

### Phase 2: NICo site

`make deploy-site E2E=1` handles Phases 2–4 in one command:
- Installs NMState operator and applies NNCPs (nicoprov0/enp2s0, machine-net0/enp3s0,
  node-default-gw-tor)
- Applies BMC CUDN (nico-bmc, 192.168.2.0/24)
- Creates the blank-disk worker VM
- Deploys NICo site chart with E2E overlay (boot artifacts seeding, siteConfig, unbound)

```bash
cd $REPO
# Grant site PG SCC (needed before PG pods can start)
oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:nico-system:nico-site-pg-instance \
  system:serviceaccount:nico-system:nico-site-pg-pgbackrest

DEPLOY_IMAGE_REPO=quay.io/fdupont-redhat make deploy-site E2E=1

# Enable promisc on bridge uplinks (transient — re-apply after SNO reboot)
# Required so unicast DHCP replies reach the worker VM through the Linux bridges
# (NMState accept-all-mac-addresses not supported on this OCP version)
ssh core@192.168.130.10 "
sudo ip link set enp2s0 promisc on && sudo ip link set nicoprov0 promisc on
sudo ip link set enp3s0 promisc on && sudo ip link set machine-net0 promisc on
"

# Vault init (one-time after first site deploy)
make vault-init

# Register site and deploy site agent
make deploy-site-agent SITE_NAME=nico-e2e
```

### Phase 5: vbmc-rs

The nico-bmc CUDN was already applied by `make deploy-site E2E=1` above.

```bash
cd $REPO
oc apply -f helm/openshift/e2e-vbmc.yaml
# Verify Redfish BMC is reachable
VBMC_IP=$(oc get svc vbmc-rs-redfish -n nico-system -o jsonpath='{.spec.clusterIP}')
curl -sk -u admin:admin "https://$VBMC_IP:8443/redfish/v1/Systems/nico-worker-0" | \
  python3 -m json.tool | grep -E '"PowerState"|"Id"'
```

### Phase 6: Discover → Ready (Scout)

The E2E site config (Scout boot artifacts, siteConfig, unbound) is already deployed
by `make deploy-site E2E=1` above.

**Step 1 — Issue admin CLI credentials from nico-admin-ca.**

The nico-admin-ca Certificate and Issuer are created by the infra-site chart
(`make deploy-site-infra`). Issue a leaf cert and populate `~/.config/nico/`:
```bash
oc apply -f - << 'CERT'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nico-admin-cli-cert
  namespace: nico-system
spec:
  secretName: nico-admin-cli-secret
  issuerRef:
    name: nico-admin-ca-issuer
    kind: Issuer
  commonName: nico-admin-cli
  usages: [client auth]
  duration: 8760h
  privateKey: {algorithm: ECDSA, size: 256}
CERT

until oc get certificate nico-admin-cli-cert -n nico-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; do sleep 5; done

oc get secret nico-admin-cli-secret -n nico-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/nico/nico-admin-cli.crt
oc get secret nico-admin-cli-secret -n nico-system \
  -o jsonpath='{.data.tls\.key}' | base64 -d > ~/.config/nico/nico-admin-cli.key
# Trust bundle: root CA + nico-admin-ca for full chain verification
oc get secret nico-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/nico/nico-root-ca.crt
oc get secret nico-admin-ca-secret -n nico-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d >> ~/.config/nico/nico-root-ca.crt
# OCP ingress CA for the REST API (nicocli)
oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.config/nico/ocp-ingress-ca.crt
```

**Step 2 — Register the expected machine.**

Critical flags and constraints:
- `--dpu-policy ignore`: REQUIRED for zero-DPU VM hosts; without it the
  site-explorer refuses to ingest ("no DPUs available for management")
- `--bmc-mac-address`: must be the Redfish Manager's MAC (the BMC controller
  NIC), NOT the host's provisioning NIC MAC. In our VM setup, the Redfish
  Manager reports MAC `02:42:ac:11:00:02` (the vbmc-rs pod's nico-bmc interface)
- `--interfaces`: the provisioning (hostinband) NIC MAC must be explicitly
  registered as `network_segment_type=3` (host_inband) so the NICo DHCP hook
  matches it. Without this, DHCP to the provisioning NIC fails with
  "Network segment mismatch" because the BMC MAC is on the OOB/underlay segment.

```bash
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
GRPC_ROUTE="https://nico-api-grpc-nico-system.${DOMAIN}"
NICOCLI=$REPO/hack/nico-admin-cli

# Get vbmc-rs BMC IP from its IPAMClaim (changes each rebuild)
BMC_IP=$(oc get pod -n nico-system -l app.kubernetes.io/name=vbmc-rs \
  -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
  python3 -c "import sys,json; nets=json.load(sys.stdin); print(next(n['ips'][0].split('/')[0] for n in nets if 'nico-bmc' in n.get('name','')))")
echo "BMC IP: $BMC_IP"

# Get chassis serial from Redfish
VBMC_SVC=$(oc get svc vbmc-rs-redfish -n nico-system -o jsonpath='{.spec.clusterIP}')
SERIAL=$(curl -sk -u admin:admin "https://$VBMC_SVC:8443/redfish/v1/Systems/nico-worker-0" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['SerialNumber'])")
echo "Serial: $SERIAL"

# Get vbmc-rs Manager MAC (Redfish Manager's NIC, not the host's provisioning NIC)
# The Manager MAC = the vbmc-rs pod's IP on nico-bmc, readable from network-status:
BMC_MAC=$(oc get pod -n nico-system -l app.kubernetes.io/name=vbmc-rs \
  -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
  python3 -c "import sys,json; nets=json.load(sys.stdin); print(next(n['mac'] for n in nets if 'nico-bmc' in n.get('name','')))")
echo "Manager MAC: $BMC_MAC"

API_URL="$GRPC_ROUTE" $NICOCLI expected-machine add \
  --bmc-mac-address "$BMC_MAC" \
  --bmc-username "admin" \
  --bmc-password "admin" \
  --chassis-serial-number "$SERIAL" \
  --bmc-ip-address "$BMC_IP" \
  --dpu-policy "ignore" \
  --meta-name "nico-worker-0" \
  --interfaces "[{\"mac_address\":\"02:00:00:aa:cc:01\",\"role\":\"host\",\"network_segment_type\":3,\"ip_allocation\":\"dynamic\"}]"
```

**If re-running Phase 6 after a previous partial attempt**, there may be an orphaned
machine record or interface. Clean up before re-registering:
```bash
# Force-delete old machine (if present)
API_URL="$GRPC_ROUTE" $NICOCLI machine force-delete \
  --machine <old-MACHINE_ID> --delete-interfaces

# Delete orphaned interface (if force-delete leaves one behind)
# Get the interface ID from the site-explorer log:
# "IP address 192.168.2.x is already allocated to interface <UUID>"
API_URL="$GRPC_ROUTE" $NICOCLI machine-interfaces delete <interface-UUID>
```

**Step 3 — Monitor discovery via nico-admin-cli.**
```bash
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
GRPC_ROUTE="https://nico-api-grpc-nico-system.${DOMAIN}"
# Poll every 30s — nico-admin-cli can take a few seconds per call
while true; do
  API_URL="$GRPC_ROUTE" $REPO/hack/nico-admin-cli machine show 2>&1
  sleep 30
done
# Expected progression: HOSTINITIALIZING/WAITINGFORDISCOVERY → HOSTNOTREADY/WAITINGFORDISCOVERY → READY
```

**WaitingForRebootToReady workaround — only if the state machine stalls.**
The site-explorer polls every 10s and may miss the power cycle window. Check with
`machine show`; apply only if State contains `WaitingForRebootToReady`:
```bash
MACHINE_ID=<id from machine show>
PGPASS=$(oc get secret nico-site-pg-pguser-nico -n nico-system \
  -o jsonpath='{.data.password}' | base64 -d)
oc exec -n nico-system nico-site-pg-instance1-m7b5-0 -c database -- \
  env PGPASSWORD="$PGPASS" psql -h localhost -U nico nico -c \
  "UPDATE machines
   SET last_reboot_requested = jsonb_set(last_reboot_requested, '{restart_verified}', 'true'),
       last_reboot_time = NOW()
   WHERE id = '$MACHINE_ID';"
```

Resource IDs (fetched from the cluster after discovery; differ on each rebuild):
  - `MACHINE_ID` — from `nico-admin-cli machine show` after Scout checkin
  - `INSTANCE_TYPE_ID` — from `nicocli instance-type list`
  - `SITE_ID` — from `nicocli GET /v2/org/ncx/nico/infrastructure-provider/current/site`
  - `TENANT_ID` — from `nicocli GET /v2/org/ncx/nico/tenant/current`
  - `VPC_ID` — from `nicocli vpc list` (use the FLAT vpc)
  - `OS_ID` — from `nicocli operating-system list` (openshift-coreos template)
  - `ALLOC_ID` — changes each provisioning cycle

### Phase 7: Allocate + provision worker

```bash
NICOCLI=$REPO/hack/nicocli

# Collect IDs needed for Phase 7 (all change each rebuild)
MACHINE_ID=$(API_URL="$GRPC_ROUTE" $REPO/hack/nico-admin-cli machine show 2>&1 | \
  grep "fm100" | awk -F'|' '{print $3}' | tr -d ' ')
SITE_ID=$($NICOCLI site list 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
TENANT_ID=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://nico-rest-api-nico-rest.${DOMAIN}/v2/org/ncx/nico/tenant/current" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 0. Create InstanceType (on fresh cluster — skip if already exists)
INSTANCE_TYPE_ID=$($NICOCLI instance-type create \
  --data "{\"name\":\"e2e-worker\",\"siteId\":\"$SITE_ID\"}" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 0a. Create FLAT VPC (requires an allocation first — create it after Step 2)
# 0b. Create openshift-coreos OS template
#     IMPORTANT field names (from proto): ipxeTemplateParameters (array of {name,value}),
#     ipxeTemplateArtifacts (array of {name,role,url,cacheStrategy}).
#     Only set 'kernel_params' here — 'base_url' and 'console' are RESERVED by
#     the template (set by nico-dhcp at boot time); including them causes
#     "reserved parameter found in OS definition: base_url".
NICO_PXE_VIP="192.0.2.13"
OS_ID=$($NICOCLI operating-system create --data "{
  \"name\": \"openshift-coreos\",
  \"ipxeTemplateId\": \"9f1b388e-cf6d-52a2-a20a-19eeeaca2f47\",
  \"siteIds\": [\"$SITE_ID\"],
  \"ipxeTemplateParameters\": [
    {\"name\": \"kernel_params\", \"value\": \"rd.neednet=1 coreos.inst.install_dev=/dev/vda coreos.live.rootfs_url=http://carbide-pxe.forge/public/blobs/internal/x86_64/rhcos-live-rootfs.x86_64.img coreos.inst.ignition_url=https://api-int.sno.nico.test:22623/config/worker\"}
  ],
  \"ipxeTemplateArtifacts\": [
    {\"name\": \"kernel\", \"role\": \"kernel\", \"url\": \"http://carbide-pxe.forge/public/blobs/internal/x86_64/rhcos-live-kernel-x86_64\", \"cacheStrategy\": \"CacheAsNeeded\"},
    {\"name\": \"initrd\", \"role\": \"initrd\", \"url\": \"http://carbide-pxe.forge/public/blobs/internal/x86_64/rhcos-live-initramfs.x86_64.img\", \"cacheStrategy\": \"CacheAsNeeded\"}
  ]
}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
# Wait for OS to sync to site (status: Ready)
until $NICOCLI operating-system get "$OS_ID" 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin); exit(0 if d.get('status')=='Ready' else 1)" 2>/dev/null; do
  sleep 5; done && echo "OS Ready"

# 1. Associate machine with InstanceType (idempotent — 409 if already done)
$NICOCLI instance-type machine-association create \
  --data "{\"machineIds\":[\"$MACHINE_ID\"]}" "$INSTANCE_TYPE_ID"

# 2. Create Allocation
ALLOC=$($NICOCLI allocation create --data "{
  \"name\": \"nico-worker-0\",
  \"siteId\": \"$SITE_ID\",
  \"tenantId\": \"$TENANT_ID\",
  \"instanceTypeId\": \"$INSTANCE_TYPE_ID\",
  \"machineCount\": 1,
  \"allocationConstraints\": [{
    \"constraintType\": \"Reserved\",
    \"machineCount\": 1,
    \"constraintValue\": 1,
    \"resourceType\": \"InstanceType\",
    \"resourceTypeId\": \"$INSTANCE_TYPE_ID\"
  }]
}")
ALLOC_ID=$(echo "$ALLOC" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 2a. Create FLAT VPC (requires allocation to exist first)
VPC_ID=$($NICOCLI vpc create \
  --data "{\"name\":\"e2e-flat\",\"networkVirtualizationType\":\"FLAT\",\"tenantId\":\"$TENANT_ID\",\"siteId\":\"$SITE_ID\"}" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 3. Create Instance (targets machine by ID, autoNetwork=true)
# Set VM to Manual runStrategy first so NICo/vbmc-rs controls power
oc patch vm nico-worker-0 -n nico-system --type merge -p '{"spec":{"runStrategy":"Manual"}}'
$NICOCLI instance create --data "{
  \"name\": \"nico-worker-0\",
  \"machineId\": \"$MACHINE_ID\",
  \"vpcId\": \"$VPC_ID\",
  \"operatingSystemId\": \"$OS_ID\",
  \"autoNetwork\": true
}"
```

After instance creation NICo powers on the machine via vbmc-rs. If the machine
gets stuck in `WaitingForRebootToReady` (common — site-explorer doesn't subscribe
to Redfish events), apply the DB workaround below.

**Approve CSRs after worker boots:**
```bash
oc get csr -o name | xargs oc adm certificate approve
```

### Phase 8: BMO ExternallyProvisioned adoption

```bash
oc apply -f helm/openshift/e2e-bmo-provisioning.yaml
oc apply -f helm/openshift/e2e-bmo-worker.yaml
# Wait ~2 min for BMO to reconcile
oc get baremetalhosts -n openshift-machine-api
```

### Phase 9: Decommission + fresh reprovision cycle

**Step 1 — Delete the BareMetalHost (if present):**
```bash
oc delete baremetalhost nico-worker-0 -n openshift-machine-api --wait=false
```

**Step 2 — Delete OCP worker node:**
```bash
oc delete node 192-168-253-12.nico.local
```

**Step 3 — Delete NICo instance:**
```bash
$NICOCLI instance delete <instance-id>
```

**Step 4 — Wait for decommission; apply WaitingForRebootToReady workaround as needed:**

The decommission loops through multiple power cycles. Each power cycle hits
`WaitingForRebootToReady`. Apply this fix each time it appears:
```bash
PGPASS=$(oc get secret nico-site-pg-pguser-nico -n nico-system \
  -o jsonpath='{.data.password}' | base64 -d)
oc exec -n nico-system nico-site-pg-instance1-m7b5-0 -c database -- \
  env PGPASSWORD="$PGPASS" psql -h localhost -U nico nico -c \
  "UPDATE machines
   SET last_reboot_requested = jsonb_set(last_reboot_requested, '{restart_verified}', 'true'),
       last_reboot_time = NOW()
   WHERE id = '$MACHINE_ID';"
```

**Step 5 — If decommission loop is stuck permanently (BadCertificate / Scout TLS
mismatch), force both DBs to a clean state:**

*Site DB:*
```bash
oc exec -n nico-system nico-site-pg-instance1-m7b5-0 -c database -- \
  env PGPASSWORD="$PGPASS" psql -h localhost -U nico nico -c "
BEGIN;
DELETE FROM instance_addresses WHERE instance_id = '<site-instance-id>';
DELETE FROM instances WHERE id = '<site-instance-id>';
UPDATE machines
  SET controller_state = '{\"state\": \"ready\"}'::jsonb,
      controller_state_version = 'V1-T' || (extract(epoch from now()) * 1000000)::bigint::text,
      last_reboot_requested = NULL,
      last_reboot_time = NOW()
  WHERE id = '$MACHINE_ID';
COMMIT;"
```

*Cloud DB — unlink deleted instance and reset machine:*
```bash
PGPASS_CLOUD=$(oc get secret nico-cloud-pg-pguser-nico -n nico-rest \
  -o jsonpath='{.data.password}' | base64 -d)
oc exec -n nico-rest nico-cloud-pg-instance1-gcjc-0 -c database -- \
  env PGPASSWORD="$PGPASS_CLOUD" psql -h localhost -U nico nico -c "
BEGIN;
UPDATE instance SET machine_id = NULL
  WHERE id = '<cloud-instance-id>' AND status = 'Deleted';
UPDATE machine SET status = 'Ready', is_assigned = false
  WHERE id = '$MACHINE_ID';
COMMIT;"
```

*Delete stale allocation:*
```bash
$NICOCLI allocation delete <alloc-id>
```

**Step 6 — Halt VM, wait for PoweredOff alert to clear, re-provision:**

Before creating a new instance, the machine must be On (site-explorer raises a
`PoweredOff/PreventAllocations` health alert if the VM is Stopped):
```bash
oc patch vm nico-worker-0 -n nico-system --type merge -p '{"spec":{"runStrategy":"Always"}}'
sleep 40  # wait for site-explorer to poll and clear PoweredOff alert
# Fix cloud DB (inventory sync may re-assert InUse):
oc exec -n nico-rest nico-cloud-pg-instance1-gcjc-0 -c database -- \
  env PGPASSWORD="$PGPASS_CLOUD" psql -h localhost -U nico nico -c \
  "UPDATE machine SET status = 'Ready', is_assigned = false WHERE id = '$MACHINE_ID';"
# Then create the new instance (Phase 7 Step 3)
oc patch vm nico-worker-0 -n nico-system --type merge -p '{"spec":{"runStrategy":"Manual"}}'
```

### Post-reboot recovery (SNO or ToR reboot)

**Crunchy PG SCC lost after reboot:**
```bash
oc adm policy add-scc-to-user anyuid \
  system:serviceaccount:nico-rest:nico-cloud-pg-instance \
  system:serviceaccount:nico-rest:nico-cloud-pg-pgbackrest \
  system:serviceaccount:nico-system:nico-site-pg-instance \
  system:serviceaccount:nico-system:nico-site-pg-pgbackrest
# Force StatefulSet to recreate pods:
for sts in nico-cloud-pg-instance1-gcjc nico-cloud-pg-repo-host \
           nico-site-pg-instance1-m7b5 nico-site-pg-repo-host; do
  NS=$(oc get sts -A --field-selector=metadata.name=$sts \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
  oc annotate sts $sts -n $NS restart-time="$(date -u +%s)" --overwrite
done
```

**Worker VM auto-restarts (runStrategy: Always) and attracts pod scheduling:**
```bash
# Stop it and remove the node
oc patch vm nico-worker-0 -n nico-system --type merge -p '{"spec":{"runStrategy":"Halted"}}'
oc delete vmi nico-worker-0 -n nico-system --wait=false
oc delete node 192-168-253-12.nico.local 2>/dev/null
# Force-delete all pods stranded on it
DEAD=192-168-253-12.nico.local
oc get pods -A --field-selector=spec.nodeName=$DEAD -o json | \
  python3 -c "
import sys,json
for p in json.load(sys.stdin)['items']:
  owners=p.get('metadata',{}).get('ownerReferences',[])
  if not owners or owners[0]['kind']!='DaemonSet':
    print(p['metadata']['namespace']+'/'+p['metadata']['name'])
" | while read nspod; do
  oc delete pod ${nspod##*/} -n ${nspod%%/*} --force --grace-period=0 2>/dev/null
done
```

**SNO disk pressure — online resize:**
```bash
# On the host (outside the VM):
sudo virsh blockresize nico-sno /path/to/sno.qcow2 180G
# Inside the SNO VM:
ssh core@192.168.130.10 "sudo growpart /dev/vda 4 && sudo xfs_growfs /var"
```

**Crashlooping pods after site-agent reconnects to Temporal:**
```bash
# Delete CrashLoopBackOff pods so they restart with fresh backoff:
oc delete pod -n nico-rest $(oc get pods -n nico-rest 2>/dev/null | \
  grep CrashLoop | awk '{print $1}')
oc delete pod -n nico-system $(oc get pods -n nico-system 2>/dev/null | \
  grep CrashLoop | awk '{print $1}')
```

## Risk register & de-risking spikes

1. **Provisioning-network reachability (highest).** VM↔`nico-dhcp`/`nico-pxe`
   over OVN secondary L2 inside SNO. → **Spike in Phase 3** before building VMs:
   confirm DHCP offer + iPXE fetch reach the VM.
2. **RHCOS iPXE + ignition via kernel args.** Correct `coreos.inst.install_dev`,
   `coreos.live.rootfs_url`, `ignition.config.url` reachable from the VM. →
   Validate with a standalone iPXE boot before wiring NICo's `InlineIpxe`.
3. **Worker joining SNO.** Now the *supported* path (unlike CRC). We control
   machine-network DNS (`api-int` → node IP) and DHCP, so the worker reaches
   MCS on the INPUT path (`22623/22624` REJECT rules live only in FORWARD/OUTPUT).
   Expect manual CSR approval (`oc adm certificate approve`). If MCS is still
   unreachable, fall back to embedding full rendered-worker ignition (from the
   `rendered-worker-*` MachineConfig `.spec.config`, ign 3.5.0) in the VM's
   config-drive — validated as extractable during the CRC spike.
4. **vbmc-rs Redfish surface vs `libredfish` expectations.** NICo's exact wire
   calls live in external `libredfish` v0.47.3. vbmc-rs may need small Redfish
   fidelity fixes (BIOS attrs, boot-order read-back). → Capture NICo↔vbmc-rs
   Redfish traffic during Phase 6; fix vbmc-rs as needed (our repo).
5. **Nested virt performance/stability.** SNO in a VM running CNV which runs
   worker VMs = two nesting levels. `host-passthrough` CPU + `/dev/kvm` keep it
   accelerated; watch memory. → Confirmed KVM works nested on this host.

## What this does and does not cover

**Covers (Phases 0–8, done):** real BMC/Redfish discovery, credential rotation,
BIOS config, NICo `Ready`, real OS install over PXE/iPXE (openshift-coreos
template + qcow-imager), an actual OpenShift worker join (CSR approval), the
unbound .forge DNS resolver and MetalLB VIP networking, and BMO
ExternallyProvisioned adoption of an existing NICo-provisioned worker.

**Covers (Track 1, Phases 9–10, planned):** NICo decommission + fresh
reprovision cycle; MAPNI — the declarative Machine API → NICo REST API
integration including BMH sync → OCP worker lifecycle.

**Covers (Track 2, Phases 11–12, planned):** NICo as hardware oracle
(discovery, attestation, GPU inventory) with Ironic as OS deployer (IPA +
virtual media + cloud-init → plain RHEL/Ubuntu/RHCOS); BMO fully manages
post-provisioning; handoff controller bridges NICo `Ready` state to BMH
annotations and Ironic trigger.

**Does not cover:** real DPUs reaching `Ready` (structural NICo limitation, see
MAT guide #1), physical switches/relay/OOB timing, or multi-node control-plane
scale (single control-plane node; we add worker nodes only).
