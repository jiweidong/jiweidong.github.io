---
title: 【MyBatis 源码】MyBatis 插件机制深度解析：从 Interceptor 动态代理到 PageHelper 分页原理
date: 2026-08-06 08:00:00
tags:
  - Java
  - MyBatis
  - 插件
  - 源码
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【MyBatis 源码】MyBatis 插件机制深度解析：从 Interceptor 动态代理到 PageHelper 分页原理

## 面试官：MyBatis 的插件（Interceptor）是怎么工作的？为什么它能拦截四大对象？

MyBatis 的插件机制是面试中的"源码加分题"。很多人用过 PageHelper 分页、用过 `@Intercepts` 注解写自定义插件，但被问到：

- 插件到底拦截了哪几个对象？什么方法？
- 为什么 `@Signature` 里的 type 只能是 Executor、StatementHandler、ParameterHandler、ResultSetHandler？
- 插件和被代理对象是什么关系？多个插件怎么协作？
- PageHelper 是怎么做到"只改当前 SQL 自动加分页"的？

就答不上来了。本文从 `Interceptor` 接口出发，结合源码把 MyBatis 插件机制完整拆解，最后揭秘 PageHelper 的分页原理。

<!-- more -->

## 一、插件机制的三要素

### 1.1 核心接口

```java
public interface Interceptor {
    // 拦截逻辑：Invocation 封装了被拦截的方法调用
    Object intercept(Invocation invocation) throws Throwable;

    // 生成代理对象（默认实现是 Plugin.wrap）
    default Object plugin(Object target) {
        return Plugin.wrap(target, this);
    }

    // 解析插件配置参数（<plugin> 标签里的 <property>）
    default void setProperties(Properties properties) {}
}
```

### 1.2 声明方式

```java
@Intercepts({
    @Signature(type = Executor.class,
               method = "query",
               args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class})
})
public class MyInterceptor implements Interceptor {
    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        System.out.println("SQL 执行前拦截...");
        Object result = invocation.proceed(); // 放行，继续执行原方法
        System.out.println("SQL 执行后拦截...");
        return result;
    }
}
```

XML 配置：

```xml
<plugins>
    <plugin interceptor="com.example.MyInterceptor">
        <property name="key" value="value"/>
    </plugin>
</plugins>
```

## 二、四大对象与可拦截方法（必背表格）

MyBatis 只允许拦截 **四大核心对象**，每个对象可拦截的方法固定：

| 对象 | 作用 | 可拦截方法 |
|------|------|-----------|
| Executor | 执行器：负责 SQL 执行、缓存维护、事务 | update、query、flushStatements、commit、rollback、getTransaction、close、isClosed |
| StatementHandler | 语句处理器：负责 JDBC Statement 的创建和参数绑定 | prepare、parameterize、batch、update、query |
| ParameterHandler | 参数处理器：负责参数对象到 JDBC 参数的映射 | getParameterObject、setParameters |
| ResultSetHandler | 结果集处理器：负责 ResultSet 到结果对象的映射 | handleResultSets、handleOutputParameters |

为什么只有这四个？看 `Configuration` 的构建过程——这四个对象全部通过 `newXxx()` 工厂方法创建，并在创建时调用 `interceptorChain.pluginAll()`：

```java
public Executor newExecutor(Transaction transaction, ExecutorType executorType) {
    Executor executor = ...; // 创建真实 Executor
    if (cacheEnabled) {
        executor = new CachingExecutor(executor); // 二级缓存包装
    }
    executor = (Executor) interceptorChain.pluginAll(executor); // 插件链包装
    return executor;
}
```

**结论**：MyBatis 的插件本质是对这四个工厂方法产出的对象做 **JDK 动态代理包装**。如果你在 `@Signature` 里写别的 type（比如 `Connection.class`），运行时会直接抛错，因为 Connection 根本不走 `pluginAll`。

## 三、Plugin.wrap：动态代理的核心

```java
public class Plugin implements InvocationHandler {

    private final Object target;          // 被代理的真实对象
    private final Interceptor interceptor;// 拦截器
    private final Map<Class<?>, Set<Method>> signatureMap; // 拦截的方法集合

    public static Object wrap(Object target, Interceptor interceptor) {
        Map<Class<?>, Set<Method>> signatureMap = getSignatureMap(interceptor);
        Class<?> type = target.getClass();
        // 只代理声明过的接口（四大对象接口）
        Class<?>[] interfaces = getAllInterfaces(type, signatureMap);
        if (interfaces.length > 0) {
            return Proxy.newProxyInstance(      // JDK 动态代理
                type.getClassLoader(), interfaces,
                new Plugin(target, interceptor, signatureMap));
        }
        return target; // 没有匹配接口，原样返回
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        // 判断当前方法是否在拦截清单里
        Set<Method> methods = signatureMap.get(method.getDeclaringClass());
        if (methods != null && methods.contains(method)) {
            // 命中：走拦截器逻辑，Invocation 封装了 target/method/args
            return interceptor.intercept(new Invocation(target, method, args));
        }
        return method.invoke(target, args); // 未命中：直接反射调用原方法
    }
}
```

流程一句话：**创建四大对象 -> interceptorChain.pluginAll 逐个 wrap -> 生成 JDK 动态代理 -> 方法调用时按 signatureMap 匹配，命中则进 intercept，否则反射原方法**。

## 四、多插件协作：洋葱模型

多个插件时是**层层嵌套的代理**，执行顺序类似洋葱：

```java
// InterceptorChain.pluginAll
public Object pluginAll(Object target) {
    for (Interceptor interceptor : interceptors) {
        target = interceptor.plugin(target); // 依次包装，后包装的在外层
    }
    return target;
}
```

```
调用链（假设 A 先配置，B 后配置）：
B.proxy -> A.proxy -> 真实对象
B.intercept() -> invocation.proceed() -> A.intercept() -> invocation.proceed() -> 真实方法
```

**注意执行顺序**：XML 里先声明的插件在内层（先被包装），后声明的在外层（先执行 intercept）。`invocation.proceed()` 就是穿透一层代理继续往下走。这个顺序在配置插件时经常踩坑——比如分页插件和其他拦截 SQL 的插件，顺序不同结果不同。

## 五、源码角度：一次带插件的 SQL 执行全流程

以 `selectList` 为例：

```
SqlSession.selectList()
  -> Executor.query()            ← 可能被插件 A 拦截（Executor）
     -> prepareStatement()       <- StatementHandler 在此创建
        -> StatementHandler.prepare()      ← 可能被插件 B 拦截
        -> StatementHandler.parameterize()
           -> ParameterHandler.setParameters() ← 可能被插件 C 拦截
        -> StatementHandler.query()
           -> ResultSetHandler.handleResultSets() ← 可能被插件 D 拦截
```

所以一个插件如果 `@Signature` 同时声明拦截 Executor.query 和 StatementHandler.prepare，它能在**多个环节**被调用。这也是为什么一个 PageHelper 分页插件能同时处理"改写 SQL"（拦截 StatementHandler）和"统计总数"（拦截 Executor.query）。

## 六、PageHelper 分页原理揭秘

PageHelper 是 MyBatis 最著名的插件，它的核心思路：

### 6.1 拦截声明

```java
@Intercepts({
    // 拦截 Executor 的两个 query 方法
    @Signature(type = Executor.class, method = "query",
        args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class}),
    @Signature(type = Executor.class, method = "query",
        args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class,
                CacheKey.class, BoundSql.class}),
})
public class PageInterceptor implements Interceptor { ... }
```

### 6.2 intercept 里的核心流程

```java
public Object intercept(Invocation invocation) throws Throwable {
    // 1. 从参数中取出 Page 对象（ThreadLocal 里的分页参数）
    Page page = getPage(invocation.getArgs());

    if (page != null && page.getPageSize() > 0) {
        // 2. 解析 BoundSql，拿到原始 SQL
        BoundSql boundSql = ...;
        String originalSql = boundSql.getSql();

        // 3. 生成 count SQL（SELECT COUNT(*) FROM (...) t）并先执行
        //    —— 这就是为什么分页会多出一条 count 查询
        executeCount(invocation, ...);

        // 4. 生成分页 SQL：MySQL 就是 append "LIMIT offset, pageSize"
        String pageSql = dialect.getPageSql(originalSql, page);
        // 5. 用反射把分页 SQL 塞回 BoundSql 的 sql 字段
        setSql(boundSql, pageSql);

        // 6. 放行执行真正的分页查询
        Object result = invocation.proceed();

        // 7. 把结果包装成 PageInfo（含 total、pages 等）
        ...
        return result;
    }
    return invocation.proceed();
}
```

**关键技巧**：PageHelper 通过**反射修改 BoundSql 的 sql 字段**来实现 SQL 改写，而不是重新生成 MappedStatement。这也是它要求"分页 SQL 不能写死 `;` 结尾"等限制的原因。

### 6.3 为什么分页必须放在最后一个插件？

因为 PageHelper 需要拿到"最终形态"的 SQL 来改写。如果它被别的 SQL 改写插件包在里面，改写的 SQL 在它外层看不到，就会漏改。**最佳实践：把 PageHelper 放在插件列表最后**（先声明）。

## 七、手写一个"SQL 审计"插件

```java
@Intercepts({
    @Signature(type = StatementHandler.class, method = "prepare",
               args = {Connection.class, Integer.class})
})
public class SqlAuditInterceptor implements Interceptor {

    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        StatementHandler handler = (StatementHandler) invocation.getTarget();
        BoundSql boundSql = handler.getBoundSql();
        String sql = boundSql.getSql().replaceAll("\\s+", " ");
        long start = System.currentTimeMillis();
        try {
            return invocation.proceed();
        } finally {
            long cost = System.currentTimeMillis() - start;
            if (cost > 500) { // 慢 SQL 告警
                System.err.printf("[慢SQL] %dms | %s%n", cost, sql);
            }
        }
    }
}
```

## 八、面试官连环追问

**Q1：MyBatis 插件为什么用 JDK 动态代理而不用 CGLIB？**
因为四大对象都实现了接口（Executor、StatementHandler 等都是接口），JDK 动态代理足够；MyBatis 内部大量使用接口编程，没有强制要求 CGLIB 的场景。

**Q2：插件能拦截私有方法或 final 方法吗？**
不能。JDK 动态代理只能代理接口方法；并且 `signatureMap` 匹配的是接口方法声明，私有方法根本不在接口里。

**Q3：插件会影响二级缓存吗？**
会。二级缓存（CachingExecutor）本身也是 Executor 的包装，插件链在 CachingExecutor 外层。如果插件拦截 Executor.query 且返回的结果没走缓存流程，可能破坏缓存语义——这也是为什么写插件要谨慎调用 `invocation.proceed()`。

**Q4：PageHelper 的 count 查询怎么生成的？**
把原 SQL 包一层：`SELECT COUNT(0) FROM (原SQL) table_count`，同时会智能移除 ORDER BY（因为排序对 count 无意义，还能省性能）。

**Q5：多个插件配置顺序会影响分页吗？**
会。插件是洋葱嵌套，外层先执行。PageHelper 要放在最外层（配置列表最后），确保它改写的是最终 SQL。

**Q6：自定义插件里的 setProperties 什么时候调用？**
解析 `<plugin>` 标签时调用，用于注入 `<property>` 配置，是插件参数化的入口。

## 九、总结

MyBatis 插件机制 = **四大对象工厂 + 拦截器链 + JDK 动态代理**：

- 拦截范围锁定 Executor / StatementHandler / ParameterHandler / ResultSetHandler 四个工厂产出对象
- 每个拦截器通过 `@Intercepts + @Signature` 声明要拦截的接口方法
- `Plugin.wrap` 生成动态代理，`signatureMap` 精确匹配方法
- 多插件形成洋葱模型，`invocation.proceed()` 逐层穿透
- PageHelper 本质就是"拦截 Executor.query -> 反射改写 BoundSql -> 追加 LIMIT"

理解了这个机制，你不仅能回答面试题，还能自己写分页、脱敏、审计、多租户隔离等生产级插件。
