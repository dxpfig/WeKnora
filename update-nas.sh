#!/usr/bin/env bash
# =====================================================================
# 在 NAS (192.168.2.3) 上 build + 重启 WeKnora 容器
# ---------------------------------------------------------------------
# 用法（在 Windows Git Bash 跑）：
#   bash -c "cd /g/claude_workspace/my_wiki/WeKnora && ./update-nas.sh"
#   bash ./update-nas.sh --clean       # 先 down（删容器保留卷）再 build+up
#   bash ./update-nas.sh --rebuild     # 强制 --no-cache build
#   bash ./update-nas.sh --down-only   # 只 down，不 build
#
# ⚠️  这个脚本不再自动同步文件 —— SSH wrapper 限制让 rsync/scp
#    访问 /volume1/docker 不可靠。
#    你需要手动把代码和配置复制到 NAS（见下方"复制清单"）。
# =====================================================================
set -euo pipefail

# ---------- 配置 ----------
NAS_HOST="${NAS_HOST:-figodxp@192.168.2.3}"
NAS_DIR="${NAS_DIR:-/volume1/docker/weknora}"

DO_CLEAN=0
DO_REBUILD=0
DO_DOWN_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --clean)      DO_CLEAN=1 ;;
    --rebuild)    DO_REBUILD=1 ;;
    --down-only)  DO_DOWN_ONLY=1 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

echo "==> 目标：${NAS_HOST}:${NAS_DIR}"
echo ""
echo "==> 复制清单（你需要手动复制）"
cat <<'CHECKLIST'

  NAS 上的目标目录布局：
    /volume1/docker/weknora/
    ├── docker-compose.nas.yml           ← G:/claude_workspace/my_wiki/WeKnora/docker-compose.nas.yml
    ├── env-share/
    │   ├── .env                          ← G:/claude_workspace/my_wiki/WeKnora/.env
    │   └── config.yaml                   ← G:/claude_workspace/my_wiki/WeKnora/config/config.yaml
    └── source/                           ← 整个 WeKnora 仓库（除 .git/、*.log、本地构建产物）
        ├── docker/
        │   ├── Dockerfile.app
        │   └── Dockerfile.docreader
        ├── docreader/
        ├── internal/
        ├── cmd/
        ├── go.mod / go.sum
        ├── Makefile
        ├── migrations/
        ├── scripts/
        ├── dataset/samples/
        ├── skills/preloaded/
        ├── config/
        └── docs/

  Windows 上复制命令参考（任选一种）：
    # A. 用 scp 单独复制 yml 和配置
    scp docker-compose.nas.yml figodxp@192.168.2.3:/volume1/docker/weknora/
    scp .env figodxp@192.168.2.3:/volume1/docker/weknora/env-share/.env
    scp config/config.yaml figodxp@192.168.2.3:/volume1/docker/weknora/env-share/config.yaml

    # B. 用绿联"文件管理器"（UGOS Web UI）拖拽整个仓库到 source/
    #    或者用 SMB 共享把 G: 盘映射到 NAS 上直接 cp

  ⚠️  .dockerignore 已经帮我们排除了 .git/、.gocache/、WeKnora-lite.exe、
     *.log 等，复制整个仓库即可，不用手动挑文件。
CHECKLIST
echo ""

# ---------- 0. 健康检查：NAS 上有没有 source/ 和 yml ----------
echo "==> [0/3] 检查 NAS 上的文件是否就绪"
CHECK_OUT=$(ssh "${NAS_HOST}" "bash -c '
  test -f ${NAS_DIR}/docker-compose.nas.yml            && echo yml=ok  || echo yml=MISSING;
  test -d ${NAS_DIR}/source                            && echo src=ok  || echo src=MISSING;
  test -f ${NAS_DIR}/source/docker/Dockerfile.app      && echo app=ok  || echo app=MISSING;
  test -f ${NAS_DIR}/source/docker/Dockerfile.docreader && echo dr=ok  || echo dr=MISSING;
  test -f ${NAS_DIR}/env-share/.env                    && echo env=ok  || echo env=MISSING;
  test -f ${NAS_DIR}/env-share/config.yaml             && echo cfg=ok  || echo cfg=MISSING;
'" 2>&1) || { echo "ssh 失败，请先确认 ssh ${NAS_HOST} 通"; exit 1; }

echo "${CHECK_OUT}"
if echo "${CHECK_OUT}" | grep -q MISSING; then
  echo ""
  echo "❌ NAS 上文件不全，请按上面的复制清单手动复制后再跑。"
  exit 1
fi
echo ""

# ---------- 1. 可选：先 down ----------
if [[ ${DO_DOWN_ONLY} -eq 1 ]]; then
  echo "==> [1/3] docker compose down（保留卷）"
  ssh "${NAS_HOST}" "cd ${NAS_DIR} && docker compose -f docker-compose.nas.yml --profile base down"
  echo "==> 完成"
  exit 0
fi

if [[ ${DO_CLEAN} -eq 1 ]]; then
  echo "==> [1/3] docker compose down（保留卷）"
  ssh "${NAS_HOST}" "cd ${NAS_DIR} && docker compose -f docker-compose.nas.yml --profile base down"
else
  echo "==> [1/3] (跳过 down)"
fi

# ---------- 2. build ----------
echo "==> [2/3] docker compose build"
BUILD_FLAGS=""
[[ ${DO_REBUILD} -eq 1 ]] && BUILD_FLAGS="--no-cache --pull"

ssh "${NAS_HOST}" "cd ${NAS_DIR} && \
  docker compose -f docker-compose.nas.yml --profile base build ${BUILD_FLAGS} app docreader"

# ---------- 3. up ----------
echo "==> [3/3] docker compose up -d"
ssh "${NAS_HOST}" "cd ${NAS_DIR} && \
  docker compose -f docker-compose.nas.yml --profile base up -d"

echo ""
echo "==> 验证："
echo "    bash ./verify-nas.sh"
echo "    curl -s http://192.168.2.3:8080/health"
echo ""
echo "==> 完成 ✅"
