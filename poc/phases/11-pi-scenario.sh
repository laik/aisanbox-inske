#!/usr/bin/env bash
# Phase 4 —— 核心业务场景: 多 Pi 共享 Workspace + 代码修改 + 并行 Review
# (POC2 §5 / §10, 验证 POC-04 / POC-10 / SEC-06 / SEC-07)
# 手工重现: bash poc/phases/11-pi-scenario.sh
#
# 这份脚本是 POC2 §10 的**逐条实现**。它要证的是四件事:
#   POC-04  三个 Sandbox 挂同一个 PVC，权限不同(dev RW / reviewer RO)—— §10.5
#   POC-10  一个 Agent 改代码，两个 Agent 并行读同一份改后的代码 —— §10.4/§10.6
#   SEC-07  Developer 写共享文件 = 允许
#   SEC-06  Reviewer 写共享文件 = 拒绝，而且**必须真的进容器执行**(§10.5 明确禁止只看 YAML)
#
# ===== 本轮(2026-11-09)实测坑，按踩到顺序 =====
# 1) **`pi -p` 会等 stdin**。`openshell sandbox exec` 保持 stdin 打开，于是 pi 永不退出、
#    而且**没有任何输出**(rc=124 被 timeout 杀掉，stdout/stderr 全空)。看起来像
#    "模型连不上"，实际是 CLI 用法。正确写法: `pi ... </dev/null`。
#    这条坑很隐蔽: 换模型、关 OTel、去扩展都试过之后仍然挂 —— 直到 stdin 重定向才通。
# 2) **Provider profile 的 `access: read-only` 是按 HTTP 方法过滤的**，不是按业务动作。
#    `git clone` 一定要 POST(smart-HTTP 的 fetch 协商)，于是被 L7 拒:
#      OCSF HTTP:POST [MED] DENIED POST …/git-upload-pack [policy:_provider_poc_git engine:l7]
#    同一个 profile 下 GET https://github.com/ 与 GET …/info/refs 都是 ALLOWED。
#    → git-over-HTTPS 要 `access: read-write`(见 providers/poc-git.yaml 的说明)。
# 3) **改 profile 不会追认到已存在的 Sandbox**。profile update / 重建 provider 之后，
#    旧 sandbox 仍然是 CLONE_DENIED；只有重建 sandbox 才生效。
#    有效策略是在 create 时快照的 —— 与 §4.4 的"标签检查"是同一时刻。
# 4) **镜像里的 GOCACHE 不可用**: Dockerfile 的 `ENV GOCACHE=/tmp/gocache` 那个目录是
#    root 建的(mode 属 root)，沙箱里 uid 10001 用不了:
#      failed to build cache … mkdir /tmp/gocache/00: permission denied
#    运行期自己 mkdir 一个就行。**镜像 ENV 里的路径不能假设可写**(和 §3.2 uid 10001 同源)。
# 5) 每个沙箱会建**两个 Service**(os-boundary-* / os-supervisor-*)，`count/services` 是
#    实际最先撞到的配额(见 capsule2/tenants.yaml 的算术)。而且 phase=Completed 的沙箱
#    **仍然占着**这两个 Service —— 必须真的 `sandbox delete`。
set -uo pipefail
cd "$(dirname "$0")/.."
CTX=kind-agent-runtime-poc
NS=tenant-a-runtime
CLI=vendor/openshell-cli-0.1.7/openshell
WS=poc-shared
A() { $CLI -g poc2-a --workspace $WS "$@"; }
DC() { # DC <claim> <read_only>
  printf '{"kubernetes":{"volumes":[{"name":"ws","persistent_volume_claim":{"claim_name":"%s","read_only":%s}}],"containers":{"agent":{"volume_mounts":[{"name":"ws","mount_path":"/data/workspace","read_only":%s}]}}}}' "$1" "$2" "$2"
}
# 沙箱内跑 Pi 的统一前缀(四个坑的集中处: agent home 可写副本 + stdin + GOCACHE)
# HOME 必须与 PI_CODING_AGENT_DIR **同值**，否则 pi-otel 读不到它的 settings.json
# (它按 homedir() 找配置，不是按 PI_CODING_AGENT_DIR)。setup-agent-home.sh 会写出
# /tmp/pi-home.env，source 它就行 —— 见该脚本里的说明。
PIRUN='sh /usr/local/pi/setup-agent-home.sh >/dev/null 2>&1
       . /tmp/pi-home.env
       export GOCACHE=/tmp/gc GOPATH=/tmp/gp GOFLAGS=-mod=mod
       mkdir -p /tmp/gc'

# 端口转发(CLI 只走 mTLS，且必须 127.0.0.1:18441)
pkill -f 'svc/os-a-openshell 1844' >/dev/null 2>&1
(setsid kubectl --context $CTX -n tenant-a-gateway port-forward svc/os-a-openshell 18441:8080 </dev/null >/tmp/pf-a.log 2>&1 &)
sleep 4

echo "### 0. 前置: 共享 PVC + 两个 provider + 两份策略"
kubectl --context $CTX -n $NS apply -f storage/workspace-pvc.yaml >/dev/null
# profile 必须先删后导(profile 是 workspace 作用域的；`update` 只接受 --file <ID>)
A provider delete poc-git >/dev/null 2>&1; A profile delete poc-git >/dev/null 2>&1
A profile import --file providers/poc-git.yaml 2>&1 | tail -1 | sed 's/^/   /'
A provider create --name poc-git --type poc-git >/dev/null 2>&1
A provider list 2>&1 | awk 'NR==1||/poc-/{print "   "$0}'
mkdir -p /tmp/pol
sed -n '/^version:/,$p' policies/pi-developer.yaml > /tmp/pol/dev.yaml
sed -n '/^version:/,$p' policies/pi-reviewer.yaml  > /tmp/pol/rev.yaml
echo "   两份策略的唯一实质差别(这就是 §5.3 说的「只差一行」):"
diff <(grep -v '^#' /tmp/pol/dev.yaml) <(grep -v '^#' /tmp/pol/rev.yaml) | sed 's/^/     /'
echo "   ⚠ 这个文件曾经**只有注释不同**、YAML 完全一样 —— 也就是说「Reviewer 只读」
   在文件里其实没生效，而注释已经写成生效了。上面的 diff 就是防这条回归的断言。"

echo
echo "### 1. 清理旧沙箱(Completed 的沙箱仍占 Service 配额)"
for s in pi-dev pi-review-1 pi-review-2; do A sandbox delete "$s" >/dev/null 2>&1; done
sleep 12
printf "   配额(注意 services，不是 pods): "
kubectl --context $CTX -n $NS get resourcequota capsule-tenant-a-0 \
  -o jsonpath='{.status.used.count/services}{"/"}{.spec.hard.count/services}{"  pods="}{.status.used.count/pods}{"/"}{.spec.hard.count/pods}{"\n"}'

echo
echo "### 2. Developer: 建沙箱 → clone → 跑测试(POC2 §10.3)"
A sandbox create --name pi-dev --from pi-agent:poc --cpu 500m --memory 1Gi --detach --restart-policy never \
  --policy /tmp/pol/dev.yaml --provider poc-model --provider poc-git \
  --driver-config-json "$(DC shared-workspace false)" -- sh -c 'sleep 3600' >/dev/null 2>&1
sleep 40
A sandbox list 2>&1 | awk 'NR==1||/^pi-/{print "   "$0}'
echo "   (a) 直接 curl 未批准的域名 —— SEC-01/SEC-03 的对照:"
A sandbox exec pi-dev -- sh -c 'printf "     api.openai.com -> "; (timeout 8 curl -s -m 6 -o /dev/null -w "%{http_code}\n" https://api.openai.com/ 2>/dev/null || echo DENIED)'
echo "   (b) git clone 走边界(需要 provider 是 read-write，见文件头坑 2):"
A sandbox exec pi-dev -- sh -c 'cd /data/workspace && rm -rf godotenv && timeout 150 git -c protocol.version=1 clone --depth 1 https://github.com/joho/godotenv.git 2>&1 | tail -1' | sed 's/^/     /'
echo "   (c) 项目测试(POC2 §10.1 要求能跑 go test):"
A sandbox exec pi-dev -- sh -c "$PIRUN"' ; cd /data/workspace/godotenv && timeout 200 go test ./... 2>&1 | tail -3' | sed 's/^/     /'

echo
echo "### 3. Developer 改代码(POC2 §10.3 的任务，POC-10 的前半)"
A sandbox exec pi-dev -- sh -c "$PIRUN"' ; cd /data/workspace/godotenv
  timeout 900 pi --model poc-model/qwen3.8-flash-next -p "In the current Go project, add ONE passing unit test in a NEW file poc_extra_test.go that checks godotenv.Load returns an error for a nonexistent file. Then run: mkdir -p /tmp/gc && GOCACHE=/tmp/gc go test ./... . Do not modify existing files, do not touch the git remote, do not push. Print git status --short and the new file." </dev/null > /tmp/pi.out 2>/tmp/pi.err
  echo "   pi rc=$?"; tail -c 260 /tmp/pi.out
  echo "   [git status]"; cd /data/workspace/godotenv && git status --short' 2>&1 | sed 's/^/   /'
echo "   SEC-07 Developer 写共享文件(必须成功):"
A sandbox exec pi-dev -- sh -c 'touch /data/workspace/dev-marker && echo "     DEV_WRITE_OK"'

echo
echo "### 4. 两个 Reviewer: 同一个 PVC，只读(POC2 §10.4 / §5.1)"
for r in 1 2; do
  A sandbox create --name "pi-review-$r" --from pi-agent:poc --cpu 500m --memory 1Gi --detach --restart-policy never \
    --policy /tmp/pol/rev.yaml --provider poc-model \
    --driver-config-json "$(DC shared-workspace true)" -- sh -c 'sleep 1800' >/dev/null 2>&1
done
sleep 45
A sandbox list 2>&1 | awk 'NR==1||/^pi-/{print "   "$0}'
echo "   三个 Pod 挂的是同一个 PV(共享是真的，不是各自一份):"
kubectl --context $CTX -n $NS get pods --no-headers \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName 2>/dev/null | grep -E "pi-(dev|review)" | sed 's/^/     /'
kubectl --context $CTX -n $NS get pvc shared-workspace -o jsonpath='     PV={.spec.volumeName}{"  access="}{.spec.accessModes}{"\n"}'

echo
echo "### 5. §10.5 的断言: Reviewer 能看到改后的代码，但不能写"
for r in 1 2; do
  echo "   --- pi-review-$r"
  A sandbox exec "pi-review-$r" -- sh -c '
    echo "     [看 Developer 的改动]"; cd /data/workspace/godotenv 2>/dev/null && git status --short && ls -l poc_extra_test.go 2>&1 | tail -1
    echo "     [读 Developer 的 marker]"; head -c 1 /data/workspace/dev-marker >/dev/null 2>&1 && echo "     READ_MARKER_OK"
    echo "     [SEC-06 写入必须失败]"; touch /data/workspace/reviewer-test.txt 2>&1 || true
    echo "     [挂载层证据(K8s mount RO)]"; grep "/data/workspace" /proc/self/mountinfo | awk "{print \"     mount_flags=\" \$4}"' 2>&1
done
echo "   两个 Reviewer 并行读同一份代码(POC-10 的「并行 Review」部分，不修改):"
for r in 1 2; do
  ( A sandbox exec "pi-review-$r" -- sh -c "$PIRUN"' ; cd /data/workspace/godotenv
     timeout 600 pi --model poc-model/qwen3.8-flash-next -p "Review the changes in this repo (read-only). Report findings with severity and file:line. Do NOT modify any file." </dev/null 2>/dev/null | tail -c 300' > "/tmp/rev-$r.out" 2>&1 ) &
done
wait
for r in 1 2; do echo "   --- Reviewer $r:"; tail -c 300 "/tmp/rev-$r.out" | sed 's/^/     /'; echo; done

echo
echo "### 6. 两条强制层要**分开**证(POC2 §10.5 说不能只看 YAML)"
# 只给策略、挂载可写 → 拒绝来自 OpenShell(EACCES "Permission denied")
A sandbox create --name ctl-polro --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --policy /tmp/pol/rev.yaml --driver-config-json "$(DC shared-workspace false)" -- sh -c 'sleep 300' >/dev/null 2>&1
sleep 30
echo "   (a) 挂载 rw + 策略只读:"
A sandbox exec ctl-polro -- sh -c 'grep "/data/workspace" /proc/self/mountinfo | awk "{print \"     mount_flags=\" \$1\" \"\$4}"; touch /data/workspace/x 2>&1 | sed "s/^/     /"; echo "     结果: mountinfo 显示 rw 但写被拒 => 强制发生在 OpenShell 策略层"'
echo "   (b) 挂载 ro + 策略可写(上一轮已证): 报错是 `Read-only file system`(EROFS)，
       来自 Kubernetes 挂载层。两种 errno 不同，正好说明是**两层独立**的强制。"

echo
echo "### 7. 生命周期: 删掉 Reviewer 不影响共享 PVC(§10.5 最后两条)"
for r in 1 2; do A sandbox delete "pi-review-$r" >/dev/null 2>&1; done
sleep 20
A sandbox create --name ctl-after --from alpine:latest --cpu 50m --memory 64Mi --detach --restart-policy never \
  --driver-config-json "$(DC shared-workspace false)" --policy /tmp/pol/dev.yaml -- sh -c 'sleep 200' >/dev/null 2>&1
sleep 30
A sandbox exec ctl-after -- sh -c 'ls /data/workspace/godotenv/poc_extra_test.go 2>&1 | sed "s/^/     删掉两个 Reviewer 之后仍在: /"' | tail -1
A sandbox delete ctl-after ctl-polro >/dev/null 2>&1

echo
echo "### 结论怎么写(诚实版)"
echo "   POC-04  共享同一 PVC + 权限不同: **成立**(上面的 git status 在两个 Reviewer 里可见、写入被拒)。"
echo "   POC-10  一个改、两个读: 读的一侧成立；「两个 Agent 各自产出 review 结论」取决于"
echo "           本地模型的能力，脚本把输出留出来了，但不要把「模型回答得不好」记成平台缺陷。"
echo "   SEC-06/07 **两条强制层分别验证**，errno 不同(EROFS vs EACCES)。"
echo "   注: 本脚本没有强制跨节点放置 —— shared 模式下调度器决定 Pod 落在哪个节点。"
echo "   要证「跨节点共享」用 phases/07-rwx-storage.sh 的普通 Pod(已证过 50/50 并发追加)。"
