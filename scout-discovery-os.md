<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# The Scout discovery OS — build postures

**Status:** reference. Describes how NICo's Scout discovery OS is built
upstream, and what a Red Hat downstream would need to build it three ways.
Posture 3 is what the SNO e2e (`e2e-nico-kubevirt-sno.md`) actually uses.

## What Scout is

Scout is the ephemeral discovery OS a bare-metal host netboots the first time
NICo sees it. It enumerates hardware and registers the machine with Core over
gRPC mTLS, driving the machine to `Ready`. It is **built from vendored
source** (`helm/vendor/infra-controller`, crate `carbide-scout`, binary
`forge-scout`) — nothing about it is proprietary or downloaded pre-baked.

### The x86_64 discovery boot chain

```
UEFI HTTP boot (DHCP option 67)
  → http://<nico-pxe-vip>:8080/public/blobs/internal/x86_64/ipxe.efi   (iPXE loader)
  → iPXE embed.ipxe chainloads /api/v0/pxe/boot?buildarch=x86_64...     (Core returns a boot instruction)
  → kernel = .../x86_64/scout.efi   (the LOADER UKI — its own kernel+initrd, no GPU)
      → loader's /etc/rc.local (scout-loader-rclocal) downloads
        .../x86_64/scout.squashfs   (the OSS rootfs), measures it into TPM PCR 16,
        mounts it as an overlay, and `systemctl soft-reboot`s into it
      → inside the rootfs, forge-scout.service runs forge-scout
      → forge-scout enumerates HW and registers via Core gRPC DiscoverMachine (mTLS)
  → machine reaches Ready
```

**Three blobs must be seeded into the `nico-pxe` blob store** (served by
`carbide` under `/public/`), all under `blobs/internal/x86_64/`:

| Blob | Built from | Contains |
|---|---|---|
| `ipxe.efi` | `pxe/ipxe/` (snponly.efi, renamed) | iPXE UEFI loader with embedded `embed.ipxe` |
| `scout.efi` | `scout-loader-x86_64` mkosi profile (`loader.efi` renamed) | minimal Ubuntu-noble UKI, **no NVIDIA** |
| `scout.squashfs` | `scout-oss-x86_64` mkosi profile | Ubuntu-noble rootfs + `forge-scout` + full NVIDIA stack |

`scout.efi` is `loader.efi` copied at
`pxe/Makefile.toml:mkosi-copy-scout-loader-to-webroot-x86_64`;
`scout.squashfs` at `mkosi-copy-scout-to-webroot-x86_64`; `ipxe.efi` via
`ipxe-install-efi-x86_64`. The `forge-scout` binary is packaged as
`target/debs/forge-scout_${PKG_VERSION}_amd64.deb`
(`package-scout-x86_64-release-local`), copied into the oss profile's
`build-output/forge-scout.deb`, and `dpkg -i`'d in `mkosi.postinst.chroot`.

### How upstream builds it

```
cd pxe && cargo make build-boot-artifacts-x86_64
```

Requires `mkosi` + `debootstrap`, runs as **root**, builds an **Ubuntu 24.04
(noble)** image. Both mkosi profiles pin `Distribution=ubuntu Release=noble`.
The oss profile's `postinst.chroot` installs the NVIDIA stack pinned to
`580.126.16-1ubuntu1` (`cuda-drivers-580`, DCGM 4, fabricmanager, MFT) from
NVIDIA's public CUDA apt repo (`nvidia.list`), plus a NICo apt repo
(`forge.list` → `http://carbide-pxe.forge/public/blobs/internal/apt/`).

---

## Posture 1 — upstream Ubuntu-noble Scout, as-is

Build the vendored profiles unchanged. Produces a ~300 MB `scout.squashfs`
carrying the whole GPU stack. Correct for production hosts with NVIDIA GPUs;
overkill (and a needless external-repo dependency) for a GPU-less test VM.

- **Pros:** zero code changes; exactly what production ships.
- **Cons:** Ubuntu-based (not Red Hat); requires reaching NVIDIA's CUDA repo
  and `carbide-pxe.forge` at build time; large; the postinst's GPU-presence
  gates (`nvidia.ko`, `mlx5_ib.ko`, DCGM binaries) fail closed on a build host
  that can't resolve those repos.

## Posture 2 — a true RHEL/UBI Scout (downstream fork)

A maintained Red Hat downstream of the boot-artifacts pipeline: same two-stage
loader+rootfs shape and the **same real `forge-scout` binary**, but built on
UBI/RHEL instead of Ubuntu. This is a **fork of `pxe/`**, not a values
override — the upstream `pxe/` tree is Debian/apt/mkosi-Ubuntu to the bone.

### What has to change

1. **Distribution swap (mkosi).** In both `mkosi.profiles/scout-*-x86_64/mkosi.conf`,
   replace `Distribution=ubuntu`/`Release=noble` and the `ToolsTree*=ubuntu`
   with a RHEL/UBI equivalent. mkosi supports `Distribution=fedora`; **there is
   no first-class UBI/RHEL distribution in mkosi**, so this is the load-bearing
   risk — either drive it as `fedora` against RHEL/UBI repos, or replace mkosi
   with a `bootc`/`osbuild` image build. Recommend evaluating **bootc** here: a
   UBI-based bootc image is the natural RHEL analogue of an mkosi UKI+rootfs and
   is Red Hat's supported path for image-mode hosts.

2. **Package-name translation (apt → dnf).** Every `Packages=` entry in both
   `mkosi.conf` files and every `apt-get install` in `postinst.chroot` must map
   to its RHEL/UBI RPM. Non-trivial cases:
   - `linux-image-6.8.0-111-generic` / `linux-modules[-extra]` /
     `linux-headers-*` → RHEL `kernel` / `kernel-modules[-extra]` /
     `kernel-devel` (a **different kernel** — see driver stack below).
   - `systemd-boot`, `systemd-boot-efi`, `systemd-ukify` → RHEL `systemd-boot`,
     `systemd-ukify` (available in RHEL 10 / recent Fedora; verify the UKI
     tooling exists in the target UBI).
   - `isc-dhcp-client` → `dhcp-client`; `bind9-dnsutils`/`bind9-host` →
     `bind-utils`; `freeipmi-tools` → `freeipmi`; `nvme-cli`, `mstflint`,
     `rdma-core`, `tpm2-tools`, `lldpd`, `ipmitool`, `smartmontools` exist as
     RPMs (some via EPEL — decide EPEL vs. RHEL-only).
   - `containerd`/`runc` → `containerd`/`runc` (or drop; discovery doesn't run
     workloads).

3. **NVIDIA driver stack (the hard part).** The oss `postinst.chroot` pins the
   Ubuntu `580.126.16-1ubuntu1` DKMS/`-open` packages + DCGM 4 +
   fabricmanager + MFT. On RHEL these come from **NVIDIA's RHEL RPM repos**
   (`cuda-rhel10` / the datacenter driver RPMs) built against the **RHEL
   kernel**, not the Ubuntu one — so the pinned versions, the kernel they DKMS
   against, and the module names all change. The postinst's consistency and
   presence gates (`dpkg -l` version check, `nvidia.ko.zst`/`mlx5_ib.ko.zst`
   presence, `dcgmi`/`nvvs`/`BwChecker` existence and `ldd` checks) must be
   rewritten in RPM terms (`rpm -q`, `.ko.xz` under RHEL's module tree).

4. **Rewrite `mkosi.postinst.chroot`.** apt → dnf; `dpkg -i forge-scout.deb` →
   `rpm -i`/`dnf install` of a **`forge-scout` RPM** (see #6); keep the
   cloud-init hardening verbatim (disable `power_state_change` + `resizefs`,
   `ssh_quiet_keygen`) — those are OS-agnostic and load-bearing (a rebooting
   cloud-init snippet re-PXEs and loops the whole site); keep the lldpd enable;
   keep the update-check timer and module-loader copies.

5. **apt sources → dnf repos.** Replace `sources.list.d/forge.list` and
   `nvidia.list` (and the `trusted.gpg*` / Dell / NVIDIA CUDA keys) with
   `.repo` files + RPM-GPG keys: a NICo internal repo equivalent to
   `http://carbide-pxe.forge/public/blobs/internal/apt/`, plus the NVIDIA RHEL
   CUDA repo.

6. **`forge-scout.deb` → `forge-scout` RPM.** `package-scout-x86_64-release-local`
   emits a `.deb` via `cargo-deb`. Add a downstream packaging step that builds
   the **same crate** (`cargo build --release -p carbide-scout --bin
   forge-scout`, from the fork's sushy tip) into an RPM (`cargo-generate-rpm`
   or a spec), installing the identical payload: the binary at
   `/opt/forge/forge-scout`, `forge-scout.service`, `forge-scout-pre.sh`,
   `forge-scout.env.template`. This is where the **version alignment** with the
   running Core is enforced — build from the same tree as the Core image.

7. **PCR-16 measured-boot loader.** `common_files/scout-loader-rclocal`
   (installed as the loader's `/etc/rc.local`) downloads `scout.squashfs`,
   measures it into TPM PCR 16 with `tpm2_pcrextend`, overlays it, and
   `soft-reboot`s. It uses only `curl`/`zstd`/`cpio`/`tpm2-tools`/`squashfs`/
   `overlay` — all available on RHEL — so it ports **unchanged** provided those
   RPMs and the `squashfs`/`overlay`/`loop` kernel modules are present in the
   loader image.

8. **Build gates / CI.** Reproduce the postinst validation gates in RPM/RHEL
   terms and keep them fail-closed. Add the fork to the Konflux pipeline
   alongside the other `nico-*` images.

### Bottom line for Posture 2

Feasible but a **real fork with ongoing maintenance cost**: a distribution
port (mkosi-Ubuntu → bootc/osbuild-RHEL), an NVIDIA RHEL driver-stack
re-pin against the RHEL kernel, a deb→rpm packaging path for `forge-scout`,
and repo/key/gate rewrites. The loader `rc.local` and the cloud-init
hardening carry over unchanged. Recommended only if a Red Hat-supported
production discovery OS is required; **not** needed for the e2e.

## Posture 3 — minimal e2e image (what the SNO e2e uses)

The SNO e2e worker is a **GPU-less KubeVirt VM**, so the entire NVIDIA stack
(the bulk of the oss rootfs, the external CUDA-repo dependency, and the
GPU-presence gates) is dead weight. `forge-scout`'s hardware enumeration
already degrades cleanly with no GPU (`hardware_enumeration.rs` matches PCI
vendor `0x10de`; absent it, `gpus=vec![]`), and the e2e siteConfig sets
`tpm_required=false` / `attestation_enabled=false`, so discovery reaches
`Ready` without a GPU or TPM.

Posture 3 keeps the **real** `forge-scout` binary and the **real** loader
(`scout.efi`, which is already NVIDIA-free) and builds a **slimmed
`scout.squashfs`** with the GPU stack and its gates stripped — same
Ubuntu-noble base as upstream (so the loader kernel and the rootfs stay
compatible across the `soft-reboot`), just minus the NVIDIA payload. It is
built from the **fork sushy tip** (`fork/feat/sushy-emulator-support`,
v2.2.0-pr line) so `forge-scout` matches the running `nico-core`.

See the e2e runbook (`e2e-nico-kubevirt-sno.md`, Phase D) for the build and
the `bootArtifactContainers` seeding of `ipxe.efi` + `scout.efi` +
`scout.squashfs` into `nico-pxe`.
