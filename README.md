# aisanbox-inske · 多租户 AI Sandbox POC

给每个租户一个**管得住、也看得见**的 AI agent 沙箱：开通租户 → agent 跑起来 → 越界被拦 → 事后能查。
四个开源组件串成一条链，中间只接了一根线。

## 先看这个

| 想知道什么 | 看哪里 |
|---|---|
| 一页看懂（推荐从这里开始） | [`poc/docs/index.html`](poc/docs/index.html) |
| 文字版结论 | [`poc/docs/SUMMARY.md`](poc/docs/SUMMARY.md) |
| 详细架构、配置、策略规则 | [`poc/docs/architecture.html`](poc/docs/architecture.html) |
| 逐项验证记录与踩坑 | [`poc/docs/FINDINGS.md`](poc/docs/FINDINGS.md) |

## 三个结论（2026-11-03 实测）

- **能跑通**：`openshell sandbox create` → agent 以非 root（uid 10001）执行命令，配额 / 网络边界 / 策略 / 审计全部生效。
- **够快**：预热池认领到就绪 **0.25 s**；冷启动 0.92 s（镜像已在节点）/ 15.98 s（要拉 20 MB 镜像）。
- **看得见**：agent 每次出网、起 shell、装包都带租户 / 命名空间 / 二进制名，能按"哪个程序连哪个地址"在内核层当场拦。

## 技术栈

Capsule 0.15.2（租户合同）· agent-sandbox v1.0.9（沙箱本体）· OpenShell 0.1.4（行为边界）· Tetragon 1.8.0（真相与拦截）。
环境：kind × 2 · Kubernetes v1.37 · macOS / Docker Desktop 29.2.1。

## 复现

```bash
bash poc/scripts/bootstrap.sh              # 重建两个 kind 集群与全部组件（约 10 分钟，Docker ≥ 8 GiB）
bash poc/usage/01-onboard-tenant.sh acme   # 给一个租户开通 sandbox 能力
```

## 目录

```
poc/
├── docs/          index.html · SUMMARY.md · architecture.html · FINDINGS.md
├── kind/          两个集群配置
├── capsule/       租户 / owner / 策略自动下发
├── openshell/     operator 模式接线
├── agent-sandbox/ 预热池 + 认领
├── tetragon/      策略基线（已验证） + 实验证据
├── observability/ 跨集群抓取
├── usage/         开通脚本 · 观测手册
└── scripts/       bootstrap.sh · bench-latency.py
```

> 尚未验证的项（沙箱 DNS 边界、runtimeClasses 白名单、预热池与策略的衔接、gVisor/Kata 隔离、HA）在
> [`poc/docs/index.html`](poc/docs/index.html) §05 与 [`FINDINGS.md`](poc/docs/FINDINGS.md) §4 中逐条说明。
