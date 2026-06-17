---
title: 数据库分库分表策略与实战避坑指南
date: 2026-06-17 11:30:00
tags:
  - 分库分表
  - 数据库
  - Sharding
  - 架构设计
categories:
  - 数据库
author: 东哥
---

# 数据库分库分表策略与实战避坑指南

## 一、为什么要分库分表

当单表数据量达到千万级甚至亿级时，数据库的读写性能会出现明显下降。分库分表是应对海量数据存储的经典方案。

### 1.1 何时需要分库分表

| 指标 | 安全线 | 警戒线 | 危险线 |
|------|-------|--------|--------|
| 单表行数 | < 500 万 | 500 万-2000 万 | > 2000 万 |
| 单表容量 | < 10 GB | 10-50 GB | > 50 GB |
| 单库连接数 | < 100 | 100-300 | > 300 |
| 单库 QPS | < 1000 | 1000-5000 | > 5000 |
| 写入 TPS | < 500 | 500-2000 | > 2000 |

### 1.2 演进路径

```
单体应用 → 主从读写分离 → 分库 → 分表 → 分库分表
                                   ↑
                           你在这里（大多数场景）
```

## 二、分库分表策略详解

### 2.1 水平分表 vs 垂直分表

**垂直分表**：把大表拆成多个小表，按列拆分。

```
垂直分表前:
┌──────────────────────────────────────────────┐
│ order_id | user_id | amount | status | ...   │
│          |         |        | ext_info(JSON) │
└──────────────────────────────────────────────┘

垂直分表后:
┌─────────────────────┐  ┌──────────────────────┐
│ order_base           │  │ order_extra           │
├─────────────────────┤  ├──────────────────────┤
│ order_id (PK)       │  │ order_id (PK, FK)    │
│ user_id              │  │ ext_info              │
│ amount               │  │ ...                   │
│ status               │  └──────────────────────┘
│ create_time          │
└─────────────────────┘
```

**水平分表**：把大表按行拆分到相同结构的多个表中。

```
水平分表:
order_0: order_id % 16 = 0
order_1: order_id % 16 = 1
... 
order_15: order_id % 16 = 15
```

### 2.2 核心分片策略对比

| 策略 | 算法 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| Hash 取模 | order_id % N | 数据均匀 | 扩容困难 | 固定分片数 |
| 一致性 Hash | hash(order_id) 在环上定位 | 平滑扩容 | 数据倾斜可能 | 需要弹性扩缩 |
| 范围分片 | 按 ID 区间 / 时间 | 扩容简单 | 数据可能不均 | 时间序列数据 |
| 列表分片 | 按地区/类型映射 | 业务直观 | 各分片不均 | 地理数据 |
| 复合分片 | 多字段组合 | 灵活 | 复杂 | 高级场景 |

### 2.3 一致性 Hash 算法详解

```
Hash Ring:
          ┌────── Node-0 ──────┐
          │                     │
    Node-3│                     │Node-1
          │                     │
          └────── Node-2 ──────┘

数据定位: hash(key) % 2^32，顺时针找最近的虚拟节点

虚拟节点引入前：A 节点故障 → B 全盘接管 → 雪崩
虚拟节点引入后：A 节点故障 → 均匀分配到 B/C/D

虚拟节点数: 推荐 100-200 个/物理节点
```

## 三、ShardingSphere 实战

### 3.1 配置示例

```yaml
spring:
  shardingsphere:
    datasource:
      names: ds0,ds1
      ds0:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://192.168.1.100:3306/order_db_0
        username: root
        password: xxxxx
      ds1:
        type: com.zaxxer.hikari.HikariDataSource
        driver-class-name: com.mysql.cj.jdbc.Driver
        jdbc-url: jdbc:mysql://192.168.1.101:3306/order_db_1
        username: root
        password: xxxxx
    
    rules:
      sharding:
        # 分库策略：按 user_id 取模
        default-database-strategy:
          standard:
            sharding-column: user_id
            sharding-algorithm-name: database-hash
        # 分表策略：按 order_id 取模
        tables:
          t_order:
            actual-data-nodes: ds$->{0..1}.t_order_$->{0..15}
            database-strategy:
              standard:
                sharding-column: user_id
                sharding-algorithm-name: database-hash
            table-strategy:
              standard:
                sharding-column: order_id
                sharding-algorithm-name: table-hash
            key-generate-strategy:
              column: id
              key-generator-name: snowflake
        
        # 分片算法
        sharding-algorithms:
          database-hash:
            type: MOD
            props:
              sharding-count: 2
          table-hash:
            type: HASH_MOD
            props:
              sharding-count: 16
        
        # 分布式主键生成（雪花算法）
        key-generators:
          snowflake:
            type: SNOWFLAKE
            props:
              worker-id: 1
```

### 3.2 广播表与绑定表

```yaml
rules:
  sharding:
    binding-tables:
      - t_order, t_order_item      # 绑定表：分片键一致，避免跨库JOIN
    
    broadcast-tables:
      - t_config                   # 广播表：全库全表存在
      - t_dict                     # 字典表
```

绑定表的好处：当 `t_order` 和 `t_order_item` 都基于 `order_id` 分片时，关联查询不会跨库。

## 四、分布式主键生成

### 4.1 方案对比

| 方案 | 结构 | 趋势递增 | 性能 | 依赖 |
|------|------|---------|------|------|
| UUID | 32位字符串 | 否 | 高 | 无 |
| Snowflake | 64位长整型 | 是 | 极高 | 无（仅在代码层） |
| 数据库自增 | 长整型 | 是 | 低 | 数据库 |
| Redis INCR | 长整型 | 是 | 高 | Redis |
| Leaf/MaxId | 长整型 | 是 | 高 | 数据库/ZK |

### 4.2 雪花算法详解

```
Snowflake ID 结构 (64 bit):
┌─────────────────────────────────────────────────────┐
│ 0 │ 41bit 时间戳 │ 10bit 工作机器ID │ 12bit 序列号 │
└─────────────────────────────────────────────────────┘
                    ↓
          二进制展开（举例）:
          0 | 0000000000 0000000000 0000000000 0000000000 0 
            | 0000000000 00 | 0000000000 00 | 0000000000 00
```

| 字段 | 位数 | 说明 | 最大值 |
|------|------|------|--------|
| 符号位 | 1 | 固定为 0 | - |
| 时间戳 | 41 | 毫秒级时间差 | 69 年 |
| 机器 ID | 10 | 部署节点标识 | 1024 台 |
| 序列号 | 12 | 同一毫秒内自增 | 4096/ms |

### 4.3 自定义 Snowflake

```java
public class SnowflakeIdGenerator {
    
    private final long workerId;
    private final long datacenterId;
    private final long epoch = 1577808000000L; // 2020-01-01
    
    private long sequence = 0L;
    private long lastTimestamp = -1L;
    
    private static final long WORKER_ID_BITS = 5L;
    private static final long DATACENTER_ID_BITS = 5L;
    private static final long SEQUENCE_BITS = 12L;
    
    public SnowflakeIdGenerator(long workerId, long datacenterId) {
        this.workerId = workerId;
        this.datacenterId = datacenterId;
    }
    
    public synchronized long nextId() {
        long timestamp = System.currentTimeMillis();
        
        if (timestamp < lastTimestamp) {
            // 时钟回拨处理：等待或使用备用序列
            long offset = lastTimestamp - timestamp;
            if (offset <= 5) {
                Thread.sleep(offset + 1);
                timestamp = System.currentTimeMillis();
            } else {
                throw new RuntimeException("Clock moved backwards!");
            }
        }
        
        if (timestamp == lastTimestamp) {
            sequence = (sequence + 1) & ((1 << SEQUENCE_BITS) - 1);
            if (sequence == 0) {
                timestamp = tilNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;
        }
        
        lastTimestamp = timestamp;
        
        return ((timestamp - epoch) << (WORKER_ID_BITS + DATACENTER_ID_BITS + SEQUENCE_BITS))
            | (datacenterId << (WORKER_ID_BITS + SEQUENCE_BITS))
            | (workerId << SEQUENCE_BITS)
            | sequence;
    }
    
    private long tilNextMillis(long lastTimestamp) {
        long timestamp = System.currentTimeMillis();
        while (timestamp <= lastTimestamp) {
            timestamp = System.currentTimeMillis();
        }
        return timestamp;
    }
}
```

## 五、跨分片查询与全局表

### 5.1 跨分片查询的挑战

| 操作 | 问题 | 解决方案 |
|------|------|---------|
| ORDER BY | 需要全局排序 | 各分片查询后在内存中归并排序 |
| GROUP BY | 聚合计算跨分片 | 分布式聚合（两阶段聚合） |
| JOIN | 跨分片关联 | 尽量使用绑定表或宽表 |
| 分页 | offset 不准确 | 游标分页 / 禁止深翻页 |
| 事务 | 跨库事务 | 柔性事务（TCC/Saga） |

### 5.2 分布式分页

```sql
-- 普通分页（错误示范）
SELECT * FROM t_order ORDER BY id LIMIT 1000000, 20;
-- 各分片查询 100万+20 条后合并，性能极差

-- 游标分页（推荐）
SELECT * FROM t_order WHERE id > 1000000 ORDER BY id LIMIT 20;
-- 各分片只查 20 条，性能稳定

-- 分区键过滤分页
SELECT * FROM t_order 
WHERE user_id IN (1001, 1002, 1003)  -- 精确到分片
ORDER BY create_time DESC 
LIMIT 20;
```

### 5.3 全局表设计

对于不常改变的基础数据（字典、配置、行政区划等），在每个分库中都存一份完整的表：

```sql
-- 在每个分库中都执行
CREATE TABLE t_dict (
    dict_code VARCHAR(32) PRIMARY KEY,
    dict_name VARCHAR(128),
    dict_value TEXT,
    status TINYINT DEFAULT 1,
    create_time DATETIME
);
```

## 六、扩容方案

### 6.1 扩缩容选择

| 方案 | 数据迁移 | 停机时间 | 复杂度 | 适用场景 |
|------|---------|---------|--------|---------|
| 停机扩容 | 全量迁移 | 有停机 | 低 | 可停机维护 |
| 双写迁移 | 逐步迁移 | 无停机 | 高 | 7x24 服务 |
| 一致性 Hash | 部分迁移 | 无停机 | 中 | 弹性伸缩 |
| N 倍取模 | 翻倍扩容 | 有停机 | 中 | 成倍扩容 |

### 6.2 双写迁移方案

```
阶段1: 双写（老 + 新库）
  ┌───────────────────┐
  │  业务代码         │
  │  写入老表 + 新表   │
  └───────────────────┘

阶段2: 历史数据迁移
  ┌───────────────────┐
  │  定时任务           │
  │  将老数据写入新表   │
  │  检查数据一致性     │
  └───────────────────┘

阶段3: 切流到新表
  ┌───────────────────┐
  │  业务代码切到新表   │
  │  停止老表写入       │
  └───────────────────┘

阶段4: 清理
  ┌───────────────────┐
  │  确认无误后删除老表 │
  │  更新分片配置       │
  └───────────────────┘
```

## 七、八大避坑指南

| # | 问题 | 描述 | 解决方案 |
|---|------|------|---------|
| 1 | 分片键选择错误 | 选择了区分度低的字段 | 选 user_id / order_id 等高基数字段 |
| 2 | 跨分片事务 | 分布式事务性能差 | 尽量设计在同一分片、使用柔性事务 |
| 3 | 数据热点 | 某些分片数据远超其他 | 一致性 Hash + 虚拟节点 |
| 4 | 深翻页问题 | offset 越大越慢 | 游标分页替代 LIMIT OFFSET |
| 5 | 扩容困难 | 取模方式扩不动 | 初始预测最终容量、预先多分片 |
| 6 | 全局主键冲突 | 自增主键跨库冲突 | 雪花算法 / 分布式 ID 生成器 |
| 7 | 查询穿透 | 非分片键查询扫全库 | 建立索引表 / ES 旁路 |
| 8 | 数据一致性 | 分片间数据不一致 | 对账系统 + 补偿机制 |

### 非分片键查询方案

```java
// 建立索引表：user_id → order_id 的映射
// 这样通过 user_id 查询 order 时也很高效
@Service
public class OrderQueryService {
    
    public List<Order> queryByUserId(Long userId) {
        // 直接走分片键，命中指定数据库
        String ds = "ds" + (userId.hashCode() & 1);
        return orderMapper.selectByUserId(ds, userId);
    }
    
    public Order queryByOrderNo(String orderNo) {
        // 非分片键：先查索引表获取分片信息
        OrderIndex index = orderIndexMapper.selectByOrderNo(orderNo);
        // 再查具体分片
        return orderMapper.selectByOrderId(index.getOrderId());
    }
}
```

分库分表是解决海量数据存储的利器，但它也带来了额外的复杂度。**不是所有场景都需要分库分表**，在单表千万级以下时，先做好索引优化、SQL 优化和读写分离，往往能用更低的成本解决性能问题。只有在评估后确认单库单表确实到了瓶颈，才值得引入分库分表。
