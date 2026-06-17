---
title: 灰度发布与蓝绿部署实战：Nginx / APISIX / Kubernetes 实现流量管理
date: 2026-06-17 08:50:00
tags:
  - 灰度发布
  - 蓝绿部署
  - DevOps
  - Kubernetes
  - Nginx
  - APISIX
categories:
  - DevOps
author: 东哥
---

# 灰度发布与蓝绿部署实战：Nginx / APISIX / Kubernetes 实现流量管理

## 一、为什么要做灰度发布

### 1.1 传统发布的痛点

```bash
# 传统发布方式：直接全量更新
# 1. 停服 → 2. 更新代码 → 3. 重启 → 4. 恢复
# 问题：如果新版本有 Bug，影响所有用户
```

| 发布方式 | 影响范围 | 回滚速度 | 风险等级 | 用户体验 |
|----------|----------|----------|----------|----------|
| 全量发布 | 所有用户 | 慢（需要重新部署） | 高 | 可能有停机 |
| 蓝绿部署 | 切换瞬间影响 | 快（切换 LB） | 中 | 基本无感 |
| 灰度发布 | 小部分用户 | 立即（调整路由） | 低 | 无感 |
| 金丝雀发布 | 少量用户 | 立即 | 极低 | 无感 |

### 1.2 发布策略选择

```
决策树：
新版本风险如何？
├── 极低风险（纯配置变更）→ 全量发布
├── 低风险（常规功能迭代）→ 灰度发布 10% → 验证 → 全量
├── 中风险（核心功能重构）→ 金丝雀 1% → 灰度 10% → 50% → 全量
└── 高风险（底层架构变更）→ 蓝绿部署 + 灰度
```

## 二、蓝绿部署

### 2.1 原理

```
蓝绿部署维护两套完全相同的环境：
正常流量         负载均衡器         切换开关
       │                 │
       ├────────────────►│
                         │
                  ┌──────┴──────┐
                  │  Blue (v1)  │ ← 当前生产环境
                  │  100% 流量   │
                  └─────────────┘

                  ┌─────────────┐
                  │  Green (v2) │ ← 新版本，测试通过后
                  │  0% 流量     │   切换流量至此
                  └─────────────┘
```

### 2.2 Nginx 实现蓝绿部署

```nginx
# 蓝绿部署配置
upstream blue {
    server 10.0.1.10:8080 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:8080 max_fails=3 fail_timeout=30s;
}

upstream green {
    server 10.0.2.10:8080 max_fails=3 fail_timeout=30s;
    server 10.0.2.11:8080 max_fails=3 fail_timeout=30s;
}

# 默认指向 Blue 环境
map $cookie_x_env $backend {
    default "blue";
    "blue"   "blue";
    "green"  "green";
}

server {
    listen 443 ssl;
    server_name api.example.com;

    location / {
        # 通过 Cookie 切换环境（用于内部测试）
        if ($cookie_x_env = "green") {
            proxy_pass http://green;
            break;
        }
        proxy_pass http://blue;  # 默认走 Blue
    }

    # 健康检查端点
    location /health {
        proxy_pass http://blue/health;
        proxy_pass http://green/health;
    }
}

# 通过管理接口切换（需要配合 Lua 或 njs）
# 生产环境切换命令：
# mv /etc/nginx/conf.d/blue.conf /etc/nginx/conf.d/blue.conf.bak
# nginx -s reload
```

### 2.3 Kubernetes 蓝绿部署

```yaml
# 1. Blue 环境 Service
apiVersion: v1
kind: Service
metadata:
  name: my-app
  labels:
    app: my-app
spec:
  selector:
    app: my-app
    version: blue    # 选择 blue 版本
  ports:
    - port: 8080
      targetPort: 8080
---
# 2. Blue 部署
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-blue
  labels:
    app: my-app
    version: blue
spec:
  replicas: 5
  selector:
    matchLabels:
      app: my-app
      version: blue
  template:
    metadata:
      labels:
        app: my-app
        version: blue
    spec:
      containers:
        - name: my-app
          image: registry/my-app:1.0.0
---
# 3. Green 部署（新版本）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-green
  labels:
    app: my-app
    version: green
spec:
  replicas: 5
  selector:
    matchLabels:
      app: my-app
      version: green
  template:
    metadata:
      labels:
        app: my-app
        version: green
    spec:
      containers:
        - name: my-app
          image: registry/my-app:2.0.0
```

```bash
# 切换流量：修改 Service 的 selector
kubectl patch service my-app -p '{"spec":{"selector":{"app":"my-app","version":"green"}}}'

# 回滚
kubectl patch service my-app -p '{"spec":{"selector":{"app":"my-app","version":"blue"}}}'
```

### 2.4 蓝绿部署的优缺点

| 优点 | 缺点 |
|------|------|
| 切换速度快（秒级） | 需要双倍资源（2倍服务器成本） |
| 回滚简单（切换回去即可） | 数据库兼容性问题（Schema 变更） |
| 测试生产一致性强 | 切换瞬间有会话丢失风险 |
| 流程清晰，自动化容易 | 长时间运行的连接会中断 |

## 三、灰度发布

### 3.1 Nginx + Cookie 灰度

```nginx
# 基于 Cookie 的灰度发布
split_clients "${remote_addr}${http_user_agent}" $variant {
    10%    "v2";
    *      "v1";
}

upstream app_v1 {
    server 10.0.1.10:8080;
    server 10.0.1.11:8080;
}

upstream app_v2 {
    server 10.0.2.10:8080;
    server 10.0.2.11:8080;
}

server {
    listen 80;
    server_name api.example.com;

    # 灰度规则：Cookie 中带 canary=true 或随机 10%
    set $backend "v1";
    
    # 1. Cookie 指定（用于内部白名单测试）
    if ($cookie_canary = "true") {
        set $backend "v2";
    }
    
    # 2. 根据用户 ID 所在区间
    if ($cookie_user_id ~ "^[0-9]") {
        set $user_prefix "${cookie_user_id}";
        # 这里用 Lua 或 njs 判断用户 ID 是否在灰度范围内
    }

    location / {
        proxy_pass http://app_$backend;
        
        # 添加版本标识 Response Header
        add_header X-App-Version $backend;
    }
}
```

### 3.2 APISIX 灰度实现

```bash
# APISIX 灰度发布——权重配置
# 10% 流量到 v2 版本
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: edd1c9f034335f136f87ad84b625c8f1" \
  -X PUT -d '{
    "uri": "/api/*",
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
              "name": "app-v2",
              "type": "roundrobin",
              "nodes": {
                "10.0.2.10:8080": 1
              }
            }
          }
        ]
      },
      "prometheus": {}
    },
    "upstream": {
      "name": "app-v1",
      "type": "roundrobin",
      "nodes": {
        "10.0.1.10:8080": 1,
        "10.0.1.11:8080": 1
      }
    }
  }'

# 查询参数灰度
curl http://127.0.0.1:9180/apisix/admin/routes/1 \
  -X PUT -d '{
    "uri": "/api/*",
    "vars": [
      ["arg_v","==","2"]
    ],
    "upstream": {
      "name": "app-v2",
      "nodes": {
        "10.0.2.10:8080": 1
      }
    }
  }'
```

### 3.3 Kubernetes Istio 灰度

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-app
spec:
  hosts:
    - my-app
  http:
    # 条件路由
    - match:
        - headers:
            x-canary:
              exact: "true"
        - sourceLabels:
            app: tester
      route:
        - destination:
            host: my-app
            subset: v2
    - match:
        - uri:
            prefix: /api/v2
      rewrite:
        uri: /api/v1
      route:
        - destination:
            host: my-app
            subset: v2
    # 默认路由到 v1
    - route:
        - destination:
            host: my-app
            subset: v1
          weight: 90
        - destination:
            host: my-app
            subset: v2
          weight: 10
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-app
spec:
  host: my-app
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

### 3.4 K8s Ingress 灰度

```yaml
# 使用 NGINX Ingress 的灰度注解
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"                    # 启用灰度
    nginx.ingress.kubernetes.io/canary-weight: "10"               # 10% 流量
    nginx.ingress.kubernetes.io/canary-by-header: "x-canary"     # Header 灰度
    nginx.ingress.kubernetes.io/canary-by-header-value: "true"   # Header 值
    nginx.ingress.kubernetes.io/canary-by-cookie: "canary"       # Cookie 灰度
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app-v2
                port:
                  number: 8080
```

## 四、灰度发布的最佳实践

### 4.1 灰度流程

```
审查 ← 代码提交
  │
  开发环境部署
  │
  测试环境验证（自动化测试 + 人工验证）
  │
  预发环境（Staging）——和线上同一套基础设施
  │
  ┌─ 灰度发布计划 ──────────────────────┐
  │                                     │
  │  阶段1：内部白名单（1% - 5%）         │
  │    → 内部员工 + 测试账号              │
  │    → 验证基本功能                      │
  │                                     │
  │  阶段2：小流量（10%）                 │
  │    → 开放给小部分真实用户              │
  │    → 监控核心指标（错误率、延迟、业务量）│
  │                                     │
  │  阶段3：中流量（50%）                 │
  │    → 观察业务指标是否有影响            │
  │    → 检查数据库、中间件负载            │
  │                                     │
  │  阶段4：全量（100%）                  │
  │    → 确认无问题，发布全量              │
  │                                     │
  └─────────────────────────────────────┘
  │
  全量发布后持续观察
  │
  下线旧版本
```

### 4.2 灰度监控指标

| 指标 | 说明 | 告警阈值 | 优先级 |
|------|------|----------|--------|
| 错误率 | HTTP 5xx 比例 | > 0.1% | P0 |
| 请求延迟 P99 | 最慢 1% 的请求耗时 | > 基线 + 20% | P0 |
| 请求延迟 P50 | 中位数延迟 | > 基线 + 10% | P1 |
| 吞吐量 | QPS 变化 | 下降 > 20% | P1 |
| 业务转化率 | 核心业务指标 | 下降 > 5% | P0 |
| GC 频率 | Full GC 频率 | > 基线 + 50% | P2 |
| CPU/内存 | 资源使用率 | > 85% | P1 |

### 4.3 自动回滚策略

```yaml
# 灰度发布自动回滚配置
rollback:
  # 自动回滚条件：任一条件满足即触发
  conditions:
    - metric: error_rate
      operator: ">"
      threshold: 0.005    # 错误率超过 0.5%
      duration: 5m         # 持续 5 分钟
    - metric: p99_latency
      operator: ">"
      threshold: 2000      # P99 延迟超过 2000ms
      duration: 3m
    - metric: business_metric
      operator: "<"
      threshold: 0.95      # 业务指标低于基线 95%
      duration: 10m

  # 回滚动作
  actions:
    - type: adjust_weight
      value: 0             # 将灰度流量降为 0
    - type: alert
      channels: [slack, pagerduty]
    - type: log
      message: "灰度发布自动回滚: $reason"
```

## 五、数据库灰度

### 5.1 数据库兼容性策略

```java
// 兼容双版本的 SQL 写法
public interface OrderRepository extends JpaRepository<Order, Long> {

    // 注意：灰度期间不能修改老的查询接口
    // ✅ 安全：新增字段使用默认值
    @Query("SELECT o FROM Order o WHERE o.id = :id")
    Optional<Order> findById(@Param("id") Long id);
}

// Flyway 迁移策略
// V1__init.sql → V2__add_new_column.sql → V3__backfill.sql
// 每个版本都兼容前后两个版本
```

### 5.2 数据库灰度步骤

```
Step 1: 添加新字段（允许 NULL 或默认值）
ALTER TABLE orders ADD COLUMN new_status VARCHAR(20) DEFAULT NULL;

Step 2: 旧版本忽略新字段，新版本读写新字段
处于灰度期，两版本共存

Step 3: 数据回填
UPDATE orders SET new_status = CASE status ...

Step 4: 灰度验证通过后
将新字段设为 NOT NULL，移除兼容代码

Step 5: 清理
ALTER TABLE orders DROP COLUMN old_status;
```

## 六、总结

| 发布策略 | 复杂度 | 成本 | 风险 | 适用团队 |
|----------|--------|------|------|----------|
| 全量发布 | 低 | 低 | 高 | 小团队，原型验证 |
| 蓝绿部署 | 中 | 高 | 中 | 中大规模，2套环境可接受 |
| 灰度发布 | 高 | 中 | 低 | **推荐的通用方案** |
| 金丝雀发布 | 高-极高 | 中-高 | 极低 | 大厂核心系统 |

**推荐实践：**
- **初期团队**：蓝绿部署（实现简单，效果明显）
- **中型团队**：网关灰度（Nginx/APISIX） + K8s 部署
- **大型团队**：Istio 服务网格 + 全链路灰度

灰度发布的核心不是技术，而是流程和监控。再好的灰度方案，如果没有完善的监控和回滚手段，反而会增加系统复杂度。灰度发布的关键在于：小步快跑、持续验证、随时回滚。
