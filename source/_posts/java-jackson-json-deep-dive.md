---
title: 【Java进阶】Jackson JSON 序列化深度解析：注解、自定义序列化与性能优化实战
date: 2026-07-12 08:00:00
tags:
  - Java
  - Jackson
  - JSON
  - 序列化
categories:
  - Java
  - 框架与工具
author: 东哥
---

# 【Java进阶】Jackson JSON 序列化深度解析：注解、自定义序列化与性能优化实战

## 一、Jackson 生态概览

Jackson 是 Java 生态中使用最广泛的 JSON 处理库之一，对标 Gson、Fastjson。它的核心由三个模块组成：

| 模块 | 功能 | Maven 坐标 |
|------|------|-----------|
| jackson-core | 底层 Streaming API（JsonParser / JsonGenerator） | 2.17.x |
| jackson-databind | 对象映射（ObjectMapper），依赖 core 和 annotations | 2.17.x |
| jackson-annotations | 注解支持（@JsonProperty、@JsonIgnore 等） | 2.17.x |

> 本文基于 Jackson 2.17.x，Spring Boot 3.x 内置此版本。

```xml
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
    <version>2.17.2</version>
</dependency>
```

## 二、ObjectMapper 核心配置

### 2.1 全局配置

```java
ObjectMapper mapper = new ObjectMapper();

// 反序列化：忽略未知字段
mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

// 序列化：日期格式化为 ISO-8601
mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

// 序列化：空对象不抛异常
mapper.disable(SerializationFeature.FAIL_ON_EMPTY_BEANS);

// 缩进输出（调试用）
mapper.enable(SerializationFeature.INDENT_OUTPUT);

// 设置时区
mapper.setTimeZone(TimeZone.getTimeZone("Asia/Shanghai"));

// 全局日期格式
mapper.setDateFormat(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"));
```

### 2.2 Spring Boot 中的定制

```java
@Configuration
public class JacksonConfig {

    @Bean
    public Jackson2ObjectMapperBuilderCustomizer jsonCustomizer() {
        return builder -> builder
            .serializationInclusion(JsonInclude.Include.NON_NULL)
            .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
            .featuresToDisable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .timeZone("Asia/Shanghai")
            .dateFormat(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"));
    }
}
```

## 三、常用注解精讲

### 3.1 属性注解

```java
public class UserDTO {

    @JsonProperty("user_id")         // 指定 JSON 字段名
    private Long id;

    @JsonAlias({"name", "userName"}) // 反序列化时接受的别名
    @JsonProperty("nickname")
    private String nickname;

    @JsonIgnore                      // 忽略字段
    private String password;

    @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss", timezone = "Asia/Shanghai")
    private LocalDateTime createTime;

    @JsonInclude(JsonInclude.Include.NON_NULL)  // 字段级非空才序列化
    private String email;

    @JsonRawValue                     // 嵌入原生 JSON 字符串
    private String extraInfo;
}
```

### 3.2 类注解

```java
@JsonIgnoreProperties(ignoreUnknown = true)  // 忽略未知字段
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)  // 全局驼峰 ⇄ 下划线
public class OrderVO {
    private String orderNo;
    private String userId;
}
```

### 3.3 动态过滤 - @JsonView

```java
public class UserViews {
    public static class Public {}
    public static class Internal extends Public {}
}

public class User {
    @JsonView(UserViews.Public.class)
    private Long id;

    @JsonView(UserViews.Public.class)
    private String nickname;

    @JsonView(UserViews.Internal.class)
    private String phone;
}

// 序列化时指定视图
mapper.writerWithView(UserViews.Public.class).writeValueAsString(user);
```

## 四、自定义序列化与反序列化

### 4.1 自定义序列化器

```java
public class MoneySerializer extends JsonSerializer<BigDecimal> {
    @Override
    public void serialize(BigDecimal value, JsonGenerator gen, SerializerProvider provider)
            throws IOException {
        // 金额保留两位小数，输出字符串防止精度丢失
        gen.writeString(value.setScale(2, RoundingMode.HALF_UP).toString());
    }
}

// 方式一：注解绑定
public class Order {
    @JsonSerialize(using = MoneySerializer.class)
    private BigDecimal amount;
}

// 方式二：全局注册
SimpleModule module = new SimpleModule();
module.addSerializer(BigDecimal.class, new MoneySerializer());
mapper.registerModule(module);
```

### 4.2 自定义反序列化器

```java
public class LocalDateTimeDeserializer extends JsonDeserializer<LocalDateTime> {
    @Override
    public LocalDateTime deserialize(JsonParser p, DeserializationContext ctxt) throws IOException {
        String dateStr = p.getText();
        DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
        return LocalDateTime.parse(dateStr, formatter);
    }
}

// 全局注册
SimpleModule module = new SimpleModule();
module.addDeserializer(LocalDateTime.class, new LocalDateTimeDeserializer());
mapper.registerModule(module);
```

### 4.3 @JsonSerialize(using) 与 StdSerializer 的性能差异

| 方式 | 性能 | 灵活性 | 适用场景 |
|------|------|--------|---------|
| @JsonSerialize(using=...) | 中等 | 低 | 单个字段特殊处理 |
| Module 全局注册 | 高 | 高 | 全局类型级处理 |
| MixIn | 高 | 中 | 无法修改源码的类 |

## 五、多态序列化

### 5.1 多态处理

```java
// 基类
@JsonTypeInfo(
    use = JsonTypeInfo.Id.NAME,
    property = "type"
)
@JsonSubTypes({
    @JsonSubTypes.Type(value = Circle.class, name = "circle"),
    @JsonSubTypes.Type(value = Rectangle.class, name = "rectangle")
})
public abstract class Shape {
    public String color;
}
```

## 六、性能优化实战

### 6.1 复用 ObjectMapper

**ObjectMapper 是线程安全的，应该全局复用！**

```java
// ❌ 错误：每次请求都 new
@GetMapping("/user")
public User getUser() {
    ObjectMapper mapper = new ObjectMapper();
    return mapper.readValue(jsonStr, User.class);
}

// ✅ 正确：全局单例
@Service
public class JsonService {
    private static final ObjectMapper MAPPER = new ObjectMapper()
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    public <T> T parse(String json, Class<T> clazz) {
        return MAPPER.readValue(json, clazz);
    }
}
```

### 6.2 使用 Stream API 处理大 JSON

```java
// 逐对象解析，避免 OOM
JsonFactory factory = new JsonFactory();
try (JsonParser parser = factory.createParser(new File("large.json"))) {
    while (parser.nextToken() != JsonToken.END_OBJECT) {
        String fieldName = parser.getCurrentName();

        if ("records".equals(fieldName)) {
            parser.nextToken(); // START_ARRAY
            while (parser.nextToken() != JsonToken.END_ARRAY) {
                Record record = mapper.readValue(parser, Record.class);
                process(record);
            }
        }
    }
}
```

### 6.3 内存优化

| 优化项 | 说明 | 效果 |
|--------|------|------|
| 禁用 FAIL_ON_EMPTY_BEANS | 避免空对象序列化抛异常 | 减少异常处理开销 |
| 设置 NON_NULL | 跳过 null 值字段 | 减少 JSON 体积 ~30% |
| 启用 AFTER_NAME_TRANSFORMATION | 延迟属性名转换 | 减少预热开销 |
| 复用 TokenBuffer / JsonGenerator | 减少对象分配 | GC 压力减少 40%+ |

### 6.4 基准测试对比

```java
@Benchmark
@BenchmarkMode(Mode.Throughput)
public String testJackson() throws Exception {
    return MAPPER.writeValueAsString(user);
}
```

> 结论：Jackson 性能在 10KB 以下的常规对象序列化中，与 Fastjson2 相当，远优于 Gson。

## 七、常见面试题

### Q1: Jackson 如何处理循环引用？

```java
// 方案一：@JsonIgnore 忽略一方
// 方案二：@JsonManagedReference / @JsonBackReference
// 方案三：@JsonIdentityInfo（推荐）
@JsonIdentityInfo(generator = ObjectIdGenerators.PropertyGenerator.class, property = "id")
public class Dept {
    private Long id;
    @JsonIdentityReference(alwaysAsId = true)
    private List<User> users;
}
```

### Q2: Jackson 和 Fastjson 的区别？

| 对比维度 | Jackson | Fastjson |
|---------|---------|----------|
| 性能 | 高（2.17 提升显著） | 高 |
| 社区活跃度 | 极活跃 | 低（维护模式） |
| 安全漏洞 | CVE 极少 | 历史 CVEs 较多 |
| Spring Boot 原生集成 | ✅ 默认 | ❌ 需额外配置 |
| 特性丰富度 | ★★★★★ | ★★★★ |

### Q3: 如何处理超大 JSON 文件？

使用 `JsonParser` 逐 Token 解析 + 分批处理，避免一次性加载整个 JSON 树到内存。

## 八、总结

Jackson 作为 Spring Boot 默认 JSON 框架，深度掌握其注解体系、自定义序列化器、Stream API 和性能优化技巧，是 Java 开发者的必备技能。建议在日常开发中：

1. **全局复用 ObjectMapper**，避免频繁创建
2. **善用 @JsonView** 控制不同场景的序列化视图
3. **大 JSON 用 Stream API**，避免 OOM
4. **配置脱敏序列化器**，统一处理手机号、身份证等敏感字段
5. **优先使用 Jackson 2.17+**，性能和安全都有显著提升
