---
name: next-session-plan
description: Next session priorities — add Vault for site-agent PKI, complete site bootstrap e2e
metadata:
  type: project
---

## Current state (2026-06-19)

Cloud profile deploys cleanly on fresh CRC:
- Prereqs → Cloud → Site creation via REST API all working
- Auth (Keycloak + JWKS) working with init container for race fix
- DB migrations working with kustomize patches (PGSSLMODE, args)
- Temporal 1.31.0 with mTLS, built-in namespace creation
- Site profile deploys (Core + site-agent) but bootstrap fails

## Site bootstrap blocked on PKI

The OTP bootstrap flow requires `nico-rest-cert-manager` (credsmgr) to issue
Temporal client certs for site-agents. We disabled credsmgr because we use
cert-manager operator. The site-manager calls `credsmgr:8000/v1/pki/cloud-cert`
during OTP exchange.

**Next step: Add HashiCorp Vault** as the PKI backend (discussed with HashiCorp
about support). Vault replaces credsmgr and provides:
1. Site-agent Temporal client cert issuance (OTP bootstrap)
2. Core certificate rotation
3. BMC credential storage

The operator repo uses Vault extensively — check
`~/Code/github.com/fabiendupont/nvidia-ncx-infra-controller-operator/` for
Vault integration patterns (managed/external modes, AppRole auth, PKI mount).

## Bootstrap secret format

The site-agent expects these keys in the `site-registration` secret:
- `site-uuid` — site UUID from REST API response
- `otp` — registrationToken from REST API response
- `creds-url` — site-manager creds endpoint (e.g. `https://nico-rest-site-manager.nvidia-infra-controller-cloud:8100/v1/sitecreds`)
- `cacert` — CA cert for verifying site-manager TLS (from `nico-root-ca-secret` in cert-manager namespace)

**Why:** Discovered during e2e testing on CRC. The credsmgr dependency was not
obvious from the chart values alone.

**How to apply:** Either add Vault or re-enable credsmgr as an interim solution.
