#!/usr/bin/env bash
# 一条命令重新登录 gateway（OIDC）。
# 为什么不能用 `openshell gateway login`：那条路是 CLI 直连 IdP 做 discovery，
# 而 CLI 只信编译进去的公共根证书，我们的 issuer 是私有 CA → invalid peer certificate: UnknownIssuer。
# 设备码流程不一样：token 交换由 gateway 做（gateway 通过 oidc.caConfigMapName 信任这个 CA），
# 批准这一步用 curl --cacert（device-approve.py），所以全程不需要 CLI 信这个 CA。
#
# 用法: bash relogin.sh [profile=os-tadmin] [user=tadmin] [pass=poc3pass]
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${CTX:-k8s-221}
PROF=${1:-os-tadmin} USER=${2:-tadmin} PASS=${3:-poc3pass}
K="kubectl --context $CTX"

# endpoint 优先用内网名（在 /etc/hosts 里，也在 chart 的 serverDnsNames 里），名字不解析才用节点 IP
GW=$(python3 -c "import socket
try:
    print('openshell-vm.home.rapa' if socket.gethostbyname('openshell-vm.home.rapa').startswith('192.168.') else '')
except OSError:
    print('')")
[ -n "$GW" ] || GW=$($K -n openshell get pods -l app.kubernetes.io/name=openshell -o jsonpath='{.items[0].status.hostIP}')
NODE_PORT=$($K -n openshell get svc openshell -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}')
ISS=$($K -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')/realms/$($K -n identity get cm kc-config -o jsonpath='{.data.realm}')
CA=$($K -n openshell get cm oidc-issuer-ca -o jsonpath='{.data.ca\.crt}')
EP="https://${GW}:${NODE_PORT}"
echo "endpoint=$EP issuer=$ISS"

printf '%s\n' "$CA" > /tmp/issuer-ca.crt
# device-approve.py 里的默认 issuer 是按 kind 环境写死的，按当前集群改一份
sed "s|KC_DEFAULT = \"[^\"]*\"|KC_DEFAULT = \"$ISS\"|" "$HERE/../openshell3/device-approve.py" > /tmp/device-approve-relogin.py

LOG=/tmp/os-relogin-$PROF.log
rm -rf "$HOME/.config/openshell/gateways/$PROF"
env OPENSHELL_NO_BROWSER=1 OPENSHELL_GATEWAY_INSECURE=true timeout 150 \
  openshell gateway add "$EP" --name "$PROF" --oidc-issuer "$ISS" --oidc-client-id openshell-cli > "$LOG" 2>&1 &
pid=$!
VL=""
for _ in $(seq 1 30); do
  VL=$(grep -m1 -oE 'https://[^ ]*/device\?user_code=[A-Z]+-[A-Z]+' "$LOG"); [ -n "$VL" ] && break; sleep 1
done
[ -n "$VL" ] || { echo "✗ 没拿到设备码:"; tail -3 "$LOG"; exit 1; }
python3 /tmp/device-approve-relogin.py "$USER" "$PASS" "$VL" --cacert /tmp/issuer-ca.crt || { kill $pid 2>/dev/null; exit 1; }
wait $pid 2>/dev/null
F="$HOME/.config/openshell/gateways/$PROF/oidc_token.json"
[ -f "$F" ] || { echo "✗ 没写出 token:"; tail -3 "$LOG"; exit 1; }
env OPENSHELL_GATEWAY_INSECURE=true openshell -g "$PROF" whoami 2>&1 | grep -vE "TLS certificate verification"
echo
# gateway 自己的证书也是 chart 私有 CA 签的（SAN 里有 openshell-vm.home.rapa 和两个节点 IP，
# 但 CA 不在 CLI 的公共根里），所以 CLI 必须跳过 TLS 验证 —— 不设置就会报 "connect error: transport error"。
echo "后续命令都要带（建议写进 shell rc）:  export OPENSHELL_GATEWAY_INSECURE=true"
