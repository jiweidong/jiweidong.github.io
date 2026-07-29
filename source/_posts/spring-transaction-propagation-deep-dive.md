---
title: 【Spring 源码】Spring 事务传播行为（Propagation）源码深度解析：七种传播模式与实现原理
date: 2026-07-29 08:00:00
tags:
  - Spring
  - 事务
  - 源码
categories:
  - Spring
  - 事务管理
author: 东哥
---

# 【Spring 源码】Spring 事务传播行为（Propagation）源码深度解析：七种传播模式与实现原理

## 前言

事务传播行为是 Spring 声明式事务最核心、最容易出问题的概念之一。面试中经常被问到：

> "如果一个方法开启了事务，调用另一个有事务的方法，事务会合并还是独立？"
> "什么情况下事务会失效？"
> "REQUIRES_NEW 的实现原理是什么？"

本文从 Spring 事务基础设施源码出发，彻底解析七种传播行为的底层实现。

## 一、事务传播行为概述

Spring 在 `TransactionDefinition` 中定义了 7 种传播行为：

| 传播行为 | 说明 |
|---------|------|
| `REQUIRED`（默认） | 支持当前事务，没有则新建 |
| `SUPPORTS` | 支持当前事务，没有则以非事务执行 |
| `MANDATORY` | 必须在一个事务中运行，否则抛异常 |
| `REQUIRES_NEW` | 挂起当前事务，创建新事务 |
| `NOT_SUPPORTED` | 以非事务方式执行，挂起当前事务 |
| `NEVER` | 以非事务方式执行，存在事务则抛异常 |
| `NESTED` | 如果存在事务，在嵌套事务中执行（JDBC savepoint） |

```java
@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
@Inherited
@Documented
public @interface Transactional {
    Propagation propagation() default Propagation.REQUIRED;
    // ...
}
```

## 二、事务基础设施源码导读

### 2.1 核心接口

```java
// 事务管理器顶层接口
public interface TransactionManager { }

// 真正的编程式事务操作接口
public interface PlatformTransactionManager {
    TransactionStatus getTransaction(@Nullable TransactionDefinition definition);
    void commit(TransactionStatus status);
    void rollback(TransactionStatus status);
}
```

**主要实现**：
- `DataSourceTransactionManager`：JDBC 单数据源
- `JpaTransactionManager`：JPA/JTA
- `HibernateTransactionManager`：Hibernate

### 2.2 事务拦截器入口

Spring 声明式事务通过 AOP 实现，核心是 `TransactionInterceptor`：

```java
public class TransactionInterceptor extends TransactionAspectSupport
        implements MethodInterceptor {

    @Override
    public Object invoke(MethodInvocation invocation) throws Throwable {
        // 真正执行事务增强逻辑
        return invokeWithinTransaction(invocation.getMethod(), invocation.getThis(), invocation::proceed);
    }
}
```

## 三、传播行为的执行流程

### 3.1 invokeWithinTransaction 源码解析

```java
// TransactionAspectSupport.java
protected Object invokeWithinTransaction(Method method, @Nullable Object target,
        final InvocationCallback invocation) throws Throwable {

    TransactionAttributeSource tas = getTransactionAttributeSource();
    // 获取 @Transactional 的事务属性
    TransactionAttribute txAttr = (tas != null ? tas.getTransactionAttribute(method, targetClass) : null);
    // 获取事务管理器
    PlatformTransactionManager tm = determineTransactionManager(txAttr);

    String joinpointIdentification = methodIdentification(method, targetClass, txAttr);

    if (txAttr == null || !(tm instanceof CallbackPreferringPlatformTransactionManager)) {
        // 标准路径：创建事务并执行
        TransactionInfo txInfo = createTransactionIfNecessary(tm, txAttr, joinpointIdentification);

        Object retVal;
        try {
            retVal = invocation.proceedWithInvocation();  // 执行业务方法
        } catch (Throwable ex) {
            completeTransactionAfterThrowing(txInfo, ex);  // 异常回滚
            throw ex;
        } finally {
            cleanupTransactionInfo(txInfo);
        }
        commitTransactionAfterReturning(txInfo);  // 正常提交
        return retVal;
    }
    // ...
}
```

**关键步骤**：
1. `createTransactionIfNecessary` —— 根据传播行为决定如何管理事务
2. `invocation.proceedWithInvocation()` —— 执行业务方法
3. `completeTransactionAfterThrowing` —— 异常时回滚
4. `commitTransactionAfterReturning` —— 正常时提交

### 3.2 createTransactionIfNecessary 源码

```java
protected TransactionInfo createTransactionIfNecessary(PlatformTransactionManager tm,
        TransactionAttribute txAttr, final String joinpointIdentification) {

    if (txAttr != null && txAttr.getName() == null) {
        txAttr = new DelegatingTransactionAttribute(txAttr) {
            @Override
            public String getName() {
                return joinpointIdentification;
            }
        };
    }

    TransactionStatus status = null;
    if (txAttr != null) {
        if (tm != null) {
            // 核心调用：根据传播行为获取事务状态
            status = tm.getTransaction(txAttr);
        }
    }
    return prepareTransactionInfo(tm, txAttr, joinpointIdentification, status);
}
```

**核心**：`tm.getTransaction(txAttr)` 根据 `TransactionAttribute` 中的 `Propagation` 值执行不同的策略。

## 四、七种传播行为源码实现

`getTransaction` 的核心实现在 `AbstractPlatformTransactionManager` 中：

```java
public final TransactionStatus getTransaction(@Nullable TransactionDefinition definition) {
    // 1. 尝试获取当前事务（查询当前线程绑定的数据库连接）
    Object transaction = doGetTransaction();

    boolean debugEnabled = logger.isDebugEnabled();

    if (definition == null) {
        definition = new DefaultTransactionDefinition();
    }

    // 2. 检查当前是否存在事务
    if (isExistingTransaction(transaction)) {
        // 当前已有事务 → 处理事务传播行为
        return handleExistingTransaction(definition, transaction, debugEnabled);
    }

    // 3. 当前没有事务
    // 根据传播行为决定是否创建新事务
    if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED
            || definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW
            || definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NESTED) {
        return startTransaction(definition, transaction, debugEnabled);
    }
    // ...
}
```

### 4.1 PROPAGATION_REQUIRED（默认）

**没有事务 → 新建事务；有事务 → 加入当前事务**

```java
private TransactionStatus handleExistingTransaction(TransactionDefinition definition,
        Object transaction, boolean debugEnabled) {

    if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRED) {
        // 加入当前事务：返回一个 TransactionStatus，与外部事务共享同一个数据库连接
        TransactionStatus status = newTransactionStatus(definition, transaction, true,
                newSynchronization ? TransactionSynchronizationUtils.isActualTransactionActive(debugEnabled) : false,
                debugEnabled, null);
        return status;
    }
    // ...
}
```

**实现关键**：
- `newSynchronization = true` 表示参与同步管理
- `transaction` 直接传入当前事务对象，不做新建
- 最终 `commit`/`rollback` 时，只有**发起事务的最外层**才真正提交/回滚

### 4.2 PROPAGATION_REQUIRES_NEW

**无论当前是否有事务，都挂起当前事务，创建一个全新的独立事务**

```java
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_REQUIRES_NEW) {
    // 挂起当前事务
    SuspendedResourcesHolder suspendedResources = suspend(transaction);
    try {
        // 创建全新的事务
        return startTransaction(definition, transaction, debugEnabled, suspendedResources);
    } catch (RuntimeException | Error ex) {
        resumeAfterBeginException(transaction, suspendedResources, ex);
        throw ex;
    }
}
```

**关键细节**：
- `suspend(transaction)`：将当前事务的连接从线程解绑，保存到 `SuspendedResourcesHolder`
- `startTransaction()`：获取新连接，开启新事务
- 内层事务提交/回滚后，调用 `resume()` 恢复被挂起的事务
- **内层事务的提交/回滚完全独立，互不影响**

### 4.3 PROPAGATION_NESTED

**嵌套事务 —— 基于 JDBC Savepoint 机制**

```java
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NESTED) {
    if (useSavepointForNestedTransaction()) {
        // 方法一：使用 Savepoint（默认，前提是 JDBC 3.0+）
        // 在当前事务的连接上创建一个 Savepoint
        DefaultTransactionStatus status = (DefaultTransactionStatus) newTransactionStatus(...);
        status.createAndHoldSavepoint();
        return status;
    } else {
        // 方法二：回退到 REQUIRES_NEW（通过 JtaTransactionManager）
        return startTransaction(definition, transaction, debugEnabled);
    }
}
```

**嵌套事务行为**：
- 外层提交 → 嵌套也提交
- 外层回滚 → 嵌套也回滚（整个事务都回滚）
- 嵌套回滚 → **只回滚到 Savepoint，不影响外层事务**
- 嵌套提交 → 释放 Savepoint，等外层统一提交

### 4.4 PROPAGATION_MANDATORY

**必须有事务，否则抛异常**

```java
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_MANDATORY) {
    throw new IllegalTransactionStateException(
            "No existing transaction found for transaction marked with propagation 'mandatory'");
}
```

### 4.5 PROPAGATION_SUPPORTS / NOT_SUPPORTED / NEVER

```java
// SUPPORTS：有事务就加入，没有就不创建
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_SUPPORTS) {
    // 没有事务时以非事务方式运行
    Object suspendedResources = (newSynchronization ? suspend(transaction) : null);
    return newTransactionStatus(...);
}

// NOT_SUPPORTED：挂起当前事务，以非事务运行
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NOT_SUPPORTED) {
    Object suspendedResources = suspend(transaction);
    // 创建"空事务"——实际上没有事务
    return newTransactionStatus(...);
}

// NEVER：如果当前有事务则抛异常
if (definition.getPropagationBehavior() == TransactionDefinition.PROPAGATION_NEVER) {
    throw new IllegalTransactionStateException(
            "Existing transaction found for transaction marked with propagation 'never'");
}
```

## 五、事务提交/回滚的传播处理

Spring 如何确保内层事务的回滚不会提前提交外层事务？答案在 `processCommit` 和 `processRollback` 中：

### 5.1 提交处理

```java
// AbstractPlatformTransactionManager.processCommit()
private void processCommit(DefaultTransactionStatus status) {
    if (status.isNewTransaction()) {
        // 真正的新事务 → 执行 JDBC commit
        doCommit(status);
    } else if (status.isNewSavepoint()) {
        // 嵌套事务 → 释放 Savepoint
        status.releaseHeldSavepoint();
    }
    // 都不是 → 不做任何操作，等外层事务统一提交
}
```

### 5.2 回滚处理

```java
private void processRollback(DefaultTransactionStatus status, boolean unexpected) {
    if (status.isNewTransaction()) {
        // 真正的新事务 → 执行 JDBC rollback
        doRollback(status);
    } else if (status.isNewSavepoint()) {
        // 嵌套事务 → 回滚到 Savepoint
        status.rollbackToHeldSavepoint();
    } else if (status.isGlobalRollbackOnly()) {
        // 参与外部事务但标记了 rollback-only → 什么都不做
        // 等外层事务检查时发现 rollback-only 标记，统一回滚
    }
    // ...
}
```

## 六、事务失效经典场景

理解传播行为源码后，就能解释下面这些"事务失效"场景了：

### 6.1 自调用不生效

```java
@Service
public class UserService {
    public void methodA() {
        this.methodB();  // 自调用：绕过 AOP 代理！
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void methodB() {
        // 事务不会生效！
    }
}
```

**原因**：`this.methodB()` 调用的是原始对象，不是 AOP 代理对象，事务拦截器不会执行。  
**解决**：注入自身代理或拆到另一个 Service。

### 6.2 异常被捕获

```java
@Transactional
public void method() {
    try {
        doSomething();
    } catch (Exception e) {
        // 异常被吞掉，事务拦截器看不到异常，不会回滚
        log.error("Error", e);
    }
}
```

**原因**：Spring 事务回滚机制依赖抛出的异常。  
**解决**：不捕获异常，或在 catch 中抛出 RuntimeException。

### 6.3 REQUIRES_NEW + 自调用嵌套

```java
@Service
public class OrderService {
    @Autowired
    private OrderService self;  // 注入自身代理

    @Transactional
    public void createOrder() {
        saveOrder();
        self.sendNotification();  // ✅ 通过代理调用
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void sendNotification() {
        // 独立事务：邮件发送失败不影响订单创建
    }
}
```

## 七、常见面试追问

### Q1: 什么是"内层异常被外层捕获"的场景？

```java
@Transactional
public void outer() {
    try {
        inner();   // inner 事务标记 rollback-only
    } catch (Exception e) {
        // 捕获了异常
    }
    // outer 提交时：发现事务被标记为 rollback-only
    // → 抛出 UnexpectedRollbackException
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void inner() {
    throw new RuntimeException();
}
```

对于 REQUIRES_NEW，这是两层独立事务，不影响。对于 REQUIRED（默认），`inner()` 抛异常会标记事务为 `rollbackOnly`，`outer()` 即使捕获异常也无法提交。

### Q2: NESTED 和 REQUIRES_NEW 的区别？

| 维度 | NESTED | REQUIRES_NEW |
|------|--------|--------------|
| 底层机制 | JDBC Savepoint | 全新数据库连接 |
| 外层回滚 | 嵌套也回滚 | 独立，不受影响 |
| 内层回滚 | 只回滚到 Savepoint | 回滚内层事务 |
| 内层提交 | 等外层统一提交 | 立即提交 |
| 性能 | 同一连接，开销小 | 新建连接，开销大 |
| 是否支持 | 需 DataSourceTransactionManager | 全支持 |

## 八、总结

| 传播行为 | 无事务 | 有事务 |
|---------|-------|-------|
| REQUIRED | 新建事务 | 加入当前事务 |
| SUPPORTS | 非事务执行 | 加入当前事务 |
| MANDATORY | ❌ 抛异常 | 加入当前事务 |
| REQUIRES_NEW | 新建事务 | 挂起+新建 |
| NOT_SUPPORTED | 非事务执行 | 挂起+非事务 |
| NEVER | 非事务执行 | ❌ 抛异常 |
| NESTED | 新建事务 | 创建 Savepoint |

理解 Spring 事务传播行为的源码实现，是写出正确的事务代码的关键。**把握三个核心点就足够了**：
1. **当前有没有事务？**（`isExistingTransaction`）
2. **要不要新建/挂起？**（`suspend`/`resume`）
3. **提交/回滚谁负责？**（`newTransaction` 标记决定）
