---
title: 【Nginx 实战】OpenResty 与 Lua 请求生命周期深度实战：阶段时序、cosocket 与共享字典
date: 2026-11-24 08:10:00
tags:
  - Java
  - Nginx
  - OpenResty
  - Lua
  - 网关
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】OpenResty 与 Lua 请求生命周期深度实战

## 前言：为什么 Java 团队最后都会碰 OpenResty

一个典型的演进路径是这样的：

1. 一开始所有逻辑都在 Java：鉴权、限流、灰度、日志，全在 Spring 拦截器里。
2. 流量上来后，发现每个请求都要过一次 JVM：TLS 终止、鉴权、限流这些「和业务无关但要全量执行」的动作，占掉了大量线程和连接。
3. 于是把入口层前移：Nginx 做静态与转发，OpenResty 用 Lua 做鉴权/限流/灰度/日志，Java 只处理业务。

代价是**你必须在 Nginx 的 11 个执行阶段里思考问题**。写惯了 Spring 的人最容易犯的错，就是在 `header_filter_by_lua` 里发一个 HTTP 请求去查用户信息——然后得到一个 `API disabled in the context of header_filter_by_lua`，或者更糟：在 `body_filter` 里拼接整个响应体，把内存打爆。

这篇按「阶段 → 能力 → 陷阱」的顺序，把 OpenResty 的请求生命周期讲成一张可查的表。

---

## 一、11 个阶段：什么时候能做什么

请求从进来到出去，Lua 代码可以挂在下面这些点上（按执行顺序）：

| 阶段 | 指令 | 执行次数 | 典型用途 | 能否 cosocket |
|---|---|---|---|---|
| 配置加载 | `init_by_lua*` | 1 次（master） | 预加载模块、编译正则、读配置 | ❌（不能 yield） |
| worker 启动 | `init_worker_by_lua*` | 每 worker 1 次 | 起定时器、预热连接池 | ✅（在 timer 里） |
| TLS 握手 | `ssl_certificate_by_lua*` | 每握手 | 动态证书（SNI）、mTLS 校验 | ✅ |
| 会话复用 | `ssl_session_fetch/store_by_lua*` | 每握手 | 分布式 TLS session 共享 | ✅ |
| 改写 | `set_by_lua*` | 每请求 | 计算变量 | ❌ |
| 改写 | `rewrite_by_lua*` | 每请求 | URI 重写、灰度分流、跳转 | ✅ |
| 访问 | `access_by_lua*` | 每请求 | 鉴权、限流、IP 黑白名单 | ✅ |
| 内容 | `content_by_lua*` | 每请求 | 直接产出响应、聚合后端 | ✅ |
| 上游选择 | `balancer_by_lua*` | 每次选后端 | 自定义负载均衡 | ❌ |
| 响应头 | `header_filter_by_lua*` | 每请求 | 加/删响应头、CORS | ❌ |
| 响应体 | `body_filter_by_lua*` | 每 chunk | 流式改写、脱敏、注入 | ❌ |
| 日志 | `log_by_lua*` | 每请求 | 异步打点、指标上报 | ❌（用 timer） |

三条铁律，记住能省掉 80% 的调试时间：

1. **`set_by_lua` / `header_filter` / `body_filter` / `log_by_lua` / `balancer_by_lua` 里没有 cosocket**。要发网络请求，只能在 `rewrite` / `access` / `content` 阶段，或者丢到 `ngx.timer.at(0, fn)` 里异步做。
2. **`rewrite_by_lua` 在标准 `rewrite` 指令之后执行，`access_by_lua` 在 `allow/deny/auth_basic` 之后执行**。所以「先 allow 再鉴权」这种顺序是天然成立的，反过来不行。
3. **阶段是按 Nginx 状态机走的，`ngx.exit()` 会终止后续阶段**。在 access 阶段 `ngx.exit(403)` 后不会进 content；但 `ngx.exit(ngx.OK)` 只是结束当前阶段。

---

## 二、access 阶段做鉴权：把 JVM 从全量请求里摘出去

最典型的场景：JWT 校验。如果在 Java 里做，每个请求都要过一次 Spring Security 过滤器链；放到 OpenResty，公钥可以缓存在共享字典里，验签在 LuaJIT 里完成，Java 只收到合法请求。

```nginx
lua_shared_dict jwks_cache 10m;
lua_shared_dict jwt_blacklist 10m;

server {
    listen 443 ssl;
    server_name api.example.com;

    location /api/ {
        access_by_lua_file /etc/openresty/lua/auth.lua;
        proxy_pass http://java_backend;
        proxy_set_header X-User-Id $jwt_sub;
    }
}
```

```lua
-- /etc/openresty/lua/auth.lua
local cjson   = require "cjson.safe"
local jwt     = require "resty.jwt"
local http    = require "resty.http"
local lock    = require "resty.lock"

local cache   = ngx.shared.jwks_cache
local CACHE_KEY = "jwks"

local function fetch_jwks()
    -- 单飞：只让一个 worker 去拉，其他等锁后读缓存
    local l = lock:new("jwks_lock", cache)
    local elapsed, err = l:lock(3)
    if not elapsed then
        ngx.log(ngx.ERR, "lock failed: ", err)
        return nil
    end
    local ok, err2 = pcall(function()
        local httpc = http.new()
        httpc:set_timeouts(500, 1000, 1000)
        local res = httpc:request_uri("http://auth-service/.well-known/jwks.json", {
            ssl_verify = false,
        })
        if res and res.status == 200 then
            cache:set(CACHE_KEY, res.body, 300)  -- 5 分钟 TTL
            return res.body
        end
        error("jwks status " .. (res and res.status or "nil"))
    end)
    l:unlock()
    if not ok then
        ngx.log(ngx.ERR, "fetch jwks failed: ", err2)
        return nil
    end
    return cache:get(CACHE_KEY)
end

local token = ngx.req.get_headers()["Authorization"]
if not token then
    return ngx.exit(401)
end
token = token:match("^Bearer%s+(.+)$")
if not token then return ngx.exit(401) end

local jwks = cache:get(CACHE_KEY) or fetch_jwks()
if not jwks then
    -- 降级策略：鉴权服务不可用时拒绝，而不是放行
    return ngx.exit(503)
end

local verified = jwt:verify_jwk(jwks, token)
if not verified.verified then
    return ngx.exit(401)
end

if verified.payload.exp and verified.payload.exp < ngx.time() then
    return ngx.exit(401)
end

-- 黑名单：登出/封禁的 token
if cache:get("bl:" .. verified.payload.jti) then
    return ngx.exit(401)
end

ngx.var.jwt_sub = verified.payload.sub
```

几个值得单独讲的点：

- **`resty.lock` 防缓存击穿**。JWKS 过期瞬间，几百个并发请求同时发现缓存没了，如果每个都去拉一次，鉴权服务会被自己人打挂。加锁之后只有一个去拉，其余等锁后直接读缓存。
- **失败必须 fail-closed**。鉴权服务挂了就返回 503，不能 `ngx.exit(ngx.OK)` 放行。这是安全边界问题，不是可用性问题。
- **`ngx.var` 可以写入并传给上游**，但只在同一请求内有效；不要指望它跨阶段保存复杂结构，用 `ngx.ctx`。
- **正则要预编译缓存**。`ngx.re.match(str, pat, "jo")` 里的 `o` 表示只编译一次，对于固定正则必加，否则每请求都重新编译，CPU 直接翻倍。

---

## 三、body_filter：流式响应的「只能往前看」约束

`body_filter_by_lua` 是 OpenResty 里最容易写错的地方，因为它看起来像「拿到完整响应再处理」，实际上**每次只给你一个 chunk**：

```lua
body_filter_by_lua_block {
    local chunk, eof = ngx.arg[1], ngx.arg[2]
    local ctx = ngx.ctx
    ctx.acc = (ctx.acc or "") .. (chunk or "")

    if eof then
        -- 只有最后一次才能看到「全部」数据
        local total = #ctx.acc
        ngx.log(ngx.INFO, "response bytes: ", total)
        -- 注意：这时 Content-Length 已经发出，不能改长度
    end
}
```

由此推出四个硬约束：

1. **不能依赖「一次拿到完整 body」**。要统计总量、做跨 chunk 的脱敏，必须把状态存在 `ngx.ctx` 里，并在 `eof` 时收口。
2. **不能改 `Content-Length`**。响应头在 `header_filter` 阶段就已经发出去了。要动态改长度只能让上游用 `Transfer-Encoding: chunked`，并且你不要手动设置 Content-Length。
3. **不能在这个阶段用 cosocket**。想做「流式内容审核」，只能在 access/content 阶段先建好连接，或者把 chunk 丢给后台 timer/消息队列异步审。
4. **chunk 边界不等于语义边界**。一个 JSON 字段、一个中文字符、一个 SSE 事件都可能被切开。跨 chunk 匹配字符串几乎一定会漏。

如果确实要在流式响应里做处理（比如给 SSE 的每个 `data:` 加字段），正确做法是**按行缓冲**：维护一个 buffer，只在遇到 `\n\n` 时处理完整事件，剩余部分留到下一个 chunk。这和 Java 侧增量 JSON 解析是同一类问题。

---

## 四、共享字典：跨 worker 的唯一内存通信方式

OpenResty 是多 worker 的，每个 worker 有独立的 Lua VM。**`ngx.shared.DICT` 是唯一高效的多 worker 共享内存**，Nginx 内部用红黑树 + LRU 管理，适合放：限流计数器、配置快照、公钥/证书、小型会话状态。

```nginx
lua_shared_dict rate_limit 20m;
```

```lua
-- 固定窗口计数（简单，但有边界突刺）
local dict = ngx.shared.rate_limit
local key  = "rl:" .. ngx.var.binary_remote_addr .. ":" .. ngx.var.uri
local count, err = dict:incr(key, 1, 0, 60)   -- 初始 0，60s 过期
if not count then
    ngx.log(ngx.ERR, "incr failed: ", err)
    return ngx.exit(500)
end
if count > 100 then
    return ngx.exit(429)
end
```

必知细节：

- **`incr` 是原子的，`get` + `set` 不是**。所有计数器都必须用 `incr`，否则并发下会丢计数——这是限流精度问题的头号来源。
- **`incr` 的第四个参数 `init_ttl` 只有「键不存在时」才生效**。每次调用都传不会重置 TTL，这是它比「incr 后手动 expire」更精确的原因。
- **字典容量是硬上限**。满了之后 `set` 会失败（返回 `no memory`），`incr` 也会失败。必须监控 `dict:capacity()` 与 `dict:free_space()`，并在代码里对失败做降级（比如失败即放行 + 告警，而不是 500）。
- **不要存大对象**。共享字典有锁竞争，存 1MB 的 JSON 会让所有 worker 排队。大配置放 `lua-resty-lrucache`（worker 内）+ 共享字典存版本号。
- **`get_keys(0)` 会遍历整个字典并阻塞**，生产禁用；需要枚举就用额外的索引结构。

### 限流为什么建议用令牌桶而不是固定窗口

固定窗口在窗口切换的瞬间允许 2 倍流量（前一秒末尾 + 后一秒开头）。对 LLM 网关这种按 token 计费的场景，突刺会直接变成账单。令牌桶用「上次时间 + 速率 + 容量」三个字段就能实现，且只需要一次 `get` + 一次 `set`——但这就不是原子的了。

工程折中：**用共享字典存桶状态 + `resty.lock` 保护读改写**，锁的粒度按 key 分片（`lock_key = "lock:" .. key`），避免全局锁。高并发下限流精度和吞吐要做取舍，这也是为什么大流量场景最终会把限流下沉到专门的网关或 Redis Lua。

---

## 五、日志阶段：不能发网络请求，但可以「扔出去」

`log_by_lua` 里没有 cosocket，但请求已经结束，最合适的做法是**把日志丢进共享字典的队列或 timer**，由后台批量发送：

```lua
log_by_lua_block {
    local dict = ngx.shared.access_log_buf
    local line = string.format("%s %s %s %s %.3f\n",
        ngx.var.time_iso8601, ngx.var.request_id,
        ngx.var.status, ngx.var.request_uri, ngx.var.request_time)
    -- 非阻塞入队，满了就丢（日志不能拖垮主流程）
    local ok = dict:rpush("logs", line)
    if not ok then
        ngx.log(ngx.WARN, "access log buffer full, dropped")
    end
}
```

`init_worker_by_lua` 里起一个 `ngx.timer.every(1, flush)`，批量 POST 到日志服务。**注意 `ngx.timer` 的回调里可以 cosocket**，这才是正确的异步出口。

如果不想自己写，`lua-resty-logger-socket` 或直接上 OpenTelemetry Collector 的 Nginx 模块更省事。自研的价值主要在于字段可控和成本。

---

## 六、性能与踩坑清单

| 坑 | 现象 | 解法 |
|---|---|---|
| `lua_code_cache off` 上生产 | CPU 高、内存涨 | 只在开发开，生产必须 on |
| 正则没加 `o` 标志 | 每请求编译，CPU 翻倍 | `ngx.re.match(s, p, "jo")` |
| `string` 大量拼接 | GC 压力、延迟抖动 | `table.concat` + `table.new` |
| 共享字典存大对象 | 所有 worker 锁竞争 | 小状态进字典，大对象进 lrucache |
| `body_filter` 里 `ngx.var` 反复读 | 变量已缓存，读到旧值 | 需要动态值用 `ngx.ctx` |
| timer 里访问 `ngx.var` | 请求已结束，变量失效 | timer 回调只用手动传入的副本 |
| 子请求 `ngx.location.capture` 拉大响应 | 内存暴涨 | 限制 `max_response_body_size` 或用 cosocket 流式读 |
| 上游超时与 Lua 超时不一致 | 504 与 Lua error 混杂 | `proxy_read_timeout` ≥ cosocket timeout |

### `ngx.location.capture` 与 `ngx.exec` 的区别

| | `ngx.location.capture` | `ngx.exec` |
|---|---|---|
| 本质 | 子请求，走完整 Nginx 阶段 | 内部重定向，替换当前请求 |
| 响应 | 全量缓冲在内存 | 不返回，直接由新 location 处理 |
| 用途 | 聚合多个内部接口 | URI 重写、灰度到另一个 location |
| 风险 | 大响应 OOM | 循环重定向（10 次上限后 500） |

聚合场景要特别小心：`capture` 会把上游响应**完整读进内存**。如果被聚合的接口返回几 MB，几十个并发就能把 worker 打爆。这种情况应该用 `ngx.thread.spawn` + cosocket 流式转发，而不是 capture。

---

## 七、面试追问

**Q1：为什么 `set_by_lua` 不能做网络请求？**
它在 Nginx 的 rewrite 阶段早期执行，用于同步计算变量，此时请求状态机不允许 yield；cosocket 需要挂起当前请求等待 IO，因此被禁用。需要 IO 就放到 `rewrite_by_lua` / `access_by_lua`。

**Q2：`access_by_lua` 和 `rewrite_by_lua` 都能做鉴权，选哪个？**
语义上鉴权属于 access 阶段，且 access 在 `allow/deny` 之后执行，顺序更符合直觉。rewrite 阶段更适合改 URI、选上游。功能上两者都能 cosocket，但把鉴权放 access 更利于维护。

**Q3：共享字典的 `incr` 为什么比 Redis 的 `INCR` 快？**
它是进程内共享内存，无网络往返、无序列化，纳秒级；Redis 是跨机 RPC，毫秒级。代价是**只在单机内共享**，多机限流仍需 Redis 或网关集群方案。

**Q4：body_filter 能不能做 gzip 解压后再处理？**
不能可靠做到。`body_filter` 看到的是 Nginx 输出链上的数据，压缩顺序与模块配置有关，可能拿到的是已压缩字节。要在压缩前处理，用 `ngx_http_lua` 的 content 阶段自行控制输出。

**Q5：OpenResty 挂了，Java 服务还在，怎么降级？**
两层：一是 OpenResty 多实例 + VIP/SLB；二是 Java 侧保留最小鉴权能力（比如只校验签名不做远程查权限），在网关不可用时由 Java 兜底，宁可性能差也不能全站 502。

### 落地检查清单

- [ ] 所有 cosocket 调用都在允许的阶段，或包在 `ngx.timer` 里
- [ ] 共享字典有容量监控与写失败降级
- [ ] 计数器一律 `incr`，读改写有锁或接受误差
- [ ] `lua_code_cache on`、正则带 `o`、无大字符串拼接
- [ ] `body_filter` 不假设完整 body、不改 Content-Length
- [ ] 鉴权失败 fail-closed，且有 JWKS 缓存与单飞
- [ ] 日志异步化，缓冲区满时丢弃而不是阻塞请求

OpenResty 的威力不在于「能在 Nginx 里写代码」，而在于**用正确的阶段做正确的事**。把 IO 放在能 yield 的阶段、把状态放在正确的存储里、把失败路径想清楚，这套东西比多写一百行 Lua 重要得多。
