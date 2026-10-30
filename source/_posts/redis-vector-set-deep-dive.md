---
title: 【Redis 8 新特性】Vector Set 深度解析：HNSW、属性过滤与 Java 客户端实战
date: 2026-10-30 08:10:00
tags:
  - Redis
  - 向量数据库
  - HNSW
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Redis 8 新特性】Vector Set 深度解析：HNSW、属性过滤与 Java 客户端实战

## 前言

做 RAG 或语义检索的团队，过去在 Redis 上的选择只有一条路：装 RediSearch 模块，用 `FT.CREATE` 建索引、`FT.SEARCH` 查询。这套方案能力很强，但代价是要维护一套索引 schema（字段类型、向量维度、距离度量、HNSW 参数），改维度就得重建索引，运维心智负担不轻。

Redis 8 给出了第二条路：**Vector Set**——一个原生数据类型，命令族前缀 `V`（`VADD` / `VSIM` / `VEMB` / `VINFO` / `VLINKS` / `VDIM` / `VCARD` / `VREM` / `VRANDMEMBER`）。它把"集合 + 向量 + 属性"三件事压进一个 key，不需要预先建索引、不需要管理 schema，写完就能查。

这篇文章从数据结构、HNSW 底层、属性过滤语法，一路写到 Java 客户端落地和生产踩坑。

<!-- more -->

## 一、为什么需要一个新的数据类型

先看传统做法和 Vector Set 的差别：

| 维度 | RediSearch（FT.CREATE） | Vector Set（VADD/VSIM） |
|---|---|---|
| 是否需预建索引 | 需要 `FT.CREATE` | 不需要，`VADD` 即建 |
| 维度变更 | 必须删索引重建 | 每个 key 独立，换 key 即可 |
| 存储内容 | 向量 + HASH 文档（分离） | 向量 + 属性 + 向量本身（一体） |
| 属性过滤 | `FT.SEARCH @field:{...}` | `VSIM ... FILTER .year > 2020` |
| 距离度量 | L2 / IP / COSINE 可选 | 固定 COSINE（内部归一化） |
| 删除元素 | 需 `FT.DEL` + 删 HASH | `VREM` / `VREM ... ALL` |
| 过期 | key 级 TTL | **不支持 TTL**（重要限制） |
| 适用规模 | 千万级、复杂查询 | 百万级、单 key 单集合 |

用一句话概括：**RediSearch 是"搜索引擎"，Vector Set 是"向量集合"**。前者适合复杂混合检索，后者适合"一把 key 装完一个小型语义索引"的场景，比如单个用户的会话记忆、单个租户的知识片段、单次任务候选集。

## 二、命令族全览

```bash
# 写入：元素 id + 向量 + 可选属性（JSON）
VADD myset VALUES 3 0.1 0.2 0.3 doc:1
VADD myset VALUES 3 0.4 0.5 0.6 doc:2 year 2026 lang java

# 查询：返回最相似的 k 个，带相似度分数
VSIM myset VALUES 3 0.1 0.2 0.31 WITHSCORES COUNT 5
# 1) "doc:1"
# 2) "1"                      <- 相似度（cosine，越大越像）

# 用已有元素做查询（推荐，避免重复传向量）
VSIM myset ELEM doc:1 WITHSCORES COUNT 5

# 带属性过滤
VSIM myset VALUES 3 0.1 0.2 0.31 FILTER '.year > 2024 && .lang == "java"' COUNT 10

# 取回向量本体
VEMB myset doc:1

# 元信息：维度、元素数、HNSW 参数
VINFO myset
# 1) "quant-type"  2) "int8"
# 3) "vector-dim"  4) (integer) 3
# 5) "hnsw-m"      6) (integer) 16
# 7) "max-node-uids" 8) (integer) 1000000
# 9) "size"        10) (integer) 2

# 图结构调试：某元素在各层的邻居
VLINKS myset doc:1 WITHSCORES

# 其他
VDIM myset          # 维度
VCARD myset         # 元素数量
VREM myset doc:1    # 删除
VRANDMEMBER myset 3 # 随机取（负样本挖掘用）
```

几个容易忽略的细节：

1. **`VADD` 的 id 是字符串**，但内部会映射为 64 位整数 UID 存 HNSW 节点。所以 `VINFO` 里的 `max-node-uids` 是上限，超过需要分片。
2. **相似度是 cosine 的变体**：Redis 内部先把向量归一化，再算内积，返回值范围 `[-1, 1]`。**不是距离**，越大越相似，这点和 Milvus 的 `distance` 语义相反，写代码时极易搞反排序方向。
3. **属性是扁平 JSON**，只支持标量（string/number/bool），不支持嵌套对象和数组。要存数组就自己序列化成字符串，过滤时用 `==`。
4. **Vector Set 不支持 TTL**。`EXPIRE myset 3600` 会直接报错。需要过期语义只能整 key 删除或按业务自己清理。

## 三、底层：HNSW 在这个类型里长什么样

Vector Set 用的是 **HNSW（Hierarchical Navigable Small World）** 图索引，加上 **int8 标量量化** 压缩。

### 3.1 分层图与随机层级

每个插入的向量会被随机分配一个层级 `l`，服从指数衰减分布：

```text
P(level = l) = (1 - 1/M)^l * (1/M)
```

`M`（`hnsw-m`，默认 16）是每个节点在每层的最大出边数。层级越高，节点越少，作用越像"高速公路"：

```text
Layer 2:        A ---------------- F            （稀疏，长跳）
Layer 1:     B -- A -- C ---- E -- F -- G       （中等密度）
Layer 0:  H - B - A - C - D - E - F - G - I     （全量，短跳）
```

查询时从最高层入口点开始贪心下降：每层找"比当前更近的邻居"就跳过去，跳不动了就降一层，最终在 Layer 0 做 `ef` 宽度的候选集搜索。复杂度约 `O(log N)`，这就是 HNSW 比暴力扫描快几个数量级的原因。

### 3.2 量化：int8 换来的内存账

`VINFO` 里的 `quant-type` 通常是 `int8`。假设 1536 维 float32：

```text
float32: 1536 * 4 = 6144 字节/向量
int8   : 1536 * 1 = 1536 字节/向量   -> 省 75%
```

100 万条向量：float32 需要约 5.9GB，int8 只要 1.5GB，加上 HNSW 图结构（约 `N * M * 2 * 层数` 的邻居指针）大概再加 1~2GB。**这也是 Vector Set 定位"百万级单 key"的现实原因**——再大就该上专业向量库了。

量化的代价是**召回率轻微下降**（通常 1~3 个百分点）。对大多数语义检索场景可以接受，但如果是"精确去重"这类场景要慎重。

## 四、属性过滤：语法与陷阱

`FILTER` 接受一个表达式字符串，字段名用 `.` 前缀引用：

```bash
VSIM idx VALUES 3 0.1 0.2 0.3 \
  FILTER '.category == "docs" && .score >= 0.8 && .lang != "py"' \
  COUNT 10 WITHSCORES
```

支持的运算符：

| 类别 | 语法 | 示例 |
|---|---|---|
| 比较 | `== != > >= < <=` | `.score >= 0.8` |
| 逻辑 | `&& \|\| !` | `.a == 1 && !(.b == 2)` |
| 字符串 | `==` / `!=` | `.lang == "java"` |
| 括号 | `( )` | `(.a == 1 \|\| .b == 2)` |

**坑 1：过滤是"后置过滤（post-filter）"还是"前置过滤（pre-filter）"？**

Vector Set 的实现是**先按 HNSW 检索出较大的候选集，再应用 FILTER**。这意味着：如果过滤条件很严（比如只命中 1% 的数据），你可能拿到远少于 `COUNT` 的结果，甚至空结果——因为前 N 个候选全被过滤掉了。

实践中要这样做：

```java
// 过滤条件严格时，先放大 COUNT，再在应用层截断
int requested = strictFilter ? Math.min(count * 10, 1000) : count;
List<ScoredId> raw = vectorSet.sim(queryVec, requested, filter);
List<ScoredId> result = raw.stream().limit(count).toList();
```

**坑 2：数值比较的隐式类型。**

VADD 时如果属性写成 `"score": "0.8"`（字符串），`FILTER .score >= 0.8` 会静默不命中。写属性时保证数字是数字类型。

**坑 3：属性更新不是原子的。**

Vector Set 没有"更新属性"的命令。要改属性只能 `VREM` + `VADD`，中间有一小段索引不一致窗口。高频更新的场景（比如文档热度分）建议把易变属性留在 MySQL/Redis Hash 里，Vector Set 只存稳定属性。

## 五、Java 客户端落地

Vector Set 是 Redis 8 的新命令，客户端支持参差不齐。截至本文写作时：

| 客户端 | 支持情况 | 建议 |
|---|---|---|
| Jedis 6.x | 部分命令有封装 | 用 `sendCommand` 兜底 |
| Lettuce 6.5+ | 有 `VectorSetCommands` 接口 | 首选 |
| redis-py | 支持较全 | Python 侧没问题 |
| Spring Data Redis | 尚未提供 Repository 抽象 | 用 `RedisTemplate.execute` |

用 Lettuce 的原生命令接口最稳：

```java
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.protocol.CommandArgs;
import io.lettuce.core.protocol.ProtocolKeyword;
import io.lettuce.core.codec.ByteArrayCodec;
import io.lettuce.core.codec.StringCodec;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public class RedisVectorSetClient {

    private final StatefulRedisConnection<String, String> conn;

    public RedisVectorSetClient(StatefulRedisConnection<String, String> conn) {
        this.conn = conn;
    }

    /** VADD key VALUES dim v1 v2 ... id [attr value ...] */
    public void add(String key, String id, float[] vec, List<String> attrs) {
        CommandArgs<String, String> args = new CommandArgs<>(StringCodec.UTF8)
                .add("VADD").add(key).add("VALUES").add(vec.length);
        for (float v : vec) {
            args.add(Float.toString(v));
        }
        args.add(id);
        if (attrs != null) {
            for (String a : attrs) {
                args.add(a);
            }
        }
        conn.sync().dispatch(Cmd.VADD, args);
    }

    /** VSIM key VALUES dim v... [FILTER expr] COUNT n WITHSCORES */
    public List<ScoredId> sim(String key, float[] vec, int count, String filterExpr) {
        CommandArgs<String, String> args = new CommandArgs<>(StringCodec.UTF8)
                .add("VSIM").add(key).add("VALUES").add(vec.length);
        for (float v : vec) {
            args.add(Float.toString(v));
        }
        if (filterExpr != null && !filterExpr.isBlank()) {
            args.add("FILTER").add(filterExpr);
        }
        args.add("COUNT").add(count).add("WITHSCORES");

        List<Object> raw = conn.sync().dispatch(Cmd.VSIM, args).asList();

        // 返回是 [id, score, id, score, ...] 的平铺数组
        List<ScoredId> out = new ArrayList<>(raw.size() / 2);
        for (int i = 0; i + 1 < raw.size(); i += 2) {
            out.add(new ScoredId(
                    raw.get(i).toString(),
                    Double.parseDouble(raw.get(i + 1).toString())));
        }
        return out;
    }

    /** 批量导入：用 pipeline 把 RTT 打下来 */
    public void bulkAdd(String key, List<float[]> vectors, List<String> ids) {
        var batch = conn.async();
        for (int i = 0; i < vectors.size(); i++) {
            float[] v = vectors.get(i);
            CommandArgs<String, String> args = new CommandArgs<>(StringCodec.UTF8)
                    .add("VADD").add(key).add("VALUES").add(v.length);
            for (float x : v) {
                args.add(Float.toString(x));
            }
            args.add(ids.get(i));
            batch.dispatch(Cmd.VADD, args);
        }
        batch.flushCommands();
    }

    public record ScoredId(String id, double score) {}

    /** 自定义命令类型，避免依赖客户端是否已封装 */
    enum Cmd implements ProtocolKeyword {
        VADD, VSIM, VEMB, VINFO, VREM, VCARD, VDIM, VLINKS;

        private final byte[] bytes = name().getBytes(StandardCharsets.US_ASCII);

        @Override
        public byte[] getBytes() { return bytes; }
    }
}
```

Spring Boot 里更实际的封装方式：

```java
@Component
public class SemanticMemoryStore {

    private final StringRedisTemplate redis;
    private final EmbeddingClient embedding;   // 你的 embedding 服务/Spring AI 封装

    public SemanticMemoryStore(StringRedisTemplate redis, EmbeddingClient embedding) {
        this.redis = redis;
        this.embedding = embedding;
    }

    public void remember(String userId, String memoryId, String text, Map<String, Object> meta) {
        float[] vec = embedding.embed(text);
        String key = "mem:" + userId;

        List<String> args = new ArrayList<>();
        args.add("text");
        args.add(text);
        meta.forEach((k, v) -> {
            args.add(k);
            args.add(String.valueOf(v));
        });

        redis.execute((RedisCallback<Void>) connection -> {
            byte[][] cmd = buildVadd(key, memoryId, vec, args);
            connection.execute("VADD", cmd);
            return null;
        });
    }

    public List<String> recall(String userId, String query, int topK) {
        float[] qv = embedding.embed(query);
        String key = "mem:" + userId;
        // 过滤条件收紧时放大候选（见"坑 1"）
        int candidates = Math.max(topK * 5, 50);

        List<Object> raw = redis.execute((RedisCallback<List<Object>>) connection ->
                connection.execute("VSIM", buildVsim(key, qv, candidates)), true);

        List<String> ids = new ArrayList<>();
        for (int i = 0; i + 1 < raw.size(); i += 2) {
            double score = Double.parseDouble(raw.get(i + 1).toString());
            if (score >= 0.75) {          // 相似度阈值，注意越大越像
                ids.add(raw.get(i).toString());
            }
        }
        return ids;
    }

    private byte[][] buildVadd(String key, String id, float[] vec, List<String> attrs) {
        List<byte[]> parts = new ArrayList<>();
        parts.add("VADD".getBytes());
        parts.add(key.getBytes());
        parts.add("VALUES".getBytes());
        parts.add(String.valueOf(vec.length).getBytes());
        for (float v : vec) parts.add(Float.toString(v).getBytes());
        parts.add(id.getBytes());
        for (String a : attrs) parts.add(a.getBytes());
        return parts.toArray(new byte[0][]);
    }

    private byte[][] buildVsim(String key, float[] vec, int count) {
        List<byte[]> parts = new ArrayList<>();
        parts.add("VSIM".getBytes());
        parts.add(key.getBytes());
        parts.add("VALUES".getBytes());
        parts.add(String.valueOf(vec.length).getBytes());
        for (float v : vec) parts.add(Float.toString(v).getBytes());
        parts.add("COUNT".getBytes());
        parts.add(String.valueOf(count).getBytes());
        parts.add("WITHSCORES".getBytes());
        return parts.toArray(new byte[0][]);
    }
}
```

> 注意：不同 Lettuce 版本 `dispatch` / `execute` 的签名差异较大。如果编译不过，直接用 `io.lettuce.core.output.*` 自定义 `CommandOutput` 更稳，或者退到 Jedis 的 `sendCommand(ProtocolCommand, byte[]...)`。

## 六、生产要点

### 6.1 内存估算公式

```text
单 key 内存 ≈ N * (dim * 1B * 1.1)          // 量化向量
           + N * M * 2 * 4B * 平均层数       // HNSW 邻居表
           + 属性存储（约 50~200B/条）
           + id 映射表（约 60B/条）
```

100 万条 768 维、M=16：约 `768MB + 512MB + 150MB ≈ 1.4GB`。加上 Redis 自身开销和复制缓冲区，**单节点建议不超过 2~3 个此类 key**。

### 6.2 写入性能

`VADD` 是**同步构建图**的操作，比 `SET` 慢一到两个数量级。实测单线程约 3k~8k ops/s（M=16，768 维）。批量导入时：

- 用 pipeline，把 RTT 摊薄（提升 5~10 倍）
- 分批发，每批 500~1000 条，避免阻塞主线程
- 大 key 首次构建建议在低峰期或独立实例上做，构建完再迁过去（`DUMP`/`RESTORE` 或 `MIGRATE`）

### 6.3 复制与持久化

Vector Set 走标准 RDB/AOF 路径，可以正常主从复制。但要注意：**AOF rewrite 时大 key 会导致重写耗时变长**，`aof-rewrite-incremental-fsync yes` 要打开；RDB `save` 时 fork 的 COW 也可能因为大 key 触发内存翻倍，`vm.overcommit_memory=1` 必须配。

### 6.4 与主库的一致性

典型架构是"MySQL 存原文 + Redis Vector Set 存向量"，双写必然有不一致窗口。可靠的模式是**以 MySQL 为准 + 补偿队列**：

```text
写入 MySQL（事务提交）
   -> 发 MQ（本地消息表保证不丢）
      -> 消费者 VADD/VSIM 更新
         -> 失败重试 3 次 -> 落死信 -> 定时对账（按 updated_at 增量补救）
```

## 七、踩坑实录

**坑 A：相似度当距离用。**

```java
// 错误：以为越小越像，按升序排了
list.sort(Comparator.comparingDouble(ScoredId::score));
```

`VSIM` 返回的是 cosine 相似度，**越大越像**。而且它内部归一化过，你传原始未归一化的向量也没关系。

**坑 B：`VADD` 重复 id 的行为。**

同 id 再次 `VADD` 会**覆盖**（不是新增），但 HNSW 图里旧节点的邻居边不会立即清理，会留下"幽灵边"，影响召回质量。频繁更新的场景建议换 id（如 `docId:version`），旧版本靠 `VREM` 或整 key 重建清理。

**坑 C：集群模式下 key 必须带 hash tag。**

```text
Vector Set 是单 key 结构，但 VSIM + FILTER + 多 key 事务操作会跨槽。
集群下用 {user:123}:mem 这样的 hash tag 保证同槽。
```

**坑 D：维度不一致直接报错。**

`VADD` 第一个元素的维度决定了整个 key 的维度，后续传不同维度会报 `WRONGTYPE Vector set dimensionality mismatch`。换 embedding 模型（比如从 768 换到 1024）必须换 key 名，**没有在线改维度的办法**。

## 八、面试常见追问

**Q1：Vector Set 和 RediSearch 的向量索引怎么选？**

看查询复杂度。需要多字段组合过滤、全文 + 向量混合检索、聚合统计 → RediSearch。只需要"给一个 key 里的向量做 top-k"、不想管 schema、想快速上线 → Vector Set。规模上 RediSearch 能撑千万级，Vector Set 现实上限是百万级单 key。

**Q2：HNSW 的 `M` 和 `ef` 分别影响什么？**

`M` 是每层最大出边数，越大图越稠密、召回越高、内存和构建时间越大。`ef_construction` 控制建图时的候选队列宽度，影响索引质量；`ef_runtime`（查询时）控制搜索候选宽度，影响召回与延迟的权衡。经验值：`M=16~32`，`ef_construction=200`，`ef_runtime=64~128`。

**Q3：为什么 HNSW 内存占用高？有没有替代？**

图结构要存每个节点的邻居列表，`N * M * 4B * 层数`。替代方案是 **IVF-PQ**（倒排 + 乘积量化），内存能降一个数量级，但召回和需要训练（聚类）是代价。Redis Vector Set 选了 HNSW + int8 量化，是在"召回/内存/易用性"三者间取平衡。

**Q4：向量库在 RAG 里是不是必须的？**

不是。10 万条以内、更新不频繁的场景，pgvector 或 MySQL 8.0 的 `VECTOR` 类型（社区插件）就够；百万级选 Redis Vector Set / Qdrant；千万级以上再上 Milvus。向量库的引入成本主要在运维和一致性，不在查询。

## 九、总结

| 关注点 | 结论 |
|---|---|
| 定位 | 单 key 内嵌的小型语义索引，不是通用向量数据库 |
| 优势 | 零 schema、命令极简、与现有 Redis 基础设施复用 |
| 硬限制 | 不支持 TTL、维度不可变、无属性更新、百万级上限 |
| Java 落地 | Lettuce 原生命令 > Jedis > Spring Data Redis（暂无抽象） |
| 生产关键 | 候选集放大 + 相似度方向 + 版本化 id + 补偿队列 |

Vector Set 的价值不在于"替代 Milvus"，而在于把"给一小撮数据加个语义检索"的成本从"部署一套向量库"降到"一条 VADD"。对 Java 团队来说，这意味着 RAG 的 PoC 阶段可以直接复用现有的 Redis 集群，把工程复杂度压到最低——这往往比多 5% 的召回率重要得多。
