#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# aisanbox demo —— 一次 agent 运行，被两个互不相干的视角同时看到。
#
#   1. 应用自己的 OpenTelemetry trace   (OTLP -> Jaeger)
#   2. 内核对同一次运行的记录           (Tetragon / eBPF)
#
# 录视频用的四拍（全部是本机实测，不依赖任何"对接"代码）:
#   ① 越界当场被拒: agent 试着出公网 / 碰云元数据 —— 内核层 0.0s 拒绝，
#      而且 trace 里能看到 agent 自己怎么反应的。
#   ② 热更新: 改这个沙箱的出网策略，不重启沙箱，版本与 hash 可追溯。
#   ③ 两侧对照: trace 里的 tool call 与内核记录的 exec 是同一批命令。
#   ④ 分层互补: 按名字访问走边界(会带 reason)，按 IP 直连绕过边界、
#      由内核层补上 —— 两层各自的盲区正好被对方覆盖。
#
# 用法:
#   bash poc/usage/03-agent-otel-demo.sh ["给 agent 的任务"]
#   TUTOR_MODE=1 bash poc/usage/03-agent-otel-demo.sh   # 录视频用，每拍停顿
# 前提: poc/scripts/bootstrap.sh 已跑过，且 poc/observability/trace-backend.yaml
#       与 poc/agent/egress-allow.yaml 已 apply。
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."

TENANT=${TENANT:-acme}; NS=${NS:-$TENANT}; CTX=${CTX:-kind-inske-plane-a}
SANDBOX=${SANDBOX:-otel-agent}
IMAGE=${IMAGE:-docker.io/library/aisanbox-agent:0.4}
PROMPT=${1:-List the files in /etc. Then read /etc/hostname and tell me the hostname.}
TUTOR_MODE=${TUTOR_MODE:-0}
PYBIN=/usr/local/bin/python3.12      # 真实解释器路径(不是符号链接)，见 policy.yaml

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }
pause(){ [ "$TUTOR_MODE" = 1 ] && { printf '\n>>>\033[33m %s\033[0m\n[enter]' "$1"; read -r _; }; }
VIEWS="$HERE/03-demo-views.py"

# 端口转发(Jaeger UI/API + gateway)。已在跑就复用。
pf() { pgrep -f "port-forward svc/$2" >/dev/null 2>&1 || { kubectl --context $CTX -n "$1" port-forward "svc/$2" "$3" >/tmp/"$4".log 2>&1 & sleep 3; }; }
curl -s -m 2 http://localhost:16686/api/services >/dev/null 2>&1 || pf observability jaeger 16686:16686 jaeger-pf
curl -s -m 2 https://localhost:8443 >/dev/null 2>&1 || pf openshell openshell 8443:8080 os-pf
command -v openshell >/dev/null || export PATH="/private/tmp/inske-probe/cli:$PATH"

MJ=$(kubectl --context $CTX -n observability get svc jaeger -o jsonpath='{.spec.clusterIP}')
ME=$(kubectl --context $CTX -n observability get svc model-egress -o jsonpath='{.spec.clusterIP}')
GW=$(kubectl --context $CTX -n openshell get svc openshell -o jsonpath='{.spec.clusterIP}')

# 预算先看清楚: 一个 OpenShell 沙箱占用 = agent 容器 + 它的 supervisor 容器，
# 两者都算进租户配额(supervisor 由 Capsule LimitRange 兜到 500m/512Mi)。
# 这一步既是个真实前提，也是"租户合同看得见"的演示。
openshell --workspace $TENANT sandbox delete $SANDBOX >/dev/null 2>&1; sleep 6
python3 "$VIEWS" "$CTX" "$SANDBOX" quota "$NS"
say "0. 给租户 $TENANT 起一个沙箱"
note "租户身份从头到尾是同一个键: Capsule 注入 projectcapsule.dev/tenant=${TENANT}，"
note "OpenShell 按它发现 namespace，Tetragon 按它选工作负载 —— 不需要映射表。"
openshell --workspace $TENANT sandbox create --name $SANDBOX --from $IMAGE \
  --cpu 300m --memory 512Mi \
  --env ANTHROPIC_BASE_URL=http://$ME:18080 --env OTEL_EXPORTER_OTLP_ENDPOINT=http://$MJ:4318 \
  --env AISANBOX_TENANT=$TENANT --env AISANBOX_SANDBOX=$SANDBOX \
  --env-from ANTHROPIC_AUTH_TOKEN --no-credential-warnings \
  --detach --restart-policy always -- $PYBIN -u -c 'import time
while True: time.sleep(30)' 2>&1 | tail -1 || exit 1
sleep 18
kubectl --context $CTX -n $NS get pod $SANDBOX -o jsonpath='{.metadata.labels}{"\n"}' \
  | sed 's/^/   /'

# --- ① 内核层当场拒绝越界，agent 立刻能反应 ----------------------------------
say "① 越界的网络尝试：内核层当场拒绝（不是等超时）"
note "同一个进程里连三个地址，计时:"
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- $PYBIN -c "
import socket, time
for label, host, port in [('公网 DNS 8.8.8.8:53','8.8.8.8',53),
                          ('云元数据 169.254.169.254:80','169.254.169.254',80),
                          ('已放行的观测后端','$MJ',4318)]:
    t0 = time.time()
    try:
        socket.create_connection((host, port), timeout=8).close()
        print('   %-34s 通过          %.2fs' % (label, time.time()-t0))
    except Exception as e:
        print('   %-34s %s  %-16s %.2fs' % (label, '被拒', type(e).__name__, time.time()-t0))
" 2>&1 | grep -v "Defaulted container"
note "前两条是 Tetragon 的 Override(argError:-1) 直接返回 EPERM；"
note "对比: 同一个连接如果只靠 NetworkPolicy 拦，是**静默丢包** —— 实测到 40s 还没返回，"
note "什么时候失败完全取决于 agent 自己的超时。对 agent 来说快速失败远比挂起好处理。"
pause "这一格只有内核层能做：按\"哪个进程连哪个地址\"当场决定"

# --- ② 热更新：两层都能在运行中的沙箱上改，都不重启 --------------------------
say "② 运行中的沙箱上改策略：两层都能热更新，都不重启"
note "OpenShell 侧 —— 加/撤一条出网例外，每次都是带 hash 的新版本:"
openshell --workspace $TENANT policy update $SANDBOX --add-endpoint "$ME:18080" \
  --binary "$PYBIN" --rule-name model_egress 2>&1 | tail -1
openshell --workspace $TENANT policy update $SANDBOX --remove-endpoint "$ME:18080" 2>&1 | tail -1
openshell --workspace $TENANT policy update $SANDBOX --add-endpoint "$ME:18080" \
  --binary "$PYBIN" --rule-name model_egress 2>&1 | tail -1
sleep 8
openshell --workspace $TENANT policy get $SANDBOX 2>&1 | sed -n '1,4p' | sed 's/^/   /'

note "Tetragon 侧 —— 同一个 agent 容器，装/撤一条内核策略，效果立刻可测:"
note "  (a) 当前基线策略禁止 agent 用包管理器:"
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- sh -c 'pip --version' 2>&1 | grep -v "Defaulted container" | sed 's/^/      /'
note "  (b) 撤掉那条策略:"
kubectl --context $CTX delete tracingpolicy agent-exec-enforcement --ignore-not-found >/dev/null 2>&1; sleep 6
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- sh -c 'pip --version' 2>&1 | grep -v "Defaulted container" | sed 's/^/      /'
note "  (c) 再装回去 —— 同一个沙箱，没有重启，没有重新构建镜像:"
kubectl --context $CTX apply -f "$HERE/../tetragon/policies/50-enforce-exec.yaml" >/dev/null 2>&1; sleep 8
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- sh -c 'pip --version' 2>&1 | grep -v "Defaulted container" | sed 's/^/      /'
pause "策略是版本化、可审计、可回滚的；agent 不用重启动，镜像不用重建"

# --- ③ 内核侧开始记录 --------------------------------------------------------
say "③ 内核侧同时在记录"
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- sh -c \
  'pkill -f "[t]etra getevents" >/dev/null 2>&1; rm -f /tmp/demo-ev.txt;
   nohup tetra getevents -o compact --pod '"$SANDBOX"' > /tmp/demo-ev.txt 2>/dev/null &'
note "capturing events for pod/$SANDBOX"

say "④ 跑 agent（真模型调用、真工具执行）"
T0=$(date +%s)
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- \
  $PYBIN /usr/local/lib/aisanbox/agent.py "$PROMPT" 2>&1 | grep -v "Defaulted container" | sed 's/^/   /'
T1=$(date +%s)

say "⑤ 内核记录的同一轮"
kubectl --context $CTX -n kube-system exec ds/tetragon -c tetragon -- sh -c \
  'pkill -f "[t]etra getevents" >/dev/null 2>&1;
   echo "   本轮内核事件数: $(grep -c . /tmp/demo-ev.txt)";
   grep "🚀 process" /tmp/demo-ev.txt | grep -v openshell-sandbox | head -5'
pause "同一个 pod、同一个 uid 10001、同一批二进制 —— 来自内核，不是来自应用埋点"

say "⑥ 应用侧的 trace"
python3 "$VIEWS" "$CTX" "$SANDBOX" trace "$NS"
pause "这些 tool span 就是内核刚记录的那些命令"

say "⑦ 两侧对得上（没有共同埋点，标识符天然一致）"
python3 "$VIEWS" "$CTX" "$SANDBOX" join "$NS"
pause "谁也不认识谁：agent 只发标准 OTLP，平台只看内核。对得上是因为它们看的是同一个进程。"

printf '\n\033[1magent 一轮 %ss。\033[0m  trace UI: http://localhost:16686 （service aisanbox-agent）\n' "$((T1-T0))"
note "建议录屏顺序: ① → ② → ④ → ⑤ → ⑥ → ⑦ → ⑧"

say "⑧ 分层的价值：同一件事，三层的表现完全不同（实测计时）"
note "对同一个沙箱、同一个进程，连三种目标:"
kubectl --context $CTX -n $NS exec $SANDBOX -c agent -- $PYBIN -c "
import socket, time
cases = [
    ('内核策略明确拒绝的地址 (8.8.8.8:53)', '8.8.8.8', 53),
    ('NetworkPolicy 未放行的地址 (gateway:8080)', '$GW', 8080),
    ('已放行的观测后端 (jaeger:4318)', '$MJ', 4318),
]
for label, host, port in cases:
    t0 = time.time()
    try:
        socket.create_connection((host, port), timeout=9).close()
        print('   %-44s 通过            %5.2fs' % (label, time.time()-t0))
    except PermissionError:
        print('   %-44s 内核当场拒绝     %5.2fs' % (label, time.time()-t0))
    except Exception as e:
        print('   %-44s 超时/失败        %5.2fs' % (label, time.time()-t0))
" 2>&1 | grep -v "Defaulted container"
note ""
note "三条不同路径，三种性质:"
note "  · 内核层(Tetragon) 按\"哪个进程连哪个地址\"决定，0.0x s 返回 EPERM —— 不看 DNS，不依赖网络拓扑。"
note "  · NetworkPolicy 只看 L3/L4 允许集合；不在集合里就**静默丢包**，失败时间由客户端超时决定(实测 40s 仍未返回)。"
note "    它对\"是谁发起的\"一无所知。"
note "  · OpenShell 的 L7 边界按\"域名 + 请求\"决定，能给出 reason(为什么拒)和审计；但**按 IP 直连不经过它**。"
note "  所以三层的盲区正好互相覆盖。少任何一层，都有一类越界看不见或拦不住。"
pause "这就是为什么是四层，不是一层"

say "⑨ 附：一条真实边界（本轮实测，别踩）"
note "OpenShell 的 network_policies.binaries 只在 **L7** 规则上参与判定；"
note "一条没有 protocol 的 L4 规则里 binaries 只写了 /bin/tar，python3.12 照样能连过去。"
note "想把\"某个进程不许连某个地址\"变成硬边界，就是 ① 里内核层做的事。"
note "详见 poc/agent/policy.yaml 注释与 poc/docs/FINDINGS.md §R2.3。"
