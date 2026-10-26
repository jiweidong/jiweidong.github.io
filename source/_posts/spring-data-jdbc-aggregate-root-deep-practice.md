---
title: 【Spring 实战】Spring Data JDBC 深度实战：聚合根、领域事件与 JPA 的边界
date: 2026-10-26 08:15:00
tags:
  - Spring
  - Spring Data JDBC
  - DDD
  - 聚合根
  - 领域事件
  - Java
categories:
  - Spring 全家桶
author: 东哥
---

# 【Spring 实战】Spring Data JDBC 深度实战：聚合根、领域事件与 JPA 的边界

## 前言

Spring 生态里做持久层，通常三选一：MyBatis（SQL 可控）、JPA/Hibernate（对象映射强）、JdbcTemplate（够底层）。Spring Data JDBC 长期被忽略，很多人甚至不知道它和 JPA 是两套东西。

它的定位非常清晰：**用 DDD 聚合根模型做持久化，不做脏检查、不做懒加载、不做会话缓存，一条 SQL 就是一次数据库往返。**

我把它用在几个中台项目后，最大的感受是：**它逼你把「聚合边界」想清楚**。想清楚了，代码结构比 JPA 干净得多；想不清楚，就会踩「只保存了根对象、子对象没落库」的坑。

这篇文章从模型、映射、仓储、领域事件、对比选型到生产踩坑，完整讲一遍。

## 一、Spring Data JDBC 的设计哲学

一句话：**Aggregate = 一致性边界 = 一次事务里加载/保存的最小单元。**

它有三条铁律：

1. **只有聚合根有 Repository**。子实体不能单独查询、单独保存，必须通过根。
2. **保存根 = 保存整个聚合**。新增/更新/删除子对象，都由根的一次 `save` 完成。
3. **没有懒加载**。加载根时按定义把整个聚合查出来（可配置是否 eager），不存在 `LazyInitializationException`，也不存在 N+1 的隐式触发。

这跟 JPA 的「托管态 + 脏检查 + 懒加载」是完全相反的取舍：

| 维度 | Spring Data JDBC | JPA / Hibernate |
|---|---|---|
| 实体状态 | 无托管态，保存即全量写 | 托管/游离，脏检查自动 flush |
| 加载策略 | 聚合内 eager，聚合间手动 | 懒加载 + 代理 |
| 子对象 | 属于聚合，随根保存 | 独立实体，可单独操作 |
| SQL 可控性 | 高（可 `@Query` 写原生） | 中（生成 SQL，调优靠 hint） |
| 学习成本 | 低（就是对象 + SQL） | 高（会话、缓存、级联、锁） |
| 复杂关联 | 不擅长（跨聚合 join） | 擅长 |
| 批量写入 | 一般 | 好（batch） |

**适用场景**：领域模型清晰、聚合边界明确、读多写少或写入以聚合为单位、团队不想背 Hibernate 的心智负担。**不适用**：复杂多表报表查询、需要二级缓存、遗留数据库模型混乱。

## 二、聚合根建模

以一个订单为例：

- 聚合根：`Order`
- 聚合内实体：`OrderItem`（没有独立生命周期，脱离订单无意义）
- 值对象：`Address`、`Money`
- 跨聚合引用：`customerId`（**只存 ID，不存对象**）

```java
@Table("t_order")
public class Order {

    @Id
    private Long id;

    private Long customerId;          // 跨聚合只存 ID
    private String status;
    private BigDecimal totalAmount;

    @Column("created_at")
    private Instant createdAt;

    @Version
    private Long version;             // 乐观锁

    @MappedCollection(idColumn = "order_id", keyColumn = "seq")
    private List<OrderItem> items = new ArrayList<>();

    // 领域行为，而不是 setter 满天飞
    public void addItem(String sku, int qty, BigDecimal price) {
        if (!"CREATED".equals(status)) {
            throw new IllegalStateException("订单已提交，不能追加商品");
        }
        items.add(new OrderItem(sku, qty, price));
        recalculateTotal();
    }

    public void submit() {
        if (items.isEmpty()) {
            throw new IllegalStateException("空订单不能提交");
        }
        this.status = "SUBMITTED";
    }

    private void recalculateTotal() {
        this.totalAmount = items.stream()
            .map(i -> i.price().multiply(BigDecimal.valueOf(i.qty())))
            .reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    // 供框架使用
    protected Order() {}
}
```

```java
@Table("t_order_item")
public class OrderItem {

    @Id
    private Long id;
    private String sku;
    private int qty;
    private BigDecimal price;

    protected OrderItem() {}

    public OrderItem(String sku, int qty, BigDecimal price) {
        this.sku = sku;
        this.qty = qty;
        this.price = price;
    }

    public BigDecimal price() { return price; }
    public int qty() { return qty; }
}
```

注意几个细节：

- **无参构造必须有**（可以是 `protected`），框架要用反射实例化。
- `@MappedCollection` 声明「这是聚合内的集合」，`idColumn` 是外键列，`keyColumn` 是顺序列。
- `@Version` 做乐观锁，`save` 时自动带上 `WHERE version = ?`，冲突抛 `OptimisticLockingFailureException`。
- **不要给子实体加 `@Table` 之外的注解去搞关联**，它不是独立实体。

## 三、仓储：只暴露根

```java
public interface OrderRepository extends CrudRepository<Order, Long> {

    List<Order> findByCustomerId(Long customerId);

    @Query("SELECT * FROM t_order WHERE status = :status AND created_at >= :from")
    List<Order> findRecentByStatus(String status, Instant from);

    @Modifying
    @Query("UPDATE t_order SET status = :status WHERE id = :id AND status = 'CREATED'")
    int markSubmitted(Long id, String status);
}
```

关键点：

- **继承 `CrudRepository` 而不是 `JpaRepository`**（后者是 JPA 的）。
- 派生查询支持 `findByXxx`、`And`、`Or`、`In`、`OrderBy` 等，但**不支持跨聚合 join**。
- `@Modifying` 的更新语句绕过实体状态，直接打库；用它做「状态机流转」比加载整个聚合再保存更轻。
- 自定义复杂查询建议用 `JdbcTemplate` 或 QueryDSL，别硬拗。

### 3.1 一次 save 发生了什么

```java
Order o = repository.findById(1L).orElseThrow();  // SELECT 主表 + SELECT 子表
o.addItem("SKU-2", 1, new BigDecimal("99.00"));
repository.save(o);
// UPDATE t_order SET ..., version = version + 1 WHERE id = ? AND version = ?
// DELETE FROM t_order_item WHERE order_id = ?
// INSERT INTO t_order_item (...) VALUES (...), (...)
```

**注意那个 `DELETE` + 全量 `INSERT`**。Spring Data JDBC 对聚合内集合采用「先删后插」策略，而不是逐条 diff。这带来两个后果：

1. 子表数据量大时，写入放大明显。
2. **子表上的自增 ID 会不断变化**，如果外部系统引用了子表 ID，会出问题。

优化手段：子集合用 `Set` 而不是 `List` 可以让框架做 diff（取决于版本），或者把大集合拆成独立聚合（比如订单项超过 50 条就分表/分聚合）。

## 四、领域事件：聚合与外部解耦

Spring Data JDBC 支持 `@DomainEvents`，在 `save` 之后发布事件：

```java
@Table("t_order")
public class Order {

    @Transient
    private final List<Object> domainEvents = new ArrayList<>();

    public void submit() {
        this.status = "SUBMITTED";
        domainEvents.add(new OrderSubmittedEvent(this.id, this.customerId, this.totalAmount));
    }

    @DomainEvents
    Collection<Object> domainEvents() {
        return List.copyOf(domainEvents);
    }

    @AfterDomainEventPublication
    void clearEvents() {
        domainEvents.clear();
    }
}
```

```java
@Component
public class OrderSubmittedListener {

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onSubmitted(OrderSubmittedEvent e) {
        // 事务提交后才发 MQ / 发短信，避免「消息发了但事务回滚」
        rabbitTemplate.convertAndSend("order.sync", "order.submitted", e);
    }
}
```

**必须用 `@TransactionalEventListener(AFTER_COMMIT)`**。用普通 `@EventListener` 会在事务提交前触发，一旦后续回滚，下游就收到了不存在的订单——这是分布式系统里最经典的「消息与数据不一致」来源。

## 五、与 JPA / MyBatis 的选型决策

| 场景 | 推荐 |
|---|---|
| DDD 聚合、写模型清晰、团队接受「一个聚合一次事务」 | Spring Data JDBC |
| 复杂对象图、多表关联、需要二级缓存、遗留系统 | JPA / Hibernate |
| 报表、复杂 SQL、DBA 要把控执行计划 | MyBatis |
| 简单 CRUD、内部工具、原型 | Spring Data JDBC 或 JdbcTemplate |
| 读写分离 + CQRS | 写用 Spring Data JDBC，读用 MyBatis/JdbcTemplate |

我的实际组合：**写侧 Spring Data JDBC（聚合）+ 读侧 MyBatis/`JdbcTemplate`（DTO 投影）**。写侧保证一致性边界，读侧保证 SQL 可控，各取所长。

## 六、生产踩坑清单

| 坑 | 现象 | 根因 | 解决 |
|---|---|---|---|
| 子对象没落库 | 保存成功但子表为空 | 子集合没加 `@MappedCollection` | 加注解并确认 `idColumn` |
| 子表 ID 每次变 | 外部引用失效 | 集合「先删后插」 | 子表用业务键，不暴露自增 ID |
| 更新整聚合很慢 | 大聚合 save 耗时长 | 全量 delete+insert | 拆分聚合 / 用 `@Modifying` 局部更新 |
| 乐观锁频繁失败 | 并发下大量 409 | 聚合太大、争用高 | 缩小聚合 / 重试 / 改用状态机 SQL |
| 跨聚合 join 报错 | 派生查询不支持 | 框架不跨聚合 | 用 `@Query` 手写或读侧另做 |
| 事件在回滚后发出 | 下游收到脏数据 | 用了 `@EventListener` | 改 `@TransactionalEventListener` |
| N+1 依然存在 | 列表页 SQL 很多 | 逐个 `findById` 加载聚合 | 批量查询 + 内存组装 |
| DDL 靠 `ddl-auto` | 生产表结构漂移 | Spring Data JDBC 不管理 DDL | 用 Flyway/Liquibase |
| `Instant` 时区错乱 | 时间差 8 小时 | 驱动/JDBC URL 时区未配 | 统一 UTC 存储 + `serverTimezone` |
| 批量插入慢 | 1 万条要几十秒 | 默认逐条 batch | 配 `spring.jdbc.template.batch-size` + 重写 `saveAll` |

### 6.1 一个真实的性能事故

订单聚合包含最多 200 个明细，`save` 时「删 200 + 插 200」，一次下单写 400 行。大促期间单库 TPS 被打到 3000，磁盘 IO 直接饱和。

改法：

1. 明细超过 30 条时，把订单拆成「订单头 + 分批明细」两个聚合，明细用独立仓储按 `orderId` 批量插入。
2. 订单头只保留汇总字段，`save` 从 400 行降到 3 行。
3. 读侧用一条 join 查询组装 DTO。

改造后下单链路 P99 从 480ms 降到 90ms。**教训：聚合边界不是「模型上属于一起」就够，还要考虑写入放大。**

## 七、面试常见追问

**Q1：Spring Data JDBC 和 Spring Data JPA 有什么本质区别？**
JPA 是 ORM，有持久化上下文、脏检查、懒加载、一级/二级缓存，实体在事务内是「托管」的，flush 时才生成 SQL；Spring Data JDBC 没有这些，实体就是普通对象，`save` 立即执行 SQL，聚合内全量读写。前者灵活但心智负担重，后者简单但要求聚合边界清晰。

**Q2：为什么 Spring Data JDBC 只允许聚合根有 Repository？**
因为聚合是事务一致性的最小单元。允许子实体独立操作会破坏不变量（比如单独删一条明细导致总额与明细不一致）。强制通过根操作，业务规则才有唯一入口。

**Q3：`@Version` 的实现原理？**
`save` 时如果实体带版本号，生成 `UPDATE ... SET version = version + 1 WHERE id = ? AND version = ?`；影响行数为 0 说明被其他事务改过，抛 `OptimisticLockingFailureException`。插入时版本初始化为 0。它防的是「读-改-写」丢失更新，不防幻读。

**Q4：领域事件为什么必须 AFTER_COMMIT？**
事件在事务内发布时，如果后续操作回滚，事件已经发出去了，下游会基于不存在的数据做动作。`AFTER_COMMIT` 保证只有事务真正提交才发布。但要注意：提交后发布失败（比如 MQ 挂了）不会回滚事务，所以还需要 outbox 表兜底。

**Q5：聚合内集合的保存策略是什么？能改成 diff 吗？**
默认「删除所有子行 + 重新插入」。部分版本对 `Set` 类型会做差量比较。工程上更可靠的做法是控制聚合大小，或用 `@Modifying` 手写增量 SQL，不要依赖框架的 diff 优化。

## 总结

Spring Data JDBC 不是一个「简化版 JPA」，而是**另一套世界观**：用聚合边界换掉会话与懒加载的复杂度。

用好它的三个前提：

1. **先画聚合边界**，再写实体。跨聚合只存 ID。
2. **控制聚合大小**。子集合超过几十条就考虑拆分，避免写入放大。
3. **读写分离**。写侧用聚合保一致，读侧用 SQL 保性能。

如果你的项目正被 Hibernate 的懒加载、级联、脏检查折腾得死去活来，而领域模型又相对清晰，Spring Data JDBC 值得认真试一次。
