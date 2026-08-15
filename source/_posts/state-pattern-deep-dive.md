---
title: 【设计模式】状态模式深度解析：从有限状态机到订单状态流转实战
date: 2026-08-15 08:00:00
tags:
  - Java
  - 设计模式
  - 状态机
  - 面试
categories:
  - Java
  - 设计模式
  - 后端面试
author: 东哥
---

# 【设计模式】状态模式深度解析：从有限状态机到订单状态流转实战

## 面试官：订单状态流转你怎么写？if-else 套 if-else ？听说过状态模式吗？

"订单状态"是后端面试必考的代码设计题。最朴素的写法是：

```java
if (status == 1) {          // 待支付
    if (action == "pay") { status = 2; ... }
} else if (status == 2) {   // 已支付
    if (action == "cancel") { status = 3; ... }
}
```

状态一多、动作一多，这个方法就变成几百行的"屎山"。**状态模式（State Pattern）**就是为了优雅解决"对象的行为随内部状态变化而变化"这类问题而生的。

## 一、状态模式的定义与核心思想

> **允许一个对象在其内部状态改变时改变它的行为，对象看起来好像修改了它的类。** —— GoF

### 1.1 核心角色

| 角色 | 说明 | 订单例子 |
|------|------|----------|
| Context（上下文） | 持有当前状态对象，对外暴露状态流转入口 | `Order` |
| State（抽象状态） | 定义状态相关行为的接口 | `OrderState` 接口 |
| ConcreteState（具体状态） | 实现具体状态下的行为，并负责状态切换 | `PendingPayState`、`PaidState` 等 |

### 1.2 与传统 if-else 的本质区别

- **if-else 方案**：行为逻辑散落在 Context 的一个方法里，状态判断与业务动作强耦合，加状态/加动作都要改主方法；
- **状态模式**：把"某个状态下能做什么、做什么后转到哪个状态"**封装到状态对象自身**，Context 只做委托。新增状态只需新增一个类，符合开闭原则。

## 二、订单状态机实战：从需求到代码

### 2.1 需求定义

以一个典型电商订单为例，状态与动作定义如下：

| 当前状态 | 允许动作 | 目标状态 |
|----------|----------|----------|
| 待支付（PENDING_PAY） | 支付 pay() | 已支付（PAID） |
| 待支付（PENDING_PAY） | 取消 cancel() | 已取消（CANCELLED） |
| 已支付（PAID） | 发货 ship() | 已发货（SHIPPED） |
| 已发货（SHIPPED） | 确认收货 confirm() | 已完成（COMPLETED） |
| 已完成（COMPLETED） | 申请售后 afterSale() | 售后中（AFTER_SALE） |

**非法动作**（如：待支付状态直接发货）必须抛出明确异常，不能静默失败。

### 2.2 状态接口：每个状态都能处理所有动作

```java
public interface OrderState {
    // 支付
    void pay(OrderContext ctx);
    // 取消
    void cancel(OrderContext ctx);
    // 发货
    void ship(OrderContext ctx);
    // 确认收货
    void confirm(OrderContext ctx);
    // 申请售后
    void afterSale(OrderContext ctx);
}
```

### 2.3 具体状态类

```java
public class PendingPayState implements OrderState {
    @Override
    public void pay(OrderContext ctx) {
        System.out.println("支付成功，订单进入【已支付】状态");
        ctx.setState(new PaidState());          // 状态切换由状态对象自己完成
    }
    @Override
    public void cancel(OrderContext ctx) {
        System.out.println("订单已取消");
        ctx.setState(new CancelledState());
    }
    @Override
    public void ship(OrderContext ctx) {
        throw new IllegalStateException("待支付订单不能发货");
    }
    @Override
    public void confirm(OrderContext ctx) {
        throw new IllegalStateException("待支付订单不能确认收货");
    }
    @Override
    public void afterSale(OrderContext ctx) {
        throw new IllegalStateException("待支付订单不能申请售后");
    }
}
```

### 2.4 Context：持有状态并委托

```java
public class OrderContext {
    private OrderState state;   // 当前状态

    public OrderContext() {
        this.state = new PendingPayState();  // 初始状态
    }

    public void setState(OrderState state) {
        this.state = state;
    }

    // 对外只需暴露动作方法，内部全部委托给当前状态对象
    public void pay()      { state.pay(this); }
    public void cancel()   { state.cancel(this); }
    public void ship()     { state.ship(this); }
    public void confirm()  { state.confirm(this); }
    public void afterSale(){ state.afterSale(this); }
}
```

### 2.5 使用效果

```java
OrderContext order = new OrderContext();   // 待支付
order.pay();                               // 支付成功，进入已支付
order.ship();                              // 发货
order.confirm();                           // 完成
order.ship();                              // ❌ IllegalStateException：已完成订单不能发货
```

**收益对比**：如果新增一个"退款中"状态，只需新增 `RefundingState` 类并在相关状态里补流转，**一行都不用改已有状态类之外的主流程**。而 if-else 方案要在主方法里新增分支，还容易漏。

## 三、状态模式 vs 策略模式：别搞混

两者结构几乎一样（都是"持有接口 + 委托"），这是面试最爱考的辨析题：

| 对比维度 | 状态模式 | 策略模式 |
|----------|----------|----------|
| 关注点 | 对象内部**状态**及其流转 | 算法的**替换** |
| 状态对象关系 | 状态之间**会互相切换**（持有 Context 引用） | 策略之间**互相独立**，不关心彼此 |
| 是否改变行为 | 状态变化导致对象行为整体改变 | 行为由调用方主动选择，对象本身不变 |
| 典型场景 | 订单状态机、电梯状态、TCP 连接状态 | 排序算法、支付渠道、压缩算法 |

一句话记忆：**策略是"换工具"，状态是"变身"**。

## 四、状态模式的进阶演进

### 4.1 用 Map 实现"状态 + 动作 → 下一状态"的查表法

纯状态模式类会膨胀（N 个状态 × M 个动作 = N 个类各写 M 个方法）。很多生产项目直接用**状态转移表**：

```java
public class OrderStateMachine {
    // 状态转移表：key = 状态+动作，value = 目标状态
    private static final Map<String, OrderStatus> TRANSITIONS = new HashMap<>();

    static {
        TRANSITIONS.put("PENDING_PAY:pay", OrderStatus.PAID);
        TRANSITIONS.put("PENDING_PAY:cancel", OrderStatus.CANCELLED);
        TRANSITIONS.put("PAID:ship", OrderStatus.SHIPPED);
        TRANSITIONS.put("SHIPPED:confirm", OrderStatus.COMPLETED);
        TRANSITIONS.put("COMPLETED:afterSale", OrderStatus.AFTER_SALE);
    }

    public OrderStatus next(OrderStatus current, String action) {
        OrderStatus next = TRANSITIONS.get(current.name() + ":" + action);
        if (next == null) {
            throw new IllegalStateException("非法状态流转: " + current + " -> " + action);
        }
        return next;
    }
}
```

查表法适合状态动作多、但**每个流转动作简单**的场景；如果每个状态切换还伴随复杂的业务副作用，状态模式更合适，二者也常结合（查表 + 策略执行动作）。

### 4.2 与 Spring 整合：State 对象交给容器管理

```java
@Component
public class OrderContext {
    private final Map<OrderStatus, OrderState> stateMap;

    // Spring 自动注入所有 OrderState 实现
    public OrderContext(List<OrderState> states) {
        this.stateMap = states.stream()
            .collect(Collectors.toMap(OrderState::getStatus, Function.identity()));
    }
}
```

### 4.3 生产级选择：Spring Statemachine / Cola StateMachine

涉及**事件、守卫条件（guard）、动作（action）、多级状态**的复杂状态机，建议直接用成熟框架：

- **Spring Statemachine**：与 Spring 生态无缝集成，支持分层、持久化、正交区域；
- **阿里 Cola StateMachine（COLA）**：轻量，基于状态+事件+条件+动作建模，社区广泛使用。

```java
// COLA 状态机示例
StateMachineBuilder<OrderStatus, OrderEvent, OrderContext> builder =
        StateMachineBuilderFactory.create();
builder.externalTransition()
       .from(OrderStatus.PENDING_PAY).to(OrderStatus.PAID)
       .on(OrderEvent.PAY)
       .when(ctx -> ctx.getAmount() > 0)        // guard 条件
       .perform(ctx -> System.out.println("扣减库存、发支付成功消息"));  // action
StateMachine<OrderStatus, OrderEvent, OrderContext> sm = builder.build();
sm.fireEvent(OrderStatus.PENDING_PAY, OrderEvent.PAY, ctx);
```

## 五、面试常见追问

**Q1：状态模式和策略模式结构这么像，怎么区分？**
看状态对象之间是否互相切换、是否持有 Context。状态模式的状态会流转（"变身"），策略模式的策略彼此独立（"换工具"）。

**Q2：状态模式有什么缺点？**
每个状态一个类，状态多时类数量膨胀；且状态转换逻辑分散在各状态类中，全局流转关系不够直观（可用状态转移表/框架弥补）。

**Q3：状态判断的 if-else 能不能完全不用？**
能。状态模式把"判断"变成了"多态分派"——但注意，每个具体状态内部如果还有复杂分支，依然要写得干净，别把 if-else 换个地方堆。

**Q4：分布式环境下订单状态机要注意什么？**
状态流转必须**原子性 + 幂等**：用数据库乐观锁（`update ... where status = ?`）或分布式锁保证并发下不会出现"状态错乱"；重试消息要幂等处理，防止重复支付/重复发货。

## 六、小结

状态模式的核心价值是**把"状态相关的行为"从 if-else 中解放出来，交给多态**。它适合：对象行为随状态变化、状态可枚举、状态切换规则复杂且易扩展的场景——订单、审批流、TCP 连接、电梯、游戏角色状态都是经典应用。面试时能画出状态转移表、写出状态模式代码、说清与策略模式的区别、再补一句"生产上复杂状态机用 Spring Statemachine / COLA"，就是一份高分答案。
