# NVIDIA Infra Controller — Red Hat Deployment

Red Hat deployment artifacts for [NVIDIA Infra Controller (NICo)](https://docs.nvidia.com/infra-controller/documentation/home).
UBI-based container images and Helm charts for OpenShift, with cert-manager
mTLS, Crunchy PostgreSQL, and Red Hat Build of Keycloak.

## Deployment

Requires OpenShift 4.21+ (CRC for dev).

### 1. Operators and ClusterIssuers

```bash
make deploy-prereqs
```

### 2. Cloud Profile

```bash
make deploy-cloud
```

### 3. Site Profile

```bash
make deploy-site SITE_NAME=my-site     # creates site, bootstrap secret, and deploys
```

To deploy to an existing site (skips site creation):

```bash
make deploy-site SITE_ID=<existing-uuid>
```

## Teardown

```bash
make undeploy
```

## CLI Tools

**nicocli** — REST API client (auto-generated from OpenAPI, site/org management).

Requires `$TOKEN` from the Authentication section above. The CLI is
bundled in the API pod:

```bash
oc run nicocli --rm -it --restart=Never \
  --image=<registry>/nicocli:latest \
  -- --keycloak-url https://keycloak-rhbk-operator.<domain> \
     --keycloak-realm nico --client-id ncx-service \
     --base-url https://nico-rest-api-nvidia-infra-controller-cloud.<domain> \
     site list --org ncx
```

To run as a standalone pod via `oc run`, build and push the `nicocli`
image first (`docker/ubi/Dockerfile.nicocli`), then use the image with
`--base-url https://nico-rest-api:8388`. Note: OpenShift requires
security context overrides (`runAsNonRoot`, `drop: ALL`, etc.) for the
restricted PodSecurity policy.

**nico-admin-cli** — Core gRPC client (bare metal management, host discovery).
Only relevant after deploying the site profile:

```bash
oc exec deploy/nico-core -n nvidia-infra-controller-site -- \
  /app/nico-admin-cli site-explorer get-report
```

## Container Images

UBI 10-based images built by Konflux. Dockerfiles in `docker/ubi/`.

## License

Apache License 2.0
