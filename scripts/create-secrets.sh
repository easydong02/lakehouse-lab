#!/usr/bin/env bash
# 실습에 필요한 네임스페이스와 Secret을 한 번에 만든다. 여러 번 실행해도 안전하다.
# 값은 ~/.lakehouse-lab.env 에 한 번만 생성되어 재사용된다 (Git에 넣지 않는다).
# 나중 Lab에서 값이 추가되어도 다시 실행하면 빠진 값만 만든다.
set -euo pipefail

ENV_FILE="${HOME}/.lakehouse-lab.env"
umask 077
touch "${ENV_FILE}"
# 없는 값만 새로 만든다 (이미 있는 값은 절대 바꾸지 않는다)
ensure() { # ensure <변수명> <생성 명령>
  if ! grep -q "^$1=" "${ENV_FILE}"; then
    echo "$1=$(eval "$2")" >> "${ENV_FILE}"
    echo "  new value: $1"
  fi
}
ensure S3_ACCESS_KEY "echo lakehouse"
ensure S3_SECRET_KEY "openssl rand -hex 20"
ensure POLARIS_ROOT_SECRET "openssl rand -hex 16"
ensure POLARIS_TOKEN_KEY "openssl rand -base64 32"
ensure GRAFANA_ADMIN_PASSWORD "openssl rand -hex 8"
# (선택) Airflow
ensure AIRFLOW_DB_PASSWORD "openssl rand -hex 16"
ensure AIRFLOW_FERNET_KEY "openssl rand -base64 32 | tr '+/' '-_'"
ensure AIRFLOW_API_SECRET "openssl rand -hex 16"
ensure AIRFLOW_JWT_SECRET "openssl rand -hex 32"
# shellcheck disable=SC1090
source "${ENV_FILE}"

apply() { kubectl apply -f - >/dev/null && echo "  ok: $1"; }
secret() { # secret <namespace> <name> <kubectl create secret generic 인자...>
  local ns=$1 name=$2; shift 2
  kubectl -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | apply "$ns/$name"
}

echo "namespaces"
for ns in storage polaris spark trino kafka monitoring airflow; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | apply "$ns"
done

echo "secrets"
# SeaweedFS S3 사용자 목록 (identities JSON)
S3_CONFIG=$(cat <<EOF
{"identities":[{"name":"lakehouse","credentials":[{"accessKey":"${S3_ACCESS_KEY}","secretKey":"${S3_SECRET_KEY}"}],"actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
)
secret storage seaweedfs-s3-config --from-literal=seaweedfs_s3_config="${S3_CONFIG}"

# 각 클라이언트가 쓸 S3 자격 증명
secret polaris polaris-s3 \
  --from-literal=access-key="${S3_ACCESS_KEY}" --from-literal=secret-key="${S3_SECRET_KEY}"
for ns in storage spark trino; do
  secret "$ns" lakehouse-s3 \
    --from-literal=AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${S3_SECRET_KEY}" \
    --from-literal=AWS_REGION=us-east-1
done

# Polaris root 계정 비밀번호와 토큰 서명 키
secret polaris polaris-root --from-literal=root-secret="${POLARIS_ROOT_SECRET}"
secret polaris polaris-token-broker --from-literal=symmetric.key="${POLARIS_TOKEN_KEY}"

# Grafana 관리자 계정
secret monitoring grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}"

# (선택) Airflow: CNPG가 쓸 DB 계정, Airflow가 쓸 접속 문자열과 키
kubectl -n airflow create secret generic airflow-db-credentials --type=kubernetes.io/basic-auth \
  --from-literal=username=airflow --from-literal=password="${AIRFLOW_DB_PASSWORD}" \
  --dry-run=client -o yaml | apply airflow/airflow-db-credentials
secret airflow airflow-metadata \
  --from-literal=connection="postgresql://airflow:${AIRFLOW_DB_PASSWORD}@airflow-db-rw.airflow.svc:5432/airflow"
secret airflow airflow-fernet --from-literal=fernet-key="${AIRFLOW_FERNET_KEY}"
secret airflow airflow-api-secret --from-literal=api-secret-key="${AIRFLOW_API_SECRET}"
secret airflow airflow-jwt --from-literal=jwt-secret="${AIRFLOW_JWT_SECRET}"

echo
echo "값 확인: cat ${ENV_FILE}"
