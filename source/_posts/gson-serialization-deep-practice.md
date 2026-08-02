---
title: 【Java进阶】Gson 序列化框架深度实战：从 TypeToken 到自定义适配器与性能优化
date: 2026-08-02 08:00:00
tags:
  - Java
  - Gson
  - JSON
  - 实战
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】Gson 序列化框架深度实战：从 TypeToken 到自定义适配器与性能优化

## 面试官：Gson 的 TypeToken 为什么能解决泛型擦除问题？它和 Jackson、Fastjson 比到底选哪个？

Gson 是 Google 出品的 JSON 序列化库，以**简单易用、无依赖、默认行为安全**著称。但很多开发者只停留在 `new Gson().toJson(obj)` 的层面，遇到泛型反序列化、不可变对象、字段改名、超大 JSON 流式处理就手足无措。

本篇文章从 Gson 的核心设计讲起，覆盖 TypeToken 泛型原理、常用注解、自定义适配器、流式解析与性能对比，让你真正吃透 Gson。

## 一、Gson 的核心设计理念

```java
Gson gson = new Gson();
String json = gson.toJson(user);              // 序列化：对象 → JSON
User user = gson.fromJson(json, User.class);  // 反序列化：JSON → 对象
```

Gson 的设计哲学：

1. **零配置可用**：默认能序列化绝大多数 POJO，无需任何注解；
2. **无第三方依赖**：纯 JDK 实现，适合 Android、工具类、嵌入式场景；
3. **默认安全**：不做自动类型转换（`"1"` 不会静默变成数字）、默认不输出 null 字段；
4. **泛型支持完善**：通过 `TypeToken` 完美解决泛型擦除问题（这是它比早期 Jackson 更早解决的问题）。

## 二、核心机制：TypeToken 与泛型擦除

### 1. 问题：为什么 `fromJson(json, List<User>.class)` 不行？

Java 泛型是**编译期擦除**的，`List<User>.class` 在运行时只有 `List.class`，`User` 的类型信息丢失了。于是 Gson 不知道要把 JSON 数组元素反序列化成什么类型，只能默认给你 `List<LinkedTreeMap>`——里面全是 Map，不是 User 对象！

### 2. 解法：TypeToken 捕获泛型类型

```java
Type userListType = new TypeToken<List<User>>() {}.getType();
List<User> users = gson.fromJson(json, userListType);
```

**原理**：`new TypeToken<List<User>>() {}` 创建了一个**匿名内部类**。匿名类在编译时会在字节码的 Signature 属性中**记录父类泛型参数**（`List<User>`），运行时通过反射 `getGenericSuperclass()` 就能拿到完整的泛型信息 `ParameterizedType`。这就是"利用匿名类绕过类型擦除"的经典技巧。

```java
// TypeToken 内部的关键实现（简化）
public class TypeToken<T> {
    final Type type;

    protected TypeToken() {
        Type superclass = getClass().getGenericSuperclass();
        // 校验确实是 ParameterizedType（否则说明没写泛型参数）
        if (superclass instanceof ParameterizedType parameterizedType) {
            this.type = parameterizedType.getActualTypeArguments()[0];
        } else {
            throw new RuntimeException("TypeToken 必须带泛型参数使用");
        }
    }
}
```

**面试加分点**：`getGenericSuperclass()` 返回的 `ParameterizedType` 是一个**类型树**（可以无限嵌套），所以 `new TypeToken<Map<String, List<Order>>>() {}` 这种复杂泛型也能完整还原。`getActualTypeArguments()[0]` 取出第一个泛型实参，即目标类型。

### 3. 常见泛型场景速查

```java
// 嵌套泛型：Map<String, List<User>>
Type type = new TypeToken<Map<String, List<User>>>() {}.getType();

// 泛型类自身也是泛型参数：Result<T>
Type type2 = new TypeToken<Result<List<User>>>() {}.getType();

// 注意：new TypeToken<List<User>>() 不加 {} 是不行的！
// TypeToken 是抽象类的思想，必须通过匿名子类捕获泛型
```

## 三、常用注解实战

### 1. @SerializedName：字段改名

后端接口字段风格与 Java 命名不一致时的救星：

```java
public class UserDTO {
    @SerializedName("user_id")   // JSON 里叫 user_id
    private Long userId;

    @SerializedName(value = "full_name", alternate = {"name", "nickName"})
    private String fullName;      // 反序列化时兼容多种输入名
}
```

`alternate` 支持**反序列化时接受多个别名**（序列化时仍输出 `value` 指定的名字），对接历史遗留接口非常实用。

### 2. @Expose：字段黑白名单

```java
public class User {
    @Expose                       // 默认 serialize=true, deserialize=true
    private Long id;

    @Expose(serialize = false)    // 只进不出：密码只接收不返回
    private String password;

    private String internal;      // 无 @Expose 的字段，默认被忽略！
}
```

注意：**@Expose 只在 `new GsonBuilder().excludeFieldsWithoutExposeAnnotation().create()` 时才生效**，普通 `new Gson()` 会忽略它。

### 3. @Since / @Until：版本化字段

```java
public class ApiResponse {
    @Since(1.0)   private String v1Field;
    @Since(2.0)   private String v2Field;   // 2.0 才有的字段
    @Until(1.5)   private String deprecatedField;
}

Gson gson = new GsonBuilder().setVersion(1.2).create();
// 序列化结果只包含 @Since(<=1.2) 且 @Until(>1.2) 的字段
```

适合做 **API 多版本共存**的响应裁剪。

### 4. null 与默认值控制

```java
// 默认：null 字段不输出
Gson defaultGson = new Gson();

// 输出 null 字段
Gson nullGson = new GsonBuilder().serializeNulls().create();

// 输出格式化 JSON（调试用，生产慎用）
Gson prettyGson = new GsonBuilder().setPrettyPrinting().create();
```

## 四、自定义适配器：处理复杂对象

### 1. JsonSerializer / JsonDeserializer

场景：后端存的是 `LocalDateTime`，前端要 `yyyy-MM-dd HH:mm:ss` 字符串：

```java
public class LocalDateTimeAdapter
        implements JsonSerializer<LocalDateTime>, JsonDeserializer<LocalDateTime> {

    private static final DateTimeFormatter FMT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    @Override
    public JsonElement serialize(LocalDateTime src, Type type,
                                 JsonSerializationContext context) {
        return new JsonPrimitive(FMT.format(src));
    }

    @Override
    public LocalDateTime deserialize(JsonElement json, Type type,
                                     JsonDeserializationContext context) {
        return LocalDateTime.parse(json.getAsString(), FMT);
    }
}

// 注册
Gson gson = new GsonBuilder()
        .registerTypeAdapter(LocalDateTime.class, new LocalDateTimeAdapter())
        .create();
```

### 2. TypeAdapter：更快、更推荐的方式

`TypeAdapter` 直接读写 JSON 流，**比 JsonSerializer 性能好**，还能做流式定制：

```java
public class BigDecimalAdapter extends TypeAdapter<BigDecimal> {
    // 反序列化时把字符串/数字统一转 BigDecimal，杜绝 double 精度丢失
    @Override
    public void write(JsonWriter out, BigDecimal value) throws IOException {
        if (value == null) {
            out.nullValue();
        } else {
            out.value(value);  // 输出数字
        }
    }

    @Override
    public BigDecimal read(JsonReader in) throws IOException {
        if (in.peek() == JsonToken.NULL) {
            in.nextNull();
            return null;
        }
        String s = in.nextString();  // 兼容 "12.34" 和 12.34
        return new BigDecimal(s);
    }
}
```

**何时用哪种？**

| 方式 | 性能 | 灵活度 | 适用场景 |
|------|------|--------|---------|
| 默认反射 | 中 | 低 | 常规 POJO |
| JsonSerializer/Deserializer | 中 | 高（操作 JsonElement 树） | 字段映射、格式转换 |
| **TypeAdapter** | **高（流式）** | 高（直接读写流） | 性能敏感、自定义格式、不可变对象 |
| @SerializedName + 注解 | 高 | 中 | 大部分字段级需求 |

### 3. 处理不可变对象（无 setter / final 字段）

```java
public class ImmutablePoint {
    private final int x;
    private final int y;

    public ImmutablePoint(int x, int y) { this.x = x; this.y = y; }
    // 只有 getter，没有无参构造器
}

public class PointAdapter extends TypeAdapter<ImmutablePoint> {
    @Override
    public void write(JsonWriter out, ImmutablePoint p) throws IOException {
        out.beginObject();
        out.name("x").value(p.getX());
        out.name("y").value(p.getY());
        out.endObject();
    }

    @Override
    public ImmutablePoint read(JsonReader in) throws IOException {
        int x = 0, y = 0;
        in.beginObject();
        while (in.hasNext()) {
            switch (in.nextName()) {
                case "x" -> x = in.nextInt();
                case "y" -> y = in.nextInt();
                default -> in.skipValue();
            }
        }
        in.endObject();
        return new ImmutablePoint(x, y);  // 走构造器，绕过反射
    }
}
```

默认 Gson 反序列化依赖**无参构造器 + 反射设字段**，遇到 final 字段/不可变对象会失败，自定义 `TypeAdapter` 是标准解法（这也解释了为什么 Java 16+ record 在旧版 Gson 上需要适配器，Gson 2.10+ 已原生支持 record）。

## 五、流式解析：处理超大 JSON

`fromJson(String, ...)` 会把整个 JSON 读进内存。处理 GB 级 JSON（如日志导出）必须用流式：

### 1. JsonReader 流式读取（边读边处理）

```java
// 流式解析 10GB 的日志数组，内存占用恒定
try (JsonReader reader = new JsonReader(new InputStreamReader(
        Files.newInputStream(Path.of("/tmp/huge.json")), StandardCharsets.UTF_8))) {
    reader.beginArray();
    while (reader.hasNext()) {
        // 逐个读取并处理元素，不构建完整对象树
        LogEntry entry = gson.fromJson(reader, LogEntry.class);
        process(entry);
    }
    reader.endArray();
}
```

**关键**：`gson.fromJson(reader, LogEntry.class)` 只消费**当前一个 JSON 元素**，读完即释放，内存恒定 O(1)。

### 2. JsonWriter 流式写出

```java
try (JsonWriter writer = new JsonWriter(Files.newBufferedWriter(
        Path.of("/tmp/out.json"), StandardCharsets.UTF_8))) {
    writer.setIndent("  ");
    writer.beginArray();
    for (LogEntry e : queryBatch()) {   // 分批查询，不一次性加载
        gson.toJson(e, LogEntry.class, writer);
    }
    writer.endArray();
}
```

### 3. 对比：三种解析方式的取舍

| 方式 | 内存 | 性能 | 场景 |
|------|------|------|------|
| `fromJson(String)` | 整串 + 对象树 | 快 | 普通小 JSON |
| `JsonParser.parse...`（JsonElement 树） | 整棵对象树 | 中 | 需要随机访问/修改 |
| **JsonReader 流式** | **O(1)** | 最快 | 超大 JSON、日志流 |

## 六、Gson vs Jackson vs Fastjson 深度对比

| 维度 | Gson | Jackson | Fastjson |
|------|------|---------|----------|
| 出品方 | Google | FasterXML | 阿里 |
| 依赖 | **零依赖** | 核心 jackson-databind | 零依赖（有安全版本） |
| 性能 | 中 | **快**（经大量优化） | 快（曾有争议） |
| 泛型支持 | TypeToken，优秀 | TypeReference，优秀 | TypeReference |
| 默认安全性 | **高**（不做类型自动转换） | 高（需显式 enable） | 历史上有反序列化 RCE 漏洞（autoType），需升级到最新版 |
| Spring Boot 默认 | 否 | **是**（spring-boot-starter-json） | 否 |
| 不可变对象/record | 2.10+ 原生支持 | 原生支持（参数名） | 支持 |
| 维护活跃度 | 中（发布节奏慢） | 高 | 中（安全问题后整改） |

**选型建议**：

- **Spring Boot 项目**：直接用默认 Jackson，不要为统一格式再引入 Gson（配置混乱、特性重叠）；
- **Android / 工具库 / 无框架纯 Java**：Gson，零依赖 + 简单；
- **性能敏感、复杂类型系统**：Jackson（性能最好、生态最全）；
- **Fastjson**：老项目兼容可保留，**新项目不建议**——历史安全漏洞多，若用必须锁最新版本并关闭 autoType。

**面试回答模板**："选型取决于场景。Spring Boot 生态默认 Jackson 且性能最好；Gson 胜在简单零依赖、Android 友好；Fastjson 历史上出过严重反序列化漏洞，新项目不推荐。三者 API 差异不大，团队统一才是最重要的。"

## 七、Gson 常见坑与最佳实践

### 坑 1：默认不输出 null，前端拿到缺字段

前后端约定不清时，`{"a":1}` 和 `{"a":1,"b":null}` 语义不同。要么全局 `serializeNulls()`，要么用 `@SerializedName` 默认值，**团队必须统一约定**。

### 坑 2：BigDecimal 被转成 double，精度丢失

JSON 数字 `0.1 + 0.2` 经 double 中转会丢精度。方案：① 业务字段用自定义 `TypeAdapter`（如上文）；② 或配置 `setObjectToNumberStrategy(ToNumberPolicy.BIG_DECIMAL)`（Gson 2.8.9+）。

### 坑 3：日期格式不统一

`Date`/`LocalDateTime` 默认序列化是时间戳或 ISO 格式，与前端约定不一致。**全局统一注册日期适配器**，避免每处 `@JsonAdapter` 注解。

### 坑 4：循环引用（A→B→A）

默认 Gson 遇到循环引用会**栈溢出**。解法：① 用 `@Expose` 忽略回引用字段；② 自定义适配器只序列化需要的部分；③ DTO 层面避免双向引用（推荐）。

### 最佳实践清单

1. 全局**单例** `Gson`（`new Gson()` 无状态线程安全），不要每次 new；
2. 用 `GsonBuilder` 统一配置日期、null、策略，一次构建；
3. 泛型一律 `TypeToken`，禁止裸 `List.class`；
4. 超大 JSON 用 `JsonReader`/`JsonWriter` 流式；
5. 对外接口定义 DTO，不直接暴露 Entity（避免循环引用、字段泄漏）。

## 八、面试官追问环节

**Q1：TypeToken 为什么必须带 `{}` 使用？**
答：`{}` 创建匿名子类，编译器才会在**类的 Signature 属性**中写入泛型实参 `List<User>`。`TypeToken` 构造函数里 `getClass().getGenericSuperclass()` 拿到带泛型信息的父类类型。不带 `{}`（即 `new TypeToken<List<User>>()` 直接实例化）时父类泛型是类型变量 `T` 而非具体类型，运行时会抛异常。

**Q2：Gson 反序列化一个对象，默认怎么创建实例？**
答：优先找**无参构造器**（反射实例化），再逐个 set 字段（反射写字段，包括私有字段）。所以：① 无无参构造器且无自定义适配器会失败；② final 字段默认无法赋值（除非 Unsafe 路径）；③ 这就是为什么推荐 DTO 提供无参构造器、用适配器处理不可变对象。

**Q3：Gson 线程安全吗？可以全局共享吗？**
答：**线程安全**。`Gson` 实例无内部可变状态（配置在构建时冻结），可安全多线程共享，官方建议单例使用。`JsonReader`/`JsonWriter` 是单次使用、非线程安全的，各线程各自创建。

**Q4：如何让 Gson 支持 Java record？**
答：Gson 2.10+ 原生支持 record（通过 RecordComponent 反射）。旧版本需要自定义 `TypeAdapter`，或用 `ReflectiveTypeAdapterFactory` 的替代方案。若项目是 Spring Boot，更简单的是直接用 Jackson（原生支持 record）。

## 九、总结

- **TypeToken** 是 Gson 泛型的灵魂——匿名类捕获泛型、`getGenericSuperclass()` 还原类型树；
- **注解三件套**：`@SerializedName`（改名/多别名）、`@Expose`（黑白名单）、`@Since/@Until`（版本裁剪）；
- **适配器三选一**：字段级注解 > JsonSerializer（树操作）> TypeAdapter（流式、性能最佳）；
- **超大 JSON** 必须流式 `JsonReader`/`JsonWriter`，内存 O(1)；
- **选型**：Spring Boot 用 Jackson，纯 Java/Android 用 Gson，新项目慎用 Fastjson；
- **最佳实践**：单例 Gson + 统一 Builder 配置 + DTO 隔离 + 全局日期/精度适配器。

JSON 序列化是每个 Java 工程师每天都要打交道的技术，吃透 Gson 的泛型与适配器机制，你不仅能写出健壮的序列化代码，面试时也能从容应对"泛型擦除"这一灵魂拷问。
