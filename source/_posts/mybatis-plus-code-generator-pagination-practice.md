---
title: MyBatis-Plus 代码生成器与分页插件深度实战：从自动化 CRUD 到企业级最佳实践
date: 2026-07-08 08:00:00
tags:
  - MyBatis-Plus
  - 代码生成器
  - 分页
  - CRUD
categories:
  - Java
  - MyBatis
author: 东哥
---

# MyBatis-Plus 代码生成器与分页插件深度实战：从自动化 CRUD 到企业级最佳实践

## 前言

在 Java 后端开发中，**CRUD 代码的重复劳动**一直是痛点。MyBatis-Plus 的 **代码生成器（Code Generator）** 和 **分页插件（Pagination Plugin）**，是解决这个问题的两大利器。

然而很多开发者对它们的认知仅停留在"一键生成"和"直接分页"的层面，遇到复杂场景就束手无策。本文将从源码和实战两个维度，带你彻底掌握这两个核心组件。

---

## 一、MyBatis-Plus 代码生成器：从入门到自定义模板

### 1.1 快速上手：传统方式（MyBatis-Plus 3.5.x）

最新版的 MyBatis-Plus 代码生成器使用 **Lambda 风格 API**，配置更加简洁：

```xml
<!-- pom.xml -->
<dependency>
    <groupId>com.baomidou</groupId>
    <artifactId>mybatis-plus-generator</artifactId>
    <version>3.5.7</version>
</dependency>
<dependency>
    <groupId>org.apache.velocity</groupId>
    <artifactId>velocity-engine-core</artifactId>
    <version>2.3</version>
</dependency>
```

```java
public class CodeGenerator {

    public static void main(String[] args) {
        // 数据源配置
        FastAutoGenerator.create("jdbc:mysql://localhost:3306/my_db?useUnicode=true&characterEncoding=utf-8",
                        "root", "password")
                // 全局配置
                .globalConfig(builder -> {
                    builder.author("东哥")                    // 作者
                           .outputDir("/tmp/code-output")     // 输出目录
                           .dateType(DateType.TIME_PACK)      // 时间策略
                           .commentDate("2026-07-08")         // 注释日期
                           .disableOpenDir();                 // 不打开目录
                })
                // 包配置
                .packageConfig(builder -> {
                    builder.parent("com.example.demo")
                           .entity("entity")
                           .service("service")
                           .serviceImpl("service.impl")
                           .mapper("mapper")
                           .controller("controller");
                })
                // 策略配置
                .strategyConfig(builder -> {
                    builder.addInclude("user", "order", "product")  // 表名
                           .addTablePrefix("t_", "sys_");           // 表前缀过滤

                    // Entity 策略
                    builder.entityBuilder()
                           .enableLombok()                          // 使用 Lombok
                           .enableChainModel()                      // 链式调用
                           .enableTableFieldAnnotation()            // 字段注解
                           .versionColumnName("version")            // 乐观锁字段
                           .logicDeleteColumnName("deleted");       // 逻辑删除字段

                    // Controller 策略
                    builder.controllerBuilder()
                           .enableRestStyle();                      // @RestController

                    // Service 策略
                    builder.serviceBuilder()
                           .formatServiceFileName("%sService");     // 接口命名
                })
                // 模板引擎配置（默认 Velocity）
                .templateEngine(new VelocityTemplateEngine())
                // 执行生成
                .execute();
    }
}
```

**生成的文件结构：**

```
/tmp/code-output/
├── com/example/demo/
│   ├── entity/
│   │   ├── User.java
│   │   ├── Order.java
│   │   └── Product.java
│   ├── mapper/
│   │   ├── UserMapper.java
│   │   ├── OrderMapper.java
│   │   └── ProductMapper.java
│   ├── service/
│   │   ├── UserService.java
│   │   ├── OrderService.java
│   │   └── ProductService.java
│   └── service/impl/
│       ├── UserServiceImpl.java
│       ├── OrderServiceImpl.java
│       └── ProductServiceImpl.java
```

### 1.2 自定义模板：摆脱千篇一律

大多数公司有自己**统一的编码规范**，比如 Controller 层必须统一返回 `R<T>`、必须包含 Swagger 注解等。

**Step 1: 创建自定义模板文件**

在 `resources/templates/` 目录下创建 `my-controller.java.vm`：

```velocity
## 自定义 Controller 模板
package ${package.Controller};

import ${package.Entity}.${entity};
import ${package.Service}.${table.serviceName};
import com.example.common.R;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.tags.Tag;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import javax.validation.Valid;

#if(${restControllerStyle})
@RestController
#else
@Controller
#end
@RequestMapping("/api/#if(${controllerMappingHyphenStyle})${controllerMappingHyphen}#else${table.entityPath}#end")
@Tag(name = "${table.comment}管理")
@RequiredArgsConstructor
#if(${kotlin})
class ${table.controllerName}#if(${superControllerClass}) : ${superControllerClass}()#end
#else
#if(${superControllerClass})
public class ${table.controllerName} extends ${superControllerClass} {
#else
public class ${table.controllerName} {
#end

    private final ${table.serviceName} ${table.entityPath}Service;

    @GetMapping
    @Operation(summary = "分页查询${table.comment}")
    public R<Page<${entity}>> page(PageParam param) {
        return R.ok(${table.entityPath}Service.page(param.toPage()));
    }

    @GetMapping("/{id}")
    @Operation(summary = "根据ID查询${table.comment}")
    public R<${entity}> get(@PathVariable Long id) {
        return R.ok(${table.entityPath}Service.getById(id));
    }

    @PostMapping
    @Operation(summary = "新增${table.comment}")
    public R<Void> add(@Valid @RequestBody ${entity} ${table.entityPath}) {
        ${table.entityPath}Service.save(${table.entityPath});
        return R.ok();
    }

    @PutMapping("/{id}")
    @Operation(summary = "修改${table.comment}")
    public R<Void> update(@PathVariable Long id, @Valid @RequestBody ${entity} ${table.entityPath}) {
        ${table.entityPath}.setId(id);
        ${table.entityPath}Service.updateById(${table.entityPath});
        return R.ok();
    }

    @DeleteMapping("/{id}")
    @Operation(summary = "删除${table.comment}")
    public R<Void> delete(@PathVariable Long id) {
        ${table.entityPath}Service.removeById(id);
        return R.ok();
    }
}
#end
```

**Step 2: 使用自定义模板**

```java
FastAutoGenerator.create("jdbc:mysql://...", "root", "password")
    // ... 其他配置
    .templateConfig(builder -> {
        builder.controller("/templates/my-controller.java.vm")  // 自定义 Controller 模板
               .entity("/templates/my-entity.java.vm")          // 自定义 Entity 模板
               .mapper("/templates/my-mapper.java.vm");         // 自定义 Mapper 模板
    })
    .execute();
```

### 1.3 模板引擎对比

| 模板引擎 | 依赖 | 语法 | 性能 | 推荐度 |
|----------|------|------|------|--------|
| **Velocity** | `velocity-engine-core` | `$xxx`, `#foreach` | 快 | ⭐⭐⭐ 默认 |
| **Freemarker** | `freemarker` | `${xxx}`, `<#list>` | 快 | ⭐⭐⭐ |
| **Beetl** | `beetl` | `@{xxx}`, `for()` | 最快 | ⭐⭐⭐⭐ |
| **Enjoy** | `jfinal-enjoy` | `#()`, `#for()` | 快 | ⭐⭐ |

```java
// 切换到 Freemarker 模板引擎
.templateEngine(new FreemarkerTemplateEngine())
```

---

## 二、MyBatis-Plus 分页插件：从配置到源码

### 2.1 分页插件配置

```java
@Configuration
public class MyBatisPlusConfig {

    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor() {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();

        // 添加分页拦截器
        PaginationInnerInterceptor pagination = new PaginationInnerInterceptor(DbType.MYSQL);
        pagination.setMaxLimit(500L);        // 单页最大条数限制
        pagination.setOverflow(false);       // 超出总页数是否回正
        pagination.setOptimizeJoin(true);    // 优化 COUNT 查询

        interceptor.addInnerInterceptor(pagination);

        // 添加乐观锁拦截器（可选）
        interceptor.addInnerInterceptor(new OptimisticLockerInnerInterceptor());

        // 添加防止全表更新/删除拦截器（推荐）
        interceptor.addInnerInterceptor(new BlockAttackInnerInterceptor());

        return interceptor;
    }
}
```

### 2.2 分页查询实战

```java
// ====== 基础分页 ======
Page<User> page = new Page<>(1, 10);
Page<User> result = userMapper.selectPage(page, null);
System.out.println("总条数: " + result.getTotal());
System.out.println("当前页: " + result.getCurrent());
System.out.println("每页条数: " + result.getSize());
System.out.println("总页数: " + result.getPages());
System.out.println("是否有上一页: " + result.hasPrevious());
System.out.println("是否有下一页: " + result.hasNext());
result.getRecords().forEach(System.out::println);

// ====== 条件分页 ======
Page<User> page = new Page<>(1, 10);
LambdaQueryWrapper<User> wrapper = Wrappers.lambdaQuery(User.class)
        .eq(User::getStatus, 1)
        .like(User::getName, "张")
        .orderByDesc(User::getCreateTime);
Page<User> result = userMapper.selectPage(page, wrapper);

// ====== 自定义 SQL 分页（多表关联） ======
// Mapper 接口
@Mapper
public interface UserMapper extends BaseMapper<User> {
    IPage<UserVO> selectUserOrders(Page<?> page, @Param("name") String name);
}

// Mapper XML
// <select id="selectUserOrders" resultType="com.example.demo.vo.UserVO">
//   SELECT u.*, COUNT(o.id) AS order_count
//   FROM user u
//   LEFT JOIN `order` o ON u.id = o.user_id
//   WHERE u.name LIKE CONCAT('%', #{name}, '%')
//   GROUP BY u.id
//   ORDER BY u.id DESC
// </select>

// Service 调用
Page<UserVO> page = new Page<>(1, 10, 100); // 第三个参数为 total，传负数自动 COUNT
IPage<UserVO> result = userMapper.selectUserOrders(page, "张三");
```

### 2.3 分页参数封装最佳实践

```java
/**
 * 通用分页请求参数
 */
@Data
public class PageParam {
    @Min(1) @ApiModelProperty("页码")
    private Integer pageNo = 1;

    @Min(1) @Max(500) @ApiModelProperty("每页条数")
    private Integer pageSize = 20;

    @ApiModelProperty("排序字段")
    private String orderBy;

    @ApiModelProperty("排序方向：asc / desc")
    private String orderDir = "desc";

    public <T> Page<T> toPage() {
        Page<T> page = new Page<>(pageNo, pageSize);
        if (StringUtils.hasText(orderBy)) {
            page.addOrder(new OrderItem(orderBy, "asc".equalsIgnoreCase(orderDir)));
        }
        return page;
    }
}

/**
 * 通用分页响应
 */
@Data
@ApiModel("分页响应")
public class PageResult<T> {
    @ApiModelProperty("数据列表")
    private List<T> list;

    @ApiModelProperty("总条数")
    private Long total;

    @ApiModelProperty("总页数")
    private Long pages;

    @ApiModelProperty("当前页")
    private Long current;

    @ApiModelProperty("每页条数")
    private Long size;

    public static <T> PageResult<T> of(IPage<T> page) {
        PageResult<T> result = new PageResult<>();
        result.setList(page.getRecords());
        result.setTotal(page.getTotal());
        result.setPages(page.getPages());
        result.setCurrent(page.getCurrent());
        result.setSize(page.getSize());
        return result;
    }
}

// Controller 中使用
@GetMapping
@Operation(summary = "分页查询用户")
public R<PageResult<UserVO>> page(PageParam param) {
    Page<User> page = param.toPage();
    IPage<UserVO> result = userMapper.selectUserOrders(page, null);
    return R.ok(PageResult.of(result));
}
```

---

## 三、分页插件源码解析

### 3.1 分页执行流程

```
用户调用 selectPage()
    ↓
MybatisPlusInterceptor.intercept()
    ↓
PaginationInnerInterceptor.beforeQuery()  ← 核心拦截逻辑
    ↓
1. 解析 IPage 参数，获取分页信息
2. 判断是否执行 COUNT 查询（见下方规则）
3. 改写 SQL：在原 SQL 外层包上 SELECT COUNT(1) FROM ( ... )
4. 改写 SQL：追加 LIMIT ?, ? 语句
    ↓
执行 COUNT 和 分页 SQL，组装 Page 对象返回
```

### 3.2 COUNT 查询优化

```java
// PaginationInnerInterceptor 中关键的优化点：

/**
 * 判断是否需要执行 COUNT 查询
 */
protected boolean needCount(Page<?> page) {
    // 用户手动传入 total 则不执行 COUNT
    if (page.isSearchCount()) {
        return false;
    }
    // 如果 total 已经是正数，跳过 COUNT
    return page.getTotal() <= 0;
}

/**
 * 优化 COUNT SQL
 */
protected String optimizeCountSql(String originalSql) {
    // 如果 SQL 中已经有 group by，保留 group by 不走简单 COUNT
    // 否则直接封装为 SELECT COUNT(1) FROM (originalSql) TOTAL
    if (hasGroupBy(originalSql)) {
        return originalSql; // 保留原 SQL 做 COUNT
    }
    return String.format("SELECT COUNT(1) FROM (%s) TOTAL", originalSql);
}
```

### 3.3 分页插件性能优化建议

| 优化点 | 说明 | 示例 |
|--------|------|------|
| 合理设置 maxLimit | 防止恶意请求一次查询海量数据 | `setMaxLimit(500)` |
| 大表使用覆盖索引 | COUNT 查询走索引避免全表扫描 | `WHERE status=1 AND idx_create_time` |
| 分页超过 1000 页用游标 | 深分页问题：OFFSET 越大越慢 | 改用 `WHERE id > ? LIMIT ?` |
| 避免 count(distinct) | 使用 count(1) 替代 | MyBatis-Plus 默认优化 |
| 关闭自动 COUNT | 如果能从业务上估算总数 | `page.setSearchCount(false)` |

---

## 四、实战：深分页问题与解决方案

### 4.1 问题复现

```sql
-- MyBatis-Plus 生成的深分页 SQL
SELECT * FROM `order` ORDER BY id LIMIT 100000, 20;
-- ↑ 即使有索引，也需要扫描 100020 行，巨慢！
```

### 4.2 解决方案一：游标分页（推荐）

```java
/**
 * 基于 ID 的游标分页
 */
@Mapper
public interface OrderMapper extends BaseMapper<Order> {
    // 游标分页查询
    @Select("SELECT * FROM `order` " +
            "WHERE id > #{lastId} " +
            "ORDER BY id ASC LIMIT #{limit}")
    List<Order> selectByCursor(@Param("lastId") Long lastId, @Param("limit") Integer limit);
}

// Service 中使用
public void cursorPaging() {
    Long lastId = 0L;
    int batchSize = 100;
    boolean hasMore = true;

    while (hasMore) {
        List<Order> batch = orderMapper.selectByCursor(lastId, batchSize);
        if (batch.isEmpty()) {
            hasMore = false;
        } else {
            processOrders(batch);
            lastId = batch.get(batch.size() - 1).getId();
        }
    }
}
```

### 4.3 解决方案二：子查询分页

```sql
-- 传统分页（慢）
SELECT * FROM `order` ORDER BY create_time DESC LIMIT 100000, 20;

-- 子查询优化（快 10 倍以上）
SELECT o.* FROM `order` o
INNER JOIN (
    SELECT id FROM `order`
    ORDER BY create_time DESC
    LIMIT 100000, 20
) tmp ON o.id = tmp.id
ORDER BY o.create_time DESC;
```

```java
// Mapper XML 实现
@Select("SELECT o.* FROM `order` o " +
        "INNER JOIN (SELECT id FROM `order` ORDER BY create_time DESC LIMIT #{offset}, #{size}) tmp " +
        "ON o.id = tmp.id ORDER BY o.create_time DESC")
List<Order> selectBySubQuery(@Param("offset") long offset, @Param("size") long size);
```

### 4.4 三种分页方式对比

| 分页方式 | 第1页 | 第100页 | 第10000页 | 适用场景 |
|----------|-------|---------|-----------|---------|
| 传统 OFFSET | 0.2ms | 5ms | 300ms+ | 小数据量管理后台 |
| 游标分页 | 0.2ms | 0.2ms | 0.2ms | 无限滚动、数据导出 |
| 子查询分页 | 0.3ms | 3ms | 20ms | 大数据量分页列表 |

---

## 五、MyBatis-Plus 实用功能集锦

### 5.1 批量操作

```java
// ====== 批量插入（JDBC 批量） ======
List<User> list = new ArrayList<>();
for (int i = 0; i < 10000; i++) {
    list.add(new User().setName("user" + i));
}
userService.saveBatch(list, 500);  // 每批 500 条

// ====== 批量更新 ======
userService.updateBatchById(list, 500);

// ====== 批量删除 ======
userService.removeByIds(Arrays.asList(1L, 2L, 3L));
```

### 5.2 条件构造器高级用法

```java
// ====== AND + OR 组合 ======
LambdaQueryWrapper<User> wrapper = Wrappers.lambdaQuery(User.class)
    .eq(User::getStatus, 1)
    .and(w -> w.like(User::getName, "张")
               .or()
               .like(User::getName, "李"));

// SQL: WHERE status = 1 AND (name LIKE '%张%' OR name LIKE '%李%')

// ====== 嵌套子查询 ======
wrapper.inSql(User::getId, "SELECT user_id FROM `order` WHERE amount > 1000");

// ====== 动态条件 ======
wrapper.eq(StringUtils.hasText(name), User::getName, name)  // name 为空时忽略

// ====== 排他锁 ======
wrapper.last("FOR UPDATE");
User user = userMapper.selectOne(wrapper);  // 带行锁查询
```

### 5.3 雪花算法 ID 配置

```java
// Entity 中配置 ID 生成策略
@Data
@TableName("user")
public class User {
    @TableId(type = IdType.ASSIGN_ID)  // 雪花算法
    private Long id;

    // 或者自增
    // @TableId(type = IdType.AUTO)
    // private Long id;
}
```

---

## 六、常见面试题

### Q1：MyBatis-Plus 和 MyBatis 是什么关系？
MyBatis-Plus 是 MyBatis 的增强工具，在 MyBatis 基础上只做增强不做改变，**不会影响原生的 MyBatis 功能**。它提供了通用的 Mapper CRUD 操作、分页插件、条件构造器等。

### Q2：分页插件的原理是什么？
通过 MyBatis 的拦截器机制，拦截 `Executor.query()` 方法。在执行 SQL 前，先解析 `IPage` 参数，改写为 COUNT SQL 和分页 SQL，然后执行两条 SQL，最后将结果组装到 Page 对象中。

### Q3：分页插件支持哪些数据库？
支持 MySQL、PostgreSQL、Oracle、SQL Server、达梦、人大金仓等 20+ 种数据库。通过配置 `DbType` 自动适配不同的分页方言。

### Q4：代码生成器如何支持多表关联？
代码生成器基于单表结构生成代码，多表关联需要在生成的 Mapper 中手动编写关联查询。可以通过自定义模板生成额外的 `*VO.java` 和 `*Mapper.xml`。

---

## 总结

MyBatis-Plus 的**代码生成器**和**分页插件**，是 Java 后端开发中**投入产出比最高**的两个工具。掌握它们后：

- **代码生成器**：将 CRUD 代码编写时间从 30 分钟缩短到 3 秒
- **分页插件**：一行代码搞定分页，同时通过合理的配置避免性能陷阱

建议每个团队都建立自己的**自定义模板体系**，统一代码规范和输出质量。配合合理的数据层设计，MyBatis-Plus 可以成为你手中最趁手的开发利器。
