---
title: 【设计模式】策略模式深度解析：干掉 if-else 的优雅之道与 Spring 实践
date: 2026-08-05 08:00:00
tags:
  - Java
  - 设计模式
  - Spring
  - 重构
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】策略模式深度解析：干掉 if-else 的优雅之道与 Spring 实践

## 面试官：支付系统支持支付宝、微信、银行卡，代码怎么设计？

初级答案：一个 `pay()` 方法里写 if-else 判断渠道类型。高级答案：**策略模式 + 工厂 + Spring 注入**。本文从最原始的 if-else 出发，一步步重构出生产级策略模式实现，并剖析 JDK 和 Spring 源码中的策略模式应用。

<!-- more -->

## 一、什么是策略模式

**定义**：定义一系列算法，把它们一个个封装起来，并且使它们可以相互替换。策略模式让算法的变化独立于使用算法的客户。

**核心角色**：

- **Strategy（抽象策略）**：定义算法的公共接口
- **ConcreteStrategy（具体策略）**：实现具体算法
- **Context（上下文）**：持有 Strategy 引用，负责调用策略

**适用场景**：

- 同一行为有多种实现方式且可替换（支付、排序、压缩、限流算法）
- 大量 if-else / switch-case 分支，每个分支是一个算法
- 需要在运行时动态选择算法

## 二、从 if-else 到策略模式的重构之路

### 第一步：原始的 if-else

```java
public class PaymentService {
    public void pay(String channel, double amount) {
        if ("alipay".equals(channel)) {
            System.out.println("支付宝支付：" + amount);
        } else if ("wechat".equals(channel)) {
            System.out.println("微信支付：" + amount);
        } else if ("bankcard".equals(channel)) {
            System.out.println("银行卡支付：" + amount);
        } else {
            throw new IllegalArgumentException("不支持的支付渠道：" + channel);
        }
    }
}
```

**痛点**：

- 每新增一个渠道就要改这个方法 → 违反开闭原则
- 方法越来越长，可读性差
- 多个方法需要按渠道分支时（支付、退款、对账），if-else 要重复写 N 遍

### 第二步：策略模式基本版

```java
// 1. 抽象策略
public interface PayStrategy {
    void pay(double amount);
}

// 2. 具体策略：支付宝
public class AlipayStrategy implements PayStrategy {
    @Override
    public void pay(double amount) {
        System.out.println("支付宝支付：" + amount);
    }
}

// 3. 具体策略：微信
public class WechatPayStrategy implements PayStrategy {
    @Override
    public void pay(double amount) {
        System.out.println("微信支付：" + amount);
    }
}

// 4. 上下文：面向接口编程
public class PaymentContext {
    private final PayStrategy strategy;

    public PaymentContext(PayStrategy strategy) {
        this.strategy = strategy;
    }

    public void executePay(double amount) {
        strategy.pay(amount);
    }
}

// 5. 客户端使用
public class Client {
    public static void main(String[] args) {
        PayStrategy strategy = new AlipayStrategy();   // 策略可替换
        PaymentContext context = new PaymentContext(strategy);
        context.executePay(100.0);
    }
}
```

### 第三步：结合简单工厂（生产常用组合）

策略模式 + 工厂，解决"客户端怎么选策略"的问题：

```java
public class PayStrategyFactory {
    private static final Map<String, PayStrategy> STRATEGIES = Map.of(
        "alipay", new AlipayStrategy(),
        "wechat", new WechatPayStrategy(),
        "bankcard", new BankCardPayStrategy()
    );

    public static PayStrategy getStrategy(String channel) {
        PayStrategy strategy = STRATEGIES.get(channel);
        if (strategy == null) {
            throw new IllegalArgumentException("不支持的支付渠道：" + channel);
        }
        return strategy;
    }
}

// 使用
PayStrategy strategy = PayStrategyFactory.getStrategy("alipay");
new PaymentContext(strategy).executePay(100.0);
```

### 第四步：枚举 + 函数式接口（最简洁版）

如果策略只有一个方法，用枚举 + `Function` 能写得非常精简：

```java
public enum PayChannel {
    ALIPAY(amount -> System.out.println("支付宝支付：" + amount)),
    WECHAT(amount -> System.out.println("微信支付：" + amount)),
    BANKCARD(amount -> System.out.println("银行卡支付：" + amount));

    private final Consumer<Double> handler;

    PayChannel(Consumer<Double> handler) {
        this.handler = handler;
    }

    public void pay(double amount) {
        handler.accept(amount);
    }
}

// 使用：枚举自带查找与校验
PayChannel.ALIPAY.pay(100.0);
```

## 三、Spring 中的策略模式实践

### 3.1 注入 Map<String, Strategy>，干掉工厂

Spring 最优雅的用法：把策略 Bean 按名称注入成一个 `Map`，key 就是 Bean 名字：

```java
// 策略接口
public interface PayStrategy {
    String getChannel();   // 渠道标识
    void pay(double amount);
}

// 具体策略：标注为 Spring Bean
@Component
public class AlipayStrategy implements PayStrategy {
    @Override
    public String getChannel() { return "alipay"; }

    @Override
    public void pay(double amount) {
        System.out.println("支付宝支付：" + amount);
    }
}

@Component
public class WechatPayStrategy implements PayStrategy {
    @Override
    public String getChannel() { return "wechat"; }

    @Override
    public void pay(double amount) {
        System.out.println("微信支付：" + amount);
    }
}

// 核心：注入所有策略
@Service
public class PaymentService {
    private final Map<String, PayStrategy> strategyMap;

    // Spring 自动把容器中所有 PayStrategy Bean 按名称注入 Map
    public PaymentService(Map<String, PayStrategy> strategyMap) {
        this.strategyMap = strategyMap;
    }

    public void pay(String channel, double amount) {
        PayStrategy strategy = strategyMap.get(channel);
        if (strategy == null) {
            throw new IllegalArgumentException("不支持的支付渠道：" + channel);
        }
        strategy.pay(amount);
    }
}
```

**注意**：`Map<String, PayStrategy>` 的 key 默认是 Bean 名（`alipayStrategy`、`wechatPayStrategy`），不是策略里的 `getChannel()`。更规范的做法是配合 `@Service("alipay")` 显式指定 Bean 名，或在构造时用 `Collectors.toMap(PayStrategy::getChannel, s -> s)` 转换。

### 3.2 结合枚举管理元信息

```java
public enum PayType {
    ALIPAY("alipay", "支付宝"),
    WECHAT("wechat", "微信"),
    BANKCARD("bankcard", "银行卡");

    private final String code;
    private final String desc;
    // 构造器、getter...
}
```

前端传 code，后端查枚举校验合法性，再从 Map 取策略执行，三段式非常清晰。

## 四、JDK 源码中的策略模式

| JDK 类 | 策略体现 |
|--------|---------|
| `java.util.Comparator` | 排序策略可替换，`Collections.sort(list, comparator)` |
| `ThreadPoolExecutor` | `RejectedExecutionHandler` 拒绝策略：AbortPolicy、CallerRunsPolicy、DiscardPolicy 等 |
| `ThreadLocal` 的 `ThreadLocalMap` 不便举例？ | 不展开 |
| `java.util.regex` 无需 | 不展开 |
| `ResourceBundle` | 不同 Locale 的策略选择 |

重点看**线程池拒绝策略**——4 种策略就是策略模式的教科书：

```java
// 策略接口
public interface RejectedExecutionHandler {
    void rejectedExecution(Runnable r, ThreadPoolExecutor executor);
}

// 策略1：直接抛异常（默认）
public static class AbortPolicy implements RejectedExecutionHandler {
    public void rejectedExecution(Runnable r, ThreadPoolExecutor e) {
        throw new RejectedExecutionException("Task " + r.toString() +
                                             " rejected from " + e.toString());
    }
}

// 策略2：调用者线程执行（降低提交速度）
public static class CallerRunsPolicy implements RejectedExecutionHandler {
    public void rejectedExecution(Runnable r, ThreadPoolExecutor e) {
        if (!e.isShutdown()) {
            r.run();
        }
    }
}
```

`ThreadPoolExecutor` 构造器接收 `RejectedExecutionHandler` 参数，运行时也可通过 `setRejectedExecutionHandler()` 动态替换——完全符合策略模式"算法可替换"的定义。

## 五、策略模式 vs 状态模式 vs 策略模式 vs 责任链

| 对比项 | 策略模式 | 状态模式 | 责任链模式 |
|--------|---------|---------|-----------|
| 关注点 | 算法替换 | 状态流转 | 请求传递 |
| 对象关系 | 平级、互斥 | 状态间可切换 | 前后串联 |
| 谁决定行为 | 客户端/上下文选择 | 状态自身驱动 | 链上节点接力 |
| 典型场景 | 支付、排序 | 订单状态机 | 过滤器链 |

**记忆口诀**：策略"选一个用"，状态"换着用"，责任链"挨个试"。

## 六、生产实践建议

1. **策略一定要有兜底**：`Map.get()` 不到时抛明确异常，或用"默认策略"（如 `UnknownStrategy`）
2. **策略对象尽量无状态**：有状态策略要保证线程安全，因为单例 Bean 会被并发共享
3. **配合校验**：渠道参数入库前用枚举校验，避免脏数据
4. **不要过度设计**：分支只有两三个且不会扩展时，直接 if-else 反而更清晰

## 七、面试追问总结

1. **策略模式和 if-else 相比有什么好处？** → 开闭原则、消除重复分支、策略可独立测试
2. **策略模式和工厂模式的区别？** → 工厂负责"创建对象"，策略负责"封装算法"；常组合使用
3. **Spring 中如何优雅落地策略模式？** → `Map<String, Strategy>` 注入 + `@Component` 自动注册
4. **策略模式和状态模式怎么区分？** → 策略互斥可替换；状态有流转关系
5. **JDK 里有哪些策略模式的应用？** → Comparator、线程池拒绝策略、`ConcurrentHashMap` 扩容策略（触发阈值）

## 八、总结

策略模式的核心价值就一句话：**把变化的算法封装成可替换的策略，把 if-else 的分支判断收敛到一次查找**。再配合 Spring 的 `Map` 注入和枚举管理，就能写出"新增一个支付渠道只需新增一个类"的优雅代码。面试时从支付案例讲起，再抛 JDK 的拒绝策略和 Spring 注入技巧，深度立刻拉满。
