---
title: 【JVM 调优】G1 字符串去重深度解析：-XX:+UseStringDeduplication 的真实收益与代价
date: 2026-11-07 08:00:00
tags:
  - Java
  - JVM
  - G1
  - 内存优化
  - 性能调优
categories:
  - Java 深挖
author: 东哥
---

# 【JVM 调优】G1 字符串去重深度解析：-XX:+UseStringDeduplication 的真实收益与代价

## 前言：一个"开了就该省内存"的参数

几乎每个 JVM 调优清单里都有这么一条：

```
-XX:+UseG1GC -XX:+UseStringDeduplication
```

注释写着"字符串去重，省内存"。于是很多团队在启动脚本里加上，然后……再也没有验证过它到底省了多少。

我们有个订单查询服务，堆 8G，Full GC 后存活 5.2G，其中 `String` 对象的 `byte[]` 占了 1.9G。业务上大量订单状态、渠道名、失败原因都是重复字符串（枚举值渲染出来的）。开启字符串去重后，存活降到 4.3G，**降幅 17%**，Young GC 后的晋升量减少，Full GC 从每天 2 次降到 3 天 1 次。

但另一个服务开了之后几乎没变化，反而 CPU 涨了 3%。所以这个参数**不是银弹**，用之前必须搞清楚它的工作机制和适用边界。

## 一、它到底去重了什么

### 1.1 只去重底层数组，不去重 String 对象

这是最容易被误解的一点。开启 `-XX:+UseStringDeduplication` 后，JVM 并不会把两个内容相同的 `String` 对象合并成一个，而是让它们的 `value` 字段**指向同一个 `byte[]`**：

```
去重前：
String@0x100 ──> byte[]{'P','A','I','D'}    (对象头 16B + 数组 16B + 4B)
String@0x200 ──> byte[]{'P','A','I','D'}    (对象头 16B + 数组 16B + 4B)

去重后：
String@0x100 ──> byte[]{'P','A','I','D'}    (只剩一份数组)
String@0x200 ──┘
```

所以收益上限是 **`byte[]` 的总大小**，`String` 对象本身（16 字节对象头 + 4 字节 hash + 4 字节 value 引用 + 4 字节 coder）一分都省不掉。

这也解释了一个常见疑问："为什么我 dump 出来 `String` 数量没减少？"——因为减少的是数组，不是 String。

### 1.2 只处理"活得够久"的字符串

去重是**在 Young GC 时**触发的，且只处理年龄达到阈值的对象：

```
-XX:StringDeduplicationAgeThreshold=3   # 默认 3，即熬过 3 次 Young GC
```

为什么要有阈值？因为短命字符串（比如一次请求里拼出来的 SQL、日志消息）本来下一轮就死了，给它算哈希、查表、改引用纯属浪费 CPU。只有**反复晋升的老字符串**才值得去重。

这也决定了适用场景：**常量池、枚举渲染、字典表、配置项、固定格式的 ID**——这些字符串生命周期长、重复率高。而动态拼接的日志、UUID、时间戳字符串，开了也没用。

### 1.3 处理链路：队列 + 独立线程

整体流程分三段：

```
Young GC
  └─ 存活对象扫描时，把符合条件的 String 的 byte[] 放进 StringDedupQueue（无锁队列）
        │
        ▼
StringDedupThread（独立线程，并发执行）
  └─ 从队列取数组 → 计算内容哈希 → 查 StringDedupTable
        ├─ 命中：把 String.value 指向已有数组（需要 safepoint 或 CAS）
        └─ 未命中：把 (hash, 弱引用) 插入表
```

关键实现细节：

- **`StringDedupTable` 用弱引用（weak oop）保存数组**，数组被回收后表项自动失效，不会造成内存泄漏；
- 表是**分代 + 可扩容**的，默认大小与堆相关，扩容时会做 rehash；
- 表的哈希用的是**数组内容的哈希**（不是 String 的 `hashCode`，后者可能还没算过，且受 `coder` 影响）；
- 真正的"改引用"必须保证原子性，JVM 用 `oop_store` + safepoint 检查来避免与 mutator 竞争。

## 二、什么时候有用：三个必要条件

我把经验总结成三条，缺一条收益就很有限：

**（1）重复率高。** 实测去重前先跑一次堆直方图：

```bash
jcmd <pid> GC.class_histogram | head -30
```

如果 `[B`（byte 数组）排名靠前，且 `String` 数量远大于"不同内容数"，就有戏。更精确的办法是用 JFR 或 `jmap -histo:live` 对比开启前后的存活。

**（2）字符串活得久。** 如果对象大多在 Young 区就死了，去重线程根本来不及处理。看 GC 日志里的晋升量（`-Xlog:gc+age=trace`）。

**（3）字符串不太短。** 一个 4 字节的数组，去重省 16 字节，但表项本身要占 16~32 字节，**净收益可能是负的**。内容长度低于 8~16 的字符串，收益基本可以忽略。

## 三、代价：CPU、内存、延迟

| 维度 | 影响 | 量级（经验值） |
|---|---|---|
| CPU | 去重线程持续哈希 + 查表 | 单核 3%~8%，重复率高时更高 |
| 内存 | 去重表本身（弱引用 + 哈希桶） | 堆的 1%~3% |
| 暂停 | GC 时入队，几乎无额外 STW | < 1ms |
| 吞吐 | 改引用需要 safepoint 协作 | 1%~3% |
| 延迟 P99 | 哈希表扩容时有抖动 | 偶发 +5~10ms |

注意最后一项：表扩容时是**全表 rehash**，在超大堆（32G+）上可能造成几十毫秒的抖动。如果对 P99 极敏感，可以预先设置表大小（内部参数，不对外开放，一般靠"预热"度过）。

## 四、实测：一个 8G 堆的订单服务

### 4.1 环境

- JDK 21，G1，`-Xms8g -Xmx8g`，Region 4MB
- 日请求 4200 万，QPS 峰值 1800
- 字符串来源：订单状态（12 种）、渠道（8 种）、失败原因（60 种）、城市名（340 个）

### 4.2 对比数据

| 指标 | 未开启 | 开启后 | 变化 |
|---|---|---|---|
| Full GC 后存活 | 5.2 GB | 4.3 GB | **-17%** |
| Young GC 平均暂停 | 38 ms | 41 ms | +8% |
| Young GC 频率 | 5.2 次/分 | 4.4 次/分 | -15% |
| 晋升量 | 210 MB/min | 150 MB/min | -29% |
| CPU（应用进程） | 62% | 64% | +2pp |
| Full GC 次数（7 天） | 14 | 2 | **-86%** |

结论：**内存收益明显，CPU 代价可接受**。尤其是晋升量下降 29%，这是最直接的收益——晋升少了，老年代压力小，Full GC 自然少。

### 4.3 另一个反例

一个网关服务，堆 4G，主要是 Netty ByteBuf 和动态拼接的 JSON 字符串。开启后：

- 存活内存：几乎无变化（-0.3%）
- CPU：+3.5%
- Young GC 暂停：+12%

原因很简单：**它的字符串大多是请求级的短命对象，且内容不重复**（含 traceId、时间戳）。去重线程白干活，还跟应用线程抢 CPU。**已经回滚。**

## 五、怎么观测

### 5.1 GC 日志

```bash
-Xlog:gc*,gc+stringdedup=info:file=/var/log/app/gc.log:time,uptime,level,tags
```

会输出类似：

```
[12.345s][info][gc,stringdedup] Concurrent String Deduplication: 12843 candidates, 9871 deduplicated, 2.1MB processed, 1.8MB skipped
```

重点看两个比值：

- `deduplicated / candidates`：命中率，低于 30% 说明重复率不够，收益有限；
- `skipped / processed`：跳过率，太高说明字符串太短或太年轻。

### 5.2 堆直方图对比

```bash
# 开启前
jcmd <pid> GC.class_histogram > before.txt
# 开启并跑满一个业务周期后
jcmd <pid> GC.class_histogram > after.txt
```

关注 `[B` 的 `#instances` 与 `#bytes`。注意：直方图会触发一次 Full GC（`GC.class_histogram` 默认 `live` 语义），生产上慎用，建议用 JFR 的 `ObjectCount` 事件替代。

### 5.3 JFR

```bash
jcmd <pid> JFR.start name=dedup settings=profile duration=300s filename=dedup.jfr
```

在 JMC 里看 `jdk.ObjectCount` 和 GC 页面的堆占用曲线，比直方图更轻量。

## 六、与其他"省内存"手段的关系

很多人把字符串去重和下面几个搞混，其实它们解决的是不同问题：

| 手段 | 作用对象 | 生效时机 | 典型收益 |
|---|---|---|---|
| Compact Strings（JEP 254） | 单字符 ≤ 255 时用 LATIN1 | 编译/运行时自动 | 每个字符串省 50% 数组 |
| 字符串去重 | 重复的 `byte[]` | GC 时并发 | 重复率高时 10%~25% 堆 |
| `String.intern()` | 全局唯一字符串 | 手动调用 | 省内存但吃 Metaspace，易 OOM |
| CDS 归档字符串 | 启动期常量 | 构建镜像时 | 启动快 + 少量内存 |
| 对象池/枚举缓存 | 业务对象 | 应用层 | 最彻底，但要自己管生命周期 |

**优先级建议**：能用枚举/常量/缓存解决的，不要指望 JVM 参数；确实有大量不可控的重复字符串（比如反序列化出来的 JSON 字段值），再开去重。

`intern()` 要特别小心：JDK 7 之后字符串常量池在堆里，但 `intern()` 的表是全局的、清理成本高，大量唯一字符串会导致 Metaspace 或 native memory 膨胀，**绝不建议对用户输入调用**。

## 七、生产配置建议

```bash
# 基础配置
-XX:+UseG1GC
-XX:+UseStringDeduplication
-XX:StringDeduplicationAgeThreshold=3

# 观测
-Xlog:gc*,gc+stringdedup=info:file=/var/log/app/gc.log:time,uptime:filecount=10,filesize=50m

# 若堆很大（>32G）且 P99 敏感，考虑关掉，改用应用层缓存
```

几点经验：

1. **先测再开。** 至少跑一个完整业务周期（含日终批量），看晋升量和 Full GC 频率。
2. **别和 `-XX:+UseZGC` 一起用。** ZGC 不支持字符串去重（该参数只对 G1/Shenandoah 生效），加了也只是个无效参数，不会报错，容易被误以为"已开启"。
3. **堆小于 2G 时收益有限。** 去重表本身要占内存，小堆上性价比低。
4. **升级 JDK 后重新验证。** JDK 17→21 之间去重实现有优化（队列与表的并发度），行为可能有变化。

## 八、面试追问

**Q：字符串去重和 `intern()` 的区别？**
A：去重是在 GC 时自动把重复的 `byte[]` 合并，字符串对象还在，生命周期跟随原对象；`intern()` 是把字符串放进全局常量池并返回池中引用，原对象可被回收，但池本身是全局的、清理代价高。

**Q：为什么只对 G1 生效？**
A：去重的触发点是 Young GC 的存活对象扫描，需要 GC 提供"对象年龄"和"存活对象回调"的钩子。G1 的分区式回收和并发标记天然适合；ZGC 的设计目标是极低停顿，不做这类额外工作。

**Q：去重会导致字符串内容被改吗？**
A：不会。合并的是内容完全相同的数组，`String` 不可变，语义不变。唯一可见的影响是 `==` 比较：两个内容相同的字符串，去重后它们的 `value` 引用相同，但 `String` 对象仍不同，所以 `==` 依然是 false。

**Q：如果去重表满了会怎样？**
A：会扩容并 rehash，期间去重线程暂停处理，队列积压。极端情况下队列满会丢弃候选（只是不去重，不影响正确性）。

## 结语

`-XX:+UseStringDeduplication` 是一个典型的"低成本、中等收益、有边界"的优化。它的收益完全取决于你的字符串重复率和生命周期分布，不存在"开了就省 20%"的说法。**用 GC 日志的 `deduplicated/candidates` 比值来决策**，比凭感觉加参数靠谱得多。
