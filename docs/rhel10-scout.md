# RHEL 10 Scout — nico-pxe build

RHEL 10 based NICo Scout discovery OS. Replaces the upstream Ubuntu noble
Scout with a fully RHEL 10 / UBI 10 build, eliminating the NVIDIA private
CUDA apt repo dependency. Validated end-to-end: machine reaches
`HOSTINITIALIZING/DISCOVERED` via forge-scout on RHEL 10 kernel 6.12.x.

## Boot flow

```
iPXE (ipxe.efi)
  → GET /blobs/internal/x86_64/scout.efi          (127 MB UKI)
  → boot: RHEL 10 kernel + loader initrd

Loader OS (scout.efi / scout-rhel10-loader-x86_64)
  scout-loader.service
    → scout-loader.sh
        → forge-scout-network.sh  (select boot NIC from mac= cmdline)
        → curl scout.squashfs from carbide-static-pxe.forge  (315 MB)
        → mksquashfs overlay mounted at /run/nextroot
        → systemctl soft-reboot   (pivot into OSS rootfs)

OSS rootfs (scout.squashfs / scout-rhel10-oss-x86_64)
  NetworkManager → DHCP + DNS (resolves carbide-pxe.forge, carbide-api.forge)
  forge-scout.service
    ExecStartPre: forge-scout-pre.sh
      → reads server_uri, machine_id, pxe_uri from /proc/cmdline
      → curl ${pxe_uri}/api/v0/tls/root_ca → /opt/forge/forge_root.pem
    ExecStart: forge-scout --api=${server_uri} --machine-interface-id=${machine_id}
      → DiscoverMachine gRPC → NICo → HOSTINITIALIZING/DISCOVERED
```

## Profiles

| Profile | Output | Purpose |
|---|---|---|
| `scout-rhel10-loader-x86_64` | `scout.efi` (UKI) | Boots, downloads squashfs, soft-reboots |
| `scout-rhel10-oss-x86_64` | `scout.squashfs` | Full discovery OS with forge-scout |
| `qcow-imager-rhel10-x86_64` | `qcow-imager.efi` | Disk imaging UKI (xfsprogs for XFS) |

Both loader and OSS pin the same kernel NVR: `6.12.0-211.64.1.el10_2`.

## Dockerfile stages

```
rhel-builder            UBI 10 + RHSM — compiles carbide-pxe + forge-scout
rhsm-certs-extractor    UBI 10 + RHSM — extracts /etc/rhsm + /etc/pki/entitlement
mkosi-rhel10-base       UBI 10 + mkosi v27.1 — base for all mkosi builds
qcow-imager-builder     mkosi-rhel10-base → qcow-imager.efi
scout-loader-builder    mkosi-rhel10-base → scout.efi (UKI)
scout-oss-builder       mkosi-rhel10-base → cpio.zst → mksquashfs → scout.squashfs
ipxe-builder            ubuntu:24.04 — iPXE C compilation only
final (ubi-minimal)     all blobs at /forge-boot-artifacts/blobs/internal/x86_64/
```

Build:
```bash
make docker-build-pxe RHSM_ORG_FILE=~/.rhsm_org RHSM_ACTIVATIONKEY_FILE=~/.rhsm_activationkey
make docker-push-pxe
make deploy-site E2E=1
```

## Lessons learned

### mkosi preset ordering (critical)

`run_preset()` in mkosi runs `systemctl --root <root> preset-all` **after**
`run_postinst_scripts()`. Any symlinks created in `mkosi.postinst.chroot`
via `systemctl enable` or `ln -sf` are **overwritten** by `preset-all`
applying `99-default-disable.preset` (`disable *`).

**Fix:** place `enable <service>` directives in
`mkosi.extra/etc/systemd/system-preset/10-<name>.preset`.  
Wrong path: `etc/systemd/systemd-preset/` (with 'd') — systemd ignores this.  
Right path: `etc/systemd/system-preset/` (without 'd').

### mkosi output is a symlink

`mkosi --output-dir /tmp/mkosi-out` with `Output=scout` and `Format=cpio`
produces `/tmp/mkosi-out/scout` as a **symlink** to the actual file
(e.g. `scout.cpio.zst`). Pass `$(readlink -f /tmp/mkosi-out/scout)` to
`zstd` — not the symlink path.

### cpio.zst → squashfs conversion

The upstream cargo-make pipeline converts the mkosi cpio output to squashfs
via `mksquashfs`. Our Dockerfile replicates this:
```bash
zstd -d "$(readlink -f /tmp/mkosi-out/scout)" -c | cpio -id --quiet
mksquashfs /tmp/scout-extract /scout.squashfs -comp zstd -noappend -quiet
```
The `scout-loader.sh` URL pattern (`*.cpio.zst`) triggers `prepare_cpio_rootfs`
(tmpfs pivot); `*.squashfs` triggers `prepare_squashfs_rootfs` (loop+overlay).
Serving as squashfs matches the upstream expectation.

### RHSM certs for mkosi SandboxTrees

`Distribution=rhel` in mkosi needs RHSM client certs to reach subscription
repos inside its dnf sandbox. Pattern used:
1. Register RHSM in the Docker RUN (`subscription-manager register`)
2. Copy live certs: `cp -a /etc/rhsm pxe/mkosi.profiles/rhsm-certs/etc/`  
   and `cp -a /etc/pki/entitlement pxe/mkosi.profiles/rhsm-certs/etc/pki/`
3. `SandboxTrees=../rhsm-certs:/` in mkosi.conf injects them into the sandbox
4. Unregister at `trap ... EXIT`

The `SandboxTrees` path is relative to the **profile's mkosi.conf directory**
(not the invocation directory). From a profile at
`pxe/mkosi.profiles/<profile>/mkosi.conf`, `../rhsm-certs` resolves to
`pxe/mkosi.profiles/rhsm-certs`.

### GPG keys

- **RHEL 10**: copy `/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release` from UBI
  to `usr/share/distribution-gpg-keys/redhat/RPM-GPG-KEY-redhat10-release`
  (major version in filename required by mkosi's `find_rpm_gpgkey`).
- **EPEL 10**: fetched at Docker build time from
  `https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-10` —
  not in any Red Hat signed image; this is a build-time decision, same
  source as `RepositoryKeyFetch` would use.
- Both trees injected via `SandboxTrees=../gpg-keys:/`.

### repo_gpgcheck

RHEL CDN (`cdn.redhat.com`) does not publish `repomd.xml.asc`. Set
`repo_gpgcheck=0` in the mkosi package manager dnf.conf via
`PackageManagerTrees=../pkgmngr-config:/` pointing to a file at
`etc/dnf/dnf.conf` with `[main]\nrepo_gpgcheck=0`. RHSM SSL certs
are the CDN access control mechanism; package-level `gpgcheck=1` stays on.

### RHEL 10 networking in Scout OSS rootfs

Use **NetworkManager** (not systemd-networkd). NM handles DHCP and writes
`/etc/resolv.conf` with the DNS servers provided by the DHCP lease. Without
NM, the OSS rootfs has routing (preserved through soft-reboot by the kernel)
but no DNS — `carbide-pxe.forge` cannot resolve and forge-scout-pre.sh
cannot download `forge_root.pem`, blocking the DiscoverMachine gRPC call.

Preset: `10-forge-scout.preset` enables `NetworkManager.service`,
`chronyd.service`, `forge-scout.service`, `lldpd.service`.

### postinst.chroot must not remove kernel

`mkosi.postinst.chroot` runs **before** `configure_initrd` (UKI assembly).
Do NOT remove `vmlinuz` or kernel files in postinst — mkosi needs them to
assemble the UKI. Only `systemctl enable scout-loader.service` goes in
postinst.chroot. Cleanup (dnf clean, doc removal) goes in finalize.chroot
which runs after the UKI is assembled.
