---
title: 彻底搞懂 Spring 声明式事务 @Transactional：原理、源码与 13 个经典失效场景
date: 2026-06-21 08:00:00
tags:
  - Java
  - Spring
  - 事务
  - 源码分析
categories:
  - Java
  - Spring 原理
author: 东哥
---

# 彻底搞懂 Spring 声明式事务 @Transactional：原理、源码与 13 个经典失效场景

## 一、引言：声明式事务 vs 编程式事务

Spring 提供两种事务管理方式：

| 方式 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| 编程式事务 | TransactionTemplate 或 PlatformTransactionManager | 粒度细，灵活控制 | 代码侵入性强，重复代码多 |
| 声明式事务 | @Transactional 注解 + AOP | 无侵入，一行注解搞定 | 不够灵活，有坑多 |

绝大多数项目都是用声明式事务——一个 `@Transactional` 搞定，但很多人只知其然不知其所以然。

```java
// 编程式事务
@Service
public class UserServiceManual {
    @Autowired
    private TransactionTemplate transactionTemplate;
    
    public void createUser(User user) {
        transactionTemplate.execute(status -> {
            userDao.insert(user);
            userLogDao.insert(new UserLog("create", user.getId()));
            return null;
        });
    }
}

// 声明式事务（更简洁）
@Service
public class UserService {
    @Transactional
    public void createUser(User user) {
        userDao.insert(user);
        userLogDao.insert(new UserLog("create", user.getId()));
    }
}
```

## 二、@Transactional 的底层原理

### 本质：AOP 代理 + TransactionInterceptor

当你在 Bean 上标注 `@Transactional`，Spring 会通过 AOP 为该 Bean 创建代理对象。事务的增强逻辑在 **TransactionInterceptor** 中实现：

```java
// TransactionInterceptor 核心逻辑
public class TransactionInterceptor extends TransactionAspectSupport
        implements MethodInterceptor {
    
    @Override
    @Nullable
    public Object invoke(MethodInvocation invocation) throws Throwable {
        // 获取事务属性
        TransactionAttributeSource tas = getTransactionAttributeSource();
        TransactionAttribute ta = tas.getTransactionAttribute(
            invocation.getMethod(), invocation.getThis().getClass());
        
        // ◆ 核心：在目标方法周围织入事务逻辑
        return invokeWithinTransaction(invocation.getMethod(), 
            invocation.getThis().getClass(), invocation::proceed);
    }
}
```

### invokeWithinTransaction——事务增强的核心

```java
// TransactionAspectSupport
protected Object invokeWithinTransaction(Method method, @Nullable Class<?> targetClass,
        final InvocationCallback invocation) throws Throwable {
    
    // 1. 获取事务属性（传播行为、隔离级别、超时等）
    TransactionAttributeSource tas = getTransactionAttributeSource();
    TransactionAttribute txAttr = (tas != null ? tas.getTransactionAttribute(method, targetClass) : null);
    
    // 2. 获取 PlatformTransactionManager
    PlatformTransactionManager tm = determineTransactionManager(txAttr);
    
    // 3. 构造连接点标识
    String joinpointIdentification = methodIdentification(method, targetClass, txAttr);
    
    if (txAttr == null || !(tm instanceof CallbackPreferringPlatformTransactionManager)) {
        // ◆ 标准事务处理（绝大多数场景走这里）
        // 3.1 创建事务
        TransactionInfo txInfo = createTransactionIfNecessary(tm, txAttr, joinpointIdentification);
        
        Object retVal = null;
        try {
            // 3.2 执行目标方法
            retVal = invocation.proceedWithInvocation();
        } catch (Throwable ex) {
            // 3.3 异常时回滚事务
            completeTransactionAfterThrowing(txInfo, ex);
            throw ex;
        } finally {
            // 3.4 清理事务信息（恢复线程绑定信息）
            cleanupTransactionInfo(txInfo);
        }
        
        // 3.5 正常提交事务
        commitTransactionAfterReturning(txInfo);
        return retVal;
    }
}
```

### createTransactionIfNecessary——创建事务

```java
protected TransactionInfo createTransactionIfNecessary(@Nullable PlatformTransactionManager tm,
        @Nullable TransactionAttribute txAttr, final String joinpointIdentification) {
    
    // 如果没有指定事务名称，生成默认名称
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
            // ◆ 委托给 PlatformTransactionManager 获取事务
            status = tm.getTransaction(txAttr);
        }
    }
    
    // 包装成 TransactionInfo，绑定到当前线程
    return prepareTransactionInfo(tm, txAttr, joinpointIdentification, status);
}
```

### completeTransactionAfterThrowing——异常回滚

```java
protected void completeTransactionAfterThrowing(@Nullable TransactionInfo txInfo, Throwable ex) {
    if (txInfo != null && txInfo.getTransactionStatus() != null) {
        // ◆ 判断是否应该回滚
        if (txInfo.transactionAttribute != null && 
            txInfo.transactionAttribute.rollbackOn(ex)) {
            // 回滚
            txInfo.getTransactionManager().rollback(txInfo.getTransactionStatus());
        } else {
            // 不回滚（异常不符合回滚条件），仍然提交
            txInfo.getTransactionManager().commit(txInfo.getTransactionStatus());
        }
    }
}
```

**关键洞察**：默认情况下，Spring 只对 **RuntimeException 和 Error** 进行回滚，对 checked exception（如 SQLException）不回滚。

### commitTransactionAfterReturning——正常提交

```java
protected void commitTransactionAfterReturning(@Nullable TransactionInfo txInfo) {
    if (txInfo != null && txInfo.getTransactionStatus() != null) {
        txInfo.getTransactionManager().commit(txInfo.getTransactionStatus());
    }
}
```

## 三、@Transactional 的核心参数详解

```java
@Target({ElementType.TYPE, ElementType.METHOD})
@Retention(RetentionPolicy.RUNTIME)
@Inherited
@Documented
public @interface Transactional {
    // 事务管理器（多数据源时指定）
    @AliasFor("transactionManager")
    String value() default "";
    @AliasFor("value")
    String transactionManager() default "";
    
    // 事务传播行为（默认：REQUIRED）
    Propagation propagation() default Propagation.REQUIRED;
    
    // 隔离级别（默认：数据库默认级别）
    Isolation isolation() default Isolation.DEFAULT;
    
    // 超时时间（秒，默认：-1 使用数据库超时）
    int timeout() default TransactionDefinition.TIMEOUT_DEFAULT;
    
    // 是否只读
    boolean readOnly() default false;
    
    // 指定哪些异常触发回滚
    Class<? extends Throwable>[] rollbackFor() default {};
    String[] rollbackForClassName() default {};
    
    // 指定哪些异常不触发回滚
    Class<? extends Throwable>[] noRollbackFor() default {};
    String[] noRollbackForClassName() default {};
}
```

### 事务传播行为（7 种）

| 传播行为 | 含义 |
|----------|------|
| REQUIRED（默认） | 有事务则加入，没有则新建 |
| SUPPORTS | 有事务则加入，没有就不开启 |
| MANDATORY | 必须有事务，否则抛异常 |
| REQUIRES_NEW | 挂起当前事务，新建一个（内外事务独立） |
| NOT_SUPPORTED | 挂起当前事务，以非事务方式运行 |
| NEVER | 不能有事务，否则抛异常 |
| NESTED | 嵌套事务（JDBC savepoint 实现） |

```java
// REQUIRED 场景：内外事务属于同一个事务
@Service
public class OuterService {
    @Autowired
    private InnerService innerService;
    
    @Transactional
    public void outer() {
        userDao.insert(new User("outer"));
        innerService.inner();  // 加入同一事务
        // 这里抛异常 → 内外都回滚
        throw new RuntimeException();
    }
}

@Service
public class InnerService {
    @Transactional(propagation = Propagation.REQUIRED)
    public void inner() {
        userDao.insert(new User("inner"));
    }
}

// REQUIRES_NEW 场景：内外事务独立
// 内层 @Transactional(propagation = Propagation.REQUIRES_NEW)
// → inner 异常不影响 outer 提交，outer 异常不影响 inner 提交
```

## 四、13 个经典 @Transactional 失效场景

这是面试中经常被问到的重点。以下场景中 @Transactional 会**失效**（不开启事务）：

### 场景 1：非 public 方法

```java
@Service
public class UserService {
    @Transactional
    protected void createUser() {  // ❌ 非 public → 事务不生效
        // ...
    }
}
```

**原因**：Spring 的 AOP 默认只对 public 方法进行代理增强（CGLIB 在某些配置下可以代理 protected，但不推荐依赖）。

### 场景 2：方法内部自调用（同一类中调用）

```java
@Service
public class UserService {
    
    public void createUser() {
        // ❌ 自调用：this.createUserWithTx() 走的是 this（原始对象），不是代理对象
        this.createUserWithTx();
    }
    
    @Transactional
    public void createUserWithTx() {
        userDao.insert(new User("test"));
    }
}
```

**原因**：本质上是 AOP 代理对象的问题。`this.method()` 调用的是原始对象的方法，没有经过 AOP 增强。

**解决方法**：
```java
// 方案一：注入自己（循环依赖解决后，注入的是代理对象）
@Service
public class UserService {
    @Autowired
    private UserService self;  // 注入代理对象
    
    public void createUser() {
        self.createUserWithTx();  // ✅ 通过代理对象调用
    }
    
    @Transactional
    public void createUserWithTx() {
        userDao.insert(new User("test"));
    }
}

// 方案二：AopContext.currentProxy()
@Service
public class UserService {
    public void createUser() {
        ((UserService) AopContext.currentProxy()).createUserWithTx();  // ✅
    }
}
// 需要配置暴露代理：@EnableAspectJAutoProxy(exposeProxy = true)
```

### 场景 3：方法被 final 修饰

```java
@Service
public class UserService {
    @Transactional
    public final void createUser() {  // ❌ final 方法
        // ...
    }
}
```

**原因**：CGLIB 通过生成子类来代理，final 方法不能被重写。

### 场景 4：异常被 try-catch 吃了

```java
@Transactional
public void createUser() {
    try {
        userDao.insert(new User("test"));
        throw new RuntimeException();  // 被吃掉了
    } catch (Exception e) {
        // ❌ 异常被捕获，TransactionInterceptor 不知道有异常
        System.out.println("忽略异常");
    }
}
```

**原因**：只有抛出异常，TransactionInterceptor 的 catch 块才会触发回滚。捕获后没抛，框架认为方法执行成功。

**正确做法**：
```java
@Transactional
public void createUser() {
    try {
        userDao.insert(new User("test"));
        throw new RuntimeException();
    } catch (Exception e) {
        // 要么重新抛出：
        throw e;
        // 要么手动回滚：
        // TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();
    }
}
```

### 场景 5：异常类型不对（checked exception）

```java
@Transactional
public void createUser() throws SQLException {  // ❌ SQLException 是 checked exception
    userDao.insert(new User("test"));
    throw new SQLException("数据库异常");  // 不会回滚！
}
```

**原因**：默认只对 RuntimeException 和 Error 回滚。SQLException 继承自 Exception，不会触发回滚。

**解决**：
```java
@Transactional(rollbackFor = Exception.class)  // ✅ 指定所有异常都回滚
// 或
@Transactional(rollbackFor = SQLException.class)  // ✅ 指定具体异常
```

**最佳实践**：线上项目在 `@Transactional` 上加上 `rollbackFor = Exception.class`。

### 场景 6：多线程调用

```java
@Transactional
public void createUser() {
    userDao.insert(new User("test"));
    
    new Thread(() -> {
        // ❌ 新线程中的操作不在同一事务中
        userDao.insert(new User("other"));
    }).start();
}
```

**原因**：Spring 事务通过 ThreadLocal 绑定到当前线程，新线程拿不到。

### 场景 7：数据库引擎不支持事务

```sql
-- MySQL MyISAM 引擎不支持事务
CREATE TABLE user_myisam (
    id INT PRIMARY KEY,
    name VARCHAR(100)
) ENGINE=MyISAM;  -- ❌ @Transactional 无效
```

### 场景 8：@Transactional 加在接口上（JDK 动态代理时）

```java
public interface UserService {
    @Transactional  // ❌ 某些版本或配置下不生效
    void createUser();
}
```

如果使用 JDK 动态代理（默认实现了接口），@Transactional 加在接口方法上可能不生效。建议加在实现类的方法上。

### 场景 9：传播行为配置不当

```java
@Transactional(propagation = Propagation.NOT_SUPPORTED)
public void createUser() {  // ❌ 以非事务方式运行
    // ...
}

@Transactional(propagation = Propagation.NEVER)
public void createUser() {  // ❌ 如果已有事务则抛异常
    // ...
}
```

### 场景 10：事务管理器未正确配置

```java
// 配置了多个事务管理器
@Bean
public PlatformTransactionManager transactionManager() { ... }
@Bean
public PlatformTransactionManager otherTransactionManager() { ... }

// 但没有指定用哪个
@Transactional  // ❌ 可能使用了错误的 TransactionManager
```

**解决**：`@Transactional("otherTransactionManager")`

### 场景 11：在异步调用中使用

```java
@Async
@Transactional
public CompletableFuture<Void> createUser() {  // ❌ 异步方法
    // ...
}
```

`@Async` 会创建一个新的代理，事务上下文可能丢失。

### 场景 12：@Transactional 加在 private 方法上

```java
@Transactional
private void createUser() {  // ❌ private 方法
    // ...
}
```

### 场景 13：同一个类中 A 方法调 B 方法，B 加了 @Transactional

```java
@Service
public class UserService {
    public void methodA() {
        this.methodB();  // ❌ 自调用，methodB 事务不生效
    }
    
    @Transactional
    public void methodB() {
        // ...
    }
}
```

**本质原因**：场景 2 的变体，都是自调用绕过代理。

## 五、事务隔离级别与 Spring

Spring 支持的事务隔离级别：

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|----------|------|-----------|------|
| DEFAULT（数据库默认） | 取决于数据库 | 取决于数据库 | 取决于数据库 |
| READ_UNCOMMITTED | ✅ | ✅ | ✅ |
| READ_COMMITTED | ❌ | ✅ | ✅ |
| REPEATABLE_READ | ❌ | ❌ | ✅ |
| SERIALIZABLE | ❌ | ❌ | ❌ |

```java
@Transactional(isolation = Isolation.REPEATABLE_READ)
public void queryUser() {
    // ...
}
```

**注意**：`@Transactional(isolation = ...)` 事务隔离级别是通过底层 Connection 的 `setTransactionIsolation()` 设置的，需要数据库支持。

## 六、@Transactional 和 @TransactionalEventListener

```java
@Component
public class UserCreatedEventListener {
    
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void handleUserCreated(UserCreatedEvent event) {
        // ✅ 事务提交后才执行（避免事务未提交就发送消息）
        sendNotification(event.getUserId());
    }
}
```

| phase | 触发时机 |
|-------|----------|
| AFTER_COMMIT（默认） | 事务提交后 |
| AFTER_ROLLBACK | 事务回滚后 |
| AFTER_COMPLETION | 事务完成后（无论提交/回滚） |
| BEFORE_COMMIT | 事务提交前（仍在事务内） |

## 七、最佳实践总结

1. **默认加 rollbackFor**：`@Transactional(rollbackFor = Exception.class)`
2. **避免自调用**：通过注入自身或 AopContext.currentProxy()
3. **事务粒度要小**：不要在长方法上加一个大事务
4. **只读事务优化**：查询方法加 `@Transactional(readOnly = true)`，某些数据库会优化
5. **慎用 REQUIRES_NEW**：每个 REQUIRES_NEW 会开启新连接，注意连接池耗尽
6. **异常一定要抛出去**：不要 try-catch 吃掉异常
7. **多数据源时指定事务管理器**：`@Transactional("primaryTransactionManager")`

### 检查事务是否生效的小技巧

```yaml
# application.yml
logging:
  level:
    org.springframework.transaction: DEBUG
    org.springframework.jdbc.datasource: DEBUG
```

日志中看到 `Creating new transaction` 和 `Committing JPA transaction` 代表事务生效了。

## 总结

理解了 @Transactional 的 AOP 代理机制，你就能解释所有失效场景——**本质都是因为事务增强依赖 AOP 代理，而自调用、非 public 方法、异常被吞掉等因素让 AOP 增强没有机会执行**。

面试时如果能从 TransactionInterceptor 源码的角度讲出 @Transactional 的原理，再结合实际场景聊聊 13 个"坑"，绝对能征服面试官。
