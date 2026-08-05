---
title: 【设计模式】责任链模式深度解析：从手写实现到 Spring MVC、Netty、Sentinel 框架落地
date: 2026-08-05 08:00:00
tags:
  - Java
  - 设计模式
  - Spring MVC
  - Netty
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】责任链模式深度解析：从手写实现到 Spring MVC、Netty、Sentinel 框架落地

## 面试官：请求进来要经过 登录校验 → 参数校验 → 权限校验 → 日志记录，你怎么设计？

如果你回答"写一堆 if-else 按顺序调用"，那这道题最多 60 分。面试官真正想听的，是**责任链模式（Chain of Responsibility）**——这是框架源码中出现频率最高的设计模式之一：Servlet 的 Filter 链、Spring MVC 的拦截器链、Netty 的 ChannelPipeline、MyBatis 的拦截器、Sentinel 的 ProcessorSlotChain，全是它的变体。

本文从手写实现讲起，再逐层拆解各大框架的落地方式，最后给出生产实践建议。

<!-- more -->

## 一、什么是责任链模式

**定义**：将请求的发送者与接收者解耦，使多个接收对象都有机会处理请求，将这些对象连成一条链，并沿链传递请求，直到有一个对象处理它为止。

**核心角色**：

- **Handler（抽象处理者）**：定义处理请求的接口，持有下一个处理者的引用
- **ConcreteHandler（具体处理者）**：实现处理逻辑，处理不了就交给下一个
- **Client（客户端）**：组装链条并发起请求

**优点**：

- 请求者与处理者解耦，新增处理者不影响现有代码（开闭原则）
- 可动态调整链条顺序，灵活控制处理流程
- 每个处理者职责单一

**缺点**：

- 调试困难：请求在链上流转，定位问题需要沿链排查
- 性能损耗：每个请求都要走完整条链
- 容易形成"链路过长"的坏味道

## 二、手写一个责任链（经典实现）

以"请假审批"为例：请假 1 天内组长批，3 天内经理批，超过 3 天总监批。

```java
// 1. 抽象处理者
public abstract class Approver {
    protected Approver next;   // 下一个处理者

    public void setNext(Approver next) {
        this.next = next;
    }

    public abstract void approve(int days);
}

// 2. 具体处理者：组长
public class GroupLeader extends Approver {
    @Override
    public void approve(int days) {
        if (days <= 1) {
            System.out.println("组长审批通过：" + days + " 天");
        } else if (next != null) {
            next.approve(days);
        }
    }
}

// 3. 具体处理者：经理
public class Manager extends Approver {
    @Override
    public void approve(int days) {
        if (days <= 3) {
            System.out.println("经理审批通过：" + days + " 天");
        } else if (next != null) {
            next.approve(days);
        }
    }
}

// 4. 具体处理者：总监
public class Director extends Approver {
    @Override
    public void approve(int days) {
        System.out.println("总监审批通过：" + days + " 天");
    }
}

// 5. 客户端：组装链条
public class Client {
    public static void main(String[] args) {
        Approver leader = new GroupLeader();
        Approver manager = new Manager();
        Approver director = new Director();

        leader.setNext(manager);   // 组长 → 经理
        manager.setNext(director); // 经理 → 总监

        leader.approve(1);   // 组长审批通过：1 天
        leader.approve(2);   // 经理审批通过：2 天
        leader.approve(10);  // 总监审批通过：10 天
    }
}
```

### 变体一：终止链与全链路

上面是"**找到一个处理者就停止**"的模式。还有一种"**每个节点都处理**"的模式（如日志过滤器、审计记录），请求走完整个链，每个节点只负责自己的那一段逻辑。Servlet Filter 就是这种。

### 变体二：函数式/责任链（现代写法）

Java 8 之后，可以用 `Function` 和 `UnaryOperator` 组合出优雅的责任链：

```java
public class Pipeline {
    public static void main(String[] args) {
        UnaryOperator<String> trim = String::trim;
        UnaryOperator<String> lower = String::toLowerCase;
        UnaryOperator<String> replace = s -> s.replace(" ", "-");

        UnaryOperator<String> pipeline = trim.andThen(lower).andThen(replace);
        System.out.println(pipeline.apply("  Hello World  ")); // hello-world
    }
}
```

## 三、框架源码中的责任链

### 3.1 Servlet Filter 链

Java Web 开发最早接触的责任链。`Filter` 通过 `FilterChain` 串联：

```java
public interface Filter {
    void doFilter(ServletRequest request, ServletResponse response,
                  FilterChain chain);
}

public interface FilterChain {
    void doFilter(ServletRequest request, ServletResponse response);
}
```

Tomcat 的 `ApplicationFilterChain` 内部维护一个 `Filter[] filters` 数组和游标 `pos`：

```java
private void internalDoFilter(ServletRequest request, ServletResponse response) {
    if (pos < n) {                              // 还有下一个 Filter
        Filter filter = filters[pos++];
        filter.doFilter(request, response, this); // 递归调用链本身
        return;
    }
    // 链走完了，交给 Servlet 处理
    servlet.service(request, response);
}
```

**关键点**：每个 Filter 处理完自己的逻辑后，调用 `chain.doFilter()` 把请求交给下一个；如果某个 Filter 不调用 `chain.doFilter()`，链路就**在这里截断**（常用于登录校验拦截）。

### 3.2 Spring MVC 拦截器链

Spring MVC 的 `HandlerExecutionChain` 是 Filter 的"兄弟"，区别在于：

| 对比项 | Servlet Filter | Spring MVC Interceptor |
|--------|---------------|----------------------|
| 作用范围 | 所有 Servlet 请求 | 仅 Spring MVC 的 Handler 请求 |
| 执行时机 | Controller 之前 | 方法执行前/后/完成后 |
| 是否可拿到 Model | ❌ | ✅（`postHandle` 可操作 ModelAndView） |
| 依赖容器 | Servlet 容器 | Spring 容器 |

`HandlerInterceptor` 三个回调方法对应请求的三个阶段：

```java
public interface HandlerInterceptor {
    // 目标方法执行前，返回 false 则截断请求
    default boolean preHandle(HttpServletRequest request,
                              HttpServletResponse response, Object handler) {
        return true;
    }
    // 目标方法执行后、视图渲染前
    default void postHandle(...) { }
    // 整个请求完成后（含异常），常用于资源清理
    default void afterCompletion(...) { }
}
```

DispatcherServlet 中通过 `mappedHandler.applyPreHandle()` 循环执行拦截器链，任何一个 `preHandle` 返回 false 就中断并触发已执行拦截器的 `afterCompletion` 逆序回调。

### 3.3 Netty 的 ChannelPipeline

Netty 把责任链模式发挥到极致：入站（Inbound）事件从 Head 流向 Tail，出站（Outbound）事件反向流动，每个 `ChannelHandler` 是一个节点：

```java
public class MyHandler extends ChannelInboundHandlerAdapter {
    @Override
    public void channelRead(ChannelHandlerContext ctx, Object msg) {
        // 处理业务
        ctx.fireChannelRead(msg);  // 传递给下一个 Inbound Handler
    }
}
```

`ctx.fireChannelRead()` 就是"交给链上下一个节点"的调用，对应 Filter 的 `chain.doFilter()`。Pipeline 默认头尾是 `HeadContext` 和 `TailContext`，业务 Handler 插入中间。**粘包拆包编解码器（LengthFieldBasedFrameDecoder 等）就是通过这种链式结构组合的。**

### 3.4 Sentinel 的 ProcessorSlotChain

阿里 Sentinel 的限流降级核心就是一条责任链，每个 Slot 负责一个维度的检查：

```
NodeSelectorSlot → ClusterBuilderSlot → LogSlot → StatisticSlot
→ AuthoritySlot → SystemSlot → FlowSlot → DegradeSlot
```

- `FlowSlot`：流量控制（限流）
- `DegradeSlot`：熔断降级
- `SystemSlot`：系统自适应保护

新增一个规则检查维度，只需实现 `ProcessorSlot` 接口插入链中，完全符合开闭原则。

### 3.5 MyBatis 拦截器

MyBatis 的 `Interceptor` 可以拦截 `Executor`、`StatementHandler`、`ParameterHandler`、`ResultSetHandler` 四大对象的方法，多个拦截器通过 `InterceptorChain` 代理嵌套串联——本质也是责任链（代理链）。

## 四、责任链 vs 其他模式的对比

| 对比项 | 责任链 | 策略模式 | 模板方法 |
|--------|--------|---------|---------|
| 核心思想 | 请求沿链传递，多处理者接力 | 算法可替换，互斥选择 | 骨架固定，步骤可定制 |
| 关系 | 处理者之间有前后关系 | 策略之间是平级的 | 父类定骨架，子类实现 |
| 典型场景 | 过滤器、审批流 | 支付方式、排序器 | AQS、JdbcTemplate |

## 五、生产实践建议

1. **控制链长度**：节点过多（>10）时拆链或引入编排框架
2. **统一异常处理**：每个节点 try-catch 后沿链传递异常信息，或定义"终止异常"快速中断
3. **支持动态组装**：把链条的组装从代码挪到配置（Spring 中按 `@Order` 排序注入 `List<Handler>`）：

```java
// Spring 中优雅地收集链上所有处理器
@Component
public class OrderHandlerChain {
    private final List<OrderHandler> handlers;

    public OrderHandlerChain(List<OrderHandler> handlers) {
        // Spring 自动按 @Order 排序注入
        this.handlers = handlers.stream()
            .sorted(Comparator.comparingInt(h -> h.getOrder()))
            .toList();
    }

    public void handle(Order order) {
        for (OrderHandler handler : handlers) {
            if (!handler.handle(order)) break;  // 任一节点拒绝即终止
        }
    }
}
```

4. **注意线程安全**：链上的处理器如果是无状态单例，可以安全共享；有状态则要小心。

## 六、面试追问总结

1. **责任链和 if-else 有什么区别？** → 解耦 + 开闭原则 + 可动态编排
2. **Filter 和 Interceptor 的区别？** → 作用域、时机、能否操作 ModelAndView
3. **如何实现"全链路过 + 某节点中断"？** → 节点返回值/异常控制链的继续与否
4. **Netty Pipeline 为什么是责任链？** → 事件沿链传播，Handler 可插拔
5. **责任链有什么缺点？** → 调试难、性能损耗、链过长难维护

## 七、总结

责任链模式是"**把 if-else 的接力判断拆成可插拔的节点**"。理解了它的本质——每个节点持有下一个节点的引用，请求沿链传递——再看 Spring MVC 拦截器、Netty Pipeline、Sentinel Slot 链，会发现全是同一套思想的变体。面试时能从一个手写 Demo 延伸到框架源码对比，这道题就稳了。
