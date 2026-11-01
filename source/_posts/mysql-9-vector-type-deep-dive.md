---
title: 【MySQL 9】VECTOR 类型深度实战：向量存储、距离度量与 Java 客户端落地（附与 pgvector/Milvus 选型对比）
date: 2026-11-01 08:10:00
tags:
  - Java
  - MySQL
  - 向量检索
  - RAG
  - JDBC
  - Embedding
categories:
  - 数据库
author: 东哥
---

# 【MySQL 9】VECTOR 类型深度实战

## 前言

做 RAG 的人都会遇到同一个灵魂拷问：**"我们已经有 MySQL 了，为什么还要再引入一个向量数据库？"**

过去的答案很干脆：**因为 MySQL 存不了向量**。你要么把 `float[]` 塞进 `BLOB` 自己算余弦相似度（全表扫描 + JVM 里算浮点，几十万行就废了），要么上 `pgvector` / Milvus / Qdrant / Redis，多一套运维、多一套权限、多一套备份策略。

**MySQL 9.0 把这个前提打破了一半**：它引入了原生 `VECTOR` 数据类型，以及 `STRING_TO_VECTOR`、`VECTOR_TO_STRING`、`VECTOR_DIM`、`DISTANCE` 一整套函数。你可以直接在 SQL 里写：

```sql
SELECT id, title, DISTANCE(embedding, STRING_TO_VECTOR('[0.12,0.34,...]'), 'EUCLIDEAN') AS d
FROM kb_chunk
WHERE tenant_id = 42
ORDER BY d
LIMIT 10;
```

**注意我说的是"打破了一半"**——因为 MySQL 9.x 的 `VECTOR` **没有 ANN 索引**，`ORDER BY DISTANCE(...)` 是实打实的全表扫描。这意味着它能覆盖的场景有明确边界。

这篇文章讲清楚三件事：**VECTOR 到底怎么存、Java 怎么读写、什么规模下该用 / 不该用**。

---

## 一、VECTOR 的物理存储：它其实就是一段 float 二进制

`VECTOR` 不是一种"魔法类型"，它的本质非常朴素：

- 声明 `VECTOR(n)`，`n` 是**最大维度数**；
- 每个维度占 **4 字节**（单精度 IEEE-754 float32），**小端序（little-endian）** 排列；
- 所以 `VECTOR(1024)` 单行最多占 `1024 × 4 = 4096` 字节；
- 它是**变长**的：你可以往 `VECTOR(1024)` 里存一个 768 维向量，`VECTOR_DIM()` 会告诉你实际维度。

```sql
CREATE TABLE kb_chunk (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tenant_id   BIGINT UNSIGNED NOT NULL,
  doc_id      BIGINT UNSIGNED NOT NULL,
  chunk_no    INT NOT NULL,
  content     TEXT NOT NULL,
  embedding   VECTOR(1024) NOT NULL,
  model       VARCHAR(64) NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_tenant_doc (tenant_id, doc_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

两个设计要点：

**① 一定要把 `model` 字段存下来。** 不同 Embedding 模型的向量**绝对不能混在同一个检索空间里比较**。`bge-m3`（1024 维）和 `text-embedding-3-small`（1536 维）产生的向量，算余弦相似度毫无意义。生产上换模型 = 全量重刷，必须能按 `model` 精确圈定范围。

**② `VECTOR` 在 InnoDB 里是 LOB 化存储的**，和 `TEXT`/`BLOB` 一样可能走 off-page。这带来一个隐性成本：**你 `SELECT *` 的时候会把向量一起读出来**。检索场景请显式列出需要的列，**别 `SELECT *`**——一个 1024 维向量 4KB，10 万行就是 400MB 网络传输。

---

## 二、SQL 侧函数族：怎么算、怎么比、怎么校验

### 2.1 三个基础函数

| 函数 | 作用 | 示例 |
|---|---|---|
| `STRING_TO_VECTOR('[1,2,3]')` | 把文本转成 VECTOR | 手工调试、SQL 里写死小向量 |
| `VECTOR_TO_STRING(v)` | VECTOR 转文本（可读） | 排查、导出、对账 |
| `VECTOR_DIM(v)` | 实际维度 | 写入校验、模型一致性检查 |
| `DISTANCE(a, b, 'EUCLIDEAN')` | 计算距离 | 排序 / 阈值过滤 |

```sql
-- 维度一致性巡检：找出和声明维度不符的脏数据
SELECT id, VECTOR_DIM(embedding) AS dim, model
FROM kb_chunk
WHERE VECTOR_DIM(embedding) <> 1024
LIMIT 100;

-- 看一条向量的前若干维（向量是 LOB，别整条打印）
SELECT id, LEFT(VECTOR_TO_STRING(embedding), 200) FROM kb_chunk LIMIT 1;
```

### 2.2 距离度量怎么选

这是最容易出错的地方。三个概念先摆清楚：

| 度量 | 公式直觉 | 什么时候用 | 排序方向 |
|---|---|---|---|
| 欧氏距离 `EUCLIDEAN` | 两点直线距离 | 向量**已归一化**时，等价于余弦 | 越小越相似 |
| 余弦距离 `COSINE` | `1 - cos θ` | 只关心方向，不关心模长（文本 Embedding 主流） | 越小越相似 |
| 点积 `DOT` | `Σ aᵢbᵢ` | 向量已归一化时等价于余弦；推荐系统里表达"强度" | 越大越相似 |

**关键结论：如果你的 Embedding 已经 L2 归一化（大多数中文 Embedding 模型默认输出归一化向量），`EUCLIDEAN` 和 `COSINE` 的排序结果完全一致**，因为：

```
‖a - b‖² = ‖a‖² + ‖b‖² - 2·a·b = 2 - 2·cosθ   (当 ‖a‖=‖b‖=1)
```

此时用 `EUCLIDEAN` 还能省掉一次开方——`DISTANCE` 内部比较时只需要平方距离。**但注意，MySQL 的 `DISTANCE` 返回的是真实距离（含开方），你没法在 SQL 里直接拿平方距离。**

> ⚠️ 版本差异：`DISTANCE()` 的第三个参数在不同 9.x 小版本里支持的度量集合不同（早期只有 `EUCLIDEAN`，`COSINE`/`DOT` 后续补充）。**上线前务必在你的目标版本上实测**：
> ```sql
> SELECT DISTANCE(STRING_TO_VECTOR('[1,0]'), STRING_TO_VECTOR('[0,1]'), 'COSINE');
> ```
> 报 `ERROR 1235` 就是没这个度量，别硬写。

### 2.3 一个完整的检索 SQL

```sql
SET @q = STRING_TO_VECTOR('[0.013,-0.271,0.884, ... 共 1024 维 ...]');

SELECT
  c.id,
  c.doc_id,
  c.chunk_no,
  LEFT(c.content, 120) AS snippet,
  DISTANCE(c.embedding, @q, 'EUCLIDEAN') AS dist
FROM kb_chunk c
WHERE c.tenant_id = 42          -- ① 先做结构化过滤
  AND c.model = 'bge-m3'        -- ② 锁定模型
  AND c.doc_id IN (101, 102)    -- ③ 缩小候选集
ORDER BY dist
LIMIT 10;
```

**执行计划会清楚地告诉你真相**：

```
+----+-------------+-------+------------+------+------------------+------+---------+------+-------+----------+-----------------------------+
| id | select_type | table | partitions | type | possible_keys    | key  | key_len | ref  | rows  | filtered | Extra                       |
+----+-------------+-------+------------+------+------------------+------+---------+------+-------+----------+-----------------------------+
|  1 | SIMPLE      | c     | NULL       | ref  | idx_tenant_doc   | idx  | 8       | const| 48213 |    10.00 | Using where; Using filesort |
+----+-------------+-------+------------+------+------------------+------+---------+------+-------+----------+-----------------------------+
```

`Using filesort` + `rows=48213` = **扫了 4.8 万行 + 逐行算 1024 维距离**。这就是没有 ANN 索引的代价。

---

## 三、Java 侧落地：Connector/J 怎么读写 VECTOR

### 3.1 依赖与前提

```xml
<dependency>
  <groupId>com.mysql</groupId>
  <artifactId>mysql-connector-j</artifactId>
  <version>9.1.0</version> <!-- 必须 9.x，8.x 不认 VECTOR 类型 -->
</dependency>
```

**三个容易踩的前提：**

1. **Connector/J 必须是 9.x**。8.x 驱动遇到 `VECTOR` 列会抛 `SQLException: Unknown type` 或退化成不可读的字符串。
2. **服务端 `sql_mode` 不要开 `STRICT_TRANS_TABLES` 之外的奇怪限制**（一般没问题，但 `NO_ZERO_DATE` 之类不影响）。
3. **`VECTOR` 不支持在 `WHERE` 里直接 `=` 比较**（浮点比较没意义），也不支持普通索引。

### 3.2 向量 ⇄ byte[]：小端序是唯一正确姿势

这是本文最关键的一段代码。**MySQL 的 VECTOR 是小端序 float32 数组**，用 `ByteBuffer` 时必须 `LITTLE_ENDIAN`：

```java
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class VectorCodec {

    private VectorCodec() {}

    /** float[] -> MySQL VECTOR 的二进制表示（小端序 float32） */
    public static byte[] toBytes(float[] v) {
        ByteBuffer buf = ByteBuffer.allocate(v.length * Float.BYTES)
                                   .order(ByteOrder.LITTLE_ENDIAN);
        for (float f : v) {
            buf.putFloat(f);
        }
        return buf.array();
    }

    /** MySQL VECTOR 的二进制表示 -> float[] */
    public static float[] fromBytes(byte[] bytes) {
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        float[] v = new float[bytes.length / Float.BYTES];
        for (int i = 0; i < v.length; i++) {
            v[i] = buf.getFloat();
        }
        return v;
    }

    /** 兜底：如果驱动把 VECTOR 当字符串返回（形如 "[0.1,0.2,...]"），也能解析 */
    public static float[] fromString(String s) {
        String trimmed = s.trim();
        if (trimmed.startsWith("[")) {
            trimmed = trimmed.substring(1, trimmed.length() - 1);
        }
        if (trimmed.isEmpty()) {
            return new float[0];
        }
        String[] parts = trimmed.split(",");
        float[] v = new float[parts.length];
        for (int i = 0; i < parts.length; i++) {
            v[i] = Float.parseFloat(parts[i].trim());
        }
        return v;
    }
}
```

> **为什么一定要 `LITTLE_ENDIAN`？** x86 是小端，很多人用 `ByteBuffer.allocate().asFloatBuffer().put(v)` 恰好也是小端，所以"碰巧对了"。一旦换到 ARM（Apple Silicon、鲲鹏、Graviton）上的 JDK 默认 `ByteOrder.nativeOrder()` 仍然是小端，但只要你显式写了 `BIG_ENDIAN`，存进去的向量就是**字节反序**的——`VECTOR_DIM` 正常、`VECTOR_TO_STRING` 输出一堆 `NaN` 和 `1e-38` 这类垃圾值。这个 bug 极难发现，因为不报错。

### 3.3 写入

```java
public void upsertChunk(Connection conn, long tenantId, long docId, int chunkNo,
                        String content, float[] embedding, String model) throws SQLException {
    String sql = """
        INSERT INTO kb_chunk (tenant_id, doc_id, chunk_no, content, embedding, model)
        VALUES (?, ?, ?, ?, ?, ?)
        """;
    try (PreparedStatement ps = conn.prepareStatement(sql)) {
        ps.setLong(1, tenantId);
        ps.setLong(2, docId);
        ps.setInt(3, chunkNo);
        ps.setString(4, content);
        ps.setBytes(5, VectorCodec.toBytes(embedding));  // ★ 关键：setBytes
        ps.setString(6, model);
        ps.executeUpdate();
    }
}
```

**用 `setBytes`，不要用 `setString`。** 走 `STRING_TO_VECTOR(...)` 也行，但要把 1024 个 float 拼成 `'[0.123456789,...]'` 这种字符串，**单条 SQL 会膨胀到 12KB+**，解析开销、网络开销、SQL 注入面全都变差。批量写入时差距是数量级的。

**批量写入的正确姿势：**

```java
public void batchInsert(Connection conn, List<ChunkRow> rows) throws SQLException {
    String sql = "INSERT INTO kb_chunk (tenant_id, doc_id, chunk_no, content, embedding, model) " +
                 "VALUES (?, ?, ?, ?, ?, ?)";
    try (PreparedStatement ps = conn.prepareStatement(sql)) {
        int i = 0;
        for (ChunkRow r : rows) {
            ps.setLong(1, r.tenantId());
            ps.setLong(2, r.docId());
            ps.setInt(3, r.chunkNo());
            ps.setString(4, r.content());
            ps.setBytes(5, VectorCodec.toBytes(r.embedding()));
            ps.setString(6, r.model());
            ps.addBatch();
            if (++i % 500 == 0) {
                ps.executeBatch();
            }
        }
        ps.executeBatch();
    }
}
```

配合 JDBC URL 参数：

```
jdbc:mysql://host:3306/kb?rewriteBatchedStatements=true&useServerPrepStmts=true&cachePrepStmts=true
```

`rewriteBatchedStatements=true` 会把 500 条 insert 合并成多值 `INSERT`，**批量写入吞吐通常提升 3~10 倍**。但注意：合并后的单条 SQL 会很大（500 × 4KB 向量 = 2MB），要留意 `max_allowed_packet`（默认 64MB，一般够）。

### 3.4 检索：把距离计算放到 MySQL，别放到 JVM

**错误做法（新手常犯）：**

```java
// ❌ 把整表向量捞到 JVM 里算余弦 —— 这是自杀
List<float[]> all = queryAllEmbeddings(conn);  // 50 万 × 4KB = 2GB
all.sort(comparing(v -> cosine(v, query)));
```

**正确做法：**

```java
public List<ChunkHit> search(Connection conn, long tenantId, float[] queryVec,
                             String model, int topK, double maxDist) throws SQLException {
    // 度量名不要拼进 SQL！白名单校验后再拼接
    String metric = "EUCLIDEAN";
    String sql = """
        SELECT id, doc_id, chunk_no, LEFT(content, 120) AS snippet,
               DISTANCE(embedding, ?, '%s') AS dist
        FROM kb_chunk
        WHERE tenant_id = ? AND model = ?
        ORDER BY dist
        LIMIT ?
        """.formatted(metric);

    List<ChunkHit> hits = new ArrayList<>();
    try (PreparedStatement ps = conn.prepareStatement(sql)) {
        ps.setBytes(1, VectorCodec.toBytes(queryVec));
        ps.setLong(2, tenantId);
        ps.setString(3, model);
        ps.setInt(4, topK);
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                double dist = rs.getDouble("dist");
                if (dist <= maxDist) {
                    hits.add(new ChunkHit(rs.getLong("id"), rs.getLong("doc_id"),
                            rs.getInt("chunk_no"), rs.getString("snippet"), dist));
                }
            }
        }
    }
    return hits;
}
```

注意 `DISTANCE(embedding, ?)` 的第一个参数直接绑 `byte[]`——驱动会把它按 VECTOR 类型的二进制格式传过去，**不需要 `STRING_TO_VECTOR` 包一层**。

**但更稳的写法是显式转换**，避免不同驱动版本对 `byte[]` 的类型推断差异：

```sql
DISTANCE(embedding, STRING_TO_VECTOR(?))  -- 绑字符串，稳但慢
-- 或
DISTANCE(embedding, CAST(? AS VECTOR)) -- 视版本支持情况
```

我的建议：**先在目标环境跑通 `setBytes` 直绑，跑不通再退回显式转换。**

---

## 四、性能现实：没有 ANN 索引意味着什么

这是选型时最该算清楚的一笔账。

### 4.1 一次检索的真实成本

假设 100 万条 chunk，每条 1024 维：

```
单次距离计算 = 1024 次乘加 ≈ 1024 FLOP（含 3 次减法、3 次乘、2 次加 ≈ 8×1024 ≈ 8K FLOP 的尺度）
全表 100 万行   = 约 8 × 10^9 次浮点运算
单核现代 CPU   ≈ 5~20 GFLOP/s（标量，未向量化）
=> 单次查询 0.5 ~ 2 秒，且 CPU 打满一个核
```

**这就是为什么 100 万行以上基本不可用。** 5 万行以内，单次查询 30~100ms，勉强能接受（配合缓存）。

### 4.2 官方的替代方案：HeatWave GenAI 的向量索引

MySQL 官方在 **HeatWave（托管服务）** 里提供了 `VECTOR` 的 **ANN 索引**（基于 HNSW 类实现，通过 `CREATE VECTOR INDEX` 或 HeatWave 的 AutoML 能力）。但那是 **HeatWave 云服务** 的能力，**自建 MySQL Community/Enterprise 9.x 没有这个索引**。

所以落地前必须确认：

```sql
-- 自建版尝试建向量索引，通常会报错或忽略
CREATE VECTOR INDEX idx_vec ON kb_chunk (embedding) OPTIONS ('distance'='EUCLIDEAN');
-- HeatWave 上可用；自建版 → ERROR 1178 / 不支持
```

> 结论：**"MySQL 9 有 VECTOR 类型" ≠ "MySQL 9 能替代向量数据库"**。前者是类型 + 函数，后者需要 ANN 索引 + 距离下推 + 分片路由。

### 4.3 什么时候该用 MySQL VECTOR，什么时候别用

| 场景 | 数据量 | 推荐 | 理由 |
|---|---|---|---|
| 单机内部工具 / PoC | < 1 万 | ✅ MySQL VECTOR | 零新增组件，够用 |
| 按明确维度强过滤（租户/文档/时间） | 5 万以内 | ✅ MySQL VECTOR | 过滤后候选集小，全扫可接受 |
| 多租户 SaaS，租户内几千条 | 总量大但单租户小 | ✅ MySQL VECTOR | 过滤性极强，天然分片 |
| 通用语义搜索 | 50 万+ | ❌ 换 pgvector/Milvus | 全表扫描扛不住 |
| 高并发在线检索（QPS > 50） | 任意 | ⚠️ 慎重 | 每次查询打满一核 |
| 需要混合检索 + Rerank | 任意 | ⚠️ 建议专门向量库 | MySQL 只能做粗排 |

### 4.4 与主流方案横向对比

| 方案 | ANN 索引 | 过滤能力 | 事务/一致性 | 运维成本 | Java 客户端成熟度 | 适合规模 |
|---|---|---|---|---|---|---|
| **MySQL 9 VECTOR** | ❌（自建） | ★★★★★ SQL 全能力 | ★★★★★ 同一事务 | ★（复用现有） | ★★★★★ JDBC | ≤ 5 万 / 强过滤 |
| **pgvector** | ✅ HNSW / IVFFlat | ★★★★☆ SQL | ★★★★★ 同一事务 | ★★ | ★★★★☆ JDBC | 十万~百万 |
| **Milvus** | ✅ HNSW/IVF/DiskANN | ★★★☆ 标量过滤 | ★★☆ | ★★★★ | ★★★★☆ | 千万~十亿 |
| **Qdrant** | ✅ HNSW + 量化 | ★★★★ | ★★☆ | ★★★ | ★★★★☆ | 百万~千万 |
| **Redis Vector Set** | ✅ HNSW | ★★☆（属性过滤是后置的） | ★★☆ | ★★ | ★★★★☆（Lettuce/Jedis） | 百万 |
| **Elasticsearch kNN** | ✅ HNSW | ★★★★★ | ★★★☆ | ★★★★ | ★★★★★ | 百万~千万 |

**我的实际建议：**

- 已经有 MySQL 且在写同一张业务表（比如给工单/商品加语义搜索），**数据量 < 5 万时直接上 VECTOR**，省一套组件。
- 数据量上去后，**别搞"双写两个库"**，而是用 **"MySQL 存业务 + 向量库存向量，通过 outbox/binlog（Canal）同步"**，这是最省心的架构。
- 千万别在 MySQL 里既存业务又指望它做 ANN——那是 HeatWave 的活。

---

## 五、工程实践：把全表扫描压到可接受

如果确定要用 MySQL VECTOR，这几招能把性能拉回来：

### 5.1 先过滤，再算距离（最重要）

`schema` 上要有能让优化器先缩小候选集的索引。上面的 `idx_tenant_doc (tenant_id, doc_id)` 就起作用了——把 100 万行先过滤成 5000 行，再算距离，耗时从 1 秒降到 40ms。

**反例：**

```sql
-- ❌ 没有可用过滤条件，全表扫
SELECT id, DISTANCE(embedding, ?, 'EUCLIDEAN') d FROM kb_chunk ORDER BY d LIMIT 10;
```

### 5.2 两阶段检索：粗排 + 精排

```java
// 第一阶段：MySQL 全扫拿 top 50（便宜的距离度量）
List<ChunkHit> coarse = search(conn, tenantId, qv, model, 50, 1.2);

// 第二阶段：Reranker 精排（cross-encoder，只算 50 条）
List<ChunkHit> reranked = reranker.rerank(query, coarse, 10);
```

`Reranker` 只处理 50 条，成本可控；MySQL 只负责"别把相关的漏掉"。这是 MySQL VECTOR 最合理的用法。

### 5.3 结果缓存 + 向量指纹

```java
String key = "kb:search:" + tenantId + ":" + model + ":"
           + Hashing.murmur3_128().hashBytes(VectorCodec.toBytes(qv)).toString();
```

用**向量本身的哈希**做缓存 key（而不是 query 文本），这样同义改写也能命中——但要注意语义缓存误命中的风险，缓存 TTL 别太长（5~15 分钟）。

### 5.4 分区表分摊扫描

```sql
ALTER TABLE kb_chunk PARTITION BY HASH(tenant_id) PARTITIONS 16;
```

按租户哈希分区后，**带 `tenant_id` 等值条件的查询能被分区裁剪**，只扫 1/16 的数据。这是 MySQL 上把"全表扫"变"分区扫"的最有效手段。

> 注意：分区表要求所有唯一键都包含分区键。上面的表 `PRIMARY KEY (id)` 不含 `tenant_id`，会被拒绝，需要改成 `PRIMARY KEY (id, tenant_id)`。这个坑很多人第一次建分区表就撞上。

### 5.5 监控：盯住这几项

```sql
-- 慢查询里出现 DISTANCE 的，基本都是隐患
SELECT digest_text, count_star, avg_timer_wait/1e9 AS avg_ms
FROM performance_schema.events_statements_summary_by_digest
WHERE digest_text LIKE '%DISTANCE%'
ORDER BY avg_timer_wait DESC LIMIT 10;
```

告警线建议：`DISTANCE` 类查询 P99 > 300ms 就报警——因为它是 CPU bound，一旦并发上来会直接把实例打满。

---

## 六、面试追问与踩坑清单

**Q1：MySQL 9 的 VECTOR 底层是什么类型？**

本质是变长的 float32 二进制串（小端序），声明 `VECTOR(n)` 表示最大 n 维。它是 LOB 化存储，不走行内。

**Q2：为什么 `ORDER BY DISTANCE(...)` 很慢？**

因为自建 MySQL 9.x **没有向量索引**，`DISTANCE` 是逐行计算的标量函数，必须全表（或全分区/全过滤结果集）扫描 + filesort。HeatWave 才有 ANN 索引。

**Q3：Embedding 归一化之后，欧氏距离和余弦距离还有区别吗？**

排序上完全等价（‖a-b‖² = 2-2cosθ），但**绝对数值不同**：欧氏距离范围 `[0,2]`，余弦距离范围 `[0,2]` 也一样，映射关系是 `d_euclid = sqrt(2 * d_cos)`。所以**阈值不能混用**：你用余弦调出来的 `0.3` 阈值，换成欧氏得改成 `sqrt(0.6) ≈ 0.775`。

**Q4：能不能给 VECTOR 列建普通索引？**

不能。浮点数组没有有意义的全序关系。只能建函数索引做辅助（比如对 `VECTOR_DIM` 建索引做维度巡检），但那和检索无关。

**Q5：多个模型的向量能放同一张表吗？**

能放，但**不能比较**。必须用 `model` 字段强隔离，检索时带上 `model = ?` 条件。更严格的做法是按模型分表。

**踩坑 1：字节序搞反。**
写入用 `BIG_ENDIAN`，读出来全是 `NaN` / `1e-38`。**永远显式 `.order(ByteOrder.LITTLE_ENDIAN)`**。

**踩坑 2：驱动版本不对。**
Connector/J 8.x 读 `VECTOR` 列会抛异常或返回乱码。必须 9.x。

**踩坑 3：`SELECT *` 带出向量。**
一张 100 万行的表，`SELECT *` 会把 4GB 向量拉进 JVM。**永远显式列名**。

**踩坑 4：以为有索引。**
在自建版上建了 `CREATE VECTOR INDEX` 以为生效，实际被忽略。**用 `SHOW INDEX FROM kb_chunk` 确认，并用 `EXPLAIN` 看是否 `Using filesort`。**

**踩坑 5：阈值沿用 pgvector 的参数。**
不同库的距离实现细节（开方与否、是否含归一化）不同，**换库必须重新标定阈值**，别信"直接搬过去"。

**踩坑 6：分区表主键不含分区键。**
`PRIMARY KEY (id)` + `PARTITION BY HASH(tenant_id)` 直接报错，必须 `PRIMARY KEY (id, tenant_id)`。

---

## 七、总结

| 结论 | 说明 |
|---|---|
| VECTOR 是"类型 + 函数"，不是"向量数据库" | 自建 MySQL 9.x 没有 ANN 索引，只有 HeatWave 有 |
| 甜点区 | 数据量 ≤ 5 万，或过滤性极强的多租户场景 |
| Java 落地核心 | Connector/J 9.x + `setBytes` + **小端序 float32** |
| 性能三板斧 | 先过滤（索引/分区）→ 两阶段（粗排+重排）→ 结果缓存 |
| 规模化路线 | MySQL 存业务 + 专用向量库存向量，binlog/outbox 同步，别双写 |

MySQL 加 `VECTOR` 的真正意义，不是"干掉向量数据库"，而是**让 80% 的中小规模 RAG 应用少一个组件**。当你只有 3 万条知识库 chunk、QPS 个位数、还要按部门/权限做复杂过滤时，把向量老老实实放在业务库里，比维护一套 Milvus 集群划算得多。

但一旦你的规模跨过十万级，或者开始需要并发在线检索，就该认真考虑专门方案了——**这不是 MySQL 不行，而是"通用关系库 + 逐行标量函数"这个组合，天生不适合做暴力向量检索。**

> 下一篇会讲 **pgvector 的 HNSW 参数调优**（`m` / `ef_construction` / `ef_search` 的取舍曲线），以及混合检索里 BM25 + kNN 的 RRF 融合在 Java 侧怎么实现。
