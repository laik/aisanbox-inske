#!/usr/bin/env bash
# 在 190 上构建数据 Agent 镜像并 load 进 kind。幂等：镜像已存在则跳过构建。
set -euo pipefail
cd "$(dirname "$0")"
IMG=opencode-agent:poc
if docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "镜像 $IMG 已存在，跳过构建（要重建：docker rmi $IMG）"
else
  docker build -t "$IMG" image/
fi
kind load docker-image "$IMG" --name agent-runtime-poc
echo "=== opencode 真实路径（profile binaries 要用）==="
docker run --rm --entrypoint sh "$IMG" -c 'readlink -f /usr/local/bin/opencode; opencode --version 2>/dev/null | head -1; which psql; readlink -f "$(which psql)"'