---
title: 【面试必备】Spring MVC 核心原理深度解析：从 DispatcherServlet 到 HandlerMapping 源码剖析
date: 2026-07-08 08:00:00
tags:
  - Spring
  - Spring MVC
  - 源码
  - 面试
categories:
  - Java
  - Spring
author: 东哥
---

# 【面试必备】Spring MVC 核心原理深度解析：从 DispatcherServlet 到 HandlerMapping 源码剖析

## 面试官：说说 Spring MVC 的请求处理流程？

Spring MVC 是 Spring 框架中最重要的模块之一，几乎所有 Java Web 开发者每天都在使用它。但很多人只停留在 `@Controller`、`@RequestMapping` 的注解使用层面，对底层实现知之甚少。

本文将从源码层面，彻底剖析 DispatcherServlet 的核心处理流程。

---

## 一、Spring MVC 整体架构

Spring MVC 基于**前端控制器模式（Front Controller Pattern）**设计，所有请求统一由 `DispatcherServlet` 接收，然后分发到具体的处理器。

### 核心组件一览

| 组件 | 作用 | 默认实现 |
|------|------|----------|
| **DispatcherServlet** | 前端控制器，统一接收请求并分发 | — |
| **HandlerMapping** | 将请求映射到对应的 Handler | `RequestMappingHandlerMapping` |
| **HandlerAdapter** | 适配调用具体的 Handler 方法 | `RequestMappingHandlerAdapter` |
| **HandlerInterceptor** | 拦截器链，在 Handler 前后执行 | `HandlerInterceptor` 接口 |
| **ViewResolver** | 解析视图名称到实际 View | `InternalResourceViewResolver` |
| **View** | 渲染响应结果 | `JstlView`、`JsonView` 等 |

### 一次请求的完整处理流程

```
用户请求 → Tomcat → DispatcherServlet → HandlerMapping（找处理器）
  → HandlerExecutionChain（含拦截器链） → HandlerAdapter（调用处理器）
    → 前置拦截器 → 实际方法执行 → 后置拦截器
  → ViewResolver（解析视图） → View（渲染） → 响应
```

---

## 二、DispatcherServlet 核心源码解析

### 2.1 类继承结构

```
DispatcherServlet
  └── FrameworkServlet
        └── HttpServletBean
              └── HttpServlet
```

`DispatcherServlet` 本质上就是一个 `HttpServlet`，其核心能力在 `FrameworkServlet` 和 `DispatcherServlet` 两个类中实现。

### 2.2 初始化：onRefresh()

当 Spring 容器启动时，`DispatcherServlet` 会通过 `onRefresh()` 方法初始化九大组件：

```java
// DispatcherServlet.java
@Override
protected void onRefresh(ApplicationContext context) {
    initStrategies(context);
}

protected void initStrategies(ApplicationContext context) {
    // 文件上传解析器
    initMultipartResolver(context);
    // 本地化解析器
    initLocaleResolver(context);
    // 主题解析器
    initThemeResolver(context);
    // HandlerMapping —— 请求映射
    initHandlerMappings(context);
    // HandlerAdapter —— 处理器适配器
    initHandlerAdapters(context);
    // HandlerExceptionResolver —— 异常处理
    initHandlerExceptionResolvers(context);
    // RequestToViewNameTranslator —— 视图名转换
    initRequestToViewNameTranslator(context);
    // ViewResolver —— 视图解析
    initViewResolvers(context);
    // FlashMapManager —— 重定向参数管理
    initFlashMapManager(context);
}
```

**面试追问：为什么要先初始化文件上传解析器？**
> 因为后续的处理器可能依赖于已解析的 `MultipartHttpServletRequest`，DispatcherServlet 在分发前会先包装请求。

### 2.3 核心方法：doDispatch()

这是整个 Spring MVC 最核心的方法，每一次请求最终都会到达这里：

```java
protected void doDispatch(HttpServletRequest request, HttpServletResponse response) throws Exception {
    HttpServletRequest processedRequest = request;
    HandlerExecutionChain mappedHandler = null;
    boolean multipartRequestParsed = false;

    try {
        ModelAndView mv = null;
        Exception dispatchException = null;

        try {
            // ① 检查是否是文件上传请求，是则包装为 MultipartHttpServletRequest
            processedRequest = checkMultipart(request);
            multipartRequestParsed = (processedRequest != request);

            // ② 获取 HandlerExecutionChain（HandlerMapping 的核心逻辑）
            mappedHandler = getHandler(processedRequest);
            if (mappedHandler == null) {
                noHandlerFound(processedRequest, response);
                return;
            }

            // ③ 获取 HandlerAdapter（适配具体 Handler）
            HandlerAdapter ha = getHandlerAdapter(mappedHandler.getHandler());

            // ④ 执行前置拦截器（preHandle）
            if (!mappedHandler.applyPreHandle(processedRequest, response)) {
                return;
            }

            // ⑤ HandlerAdapter 执行实际的 Handler 方法
            mv = ha.handle(processedRequest, response, mappedHandler.getHandler());

            // ⑥ 如果没有返回视图名，尝试从请求中解析
            applyDefaultViewName(processedRequest, mv);

            // ⑦ 执行后置拦截器（postHandle）
            mappedHandler.applyPostHandle(processedRequest, response, mv);
        } catch (Exception ex) {
            dispatchException = ex;
        } catch (Throwable err) {
            dispatchException = new NestedServletException("Handler dispatch failed", err);
        }

        // ⑧ 处理返回结果，调用异常解析器或渲染视图
        processDispatchResult(processedRequest, response, mappedHandler, mv, dispatchException);
    } finally {
        // ⑨ 请求完成后的清理（触发拦截器的 afterCompletion）
        if (mappedHandler != null) {
            mappedHandler.triggerAfterCompletion(processedRequest, response, null);
        }
    }
}
```

---

## 三、HandlerMapping：请求到底如何找到 Controller？

### 3.1 HandlerMapping 接口

```java
public interface HandlerMapping {
    @Nullable
    HandlerExecutionChain getHandler(HttpServletRequest request) throws Exception;
}
```

核心方法就一个：根据 `HttpServletRequest` 返回一个 **HandlerExecutionChain**（包含 Handler + 拦截器链）。

### 3.2 HandlerExecutionChain 结构

```java
public class HandlerExecutionChain {
    private final Object handler;          // 实际的处理器对象
    private HandlerInterceptor[] interceptors;  // 拦截器数组
    private List<HandlerInterceptor> interceptorList;  // 拦截器列表
    
    // 执行前置拦截器
    boolean applyPreHandle(HttpServletRequest request, HttpServletResponse response) { ... }
    // 执行后置拦截器
    void applyPostHandle(HttpServletRequest request, HttpServletResponse response, ModelAndView mv) { ... }
    // 触发完成回调
    void triggerAfterCompletion(HttpServletRequest request, HttpServletResponse response, Exception ex) { ... }
}
```

### 3.3 主要的 HandlerMapping 实现

| 实现类 | 说明 | 优先级 |
|--------|------|--------|
| `RequestMappingHandlerMapping` | 基于 `@RequestMapping` 注解，最常用 | 最高 |
| `SimpleUrlHandlerMapping` | 基于 URL 路径配置 | 中 |
| `BeanNameUrlHandlerMapping` | 根据 Bean Name 匹配 `/beanName` | 低 |
| `RouterFunctionMapping` | WebFlux 函数式路由 | — |

### 3.4 RequestMappingHandlerMapping 实现原理

**核心逻辑：`AbstractHandlerMethodMapping.lookupHandlerMethod()`**

```java
// AbstractHandlerMethodMapping.java
@Nullable
protected HandlerMethod lookupHandlerMethod(String lookupPath, HttpServletRequest request) throws Exception {
    List<T> directPathMatches = this.mappingRegistry.getMappingsByDirectPath(lookupPath);
    if (directPathMatches != null) {
        // 精确路径匹配
        match = addMatchingMapping(mapping, directPathMatches.get(0));
    }
    if (match != null) {
        return match;
    }
    // 模糊匹配（如 /api/**）
    for (T mapping : this.mappingRegistry.getMappings()) {
        if (isMatch(mapping, lookupPath)) {
            matches.add(mapping);
        }
    }
    // 排序后取最优匹配
    if (!matches.isEmpty()) {
        Comparator<MappingRegistration<T>> comparator = (o1, o2) -> ...
        matches.sort(comparator);
        return matches.get(0).handlerMethod;
    }
    return null;
}
```

**面试追问：当两个 @RequestMapping 路径相同时，Spring MVC 如何处理？**
> 会走模糊匹配流程，根据条件进行排序。匹配度更高的排在前面，例如有请求参数条件的优于无条件的。如果完全一致，会抛出异常，因为无法确定调用哪个。

---

## 四、HandlerAdapter：适配器的艺术

### 4.1 为什么需要 HandlerAdapter？

Handler 的类型多种多样：
- `@Controller` 注解的方法（`HandlerMethod`）
- 实现了 `Controller` 接口的类
- `HttpRequestHandler`

HandlerAdapter 的作用就是**用一个统一的接口适配不同类型的 Handler**：

```java
public interface HandlerAdapter {
    // 判断是否支持该 Handler
    boolean supports(Object handler);

    // 执行 Handler，返回 ModelAndView
    @Nullable
    ModelAndView handle(HttpServletRequest request, HttpServletResponse response, Object handler) throws Exception;
}
```

### 4.2 RequestMappingHandlerAdapter 的执行逻辑

```java
// RequestMappingHandlerAdapter.invokeHandlerMethod()
protected ModelAndView invokeHandlerMethod(HttpServletRequest request, HttpServletResponse response, HandlerMethod handlerMethod) throws Exception {
    // 创建参数绑定器工厂
    WebDataBinderFactory binderFactory = getDataBinderFactory(handlerMethod);
    // 创建 ModelFactory
    ModelFactory modelFactory = getModelFactory(handlerMethod, binderFactory);

    // 创建 ServletInvocableHandlerMethod（可调用的处理器方法包装）
    ServletInvocableHandlerMethod invocableMethod = createInvocableHandlerMethod(handlerMethod);
    invocableMethod.setHandlerMethodArgumentResolvers(this.argumentResolvers);
    invocableMethod.setHandlerMethodReturnValueHandlers(this.returnValueHandlers);
    invocableMethod.setDataBinderFactory(binderFactory);

    // 创建 ModelAndViewContainer
    ModelAndViewContainer mavContainer = new ModelAndViewContainer();

    // 执行方法
    invocableMethod.invokeAndHandle(webRequest, mavContainer);

    // 返回 ModelAndView
    return getModelAndView(mavContainer, modelFactory, webRequest);
}
```

### 4.3 参数解析器（HandlerMethodArgumentResolver）

Spring MVC 最神奇的功能之一：Controller 方法的参数可以自动注入。

```java
public interface HandlerMethodArgumentResolver {
    boolean supportsParameter(MethodParameter parameter);
    @Nullable
    Object resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
                          NativeWebRequest webRequest, WebDataBinderFactory binderFactory);
}
```

常见的参数解析器：

| 参数解析器 | 解析的参数类型 |
|------------|---------------|
| `RequestParamMethodArgumentResolver` | `@RequestParam` 注解的参数 |
| `PathVariableMethodArgumentResolver` | `@PathVariable` 注解的参数 |
| `RequestResponseBodyMethodProcessor` | `@RequestBody` 注解的参数 |
| `ServletModelAttributeMethodProcessor` | Model 属性/ `@ModelAttribute` |
| `ServletRequestMethodArgumentResolver` | `HttpServletRequest`、`HttpServletResponse` |

---

## 五、拦截器链：在方法执行前后做手脚

### 5.1 HandlerInterceptor 接口

```java
public interface HandlerInterceptor {
    // 在 Handler 执行之前调用，返回 false 则中断请求
    default boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) throws Exception {
        return true;
    }
    // 在 Handler 执行之后、视图渲染之前调用
    default void postHandle(HttpServletRequest request, HttpServletResponse response, Object handler, @Nullable ModelAndView modelAndView) throws Exception {
    }
    // 在请求完成之后（视图渲染之后）调用
    default void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, @Nullable Exception ex) throws Exception {
    }
}
```

### 5.2 拦截器 vs 过滤器

| 对比维度 | Filter | HandlerInterceptor |
|----------|--------|-------------------|
| 规范级别 | Servlet 规范 | Spring MVC 内部 |
| 作用范围 | 所有 URL | 仅经过 DispatcherServlet 的请求 |
| 获取 Bean | 较困难 | 可以直接注入 Spring Bean |
| 精细化控制 | 粗粒度 | 可以拿到具体 Handler 方法 |
| 资源 | Web 容器级 | Spring 容器级 |

---

## 六、ViewResolver：视图的最终渲染

```java
public interface ViewResolver {
    @Nullable
    View resolveViewName(String viewName, Locale locale) throws Exception;
}
```

常见的 ViewResolver：

| 实现类 | 功能 |
|--------|------|
| `InternalResourceViewResolver` | 解析 JSP 视图 |
| `ThymeleafViewResolver` | 解析 Thymeleaf 模板 |
| `FreeMarkerViewResolver` | 解析 FreeMarker 模板 |
| `ContentNegotiatingViewResolver` | 根据内容协商选择视图 |

当方法标注 `@ResponseBody` 或 `@RestController` 时，`RequestResponseBodyMethodProcessor` 会直接将返回值写入响应体，**不经过 ViewResolver**。

---

## 七、面试高频追问汇总

### Q1：DispatcherServlet 是单例还是多例？线程安全吗？
**单例**，每个 Web 应用只有一个 `DispatcherServlet` 实例。它本身是无状态的（状态存储在 Request 作用域中），所以是线程安全的。

### Q2：如果自定义拦截器想要排除某些路径，怎么办？
```java
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(new AuthInterceptor())
                .addPathPatterns("/api/**")
                .excludePathPatterns("/api/login", "/api/register");
    }
}
```

### Q3：@ControllerAdvice 的原理是什么？
`@ControllerAdvice` 本质上是一个 `@Component`，被 `ExceptionHandlerExceptionResolver` 扫描并注册。当 Controller 抛出异常时，`processDispatchResult()` 会调用 `HandlerExceptionResolver`，匹配到对应的 `@ExceptionHandler` 方法。

### Q4：如何自定义参数解析器？
实现 `HandlerMethodArgumentResolver` 接口，注册到 `WebMvcConfigurer.addArgumentResolvers()` 中。

### Q5：Spring MVC 的异步请求（DeferredResult / Callable）原理？
通过 `WebAsyncManager` 管理异步任务。请求线程可以立即释放，业务在另外的线程中执行，完成后通过 `AsyncContext` 返回结果，提升 Tomcat 线程利用率。

---

## 总结

Spring MVC 的核心就一句话：**DispatcherServlet 通过 HandlerMapping 找到处理器，通过 HandlerAdapter 调用处理器，通过 ViewResolver 解析视图，通过拦截器链嵌入横切逻辑。**

理解了这个流程，你不仅会写出更好的 Spring MVC 代码，还能在面试中从容应对各种追问。源码是最好的老师，建议配合源码阅读本文，效果更佳。
