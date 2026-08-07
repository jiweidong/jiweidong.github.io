---
title: 【数据库实战】JDBC 核心原理深度解析：从 DriverManager 到 PreparedStatement 预编译与批处理
date: 2026-08-07 08:00:00
tags:
  - Java
  - JDBC
  - 数据库
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【数据库实战】JDBC 核心原理深度解析：从 DriverManager 到 PreparedStatement 预编译与批处理

## 面试官：你用 JDBC 连过数据库吗？说说它底层是怎么工作的？

很多同学天天用 MyBatis、Spring Data JPA，却连最底层的 JDBC 都没真正理解过。JDBC（Java Database Connectivity）是 Java 访问关系型数据库的**官方标准接口**，所有 ORM 框架最终都逃不过它。这篇文章带你彻底搞懂 JDBC 的核心机制。

## 一、JDBC 是什么：接口标准 + SPI 加载

JDBC 的本质是一组接口（`java.sql` 包），而具体实现由数据库厂商提供。这套设计遵循**面向接口编程 + SPI 机制**：

```
JDBC 接口（java.sql.*）
    ↑ 实现
MySQL Connector/J、PostgreSQL JDBC、Oracle JDBC 驱动...
```

核心接口一览：

| 接口 | 职责 |
|------|------|
| `Driver` | 数据库驱动入口，负责建立连接 |
| `Connection` | 数据库会话，管理事务、创建 Statement |
| `Statement` | 静态 SQL 执行器 |
| `PreparedStatement` | 预编译 SQL 执行器（重点） |
| `ResultSet` | 查询结果集，游标式遍历 |
| `DataSource` | 连接池标准接口，取代 DriverManager |

### 驱动加载：DriverManager 与 SPI

传统写法 `Class.forName("com.mysql.cj.jdbc.Driver")` 其实**从 JDBC 4.0 起就可以省略了**。为什么？因为 `DriverManager` 初始化时会通过 `ServiceLoader` 扫描 `META-INF/services/java.sql.Driver` 文件，自动注册驱动——这正是 Java SPI 机制的标准应用。

`DriverManager.getConnection(url, user, pwd)` 的流程：

```
1. 遍历已注册的 Driver 列表（CopyOnWriteArrayList 保存）
2. 逐个调用 driver.acceptsURL(url) 判断是否支持该 URL
3. 支持的驱动调用 driver.connect(url, info) 建立物理连接
4. 返回 Connection（实际是驱动包装后的实现类）
```

**面试追问：为什么 MySQL 驱动要分 `com.mysql.jdbc.Driver` 和 `com.mysql.cj.jdbc.Driver`？**

前者是 MySQL Connector/J 5.x 的老驱动，后者是 8.x 的新驱动。新驱动类继承了老驱动，为了兼容旧代码才保留了老类名。此外 8.x 驱动还做了时区处理（`serverTimezone` 参数）等改进。

## 二、Connection：连接的本质是什么？

`Connection` 不是凭空来的，它底层就是一条 **TCP 连接 + 协议握手**：

```
MySQL 连接建立过程
1. TCP 三次握手
2. MySQL 握手协议：服务端发送握手包（版本、认证插件）
3. 客户端发送认证包（用户名、密码加密、数据库名）
4. 服务端返回 OK 包，连接建立
```

这也是为什么"建立连接很贵"——一次连接要经历 TCP 握手 + 认证握手，网络往返至少 2~3 次 RTT。**这就是连接池存在的根本原因**。

### Connection 的两个关键能力

**1. 事务管理**

```java
try (Connection conn = dataSource.getConnection()) {
    conn.setAutoCommit(false);          // 关闭自动提交，开启事务
    try {
        // 多条 SQL...
        conn.commit();                   // 提交
    } catch (Exception e) {
        conn.rollback();                 // 回滚
        throw e;
    }
}
```

注意：`setAutoCommit(false)` 相当于发了 `SET autocommit=0`；`commit()` 底层发送 `COMMIT` 命令。

**2. 元数据获取**

```java
DatabaseMetaData meta = conn.getMetaData();
System.out.println(meta.getDatabaseProductName());  // MySQL
System.out.println(meta.getDriverVersion());        // mysql-connector-j-8.x
```

## 三、Statement vs PreparedStatement：预编译的真相

这是面试必考点。先看对比：

| 特性 | Statement | PreparedStatement |
|------|-----------|-------------------|
| SQL 拼接 | 字符串拼接，有注入风险 | `?` 占位符，参数化 |
| SQL 注入 | 高风险 | 天然免疫 |
| 预编译 | 每次执行都编译 | 可预编译，复用执行计划 |
| 性能 | 多次执行同 SQL 时差 | 多次执行时优势明显 |
| 可读性 | 差（拼接地狱） | 好 |

### 预编译到底预编译了什么？

以 MySQL 为例，`PreparedStatement` 的执行分两步：

```
第一步：prepare
  客户端发送 COM_STMT_PREPARE（含 SQL 文本）
  服务端解析 SQL、生成执行计划，返回 statement_id

第二步：execute
  客户端发送 COM_STMT_EXECUTE（含 statement_id + 参数二进制数据）
  服务端直接按已有执行计划执行
```

**关键点**：
- 预编译发生在**服务端**（MySQL 5.1+ 支持），服务端缓存了执行计划
- 参数通过**二进制协议**传输，不参与 SQL 文本拼接——这就是防注入的根本原因
- 连接池中如果开启 `cachePrepStmts=true`，客户端也会缓存 `PreparedStatement` 对象，避免重复 prepare

### 面试高频追问：PreparedStatement 一定能防 SQL 注入吗？

**分情况**：

```java
// ✅ 安全：占位符绑定参数
ps = conn.prepareStatement("SELECT * FROM user WHERE name = ?");
ps.setString(1, "'; DROP TABLE user;--");   // 作为普通字符串处理

// ❌ 危险：表名/列名/排序字段不能用占位符
ps = conn.prepareStatement("SELECT * FROM " + tableName);  // 拼接表名有风险
```

占位符只能绑定**值**，不能用于表名、列名、ORDER BY 等标识符位置。另外注意：**MySQL 的预编译默认是"客户端模拟"的**（`useServerPrepStmts=false` 时），此时防注入靠的是参数转义，效果等同但性能提升有限；要真正服务端预编译需开启 `useServerPrepStmts=true&cachePrepStmts=true`。

## 四、批处理：性能提升的利器

一次性插入 10 万条数据，逐条执行 vs 批处理，性能差距可能是**几十倍**。

### 三种批量插入方式对比

```java
// 方式一：逐条执行（最慢）
for (int i = 0; i < 100000; i++) {
    stmt.executeUpdate("INSERT INTO t VALUES (" + i + ")");
}

// 方式二：addBatch + executeBatch（快）
try (PreparedStatement ps = conn.prepareStatement("INSERT INTO t VALUES (?)")) {
    for (int i = 0; i < 100000; i++) {
        ps.setInt(1, i);
        ps.addBatch();
        if (i % 1000 == 0) ps.executeBatch();  // 每 1000 条提交一批
    }
    ps.executeBatch();
}

// 方式三：rewriteBatchedStatements（最快，MySQL 专有）
// JDBC URL 加参数：?rewriteBatchedStatements=true
```

### rewriteBatchedStatements 的原理

开启该参数后，MySQL 驱动会把多条 `INSERT` **重写为一条多 VALUES 语句**：

```
原始：
INSERT INTO t VALUES (1)
INSERT INTO t VALUES (2)
INSERT INTO t VALUES (3)

重写后：
INSERT INTO t VALUES (1),(2),(3)
```

这样网络往返从 N 次降为 1 次，插入性能提升 5~10 倍。实测 10 万条数据：
- 逐条执行：约 30s
- addBatch：约 5s
- addBatch + rewriteBatchedStatements：约 1s

**注意**：`executeBatch()` 返回的是 `int[]`，表示每条 SQL 影响的行数；批处理中某条失败时抛 `BatchUpdateException`，可通过 `getUpdateCounts()` 获取已成功执行的数量。

## 五、ResultSet：游标与数据读取

`ResultSet` 是**游标式**的数据结构，不是一次性把所有数据加载到内存：

```java
ResultSet rs = stmt.executeQuery("SELECT * FROM t");
while (rs.next()) {           // 游标下移一行
    int id = rs.getInt("id");
    String name = rs.getString("name");
}
```

底层机制：
- MySQL 默认**一次性拉取全部结果**到客户端内存（简单模式）
- 大数据量场景可开启**流式读取**：`stmt.setFetchSize(Integer.MIN_VALUE)`，此时驱动会一行一行从服务端读取（`useCursorFetch=true` 时更可控）
- `setFetchSize(n)` 配合 `useCursorFetch=true` 可实现服务端游标分批拉取

**面试追问：为什么说"结果集很大时直接全量查询会 OOM"？**

因为默认模式下驱动会把所有行缓存到内存。10 万行 × 每行 1KB ≈ 100MB，多几个查询堆就爆了。解决方案：分页查询、流式读取、或者用 LIMIT 分批。

## 六、从 JDBC 到 MyBatis：ORM 的封装逻辑

理解了 JDBC，再看 ORM 就豁然开朗。MyBatis 做了三件事：

```
1. 参数映射：#{id} → ps.setInt(1, id)（PreparedStatement 占位符）
2. 结果映射：ResultSet → POJO（反射/构造函数赋值）
3. 连接管理：SqlSession 从连接池获取/归还 Connection
```

而 Spring 的 `JdbcTemplate` 则帮你管好了 **Connection 获取、Statement 创建、异常转换、资源关闭** 这些样板代码，核心还是 JDBC。

## 七、最佳实践总结

| 实践点 | 建议 |
|--------|------|
| 连接获取 | 永远用连接池（HikariCP），别用 DriverManager |
| SQL 执行 | 一律 PreparedStatement，杜绝拼接 |
| 批量插入 | addBatch + rewriteBatchedStatements=true |
| 事务 | setAutoCommit(false) + commit/rollback，finally 恢复 |
| 资源释放 | try-with-resources 自动关闭（Connection 归还连接池） |
| 大结果集 | 分页查询或流式读取，防止 OOM |
| 驱动参数 | useServerPrepStmts=true&cachePrepStmts=true&rewriteBatchedStatements=true |

## 八、面试速答

1. **JDBC 驱动怎么加载的？** JDBC 4.0+ 通过 SPI（`META-INF/services/java.sql.Driver`）自动注册，`Class.forName` 可省略。
2. **PreparedStatement 为什么防注入？** 参数走二进制协议绑定，不参与 SQL 文本拼接；且能复用服务端执行计划。
3. **连接为什么贵？** 底层是 TCP 握手 + MySQL 认证握手，多次网络 RTT。
4. **批处理原理？** addBatch 攒批发送 + rewriteBatchedStatements 把多条 INSERT 重写为一条多 VALUES。
5. **JDBC 和 MyBatis 什么关系？** MyBatis 是对 JDBC 的封装：参数映射、结果映射、连接管理。

JDBC 是所有 Java 数据库技术的基石，理解它，你才能真正理解 MyBatis 的一级缓存、Spring 事务传播这些上层机制。
