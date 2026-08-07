---
title: 【Web 性能】HTTP 缓存机制深度解析：强缓存、协商缓存与 Java/Spring 实战
date: 2026-08-07 08:00:00
tags:
  - HTTP
  - 缓存
  - Spring
  - 性能优化
categories:
  - Java
  - Web 开发
author: 东哥
---

# 【Web 性能】HTTP 缓存机制深度解析：强缓存、协商缓存与 Java/Spring 实战

## 面试官：讲讲 HTTP 缓存的强缓存和协商缓存？浏览器缓存是怎么工作的？

HTTP 缓存是 Web 性能优化的**第一板斧**——一个静态资源（JS/CSS/图片）如果命中缓存，可以省掉 99% 的重复传输。但很多后端同学只听说过"强缓存""协商缓存"两个名词，说不清 `Cache-Control` 和 `ETag` 的配合逻辑。这篇文章一次讲透。

## 一、整体架构：浏览器缓存的两级模型

```
第一次请求：GET /app.js
  服务器响应：200 OK + 资源内容 + 缓存头（Cache-Control、ETag、Last-Modified）

第二次请求：
  ├── 命中【强缓存】：直接用本地缓存，不发请求！(200 from disk cache)
  └── 未命中强缓存 → 发请求【协商缓存】：
        ├── 服务器验证资源没变 → 304 Not Modified（无 body，省流量）
        └── 服务器验证资源变了 → 200 + 新资源
```

**核心区别**：

| 维度 | 强缓存 | 协商缓存 |
|------|--------|----------|
| 是否发请求 | **不发**，直接用本地 | 发请求，服务器判断 |
| 状态码 | 200 (from memory/disk cache) | 304 Not Modified |
| 性能收益 | 最高（零网络开销） | 中等（省 body，省一次完整传输） |
| 控制头 | `Cache-Control` / `Expires` | `ETag/If-None-Match`、`Last-Modified/If-Modified-Since` |

## 二、强缓存：Cache-Control 详解

### 优先级：Cache-Control > Expires

`Expires`（HTTP/1.0）是**绝对时间**，依赖客户端时钟，改系统时间就失效；`Cache-Control`（HTTP/1.1）是**相对时间**，优先使用。

```http
# 响应头
Cache-Control: max-age=3600          # 缓存 1 小时
Cache-Control: no-cache              # 每次都要去服务器验证（协商），但可以本地存
Cache-Control: no-store              # 完全不缓存（敏感数据）
Cache-Control: public                # 任何节点（含 CDN）都可缓存
Cache-Control: private               # 只有客户端能缓存，代理/CDN 不能
Cache-Control: must-revalidate       # 过期后必须回源验证
```

### 常见组合

| 场景 | 配置 |
|------|------|
| 静态资源（指纹命名） | `Cache-Control: public, max-age=31536000, immutable`（缓存一年，因为文件名带 hash，内容变了文件名就变） |
| HTML 页面 | `Cache-Control: no-cache`（每次协商验证，保证最新） |
| 登录态/订单接口 | `Cache-Control: no-store`（绝不缓存） |

**immutable** 告诉浏览器：这个资源**永不变化**，过期时间内连"重新验证"都不用想（Chrome 支持）。

## 三、协商缓存：ETag 与 Last-Modified

当强缓存失效（或 no-cache）时，浏览器带上"验证凭证"问服务器：资源变了吗？

### 方案一：Last-Modified / If-Modified-Since（HTTP/1.0）

```
第一次响应：Last-Modified: Wed, 07 Aug 2026 08:00:00 GMT
第二次请求：If-Modified-Since: Wed, 07 Aug 2026 08:00:00 GMT
服务器：比较文件最后修改时间
  ├── 没变 → 304
  └── 变了 → 200 + 新内容
```

**缺点**：
1. 精度到秒，秒内修改检测不到
2. 修改时间变了但内容没变（如 touch 一下），也会误判为变化
3. 某些场景（CDN 分发）时间不可靠

### 方案二：ETag / If-None-Match（HTTP/1.1，优先）

```
第一次响应：ETag: "33a64df5-1234"   # 内容的指纹（hash 或版本号）
第二次请求：If-None-Match: "33a64df5-1234"
服务器：比较指纹
  ├── 相同 → 304（响应头带上新的 ETag）
  └── 不同 → 200 + 新内容
```

**优先级：If-None-Match > If-Modified-Since**，同时发送时服务器只认 ETag。

ETag 又分强/弱两种：
- 强 ETag：`"abc123"`——内容字节级相同才匹配
- 弱 ETag：`W/"abc123"`——语义相同即可匹配（如编码不同但内容等价）

## 四、缓存决策完整流程（浏览器视角）

```
发起请求
  ├─ 有缓存？
  │   ├─ 否 → 直接发请求 → 200
  │   └─ 是 → 检查 Cache-Control/Expires
  │         ├─ 未过期（强缓存命中）→ 直接用本地缓存，零请求 ✅
  │         └─ 已过期 / no-cache → 走协商缓存
  │               ├─ 带 If-None-Match（ETag）
  │               ├─ 带 If-Modified-Since（Last-Modified）
  │               └─ 服务器响应
  │                     ├─ 304 → 用本地缓存，更新缓存头 ✅（省流量）
  │                     └─ 200 → 用新资源，更新缓存 ✅
```

## 五、Java/Spring 后端怎么设置缓存头

### 方案一：Spring Boot 静态资源缓存配置

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Override
    public void addResourceHandlers(ResourceHandlerRegistry registry) {
        registry.addResourceHandler("/static/**")
                .addResourceLocations("classpath:/static/")
                .setCacheControl(CacheControl.maxAge(365, TimeUnit.DAYS)
                        .cachePublic()
                        .immutable());  // 指纹命名资源的黄金组合
    }
}
```

### 方案二：响应头直接设置

```java
@GetMapping("/resource")
public ResponseEntity<byte[]> getResource() {
    return ResponseEntity.ok()
            .cacheControl(CacheControl.maxAge(3600, TimeUnit.SECONDS).cachePublic())
            .body(data);
}
```

### 方案三：ETag 支持（Spring 内置）

```java
@GetMapping("/data")
public ResponseEntity<String> getData(WebRequest request) {
    String data = queryData();
    String etag = DigestUtils.md5DigestAsHex(data.getBytes());
    // Spring 自动处理 If-None-Match 比较，匹配则返回 304
    if (request.checkNotModified(etag)) {
        return null;  // Spring 帮你返回 304 + 空 body
    }
    return ResponseEntity.ok().eTag(etag).body(data);
}
```

**注意**：Spring MVC 的 `@ResponseBody` 默认不加缓存头；想要 304 要用 `WebRequest.checkNotModified()` 或返回 `ResponseEntity`。

### 方案四：过滤器统一处理（Nginx 也可代劳）

生产环境更常见的是 **Nginx 层直接配**：

```nginx
location /static/ {
    expires 365d;                    # 等价 Cache-Control: max-age=31536000
    add_header Cache-Control "public, immutable";
}

location /api/ {
    add_header Cache-Control "no-store";   # 接口层默认不缓存
}
```

## 六、常见坑与最佳实践

| 坑 | 说明 | 解决 |
|----|------|------|
| 更新了资源用户还是旧版 | 文件名没变 + 强缓存没过期 | 文件名带 **内容 hash**（webpack 输出 `app.a1b2c3.js`） |
| HTML 被强缓存 | 页面内容更新用户看不到 | HTML 用 `no-cache`，只有静态资源长缓存 |
| 登录接口被缓存 | 下一个用户拿到上一个用户的响应 | 敏感接口一律 `no-store` |
| CDN 缓存了私有数据 | `public` 配错了 | 区分 `public`/`private` |
| 时间戳校验失效 | 秒级精度、内容没变时间变了 | 优先用 ETag |

**核心思想**：缓存策略要按资源类型分级——

```
HTML       → no-cache（每次协商）
JS/CSS/IMG → max-age=一年 + immutable（指纹命名）
API 数据   → 默认 no-store，幂等查询类可短缓存（max-age=几秒~几分钟）
```

## 七、面试速答

1. **强缓存和协商缓存区别？** 强缓存不发请求直接用本地，协商缓存发请求由服务器判定 304/200。
2. **Cache-Control 和 Expires？** Cache-Control 是 HTTP/1.1 相对时间，优先级更高；Expires 是绝对时间已基本废弃。
3. **ETag 和 Last-Modified？** ETag 是内容指纹更精确，If-None-Match 优先于 If-Modified-Since。
4. **304 和 200 区别？** 都算"服务器响应了请求"，但 304 无 body，用本地缓存，省带宽；200 传输完整资源。
5. **为什么静态资源要指纹命名 + 长缓存？** 内容变 → 文件名变 → URL 变 → 必然是新请求；文件名不变的资源永远命中缓存，性能最优。

HTTP 缓存是性价比最高的性能优化手段之一，理解它不仅能答好面试，更能让你的系统"快人一步"。
