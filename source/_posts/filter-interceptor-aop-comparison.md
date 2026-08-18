---
title: 面试官：Filter、Interceptor、AOP 到底有什么区别？
date: 2026-08-18 08:00:00
tags:
  - Spring
  - Spring MVC
  - 过滤器
  - 拦截器
  - AOP
  - 面试
categories:
  - Spring
  - 后端面试
author: 东哥
---

# 面试官：Filter、Interceptor、AOP 到底有什么区别？

## 场景还原

面试官："你们项目里登录鉴权是怎么做的？"
你："用了拦截器。"
面试官："那为什么不用 Filter？Filter 和 Interceptor 什么区别？跟 AOP 又是什么关系？"

这三个东西几乎每个 Java 后端项目都在用，但能把它们讲清楚的候选人不到三成。今天一次讲透。

---

## 一、先搞清楚三个"层次"

一句话定位：**Filter 是 Servlet 规范的东西，Interceptor 是 Spring MVC 的东西，AOP 是 Spring 容器的东西**。它们分属三个不同的抽象层次，作用范围天然不同。

| 维度 | Filter | Interceptor | AOP |
|------|--------|-------------|-----|
| 所属规范 | Servlet 规范（javax/jakarta.servlet） | Spring MVC 框架 | Spring 容器（AOP 模块） |
| 作用对象 | Servlet 请求（URL 级别的请求） | Handler 方法（Controller 方法） | 任意 Spring Bean 的方法 |
| 触发时机 | 请求进入 Servlet 容器时 | 请求进入 DispatcherServlet 之后、调用 Handler 前后 | Bean 方法调用时（代理对象） |
| 能否拿到 Handler 信息 | 不能 | 能（HandlerMethod，含注解、参数） | 能（Method 对象） |
| 依赖 Spring 容器 | 不依赖（Web 容器管理） | 依赖 | 强依赖 |
| 粒度 | 粗（URL 级） | 中（方法级，仅 MVC） | 细（任意方法，不限于 Web） |

**核心记忆点**：三者的过滤范围是逐层收窄的——Filter 拦的是"所有进容器的请求"，Interceptor 拦的是"进入 MVC 的请求"，AOP 拦的是"Bean 方法的调用"。

---

## 二、执行时机：一次请求到底经历了什么？

先看完整调用链（以 Spring Boot + Spring MVC 为例）：

```
客户端请求
  → Tomcat 线程
    → Filter1.doFilter()  ...  before
      → Filter2.doFilter() ...  before
        → DispatcherServlet.doDispatch()
          → HandlerMapping 找到 HandlerMethod
          → HandlerExecutionChain 组装拦截器链
            → Interceptor1.preHandle()
              → Interceptor2.preHandle()
                → 执行 Controller 方法（被 AOP 代理包裹）
                  → @Around 前置逻辑
                    → @Before
                      → 目标方法执行
                      → @AfterReturning / @After
                  → @Around 后置逻辑
                → Interceptor2.postHandle()
                → Interceptor1.postHandle()
              → 视图渲染（afterCompletion 在渲染后）
        → Filter 链的 after 逻辑（响应出容器前）
```

三个关键结论：

### 1. Filter 在最外层
请求**先过 Filter，再过 DispatcherServlet**。所以 Filter 能拦截到静态资源、404 请求等一切进入容器的请求；也能拦截到 Spring Security 的过滤器链——实际上 **Spring Security 本身就是一串 Filter（DelegatingFilterProxy 注册的 FilterChainProxy）**。

### 2. Interceptor 在 DispatcherServlet 内部
它依赖 HandlerMapping 找到了具体的处理器之后才能工作。所以 Interceptor 能拿到 HandlerMethod，从而读取方法上的注解、参数、返回值类型——**这是 Filter 做不到的**。

### 3. AOP 在最内层
它不关心你是不是 Web 请求，只关心"某个 Bean 的方法被调用"。Controller 里的方法在 Spring 容器中是被代理的，所以 AOP 也能切 Controller（但一般不建议，事务/缓存等切面都在 Service 层）。

---

## 三、源码验证：三个关键类

### Filter —— FilterChain 链表

```java
public interface Filter {
    void doFilter(ServletRequest request, ServletResponse response, FilterChain chain);
}
```

Filter 链是**单向链表**结构，`chain.doFilter()` 负责把请求传给下一个 Filter；不调用它，请求就断在这里（可以做拦截响应）。注册方式：

```java
@Bean
public FilterRegistrationBean<AuthFilter> authFilter() {
    FilterRegistrationBean<AuthFilter> reg = new FilterRegistrationBean<>(new AuthFilter());
    reg.addUrlPatterns("/*");
    reg.setOrder(1);  // 数字越小越先执行
    return reg;
}
```

### Interceptor —— HandlerExecutionChain

```java
public interface HandlerInterceptor {
    default boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) { return true; }
    default void postHandle(...) {}
    default void afterCompletion(...) {}
}
```

- `preHandle` 返回 `false` 直接终止链路（后续拦截器和 Controller 都不会执行）；
- `postHandle` 在 Controller 返回后、视图渲染前；
- `afterCompletion` 在请求完全结束后（无论是否抛异常都会执行，适合清理资源）。

注册：实现 `WebMvcConfigurer.addInterceptors()`。注意 **Spring Boot 3 / Spring 6 中 WebMvcConfigurerAdapter 已废弃，直接实现接口即可**。

### AOP —— 代理链

```java
// 切面示例
@Aspect
@Component
public class LogAspect {
    @Around("@annotation(OperationLog)")
    public Object around(ProceedingJoinPoint pjp) throws Throwable {
        long start = System.currentTimeMillis();
        Object result = pjp.proceed();
        log.info("耗时: {}ms", System.currentTimeMillis() - start);
        return result;
    }
}
```

AOP 底层是 JDK 动态代理或 CGLIB 代理，切面方法通过代理对象在目标方法前后织入。

---

## 四、三者选型：什么场景用谁？

### 用 Filter
- **跨域（CORS）全局处理**：要拦所有请求，包括静态资源；
- **字符编码、请求日志（原始 body 级别）**：在请求进入业务代码前；
- **登录态粗粒度校验**（如 token 是否存在，不关心业务含义）；
- **与 Spring 无关的通用能力**，如第三方网关逻辑。

### 用 Interceptor
- **需要读取 HandlerMethod 注解的鉴权**：如 `@RequirePermission` 注解 + preHandle 校验；
- **Controller 层的日志/耗时统计**；
- **需要拿到 ModelAndView 做渲染前后处理的场景**；
- **需要中断请求链并返回自定义响应**（preHandle 返回 false）。

### 用 AOP
- **事务管理 @Transactional**（本质就是 AOP）；
- **缓存 @Cacheable、异步 @Async、重试 @Retryable**；
- **操作日志、审计、权限校验注解（自定义注解 + AOP）**；
- **任意非 Web 层的方法增强**，如 MQ 消费者、定时任务方法的监控。

一句话选型：**要管所有请求 → Filter；只管 Controller 调用 → Interceptor；要管任意 Bean 方法且能自定义注解 → AOP**。

---

## 五、面试官连环追问

**Q1：Filter 和 Interceptor 的执行顺序谁先谁后？**
Filter 先。请求先进 Servlet 容器 → Filter 链 → DispatcherServlet → Interceptor。响应则相反，Interceptor 的 afterCompletion 先执行，Filter 的 after 逻辑最后执行。**Filter 是"包在外面"的**。

**Q2：异常处理有什么差异？**
Filter 的异常发生在 DispatcherServlet 之前时，`@ControllerAdvice` 的 `@ExceptionHandler` 处理不到（因为还没进入 MVC）；Interceptor 内的异常可以被 HandlerExceptionResolver 处理；AOP 内抛出的异常如果被切面 catch 了，ControllerAdvice 也看不到。**所以全局异常兜底一般建议放在最外层 Filter 或 ErrorController**。

**Q3：Interceptor 能拿到 Controller 方法的注解吗？**
能。`preHandle` 的 handler 参数是 `HandlerMethod`，可以 `((HandlerMethod) handler).getMethodAnnotation(Xxx.class)`。这是 Filter 做不到的。

**Q4：Filter 里能用 Spring 的 Bean 吗？**
能，但要注意：**Filter 是 Web 容器管理的，不是 Spring 容器管理的**。要么通过 `DelegatingFilterProxy` 注册（Spring Boot 中 `FilterRegistrationBean` 注册的 Filter 是在 Spring 容器里的，可以直接注入）；要么在 Filter 里用 `ApplicationContext` 手动获取。Spring Security 之所以能作为 Filter 工作，靠的就是 DelegatingFilterProxy 桥接。

**Q5：AOP 能切 Filter 吗？**
不能直接切——Filter 不在 Spring 容器管理范围内（除非它本身也是 Bean 且通过 Bean 调用，但 doFilter 由容器触发，不走代理）。同理，**AOP 只能切 Spring Bean 的调用**，new 出来的对象、静态方法都切不了。

**Q6：三者都能做权限校验，重复用会怎样？**
会导致重复校验和性能浪费。常规做法：**Filter 做粗粒度（登录态），Interceptor 做细粒度（基于注解的权限），AOP 做业务逻辑增强（审计日志）**，各司其职，避免同一件事做三遍。

---

## 六、总结

| 对比项 | Filter | Interceptor | AOP |
|--------|--------|-------------|-----|
| 层次 | Servlet 容器 | Spring MVC | Spring 容器 |
| 拦截对象 | URL 请求 | Handler 方法 | Bean 方法 |
| 拿到 HandlerMethod | ❌ | ✅ | ✅（Method） |
| 中断请求 | 不调用 chain.doFilter | preHandle 返回 false | 不调用 pjp.proceed |
| 典型应用 | 编码、CORS、粗鉴权 | 注解鉴权、日志 | 事务、缓存、审计 |

记住一句话总结：**Filter 管"请求"，Interceptor 管"调用"，AOP 管"方法"**。把层次讲清楚，再补上执行顺序和典型场景，这道题就是送分题。
