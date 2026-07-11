---
title: 【Java实战】Sa-Token 轻量级 Java 权限认证框架：从入门到微服务集成
date: 2026-07-11 08:00:00
tags:
  - Java
  - Sa-Token
  - 权限认证
  - 鉴权
categories:
  - Java
author: 东哥
---

# 【Java实战】Sa-Token 轻量级 Java 权限认证框架：从入门到微服务集成

## 前言

说到 Java 权限认证，大多数人会想到 Spring Security。但 Spring Security 的学习曲线陡峭，配置繁琐，一个小项目引入它就像用牛刀杀鸡。

**Sa-Token** 是一个轻量级的 Java 权限认证框架，官网定位为「这可能是史上功能最全的 Java 权限认证框架」。对比 Spring Security，它的 API 更简洁、配置更少、学习成本极低，同时功能覆盖登录认证、权限认证、OAuth2.0、单点登录（SSO）、踢人下线、Redis 集成等几乎所有权限场景。

<!-- more -->

---

## 一、Sa-Token 概览

### 1.1 核心特性

| 特性 | Sa-Token | Spring Security |
|------|----------|----------------|
| API 简洁度 | ⭐⭐⭐⭐⭐ 一行代码搞定 | ⭐⭐ 配置多、概念多 |
| 学习成本 | 30 分钟上手 | 2-3 周入门 |
| 登录认证 | `StpUtil.login(id)` | 需要配置 UserDetailsService |
| 权限校验 | `@SaCheckPermission("user:add")` | `@PreAuthorize("hasAuthority(...)")` |
| Redis 集成 | 一行配置 | 需额外配置 |
| SSR/前后端分离 | 都支持 | 都支持 |
| OAuth2.0 / SSO | 内置支持 | 需额外配置 |

### 1.2 引入依赖

```xml
<dependency>
    <groupId>cn.dev33</groupId>
    <artifactId>sa-token-spring-boot3-starter</artifactId>
    <version>1.39.0</version>
</dependency>
```

对于 Spring Boot 2.x：

```xml
<dependency>
    <groupId>cn.dev33</groupId>
    <artifactId>sa-token-spring-boot-starter</artifactId>
    <version>1.39.0</version>
</dependency>
```

### 1.3 配置文件

```yaml
# application.yml
sa-token:
  # token 名称（同时也是 cookie 名称）
  token-name: satoken
  # token 有效期（秒），30天，-1 代表永不过期
  timeout: 2592000
  # token 最低活跃频率（秒），如果 1800 秒内无操作则过期
  active-timeout: 1800
  # 是否允许同一账号多地同时登录（true 允许多端在线，false 新登录挤掉旧登录）
  is-concurrent: true
  # 在多人登录同一账号时，是否共用一个 token（false 为每个登录分配不同 token）
  is-share: false
  # token 风格（uuid / simple-uuid / random-32 / random-64 / random-128 / tik）
  token-style: uuid
  # 是否输出操作日志
  is-log: true
```

---

## 二、登录认证：一行代码搞定

### 2.1 基本登录

```java
@RestController
@RequestMapping("/auth")
public class AuthController {

    @PostMapping("/login")
    public Result login(@RequestBody LoginRequest request) {
        // 1. 校验用户名密码
        User user = userService.findByUsername(request.getUsername());
        if (user == null || !user.getPassword().equals(request.getPassword())) {
            return Result.fail("用户名或密码错误");
        }

        // 2. 登录！就这么一行
        StpUtil.login(user.getId());

        // 3. 获取 token 信息
        String token = StpUtil.getTokenInfo().getTokenValue();
        return Result.ok(token);
    }

    @GetMapping("/isLogin")
    public Result isLogin() {
        // 判断是否登录
        boolean isLogin = StpUtil.isLogin();
        return Result.ok(isLogin);
    }

    @GetMapping("/logout")
    public Result logout() {
        // 退出登录
        StpUtil.logout();
        return Result.ok("已退出");
    }
}
```

### 2.2 登录拦截器

```java
@Configuration
public class SaTokenConfig implements WebMvcConfigurer {

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        // 注册 Sa-Token 的路由拦截器
        registry.addInterceptor(new SaInterceptor(handle -> {
            // 拦截所有请求，必须登录后才能访问
            SaRouter.match("/**")
                .notMatch("/auth/login", "/auth/register")  // 排除登录注册接口
                .check(r -> StpUtil.checkLogin());          // 校验是否登录
        })).addPathPatterns("/**");
    }
}
```

### 2.3 登录校验异常处理

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(NotLoginException.class)
    public Result handleNotLogin(NotLoginException e) {
        return Result.fail(401, "未登录，请先登录");
    }

    @ExceptionHandler(NotPermissionException.class)
    public Result handleNotPermission(NotPermissionException e) {
        return Result.fail(403, "无权限：" + e.getPermission());
    }

    @ExceptionHandler(NotRoleException.class)
    public Result handleNotRole(NotRoleException e) {
        return Result.fail(403, "无角色：" + e.getRole());
    }
}
```

---

## 三、权限认证：细粒度的访问控制

### 3.1 定义权限与角色

```java
@Service
public class StpInterfaceImpl implements StpInterface {

    @Override
    public List<String> getPermissionList(Object loginId, String loginType) {
        // 根据用户 ID 查询该用户拥有的权限列表
        User user = userService.findById(Long.valueOf(loginId.toString()));
        if (user == null) return Collections.emptyList();
        return user.getRoles().stream()
            .flatMap(role -> role.getPermissions().stream())
            .map(Permission::getCode)
            .collect(Collectors.toList());
    }

    @Override
    public List<String> getRoleList(Object loginId, String loginType) {
        // 根据用户 ID 查询该用户拥有的角色列表
        User user = userService.findById(Long.valueOf(loginId.toString()));
        if (user == null) return Collections.emptyList();
        return user.getRoles().stream()
            .map(Role::getCode)
            .collect(Collectors.toList());
    }
}
```

### 3.2 基于注解的权限校验

```java
@RestController
@RequestMapping("/user")
public class UserController {

    @GetMapping("/list")
    @SaCheckPermission("user:list")     // 需要 user:list 权限
    public Result list() {
        return Result.ok(userService.list());
    }

    @PostMapping("/add")
    @SaCheckPermission("user:add")       // 需要 user:add 权限
    public Result add(@RequestBody User user) {
        userService.save(user);
        return Result.ok("添加成功");
    }

    @PutMapping("/update")
    @SaCheckPermissionOr("user:update:own")  // 拥有任一权限即可
    public Result update(@RequestBody User user) {
        userService.updateById(user);
        return Result.ok("更新成功");
    }

    @DeleteMapping("/delete")
    @SaCheckRole("admin")                 // 需要 admin 角色
    public Result delete(Long id) {
        userService.removeById(id);
        return Result.ok("删除成功");
    }
}
```

支持的注解：

| 注解 | 说明 |
|------|------|
| `@SaCheckLogin` | 登录校验 |
| `@SaCheckRole("admin")` | 角色校验（同时满足） |
| `@SaCheckRoleOr("admin", "super")` | 角色校验（满足一个即可） |
| `@SaCheckPermission("user:add")` | 权限校验（同时满足） |
| `@SaCheckPermissionOr("user:add", "user:edit")` | 权限校验（满足一个即可） |
| `@SaCheckSafe` | 二级认证校验 |
| `@SaCheckDisable("comment")` | 账号被封禁校验 |

### 3.3 编程式权限校验

```java
// 权限校验
StpUtil.checkPermission("user:add");
StpUtil.checkPermissionAnd("user:add", "user:edit");
StpUtil.checkPermissionOr("user:add", "user:delete");

// 角色校验
StpUtil.checkRole("admin");
StpUtil.checkRoleAnd("admin", "super-admin");
StpUtil.checkRoleOr("admin", "super-admin");

// 批量校验
StpUtil.checkByAnnotation(new SaCheckPermission(value = {"user:add", "user:edit"}, mode = SaMode.AND));
```

---

## 四、Token 管理

### 4.1 获取当前 Token 信息

```java
// 获取当前 token 值
String tokenValue = StpUtil.getTokenValue();

// 获取当前登录的账号 id
Object loginId = StpUtil.getLoginId();
long loginIdAsLong = StpUtil.getLoginIdAsLong();

// 获取当前 token 的 Session
SaSession session = StpUtil.getSession();
session.setAttribute("key", "value");
String value = (String) session.getAttribute("key");

// 获取 Token 信息对象
SaTokenInfo tokenInfo = StpUtil.getTokenInfo();
// tokenInfo.getTokenName()     -> "satoken"
// tokenInfo.getTokenValue()    -> "xxx-xxx-xxx"
// tokenInfo.getLoginId()       -> "10001"
// tokenInfo.getLoginType()     -> "login"
// tokenInfo.getTokenTimeout()  -> 2592000
// tokenInfo.getSessionTimeout()-> 1800
// tokenInfo.getTokenSessionTimeout() -> ...
```

### 4.2 Token-Session 与 Custom-Session

Sa-Token 中有两种 Session：

| 类型 | 作用域 | 使用场景 |
|------|--------|---------|
| `StpUtil.getSession()` | 账号纬度 | 用户级别共享数据（购物车、权限缓存） |
| `StpUtil.getTokenSession()` | Token 纬度 | 一次登录会话的数据（OAuth2 的 code_challenge 等） |

```java
// 账号 Session —— 该账号所有 token 共享
SaSession userSession = StpUtil.getSession();
userSession.setAttribute("cart", cartList);

// Token Session —— 仅当前 token 可见
SaSession tokenSession = StpUtil.getTokenSession();
tokenSession.setAttribute("loginDevice", "iPhone");
```

---

## 五、踢人下线与会话管理

### 5.1 强制下线

```java
@RestController
@RequestMapping("/admin")
public class AdminController {

    // 管理员踢人下线
    @PostMapping("/kickout")
    @SaCheckRole("admin")
    public Result kickout(Long userId) {
        // 方式一：踢掉该用户所有登录
        StpUtil.kickout(userId);

        // 方式二：踢掉该用户的某个 token
        // StpUtil.kickoutByTokenValue(tokenValue);

        return Result.ok("已强制下线");
    }

    // 账号封禁
    @PostMapping("/disable")
    @SaCheckRole("super-admin")
    public Result disable(Long userId, Integer days) {
        // 封禁账号（指定天数）
        StpUtil.disable(userId, days * 24 * 60 * 60);
        return Result.ok("已封禁账号 " + days + " 天");
    }

    // 解除封禁
    @PostMapping("/undisable")
    @SaCheckRole("super-admin")
    public Result undisable(Long userId) {
        StpUtil.untieDisable(userId);
        return Result.ok("已解除封禁");
    }
}
```

### 5.2 查询在线用户

```java
@Service
public class SessionMonitorService {

    // 获取所有在线 Session（需要开启数据持久化）
    public List<OnlineUserVO> listOnlineUsers() {
        List<OnlineUserVO> result = new ArrayList<>();

        // 搜索所有 Token
        List<String> tokenKeys = SaTokenDaoContainer.getData(SaTokenDaoContainer.KEY_TYPE_TOKEN);
        for (String tokenValue : tokenKeys) {
            Object loginId = StpUtil.getLoginIdByToken(tokenValue);
            if (loginId != null) {
                OnlineUserVO vo = new OnlineUserVO();
                vo.setUserId(Long.valueOf(loginId.toString()));
                vo.setTokenValue(tokenValue);
                vo.setLastActivityTime(StpUtil.getTokenSession().getCreateTime());
                result.add(vo);
            }
        }
        return result;
    }
}
```

---

## 六、集成 Redis 持久化

### 6.1 引入依赖

```xml
<dependency>
    <groupId>cn.dev33</groupId>
    <artifactId>sa-token-redis</artifactId>
    <version>1.39.0</version>
</dependency>
<!-- Spring Boot 默认操作 Redis 需要 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

### 6.2 配置

```yaml
# 一行配置即可切换为 Redis 持久化
sa-token:
  token-persistence: redis
  # 或者使用下面的配置做更精细的控制
  # sa-token-dao: redis

spring:
  data:
    redis:
      host: 127.0.0.1
      port: 6379
```

引入 `sa-token-redis` 后，Sa-Token 所有数据（Token、Session、权限缓存等）自动存储在 Redis 中。这是**无感知切换**——代码完全不用改，所有 `StpUtil` 操作自动基于 Redis。

---

## 七、前后端分离适配

### 7.1 配置 Token 传递方式

```yaml
sa-token:
  # 前后端分离时关闭 Cookie 模式
  is-read-cookie: false
  # 改为从请求头读取 Token
  is-read-header: true
  # 请求头的名称
  token-name: Authorization
  # 是否在响应头写入 Token
  is-write-header: true
```

### 7.2 前端传递 Token

```javascript
// axios 配置
axios.interceptors.request.use(config => {
    const token = localStorage.getItem('satoken');
    if (token) {
        config.headers['Authorization'] = token;
    }
    return config;
});

axios.interceptors.response.use(
    response => {
        // 登录成功后保存 Token
        if (response.data.code === 200 && response.data.data) {
            localStorage.setItem('satoken', response.data.data);
        }
        return response;
    },
    error => {
        if (error.response.status === 401) {
            localStorage.removeItem('satoken');
            window.location.href = '/login';
        }
        return Promise.reject(error);
    }
);
```

---

## 八、Sa-Token 的微服务架构

在微服务架构中，Sa-Token 配合 Redis 实现 Session 共享：

```text
┌─────────────────────────────────────────────────────────────────┐
│                          API 网关                               │
│                  (Sa-Token 路由拦截校验)                          │
└──────────┬──────────────┬──────────────┬───────────────────────┘
           │              │              │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │  用户服务    │ │  订单服务    │ │  商品服务    │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │              │              │
           └──────────────┼──────────────┘
                     ┌────▼────┐
                     │  Redis  │
                     │ (Token) │
                     └─────────┘
```

```java
// 网关层面统一鉴权（Spring Cloud Gateway 示例）
@Component
public class GlobalAuthFilter implements GlobalFilter, Ordered {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // 获取请求路径
        String path = exchange.getRequest().getURI().getPath();

        // 白名单
        if (path.contains("/auth/login") || path.contains("/auth/register")) {
            return chain.filter(exchange);
        }

        // 校验 Token（会自动从 Header 中读取）
        try {
            StpUtil.checkLogin();
            return chain.filter(exchange);
        } catch (NotLoginException e) {
            ServerHttpResponse response = exchange.getResponse();
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return response.writeWith(Mono.just(response.bufferFactory()
                .wrap(JSON.toJSONBytes(Result.fail(401, "未登录")))));
        }
    }

    @Override
    public int getOrder() {
        return -100;
    }
}
```

---

## 九、Sa-Token vs Spring Security 对比

| 维度 | Sa-Token | Spring Security |
|------|----------|---------------|
| 学习曲线 | 低（半小时上手） | 高（数周掌握） |
| 代码量 | 极少（StpUtil 一行登录） | 较多（Configurer + Filter + Provider） |
| RBAC 权限 | @SaCheckPermission | @PreAuthorize + 表达式 |
| OAuth2 | 内置支持 | 需引入单独的模块 |
| 单点登录（SSO） | 内置支持，配置简单 | 需额外配置 |
| 踢人/封禁 | StpUtil.kickout() 一行 | 需要自定义实现 |
| 前后端分离 | 天然支持 | 需额外配置 |
| Spring Boot 版本 | 2.x / 3.x 都支持 | 2.x / 3.x 都支持 |
| 社区生态 | 国内活跃 | 全球生态完善 |
| 企业级复杂场景 | 能满足大多数场景 | 更完善的扩展体系 |

**选型建议**：
- 初创项目 / 内部系统 / 快速迭代 → Sa-Token
- 大企业 / 金融级安全 / 复杂 OAuth2 流程 → Spring Security + Sa-Token 互补

---

## 十、面试常见追问

**Q1：Sa-Token 的 Token 是如何生成的？**

A：默认使用 UUID 生成，可以通过配置 `token-style` 切换风格（uuid/simple-uuid/random-32/tik 等）。如果你有自定义需求，可以实现 `TokenGenerator` 接口。

**Q2：Sa-Token 如何防止 Token 被窃取？**

A：① 支持 HTTPS 传输（Cookie 的 secure 属性）；② 支持 HttpOnly Cookie，防止 XSS 窃取；③ 支持 active-timeout 活跃超时，Token 长时间不用自动过期；④ 支持二级认证（@SaCheckSafe），敏感操作额外验证。

**Q3：如何实现一个用户只有一个在线会话？**

A：设置 `sa-token.is-concurrent=false`，新用户登录时旧 token 自动失效。或者使用 `StpUtil.kickout(userId)` 手动踢人。

---

## 总结

Sa-Token 提供了一种「开箱即用」的权限认证体验，它最大的特点就是简单：

- 登录认证 → `StpUtil.login(id)`
- 权限校验 → `@SaCheckPermission("xxx")`
- 踢人下线 → `StpUtil.kickout(id)`
- Redis 切换 → 添加一个依赖即可

对于国内绝大多数的业务系统，Sa-Token 的功能覆盖已经绰绰有余，而且学习成本极低。如果你还在被 Spring Security 复杂的配置折磨，不妨试试 Sa-Token。
