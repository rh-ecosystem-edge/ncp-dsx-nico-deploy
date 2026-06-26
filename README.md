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

### 3. Register a Site

```bash
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KC_URL="https://keycloak-rhbk-operator.${DOMAIN}"
API_URL="https://nico-rest-api-nvidia-infra-controller-cloud.${DOMAIN}"

# Get a service-account token (client_credentials grant)
TOKEN=$(curl -sk -X POST "${KC_URL}/realms/nico/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=ncx-service" \
  -d "client_secret=nico-local-secret" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# Bootstrap the org (required one-time call)
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${API_URL}/v2/org/ncx/nico/service-account/current" | python3 -m json.tool

# Create site
curl -sk -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"site-1","description":"First site"}' \
  "${API_URL}/v2/org/ncx/nico/site" | python3 -m json.tool
```

Record `id` (site UUID) and `registrationToken` (OTP) from the response.

### 4. Bootstrap Secret

```bash
oc create namespace nvidia-infra-controller-site

CA_CERT=$(oc get secret nico-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d)

oc create secret generic site-registration \
  -n nvidia-infra-controller-site \
  --from-literal=site-uuid=<site-id> \
  --from-literal=otp=<registration-token> \
  --from-literal=creds-url=https://nico-rest-site-manager.nvidia-infra-controller-cloud:8100/v1/sitecreds \
  --from-literal=cacert="$CA_CERT"
```

### 5. Site Profile

```bash
make deploy-site SITE_ID=<site-id>
```

## CLI Tools

Two CLI images for interacting with NICo:

**nicocli** — REST API client (auto-generated from OpenAPI, site/org management):

```bash
oc run nicocli --rm -it --restart=Never \
  --image=<registry>/nicocli:latest \
  -- --keycloak-url https://keycloak-rhbk-operator.<domain> \
     --keycloak-realm nico --client-id ncx-service \
     --base-url https://nico-rest-api-nvidia-infra-controller-cloud.<domain> \
     site list --org ncx
```

**nico-admin-cli** — Core gRPC client (bare metal management, host discovery):

```bash
oc run nico-admin-cli --rm -it --restart=Never \
  -n nvidia-infra-controller-site \
  --image=<registry>/nico-admin-cli:latest \
  -- site-explorer get-report
```

## Container Images

UBI 10-based images built by Konflux. Dockerfiles in `docker/ubi/`.

## License

Apache License 2.0
