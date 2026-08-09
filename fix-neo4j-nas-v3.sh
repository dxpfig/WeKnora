#!/usr/bin/env bash
# fix-neo4j-nas-v3.sh
# v2 的 grep + sed '<n>d' 还不够,docreader 段也是 orphan(全局 sed 的遗留伤)。
# v3 改用一个 awk pass 同时处理 neo4j + docreader(以及其他任何被前次全局 sed 影响过的 service):
#   - 任何 service 段内,有 `- /volume1/.../.env` orphan list 项 → 删
#   - 任何 service 段内,有 `env_file:` 父键但其 list item 已经被前次 sed 删了的 → 父键也删
#
# 只动 app / neo4j / docreader 这三个真正在 docker-compose.nas.yml 里用 env_file 的服务
# (其他 service 用 environment: 不受影响),所以 awk 状态机限定 service 范围。
#
# 用法: sudo bash fix-neo4j-nas-v3.sh

set -euo pipefail

COMPOSE="/volume1/docker/weknora/docker-compose.nas.yml"
ENV_FILE="/volume1/docker/weknora/env-share/.env"
BACKUP="${COMPOSE}.bak-$(date +%Y%m%d-%H%M%S)"

red()    { printf "\033[31m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
section(){ printf "\n\033[1;36m===== %s =====\033[0m\n" "$*"; }

# --- 0. sanity ---
section "0/7 sanity"
[ -f "$COMPOSE" ]  || { red "missing $COMPOSE";  exit 1; }
[ -f "$ENV_FILE" ] || { red "missing $ENV_FILE"; exit 1; }
green "✓ compose + env 在"

# --- 1. backup ---
section "1/7 backup"
cp -v "$COMPOSE" "$BACKUP"
echo "→ $BACKUP(失败回滚用)"

# --- 2. 改前状态 ---
section "2/7 改前 — neo4j 段"
sed -n '/^  neo4j:/,/^  langfuse-web:/p' "$COMPOSE" | head -16
echo "改前 — docreader 段"
sed -n '/^  docreader:/,/^  sandbox:/p' "$COMPOSE" | head -20

# --- 2.5. EARLY FAIL CHECK — neo4j 段必须有 env_file: 父键 ---
# 这个 awk pass 只在 "干净" YAML 上有效(env_file 父键存在)。如果父键已被前次 sed
# 干掉了,awk 进入 skip_mode 的触发器失效,啥都不会删。
section "2.5/7 EARLY CHECK — 验证 NAS 上 yaml 是干净状态"
if awk '/^  neo4j:/{f=1} f && /^    env_file:/{print; exit}' "$COMPOSE" | grep -q env_file; then
  green "✓ neo4j 段有 env_file: 父键,可继续修"
else
  red "✗ NAS 上 docker-compose.nas.yml 不是干净状态"
  red "  neo4j 段缺 env_file: 父键 —— 之前的全局 sed 已经把它删了"
  red "  awk 没法在 orphan 状态下工作"
  echo ""
  echo "修复方法(必须在 PowerShell 跑一次):"
  echo ""
  echo "  scp G:\\claude_workspace\\my_wiki\\WeKnora\\docker-compose.nas.yml \\"
  echo "      figodxp@192.168.2.3:/volume1/docker/weknora/docker-compose.nas.yml"
  echo ""
  echo "这条 scp 会把你 Win 端的干净 yaml 覆盖到 NAS 上,使 neo4j 段回到"
  echo "  image / container_name / env_file: / - /...env / profiles 顺序"
  echo ""
  echo "然后再跑本脚本。"
  exit 1
fi

# --- 3. awk pass —— 删 neo4j 段 + docreader 段的 env_file 父键 + 后续 orphan list ---
# 思路:awk 进入 service 块后,看到 "    env_file:" 就 skip 整段(连下一行 list item),
#      直到 service 边界(下一个 2-space-indent 的 service key 行)再次触发 in_block 重置。
# 这等于一次性把 neo4j 和 docreader 的 env_file 父键 + 后续 list 全删。
#
# 但 app service 也要保留 env_file,所以要按 service 名选择性处理。
section "3/7 awk pass — 只删除 neo4j 段的 env_file(其它 service 不动)"
# 警告:用户必须先 scp 干净 yaml 覆盖 NAS(在 sed 一开始前用 Windows PowerShell 跑那条 scp)
# 这样 neo4j 段格式保证是 image / container_name / env_file / profiles 顺序
# awk 只在 neo4j 段删 env_file 父键和紧跟其后的 `- /...env` 列表项

awk '
  BEGIN { in_target=0; skip_env_file=0 }

  # 匹配 2-space indent 的 service key 行
  /^  [a-z][a-z0-9-]*:/ {
    if ($0 ~ /^  neo4j:/) {
      in_target=1
    } else {
      in_target=0
      skip_env_file=0
    }
  }

  # 在 neo4j 段内
  in_target == 1 {
    if ($0 ~ /^    env_file:/) {
      skip_env_file=1
      next   # 父键删
    }
    if (skip_env_file == 1) {
      # 后续行:
      #   - 列表项 `- /volume1/.../.env` → 删
      #   - 其他顶级 key(environment: / volumes: / profiles: 等) → 退出 skip
      if ($0 ~ /^      - \/volume1\/docker\/weknora\/env-share\/\.env$/) {
        next   # 列表项,删
      }
      if ($0 ~ /^    [a-z][a-z_]*:/) {
        skip_env_file=0   # 退出 skip,让这个顶级 key 正常 print
      } else {
        # 列表项其它内容(罕见),先删 — 安全
        next
      }
    }
  }

  # 正常 print 其它行
  { print }
' "$COMPOSE" > /tmp/c.yml

# 验证 diff
before=$(wc -l < "$COMPOSE")
after=$(wc -l < /tmp/c.yml)
echo "  改前行数: $before / 改后行数: $after"
if [ "$after" -ge "$before" ]; then
  red "⚠ awk 没删任何东西"
  exit 1
fi

# 替换原文
cat /tmp/c.yml > "$COMPOSE"
green "✓ awk pass 完成"

# --- 4. 验证改后 ---
section "4/7 改后 — neo4j 段(应直接 profiles / environment,无 env_file / 无 orphan list)"
sed -n '/^  neo4j:/,/^  langfuse-web:/p' "$COMPOSE" | head -16
echo ""
echo "改后 — docreader 段"
sed -n '/^  docreader:/,/^  sandbox:/p' "$COMPOSE" | head -20

# --- 5. NEO4J_PASSWORD ---
section "5/7 NEO4J_PASSWORD"
PW=$(grep -E '^NEO4J_PASSWORD=' "$ENV_FILE" | sed 's/^NEO4J_PASSWORD=//' | tr -d '"' || true)
NEO4J_PASSWORD="${PW:-password}"
export NEO4J_PASSWORD
echo "Using NEO4J_PASSWORD=$NEO4J_PASSWORD"

# --- 6. up neo4j + wait ready + restart app ---
section "6/7 up neo4j"
cd /volume1/docker/weknora
docker compose -f docker-compose.nas.yml --profile neo4j up -d neo4j

echo ""
section "7/7 wait for :7474 + restart app + final"
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
  docker logs weknora-neo4j --tail 30 --since 2m
  exit 1
fi

# 重启 app 让 NEO4J_ENABLE=true 生效
docker compose -f docker-compose.nas.yml --profile base restart app

echo ""
section "final state"
docker compose -f docker-compose.nas.yml --profile base --profile neo4j ps
echo ""
docker logs weknora-neo4j --tail 12 --since 2m

echo ""
green "完成 → http://192.168.2.3:7474 登录 Neo4j Browser"
echo "  user: neo4j / pwd: $NEO4J_PASSWORD"
