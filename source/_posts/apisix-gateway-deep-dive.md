---
title: Apache APISIX 网关核心原理与生产级部署实践
date: 2026-06-17 08:05:00
tags:
  - API网关
  - APISIX
  - Nginx
  - 网关
  - 微服务
categories:
  - 中间件
author: 东哥
---

# Apache APISIX 网关核心原理与生产级部署实践

## 一、为什么需要 API 网关

在微服务架构中，随着服务数量的增长，客户端直接调用各个微服务会面临以下问题：

| 问题 | 说明 |
|------|------|
| 认证授权分散 | 每个服务都要实现登录校验、权限验证 |
| 协议转换复杂 | 内部可能是 gRPC，对外暴露 RESTful |
| 流量控制缺失 | 没有统一的限流、熔断能力 |
| 监控治理困难 | 日志和指标散落在各个服务中 |
| 版本管理混乱 | API 升级难以平滑过渡 |

API 网关作为系统的统一入口，集中处理上述横切关注点。Apache APISIX 作为目前最活跃的开源 API 网关之一，基于 Nginx 和 etcd，具备高性能和动态热更新的特点。

## 二、APISIX 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────┐
│                    Admin API / Dashboard          │
├─────────────────────────────────────────────────┤
│                                                   │
│   ┌─────────────────┐      ┌─────────────────┐   │
│   │   APISIX Node 1  │      │   APISIX Node 2  │   │
│   │ ┌─────────────┐ │      │ ┌─────────────┐ │   │
│   │ │ Route →     │ │      │ │ Route →     │ │   │
│   │ │ Service →   │ │      │ │ Service →   │ │   │
│   │ │ Upstream    │ │      │ │ Upstream    │ │   │
│   │ └─────────────┘ │      │ └─────────────┘ │   │
│   └────────┬────────┘      └────────┬────────┘   │
│            │                        │             │
│            └──────────┬─────────────┘             │
│                       │                           │
│              ┌────────▼────────┐                  │
│              │   etcd 集群     │                  │
│              │  (配置中心)     │                  │
│              └─────────────────┘                  │
└─────────────────────────────────────────────────┘
```

APISIX 与其他基于 Nginx 的网关（如 Kong）最大的区别是：**配置存储使用 etcd**，而非数据库。这使得 APISIX 具备以下优势：
- **毫秒级配置同步**：etcd 的 watch 机制让所有节点实时感知配置变更
- **无中心化热点**：没有数据库瓶颈
- **天生支持集群**：etcd 本身就是分布式协调工具

### 2.2 核心组件

| 组件 | 作用 | 说明 |
|------|------|------|
| Route | 路由规则 | 匹配客户端请求的 URL、Method、Header 等 |
| Service | 服务抽象 | 一组共同的插件配置抽象，可被多个 Route 引用 |
| Upstream | 上游服务 | 真实后端服务的地址列表和负载均衡策略 |
| Consumer | 消费者 | API 调用方身份，用于认证授权 |
| Plugin | 插件 | 扩展 APISIX 功能的核心机制 |
| Admin API | 管理接口 | RESTful 接口，用于动态管理所有配置 |

### 2.3 请求处理流程

```
Client Request
      │
      ▼
┌─────────────┐
│  HTTP Route  │  ← 根据 URI、Method、Header 匹配 Route
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Plugin      │  ← 执行前置插件（认证、限流、日志等）
│  Pre-phase   │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Upstream    │  ← 负载均衡，选择后端节点
│  Load Balance│
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Backend     │  ← 转发请求到后端服务
│  Service     │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Plugin      │  ← 执行后置插件（响应转换、日志记录）
│  Post-phase  │
└──────┬──────┘
       │
       ▼
Client Response
```

## 三、核心功能实战

### 3.1 路由配置示例

通过 Admin API 动态创建路由：

```bash
# 创建路由：匹配 /api/v1/users 路径
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/api/v1/users/*",
    "methods": ["GET", "POST"],
    "hosts": ["api.example.com"],
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "192.168.1.10:8080": 1,
        "192.168.1.11:8080": 1
      }
    },
    "plugins": {
      "limit-count": {
        "count": 1000,
        "time_window": 60,
        "rejected_code": 429
      },
      "key-auth": {}
    }
  }'
```

### 3.2 多种路由匹配方式

```json
// 1. 精确匹配
{ "uri": "/api/v1/users" }

// 2. 前缀匹配
{ "uri": "/api/v1/*" }

// 3. 正则匹配
{ "uri": "/api/v1/users/\\d+" }

// 4. 高级路由：同时按 Method + Header + Query 匹配
{
  "uri": "/api/*",
  "methods": ["GET", "POST"],
  "hosts": ["*.example.com"],
  "remote_addrs": ["192.168.1.0/24"],
  "vars": [
    ["arg_name", "==", "admin"],
    ["http_x-version", ">=", "2.0"]
  ]
}
```

### 3.3 负载均衡策略

APISIX 支持多种负载均衡算法：

```bash
# 配置 Weighted Round Robin（加权轮询）
curl http://127.0.0.1:9180/apisix/admin/upstreams/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "type": "roundrobin",
    "nodes": {
      "10.0.1.10:8080": 10,
      "10.0.1.11:8080": 20,
      "10.0.1.12:8080": 30
    }
  }'

# 一致性哈希（适用于缓存场景）
{
  "type": "chash",
  "hash_on": "header",
  "key": "x-user-id",
  "nodes": {
    "10.0.1.10:8080": 1,
    "10.0.1.11:8080": 1
  }
}
```

| 算法 | 适用场景 | 优势 |
|------|----------|------|
| roundrobin | 通用场景 | 实现简单，请求均匀分布 |
| chash | 缓存、Session 亲和 | 同一用户始终路由到同一节点 |
| least_connections | 长连接、计算密集型 | 避免请求堆积到繁忙节点 |
| ewma | 高并发场景 | 根据响应时间动态调整权重 |

## 四、插件机制详解

### 4.1 内置插件概览

APISIX 拥有超过 80 个内置插件，覆盖网关的大多数场景：

| 分类 | 插件 | 说明 |
|------|------|------|
| 认证 | key-auth, jwt-auth, basic-auth, oauth2, casdoor | 多种身份认证 |
| 安全 | cors, ip-restriction, ua-restriction, referer-restriction | 安全防护 |
| 流量控制 | limit-count, limit-conn, limit-req | 限流限速 |
| 可观测性 | prometheus, skywalking, opentelemetry, datadog | 监控链路 |
| 流量管理 | proxy-rewrite, response-rewrite, redirect | 请求/响应改写 |
| 日志 | kafka-logger, syslog, http-logger, tcp-logger | 日志采集 |

### 4.2 配置限流插件

```bash
# 基于计数器的限流：每分钟最多1000次请求
curl http://127.0.0.1:9180/apisix/admin/routes/1/plugins \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PATCH -d '{
    "limit-count": {
      "count": 1000,
      "time_window": 60,
      "rejected_code": 429,
      "rejected_msg": "请求太频繁，请稍后再试",
      "policy": "local"
    }
  }'
```

限流策略对比：

| 策略 | 存储 | 精度 | 性能 | 适用场景 |
|------|------|------|------|----------|
| local | 本地内存 | 节点级 | 极高 | 单节点部署 |
| redis | Redis | 集群级精确 | 高 | 分布式部署 |
| redis-cluster | Redis Cluster | 集群级精确 | 高 | 大规模集群 |

### 4.3 灰度发布插件

APISIX 原生支持灰度发布，通过 `traffic-split` 插件实现：

```bash
# 10% 流量路由到新版本服务
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/api/v1/orders",
    "plugins": {
      "traffic-split": {
        "rules": [
          {
            "match": [
              {
                "weighted": {
                  "weight": 10
                }
              }
            ],
            "upstream": {
              "type": "roundrobin",
              "nodes": {
                "10.0.1.100:8080": 1
              }
            }
          }
        ]
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "10.0.1.10:8080": 1
      }
    }
  }'
```

## 五、生产级部署方案

### 5.1 Docker-Compose 部署

```yaml
# docker-compose.yml
version: '3.8'

services:
  etcd:
    image: bitnami/etcd:3.5
    environment:
      - ALLOW_NONE_AUTHENTICATION=yes
      - ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379
    networks:
      - apisix-network

  apisix:
    image: apache/apisix:3.8
    ports:
      - "9080:9080"   # HTTP 入口
      - "9180:9180"   # Admin API
      - "9443:9443"   # HTTPS 入口
    volumes:
      - ./apisix/config.yaml:/usr/local/apisix/conf/config.yaml
    depends_on:
      - etcd
    networks:
      - apisix-network

  apisix-dashboard:
    image: apache/apisix-dashboard:3.0
    ports:
      - "9000:9000"
    depends_on:
      - etcd
    networks:
      - apisix-network

networks:
  apisix-network:
    driver: bridge
```

### 5.2 生产配置优化

```yaml
# config.yaml — APISIX 生产配置
apisix:
  node_listen:
    - port: 9080
      enable_http2: true   # 启用 HTTP/2
    - port: 9443
      enable_http2: true
      ssl: true

deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  etcd:
    host:
      - "http://10.0.1.10:2379"
      - "http://10.0.1.11:2379"
      - "http://10.0.1.12:2379"
    prefix: "/apisix"
    timeout: 30

plugin_attr:
  prometheus:
    export_addr:
      ip: "0.0.0.0"
      port: 9091

nginx_config:
  worker_processes: auto
  worker_connections: 40960
  enable_cpu_affinity: true
  error_log:
    level: warn
    file: /dev/stderr
  ssl:
    enable: true
    ssl_protocols: TLSv1.2 TLSv1.3
    ssl_ciphers: ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl_session_cache: shared:SSL:10m
    ssl_session_timeout: 10m
```

### 5.3 性能调优参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| worker_processes | auto | 自动匹配 CPU 核心数 |
| worker_connections | 40960 | 每个 worker 的最大连接数 |
| keepalive | 1024 | 后端连接池大小 |
| lua_max_running_timer | 8 | Lua 定时器最大并发数 |
| lua_worker_threads | 4 | Lua 工作线程数 |
| resolver_timeout | 5s | DNS 解析超时 |
| etcd_timeout | 30s | etcd 请求超时时间 |

## 六、APISIX vs Kong 对比

| 特性 | APISIX | Kong |
|------|--------|------|
| 配置存储 | etcd | PostgreSQL/Cassandra |
| 配置热更新 | 支持（毫秒级） | 支持 |
| 核心语言 | Lua（基于 OpenResty）+ Go/Java/Wasm 多语言 | Lua（基于 OpenResty） |
| 插件数 | 80+ | 200+（含社区） |
| 多语言插件 | Go / Java / Python / Wasm | Go（Kong Plugin Dev Kit） |
| 性能（QPS） | ~150,000 | ~80,000 |
| 延迟（P99） | ~5ms | ~10ms |
| Dashboard | 官方提供 | Kong Manager（企业版） |
| 开源协议 | Apache 2.0 | Apache 2.0 |
| 学习成本 | 低 | 中 |

> 性能数据基于单核 CPU、2GB 内存的相同硬件环境测试。

## 七、最佳实践总结

### 7.1 架构设计建议

1. **分层设计**：API 网关 + Ingress Controller 双层网关架构，API 网关负责南北流量，Ingress 负责东西流量
2. **插件分离**：全局插件在 `global rules` 中配置，业务相关插件在 Route 级别配置
3. **限流兜底**：即使在网关层做了限流，后端服务也需要实现限流保护，避免网关被绕过

### 7.2 运维实践

```bash
# 1. 健康检查
curl http://127.0.0.1:9080/apisix/admin/routes

# 2. 查看所有已配置的插件
curl http://127.0.0.1:9180/apisix/admin/plugins

# 3. Prometheus 指标
curl http://127.0.0.1:9091/apisix/prometheus/metrics | grep apisix_http_requests_total

# 4. 动态配置 Reload（无需重启服务）
# APISIX 不支持 nginx -s reload，但配置变更会实时推送到所有节点
```

### 7.3 高可用部署

- 至少 2 个 APISIX 节点，前端使用 Nginx + Keepalived 做 VIP
- etcd 集群至少 3 节点
- Admin API 绑定内网 IP，不要对外暴露
- 启用 Prometheus 埋点，设置关键指标告警

APISIX 作为新一代云原生 API 网关，在性能、扩展性和云原生生态支持上都非常出色，是构建微服务网关的优先选择之一。
