#!/usr/bin/env bash
# fix-neo4j-nas-v2.sh
# v1 的范围 sed 在损坏的 yaml 上不生效(orphan list 项的隐字符不匹配)。
# v2 改成:grep -n 找精确行号 → sed 'Nd' 删除。不依赖 regex/缩进/delimiter。
#
# 用法: sudo bash fix-neo4j-nas-v2.sh

set -euo pipefail

COMPOSE="/volume1/docker/weknora/docker-compose.nas.yml"
ENV_FILE="/volume1/docker/weknora/env-share/.env"
BACKUP="${COMPOSE}.bak-$(date +%Y%m%d-%H%M%S)"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
section(){ printf "\n\033[1;36m===== %s =====\033[0m\n" "$*"; }

# --- 0. sanity ---
section "0/9 sanity"
[ -f "$COMPOSE" ]  || { red "missing: $COMPOSE";  exit 1; }
[ -f "$ENV_FILE" ] || { red "missing: $ENV_FILE"; exit 1; }

# --- 1. backup ---
section "1/9 backup"
cp -v "$COMPOSE" "$BACKUP"
echo "→ $BACKUP"

# --- 2. 找精确行号 ---
# 思路:扫描所有"- /volume1/.../.env"(或等价的相对路径)list item,
#      如果它们的父键 `env_file:` 在原文件里**已被前次 sed 删了**,这些 list item
#      就是 orphan — 把所有 orphan 全删。
section "2/9 找所有 orphan - /volume1/.../.env(list 项无 env_file: 父键的)"

# 找所有 env-share/.env 行,以及它们所属 service 段
# 简化:列出所有 env-share/.env 行,后续逻辑手动判别
grep -n 'env-share/\.env' "$COMPOSE" || true
echo "(↑ 上面所有这些 - /...env 行都需要判别)"

# 用 awk 在内存里扫描,跟踪当前是否在 "env_file: parent" 上下文内
# 简化判别:对每个 `- ...env` 行,看它前 1-3 行是否有 `env_file:`(4 spaces)
TO_DELETE=()
while IFS=: read -r num body; do
  # body 形如 "      - /volume1/docker/weknora/env-share/.env"
  # 看它前面 1-3 行(直到遇到 service key 行 ^  X:)有没有 `env_file:`
  prev_start=$((num > 4 ? num-4 : 1))
  prev_block=$(sed -n "${prev_start},$((num-1))p" "$COMPOSE")
  if echo "$prev_block" | grep -q '^    env_file:'; then
    green "  L$num: 父键 env_file: 还在 — 此行是合法的,跳过"
  else
    TO_DELETE+=("$num")
    yellow "  → 待删除 L$num (orphan): ${body## }"
  fi
done < <(grep -n 'env-share/\.env' "$COMPOSE")

if [ ${#TO_DELETE[@]} -eq 0 ]; then
  yellow "(没找到 orphan 行 — compose 可能已被修复?)"
  yellow "继续到下步"
fi

# 用 sed 按行号删(任何 sed 都支持,不需要 gawk)
if [ ${#TO_DELETE[@]} -gt 0 ]; then
  section "3/9 用 sed 按行号删除(busybox/GNU sed 通用,不用 gawk)"
  # 把数组格式化成 sed 命令 '<n1>d;<n2>d;<n3>d;'
  SED_EXPR=""
  for n in "${TO_DELETE[@]}"; do
    SED_EXPR="${SED_EXPR}${n}d;"
  done
  echo "sed 表达式: $SED_EXPR"

  # 先做干跑显示 — 让人眼看清楚是哪些行
  echo "--- 即将删除的行 ---"
  for n in "${TO_DELETE[@]}"; do
    sed -n "${n}p" "$COMPOSE" | sed 's/^/  L'"${n}"': /'
  done
  echo "--------------------"

  # 实际删除:redirect 到 tmp + mv 覆盖(busybox sed 也支持,不需要 -i)
  sed "$SED_EXPR" "$COMPOSE" > /tmp/c.yml

  # 验证文件行数变了(说明真删了)
  before=$(wc -l < "$COMPOSE")
  after=$(wc -l < /tmp/c.yml)
  echo "  删除前行数: $before / 删除后行数: $after"

  if [ "$after" -ge "$before" ]; then
    red "⚠ sed 没删任何东西(行号可能算错),中止"
    exit 1
  fi

  # 替换原文(直接 cat > + 追加空白行?不行,精确覆盖)
  cat /tmp/c.yml > "$COMPOSE"
  green "✓ sed 删除完成"
else
  section "3/9 跳过删除(无目标行)"
fi

# --- 4. 验证 neo4j 段当前状态 ---
section "4/9 改后 neo4j 段(应看到 image / container_name / profiles / environment,无 env_file 也无 orphan list)"
sed -n '/^  neo4j:/,/^  langfuse-web:/p' "$COMPOSE" | head -16

# --- 5. 设 NEO4J_PASSWORD ---
section "5/9 NEO4J_PASSWORD 从 .env 读"
PW=$(grep -E '^NEO4J_PASSWORD=' "$ENV_FILE" | sed 's/^NEO4J_PASSWORD=//' | tr -d '"' || true)
NEO4J_PASSWORD="${PW:-password}"
export NEO4J_PASSWORD
echo "Using NEO4J_PASSWORD=$NEO4J_PASSWORD"

# --- 6. 重启 neo4j ---
section "6/9 up neo4j"
cd /volume1/docker/weknora
docker compose -f docker-compose.nas.yml --profile neo4j up -d neo4j

# --- 7. 等 HTTP :7474 ready ---
section "7/9 wait for :7474 (curl probe, exclude initializing banner)"
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
  red "✗ Neo4j NOT ready in 120s"
  echo ""
  echo "----- logs (last 30) -----"
  docker logs weknora-neo4j --tail 30 --since 2m
  exit 1
fi

# --- 8. 重启 app ---
section "8/9 restart app(让 NEO4J_ENABLE=true 生效)"
docker compose -f docker-compose.nas.yml --profile base restart app

# --- 9. final ---
echo ""
section "9/9 final state"
docker compose -f docker-compose.nas.yml --profile base --profile neo4j ps
echo ""
docker logs weknora-neo4j --tail 12 --since 2m

echo ""
green "完成 → http://192.168.2.3:7474 登录 Neo4j Browser"
echo "  user: neo4j / pwd: $NEO4J_PASSWORD"
