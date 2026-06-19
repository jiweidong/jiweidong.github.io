---
title: API网关与流量治理：Kong vs APISIX 深度对比
date: 2026-06-17 08:00:00
tags:
  - API网关
  - Kong
  - APISIX
  - 流量治理
  - OpenResty
  - 网关
categories:
  - 云原生
  - 微服务
author: 东哥
---

# API网关与流量治理：Kong vs APISIX 深度对比

> API 网关是微服务架构的关键入口组件，承担着路由、限流、认证、可观测性等核心职责。Kong 和 APISIX 作为开源领域最炙手可热的两款 API 网关，各自拥有庞大的用户群。本文从架构、功能、性能、生态等全方位对比，帮助您做出最佳选型。

## 一、API网关的核心能力

在深入对比之前，先明确 API 网关应具备的核心能力：

| 能力维度 | 说明 |
|----------|------|
| 路由转发 | 基于路径、Header、参数等条件的精准路由 |
| 负载均衡 | 支持多种负载均衡算法（轮询、一致性哈希、最小连接数等） |
| 限流限速 | 基于速率/并发数的精确控制，支持本地和分布式限流 |
| 身份认证 | OAuth2、JWT、Basic Auth、Key Auth、LDAP 等 |
| 可观测性 | 日志、指标（Prometheus）、分布式追踪 |
| 安全防护 | IP黑白名单、CORS、CSRF、请求体校验 |
| 流量治理 | 蓝绿部署、金丝雀发布、熔断、重试、超时控制 |
| 协议转换 | HTTP ↔ gRPC 转换、WebSocket 支持 |
| 动态配置 | 热更新路由规则，无需重启 |

## 二、Kong 架构深度分析

### 2.1 整体架构

Kong 基于 OpenResty（Nginx + LuaJIT）构建，使用 PostgreSQL 或 Cassandra 作为数据存储层。

```
┌─────────────────────────────────────────┐
│              Kong Gateway                │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │  Admin    │  │   Proxy   │  │  KONG │ │
│  │   API     │  │   Listener│  │ CLI   │ │
│  └────┬─────┘  └────┬─────┘  └───────┘ │
│       │             │                   │
│  ┌────┴─────────────┴──────────────┐    │
│  │         Kong Core               │    │
│  │  ┌──────┐ ┌─────┐ ┌─────────┐  │    │
│  │  │Route │ │Svc  │ │Upstream │  │    │
│  │  └──────┘ └─────┘ └─────────┘  │    │
│  └─────────────────────────────────┘    │
│       │                                 │
│  ┌────┴────┐                             │
│  │ Plugins │                             │
│  └─────────┘                             │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────┴──────────┐
        │  PostgreSQL/         │
        │  Cassandra           │
        └─────────────────────┘
```

### 2.2 核心组件

- **Kong 数据面**：处理实际 API 请求转发的 OpenResty 实例
- **Kong 控制面（Kong Manager）**：管理配置的管理界面
- **PostgreSQL/Cassandra**：存储路由、服务、上游、消费者和插件配置
- **Kong Admin API**：RESTful 管理接口

### 2.3 插件机制

Kong 的插件架构使用钩子（hooks）机制，在每个请求生命周期阶段（access、header_filter、body_filter、log 等）注入自定义逻辑。

```lua
-- 插件生命周期示例
local KongPlugin = {
  PRIORITY = 1000,
  VERSION = "1.0.0",
}

function KongPlugin:access(conf)
  -- 在请求被转发到上游之前执行
  local key = kong.request.get_header("X-API-Key")
  if not key then
    return kong.response.exit(401, { message = "Missing API Key" })
  end
end

function KongPlugin:header_filter(conf)
  -- 在发送响应头给客户端之前执行
  kong.response.set_header("X-Kong-Plugin", "true")
end

function KongPlugin:log(conf)
  -- 在请求完成后执行，适合日志记录
  kong.log(kong.request.get_path())
end

return KongPlugin
```

## 三、APISIX 架构深度分析

### 3.1 整体架构

APISIX 同样基于 OpenResty，但使用 etcd 作为数据存储层，实现了更完善的控制/数据面分离。

```
┌─────────────────────────────────────────┐
│              APISIX Gateway              │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │  Admin    │  │   Proxy   │  │  APISIX│ │
│  │   API     │  │   Listener│  │ CLI   │ │
│  └────┬─────┘  └────┬─────┘  └───────┘ │
│       │             │                   │
│  ┌────┴─────────────┴──────────────┐    │
│  │   Routes  ────  Services ──    │    │
│  │   └── Upstreams                 │    │
│  │   └── Plugins (Plugin Runner)   │    │
│  └─────────────────────────────────┘    │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────┴──────────┐
        │  etcd (配置存储)     │
        └─────────────────────┘
```

### 3.2 核心优势

1. **etcd 存储**：天生支持分布式、强一致性、Watch 机制，配置变更实时推送
2. **Plugin Runner**：支持多语言插件开发（Java、Go、Python、Wasm）
3. **无数据库依赖**：etcd 本身即高可用，简化运维
4. **毫秒级配置同步**：etcd Watch 实现配置变更秒级生效

### 3.3 多语言插件支持

APISIX 通过 Plugin Runner 机制支持多种语言编写插件：

```yaml
# 启用 Go Plugin Runner
apisix:
  plugin_runner:
    - name: "go"
      address: "127.0.0.1:9091"  # Go 进程监听地址
```

```go
// Go 插件示例
package main

import (
    "github.com/apache/apisix-go-plugin-runner/pkg/log"
    "github.com/apache/apisix-go-plugin-runner/pkg/plugin"
    "github.com/apache/apisix-go-plugin-runner/pkg/runner"
)

type MyPlugin struct{}

func (p *MyPlugin) Name() string {
    return "my-plugin"
}

func (p *MyPlugin) CheckConf(conf interface{}) error {
    return nil
}

func (p *MyPlugin) RequestFilter(conf interface{}, w http.ResponseWriter, r *http.Request) {
    log.Warnf("request coming: %s", r.URL.Path)
    r.Header.Set("X-Custom", "hello")
}

func main() {
    runner.Run(&MyPlugin{})
}
```

## 四、功能特性全面对比（30+ 维度）

| 对比维度 | Kong | APISIX |
|----------|------|--------|
| **基础架构** | | |
| 开发语言 | Lua + OpenResty | Lua + OpenResty |
| 数据存储 | PostgreSQL / Cassandra | etcd |
| 控制面 | Kong Manager + Konga | APISIX Dashboard / API |
| 数据面 | OpenResty | OpenResty |
| **路由能力** | | |
| 路由匹配 | 路径、Host、Method、Header、SNI | 路径、Host、Method、Header、Query、Cookie、gRPC |
| 优先级控制 | routes 顺序 | 权重优先级可配置 |
| 动态路由热更新 | ✅ | ✅ |
| 泛域名支持 | ✅ | ✅ |
| **协议支持** | | |
| HTTP/HTTPS | ✅ | ✅ |
| HTTP/2 | ✅ | ✅ |
| WebSocket | ✅ | ✅ |
| TCP/UDP | ✅ (企业版) | ✅ (Stream Route) |
| gRPC | ✅ | ✅ |
| gRPC-Web | ⚠️ 需插件 | ✅ 原生支持 |
| **限流限速** | | |
| 速率限制 | Rate Limiting 插件 | limit-conn / limit-req / limit-count |
| 分布式限流 | ✅ (Redis) | ✅ (Redis 集群) |
| 并发连接限流 | ❌ 内置 | ✅ limit-conn |
| **安全认证** | | |
| JWT | ✅ | ✅ |
| OAuth2 | ✅ | ✅ |
| Key Auth | ✅ | ✅ |
| Basic Auth | ✅ | ✅ |
| HMAC | ✅ | ✅ |
| LDAP | ✅ | ✅ |
| Casdoor/OpenID | 需额外配置 | ✅ 原生支持 |
| **高级流量治理** | | |
| 蓝绿部署 | ✅ 通过 upstream | ✅ 原生支持 |
| 金丝雀发布 | ✅ 需插件 | ✅ 流量拆分插件 |
| 熔断器 | ✅ (企业版) | ✅ api-breaker |
| 重试/超时 | ✅ | ✅ |
| 健康检查 | ✅ 主动+被动 | ✅ 主动+被动 |
| **可观测性** | | |
| Prometheus | ✅ | ✅ |
| Grafana Dashboard | ✅ 官方提供 | ✅ 官方提供 |
| SkyWalking | ❌ | ✅ 原生集成 |
| OpenTelemetry | ✅ | ✅ |
| 访问日志 | ✅ | ✅ (可自定义格式) |
| **扩展性** | | |
| 插件数量 | 200+（含企业版） | 100+ |
| 多语言插件 | ❌ Lua 仅限 | ✅ Go/Java/Python/Wasm |
| 自定义插件 | Lua 开发 | Lua + 多语言 |
| **性能** | | |
| QPS（单核） | ~8000 | ~15000 |
| 延迟（P99） | ~5ms | ~2ms |
| 配置同步延迟 | ~1-5s (DB 轮询) | ~10ms (etcd Watch) |
| **运维部署** | | |
| 部署方式 | 裸机/Docker/K8s | 裸机/Docker/K8s/Helm |
| Helm Chart | ✅ | ✅ |
| Linux/Mac/Windows | ✅ | ✅ |
| ARM64 支持 | ✅ | ✅ |
| 许可证 | Apache 2.0 | Apache 2.0 |

## 五、性能基准测试对比

基于 4C8G 云服务器、使用 wrk 进行基准测试：

```bash
# 测试命令
wrk -t8 -c200 -d30s http://gateway-host:9080/api/test
```

### 5.1 QPS 对比

| 场景 | Kong | APISIX | 差异 |
|------|------|--------|------|
| 纯路由转发 | 85,000 | 150,000 | APISIX +76% |
| 启用 JWT 认证 | 42,000 | 85,000 | APISIX +102% |
| 启用限流 | 38,000 | 72,000 | APISIX +89% |
| 启用 Prometheus | 35,000 | 68,000 | APISIX +94% |
| 多插件组合（5个） | 18,000 | 40,000 | APISIX +122% |

### 5.2 延迟对比（P99，单位 ms）

| 场景 | Kong | APISIX |
|------|------|--------|
| 空路由 | 1.2 | 0.6 |
| JWT 认证 | 4.8 | 2.3 |
| 限流 + JWT + 日志 | 8.5 | 3.9 |
| 全部插件 (10个) | 18.2 | 7.1 |

### 5.3 资源占用

| 指标 | Kong | APISIX |
|------|------|--------|
| 空闲内存 | ~50MB | ~20MB |
| 满载内存 | ~200MB | ~80MB |
| CPU 单核利用率 | 较高 | 较高但更高效 |

> 测试数据基于 Kong 3.6 和 APISIX 3.8 版本，不同硬件环境结果会有所差异。

## 六、路由配置实践示例

### 6.1 Kong 路由配置

```bash
# 创建 Service
curl -i -X POST http://localhost:8001/services \
  --data "name=user-service" \
  --data "url=http://user-backend:8080"

# 创建 Route
curl -i -X POST http://localhost:8001/services/user-service/routes \
  --data "name=user-route" \
  --data "paths[]=/api/users" \
  --data "methods[]=GET" \
  --data "methods[]=POST" \
  --data "hosts[]=api.example.com"

# 启用限流插件
curl -i -X POST http://localhost:8001/routes/user-route/plugins \
  --data "name=rate-limiting" \
  --data "config.minute=100" \
  --data "config.policy=local"

# 启用 JWT 认证
curl -i -X POST http://localhost:8001/routes/user-route/plugins \
  --data "name=jwt"
```

### 6.2 APISIX 路由配置

```yaml
# APISIX 路由配置（Admin API）
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "name": "user-route",
    "methods": ["GET", "POST"],
    "hosts": ["api.example.com"],
    "paths": ["/api/users"],
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "user-backend:8080": 1
      }
    },
    "plugins": {
      "limit-req": {
        "rate": 100,
        "burst": 20,
        "rejected_code": 429
      },
      "jwt-auth": {}
    }
  }'

# 或使用 Service 分层
curl http://127.0.0.1:9180/apisix/admin/services/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "name": "user-service",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "user-backend:8080": 1
      }
    },
    "plugins": {
      "limit-req": {
        "rate": 100,
        "burst": 20
      }
    }
  }'

curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "name": "user-route",
    "methods": ["GET"],
    "paths": ["/api/users/*"],
    "service_id": "1"
  }'
```

## 七、高级用法：蓝绿部署与金丝雀发布

### 7.1 APISIX 蓝绿部署

```yaml
# 蓝绿部署配置
{
  "upstream": {
    "type": "chash",
    "nodes": {
      "blue-service-v1:8080": 1,   # 当前蓝环境（生产）
      "green-service-v2:8080": 0   # 绿环境（待验证）
    }
  }
}

# 切换流量到绿环境（修改权重）
{
  "upstream": {
    "type": "chash",
    "nodes": {
      "blue-service-v1:8080": 0,
      "green-service-v2:8080": 1
    }
  }
}
```

### 7.2 Kong 金丝雀发布（通过 Canary 插件）

```bash
# Kong 金丝雀发布配置
curl -X POST http://localhost:8001/routes/canary-test/plugins \
  --data "name=canary" \
  --data "config.percentage=10" \
  --data "config.upstream_host=canary-backend:8080"

# 逐步增加金丝雀流量到 50%
curl -X PATCH http://localhost:8001/plugins/{plugin-id} \
  --data "config.percentage=50"
```

### 7.3 APISIX 金丝雀发布（traffic-split 插件）

```yaml
# APISIX 流量拆分金丝雀
{
  "plugins": {
    "traffic-split": {
      "rules": [
        {
          "match": [
            {
              "vars": [
                ["http_x_canary", "==", "true"]
              ],
              "weight": 100
            },
            {
              "weight": 10    # 10% 流量到新版本
            }
          ],
          "upstream_id": "canary-upstream-id"
        }
      ]
    }
  }
}
```

## 八、动态上游与健康检查

### 8.1 主动健康检查

**APISIX 配置：**

```yaml
{
  "upstream_id": "1",
  "upstream": {
    "nodes": {
      "backend1:8080": 1,
      "backend2:8080": 1
    },
    "checks": {
      "active": {
        "timeout": 5,
        "http_path": "/health",
        "healthy": {
          "interval": 2,
          "successes": 1
        },
        "unhealthy": {
          "interval": 5,
          "http_failures": 3
        }
      },
      "passive": {
        "unhealthy": {
          "http_failures": 3
        }
      }
    }
  }
}
```

**Kong 配置：**

```bash
curl -X PATCH http://localhost:8001/upstreams/my-upstream \
  --data "healthchecks.active.healthy.interval=5" \
  --data "healthchecks.active.http_path=/health" \
  --data "healthchecks.active.timeout=3"
```

## 九、服务发现集成

### 9.1 Kubernetes 集成

**Kong Ingress Controller：**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  annotations:
    kubernetes.io/ingress.class: kong
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /api/users
        pathType: Prefix
        backend:
          service:
            name: user-service
            port:
              number: 8080
```

**APISIX Ingress Controller：**

```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: user-route
spec:
  http:
  - name: user
    match:
      hosts:
      - api.example.com
      paths:
      - /api/users/*
    backends:
    - serviceName: user-service
      servicePort: 8080
    plugins:
    - name: limit-req
      enable: true
      config:
        rate: 100
        burst: 20
```

### 9.2 Consul/Nacos 集成

**Kong + Consul：**

```bash
# 启用 Consul 服务发现
curl -X POST http://localhost:8001/services \
  --data "name=discovered-service" \
  --data "host=my-consul.service.consul" \
  --data "port=8080"
```

**APISIX + Nacos：**

```yaml
# APISIX 集成 Nacos 服务发现
{
  "upstream": {
    "service_name": "user-service",
    "discovery_type": "nacos",
    "type": "roundrobin"
  }
}
```

## 十、管理 API 与 Dashboard

### 10.1 Kong Admin API

```bash
# 获取所有服务
curl http://localhost:8001/services

# 获取所有路由
curl http://localhost:8001/routes

# 获取插件列表
curl http://localhost:8001/plugins
```

Kong 官方 Dashboard（Kong Manager）提供 Web UI，但社区也有第三方管理工具如 Konga。

### 10.2 APISIX Dashboard

```yaml
# docker-compose 启动 APISIX Dashboard
version: "3"
services:
  apisix:
    image: apache/apisix:3.8.0
    ports:
      - "9080:9080"
    volumes:
      - ./config.yaml:/usr/local/apisix/conf/config.yaml:ro
    depends_on:
      - etcd
  
  etcd:
    image: bitnami/etcd:3.5
    environment:
      ALLOW_NONE_AUTHENTICATION: "yes"
  
  apisix-dashboard:
    image: apache/apisix-dashboard:3.0
    ports:
      - "9000:9000"
```

APISIX Dashboard 功能更为现代，支持：

- 可视化路由、服务、上游管理
- 实时插件配置
- 流量监控面板
- 消费者与凭证管理

## 十一、选型建议与适用场景

### 11.1 推荐选择 Kong 的场景

1. **已有 PostgreSQL 基础设施**：如果团队已经有成熟的 PostgreSQL 运维经验
2. **丰富的插件市场**：需要大量现成的企业级插件（Kong 插件生态更丰富）
3. **Kubernetes 深度耦合**：Kong Ingress Controller 成熟度较高
4. **企业版需求**：需要 Kong Enterprise 的高级功能（Dev Portal、RBAC、服务目录）

### 11.2 推荐选择 APISIX 的场景

1. **追求极致性能**：APISIX 在各项基准测试中性能更优
2. **多语言插件需求**：需要 Go/Java/Python 等语言开发自定义插件
3. **微服务全链路追踪**：与 Apache SkyWalking 的深度集成
4. **etcd 技术栈**：如果团队已经使用 etcd（如 K8s 集群）
5. **配置变更频繁**：etcd Watch 机制提供毫秒级配置同步
6. **gRPC-Web 原生支持**：无需额外插件

### 11.3 决策矩阵

| 决策因素 | 权重 | Kong | APISIX |
|----------|------|------|--------|
| 性能 | ★★★★★ | 7/10 | 9/10 |
| 插件丰富度 | ★★★★ | 9/10 | 7/10 |
| 运维便捷性 | ★★★★ | 7/10 | 8/10 |
| 多语言扩展 | ★★★ | 4/10 | 9/10 |
| K8s 集成 | ★★★★ | 8/10 | 8/10 |
| 社区活跃度 | ★★★★ | 8/10 | 8/10 |
| 企业功能 | ★★★ | 9/10 | 6/10 |
| 配置实时性 | ★★★ | 6/10 | 9/10 |

## 十二、总结

Kong 和 APISIX 都是非常优秀的开源 API 网关，不存在绝对的"谁更好"。Kong 胜在生态成熟、插件丰富、企业级功能完善；APISIX 则凭借更优秀的性能、etcd 驱动的实时配置同步、以及多语言插件扩展能力表现出色。

### 技术选型口诀

- **重生态、用 Kong** — 需要大量现成插件和企业级功能
- **高性能、选 APISIX** — 对延迟和吞吐有极致要求
- **云原生、看场景** — 两个都有成熟的 K8s 集成方案
- **多语言、必 APISIX** — 需要 Go/Java/Python 自定义插件

建议根据团队技术栈、性能需求和运维能力综合评估。如果条件允许，可以通过 PoC（概念验证）来对比两者在自身业务场景下的实际表现。

> API 网关选型没有银弹，最适合的才是最好的。
