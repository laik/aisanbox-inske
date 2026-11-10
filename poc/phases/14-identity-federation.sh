#!/usr/bin/env bash
# POC3 —— 一条身份链同时管住 Kubernetes 与 OpenShell Gateway。
# 手工重现: bash poc/phases/14-identity-federation.sh   (在远端: bash /root/poc2/phases/14-identity-federation.sh)
#
# 这份脚本里的每一行"预期"都来自 POC3.md 的用例表；每一处 ⚠ 注释都是**实测踩过的坑**，
# 不是推测。它同时是"报告里的数字从哪来"的答案 —— 结论里引用的每个 yes/no/HTTP 码都出自这里。
#
# 三条方法论(本轮反复用到，写在这里而不是散在各处):
#  1) **每个"拒绝"都要配一条期待"允许"的正对照**。满屏的 no 不能证明隔离生效 ——
#     claim 读不到、token 没带上、隧道断了，都会得到一模一样的 no。
#  2) **断言跑着的东西，不是配置文件**。values 写错键、ConfigMap 是旧的、port-forward 断了，
#     都不会让"隔离测试"报错，只会让它悄悄变成假的。
#  3) **不用 port-forward**。这是 kind 集群，节点是宿主机上的容器，NodePort 直接可达
#     (见 openshell3/70-gateway-nodeport.yaml)。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=${CTX:-kind-agent-runtime-poc}
K="kubectl --context $CTX"
REALM=aisanbox
ISSUER_PATH=$($K -n identity get cm kc-config -o 'jsonpath={.data.issuer_url}')
ISSUER="$ISSUER_PATH/realms/$REALM"
GW_EP=${GW_EP:-https://172.22.0.3:31444}      # NodePort，见 70-gateway-nodeport.yaml
CLI=vendor/openshell-cli-0.1.7/openshell
SA_ID=3affaeaa-70f6-1041-996a-41648389b70a    # alice  = 目录里的 entryUUID
SB_ID=3b008514-70f6-1041-996c-41648389b70a    # bob
ST_ID=3b001764-70f6-1041-996b-41648389b70a    # tadmin (带 os-admin)
PASS=poc3pass
WS_A=ws-tenant-a; WS_B=ws-tenant-b
CA=/tmp/issuer-ca.crt
[ -s "$CA" ] || cp identity/certs/issuer-ca.crt "$CA"
mkdir -p /tmp/p3
OF=/tmp/p3/cli-out.txt   # CLI 调用的 stdout+stderr 都落这里(见下面 OSC 的 ⚠)
PASS_CNT=0; FAIL_CNT=0
ck() { # ck <用例号> <说明> <期望> <实际>
  local id=$1 what=$2 want=$3 got=$4 mark
  if [ "$want" = "$got" ]; then mark="PASS"; PASS_CNT=$((PASS_CNT+1)); else mark="FAIL"; FAIL_CNT=$((FAIL_CNT+1)); fi
  printf "  %-6s %-46s 期望=%-10s 实际=%-10s %s\n" "$id" "$what" "$want" "$got" "$mark"
}
tok() { curl -sS -m 20 --cacert "$CA" -X POST "$ISSUER/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=openshell-cli -d username=$1 -d password=$PASS \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"; }
# 把 JWT 的 payload 解出来。⚠ 这里**只**用来读 claim，不用来下结论说"用户有什么权限" ——
# 权限的结论来自 apiserver / gateway 自己的回答(见 memory: 不要用被测的东西去测它自己)。
claims() { cut -d. -f2 | python3 -c "
import sys,base64,json
d=json.loads(base64.urlsafe_b64decode(sys.stdin.read()+'==='))
print(json.dumps(d))"; }
# ⚠ 解析失败时必须**出声**。返回空串会被下面的 ck 判成 FAIL，但没人知道是
#   "对方没返回 JSON"还是"我解析写错了" —— 两种原因的动作完全不同。
jq1() { python3 -c "import sys,json,re
src=sys.stdin.read()
# 前面可能混着 WARN openshell_sdk::transport 这类日志行(反引号不能写: 双引号里会被 shell 当命令替换), 从第一个 { 开始取
i=src.find(chr(123))
if i<0: print('PARSE-FAIL:no-json-in-output'); raise SystemExit(0)
try:
    d=json.loads(src[i:])
except Exception as e:
    print('PARSE-FAIL:%s'%e); raise SystemExit(0)
print($1)" 2>/dev/null; }
OSC() { # OSC <profile> <args…> —— 把 stdout+stderr 落到文件，再 cat 出来(不靠命令替换)
  local g=$1; shift
  : > "$OF" 2>/dev/null
  OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$g" "$@" > "$OF" 2>&1
  cat "$OF"
}
# ⚠ 为什么不用 OUT=$(OSC …): 实测同一条命令在**命令替换**里只捕到 `WARN …TLS certificate
#   verification is disabled` 那一行，真正的 `Error: × …` 块没进管道(直接写到了终端)。
#   于是 G-03/G-05/G-11 明明**被正确拒绝**却判成 FAIL。改成文件中转后，断言读的是文件，
#   拒绝原文还能顺手打印出来(§五"失败可观测"正好要这个)。
OC() { local g=$1; shift; : > "$OF"; OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$g" "$@" > "$OF" 2>&1; tr '\n' ' ' < "$OF"; }
# 上面那个 2>&1 是**故意**的: 断言"被拒"时要拿到 message，只有退出码不够。
# 但 -o json 时 stderr 里混着 `WARN openshell_sdk::transport: TLS certificate verification…`，
# 直接喂 JSON 解析器会得到 `PARSE-FAIL: Extra data: line 1 column 5` —— 那不是 gateway 的问题。
# ⇒ 取 JSON 要另开一路，把 stderr 丢掉。
OSCJSON() { local g=$1; shift; OPENSHELL_GATEWAY_INSECURE=true "$CLI" -g "$g" "$@" 2>/dev/null; }

echo "########## 0. 前置: 集群里跑的配置 == 仓库里的配置(否则后面全部无意义) ##########"
LOCAL_HASH=$(cat identity/BUILD-HASH 2>/dev/null)
CLUSTER_SCRIPT=$($K -n identity get cm kc-realm-config -o 'jsonpath={.data.realm-script\.sh}' 2>/dev/null)
printf "  %-52s 本地=%s\n" "realm 配置的源文件哈希" "${LOCAL_HASH:0:16}…"
# ⚠ 算法必须**逐字**照 build-realm-configmap.py: key 名 + 文件内容依次喂进同一个 sha256。
#   我自己拼错过一次，得到 e3b0c442…(那是**空串**的 sha256 —— jsonpath 取不到值时不会报错)。
REBUILD=$(python3 - "$LOCAL_HASH" <<'PY'
import glob,hashlib,io,os,sys
root=os.path.join(os.getcwd(),"identity")
h=hashlib.sha256(); h.update(b"realm-script.sh")
h.update(io.open(os.path.join(root,"realm-script.sh"),"rb").read())
for f in sorted(glob.glob(os.path.join(root,"keycloak","*.json"))):
    h.update(os.path.basename(f).encode()); h.update(io.open(f,"rb").read())
print(h.hexdigest())
PY
)
# P-01 断言的是"集群里那份**含有当前源文件才有的内容**"，不是"非空"。
# 标记用本轮新加的 client 属性(旧的 ConfigMap 里一定没有它)——
# 单看"非空"会得到 e3b0c442…(空串的 sha256)那种假通过，见下面 REBUILD 的注释。
MARK='oauth2.device.authorization.grant.enabled'
echo "$CLUSTER_SCRIPT" | grep -q "$MARK" && ck P-01 "集群里的 realm 脚本含当前源才有的配置" PASS "PASS" \
  || ck P-01 "集群里的 realm 脚本含当前源才有的配置" PASS "FAIL"
for jf in 22-claim-roles 24-claim-sub-from-ldap; do
  $K -n identity get cm kc-realm-config -o "jsonpath={.data.$jf\.json}" 2>/dev/null | grep -q '"claim.name"' \
    && ck P-01b "ConfigMap 里有 $jf" PASS "PASS" || ck P-01b "ConfigMap 里有 $jf" PASS "FAIL"
done
[ "$REBUILD" = "$LOCAL_HASH" ] && ck P-02 "30-keycloak-realm.yaml 与源文件一致" PASS "PASS" || {
  echo "  P-02 FAIL: 源文件哈希=$REBUILD 与 BUILD-HASH=$LOCAL_HASH 不一致 —— 先跑 build-realm-configmap.py"; FAIL_CNT=$((FAIL_CNT+1)); }
$K -n identity logs job/kc-realm 2>&1 | grep -q "=== 完成 ===" \
  && ck P-03 "realm 配置 Job 成功跑过" PASS "PASS" || ck P-03 "realm 配置 Job 成功跑过" PASS "FAIL"

# 正在生效的 apiserver OIDC flag（从**节点上的 manifest**读，不是从 kubeadm-config 读）
echo "  正在生效的 apiserver OIDC flag:"
docker exec agent-runtime-poc-control-plane sh -c 'grep -o "\-\-oidc-[a-z-]*=[^\" ]*" /etc/kubernetes/manifests/kube-apiserver.yaml' | sed 's/^/    /' | tee /tmp/p3/flags.txt >/dev/null
grep -q -- "--oidc-groups-claim=groups" /tmp/p3/flags.txt && ck P-04 "apiserver 用顶层 groups claim(与 Gateway 同一个)" PASS "PASS" \
  || ck P-04 "apiserver 用顶层 groups claim(与 Gateway 同一个)" PASS "FAIL"

# 正在生效的 Gateway OIDC（读**跑着的 TOML**，见 openshell3/gateway-oidc-values.yaml 的 ⚠⚠）
GTOML=$($K -n poc3-gateway get cm -l app.kubernetes.io/name=openshell -o 'jsonpath={.items[0].data.gateway\.toml}' 2>/dev/null)
for kv in "issuer = \"$ISSUER\"" 'roles_claim = "groups"' 'admin_role = "os-admin"' 'user_role = "os-user"' 'audience = "openshell-cli"'; do
  echo "$GTOML" | grep -qF "$kv" && ck P-05 "gateway.toml: $kv" PASS "PASS" || ck P-05 "gateway.toml: $kv" PASS "FAIL"
done
echo "$GTOML" | grep -q "client_ca_path" && ck P-06 "mTLS 已关(不再要求客户端证书)" PASS "FAIL" || ck P-06 "mTLS 已关(不再要求客户端证书)" PASS "PASS"
echo "$GTOML" | grep -q "allow_unauthenticated_users = true" && ck P-07 "未认证用户没有被兜底放行" PASS "FAIL" || ck P-07 "未认证用户没有被兜底放行" PASS "PASS"
# ⚠ issuer 的 CA **不在** TOML 里，是给 TLS 栈的进程级 env(chart 注释明说不能进 schema)。
$K -n poc3-gateway get sts p3-openshell -o 'jsonpath={.spec.template.spec.containers[0].env[*].name}' | grep -q SSL_CERT_FILE \
  && ck P-08 "issuer CA 已交给 gateway(走 SSL_CERT_FILE)" PASS "PASS" || ck P-08 "issuer CA 已交给 gateway(走 SSL_CERT_FILE)" PASS "FAIL"

echo
echo "########## 1. 身份与声明(§一) ##########"
declare -A SUB TEN GRP AT
for u in alice bob tadmin; do
  T=$(tok $u); AT[$u]=$T
  C=$(printf '%s' "$T" | claims)
  SUB[$u]=$(printf '%s' "$C" | jq1 "d['sub']"); TEN[$u]=$(printf '%s' "$C" | jq1 "d.get('tenant','')")
  GRP[$u]=$(printf '%s' "$C" | jq1 "','.join(sorted(d.get('groups',[])))")
  printf "  %-7s sub=%s tenant=%s groups=%s\n" "$u" "${SUB[$u]}" "${TEN[$u]}" "${GRP[$u]}"
done
ck K-01 "alice 的 sub == 目录里的 entryUUID" "$SA_ID" "${SUB[alice]}"
ck K-02 "bob 的 sub == 目录里的 entryUUID"   "$SB_ID" "${SUB[bob]}"
# ⚠ groups 是**集合**，顺序不保证。按前缀 grep 会假失败(实测 alice 的排序是
#   os-user,tenant-a-owners,tenant-a-users，与我猜的不同)。按成员逐个判。
all_in() { local n; for n in $1; do echo "$2" | grep -q "$n" || return 1; done; return 0; }
all_in "os-user tenant-a-users tenant-a-owners" "${GRP[alice]}" && ck K-03 "alice 的组全部来自目录" PASS "PASS" || ck K-03 "alice 的组全部来自目录" PASS "FAIL"
all_in "os-admin" "${GRP[tadmin]}" && ck K-03b "os-admin 只落在 tadmin 身上" PASS "PASS" || ck K-03b "os-admin 只落在 tadmin 身上" PASS "FAIL"
echo "${GRP[bob]}" | grep -q "tenant-a" && ck K-03c "bob 的 token 里没有 tenant-a 的组" PASS "FAIL" || ck K-03c "bob 的 token 里没有 tenant-a 的组" PASS "PASS"
echo "${TEN[alice]}" | grep -q tenant-a && ck K-04 "租户标识 claim(tenant)存在" PASS "PASS" || ck K-04 "租户标识 claim(tenant)存在" PASS "FAIL"
# 对照: 换 aud 的 token 应当被 apiserver 拒(--oidc-required-claim=aud=…)。
# 这条是补架构约束里的洞: kube-apiserver v1.37 **没有** --oidc-audience，而 Gateway 会校验 aud。
# 对照: 同一个用户、**aud 不对**的 token 应当被 apiserver 拒。
# ⚠ 这条用例的**输入**本身是个坑，第一版造不出来:
#   `client_id=openshell-cli&audience=someone-else` 出来的 token 里 aud 仍是 `openshell-cli`
#   (Keycloak 以 client 自己的 audience 为准)，于是 apiserver 理所当然地接受它 ——
#   这不是"required-claim 没生效"，是**没有 aud 不对的 token 可用**。
#   办法是换 client: realm-script §2b 里的 `poc3-other-aud`(同 issuer、同用户、同 claim，只有 aud 不同)。
for cl in poc3-other-aud openshell-cli; do
  BADAUD=$(curl -sS -m 20 --cacert "$CA" -X POST "$ISSUER/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=$cl -d username=alice -d password=$PASS \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  [ -n "$BADAUD" ] || { echo "      $cl: 没拿到 token(先跑 identity/30 的 Job)"; ck K-05-$cl "$cl 的 token 能被 apiserver 判定" PASS "NO-TOKEN"; continue; }
  AUD=$(cut -d. -f2 <<<"$BADAUD" | python3 -c "import sys,base64,json;d=sys.stdin.read();print(json.loads(base64.urlsafe_b64decode(d+'===' )).get('aud'))")
  # ⚠ CA 必须先落盘再用 --kubeconfig 指过去。第一版写成
  #   `--certificate-authority=<(cat …)`，文件还不存在时得到的是**空 CA**，
  #   报错是 `x509: certificate signed by unknown authority` —— 那是**探针**坏了，
  #   不是 aud 被拒。把它当成 K-05 的结果，就是自己骗自己。
  [ -s /tmp/cluster-ca.crt ] || $K -n kube-system get cm kube-root-ca.crt -o 'jsonpath={.data.ca\.crt}' > /tmp/cluster-ca.crt
  cat > /tmp/p3/kc-aud.yaml <<KUBE
apiVersion: v1
kind: Config
clusters: [{name: c, cluster: {server: "https://172.22.0.3:6443", certificate-authority: /tmp/cluster-ca.crt}}]
users: [{name: who, user: {token: "$BADAUD"}}]
contexts: [{name: c, context: {cluster: c, user: who}}]
current-context: c
KUBE
  R=$(timeout 30 kubectl --kubeconfig=/tmp/p3/kc-aud.yaml auth whoami 2>&1 | tr '\n' ' ')
  printf "      client=%-16s token aud=%-16s apiserver: %s\n" "$cl" "$AUD" "$(echo "$R" | cut -c1-110)"
  if [ "$cl" = poc3-other-aud ]; then
    echo "$R" | grep -qiE "unauthorized|doesn't have required claim" \
      && ck K-05 "aud 不对的 token 被 apiserver 拒(--oidc-required-claim)" PASS "PASS" \
      || { ck K-05 "aud 不对的 token 被 apiserver 拒(--oidc-required-claim)" PASS "FAIL"; }
  else
    # 正对照: 换 aud 就拒，那 aud 对时必须**接受** —— 否则上面的"被拒"什么也证明不了。
    echo "$R" | grep -q "$SA_ID" \
      && ck K-05b "正对照: aud 正确的同一个用户被接受" PASS "PASS" \
      || ck K-05b "正对照: aud 正确的同一个用户被接受" PASS "FAIL"
  fi
done

# 每人一份**只用 token** 的 kubeconfig。
# ⚠ 实测坑(本轮最重要的一次假结论): 复用默认 kubeconfig 时，客户端证书会**盖过** token，
#   whoami 显示的是 kubernetes-admin，can-i 全是 yes —— 整张矩阵作废。必须单独建 config。
[ -s /tmp/cluster-ca.crt ] || $K -n kube-system get cm kube-root-ca.crt -o 'jsonpath={.data.ca\.crt}' > /tmp/cluster-ca.crt
for u in alice bob tadmin; do
  cat > /tmp/p3/kc-$u.yaml <<KUBE
apiVersion: v1
kind: Config
clusters: [{name: c, cluster: {server: "https://172.22.0.3:6443", certificate-authority: /tmp/cluster-ca.crt}}]
users: [{name: who, user: {token: "${AT[$u]}"}}]
contexts: [{name: c, context: {cluster: c, user: who}}]
current-context: c
KUBE
done
KU() { local u=$1; shift; kubectl --kubeconfig=/tmp/p3/kc-$u.yaml "$@" 2>&1; }

echo
echo "########## 2. Kubernetes 侧(§二) ##########"
for u in alice bob tadmin; do
  echo "  --- $u 在 apiserver 眼里的身份"
  KU $u auth whoami 2>&1 | sed 's/^/      /'
done
echo "  --- 读权限矩阵(can-i)"
for u in alice bob; do
  for ns in tenant-a-runtime tenant-a-gateway tenant-b-runtime tenant-b-gateway; do
    printf "  %-6s list pods %-20s -> " $u $ns; KU $u auth can-i list pods -n $ns | tail -1
  done
  printf "  %-6s list nodes(集群级)        -> " $u; KU $u auth can-i list nodes | tail -1
done
echo "  --- 正对照(必须为 yes，否则上面整张矩阵无意义): 故意把 tenant-b-users 绑进 tenant-a-runtime"
printf "  %-6s list pods tenant-a-runtime -> " bob; KU bob auth can-i list pods -n tenant-a-runtime | tail -1
printf "  %-6s list pods tenant-a-gateway -> " bob; KU bob auth can-i list pods -n tenant-a-gateway | tail -1
echo "  --- 真实写入(kubectl run，不是 can-i 的推测)"
for u in alice bob; do
  for ns in tenant-a-runtime tenant-b-runtime; do
    # ⚠ -n 必须在 `--` **之前**。写在后面会被当成容器参数，请求发到 default ns，
    #   报错是 `... in the namespace "default"` —— 看着像权限问题，其实是命令写错。
    OUT=$(KU $u run poc3-$u-$ns --image=busybox:1.36 --restart=Never -n $ns --command -- sleep 20)
    printf "  %-6s create pod %-20s -> %s\n" $u $ns "$(echo "$OUT" | head -1 | cut -c1-110)"
  done
done
$K -n tenant-a-runtime delete pod poc3-alice-tenant-a-runtime poc3-bob-tenant-a-runtime --ignore-not-found >/dev/null 2>&1
$K -n tenant-b-runtime delete pod poc3-alice-tenant-b-runtime poc3-bob-tenant-b-runtime --ignore-not-found >/dev/null 2>&1
echo "  --- RBAC 允许但策略拒绝(§二.3: 权限不是唯一边界)"
# alice 对 tenant-a-runtime 有 create pods(上面已证)，但 Gatekeeper 的租户边界约束挡 hostNetwork。
OUT=$(KU alice run poc3-gk --image=busybox:1.36 --restart=Never -n tenant-a-runtime \
        --overrides='{"spec":{"hostNetwork":true}}' --command -- sleep 20)
echo "$OUT" | grep -qiE "denied|hostNetwork" && ck X-01 "RBAC 允许、Gatekeeper 拒绝" PASS "PASS" || { echo "      实际: $(echo "$OUT"|head -1)"; ck X-01 "RBAC 允许、Gatekeeper 拒绝" PASS "FAIL"; }
KU alice delete pod poc3-gk -n tenant-a-runtime --ignore-not-found >/dev/null 2>&1

echo
echo "########## 2b. 租户网络隔离(Capsule networkPolicies —— 修正 POC2 §5.4) ##########"
$K get networkpolicy -l capsule.clastix.io/network-policy -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPES:.spec.policyTypes' --no-headers 2>&1 | sed 's/^/  /' | head -6
# ⚠ 不带 -A 的 `get networkpolicy -l ...` 只查**当前 namespace**(这里是 default)，
#   于是一个都数不到 —— 会被误判成「平台没下发策略」。
NP=$($K get networkpolicy -A -l capsule.clastix.io/network-policy --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${NP:-0}" -ge 2 ] && ck N-01 "平台为两个租户都下发了 NetworkPolicy" PASS "PASS" || ck N-01 "平台为两个租户都下发了 NetworkPolicy" PASS "FAIL"
echo "  --- 跨租户流量实测(不是看策略，是打流量)"
# ⚠ 探针本身要先立住。第一版用
#   `exec ... -- sh -c "echo x | nc -l -p 8081 -q1 & sleep 1"` 起监听，
#   那个 nc 在 exec 返回后**就退出了**(-q1 = EOF 后 1s)。
#   于是「跨租户 BLOCKED」与「同租户 REACHED」都可能来自监听器而不是策略 —— 测的是工具，不是隔离。
#   正确做法: 用一个**常驻**服务 Pod(busybox httpd -f 保持前台)，从别的 ns 打过去。
mk() { # mk <ns> <pod> <args...>
  local ns=$1 pod=$2; shift 2
  $K -n $ns run $pod --image=busybox:1.36 --restart=Never --command -- "$@" >/dev/null 2>&1
  $K -n $ns wait --for=condition=Ready pod/$pod --timeout=120s >/dev/null 2>&1
}
mk tenant-b-runtime p3-srvb  sh -c "echo b > /tmp/index.html; httpd -f -p 8081 -h /tmp"
mk tenant-b-runtime p3-cli-b sh -c "sleep 900"
mk tenant-a-runtime p3-clia  sh -c "sleep 900"
IPB=$($K -n tenant-b-runtime get pod p3-srvb -o 'jsonpath={.status.podIP}')
echo "  服务端 Pod 就绪: p3-srvb=$IPB"
probe() { $K -n $1 exec $2 -- sh -c "wget -q -T 5 -O- http://$3:8081/ >/dev/null 2>&1" && echo REACHED || echo BLOCKED; }
R=$(probe tenant-a-runtime p3-clia "$IPB")
printf "  a -> b(跨租户)         : %s\n" "$R"
[ "$R" = BLOCKED ] && ck N-02 "跨租户 Pod 不通" PASS "PASS" || ck N-02 "跨租户 Pod 不通" PASS "FAIL"
echo "  --- 同租户内的正对照(必须 REACHED，否则上面那条只是网络本来就断了)"
R2=$(probe tenant-b-runtime p3-cli-b "$IPB")
printf "  b -> b(同租户)         : %s\n" "$R2"
[ "$R2" = REACHED ] && ck N-03 "同租户 Pod 可达(正对照)" PASS "PASS" || ck N-03 "同租户 Pod 可达(正对照)" PASS "FAIL"
echo "  --- 可加性(必须写进结论的告警): 租户自己建一条 NetworkPolicy 就能把边界打开"
$K apply -f - >/dev/null 2>&1 <<'YML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: p3-reopen, namespace: tenant-b-runtime}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{from: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: tenant-a-runtime}}}]}]
YML
sleep 8
R3=$(probe tenant-a-runtime p3-clia "$IPB")
printf "  租户自建策略后 a -> b  : %s\n" "$R3"
# NetworkPolicy 的语义是**并集**: 同一 Pod 上多条 Ingress 策略相加。
# 所以租户自己建一条就能把平台画的边界**放宽**。要「画了就不能改」，
# 得用 Capsule 的 spec.rules.enforce.policies 或 Antrea ClusterNetworkPolicy。
[ "$R3" = REACHED ] && ck N-04 "租户自建 NetworkPolicy 会放宽边界(可加性)" PASS "PASS" \
  || ck N-04 "租户自建 NetworkPolicy 会放宽边界(可加性)" PASS "FAIL"
$K -n tenant-b-runtime delete netpol p3-reopen --ignore-not-found >/dev/null 2>&1
sleep 8
R4=$(probe tenant-a-runtime p3-clia "$IPB")
printf "  撤掉自建策略后 a -> b  : %s\n" "$R4"
[ "$R4" = BLOCKED ] && ck N-05 "撤掉后边界恢复" PASS "PASS" || ck N-05 "撤掉后边界恢复" PASS "FAIL"
$K -n tenant-a-runtime delete pod p3-clia --ignore-not-found >/dev/null 2>&1
$K -n tenant-b-runtime delete pod p3-srvb p3-cli-b --ignore-not-found >/dev/null 2>&1

echo
echo "########## 3. OpenShell Gateway 侧(§三) ##########"
echo "  ⚠ 连接方式: NodePort($GW_EP)。POC2 用的 port-forward 在这种多轮矩阵里会断，"
echo "    断掉之后每个调用都返回 \"connect error: transport error\" —— 那不是拒绝，是隧道没了。"
source openshell3/lib-cli-login.sh
for u in alice bob tadmin; do
  cli_login_as "p3-$u" $u $PASS "$ISSUER" "$GW_EP" >/tmp/p3/login-$u.log 2>&1 \
    && printf "  %-7s 登录成功(CLI 自己的 device flow)\n" $u || { printf "  %-7s 登录失败\n" $u; tail -3 /tmp/p3/login-$u.log | sed 's/^/      /'; }
done
# ⚠ 先清场。不清的话这一节会读到上一轮留下的对象:
#   `workspace create` 得到 "workspace already exists"、`sandbox create` 得到
#   "sandbox 'p3-a1' already exists" —— 那**不是**隔离通过，是名字撞了。上一轮 G-10 就是这么假的 FAIL。
# 顺序**必须**是"先 sandbox、再 workspace": 反过来的话 workspace 删除停在 Terminating
# ("still contains resources: sandbox, sandbox policy")，而**停在那里的名字仍然占着**——
# 下一轮 `workspace create` 得到 "workspace already exists"、`member add` 得到
# "workspace 'ws-tenant-a' is being deleted"、`sandbox create` 拿不到真结果。
# 上一轮 G-03/G-06/G-10 三个 FAIL 全是这一个原因(实测: ws-tenant-a 从 06:10 一直 Terminating)。
for w in $WS_A $WS_B; do
  OC p3-tadmin --workspace $w sandbox delete --all >/dev/null 2>&1
done
for w in $WS_A $WS_B; do
  OC p3-tadmin workspace delete $w >/dev/null 2>&1
done
# 删除是**异步**的: 等名字真的从 list 里消失，而不是 sleep 5 拍脑袋。
for _i in $(seq 1 30); do
  L=$(OC p3-tadmin workspace list | grep -oE 'ws-[a-z-]+' | sort -u | tr '\n' ',')
  case "$L" in *"$WS_A"*|*"$WS_B"*) sleep 3 ;; *) break ;; esac
done
echo "  清场后现存 Workspace: $(OC p3-tadmin workspace list | grep -oE 'ws-[a-z-]+' | sort -u | tr '\n' ',' || echo 无)"
echo "  --- 两侧身份是否同一人(§四的核心一条)"
for u in alice bob tadmin; do
  GW_SUB=$(OSCJSON p3-$u whoami -o json | jq1 "d['subject']")
  ck G-01 "$u: apiserver 与 gateway 看到的 subject 相同" "${SUB[$u]}" "$GW_SUB"
done
echo "  --- 未认证调用(证明这台 Gateway 真的要求认证，不是所有请求都放行)"
# 注册一台**从不登录**的 gateway: 有 endpoint 没有 token。
OPENSHELL_NO_BROWSER=1 OPENSHELL_GATEWAY_INSECURE=true timeout 20 "$CLI" gateway add "$GW_EP" \
  --name p3-nonauth --oidc-issuer "$ISSUER" --oidc-client-id openshell-cli >/dev/null 2>&1
OUT=$(OC p3-nonauth workspace list); printf "      未认证调用的原文: %s\n" "$(echo "$OUT" | cut -c1-160)"; echo "$OUT" | grep -qiE "credentials are missing|unauth" && ck G-02 "无凭证时被拒" PASS "PASS" || ck G-02 "无凭证时被拒" PASS "FAIL"
echo "  --- 只有 os-admin 能建 Workspace"
W1=$(OC p3-tadmin workspace create --name $WS_A)
printf "      tadmin 建 %s 的返回: %s\n" "$WS_A" "$(echo "$W1" | cut -c1-140)"
echo "$W1" | grep -qiE "created" && ck G-03 "tadmin(os-admin) 建 Workspace" PASS "PASS" || ck G-03 "tadmin(os-admin) 建 Workspace" PASS "FAIL"
W2=$(OC p3-tadmin workspace create --name $WS_B)
echo "$W2" | grep -qiE "created" && ck G-04 "tadmin 建第二个 Workspace" PASS "PASS" \
  || { printf "      建 %s 的返回: %s\n" "$WS_B" "$(echo "$W2" | cut -c1-140)"; ck G-04 "tadmin 建第二个 Workspace" PASS "FAIL"; }
GOUT=$(OC p3-alice workspace create --name ws-by-alice)
# 真实拒绝原文(多行，要先压成一行再匹配):
#   Error: × code: 'The caller does not have permission to execute the specified operation',
#          message: "role 'os-admin' required"
echo "$GOUT" | grep -qiE "does not have permission|role 'os-admin' required|denied|forbidden|not authorized" \
  && ck G-05 "os-user 建 Workspace 被拒(只有 os-admin 可以)" PASS "PASS" \
  || { echo "      实际: $(echo "$GOUT" | cut -c1-200)"; ck G-05 "os-user 建 Workspace 被拒(只有 os-admin 可以)" PASS "FAIL"; }
echo "  --- Workspace 成员资格按 subject 绑定(数据只有目录里的 entryUUID)"
M1=$(OC p3-tadmin workspace member add --workspace $WS_A --subject "${SUB[alice]}" --role user)
printf "      member add alice: %s\n" "$(echo "$M1" | cut -c1-120)"
echo "$M1" | grep -qiE "added|already exists" && ck G-06 "把 alice 加入 $WS_A" PASS "PASS" || ck G-06 "把 alice 加入 $WS_A" PASS "FAIL"
M2=$(OC p3-tadmin workspace member add --workspace $WS_B --subject "${SUB[bob]}" --role user)
echo "$M2" | grep -qiE "added|already exists" && ck G-07 "把 bob 加入 $WS_B" PASS "PASS" || ck G-07 "把 bob 加入 $WS_B" PASS "FAIL"
echo "  --- 谁能看到哪些 Workspace"
for u in alice bob tadmin; do
  V=$(OC p3-$u workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
  printf "  %-7s 看到: %s\n" "$u" "${V:-（空）}"
done
VA=$(OC p3-alice workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
[ "$VA" = "$WS_A," ] && ck G-08 "alice 只看得到 $WS_A" PASS "PASS" || { echo "      实际: $VA"; ck G-08 "alice 只看得到 $WS_A" PASS "FAIL"; }
VB=$(OC p3-bob workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
[ "$VB" = "$WS_B," ] && ck G-09 "bob 只看得到 $WS_B" PASS "PASS" || { echo "      实际: $VB"; ck G-09 "bob 只看得到 $WS_B" PASS "FAIL"; }
echo "  --- 在别人的 Workspace 里建 sandbox"
S1=$(OC p3-alice --workspace $WS_A sandbox create --name p3-a1 --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never)
printf "      alice 在 %s 建 p3-a1 的返回: %s\n" "$WS_A" "$(echo "$S1" | cut -c1-150)"
echo "$S1" | grep -qiE "created|provision" && ck G-10 "alice 在 $WS_A 建 sandbox" PASS "PASS" \
  || { ck G-10 "alice 在 $WS_A 建 sandbox" PASS "FAIL"; }
S2=$(OC p3-alice --workspace $WS_B sandbox create --name p3-a2 --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never)
# ⚠ 匹配前先压成一行: 这段拒绝是**多行**的(gRPC code 一行、message 折行)，
#   逐行 grep 会把 "not a member of workspace" 从中间切断，于是**真的拒绝**被判成 FAIL。
printf "      alice 在 %s 建 p3-a2 被拒的原文: %s\n" "$WS_B" "$(echo "$S2" | cut -c1-260)"
echo "$S2" | grep -qiE "not a member|does not have permission|denied|forbidden|unauthorized" \
  && ck G-11 "alice 在 $WS_B 建 sandbox 被拒" PASS "PASS" \
  || { ck G-11 "alice 在 $WS_B 建 sandbox 被拒" PASS "FAIL"; }
echo "  --- 列表也只看得见自己的"
LA=$(OC p3-alice --workspace $WS_A sandbox list | grep -oE "p3-a[0-9]" | sort -u | tr '\n' ',')
LB=$(OC p3-alice --workspace $WS_B sandbox list | grep -oE "p3-a[0-9]" | sort -u | tr '\n' ',')
printf "  alice 在 %s 看到: %s\n" "$WS_A" "${LA:-（空）}"
printf "  alice 在 %s 看到: %s\n" "$WS_B" "${LB:-（空/被拒）}"
echo "$LA" | grep -q "p3-a1" && ck G-10b "$WS_A 里列得到 p3-a1" PASS "PASS" || ck G-10b "$WS_A 里列得到 p3-a1" PASS "FAIL"
echo "  --- W-11 对照: 边界随成员资格移动，不是随名字"
OC p3-tadmin workspace member add --workspace $WS_B --subject "${SUB[alice]}" --role user >/dev/null
VA2=$(OC p3-alice workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
printf "  加成员后 alice 看到: %s\n" "${VA2:-（空）}"
[ "$VA2" = "$WS_A,$WS_B," ] && ck G-12 "加入后 alice 能看到 $WS_B" PASS "PASS" || ck G-12 "加入后 alice 能看到 $WS_B" PASS "FAIL"
S3=$(OC p3-alice --workspace $WS_B sandbox create --name p3-a3 --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never)
echo "$S3" | grep -qiE "created|provision" && ck G-12b "成为成员后**可以**在 $WS_B 建 sandbox" PASS "PASS" \
  || { printf "      返回: %s\n" "$(echo "$S3" | cut -c1-150)"; ck G-12b "成为成员后**可以**在 $WS_B 建 sandbox" PASS "FAIL"; }
OC p3-tadmin workspace member remove --workspace $WS_B --subject "${SUB[alice]}" >/dev/null 2>&1
VA3=$(OC p3-alice workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
printf "  移出后 alice 看到: %s\n" "${VA3:-（空）}"
[ "$VA3" = "$WS_A," ] && ck G-13 "移出后边界恢复" PASS "PASS" || ck G-13 "移出后边界恢复" PASS "FAIL"

echo
echo "########## 4. 跨系统一致性(§四) ##########"
# (a) 两侧读的是**同一个** claim 名。不是"各自配好了"，是同一个字段。
grep -q -- "--oidc-groups-claim=groups" /tmp/p3/flags.txt && echo "$GTOML" | grep -q 'roles_claim = "groups"' \
  && ck C-01 "apiserver 与 Gateway 读同一个 groups claim" PASS "PASS" || ck C-01 "apiserver 与 Gateway 读同一个 groups claim" PASS "FAIL"
# (b) 同一个 subject 在两侧都能用来授权(上面 G-01 + 上面 member add 成功已分别证)。
# (c) 只改目录，不改任何一处授权配置，两侧同时跟着变。
#     做法: 往 LDAP 的 tenant-b-users 里加 alice ⇒ K8s 侧应当立刻把 alice 当 tenant-b 的成员。
# ⚠ `kubectl exec ... -- sh -c "cat >f"` **必须带 -i**: 不带时 stdin 被丢掉、文件是 0 字节，
#   而命令返回 0。我在 Keycloak 那次踩过同一个坑，这里又踩了一次 —— 现象是
#   "改了目录但什么都没变"，根因是 ldif 是空的。**改完把目录读回来确认**，别靠后面的结果猜。
LD=deployment/openldap
LDAPU=ldap://openldap.identity.svc.cluster.local:389
BINDDN="cn=admin,dc=aisanbox,dc=example"
chg() { # chg <add|delete>: 改目录里 alice 的租户组成员关系，并把目录当前状态读回来
  printf 'dn: cn=tenant-b-users,ou=groups,dc=aisanbox,dc=example\nchangetype: modify\n%s: member\nmember: uid=alice,ou=people,dc=aisanbox,dc=example\n' "$1" \
    | $K -n identity exec -i "$LD" -- sh -c 'cat > /tmp/chg.ldif'
  $K -n identity exec "$LD" -- sh -c 'wc -l /tmp/chg.ldif | sed "s/^/      ldif 行数: /"'
  $K -n identity exec "$LD" -- ldapmodify -x -H "$LDAPU" -D "$BINDDN" -w pocadminpass -f /tmp/chg.ldif 2>&1 | sed 's/^/      /'
  $K -n identity exec "$LD" -- sh -c "ldapsearch -x -H $LDAPU -D \"$BINDDN\" -w pocadminpass -b 'cn=tenant-b-users,ou=groups,dc=aisanbox,dc=example' member 2>/dev/null" \
    | grep '^member:' | sed 's/^/      目录里的 member: /'
}
chg add
# ⚠ 实测(多轮，2026-11-10): **改了目录不会自己到 token 里**。Keycloak 26.4 的 LDAP 用户是
#   "惰性导入 + 本地副本" —— 副本已经存在时，改组**不会**刷新它；重跑整个 realm Job 也不刷新
#   (它的 §4b 只在 federationLink 与当前 provider 不一致时才删副本)。
#   想让变更生效只有一条实测可行的路: **删掉该用户的本地副本**，下一次请求按目录重新导入。
#   (试过但**不可用**的两条: ① kcadm `create user-storage/<id>/sync -q action=…` → "Missing action";
#    ② REST `POST /admin/realms/aisanbox/user-storage/<id>/sync?action=import|changedUsersSync`
#      → HTTP 400 `{"error":"Unknown action: …"}`; 且 serverinfo 里 LDAP provider 只有
#      `importEnabled`/`syncRegistrations` 两项，**没有** fullSyncPeriod/changedSyncPeriod。)
#   这条既是 POC 的操作步骤，也是约束漏洞之一: 生产上需要一个"目录变更 -> 删副本/重导入"的
#   同步器，或者把 claim 的来源换成**逐请求读目录**，否则权限变更永远慢一步。
KC_POD=$($K -n identity get pods -o name | grep keycloak- | grep -v realm | head -1 | sed 's|pod/||')
reimport() { # reimport <用户名>: 删本地联邦副本，让下一次认证按目录重新导入
  kubectl --context $CTX -n identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh \
    config credentials --server http://keycloak-admin.identity.svc.cluster.local:8080 \
    --realm master --user pocadmin --password pocadminpass >/dev/null 2>&1
  local uid
  uid=$(kubectl --context $CTX -n identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh \
        get users -r $REALM -q "search=$1" 2>/dev/null | grep -m1 '"id"' | sed 's/.*"id" : "//;s/".*//')
  kubectl --context $CTX -n identity exec -i $KC_POD -- /opt/keycloak/bin/kcadm.sh \
    delete "users/$uid" -r $REALM >/dev/null 2>&1
  echo "      已丢弃 $1 的本地副本($uid) —— 下次认证按目录重新导入"
}
reimport alice
sleep 3
# ⚠ 这里必须**重新签** token 和 kubeconfig。复用 §2 那份会得到
#   `You must be logged in to the server (Unauthorized)` —— 那是 token 过期，
#   不是"目录改动没生效"。这正是 C-03 上一轮的假失败原因。
NT=$(tok alice); AT[alice]=$NT
cat > /tmp/p3/kc-alice.yaml <<KUBE
apiVersion: v1
kind: Config
clusters: [{name: c, cluster: {server: "https://172.22.0.3:6443", certificate-authority: /tmp/cluster-ca.crt}}]
users: [{name: who, user: {token: "$NT"}}]
contexts: [{name: c, context: {cluster: c, user: who}}]
current-context: c
KUBE
GRP2=$(printf '%s' "$NT" | claims | jq1 "','.join(sorted(d.get('groups',[])))")
echo "  改目录后 alice 的 groups: $GRP2"
all_in "tenant-b-users" "$GRP2" && ck C-02 "目录改组 -> token 立刻跟着变" PASS "PASS" || ck C-02 "目录改组 -> token 立刻跟着变" PASS "FAIL"
printf "  alice 现在能读 tenant-b-runtime 吗: "; KU alice auth can-i list pods -n tenant-b-runtime | tail -1
K2=$(KU alice auth can-i list pods -n tenant-b-runtime | tail -1)
[ "$K2" = yes ] && ck C-03 "目录改组 -> K8s 侧授权跟着变" PASS "PASS" || ck C-03 "目录改组 -> K8s 侧授权跟着变" PASS "FAIL"
cli_login_as "p3-alice" alice $PASS "$ISSUER" "$GW_EP" >/tmp/p3/relogin-alice.log 2>&1
GROUT=$(OSCJSON p3-alice workspace list | grep -oE "ws-[a-z-]+" | sort -u | tr '\n' ',')
printf "  同一个人在 Gateway 侧能看到的 Workspace: %s\n" "${GROUT:-（空）}"
# 关键区别(要写进结论): 只改目录时，K8s 侧的成员资格随目录组走；
# Gateway 侧的**不**随目录组走 —— 它是按 subject 显式写进 Workspace 成员表的。
# 这不是缺陷，是两个系统对"成员"的定义不同(目录组 vs 资源成员表)。要统一，
# 就得有一个把目录组同步进 Workspace 成员的控制器(见结论的修正建议)。
echo "$GROUT" | grep -q "$WS_B" && ck C-04 "Gateway 侧成员资格随目录组自动变(与预期不符)" PASS "FAIL"  \
  || ck C-04 "Gateway 侧成员资格不随目录组自动变(需显式绑定)" PASS "PASS"
chg delete
reimport alice
sleep 3
$K -n identity wait --for=condition=complete job/kc-realm --timeout=300s >/dev/null 2>&1
echo "  目录已还原"

echo
echo "########## 5. 失败可观测(§五最后一项) ##########"
echo "  --- 拒绝有没有留下可查的记录"
echo "    gateway 日志里的拒绝记录(打印**原文**: 行数本身不能证明记的是哪一次拒绝)"
$K -n poc3-gateway logs p3-openshell-0 --tail=800 2>&1 | grep -iE "denied|denies|unauthor" | tail -4 | cut -c1-230 | sed 's/^/      /'
$K -n poc3-gateway logs p3-openshell-0 --tail=800 2>&1 | grep -icE "denied|denies|unauthor" | sed 's/^/      命中行数: /'
# ⚠ 这个镜像里**没有** sh/cat(exec: "sh": executable file not found)，所以不能 exec 进去数。
#    OCSF JSONL 写在 PVC 上，用一次性 Pod 挂同一个 PVC 去读。
$K -n poc3-gateway get pvc -o name 2>/dev/null | head -2 | sed 's/^/    PVC: /'
# ⚠ 这个镜像里**没有** sh(`/bin/sh: no such file`)，不能 exec 进 gateway 容器数行数。
#   OCSF JSONL 在 PVC 上 —— 用一个挂同一 PVC 的一次性 Pod 读。
#   ⚠ 也别用 `run --rm -i`: 容器一退出 attach 就失败
#     (`couldn't attach to pod …, falling back to streaming logs`)，只剩一句 warning，数字拿不到。
#     可用写法: run(不带 --rm) → wait → logs → delete。
$K -n poc3-gateway delete pod p3-ocsf-read --ignore-not-found >/dev/null 2>&1
$K -n poc3-gateway run p3-ocsf-read --image=busybox:1.36 --restart=Never --command -- sh -c 'sleep 1' \
  --overrides='{"spec":{"containers":[{"name":"p3-ocsf-read","image":"busybox:1.36","command":["sh","-c","ls -l /var/openshell/ | head -6; wc -l /var/openshell/*.jsonl 2>/dev/null || echo \"JSONL 不存在\""],"volumeMounts":[{"name":"d","mountPath":"/var/openshell"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"openshell-data-p3-openshell-0"}}]}}' >/dev/null 2>&1
$K -n poc3-gateway wait --for=condition=Ready pod/p3-ocsf-read --timeout=90s >/dev/null 2>&1
$K -n poc3-gateway logs p3-ocsf-read 2>&1 | sed 's/^/    /'
$K -n poc3-gateway delete pod p3-ocsf-read --ignore-not-found >/dev/null 2>&1
echo "  --- 配置写错时的报错(与\"策略没生效\"要能区分): 见 openshell3/gateway-oidc-values.yaml 里三处报错原文"
echo
echo "########## 汇总 ##########"
printf "  PASS=%d  FAIL=%d\n" $PASS_CNT $FAIL_CNT
