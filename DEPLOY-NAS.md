# WeKnora @ 绿联 DXP4800 Plus — 部署 Cheatsheet

> 目标：把整套 WeKnora 跑在 NAS（192.168.2.3），浏览器访问 **http://192.168.2.3:8080**。
>
> LLM/Ollama/Xinference 仍在 Windows 机器（**这台机器的 LAN IP 待你提供**——见 §0）。

---

## §0. 上传前你要准备的 3 件事

### 0.1 你 Windows 机器的 LAN IP（必填）

NAS 要通过 LAN 找你 Windows 上的 Ollama/Xinference。需要：
```cmd
ipconfig /all
```
看 "IPv4 Address" 里 `192.168.2.x` 那个（**不是** 192.168.2.3 那个，那是 NAS）。

假设是 `192.168.2.10`（替换下面的占位 `WINDOWS_HOST`）：
- Ollama 在 Windows: `http://192.168.2.10:11434`
- Xinference 在 Windows: `http://192.168.2.10:9997`

### 0.2 打开 Windows 防火墙（关键）

Ollama 和 Xinference 默认只 listen 在 `127.0.0.1`，NAS 访问不到。要么：
- **A（推荐）：在 Windows 上把 Ollama/Xinference 绑到 0.0.0.0**
  - Ollama：`set OLLAMA_HOST=0.0.0.0:11434` 然后重启
  - Xinference：在配置或启动参数里加 `--host 0.0.0.0`
- **B：在 Windows 防火墙给 11434 + 9997 加 inbound 规则**

### 0.3 .env 需要改 3 行（指向 NAS 而不是 Docker service）

`OLLAMA_BASE_URL=http://192.168.2.10:11434`  ← 把 192.168.2.10 改成你 Windows 真实 LAN IP
`EMBEDDING_BASE_URL=http://192.168.2.10:11434/v1`
`RERANK_BASE_URL=http://192.168.2.10:9997/v1`
`APP_EXTERNAL_URL=http://192.168.2.3`           ← 这是 NAS IP，不用改

---

## §1. 上传到 NAS

### 方案 A — ssh/scp 推送（推荐，干净）
```bash
# Windows PowerShell 跑：
scp G:\claude_workspace\my_wiki\WeKnora\docker-compose.nas.yml root@192.168.2.3:/volume1/docker/weknora/
scp G:\claude_workspace\my_wiki\WeKnora\.env root@192.168.2.3:/volume1/docker/weknora/env-share/.env
scp G:\claude_workspace\my_wiki\WeKnora\config\config.yaml root@192.168.2.3:/volume1/docker/weknora/env-share/config.yaml
```

### 方案 B — 用绿联"文件管理器"手动拖
把 3 个文件拖到 NAS 的 `/volume1/docker/weknora/` 目录结构里：
```
/volume1/docker/weknora/
├── docker-compose.nas.yml
└── env-share/
    ├── .env          ← 你 Windows 上的 .env 原样
    └── config.yaml   ← 你 Windows 上的 config/config.yaml 原样
```

### 然后 ssh 进去：
```bash
ssh root@192.168.2.3
cd /volume1/docker/weknora
mkdir -p env-share skills-preloaded
# （如果你用方案 B，这一步是把拖进来的文件归位）
```

---

## §2. 在 NAS 上准备好数据卷目录

```bash
mkdir -p /volume1/docker/weknora/{postgres-data,redis-data,minio-data,neo4j-data,neo4j-logs,langfuse-clickhouse-data,langfuse-minio-data,data-files,docreader-cache,searxng-config,skills-preloaded}
```

确认一下：
```bash
ls /volume1/docker/weknora/
# 应该看到 11 个子目录
```

---

## §3. 关掉你 Windows 上跑的 Lite（释放 8080）

如果你想把 8080 让给 NAS app，先在 Windows PowerShell 里：
```powershell
taskkill /F /PID 24680
```
（Lite 是 PID 24680；如变了用 `tasklist /FI "IMAGENAME eq WeKnora-lite.exe"` 查）

**如果你想两个都跑**（Lite 在 8080 + NAS app 用别的端口），改 NAS 的 `APP_PORT=8081`：
```bash
sed -i 's/APP_PORT:-8080/APP_PORT:-8081/' /volume1/docker/weknora/docker-compose.nas.yml
# 然后 NAS app 上 8081，浏览器改 http://192.168.2.3:8081
```

---

## §4. 启动（按你想要的"测试覆盖度"分阶段）

> **RAM 预算 16 GB**：留 2 GB 给 UGOS 系统，其余 14 GB 给容器。
> 高级组件（Neo4j / Langfuse / ODL）不**同时**开。

### 阶段 ①（**必起**，占 ~5 GB）—— 核心 RAG 全栈
```bash
docker compose -f docker-compose.nas.yml --profile base up -d
```
组件：app / frontend / postgres / redis / docreader / sandbox

验证：
```bash
docker compose -f docker-compose.nas.yml ps
curl -s http://192.168.2.3:8080/health      # 应返回 ok
curl -s http://192.168.2.3:80/healthz      # nginx 应返 200
```

浏览器开 **http://192.168.2.3:8080** 注册第一个 admin。

### 阶段 ② 可选（一次性开一个，各占 ~3-4 GB）

**a. Neo4j + GraphRAG**
```bash
# 阶段 ① 都还在的时候，先停
docker compose -f docker-compose.nas.yml stop langfuse-web langfuse-clickhouse langfuse-minio
# 再启 Neo4j
docker compose -f docker-compose.nas.yml --profile neo4j up -d
```
浏览器开 http://192.168.2.3:7474（账号 `neo4j`、密码看 .env 里 NEO4J_PASSWORD），交互式看节点关系。

**b. Langfuse（自建 LLM 可观测性）**
```bash
docker compose -f docker-compose.nas.yml stop neo4j odl-hybrid
docker compose -f docker-compose.nas.yml --profile langfuse up -d
sleep 60    # 第一次跑 ClickHouse 迁移要 1-2 分钟
curl -s http://192.168.2.3:3000             # 应 200
```
浏览器开 http://192.168.2.3:3000 注册管理员 → Settings → Create Project → 拿 pk-lf-/sk-lf- key 填回 .env 里 LANGFUSE_*，然后重启 app：
```bash
docker compose -f docker-compose.nas.yml --profile base restart app
```

**c. ODL-Hybrid（重型 PDF 解析）**
```bash
docker compose -f docker-compose.nas.yml stop neo4j langfuse-web langfuse-clickhouse langfuse-minio
docker compose -f docker-compose.nas.yml --profile odl-hybrid up -d --build
curl -s http://192.168.2.3:5002/health
```
需要在 .env 里加：
```
DOCREADER_ODL_HYBRID=on
DOCREADER_ODL_HYBRID_URL=http://odl-hybrid:5002
```
然后：
```bash
docker compose -f docker-compose.nas.yml --profile base restart docreader app
```

### 阶段 ③（按需）—— MinIO / SearXNG / Sandbox

- **MinIO**（.env 加 `STORAGE_TYPE=minio` 后）：`--profile minio up -d`
- **SearXNG**（自建搜索）：`--profile searxng up -d`
- **Sandbox**：base 已带，无需单启

---

## §5. 日常运维

```bash
# 看全部容器状态
docker compose -f docker-compose.nas.yml ps

# 实时日志
docker compose -f docker-compose.nas.yml logs -f app
docker compose -f docker-compose.nas.yml logs -f docreader

# 重启单个
docker compose -f docker-compose.nas.yml --profile base restart app

# 停所有
docker compose -f docker-compose.nas.yml --profile base down

# 完全清（含数据）
docker compose -f docker-compose.nas.yml down -v
```

---

## §6. 已就位后回到 Lite 测试的迁移

如果哪天想从 NAS docker 切回 Windows Lite 单文件：

1. `docker compose -f docker-compose.nas.yml --profile base stop app frontend`
2. 在 Windows 启动 Lite（之前那条成功命令）
3. .env.lite 改回 `127.0.0.1`（即 Ollama/Xinference 同机）+ `DB_DRIVER=sqlite` + `STREAM_MANAGER_TYPE=memory`
4. docreader 也已经在 Windows 上跑着，Lite 会自动连 127.0.0.1:50051

Lite 和 Docker NAS 可**同时存在**，互不干扰。

---

## §7. 已知会踩的坑（按概率排）

1. **NAS `127.0.0.1` 在容器里指容器本身**——所以 OLLAMA/XINFERENCE 这种"外部"服务必须用 Windows LAN IP（`192.168.2.10`），不是 127.0.0.1。
2. **100 Mbps 上行**：NAS ↔ Windows LLM 流量受限于此。若卡顿，把 Ollama/Xinference 也放 NAS（同一 Docker，但占 RAM）。
3. **default 密码**：项目 demo 的 `postgres123!@#` / `redis123!@#` / `neo4j123` 一定记得改。
4. **ParadeDB 镜像较重**（~1 GB）：第一次 `docker pull` 要 5-10 分钟。
5. **Langfuse 第一次启动**：ClickHouse schema 迁移约 1-2 分钟，期间 langfuse-web 报 502。等几分钟就好。
6. **Neo4j**：第一次启动要做 store format 初始化，约 30 秒。这期间 WeKnora app 调用 Neo4j 会 timeout，正常。
7. **Sandbox 容器是 `sleep infinity`**：用户/Agent 调 Skill 时 WeKnora 会临时起新容器、用完销毁。
