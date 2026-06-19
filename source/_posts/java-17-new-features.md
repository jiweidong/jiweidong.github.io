---
title: Java 17 新特性详解：从密封类到虚拟线程的演进之路
date: 2026-06-17 08:00:00
author: 东哥
categories:
  - Java
  - 新特性
tags:
  - Java 17
  - Records
  - Sealed Classes
  - Pattern Matching
  - LTS
  - 迁移
cover: /images/java17-banner.png
---

## 一、Java 17：现代化 Java 的里程碑

2021 年 9 月发布的 Java 17 是继 Java 11 之后的第二个 LTS（长期支持）版本，也是 Java 现代化进程中的关键转折点。它不仅带来了丰富的语言新特性，更为后续的虚拟线程（Project Loom）、模式匹配（Project Amber）等划时代功能铺平了道路。

本文将深入解析 Java 17 的核心新特性，涵盖语法改进、API 增强和性能优化，并提供从 Java 11 迁移的实战指南。

### Java 版本演进时间线

| 版本 | 发布时间 | 类型 | 核心特性 |
|------|----------|------|----------|
| Java 11 | 2018.09 | LTS | 模块化、HTTP Client、ZGC |
| Java 12-16 | 2019-2021 | 短期 | Switch 表达式、Text Blocks、Records 预览 |
| **Java 17** | **2021.09** | **LTS** | **密封类、模式匹配、Records 转正** |
| Java 21 | 2023.09 | LTS | 虚拟线程、Record Patterns、Switch 模式匹配转正 |

## 二、Records（记录类型）

Records 在 Java 14 中首次预览，Java 16 中转正，Java 17 中稳定使用。它本质上是 **不可变数据载体** 的语法糖，大幅减少了样板代码。

### 2.1 基本用法

```java
// 传统方式
public class Point {
    private final int x;
    private final int y;
    
    public Point(int x, int y) {
        this.x = x;
        this.y = y;
    }
    
    public int getX() { return x; }
    public int getY() { return y; }
    
    @Override
    public boolean equals(Object o) { /* 30行代码 */ }
    
    @Override
    public int hashCode() { /* 10行代码 */ }
    
    @Override
    public String toString() { /* 5行代码 */ }
}

// Record 方式 — 一行搞定！
public record Point(int x, int y) {}
```

Record 自动生成：
- 所有字段的 `private final` 和 canonical 构造方法
- `accessor` 方法（注意不是 `getX()` 而是 `x()`）
- `equals()`、`hashCode()`、`toString()`

### 2.2 自定义构造方法

```java
public record Range(int start, int end) {
    // 紧凑构造方法 — 参数校验
    public Range {
        if (start > end) {
            throw new IllegalArgumentException("start must be <= end");
        }
    }
    
    // 静态工厂方法
    public static Range of(int start, int end) {
        return new Range(start, end);
    }
    
    // 实例方法
    public boolean contains(int value) {
        return value >= start && value <= end;
    }
}

// 使用
var range = new Range(1, 10);
System.out.println(range.start());  // 1
System.out.println(range.contains(5));  // true
```

### 2.3 与注解框架集成

Records 与 Lombok、Jackson、Spring 等框架完美协作：

```java
// Jackson 序列化
@JsonIgnoreProperties(ignoreUnknown = true)
public record UserDto(
    @JsonProperty("user_id") Long userId,
    @NotBlank String name,
    @Email String email,
    @JsonFormat(pattern = "yyyy-MM-dd") LocalDate createdAt
) {}

// 与 Spring 结合
@RestController
public class UserController {
    @PostMapping("/users")
    public UserDto createUser(@Valid @RequestBody CreateUserRequest request) {
        // request.name(), request.email() ...
    }
}

public record CreateUserRequest(
    @NotBlank String name,
    @Email String email,
    @Min(18) int age
) {}
```

### 2.4 Records 的限制

| 特性 | 支持情况 |
|------|----------|
| 继承 | ❌ 不能继承其他类（隐式继承 `java.lang.Record`）|
| 被继承 | ❌ 是 final 类，不能被继承 |
| 实例字段 | ❌ 只能声明 canonical 字段，不能加额外字段 |
| 静态字段/方法 | ✅ 支持 |
| 泛型 | ✅ 支持：`record Pair<T, U>(T first, U second) {}` |
| 实现接口 | ✅ 支持 |
| 注解 | ✅ 支持 |

## 三、Sealed Classes（密封类）

密封类是 Java 17 正式引入的重要特性，允许类或接口明确声明哪些子类可以继承或实现它。

### 3.1 为什么需要密封类

传统继承体系的问题：

```java
// 问题：任何类都能继承 Shape，破坏设计意图
public abstract class Shape {}
public class Circle extends Shape {}  // 期望
public class EvilShape extends Shape {}  // 不期望但不阻止
```

### 3.2 密封类基础用法

```java
// 声明密封类，指定允许的子类
public sealed class Shape permits Circle, Rectangle, Triangle {}

// 子类必须用 final、sealed 或 non-sealed 修饰
public final class Circle extends Shape {
    private final double radius;
    public Circle(double radius) { this.radius = radius; }
    public double area() { return Math.PI * radius * radius; }
}

public sealed class Rectangle extends Shape permits Square {
    private final double width, height;
    public Rectangle(double width, double height) {
        this.width = width;
        this.height = height;
    }
}

// 子类的子类必须完整覆盖密封声明
public final class Square extends Rectangle {
    public Square(double side) { super(side, side); }
}

public non-sealed class Triangle extends Shape {}  // 放开口子
```

### 3.3 密封接口

```java
public sealed interface JsonValue 
    permits JsonString, JsonNumber, JsonObject, JsonArray, JsonNull {}

public record JsonString(String value) implements JsonValue {}
public record JsonNumber(double value) implements JsonValue {}
public record JsonObject(Map<String, JsonValue> values) implements JsonValue {}
public record JsonArray(List<JsonValue> values) implements JsonValue {}
public record JsonNull() implements JsonValue {}
```

### 3.4 密封类与 Pattern Matching

密封类与模式匹配是天作之合，编译器可以验证 switch 的穷尽性：

```java
// 密封类 + 模式匹配
public sealed interface Vehicle permits Car, Truck, Motorcycle {}
public record Car(String brand, int doors) implements Vehicle {}
public record Truck(String brand, double capacity) implements Vehicle {}
public record Motorcycle(String brand, boolean hasSidecar) implements Vehicle {}

// Java 17 增强版 switch + 模式匹配（预览）
public static String describeVehicle(Vehicle v) {
    return switch (v) {
        case Car car -> "汽车：品牌=" + car.brand() + ", 门数=" + car.doors();
        case Truck truck -> "卡车：品牌=" + truck.brand() + ", 载重=" + truck.capacity();
        case Motorcycle bike -> "摩托车：品牌=" + bike.brand() + 
                                (bike.hasSidecar() ? "（带挎斗）" : "");
    };
    // ✅ 编译器知道已穷尽所有分支，不需要 default
}
```

### 3.5 设计模式中的应用

```java
// 状态模式 + 密封类
public sealed interface OrderState 
    permits PendingState, PaidState, ShippedState, DeliveredState, CancelledState {}

public record PendingState(long createTime) implements OrderState {}
public record PaidState(long payTime, String payMethod) implements OrderState {}
public record ShippedState(String logisticsNo, String carrier) implements OrderState {}
public record DeliveredState(long deliverTime) implements OrderState {}
public record CancelledState(String reason, long cancelTime) implements OrderState {}
```

## 四、Pattern Matching for switch

Java 17 将 switch 的模式匹配功能提升为预览特性（Java 21 转正），这是 Java 多年来对 switch 做的最激动人心的改进。

### 4.1 类型匹配

```java
// 传统方式 — instanceof + 强制转换
public static String format(Object obj) {
    if (obj instanceof Integer) {
        int i = (Integer) obj;
        return String.format("整数：%d", i);
    } else if (obj instanceof String) {
        String s = (String) obj;
        return "字符串：" + s;
    }
    return "未知类型";
}

// Java 17 方式 — switch + 模式匹配
public static String format(Object obj) {
    return switch (obj) {
        case Integer i -> String.format("整数：%d", i);
        case String s -> "字符串：" + s;
        case Long l && l > 100 -> "大长整数：" + l;  // 守卫模式（guarded pattern）
        case null -> "null值";  // 直接处理 null
        default -> "未知类型";
    };
}
```

### 4.2 守卫模式（Guarded Patterns）

```java
public static String processOrder(Order order) {
    return switch (order) {
        case Order o && o.amount() > 10000 -> "大额订单，需审核";
        case Order o && o.status().equals("PAID") -> "已支付订单";
        case Order o && o.status().equals("PENDING") -> "待处理订单";
        case null -> "订单为空";
        default -> "其他状态";
    };
}
```

### 4.3 穷尽性检查

当 switch 作用于密封类或枚举时，编译器自动检查所有分支是否覆盖：

```java
public enum Color { RED, GREEN, BLUE }

// 不完整 — 编译警告
String label = switch (color) {
    case RED -> "红色";
    case GREEN -> "绿色";
    // 缺少 BLUE ❌
};

// ✅ 完整覆盖
String label = switch (color) {
    case RED -> "红色";
    case GREEN -> "绿色";
    case BLUE -> "蓝色";
};
```

## 五、Text Blocks（文本块）

Text Blocks 在 Java 13 中预览，Java 14 转正，Java 17 中成熟使用。

### 5.1 基本用法

```java
// 传统方式：各种转义和拼接
String json = "{\n" +
              "  \"name\": \"Alice\",\n" +
              "  \"age\": 30,\n" +
              "  \"email\": \"alice@example.com\"\n" +
              "}";

// Text Block：直觉化、可读性极强
String json = """
    {
      "name": "Alice",
      "age": 30,
      "email": "alice@example.com"
    }
    """;
```

### 5.2 常见应用场景

```java
// SQL 查询
String query = """
    SELECT u.id, u.name, o.total_amount
    FROM users u
    JOIN orders o ON u.id = o.user_id
    WHERE o.status = 'PAID'
      AND o.created_at >= :startDate
    ORDER BY o.total_amount DESC
    """;

// HTML 模板
String html = """
    <!DOCTYPE html>
    <html>
      <head>
        <title>%s</title>
      </head>
      <body>
        <h1>欢迎，%s！</h1>
        <p>您的订单号：%s</p>
      </body>
    </html>
    """.formatted(title, userName, orderId);

// 正则表达式（不再双重转义）
String regex = """
    ^(?<protocol>https?)://
    (?<host>[^:/]+)
    (?::(?<port>\\d+))?
    (?<path>/.*)?$
    """;
```

### 5.3 缩进与空格处理

```java
// 编译器自动去除公共前导空白（左侧对齐）
String block = """
        第一行
          第二行（多缩进2格）
        第三行
    """;
// 输出：
// 第一行
//   第二行（多缩进2格）
// 第三行

// 使用 stripIndent() 和 translateEscapes()
String raw = block.stripIndent();  // 手动去除缩进
String escaped = "line1\\nline2".translateEscapes();  // 转义序列解释
```

## 六、增强的 NullPointerException

Java 14 起，NPE 错误信息会精确指出哪个变量为 null：

```java
// 传统 NPE：只知道哪一行，不知道哪个变量为 null
z.getA().getB().getC();  
// Exception in thread "main" java.lang.NullPointerException
//     at App.main(App.java:5)

// Java 17 NPE：精确定位
z.getA().getB().getC();
// Exception in thread "main" java.lang.NullPointerException:
//   Cannot invoke "C.getSomething()" because the return value of "B.getC()" is null
//     at App.main(App.java:5)
```

## 七、新 API 与性能改进

### 7.1 java.time 增强

```java
// 时区偏移量格式化
DateTimeFormatter formatter = DateTimeFormatter
    .ofPattern("yyyy-MM-dd HH:mm:ss[XXX]");
System.out.println(formatter.format(ZonedDateTime.now()));
// 2026-06-17 08:00:00+08:00

// DayOfWeek 新增方法
DayOfWeek dow = DayOfWeek.of(3);  // WEDNESDAY
System.out.println(dow.getDisplayName(TextStyle.FULL, Locale.CHINA));  // 星期三
```

### 7.2 Stream API 改进

```java
// toList() — 直接转不可变列表
List<String> names = stream
    .map(User::name)
    .filter(n -> n.startsWith("张"))
    .toList();  // Java 16+，无需 .collect(Collectors.toList())

// Stream.mapMulti — 扁平化替代 flatMap
Stream.of("1,2,3", "4,5,6")
    .mapMulti((line, consumer) -> {
        for (String s : line.split(",")) {
            consumer.accept(Integer.parseInt(s));
        }
    })
    .forEach(System.out::println);
```

### 7.3 新工具方法

```java
// HexFormat — 二进制与十六进制互转
HexFormat hex = HexFormat.of();
byte[] bytes = hex.parseHex("4a617661203137");  // "Java 17"
String hexStr = hex.formatHex("Hello".getBytes());
System.out.println(hexStr);  // 48656c6c6f

HexFormat hexPretty = HexFormat.ofDelimiter(" ").withUpperCase();
System.out.println(hexPretty.formatHex("ABC".getBytes()));  // 41 42 43

// 开关表达式
Boolean result = switch (flag) {
    case true -> Boolean.TRUE;
    case false -> Boolean.FALSE;
};
```

### 7.4 性能优化

| 优化项 | 说明 | 影响 |
|--------|------|------|
| ZGC 改进 | 支持并发类卸载、分代模式 | 降低 Full GC 延迟 |
| 偏置锁移除 | 移除偏向锁，简化同步实现 | 减少锁竞争复杂带来的开销 |
| 即时编译增强 | 内联优化、逃逸分析改进 | 微基准测试提升 5-15% |
| 向量化 API | JEP 338：Vector API（孵化器） | SIMD 加速数值计算 |
| 多线程 GC | G1/Parallel GC 并发性改进 | 降低 GC 停顿时间 |

## 八、从 Java 11 迁移到 Java 17

### 8.1 迁移检查清单

```markdown
- [ ] 确认所有依赖库兼容 Java 17
- [ ] 检查模块化（module-info.java）兼容性
- [ ] 替换已被移除的 API（如 finalize()、Pack200）
- [ ] 更新构建工具（Maven 3.8+ / Gradle 7.3+）
- [ ] 更新 IDE（IntelliJ IDEA 2021.2+）
- [ ] 处理废弃 API 警告（-Xlint:deprecation）
- [ ] 运行全量测试套件
```

### 8.2 被移除或标记为移除的 API

| 旧 API | 替代方案 | 移除版本 |
|--------|----------|----------|
| `finalize()` | `Cleaner`/`AutoCloseable` | Java 18 |
| `SecurityManager` | 无直接替代 | Java 17 标记废弃 |
| `Pack200` | 无 | Java 14 |
| `Thread.destroy()` | 无 | Java 11 |
| Nashorn JavaScript Engine | GraalVM | Java 15 |
| RMI Activation | 无 | Java 15 |

### 8.3 Maven 构建配置

```xml
<properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
    <java.version>17</java.version>
</properties>

<!-- 启用预览特性（如有需要） -->
<plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-compiler-plugin</artifactId>
    <version>3.11.0</version>
    <configuration>
        <source>17</source>
        <target>17</target>
        <compilerArgs>
            <arg>--enable-preview</arg>
        </compilerArgs>
    </configuration>
</plugin>
```

### 8.4 Docker 镜像

```dockerfile
# 多阶段构建
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn package -DskipTests

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar

# JVM 优化参数
ENV JAVA_OPTS="\
    -XX:+UseZGC \
    -XX:MaxGCPauseMillis=10 \
    -Xms2g -Xmx2g \
    -XX:+AlwaysPreTouch \
    -XX:+HeapDumpOnOutOfMemoryError \
    -Dfile.encoding=UTF-8"

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

## 九、展望未来：从 Java 17 到 21+

Java 17 奠定了通往未来版本的基础，许多在 Java 21（下一个 LTS，2023 年发布）中转正的特性在 Java 17 中已经以预览形式存在：

| Java 17 预览特性 | Java 21 状态 | 说明 |
|------------------|--------------|------|
| 模式匹配 switch | ✅ 转正 | 永久启用 |
| Record Patterns | ✅ 转正 | 嵌套解构 |
| 虚拟线程 | ✅ 转正 | Project Loom 正式落地 |
| 结构化并发 | 孵化器阶段 | 简化并发编程 |
| 作用域值 | 孵化器阶段 | 轻量级线程局部变量 |

### 从 Records 到 Record Patterns

```java
// Java 17 基础用法
public record Address(String city, String street) {}
public record Person(String name, Address address) {}

// 嵌套解构（Java 21 正式支持）
String cityInfo = switch (person) {
    case Person(var name, Address(var city, _)) -> name + "住在" + city;
    // _ 表示忽略该字段
};
```

### 虚拟线程预览（Java 19+）

虽然虚拟线程在 Java 17 中只是预览，但了解其概念有助于规划架构演进：

```java
// 在 Java 17 中通过 --enable-preview 使用（预览）
// 或直接在 Java 21 中使用

// 大量轻量级虚拟线程
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    IntStream.range(0, 10000).forEach(i -> {
        executor.submit(() -> {
            Thread.sleep(1000);
            return i;
        });
    });
}  // 10,000 个虚拟线程，开销远小于操作系统线程
```

## 十、总结

Java 17 是 Java 语言演进历程中不可忽视的 LTS 版本。它通过 Records、密封类、模式匹配等特性，让 Java 代码更加 **简洁、安全、富有表达力**。如果说 Java 8 让 Lambda 走进开发者视野，Java 11 拉响了模块化的号角，那么 Java 17 则是 Java 真正走向现代化语言的关键一跃。

**迁移建议**：如果你的项目仍停留在 Java 8 或 11，果断升级到 Java 17 是性价比最高的选择——既获得了大量语法糖和性能改进，又为后续拥抱虚拟线程等划时代特性铺平了道路。
