#!/usr/bin/env bash
# POC5-2：不同 namespace ↔ 不同 workspace ↔ OIDC 身份/权限，实测。
# 用法: bash 90-oidc-ns-workspace.sh          # 全跑
#       bash 90-oidc-ns-workspace.sh clean    # 只删本脚本建的沙箱/成员
# 复用 POC3 的 identity 栈（poc/identity）与 device-flow 登录helper（poc/openshell3），只改 issuer 的节点 IP。
# 前提：poc/operator-mode/demo.sh 已跑过（operator 模式 + tenant-a/b-runtime 的 workspace）。
set -uo pipefail
# macOS 的 sed 在 C locale 下读到 UTF-8 注释会报 "illegal byte sequence"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

HERE=$(cd "$(dirname "$0")" && pwd)
POC=$(dirname "$HERE")
CTX=${CTX:-k8s-221}
NODE_IP=${NODE_IP:-192.168.5.221}
GNS=openshell GW=openshell CHART="oci://ghcr.io/nvidia/openshell/helm-chart"
WSCHART="oci://ghcr.io/nvidia/openshell/openshell-workspace"
VER=${VER:-0.1.7}
IMG="nvcr.io/nvidia/base/ubuntu:24.04"
A=tenant-a-runtime B=tenant-b-runtime
K="kubectl --context $CTX"
CLI=${CLI:-openshell}                      # 本机 CLI（0.1.9）对 0.1.7 gateway，本轮沿用
PASS=poc3pass
REALM=aisanbox
ISSUER="https://$NODE_IP:31443/realms/$REALM"
GWPROF=${GWPROF:-openshell-vm.home.rapa-31761}   # 现有 mTLS 管理通道（开 OIDC 后会失效，见步骤 20）
sub_of() { python3 -c "import base64,json,sys;q=open(sys.argv[1]).read();p=json.loads(q)['access_token'].split('.')[1];p+='='*(-len(p)%4);print(json.loads(base64.urlsafe_b64decode(p))['sub'])" "$HOME/.config/openshell/gateways/$1/oidc_token.json"; }
OSC() { local prof=$1; shift; OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$prof" "$@" 2>&1; }
sbx() { OSC "$1" sandbox delete --workspace "$2" "$3" >/dev/null 2>&1   # 让矩阵可重复跑
        OSC "$1" sandbox create --workspace "$2" --name "$3" --from "$IMG" --detach --restart-policy never -- sleep 600 | tail -3; }

# device-approve.py 的默认 issuer 是 POC3 的 kind 节点 IP —— 复制一份改掉默认值（不改 POC3 的原件）
sed "s|KC_DEFAULT = \"https://172.22.0.3:31443/realms/aisanbox\"|KC_DEFAULT = \"$ISSUER\"|" \
  "$POC/openshell3/device-approve.py" > /tmp/device-approve-op.py
sed 's|"\$(dirname "\$BASH_SOURCE")/device-approve.py"|/tmp/device-approve-op.py|' \
  "$POC/openshell3/lib-cli-login.sh" > /tmp/lib-cli-login-op.sh
# shellcheck source=/tmp/lib-cli-login-op.sh
source /tmp/lib-cli-login-op.sh

if [ "${1:-all}" = clean ]; then
  for spec in "os-alice $A oa-1" "os-alice $B oa-2" "os-bob $B ob-1" "os-bob $A ob-2" "os-tadmin $B ta-1" "os-u50933 t-50933 tc-1"; do
    set -- $spec; OSC "$1" sandbox delete --workspace "$2" "$3" >/dev/null 2>&1
  done
  for spec in "$A alice" "$A bob" "$B alice" "$B bob" "$A tadmin" "$B tadmin" "t-50933 u50933" "t-50933 a50933" "t-50933 bob"; do set -- $spec
    OSC os-tadmin workspace member remove --workspace "$1" --subject "$2" >/dev/null 2>&1; done
  echo "clean: 只删矩阵产物；identity 栈与 OIDC 配置保留"
  exit 0
fi

echo "########## 00 issuer 证书（复用 POC3 脚本，只换 OUT 与 IP）##########"
date -u '+%Y-%m-%dT%H:%M:%SZ'
mkdir -p "$HERE/certs"
# 只在没有可用证书时才签（实测坑：每次重签会让运行中的 nginx sidecar 继续用旧证书，
# 而客户端读的是新 CA → "upstream SSL certificate verify error: certificate signature failure"，
# 表现却是 gateway 报 "OIDC discovery request failed"。与 certmanager.md 里"ca.crt 残留旧 CA"同一类故障。）
if openssl x509 -in "$HERE/certs/issuer.crt" -noout -text 2>/dev/null | grep -q "IP Address:$NODE_IP"; then
  echo "复用 issuer CA（SAN 已含 ${NODE_IP}）"
else
  sed "s|^OUT=.*|OUT=\"$HERE/certs\"|" "$POC/identity/certs/gen-issuer-ca.sh" > /tmp/gen-issuer-ca-op.sh
  NODE_IP=$NODE_IP HOST_IP=$NODE_IP bash /tmp/gen-issuer-ca-op.sh | grep -m1 wrote
fi
cp "$HERE/certs/issuer-ca.crt" /tmp/issuer-ca.crt        # device-approve.py 的默认 --cacert

echo; echo "########## 10 OIDC 提供商：Keycloak + nginx 终止 TLS（91-identity-op.yaml）##########"
# 这台集群到不了 docker.io（osixia/openldap、library/nginx 全是 "connection reset by peer"），
# 所以不接 POC3 的 LDAP；realm 由 --import-realm 导入本地用户。
# claim 形状：roles_claim 只读一个 claim（这里叫 groups），里面只放 OpenShell 认的 os-user / os-admin
# 与租户侧的组名；租户侧的组不参与 OpenShell 判定，只给平台 Controller 做成员同步用。
# "目录 → 同一个 claim" 那条链 POC3 §12 已证，本轮不重复测。
$K -n identity delete deploy/openldap job/ldap-seed job/kc-realm --ignore-not-found >/dev/null
# 原地更新而不是 delete+create：删了重建会让 Pod 里的挂载点不再同步（实测 import 用的还是上一版 realm.json）
$K -n identity create configmap kc-realm-op --from-file=realm.json="$HERE/kc-realm-op.json" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n identity create secret generic issuer-tls --from-file=tls.crt="$HERE/certs/issuer.crt" \
  --from-file=tls.key="$HERE/certs/issuer.key" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n openshell create configmap oidc-issuer-ca --from-file=ca.crt="$HERE/certs/issuer-ca.crt" \
  --dry-run=client -o yaml | $K apply -f - >/dev/null
# Keycloak 只在启动时 import realm，nginx 只在启动时读一次证书 → 内容变了必须重启。
# 用 annotation 记"当前 Pod 实际导入的是哪一版"：比对 Secret/CM 会慢一拍（它们已被上一轮更新过）。
RH=$(md5sum < "$HERE/kc-realm-op.json" | cut -c1-12); CH=$(md5sum < "$HERE/certs/issuer.crt" | cut -c1-12)
WANT="realm=$RH cert=$CH"
MOUNTED() { printf 'realm=%s cert=%s' "$($K -n identity exec deploy/keycloak -c keycloak -- sh -c 'md5sum /opt/keycloak/data/import/realm.json' 2>/dev/null | cut -c1-12)" \
    "$($K -n identity exec deploy/keycloak -c tls -- md5sum /etc/tls/tls.crt 2>/dev/null | cut -c1-12)"; }
# annotation 记的是"上一次真正 import 进去的版本"（只在重启前写）；Pod 里的文件哈希是"现在挂着的版本"。
# 两个都一致才算已生效 —— 只比 annotation 会骗人（上一轮写入了 annotation 但文件还没同步）。
HAVE=$($K -n identity get deploy keycloak -o jsonpath='{.metadata.annotations.os-poc\.io/imported}' 2>/dev/null)
if [ "${FORCE_KC:-0}" != 1 ] && [ "$HAVE" = "$WANT" ]; then echo "realm/证书未变，不重启 keycloak"   # 要强制重 import: FORCE_KC=1
else
  $K -n identity annotate deploy/keycloak "os-poc.io/imported=$WANT" --overwrite >/dev/null
  $K -n identity rollout restart deploy/keycloak
fi
$K -n identity rollout status deploy/keycloak --timeout=420s | tail -1
# 断言新 Pod 挂上的确实是当前版本（挂到旧文件时 import 的就是旧 realm，症状是"改了配置不生效"）
if [ "$(MOUNTED)" != "$WANT" ]; then echo "✗ Pod 挂的是 $(MOUNTED)，要 $WANT"; exit 1; fi
# issuer 只有一处定义（identity/kc-config），脚本读它并断言与本机拼出来的一致
KC_ISSUER=$($K -n identity get cm kc-config -o jsonpath='{.data.issuer_url}')/$( $K -n identity get cm kc-config -o jsonpath='{.data.realm}' | sed 's|^|realms/|')
echo "kc-config issuer = $KC_ISSUER   脚本用的 = $ISSUER"
[ "$KC_ISSUER" = "$ISSUER" ] || { echo "✗ issuer 不一致"; exit 1; }
HC=""   # readiness 探针会在 import 刚完成时就通过，nginx 到 KC 的 upstream 还要几秒
for i in $(seq 1 24); do HC=$(curl --cacert "$HERE/certs/issuer-ca.crt" -s -o /dev/null -w "%{http_code}" "$ISSUER/.well-known/openid-configuration")
  [ "$HC" = 200 ] && break; sleep 5; done; echo "issuer discovery（CA 校验）: HTTP $HC"
[ "$HC" = 200 ] || { $K -n identity logs deploy/keycloak --tail=5; exit 1; }
curl -sk "$ISSUER/.well-known/openid-configuration" | tr ',' '\n' | grep -m1 '"issuer"'
echo "--- password grant：看 gateway 将读到的 claim（sub / groups / aud）"
TK=$(curl -sk -X POST "$ISSUER/protocol/openid-connect/token" -d grant_type=password -d client_id=openshell-cli \
     -d username=alice -d password=$PASS | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
if [ -n "$TK" ]; then python3 - "$TK" <<'PYX'
import base64, json, sys
t = sys.argv[1].split('.')[1]; t += '=' * (-len(t) % 4)
c = json.loads(base64.urlsafe_b64decode(t))
print("   sub=%s groups=%s aud=%s" % (c.get('sub'), sorted(set(c.get('groups', []))), c.get('aud')))
PYX
else echo "   ✗ 拿不到 token"; exit 1; fi

echo; echo "########## 20 Gateway 开 OIDC（mTLS 同时保留）##########"
if [ "${SKIP_GATEWAY:-0}" = 1 ]; then echo "SKIP_GATEWAY=1：跳过 helm upgrade，直接跑 30 之后"; skip_gw=1; else skip_gw=0; fi
if [ "$skip_gw" = 0 ]; then
$K -n $GNS -o name get cm oidc-issuer-ca >/dev/null 2>&1 && $K -n $GNS delete cm oidc-issuer-ca
$K -n $GNS create configmap oidc-issuer-ca --from-file=ca.crt="$HERE/certs/issuer-ca.crt" >/dev/null
sed "s|__ISSUER__|$ISSUER|" "$HERE/values-oidc.yaml.tmpl" > /tmp/values-oidc.yaml
helm get values "$GW" -n "$GNS" -o yaml > /tmp/os-user-values-oidc.yaml
helm upgrade "$GW" "$CHART" --version "$VER" -n "$GNS" \
  -f /tmp/os-user-values-oidc.yaml -f "$HERE/values-operator.yaml" -f /tmp/values-oidc.yaml \
  >/dev/null && echo "helm upgrade ok"
$K -n $GNS rollout status "sts/$GW" --timeout=240s | tail -1 || { $K -n $GNS logs "$GW"-0 --tail=6; exit 1; }
$K -n $GNS get cm openshell-config -o jsonpath='{.data.gateway\.toml}' | sed -n '/gateway.oidc/,/^\[openshell/p'
echo "--- 开 OIDC 之后，原来的 mTLS 客户端证书 CLI 通道会怎样:"
"$CLI" -g "$GWPROF" workspace list 2>&1 | tail -2

fi

echo; echo "########## 30 三个身份走产品自己的 device flow 登录 ##########"
NP=$($K -n $GNS get svc $GW -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}')
EP="https://$NODE_IP:$NP"; echo "endpoint=$EP issuer=$ISSUER"
for spec in "os-alice:alice" "os-bob:bob" "os-tadmin:tadmin"; do
  IFS=: read -r prof user <<<"$spec"; printf "%-10s %-8s " "$prof" "$user"
  cli_login_as "$prof" "$user" "$PASS" "$ISSUER" "$EP" >/dev/null 2>&1 && echo "✓" || echo "✗"
done
echo "--- token 里 gateway 真正读到的 claim（sub / groups / aud）"
for prof in os-alice os-bob os-tadmin; do
  python3 - "$HOME/.config/openshell/gateways/$prof/oidc_token.json" <<'PY'
import base64, json, sys
raw = json.load(open(sys.argv[1]))["access_token"]
p = raw.split('.')[1]; p += '=' * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print(f"  {c.get('sub'):<8} groups={sorted(set(c.get('groups', [])))} aud={c.get('aud')} ttl={c['exp']-c['iat']}s")
PY
done
SUB_ALICE=$(sub_of os-alice); SUB_BOB=$(sub_of os-bob); SUB_TADMIN=$(sub_of os-tadmin)
echo "subject(alice)=$SUB_ALICE  (K8s 与 OpenShell 用的是同一个目录身份，但只有 OpenShell 侧参与授权)"

echo; echo "########## 40 平台侧的“目录组 → workspace 成员”同步（这里手工做）##########"
# 目录里是 tenant-a-users / tenant-b-users 组；OpenShell 侧没有组→workspace 的自动映射，
# 所以这一步必须由平台 Controller 做。映射规则: 组 tenant-X-users → workspace tenant-X-runtime。
for spec in "$A $SUB_ALICE user" "$A $SUB_TADMIN admin" "$B $SUB_BOB user" "$B $SUB_TADMIN user"; do
  set -- $spec
  OSC os-tadmin workspace member add --workspace "$1" --subject "$2" --role "$3" | tail -1
done
for w in "$A" "$B"; do echo "--- member list $w"; sleep 2; OSC os-tadmin workspace member list --workspace "$w" 2>&1 | tail -4; done

echo; echo "########## 50 矩阵：谁能往哪个 ns 落沙箱 ##########"
echo "--- O-01 alice 在 tenant-a-runtime 建沙箱"
sbx os-alice "$A" oa-1
echo "--- O-02 alice 在 tenant-b-runtime 建沙箱（不是成员）"
sbx os-alice "$B" oa-2
echo "--- O-03 alice 列 tenant-b-runtime 的沙箱"
OSC os-alice sandbox list --workspace "$B" | tail -3
echo "--- O-04 bob 对称：b 可、a 不可"
sbx os-bob "$B" ob-1; sbx os-bob "$A" ob-2
echo "--- O-05 tadmin（os-admin = Platform Admin，不是 tenant-b 成员）跨租户"
OSC os-tadmin workspace list | tail -5
sbx os-tadmin "$B" ta-1
echo "--- O-06 边界随成员资格移动（groups 不参与）：把 alice 加进 tenant-b-runtime"
OSC os-tadmin workspace member add --workspace "$B" --subject "$SUB_ALICE" --role user 2>&1 | tail -1
sbx os-alice "$B" oa-2
echo "    移除后再试:"
OSC os-tadmin workspace member remove --workspace "$B" --subject "$SUB_ALICE" 2>&1 | tail -1
sbx os-alice "$B" oa-2b
echo "--- O-07 控制面可见性:alice 在 tenant-a-runtime 只看得到自己的"
OSC os-alice sandbox list --workspace "$A" | tail -4
echo "--- O-09 Workspace User 不能加成员；Platform Admin 提到 Workspace Admin 后就能"
OSC os-alice workspace member add --workspace "$A" --subject "$SUB_BOB" --role user | tail -2
OSC os-tadmin workspace member remove --workspace "$A" --subject "$SUB_ALICE" | tail -1
OSC os-tadmin workspace member add --workspace "$A" --subject "$SUB_ALICE" --role admin | tail -1   # 没有 member update，改角色只能 remove+add
OSC os-alice workspace member add --workspace "$A" --subject "$SUB_BOB" --role user | tail -2
OSC os-alice workspace member list --workspace "$A" | tail -4
echo "--- O-10 Workspace Admin 也不能管别的 workspace"
OSC os-alice workspace member list --workspace "$B" | tail -2
echo "--- O-08 K8s 侧根本没有这些用户身份：租户 ns 的 RoleBinding subject"
$K -n $A get rolebinding -o jsonpath='{range .items[*]}{.metadata.name}{"  subject="}{.subjects[0].kind}/{.subjects[0].namespace}/{.subjects[0].name}{"\n"}{end}'
echo "    用 OIDC 用户/组去问 apiserver:"
$K auth can-i create sandboxes.agents.x-k8s.io -n $A --as=alice --as-group=tenant-a-users --as-group=os-user

echo; echo "########## 60 再接一个租户 T-50933：IdP 侧只加两个组，OpenShell 的角色一个都不加 ##########"
# workspace/ns 名只能 DNS-1123 且 ≤19 字符 → 用 t-50933；"T-50933-USER" 那种大写名不能当 workspace 名
T=t-50933
$K create ns "$T" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K label ns "$T" openshell.ai/workspace=true platform.io/tenant=T-50933 --overwrite >/dev/null
helm upgrade --install openshell-workspace "$WSCHART" --version "$VER" -n "$T" >/dev/null && echo "平台侧: ns $T 已创建 + 打标 + 装 workspace chart（Gateway 不用重启）"
sleep 8; OSC os-tadmin workspace create --name "$T" | tail -1
for spec in "os-u50933:u50933" "os-a50933:a50933"; do IFS=: read -r pr us <<<"$spec"; printf "%-11s %-8s " "$pr" "$us"
  cli_login_as "$pr" "$us" "$PASS" "$ISSUER" "$EP" >/dev/null 2>&1 && echo "✓" || echo "✗"; done
echo "--- 这两个人的 token：roles claim 里只有 os-user + 自己那一个租户组（os-user 是从叶子组的父组继承来的）"
for pr in os-u50933 os-a50933; do python3 - "$HOME/.config/openshell/gateways/$pr/oidc_token.json" <<'PY2'
import base64,json,sys
raw=json.load(open(sys.argv[1]))["access_token"];q=raw.split('.')[1];q+='='*(-len(q)%4)
c=json.loads(base64.urlsafe_b64decode(q));print(f"  sub={c['sub']:<8} groups={sorted(set(c['groups']))} ttl={c['exp']-c['iat']}s")
PY2
done
echo "--- O-11 只有目录组、没有成员关系 → 进不去 t-50933（组本身不授权）"
sbx os-u50933 "$T" tc-1
echo "--- 平台 Controller 要做的那一步：组 → 同名 workspace 的成员（角色也在这里区分 admin/user）"
OSC os-tadmin workspace member add --workspace "$T" --subject "$(sub_of os-u50933)" --role user | tail -1
OSC os-tadmin workspace member add --workspace "$T" --subject "$(sub_of os-a50933)" --role admin | tail -1
echo "--- O-12 同步之后 u50933 能在 t-50933 建沙箱；仍进不去 tenant-a-runtime"
sbx os-u50933 "$T" tc-1
sbx os-u50933 "$A" tc-cross
echo "--- O-13 a50933（T-50933-ADMIN → Workspace Admin）：能管 t-50933 的成员，管不了别的 workspace"
OSC os-a50933 workspace member add --workspace "$T" --subject "$SUB_BOB" --role user | tail -1
OSC os-a50933 workspace member list --workspace "$T" | tail -4
OSC os-a50933 workspace member list --workspace "$A" | tail -2
echo "--- 落点：运行时只在 $T"
$K -n "$T" get pod -l openshell.ai/sandbox 2>/dev/null | tail -2


echo; echo "########## 90 矩阵产物落点（全部在租户 ns 内）##########"
$K get sandboxes.agents.x-k8s.io -A | grep -E "NAMESPACE|oa-|ob-|ta-|tc-"
date -u '+%Y-%m-%dT%H:%M:%SZ'
