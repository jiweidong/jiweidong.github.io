---
title: 【Java AI】RAG 权限过滤与 ACL 下推深度实战：多租户、文档级鉴权与召回悖论
date: 2026-11-04 08:15:00
tags:
  - Java
  - AI
  - RAG
  - 权限
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】RAG 权限过滤与 ACL 下推深度实战

## 前言

RAG 的 Demo 版本是这样的：把公司文档切片、embedding、塞进向量库，然后 "问什么答什么"。效果惊艳，老板很满意。

上线第二周，CEO 用实习生账号问了一句"今年的期权池怎么分配"，系统流畅地回答了——**因为向量库里躺着那份只有 HRD 能看的文档。**

这是 RAG 落地最致命的坑之一：**向量检索天然无视权限**。传统系统的权限靠"先过滤再展示"，而 RAG 是"先召回再生成"，一不留神就把不该给模型看的内容喂给了模型，最终输出给无权用户。

Python 生态里讨论这个问题的文章不少，但 Java 侧、尤其是 Spring AI / Spring Security 体系下怎么落地，几乎找不到完整方案。这篇就把这件事拆到底。

---

## 一、为什么"后过滤"是错的

最直觉的做法：先向量检索 topK，再在应用层把没有权限的 chunk 剔掉。

```java
// ❌ 危险示范
List<Document> docs = vectorStore.similaritySearch(query, 10);
List<Document> allowed = docs.stream()
    .filter(d -> aclService.canRead(currentUser, d.getMetadata().get("docId")))
    .toList();
```

看似合理，实际有三个致命问题：

### 1.1 召回数量塌陷（召回悖论）

假设库里有 100 万 chunk，用户只有 5% 的文档权限。topK=10 之后过滤，**期望保留数 = 0.5 条**。于是：

- 上下文里没有相关内容 → 模型开始胡说（幻觉率飙升）
- 或者你把 topK 调到 100 → 每次检索成本 ×10，延迟 ×3，还未必够

**权限越严格，检索质量越差** —— 这是后过滤的本质缺陷：**过滤和应用在同一批候选上博弈，候选池就那么多。**

### 1.2 权限数据泄漏给模型（间接泄漏）

即使你剔掉了内容，很多实现会把"检索到的但无权访问的文档标题"塞进 prompt 当作"参考资料列表"。这依然泄漏了信息。更极端的，某些模型的工具调用轨迹里会带上被过滤的内容。

### 1.3 性能浪费

检索了 100 条，只用 3 条，97% 的向量计算和网络传输是白干的。大库 + 严格权限下，这会让 P99 延迟难看得离谱。

> **结论：权限必须在检索之前或检索之中生效，即"前置过滤 / ACL 下推"。**

---

## 二、ACL 下推的三种实现路径

| 方案 | 机制 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| 1. 分库/分 Collection | 每个租户独立 collection/index | 物理隔离，最安全，检索不受他人影响 | 租户多时 collection 爆炸，跨租户检索做不了 | 强合规、租户数 < 100 |
| 2. 元数据过滤下推 | 向量库支持 `filter` 表达式，检索时先过滤 | 单 collection，扩展性好，延迟可控 | 依赖向量库过滤能力与索引效率 | **主流方案** |
| 3. 分区键 / Namespace | 按 tenant 分区，检索限定分区 | 性能好 | 无法表达"文档级"细粒度权限 | 租户级隔离 |

绝大多数企业场景是 **方案 2 + 方案 3 组合**：tenant 用 partition/namespace 做粗隔离，文档级 ACL 用元数据 filter 做细过滤。

---

## 三、ACL 元数据的建模：这一步错，后面全错

向量库的 filter 能力有限（通常是"字段 = 值"/"字段 IN [...]"/范围比较"），**不支持 JOIN、不支持子查询**。所以权限必须提前"物化"到 chunk 的 metadata 里。

### 3.1 最小可行模型

```java
public record ChunkAcl(
    String tenantId,
    String docId,
    Set<String> allowedUserIds,   // 显式授权用户
    Set<String> allowedDeptIds,   // 部门授权
    Set<String> allowedRoles,     // 角色授权
    boolean isPublic
) {}
```

落到向量库 metadata：

```json
{
  "tenant_id": "t_1001",
  "doc_id": "doc_88231",
  "acl_public": false,
  "acl_users": ["u_1", "u_2"],
  "acl_depts": ["d_finance", "d_legal"],
  "acl_roles": ["role_hrd"],
  "chunk_index": 17,
  "source": "员工手册-2026.pdf"
}
```

### 3.2 三个建模陷阱

**陷阱 1：把权限做成"黑名单"。** 用 `deny_users` 而不是 `allow_*`，一旦新增用户就漏了。**永远用白名单 + 默认拒绝。**

**陷阱 2：粒度太细导致 filter 表达式爆炸。** 如果一份文档授权给 500 个用户，`acl_users IN [500 个 id]` 的 filter 会让向量库的倒排索引扛不住。**解法：用户数超过阈值（如 50）就上移到"部门/角色/组"维度，或者建一个"虚拟组"。**

**陷阱 3：忽略"权限继承"。** 文档在文件夹里，文件夹在空间里，权限逐层继承。**必须在入库时把继承链拍平（flatten）成最终有效权限集**，不要指望检索时再去算。

### 3.3 权限变更的实时性

文档权限变更后，向量库里的旧 metadata 必须更新：

```java
@Component
public class AclChangeListener {
    private final VectorStore vectorStore;
    private final JdbcTemplate jdbc;

    /** 文档权限变更事件：只更新 metadata，不重算 embedding */
    @EventListener
    public void onAclChanged(AclChangedEvent e) {
        // 1. 查出该文档所有 chunk 的 id
        List<String> chunkIds = jdbc.queryForList(
            "SELECT chunk_id FROM doc_chunk WHERE doc_id = ?", String.class, e.docId());

        // 2. 批量更新（Spring AI 0.8+ 支持，底层调向量库 upsert 的 metadata-only 更新）
        chunkIds.forEach(id -> vectorStore.updateMetadata(id, Map.of(
            "acl_users", String.join(",", e.allowedUsers()),
            "acl_depts", String.join(",", e.allowedDepts()),
            "acl_version", e.version()
        )));
    }
}
```

**关键**：权限更新走 metadata-only 路径，**绝不能重新 embedding**（那是几十倍成本）。如果向量库不支持 metadata 局部更新（如某些版本的 pgvector），就用 `DELETE + INSERT`（保留原 vector），别调 embedding API。

**更狠的做法：ACL 版本号 + 缓存失效。** 在 metadata 里存 `acl_version`，检索时代码层再校验一次版本是否与权限中心的版本一致，不一致的 chunk 直接丢弃并触发异步重建。这是"向量库 filter + 应用层二次校验"的双保险，**安全场景值得多这一层**。

---

## 四、Spring AI 落地：一个可跑的检索服务

### 4.1 Filter 表达式构造

Spring AI 的 `SearchRequest` 支持 `filterExpression`：

```java
@Service
public class SecureRetrievalService {

    private final VectorStore vectorStore;

    public List<Document> retrieve(String query, UserContext user, int topK) {
        String filter = buildAclFilter(user);

        SearchRequest request = SearchRequest.builder()
            .query(query)
            .topK(topK * 3)              // 留余量：filter 后仍可能有少量损耗
            .similarityThreshold(0.65)
            .filterExpression(filter)
            .build();

        List<Document> docs = vectorStore.similaritySearch(request);
        return postVerify(docs, user);   // 双保险二次校验
    }

    private String buildAclFilter(UserContext u) {
        List<String> clauses = new ArrayList<>();
        clauses.add("tenant_id == '" + escape(u.tenantId()) + "'");

        // public OR 用户显式授权 OR 部门授权 OR 角色授权
        List<String> ors = new ArrayList<>();
        ors.add("acl_public == true");
        if (!u.userId().isBlank()) {
            ors.add("acl_users.contains('" + escape(u.userId()) + "')");
        }
        u.deptIds().forEach(d ->
            ors.add("acl_depts.contains('" + escape(d) + "')"));
        u.roles().forEach(r ->
            ors.add("acl_roles.contains('" + escape(r) + "')"));

        clauses.add("(" + String.join(" || ", ors) + ")");
        return String.join(" && ", clauses);
    }
}
```

不同向量库的 filter 语法差异很大，必须用各自的原生写法（Spring AI 的通用表达式会翻译，但复杂嵌套可能不支持）：

| 向量库 | 语法示例 |
|---|---|
| Milvus | `tenant_id == "t1" && ARRAY_CONTAINS(acl_depts, "d1")` |
| Qdrant | `must: [{key: tenant_id, match: {value: t1}}]` |
| pgvector | `WHERE tenant_id = 't1' AND acl_depts && ARRAY['d1']`（SQL） |
| Elasticsearch | `terms: {acl_depts: ["d1"]}` |
| Redis Vector Set | 检索后过滤（**无原生 filter，性能陷阱**） |

⚠️ **Redis 8 的 Vector Set 目前不支持检索时元数据过滤**，只能 `VSIM` 后应用层过滤。这意味着 Redis 做向量库时要格外小心召回悖论——要么按租户分 key，要么接受"过滤后召回不足"。

### 4.2 二次校验（绝不能省）

```java
private List<Document> postVerify(List<Document> docs, UserContext u) {
    return docs.stream()
        .filter(d -> {
            String docId = String.valueOf(d.getMetadata().get("doc_id"));
            // 走本地 Caffeine 缓存（TTL 30s）+ 权限中心兜底
            return aclCache.canRead(u.userId(), docId);
        })
        .limit(5)
        .toList();
}
```

为什么 filter 下推了还要二次校验？三个理由：

1. **向量库的 filter 可能有 bug 或版本差异**（尤其 `contains` 在数组字段上的语义）
2. **权限撤销的传播延迟**：向量库里的 metadata 可能还没更新，本地缓存 + 权限中心是权威源
3. **纵深防御**：安全设计不能只有一个检查点

代价是每次检索多 N 次 Redis/Caffeine 查询（N=topK）。用 `MGET` 批量 + 本地缓存，实测增加 < 2ms。

### 4.3 引用溯源也要过权限

生成答案后要附引用来源，**引用列表同样要过滤**：

```java
public Answer ask(String q, UserContext u) {
    List<Document> ctx = retrieve(q, u, 5);
    if (ctx.isEmpty()) {
        return Answer.noPermission();   // ⭐ 明确返回"无权限"，而不是让模型硬答
    }
    String prompt = promptTemplate.render(Map.of("context", join(ctx), "question", q));
    String answer = chatClient.prompt(prompt).call().content();

    List<Citation> citations = ctx.stream()
        .map(d -> new Citation(d.getMetadata().get("source"), d.getId()))
        .distinct().toList();
    return new Answer(answer, citations);
}
```

注意 `ctx.isEmpty()` 的处理：**必须返回"未找到相关资料或无权访问"，而不是丢空上下文让模型自由发挥。** 空上下文 + 强指令是幻觉的高发场景。

---

## 五、召回悖论的四种解法

即使 filter 下推了，"严格权限 + 大库"依然可能召回不足。四种工业级应对：

### 5.1 提高 topK + 重排

```java
// 粗排多召回（含过滤），再精排截断
SearchRequest req = SearchRequest.builder()
    .query(query).topK(50).similarityThreshold(0.5)
    .filterExpression(aclFilter).build();
List<Document> candidates = vectorStore.similaritySearch(req);
// Cross-encoder rerank 后取 top 5
List<Document> top = reranker.rerank(query, candidates, 5);
```

多召回 + 重排是性价比最高的方案，成本是延迟增加 50~150ms。

### 5.2 按"权限可见度"分层建库

把文档按可见范围分成三类索引：

- `idx_public`：全员可见（占比通常 70%+）
- `idx_dept`：部门级（filter 只按 dept）
- `idx_restricted`：文档级白名单（量小，可以小 topK）

检索时按用户身份**并行查多个索引再合并**。好处是公共索引的 filter 极简（`tenant == x`），检索效率高；坏处是索引数量增加，需要一套路由逻辑。

### 5.3 Query 改写 + 权限感知扩展

当检索结果为空时，不要直接认输。用 LLM 把 query 改写成"更可能在可见范围内命中"的表述：

```java
if (docs.isEmpty()) {
    String rewritten = chatClient.prompt()
        .user("把这个问题改写为更通用的表述，不要包含具体人名/项目代号：" + q)
        .call().content();
    docs = retrieve(rewritten, u, 5);
}
```

这招在"用户问的是自己无权看的文档"时尤其有效——通常还能从公开材料里找到相关背景。

### 5.4 明确降级话术

最差也要优雅：

> "我在你有权限访问的资料中没有找到相关内容。该问题涉及的内容可能位于受限文档中，建议联系 XXX 或申请权限。"

比让模型编一个答案强一万倍。

---

## 六、五个生产踩坑

**坑 1：metadata 里的数组字段在向量库里是字符串**
有些实现（尤其是从 JSON 序列化进去的）把 `acl_users` 存成了 `"u1,u2,u3"` 字符串，`contains('u2')` 会误命中 `"u20"`。**必须存成原生数组类型**，或者用带分隔符的精确匹配 `,u2,`。

**坑 2：tenant 过滤漏在了某条"内部工具"路径上**
管理后台有个"全库搜索"给运营用，代码里忘了带 tenant filter。这类问题必须靠**单元测试 + 架构约束**：把 `buildAclFilter` 作为唯一入口，禁止直接调 `vectorStore.similaritySearch(query, topK)`。可以用 ArchUnit 加一条规则：

```java
@ArchTest
static final ArchRule no_raw_vector_search =
    noClasses().that().resideOutsideOfPackage("..retrieval..")
        .should().callMethod(VectorStore.class, "similaritySearch", String.class, int.class);
```

**坑 3：chunk 的 metadata 在切片时丢失**
文档切 100 个 chunk，只给第一个 chunk 打了 acl 字段。**切片器必须保证每个 chunk 都继承完整 ACL**，最好在 `DocumentSplitter` 之后统一 `enrichMetadata` 一遍。

**坑 4：embedding 缓存跨租户复用**
为了省钱做了"文本 hash → vector"的全局缓存。两个租户上传了同一份文件（比如公开的行业报告），共用 vector 没问题；但如果 metadata 也一起缓存了，第二个租户的 ACL 就错了。**缓存 key 必须包含 tenant + acl 版本，或者只缓存 vector 不缓存 metadata。**

**坑 5：日志把 chunk 内容打出来了**
`log.debug("retrieved: {}", docs)` 直接把全文写进日志，而日志平台是全公司可查的。**这是最容易被审计抓到的泄漏点。** 打日志只打 `doc_id` + `score`，内容字段做脱敏。

---

## 七、面试常见追问

**Q1：为什么不能先检索再过滤？**
两个原因：①召回悖论——topK 固定时，过滤后有效结果可能为 0，权限越严检索质量越差；②性能浪费——算了很多用不上的向量距离。正确做法是 filter 下推到向量库，在 ANN 搜索时就排除无权文档。

**Q2：向量库的 filter 会影响 ANN 索引效率吗？**
会。大多数向量库的实现是"用 filter 走标量索引先缩小候选集，再在候选集里做向量检索"，或者"先 ANN 再过滤"（取决于过滤比例）。**高选择性 filter（如 tenant）性能好，低选择性 filter（如 acl_public=true 占 90%）反而拖慢**，因为候选集太大。Milvus 2.4+ 有专门的过滤策略选择，Qdrant 有 filterable HNSW。

**Q3：多租户用 collection 隔离还是 metadata 隔离？**
取决于租户数与合规要求。租户 < 100 且强合规 → 独立 collection（物理隔离，误配风险低）；租户上千 → metadata filter + 分区。**千万别用"每个用户一个 collection"**，元数据管理会成为灾难。

**Q4：权限变更后多久生效？**
理想是秒级，实际取决于链路：权限中心 → 消息队列 → metadata 更新 → 向量库索引可见。Milvus/Qdrant 的 metadata 更新通常是近实时的，ES 需要 refresh（默认 1s）。**兜底方案是应用层二次校验 + 短 TTL 缓存**，把生效延迟压到 TTL 级别（30s）。

**Q5：能不能让 LLM 自己判断该不该回答？**
不能作为唯一防线。模型没有可靠的权限判断能力，且 prompt 注入可以绕过。**权限必须在代码里判，不能交给模型。**

---

## 八、小结

- RAG 天生无视权限，**后过滤会导致召回悖论**：权限越严，检索质量越差。
- 正确姿势是 **ACL 下推**：权限物化到 chunk metadata，检索时用 filter 表达式前置过滤。
- 元数据建模三原则：**白名单 + 默认拒绝**、**权限继承入库时拍平**、**粒度上移防止 filter 爆炸**。
- 权限变更走 **metadata-only 更新**，绝不重新 embedding。
- 落地要"双保险"：向量库 filter + 应用层二次校验（Caffeine 缓存 + 权限中心）。
- 召回不足的四种解法：多召回 + 重排、权限分层建库、Query 改写、明确降级话术。
- 最容易翻车的地方不是算法，是**漏配 tenant filter** 和**日志打全文**。

RAG 的权限问题，本质是"检索系统"和"权限系统"两个世界的对接。做 AI 应用开发的 Java 工程师最大的优势，恰恰是**你比纯算法背景的人更懂权限体系该怎么建**——这活儿真该你来干。
