---
title: 【Spring 源码】JdbcTemplate 深度解析：SQL 执行流程、RowMapper 回调与异常转换体系
date: 2026-09-28 08:00:00
tags:
  - Java
  - Spring
  - JdbcTemplate
  - 源码
  - 面试
categories:
  - Java
  - Spring
author: 东哥
---

# 【Spring 源码】JdbcTemplate 深度解析：SQL 执行流程、RowMapper 回调与异常转换体系

## 面试官：JdbcTemplate 你用过，那它是怎么把原生 JDBC 的样板代码"干掉"的？

这个问题看起来只是"用过就算会"，但实际上它一次性考了三件事：**模板方法模式的落地**、**回调接口的设计**、以及 **Spring 的异常体系**。能把这三点串起来讲清楚，基本就说明你不是只会写 `jdbcTemplate.queryForList(sql)` 的 API 调用工。

本文从一段最原始的 JDBC 代码出发，一路把 JdbcTemplate 的设计动机、执行链路、行映射回调、异常转换、命名参数、批量与主键回填全部打通，最后给出一张与 MyBatis / JPA 的选型对比表。

---

## 一、从原生 JDBC 的"六步曲"说起

先看一段最标准的原生 JDBC 查询：

```java
public User findById(Long id) throws SQLException {
    Connection conn = null;
    PreparedStatement ps = null;
    ResultSet rs = null;
    try {
        conn = dataSource.getConnection();
        ps = conn.prepareStatement("select id, name, age from user where id = ?");
        ps.setLong(1, id);
        rs = ps.executeQuery();
        if (rs.next()) {
            User u = new User();
            u.setId(rs.getLong("id"));
            u.setName(rs.getString("name"));
            u.setAge(rs.getInt("age"));
            return u;
        }
        return null;
    } finally {
        if (rs != null) try { rs.close(); } catch (SQLException ignore) {}
        if (ps != null) try { ps.close(); } catch (SQLException ignore) {}
        if (conn != null) try { conn.close(); } catch (SQLException ignore) {}
    }
}
```

这里只有 **3 行是真正的业务逻辑**（SQL、参数、结果映射），其余全是**资源获取 + 参数绑定 + 结果遍历 + 资源释放 + 异常处理**。这就是典型的"样板代码"（boilerplate）。

更麻烦的是：一旦在多处复制这段逻辑，只要有一处 `finally` 写错、漏关一个 `ResultSet`，在长连接 + 高并发下就是**连接泄漏**，最终把连接池打满，整个服务雪崩。

JdbcTemplate 的定位就是：**把这些"每次都必须做对"的事情，收进一个模板里，只把"会变的部分"通过回调暴露给你**。

---

## 二、核心设计：模板方法 + 回调

JdbcTemplate 继承自 `JdbcAccessor`，实现了 `JdbcOperations` 接口，内部持有一个 `DataSource`。它的骨架方法（template method）负责：

1. 从 DataSource 获取连接（或从事务同步器中拿绑定连接）；
2. 创建 `Statement` / `PreparedStatement`，绑定参数；
3. 调用回调（callback）执行 SQL；
4. **统一处理结果集**；
5. **统一释放资源**；
6. **统一把 `SQLException` 翻译成 `DataAccessException`**。

而"会变的部分"被抽象成了三类回调：

| 回调接口 | 用途 | 是否需要处理 ResultSet |
|---|---|---|
| `ConnectionCallback<T>` | 直接操作 Connection | 自己管 |
| `StatementCallback<T>` | 直接操作 Statement | 自己管 |
| `PreparedStatementCallback<T>` | 直接操作 PreparedStatement | 自己管 |
| `RowMapper<T>` | 每行映射成一个对象 | 否，框架遍历 |
| `ResultSetExtractor<T>` | 整个结果集映射成一个对象 | 是，自己遍历 |
| `RowCallbackHandler` | 逐行消费，无返回值 | 否，框架遍历 |

一句话总结：**ConnectionCallback 管到"连接级"，StatementCallback 管到"语句级"，RowMapper / ResultSetExtractor 管到"结果级"。粒度越细，你写的代码越少，框架帮你做得越多。**

---

## 三、源码级执行链路

以最常用的 `query(String sql, RowMapper<T> rowMapper, Object... args)` 为例，源码简化后是这样的：

```java
public <T> List<T> query(String sql, RowMapper<T> rowMapper, @Nullable Object... args)
        throws DataAccessException {
    return query(sql, newArgPreparedStatementSetter(args), rowMapper);
}

public <T> List<T> query(String sql, PreparedStatementSetter pss, RowMapper<T> rowMapper) {
    return query(sql, pss, new RowMapperResultSetExtractor<>(rowMapper));
}

public <T> T query(String sql, @Nullable PreparedStatementSetter pss,
                   ResultSetExtractor<T> rse) {
    return execute(con -> {
        PreparedStatement ps = null;
        try {
            ps = con.prepareStatement(sql);
            if (pss != null) {
                pss.setValues(ps);   // 参数绑定
            }
            ResultSet rs = ps.executeQuery();
            return rse.extractData(rs);  // 结果提取
        } finally {
            JdbcUtils.closeStatement(ps);
        }
    });
}
```

真正的"骨架"在 `execute(StatementCallback)` 里：

```java
public <T> T execute(StatementCallback<T> action) {
    Connection con = DataSourceUtils.getConnection(obtainDataSource());
    Statement stmt = null;
    try {
        stmt = con.createStatement();
        applyStatementSettings(stmt);        // fetchSize / maxRows / queryTimeout
        T result = action.doInStatement(stmt);
        handleWarnings(stmt);                // SQLWarning 处理
        return result;
    } catch (SQLException ex) {
        String sql = getSql(action);
        JdbcUtils.closeStatement(stmt);
        stmt = null;
        throw translateException("StatementCallback", sql, ex);  // <-- 异常翻译
    } finally {
        JdbcUtils.closeStatement(stmt);
        DataSourceUtils.releaseConnection(con, getDataSource());
    }
}
```

这里有两个非常关键的点，面试被追问高频命中：

### 3.1 `DataSourceUtils.getConnection` 而不是 `dataSource.getConnection()`

为什么？因为要**和 Spring 事务集成**。

- 如果当前线程存在 `TransactionSynchronizationManager` 里绑定的事务连接，直接复用；
- 否则才真正向 DataSource 借一条连接，并注册到线程上下文中；
- `releaseConnection` 同理：**有事务时不真正还连接，只做引用计数（ConnectionHolder）**。

这就解释了那个经典面试题：**"为什么 `@Transactional` 里的 JdbcTemplate 和外面拿到的是同一个 Connection？"** —— 答案就在 `DataSourceUtils` 的线程绑定机制里。事务要生效，SQL 必须走同一个连接，否则 `BEGIN` / `COMMIT` 就跨连接失效了。

### 3.2 `applyStatementSettings`

```java
protected void applyStatementSettings(Statement stmt) throws SQLException {
    int fetchSize = getFetchSize();
    if (fetchSize != -1) stmt.setFetchSize(fetchSize);
    int maxRows = getMaxRows();
    if (maxRows != -1) stmt.setMaxRows(maxRows);
    DataSourceUtils.applyTimeout(stmt, getDataSource(), getQueryTimeout());
}
```

**`fetchSize` 是 JdbcTemplate 最大的性能旋钮**。默认 `-1`（用驱动默认值）。MySQL 驱动只有在 `fetchSize = Integer.MIN_VALUE`（或 `useCursorFetch=true` + 正数）时才是真正的**流式读取**；否则会把整个结果集一次性拉到客户端内存，这就是"查 100 万行直接 OOM"的根因。

> 面试追问：**"用 JdbcTemplate 查一张千万级大表，怎么做流式处理？"**
>
> 答：MySQL 下有两种方式。一是把 `fetchSize` 设为 `Integer.MIN_VALUE` 走流式（需在 `JdbcTemplate` 上 `setFetchSize`，且必须保证结果集在事务内消费完）；二是用 `ResultSetExtractor` 手动控制遍历，配合 `setFetchSize` 分批 fetch。更稳的做法是**游标式分页**（`where id > lastId order by id limit N`），避免长事务与连接占用。

---

## 四、RowMapper / ResultSetExtractor / RowCallbackHandler

这三个接口是新手最常混淆的地方，一张表说清：

| 接口 | 方法签名 | 搬运单位 | 典型场景 |
|---|---|---|---|
| `RowMapper<T>` | `T mapRow(ResultSet rs, int rowNum)` | **一行 → 一个对象** | `queryForList`、`query` |
| `ResultSetExtractor<T>` | `T extractData(ResultSet rs)` | **整个 ResultSet → 一个对象** | 聚合计算、复杂嵌套对象、流式处理 |
| `RowCallbackHandler` | `void processRow(ResultSet rs)` | 逐行消费，**无返回值** | 大结果集导出、逐行写文件 |

`RowMapper` 的无状态性非常关键：**它是线程安全的、可复用的单例**（比如 `new BeanPropertyRowMapper<>(User.class)` 可以定义为全局常量），因为框架每次回调都传入不同的 `rowNum`。

而 `ResultSetExtractor` 常被写成 Lambda，用于把"一对多"结果手工组装：

```java
List<Order> orders = jdbcTemplate.query(
    "select o.id oid, o.no, i.name iname, i.qty " +
    "from orders o join order_item i on i.order_id = o.id " +
    "where o.user_id = ? order by o.id",
    rs -> {
        Map<Long, Order> map = new LinkedHashMap<>();
        while (rs.next()) {
            long oid = rs.getLong("oid");
            Order o = map.computeIfAbsent(oid, k -> {
                Order x = new Order();
                x.setId(oid);
                x.setItems(new ArrayList<>());
                return x;
            });
            OrderItem it = new OrderItem();
            it.setName(rs.getString("iname"));
            it.setQty(rs.getInt("qty"));
            o.getItems().add(it);
        }
        return new ArrayList<>(map.values());
    },
    userId);
```

---

## 五、异常转换体系：SQLException → DataAccessException

这是 JdbcTemplate 最被低估的设计。原生 JDBC 的 `SQLException` 是**受检异常**，带着 `SQLState`、`vendorCode` 等一堆"数据库方言"信息，业务代码里到处 `catch` 会非常难看。

Spring 的做法是引入 `SQLExceptionTranslator`：

```java
protected DataAccessException translateException(String task, String sql, SQLException ex) {
    DataAccessException dae = getExceptionTranslator().translate(task, sql, ex);
    return (dae != null ? dae : new UncategorizedSQLException(task, sql, ex));
}
```

默认实现是 `SQLErrorCodeSQLExceptionTranslator`，它加载 `sql-error-codes.xml`，按 **数据库厂商 + 错误码** 映射成 Spring 的异常层级：

```
DataAccessException
├── NonTransientDataAccessException        (不可重试: 语法错误、约束冲突)
│   ├── BadSqlGrammarException
│   ├── DataIntegrityViolationException    (唯一键/外键冲突)
│   ├── DuplicateKeyException
│   └── DataAccessResourceFailureException
└── TransientDataAccessException           (可重试: 死锁、连接闪断)
    ├── DeadlockLoserDataAccessException
    └── QueryTimeoutException
```

**`DuplicateKeyException` 就是 `DataIntegrityViolationException` 的子类**，所以捕获父类即可覆盖大部分约束错误。

这个设计带来的实际收益有两个：

1. **异常语义化**：`catch (DuplicateKeyException e)` 比 `catch (SQLException e) { if (e.getErrorCode() == 1062) ... }` 干净一万倍；
2. **数据库无关**：MySQL 的 1062、Oracle 的 1、PG 的 23505 都被翻译成同一个 `DuplicateKeyException`，换库不用改业务代码。

> 面试追问：**"`TransientDataAccessException` 还有什么用？"**
>
> 答：它是"可重试"的语义标记。配合 Spring Retry 可以写成 `@Retryable(retryFor = TransientDataAccessException.class)`，把死锁、连接闪断这类瞬时故障自动重试，而不可重试的语法错误立即失败——避免无意义的重试风暴。

---

## 六、NamedParameterJdbcTemplate：告别 `?` 的位置地狱

参数一多，`?` 顺序就容易错。`NamedParameterJdbcTemplate` 允许用 `:name` 命名参数：

```java
String sql = "select * from user where name like :name and age > :age and city in (:cities)";
Map<String, Object> params = new HashMap<>();
params.put("name", "张%");
params.put("age", 18);
params.put("cities", Arrays.asList("北京", "上海"));

List<User> list = namedTemplate.query(sql, params, new BeanPropertyRowMapper<>(User.class));
```

底层由 `NamedParameterUtils.parseSqlStatement` 完成：

1. 扫描 SQL，识别 `:name`、`:name:type`、`&name` 等占位符，同时**跳过字符串字面量和注释中的冒号**（避免把 `'http://x'` 里的冒号当参数）；
2. 把 SQL 重写成 `?` 形式；
3. 按出现顺序构建 `SqlParameterSource`，`in (:cities)` 会自动展开成 `(?, ?, ?)` 并展开参数列表。

这里有个重要结论：**命名参数只是"编写期"的便利，最终发给数据库的仍是 `PreparedStatement` + `?` + 参数绑定，所以防 SQL 注入的特性和原生一样安全**——前提是值走参数，而不是字符串拼接。

---

## 七、批量操作与主键回填

### 7.1 batchUpdate

```java
List<User> users = ...;
jdbcTemplate.batchUpdate(
    "insert into user(name, age) values(?, ?)",
    new BatchPreparedStatementSetter() {
        public void setValues(PreparedStatement ps, int i) throws SQLException {
            ps.setString(1, users.get(i).getName());
            ps.setInt(2, users.get(i).getAge());
        }
        public int getBatchSize() { return users.size(); }
    });
```

要让**批量插入性能真正起飞**，MySQL 连接串必须加 `rewriteBatchedStatements=true`，否则驱动依旧一条一条发，批量只是个假象。加上参数后 1 万条插入通常能从几秒降到几百毫秒。

### 7.2 自增主键回填

```java
KeyHolder keyHolder = new GeneratedKeyHolder();
jdbcTemplate.update(con -> {
    PreparedStatement ps = con.prepareStatement(
        "insert into user(name, age) values(?, ?)",
        Statement.RETURN_GENERATED_KEYS);
    ps.setString(1, "东哥");
    ps.setInt(2, 18);
    return ps;
}, keyHolder);

Number key = keyHolder.getKey();  // 新插入行的 id
```

注意 `keyHolder.getKey()` 在批量插入时只能拿到**第一条**主键（JDBC 规范限制），需要全部主键时得改用 `getKeyList()`（依赖驱动支持）或逐条插入。

---

## 八、和 MyBatis / JPA 怎么选？

| 维度 | JdbcTemplate | MyBatis | Spring Data JPA |
|---|---|---|---|
| SQL 控制力 | 完全手写，最强 | 手写为主 | 自动生成，可控性弱 |
| 学习成本 | 低 | 中 | 高（要懂一级缓存/脏检查/N+1） |
| 映射能力 | 手写 RowMapper | ResultMap 强大 | 全自动 ORM |
| 动态 SQL | 需手工拼 | `<if> <foreach>` 原生支持 | Specification / QueryDSL |
| 性能调优 | 直给 JDBC，无黑盒 | 可控 | 有隐式行为，易踩坑 |
| 典型场景 | 报表、批量、极致性能 SQL | 复杂查询类业务 | 领域模型清晰的 CRUD |
| 事务/连接管理 | 与 Spring 事务无缝 | 无缝 | 无缝 |

经验法则：

- **复杂 SQL、报表、批量处理、对性能要求极端** → JdbcTemplate；
- **业务 CRUD + 复杂动态查询** → MyBatis；
- **领域模型清晰、以对象为中心的增删改查** → JPA。

很多成熟项目其实是**混用**：JPA/MyBatis 做主业务，JdbcTemplate 专门处理批量导入导出和大报表。

---

## 九、实战避坑清单

1. **大结果集必须控制 fetchSize**，或改用游标分页，别让驱动把整表拉进堆。
2. **`queryForObject` 查不到会抛 `EmptyResultDataAccessException`**，查多条会抛 `IncorrectResultSizeDataAccessException`——用 `query().stream().findFirst()` 更安全。
3. **不要在循环里调用 `update` 单条**，用 `batchUpdate`。
4. **`BeanPropertyRowMapper` 依赖 setter 与列名匹配**，开启 `mapUnderscoreToCamelCase`（这里是 `BeanPropertyRowMapper` 的别名映射）才能映射 `user_name → userName`。
5. **事务内避免长耗时逻辑**：连接被事务持有，做 HTTP 调用会把连接池拖死。
6. **异常翻译不是万能的**：自定义函数的业务错误码可能落到 `UncategorizedSQLException`，需要自定义 `SQLExceptionTranslator`。

---

## 十、面试追问连环炮

**Q：JdbcTemplate 是线程安全的吗？**
A：是。它自身无可变共享状态（除了可配置的 fetchSize/queryTimeout 等，配置后不再改），每次调用都从 DataSource 取连接、用完归还，所以是线程安全的，可以放心作为单例 Bean。

**Q：为什么它不用 `@Transactional` 也能和事务配合？**
A：因为它通过 `DataSourceUtils` 与 `TransactionSynchronizationManager` 交互，事务连接绑定在线程上。`@Transactional` 由 `DataSourceTransactionManager` 开启事务并绑定 ConnectionHolder，JdbcTemplate 只是"复用"了它。

**Q：`execute` 里为什么要 `handleWarnings`？**
A：JDBC 的 `SQLWarning` 会被静默吞掉，Spring 默认把它转成日志；配置 `ignoreWarnings=false` 时可以升级为异常，方便发现隐式截断、隐式类型转换等问题。

**Q：JdbcTemplate 有缓存 PreparedStatement 吗？**
A：没有。它每次都 `con.prepareStatement(sql)`。语句缓存在连接池层（如 HikariCP 的 `PreparedStatementCache`）或驱动层完成，别指望 JdbcTemplate 做。

---

## 总结

JdbcTemplate 的价值远不止"少写几行代码"，它示范了三个可以复用到自己代码里的设计思想：

1. **模板方法收敛不变部分**：资源、异常、清理一次性做对；
2. **回调暴露可变部分**：粒度从 Connection 到 Row 逐层细化；
3. **异常语义化**：把方言化的底层错误翻译成统一的、可分类（可重试/不可重试）的异常体系。

把这三条想明白，再看 Spring 的 `RestTemplate`、`RedisTemplate`、`TransactionTemplate`，会发现它们全都是同一套思路的复刻——这才是读源码真正的收获。
