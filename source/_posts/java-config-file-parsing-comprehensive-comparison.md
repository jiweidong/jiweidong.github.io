---
title: 【Java进阶】Java 配置文件解析方案深度对比：Properties、YAML、JSON、TOML 与自定义格式
date: 2026-07-25 08:00:00
tags:
  - Java
  - 配置文件
  - YAML
  - JSON
  - TOML
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】Java 配置文件解析方案深度对比：Properties、YAML、JSON、TOML 与自定义格式

## 前言

每个 Java 应用都需要读取配置——从 `application.properties` 到 `bootstrap.yml`，从 `logback.xml` 到自定义 `config.json`。配置文件解析看似简单，但选错方案会让你面临编码问题、性能瓶颈、安全风险。

本文深度对比 Java 中 **5 种主流配置文件格式** 的解析方案，从 API 用法到性能实测，帮你做出最佳选型。

---

## 一、Properties 文件：Java 原生配置格式

### 1.1 基础用法

`.properties` 文件是最古老也最简单的 Java 配置格式：

```properties
# config.properties
app.name=MyApp
app.version=1.0.0
app.debug=true
db.url=jdbc:mysql://localhost:3306/mydb
db.username=root
db.password=${DB_PASSWORD:-defaultPass}
server.port=8080
```

Java 原生 API 读取：

```java
Properties props = new Properties();
try (InputStream in = new FileInputStream("config.properties")) {
    props.load(in);
}

String name = props.getProperty("app.name");
int port = Integer.parseInt(props.getProperty("server.port"));
boolean debug = Boolean.parseBoolean(props.getProperty("app.debug"));
```

### 1.2 进阶用法

```java
// XML 格式的 Properties
Properties props = new Properties();
try (InputStream in = new FileInputStream("config.xml")) {
    props.loadFromXML(in);
}

// 写入
props.setProperty("app.name", "NewApp");
try (OutputStream out = new FileOutputStream("config.properties")) {
    props.store(out, "Application Config");
}
```

### 1.3 注意事项

```java
// ISO 8859-1 编码：中文需转义
Properties props = new Properties();
try (InputStreamReader reader = new InputStreamReader(
        new FileInputStream("config.properties"), StandardCharsets.UTF_8)) {
    props.load(reader);  // InputStreamReader 可指定编码
}
```

> ⚠️ `Properties.load()` 默认使用 **ISO 8859-1** 编码，中文需要手动转 Unicode 或使用 Reader。

### 1.4 Spring Boot 扩展：类型安全绑定

```java
@ConfigurationProperties(prefix = "app")
@Component
public class AppConfig {
    private String name;
    private Version version;
    private List<String> servers = new ArrayList<>();
    private Map<String, String> metadata = new HashMap<>();

    // getters & setters
}
```

Spring Boot 的 `@ConfigurationProperties` 让 Properties 也能支持 **嵌套对象、List、Map 和类型转换**——这才是生产级的用法。

---

## 二、YAML：Spring Boot 的首选格式

YAML（YAML Ain't Markup Language）以**缩进层级**代替 Properties 的扁平 `key=value`，可读性极高。

### 2.1 SnakeYAML 解析

Spring Boot 底层默认使用 **SnakeYAML** 库：

```xml
<!-- 独立使用 SnakeYAML -->
<dependency>
    <groupId>org.yaml</groupId>
    <artifactId>snakeyaml</artifactId>
    <version>2.2</version>
</dependency>
```

```yaml
# config.yml
server:
  port: 8080
  servlet:
    context-path: /api

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/db
    username: root
    password: secret
    hikari:
      maximum-pool-size: 20

app:
  name: MyApp
  version: 1.0.0
  features:
    - logging
    - monitoring
    - caching
  metadata:
    author: 张三
    license: MIT
```

```java
// SnakeYAML 加载
Yaml yaml = new Yaml();
try (InputStream in = new FileInputStream("config.yml")) {
    Map<String, Object> map = yaml.load(in);
    // 手动遍历 map 获取配置
}
```

更推荐的方式——**自定义 Java 对象映射**：

```java
public class AppConfig {
    private Server server;
    private Spring spring;
    private App app;
    // getters & setters...
}

Yaml yaml = new Yaml(new Constructor(AppConfig.class));
try (InputStream in = new FileInputStream("config.yml")) {
    AppConfig config = yaml.load(in);
    System.out.println(config.getServer().getPort());
}
```

### 2.2 Spring Boot 中的 YAML

```java
@Component
@ConfigurationProperties(prefix = "app")
public class FeatureConfig {
    private List<String> features;
    private String name;
    // ...
}
```

### 2.3 多文档 YAML

YAML 支持用 `---` 分隔多个文档，常用于多环境配置：

```yaml
# 默认配置
server:
  port: 8080
---
# 生产配置
spring:
  config:
    activate:
      on-profile: prod
server:
  port: 80
```

### 2.4 YAML 的坑

```java
// YAML 将字符串 "true"/"false" 自动转为 boolean
value: true      // 读出来是 Boolean，不是 String

// 数字也一样
port: 8080        // 读出来是 Integer

// 解决：用引号强制字符串
port: "8080"      // 读出来是 String

// 制表符 vs 空格：YAML 不允许制表符
// ❌ 错误：
// server:
// →	port: 8080  (使用了 Tab)

// ✅ 正确：
// server:
//   port: 8080  (使用了空格)
```

---

## 三、JSON 配置：通用性与工具链最丰富

JSON 虽然不是专为配置设计的格式，但在 Java 中生态最好——Jackson、Gson、Fastjson 三方工具任选。

### 3.1 Jackson 读取配置

```json
{
  "server": {
    "port": 8080,
    "contextPath": "/api"
  },
  "database": {
    "url": "jdbc:mysql://localhost:3306/db",
    "pool": {
      "maxSize": 20,
      "minIdle": 5
    }
  },
  "features": ["logging", "monitoring"]
}
```

```java
@JsonIgnoreProperties(ignoreUnknown = true)
public class JsonConfig {
    private ServerConfig server;
    private DatabaseConfig database;
    private List<String> features;
    // getters...
}

ObjectMapper mapper = new ObjectMapper()
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
JsonConfig config = mapper.readValue(new File("config.json"), JsonConfig.class);
```

### 3.2 带注释的 JSON（支持注释）

```json
{
  // 这是单行注释
  "app": {
    "name": "MyApp" /* 这是多行注释 */
  }
}
```

Jackson 默认**不支持注释**，需开启：

```java
ObjectMapper mapper = new ObjectMapper()
        .configure(JsonParser.Feature.ALLOW_COMMENTS, true);
```

### 3.3 JSON5（更友好的 JSON 配置）

```json
{
  // JSON5 格式
  name: 'MyApp',           // 属性名可省略引号
  version: 1.0,            // 尾部逗号允许
  description: "应用配置",   // 支持中文
}
```

Jackson 通过 `jackson-core` 的 `JsonReadFeature` 支持 JSON5。

---

## 四、TOML：Rust 社区推崇的配置格式

TOML（Tom's Obvious Minimal Language）的设计目标是**明确、语义清晰**，在 Rust 和 Go 社区非常流行，Java 生态也有对应的解析库。

```toml
# config.toml
[server]
port = 8080
host = "0.0.0.0"

[database]
url = "jdbc:mysql://localhost:3306/db"
max_connections = 100

[app]
name = "MyApp"
version = "1.0.0"

[app.features]
values = ["logging", "monitoring"]
```

### 4.1 TOML4J 解析

```xml
<dependency>
    <groupId>org.tomlj</groupId>
    <artifactId>tomlj</artifactId>
    <version>1.1.1</version>
</dependency>
```

```java
TomlParseResult result = Toml.parse(Paths.get("config.toml"));
String name = result.getString("app.name");
int port = result.getLong("server.port").intValue();
String dbUrl = result.getString("database.url");
List<String> features = result.getArray("app.features.values")
        .toList().stream()
        .map(Object::toString)
        .toList();

// 错误处理
if (result.hasErrors()) {
    result.errors().forEach(error -> System.err.println(error.toString()));
}
```

### 4.2 TOML vs YAML

| 特性 | TOML | YAML |
|------|------|------|
| 学习曲线 | 低（类 INI） | 中（缩进敏感） |
| 类型系统 | 显式 | 自动推断 |
| 复杂嵌套 | 一般 | 强 |
| 注释支持 | ✅ | ✅ |
| 大文件解析 | 快 | 中 |
| Java 生态 | 小众 | 主流（SnakeYAML） |

---

## 五、五格式全面对比

| 维度 | Properties | YAML | JSON | TOML | XML |
|------|-----------|------|------|------|-----|
| **层次结构** | ❌（扁平） | ✅（缩进） | ✅（层级） | ✅（表） | ✅ |
| **类型支持** | 纯字符串 | 自动推断 | 丰富 | 丰富 | XSD |
| **注释** | # | # | 需开启 | #，# | <!-- --> |
| **编码** | ISO 8859-1 | UTF-8 | UTF-8 | UTF-8 | UTF-8 |
| **Java 原生** | ✅ | ❌ | ❌ | ❌ | ✅（JAXB） |
| **可读性（简单）** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| **可读性（复杂）** | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| **库体积** | 0（内置） | 小 | 大（Jackson） | 小 | 大 |
| **解析速度** | 极快 | 快 | 中 | 快 | 慢 |
| **Spring Boot 支持** | ✅ | ✅ | 需额外配置 | 需额外配置 | ✗ |
| **最适合** | 简单 Key-Value | 复杂多层次配置 | 系统间配置交换 | 明确类型场景 | 结构化文档 |

---

## 六、实战：通用配置加载器

一个支持多格式的生产级配置加载器：

```java
public class ConfigLoader {
    private final ObjectMapper jsonMapper = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
            .enable(JsonParser.Feature.ALLOW_COMMENTS);

    /**
     * 根据文件扩展名自动选择解析器
     */
    public <T> T load(String path, Class<T> targetType) throws IOException {
        String ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase();
        return switch (ext) {
            case "properties" -> loadProperties(path, targetType);
            case "yml", "yaml" -> loadYaml(path, targetType);
            case "json" -> loadJson(path, targetType);
            case "toml" -> loadToml(path, targetType);
            default -> throw new IllegalArgumentException("Unsupported format: " + ext);
        };
    }

    @SuppressWarnings("unchecked")
    private <T> T loadProperties(String path, Class<T> targetType) throws IOException {
        Properties props = new Properties();
        try (InputStreamReader reader = new InputStreamReader(
                new FileInputStream(path), StandardCharsets.UTF_8)) {
            props.load(reader);
        }
        // 简单映射：如果目标类型是 Properties 直接返回
        if (Properties.class.equals(targetType)) {
            return (T) props;
        }
        // 否则通过 Spring Boot 的 RelaxedBinding 风格转换
        // 这里简单示例：用 Jackson 转换
        Map<String, String> map = new HashMap<>();
        props.forEach((k, v) -> map.put((String) k, (String) v));
        // 扁平结构转嵌套需要额外处理
        return jsonMapper.convertValue(flattenToNested(map), targetType);
    }

    private <T> T loadYaml(String path, Class<T> targetType) throws IOException {
        Yaml yaml = new Yaml(new Constructor(targetType, new DefaultConstructor(true)));
        try (InputStream in = new FileInputStream(path)) {
            return yaml.load(in);
        }
    }

    private <T> T loadJson(String path, Class<T> targetType) throws IOException {
        return jsonMapper.readValue(new File(path), targetType);
    }

    @SuppressWarnings("unchecked")
    private <T> T loadToml(String path, Class<T> targetType) throws IOException {
        TomlParseResult result = Toml.parse(Paths.get(path));
        // 转成 Map 再转目标类型
        Map<String, Object> map = new HashMap<>();
        result.dottedEntrySet().forEach(entry ->
                map.put(entry.key().toString(), entry.value()));
        return jsonMapper.convertValue(map, targetType);
    }

    /** 将扁平 key 转为嵌套 Map：db.url → {db: {url: ...}} */
    private Map<String, Object> flattenToNested(Map<String, String> flat) {
        Map<String, Object> nested = new HashMap<>();
        flat.forEach((key, value) -> {
            String[] parts = key.split("\\.");
            Map<String, Object> current = nested;
            for (int i = 0; i < parts.length - 1; i++) {
                current = (Map<String, Object>) current.computeIfAbsent(
                        parts[i], k -> new HashMap<String, Object>());
            }
            current.put(parts[parts.length - 1], value);
        });
        return nested;
    }
}
```

---

## 七、面试追问

> **Q：为什么 Spring Boot 选择 YAML 作为默认配置格式？**
> A：YAML 支持层次结构和多文档，比 Properties 更适合复杂配置。Spring 官方在 2012 年就引入了 YAML 支持。不过 2023 年起 Spring Boot 3.x 也强力推荐 `.properties`（因为记录顺序保持、环境切换更精确），但 YAML 仍是大多数人的首选。

> **Q：配置文件的优先级/覆盖机制是怎样的？**
> A：Spring Boot 的优先级是：命令行参数 > JNDI > 系统属性 > 环境变量 > `application-{profile}.properties` > `application.properties` > `@PropertySource`。Profile 后缀优先级高于无后缀文件。

> **Q：敏感配置（密码、密钥）怎么处理？**
> A：使用 Jasypt 或 Spring Cloud Vault 加密。生产环境优先通过环境变量或 Kubernetes Secret 注入，不写入配置文件。

> **Q：大配置文件解析，哪个性能最好？**
> A：纯 Properties 解析最快（无语法树构建），YAML 次之（需要缩进解析），JSON 和 XML 最慢（需构建完整语法树）。超大规模配置（几百 KB+）建议用 Properties 或 TOML。

---

## 总结

- **简单项目 / 遗留系统** → Properties（内置，零依赖）
- **Spring Boot 项目** → YAML（层次清晰，多环境支持好）
- **跨语言配置交换** → JSON（生态最好，工具链成熟）
- **类型安全 / 明确语义** → TOML（新兴格式，值得关注）
- **结构化配置文件** → XML（XSD 校验，数据交换）

**没有最好的格式，只有最适合场景的格式。** 掌握各种方案的优缺点，才能在每个项目中做出正确的选型。
