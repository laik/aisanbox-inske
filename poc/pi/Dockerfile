# POC2 §6.1 —— Pi Coding Agent 镜像。
#
# 与 POC2 的偏离(都是实测必要的):
#  1. POC2 §10 的任务要跑 `go test`，但 §6.1 的 Dockerfile 里**没有 Go** —— 补上。
#  2. 版本全部固定(POC2 自己也说"实际使用时应锁定 Pi 版本")。见下面 ARG 的坑。
#  3. pi-otel 扩展在**构建期**装好: 沙箱默认不能直连外网，运行期 npm 装不了。
FROM node:24-bookworm-slim

# 实测坑(值得进报告): ARG 写在 FROM **之前**，只在 FROM 行插值时可见，**stage 里看不到** ——
# 于是 ${PI_VERSION} 展开成空字符串:
#   npm install -g "@earendil-works/pi-coding-agent@"   -> 实际装的是 latest
#   pi install "npm:pi-otel@"                          -> 日志里就是 "Installing npm:pi-otel@"
# 不报错、构建成功、镜像能用 —— 但 §6.1 要的"锁定版本"其实没做到。
# 所以 ARG 必须在 stage 内声明;下面把 pin 打印出来，让 `docker build` 的输出本身就是证据。
ARG PI_VERSION=1.5.0
ARG PI_OTEL_VERSION=0.3.0
RUN echo "pin: pi=${PI_VERSION} pi-otel=${PI_OTEL_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates git ripgrep fd-find openssh-client curl unzip \
       golang-go \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && pi --version

# POC2 §6.2: Pi 的 OTel 扩展，锁定版本。
#
# 必须在**构建期**装: 沙箱默认不能直连外网，运行期 `pi install npm:pi-otel` 会失败
# (实测 npm 连 registry.npmjs.org 直接被网络边界拒掉)。
#
# 用 Pi 自己的 installer，而不是手工把包拷进 extensions/ —— 实测原因:
#   手工拷一份 pi-otel 到 agent 目录后 pi 报
#     Cannot find module '@opentelemetry/api'   (require stack: .../pi-otel/dist/index.js)
#   因为扩展的 **dependencies** 不在解析路径上。installer 会连带装依赖并写 settings.json。
#
# agent 目录放在 /usr/local 而不是 /opt —— 实测原因: OpenShell 的默认文件系统基线只覆盖
# /bin /usr /lib /proc /dev/urandom /etc /var/log(只读)与 /tmp /dev/null(读写)，**不含 /opt**。
# 在沙箱里读 /opt/pi-home 得到的是 `Permission denied` —— 看起来像 Unix 权限问题
# (mode 是 0755 root，uid 10001 本该能读)，实际是策略边界。
# 上一轮 poc/agent/policy.yaml 已经记过同一类教训("keep it under /usr, or list your own
# path")；这次是在**另一个组件**上重现了它，说明它属于"平台的默认值"，不是某个镜像的 bug。
# 目录在 root 阶段创建(之后 USER node，/opt 与 /usr 都不可写)，权限设成所有 uid 可读:
# 沙箱实际以 **uid 10001**(OpenShell 自己的非 root uid)运行，会覆盖镜像里的 USER node。
ENV PI_AGENT_DIR=/usr/local/pi-home
RUN mkdir -p "${PI_AGENT_DIR}" \
    && PI_CODING_AGENT_DIR="${PI_AGENT_DIR}" pi install "npm:pi-otel@${PI_OTEL_VERSION}" \
    && chmod -R a+rX "${PI_AGENT_DIR}"

# 运行期用的 agent-home 准备脚本(为什么要在运行期复制成可写副本，见脚本内注释)。
COPY setup-agent-home.sh /usr/local/pi/setup-agent-home.sh
RUN chmod 0755 /usr/local/pi/setup-agent-home.sh

RUN mkdir -p /data/workspace /tmp/gocache \
    && chown -R node:node /data /tmp

USER node

ENV PI_TELEMETRY_OPTOUT=1
ENV GOCACHE=/tmp/gocache
# 不在这里设 PI_CODING_AGENT_DIR: 由 /usr/local/pi/setup-agent-home.sh 在运行期给出可写副本。
# 模型端点由 gateway 的 provider 注入，见 phases/11-pi-scenario.sh。
WORKDIR /data/workspace
