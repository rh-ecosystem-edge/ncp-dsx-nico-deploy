<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Future Improvements — RHEL 10 Scout

Architectural ideas identified during the RHEL 10 Scout implementation that are
not yet implemented but worth tracking for productization.

---

## UKI Add-ons for machine-specific boot parameters

**Reference:** https://www.redhat.com/en/blog/extending-red-hat-unified-kernel-images-using-addons

### Problem

The current Scout boot chain passes machine-specific parameters (`machine_id`,
`server_uri`, `newrootfs`) via iPXE kernel cmdline:

```ipxe
chain http://carbide-pxe.forge/public/blobs/internal/x86_64/scout.efi \
    machine_id=<uuid> server_uri=https://carbide-api.forge \
    newrootfs=http://carbide-static-pxe.forge/.../scout.squashfs
```

`forge-scout-pre.sh` then parses `/proc/cmdline` to extract these values. This
has two limitations:

1. **iPXE cmdline length limit** — long URLs or multiple parameters can exceed
   iPXE's internal buffer
2. **Measured boot instability** — kernel cmdline is measured into PCR9/10 at
   each boot; per-machine values make PCR values unique per machine, complicating
   remote attestation policy

### Solution: UKI Add-ons

A UKI Add-on is a separate `.efi` file that the UEFI firmware (or bootloader)
merges with the base UKI at boot time. The add-on carries additional kernel
cmdline parameters (and optionally additional initrd content). The machine-
specific parameters would live in a per-machine add-on served by nico-pxe.

**Boot chain with add-ons:**

```
UEFI HTTP Boot
  └─ downloads scout.efi  (base UKI — static, same for all machines)
  └─ downloads scout-<machine-interface-id>.efi  (add-on — machine-specific)
     contains: machine_id=<uuid> server_uri=https://... newrootfs=http://...
```

The firmware merges both before booting — the kernel sees the combined cmdline
without any iPXE string manipulation.

**nico-pxe changes required:**
- Serve `scout.efi` as a static blob (unchanged)
- Generate and serve `scout-<machine-interface-id>.efi` as a per-machine
  dynamic endpoint (similar to how `/api/v0/pxe/boot` generates iPXE scripts
  today, but produces a signed EFI add-on instead)

**Advantages:**
- No iPXE cmdline length limits
- Add-on can be signed independently with a machine-specific key (full measured
  boot chain — PCR values stable across boots of the same machine)
- `forge-scout-pre.sh` no longer needs to parse `/proc/cmdline`
- nico-pxe serves the base UKI from cache (CDN-friendly) + add-on dynamically

**Requirements:**
- systemd 255+ for `ukify` add-on generation (`systemd --version` on RHEL 10:
  257 ✓)
- UEFI firmware with UKI add-on support. OVMF requires the add-on section
  (`SD_ADDON_UKI=1`) — verify OVMF version in use
- nico-pxe upstream change: new endpoint to generate and serve per-machine
  add-on EFI files (file upstream issue)

**Status:** not implemented. Current workaround: `scout-loader.service` runs
`scout-loader.sh` which reads `newrootfs=` from `/proc/cmdline` (set by the
iPXE boot script returned from `/api/v0/pxe/boot`).

---

## NetworkManager-native NIC isolation

`forge-scout-network.sh` currently uses `systemd-networkd` (`networkctl`) to
isolate the provisioning NIC. RHEL 10 defaults to NetworkManager. Our RHEL 10
Scout ships the NM-based replacement at
`hack/pxe-rhel10/mkosi.profiles/scout-rhel10-oss-x86_64/mkosi.extra/opt/forge/forge-scout-network.sh`.

The upstream script should be contributed back with NM support (detect NM vs
networkd at runtime and use the appropriate backend).
