#!/usr/bin/env bash
# 把 GitHub **release asset** 取到本地 vendor/。
#
# 为什么需要它(实测): 这台宿主能通 api.github.com 和 github.com 的 HTML，但 release 的
# 下载主机(objects.githubusercontent.com / raw.githubusercontent.com)会 503/504。
# 走 API 的 asset 端点(`Accept: application/octet-stream`)是通的 —— 它走的是另一条 CDN。
#
# 用法: bash scripts/gh-fetch.sh <owner>/<repo> <tag> <asset-name> [本地文件名]
# 注: helm **repo**(charts.antrea.io)和 OCI(ghcr.io)都不受影响，只有 release asset 要绕。
set -euo pipefail
repo=$1 tag=$2 asset=$3 out=${4:-$3}
cd "$(dirname "$0")/.."
mkdir -p vendor
if [ -s "vendor/$out" ]; then echo "   已有 vendor/$out ($(stat -c%s "vendor/$out")B) —— 跳过"; exit 0; fi
host=$(echo "https://api.github.com/repos/$repo/releases/tags/$tag" | sed 's#https://api.github.com##')
aid=$(curl -fsSL --connect-timeout 10 --max-time 60 "https://api.github.com/repos/$repo/releases/tags/$tag" \
      | python3 -c "import sys,json;print([a['id'] for a in json.load(sys.stdin)['assets'] if a['name']=='$asset'][0])")
curl -fsSL --connect-timeout 10 --max-time 300 \
  -H "Accept: application/octet-stream" \
  -o "vendor/$out" "https://api.github.com/repos/$repo/releases/assets/$aid"
echo "   vendor/$out = $(stat -c%s "vendor/$out")B  ($repo@$tag/$asset)"
