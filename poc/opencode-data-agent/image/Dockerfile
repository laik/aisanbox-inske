# 数据 Agent 镜像：复用 POC2 的 pi-agent:poc（debian12 + node24 + git + curl），
# 加 postgresql-client（psql）和 opencode（npm 全局安装）。
# 构建：bash build-image.sh（在 190 上，会自动 kind load）
FROM pi-agent:poc
# pi 镜像默认非 root，apt/npm 全局安装需要 root（USER 行不能带行内注释）
USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*

# opencode 是 native 二进制（bun 编译），npm 包只是分发壳。
# provider profile 的 binaries 必须列它的**真实路径**（readlink -f 确认）。
RUN npm install -g opencode-ai

COPY da-agent.sh /usr/local/bin/da-agent.sh
COPY da-ai.sh    /usr/local/bin/da-ai.sh
COPY opencode.json /usr/share/da/opencode.json
RUN chmod +x /usr/local/bin/da-agent.sh /usr/local/bin/da-ai.sh