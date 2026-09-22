# Vendor patches

`infra-controller.patch` contains fixes for the read-only upstream submodule
(`helm/vendor/infra-controller`) that cannot be expressed with the kustomize
post-renderer: **helm post-renderers are not applied to hook resources**, so
`helm.sh/hook` pre-install/pre-upgrade Jobs escape every patch in
`helm/kustomize/`.

The patch fixes two hook bugs hit on OpenShift 4.22 — both hard blockers,
observed on a live 4.22 SNO:

1. `helm/rest/nico-rest/charts/nico-rest-db/templates/migration-job.yaml` —
   the pre-install hook pinned `runAsUser: 1000` / `fsGroup: 1000`, which the
   `restricted-v2` SCC rejects (UID outside the namespace range). The pod now
   only sets `runAsNonRoot: true` and lets OpenShift auto-assign an in-range
   UID.

2. `helm/charts/nico-api/templates/migration-job.yaml` — the pre-install
   migration Job read `key: username` from Crunchy PGO pguser secrets, which
   use the key `user`. The Job failed with `CreateContainerConfigError`.

A third upstream bug (`helm/charts/nico-flow/templates/namespace.yaml` uses
`{{- if .Values.createNamespace | default true }}`, which re-defaults an
explicit `false` back to true) is deliberately NOT patched here: in this
repo the only paths that render that template are the `nico-core` umbrella
chart (already neutralized by
`helm/kustomize/nico-core/patches/remove-flow-namespace.yaml`) and the
standalone `deploy-flow` target (removed — Flow ships inside `nico-core`).
Upstream it to NVIDIA/infra-controller when possible.

Applied automatically by `make patch-vendor` (wired into `helm-dep-build` and
`deploy-site`). The target is idempotent: it detects an already-applied patch
(`git apply --reverse --check`) and fails loudly if the submodule commit has
moved so the patch no longer applies cleanly — rebase the patch onto the new
commit or update the submodule pin.
