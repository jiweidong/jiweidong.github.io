---
title: 【Java Web 底层】Servlet 规范深度解析：从生命周期到异步 Servlet 与线程模型演进
date: 2026-08-07 08:00:00
tags:
  - Java
  - Servlet
  - Web
  - 面试
categories:
  - Java
  - Web 开发
author: 东哥
---

# 【Java Web 底层】Servlet 规范深度解析：从生命周期到异步 Servlet 与线程模型演进

## 面试官：Spring MVC 的 DispatcherServlet 你天天用，那 Servlet 规范本身你了解多少？

`DispatcherServlet` 本质上就是一个 `Servlet`。Spring MVC、Struts2、任何 Java Web 框架，都跑在 Servlet 规范之上。这篇文章带你从规范层面理解：Servlet 生命周期、线程模型、三大作用域、异步 Servlet，以及 Servlet 3.1 和虚拟线程时代的演进。

## 一、Servlet 是什么：规范 + 容器

Servlet 是 Java EE 定义的 **Web 组件规范**（`jakarta.servlet` 包），核心是 `javax.servlet.Servlet` 接口。Servlet **自己不能运行**，必须由**容器**（Container）托管——Tomcat、Undertow、Jetty 就是 Servlet 容器。

```
浏览器
  │ HTTP 请求
  ▼
Tomcat（Servlet 容器）
  ├── Connector（HTTP 协议解析，NIO）
  └── Container（Servlet 容器）
        ├── Engine → Host → Context（应用）→ Wrapper（Servlet）
```

**面试追问：Servlet 容器和 Spring 容器是同一个东西吗？**

不是。Tomcat 是 Servlet 容器（管理 Servlet 生命周期），Spring 是 IOC 容器（管理 Bean）。Spring MVC 通过 `DispatcherServlet` 这个"桥"把两者串起来：Tomcat 把请求交给 DispatcherServlet，DispatcherServlet 再去 Spring 容器里找 HandlerMapping、HandlerAdapter。

## 二、Servlet 生命周期：5 个阶段

| 阶段 | 方法 | 调用时机 | 次数 |
|------|------|----------|------|
| 加载实例化 | 构造器 | 首次请求或容器启动时（load-on-startup） | 1 |
| 初始化 | `init()` | 实例化后，只调用一次 | 1 |
| 服务 | `service()` | 每次请求 | N |
| 销毁 | `destroy()` | 容器关闭/应用卸载 | 1 |
| 卸载 | GC | destroy 后由 JVM 回收 | 1 |

```java
@WebServlet("/hello")
public class HelloServlet extends HttpServlet {

    @Override
    public void init() {
        // 只执行一次：加载配置、初始化连接池等
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        // 每次 GET 请求执行，注意线程安全！
    }

    @Override
    public void destroy() {
        // 关闭资源
    }
}
```

**核心要点**：
- **Servlet 是单实例多线程**：整个生命周期只有一个 Servlet 实例，多个请求并发调用 `service()` → **必须保证线程安全**（实例字段是共享的！）
- `load-on-startup`：配置后容器启动即初始化，避免首个请求慢

```xml
<servlet>
    <servlet-name>hello</servlet-name>
    <servlet-class>com.example.HelloServlet</servlet-class>
    <load-on-startup>1</load-on-startup>  <!-- 启动时初始化 -->
</servlet>
```

## 三、Servlet 线程模型：阻塞 IO 的经典架构

传统 Servlet（阻塞式）的线程模型：

```
Tomcat 线程池（默认 200 线程）
    ├── 线程1 → 处理请求A（全程占用，直到响应写完）
    ├── 线程2 → 处理请求B
    └── ...
```

**问题**：如果请求里有慢操作（远程调用、查数据库），**线程一直占着等 IO**。200 个线程只能同时处理 200 个请求，高并发下线程池耗尽 → 请求排队 → 雪崩。这就是"**C10K 问题**"在 Java Web 的老版本答案。

Tomcat 演进：
- Tomcat 7 及以前：BIO（阻塞 IO），一个连接一个线程
- Tomcat 8.5+/9：**默认 NIO**（`org.apache.coyote.http11.Http11NioProtocol`），线程只处理"有数据可读写"的连接，空闲连接不占线程
- Tomcat 8.5+ 还提供 NIO2（AIO）和 APR

NIO 模型下，线程数可以远小于连接数：**一个线程处理多个连接**（多路复用）。

## 四、异步 Servlet：Servlet 3.0/3.1 的救赎

NIO 解决了"连接占用线程"，但**业务代码里的阻塞调用**（`restTemplate.call()`、`db.query()`）依然占着线程。异步 Servlet（Servlet 3.0+）就是为了释放这些线程：

```java
@WebServlet(value = "/async", asyncSupported = true)
public class AsyncServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        // 1. 开启异步模式，立即释放容器线程
        AsyncContext ctx = req.startAsync();

        // 2. 把耗时业务丢给业务线程池
        ExecutorService bizPool = ...;
        bizPool.submit(() -> {
            try {
                String result = slowRemoteCall();   // 耗时操作
                resp.getWriter().write(result);     // 业务线程写响应
            } finally {
                ctx.complete();                     // 3. 通知容器响应完成
            }
        });
        // doGet 返回，容器线程立刻回到线程池！💡
    }
}
```

**异步 Servlet 的意义**：
- 容器线程只做"接请求 + 转交 + 返回"（微秒级），不再被慢业务占住
- 高并发 + 慢下游场景，**线程利用率大幅提升**
- 但要注意：异步不等于变快，**吞吐**提升了，**RT（响应时间）**没变

Spring 的 `DeferredResult`、`WebAsyncTask`、`@Async` + Servlet 3.1 就是基于这套机制实现的。

## 五、三大作用域与监听器

| 作用域 | 生命周期 | 典型用途 |
|--------|----------|----------|
| `request` | 一次请求 | 请求参数、临时数据 |
| `session` | 一次会话（默认 30 分钟） | 登录状态、购物车 |
| `application` | 应用生命周期 | 全局配置、计数器 |

监听器（Listener）用于观察生命周期事件：

```java
// 应用启动/关闭
@WebListener
public class AppListener implements ServletContextListener {
    public void contextInitialized(ServletContextEvent sce) {
        // 启动时初始化：加载配置、预热缓存
    }
}
```

`Filter`（过滤器）则是请求链路上的拦截器：**编码处理、登录校验、日志记录**都在这层做，Spring Security 的过滤器链也是挂在 Servlet Filter 上的。

```
请求 → Filter链 → Servlet（DispatcherServlet）→ Controller → 响应
```

## 六、Servlet 4.0/5.0/6.0 与虚拟线程时代

| 版本 | 亮点 |
|------|------|
| Servlet 4.0 | HTTP/2 支持（Java EE 8） |
| Servlet 5.0 | 包名从 `javax.servlet` 改为 `jakarta.servlet`（Jakarta EE 9） |
| Servlet 6.0 | Jakarta EE 10，支持虚拟线程等新特性 |

**虚拟线程（Java 21）对 Servlet 的意义**：Tomcat 10.1+（Servlet 5.0/6.0）支持配置虚拟线程执行器。虚拟线程**极轻量**（几 KB 栈，百万级可创建），阻塞时自动让出载体线程——**用虚拟线程 + 传统阻塞式 Servlet 代码，就能获得异步 Servlet 的吞吐效果，而且代码不用改**！

```yaml
# Spring Boot 3.2 + Tomcat 虚拟线程
spring:
  threads:
    virtual:
      enabled: true
```

这是不是意味着异步 Servlet 过时了？不完全是：虚拟线程让"阻塞式 + 线程池"模型重新焕发生机，但异步编程（WebFlux）在**高密度 IO 场景**仍有其优势。两者不是替代关系，而是各有适用场景。

## 七、面试速答

1. **Servlet 生命周期？** 实例化 → init（一次）→ service（每次请求）→ destroy（一次）→ GC。
2. **Servlet 线程安全吗？** 单实例多线程，实例字段共享，需要自己保证线程安全（尽量无状态）。
3. **Tomcat 为什么能支持高并发？** NIO 多路复用：线程只处理有 IO 事件的连接，一个线程管多个连接。
4. **异步 Servlet 解决什么？** 释放容器线程：容器线程接请求后转交业务线程池立即返回，提升高并发下的吞吐。
5. **虚拟线程和 Servlet？** Tomcat 10.1+ 可配虚拟线程执行器，用阻塞式代码获得高吞吐。

理解了 Servlet 规范，你就理解了 Tomcat、理解了 Spring MVC 的底层、理解了 Java Web 的演进逻辑。这是每个 Java 后端必须夯实的地基。
