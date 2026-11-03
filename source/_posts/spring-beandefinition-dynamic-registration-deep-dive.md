---
title: 【Spring 源码】BeanDefinition 与动态 Bean 注册深度解析：从注册中心到 AOT 边界
date: 2026-11-03 08:00:00
tags:
  - Java
  - Spring
  - Spring Boot
  - BeanDefinition
  - 源码
  - AOT
categories:
  - Spring
author: 东哥
---

# 【Spring 源码】BeanDefinition 与动态 Bean 注册深度解析

## 前言

日常写 Spring，我们习惯了 `@Component`、`@Bean`、`@Service`——声明式，编译期就确定了。

但有几类需求天然是「运行期才知道要几个 Bean」的：

- **多租户**：每个租户一套数据源 / 一套 MQ 消费者，租户是运营后台动态开通的
- **插件化**：从外部 jar 加载实现类，注册成 Bean，卸载时销毁
- **动态集成**：用户在管理界面配置一个「数据源连接」，系统立刻能查它
- **灰度/多版本**：同一接口按流量比例注册两个实现，路由决定用哪个

这些场景绕不开 `BeanDefinition`。而这套机制有三层坑：**注册时机**、**依赖刷新**、**AOT 兼容**。踩过一遍之后我把链路整理成这篇。

---

## 一、BeanDefinition 到底是什么

### 1.1 它不是 Bean，是「Bean 的图纸」

```java
public interface BeanDefinition extends AttributeAccessor, BeanMetadataElement {
    void setBeanClassName(String beanClassName);
    String getScope();
    boolean isLazyInit();
    String[] getDependsOn();
    boolean isPrimary();
    int getAutowireMode();
    String getInitMethodName();
    String getDestroyMethodName();
    MutablePropertyValues getPropertyValues();
    ConstructorArgumentValues getConstructorArgumentValues();
    // ...
}
```

关键认知：**BeanDefinition 是元数据，Bean 是它的实例化产物**。`refresh()` 的最后一步 `finishBeanFactoryInitialization` 才把非懒加载的 BeanDefinition 真正变成对象。

### 1.2 三种实现

| 实现 | 用途 | 特点 |
|---|---|---|
| `GenericBeanDefinition` | 通用，最常用 | 可设 parent，推荐手写注册时用 |
| `RootBeanDefinition` | 容器内部合并后的定义 | 无 parent，注册时也可用 |
| `ChildBeanDefinition` | 继承父定义 | 已不推荐（用 Generic + parentName） |
| `ScannedGenericBeanDefinition` | 组件扫描产生 | 带 `AnnotationMetadata` |

### 1.3 注册中心的两个 Map

`DefaultListableBeanFactory` 里：

```java
// bean 名字 → 定义
private final Map<String, BeanDefinition> beanDefinitionMap = new ConcurrentHashMap<>(256);
// 注册顺序（保持顺序很重要，影响 @Autowired 多候选时的排序基础）
private final List<String> beanDefinitionNames = new ArrayList<>(256);
// 手动注册的单例（registerSingleton 走的路径）
private final Map<String, Object> manualSingletonNames = new LinkedHashSet<>();
```

⚠️ 注意第三个：`registerSingleton()` 注册的对象**不会生成 BeanDefinition**，它只进 `manualSingletonNames` + `singletonObjects`。这意味着：

- 它**不参与** `BeanPostProcessor` 处理（除了已经在缓存里的）
- 它**不参与** `@Autowired` 注入到其他 Bean（除非在创建前就注册好）
- `getBeanDefinition(name)` 查不到它

这是很多人「用 registerSingleton 注册后注入不进去」的根因。

---

## 二、注册时机：三个层次

### 2.1 层次一：编译期确定的（@Component / @Bean）

组件扫描 → `ClassPathBeanDefinitionScanner` → 注册 `ScannedGenericBeanDefinition`。
`@Bean` 方法 → `ConfigurationClassPostProcessor` 解析配置类 → 注册为 `ConfigurationClassBeanDefinition`。

这些都在 `invokeBeanFactoryPostProcessors` 阶段完成，**早于任何业务 Bean 实例化**。

### 2.2 层次二：扩展点注册（推荐）

```java
public class DynamicDataSourceRegistrar
        implements BeanDefinitionRegistryPostProcessor, PriorityOrdered {

    @Override
    public void postProcessBeanDefinitionRegistry(BeanDefinitionRegistry registry) {
        // 这里注册的 BeanDefinition 会参与后续完整生命周期
        for (TenantConfig cfg : TenantConfigLoader.loadAll()) {
            GenericBeanDefinition def = new GenericBeanDefinition();
            def.setBeanClass(TenantDataSource.class);
            def.getConstructorArgumentValues()
               .addGenericArgumentValue(cfg.jdbcUrl());
            def.getConstructorArgumentValues()
               .addGenericArgumentValue(cfg.username());
            def.getConstructorArgumentValues()
               .addGenericArgumentValue(cfg.password());
            def.setDestroyMethodName("close");
            registry.registerBeanDefinition("ds-" + cfg.tenantId(), def);
        }
    }

    @Override
    public void postProcessBeanFactory(ConfigurableListableBeanFactory bf) {
        // 一般不用，留空
    }

    @Override
    public int getOrder() { return Ordered.HIGHEST_PRECEDENCE + 10; }
}
```

**两个方法的分工**（面试常问）：

| 方法 | 时机 | 能做什么 |
|---|---|---|
| `postProcessBeanDefinitionRegistry` | 所有 BeanDefinition 加载完、Bean 实例化之前 | **注册/修改/删除 BeanDefinition** |
| `postProcessBeanFactory` | 同上稍后 | 只能改 BeanFactory 本身（如设置 `allowBeanDefinitionOverriding`），**不能再注册** |

顺序：`BeanDefinitionRegistryPostProcessor` 全部执行完 → 再执行普通 `BeanFactoryPostProcessor`。

### 2.3 层次三：运行期注册（最危险）

`refresh()` 结束之后再注册，就进入了「半野生」状态：

```java
@RestController
public class TenantAdminController {
    private final DefaultListableBeanFactory bf;
    private final ApplicationContext ctx;

    @PostMapping("/tenants")
    public String addTenant(@RequestBody TenantConfig cfg) {
        GenericBeanDefinition def = new GenericBeanDefinition();
        def.setBeanClass(TenantDataSource.class);
        def.setScope(BeanDefinition.SCOPE_SINGLETON);
        def.getConstructorArgumentValues().addGenericArgumentValue(cfg.jdbcUrl());
        def.getConstructorArgumentValues().addGenericArgumentValue(cfg.username());
        def.getConstructorArgumentValues().addGenericArgumentValue(cfg.password());

        bf.registerBeanDefinition("ds-" + cfg.tenantId(), def);

        // ⚠️ 关键：必须手动触发创建，否则它只是「图纸」
        Object ds = bf.getBean("ds-" + cfg.tenantId());
        return "created: " + ds.getClass().getSimpleName();
    }
}
```

三个必须知道的限制：

1. **`@PostConstruct` / `InitializingBean` 仍会执行**（创建时走完整 `createBean` 流程），但 `BeanPostProcessor` 只对「之后创建的 Bean」生效
2. **已经被注入过的 Bean 不会重新注入**：如果某个 Service 已经持有 `List<DataSource>`，新注册的不会出现在这个 List 里
3. **`@Conditional` / `@Profile` 不会评估**：你绕过的是配置类解析阶段，条件注解根本不会跑

第 2 条最坑。解决办法只有两个：要么重启上下文（不现实），要么用「路由 + 注册表」的模式——**Bean 本身不动态，动态的是它内部维护的 Map**。

---

## 三、更推荐的做法：静态 Bean + 动态注册表

```java
@Component
public class TenantDataSourceRouter extends AbstractRoutingDataSource {
    private final Map<String, DataSource> registry = new ConcurrentHashMap<>();

    @Override
    protected Object determineCurrentLookupKey() {
        return TenantContext.get();     // ThreadLocal
    }

    /** 动态新增租户数据源：不打 BeanDefinition 的主意，只改内部注册表 */
    public void register(String tenantId, DataSource ds) {
        registry.put(tenantId, ds);
        setTargetDataSources(new HashMap<>(registry));   // 触发 afterPropertiesSet 重建
        afterPropertiesSet();
    }

    public void unregister(String tenantId) {
        DataSource ds = registry.remove(tenantId);
        if (ds instanceof Closeable c) {
            try { c.close(); } catch (IOException ignored) {}
        }
        setTargetDataSources(new HashMap<>(registry));
        afterPropertiesSet();
    }
}
```

**为什么这个方案更好**：

| 维度 | 动态 BeanDefinition | 静态 Bean + 注册表 |
|---|---|---|
| 依赖注入 | 新 Bean 无法注入到已有 Bean | 无影响 |
| 生命周期管理 | 走容器，但边界模糊 | 自己管，明确 |
| AOT / native | ❌ 不支持 | ✅ 支持 |
| 并发安全 | 容器内部锁，行为不透明 | 自己控制 |
| 可测试性 | 需要起容器 | 纯 POJO，好测 |

我的经验法则：**能不用动态 BeanDefinition，就不要用**。它适合「启动期按配置批量注册」，不适合「运行期随意增删」。

---

## 四、`ImportBeanDefinitionRegistrar`：库作者的正确姿势

如果你在写二方库（例如「自动注册所有 `@MyHandler` 注解的类」），用 `ImportBeanDefinitionRegistrar` 比 `BeanDefinitionRegistryPostProcessor` 更合适——它能拿到 `@Import` 所在配置类的注解元数据。

```java
public class HandlerScannerRegistrar implements ImportBeanDefinitionRegistrar {

    @Override
    public void registerBeanDefinitions(AnnotationMetadata meta,
                                        BeanDefinitionRegistry registry) {
        Map<String, Object> attrs = meta.getAnnotationAttributes(EnableHandlers.class.getName());
        String basePackage = (String) attrs.get("basePackage");

        ClassPathScanningCandidateComponentProvider scanner =
            new ClassPathScanningCandidateComponentProvider(false) {
                @Override
                protected boolean isCandidateComponent(AnnotatedBeanDefinition bd) {
                    // 默认只接受「独立且具体」的类，接口/抽象类会被过滤
                    return bd.getMetadata().isIndependent();
                }
            };
        scanner.addIncludeFilter(new AnnotationTypeFilter(MyHandler.class));

        for (BeanDefinition bd : scanner.findCandidateComponents(basePackage)) {
            String className = bd.getBeanClassName();
            String beanName = decapitalize(simpleName(className));
            if (registry.containsBeanDefinition(beanName)) {
                // ⚠️ Spring Boot 2.1+ 默认禁止覆盖，重复注册会抛异常
                continue;
            }
            registry.registerBeanDefinition(beanName, bd);
        }
    }
}
```

⚠️ **`registry.containsBeanDefinition` 这层判断不能省**：Spring Boot 2.1 起 `spring.main.allow-bean-definition-overriding` 默认 `false`，重复注册直接抛 `BeanDefinitionOverrideException`，而且是在启动时抛，很刺眼。

---

## 五、AOT / Native Image：动态注册的终结者

Spring Boot 3 引入 AOT 处理后，很多「运行期魔法」失效了。原因是：

**AOT 阶段（构建时）会固定 Bean 定义集合**，生成 `ApplicationContextInitializer` 和反射提示。运行期再 `registerBeanDefinition`，native image 里不会重新做 AOT 分析，结果就是：

- 启动时报 `ClassNotFoundException`（类没被注册进镜像）
- 或者 `NoSuchBeanDefinitionException`（定义没生成）
- 反射调用失败（缺 `RuntimeHints`）

如果你必须在 native 下动态注册，只能：

```java
@ImportRuntimeHints(MyHints.class)
public class MyHints implements RuntimeHintsRegistrar {
    @Override
    public void registerHints(RuntimeHints hints, ClassLoader cl) {
        hints.reflection().registerType(TenantDataSource.class,
            MemberCategory.INVOKE_PUBLIC_CONSTRUCTORS,
            MemberCategory.INVOKE_PUBLIC_METHODS);
        hints.resources().registerPattern("tenant/*.properties");
    }
}
```

⚠️ 即便如此，**「运行期任意新增类型的 Bean」在 native image 下也不可能**——镜像里的类集合是封闭的。所以做 native 化的服务，架构上必须放弃「运行期动态 Bean」这条路。

---

## 六、踩坑清单

1. **`registerSingleton` 后注入不进去**：因为它不进 `beanDefinitionMap`，已创建的 Bean 不会重新解析依赖。要么提前注册，要么用注册表模式。
2. **运行期注册的 Bean 没有 AOP 代理**：如果它需要 `@Transactional`，必须在注册时设置 `setAutowireMode` 且确保 `AbstractAutoProxyCreator` 能扫到——实际很难保证，建议改成「静态代理 Bean + 动态目标」。
3. **`FactoryBean` 的 `&` 前缀**：`getBean("x")` 拿产物，`getBean("&x")` 拿 FactoryBean 本身。动态注册时容易搞混。
4. **`@Conditional` 被跳过**：自己 `registerBeanDefinition` 不经过 `ConditionEvaluator`，条件注解形同虚设，会出现「测试环境也注册了生产数据源」的事故。
5. **Bean 名冲突**：Boot 2.1+ 默认不覆盖，重复注册启动失败。用 `containsBeanDefinition` 防御。
6. **`destroyMethodName` 忘了设**：动态注册的数据源永远不会被关，连接泄漏。这是最隐蔽的一类。
7. **顺序依赖**：如果你的 Bean 依赖某个 `BeanDefinitionRegistryPostProcessor` 注册的 Bean，注意 `PriorityOrdered` / `Ordered` 的排序，否则 `NoSuchBeanDefinitionException`。
8. **`getBean` 触发的循环依赖**：运行期 `getBean` 是在已有上下文中执行的，循环依赖的三级缓存可能已经清空，行为与启动期不同。

---

## 七、面试追问

**Q1：BeanDefinition 和 Bean 的关系？**
BeanDefinition 是元数据（图纸），描述类名、作用域、构造参数、属性、初始化/销毁方法、是否懒加载等；Bean 是容器按图纸实例化 + 初始化 + 后处理后的对象。一个 BeanDefinition 在 singleton 作用域下对应一个 Bean，prototype 下对应多个。

**Q2：`BeanDefinitionRegistryPostProcessor` 和 `BeanFactoryPostProcessor` 的区别？**
前者继承后者，多一个 `postProcessBeanDefinitionRegistry` 方法，可以在 Bean 实例化前注册新的 BeanDefinition。所有 `BeanDefinitionRegistryPostProcessor` 先执行，然后才执行普通 `BeanFactoryPostProcessor`。

**Q3：想在运行期注册一个 Bean，怎么做？有什么坑？**
`ConfigurableListableBeanFactory.registerBeanDefinition()` + 手动 `getBean()` 触发创建。坑：(1) 已注入的 Bean 不会重新注入；(2) `@Conditional` 不评估；(3) 可能没有 AOP 代理；(4) native image 不支持；(5) 需要自己管理销毁。

**Q4：`registerSingleton` 和 `registerBeanDefinition` 的区别？**
前者直接注册一个**已实例化的对象**，不进 `beanDefinitionMap`，不参与 BeanPostProcessor；后者注册**定义**，走完整创建流程。前者快但「不完整」，后者慢但生命周期完整。

**Q5：为什么 Spring Boot 2.1 默认禁止 Bean 覆盖？**
Bean 覆盖会静默掩盖配置错误（两个 `@Bean` 同名，谁生效取决于注册顺序）。默认禁止后，冲突会在启动时暴露。需要兼容旧行为时显式设 `spring.main.allow-bean-definition-overriding=true`。

**Q6：AOT 之后动态注册为什么不行？**
AOT 在构建期就把 Bean 定义集合、反射调用点、资源路径固化成代码和 hint。运行期新增的类型不在镜像里，无法加载；新增的定义也没有对应的生成代码。native image 的类集合是封闭的，这是根本限制。

---

## 八、总结

把这条链收成一张表：

| 需求 | 方案 |
|---|---|
| 启动期按配置批量注册 | `BeanDefinitionRegistryPostProcessor` / `ImportBeanDefinitionRegistrar` |
| 库作者自动装配 | `ImportBeanDefinitionRegistrar` + `@Import` |
| 运行期增删「同类对象」 | **静态 Bean + 内部注册表**（首选） |
| 运行期新增「新类型」 | 动态 BeanDefinition（慎用，放弃 AOT） |
| 只需要一个对象 | `registerSingleton`（注意注入限制） |

一句话：**BeanDefinition 是容器启动期的图纸，不是运行期的插件系统**。把它当插件系统用，短期能跑，长期一定会在依赖注入、代理、AOT 这三件事上翻车。

真正稳定的架构是：**Bean 集合静态化，变化的部分下沉到 Map/注册表/策略路由**。这样既保住了 Spring 的生命周期管理，又拿到了动态性。
