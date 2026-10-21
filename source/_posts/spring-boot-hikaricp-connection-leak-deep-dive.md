---
title: 【Spring Boot 实战】连接池耗尽与连接泄漏排查：HikariCP 参数、堆栈定位与根因治理
date: 2026-10-21 08:20:00
tags:
  - Java
  - Spring Boot
  - HikariCP
  - 数据库
  - 生产排查
categories:
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】连接池耗尽与连接泄漏排查

## 前言

这个报错，做过线上 Java 的人应该都见过：

```
HikariPool-1 - Connection is not available, request timed out after 30000ms.
```

它出现的时候，通常伴随三个现象：

1. 所有涉及数据库的接口全部卡住，30 秒后统一超时；
2. 不涉及数据库的接口（纯缓存、纯计算）正常；
3. 重启后立刻恢复，但过几小时又复发。

很多人的第一反应是「连接池太小，调大 `maximumPoolSize`」。这个操作有 50% 的概率让问题更严重——因为如果是**连接泄漏**，调大池子只是把爆炸时间往后推，同时把数据库的连接数打满，从应用故障升级成数据库故障。

这一篇把连接池耗尽这件事拆开讲：连接的生命周期、HikariCP 的核心参数怎么算、泄漏的六种典型根因、以及一套从指标到代码的定位方法。

---

## 一、一条连接的完整生命周期

### 1.1 从 `getConnection()` 到 `close()`

```
业务代码 dataSource.getConnection()
   ↓
HikariDataSource.getConnection()          ← 30s 超时在这里
   ↓
HikariPool.getConnection()                ← 从 ConcurrentBag 借出 PoolEntry
   ↓
ProxyConnection（Hikari 的包装）
   ↓
业务使用（Statement / ResultSet）
   ↓
connection.close()                        ← 实际是 ProxyConnection.close()
   ↓
HikariPool.recycle()                      ← 归还到 ConcurrentBag
```

关键点：**`close()` 不是关闭 TCP 连接，是归还到池**。`PoolEntry` 内部维护 `lastAccessed`、`lastBorrowed` 时间戳和 `state`（STATE_NOT_IN_USE / STATE_IN_USE / STATE_REMOVED）。

如果你 `getConnection()` 之后忘了 `close()`，这条连接的状态会永远停在 `STATE_IN_USE`，永远不会被 `recycle`，池子的可用连接就少一条。漏 N 次，池子就空了。

### 1.2 池子里的两条「清理线」

HikariCP 有两个后台任务：

- **HouseKeeper**（默认每 30s 跑一次）：检查 `idleTimeout` 和 `maxLifetime`，回收空闲连接和超龄连接；
- **leakDetectionThreshold**（需要显式开启）：检查是否有连接借用超时未归还。

注意：HouseKeeper 的 `maxLifetime` 只能回收 **`STATE_NOT_IN_USE`** 的连接。**泄漏的连接是 `STATE_IN_USE`，永远不会被回收**——这是「重启才能恢复」的根本原因。

---

## 二、参数怎么算，而不是怎么调

先看 HikariCP 的核心参数：

| 参数 | 默认值 | 含义 | 生产建议 |
|---|---|---|---|
| `maximumPoolSize` | 10 | 最大连接数 | **按公式算，不要拍脑袋** |
| `minimumIdle` | = max | 最小空闲连接 | 与 max 相同（避免抖动） |
| `connectionTimeout` | 30000ms | 借连接超时 | 1000~3000ms（快速失败） |
| `idleTimeout` | 600000ms | 空闲回收 | 600000（10 分钟） |
| `maxLifetime` | 1800000ms | 连接最大存活 | **比 DB 的 `wait_timeout` 小 30s** |
| `keepaliveTime` | 0（关闭） | 心跳保活 | 300000（5 分钟） |
| `leakDetectionThreshold` | 0（关闭） | 泄漏检测阈值 | **测试/预发 10000，生产按需** |
| `validationTimeout` | 5000ms | 校验超时 | 3000ms |

### 2.1 `maximumPoolSize` 的估算公式

HikariCP 官方给的公式（PostgreSQL wiki 的经典推导）：

```
connections = ((core_count * 2) + effective_spindle_count)
```

但这个公式是给「纯数据库压测」用的，业务系统不能直接套。业务系统更实用的是**利特尔法则（Little's Law）**：

```
并发连接数 = QPS × 平均持有时间（秒）
```

举例：一个接口 QPS 500，平均 SQL 耗时 5ms，一次请求持有连接 8ms（含网络往返）：

```
500 × 0.008 = 4 条
```

再加 2~3 倍冗余应对毛刺，`maximumPoolSize = 10~12` 就够了。

**关键洞察：连接池不是越大越好。** 数据库的并行处理能力受 CPU 核数限制，100 个连接打到 8 核的 MySQL 上，只会让上下文切换和锁竞争更严重。经验值：

- 4 核 DB：单实例应用池 10~20；
- 8 核 DB：单实例应用池 20~30；
- 多应用共享一个库：**所有应用池之和 < DB 的 `max_connections` × 0.8**。

### 2.2 `maxLifetime` 与 `wait_timeout` 的配合（高频踩坑）

MySQL 的 `wait_timeout` 默认 28800 秒（8 小时），但云数据库（RDS）经常改成 60~600 秒。中间还有 SLB、NAT、防火墙的空闲连接回收，往往是 **300 秒**。

如果你的 `maxLifetime`（默认 30 分钟）大于中间设备的空闲超时（5 分钟），会出现：

1. 连接在池里空闲 5 分钟；
2. 防火墙悄悄把 TCP 连接断了（不发 RST）；
3. 应用拿到这条「僵尸连接」发 SQL；
4. 读到 EOF 或 `Communications link failure`。

**正确配置**：

```yaml
spring:
  datasource:
    hikari:
      max-lifetime: 240000        # 4 分钟 < 中间设备 5 分钟
      keepalive-time: 60000       # 每分钟探活一次
      idle-timeout: 120000
```

`keepaliveTime` 是 HikariCP 4.0.0+ 的能力，它会定期对空闲连接发心跳，比 `validationQuery` 更轻量（不是每个借出都校验，而是后台保活）。

---

## 三、连接泄漏的六种根因

### 根因 1：忘记 close（最基础，也最常见）

```java
// ❌ 错误
Connection conn = dataSource.getConnection();
PreparedStatement ps = conn.prepareStatement(sql);
ResultSet rs = ps.executeQuery();
// 没有 close，异常时更不会 close

// ✅ 正确
try (Connection conn = dataSource.getConnection();
     PreparedStatement ps = conn.prepareStatement(sql);
     ResultSet rs = ps.executeQuery()) {
    // ...
}
```

用 `JdbcTemplate` 的话它内部会正确关闭，但**手动 `new JdbcTemplate` 之外的裸 JDBC 代码**要特别小心。

### 根因 2：`@Transactional` 方法里做远程调用

这是最隐蔽、最高频的一种。

```java
@Transactional
public void createOrder(OrderDTO dto) {
    orderMapper.insert(dto);              // 开启事务，持有连接
    inventoryClient.deduct(dto);          // HTTP 调用，超时 30s！
    couponClient.lock(dto);               // 又一个 HTTP 调用
    // 整个方法期间，这条数据库连接一直被占用
}
```

Spring 的 `@Transactional` 在方法入口就 `getConnection()` 并 `setAutoCommit(false)`，直到方法返回才释放。方法里有 30 秒超时的 HTTP 调用，就意味着**这条连接被占用 30 秒**。

QPS 10 的接口，就能在 3 秒内耗尽 10 条连接。

**治理原则**：**事务边界只包住数据库操作**。远程调用放在事务外，或者用「先本地事务落库 → 事务提交后发消息/调远程」。

```java
public void createOrder(OrderDTO dto) {
    orderService.saveInTransaction(dto);          // 短事务
    inventoryClient.deduct(dto);                  // 事务外
}
```

### 根因 3：流式查询 / 大 ResultSet 未关闭

```java
@Transactional
public void exportAll() {
    try (Connection conn = dataSource.getConnection();
         PreparedStatement ps = conn.prepareStatement(
             "SELECT * FROM t_order", ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
        ps.setFetchSize(Integer.MIN_VALUE);      // MySQL 流式
        ResultSet rs = ps.executeQuery();
        while (rs.next()) {
            // 处理 1000 万行，耗时 20 分钟
        }
    }
}
```

流式查询期间连接一直被占用，**如果并发跑几个导出任务，池子立刻空**。而且 MySQL 流式读取要求连接不能执行其他语句，等于独占。

治理：导出走独立的 DataSource（单独的池），限制并发数（信号量），或者干脆走离线任务 + 游标分页。

### 根因 4：异步线程里传递连接

```java
@Transactional
public void handle() {
    ConnectionHolder holder = (ConnectionHolder) TransactionSynchronizationManager
        .getResource(dataSource);

    CompletableFuture.runAsync(() -> {
        // 子线程拿不到父线程的 TransactionSynchronizationManager（ThreadLocal）
        // 于是新开一条连接，但父线程的事务还持有原连接
        jdbcTemplate.update("...");
    });
}
```

父线程事务未结束 + 子线程新开连接 = 双倍占用。如果 `runAsync` 里还有阻塞，泄漏更严重。

**永远不要在事务方法里开异步线程做数据库操作。** 如果必须，用 `TransactionTemplate` 在子线程里独立开事务。

### 根因 5：嵌套事务 / `REQUIRES_NEW` 用错

```java
@Transactional
public void outer() {
    inner();   // @Transactional(propagation = REQUIRES_NEW)
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void inner() {
    // 挂起外层事务，从池里再借一条连接
}
```

`REQUIRES_NEW` 会**挂起当前事务并新借一条连接**。如果外层循环调用 100 次，理论上会短暂持有 2 条（挂起的不释放）。在连接池小的情况下，这会导致**自己等自己**的死锁：

- 线程 A 持有连接 1，等连接 2；
- 线程 B 持有连接 2，等连接 1；
- 池子 max=2，永久阻塞。

这是最典型的「连接池死锁」。诊断特征是：`activeConnections == maximumPoolSize`，且线程堆栈里都在 `HikariPool.getConnection`。

### 根因 6：连接被「藏」在静态变量或长生命周期对象里

```java
public class LegacyDao {
    private static Connection conn;   // 💣 灾难

    public static Connection getConn() throws SQLException {
        if (conn == null || conn.isClosed()) {
            conn = DriverManager.getConnection(URL, USER, PWD);
        }
        return conn;
    }
}
```

这种代码在老项目里偶尔能见到。它绕过了连接池，直连数据库，且永不释放。表现是**数据库连接数持续增长**，但应用侧 `HikariPool` 指标正常——因为根本没走池。

---

## 四、定位方法：从指标到堆栈

### 4.1 第一层：看指标

HikariCP 通过 Micrometer 暴露这些指标（Spring Boot Actuator 自动注册）：

| 指标 | 含义 | 异常信号 |
|---|---|---|
| `hikaricp.connections.active` | 正在使用 | 持续 == max |
| `hikaricp.connections.idle` | 空闲 | 长期为 0 |
| `hikaricp.connections.pending` | 等待借连接的线程数 | > 0 且持续增长 |
| `hikaricp.connections.acquire` | 借出总次数 | 速率突增 |
| `hikaricp.connections.timeout` | 超时次数 | > 0 就是故障 |
| `hikaricp.connections.usage` | 持有时间分布 | P99 突增（长事务信号） |

`pending > 0` 是最早的预警信号，比报错早几分钟。建议报警规则：

```yaml
- alert: HikariPoolPending
  expr: hikaricp_connections_pending{pool="HikariPool-1"} > 5
  for: 2m
```

### 4.2 第二层：开 `leakDetectionThreshold`

```yaml
spring:
  datasource:
    hikari:
      leak-detection-threshold: 10000   # 10 秒
```

开启后，如果一条连接被借用超过 10 秒未归还，日志会打出**借用时的完整堆栈**：

```
ERROR c.z.hikari.pool.ProxyLeakTask - Connection leak detection triggered
for connection com.mysql.cj.jdbc.ConnectionImpl@6f1d2a3b, stack trace follows
java.lang.Exception: Apparent connection leak detected
    at com.zaxxer.hikari.HikariDataSource.getConnection(HikariDataSource.java:128)
    at com.example.order.OrderService.createOrder(OrderService.java:57)   ← 就是这里
    at com.example.order.OrderController.submit(OrderController.java:33)
    ...
```

⚠️ **生产环境的注意事项**：

- 这个功能有性能开销（每次借出要调度一个定时任务，归还时取消），QPS 高时 CPU 会涨 3%~5%；
- 阈值不能太小。正常的长查询（报表、批量更新）可能合法持有 10 秒以上，会误报；
- 建议：**预发环境永远开（10s），生产环境按需临时开（30s），排查完关掉**。

### 4.3 第三层：堆栈与线程分析

如果没开泄漏检测，或者泄漏是「逻辑泄漏」（连接确实 close 了，但事务没提交导致连接挂着），用 `jstack` / Arthas：

```bash
# 找到卡在借连接的线程
jstack <pid> | grep -A 20 "HikariPool.getConnection"

# 或者用 Arthas
thread -n 10
```

典型堆栈：

```
"http-nio-8080-exec-23" #123 daemon prio=5 os_prio=0
   java.lang.Thread.State: TIMED_WAITING
        at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:196)
        at com.zaxxer.hikari.HikariDataSource.getConnection(HikariDataSource.java:112)
        at org.springframework.jdbc.datasource.DataSourceTransactionManager.doBegin(...)
        ...
```

如果大量线程都卡在这里，而 `active == max`，就是池子被占满。

再看谁占着连接不还：

```bash
# Arthas 看 PoolEntry 的借用栈（需要 watch HikariPool.getConnection 的返回值）
watch com.zaxxer.hikari.pool.HikariPool getConnection '{returnObj, throwExp}' -x 3
```

### 4.4 第四层：数据库侧交叉验证

应用侧说「我只有 10 个连接」，数据库侧却看到 200 个：

```sql
-- MySQL
SHOW PROCESSLIST;
SELECT user, host, db, command, time, state, info
FROM information_schema.processlist
WHERE db = 'shop' AND command <> 'Sleep'
ORDER BY time DESC;

-- 按 host 聚合，看哪个实例连接最多
SELECT SUBSTRING_INDEX(host, ':', 1) AS client, COUNT(*) AS cnt
FROM information_schema.processlist
GROUP BY client ORDER BY cnt DESC;
```

如果 `Sleep` 状态的连接很多且 `time` 很大，说明是**连接没归还**（池外的直连）或者 **`maxLifetime` 配置不当**。

### 4.5 第五层：堆转储找 `ProxyConnection`

```bash
jmap -dump:live,format=b,file=/tmp/heap.hprof <pid>
# 用 MAT 打开，OQL 查询：
SELECT * FROM com.zaxxer.hikari.pool.ProxyConnection
```

如果 `ProxyConnection` 实例数远超 `maximumPoolSize`，说明有连接没被回收（正常情况下应该恰好等于池大小）。

---

## 五、一套防泄漏的工程规范

### 5.1 事务边界三原则

```java
// ✅ 原则 1：事务方法只做 DB 操作
@Transactional
public void pay(Long orderId) {
    orderMapper.updateStatus(orderId, PAID);
    paymentMapper.insert(...);
}

// ✅ 原则 2：远程调用在事务外
public void handlePay(Long orderId) {
    pay(orderId);                          // 短事务
    notifyService.send(orderId);           // 事务外
}

// ✅ 原则 3：需要跨服务一致性，用本地消息表 + 事务提交后投递
@Transactional
public void createOrder(OrderDTO dto) {
    orderMapper.insert(dto);
    outboxMapper.insert(OutboxEvent.of("ORDER_CREATED", dto.getId()));  // 同库同事务
}
// 事务提交后由独立线程扫描 outbox 发 MQ
```

### 5.2 用 ArchUnit 把规范变成测试

规范写在文档里没人看，写成测试才会被执行：

```java
@AnalyzeClasses(packages = "com.example")
class TransactionBoundaryTest {

    @ArchTest
    static final ArchRule no_remote_call_in_transaction =
        methods()
            .that().areAnnotatedWith(Transactional.class)
            .should(not(callMethodsThat(
                areDeclaredInClassesThat().resideInAnyPackage("..client..", "..feign..")
                    .or(areAnnotatedWith(FeignClient.class))
            )))
            .because("事务方法内禁止远程调用，会长时间占用数据库连接");
}
```

### 5.3 独立的连接池隔离

不同用途的连接不要共用池：

```java
@Configuration
public class DataSourceConfig {

    @Bean
    @Primary
    @ConfigurationProperties("spring.datasource.hikari")
    public DataSource primaryDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }

    /** 报表/导出专用池，容量小、超时短，防止拖垮主业务 */
    @Bean
    @ConfigurationProperties("spring.datasource.report.hikari")
    public DataSource reportDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }
}
```

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20
    report:
      hikari:
        maximum-pool-size: 4
        connection-timeout: 2000
        leak-detection-threshold: 60000
```

这样导出任务把 report 池占满，主业务完全不受影响——这就是**舱壁模式**在数据源层的落地。

---

## 六、面试高频追问

**Q1：连接池越大越好吗？**
不是。数据库的并发处理能力有上限，连接数超过 CPU 核数后，继续增加只会加剧上下文切换和锁竞争。经验公式：`连接数 ≈ 核数 × 2 + 磁盘数`，业务系统按利特尔法则算，所有应用之和不超过 DB `max_connections` 的 80%。

**Q2：`maxLifetime` 为什么要小于 `wait_timeout`？**
因为连接在池中空闲时，数据库或中间网络设备可能单方面断开（不发 RST）。如果 `maxLifetime` 更大，应用会拿到这条已死的连接，报 `Communications link failure`。所以 `maxLifetime` = `min(DB wait_timeout, 中间设备空闲超时) - 30s`。

**Q3：HikariCP 为什么比 Druid 快？**
三个原因：(1) 用 `ConcurrentBag` 做无锁化连接管理，借还都在 ThreadLocal 的本地列表里优先命中；(2) 字节码优化的 `ProxyConnection`，减少方法调用层级；(3) 极简的 `Statement` 缓存（`cachePrepStmts` 交给驱动）。Druid 更强在监控和 SQL 防火墙。

**Q4：`@Transactional` 里调用 HTTP 接口，为什么会耗尽连接池？**
事务开启时 `DataSourceTransactionManager.doBegin()` 会 `getConnection()` 并绑定到 `ThreadLocal`，直到方法返回才 `release`。HTTP 调用期间连接一直被占用，即使没有执行任何 SQL。

**Q5：怎么在不重启的情况下恢复一个被泄漏打满的池？**
不能。泄漏的连接状态是 `STATE_IN_USE`，HouseKeeper 不会回收。只能重启实例。所以**预防 > 恢复**：开 `leakDetectionThreshold`、加事务边界规范、做连接池监控。

**Q6：`REQUIRES_NEW` 为什么会导致连接池死锁？**
它挂起外层事务（连接不释放）并新借一条。当并发线程数 × 2 > `maximumPoolSize` 时，所有线程都持有 1 条连接、等待第 2 条，形成环形等待。这是**应用层死锁**，数据库侧看不到。

---

## 七、总结

- 连接池耗尽的**第一反应不应该是调大池子**，而是判断「是容量不足还是泄漏」。
- 判断方法：`active == max` 且 `idle == 0` 且 `pending` 持续增长 → 泄漏；`active` 高但 `pending` 偶发 → 容量不足。
- 泄漏的六大根因：忘记 close、事务内远程调用、流式查询、异步线程、`REQUIRES_NEW`、池外直连。
- 定位工具链：Micrometer 指标 → `leakDetectionThreshold` 堆栈 → `jstack`/Arthas → 数据库 `processlist` → 堆转储。
- 治理靠规范 + 测试：事务边界三原则、ArchUnit 断言、独立连接池隔离。

连接池是应用和数据库之间唯一的咽喉。它出问题的时候，整个系统都会窒息。把 `leakDetectionThreshold` 在预发环境打开，可能是我能给出的性价比最高的一条建议。
