<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# NICo iPXE Patches — Productization Tracking

NICo builds `ipxe.efi` from a patched iPXE upstream source. The source is the
`ipxe/ipxe` git repository (submodule at
`helm/vendor/infra-controller/pxe/ipxe/upstream/`, pinned at commit
`bbd7821bd42da5456ee068a471ef73d525ea26a1`) with three patches applied from
`helm/vendor/infra-controller/pxe/ipxe/local/*.patch`.

These patches are **not yet in iPXE upstream**. Red Hat productization of NICo
must either:
1. Carry these patches downstream as a set of `%patch` entries in an `ipxe.spec`
   file, or
2. Get them merged upstream in iPXE and wait for the vendored commit to advance.

---

## Patch 1 — TPM measurement via TCG EFI protocols

**File:** `0001-efi-Add-TPM-measurement-API-via-TCG-v1-and-TCG-v2-EF.patch`  
**Size:** 688 lines  
**Status:** Not upstream in iPXE (as of 2026-10)

### What it does

Enables `#define TPM_EFI` in `src/config/defaults/efi.h` and adds a complete
TPM measurement API to iPXE's EFI image loading path. Implements TCG v1
(`EFI_TCG_PROTOCOL`) and TCG v2 (`EFI_TCG2_PROTOCOL`) support so that iPXE
can extend TPM PCRs when loading EFI images.

### Why NICo needs it

NICo performs remote attestation of bare-metal nodes via Redfish
`ComponentIntegrity/SPDM`. TPM PCR measurements of the boot chain (UEFI →
iPXE → Scout UKI → forge-scout) are used to prove the node booted from
known-good software. Without this patch, iPXE does not participate in the TPM
measurement chain.

### Productization action

This is the largest patch and the most NICo-specific. Upstream submission to
iPXE mailing list (`ipxe-devel@lists.ipxe.org`) is recommended. Red Hat should
track the upstream review status. If not accepted upstream, carry in
`ipxe.spec` as `Patch0`.

---

## Patch 2 — BlueField NIC SNP driver fix

**File:** `0001-fix-update-to-allow-iPXE-to-boot-on-BlueField-NICs.patch`  
**Author:** Vishnu Rangayyan `<vrangayyan@nvidia.com>` (NVIDIA)  
**Date:** 2023-12-01  
**Commit:** `85217244da5eb01b6bf99741767d310f116c258f`  
**Size:** 51 lines  
**Status:** Not upstream in iPXE (as of 2026-10)

### What it does

Removes overly strict EFI Simple Network Protocol (SNP) receive filter
requirements from `src/drivers/net/efi/snpnet.c` and
`src/interface/efi/efi_snp.c`. The standard SNP filter setup
(`EFI_SIMPLE_NETWORK_RECEIVE_UNICAST | MULTICAST | BROADCAST`) fails on
BlueField DPU NICs whose SNP implementation does not support the full filter
mask. The patch falls back to what the NIC reports as its supported mask.

### Why NICo needs it

NICo targets NVIDIA BlueField-equipped servers. Without this fix iPXE hangs
or fails to receive network traffic on BlueField management ports, preventing
PXE boot on the target hardware class.

### Productization action

This was authored by NVIDIA and should be straightforward to push upstream.
Check the iPXE mailing list / GitHub PRs for any prior submission. If already
submitted and pending, track the review. If not submitted, Red Hat or NVIDIA
should submit it. Carry in `ipxe.spec` as `Patch1` until accepted.

---

## Patch 3 — Disable UEFI watchdog during `LoadImage()`

**File:** `0003-efi-prevent-load-image-watchdog-timeout.patch`  
**Size:** 52 lines  
**Status:** Not upstream in iPXE (as of 2026-10)

### What it does

Wraps both `efi_image_exec()` and `efi_image_probe()` calls to
`bs->LoadImage()` with watchdog disable/enable:

```c
bs->SetWatchdogTimer(0, 0, 0, NULL);  /* disable */
efi_watchdog_stop();
efirc = bs->LoadImage(...);
efi_watchdog_start();
```

The UEFI Boot Services default watchdog timer (5 minutes) can fire on
platforms where `LoadImage()` takes unusually long — for example when loading
a large Scout UKI (127 MB) or qcow-imager UKI (176 MB) over a slow network
interface, or on platforms with slow flash/memory subsystems.

### Why NICo needs it

NICo's boot artifacts are large UKIs. On some server platforms (especially
those with slower NIC SNP implementations) the UEFI watchdog fires during
`LoadImage()`, causing a forced reset before the image finishes loading. This
patch ensures the watchdog is suspended for the duration of the load.

### Productization action

This is a generally useful fix for any PXE scenario with large EFI images.
Submit upstream to iPXE. The fix is small and self-contained; upstream
acceptance is likely. Carry in `ipxe.spec` as `Patch2` until accepted.

---

## Embedded iPXE script (`embed.ipxe`)

In addition to the three patches, NICo embeds a custom iPXE script at
`pxe/ipxe/local/embed.ipxe`. This script:

- Performs DHCP (`ifconf -c dhcp`)
- Chains to `http://${next-server}/api/v0/pxe/boot?buildarch=...` passing
  hardware identity parameters (architecture, platform, manufacturer, product,
  serial number) so NICo's PXE server can return the machine-specific boot
  script
- Provides a 4-second interactive menu for debug/override

This is not patchable from an RPM — it must be compiled into the binary at
build time. The `embed.ipxe` script is NICo-proprietary and has no upstream
equivalent.

---

## Build context

The patched `ipxe.efi` is compiled in the `ipxe-builder` stage of
`docker/ubi/Dockerfile.nico-pxe`. This stage uses Ubuntu 24.04 with standard
GCC tooling (iPXE's build system requires Debian-style tools). The patches are
applied by the build system via the `local/` header mechanism (not via `git
apply`) — the three `.patch` files are applied during the Docker build before
`make`.

**iPXE upstream commit:** `bbd7821bd42da5456ee068a471ef73d525ea26a1`  
**NICo version:** v2.3 (submodule at `helm/vendor/infra-controller`)
