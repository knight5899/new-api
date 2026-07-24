# Docker Compose 本地部署

本文是一份可直接执行的本地部署 runbook，补充官方安装页中的 Compose 说明：

- 官方安装入口：<https://www.newapi.ai/zh/docs/installation>
- 官方 Compose 说明：<https://www.newapi.ai/zh/docs/installation/deployment-methods/docker-compose-installation>

本方案启动三个容器：New API、PostgreSQL 15 和 Redis 7。PostgreSQL 数据使用命名卷持久化，New API 的运行数据和日志映射到当前目录的 `data/`、`logs/`。

## 前置条件

- Docker Desktop 或 Docker Engine 24+，并包含 Compose v2（命令是 `docker compose`，不是旧的 `docker-compose`）。
- 64 位系统，建议至少 2 CPU、4 GB 内存和 10 GB 可用磁盘。
- 本机 `3000` 端口未被占用。端口冲突时，在 `.env` 中修改 `NEW_API_PORT`。

## 启动

在仓库根目录执行：

```bash
cp docker-compose.env.example .env
```

打开 `.env`，至少把 `POSTGRES_PASSWORD`、`REDIS_PASSWORD` 和 `SESSION_SECRET` 换成自己的值。可以用下面的命令生成随机值，再粘贴到 `.env`：

```bash
openssl rand -hex 16   # PostgreSQL 或 Redis 密码
openssl rand -hex 32   # SESSION_SECRET
```

然后校验并启动：

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
```

Compose 会等待 PostgreSQL 和 Redis 通过健康检查后再启动 New API。首次启动会自动拉取镜像并执行数据库迁移，可能需要几分钟。

## 初始化和验证

打开 <http://127.0.0.1:3000>。首次访问会进入初始化页面，按页面提示设置管理员账号和密码；初始化只需要执行一次。

也可以用接口确认容器已经可以响应：

```bash
curl --fail http://127.0.0.1:3000/api/status
curl --fail http://127.0.0.1:3000/api/setup
```

健康状态可直接查看：

```bash
docker inspect --format='{{.State.Health.Status}}' new-api
```

预期 `/api/setup` 返回 `success: true`。刚创建的实例通常会显示 `status: false`、`root_init: false`，这表示还没有完成管理员初始化，不是故障。

## 常用运维命令

```bash
# 实时查看 New API 日志
docker compose logs -f --tail=200 new-api

# 查看全部服务状态
docker compose ps

# 重启（保留数据）
docker compose restart

# 停止并删除容器、网络（保留 PostgreSQL 数据卷）
docker compose down

# 更新镜像并重新创建容器
docker compose pull
docker compose up -d
```

不要在日常停止操作中使用 `docker compose down -v`：`-v` 会删除 `pg_data`，数据库中的用户、渠道、配置和日志将无法从该卷恢复。

## 备份和恢复

备份 PostgreSQL：

```bash
mkdir -p backups
docker compose exec -T postgres sh -c 'pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > "backups/new-api-$(date +%Y%m%d-%H%M%S).sql"
```

恢复前先停止 New API，并确认备份文件和目标数据库无误。下面的命令会删除并重建备份中包含的数据库对象：

```bash
docker compose stop new-api
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < backups/your-backup.sql
docker compose start new-api
```

`data/` 和 `logs/` 也是宿主机目录，建议与 PostgreSQL 备份一起纳入主机级备份。

## 常见问题

### 端口已被占用

在 `.env` 中设置其他端口，例如 `NEW_API_PORT=3001`，然后执行 `docker compose up -d`，访问 <http://127.0.0.1:3001>。

### New API 一直不是 healthy

先看依赖服务和应用日志：

```bash
docker compose ps
docker compose logs --tail=200 postgres redis new-api
```

如果日志中出现 `connection refused`，等待 PostgreSQL 的健康状态变为 `healthy` 后再执行 `docker compose up -d`。如果仍然失败，确认 `.env` 中的数据库密码与 `POSTGRES_PASSWORD` 一致，并检查磁盘空间。

### 修改密码后仍然无法连接 PostgreSQL

PostgreSQL 只在第一次初始化数据卷时读取 `POSTGRES_PASSWORD`。修改 `.env` 不会改变已有数据库用户密码；应使用 `psql` 修改数据库密码，或在确认数据已备份后删除并重新初始化 `pg_data`。

### 如何对外提供 HTTPS 服务

本地 HTTP 适合开发和验证。生产环境应在反向代理后运行，设置强随机 `SESSION_SECRET`，启用 `SESSION_COOKIE_SECURE=true` 并填写精确的 `SESSION_COOKIE_TRUSTED_URL`，同时不要把 PostgreSQL 或 Redis 端口暴露到公网。

## 配置变量

| 变量 | 作用 | 本地示例 |
| --- | --- | --- |
| `NEW_API_BIND_ADDRESS` | 宿主机监听地址 | `127.0.0.1` |
| `NEW_API_PORT` | 宿主机访问端口 | `3000` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | PostgreSQL 初始化账号和数据库 | `root` / 自定义密码 / `new-api` |
| `REDIS_PASSWORD` | Redis 密码，同时用于 New API 连接串 | 自定义密码 |
| `SESSION_SECRET` | 登录会话和令牌签名密钥 | `openssl rand -hex 32` 的输出 |
| `NEW_API_IMAGE` | New API 镜像，可固定版本 | `calciumion/new-api:latest` |

Compose 服务名 `postgres`、`redis` 只在 Docker 网络内使用；不要把 `localhost` 写进 `SQL_DSN` 或 `REDIS_CONN_STRING`，否则容器会连接自身而不是依赖服务。
