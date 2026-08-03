---
title: 面试官：Spring 事务失效的 8 大场景，你踩过几个？
date: 2026-08-03 08:00:00
tags:
  - Java
  - Spring
  - 事务
  - 面试
categories:
  - Java
  - Spring
author: 东哥
---

# 面试官：Spring 事务失效的 8 大场景，你踩过几个？

## 面试官：@Transactional 加在方法上，事务就一定生效吗？

很多人以为只要加上 `@Transactional`，方法里所有 SQL 就自动具备原子性了。但实际生产里"事务悄悄失效"的案例比比皆是：**日志里明明打印了异常，数据却提交了**。今天我们把 Spring 事务失效的 8 大经典场景全部列出来，每个都带代码示例、失效原因和解决方案。

先记住一句话：**Spring 声明式事务的本质是 AOP 动态代理**，所有失效场景，追根溯源都是"代理没生效"或"回滚条件没满足"。

## 场景 1：方法不是 public 的

```java
@Service
public class OrderService {

    @Transactional
    private void createOrder() {   // ❌ private 方法
        // 插入订单...
    }
}
```

**失效原因**：Spring 的 `AbstractFallbackTransactionAttributeSource` 在解析事务属性时，默认只处理 public 方法。`@Transactional` 加在 private / protected / 包可见方法上，事务属性根本不会被解析到，代理不会拦截。

**解决**：事务方法必须是 `public`。如果想控制可见性，可以把事务逻辑抽到独立的 public Service 方法里。

## 场景 2：同类内部方法自调用（self-invocation）

```java
@Service
public class OrderService {

    public void createOrderAndPay() {
        this.createOrder();   // ❌ 自调用，走 this，不走代理
    }

    @Transactional
    public void createOrder() {
        // 插入订单...
    }
}
```

**失效原因**：Spring 事务靠 AOP 代理实现。外部调用 `orderService.createOrderAndPay()` 时走的是**代理对象**，但 `createOrderAndPay()` 内部用 `this.createOrder()` 调用的是**原始对象**的方法，直接绕过了代理，`@Transactional` 自然不生效。

**解决**（三种）：
1. 把事务方法放到**另一个 Service/Bean** 里，通过注入的代理对象调用；
2. 注入自身代理：`@Autowired private OrderService self;` 然后 `self.createOrder()`；
3. 用 `AopContext.currentProxy()`（需要 `@EnableAspectJAutoProxy(exposeProxy = true)`）：

```java
((OrderService) AopContext.currentProxy()).createOrder();
```

## 场景 3：方法被 final 修饰

```java
@Transactional
public final void createOrder() {   // ❌ final 方法
}
```

**失效原因**：Spring 默认使用 **JDK 动态代理**（基于接口）或 **CGLIB 代理**（基于继承）。CGLIB 通过生成目标类的子类来代理，**final 方法无法被重写**，代理类无法拦截，事务失效。JDK 动态代理下，final 方法连代理入口都没有。

**解决**：不要用 final 修饰事务方法；Spring Boot 2.x+ 默认 `proxy-target-class=true` 用 CGLIB，遇到 final 直接报错或失效。

## 场景 4：异常被 try-catch 吞掉

```java
@Transactional
public void createOrder() {
    try {
        orderMapper.insert(order);
        throw new RuntimeException("库存不足");
    } catch (Exception e) {
        log.error("下单失败", e);   // ❌ 异常被吞，事务不感知
    }
}
```

**失效原因**：Spring 事务回滚靠**异常传播**触发。异常在方法内部被捕获并处理，事务拦截器根本看不到异常，自然认为"执行成功"，提交事务——脏数据落库。

**解决**：
- 事务方法内**不要捕获异常**，让异常抛给事务拦截器；
- 必须捕获处理时，捕获后**手动回滚**：

```java
try {
    orderMapper.insert(order);
} catch (Exception e) {
    TransactionAspectSupport.currentTransactionStatus().setRollbackOnly();
    throw e;   // 或者重新抛出 RuntimeException
}
```

## 场景 5：抛出的异常不是 RuntimeException（回滚条件不匹配）

```java
@Transactional
public void createOrder() throws IOException {
    orderMapper.insert(order);
    throw new IOException("文件写入失败");   // ❌ 默认不回滚！
}
```

**失效原因**：Spring 的默认回滚策略是**只对 RuntimeException 和 Error 回滚**（`rollbackFor = RuntimeException.class` 是默认值）。受检异常（Checked Exception，如 IOException、SQLException）默认**不回滚**，因为 Spring 认为"业务上已处理的受检异常不算失败"。

**解决**：显式指定回滚异常类型：

```java
@Transactional(rollbackFor = Exception.class)   // ✅ 推荐，所有异常都回滚
// 或
@Transactional(rollbackFor = IOException.class)
```

**经验**：生产代码一律写 `rollbackFor = Exception.class`，不要依赖默认值，这是最隐蔽也最常见的失效场景。

## 场景 6：类没有被 Spring 管理（没有成为 Bean）

```java
public class OrderService {   // ❌ 没加 @Service，也没在配置类注册
    @Transactional
    public void createOrder() { }
}
```

**失效原因**：`@Transactional` 是由 Spring 容器中的代理 Bean 实现的。类根本不是 Bean（没有 `@Service`/`@Component`，或没被 `@Bean` 注册，或没被包扫描扫到），代理都无从谈起。

**解决**：确认类被 Spring 管理（加 `@Service` 等注解，且所在包在 `@ComponentScan` 扫描范围内）。

## 场景 7：数据库引擎不支持事务

```java
-- MyISAM 引擎不支持事务！
CREATE TABLE t_order (...) ENGINE = MyISAM;
```

**失效原因**：这不是 Spring 的问题，是**数据库本身不支持**。MyISAM 没有事务和行锁概念，`@Transactional` 加了也白加。MySQL 8.0 之前的默认引擎是 MyISAM 的场景，或者表被误建为 MyISAM，都会"事务失效"。

**解决**：表引擎统一使用 **InnoDB**（支持事务、行级锁、崩溃恢复）。

## 场景 8：多线程/跨线程调用

```java
@Transactional
public void createOrder() {
    new Thread(() -> {
        orderMapper.insert(order);   // ❌ 新线程里执行 SQL
    }).start();
}
```

**失效原因**：Spring 事务是通过 **ThreadLocal** 绑定数据库连接的（`DataSourceTransactionManager` 把 connection 存在当前线程）。新起的线程拿不到主线程的事务连接，它执行的是**独立连接上的独立操作**，主线程回滚它也不受影响——数据照样提交。

**解决**：事务方法内**不要开多线程**；子线程操作要么独立事务（自求多福），要么把子线程的活改成主线程同步执行，或使用 `TransactionTemplate` 在子线程内手动开启独立事务。

## 附：其他易踩的坑

| 坑 | 说明 |
|----|------|
| `@Transactional` 加在接口上 | 基于接口代理时有效，但 CGLIB 下不可靠，**规范是加在实现类方法上** |
| 传播行为配置错误 | 如 `REQUIRES_NEW` 内层异常不影响外层（独立事务），看起来像"失效"，其实是语义不同 |
| 自增主键 + 批量插入 | 不是失效，但大事务容易锁竞争、长事务导致连接池耗尽 |
| 事务与锁混用 | 先锁后事务提交、锁释放时机不对导致死锁 |
| `@Transactional` 在 `@Async` 方法上 | 异步方法本身就是独立线程执行，事务随线程走，跨线程问题同上 |

## 面试追问整理

**Q1：为什么 Spring 默认只对 RuntimeException 回滚？**
答：设计哲学上，受检异常代表"业务上预期内、可恢复"的情况（如 IO 失败），而运行时异常代表"程序错误"。默认不回滚受检异常可以避免误回滚业务已处理的场景。但实际开发中我们通常显式配置 `rollbackFor = Exception.class` 让所有异常都回滚，保证数据安全。

**Q2：自调用为什么事务不生效？AOP 的原理是什么？**
答：声明式事务基于动态代理：Spring 启动时为目标 Bean 创建代理对象，调用方法时先经过代理拦截器（`TransactionInterceptor`），它开启/提交/回滚事务。自调用时 `this` 指向原始对象而非代理，绕过了拦截器，事务逻辑从未执行。

**Q3：CGLIB 代理和 JDK 动态代理有什么区别？对事务有什么影响？**
答：JDK 动态代理要求目标类实现接口，基于 `InvocationHandler`；CGLIB 通过生成目标类的子类实现，不要求接口。CGLIB 不能代理 final 类和方法。Spring Boot 2.x 默认 CGLIB。对事务的影响就是：final 方法/类在 CGLIB 下无法被拦截。

**Q4：事务传播行为 REQUIRED 和 REQUIRES_NEW 的区别？**
答：REQUIRED（默认）：有事务则加入，没有则新建；REQUIRES_NEW：无论有没有都新开一个独立事务，外层回滚不影响内层已提交的事务。所以"内层抛异常外层捕获后事务还能提交"这种看起来像失效的现象，其实是 REQUIRES_NEW 的正常语义。

**Q5：大事务有什么危害？怎么避免？**
答：危害：① 长事务持有连接和行锁，连接池耗尽、锁竞争加剧；② undo log 膨胀；③ 主从延迟。避免：事务只包必要的写操作，读操作移出事务；批量操作分批提交；用编程式事务 `TransactionTemplate` 精确控制边界。

## 总结

事务失效八大场景，背下来不如理解透：**代理（1、2、3、6 场景）+ 异常传播（4、5 场景）+ 线程与存储（7、8 场景）** 三条主线。面试时先讲本质（AOP 代理），再展开场景，最后给出 `rollbackFor = Exception.class` + 自调用处理等实践建议，就是一份高分答案。而开发时记住一句口诀：**public 方法、走代理、不吞异常、rollbackFor 显式配**。
