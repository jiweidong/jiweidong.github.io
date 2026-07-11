---
title: 【微服务实战】Spring Session 分布式会话管理与集群 Session 共享
date: 2026-07-11 08:00:00
tags:
  - Spring
  - Spring Session
  - 分布式
  - Session
categories:
  - Java
  - Spring
author: 东哥
---

# 【微服务实战】Spring Session 分布式会话管理与集群 Session 共享

## 前言

单体应用时代，用户登录信息直接存在 `HttpSession` 里，基于 Tomcat 的内存存储，简单好用。

到了微服务时代，问题来了：用户的请求经过网关负载均衡到不同服务实例——你登录时命中了实例 A，session 存在 A 的内存里；下一个请求路由到了实例 B，B 的内存里没有你的 session，**你就被要求重新登录了**。

这就是经典的「分布式 Session 一致性问题」。Spring Session 正是为了解决这个问题而生。

<!-- more -->

---

## 一、分布式 Session 的三种主流方案

在介绍 Spring Session 之前，先看看业界解决分布式 Session 的几种方案：

| 方案 | 原理 | 优缺点 |
|------|------|--------|
| **Session 黏滞（Sticky Session）** | 负载均衡按 sessionId 哈希路由到同一实例 | 简单但单点故障不可用 |
| **Session 复制** | Tomcat 实例之间广播复制 Session | 网络开销大，有延迟 |
| **集中式 Session 存储** | Session 统一存 Redis/数据库 | 推荐方案，Spring Session 就是这个思路 |

**集中式 Session 存储**是当前最主流的方案。用户会话信息统一存储在 Redis 中，所有应用实例从同一个 Redis 读取会话数据。即使请求被路由到不同的实例，也能获取到相同的会话内容。

---

## 二、Spring Session 核心原理

### 2.1 架构设计

Spring Session 的核心思路是：**用一个外部的存储（Redis、JDBC、MongoDB 等）替换掉 Tomcat 原生的 HttpSession 实现**。

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  客户端      │────▶│  Nginx/网关   │────▶│  应用实例 A   │
└─────────────┘     └──────────────┘     └──────┬───────┘
                                                │
                                         ┌──────▼───────┐
                                         │    Redis     │
                                         │  (Session)   │
                                         └──────▲───────┘
                                                │
┌─────────────┐     ┌──────────────┐     ┌──────┴───────┐
│  客户端      │────▶│  Nginx/网关   │────▶│  应用实例 B   │
└─────────────┘     └──────────────┘     └──────────────┘
```

### 2.2 工作原理

Spring Session 通过以下几个核心组件实现 HttpSession 的替换：

1. **SessionRepositoryFilter**：Servlet 容器中的 Filter，拦截所有请求，将 `HttpServletRequest` 包装为 `SessionRepositoryRequestWrapper`
2. **SessionRepositoryRequestWrapper**：重写了 `getSession()` 方法，返回 Spring Session 的实现而非原生的 Tomcat HttpSession
3. **SessionRepository**：负责 Session 的 CRUD 操作，Redis 实现为 `RedisIndexedSessionRepository`
4. **Session**：会话数据载体，包含 sessionId、创建时间、最后访问时间、过期时间等元数据以及用户属性

### 2.3 请求处理流程

```text
1. 客户端请求携带 Cookie（JSESSIONID=xxx）
2. SessionRepositoryFilter 拦截请求，包装 Request
3. 应用代码调用 request.getSession() -> 触发 SessionRepositoryRequestWrapper
4. Wrapper 从 Redis 中根据 sessionId 查询 Session
5. 如果查到 -> 返回 Session 对象；查不到 -> 创建新的 Session
6. 请求结束，SessionRepository 将 Session 持久化或更新到 Redis
7. Redis 中 Session 的过期时间自动延长
```

---

## 三、Spring Boot + Redis 集成实战

### 3.1 Maven 依赖

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.session</groupId>
    <artifactId>spring-session-data-redis</artifactId>
</dependency>
```

### 3.2 配置文件

```yaml
spring:
  session:
    store-type: redis           # 指定 Session 存储方式
    timeout: 1800               # Session 过期时间（秒），默认 30 分钟
    redis:
      namespace: myapp:session  # Redis key 前缀，避免多应用冲突
      flush-mode: on-save       # 刷新模式：on-save（默认）/ immediate
  data:
    redis:
      host: 192.168.1.100
      port: 6379
      password: xxx
      timeout: 2000ms
      lettuce:
        pool:
          max-active: 8
          max-idle: 8
          min-idle: 0
```

### 3.3 启用 Spring Session

```java
@SpringBootApplication
// 方式一：使用 @EnableRedisHttpSession 注解（旧版本方式）
// @EnableRedisHttpSession
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
```

在 Spring Boot 2.x/3.x 中，只要引入 `spring-session-data-redis` 依赖并配置 `spring.session.store-type=redis`，Spring Boot 会自动配置好一切，**无需额外注解**。

### 3.4 使用 HttpSession（和以前一样！）

```java
@RestController
@RequestMapping("/user")
public class UserController {

    // 登录：将用户信息存入 Session
    @PostMapping("/login")
    public Result login(@RequestBody LoginRequest request, HttpSession session) {
        User user = userService.login(request.getUsername(), request.getPassword());
        session.setAttribute("currentUser", user);
        return Result.ok("登录成功");
    }

    // 获取当前登录用户
    @GetMapping("/current")
    public Result current(HttpSession session) {
        User user = (User) session.getAttribute("currentUser");
        if (user == null) {
            return Result.fail(401, "未登录");
        }
        return Result.ok(user);
    }

    // 退出登录
    @PostMapping("/logout")
    public Result logout(HttpSession session) {
        session.invalidate();
        return Result.ok("已退出");
    }
}
```

**关键点**：代码完全不用变！`HttpSession` 仍然是那个 `HttpSession`，只是底层实现从 Tomcat 内存切换到了 Redis。

---

## 四、深入配置与自定义

### 4.1 自定义 Cookie 配置

```yaml
spring:
  session:
    cookie:
      name: MY_SESSION_ID     # 自定义 Cookie 名称，默认 SESSION
      path: /                 # Cookie 路径
      domain: .example.com    # 跨子域名共享（如 app1.example.com, app2.example.com）
      http-only: true         # 防止 XSS 窃取 Cookie
      secure: true            # 仅 HTTPS 传输
      same-site: lax          # CSRF 防护
      max-age: 1800           # Cookie 的过期时间（秒）
```

### 4.2 Java Config 方式

```java
@Configuration
public class SessionConfig {

    @Bean
    public CookieSerializer cookieSerializer() {
        DefaultCookieSerializer serializer = new DefaultCookieSerializer();
        serializer.setCookieName("MY_SSO_SESSION");
        serializer.setCookiePath("/");
        serializer.setDomainName("example.com");
        serializer.setUseHttpOnlyCookie(true);
        serializer.setUseSecureCookie(true);
        serializer.setSameSite("Lax");
        return serializer;
    }

    @Bean
    public RedisSerializer<Object> springSessionDefaultRedisSerializer() {
        // 使用 Jackson 序列化 Session 中的对象
        return new GenericJackson2JsonRedisSerializer();
    }
}
```

### 4.3 自定义 Session 过期策略

```java
@Configuration
public class SessionExpiryConfig {

    @Bean
    public FindByIndexNameSessionRepository<?> sessionRepository(
            RedisIndexedSessionRepository sessionRepository) {
        // 设置 Session 过期后的监听器
        sessionRepository.setDefaultMaxInactiveInterval(1800);
        return sessionRepository;
    }
}
```

---

## 五、Spring Session 的 Redis 数据结构

Spring Session 在 Redis 中的存储结构值得了解一下，便于排查问题：

```
// 创建 Session 后，Redis 中会出现以下 key 和对应的 TTL：

// 1. Session 本体（数据结构为 Hash）
myapp:session:sessions:{sessionId}
  - creationTime       -> 创建时间戳
  - lastAccessedTime   -> 最后访问时间戳
  - maxInactiveInterval -> 最大不活动间隔（秒）
  - sessionAttr:currentUser -> 用户对象的序列化数据

// 2. 过期相关 key（用于自动过期通知）
myapp:session:expirations:{expirationTime}
  - 存储即将在某个时间点到期的 sessionId 集合

// 3. 针对特定索引的 key（如果使用了 FindByIndexNameSessionRepository）
myapp:session:index:org.springframework.session.FindByIndexNameSessionRepository.PRINCIPAL_NAME_INDEX_NAME:{username}
  - 存储 {sessionId} -> "" 的映射
```

> 当 Session 过期时，Redis 的 keyspace notification 会触发 Spring Session 的过期监听器，清理相关的索引数据。

---

## 六、Spring Session + Spring Security 集成

实际项目中，Session 通常和认证授权密切相关。Spring Session 与 Spring Security 的集成开箱即用：

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/login", "/register").permitAll()
                .anyRequest().authenticated()
            )
            .formLogin(form -> form
                .loginProcessingUrl("/login")
                .defaultSuccessUrl("/dashboard", true)
            )
            // 会话管理
            .sessionManagement(session -> session
                .maximumSessions(1)                    // 同一用户最多同时在线 1 个会话
                .maxSessionsPreventsLogin(false)       // 超过限制时踢掉旧会话
                .expiredUrl("/login?expired")          // 会话过期后的跳转地址
            )
            .logout(logout -> logout
                .logoutUrl("/logout")
                .deleteCookies("MY_SESSION_ID")
                .invalidateHttpSession(true)
            );
        return http.build();
    }

    // 获取当前 session 中所有活跃会话（踢人功能）
    @Bean
    public HttpSessionEventPublisher httpSessionEventPublisher() {
        return new HttpSessionEventPublisher();
    }
}
```

---

## 七、多应用共享 Session 实战

### 7.1 子域名共享

假如你有多个子系统：`admin.example.com`、`shop.example.com`、`blog.example.com`，希望用户登录一个系统后，访问其他系统也保持登录状态。

```java
// 统一 Cookie 域
@Bean
public CookieSerializer cookieSerializer() {
    DefaultCookieSerializer serializer = new DefaultCookieSerializer();
    serializer.setCookieName("GLOBAL_SESSION");
    serializer.setCookiePath("/");
    serializer.setDomainName("example.com");  // 统一父域
    return serializer;
}
```

> ⚠️ Cookie 的 Domain 不能跨二级域名（如 `app1.example.com` 和 `app2.example.com`），只能设置到共同的父域 `example.com`。跨顶级域名（如 `example.com` 和 `example.cn`）无法共享 Cookie。

### 7.2 不同应用间启用/禁用 Session 共享

```yaml
# 应用 A（类似 Auth 服务）
spring:
  session:
    store-type: redis
    redis:
      namespace: shared:session

# 应用 B（不需要 Session，适合纯 API 服务）
spring:
  session:
    store-type: none  # 不启用 Session
```

---

## 八、会话监控与管理

### 8.1 获取当前所有在线用户

```java
@Service
public class SessionManagementService {

    @Autowired
    private FindByIndexNameSessionRepository<? extends Session> sessionRepository;

    /**
     * 根据用户名查询所有活跃 Session
     */
    public Map<String, ? extends Session> findSessionsByUsername(String username) {
        return sessionRepository.findByPrincipalName(username);
    }

    /**
     * 强制下线指定 Session
     */
    public void expireSession(String sessionId) {
        Session session = sessionRepository.findById(sessionId);
        if (session != null) {
            session.setMaxInactiveInterval(Duration.ZERO);  // 立即过期
            sessionRepository.save(session);
        }
    }

    /**
     * 强制所有用户下线（如系统升级）
     */
    public void expireAllSessions() {
        // 需要 Redis 的 keys 操作或使用 SCAN
    }
}
```

### 8.2 Session 事件监听

```java
@Component
public class SessionEventListener {

    @EventListener
    public void handleSessionCreated(SessionCreatedEvent event) {
        String sessionId = event.getSessionId();
        log.info("Session 创建: {}", sessionId);
    }

    @EventListener
    public void handleSessionExpired(SessionExpiredEvent event) {
        String sessionId = event.getSessionId();
        log.info("Session 过期: {}", sessionId);
    }

    @EventListener
    public void handleSessionDestroyed(SessionDestroyedEvent event) {
        String sessionId = event.getSessionId();
        log.info("Session 销毁: {}", sessionId);
        // 可以在这里做清理工作：如清除用户的分布式锁、释放资源等
    }
}
```

---

## 九、性能优化与常见问题

### 9.1 性能优化

| 优化项 | 说明 |
|-------|------|
| **最小化 Session 数据** | 只存 userId 等关键标识，用户详情从业务 DB 查询 |
| **配置合理的过期时间** | 不要太长（安全风险），不要太短（频繁重建） |
| **使用连接池** | Redis 连接池配置 max-active 建议 8-16 |
| **启用序列化压缩** | 大数据量时使用 Kryo 或压缩 Jackson |
| **减少 Session 写操作** | 只在登录/更新关键信息时写入 |

### 9.2 常见问题

**问题1：Session 数据丢失**

```text
原因排查：
1. Redis 内存达到 maxmemory -> 触发了淘汰策略 -> Session 被 LRU 移除
   解决：合理设置 Redis maxmemory，避免使用 volatile-lru 淘汰包含 session 的 key
   
2. Session 序列化问题
   解决：Session 中存储的对象必须实现 Serializable，或使用 Jackson 序列化

3. Cookie 域名/路径配置错误
   解决：检查 Cookie 的 domain 和 path 是否匹配前端请求地址
```

**问题2：高并发下 Redis 连接耗尽**

```text
现象：登录后页面频繁 500，日志显示 redis.clients.jedis.exceptions.JedisConnectionException

分析：每个请求都要操作 Redis（读取 Session），高并发下连接池被打满

优化方案：
1. 增大连接池 max-active（但不要超过 Redis maxclients）
2. 使用本地缓存缓存 Session（注意一致性）
3. 如果是查询操作，使用 Redis 只读副本
```

---

## 十、面试常见追问

**Q1：Spring Session 如何保证与原生 HttpSession 的 API 兼容？**

A：通过 `SessionRepositoryFilter` 将 `HttpServletRequest` 包装为 `SessionRepositoryRequestWrapper`。这个 Wrapper 重写了 `getSession()` 和 `getSession(boolean)` 方法，返回的是 `ExpiringSession` 对象，而非原生的 `StandardSession`。对于应用层代码来说，调用的仍然是 `HttpSession` 接口的方法，完全透明。

**Q2：Spring Session + Redis 方案有什么缺陷？**

A：主要有三点：① **网络开销**——每次请求都要访问 Redis，比本地内存慢 1-5ms；② **Redis 故障影响面大**——Redis 挂了所有服务都无法获取 Session；③ **Session 数据膨胀**——Redis 内存被 Session 占满的风险。

**Q3：无状态 Token（JWT）和 Session 怎么选？**

A：JWT 适合 API 鉴权、微服务间调用，不需要服务端存储；Spring Session 适合传统 Web 应用，有服务端 Session 管理需求（如踢人、Session 事件监听）。一般混合使用：客户端认证用 JWT，服务端保留 Session 做会话管理。

---

## 总结

Spring Session 是解决分布式 Session 一致性问题的最优雅方案，它通过 Filter 机制在**不改动业务代码**的前提下，将 Session 的存储从内存迁移到外部存储（通常是 Redis）。

核心要点：
- **引入依赖 + 配置文件**两步走，改造成本极低
- **开发者无感知**，`HttpSession` 的 API 使用方式完全不变
- **支持多存储后端**：Redis、JDBC、MongoDB、Hazelcast 等
- **与 Spring Security 深度集成**，提供会话管理、踢人、并发控制等高级功能
- **注意性能优化**：最小化 Session 数据、合理过期、Redis 高可用
