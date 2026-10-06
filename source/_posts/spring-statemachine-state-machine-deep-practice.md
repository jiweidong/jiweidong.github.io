---
title: 【Spring 实战】Spring Statemachine 状态机深度实战：状态流转、持久化与订单履约落地
date: 2026-10-06 08:10:00
tags:
  - Java
  - Spring
  - 状态机
  - 订单
categories:
  - Java
  - Spring 全家桶
author: 东哥
---

# 【Spring 实战】Spring Statemachine 状态机深度实战：状态流转、持久化与订单履约落地

## 面试官：订单状态流转，你是怎么实现的？

很多人回答："数据库里存个 `status` 字段，业务代码里 `if (status == 1) { status = 2; }`。"

面试官接着问："那如果状态有 8 个、事件有 15 个，谁来保证不会出现 `已取消 → 已支付` 这种非法流转？加了多少个 if？"

这时候"状态机"就是标准答案。而 Spring 生态里最正统的实现，就是 **Spring Statemachine**。

---

## 一、为什么需要状态机

先看手写 if-else 的三大恶果：

| 问题 | 表现 |
| --- | --- |
| 流转规则分散 | 同一状态判断散落在多个 Service，改一处漏一处 |
| 非法流转无保护 | 直接 `setStatus(任意值)`，脏数据进库 |
| 副作用难管理 | 发短信、扣库存、写日志塞在 if 里，顺序不可控 |
| 无审计 | 谁在什么事件下改了什么，日志缺失 |

状态机把这些收拢成一句话：**状态 × 事件 → 新状态（+ 守卫 + 动作）**。规则集中声明，非法流转直接被拒绝。

### 核心概念

| 概念 | 说明 |
| --- | --- |
| State | 状态，如 `待支付`、`已支付`、`已发货` |
| Event | 触发事件，如 `支付成功`、`发货`、`取消` |
| Transition | 转移：`source + event → target` |
| Guard | 守卫：转移的前置条件，返回 false 则不放行 |
| Action | 动作：转移过程中执行的副作用 |
| Extended State | 扩展状态变量（如订单号），随状态机携带 |

---

## 二、最小可用示例：订单状态机

**Maven 依赖：**

```xml
<dependency>
    <groupId>org.springframework.statemachine</groupId>
    <artifactId>spring-statemachine-core</artifactId>
    <version>2.5.0</version>
</dependency>
<!-- 持久化（可选） -->
<dependency>
    <groupId>org.springframework.statemachine</groupId>
    <artifactId>spring-statemachine-redis</artifactId>
    <version>2.5.0</version>
</dependency>
```

**定义状态与事件：**

```java
public enum OrderState {
    WAIT_PAY, PAID, SHIPPED, RECEIVED, CANCELED, CLOSED
}

public enum OrderEvent {
    PAY, SHIP, CONFIRM, CANCEL, TIMEOUT_CLOSE
}
```

**配置状态机（2.x 经典写法）：**

```java
@Configuration
@EnableStateMachine
public class OrderStateMachineConfig
        extends StateMachineConfigurerAdapter<OrderState, OrderEvent> {

    @Override
    public void configure(StateMachineStateConfigurer<OrderState, OrderEvent> states)
            throws Exception {
        states.withStates()
                .initial(OrderState.WAIT_PAY)
                .state(OrderState.WAIT_PAY)
                .state(OrderState.PAID)
                .state(OrderState.SHIPPED)
                .state(OrderState.RECEIVED)
                .end(OrderState.CANCELED)
                .end(OrderState.CLOSED);
    }

    @Override
    public void configure(StateMachineTransitionConfigurer<OrderState, OrderEvent> trans)
            throws Exception {
        trans
            .withExternal()
                .source(OrderState.WAIT_PAY).target(OrderState.PAID)
                .event(OrderEvent.PAY)
                .action(payAction())
            .and()
            .withExternal()
                .source(OrderState.PAID).target(OrderState.SHIPPED)
                .event(OrderEvent.SHIP)
                .guard(shipGuard())
            .and()
            .withExternal()
                .source(OrderState.SHIPPED).target(OrderState.RECEIVED)
                .event(OrderEvent.CONFIRM)
            .and()
            .withExternal()
                .source(OrderState.WAIT_PAY).target(OrderState.CANCELED)
                .event(OrderEvent.CANCEL)
            .and()
            .withExternal()
                .source(OrderState.WAIT_PAY).target(OrderState.CLOSED)
                .event(OrderEvent.TIMEOUT_CLOSE);
    }

    @Bean
    public Action<OrderState, OrderEvent> payAction() {
        return ctx -> {
            Long orderId = (Long) ctx.getExtendedState()
                    .getVariables().get("orderId");
            // 发消息、加积分、写流水……
            System.out.println("订单 " + orderId + " 支付成功动作执行");
        };
    }

    @Bean
    public Guard<OrderState, OrderEvent> shipGuard() {
        return ctx -> {
            Boolean paid = (Boolean) ctx.getExtendedState()
                    .getVariables().getOrDefault("paid", false);
            return Boolean.TRUE.equals(paid); // 未支付不允许发货
        };
    }
}
```

**触发事件：**

```java
@Service
public class OrderService {

    @Autowired
    private StateMachine<OrderState, OrderEvent> stateMachine;

    public boolean fire(Long orderId, OrderEvent event, boolean paid) {
        stateMachine.getExtendedState().getVariables().put("orderId", orderId);
        stateMachine.getExtendedState().getVariables().put("paid", paid);
        return stateMachine.sendEvent(Mono.just(
                MessageBuilder.withPayload(event).build()))
                .blockLast() != null;
    }
}
```

> ⚠️ 注意：`sendEvent` 是**异步**的（Reactor 风格），返回值是 `Flux`、`Mono<Boolean>` 等。别在事务方法里忘了 `blockLast()`，否则事件还没执行完就返回了。

---

## 三、监听状态变化

想统一记录流转日志，用 `@WithStateMachine` 监听：

```java
@Component
@WithStateMachine
public class OrderStateListener {

    @OnTransition(target = "PAID")
    public void onPaid(StateContext<OrderState, OrderEvent> ctx) {
        Long orderId = (Long) ctx.getExtendedState()
                .getVariables().get("orderId");
        // 记录状态流转日志 / 发 MQ
        System.out.println("订单 " + orderId + " 已支付");
    }

    @OnTransition
    public void anyTransition(StateContext<OrderState, OrderEvent> ctx) {
        // 所有转移都会经过这里
    }
}
```

`@OnTransition` 支持 `source`、`target`、`event` 组合过滤，是做审计日志的最佳位置。

---

## 四、持久化：让状态机"记住"自己

上面的 `stateMachine` 是单例 Bean，多个订单共用会互相污染。生产上必须**按业务 ID 恢复状态机**。

```java
@Service
public class OrderStateMachineService {

    @Autowired
    private StateMachineFactory<OrderState, OrderEvent> factory;

    @Autowired
    private StateMachinePersister<OrderState, OrderEvent, String> persister;

    public boolean sendEvent(String orderId, OrderEvent event) {
        StateMachine<OrderState, OrderEvent> sm = factory.getStateMachine(orderId);
        try {
            sm.startReactively().block();
            // 从 Redis 恢复
            persister.restore(sm, orderId);
            boolean accepted = sm.sendEvent(Mono.just(
                    MessageBuilder.withPayload(event).build()))
                    .blockLast() != null;
            // 持久化新状态
            persister.persist(sm, orderId);
            return accepted;
        } catch (Exception e) {
            throw new RuntimeException("状态机执行失败", e);
        } finally {
            sm.stopReactively().block();
        }
    }
}
```

**Redis 持久化配置：**

```java
@Configuration
public class PersistConfig {

    @Bean
    public RedisConnectionFactory redisConnectionFactory() {
        return new LettuceConnectionFactory("127.0.0.1", 6379);
    }

    @Bean
    public StateMachinePersister<OrderState, OrderEvent, String> persister(
            StateMachinePersist<OrderState, OrderEvent, String> persist) {
        return new RedisStateMachinePersister<>(persist);
    }

    @Bean
    public StateMachinePersist<OrderState, OrderEvent, String> stateMachinePersist(
            RedisConnectionFactory factory) {
        RedisStateMachineContextRepository<OrderState, OrderEvent> repo =
                new RedisStateMachineContextRepository<>(factory);
        return new RepositoryStateMachinePersist<>(repo);
    }
}
```

| 持久化方式 | 适用场景 | 特点 |
| --- | --- | --- |
| 内存 | 单机、短生命周期 | 快，重启即丢 |
| Redis | 分布式、高频 | 推荐，恢复快 |
| JPA/JDBC | 需要强一致/审计 | 与业务表同库同事务 |

---

## 五、分布式下的两个坑

### 1. 并发：同一订单被两个请求同时推进

状态机的 guard 是在**内存**里判断的，两个实例同时 `sendEvent` 会双双通过。解决：在业务层加**乐观锁或分布式锁**。

```java
// 乐观锁：版本号兜底
int rows = orderMapper.updateState(orderId, targetState, expectedState, version);
if (rows == 0) {
    throw new BizException("订单状态已变更，请刷新");
}
```

```java
// 或分布式锁，按订单 ID 加锁
if (!lock.tryLock("order:" + orderId, 5, TimeUnit.SECONDS)) {
    throw new BizException("操作过于频繁");
}
try { /* 状态机推进 */ } finally { lock.unlock("order:" + orderId); }
```

### 2. 幂等：重复事件要能吞掉

消息队列重投、用户重复点击都会重复发事件。做法：

- 用状态机的 `guard` 校验"当前状态是否允许该事件"，非法直接拒绝；
- 事件本身带唯一 ID，落一张 `event_dedupe` 表，`insert ignore` 判重。

---

## 六、Spring Statemachine 3.x 的变化

3.0 起包名/配置 API 有调整：`StateMachineConfigurerAdapter` 被移除，改用 `StateMachineConfigurationConfigurer` 配合 builder 风格；`sendEvent` 全面 Reactor 化。老项目升级时要注意：

- 配置文件重写；
- 监听器注解 `@WithStateMachine` 仍在，但 `StateMachineListener` 接口有方法变化；
- 与 Spring Boot 3 / Jakarta 命名空间对齐。

**结论**：新项目建议直接用 3.x，但要注意 API 迁移；存量项目 2.5.x 依然稳定可用。

---

## 七、它和"状态模式"有什么区别

| 维度 | 状态模式（设计模式） | Spring Statemachine |
| --- | --- | --- |
| 本质 | 把状态封装成类，多态实现行为 | 通用引擎，规则用配置声明 |
| 复杂性 | 手写类，状态多了爆炸 | 声明式，扩展灵活 |
| 持久化 | 自己实现 | 内置 Redis/JPA |
| 分布式 | 无 | 有 factory + persister |
| 适用 | 简单状态流转 | 复杂、多状态、需审计的流程 |

一句话：**状态模式是"手写轮子"，Statemachine 是"买现成的引擎"**。订单这种多状态、要审计、要分布式恢复的场景，果断上引擎。

---

## 八、面试追问连环炮

**Q1：状态机怎么防止非法流转？**
`configure` 里只声明合法的 `source + event → target`，未声明的转移 `sendEvent` 会返回 false（或抛异常），状态保持不变。

**Q2：Guard 和 Action 的区别？**
Guard 是**判断**（返回 boolean），决定转移是否发生，发生在转移**之前**；Action 是**执行**（副作用），发生在转移**过程中**。Guard 里不要写副作用，否则失败回滚会很难受。

**Q3：转移过程中抛异常会怎样？**
状态机会把状态回滚到转移前，并触发 `onTransitionError`/异常回调。所以 Action 里的外部调用要能重试或补偿。

**Q4：怎么记录状态变更历史？**
三种方式：`@OnTransition` 监听器统一写流水表；持久化层每次 persist 前落库；直接 `StateMachineInterceptor` 拦截 `preStateChange/postStateChange`。

**Q5：状态机性能如何？**
单机内存状态机纳秒级，瓶颈在持久化（Redis/JPA）。高并发场景建议：按业务 ID 缓存状态机实例、批量持久化、Listener 里只发消息不做重活。

---

## 九、总结

1. **状态机解决的是"状态流转失控"**，把规则从 if-else 中抽出来声明化；
2. **Guard 管放行，Action 管副作用，Listener 管审计**，三者职责分清；
3. **生产必须持久化 + 乐观锁**，否则分布式下必然出现状态覆盖；
4. 简单流程别上引擎，多状态 + 审计 + 分布式恢复才是它的主场。

订单、支付、风控、审批流——凡是"有状态、要走流程"的业务，Spring Statemachine 都值得放进技术选型清单。
