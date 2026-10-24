---
title: 【MyBatis 源码】TypeHandler 深度解析：注册查找链、自定义枚举/JSON 映射与踩坑清单
date: 2026-10-24 08:10:00
tags:
  - Java
  - MyBatis
  - 源码
  - 类型转换
  - 持久层
categories:
  - Java 深挖
author: 东哥
---

# 【MyBatis 源码】TypeHandler 深度解析：注册查找链、自定义枚举/JSON 映射与踩坑清单

## 前言

几乎每个用 MyBatis 的项目都会遇到这几件事：

- 枚举字段存进库成了 `0/1/2` 或者 `ORDINAL` 序号，产品改一次枚举顺序，历史数据全错位；
- 一个 `List<String>` 想直接存成 JSON 列，结果报 `Cannot convert String to List`；
- 手机号、身份证要加密落库，在 Service 层手动加解密，漏一个字段就是安全事故；
- 明明写了 `typeHandler`，就是不生效，日志里全是默认的 `StringTypeHandler`。

这些问题的共同答案是同一个东西：**`TypeHandler`**。它是 MyBatis 里「Java 类型 ↔ JDBC 类型」的唯一转换入口，但绝大多数人只在报错时才想起它。

这篇文章从它在 MyBatis 中的位置讲起，把 `TypeHandlerRegistry` 的查找链、自定义枚举/JSON/加密处理器的落地、Spring Boot 下的注册方式、以及 8 个高频踩坑一次说清。

---

## 一、TypeHandler 在 MyBatis 执行流程中的位置

MyBatis 的四大核心组件：`Executor` → `StatementHandler` → `ParameterHandler` / `ResultSetHandler`。`TypeHandler` 挂在后两个身上：

```
                    ┌─────────────────────┐
                    │      Executor       │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │  StatementHandler   │
                    └────┬───────────┬────┘
                         ▼           ▼
          ┌──────────────────┐  ┌──────────────────┐
          │ ParameterHandler │  │ ResultSetHandler │
          └────────┬─────────┘  └────────┬─────────┘
                   ▼                     ▼
            setParameter()         getResult()
                   │                     │
                   └────────┬────────────┘
                            ▼
                   ┌──────────────────┐
                   │   TypeHandler    │  ← 唯一转换点
                   └──────────────────┘
```

- **写方向**：`ParameterHandler.setParameters()` 从 `ParameterMapping` 里取出 `typeHandler`，调用 `setParameter(ps, i, value, jdbcType)`；
- **读方向**：`ResultSetHandler` 根据 `ResultMap` 的 `typeHandler`，调用 `getResult(rs, columnName)`。

也就是说：**只要这个字段要经过 JDBC，就一定会经过 TypeHandler**。这是做统一加解密、统一脱敏、统一类型转换的最佳切面。

---

## 二、接口与模板方法

`TypeHandler<T>` 只有两个方法：

```java
public interface TypeHandler<T> {
    void setParameter(PreparedStatement ps, int i, T parameter, JdbcType jdbcType) throws SQLException;
    T getResult(ResultSet rs, String columnName) throws SQLException;
    T getResult(ResultSet rs, int columnIndex) throws SQLException;
    T getResult(CallableStatement cs, int columnIndex) throws SQLException;
}
```

实际开发几乎不直接实现接口，而是继承 `BaseTypeHandler<T>`，它用模板方法把「空值处理」和「异常包装」都做好了：

```java
public abstract class BaseTypeHandler<T> extends TypeReference<T> implements TypeHandler<T> {

    @Override
    public void setParameter(PreparedStatement ps, int i, T parameter, JdbcType jdbcType) throws SQLException {
        if (parameter == null) {
            if (jdbcType == null) {
                throw new TypeException("JDBC requires that the JdbcType must be specified for all nullable parameters.");
            }
            try {
                ps.setNull(i, jdbcType.TYPE_CODE);   // ← 坑 1 的来源
            } catch (SQLException e) {
                throw new TypeException("Error setting null for parameter #" + i + " ...", e);
            }
        } else {
            try {
                setNonNullParameter(ps, i, parameter, jdbcType);
            } catch (Exception e) {
                throw new TypeException("Error setting non null for parameter #" + i + " ...", e);
            }
        }
    }

    // 子类只需实现这四个
    public abstract void setNonNullParameter(PreparedStatement ps, int i, T parameter, JdbcType jdbcType) throws SQLException;
    public abstract T getNullableResult(ResultSet rs, String columnName) throws SQLException;
    public abstract T getNullableResult(ResultSet rs, int columnIndex) throws SQLException;
    public abstract T getNullableResult(CallableStatement cs, int columnIndex) throws SQLException;
}
```

注意 `TypeReference<T>`：它通过反射读取泛型父类的实际类型参数，**这就是「你的 Handler 到底处理哪个 Java 类型」的来源**。所以自定义 Handler 必须是「具体的类」，不能是裸泛型。

---

## 三、注册与查找：TypeHandlerRegistry 的优先级链

`TypeHandlerRegistry` 内部是三个 `Map`：

```java
private final Map<JdbcType, TypeHandler<?>> jdbcTypeHandlerMap = new EnumMap<>(JdbcType.class);
private final Map<Type, Map<JdbcType, TypeHandler<?>>> typeHandlerMap = new ConcurrentHashMap<>();
private final Map<Class<?>, TypeHandler<?>> allTypeHandlersMap = new HashMap<>();
```

查找逻辑（`getTypeHandler`，已简化）：

```java
private <T> TypeHandler<T> getTypeHandler(Type type, JdbcType jdbcType, boolean searchSuperTypes) {
    Map<JdbcType, TypeHandler<?>> jdbcHandlerMap = getJdbcHandlerMap(type);
    TypeHandler<?> handler = null;
    if (jdbcHandlerMap != null) {
        handler = jdbcHandlerMap.get(jdbcType);        // 1. (javaType, jdbcType) 精确匹配
        if (handler == null) {
            handler = jdbcHandlerMap.get(null);        // 2. (javaType, null) 兜底
        }
        if (handler == null && jdbcType != null) {
            handler = getJdbcHandlerMap(...);          // 3. jdbcType 单维度
        }
    }
    ...
}
```

再看注册：

```java
public void register(Class<?> javaType, JdbcType jdbcType, TypeHandler<?> handler) {
    if (jdbcType == null) {
        // 注册成 (javaType, null)，作为该类型的默认处理器
        typeHandlerMap.computeIfAbsent(javaType, k -> new ConcurrentHashMap<>()).put(null, handler);
    } else {
        typeHandlerMap.computeIfAbsent(javaType, k -> new ConcurrentHashMap<>()).put(jdbcType, handler);
    }
    allTypeHandlersMap.put(handler.getClass(), handler);
}
```

**查找优先级（务必记住）：**

| 优先级 | 匹配 key | 说明 |
|---|---|---|
| 1 | `(javaType, jdbcType)` | 最精确，resultMap 里显式写 `jdbcType` 才命中 |
| 2 | `(javaType, null)` | 该类型的默认处理器，**自定义 Handler 通常落在这里** |
| 3 | 父类 / 接口 | `searchSuperTypes=true` 时向上找（`Enum`、`Object` 等） |
| 4 | `ObjectTypeHandler` | 最终兜底，直接 `ps.setObject()` |

关键点：**自定义 Handler 想「自动生效」，就要注册成 `(javaType, null)`。** 如果注册时指定了 `jdbcType`，那么只有显式声明了该 `jdbcType` 的参数/字段才会用它。

`register` 的重载里有一个容易忽略的分支：

```java
public void register(Class<?> javaType, Class<? extends TypeHandler<?>> typeHandlerClass) {
    TypeHandler<?> handler = resolveTypeHandler(javaType, null, typeHandlerClass);
    register(javaType, null, handler);   // ← 自动解析 @MappedTypes / @MappedJdbcTypes
}
```

`resolveTypeHandler` 会读 `@MappedTypes` 和 `@MappedJdbcTypes`：

```java
@MappedTypes(OrderStatus.class)
@MappedJdbcTypes({JdbcType.TINYINT, JdbcType.INTEGER})
public class OrderStatusTypeHandler extends BaseTypeHandler<OrderStatus> { ... }
```

**没有 `@MappedTypes` 时，`javaType` 就靠 `TypeReference` 反射拿；但一旦你写了泛型基类（比如 `AbstractEnumTypeHandler<E>`），反射拿到的是 `E` 这个 TypeVariable，注册就会失败或注册到错误类型上。这是坑 5。**

---

## 四、实战 1：通用枚举处理器（告别 ORDINAL）

### 4.1 问题现场

```java
public enum OrderStatus {
    CREATED,      // 0
    PAID,         // 1
    SHIPPED,      // 2
    COMPLETED;    // 3
}
```

默认情况下，MyBatis 对枚举有两个内置 Handler：

- `EnumTypeHandler`：存 **name 字符串**（默认）；
- `EnumOrdinalTypeHandler`：存 **ordinal 序号**。

但业务上我们往往要存自定义的 code（比如 `10/20/30`，或者和外部系统对齐的 `NEW/PAID`）。而且一旦用 ordinal，**枚举里插入一个新值，历史数据的含义就整体错位**——这是典型的「上线三年后才炸」的坑。

### 4.2 定义标记接口

```java
public interface CodedEnum<E extends Enum<E>> {
    int getCode();
}
```

### 4.3 通用 Handler

```java
public class CodedEnumTypeHandler<E extends Enum<E> & CodedEnum<E>>
        extends BaseTypeHandler<E> {

    private final Class<E> type;
    private final Map<Integer, E> codeMap = new HashMap<>();

    public CodedEnumTypeHandler(Class<E> type) {
        if (type == null) throw new IllegalArgumentException("Type argument cannot be null");
        this.type = type;
        for (E e : type.getEnumConstants()) {
            codeMap.put(e.getCode(), e);
        }
    }

    @Override
    public void setNonNullParameter(PreparedStatement ps, int i, E parameter, JdbcType jdbcType)
            throws SQLException {
        ps.setInt(i, parameter.getCode());
    }

    @Override
    public E getNullableResult(ResultSet rs, String columnName) throws SQLException {
        int code = rs.getInt(columnName);
        return rs.wasNull() ? null : convert(code);
    }

    @Override
    public E getNullableResult(ResultSet rs, int columnIndex) throws SQLException {
        int code = rs.getInt(columnIndex);
        return rs.wasNull() ? null : convert(code);
    }

    @Override
    public E getNullableResult(CallableStatement cs, int columnIndex) throws SQLException {
        int code = cs.getInt(columnIndex);
        return cs.wasNull() ? null : convert(code);
    }

    private E convert(int code) {
        E e = codeMap.get(code);
        if (e == null) throw new IllegalArgumentException("未知枚举 code: " + code + " for " + type.getName());
        return e;
    }
}
```

**注意 `rs.wasNull()`**：`getInt` 遇到 NULL 返回 `0`，不判断就会把 NULL 变成 code=0 的枚举值。这是 TypeHandler 里最经典的 bug。

### 4.4 注册

```java
@Configuration
public class MyBatisConfig {
    @Bean
    public ConfigurationCustomizer typeHandlerCustomizer() {
        return configuration -> {
            TypeHandlerRegistry registry = configuration.getTypeHandlerRegistry();
            for (OrderStatus s : OrderStatus.values()) { /* 只是为了演示 */ }
            registry.register(OrderStatus.class, new CodedEnumTypeHandler<>(OrderStatus.class));
        };
    }
}
```

或者更省事：**让 Handler 无参可构造，然后配置包里扫描**。

```yaml
mybatis:
  type-handlers-package: com.example.mybatis.handler
```

MyBatis 扫描到带 `@MappedTypes` 的 Handler 会自动注册；没有 `@MappedTypes` 的，会用反射从 `TypeReference` 解析，解析不出来就打日志跳过（**静默跳过，不报错——这是坑 5**）。

---

## 五、实战 2：JSON 字段处理器

MySQL 5.7+ / PostgreSQL 的 `JSON` 列，或者干脆用 `VARCHAR` 存 JSON，都需要一个 `List<String>` / `Map` 的 Handler。

```java
@MappedTypes({List.class, Map.class})
@MappedJdbcTypes(JdbcType.VARCHAR)
public class JsonTypeHandler<T> extends BaseTypeHandler<T> {

    private static final ObjectMapper MAPPER = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private final Class<T> clazz;

    public JsonTypeHandler(Class<T> clazz) {
        this.clazz = clazz;
    }

    @Override
    public void setNonNullParameter(PreparedStatement ps, int i, T parameter, JdbcType jdbcType)
            throws SQLException {
        try {
            ps.setString(i, MAPPER.writeValueAsString(parameter));
        } catch (JsonProcessingException e) {
            throw new SQLException("序列化 JSON 失败: " + parameter, e);
        }
    }

    @Override
    public T getNullableResult(ResultSet rs, String columnName) throws SQLException {
        return parse(rs.getString(columnName));
    }

    @Override
    public T getNullableResult(ResultSet rs, int columnIndex) throws SQLException {
        return parse(rs.getString(columnIndex));
    }

    @Override
    public T getNullableResult(CallableStatement cs, int columnIndex) throws SQLException {
        return parse(cs.getString(columnIndex));
    }

    private T parse(String json) throws SQLException {
        if (json == null || json.isBlank()) return null;
        try {
            return MAPPER.readValue(json, MAPPER.getTypeFactory().constructType(clazz));
        } catch (IOException e) {
            throw new SQLException("解析 JSON 失败: " + json, e);
        }
    }
}
```

**泛型 Handler 的致命问题**：`List<String>` 和 `List<Order>` 都是 `List`，`@MappedTypes(List.class)` 只能注册一个 Handler，无法区分元素类型。所以真实项目里通常有两条路：

1. **为每种元素类型写一个具体子类**（笨但可靠）；
2. **用 MyBatis-Plus 的 `JacksonTypeHandler`**：在 `@TableField(typeHandler = JacksonTypeHandler.class)` 上显式指定，同时实体类加 `@TableName(autoResultMap = true)`：

```java
@TableName(value = "t_order", autoResultMap = true)   // ← 必须有，否则查询不生效
public class Order {
    @TableField(typeHandler = JacksonTypeHandler.class)
    private List<String> tags;
}
```

`autoResultMap = true` 是关键：它让 MyBatis-Plus 自动生成一个带 `typeHandler` 的 `resultMap`。**忘了它，写入是 JSON、读取还是报错。**

---

## 六、实战 3：字段加密处理器（以及它的边界）

手机号、身份证加密落库，用 Handler 做是最省事的：

```java
@MappedTypes(String.class)
@MappedJdbcTypes(JdbcType.VARCHAR)
public class EncryptTypeHandler extends BaseTypeHandler<String> {

    private static final AesGcm CIPHER = AesGcm.fromKey(...);

    @Override
    public void setNonNullParameter(PreparedStatement ps, int i, String parameter, JdbcType jdbcType)
            throws SQLException {
        ps.setString(i, CIPHER.encrypt(parameter));
    }

    @Override
    public String getNullableResult(ResultSet rs, String columnName) throws SQLException {
        return decrypt(rs.getString(columnName));
    }
    // 其余两个省略

    private String decrypt(String cipherText) {
        if (cipherText == null || cipherText.isEmpty()) return null;
        return CIPHER.decrypt(cipherText);
    }
}
```

**但请注意它的三个边界，否则必然翻车：**

| 场景 | 结果 | 解决方案 |
|---|---|---|
| `WHERE phone = #{phone}` | 比较的是明文与密文，**永远查不到** | 额外存 `phone_hash`（SHA-256 + 盐）列做等值查询 |
| `LIKE '%138%'` | 完全不可用 | 明确不支持，改用其他检索方式 |
| `ORDER BY phone` | 按密文排序，语义错误 | 不支持 |
| `GROUP BY` / 去重 | 密文相同才能去重（GCM 随机 IV 会导致同一明文密文不同） | 用确定性加密（如 AES-SIV）或哈希列 |

所以：**TypeHandler 适合「写读透明」的字段，不适合需要参与查询条件的字段。** 需要查询的，必须额外设计哈希列或索引列。这一点在安全评审时经常被追问。

---

## 七、八个高频踩坑

### 坑 1：null 参数没指定 jdbcType

```
org.apache.ibatis.type.TypeException: JDBC requires that the JdbcType must be specified
for all nullable parameters.
```

`BaseTypeHandler.setParameter` 在 `parameter == null && jdbcType == null` 时直接抛异常。解决：

```xml
<insert id="insert">
    INSERT INTO t_order(remark) VALUES (#{remark, jdbcType=VARCHAR})
</insert>
```

或者在全局配置里打开 `jdbcTypeForNull`：

```yaml
mybatis:
  configuration:
    jdbc-type-for-null: 'NULL'   # 默认 OTHER，某些驱动不认
```

### 坑 2：resultMap 里没写 typeHandler

```xml
<!-- ❌ 只写了 property/column，用默认 Handler -->
<result property="status" column="status"/>
```

必须显式写：

```xml
<result property="status" column="status"
        typeHandler="com.example.mybatis.handler.OrderStatusTypeHandler"/>
```

或者直接依赖「注册成 `(javaType, null)` 默认处理器」，让 MyBatis 自动匹配——这也是为什么推荐用无参构造 + 包扫描。

### 坑 3：`@MappedJdbcTypes` 限制了适用范围

```java
@MappedJdbcTypes(JdbcType.TINYINT)   // 只匹配 TINYINT
```

如果库里是 `INT`，查找时 `(javaType, INTEGER)` 不命中，回退 `(javaType, null)` 也不命中（因为你注册时绑定了 TINYINT），最终落到默认 Handler。

**除非有明确需求，别随便写 `@MappedJdbcTypes`。**

### 坑 4：泛型基类导致注册失效

```java
public abstract class AbstractEnumHandler<E extends Enum<E>> extends BaseTypeHandler<E> { }
public class OrderStatusHandler extends AbstractEnumHandler<OrderStatus> { }
```

`TypeReference` 只能解析到直接父类的泛型实参。中间隔了一层抽象类时，`getRawType()` 拿到的是 `Enum` 或 `Object`，注册就跑到 `Object` 上去了。

**解决**：在具体子类上显式加 `@MappedTypes(OrderStatus.class)`，或者用带 `Class<E>` 构造参数的版本手动 `register`。

### 坑 5：包扫描静默跳过

`type-handlers-package` 扫描时，如果 Handler 没有无参构造函数、或者泛型解析失败，**只打一条 debug 日志就跳过了**，你根本不会发现。上线后表现是「配置写了但没生效」。

**排查手段**：启动后打印 `configuration.getTypeHandlerRegistry().getTypeHandler(OrderStatus.class)`，看是不是你的 Handler 实例。

### 坑 6：Handler 里塞了可变状态

`TypeHandler` 是**单例**，被所有线程共享。写成这样就是定时炸弹：

```java
public class BadHandler extends BaseTypeHandler<String> {
    private String temp;              // ❌ 共享可变状态
    private final SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd"); // ❌ 非线程安全
}
```

**规则：Handler 只能是「无状态 + 不可变字段」**，缓存 Map 也必须在构造时初始化后只读。

### 坑 7：二级缓存缓存的是「对象」，不是数据库值

`<cache/>` 开启后，`ResultSetHandler` 产出的对象会被缓存。也就是说**反序列化已经做完了**。如果有人绕过 MyBatis 直接改库（比如 DBA 手工 UPDATE），缓存不会失效。

另外，如果 Handler 返回的是**可变集合**，缓存返回的是同一个引用，调用方改一下就把缓存污染了。**Handler 应返回不可变或深拷贝的对象。**

### 坑 8：加密 Handler + 分页插件 count 语句

分页插件会自动生成 `SELECT COUNT(*)`。如果原 SQL 的 `WHERE` 里用了加密列，count 语句同样查不到数据，表现为「总数 0 但列表有数据」（或反之）。这类问题只能靠「哈希列」从设计上避免。

---

## 八、面试常见追问

**Q1：MyBatis 里枚举默认是怎么存的？**

默认 `EnumTypeHandler` 存 `name()`；如果配置 `defaultEnumTypeHandler=org.apache.ibatis.type.EnumOrdinalTypeHandler` 则存 `ordinal()`。生产环境**强烈建议存自定义 code 或 name，绝不要用 ordinal**。

**Q2：TypeHandler 和 Converter 有什么区别？**

- `TypeHandler`：Java 类型 ↔ **JDBC** 类型的转换，作用于 `PreparedStatement` / `ResultSet`；
- `TypeConverter`（MyBatis-Plus 的概念）：Java 类型 ↔ **数据库字符串** 的转换，用于 `@TableField(typeHandler=...)` 之外的场景；
- Spring 的 `Converter`：任意类型之间的转换，与持久层无关。

**Q3：`#{}` 和 `${}` 在 TypeHandler 层面有什么差异？**

`#{}` 走 `PreparedStatement` 占位符，**会经过 TypeHandler**；`${}` 是字符串直接拼接，**不经过 TypeHandler**。所以加密、脱敏类 Handler 对 `${}` 完全无效——这也是 `${}` 的又一条罪状。

**Q4：怎么做一个「全局字段脱敏」？**

不建议用 TypeHandler（会影响写入）。更合适的是：

- 查询侧：用 `ResultSetHandler` 插件或 `@JsonSerialize` 做序列化脱敏；
- 或者用「视图 + 权限」在数据库层隔离。

**Q5：TypeHandler 能拦到批量插入吗？**

能。`ExecutorType.BATCH` 下最终仍走 `ParameterHandler.setParameters()`，Handler 照常生效。但要注意批量场景下异常定位困难——某一条序列化失败会导致整批回滚。

**Q6：如何调试「Handler 没生效」？**

按这个顺序查：

1. `configuration.getTypeHandlerRegistry().getTypeHandler(Xxx.class)` 打印实际 Handler；
2. 检查 `@MappedTypes` / `@MappedJdbcTypes` 是否把匹配范围收窄了；
3. 检查 resultMap 是否显式覆盖了 `typeHandler`；
4. 检查 SQL 用的是 `#{}` 还是 `${}`；
5. 检查是不是被 MyBatis-Plus 的 `autoResultMap` 逻辑接管了。

---

## 九、总结

`TypeHandler` 是 MyBatis 里「小而关键」的扩展点，把它用好的收益很直接：

- **枚举统一走 code**，不再怕顺序变更；
- **JSON 字段透明读写**，不用在 Service 层到处 `writeValueAsString`；
- **敏感字段统一加密**，不漏字段；
- **类型转换集中治理**，出问题只有一个地方要看。

三条实践原则：

1. **优先注册成 `(javaType, null)`**，让它成为该类型的默认处理器；
2. **Handler 必须无状态、线程安全、处理 null**（尤其 `rs.wasNull()`）；
3. **参与查询条件的字段不要用 TypeHandler 做加密**，用哈希列从设计上解决。

再补一句工程习惯：**每加一个 TypeHandler，都在启动日志里打印一次注册结果**。MyBatis 的注册失败是静默的，你不主动验证，就只能等线上出事。
