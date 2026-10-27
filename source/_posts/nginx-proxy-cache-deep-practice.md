---
title: 【Nginx 实战】proxy_cache 缓存深度实战：缓存键设计、缓存穿透与多级缓存治理
date: 2026-10-27 08:00:00
tags:
  - Nginx
  - 缓存
  - 性能优化
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】proxy_cache 缓存深度实战

## 前言

很多团队一提到缓存，第一反应就是 Redis。但在真实的高并发系统里，**最便宜、最近、最有效的一层缓存，往往是 Nginx 的 `proxy_cache`**。

它挡在 Tomcat 前面，命中时连 Java 进程都不用碰：一次请求在 Nginx 内部完成磁盘（或内存）读取并直接返回，省掉了内核态到用户态的多次拷贝、省掉了 Spring 的一整条 Filter/Interceptor/AOP 链路，也省掉了数据库连接。

但 `proxy_cache` 是典型的「配置五行能跑，生产半年出事故」的组件：缓存键设计不当导致串号、`Set-Cookie` 被缓存导致用户串登录、`proxy_cache_lock` 没开导致缓存击穿打爆回源、磁盘 IO 打满导致 Nginx 自己变成瓶颈。

这篇文章把 `proxy_cache` 从原理到生产配置讲透，最后给出一套可以直接抄的配置模板和排查手册。

---

## 一、proxy_cache 的工作模型

先建立一个正确的心理模型。Nginx 的缓存是**反向代理层的响应缓存**，它缓存的是「上游返回的 HTTP 响应」，不是一个 KV 存储。

一次请求进来，Nginx 的处理顺序是：

```
客户端 → Nginx
  ├─ 1. 用 proxy_cache_key 计算缓存键
  ├─ 2. 查 cache zone 的元数据（keys zone，内存）
  │     ├─ 命中且未过期 → 直接读缓存文件返回（$upstream_cache_status = HIT）
  │     └─ 未命中 → 进入下一步
  ├─ 3. 判断是否需要加锁（proxy_cache_lock）
  ├─ 4. 回源到 upstream，边接收边写临时文件
  ├─ 5. 响应完成后 rename 成正式缓存文件（原子替换）
  └─ 6. 返回给客户端
```

这里有两个关键设计必须记住：

1. **元数据在共享内存（`keys_zone`），响应体在磁盘。** `keys_zone=api_cache:20m` 里的 20MB 只存 key 和文件指针，大约能存 8 万个 key（1MB ≈ 8000 个 key，官方经验值），不是存响应体。
2. **写入是「临时文件 + rename」的原子操作。** 所以并发的读请求不会读到半截文件，这是它能安全用于生产的基础。

```nginx
proxy_cache_path /data/nginx/cache
                 levels=1:2
                 keys_zone=api_cache:50m
                 max_size=20g
                 inactive=60m
                 use_temp_path=off;
```

| 参数 | 含义 | 生产建议 |
|---|---|---|
| `levels=1:2` | 二级目录散列，避免单目录文件过多 | 保持 1:2，别用 1:1:1（目录太深 inode 浪费） |
| `keys_zone` | 元数据共享内存 | 每 8000 个 key 约 1MB，按峰值 key 数 × 1.5 预留 |
| `max_size` | 磁盘上限 | 独立挂盘，别和日志同盘 |
| `inactive` | 多久没被访问就淘汰 | 通常 ≥ 缓存有效期，否则会「刚缓存就被清」 |
| `use_temp_path=off` | 临时文件直接写在缓存目录 | **必开**，避免跨文件系统 rename 变成 copy |

`use_temp_path=off` 这一条特别容易漏。默认临时目录在 `/var/lib/nginx/tmp`，如果它和缓存目录不在同一个文件系统，`rename()` 会退化成「复制 + 删除」，一个 10MB 的响应就要多写一次磁盘，QPS 一高磁盘直接顶满。

---

## 二、缓存键：90% 的线上事故都出在这里

### 2.1 默认缓存键是危险的

Nginx 默认的 `proxy_cache_key` 是 `$scheme$proxy_host$request_uri`。注意它**不包含** `Host`、不包含 Cookie、不包含任何请求头。

这意味着下面两类事故几乎必然发生：

- 多域名共用一套 Nginx（`server_name a.com b.com`），`proxy_host` 相同 → **A 站内容被 B 站命中**。
- 接口按 `Authorization` 或租户 ID 返回不同数据 → **租户数据串号**，这是安全事故级别的问题。

### 2.2 正确的缓存键设计

```nginx
# 公共静态资源：按 host + 完整 URI
proxy_cache_key "$scheme$host$request_uri";

# 需要区分租户的接口：显式加入业务维度
proxy_cache_key "$scheme$host$request_uri|$http_x_tenant_id|$cookie_session_hash";

# 需要区分设备/语言
proxy_cache_key "$scheme$host$request_uri|$http_accept_language|$http_user_agent_type";
```

设计原则：

1. **默认全部带上 `$host`**，成本几乎为零。
2. **只加真正影响响应内容的维度。** 每加一个维度，键空间就乘一次，缓存命中率就掉一截。`User-Agent` 千万别整串塞进去，先做归一化（移动端/PC/爬虫）。
3. **绝对不要把原始 Cookie 整串放进缓存键**，一是键太长（Nginx 变量上限受 `large_client_header_buffers` 影响），二是会导致「每个用户一份缓存」，等于没缓存。
4. 敏感维度用哈希：`$cookie_session_hash` 可以用 `map` + `md5` 预先算好。

> 面试高频追问：**为什么不能把 `Authorization` 直接放缓存键？** 因为它包含 token 原文，会被写进磁盘文件名（虽然做了 md5，但 key 本身仍在共享内存），而且 token 轮换会导致缓存全量失效。正确做法是把「用户身份」映射成稳定的内部 ID，再作为维度。

---

## 三、缓存状态可观测：`$upstream_cache_status`

不做可观测的缓存等于没有缓存。必须先把状态打到日志里：

```nginx
log_format cache_log '$remote_addr - $host "$request" '
                     'status=$status cache=$upstream_cache_status '
                     'upstream=$upstream_addr time=$request_time '
                     'urt=$upstream_response_time bytes=$body_bytes_sent';

access_log /var/log/nginx/cache.log cache_log;
```

`$upstream_cache_status` 的取值及含义：

| 状态 | 含义 | 是否回源 | 需要关注 |
|---|---|---|---|
| `MISS` | 未命中，正常回源 | 是 | 命中率低时看这个 |
| `HIT` | 命中 | 否 | 目标：静态资源 > 95%，接口 60%~85% |
| `EXPIRED` | 有缓存但已过期，回源 | 是 | 正常现象，看 TTL 是否合理 |
| `STALE` | 返回了过期缓存（配合 `proxy_cache_use_stale`） | 否 | 说明上游异常，应告警 |
| `UPDATING` | 缓存正在后台更新，返回旧的 | 否 | 正常，说明 `background_update` 生效 |
| `REVALIDATED` | 304 协商缓存命中 | 是（304） | 正常 |
| `BYPASS` | 被 `proxy_cache_bypass` 跳过 | 是 | **异常信号，通常是误配** |

线上排查的第一步永远是：

```bash
# 命中率（按小时）
awk '{for(i=1;i<=NF;i++) if($i ~ /^cache=/) print $i}' /var/log/nginx/cache.log \
  | sort | uniq -c | sort -rn
```

如果 `BYPASS` 占比高，常见原因是 `proxy_cache_bypass $cookie_nocache $arg_nocache` 这类配置，而某些客户端恰好带了同名参数。

---

## 四、缓存击穿、穿透、雪崩的三道防线

### 4.1 击穿：热点 key 过期瞬间并发回源

这是 Nginx 缓存最经典的坑。一个 QPS 5000 的热点接口，缓存 TTL 60s，在第 60 秒的瞬间，可能有几百个并发请求同时发现缓存失效，同时回源，直接把后端打挂。

**防线一：`proxy_cache_lock`**

```nginx
proxy_cache_lock on;
proxy_cache_lock_timeout 5s;
proxy_cache_lock_age 5s;
```

开启后，同一个缓存键在同一时刻只允许**一个**请求回源，其他请求排队等待，等第一个请求写完后直接用缓存。这是最有效的一招，成本几乎为零。

注意 `proxy_cache_lock_timeout` 到期后，等待的请求会「放行」回源（但不会写缓存），所以这个值要略大于你后端 P99 响应时间。

**防线二：`proxy_cache_use_stale` + 后台更新**

```nginx
proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
proxy_cache_background_update on;
```

含义是：当上游报错、超时，或者缓存正在更新时，**返回旧的缓存内容**（`STALE`）。`background_update on` 则让「过期后第一个请求」立即返回旧内容，同时在后台异步回源更新。

这两个配合起来，用户侧几乎感知不到缓存过期，也不会出现「过期瞬间集体卡住」。

**防线三：TTL 打散**

```nginx
# 用请求参数的哈希做 ±10% 抖动
set $ttl_jitter 0;
proxy_cache_valid 200 302 10m;
```

严格来说 Nginx 原生不支持 TTL 抖动，工程上的做法是让后端在 `Cache-Control: max-age` 里返回带随机抖动的值，Nginx 用 `proxy_cache_valid` 不覆盖响应头时可以吃这个值（需要 `proxy_ignore_headers` 不屏蔽 `Cache-Control`）。这一点很多文章讲错，务必实测。

### 4.2 穿透：查询不存在的数据

如果接口对「不存在的 ID」也返回 200 + 空结果，且不缓存，那么恶意请求可以用随机 ID 无限打穿缓存。做法是**空结果也缓存，但 TTL 要短**：

```nginx
map $upstream_http_x_cacheable $cache_empty {
    default        0;
    "1"            1;
}
proxy_cache_valid 404 1m;   # 404 缓存 1 分钟，控制穿透
```

同时在后端做布隆过滤器/参数合法性校验，Nginx 这层只做兜底。

### 4.3 雪崩：大量 key 同时过期

除了 TTL 抖动，更根本的手段是**分层**：CDN → Nginx 缓存 → 应用本地缓存（Caffeine）→ Redis → DB。每一层的 TTL 依次递增，即使上层全挂，下层也能顶住。

| 层级 | 典型 TTL | 容量 | 命中耗时 |
|---|---|---|---|
| CDN | 1h~7d | 海量 | 10~40ms（边缘） |
| Nginx proxy_cache | 1~30min | 受磁盘限制 | 0.1~1ms（本地盘） |
| Caffeine（JVM 内） | 10s~5min | 受堆限制 | 100ns 级 |
| Redis | 5~60min | 受内存限制 | 0.5~2ms |

---

## 五、最容易踩的五个坑

### 坑 1：把带 `Set-Cookie` 的响应缓存了

Nginx 默认**不缓存**带 `Set-Cookie` 的响应（因为 `proxy_ignore_headers` 没开）。但很多人为了「提高命中率」加了：

```nginx
proxy_ignore_headers Set-Cookie Cache-Control Expires;
```

这一行是**登录态串号事故的头号元凶**。一旦忽略 `Set-Cookie`，A 用户的登录响应会被缓存并返回给 B 用户。

正确做法：**只对明确无状态的接口开缓存**，用独立的 `location` 隔离，不要全局开。

```nginx
location ~ ^/api/public/ {
    proxy_cache api_cache;
    proxy_cache_key "$scheme$host$request_uri";
    proxy_cache_valid 200 5m;
    proxy_ignore_headers Set-Cookie;   # 仅限确定无 Cookie 的公开接口
    proxy_hide_header Set-Cookie;      # 并且把 Cookie 从响应里摘掉
    add_header X-Cache-Status $upstream_cache_status always;
    proxy_pass http://backend;
}

location /api/ {
    proxy_cache off;                   # 其余接口一律不缓存
    proxy_pass http://backend;
}
```

`add_header ... always` 里的 `always` 很重要，否则 4xx/5xx 响应不会带这个头，排查时看不到。

### 坑 2：缓存了大文件，磁盘 IO 打满

视频、Excel 导出、大 PDF 不适合放 `proxy_cache`（尤其是机械盘）。这类内容应该走对象存储 + CDN。

判断标准：**单响应 > 1MB 且 QPS > 100**，就不要走 Nginx 磁盘缓存。

### 坑 3：`Vary` 头导致命中率归零

上游返回 `Vary: Accept-Encoding, User-Agent, Cookie` 时，Nginx 会按这些头分别缓存。`User-Agent` 有几千种取值，等于缓存全废。

处理方式：`proxy_ignore_headers Vary;`（在你确认内容与这些头无关时），或者在后端收敛 `Vary`。

### 坑 4：缓存目录和日志同盘

Nginx 的 access log 是追加写，缓存是随机读写。同盘时缓存淘汰产生的大量小文件 IO 会和日志刷盘互相干扰。生产上缓存目录必须独立挂盘，并且优先 SSD。

### 坑 5：`proxy_cache_valid` 覆盖了后端语义

```nginx
proxy_cache_valid 200 10m;
```

这会让**所有 200 响应**都按 10 分钟缓存，包括那些本该 `no-store` 的响应。正确姿势是让后端用 `Cache-Control` 表达语义，Nginx 只在后端没给时兜底：

```nginx
proxy_cache_valid 200 302 10m;
proxy_cache_valid 404 1m;
proxy_ignore_headers X-Accel-Expires;   # 允许后端用 X-Accel-Expires 精细控制
```

---

## 六、完整可抄配置模板

```nginx
# ---------- http 块 ----------
proxy_cache_path /data/nginx/cache levels=1:2 keys_zone=api_cache:50m
                 max_size=20g inactive=60m use_temp_path=off
                 manager_sleep=50ms manager_files=200;

# 设备归一化，避免 UA 键空间爆炸
map $http_user_agent $device_type {
    default        "pc";
    ~*mobile       "mobile";
    ~*bot|spider   "bot";
}

server {
    listen 80;
    server_name api.example.com;

    # 公开只读接口：可缓存
    location ~ ^/api/v1/(catalog|config|dict)/ {
        proxy_cache            api_cache;
        proxy_cache_key        "$scheme$host$request_uri|$device_type";
        proxy_cache_valid      200 302 5m;
        proxy_cache_valid      404 30s;
        proxy_cache_lock       on;
        proxy_cache_lock_timeout 3s;
        proxy_cache_use_stale  error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_revalidate on;
        proxy_ignore_headers   Set-Cookie Vary;
        proxy_hide_header      Set-Cookie;

        add_header X-Cache-Status $upstream_cache_status always;
        add_header X-Cache-Key    $scheme$host$request_uri always;

        proxy_pass http://backend;
    }

    # 业务接口：一律不缓存
    location /api/ {
        proxy_cache off;
        proxy_pass  http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

## 七、面试常见追问

**Q1：Nginx 缓存和 Redis 缓存怎么分工？**

Nginx 缓存的是「完整的 HTTP 响应」，属于**边缘缓存**，优势是零业务侵入、命中时延极低（亚毫秒）、不占 JVM 内存；劣势是无法做细粒度失效（只能按 key purge，需要 `ngx_cache_purge` 模块）、不适合个性化数据。Redis 缓存的是「业务数据片段」，可以做精确失效、可以跨服务共享。

实践原则：**能缓存在边缘的绝不放到应用层，能放到应用层的绝不打到数据库。**

**Q2：`proxy_cache_lock` 会不会把 Nginx worker 阻塞住？**

不会。Nginx 是事件驱动，等待锁的请求只是挂在等待队列上，worker 继续处理其他连接。但要注意 `proxy_cache_lock_timeout` 不能设太大，否则大量请求长时间挂起会耗尽 `worker_connections`。

**Q3：怎么做到「发布后立即刷新缓存」？**

三种方式：① 主动 `proxy_cache_purge`（需要模块）；② 版本化 URL（`?v=20261027`），最推荐，天然无失效问题；③ 缩短 TTL + `background_update`。生产上最稳的是 ②。

**Q4：`inactive` 和 `proxy_cache_valid` 有什么区别？**

`proxy_cache_valid` 控制的是「缓存内容的新鲜度」，过期后要回源；`inactive` 控制的是「多久没被访问就删除」，是淘汰策略。一个缓存项可能已经过期（不再返回 HIT）但仍未被删除（还没到 `inactive`）。这也是为什么 `inactive` 应该 ≥ 有效期的原因。

---

## 八、总结

`proxy_cache` 的价值在于**用最少的资源挡掉最多的流量**，但它有三个必须守住的底线：

1. **缓存键必须包含 `$host` 和所有影响响应的业务维度**，宁少勿滥。
2. **`proxy_cache_lock` + `proxy_cache_use_stale` + `background_update` 是生产必备三件套**，缺一个就会有击穿风险。
3. **绝不全局 `proxy_ignore_headers Set-Cookie`**，无状态接口必须用独立 location 隔离。

做到这三点，一个 2 核 4G 的 Nginx 顶上几千 QPS 的读流量完全不是问题，而后端只需要处理真正需要动态计算的那部分请求。
