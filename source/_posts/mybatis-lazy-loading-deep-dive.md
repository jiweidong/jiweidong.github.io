---
title: 【MyBatis 源码】MyBatis 延迟加载深度解析：Lazy Loading 原理与源码级分析
date: 2026-08-07 08:00:00
tags:
  - MyBatis
  - 源码
  - 数据库
  - 面试
categories:
  - Java
  - MyBatis
author: 东哥
---

# 【MyBatis 源码】MyBatis 延迟加载深度解析：Lazy Loading 原理与源码级分析

## 面试官：MyBatis 的延迟加载是怎么实现的？和 Hibernate 的延迟加载有什么区别？

很多同学配置过 `<association>`、`<collection>` 的 `fetchType="lazy"`，但一问到"延迟加载底层是什么原理"，就卡住了。这篇文章从源码角度彻底拆解 MyBatis 延迟加载：代理对象怎么生成、SQL 什么时候触发、N+1 问题怎么来的。

## 一、延迟加载解决了什么问题？

### 场景：查询订单要不要顺便查用户？

```java
// 需求：只查订单列表，展示订单号
// 如果每条订单都 JOIN 查用户，纯属浪费
SELECT * FROM orders;            -- 主 SQL
SELECT * FROM users WHERE id=?;  -- 关联 SQL（可能 N 条）
```

**不使用延迟加载**：查询订单时，`<association>` 关联的用户**立即**执行第二条 SQL（或者用 JOIN 一次查出）。

**使用延迟加载**：先只查订单，当代码**真正访问** `order.getUser()` 时才执行用户查询。省掉了不必要的数据库查询。

### 开启方式

```yaml
# application.yml（Spring Boot）
mybatis:
  configuration:
    lazy-loading-enabled: true        # 全局开关，默认 false
    aggressive-lazy-loading: false    # 默认 true，建议关掉
```

或在 XML 中按需指定：

```xml
<resultMap id="orderMap" type="Order">
    <id property="id" column="id"/>
    <association property="user"
                 column="user_id"
                 select="com.example.mapper.UserMapper.selectById"
                 fetchType="lazy"/>   <!-- lazy / eager -->
</resultMap>
```

`fetchType` 优先级**高于**全局配置，可以按字段精细控制。

## 二、核心原理：代理对象 + 拦截触发

延迟加载的实现只有两步：

```
第一步（查询主对象时）：
  1. 正常执行主 SQL，查出 Order 数据
  2. 对于 fetchType=lazy 的属性，不为它填充真实 User
  3. 而是创建一个 User 的【代理对象】塞进 order.user

第二步（访问属性时）：
  1. 调用 order.getUser()
  2. 代理对象拦截到方法调用
  3. 触发关联 SQL 执行，查出真实 User
  4. 替换代理为真实对象，返回
```

### 源码：代理对象怎么来的？

关键类：`org.apache.ibatis.executor.loader.JavassistProxyFactory`（或 `CglibProxyFactory`）。

```java
// JavassistProxyFactory.createProxy()
public Object createProxy(Object target, ResultLoaderMap lazyLoader,
                          Configuration configuration, ObjectFactory objectFactory,
                          List<Class<?>> constructorArgTypes, List<Object> constructorArgs) {
    // 生成一个继承自目标类型的代理类
    final Class<?> clazz = target.getClass();
    // 代理类会有一个 EnhancedResultObjectProxyImpl 的拦截器
    ...
}
```

核心拦截器 `EnhancedResultObjectProxyImpl`：

```java
public Object invoke(ObjectEnhanced enhanced, Method method, Method methodProxy,
                     Object[] args) throws Throwable {
    final String methodName = method.getName();
    // 1. 只拦截 getter 方法（getUser）
    if (lazyLoader.size() > 0 && !FINALIZE_METHOD.equals(methodName)) {
        // 2. 判断是否是延迟加载属性
        if (property == null || LAZY_LOAD_PROPERTY_MAP.containsKey(property)) {
            // 3. 触发加载！
            lazyLoader.loadProperty(property);
        }
    }
    return methodProxy.invoke(enhanced, args);
}
```

### 源码：loadProperty 干了什么？

```java
// ResultLoaderMap.loadProperty()
public boolean loadProperty(final String name) {
    LoadPair pair = loaderMap.get(name);   // 找到该属性对应的 LoadPair
    if (pair == null) return false;
    // 加锁防止并发重复加载
    pair.load();                            // 执行关联 SQL
    loaderMap.remove(name);                 // 加载完移除，避免二次加载
    return true;
}

// LoadPair.load()
private Object load(final Object userObject) throws ... {
    // 本质就是一次新的 SqlSession 查询：
    // 用保存的 MappedStatement + 参数，执行 selectById(user_id)
    ...
}
```

注意：延迟加载的关联 SQL 用的是**当前 SqlSession 还是新会话**？答案是——MyBatis 会优先复用当前 SqlSession（`Executor` 被包装成 `ResultLoader` 保存），如果原会话已关闭（比如在 Service 层查询完就关了 session），会从 `Configuration` 的 `Environment` 重新获取连接。这就有个经典坑：**Spring 事务内没问题；非事务场景 session 关闭后，延迟加载可能报 "Closing was forced" 或拿不到连接**。

## 三、aggressiveLazyLoading 的坑

```yaml
mybatis:
  configuration:
    aggressive-lazy-loading: false  # 强烈建议 false
```

- **默认 true（老版本）**：只要调用主对象**任意一个 getter**（哪怕 `getOrderNo()`），所有延迟加载属性**全部**被触发加载。等于延迟加载形同虚设！
- **设为 false**：只有访问**该属性自己的 getter**（`getUser()`）才触发对应加载。

```java
// aggressiveLazyLoading=false 时
order.getOrderNo();   // 不触发任何延迟加载
order.getUser();      // 只触发 user 的加载

// aggressiveLazyLoading=true 时
order.getOrderNo();   // 💥 user 的 SQL 也执行了！
```

所以新项目务必显式关闭 aggressive，否则性能优化无从谈起。

## 四、延迟加载与 N+1 问题：一对多场景的真相

```xml
<collection property="items" select="...selectItemsByOrderId" fetchType="lazy"/>
```

查 100 个订单，访问每个订单的 `items`：

```
1 条查询订单 SQL
+ 100 条查询 items SQL   = 101 条 SQL  =  N+1 问题 💥
```

**延迟加载本身不解决 N+1，它甚至放大 N+1**（循环里访问关联属性就会触发）。解决 N+1 的正确姿势：

| 方案 | 说明 |
|------|------|
| 嵌套结果映射（JOIN） | `<association>` 直接写 `<result>` 子标签，一次 JOIN 查出，无 N+1 |
| 批量加载 | 循环访问前，先批量查出所有关联数据放入 Map（手写或 MyBatis-Plus 的 `listByIds`） |
| 及时加载 + 缓存 | 访问前先查关联集合，配合一级/二级缓存 |
| 明确不需要关联 | 拆两个 Mapper 方法，按需调用 |

**面试追问：延迟加载和 JOIN（嵌套结果）怎么选？**

- 列表页只显示主表字段 → 不需要关联 → 不配置关联字段
- 详情页需要关联对象 → 数据量小 → JOIN 一次查出（嵌套结果）
- 关联数据大、按需使用 → 延迟加载
- 原则：**能用一次查询解决，绝不用延迟加载**；延迟加载是"兜底方案"不是"首选方案"。

## 五、延迟加载 vs Hibernate 懒加载

| 维度 | MyBatis | Hibernate |
|------|---------|-----------|
| 代理技术 | Javassist / CGLIB 子类代理 | CGLIB 子类代理 |
| 配置粒度 | 每个 association/collection 的 fetchType | 类/属性级 @OneToMany(fetch=FetchType.LAZY) |
| 会话要求 | 关联 SQL 可复用旧会话，否则开新会话 | **必须**在 Session 生命周期内访问，否则 LazyInitializationException |
| 代理失效 | final 类/方法无法代理（同 CGLIB 限制） | 同 |
| 常见坑 | aggressive 默认值、N+1 | LazyInitializationException |

两者的根本区别：MyBatis 的延迟加载是**手写的关联查询再执行**（半自动，SQL 你自己写），Hibernate 是**实体关系自动装配**（全自动）。所以 MyBatis 更可控、更灵活，代价是 SQL 要自己写。

## 六、最佳实践总结

1. **全局配置**：`lazy-loading-enabled: true` + `aggressive-lazy-loading: false`
2. **按需配置**：只在真正需要的关联字段上加 `fetchType="lazy"`
3. **警惕 N+1**：循环访问关联属性前，先批量加载或改用 JOIN
4. **事务内使用**：延迟加载最好在 Spring 事务范围内完成，避免会话关闭问题
5. **DTO 化**：MyBatis 建议返回 DTO/VO，避免把实体和关联关系暴露给前端（防止前端序列化时触发延迟加载，导致 N+1 雪崩）

**经典坑**：返回实体给前端，JSON 序列化 `getUser()` 被调用 → 每条订单触发一条 SQL → 页面慢到爆炸。解决：返回 DTO、或 JSON 序列化前排除懒加载字段（`@JsonIgnore` / 自定义序列化器）。

## 七、面试速答

1. **延迟加载原理？** 查询主对象时为关联属性生成代理对象（Javassist/CGLIB），访问该属性 getter 时拦截触发关联 SQL，加载完替换真实对象。
2. **触发条件？** 访问被标记 lazy 属性的 getter 方法；`aggressiveLazyLoading=true` 时访问任意 getter 都会触发全部。
3. **怎么避免 N+1？** 用 JOIN 嵌套结果、批量查询、或按需拆分查询。
4. **和 Hibernate 懒加载区别？** 都是代理实现，但 MyBatis 是手写 SQL 二次查询、可脱离原会话，Hibernate 是自动装配、必须在 Session 内访问。
5. **代理失效场景？** final 类/方法无法被 CGLIB/Javassist 代理，此时延迟加载不生效。

延迟加载是一把双刃剑：用好了省查询，用不好 N+1 雪崩。理解它的代理原理，你才能游刃有余。
