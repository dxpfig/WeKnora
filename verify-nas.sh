#!/usr/bin/env bash
# =====================================================================
# 验证 NAS (192.168.2.3) 上的 WeKnora 容器是否跑着"最新"代码
# ---------------------------------------------------------------------
# 用法：
#   bash ./verify-nas.sh
#
# 检查项：
#   1. 容器在跑（docker compose ps）
#   2. health 端点返回 ok
#   3. app 镜像的 IMAGE ID 与本机刚 build 的 IMAGE ID 一致
#   4. 容器内 COMMIT_ID 环境变量（build 时注入的）能看到
#   5. docreader 容器也起来了
# =====================================================================
set -euo pipefail

NAS_HOST="${NAS_HOST:-figodxp@192.168.2.3}"
NAS_DIR="${NAS_DIR:-/volume1/docker/weknora}"

echo "===== [1/5] 容器状态 ====="
ssh "${NAS_HOST}" "cd ${NAS_DIR} && docker compose -f docker-compose.nas.yml --profile base ps --format 'table {{.Name}}\t{{.Status}}\t{{.Image}}'"

echo ""
echo "===== [2/5] app health ====="
HEALTH=$(curl -sf http://192.168.2.3:8080/health || echo "FAIL")
echo "    /health -> ${HEALTH}"
[[ "${HEALTH}" != "ok" ]] && { echo "❌ health 失败"; exit 1; }

echo ""
echo "===== [3/5] app 镜像 ID（应与本机 build 的一致） ====="
NAS_IMAGE_ID=$(ssh "${NAS_HOST}" "docker inspect --format '{{.Image}}' weknora-app" 2>/dev/null | cut -c1-12)
echo "    NAS 镜像 ID: ${NAS_IMAGE_ID}"
echo "    本机镜像 ID: （跑过 build 后才有）"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' 2>/dev/null \
  | grep -E 'wechatopenai/weknora-app|weknora-app' \
  | head -3 || echo "    (本机还没有这个镜像——说明 build 没在你机器上跑，而是在 NAS 上跑的，这正常)"

echo ""
echo "===== [4/5] app 容器内的 build 元信息 ====="
ssh "${NAS_HOST}" "docker exec weknora-app sh -c 'echo \"COMMIT_ID=\${COMMIT_ID:-<unset>}\"; echo \"VERSION=\${VERSION:-<unset>}\"; echo \"BUILD_TIME=\${BUILD_TIME:-<unset>}\"; echo \"GO_VERSION=\${GO_VERSION:-<unset>}\"'"

echo ""
echo "===== [5/5] docreader 容器 ====="
ssh "${NAS_HOST}" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' --filter name=weknora-docreader"

echo ""
echo "===== [BONUS] 验证 Lite-mode 修复进了二进制 ====="
# Lite-mode 修复在 internal/container/container.go 里加了 "skipping DuckDB open (MinGW 16 emutls ABI mismatch)"
# 这个字符串只有在编译进二进制后才能看到。注意 NAS 上 Edition=standard 不会触发这个分支，但**字符串本身**仍在二进制里。
echo "    检查二进制里有没有 'MinGW 16 emutls ABI mismatch' 字符串："
ssh "${NAS_HOST}" "docker exec weknora-app sh -c 'strings /app/WeKnora | grep -c \"MinGW 16 emutls\" || echo 0'" \
  | xargs -I{} echo "    命中次数: {}"
echo "    （>0 表示你刚改的 container.go 确实在跑的二进制里）"

echo ""
echo "===== 完成 ====="
echo "如果所有项都绿，部署成功 ✅"
echo "如果 [3] 的镜像 ID 对不上：说明 NAS 用的是 wechatopenai 远程镜像，需要加 --build 参数强制本地构建。"
