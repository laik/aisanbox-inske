# rm-guard · supervisor 放行，内核不答应

> sandbox 策略**明确允许**工作区可写，agent 执行 `rm -rf`，**supervisor 批准**
> （OCSF `SSH:OPEN ALLOWED`、零 DENIED、文件真的被删）；Tetragon 在内核逐文件
> 见证，responder 调 **openshell CLI** 把 sandbox **暂停**（stop）并下 **gateway
> 全局锁拒绝**（再起来就是只读）。变体拍：kprobe Override **内核直拒，零删除**。
>
> 环境：`root@192.168.5.190`，kind `kind-agent-runtime-poc`，OpenShell **0.1.7**，
> gateway `os-a`（CLI 名 `poc2-a`，workspace `poc-shared`），Tetragon **1.8.0**，
> 宿主内核 **6.8.0-149-generic**。2026-11-19 实跑 **两轮 10/10 通过**。
> 设计推演见 [`DESIGN.md`](DESIGN.md)（两处被实测修正，见下 §强制边界）。

## 架构

```text
        ┌─────────────────────────── kind node (worker) ───────────────────────────┐
        │  workload Pod: poc-shared--rm-guard         supervisor Pod (boundary-pair) │
        │  ┌─────────────────────────────┐            ┌──────────────────────────┐  │
 openshell│  │ agent: rm -rf /sandbox/canary│           │ 策略 rev1: /sandbox RW    │  │
 sandbox  ┼─→│  landlock 放行（策略允许）     │←─策略加载──│ OCSF SSH:OPEN ALLOWED    │  │
 exec     │  └──────────────┬──────────────┘            │ 零 DENIED                 │  │
        │         sys_execve / sys_unlinkat             └──────────────────────────┘  │
        │                 │ eBPF                                                        │
        │   TracingPolicy rm-guard（租户级：rm-exec 预警 + 绝对路径 delete）              │
        │   TracingPolicy rm-guard-files（pod 级：全量 unlinkat 逐文件见证）             │
        │                 ▼                                                             │
        │   tetragon DaemonSet ──tetra getevents -o json --policy-names rm-guard,rm-guard-files
        └─────────────────┼─────────────────────────────────────────────────────────────┘
                          │ kubectl exec 流（POC 形态；生产形态见 §生产化）
                          ▼
        responder.py（宿主，边界外，持 openshell CLI 凭据；沙箱内拿不到）
          读线程持续排空事件 → timeline.jsonl（取证）
          主线程触发：① sandbox stop（暂停，立即 containment）
                      ② policy set --global lockdown（拒绝，下次启动生效）
```

**为什么是两条检测策略**：GNU `rm -rf` 递归删除走 **dirfd + 相对路径**
（`unlinkat(dirfd, "f93", 0)`），租户级策略的 `Prefix /sandbox/canary` 只能命中
绝对路径调用（顶层目录那一下）。pod 级 `rm-guard-files` 按
`agents.x-k8s.io/sandbox-name-hash` 标签只选这一个 sandbox，不带路径 selector，
把 200 个文件的相对路径删除**全部**记下来（实测 202 条 file-delete）。

## 跑起来

```bash
ssh root@192.168.5.190
# 前置（一次）：kind + tetragon（../tetragon/values.yaml）+ gateway os-a
#   + 镜像 opencode-agent:poc（../opencode-data-agent/build-image.sh）
#   + 一个 Ready 的正对照 sandbox（默认 v-cm，vault demo 遗留；PC_SB=<name> 可换）
bash /root/poc2/rm-guard/demo.sh          # 交互，每拍回车（录屏）
FAST=1 bash /root/poc2/rm-guard/demo.sh   # 连跑回归
bash /root/poc2/rm-guard/demo.sh --cleanup # 清场（保留 timeline.jsonl/responder.log）
```

## 十拍内容（全部实跑验证）

| 拍 | 做什么 | 关键命令 / 判定（实测） |
| --- | --- | --- |
| 0 | 自检 | gateway/tetragon/镜像/正对照/配额（9/10） |
| 1 | 建 sandbox（policy-allow）+ 两条检测策略 | `policy get` rev1 sandbox 级；写探针 `WRITE_OK`（supervisor 放行）；`tetra tracingpolicy list` 两条 enabled |
| 2 | 启动 responder | **探针正对照**：无害写删 `.rmguard-probe`，亲眼看到事件穿过来才宣布 `listening` |
| 3 | 种 canary 200 文件 | 计数 = 200（正对照） |
| 4 | **攻击** `rm -rf /sandbox/canary` | 计数 200→0；supervisor `SSH:OPEN ALLOWED`、零 DENIED |
| 5 | Tetragon 逐文件见证 | **202 条 file-delete** + rm-exec 预警；binary/argv/uid/pod 齐全 |
| 6 | **CLI 强制** | stop ✓（2.4s）→ 全局锁 ✓；内核事件→检测 **5ms**，检测→暂停+拒绝 **2.7s** |
| 7 | 暂停验证 + 正对照 | rm-guard exec 被拒（`not ready`）；**同一通道同一时刻** v-cm exec 成功 |
| 8 | 拒绝验证 | stop→start 新实例：`mkdir`/`touch` **Permission denied**；读仍 OK（证据保留） |
| 9 | **变体：内核直拒** | kprobe Override：`rm -f canary/f*` 逐一 **Operation not permitted**，计数**不降**（200） |
| 10 | 取证回放 | timeline.jsonl：203 事件 + 5 动作，全程时间戳 |

## 强制边界（0.1.7 实测，本 POC 的核心新发现）

设计原本假设"live policy 收紧 = 拒绝"，实测**三处不成立**，强制链因此定型：

| 试过的路 | 实测结果 | 结论 |
| --- | --- | --- |
| `sandbox suspend` | `compute driver does not support sandbox suspend` | kubernetes driver 不支持 → **回退 stop**（保 workspace PVC，不保内存态） |
| sandbox 级 `policy set` 移除 RW 路径 | `read_write path '/sandbox' cannot be removed on a live sandbox`（**Stopped 也报**） | live policy **只增不减**；`include_workdir` 也不能改 |
| 全局锁后直接写运行中实例 | 仍 `WRITE_OK`（supervisor 已 `Policy reloaded successfully (global)`） | **FS 权限是实例启动时施的 landlock**，运行中实例不受后续策略变更影响 |
| **stop → start（全局锁下）** | `mkdir`/`touch` **Permission denied**，读 OK | ✅ 拒绝生效路径 = 停掉肇事者 + 全局锁（新实例只读） |

所以 responder 的强制顺序是 **先暂停后拒绝**：
1. `sandbox stop rm-guard` —— 立即 containment，exec 通道当场拒（`not ready`）；
2. `policy set --global --policy policy-lockdown.yaml --yes` —— gateway 全局锁，
   肇事 sandbox **下次 start** 即只读。运行中的其它 sandbox 不受影响（landlock 实例级）。

**全局锁的影响面**：整个 gateway 的 sandbox 的**下次启动**都会被锁只读，直到
`policy delete --global --yes` 解锁。demo 第 9 拍开头解锁、`--cleanup` 也解锁。
生产里这是"紧急制动"语义，要配审计与自动解锁流程（见 §生产化）。

**诚实边界（demo 明说）**：带外环有秒级延迟，`rm -rf` 在暂停生效前已删完
（200→0）。本场景判定是"**批准被撤销 + 沙箱暂停 + 后续被拒 + 证据保留**"，
不是"零删除"。**零删除**是第 9 拍的内核直拒变体（同步 Override，删除 syscall
当场 EPERM），两条链互补，不混淆。

## 内核直拒变体的前提（第 9 拍）

- 宿主 `CONFIG_BPF_KPROBE_OVERRIDE=y`，且 `__x64_sys_unlinkat` 在
  `/sys/kernel/debug/error_injection/list`（ERRNO）→ **kprobe Override 可用**。
- 但 LSM 列表仍无 `bpf`（`lockdown,capability,landlock,yama,apparmor`）→
  **lsm hooks 依旧不可用**，所以走 kprobe 而非 lsm（与 ../tetragon/values.yaml 一致）。
- tetragon 需 `--disable-kprobe-multi`（values 已配）。
- 覆盖边界：Override 的 `Prefix /sandbox/canary` 同样只命中**绝对路径** unlinkat。
  变体攻击用 `rm -f /sandbox/canary/f*`（glob 展开绝对路径）→ 200 个逐一 EPERM。
  `rm -rf` 整目录的相对路径删除不在覆盖内 —— 主链（execve 预警 + CLI）兜底。

## 文件地图

| 文件 | 用途 |
| --- | --- |
| `demo.sh` | 十拍 demo / 回归 / --cleanup |
| `responder.py` | 事件→CLI 强制环；读线程排空+主线程强制；timeline.jsonl |
| `policy-allow.yaml` | 初始策略：`/sandbox` RW（supervisor 放行的来源） |
| `policy-lockdown.yaml` | 全局锁拒绝策略：`include_workdir: false` + 全只读 |
| `tracingpolicy.yaml` | 租户级检测：rm-exec 预警 + 绝对路径 file-delete |
| `tracingpolicy-files.yaml.template` | pod 级逐文件见证（`__HASH__` 由 demo 替换） |
| `tracingpolicy-enforce.yaml` | 变体：kprobe Override 内核直拒 |
| `DESIGN.md` | 设计推演（含实测后记） |

## 实测坑（这次新撞的）

1. **gRPC 流附着窗口**：`kubectl exec … tetra getevents` 进程起来 ≠ 在听，
   流要 1~2s 才挂上。不探针就宣布就绪，攻击事件落在窗口里**全丢**（第一轮回归
   0 事件）。responder 周期性发无害探针删除，**亲眼看到一条**才 `listening`。
2. **enforce 阻塞丢事件**：stop+全局锁阻塞主线程 ~3s，期间 200 条删除事件涌来，
   串行读会撑爆 64KB 管道缓冲。改**读线程持续排空 + 主线程强制**，202 条全落盘。
3. **`pipefail` + `grep -q` 误判**：`cmd | grep -q` 在 pipefail 下，grep 提前退出
   让上游吃 SIGPIPE，大输出时把**通过的断言判成失败**（镜像自检一度误报）。
   全部改 herestring（`grep -q … <<< "$out"`）。
4. **`policy get` 不回显规则正文**：只给 Version/Hash/Status/Source。"工作区可写"
   要用**写探针**证明，不能 grep policy get 输出。
5. **`policy delete` 要 `--global`**：删全局锁是 `policy delete --global --yes`，
   裸 `policy delete` 报 "sandbox policy delete is not supported"。
6. **GNU rm 相对路径删除**：见 §架构，逐文件见证必须 pod 级全量策略。
7. **配额是 Tenant 级跨 namespace 拆分**：`tenant-a` 总额 10，gateway 占 1，
   runtime 只剩 9。直接 patch RQ 被 Capsule webhook 拒（controller-managed），
   且 reconciler 会把 spec 拉回；正确做法是改 **Tenant** 的
   `spec.resourceQuotas.items[0].hard.persistentvolumeclaims`（本次 10→11，
   runtime 拿到第 10 位）。

## 生产化备注

- responder 应为集群内 Deployment：专用 SA（只读 pods + tetragon gRPC，或
  exec tetragon 的 RBAC），openshell 凭据走边界外 Secret。沙箱内**永远拿不到**
  这条链的凭据（0.1.7 禁投影 SA token，见 ../vault/README.md）。
- 多租户：每租户一条 TracingPolicy（换租户标签）+ 每 gateway 一个 responder；
  timeline 进 SIEM，与 supervisor OCSF 流按 `pod.name`/`boundary-pair` join
  （见 ../docs/POC2-CONCLUSIONS.md POC-11）。
- **全局锁是紧急制动**：影响整个 gateway 的下次启动，生产必须配审计、告警与
  自动解锁/审批流程，不能 demo 这样手动 `policy delete` 收尾。
- 内核直拒依赖宿主 `CONFIG_BPF_KPROBE_OVERRIDE` + error_injection 白名单，
  属交付前提，开通检查要验（同 LSM 前提，见 POC2 结论 §7.3）。
- 若要"运行中即时收回 FS 写权限"，0.1.7 做不到（landlock 实例级 + live policy
  只增不减）；需要 stop→start 或重建。这是平台能力边界，不是策略写错。