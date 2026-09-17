---
title: 【MySQL 8.0】通用表表达式（CTE）深度解析：递归查询、物化策略与树形结构实战
date: 2026-09-17 08:00:00
tags:
  - MySQL
  - SQL优化
  - CTE
categories:
  - 数据库
  - MySQL
author: 东哥
---

# 【MySQL 8.0】通用表表达式（CTE）深度解析：递归查询、物化策略与树形结构实战

## 面试官：组织架构树怎么查？别说"Java 里递归"

"给我一个部门下的所有子部门"——这个问题在 Java 里用递归 + 多次查询能实现，但那是**把数据库该干的活搬到了应用层**：N 层树就是 N 次网络往返，层级深一点就是几十次查询，一旦并发上来，连接池先扛不住。

MySQL 8.0 之前，标准答案是"存储过程 + 临时表 + 循环"，写得又臭又长。8.0 引入 **CTE（Common Table Expression，通用表表达式）** 后，终于可以用一条 SQL 搞定递归。

本文把 CTE 讲透：语法、`WITH RECURSIVE` 的执行模型、物化 vs 内联、递归深度限制与 `cte_max_recursion_depth`，以及组织架构 / 评论树 / 路径枚举等真实场景。

## 一、非递归 CTE：让复杂 SQL 长出手脚

先看一个很典型的需求：**统计每个类目的销售额，并只保留高于全场均值的类目**。

不用 CTE 的写法：

```sql
SELECT category,
       SUM(amount) AS total
FROM orders
GROUP BY category
HAVING SUM(amount) > (
    SELECT AVG(cat_total)
    FROM (
        SELECT SUM(amount) AS cat_total
        FROM orders
        GROUP BY category
    ) t
);
```

用 CTE：

```sql
WITH cat_total AS (
    SELECT category, SUM(amount) AS total
    FROM orders
    GROUP BY category
)
SELECT *
FROM cat_total
WHERE total > (SELECT AVG(total) FROM cat_total);
```

区别不只是好看。CTE 的价值在于：

1. **可读性**：把"分步计算"写成有名字的步骤，和写代码一样；
2. **可复用**：同一个 CTE 可以在主查询里引用多次，不用把子查询复制两遍；
3. **可串联**：后面的 CTE 可以引用前面的 CTE，形成流水线。

关键点是第 2 条：`cat_total` 在主查询里用了两次（一次取数、一次算均值）。这就引出了本文最重要的一个机制问题——**它到底被物化了几次？**

## 二、物化（Materialization）还是内联（Merge）？

MySQL 8.0 对 CTE 有两种处理策略：

| 策略 | 行为 | 触发条件 |
| --- | --- | --- |
| **Merge（内联）** | SQL 优化器把 CTE 当成"视图"，把定义展开进主查询 | CTE 只被引用一次、且无副作用（无聚合/无 LIMIT/无 UNION 等），且外层可以下推条件 |
| **Materialization（物化）** | 先算出结果集放进临时表，后续每次引用都读这张临时表 | CTE 被多次引用、包含聚合/排序/LIMIT、或含递归 |

上面 `cat_total` 被引用两次 → **必然物化**，只扫描一次 `orders` 再建临时表，这也是它比"子查询写两遍"快的原因（子查询写两遍在某些情况下会被执行两次）。

用 `EXPLAIN` 可以直接看出选择：

```sql
EXPLAIN FORMAT=TREE
WITH cat_total AS (
    SELECT category, SUM(amount) AS total FROM orders GROUP BY category
)
SELECT * FROM cat_total WHERE total > (SELECT AVG(total) FROM cat_total);
```

```text
-> Filter: (cat_total.total > (select #2))
    -> Table scan on cat_total
        -> Materialize
            -> Table scan on <temporary>
                -> Aggregate ...
```

看到 `Materialize` 就说明落临时表了。**如果临时表超过 `tmp_table_size` / `max_heap_table_size`，会溢出到磁盘**——这是 CTE 最常见的性能事故来源。

::: tip 控制手段
MySQL 允许显式指定处理方式（优化器 hint 语法，8.0.20+）：

```sql
WITH cat_total AS MATERIALIZED ( ... )
WITH cat_total AS NOT MATERIALIZED ( ... )
```

`NOT MATERIALIZED` 会把 CTE 内联展开，适合"只引用一次但优化器误判物化"的场景；反过来，如果内联导致重复扫表，就强制 `MATERIALIZED`。
:::

### Java 视角的工程约束

CTE 物化后的临时结果不算"缓存"，**不要指望它跨请求复用**。所以这类逻辑不要放在"每分钟跑几万次"的热点接口里，而应该：

- 定期物化到物理表（宽表 / 汇总表），接口直接查；
- 或者放到离线/准实时链路（Flink、定时任务）算好。

## 三、WITH RECURSIVE：一条 SQL 走完整棵树

语法骨架：

```sql
WITH RECURSIVE cte_name AS (
    -- 锚点（Base case）：不引用自身的查询
    SELECT ... 
    UNION ALL
    -- 递归成员（Recursive case）：FROM 里引用了 cte_name
    SELECT ... FROM cte_name JOIN some_table ON ...
)
SELECT * FROM cte_name;
```

执行模型是**迭代**而不是"递归调用"：

```text
1. 执行锚点查询 → 结果集 R0 放入临时表（work table）
2. while (work table 非空) {
     用 work table 的"增量行"去执行递归成员 → 得到 Rn
     覆盖 work table = Rn
     把 Rn 追加进最终结果集
   }
3. 返回最终结果集
```

注意第 2 步里的"增量行"——每轮迭代只把**上一轮新产出的行**喂给递归成员，这就是它不会死循环的前提（前提是数据无环）。

### 场景 1：组织架构，查某部门下所有子部门

```sql
CREATE TABLE department (
    id        BIGINT PRIMARY KEY,
    parent_id BIGINT,
    name      VARCHAR(64),
    KEY idx_parent (parent_id)
);

WITH RECURSIVE sub_dept AS (
    -- 锚点：起点部门
    SELECT id, parent_id, name, 1 AS depth
    FROM department
    WHERE id = 100

    UNION ALL

    -- 递归：往上找到的父节点，继续找它的子节点
    SELECT d.id, d.parent_id, d.name, s.depth + 1
    FROM department d
    JOIN sub_dept s ON d.parent_id = s.id
)
SELECT * FROM sub_dept ORDER BY depth, id;
```

关键点：

- 锚点必须能定位到起点，**锚点查询要有索引可用**（这里 `id` 主键）；
- 递归成员的连接条件是 `d.parent_id = s.id`，走的是 `idx_parent` 索引；
- `depth` 是我们自己加的层级列，用来限制层数或排序。

### 场景 2：向下查祖先链（反向）

```sql
WITH RECURSIVE ancestors AS (
    SELECT id, parent_id, name, 1 AS depth FROM department WHERE id = 100
    UNION ALL
    SELECT d.id, d.parent_id, d.name, a.depth + 1
    FROM department d JOIN ancestors a ON d.id = a.parent_id
)
SELECT * FROM ancestors;
```

这里连接方向反了：从子节点往上找父节点，`d.id = a.parent_id` 走主键。

### 场景 3：限制递归深度

数据里如果存在环（`A.parent = B, B.parent = A`，典型是脏数据），`UNION ALL` 会无限迭代直到报错。三种防护：

```sql
-- 方式一：显式深度限制（推荐，语义清晰）
WITH RECURSIVE sub AS (
    SELECT id, parent_id, 1 AS depth FROM department WHERE id = 100
    UNION ALL
    SELECT d.id, d.parent_id, s.depth + 1
    FROM department d JOIN sub s ON d.parent_id = s.id
    WHERE s.depth < 10          -- ← 关键
)
SELECT * FROM sub;

-- 方式二：用 UNION（去重）替代 UNION ALL
--   环上的行内容重复后被去重，循环自然终止
--   代价：每轮都要做去重，性能明显下降

-- 方式三：会话级限制（默认 1000）
SET SESSION cte_max_recursion_depth = 10000;
```

> `cte_max_recursion_depth` 默认 **1000**。组织架构超过 1000 层不可能，但**评论树 / 图遍历 / BOM 展开**很容易触碰。生产上宁可显式 `WHERE depth < N`，也别依赖全局变量——它一旦被调大，脏数据环就会把库拖垮。

## 四、树形结构方案对比：别只想着递归

递归 CTE 很方便，但它**不适合高频查询**。真实工程里通常三选一或组合：

| 方案 | 查询复杂度 | 写入成本 | 适用场景 |
| --- | --- | --- | --- |
| 邻接表（parent_id）+ 递归 CTE | O(深度) 次索引查找 | 极低 | 层级浅、查询不频繁（后台管理） |
| 路径枚举（path = '1/12/135/'） | 一次 LIKE 前缀扫描 | 中（移动节点要批量改） | 层级稳定、需要"子树前缀"查询 |
| 闭包表（closure table） | 一次 JOIN | 高（每对祖先-后代一行） | 读多写少、需要"任意两节点关系" |
| 嵌套集（left/right 值） | 范围查询，极快 | 很高（插入要改半张表） | 几乎只读的树 |

路径枚举示例：

```sql
-- 查 id=100 及其所有后代
SELECT * FROM department
WHERE path LIKE '1/12/100%'      -- 前缀匹配，走索引
  AND id <> 100;
```

`LIKE 'xxx%'` 是唯一能用上索引的 LIKE 形式，所以路径前缀必须放最前面。移动节点时用一条 `UPDATE ... REPLACE(path, ...)` 批量改子树的 path。

实践结论：**后台低频查询用递归 CTE，前台高频查询用路径枚举 + 索引（或物化宽表）**。

## 五、CTE 的坑与优化清单

1. **`WITH RECURSIVE` 必须用 `RECURSIVE` 关键字**，否则递归成员里引用自身会报"表不存在"。
2. **锚点与递归成员的列类型/数量必须一致**，否则报错或隐式转换导致索引失效。
3. **CTE 不能跨语句复用**。它不是视图，也不是临时表，别想着在下一个 SQL 里接着用。
4. **物化临时表会落盘**。用这个 SQL 观察：

   ```sql
   SHOW STATUS LIKE 'Created_tmp_disk_tables';
   ```

   如果这个值持续上涨，说明你的 CTE / 派生表太大，考虑加索引或用汇总表替代。
5. **`MATERIALIZED` 与 `NOT MATERIALIZED` 是双刃剑**。内联展开可能让查询变成"扫表两遍"，物化则可能落磁盘。8.0.20 之前无法干预，只能改写 SQL。
6. **`UPDATE` / `DELETE` 里也能用 CTE**，但要注意 `WITH` 必须在语句最前面：

   ```sql
   WITH stale AS (
       SELECT id FROM orders WHERE created_at < '2025-01-01' LIMIT 1000
   )
   DELETE o FROM orders o JOIN stale s ON o.id = s.id;
   ```

   `LIMIT` + CTE + JOIN 是"分批清理大表"的常用姿势，比 `DELETE ... LIMIT` 更可控。
7. **递归 CTE 无法用索引优化迭代本身**，每轮迭代都是一次全量索引查找，所以**每层数据量不能爆**。如果某一层有十万行，递归会把临时表撑爆。

## 面试追问连击

**追问 1：递归 CTE 的时间复杂度是多少？**
近似 O(D × log N)，D 是最大深度，每层迭代做一次索引查找（B+ 树 O(log N)）。它**不是** O(N)，因为每轮只处理增量行。真实瓶颈在于临时表行数（= 结果集大小）而非查找次数。

**追问 2：为什么 `UNION` 能防环，`UNION ALL` 不能？**
`UNION` 每轮对结果去重，环上的重复行被消除后 work table 为空，迭代终止。代价是每轮 O(n) 去重（可能走临时表），所以大结果集下性能断崖式下降。

**追问 3：CTE 和临时表、派生表有什么区别？**
派生表（`FROM (...)`）作用域只在当前查询且通常一次引用；临时表是物理存在的，可跨语句、可建索引；CTE 是"命名查询块"，作用域限本语句，是否物化由优化器决定，且支持递归。**CTE 是表达能力介于视图和子查询之间的东西**。

**追问 4：`WITH X AS MATERIALIZED` 和 `CREATE TEMPORARY TABLE` 选哪个？**
如果结果需要**多次复用**或**加索引**，临时表更合适（可以 `ALTER TABLE ... ADD INDEX`）；CTE 的物化临时表**不能建索引**，只能全扫，这也是它慢的根源之一。

**追问 5：怎么排查递归 CTE 把库跑挂？**
先看 `performance_schema` 里的 `statement/sql/select` 与 `Created_tmp_disk_tables`；再看 `tmpdir` 磁盘用量；最后检查 `cte_max_recursion_depth` 是否被调大。止血手段是 kill 掉对应 thread（`SHOW PROCESSLIST` + `KILL QUERY`），根治是加 `depth` 上限。

## 小结

- CTE 把"分步查询"变成可命名、可复用的流水线，`WITH RECURSIVE` 让树形查询回到数据库内。
- 是否物化由优化器决定，多次引用 → 必然物化 → 可能落磁盘，这是性能风险点。
- 递归的执行模型是迭代式，每轮只喂增量行，时间复杂度约 O(D·log N)。
- 防环靠 `depth` 上限或 `UNION`（去重），别依赖 `cte_max_recursion_depth`。
- 高频树查询别用递归 CTE，路径枚举/闭包表/宽表才是正解。

下次面试再被问"组织架构树怎么查"，你可以先给出递归 CTE 的写法，再补一句"但线上我会换成路径枚举"——这一来一回，层次就出来了。
