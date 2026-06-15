---
title: 分库分表实战：ShardingSphere 核心原理与最佳实践
date: 2026-06-15 23:30:00
tags:
  - ShardingSphere
  - 分库分表
  - 分布式数据库
  - 中间件
categories:
  - 数据库
author: 东哥
---

# 分库分表实战：ShardingSphere 核心原理与最佳实践

> 当单库数据量达到千万级、QPS 达到万级时，分库分表是数据库扩展的必经之路。本文深入 ShardingSphere 的分片原理、读写分离、分布式事务等核心能力。

## 一、为什么要分库分表

### 1.1 单库瓶颈

| 规模 | 问题 | 表现 |
|------|------|------|
| 数据量 > 500 万 | 索引层级深 | B+树层数增加，IO 次数增加 |
| 数据量 > 1 亿 | 查询缓慢 | 全表扫描耗时长 |
| QPS > 5000 | 连接池打满 | 数据库连接不够用 |
| 磁盘 > 500G | 备份困难 | 备份时间过长 |

### 1.2 拆分策略

```
垂直拆分（按业务拆分）：
┌─────────────────┐
│    用户库        │  → users
├─────────────────┤
│    订单库        │  → orders
├─────────────────┤
│    商品库        │  → products
└─────────────────┘

水平拆分（按数据分片）：
┌─────────────────┐
│     orders_0     │  → user_id % 4 = 0
├─────────────────┤
│     orders_1     │  → user_id % 4 = 1
├─────────────────┤
│     orders_2     │  → user_id % 4 = 2
├─────────────────┤
│     orders_3     │  → user_id % 4 = 3
└─────────────────┘
```

## 二、ShardingSphere 架构

### 2.1 核心组件

```
┌─────────────────────────────────────────────┐
│               Application                     │
├─────────────────────────────────────────────┤
│           ShardingSphere-JDBC                │
│  ┌─────────┐ ┌────────┐ ┌───────────────┐  │
│  │ SQL解析  │ │ SQL优化│ │  SQL路由     │  │
│  └─────────┘ └────────┘ └───────────────┘  │
│  ┌─────────┐ ┌────────┐ ┌───────────────┐  │
│  │ SQL改写  │ │ SQL执行│ │  结果归并     │  │
│  └─────────┘ └────────┘ └───────────────┘  │
├─────────────────────────────────────────────┤
│   ds0     ds1     ds2     ds3                │
│  orders_0 orders_1 orders_2 orders_3         │
└─────────────────────────────────────────────┘
```

### 2.2 架构选型对比

| 特性 | ShardingSphere-JDBC | ShardingSphere-Proxy |
|------|---------------------|---------------------|
| 部署方式 | 嵌入应用 | 独立服务 |
| 性能 | 最高（无中间跳转） | 较低（网络开销） |
| 协议 | JDBC 直连 | MySQL/PostgreSQL 协议 |
| 管理 | 应用内配置 | 独立运维 |

## 三、快速接入

### 3.1 Maven 依赖

```xml
<dependency>
    <groupId>org.apache.shardingsphere</groupId>
    <artifactId>shardingsphere-jdbc-core</artifactId>
    <version>5.4.0</version>
</dependency>
```

### 3.2 YAML 配置

```yaml
spring:
  shardingsphere:
    datasource:
      names: ds0, ds1
      ds0:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://localhost:3306/db0
        username: root
        password: ***
      ds1:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://localhost:3306/db1
        username: root
        password: ***

    rules:
      sharding:
        tables:
          orders:
            actual-data-nodes: ds$->{0..1}.orders_$->{0..3}
            table-strategy:
              standard:
                sharding-column: order_id
                sharding-algorithm-name: orders-table-inline
            database-strategy:
              standard:
                sharding-column: user_id
                sharding-algorithm-name: orders-db-inline
        sharding-algorithms:
          orders-table-inline:
            type: INLINE
            props:
              algorithm-expression: orders_$->{order_id % 4}
          orders-db-inline:
            type: INLINE
            props:
              algorithm-expression: ds$->{user_id % 2}
```

### 3.3 Java API 配置

```java
@Configuration
public class ShardingConfig {

    @Bean
    public ShardingSphereDataSource shardingDataSource() {
        // 配置数据源
        Map<String, DataSource> dataSources = new HashMap<>();
        dataSources.put("ds0", createDataSource("jdbc:mysql://localhost:3306/db0"));
        dataSources.put("ds1", createDataSource("jdbc:mysql://localhost:3306/db1"));

        // 配置分片规则
        ShardingTableRuleConfiguration orderRule = 
            new ShardingTableRuleConfiguration("orders", "ds$->{0..1}.orders_$->{0..3}");
        orderRule.setDatabaseShardingStrategy(new StandardShardingStrategyConfiguration(
            "user_id", "dbShardingAlgorithm"));
        orderRule.setTableShardingStrategy(new StandardShardingStrategyConfiguration(
            "order_id", "tableShardingAlgorithm"));

        return ShardingSphereDataSourceFactory.createDataSource(
            dataSources, 
            Collections.singleton(new ShardingRuleConfiguration(
                Collections.singleton(orderRule), 
                algorithms)),
            new Properties());
    }
}
```

## 四、分片策略精讲

### 4.1 内置分片算法

```yaml
# 1. MOD 取模分片
sharding-algorithms:
  mod-algorithm:
    type: MOD
    props:
      sharding-count: 4

# 2. HASH_MODE 哈希取模
  hash-algorithm:
    type: HASH_MOD
    props:
      sharding-count: 4

# 3. VOLUME_RANGE 范围分片
  range-algorithm:
    type: VOLUME_RANGE
    props:
      range-lower: 0
      range-upper: 10000000
      sharding-volume: 1000000
```

### 4.2 自定义分片算法

```java
public class OrderShardingAlgorithm 
        implements StandardShardingAlgorithm<Long> {

    @Override
    public String doSharding(
            Collection<String> availableTargetNames, 
            PreciseShardingValue<Long> shardingValue) {
        
        Long orderId = shardingValue.getValue();
        int index = (int) (orderId % 4);
        
        for (String target : availableTargetNames) {
            if (target.endsWith(String.valueOf(index))) {
                return target;
            }
        }
        throw new IllegalArgumentException("No target found");
    }

    @Override
    public Collection<String> doSharding(
            Collection<String> availableTargetNames,
            RangeShardingValue<Long> shardingValue) {
        
        Range<Long> range = shardingValue.getValueRange();
        Collection<String> result = new LinkedHashSet<>();
        
        // 范围查询，需要查所有可能的分片
        Long lower = range.lowerEndpoint();
        Long upper = range.upperEndpoint();
        for (long i = lower / 1000000; i <= upper / 1000000; i++) {
            result.add("orders_" + (i % 4));
        }
        return result;
    }
}
```

## 五、读写分离

```yaml
spring:
  shardingsphere:
    rules:
      readwrite-splitting:
        data-sources:
          order-ds:
            write-data-source-name: ds-master
            read-data-source-names:
              - ds-slave-0
              - ds-slave-1
            load-balancer-name: round-robin
        load-balancers:
          round-robin:
            type: ROUND_ROBIN

# 强制读主库
@Transactional  // 事务内自动路由到主库
public void createOrder(Order order) {
    orderMapper.insert(order);
    // 事务内的读操作也会走主库（读写一致）
    Order saved = orderMapper.selectById(order.getId());
}
```

## 六、分布式主键

```java
// 内置雪花算法
@TableId(type = IdType.INPUT)  // 手动设置主键
private Long orderId;

// ShardingSphere 分布式主键配置
spring:
  shardingsphere:
    rules:
      sharding:
        key-generators:
          snowflake:
            type: SNOWFLAKE
            props:
              worker-id: 1
              max-vibration-offset: 8

// 雪花算法 ID 结构
// 1 bit 符号位 | 41 bit 时间戳 | 10 bit 工作机器 | 12 bit 序列号
// 特点：全局唯一、趋势递增、高性能（百万级/s）

// 雪花算法缺陷与优化
// ❌ 时钟回拨问题
// ❌ 分页查询时 ID 趋势递增无法保证全局有序
// ✅ 可结合号段模式（segment）如 Leaf
```

## 七、分布式事务

### 7.1 支持的事务类型

```yaml
# 1. LOCAL 事务（默认）：跨库操作不保证原子性
# 2. XA 事务（两阶段提交）：强一致，性能差
# 3. BASE 事务（柔性事务）：最终一致，性能好

# 配置 XA 事务
spring:
  shardingsphere:
    props:
      xa-transaction-manager-type: Atomikos
```

### 7.2 Seata AT 事务

```xml
<dependency>
    <groupId>org.apache.shardingsphere</groupId>
    <artifactId>shardingsphere-transaction-base-seata-at</artifactId>
</dependency>
```

```java
@GlobalTransactional  // Seata 全局事务
public void createOrderAndReduceStock(Order order, Long productId) {
    // 跨库操作
    orderMapper.insert(order);         // 订单库
    stockMapper.reduceStock(productId); // 库存库
}
```

## 八、避坑指南

### 8.1 分片键选择

```java
// ✅ 分片键选择原则
// 1. 高频查询条件
// 2. 数据分布均匀
// 3. 不可修改

// ✅ 按 user_id 分片（用户维度）
SELECT * FROM orders WHERE user_id = 123;

// ❌ 跨分片查询
SELECT * FROM orders ORDER BY create_time DESC LIMIT 10;
// 需要归并：每个分片 LIMIT 10 → 归并排序 → 取 Top 10

// ❌ 全路由查询
SELECT COUNT(*) FROM orders;  
// 所有分片都要扫描
```

### 8.2 分页优化

```sql
-- ShardingSphere 分页原理
-- LIMIT 10, 20 会被改写成每个分片 LIMIT 30
-- 归并后取 10-30 条

-- 深分页优化：流式归并 + 游标分页
SELECT * FROM orders 
WHERE user_id = 123 AND id > 10000 
ORDER BY id LIMIT 20;
```

### 8.3 数据迁移

```yaml
# 平滑迁移方案
1. 建立双写（新老库同时写）
2. 历史数据迁移（增量同步）
3. 数据校验（确保一致性）
4. 切换读流量
5. 下线老库

# 推荐工具：ShardingSphere-Scaling
# 支持 JDBC 数据迁移
# 自动完成全量 + 增量
```

## 九、总结

分库分表是数据库竖井的终极解法，但也引入了分布式查询、跨库事务等复杂度。核心原则：

1. **能不拆就不拆**：分库分表是最后手段，优先考虑索引优化、缓存、读写分离
2. **分片键要选好**：业务中最常用的查询条件做分片键
3. **跨分片操作要少**：尽量在一次请求中只查一个分片
4. **提前规划容量**：分片数量留有 3-5 年余量

ShardingSphere 掩盖了分库分表的复杂度，但对核心原理的理解依然至关重要。
