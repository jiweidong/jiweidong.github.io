---
title: 【MySQL 优化】唯一索引与 Duplicate Key 深度解析：INSERT IGNORE、ON DUPLICATE KEY UPDATE 与并发冲突治理
date: 2026-10-11 08:45:00
tags:
  - MySQL
  - 索引
  - 并发
  - 数据库
categories:
  - MySQL
  - 数据库
author: 东哥
---

# 【MySQL 优化】唯一索引与 Duplicate Key 深度解析：INSERT IGNORE、ON DUPLICATE KEY UPDATE 与并发冲突治理

## 面试官：怎么保证用户名不重复？

最直接的回答是"给 username 加唯一索引"，这句话只值 20 分。面试官接着会问：

- 加了唯一索引，并发注册两条同名怎么处理？
- `INSERT IGNORE`、`ON DUPLICATE KEY UPDATE`、`REPLACE INTO` 有什么区别？
- 唯一索引冲突时，为什么有时候会**死锁**？
- 逻辑删除和唯一索引为什么会打架？

这四个问题，才是这道题从 20 分到 90 分的分水岭。本文一次性讲透。

---

## 一、唯一索引的底层：唯一性是怎么被保证的

InnoDB 中，**唯一索引也是 B+ 树**，区别在于插入时多了一步**唯一性校验**：

1. 先在索引树中定位到待插入位置；
2. 检查该位置（以及相邻记录）是否存在相同键值；
3. 不存在 → 插入；存在 → 报 `ERROR 1062 (23000): Duplicate entry`。

关键点：**唯一性检查是在"加锁后、插入前"完成的**，这决定了并发行为。

### 1.1 二级唯一索引 vs 主键

- **主键**：唯一性由聚集索引天然保证，冲突直接报错；
- **二级唯一索引**：插入前需要**在二级索引上加锁**做校验，这是死锁的重要来源。

```sql
CREATE TABLE `t_user` (
  `id`          BIGINT       NOT NULL AUTO_INCREMENT,
  `username`    VARCHAR(64)  NOT NULL,
  `phone`       VARCHAR(20)  NOT NULL,
  `status`      TINYINT      NOT NULL DEFAULT 1,
  `create_time` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_username` (`username`),
  UNIQUE KEY `uk_phone` (`phone`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 二、三种"冲突处理"语法的本质区别

### 2.1 INSERT IGNORE

```sql
INSERT IGNORE INTO t_user (username, phone) VALUES ('tom', '13800000001');
```

- 冲突时**返回 warning，不报错**，返回影响行数 0；
- **危险点**：它忽略的**不只是重复键错误**！数据超长、类型转换失败、NOT NULL 约束等都会被"吞掉"。

```sql
-- 下面这条会被 IGNORE 悄悄截断成 'abc' 或插入空串，不报错！
INSERT IGNORE INTO t_user (username, phone) VALUES ('abc超长超长超长...', '13800000001');
```

**结论**：`INSERT IGNORE` 适合"我不关心这条数据是否真正写入"的幂等初始化场景，**绝不适合需要感知失败的注册流程**。

### 2.2 REPLACE INTO

```sql
REPLACE INTO t_user (id, username, phone) VALUES (1, 'tom', '13800000001');
```

**很多人以为它是"更新"，其实它是"DELETE + INSERT"**：

1. 尝试插入；
2. 若主键或唯一索引冲突 → **先删除冲突行**，再插入新行。

**两个致命后果**：

- **`id` 变了**：自增主键被删除重建，新 id 变大，之前的外键/引用全部指向"幽灵行"；
- **触发器与级联**：`DELETE` 会触发表上的 `ON DELETE CASCADE` 和删除触发器，把不该删的数据连带干掉；
- **变更审计失效**：审计里看到的是"删一条 + 加一条"，不是"改一条"。

**结论**：`REPLACE INTO` 在生产业务里基本应该禁用，只在"整行覆盖、无外键、无审计"的字典表场景才勉强可用。

### 2.3 INSERT ... ON DUPLICATE KEY UPDATE（推荐）

```sql
INSERT INTO t_user (username, phone, login_count)
VALUES ('tom', '13800000001', 1)
ON DUPLICATE KEY UPDATE
    login_count = login_count + 1,
    phone       = VALUES(phone);
```

- 冲突时执行 `UPDATE`，**不删除原行**，主键不变；
- **返回影响行数有讲究**：插入 1、更新 2、未变化 0。用 `MyBatis` 判断时要小心：

```java
// 影响行数为 1 表示插入，2 表示更新，0 表示键存在但值没变
int affected = userMapper.upsert(user);
```

> 注意 `VALUES(col)` 语法在 MySQL 8.0.20+ 已**废弃**，推荐用别名形式：
> ```sql
> INSERT INTO t_user (username, phone) VALUES ('tom','13800000001') AS new
> ON DUPLICATE KEY UPDATE phone = new.phone;
> ```

---

## 三、三种方案对比表

| 特性 | INSERT IGNORE | REPLACE INTO | ON DUPLICATE KEY UPDATE |
| --- | --- | --- | --- |
| 冲突行为 | 静默跳过 | **删除 + 插入** | 执行 UPDATE |
| 主键是否变化 | 不变 | **会变** | 不变 |
| 触发 DELETE 触发器 | 否 | **是** | 否 |
| 可能触发级联删除 | 否 | **是** | 否 |
| 吞掉其他错误 | **是** | 否 | 否 |
| 适用场景 | 初始化幂等 | 基本不用 | 幂等写入 / 计数累加 |

---

## 四、并发冲突：你怎么判断"我是插入还是被冲突了"

唯一索引能保证数据不重复，但**业务上你依然需要知道"这次到底是新建成功，还是撞了已有记录"**。

### 4.1 朴素方案：先查后插（有竞态）

```java
// ❌ 典型 TOCTOU 竞态：两个线程同时查到不存在，然后都插入
User existing = mapper.selectByUsername(username);
if (existing != null) throw new BizException("用户名已存在");
mapper.insert(user);
```

在并发下必然出现：① 一个成功一个 1062 异常；② 更糟的是没加唯一索引时直接双写成功。

### 4.2 正确姿势一：捕获唯一键异常

```java
try {
    mapper.insert(user);
    return Result.created();
} catch (DuplicateKeyException e) {
    // Spring 会把 1062 翻译成 DuplicateKeyException
    throw new BizException("用户名已存在");
}
```

**提前判断 + 兜底捕获**才是最稳的：

```java
if (mapper.existsByUsername(username)) {
    throw new BizException("用户名已存在");
}
try {
    mapper.insert(user);
} catch (DuplicateKeyException e) {
    // 并发兜底：说明在 exists 与 insert 之间被别人抢了
    throw new BizException("用户名已存在");
}
```

**关键**：判断"是否 DuplicateKey"要**看唯一索引名**，而不是笼统 catch。一张表多个唯一索引时，需要解析错误信息：

```java
private String extractDuplicateKey(DataIntegrityViolationException e) {
    String msg = e.getMostSpecificCause().getMessage();
    // Duplicate entry 'tom' for key 't_user.uk_username'
    Matcher m = Pattern.compile("for key '([^']+)'").matcher(msg);
    return m.find() ? m.group(1) : "";
}
```

### 4.3 正确姿势二：原子 UPSERT

注册/登录统计、库存计数这类场景，用一条 `ON DUPLICATE KEY UPDATE` 原子完成，**不查不判断**：

```sql
INSERT INTO t_user_stat (user_id, login_count, last_login)
VALUES (#{userId}, 1, NOW())
ON DUPLICATE KEY UPDATE
    login_count = login_count + 1,
    last_login  = NOW();
```

一条 SQL 搞定"存在则累加，不存在则创建"，无竞态、无死锁风险（单行冲突）。

---

## 五、唯一索引与逻辑删除的经典冲突

业务常用 `is_deleted` 做逻辑删除：

```sql
CREATE TABLE t_user (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(64) NOT NULL,
    is_deleted TINYINT NOT NULL DEFAULT 0,
    UNIQUE KEY uk_username (username)
);
```

**问题**：删除用户 `tom` 后想重新注册 `tom`，会撞唯一索引——因为旧行还在，只是 `is_deleted = 1`。

### 方案一：唯一索引带上删除标记（不推荐）

```sql
UNIQUE KEY uk_username (username, is_deleted)
```

**坑**：删两次就冲突了（两条 `is_deleted = 1` 的 `tom`）。除非把删除标记设计成"删除时间戳"：

```sql
is_deleted BIGINT NOT NULL DEFAULT 0   -- 0 表示未删除；删除时写入 id 或时间戳
UNIQUE KEY uk_username (username, is_deleted)
```

这样未删除的行 `is_deleted` 恒为 0 → 唯一性生效；已删除的行值各不相同 → 不冲突。**这是最实用的方案**，但要注意查询时 `is_deleted = 0` 要用到索引最左前缀。

### 方案二：物理删除 + 归档表

业务表只保留活跃数据，删除即物理删除，历史进归档表。**最干净**，但业务改造成本高。

### 方案三：软删除字段 + 生成列

```sql
deleted_at DATETIME NULL,
active_flag VARCHAR(64) GENERATED ALWAYS AS (
    IF(deleted_at IS NULL, username, NULL)
) STORED,
UNIQUE KEY uk_active_username (active_flag)
```

**原理**：未删除时 `active_flag = username`（唯一）；已删除时 `active_flag = NULL`，而**唯一索引允许多个 NULL**，天然不冲突。**这是最优雅的方案**，代价是多一个生成列。

---

## 六、唯一索引引发的死锁：真实案例

这是最能体现深度的一题。

### 6.1 场景

两个事务并发插入不同但"相邻"的唯一键：

```
T1: INSERT INTO t_user(username) VALUES ('C');
T2: INSERT INTO t_user(username) VALUES ('D');
```

若 C、D 在索引树中相邻，加锁过程可能形成**互相等待**：

```
T1 持有 C 的间隙锁，等待 D；
T2 持有 D 的间隙锁，等待 C；
→ Deadlock found when trying to get lock
```

### 6.2 为什么唯一索引插入会加间隙锁？

InnoDB 在唯一索引插入时，虽然唯一性检查理论上只需加**记录锁**，但为了保证"插入位置"的稳定性与可重复读语义，在**冲突检测失败**或**间隙扫描**时仍会加 `Next-Key Lock`。当多个事务插入的键位于同一间隙时，就可能出现死锁。

### 6.3 治理手段

1. **批量导入时对唯一键排序**：让所有事务按同一顺序加锁，破除循环等待（最有效）；
2. **控制事务长度**：插入后尽快提交，缩短持锁时间；
3. **捕获死锁自动重试**：

```java
@Retryable(
    retryFor = {DeadlockLoserDataAccessException.class, CannotAcquireLockException.class},
    maxAttempts = 3,
    backoff = @Backoff(delay = 50, multiplier = 2))
public void insertBatch(List<User> users) {
    mapper.insertBatch(users);
}
```

4. **降低隔离级别到 RC**：RC 下间隙锁大幅减少（但仍非零），配合业务幂等可显著降低死锁；
5. **`innodb_autoinc_lock_mode`**：批量插入自增锁也会加剧冲突，注意设置。

---

## 七、面试高频追问

**追问一：唯一索引和普通索引的查询性能差多少？**

差别极小。两者都是 B+ 树，**等值查询路径几乎一样**；唯一索引甚至可能更快一点点，因为找到匹配即可停止（不需要看下一条），而普通索引需要再读一条判断"是否还有下一个"。**不要为了性能差异决定是否加唯一索引，应该按业务约束决定。**

**追问二：唯一索引冲突时，走的是唯一索引还是主键索引？**

看冲突键。冲突检测发生在**对应索引树上**；如果多个唯一索引都冲突，报第一个检测到的。

**追问三：`INSERT IGNORE` 和 `ON DUPLICATE KEY UPDATE` 谁更快？**

同等条件下差距不大，但 `IGNORE` 冲突时不做任何写入；`ON DUPLICATE` 冲突时要执行 UPDATE。批量场景下 `ON DUPLICATE` 的 UPDATE 会带来额外 binlog 与 undo，**写放大更明显**。选型看语义，不是看速度。

**追问四：怎么给一张已有重复数据的大表加唯一索引？**

直接 `ALTER TABLE ADD UNIQUE` 会失败。步骤：① 找出重复数据并清理/合并；② 用 `pt-online-schema-change` 或 `gh-ost` 在线加索引，避免锁表；③ 加完后校验。**注意 DDL 期间的写入**：工具会创建触发器同步增量，要评估触发器带来的性能损耗。

**追问五：唯一索引能不能为 NULL？**

**可以，且可以有多行 NULL**。因为 SQL 标准里 `NULL != NULL`。这正是前面"生成列方案"能成立的原因。但要注意：如果是**联合唯一索引**，只要其中一列为 NULL，唯一约束可能不生效（取决于各列组合）。

---

## 八、最佳实践清单

1. **业务唯一性约束一定用唯一索引落地**，不要只靠应用层 `exists` 判断——应用层判断永远有竞态；
2. **注册/创建类接口**用"提前 exists + DuplicateKeyException 兜底"双保险，并**解析冲突的具体索引名**返回精准提示；
3. **计数、状态更新类接口**优先用 `ON DUPLICATE KEY UPDATE` 做原子 UPSERT；
4. **慎用 `REPLACE INTO`**：它删除重建，破坏主键、审计、外键；
5. **慎用 `INSERT IGNORE`**：它会吞掉其他错误；
6. **逻辑删除 + 唯一索引**优先用"生成列置 NULL"或"删除时间戳入索引"方案；
7. **批量插入前排序**，降低唯一索引死锁概率，并加死锁自动重试；
8. **DDL 加唯一索引**用 `gh-ost` / `pt-osc`，提前清理重复数据。

---

## 总结

一道"怎么保证用户名不重复"的题，背后是：**唯一索引的加锁机制 → 三种冲突语法的语义差异 → 并发竞态与异常兜底 → 逻辑删除与唯一约束的设计博弈 → 间隙锁死锁治理**。

记住三句话：

- **唯一索引是数据一致性的最后防线**，应用层判断只是优化体验的前置检查；
- **`ON DUPLICATE KEY UPDATE` 是幂等写入的首选**，`REPLACE` 和 `IGNORE` 都有隐性代价；
- **逻辑删除与唯一索引的冲突**，用"生成列置 NULL"最优雅。

把这三句话讲出来，这道题就从"背过"变成"做过"了。
