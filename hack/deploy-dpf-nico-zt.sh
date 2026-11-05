#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE=${STAGE:-all}
DRY_RUN=${DRY_RUN:-false}
DPF_NAMESPACE=${DPF_NAMESPACE:-dpf-operator-system}
CLUSTERS_NAMESPACE=${CLUSTERS_NAMESPACE:-clusters}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-7200}
NICO_DPU_AGENT_HOST_LIBRARY_PATH=${NICO_DPU_AGENT_HOST_LIBRARY_PATH:-/usr/lib64}
NICO_DPU_AGENT_CHART_VERSION=${NICO_DPU_AGENT_CHART_VERSION:-0.1.5}
NICO_DPU_AGENT_CHART_SOURCE=${NICO_DPU_AGENT_CHART_SOURCE:-$ROOT_DIR/helm/vendor/infra-controller/bluefield/charts/nico-dpu-agent}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "set $name before running this target"
}

for name in DPF_AUTOMATION_DIR SITE NICO_DPU_DEPLOYMENT_NAME HOSTED_CLUSTER_NAME; do
  need "$name"
done
if [[ "$STAGE" == all || "$STAGE" == nico ]]; then
  need SITE_NAME
fi
if [[ "$STAGE" == all || "$STAGE" == hosted || "$STAGE" == verify ]]; then
  need HOSTED_KUBECONFIG
fi

[[ "$NICO_DPU_DEPLOYMENT_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || \
  fail "NICO_DPU_DEPLOYMENT_NAME is not a valid Kubernetes resource name"
[[ "$STAGE" =~ ^(all|dpf|nico|hosted|verify)$ ]] || \
  fail "STAGE must be one of: all, dpf, nico, hosted, verify"
[[ "$DRY_RUN" =~ ^(true|false)$ ]] || fail "DRY_RUN must be true or false"
[[ "$SITE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "SITE must contain only lowercase letters, digits, and hyphens"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "TIMEOUT_SECONDS must be a positive integer"
[[ "$NICO_DPU_AGENT_HOST_LIBRARY_PATH" == /* ]] || \
  fail "NICO_DPU_AGENT_HOST_LIBRARY_PATH must be an absolute host path"

DPF_AUTOMATION_DIR=$(cd "$DPF_AUTOMATION_DIR" 2>/dev/null && pwd) || \
  fail "DPF_AUTOMATION_DIR does not exist"
[[ -f "$DPF_AUTOMATION_DIR/Makefile" && -f "$DPF_AUTOMATION_DIR/.env" ]] || \
  fail "DPF_AUTOMATION_DIR must contain Makefile and .env"
[[ -f "$DPF_AUTOMATION_DIR/scripts/env.sh" ]] || \
  fail "DPF checkout is missing scripts/env.sh"
grep -q 'NICO_ENABLED' "$DPF_AUTOMATION_DIR/scripts/env.sh" || \
  fail "DPF checkout lacks the NICO_ENABLED integration changes"

SITE_VALUES="$ROOT_DIR/helm/values/nico-core-${SITE}.yaml"
PREREQS_VALUES="$ROOT_DIR/helm/values/prereqs-${SITE}.yaml"
SITE_INFRA_VALUES="$ROOT_DIR/helm/values/infra-site-${SITE}.yaml"
for file in "$SITE_VALUES" "$PREREQS_VALUES" "$SITE_INFRA_VALUES"; do
  [[ -f "$file" ]] || fail "missing site configuration: $file"
done
grep -Fq "$NICO_DPU_DEPLOYMENT_NAME" "$SITE_VALUES" || \
  fail "$SITE_VALUES does not reference DPUDeployment $NICO_DPU_DEPLOYMENT_NAME"

if [[ -n "${KUBECONFIG:-}" ]]; then
  [[ -f "$KUBECONFIG" ]] || fail "KUBECONFIG does not exist: $KUBECONFIG"
  KUBECONFIG=$(cd "$(dirname "$KUBECONFIG")" && pwd)/$(basename "$KUBECONFIG")
  export KUBECONFIG
fi
if [[ -n "${HOSTED_KUBECONFIG:-}" ]]; then
  [[ -d "$(dirname "$HOSTED_KUBECONFIG")" ]] || fail "HOSTED_KUBECONFIG parent directory does not exist"
  HOSTED_KUBECONFIG=$(cd "$(dirname "$HOSTED_KUBECONFIG")" && pwd)/$(basename "$HOSTED_KUBECONFIG")
  export HOSTED_KUBECONFIG
fi

show_plan() {
  echo "DPF + NICo Zero Trust deployment (stage: $STAGE)"
  echo "  DPF checkout: $DPF_AUTOMATION_DIR"
  echo "  NICo site: $SITE"
  echo "  DPUDeployment: $NICO_DPU_DEPLOYMENT_NAME"
  echo "  HostedCluster: $HOSTED_CLUSTER_NAME (namespace: $CLUSTERS_NAMESPACE)"
  echo "  Management kubeconfig: ${KUBECONFIG:-current oc context}"
  echo "  Hosted kubeconfig: ${HOSTED_KUBECONFIG:-not used in this stage}"
  echo "  DPU-agent chart: $NICO_DPU_AGENT_CHART_VERSION ($NICO_DPU_AGENT_CHART_SOURCE)"
  case "$STAGE" in
    all)
      echo "  1. DPF platform in NICO_ENABLED=true mode"
      echo "  2. NICo cloud, site charts, and site-agent (MetalLB supplied by DPF)"
      echo "  3. HCP creation and hosted-cluster DPF authorization"
      echo "  4. DPU-agent chart publication and RHCOS host-library configuration"
      echo "  5. DPU and hosted-node readiness checks"
      ;;
    dpf) echo "  DPF platform in NICO_ENABLED=true mode" ;;
    nico) echo "  NICo cloud, site charts, and site-agent (MetalLB supplied by DPF)" ;;
    hosted) echo "  HCP creation, hosted-cluster DPF authorization, DPU-agent chart publication, and readiness checks" ;;
    verify) echo "  Read-only DPU, HostedCluster, and hosted-node readiness checks" ;;
  esac
  echo "  External host reboot remains a manual DPF gate; this script will not reboot it."
}

if [[ "$DRY_RUN" == true ]]; then
  show_plan
  exit 0
fi

need KUBECONFIG
[[ -f "$KUBECONFIG" ]] || fail "KUBECONFIG does not exist: $KUBECONFIG"
KUBECONFIG=$(cd "$(dirname "$KUBECONFIG")" && pwd)/$(basename "$KUBECONFIG")
export KUBECONFIG
if [[ "$STAGE" == verify && ! -f "$HOSTED_KUBECONFIG" ]]; then
  fail "HOSTED_KUBECONFIG does not exist: $HOSTED_KUBECONFIG"
fi

for bin in make oc helm jq python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "required command not found: $bin"
done
oc whoami >/dev/null 2>&1 || fail "oc is not logged in to the management cluster"
if [[ "$STAGE" == all || "$STAGE" == nico ]]; then
  make -C "$ROOT_DIR" check-prereqs
fi

run_dpf() {
  local -a extra_vars=(
    DPF_DEPLOYMENT_MODE=zero-trust
    NICO_ENABLED=true
    NICO_DPU_DEPLOYMENT_NAME="$NICO_DPU_DEPLOYMENT_NAME"
    HOSTED_CLUSTER_NAME="$HOSTED_CLUSTER_NAME"
    CLUSTERS_NAMESPACE="$CLUSTERS_NAMESPACE"
  )
  [[ -z "${KUBECONFIG:-}" ]] || extra_vars+=("KUBECONFIG=$KUBECONFIG")
  [[ -z "${HOSTED_KUBECONFIG:-}" ]] || extra_vars+=("HOSTED_KUBECONFIG=$HOSTED_KUBECONFIG")
  make -C "$DPF_AUTOMATION_DIR" "$@" "${extra_vars[@]}"
}

wait_for_dpu_deployment() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  until oc -n "$DPF_NAMESPACE" get dpudeployment "$NICO_DPU_DEPLOYMENT_NAME" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || fail "timed out waiting for NICo DPUDeployment $NICO_DPU_DEPLOYMENT_NAME"
    echo "Waiting for NICo DPUDeployment $NICO_DPU_DEPLOYMENT_NAME..."
    sleep 10
  done
}

wait_for_hosted_cluster() {
  echo "Waiting for HostedCluster $HOSTED_CLUSTER_NAME to become Available..."
  oc wait -n "$CLUSTERS_NAMESPACE" \
    --for=condition=Available "hostedcluster/$HOSTED_CLUSTER_NAME" \
    --timeout="${TIMEOUT_SECONDS}s"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  until [[ -f "$HOSTED_KUBECONFIG" ]]; do
    (( SECONDS < deadline )) || fail "timed out waiting for hosted kubeconfig $HOSTED_KUBECONFIG"
    echo "Waiting for hosted kubeconfig $HOSTED_KUBECONFIG..."
    sleep 10
  done
}

external_reboot_pending() {
  oc -n "$DPF_NAMESPACE" get dpunodes.provisioning.dpu.nvidia.com -o json |
    jq -e '[.items[] | select((.metadata.annotations // {})["provisioning.dpu.nvidia.com/dpunode-external-reboot-required"] == "true")] | length > 0' \
      >/dev/null
}

configure_dpu_agent_host_libraries() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local patch_file
  patch_file=$(mktemp)

  echo "Waiting for DPF DPUServiceConfiguration carbide-dpu-agent..."
  until oc -n "$DPF_NAMESPACE" get dpuserviceconfiguration carbide-dpu-agent >/dev/null 2>&1; do
    (( SECONDS < deadline )) || fail "timed out waiting for DPUServiceConfiguration carbide-dpu-agent"
    sleep 10
  done

  python3 - "$NICO_DPU_AGENT_HOST_LIBRARY_PATH" > "$patch_file" <<'PY'
import json
import sys

print(json.dumps({
    "spec": {
        "serviceConfiguration": {
            "helmChart": {
                "values": {
                    "lldpSidecar": {
                        "hostLibraryPath": sys.argv[1],
                        "ldLibraryPath": None,
                    },
                },
            },
        },
    },
}))
PY

  oc -n "$DPF_NAMESPACE" patch dpuserviceconfiguration carbide-dpu-agent \
    --type=merge --patch-file="$patch_file"
  oc -n "$DPF_NAMESPACE" get dpuserviceconfiguration carbide-dpu-agent -o json |
    python3 -c 'import json,sys; x=json.load(sys.stdin); v=x["spec"]["serviceConfiguration"]["helmChart"]["values"]["lldpSidecar"]; assert v.get("hostLibraryPath"); assert not v.get("ldLibraryPath"); print("Configured LLDP sidecar host library directory:", v["hostLibraryPath"])'
  rm -f "$patch_file"
}

publish_dpu_agent_chart() {
  echo "=== Publishing the RHCOS-compatible NICo DPU-agent chart ==="
  CHART_SOURCE="$NICO_DPU_AGENT_CHART_SOURCE" \
    CHART_VERSION="$NICO_DPU_AGENT_CHART_VERSION" \
    HOST_LIBRARY_PATH="$NICO_DPU_AGENT_HOST_LIBRARY_PATH" \
    DPF_NAMESPACE="$DPF_NAMESPACE" \
    DRY_RUN=false \
    bash "$ROOT_DIR/hack/publish-dpf-dpu-agent-chart.sh"
}

verify_ready() {
  local selector="svc.dpu.nvidia.com/owned-by-dpudeployment=${DPF_NAMESPACE}_${NICO_DPU_DEPLOYMENT_NAME}"
  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local dpu_json hosted_json

  if external_reboot_pending; then
    echo "DPF is waiting for an external host reboot. Reboot the requested host,"
    echo "wait for it to return, then remove the DPUNode external-reboot annotation"
    echo "as required by DPF. Resume without redeploying by rerunning the same make"
    echo "command with STAGE=verify."
    return 2
  fi

  while (( SECONDS < deadline )); do
    dpu_json=$(oc -n "$DPF_NAMESPACE" get dpu -l "$selector" -o json 2>/dev/null || printf '{"items":[]}')
    hosted_json=$(oc --kubeconfig="$HOSTED_KUBECONFIG" get nodes -o json 2>/dev/null || printf '{"items":[]}')
    if jq -e '
      (.items | length > 0) and
      all(.items[];
        any(.status.conditions[]?; .type == "Ready" and .status == "True") and
        any(.status.operationalConditions[]?; .type == "OperationalReady" and .status == "True")
      )
    ' <<<"$dpu_json" >/dev/null && jq -e '
      (.items | length > 0) and
      any(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    ' <<<"$hosted_json" >/dev/null; then
      echo "DPF DPU and hosted worker are Ready."
      oc -n "$DPF_NAMESPACE" get dpu -l "$selector"
      oc --kubeconfig="$HOSTED_KUBECONFIG" get nodes
      return 0
    fi
    echo "Waiting for DPU OperationalReady and a Ready hosted worker..."
    sleep 15
  done

  echo "Timed out before DPU and hosted worker became Ready. Current status:" >&2
  oc -n "$DPF_NAMESPACE" get dpu -l "$selector" -o wide >&2 || true
  oc --kubeconfig="$HOSTED_KUBECONFIG" get nodes -o wide >&2 || true
  return 1
}

show_plan

if [[ "$STAGE" == all || "$STAGE" == dpf ]]; then
  echo "=== Deploying DPF Zero Trust platform in NICo ownership mode ==="
  run_dpf all-zt
  [[ "$STAGE" == all ]] || exit 0
fi

if [[ "$STAGE" == all || "$STAGE" == nico ]]; then
  echo "=== Deploying NICo cloud ==="
  make -C "$ROOT_DIR" deploy-all-cloud
  echo "=== Deploying NICo site $SITE ==="
  make -C "$ROOT_DIR" deploy-all-site SITE="$SITE" METALLB_MODE=dpf
  echo "=== Registering the NICo site-agent ==="
  site_id_b64=$(oc -n nico-system get secret site-registration \
    -o jsonpath='{.data.site-uuid}' 2>/dev/null || true)
  if [[ -n "$site_id_b64" ]]; then
    site_id=$(python3 -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' "$site_id_b64")
    make -C "$ROOT_DIR" deploy-site-agent SITE_ID="$site_id"
  else
    make -C "$ROOT_DIR" deploy-site-agent SITE_NAME="$SITE_NAME"
  fi
  [[ "$STAGE" == all ]] || exit 0
fi

if [[ "$STAGE" == all || "$STAGE" == hosted ]]; then
  echo "=== Waiting for NICo's DPUDeployment ==="
  wait_for_dpu_deployment
  echo "=== Creating the HostedCluster through the DPF HCP provisioner ==="
  run_dpf deploy-hosted-cluster
  wait_for_hosted_cluster
  echo "=== Applying DPF Zero Trust authorization to the HostedCluster ==="
  publish_dpu_agent_chart
  run_dpf deploy-zt-dpu-services
  echo "=== Configuring the DPU agent host runtime libraries for RHCOS ==="
  configure_dpu_agent_host_libraries
  [[ "$STAGE" == all ]] || exit 0
fi

verify_ready
