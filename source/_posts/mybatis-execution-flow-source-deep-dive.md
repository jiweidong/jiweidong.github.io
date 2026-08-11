---
title: 【MyBatis 源码】核心执行流程深度解析：从 SqlSession 到四大组件的协作
date: 2026-08-11 08:30:00
tags:
  - Java
  - MyBatis
  - 源码
categories:
  - MyBatis
  - Java 后端
author: 东哥
---

# 【MyBatis 源码】核心执行流程深度解析：从 SqlSession 到四大组件的协作

## 面试官：一条 selectById 从调用到返回，MyBatis 内部都经历了什么？

很多人天天用 MyBatis，却说不清 `sqlSession.selectOne("user.selectById", 1)` 背后发生了什么。MyBatis 的执行链路非常清晰：**SqlSession → Executor → StatementHandler → ParameterHandler / ResultSetHandler**，中间穿插 TypeHandler 和缓存。

本文从 `selectOne` 开始逐层拆解源码，把这条链路彻底讲透。

<!-- more -->

## 一、整体架构与四大组件

| 组件 | 职责 | 接口关键方法 |
| --- | --- | --- |
| `SqlSession` | 门面，对外提供 CRUD API | `selectOne` / `insert` / `update` / `delete` |
| `Executor` | 执行器，负责缓存、事务、SQL 分发 | `query` / `update` / `commit` / `rollback` |
| `StatementHandler` | 处理 JDBC Statement，是核心中的核心 | `prepare` / `query` / `update` |
| `ParameterHandler` | 参数绑定，把 Java 参数设置到 PreparedStatement | `setParameters` |
| `ResultSetHandler` | 结果映射，把 ResultSet 转为 Java 对象 | `handleResultSets` |
| `TypeHandler` | 类型转换，贯穿参数绑定与结果映射 | `setParameter` / `getResult` |

还有两个容易被忽略的角色：`SqlSource`（解析 SQL 生成 BoundSql）和 `MappedStatement`（一条 SQL 的完整描述：id、参数类型、结果映射、缓存配置等）。

## 二、入口：SqlSession 的门面模式

```java
// DefaultSqlSession
@Override
public <T> T selectOne(String statement, Object parameter) {
    // 转成 selectList 取第一个
    List<T> list = this.selectList(statement, parameter);
    if (list.size() == 1) {
        return list.get(0);
    } else if (list.size() > 1) {
        throw new TooManyResultsException(...);
    } else {
        return null;
    }
}

@Override
public <E> List<E> selectList(String statement, Object parameter) {
    MappedStatement ms = configuration.getMappedStatement(statement);
    return executor.query(ms, wrapCollection(parameter),
            RowBounds.DEFAULT, Executor.NO_RESULT_HANDLER);
}
```

两个关键动作：
1. `configuration.getMappedStatement(statement)`：根据 `"namespace.id"` 找到对应的 `MappedStatement`。这就是为什么 Mapper 接口全限定名必须和 XML 的 namespace 一致；
2. 把请求委托给 `Executor` —— SqlSession 本身不干活，它是典型的外观（Facade）模式。

## 三、Executor：一条链上的四个实现

`SqlSession` 持有的 `Executor` 在 `Configuration.newExecutor()` 中创建：

```java
public Executor newExecutor(Transaction transaction, ExecutorType executorType) {
    executorType = executorType == null ? defaultExecutorType : executorType;
    Executor executor;
    if (ExecutorType.BATCH == executorType) {
        executor = new BatchExecutor(this, transaction);
    } else if (ExecutorType.REUSE == executorType) {
        executor = new ReuseExecutor(this, transaction);
    } else {
        executor = new SimpleExecutor(this, transaction);  // 默认
    }
    if (cacheEnabled) {
        // 开启二级缓存则包一层 CachingExecutor（装饰器模式）
        executor = new CachingExecutor(executor);
    }
    // 插件（Interceptor）在这里用 JDK 动态代理包装 Executor
    executor = (Executor) interceptorChain.pluginAll(executor);
    return executor;
}
```

注意这里的设计：
- **默认 `SimpleExecutor`**，每执行一次 SQL 就新建一个 Statement；
- `ReuseExecutor` 复用 PreparedStatement；`BatchExecutor` 批量执行；
- **二级缓存是装饰器**：`CachingExecutor` 包在外面，先查二级缓存，命中直接返回，未命中才走真实 Executor；
- **插件机制**：`interceptorChain.pluginAll` 用动态代理把所有拦截器串到 Executor 上——MyBatis 的四大组件都可以被插件代理，这就是 PageHelper 分页插件能"偷改 SQL"的根本原因。

## 四、核心：StatementHandler 的完整执行

`SimpleExecutor.doQuery` 把控制权交给 StatementHandler：

```java
// SimpleExecutor
@Override
public <E> List<E> doQuery(MappedStatement ms, Object parameter, RowBounds rowBounds,
        ResultHandler resultHandler, BoundSql boundSql) throws SQLException {
    Statement stmt = null;
    try {
        Configuration configuration = ms.getConfiguration();
        // 1. 创建 StatementHandler（含插件代理）
        StatementHandler handler = configuration.newStatementHandler(
                this, ms, parameter, rowBounds, resultHandler, boundSql);
        // 2. 准备 Statement：连接、预编译、参数绑定
        stmt = prepareStatement(handler, ms.getStatementLog());
        // 3. 执行查询
        return handler.query(stmt, resultHandler);
    } finally {
        closeStatement(stmt);
    }
}

private Statement prepareStatement(StatementHandler handler, Log statementLog)
        throws SQLException {
    Statement stmt;
    Connection connection = getConnection(statementLog);
    // 2.1 预编译：PreparedStatementHandler 中执行 connection.prepareStatement(sql)
    stmt = handler.prepare(connection, transaction.getTimeout());
    // 2.2 参数绑定：ParameterHandler.setParameters
    handler.parameterize(stmt);
    return stmt;
}
```

### 4.1 handler.prepare：预编译

`PreparedStatementHandler` 的 prepare：

```java
@Override
public Statement prepare(Connection connection, Integer transactionTimeout)
        throws SQLException {
    return instantiateStatement(connection);
}

protected Statement instantiateStatement(Connection connection) throws SQLException {
    String sql = boundSql.getSql();
    if (mappedStatement.getKeyGenerator() != null
            && mappedStatement.getKeyGenerator().isJdbc3KeyGenerator(mappedStatement)) {
        // 需要回填自增主键，加上 RETURN_GENERATED_KEYS
        return connection.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS);
    }
    return connection.prepareStatement(sql);
}
```

`#{}` 在 `SqlSource` 解析阶段就变成了 `?`，所以这里拿到的是带占位符的 SQL——这就是为什么 `#{}` 能防 SQL 注入而 `${}` 不能（`${}` 是字符串直接拼接）。

### 4.2 handler.parameterize：参数绑定

```java
// PreparedStatementHandler
@Override
public void parameterize(Statement statement) throws SQLException {
    parameterHandler.setParameters((PreparedStatement) statement);
}

// DefaultParameterHandler
public void setParameters(PreparedStatement ps) {
    for (int i = 0; i < parameterMappings.size(); i++) {
        ParameterMapping parameterMapping = parameterMappings.get(i);
        Object value;
        // 通过反射从参数对象中取属性值（MetaObject / Reflector）
        value = getParameterObjectValue(parameterMapping);
        // 根据 JdbcType 找到对应的 TypeHandler 执行 setXxx
        typeHandler.setParameter(ps, i + 1, value, jdbcType);
    }
}
```

`TypeHandler` 决定调用 `ps.setString`、`ps.setInt` 还是 `ps.setObject`，这是参数从 Java 类型到 JDBC 类型的转换桥梁。

## 五、结果映射：ResultSetHandler 的两阶段

```java
// DefaultResultSetHandler
@Override
public List<Object> handleResultSets(Statement stmt) throws SQLException {
    final List<Object> multipleResults = new ArrayList<>();
    int resultSetCount = 0;
    ResultSetWrapper rsw = getFirstResultSet(stmt);
    List<ResultMap> resultMaps = mappedStatement.getResultMaps();
    // 遍历每一个 ResultMap（支持多结果集）
    while (rsw != null && resultSetCount < resultMaps.size()) {
        ResultMap resultMap = resultMaps.get(resultSetCount);
        handleResultSet(rsw, resultMap, multipleResults);
        rsw = getNextResultSet(stmt);
        resultSetCount++;
    }
    // 处理嵌套结果（一对多/多对一）
    if (mappedStatement.hasNestedResultMaps()) {
        // 通过 ResultMap 中维护的对象标识，把嵌套对象组合起来
        combineNestedResultSets(multipleResults);
    }
    // 剥离额外的结果（多结果集场景下只保留第一个）
    return collapseSingleResultList(multipleResults);
}
```

结果映射的核心是 `applyAutomaticMappings`（自动映射，`mapUnderscoreToCamelCase` 就在这里生效）和 `applyPropertyMappings`（显式 `<result column="xxx" property="yyy"/>` 映射）。每条记录通过 `createResultObject` 反射创建目标对象，再用 MetaObject 设置属性值。

## 六、缓存到底在哪一层？

- **一级缓存**：`BaseExecutor` 中的 `localCache`（PerpetualCache，本质是 HashMap）。同一个 SqlSession 内，相同 SQL + 参数会命中缓存，**执行 update/insert/delete 或 commit/close 后清空**；
- **二级缓存**：`CachingExecutor` 装饰器，namespace 级别，跨 SqlSession 共享，默认关闭，需在 XML 中 `<cache/>` 开启。

```java
// BaseExecutor.query 中的一级缓存逻辑
CacheKey key = createCacheKey(ms, parameter, rowBounds, boundSql);
return query(ms, parameter, rowBounds, resultHandler, key, boundSql);

private <E> List<E> query(...) throws SQLException {
    List<E> list = (List<E>) localCache.getObject(key);
    if (list != null) {
        // 命中一级缓存，直接返回
        return list;
    }
    list = doQuery(ms, parameter, rowBounds, resultHandler, boundSql);
    localCache.putObject(key, list);
    return list;
}
```

一级缓存失效的经典场景：同一个 SqlSession 里两次查询之间执行了一次 `update`（`clearLocalCache`），或者查询走了不同参数。多线程、多 SqlSession 场景下一级缓存基本无意义，真正的跨会话缓存靠二级缓存。

## 七、手绘完整时序

```
调用方
  │ selectOne("user.selectById", 1)
  ▼
DefaultSqlSession ──► MappedStatement 查找
  │ 委托
  ▼
CachingExecutor（二级缓存查询，未命中）──►  Plugin 代理
  ▼
SimpleExecutor.doQuery
  │ ① newStatementHandler
  ▼
PreparedStatementHandler
  │ ② prepare：connection.prepareStatement(sql)
  │ ③ parameterize → DefaultParameterHandler
  │        └─ TypeHandler.setParameter
  │ ④ query → statement.execute()
  ▼
DefaultResultSetHandler
  │ ⑤ handleResultSets：ResultSet → Java 对象
  │        └─ TypeHandler.getResult / MetaObject 赋值
  ▼
返回结果（逐层回传，同时填充一级缓存）
```

## 八、面试常见追问

**Q1：Executor 为什么能被插件代理？**
`pluginAll` 返回 JDK 动态代理对象，拦截器实现 `@Intercepts` 标注拦截 Executor/StatementHandler/ParameterHandler/ResultSetHandler 的指定方法。PageHelper 就是拦截 `Executor.query`，在 BoundSql 后追加 `limit` 分页 SQL。

**Q2：`#{}` 和 `${}` 在源码层面有什么区别？**
`#{}` 解析成 `?` 占位符走 `PreparedStatement` 预编译，参数由 ParameterHandler 绑定，天然防注入；`${}` 是 `StringSubstitutor` 直接替换进 SQL 字符串，不预编译，只用于表名、排序字段等无法占位的场景，且必须人工校验。

**Q3：MyBatis 是如何把接口方法映射到 MapperStatement 的？**
启动时 `MapperRegistry.addMapper` 注册 Mapper 接口，`MapperProxy` 动态代理拦截接口调用，方法签名 + 类名拼出 `namespace.methodName` 去 configuration 中查找 MappedStatement。

**Q4：一级缓存和二级缓存的坑？**
一级缓存：跨 SqlSession 不共享、并发下有脏读风险（一个 session 提交前另一个 session 看不到）；二级缓存：默认不开启、namespace 间数据不一致、多表操作容易缓存脏数据。生产环境通常只开二级缓存并配合 `useCache` 精确控制。

## 总结

MyBatis 的执行链路就是一条**职责清晰的流水线**：SqlSession 做门面，Executor 管执行策略与缓存，StatementHandler 管 JDBC 交互，ParameterHandler 和 ResultSetHandler 分别负责"进"和"出"的类型转换。加上 TypeHandler、插件代理、装饰器缓存，源码处处是设计模式的影子。把这条链路走一遍，MyBatis 相关的面试题基本都能从容应对。
