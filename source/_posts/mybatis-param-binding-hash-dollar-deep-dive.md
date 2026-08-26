---
title: 【面试必备】MyBatis #{} 与 ${} 深度解析：参数绑定机制、SQL 注入防御与源码级原理
date: 2026-08-26 08:00:00
tags:
  - Java
  - MyBatis
  - 面试
  - 源码
categories:
  - Java
  - 数据库
  - 后端面试
author: 东哥
---

# 【面试必备】MyBatis #{} 与 ${} 深度解析：参数绑定机制、SQL 注入防御与源码级原理

## 面试官：MyBatis 中 #{} 和 ${} 有什么区别？为什么 #{} 能防 SQL 注入？

这是 MyBatis 面试中出场率最高的基础题，但绝大多数回答只停留在「#{} 是预编译占位符，${} 是字符串拼接」这一层。真正的加分项在于：**说清楚两者的本质差异、底层执行链路，以及为什么预编译能防注入**。本文从用法到源码，一次讲透。

## 一、先用一段代码引出问题

```xml
<!-- 方式一：使用 #{} -->
<select id="getUserById" resultType="User">
    SELECT * FROM user WHERE id = #{id}
</select>

<!-- 方式二：使用 ${} -->
<select id="getUserByName" resultType="User">
    SELECT * FROM user WHERE name = '${name}'
</select>
```

两者都能把外部参数拼进 SQL，但执行效果天差地别：

| 对比维度 | #{} | ${} |
|---------|-----|-----|
| 底层机制 | PreparedStatement 预编译占位符（?） | 字符串直接拼接 |
| SQL 注入风险 | 无（参数值不参与 SQL 解析） | 有（拼接后整体参与解析） |
| 参数类型 | 任意类型，自动处理类型转换 | 基本是字符串，需手动处理引号 |
| 使用场景 | 值传递：查询条件、插入值、更新值 | 结构传递：表名、列名、ORDER BY 字段、LIKE 模糊匹配 |
| 性能 | 相同 SQL 可复用预编译缓存 | 每次拼接新 SQL，无法复用 |
| 空值处理 | 可以（jdbcType 配合） | 不行，null 会拼成 "null" 字符串 |

**一句话总结：`#{}` 是把参数当成「值」预编译进 SQL，`${}` 是把参数当成「SQL 片段」直接替换。** 这就是防注入的根源。

## 二、为什么 #{} 能防 SQL 注入？——预编译的本质

### 2.1 SQL 执行的两个阶段

数据库执行一条 SQL 要经过：**词法/语法解析 → 优化 → 生成执行计划 → 执行**。SQL 注入的本质是：**用户输入混入了「解析阶段」**，让输入的一部分被当作 SQL 语法执行。

```sql
-- 假设 SQL 是拼接出来的
SELECT * FROM user WHERE name = '${name}'
-- 用户输入: ' OR '1'='1
-- 拼接结果:
SELECT * FROM user WHERE name = '' OR '1'='1'
-- 整个表都被查出来了！

-- 使用预编译占位符
SELECT * FROM user WHERE name = ?
-- 用户输入 ' OR '1'='1 只会被当作一个字符串"值"
-- 数据库解析时 ? 处就是"一个值"，输入再长也只是这个值的字面量
```

### 2.2 MySQL 服务端的预编译

MySQL 从 4.1 开始支持服务端预编译（Prepared Statement）。客户端把「带 ? 的 SQL 模板」和「参数」分两次发给服务端：

1. 第一次：`PREPARE stmt FROM 'SELECT * FROM user WHERE id = ?'`——**模板在此刻完成解析**，`?` 被标记为参数占位符；
2. 第二次：`EXECUTE stmt USING @id`——只传值，**值不参与解析**，服务端把它当作二进制数据绑定到执行计划上。

也就是说，无论参数里写了什么 `' OR 1=1`、`; DROP TABLE`，在服务端看来它都只是「一个字符串的值」，永远没有机会成为 SQL 语法。**预编译 = 参数与 SQL 语法彻底隔离**，这就是防注入的根本原理，跟参数内容无关。

## 三、从源码看 #{} 和 ${} 的完整执行链路

MyBatis 处理一条 SQL 要经过：**XML 解析 → SqlSource 构建 → SQL 模板预编译（BoundSql）→ PreparedStatement 设置参数**。`#{}` 和 `${}` 的分叉点就在第二步。

### 3.1 XML 解析阶段：TokenHandler 分流

MyBatis 解析 Mapper XML 时，用 `XMLScriptBuilder` 处理动态 SQL，核心是 `TextSqlNode`——它用 `GenericTokenParser` 解析文本中的 `${}`：

```java
// TextSqlNode.java（关键逻辑）
public boolean apply(DynamicContext context) {
    GenericTokenParser parser = createParser(new BindingTokenParser(context, injectionFilter));
    context.appendSql(parser.parse(context.getSql()));
    return true;
}
```

而 `#{}` 则由 `XMLScriptBuilder` 在解析节点时直接转为 `StaticTextSqlNode` 中的占位符 `?`，同时生成 `ParameterMapping` 列表（参数名、jdbcType、typeHandler 等元数据）。

**关键差异**：`${}` 走 `BindingTokenParser`，在 **XML 解析阶段就把参数值直接拼进 SQL 文本**；`#{}` 则保留为 `?`，参数信息记入 `ParameterMapping`，等到设置参数阶段才绑定。

### 3.2 执行阶段：${} 早已定型，#{} 才刚上场

```java
// SqlSourceBuilder.java —— 把 #{} 替换成 ?，同时收集 ParameterMapping
private ParameterMappingTokenHandler handler = new ParameterMappingTokenHandler();
public SqlSource parse(String originalSql, Class<?> parameterType, Map<String, Object> additionalParameters) {
    ParameterMappingTokenHandler handler = new ParameterMappingTokenHandler(configuration, parameterType, additionalParameters);
    GenericTokenParser parser = new GenericTokenParser("#{", "}", handler);
    String sql = parser.parse(originalSql);   // #{} → ?
    return new StaticSqlSource(configuration, sql, handler.getParameterMappings());
}
```

执行时 `DefaultSqlSession` → `SimpleExecutor` → `prepareStatement()`：

```java
// SimpleExecutor.java
private Statement prepareStatement(StatementHandler handler, Log statementLog) throws SQLException {
    Statement stmt;
    Connection connection = getConnection(statementLog);
    stmt = handler.prepare(connection, transaction.getTimeout());  // 创建 PreparedStatement
    handler.parameterize(stmt);   // 设置参数 —— 重点在这里
    return stmt;
}
```

`parameterize()` 最终走到 `DefaultParameterHandler.setParameters()`：

```java
// DefaultParameterHandler.java
public void setParameters(PreparedStatement ps) {
    // 遍历每个 ParameterMapping，从参数对象中取出值
    for (int i = 0; i < parameterMappings.size(); i++) {
        Object value = ...; // 反射/ognl 取参数值
        TypeHandler typeHandler = parameterMapping.getTypeHandler();
        // 用 TypeHandler 把 Java 对象转成 JDBC 类型
        typeHandler.setParameter(ps, i + 1, value, jdbcType);
    }
}
// 最终 ps.setString(i, value) / ps.setInt(i, value) ...
```

**到这里就看得很清楚了**：

- **`#{}`**：MyBatis 用 `PreparedStatement.setXxx()` 绑定参数 → 数据库执行的是「模板 + 参数」，注入无效；
- **`${}`**：值在 `TextSqlNode` 阶段已经以字符串形式混进 SQL 文本 → 最终 `Connection.prepareStatement(拼接后的SQL)`，**拼接发生在预编译之前**，输入即语法。

### 3.3 一个常见的误解澄清

> 「#{} 会预编译，所以性能更好」

不完全对。MySQL 默认 `useServerPrepStmts=false` 时，客户端 JDBC 驱动只是「模拟预编译」，SQL 仍然每次发给服务端解析；真正启用服务端预编译需要 JDBC URL 加 `useServerPrepStmts=true&cachePrepStmts=true`。不过 `#{}` 的语义安全性（防注入）与参数隔离，在任何模式下都是成立的。

## 四、${} 的正确打开方式——什么时候必须用它

`${}` 的本职是「**SQL 结构动态化**」：当参数要充当表名、列名、排序字段等语法成分时，`#{}` 无能为力，因为占位符只能代表「值」。

### 4.1 动态表名 / 分表场景

```xml
<!-- 按月分表：user_202608 -->
<select id="getUserByMonth" resultType="User">
    SELECT * FROM ${tableName} WHERE id = #{id}
</select>
```

### 4.2 动态排序字段

```xml
<select id="listUsers" resultType="User">
    SELECT * FROM user
    ORDER BY ${orderByColumn} ${orderByType}
</select>
```

### 4.3 LIKE 模糊查询（推荐 ${} 拼通配符）

```xml
<!-- 错误示范：like 后面是值，用 #{} 但通配符写法别扭 -->
SELECT * FROM user WHERE name LIKE CONCAT('%', #{name}, '%')

<!-- 常见写法：通配符拼接进 ${}，用户输入仍走 #{} -->
SELECT * FROM user WHERE name LIKE '%${keyword}%'
```

⚠️ **使用 ${} 的三条铁律**：

1. **值必须来自可信来源**：表名、列名、排序字段必须由代码硬编码/白名单校验，绝不能直接接受前端裸传；
2. **白名单校验是底线**：

```java
// 排序字段白名单
private static final Set<String> ORDER_COLUMNS = Set.of("create_time", "id", "update_time");
private static final Set<String> ORDER_TYPES = Set.of("ASC", "DESC");

public String safeOrderBy(String column, String type) {
    if (!ORDER_COLUMNS.contains(column) || !ORDER_TYPES.contains(type.toUpperCase())) {
        throw new IllegalArgumentException("非法排序参数");
    }
    return column + " " + type;
}
```

3. **能不用就不用**：能用 `#{}` 表达的需求，一律 `#{}`。

## 五、实战避坑：5 个高频翻车现场

### 5.1 坑一：${} 传 null

```java
// ${} 拼接 null → SQL 变成 name = null
// #{} 传 null 虽然也不等于 NULL（要用 IS NULL），但至少不会拼出语法错误
```

### 5.2 坑二：数字参数也能注入

```java
// 你以为 ${id} 传数字就安全？用户传 "1 OR 1=1" 一样中招
// 注入不看类型，只看是否参与解析
```

### 5.3 坑三：ORDER BY 里用了 #{}（必错）

```sql
-- #{} 生成: ORDER BY ?  →  MySQL 语法错误
-- 排序字段是结构不是值，必须 ${}
```

### 5.4 坑四：IN 条件用 ${} 裸拼

```xml
<!-- 危险 -->
WHERE id IN (${ids})   <!-- 传入 "1,2,3); DROP TABLE user;--" -->

<!-- 安全：MyBatis 的 foreach -->
<select id="getByIds" resultType="User">
    SELECT * FROM user WHERE id IN
    <foreach collection="ids" item="id" open="(" separator="," close=")">
        #{id}
    </foreach>
</select>
```

### 5.5 坑五：忽略 MyBatis 3.5.x 的 ${} 注入过滤器

MyBatis 3.5.9+ 为 `${}` 引入了可选的正则注入过滤器（`scripting.defaults.injectionFilter` 配置项，默认关闭）。注意它**不是默认开启的**，不要以为升级版本就万事大吉，白名单校验仍是第一道防线。

## 六、面试官追问环节

**Q1：预编译防注入的原理是什么？**
数据库执行 SQL 分「解析」与「执行」两步。`PreparedStatement` 先让服务端解析「带 ? 的模板」，参数在解析之后以值的形式绑定，不参与语法解析，因此无论参数内容是什么都不会改变 SQL 语义。

**Q2：JDBC 层怎么用预编译？**

```java
String sql = "SELECT * FROM user WHERE name = ?";
try (PreparedStatement ps = conn.prepareStatement(sql)) {
    ps.setString(1, name);   // 值绑定
    try (ResultSet rs = ps.executeQuery()) { ... }
}
```

**Q3：${} 完全不能用吗？**
能用，但只用于「结构」而非「值」，且必须白名单校验。动态表名、排序字段、`LIKE` 通配符是典型合法场景。

**Q4：动态 SQL 里的 <if> 判断和 #{} ${} 有什么关系？**
`<if>`、`<choose>`、`<foreach>` 属于动态 SQL 标签，在 XMLScriptBuilder 阶段处理，决定 SQL 文本的「形状」；`#{}`/`${}` 决定参数如何进入 SQL。两者是不同维度：标签管结构，占位符管绑定。

**Q5：MyBatis-Plus 的 QueryWrapper 用的是什么？**
MyBatis-Plus 最终也是生成带 `#{}` 占位符的 SQL（Wrapper 的 `condition` 参数生成 SQL 片段，值部分走参数绑定），`last()`、`apply()` 等拼接原始 SQL 的方法则相当于 `${}` 的语义，同样有注入风险，需要谨慎。

## 七、总结

| 要点 | 结论 |
|------|------|
| 本质区别 | `#{}` 预编译占位符，`${}` 字符串拼接 |
| 注入根源 | `${}` 让输入参与 SQL 解析阶段 |
| 防注入原理 | 预编译让参数与语法隔离 |
| 适用场景 | `#{}`：值；`${}`：结构（需白名单） |
| 源码分叉点 | `TextSqlNode`（`${}` 立即拼接）vs `ParameterMappingTokenHandler`（`#{}` 转 `?` + 收集映射） |
| 安全底线 | 外部输入永远只走 `#{}` |

记住这句话：**凡是「值」，用 `#{}`；凡是「结构」，用 `${}` 并白名单校验**。回答到这个深度，这道题就稳了。
