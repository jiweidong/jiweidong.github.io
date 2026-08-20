---
title: 【Java 安全】内存马原理与攻防实战：从动态注册到检测防御
date: 2026-08-20 08:00:00
tags:
  - Java
  - 安全
  - Tomcat
  - Spring
categories:
  - Java
  - 安全
author: 东哥
---

# 【Java 安全】内存马原理与攻防实战：从动态注册到检测防御

## 引言：为什么"文件马"正在被"内存马"取代？

传统 WebShell 是往服务器写一个 `.jsp` 文件，落地即留痕：文件扫描、杀软查杀、文件完整性校验都能发现。而**内存马（Memory Shell）不落地任何文件**——恶意代码直接注入到运行中的 JVM 内存里，以 Tomcat/Spring 容器内部的组件形态存活。

文件系统里什么都没有，常规文件查杀完全失效；进程重启后内存马消失，也增加了取证难度。这就是为什么近年来攻防演练（红蓝对抗）中内存马成为主流武器。本文从原理讲透三类主流内存马，再给出检测与防御的完整方案。

## 一、内存马的原理基础

内存马的本质是：**向运行中的 Web 容器动态注册一个"请求处理器"**，让特定 URL（或 Header）的请求被它接管执行任意命令。

要实现这一点，需要三个前提：

1. **能拿到容器组件的注册入口**（Tomcat 的 Mapper/Context、Spring 的 HandlerMapping）
2. **能执行任意代码**（通常先通过反序列化、JNDI 注入、表达式注入等漏洞拿到代码执行权限）
3. **代码注入后能常驻**（利用 ClassLoader 加载恶意类，且不被 GC）

下面以最常见的 Tomcat 为例，看注册入口在哪。

## 二、三类主流内存马原理

### 2.1 Filter 型内存马（最常见）

Tomcat 处理请求的管道是：`Connector → Engine → Host → Context → FilterChain → Servlet`。其中 **Filter 在 Servlet 之前执行**，且 Filter 列表存在 `Context` 的 `filterMaps` 和 `filterDefs` 中——这两个 Map 是可以在运行时**动态添加**的。

```java
// 核心思路：拿到 StandardContext，动态 addFilter + 添加 FilterMap
public class FilterShellInjector {

    public static void inject() throws Exception {
        // 1. 从当前线程拿到 StandardContext（Tomcat 上下文）
        StandardContext context = getStandardContext();

        // 2. 创建恶意 Filter
        FilterDef filterDef = new FilterDef();
        filterDef.setFilterName("shellFilter");
        filterDef.setFilterClass(EvilFilter.class.getName());
        filterDef.setFilter(new EvilFilter());

        // 3. 注册 FilterDef 和 FilterMap（拦截 /*）
        context.addFilterDef(filterDef);
        FilterMap filterMap = new FilterMap();
        filterMap.setFilterName("shellFilter");
        filterMap.addURLPattern("/*");
        context.addFilterMap(filterMap);
    }

    static class EvilFilter implements Filter {
        @Override
        public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain) {
            // 特定参数触发命令执行，否则放行
            String cmd = req.getParameter("cmd");
            if (cmd != null) {
                // 执行命令并写回响应（此处省略命令执行细节）
                chain.doFilter(req, res);
            } else {
                chain.doFilter(req, res);
            }
        }
    }
}
```

**为什么 Filter 型最流行**：`/*` 拦截一切请求，隐蔽性好（正常请求照常放行），且 addFilter 的 API 是 Tomcat 公开的，不需要反射 Hack 内部私有字段。

### 2.2 Servlet 型内存马

原理与 Filter 类似：往 `StandardContext` 的 `children` 里 addChild 一个 Wrapper（Servlet 包装），并映射 URL。Servlet 型的问题是要占用一个 URL 路径，隐蔽性略差，且部分版本需要手动设置 Servlet 的 class 加载。

### 2.3 Spring 型内存马（Controller/Interceptor）

Spring MVC 应用不走 Tomcat 的 Servlet 管道注册也可以——直接往 Spring 容器注册组件：

```java
// 核心思路：往 RequestMappingHandlerMapping 里注册一个动态 Controller
public class SpringShellInjector {

    public static void inject(ApplicationContext ctx) throws Exception {
        RequestMappingHandlerMapping mapping = ctx.getBean(RequestMappingHandlerMapping.class);

        // 通过 RequestMappingHandlerMapping 的 registerMapping 注册动态方法
        Method method = SpringShellInjector.class.getMethod("shell", HttpServletRequest.class, HttpServletResponse.class);
        RequestMappingInfo info = RequestMappingInfo.paths("/api/shell").build();

        mapping.registerMapping(info, new SpringShellInjector(), method);
    }

    public void shell(HttpServletRequest request, HttpServletResponse response) throws Exception {
        String cmd = request.getParameter("cmd");
        if (cmd != null) {
            // 命令执行...
        }
    }
}
```

Spring 型内存马的好处：注册后就是一个"正常"的 Spring MVC Controller，`@RequestMapping` 映射表里多了一条，从 Filter 层看完全无异常，隐蔽性更强。

### 2.4 其他变种

- **Listener 型**：注册 `ServletRequestListener`，每次请求触发
- **Agent 型**：通过 Java Agent 的 retransform 篡改现有类字节码（如改 `org.apache.catalina.core.ApplicationFilterChain`），最隐蔽也最难写
- **WebSocket 型**：注册 WebSocket 端点作为指令通道

## 三、实战攻防：攻击链路与检测方法

### 3.1 完整攻击链

```
1. 漏洞入口（反序列化 / JNDI / 表达式注入 / 任意文件上传）
        ↓
2. 获取代码执行（通常借助字节码加载：defineClass / BCEL / 恶意 ClassLoader）
        ↓
3. 注入内存马（Filter/Servlet/Spring Controller 注册）
        ↓
4. 访问 shell URL 持续控制（可加密混淆流量）
```

关键点：第 2 步的"类加载"环节，攻击者一般通过 `Thread.currentThread().getContextClassLoader()` 拿到 Web 应用的 ClassLoader，保证恶意类能被容器正常加载且不被回收。

### 3.2 检测思路（红队视角反推）

**① 基于行为的检测（流量侧）**

内存马总要通信：特定 URL、特定 Header（如 `cmd` 参数、`X-Options` 头、加密 payload）。WAF/网关侧重点监控：

- 异常参数名（cmd、exec、shell 等高频词）
- 请求与响应内容特征（命令执行回显特征、whoami 等命令指纹）
- 高频访问单一 URL 且参数加密的异常行为

**② 基于容器的检测（内存侧）**

这是最有效的检测方式——直接查容器内部注册表：

```java
// 检测脚本：遍历 Tomcat 的 Filter 列表，比对是否为"已知/预期"的 Filter
StandardContext context = getStandardContext();
ApplicationFilterConfig[] filterConfigs = context.findFilterConfigs();
for (ApplicationFilterConfig fc : filterConfigs) {
    String filterClass = fc.getFilterClass();
    String name = fc.getFilterName();
    // 1. 不在白名单（web.xml/注解配置）里的 Filter = 可疑
    // 2. FilterClass 不在 classpath 任何 jar/classes 中 = 高危
    // 3. 类名混淆、加载器异常 = 高危
    System.out.println(name + " -> " + filterClass);
}
```

同理可以遍历 `RequestMappingHandlerMapping` 的 handlerMethods，检查是否有 handler 对应的类不在代码库中。

**③ 基于 JVM 的检测**

- **ClassLoader 溯源**：正常业务类由 WebAppClassLoader 从应用目录加载；恶意类可能来自自定义 ClassLoader 或反射 defineClass，类文件无对应磁盘路径
- **JSP 预编译残留**：访问过被删 JSP 的编译产物 class 文件会留在 work 目录
- **线程排查**：CPU 高、可疑守护线程（连接外部 C2 的线程）
- **JDK 自带工具**：`jmap -histo` 看可疑类、`jstack` 看线程栈、Arthas `sc`/`jad` 命令排查

### 3.3 防御体系（蓝队视角）

**① 源头治理（最重要）**

- 漏洞修复：反序列化、JNDI、表达式注入是内存马入口，优先封堵
- 依赖安全：升级 Fastjson、Log4j2、Spring 等高风险组件版本
- RASP（Runtime Application Self-Protection）：在 JVM 层拦截 `Filter.addFilterDef`、`defineClass`、`ProcessBuilder` 等敏感 API——**RASP 是目前对抗内存马最有效的技术**，因为它直接阻断"动态注册"这个动作本身

**② 运行时检测**

- 部署内存马检测 Agent（如阿里云、长亭的检测方案），定时比对容器注册表与基线
- 关键业务容器开启 **只读文件系统 + 最小化 JDK**，压缩攻击面
- 禁止应用使用反射调用容器内部 API（可通过 SecurityManager/模块化限制，Java 17+ 可考虑 strong encapsulation 收益）

**③ 响应处置**

- 确认内存马后：`kill -9` 重启进程是唯一彻底的清除手段（内存马不落地，重启即消失）
- 重启前先抓内存快照（`jmap -dump`）、线程栈、进程内存，保留取证
- 排查同类服务器是否也被打（内存马通常批量投放）

## 四、自己动手写个检测 Demo

一个最小可用的 Filter 基线检测（基于 JDK 内置工具思路）：

```bash
# 1. 用 jmap 导出类直方图，找可疑类
jmap -histo <pid> | grep -i "evil\|shell\|filter"

# 2. 用 jstack 找可疑线程（连接外网 IP 的线程）
jstack <pid> > stack.txt
grep -B5 -A20 "RUNNABLE" stack.txt

# 3. 用 Arthas 列出所有 Filter
#    需要先拿到 SpringContext/TomcatContext，再遍历 filterConfigs
```

## 五、面试追问环节

**Q1：内存马为什么不落地文件还能生效？**
答：Java 类加载机制决定了"类不一定来自文件"。`ClassLoader.defineClass()` 可以传入字节数组直接定义类，字节码可以来自网络、反序列化数据甚至恶意类加载器。类被加载进 JVM 后，是否在磁盘上有对应文件并不影响其执行。

**Q2：为什么重启能清除内存马？**
答：内存马的"马"只存在于 JVM 内存（类 + 容器注册表项）。JVM 进程结束，所有类定义和注册的组件随之消失；因为没有落地文件，也没有持久化机制，重启后不会自动复活。

**Q3：Filter 内存马为什么难以被常规安全设备发现？**
答：因为它在"应用容器内部"，请求先经过它再进业务代码，流量层的 WAF 看到的是正常请求形态（恶意触发参数可加密/伪造成正常参数）；文件层完全没有痕迹；只有"容器注册表比对"和"JVM 内存分析"这类检测能看到它。

**Q4：RASP 为什么能防住内存马？**
答：RASP 以 Java Agent 方式注入 JVM，在 `addFilterDef`、`defineClass`、`invoke`、`ProcessBuilder` 等关键方法上做 Hook，动态注册动作一旦发生立即阻断并告警。它和内存马在同一个"内存战场"，所以能看到传统边界设备看不到的东西。

## 总结

内存马是 Java Web 安全攻防的"高阶战场"：攻击者把恶意代码藏进容器内存，绕过文件层防护；防御方则需要"流量行为 + 容器注册表 + JVM 内存"三层联动检测，用 RASP 从源头阻断注入动作。**对于 Java 开发者，理解 Tomcat 的 Filter/Servlet 注册机制、Spring 的 HandlerMapping 结构，不仅是写业务的基础，也是看懂攻防攻防的关键**——防御永远建立在对底层机制的理解之上。
