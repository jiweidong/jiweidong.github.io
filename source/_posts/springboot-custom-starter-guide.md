---
title: Spring Boot 自定义 Starter 开发实战
date: 2026-06-22 08:00:00
author: 东哥
categories:
  - Spring框架
tags:
  - Spring
  - SpringBoot
  - Starter
  - 自动配置
  - 实战
---

## 前言

Spring Boot Starter 是最常用的依赖管理方式——引入一个 starter，一组功能自动就绪。比如 `spring-boot-starter-web` 带来了内嵌 Tomcat + Spring MVC + Jackson。

如果你在团队中沉淀了公共组件（如短信 SDK、日志封装、安全校验、分布式锁），把它封装成 **自定义 Starter**，能让其他项目零成本集成。

本文从零开始，手写一个完整的 Starter，覆盖全部关键知识点。

---

## 一、Starter 的本质

**Starter = 自动配置类（AutoConfiguration） + 条件注解 + spring.factories**

核心原理：

```
starter 引入
    ↓
spring.factories 中声明自动配置类
    ↓
@ConditionalOnXxx 检查是否满足条件
    ↓
满足条件 → 自动配置生效（创建 Bean）
    ↓
使用者直接 @Autowired 即可
```

---

## 二、项目结构

对于一个自定义 Starter，推荐创建三个 Maven 模块：

```
my-spring-boot-starter       ← 对外依赖入口（简化用户引入）
  └── pom.xml（依赖 autoconfigure 模块）

my-spring-boot-autoconfigure ← 自动配置逻辑（核心实现）
  ├── pom.xml
  └── src/main/java/...
      └── META-INF/spring/
          └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

也可以合并在一个模块中，但拆分更规范（参考 Spring Boot 官方的 `spring-boot-starter-*` 和 `spring-boot-autoconfigure` 模块）。

---

## 三、实战：分布式锁 Starter

以 Redisson 分布式锁为例，封装一个开箱即用的 Starter。

### 3.1 创建 autoconfigure 模块

**pom.xml：**

```xml
<dependencies>
    <!-- 自动配置核心依赖 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-autoconfigure</artifactId>
        <scope>provided</scope>
    </dependency>

    <!-- 编译时元数据生成 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-configuration-processor</artifactId>
        <optional>true</optional>
    </dependency>

    <!-- 核心功能依赖 -->
    <dependency>
        <groupId>org.redisson</groupId>
        <artifactId>redisson-spring-boot-starter</artifactId>
        <version>3.27.2</version>
    </dependency>
</dependencies>
```

### 3.2 定义属性类

```java
@ConfigurationProperties(prefix = "my.lock")
public class RedisLockProperties {
    /** Redis 地址 */
    private String host = "localhost";
    private int port = 6379;
    private String password;
    /** 默认锁超时（毫秒） */
    private long lockWatchdogTimeout = 30000;

    // getters / setters ...
}
```

配置前缀 `my.lock`，用户可以在 `application.yml` 中配置：

```yaml
my:
  lock:
    host: 192.168.1.100
    port: 6379
    lock-watchdog-timeout: 30000
```

### 3.3 定义锁服务接口

```java
public interface DistributedLock {
    /**
     * 尝试获取锁
     * @param key 锁名称
     * @param waitTime 等待时间
     * @param leaseTime 持有时间
     * @param unit 时间单位
     * @return 是否获取成功
     */
    boolean tryLock(String key, long waitTime, long leaseTime, TimeUnit unit);

    /** 释放锁 */
    void unlock(String key);
}
```

### 3.4 实现默认锁服务

```java
public class RedissonDistributedLock implements DistributedLock {
    private final RedissonClient redissonClient;

    public RedissonDistributedLock(RedissonClient redissonClient) {
        this.redissonClient = redissonClient;
    }

    @Override
    public boolean tryLock(String key, long waitTime, long leaseTime, TimeUnit unit) {
        RLock lock = redissonClient.getLock(key);
        try {
            return lock.tryLock(waitTime, leaseTime, unit);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    @Override
    public void unlock(String key) {
        RLock lock = redissonClient.getLock(key);
        if (lock.isHeldByCurrentThread()) {
            lock.unlock();
        }
    }
}
```

### 3.5 定义自动配置类

```java
@Configuration
@ConditionalOnClass(RedissonClient.class)
@EnableConfigurationProperties(RedisLockProperties.class)
public class RedisLockAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public RedissonClient redissonClient(RedisLockProperties properties) {
        Config config = new Config();
        String address = "redis://" + properties.getHost() + ":" + properties.getPort();

        SingleServerConfig serverConfig = config.useSingleServer()
                .setAddress(address)
                .setConnectionPoolSize(10);

        if (properties.getPassword() != null && !properties.getPassword().isEmpty()) {
            serverConfig.setPassword(properties.getPassword());
        }

        config.setLockWatchdogTimeout(properties.getLockWatchdogTimeout());
        return Redisson.create(config);
    }

    @Bean
    @ConditionalOnMissingBean(DistributedLock.class)
    public DistributedLock distributedLock(RedissonClient redissonClient) {
        return new RedissonDistributedLock(redissonClient);
    }
}
```

**条件注解解读：**

| 注解 | 含义 |
|------|------|
| `@ConditionalOnClass(RedissonClient.class)` | classpath 存在 Redisson 才生效 |
| `@ConditionalOnMissingBean` | 用户没定义同类型 Bean 才创建 |
| `@EnableConfigurationProperties` | 启用属性绑定 |

### 3.6 注册自动配置

Spring Boot 3.0+（基于 spring-core 6.x）：

创建 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`：

```
com.example.lock.autoconfigure.RedisLockAutoConfiguration
```

Spring Boot 2.x 时代使用 `spring.factories`：

```properties
org.springframework.boot.autoconfigure.EnableAutoConfiguration=\
com.example.lock.autoconfigure.RedisLockAutoConfiguration
```

> **注意**：Spring Boot 3.0+ 不再扫描 `spring.factories` 中的自动配置，必须使用 `AutoConfiguration.imports` 文件。

### 3.7 创建 starter 模块

starter 模块本身只需要一个 pom.xml，依赖 autoconfigure 模块：

```xml
<artifactId>my-spring-boot-starter</artifactId>

<dependencies>
    <dependency>
        <groupId>com.example</groupId>
        <artifactId>my-spring-boot-autoconfigure</artifactId>
    </dependency>
</dependencies>
```

---

## 四、使用自定义 Starter

引入依赖：

```xml
<dependency>
    <groupId>com.example</groupId>
    <artifactId>my-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

配置：

```yaml
my:
  lock:
    host: 192.168.1.100
    port: 6379
```

使用：

```java
@Service
public class OrderService {
    @Autowired
    private DistributedLock distributedLock;

    public void createOrder() {
        String lockKey = "order:create:" + orderId;
        if (distributedLock.tryLock(lockKey, 3, 10, TimeUnit.SECONDS)) {
            try {
                // 业务逻辑
            } finally {
                distributedLock.unlock(lockKey);
            }
        }
    }
}
```

---

## 五、全部条件注解速查

| 注解 | 触发条件 |
|------|---------|
| `@ConditionalOnClass` | classpath 中存在指定类 |
| `@ConditionalOnMissingClass` | classpath 中不存在指定类 |
| `@ConditionalOnBean` | 容器中已存在指定 Bean |
| `@ConditionalOnMissingBean` | 容器中不存在指定 Bean |
| `@ConditionalOnProperty` | 配置项存在且符合值要求 |
| `@ConditionalOnResource` | classpath 中存在指定资源文件 |
| `@ConditionalOnWebApplication` | 当前是 Web 应用 |
| `@ConditionalOnNotWebApplication` | 当前不是 Web 应用 |
| `@ConditionalOnExpression` | SpEL 表达式结果为 true |
| `@ConditionalOnJava` | Java 版本匹配 |
| `@ConditionalOnSingleCandidate` | 容器中指定类型只有一个候选 Bean |

### 进阶组合示例

```java
@Configuration
@ConditionalOnProperty(prefix = "my.lock", name = "enabled", havingValue = "true", matchIfMissing = true)
@ConditionalOnClass(RedissonClient.class)
@ConditionalOnMissingBean(DistributedLock.class)
public class RedisLockAutoConfiguration {
    // 只有当配置 my.lock.enabled=true（或缺省）
    // 且 classpath 有 Redisson
    // 且用户没定义 DistributedLock Bean 时
    // 该配置才生效
}
```

---

## 六、测试 Starter

### 6.1 单元测试自动配置

```java
@SpringBootTest
@AutoConfigureMockMvc
class RedisLockAutoConfigurationTest {

    @Autowired
    private ApplicationContext context;

    @Test
    void testDistributedLockBeanCreated() {
        assertThat(context.containsBean("distributedLock")).isTrue();
        assertThat(context.getBean(DistributedLock.class)).isNotNull();
    }

    @Test
    void testRedissonClientCreated() {
        assertThat(context.containsBean("redissonClient")).isTrue();
        assertThat(context.getBean(RedissonClient.class)).isNotNull();
    }
}
```

### 6.2 模拟用户自定义 Bean 覆盖

```java
@SpringBootTest
class OverrideBeanTest {

    @TestConfiguration
    static class TestConfig {
        @Bean
        public DistributedLock distributedLock() {
            return (key, waitTime, leaseTime, unit) -> {
                System.out.println("Mock lock: " + key);
                return true;
            };
        }
    }

    @Autowired
    private DistributedLock distributedLock;

    @Test
    void testCustomBeanTakesPrecedence() {
        // 验证用户自定义的 Mock 实现生效了
        boolean locked = distributedLock.tryLock("test", 1, 5, TimeUnit.SECONDS);
        assertThat(locked).isTrue();
    }
}
```

---

## 七、AutoConfiguration.imports 与 spring.factories 演变

| Spring Boot 版本 | 自动配置注册方式 |
|------------------|----------------|
| 1.x | `spring.factories`（核心 key：`org.springframework.boot.autoconfigure.EnableAutoConfiguration`） |
| 2.x | 同上，兼容 | 
| 2.7+ | 开始支持 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`（新格式） |
| 3.0+ | **仅支持** `AutoConfiguration.imports`，不再读取 `spring.factories` 中的自动配置 |

如果你的项目同时兼容 2.x 和 3.x，需要同时提供两个文件：

- `META-INF/spring.factories`
- `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`

---

## 八、最佳实践

### 8.1 命名规范

| 组件 | 命名 |
|------|------|
| Starter | `xxx-spring-boot-starter` |
| Autoconfigure | `xxx-spring-boot-autoconfigure` |
| 属性类 | 使用 `Properties` 后缀，加 `@ConfigurationProperties` |

### 8.2 自动配置类放置位置

自动配置类放在 `autoconfigure` 模块的 `META-INF/spring/` 目录下注册。不要放在 `starter` 模块。

### 8.3 尽可能使用 @ConditionalOnMissingBean

让用户有能力覆盖你的默认实现。这是"约定优于配置"的核心体现。

### 8.4 生成配置元数据

添加 `spring-boot-configuration-processor` 依赖后编译，会在 `target/classes/META-INF/` 下生成 `spring-configuration-metadata.json`，IDE 阅读时会有自动补全和文档提示。

### 8.5 不要遗忘 auto-configuration 注解

自定义自动配置类需要：`@Configuration` + 适当 `@Conditional*` + 属性绑定按需开启。

---

## 总结

自定义 Starter 是 Spring Boot 生态的核心扩展方式。通过本文的练习，你应该能掌握：

1. 自动配置的注册链路：`AutoConfiguration.imports` → 自动配置类 → 条件判断 → Bean 创建
2. 属性绑定的规范用法
3. 条件注解的组合使用技巧
4. 用户覆盖默认配置的机制

写一个 Starter，本质就是把一组 Bean 的"自动创建逻辑"打包成一个可复用的依赖。理解了这一点，你在 Spring Boot 生态中就拥有了"组件级"的驾驭能力。
