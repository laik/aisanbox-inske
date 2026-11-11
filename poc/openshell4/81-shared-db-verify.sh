#!/usr/bin/env bash
# POC4 验证矩阵: 两台 Deployment 形态的 Gateway(p4a / p4b)共用一套 PostgreSQL。
# 判定原则与 POC3 相同: 断言**跑着的东西**，每条用例都要能复现；不用 port-forward。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=${CTX:-kind-agent-runtime-poc}
K="kubectl --context $CTX"
CLI=vendor/openshell-cli-0.1.7/openshell
GWA=poc4-gw-a; GWB=poc4-gw-b; DB_NS=poc4-db; RT_NS=poc4-runtime
RA=p4a; RB=p4b
# ⚠ workspace 名字每次跑都不一样: 上一轮的 workspace 若还在 Terminating/create 会得到
#   ALREADY_EXISTS, 而 S-02 只看"B 可见"就会把**上一轮的状态**当成本轮成功(踩过)。
RUN=${RUN:-$(date +%H%M%S)}
WS=${WS:-p4-shared-$RUN}; SB=${SB:-p4-sb-$RUN}
OF=/tmp/p4oc.log
CA=identity/certs/issuer-ca.crt
# ⚠ sub 是目录里的 entryUUID —— 2026-11-11 LDAP 重建过，UUID 与 POC3 文档里的**不同**。
#   所以这里现场从 token 读，不抄常量(抄了就是"探针写错、结论全废"那一类)。
toksub() {
  local u=$1 t
  t=$(curl -s --cacert $CA -d grant_type=password -d client_id=openshell-cli \
        -d username=$u -d password=poc3pass -d scope=openid \
        "https://172.22.0.3:31443/realms/aisanbox/protocol/openid-connect/token" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
  echo "$t" | python3 -c 'import sys,base64,json
s=sys.stdin.read().split(".")
if len(s)<2: print(""); raise SystemExit
s=s[1]+"="*(-len(s[1])%4)
print(json.loads(base64.urlsafe_b64decode(s)).get("sub",""))'
}
SUB_ALICE=$(toksub alice); SUB_TADMIN=$(toksub tadmin)
echo "   alice sub=$SUB_ALICE  tadmin sub=$SUB_TADMIN"
PASS=0; FAIL=0
ck() { # ck <id> <desc> <expected> <actual>
  if [ "$3" = "$4" ]; then PASS=$((PASS+1)); printf "PASS %-5s %s\n" "$1" "$2"
  else FAIL=$((FAIL+1)); printf "FAIL %-5s %s\n         期望: %s\n         实际: %s\n" "$1" "$2" "$3" "$4"; fi
}
# ⚠ 不要把换行 tr 掉: WARN 与真正结果会并到同一行, grep -v WARN 就把整行(含结果)删了,
#   证据行全空 —— 上一版就是这么"看起来没输出"的。
OC() { local g=$1; shift; OPENSHELL_GATEWAY_INSECURE=true timeout 150 "$CLI" -g "$g" "$@" >"$OF" 2>&1; sed 's/\x1b\[[0-9;]*m//g' <"$OF"; }
wslist() { OC "$1" workspace list | grep -oE "$WS" | sort -u | tr '\n' ','; }
has()  { echo "$2" | grep -q  -- "$1"; }
hasi() { echo "$2" | grep -qi -- "$1"; }

echo "########## 0. 前置 ##########"
timeout 20 $K get deploy -n $GWA ${RA}-openshell >/dev/null 2>&1 || { echo "✗ 先跑 80-gateway-pg.sh"; exit 1; }
ls "$HOME/.config/openshell/gateways" | grep -q p4a-tadmin || { echo "✗ 先跑 82-cli-login.sh"; exit 1; }

echo "########## 1. 形态与存储(D) ##########"
D1=$($K -n $GWA get deploy ${RA}-openshell -o name 2>/dev/null | sed 's|.*/||'); ck D-01 "p4a 是 Deployment" "${RA}-openshell" "$D1"
D2=$($K -n $GWB get deploy ${RB}-openshell -o name 2>/dev/null | sed 's|.*/||'); ck D-02 "p4b 是 Deployment" "${RB}-openshell" "$D2"
D3=$($K -n $GWA get deploy ${RA}-openshell -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}'); ck D-03 "p4a 的 DB 走 Secret p4-db-uri" "p4-db-uri" "$D3"
D4=$($K -n $GWB get deploy ${RB}-openshell -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_DB_URL")].valueFrom.secretKeyRef.name}'); ck D-04 "p4b 的 DB 走同一个 Secret 名" "p4-db-uri" "$D4"
# 关键: 渲染出的启动参数里**没有** --db-url(sqlite 的入口)，否则 env 会被忽略
A1=$($K -n $GWA get deploy ${RA}-openshell -o jsonpath='{.spec.template.spec.containers[0].args[*]}'); has --db-url "$A1" && D5=has || D5=no
ck D-05 "p4a 的 args 不再有 --db-url(sqlite)" no "$D5"
A2=$($K -n $GWB get deploy ${RB}-openshell -o jsonpath='{.spec.template.spec.containers[0].args[*]}'); has --db-url "$A2" && D6=has || D6=no
ck D-06 "p4b 的 args 不再有 --db-url" no "$D6"
PGPOD=$($K -n $DB_NS get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
T=$($K -n $DB_NS exec "$PGPOD" -- psql -U openshell -d openshell -tAc "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d ' ')
case "${T:-0}" in ''|*[!0-9]*) T=0 ;; esac; [ "$T" -gt 0 ] && D7=yes || D7=no
ck D-07 "PostgreSQL 里有 gateway 建的表(${T:-0} 张)" yes "$D7"
# 不按 application_name 过滤: gateway 没设 application_name(实测恒为 0)。用"库里的会话数
# 减去本探针自己"来数, 更能说明"两台 gateway 真的各开了池"。
PODS=$($K -n $DB_NS exec "$PGPOD" -- psql -U openshell -d openshell -tAc "select count(*) from pg_stat_activity where datname='openshell' and pid <> pg_backend_pid()" 2>/dev/null | tr -d ' ')
echo "   PG 上 gateway 持有的连接数(不含本次 psql): ${PODS:-?}"

echo "########## 2. 两个 gateway 读到同一份状态(S) ##########"
# 清场(顺序: sandbox → provider → profile → workspace)。⚠ 只删 sandbox 不够:
#   workspace 里还有 provider/profile 时 delete 会被拒(实测原文:
#   "workspace '...' still contains resources: provider profile"), workspace 就卡在
#   Terminating; 下一轮 create 拿到 ALREADY_EXISTS, 后续 import/create 全部
#   FAILED_PRECONDITION —— 上一轮就是这样假 FAIL 的。
clean_ws() {
  local w=$1
  OC p4a-tadmin --workspace "$w" sandbox delete --all >/dev/null 2>&1
  OC p4a-tadmin --workspace "$w" provider delete p4-kek >/dev/null 2>&1
  OC p4a-tadmin --workspace "$w" profile delete poc4-kek >/dev/null 2>&1
  OC p4a-tadmin workspace delete "$w" >/dev/null 2>&1
}
for w in $WS p4-kek-ws; do clean_ws "$w"; done
for i in $(seq 1 30); do
  echo "$(OC p4a-tadmin workspace get "$WS")" | grep -q "workspace not" && break; sleep 2
done

S1A=$(OC p4a-tadmin whoami); S1B=$(OC p4b-tadmin whoami)
ck S-01 "tadmin 在两台 gateway 上身份相同(sub)" yes "$(has "$SUB_TADMIN" "$S1A" && has "$SUB_TADMIN" "$S1B" && echo yes || echo no)"

C1=$(OC p4a-tadmin workspace create --name $WS)
echo "   A 上创建 workspace 的返回: $(echo "$C1" | grep -v 'WARN openshell_sdk' | tr '\n' ' ' | cut -c1-160)"
ck S-02a "A 上真的创建了本轮的新 workspace" yes "$(has "Created workspace" "$C1" && echo yes || echo no)"
ck S-02 "A 上创建的 workspace 在 B 上可见" "$WS," "$(wslist p4b-tadmin)"
M1=$(OC p4a-tadmin workspace member add --workspace $WS --subject $SUB_ALICE --role user)
echo "   A 上加成员的返回: $(echo "$M1" | cut -c1-120)"
ck S-03 "A 上加的成员，alice 从 B 能看到 workspace" "$WS," "$(wslist p4b-alice)"
S4=$(OC p4a-alice --workspace $WS sandbox create --name $SB --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never)
echo "   A 上建 sandbox 的返回: $(echo "$S4" | grep -v 'WARN openshell_sdk' | tr '\n' ' ' | cut -c1-160)"
ck S-04a "A 上 alice 建 sandbox 成功(先证明本轮有对象)" yes "$(has "Created sandbox" "$S4" && echo yes || echo no)"
OK=no
for i in $(seq 1 45); do
  OC p4b-alice --workspace $WS sandbox list | grep -q "$SB" && { OK=yes; break; }; sleep 2
done
ck S-04 "A 上建的 sandbox 在 B 上可见" yes "$OK"
C2=$(OC p4b-tadmin workspace create --name $WS)
ck S-05 "B 上建同名 workspace 得到已存在" yes "$(has "already exists" "$C2" && echo yes || echo no)"
echo "   B 上的原文: $(echo "$C2" | cut -c1-140)"
B1=$(OC p4b-bob workspace list); B2=$(OC p4b-bob --workspace $WS sandbox list)
ck S-06 "非成员 bob 在 B 上看不到该 workspace" no "$(has "$WS" "$B1" && echo yes || echo no)"
ck S-07 "非成员 bob 在 B 上直接访问 workspace 被拒" yes "$(hasi "denied\|forbidden\|not.*member\|permission" "$B2" && echo yes || echo no)"
echo "   bob 访问的原文: $(echo "$B2" | cut -c1-160)"

echo "########## 3. 状态不在 pod 里(重启/重启后仍在) ##########"
$K -n $GWA delete pod -l app.kubernetes.io/instance=$RA >/dev/null 2>&1
$K -n $GWA rollout status deploy/${RA}-openshell --timeout=180s >/dev/null 2>&1
R1=$(wslist p4b-tadmin); R2=no
for i in $(seq 1 30); do OC p4b-alice --workspace $WS sandbox list | grep -q "$SB" && { R2=yes; break; }; sleep 2; done
ck S-08 "删掉 p4a 的 pod 后，B 仍能看到 workspace 和 sandbox" "$WS," "$R1"
ck S-09 "……且 sandbox 也还在" yes "$R2"
R3=no; for i in $(seq 1 30); do OC p4a-tadmin workspace list | grep -q "$WS" && { R3=yes; break; }; sleep 2; done
ck S-10 "p4a 重建后自己也能读回同一份状态" yes "$R3"

echo "########## 4. 负向对照: chart 的硬约束(证明不是我们少配了) ##########"
T1=$(helm template neg1 oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.7 \
  --set workload.kind=statefulset --set replicaCount=2 --set agentSandbox.preflight.enabled=false 2>&1)
ck S-11 "statefulset + 2 副本被 chart 拒绝" yes "$(has "cannot share the default per-pod SQLite database" "$T1" && echo yes || echo no)"
echo "   chart 原文: $(echo "$T1" | grep -m1 "cannot share" | cut -c1-160)"
T2=$(helm template neg2 oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.7 \
  --set workload.kind=deployment --set agentSandbox.preflight.enabled=false 2>&1)
ck S-12 "deployment 不给 externalDbSecret 被 chart 拒绝" yes "$(has "externalDbSecret" "$T2" && echo yes || echo no)"
echo "   chart 原文: $(echo "$T2" | grep -m1 -i "externalDbSecret" | cut -c1-160)"
T3=$(helm template pos oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.7 \
  --set workload.kind=deployment --set server.externalDbSecret=p4-db-uri --set agentSandbox.preflight.enabled=false 2>&1)
ck S-13 "正向: deployment + externalDbSecret 能渲染出 OPENSHELL_DB_URL" yes "$(has "OPENSHELL_DB_URL" "$T3" && echo yes || echo no)"
ck S-14 "……且渲染结果里没有 --db-url(sqlite)" no "$(has --db-url "$T3" && echo yes || echo no)"

echo "########## 5. 同一 release 两副本(HA) ##########"
helm --kube-context $CTX upgrade $RA oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.7 --namespace $GWA --reuse-values --set replicaCount=2 --timeout 5m --wait >/tmp/p4-scale.log 2>&1
RC=$?
ck S-15 "p4a helm upgrade 到 2 副本成功" 0 "$RC"
[ $RC -ne 0 ] && tail -3 /tmp/p4-scale.log | sed 's/^/   /'
N=0; for i in $(seq 1 40); do N=$($K -n $GWA get pod -l app.kubernetes.io/instance=$RA --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "$N" = 2 ] && break; sleep 3; done
ck S-16 "p4a 两个副本都 Running" 2 "$N"
# 杀掉其中一个: NodePort 只把流量给 Ready 的端点，剩下的那个要能继续服务
VICTIM=$($K -n $GWA get pod -l app.kubernetes.io/instance=$RA -o jsonpath='{.items[0].metadata.name}')
$K -n $GWA delete pod "$VICTIM" >/dev/null 2>&1
OKC=0; for i in $(seq 1 10); do OC p4a-tadmin workspace list | grep -q "$WS" && OKC=$((OKC+1)); sleep 1; done
ck S-17 "杀掉 1 个副本后，连续 10 次调用仍成功(另一副本在服务)" 10 "$OKC"
for i in $(seq 1 40); do N=$($K -n $GWA get pod -l app.kubernetes.io/instance=$RA --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '); [ "$N" = 2 ] && break; sleep 3; done
ck S-18 "被杀副本自动补回到 2" 2 "$N"

echo "########## 6. 共库时的凭据(K) ##########"
# ⚠ OpenShell **不把任何 provider profile 编进发行版**(README §10 第 6 条)，
#   所以 provider create --type openai 必然报 "provider profile 'openai' not found"(实测)。
#   这里导入一个最小自定义 profile，让凭据真的写进库里。
cat > /tmp/p4-prof.yaml <<'YAML'
id: poc4-kek
display_name: POC4 KEK probe
credentials:
  - name: API_KEY
    required: true
YAML
IMP=$(OC p4a-tadmin --workspace $WS profile import -f /tmp/p4-prof.yaml)
echo "   profile import: $(echo "$IMP" | cut -c1-120)"
ck K-01 "A 上导入自定义 provider profile" yes "$(has "Imported 1" "$IMP" && echo yes || echo no)"
# ⚠ 不要在外层再重定向: OC 自己把 stdout+stderr 落到 $OF, 外层 >file 只会得到空文件
#   (第一次跑就是在这里假 FAIL 的)。
P1=$(API_KEY=sk-poc4-KEK-probe OC p4a-tadmin --workspace $WS provider create \
  --name p4-kek --type poc4-kek --credential API_KEY)
K1=$(has "Created provider" "$P1" && echo yes || echo no)
ck K-02a "A 上创建 provider 成功" yes "$K1"
echo "   A 上的原文: $(echo "$P1" | grep -v 'WARN openshell_sdk' | tr '\n' ' ' | cut -c1-160)"
# "写进 PG" 要直接查库, 不能只看 CLI 返回。
KROW=$($K -n $DB_NS exec "$PGPOD" -- psql -U openshell -d openshell -tAc \
  "select count(*) from objects where object_type='provider' and name='p4-kek' and workspace='$WS'" 2>/dev/null | tr -d ' ')
ck K-02 "PG 的 objects 表里有这条 provider(workspace=$WS)" 1 "${KROW:-0}"
# "同一条 id": A 与 B 各 get 一次, 比 Id
GA=$(OC p4a-tadmin --workspace $WS provider get p4-kek)
G1=$(OC p4b-tadmin --workspace $WS provider get p4-kek)
IDA=$(echo "$GA" | grep -oE 'Id: [0-9a-f-]{36}' | head -1 | cut -d' ' -f2)
IDB=$(echo "$G1" | grep -oE 'Id: [0-9a-f-]{36}' | head -1 | cut -d' ' -f2)
ck K-03 "B 读到的 provider 与 A 是同一条 id" "$IDA" "$IDB"
echo "   A/B 的 id: ${IDA:-?} / ${IDB:-?}"
echo "   B 上 get 的原文: $(echo "$G1" | grep -v 'WARN openshell_sdk' | tr '\n' ' ' | cut -c1-200)"
# KEK 必须两台一致 —— 这是 chart 的设计(credentials 以 AES-256-GCM 加密，KEK 是 per-release Secret)。
# 两个 release 共库时如果用默认(各自生成)的 KEK，B 就解不开 A 写的密文。这里断言的是**配置**:
REF_A=$($K -n $GWA get deploy ${RA}-openshell -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY")].valueFrom.secretKeyRef.name}')
REF_B=$($K -n $GWB get deploy ${RB}-openshell -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY")].valueFrom.secretKeyRef.name}')
ck K-04 "两台的 KEK 都引用同一个显式 Secret" "p4-credential-kek|p4-credential-kek" "$REF_A|$REF_B"
VAL_A=$($K -n $GWA get secret p4-credential-kek -o jsonpath='{.data.key-encryption-key}')
VAL_B=$($K -n $GWB get secret p4-credential-kek -o jsonpath='{.data.key-encryption-key}')
ck K-05 "两个 ns 里的 KEK 值逐字节相同" yes "$([ "$VAL_A" = "$VAL_B" ] && echo yes || echo no)"
# ⚠ 实测边界(写在报告里，不在这里伪造用例): provider get 只返回元数据，不触发解密 ——
#   POC 里把 B 的 KEK 换成另一个值并重启后，get 仍然成功；沙箱 create --provider 也没能
#   构造出"解密失败"的可观测面(最小 profile 没有 env 注入)。所以"KEK 不同 ⇒ 凭据不可用"
#   只到 chart 源码/注释层面，本矩阵不给它记 PASS。

echo "########## 7. 清理 ##########"
for w in $WS p4-kek-ws; do clean_ws "$w"; done
echo
echo "########## PASS=$PASS FAIL=$FAIL ##########"
[ $FAIL -eq 0 ] || exit 1
