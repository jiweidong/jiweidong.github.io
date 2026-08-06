---
title: 【MySQL 实战】MySQL 表设计最佳实践：字段类型选型、范式与反范式、索引设计规范
date: 2026-08-06 08:00:00
tags:
  - Java
  - MySQL
  - 数据库
  - 面试
categories:
  - Java
  - MySQL
author: 东哥
---

# 【MySQL 实战】MySQL 表设计最佳实践：字段类型选型、范式与反范式、索引设计规范

## 面试官：你做过数据库表设计吗？说一下你的设计规范？

「表设计」是后端开发的基本功，也是面试中**最容易暴露水平**的环节——很多人上来就聊索引优化，但一问字段类型为什么选 `varchar(255)`、为什么用 `bigint` 不用 `int`，就答不上来了。

表设计做得好，后续的查询优化、扩展、迁移都顺；设计得烂，上线就是灾难。本文从**字段类型选型 → 范式与反范式 → 索引设计 → 命名规范 → 实战案例**五层，系统梳理 MySQL 表设计的最佳实践。

---

## 一、字段类型选型：这是表设计的第一关

### 1. 整数类型怎么选？

| 类型 | 字节数 | 取值范围（有符号） | 适用场景 |
|------|--------|-------------------|---------|
| TINYINT | 1 | -128 ~ 127 | 状态码、开关（0/1）、枚举小值 |
| SMALLINT | 2 | -32768 ~ 32767 | 较小数值、端口号 |
| MEDIUMINT | 3 | -838万 ~ 838万 | 中量数值 |
| INT | 4 | -21亿 ~ 21亿 | 常规数值 |
| BIGINT | 8 | ±922亿亿 | **主键 ID、雪花 ID、订单号** |

**最佳实践**：

- **主键一律用 BIGINT**：自增 ID 或雪花 ID 都可能超过 INT 上限（21 亿），尤其分库分表后 ID 更大。用 `BIGINT UNSIGNED` 更保险。
- **能用小不用大**：`TINYINT` 存状态比 `INT` 省 3 字节，百万行就省 3MB，千万行就是 30MB——不要小看这一点。
- **不要用 INT(11) 这种写法**：MySQL 8.0 已废弃显示宽度，`INT(11)` 和 `INT` 存储完全一样，纯误导。

### 2. 小数类型：DECIMAL vs FLOAT/DOUBLE

| 类型 | 精度 | 适用场景 |
|------|------|---------|
| FLOAT/DOUBLE | 浮点，**有精度损失** | 科学计算、近似值（不推荐用于金额） |
| DECIMAL(M,D) | 定点，精确 | **金额、单价、费率等所有需要精确计算的场景** |

**最佳实践**：

- **金额一律 DECIMAL**（如 `DECIMAL(10,2)` 支持到 1 亿以内，`DECIMAL(18,2)` 一般够用）。浮点数 0.1+0.2 ≠ 0.3，存金额会出大事。
- **不要用 DOUBLE 存金额**，即使前端展示没问题，累加统计时精度误差会累积。
- 存储优化：金额可以放大为整数分（`BIGINT` 存分），节省空间且计算更快，但可读性差，团队要统一约定。

### 3. 字符串类型：CHAR vs VARCHAR vs TEXT

| 类型 | 特点 | 适用场景 |
|------|------|---------|
| CHAR(N) | 定长，空格填充，检索快 | 固定长度：手机号（11）、MD5（32）、UUID（32）、身份证（18） |
| VARCHAR(N) | 变长，额外 1~2 字节存长度 | 大部分字符串：名称、邮箱、地址 |
| TEXT | 大文本，存磁盘（溢出页） | 长文本、JSON 大字段（尽量少用） |

**最佳实践**：

- **VARCHAR 要合理定长**：`VARCHAR(255)` 是「万金油」但也是「偷懒」——越大，索引占用越大，内存排序临时表也越大。按业务实际最大长度 + 余量定（如名称 `VARCHAR(64)`，URL `VARCHAR(512)`）。
- **不要用 TEXT 存 JSON**：MySQL 5.7+ 有原生 JSON 类型，支持 `->` 提取、`JSON_EXTRACT`、虚拟列索引。
- **禁用 BLOB 存文件**：文件用对象存储（OSS/MinIO），数据库只存 URL。
- **字符集**：统一 `utf8mb4`（支持 emoji 和生僻字），排序规则一般用 `utf8mb4_unicode_ci` 或 `utf8mb4_general_ci`（性能略优）。

### 4. 日期时间：DATETIME vs TIMESTAMP

| 类型 | 存储 | 范围 | 时区 | 场景 |
|------|------|------|------|------|
| DATETIME | 8 字节 | 1000~9999 年 | 不随会话时区变化 | **通用推荐** |
| TIMESTAMP | 4 字节 | 1970~2038 年 | 跟随时区转换 | 有时区敏感的场景 |

**最佳实践**：

- **默认用 DATETIME**：2038 年问题让 TIMESTAMP 有硬伤，DATETIME 范围更大且不随时区变。
- **Java 8+ 用 LocalDateTime/LocalDate 映射**，避免 `java.util.Date` 的时区坑。
- 统一加 `create_time`、`update_time` 字段，`update_time` 用 `ON UPDATE CURRENT_TIMESTAMP` 自动维护：

```sql
CREATE TABLE t_user (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
```

- **不要用字符串存日期**：无法用日期函数索引优化，排序也是字典序（可能错乱），还浪费空间。

### 5. 其他类型

- **布尔值**：MySQL 没有真正的 BOOLEAN，用 `TINYINT(1)`（0/1）。
- **IP 地址**：用 `INT UNSIGNED`（`INET_ATON`/`INET_NTOA`）或 `VARCHAR(45)`（IPv6）。
- **枚举**：业务枚举建议用 `TINYINT` 存编码 + 代码层映射，避免 MySQL ENUM 类型扩展困难（改枚举要 ALTER TABLE）。

---

## 二、范式与反范式：设计的灵魂

### 三大范式回顾

| 范式 | 要求 | 反例 |
|------|------|------|
| 1NF | 字段不可再分（原子性） | 一个字段存「北京-朝阳区-xx路」 |
| 2NF | 非主键字段完全依赖主键（消除部分依赖） | 订单表里存「用户姓名」（只依赖用户ID，不依赖订单ID） |
| 3NF | 非主键字段不传递依赖主键（消除传递依赖） | 用户表里存「部门名称」（应存部门ID） |

### 范式的代价

范式消除了冗余，但带来**多表 JOIN**：

```sql
-- 3NF 设计：查订单要 JOIN 用户表
SELECT o.order_no, u.name 
FROM t_order o JOIN t_user u ON o.user_id = u.id 
WHERE o.id = 10086;
```

千万级订单表 JOIN 用户表，性能直线下降。所以生产环境往往**适度反范式**：

### 反范式的经典场景

| 场景 | 反范式做法 | 代价与对策 |
|------|-----------|-----------|
| 订单列表要展示用户名 | 订单表冗余 `user_name` 字段 | 用户改名时需同步更新（低频，可接受或用 MQ 异步修正） |
| 商品列表要展示销量 | 商品表冗余 `sale_count` | 用计数器表/Redis 异步累加，定期回写 |
| 统计报表 | 冗余汇总字段/预聚合表 | 容忍轻微延迟（准实时） |

**反范式原则**：**冗余「读多写少」的字段，且能容忍轻微不一致或可以异步修正**。核心业务字段（金额、状态）绝不冗余。

### 设计决策表

```text
数据一致性要求高、写入频繁  → 坚持范式（3NF），接受 JOIN
读多写少、查询是瓶颈         → 适度反范式（冗余展示字段）
超大表、复杂报表             → 分表 + 冗余宽表 + 汇总表
```

---

## 三、索引设计规范：表设计的另一半

### 1. 索引设计五条铁律

1. **主键用自增 BIGINT 或雪花 ID**：不要用 UUID 做主键——UUID 无序，B+ 树插入频繁页分裂，性能差且索引占用大。
2. **每个表都要有主键**：InnoDB 是聚簇索引表，没主键会隐式生成，浪费空间还不可控。
3. **为 WHERE、ORDER BY、GROUP BY、JOIN 的字段建索引**，而不是「所有字段都建」——索引不是越多越好，每个索引都要维护成本。
4. **联合索引遵循最左前缀原则**：`(a, b, c)` 索引能匹配 `a`、`a,b`、`a,b,c`，但**不能直接匹配 `b` 或 `c`**。把区分度高、查询最频繁的字段放最左。
5. **区分度低的字段不要单独建索引**：如性别（只有 0/1）、状态（只有几种值），索引选择性差，优化器可能放弃索引。

### 2. 常用索引设计模板

```sql
CREATE TABLE t_order (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
  order_no VARCHAR(32) NOT NULL COMMENT '订单号',
  user_id BIGINT UNSIGNED NOT NULL COMMENT '用户ID',
  status TINYINT NOT NULL DEFAULT 0 COMMENT '状态：0待支付 1已支付 2已取消',
  amount DECIMAL(18,2) NOT NULL COMMENT '金额',
  pay_time DATETIME DEFAULT NULL COMMENT '支付时间',
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_no (order_no),                    -- 唯一索引：订单号
  KEY idx_user_status (user_id, status),                -- 联合索引：用户维度查询
  KEY idx_create_time (create_time)                     -- 范围查询：按时间分页
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
```

### 3. 索引设计的坑

| 坑 | 说明 | 对策 |
|----|------|------|
| 隐式类型转换 | `WHERE order_no = 12345`（字符串字段传数字）导致索引失效 | 代码层保证类型一致 |
| 函数/运算 | `WHERE DATE(create_time) = '2026-08-06'` 索引失效 | 改为范围查询 `create_time >= '2026-08-06 00:00:00' AND create_time < '2026-08-07'` |
| 前导模糊 | `LIKE '%关键词%'` 无法用索引 | 用全文索引/ES，或只做后缀模糊 `LIKE '关键词%'` |
| 冗余索引 | 已有 `(a,b)` 又建 `(a)` | 用 `(a,b)` 前缀即可覆盖，删掉 `(a)` |
| 覆盖索引 | 查询字段都在索引中，避免回表 | 高频查询用覆盖索引（联合索引包含 SELECT 字段） |

---

## 四、命名规范与工程化细节

### 命名规范（团队统一）

- **表名**：小写 + 下划线，业务模块前缀：`t_user`、`t_order`、`t_order_item`；复数还是单数团队统一（国内常用单数）。
- **字段名**：小写 + 下划线：`user_id`、`create_time`；避免关键字（`order`、`group`、`desc` 要加前缀规避）。
- **索引名**：`uk_字段`（唯一）、`idx_字段`（普通）、`fk_字段`（外键）：`uk_order_no`、`idx_user_status`。
- **所有表加 COMMENT 注释**，字段也加 COMMENT，避免后人靠猜。

### 工程化细节

1. **NOT NULL 约束**：字段尽量 `NOT NULL` + 默认值。NULL 会占用额外空间（NULL 位图）、`COUNT` 会漏行、`IS NULL` 无法走普通索引。
2. **外键约束尽量不用**：互联网高并发场景禁用物理外键，用应用层保证关联（外键导致锁竞争、插入校验开销），这是行业共识。
3. **统一引擎 InnoDB**：支持事务、行级锁、崩溃恢复，MyISAM 已过时。
4. **预留字段不要乱加**：`remark1/remark2` 这种预留字段是坏味道，需求来了再 ALTER 也不难。
5. **大表拆分**：单表超过千万级/几十 GB，考虑垂直拆分（按业务字段）或水平拆分（按 ID/时间分片），配合分页优化（游标分页替代 LIMIT 深分页）。

---

## 五、实战：从需求到建表（完整案例）

**需求**：电商订单系统，需要支持「用户查询自己的订单列表（按状态筛选、按时间倒序分页）」。

```sql
CREATE TABLE t_order (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
  order_no VARCHAR(32) NOT NULL COMMENT '订单号（业务唯一）',
  user_id BIGINT UNSIGNED NOT NULL COMMENT '用户ID',
  shop_id BIGINT UNSIGNED NOT NULL COMMENT '店铺ID',
  status TINYINT NOT NULL DEFAULT 0 COMMENT '订单状态：0待支付 1已支付 2已发货 3已完成 4已取消 5售后中',
  total_amount DECIMAL(18,2) NOT NULL COMMENT '订单总金额',
  pay_amount DECIMAL(18,2) NOT NULL DEFAULT 0.00 COMMENT '实付金额',
  pay_time DATETIME DEFAULT NULL COMMENT '支付时间',
  receiver_name VARCHAR(64) NOT NULL COMMENT '收货人',
  receiver_phone VARCHAR(20) NOT NULL COMMENT '收货电话（冗余，订单快照）',
  receiver_address VARCHAR(255) NOT NULL COMMENT '收货地址（冗余，订单快照）',
  remark VARCHAR(255) DEFAULT '' COMMENT '订单备注',
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  update_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_user_status_ctime (user_id, status, create_time),
  KEY idx_shop_ctime (shop_id, create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';
```

**设计解读**：

- 订单号唯一索引：幂等/防重复下单。
- `idx_user_status_ctime` 联合索引：完美覆盖「用户 + 状态筛选 + 时间排序」的查询（最左前缀：`user_id` → `user_id,status` → `user_id,status,create_time`）。
- 收货人信息冗余（快照）：订单生成后地址变了不影响历史订单，这是**有意的反范式**。
- 金额用 DECIMAL，状态用 TINYINT，时间用 DATETIME——每一条都落在本文的规范上。

---

## 面试追问清单

1. **VARCHAR(255) 和 VARCHAR(64) 有区别吗？** → 存储上按实际长度占空间，但索引占用、排序临时表、`ROW_FORMAT` 都可能受最大长度影响；超长还会导致「索引前缀超 3072 字节」问题。
2. **为什么金额用 DECIMAL 不用 DOUBLE？** → 浮点精度误差，累加会放大；DECIMAL 是定点精确。
3. **范式化和反范式化怎么权衡？** → 一致性 vs 性能；读多写少、查询瓶颈时反范式冗余展示字段，核心金额/状态不冗余。
4. **主键为什么不用 UUID？** → 无序导致 B+ 树页分裂、随机 IO；UUID 是字符串索引占用大；自增/雪花 ID 有序性好。
5. **什么时候需要分表？** → 单表数据量过大（千万级+）、写并发过高、单表索引膨胀；先优化再分表，分表是最后手段。

**一句话总结**：表设计 = 选对字段类型（省空间、保精度）+ 平衡范式与反范式（一致性 vs 性能）+ 按查询设计索引（最左前缀、覆盖索引）+ 统一命名规范（可维护性）。把这张「设计清单」背熟，任何表设计需求都能从容应对。
