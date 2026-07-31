---
title: Neo4j 图数据库入门与 Spring Boot 集成实战：从数据建模到社交推荐
date: 2026-07-31 08:00:00
tags:
  - Java
  - Neo4j
  - 图数据库
  - Spring Boot
categories:
  - Java
  - 数据库
author: 东哥
---

# Neo4j 图数据库入门与 Spring Boot 集成实战：从数据建模到社交推荐

## 为什么要用图数据库？

当我们需要处理复杂的关系网络时，传统关系型数据库的 JOIN 操作往往会成为性能瓶颈。以社交网络中"用户的好友的好友的好友"为例，MySQL 需要自连接多次，查询呈指数级增长——而图数据库仅需一次**图遍历**。

> 面试官：MySQL 也能存关系数据，为什么要用图数据库？

**核心回答：关系的查询效率。** MySQL 中的关系是"计算出来的"（JOIN），而图数据库中的关系是"存储好的"（直接指针引用）。对于 3 度以上的关系查询，性能差距可达数千倍。

---

## 一、Neo4j 核心概念

### 1.1 图数据模型四大要素

| 概念 | 说明 | MySQL 类比 |
|------|------|-----------|
| 节点（Node） | 实体，如用户、商品 | 表中的一行 |
| 标签（Label） | 节点分类，如 `:User` `:Product` | 表名 |
| 关系（Relationship） | 节点间的连接，如 `:FOLLOWS` `:PURCHASED` | 外键/关联表 |
| 属性（Property） | 节点或关系的键值对 | 列 |

### 1.2 与 MySQL 的对比

```cypher
// Neo4j：查询"Alice 关注的人关注的电影"
MATCH (alice:User {name: "Alice"})-[:FOLLOWS]->()-[:LIKES]->(m:Movie)
RETURN DISTINCT m.title
```

```sql
-- MySQL：同样逻辑，需要 3 次 JOIN
SELECT DISTINCT m.title
FROM users u1
JOIN follows f1 ON u1.id = f1.follower_id
JOIN users u2 ON f1.followee_id = u2.id
JOIN likes l ON u2.id = l.user_id
JOIN movies m ON l.movie_id = m.id
WHERE u1.name = 'Alice';
```

当关系深度达到 4-5 层时，MySQL 的 JOIN 会爆炸，而 Neo4j 的遍历性能几乎线性。

---

## 二、Cypher 查询语言基础

Cypher 是 Neo4j 的声明式查询语言，语法直观：

```cypher
// 创建节点
CREATE (u:User {name: "东哥", age: 28, city: "上海"})

// 创建关系
MATCH (a:User {name: "Alice"}), (b:User {name: "Bob"})
CREATE (a)-[:FOLLOWS {since: 2024}]->(b)

// 查找好友的好友推荐
MATCH (me:User {name: "Alice"})-[:FOLLOWS]->(friend)-[:FOLLOWS]->(fof:User)
WHERE NOT (me)-[:FOLLOWS]->(fof)
RETURN fof.name AS recommendation, count(*) AS commonFriends
ORDER BY commonFriends DESC
LIMIT 10

// 聚合查询：每个城市的用户数
MATCH (u:User)
RETURN u.city AS city, count(*) AS userCount
ORDER BY userCount DESC
```

**关键语法说明：**
- `(n:Label)` — 节点模式
- `[r:REL_TYPE]` — 关系模式
- `->` 表示关系方向，无方向用 `--`
- `MATCH` 用于匹配模式，`WHERE` 用于过滤
- `RETURN` 可以返回节点、属性、聚合结果

---

## 三、Spring Data Neo4j 集成

### 3.1 环境准备

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-neo4j</artifactId>
</dependency>
```

### 3.2 配置连接

```yaml
# application.yml
spring:
  neo4j:
    uri: bolt://localhost:7687
    authentication:
      username: neo4j
      password: password
  data:
    neo4j:
      database: neo4j  # Neo4j 5.x 默认数据库
```

### 3.3 实体映射

```java
import org.springframework.data.neo4j.core.schema.*;

@Node("User")  // 对应节点的 :User 标签
public class User {

    @Id
    @GeneratedValue
    private Long id;

    @Property("name")
    private String name;

    @Property("age")
    private Integer age;

    @Property("city")
    private String city;

    // @Relationship 映射关系
    @Relationship(type = "FOLLOWS", direction = Direction.OUTGOING)
    private List<User> following;

    // 关系属性可借助中间实体
    @Relationship(type = "LIKES", direction = Direction.OUTGOING)
    private List<LikesRelationship> likedMovies;

    // getters/setters...
}

@RelationshipProperties
public class LikesRelationship {

    @RelationshipId
    private Long id;

    @Property("rating")
    private Integer rating;  // 评分

    @Property("createdAt")
    private LocalDateTime createdAt;

    @TargetNode
    private Movie movie;

    // getters/setters...
}

@Node("Movie")
public class Movie {

    @Id
    @GeneratedValue
    private Long id;

    @Property("title")
    private String title;

    @Property("genre")
    private String genre;

    @Property("year")
    private Integer year;

    // getters/setters...
}
```

### 3.4 Repository 层

```java
import org.springframework.data.neo4j.repository.Neo4jRepository;
import org.springframework.data.neo4j.repository.query.Query;
import java.util.List;

public interface UserRepository extends Neo4jRepository<User, Long> {

    // 基于方法命名查询
    User findByName(String name);

    List<User> findByCity(String city);

    // 自定义 Cypher 查询
    @Query("MATCH (u:User) WHERE u.age >= $minAge RETURN u ORDER BY u.age DESC")
    List<User> findUsersByMinAge(int minAge);

    // 好友的好友推荐（排除已关注）
    @Query("MATCH (me:User {name: $userName})-[:FOLLOWS]->(friend)-[:FOLLOWS]->(fof:User) " +
           "WHERE NOT (me)-[:FOLLOWS]->(fof) " +
           "RETURN fof, count(*) AS commonFriends " +
           "ORDER BY commonFriends DESC " +
           "LIMIT $limit")
    List<User> findFriendOfFriendRecommendations(String userName, int limit);

    // 电影推荐：关注的人喜欢的电影
    @Query("MATCH (me:User {name: $userName})-[:FOLLOWS]->(friend)-[:LIKES]->(m:Movie) " +
           "WHERE NOT (me)-[:LIKES]->(m) " +
           "RETURN m, avg(friend.rating) AS avgRating " +
           "ORDER BY avgRating DESC " +
           "LIMIT $limit")
    List<Movie> recommendMoviesByFollowing(String userName, int limit);

    // 共同关注者查询
    @Query("MATCH (u1:User {name: $userName1}), (u2:User {name: $userName2}) " +
           "MATCH (u1)-[:FOLLOWS]->(common)<-[:FOLLOWS]-(u2) " +
           "RETURN common")
    List<User> findMutualFollowings(String userName1, String userName2);
}
```

### 3.5 Service 层

```java
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

@Service
public class SocialRecommendationService {

    private final UserRepository userRepository;

    public SocialRecommendationService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Transactional
    public User createUser(String name, Integer age, String city) {
        User user = new User();
        user.setName(name);
        user.setAge(age);
        user.setCity(city);
        return userRepository.save(user);
    }

    @Transactional
    public void followUser(String followerName, String followeeName) {
        User follower = userRepository.findByName(followerName);
        User followee = userRepository.findByName(followeeName);
        if (follower.getFollowing() == null) {
            follower.setFollowing(new ArrayList<>());
        }
        follower.getFollowing().add(followee);
        userRepository.save(follower);
    }

    public List<User> getFriendRecommendations(String userName, int limit) {
        return userRepository.findFriendOfFriendRecommendations(userName, limit);
    }
}
```

---

## 四、实战案例：社交推荐系统

构建一个小型社交推荐系统，模拟用户关注和电影偏好推荐：

```java
@Component
public class DemoDataInitializer implements CommandLineRunner {

    private final UserRepository userRepository;
    private final MovieRepository movieRepository;

    @Override
    public void run(String... args) {
        // 1. 创建用户
        User alice = createUser("Alice", 28, "上海");
        User bob = createUser("Bob", 25, "北京");
        User charlie = createUser("Charlie", 30, "深圳");
        User dave = createUser("Dave", 27, "上海");
        User eve = createUser("Eve", 26, "北京");

        // 2. 创建电影
        Movie movie1 = createMovie("盗梦空间", "科幻", 2010);
        Movie movie2 = createMovie("星际穿越", "科幻", 2014);
        Movie movie3 = createMovie("肖申克的救赎", "剧情", 1994);
        Movie movie4 = createMovie("千与千寻", "动画", 2001);

        // 3. 建立关注关系
        follow(alice, bob);    // Alice 关注 Bob
        follow(alice, charlie);
        follow(bob, charlie);  // Bob 关注 Charlie
        follow(bob, dave);
        follow(charlie, dave);
        follow(charlie, eve);
        follow(dave, eve);

        // 4. 建立电影评分关系
        likeMovie(alice, movie1, 5);
        likeMovie(bob, movie2, 4);
        likeMovie(bob, movie3, 5);
        likeMovie(charlie, movie1, 4);
        likeMovie(charlie, movie4, 5);
        likeMovie(dave, movie2, 3);
        likeMovie(eve, movie3, 4);
        likeMovie(eve, movie4, 5);
    }
}
```

**查询 Alice 的推荐结果：**

```cypher
// 1. 好友推荐（二度好友）
推荐 Dave（共同关注者 Bob）
理由：Alice -> Bob -> Dave

// 2. 电影推荐（关注的人喜欢的电影）
推荐《星际穿越》—— Bob 喜欢的
推荐《肖申克的救赎》—— Bob 喜欢的
推荐《千与千寻》—— Charlie 喜欢的
```

---

## 五、Neo4j 性能优化策略

### 5.1 索引策略

```cypher
// 创建单属性索引
CREATE INDEX user_name_idx FOR (u:User) ON (u.name)

// 创建复合索引
CREATE INDEX user_city_age_idx FOR (u:User) ON (u.city, u.age)

// 创建全文索引
CREATE FULLTEXT INDEX user_names_fulltext FOR (n:User) ON EACH [n.name]
```

### 5.2 查询优化原则

```cypher
// 🔴 低效：先匹配所有再过滤
MATCH (u:User) WHERE u.city = "上海" AND u.age > 25

// 🟢 高效：使用参数化查询
MATCH (u:User {city: $city}) WHERE u.age > $minAge

// 🔴 低效：返回全部属性
MATCH (u:User)-[:FOLLOWS]->(f) RETURN *

// 🟢 高效：只返回需要的属性
MATCH (u:User)-[:FOLLOWS]->(f) RETURN u.name, f.name
```

### 5.3 分页查询

```cypher
MATCH (u:User)
RETURN u.name, u.city
ORDER BY u.name SKIP $offset LIMIT $limit
```

---

## 六、Neo4j vs 关系型数据库选型建议

| 场景 | 推荐方案 | 理由 |
|------|---------|------|
| 社交网络 | Neo4j | 多度关系查询性能优异 |
| 推荐引擎 | Neo4j | 个性化路径推荐天然支持 |
| 权限系统 | Neo4j | 角色继承/资源层级查询 |
| 风控反欺诈 | Neo4j | 异常关系环检测 |
| 订单系统 | MySQL | 强一致性 + 事务标准 |
| 内容管理 | MySQL | 简单 CRUD 无复杂关系 |
| 报表统计 | MySQL | 聚合查询更成熟 |

---

## 七、常见面试追问

**Q：Neo4j 的事务模型是怎样的？**
A：Neo4j 支持 ACID 事务，写操作使用悲观锁。READ_COMMITTED 隔离级别，支持死锁检测自动回滚。

**Q：大量数据写入性能如何？**
A：批量写入建议使用 `UNWIND $batch AS row CREATE...` 方式，而非逐条 `CREATE`。Neo4j 5.x 支持批量导入工具 `neo4j-admin database import`。

**Q：Neo4j 的存储结构是什么样的？**
A：使用"免索引邻接"（Index-free adjacency）——每个节点直接存储指向相邻关系的指针。关系存储在独立的关系文件中（双向链表结构），保证了遍历 O(1) 时间访问邻居。

---

## 总结

Neo4j 让关系查询变得优雅而高效。本文从 Cypher 基础到 Spring Data Neo4j 集成，再到一个完整的社交推荐案例，覆盖了图数据库的核心应用。在实际项目中，建议将 Neo4j 作为**关系查询的加速器**，与 MySQL 等关系型数据库配合使用，各自承担擅长的职责。
