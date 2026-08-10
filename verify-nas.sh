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
#   6. 新 endpoint 已注册（image-statuses / retry-failed-images）
#   7. 迁移 000005 已应用（idx_chunks_metadata_gin 存在）
#   BONUS：两个关键字符串进了二进制
# =====================================================================
set -euo pipefail

NAS_HOST="${NAS_HOST:-figodxp@192.168.2.3}"
NAS_DIR="${NAS_DIR:-/volume1/docker/weknora}"

echo "===== [1/7] 容器状态 ====="
ssh "${NAS_HOST}" "cd ${NAS_DIR} && docker compose -f docker-compose.nas.yml --profile base ps --format 'table {{.Name}}\t{{.Status}}\t{{.Image}}'"

echo ""
echo "===== [2/7] app health ====="
HEALTH=$(curl -sf http://192.168.2.3:8080/health || echo "FAIL")
echo "    /health -> ${HEALTH}"
[[ "${HEALTH}" != "ok" ]] && { echo "❌ health 失败"; exit 1; }

echo ""
echo "===== [3/7] app 镜像 ID（应与本机 build 的一致） ====="
NAS_IMAGE_ID=$(ssh "${NAS_HOST}" "docker inspect --format '{{.Image}}' weknora-app" 2>/dev/null | cut -c1-12)
echo "    NAS 镜像 ID: ${NAS_IMAGE_ID}"
echo "    本机镜像 ID: （跑过 build 后才有）"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' 2>/dev/null \
  | grep -E 'wechatopenai/weknora-app|weknora-app' \
  | head -3 || echo "    (本机还没有这个镜像——说明 build 没在你机器上跑，而是在 NAS 上跑的，这正常)"

echo ""
echo "===== [4/7] app 容器内的 build 元信息 ====="
ssh "${NAS_HOST}" "docker exec weknora-app sh -c 'echo \"COMMIT_ID=\${COMMIT_ID:-<unset>}\"; echo \"VERSION=\${VERSION:-<unset>}\"; echo \"BUILD_TIME=\${BUILD_TIME:-<unset>}\"; echo \"GO_VERSION=\${GO_VERSION:-<unset>}\"'"

echo ""
echo "===== [5/7] docreader 容器 ====="
ssh "${NAS_HOST}" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' --filter name=weknora-docreader"

echo ""
echo "===== [6/7] 新 endpoint 已注册(image-statuses / retry-failed-images) ====="
# 这些 endpoint 要求鉴权 — 401 表示 endpoint 存在但需要 token，404 表示没注册。
# 用 0-length body 的 GET + POST 看状态码。
GET_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://192.168.2.3:8080/api/v1/knowledge/test/image-statuses" || echo "ERR")
POST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://192.168.2.3:8080/api/v1/knowledge/test/retry-failed-images" || echo "ERR")
echo "    GET  /knowledge/test/image-statuses        -> ${GET_STATUS} (期望 401 / 400,不要 404)"
echo "    POST /knowledge/test/retry-failed-images   -> ${POST_STATUS} (期望 401 / 400,不要 404)"
if [[ "${GET_STATUS}" == "404" || "${POST_STATUS}" == "404" ]]; then
  echo "❌ 新 endpoint 没注册 — 路由没刷上。需要 force-recreate。"
  exit 1
fi

echo ""
echo "===== [7/7] 迁移 000005 已应用(idx_chunks_metadata_gin) ====="
# 检查 GIN 索引是否存在。索引不在的话 '@>' 查询会全表扫。
INDEX_EXISTS=$(ssh "${NAS_HOST}" "docker exec weknora-postgres sh -c 'PGPASSWORD=\$POSTGRES_PASSWORD psql -U \$POSTGRES_USER -d \$POSTGRES_DB -tAc \"SELECT count(*) FROM pg_indexes WHERE indexname = '\''idx_chunks_metadata_gin'\''\"'" 2>/dev/null | tr -d ' \n' || echo "ERR")
echo "    idx_chunks_metadata_gin count: ${INDEX_EXISTS}"
if [[ "${INDEX_EXISTS}" != "1" ]]; then
  echo "❌ 索引不存在 — 迁移 000005 没跑。需要手动跑 migrations/versioned/000005_image_retry_indexes.up.sql"
  exit 1
fi

echo ""
echo "===== [BONUS] 验证关键修复进了二进制 ====="
# Lite-mode 修复在 internal/container/container.go 里加了 "skipping DuckDB open (MinGW 16 emutls ABI mismatch)"
# Per-image retry 修复在 internal/application/service/image_multimodal.go 里加了 "recordImageStatus: parent chunk"
# 这俩字符串只有在编译进二进制后才能看到。
echo "    检查两个字符串是否在二进制里："
ssh "${NAS_HOST}" "docker exec weknora-app sh -c '
  A=\$(strings /app/WeKnora 2>/dev/null | grep -c \"MinGW 16 emutls\" || echo 0);
  B=\$(strings /app/WeKnora 2>/dev/null | grep -c \"recordImageStatus: parent chunk\" || echo 0);
  echo \"MinGW 16 emutls                : \$A\";
  echo \"recordImageStatus: parent chunk: \$B\"'" \
  | sed 's/^/      /'
echo "    （两个都 >0 表示你刚 commit 的代码确实在跑的二进制里）"

echo ""
echo "===== 完成 ====="
echo "如果所有项都绿，部署成功 ✅"
echo "如果 [3] 的镜像 ID 对不上：说明 NAS 用的是 wechatopenai 远程镜像，需要加 --build 参数强制本地构建。"
echo "如果 [6] endpoint 404：docker compose up -d --force-recreate 重启。"
echo "如果 [7] 索引不存在：在 NAS 上跑 bash ./scripts/migrate.sh"