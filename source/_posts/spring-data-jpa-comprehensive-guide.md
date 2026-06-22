---
title: Spring Data JPA 实战：从入门到性能优化
date: 2026-06-22 08:10:00
tags:
  - Java
  - Spring
  - JPA
  - 数据库
categories:
  - Java
  - Spring生态
author: 东哥
---

# Spring Data JPA 实战：从入门到性能优化

## 一、JPA 是什么？为什么还要学 JPA？

很多 Java 开发者对 JPA 的印象停留在"慢""黑盒""复杂"上，转而投向 MyBatis 的怀抱。但其实，当你真正理解了 JPA 的设计思想，它在**单表操作、关联查询、多租户、审计日志**等场景下能极大提升开发效率。

JPA（Java Persistence API）是 Java EE 规范中的持久化标准。Spring Data JPA 是对 JPA 的进一步封装，让你只写接口就能完成数据库操作。

## 二、快速入门：一个完整的例子

### 2.1 依赖引入

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>
<dependency>
    <groupId>com.mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
    <scope>runtime</scope>
</dependency>
```

### 2.2 配置文件

```yaml
spring:
  jpa:
    hibernate:
      ddl-auto: update          # 开发阶段用 update，生产用 validate
    show-sql: true              # 显示SQL（开发调试用）
    properties:
      hibernate:
        format_sql: true
        dialect: org.hibernate.dialect.MySQLDialect
    open-in-view: false         # 关闭 OSIV，避免懒加载陷阱
```

### 2.3 实体类

```java
@Entity
@Table(name = "users")
@Data
@NoArgsConstructor
@AllArgsConstructor
public class User {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    @Column(nullable = false, unique = true, length = 50)
    private String username;
    
    @Column(nullable = false)
    private String password;
    
    @Column(length = 100)
    private String email;
    
    @Enumerated(EnumType.STRING)
    private UserStatus status;
    
    @CreationTimestamp
    private LocalDateTime createdAt;
    
    @UpdateTimestamp
    private LocalDateTime updatedAt;
}

public enum UserStatus {
    ACTIVE, INACTIVE, LOCKED
}
```

### 2.4 Repository 接口

```java
public interface UserRepository extends JpaRepository<User, Long> {
    // 根据用户名查询
    Optional<User> findByUsername(String username);
    
    // 模糊查询
    List<User> findByUsernameLike(String keyword);
    
    // 多条件组合
    List<User> findByStatusAndCreatedAtAfter(UserStatus status, LocalDateTime after);
    
    // 统计
    long countByStatus(UserStatus status);
    
    // 分页
    Page<User> findByStatus(UserStatus status, Pageable pageable);
}
```

不需要写任何实现类！Spring Data JPA 通过方法名自动生成 SQL。

### 2.5 使用

```java
@Service
@RequiredArgsConstructor
public class UserService {
    private final UserRepository userRepository;
    
    public User createUser(User user) {
        return userRepository.save(user);
    }
    
    public Page<User> listActiveUsers(int page, int size) {
        return userRepository.findByStatus(
            UserStatus.ACTIVE, 
            PageRequest.of(page, size, Sort.by("createdAt").descending())
        );
    }
}
```

## 三、核心注解详解

### 3.1 实体映射

| 注解 | 用途 | 常用属性 |
|------|------|----------|
| `@Entity` | 标记为JPA实体 | name（实体名称） |
| `@Table` | 指定映射表 | name, schema, uniqueConstraints |
| `@Column` | 字段映射 | name, nullable, unique, length, columnDefinition |
| `@Enumerated` | 枚举映射 | ORDINAL（数字）/ STRING（字符串） |
| `@Lob` | 大字段 | 对应 TEXT/BLOB |
| `@Transient` | 忽略字段 | 不持久化 |

### 3.2 关联关系

```java
@Entity
public class Order {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    // 多对一（默认Eager，建议用FetchType.LAZY）
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id")
    private User user;
    
    // 一对多（默认Lazy）
    @OneToMany(mappedBy = "order", cascade = CascadeType.ALL, orphanRemoval = true)
    private List<OrderItem> items = new ArrayList<>();
    
    // 一对一
    @OneToOne(mappedBy = "order", fetch = FetchType.LAZY)
    private Payment payment;
    
    // 多对多
    @ManyToMany
    @JoinTable(
        name = "order_tags",
        joinColumns = @JoinColumn(name = "order_id"),
        inverseJoinColumns = @JoinColumn(name = "tag_id")
    )
    private Set<Tag> tags = new HashSet<>();
}
```

**⚠️ 关联关系的常见陷阱：**

1. **N+1 查询问题** — FetchType.LAZY + @EntityGraph 解决
2. **双向关联需要两边维护** — 用 `addXxx()` / `removeXxx()` 辅助方法
3. **级联删除要谨慎** — CascadeType.REMOVE 可能误删大量数据

### 3.3 联合主键

```java
// 方式一：@IdClass
@Data
public class OrderItemId implements Serializable {
    private Long orderId;
    private Long productId;
}

@Entity
@IdClass(OrderItemId.class)
public class OrderItem {
    @Id
    private Long orderId;
    @Id
    private Long productId;
    private Integer quantity;
}

// 方式二：@EmbeddedId
@Embeddable
@Data
public class OrderItemId implements Serializable {
    private Long orderId;
    private Long productId;
}

@Entity
public class OrderItem {
    @EmbeddedId
    private OrderItemId id;
    private Integer quantity;
}
```

推荐使用 `@EmbeddedId`，更面向对象。

## 四、高级查询技巧

### 4.1 方法命名查询

Spring Data JPA 的方法命名规则非常强大：

| 关键字 | 示例 | SQL片段 |
|--------|------|---------|
| `And` | `findByNameAndAge` | WHERE name=? AND age=? |
| `Or` | `findByNameOrAge` | WHERE name=? OR age=? |
| `Between` | `findByAgeBetween` | WHERE age BETWEEN ? AND ? |
| `LessThan` | `findByAgeLessThan` | WHERE age < ? |
| `GreaterThanEqual` | `findByAgeGreaterThanEqual` | WHERE age >= ? |
| `IsNull` | `findByNameIsNull` | WHERE name IS NULL |
| `In` | `findByAgeIn` | WHERE age IN (?) |
| `OrderBy` | `findByAgeOrderByNameDesc` | ORDER BY name DESC |
| `IgnoreCase` | `findByNameIgnoreCase` | WHERE UPPER(name)=UPPER(?) |
| `Top/First` | `findTop10ByOrderByAgeDesc` | LIMIT 10 |

### 4.2 @Query 自定义查询

复杂场景用 JPQL：

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    
    @Query("SELECT o FROM Order o JOIN FETCH o.user WHERE o.status = :status")
    List<Order> findByStatusWithUser(@Param("status") OrderStatus status);
    
    @Query(value = "SELECT * FROM orders o WHERE o.total_amount > :min GROUP BY o.user_id HAVING COUNT(*) > :count",
           countQuery = "SELECT COUNT(*) FROM (SELECT 1 FROM orders ...) t",
           nativeQuery = true)
    Page<Order> findLargeOrders(@Param("min") BigDecimal min, @Param("count") long count, Pageable pageable);
}
```

**JPQL vs 原生 SQL 选择：**
- JPQL：跨数据库、自动映射实体、支持懒加载
- 原生 SQL：复杂查询、数据库特定函数、批量操作

### 4.3 @EntityGraph 解决 N+1

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    
    @EntityGraph(attributePaths = {"user", "items.product"})
    @Query("SELECT o FROM Order o WHERE o.id IN :ids")
    List<Order> findByIdsWithDetails(@Param("ids") List<Long> ids);
}
```

等价于 `JOIN FETCH`，但更声明式，可以复用：

```java
@EntityGraph("Order.detail")
@Query("SELECT o FROM Order o WHERE o.status = :status")
List<Order> findByStatusWithDetail(@Param("status") OrderStatus status);
```

在实体类上定义：

```java
@Entity
@NamedEntityGraph(name = "Order.detail",
    attributeNodes = {
        @NamedAttributeNode("user"),
        @NamedAttributeNode(value = "items", subgraph = "items")
    },
    subgraphs = {
        @NamedSubgraph(name = "items", attributeNodes = @NamedAttributeNode("product"))
    })
public class Order { ... }
```

### 4.4 Specification 动态查询

复杂动态条件查询：

```java
public class OrderSpecifications {
    public static Specification<Order> byStatus(OrderStatus status) {
        return (root, query, cb) -> 
            status == null ? null : cb.equal(root.get("status"), status);
    }
    
    public static Specification<Order> byAmountGreaterThan(BigDecimal min) {
        return (root, query, cb) -> 
            cb.greaterThan(root.get("totalAmount"), min);
    }
    
    public static Specification<Order> byCreatedAfter(LocalDateTime after) {
        return (root, query, cb) ->
            cb.greaterThan(root.get("createdAt"), after);
    }
    
    public static Specification<Order> byUsername(String username) {
        return (root, query, cb) -> {
            Join<Order, User> userJoin = root.join("user");
            return cb.like(userJoin.get("username"), "%" + username + "%");
        };
    }
}
```

组合使用：

```java
@Service
public class OrderQueryService {
    private final OrderRepository orderRepository;
    
    public Page<Order> searchOrders(OrderSearchCriteria criteria) {
        Specification<Order> spec = Specification
            .where(OrderSpecifications.byStatus(criteria.getStatus()))
            .and(OrderSpecifications.byAmountGreaterThan(criteria.getMinAmount()))
            .and(OrderSpecifications.byCreatedAfter(criteria.getStartDate()));
        
        if (StringUtils.hasText(criteria.getUsername())) {
            spec = spec.and(OrderSpecifications.byUsername(criteria.getUsername()));
        }
        
        return orderRepository.findAll(spec, criteria.toPageable());
    }
}
```

### 4.5 QueryDSL（更强力的动态查询）

推荐在复杂项目中使用 QueryDSL：

```java
// 生成 Q 类
QUser qUser = QUser.user;
JPAQueryFactory queryFactory = new JPAQueryFactory(entityManager);

List<User> users = queryFactory
    .selectFrom(qUser)
    .where(qUser.status.eq(UserStatus.ACTIVE)
        .and(qUser.createdAt.after(LocalDateTime.now().minusDays(7))))
    .orderBy(qUser.createdAt.desc())
    .offset(0)
    .limit(20)
    .fetch();
```

## 五、性能优化实战

### 5.1 N+1 问题详解

```java
// ❌ 糟糕：遍历用户时每个用户触发一次查询
List<User> users = userRepository.findAll();
for (User user : users) {
    System.out.println(user.getOrders().size());  // N+1!
}
```

**解决方案：**

| 方案 | 优点 | 缺点 |
|------|------|------|
| `JOIN FETCH` | 一次查询、简单直接 | 多条数据重复，分页可能不准 |
| `@EntityGraph` | 声明式、可复用 | 定义略繁琐 |
| `@BatchSize` | 批量懒加载 | 仍然是N+1只是批量 |
| DTO投影 | 只查需要的字段 | 需要额外定义 |

### 5.2 分页优化

```java
// ❌ 错误：COUNT 查询很慢
Page<User> page = userRepository.findAll(pageable);

// ✅ 优化：使用自定义 count 查询
@Query(value = "SELECT u FROM User u WHERE u.status = :status",
       countQuery = "SELECT COUNT(u.id) FROM User u WHERE u.status = :status")
Page<User> findByStatusWithCount(@Param("status") UserStatus status, Pageable pageable);
```

**分页最佳实践：**
- 用 `Slice` 代替 `Page`（不需要总条数时）
- 禁用 `countQuery` 用近似值替代
- 避免大数据量下的深度分页（用游标或 keyset pagination）

### 5.3 只读事务优化

```java
// 查询方法显式标注只读
@Transactional(readOnly = true)
public User getUserById(Long id) {
    return userRepository.findById(id).orElse(null);
}
// 批量查询设置 Hibernate 批处理
spring.jpa.properties.hibernate.jdbc.batch_size=50
spring.jpa.properties.hibernate.order_inserts=true
spring.jpa.properties.hibernate.order_updates=true
```

### 5.4 避免 OSIV 陷阱

OSIV（Open Session In View）默认开启，会导致事务结束后仍然持有数据库连接：

```yaml
spring.jpa.open-in-view: false  # 必须关掉！
```

关闭后遇到懒加载会抛 `LazyInitializationException`，**这才是正确行为**——迫使你提前规划好查询范围。

### 5.5 数据投影（DTO）

只查需要的字段，避免查整表：

```java
// 接口投影
public interface UserSummary {
    Long getId();
    String getUsername();
}

// 类投影
@Value
public class UserDTO {
    Long id;
    String username;
    String email;
}

public interface UserRepository extends JpaRepository<User, Long> {
    // 接口投影
    List<UserSummary> findByStatus(UserStatus status);
    
    // 类投影
    @Query("SELECT new com.example.dto.UserDTO(u.id, u.username, u.email) FROM User u WHERE u.status = :status")
    List<UserDTO> findUserDTOsByStatus(@Param("status") UserStatus status);
}
```

## 六、Spring Data JPA 中的事务管理

### 6.1 事务传播行为

```java
@Service
public class OrderService {
    
    @Transactional(propagation = Propagation.REQUIRED)  // 默认，支持当前事务
    public void createOrder(Order order) { ... }
    
    @Transactional(propagation = Propagation.REQUIRES_NEW)  // 挂起当前，开启新事务
    public void logAudit(AuditLog log) { ... }
    
    @Transactional(propagation = Propagation.NESTED)  // 嵌套事务（Savepoint）
    public void updateInventory(Long productId, int quantity) { ... }
}
```

### 6.2 事务隔离级别

```java
@Transactional(isolation = Isolation.REPEATABLE_READ)
public void processPayment(Long orderId) { ... }
```

| 隔离级别 | 脏读 | 不可重复读 | 幻读 |
|----------|------|------------|------|
| READ_UNCOMMITTED | ✅ 可能 | ✅ 可能 | ✅ 可能 |
| READ_COMMITTED | ❌ | ✅ 可能 | ✅ 可能 |
| REPEATABLE_READ | ❌ | ❌ | ✅ 可能 |
| SERIALIZABLE | ❌ | ❌ | ❌ |

## 七、最佳实践总结

### ✅ 推荐做法

1. **实体设计**
   - 用 `Long` 而非 `long` 做主键（支持 null 值判断）
   - 用 `@CreationTimestamp` 和 `@UpdateTimestamp` 自动管理时间
   - 用 `@Enumerated(EnumType.STRING)` 而非 ORDINAL
   - 重写 `equals()` 和 `hashCode()` 基于业务主键

2. **查询优化**
   - 始终考虑 N+1，用 `@EntityGraph` 或 `JOIN FETCH`
   - 复杂查询用 `Specification` 或 QueryDSL
   - 只读查询标注 `@Transactional(readOnly = true)`

3. **事务管理**
   - Service 层控制事务边界
   - 避免在循环中调用 Repository
   - 长时间事务内避免远程调用

### ❌ 避坑指南

1. **不要过度使用 CascadeType.ALL** — 级联删除可能导致意外的数据丢失
2. **不要忽略 FetchType** — 默认的 @ManyToOne(fetch = EAGER) 需要改为 LAZY
3. **不要在大表中用 `findAll()`** — 一定要分页
4. **不要用 `@OneToMany(fetch = EAGER)`** — 会笛卡尔积爆炸
5. **不要在循环中调用 `save()`** — 用 `saveAll()` 批处理
6. **不要忽略 equals/hashCode** — Set 集合中的实体比较会出问题

## 八、总结

Spring Data JPA 的学习曲线确实比 MyBatis 陡峭，但一旦掌握，它能让你：
- **减少 60% 以上的模板代码**
- **自动处理关联关系和级联操作**
- **提供声明式查询，更易维护**
- **与 Spring 生态深度整合**

选择 JPA 还是 MyBatis，本质上是在"开发效率"和"SQL 控制力"之间做 trade-off。对于 **单表 CRUD 密集型** 的业务系统，JPA 是最佳选择；对于 **复杂 SQL / 报表 / 大数据量** 场景，MyBatis 更合适。**两者完全可以共存**在一个项目中。
