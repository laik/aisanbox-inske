#!/usr/bin/env bash
# 0.1.7 driver-config 能力边界实测：
#   E1 configMap volume   E2 secret volume   E3 pod annotations   E4 /run 挂载
# 每个实验独立建 sandbox，失败不影响下一个。在 192.168.5.190 上跑。
set -uo pipefail
C=/root/poc2/vendor/openshell-cli-0.1.7/openshell
G="-g poc2-a --workspace poc-shared"
D=/root/poc2/vault
BASE="--from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never"

run() { # name json [extra flags...]
  local n=$1 j=$2; shift 2
  echo "===== $n ====="
  $C $G sandbox create --name "$n" $BASE --driver-config-json "$(cat "$D/$j")" "$@" 2>&1 | tail -6
  echo
}

run v-cm  dc-cm.json
run v-sec dc-sec.json
run v-ann dc-ann.json --policy "$D/policy-vault-secrets.yaml"
run v-run dc-run.json

echo "===== pods ====="
kubectl --context kind-agent-runtime-poc -n tenant-a-runtime get pods \
  -l openshell.ai/boundary-role=workload --show-labels 2>/dev/null | head -10