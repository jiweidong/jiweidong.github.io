---
title: 分布式事务从理论到实战（Seata + MQ 方案）
date: 2026-06-13 11:29:00
updated: 2026-06-13 11:29:00
tags:
  - 分布式事务
  - Seata
  - TCC
  - Saga
  - 最终一致性
  - CAP
categories: 分布式系统
author: 东哥
---

## 前言

单体应用时代，数据库的 ACID 事务就能保证数据一致性。但微服务架构下，一个业务操作往往横跨多个服务、多个数据库——下单要扣库存、扣余额、创建订单，这些操作如果只用本地事务，必定出现"钱扣了但没下单"的数据不一致问题。

**分布式事务**就是为了解决跨服务、跨库场景下数据一致性的问题。本文从 CAP/BASE 理论出发，逐一拆解 2PC、TCC、Saga、MQ 最终一致性、Seata 等主流方案，帮助大家彻底搞懂分布式事务。

---

## 一、分布式事务理论基础

### 1.1 CAP 理论

CAP 定理是分布式系统的基石，由 Eric Brewer 提出：

| 维度 | 含义 | 说明 |
|------|------|------|
| **C**onsistency（一致性） | 所有节点在同一时刻看到相同数据 | 写入后立刻读取到最新值 |
| **A**vailability（可用性） | 非故障节点总能返回合理响应 | 请求不会一直等待或超时 |
| **P**artition Tolerance（分区容忍性） | 系统能容忍网络分区（节点之间断开） | 是分布式系统的必选项 |

> **核心结论：在分布式系统中，P 是必选的，C 和 A 只能二选一。**

- **CP 系统**：放弃可用性，保证强一致。ZooKeeper、Etcd 就是典型——选举期间不可用。
- **AP 系统**：放弃强一致，保证可用性。Eureka、Nacos 的 AP 模式——注册中心允许读到过期数据。

### 1.2 BASE 理论

BASE 是 CAP 中 AP 方案的延伸：

- **Basically Available**（基本可用）：系统允许降级，而非完全不可用
- **Soft State**（软状态）：允许中间状态，数据副本可以暂时不一致
- **Eventually Consistent**（最终一致性）：经过一段时间后，数据趋于一致

### 1.3 刚性事务 vs 柔性事务

| 类型 | 代表方案 | 特点 |
|------|---------|------|
| **刚性事务** | ACID、XA/2PC | 强一致性、同步阻塞、适合短事务 |
| **柔性事务** | TCC、Saga、MQ 最终一致性 | 最终一致、异步非阻塞、适合长事务 |

> 微服务场景下，绝大多数业务都能接受一段时间的不一致，因此柔性事务是主流选型。

### 1.4 分布式事务的核心问题

两个核心场景：

1. **跨库事务**：同一个服务内操作多个数据库。例如订单库 + 库存库。
2. **跨服务事务**：调用多个微服务，每个服务操作自己的数据库。例如订单服务 + 库存服务 + 账户服务。

跨服务事务比跨库事务更难处理，因为还涉及网络通信的不可靠性。

举个例子：用户下单支付 100 元买一个商品，涉及订单服务（创建订单）、账户服务（扣 100 元）、库存服务（减 1 个库存）。如果不用分布式事务，极端情况下会出现：账户扣了 100 元，但订单没创建成功，库存也没减——钱丢了。

---

## 二、XA 协议（两阶段提交 2PC）

### 2.1 什么是 2PC

2PC（Two-Phase Commit）是最经典的分布式事务协议，由**协调者**和**参与者**组成，分两阶段执行：

**阶段一：准备（投票）**

```
协调者 → 所有参与者: 准备提交（prepare）
参与者 → 协调者:    OK（yes）/ 失败（no）
```

**阶段二：提交（执行）**

- 如果所有参与者都返回 OK → 全局提交（commit）
- 如果有任何一个返回 NO 或超时 → 全局回滚（rollback）

### 2.2 2PC 的三大缺陷

1. **同步阻塞**：参与者持有资源锁，直到协调者发出 commit/rollback，期间无法做其他事。
2. **单点故障**：协调者崩溃后，参与者一直锁定资源。
3. **脑裂问题**：协调者发出 commit 后宕机，部分参与者收到 commit 执行了提交，部分没收到——数据不一致。

### 2.3 3PC 的改进

3PC（Three-Phase Commit）把准备阶段拆为 CanCommit 和 PreCommit 两步，并引入了超时机制：参与者在等待协调者超时后会自动提交，而不是一直阻塞等待。但 3PC 依然无法彻底解决脑裂问题（协调者和部分参与者同时宕机时的数据不一致），而且引入了更复杂的交互流程，实际生产中使用较少。

> 目前业界的主流选择是：**放弃强一致，追求最终一致**——也就是接下来要讲的 TCC、Saga、MQ 方案。

---

## 三、TCC 模式

### 3.1 TCC 概念

TCC 是**业务层面的两阶段提交**，将每个服务操作拆为三步：

| 阶段 | 操作 | 说明 |
|------|------|------|
| **Try** | 预留资源 | 冻结金额、扣减预占库存 |
| **Confirm** | 确认执行 | 真正扣减，完成操作 |
| **Cancel** | 取消回滚 | 释放预留的资源 |

### 3.2 核心要点

```java
// 账户转账的 TCC 示例
public class AccountService {

    @TwoPhaseBusinessAction(name = "transfer", commitMethod = "confirm", rollbackMethod = "cancel")
    public void try( BusinessActionContext ctx,
                     @BusinessActionContextParameter(paramName = "userId") Long userId,
                     @BusinessActionContextParameter(paramName = "amount") BigDecimal amount) {
        // 1. 冻结金额
        accountMapper.freezeAmount(userId, amount);
    }

    public void confirm(BusinessActionContext ctx) {
        // 2. 真正扣减（冻结变扣减）
        accountMapper.confirmFreeze(ctx.getActionContext("userId"), ctx.getActionContext("amount"));
    }

    public void cancel(BusinessActionContext ctx) {
        // 3. 解冻金额
        accountMapper.unfreezeAmount(ctx.getActionContext("userId"), ctx.getActionContext("amount"));
    }
}
```

### 3.3 三个关键问题

1. **空回滚**：Try 阶段没执行（如网络超时），Cancel 被调用了——Cancel 要能正确处理空请求。
2. **幂等性**：Confirm 和 Cancel 可能被重复调用——保证幂等。
3. **悬挂**：Try 超时后 Cancel 先执行了，但后来 Try 又成功了——Cancel 后不再执行 Try。

> TCC 是业务侵入性最强的方案，需要为每个操作写 Try/Confirm/Cancel，但也最灵活。

### 3.4 TCC vs 2PC

| 对比维度 | TCC | 2PC |
|---------|-----|-----|
| 资源锁 | 业务预留，不锁数据库 | 锁数据库资源 |
| 性能 | 高（异步解锁） | 低（同步阻塞） |
| 业务侵入 | 高（需实现三阶段） | 低（数据库支持） |
| 一致性 | 最终一致 | 强一致 |

---

## 四、Saga 模式

### 4.1 什么是 Saga

Saga 是长事务解决方案，将一个分布式事务拆分为一系列**本地事务**，每个本地事务对应一个**补偿事务**。如果某个本地事务失败，依次执行之前的事务的补偿操作回滚。

### 4.2 两种实现方式

**Choreography（编排）**

```
下单 → 发消息 → 库存扣减 → 发消息 → 账户扣款 → 发消息 → ...
```

每个服务完成后发布事件，下一个服务监听事件触发。优点是无中心，缺点是流程耦合。

**Orchestration（协调）**

```
协调器: 下订单 → 扣库存 → 扣账户 → 确认完成
协调器: 如果失败 → 取消订单 → 加库存 → 加账户
```

由协调器统一调度，流程清晰，适合复杂业务。

### 4.3 补偿实现示例

```java
// Saga 正向操作
public void createOrder() { /* 创建订单 */ }
public void deductStock() { /* 扣减库存 */ }
public void deductAccount() { /* 扣减余额 */ }

// Saga 补偿操作
public void compensateCreateOrder() { /* 取消订单 */ }
public void compensateDeductStock() { /* 恢复库存 */ }
public void compensateDeductAccount() { /* 恢复余额 */ }
```

### 4.4 Saga vs TCC

| 对比维度 | Saga | TCC |
|---------|------|-----|
| 资源锁 | 不锁资源，释放快 | Try 阶段预留资源 |
| 隔离性 | 无隔离性，需要业务层处理 | Try 预留天然隔离 |
| 回滚方式 | 反向补偿（已提交的本地事务需回滚） | Cancel 操作 |
| 适用场景 | 长事务、跨多服务 | 短事务、资源竞争高 |

---

## 五、可靠消息最终一致性（MQ 方案）

这是**生产中最常用的柔性事务方案**，核心思想：利用消息队列保证业务操作和消息发送的原子性。

### 5.1 本地消息表（eBay 方案）

```
1. 下单 → 保存订单（本地库） + 插入消息表（同一事务）
2. 定时任务扫描消息表 → 发送 MQ
3. 消费者收到消息 → 扣库存 + 扣余额
4. 消费者处理成功 → 回调更新消息状态为已处理
```

**优点**：实现简单，不依赖 MQ 特性。  
**缺点**：需要建消息表 + 定时扫描，对数据库有压力。

### 5.2 RocketMQ 事务消息

RocketMQ 原生支持事务消息，解决了本地消息表轮询的问题：

```java
// 生产者：发送半消息 + 执行本地事务
TransactionMQProducer producer = new TransactionMQProducer();
producer.setExecutor(executor);
producer.setTransactionListener(new TransactionListener() {

    @Override
    public LocalTransactionState executeLocalTransaction(Message msg, Object arg) {
        // 1. 执行本地事务（创建订单）
        orderService.createOrder((Long) arg);
        // 2. 返回事务状态
        return LocalTransactionState.COMMIT_MESSAGE;
    }

    @Override
    public LocalTransactionState checkLocalTransaction(MessageExt msg) {
        // 3. 回查：如果半消息一直未确认
        Long orderId = msg.getUserProperty("orderId");
        return orderService.isOrderExist(orderId)
            ? LocalTransactionState.COMMIT_MESSAGE
            : LocalTransactionState.ROLLBACK_MESSAGE;
    }
});
```

**事务消息流程**：

```
生产者 → Broker: 半消息（半成品，不可消费）
生产者 → 业务库: 执行本地事务
  成功 → Broker: Commit（消息变为可消费）
  失败 → Broker: Rollback（删除半消息）
Broker → 生产者: 回查（半消息长时间未确认时）
消费者 → Broker: 拉取消息
消费者 → 业务库: 执行业务
消费者 → Broker: ACK（消费成功）
```

### 5.3 最大努力通知（支付宝回调）

```
业务方 → 第三方: 调用接口
第三方 → 业务方: 同步返回结果
第三方 → 业务方: 异步回调（最多重试 N 次）
业务方: 收到回调后确认结果
```

典型场景：支付宝支付回调、短信发送回调。发送方尽最大努力通知，接收方需保证幂等。

---

## 六、Seata 分布式事务框架

Seata 是阿里巴巴开源的一站式分布式事务解决方案，**开箱即用**，对业务代码的侵入最小。

### 6.1 三大组件

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  TC              │      │  TM              │      │  RM              │
│  Transaction     │      │  Transaction     │      │  Resource        │
│  Coordinator     │      │  Manager         │      │  Manager         │
│  （事务协调器）   │      │  （事务管理器）   │      │  （资源管理器）   │
│  维护全局事务     │      │  开启/提交/回滚   │      │  管理分支资源     │
│  分支状态        │      │  全局事务        │      │  注册分支        │
└────────┬────────┘      └────────┬─────────┘      └────────┬─────────┘
         │                         │                        │
         └─────────────────────────┼────────────────────────┘
                                   │
                          ┌────────┴─────────┐
                          │  业务服务（多个）   │
                          │  每个服务嵌入 TM+RM │
                          └──────────────────┘
```

### 6.2 AT 模式（自动补偿）

AT（Automatic Transaction）是 Seata 的最大亮点，对业务**零侵入**：开发者只需要写普通的 SQL，Seata 通过拦截 JDBC 数据源自动完成分布式事务的提交和回滚。

**原理核心**：Seata 在执行 SQL 之前自动记录数据的前后快照（undo_log），如果全局事务需要回滚，Seata 利用这些快照生成逆向 SQL 恢复数据。

看一个具体的例子：一个跨库转账业务——用户下单时同时扣库存、扣余额、建订单，三个操作在三个不同的数据库里：

```java
@GlobalTransactional
public void createOrder(OrderDTO order) {
    // 这些是普通 SQL，业务只关心自己的逻辑
    orderMapper.insert(order);    // 数据库1：订单库
    inventoryService.deduct();     // 数据库2：库存库
    accountService.deduct();       // 数据库3：账户库
}
```

Seata 在执行过程中做了什么？

1. 拦截 `orderMapper.insert`：自动生成 insert 语句的前后镜像，存入 undo_log 表
2. 拦截远程调用 `inventoryService.deduct()`：通过 RPC 上下文传递 XID，库存服务 RM 自动注册分支事务
3. 全部成功 → 全局提交，删除 undo_log
4. 任何一步失败 → 全局回滚，Seata 根据 undo_log 自动生成对应的 DELETE / UPDATE 语句恢复数据

这就是**自动补偿**——开发者只需要加一个 `@GlobalTransactional` 注解，连回滚都不用写。

```sql
-- 1. 执行业务 SQL（用户写的普通 SQL）
UPDATE account SET money = money - 100 WHERE id = 1;

-- 2. Seata 自动记录前后镜像
-- 前镜像: SELECT money FROM account WHERE id = 1;  -- 500
-- 后镜像: SELECT money FROM account WHERE id = 1;  -- 400

-- 3. 如果全局事务回滚，Seata 自动生成逆向 SQL
UPDATE account SET money = 500 WHERE id = 1;
```

**AT 模式工作流程**：

```
TM → TC: 开启全局事务（获取 XID）
   RM → TC: 注册分支事务
   RM: 执行业务 SQL + 自动生成 undo_log
   RM → TC: 报告分支状态
TM → TC: 发起全局提交 / 回滚
   TC → RM: 通知分支提交 / 回滚
      RM: 提交 → 删除 undo_log
      RM: 回滚 → 根据 undo_log 逆向 SQL 回滚
```

### 6.3 AT vs TCC vs Saga 对比表

| 特性 | AT 模式 | TCC 模式 | Saga 模式 |
|------|---------|----------|-----------|
| **业务侵入** | 无（完全透明） | 高（需写三阶段） | 中（需写补偿） |
| **隔离性** | 全局锁保证读隔离 | Try 预留天然隔离 | 无隔离 |
| **性能** | 中（需全局锁） | 高 | 高 |
| **回滚粒度** | 自动逆向 SQL | 代码手动实现 | 代码手动实现 |
| **学习成本** | 低 | 高 | 中 |
| **适用场景** | 通用的微服务场景 | 高并发、短事务 | 长事务、跨多服务 |
| **一致性** | 最终一致 | 最终一致 | 最终一致 |

### 6.4 Seata 与 Spring Cloud 集成

```yaml
# application.yml
seata:
  enabled: true
  application-id: order-service
  tx-service-group: my_tx_group
  config:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
  registry:
    type: nacos
    nacos:
      server-addr: 127.0.0.1:8848
```

```java
// 一个注解开启全局事务
@GlobalTransactional(name = "create-order", timeoutMills = 60000)
public void createOrder(OrderDTO order) {
    // 1. 创建订单（本地事务）
    orderMapper.insert(order);
    // 2. 扣减库存（远程调用，每个服务都有自己的数据库）
    inventoryFeignClient.deduct(order.getProductId(), order.getQuantity());
    // 3. 扣减余额（远程调用）
    accountFeignClient.deduct(order.getUserId(), order.getAmount());
    // 4. 任意一步失败 → 全局回滚
}
```

> 上述代码中，`@GlobalTransactional` 会自动拦截方法执行前后的事务状态。任何一个远程调用失败，Seata 都会回滚所有已执行的本地事务，开发者无需写任何补偿代码。

---

## 七、高频面试题

### 7.1 跨库转账如何保证数据一致性

> 用户 A 给用户 B 转账 100 元，A 账户在库 1，B 账户在库 2，如何保证一致性？

**推荐方案**：Seata AT 模式

```java
@GlobalTransactional
public void transfer(Long fromId, Long toId, BigDecimal amount) {
    accountMapper.deduct(fromId, amount);           // A 扣款（库1）
    accountMapper.add(toId, amount);                // B 加款（库2）
    // 任一失败，Seata 自动回滚
}
```

如果不引入框架，可使用**可靠消息最终一致性**：A 扣款成功后发 MQ 消息，B 端消费消息后加款。

### 7.2 分布式事务的最终实现方案选择表

| 业务场景 | 推荐方案 | 原因 |
|---------|---------|------|
| 金融转账、支付 | TCC | 需强隔离、不漏钱 |
| 电商下单（订单+库存+账户） | Seata AT | 侵入低、开发快 |
| 跨长周期（如旅行预订） | Saga | 流程长、可异步 |
| 消息通知类（如积分、日志） | MQ 最终一致 | 性能高、容忍延迟 |
| 和老系统对接 | 最大努力通知 | 适合不可靠的第三方 |

### 7.3 Kafka vs RocketMQ 事务消息对比

MQ 选型也是分布式事务方案中的重要决策：

| 对比维度 | RocketMQ 事务消息 | Kafka 事务 |
|---------|------------------|-----------|
| **半消息机制** | 原生支持（半消息 + 回查） | 不支持，需自己实现本地消息表 |
| **事务回查** | Broker 主动回查生产者 | 无回查机制 |
| **实现复杂度** | 低（框架自带） | 中（需额外开发） |
| **适用场景** | 对一致性要求高的分布式事务 | 流处理场景的数据一致性 |

> 如果团队已经用 RocketMQ，事务消息是 MQ 最终一致性方案的最佳选择；如果用的是 Kafka，可以结合本地消息表实现类似效果。

### 7.4 为什么要用分布式事务而不是 try-catch

很多新手会说："我用 try-catch 手动回滚不行吗？"

```java
try {
    orderService.create();       // 成功
    inventoryService.deduct();   // 失败
    // 手动回滚
    orderService.cancel();       // ⚠️ 如果这里也失败了呢？
} catch (Exception e) {
    orderService.cancel();       // ⚠️ 网络异常、服务宕机怎么办？
}
```

**致命问题**：

1. **cancel 也可能失败**——你无法保证回滚一定成功
2. **网络超时**——try 阶段成功但返回超时，你以为失败了去回滚，结果补偿了已成功的操作
3. **并发问题**——cancel 和另一个请求的 try 可能同时执行
4. **缺乏全局视图**——跨多个服务做 try-catch 回滚，没有统一的事务上下文

> 分布式事务框架解决的问题正是这些：全局状态管理、自动补偿、幂等控制、并发隔离。

---

## 总结

分布式事务没有银弹，每种方案都有其适用场景：

- **追求强一致、短事务** → 考虑 XA/2PC（但性能是硬伤）
- **业务简单、追求开发效率** → **Seata AT 模式**是最佳选择
- **高并发、资源竞争激烈** → **TCC** 能释放资源更快
- **长事务、跨服务多** → **Saga** 适合编排长流程
- **能接受延迟、性能优先** → **MQ 最终一致性**是你的菜

理解理论、选对方案、用好工具，分布式事务就不再可怕。

> 📌 **一句话总结**：Seata AT 模式用最少的代码解决了 80% 的分布式事务场景，是绝大多数微服务项目的首选。

## 参考

- [Seata 官方文档](https://seata.apache.org/zh-cn/) - 阿里分布式事务框架
- [RocketMQ 事务消息](https://rocketmq.apache.org/) - 消息最终一致性
- [CAP 定理](https://en.wikipedia.org/wiki/CAP_theorem) - 分布式系统理论基础
- [Saga 论文](https://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf) - Hector Garcia-Molina

---

> 如果本文对你有帮助，欢迎收藏转发。更多分布式系统文章持续更新中。
