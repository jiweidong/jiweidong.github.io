---
title: 【源码深度】MyBatis-Spring 集成原理深度解析：从 @MapperScan 到 MapperFactoryBean 与 SqlSessionTemplate
date: 2026-09-10 08:00:00
tags:
  - MyBatis
  - Spring
  - 源码
  - 面试
categories:
  - Java
  - 数据库
author: 东哥
---

# 【源码深度】MyBatis-Spring 集成原理深度解析：从 @MapperScan 到 MapperFactoryBean 与 SqlSessionTemplate

## 面试官：你项目里 MyBatis 的 Mapper 接口为什么不用写实现类就能用？

很多同学天天用 `@Mapper` / `@MapperScan`，Mapper 接口一个实现类都没写，却能在 Service 里直接 `@Autowired` 注入并调用。面试官只要追问一句"**MyBatis 是怎么把接口变成 Bean 的？**"，不少人就卡住了。

本文从 `@MapperScan` 入手，一路拆到 `MapperFactoryBean`、`SqlSessionTemplate` 和 JDK 动态代理，把 MyBatis-Spring 集成的完整链路讲透。

## 一、整体架构：三层协作

MyBatis-Spring 集成（`mybatis-spring` 模块）的核心是三个角色：

| 角色 | 类 | 职责 |
|---|---|---|
| 注册入口 | `@MapperScan` / `MapperScannerConfigurer` | 扫描指定包，把每个 Mapper 接口注册为 BeanDefinition |
| 工厂 | `MapperFactoryBean` | 实现 `FactoryBean`，`getObject()` 返回 Mapper 代理对象 |
| 会话门面 | `SqlSessionTemplate` | 线程安全的 SqlSession 封装，真正执行 SQL |

调用链路可以概括为：

```
@MapperScan 扫描包
   └─> 为每个接口注册 MapperFactoryBean 的 BeanDefinition
          └─> Spring 实例化时调用 MapperFactoryBean.getObject()
                 └─> 通过 JDK 动态代理创建 Mapper 接口实现
                        └─> 方法调用 → MapperProxy → SqlSessionTemplate
                               └─> 从 SqlSessionFactory 获取/复用 SqlSession 执行 SQL
```

## 二、第一步：@MapperScan 是怎么把接口"扫"进来的

### 2.1 @Import 引入 Registrar

`@MapperScan` 注解上标着 `@Import(MapperScannerRegistrar.class)`，而 `MapperScannerRegistrar` 实现了 `ImportBeanDefinitionRegistrar`。Spring 处理配置类时，会把 Registrar 的 `registerBeanDefinitions()` 回调出来：

```java
public void registerBeanDefinitions(AnnotationMetadata importingClassMetadata,
                                    BeanDefinitionRegistry registry) {
    AnnotationAttributes mapperScanAttrs = AnnotationAttributes
            .fromMap(importingClassMetadata.getAnnotationAttributes(MapperScan.class.getName()));
    if (mapperScanAttrs != null) {
        registerBeanDefinitions(importingClassMetadata, registry, mapperScanAttrs);
    }
}
```

### 2.2 关键：ClassPathMapperScanner

Registrar 内部创建了 `ClassPathMapperScanner`（它继承 Spring 的 `ClassPathBeanDefinitionScanner`），并做了三件关键配置：

```java
scanner.setAnnotationClass(Mapper.class);          // 只认标了 @Mapper 的接口
scanner.setMarkerInterface(...);                    // 或继承指定标记接口
scanner.setMapperFactoryBeanClass(MapperFactoryBean.class); // 指定工厂 Bean
scanner.registerFilters();                          // 注册扫描过滤器
```

然后调用 `scanner.scan(basePackages)` 开始扫描。注意：**扫描器本身扫描到的其实只是普通接口 BeanDefinition**，真正点石成金的是后面的 `processBeanDefinitions` 方法。

### 2.3 processBeanDefinitions：偷梁换柱

`ClassPathMapperScanner.processBeanDefinitions()` 是集成最核心的一步，它把每个 Mapper 接口的 BeanDefinition 做如下改造：

```java
// 1. 构造函数改为 MapperFactoryBean(接口.class)
beanDefinition.getConstructorArgumentValues()
    .addGenericArgumentValue(beanClassName); // 接口的 Class 对象

// 2. 把 beanClass 换成 MapperFactoryBean
beanDefinition.setBeanClass(this.mapperFactoryBeanClass);

// 3. 注入 SqlSessionFactory / SqlSessionTemplate 引用（按类型自动装配）
beanDefinition.getPropertyValues().add("sqlSessionFactory", ...);
beanDefinition.setAutowireMode(AbstractBeanDefinition.AUTOWIRE_BY_TYPE);
```

改造后的 BeanDefinition 等价于：

```xml
<bean id="userMapper" class="org.mybatis.spring.mapper.MapperFactoryBean">
    <constructor-arg value="com.example.mapper.UserMapper"/>
    <property name="sqlSessionFactory" ref="sqlSessionFactory"/>
</bean>
```

所以从 Spring 视角看，`UserMapper` 这个 Bean 其实是一个 **MapperFactoryBean 实例**（工厂本身），而 `UserMapper` 接口类型是它的**构造参数**。

## 三、第二步：MapperFactoryBean 如何生产代理对象

### 3.1 为什么用 FactoryBean

`MapperFactoryBean` 继承 `SqlSessionDaoSupport`，实现 `FactoryBean<T>`。Spring 在注入时发现是 FactoryBean，会先创建工厂本身，再调用 `getObject()` 拿到真正的产品：

```java
public class MapperFactoryBean<T> extends SqlSessionDaoSupport implements FactoryBean<T> {

    private Class<T> mapperInterface;   // 通过构造函数传入的接口

    @Override
    public T getObject() throws Exception {
        // 从 SqlSessionTemplate 拿 Mapper 代理
        return getSqlSession().getMapper(this.mapperInterface);
    }

    @Override
    public Class<T> getObjectType() {
        return this.mapperInterface;
    }

    @Override
    protected void checkDaoConfig() {
        // 校验：接口必须存在、必须注册过 statement、必须声明为 Mapper
        super.checkDaoConfig();
        if (!this.mapperInterface.isInterface()) {
            throw new IllegalArgumentException("...不是接口");
        }
        Configuration configuration = getSqlSession().getConfiguration();
        if (configuration.hasMapper(this.mapperInterface)) {
            // 把接口注册进 MyBatis Configuration（解析 @Select 等注解、绑定 statement）
            configuration.addMapper(this.mapperInterface);
        }
    }
}
```

注意 `checkDaoConfig()`：Spring 在 `afterPropertiesSet()` 阶段调用它，此时会把 Mapper 接口**注册进 MyBatis 的 Configuration**（解析注解 SQL / 绑定 XML statement）。这也是为什么你的 Mapper 接口上写 `@Select` 注解就能直接用的原因。

### 3.2 单例还是多例？

`MapperFactoryBean` 默认是单例（`@Scope("singleton")` 由 BeanDefinition 默认值决定），每个 Mapper 接口全局只有一个代理实例。这也带来一个常见坑：**Mapper 代理是线程安全的，但里面持有的 SqlSessionTemplate 才是并发安全的关键**。

## 四、第三步：SqlSessionTemplate 与动态代理执行

### 4.1 Mapper 代理：MapperProxy

`sqlSession.getMapper(interface)` 最终走到 MyBatis 的 `MapperRegistry.getMapper()`，用 `MapperProxyFactory` 创建 JDK 动态代理：

```java
public T newInstance(SqlSession sqlSession) {
    MapperProxy<T> mapperProxy = new MapperProxy<>(sqlSession, mapperInterface, methodCache);
    return (T) Proxy.newProxyInstance(mapperInterface.getClassLoader(),
            new Class[]{mapperInterface}, mapperProxy);
}
```

`MapperProxy` 实现了 `InvocationHandler`，每个方法调用最终进入 `MapperMethod.execute()`，根据 SQL 类型分发：

```java
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    // Object 自带方法（toString/hashCode 等）直接走原生实现
    if (Object.class.equals(method.getDeclaringClass())) {
        return method.invoke(this, args);
    }
    // 默认方法（Java 8+）走原生调用
    ...
    // 真正的 SQL 执行
    return cachedInvoker(method).invoke(proxy, method, args, sqlSession);
}
```

### 4.2 为什么不用原生 SqlSession

MyBatis 原生的 `DefaultSqlSession` **不是线程安全的**（每个 SqlSession 持有独立的 Executor 和一级缓存），不能在单例 Mapper 里共享。MyBatis-Spring 因此提供了 `SqlSessionTemplate`，它实现了 `SqlSession` 接口并**动态代理了所有方法**：

```java
public class SqlSessionTemplate implements SqlSession, DisposableBean {

    private final SqlSessionFactory sqlSessionFactory;
    private final ExecutorType executorType;
    private final SqlSession sqlSessionProxy;  // 代理对象

    public SqlSessionTemplate(SqlSessionFactory sqlSessionFactory) {
        ...
        this.sqlSessionProxy = (SqlSession) Proxy.newProxyInstance(
            SqlSessionFactory.class.getClassLoader(),
            new Class[]{SqlSession.class},
            new SqlSessionInterceptor());  // 关键拦截器
    }
}
```

`SqlSessionInterceptor` 的逻辑是：

```java
public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
    // 1. 从 Spring 事务同步器拿当前事务绑定的 SqlSession（有事务就复用）
    SqlSession sqlSession = getSqlSession(this.sqlSessionFactory,
            this.executorType, exceptionTranslator);
    try {
        // 2. 真正执行
        Object result = method.invoke(sqlSession, args);
        // 3. 若不在 Spring 管理的事务中，立即提交（自动提交模式）
        if (!isSqlSessionTransactional(sqlSession, this.sqlSessionFactory)) {
            sqlSession.commit(true);
        }
        return result;
    } catch (Throwable t) {
        // 4. 翻译异常：把 MyBatis 的 PersistenceException
        //    转成 Spring 的 DataAccessException（配合 @Transactional 回滚）
        Throwable unwrapped = translateException(t);
        ...
        throw unwrapped;
    } finally {
        // 5. 关闭/归还 SqlSession
        closeSqlSession(sqlSession, this.sqlSessionFactory);
    }
}
```

这段代码解释了两个高频面试点：

1. **为什么 Mapper 方法不用手动 commit？** —— 非事务场景下 SqlSessionTemplate 自动 `commit(true)`；
2. **为什么 MyBatis 异常能被 Spring 事务回滚？** —— 异常被翻译成 Spring 的 `DataAccessException`，满足 `@Transactional` 默认只回滚 RuntimeException 的约定。

### 4.3 事务内复用同一个 SqlSession

`getSqlSession()` 内部通过 `TransactionSynchronizationManager.getResource(sqlSessionFactory)` 查找当前线程事务是否已绑定 SqlSession。若 `@Transactional` 已开启事务，Spring 事务管理器会在 DataSource 上注册同步，MyBatis 的 `SpringManagedTransaction` 保证 **一个事务内所有 Mapper 操作共用同一个 SqlSession 和同一个数据库连接**，从而保证事务的原子性。这也是为什么"事务里查一次再改一次，一级缓存能命中"。

## 五、没有 @MapperScan 的三种替代方式

| 方式 | 原理 | 适用场景 |
|---|---|---|
| `@Mapper` 逐个标注 | 被 Spring Boot 的 `AutoConfiguredMapperScannerRegistrar` 自动扫描到 | Mapper 数量少 |
| `@MapperScan` 包扫描 | 显式指定 basePackages，可多包 | 常规项目，最推荐 |
| `@MapperScan(markerInterface=...)` | 只扫描继承某标记接口的 Mapper | 规范约束型团队 |
| XML `<mybatis:scan>` | 命名空间方式，底层同 MapperScannerConfigurer | 纯 XML 配置项目 |

**Spring Boot 中的自动装配**：`mybatis-spring-boot-starter` 在 `MybatisAutoConfiguration` 中自动注册了 `SqlSessionFactory`（从数据源构建）和 `SqlSessionTemplate`，并且若你**没有**显式声明 `@MapperScan`，`AutoConfiguredMapperScannerRegistrar` 会扫描启动类所在包及其子包下所有带 `@Mapper` 的接口。

## 六、高频面试追问

**Q1：一个 Mapper 接口能被注入两次吗？会怎样？**
会。`@MapperScan("com.example.mapper")` 指定了包，接口上又标了 `@Mapper`，Spring Boot 的自动扫描和 `@MapperScan` 扫描会注册两个 BeanDefinition → 启动报 `NoUniqueBeanDefinitionException`。解决：二选一，或 `@MapperScan` 指定 `annotationClass = None.class` 关闭注解过滤。

**Q2：为什么 Mapper 不能定义为 prototype 作用域？**
技术上可以，但没必要。Mapper 代理是无状态的（状态都在线程安全的 SqlSessionTemplate 里），单例足够；每次 getObject() 创建代理还会带来不必要的开销。

**Q3：MyBatis 一级缓存为什么在 Spring 里"有时生效有时不生效"？**
`SqlSessionTemplate` 每次非事务调用都可能拿到**新的 SqlSession**（从 SqlSessionUtils 创建），一级缓存随 SqlSession 销毁 → 看起来"失效"。只有包在同一个 `@Transactional` 里时，才共用同一个 SqlSession，一级缓存稳定生效。这解释了网上"一级缓存时灵时不灵"的困惑。

**Q4：MapperFactoryBean 和普通 FactoryBean 有什么区别？**
区别在它继承 `SqlSessionDaoSupport`：`afterPropertiesSet()` 时不仅做 FactoryBean 校验，还会把 Mapper 接口 `addMapper` 进 MyBatis Configuration，完成注解/XML statement 的注册绑定。普通 FactoryBean 只负责生产对象。

## 七、总结

- `@MapperScan` 通过 `@Import` + `ClassPathMapperScanner` 把接口 BeanDefinition **改造成 MapperFactoryBean**；
- `MapperFactoryBean.getObject()` 用 JDK 动态代理生成 Mapper 接口实现；
- 代理内部统一走 **SqlSessionTemplate**（线程安全门面），非事务自动提交、异常翻译成 Spring 体系；
- 事务场景下通过 `TransactionSynchronizationManager` 复用同一 SqlSession，保证事务与一级缓存的语义。

**一条主线记牢**：接口 → BeanDefinition 改造 → FactoryBean → JDK 代理 → SqlSessionTemplate → 事务同步。把这根链条讲清楚，MyBatis 集成相关的面试题基本就稳了。
