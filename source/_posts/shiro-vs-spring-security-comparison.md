---
title: 【安全框架】Apache Shiro vs Spring Security：Java 安全框架深度对比与选型指南
date: 2026-09-06 08:00:00
tags:
  - Java
  - Shiro
  - Spring Security
  - 安全
  - 选型
categories:
  - Java
  - 安全框架
author: 东哥
---

# 【安全框架】Apache Shiro vs Spring Security：Java 安全框架深度对比与选型指南

## 面试官：你们项目用的什么权限框架？为什么选它？

"用的 Shiro，配置简单……""我们用的 Spring Security，生态好。"——然后呢？很多同学答不出**为什么**，也说不清两者本质区别。今天从架构、认证授权流程、生态、适用场景四个维度彻底对比，看完你就能有理有据地回答。

## 一、先统一认知：认证与授权

无论哪个框架，核心就两件事：

- **认证（Authentication）**：你是谁？——登录校验，用户名密码、验证码、OAuth2、SSO 都属于认证；
- **授权（Authorization）**：你能干什么？——权限校验，最常见的是 RBAC（Role-Based Access Control，用户-角色-权限）模型，精细点还有 ABAC（基于属性）。

两个框架都是"认证 + 授权"一站式解决方案，但**设计哲学和复杂度完全不同**。

## 二、Apache Shiro：轻量级的安全门面

### 2.1 四大核心组件

Shiro 的设计非常直观，就四个概念：

| 组件 | 作用 | 类比 |
|------|------|------|
| `Subject` | 当前操作用户（门面，程序里直接打交道的就是它） | 用户本人 |
| `SecurityManager` | 核心调度器，管理所有 Subject | 保安队长 |
| `Realm` | 数据源：从 DB/LDAP 查用户、查权限 | 户籍档案 |
| `Authenticator` / `Authorizer` | 认证器 / 授权器（SecurityManager 内部使用） | 验证身份的流程 |

`Subject` 是 Shiro 最体现设计功力的一点：**无论 Web、非 Web、单机还是分布式，程序只跟 Subject 打交道**，底层的 Session 管理、安全数据存储都被封装了。

### 2.2 认证流程

```
subject.login(token)  // token 如 UsernamePasswordToken
  -> SecurityManager.login()
    -> Authenticator.authenticate(token)
      -> Realm.getAuthenticationInfo(token)   // 查库拿用户+密码(密文)+盐
        -> 比对 credentials（支持 md5/sha + 加盐 + 多次散列）
  -> 成功：生成 Subject 身份；失败：抛 UnknownAccountException /
     IncorrectCredentialsException / LockedAccountException 等
```

一个最简单的 Realm：

```java
public class MyRealm extends AuthorizingRealm {

    // 认证：校验用户名密码
    @Override
    protected AuthenticationInfo doGetAuthenticationInfo(AuthenticationToken token) {
        String username = (String) token.getPrincipal();
        User user = userMapper.findByUsername(username);   // 查库
        if (user == null) {
            return null;   // 抛 UnknownAccountException
        }
        // 注意：这里返回的是密文 + 盐，Shiro 内部会按配置的算法重算比对
        return new SimpleAuthenticationInfo(
                user.getUsername(),
                user.getPassword(),          // 数据库中存的密文
                ByteSource.Util.bytes(user.getSalt()),  // 盐
                getName());
    }

    // 授权：查询角色与权限（首次校验时触发，可加缓存）
    @Override
    protected AuthorizationInfo doGetAuthorizationInfo(PrincipalCollection principals) {
        String username = (String) principals.getPrimaryPrincipal();
        SimpleAuthorizationInfo info = new SimpleAuthorizationInfo();
        info.addRoles(userMapper.findRoles(username));       // 角色
        info.addStringPermissions(userMapper.findPerms(username)); // 权限
        return info;
    }
}
```

### 2.3 Web 集成：过滤器链

Shiro 在 Web 层本质是一堆 Filter，通过 `ShiroFilterFactoryBean` 配置 URL 级别的拦截规则：

```java
@Bean
public ShiroFilterFactoryBean shiroFilter(SecurityManager securityManager) {
    ShiroFilterFactoryBean bean = new ShiroFilterFactoryBean();
    bean.setSecurityManager(securityManager);
    // 登录页与未授权跳转
    bean.setLoginUrl("/login");
    bean.setUnauthorizedUrl("/403");

    Map<String, String> filterChain = new LinkedHashMap<>();
    filterChain.put("/login", "anon");        // 匿名可访问
    filterChain.put("/logout", "logout");
    filterChain.put("/css/**", "anon");
    filterChain.put("/admin/**", "authc, roles[admin]");  // 需登录且是 admin 角色
    filterChain.put("/user/**", "authc, perms[user:edit]"); // 需登录且有权限
    filterChain.put("/**", "authc");          // 其余都要登录
    bean.setFilterChainDefinitionMap(filterChain);  // 注意：顺序敏感，先匹配先生效
    return bean;
}
```

内置过滤器：`anon`（匿名）、`authc`（登录）、`logout`、`roles[...]`、`perms[...]`、`user`（记住我）等。方法级权限用注解 `@RequiresRoles("admin")`、`@RequiresPermissions("user:edit")`。

### 2.4 Shiro 的特点小结

- ✅ **上手极快**：概念少、配置直观，半天能跑通；
- ✅ **不依赖 Spring**：普通 Java 项目、非 Web 项目也能用；
- ✅ **会话管理简单**：自带 SessionManager，支持分布式 Session（配合 Redis）；
- ✅ **密码学工具内置**：`Md5Hash`、`Sha256Hash` + 盐，代码少；
- ❌ 与 Spring 生态集成较浅：无 OAuth2/OIDC 一等支持，细粒度方法安全（SpEL 表达式）弱；
- ❌ 社区维护节奏慢、文档陈旧，Spring Boot 3（Jakarta）适配滞后；
- ❌ 过滤器链基于 URL 字符串，配置复杂场景可读性差、易错。

## 三、Spring Security：Spring 生态的安全内核

### 3.1 核心架构

Spring Security 的骨架是一条**过滤器链**：

```
请求 -> FilterChainProxy（入口）
         -> SecurityContextPersistenceFilter   // 从 Session 恢复 SecurityContext
         -> UsernamePasswordAuthenticationFilter // 表单登录认证
         -> BasicAuthenticationFilter / JwtAuthenticationFilter ...
         -> ExceptionTranslationFilter         // 把 AccessDeniedException 转成 403/跳转
         -> AuthorizationFilter                // 最终授权校验
      -> Controller
```

Java Config 方式（Boot 3.x / Security 6.x）推荐**组件式配置**，声明一个 `SecurityFilterChain` Bean：

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity          // 开启方法级安全注解
public class SecurityConfig {

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())                 // 前后端分离关 CSRF
            .sessionManagement(sm -> sm.sessionCreationPolicy(
                    SessionCreationPolicy.STATELESS))     // JWT 无状态
            .authorizeHttpRequests(auth -> auth
                    .requestMatchers("/login", "/public/**").permitAll()
                    .requestMatchers("/admin/**").hasRole("ADMIN")
                    .requestMatchers("/user/**").hasAuthority("user:edit")
                    .anyRequest().authenticated())
            .addFilterBefore(new JwtAuthenticationFilter(),   // 自定义 JWT 过滤器
                    UsernamePasswordAuthenticationFilter.class);
        return http.build();
    }

    // 认证数据源：查库 + 密码比对
    @Bean
    public UserDetailsService userDetailsService() {
        return username -> {
            User user = userMapper.findByUsername(username);
            if (user == null) throw new UsernameNotFoundException(username);
            // 返回 Spring Security 的用户模型（含密码密文与权限列表）
            return org.springframework.security.core.userdetails.User
                    .withUsername(user.getUsername())
                    .password(user.getPassword())          // {bcrypt}xxx 格式
                    .authorities(user.getPerms().toArray(new String[0]))
                    .build();
        };
    }

    // 密码编码器：BCrypt 是默认推荐
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

认证核心链路：`AuthenticationManager` -> `AuthenticationProvider` -> `UserDetailsService.loadUserByUsername()` -> `PasswordEncoder.matches()` 比对。认证成功后把 `Authentication` 塞进 `SecurityContextHolder`（内部是 ThreadLocal），后续代码随时可取当前用户。

### 3.2 授权：方法级安全

```java
@RestController
public class OrderController {

    @GetMapping("/order/{id}")
    @PreAuthorize("hasRole('USER') and #id == authentication.principal.userId")
    public Order getOrder(@PathVariable Long id) { ... }
    // 方法级 + SpEL 表达式：既能校验角色，还能做"只能查自己的订单"这种对象级校验
}
```

`@PreAuthorize` 通过 AOP 在方法调用前拦截，SpEL 表达式能力极强（角色、权限、参数、返回值、自定义 Bean 方法都能引用），这是 Shiro 注解比不了的。

### 3.3 Spring Security 的特点小结

- ✅ **Spring 官方出品**：与 Spring Boot 自动配置、Spring MVC、方法安全无缝集成；
- ✅ **OAuth2/OIDC 一等公民**：`oauth2-client`（第三方登录）、`oauth2-resource-server`（JWT 鉴权）、`oauth2-login` 开箱即用；
- ✅ **安全默认值完善**：CSRF 防护、安全响应头（`X-Frame-Options`、CSP、HSTS）、Session 固定攻击防护默认开启；
- ✅ **BCrypt 等现代算法**：`PasswordEncoder` 体系，支持密码自动升级；
- ❌ **学习曲线陡**：概念多（FilterChain、AuthenticationManager、Provider、SecurityContext……），报错信息抽象；
- ❌ 配置一旦写错容易"全局 403 或全部放行"，排查成本高；
- ❌ 非 Spring 项目基本无法使用。

## 四、正面硬刚：对比表

| 维度 | Apache Shiro | Spring Security |
|------|-------------|-----------------|
| 出身 | Apache 独立项目 | Spring 官方（Pivotal/VMware） |
| 核心模型 | Subject / SecurityManager / Realm | SecurityFilterChain / AuthenticationManager |
| 上手难度 | ⭐ 低，半天上手 | ⭐⭐⭐ 高，概念多 |
| Spring 集成度 | 低（可脱离 Spring） | **极高**（深度绑定） |
| 方法级安全 | 注解简单（@RequiresRoles） | **@PreAuthorize + SpEL，能力最强** |
| OAuth2 / OIDC | 基本不支持（需第三方） | **原生支持 client / resource server** |
| 安全默认值 | 少（需自己配） | 多（CSRF、响应头、Session 防护） |
| 密码方案 | 散列+盐（需自己拼） | PasswordEncoder 体系（BCrypt 等） |
| 无状态 JWT | 需手写 Filter | 手写 Filter 或 resource-server 原生支持 |
| 社区活跃度 | 一般（版本迭代慢） | **非常活跃** |
| 非 Spring 项目 | ✅ 可用 | ❌ 不可用 |
| 典型场景 | 轻量后台、老系统、非 Spring 项目 | **Spring Boot 新项目、微服务、OAuth2 生态** |

## 五、到底怎么选？给结论

1. **Spring Boot 新项目，无脑 Spring Security**。理由：官方维护、OAuth2/JWT 生态齐全、方法级 SpEL 强大、安全默认值帮你兜底。担心学习成本？只需要掌握"过滤器链 + UserDetailsService + PasswordEncoder + @PreAuthorize"四条主线，足以覆盖 90% 需求。
2. **非 Spring 项目 / 普通 Java Web / 只想快速加个登录**：选 Shiro，它确实轻。
3. **遗留系统正在用 Shiro 且跑得好好的**：没必要为了"先进"强行迁移，迁移收益低于风险；但当你要接入 OAuth2/微服务统一认证时，再考虑逐步替换。
4. **微服务场景**：网关层统一鉴权（Spring Cloud Gateway + OAuth2 Resource Server）是主流形态，框架层的 Security 主要负责"解析已认证身份 + 方法级授权"——此时 Spring Security 几乎是唯一顺手的选择。

## 六、面试追问速答

**Q：Spring Security 的 SecurityContextHolder 原理是什么？有什么坑？**
内部是 ThreadLocal（`MODE_THREADLOCAL`），请求进入过滤器链时由 `SecurityContextPersistenceFilter` 从 Session 恢复、请求结束清理。坑在于：**异步线程、@Async、消息消费线程拿不到主线程的 SecurityContext**——需要手动传播（`DelegatingSecurityContextExecutor` / `SecurityContextCallable`）或从 Token 重新解析。

**Q：Shiro 和 Spring Security 过滤器链的本质区别？**
Shiro 是"**一个 ShiroFilter 分发到内置过滤器链**"，规则靠 URL 字符串匹配（LinkedHashMap 顺序敏感）；Spring Security 是"**FilterChainProxy 管理多条 SecurityFilterChain**"，每条链按 `SecurityFilterChain` 匹配器选择，过滤器是 Bean、可排序可插拔，扩展方式更正规。

**Q：@PreAuthorize 是怎么生效的？**
`@EnableMethodSecurity` 引入 AOP 切面（`AuthorizationManagerBeforeMethodInterceptor`），在方法调用前用 `AuthorizationManager` 求值 SpEL 表达式，不通过就抛 `AccessDeniedException`，由 `ExceptionTranslationFilter` 转成 403。

**Q：权限数据模型怎么设计？**
小系统：用户-角色-权限三张表 + 关联表，权限用字符串（`user:edit`）。大系统：加资源表、数据权限维度（部门/租户），或用 ABAC 用 SpEL/规则引擎表达"谁能看哪些数据"。设计原则：**角色管粗粒度，权限管细粒度，数据权限单独设计**。

**Q：为什么 Spring Security 默认推荐 BCrypt？**
BCrypt 自带随机盐、计算慢（抗暴力破解）、输出串自带盐信息无需单独存盐字段；相比 MD5/SHA 加盐要自己实现且现代 GPU 可秒破，BCrypt 是"成本可控的安全默认值"。Shiro 传统散列方案在新项目里已经不推荐了。

**一句话收尾**：Shiro 是"轻巧的门卫"，Spring Security 是"完整的安保体系"。选型先看项目出身——**Spring 生态里它俩的差距，远大于那点学习成本**。
