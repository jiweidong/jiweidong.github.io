---
title: 【安全实战】日志脱敏深度实战：从 Logback 自定义规则到敏感信息治理方案
date: 2026-09-10 08:00:00
tags:
  - 日志
  - Logback
  - 安全
  - 实战
categories:
  - Java
  - 安全
  - 运维
author: 东哥
---

# 【安全实战】日志脱敏深度实战：从 Logback 自定义规则到敏感信息治理方案

## 面试官：日志里打了手机号、身份证、密码，出了安全事故算谁的？

线上排查问题时，`log.info("用户下单: {}", user)` 一条日志把手机号、身份证号全打出来了。日志进了 ELK、进了日志易、进了三方排障群——**日志泄露是数据安全合规（个保法、等保）的常见罚点**。而"以后注意别打"这种口头约定根本不可靠，必须在**框架层做强制脱敏**。

本文梳理日志敏感信息的四层治理方案，重点讲 Logback 层面的三种落地手段（Converter、Filter、Encoder），并给出生产可用的完整配置。

## 一、先分类：日志里有哪些敏感信息

| 类型 | 示例 | 脱敏规则 |
|---|---|---|
| 手机号 | 138****5678 | 保留前 3 后 4 |
| 身份证 | 110101********1234 | 保留前 6 后 4 |
| 银行卡 | 6222 **** **** 1234 | 保留后 4 |
| 邮箱 | zh***@qq.com | 保留首字符与域名 |
| 密码/密钥 | 明文密码、token、Authorization | 整体替换为 `***` |
| IP/地址 | 内网 IP、详细地址 | 按策略掩码或打码 |

## 二、治理方案分层：从源头到出口

```
第 1 层：代码规范（源头）      —— 不打明文、用脱敏工具类
第 2 层：序列化层              —— Jackson 脱敏注解（@Sensitive）
第 3 层：日志框架层（本文重点） —— Logback Converter / Filter / Encoder
第 4 层：采集存储层            —— Logstash/Filebeat 过滤、ES 字段权限
```

**核心原则：不信任任何一层，越靠底层兜底越稳。** 代码层漏了，框架层必须接住。

## 三、方案一：自定义 Pattern Converter（推荐）

Logback 允许自定义 `%` 转换符，把"打印时脱敏"做成全局能力。

### 3.1 实现 Converter

```java
public class SensitiveDataConverter extends MessageConverter {

    // 预编译正则：手机号 / 身份证 / 银行卡
    private static final Pattern PHONE = Pattern.compile("(?<!\\d)1[3-9]\\d{9}(?!\\d)");
    private static final Pattern ID_CARD = Pattern.compile("(?<!\\d)\\d{17}[\\dXx](?!\\d)");
    private static final Pattern BANK = Pattern.compile("(?<!\\d)\\d{16,19}(?!\\d)");

    @Override
    public String convert(ILoggingEvent event) {
        String msg = event.getFormattedMessage();   // 取格式化后的完整消息
        msg = PHONE.matcher(msg).replaceAll(m -> m.group().replaceAll("(\\d{3})\\d{4}(\\d{4})", "$1****$2"));
        msg = ID_CARD.matcher(msg).replaceAll(m -> m.group().replaceAll("(\\d{6})\\d{8}(\\d{4})", "$1********$2"));
        msg = BANK.matcher(msg).replaceAll(m -> m.group().replaceAll("(\\d{4})\\d+(\\d{4})", "$1 **** **** $2"));
        return msg;
    }
}
```

正则里的 `(?<!\d)` / `(?!\d)` 是**边界断言**，防止把订单号、时间戳里连续数字误伤成手机号。生产上建议用**配置化的正则列表**（从配置中心加载），避免改规则要发版。

### 3.2 注册进 logback.xml

```xml
<configuration>
    <!-- 1. 注册转换器 -->
    <conversionRule conversionWord="msg"
                    converterClass="com.example.log.SensitiveDataConverter" />

    <appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <encoder>
            <!-- 2. 用 %msg 触发脱敏转换器 -->
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %-5level [%thread] %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>

    <root level="INFO">
        <appender-ref ref="FILE"/>
    </root>
</configuration>
```

> 注意：覆盖了内置的 `%msg` 后，所有 Appender 的日志都会经过脱敏，**一处配置全局生效**。代价是正则匹配有少量性能开销（毫秒级可忽略，高并发下可用缓存/先探测敏感字符再匹配优化）。

## 四、方案二：自定义 Filter（按需丢弃/改写）

Converter 适合"脱敏展示"，Filter 适合"整条丢弃高危日志"或"按 MDC 标记处理"：

```java
public class SensitiveLogFilter extends Filter<ILoggingEvent> {

    @Override
    public FilterReply decide(ILoggingEvent event) {
        String msg = event.getFormattedMessage();
        // 命中明文密码关键词 → 直接丢弃（宁可丢日志不泄密）
        if (msg != null && (msg.contains("password=") || msg.contains("token="))) {
            return FilterReply.DENY;
        }
        return FilterReply.NEUTRAL;
    }
}
```

```xml
<appender name="ASYNC" class="ch.qos.logback.classic.AsyncAppender">
    <filter class="com.example.log.SensitiveLogFilter"/>
    <appender-ref ref="FILE"/>
</appender>
```

## 五、方案三：MDC + 统一封装，代码层兜底

框架层兜底之外，团队还要有**好用的工具**，让"脱敏"成为顺手的事而不是负担：

```java
public final class MaskUtil {

    private MaskUtil() {}

    public static String phone(String p) {
        return p == null || p.length() < 7 ? "***" :
                p.replaceAll("(\\d{3})\\d{4}(\\d{4})", "$1****$2");
    }

    public static String idCard(String id) {
        return id == null || id.length() < 10 ? "***" :
                id.replaceAll("(\\d{6})\\d{8}(\\w{4})", "$1********$2");
    }

    public static String email(String e) {
        if (e == null || !e.contains("@")) return "***";
        String[] parts = e.split("@");
        return parts[0].charAt(0) + "***@" + parts[1];
    }

    /** 对外统一入口：对象转日志字符串时递归脱敏 */
    public static String safe(Object obj) {
        if (obj == null) return "null";
        // 结合 Jackson 的 @Sensitive 注解或字段白名单实现
        return JSON.toJSONString(obj, SensitiveFilter.getInstance());
    }
}
```

配套**团队约定**（写进代码规约）：
- 禁止直接打印实体对象，统一走 `MaskUtil.safe(obj)`；
- 日志模板禁止出现 `password`、`token`、`secret` 字样；
- 敏感字段在 DTO 上打 `@JsonIgnore` 或 `@Sensitive`，从序列化源头拦截。

## 六、方案四：采集层兜底（ELK 场景）

日志进了 Kafka/Logstash 后仍有泄露风险，采集层再上一道：

```
Filebeat/Logstash filter 阶段：
  1. 正则替换敏感字段（同 Logback 规则，双保险）
  2. drop 包含 password= 的 event
  3. ES 索引层面：敏感字段设 keyword + 字段级权限（部分角色不可读）
```

多一层采集层脱敏的收益：**历史日志、第三方系统接入的日志、绕过应用层直接写文件的日志**也能被覆盖。

## 七、三种方案对比与选型

| 方案 | 生效范围 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| Converter（%msg） | 全局所有 Appender | 一处配置全生效、透明 | 正则性能开销、误伤需精调 | **首选，通用日志脱敏** |
| Filter | 单 Appender | 可丢弃高危日志 | 只过滤不改写（需自写） | 高危日志丢弃 |
| 代码层 MaskUtil/注解 | 应用代码 | 精确、可测试 | 依赖开发自觉 | 新代码规范 |
| 采集层（Logstash/ES） | 管道 | 覆盖第三方与历史 | 链路复杂、双倍成本 | ELK 生产必配 |

> 成熟度提醒：Logback 生态里也有现成方案（如 `logback-mask`、logstash-logback-encoder 的 `MaskingJsonGenerator` 可对 JSON 字段打码），引入第三方前先确认维护活跃度与正则性能。

## 八、高频面试追问

**Q1：Converter 和 Filter 的区别？**
Converter 在**输出前改写消息内容**（脱敏展示）；Filter 决定**事件是否交给 Appender**（DENY/ACCEPT/NEUTRAL），适合丢弃。脱敏用 Converter，丢弃用 Filter。

**Q2：为什么覆盖 %msg 会影响所有 Appender？**
因为 conversionRule 注册的是全局转换符，任何 pattern 里出现 `%msg` 都会走 `SensitiveDataConverter`。如果只想对某个 Appender 生效，可以把 Appender 拆开分别配 pattern，或用 Filter 按 Appender 隔离。

**Q3：正则脱敏的性能怎么保证？**
三个手段：正则预编译 + 复用（Pattern 常量）；先做快速预检（消息里没有 11 位连续数字就直接返回原文，避免全量正则）；高 QPS 场景把脱敏放在异步 Appender 线程。实测常规业务下开销可忽略。

**Q4：日志脱敏能完全替代代码规范吗？**
不能。框架层是兜底，正则覆盖不了"拼接式敏感信息"（如拆成两段打印）。正确姿势是**代码规范（不打明文）+ 框架兜底（Converter）+ 采集层双保险**三层同时上。

## 九、总结

日志脱敏的本质是**把"人别打敏感信息"的软约束，变成"框架打不出来"的硬约束**：

- 首选 Logback 自定义 Converter 覆盖 `%msg`，一处配置全局脱敏；
- 高危日志用 Filter 直接 DENY；
- 代码层提供 `MaskUtil` + 序列化注解，从源头规范；
- ELK 场景在采集层再兜一道，覆盖历史与三方日志；
- 手机/身份证/银行卡正则务必加边界断言，避免误伤业务数字。

合规无小事，一条泄密的日志可能比一个 Bug 贵得多。把脱敏做成**默认能力**而不是"提醒事项"，才是工程化的安全。
