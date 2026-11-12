#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build the Posture 3 (e2e) minimal Scout boot artifacts -- ipxe.efi, scout.efi
# (NVIDIA-free loader UKI), scout.squashfs (NVIDIA-free rootfs with the real
# forge-scout) -- from the fork sushy tip, in a privileged podman container that
# reproduces the upstream Ubuntu-noble mkosi build environment. The vendored
# submodule is never touched; all work happens in a throwaway git worktree.
# See scout-discovery-os.md (Posture 3) and hack/scout-e2e/README.md.
#
#   build-scout.sh [x86_64|aarch64]
#
# Prereqs: podman; the fork checkout at $FORK_REPO knowing the sushy tip.
#
# NOTE on aarch64: upstream flags the *local* arm boot-artifact build as
# incomplete ("no support for building arm images locally", pxe/Makefile.toml).
# The strip overlay and this script cover aarch64, but a working aarch64 build
# needs a native arm64 builder host (or the upstream CI cross pipeline); on an
# x86_64 host the arm target is not expected to complete. x86_64 is validated.
set -Eeuo pipefail

ARCH="${1:-x86_64}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config -----------------------------------------------------------------
FORK_REPO="${FORK_REPO:-$HOME/Code/github.com/NVIDIA/infra-controller}"
SUSHY_REF="${SUSHY_REF:-3892898925e851cdcfaab650930e08cf4dd20745}"   # v2.2.0-pr-452, fork sushy tip
WORKROOT="${WORKROOT:-$HOME/nico-e2e-sno/scout-build}"
SRC="$WORKROOT/src"
OUT="$WORKROOT/out/$ARCH"
IMAGE="${IMAGE:-localhost/nico-scout-builder:noble}"

# Drive the exact sub-targets Scout needs, NOT the umbrella
# build-boot-artifacts-*-host. The umbrella also runs cargo-make's built-in
# `build` (whole workspace -> carbide-api needs a running Postgres for sqlx and
# carbide-dhcp needs libkea, neither present here) and setup-apt-repo (for the
# forge.list we strip). package-scout builds only carbide-scout;
# create-ephemeral-image stages + mkosi-builds scout.efi + scout.squashfs;
# ipxe builds ipxe.efi.
case "$ARCH" in
  x86_64)
    PKG_TARGET="package-scout-x86_64-release-local"
    EPH_TARGET="create-ephemeral-image-x86-host"
    IPXE_TARGET="ipxe-x86_64"; BLOBDIR="x86_64" ;;
  aarch64)
    PKG_TARGET="package-scout-aarch64-release-local"
    EPH_TARGET="create-ephemeral-image-arm-host"
    IPXE_TARGET="ipxe-aarch64"; BLOBDIR="aarch64" ;;
  *) echo "ERROR: arch must be x86_64 or aarch64" >&2; exit 1 ;;
esac

# --- 1. throwaway worktree at the sushy tip ---------------------------------
if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/.git" ]; then
  echo "== creating worktree at $SUSHY_REF =="
  mkdir -p "$WORKROOT"
  git -C "$FORK_REPO" worktree add --detach "$SRC" "$SUSHY_REF"
fi
echo "== worktree: $(git -C "$SRC" describe --tags --always) =="

# The boot-artifact build needs two submodules checked out in the worktree:
# pxe/mkosi (systemd/mkosi, invoked via pxe/mkosi/bin/mkosi -- NOT the system
# mkosi) and pxe/ipxe/upstream (the iPXE source ipxe-<arch> builds). Init all.
git -C "$SRC" submodule update --init --recursive

# --- 2. apply the strip-NVIDIA overlay --------------------------------------
"$HERE/apply-overlay.sh" "$SRC"

# --- 3. builder image -------------------------------------------------------
if ! podman image exists "$IMAGE"; then
  echo "== building builder image $IMAGE =="
  podman build -t "$IMAGE" -f "$HERE/Dockerfile.builder" "$HERE"
fi

# --- 4. run the mkosi + cargo-make pipeline inside the container -------------
# Privileged: mkosi needs loop devices, mount, and debootstrap. The worktree is
# bind-mounted rw (build writes into pxe/static and target/); package cache is
# persisted to speed re-runs.
mkdir -p "$OUT" "$WORKROOT/mkosi-cache" "$WORKROOT/var-tmp" "$WORKROOT/tmp"
echo "== running $PKG_TARGET + $EPH_TARGET + $IPXE_TARGET in container =="
# $SRC is a linked git worktree: its .git file points at the parent repo's
# gitdir ($FORK_REPO/.git/worktrees/...), and the ipxe submodule's gitdir link
# is RELATIVE to the worktree's host location. Mount BOTH the worktree and the
# parent repo at their own host paths so every absolute and relative git
# reference resolves inside the container exactly as on the host. --privileged
# runs unconfined, so no :z relabel is needed on the large repo mounts.
# mkosi does its assembly under /var/tmp (workspace) and /tmp (output staging)
# with `cp --preserve=xattr`. The apt cache / tool-tree files carry SELinux
# security.* xattrs; the container's own /tmp and /var/tmp are on podman's
# overlay upperdir, which rejects copying those xattrs ("Operation not
# supported"). Bind-mount host btrfs dirs over both so the xattr copies land on
# a filesystem that supports them.
podman run --rm --privileged \
  -v "$SRC":"$SRC" \
  -v "$FORK_REPO":"$FORK_REPO" \
  -v "$WORKROOT/mkosi-cache":"$SRC/pxe/.mkosi-package-cache" \
  -v "$WORKROOT/var-tmp":/var/tmp \
  -v "$WORKROOT/tmp":/tmp \
  -w "$SRC/pxe" \
  -e CARGO_HOME="$SRC/.cargo-home" \
  "$IMAGE" -lc "
    set -Eeuxo pipefail
    git config --global --add safe.directory '*'
    # package-scout is a root-workspace task (workspace=false, path=REPO_ROOT).
    cd '$SRC' && cargo make ${PKG_TARGET}
    # ephemeral image + ipxe are pxe/ tasks.
    cd '$SRC/pxe' && cargo make ${EPH_TARGET} && cargo make ${IPXE_TARGET}
  "

# --- 5. extract artifacts ---------------------------------------------------
SB="$SRC/pxe/static/blobs/internal/$BLOBDIR"
echo "== extracting artifacts from $SB =="
missing=0
for f in ipxe.efi scout.efi scout.squashfs qcow-imager.efi; do
  if [ -f "$SB/$f" ]; then
    cp -v "$SB/$f" "$OUT/$f"
  else
    echo "MISSING: $SB/$f" >&2
    missing=1
  fi
done
[ "$missing" = 0 ] || { echo "ERROR: not all artifacts were produced" >&2; exit 1; }

echo ""
echo "== Posture 3 artifacts ($ARCH) =="
ls -lh "$OUT"
echo "Seed these into nico-pxe via bootArtifactContainers -- see scout-discovery-os.md"
