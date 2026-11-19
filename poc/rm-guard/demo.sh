#!/usr/bin/env bash
# rm-guard · supervisor 放行，内核不答应（OpenShell 0.1.7 实测版）
#
# 在 192.168.5.190 上：
#   bash /root/poc2/rm-guard/demo.sh          # 交互，每拍回车（录屏）
#   FAST=1 bash /root/poc2/rm-guard/demo.sh   # 连跑回归
#   bash demo.sh --cleanup                    # 清场
#
# 故事：sandbox 策略明确允许工作区可写 → agent 执行 rm -rf，supervisor 批准
# （OCSF SSH:OPEN ALLOWED，无 DENIED，文件真的被删）→ Tetragon 内核观测
# 逐文件见证 → responder 调 openshell CLI：stop 暂停 + gateway 全局锁拒绝
# （再起来就是只读）。变体拍：kprobe Override 内核直拒，零删除。
#
# 前置：kind 集群 + tetragon（../tetragon/values.yaml）+ gateway os-a
# （CLI 名 poc2-a）+ 镜像 opencode-agent:poc（../opencode-data-agent/build-image.sh）
# 正对照 sandbox：默认 v-cm（vault demo 遗留），可用 PC_SB=<name> 换。
set -uo pipefail
CTX=kind-agent-runtime-poc
C=/root/poc2/vendor/openshell-cli-0.1.7/openshell
G="-g poc2-a --workspace poc-shared"
NS=tenant-a-runtime
K="kubectl --context $CTX"
D="$(cd "$(dirname "$0")" && pwd)"
FAST=${FAST:-0}
FAIL=0
SB=rm-guard
POD="poc-shared--$SB"
CANARY=/sandbox/canary
N=200
PC_SB=${PC_SB:-v-cm}
TL="$D/timeline.jsonl"
RLOG="$D/responder.log"

pause() { [ "$FAST" = "1" ] || read -rp "── 回车继续 ── " _; }
step()  { echo; echo "════════ 第 $1 拍：$2 ════════"; echo "证明：$3"; }
check() {
  # herestring 而非管道：pipefail 下 grep -q 提前退出会让上游吃 SIGPIPE，
  # 大输出时把通过的断言误判成失败（实测撞过）。
  if grep -qF "$2" <<< "$3"; then echo "✅ $1"
  else echo "❌ $1（期望含 [$2]，实际：$(head -2 <<< "$3")）"; FAIL=1; fi
}
check_num() { # check_num <label> <actual> <op: eq|ge> <expected>
  if [ "$3" = "eq" ] && [ "$2" = "$4" ] || [ "$3" = "ge" ] && [ "$2" -ge "$4" ]; then
    echo "✅ $1（$2）"
  else echo "❌ $1（实际 $2，期望 $3 $4）"; FAIL=1; fi
}
sb_delete() {
  local out; out=$($C $G sandbox delete "$1" 2>&1)
  case "$out" in *"✓"*|*"not found"*|*"No sandbox"*) ;; *) echo "  (delete $1: $out)";; esac
}
sb_wait_gone() {
  local out
  for _ in $(seq 1 30); do
    out=$($C $G sandbox list 2>/dev/null); grep -q "$1" <<< "$out" || return 0; sleep 2
  done
}
wait_ready() {
  local out
  for _ in $(seq 1 40); do
    out=$($C $G sandbox get "$SB" 2>/dev/null)
    grep -q "Phase: Ready" <<< "$out" && return 0; sleep 3
  done
  echo "❌ $SB 等不到 Ready"; FAIL=1; return 1
}
kill_responder() {
  [ -f "$D/responder.pid" ] && kill "$(cat "$D/responder.pid")" 2>/dev/null
  rm -f "$D/responder.pid"
}

if [ "${1:-}" = "--cleanup" ]; then
  kill_responder
  sb_delete $SB; sb_wait_gone $SB
  $K delete tracingpolicy rm-guard rm-guard-files rm-guard-enforce --ignore-not-found 2>&1 | sed 's/^/  /'
  $C $G policy delete --global --yes >/dev/null 2>&1
  echo "已清场（timeline.jsonl / responder.log 保留为证据）"
  exit 0
fi

echo "═══ 第 0 拍：自检 ═══"
if ! grep -q ":18441 " <<< "$(ss -ltn)"; then
  setsid nohup $K -n tenant-a-gateway port-forward svc/os-a-openshell \
    18441:8080 --address 127.0.0.1 >/tmp/pf-os-a.log 2>&1 &
  sleep 4
fi
$C $G whoami >/dev/null 2>&1 || { echo "❌ gateway 通道不通"; exit 1; }
grep -q Running <<< "$($K -n kube-system get pods -l app.kubernetes.io/name=tetragon 2>/dev/null)" \
  || { echo "❌ tetragon 不在"; exit 1; }
grep -q opencode-agent <<< "$(docker exec agent-runtime-poc-control-plane crictl images 2>/dev/null)" \
  || { echo "❌ kind 里没有 opencode-agent:poc（先跑 ../opencode-data-agent/build-image.sh）"; exit 1; }
grep -q "$PC_SB" <<< "$($C $G sandbox list 2>/dev/null)" \
  || { echo "❌ 正对照 sandbox $PC_SB 不在（PC_SB=<name> 换一个 Ready 的）"; exit 1; }
PU=$($K -n $NS get resourcequota capsule-tenant-a-0 -o jsonpath='{.status.used.persistentvolumeclaims}')
PH=$($K -n $NS get resourcequota capsule-tenant-a-0 -o jsonpath='{.spec.hard.persistentvolumeclaims}')
if $K -n $NS get pvc "workspace-poc-shared--$SB" >/dev/null 2>&1; then PU=$((PU-1)); fi
if [ "$PU" -ge "$PH" ]; then
  echo "❌ PVC 配额满（$PU/$PH）：先删一个不用的 sandbox，或调高租户配额"; exit 1
fi
echo "✅ gateway / tetragon / 镜像 / 正对照($PC_SB) / 配额($PU/$PH)"
pause

step 1 "建 sandbox（策略明确放行）+ 部署检测策略" \
     "supervisor 的'批准'来自策略本身：rev1 工作区可写；检测策略租户级+pod级两层"
kill_responder
sb_delete $SB; sb_wait_gone $SB
for _ in $(seq 1 30); do
  $K -n $NS get pvc "workspace-poc-shared--$SB" >/dev/null 2>&1 || break; sleep 2
done
$C $G sandbox create --name $SB --from opencode-agent:poc \
  --cpu 500m --memory 1Gi --detach --restart-policy never \
  --policy "$D/policy-allow.yaml" -- sh -c "sleep 3600" 2>&1 | tail -1
wait_ready || exit 1
OUT=$($C $G policy get $SB 2>&1)
check "策略 rev1 生效（sandbox 级）" "Source:       sandbox" "$OUT"
# policy get 只回显版本/哈希，不回显规则正文 —— 用写探针证明工作区可写
OUT=$($C $G sandbox exec $SB -- sh -c "touch /sandbox/.rw-probe && echo WRITE_OK" 2>&1)
check "supervisor 放行工作区写（正对照）" "WRITE_OK" "$OUT"
# pod 级逐文件见证策略：按 sandbox-name-hash 标签只选本 sandbox
HASH=$($K -n $NS get pod $POD -o jsonpath='{.metadata.labels.agents\.x-k8s\.io/sandbox-name-hash}')
sed "s/__HASH__/$HASH/" "$D/tracingpolicy-files.yaml.template" > /tmp/rm-guard-files.yaml
$K apply -f "$D/tracingpolicy.yaml" >/dev/null
$K apply -f /tmp/rm-guard-files.yaml >/dev/null
sleep 4
OUT=$($K -n kube-system exec $($K -n kube-system get pods -l app.kubernetes.io/name=tetragon \
  --field-selector spec.nodeName=$($K -n $NS get pod $POD -o jsonpath='{.spec.nodeName}') \
  -o jsonpath='{.items[0].metadata.name}') -c tetragon -- tetra tracingpolicy list 2>&1)
check "rm-guard 加载（monitor_only）" "rm-guard " "$OUT"
check "rm-guard-files 加载" "rm-guard-files" "$OUT"
echo "  pod=$POD  hash=$HASH"
pause

step 2 "启动 responder（边界外，持 CLI 凭据）" \
     "沙箱内拿不到这条强制链的任何凭据；事件流=tetra getevents --policy-names rm-guard,rm-guard-files"
: > "$TL"
setsid nohup python3 "$D/responder.py" --once --sandbox $SB --timeline "$TL" \
  > "$RLOG" 2>&1 &
echo $! > "$D/responder.pid"
for _ in $(seq 1 60); do grep -q listening "$RLOG" 2>/dev/null && break; sleep 1; done
check "探针事件穿过事件通道（正对照）" "probe-ok" "$(cat "$RLOG")"
check "responder 就绪监听" "listening" "$(cat "$RLOG")"
tail -3 "$RLOG" | sed 's/^/  /'
pause

step 3 "种 canary：$N 个文件" \
     "正对照：攻击前计数必须=$N，后面的计数差才有意义"
OUT=$($C $G sandbox exec $SB -- sh -c \
  "mkdir -p $CANARY; i=0; while [ \$i -lt $N ]; do echo data-\$i > $CANARY/f\$i; i=\$((i+1)); done; ls $CANARY | wc -l" 2>&1)
check_num "canary 计数" "$(printf '%s' "$OUT" | tail -1)" eq "$N"
pause

step 4 "攻击：rm -rf $CANARY —— supervisor 批准" \
     "策略允许→landlock 放行→OCSF SSH:OPEN ALLOWED 且无 DENIED→文件真的没了"
T_ATTACK=$(date -u +%FT%T.%3NZ)
echo "  攻击时刻：$T_ATTACK"
OUT=$($C $G sandbox exec $SB -- sh -c \
  "rm -rf $CANARY; ls $CANARY 2>/dev/null | wc -l" 2>&1)
AFTER=$(printf '%s' "$OUT" | tail -1)
check_num "攻击后计数（删除真实发生）" "$AFTER" eq 0
BP=$($K -n $NS get pod $POD -o jsonpath='{.metadata.labels.openshell\.ai/boundary-pair}')
SUP=$($K -n $NS logs "os-supervisor-$BP" --since=90s 2>/dev/null)
check "supervisor 批准了 exec 通道" "SSH:OPEN [INFO] ALLOWED" "$SUP"
DENIED=$(printf '%s' "$SUP" | grep -c "DENIED" || true)
check_num "supervisor 无 DENIED" "$DENIED" eq 0
echo "  supervisor 日志（攻击窗口）："
printf '%s\n' "$SUP" | grep -E "SSH:OPEN|CONFIG:LOADED" | tail -2 | sed 's/^/    /'
echo "  计数差：$N → $AFTER（带外环有延迟，删除先于暂停完成 —— 如实展示）"
pause

step 5 "Tetragon 内核证据：逐文件见证" \
     "rm-exec 早期预警 + $N+1 条 file-delete（200 文件+顶层目录），pod/uid/binary/argv 齐全"
# 读线程在 enforce 期间持续排空管道，计数是逐渐到位的 ——  poll 到齐为止
FEV=0
for _ in $(seq 1 20); do
  FEV=$(grep -c '"message": "rmguard:file-delete"' "$TL" 2>/dev/null || true)
  [ "$FEV" -ge "$N" ] && break; sleep 1
done
check_num "file-delete 事件数（≥$N）" "$FEV" ge "$N"
check "rm-exec 早期预警" "rmguard:rm-exec" "$(cat "$TL")"
echo "  首条事件（内核视角）："
FIRST=$(grep '"kind": "event"' "$TL" | head -1)
if [ -n "$FIRST" ]; then
  printf '%s' "$FIRST" | python3 -c \
    'import json,sys; e=json.load(sys.stdin); print("   ", json.dumps({k:e[k] for k in ("t","message","binary","arguments","args")}, ensure_ascii=False))'
else
  echo "    （无事件 —— 检查 responder.log）"; FAIL=1
fi
pause

step 6 "CLI 强制：stop 暂停 + gateway 全局锁拒绝" \
     "0.1.7 实测：suspend 不支持→stop；live policy 只增不减→拒绝走全局锁（下次启动生效）"
for _ in $(seq 1 30); do grep -q '"kind": "enforced"' "$TL" 2>/dev/null && break; sleep 1; done
check "强制完成" '"enforced"' "$(cat "$TL")"
grep -E '"kind": "(detect|pause|deny|enforced)"' "$TL" | python3 -c '
import json,sys
for line in sys.stdin:
    e=json.loads(line)
    k=e["kind"]
    if k=="detect": print("  检测到危险动作 :", e["t"])
    elif k=="pause": print("  暂停(stop)     :", e["t"], "rc="+str(e["rc"]), "("+str(e["elapsed_s"])+"s)")
    elif k=="deny": print("  拒绝(全局锁)   :", e["t"], "rc="+str(e["rc"]))
    elif k=="enforced": print("  强制完成       :", e["t"], "deny_ok="+str(e["deny_ok"]), "pause_ok="+str(e["pause_ok"]))
'
python3 - "$TL" <<'EOF'
import json, sys, datetime
tl = [json.loads(l) for l in open(sys.argv[1])]
def t(k):
    r = next((e for e in tl if e["kind"] == k), None)
    return datetime.datetime.fromisoformat(r["t"]) if r else None
ev = next((e for e in tl if e["kind"] == "event"), None)
if ev and t("detect") and t("enforced"):
    kt = datetime.datetime.fromisoformat(ev["event_time"].replace("Z", "+00:00"))
    print(f"  延迟：内核事件→检测 {(t('detect')-kt).total_seconds():.3}s；"
          f"检测→暂停+拒绝 {(t('enforced')-t('detect')).total_seconds():.3}s")
else:
    print("  （时间线不完整，无法计算延迟）")
EOF
check "sandbox 已暂停" "Phase: Stopped" "$($C $G sandbox get $SB 2>&1)"
check "全局锁生效" "Source:       global" "$($C $G policy get $SB 2>&1)"
pause

step 7 "暂停验证（不经过坏东西测坏东西）" \
     "rm-guard exec 被拒；同一 CLI 通道同一时刻 exec $PC_SB 成功 —— 失败是暂停，不是通道坏"
OUT=$($C $G sandbox exec $SB -- true 2>&1)
check "rm-guard exec 被拒" "not ready" "$OUT"
printf '%s\n' "$OUT" | head -2 | sed 's/^/  /'
OUT=$($C $G sandbox exec $PC_SB -- echo POSITIVE_CONTROL_OK 2>&1)
check "正对照 $PC_SB exec 成功" "POSITIVE_CONTROL_OK" "$OUT"
pause

step 8 "拒绝验证：再起来也是只读" \
     "全局锁在 stop→start 的新实例上施 landlock：写 EACCES，读仍可以（证据保留）"
$C $G sandbox start $SB 2>&1 | tail -1
wait_ready || exit 1
OUT=$($C $G sandbox exec $SB -- sh -c \
  "mkdir $CANARY 2>&1; touch /sandbox/x 2>&1; ls /sandbox >/dev/null && echo READ_OK" 2>&1)
check "写被拒（EACCES）" "Permission denied" "$OUT"
check "读仍可以（证据保留）" "READ_OK" "$OUT"
printf '%s\n' "$OUT" | sed 's/^/  /'
$C $G sandbox stop $SB 2>&1 | tail -1
pause

step 9 "变体：内核直拒（零删除）" \
     "kprobe Override（CONFIG_BPF_KPROBE_OVERRIDE=y + error_injection 白名单）；绝对路径删除逐一 EPERM，计数不降"
$C $G policy delete --global --yes 2>&1 | tail -1
$C $G sandbox start $SB 2>&1 | tail -1
wait_ready || exit 1
OUT=$($C $G sandbox exec $SB -- sh -c \
  "mkdir -p $CANARY; i=0; while [ \$i -lt $N ]; do echo data-\$i > $CANARY/f\$i; i=\$((i+1)); done; ls $CANARY | wc -l" 2>&1)
check_num "新 canary 计数" "$(printf '%s' "$OUT" | tail -1)" eq "$N"
$K apply -f "$D/tracingpolicy-enforce.yaml" >/dev/null
sleep 4
OUT=$($C $G sandbox exec $SB -- sh -c \
  "rm -f $CANARY/f* 2>&1 | head -2; ls $CANARY | wc -l" 2>&1)
check "内核 EPERM 直拒" "Operation not permitted" "$OUT"
check_num "计数不降（零删除）" "$(printf '%s' "$OUT" | tail -1)" eq "$N"
printf '%s\n' "$OUT" | sed 's/^/  /'
echo "  边界：rm -rf 整目录的 dirfd 相对路径删除不在 Override 覆盖内（主链兜底）"
$K delete tracingpolicy rm-guard-enforce >/dev/null 2>&1
pause

step 10 "取证回放" \
     "timeline.jsonl 全程落盘：事件原始字段 + 每步 CLI 命令/输出/时间戳"
kill_responder
python3 - "$TL" <<'EOF'
import json, sys
tl = [json.loads(l) for l in open(sys.argv[1])]
ev = [e for e in tl if e["kind"] == "event"]
print(f"  事件 {len(ev)} 条（file-delete {sum(1 for e in ev if e['message']=='rmguard:file-delete')}）"
      f" + 动作 {sum(1 for e in tl if e['kind'] in ('detect','pause','deny','state','enforced'))} 条")
print("  回放：cat timeline.jsonl | python3 -m json.tool --json-lines（或逐行 jq）")
EOF
echo "  最终状态：$($C $G sandbox get $SB 2>&1 | grep Phase)"
echo "  清场：bash $D/demo.sh --cleanup（删 sandbox/策略/全局锁，保留证据文件）"
echo
if [ "$FAIL" = "0" ]; then echo "═══ 全部通过 ═══"; else echo "═══ 有 ❌，见上 ═══"; fi
exit $FAIL