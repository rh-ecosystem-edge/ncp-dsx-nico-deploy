---
name: temporal-openshift
description: Official Temporal Helm chart v1.2.0 requires specific overrides for OpenShift and TLS
metadata:
  type: feedback
---

When using the official Temporal Helm chart (v1.2.0) on OpenShift with mTLS:

1. **securityContext must be `null`, not `{}`** — Helm deep-merges `{}` over defaults, keeping `fsGroup: 1000` and `runAsUser: 1000`. Only `null` clears them for OpenShift SCC compliance.

2. **Kubernetes gRPC probes don't support TLS** — when Temporal frontend has `requireClientAuth: true`, the native gRPC readiness probe fails because it connects plaintext. Use `tcpSocket` probe instead, and null out the default `grpc` key: `readinessProbe: {grpc: null, tcpSocket: {port: 7233}}`.

3. **`connectProtocol: "tcp"` is required** — the v1.2.0 chart validates this field; omitting it causes "zero value" errors at startup.

4. **TLS config path is `server.config.tls`**, not `server.config.global.tls` — the chart template reads from `server.config.tls` and places it under `global.tls` in the generated configmap.

5. **Crunchy PGO CA cert** — mount `temporal-pg-cluster-cert` secret (key `ca.crt`) and set `caFile` in datastore TLS config for proper PostgreSQL certificate verification.

6. **Temporal CLI env var naming changed** — the old `tctl` used `TEMPORAL_CLI_TLS_CERT` etc. The new `temporal` CLI (1.31.0) uses `TEMPORAL_TLS_CLIENT_CERT_PATH`, `TEMPORAL_TLS_CLIENT_KEY_PATH`, `TEMPORAL_TLS_CA_CERT_PATH`, `TEMPORAL_TLS_DISABLE_HOST_VERIFICATION`. The chart's built-in namespace creation job (`server.config.namespaces.create: true`) works correctly once `admintools.additionalEnv` uses the new names. No custom namespace-setup job needed.

**Why:** Discovered during e2e deployment on CRC (OpenShift 4.21). Each issue caused pod failures that required investigation.

**How to apply:** Check these settings whenever upgrading the Temporal chart version or deploying to a new OpenShift cluster.
