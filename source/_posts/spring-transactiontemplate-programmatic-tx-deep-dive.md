---
title: 【Spring 实战】编程式事务 TransactionTemplate 深度解析：从声明式事务失效场景到多线程事务边界控制
date: 2026-09-08 08:00:00
tags:
  - Spring
  - 事务
  - 源码
categories:
  - Java
  - Spring 全家桶
author: 东哥
---

# 【Spring 实战】编程式事务 TransactionTemplate 深度解析：从声明式事务失效场景到多线程事务边界控制

## 面试官：@Transactional 失效了，除了自调用，还有什么补救办法？

`@Transactional` 是声明式事务的银弹，但生产环境里「事务没生效」「事务边界不对」的坑层出不穷：同类自调用、非 public 方法、异常被 catch 吞掉、跨线程调用……面试官想听的往往不只是失效原因，而是你**有没有备用的武器**——编程式事务，尤其是 `TransactionTemplate`。

本文从 TransactionTemplate 的用法、源码原理、与声明式事务的对比，讲到多线程事务边界控制这个进阶话题。

---

## 一、为什么需要编程式事务？

声明式事务的本质是 **AOP 代理**：Spring 在 Bean 初始化时给目标类生成代理对象，方法调用时由 `TransactionInterceptor` 在方法前后开启/提交/回滚事务。

它有两个天生短板：

1. **失效场景多**：同类自调用（`this.method()` 绕过代理）、非 public 方法（CGLIB 代理无法织入）、方法被 final 修饰等。
2. **粒度粗**：一个方法一个事务。如果方法里有循环，想「每 N 条提交一次」或者「部分逻辑不需要事务」，声明式事务做不到。

编程式事务把事务边界**显式交给代码控制**，Spring 提供了两种方式：

| 方式 | 说明 | 现状 |
|------|------|------|
| `PlatformTransactionManager` 原生 API | `getTransaction/commit/rollback` 手动三板斧 | 繁琐、容易漏提交/漏回滚 |
| **`TransactionTemplate`** | 模板方法模式封装，回调内自动提交/回滚 | **推荐**，声明式事务的编程式平替 |

---

## 二、TransactionTemplate 快速上手

### 2.1 配置

Spring Boot 环境下，容器里已自动配置了 `PlatformTransactionManager`，直接注入即可：

```java
@Service
public class OrderService {

    private final TransactionTemplate transactionTemplate;

    // Spring Boot 自动注入 DataSourceTransactionManager 构造的模板
    public OrderService(TransactionTemplate transactionTemplate) {
        this.transactionTemplate = transactionTemplate;
    }
}
```

> 注意：Spring Boot 自动配置的 `TransactionTemplate` 是 `TransactionAutoConfiguration` 提供的，默认绑定主 `DataSourceTransactionManager`。如果有多数据源，需要自己 new 并绑定对应的事务管理器。

### 2.2 基本用法

有返回值用 `execute`，无返回值用 `executeWithoutResult`（Spring 5.2+）：

```java
public Order createOrder(OrderDTO dto) {
    return transactionTemplate.execute(status -> {
        Order order = orderMapper.insert(dto);
        // 模拟业务失败
        if (order.getAmount() > 10000) {
            // 抛异常即可触发回滚；也可以主动标记 rollback-only
            status.setRollbackOnly();
        }
        return order;
    });
}

public void batchUpdate(List<Long> ids) {
    transactionTemplate.executeWithoutResult(status -> {
        for (Long id : ids) {
            userMapper.updateStatus(id);
        }
    });
}
```

关键规则：**回调内抛出未捕获异常 → 模板自动回滚；正常返回 → 自动提交**。不需要手动调 `commit/rollback`，这正是模板的价值。

---

## 三、源码原理：TransactionTemplate 是怎么工作的？

看源码（`spring-tx` 的 `TransactionTemplate`）会发现它和 `TransactionInterceptor` 走的是**同一条执行链**：

```java
public class TransactionTemplate extends DefaultTransactionDefinition
        implements TransactionOperations, InitializingBean {

    private PlatformTransactionManager transactionManager;

    @Override
    public <T> T execute(TransactionCallback<T> action) throws TransactionException {
        // 核心：委托给 TransactionTemplate 的静态执行方法
        return execute(this, action);
    }

    static <T> T execute(TransactionOperations operations, TransactionCallback<T> action) {
        PlatformTransactionManager tm = operations.getTransactionManager();
        // 1. 开启事务（含传播行为处理，返回 TransactionStatus）
        TransactionStatus status = tm.getTransaction(operations);
        T result;
        try {
            // 2. 执行业务回调
            result = action.doInTransaction(status);
        } catch (RuntimeException | Error ex) {
            // 3. 运行时异常/Error → 回滚事务
            rollbackOnException(tm, status, ex);
            throw ex;
        } catch (Throwable ex) {
            // 4. 受检异常（默认）→ 提交事务
            commitTransactionAfterException(tm, status);
            throw ex;
        }
        // 5. 正常返回 → 提交
        tm.commit(status);
        return result;
    }
}
```

**核心发现**：

1. 默认回滚规则和 `@Transactional` 完全一致：**RuntimeException / Error 回滚，受检异常不回滚**（因为 `DefaultTransactionAttribute` 的 `rollbackOn` 只认 RuntimeException 和 Error）。
2. 模板没有走代理，**直接调用事务管理器**，所以不存在自调用失效问题。
3. 想改变回滚规则？TransactionTemplate 继承 `DefaultTransactionDefinition`，可以设置自定义 `TransactionAttribute`：

```java
transactionTemplate.setRollbackOn(ex ->
    ex instanceof BusinessException || ex instanceof RuntimeException);
```

---

## 四、TransactionTemplate 的高级配置

### 4.1 传播行为与隔离级别

TransactionTemplate 继承 `DefaultTransactionDefinition`，所有声明式事务能配的属性它都能配：

```java
@Bean
public TransactionTemplate transactionTemplate(PlatformTransactionManager tm) {
    TransactionTemplate template = new TransactionTemplate(tm);
    template.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRED);
    template.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    template.setTimeout(10); // 秒
    template.setReadOnly(false);
    return template;
}
```

也可以在业务代码里按需 new 一个临时模板（推荐用 `TransactionTemplate` 的 `setXxx` 链式，或直接构造不同配置的多个 Bean 按场景注入）。

### 4.2 事务内部分提交：循环分批提交

经典场景：批量导入 10 万条数据，要求**整体失败可回滚**，但内存里一条事务扛不住，折中方案是「每 1000 条提交一次，失败则整批回滚到该批次」：

```java
public void importBatch(List<Row> rows) {
    int batchSize = 1000;
    for (int i = 0; i < rows.size(); i += batchSize) {
        List<Row> sub = rows.subList(i, Math.min(i + batchSize, rows.size()));
        // REQUIRES_NEW：每次都是独立事务（挂起外层事务）
        TransactionTemplate inner = new TransactionTemplate(txManager);
        inner.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        inner.executeWithoutResult(status -> sub.forEach(this::saveRow));
    }
}
```

> 注意 REQUIRES_NEW 会**挂起外层事务**，如果外层也有未提交事务，锁可能被长时间持有，要权衡。另一种更常见的做法是外层根本没有事务，直接循环调用带事务的小方法。

---

## 五、多线程事务边界控制（进阶重点）

这是面试最容易「聊爆」的点：**`@Transactional` 能跨线程吗？**

不能。事务与线程绑定（`TransactionSynchronizationManager` 用 ThreadLocal 保存连接资源），子线程拿不到父线程的事务上下文。下面的代码**看起来**在一个事务里，实际上子线程的 SQL 是独立连接、独立自动提交的：

```java
@Transactional
public void wrongDemo() {
    for (Task task : tasks) {
        new Thread(() -> {
            // 这里的操作不在外层事务里！异常也不会触发外层回滚
            biz(task);
        }).start();
    }
}
```

### 5.1 TransactionTemplate 的正确多线程姿势

思路：**主线程只管编排，把事务下放到每个子线程内独立执行**，再汇总结果决定是否「补偿」：

```java
public boolean processInParallel(List<Long> ids) {
    ExecutorService pool = Executors.newFixedThreadPool(4);
    List<Future<Boolean>> futures = ids.stream()
        .map(id -> pool.submit(() -> {
            // 每个子线程内开启独立事务
            try {
                transactionTemplate.executeWithoutResult(status -> biz(id));
                return true;
            } catch (Exception e) {
                log.error("sub task failed, id={}", id, e);
                return false;
            }
        }))
        .collect(Collectors.toList());

    boolean allOk = futures.stream().allMatch(f -> {
        try { return f.get(); } catch (Exception e) { return false; }
    });

    // 全部成功才整体对外提交语义；有失败则对已成功的做补偿
    if (!allOk) {
        compensate(ids);   // 反向操作或写失败记录，交给重试/对账兜底
        return false;
    }
    return true;
}
```

**必须认清的现实**：关系型数据库的「跨线程分布式事务」没有银弹——每个线程独立事务，要么接受「部分成功 + 补偿」，要么引入 Seata/XA 等分布式事务方案。TransactionTemplate 能给你的，是**把每个子任务的事务边界管好、不吞异常、可汇总结果**。

### 5.2 实战原则

1. 子线程事务内**绝不能吞异常**——吞了模板就不会回滚。
2. 子任务结果必须汇总：用 `Future.get()` 拿到每个任务的成败。
3. 涉及「全成功才生效」的业务，设计好**补偿动作或对账任务**（幂等）。
4. 线程池用完要 shutdown，避免资源泄漏。

---

## 六、TransactionTemplate vs @Transactional 全对比

| 维度 | @Transactional（声明式） | TransactionTemplate（编程式） |
|------|------------------------|------------------------------|
| 实现机制 | Spring AOP 代理 + TransactionInterceptor | 直接调用 PlatformTransactionManager |
| 自调用是否失效 | **失效**（绕过代理） | 不失效 |
| 非 public 方法 | 不生效 | 无限制（就是普通方法） |
| 事务粒度 | 整个方法 | 任意代码块 |
| 循环内分批提交 | 做不到 | 轻松实现 |
| 动态传播行为 | 编译期写死 | 可运行时按需 new 模板配置 |
| 代码侵入 | 一个注解 | 显式模板代码 |
| 可读性 | 高 | 中（业务逻辑被回调包一层） |
| 调试友好度 | 代理链路隐藏 | 直接可见 |

**选型建议**：80% 场景用 `@Transactional`（简单、声明式、可读性好）；遇到自调用/粒度控制/多线程事务等场景，切 TransactionTemplate，而不是硬着头皮在注解上做文章。

---

## 七、面试常见追问

**Q1：TransactionTemplate 默认对受检异常会回滚吗？**
不会。和 @Transactional 一致，默认只回滚 RuntimeException 和 Error。受检异常会被当作「业务可预期」，模板正常提交。要改规则就自定义 `rollbackOn` 或 `TransactionAttribute`。

**Q2：为什么 @Transactional 自调用会失效，而 TransactionTemplate 不会？**
@Transactional 靠 AOP 代理生效，`this.method()` 是直接调用目标对象而不是代理对象，拦截器根本不会执行；TransactionTemplate 是直接调用事务管理器开启事务，不依赖代理，天然免疫自调用问题。

**Q3：一个事务里调用了 RPC/HTTP，事务迟迟不提交，怎么优化？**
事务内远程调用会长时间持有数据库连接和锁。优化：把远程调用移出事务（先本地落库标记「待发送」，事务提交后再通过事件/定时任务发送——事务同步事件 `@TransactionalEventListener` 的 AFTER_COMMIT 就是为此设计的）。

**Q4：多线程并发写同一批数据，各自开事务会死锁吗？**
会。两个线程各自事务按不同顺序更新同一组行，就可能死锁。多线程事务务必统一加锁顺序，或把并发写收敛为串行（如按主键分片后单线程处理每个分片）。

---

## 总结

TransactionTemplate 是声明式事务的「兜底武器」：原理与 TransactionInterceptor 同源（getTransaction → 回调 → commit/rollback），但不依赖 AOP 代理，天然规避自调用/非 public 失效问题，还能做到代码块级事务、循环分批提交、多线程独立事务。理解它的本质——**事务管理器 + 模板回调 + 默认回滚规则**——面试时从失效场景聊到多线程边界控制，一套组合拳下来，事务这块就稳了。
