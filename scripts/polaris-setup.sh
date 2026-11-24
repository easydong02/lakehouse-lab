#!/usr/bin/env bash
# Polaris 초기 설정: 카탈로그 + 역할 + 서비스 계정(spark, trino) + K8s Secret
# 먼저 다른 터미널에서: kubectl -n polaris port-forward svc/polaris 8181:8181
# 여러 번 실행해도 된다. (이미 있는 principal은 자격 증명을 rotate 한다)
set -euo pipefail
# shellcheck disable=SC1090
source "${HOME}/.lakehouse-lab.env"

POLARIS="${POLARIS:-http://localhost:8181}"
REALM="POLARIS"
CATALOG="lakehouse"
BASE_LOCATION="s3://lakehouse/warehouse"
S3_ENDPOINT="http://seaweedfs-all-in-one.storage.svc:8333"

# 1) root 토큰 발급 (OAuth2 client_credentials)
TOKEN=$(curl -sf -X POST "${POLARIS}/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: ${REALM}" \
  -d grant_type=client_credentials -d client_id=root \
  -d client_secret="${POLARIS_ROOT_SECRET}" -d scope=PRINCIPAL_ROLE:ALL | jq -r .access_token)
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] || { echo "토큰 발급 실패"; exit 1; }

# 관리 API 호출. 2xx와 409(이미 있음)는 성공으로 본다.
mgmt() { # mgmt METHOD PATH [JSON]
  local method=$1 path=$2 body=${3:-} out code
  out=$(mktemp)
  code=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "${POLARIS}/api/management/v1${path}" \
    -H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}" \
    -H 'Content-Type: application/json' ${body:+-d "$body"})
  case "$code" in
    2*) echo "  ${code} ${method} ${path}" >&2; cat "$out" ;;
    409) echo "  409 ${method} ${path} (이미 있음)" >&2 ;;
    *) echo "  ${code} ${method} ${path}" >&2; cat "$out" >&2; rm -f "$out"; return 1 ;;
  esac
  rm -f "$out"
}

echo "catalog"
mgmt POST /catalogs "$(cat <<EOF
{"catalog": {
  "name": "${CATALOG}", "type": "INTERNAL", "readOnly": false,
  "properties": {
    "default-base-location": "${BASE_LOCATION}",
    "polaris.config.drop-with-purge.enabled": "true"
  },
  "storageConfigInfo": {
    "storageType": "S3",
    "allowedLocations": ["${BASE_LOCATION}"],
    "endpoint": "${S3_ENDPOINT}",
    "pathStyleAccess": true,
    "stsUnavailable": true,
    "region": "us-east-1"
  }
}}
EOF
)" >/dev/null

echo "catalog roles"
mgmt POST "/catalogs/${CATALOG}/catalog-roles" '{"catalogRole":{"name":"lakehouse_writer"}}' >/dev/null
mgmt POST "/catalogs/${CATALOG}/catalog-roles" '{"catalogRole":{"name":"lakehouse_reader"}}' >/dev/null
mgmt PUT "/catalogs/${CATALOG}/catalog-roles/lakehouse_writer/grants" \
  '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}' >/dev/null
for p in NAMESPACE_LIST NAMESPACE_READ_PROPERTIES TABLE_LIST TABLE_READ_PROPERTIES TABLE_READ_DATA; do
  mgmt PUT "/catalogs/${CATALOG}/catalog-roles/lakehouse_reader/grants" \
    "{\"grant\":{\"type\":\"catalog\",\"privilege\":\"${p}\"}}" >/dev/null
done

echo "principal roles"
mgmt POST /principal-roles '{"principalRole":{"name":"engineer"}}' >/dev/null
mgmt POST /principal-roles '{"principalRole":{"name":"analyst"}}' >/dev/null
mgmt PUT "/principal-roles/engineer/catalog-roles/${CATALOG}" '{"catalogRole":{"name":"lakehouse_writer"}}' >/dev/null
mgmt PUT "/principal-roles/analyst/catalog-roles/${CATALOG}" '{"catalogRole":{"name":"lakehouse_reader"}}' >/dev/null

# principal 생성(처음) 또는 rotate(재실행) 후 자격 증명을 K8s Secret으로 저장
make_principal() { # make_principal <이름> <principal role> <namespace>
  local name=$1 role=$2 ns=$3 resp
  resp=$(mgmt POST /principals "{\"principal\":{\"name\":\"${name}\"}}")
  if [ -z "$resp" ]; then
    resp=$(mgmt POST "/principals/${name}/rotate")
  fi
  local id secret
  id=$(echo "$resp" | jq -r .credentials.clientId)
  secret=$(echo "$resp" | jq -r .credentials.clientSecret)
  mgmt PUT "/principals/${name}/principal-roles" "{\"principalRole\":{\"name\":\"${role}\"}}" >/dev/null
  kubectl -n "$ns" create secret generic "polaris-${name}" \
    --from-literal=POLARIS_CREDENTIAL="${id}:${secret}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  principal ${name} → secret ${ns}/polaris-${name}"
}

echo "principals"
make_principal spark engineer spark
make_principal trino analyst trino
echo "done"
