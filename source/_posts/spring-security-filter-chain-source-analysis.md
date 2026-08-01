---
title: 面试官：说说 Spring Security 的过滤器链与认证流程？
date: 2026-08-01 08:10:00
tags:
  - Spring Security
  - 源码
  - 认证授权
  - 面试
categories:
  - Java
  - Spring 全家桶
  - 后端面试
author: 东哥
---

# 面试官：说说 Spring Security 的过滤器链与认证流程？

Spring Security 号称"原理复杂、用起来简单"，几乎每个做 Java 后端的都被它折磨过。但真正理解它的过滤器链架构，一切配置都会变得清晰。本文从面试官视角出发，从过滤器链到认证流程源码级拆解，帮你彻底打通 Spring Security 的任督二脉。

<!-- more -->

## 面试官：Spring Security 的认证流程是什么？请从请求进入开始讲

**答：** 一个 HTTP 请求进入 Spring Security 后，会依次经过**过滤器链（Filter Chain）**，认证相关的核心过滤器处理后，最终由授权过滤器判断是否可以访问资源。

整体链路可以概括为：

```
请求 → Tomcat 容器过滤器 → DelegatingFilterProxy
     → FilterChainProxy（Spring Security 过滤器链的入口）
     → 安全过滤器链（SecurityFilterChain 中的 N 个过滤器）
     → DispatcherServlet → Controller
```

## 一、两个关键的"代理"：DelegatingFilterProxy 与 FilterChainProxy

很多人在这一步就懵了，因为 Spring Security 里有两个 Proxy。

### 1. DelegatingFilterProxy

Servlet 容器（Tomcat）的过滤器在容器启动时初始化，但 Spring Security 的过滤器是 Spring 容器管理的 Bean，二者生命周期不一致。`DelegatingFilterProxy` 就是桥接层——它是一个注册在 web.xml / 自动配置里的普通 Servlet Filter，名字固定为 `springSecurityFilterChain`，当请求进来时，它把执行委托给 Spring 容器中同名的 Bean：

```java
// DelegatingFilterProxy 核心逻辑（简化）
public void doFilter(ServletRequest request, ServletResponse response, FilterChain filterChain) {
    Filter delegate = getFilterBean();   // 从 Spring 容器拿 "springSecurityFilterChain" Bean
    delegate.doFilter(request, response, filterChain);
}
```

### 2. FilterChainProxy

这个"springSecurityFilterChain" Bean 的真实类型就是 `FilterChainProxy`。它内部持有一组 `SecurityFilterChain`，每个 `SecurityFilterChain` 包含：

- `RequestMatcher`：匹配规则（哪些 URL 走这条链）
- `List<Filter>`：过滤器列表（真正的安全逻辑）

```java
public class FilterChainProxy extends GenericFilterBean {
    private List<SecurityFilterChain> filterChains;
    // 请求进来后，遍历 filterChains，找到第一个匹配的链并执行
}
```

所以多套 SecurityFilterChain 的本质就是：**按 URL 匹配，路由到不同的过滤器组合**。比如 `/api/**` 走 JWT 无状态链，`/admin/**` 走表单登录链。

## 二、核心过滤器逐个数（面试高频）

以最常用的 `httpBasic/表单登录 + 授权` 配置为例，一条典型链路包含（按执行顺序）：

| 顺序 | 过滤器 | 职责 |
|------|--------|------|
| 1 | `SecurityContextHolderFilter` | 从 Session/SecurityContextRepository 恢复认证信息到 SecurityContextHolder |
| 2 | `HeaderWriterFilter` | 写安全响应头（X-Frame-Options、CSP 等） |
| 3 | `CorsFilter` / `CsrfFilter` | 跨域处理、CSRF 防护 |
| 4 | `LogoutFilter` | 处理登出 |
| 5 | `UsernamePasswordAuthenticationFilter` | **表单登录认证**（拦截 /login POST） |
| 6 | `BasicAuthenticationFilter` | HTTP Basic 认证 |
| 7 | `RequestCacheAwareFilter` | 登录成功后跳回原页面 |
| 8 | `SecurityContextHolderAwareRequestFilter` | 包装 request |
| 9 | `AnonymousAuthenticationFilter` | 为未认证用户生成 AnonymousAuthenticationToken |
| 10 | `ExceptionTranslationFilter` | **捕获认证/授权异常并处理**（重定向登录/返回 403） |
| 11 | `AuthorizationFilter` | **最终授权检查**（@PreAuthorize、authorizeHttpRequests 规则） |

> 面试加分点：整个链的"守门员"是 `AuthorizationFilter`（Spring Security 6 后替代了 `FilterSecurityInterceptor`），它调用 `AuthorizationManager` 做最终裁决；而 `ExceptionTranslationFilter` 负责把"未认证"转成 401/重定向登录，把"无权限"转成 403。

## 三、认证流程源码级拆解

以表单登录为例，核心类协作关系：

```
UsernamePasswordAuthenticationFilter
    ↓ 提取用户名密码，封装成 UsernamePasswordAuthenticationToken（未认证）
AuthenticationManager（ProviderManager）
    ↓ 遍历 AuthenticationProvider，找到支持该 token 类型的
DaoAuthenticationProvider
    ↓ 调用 UserDetailsService.loadUserByUsername(username)
UserDetails
    ↓ 交给 DaoAuthenticationProvider 做密码校验（BCrypt）
    ↓ 校验通过 → 创建已认证的 Authentication
    ↓ 存入 SecurityContextHolder / SecurityContextRepository
    ↓ 触发 AuthenticationSuccessHandler → 登录成功
```

### 关键点 1：AuthenticationManager 与 ProviderManager

`AuthenticationManager` 是认证入口，默认实现是 `ProviderManager`。它维护一组 `AuthenticationProvider`：

```java
public class ProviderManager implements AuthenticationManager {
    private List<AuthenticationProvider> providers;

    public Authentication authenticate(Authentication authentication) {
        for (AuthenticationProvider provider : providers) {
            if (provider.supports(authentication.getClass())) {
                result = provider.authenticate(authentication);
                break;  // 找到第一个支持的 Provider 就执行
            }
        }
    }
}
```

`DaoAuthenticationProvider` 是最常用的实现，它依赖：

- `UserDetailsService`：查用户（从数据库、内存、LDAP）
- `PasswordEncoder`：密码比对（推荐 BCrypt，自带盐）

### 关键点 2：认证成功/失败后做了什么

- **成功**：`AuthenticationSuccessHandler` 默认跳转到之前缓存的请求地址，配合 `RequestCacheAwareFilter` 实现"登录后回到原页面"。
- **失败**：`AuthenticationFailureHandler` 默认重定向到 `/login?error`。

这两个 Handler 是前后端分离改造时最常自定义的点——改成返回 JSON：

```java
http.formLogin(form -> form
        .successHandler((req, res, auth) -> {
            res.setContentType("application/json;charset=UTF-8");
            res.getWriter().write("{\"code\":0,\"msg\":\"登录成功\"}");
        })
        .failureHandler((req, res, e) -> {
            res.setStatus(401);
            res.getWriter().write("{\"code\":401,\"msg\":\"用户名或密码错误\"}");
        }));
```

### 关键点 3：SecurityContext 的传递

认证成功后，`Authentication` 会放入 `SecurityContext`，再绑定到 `SecurityContextHolder`（默认策略 `ThreadLocal`）。因此**业务代码里能直接 `SecurityContextHolder.getContext().getAuthentication()` 拿到当前用户**。但要注意：

- `ThreadLocal` 不跨线程传播 → 异步线程池/`@Async` 中拿不到上下文，需要手动传递或使用装饰器
- 每个请求结束，`SecurityContextHolderFilter` 会清理上下文，防止内存泄漏

## 四、无状态 JWT 场景：如何改造过滤器链

前后端分离 + JWT 是最常见生产组合，改造思路：

1. `csrf` 关闭（无 Cookie 会话，CSRF 意义不大）
2. `sessionManagement` 改为 `STATELESS`
3. 自定义 `OncePerRequestFilter` 解析 JWT 并手动设置 SecurityContext
4. 异常处理换成 JSON（`AuthenticationEntryPoint` 返回 401、`AccessDeniedHandler` 返回 403）

```java
@Bean
SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
    http
        .csrf(AbstractHttpConfigurer::disable)
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/auth/login", "/auth/refresh").permitAll()
            .anyRequest().authenticated())
        .exceptionHandling(e -> e
            .authenticationEntryPoint((req, res, ex) -> writeJson(res, 401, "未认证"))
            .accessDeniedHandler((req, res, ex) -> writeJson(res, 403, "无权限")))
        .addFilterBefore(new JwtAuthenticationFilter(jwtUtil), UsernamePasswordAuthenticationFilter.class);
    return http.build();
}
```

自定义 `JwtAuthenticationFilter` 的核心就三行：

```java
String token = resolveToken(request);                    // 从 Header 取 token
if (token != null && jwtUtil.validate(token)) {
    Authentication auth = jwtUtil.buildAuthentication(token);  // 解析出用户+权限
    SecurityContextHolder.getContext().setAuthentication(auth); // 塞进上下文
}
chain.doFilter(request, response);
```

## 五、面试官连环追问

**Q1：为什么自定义过滤器要用 `addFilterBefore` 加在 `UsernamePasswordAuthenticationFilter` 之前？**
答：因为认证过滤器执行时就要从 SecurityContext 拿已认证信息；放在它前面，JWT 过滤器先把认证信息塞进上下文，后续的授权过滤器才能正确裁决。如果放在后面，授权判断时上下文里还是空的。

**Q2：多个 SecurityFilterChain 的执行顺序是怎样的？**
答：按注册顺序（`@Order`）依次匹配，`FilterChainProxy` 找到**第一个** `matches(request)` 返回 true 的链执行，后面的不再匹配。所以精确路径的链要放在前面，兜底链（`anyRequest`）放最后。

**Q3：ExceptionTranslationFilter 具体怎么工作？**
答：它 try-catch 包住后面授权过滤器抛出的异常：捕获 `AuthenticationException` → 调用 `AuthenticationEntryPoint`（未登录跳登录页/返 401）；捕获 `AccessDeniedException` → 若是匿名用户先走 entryPoint，否则调用 `AccessDeniedHandler`（返 403）。

**Q4：Spring Security 6 相比 5 有哪些变化？**
答：① 废弃 `WebSecurityConfigurerAdapter`，全面组件化 + Lambda DSL；② `authorizeRequests` 废弃，用 `authorizeHttpRequests` + `AuthorizationManager`；③ 密码默认要求 BCrypt；④ `SecurityContextHolderFilter` 取代 `SecurityContextPersistenceFilter`，默认不写 Session。

## 总结

Spring Security 的骨架就一句话：**DelegatingFilterProxy 桥接容器 → FilterChainProxy 路由 → 过滤器链按序执行 → ExceptionTranslationFilter 兜底异常 → AuthorizationFilter 最终裁决**。把这条链路画在纸上，任何配置都不会再让你困惑。下次面试官问起，从这两个 Proxy 讲起，就是最漂亮的回答。
