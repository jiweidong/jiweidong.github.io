---
title: 【Spring 源码】事务同步机制（TransactionSynchronization）深度解析：事务钩子、@TransactionalEventListener 与嵌套事务
date: 2026-10-09 08:00:00
tags:
  - Java
  - Spring
  - 事务
  - 源码
  - 面试
categories:
  - Java
  - Spring 源码
author: 东哥
---

# 【Spring 源码】事务同步机制（TransactionSynchronization）深度解析：事务钩子、@TransactionalEventListener 与嵌套事务

## 面试官：事务提交之后要发一条 MQ 消息，你怎么写？

很多人第一反应是这样：

```java
@Transactional
public void createOrder(Order order) {
    orderMapper.insert(order);
    // 事务还没提交就把消息发出去了！
    rocketMQTemplate.send("order-topic", order);
}
```

面试官马上追问一句：**如果消息发成功了，但后面事务回滚了，这条消息怎么办？** 或者反过来，消息发送失败抛异常，事务回滚了，但这本来就不该回滚——因为业务其实可以接受消息后补。

正确做法不是"先发消息再提交"，也不是"先提交再发消息"（那要拆成两个方法、还要自己控制事务边界），而是**把动作挂到事务的生命周期钩子上**——这就是 Spring 的**事务同步机制**（`TransactionSynchronization`）。

这篇文章把 `TransactionSynchronizationManager`、七种回调、`@TransactionalEventListener`、嵌套事务里的 savepoint 回调一起讲透。

## 一、事务同步到底解决了什么问题

一句话：**允许你在"当前事务"的特定时点插入自己的逻辑，而这些逻辑的触发与事务的提交/回滚结果严格绑定。**

典型场景：

| 场景 | 期望行为 | 用事务同步的原因 |
| --- | --- | --- |
| 事务提交后发 MQ | 只有提交成功才发 | afterCommit |
| 事务提交后清缓存 | 只有提交成功才清 | afterCommit |
| 事务完成后记录操作日志 | 提交/回滚都要记 | afterCompletion |
| 提交前做最后校验 | 校验失败直接回滚 | beforeCommit |
| 事务回滚时补偿 | 只在回滚时执行 | afterCompletion(status != COMMITTED) |

如果没有这套机制，你只能：

1. 把发送逻辑放到 `@Transactional` 方法外面（需要拆分方法、暴露事务边界）；
2. 用 `TransactionSynchronizationManager.isActualTransactionActive()` 手工判断；
3. 用 `@TransactionalEventListener`（本质也是基于它实现）。

## 二、核心容器：TransactionSynchronizationManager

`TransactionSynchronizationManager` 是一个"ThreadLocal 大管家"，它维护了一个事务线程内的多份上下文：

```java
public abstract class TransactionSynchronizationManager {

    // 事务资源：key 一般是 DataSource / EntityManagerFactory
    // value 是ConnectionHolder / EntityManagerHolder，实现"同一事务同一连接"
    private static final ThreadLocal<Map<Object, Object>> resources =
            new NamedThreadLocal<>("Transactional resources");

    // 当前事务注册的所有同步器（List，有序）
    private static final ThreadLocal<Set<TransactionSynchronization>> synchronizations =
            new NamedThreadLocal<>("Transaction synchronizations");

    private static final ThreadLocal<String> currentTransactionName =
            new NamedThreadLocal<>("Current transaction name");

    private static final ThreadLocal<Boolean> currentTransactionReadOnly =
            new NamedThreadLocal<>("Current transaction read-only status");

    private static final ThreadLocal<Integer> currentTransactionIsolationLevel =
            new NamedThreadLocal<>("Current transaction isolation level");

    private static final ThreadLocal<Boolean> actualTransactionActive =
            new NamedThreadLocal<>("Actual transaction active");
}
```

关键点：

- **synchronizations 是一个 `LinkedHashSet`**，所以注册顺序 = 回调顺序（`LinkedHashSet` 保证插入序）。
- 它只在**实际事务**生效时才有同步器；如果只是 `@Transactional(propagation = SUPPORTS)` 且没有外层事务，`isSynchronizationActive()` 为 false。
- 回调执行完了会调用 `clearSynchronization()` 清理，**所以不要指望在事务结束后再往里面加东西**。

自己注册同步器最原始的写法：

```java
// 必须在事务中执行，否则抛 IllegalStateException
if (TransactionSynchronizationManager.isSynchronizationActive()) {
    TransactionSynchronizationManager.registerSynchronization(
        new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                mqProducer.send(order);
            }
        });
}
```

## 三、七种回调的执行时机

Spring 5.3 之后 `TransactionSynchronization` 提供了默认方法，你按需重写即可。完整生命周期如下：

```java
public interface TransactionSynchronization extends Ordered, Flushable {

    default void suspend() {}                 // 事务挂起（外层事务暂停时）
    default void resume() {}                  // 事务恢复
    default void flush() {}                   // 显式 flush（flush 时调用）
    default void beforeCommit(boolean readOnly) {}
    default void beforeCompletion() {}
    default void afterCommit() {}
    default void afterCompletion(int status) {}
}
```

执行顺序（以"提交成功"为例）：

```
业务方法执行
   ↓
flush()                       // 有脏数据时
   ↓
beforeCommit(readOnly)        // 提交前，抛异常则回滚
   ↓
beforeCompletion()            // 提交/回滚前最后一刻
   ↓
【真正 commit】                // 数据库提交
   ↓
afterCommit()                 // 提交成功后
   ↓
afterCompletion(STATUS_COMMITTED)
```

回滚时：

```
业务方法抛异常
   ↓
beforeCompletion()
   ↓
【真正 rollback】
   ↓
afterCompletion(STATUS_ROLLED_BACK)   // afterCommit 不会执行
```

必须记住的三条铁律：

1. **`beforeCommit` 里抛异常会导致回滚**，因为还在事务边界内。
2. **`afterCommit` 里抛异常不会回滚**（已经提交了），只会向上传播，但常被吞掉，务必自己 try-catch。
3. **`afterCommit`/`afterCompletion` 里默认没有事务**——此时 `isActualTransactionActive()` 已经是 false，再执行数据库写操作是**独立的新事务**（如果走的是同一 DataSource，会重新拿连接）。

这条第 3 点是最容易踩的坑：很多人在 `afterCommit` 里 `update` 一张表，以为还在同一个事务里，其实早就是新连接了新事务，出了异常也不会影响主流程——听起来"安全"，但会造成数据不一致且没人发现。

## 四、源码：回调是怎么被触发的

以 `AbstractPlatformTransactionManager` 为例。

挂起/恢复：

```java
private TransactionStatus handleExistingTransaction(...) {
    // ...
    if (definition.getPropagationBehavior() == Propagation.REQUIRES_NEW) {
        SuspendedResourcesHolder suspended = doSuspend(transaction);
        // doSuspend 会把当前 synchronizations 拷贝出来并清空，
        // 然后 TransactionSynchronizationManager.clear()
    }
}

private SuspendedResourcesHolder doSuspend(TransactionSynchronizationManager local) {
    Set<TransactionSynchronization> synchronizations = TransactionSynchronizationManager.getSynchronizations();
    TransactionSynchronizationManager.clearSynchronization();
    // 保存 synchronizations，resume 时恢复
    return new SuspendedResourcesHolder(null, synchronizations);
}
```

提交：

```java
private void processCommit(DefaultTransactionStatus status) {
    try {
        boolean beforeCompletionInvoked = false;
        if (status.hasSavepoint()) {
            status.releaseHeldSavepoint();
        } else if (status.isNewTransaction()) {
            doCommit(status);          // 真正的数据库提交
        }
    } finally {
        triggerAfterCommit(status);     // 回调 afterCommit
        triggerAfterCompletion(status, TransactionSynchronization.STATUS_COMMITTED);
    }
}

private void triggerAfterCommit(DefaultTransactionStatus status) {
    if (status.isNewSynchronization()) {
        TransactionSynchronizationUtils.triggerAfterCommit();
    }
}
```

再往下看 `TransactionSynchronizationUtils`：

```java
public static void triggerAfterCommit() {
    invokeAfterCommit(TransactionSynchronizationManager.getSynchronizations());
}

public static void invokeAfterCommit(@Nullable List<TransactionSynchronization> synchronizations) {
    if (synchronizations != null) {
        for (TransactionSynchronization synchronization : synchronizations) {
            synchronization.afterCommit();   // 直接遍历，异常会中断后续回调
        }
    }
}
```

注意：**一个同步器抛异常，后面的同步器就不会执行了**。所以生产代码里每个回调都要自己兜底：

```java
@Override
public void afterCommit() {
    try {
        doSomething();
    } catch (Exception e) {
        log.error("afterCommit 执行失败", e);   // 千万别往外抛
    }
}
```

另外 `beforeCompletion` 和 `afterCompletion` 在回滚路径上也会执行，`afterCommit` 只在成功路径执行，这个差别是排查"消息没发出去"的第一现场。

## 五、@TransactionalEventListener：同步机制的官方门面

Spring 4.2 引入的 `@TransactionalEventListener` 就是把这套机制封装成了事件监听：

```java
@Component
public class OrderMessageListener {

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderCreated(OrderCreatedEvent event) {
        mqProducer.send(new OrderMessage(event.getOrderId()));
    }
}
```

`TransactionPhase` 有四个值，和回调一一对应：

| phase | 对应回调 | 触发条件 |
| --- | --- | --- |
| BEFORE_COMMIT | beforeCommit | 提交前，抛异常可回滚 |
| AFTER_COMMIT | afterCommit | 提交成功后 |
| AFTER_ROLLBACK | afterCompletion | 仅回滚时 |
| AFTER_COMPLETION | afterCompletion | 提交或回滚都触发 |

它底层是怎么工作的？看 `TransactionalApplicationListener`：

```java
// 简化逻辑
private void processEvent(ApplicationEvent event) {
    switch (this.phase) {
        case BEFORE_COMMIT:
            TransactionSynchronizationManager.registerSynchronization(
                new TransactionalApplicationListenerSynchronization<>(...){});
            break;
        case AFTER_COMMIT:
        case AFTER_ROLLBACK:
        case AFTER_COMPLETION:
            // 通过 TransactionalApplicationListenerMethodAdapter 注册同步器
            break;
    }
}
```

也就是说：**没有事务时，默认事件会被丢弃**（除非设置 `fallbackExecution = true`）。

```java
// 没有事务时也执行，改成同步执行
@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT, fallbackExecution = true)
public void onEvent(OrderCreatedEvent event) { ... }
```

这个 `fallbackExecution` 是个经典考点：默认 false 意味着"无事务即不监听"，很多人本地测试直接调用方法、没有事务，事件"消失"了，还以为是异步问题。

## 六、嵌套事务（savepoint）下的回调行为

`PROPAGATION_NESTED` 不是新事务，而是"外层事务 + savepoint"。看源码：

```java
// AbstractPlatformTransactionManager#handleExistingTransaction
if (definition.getPropagationBehavior() == Propagation.NESTED) {
    if (useSavepointForNestedTransaction()) {
        DefaultTransactionStatus status =
            prepareTransactionStatus(definition, transaction, false, false, debugEnabled, null);
        status.createAndHoldSavepoint();     // 创建 savepoint
        return status;
    } else {
        return startTransaction(definition, transaction, debugEnabled, null);
    }
}
```

内层回滚时：

```java
private void processRollback(DefaultTransactionStatus status, boolean unexpected) {
    if (status.hasSavepoint()) {
        status.rollbackToHeldSavepoint();      // 只回滚到 savepoint
        triggerAfterCompletion(status, TransactionSynchronization.STATUS_ROLLED_BACK);
        // 注意：这里会触发 afterCompletion，但不会触发 afterCommit
    }
    // ...
    cleanupAfterCompletion(status);
}
```

关键结论：

- 内层 `NESTED` 回滚到 savepoint 时，**内层注册的 `afterCompletion` 会执行**（status = ROLLED_BACK），而外层事务继续。
- 因为 `isNewSynchronization()` 为 false，**内层注册的同步器其实是注册到外层的 synchronizations 集合里的**（同一个事务上下文），所以回调的"粒度"并不像你想的那么细。
- `REQUIRES_NEW` 会挂起外层事务（`doSuspend`），它拥有**独立的 synchronization 集合和独立连接**，因此 `REQUIRES_NEW` 里的 `afterCommit` 是真正独立生效的。

对比总结：

| 传播行为 | 是否新事务 | 是否有独立 synchronization | afterCommit 时机 |
| --- | --- | --- | --- |
| REQUIRED | 否（加入外层） | 否 | 外层提交后 |
| REQUIRES_NEW | 是 | 是 | 自己的提交后 |
| NESTED | 否（savepoint） | 否 | 外层提交后 |
| SUPPORTS | 看有没有外层 | 否 | 外层提交后 |

## 七、实战：一个"事务提交后可靠发消息"的组件

需求：订单创建后发 MQ；失败要重试；绝不能因为 MQ 故障导致订单回滚。

```java
@Component
@RequiredArgsConstructor
public class AfterCommitExecutor {

    private final MessageSender messageSender;
    private final OrderOutboxMapper outboxMapper;   // 本地消息表

    /** 在当前事务提交后执行任务；若当前无事务则立即执行 */
    public void execute(Runnable task) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCompletion(int status) {
                        if (status == TransactionSynchronization.STATUS_COMMITTED) {
                            try {
                                task.run();
                            } catch (Exception e) {
                                log.error("afterCommit 任务失败", e);
                            }
                        }
                    }
                });
        } else {
            task.run();
        }
    }
}
```

配合**本地消息表（事务性发件箱）**，把"发消息"这件事落成一张表，在同一个事务里写入，提交后再真正投递并由定时任务补偿，才能做到"不丢消息"：

```java
@Transactional
public void createOrder(Order order) {
    orderMapper.insert(order);
    // 同一事务内写入 outbox，绝不会出现"消息成功但订单回滚"
    outboxMapper.insert(new Outbox("order-topic", JSON.toJSONString(order)));

    afterCommitExecutor.execute(() -> {
        // 提交后异步投递，失败交给定时任务重试
        messageSender.trySend(order.getId());
    });
}
```

这里有两个工程细节值得强调：

1. **不要在 `afterCommit` 里执行耗时操作**：它会占用执行提交的线程（也就是业务线程）。正确做法是丢进线程池 / 交给 `afterCommitExecutor` 里的异步逻辑。
2. **`afterCommit` 里的异常会导致"消息丢失"**：所以要么 try-catch + 落库重试，要么直接依赖本地消息表 + 定时补偿，别把可靠性押在 `afterCommit` 上。

## 八、常见坑与排查清单

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `@TransactionalEventListener` 不触发 | 调用方没有事务，`fallbackExecution=false` | 加事务 / 设 `fallbackExecution=true` |
| `afterCommit` 里改数据"没生效" | 无事务环境下自建新事务，可能被外层连接可见性问题掩盖 | 显式开新事务 / 改用消息表 |
| 注册同步器报 `IllegalStateException` | 不在事务中 / 只是 `SUPPORTS` 无外层事务 | 判空 `isSynchronizationActive()` |
| 多个监听器只有一个生效 | 前面的回调抛异常中断了遍历 | 每个回调内部 try-catch |
| 事务方法内部调用事件、无事务 | 自调用绕过代理 | 注入自身 / 拆类 |
| `REQUIRES_NEW` 后同步器消失 | `doSuspend` 清空了 synchronizations | 理解挂起语义，别跨边界复用回调 |

一个非常好用的调试手段是打日志确认时机：

```java
TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
    @Override public void beforeCommit(boolean readOnly) {
        log.info("beforeCommit, readOnly={}, txName={}", readOnly,
                TransactionSynchronizationManager.getCurrentTransactionName());
    }
    @Override public void afterCommit() { log.info("afterCommit"); }
    @Override public void afterCompletion(int status) { log.info("afterCompletion status={}", status); }
});
```

## 九、面试追问

**Q1：为什么 `afterCommit` 里再操作数据库不是同一个事务？**

因为此时数据库事务已经提交、连接已归还或即将归还，`TransactionSynchronizationManager` 的 resources 已被清理，`isActualTransactionActive()` 为 false。再次执行 SQL 会重新获取连接、开启新事务。

**Q2：`beforeCommit` 和 `beforeCompletion` 的区别？**

`beforeCommit` 是"业务层面的提交前"，可以在这里做最后校验并抛异常触发回滚；`beforeCompletion` 是"资源层面的提交前"，无论提交还是回滚都会执行，主要给资源清理用。`beforeCommit` 只在提交路径执行。

**Q3：`@TransactionalEventListener` 和 `@EventListener` 的执行顺序？**

`@EventListener` 是同步的，会立刻在 `publishEvent` 处执行（此时还在事务里）；`@TransactionalEventListener` 会注册同步器延后执行。两者同时监听一个事件时，`@EventListener` 先执行。

**Q4：多个同步器怎么保证顺序？**

`TransactionSynchronization` 继承 `Ordered`，`LinkedHashSet` 按插入顺序保存，但你无法通过 `@Order` 直接控制匿名内部类；需要排序时用 `AnnotationAwareOrderComparator.sort()` 自己处理，或实现 `Ordered` 接口。

## 十、小结

- `TransactionSynchronizationManager` 用 ThreadLocal 维护事务资源与同步器集合，是"同一事务同一连接"和"事务钩子"的共同底座。
- 七个回调中，`afterCommit` 只在成功提交后执行，`afterCompletion` 提交/回滚都会执行，`beforeCommit` 抛异常会回滚。
- `@TransactionalEventListener` 是官方封装，默认**无事务不触发**，注意 `fallbackExecution`。
- `REQUIRES_NEW` 会挂起并隔离同步器，`NESTED` 不会；跨事务边界复用回调是经典事故来源。
- 真正的"事务后可靠发消息"要靠**本地消息表 + 定时补偿**，`afterCommit` 只是触发点，不是可靠性保证。

把这套机制吃透，你回答的就不再是"我会用 `@TransactionalEventListener`"，而是"我知道它为什么可靠、哪里不可靠"。
