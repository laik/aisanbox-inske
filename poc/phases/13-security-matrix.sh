#!/usr/bin/env bash
# Phase 13 —— 安全测试矩阵 (POC2 §11, 补齐 SEC-04 / SEC-06 / SEC-07 / SEC-08 / SEC-12 / SEC-13)
# 手工重现: bash poc/phases/13-security-matrix.sh
#
# 这份脚本只做**上一轮没做**的五条；SEC-01/02/03/05/09/10/11/14 已在
# 03-netpol-verify.sh / 05-gatekeeper.sh / 09-resource-admission.sh / 11-pi-scenario.sh 里跑过，
# 这里只做**汇总核对**，不重复实现。
#
# ===== 本轮(2026-11-09)实测结论，先写在这里 =====
# ⚠ **SEC-04 / SEC-08 的"跨租户被拒"不是 Capsule/Antrea 的租户隔离做出来的**，
#   而是 OpenShell 自己生成的 NetworkPolicy 顺带做到的。两个实测事实:
#   (1) Capsule 的 `spec.networkPolicies` 是**空的** —— 平台没有下发任何租户级 NetworkPolicy;
#   (2) 两个**普通 Pod**(不是 OpenShell 沙箱)跨租户互相 **REACHED**:
#         tenant-a/p-a -> tenant-b/p-b :8080  = REACHED
#   而 OpenShell 沙箱跨租户/跨 namespace 是 TIMEOUT，原因是它自己给每个边界对(pair)建了策略:
#         openshell-sandbox-workloads:  podSelector=boundary-role=workload, Ingress/Egress 都限
#         os-control-<boundary-pair>:   只允许到**同一个 boundary-pair** 的 supervisor:5500
#   → 报告里必须这样写: **"Agent 无法绕过 Supervisor 直接访问网络"这条(POC-05/§9.1)成立，
#     但"租户之间的网络隔离"目前是靠 OpenShell 的执行边界顺带实现的，不是平台的租户网络策略。**
#     平台如果只跑普通 Pod(或换掉 OpenShell)，这条就不存在 —— 要补 Capsule networkPolicies
#     或 Antrea ClusterNetworkPolicy。这是 POC2 §9 与 §11 混在一起的两件事，要拆开。
# ⚠ SEC-12 的"fail-closed"要看清是哪一段的链路: 沙箱 Pod 的**唯一**出网路径是自己的 supervisor
#   (os-control-<pair> 的 egress 只到它)，而 supervisor 的 egress 是**全开**(Egress 无 to)。
#   实测(见下面 SEC-12 一节，方法也在那里): Gateway 缩到 0 的窗口里 agent **仍然连续拿到模型回复**
#   —— "断链 fail-closed"只对**依赖 gateway 控制面**的操作(建/改沙箱)成立，不对数据面成立。
#   ⚠ 这条最容易测错，因为**两条 exec 通道都会骗人**: `openshell sandbox exec` 自己走 Gateway
#   (一断就 transport error，看着像数据面也断了)，而 `kubectl exec` 的环境不完整(没有注入的
#   provider 占位符与 supervisor CA，pi 会说"没有模型"，不是"网络不通")。测法见该节注释。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime   # ⚠ 这个脚本开了 `set -u`: 用到 $NS 的段落必须它在头部定义过(之前只写 -n tenant-a-runtime 字面量)
CLI=vendor/openshell-cli-0.1.7/openshell
WS=poc-shared
A() { $CLI -g poc2-a --workspace $WS "$@"; }
# wait_ready <sandbox-name> [秒] —— 固定 sleep 30/45 不够(镜像拉取、配额排队都会更久)，
# 而没就绪就 exec 会得到 `Error: × … sandbox not found`，看起来像功能失败。
wait_ready() {
  local n=$1 t=${2:-150} e=0
  while [ $e -lt "$t" ]; do
    # ⚠ 不要用 "^$n$" 匹配: `sandbox list` 的列是**空格补齐**的，行尾有空白，锚到行尾永远不匹配
    #    (实测: 明明列出来是 Ready，wait_ready 却等到超时)。名字后面跟一个空白才是对的。
    if A sandbox list 2>&1 | awk '$4=="Ready"' | grep -q "^$n[[:space:]]"; then return 0; fi
    sleep 10; e=$((e+10))
  done
  echo "       ⚠ $n 在 ${t}s 内没到 Ready。先查配额(每个沙箱 = **2 个 Service + 1 个 PVC**):"
  printf "         "; kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
    -o jsonpath='{"services "}{.status.used.count/services}{"/"}{.spec.hard.count/services}{"  pods "}{.status.used.count/pods}{"/"}{.spec.hard.count/pods}{"  pvc "}{.status.used.persistentvolumeclaims}{"/"}{.spec.hard.persistentvolumeclaims}{"  storage "}{.status.used.requests.storage}{"/"}{.spec.hard.requests.storage}{"\n"}'
  return 1
}
RO='{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"shared-workspace","read_only":true}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":true}]}}}}'
RW='{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"shared-workspace","read_only":false}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":false}]}}}}'

# PF —— 建(或重建)到 Gateway 的端口转发。CLI 只走 mTLS，且必须是 127.0.0.1:18441。
# ⚠ 同一时间只跑一个 phases 脚本：它们共用同一个 Gateway 与同一份租户配额，并行时配额被双倍消耗，
#    SEC-12 的计数也不再可信(2026-11-09: 一条断线 SSH 留下的孤儿进程与新一轮并行，整段作废)。
#    这里只**提醒**不硬停，因为匹配到的也可能是启动本脚本的那条命令本身。
if [ "$(pgrep -cf 'phases/[0-9][0-9]-')" -gt 1 ]; then
  echo "### ⚠ 看起来有别的 phases 脚本在跑 —— 它们共用 Gateway 与配额，结果会不可信。"
  pgrep -af 'phases/[0-9][0-9]-' | sed 's/^/     /'
  echo "     要先停: pkill -f 'phases/'  然后重跑本脚本。"
fi

PF() {
  pkill -f 'svc/os-a-openshell 1844' >/dev/null 2>&1
  (setsid kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 </dev/null >/tmp/pf-a.log 2>&1 &)
  sleep 4
}
PF

echo "### 前置: 复用 11-pi-scenario.sh 的共享 PVC；Developer/Reviewer 缺了**自己重建**"
# 先把**本脚本上次**留下的探针清掉: 它们每个占 2 个 Service，攒两轮就撞满配额，
# 之后所有 create 都静默失败，症状是 `sandbox not found`(2026-11-09 踩过)。
# 这里的删除**允许**静默失败: 它们后面都紧跟一个 create，真没删掉就会在 create 处报明确的配额错。
# (文末 SEC-12 的收尾删除**不能**静默 —— 它后面没有 create 会替它报错，见那里。)
for s in sec-polonly sec-mtonly sec12-gw-down sec12-loop; do A sandbox delete "$s" >/dev/null 2>&1; done

# ⚠ PHASE 是第 4 列: CREATED 打印的是 "2026-11-09 06:28:21"，日期和时间被空格分成两列。
#    写成 $2/$3 会永远匹配不到，脚本看起来像"前置没跑"，实际是列号错(2026-11-09 踩过两次)。
# ⚠ pi-dev 的 keepalive 是 sleep 3600 —— **一小时后它就变 Completed**，而 Completed 的沙箱
#    exec 直接报 `sandbox ... is not ready (phase: Completed)`。隔天手工复验必然撞上这条。
#    所以这里不是"没跑过 11 就退出"，而是**自己重建**(共享 PVC 里的代码是持久的，那才是被测对象)。
mkdir -p /tmp/pol
sed -n '/^version:/,$p' policies/pi-developer.yaml > /tmp/pol/dev.yaml
sed -n '/^version:/,$p' policies/pi-reviewer.yaml  > /tmp/pol/rev.yaml
DC() { printf '{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"%s","read_only":%s}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":%s}]}}}}' "$1" "$2" "$2"; }
kubectl --context $CTX -n $NS apply -f storage/workspace-pvc.yaml >/dev/null 2>&1
ready() { A sandbox list 2>&1 | awk '$4=="Ready"' | grep -q "^$1[[:space:]]"; }
if ! ready pi-dev; then
  echo "   pi-dev 不在(或已 Completed) —— 按 11 号脚本 §2 的参数重建:"
  A sandbox delete pi-dev >/dev/null 2>&1; sleep 10
  A sandbox create --name pi-dev --from pi-agent:poc --cpu 500m --memory 1Gi --detach --restart-policy never \
    --policy /tmp/pol/dev.yaml --provider poc-model --provider poc-git \
    --driver-config-json "$(DC shared-workspace false)" -- sh -c 'sleep 3600' >/dev/null 2>&1
  wait_ready pi-dev 240
fi
A sandbox list 2>&1 | awk 'NR==1||/^pi-|^sec-/{print "   "$1" "$4}'
if ! ready pi-dev; then
  echo "   ✗ 重建 pi-dev 失败。最常见的原因是**配额**: 每个沙箱占 2 个 Service，"
  echo "     撞满 count/services 时 create 只报错、不给原因。先看:"
  printf "       "; kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
    -o jsonpath='{.status.used.count/services}{"/"}{.spec.hard.count/services}{"  pods="}{.status.used.count/pods}{"/"}{.spec.hard.count/pods}{"\n"}'
  echo "     清理: 对 sandbox list 里**每一个**(含 Completed)执行 sandbox delete。"
  exit 1
fi

# Reviewer 由本脚本自己建: 11 号脚本结束时会把它们删掉(那是它 §7 的断言本身)。
for r in 1 2; do
  if ! A sandbox list 2>&1 | awk '$4=="Ready"' | grep -q "^pi-review-$r"; then
    # 先 delete: 同名但已经 Completed 的沙箱会占着名字和 2 个 Service，create 会静默失败。
    A sandbox delete "pi-review-$r" >/dev/null 2>&1; sleep 8
    A sandbox create --name "pi-review-$r" --from pi-agent:poc --cpu 500m --memory 1Gi --detach \
      --restart-policy never --policy /tmp/pol/rev.yaml --provider poc-model \
      --driver-config-json "$RO" -- sh -c 'sleep 3600' >/dev/null 2>&1
    # ⚠ keepalive 要明显长于这个矩阵自己的耗时: 用 sleep 900 时 pi-review-1 在 SEC-06
    #   之前就变成 Completed，报 `sandbox 'pi-review-1' is not ready (phase: Completed)`。
    #   这不是功能问题，是脚本自己把被测对象跑到期了。
  fi
done
for r in 1 2; do wait_ready "pi-review-$r" 240; done
echo "   为 SEC-06/07 建的 Reviewer:"
A sandbox list 2>&1 | awk 'NR==1||/^pi-/{print "   "$1" "$4}'
echo "   共享 PVC 里 Developer 的改动仍在(11 号脚本留下的，本脚本不重新 clone):"
A sandbox exec pi-dev -- sh -c 'cd /data/workspace/godotenv 2>/dev/null && git status --short && wc -l poc_extra_test.go' 2>&1 | sed 's/^/     /' 

# ---------------------------------------------------------------------------
echo
echo "### SEC-04 / SEC-08: 跨租户 —— 先把**归因**做对(见文件头 ⚠)"
echo "   (a) 平台有没有下发租户级 NetworkPolicy:"
for t in a b; do
  printf "       Capsule Tenant tenant-%s 的 spec.networkPolicies: " "$t"
  kubectl --context $CTX get tenant "tenant-$t" -o jsonpath='{.spec.networkPolicies}' | grep -q . \
    && echo "有配置" || echo "空 ← 平台没有做租户网络隔离"
done
echo "   (b) 两个普通 Pod 跨租户互访(不是沙箱):"
# ⚠ 两个坑叠在同一条测试上，2026-11-09 各踩一次，都会给出**假的"隔离生效"**:
#   (1) 目标 Pod **必须在被测端口上真有监听**。没有 listener 时 `nc -z` 一定失败，
#       得到的 NOT_REACHED 是"没人监听"，不是"被 NetworkPolicy 拦"。
#   (2) **busybox 的 `nc -l` 只服务一条连接就退出**(`-k` 在 alpine 的 busybox 里不可靠)。
#       所以"先自证在监听"这一步会**自己把 listener 用掉**，下一条跨租户测试必然失败 ——
#       实测就是这样得到过与上一轮相反的结论。正确写法是 `while true; do nc -l …; done`，
#       并且自证只打到 127.0.0.1、放在跨租户测试**之后**再确认 Pod 还活着。
LISTEN_CMD='while true; do nc -l -p 8080 </dev/null; done'
kubectl --context $CTX -n tenant-b-runtime run sec-pb --image=alpine:latest --restart=Never --command -- sh -c "$LISTEN_CMD" >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime run sec-pa --image=alpine:latest --restart=Never --command -- sleep 300 >/dev/null 2>&1
kubectl --context $CTX -n tenant-b-runtime wait --for=condition=Ready pod/sec-pb --timeout=90s >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime wait --for=condition=Ready pod/sec-pa --timeout=90s >/dev/null 2>&1
BIP=$(kubectl --context $CTX -n tenant-b-runtime get pod sec-pb -o jsonpath='{.status.podIP}')
printf "       tenant-a 普通 Pod -> tenant-b 普通 Pod(:8080): "
kubectl --context $CTX -n tenant-a-runtime exec sec-pa -- sh -c "timeout 8 nc -z -w5 $BIP 8080 && echo 'REACHED  <== 平台层没有隔离' || echo NOT_REACHED" 2>&1 | tail -1
echo "   (b+) 自证 listener 确实活着(放在跨租户测试**之后**，且只打 127.0.0.1):"
printf "       tenant-b 自己 -> 127.0.0.1:8080: "
kubectl --context $CTX -n tenant-b-runtime exec sec-pb -- sh -c "nc -z -w3 127.0.0.1 8080 && echo LISTENING || echo NO_LISTENER" 2>&1 | tail -1
echo "       ↑ 若这里是 LISTENING 而 (b) 是 REACHED，则跨租户在平台层**没有**隔离。"
echo "   (c) OpenShell 沙箱跨租户/跨 namespace:"
kubectl --context $CTX -n tenant-b-runtime delete pod sec-pb --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime run sec-pb2 --image=alpine:latest --restart=Never --command -- sh -c "$LISTEN_CMD" >/dev/null 2>&1
kubectl --context $CTX -n tenant-a-runtime wait --for=condition=Ready pod/sec-pb2 --timeout=90s >/dev/null 2>&1
PB2=$(kubectl --context $CTX -n tenant-a-runtime get pod sec-pb2 -o jsonpath='{.status.podIP}')
# ⚠ 目标端口要和上面一样是**有监听的 8080**。打到没人监听的 :80 上，
#   "连不上"就说不清是边界拦的还是根本没服务。
printf "       沙箱(pi-review-2) -> 同 ns 的普通 Pod(:8080): "
A sandbox exec pi-review-2 -- sh -c "timeout 8 curl -s -m 6 -o /dev/null -w '%{http_code}\n' http://$PB2:8080/ 2>/dev/null || echo TIMEOUT" 2>&1 | tail -1
printf "       沙箱(pi-review-2) -> tenant-b 的 gateway: "
A sandbox exec pi-review-2 -- sh -c 'timeout 8 curl -s -m 6 -o /dev/null -w "%{http_code}\n" https://os-b-openshell.tenant-b-gateway.svc.cluster.local:8080/ 2>/dev/null || echo TIMEOUT' 2>&1 | tail -1
echo "   (d) 谁做的拒绝 —— OpenShell 自己生成的 NetworkPolicy(注意 boundary-pair 的粒度):"
kubectl --context $CTX -n tenant-a-runtime get netpol --no-headers | awk '{print "       "$1}' | head -8
# ⚠ 不要只打印 openshell-sandbox-workloads 的 .spec.egress —— 它**根本没有 egress 规则**，
#   所以这一列永远空，看起来像证据没取到。真正的机制是两条策略**相加**:
#     openshell-sandbox-workloads: policyTypes=[Ingress,Egress] 但只定义 ingress
#                                  => 它自己把 workload 的出网**全 deny**(声明了 Egress 却没有规则)
#     os-control-<pair>:           唯一放行的 egress = **同一个 boundary-pair 的 supervisor:5500**
#   两条合起来 = workload 只能到自己的 supervisor:5500。下面按这个把证据取全。
kubectl --context $CTX -n tenant-a-runtime get netpol openshell-sandbox-workloads \
  -o jsonpath='       workloads 策略: policyTypes={.spec.policyTypes} egress={.spec.egress} <== 空但 Egress 已受管 = 出网全 deny | ingress={.spec.ingress}{"\n"}'
CN=$(kubectl --context $CTX -n tenant-a-runtime get netpol --no-headers | awk '/^os-control-/{print $1; exit}')
# ⚠ jsonpath 里的 `{"\n"}` 必须整段待在**单引号**里。写成 "$CN: … {"\n"}" 时 shell 先把内层双引号吃掉，
#   jsonpath 收到的是 `{n}` → `Error executing template: unrecognized identifier n`(实测踩过)。
#   需要打印变量名就先 echo 打，再把 jsonpath 整段单引号。
echo "       $CN:"
kubectl --context $CTX -n tenant-a-runtime get netpol "$CN" \
  -o 'jsonpath=         唯一放行的 egress -> {.spec.egress[0].to[0].podSelector.matchLabels} port={.spec.egress[0].ports[0].port}{"\n"}'
kubectl --context $CTX -n tenant-a-runtime get netpol "$CN" \
  -o 'jsonpath=         podSelector={.spec.podSelector.matchLabels}{"\n"}'
echo "       ↑ 两条策略相加 = workload 的出网只有**自己那个 supervisor:5500**。这就是 POC-05「不能绕过 Supervisor」的实现机制。"
kubectl --context $CTX -n tenant-a-runtime delete pod sec-pa sec-pb2 --ignore-not-found >/dev/null 2>&1
echo "   ⚠ 结论措辞: POC-05/§9.1「Agent 不能绕过 Supervisor 出网」**成立**(上面 (c) 两条都连不上，
      而它连自己 supervisor 是通的 —— 见 11 号脚本里的模型调用)。
      「租户之间网络隔离」**不是**平台能力，是 OpenShell 边界的副作用。两者要分开写。"

# ---------------------------------------------------------------------------
echo
echo "### SEC-06 / SEC-07: 读写分权要**分别**指认是哪一层(POC2 §10.5: 不能只看 YAML)"
# ⚠ 挂载标志**不要按固定列号打印**。/proc/self/mountinfo 里字段 4 是"挂载根"、
#   字段 5 是挂载点、字段 6 才是挂载选项，而且中间可能有 shared:/master: 这类可选字段。
#   实测坑: 写 awk '{print $4}' 时 dev 和 reviewer 都打印 "/"，两种情况一模一样，
#   这一列证据等于没测。下面的 awk 是"找到挂载点那一列，打印它的下一列"。
#   实测输出: reviewer 侧 mount_flags=ro,relatime；dev 侧 mount_flags=rw,relatime。
echo "   (a) SEC-07 Developer 写共享文件:"
A sandbox exec pi-dev -- sh -c 'touch /data/workspace/sec07 && echo "       DEV_WRITE_OK"; grep "/data/workspace" /proc/self/mountinfo | awk "{for(i=1;i<=NF;i++) if(\$i==\"/data/workspace\"){print \"mount_flags=\" \$(i+1); break}}"'
echo "   (b) SEC-06 Reviewer 写共享文件 —— 挂载 ro + 策略 ro(两层都关):"
A sandbox exec pi-review-1 -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{for(i=1;i<=NF;i++) if(\$i==\"/data/workspace\"){print \"mount_flags=\" \$(i+1); break}}"; touch /data/workspace/sec06 2>&1 | sed "s/^/       /"'
# (b) 已经用完两个 Reviewer。**在这里回收它们** —— 它们继续占 4 个 Service + 2 个 PVC，
# 而 (c)(d) 还要再建两个对照沙箱。租户配额里 `persistentvolumeclaims` 与 `count/services`
# 都会先撞满，撞满时 create **只报错、不给原因**，症状是 `sandbox not found`。
# (要重测 Reviewer: 本脚本开头会自己重建，不用手工做。)
echo "   (b2) 回收 Reviewer，给对照沙箱腾配额(每个沙箱 = 2 Service + 1 PVC):"
A sandbox list 2>&1 | awk 'NR==1||/^(pi|sec)/{printf "       回收前: %s %s\n",$1,$4}'
for r in 1 2; do A sandbox delete "pi-review-$r" >/dev/null 2>&1; done
sleep 10
echo "   (c) 只有**策略**关、挂载可写(证明 OpenShell 这一层独立生效):"
A sandbox create --name sec-polonly --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /tmp/pol/rev.yaml --driver-config-json "$RW" -- sh -c 'sleep 300' >/dev/null 2>&1
wait_ready sec-polonly 180
A sandbox exec sec-polonly -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{for(i=1;i<=NF;i++) if(\$i==\"/data/workspace\"){print \"mount_flags=\" \$(i+1); break}}"; touch /data/workspace/sec06 2>&1 | sed "s/^/       /"'
echo "       ↑ mountinfo 是 rw，写仍被拒(errno EACCES / Permission denied) => 拒绝来自 OpenShell 策略层"
echo "   (d) 只有**挂载**关、策略可写(对照，errno 不同):"
A sandbox create --name sec-mtonly --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /tmp/pol/dev.yaml --driver-config-json "$RO" -- sh -c 'sleep 300' >/dev/null 2>&1
wait_ready sec-mtonly 180
A sandbox exec sec-mtonly -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{for(i=1;i<=NF;i++) if(\$i==\"/data/workspace\"){print \"mount_flags=\" \$(i+1); break}}"; touch /data/workspace/x 2>&1 | sed "s/^/       /"'
echo "       ↑ errno 是 EROFS(Read-only file system) —— 与 (c) 的 EACCES 不同，
         说明这是**两条独立的强制链**，不是一条策略的两种写法。生产上两条都要留。"
A sandbox delete sec-polonly sec-mtonly >/dev/null 2>&1

# ---------------------------------------------------------------------------
echo
echo "### SEC-12: Supervisor ↔ Gateway 断链 —— 分清控制面与数据面"
# ===== 这一条踩过四个坑，都会给出**假结论**，按踩到顺序记在这里 =====
# 1) **不要用 NetworkPolicy 当"断链"**。sec12-cut 那种写法掐的是 supervisor 的出网，
#    与"supervisor ↔ Gateway 断链"不是同一件事，测出来的东西自相矛盾。
#    正确做法: 把 **StatefulSet** os-a-openshell 缩到 0(它是 StatefulSet，
#    `scale deployment/...` 会报 `Error from server (NotFound)`)。
# 2) **数据面不能用 `openshell sandbox exec` 测**。这条 exec 通道自己走 Gateway:
#    Gateway 一缩到 0，它必然报 `Error: × connect error: transport error` ——
#    那是**CLI 的通道断了**，不是数据面断了。用它测会得到"数据面也 fail-closed"的假结论。
# 3) **`kubectl exec` 的环境是不完整的**: 注入的 `OPENAI_API_KEY`(占位符)和
#    supervisor CA(SSL_CERT_FILE / CURL_CA_BUNDLE / NODE_EXTRA_CA_CERTS)只在 agent 的
#    登录环境里有。直接 `kubectl exec` 跑 pi 会得到
#    `providers.poc-model.apiKey: must not have fewer than 1 characters` + `No models available` ——
#    那是**没有模型**，不是**网络不通**。要先 export 占位符，**再**跑 setup-agent-home.sh
#    (models.json 是它生成的，顺序反了 key 就是空的)。
# 4) **Sandbox CR 的真名是 `<workspace>--<name>`**(如 poc-shared--gw-q)，不是 `<name>`。
#    按 `get sandbox gw-q` 查会得到 NotFound，把一次**成功的**创建读成失败的。
# 被测对象自己建: pi-dev/pi-review-* 的 keepalive 会到期(phase=Completed 后 exec 直接报错),
# 复验时不要把结论挂在它们的寿命上。这个沙箱带 poc-model provider —— 数据面要用真实模型调用。
if ! A sandbox list 2>&1 | awk '$4=="Ready"' | grep -q "^sec12-loop[[:space:]]"; then
  A sandbox delete sec12-loop >/dev/null 2>&1; sleep 8
  A sandbox create --name sec12-loop --from pi-agent:poc --cpu 500m --memory 1Gi --detach \
    --restart-policy never --provider poc-model -- sh -c 'sleep 3600' >/dev/null 2>&1
  wait_ready sec12-loop 240
fi
POD=poc-shared--sec12-loop
kubectl --context $CTX -n $NS get pod $POD -o jsonpath='   pod={.metadata.name} phase={.status.phase} node={.spec.nodeName}{"\n"}'
PAIR=$(kubectl --context $CTX -n $NS get pod $POD -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair}')
SP=os-supervisor-$PAIR
echo "   这个沙箱的边界: boundary-pair=$PAIR  supervisor=$SP"
echo "   ⚠ 每个沙箱占 **2 个 Service**(os-boundary-* + os-supervisor-*)。复验前先跑 sandbox list 清场:"
echo "     撞满 count/services 时 create 只报错、不给原因，看上去像平台坏了(2026-11-09 踩过)。"
echo "   (a) 在沙箱里起一个**自循环的模型调用**(只在 Gateway 在的时候启动一次):"
A sandbox exec sec12-loop -- sh -c 'sh /usr/local/pi/setup-agent-home.sh >/dev/null 2>&1; . /tmp/pi-home.env
  rm -f /tmp/sec12-loop.log
  setsid sh -c "i=0; while [ \$i -lt 60 ]; do i=\$((i+1)); printf \"== try %s %s\\n\" \"\$i\" \"\$(date -u +%T)\">> /tmp/sec12-loop.log; timeout 90 pi --model poc-model/qwen3.8-flash-next -p \"Reply with exactly the token DATA_PLANE_OK\" </dev/null >> /tmp/sec12-loop.log 2>&1; sleep 20; done" >/dev/null 2>&1 &
  sleep 2; echo "     LOOP_STARTED"'
sleep 70
READ='grep -c DATA_PLANE_OK /tmp/sec12-loop.log | sed "s/^/       agent 自己拿到 DATA_PLANE_OK 的次数: /"; tail -3 /tmp/sec12-loop.log | sed "s/^/       /"'
echo "   (b) BASELINE(gateway 在)。读结果用 **kubectl exec**(走 apiserver，与 Gateway 无关):"
kubectl --context $CTX -n $NS exec $POD -c agent -- sh -c "$READ"
echo "   (c) 断链: StatefulSet 缩到 0(不是 netpol、不是 Deployment)"
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=0 >/dev/null; sleep 30
echo "       gateway pods: $(kubectl --context $CTX -n tenant-a-gateway get pods --no-headers --ignore-not-found | wc -l | tr -d ' ')"
echo "       supervisor **自己**到 Gateway 的链路(它确实察觉了):"
kubectl --context $CTX -n $NS logs $SP --tail=120 2>/dev/null | grep "os-a-openshell" | tail -2 | sed 's/^/         /'
echo "       supervisor 的出网策略(为什么数据面不断):"
kubectl --context $CTX -n $NS get netpol openshell-sandbox-supervisors \
  -o jsonpath='         policyTypes={.spec.policyTypes} egress={.spec.egress}   <== 全开{"\n"}'
echo "       (d) 数据面 —— 断链窗口内读同一个文件:"
kubectl --context $CTX -n $NS exec $POD -c agent -- sh -c "$READ"
sleep 100; echo "       100s 之后:"
kubectl --context $CTX -n $NS exec $POD -c agent -- sh -c "$READ"
echo "       对照: 用 CLI exec 读**同一个文件** -> $(A sandbox exec sec12-loop -- cat /tmp/sec12-loop.log 2>&1 | sed '/^[[:space:]]*$/d' | tail -1)  <== 这是 CLI 通道断了，不是数据面"
echo "       (e) 控制面 —— 依赖 Gateway 的操作应当失败:"
timeout 90 $CLI -g poc2-a --workspace $WS sandbox create --name sec12-gw-down --from alpine:latest \
  --cpu 50m --memory 64Mi --detach --restart-policy never -- 'sleep 20' 2>&1 \
  | sed '/^[[:space:]]*$/d' | tail -1 | sed 's/^/         /'   # ⚠ 必须先删空行: CLI 的报错以换行结尾，
                                                              #    tail -1 直接取会打印一行空白，看着像"没报错" 
echo "         含 sec12-gw-down 的 Sandbox CR: $(kubectl --context $CTX -n $NS get sandboxes.agents.x-k8s.io --no-headers 2>&1 | grep -c sec12-gw-down)  <== 0 = 控制面 fail-closed"
echo "   (f) 恢复:"
kubectl --context $CTX -n tenant-a-gateway scale statefulset/os-a-openshell --replicas=1 >/dev/null
kubectl --context $CTX -n tenant-a-gateway rollout status statefulset/os-a-openshell --timeout=240s >/dev/null 2>&1; sleep 30
kubectl --context $CTX -n $NS logs $SP --tail=120 2>/dev/null | grep "os-a-openshell" | tail -1 | sed 's/^/         supervisor 重连: /'
kubectl --context $CTX -n $NS exec $POD -c agent -- sh -c "$READ"
kubectl --context $CTX -n $NS exec $POD -c agent -- pkill -f "while \[ \$i" >/dev/null 2>&1
# ⚠ 必须**重建**端口转发再收尾: 把 Gateway 缩到 0 会把它底下那条 port-forward 一起带走，
#    于是恢复后的 `sandbox delete` 只会得到 transport error —— 实测(sec12-loop)因此一直没删掉，
#    白占 2 个 Service 配额，下一轮 create 就撞配额。收尾用的删除**不要**把 stderr 丢掉。
PF
A sandbox delete sec12-loop 2>&1 | tail -1 | sed 's/^/       /'
echo "   ⚠ 实测结论(2026-11-09，可复现): **数据面不 fail-closed** —— Gateway 缩到 0 的窗口里
      agent 仍连续拿到模型回复(上面 (d) 两次读到的**次数在增长**，时间戳都落在停机窗口内；
      绝对数字每轮不同 —— 两次实测分别是 3→5→9 和 3→4→8，要读的是**方向**)；
      **控制面 fail-closed** —— 「sandbox create」连 Sandbox CR 都没有(0 个)。
      supervisor **察觉**断链(自己日志里「OCSF NET:FAIL … os-a-openshell…:8080」，恢复后「NET:OPEN」)，
      但它继续代理**已批准的** L7 流量。POC2 §11 只写 'Fail Closed' 太粗，要按 §9.1 分开写。
      ⚠ 这段文案里**不要用反引号**: 双引号内的反引号会被当成命令替换，
         实测报 OCSF: command not-found，把结论行整行吃掉(与 11 号脚本同一条坑)。"

# ---------------------------------------------------------------------------
echo
# ---------------------------------------------------------------------------
echo
# SEC-13: 「通过其他进程绕过 Agent 工具调用直接访问网络」(POC2 §11 SEC-13)。
#   ⚠ 必须带**正对照**，否则"连不上"说不清是边界拦的还是这个进程本来就没网:
#     同一个进程连**自己的 supervisor:5500** 必须 CONNECTED，那才是有效对照。
#     (踩过: supervisor Service 的 clusterIP 取空 → ECONNREFUSED，看着像"被拦"，其实是没地址。)
#   ⚠ 被测进程要**不经任何工具调用**: 这里用 node 直接开原始 socket —— pi 镜像里有 node，
#     没有 python3/deno，别按别的镜像假设。
#   测法不需要新沙箱(复用 pi-dev，不消耗配额)。
#   ⚠ 具体错误码**不是不变量**: 本次 DNS 是 EAI_AGAIN、TCP 是 6s TIMEOUT；而 11 号脚本里
#     pi 的 curl 得到的是**几毫秒**的 "Couldn't connect"(SEC-01 那条)。两种都是同一个 L4 阻断的
#     不同表现(取决于当时解析走到哪一步)。**不变的是**：只有自己的 supervisor:5500 连得上。
#     复验时只要这一点成立就算通过，不要去对齐错误码。
echo "### SEC-13: 另一个进程(不经 Pi、不经任何工具调用)直接用原始 socket 出网"
SP_SVC=$(kubectl --context $CTX -n $NS get svc --no-headers 2>/dev/null | awk '/^os-supervisor-/{print $1; exit}')
SP_IP=$(kubectl --context $CTX -n $NS get svc "$SP_SVC" \
  -o jsonpath='{.spec.clusterIP} {.spec.ports[0].port}' 2>/dev/null)
echo "   边界 Service: $SP_SVC -> $SP_IP"
cat > /tmp/sec13.js <<'JS'
const net=require("net"), dns=require("dns");
const t=(host,port,label)=>new Promise(r=>{
  const s=net.connect({host,port,timeout:6000});
  s.on("connect",()=>{console.log(label+": CONNECTED");s.destroy();r()});
  s.on("timeout",()=>{console.log(label+": TIMEOUT");s.destroy();r()});
  s.on("error",e=>{console.log(label+": ERROR "+e.code);r()});
});
(async()=>{
  // ⚠ 两个参数**分开传**(argv[2]=host, argv[3]=port)。把它们拼成一个字符串再 split 也会错，
  //    但更坑的是反过来: 传 "ip port" 到 shell 里被拆成两个参数，脚本却只读 argv[2] ——
  //    实测正对照变成"没拿到地址"，整段又不可用了(2026-11-09 踩过)。
  const host=process.argv[2], port=+(process.argv[3]||0);
  if(!host || !port) console.log("  ! 没拿到 supervisor 地址 —— 正对照缺失，这次的结果不可用");
  else await t(host,port,"[正对照] 自己的 supervisor:"+port);
  await t("10.96.0.1",443,"kubernetes API 的 ClusterIP :443");
  await t("1.1.1.1",443,"1.1.1.1:443 (写死的 IP，跳过 DNS)");
  dns.lookup("api.openai.com",e=>console.log("DNS api.openai.com: "+(e?("ERROR "+e.code):"OK")));
  dns.lookup("kubernetes.default.svc",e=>console.log("DNS kubernetes.default.svc: "+(e?("ERROR "+e.code):"OK")));
})();
JS
# ⚠ kubectl exec 要用 **Pod 名 = <workspace>--<sandbox-name>**(见文件头坑 #10)，不是沙箱名。
DV=poc-shared--pi-dev
kubectl --context $CTX -n $NS exec -i $DV -c agent -- sh -c 'cat > /tmp/sec13.js' < /tmp/sec13.js
SPH=${SP_IP% *}; SPP=${SP_IP##* }   # 把 "ip port" 拆成两个标量，再作为**两个**参数传进去
kubectl --context $CTX -n $NS exec $DV -c agent -- node /tmp/sec13.js "$SPH" "$SPP" 2>&1 | sed 's/^/     /'
kubectl --context $CTX -n $NS exec $DV -c agent -- rm -f /tmp/sec13.js
echo "   ⚠ 结论(2026-11-09 实测): SEC-13 **成立**，而且比 POC2 写的更强 —— 绕不过去的不是 Pi 的工具层，"
echo "     是** Pod 的 L4 出网**：非 Pi 进程(node)自己的 socket 连不上任何非 supervisor 的目标，"
echo "     连 DNS 都失败(EAI_AGAIN)。也就是说这条**不是 L7 策略**在拦，是 §5.4 那两条 NetworkPolicy 在拦。"
echo "     含义: 想给沙箱加任何额外出口(比如自建 proxy、其它 agent runtime)都要改 NetworkPolicy，"
echo "     改 OpenShell 的 L7 策略不够。"

echo "### 汇总核对(其余 SEC 已在各自脚本里跑过，这里只做存在性检查)"
chk() { printf "   %-8s %s\n" "$1" "$2"; }
chk SEC-01 "03/11: 沙箱直连未批准域名 -> 见上面 (c) 的 TIMEOUT + supervisor 日志里的 transparent_tcp_policy_denied"
chk SEC-02 "11: 模型调用经边界 -> supervisor 日志 OCSF HTTP:POST ALLOWED … engine:l7"
chk SEC-03 "11: 未批准域名 -> OCSF NET:OPEN [MED] DENIED … [reason:transparent_tcp_policy_denied]"
chk SEC-05 "11: kubernetes.default.svc 被拒(沙箱 egress 只到自己的 supervisor)"
chk SEC-09 "05-gatekeeper.sh: privileged/hostNetwork/hostPID/hostPath 被 [poc-tenant-pod-boundary] 拒"
chk SEC-10 "05-gatekeeper.sh: RBAC 先拒；给权限后 [poc-managed-cr-only-platform] 仍拒"
chk SEC-11 "11: 沙箱里 OPENAI_API_KEY 是 openshell:resolve:env:… 占位符"
chk SEC-14 "09-resource-admission.sh: 无标签/标签不符 -> not admitted by required labels"
echo
echo "### 本轮新增的四条要点(要进报告)"
echo "   1) SEC-04/08 的归因: 跨租户阻断来自 OpenShell 的 NetworkPolicy，不是租户隔离。"
echo "      补法: Capsule spec.networkPolicies 或 Antrea ClusterNetworkPolicy(按 ns label)。"
echo "   2) SEC-06/07 是**两层独立**强制(EROFS vs EACCES)。只测一层会在另一层配置漂移时失效。"
echo "   3) SEC-12: 数据面实测**不** fail-closed，控制面**是**。supervisor 的 egress 是全开的；"
echo "      而且 supervisor 自己**察觉**断链(日志 OCSF NET:FAIL … 恢复后 NET:OPEN)却继续代理已批准的流量。"
echo "   4) SEC-13: 非 Pi 进程(node)直接开原始 socket 也出不了网 —— 连自己的 supervisor 通、其余全断(含 DNS)。"
echo "      拦它的是** L4 的 NetworkPolicy**，不是 L7 策略。所以加任何额外出口都要改 NetworkPolicy。"
