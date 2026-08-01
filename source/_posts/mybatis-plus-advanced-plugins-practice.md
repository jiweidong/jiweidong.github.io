---
title: MyBatis-Plus 高级插件实战：乐观锁、逻辑删除、多租户与动态表名
date: 2026-08-01 08:20:00
tags:
  - MyBatis-Plus
  - 插件
  - 乐观锁
  - 多租户
categories:
  - Java
  - 数据库
author: 东哥
---

# MyBatis-Plus 高级插件实战：乐观锁、逻辑删除、多租户与动态表名

很多同学用 MyBatis-Plus 只停留在 `BaseMapper` CRUD 和 `Wrapper` 查询，遇到乐观锁、多租户、分表场景就手足无措。其实 MyBatis-Plus 内置的**拦截器插件体系**把这些企业级能力都封装好了，本文带你逐个击破：乐观锁、逻辑删除、多租户、动态表名四大插件的原理、配置与避坑。

<!-- more -->

## 一、MyBatis-Plus 插件机制：InnerInterceptor 是什么？

MyBatis-Plus 的插件全部基于 MyBatis 的 `Interceptor`（拦截器）机制实现，在执行 SQL 前后进行拦截改写。核心是 `MybatisPlusInterceptor`，它内部维护一组 `InnerInterceptor`（内部拦截器），按注册顺序依次对 SQL 进行增强：

```java
@Bean
public MybatisPlusInterceptor mybatisPlusInterceptor() {
    MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
    interceptor.addInnerInterceptor(new OptimisticLockerInnerInterceptor());   // 乐观锁
    interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL)); // 分页
    interceptor.addInnerInterceptor(new TenantLineInnerInterceptor(handler));  // 多租户
    interceptor.addInnerInterceptor(new DynamicTableNameInnerInterceptor());   // 动态表名
    return interceptor;
}
```

> **关键点**：拦截器有执行顺序。比如多租户和分页同时用时，建议**租户拦截器放在分页之前**，否则分页 SQL 中的 COUNT 查询可能带上错误的表名替换。

## 二、乐观锁：OptimisticLockerInnerInterceptor

### 1. 为什么需要乐观锁

高并发下更新同一行数据会互相覆盖（丢失更新）。悲观锁用 `SELECT ... FOR UPDATE` 锁行，代价高；乐观锁用版本号机制：**更新时比对版本号，版本号一致才更新并 +1，否则更新失败重试**。

### 2. 使用步骤

**第一步：实体类加 @Version 字段**

```java
@Data
public class Product {
    private Long id;
    private String name;
    private BigDecimal price;
    @Version
    private Integer version;   // 版本号字段
}
```

**第二步：注册拦截器**（见上文）

**第三步：正常调用 update**

```java
Product p = productMapper.selectById(1L);
p.setPrice(new BigDecimal("99.00"));
productMapper.updateById(p);
// 生成的 SQL：
// UPDATE product SET price=99.00, version=version+1 WHERE id=1 AND version=1
```

### 3. 原理与避坑

- **原理**：拦截器在 update 时自动把实体里的 `version` 值拼进 `WHERE` 条件，同时把 `SET version = version + 1`。
- **返回影响行数为 0** 说明版本冲突，需要业务重试（通常配合循环重试 3 次）。
- **update 时 version 必须从数据库查出**，不能自己 new 一个 0。
- 只对 `updateById` / `update(entity, wrapper)` 生效；**手写 XML SQL 不生效**，需要手动写 `WHERE version = #{version}`。

## 三、逻辑删除：delete 变 update

### 1. 配置

```yaml
mybatis-plus:
  global-config:
    db-config:
      logic-delete-field: deleted      # 全局逻辑删除字段
      logic-delete-value: 1            # 已删除
      logic-not-delete-value: 0        # 未删除
```

实体类加字段：

```java
@TableLogic
private Integer deleted;
```

### 2. 行为表现

- `deleteById(1L)` → 实际执行 `UPDATE user SET deleted=1 WHERE id=1 AND deleted=0`
- 普通查询自动追加 `AND deleted=0`
- 手动 `SELECT * FROM user`（XML）**不会**自动过滤，需要自己加条件

### 3. 三个大坑

1. **唯一索引冲突**：逻辑删除后数据还在表里，重建同用户名/同手机号会撞唯一索引。解决：唯一索引字段拼接 deleted（如 `uk(user_name, deleted)`），或用删除时间戳做标记字段。
2. **count 统计失真**：所有统计都要意识到带 `deleted=0` 条件。
3. **物理清理**：逻辑删除的数据需要定时任务真正清理或归档，否则表无限膨胀。

## 四、多租户：TenantLineInnerInterceptor

SaaS 系统最常见的"一表多租户"方案：所有表加 `tenant_id` 字段，SQL 执行时**自动追加租户条件**，业务代码零侵入。

### 1. 实现 TenantLineHandler

```java
@Configuration
public class TenantConfig {

    @Bean
    public TenantLineHandler tenantLineHandler() {
        return new TenantLineHandler() {
            @Override
            public Expression getTenantId() {
                // 从上下文（ThreadLocal/请求头）取当前租户
                Long tenantId = TenantContext.getCurrentTenantId();
                return new LongValue(tenantId);
            }

            @Override
            public String getTenantIdColumn() {
                return "tenant_id";
            }

            @Override
            public boolean ignoreTable(String tableName) {
                // 忽略某些表：字典表、系统配置表等
                return IGNORE_TABLES.contains(tableName);
            }
        };
    }
}
```

### 2. 拦截效果

```java
userMapper.selectList(null);
// 实际 SQL：SELECT id, name, tenant_id FROM user WHERE tenant_id = 1001

userMapper.deleteById(5L);
// 实际 SQL：UPDATE user SET deleted=1 WHERE id=5 AND tenant_id=1001
```

**INSERT 也会自动补 tenant_id**，查询、更新、删除全链路自动加条件，这是它最大的价值——**从根上杜绝跨租户数据泄漏**。

### 3. 避坑清单

- **join 多表**：所有参与 join 的表都要有 tenant_id 或加入 ignoreTable，否则解析出错
- **手写 SQL**：XML 里的 SQL 同样会被拦截改写，但要保证 SQL 能被正确解析（复杂 SQL 建议验证）
- **租户上下文传递**：用 ThreadLocal 存租户，注意线程池场景要手动传递，防止串租户（这属于严重事故！）
- **定时任务/异步任务**：没有请求上下文，必须显式设置租户

## 五、动态表名：DynamicTableNameInnerInterceptor

分表场景（如订单表按月份分表 `order_202601`、`order_202602`）用它最方便：逻辑上还是写 `order`，执行时自动替换成真实表名。

```java
@Bean
public DynamicTableNameInnerInterceptor dynamicTableNameInnerInterceptor() {
    DynamicTableNameInnerInterceptor interceptor = new DynamicTableNameInnerInterceptor();
    interceptor.setTableNameHandler((sql, tableName) -> {
        if ("order".equals(tableName)) {
            String ym = DateUtil.format(new Date(), "yyyyMM");
            return "order_" + ym;   // 返回真实表名
        }
        return tableName;
    });
    return interceptor;
}
```

注意点：

- 表名替换是**全局生效**的，多个 mapper 用同一逻辑表名时要保证替换规则一致
- 跨月查询需要自己写 Union SQL 或分多次查询
- 动态表名与多租户拦截器叠加时，注意执行顺序（一般租户在前、表名在后）

## 六、完整实战：订单系统组合拳

```java
// 配置
@Bean
public MybatisPlusInterceptor mybatisPlusInterceptor(TenantLineHandler tenantHandler) {
    MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
    interceptor.addInnerInterceptor(new TenantLineInnerInterceptor(tenantHandler)); // 多租户
    interceptor.addInnerInterceptor(new OptimisticLockerInnerInterceptor());        // 乐观锁
    interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));  // 分页
    interceptor.addInnerInterceptor(new DynamicTableNameInnerInterceptor());        // 动态表名
    return interceptor;
}

// 业务：下单 + 扣库存（乐观锁防超卖）
@Transactional
public boolean placeOrder(OrderDTO dto) {
    Product product = productMapper.selectById(dto.getProductId());
    int rows = productMapper.updateStock(product.getId(), dto.getCount(), product.getVersion());
    if (rows == 0) {
        throw new BizException("库存已变化，请重试");   // 乐观锁冲突
    }
    return orderMapper.insert(convert(dto)) > 0;
}
```

## 七、面试官追问

**Q1：乐观锁和悲观锁怎么选？**
答：读多写少、冲突概率低的场景用乐观锁（版本号），实现简单、无锁开销；写冲突频繁、对一致性要求极高的场景用悲观锁（SELECT FOR UPDATE）。秒杀扣库存这类热点写，通常用乐观锁 + 重试或 Redis 预扣。

**Q2：多租户方案有哪些？**
答：三种：① 独立数据库（隔离最好、成本最高）；② 共享库独立 Schema（中等隔离）；③ 共享表 + tenant_id 字段（成本最低，MyBatis-Plus 拦截器方案，靠 SQL 自动追加条件保证隔离）。选型取决于租户数据敏感度和规模。

**Q3：逻辑删除和物理删除怎么选？**
答：业务数据建议逻辑删除（可恢复、保留审计线索），但要处理唯一索引冲突和定期归档；日志类、临时数据直接物理删除。两者结合：逻辑删除标记 + 定时任务物理清理。

**Q4：分表后 MyBatis-Plus 还能用吗？**
答：能。动态表名插件适合按固定规则（时间、哈希取模）分表；更复杂的分片策略（范围+取模组合）建议用 ShardingSphere，它对应用透明，支持更完整的分片、读写分离能力。

## 总结

MyBatis-Plus 的四大拦截器把企业级数据访问的痛点都封装好了：**乐观锁防并发覆盖、逻辑删除保数据可恢复、多租户拦截器防数据越权、动态表名解决分表**。用好这套组合拳，业务代码可以保持极致的简洁。最后再强调一遍：拦截器顺序、租户上下文传递、手写 SQL 的兼容性，是生产环境最容易翻车的三个点。
