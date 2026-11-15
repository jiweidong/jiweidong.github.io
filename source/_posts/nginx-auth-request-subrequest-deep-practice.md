---
title: 【Nginx 实战】auth_request 与子请求深度解析：内部鉴权网关的子请求生命周期与生产治理
date: 2026-11-15 08:20:00
tags:
  - Java
  - Nginx
  - 网关
  - 鉴权
  - 微服务
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】auth_request 与子请求深度解析

## 前言

微服务里做统一鉴权，有三种常见落点：

1. 每个服务自己引 Spring Security（重复实现、配置漂移、升级地狱）；
2. 网关层（Spring Cloud Gateway / APISIX）统一校验（要引入 Java/Nginx 之外的组件）；
3. **在 Nginx 层做 `auth_request` 子请求鉴权**（零额外组件，接入成本最低）。

第三条路用的人很多，但真正讲清楚的人很少。大多数配置文章止步于「复制这段配置就能用」，于是生产里出现这些问题：

- POST 请求鉴权永远失败（因为子请求默认不带 body）；
- 上游 auth 服务返回 503，用户看到 500（错误码语义被吞）；
- 每次请求多一次 RTT，QPS 高了之后 auth 服务先崩；
- 想把 auth 返回的 `X-User-Id` 透传给业务，发现拿不到；
- 大文件上传时鉴权接口超时，但业务接口并不慢。

这篇从 **subrequest 的生命周期**讲起，把 `auth_request` 的语义边界、错误码映射、性能模型和五个典型坑全部拆开。

## 一、subrequest 是什么：不是反向代理，是「进程内递归」

Nginx 的 subrequest（子请求）是一个**内部请求**：不经过 socket，不走 TCP，直接在同一个 worker 进程里从 `NGX_HTTP_SERVER_REWRITE_PHASE` 重新走一遍请求处理流程。

它的关键特征：

| 特征 | 说明 |
|---|---|
| 不占连接 | 不消耗 fd、不走 listen socket，只是内存里的 `ngx_http_request_t` 结构 |
| 独立 header | 子请求有自己的 headers_in / headers_out，**不自动继承**父请求的请求头（需要手工 `proxy_set_header`） |
| 默认无 body | 子请求的 `request_body` 是空的，父请求的 body 不会传给它 |
| 走完整 phase | 从 server rewrite 开始，会再次经过 rewrite/access/content 等阶段 |
| 有深度限制 | `NGX_HTTP_MAX_SUBREQUESTS`（默认 50）+ 内部跳转 10 次限制（`NGX_HTTP_MAX_URI_CHANGES`） |
| 结果不直接返回客户端 | 子请求只负责**设置变量和状态码**，响应体默认丢弃 |

最后一点是关键：`auth_request` 是**用于控制流程**的，不是用于转发响应的。它的输入是「状态码」，输出是「通过 / 拒绝」和「一组可提取变量」。

## 二、auth_request 的完整语义

```nginx
location /api/ {
    auth_request /_auth;                  # 触发子请求
    auth_request_set $user_id  $upstream_http_x_user_id;
    auth_request_set $user_role $upstream_http_x_user_role;

    proxy_set_header X-User-Id   $user_id;
    proxy_set_header X-User-Role $user_role;
    proxy_pass http://backend;
}

location = /_auth {
    internal;                             # 禁止外部直接访问
    proxy_pass http://auth-service/verify;

    # 子请求默认不带父请求的 body，这一行是「显式声明我不需要 body」
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";

    # 手工转发父请求上下文
    proxy_set_header X-Original-URI  $request_uri;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header Authorization   $http_authorization;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host            $host;

    # 独立超时预算，必须比业务超时小
    proxy_connect_timeout 200ms;
    proxy_read_timeout    500ms;
    proxy_send_timeout    500ms;
}
```

### 2.1 状态码映射规则（必须背下来）

| auth 子请求返回 | 父请求结果 | 备注 |
|---|---|---|
| 2xx | **通过**，继续执行业务 location | 具体是 200/201/204 都一样 |
| 401 | 返回 401，并**透传 `WWW-Authenticate`** | 浏览器会弹认证框，注意别误用 |
| 403 | 返回 403 | 最常见的「无权限」 |
| 其他（5xx、404、3xx） | **返回 500** | 这是最大的坑：auth 挂了用户看到 500 |

这个映射表解释了两件事：

1. **auth 服务的 404 会变成 500**。如果你的鉴权接口路径配错（`/_auth` 代理到了不存在的 path），用户看到的是 500，日志里没有 401，排查方向会被带偏。
2. **auth 服务不可用时不能靠这个机制做降级**。Nginx 没有「auth 失败则放行」的开关（`satisfy` 也不行，它只对 access 模块生效）。

### 2.2 `auth_request_set` 的变量可见性

`auth_request_set` 在**子请求完成后**才赋值，赋值范围是父请求的变量表。所以：

- 在 `auth_request` 之前使用 `$user_id` 是空值；
- 在 `log_format` 里可以用（日志阶段在 content 之后）；
- 在 `if`/`rewrite` 里判断要注意执行阶段（rewrite 阶段早于 auth 阶段）。

一个常见误用：

```nginx
# 错的：rewrite 阶段执行，此时 $user_id 还没赋值
if ($user_id = "") { return 403; }

# 对的：auth_request 已经把「通过/拒绝」判完了，不需要再判
```

### 2.3 与 `satisfy`、`deny`、Lua 的关系

| 方案 | 执行阶段 | 能否读 body | 能否做复杂逻辑 | 额外组件 |
|---|---|---|---|---|
| `allow/deny` + `satisfy any` | access | 否 | 否（仅 IP） | 无 |
| `auth_basic` | access | 否 | 否 | 无 |
| `auth_request` | access | 否（默认） | 由后端决定 | 无（但需要 auth 服务） |
| `access_by_lua` (OpenResty) | access | 是（`ngx.req.read_body`） | 是（可写 Redis/JWT 本地验签） | OpenResty |
| Spring Cloud Gateway `GlobalFilter` | 应用层 | 是 | 是 | Java 网关 |

**关键结论：如果鉴权需要看请求体（比如校验 body 里的资源 ID 是否属于该用户），`auth_request` 会很别扭**——虽然可以在父请求里 `proxy_set_header` 传 body 的哈希，但完整 body 转发需要 `proxy_pass_request_body on` + 重设 `Content-Length`，代价是大 body 全量缓冲，得不偿失。

## 三、性能模型：为什么会多一次 RTT，以及怎么消掉

`auth_request` 的本质是**串行依赖**：父请求必须等子请求完成才能继续。

```
客户端 → Nginx → auth-service（RTT_auth）→ Nginx → backend（RTT_backend）→ 客户端
总延迟 = RTT_auth + RTT_backend
```

同机房内 `RTT_auth` 大约 1~3ms，看起来不多。但要注意三个放大效应：

**放大 1：auth 服务的 QPS = 业务 QPS，且没有缓存。**
如果业务 5000 QPS，auth 服务就要扛 5000 QPS，即使每个用户每分钟只发几个请求。

**放大 2：auth 服务成为新的单点瓶颈。**
Nginx 的 worker 是事件驱动的，可以扛几万连接；但如果 auth 是 Java 服务，线程池一满就排队，`proxy_read_timeout` 一到就是 500（还记得上面的映射表吗）。

**放大 3：超时预算被吃掉。**
业务 SLO 是 200ms，auth 占 3ms 还好；但如果 auth 在高峰期 P99 到 80ms，业务 SLO 直接被击穿，而且**从业务服务的监控上看不出来**（因为时间花在 Nginx 之前的阶段）。

### 3.1 三种优化手段

**手段 1：Nginx 侧短缓存（适合「权限变化不敏感」的场景）**

```nginx
proxy_cache_path /var/cache/nginx/auth levels=1:2 keys_zone=auth_cache:20m
                 max_size=200m inactive=60s use_temp_path=off;

location = /_auth {
    internal;
    proxy_pass http://auth-service/verify;
    proxy_cache auth_cache;
    proxy_cache_key "$http_authorization$request_method$uri";
    proxy_cache_valid 200 10s;        # 10 秒内的相同凭证直接命中
    proxy_cache_valid 401 403 60s;    # 拒绝结果缓存更久，防撞库
    proxy_cache_lock on;              # 相同 key 只放一个请求回源（防击穿）
    proxy_cache_use_stale error timeout updating;
    proxy_ignore_headers Cache-Control Expires Set-Cookie;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_authorization;
    proxy_set_header X-Original-URI $request_uri;
}
```

注意 `proxy_cache_key` **必须包含凭证**，否则 A 用户的鉴权结果会被 B 用户命中——这是最危险的一类配置错误。

**手段 2：把「能本地判的」放到 Nginx 判，只把「必须回源的」交给 auth**

JWT 的签名校验可以用 `auth_request` + 一个极轻量的验签服务，也可以用 OpenResty 的 `lua-resty-jwt` 本地验签（零 RTT）。混合方案：

```nginx
# 第一层：本地粗判（无 RTT）
map $http_authorization $has_token {
    "~^Bearer " 1;
    default     0;
}

location /api/ {
    if ($has_token = 0) { return 401; }   # 只在 rewrite 阶段，安全
    auth_request /_auth;                  # 第二层：回源校验签名与权限
    ...
}
```

**手段 3：把权限粒度做粗，减少 auth 调用**
按「角色 + 资源类型」鉴权（Nginx 回源），具体的「这条数据是否属于你」在业务层做（业务层本来就要查库，顺手校验零成本）。这条是架构层面的取舍，收益最大。

## 四、五个生产级大坑

### 坑 1：`proxy_pass_request_body off` 忘了写，大文件上传变慢

子请求默认会把父请求的 body 转发给 auth 服务。上传 100MB 文件时，Nginx 会先缓冲/流式转发 100MB 给 auth 服务，auth 服务还得读完（或者直接拒绝），延迟和内存双爆。

**规则：auth 子请求永远 `proxy_pass_request_body off` + `proxy_set_header Content-Length ""`。**

### 坑 2：Authorization 头没有转发，鉴权永远失败

子请求有自己的 header 表。`proxy_set_header Authorization $http_authorization;` 必须写。同理，如果你用了自定义 header（`X-Tenant-Id`），也要逐个转发。

一个更隐蔽的变体：**`underscores_in_headers`**。如果客户端传的是 `X_User_Id`（下划线），Nginx 默认丢弃这类 header。

### 坑 3：auth 服务返回 5xx，用户看到 500，没有降级

```nginx
# 想优雅降级？这行是无效的
proxy_next_upstream error timeout http_502;
```

`proxy_next_upstream` 只对「上游连接失败」有效，对 `auth_request` 的业务语义无效。而且**如果 auth 全部不可用，Nginx 会把所有请求变成 500**——这不是「fail-closed 更安全」的优雅实现，而是「全站挂掉」。

正确做法：

- auth 服务做**多副本 + 本地缓存兜底**（Redis 存一份 token→权限映射，TTL 5 分钟）；
- 监控上把 `auth_request` 的 5xx 单独告警（用 `$upstream_status` 在 auth location 里记日志）；
- 明确业务语义：**宁可 401 也不要 500**。可以在 auth location 里用 `error_page 500 502 503 504 = @auth_fail;` 转成 401。

```nginx
location = /_auth {
    internal;
    proxy_pass http://auth-service/verify;
    error_page 500 502 503 504 = @auth_fail;
    ...
}
location @auth_fail {
    internal;
    return 401;   # 明确表达「凭证无效」，而不是「服务器错误」
}
```

### 坑 4：内部跳转 10 次上限，循环 rewrite 直接 500

`auth_request` 本身有子请求数量上限（50），但更常见的是 **rewrite 循环**触发 `rewrite or internal redirection cycle`：

```nginx
# 危险：/api 前缀被反复重写
location /api/ {
    rewrite ^/api/(.*)$ /$1 break;   # break 只跳当前 location，安全
    # rewrite ^/api/(.*)$ /$1 last;  # last 会重新匹配 location，可能循环
}
```

排查靠 `error_log ... debug`，日志里会明确写 `rewriting ... to ...` 的链条。

### 坑 5：`auth_request_set` 提取不到 header

三个原因：

1. auth 服务返回的 header 名带下划线（`X_User_Id`）→ 被丢弃；
2. 用了 HTTP/2 上游（`grpc_pass`），header 名会小写化 → 变量名仍是 `$upstream_http_x_user_id`（小写），写法没问题但容易误判；
3. **auth 服务返回了 401，但你仍然想读 header**（比如读 `X-Auth-Reason`）→ 只有 2xx 时 `auth_request_set` 才会执行提取逻辑（严格说：变量会赋值，但父请求已经短路返回，用不上）。

## 五、一个可落地的完整方案

目标：多租户 SaaS，Nginx 做统一鉴权 + 用户上下文注入，后端服务不再关心 token。

```nginx
upstream auth_service {
    server 10.0.1.11:8080;
    server 10.0.1.12:8080;
    keepalive 64;                      # 复用连接，省掉 3 次握手
}

upstream app_backend {
    server 10.0.2.11:8080;
    server 10.0.2.12:8080;
    keepalive 128;
}

server {
    listen 443 ssl;
    http2 on;
    server_name api.example.com;

    # 全局：所有业务请求先过鉴权
    location /api/ {
        auth_request /_auth;
        auth_request_set $uid   $upstream_http_x_user_id;
        auth_request_set $roles $upstream_http_x_user_roles;
        auth_request_set $tid   $upstream_http_x_tenant_id;

        # 清掉客户端伪造的可能
        proxy_set_header X-User-Id    $uid;
        proxy_set_header X-User-Roles $roles;
        proxy_set_header X-Tenant-Id  $tid;
        proxy_set_header X-Real-IP    $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_pass http://app_backend;
    }

    # 白名单：登录、健康检查不鉴权
    location /api/public/ {
        proxy_pass http://app_backend;
    }

    location = /_auth {
        internal;
        proxy_pass http://auth_service/verify;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Authorization    $http_authorization;
        proxy_set_header X-Original-URI   $request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Real-IP        $remote_addr;

        proxy_connect_timeout 100ms;
        proxy_read_timeout    300ms;
        error_page 500 502 503 504 = @auth_fail;

        # 单独的日志，便于算 auth 的 P99
        access_log /var/log/nginx/auth.log auth_fmt;
    }

    location @auth_fail { internal; return 401; }
}
```

配套的 `log_format`，把 auth 的耗时与状态单独打出来：

```nginx
log_format auth_fmt '$time_iso8601 $request_method $uri '
                    'status=$upstream_status rt=$upstream_response_time '
                    'upstream=$upstream_addr';
```

有了这个日志，你才能回答「auth 的 P99 是多少」——这是排查「业务慢但业务日志正常」的第一现场。

## 六、Java 侧的配合要点

**1. auth 服务必须极轻。** 只做「token 解析 + 签名校验 + 权限查询」，不要在这里查业务库、不要做审计落库（审计异步化）。目标 P99 < 5ms。

**2. 返回 header 用规范名，不要下划线。** Spring Boot 里：

```java
@GetMapping("/verify")
public ResponseEntity<Void> verify(@RequestHeader("Authorization") String auth,
                                   @RequestHeader(value = "X-Original-URI", required = false) String uri) {
    Claims claims = jwtService.parse(auth);
    return ResponseEntity.ok()
            .header("X-User-Id", claims.getSubject())
            .header("X-Tenant-Id", String.valueOf(claims.get("tid")))
            .header("X-User-Roles", String.join(",", roles(claims)))
            .build();   // 204/200 均可，body 留空
}
```

**3. 注意 `ResponseEntity.ok()` 会带 `Content-Length: 0`**，没问题；但如果你返回了 body，Nginx 会把它丢弃（不影响正确性，只浪费带宽）。

**4. 拒绝时用 401/403，不要用 400。** 400 会被映射成 500，用户看到「服务器错误」，客服会被打爆。

**5. 后端服务要校验「这些 header 是不是 Nginx 注入的」。** 如果后端端口在内网可达（很多人忘了关），攻击者可以直连后端伪造 `X-User-Id`。做法：后端只监听 127.0.0.1 或安全组限制来源，或者加一个 Nginx 与后端共享的 `X-Internal-Sign`。

## 七、面试追问

**Q1：`auth_request` 和 `proxy_pass` 有什么区别？**
`proxy_pass` 是反向代理，请求经过网络到上游，上游的响应会返回给客户端；`auth_request` 是内部子请求，不走网络（对 Nginx 而言），结果只取状态码和变量，响应体被丢弃，用于控制父请求是否继续。

**Q2：auth 子请求返回 403 和 401 有什么区别？**
401 表示「未认证」，Nginx 会把 `WWW-Authenticate` 透传给客户端；403 表示「已认证但无权限」。其他状态码（含 5xx）一律变成 500，所以鉴权服务要严格只用 401/403 表达拒绝。

**Q3：怎么避免 auth 成为性能瓶颈？**
三层：Nginx 侧短 TTL 缓存（key 必须含凭证）、把可本地判定的逻辑前移（JWT 本地验签）、把权限粒度做粗（资源级校验放业务层，反正业务要查库）。

**Q4：子请求能拿到父请求的请求体吗？**
默认不能。需要 `proxy_pass_request_body on` 并重设 `Content-Length`，代价是 body 全量缓冲，大 body 场景不可接受。所以「需要看 body 的鉴权」不适合 `auth_request`。

## 总结

- `auth_request` = 进程内子请求 + 状态码语义 + 变量提取，不是反向代理。
- 状态码映射只有三个分支：2xx 通过、401/403 拒绝、**其他全部 500**——所以鉴权服务必须只用 401/403 表达拒绝。
- 三个必写配置：`internal`、`proxy_pass_request_body off`、`proxy_set_header Authorization`。
- 性能靠缓存和粒度，不靠加机器。缓存 key 必须含凭证，否则是越权漏洞。
- 后端必须假设「header 可能被伪造」，靠网络隔离或内部签名兜底。

Nginx 这一层的坑，本质都是「阶段（phase）与上下文（context）」的问题。搞清 subrequest 的生命周期，剩下都是配置细节。
