<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Posture 3 — minimal e2e Scout boot artifacts

Builds the three blobs the SNO e2e worker needs to netboot into NICo discovery:

| Blob | What it is |
|---|---|
| `ipxe.efi` | iPXE UEFI loader (chainloads Core's `/api/v0/pxe/boot`) |
| `scout.efi` | loader UKI (Ubuntu-noble, **no NVIDIA** even upstream) |
| `scout.squashfs` | discovery rootfs with the **real `forge-scout`**, GPU stack **stripped** |

See [`../../scout-discovery-os.md`](../../scout-discovery-os.md) for the boot
chain and how this differs from Postures 1 (upstream, full GPU stack) and 2
(true RHEL/UBI fork).

## Why a separate build

The upstream Scout pipeline is `mkosi` + `debootstrap` against **Ubuntu 24.04**
— tooling absent from the RHEL/Fedora dev host. `Dockerfile.builder`
reproduces that environment so the pipeline runs unchanged in a privileged
`podman` container; the host stays clean. The GPU stack (the bulk of the rootfs
and an external CUDA-repo dependency) is dropped by `apply-overlay.sh` because
the KubeVirt worker VM has no GPU — `forge-scout` enumerates `gpus=[]` and never
calls the CUDA/DCGM tooling.

## Source of truth (version alignment)

Everything is built from the **fork sushy tip**
`fabiendupont/nvidia-infra-controller@feat/sushy-emulator-support`
(`3892898`, `v2.2.0-pr-452`) — the same tree the running `nico-core` is built
from — so the `forge-scout` ↔ Core `DiscoverMachine` gRPC contract aligns by
construction. Built in a throwaway `git worktree`; the vendored submodule
(`helm/vendor/infra-controller`, pinned at v2.3) is never modified.

## Usage

```bash
# x86_64 (validated path)
./build-scout.sh x86_64
# → artifacts in ~/nico-e2e-sno/scout-build/out/x86_64/{ipxe.efi,scout.efi,scout.squashfs}
```

`build-scout.sh`:
1. creates the worktree at the sushy tip + inits the `pxe/ipxe` submodule;
2. applies the strip-NVIDIA overlay (`apply-overlay.sh`, both arches);
3. builds `Dockerfile.builder` if missing;
4. runs `cargo make build-boot-artifacts-x86-host` in a privileged container;
5. extracts the three blobs to `out/<arch>/`.

### aarch64

The overlay and script cover aarch64, **but** upstream flags the *local* arm
boot-artifact build as incomplete (“no support for building arm images
locally”, `pxe/Makefile.toml`). A working aarch64 build needs a **native arm64
builder host** (run `./build-scout.sh aarch64` there) or the upstream CI cross
pipeline. On an x86_64 host the arm target is not expected to complete.

## Seeding into nico-pxe

`nico-pxe` serves `carbide` static blobs from an `emptyDir` populated by
`bootArtifactContainers` init containers. Package the three blobs into an OCI
image (or host them) and point the e2e overlay's
`nico-pxe.bootArtifactContainers` at `blobs/internal/<arch>/`. See
`../../scout-discovery-os.md` and the e2e runbook (Phase D).

## Cleanup

```bash
git -C ~/Code/github.com/NVIDIA/infra-controller worktree remove --force ~/nico-e2e-sno/scout-build/src
podman rmi localhost/nico-scout-builder:noble
```
