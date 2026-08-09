#!/usr/bin/env bash
# fix-neo4j-nas.sh
# 一次性修复 NAS 上 WeKnora Neo4j 启动失败(NEO4J_URI 命名空间冲突)
#
# 根因:
#   docker-compose.nas.yml 的 neo4j 服务用 env_file 把整份 .env 灌给 Neo4j 5,
#   .env 里 NEO4J_URI=... 是 WeKnora 客户端用的(让 app 连 Neo4j),
#   但 Neo4j 5 启动时会"霸道地"把所有 NEO4J_* env 当 dbms setting 解析,
#   找不到 URI 这个 setting 就 hard fail → restart loop。
#
# 修法:
#   范围 sed 删掉 neo4j service 的 env_file 两行(不影响 app 等其它服务),
#   neo4j 改成走 environment: 块 + 当前 shell 的 NEO4J_PASSWORD。
#   app 服务继续读 .env(它仍需要 NEO4J_URI 等客户端配置)。
#
# 用法:
#   1. 在 Windows: scp <此脚本> figodxp@192.168.2.3:/tmp/fix.sh
#   2. 在 NAS root shell:  sudo bash /tmp/fix.sh
#
# 失败兜底:
#   compose 自动备份成 docker-compose.nas.yml.bak-YYYYMMDD-HHMMSS,
#   手动回滚:  cp <backup> /volume1/docker/weknora/docker-compose.nas.yml

set -euo pipefail

COMPOSE="/volume1/docker/weknora/docker-compose.nas.yml"
ENV_FILE="/volume1/docker/weknora/env-share/.env"
BACKUP="${COMPOSE}.bak-$(date +%Y%m%d-%H%M%S)"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
section(){ printf "\n\033[1;36m===== %s =====\033[0m\n" "$*"; }

# ---------- 0. sanity ----------
section "0/8  自检环境"
[ -f "$COMPOSE" ]  || { red "missing: $COMPOSE";  exit 1; }
[ -f "$ENV_FILE" ] || { red "missing: $ENV_FILE"; exit 1; }
green "✓ compose + env file 都在"

# ---------- 1. backup ----------
section "1/8  备份 compose (失败可回滚)"
cp -v "$COMPOSE" "$BACKUP"
echo "备份路径: $BACKUP"

# ---------- 2. before snapshot ----------
section "2/8  改前 — neo4j 段状态(应看到 image / container_name / env_file / profiles / environment 五段)"
sed -n '/^  neo4j:/,/^  langfuse-web:/p' "$COMPOSE" | head -16

# ---------- 3. apply sed (RANGE-LIMITED, not global) ----------
section "3/8  应用 sed — 范围限定在 neo4j 段(不影响 app 等其它服务的 env_file)"
sed -i '/^  neo4j:/,/^  langfuse-web:/{ /^    env_file:/d; /^      - \/volume1\/docker\/weknora\/env-share\/.env$/d; }' "$COMPOSE"
green "✓ sed 完成(只动 neo4j 段,不改 app 等其他服务)"

# ---------- 4. after snapshot ----------
section "4/8  改后 — 验证 neo4j 段当前 12 行(应不再有 env_file,profiles 直接跟 profiles: [neo4j])"
sed -n '/^  neo4j:/,/^  langfuse-web:/p' "$COMPOSE" | head -16

# ---------- 5. NEO4J_PASSWORD ----------
section "5/8  准备 NEO4J_PASSWORD(供 compose 的 \${NEO4J_PASSWORD} 替换)"
PW=$(grep -E '^NEO4J_PASSWORD=' "$ENV_FILE" | sed 's/^NEO4J_PASSWORD=//' | tr -d '"' || true)
NEO4J_PASSWORD="${PW:-password}"
export NEO4J_PASSWORD
echo "Using NEO4J_PASSWORD=$NEO4J_PASSWORD"
yellow "  若你的 NAS .env 用了别的密码,grep 你备份的 .env 改 BACKUP 后再 sed in-place"

# ---------- 6. up neo4j ----------
section "6/8  启动 neo4j(profile 限定,不影响其它运行容器)"
cd /volume1/docker/weknora
docker compose -f docker-compose.nas.yml --profile neo4j up -d neo4j

# ---------- 7. wait for HTTP :7474 ready ----------
section "7/8  等 Neo4j HTTP :7474 ready(curl 探活 + 排除 initializing banner)"
ready=0
for i in $(seq 1 60); do
  code=$(curl -sS -o /tmp/neo4j.html -w '%{http_code}' --max-time 3 http://127.0.0.1:7474/ 2>/dev/null || echo 000)
  init_banner="no"
  if [ -f /tmp/neo4j.html ] && grep -qi initializing /tmp/neo4j.html 2>/dev/null; then
    init_banner="yes"
  fi
  if [ "$code" = "200" ] && [ "$init_banner" = "no" ]; then
    green "✓ Neo4j READY after $((i*2))s"
    ready=1
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    state=$(docker inspect --format '{{.State.Status}}' weknora-neo4j 2>/dev/null || echo "?")
    echo "  attempt $i: http=$code init=$init_banner container=$state"
  fi
  sleep 2
done

if [ $ready -ne 1 ]; then
  red "✗ Neo4j 没有 ready(轮询 60 次 = 120s 没起来)。看 logs:"
  echo ""
  echo "===== Neo4j logs (last 30) ====="
  docker logs weknora-neo4j --tail 30 --since 2m
  exit 1
fi

# ---------- 8. restart app ----------
section "8/8  重启 app(让 NEO4J_ENABLE=true 生效)"
docker compose -f docker-compose.nas.yml --profile base restart app

# ---------- final ----------
echo ""
section "最终:全景容器状态"
docker compose -f docker-compose.nas.yml --profile base --profile neo4j ps

echo ""
section "Neo4j 日志尾"
docker logs weknora-neo4j --tail 12 --since 2m

echo ""
green "完成。下一步浏览器访问 http://192.168.2.3:7474 登录 Neo4j Browser"
echo "  用户名: neo4j"
echo "  密码:   $NEO4J_PASSWORD"
echo ""
echo "  WeKnora UI: http://192.168.2.3:8098  应该有 GraphRAG 配置项了"
