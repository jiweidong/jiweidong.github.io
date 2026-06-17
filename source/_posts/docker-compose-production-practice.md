---
title: Docker Compose 生产级编排最佳实践
date: 2026-06-17 09:00:00
tags:
  - Docker
  - Docker Compose
  - 容器编排
  - DevOps
categories:
  - DevOps
author: 东哥
---

# Docker Compose 生产级编排最佳实践

## 一、从开发到生产：Compose 的定位

很多人觉得 Docker Compose 只是个"玩具"，只适合本地开发环境。实际上，在中小规模的生产环境中，Docker Compose 完全能够胜任编排工作，甚至在某些场景下比 Kubernetes 更加轻量高效。

### 1.1 Compose 适用场景矩阵

| 场景 | Compose | Kubernetes | 说明 |
|------|---------|-----------|------|
| 本地开发 | ⭐⭐⭐⭐⭐ | ⭐⭐ | 启动快、配置简单 |
| CI/CD 测试环境 | ⭐⭐⭐⭐ | ⭐⭐⭐ | 单机测试足够 |
| 小团队生产（<10服务） | ⭐⭐⭐⭐ | ⭐⭐⭐ | 运维成本低 |
| 中大规模生产 | ⭐⭐ | ⭐⭐⭐⭐⭐ | 需要自愈、扩缩容 |
| 边缘计算 | ⭐⭐⭐⭐⭐ | ⭐⭐ | 资源敏感 |
| 单机部署 | ⭐⭐⭐⭐⭐ | ⭐ | 杀鸡不用牛刀 |

## 二、Compose 文件最佳实践

### 2.1 分层架构设计

一个生产级的 docker-compose.yml 应该遵循分层设计思想：

```yaml
version: '3.8'

# 1. 全局配置层
x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"

x-healthcheck: &default-healthcheck
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 40s

# 2. 服务定义层
services:
  # 2.1 网关层
  gateway:
    image: nginx:1.25-alpine
    restart: unless-stopped
    logging: *default-logging
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
    ports:
      - "443:443"
      - "80:80"
    networks:
      - frontend
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "nginx", "-t"]
    depends_on:
      app:
        condition: service_healthy
  
  # 2.2 应用层
  app:
    image: registry.example.com/order-service:${TAG:-latest}
    restart: unless-stopped
    logging: *default-logging
    expose:
      - "8080"
    environment:
      - SPRING_PROFILES_ACTIVE=${PROFILE:-prod}
      - DB_HOST=mysql
      - REDIS_HOST=redis
      - MQ_HOST=rabbitmq
    volumes:
      - ./logs/app:/app/logs
    networks:
      - frontend
      - backend
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
      rabbitmq:
        condition: service_healthy
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
  
  # 2.3 数据层
  mysql:
    image: mysql:8.0
    restart: unless-stopped
    logging: *default-logging
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --max_connections=200
      - --innodb_buffer_pool_size=1G
      - --slow_query_log=1
      - --long_query_time=2
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: order_db
    volumes:
      - mysql-data:/var/lib/mysql
      - ./mysql/init:/docker-entrypoint-initdb.d
      - ./mysql/conf:/etc/mysql/conf.d:ro
    networks:
      - backend
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
    deploy:
      resources:
        limits:
          memory: 2G
  
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    logging: *default-logging
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis-data:/data
    networks:
      - backend
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "redis-cli", "ping"]

  rabbitmq:
    image: rabbitmq:3.12-management-alpine
    restart: unless-stopped
    logging: *default-logging
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASS}
      RABBITMQ_DEFAULT_VHOST: /
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    networks:
      - backend
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "rabbitmq-diagnostics", "check_port_connectivity"]

# 3. 网络层
networks:
  frontend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
  backend:
    driver: bridge
    internal: true  # 禁止外部访问
    ipam:
      config:
        - subnet: 172.20.1.0/24

# 4. 存储层
volumes:
  mysql-data:
    driver: local
    driver_opts:
      type: none
      device: /data/mysql
      o: bind
  redis-data:
    driver: local
  rabbitmq-data:
    driver: local
```

## 三. 生产环境关键配置

### 3.1 .env 文件管理

```
# .env.production
PROFILE=prod
TAG=v3.2.1
DB_ROOT_PASSWORD=xxxxx
REDIS_PASSWORD=xxxxx
RABBITMQ_USER=admin
RABBITMQ_PASS=xxxxx
```

使用方式：
```bash
# 启动生产环境
docker compose --env-file .env.production up -d

# 启动预发布环境
docker compose --env-file .env.staging up -d
```

### 3.2 健康检查与依赖顺序

正确设置 `depends_on` 和 `healthcheck` 可以避免"启动竞态"问题：

```yaml
services:
  app:
    depends_on:
      mysql:
        condition: service_healthy   # 等 MySQL 就绪
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
```

### 3.3 日志管理与轮转

Docker 默认的日志驱动是 json-file，如果不加限制，一个服务可能吃掉整个磁盘：

```yaml
x-logging: &json-logging
  driver: "json-file"
  options:
    max-size: "10m"      # 单个日志文件最大 10MB
    max-file: "5"        # 最多保留 5 个文件
    compress: "true"     # 轮转后压缩

x-logging: &syslog-logging
  driver: "syslog"
  options:
    syslog-address: "tcp://logstash:5000"
    tag: "{{.Name}}/{{.ID}}"
```

### 3.4 资源限制

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1G
        reservations:
          cpus: '0.25'
          memory: 256M
```

推荐的内存分配策略：

| 服务类型 | 内存限额 | CPU 限额 | 说明 |
|---------|---------|---------|------|
| Java 应用 | -Xmx + 25% | 2-4 core | 预留 GC 和 JVM 自身开销 |
| Node.js 应用 | 256M-512M | 1 core | 单线程事件循环 |
| Nginx | 128M-256M | 0.5-1 core | 静态文件代理 |
| MySQL | 物理内存 50% | 4-8 core | InnoDB 缓存池占用大头 |
| Redis | 数据量 2x | 1-2 core | RDB/AOF 写时需要额外内存 |

## 四、多环境管理

### 4.1 Compose 文件覆盖

```yaml
# docker-compose.yml (基础配置)
services:
  app:
    image: order-service:latest
    ports:
      - "8080"
    environment:
      - SPRING_PROFILES_ACTIVE=dev

# docker-compose.prod.yml (生产覆盖)
services:
  app:
    image: registry.example.com/order-service:${TAG}
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=prod
    deploy:
      replicas: 3        # 生产环境多副本
    restart: always

# 启动方式
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### 4.2 健康检查 + 滚动更新

```yaml
services:
  app:
    deploy:
      replicas: 3
      update_config:
        parallelism: 1           # 一次更新一个副本
        delay: 10s              # 两个副本间的延迟
        failure_action: rollback # 失败时回滚
        monitor: 30s            # 检查健康状态 30s
        order: start-first      # 先启动新容器再停止旧容器
      rollback_config:
        parallelism: 1
        failure_action: pause
        monitor: 30s
```

## 五、监控与运维

### 5.1 内置监控栈

```yaml
services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    ports:
      - "8088:8080"
    networks:
      - monitoring

  node-exporter:
    image: prom/node-exporter:latest
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    ports:
      - "9100:9100"
    networks:
      - monitoring

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_INSTALL_PLUGINS=grafana-clock-panel
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    ports:
      - "3000:3000"
    networks:
      - monitoring
```

### 5.2 日常运维命令

```bash
# 查看所有容器的健康状态
docker compose ps -a

# 查看某个服务的日志（实时）
docker compose logs -f --tail=100 app

# 重启某个服务（不影响其他服务）
docker compose restart app

# 重新创建某个服务
docker compose up -d --force-recreate --no-deps app

# 缩容
docker compose up -d --scale app=5

# 查看资源使用
docker stats $(docker compose ps -q)

# 定期清理
docker system prune -af --volumes
```

## 六、安全加固

### 6.1 最小权限原则

```yaml
services:
  app:
    # 使用非 root 用户运行
    user: "1000:1000"
    # 限制系统调用
    security_opt:
      - no-new-privileges:true
    # 只读根文件系统
    read_only: true
    # 允许写入的目录
    tmpfs:
      - /tmp
      - /var/tmp
    volumes:
      - app-logs:/app/logs
    # 内核能力最小化
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # 只允许绑定低端口
```

### 6.2 Secrets 管理

```yaml
services:
  app:
    secrets:
      - db_password
      - jwt_secret

secrets:
  db_password:
    file: ./secrets/db_password.txt
  jwt_secret:
    external: true  # 使用外部 secrets 管理
```

## 七、Compose 到 K8s 的迁移路径

当服务规模增长到需要 Kubernetes 时，Compose 积累的配置可以平滑迁移：

| Compose 概念 | K8s 对应 | 转换方式 |
|-------------|---------|---------|
| service | Deployment + Service | kompose convert |
| networks | NetworkPolicy | 手动配置 |
| volumes | PersistentVolumeClaim | 迁移数据 |
| depends_on | initContainers + readinessProbe | 配置探活 |
| healthcheck | livenessProbe / readinessProbe | 保持配置 |
| deploy.resources | resources.limits/requests | 直接映射 |

```bash
# 使用 kompose 一键转换
kompose convert -f docker-compose.yml -o k8s-manifests/
```

Docker Compose 是一个非常实用的编排工具，在团队规模不大、服务数量可控的场景下，它能提供比 K8s 更简洁的运维体验。关键是掌握正确的配置方法和管理规范，让它在生产环境中稳定运行。
