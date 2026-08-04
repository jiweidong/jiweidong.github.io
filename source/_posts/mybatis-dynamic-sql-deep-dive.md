---
title: MyBatis 动态 SQL 深度解析：从 XML 标签到 SQL 拼接原理与最佳实践
date: 2026-08-04 09:30:00
tags:
  - Java
  - MyBatis
  - 数据库
categories:
  - Java
  - 数据库
author: 东哥
---

# MyBatis 动态 SQL 深度解析：从 XML 标签到 SQL 拼接原理与最佳实践

## 面试官：MyBatis 的动态 SQL 你熟吗？说说有哪些标签，它们的原理是什么？

**候选人：** 动态 SQL 是 MyBatis 最强大的特性之一，核心标签有 `if`、`choose/when/otherwise`、`trim/where/set`、`foreach`、`bind` 等。它的原理是：**解析 XML 时把动态标签编译成 SQL 节点树，执行时根据参数动态拼接 SQL**，本质是一个基于 OGNL 表达式求值的模板引擎。

**面试官：** 那你说说 `#{}` 和 `${}` 的区别，为什么 `foreach` 拼接 IN 查询推荐用 `#{}`？

## 一、动态 SQL 标签全景图

### 1.1 标签总览

| 标签 | 作用 | 典型场景 |
|------|------|---------|
| `<if>` | 条件判断，满足才拼接 | 多条件组合查询 |
| `<choose>/<when>/<otherwise>` | switch-case 分支 | 多选一逻辑 |
| `<where>` | 自动处理 WHERE 关键字和开头 AND/OR | 多条件查询 |
| `<set>` | 自动处理 SET 关键字和末尾逗号 | 动态更新 |
| `<trim>` | 通用修剪（prefix/suffix/覆盖） | 自定义 where/set 行为 |
| `<foreach>` | 集合遍历 | IN 查询、批量插入 |
| `<bind>` | 变量绑定（如模糊查询拼接 %） | 跨数据库兼容 |
| `<sql>/<include>` | SQL 片段复用 | 公共查询列 |

### 1.2 每个标签的实战示例

**if + where：多条件组合查询**

```xml
<select id="searchUsers" resultType="User">
    SELECT * FROM user
    <where>
        <if test="name != null and name != ''">
            AND name LIKE CONCAT('%', #{name}, '%')
        </if>
        <if test="age != null">
            AND age &gt;= #{age}
        </if>
        <if test="status != null">
            AND status = #{status}
        </if>
    </where>
    ORDER BY id DESC
</select>
```

`<where>` 的妙处：如果所有条件都不满足，它**不会生成 WHERE**；如果第一个条件以 AND/OR 开头，它会**自动去掉开头的 AND/OR**。

**set：动态更新**

```xml
<update id="updateUser" parameterType="User">
    UPDATE user
    <set>
        <if test="name != null">name = #{name},</if>
        <if test="age != null">age = #{age},</if>
        <if test="email != null">email = #{email},</if>
    </set>
    WHERE id = #{id}
</update>
```

`<set>` 自动去掉**末尾多余的逗号**，避免 `UPDATE user SET name = 'x', WHERE id = 1` 这种语法错误。

**choose：多选一**

```xml
<select id="queryByCondition" resultType="Order">
    SELECT * FROM `order`
    <where>
        <choose>
            <when test="orderNo != null and orderNo != ''">
                AND order_no = #{orderNo}
            </when>
            <when test="userId != null">
                AND user_id = #{userId}
            </when>
            <otherwise>
                AND status = 0
            </otherwise>
        </choose>
    </where>
</select>
```

**foreach：IN 查询**

```xml
<select id="selectByIds" resultType="User">
    SELECT * FROM user
    WHERE id IN
    <foreach collection="ids" item="id" open="(" separator="," close=")">
        #{id}
    </foreach>
</select>
```

**foreach：批量插入**

```xml
<insert id="batchInsert">
    INSERT INTO user (name, age) VALUES
    <foreach collection="list" item="u" separator=",">
        (#{u.name}, #{u.age})
    </foreach>
</insert>
```

**bind：模糊查询（跨库兼容）**

```xml
<select id="searchByName" resultType="User">
    <bind name="pattern" value="'%' + name + '%'" />
    SELECT * FROM user WHERE name LIKE #{pattern}
</select>
```

用 `bind` 拼接 `%`，在 MySQL 和 Oracle 上都能工作（如果直接在 SQL 里写 `'%' || name || '%'`，Oracle 用 `||`、MySQL 用 `CONCAT`，不兼容）。

## 二、动态 SQL 的底层原理

### 2.1 SQL 节点树（SQL Node Tree）

MyBatis 解析 Mapper XML 时，会把每个 SQL 解析成一棵**节点树**，节点类型包括：

```
DynamicSqlSource（动态 SQL 源）
 ├── TextSqlNode           ← 静态文本
 ├── IfSqlNode             ← <if>
 ├── WhereSqlNode          ← <where>
 ├── SetSqlNode            ← <set>
 ├── TrimSqlNode           ← <trim>
 ├── ForEachSqlNode        ← <foreach>
 ├── ChooseSqlNode         ← <choose>
 ├── BindSqlNode           ← <bind>
 └── MixedSqlNode          ← 混合节点（子节点集合）
```

### 2.2 执行流程：从 SQL 模板到可执行 SQL

```
Mapper 接口方法调用
    │
    ▼
MapperProxy → MapperMethod
    │
    ▼
SqlSession.selectList()
    │
    ▼
SqlSource.getBoundSql(parameterObject)   ← 关键步骤！
    │   DynamicSqlSource 遍历 SQL 节点树，
    │   对每个动态节点用 OGNL 求值参数对象，
    │   决定拼接/跳过，最终生成完整 SQL 字符串
    ▼
BoundSql（包含：最终 SQL + 参数映射 #{} 占位符列表）
    │
    ▼
JDBC PreparedStatement 预编译执行
```

**核心代码**（`DynamicSqlSource.getBoundSql`，简化）：

```java
public BoundSql getBoundSql(Object parameterObject) {
    DynamicContext context = new DynamicContext(configuration, parameterObject);
    // 递归遍历 SQL 节点树，动态拼接 SQL
    rootSqlNode.apply(context);
    // 解析 #{} 占位符，生成参数映射
    SqlSourceBuilder sqlSourceParser = new SqlSourceBuilder(configuration);
    SqlSource sqlSource = sqlSourceParser.parse(context.getSql());
    return sqlSource.getBoundSql(parameterObject);
}
```

`IfSqlNode.apply()` 的逻辑：

```java
public boolean apply(DynamicContext context) {
    // 用 OGNL 对 test 表达式求值
    if (evaluator.evaluateBoolean(test, context.getBindings())) {
        contents.apply(context);   // 条件为 true，拼接子节点内容
        return true;
    }
    return false;                  // 条件为 false，跳过
}
```

**关键点**：MyBatis 的"动态"发生在**参数对象传入之后、JDBC 执行之前**，每次调用都会重新拼接 SQL——所以动态 SQL 无法利用数据库的 Statement 缓存（但 `#{}` 参数可以复用 PreparedStatement 缓存，前提是 SQL 结构不变）。

### 2.3 OGNL 表达式求值

动态 SQL 的 `test` 属性是 **OGNL 表达式**。MyBatis 用 `ognl.Ognl` 对参数对象求值。常用表达式：

```xml
<if test="name != null and name != ''">        <!-- 字符串非空 -->
<if test="age >= 18">                          <!-- 数值比较 -->
<if test="list != null and list.size() > 0">   <!-- 集合判空 -->
<if test="user != null and user.name == 'admin'"> <!-- 嵌套属性 -->
```

注意：OGNL 中 `==` 比较 String 时，如果两边都是字符串字面量或能自动转换，通常按值比较（MyBatis 做了特殊处理）；但保险起见字符串比较推荐用 `'x'.equals(name)` 或者直接判空。

## 三、#{} vs ${}：动态 SQL 的灵魂问题

### 3.1 区别

| 维度 | `#{}` | `${}` |
|------|-------|-------|
| 处理方式 | **预编译占位符**，生成 `?` | **字符串直接拼接** |
| 安全性 | ✅ 防 SQL 注入 | ❌ 存在注入风险 |
| 性能 | 相同 SQL 可复用 PreparedStatement | 每次生成新 SQL，无法复用 |
| 适用场景 | 值传递（99% 场景） | 表名、列名、排序字段等结构 |
| 示例 | `WHERE id = #{id}` → `WHERE id = ?` | `ORDER BY ${orderCol}` |

### 3.2 ${} 的正确使用姿势（必须白名单校验）

```xml
<!-- 危险：ORDER BY ${orderCol} 用户可传入任意内容 -->
<!-- 安全做法：代码层白名单校验 -->
```

```java
private static final Set<String> ALLOWED_COLUMNS = Set.of("id", "create_time", "price");

public Page<User> query(PageQuery q) {
    // 白名单校验，非法值走默认排序
    String orderCol = ALLOWED_COLUMNS.contains(q.getOrderCol()) ? q.getOrderCol() : "id";
    String orderDir = "asc".equalsIgnoreCase(q.getOrderDir()) ? "ASC" : "DESC";
    return userMapper.query(q, orderCol, orderDir);
}
```

```xml
<select id="query" resultType="User">
    SELECT * FROM user
    ORDER BY ${orderCol} ${orderDir}   <!-- 已经过白名单，安全 -->
</select>
```

### 3.3 为什么 foreach 用 #{} 没毛病？

`foreach` 生成的是**多个占位符**，不是拼接值：

```xml
<foreach collection="ids" item="id" open="(" separator="," close=")">
    #{id}
</foreach>
<!-- 实际生成：WHERE id IN (?, ?, ?, ?) -->
```

每个 `#{id}` 都是预编译参数，**安全且高效**。真正危险的是 `IN (${ids})` 这种直接把字符串拼进去的写法。

## 四、动态 SQL 性能与工程最佳实践

### 4.1 动态 SQL 的性能真相

**误区**："动态 SQL 慢，因为每次重新拼接。"

**真相**：
- 动态 SQL 的拼接发生在**应用内存**里，毫秒级以下，通常不是瓶颈
- 真正的性能影响是：**动态 SQL 结构变化会导致 PreparedStatement 无法复用**，数据库每次要重新解析执行计划
- 对于超高 QPS 的查询，如果 SQL 结构固定（只是参数不同），应避免过度使用 `<if>` 导致 SQL 结构漂移

**优化建议**：
- **查询列固定**：`SELECT` 列不要动态拼，保持稳定
- **条件尽量后置**：动态条件放在 WHERE 尾部，让核心 SQL 结构稳定（MySQL 对 `?` 参数的执行计划缓存生效前提是 SQL 文本一致）
- 条件变化极多时，考虑 **CQRS 拆分**：为不同查询场景写固定 SQL，而不是一个万能动态 SQL

### 4.2 常见坑

**坑 1：where 里只写 if，忘记处理 AND**

```xml
<!-- 错误：第一个条件前面会多出 AND -->
<select id="bad" resultType="User">
    SELECT * FROM user
    WHERE
    <if test="name != null">AND name = #{name}</if>
</select>
<!-- 当 name == null 时生成：SELECT * FROM user WHERE   → 语法错误！ -->
```

解决：用 `<where>` 包裹，或 `WHERE 1=1`（不推荐，破坏索引选择），或 trim 掉开头 AND。

**坑 2：动态 SQL 中的 `>` `<` 需要转义**

XML 中 `>` 和 `<` 是特殊字符：

```xml
<!-- 错误 -->
<if test="age > 18">
<!-- 正确：转义 -->
<if test="age &gt; 18">
<!-- 或使用 CDATA -->
<if test="age > 18"><![CDATA[ AND age > 18 ]]></if>
```

**坑 3：foreach collection 参数名写错**

`collection` 的值取决于参数类型：
- 单 List 参数（无 @Param）：`collection="list"`
- 单数组参数（无 @Param）：`collection="array"`
- 有 @Param 注解：`collection="参数名"`
- Map 参数：`collection="key名"`

```java
List<User> selectByIds(@Param("ids") List<Long> ids);
```

```xml
<!-- 必须写 @Param 的名字 ids，写 list 会报错 -->
<foreach collection="ids" ...>
```

**坑 4：批量插入超长**

MySQL 的 max_allowed_packet（默认 4MB~64MB）限制单条 SQL 大小。批量插入 10 万条会超限，需要**分批插入**（如每批 1000 条）。这也是 `foreach` 批量插入的常见线上事故。

**坑 5：`<set>` 中全为 null 时**

所有 if 都不满足时，`<set>` 不生成 SET，SQL 变成 `UPDATE user WHERE id = ?`——语法错误。业务上应先判断是否有可更新字段。

### 4.3 动态 SQL 的测试策略

- **单元测试必写**：用 H2 内存库 + `@MybatisTest` 验证动态 SQL 拼接结果
- **打印最终 SQL**：`mybatis.configuration.log-impl=org.apache.ibatis.logging.stdout.StdOutImpl` 调试
- **注意空格**：`<if>` 标签之间要注意换行和空格，避免拼接出 `name=#{name}AND` 这类粘连（标签间加换行即可）

## 五、面试官追问环节

### Q1：动态 SQL 是在什么时候解析成 SQL 的？

每次执行 SQL 时，`DynamicSqlSource.getBoundSql()` 都会根据当前参数对象**重新遍历节点树拼接**。但 Mapper XML 的**解析只做一次**（应用启动时），解析结果是节点树，不是最终 SQL。

### Q2：一级缓存和二级缓存对动态 SQL 有效吗？

有效，但要区分：
- **一级缓存**（SqlSession 级别）：缓存的是查询结果，key 包含完整 SQL（动态拼接后的），结构相同的动态 SQL 可命中
- **二级缓存**（namespace 级别）：同样缓存结果，但动态 SQL 拼接结果不同则 key 不同
- 注意：**缓存的是结果不是 SQL**，PreparedStatement 层面的复用才是性能关键

### Q3：MyBatis-Plus 的 LambdaQueryWrapper 和动态 SQL 什么关系？

MyBatis-Plus 的 `QueryWrapper/LambdaWrapper` 是在**应用层用 Java 代码构建动态条件**，最终也是生成动态 SQL 交给 MyBatis 执行。本质是"用 Java DSL 替代 XML 标签"，底层还是同一个 SqlSource 机制。注意 Lambda 写法是**编译期类型安全**，推荐优先使用。

### Q4：动态 SQL 能防止 SQL 注入吗？

`#{}` 能防注入（预编译），`${}` 不能。**动态 SQL 标签本身不提供注入防护**，安全取决于你用哪种占位符。凡是用户输入的值一律 `#{}`，凡是结构（表名/列名/排序）必须 `${}` 时务必白名单校验。

### Q5：一个 Mapper 方法可以同时有静态和动态 SQL 吗？

可以。一个 XML 里 `<select>` 内部既有静态文本也有动态标签，MyBatis 会生成 `MixedSqlNode` 混合节点树统一处理。如果 SQL 完全没有动态标签，MyBatis 会使用 `RawSqlSource`（只解析一次，性能更好）。

## 六、总结

动态 SQL 的核心知识框架：

1. **标签体系**：if / choose / where / set / trim / foreach / bind / sql，各司其职
2. **原理**：XML → SQL 节点树 → 执行时 OGNL 求值拼接 → BoundSql → PreparedStatement
3. **安全**：`#{}` 预编译防注入，`${}` 拼接必须白名单
4. **性能**：SQL 结构稳定才能复用 PreparedStatement；批量操作注意分批
5. **避坑**：AND 前缀、XML 转义、foreach collection 命名、超长 SQL

动态 SQL 是把"数据库访问的灵活性"交给开发者的设计——理解它的原理，你才能在面试和工程中真正用好它。
