#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Apply the Posture 3 (e2e) strip-NVIDIA overlay to a throwaway infra-controller
# worktree. Idempotent. Never touches the vendored submodule -- it operates on
# the scratch source tree given by $1 (default: the worktree build-scout.sh
# creates). See scout-discovery-os.md (Posture 3).
#
#   apply-overlay.sh [SRC_TREE]
#
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$HOME/nico-e2e-sno/scout-build/src}"

if [ ! -d "$SRC/pxe/mkosi.profiles" ]; then
  echo "ERROR: $SRC does not look like an infra-controller tree (no pxe/mkosi.profiles)" >&2
  exit 1
fi

# Guard: refuse to run against the vendored submodule.
case "$SRC" in
  *helm/vendor/infra-controller*)
    echo "ERROR: refusing to overlay the vendored submodule ($SRC)" >&2
    exit 1
    ;;
esac

for arch in x86_64 aarch64; do
  prof="$SRC/pxe/mkosi.profiles/scout-oss-${arch}"
  [ -d "$prof" ] || { echo "skip: no profile $prof"; continue; }

  echo "== overlaying scout-oss-${arch} =="

  # 1. Replace the oss postinst with the NVIDIA-free minimal one.
  install -m 0755 "$HERE/postinst.minimal.chroot" "$prof/mkosi.postinst.chroot"

  # 2. Drop the NVIDIA CUDA apt source (no GPU stack to install) and the
  #    internal forge apt source (carbide-pxe.forge is unreachable at build
  #    time and nothing minimal pulls from it).
  rm -f "$prof/mkosi.extra/etc/apt/sources.list.d/nvidia.list"
  rm -f "$prof/mkosi.extra/etc/apt/sources.list.d/forge.list"
  rm -f "$prof/mkosi.extra/etc/apt/trusted.gpg.d/nvidia-cuda-"*.asc* 2>/dev/null || true

  echo "   postinst -> minimal; nvidia.list/forge.list removed"
done

echo "overlay applied to $SRC"
