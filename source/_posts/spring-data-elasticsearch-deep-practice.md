---
title: 【Spring Boot 实战】Spring Data Elasticsearch 深度实战：从 Repository 到高亮搜索与聚合
date: 2026-08-29 08:00:00
tags:
  - Spring Boot
  - Elasticsearch
  - 搜索引擎
  - 实战
categories:
  - Java
author: 东哥
---

# 【Spring Boot 实战】Spring Data Elasticsearch 深度实战：从 Repository 到高亮搜索与聚合

## 面试官：项目里 ES 检索是怎么落地的？说说 Spring Data Elasticsearch 的 Repository 查询原理，以及 N+1、深度分页、高亮这些坑你怎么处理的？

很多同学 ES 会用 Kibana 的 DevTools 写 DSL，但一上 Spring Boot 就露怯：Repository 怎么定义、`@Query` 怎么写、高亮怎么配、聚合怎么拿结果、和 MySQL 双写怎么保证一致。这篇从**架构定位 → Repository 原理 → 高阶查询 → 生产实践**完整走一遍。

## 一、Spring Data Elasticsearch 的架构定位

### 1.1 它在全家桶里的位置

```
Spring Boot
  └── spring-boot-starter-data-elasticsearch
        ├── ElasticsearchClient（官方 Java Client，走 HTTP/JSON）
        ├── ElasticsearchOperations（Spring 封装的模板类）
        └── ElasticsearchRepository（声明式接口，自动实现）
```

> 注意版本矩阵：Spring Boot 3.x 对应 ES 8.x 客户端（`co.elastic.clients`），底层是 **Elasticsearch Java API Client**（HTTP 协议），不再是老的 `RestHighLevelClient`（7.x 时代）。**迁移踩坑点**：`RestHighLevelClient` 的 API 全部换了，老教程别直接抄。

### 1.2 依赖与配置

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-elasticsearch</artifactId>
</dependency>
```

```yaml
spring:
  elasticsearch:
    uris: http://es-node1:9200,http://es-node2:9200
    username: elastic
    password: ${ES_PASSWORD}
    connection-timeout: 3s
    socket-timeout: 10s
```

## 二、实体映射与索引管理

### 2.1 实体注解

```java
@Data
@Document(indexName = "product", createIndex = false)
public class Product {
    @Id
    private String id;                  // 文档 _id（业务主键）

    @Field(type = FieldType.Text, analyzer = "ik_max_word",
           searchAnalyzer = "ik_smart")
    private String name;                // 名称：分词搜索

    @Field(type = FieldType.Keyword)
    private String category;            // 类目：精确匹配/聚合桶

    @Field(type = FieldType.Double)
    private BigDecimal price;           // 价格：范围查询

    @Field(type = FieldType.Integer)
    private Integer stock;

    @Field(type = FieldType.Date, format = DateFormat.date_time)
    private LocalDateTime createdAt;

    @Field(type = FieldType.Text, analyzer = "ik_max_word")
    private String description;
}
```

要点：
- `createIndex = false`：**索引结构（mapping）由 DBA 用 DSL 提前建好**，别让应用自动建——自动建出的 mapping 没有 ik 分词器配置（见本站《ES 中文分词与 IK 调优》），字段类型也常不符合预期。
- Text + Keyword 双字段是标配：Text 用于搜索，Keyword 用于排序/聚合/精确过滤。

### 2.2 索引操作模板

```java
@Service
public class IndexService {
    private final ElasticsearchOperations ops;

    public boolean exists(String index) {
        return ops.indexOps(IndexCoordinates.of(index)).exists();
    }

    public boolean createIndex(String index, String mappingJson) {
        IndexOperations io = ops.indexOps(IndexCoordinates.of(index));
        io.create();
        io.putMapping(mappingJson);
        return true;
    }
}
```

## 三、Repository：声明式查询的底层原理

### 3.1 一个完整的 Repository

```java
public interface ProductRepository extends ElasticsearchRepository<Product, String> {

    // 方法名派生查询
    List<Product> findByNameAndCategory(String name, String category);

    // 价格范围 + 排序
    List<Product> findByPriceBetweenAndStockGreaterThan(double min, double max, int stock);

    // @Query 原生 DSL（JSON 字符串，Spring Data 会替换 ?0 ?1）
    @Query("{\"match\": {\"name\": \"?0\"}}")
    List<Product> searchByName(String keyword);

    // 高亮查询需要走模板，Repository 原生支持有限，见下文
}
```

### 3.2 原理：方法名是怎么变成 DSL 的

`ElasticsearchRepository` 的默认实现是 `SimpleElasticsearchRepository`，它内部委托给 `ElasticsearchTemplate`/`ElasticsearchOperations`。方法名解析走 **`PartTreeElasticsearchQuery`**：

1. 解析方法名 `findByNameAndCategory` → 拆成 `PropertyPath`：`name`、`category` → 得到条件 `{ name: ?0 }` 和 `{ category: ?1 }`。
2. 把多个条件用 `bool` 组合：`must`（And 语义）。
3. 关键字映射表：`Between→range`、`GreaterThan→gt`、`Like→wildcard`、`In→terms`、`OrderByXxxDesc→sort`。
4. 组装成 `NativeQuery` 交给 `ElasticsearchOperations` 执行。

**局限**：方法名派生覆盖不了高亮、聚合、多条件复杂嵌套；`@Query` 虽然能写任意 DSL，但**参数只能整体替换、不支持动态拼接片段**。所以生产上复杂查询建议直接用 `ElasticsearchOperations` 手写 `NativeQuery`（官方推荐，类型安全且灵活）。

## 四、ElasticsearchOperations：复杂查询的完全体

### 4.1 关键词搜索 + 高亮 + 分页

```java
@Service
public class ProductSearchService {

    private final ElasticsearchOperations ops;

    public Page<Product> search(String keyword, int page, int size) {
        // 1. 构建查询
        Criteria criteria = new Criteria("name").matches(keyword)
                .or(new Criteria("description").matches(keyword));
        Query query = new CriteriaQuery(criteria)
                .setPageable(PageRequest.of(page, size));

        // 2. 高亮（highlight 是 NativeQuery 的专属能力）
        NativeQuery nativeQuery = NativeQuery.builder()
                .withQuery(q -> q
                        .bool(b -> b
                                .must(m -> m
                                        .multiMatch(mm -> mm
                                                .fields("name", "description")
                                                .query(keyword)))))
                .withPageable(PageRequest.of(page, size))
                .withHighlight(h -> h
                        .fields(f -> f.name("name")
                                .preTags("<em class='hl'>")
                                .postTags("</em>"))
                        .fields(f -> f.name("description")))
                .build();

        SearchHits<Product> hits = ops.search(nativeQuery, Product.class,
                IndexCoordinates.of("product"));

        // 3. 提取高亮片段，回填到返回对象
        return hits.stream().map(hit -> {
            Product p = hit.getContent();
            List<String> hl = hit.getHighlightFields().get("name");
            if (hl != null && !hl.isEmpty()) {
                p.setName(hl.get(0)); // 用高亮片段覆盖原字段
            }
            return p;
        }).collect(Collectors.collectingAndThen(Collectors.toList(),
                list -> new PageImpl<>(list,
                        PageRequest.of(page, size), hits.getTotalHits())));
    }
}
```

> 高亮字段和查询字段要**同字段**才能命中高亮；多字段查询用 `multiMatch`，高亮按字段分别配 `fields`。

### 4.2 聚合（Aggregation）：类目统计 + 价格分布

```java
NativeQuery query = NativeQuery.builder()
        .withQuery(q -> q.matchAll(m -> m))
        .withAggregation("category_count", Aggregation.of(a -> a
                .terms(t -> t.field("category").size(10))))
        .withAggregation("price_range", Aggregation.of(a -> a
                .range(r -> r.field("price")
                        .ranges(rg -> rg.key("0-100").to(100d))
                        .ranges(rg -> rg.key("100-500").from(100d).to(500d))
                        .ranges(rg -> rg.key("500+").from(500d)))))
        .withSize(0) // 只要聚合结果，不要命中文档
        .build();

SearchHits<Product> hits = ops.search(query, Product.class, IndexCoordinates.of("product"));

// 取聚合结果
AggregationsContainer<?> aggs = hits.getAggregations();
String aggJson = aggs.aggregationsAsMap().get("category_count").toString();
```

聚合结果拿到后是 ES 返回的 JSON，解析可以：

```java
// 用 ES 官方响应类型反序列化
SearchResponse response = ...;
LongTerms terms = response.aggregations().get("category_count");
for (LongTerms.Bucket bucket : terms.buckets()) {
    System.out.println(bucket.key().stringValue() + " -> " + bucket.docCount());
}
```

### 4.3 批量写入：Bulk 性能翻 N 倍

单条 `save()` 是 1 次 HTTP 往返，100 万条数据会慢到怀疑人生。必须用 **Bulk**：

```java
// 官方客户端 bulk（性能最优）
BulkRequest br = new BulkRequest();
list.forEach(p -> br.add(new IndexRequest("product")
        .id(p.getId())
        .source(JsonUtils.toJson(p), XContentType.JSON)));
BulkResponse resp = client.bulk(br, RequestOptions.DEFAULT);
```

> 经验值：单条写入 ~2ms/条，Bulk 5000 条一批能到 **每秒 2~5 万条**（取决于分片数和机器）。批大小、并发数、`refresh_interval`（写入期间调到 30s，写完恢复 1s）是三大调优点。

## 五、生产必修课：四个高频坑

### 5.1 坑一：与 MySQL 的双写一致性

ES 是近实时（NRT，默认 1s refresh），和 MySQL 天然不一致。**不要**在业务事务里双写（事务跨库不成立，写 ES 失败还会拖垮主库事务）。推荐 **Binlog 订阅（Canal）+ MQ**：

```
MySQL Binlog → Canal → Kafka/RabbitMQ → 消费端更新 ES
```

- 增量更新：消费消息后按主键 upsert 到 ES。
- 兜底对账：定时任务比对 MySQL 更新时间 > ES 文档时间的数据，重新同步。
- 全量重建：数据迁移时用 Bulk 全量灌 + 切索引别名（`product_v2` 建好 → 原子切 alias）。

详见本站《Redis 缓存与数据库一致性》里的「Canal 终极方案」一节，思路同源。

### 5.2 坑二：深度分页

`from + size` 超过 10000 会报 `Result window is too large`，而且深翻页性能极差（每个分片都要取 from+size 条再归并）。三种解法对比：

| 方案 | 原理 | 适用 |
|---|---|---|
| Scroll（已废弃） | 快照游标 | 导出全量数据 |
| **search_after** | 用排序值做游标翻页 | **业务翻页推荐**，无跳页需求 |
| PIT（Point In Time） | 固定视图 + search_after | 一致性要求高的实时翻页 |

完整原理见本站《ES 深度分页深度解析：from+size、Scroll 与 search_after》。

### 5.3 坑三：N+1 / 宽表设计

ES 文档**建议冗余成宽表**（把类目名、品牌名、商家名直接冗余进文档），查询一次命中、零 join。常见错误：ES 里只存 ID，查询后 for 循环查 MySQL 组装 → 100 条结果 101 次查询，P99 直接起飞。

宽表数据来源：MySQL 表变更时（商品改名、类目迁移），通过 Canal 同步**级联更新**关联文档。

### 5.4 坑四：分词导致的「搜不到」

- `ik_max_word` 用于索引（最大切分），`ik_smart` 用于搜索（最粗切分），配错会出现「搜『手机壳』找不到『手机保护壳』」。
- 新词未加入 IK 词典 → 搜不到；词典热更新用 IK 的 HTTP 接口或直接 reload。
- 拼音搜索（搜「shouji」）：加 pinyin 子字段。

## 六、单元测试与集成测试

```java
@Testcontainers
@SpringBootTest
class ProductSearchServiceTest {

    @Container
    static ElasticsearchContainer es =
            new ElasticsearchContainer("docker.elastic.co/elasticsearch/elasticsearch:8.13.0")
                    .withEnv("xpack.security.enabled", "false");

    @Test
    void testSearchWithHighlight() {
        // 预置数据 → 调用 service → 断言高亮片段包含 <em>
    }
}
```

Testcontainers 起真实 ES 做集成测试，比 mock 靠谱得多（能真实验证分词、mapping、高亮行为）。

## 七、面试追问速答

**追问 1：`@Query` 和 CriteriaQuery 怎么选？**
`@Query` 适合固定 DSL、参数整体替换的简单场景；动态条件组合、高亮、聚合一律 `NativeQuery`（官方 client DSL builder），类型安全、IDE 补全、编译期就能发现字段名错误。

**追问 2：ES 写入为什么慢？怎么调？**
主因：refresh（段刷新）、translog fsync、副本复制。调优：批量 Bulk、调大 `refresh_interval` 或关闭 refresh、`translog.durability=async`（接受少量丢失）、合理分片数（单分片 30~50GB）、写入走专用节点。

**追问 3：搜索相关性怎么调？**
BM25 参数（k1、b）、boost 字段权重（标题 3.0 > 描述 1.0）、`function_score`（销量/时间加权）、同义词词典、`minimum_should_match` 防召回过泛。线上用 Kibana 对比不同 query 的 Precision@10/Recall@10 再上。

## 总结

| 场景 | 正解 |
|---|---|
| 简单条件查询 | Repository 方法名派生 |
| 复杂 DSL/高亮/聚合 | ElasticsearchOperations + NativeQuery |
| 批量写入 | Bulk + refresh 调优，单条写入是性能杀手 |
| 数据同步 | Canal + MQ 增量，定时对账兜底 |
| 翻页 | search_after + PIT，禁用深分页 |
| 测试 | Testcontainers 起真 ES |

Spring Data Elasticsearch 的定位是「**把 ES 的 DSL 能力用类型安全的 Java 暴露出来**」，吃透 Repository 原理 + NativeQuery + 生产四坑，你就能从「会用」进阶到「能扛生产」。
