---
title: 【面试必备】面试官：SimpleDateFormat 为什么线程不安全？Java 日期时间处理最佳实践
date: 2026-09-06 08:00:00
tags:
  - Java
  - 并发
  - 面试
  - java.time
categories:
  - Java
  - Java 基础
author: 东哥
---

# 【面试必备】面试官：SimpleDateFormat 为什么线程不安全？Java 日期时间处理最佳实践

## 面试官：你项目里用过 SimpleDateFormat 吗？它线程安全吗？

"用过，格式化日期很方便……线程安全？呃，好像不安全，但我们都是每次 new 一个用的。"

"那你说说它为什么线程不安全？根源在哪？换成什么最好？"

很多同学背了结论"SimpleDateFormat 线程不安全，要用 DateTimeFormatter"，但一问到**为什么不安全**就卡壳。今天我们从 JDK 源码角度彻底讲透，顺便把 Java 日期时间处理的正确姿势梳理一遍。

## 一、先看事故现场

先写个复现 Demo：多个线程共享一个 `SimpleDateFormat` 实例，并发解析日期字符串。

```java
import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class SdfBugDemo {
    // 共享同一个实例 —— 事故源头
    private static final SimpleDateFormat SDF =
            new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");

    public static void main(String[] args) {
        ExecutorService pool = Executors.newFixedThreadPool(8);
        for (int i = 0; i < 20; i++) {
            final String dateStr = "2026-09-06 08:00:0" + (i % 10);
            pool.submit(() -> {
                try {
                    System.out.println(SDF.parse(dateStr));
                } catch (ParseException e) {
                    System.out.println("解析异常: " + e.getMessage());
                }
            });
        }
        pool.shutdown();
    }
}
```

跑几次，你会看到三类典型症状：

1. **抛异常**：`java.lang.NumberFormatException: For input string: ""` 或 `ParseException`；
2. **结果错乱**：解析出 `Sun Jan 06 08:00:00 CST 2029` 这种诡异时间（月份、年份串了）；
3. **偶发正常**：运气好时完全没问题——这正是它最坑的地方，**问题随机出现，线上难以复现**。

## 二、根因分析：共享的可变 Calendar

打开 `SimpleDateFormat` 的源码（JDK 8 及以后都一样），看类继承和关键字段：

```java
public class SimpleDateFormat extends DateFormat {

    // DateFormat 中的关键字段 —— 这就是罪魁祸首
    protected Calendar calendar;

    // 解析/格式化时操作的数字缓冲区（也是共享可变状态）
    transient char[] compiledPattern;
    ...
}
```

`SimpleDateFormat` 继承自 `DateFormat`，**内部持有一个 `Calendar` 实例**。我们以 `parse()` 为例看它干了什么：

```java
public Date parse(String text, ParsePosition pos) {
    // 1. 先清空 calendar —— 注意是"共享的那个 calendar"
    calendar.clear();

    // 2. 解析字符串，把年月日时分秒逐个 set 进 calendar
    //    （内部大量 calendar.set(...) / calendar.get(...)）
    ...
    // 3. 从 calendar 取时间
    Date parsedDate = calendar.getTime();
    ...
}
```

`format()` 同理，也是先 `calendar.setTime(date)` 再逐字段读取。

问题就出在这里：**parse/format 不是无状态的纯函数，它们把中间状态存在共享的 `calendar` 字段里**。当线程 A 刚执行完 `calendar.clear()` 还没来得及 `set` 完所有字段，线程 B 也进来 `clear()` 并开始 set——两个线程的字段互相覆盖：

- A 刚 set 完"2026-09-06"，B 把年份改成了 2029，A 接着 set 月份时把 B 的年份又覆盖掉；
- 某些字段读到一半被改，或者数组越界、空字符串，直接抛 `NumberFormatException`。

另外 `SimpleDateFormat` 内部还有一个共享的 `DecimalFormat`（`numberFormat` 字段）用于解析数字，它同样非线程安全，会放大问题。

**结论：线程不安全的根源不是"解析算法"，而是"实例内部持有可变的 Calendar 和 NumberFormat 共享状态"。** 官方 javadoc 也明确写着：Date formats are not synchronized，建议每个线程维护独立实例，多线程共享时必须外部加锁。

## 三、四种解决办法对比

### 方案一：每次 new —— 能用但浪费

```java
public String format(Date date) {
    return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(date);
}
```

问题：`SimpleDateFormat` 构造时要编译 pattern、创建 Calendar 和 NumberFormat，**对象很重**。高并发下频繁 new + GC，性能差。`Calendar.getInstance()` 本身也不便宜。

### 方案二：加锁同步 —— 能用但变成串行

```java
private static final SimpleDateFormat SDF = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
public synchronized String format(Date date) { return SDF.format(date); }
```

正确但把并发直接打成串行，格式化这种高频操作扛不住。**不推荐**。

### 方案三：ThreadLocal 包装 —— 经典解法

```java
private static final ThreadLocal<SimpleDateFormat> SDF_HOLDER =
        ThreadLocal.withInitial(() -> new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"));

public static String format(Date date) {
    return SDF_HOLDER.get().format(date);
}
```

每个线程独享一个实例，既安全又避免重复创建。这是 Java 8 之前的**标准答案**。注意两点：

- 用 `ThreadLocal.withInitial()` 而不是 `new ThreadLocal<SimpleDateFormat>() { ... }`，避免内部类持有外部引用；
- 在线程池场景，`ThreadLocal` 里的值会随线程复用而存活，用完记得 `remove()`，避免**线程池 + ThreadLocal 的内存泄漏**（虽然 SimpleDateFormat 本身不引用 ThreadLocal，但规范习惯要养成）。

### 方案四：DateTimeFormatter —— 终极答案

```java
// DateTimeFormatter 是不可变的（immutable），天然线程安全！
private static final DateTimeFormatter FORMATTER =
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

// 配合 java.time 使用
String format(LocalDateTime dt) {
    return dt.format(FORMATTER);
}
LocalDateTime parse(String s) {
    return LocalDateTime.parse(s, FORMATTER);
}
```

**为什么它安全？** 因为 `DateTimeFormatter` 设计为**不可变对象**：解析/格式化过程中的状态全部放在方法局部变量或 `ParsePosition`/`DateTimeParseContext` 这类**每次调用新建**的对象里，不写实例字段。不可变 + 无共享可变状态 = 天然并发安全，连锁都不用加。

## 四、Java 8 之后，日期时间到底该怎么用？

面试追问经常是："那你说说 java.time 的设计，LocalDateTime 和 Date 有什么区别？"

### 4.1 核心类一张表

| 类 | 含义 | 典型场景 |
|----|------|---------|
| `LocalDate` | 日期（无时间无时区） | 生日、账单日 |
| `LocalTime` | 时间（无日期无时区） | 营业时间 |
| `LocalDateTime` | 日期+时间，无时区 | 业务时间（配合 DB） |
| `Instant` | 时间戳（UTC 瞬时点） | 跨时区、日志、比较 |
| `ZonedDateTime` | 带时区的日期时间 | 跨时区业务 |
| `OffsetDateTime` | 带固定偏移 | API 传输（ISO8601） |
| `Duration` / `Period` | 时间间隔 | 计算差值 |

设计哲学上：**`Date` 是"一个时间点"但 API 混乱（年月日 getYear() 要 +1900），`Calendar` 可变且字段索引反人类；`java.time` 则把"瞬时点"和"本地时间"严格分开，全部不可变，方法名自解释**（`plusDays` 返回新对象而不是改自己）。

### 4.2 新老 API 互转

```java
// Date -> Instant -> LocalDateTime（注意时区！）
Date date = new Date();
LocalDateTime ldt = date.toInstant()
        .atZone(ZoneId.systemDefault())   // 用服务器默认时区
        .toLocalDateTime();

// LocalDateTime -> Instant -> Date
Date date2 = Date.from(ldt.atZone(ZoneId.systemDefault()).toInstant());

// 与时间戳互转
long epochMilli = Instant.now().toEpochMilli();
Instant instant = Instant.ofEpochMilli(epochMilli);
```

### 4.3 与数据库/MyBatis 的配合

JDBC 4.2 起 `PreparedStatement.setObject()` / `ResultSet.getObject()` 原生支持 `LocalDateTime`，MyBatis 3.4.5+ 也内置了 `LocalDateTimeTypeHandler`，**直接存 LocalDateTime 即可，不要再用 `java.sql.Timestamp` 手动转**：

```java
// 实体类直接写
private LocalDateTime createTime;

// Mapper XML 照常写
// INSERT INTO t_order (create_time) VALUES (#{createTime})
```

⚠️ 常见坑：MySQL 连接串**必须显式指定时区**，否则驱动按服务器时区转换，容易差 8 小时：

```
jdbc:mysql://localhost:3306/db?serverTimezone=Asia/Shanghai&useSSL=false
```

### 4.4 序列化给前端的坑

Spring Boot 默认用 Jackson。注意：`spring.jackson.date-format` **只对 `java.util.Date` 生效**，对 `LocalDateTime` 无效！正确做法：

```java
// 方案 A：字段上加注解
@JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss")
private LocalDateTime createTime;

// 方案 B：全局配置（Boot 2.x+ 推荐，一劳永逸）
@Configuration
public class JacksonConfig {
    @Bean
    public Jackson2ObjectMapperBuilderCustomizer customizer() {
        return builder -> {
            builder.serializers(new LocalDateTimeSerializer(
                    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")));
            builder.deserializers(new LocalDateTimeDeserializer(
                    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")));
        };
    }
}
```

依赖别忘了 `jackson-datatype-jsr310`（Boot 默认带），并在配置里注册 `JavaTimeModule`（`spring.jackson.serialization.write-dates-as-timestamps=false` 可关掉默认的时间戳输出）。

### 4.5 格式化的两个细节

**细节一：`yyyy` 还是 `uuuu`？**

`yyyy` 是 year-of-era（公元纪元内年份），`uuuu` 是 proleptic year（天文年）。对公元后年份没区别，但解析公元前日期或跨纪元时 `yyyy` 会出错。**规范做法是解析用 `uuuu`**，很多静态检查工具也会提示。

**细节二：`ResolverStyle` 三档校验强度**

```java
DateTimeFormatter.ofPattern("yyyy-MM-dd")
        .withResolverStyle(ResolverStyle.STRICT);   // 严格：2月30日直接报错
// SMART（默认）：宽松的智能处理
// LENIENT：最宽松，2月30日会被"顺延"成3月2日
```

## 五、时区：最容易翻车的 8 小时

再问一个高频追问："线上时间差了 8 小时，你会怎么排查？"

排查清单：

1. **服务器时区**：`date` 命令看系统时区，JVM 默认时区由 `user.timezone` / `TZ` 决定，容器部署经常是 UTC；
2. **数据库时区**：连接串有没有 `serverTimezone`；MySQL 的 `TIMESTAMP` 存的是 UTC 时间戳，展示时按会话时区转，而 `DATETIME` 存的就是字面值；
3. **日志打印**：`Date.toString()` 用的是 JVM 默认时区，同一时刻不同机器打出来不一样；
4. **前端展示**：后端存 `Instant`/时间戳，前端按浏览器时区格式化，最不容易错；
5. **夏令时**：如果业务覆盖欧美，`LocalDateTime` + 固定偏移会算错，必须用 `ZonedDateTime`。

生产建议：**存储统一用 UTC（或纯时间戳），展示层按用户时区转换**，后端内部逻辑不要依赖 `ZoneId.systemDefault()` 的隐式行为。

## 六、面试追问速答

**Q：SimpleDateFormat 的 parse 和 format 都不安全吗？**
都危险。两者都操作共享的 `calendar` 字段，parse 先 clear 再 set、format 先 setTime 再读取，并发交错都会产生脏数据。

**Q：那 JDK 为什么不修？**
`SimpleDateFormat` 的线程安全性属于"契约外"行为，官方文档一直要求外部同步。贸然加锁会破坏它和 `DateFormat` 子类的扩展点，属于历史包袱——所以 JDK 8 干脆推出了全新的 `java.time` 体系来替代，而不是修修补补。

**Q：高并发下怎么选？**
JDK 8+ 一律用 `DateTimeFormatter` + `java.time`；如果老项目还在用 `Date`，可以用 ThreadLocal 包 SimpleDateFormat 过渡，但新代码不要再用 SimpleDateFormat 了。

**Q：LocalDateTime 和 Instant 什么时候用哪个？**
"这个时间点本身"（跨时区、存日志、比较先后）用 `Instant`；"墙上时钟时间"（业务上就是这个本地时间，比如"2026-09-06 08:00 开门"）用 `LocalDateTime`；两者转换必须显式指定时区，别让系统默认时区悄悄替你决定。
