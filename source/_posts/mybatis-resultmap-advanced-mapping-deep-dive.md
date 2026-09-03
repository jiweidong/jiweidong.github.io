---
title: 【MyBatis 源码】ResultMap 高级映射深度解析：association、collection、懒加载与鉴别器源码级剖析
date: 2026-09-03 08:00:00
tags:
  - MyBatis
  - ORM
  - 源码
  - 实战
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MyBatis 源码】ResultMap 高级映射深度解析：association、collection、懒加载与鉴别器源码级剖析

## 场景：多表联查，对象怎么"拼"出来？

MyBatis 里最常见的写法是"实体字段一一对应"，但业务建模往往是聚合结构：一个订单 `Order` 里有用户信息 `User`（一对一）、有明细列表 `List<OrderItem>`（一对多）。SQL 用 JOIN 一把梭查出扁平的 20 列，怎么映射成嵌套对象？

```xml
<resultMap id="orderDetailMap" type="Order">
    <id property="id" column="id"/>
    <result property="orderNo" column="order_no"/>
    <association property="user" javaType="User">
        <id property="id" column="uid"/>
        <result property="name" column="uname"/>
    </association>
    <collection property="items" ofType="OrderItem">
        <id property="id" column="item_id"/>
        <result property="productName" column="product_name"/>
    </collection>
</resultMap>
```

这段 XML 背后，MyBatis 在查询结果集的每一行上做了大量工作：根据 `column` 找值、判空、构造对象、按 id 去重、决定是 new 还是复用……本文从 `DefaultResultSetHandler` 源码切入，把 ResultMap 高级映射的底层机制讲透。

## 一、ResultMap 体系：先认识四个核心组件

MyBatis 把"一行数据 → 对象图"的映射规则抽象成 ResultMap，内部由四类节点组成：

| 组件 | 作用 | 常用属性 |
|------|------|---------|
| `<id>` | 主键映射，**用于对象去重/缓存标识** | column, property, typeHandler |
| `<result>` | 普通字段映射 | column, property, jdbcType, typeHandler |
| `<association>` | 嵌套的**单个**对象（一对一/多对一） | javaType, select, column, fetchType |
| `<collection>` | 嵌套的**集合**（一对多） | ofType, select, column, fetchType |
| `<discriminator>` | 鉴别器，按某列值**动态选择** resultMap | column, javaType |

每个节点在 XML 解析阶段（`XMLMapperBuilder`/`ResultMapResolver`）被构造成 `ResultMapping` 对象，最终注册成 `ResultMap` 存入 `Configuration.resultMaps`（key 是 namespace + id，如 `com.x.mapper.OrderMapper.orderDetailMap`）。注意：**解析时只记录映射规则，不执行任何映射逻辑**——真正的执行在查询时。

## 二、执行期主流程：DefaultResultSetHandler 如何消费每一行

查询走 `DefaultResultSetHandler.handleResultSets()`，核心步骤：

1. 拿到第一个 ResultSet，找到对应的 ResultMap（多个结果集按 `resultSets` 属性匹配）。
2. 外层循环每一行：`handleRowValues()` → 如果是简单映射走 `handleRowValuesForSimpleResultMap`，有嵌套（association/collection）走 `handleRowValuesForNestedResultMap`。
3. 对每行执行 `applyPropertyMappings`：遍历 ResultMapping 列表，从 ResultSet 按 column 取值（`getPropertyMappingValue`），再用 `MetaObject.setValue` 反射/内省设置到目标对象属性。
4. 返回对象列表。

**嵌套结果映射（Nested ResultMap，JOIN 方式）的关键**：MyBatis 用 **`<id>` 列做"行标识"**，配合 `PartialRowRecord`/`DefaultResultHandler` 的缓存，实现**一行一行地合并对象图**。同一行里，Order 只 new 一次；如果下一行还是同一个订单（JOIN 明细产生多行），则复用之前创建好的 Order，把新的 OrderItem add 进它的 items——**这就是为什么嵌套映射必须声明 `<id>`**：不声明的话 MyBatis 无法判断"这两行是不是同一个主对象"，会出现对象被重复创建、集合被覆盖/重复的 bug。

## 三、association 与 collection 的两种实现策略

### 策略一：嵌套结果映射（Nested Result / JOIN）

```xml
<select id="selectOrderDetail" resultMap="orderDetailMap">
    SELECT o.id, o.order_no,
           u.id AS uid, u.name AS uname,
           i.id AS item_id, i.product_name
    FROM t_order o
    LEFT JOIN t_user u ON o.user_id = u.id
    LEFT JOIN t_order_item i ON o.id = i.order_id
    WHERE o.id = #{id}
</select>
```

- **优点**：一次 SQL 查完，无 N+1；
- **缺点**：JOIN 结果集是笛卡尔积放大（1 订单 × 1 用户 × N 明细 = N 行），明细多时传输量大；跨数据库方言的 SQL 复杂；**字段别名必须唯一且与 column 完全一致**，很容易配错。

### 策略二：嵌套查询（Nested Select / 子查询）

```xml
<association property="user" column="user_id"
             select="com.x.mapper.UserMapper.selectById" fetchType="lazy"/>
<collection property="items" column="id"
             select="com.x.mapper.OrderItemMapper.selectByOrderId" fetchType="lazy"/>
```

- **原理**：MyBatis 拿当前行的 `user_id`/`id` 作为参数，**再次发起查询**填充嵌套对象；
- **优点**：SQL 简单、天然支持**懒加载**；
- **缺点**：默认立即执行就是 **N+1 查询**（每个订单多查 2 次），必须配懒加载或批量嵌套查询（`<collection>` 里用 `column="{id=id}"` + `@Param` 集合批量 in 查询的变体）。

## 四、懒加载源码解析：代理对象是怎么来的

`fetchType="lazy"`（或全局 `lazyLoadingEnabled=true`）时，MyBatis 不会立即执行嵌套查询，而是给该属性塞一个**代理对象**：

1. `DefaultResultSetHandler.createResultObject` 阶段，对标记 lazy 的 ResultMapping 调用 `createLazyProxy()`；
2. `ProxyFactory`（默认 `JavassistProxyFactory`，Spring Boot 集成常用它；也可配 `cglib`）为**目标类型**生成子类代理，拦截所有方法调用；
3. 真正第一次调用 getter 时，代理触发 `ResultLoaderMap.load()` → 打开新 SqlSession → 执行嵌套 select → `MetaObject.setValue` 填充真实值 → 移除该属性的 loader 标记；
4. 后续调用直接返回真实对象，不再触发查询。

几个必须知道的点：

- **懒加载需要 SqlSession 还活着**：代理触发加载时要新开/复用会话，配合 Spring 时若事务已提交、连接已关，会抛 `org.apache.ibatis.executor.ExecutorException: Result object returned by Mapper...` 或 LazyInitializationException。**所以懒加载属性要在事务作用域内访问完**，或 DTO 提前拷贝。
- **构造器参数不能懒加载**：对象通过无参构造 + setter 填充才支持代理；用 `<constructor>` 注入的属性无法 lazy。
- **localCache 的影响**：同一会话内二级缓存未命中时，懒加载查询仍走一级缓存；跨会话会重复查。

## 五、鉴别器 discriminator：一行数据，多种对象

```xml
<resultMap id="msgMap" type="Message">
    <discriminator column="msg_type" javaType="int">
        <case value="1" resultMap="textMsgMap"/>   <!-- 文本消息 -->
        <case value="2" resultMap="imageMsgMap"/>  <!-- 图片消息 -->
    </discriminator>
</resultMap>
```

原理：`handleRowValues` 处理每行前，先读 `discriminator` 指定的 column 值，到 `ResultMap.discriminator` 的映射表里找对应的子 resultMap（找不到就用默认父 map），**整行按子 map 的规则映射**。子 map 会继承父 map 的映射（`extends`），适合"基类 + 多子类"的持久化设计（单表多态）。注意 discriminator 的匹配发生在**对象创建前**，所以它决定的是"造哪种对象"，而不是"给对象贴标签"。

## 六、ResultMap 高级映射的常见坑

| 坑 | 现象 | 解决 |
|----|------|------|
| 嵌套映射没写 `<id>` | 集合元素重复/主对象重复 | 必须为每层主对象声明 `<id>`（可用不可见列或复合 id） |
| column 别名不一致 | 属性为 null | SQL 别名与 resultMap column 严格对齐 |
| 驼峰映射混用 | 部分字段映射不上 | 统一用 `mapUnderscoreToCamelCase` 或显式 resultMap，别两套混着 |
| 懒加载在事务外访问 | LazyInitializationException | 事务内访问完；或 DTO 转换；或关掉懒加载 |
| 嵌套查询 N+1 | 接口响应慢、DB 压力大 | 用 JOIN + 嵌套结果；或 batch select 嵌套查询（MyBatis 3.4+ 支持 `<collection>` 传多个参数做 in 查询） |
| 大结果集 + 嵌套映射 | 内存暴涨 | 嵌套结果映射会把整棵对象树驻留内存做合并；超大导出改用 Cursor + 简单映射或分片 |
| 循环引用（A→B→A） | 栈溢出/死循环 | 避免双向嵌套；用 DTO 扁平化或手动组装 |
| `resultType` 误写成嵌套 | 直接报错或全部 null | 嵌套结构只能用 resultMap |

另外一个性能忠告：**`<collection>` 的嵌套结果映射在结果集很大时会吃掉大量内存**（所有中间对象都要缓存等待合并）。MyBatis 官方也建议：一对多优先考虑**两条 SQL 分别查询 + 应用层分组组装**（比如查订单列表 + `WHERE order_id IN (...)` 查明细，再按 orderId 归组），可读性和性能往往双赢。

## 七、面试追问速答

**Q：为什么嵌套 resultMap 强烈建议声明 `<id>`？**
A：MyBatis 靠 `<id>` 列的哈希值识别"同一行是否属于同一个外层对象"，决定是 new 还是复用并往集合里追加。缺了它，JOIN 出的多行会被当成不同对象，集合里出现重复/错乱。

**Q：association 和 collection 在 ResultMap 解析上有什么区别？**
A：解析结构几乎一样（都是嵌套 ResultMapping 列表），区别在语义：association 映射到单个属性（javaType），collection 映射到集合属性（ofType），执行期前者 `setValue` 单对象、后者先确保集合已初始化再 add。支持 `select` 子查询时两者都要传 `column` 作为参数来源。

**Q：懒加载一定好吗？**
A：不一定。懒加载把 N+1 从"显式"变成"隐式"——你不在事务里访问完，序列化/视图渲染阶段随时触发查询，反而更难排查。小对象图用 JOIN 嵌套结果，大列表用两条 SQL 应用层组装，懒加载只适合"极少访问的补充字段"。

**Q：MyBatis-Plus 里怎么处理一对多？**
A：MyBatis-Plus 的 BaseMapper 只做单表 CRUD，一对多推荐手写 XML resultMap 或分两条 SQL 组装；其 `@TableField(exist=false)` + 手动填充的"伪关联"不推荐用于大批量场景（本质是内存 join）。

## 小结

ResultMap 高级映射的底层，是 `DefaultResultSetHandler` 对"扁平行 → 嵌套对象图"的**按 id 合并算法**，配合 `<association>/<collection>` 的 JOIN 与子查询两种策略、代理机制的懒加载、以及按列值分发对象的鉴别器。掌握三个关键词——**`<id>` 去重、嵌套结果 vs 嵌套查询、fetchType**，无论手写复杂映射还是排查数据错乱，都能直击要害。最后记住工程心法：**能用两条 SQL 组装就别硬 JOIN 嵌套，能用简单映射就别上 resultMap**——少一份魔法，多一分可控。
