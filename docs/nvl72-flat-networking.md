<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# NICo FLAT networking on GB300 NVL72 — current architecture & recommended layout

> **Audience**: anyone on the team who needs to deploy or operate a **FLAT (zero-DPU)**
> NICo site on the shared GB300 NVL72 lab (NVIDIA LaunchPad). It documents **how FLAT
> works today** in this lab, **why** we run the "all-shared" variant, and **what the
> recommended layout** would be and what is still missing to get there.
>
> **Grounding**: every network/IP below is verified against the lab (`lab-inventory.md`,
> `network-cabling.md`, `dnsmasq-map.md`, switch configs). NICo in the lab runs **v2.3.0-pr**.
> Items marked **[EXAMPLE]** are proposals to be confirmed with NVIDIA before applying,
> because the fabric is shared with other teams.

---

## 1. TL;DR

- Today everything FLAT lives on **one VLAN: 200 / `172.16.2.0/24`** — OCP hub machine
  network, all BMCs, and the tray host OS all share it. This is the **"all-shared
  HostInband"** variant: **supported**, but **not recommended** (it removes OOB network
  isolation and forces DHCP coexistence with the lab's shared DHCP).
- We chose it **on purpose**: the fabric and the bastion DHCP are **shared with other
  teams**, and all 18 trays already boot on VLAN 200. The all-shared variant needs **zero
  fabric changes** and coexists with the others via **per-MAC DHCP deconfliction**.
- The **recommended layout** is a **dedicated provisioning VLAN** for the tray host OS
  (option **C-routed**): NICo service VIPs stay on VLAN 200, the new VLAN is routed to them,
  and DHCP reaches `nico-dhcp` through a **relay** (`giaddr`). This removes the collision
  cleanly. It is **not yet configured** — it needs fabric changes (see §6).

---

## 2. Lab networks (what already exists)

Fabric A is a production **EVPN-VXLAN** fabric; L3 for these VLANs is done on the
`sn5600-csl` collapsed spine-leaf, OOB leaves are `sn2201-mg` (hub + BMC) and `sn2201dc`
(compute-tray OOB).

| VLAN | Network | VRF | Gateway | Role |
|---|---|---|---|---|
| 100 | `172.16.0.0/23` | EXIT | `172.16.0.2` (bastion `.0.1`) | Control-plane BMC + internet egress |
| **200** | **`172.16.2.0/24`** | OOB | `172.16.2.1` | **FLAT plane**: OCP machine net + Tray/DPU BMC + host OS |
| 300 | `172.16.3.0/24` | INBAND | `172.16.3.1` | North-South data (CP CX7 `ens3f*`, DPU data) |
| 400 | `172.16.4.0/24` | INBAND | `172.16.4.1` | North-South data #2 |
| 501 | `172.16.5.0/24` | STORAGE | `172.16.5.1` | Storage / WEKA NFS (`.5.31-40`) |
| 900 | `192.168.0.0/20` + `192.168.16.0/20` | GPU | `192.168.0.1` / `.16.1` | GPU East-West (RoCE) |

> **Note**: DPU BMC and DPU OOB are on **VLAN 200** (management). VLAN 300 carries the DPU
> **data** plane, not its management. In FLAT the DPU is ignored entirely.

---

## 3. Current architecture — all-shared on VLAN 200

### 3.1 Components

The OCP **hub** (`nico-hub`, nodes cp-8/9/10) runs OCP + ACM/MCE + NICo (`nico-system`) +
MetalLB. NICo services are exposed as **MetalLB LoadBalancer VIPs** on VLAN 200.

| IP (VLAN 200) | Service | Notes |
|---|---|---|
| `172.16.2.10` | OCP hub **apiVIP** | `api.nico-hub.nvidialaunchpad.internal` |
| `172.16.2.11` | OCP hub **ingressVIP** | `*.apps.nico-hub...` |
| `172.16.2.12` | **nico-pxe** | serves scout rootfs on `:80`/`:8080`; `*-pxe.forge` |
| `172.16.2.13` | **unbound** | client-facing DNS; resolves `.forge` → `.12`/`.14`, forwards the rest to bastion `.0.1` |
| `172.16.2.14` | **nico-api** | Core gRPC API (cert carries this IP as SAN) |
| `172.16.2.15` | **nico-dhcp** | DHCP for the tray host OS (MetalLB L2 on VLAN 200) |
| `172.16.2.41-43` | **DPU BMC** | IP from bastion; NICo reaches by Redfish |
| `172.16.2.61-63` | **Tray BMC** (AMI) | IP from bastion; NICo reaches by Redfish |
| `172.16.2.103-105` | **Tray host OS** (`bond0`) | reserved by MAC; PXE-boots here |
| `172.16.2.128-130` | hub nodes cp-8/9/10 (OS-MGMT `ens6f*`) | OCP machine network |

> `nico-dns` has **no external VIP** (internal `:5353` only). The client-facing DNS is
> **unbound** (`172.16.2.13`), which is what serves `.forge`.

### 3.2 Physical: how a compute-tray attaches (FLAT / zero-DPU)

```
  COMPUTE-TRAY (arm64/Grace)                 switch              VLAN / network
  ├─ bond0 (host OS, OCP node) ───────────► sn2201dc-02 swp1   VLAN 200 · 172.16.2.103  ← PXE boots here
  ├─ Tray BMC (AMI MegaRAC) ──────────────► sn2201dc-01        VLAN 200 · 172.16.2.61   (Redfish)
  ├─ DPU BMC / DPU OOB ───────────────────► sn2201dc-02 swp29  VLAN 200 · 172.16.2.41   (ignored in FLAT)
  └─ CX8 ×4 (GPU East-West) ──────────────► pl1/pl2            VLAN 900 · 192.168.x     (data, no boot)
```

The tray's **only** boot/management NIC in FLAT is `bond0` on VLAN 200. That is why FLAT
provisioning necessarily happens on `172.16.2.0/24`.

### 3.3 Logical: everything on one broadcast domain

```
          ┌───────────────────────────────────────────────────────────┐
          │   OCP hub (cp-8/9/10) · nico-system · MetalLB              │
          │   nico-pxe .12  unbound .13  nico-api .14  nico-dhcp .15   │
          └───────────────────────────┬───────────────────────────────┘
                                       │  (MetalLB L2, VLAN 200)
   ╔═══════════════════════════════════╪═══════════════════════════════╗
   ║  VLAN 200 · 172.16.2.0/24  (GW .1)  —  ONE SHARED PLANE           ║
   ║  siteConfig: type = "hostinband"  (host OS *and* BMC together)    ║
   ╚═══════════════════════════════════╪═══════════════════════════════╝
         ┌─────────────┬───────────────┼───────────────┬─────────────┐
     Tray host OS   Tray BMC       DPU BMC/OOB      hub nodes     apiVIP/ingressVIP
     .103-.105      .61-.63        .41-.43          .128-.130     .10 / .11
```

### 3.4 Provisioning flow (FLAT, today)

```
 1. NICo powers the tray on / sets next-boot = PXE  ──Redfish──► Tray BMC (.61-63)
 2. bond0 sends DHCP DISCOVER on VLAN 200
        └─► nico-dhcp .2.15 answers: reserved IP (.103-105 by MAC),
            DNS = unbound .2.13, boot = iPXE → nico-pxe
 3. iPXE chains from nico-pxe .2.12  (carbide-static-pxe.forge → .2.12 via unbound)
 4. nico-pxe serves the scout rootfs  (:8080 / :80)
 5. Scout wipes disks, inventories HW, reports to nico-api .2.14 (gRPC/mTLS)
 6. NICo matches MAC ↔ expected_machine  → machine state = Ready
 7. (OSAC / HCP phase) tray boots the Assisted discovery image, registers an Agent,
    joins the NodePool as a worker
```

### 3.5 The DHCP coexistence problem (and today's fix)

VLAN 200 has **two** DHCP servers:

- **nico-dhcp** (`172.16.2.15`, MetalLB L2) answers directly on VLAN 200.
- the **bastion dnsmasq** (`172.16.0.1`) is reached via a **DHCP relay** on `sn2201-mg`
  and also answers (it holds reservations for all 18 trays, for the other teams).

Both can reply to the same DISCOVER → a **race**. If the bastion wins, the tray either
boots the wrong (Ubuntu) image or gets DNS `.0.1` and fails to resolve `*.forge`.

**Fix in place (per-MAC deconfliction):** on the bastion, the three tray **node** MACs
(`c4:ef:bb:*`) are set to `ignore` so only `nico-dhcp` serves them; all other MACs
(BMCs, other teams' trays) keep being served by the bastion.

```
  DISCOVER on VLAN 200 ──┬──► nico-dhcp .2.15      (serves .103-.105 — our 3 trays)
                         └──► relay → bastion .0.1 (ignores c4:ef:bb:* ; serves the rest)
```

> ⚠️ Editing the bastion requires `systemctl restart dnsmasq` = a brief DNS+DHCP outage
> for the **whole lab** → **coordinate with NVIDIA** before touching it.

---

## 4. Why we run the all-shared variant (supported, not recommended)

NICo **supports** putting the host OS and the host BMC on the **same** HostInband segment
for zero-DPU hosts, but the docs flag it with a security **Warning**: it removes the
network-level OOB isolation that a dedicated management VLAN provides.

We chose it anyway, deliberately, because the lab is **shared**:

1. **No fabric changes.** Creating/retagging VLANs on the production EVPN-VXLAN fabric is a
   change that affects every team on the rack and must go through NVIDIA. All-shared needs
   **none**.
2. **The trays already live on VLAN 200.** The bastion serves all 18 trays there for the
   other teams. We slot in next to them via per-MAC deconfliction instead of carving out
   new L2.
3. **Smallest blast radius for a pilot.** We only change three MACs on the bastion; we do
   not move anyone else's boot path.

Trade-offs we accept: BMC and host OS share a broadcast domain (no OOB isolation), and the
DHCP coexistence is fragile (per-MAC, and bastion edits are lab-wide). For a **pilot** this
is the right call; for a **production** FLAT site, use the recommended layout below.

---

## 5. Recommended layout — dedicated provisioning VLAN (C-routed)

Move **only the tray host OS boot** (`bond0`) off the shared VLAN 200 into a **dedicated
provisioning VLAN** (e.g. **250 / `172.16.6.0/24`** **[EXAMPLE]**), where `nico-dhcp` is the
**only** DHCP. BMCs stay on VLAN 200 (served by the bastion; NICo uses Redfish). This
removes the collision at the root without touching the bastion DHCP.

In the **C-routed** variant the **NICo VIPs stay on VLAN 200** (the hub's primary network).
The new VLAN is **routed** to them, and DHCP reaches `nico-dhcp` through a **relay**
(`giaddr`) — the model the NICo docs recommend.

```
  TRAY (VLAN 250, 172.16.6.103)                 HUB / VIPs NICo (VLAN 200, 172.16.2.x)
   (1) DHCP DISCOVER (broadcast, VLAN 250)                        ▲
        │                                                         │
  ┌─────▼─────────────────┐  (2) dhcp-relay on SVI .6.1           │
  │ SVI VLAN 250 = .6.1    │──── ip helper-address 172.16.2.15 ───┤ nico-dhcp .2.15
  │ (gateway of VLAN 250)  │     broadcast → unicast, giaddr=.6.1  │
  └─────┬─────────────────┘     → intended: NICo selects segment by giaddr (verify — see note)
        │ (3) inter-VLAN routing 250↔200 (unicast)                │
        ├────────────────────────────────────────────────────────► nico-pxe .2.12
        ├────────────────────────────────────────────────────────► unbound  .2.13
        └────────────────────────────────────────────────────────► nico-api .2.14
```

- **DHCP** (broadcast) does not cross VLANs by itself → a **relay** on the VLAN 250 SVI
  points to `172.16.2.15`. The relay stamps `giaddr=.6.1`; the intent is that NICo selects
  the HostInband segment whose prefix contains `.6.1` (→ `172.16.6.0/24`).
  > **Verify before relying on this for the host path.** The NICo protocol flow documents the
  > `relay_address` (`giaddr`) selector explicitly for **BMC** DHCP; the **host** provisioning
  > DHCP path (`GetDhcpDiscovery(mac)`) is not confirmed to select the segment by `giaddr` in
  > NICo **v2.3.0-pr**. Treat the `giaddr`→segment mapping for host PXE as a **deployment
  > prerequisite to validate** against your NICo version, not guaranteed behavior. If it does
  > not hold, keep the host OS L2-adjacent to `nico-dhcp` (the C-L2 variant, §5.2).
- **PXE / DNS / API** (unicast) reach VLAN 200 via plain inter-VLAN routing.
- **Collision is gone**: the bastion has no interface or relay on VLAN 250, so it never
  sees the tray's DISCOVER. The only DHCP reachable from VLAN 250 is `nico-dhcp`.

### 5.1 How each machine looks

```
  COMPUTE-TRAY (FLAT)
    bond0        ─► sn2201dc-02 swp1  (VLAN 250) ─► 172.16.6.103   ◄ CHANGES (was VLAN 200)
    Tray BMC     ─► sn2201dc-01       (VLAN 200) ─► 172.16.2.61     ◄ same (bastion + Redfish)
    DPU BMC/OOB  ─► sn2201dc-02 swp29 (VLAN 200) ─► 172.16.2.41     ◄ same (ignored in FLAT)
    CX8 ×4       ─► pl1/pl2           (VLAN 900) ─► East/West        ◄ same (GPU data)

  CONTROL-PLANE (cp-8/9/10, the hub)         — NO new NIC needed in C-routed
    BMC              (VLAN 100) 172.16.0.35/36/37
    OS-MGMT ens6f0/1 (VLAN 200) 172.16.2.128/129/130   ← hub stays here; VIPs stay here
    Storage CX7      (VLAN 501) 172.16.5.x
    N/S CX7          (VLAN 300) 172.16.3.x
```

### 5.2 What is still missing to configure in the lab

**NVIDIA (fabric):**
1. Create **VLAN 250 + L2VNI** (e.g. `245250`, following the `2452xx` scheme), stretched on
   Fabric A across `sn2201dc` and `sn2201-mg`. **[EXAMPLE]**
2. **Retag** the tray `bond0` ports (`sn2201dc-02 swp1`, ×N) from access VLAN 200 → 250.
3. SVI/gateway `172.16.6.1` with **inter-VLAN routing 250↔200** (same VRF or route-leaking).
4. **DHCP relay** on the SVI: `ip helper-address 172.16.2.15`.
5. Confirm the bastion has **no** interface/relay on VLAN 250 (automatic isolation).

**Us (OCP + NICo):**
6. Update the siteConfig HostInband prefix to `172.16.6.0/24` (gateway `.6.1`). **VIPs do
   not move** — they stay on `172.16.2.12-15`.
7. No NNCP / OVN local-gateway / second hub NIC needed (that is only the C-L2 variant where
   VIPs move onto VLAN 250).

siteConfig change (C-routed):

```toml
[networks.nvl72-inband]
type               = "hostinband"
prefix             = "172.16.6.0/24"   # was 172.16.2.0/24
gateway            = "172.16.6.1"      # the VLAN 250 SVI that carries the DHCP relay
mtu                = 1500
reserve_first      = 5
allocation_strategy = "reserved"

[networks.nvl72-admin]                 # mandatory placeholder, unused in FLAT
type   = "admin"
prefix = "10.180.64.0/24"
```

> **Alternative (C-L2)**: put the VIPs on VLAN 250 instead of routing. That removes the
> relay but requires a second hub NIC (NNCP), MetalLB pinned to it, and OVN local-gateway
> mode. C-routed is preferred — fewer OCP changes.

### 5.3 OCP note: HCP vs standalone

- **HCP (this lab's plan)**: the hosted cluster's control plane runs as **pods on the hub**
  (VLAN 200); the workers (trays) live on **VLAN 250**. This works **by design** —
  HyperShift decouples control plane from workers. Workers only need **L3 reachability** to
  the hosted kube-apiserver / ignition endpoints (exposed via LoadBalancer/Route on the
  hub); the control-plane→worker direction is tunneled by **konnectivity** (the agent dials
  out). The hosted cluster's `machineNetwork` = VLAN 250. The required routing is the same
  250↔200 routing C-routed already needs.
- **Standalone (non-HCP)**: a cluster provisioned entirely on the trays has **all** nodes on
  VLAN 250, with its own apiVIP/ingressVIP on VLAN 250 — fully self-contained. The
  "control plane on VLAN 200 / workers on VLAN 250" split is **specific to HCP**.

---

## 6. Quick reference

| | All-shared (today) | C-routed (recommended) |
|---|---|---|
| Tray host OS boot | VLAN 200 `172.16.2.103-105` | VLAN 250 `172.16.6.103-105` |
| BMCs | VLAN 200 (bastion + Redfish) | VLAN 200 (unchanged) |
| NICo VIPs | VLAN 200 `.2.12-.15` | VLAN 200 `.2.12-.15` (unchanged) |
| DHCP collision with bastion | yes → per-MAC `ignore` | no (bastion not on VLAN 250) |
| Fabric changes | none | new VLAN + retag + routing + relay |
| OCP changes | none | siteConfig HostInband prefix + gateway (`172.16.6.1`) |
| OOB isolation | none (shared) | BMC on VLAN 200, host on VLAN 250 |
| Recommended for | shared-lab pilot | production FLAT |

**Related docs**: data-plane VIP deploy flow and MetalLB FLAT mode →
`ncp-dsx-nico-deploy` (`dataplane-vip.md`); full lab IP inventory → `lab-inventory.md`;
cabling / VLAN↔VNI map → `network-cabling.md`; DHCP map and per-MAC procedure →
`dnsmasq-map.md`.
