# opencode 数据 Agent · OpenShell 全流程 demo

> 一个 AI 数据 Agent（opencode）跑在 OpenShell sandbox 里：读 **ConfigMap** 里的
> 临时配置，用 **Vault** 渲染的数据库管理密码查 **PostgreSQL**，结果写共享 **PVC**，
> 模型凭据走 OpenShell **profile/provider** 代理 —— sandbox 里只有占位 key。
>
> 环境：`root@192.168.5.190`，kind `kind-agent-runtime-poc`，OpenShell **0.1.7**，
> gateway `os-a`（workspace `poc-shared`），opencode **1.19.6**，模型为宿主 Strata
> （`qwen3.8-flash-next`，OpenAI 兼容 :8080）。2026-11-18 实跑 **10/10 通过**。
> 挂载机制的实测依据见 [`../vault/README.md`](../vault/README.md)（0.1.7 禁止
> workload 持投影 SA token，所以 Vault 走边界外渲染 + 标签 PVC）。

## 架构

```text
Vault KV secret/tenant-a/db-admin ──(da-render Job, 边界外)──→ PVC(密钥文件)
                                                                 │ Assign 挂载
ConfigMap da-config(临时配置) ─────────────── Assign 挂载 ──→   │
Secret da-report-token(静态) ──────────────── Assign 挂载 ──→   ▼
                                              ┌─────────────────────────────┐
PVC da-output ←──查询结果──────────────────── │ sandbox: opencode-agent:poc │
                                              │  psql ──→ da-db (PostgreSQL)│
Strata :8080 ←─(supervisor 代理, 换真实 key)── │  opencode ──→ 模型          │
                                              │  env: 占位 OPENAI_API_KEY   │
                                              └─────────────────────────────┘
profile da-model 声明: 哪个二进制(opencode.exe/curl) 能去哪个端点(192.168.5.190:8080)
```

## 跑起来

```bash
ssh root@192.168.5.190
# 前置（一次）：../vault 的 Vault 安装 + 10/15 脚本；然后构建镜像：
bash /root/poc2/opencode-data-agent/build-image.sh
# demo：
bash /root/poc2/opencode-data-agent/demo.sh          # 交互，每拍回车（录屏）
FAST=1 bash /root/poc2/opencode-data-agent/demo.sh   # 连跑回归
bash /root/poc2/opencode-data-agent/demo.sh --cleanup
```

## 十拍内容（全部实跑验证）

| 拍 | 做什么 | 关键 openshell 命令 / 判定 |
| --- | --- | --- |
| 0 | 自检 + 配额拦截 | Vault/gateway/镜像；PVC 配额满提前退出 |
| 1 | 部署 DB，管理密码存 Vault | `10-vault-db-admin.sh`（幂等复用密码） |
| 2 | CM/Secret/PVC + 渲染 Job | `da-render` 把 db-admin 写进 PVC |
| 3 | **profile import + provider create** | `profile import --file providers/da-model.yaml`；`provider create --name da-model --type da-model --credential OPENAI_API_KEY=<key>` |
| 4 | **sandbox create** | `--from opencode-agent:poc --policy da-policy.yaml --provider da-model` |
| 5 | 看三类文件 | `sandbox exec da-agent -- cat /etc/da-config/config.env` 等 |
| 6 | Agent 查库写结果 | `sandbox exec da-agent -- sh /usr/local/bin/da-agent.sh` → 5 行 CSV，确定性 |
| 7 | 占位 key 验证 | env 是 `openshell:resolve:env:...`，**不等于真实 key** |
| 8 | opencode 调模型（软） | 实测答出"west 区域的金额最高，为 2400"（与 CSV 一致）；只观察不硬断言 |
| 9 | 轮转管理密码 | Vault 改密 + ALTER USER + 重渲染 → 不重启 sandbox 查库成功 |
| 10 | 改临时配置 | patch CM ROW_LIMIT 5→3 → ~70s 后运行中 sandbox 生效 |

## 文件地图

| 文件 | 用途 |
| --- | --- |
| `demo.sh` | 十拍 demo / 回归 / --cleanup |
| `build-image.sh` + `image/` | 镜像（pi-agent:poc + psql + opencode）、agent 脚本、opencode 配置 |
| `00-db.yaml` + `10-vault-db-admin.sh` | 演示 PostgreSQL + Vault 密码权威源 |
| `20-config.yaml` | CM 临时配置 / Secret 静态 token / 输出 PVC / 渲染 Job |
| `30-assigns.yaml` | 8 条 Gatekeeper Assign（4 卷 + 4 挂载） |
| `da-policy.yaml.template` | 基线 + /vault/da-secrets RO + /data/output RW + DB L4 规则 |
| `providers/da-model.yaml` | 模型 profile（端点 + 二进制白名单） |

## 实测坑（这次新撞的）

1. **`--credential` 的 KEY 是 env 变量名**（`OPENAI_API_KEY`），不是 profile 里的
   credential name（`api_key`）—— 后者报 "credentials are not declared by profile"。
2. **opencode 是 native 二进制**（bun 编译，`opencode.exe`），不是 node 进程。
   profile binaries 必须列 `readlink -f` 的真实路径
   （`/usr/local/lib/node_modules/opencode-ai/bin/opencode.exe`）。
3. **opencode 权限系统**：非交互 run 模式下 `external_directory` 默认 ask→自动拒，
   读 `/data/output/*` 会失败。opencode.json 里 `permission` 各项设 `allow`。
4. **每个 sandbox 自带一个 workspace PVC**，计入 Capsule 配额（PVC 上限 9）。
   配额满时 sandbox 卡 Provisioning，报错是 "PVC not found"（建不出来），很有迷惑性。
   demo.sh 第 0 拍提前拦截；删 sandbox 后 PVC 异步删除，重建前要等它消失。
5. **provider 被 sandbox 引用时删不掉**，profile 连带删不掉。重导前必须先删 sandbox。
6. pi 基础镜像默认非 root：Dockerfile 要 `USER root`（且该行不能带行内注释）。
7. psql 是 pg_wrapper 包装：策略 binaries 列真实路径 `/usr/lib/postgresql/15/bin/psql`。
8. 模型输出不确定（本地模型可能返回空且退出码 0）：第 8 拍是软验证，确定性结论
   全部来自第 6/9/10 拍的 psql 行数与内容。

## 生产化备注

- 每租户：Vault role/policy + 渲染器 + 标签 PVC/CM/Secret + Assign + profile/provider，
  由平台开通流程生成；demo 里 namespace/workspace 写死 tenant-a-runtime/poc-shared。
- 管理密码服务端副本（da-db-server Secret）是演示 DB 自身需要；真实平台的数据库
  凭据管理按既有约定（Vault/KMS，见 openshell4/production/）。
- opencode 的 `permission: allow` 是 demo 取舍；生产应按最小权限收紧（至少
  external_directory 限定到 /data/output）。