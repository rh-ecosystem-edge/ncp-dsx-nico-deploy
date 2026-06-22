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

TOKEN=$(curl -sk -X POST "$KC_URL/realms/nico-dev/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=nico-api" \
  -d "client_secret=nico-local-secret" \
  -d "username=admin" \
  -d "password=adminpassword" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

curl -sk "$API_URL/v2/org/test-org/nico/infrastructure-provider/current" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

curl -sk -X POST "$API_URL/v2/org/test-org/nico/site" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "site-1", "description": "First site"}' | python3 -m json.tool
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

## Container Images

Pre-built UBI images at `quay.io/fdupont-redhat/nico-*:latest`.

```bash
make docker-build-ubi    # Build from source
make docker-push-ubi     # Push to registry
```

## License

Apache License 2.0
