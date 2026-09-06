---
title: 【Web 安全进阶】SSRF、越权访问与文件上传漏洞深度解析：Java 服务端安全攻防实战
date: 2026-09-06 08:00:00
tags:
  - Java
  - Web 安全
  - SSRF
  - 越权
  - 文件上传
categories:
  - Java
  - Web 安全
author: 东哥
---

# 【Web 安全进阶】SSRF、越权访问与文件上传漏洞深度解析：Java 服务端安全攻防实战

## 为什么还要聊"老掉牙"的安全漏洞？

XSS、CSRF、SQL 注入大家已经耳熟能详（之前也写过专项），但**越权（IDOR）、SSRF、文件上传**这三类漏洞，才是现在企业安全测试里**出现频率最高、危害往往最大**的。它们不挑语言、不挑框架，纯看业务代码怎么写。很多团队自测"没发现漏洞"，是因为根本没测对地方。

本文从攻击者视角讲清三类漏洞的原理与利用方式，再给出 Java 侧的防御代码，最后附一份安全开发 Checklist。

## 一、SSRF：服务端请求伪造

### 1.1 什么是 SSRF

SSRF（Server-Side Request Forgery）：**攻击者控制服务端发起请求的目标地址**。凡是"服务端替用户去请求某个 URL"的功能，都是 SSRF 的高发区：

- 图片/文章链接预览（抓取 URL 生成缩略图）；
- Webhook 回调配置（用户填一个回调地址）；
- 在线翻译、转码、PDF 生成（要访问远程资源）；
- 代理接口（服务端转发请求）。

Java 里最常见的写法：

```java
@PostMapping("/fetch")
public String fetch(@RequestBody Map<String, String> body) {
    String url = body.get("url");          // 用户传的！
    // 直接拿用户 URL 去请求 —— SSRF
    try (InputStream in = new URL(url).openStream()) {
        return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    } catch (IOException e) {
        return "error";
    }
}
```

### 1.2 攻击者能干什么

1. **探测内网**：传入 `http://192.168.1.1:8080/`、`http://10.0.0.8:3306`，利用响应差异（超时/报错/内容）扫描内网端口和服务；
2. **打云元数据服务**：传 `http://169.254.169.254/latest/meta-data/`（AWS）或 `http://100.100.100.200/latest/meta-data/`（阿里云），**直接拿到云主机的临时 AK/SK**，接管整个云账号——这是近几年云上被利用最多的路径之一；
3. **读本地文件**：若代码用的是支持多协议的库（如旧版 `HttpClient` 配 `file:` 协议，或 `Jsoup.connect` 某些配置），`file:///etc/passwd` 能直接读服务器文件；
4. **打内网 Redis 等**：通过 `gopher://` 协议向内网 Redis 发命令写 crontab 反弹 shell（利用条件苛刻但真实存在）。

### 1.3 防御：层层设卡

```java
public class SsrfGuard {

    private static final Set<String> BLOCKED_IPS = Set.of(
            "127.0.0.1", "0.0.0.0", "::1",
            "169.254.169.254",       // AWS 元数据
            "100.100.100.200",       // 阿里云元数据
            "10.0.0.0", "10.255.255.255",
            "172.16.0.0", "172.31.255.255",
            "192.168.0.0", "192.168.255.255");

    public static String safeFetch(String url) throws Exception {
        // 第 1 层：协议白名单 —— 只允许 http/https
        URI uri = new URI(url);
        if (!"http".equalsIgnoreCase(uri.getScheme())
                && !"https".equalsIgnoreCase(uri.getScheme())) {
            throw new IllegalArgumentException("非法协议: " + uri.getScheme());
        }

        // 第 2 层：域名/IP 白名单或黑名单（公司内部域名放行名单）
        String host = uri.getHost();
        if (!allowList.contains(host)) {
            throw new IllegalArgumentException("域名不在白名单: " + host);
        }

        // 第 3 层：DNS 解析后校验 IP（防 DNS Rebinding）
        InetAddress addr = InetAddress.getByName(host);   // 解析一次
        String ip = addr.getHostAddress();
        if (isInternalIp(ip)) {
            throw new IllegalArgumentException("禁止访问内网地址: " + ip);
        }
        // ⚠️ 关键：真正建连时要"绑定"这个解析后的 IP 再请求（自定义
        //    SSLSocketFactory/连接器），否则连接时会再次 DNS 解析，
        //    攻击者通过 DNS 轮询即可绕过上面的校验。

        // 第 4 层：禁止重定向，或对每个跳转目标重复执行上述校验
        // 第 5 层：只返回必要信息，不要把响应全文透传给用户
        return doHttpRequest(uri, ip);
    }

    private static boolean isInternalIp(String ip) {
        // 把 IP 转成 long 做网段判断；IPv6 同理（::1、fc00::/7 等）
        // 简写示意，生产环境建议用现成库（如 Guava 的 InetAddresses）
        for (String s : BLOCKED_IPS) { /* 区间匹配逻辑 */ }
        return false;
    }
}
```

**SSRF 防御清单（按优先级）**：

1. **协议白名单**（只留 http/https）——先堵 file/gopher/dict；
2. **URL 解析用 `URI` 而不是字符串拼接**，并规范化（防 `http://evil.com@127.0.0.1`、`http://127.0.0.1:80@evil.com` 这类混淆写法）；
3. **域名白名单 > IP 黑名单**：能白名单就别黑名单，黑名单永远有绕过姿势（十进制 IP `http://2130706433/`、IPv6 简写、短链、DNS rebinding、重定向跳内网）；
4. **请求库选型**：用不支持非 HTTP 协议的客户端（如 `HttpClient` 默认），关掉自动重定向；
5. 响应**不完整回显**，超时设短，限制响应大小。

## 二、越权访问：最常见的"高危"

### 2.1 IDOR / 水平越权 / 垂直越权

越权分两类，本质都是**"服务端没有校验资源归属/操作权限"**：

| 类型 | 含义 | 例子 |
|------|------|------|
| 水平越权（IDOR） | 同级别用户访问**别人的**资源 | 登录 A 账号，改 URL 里的订单 id 查 B 的订单 |
| 垂直越权 | 低权限用户执行**高权限**操作 | 普通用户直接调 `/admin/deleteUser` 接口 |

最典型的漏洞代码——只校验"登录了"，不校验"是不是本人的"：

```java
@GetMapping("/order/{id}")
public Order getOrder(@PathVariable Long id) {
    // ❌ 只校验了登录，没校验订单归属
    return orderService.getById(id);
}

// 攻击方式：遍历 id=1,2,3... 或抓包改 id，就能看到所有用户的订单
```

### 2.2 修复：对象级授权（Object-Level Authorization）

```java
@GetMapping("/order/{id}")
public Order getOrder(@PathVariable Long id) {
    // 从 SecurityContext 拿当前登录用户（不要信任前端传的 userId！）
    Long currentUserId = SecurityUtils.getCurrentUserId();

    Order order = orderService.getById(id);
    if (order == null) {
        throw new NotFoundException();
    }
    // ✅ 核心：校验资源归属
    if (!order.getUserId().equals(currentUserId)) {
        throw new ForbiddenException("无权访问该订单");
    }
    return order;
}
```

更优雅的方式是**用框架能力做对象级授权**，避免每个接口手写：

```java
// Spring Security 方法级：SpEL 里比较参数与当前用户
@GetMapping("/order/{id}")
@PreAuthorize("@orderGuard.canAccess(#id)")   // 或 hasPermission(#id, 'Order','read')
public Order getOrder(@PathVariable Long id) { ... }

// 垂直越权：接口级统一注解
@DeleteMapping("/admin/user/{userId}")
@PreAuthorize("hasRole('ADMIN')")
public void deleteUser(@PathVariable Long userId) { ... }
```

**越权防御清单**：

1. **身份永远取自服务端会话**（SecurityContext/Session），绝不信任请求参数里的 userId；
2. 每个"按 id 查/改/删"的接口都要做**归属校验**，不能只测登录；
3. 敏感操作（改密、转账、删数据）必须**二次校验**（原密码/验证码）；
4. 用自动化工具扫 IDOR：登录两个账号互相访问对方资源；
5. 接口层做好**统一鉴权注解 + 默认拒绝**（白名单放行，而不是默认放行）；
6. 列表接口注意分页越权：`/my/orders?page=2` 也要按当前用户过滤，别只过滤第一页。

## 三、文件上传漏洞：从上传到 RCE

### 3.1 攻击路径

文件上传本身不是漏洞，**"上传的文件能被当脚本执行"**才是。攻击链：

```
上传 jsp/php webshell -> 访问上传的 URL -> 服务器执行恶意代码 -> RCE（远程命令执行）
```

常见绕过姿势（针对防御不严的系统）：

- 只校验了前端（可抓包改请求）或 Content-Type（`image/jpeg` 随手改）；
- 黑名单后缀：`.jsp` 被拦，就试 `.jspx`、`.JSP`、`.jsp%00.png`（老版本截断）、`.jsp.`（Windows 去尾点）、`shell.jpg.jsp`；
- 图片马：在合法图片尾部拼接脚本代码（配合文件包含漏洞利用）；
- 上传 `.htaccess`/`web.xml` 改写服务器配置（老 Apache 场景）。

### 3.2 Java 侧修复：白名单 + 重命名 + 存储执行分离

```java
public String upload(MultipartFile file) {
    // 1. 白名单后缀（黑名单永远拦不全）
    String original = file.getOriginalFilename();
    String ext = StringUtils.getFilenameExtension(original).toLowerCase();
    if (!Set.of("jpg", "jpeg", "png", "gif", "webp", "pdf").contains(ext)) {
        throw new BizException("不支持的文件类型: " + ext);
    }

    // 2. 校验 Content-Type 与文件魔数（文件头字节）双保险
    String contentType = file.getContentType();   // 不可信，仅参考
    if (!contentType.startsWith("image/")) {
        throw new BizException("非图片文件");
    }
    // 魔数校验：读取前几个字节，JPEG=FFD8FF, PNG=89504E47, GIF=47494638
    byte[] header = new byte[4];
    file.getInputStream().read(header);
    if (!isValidImageMagic(header, ext)) {
        throw new BizException("文件内容与后缀不匹配");
    }

    // 3. 服务端随机重命名（UUID），绝不使用用户原始文件名
    String newName = UUID.randomUUID().toString().replace("-", "") + "." + ext;

    // 4. 存储与执行分离：上传到对象存储（OSS/MinIO）或独立静态域名，
    //    Web 容器所在目录禁止任何脚本执行；图片类可再做压缩/转码（顺带杀马）
    ossClient.putObject("avatar-bucket", newName, file.getInputStream());
    return "https://cdn.example.com/avatar/" + newName;   // 返回 CDN 域名
}
```

**文件上传防御清单**：

1. **后缀白名单 + 随机重命名**（用户文件名一律丢弃）；
2. 校验**魔数**（文件头），别只信 Content-Type；
3. **存储与执行分离**：上传目录与 Web 执行目录隔离，或直接上对象存储 + 独立域名；同域名下务必配置该路径不可执行脚本；
4. 限制文件大小、限制上传频率（防拖垮磁盘）；
5. 图片类上传后**重新压缩/转码**（丢弃多余字节，天然"消毒"）；
6. 下载接口防目录穿越：`../` 拼接路径要规范化校验，禁止任意文件下载（`/download?file=/etc/passwd`）。

## 四、容易被忽视的：安全响应头

很多团队以为"没漏洞就安全"，其实浏览器侧还有一层免费防线没利用——**安全响应头**。Spring Security 默认帮你加了一部分，但自定义或非 Security 项目常被忽略：

| 响应头 | 作用 | 推荐值 |
|--------|------|--------|
| `X-Frame-Options` | 防点击劫持（页面被 iframe 嵌入） | `DENY` 或 `SAMEORIGIN` |
| `X-Content-Type-Options` | 禁止浏览器 MIME 嗅探（防"文本伪装成 JS"） | `nosniff` |
| `Strict-Transport-Security` | 强制 HTTPS（防降级攻击） | `max-age=31536000; includeSubDomains` |
| `Content-Security-Policy` | CSP：白名单页面可加载的资源 | 按业务收紧 `default-src 'self'` |
| `Referrer-Policy` | 控制 Referer 泄露 | `strict-origin-when-cross-origin` |

Spring Security 中配置：

```java
http.headers(headers -> headers
        .frameOptions(f -> f.deny())
        .contentSecurityPolicy(csp -> csp.policyDirectives(
                "default-src 'self'; img-src 'self' data:; script-src 'self'")));
```

非 Security 项目写一个 `OncePerRequestFilter` 加头即可，三分钟的事，别省。

## 五、安全开发 Checklist（贴墙版）

**接口层**：
- [ ] 所有接口默认拒绝，白名单放行；登录态从服务端取；
- [ ] 按 id 操作资源必须校验归属（水平越权）；敏感操作校验角色（垂直越权）；
- [ ] 上传：后缀白名单 + 魔数校验 + 随机命名 + 存储执行分离；
- [ ] 下载：路径规范化，禁止任意文件读取。

**服务端请求**：
- [ ] 任何"服务端发起的请求"都要协议白名单 + 域名白名单 + 内网 IP 拦截 + 禁重定向；
- [ ] 禁止访问云元数据地址（169.254.169.254 / 100.100.100.200）。

**响应侧**：
- [ ] 安全响应头齐全（X-Frame-Options / nosniff / HSTS / CSP）；
- [ ] 敏感字段脱敏返回（手机号、身份证），日志不打印密码/token；
- [ ] 错误信息不泄露堆栈与 SQL。

**上线前**：
- [ ] 用两个账号互访做 IDOR 自测；
- [ ] 上传功能用 BurpSuite 改包测绕过；
- [ ] 依赖漏洞扫描（OWASP Dependency-Check 等），高危组件及时升级。

## 六、面试追问速答

**Q：SSRF 的 IP 黑名单有哪些常见绕过？**
DNS Rebinding（第一次解析放行、建连时解析到内网）、重定向跳转内网、IPv6 映射（`::ffff:127.0.0.1`）、进制混淆 IP（`2130706433` = 127.0.0.1）、短链跳转、`@` 符号 URL 解析歧义。所以**白名单 + 解析后绑定 IP 建连**才是正解。

**Q：IDOR 和垂直越权怎么区分？怎么测？**
IDOR 是"横向"：两个同级账号互访资源（改资源 id）；垂直越权是"纵向"：低权限账号访问高权限接口。测试方法：低权限账号直接请求高权限接口看是否 403，两个平级账号交换资源 id 看是否泄露。

**Q：为什么文件上传要"存储与执行分离"？**
上传校验再严也有绕过可能，**纵深防御**：就算 webshell 传上去了，只要它不在可执行脚本的目录/域名下（或该路径禁了脚本执行），就只是一堆死字节，无法 RCE。安全设计要假设"校验会被绕过"。

**Q：安全测试应该什么时候做？**
不是上线前突击，而是**需求评审（威胁建模）-> 开发自测（checklist）-> Code Review（重点看鉴权/上传/外呼）-> 上线前渗透测试**全流程。越权、SSRF 这类逻辑漏洞，越早发现修复成本越低。
