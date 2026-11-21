---
title: 【Nginx 实战】stream 四层代理深度实战：TCP/UDP 转发、TLS 透传与 SNI 分流
date: 2026-11-21 08:20:00
tags:
  - Nginx
  - Java
  - TCP
  - TLS
  - 运维
categories:
  - 中间件实战
author: 东哥
---

# 【Nginx 实战】stream 四层代理深度实战

## 前言

提到 Nginx，绝大多数人想的是 `location`、`proxy_pass`、`upstream` —— 那是 `http` 模块，工作在第七层。但在真实系统里还有一类需求它解决不了：

- 数据库（MySQL/PostgreSQL）要经过统一入口，做故障转移和内网收敛。
- Redis 集群要给外部租户暴露，但不能让租户直连节点。
- 多租户 SaaS，每个客户用自己的域名和证书，需要**按 SNI 分流但不在网关解密**。
- 一套入口同时承载 HTTPS 和 MQTT/自定义二进制协议。

这些都得用 `stream` 模块 —— Nginx 的**四层（TCP/UDP）代理**。它不理解应用协议，只搬字节，所以能力边界和 `http` 模块完全不同。这篇文章把这个边界讲清楚。

## 一、stream 模块的定位：它不懂协议，这是优点也是限制

| 能力 | `http` 模块 | `stream` 模块 |
|---|---|---|
| 理解请求 | ✅ 解析 HTTP 头/体 | ❌ 只搬字节流 |
| 路由依据 | URI、Header、Cookie、方法 | 源 IP、端口、SNI、ALPN |
| 改写内容 | ✅ `sub_filter`、`proxy_set_header` | ❌ 不可能 |
| 连接复用 | ✅ `keepalive` 连接池 | 1.15.9+ 支持（早期版本没有） |
| 健康检查 | 被动 + 主动（Plus） | 仅被动（OSS） |
| TLS | 可终止、可校验客户端证书 | 可终止，也可纯透传 |
| 典型用途 | Web API、静态资源、gRPC | MySQL/Redis/MQTT/DNS、TLS 透传 |

**关键认知**：`stream` 里的 `proxy_pass` 没有 `http://` 前缀，也不能带路径；`location`、`proxy_set_header`、`add_header` 全都不存在。想改一个字节的应用数据，只能上 `stream_lua`（OpenResty）或者换方案。

## 二、最小可用配置：代理 MySQL

```nginx
# /etc/nginx/nginx.conf
stream {
    upstream mysql_primary {
        server 10.0.1.11:3306 max_fails=3 fail_timeout=10s;
        server 10.0.1.12:3306 max_fails=3 fail_timeout=10s backup;
    }

    server {
        listen 3306;
        proxy_pass mysql_primary;
        proxy_connect_timeout 3s;
        proxy_timeout 600s;
    }
}
```

几个参数的真实语义：

- `proxy_connect_timeout`：与后端建连的超时。**默认 60s，对这个场景太长**，后端挂了会让客户端等 60 秒，改成 3s。
- `proxy_timeout`：**两次连续读/写操作之间的空闲超时**，不是"整个会话总时长"。默认 10 分钟。MySQL 的 `wait_timeout` 默认 8 小时，所以这里设 600s 会导致 Nginx 先断开空闲连接 —— 客户端连接池里的连接变成"死连接"，下次借出来用直接 `Communications link failure`。
- `max_fails`/`fail_timeout`：被动健康检查。连续失败 3 次后，该后端在 10 秒内不再被选中。

### 2.1 `proxy_timeout` 与后端 idle timeout 的配合

这是 L4 代理最高频的线上问题。三条时间线必须满足：

```text
客户端连接池 idle 检测  <  Nginx proxy_timeout  <  后端 wait_timeout
```

推荐值：

| 层 | 配置 | 建议 |
|---|---|---|
| 客户端（HikariCP） | `idleTimeout` / `maxLifetime` | `maxLifetime` 比后端 `wait_timeout` 小 2~3 分钟 |
| Nginx | `proxy_timeout` | 略大于后端 `wait_timeout`，或直接关掉（`proxy_timeout 1h`） |
| MySQL | `wait_timeout` | 默认 28800s，很多云托管改成 300s |

如果 Nginx 的 `proxy_timeout` 小于后端 `wait_timeout`，Nginx 会先发 FIN。此时客户端连接池认为连接还活着（没收到 RST），下一次写入才报错。**这类"间歇性连接重置"90% 是这条时间线配错了。**

### 2.2 源 IP 丢失问题

经过 L4 代理后，MySQL 看到的客户端 IP 全是 Nginx 的地址。影响：

1. 基于 `GRANT ... TO 'user'@'ip'` 的权限模型失效。
2. 慢查询日志、审计日志里的来源全是网关。
3. `performance_schema` 里的连接归属无法区分业务。

三种解法：

| 方案 | 原理 | 限制 |
|---|---|---|
| PROXY protocol | Nginx 在连接首部插入 `PROXY TCP4 src dst sport dport` 文本行 | **后端必须支持**：MariaDB 10.3+、ProxySQL、部分云数据库；MySQL 官方版不支持，开启后握手直接乱码 |
| 应用层传递 | 业务 SQL 里带 `SET @client_ip=...` | 需改代码，且连接池复用会串味 |
| 网段映射 | 按源网段分配不同数据库账号 | 粒度粗，但零改造 |

PROXY protocol 的配置：

```nginx
server {
    listen 3306;
    proxy_pass mysql_primary;
    proxy_protocol on;      # 发给后端
}
```

⚠️ **开之前一定确认后端支持**。如果不支持，现象是"连接建立了但立刻断开"或"Access denied"，因为后端把 `PROXY TCP4 ...` 当成协议握手包解析了。

如果客户端到 Nginx 这一段也经过了一层代理（比如云 SLB），Nginx 自己也需要 `listen 3306 proxy_protocol;` 来接收上游的 PROXY 头，否则 `$remote_addr` 拿到的还是上一层代理的 IP。两段都要配对。

## 三、TLS 透传 vs TLS 终止：这是架构选择

### 3.1 两种模式的本质区别

```nginx
# 模式 A：TLS 终止（在 Nginx 解密）
stream {
    server {
        listen 443 ssl;
        ssl_certificate     /etc/nginx/certs/api.crt;
        ssl_certificate_key /etc/nginx/certs/api.key;
        proxy_pass 10.0.2.10:8443;      # 后端是明文 HTTP
    }
}

# 模式 B：TLS 透传（不解密，直接搬）
stream {
    server {
        listen 443;
        proxy_pass 10.0.2.10:443;       # 后端自己做 TLS
    }
}
```

| 维度 | TLS 终止 | TLS 透传 |
|---|---|---|
| 端到端加密 | ❌ 网关是中间人 | ✅ 真正的 E2E |
| 能否做 L7 路由 | ✅ 按路径/Header | ❌ 只能按 SNI |
| 证书管理 | 集中在网关 | 分散在各后端 |
| 客户端证书校验（mTLS） | ✅ 网关统一校 | 各后端自己校 |
| 后端 CPU | 低（明文） | 高（每个连接都要握手） |
| 合规（金融/医疗） | 常有争议 | 通常必需 |
| 排障 | 能看到明文（也是风险） | 只能看字节数 |

### 3.2 用 `ssl_preread` 做 SNI 分流（不解密也能路由）

这是 `stream` 最漂亮的用法：读取 ClientHello 里的 SNI 字段，**不完成握手、不解密**，直接按域名转发。

```nginx
stream {
    map $ssl_preread_server_name $backend {
        api.example.com      api_pool;
        admin.example.com    admin_pool;
        ~^(.+)\.tenant\.io$  tenant_pool;
        default              fallback_pool;
    }

    upstream api_pool     { server 10.0.3.10:443; }
    upstream admin_pool   { server 10.0.3.20:443; }
    upstream tenant_pool  { server 10.0.3.30:443; }
    upstream fallback_pool{ server 10.0.3.99:443; }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend;

        # 关键：后端使用 SNI 做证书选择时，Nginx 必须把原始 SNI 传下去
        proxy_ssl_server_name on;
        proxy_ssl_name $ssl_preread_server_name;
    }
}
```

四个细节：

1. `ssl_preread on` 需要编译时带 `--with-stream_ssl_preread_module`（官方包默认带，自编译要检查 `nginx -V`）。
2. `proxy_pass` 的变量来自 `map`，属于**运行时变量**，Nginx 会在每个连接上重新解析 upstream 组 —— 这比静态 upstream 多一点开销，但可以接受。
3. `proxy_ssl_server_name on` 只有在 Nginx 作为 TLS **客户端**时才生效 —— 透传模式下 Nginx 不发起 TLS 握手，所以这行其实无关；但如果你用 `ssl_preread` 分流后又在同一台机器上 `proxy_pass https://127.0.0.1:8443`（终止模式），它就必须开，否则后端收到的是 IP 而不是域名，证书校验失败。
4. `$ssl_preread_alpn_protocols` 可以按 ALPN 分流（`h2` / `http/1.1` / 自定义协议），做"同端口多协议"时有用。

### 3.3 443 端口不能同时被 http 和 stream 监听

这是新手必踩的坑：`http { server { listen 443 ssl; } }` 和 `stream { server { listen 443; } }` **冲突**，Nginx 启动直接报 `duplicate listen options` 或地址占用。

正确做法是"外层 stream 收 443，内层 http 监听本地高端口"：

```nginx
stream {
    map $ssl_preread_server_name $upstream {
        default  127.0.0.1:8443;   # 交给本机 http 模块
    }
    server {
        listen 443;
        ssl_preread on;
        proxy_pass $upstream;
    }
}

http {
    server {
        listen 127.0.0.1:8443 ssl;
        server_name _;
        # ... 正常的 HTTPS 站点配置
    }
}
```

这样 SNI 分流和常规 Web 服务可以共存，代价是多一跳 loopback（延迟增加约 0.1ms，可忽略）。

## 四、负载均衡与会话保持

```nginx
upstream mysql_pool {
    least_conn;
    server 10.0.1.11:3306;
    server 10.0.1.12:3306;
    keepalive 32;
    keepalive_timeout 60s;
}
```

| 算法 | 适用 | 陷阱 |
|---|---|---|
| 默认 round-robin | 无状态短连接 | MySQL 长连接池下会按连接均分，但连接池大小固定则长期倾斜 |
| `least_conn` | 连接时长差异大 | 对 CPU 负载无感知 |
| `hash $remote_addr consistent` | 需要会话粘滞 | 客户端在 NAT 后则全部落到一台 |
| `random two` | 大规模集群 | 需要较多 upstream |

**MySQL/Redis 场景下，`hash $remote_addr consistent` 往往是个坏主意**：一个应用实例的所有连接都会打到同一台数据库，连接池 20 个连接全压一台，另外两台闲着。只有"必须命中特定节点"（比如读写分离里强制走主库）才用。

### 4.1 `keepalive` 在 stream 里的历史包袱

`upstream { keepalive N; }` 在 `stream` 里是 **1.15.9 才引入**的。更早的版本只能靠：

```nginx
proxy_socket_keepalive on;
```

注意这两者完全不同：

- `keepalive N`：连接**复用**池，N 个空闲连接留给下一个客户端用。
- `proxy_socket_keepalive on`：给 socket 设 `SO_KEEPALIVE`，只是**探测**，不能复用连接。

很多老文章把它们混为一谈，导致按"开了 keepalive"配置却发现 QPS 高时后端连接数爆炸。查版本：

```bash
nginx -v    # 1.24.x 之类
```

### 4.2 被动健康检查的边界

OSS 版 `stream` 只有被动检查：`max_fails` + `fail_timeout`。这意味着：

- 后端进程还在但端口不通 → 连接被拒 → 计入失败 → 摘除。
- 后端能建连但立刻断开（半死状态）→ 只要 TCP 握手成功，**不算失败**。
- 没有任何主动探测，只能等真实流量踩雷。

如果要主动检查，只有三条路：Nginx Plus（付费）、OpenResty + Lua 定时探测、或者把健康检查交给上游（Kubernetes 的 readiness + Service 摘端点）。

### 4.3 `proxy_next_upstream` 的重试边界

```nginx
proxy_next_upstream on;
```

它的语义是"连接后端失败时换下一个"。但对不同协议效果天差地别：

- **服务端先说话**（MySQL、Redis、SMTP）：客户端还没发数据，Nginx 就能发现后端挂了并重试，效果好。
- **客户端先说话**（HTTP、自定义协议）：数据已经发给后端了，无法重试 —— 所以 `http` 模块的 `proxy_next_upstream` 只在 `non_idempotent` 明确允许时才敢重试非幂等请求。

## 五、UDP 代理：DNS 与自定义协议

```nginx
stream {
    upstream dns_pool {
        server 10.0.5.11:53;
        server 10.0.5.12:53;
    }

    server {
        listen 53 udp;
        proxy_pass dns_pool;
        proxy_timeout 5s;
        proxy_responses 1;      # 期望后端返回几个报文，到数即关闭会话
    }
}
```

`proxy_responses` 是 UDP 特有的：Nginx 需要知道"这个 UDP 会话什么时候算结束"，否则每个请求都要占一个会话槽位直到超时。DNS 是一问一答，设 1；如果后端会返回多个包（比如分片响应），要相应调大。

`proxy_timeout` 在 UDP 下默认 10s，DNS 场景建议 2~5s —— 太长了会积压会话。

## 六、可观测：stream 也有 access log

```nginx
stream {
    log_format basic '$remote_addr:$remote_port -> $upstream_addr '
                     'status=$status sent=$bytes_sent recv=$bytes_received '
                     'time=$session_time sni=$ssl_preread_server_name';
    access_log /var/log/nginx/stream.log basic;
}
```

| 变量 | 含义 | 用途 |
|---|---|---|
| `$status` | 会话状态（200 正常结束） | 统计异常断开比例 |
| `$session_time` | 会话总时长 | 发现"3 秒就断"的握手失败 |
| `$bytes_received` / `$bytes_sent` | 双向字节数 | 识别只连不用、或大结果集 |
| `$upstream_addr` | 实际后端 | 定位倾斜 |
| `$ssl_preread_server_name` | 读到的 SNI | 多租户统计 |

**一个非常实用的告警**：`$session_time < 1s` 的会话占比突增。这通常意味着后端在建连后立刻断开（认证失败、连接数打满、TLS 版本不匹配），而此时 Nginx 的错误日志里什么都没有 —— 因为 TCP 层一切正常。

```bash
# 统计 1 秒内结束的会话占比
awk '{match($0,/time=([0-9.]+)/,m); if (m[1]+0 < 1) s++; t++} END {print s/t}' /var/log/nginx/stream.log
```

## 七、常见故障对照表

| 现象 | 最可能原因 | 排查 |
|---|---|---|
| 连接建立后立刻断开 | 后端不支持 PROXY protocol，或 TLS 版本不匹配 | 抓包看首包内容；临时关 `proxy_protocol` |
| 间歇性 `Communications link failure` | `proxy_timeout` < 后端 `wait_timeout` | 对比三条时间线 |
| 所有连接打到一台后端 | 用了 `hash $remote_addr`，客户端在 NAT 后 | 换 `least_conn` |
| 后端连接数远高于客户端数 | 老版本无 `keepalive`，或 `proxy_socket_keepalive` 被误当复用 | `nginx -v` + 查 upstream 配置 |
| 大包上传卡死 | MTU 不一致（VXLAN/隧道场景） | 抓包看是否缺 ICMP `fragmentation needed` |
| 443 启动报地址占用 | http 和 stream 同时监听 443 | 改 loopback 分层方案 |
| 慢查询日志里全是网关 IP | 未启用 PROXY protocol | 见 2.2 节三方案 |

## 八、面试追问

**Q：`stream` 的 `proxy_timeout` 和 `http` 的 `proxy_read_timeout` 有什么区别？**

`http` 的 `proxy_read_timeout` 是"两次读操作之间的间隔"，且只在等待响应体时生效，请求头阶段有单独的 `proxy_send_timeout`。`stream` 的 `proxy_timeout` 是"两次任意方向 IO 之间的间隔"，没有请求/响应阶段的区分 —— 因为它根本不知道协议边界。

**Q：为什么 TLS 透传模式下不能用 `proxy_ssl_verify`？**

`proxy_ssl_*` 系列是 Nginx 作为 TLS 客户端时的参数。透传模式下 Nginx 不参与握手，字节流从客户端直接流向后端，Nginx 没有 TLS 会话可校验。要校验后端证书，只能改成终止模式（或者在后端侧做校验）。

**Q：SNI 分流能防住"用 IP 直连"的绕过吗？**

不能。客户端直接连 IP 时不发 SNI（或发 IP 作为 SNI），`map` 会落到 `default`。所以 `default` 必须指向一个"拒绝或默认租户"的后端，不能是空配置 —— 空 `default` 会导致 `proxy_pass` 变量为空，Nginx 直接 502。安全上还要靠网络层（安全组/防火墙）限制直连后端。

**Q：四层代理能不能做限流？**

原生 `stream` 有 `limit_conn`（连接数）但没有 `limit_req`（请求速率）—— 因为它数不清"请求"。要做速率限制只能靠 OpenResty 的 `stream_lua` 按字节/包计数，或者在上层 L7 做。

## 九、落地清单

1. `proxy_connect_timeout` 从默认 60s 降到 3s。
2. `proxy_timeout` 与后端 idle timeout 排序核对，别让 Nginx 先断。
3. PROXY protocol 两端都要配对，且确认后端真的支持。
4. 长连接池场景用 `least_conn`，别用 `hash $remote_addr`。
5. `keepalive` 需要 1.15.9+，别把 `proxy_socket_keepalive` 当复用。
6. 443 想同时跑 Web 和透传，用 loopback 分层。
7. `default` 分支必须有后端，否则 502。
8. 配 stream access log，重点看 `$session_time` 分布。
9. 主动健康检查 OSS 没有，交给 K8s readiness 或上 Plus。
10. UDP 必须设 `proxy_responses`，否则会话堆积。

`stream` 模块的价值在于：**它让"不懂协议"变成了一种能力** —— 不解析、不改写、不缓冲，纯粹地转发，因此能透明地承载任何协议，包括那些还没被发明出来的。代价是所有 L7 的便利都没有。认清这条边界，就不会再问"为什么 stream 里不能加 header"了。
