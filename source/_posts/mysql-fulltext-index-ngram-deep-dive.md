---
title: 【MySQL 索引】MySQL 全文索引深度解析：FULLTEXT、ngram 分词与中文检索实战
date: 2026-08-29 08:00:00
tags:
  - MySQL
  - 索引
  - 全文检索
  - 实战
categories:
  - Java
author: 东哥
---

# 【MySQL 索引】MySQL 全文索引深度解析：FULLTEXT、ngram 分词与中文检索实战

## 面试官：业务里有个「标题+内容」的模糊搜索，`LIKE '%关键词%'` 已经慢到 3 秒了，你有哪几种优化思路？MySQL 自带的全文索引能不能用？

搜索场景在中小项目里最常见的错误就是 `LIKE '%xx%'` 一把梭。数据量到百万级，全表扫描 + 回表，3 秒都算快的。这一篇我们把 **FULLTEXT 全文索引** 从原理到实战讲透：倒排索引结构、ngram 中文分词、与 LIKE/ES 的选型边界。

## 一、为什么 LIKE '%xx%' 走不了索引

### 1.1 B+ 树索引的匹配规则

B+ 树索引（见本站《B+ 树深度解析》）只支持**前缀匹配**：

- `LIKE 'abc%'` → 可以走索引（定位到 `abc` 起始区间）
- `LIKE '%abc'` / `LIKE '%abc%'` → **不能走索引**，因为不知道从哪个 key 开始扫描，只能全表扫 + 逐行判断

```
SELECT * FROM article WHERE content LIKE '%分布式事务%';
-- 执行计划: type=ALL, rows=500万  ← 全表扫描，血崩
```

### 1.2 为什么不用「反向 LIKE 优化」等土办法

有人会想到存倒序字段、拆词缓存等方案——都能缓解，但要么维护成本高，要么**无法做到真正的全文匹配**（多关键词 AND、词频排序等）。MySQL 官方给的答案就是 **FULLTEXT 全文索引**。

## 二、FULLTEXT 索引的底层原理

### 2.1 倒排索引（Inverted Index）

全文索引的数据结构是**倒排索引**，和 B+ 树完全不同：

```
正向索引（普通索引）：文档 → 词
  文档1: 分布式 事务 原理
  文档2: 事务 隔离 级别

倒排索引（全文索引）：词 → 文档列表
  分布式 → [文档1]
  事务   → [文档1, 文档2]   ← 带词频、位置信息
  隔离   → [文档2]
```

InnoDB 的实现里，全文索引数据存放在**辅助表（auxiliary table）**中，每个 FULLTEXT 索引对应 6 张 FTS 辅助表（FTS_INDEX_TABLE 存分词后的索引项，FTS_DOC_ID 表存文档映射）。核心表 `FTS_INDEX_TABLE` 的结构近似：

```
TERM（词） | DOC_COUNT（文档数） | ...
```

查询时：关键词 → 词典定位 → 拿到 doc_id 列表 → 回原表取行。**不需要扫描全表**。

### 2.2 全文索引的存储结构

InnoDB 全文索引使用 **倒排索引 + 分片（partition）** 结构，每个分片内部是一个 B+ 树（以词为 key）。插入文档时按 doc_id 哈希分片，避免单点写热点。还有 **FTS Index Cache**（内存缓存）加速新文档的索引构建，达到阈值后批量刷盘。

> 注意：MySQL 的 FULLTEXT 索引在 InnoDB 下是**异步提交**的（先写 cache，稍后落盘），刚插入的数据可能短暂搜不到——但实际延迟通常毫秒级，业务上可接受。

## 三、ngram：中文全文索引的正确打开方式

### 3.1 英文与中文的分词差异

MySQL 内置分词器（built-in）按空格/标点切词，只适合英文等空格分隔的语言。中文没有空格，必须用 **ngram 解析器**（MySQL 5.7.6+ 内置）：把文本按 **n 个字符为一组连续切分**（n 默认 2，即 bigram）。

```
文本: 分布式事务
bigram(2): 分布 | 布式 | 式事 | 事务
trigram(3): 分布式 | 布式事 | 式事务
```

### 3.2 创建 ngram 全文索引

```sql
-- 建表时指定 ngram 解析器（token_size=2）
CREATE TABLE article (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    title VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    FULLTEXT KEY ft_title_content (title, content) WITH PARSER ngram
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 或修改参数（全局默认解析器）
SET GLOBAL ngram_token_size = 2;
```

`ngram_token_size` 的选型：

| token_size | 优点 | 缺点 |
|---|---|---|
| 1 | 召回最全（单字也能搜） | 索引巨大、噪音多 |
| **2（默认）** | 中文双字词为主，平衡 | 单字搜不到（`搜「分」` 不行） |
| 3 | 更精确、索引更小 | 两字词搜不到（`搜「事务」` 不行） |

> 生产建议：**默认 2**。业务上确需单字搜索，可以考虑 token_size=1 + 搜索词至少两字的前端约束，或用 ES 兜底。

### 3.3 三种全文检索语法

```sql
-- 1. 自然语言模式 NATURAL LANGUAGE MODE（默认）
SELECT * FROM article
WHERE MATCH(title, content) AGAINST ('分布式 事务');

-- 2. 布尔模式 BOOLEAN MODE（支持 + - * " 等操作符）
SELECT * FROM article
WHERE MATCH(title, content) AGAINST ('+分布式 +事务' IN BOOLEAN MODE);
-- +必须包含  -必须不含  *通配(ngram下有限制)  "精确短语"

-- 3. 查询扩展 WITH QUERY EXPANSION（自动关联相关词，慎用）
SELECT * FROM article
WHERE MATCH(title, content) AGAINST ('分布式事务' WITH QUERY EXPANSION);
```

**布尔模式常用组合**：

| 语法 | 含义 |
|---|---|
| `+词A +词B` | 必须同时包含 A 和 B（AND） |
| `词A 词B` | 包含 A 或 B（OR） |
| `+词A -词B` | 包含 A 且不含 B |
| `"分布式事务"` | 精确短语匹配（ngram 下按 n-gram 序列匹配） |
| `词A*` | 前缀通配（ngram 支持有限，慎用） |

### 3.4 相关性排序：score 到底怎么算

MATCH 返回的隐式 score（布尔模式下不排序）基于 **TF-IDF 变体**：

```
score = Σ (idf × tf × 归一化因子)
idf = log((N - n + 1) / (n + 1))    -- N 总文档数，n 含词文档数
tf  = 词在该文档中的出现次数（按 doc 长度归一化）
```

可以显式取 score 并排序：

```sql
SELECT id, title, MATCH(title, content) AGAINST ('分布式 事务') AS score
FROM article
WHERE MATCH(title, content) AGAINST ('分布式 事务')
ORDER BY score DESC
LIMIT 20;
```

> 注意：`MATCH ... AGAINST` 在 WHERE 里写一次、SELECT 里再写一次，**两次计算**；MySQL 8.0 后可以用窗口函数或 CTE 复用。另外全文索引的 score 和 ES 的 BM25 不同，**不能跨库对比绝对值**。

## 四、实战：文章系统全文检索

### 4.1 场景需求

- 标题+正文搜索，支持多关键词 AND
- 按相关性排序
- 高亮片段（MySQL 8.0 的 `REGEXP`/`LOCATE` 自己截取，或 Java 侧处理）
- 分页

### 4.2 SQL 实现（布尔模式）

```sql
SELECT id, title,
       MATCH(title, content) AGAINST ('+分布式 +事务' IN BOOLEAN MODE) AS score,
       LEFT(content, 120) AS snippet
FROM article
WHERE MATCH(title, content) AGAINST ('+分布式 +事务' IN BOOLEAN MODE)
ORDER BY score DESC
LIMIT 0, 20;
```

### 4.3 MyBatis 映射

```xml
<select id="search" resultType="ArticleVO">
    SELECT id, title,
           MATCH(title, content) AGAINST (#{keyword} IN BOOLEAN MODE) AS score
    FROM article
    WHERE MATCH(title, content) AGAINST (#{keyword} IN BOOLEAN MODE)
    ORDER BY score DESC
    LIMIT #{offset}, #{size}
</select>
```

注意：**布尔模式关键词来自用户输入时，必须做转义**——`+ - < > ( ) ~ * "` 这些符号在布尔语法里是操作符，用户输入 `"a+b"` 会语法报错或语义错乱：

```java
public static String escapeBooleanQuery(String kw) {
    // 保留 + - 等作为普通字符处理
    return kw.replaceAll("([+\\-<>\\(\\)~\\*\"])", "\\\\$1");
}
```

### 4.4 与 LIKE 的性能实测对比

| 场景 | LIKE '%kw%' | FULLTEXT(ngram) |
|---|---|---|
| 100 万行，等宽数据 | 全表扫描，~2~3s | 倒排索引，~20~50ms |
| 索引空间 | 无额外开销 | 约数据量 30%~50% 的辅助表 |
| 相关性排序 | 不支持 | 内置 TF-IDF score |
| 多关键词 | 多个 LIKE AND，仍全表扫 | 布尔模式原生支持 |

**结论**：数据量过百万 + 需要多词 AND + 相关性排序 → FULLTEXT 完胜 LIKE。但**永远不要**拿 FULLTEXT 去硬刚 ES：FULLTEXT 没有分片、没有分布式、没有复杂打分模型。

## 五、全文索引的边界与坑

### 5.1 已知限制（面试高频）

1. **InnoDB 全文索引不支持中文停用词过滤**（英文内置 stopwords 列表；中文 ngram 没有内置停用词，`的/了/是` 也会进索引，白白占空间）。
2. **不支持前缀匹配优化**：`LIKE 'abc%'` 结合全文索引不会加速（全文索引不能当 B+ 树用）。
3. **不能用于数值/日期范围**：FULLTEXT 只服务于文本匹配。
4. **`IN BOOLEAN MODE` 下 `*` 通配在 ngram 上效果有限**（ngram 是固定 n 切分，无法做任意前缀扩展）。
5. **ALTER TABLE 添加全文索引会锁表重建**（8.0 用 INSTANT/INPLACE 算法有所缓解，但仍建议低峰期操作，或 pt-osc/gh-ost 在线变更，见本站《Online DDL 方案深度对比》）。
6. **索引同步延迟**：插入后短暂不可见（FTS cache 未刷盘），对「插入后立刻搜」的场景要做补偿（比如强制 flush 或接受毫秒延迟）。

### 5.2 停用词处理（8.0）

```sql
-- 查看内置停用词
SELECT * FROM INFORMATION_SCHEMA.INNODB_FT_DEFAULT_STOPWORD;

-- 自定义停用词表：创建表 → 设置变量 → 重建索引
CREATE TABLE my_stopwords (value VARCHAR(30)) ENGINE=INNODB;
INSERT INTO my_stopwords VALUES ('的'),('了'),('是'),('和');
SET GLOBAL innodb_ft_server_stopword_table = 'db/my_stopwords';
```

### 5.3 与 ES 的选型决策

```
数据量 < 500 万、无分布式需求、不想引入新组件
        └─> MySQL FULLTEXT（ngram）够用，零运维成本
数据量大 / 需要复杂分词（IK 同义词、拼音）/
高并发搜索 / 聚合分析 / 多租户隔离
        └─> Elasticsearch（见本站《Spring Data ES 深度实战》）
```

很多团队上来就上 ES，结果就一个 50 万行的文章表——运维成本远大于收益。**先问自己：数据量真的需要 ES 吗？** FULLTEXT 是「不引组件就能解决 80% 问题」的答案。

## 六、面试追问速答

**追问 1：为什么 LIKE '%abc%' 不能走索引，而 FULLTEXT 能？**
B+ 树索引按 key 有序，`%abc%` 无法确定起始 key，只能全表扫描；FULLTEXT 用倒排索引，把「词→文档列表」提前建好，查询时直接查词条定位文档，天然就是子串语义（分词后）。

**追问 2：ngram_token_size=2 搜「分布式事务」为什么能命中？**
查询时查询词也按 bigram 切分成 `分布|布式|式事|事务`，倒排索引里这 4 个词都指向该文档，布尔模式要求全部包含即可命中。代价是索引膨胀（文本长度×2 的词条），所以 ngram 索引体积明显大于数据本身。

**追问 3：FULLTEXT 和 ES 的倒排索引区别？**
同源的「词→文档」思想；差异在规模与能力：ES 是分布式分片、BM25 打分、自定义分词器（IK/同义词/拼音）、实时性可控（refresh）、聚合分析；MySQL FULLTEXT 单机、TF-IDF 变体、ngram 固定切分、无分片。**定位不同，不是替代关系**。

## 总结

| 要点 | 结论 |
|---|---|
| LIKE '%x%' | 全表扫描，百万级必炸 |
| FULLTEXT + ngram | 单机百万级文本搜索的正解，零额外组件 |
| 中文分词 | 用 `WITH PARSER ngram`，token_size=2 最均衡 |
| 语法 | 布尔模式支持 `+ - "` 组合，用户输入必须转义 |
| 边界 | 无分布式、无复杂打分，规模上来果断换 ES |

MySQL 全文索引是「杀鸡用牛刀」的反面——对中小规模搜索，它恰恰是那把刚好够用的牛刀。原理吃透，面试能讲，实战能落。
