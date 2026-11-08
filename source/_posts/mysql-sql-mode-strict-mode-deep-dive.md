---
title: 【MySQL 深挖】sql_mode 与严格模式深度解析：从静默截断到 ONLY_FULL_GROUP_BY 的迁移血泪
date: 2026-11-08 08:00:00
tags:
  - MySQL
  - 数据库
  - 数据一致性
  - 面试
categories:
  - MySQL
author: 东哥
---

# 【MySQL 深挖】sql_mode 与严格模式深度解析：从静默截断到 ONLY_FULL_GROUP_BY 的迁移血泪

## 前言

两个真实事故，一个"太安静"，一个"太吵"。

**事故一（静默截断）**：某电商的订单表 `receiver_phone VARCHAR(11)`，上游改成支持国际号码后传入了 13 位。数据库没有报错，只有一条 warning。三个月后对账发现，几千条订单的手机号被截成了 11 位——**用户收不到验证码，但系统一切正常**。

**事故二（迁移报错）**：从 MySQL 5.6 迁到 8.0，一条统计 SQL 突然报：

```
ERROR 1055 (42000): Expression #3 of SELECT list is not in GROUP BY clause
and contains nonaggregated column 'db.t.status' which is not functionally
dependent on columns in GROUP BY clause; this is incompatible with
sql_mode=only_full_group_by
```

这条 SQL 在 5.6 上跑了六年，从没出过问题。

两个事故的共同开关都是 `sql_mode`。它默认存在、极少有人主动看，却直接决定**你的数据库是"宽容地存错数据"还是"严格地拒绝你"**。这篇把它拆清楚。

---

## 一、sql_mode 是什么

一句话：**一组控制 SQL 语法校验与数据校验行为的标志位**，可以在全局、会话、甚至单条语句上设置。

```sql
-- 当前会话
SELECT @@SESSION.sql_mode;
-- 全局
SELECT @@GLOBAL.sql_mode;
-- 设置（只影响当前会话）
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
```

它影响的东西比大多数人以为的多：

| 类别 | 代表选项 | 影响 |
|---|---|---|
| **严格性** | `STRICT_TRANS_TABLES`、`STRICT_ALL_TABLES` | 非法数据是报错还是警告+截断 |
| **分组语法** | `ONLY_FULL_GROUP_BY` | `GROUP BY` 里能不能出现非聚合、非函数依赖的列 |
| **日期校验** | `NO_ZERO_DATE`、`NO_ZERO_IN_DATE` | 是否允许 `'0000-00-00'`、`'2026-00-15'` |
| **除零** | `ERROR_FOR_DIVISION_BY_ZERO` | `1/0` 是 NULL 还是报错 |
| **引擎选择** | `NO_ENGINE_SUBSTITUTION` | 指定引擎不存在时是报错还是静默替换成默认引擎 |
| **密码/用户** | `NO_AUTO_CREATE_USER`（8.0 已移除） | `GRANT` 时是否自动建用户 |
| **转义** | `NO_BACKSLASH_ESCAPES` | 反斜杠是否作为转义符 |

---

## 二、默认值的演进：为什么"升级"等于"收紧"

| 版本 | 默认 sql_mode（节选） | 关键变化 |
|---|---|---|
| 5.6 | 空（严格模式关闭） | 超长截断、非法日期写入零值，只有 warning |
| 5.7 | `ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION` | **5.7.5 起 `ONLY_FULL_GROUP_BY` 默认开启**，大量老 SQL 开始报 1055 |
| 8.0 | 去掉 `NO_AUTO_CREATE_USER`（该选项被移除），其余保留 | 升级 5.6→8.0 相当于一次性打开所有严格校验 |
| 8.4 / 9.x | 延续 8.0 的严格基调 | `NO_ZERO_DATE` 等已被标记为废弃，未来会彻底移除 |

⚠️ 关键认知：**从 5.6 直接升到 8.x，是一次"跨两代"的严格性跃迁**。很多人把升级当成"换个二进制包"，实际上你同时打开了：

1. `STRICT_TRANS_TABLES`（数据不再被静默截断，改为报错）
2. `ONLY_FULL_GROUP_BY`（一类 SQL 直接语法不合法）
3. `NO_ZERO_DATE` / `NO_ZERO_IN_DATE`（历史脏数据无法再写入）
4. `ERROR_FOR_DIVISION_BY_ZERO`（报表 SQL 里的 `x/0` 报错）

---

## 三、严格 vs 非严格：五类行为的差异

这是本文最该背下来的一张表。

| 场景 | 非严格模式（`sql_mode=''`） | 严格模式（`STRICT_TRANS_TABLES`） |
|---|---|---|
| `VARCHAR(11)` 插入 13 字符 | **截断**为 11 字符 + warning | `ERROR 1406: Data too long for column` |
| `TINYINT` 插入 300 | **截断**为 127 + warning | `ERROR 1264: Out of range value` |
| `NOT NULL` 列插入 NULL（无默认值） | 隐式填 `0` / `''` / 零日期 + warning | `ERROR 1048: Column cannot be null` |
| 插入 `'0000-00-00'` | 允许（若未开 `NO_ZERO_DATE`） | `ERROR 1292: Incorrect date value` |
| `INSERT ... SELECT` 中途失败 | **部分行已插入**，留下半截数据 | 语句回滚（事务表） |

注意最后一行：`STRICT_ALL_TABLES` 与 `STRICT_TRANS_TABLES` 的区别在于**非事务表（MyISAM）**——前者对非事务表也严格，但会留下"前 N 行已插入"的半截状态。**所以工程上永远用 `STRICT_TRANS_TABLES`，不要用 `STRICT_ALL_TABLES`。**

最危险的不是报错，是**warning 被忽略**。Java 侧 JDBC 默认会把 warning 吞掉：

```java
// 这段代码在非严格模式下"成功"了，但数据已经错了
jdbcTemplate.update("INSERT INTO orders(receiver_phone) VALUES (?)", "8613800138000");
// 没有任何异常，数据库里存的是 "86138001380"
```

**静默截断比报错可怕 100 倍**：报错会立刻被发现，截断会安静地陪你三个月，直到对账出问题。

---

## 四、`ONLY_FULL_GROUP_BY`：不是找麻烦，是在救你

### 4.1 它到底禁了什么

```sql
-- ❌ 1055：status 既不在 GROUP BY 里，也不是聚合函数
SELECT user_id, status, COUNT(*) FROM orders GROUP BY user_id;

-- ✅ 函数依赖：user_id 是主键，status 由它唯一决定（8.0 能识别）
SELECT user_id, status, COUNT(*) FROM orders GROUP BY user_id;
```

MySQL 8.0 的 `ONLY_FULL_GROUP_BY` 会检查**函数依赖**：如果 `GROUP BY` 的列是主键/唯一键，那么同表其他列被它函数决定，可以出现在 SELECT 里。这是 5.7 之后才有的能力，很多"5.7 也报错"的 SQL 其实在 8.0 反而能跑。

### 4.2 为什么非严格模式下这是"随机结果"

```sql
SELECT user_id, status, COUNT(*) FROM orders GROUP BY user_id;
```

`user_id=42` 有 5 条订单，状态分别是 PAID/PAID/REFUND/PAID/CLOSED。数据库返回哪个 `status`？

**答案：不确定。** 取决于执行计划——走索引可能是索引里第一条，走全表可能是最后一条，换一个索引或换一个版本，结果就变了。这不是"宽容"，这是**在给你一个看起来合理、实际随机的数字**，然后你把它放进了报表和告警。

### 4.3 三种正确改法

```sql
-- 方案 A：用聚合函数明确表达意图（最推荐，语义清晰）
SELECT user_id, MAX(status) AS last_status, COUNT(*) FROM orders GROUP BY user_id;

-- 方案 B：用 ANY_VALUE 显式声明"我不在乎取哪个"（适合确实任意的场景）
SELECT user_id, ANY_VALUE(status), COUNT(*) FROM orders GROUP BY user_id;

-- 方案 C：先聚合再关联（需要"最新一条"这类语义时，用窗口函数最准确）
SELECT o.user_id, o.status, c.cnt
FROM orders o
JOIN (SELECT user_id, COUNT(*) cnt FROM orders GROUP BY user_id) c USING (user_id)
WHERE o.id = (SELECT id FROM orders o2 WHERE o2.user_id = o.user_id
              ORDER BY created_at DESC LIMIT 1);
```

❌ **绝对不要**用 `SET SESSION sql_mode = ''` 或 `SET sql_mode = REPLACE(@@sql_mode,'ONLY_FULL_GROUP_BY','')` 来"解决"。这等于把所有严格校验一起关掉，用一行配置埋下十个坑。

---

## 五、5.6/5.7 → 8.x 迁移的五步法

### 第一步：把差异"抓"出来，别靠猜

```sql
-- 目标：找出在严格模式下会失败的语句。在从库/预发开严格模式跑全量回归
SET GLOBAL sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,
                       NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';
```

同时用 `performance_schema` 的语句摘要看哪些 SQL 开始报错（报错的语句会进 `events_errors_summary_by_thread_by_error`），或者直接看应用日志里的 1055/1406/1264/1292。

### 第二步：区分"代码问题"和"数据问题"

| 报错 | 分类 | 处理 |
|---|---|---|
| 1055（GROUP BY） | 代码 | 改 SQL，别改配置 |
| 1406（Data too long） | 代码或数据 | 先看是不是字段长度设计不足 |
| 1264（Out of range） | 数据 | 检查历史脏数据与上游类型 |
| 1292（Incorrect date） | 数据 | 清理 `0000-00-00`，加 `NO_ZERO_DATE` 前必须先清 |

### 第三步：用"影子写入"验证

在预发环境用**双写**：同时写一份到 8.0 严格模式库，比对结果集。差异就是迁移风险清单。这比"跑一遍回归测试"靠谱得多，因为回归测试覆盖不到长尾数据。

### 第四步：灰度与回滚预案

```sql
-- 会话级灰度：只对特定应用连接开严格模式（用 init_connect 或连接池的 connection-init-sql）
-- Java 侧 HikariCP：
-- connectionInitSql=SET SESSION sql_mode='STRICT_TRANS_TABLES,ONLY_FULL_GROUP_BY'
```

先让 1% 的流量走严格模式，观察 24 小时错误率，再放量。**回滚手段必须是"改回 sql_mode"，而不是"回滚数据库版本"**——后者在云上基本不可行。

### 第五步：把严格模式写进规范

| 环境 | sql_mode 建议 |
|---|---|
| 开发 | 与生产完全一致（这是最重要的一条） |
| 预发 | 与生产一致 + 开启额外告警 |
| 生产 | `STRICT_TRANS_TABLES,ONLY_FULL_GROUP_BY,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO` |

**开发环境用宽松模式是万恶之源**：本地能跑、预发能跑、生产报错，或者更糟——本地宽松、生产严格，测试永远测不出问题。

---

## 六、Java 侧的双保险

数据库的严格模式是最后一道防线，不是第一道。正确的分层是：

```
前端校验 → Bean Validation（@NotNull/@Size/@Pattern）→ 领域层校验 → 数据库约束（严格模式 + 类型 + 长度）
```

```java
public record OrderCreateCmd(
    @NotBlank(message = "手机号不能为空")
    @Pattern(regexp = "^1[3-9]\\d{9}$", message = "手机号格式不合法")
    String receiverPhone,

    @NotNull @DecimalMin("0.00") @Digits(integer = 10, fraction = 2)
    BigDecimal amount,

    @NotNull @Future
    LocalDateTime expectDeliveryAt
) {}
```

三个容易忽略的细节：

1. **`@Size` 要和 DDL 的 `VARCHAR(n)` 严格对齐**。代码里写 `@Size(max = 64)`、DDL 写 `VARCHAR(32)`，严格模式下会 1406，非严格模式会静默截断。建议用 Flyway/Liquibase 管理 DDL，并在测试里断言"实体长度注解 == 列长度"。
2. **`BigDecimal` 的 `scale` 与 `DECIMAL(10,2)` 的交互**。`0.999` 写入 `DECIMAL(10,2)`，严格模式下四舍五入到 `1.00`（**不报错**），非严格模式同样四舍五入。这是唯一"严格模式也不救你"的场景——金额务必在领域层用 `setScale(2, RoundingMode.HALF_UP)` 显式处理，并配 `@Digits`。
3. **JDBC 参数**。Connector/J 的 `jdbcCompliantTruncation`（默认 true）在客户端也会拦截断；如果为了"兼容老代码"把它设成 false，你会在客户端先丢一次精度，数据库严格模式根本看不到。

```yaml
# 推荐：让客户端也严格，问题尽早暴露
spring:
  datasource:
    hikari:
      connection-init-sql: "SET SESSION sql_mode='STRICT_TRANS_TABLES,ONLY_FULL_GROUP_BY,NO_ENGINE_SUBSTITUTION'"
    url: jdbc:mysql://db:3306/app?jdbcCompliantTruncation=true&characterEncoding=utf8mb4
```

---

## 七、和字符集/排序规则的联动坑

严格模式不校验"字符能不能存"，那是字符集的事：

```sql
-- utf8（3 字节）存不了 emoji，严格模式下：
-- ERROR 1366: Incorrect string value: '\xF0\x9F\x98\x80'
INSERT INTO user_profile(nickname) VALUES ('东哥😀');
```

| 项 | 建议 |
|---|---|
| 字符集 | 全库统一 `utf8mb4`（**不要用 `utf8`/`utf8mb3`**） |
| 排序规则 | 8.0 用 `utf8mb4_0900_ai_ci`；与 5.7 混跑时用 `utf8mb4_general_ci` 保持一致 |
| 连接参数 | `characterEncoding=utf8`（Connector/J 8 会映射到 utf8mb4）+ `connectionCollation=utf8mb4_0900_ai_ci` |
| 迁移注意 | 5.7 的 `utf8mb4_general_ci` 与 8.0 的 `0900_ai_ci` **排序结果不同**，会影响 `ORDER BY` 与唯一索引冲突判定 |

最后一条特别隐蔽：迁移后"同样的数据，`ORDER BY name` 的顺序变了"，或者"原本不冲突的两个值，唯一索引突然报重复"。根因是排序规则变了（`0900_ai_ci` 对重音、大小写的处理更符合 Unicode 规范）。

---

## 八、面试高频追问

**Q1：`STRICT_TRANS_TABLES` 和 `STRICT_ALL_TABLES` 的区别？**

两者都对非法数据报错，区别在非事务表（MyISAM）：`STRICT_ALL_TABLES` 会在插入若干行后失败并**保留已插入的行**，造成半截数据；`STRICT_TRANS_TABLES` 对事务表可回滚，对非事务表会退化为"警告 + 截断"。生产推荐后者。

**Q2：为什么生产必须开 `ONLY_FULL_GROUP_BY`？**

因为它禁止"非聚合、非函数依赖的列"出现在 SELECT 中，避免返回不确定的行。不开的时候，同一条 SQL 在不同执行计划下可能返回不同结果，等于让数据库给你随机的业务数据。

**Q3：非严格模式下 `VARCHAR` 超长会怎样？**

会被截断到列定义长度，并产生 warning（`1265 Data truncated`）。JDBC 默认不抛异常，所以应用层完全无感。这是"数据静默损坏"的头号来源。

**Q4：`NO_ZERO_DATE` 打开后，历史数据里的 `0000-00-00` 会怎样？**

已有数据**不会**被清掉，只是**新写入**会被拒绝；但如果对它做 `ALTER TABLE`（即使是不相关的列）或 `mysqldump` 导入，可能直接失败。所以开启前必须先清理历史脏数据，并用 `SELECT COUNT(*) FROM t WHERE dt = '0000-00-00'` 做基线。

**Q5：`sql_mode` 是全局的还是会话的？**

两者都有，会话优先。`SET GLOBAL` 只影响**新建立的连接**（对已存在的连接无效），必须配合连接池重建或 `connection-init-sql` 才能保证一致——这是灰度时最容易踩的坑。

**Q6：怎么在不改 SQL 的前提下让 1055 消失？**

技术上可以 `SET sql_mode` 去掉 `ONLY_FULL_GROUP_BY`，但这是反模式：你会同时失去严格模式的其他保护，而且 SQL 的语义依然是随机的。正确做法是 `ANY_VALUE()`（明确表达"任意"）或改写成窗口函数/子查询（明确表达"最新")。

---

## 九、生产踩坑清单

1. **开发环境 `sql_mode=''`**——测试永远测不出截断，问题只在生产爆发。
2. **`SET GLOBAL sql_mode` 后没重建连接池**——老连接仍用旧模式，出现"部分请求报错、部分正常"的诡异现象。
3. **迁移前不查 `0000-00-00`**——开 `NO_ZERO_DATE` 后备份恢复失败。
4. **用 `SET sql_mode=''` 修 1055**——顺手关掉了所有严格校验，是"用一个更大的坑填一个小坑"。
5. **`@Size` 与 `VARCHAR(n)` 不一致**——严格模式下 1406，非严格下静默截断。
6. **`jdbcCompliantTruncation=false`**——客户端先丢精度，数据库侧根本看不到。
7. **`DECIMAL` 小数位溢出**——严格模式也只会四舍五入，不报错；金额必须显式 `setScale`。
8. **排序规则跨版本不一致**——`utf8mb4_general_ci` → `utf8mb4_0900_ai_ci` 会改变 `ORDER BY` 与唯一冲突判定。
9. **`ERROR_FOR_DIVISION_BY_ZERO` 打开后报表 SQL 报错**——`SUM(a)/SUM(b)` 在分母为 0 时要显式 `NULLIF(b,0)`。
10. **只改配置不改代码**——严格模式的正确用法是"让问题尽早暴露"，而不是"让问题消失"。

---

## 十、总结

`sql_mode` 是那种"你不看它，它一直在看你"的配置。

三句话收尾：

1. **严格模式的目的是把错误提前到写入时**，而不是让数据库"宽容地帮你猜"。静默截断的代价，永远在对账那天一次性还清。
2. **`ONLY_FULL_GROUP_BY` 不是敌人的规则，是随机的解药**。遇到 1055，改 SQL 的语义（`ANY_VALUE` / 窗口函数），不要改配置。
3. **开发、预发、生产的 `sql_mode` 必须完全一致**。环境差异是这类问题最大的温床。

如果你的库还跑在 5.6 的宽松模式上，现在就可以做一件事：在预发把 `sql_mode` 调成 8.x 的默认值，跑一遍全量回归，把报错清单列出来。那张清单，就是你未来迁移的风险评估报告。
