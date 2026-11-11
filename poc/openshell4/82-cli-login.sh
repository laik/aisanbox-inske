#!/usr/bin/env bash
# 用**产品自己的 device flow**给两台 Gateway 各注册几个身份，供 81 号脚本用。
# profile: p4a-tadmin / p4a-alice / p4b-tadmin / p4b-alice / p4b-bob
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=${CTX:-kind-agent-runtime-poc}
CLI=vendor/openshell-cli-0.1.7/openshell
PASS=poc3pass
# shellcheck source=../openshell3/lib-cli-login.sh
source openshell3/lib-cli-login.sh
# device-approve.py 默认用 /tmp/issuer-ca.crt(POC3 phase14 同一条)
[ -s /tmp/issuer-ca.crt ] || cp identity/certs/issuer-ca.crt /tmp/issuer-ca.crt

REALM=$(kubectl --context $CTX -n identity get cm kc-config -o jsonpath='{.data.realm}' 2>/dev/null); REALM=${REALM:-aisanbox}
ISSUER="$(kubectl --context $CTX -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')/realms/$REALM"
[ -n "${ISSUER%%/realms/*}" ] || { echo "✗ 读不到 issuer"; exit 1; }
NODE_IP=$(kubectl --context $CTX get nodes -o jsonpath='{.items[?(@.metadata.labels.kubernetes\.io/hostname=="agent-runtime-poc-worker2")].status.addresses[?(@.type=="InternalIP")].address}')
NODE_IP=${NODE_IP:-172.22.0.3}
echo "issuer=$ISSUER  node=$NODE_IP"
for spec in "p4-a:31445:tadmin:p4a-tadmin" "p4-a:31445:alice:p4a-alice" \
            "p4-b:31446:tadmin:p4b-tadmin" "p4-b:31446:alice:p4b-alice" \
            "p4-b:31446:bob:p4b-bob"; do
  IFS=: read -r gw port user prof <<<"$spec"
  printf "%-14s %-8s " "$prof" "$user"
  if cli_login_as "$prof" "$user" "$PASS" "$ISSUER" "https://$NODE_IP:$port"; then echo "✓"; else echo "✗"; fi
done
echo "### profiles:"; ls -1 "$HOME/.config/openshell/gateways" | grep '^p4' | sed 's/^/   /'
