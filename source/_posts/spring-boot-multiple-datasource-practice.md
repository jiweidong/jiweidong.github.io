---
title: 【Spring Boot 实战】多数据源配置与动态切换实战：从基础到高级
date: 2026-07-17 08:00:00
tags:
  - Spring Boot
  - 多数据源
  - MyBatis
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】多数据源配置与动态切换实战：从基础到高级

## 引言

在实际项目中，多数据源是绕不开的需求：

- **主从分离**：写主库、读从库，提升读写性能
- **多库拆分**：业务数据在一个库，日志、报表在另一个库
- **异构数据源**：MySQL + PostgreSQL + Redis + MongoDB 混用
- **分库分表**：按业务域或租户隔离到不同数据库
- **历史数据归档**：热数据在本库，冷数据在归档库

本文从「最简单的多数据源配置」开始，逐步深入到「动态数据源切换」「读写分离」「分布式事务」等企业级方案。

## 一、基础篇：多 DataSource 配置（静态多数据源）

### 1.1 场景：两个 MySQL 库

假设有两个库：
- `db_user`（用户数据库）
- `db_order`（订单数据库）

### 1.2 application.yml 配置

```yaml
spring:
  datasource:
    user:
      jdbc-url: jdbc:mysql://localhost:3306/db_user?useSSL=false&serverTimezone=Asia/Shanghai
      username: root
      password: root123
      driver-class-name: com.mysql.cj.jdbc.Driver
    order:
      jdbc-url: jdbc:mysql://localhost:3306/db_order?useSSL=false&serverTimezone=Asia/Shanghai
      username: root
      password: root123
      driver-class-name: com.mysql.cj.jdbc.Driver
```

**注意**：这里用的是 `jdbc-url` 而不是 `url`（Spring Boot 自动配置的单数据源用 `url`，多数据源手动配置时用 `jdbc-url`）。

### 1.3 配置类实现

```java
@Configuration
public class DataSourceConfig {

    @Bean
    @ConfigurationProperties(prefix = "spring.datasource.user")
    public DataSource userDataSource() {
        return DataSourceBuilder.create()
                .type(HikariDataSource.class)
                .build();
    }

    @Bean
    @ConfigurationProperties(prefix = "spring.datasource.order")
    public DataSource orderDataSource() {
        return DataSourceBuilder.create()
                .type(HikariDataSource.class)
                .build();
    }

    @Bean
    public SqlSessionFactory userSqlSessionFactory(
            @Qualifier("userDataSource") DataSource dataSource) throws Exception {
        SqlSessionFactoryBean bean = new SqlSessionFactoryBean();
        bean.setDataSource(dataSource);
        // 指定 user 库的 mapper 位置
        bean.setMapperLocations(
                new PathMatchingResourcePatternResolver()
                        .getResources("classpath:mapper/user/*.xml"));
        return bean.getObject();
    }

    @Bean
    public SqlSessionFactory orderSqlSessionFactory(
            @Qualifier("orderDataSource") DataSource dataSource) throws Exception {
        SqlSessionFactoryBean bean = new SqlSessionFactoryBean();
        bean.setDataSource(dataSource);
        bean.setMapperLocations(
                new PathMatchingResourcePatternResolver()
                        .getResources("classpath:mapper/order/*.xml"));
        return bean.getObject();
    }

    @Bean
    public MapperScannerConfigurer userMapperScanner() {
        MapperScannerConfigurer config = new MapperScannerConfigurer();
        config.setBasePackage("com.example.mapper.user");
        config.setSqlSessionFactoryBeanName("userSqlSessionFactory");
        return config;
    }

    @Bean
    public MapperScannerConfigurer orderMapperScanner() {
        MapperScannerConfigurer config = new MapperScannerConfigurer();
        config.setBasePackage("com.example.mapper.order");
        config.setSqlSessionFactoryBeanName("orderSqlSessionFactory");
        return config;
    }
}
```

### 1.4 优缺点分析

| 优点 | 缺点 |
|------|------|
| 配置清晰，每个库独立管理 | Mapper 必须严格分包 |
| 隔离性好，互不影响 | 不支持运行时切换数据源 |
| 性能好，没有动态代理开销 | 代码不能跨库复用（同一个 Service 里无法切换） |
| 简单直接，适合库数量固定 | 库多了配置会爆炸 |

**适用场景**：数据源数量固定、Mapper 完全按库分离、不需要在一个方法内切换数据源。

## 二、进阶篇：动态数据源切换（@DS 注解方案）

### 2.1 什么是动态数据源？

核心思想：通过 `AbstractRoutingDataSource` 实现**运行时动态选择**数据源。

```
请求 → AOP 拦截 @DS 注解 → 设置 ThreadLocal 数据源 key → AbstractRoutingDataSource 返回对应 DataSource → 执行 SQL
```

### 2.2 自定义动态数据源实现

```java
/**
 * 动态数据源上下文持有者
 */
public class DynamicDataSourceContextHolder {
    private static final ThreadLocal<String> CONTEXT_HOLDER = 
            ThreadLocal.withInitial(() -> "master");  // 默认主库
    
    public static void setDataSource(String dataSource) {
        CONTEXT_HOLDER.set(dataSource);
    }
    
    public static String getDataSource() {
        return CONTEXT_HOLDER.get();
    }
    
    public static void clear() {
        CONTEXT_HOLDER.remove();
    }
}
```

```java
/**
 * 动态数据源——继承 AbstractRoutingDataSource
 */
public class DynamicDataSource extends AbstractRoutingDataSource {
    
    @Override
    protected Object determineCurrentLookupKey() {
        // 关键方法：返回当前线程要用的数据源 key
        return DynamicDataSourceContextHolder.getDataSource();
    }
}
```

### 2.3 @DS 自定义注解

```java
@Target({ElementType.METHOD, ElementType.TYPE})
@Retention(RetentionPolicy.RUNTIME)
@Documented
public @interface DS {
    String value() default "master";
}
```

### 2.4 AOP 切面实现

```java
@Aspect
@Component
@Order(0)  // 优先级高，在事务之前执行
public class DataSourceAspect {
    
    @Around("@annotation(ds)")  // 方法级别
    public Object around(ProceedingJoinPoint point, DS ds) throws Throwable {
        String dataSource = ds.value();
        try {
            DynamicDataSourceContextHolder.setDataSource(dataSource);
            return point.proceed();
        } finally {
            DynamicDataSourceContextHolder.clear();
        }
    }
}
```

### 2.5 配置与使用

```java
// 配置所有数据源
@Configuration
public class DynamicDataSourceConfig {
    
    @Bean
    @ConfigurationProperties(prefix = "spring.datasource.master")
    public DataSource masterDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }
    
    @Bean
    @ConfigurationProperties(prefix = "spring.datasource.slave")
    public DataSource slaveDataSource() {
        return DataSourceBuilder.create().type(HikariDataSource.class).build();
    }
    
    @Bean
    @Primary
    public DataSource dynamicDataSource() {
        DynamicDataSource dds = new DynamicDataSource();
        // 设置默认数据源
        dds.setDefaultTargetDataSource(masterDataSource());
        
        // 注册所有数据源
        Map<Object, Object> targetDataSources = new HashMap<>();
        targetDataSources.put("master", masterDataSource());
        targetDataSources.put("slave", slaveDataSource());
        dds.setTargetDataSources(targetDataSources);
        
        return dds;
    }
}
```

**在 Service 层使用**：

```java
@Service
public class OrderService {
    
    @Autowired
    private OrderMapper orderMapper;
    
    // 写操作走主库
    @DS("master")
    @Transactional
    public void createOrder(Order order) {
        orderMapper.insert(order);
    }
    
    // 读操作走从库
    @DS("slave")
    public Order getOrder(Long id) {
        return orderMapper.selectById(id);
    }
}
```

## 三、高级实战：读写分离 + 负载均衡

### 3.1 一主多从架构

```
                     ┌→ Slave1
Master → Proxy/DDS ──┼→ Slave2
                     └→ Slave3
```

### 3.2 带负载均衡的动态多从库

```java
@Component
public class ReadOnlyDataSourceRouter {
    
    // 从库列表（可动态添加）
    private final List<String> slaveKeys = new CopyOnWriteArrayList<>();
    private final AtomicInteger counter = new AtomicInteger(0);
    
    public ReadOnlyDataSourceRouter() {
        slaveKeys.add("slave1");
        slaveKeys.add("slave2");
        slaveKeys.add("slave3");
    }
    
    /**
     * 轮询选择一个从库
     */
    public String selectSlave() {
        if (slaveKeys.isEmpty()) {
            return "master";
        }
        int index = Math.abs(counter.getAndIncrement() % slaveKeys.size());
        return slaveKeys.get(index);
    }
    
    public void addSlave(String key) {
        slaveKeys.add(key);
    }
    
    public void removeSlave(String key) {
        slaveKeys.remove(key);
    }
}
```

### 3.3 自动读写分离的 AOP

```java
@Aspect
@Component
@Order(0)
public class ReadWriteSeparationAspect {
    
    @Autowired
    private ReadOnlyDataSourceRouter router;
    
    /**
     * 拦截所有 Service 方法，自动判断读写
     * 以 get/query/select/find/list/count 开头的方法 -> 从库
     * 其他 -> 主库
     */
    @Around("execution(* com.example.service..*.*(..))")
    public Object around(ProceedingJoinPoint point) throws Throwable {
        String methodName = point.getSignature().getName();
        String dataSource;
        
        // 读方法走从库，其余走主库
        if (methodName.matches("^(get|query|select|find|list|count|search).*")) {
            dataSource = router.selectSlave();
        } else {
            dataSource = "master";
        }
        
        try {
            DynamicDataSourceContextHolder.setDataSource(dataSource);
            return point.proceed();
        } finally {
            DynamicDataSourceContextHolder.clear();
        }
    }
}
```

**使用效果**：Service 方法上不用加任何注解，自动根据方法名前缀切换数据源！

### 3.4 注意事项

**坑1：事务内的读写分离**

Spring 的 `@Transactional` 会把整个方法的数据库连接绑定到同一个数据源。如果在读方法上写了 `@Transactional(readOnly = true)`，则无法在事务内切换到从库。

**解决方法**：
```java
// ✅ 正确：事务注解和数据源注解一起用
@DS("slave")
@Transactional(readOnly = true)
public List<Order> queryOrders() {
    return orderMapper.selectList();
}

// ❌ 问题代码：事务内无法切换数据源
@Transactional(readOnly = true)
public List<Order> queryOrders() {
    DynamicDataSourceContextHolder.setDataSource("slave"); // 无效！
    return orderMapper.selectList();
}
```

**坑2：@DS 注解必须在事务之前生效**

AOP 执行顺序：
1. `@Transactional` 拦截（优先级最低，默认 `Order = Integer.MAX_VALUE`）
2. `@DS` 切面拦截（优先级最高，设置 `@Order(0)`）

所以 `@DS` 需要在事务之前设置上下文。

## 四、企业级方案对比

| 方案 | 实现复杂度 | 灵活性 | 性能 | 推荐场景 |
|------|:---:|:---:|:---:|--------|
| 静态多 DataSource | 低 | 低 | 最高 | 库固定、功能完全分离 |
| 动态 @DS 注解 | 中 | 高 | 中 | 主从分离、多库业务 |
| 读写分离 Proxy | 中 | 高 | 高 | 一主多从架构 |
| ShardingSphere-JDBC | 高 | 极高 | 中高 | 分库分表 + 读写分离 |
| ShardingSphere-Proxy | 中 | 极高 | 中 | 异构语言、透明接入 |
| MySQL Group Replication | 低 | 中 | 高 | MySQL 原生方案 |

## 五、分布式事务注意事项

当操作跨两个数据源时，单机事务就失效了，需要引入分布式事务：

### 5.1 使用 Seata AT 模式

```java
// 引入依赖
// seata-spring-boot-starter

@GlobalTransactional
public void createOrderWithLog(Order order, Log log) {
    // db1: 插入订单
    orderMapper.insert(order);
    // db2: 插入日志（不同数据源）
    logMapper.insert(log);
    // 任一失败，Seata 自动回滚
}
```

### 5.2 用消息队列实现最终一致性

对于非强一致要求，推荐用 MQ 方案（更轻量）：

```java
public void createOrderWithEvent(Order order) {
    // 1. 写入订单（本地事务）
    orderMapper.insert(order);
    
    // 2. 发送事件到 MQ
    eventPublisher.publish(new OrderCreatedEvent(order.getId()));
    
    // Consumer 端：写入日志库（异步 + 重试）
    // 如果失败，MQ 重试机制保证最终一致
}
```

## 六、常见面试问答

**Q1：`AbstractRoutingDataSource` 的工作原理是什么？**

A：`AbstractRoutingDataSource` 是 Spring 提供的抽象数据源路由类。它的核心方法 `determineCurrentLookupKey()` 决定了当前线程应该使用哪个目标数据源。底层原理是：
1. 持有 `Map<Object, Object> targetDataSources` 存储所有数据源
2. 调用 `getConnection()` 时，通过 `determineCurrentLookupKey()` 获取 key
3. 从 Map 中找到对应 DataSource，调用其 `getConnection()`
4. 如果没有匹配，使用默认数据源

**Q2：为什么 @DS 注解要设置 @Order(0)？**

A：因为 `@Transactional` 会在方法执行前开启事务，而事务会绑定一个数据源连接。如果不把 @DS 设置在事务之前执行，当事务开始时还不知道用什么数据源，会导致连接从默认数据源获取后无法切换。设置 `@Order(0)` 确保 @DS 切面在 @Transactional 切面（`Order = Integer.MAX_VALUE`）之前执行。

**Q3：多数据源下遇到 LazyInitializationException 怎么办？**

A：这是典型的「跨数据源懒加载」问题。当 A 库的 Entity 持有 B 库的关联对象时，懒加载会失败。解决方案：
1. 在序列化之前提前加载（`@Transactional` 内的查询）
2. 用 DTO 替代 Entity 传输
3. 关闭懒加载（不推荐）
4. 考虑是否需要真的跨库关联——微服务下应该拆开

**Q4：多数据源与 MyBatis-Plus 的兼容性如何？**

A：完全兼容。MyBatis-Plus 的 `SqlSessionFactoryBean` 和 `MapperScannerConfigurer` 配置方式与原生 MyBatis 一致。MyBatis-Plus 的分页插件、乐观锁等需要在每个 `SqlSessionFactory` 上都配置一遍。

## 七、总结

多数据源在 Spring Boot 中有多种实现方案，选择取决于具体场景：

1. **库完全独立、不交叉** → 静态多 DataSource + 分包 Mapper
2. **主从读写分离** → 动态 @DS 注解 + AbstractRoutingDataSource
3. **分库分表 + 读写分离** → ShardingSphere-JDBC
4. **跨库事务** → Seata（强一致）或 MQ（最终一致）

记住：**多数据源增加了系统复杂度**，能不分库就不要分。真正的微服务架构下，每个服务只连自己的数据库是最佳实践。
