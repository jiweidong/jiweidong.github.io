---
title: 【Spring Boot 实战】Spring Data MongoDB 深度实战：从 Repository 到聚合管道与事务
date: 2026-07-25 08:00:00
tags:
  - Java
  - Spring Boot
  - MongoDB
  - Spring Data
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】Spring Data MongoDB 深度实战：从 Repository 到聚合管道与事务

## 前言

MongoDB 作为最流行的 NoSQL 文档数据库，在 Java 生态中与 Spring Data MongoDB 组合堪称「黄金搭档」。无论是内容管理、日志存储、IoT 数据还是用户画像系统，MongoDB 的灵活文档模型 + Spring Data 的便捷抽象让开发效率大幅提升。

本文从零开始，带你从 **基础 CRUD → 高级聚合 → 事务处理 → 性能优化**，全面掌握 Spring Data MongoDB。

---

## 一、快速集成

### 1.1 依赖引入

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-mongodb</artifactId>
</dependency>
```

Spring Boot 3.x 默认使用 MongoDB Driver 4.x 同步驱动。如果需要响应式版本：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-mongodb-reactive</artifactId>
</dependency>
```

### 1.2 基础配置

```yaml
spring:
  data:
    mongodb:
      uri: mongodb://admin:password@localhost:27017/mydb?authSource=admin
      # 或者分拆配置
      # host: localhost
      # port: 27017
      # database: mydb
      # username: admin
      # password: password
      # authentication-database: admin

# 连接池配置（MongoDB Driver 4.x 支持）
spring.data.mongodb.connection-pool:
  max-size: 100
  min-size: 10
  max-wait-time: 2000ms
  max-connection-life-time: 30m
```

### 1.3 实体定义

```java
@Document(collection = "users")           // 映射到 users 集合
@CompoundIndex(def = "{'name':1, 'age':-1}") // 复合索引
public class User {

    @Id
    private String id;                     // MongoDB _id 字段

    @Field("username")
    private String name;

    @Field("birth_year")
    private Integer birthYear;

    @Field("tags")
    private List<String> tags;             // 数组类型

    @Field("address")
    private Address address;               // 嵌套文档

    @Field("created_at")
    private LocalDateTime createdAt;

    @Field("score")
    private Double score;

    // 映射为 DBRef（注意：不推荐频繁使用）
    @DBRef
    private Organization organization;

    // getters & setters...
}

// 嵌套文档不需要 @Document
public class Address {
    private String province;
    private String city;
    private String detail;
    // getters & setters...
}
```

---

## 二、Repository 层：最常用的 CRUD

### 2.1 定义 Repository 接口

```java
public interface UserRepository extends MongoRepository<User, String> {
    // 按方法名自动推导查询
    List<User> findByName(String name);
    List<User> findByNameLike(String name);
    List<User> findByBirthYearGreaterThan(Integer year);
    List<User> findByTagsContaining(String tag);

    // 分页排序
    Page<User> findByBirthYearBetween(Integer from, Integer to, Pageable pageable);
    List<User> findTop10ByOrderByScoreDesc();

    // 删除
    Long deleteByName(String name);
}
```

### 2.2 测试

```java
@SpringBootTest
class UserRepositoryTest {
    @Autowired
    private UserRepository userRepository;

    @Test
    void testCrud() {
        User user = new User();
        user.setName("张三");
        user.setBirthYear(1995);
        user.setTags(List.of("developer", "java"));
        user.setCreatedAt(LocalDateTime.now());
        user.setScore(85.5);

        // 插入
        User saved = userRepository.save(user);
        assertNotNull(saved.getId());

        // 查询
        Optional<User> found = userRepository.findById(saved.getId());
        assertTrue(found.isPresent());

        // 更新（save 是 upsert 语义）
        found.get().setScore(90.0);
        userRepository.save(found.get());

        // 删除
        userRepository.delete(found.get());
        assertFalse(userRepository.findById(saved.getId()).isPresent());
    }
}
```

### 2.3 自定义查询（@Query）

当方法名无法表达复杂查询时，使用 `@Query` 注解直接写 MongoDB JSON 查询：

```java
public interface UserRepository extends MongoRepository<User, String> {

    // 原生 JSON 查询
    @Query("{ 'name': { $regex: ?0, $options: 'i' }, 'birthYear': { $gte: ?1 } }")
    List<User> searchByNameAndAge(String namePattern, Integer minBirthYear);

    // 指定返回字段（类似 SQL 的 SELECT 指定列）
    @Query(value = "{ 'tags': 'vip' }", fields = "{ 'username': 1, 'score': 1 }")
    List<User> findVipUsers();

    // 使用 $in
    @Query("{ 'name': { $in: ?0 } }")
    List<User> findByNames(List<String> names);

    // 聚合管道（需要 @Aggregation 注解）
    @Aggregation(pipeline = {
        "{ $match: { 'birthYear': { $gte: ?0 } } }",
        "{ $group: { _id: '$birthYear', count: { $sum: 1 }, avgScore: { $avg: '$score' } } }",
        "{ $sort: { _id: -1 } }"
    })
    List<BirthYearStats> getStatsByBirthYear(Integer minBirthYear);
}
```

### 2.4 更新操作

```java
public interface UserRepository extends MongoRepository<User, String> {

    // 使用 MongoTemplate 的 update 语义
    // 或使用 @Query 加修饰
    @Query("{ 'id': ?0 }")
    @Update("{ $inc: { 'score': ?1 } }")
    void incrementScore(String id, double delta);
}
```

---

## 三、MongoTemplate：更灵活的底层操作

Repository 能覆盖 80% 的场景，剩下 20% 需要 MongoTemplate：

```java
@Service
public class UserService {
    @Autowired
    private MongoTemplate mongoTemplate;

    // 3.1 复杂更新
    public void updateTags(String userId, String newTag) {
        Query query = Query.query(Criteria.where("id").is(userId));
        Update update = new Update()
                .addToSet("tags", newTag)    // 数组去重添加
                .currentDate("updatedAt");    // 更新时间为当前时间
        mongoTemplate.updateFirst(query, update, User.class);
    }

    // 3.2 批量更新
    public void batchUpgrade(List<String> userIds) {
        Query query = Query.query(Criteria.where("id").in(userIds));
        Update update = new Update().set("level", "VIP");
        mongoTemplate.updateMulti(query, update, User.class);
    }

    // 3.3 聚合管道
    public List<Map> aggregateByCity() {
        TypedAggregation<User> aggregation = Aggregation.newAggregation(
                Aggregation.match(Criteria.where("score").gte(60)),
                Aggregation.group("address.city")
                        .count().as("userCount")
                        .avg("score").as("avgScore"),
                Aggregation.sort(Sort.by(Sort.Direction.DESC, "userCount")),
                Aggregation.limit(10)
        );
        AggregationResults<Map> results = mongoTemplate.aggregate(
                aggregation, User.class, Map.class);
        return results.getMappedResults();
    }

    // 3.4 upsert（存在则更新，不存在则插入）
    public void upsertByOpenId(String openId, User user) {
        Query query = Query.query(Criteria.where("openId").is(openId));
        Update update = new Update()
                .setOnInsert("openId", openId)
                .set("name", user.getName())
                .set("score", user.getScore());
        mongoTemplate.upsert(query, update, User.class);
    }
}
```

### MongoTemplate 常用方法速查

| 方法 | 作用 |
|------|------|
| `find` | 查询多条 |
| `findOne` | 查询单条 |
| `findById` | 按 ID 查询 |
| `insert` | 插入（已存在报错） |
| `save` | 保存（已存在则替换） |
| `updateFirst` | 更新第一条匹配 |
| `updateMulti` | 更新所有匹配 |
| `upsert` | 存在更新，不存在插入 |
| `remove` | 删除 |
| `aggregate` | 聚合管道 |
| `count` | 计数 |
| `stream` | 流式读取大结果集 |

---

## 四、聚合管道（Aggregation Pipeline）

聚合是 MongoDB 最强大的数据分析能力，等价于 SQL 中的 GROUP BY + 各种函数。

### 4.1 聚合阶段对比 SQL

| MongoDB 阶段 | 对应 SQL | 用途 |
|-------------|---------|------|
| `$match` | WHERE | 过滤文档 |
| `$group` | GROUP BY | 分组聚合 |
| `$sort` | ORDER BY | 排序 |
| `$project` | SELECT | 字段投影/重命名 |
| `$limit` / `$skip` | LIMIT / OFFSET | 分页 |
| `$unwind` | — | 数组展开（一行变多行） |
| `$lookup` | LEFT JOIN | 跨集合关联 |
| `$addFields` | — | 添加计算字段 |
| `$bucket` | CASE WHEN | 分桶统计 |

### 4.2 实战：用户行为分析

```java
public class OrderAnalyticsService {
    @Autowired
    private MongoTemplate mongoTemplate;

    /** 统计每月各品类销售额 Top 5 */
    public List<MonthlyCategoryStats> monthlyTopCategories(LocalDate start, LocalDate end) {
        TypedAggregation<Order> aggregation = Aggregation.newAggregation(
                Order.class,
                Aggregation.match(Criteria.where("orderTime")
                        .gte(start.atStartOfDay())
                        .lt(end.plusDays(1).atStartOfDay())),
                Aggregation.unwind("items"),                      // 展开订单商品数组
                Aggregation.group("category")                     // 按品类分组
                        .sum("items.amount").as("totalAmount")
                        .count().as("orderCount"),
                Aggregation.sort(Sort.by(Sort.Direction.DESC, "totalAmount")),
                Aggregation.limit(5)
        );
        return mongoTemplate.aggregate(aggregation, MonthlyCategoryStats.class).getMappedResults();
    }

    /** $lookup 跨集合关联：订单 + 用户 */
    public List<Map> orderWithUserInfo() {
        TypedAggregation<Order> aggregation = Aggregation.newAggregation(
                Aggregation.lookup("users", "userId", "_id", "userInfo"),
                Aggregation.unwind("$userInfo"),
                Aggregation.project()
                        .and("orderId").as("orderId")
                        .and("userInfo.username").as("userName")
                        .and("userInfo.phone").as("phone")
        );
        return mongoTemplate.aggregate(aggregation, Order.class, Map.class).getMappedResults();
    }
}
```

### 4.3 Spring Data 聚合 DTO

```java
// 定义聚合结果 DTO
public class MonthlyCategoryStats {
    @Id
    private String category;         // _id 字段必须用 @Id
    private Double totalAmount;
    private Long orderCount;

    // getters & setters
}
```

---

## 五、事务支持

MongoDB 从 4.0 开始支持 **多文档事务**（副本集），4.2 支持分片集群事务。

### 5.1 Spring 声明式事务

```java
@Service
public class TransferService {
    @Autowired
    private MongoTemplate mongoTemplate;

    @Transactional
    public void transfer(String fromId, String toId, double amount) {
        // 扣款
        Query q1 = Query.query(Criteria.where("id").is(fromId));
        Update u1 = new Update().inc("balance", -amount);
        mongoTemplate.updateFirst(q1, u1, Account.class);

        // 入账
        Query q2 = Query.query(Criteria.where("id").is(toId));
        Update u2 = new Update().inc("balance", amount);
        mongoTemplate.updateFirst(q2, u2, Account.class);

        // 如果中间发生异常，两个操作都会回滚
    }
}
```

### 5.2 编程式事务

```java
@Service
public class OrderService {
    @Autowired
    private MongoTemplate mongoTemplate;

    public void createOrderWithTransaction(Order order) {
        mongoTemplate.inTransaction().execute(action -> {
            // 插入订单
            action.insert(order);

            // 扣减库存
            Query query = Query.query(Criteria.where("id").is(order.getProductId()));
            Update update = new Update().inc("stock", -order.getQuantity());
            action.updateFirst(query, update, Product.class);

            // 记录日志
            action.insert(new OrderLog(order.getOrderId(), "created"));

            return null;
        });
    }
}
```

### 5.3 事务配置要求

```yaml
spring:
  data:
    mongodb:
      uri: mongodb://.../mydb?replicaSet=rs0  # 必须副本集模式
  transaction:
    default-timeout: 5s
```

> ⚠️ **重要：** MongoDB 事务对副本集有强依赖。单节点 MongoDB **不支持事务**。

---

## 六、索引优化

### 6.1 声明式索引

```java
@Document
@CompoundIndex(name = "idx_name_age", def = "{'name':1, 'age':-1}")
@TextIndexed                                        // 全文索引
public class User {
    @Indexed(unique = true, direction = IndexDirection.ASCENDING)
    private String email;                           // 唯一索引 + 升序

    @Indexed(background = true)
    private LocalDateTime createdAt;                // 后台创建索引

    @TextIndexed(weight = 2)
    private String name;

    @TextIndexed(weight = 1)
    private String bio;
}
```

### 6.2 通过 MongoTemplate 管理索引

```java
@Service
public class IndexService {
    @Autowired
    private MongoTemplate mongoTemplate;

    public void ensureIndexes() {
        // 创建唯一索引
        mongoTemplate.indexOps(User.class)
                .ensureIndex(new Index()
                        .on("email", Sort.Direction.ASC)
                        .unique());

        // 创建 TTL 索引（自动过期，7天后删除）
        mongoTemplate.indexOps(LogEntry.class)
                .ensureIndex(new Index()
                        .on("createdAt", Sort.Direction.ASC)
                        .expire(7, TimeUnit.DAYS));

        // 创建地理空间索引（支持 $near 查询）
        mongoTemplate.indexOps(Store.class)
                .ensureIndex(new GeospatialIndex("location"));
    }
}
```

### 6.3 查看执行计划

```java
// 使用 explain 分析查询
Query query = Query.query(Criteria.where("email").is("test@example.com"));
Document explainResult = mongoTemplate.executeCommand(
        Document.parse("{ explain: { find: 'users', filter: { email: 'test@example.com' } } }"));
System.out.println(explainResult.toJson());
```

---

## 七、性能优化最佳实践

### 7.1 批量操作

```java
// 批量插入（一次网络往返）
List<User> users = generateUsers(10000);
mongoTemplate.insertAll(users);  // 批量插入

// 批量更新
List<Pair<Query, Update>> updates = new ArrayList<>();
updates.add(Pair.of(query1, update1));
updates.add(Pair.of(query2, update2));
mongoTemplate.bulkOps(BulkMode.ORDERED, User.class).updateMulti(updates).execute();
```

### 7.2 流式读取大结果集

```java
// 避免将所有数据加载到内存
Query query = new Query();
query.cursorBatchSize(500);  // 每次游标读取 500 条

try (CloseableIterator<User> iterator = mongoTemplate.stream(query, User.class)) {
    while (iterator.hasNext()) {
        User user = iterator.next();
        process(user);  // 逐条处理
    }
}
```

### 7.3 字段过滤

```java
// 只返回需要的字段，减少网络传输
Query query = Query.query(Criteria.where("score").gte(80));
query.fields().include("name", "score").exclude("_id");
List<User> users = mongoTemplate.find(query, User.class);
```

### 7.4 连接池调优

```yaml
spring.data.mongodb.connection-pool:
  max-size: 200               # 最大连接数
  min-size: 20                # 最小连接数
  max-wait-time: 2000ms       # 获取连接超时
  max-connection-idle-time: 10m  # 空闲连接存活
  max-connection-life-time: 30m  # 连接最大生命周期
```

---

## 八、面试追问

> **Q：MongoDB 的事务和 MySQL 的事务有什么区别？**
> A：MongoDB 事务在多文档上保持 ACID，但性能开销较大（副本集同步），**不建议高频短事务场景使用**。MySQL 事务更成熟、性能更好。MongoDB 建议尽量用文档内嵌的方式避免跨文档事务。

> **Q：什么时候用 @DBRef，什么时候用内嵌文档？**
> A：**内嵌优先。** 当子文档单独查询频率低且数据量小时，直接内嵌。只有在子文档独立查询、独立更新频繁，或子文档数据量过大时才考虑引用或反范式化。

> **Q：Spring Data MongoDB 的 save 在不存在时 insert，存在时 update 吗？**
> A：是的，save 是 upsert 语义。如果 `_id` 字段有值且文档已存在则执行替换（replace），不存在则插入。注意这是**整个文档替换**，不是局部更新。局部更新要用 `updateFirst`。

> **Q：MongoDB 4.0+ 的 change stream 有什么用？**
> A：可以实时监听集合/库/整个集群的数据变更事件，用于 CDC 场景（如同步到缓存、搜索引擎或触发业务逻辑），类似 MySQL 的 binlog。

---

## 总结

Spring Data MongoDB 的强大之处在于：

1. **Repository 自动实现**：80% 场景零代码
2. **MongoTemplate 灵活操控**：复杂聚合、更新、游标全部可控
3. **事务支持**：关键业务场景可依赖
4. **索引管理一体化**：声明式 + 编程式双管齐下

**最佳实践口诀：**
> 简单 CRUD 用 Repository，复杂查询用 MongoTemplate
> 内嵌文档优先，跨集合引用谨慎
> 索引先行，explain 验证
> 批量操作加流式，大结果集不心慌
