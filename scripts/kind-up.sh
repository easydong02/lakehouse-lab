#!/usr/bin/env bash
# kind 클러스터 + 로컬 레지스트리(kind-registry, localhost:5001)를 만든다.
# kind 공식 문서의 local registry 스크립트를 이 실습에 맞게 고친 것.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-lakehouse}"
# kind v0.33.0의 기본 노드 이미지 (digest 고정)
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
REG_NAME="kind-registry"
REG_PORT="5001"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 1) 레지스트리 컨테이너 (데이터는 named volume에 남는다)
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always \
    -p "127.0.0.1:${REG_PORT}:5000" \
    -v kind-registry-data:/var/lib/registry \
    --network bridge --name "${REG_NAME}" \
    registry:3
fi

# 2) 클러스터
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" \
    --config "${ROOT_DIR}/kind/cluster.yaml"
fi

# 3) 각 노드의 containerd에 "localhost:5001 → http://kind-registry:5000" 매핑 추가
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  printf '[host."http://%s:5000"]\n' "${REG_NAME}" \
    | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
done

# 4) 레지스트리를 kind 네트워크에 연결 (노드가 이름으로 찾을 수 있게)
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REG_NAME}"
fi

# 5) 로컬 레지스트리 위치를 클러스터에 알리는 표준 ConfigMap (KEP-1755)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo
kubectl get nodes -o wide
