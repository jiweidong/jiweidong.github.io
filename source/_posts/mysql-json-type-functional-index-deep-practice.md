---
title: 【MySQL 实战】MySQL JSON 数据类型深度实战：二进制存储、JSON 函数、虚拟列与函数索引
date: 2026-09-11 08:00:00
tags:
  - MySQL
  - 数据库
  - 性能优化
  - 面试
categories:
  - MySQL
  - 后端
author: 东哥
---

# 【MySQL 实战】MySQL JSON 数据类型深度实战：二进制存储、JSON 函数、虚拟列与函数索引

## 面试官：你们表里有 JSON 字段吗？为什么要用 JSON？

很多人第一反应是"扩展字段用 TEXT 存一段 JSON 字符串不就行了"。这就是典型的**把 JSON 当成字符串**。MySQL 5.7 引入的 `JSON` 类型和 `TEXT` 存 JSON 完全是两种东西：

| 维度 | TEXT 存 JSON | JSON 类型 |
| --- | --- | --- |
| 合法性校验 | 无，脏数据随便进 | 写入即校验，非法直接报 3130 |
| 存储格式 | 原样字符串 | 二进制格式（BINARY JSON） |
| 读写效率 | 每次全量解析 | 解析一次，按路径定位 |
| 中文/转义 | 需要处理转义字符 | 不需转义 |
| 路径查询 | `LIKE '%xxx%'` 全表扫 | `->` / `JSON_EXTRACT` 走路径 |
| 索引 | 只能靠生成列 | 生成列 + 索引 / 函数索引 |
| 部分更新 | 整行重写 | 满足条件可只改片段 |

所以 JSON 类型的价值在于：**半结构化数据的动态扩展**（比如商品的多变属性、风控事件的上下文、埋点参数），而不是用它替代所有字段。

## 一、二进制存储：JSON 到底长什么样

MySQL 的 JSON 以**二进制格式**存储，一个 JSON 文档的结构大致是：

```
+--------+---------------------+
| type   | value               |
+--------+---------------------+
```

- `type`：1 字节类型标记（0x00=small object，0x01=large object，0x02=small array，0x03=large array，0x04=literal，0x05=number，0x06=string ...）
- `object` 的 value 结构：`element count` + `size` + `key entries` + `value entries`
- `key entries` 是**有序的 key 数组**（按 key 长度再按字典序排序），查找时二分，因此 key 不需要重复存储，多个元素共享同一个 key 字符串

用一个小例子在 SQL 里直接看大小差异：

```sql
CREATE TABLE t_json_demo (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  content TEXT,
  payload JSON
);

INSERT INTO t_json_demo(content, payload)
VALUES ('{"name":"apple","price":10,"tags":["fruit"]}',
        '{"name":"apple","price":10,"tags":["fruit"]}');

SELECT
  LENGTH(content) AS text_bytes,
  LENGTH(payload) AS json_bytes
FROM t_json_demo;
-- 典型结果：text_bytes=44, json_bytes 会略大（多了类型和长度头），
-- 但 key 复用、重复 key 的场景下 JSON 反而更小
```

**面试追问：JSON 比 TEXT 小吗？**
不一定。**单个 key 极少的扁平小文档**，JSON 因为有类型头会略大；但**key 大量重复、字段多的数组**，因为 key 只存一次并可二分查找，JSON 反而更省。真正的收益是**查询和更新的效率**，不是体积。

## 二、JSON 函数全景

### 1. 提取

```sql
SET @doc = '{"name":"apple","price":10,"spec":{"color":"red","weight":200},"tags":["fruit","fresh"]}';

SELECT JSON_EXTRACT(@doc, '$.spec.color');   -- "red"（带引号）
SELECT @doc -> '$.spec.color';               -- 等价写法
SELECT @doc ->> '$.spec.color';              -- red（去引号，等价 JSON_UNQUOTE）
SELECT JSON_UNQUOTE(@doc -> '$.name');       -- apple
SELECT JSON_KEYS(@doc);                      -- ["name","price","spec","tags"]
SELECT JSON_LENGTH(@doc, '$.tags');          -- 2
SELECT JSON_TYPE(@doc -> '$.tags');          -- ARRAY
SELECT JSON_VALID('{bad json');              -- 0
```

**重点区分 `->` 和 `->>`**：前者返回 JSON 类型的值（字符串带引号），后者返回 SQL 字符串。做 `WHERE` 比较时一定要用 `->>`，否则 `"apple" != 'apple'`。

### 2. 修改（注意：修改函数返回新文档，必须回写）

```sql
UPDATE t_json_demo
SET payload = JSON_SET(payload, '$.price', 12, '$.stock', 100)
WHERE id = 1;

UPDATE t_json_demo SET payload = JSON_REMOVE(payload, '$.stock') WHERE id = 1;
UPDATE t_json_demo SET payload = JSON_REPLACE(payload, '$.price', 15) WHERE id = 1; -- 不存在则不插入
UPDATE t_json_demo SET payload = JSON_INSERT(payload, '$.origin', 'CN') WHERE id = 1; -- 已存在则不覆盖
UPDATE t_json_demo SET payload = JSON_MERGE_PATCH(payload, '{"price":20}') WHERE id = 1; -- RFC 7386 合并
```

### 3. 判断与检索

```sql
SELECT JSON_CONTAINS('["a","b","c"]', '"b"');                 -- 1（数组包含）
SELECT JSON_CONTAINS('{"a":1,"b":2}', '{"a":1}');             -- 1（文档子集）
SELECT JSON_OVERLAPS('[1,2,3]', '[3,4]');                     -- 1（8.0.17+，有交集）
SELECT JSON_SEARCH('{"name":"apple"}', 'one', 'app%');        -- "$.name"（深度遍历，慢）
```

`JSON_SEARCH` 是**全文档深度遍历**，千万级数据里用它做业务查询基本等于自杀，只适合运维排障。

### 4. 展开成行：JSON_TABLE（8.0 神器）

把数组打平成关系行，这是 JSON 与关系模型之间的桥：

```sql
SELECT t.id, jt.tag, jt.idx
FROM t_json_demo t,
     JSON_TABLE(t.payload, '$.tags[*]'
       COLUMNS (
         idx FOR ORDINALITY,
         tag VARCHAR(32) PATH '$'
       )) AS jt
WHERE t.id = 1;
-- 1 | fruit | 1
-- 1 | fresh | 2
```

### 5. 聚合回 JSON

```sql
SELECT JSON_OBJECTAGG(name, price) FROM t_product WHERE category_id = 10;
SELECT JSON_ARRAYAGG(name) FROM t_product WHERE category_id = 10;
```

## 三、JSON 字段能不能建索引？——生成列与函数索引

**JSON 字段本身不能直接建 B-Tree 索引**（因为它不是一个标量值）。两条路：

### 方案一：生成列（虚拟列）+ 索引（5.7+，最通用）

```sql
ALTER TABLE t_json_demo
  ADD COLUMN price INT
    GENERATED ALWAYS AS (payload ->> '$.price') VIRTUAL,
  ADD COLUMN name VARCHAR(64)
    GENERATED ALWAYS AS (payload ->> '$.name') STORED;

CREATE INDEX idx_price ON t_json_demo(price);
CREATE INDEX idx_name ON t_json_demo(name);
```

- `VIRTUAL`：不占存储，读时计算，可以建二级索引（索引里物化了值）
- `STORED`：占存储，写时计算，可建索引也可做主键的一部分
- **注意**：表达式必须是**确定性**的，不能用 `NOW()`、不能用非确定性函数，否则报错 3105

### 方案二：函数索引（8.0.13+，更省事）

```sql
CREATE INDEX idx_price_func ON t_json_demo ((CAST(payload ->> '$.price' AS UNSIGNED)));
-- 或者
ALTER TABLE t_json_demo ADD INDEX idx_name_func ((payload ->> '$.name'));
```

**关键坑：函数索引只有在 SQL 表达式与索引表达式完全一致时才会命中。** 写法不同（比如少一个 `CAST`）就退化成全表扫描：

```sql
-- ✅ 命中 idx_price_func
SELECT * FROM t_json_demo WHERE CAST(payload ->> '$.price' AS UNSIGNED) = 10;

-- ❌ 不命中（表达式不一致）
SELECT * FROM t_json_demo WHERE payload ->> '$.price' = '10';
```

一定要用 `EXPLAIN` 验证，`key` 列有值才算生效：

```sql
EXPLAIN SELECT * FROM t_json_demo
WHERE CAST(payload ->> '$.price' AS UNSIGNED) = 10\G
```

### 更多值索引：多值索引（8.0.17+）

数组里的每个元素也想索引，可以用 `CAST(... AS ... ARRAY)`：

```sql
ALTER TABLE t_product
  ADD INDEX idx_tags ((CAST(payload -> '$.tags' AS CHAR(32) ARRAY)));

SELECT * FROM t_product WHERE 'fresh' MEMBER OF (payload -> '$.tags');
```

## 四、JSON 部分更新（Partial Update）与 binlog 格式

JSON 的"部分更新"是指：当 `JSON_SET/REPLACE/REMOVE` 修改的是**已有路径的等长（或更短）值**，且满足其它条件时，InnoDB 只重写变化的片段，而不是整个文档。

要真正落盘为部分更新，需要满足：

1. `binlog_format = ROW` 且 `binlog_row_image = FULL`
2. 不是 `JSON_REPLACE` 之外的不满足条件的操作（例如在数组中间插入会退化为整体重写）
3. 使用的是 InnoDB 表

如果没有满足，MySQL 会退化成**整文档重写**，此时：

- undo/redo 体积变大（一行可能几 KB 的 JSON）
- 大文档更新会成为写热点

所以最佳实践是：**JSON 文档不要过大（控制在几 KB 以内），不要把频繁更新的字段塞进大 JSON**。如果某个字段更新极其频繁，就把它提出来做普通列。

## 五、什么时候该用 JSON，什么时候必须拆表

| 场景 | 建议 |
| --- | --- |
| 字段数量动态变化、每种类型字段不同（商品属性、埋点参数） | ✅ JSON |
| 读多写少、按整体读取（配置快照、原始报文归档） | ✅ JSON |
| 需要频繁按某字段过滤/排序/关联 | ⚠️ 用生成列 + 索引，或拆列 |
| 需要事务强约束（外键、唯一约束） | ❌ 拆成关系表 |
| 需要复杂的多字段组合查询、聚合分析 | ❌ 拆表 / 走 ES / 列存 |
| 文档超过几十 KB，且频繁更新 | ❌ 拆表或对象存储 |

一句话总结：**JSON 是"动态扩展的补充",不是"关系模型的替代"**。核心查询路径必须字段化。

## 六、生产踩坑清单

1. **别用 `LIKE '%key%'` 查 JSON**：一定全表扫描。
2. **`->>` 与 `->` 混用**：比较时忘写 `->>`，字符串带引号，索引失效。
3. **生成列表达式与查询表达式不一致**：函数索引直接失效，必须 `EXPLAIN` 验证。
4. **大 JSON 拆不动**：单行超过几 KB 且高频更新，会产生严重的 redo/undo 膨胀和复制延迟。
5. **NULL 语义**：`JSON_EXTRACT` 找不到路径返回 SQL `NULL`，而 JSON 里显式 `null` 返回 JSON `null`，二者在 `WHERE` 里的行为不同，务必区分。
6. **排序列已是字符串**：`payload ->> '$.price'` 出来的是字符串，排序会按字典序（`100 < 20`），必须 `CAST(... AS UNSIGNED)`。
7. **字符集**：JSON 内部使用 `utf8mb4`，与其他字符集列比较时注意隐式转换。

## 面试官可能的追问

**Q1：JSON 类型可以建索引吗？**
本身不能，但可以通过生成列（虚拟列）或 8.0 的函数索引、多值索引来间接索引。索引里存的是表达式的计算结果。

**Q2：虚拟列和存储生成列怎么选？**
只需索引、不需要频繁读，选 `VIRTUAL`（省空间，索引里已物化）；需要直接在 `SELECT` 中做条件过滤且不想每次计算，或者需要参与主键/分区，选 `STORED`。更新频繁时 `STORED` 会带来额外写开销。

**Q3：JSON 的 key 会不会重复存储？**
不会。二进制格式里 key 数组有序且去重，value 通过偏移引用 key，所以大量重复 key 的场景 JSON 比等价 TEXT 更省空间。

**Q4：为什么 JSON 字段更新会导致主从延迟？**
因为若退化为整文档重写，一行 binlog event 携带整个大 JSON，从库回放时又是全字段更新，写入放大数倍。

## 总结

- JSON 类型 = **二进制存储 + 写入校验 + 路径查询**，不是 TEXT 的替代品。
- `->` 返回 JSON，`->>` 返回字符串，比较/排序必须 `->>` 并注意 `CAST`。
- 索引只有三条路：**生成列 + 索引、函数索引（8.0.13+）、多值索引（8.0.17+）**，且表达式必须与查询完全一致。
- 大文档高频更新的场景要警惕写放大与复制延迟，核心查询字段一定要提出来做普通列。
- 选型的判断标准是**"是否为核心查询路径"**，而不是"数据是不是 JSON 形状"。
