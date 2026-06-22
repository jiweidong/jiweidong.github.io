---
title: MyBatis 核心原理与源码解析：从配置到 SQL 执行全流程
date: 2026-06-22 08:50:00
tags:
  - Java
  - MyBatis
  - ORM
  - 源码分析
categories:
  - Java
  - 数据库
author: 东哥
---

# MyBatis 核心原理与源码解析：从配置到 SQL 执行全流程

MyBatis-Plus 大家都用得飞起，但 MyBatis 底层是怎么工作的？SqlSession、Mapper 代理、一级缓存、二级缓存，这些概念你真的懂吗？

本文从源码角度，带你走一遍 MyBatis 从配置解析到 SQL 执行的全流程。

## 一、MyBatis 整体架构

MyBatis 分三层：

```
┌─────────────────────────────────────────────────┐
│                 接口层 (API)                       │
│  SqlSession  SqlSessionFactory  Configuration    │
├─────────────────────────────────────────────────┤
│             数据处理层 (Core)                     │
│  SQL 解析  参数映射  SQL 执行  结果映射           │
├─────────────────────────────────────────────────┤
│              基础支撑层 (Base)                    │
│  连接管理  事务管理  缓存管理  配置加载           │
└─────────────────────────────────────────────────┘
```

**核心接口：**
- **SqlSession** — 顶层 API，提供 CRUD 方法
- **Executor** — 真正执行 SQL 的组件（含缓存逻辑）
- **StatementHandler** — 处理 JDBC Statement
- **ParameterHandler** — 参数预处理
- **ResultSetHandler** — 结果集映射

## 二、从 SqlSessionFactory 开始

### 2.1 构建过程

```java
// 经典入口
String resource = "mybatis-config.xml";
InputStream inputStream = Resources.getResourceAsStream(resource);
SqlSessionFactory sqlSessionFactory = new SqlSessionFactoryBuilder().build(inputStream);
```

**内部发生了什么？**

```java
// SqlSessionFactoryBuilder.build() 简化流程
public SqlSessionFactory build(InputStream inputStream) {
    // 1. 创建 XMLConfigBuilder，解析配置文件
    XMLConfigBuilder parser = new XMLConfigBuilder(inputStream, null, null);
    
    // 2. 解析配置，生成 Configuration 对象
    Configuration config = parser.parse();
    
    // 3. 创建 DefaultSqlSessionFactory
    return new DefaultSqlSessionFactory(config);
}
```

### 2.2 Configuration 解析流程

```
mybatis-config.xml 解析：
├── <properties> → properties 属性
├── <settings> → 全局设置（缓存、懒加载、日志等）
├── <typeAliases> → 类型别名
├── <typeHandlers> → 类型处理器
├── <objectFactory> → 对象工厂
├── <plugins> → 插件（拦截器）
├── <environments> → 环境配置（数据源、事务）
└── <mappers> → Mapper XML 文件

每个 Mapper XML 解析：
├── <cache> / <cache-ref> → 二级缓存配置
├── <resultMap> → 结果映射（重点）
├── <sql> → SQL 片段
└── <select|insert|update|delete> → 每一条 SQL 语句
```

**每条 SQL 被解析为 MappedStatement：**

```java
public class MappedStatement {
    private String id;                    // namespace + id
    private SqlSource sqlSource;          // 包含原始 SQL
    private SqlCommandType sqlCommandType; // SELECT/INSERT/...
    private ResultMap resultMap;           // 结果映射
    private boolean flushCacheRequired;    // 是否清空缓存
    private boolean useCache;              // 是否使用二级缓存
    // ...
}
```

## 三、Mapper 代理原理

这是 MyBatis 最核心的机制——**你写的 Mapper 接口是怎么被调用的？**

### 3.1 获取 Mapper

```java
// 获取 Mapper 代理
UserMapper mapper = sqlSession.getMapper(UserMapper.class);
User user = mapper.selectById(1L);
```

### 3.2 创建代理

```java
// DefaultSqlSession.getMapper()
public <T> T getMapper(Class<T> type) {
    return configuration.getMapper(type, this);
}

// MapperRegistry.getMapper()
@SuppressWarnings("unchecked")
public <T> T getMapper(Class<T> type, SqlSession sqlSession) {
    MapperProxyFactory<T> factory = knownMappers.get(type);
    return factory.newInstance(sqlSession);
}

// MapperProxyFactory.newInstance()
public T newInstance(SqlSession sqlSession) {
    MapperProxy<T> mapperProxy = new MapperProxy<>(sqlSession, mapperInterface, methodCache);
    return Proxy.newProxyInstance(
        mapperInterface.getClassLoader(),
        new Class[]{mapperInterface},
        mapperProxy
    );
}
```

### 3.3 MapperProxy 调用链

```java
public class MapperProxy<T> implements InvocationHandler {
    
    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        // 1. 如果是 Object 方法，直接走原方法
        if (Object.class.equals(method.getDeclaringClass())) {
            return method.invoke(this, args);
        }
        
        // 2. 查找对应的 MappedStatement
        MappedStatement ms = cachedMapperMethod(method);
        
        // 3. 执行 SQL
        return sqlSession.selectOne(ms.getId(), args);
    }
}
```

**核心逻辑：** JDK 动态代理将 Mapper 接口的方法调用，转换为 `SqlSession.selectOne() / insert() / update() / delete()` 的调用，参数就是 MappedStatement 的 id。

## 四、SQL 执行全流程

```
MapperProxy.invoke()
    ↓
SqlSession.selectOne()
    ↓
Executor.query()          ← 含一级缓存逻辑
    ↓
StatementHandler.query()  ← 含插件拦截点
    ↓
ParameterHandler.setParameters()  ← 参数绑定
    ↓
Statement.execute()       ← JDBC 执行
    ↓
ResultSetHandler.handleResultSets()  ← 结果映射
    ↓
返回结果
```

### 4.1 Executor — 执行器

MyBatis 有三种 Executor：

| 类型 | 说明 | 默认？ | 场景 |
|------|------|--------|------|
| **SimpleExecutor** | 每次执行都创建 Statement | ✅ 默认 | 简单查询 |
| **ReuseExecutor** | 复用 PreparedStatement | ❌ | 同 SQL 多次执行 |
| **BatchExecutor** | 批量执行 | ❌ | 批量 INSERT/UPDATE |

```java
// 配置方式
configuration.setDefaultExecutorType(ExecutorType.BATCH);
```

**SimpleExecutor.query() 核心逻辑：**

```java
public <E> List<E> query(MappedStatement ms, Object parameter, 
                         RowBounds rowBounds, ResultHandler resultHandler) throws SQLException {
    // 1. 获取 BoundSql（含 #{} 替换后的 SQL）
    BoundSql boundSql = ms.getBoundSql(parameter);
    
    // 2. 创建缓存 key
    CacheKey key = createCacheKey(ms, parameter, rowBounds, boundSql);
    
    // 3. 查询缓存（一级缓存）
    return query(ms, parameter, rowBounds, resultHandler, key, boundSql);
}

private <E> List<E> queryFromDatabase(MappedStatement ms, Object parameter,
                                       RowBounds rowBounds, ResultHandler resultHandler,
                                       CacheKey key, BoundSql boundSql) throws SQLException {
    // 1. 创建 StatementHandler
    StatementHandler handler = configuration.newStatementHandler(
        ms, parameter, rowBounds, resultHandler, boundSql);
    
    // 2. 创建 Statement 并执行
    Statement stmt = prepareStatement(handler);
    
    // 3. 执行查询
    return handler.query(stmt, resultHandler);
}
```

### 4.2 StatementHandler

```java
// 预编译处理
public class PreparedStatementHandler extends BaseStatementHandler {
    
    @Override
    public Statement prepare(Connection connection, Integer transactionTimeout) throws SQLException {
        // 创建 PreparedStatement
        PreparedStatement ps = connection.prepareStatement(sql);
        
        // 设置超时时间
        ps.setQueryTimeout(queryTimeout);
        
        // 设置 fetchSize
        ps.setFetchSize(fetchSize);
        
        return ps;
    }
    
    @Override
    public void parameterize(Statement statement) throws SQLException {
        // 设置参数
        parameterHandler.setParameters((PreparedStatement) statement);
    }
    
    @Override
    public <E> List<E> query(Statement statement, ResultHandler resultHandler) throws SQLException {
        PreparedStatement ps = (PreparedStatement) statement;
        ps.execute();
        return resultSetHandler.handleResultSets(ps);
    }
}
```

### 4.3 ParameterHandler — 参数绑定

```java
public class DefaultParameterHandler implements ParameterHandler {
    
    @Override
    public void setParameters(PreparedStatement ps) {
        // 遍历所有参数映射
        for (ParameterMapping mapping : boundSql.getParameterMappings()) {
            // 获取参数值
            Object value = getParameterValue(mapping);
            
            // 获取对应的 TypeHandler
            TypeHandler typeHandler = mapping.getTypeHandler();
            
            // 调用 TypeHandler 设置参数
            typeHandler.setParameter(ps, mapping.getJdbcType(), value);
        }
    }
}
```

### 4.4 ResultSetHandler — 结果映射

```java
public class DefaultResultSetHandler implements ResultSetHandler {
    
    @Override
    public List<Object> handleResultSets(Statement stmt) throws SQLException {
        List<Object> results = new ArrayList<>();
        ResultSet rs = stmt.getResultSet();
        
        // 处理 ResultSet
        while (true) {
            // 根据 ResultMap 映射结果
            Object row = handleRowValues(rs, resultMap);
            results.add(row);
            if (!rs.next()) break;
        }
        
        return results;
    }
    
    private Object handleRowValues(ResultSet rs, ResultMap resultMap) throws SQLException {
        // 1. 创建结果对象（反射或构造函数）
        Object result = createResultObject(rs, resultMap);
        
        // 2. 设置属性值
        for (ResultMapping mapping : resultMap.getResultMappings()) {
            setValue(result, mapping, rs);
        }
        
        // 3. 处理关联查询（@One, @Many）
        applyNestedResultMappings(rs, result, resultMap);
        
        return result;
    }
}
```

## 五、MyBatis 缓存机制

### 5.1 一级缓存（SqlSession 级别）

**默认开启，无法关闭（MyBatis 3 后可以配置）。**

```java
SqlSession session = sqlSessionFactory.openSession();
UserMapper mapper = session.getMapper(UserMapper.class);

User u1 = mapper.selectById(1L);  // 查数据库
User u2 = mapper.selectById(1L);  // 走一级缓存，不查数据库

System.out.println(u1 == u2);  // true（同一对象引用）
```

**一级缓存失效场景：**

```java
// 1. 执行了 DML 操作（INSERT/UPDATE/DELETE）
mapper.updateUser(user);
User u3 = mapper.selectById(1L);  // 缓存被清空，重新查库

// 2. 手动清空
sqlSession.clearCache();

// 3. 不同 SqlSession
SqlSession session2 = sqlSessionFactory.openSession();
UserMapper mapper2 = session2.getMapper(UserMapper.class);
User u4 = mapper2.selectById(1L);  // 不同 SqlSession，无缓存
```

**一级缓存源码：**

```java
// BaseExecutor.query()
public <E> List<E> query(MappedStatement ms, Object parameter, 
                         RowBounds rowBounds, ResultHandler resultHandler,
                         CacheKey key, BoundSql boundSql) throws SQLException {
    // 查一级缓存
    List<E> list = localCache.getObject(key);
    
    if (list == null) {
        // 缓存未命中，查数据库
        list = queryFromDatabase(ms, parameter, rowBounds, resultHandler, key, boundSql);
    }
    
    return list;
}

// DML 操作后清空缓存
public int update(MappedStatement ms, Object parameter) throws SQLException {
    // 清空一级缓存
    clearLocalCache();
    return doUpdate(ms, parameter);
}
```

### 5.2 二级缓存（Namespace 级别）

**跨 SqlSession 共享，需要手动开启。**

```xml
<!-- mybatis-config.xml -->
<settings>
    <setting name="cacheEnabled" value="true"/>
</settings>

<!-- Mapper XML 中开启 -->
<mapper namespace="com.example.mapper.UserMapper">
    <cache eviction="LRU" flushInterval="60000" size="512" readOnly="true"/>
</mapper>
```

| 属性 | 默认值 | 说明 |
|------|--------|------|
| `eviction` | LRU | 淘汰策略（LRU/FIFO/SOFT/WEAK） |
| `flushInterval` | 无 | 刷新间隔（毫秒） |
| `size` | 1024 | 缓存最大引用数 |
| `readOnly` | false | 只读返回同一实例/可读写返回拷贝 |
| `blocking` | false | 阻塞读（防止并发穿透） |

**二级缓存执行流程（CachingExecutor）：**

```java
public class CachingExecutor implements Executor {
    
    private Executor delegate;  // 真正的 Executor
    private TransactionalCacheManager cacheManager;
    
    @Override
    public <E> List<E> query(MappedStatement ms, Object parameter, 
                             RowBounds rowBounds, ResultHandler resultHandler) throws SQLException {
        if (ms.isUseCache()) {
            // 1. 获取二级缓存
            Cache cache = ms.getCache();
            
            // 2. 查二级缓存
            List<E> list = cache.getObject(key);
            if (list != null) return list;
            
            // 3. 未命中 → 委托 Executor 查（走一级缓存 + 数据库）
            list = delegate.query(ms, parameter, rowBounds, resultHandler);
            
            // 4. 写入二级缓存
            cache.putObject(key, list);
            return list;
        }
        
        return delegate.query(ms, parameter, rowBounds, resultHandler);
    }
}
```

**⚠️ 二级缓存使用场景限制：**
- 查询多、更新少的场景
- 多个 SqlSession 共享数据
- **不能有跨表关联**（不同 Mapper 修改同一张表会导致脏数据）

### 5.3 自定义缓存

```java
// 实现 Cache 接口
public class RedisCache implements Cache {
    private final String id;
    private final RedisTemplate<String, Object> redisTemplate;
    
    @Override
    public void putObject(Object key, Object value) {
        redisTemplate.opsForValue().set(
            id + ":" + key.toString(), 
            value, 
            30, TimeUnit.MINUTES
        );
    }
    
    @Override
    public Object getObject(Object key) {
        return redisTemplate.opsForValue().get(id + ":" + key.toString());
    }
}

// Mapper XML 中使用
<mapper namespace="...">
    <cache type="com.example.config.RedisCache"/>
</mapper>
```

## 六、MyBatis 插件机制（拦截器）

MyBatis 允许你拦截四大核心对象的方法：

```java
@Intercepts({
    @Signature(
        type = Executor.class,
        method = "query",
        args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class}
    ),
    @Signature(
        type = Executor.class,
        method = "update",
        args = {MappedStatement.class, Object.class}
    )
})
public class SqlMonitorPlugin implements Interceptor {
    
    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        MappedStatement ms = (MappedStatement) invocation.getArgs()[0];
        
        // 前置处理
        long start = System.currentTimeMillis();
        
        try {
            // 执行目标方法
            return invocation.proceed();
        } finally {
            // 后置处理
            long cost = System.currentTimeMillis() - start;
            System.out.println("SQL[" + ms.getId() + "] 耗时: " + cost + "ms");
            if (cost > 1000) {
                System.err.println("慢SQL告警: " + ms.getId() + " -> " + cost + "ms");
            }
        }
    }
}
```

**可拦截的四大对象：**

| 对象 | 作用 | 常见插件场景 |
|------|------|-------------|
| `Executor` | SQL 执行器 | 分页、缓存、审计 |
| `StatementHandler` | JDBC 处理器 | 改写 SQL、分页 |
| `ParameterHandler` | 参数处理 | 参数加密 |
| `ResultSetHandler` | 结果处理 | 结果脱敏 |

## 七、常见面试题

### Q1：MyBatis 中 #{} 和 ${} 的区别？

```java
// #{} → 预编译，防 SQL 注入 ✅ 推荐
@Select("SELECT * FROM user WHERE id = #{id}")
// 生成: SELECT * FROM user WHERE id = ?  (PreparedStatement)

// ${} → 字符串拼接，有 SQL 注入风险 ❌
@Select("SELECT * FROM user WHERE name = '${name}'")
// 生成: SELECT * FROM user WHERE name = 'admin'  (直接拼接)
```

**原则：能用 #{} 绝不用 ${}，只有表名、排序字段等动态标识才用 ${}。**

### Q2：MyBatis 一级缓存和二级缓存有什么区别？

| 维度 | 一级缓存 | 二级缓存 |
|------|----------|----------|
| 作用域 | SqlSession | Mapper（Namespace） |
| 默认状态 | 开启 | 关闭 |
| 共享范围 | 单次会话内 | 跨会话 |
| 生命周期 | SqlSession 生命周期 | 应用级别 |
| 序列化 | 不需要 | 需要（可能跨 JVM） |

### Q3：MyBatis 和 MyBatis-Plus 的关系？

**MyBatis-Plus 是 MyBatis 的增强工具，在 MyBatis 基础上做了：**
- **自动 CRUD** — 继承 BaseMapper 就自带增删改查
- **分页插件** — 自动拦截 SQL 生成 COUNT + LIMIT
- **条件构造器** — LambdaQueryWrapper 链式查询
- **代码生成器** — AutoGenerator 生成 Entity/Mapper/Service
- **乐观锁插件** — @Version 自动处理版本号

## 八、总结

MyBatis 的核心设计思想是**将 SQL 从 Java 代码中解耦**，通过 XML 或注解管理 SQL，配合动态代理自动生成 Mapper 实现。

全流程一句话总结：

> **MapperProxy 动态代理 → SqlSession → Executor（含一级缓存）→ StatementHandler → ParameterHandler 设置参数 → JDBC 执行 → ResultSetHandler 映射结果**

理解这个流程，你就掌握了 MyBatis 的精髓。
