# Repository Guidelines

## Project Structure & Module Organization
This repository packages Red Hat deployment artifacts for NVIDIA Infra Controller (NICo). Top-level operational docs live in `README.md` and the runbooks in `*.md`. Helm content is under `helm/`: `infra-cloud/` and `infra-site/` contain downstream charts, `values/` holds overrides, `kustomize/` contains post-render patches, and `nvidia-infra-controller-prereqs/` installs operators. Treat `helm/vendor/infra-controller/` as upstream, vendored, and read-only unless you are intentionally updating the submodule. Container build inputs live in `docker/`, storage manifests in `storage/`, helper scripts in `utils/`, and cluster/dev helpers in `hack/`.

## Build, Test, and Development Commands
Run `make check-prereqs` first to verify `oc`, `helm`, `kustomize`, `podman`, `python3`, and cluster login state. Use `make helm-dep-build` after cloning or when chart dependencies change. `make helm-lint` is the main pre-PR validation step: it lints local charts and renders the upstream `nico-rest` and `nico-core` charts. `make helm-template` prints rendered manifests for review. Deployment entry points are `make deploy-all-cloud`, `make deploy-all-site`, and `make status`. For teardown, prefer `make undeploy`; use `bash cleanup.sh` only for stuck resources.

## Coding Style & Naming Conventions
Preserve the existing style in each file type: two-space indentation in YAML, tabs in `Makefile` recipes, and `set -euo pipefail` in Bash scripts. Keep Helm values files and manifests in lowercase kebab-case, for example `helm/values/nico-core-mat.yaml`. Follow the SPDX header pattern already used in tracked YAML and workflow files when editing those files. Dockerfile and GitHub Actions changes should remain compatible with `hadolint` and `actionlint`.

## Testing Guidelines
There is no single unit-test suite at the repo root; validation is command-driven. Run `make helm-lint` for every Helm or values change. Run `make helm-template` when changing templates, kustomize patches, or release wiring. After cluster-facing changes, use `make status` and `bash validate-machines.sh` against a logged-in OpenShift cluster to confirm deployment health.

## Commit & Pull Request Guidelines
Recent history favors short, imperative commit subjects such as `update lint workflow` or `Add DPU onboarding runbook...`. Keep subjects concise, describe the deployment impact in the PR body, and link the relevant issue or ticket when available. PRs that touch manifests or images should include the exact validation commands run and their results; include screenshots only when route/UI behavior changed.
