# MISSING — Known Issues and Gaps

## 1. Cloud namespace mismatch with nicocli default

**Symptom:** `nicocli` requires `--base-url` for every command because
the default URL (`https://nico-rest-api.nico.svc.cluster.local`) doesn't
match the deployed namespace.

**Root cause:** The cloud profile deploys to namespace
`nvidia-infra-controller-cloud` (set in `Makefile` line 82), but
upstream `nicocli` defaults to looking for the API service in the `nico`
namespace.

**Options:**

- **Option A — Deploy to `nico` namespace.** Change `-n nvidia-infra-controller-cloud`
  to `-n nico` in the Makefile `deploy-cloud` target. This makes `nicocli`
  work out of the box with no `--base-url` override. Simpler, but the
  namespace name is less descriptive and may collide in multi-tenant
  clusters.

- **Option B — Keep current namespace, always override.** Continue using
  `nvidia-infra-controller-cloud` and pass `--base-url` or set
  `NICO_BASE_URL` when running `nicocli`. More explicit, no upstream
  assumptions.

**Current state:** Option B is in use. Users must set `--base-url` or
`NICO_BASE_URL=https://nico-rest-api.nvidia-infra-controller-cloud:8388`.
