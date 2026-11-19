# rm-guard · 设计文档 —— supervisor 放行，内核不答应

> **实测后记（2026-11-19）**：验证完成，最终结论与逐拍回放见 [`README.md`](README.md)。
> 设计有两处被实测修正：① 0.1.7 的 sandbox 级 live policy **只增不减**，
> "拒绝"改为 **stop + gateway 全局锁**（顺序：先暂停后拒绝）；② suspend 在
> kubernetes compute driver 上不支持，回退 stop。检测侧增加了 pod 级
> `rm-guard-files` 策略（逐文件见证，201 事件实测）。

> 场景：sandbox 里执行 `rm -rf`，**supervisor（带内策略面）批准了这个动作**；
> Tetragon（带外内核观测面）拦截到危险调用， responder 调 **openshell CLI**
> 直接拒绝（live policy 收紧）并**暂停 sandbox**（suspend，失败则 stop）。
>
> 目标环境：`root@192.168.5.190`，kind `kind-agent-runtime-poc`，OpenShell **0.1.7**，
> gateway `os-a`（CLI 名 `poc2-a`，workspace `poc-shared`），Tetragon **1.8.0**。
> 交付物：逐帧（逐拍）回放的 demo.sh + 实测证据，风格同 `../opencode-data-agent/`。

## 1. 要证明什么（以及不证明什么）

**证明**：带内批准 ≠ 最终放行。即使 supervisor 按策略批准了破坏性动作，
平台仍有一条**沙箱内进程不可绕过、不可关闭**的带外强制链：

```text
内核 syscall ──eBPF──→ Tetragon 事件 ──→ responder ──openshell CLI──→ ① policy set 拒绝
                                                                      ② sandbox suspend 暂停
```

**不证明**（诚实边界，demo 里明说）：
- 带外环有延迟（秒级）。`rm -rf` 本身可能在暂停生效前已删完部分/全部文件。
  本场景的判定是"**批准被撤销、沙箱被暂停、后续动作被拒、证据被保留**"，
  不是"零删除"。删除量用**计数差**实测并如实展示。
- 零删除的"硬拒绝"是另一个变体（§6 内核直拒拍）：该宿主内核
  `CONFIG_BPF_KPROBE_OVERRIDE=y` 且 `__x64_sys_unlinkat` 在 error_injection
  白名单里，kprobe + Override/Sigkill **可能**可用（lsm hook 仍不可用，
  LSM 列表无 bpf，见 `../tetragon/values.yaml`）。实测后单独成拍，不与主链混淆。

## 2. 架构与组件

```text
                 ┌────────────────────────── kind node (worker) ─────────────────────────┐
                 │  workload Pod: poc-shared--rm-guard        supervisor Pod (boundary-pair)│
                 │  ┌────────────────────────────┐            ┌─────────────────────────┐ │
   openshell     │  │ agent: rm -rf /sandbox/canary│           │ 策略 rev1: /sandbox RW   │ │
   sandbox exec ─┼─→│  landlock 放行（策略允许）    │←─策略加载──│ OCSF SSH:OPEN ALLOWED   │ │
                 │  └─────────────┬──────────────┘            └─────────────────────────┘ │
                 │        sys_execve / sys_unlinkat                                          │
                 │                │ eBPF（TracingPolicy: rm-guard）                          │
                 │                ▼                                                          │
                 │  tetragon DaemonSet Pod ──tetra getevents -o json --policy-names rm-guard │
                 └────────────────┼──────────────────────────────────────────────────────────┘
                                  │ kubectl exec 流（POC 形态；生产形态见 §7）
                                  ▼
                 responder.py（宿主，边界外，持 openshell CLI 凭据）
                   1) pod.name → sandbox 名（去掉 "poc-shared--" 前缀）
                   2) openshell policy set rm-guard --policy policy-lockdown.yaml --wait   ← 拒绝
                   3) openshell sandbox suspend rm-guard（不支持则 stop）                   ← 暂停
                   4) timeline.jsonl：t_detect / t_deny / t_pause / 每步 CLI 输出
```

组件与文件（本目录）：

| 文件 | 用途 |
| --- | --- |
| `policy-allow.yaml` | sandbox 初始策略：`/sandbox` **read_write**（supervisor 会放行 rm） |
| `policy-lockdown.yaml` | responder 推送的拒绝策略：全只读 + 工作区只读（rev2） |
| `tracingpolicy.yaml` | Tetragon `rm-guard`：execve(rm -rf canary) 早期预警 + unlinkat(canary) 逐文件见证 |
| `responder.py` | 事件→CLI 强制环；写 `timeline.jsonl`；`--once`（demo）/`--loop` |
| `demo.sh` | 逐拍 demo：交互回车（录屏）/ `FAST=1` 回归 / `--cleanup` |
| `README.md` | 实测后的回放文档（拍表 + 证据 + 坑），验证完成后生成 |

### 2.1 检测策略（tracingpolicy.yaml）

两条 kprobe（**不用 lsmhooks** —— 该宿主 LSM 无 bpf，lsm 策略加载必失败）：

1. `sys_execve`：binary ∈ {/usr/bin/rm, /bin/rm}，matchCmdArgs 命中
   `-rf/-fr/-r/-f/--recursive/--force` 且目标 Prefix `/sandbox/canary`
   → message `rmguard:rm-rf-exec`（早期预警，删除发生前）。
2. `sys_unlinkat`：args[1]（pathname）Prefix `/sandbox/canary`
   → message `rmguard:file-delete`（逐文件见证，任何删除工具都逃不掉）。

podSelector：`openshell.ai/boundary-role=workload` + `projectcapsule.dev/tenant=tenant-a`
（平台级：一条策略看住整租户 workload；canary 路径只有 demo sandbox 有，无误报）。
responder 再按 `pod.name == poc-shared--rm-guard` 精确过滤。

已知边界（写进 README）：unlinkat 的 pathname 若是**相对路径**（先 cd 再删），
Prefix 匹配不到 —— demo 用绝对路径；生产要补 dirfd 解析或按 execve 链归因。

### 2.2 "supervisor 批准"的证据链（实测口径）

supervisor **不会**为每个被放行的文件操作打 OCSF 行（实测：放行删除只留下
exec 通道的 `OCSF SSH:OPEN [INFO] ALLOWED`，无 FILE:DELETE 行）。所以"批准"用三件事证明：

1. `openshell policy get rm-guard` → rev1 明确 `read_write: [/sandbox]`；
2. supervisor 日志：该次 exec 的 `SSH:OPEN ALLOWED`，且**无任何 DENIED**；
3. 动作真实成功：canary 计数下降（正对照：攻击前计数 = 200）。

### 2.3 强制环（responder.py）

- 事件源：`kubectl exec -n kube-system <tetragon-pod-on-node> -c tetragon --
  tetra getevents -o json --policy-names rm-guard`。
  tetragon pod 按 `spec.nodeName` 选（事件是节点级的，sandbox 在哪个 node 就听哪个）。
- 触发：`process_kprobe` 且 `policy_name=rm-guard` 且 pod 名匹配 → 记 `t_detect`，
  同一 sandbox 只触发一次（去重）。
- 动作顺序：**先拒绝后暂停** —— `policy set --wait`（确保 rev2 已加载）再
  `suspend`；suspend 报不支持时回退 `stop`（保 workspace，不保内存态），实测结果写 README。
- 全程落 `timeline.jsonl`（事件原始 JSON + 每步 CLI 命令/输出/时间戳），供逐帧回放。

### 2.4 暂停/拒绝的验证（不经过坏东西测坏东西）

- 暂停成立：`sandbox get rm-guard` phase = Suspended（或 Stopped）；
  `sandbox exec rm-guard -- true` **失败**。
  **正对照**：同一 CLI 通道同一时刻 exec 另一个 Ready sandbox（v-cm）成功 ——
  证明失败是"沙箱被暂停"，不是通道坏了。
- 拒绝成立：`sandbox resume`（或 start）后，再执行写/删 → **EACCES**；
  `policy get` 显示 rev2 lockdown。注意 landlock 的 FS 拒绝发生在内核，
  supervisor 不一定有 OCSF DENIED 行 —— 证据以 errno + policy 版本为准。

## 3. 前置与配额

- gateway 通道：`127.0.0.1:18441` port-forward（demo.sh 第 0 拍自愈拉起）。
- **PVC 配额 9/9 已满**（实测 2026-11-19）。每个 sandbox 占一个 workspace PVC。
  本 demo 需要 1 个新 sandbox `rm-guard`。候选腾位方案（执行前与用户确认）：
  a) 删 `da-agent`（已 Completed；其 demo.sh 本来就每轮先删后建，损失最小）；
  b) 删 vault demo 的某个 sandbox（v-sec/v-cm/v-ksec 是 vault README 的活证据，不建议）；
  c) 调高 Capsule 租户配额（会削弱 opencode demo 第 0 拍"配额拦截"的叙事）。
- 镜像：复用 kind 里已有的 `opencode-agent:poc`（含 coreutils rm）。
- Tetragon 已运行（3 pod），`tetra getevents` 可用（实测）。
  若集群重启过，先确认 `--disable-kprobe-multi` 等 values 仍在（`../tetragon/values.yaml`）。

## 4. 逐拍步骤（demo.sh，录屏用）

| 拍 | 做什么 | 判定（全部确定性，不依赖模型） |
| --- | --- | --- |
| 0 | 自检：gateway/tetragon/镜像/配额 | whoami 通；tetragon pod Running；配额有空位 |
| 1 | 部署 TracingPolicy + 启动 responder | tracingpolicy 建立；responder 日志出现 "listening" |
| 2 | 建 sandbox rm-guard（policy-allow） | phase Ready；`policy get` rev1 含 `/sandbox` RW |
| 3 | 种 canary：200 个文件 | exec 计数 = 200（正对照） |
| 4 | **攻击**：`rm -rf /sandbox/canary` | exec 成功返回；supervisor SSH:OPEN ALLOWED 无 DENIED；计数差实测 |
| 5 | Tetragon 证据 | responder 收到 rm-rf-exec + N 条 file-delete，pod/uid/binary/argv 齐全 |
| 6 | **CLI 强制** | timeline：policy set rev2 ✓ → suspend ✓；t_detect→t_pause 延迟实测 |
| 7 | 暂停验证 + 正对照 | rm-guard exec 失败；v-cm exec 成功；phase=Suspended/Stopped |
| 8 | 拒绝验证 | resume/start 后写/删 EACCES；policy get = rev2 lockdown；再暂停 |
| 9 | （变体）内核直拒 | rm-guard-enforce：kprobe Override/Sigkill；新 canary 计数**不降**；不支持则如实记录 |
| 10 | 取证回放 + 清场指引 | timeline.jsonl 全量展示；`--cleanup` 说明 |

每拍：`step N` 标题 + "证明什么" + 命令回显 + `check` 断言 + 回车暂停（FAST=1 连跑）。

## 5. 验证计划（写 demo 前先逐项实测）

1. `sandbox suspend` 在该 compute driver 上是否支持（用 rm-guard 实测；不支持→stop 回退）。
2. `policy set --wait` live 收紧是否即时生效（resume 后 EACCES）。
3. TracingPolicy 两条 kprobe 在 6.8.0-149 + disable-kprobe-multi 下加载成功且命中。
4. responder 端到端延迟（t_detect→t_pause）与 canary 计数差。
5. 变体：kprobe `action: Override argError: -1` / `Sigkill` 是否加载并生效
   （error_injection 白名单已确认含 __x64_sys_unlinkat；**未实测**）。
6. 正对照全部通过（§2.4）。

## 6. 风险与回退

| 风险 | 回退 |
| --- | --- |
| suspend 不支持 | stop（保 workspace）；README 明示差异 |
| resume 不支持 | start；再不行则重建 sandbox 验证 rev2（policy 持久在 gateway） |
| kprobe Override 加载失败 | 第 9 拍降级为"观测-only 已证"，如实记录报错 |
| rm 在暂停前删完 canary | 如实展示计数差；叙事重点是撤销+暂停+拒后续，不是零删除 |
| 配额腾位误删 | 执行前与用户确认（§3）；--cleanup 只删本 demo 自建资源 |

## 7. 生产化备注

- responder 应为集群内 Deployment：专用 SA（只读 pods + exec tetragon 的 RBAC，
  或直连 tetragon gRPC service），openshell 凭据走边界外 Secret；
  沙箱内**永远拿不到**这条强制链的任何凭据（0.1.7 禁投影 SA token，见 ../vault/README.md）。
- 多租户：每租户一条 TracingPolicy（podSelector 换租户标签）+ 每 gateway 一个
  responder 实例；timeline 进 SIEM（OCSF 对齐 supervisor 流，join 键 = pod.name/boundary-pair，
  见 ../docs/POC2-CONCLUSIONS.md POC-11）。
- 内核直拒（第 9 拍变体）依赖宿主 `CONFIG_BPF_KPROBE_OVERRIDE` + error_injection
  白名单，属交付前提，开通检查要验（同 LSM 前提，见 POC2 结论 §7.3）。