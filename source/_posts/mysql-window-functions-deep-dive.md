---
title: 【MySQL 实战】窗口函数深度实战：ROW_NUMBER、RANK、LEAD/LAG 原理与 SQL 优化
date: 2026-08-18 08:00:00
tags:
  - MySQL
  - 窗口函数
  - SQL优化
  - 面试
categories:
  - MySQL
  - 后端面试
author: 东哥
---

# 【MySQL 实战】窗口函数深度实战：ROW_NUMBER、RANK、LEAD/LAG 原理与 SQL 优化

## 面试官：说说窗口函数和 GROUP BY 有什么区别？

很多同学一上来就答：窗口函数就是分组排序。这个回答太浅了。我们先从本质说起。

**GROUP BY 的语义是"折叠"**：多行输入，一行输出。分组之后，你只能看到聚合结果，看不到组内每一行的细节。

**窗口函数（Window Function）的语义是"开窗计算"**：不折叠行数，每一行仍然保留，只是在每一行的上下文中多算出一个"窗口内"的聚合值。输入多少行，输出多少行。

```sql
-- GROUP BY：输出行数 = 分组数
SELECT dept_id, AVG(salary) FROM emp GROUP BY dept_id;

-- 窗口函数：输出行数 = 原始行数，每行附带其部门的平均工资
SELECT emp_id, dept_id, salary,
       AVG(salary) OVER (PARTITION BY dept_id) AS dept_avg
FROM emp;
```

窗口函数是 SQL 2003 标准引入的，MySQL 8.0 才完整支持（8.0.2 起可用）。所以这也是一个"版本分水岭"知识点：**在 MySQL 5.7 里你用子查询 + 用户变量才能实现的事，8.0 一行 OVER 搞定**。

---

## 一、窗口函数的语法骨架

```sql
window_function(expr) OVER (
    [PARTITION BY 分组列]
    [ORDER BY 排序列]
    [ROWS | RANGE 窗口框架]
)
```

拆开来看三个核心部分：

### 1. PARTITION BY —— 开窗的分区
逻辑上和 GROUP BY 类似，把数据分成若干个"窗口"。**区别在于：PARTITION BY 不合并行**。

### 2. ORDER BY —— 窗口内的排序
决定了窗口内行的顺序，也是排名类函数的依据。注意：**窗口内的 ORDER BY 只影响窗口函数计算，不影响最终结果集的行序**（最终顺序还是要靠外层 ORDER BY 保证，除非你恰好利用了 OVER 的排序副作用，但那不可靠）。

### 3. 窗口框架（Frame）—— 计算范围
这是最容易被忽略、也是面试最容易挖坑的部分。框架指定了"当前行到底和哪些行一起算"。

```sql
ROWS BETWEEN 边界1 AND 边界2
-- 边界可以是：
-- UNBOUNDED PRECEDING  窗口起点（第一行）
-- N PRECEDING          往前 N 行
-- CURRENT ROW          当前行
-- N FOLLOWING          往后 N 行
-- UNBOUNDED FOLLOWING  窗口终点（最后一行）
```

**经典坑**：`ORDER BY` 存在时，默认框架是 `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`——**不是全窗口**！

```sql
-- 默认框架下，这是"截至当前行的累计和"，不是全组总和
SELECT emp_id, salary,
       SUM(salary) OVER (PARTITION BY dept_id ORDER BY salary) AS running_total
FROM emp;
```

想要全组总和，必须显式写 `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`，或者干脆去掉 ORDER BY（没有 ORDER BY 时框架就是整个分区）。

---

## 二、三大类窗口函数

### 1. 聚合类：SUM / AVG / COUNT / MAX / MIN
和普通聚合函数同名，但加了 OVER 就是窗口函数。常用于累计值、移动平均：

```sql
-- 近 3 天销售额移动平均
SELECT trade_date, amount,
       AVG(amount) OVER (ORDER BY trade_date
                         ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS ma_3
FROM daily_sales;
```

### 2. 排名类：ROW_NUMBER / RANK / DENSE_RANK / NTILE

| 函数 | 行为 | 例子（分数 90, 90, 85） |
|------|------|------------------------|
| ROW_NUMBER() | 严格递增，不并列 | 1, 2, 3 |
| RANK() | 并列跳号 | 1, 1, 3 |
| DENSE_RANK() | 并列不跳号 | 1, 1, 2 |
| NTILE(n) | 平均分桶 | 依桶数而定 |

**RANK 和 DENSE_RANK 的区别是面试高频题**，一句话记忆：RANK 是"并列第几，后续跳号"（体育比赛名次 1、1、3），DENSE_RANK 是"并列第几，后续连续"（1、1、2）。

### 3. 取值类：LAG / LEAD / FIRST_VALUE / LAST_VALUE / NTH_VALUE
LAG(列, n) 取前 n 行的值，LEAD(列, n) 取后 n 行的值——**同比环比、前后对比全靠它**：

```sql
-- 每个员工与上一个入职者的入职日期差
SELECT emp_id, hire_date,
       LAG(hire_date, 1) OVER (ORDER BY hire_date) AS prev_hire,
       DATEDIFF(hire_date, LAG(hire_date, 1) OVER (ORDER BY hire_date)) AS gap_days
FROM emp;
```

注意 LAST_VALUE 受默认框架影响很大，取"窗口内最后一行"时一定要显式声明框架，否则只会得到当前行自己。

---

## 三、实战案例：面试必考的四个场景

### 场景 1：分组 TopN（最经典）

```sql
-- 每个部门工资最高的 3 个人
SELECT dept_id, emp_id, salary
FROM (
    SELECT dept_id, emp_id, salary,
           ROW_NUMBER() OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rn
    FROM emp
) t
WHERE rn <= 3;
```

**为什么必须套一层子查询？** 因为 WHERE 的执行顺序在窗口函数之前，MySQL 不允许直接在 WHERE 里用窗口函数别名。这背后是 SQL 的逻辑执行顺序：FROM → WHERE → GROUP BY → HAVING → 窗口函数 → SELECT → ORDER BY → LIMIT。**窗口函数在 WHERE 之后才执行**，所以过滤必须在外层做。这是面试必问的执行顺序考点。

### 场景 2：连续登录天数（互联网公司高频题）

```sql
-- 找出连续登录 >= 3 天的用户
SELECT user_id
FROM (
    SELECT user_id, login_date,
           DATE_SUB(login_date, INTERVAL ROW_NUMBER()
               OVER (PARTITION BY user_id ORDER BY login_date) DAY) AS grp
    FROM login_log
) t
GROUP BY user_id, grp
HAVING COUNT(*) >= 3;
```

思路：按登录日期排序后编号，**日期减去编号**——连续的天数会落到同一个"基准日"，不连续的天数基准日不同。这个"差值分组"技巧把连续性问题转化成了分组计数问题，是窗口函数最漂亮的用法之一。

### 场景 3：去重保留一条（替代 group by + min(id) 的复杂写法）

```sql
DELETE FROM orders
WHERE id IN (
    SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY order_no ORDER BY create_time) AS rn
        FROM orders
    ) t WHERE rn > 1
);
```

注意 MySQL 不允许直接对子查询中使用了窗口函数的结果 DELETE 的表操作自身，需要再套一层派生表（如上）。每个 order_no 只保留最早创建的一条。

### 场景 4：同比环比

```sql
SELECT month, revenue,
       LAG(revenue, 1) OVER (ORDER BY month) AS prev_month,
       LAG(revenue, 12) OVER (ORDER BY month) AS prev_year,
       ROUND((revenue - LAG(revenue, 1) OVER (ORDER BY month))
             / LAG(revenue, 1) OVER (ORDER BY month) * 100, 2) AS mom_growth
FROM monthly_revenue;
```

---

## 四、窗口函数的性能与优化

### 1. 一定会产生排序
窗口内的 ORDER BY 和 PARTITION BY 都需要排序/哈希操作，会生成临时文件（Using temporary; Using filesort）。**数据量大时，窗口函数比同语义的 GROUP BY 子查询更吃内存**。

### 2. 优化思路
- **尽量让排序走索引**：`OVER (PARTITION BY dept_id ORDER BY salary)` 若能命中 `(dept_id, salary)` 联合索引，可避免 filesort；
- **控制窗口大小**：能用 ROWS 限制框架范围的，别扫整个分区；
- **避免在大表上做全量窗口计算**：先用 WHERE 缩小数据范围再开窗，因为窗口函数作用于"过滤后的结果集"；
- **MySQL 8.0 里窗口函数无法使用索引下推**（这是相对于 5.7 用户变量方案的一个取舍），极端场景可考虑物化临时表。

### 3. 窗口函数 vs 用户变量（5.7 兼容方案）
5.7 里模拟 ROW_NUMBER 靠用户变量 + 派生表：

```sql
SELECT @rn := IF(@dept = dept_id, @rn + 1, 1) AS rn,
       @dept := dept_id
FROM emp, (SELECT @rn := 0, @dept := NULL) init
ORDER BY dept_id, salary DESC;
```

**用户变量方案的致命伤**：结果的正确性依赖 ORDER BY 的执行顺序，MySQL 官方文档明确不保证变量赋值的求值顺序，生产环境极易踩坑。所以能用 8.0 就别用 5.7 变量方案。

---

## 五、面试官连环追问

**Q1：ROW_NUMBER() 和 LIMIT 都能取 TopN，区别在哪？**
LIMIT 是对"整体排序后的结果"截断，取的是全局 TopN；ROW_NUMBER + PARTITION BY 取的是"每个分组内的 TopN"。分组 TopN 用 LIMIT 写不出来（除非用 UNION 拼，丑且不可扩展）。

**Q2：窗口函数里 ORDER BY 会改变结果集顺序吗？**
不会保证。OVER 里的 ORDER BY 只决定窗口计算逻辑；最终结果集顺序仍由最外层 ORDER BY 决定。依赖 OVER 排序副作用是坏味道。

**Q3：默认窗口框架是什么？**
有 ORDER BY 时是 `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`（到当前行止）；无 ORDER BY 时是整个分区。RANGE 模式按值相等归并（同值行算同一行），ROWS 模式严格按物理行。**这也是为什么 SUM(...) OVER (ORDER BY x) 是累计和而不是总和**。

**Q4：窗口函数在逻辑执行顺序的哪一步？**
WHERE/GROUP BY/HAVING 之后、SELECT 投影之前。所以不能直接在 WHERE 里引用窗口函数别名，必须包一层。

**Q5：PERCENT_RANK()、CUME_DIST() 了解吗？**
都是分布函数：PERCENT_RANK() 返回 (排名-1)/(总行数-1)，CUME_DIST() 返回"小于等于当前值的行占比"。用于百分位分析，如成绩超过多少人。

---

## 六、总结

| 维度 | GROUP BY | 窗口函数 |
|------|----------|----------|
| 行数变化 | 多行折叠为一行 | 行数不变 |
| 能否看到明细 | 不能 | 能 |
| 组内排名 | 不支持 | 支持 |
| 前后行访问 | 不支持 | LAG/LEAD 支持 |
| MySQL 版本 | 全版本 | 8.0+ |

窗口函数是 MySQL 8.0 时代必须掌握的核心能力。面试时把"执行顺序、默认框架、RANK 三兄弟、连续登录差值分组"这四点讲透，基本就立于不败之地了。实践中记住一条铁律：**先过滤、后开窗、框架显式写**，性能和正确性就都有保障了。
