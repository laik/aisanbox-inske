#!/usr/bin/env bash
# 角色名到底在哪定义：IdP 还是 OpenShell？
#  A) rolesClaim 支持**点分路径**（chart 注释里就写了 Keycloak 用 realm_access.roles）→ 不需要在 IdP 里造自定义 claim
#  B) adminRole/userRole 都留空 = chart 注释里的 "authentication-only mode"：角色门关掉，只剩成员关系判定
#    （同时要知道：这种模式下谁来当 Platform Admin —— 实测）
set -uo pipefail
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
HERE=$(cd "$(dirname "$0")" && pwd); POC="$HERE/.."
CTX=${CTX:-k8s-221}; GNS=openshell GW=openshell
CHART="oci://ghcr.io/nvidia/openshell/helm-chart"; VER=${VER:-0.1.7}
K="kubectl --context $CTX"; CLI=$(command -v openshell)
ISS=$($K -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')/$( $K -n identity get cm kc-config -o jsonpath='{.data.realm}' | sed 's|^|realms/|')
NP=$($K -n $GNS get svc $GW -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}'); EP="https://192.168.5.221:${NP}"
PASS=poc3pass; T=t-50933; A=tenant-a-runtime
OSC(){ local p=$1; shift; OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$p" "$@" 2>&1; }
sbx(){ OSC "$1" sandbox delete --workspace "$2" "$3" >/dev/null 2>&1
       OSC "$1" sandbox create --workspace "$2" --name "$3" --from nvcr.io/nvidia/base/ubuntu:24.04 --detach --restart-policy never -- sleep 600 | tail -3; }
login(){ local prof=$1 user=$2
  rm -rf "$HOME/.config/openshell/gateways/$prof"
  OPENSHELL_NO_BROWSER=1 OPENSHELL_GATEWAY_INSECURE=true timeout 150 "$CLI" gateway add "$EP" --name "$prof" \
    --oidc-issuer "$ISS" --oidc-client-id openshell-cli > "/tmp/os-add-$prof.log" 2>&1 &
  local pid=$! VL=""
  for i in $(seq 1 30); do VL=$(grep -m1 -oE 'https://[^ ]*/device\?user_code=[A-Z]+-[A-Z]+' "/tmp/os-add-$prof.log"); [ -n "$VL" ] && break; sleep 1; done
  [ -n "$VL" ] || { echo "  ✗ $user 没拿到设备码"; return 1; }
  python3 /tmp/device-approve-op.py "$user" "$PASS" "$VL" >/dev/null || { echo "  ✗ $user 设备授权失败"; kill $pid 2>/dev/null; return 1; }
  wait $pid 2>/dev/null; [ -f "$HOME/.config/openshell/gateways/$prof/oidc_token.json" ]; }
claim(){ python3 -c "
import base64,json,sys
t=json.load(open(sys.argv[1]))['access_token'].split('.')[1];t+='='*(-len(t)%4)
c=json.loads(base64.urlsafe_b64decode(t))
print('   claim: realm_access.roles=%s groups=%s'%(sorted(c.get('realm_access',{}).get('roles',[])),sorted(c.get('groups',[]))))" \
  "$HOME/.config/openshell/gateways/$1/oidc_token.json"; }
gw(){ # $1=rolesClaim $2=adminRole $3=userRole
  cat > /tmp/v-oidc-mode.yaml <<EOF
server:
  oidc:
    issuer: "$ISS"
    audience: "openshell-cli"
    rolesClaim: "$1"
    adminRole: "$2"
    userRole: "$3"
    scopesClaim: ""
    caConfigMapName: "oidc-issuer-ca"
    jwksTtl: 600
EOF
  $K -n $GNS -o name get cm oidc-issuer-ca >/dev/null 2>&1 || \
    $K -n $GNS create configmap oidc-issuer-ca --from-file=ca.crt="$HERE/certs/issuer-ca.crt" >/dev/null
  $K -n $GNS get cm openshell-config -o jsonpath='{.data.gateway\.toml}' > /dev/null
  helm get values "$GW" -n "$GNS" -o yaml > /tmp/os-cur-values.yaml
  helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
    -f /tmp/os-cur-values.yaml -f "$HERE/values-operator.yaml" -f /tmp/v-oidc-mode.yaml >/dev/null \
    && echo "  helm upgrade ok (rolesClaim=$1 adminRole='$2' userRole='$3')"
  $K -n $GNS rollout status "sts/$GW" --timeout=240s | tail -1; }

sed "s|KC_DEFAULT = \"https://172.22.0.3:31443/realms/aisanbox\"|KC_DEFAULT = \"$ISS\"|" \
  "$POC/openshell3/device-approve.py" > /tmp/device-approve-op.py

echo "########## 00 realm：加一个「没有任何角色」的用户 p50933 ##########"
python3 - "$HERE/kc-realm-op.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
if not any(u['username']=='p50933' for u in d['users']):
    d['users'].append({'username':'p50933','enabled':True,'firstName':'No','lastName':'Role',
                       'email':'p50933@aisanbox.example','emailVerified':True,'requiredActions':[],
                       'credentials':[{'type':'password','value':'poc3pass','temporary':False}],'realmRoles':[]})
    json.dump(d,open(p,'w'),ensure_ascii=False,indent=2); print('已加 p50933（realmRoles=[]）')
else: print('p50933 已存在')
PY
$K -n identity create configmap kc-realm-op --from-file=realm.json="$HERE/kc-realm-op.json" --dry-run=client -o yaml | $K apply -f - >/dev/null
WANT=$(md5sum < "$HERE/kc-realm-op.json" | cut -c1-12)
HAVE=$($K -n identity get deploy keycloak -o jsonpath='{.metadata.annotations.os-poc\.io/realm}' 2>/dev/null)
if [ "$HAVE" != "$WANT" ]; then
  for i in $(seq 1 24); do [ "$($K -n identity exec deploy/keycloak -c keycloak -- sh -c 'md5sum /opt/keycloak/data/import/realm.json' 2>/dev/null | cut -c1-12)" = "$WANT" ] && break; sleep 5; done
  $K -n identity annotate deploy/keycloak "os-poc.io/realm=$WANT" --overwrite >/dev/null
  $K -n identity rollout restart deploy/keycloak; fi
$K -n identity rollout status deploy/keycloak --timeout=420s | tail -1
for i in $(seq 1 24); do C=$(curl -sk -o /dev/null -w "%{http_code}" "$ISS/.well-known/openid-configuration"); [ "$C" = 200 ] && break; sleep 5; done
echo "issuer $ISS → HTTP $C"

echo; echo "########## 10 A：rolesClaim 用 Keycloak 默认的点分路径 realm_access.roles ##########"
gw "realm_access.roles" "os-admin" "os-user"
login os-tadmin tadmin && echo "  tadmin ✓"; claim os-tadmin
login os-p50933 p50933 && echo "  p50933 ✓（realmRoles 为空）"; claim os-p50933
echo "--- 有 os-admin 的人能管平台（证明点分 claim 被读到了）"
OSC os-tadmin workspace list | tail -3
echo "--- 没有任何角色的人：角色门挡在外面（对照用例）"
sbx os-p50933 "$T" pc-1
echo "--- 带 os-user 且是成员的人能用（u50933 先补成员）"
OSC os-tadmin workspace member add --workspace "$T" --subject u50933 --role user | tail -1
login os-u50933 u50933 >/dev/null && sbx os-u50933 "$T" uc-1

echo; echo "########## 20 B：adminRole / userRole 都留空（chart 注释：authentication-only mode）##########"
gw "realm_access.roles" "" ""
login os-p50933 p50933 && echo "  p50933 ✓"; claim os-p50933
echo "--- 同一个身份：不再报 role，而是报成员关系（角色门关掉了）"
OSC os-tadmin workspace member remove --workspace "$T" --subject p50933 >/dev/null
sbx os-p50933 "$T" pc-1
echo "--- 这种模式下谁来当 Platform Admin？（tadmin 的 os-admin 已无人认领）"
OSC os-tadmin workspace list | tail -2
OSC os-tadmin workspace member add --workspace "$T" --subject p50933 --role user | tail -2
echo "--- 补上成员后（若上面被拒，这里就失败）"
sbx os-p50933 "$T" pc-1

echo; echo "########## 30 恢复 A（rolesClaim=realm_access.roles, os-admin/os-user）##########"
gw "realm_access.roles" "os-admin" "os-user"
echo "--- 清场"
for n in pc-1 uc-1; do OSC os-tadmin sandbox delete --workspace "$T" "$n" >/dev/null 2>&1; done
for s in p50933 u50933; do OSC os-tadmin workspace member remove --workspace "$T" --subject "$s" >/dev/null 2>&1; done
$K -n $GNS get cm openshell-config -o jsonpath='{.data.gateway\.toml}' | sed -n '/gateway.oidc/,/^\[openshell/p'
date -u '+%Y-%m-%dT%H:%M:%SZ'
