#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHART_SOURCE=${CHART_SOURCE:-$ROOT_DIR/helm/vendor/infra-controller/bluefield/charts/nico-dpu-agent}
CHART_VERSION=${CHART_VERSION:-0.1.5}
APP_VERSION=${APP_VERSION:-0.1.0}
DPF_NAMESPACE=${DPF_NAMESPACE:-dpf-operator-system}
CHART_REPO_CONFIGMAP=${CHART_REPO_CONFIGMAP:-nico-chart-repo}
CHART_REPO_DEPLOYMENT=${CHART_REPO_DEPLOYMENT:-nico-chart-repo}
CHART_REPO_URL=${CHART_REPO_URL:-https://nico-chart-repo.dpf-operator-system.svc:443}
HOST_LIBRARY_PATH=${HOST_LIBRARY_PATH:-/usr/lib64}
DRY_RUN=${DRY_RUN:-false}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$CHART_SOURCE" ]] || fail "chart source directory not found: $CHART_SOURCE"
[[ "$CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || \
  fail "CHART_VERSION must be a valid Helm chart version"
[[ "$DRY_RUN" =~ ^(true|false)$ ]] || fail "DRY_RUN must be true or false"
[[ "$HOST_LIBRARY_PATH" == /* ]] || fail "HOST_LIBRARY_PATH must be an absolute host path"

for bin in helm oc python3; do
  command -v "$bin" >/dev/null 2>&1 || fail "required command not found: $bin"
done
oc whoami >/dev/null 2>&1 || fail "oc is not logged in to the management cluster"
oc -n "$DPF_NAMESPACE" get configmap "$CHART_REPO_CONFIGMAP" >/dev/null || \
  fail "chart repository ConfigMap $DPF_NAMESPACE/$CHART_REPO_CONFIGMAP was not found"
oc -n "$DPF_NAMESPACE" get deployment "$CHART_REPO_DEPLOYMENT" >/dev/null || \
  fail "chart repository Deployment $DPF_NAMESPACE/$CHART_REPO_DEPLOYMENT was not found"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/repo"

helm lint "$CHART_SOURCE" --set "lldpSidecar.hostLibraryPath=$HOST_LIBRARY_PATH"
helm template nico-dpu-agent "$CHART_SOURCE" \
  --set "lldpSidecar.hostLibraryPath=$HOST_LIBRARY_PATH" > "$tmp_dir/rendered.yaml"
grep -Fq "name: LD_LIBRARY_PATH" "$tmp_dir/rendered.yaml" || \
  fail "chart does not render the configured LLDP sidecar library path"
grep -Fq "mountPath: /host/lib64" "$tmp_dir/rendered.yaml" || \
  fail "chart does not mount host libraries at /host/lib64"
grep -Fq "path: \"$HOST_LIBRARY_PATH\"" "$tmp_dir/rendered.yaml" || \
  fail "chart does not use host library path $HOST_LIBRARY_PATH"
grep -Fq 'value: "/host/lib64"' "$tmp_dir/rendered.yaml" || \
  fail "chart does not set the sidecar library path to /host/lib64"

helm package "$CHART_SOURCE" \
  --version "$CHART_VERSION" \
  --app-version "$APP_VERSION" \
  --destination "$tmp_dir/repo"

oc -n "$DPF_NAMESPACE" get configmap "$CHART_REPO_CONFIGMAP" -o json > "$tmp_dir/configmap.json"
python3 - "$tmp_dir/configmap.json" "$tmp_dir/index.yaml" <<'PY'
import json
import sys
from pathlib import Path

configmap_path, index_path = map(Path, sys.argv[1:])
configmap = json.loads(configmap_path.read_text())
index = configmap.get("data", {}).get("index.yaml")
if not index:
    raise SystemExit("chart repository ConfigMap has no data.index.yaml")
index_path.write_text(index)
PY

helm repo index "$tmp_dir/repo" \
  --url "$CHART_REPO_URL" \
  --merge "$tmp_dir/index.yaml"

chart_file="$tmp_dir/repo/nico-dpu-agent-${CHART_VERSION}.tgz"
[[ -s "$chart_file" ]] || fail "packaged chart is missing: $chart_file"
python3 - "$tmp_dir/configmap.json" "$tmp_dir/repo/index.yaml" "$chart_file" "$CHART_VERSION" \
  > "$tmp_dir/updated-configmap.json" <<'PY'
import base64
import json
import sys
from pathlib import Path

configmap_path, index_path, chart_path = map(Path, sys.argv[1:4])
version = sys.argv[4]
configmap = json.loads(configmap_path.read_text())
metadata = configmap.get("metadata", {})
for field in ("creationTimestamp", "generation", "managedFields", "resourceVersion", "selfLink", "uid"):
    metadata.pop(field, None)
configmap.setdefault("data", {})["index.yaml"] = index_path.read_text()
configmap.setdefault("binaryData", {})[f"nico-dpu-agent-{version}.tgz"] = base64.b64encode(
    chart_path.read_bytes()
).decode("ascii")
print(json.dumps(configmap))
PY

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY_RUN=true; would publish nico-dpu-agent $CHART_VERSION to $DPF_NAMESPACE/$CHART_REPO_CONFIGMAP"
  exit 0
fi

oc apply -f "$tmp_dir/updated-configmap.json"
oc -n "$DPF_NAMESPACE" rollout restart "deployment/$CHART_REPO_DEPLOYMENT"
oc -n "$DPF_NAMESPACE" rollout status "deployment/$CHART_REPO_DEPLOYMENT" --timeout=180s
echo "Published nico-dpu-agent $CHART_VERSION to $CHART_REPO_URL"
