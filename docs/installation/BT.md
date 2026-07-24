# 宝塔面板部署教程

本文档提供使用宝塔面板 Docker 功能部署 New API 的图文教程。

> 📖 官方文档：[宝塔面板部署](https://docs.newapi.pro/zh/docs/installation/deployment-methods/bt-docker-installation)

***

## 前置要求

| 项目    | 要求                                 |
| ----- | ---------------------------------- |
| 宝塔面板  | ≥ 9.2.0 版本                         |
| 推荐系统  | CentOS 7+、Ubuntu 18.04+、Debian 10+ |
| 服务器配置 | 至少 1 核 2G 内存                       |

***

## 步骤一：安装宝塔面板

1. 前往 [宝塔面板官网](https://www.bt.cn/new/download.html) 下载适合您系统的安装脚本
2. 运行安装脚本安装宝塔面板
3. 安装完成后，使用提供的地址、用户名和密码登录宝塔面板

***

## 步骤二：安装 Docker

1. 登录宝塔面板后，在左侧菜单栏找到并点击 **Docker**
2. 首次进入会提示安装 Docker 服务，点击 **立即安装**
3. 按照提示完成 Docker 服务的安装

***

## 步骤三：安装 New API

### 方法一：部署当前仓库（推荐用于自有代码）

该方法会构建当前仓库中的代码，因此包含你对系统名称、Footer 和其他文件的修改。脚本会在首次运行时创建 `.env`，为 PostgreSQL、Redis、会话和缓存分别生成随机密钥；之后的重复执行会保留已有配置与数据卷，只更新应用容器。

1. 在服务器的宝塔终端中进入已上传或已克隆的仓库目录，例如：

```bash
cd /www/wwwroot/new-api
```

2. 赋予脚本执行权限，并传入宝塔反向代理将使用的公开 HTTPS 域名：

```bash
chmod +x scripts/deploy-baota.sh
bash scripts/deploy-baota.sh --public-url https://api.example.com
```

首次构建通常需要几分钟。脚本完成后，New API 默认只监听 `127.0.0.1:3000`，不会直接暴露 PostgreSQL 或 Redis。

3. 在宝塔面板中创建网站并申请 SSL 证书，然后配置反向代理：

| 配置项 | 值 |
| --- | --- |
| 目标 URL | `http://127.0.0.1:3000` |
| 域名 | `api.example.com` |
| SSL | 为该域名启用 HTTPS |

脚本会把 `SESSION_COOKIE_SECURE=true` 和 `SESSION_COOKIE_TRUSTED_URL=https://api.example.com` 写入 `.env`，因此传入的 URL 必须与用户实际访问的 HTTPS 域名完全一致。

常用命令：

```bash
# 重新构建并部署当前代码，保留数据库和配置
bash scripts/deploy-baota.sh --public-url https://api.example.com

# 仅重建容器，复用已经构建的本地镜像
bash scripts/deploy-baota.sh --skip-build

# 只生成配置并校验，不构建或启动容器
bash scripts/deploy-baota.sh --public-url https://api.example.com --dry-run

# 直接暴露端口（不建议生产环境使用）
bash scripts/deploy-baota.sh --bind-address 0.0.0.0 --port 3000

# 查看应用日志
docker compose logs -f --tail=200 new-api
```

不要执行 `docker compose down -v`，其中的 `-v` 会删除 PostgreSQL 数据卷。

### 方法二：使用宝塔应用商店

1. 在宝塔面板 Docker 功能中，点击 **应用商店**
2. 搜索并找到 **New-API**
3. 点击 **安装**
4. 配置以下基本选项：
   - **容器名称**：可自定义，默认为 `new-api`
   - **端口映射**：默认为 `3000:3000`
   - **环境变量**：
     - `SESSION_SECRET`：会话密钥（**必填**，多机部署时必须一致）
     - `CRYPTO_SECRET`：加密密钥（使用 Redis 时必填）
5. 点击 **确认** 开始安装
6. 等待安装完成后，访问 `http://您的服务器IP:3000` 即可使用

### 方法三：手动使用 Docker Compose

1. 在宝塔面板中创建网站目录，如 `/www/wwwroot/new-api`
2. 创建 `docker-compose.yml` 文件：

```yaml
version: '3'
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - ./data:/data
    environment:
      - SESSION_SECRET=your_session_secret_here  # 请修改为随机字符串
      - TZ=Asia/Shanghai
```

1. 在终端中进入目录并启动：

```bash
cd /www/wwwroot/new-api
docker-compose up -d
```

***

## 配置说明

### 必要环境变量

| 变量名                 | 说明                 | 是否必填   |
| ------------------- | ------------------ | ------ |
| `SESSION_SECRET`    | 会话密钥，多机部署必须一致      | **必填** |
| `CRYPTO_SECRET`     | 加密密钥，使用 Redis 时必填  | 条件必填   |
| `SQL_DSN`           | 数据库连接字符串（使用外部数据库时） | 可选     |
| `REDIS_CONN_STRING` | Redis 连接字符串        | 可选     |

### 生成随机密钥

```bash
# 生成 SESSION_SECRET
openssl rand -hex 16

# 或使用 Linux 命令
head -c 16 /dev/urandom | xxd -p
```

***

## 常见问题

### Q1：无法访问 3000 端口？

1. 检查服务器防火墙是否开放 3000 端口
2. 在宝塔面板 **安全** 中放行 3000 端口
3. 检查云服务器安全组是否开放端口

### Q2：登录后提示会话失效？

确保设置了 `SESSION_SECRET` 环境变量，且值不为空。

### Q3：数据如何持久化？

使用 Docker 卷映射数据目录：

```yaml
volumes:
  - ./data:/data
```

### Q4：如何更新版本？

```bash
# 拉取最新镜像
docker pull calciumion/new-api:latest

# 重启容器
docker-compose down && docker-compose up -d
```

***

## 相关链接

- [官方文档](https://docs.newapi.pro/zh/docs/installation)
- [环境变量配置](https://docs.newapi.pro/zh/docs/installation/config-maintenance/environment-variables)
- [常见问题](https://docs.newapi.pro/zh/docs/support/faq)
- [GitHub 仓库](https://github.com/QuantumNous/new-api)

***

## 截图示例

![宝塔面板 Docker 安装](https://github.com/user-attachments/assets/7a6fc03e-c457-45e4-b8f9-184508fc26b0)

> ⚠️ 注意：密钥为环境变量 `SESSION_SECRET`，请务必设置！
