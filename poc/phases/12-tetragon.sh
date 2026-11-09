#!/usr/bin/env bash
# Phase 5 —— Tetragon(eBPF) 运行时观测 (POC2 §3.7 / §7, 验证 POC-07)
# 手工重现: bash poc/phases/12-tetragon.sh
#
# 要证明的五件事(POC2 §7.1 表格,即 POC-07):
#   (a) Process Exec    —— 沙箱里执行了什么(argv 原样可见)
#   (b) Process Exit    —— 进程退出与退出状态
#   (c) Network Connect —— 五元组(saddr:sport -> daddr:dport),含被拦掉的"尝试"
#   (d) Process Parent  —— 谁启动了谁(需要 --parents-map-enabled,见 tetragon/values.yaml)
#   (e) K8s 身份        —— 事件自带 namespace/pod/container.image/workload
# 边界(POC2 §7.1):Tetragon 只负责"看见",允许/拒绝归 Antrea(NetworkPolicy)和 OpenShell。
# 本脚本不动 observability ns;对正在运行的真实 agent(poc-shared--pi-trace-test)只**被动读**
# 事件,不 exec、不对其施加强制。
#
# ===== 本轮(2026-11-08, kind 宿主内核 6.8.0-147-generic)实测坑,按踩到顺序 =====
# 1) 版本核对: helm repo cilium/tetragon 最高 chart=1.8.0,GitHub releases/latest 也是
#    v1.8.0(2026-10-30) —— 与上一轮一致,policy 的 API(cilium.io/v1alpha1)没有变化。
# 2) **旧策略包在本集群"加载成功但 0 事件"**: selector 写的是旧集群租户标签
#    (projectcapsule.dev/tenant: acme),本集群真实标签是 Capsule 注入的 tenant-a。
#    已按 tenant-a 修正(最小改动)。**加载不报错**是这类问题的伪装术。
# 3) **kubectl apply 的退出码与 TracingPolicy 的 status 都不能用来判断加载**:
#    apply 成功≠加载成功;1.8.0 里加载**失败**的策略 CRD status 也是空的 {}。
#    权威判断有两个: a) agent 里 `tetra tracingpolicy list` 的 STATE 列(enabled/load_error);
#    b) agent 容器 stderr 日志里的 "adding tracing policy failed"。脚本用 a)。
# 4) kprobe_multi(1.8.0 默认)两条硬限制,报错文本自带解法:
#    同一策略内同 symbol 出现两次(00/30 的"一全量一过滤"写法):
#      "can't have multiple instances of same symbol 'tcp_connect' with kprobe_multi,
#       use --disable-kprobe-multi option"
#    带 action: Override 的强制策略:
#      "override validation failed: can't override 'security_socket_connect' function
#       with kprobe_multi, use --disable-kprobe-multi option"
#    => values.yaml 加 --disable-kprobe-multi(已在 values 记录,生产开回前要按此拆策略)。
# 5) **lsmhooks 在本宿主内核整体不可用(环境差异,不是策略写错)**:
#      "does you kernel support the bpf LSM? You can enable LSM BPF by modifying
#       the GRUB configuration /etc/default/grub with GRUB_CMDLINE_LINUX=\"lsm=bpf\""
#    实测: 节点 /sys/kernel/security/lsm = lockdown,capability,landlock,yama,apparmor;
#    Ubuntu 6.8 内核 CONFIG_LSM 不含 bpf(上一轮的 6.12.72 含)。lsm 列表只能开机改,
#    所以 supply-chain 观察(20)与 exec 强制(50)要等宿主 grub+重启后才能启用;
#    kprobe 类观测与 security_socket_connect 强制不受影响(它是 kprobe 挂的 override)。
#    这正是"错误信息指向的是宿主内核,不是 Tetragon 配置"的那类分层。
# 6) `tetra getevents` 是**只直播、不回放**的流: 不加 `timeout` 永不退出(脚本会挂),
#    先 getevents 后造事件也一定为空。正确姿势: `timeout N tetra getevents ... &` 起流,
#    再造事件,再收流。JSON 文件(/var/log/tetragon/tetragon.log)才是可回查的那份。
# 7) JSON 导出字段名(与文档/gRPC proto 直觉不同,按实测写): 事件按类型分顶层键
#    process_exec/process_exit/process_kprobe;K8s 身份在 **process.pod**(不是 k8s 字段);
#    退出码是 **process_exit.status**(不是 exit_status/errno/signal);
#    五元组在 **args[].sock_arg**(tcp_connect+type:sock);
#    security_socket_connect 的目的地在 **args[].sockaddr_arg**(此刻 socket 未连接,
#    sock_arg 全是 0.0.0.0 —— 按 sock_arg 找被拒连接的 daddr 会"看见了但读不到")。
# 8) 造测试事件的两个坑: busybox 的 echo 是 shell 内建,`echo x` **不产生 execve**
#    (要 /bin/echo);alpine 镜像里**没有 nc**(用 wget 造 TCP connect)。
# 9) 父进程信息: PROCESS_EXEC 事件**不带**内联 parent(只有 parent_exec_id + ancestors);
#    内联 parent 出现在 process_kprobe/process_exit 事件里。要"每条 exec 都带父"就用
#    processAncestors(values 已开)。matchParentBinaries 的 values 要同时写 /bin/sh 与
#    /bin/busybox —— 父 binary 记成调用路径还是解析后路径与版本/内核相关(两轮都见过)。
# 10) **成功退出在 JSON 里没有 status 字段**: process_exit 事件只在非零退出时带 status,
#    exit 0 的整个键都不导出(实测: status=None 的行 keys=['time'];status=7 的行 keys=[status,time])。
#    但 compact 输出会统一显示 `0`。=> 想用 JSON 判断"是否异常退出",规则是 status 缺失=成功;
#    按字符串 grep `"exit 7"` 也不行 —— argv 在 JSON 里是转义后的,匹配不到带引号的原文。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
TNS=tenant-a-runtime          # 真实租户 ns(Capsule 注入 projectcapsule.dev/tenant 标签)
ONS=poc-tetra-obs             # 自造观察 ns(不带租户标签,证明独立观察链路)
PROBE=tetra-probe
TPROBE=tetra-tenant-probe
TETRAGON_VERSION=1.8.0        # 见上面第 1 条: chart 与 GitHub latest 一致的版本

echo "### 前置: 节点内核/BTF/LSM (POC2: 没有 BTF 先解决 BTF,别排查 Tetragon 配置)"
# 实测: kind 节点容器里**没有挂 securityfs**(cat /sys/kernel/security/lsm 在节点内报
# No such file) —— 节点与宿主共享内核,LSM 列表要在宿主上看。
echo "   宿主 lsm 栈: $(cat /sys/kernel/security/lsm 2>/dev/null)"
for n in $(kind get nodes --name agent-runtime-poc); do
  printf "   %-28s kernel=%-16s btf=%s\n" "$n" "$(docker exec $n uname -r)" \
    "$(docker exec $n test -e /sys/kernel/btf/vmlinux && echo yes || echo NO)"
done
# 没有 bpf 在 lsm 列表里 → 预期: 所有 lsmhooks 策略 load_error(实测坑 #5),继续跑 kprobe 项。

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null 2>&1 || true
helm --kube-context $CTX upgrade --install tetragon cilium/tetragon \
  --namespace kube-system --version "$TETRAGON_VERSION" \
  -f tetragon/values.yaml --wait --timeout 8m
kubectl --context $CTX -n kube-system rollout status ds/tetragon --timeout=240s >/dev/null
kubectl --context $CTX wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=120s >/dev/null

echo
echo "### 组件与版本自证"
helm --kube-context $CTX list -n kube-system | grep -E "NAME|tetragon" | sed 's/^/   /'
kubectl --context $CTX -n kube-system get pods -l app.kubernetes.io/name=tetragon --no-headers \
  -o custom-columns=N:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName | sed 's/^/   /'
# 实测: 此 chart 默认 tolerations=operator:Exists —— control-plane 也被调度,
# DS 数==节点数;按"只有 worker 上有"核对会误判。
tpod() { kubectl --context $CTX -n kube-system get pods -l app.kubernetes.io/name=tetragon \
  --field-selector "spec.nodeName=$1" -o jsonpath='{.items[0].metadata.name}'; }
ALLNODES=$(kind get nodes --name agent-runtime-poc)
NODE0=$(kubectl --context $CTX -n kube-system get pods -l app.kubernetes.io/name=tetragon \
  --no-headers -o jsonpath='{.items[0].spec.nodeName}')
kubectl --context $CTX -n kube-system exec $(tpod $NODE0) -c tetragon -- sh -c \
  'tetra version; echo; tetra status' 2>/dev/null | sed 's/^/   /'

echo
echo "### 策略加载(POC2 §7.2)—— 以 agent 侧 STATE 为准,不看 CRD status(实测坑 #3)"
for f in 00-egress-who 10-dangerous-fs 20-supply-chain 30-exec-and-proc 60-poc5-demo; do
  kubectl --context $CTX apply -f tetragon/policies/$f.yaml >/dev/null
done
# 40/50 是强制类。它们按 tenant-a 选 Pod,直接生效会改变**正在运行的 agent** 的行为
# (50 会拒 /bin/bash exec;用户场景在跑),所以这里临时换成不命中 selector 只验加载。
for f in 40-enforce-network 50-enforce-exec; do
  sed 's#projectcapsule.dev/tenant: tenant-a#projectcapsule.dev/tenant: loadtest-no-match#' \
    tetragon/policies/$f.yaml | kubectl --context $CTX apply -f - >/dev/null
done
sleep 4
P0=$(tpod $NODE0)
kubectl --context $CTX -n kube-system exec $P0 -c tetragon -- tetra tracingpolicy list | sed 's/^/   /'
echo "   ↑ load_error 的应只有 lsmhooks 那两条(20-supply-chain / 50-exec-enforcement),"
echo "     原因=宿主内核未启用 bpf LSM(实测坑 #5),agent 日志原文:"
kubectl --context $CTX -n kube-system logs $P0 -c tetragon 2>&1 \
  | grep -m1 -o "does you kernel support the bpf LSM.*" | sed 's/^/       /'

echo
echo "### 探针 Pod(观察 ns + 租户 ns 各一个,收尾删除)"
kubectl --context $CTX delete ns $ONS --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context $CTX create ns $ONS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl --context $CTX -n $ONS apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $PROBE, labels: {aisanbox.io/poc: phase5}}
spec:
  containers: [{name: c, image: alpine:latest, command: ["sleep", "900"]}]
EOF
# 租户探针:**不手工打租户标签** —— 实测 Capsule 的 namespace Mutation 会给 Pod 自动注入
# projectcapsule.dev/tenant=tenant-a,tenant pack 就是这样选中它的。
# Gatekeeper k8spocruntime 要求 Pod 显式 resources —— 已显式写。
kubectl --context $CTX -n $TNS apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $TPROBE}
spec:
  containers:
    - name: c
      image: alpine:latest
      command: ["sleep", "900"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
EOF
kubectl --context $CTX -n $ONS wait --for=condition=Ready pod/$PROBE --timeout=180s 2>&1 | tail -1 | sed 's/^/   /'
kubectl --context $CTX -n $TNS wait --for=condition=Ready pod/$TPROBE --timeout=180s 2>&1 | tail -1 | sed 's/^/   /'
echo "   租户探针被 Capsule 自动注入的标签(策略就是按它选的):"
kubectl --context $CTX -n $TNS get pod $TPROBE -o jsonpath='{.metadata.labels.projectcapsule\.dev/tenant}' | sed 's/^/     projectcapsule.dev\/tenant= /;s/$/\n/'
PNODE=$(kubectl --context $CTX -n $ONS get pod $PROBE -o jsonpath='{.spec.nodeName}')
TNODE=$(kubectl --context $CTX -n $TNS get pod $TPROBE -o jsonpath='{.spec.nodeName}')
PLOG=$(tpod $PNODE); TLOG=$(tpod $TNODE)   # JSON 导出只在事件发生的节点上
MARK=P5-$(date +%s)

ex()  { kubectl --context $CTX -n $ONS exec $PROBE  -- sh -c "$1"; }
tex() { kubectl --context $CTX -n $TNS exec $TPROBE -- sh -c "$1"; }
# 实测坑 #6: getevents 只直播不回放 —— 先起流(timeout 兜底),再造事件。
startcap() { # $1=agentPod $2=ns过滤器 $3=输出文件; 起流后**必须 sleep**:
  # kubectl exec 起流要 1-2s,事件早于流开始就全漏(实测两跑一次漏一次)。
  ( kubectl --context $CTX -n kube-system exec "$1" -c tetragon -- \
      timeout 12 tetra getevents -o compact --timestamps --namespace "$2" > "$3" 2>/dev/null ) & }
W=/tmp/p5-work.$$; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
# 实测坑: 管道接 head 会让远端 cat 收到 SIGPIPE,kubectl 会打印
# "command terminated with exit code 1" 干扰判读 —— 一律先落文件再解析。
jlog() { # $1=agentPod $2=输出文件; 按关键字取事件
  kubectl --context $CTX -n kube-system exec "$1" -c tetragon -- cat /var/log/tetragon/tetragon.log 2>/dev/null \
  | python3 -c '
import sys
for line in sys.stdin:
    if all(k in line for k in sys.argv[1:]):
        print(line, end="")
' "${@:3}" > "$2"; }
# JSON 结构实测(坑 #7):类型键 process_exec/process_exit/process_kprobe;
# 身份=process.pod;退出码=process_exit.status;五元组=args[].sock_arg。
fmt() { python3 -c '
import sys,json
for line in sys.stdin:
    try: e=json.loads(line)
    except Exception: continue
    for kind in ("process_exec","process_exit","process_kprobe"):
        ev=e.get(kind)
        if not ev: continue
        p=ev.get("process") or {}; pod=p.get("pod") or {}
        if kind=="process_exec":
            anc=[a.get("binary") for a in (ev.get("ancestors") or [])][:3]
            print("PROCESS_EXEC binary=%s argv=%r" % (p.get("binary"),p.get("arguments")))
            print("  (e) 身份: ns=%s pod=%s container=%s image=%s" % (pod.get("namespace"),pod.get("name"),
                  ((pod.get("container") or {}).get("name")),(((pod.get("container") or {}).get("image")) or {}).get("name")))
            print("  (d) 链: parent_exec_id=%s... ancestors=%s" % ((p.get("parent_exec_id") or "")[:16],anc))
        elif kind=="process_exit":
            print("PROCESS_EXIT argv=%r status=%s" % (p.get("arguments"),ev.get("status")))
        elif kind=="process_kprobe":
            sargs=[a.get("string_arg") for a in (ev.get("args") or []) if a.get("string_arg")]
            s=None; sa=None
            for a in ev.get("args") or []:
                s=a.get("sock_arg") or s; sa=a.get("sockaddr_arg") or sa
            line="KPROBE msg=%s argv=%r" % (ev.get("message"),p.get("arguments"))
            if sargs: line += " arg0=%r" % sargs[0]
            if s and (s.get("daddr") not in (None,"0.0.0.0")):
                line += " %s %s:%s -> %s:%s" % (s.get("family"),s.get("saddr"),s.get("sport"),s.get("daddr"),s.get("dport"))
            elif sa:
                line += " 目的地(sockaddr_arg)=%s:%s action=%s" % (sa.get("addr"),sa.get("port"),ev.get("action"))
            print(line)
' ; }

startcap "$PLOG" $ONS /tmp/p5-obs.txt
sleep 2
# 先确保 61(1.1.1.1 强制)不在: 上一轮运行若留下了它,这里的"出公网"基线会被当场拒掉。
# (策略是集群级对象,跨运行留存 —— 演示"先观测后强制"时必须显式控制它的存在与否。)
kubectl --context $CTX delete tracingpolicy poc5-enforce-net --ignore-not-found >/dev/null 2>&1
sleep 1
# 把 MARK 放进 wget 的 URL 参数: kprobe 事件里的 argv 就是这次 connect 的进程参数,
# 用 MARK 过滤才能确认"是本轮的事件"(重复运行时 tetragon.log 里有上一轮的旧行)。
ex "/bin/echo $MARK-exec; /bin/sh -c '/bin/echo $MARK-ex7; exit 7'; wget -T2 -q -O- \"https://1.1.1.1/?$MARK\" >/dev/null 2>&1; wget -T2 -q -O- \"http://10.96.0.1:443/?$MARK\" >/dev/null 2>&1; /bin/sh -c '/bin/sh -c \"/bin/cat /etc/hostname #$MARK-pc\"'"
wait
echo
echo "### (a)(b)(c)(d) 观察 ns 探针: tetra getevents -o compact 原始输出"
grep -E "$MARK|connect |poc5:" /tmp/p5-obs.txt | cut -c1-200 | sed 's/^/   /'
echo
jlog "$PLOG" "$W/ex.json" "$MARK-exec" '"process_exec"'
head -1 "$W/ex.json" | fmt
# 实测坑(坑 #10): 成功退出的事件**没有 status 键**;只有非零退出才有。
# 所以关键字用 '"status":7' —— 既证明退出状态被记录,又天然排除了 exit 0 的行。
jlog "$PLOG" "$W/exit.json" "$MARK-ex7" '"process_exit"' '"status":7'
fmt < "$W/exit.json" | head -1 | sed 's/^/   /'
# 注意: 这里两条都用 poc5:egress-who(按探针标签选)。观察 ns 的探针**没有**租户标签,
# 用 00 的 agent:* 去取必然 0 条 —— 这正是坑 #2 的反向印证:0 事件先查 selector。
# 租户标签版本(agent:in-cluster)在下面的 (e) 里用租户探针证明。
jlog "$PLOG" "$W/net.json" poc5:egress-who "$MARK" '"daddr":"1.1.1.1"'
fmt < "$W/net.json" | head -1 | sed 's/^/   出公网: /'
jlog "$PLOG" "$W/in.json" poc5:egress-who "$MARK" '"daddr":"10.96.0.1"'
fmt < "$W/in.json" | head -1 | sed 's/^/   集群内: /'
echo
echo '### (d) matchParentBinaries 策略命中(只报"父是 sh/busybox"的子进程):'
echo "   实测: 内联 parent 在 process_kprobe/process_exit 里;PROCESS_EXEC 只有 parent_exec_id+ancestors(坑 #9)"
jlog "$PLOG" "$W/child.json" poc5:child-of-shell "$MARK"
fmt < "$W/child.json" | head -2 | sed 's/^/   /'
jlog "$PLOG" "$W/par.json" "$MARK-pc" '"process_kprobe"'
head -1 "$W/par.json" | python3 -c '
import sys,json
try: e=json.load(sys.stdin)["process_kprobe"]
except Exception: sys.exit()
p=e.get("parent") or {}
print("   内联 parent: binary=%s argv=%r" % (p.get("binary"),p.get("arguments")))'

startcap "$TLOG" $TNS /tmp/p5-tns.txt
sleep 2
tex "/bin/echo $MARK-T; wget -T2 -q -O- \"http://10.96.0.1:443/?$MARK\" >/dev/null 2>&1"
wait
echo
echo "### (e) 租户链路: $TNS 里的 Pod,由 **tenant pack**(按租户标签)捕获 —— POC-07 交付证据"
echo "   tetra getevents -o compact --namespace $TNS 原始输出:"
grep -E "$MARK-T|connect " /tmp/p5-tns.txt | cut -c1-200 | sed 's/^/   /'
echo "   同事件的 JSON(策略 msg=agent:exec / agent:in-cluster,即 00/30 这两条):"
jlog "$TLOG" "$W/texec.json" "$MARK-T" '"message":"agent:exec"'
head -1 "$W/texec.json" | fmt | sed 's/^/   /'
jlog "$TLOG" "$W/tnet.json" agent:in-cluster "$MARK"
fmt < "$W/tnet.json" | head -1 | sed 's/^/   由 00(tenant pack)捕获的连接: /'

echo
echo '### 附带: 网络运行时强制(先观测后强制;对照 NetworkPolicy 的"挂住")'
echo "   刚才 1.1.1.1 是通的(上面出公网那条 daddr=1.1.1.1);现在加载 61 再连同一条:"
kubectl --context $CTX apply -f tetragon/policies/61-poc5-enforce.yaml >/dev/null
sleep 3
t0=$(date +%s%N); o2=$(ex "wget -T3 -q -O- \"https://1.1.1.1/?$MARK-denied\" >/dev/null" 2>&1); r=$?; t1=$(date +%s%N)
echo "   强制后: rc=$r 耗时=$(( (t1-t0)/1000000 ))ms 输出: $o2"
echo "   复验上一轮结论: NetworkPolicy 拦=挂到超时;Override(argError:-1)=立即 EPERM,进程存活。"
jlog "$PLOG" "$W/den.json" poc5:egress-denied "$MARK-denied"
fmt < "$W/den.json" | head -1 | sed 's/^/   内核仍记全尝试: /'
echo "   (注意 0.0.0.0 出现在 sock_arg —— 被拒时 socket 未连接,目的地在 sockaddr_arg,坑 #7)"

echo
echo '### 真实 agent sandbox 的被动观测(只读,不 exec 它)'
for n in $ALLNODES; do
  kubectl --context $CTX -n kube-system exec $(tpod $n) -c tetragon -- cat /var/log/tetragon/tetragon.log 2>/dev/null
done | python3 -c '
import sys,json
n=0
for line in sys.stdin:
    try: e=json.loads(line)
    except Exception: continue
    for kind in ("process_exec","process_kprobe"):
        ev=e.get(kind)
        if not ev: continue
        pod=(ev.get("process") or {}).get("pod") or {}
        if pod.get("namespace")=="'"$TNS"'" and "tetra-" not in (pod.get("name") or ""):
            n+=1
            if n<=3:
                print("   %s pod=%s argv=%r" % (kind,pod.get("name"),(ev.get("process") or {}).get("arguments")))
print("   真实 sandbox/ supervisor 事件总数(本脚本窗口,全节点 JSON):",n)'

echo
echo '### §7.3 预留接入点(本阶段不动 observability,只报告事实)'
echo "   每个 agent 导出 /var/log/tetragon/tetragon.log(JSON 行,节点宿主路径)与 :54321 gRPC;"
echo "   OTel Collector Contrib 的 filelog receiver 可直接吃前者。事件与 Pi Trace 不共享"
echo "   trace_id —— 用 Pod UID + 时间戳关联(POC2 §7.3);env 变量字段实测叫"
echo "   environment_variables(见 values.yaml 的更正注释),放进 argv 仍是最稳的关联方式。"

echo
echo "### 收尾: 删除探针 Pod/NS;保留 Tetragon 与策略包(它们是后续阶段交付物)"
kubectl --context $CTX -n $ONS delete pod $PROBE --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n $TNS delete pod $TPROBE --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX delete ns $ONS --ignore-not-found >/dev/null 2>&1
kubectl --context $CTX -n kube-system exec $P0 -c tetragon -- tetra tracingpolicy list | \
  awk '$4=="enabled" {print "   已加载(STATE=enabled): "$2}'
