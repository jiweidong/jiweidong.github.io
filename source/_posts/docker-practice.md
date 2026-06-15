---
title: Docker 容器化从入门到生产实践
date: 2026-06-15 08:00:00
tags:
  - Docker
  - 容器化
  - DevOps
  - 微服务
categories:
  - DevOps
author: 东哥
---

# Docker 容器化从入门到生产实践

> Docker 已经成为现代软件开发中不可或缺的基础设施。无论你是后端开发、前端开发还是运维工程师，掌握 Docker 都是必备技能。本文从零开始，带你全面掌握 Docker。

## 一、Docker 是什么？

Docker 是一个开源的容器化平台，它可以让开发者将应用及其依赖打包到一个轻量级、可移植的容器中，然后发布到任何 Linux 机器上。

### 1.1 容器 vs 虚拟机

| 特性 | 容器 | 虚拟机 |
|------|------|--------|
| 启动速度 | 毫秒级 | 分钟级 |
| 资源占用 | 共享宿主机内核，极低 | 每个 VM 独占 OS，开销大 |
| 磁盘占用 | MB 级别 | GB 级别 |
| 隔离性 | 进程级隔离 | 完全隔离 |

### 1.2 核心概念

- **镜像（Image）**：一个只读模板，包含运行应用所需的文件系统、依赖和配置
- **容器（Container）**：镜像的运行实例，可读可写
- **仓库（Repository）**：集中存储和分发镜像的地方
- **Dockerfile**：构建镜像的指令文件

## 二、Docker 安装与基本操作

### 2.1 安装 Docker

```bash
# Ubuntu / Debian
curl -fsSL https://get.docker.com | bash

# CentOS / RHEL
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install docker-ce docker-ce-cli containerd.io

# 启动并设为开机自启
sudo systemctl start docker
sudo systemctl enable docker
```

### 2.2 镜像管理

```bash
# 拉取镜像
docker pull nginx:latest
docker pull openjdk:17-slim

# 查看本地镜像
docker images

# 删除镜像
docker rmi nginx:latest

# 搜索镜像
docker search mysql
```

### 2.3 容器生命周期

```bash
# 创建并运行容器
docker run -d --name my-nginx -p 80:80 nginx:latest

# 查看运行中的容器
docker ps

# 查看所有容器（含已停止的）
docker ps -a

# 停止容器
docker stop my-nginx

# 启动已停止的容器
docker start my-nginx

# 进入容器内部
docker exec -it my-nginx /bin/bash

# 查看容器日志
docker logs -f my-nginx

# 删除容器
docker rm my-nginx
```

## 三、Dockerfile 编写实战

### 3.1 基础 Dockerfile 示例

```dockerfile
# 基础镜像
FROM openjdk:17-slim

# 维护者
LABEL maintainer="dongge"

# 设置工作目录
WORKDIR /app

# 复制 JAR 包
COPY target/my-app.jar app.jar

# 暴露端口
EXPOSE 8080

# 启动命令
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 3.2 多阶段构建（减小镜像体积）

```dockerfile
# 第一阶段：编译
FROM maven:3.8-openjdk-17 AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

# 第二阶段：运行
FROM openjdk:17-slim
WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 3.3 Dockerfile 最佳实践

1. **选择最小的基础镜像**：使用 `slim` 或 `alpine` 版本
2. **减少层数**：合并 RUN 指令
3. **利用缓存**：将不变的依赖放在前面
4. **使用 .dockerignore**：排除不需要的文件
5. **设置正确的时区**：

```dockerfile
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
```

## 四、Docker Compose 多容器编排

### 4.1 什么是 Docker Compose

Docker Compose 允许你使用 YAML 文件定义和运行多个容器应用。

### 4.2 docker-compose.yml 示例

```yaml
version: '3.8'

services:
  # MySQL 数据库
  mysql:
    image: mysql:8.0
    container_name: my-mysql
    environment:
      MYSQL_ROOT_PASSWORD: root123
      MYSQL_DATABASE: myapp
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - app-net

  # Redis 缓存
  redis:
    image: redis:7-alpine
    container_name: my-redis
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - app-net

  # Spring Boot 应用
  app:
    build: .
    container_name: my-app
    depends_on:
      - mysql
      - redis
    ports:
      - "8080:8080"
    environment:
      SPRING_DATASOURCE_URL: jdbc:mysql://mysql:3306/myapp
      SPRING_REDIS_HOST: redis
    networks:
      - app-net

volumes:
  mysql-data:
  redis-data:

networks:
  app-net:
    driver: bridge
```

### 4.3 Compose 常用命令

```bash
# 启动所有服务
docker-compose up -d

# 停止所有服务
docker-compose down

# 查看日志
docker-compose logs -f

# 重建服务
docker-compose up -d --build

# 查看服务状态
docker-compose ps
```

## 五、Docker 网络与存储

### 5.1 网络模式

- **bridge**（默认）：容器间通过 bridge 网络通信
- **host**：容器直接使用宿主机网络
- **none**：无网络
- **overlay**：跨主机容器通信（Swarm 模式）

```bash
# 创建自定义网络
docker network create --driver bridge my-net

# 容器加入网络
docker run -d --network my-net --name app1 nginx
```

### 5.2 数据持久化

```bash
# Volume（推荐）
docker volume create my-data
docker run -v my-data:/data nginx

# Bind Mount
docker run -v /host/path:/container/path nginx

# tmpfs（内存中）
docker run --tmpfs /tmp nginx
```

## 六、Docker 在生产环境的最佳实践

### 6.1 安全加固

```bash
# 以非 root 用户运行容器
docker run --user 1000:1000 nginx

# 只读根文件系统
docker run --read-only nginx

# 限制资源使用
docker run --memory="512m" --cpus="1.0" nginx
```

### 6.2 健康检查

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1
```

### 6.3 日志管理

```yaml
# 限制日志大小
services:
  app:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

## 七、常见问题与解决方案

### 7.1 容器时区问题

```dockerfile
ENV TZ=Asia/Shanghai
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
```

### 7.2 容器无法访问外网

```bash
# 检查 DNS 配置
docker run --dns 8.8.8.8 --dns 114.114.114.114 nginx
```

### 7.3 清理磁盘空间

```bash
# 清理所有未使用的资源
docker system prune -a

# 查看磁盘占用
docker system df
```

## 八、总结

Docker 技术栈是每个后端工程师的必修课。掌握 Docker 不仅仅是为了"会用"，更重要的是理解其背后的原理和最佳实践。从简单的单容器部署到复杂的多服务编排，Docker 都能提供优雅的解决方案。

下一篇文章我们将探讨 Kubernetes（K8s），学习如何在生产环境中管理大规模的容器集群。
