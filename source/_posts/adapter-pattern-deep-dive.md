---
title: 【设计模式】适配器模式深度解析：从接口兼容到 Spring MVC HandlerAdapter
date: 2026-08-09 08:00:00
tags:
  - Java
  - 设计模式
  - Spring MVC
  - 源码
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】适配器模式深度解析：从接口兼容到 Spring MVC HandlerAdapter

## 面试官：适配器模式和装饰器模式有什么区别？Spring MVC 里的 HandlerAdapter 是适配器吗？

适配器模式（Adapter Pattern）是最「接地气」的设计模式——它解决的就是日常开发里最常见的痛点：**接口不兼容**。充电器转接头、插座转换器、读卡器，全都是适配器。

但面试官不会满足于「转接头」的比喻，他更想听你讲：适配器模式有哪两种实现方式？适配器、装饰器、代理三个模式的区分？以及 Spring MVC 的 `HandlerAdapter` 为什么是适配器模式最经典的框架级应用。

## 一、适配器模式的核心思想

### 1.1 问题场景

```
你的系统里有一个「统一支付接口」：
    interface Payment { void pay(double amount); }

但第三方微信支付 SDK 提供的接口是：
    class WechatPaySDK { void wechatPay(double amount, String appId); }

支付宝 SDK 又是：
    class AlipaySDK { void alipayPay(double amount); }

接口都不兼容，怎么统一调用？
```

直接改 SDK？不行，那是第三方库。让业务代码分别判断？代码里全是 if-else，违反开闭原则。**适配器模式**就是为此而生：写一层适配器，把不兼容的接口「翻译」成统一接口。

### 1.2 三种角色

| 角色 | 说明 | 例子 |
|------|------|------|
| Target（目标接口） | 客户端期望的接口 | Payment |
| Adaptee（被适配者） | 已有的、不兼容的类 | WechatPaySDK |
| Adapter（适配器） | 把 Adaptee 适配成 Target | WechatPayAdapter |

## 二、两种实现方式：类适配器 vs 对象适配器

### 2.1 对象适配器（组合方式，推荐）

```java
// Target：统一支付接口
public interface Payment {
    void pay(double amount);
}

// Adaptee：第三方微信支付 SDK（不能改）
public class WechatPaySDK {
    public void wechatPay(double amount, String appId) {
        System.out.println("微信支付 " + amount + " 元，appId=" + appId);
    }
}

// Adapter：对象适配器（持有 Adaptee 引用，组合方式）
public class WechatPayAdapter implements Payment {
    private final WechatPaySDK wechatPaySDK;
    private final String appId;

    public WechatPayAdapter(WechatPaySDK wechatPaySDK, String appId) {
        this.wechatPaySDK = wechatPaySDK;
        this.appId = appId;
    }

    @Override
    public void pay(double amount) {
        // 把统一接口的调用「翻译」成 SDK 的调用
        wechatPaySDK.wechatPay(amount, appId);
    }
}

// 使用：业务只依赖统一接口
Payment payment = new WechatPayAdapter(new WechatPaySDK(), "wx123456");
payment.pay(99.5);
```

### 2.2 类适配器（继承方式，了解即可）

```java
// 类适配器：继承 Adaptee + 实现 Target（Java 单继承，局限性大）
public class WechatPayClassAdapter extends WechatPaySDK implements Payment {
    @Override
    public void pay(double amount) {
        super.wechatPay(amount, "default-app-id");
    }
}
```

**对比**：

| 维度 | 对象适配器 | 类适配器 |
|------|-----------|---------|
| 实现方式 | 组合（持有引用） | 继承 |
| 灵活性 | 高（可适配多个 Adaptee，可动态换） | 低（单继承，编译期固定） |
| 耦合度 | 低 | 高 |
| 推荐度 | ⭐⭐⭐ 首选 | ⭐ 了解即可 |

**面试重点**：说出「对象适配器优于类适配器，因为组合优于继承，Java 单继承限制了类适配器，而且对象适配器还能适配多个被适配者」，就是加分项。

### 2.3 适配器模式的两类变体

- **默认适配器（Default Adapter）**：接口方法太多，先提供一个空实现的抽象类，子类只重写需要的方法。典型例子是 Java AWT 的 `MouseAdapter`（你只关心 mouseClicked，不用实现全部 5 个方法）。
- **双向适配器**：实现两个接口，两边都能适配，少见但面试可以提。

## 三、Spring MVC 的 HandlerAdapter：适配器模式最佳框架实践

### 3.1 背景：Spring MVC 如何统一处理各种 Handler？

Spring MVC 的 `DispatcherServlet` 要把请求交给 Handler 处理，但 Handler 有各种形态：

- `@Controller` 的方法（`HandlerMethod`）
- `HttpRequestHandler`（如静态资源处理）
- `SimpleControllerHandlerAdapter` 对应的 Controller 接口实现

**DispatcherServlet 不可能为每种 Handler 写一套分发逻辑**，否则加一种 Handler 就要改核心代码。解决方案就是适配器模式：

```
DispatcherServlet
    → getHandler() 找到 Handler（可能是任何形态）
    → 遍历 HandlerAdapter 列表，找到能处理该 Handler 的适配器
    → adapter.handle(request, response, handler) 统一调用
```

### 3.2 源码：HandlerAdapter 接口

```java
// Spring 源码：org.springframework.web.servlet.HandlerAdapter
public interface HandlerAdapter {
    // 1. 判断能否处理该 Handler（适配器匹配）
    boolean supports(Object handler);

    // 2. 统一处理入口（把各种 Handler 翻译成统一调用）
    @Nullable
    ModelAndView handle(HttpServletRequest request, HttpServletResponse response,
                        Object handler) throws Exception;
}
```

### 3.3 三个核心实现类

```java
// ① 处理 @Controller/@RequestMapping 方法 —— 最常用
public class RequestMappingHandlerAdapter implements HandlerAdapter {
    @Override
    public boolean supports(Object handler) {
        return handler instanceof HandlerMethod;   // 只认 HandlerMethod
    }
    @Override
    public ModelAndView handle(HttpServletRequest request, HttpServletResponse response,
                               Object handler) throws Exception {
        // 核心：反射调用 Controller 方法，解析参数、执行拦截器链...
        return invokeHandlerMethod(request, response, (HandlerMethod) handler);
    }
}

// ② 处理 Controller 接口实现类（老式）
public class SimpleControllerHandlerAdapter implements HandlerAdapter {
    @Override
    public boolean supports(Object handler) {
        return (handler instanceof Controller);
    }
    @Override
    public ModelAndView handle(HttpServletRequest request, HttpServletResponse response,
                               Object handler) {
        return ((Controller) handler).handleRequest(request, response);
    }
}

// ③ 处理 HttpRequestHandler（静态资源等）
public class HttpRequestHandlerAdapter implements HandlerAdapter {
    @Override
    public boolean supports(Object handler) {
        return (handler instanceof HttpRequestHandler);
    }
    @Override
    public ModelAndView handle(...) {
        ((HttpRequestHandler) handler).handleRequest(request, response);
        return null;
    }
}
```

### 3.4 为什么说它是适配器模式？

| 模式角色 | HandlerAdapter 对应 |
|----------|---------------------|
| Target | HandlerAdapter 接口（DispatcherServlet 只依赖它） |
| Adapter | RequestMappingHandlerAdapter / SimpleControllerHandlerAdapter 等 |
| Adaptee | HandlerMethod / Controller / HttpRequestHandler（各种不同形态的处理器） |

**精髓**：DispatcherServlet 通过 `supports()` 找到匹配的适配器，再通过统一的 `handle()` 调用——**新增一种 Handler 类型只需新增一个 HandlerAdapter 实现，完全不改 DispatcherServlet**，完美开闭原则。这就是适配器模式在框架中的教科书级应用。

## 四、适配器 vs 装饰器 vs 代理：终极对比

这是结构型设计模式三大高频面试题，必须能对比：

| 维度 | 适配器模式 | 装饰器模式 | 代理模式 |
|------|-----------|-----------|---------|
| 目的 | 让不兼容的接口变得兼容 | 动态增强功能 | 控制访问 |
| 接口 | **改变**接口（把 A 接口转成 B 接口） | **保持**接口不变 | 保持接口不变（通常） |
| 关注点 | 转换、翻译 | 叠加职责 | 权限/延迟/日志等控制 |
| 结构 | Adapter 实现 Target 接口，包装 Adaptee | Decorator 实现 Component 接口，包装 Component | Proxy 实现 Subject 接口，包装 RealSubject |
| 客户端感知 | 感知到接口变了 | 无感知（还是同一接口） | 无感知（看起来是同一对象） |
| 典型例子 | HandlerAdapter、日志门面 SLF4J | Java IO 流、CachingExecutor | JDK 动态代理、Spring AOP |

**一句话记忆**：
- 适配器 = **改接口**（翻译官）
- 装饰器 = **加功能**（化妆师）
- 代理 = **控访问**（经纪人）

## 五、实战：JDK 里的适配器模式

### 5.1 Arrays.asList：数组 → List 的适配

```java
// 数组是 Adaptee，List 是 Target，Arrays.asList 就是适配器
List<String> list = Arrays.asList("a", "b", "c");
// 注意：返回的是 Arrays$ArrayList（适配器），不是 java.util.ArrayList
// 所以不能 add/remove！这就是「适配器的限制」——接口转换后能力以 Target 为准
```

### 5.2 日志门面 SLF4J：适配器模式的伟大应用

```java
// 你的代码只依赖 SLF4J API（Target）
private static final Logger log = LoggerFactory.getLogger(Xxx.class);

// 底层可以是 Logback、Log4j2、JUL（Adaptee）
// slf4j-log4j12.jar、log4j-slf4j-impl.jar 这些就是适配器！
// 换日志框架 = 换适配器 jar 包，业务代码一行不用改
```

### 5.3 IO 流的 InputStreamReader：字节流 → 字符流

```java
// InputStream 是字节流（Adaptee），Reader 是字符流（Target）
// InputStreamReader 就是适配器：把字节流「翻译」成字符流
Reader reader = new InputStreamReader(new FileInputStream("a.txt"), StandardCharsets.UTF_8);
```

**注意区分**：InputStreamReader 是适配器（改变接口：字节→字符），而 BufferedInputStream 是装饰器（保持接口：还是 InputStream，只是加了缓冲）。

## 六、手写实战：统一接入多个第三方支付

```java
// 统一接口（Target）
public interface PaymentGateway {
    void pay(PayRequest request);
}

// 微信适配器
public class WechatAdapter implements PaymentGateway {
    private final WechatPaySDK sdk;
    public WechatAdapter(WechatPaySDK sdk) { this.sdk = sdk; }

    @Override
    public void pay(PayRequest request) {
        sdk.wechatPay(request.getAmount(), request.getAppId());
    }
}

// 支付宝适配器
public class AlipayAdapter implements PaymentGateway {
    private final AlipaySDK sdk;
    public AlipayAdapter(AlipaySDK sdk) { this.sdk = sdk; }

    @Override
    public void pay(PayRequest request) {
        sdk.alipayPay(request.getAmount());
    }
}

// 工厂：根据渠道返回对应适配器（客户端只依赖统一接口）
public class PaymentFactory {
    public static PaymentGateway getGateway(String channel) {
        return switch (channel) {
            case "wechat" -> new WechatAdapter(new WechatPaySDK());
            case "alipay" -> new AlipayAdapter(new AlipaySDK());
            default -> throw new IllegalArgumentException("未知渠道: " + channel);
        };
    }
}

// 使用
PaymentGateway gateway = PaymentFactory.getGateway("wechat");
gateway.pay(new PayRequest(99.5, "wx123"));
```

以后再接入新支付渠道，**只加一个适配器类 + 一行工厂分支**，业务代码零改动。

## 七、总结

| 要点 | 结论 |
|------|------|
| 核心思想 | 把不兼容的接口「翻译」成目标接口 |
| 两种实现 | 对象适配器（组合，推荐）/ 类适配器（继承，少用） |
| 框架实例 | Spring MVC HandlerAdapter（supports + handle） |
| 与其他模式 | 适配器改接口、装饰器加功能、代理控访问 |
| JDK 实例 | Arrays.asList、InputStreamReader、SLF4J 桥接包 |
| 实战价值 | 统一对接第三方 SDK、老系统接口兼容 |

**面试话术**：「适配器模式解决接口不兼容，对象适配器通过组合持有被适配者实现翻译，优于类适配器；Spring MVC 的 HandlerAdapter 是教科书级应用——DispatcherServlet 依赖统一接口，supports() 匹配、handle() 统一调用，新增处理器类型零侵入；它与装饰器的区别是适配器改变接口、装饰器保持接口并增强功能，与代理的区别是适配器解决兼容性、代理控制访问。」一套组合拳打完，结构、源码、对比全覆盖。
