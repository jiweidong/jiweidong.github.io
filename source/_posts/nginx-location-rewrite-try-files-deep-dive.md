---
title: 【Nginx 实战】location 匹配优先级与 rewrite/try_files 深度解析：从 404 排查到灰度分流
date: 2026-11-04 08:00:00
tags:
  - Nginx
  - 反向代理
  - 运维
  - 面试
categories:
  - 中间件
author: 东哥
---

# 【Nginx 实战】location 匹配优先级与 rewrite/try_files 深度解析

## 前言

Nginx 的 `location` 大概是最"看起来简单、用起来踩坑"的配置块。几乎每个 Java 后端都写过类似的东西：

```nginx
location /api/ {
    proxy_pass http://backend;
}
```

然后某一天加了一个 `location ~ \.php$`、又加了一个 `location = /api/health`，线上突然开始 404，或者 `/api/health` 被转发到了后端却拿不到 200，或者 `try_files` 把静态资源和后端接口搞混了。

面试里也常问：「Nginx location 的匹配顺序是什么？」「`=` 和 `^~` 有什么区别？」「`rewrite` 的 `last` 和 `break` 差在哪？」「`proxy_pass` 带不带斜杠到底影响什么？」

这篇把这几件事一次讲透，并给出一个真实可用的**灰度分流 + SPA 前端路由**配置模板。

---

## 一、location 匹配优先级：一张表定生死

Nginx 的 location 匹配**不是按配置文件书写顺序**，而是有一套固定的优先级规则。

| 优先级 | 修饰符 | 类型 | 说明 |
|---|---|---|---|
| 1 | `=` | 精确匹配 | 完全相等才命中，命中即终止 |
| 2 | `^~` | 前缀匹配（抑制正则） | 命中最长前缀后**跳过正则** |
| 3 | `~` | 正则匹配（区分大小写） | 按**书写顺序**第一个命中即用 |
| 4 | `~*` | 正则匹配（不区分大小写） | 同上 |
| 5 | 无修饰符 | 普通前缀匹配 | 记住最长匹配，**之后仍尝试正则** |

关键点在于：**普通前缀匹配和 `^~` 前缀匹配的差别，只在"是否继续尝试正则"**。

```nginx
location /static/ {
    root /var/www;
}

location ~ \.(js|css)$ {
    expires 7d;
}
```

请求 `/static/app.js`：普通前缀 `/static/` 命中，但**不终止**，继续跑正则，`\.(js|css)$` 命中 → 最终走正则块。这就是很多人"明明写了 `root` 却没生效"的原因。

改成 `location ^~ /static/` 就会在命中前缀后直接停止，正则不再参与。

> 记忆口诀：**精确 > 抑制正则的前缀 > 正则（书写顺序）> 普通前缀（最长优先）**。注意正则排在普通前缀之前，这是最反直觉的一点。

### 容易错的三个细节

1. **最长前缀 vs 正则**：普通前缀匹配会记住最长的那一个，但如果后面有任意正则命中，正则赢。
2. **正则是"第一个命中"而不是"最长命中"**：所以 `location ~ \.php$` 写在 `location ~ ^/api/.*\.php$` 之前，后者永远不会被用到。
3. **`=` 精确匹配不带路径归一化**：`/api/` 和 `/api` 是两个不同的 URI，`location = /api/` 不会命中 `/api`。

---

## 二、proxy_pass 带不带斜杠：URI 替换的唯一规则

这是 Nginx 里最经典的"玄学"，其实只有一条规则：

**如果 `proxy_pass` 后面带了 URI（哪怕只是一个 `/`），就用它替换掉 location 匹配到的那部分前缀；如果不带 URI，就原样透传整个请求 URI。**

```nginx
# 场景 1：不带斜杠 → 原样透传
location /api/ {
    proxy_pass http://backend;
}
# 请求 /api/user/1 → 后端收到 /api/user/1

# 场景 2：带斜杠 → 剥离 location 前缀
location /api/ {
    proxy_pass http://backend/;
}
# 请求 /api/user/1 → 后端收到 /user/1

# 场景 3：带路径 → 前缀替换
location /api/ {
    proxy_pass http://backend/v2/;
}
# 请求 /api/user/1 → 后端收到 /v2/user/1
```

而**正则 location 里 `proxy_pass` 带变量时，Nginx 不会做 URI 替换**，必须自己用 `rewrite` 或变量拼：

```nginx
location ~ ^/api/(.+)$ {
    proxy_pass http://backend/$1;   # 正则捕获组可以用
}
```

生产上最常见的坑：Spring Boot 应用配了 `server.servlet.context-path=/app`，网关又想剥掉 `/api` 前缀，结果 `proxy_pass` 少写一个斜杠，后端全部 404，而 `curl` 直连后端是好的——因为问题出在网关的 URI 重写上。

---

## 三、rewrite：last / break / redirect / permanent

`rewrite regex replacement [flag]` 的四个 flag，本质是**两个维度**：是否重新匹配 location、是否返回 3xx。

| flag | 是否停止当前 rewrite 序列 | 是否重新匹配 location | 是否发 3xx |
|---|---|---|---|
| `last` | 是 | **是**（重新走 location 匹配） | 否 |
| `break` | 是 | 否（留在当前 location 继续后续指令） | 否 |
| `redirect` | 是 | — | 302 临时 |
| `permanent` | 是 | — | 301 永久 |

```nginx
# 旧域名永久跳转
server {
    server_name old.example.com;
    rewrite ^/(.*)$ https://new.example.com/$1 permanent;
}
```

`last` 与 `break` 的区别，用这个例子最能看清：

```nginx
location /a/ {
    rewrite ^/a/(.*)$ /b/$1 last;    # 重新匹配，会进入 location /b/
}

location /b/ {
    rewrite ^/b/(.*)$ /c/$1 break;   # 不重匹配，留在 /b/ 里继续处理
    proxy_pass http://backend;
}
```

### ⚠️ 内部跳转有 10 次上限

`last` 会重新进入 location 匹配流程，如果没有收敛条件，就会出现：

```
rewrite or internal redirection cycle while internally redirecting to "/index.html"
```

Nginx 硬编码了**最多 10 次内部跳转**。SPA 场景下的典型死循环：

```nginx
location / {
    try_files $uri $uri/ /index.html;   # index.html 不存在时无限跳自己
}
```

如果 `root` 配错了目录，`/index.html` 也不存在，`try_files` 会再次 fallback 到 `/index.html`，10 次后报 500。看到这个报错，**第一反应是查 root/alias 路径下文件到底存不存在**，而不是加大跳转次数（也加不了）。

---

## 四、try_files：SPA 与前后端分离的正确姿势

`try_files` 按顺序检查文件/目录，最后一个参数是 fallback（内部跳转或状态码）。

```nginx
# Vue/React SPA：静态资源优先，其余交给 index.html
location / {
    root /var/www/dist;
    try_files $uri $uri/ /index.html;
}

# 前后端分离：静态资源走本地，/api 走后端
server {
    listen 80;
    server_name app.example.com;

    location ^~ /assets/ {
        root /var/www/dist;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    location /api/ {
        proxy_pass http://backend/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        root /var/www/dist;
        try_files $uri $uri/ /index.html;
    }
}
```

这里用 `^~ /assets/` 而不是普通前缀，是为了**防止 `/assets/xxx.js` 被兜底的 `/index.html` 逻辑或者别的正则抢走**——虽然本例中 `/` 是普通前缀且不会赢过长前缀，但加上 `^~` 是防御性写法。

### 静态资源长缓存 + 文件名 hash

`expires 1y; immutable` 是安全的，**前提是文件名带 content hash**（`app.3f2a1b.js`）。如果是 `app.js` 这种固定名，长缓存会导致发版后用户拿到旧代码，这时候必须改成 `no-cache` 或者加 `?v=` 版本号。

---

## 五、实战：用 map + split_clients 做灰度分流

需求：10% 流量打到新版本，其余走老版本，且同一用户始终落在同一侧（避免刷新跳版本）。

```nginx
# 按 userId 稳定分桶（需要业务在 header/cookie 里带上 userId）
map $cookie_uid $gray_bucket {
    default        "old";
    "~^[0-9]+[0-9]$" "old";
    "~^[0-9]*[0-9]$" "new";   # 简化示意，真实场景用 split_clients
}

split_clients "${remote_addr}${http_user_agent}" $variant {
    10%     new_backend;
    *       old_backend;
}

upstream new_backend {
    server 10.0.1.11:8080 max_fails=3 fail_timeout=10s;
}

upstream old_backend {
    server 10.0.1.10:8080 max_fails=3 fail_timeout=10s;
}

server {
    location /api/ {
        proxy_pass http://$variant;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 1s;
        proxy_read_timeout 10s;
        add_header X-Variant $variant always;   # 便于排查
    }
}
```

`split_clients` 的哈希是基于给定字符串的 murmur2，**同一个 key 永远落在同一桶**，天然满足"用户粘性"。加上 `add_header X-Variant` 回写响应头，排查问题时一眼看出命中了哪一侧。

### 灰度分流的三个生产注意点

1. **会话状态**：新老版本如果 session 不共享（比如本地内存 session），灰度会把用户"打散"。必须先做 `spring-session` + Redis 共享，或者用 JWT 无状态。
2. **数据库兼容**：新版本如果先上线了加字段的代码，老版本读不到会 NPE。灰度前提是 **schema 双向兼容**（expand-contract 模式：先加列 → 双写 → 切读 → 删旧列）。
3. **回滚开关**：把 `10%` 改成 `0%` 再 `nginx -s reload` 是秒级回滚，比重新发布快得多。这是灰度最大的价值，不要只当"发布手段"用。

---

## 六、if is evil：为什么 `if` 在 location 里危险

Nginx 官方 wiki 有一篇著名文档叫 *IfIsEvil*。原因是：**`if` 块在 location 里会创建一个隐式的嵌套 location，且部分指令（如 `proxy_pass`）在 `if` 中的行为不符合直觉**。

```nginx
# ❌ 反模式：if 里放 proxy_pass
location /api/ {
    if ($http_user_agent ~* "bot") {
        return 403;
    }
    proxy_pass http://backend;
}
```

上面这个还算安全（`return` 是 if 里少数安全的指令），但下面这种就危险：

```nginx
# ❌ 危险：if 改变 proxy_pass 目标
location / {
    if ($args ~ "debug=1") {
        proxy_pass http://debug_backend;
    }
    proxy_pass http://prod_backend;
}
```

正确做法是用 `map` 提前算出变量，再在 `proxy_pass` 里引用变量（如上一节的 `$variant`），**把"条件判断"变成"变量求值"**，全程不产生隐式 location。

```nginx
map $arg_debug $target {
    1       debug_backend;
    default prod_backend;
}
```

同理，`if` 也不该用来做 `rewrite ... last` 的组合，那会叠加两层内部跳转，很容易撞 10 次上限。

---

## 七、排查清单：404 / 502 / 499 怎么定位

| 现象 | 常见原因 | 定位手段 |
|---|---|---|
| 404 | `proxy_pass` 斜杠导致 URI 错、`try_files` 路径错、`root` vs `alias` 混用 | `error_log` 调 `info` 级，看 `internal redirect` 记录 |
| 502 | 后端未起、`upstream` 端口错、`proxy_buffer` 太小导致响应头过大 | `curl -v` 直连 upstream、看 `upstream_response_time` |
| 499 | **客户端主动断开**（超时/用户取消），不是 Nginx 的错 | 看 `request_time` 是否接近客户端超时设置 |
| 504 | `proxy_read_timeout` 太短、后端慢查询 | 打 `$upstream_response_time` 日志 |
| 500 循环 | `rewrite`/`try_files` 内部跳转超 10 次 | 查 fallback 目标文件是否存在 |

打开耗时日志的推荐配置：

```nginx
log_format timed '$remote_addr "$request" $status '
                 'rt=$request_time urt=$upstream_response_time '
                 'uaddr=$upstream_addr ut=$upstream_status';
access_log /var/log/nginx/access.log timed;
```

`urt` 为空说明请求根本没到 upstream（被本地 location 处理了，比如静态文件或 404），这是区分"网关问题"和"后端问题"的第一道分水岭。

---

## 八、`root` vs `alias`：一个最容易被忽略的差异

```nginx
location /img/ {
    root /data/static;
    # 实际路径：/data/static/img/a.png（root 会拼接完整 URI）
}

location /img/ {
    alias /data/static/;
    # 实际路径：/data/static/a.png（alias 会替换掉 location 前缀）
}
```

`alias` 必须**以 `/` 结尾**且 location 也建议以 `/` 结尾，否则路径会拼错。`root` 在 `location /` 下等价于 `alias`，但在子路径下完全不同。这种差异在 copy 配置时极容易出事。

---

## 九、面试常见追问

**Q1：`location ~ \.php$` 和 `location ^~ /static/` 同时命中，谁赢？**
如果 URI 是 `/static/a.php`：`^~ /static/` 是前缀匹配且带抑制正则，命中后**不再尝试正则**，所以走 `/static/`。`^~` 的语义就是"停止正则搜索"。

**Q2：`proxy_pass http://backend` 和 `http://backend/` 在 `location /api/` 下的区别？**
前者原样透传 `/api/xxx`，后者剥掉 `/api/` 变成 `/xxx`。这是 Nginx URI 替换规则的核心。

**Q3：`rewrite last` 和 `return 302` 到底怎么选？**
内部路由用 `last`（不产生额外请求，浏览器地址栏不变）；需要让浏览器地址变化（域名迁移、http→https）用 `permanent`/`redirect`。用 `last` 做域名跳转是错的，因为后端还是同一台机器在提供服务。

**Q4：为什么 `try_files` 里的 fallback 会导致 500？**
fallback 是内部跳转，若目标依然不存在会再次进入 `try_files`，累计 10 次触发 `rewrite or internal redirection cycle`。根因通常是 `root` 目录配错或 dist 未上传。

**Q5：`$request_time` 和 `$upstream_response_time` 差别？**
前者从读到客户端第一个字节到响应完成，后者从连接 upstream 到读完 upstream 响应。`request_time - upstream_response_time` 近似为 Nginx 自身开销 + 网络 + 客户端慢（读写慢会显著拉长 `request_time`）。

---

## 十、小结

- location 优先级：**`=` > `^~` > 正则（书写顺序）> 普通前缀（最长）**，普通前缀命中后仍会尝试正则。
- `proxy_pass` 带 URI 就替换 location 前缀，不带就原样透传；正则 location 里更要用捕获组。
- `rewrite last` 重匹配 location，`break` 留在原地；内部跳转上限 10 次，死循环先查文件是否存在。
- `try_files` 是 SPA 与前后端分离的基石，静态资源用 `^~` + 文件名 hash + `immutable` 长缓存。
- 灰度用 `split_clients` + `map` 变量化 `proxy_pass`，靠 **reload 秒级回滚**，而不是重新发布。
- 远离 `if` 里的 `proxy_pass`，把条件判断变成变量求值。
- 排查先看 `$upstream_response_time` 是否为空，一刀切开"网关问题"与"后端问题"。

配置本身不难，难的是**每一条规则背后的匹配时序**。把这套时序记住，Nginx 就不再是"玄学"了。
