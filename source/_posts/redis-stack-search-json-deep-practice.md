---
title: 【Redis 实战】Redis Stack 深度实战：RediSearch 全文检索、RedisJSON 与混合查询
date: 2026-10-26 08:05:00
tags:
  - Redis
  - RediSearch
  - RedisJSON
  - 搜索引擎
  - 向量检索
  - Java
categories:
  - 中间件
author: 东哥
---

# 【Redis 实战】Redis Stack 深度实战：RediSearch 全文检索、RedisJSON 与混合查询

## 前言

一个真实的排查现场：商品列表页要求「关键词搜索 + 类目筛选 + 价格区间 + 按销量排序 + 分页」，团队最初用 `KEYS prefix:*` 加 Java 内存过滤，QPS 一上 200 就打满 CPU；后来换成 ES，又背上了集群运维、数据同步、双写一致性的包袱。

这类「数据量中等、查询维度多、要求毫秒级」的场景，Redis Stack 往往是个被低估的选项：数据本来就在 Redis 里，加个索引就能做全文检索、标签过滤、数值范围、地理位置，甚至向量相似度检索。

这篇文章把 RedisJSON、RediSearch、混合查询、向量检索和 Java 落地一次讲透，最后给出生产踩坑清单和面试追问。

## 一、Redis Stack 到底是什么

Redis Stack 不是「另一个数据库」，而是 Redis + 一组官方模块的打包发行版：

| 模块 | 作用 | 典型场景 |
|---|---|---|
| RedisJSON | 原生 JSON 文档类型，支持 JSONPath 读写子字段 | 商品详情、用户画像、配置文档 |
| RediSearch | 二级索引 + 全文检索 + 聚合 + 向量检索 | 搜索列表、筛选、去重、KNN |
| RedisTimeSeries | 时间序列存储与降采样 | 监控指标、埋点聚合 |
| RedisBloom | 布隆过滤器、Cuckoo、TopK、Count-Min Sketch | 去重、UV 估算、热词 |
| RedisGears | 服务端函数（部分版本） | 触发器、批处理 |

关键认知：**这些是模块，不是插件化的「外挂」**。索引由 Redis 自己维护，写入时同步更新，所以不存在「DB 与索引双写不一致」的问题——这是它相对 ES 最大的工程优势。

代价也要说清楚：

- 索引占内存。一个 TEXT 字段的倒排索引可能比原数据大 1~3 倍。
- 集群模式下 RediSearch 的索引是**分片级**的，跨槽聚合需要客户端或代理层合并。
- 持久化仍靠 RDB/AOF，重启后索引需要重建（Redis 会从数据重建，大库启动会变慢）。

## 二、RedisJSON：把「字符串缓存」升级成「可查询文档」

### 2.1 基本操作

```bash
# 写入整个文档
JSON.SET product:1001 $ '{"id":1001,"name":"机械键盘 87 键","category":"peripheral","price":399.00,"stock":120,"tags":["键盘","无线","办公"],"attrs":{"switch":"红轴","layout":"87"}}'

# 只读子字段（JSONPath）
JSON.GET product:1001 $.name $.price
# ["机械键盘 87 键",399]

# 只改一个字段，不读全文档
JSON.SET product:1001 $.stock 110

# 数值自增（原子）
JSON.NUMINCRBY product:1001 $.stock -1

# 数组追加
JSON.ARRAPPEND product:1001 $.tags '"静音"'
```

对比传统 `SET product:1001 "{...}"`：

| 维度 | String + Jackson | RedisJSON |
|---|---|---|
| 改一个字段 | 读全量 → 反序列化 → 改 → 序列化 → 写回 | `JSON.SET $.field` 原地改 |
| 并发安全 | 需要 WATCH/Lua 才能避免丢更新 | 单字段操作天然原子 |
| 内存 | 字符串编码，无压缩 | 有专门编码，小文档更省 |
| 可索引 | 不能 | RediSearch 可直接索引 JSONPath |
| 客户端复杂度 | 高（每次全量） | 低 |

**实践结论**：文档型数据（商品、订单快照、用户画像）用 RedisJSON；纯 KV、大 blob、计数器仍用 String/Hash。别为了统一而统一。

### 2.2 内存编码的坑

RedisJSON 内部用类似树的结构存储。字段极多（几百个 key）的「大宽表 JSON」会显著放大内存，而且 `JSON.GET $` 全量读取会阻塞事件循环。经验阈值：

- 单文档 < 10KB，字段 < 50 个：随便用。
- 单文档 10KB~100KB：只读子路径，禁止 `JSON.GET key $` 全量。
- 单文档 > 100KB：拆文档，或用 Hash + 分片。

## 三、RediSearch：给 Redis 装上倒排索引

### 3.1 建索引

```bash
FT.CREATE idx:product ON JSON PREFIX 1 product: SCHEMA
  $.name AS name TEXT WEIGHT 5.0
  $.category AS category TAG
  $.price AS price NUMERIC
  $.stock AS stock NUMERIC
  $.tags[*] AS tags TAG
  $.attrs.switch AS switch TAG
  $.location AS location GEO
```

几个必须理解的参数：

- `ON JSON` + `PREFIX`：索引哪些 key。前缀匹配，不是通配符。
- `AS`：给索引字段起别名，查询时用别名。
- `TEXT`：分词 + 倒排，支持模糊、前缀、短语。
- `TAG`：精确匹配、多值、`{a|b}` 或关系，**不分词**，适合类目/标签/状态。
- `NUMERIC`：范围查询、排序。
- `GEO`：半径查询。
- `VECTOR`：向量字段（下一节）。

### 3.2 中文分词

RediSearch 内置分词器对中文是按字节切分的，效果很差。生产必须用 `friso` 或 `jieba` 分词器（Redis Stack 提供 `Chinese` 语言支持）：

```bash
FT.CREATE idx:article ON HASH PREFIX 1 article: SCHEMA
  title TEXT LANGUAGE chinese
  content TEXT LANGUAGE chinese
```

注意：`LANGUAGE chinese` 需要模块编译时带中文词典。社区版默认镜像可能没有，部署前先用 `FT.INFO` 或写一条中文查询验证。

如果不想依赖分词器，一个稳妥的折中方案：**写入时自己分词，把词元写进 TAG 数组字段**，查询用 TAG 组合。可控性最好，代价是失去相关性打分。

### 3.3 查询语法

```bash
# 全文 + 类目 + 价格区间 + 库存 > 0，按销量排序，分页
FT.SEARCH idx:product "@name:(机械 键盘) @category:{peripheral} @price:[100 500] @stock:[1 +inf]"
  SORTBY price ASC LIMIT 0 20

# 标签或关系
FT.SEARCH idx:product "@tags:{无线|蓝牙}"

# 前缀匹配（自动补全场景）
FT.SEARCH idx:product "@name:机械*"

# 聚合：按类目统计平均价
FT.AGGREGATE idx:product "*"
  GROUPBY 1 @category
  REDUCE AVG 1 @price AS avg_price
  REDUCE COUNT 0 AS cnt
  SORTBY 2 @cnt DESC
```

`FT.SEARCH` 返回的是文档 ID 列表 + 字段，**不含原文**（HASH/JSON 需要再取）。用 `RETURN 3 name price stock` 限制返回字段，能显著降低网络开销。

## 四、向量检索：把语义搜索塞进 Redis

Redis 8 之后向量检索是核心能力。建索引：

```bash
FT.CREATE idx:doc ON HASH PREFIX 1 doc: SCHEMA
  title TEXT
  content TEXT
  embedding VECTOR HNSW 6
    TYPE FLOAT32
    DIM 1024
    DISTANCE_METRIC COSINE
    M 16
    EF_CONSTRUCTION 200
```

写入：

```bash
HSET doc:1 title "退款政策" content "..." embedding <1024 个 float32 字节>
```

KNN 查询（返回 TopK + 距离）：

```bash
FT.SEARCH idx:doc "*=>[KNN 5 @embedding $vec AS score]"
  PARAMS 2 vec <二进制向量>
  SORTBY score ASC
  RETURN 3 title score content
  DIALECT 2
```

关键点：

- `DIM` 必须和 embedding 模型输出维度一致，改模型 = 重建索引。
- `DISTANCE_METRIC` 要和模型训练时一致：OpenAI/BGE 类模型一般用 `COSINE`。
- `M`/`EF_CONSTRUCTION` 影响召回与内存，`EF_RUNTIME` 影响查询延迟。
- 向量以二进制传，Java 里要手动把 `float[]` 转 little-endian `ByteBuffer`。

## 五、Java 落地

### 5.1 依赖

```xml
<dependency>
  <groupId>redis.clients</groupId>
  <artifactId>jedis</artifactId>
  <version>5.2.0</version>
</dependency>
<dependency>
  <groupId>com.fasterxml.jackson.core</groupId>
  <artifactId>jackson-databind</artifactId>
</dependency>
```

Spring Data Redis 的 `RedisTemplate` 对 JSON/搜索命令支持不全，搜索类命令建议直接用 Jedis/Lettuce 原生 API。

### 5.2 统一的文档仓储

```java
@Component
public class ProductSearchRepository {

    private final UnifiedJedis jedis;
    private final ObjectMapper mapper;

    public ProductSearchRepository(UnifiedJedis jedis, ObjectMapper mapper) {
        this.jedis = jedis;
        this.mapper = mapper;
    }

    public void save(Product p) {
        String key = "product:" + p.id();
        jedis.jsonSet(key, "$", mapper.writeValueAsString(p));
    }

    /** 只更新库存，避免全量覆盖导致并发丢更新 */
    public void updateStock(long id, int delta) {
        jedis.jsonNumIncrBy("product:" + id, "$.stock", delta);
    }

    public SearchResult search(ProductQuery q) {
        StringBuilder sb = new StringBuilder();
        if (StringUtils.hasText(q.keyword())) {
            sb.append("@name:(").append(escape(q.keyword())).append(") ");
        }
        if (q.category() != null) {
            sb.append("@category:{").append(q.category()).append("} ");
        }
        if (q.minPrice() != null || q.maxPrice() != null) {
            sb.append("@price:[")
              .append(q.minPrice() == null ? "-inf" : q.minPrice()).append(" ")
              .append(q.maxPrice() == null ? "+inf" : q.maxPrice()).append("] ");
        }
        sb.append("@stock:[1 +inf]");

        Query query = new Query(sb.toString())
            .setSortBy(q.sortField(), q.asc())
            .limit(q.offset(), q.size())
            .returnFields("name", "price", "stock", "category");

        var res = jedis.ftSearch("idx:product", query);
        List<Product> list = res.getDocuments().stream()
            .map(d -> mapper.convertValue(d.getProperties(), Product.class))
            .toList();
        return new SearchResult(list, res.getTotalResults());
    }

    private String escape(String kw) {
        // RediSearch 特殊字符必须转义，否则查询语法报错
        return kw.replaceAll("([,.<>{}\\[\\]\"':;!@#$%^&*()\\-+=~|/\\\\])", "\\\\$1");
    }
}
```

**转义这段是血泪教训**：用户搜 `a-b` 或 `C++`，不转义直接返回 `Syntax error`，前端表现为「搜某些词就白屏」。

### 5.3 向量写入与检索

```java
public void indexChunk(String id, String title, String content, float[] vector) {
    Map<String, Object> doc = new HashMap<>();
    doc.put("title", title);
    doc.put("content", content);
    doc.put("embedding", toBytes(vector));
    jedis.hset("doc:" + id, toStringMap(doc));
}

private static byte[] toBytes(float[] v) {
    ByteBuffer buf = ByteBuffer.allocate(v.length * Float.BYTES)
        .order(ByteOrder.LITTLE_ENDIAN);   // 必须小端
    for (float f : v) buf.putFloat(f);
    return buf.array();
}

public List<ScoredDoc> knn(float[] queryVec, int topK) {
    byte[] vec = toBytes(queryVec);
    Query q = new Query("*=>[KNN " + topK + " @embedding $vec AS score]")
        .addParam("vec", vec)
        .setSortBy("score", true)
        .returnFields("title", "content", "score")
        .dialect(2)
        .limit(0, topK);

    return jedis.ftSearch("idx:doc", q).getDocuments().stream()
        .map(d -> new ScoredDoc(
            (String) d.getProperties().get("title"),
            (String) d.getProperties().get("content"),
            Float.parseFloat((String) d.getProperties().get("score"))))
        .toList();
}
```

## 六、生产踩坑清单

| 坑 | 表现 | 处理 |
|---|---|---|
| 索引与数据前缀不匹配 | 写入成功但搜不到 | `FT.INFO` 看 `num_docs`，确认 PREFIX 与 key 一致 |
| TAG 字段写成了 TEXT | 精确筛选失效、结果发散 | 类目/状态/枚举一律 TAG |
| 中文不分词 | 搜「键盘」搜不到「机械键盘」 | 配中文分词器或写入时预分词 |
| 特殊字符未转义 | 查询语法错误 | 统一 escape 工具方法 |
| 全量 `JSON.GET $` | 大文档拖慢事件循环 | 按路径读，或 `RETURN` 限制字段 |
| 集群下跨槽聚合 | 结果不全 | 客户端合并 / 哈希标签 / 代理层 |
| 索引内存未估算 | 内存翻倍触发淘汰 | 上线前用样本数据压测 `used_memory` |
| 重建索引阻塞 | `FT.CREATE` 大库耗时 | 用 `FT.ALIASADD` 做索引切换，蓝绿重建 |
| 向量维度不一致 | 检索报错或召回为 0 | 模型版本与 DIM 绑定，写进配置中心 |

**索引蓝绿切换**是运维必备技巧：

```bash
FT.CREATE idx:product:v2 ON JSON PREFIX 1 product: SCHEMA ...
# 等索引追上
FT.ALIASADD idx:product idx:product:v2
# 确认后删旧
FT.DROPINDEX idx:product:v1
```

## 七、和 Elasticsearch 怎么选

| 维度 | Redis Stack | Elasticsearch |
|---|---|---|
| 延迟 | 亚毫秒~毫秒 | 毫秒~几十毫秒 |
| 全文能力 | 中等（分词、短语、打分） | 强（BM25、同义词、复杂分析器） |
| 聚合分析 | 基础 | 非常强 |
| 运维成本 | 低（复用现有 Redis） | 高（独立集群） |
| 数据一致性 | 写入即索引，强一致 | 近实时（refresh_interval） |
| 内存成本 | 高（全内存） | 中（可落盘） |
| 适用数据量 | 百万~千万级 | 亿级以上 |

**结论**：数据已经在 Redis、查询以「过滤 + 排序 + TopK」为主、数据量千万以内 → Redis Stack；需要复杂全文相关性、海量聚合、亿级数据 → ES。别用一个工具硬扛所有场景。

## 八、面试常见追问

**Q1：RediSearch 的索引是同步更新还是异步？会不会丢？**
写入命令执行时同步更新索引，返回 OK 即索引可见。持久化层面依赖 RDB/AOF；重启后 Redis 会扫描匹配 PREFIX 的 key 重建索引，所以「数据在、索引可重建」。但重建期间查询会不完整，大库要有预热方案。

**Q2：TEXT 和 TAG 的本质区别？**
TEXT 走分词器生成倒排表，支持相关性打分和模糊匹配，代价是索引大、不支持精确等值的高效过滤；TAG 不分词，按原值建倒排，适合枚举值精确匹配和 `{a|b}` 或查询，性能更好、索引更小。选错的典型症状是「筛选不准」或「内存暴涨」。

**Q3：向量检索为什么用 HNSW 而不是暴力扫描？**
暴力扫描是 O(N·D)，百万级向量单次查询几十毫秒到几百毫秒，无法支撑高 QPS。HNSW 是分层可导航小世界图，查询复杂度近似 O(log N)，用少量召回损失换数量级性能提升。代价是内存放大（图结构）和构建慢，需要调 `M`、`EF_CONSTRUCTION`、`EF_RUNTIME`。

**Q4：Redis 集群下做搜索有什么限制？**
索引是分片本地的，`FT.SEARCH` 默认只查当前节点；`FT.AGGREGATE` 的 GROUPBY 需要跨分片合并，官方企业版/RediSearch 集群支持有限。常见做法：用 hash tag 把同一业务维度的 key 固定到同一槽（会牺牲均衡），或在客户端 fan-out 到所有分片再归并。

## 总结

Redis Stack 的价值不在于「替代 ES」，而在于**把搜索能力下沉到已有的数据层**，消灭双写与同步链路。落地时记住四句话：

1. 文档型数据用 RedisJSON，只改子字段，不要全量覆盖。
2. 枚举用 TAG，文本用 TEXT，数值用 NUMERIC，别混。
3. 中文分词必须单独验证，不行就预分词。
4. 索引是内存换性能，上线前先算内存，再做蓝绿切换。

把这四件事做对，Redis 就不只是缓存，而是一个够用的实时查询引擎。
