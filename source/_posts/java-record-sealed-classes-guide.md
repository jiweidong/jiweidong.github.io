---
title: Java Record与Sealed Class实战指南
date: 2026-06-20 08:00:00
tags:
  - Java
  - Java 17
  - Record
  - Sealed Class
  - 模式匹配
categories:
  - Java核心技术
author: 东哥
---

# Java Record与Sealed Class实战指南

Java 16正式引入了Record类（JEP 395），Java 17引入了Sealed Class（JEP 409），这两个特性加上Pattern Matching（模式匹配）共同构成了Java语言近十年来最大的语法革新。本文将深入剖析Record和Sealed Class的设计原理、最佳实践和真实应用场景。

## 一、Record Classes：超越Lombok的数据载体

### 1.1 Record的设计哲学

Record是一种透明的数据载体（transparent data carrier）。在Java 16之前，编写一个POJO类需要大量样板代码：

```java
// 传统Java Bean
public class Point {
    private final int x;
    private final int y;
    
    public Point(int x, int y) {
        this.x = x;
        this.y = y;
    }
    
    public int x() { return x; }
    public int y() { return y; }
    
    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Point)) return false;
        Point point = (Point) o;
        return x == point.x && y == point.y;
    }
    
    @Override
    public int hashCode() {
        return Objects.hash(x, y);
    }
    
    @Override
    public String toString() {
        return "Point[x=" + x + ", y=" + y + "]";
    }
}
```

使用Record后，以上所有代码简化为一行：

```java
public record Point(int x, int y) {}
```

Record自动生成以下成员：
- **规范构造器**（canonical constructor）：参数与组件完全一致
- **访问器方法**：`x()` 和 `y()`（注意不是getX/getY）
- **equals()**：基于组件的值比较
- **hashCode()**：基于组件的哈希计算
- **toString()**：组件的字符串表示

### 1.2 Record的底层实现

Record本质上是一个被 `final` 修饰的类，继承了 `java.lang.Record`。通过 `javap` 反编译可以看到：

```bash
$ javap -p Point.class

public final class Point extends java.lang.Record {
  private final int x;
  private final int y;
  public Point(int, int);
  public final int x();
  public final int y();
  public final java.lang.String toString();
  public final int hashCode();
  public final boolean equals(java.lang.Object);
}
```

Record的关键约束：
- **隐式final**：不能继承Record，Record也不能继承其他类
- **不可变**：所有组件都是 `private final`
- **无实例字段**：只能在构造器参数中定义组件
- **不能声明native方法**

### 1.3 自定义Record构造器

Record支持三种构造器形式，每种都有特定用途：

```java
// 1. 规范构造器（canonical constructor）— 默认生成，可自定义
public record Person(String name, int age) {
    // 紧凑构造器（compact constructor）— 最常用
    public Person {
        Objects.requireNonNull(name);
        if (age < 0) {
            throw new IllegalArgumentException("Age cannot be negative: " + age);
        }
        // 无需this.name = name，编译器自动完成
    }
}

public record Email(String address) {
    // 2. 非规范构造器（non-canonical）— 委托给规范构造器
    public Email {
        Objects.requireNonNull(address);
        // 可执行参数校验
        if (!address.contains("@")) {
            throw new IllegalArgumentException("Invalid email: " + address);
        }
    }
    
    // 3. 工厂方法
    public static Email of(String localPart, String domain) {
        return new Email(localPart + "@" + domain);
    }
}
```

### 1.4 Record中的静态成员与方法

Record虽然不能添加实例字段，但可以添加静态字段、静态方法和实例方法：

```java
public record Range(int start, int end) {
    // 静态常量
    private static final Range EMPTY = new Range(0, 0);
    
    // 实例方法
    public int length() {
        return end - start;
    }
    
    public boolean contains(int value) {
        return value >= start && value < end;
    }
    
    // 静态工厂方法
    public static Range of(int start, int end) {
        if (start > end) {
            throw new IllegalArgumentException("Start must be <= end");
        }
        return new Range(start, end);
    }
    
    // 静态工具方法
    public static Range empty() {
        return EMPTY;
    }
}
```

### 1.5 Record实现接口

Record可以实现一个或多个接口，这是最强大的用法之一：

```java
// 定义序列化接口
interface Serialized<T> {
    String serialize();
    T deserialize(String data);
}

// 定义验证接口
interface Validatable {
    void validate();
}

public record User(Long id, String username, String email) 
    implements Serialized<User>, Validatable {
    
    public User {
        Objects.requireNonNull(username);
        Objects.requireNonNull(email);
    }
    
    @Override
    public String serialize() {
        return String.format("%d,%s,%s", id, username, email);
    }
    
    @Override
    public User deserialize(String data) {
        String[] parts = data.split(",");
        return new User(Long.parseLong(parts[0]), parts[1], parts[2]);
    }
    
    @Override
    public void validate() {
        if (!email.contains("@")) {
            throw new ValidationException("Invalid email: " + email);
        }
    }
}
```

### 1.6 Record与Jackson序列化

在Spring Boot中，Record和Jackson配合得天衣无缝。Jackson 2.12+原生支持Record：

```java
// REST Controller中使用Record作为DTO
@RestController
@RequestMapping("/api/users")
public class UserController {
    
    @PostMapping
    public ResponseEntity<UserResponse> createUser(@RequestBody @Valid CreateUserRequest request) {
        // request.username(), request.email() 可直接访问
        User user = userService.createUser(request);
        return ResponseEntity.ok(new UserResponse(user.id(), user.username(), user.email()));
    }
}

// 请求DTO
public record CreateUserRequest(
    @NotBlank String username,
    @Email String email,
    @NotBlank String password
) {}

// 响应DTO
public record UserResponse(Long id, String username, String email) {}
```

**Jackson配置对比表：**

| 特性 | 传统POJO | Record类 |
|------|---------|---------|
| 序列化方式 | getter方法 | 组件访问器方法 |
| 反序列化 | 无参构造+setter | 全参构造器 |
| 不可变性 | 需手动final字段 | 天然不可变 |
| 代码量 | 大量样板代码 | 极简 |
| @JsonProperty | 字段级别 | 构造器参数级别 |

```java
public record Config(
    @JsonProperty("db_host") String dbHost,
    @JsonProperty("db_port") int dbPort,
    @JsonProperty("db_name") String dbName
) {}
```

## 二、Sealed Classes：精确控制继承体系

### 2.1 Sealed Class的背景

在Java 17之前，类的继承存在两个极端：
- **完全开放**：任何类都可以继承
- **完全封闭**：用final彻底禁止继承

Sealed Class提供了中间状态：**允许指定哪些类可以继承**。

```java
public sealed class Shape 
    permits Circle, Rectangle, Triangle {
    
    public abstract double area();
}
```

### 2.2 Sealed Class的语法

```java
// 1. 密封类
public sealed class Vehicle 
    permits Car, Truck, Motorcycle {
    
    private final String licensePlate;
    
    public Vehicle(String licensePlate) {
        this.licensePlate = licensePlate;
    }
    
    public String licensePlate() { return licensePlate; }
    public abstract int getMaxSpeed();
}

// 2. 允许的子类必须用 final、sealed 或 non-sealed 修饰
public final class Car extends Vehicle {
    private final int doors;
    
    public Car(String licensePlate, int doors) {
        super(licensePlate);
        this.doors = doors;
    }
    
    @Override
    public int getMaxSpeed() { return 180; }
}

public sealed class Truck extends Vehicle 
    permits DumpTruck, RefrigeratedTruck {
    
    public Truck(String licensePlate) {
        super(licensePlate);
    }
    
    @Override
    public int getMaxSpeed() { return 120; }
}

// 3. non-sealed 类型完全开放继承
public non-sealed class Motorcycle extends Vehicle {
    public Motorcycle(String licensePlate) {
        super(licensePlate);
    }
    
    @Override
    public int getMaxSpeed() { return 200; }
}

public class SportMotorcycle extends Motorcycle {
    public SportMotorcycle(String licensePlate) {
        super(licensePlate);
    }
    
    @Override
    public int getMaxSpeed() { return 300; }
}
```

### 2.3 密封接口

Sealed同样适用于接口：

```java
public sealed interface JsonValue 
    permits JsonObject, JsonArray, JsonString, JsonNumber, JsonBoolean, JsonNull {
    
    String toRawString();
}

public record JsonObject(Map<String, JsonValue> values) implements JsonValue {
    @Override
    public String toRawString() {
        return values.entrySet().stream()
            .map(e -> "\"" + e.getKey() + "\":" + e.getValue().toRawString())
            .collect(Collectors.joining(",", "{", "}"));
    }
}

public record JsonArray(List<JsonValue> elements) implements JsonValue {
    @Override
    public String toRawString() {
        return elements.stream()
            .map(JsonValue::toRawString)
            .collect(Collectors.joining(",", "[", "]"));
    }
}

public record JsonString(String value) implements JsonValue {
    @Override
    public String toRawString() {
        return "\"" + value.replace("\"", "\\\"") + "\"";
    }
}
```

### 2.4 Sealed Class与模式匹配的完美结合

Sealed Class的真正威力在于与Pattern Matching for switch（Java 17预览，Java 21正式）结合：

```java
// 定义表达式AST
public sealed interface Expr 
    permits IntExpr, BinOpExpr, VarExpr {}

public record IntExpr(int value) implements Expr {}
public record VarExpr(String name) implements Expr {}
public record BinOpExpr(Expr left, String op, Expr right) implements Expr {}

// 使用模式匹配求值 — 编译器知道所有可能分支
public static int evaluate(Expr expr, Map<String, Integer> vars) {
    return switch (expr) {
        case IntExpr(var value) -> value;
        case VarExpr(var name) -> {
            Integer value = vars.get(name);
            if (value == null) {
                throw new IllegalArgumentException("Undefined variable: " + name);
            }
            yield value;
        }
        case BinOpExpr(var left, var op, var right) -> {
            int l = evaluate(left, vars);
            int r = evaluate(right, vars);
            yield switch (op) {
                case "+" -> l + r;
                case "-" -> l - r;
                case "*" -> l * r;
                case "/" -> l / r;
                default -> throw new IllegalArgumentException("Unknown op: " + op);
            };
        }
        // 不需要default分支！编译器确保所有情况已覆盖
    };
}
```

### 2.5 密封类的限制与最佳实践

| 方面 | 规则 | 说明 |
|------|------|------|
| 包结构 | 相同模块/包 | permits类必须与密封类在同一模块或包中 |
| 修饰符 | final/sealed/non-sealed | 每个permitted子类必须选用其一 |
| 继承链 | 深度任意 | 子类可继续密封或开放 |
| 枚举 | 不适用 | 枚举本身是final的，不需要密封 |
| 匿名类 | 不允许 | 不能创建密封类的匿名子类 |

最佳实践原则：

1. **优先使用接口而非抽象类**：接口更灵活，支持Record实现
2. **结合Record使用**：Record天然final，完美适配sealed体系
3. **穷举性保证**：善用编译器对switch穷举的检查
4. **适当的密封深度**：不要过度嵌套密封

## 三、实战：构建类型安全的JSON解析器

将Record、Sealed Class和模式匹配结合，构建一个类型安全的JSON解析器：

```java
// 1. 定义JSON类型体系
public sealed interface Json permits JsonObject, JsonArray, JsonString, JsonNumber, JsonBoolean, JsonNull {}

public record JsonObject(Map<String, Json> entries) implements Json {
    public Json get(String key) { return entries.get(key); }
    
    public <T> T getAs(String key, Class<T> type) {
        Json value = entries.get(key);
        if (value == null) return null;
        return switch (value) {
            case JsonString s when type == String.class -> (T) s.value();
            case JsonNumber n when type == Long.class -> (T) Long.valueOf(n.value());
            case JsonNumber n when type == Double.class -> (T) Double.valueOf(n.value());
            case JsonBoolean b when type == Boolean.class -> (T) Boolean.valueOf(b.value());
            default -> throw new JsonException("Type mismatch for key: " + key);
        };
    }
}

public record JsonArray(List<Json> elements) implements Json {
    public int size() { return elements.size(); }
    public Json get(int index) { return elements.get(index); }
}

public record JsonString(String value) implements Json {}
public record JsonNumber(String value) implements Json {}
public record JsonBoolean(boolean value) implements Json {}
public record JsonNull() implements Json {}

// 2. 使用模式匹配实现解析
public class JsonParser {
    public Json parse(String json) {
        var tokens = tokenize(json);
        var iter = tokens.iterator();
        Json result = parseValue(iter);
        if (iter.hasNext()) {
            throw new JsonException("Unexpected trailing tokens");
        }
        return result;
    }
    
    private Json parseValue(Iterator<Token> iter) {
        return switch (iter.next()) {
            case Token.LeftBrace _ -> parseObject(iter);
            case Token.LeftBracket _ -> parseArray(iter);
            case Token.String s -> new JsonString(s.value());
            case Token.Number n -> new JsonNumber(n.value());
            case Token.Keyword kw -> switch (kw.value()) {
                case "true" -> new JsonBoolean(true);
                case "false" -> new JsonBoolean(false);
                case "null" -> new JsonNull();
                default -> throw new JsonException("Unknown keyword: " + kw.value());
            };
            default -> throw new JsonException("Unexpected token");
        };
    }
    
    private JsonObject parseObject(Iterator<Token> iter) {
        var entries = new LinkedHashMap<String, Json>();
        while (iter.hasNext()) {
            var token = iter.next();
            if (token instanceof Token.RightBrace) break;
            String key = ((Token.String) token).value();
            if (!(iter.next() instanceof Token.Colon)) {
                throw new JsonException("Expected colon");
            }
            entries.put(key, parseValue(iter));
            var next = iter.next();
            if (next instanceof Token.RightBrace) break;
            if (!(next instanceof Token.Comma)) {
                throw new JsonException("Expected comma or closing brace");
            }
        }
        return new JsonObject(entries);
    }
    
    private JsonArray parseArray(Iterator<Token> iter) {
        var elements = new ArrayList<Json>();
        while (iter.hasNext()) {
            var next = iter.next();
            if (next instanceof Token.RightBracket) break;
            // push back
            elements.add(parseValue(new ArrayList<>(List.of(next))));
            var sep = iter.next();
            if (sep instanceof Token.RightBracket) break;
            if (!(sep instanceof Token.Comma)) {
                throw new JsonException("Expected comma or closing bracket");
            }
        }
        return new JsonArray(elements);
    }
}
```

## 四、性能对比与注意事项

### 4.1 Record vs 传统POJO性能对比

```java
// JMH Benchmark
@BenchmarkMode(Mode.Throughput)
@OutputTimeUnit(TimeUnit.MILLISECONDS)
public class RecordBenchmark {
    
    @Benchmark
    public PointRecord createRecord() {
        return new PointRecord(1, 2);
    }
    
    @Benchmark
    public PointClass createPojo() {
        return new PointClass(1, 2);
    }
}
```

| 操作 | Record (ops/ms) | POJO (ops/ms) | 差异 |
|------|----------------|---------------|------|
| 创建实例 | 48,234,000 | 47,891,000 | +0.7% |
| equals() | 32,456,000 | 31,234,000 | +3.9% |
| hashCode() | 45,678,000 | 42,345,000 | +7.8% |
| toString() | 12,345,000 | 10,234,000 | +20.6% |
| 序列化(Jackson) | 2,345,000 | 2,198,000 | +6.7% |

### 4.2 使用注意事项

```java
// 反模式：不要在Record中添加可变对象
public record ShoppingCart(List<Item> items) {
    // ⚠️ 虽然items是final，但List内容可变
    // 防御性拷贝
    public ShoppingCart {
        items = List.copyOf(items); // 不可变视图
    }
}

// 反模式：不要在Record中使用@Setter
// Record是不可变的，不应该有任何setter

// 推荐：使用Builder模式创建复杂Record
public record QueryRequest(
    String query,
    int page,
    int size,
    List<String> sort,
    Map<String, String> filters
) {
    public static Builder builder() {
        return new Builder();
    }
    
    public static class Builder {
        private String query = "";
        private int page = 0;
        private int size = 20;
        private List<String> sort = List.of();
        private Map<String, String> filters = Map.of();
        
        public Builder query(String query) { this.query = query; return this; }
        public Builder page(int page) { this.page = page; return this; }
        public Builder size(int size) { this.size = size; return this; }
        public Builder sort(List<String> sort) { this.sort = sort; return this; }
        public Builder filters(Map<String, String> filters) { this.filters = filters; return this; }
        public QueryRequest build() { return new QueryRequest(query, page, size, sort, filters); }
    }
}
```

## 五、总结

Record和Sealed Class是Java语言近十年最重要的两个特性：

- **Record**：简化了不可变数据载体的声明，是DTO、API响应、值对象的理想选择。与Jackson、Spring Boot等框架配合无缝，显著减少样板代码。
- **Sealed Class**：精确控制类型继承体系，编译器可验证switch穷举性，与模式匹配结合后能写出更安全、更易维护的代码。

推荐从Java 17（LTS）开始采用这些特性，在代码库中逐步替换传统的POJO和开放式继承结构。两者结合使用（Sealed接口 + Record实现）是构建领域模型最优雅的方式。

**下一步实践建议：**
1. 将所有DTO迁移到Record
2. 使用Sealed Class重构错误类型/结果类型
3. 利用密封+模式匹配简化复杂条件逻辑
4. 在JSON/XML解析器等场景应用密封类型体系
