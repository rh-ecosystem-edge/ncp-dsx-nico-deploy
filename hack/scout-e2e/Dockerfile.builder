# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Posture 3 (e2e) Scout build environment.
#
# The upstream Scout boot artifacts are built with mkosi + debootstrap against
# Ubuntu 24.04 (noble) -- tooling that is not on the RHEL/Fedora dev host. This
# image reproduces the upstream build environment so the mkosi + cargo-make
# pipeline runs unchanged (minus the NVIDIA stack, stripped by apply-overlay.sh)
# inside a privileged podman container. Keeps the host clean. See
# scout-discovery-os.md (Posture 3) and build-scout.sh.
FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Build + image-assembly toolchain. mkosi/debootstrap build the Ubuntu-noble
# UKI (scout.efi) and rootfs (scout.squashfs); the -dev libs are what
# carbide-scout links against (libudev, tpm2-tss, openssl); the systemd-ukify /
# systemd-boot / ovmf / mtools / dosfstools set is what mkosi needs to emit a
# bootable UKI; protobuf-compiler is for the rpc crate.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zstd cpio jq \
      build-essential pkg-config cmake clang libclang-dev \
      mkosi debootstrap \
      systemd systemd-boot systemd-boot-efi systemd-ukify \
      ovmf mtools dosfstools squashfs-tools e2fsprogs \
      qemu-utils qemu-user-static binfmt-support \
      libudev-dev libtss2-dev libssl-dev \
      python3 python3-pip sudo \
    && rm -rf /var/lib/apt/lists/*

# protoc from the official release (not distro protobuf-compiler): it bundles
# include/google/protobuf/*.proto and auto-resolves the well-known types, which
# the carbide-rpc build.rs codegen needs. Same version/approach as
# docker/ubi/Dockerfile.nico-core.
RUN curl -sLO https://github.com/protocolbuffers/protobuf/releases/download/v36.1/protoc-36.1-linux-x86_64.zip && \
    unzip protoc-36.1-linux-x86_64.zip -d /usr/local && \
    rm protoc-36.1-linux-x86_64.zip && \
    chmod -R a+rX /usr/local/include/google

# Rust toolchain via rustup so the worktree's rust-toolchain.toml drives the
# exact channel. cargo-make orchestrates the pxe build targets; cargo-deb
# packages forge-scout into the .deb the mkosi postinst dpkg-installs.
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --default-toolchain stable --profile minimal && \
    cargo install cargo-make cargo-deb && \
    chmod -R a+rwX /opt/rust

# Expose PROTOC for build scripts that look it up.
ENV PROTOC=/usr/local/bin/protoc

WORKDIR /work
ENTRYPOINT ["/bin/bash"]
