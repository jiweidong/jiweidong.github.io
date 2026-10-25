---
title: 【Nginx 实战】限流与连接治理深度实战：limit_req、limit_conn 与集群限流的精度陷阱
date: 2026-10-25 08:05:00
tags:
  - Nginx
  - 限流
  - 漏桶算法
  - 高并发
  - 中间件
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】限流与连接治理深度实战：limit_req、limit_conn 与集群限流的精度陷阱

## 前言

一个让人印象深刻的故障：有人为了「保护后端」，在大促前给 Nginx 加了：

```nginx
limit_req zone=api burst=5 nodelay;
limit_conn addr 2;
```

结果大促一开始，首页的雪碧图（当时还有 sprite）+ 十几个静态资源请求并发打到同一个 `location`，`limit_conn addr 2` 直接把正常用户的图片请求全拒了。监控上是「429 激增」，用户看到的是「页面空白」。

限流参数从来不是「加上就安全」，而是**必须回答三个问题**：限谁（key 是什么）、限多严（rate + burst）、超了怎么办（拒绝 / 排队 / 降级）。

这篇文章讲 Nginx 两把限流武器（`limit_req` 漏桶、`limit_conn` 并发连接数）的真实语义、参数之间的数学关系、集群限流的精度陷阱，以及它和 Java 侧（Sentinel）的分工。

---

## 一、`limit_req`：不是令牌桶，是漏桶

```nginx
http {
    # 定义限流维度：按 IP，10MB 共享内存，每秒 20 个请求
    limit_req_zone $binary_remote_addr zone=perip:10m rate=20r/s;
    # 按域名 + URI（对接口做细粒度限流）
    limit_req_zone $server_name$uri zone=perapi:20m rate=100r/s;

    server {
        location /api/order/ {
            limit_req zone=perapi burst=20 nodelay;
            limit_req_status 429;
            proxy_pass http://order_service;
        }
    }
}
```

### 1.1 语义：漏桶（leaky bucket）

- `rate=20r/s`：**平均速率**，即每 50ms 放行一个请求。
- `burst=20`：桶的容量（允许的突发量）。
- `nodelay`：突发部分**立即放行**而不是排队等待。

不加 `nodelay` 时，超出的请求会**在桶里排队**（每个请求等 `1/rate` 的倍数），客户端体感是延迟变高而不是被拒绝。加了 `nodelay`，突发请求一次性放行，之后的请求按 `rate` 补充。两种模式的区别：

| 配置 | 行为 | 客户端体感 | 适用 |
|---|---|---|---|
| `burst=20`（无 nodelay） | 峰值为 20 的排队，队列满则 503/429 | 延迟变高，有抖动 | 不宜拒绝的场景（内部 API） |
| `burst=20 nodelay` | 20 个突发立即放行，之后严格按 rate | 突发不受影响，持续高频被拒 | 对外 API（推荐） |
| `burst=0` | 完全不允许突发，严格间隔 | 正常用户也会偶发被拒 | ❌ 基本不要用 |

**关键结论：`burst=0` 是个陷阱。** 因为浏览器的并发请求、TCP 重传、客户端重试都会产生不可预测的微突发，`burst=0` 会把「正常但稍快」的用户打成 429。经验值：`burst ≈ rate × 0.5~2`。

### 1.2 内存怎么算

`limit_req_zone` 的共享内存按 **key 的数量** 估算，每个 key 约占 128 字节（64 位系统）：

```
10MB / 128B ≈ 81,920 个 key
```

如果用 `$binary_remote_addr`（IPv4 4 字节），一个 10MB 的 zone 大约能记 8 万个 IP 的限流状态。**超出后 Nginx 会淘汰最久未使用的 key（LRU），限流状态被重置**——这也是「为什么攻击者能绕过限流」的一个原因（IP 池足够大时，把老 IP 的状态挤掉）。

### 1.3 一个必须知道的精度问题

`limit_req` 的桶是**按毫秒级补充**的（内部是 `excess` 计数 + 时间差衰减），不是「每秒清零计数器」。所以：

- 它**不是固定窗口**，不会有「59.999s 打满 + 60.001s 再打满」的双倍突发问题；
- 但它也**不是严格的令牌桶**，`nodelay` 下允许「瞬间 burst + 持续 rate」的组合突刺。

如果你的业务要求「每秒绝对不超过 100 次」，`limit_req` 做不到严格保证（它允许 100 + burst 的瞬时峰值）。严格硬限流要靠 Java 侧的滑动窗口（Sentinel）或 Redis 计数器。

### 1.4 返回值：429 还是 503

```nginx
limit_req_status 429;   # 默认是 503
limit_conn_status 429;
```

**一定要改成 429。** 503 会被客户端和监控理解成「服务不可用」，触发熔断/告警风暴；429（Too Many Requests）语义正确，且 `Retry-After` 头可以告诉客户端什么时候重试。

```nginx
limit_req_status 429;
add_header Retry-After 1 always;
```

---

## 二、`limit_conn`：限的是「并发连接数」

```nginx
limit_conn_zone $binary_remote_addr zone=conn_perip:10m;
limit_conn_zone $server_name zone=conn_perserver:10m;

server {
    limit_conn conn_perip 20;      # 单 IP 最多 20 个并发连接
    limit_conn conn_perserver 2000; # 单 server 最多 2000 个并发连接
}
```

两者语义完全不同：

| | `limit_req` | `limit_conn` |
|---|---|---|
| 限制对象 | 请求速率（req/s） | 并发连接数（个） |
| 算法 | 漏桶 | 计数器（连接建立 +1，关闭 -1） |
| 适合 | 防刷接口、防爬虫 | 防慢速攻击、防长连接占满、保护后端连接池 |
| 副作用 | 无（不占连接） | 阻塞在 Nginx 侧，占内存 |

**`limit_conn` 的真正价值是防「慢速连接攻击」（Slowloris）**：攻击者只发一半的 HTTP 请求头，保持连接不关，就能用几百个连接占满 Nginx 的 `worker_connections`。`limit_req` 对这种攻击完全无效（因为它压根没发完整请求）。

配套的防御：

```nginx
client_header_timeout 10s;    # 请求头必须在 10s 内发完
client_body_timeout 10s;      # 请求体同理
send_timeout 10s;             # 响应发送超时
client_max_body_size 10m;     # 防大文件上传打满磁盘
```

**但 `limit_conn` 按 IP 限并发是有代价的**：企业内网、运营商 NAT、公司出口 IP 后面可能有几千人。给 `limit_conn` 设一个很小的值（比如 2），就是把整个公司墙在外面。这就是前言里那个故障的成因。

安全取值：`limit_conn per IP ≥ 20`，并且在 `location ~* \.(js|css|png|jpg|woff2)$` 这类静态资源上**不要**开（浏览器有 6 个并发连接是标配）。

---

## 三、限流维度怎么选（key 的设计）

| key | 表达 | 优点 | 缺点 |
|---|---|---|---|
| `$binary_remote_addr` | 客户端 IP | 简单、能挡单机刷 | NAT 误伤；IPv6 需单独考虑 |
| `$http_x_forwarded_for` | 真实客户端 IP（过 CDN 后） | 准确 | **可伪造**（除非只信任自家 CDN 的段） |
| `$server_name` | 域名 | 保护后端整体 | 粒度太粗 |
| `$server_name$uri` | 域名 + 路径 | 可按接口限流 | 路径多会导致 zone 内存涨 |
| `$http_authorization` / `$cookie_uid` | 用户维度 | 最贴近业务 | 需哈希，且未登录用户无法限制 |
| `$geoip_country_code`（需模块） | 地域 | 可做海外/国内分离 | 需 GeoIP 库 |

**生产推荐组合（三段式）**：

```nginx
# 第一段：按 IP 粗限，挡脚本刷（宽）
limit_req_zone $binary_remote_addr zone=ip:20m rate=50r/s;
# 第二段：按接口细限，保护热点接口（严）
limit_req_zone $server_name$uri zone=api:20m rate=100r/s;
# 第三段：按用户（已登录）限，做业务级配额（最严）
map $http_authorization $limit_key {
    ""      $binary_remote_addr;      # 未登录回退到 IP
    default $http_authorization;
}
limit_req_zone $limit_key zone=user:20m rate=10r/s;

server {
    location /api/seckill/ {
        limit_req zone=ip burst=20 nodelay;
        limit_req zone=api burst=10 nodelay;
        limit_req zone=user burst=5 nodelay;
        limit_req_status 429;
    }
}
```

**多个 `limit_req` 会依次评估，任意一个超限即拒绝**。这形成了「漏斗」：IP 50/s → 接口 100/s（全站）→ 用户 10/s。注意顺序不影响结果，但 Nginx 会为每个 zone 维护独立状态。

**`$http_x_forwarded_for` 的安全用法**：只信任自家 CDN 的 IP 段，用 `real_ip` 模块还原：

```nginx
set_real_ip_from 10.0.0.0/8;          # CDN 回源段
set_real_ip_from 172.16.0.0/12;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

否则攻击者直接发一个 `X-Forwarded-For: 1.2.3.4`，就能无限换 IP 绕过 IP 限流。

---

## 四、集群限流：Nginx 最大的精度陷阱

`limit_req_zone` 的状态在**每个 Nginx 实例的共享内存里**。有 4 台 Nginx 时：

```
rate=100r/s × 4 台 = 实际放行 400r/s
```

这不是 BUG，是设计。但很多人在做容量规划时按 100r/s 算后端能力，结果后端被打 4 倍。

### 4.1 三种解法

| 方案 | 精度 | 复杂度 | 说明 |
|---|---|---|---|
| 单点总和分摊 | 中 | 低 | 每台配 `rate/节点数`，误差随节点数增大 |
| OpenResty + Redis | 高 | 中 | Lua 脚本里做分布式计数，多一次 Redis RTT |
| 只做粗限流，精限流交给 Java | 高 | 低 | **推荐**：Nginx 挡洪水，Sentinel 管配额 |

**推荐的分层架构**：

```
L1  CDN / WAF         → 挡 DDoS、地域封禁（百万级 QPS）
L2  Nginx limit_req   → 挡单 IP 刷、慢速攻击（万级 QPS，宽限）
L3  网关 / Sentinel   → 按用户/租户/接口的精确配额（千级 QPS，严限）
L4  业务侧限流         → 数据库连接池、线程池、信号量（最终防线）
```

**L2 的目标不是「精确」，是「把明显异常的流量挡在门外」**，所以给足 burst，宁可漏放不可误杀。**L3 才是真正的配额**，因为它能拿到用户身份、能读实时指标、能做动态调整。

### 4.2 如果非要用 Redis 做集群限流

```lua
-- OpenResty 侧：滑动窗口计数
local key = "rl:" .. ngx.var.binary_remote_addr .. ":" .. ngx.var.uri
local now = ngx.now()
local window = 1.0     -- 1 秒
local limit = 100

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)
if count >= limit then
    return 0
end
redis.call('ZADD', key, now, now .. math.random())
redis.call('PEXPIRE', key, 2000)
return 1
```

代价：每个请求多一次 Redis 往返（+0.3~1ms），且 Redis 成单点。**只有在「限流必须全局精确」的场景（如按 API Key 计费的开放平台）才值得**。

---

## 五、压测验证：怎么确认限流真的生效

限流配置最怕「看起来配了，其实没生效」。三个验证步骤：

### 5.1 单机压测

```bash
# 用 ab 打 100 并发、1000 个请求，看 429 比例
ab -n 1000 -c 100 http://127.0.0.1/api/order/list

# 关注这两行
# Non-2xx responses:     823
# Requests per second:   20.15   ← 应该接近 rate 值
```

如果 `Requests per second` 远大于 `rate`，说明 zone 没生效（常见原因：`limit_req_zone` 写在 `server` 块里——它**只能在 `http` 块**）。

### 5.2 验证 burst 行为

```bash
# 10 个并发打一次（burst 内，应该全部 200）
seq 10 | xargs -P10 -I{} curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/api/order/list

# 紧接着 30 个并发（超出 burst，应该有 429）
seq 30 | xargs -P30 -I{} curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/api/order/list
```

### 5.3 看指标

```nginx
# 日志里带上限流状态
log_format rl '$remote_addr "$request" $status '
              'req_limit=$limit_req_status conn_limit=$limit_conn_status';
access_log /var/log/nginx/access.log rl;
```

`$limit_req_status` 取值：`PASSED` / `DELAYED` / `REJECTED` / `BURST`。**统计 `REJECTED` 的占比**是判断「限流是否误伤」的核心指标：

- `REJECTED > 5%`：参数太严，正常用户在被拒；
- `REJECTED = 0` 且 QPS 很高：限流没生效或太松。

---

## 六、Nginx 限流 vs Java 限流：职责边界

| 维度 | Nginx `limit_req` | Sentinel / Resilience4j |
|---|---|---|
| 位置 | 请求入口，最早 | 业务方法/接口内 |
| 状态 | 单机内存（不共享） | 单机（集群流控需额外组件） |
| 维度 | IP / URI / Header | 任意（用户、租户、参数、方法） |
| 动态调整 | 需 reload | 实时（配置中心推送） |
| 熔断降级 | ❌ | ✅ |
| 资源消耗 | 极低（C 实现） | 有（拦截器 + 指标统计） |
| 误伤成本 | 高（拦在业务之前，无法区分用户） | 低（能看到业务上下文） |

**分工原则**：

1. **Nginx 负责「与身份无关」的粗粒度防护**：单 IP 速率、单 IP 并发、URI 级总量、慢速攻击。这些在 Java 侧做，成本高且为时已晚（请求已经占用了 Tomcat 线程）。
2. **Java 侧负责「与身份/业务有关」的精细配额**：用户级、租户级、VIP 豁免、按接口成本的差异化（查询 1 次 = 1 单位，导出 1 次 = 100 单位）。
3. **两者都要有**，但不要在两边配同一个阈值——否则调参时会互相干扰，出问题无法定位是哪一层拦的。

Sentinel 侧的对应实现（按调用方做热点参数限流）：

```java
@PostMapping("/api/order/list")
@SentinelResource(value = "orderList", blockHandler = "onBlocked")
public Result<List<OrderVO>> list(@RequestParam(defaultValue = "1") int page) {
    return Result.ok(orderService.list(page));
}

public Result<List<OrderVO>> onBlocked(int page, BlockException ex) {
    // 返回 429 + Retry-After 语义，而不是笼统的 500
    return Result.fail(429, "请求过于频繁，请稍后重试");
}
```

```java
// 参数级限流：同一个 userId 每秒最多 5 次
ParamFlowRule rule = new ParamFlowRule("orderList")
        .setParamIdx(0)
        .setCount(5);
```

---

## 七、四个真实踩坑

### 坑 1：`limit_req_zone` 写错位置

```nginx
server {
    limit_req_zone $binary_remote_addr zone=ip:10m rate=20r/s;   # ❌ 无效！
}
```

`limit_req_zone` / `limit_conn_zone` 只能在 `http` 块。写在 `server` 里 Nginx **不会报错**（某些版本会忽略），但 zone 不会被创建，`limit_req zone=ip` 会报 `unknown limit_req_zone "ip"`——至少这个会启动失败。更隐蔽的是 `limit_conn_zone` 写了两份，后一份覆盖前一份的共享内存名。

### 坑 2：`burst` 太大等于没限流

`rate=20r/s, burst=1000 nodelay` 意味着：**瞬间可以放 1000 个请求**。攻击者只要每 50 秒发一波 1000 个请求，就能持续打满后端——平均速率只有 20/s，但瞬时是 1000。而 Nginx 的 `limit_req` 恰恰擅长的是「平均速率」，所以这种配置把它的能力废掉了。

**`burst` 的正确取值：`rate × 允许的突刺秒数`。** 允许 1 秒突刺就 `burst = rate × 1`。

### 坑 3：限流和重试的叠加放大

Nginx 返回 429 后，客户端的重试（尤其是移动端的「网络异常自动重试」）会立刻再打一次。如果 429 没有携带 `Retry-After`，客户端可能立即重试 3 次 → **限流不但没减轻压力，反而放大了 3 倍**。

```nginx
limit_req_status 429;
add_header Retry-After 1 always;
# 并且要求在 Java SDK 侧做「指数退避 + 尊重 Retry-After」
```

### 坑 4：限流把健康检查也挡住了

K8s 的 `readinessProbe` 每 10 秒打一次 `/actuator/health`，多个副本 + 多次重试后，如果探测路径和业务路径共用一个 `location`，健康检查会被 429 → **Pod 被判定不健康 → 滚动重启 → 雪崩**。

```nginx
location = /actuator/health {
    allow 10.0.0.0/8;      # 只允许内网探活
    deny all;
    proxy_pass http://app;
    # 不配 limit_req
}
```

**所有探活/内部调用路径必须显式排除在限流之外。**

---

## 八、面试追问

**Q1：`limit_req` 是令牌桶还是漏桶？**
对外表现为漏桶：请求以固定速率流出，`burst` 是桶容量。实现上用的是「`excess` 计数 + 按时间差衰减」，可以理解为「速率限制的漏桶」。它**不是令牌桶**——令牌桶允许「积累令牌后一次性爆发」，Nginx 的 `burst + nodelay` 效果类似，但实现机制不同。

**Q2：`nodelay` 到底改变了什么？**
不加 `nodelay` 时，超速请求会被**延迟处理**（排队，每个请求等到下一个时间片）；加了之后，`burst` 范围内的请求**立即放行**，只有超过 `burst` 的才拒绝。所以 `nodelay` 是把「延迟」换成了「允许突刺」，不是「取消限流」。

**Q3：4 台 Nginx 想实现全局 100r/s 怎么做？**
`limit_req_zone` 是进程内共享内存，跨机器不共享。三个方案：① 每台配 25r/s（简单，但误差大）；② OpenResty + Redis 做分布式计数（精确，但多一次 RTT 且 Redis 成为依赖）；③ Nginx 粗限流 + 网关/Java 侧精确限流（推荐）。

**Q4：限流和熔断的区别？**
限流是**主动的、预防性的**（按预设速率丢请求），目的是「不让系统过载」；熔断是**被动的、反应性的**（观察下游错误率，超过阈值后直接快速失败），目的是「不让故障扩散」。限流看「入口速率」，熔断看「下游健康度」。生产上两者都要，且通常在不同层。

**Q5：为什么 `limit_conn` 可能比 `limit_req` 更危险？**
因为它限制的是**连接**，而连接的分配与「用户身份」无关。NAT 后的大量用户共享 IP、浏览器并发 6 连接、HTTP/2 单连接多路复用（此时 `limit_conn` 反而几乎不生效）——都会导致误伤或失效。`limit_req` 至少是按请求计数，粒度更细。

**Q6：HTTP/2 下 `limit_conn` 还有意义吗？**
意义大幅下降。HTTP/2 一个 TCP 连接承载所有并发流，`limit_conn` 按连接数限流基本失效。此时应该用 `limit_req`（按请求）或者 `limit_conn` 改按 `$server_name` 做总量保护。这也是 HTTP/2 环境下限流策略必须重新设计的原因。

---

## 九、上线检查清单

- [ ] `limit_req_zone` / `limit_conn_zone` 在 `http` 块，共享内存 ≥ `key 数 × 128B`
- [ ] `burst` 与 `rate` 有明确的数学关系（`burst ≈ rate × 允许突刺秒数`），不是拍脑袋
- [ ] `limit_req_status` / `limit_conn_status` 改成 **429**，并带 `Retry-After`
- [ ] 静态资源 location **不**开 `limit_conn`（浏览器并发 6）
- [ ] 探活路径（`/actuator/health`）显式排除限流
- [ ] 三段式 key：IP 粗限 + URI 细限 + 用户精限
- [ ] `X-Forwarded-For` 只在信任的 CDN 段使用，配 `set_real_ip_from`
- [ ] 集群限流做了「总和分摊」或明确交给上层，容量按总放行量算
- [ ] 日志含 `$limit_req_status`，监控 `REJECTED` 占比（>5% 需调参）
- [ ] 客户端 SDK 尊重 `Retry-After` 并做指数退避
- [ ] 压测验证：QPS 收敛到 rate、burst 内全 200、burst 外 429

限流这件事，配对比配多重要。**限流的目的是「让系统在过载时优雅地降级」，不是「把用户挡在门外」**。当你发现限流误伤的投诉比过载还多时，说明参数该松了——而这个判断，只能靠 `REJECTED` 指标和业务数据，不能靠感觉。
