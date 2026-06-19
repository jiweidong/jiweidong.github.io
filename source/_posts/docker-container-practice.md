---
title: Docker容器化实战：从入门到生产部署
date: 2026-06-17 08:00:00
tags:
  - Docker
  - 容器化
  - DevOps
  - 部署
  - K8s
categories: DevOps
author: 东哥
---

# Docker容器化实战：从入门到生产部署

## 一、为什么需要容器化？

在传统部署模式中，"在我机器上能跑"是开发与运维之间永恒的矛盾。环境不一致、依赖冲突、版本差异等问题让应用部署充满了不确定性。Docker通过容器化技术将应用及其依赖打包为一个标准化的镜像，从根本上解决了这个问题。

| 对比维度 | 传统部署 | 虚拟机部署 | Docker容器化 |
|---------|---------|-----------|------------|
| 启动速度 | 分钟级 | 分钟级 | 秒级 |
| 资源占用 | 高 | 中等 | 极低 |
| 镜像大小 | N/A | GB级 | MB级 |
| 一致性 | 差 | 好 | 极好 |
| 可移植性 | 差 | 中 | 极好 |

## 二、Docker核心概念

### 2.1 镜像（Image）

镜像是只读的模板，包含了运行应用所需的完整环境：操作系统依赖、运行时、应用代码和配置。镜像由多层组成，每一层代表Dockerfile中的一条指令。

```dockerfile
# 多阶段构建示例
# 第一阶段：编译
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

# 第二阶段：运行
FROM eclipse-temurin:17-jre-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder /app/target/app.jar app.jar
USER appuser
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 2.2 容器（Container）

容器是镜像的运行实例，拥有自己独立的文件系统、网络栈和进程空间。多个容器共享宿主机内核，但彼此隔离。

```bash
# 常用容器管理命令
docker run -d --name myapp -p 8080:8080 myapp:latest
docker ps -a                    # 查看所有容器
docker logs -f myapp            # 查看日志
docker exec -it myapp /bin/sh   # 进入容器
docker stats                    # 查看资源占用
```

### 2.3 数据管理

容器销毁后数据也会丢失，因此需要数据持久化方案：

```bash
# 方式一：绑定挂载
docker run -v /host/data:/app/data myapp

# 方式二：命名卷（推荐生产使用）
docker volume create app-data
docker run -v app-data:/app/data myapp

# 方式三：tmpfs（内存挂载，适合敏感数据）
docker run --tmpfs /app/tmp:rw,noexec,nosuid,size=64m myapp
```

## 三、Docker Compose编排

对于微服务架构，手动管理多个容器是不现实的。Docker Compose通过YAML文件定义多容器应用：

```yaml
version: '3.8'

services:
  # MySQL数据库
  mysql:
    image: mysql:8.0
    container_name: blog-mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD}
      MYSQL_DATABASE: blog
      MYSQL_USER: blog_user
      MYSQL_PASSWORD: ${DB_USER_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
      - ./init-scripts:/docker-entrypoint-initdb.d
    ports:
      - "3306:3306"
    networks:
      - blog-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis缓存
  redis:
    image: redis:7-alpine
    container_name: blog-redis
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis-data:/data
    ports:
      - "6379:6379"
    networks:
      - blog-net

  # 后端应用
  app:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: blog-app
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    environment:
      SPRING_DATASOURCE_URL: jdbc:mysql://mysql:3306/blog?useSSL=false&serverTimezone=Asia/Shanghai
      SPRING_DATASOURCE_USERNAME: blog_user
      SPRING_DATASOURCE_PASSWORD: ${DB_USER_PASSWORD}
      SPRING_REDIS_HOST: redis
      SPRING_REDIS_PASSWORD: ${REDIS_PASSWORD}
    ports:
      - "8080:8080"
    networks:
      - blog-net
    restart: unless-stopped

  # Nginx反向代理
  nginx:
    image: nginx:1.25-alpine
    container_name: blog-nginx
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./frontend/dist:/usr/share/nginx/html:ro
    ports:
      - "80:80"
      - "443:443"
    depends_on:
      - app
    networks:
      - blog-net

networks:
  blog-net:
    driver: bridge

volumes:
  mysql-data:
  redis-data:
```

## 四、Dockerfile最佳实践

### 4.1 镜像瘦身原则

```dockerfile
# ❌ 不好的做法：依赖包也留在了最终镜像中
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y build-essential
RUN apt-get install -y curl
# ... 应用代码

# ✅ 好的做法：清理缓存，合并命令
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# ✅ 更好的做法：多阶段构建
FROM golang:1.21 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o server

FROM alpine:3.18
RUN apk --no-cache add ca-certificates tzdata
COPY --from=builder /app/server /server
CMD ["/server"]
```

### 4.2 .dockerignore配置

```dockerfile
.git/
.gitignore
node_modules/
target/
*.log
.env
.idea/
*.md
Dockerfile
docker-compose*.yml
```

## 五、生产环境部署要点

### 5.1 日志管理

Docker默认将日志输出到json-file驱动，生产环境建议使用更专业的方案：

```yaml
# docker-compose.yml 配置
services:
  app:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

### 5.2 资源限制

```bash
# 内存限制
docker run -m 512m --memory-reservation 256m myapp

# CPU限制
docker run --cpus=1.5 --cpuset-cpus=0,1 myapp

# 重启策略
docker run --restart=unless-stopped myapp
```

### 5.3 健康检查

```yaml
services:
  app:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### 5.4 安全最佳实践

```dockerfile
# 1. 不要以root运行
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# 2. 最小化镜像
FROM alpine:3.18

# 3. 定期扫描漏洞
# docker scan myapp:latest

# 4. 使用只读文件系统
docker run --read-only --tmpfs /tmp --tmpfs /var/run myapp
```

## 六、常见问题与排错

### 6.1 容器无法启动

```bash
# 查看详细错误
docker logs container_name

# 检查退出码含义
docker inspect container_name --format='{{.State.ExitCode}}'

# 进入容器调试
docker run -it --entrypoint /bin/sh myapp
```

### 6.2 网络问题排查

```bash
# 查看容器网络
docker network ls
docker network inspect bridge

# 容器间连通性测试
docker exec app ping mysql

# DNS排查
docker exec app cat /etc/resolv.conf
```

### 6.3 磁盘空间清理

```bash
# 查看磁盘占用
docker system df

# 清理未使用的资源
docker system prune -a --volumes

# 按大小排序查看镜像
docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | sort -k2 -h
```

## 七、总结

Docker容器化是现代应用交付的标准方式。通过容器化，团队实现了"构建一次，到处运行"的承诺，显著提升了开发效率和部署可靠性。本文从基本概念到生产实践，覆盖了Docker使用的完整链路。记住几个核心原则：镜像最小化、安全优先、日志外置、资源限制、健康检查。掌握了这些，你的容器化之旅就成功了一大半。

在生产环境中，建议进一步结合Kubernetes进行容器编排，实现自动扩缩容、滚动更新和自愈能力，构建真正云原生的应用架构。
