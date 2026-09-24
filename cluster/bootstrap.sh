#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Self-contained cluster bootstrap for NICo test beds.
#
# Installs a single-node OpenShift (SNO) on a local libvirt VM with a static
# IP via the Assisted Installer (aicli), then deploys LVM Storage so the
# cluster has a default StorageClass (required by NICo's PG/Vault/NATS/
# Temporal PVCs). Logic is a trimmed, standalone extraction of the
# openshift-dpf automation's cluster chain (rh-ecosystem-edge/openshift-dpf,
# scripts/cluster.sh + vm.sh), reduced to the SNO path only.
#
# Usage:
#   bootstrap.sh install NICO_BASE_DOMAIN=example.com NICO_API_IP=10.0.0.5 \
#       NICO_GW=10.0.0.1 NICO_DNS=10.0.0.2 [NICO_...=...]
#   bootstrap.sh clean  [NICO_CLUSTER_NAME=...]
#
# All configuration is NICO_* env vars (or KEY=VALUE args); defaults below.
# Idempotent: if the cluster is already installed it only (re)downloads the
# kubeconfig and exits.

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
NICO_CLUSTER_NAME="${NICO_CLUSTER_NAME:-nico-lab}"
NICO_OPENSHIFT_VERSION="${NICO_OPENSHIFT_VERSION:-4.22.7-multi}"
NICO_PULL_SECRET="${NICO_PULL_SECRET:-openshift_pull.json}"
NICO_SSH_PUB_KEY="${NICO_SSH_PUB_KEY:-}"          # default: first of ~/.ssh/{id_ed25519,id_rsa}.pub
NICO_VM_PREFIX="${NICO_VM_PREFIX:-vm-${NICO_CLUSTER_NAME}}"
NICO_RAM="${NICO_RAM:-41984}"                      # MiB
NICO_VCPUS="${NICO_VCPUS:-14}"
NICO_DISK1="${NICO_DISK1:-120}"                    # GiB (root + platform)
NICO_DISK2="${NICO_DISK2:-80}"                     # GiB (spare disk -> LVMS)
NICO_DISK_PATH="${NICO_DISK_PATH:-/var/lib/libvirt/images}"
NICO_BRIDGE="${NICO_BRIDGE:-}"                     # default: auto-detect first UP bridge
NICO_PRIMARY_IFACE="${NICO_PRIMARY_IFACE:-enp1s0}" # host NIC the bridge uses
NICO_NETMASK="${NICO_NETMASK:-24}"
NICO_OLM_WORKAROUND="${NICO_OLM_WORKAROUND:-true}" # LVMS via previous-minor catalog
# Required (no default): NICO_BASE_DOMAIN, NICO_API_IP, NICO_GW, NICO_DNS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_NET_FILE="${SCRIPT_DIR}/static_net.yaml"
KUBECONFIG_FILE="${SCRIPT_DIR}/kubeconfig"
ADMIN_PASS_FILE="${SCRIPT_DIR}/kubeadmin-password.${NICO_CLUSTER_NAME}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
retry() { local n=$1 d=$2; shift 2; for ((i=1;i<=n;i++)); do "$@" && return 0; [ $i -eq $n ] && return 1; sleep "$d"; done; return 1; }

# --- KEY=VALUE arg parsing ----------------------------------------------------
# KEY=VALUE args override the defaults above; empty values are ignored so
# the Makefile can pass unset variables through harmlessly.
for arg in "$@"; do
    [[ "$arg" == *=* ]] || continue
    key="${arg%%=*}"
    val="${arg#*=}"
    [ -n "$val" ] && export "$key=$val"
done

cluster_status() { aicli info cluster "$NICO_CLUSTER_NAME" -f status -v 2>/dev/null || echo unknown; }

check_preflight() {
    local missing=()
    for bin in aicli virt-install virsh oc md5sum; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"
    aicli list clusters >/dev/null 2>&1 \
        || die "aicli is not authenticated (try 'aicli login', or set up ~/.aicli/offlinetoken.txt)"
    resolve_bridge
}

# Bridge for the VM: explicit NICO_BRIDGE wins; otherwise auto-detect the
# first UP non-virtual bridge on the host so the default run works OOTB.
resolve_bridge() {
    if [ -n "$NICO_BRIDGE" ]; then
        ip link show "$NICO_BRIDGE" >/dev/null 2>&1 \
            || die "bridge $NICO_BRIDGE does not exist. Create it first, e.g.:
  nmcli connection add type bridge con-name $NICO_BRIDGE ifname $NICO_BRIDGE
  nmcli connection up $NICO_BRIDGE
  nmcli connection modify $NICO_BRIDGE +ipv4.address <host-ip>/<pl>
  nmcli connection modify $NICO_BRIDGE +ipv4.gateway $NICO_GW
  nmcli connection modify $NICO_BRIDGE ipv4.method manual && nmcli connection up $NICO_BRIDGE"
        return 0
    fi
    local b
    for b in $(ip -o link show type bridge 2>/dev/null | awk '{print $2}' | cut -d@ -f1 | tr -d ':'); do
        case "$b" in virbr*|docker*|kube*|cali*|flannel*) continue ;; esac
        if ip link show "$b" 2>/dev/null | grep -q "state UP"; then
            NICO_BRIDGE="$b"
            log "Auto-detected bridge: $b (override with NICO_BRIDGE)"
            return 0
        fi
    done
    die "no usable bridge found on this host. Create one, e.g.:
  nmcli connection add type bridge con-name mgmt-br ifname mgmt-br
  nmcli connection up mgmt-br
  nmcli connection modify mgmt-br +ipv4.address <host-ip>/<pl>
  nmcli connection modify mgmt-br +ipv4.gateway $NICO_GW
  nmcli connection modify mgmt-br ipv4.method manual && nmcli connection up mgmt-br"
}

# Deterministic local MAC from the cluster name (stable across re-runs).
vm_mac() {
    local hex
    hex=$(echo -n "$NICO_CLUSTER_NAME" | md5sum | cut -c1-6)
    echo "52:54:00:${hex}"
}

write_static_net() {
    local mac
    mac=$(vm_mac)
    log "Static IP config: ${NICO_API_IP}/${NICO_NETMASK}, GW ${NICO_GW}, DNS ${NICO_DNS}, iface ${NICO_PRIMARY_IFACE}, MAC ${mac}"
    cat > "$STATIC_NET_FILE" <<EOF
static_network_config:
- interfaces:
   - name: ${NICO_PRIMARY_IFACE}
     type: ethernet
     state: up
     mtu: 1500
     mac-address: '${mac}'
     ipv4:
       enabled: true
       dhcp: false
       address:
         - ip: ${NICO_API_IP}
           prefix-length: ${NICO_NETMASK}
  dns-resolver:
    config:
      server:
        - ${NICO_DNS}
  routes:
    config:
      - destination: 0.0.0.0/0
        next-hop-address: ${NICO_GW}
        next-hop-interface: ${NICO_PRIMARY_IFACE}
EOF
}

create_cluster() {
    local ssh_key="${NICO_SSH_PUB_KEY:-$(ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -1)}"
    [ -n "$ssh_key" ] || die "no SSH public key found (set NICO_SSH_PUB_KEY)"
    [ -f "$ssh_key" ] || die "SSH public key not found: $ssh_key"
    [ -f "$NICO_PULL_SECRET" ] || die "pull secret not found: $NICO_PULL_SECRET"

    log "Creating cluster ${NICO_CLUSTER_NAME} (${NICO_OPENSHIFT_VERSION}, SNO)..."
    aicli create cluster \
        -P openshift_version="${NICO_OPENSHIFT_VERSION}" \
        -P base_dns_domain="${NICO_BASE_DOMAIN}" \
        -P pull_secret="${NICO_PULL_SECRET}" \
        -P high_availability_mode=None \
        -P public_key="${ssh_key}" \
        -P user_managed_networking=True \
        --paramfile "${STATIC_NET_FILE}" \
        "${NICO_CLUSTER_NAME}"
}

wait_status() {
    local status=$1 max_retries=$2 current
    log "Waiting for cluster ${NICO_CLUSTER_NAME} to reach status: ${status} (up to ${max_retries} min)"
    for ((i=1;i<=max_retries;i++)); do
        current=$(cluster_status)
        if [ "$status" = "ready" ] && [ "$current" = "installed" ]; then
            log "Cluster already installed; skipping wait for 'ready'."
            return 0
        fi
        if [ "$current" = "$status" ]; then
            log "Cluster status: ${status}"
            return 0
        fi
        log "status=${current} (attempt ${i}/${max_retries})"
        sleep 60
    done
    die "timeout waiting for cluster status ${status}"
}

create_vm() {
    local vm="${NICO_VM_PREFIX}1"
    if virsh list --all --name | grep -qx "$vm"; then
        log "VM ${vm} already exists"
        virsh start "$vm" 2>/dev/null || true
        return 0
    fi
    mkdir -p "$NICO_DISK_PATH"
    log "Creating VM ${vm} (${NICO_VCPUS} vCPU, ${NICO_RAM} MiB, ${NICO_DISK1}+${NICO_DISK2} GiB)..."
    nohup virt-install --connect "qemu:///system" --name "$vm" \
        --memory "$NICO_RAM" --vcpus "$NICO_VCPUS" \
        --os-variant=rhel9.4 \
        --disk "path=${NICO_DISK_PATH}/${vm}-disk1.qcow2,size=${NICO_DISK1}" \
        --disk "path=${NICO_DISK_PATH}/${vm}-disk2.qcow2,size=${NICO_DISK2}" \
        --network "bridge=${NICO_BRIDGE},model=virtio,mac=$(vm_mac)" \
        --graphics=vnc --events on_reboot=restart \
        --cdrom "${NICO_DISK_PATH}/${NICO_CLUSTER_NAME}.iso" \
        --cpu host-passthrough --boot uefi --noautoconsole --wait=-1 \
        >"${SCRIPT_DIR}/virt-install.log" 2>&1 &
    # Give the inspector a moment to register before waiting for 'ready'.
    sleep 60
}

deploy_lvm() {
    local catalog="redhat-operators"
    if [ "$NICO_OLM_WORKAROUND" = "true" ]; then
        # LVMS subscription targets the previous-minor Red Hat catalog
        # (e.g. 4.22 -> 4.21), created by the dpf automation for this
        # deployment. Derive it from the installed OCP version.
        local minor="${NICO_OPENSHIFT_VERSION#*.}"
        minor="${minor%%.*}"
        local olm_version="${NICO_OPENSHIFT_VERSION%%.*}.$((minor - 1))"
        catalog="redhat-operators-v${olm_version}"
        log "Creating workaround CatalogSource ${catalog}..."
        sed -e "s/<OLM_VERSION>/${olm_version}/g" \
            "${SCRIPT_DIR}/manifests/lvm-catalogsource.yaml" | oc apply -f -
    fi

    log "Subscribing to LVMS operator (catalog: ${catalog})..."
    sed -e "s/<CATALOG_SOURCE_NAME>/${catalog}/g" \
        "${SCRIPT_DIR}/manifests/lvm-subscription.yaml" | retry 12 15 oc apply -f -

    log "Waiting for LVMS operator pod..."
    retry 60 10 bash -c "oc get pod -n openshift-storage -l app.kubernetes.io/name=lvms-operator --no-headers | grep -q '1/1.*Running\|^1/1'"

    if ! oc get lvmcluster -n openshift-storage my-lvmcluster >/dev/null 2>&1; then
        log "Creating LVMCluster (auto-selects free disks; ${NICO_DISK2} GiB spare expected)..."
        retry 30 10 oc apply -f "${SCRIPT_DIR}/manifests/lvmcluster.yaml"
    fi

    log "Waiting for LVMS StorageClass..."
    retry 30 10 bash -c "oc get storageclass | grep -q lvms-"
    oc annotate storageclass lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
    log "Default StorageClass ready:"
    oc get storageclass
}

install() {
    check_preflight
    [[ -n "${NICO_BASE_DOMAIN:-}" && -n "${NICO_API_IP:-}" && -n "${NICO_GW:-}" && -n "${NICO_DNS:-}" ]] \
        || die "NICO_BASE_DOMAIN, NICO_API_IP, NICO_GW and NICO_DNS are required"

    if [ "$(cluster_status)" = "installed" ]; then
        log "Cluster ${NICO_CLUSTER_NAME} is already installed."
    else
        write_static_net
        if ! aicli info cluster "$NICO_CLUSTER_NAME" >/dev/null 2>&1; then
            create_cluster
        else
            log "Cluster ${NICO_CLUSTER_NAME} already exists in aicli (status: $(cluster_status))"
        fi
        mkdir -p "$NICO_DISK_PATH"
        log "Downloading installer ISO..."
        aicli download iso "$NICO_CLUSTER_NAME" -p "$NICO_DISK_PATH"
        create_vm
        wait_status "ready" 90
        log "Starting installation..."
        aicli start cluster "$NICO_CLUSTER_NAME"
        wait_status "installed" 120
    fi

    log "Downloading kubeconfig and admin password..."
    ( cd "$SCRIPT_DIR" && aicli download kubeconfig "$NICO_CLUSTER_NAME" && \
      cp "kubeconfig.${NICO_CLUSTER_NAME}" "$KUBECONFIG_FILE" && \
      aicli download kubeadmin-password "$NICO_CLUSTER_NAME" 2>/dev/null || true )
    export KUBECONFIG="$KUBECONFIG_FILE"
    [ -f "$KUBECONFIG_FILE" ] || die "kubeconfig was not created at $KUBECONFIG_FILE"

    deploy_lvm

    log "=== Bootstrap complete ==="
    log "Point oc at the cluster:"
    log "  export KUBECONFIG=${KUBECONFIG_FILE}"
    log "Console: https://console-openshift-console.apps.${NICO_CLUSTER_NAME}.${NICO_BASE_DOMAIN}"
    log "Admin password: ${ADMIN_PASS_FILE}"
}

clean() {
    log "Deleting cluster ${NICO_CLUSTER_NAME}..."
    aicli delete cluster "$NICO_CLUSTER_NAME" -y 2>/dev/null || log "cluster not in aicli (or already gone)"
    for vm in $(virsh list --all --name | grep "^${NICO_VM_PREFIX}" || true); do
        log "Destroying VM ${vm}..."
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" 2>/dev/null || true
        rm -f "${NICO_DISK_PATH}/${vm}"-disk*.qcow2
    done
    rm -f "${NICO_DISK_PATH}/${NICO_CLUSTER_NAME}.iso" "$STATIC_NET_FILE"
    log "Clean complete."
}

cmd="${1:-install}"; shift || true
case "$cmd" in
    install) install "$@" ;;
    clean)   clean "$@" ;;
    *) die "unknown command: $cmd (use 'install' or 'clean')" ;;
esac
