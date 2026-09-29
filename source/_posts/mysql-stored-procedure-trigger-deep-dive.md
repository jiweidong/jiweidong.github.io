---
title: 【MySQL 进阶】存储过程与触发器深度解析：语法、游标、事件调度与生产取舍
date: 2026-09-29 08:00:00
tags:
  - MySQL
  - 数据库
  - 存储过程
categories:
  - MySQL
  - 数据库
author: 东哥
---

# 【MySQL 进阶】存储过程与触发器深度解析：语法、游标、事件调度与生产取舍

## 面试官：你们项目用存储过程吗？为什么？

这是一个「没有标准答案，但答错立刻掉分」的问题。

答「用啊，所有业务逻辑都写在存储过程里」——面试官会怀疑你的架构能力；
答「存储过程是落后技术，从来不用」——面试官会怀疑你没当过大流量系统的家。

真正得体的回答是：**分清场景**。存储过程适合「批量、离线、数据迁移、报表聚合」这类逻辑稳定、需要减少网络往返的场景；而在线事务型业务更适合放在应用层。这篇文章把 MySQL 的存储过程、函数、游标、触发器、事件调度器一次性讲透，并给出落地取舍。

## 一、存储过程基础语法

存储过程（Stored Procedure）是一组预编译并保存在服务端的 SQL 集合。核心语法：

```sql
DELIMITER $$

CREATE PROCEDURE p_transfer(
    IN  from_id BIGINT,
    IN  to_id   BIGINT,
    IN  amount  DECIMAL(18,2),
    OUT result  VARCHAR(64)
)
BEGIN
    -- 声明异常处理器：出错就回滚
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET result = 'FAILED';
    END;

    START TRANSACTION;
    UPDATE account SET balance = balance - amount WHERE id = from_id;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '付款账户不存在';
    END IF;
    UPDATE account SET balance = balance + amount WHERE id = to_id;
    COMMIT;
    SET result = 'SUCCESS';
END$$

DELIMITER ;

CALL p_transfer(1, 2, 100.00, @r);
SELECT @r;
```

几个必须搞清楚的语法点：

| 语法 | 作用 | 易错点 |
| --- | --- | --- |
| `DELIMITER` | 临时改语句结束符 | 只是客户端指令，不发给服务端 |
| `IN / OUT / INOUT` | 参数模式 | 默认 `IN`；`OUT` 必须传变量 |
| `DECLARE` | 声明变量/条件/游标/处理器 | 必须在 `BEGIN` 最开始，顺序固定 |
| `HANDLER` | 异常处理 | `EXIT` 跳出、`CONTINUE` 继续 |
| `SIGNAL` | 主动抛错 | 生产里比 `SELECT 'error'` 靠谱得多 |

**关于 `DECLARE` 顺序**：MySQL 要求声明顺序是「变量 → 条件 → 游标 → 处理器」，顺序颠倒直接 `Syntax error`。这是新手最常卡住的地方。

**关于 `SIGNAL` 与 `RESIGNAL`**：`SIGNAL` 抛新错误，`RESIGNAL` 在原处理器里把错误原样重抛。写通用错误处理时很关键：

```sql
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    ROLLBACK;
    RESIGNAL;  -- 把真实错误码抛给调用方，方便上层定位
END;
```

## 二、存储函数与「确定性」

函数（FUNCTION）必须返回一个值，且常被用在 SQL 表达式里：

```sql
CREATE FUNCTION f_order_level(total DECIMAL(18,2))
RETURNS VARCHAR(16)
DETERMINISTIC
READS SQL DATA
BEGIN
    RETURN CASE
        WHEN total >= 10000 THEN '钻石'
        WHEN total >= 3000  THEN '黄金'
        WHEN total >= 500   THEN '白银'
        ELSE '普通'
    END;
END;
```

关键约束与坑：

1. **`DETERMINISTIC` / `NO SQL` / `READS SQL DATA` 必须显式声明**，否则在开启了 `binlog_format=STATEMENT` 且 `log_bin_trust_function_creators=OFF` 时创建失败。
2. **在 `GROUP BY`、`WHERE` 中调用函数会导致索引失效**——优化器没有函数索引（MySQL 8.0.13 才有 functional index），整表扫描是常态。这是「用函数一时爽，慢查询火葬场」的典型。
3. **函数里不能返回结果集**，也不能显式 `COMMIT`。

## 三、游标与循环：批处理的核心

游标（Cursor）用于逐行处理结果集，是批处理的标配。

```sql
DELIMITER $$
CREATE PROCEDURE p_batch_upgrade()
BEGIN
    DECLARE v_id BIGINT;
    DECLARE v_done INT DEFAULT 0;

    DECLARE cur CURSOR FOR
        SELECT id FROM orders WHERE status = 'PAID' AND created_at < NOW() - INTERVAL 30 DAY;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id;
        IF v_done = 1 THEN
            LEAVE read_loop;
        END IF;

        UPDATE orders SET status = 'ARCHIVED' WHERE id = v_id;
        -- 每 1000 行提交一次，避免大事务
        SET @cnt = @cnt + 1;
        IF @cnt % 1000 = 0 THEN
            COMMIT;
            START TRANSACTION;
        END IF;
    END LOOP;
    CLOSE cur;
    COMMIT;
END$$
DELIMITER ;
```

**游标的三条铁律**：

1. `NOT FOUND` 处理器必须存在，否则 `FETCH` 越界会直接报错；
2. `OPEN / FETCH / CLOSE` 必须配对，异常路径上也要保证关闭；
3. **游标是逐行的，性能远低于集合运算**——能写成一条 `UPDATE ... WHERE` 就绝不用游标。游标只适合「每行逻辑不同」的场景。

> 关于批次提交：把一个大事务拆成小事务能降低 undo 膨胀和主从延迟，但会牺牲原子性。**如果业务要求整体成功或整体失败，不要分段提交**，改用 `--single-transaction` 式的思路或异步化。

## 四、触发器：能不用就不用

触发器（Trigger）在 `INSERT/UPDATE/DELETE` 前后自动执行。语法：

```sql
CREATE TRIGGER trg_order_after_insert
AFTER INSERT ON orders
FOR EACH ROW
BEGIN
    INSERT INTO order_audit(order_id, action, created_at)
    VALUES (NEW.id, 'INSERT', NOW());
END;
```

`NEW` 表示新行、`OLD` 表示旧行（`INSERT` 只有 `NEW`，`DELETE` 只有 `OLD`）。`BEFORE` 触发器还能改 `NEW.xxx` 实现字段赋值。

**触发器在生产里的四大罪状**：

| 问题 | 具体表现 |
| --- | --- |
| 隐式执行 | 业务代码里看不到，审计困难，「谁把数据改了」查不出来 |
| 级联放大 | 一个触发器再触发另一个表的触发器，写放大与死锁风险成倍上升 |
| 无法回滚外部动作 | 触发器里调外部系统（UDF）无法参与事务 |
| 复制隐患 | 基于行的复制虽然安全，但触发器逻辑若含 `NOW()`、`RAND()` 仍会导致主从不一致 |

更致命的组合是「触发器 + 唯一索引冲突」：触发器里插入辅助表，如果辅助表有唯一键，主表这条 DML 会因为辅助表的冲突而失败，报错信息还指向主表，排查成本极高。

**结论**：审计、软删除、字段审计这类需求，用应用层 AOP 或 CDC（Canal/Debezium 订阅 binlog）替代触发器。只有在「无法改应用代码」的遗留系统里才考虑触发器。

## 五、事件调度器（Event Scheduler）

MySQL 内置定时任务，可以理解为「数据库自带的 crontab」：

```sql
-- 确认调度器已开启
SHOW VARIABLES LIKE 'event_scheduler';

-- 临时开启
SET GLOBAL event_scheduler = ON;

-- 每 5 分钟清理一次过期数据
CREATE EVENT IF NOT EXISTS e_clean_expired
ON SCHEDULE EVERY 5 MINUTE
STARTS CURRENT_TIMESTAMP + INTERVAL 1 MINUTE
ON COMPLETION PRESERVE
DO
BEGIN
    DELETE FROM login_token WHERE expire_at < NOW() LIMIT 10000;
END;
```

注意点：

- `event_scheduler` 默认关闭，且**必须写进配置文件**（`my.cnf`），否则重启失效；
- 事件属于某个 schema，不随应用迁移自动同步；
- **主从架构下事件只会在主库执行**，从库上创建的事件不会重复跑，但也意味着故障切换后要确认事件状态；
- 事件里执行 DDL 会拿 MDL 锁，可能阻塞业务。清理类任务用 `LIMIT` 分批，避免长事务。

## 六、性能与可观测性

存储过程性能好在哪里、差在哪里，要讲得清：

**优势**：

- 减少网络往返（一次 `CALL` 跑完 N 条语句），跨机房场景提升明显；
- SQL 在服务端缓存执行计划（受 `plan_cache` 与版本影响）；
- 批量数据处理时省去应用层对象映射开销。

**劣势**：

- **不可控的长时间持有锁**：一个存储过程一个大事务，锁等待可能拖垮线上；
- **性能分析困难**：`performance_schema` 里存储过程有独立的事件嵌套，`EXPLAIN` 也拿不到中间语句的执行情况，只能靠 `SHOW PROFILE`（已废弃）或慢日志按内部语句统计；
- **业务逻辑分散**：版本管理、Code Review、单元测试都很难做；
- **迁移成本**：换数据库（Oracle→MySQL、MySQL→PG）几乎等于重写。

排查存储过程问题时的实用手段：

```sql
-- 当前正在执行的语句（含由存储过程调用的内部语句）
SELECT * FROM performance_schema.events_statements_current
WHERE SQL_TEXT LIKE '%CALL%' LIMIT 10;

-- 看锁等待
SELECT * FROM performance_schema.data_lock_waits;

-- 慢日志里存储过程内部语句也会被记录（取决于 log_slow_sp_statements）
SHOW VARIABLES LIKE 'log_slow_sp_statements';
```

`log_slow_sp_statements=ON` 是排查存储过程慢查询的关键开关——**默认不记录内部语句**，很多人因此误以为「存储过程里的慢 SQL 抓不到」。

## 七、与应用层协作的正确姿势

存储过程要和框架配合，而不是对抗：

```java
// MyBatis 调用存储过程
@Select("{ CALL p_transfer(#{fromId}, #{toId}, #{amount}, #{result, mode=OUT, jdbcType=VARCHAR}) }")
@Options(statementType = StatementType.CALLABLE)
void transfer(@Param("fromId") Long fromId,
              @Param("toId") Long toId,
              @Param("amount") BigDecimal amount,
              @Param("result") Map<String, Object> result);
```

- **事务边界要明确**：如果 Spring 开了事务，又调用了内含 `COMMIT` 的存储过程，会破坏 Spring 的事务语义，甚至抛 `Transaction rolled back because it has been marked as rollback-only`。
- **不要在存储过程里再 `START TRANSACTION`**，交给应用层统一管理事务，除非这是纯批处理任务。
- **参数用 `DECIMAL` 不用 `DOUBLE`**：金额相关逻辑一旦进了 `DOUBLE`，精度问题会让你在财务对账时哭出来。

## 八、面试追问速答

**Q：存储过程和函数的核心区别？**
函数必须有返回值、可出现在 SQL 表达式里、不能返回结果集、限制更多；过程可以返回多个结果集、有 `IN/OUT` 参数、更灵活。

**Q：`IN` 参数是值传递还是引用传递？**
`IN` 是值传递，过程内修改不影响调用方；`INOUT` 才是双向。

**Q：触发器能回滚主语句吗？**
能。触发器里 `SIGNAL` 抛错或执行失败会让主语句一起回滚（同一事务）。但触发器里若有 `COMMIT` 则会破坏事务——MySQL 也不允许触发器里提交。

**Q：存储过程能返回结果集给 Java 吗？**
可以，使用 `SELECT` 产生结果集，MyBatis 里配 `resultSets` 或用 `CallableStatement.getMoreResults()` 逐段取。

**Q：什么情况下你会坚决用存储过程？**
数据迁移/清洗（TB 级）、离线报表聚合、批量对账，且逻辑稳定、不需要频繁迭代。核心判断标准是「数据量大 + 逻辑稳定 + 无需单元测试」。

**Q：DDL 能在存储过程里做吗？**
能用动态 SQL（`PREPARE ... EXECUTE`）做，但会拿 MDL 锁，且不受事务保护，生产慎用。

## 九、小结

存储过程与触发器不是「落后」，而是**把复杂度挪了一个位置**：挪到数据库服务端，换取网络往返的减少和批处理效率，代价是运维、测试、迁移成本的上升。

一句话总结取舍：**离线批量用存储过程，在线事务放应用层，审计类需求交给 CDC，定时清理优先用调度平台（XXL-Job）而不是 MySQL Event。**
