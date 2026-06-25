---
title: Java 日期时间 API 完全指南：从遗留 Date 到现代 java.time
date: 2026-06-25 08:00:00
tags:
  - Java
  - 日期时间
  - java.time
  - 面试
categories:
  - Java
  - Java基础
author: 东哥
---

# Java 日期时间 API 完全指南：从遗留 Date 到现代 java.time

## 面试官：SimpleDateFormat 是线程安全的吗？

这是 Java 日期时间方面最经典的"钓鱼题"。答案很干脆：

**`SimpleDateFormat` 不是线程安全的。** 多个线程同时调用同一个 `SimpleDateFormat` 实例的 `parse()` 或 `format()` 方法，会导致内部 `Calendar` 对象状态错乱，产生各种诡异结果——解析出错误日期、无限循环甚至 JVM crash。

```java
// ❌ 错误示范：共享 SimpleDateFormat
private static final SimpleDateFormat SDF = new SimpleDateFormat("yyyy-MM-dd");

// 多个线程并发调用：
// 线程 1: SDF.parse("2024-01-01") → 可能返回 2024-06-01 或根本异常
// 线程 2: SDF.parse("2024-06-15") →
```

解决方案有四种：

1. **每次 new 新实例**（简单但浪费）
2. **加锁**（性能损失）
3. **ThreadLocal**（经典解决方案）
4. **换成 DateTimeFormatter**（推荐，Java 8+）

```java
// 方案 4：使用线程安全的 DateTimeFormatter
private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd");
// DateTimeFormatter 是不可变的，天然线程安全！
```

> **面试追问：** "为什么 SimpleDateFormat 不是线程安全的？它的内部是怎么出问题的？"
>
> **分析：** `SimpleDateFormat` 内部持有一个 `Calendar` 对象，`parse()` 和 `format()` 都会修改 `Calendar` 的各个字段。多线程同时操作这个共享的 `Calendar` 实例，就会出现一个线程刚设置好年份，另一个线程改成了别的值。

## 一、Java 日期时间 API 的进化史

| 版本 | API | 特点（与槽点） |
|------|-----|---------------|
| JDK 1.0 | `java.util.Date` | 非线程安全、设计糟糕（月份 0 开始、年份-1900） |
| JDK 1.1 | `java.util.Calendar` + `DateFormat` | 依然可变、设计复杂、性能差 |
| JDK 1.8 | `java.time` 包（JSR-310） | 不可变、线程安全、设计优雅 |
| JDK 9+ | 各种增强 | 新增 `LocalDate.ofInstant()`、`Duration.toDaysPart()` 等 |

### 1.1 老 API 的"槽点"汇总

```java
// 1. Date 的月份从 0 开始
Date date = new Date(2024 - 1900, Calendar.JANUARY, 1);  // year 要减 1900
System.out.println(date.getMonth());  // 0 代表一月！（我怎么会知道这么坑）

// 2. 月份常量居然是从 0 开始的
Calendar.DECEMBER == 11  // true，最后一个月的值是 11

// 3. DateFormat 格式化时月份是英文
DateFormat df = DateFormat.getDateInstance();
System.out.println(df.format(new Date()));  // Jan 1, 2024（看你的 Locale）

// 4. Date 是可变的
Date date = new Date();
Date copy = date;
copy.setTime(123456L);  // 原 date 也被改了 → 破防了
```

## 二、java.time 核心类体系

`java.time` 包基于 Joda-Time 的设计理念，主要分为三类：

- **日期/时间类**：`LocalDate`、`LocalTime`、`LocalDateTime`、`ZonedDateTime`、`Instant`
- **时间单位**：`TemporalUnit`（`ChronoUnit`实现）、`TemporalField`（`ChronoField`实现）
- **时间段**：`Duration`（秒/纳秒级）、`Period`（年月日级）

### 2.1 LocalDate — 纯日期（不含时间和时区）

```java
// 创建
LocalDate today = LocalDate.now();                      // 系统时钟
LocalDate newYear = LocalDate.of(2024, 1, 1);           // 2024-01-01
LocalDate parsed = LocalDate.parse("2024-01-01");       // ISO 格式直接解析

// 常用操作
LocalDate tomorrow = today.plusDays(1);
LocalDate lastMonth = today.minusMonths(1);
DayOfWeek dow = today.getDayOfWeek();                   // MONDAY ~ SUNDAY
int day = today.getDayOfMonth();                        // 当月第几天
boolean leap = today.isLeapYear();                      // 闰年判断

// 比较
boolean before = date1.isBefore(date2);
boolean after = date1.isAfter(date2);
long days = ChronoUnit.DAYS.between(date1, date2);     // 天数差
```

### 2.2 LocalTime — 纯时间（不含日期和时区）

```java
LocalTime now = LocalTime.now();
LocalTime meeting = LocalTime.of(14, 30, 0);           // 14:30:00
LocalTime parsed = LocalTime.parse("14:30:00");

// 操作
LocalTime later = now.plusHours(2);
boolean isBefore = now.isBefore(meeting);

// 截断（常见面试题：把秒和纳秒置为 0）
LocalTime truncated = now.truncatedTo(ChronoUnit.MINUTES);
System.out.println(truncated);  // 14:30:00（秒和纳秒被截断）
```

### 2.3 LocalDateTime — 日期+时间（不含时区）

```java
LocalDateTime ldt = LocalDateTime.of(2024, 1, 1, 14, 30, 0);
LocalDateTime parsed = LocalDateTime.parse("2024-01-01T14:30:00");

// 组合
LocalDateTime combo = LocalDate.now().atTime(LocalTime.NOON);
LocalDate date = ldt.toLocalDate();
LocalTime time = ldt.toLocalTime();

// ⚠️ 重要：LocalDateTime 不等于时间戳！
// LocalDateTime 不包含时区信息，不能直接转为时间戳
```

### 2.4 ZonedDateTime — 带时区的日期时间

```java
// 带时区
ZonedDateTime now = ZonedDateTime.now(ZoneId.of("Asia/Shanghai"));
ZonedDateTime utc = ZonedDateTime.now(ZoneOffset.UTC);

// 时区转换
ZonedDateTime shanghai = ZonedDateTime.now(ZoneId.of("Asia/Shanghai"));
ZonedDateTime newYork = shanghai.withZoneSameInstant(ZoneId.of("America/New_York"));
System.out.println(shanghai);  // 2024-06-15T10:30+08:00[Asia/Shanghai]
System.out.println(newYork);   // 2024-06-14T22:30-04:00[America/New_York]

// 获取所有支持的时区
Set<String> zoneIds = ZoneId.getAvailableZoneIds();  // 600+ 个时区
```

### 2.5 Instant — 时间戳（UTC 瞬时点）

```java
Instant now = Instant.now();                           // 当前 UTC 时间戳
Instant epoch = Instant.EPOCH;                         // 1970-01-01T00:00:00Z

// 与 Date 互转
Instant inst = new Date().toInstant();
Date date = Date.from(Instant.now());

// 与时间戳
long epochSecond = now.getEpochSecond();               // 秒级
long epochMillis = now.toEpochMilli();                 // 毫秒级
Instant fromMillis = Instant.ofEpochMilli(1718400000000L);

// ⚠️ 典型陷阱
System.out.println(Instant.now());                     // 2024-06-15T02:30:00Z
// 这是 UTC 时间！不是你的本地时间！
// 如果打印出来和你手机时间不一样，是正常的
```

## 三、格式化与解析

### 3.1 DateTimeFormatter

```java
// 预定义格式
DateTimeFormatter isoDate = DateTimeFormatter.ISO_LOCAL_DATE;     // 2024-01-01
DateTimeFormatter isoDateTime = DateTimeFormatter.ISO_LOCAL_DATE_TIME; // 2024-01-01T14:30:00

// 自定义格式
DateTimeFormatter formatter = DateTimeFormatter.ofPattern("yyyy年MM月dd日 HH:mm:ss");
String formatted = LocalDateTime.now().format(formatter);         // "2024年06月15日 14:30:00"

// 解析
LocalDate parsed = LocalDate.parse("2024/01/01", DateTimeFormatter.ofPattern("yyyy/MM/dd"));
```

### 3.2 常用格式模式

| 模式 | 示例 | 说明 |
|------|------|------|
| `yyyy` | 2024 | 四位数年份 |
| `yy` | 24 | 两位数年份 |
| `MM` | 06 | 月份（补零） |
| `M` | 6 | 月份（不补零） |
| `dd` | 01 | 日期（补零） |
| `HH` | 14 | 24小时制 |
| `hh` | 02 | 12小时制 |
| `mm` | 30 | 分钟 |
| `ss` | 00 | 秒 |
| `SSS` | 456 | 毫秒 |
| `a` | 下午 | AM/PM |
| `XXX` | +08:00 | 时区偏移量 |
| `VV` | Asia/Shanghai | 时区 ID |

### 3.3 遗留代码迁移

```java
// Java 8+ 中兼容旧 API 的方式
// Date → Instant → LocalDateTime
Date oldDate = new Date();
LocalDateTime ldt = oldDate.toInstant()
                           .atZone(ZoneId.systemDefault())
                           .toLocalDateTime();

// Calendar → Instant → ZonedDateTime
Calendar cal = Calendar.getInstance();
ZonedDateTime zdt = cal.toInstant()
                        .atZone(ZoneId.systemDefault());

// String 格式化 — 老 vs 新
// 老
SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
String oldStr = sdf.format(new Date());     // 线程不安全

// 新
DateTimeFormatter dtf = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
String newStr = LocalDateTime.now().format(dtf);  // 线程安全
```

## 四、Duration 与 Period

### 4.1 Duration（秒/纳秒精度）

用于计算时间戳之间的时间差：

```java
Duration d1 = Duration.ofHours(2).plusMinutes(30);   // 2小时30分
Duration d2 = Duration.between(instant1, instant2);
long hours = d2.toHours();
long minutes = d2.toMinutes();
long nanos = d2.toNanos();

// ISO 格式解析
Duration parsed = Duration.parse("PT2H30M");         // 2小时30分
System.out.println(parsed);                          // PT2H30M
```

### 4.2 Period（年月日精度）

用于计算日期之间的间隔：

```java
Period p = Period.between(startDate, endDate);
int years = p.getYears();
int months = p.getMonths();
int days = p.getDays();

// 总天数（注意：Period 不精确，因为月份天数不定）
long totalDays = ChronoUnit.DAYS.between(startDate, endDate);
```

## 五、实际场景中的常见问题

### 5.1 获取一天的开始和结束

```java
// 今日 00:00:00
LocalDateTime startOfDay = LocalDate.now().atStartOfDay();
// 或
LocalDateTime start = LocalDateTime.now().with(ChronoField.NANO_OF_DAY, 0);

// 今日 23:59:59.999999999
LocalDateTime endOfDay = LocalDate.now().atTime(LocalTime.MAX);
```

### 5.2 时区转换最佳实践

推荐：**后端统一用 UTC 存储，展示时转成用户时区**

```java
// 存储：统一为 UTC 时间戳
Instant now = Instant.now();                          // UTC

// 展示：转换到用户时区
ZonedDateTime userTime = now.atZone(ZoneId.of("Asia/Shanghai"));
String display = userTime.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));

// 数据库交互（JDBC 4.2+ 支持直接存 LocalDateTime/LocalDate）
preparedStatement.setObject(1, LocalDate.now());     // 直接保存日期
resultSet.getObject("create_time", LocalDateTime.class);  // 直接读取
```

### 5.3 计算本月第一天 / 最后一天

```java
LocalDate today = LocalDate.now();
LocalDate firstDay = today.withDayOfMonth(1);
LocalDate firstDay2 = today.with(TemporalAdjusters.firstDayOfMonth());

LocalDate lastDay = today.with(TemporalAdjusters.lastDayOfMonth());
System.out.println(lastDay);  // 2024-06-30

// 下个月第一天
LocalDate firstOfNextMonth = today.plusMonths(1).withDayOfMonth(1);
```

### 5.4 日期范围判断（如：某个时间段是否包含今天）

```java
public boolean isWithinRange(LocalDate start, LocalDate end) {
    LocalDate today = LocalDate.now();
    return !today.isBefore(start) && !today.isAfter(end);
}

// 使用半开区间 [start, end)
public boolean isInHalfOpenRange(LocalDateTime start, LocalDateTime end) {
    LocalDateTime now = LocalDateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
}
```

## 六、与数据库的交互

| Java 类型 | JDBC 类型 | MySQL 类型 |
|-----------|-----------|-----------|
| `LocalDate` | `DATE` | `DATE` |
| `LocalTime` | `TIME` | `TIME` |
| `LocalDateTime` | `TIMESTAMP` | `DATETIME` |
| `OffsetDateTime` | `TIMESTAMP_WITH_TIMEZONE` | `TIMESTAMP` |
| `Instant` | `TIMESTAMP` | `TIMESTAMP`（UTC 存储） |

```java
// Spring JPA 示例
@Entity
public class OrderEntity {
    @Column(name = "create_time")
    private LocalDateTime createTime;  // JPA 自动映射
    
    @Column(name = "expire_date")
    private LocalDate expireDate;
}
```

## 七、面试高频题汇总

| 问题 | 核心点 |
|------|--------|
| SimpleDateFormat 线程安全吗？ | 不安全，内部 Calendar 可变 |
| java.time 为什么不用 SimpleDateFormat？ | 用 DateTimeFormatter，不可变线程安全 |
| LocalDate 和 Date 的区别？ | 不可变 vs 可变，设计更清晰 |
| LocalDateTime 和 Instant 的区别？ | LocalDateTime 无时区；Instant 是 UTC 时间戳 |
| 怎么算两个日期相差多少天？ | `ChronoUnit.DAYS.between(start, end)` |
| Period 和 Duration 的区别？ | Period 年月日；Duration 秒纳秒 |
| 时区转换怎么做？ | ZonedDateTime 配合 ZoneId |
| 旧代码 Date 怎么迁移到 java.time？ | `Date.toInstant().atZone()` |

## 总结

Java 8 引入的 `java.time` 包是正确的日期时间处理方式。记住三条原则：

1. **永远不要在业务代码中使用 `SimpleDateFormat`**，用 `DateTimeFormatter`
2. **存储用 UTC，展示转本地**，用 `Instant` 或 `OffsetDateTime` 存储
3. **根据场景选对类**：纯日期用 `LocalDate`，精确时间戳用 `Instant`，带时区用 `ZonedDateTime`
