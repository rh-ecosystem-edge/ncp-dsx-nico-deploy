#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Helm post-renderer plugin that applies Kustomize patches to rendered manifests.
# Usage: helm install ... --post-renderer kustomize-post-renderer --post-renderer-args <kustomize-dir>

set -euo pipefail

KUSTOMIZE_DIR="${1:?Usage: --post-renderer-args <path-to-kustomize-dir>}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

cat > "$TMPDIR/all.yaml.raw"

# Some upstream charts emit duplicate YAML mapping keys (e.g. nico-flow's
# labels + selectorLabels both output app.kubernetes.io/name). kubectl
# tolerates this but kustomize v5's strict YAML parser rejects it.
# Round-trip through Python's yaml parser which silently deduplicates keys.
python3 -c "
import sys, yaml
content = open('$TMPDIR/all.yaml.raw').read()
for doc in yaml.safe_load_all(content):
    if doc is not None:
        print('---')
        print(yaml.dump(doc, default_flow_style=False, width=200), end='')
" > "$TMPDIR/all.yaml"

cp -r "$KUSTOMIZE_DIR/"* "$TMPDIR/"

cd "$TMPDIR"
kustomize build .
