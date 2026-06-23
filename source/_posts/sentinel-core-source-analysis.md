---
title: Sentinel 核心源码解析：滑动窗口限流算法与熔断降级实现原理
date: 2026-06-23 08:03:00
tags:
  - Sentinel
  - 限流
  - 源码分析
  - 熔断
categories:
  - 架构
  - 源码分析
author: 东哥
---

# Sentinel 核心源码解析：滑动窗口限流算法与熔断降级实现原理

## 面试官：Sentinel 的滑动窗口限流是怎么实现的？和令牌桶有什么区别？

Sentinel 作为阿里开源的流量防卫兵，其核心是**滑动窗口** + **责任链模式**。本文从源码层面拆解 Sentinel 最核心的限流与熔断机制。

## 一、Sentinel 架构总览

### 1.1 核心调用链路

```
SphU.entry("resourceName")
    ↓
CtSph.entry()  → 创建 Context
    ↓
ProcessorSlotChain（责任链）
    ├── NodeSelectorSlot      ← 构建调用树
    ├── ClusterBuilderSlot    ← 创建统计节点
    ├── LogSlot               ← 日志记录
    ├── StatisticSlot         ← 实时统计（核心！）
    │   ├── FlowSlot          ← 限流规则检查
    │   ├── DegradeSlot       ← 熔断降级检查
    │   ├── SystemSlot        ← 系统保护
    │   └── AuthoritySlot     ← 授权检查
    └── DefaultNode
    ↓
entry 通过 → 执行业务逻辑
entry 拒绝 → BlockException
```

### 1.2 责任链构建

```java
// CtSph 中的链构建
class CtSph {
    private static final ProcessorSlotChainBuilder chainBuilder
        = new DefaultProcessorSlotChainBuilder();

    public Entry entry(String name, EntryType type, Object... args) {
        // 获取或创建资源对应的责任链
        ProcessorSlotChain chain = getChain(name);
        // 执行责任链
        return chain.entry(context, resourceWrapper, null, count, args);
    }

    private ProcessorSlotChain getChain(String resourceName) {
        // 缓存责任链，避免重复创建
        return chainMap.computeIfAbsent(resourceName, key -> {
            ProcessorSlotChain chain = chainBuilder.build();
            chain.addLast(new NodeSelectorSlot());
            chain.addLast(new ClusterBuilderSlot());
            chain.addLast(new StatisticSlot());
            // ... 添加其他 Slot
            return chain;
        });
    }
}
```

## 二、滑动窗口算法源码解析

### 2.1 为什么需要滑动窗口？

传统的**固定时间窗口**有临界突变问题：

```
固定窗口 1 分钟，限制 100 QPS
请求集中在 00:00:59 ~ 00:01:01 两秒内
→ 第一个窗口 (00:00:00~00:01:00): 100 请求
→ 第二个窗口 (00:01:00~00:02:00): 100 请求
→ 实际 2 秒内 200 请求，远超阈值！❌
```

滑动窗口把时间切得更细，解决这个"突刺"问题。

### 2.2 核心数据结构

```java
// LeapArray — 滑动窗口的核心
public abstract class LeapArray<T> {

    /** 窗口时间长度（毫秒）: 如 1000ms = 1秒 */
    protected int windowLengthMs;
    /** 一个周期内的窗口数量: 如 2 个 */
    protected int sampleCount;
    /** 整个时间周期: windowLengthMs * sampleCount */
    protected int intervalInMs;

    /** 环形数组存储窗口数据 */
    protected final AtomicReferenceArray<WindowWrap<T>> array;

    public LeapArray(int sampleCount, int intervalInMs) {
        this.sampleCount = sampleCount;
        this.intervalInMs = intervalInMs;
        this.windowLengthMs = intervalInMs / sampleCount;
        // 环形数组大小 = sampleCount
        this.array = new AtomicReferenceArray<>(sampleCount);
    }
}
```

**默认配置：** `sampleCount=2`, `intervalInMs=1000` → 每个窗口 500ms

```
时间轴: 0ms        500ms      1000ms
        ┌─────────────┬─────────────┐
        │  窗口 0     │   窗口 1    │
        │  指标统计    │   指标统计   │
        └─────────────┴─────────────┘
         ← 整个滑动周期 1000ms →
```

### 2.3 当前时间窗口定位

```java
public int calculateTimeIdx(long timeMillis) {
    // 计算时间对应的窗口索引
    // (timeMillis / 500) % 2
    long timeId = timeMillis / windowLengthMs;
    return (int)(timeId % array.length());
}

public long calculateWindowStart(long timeMillis) {
    // 计算窗口的起始时间
    // (timeMillis / 500) * 500
    return timeMillis - timeMillis % windowLengthMs;
}
```

### 2.4 获取或创建窗口（核心方法）

```java
public WindowWrap<T> currentWindow(long timeMillis) {
    long timeId = timeMillis / windowLengthMs;    // 当前时间对应的桶号
    int idx = (int)(timeId % array.length());     // 环形索引

    WindowWrap<T> old = array.get(idx);
    if (old == null) {
        // 空的 → 新建并 CAS 写入
        WindowWrap<T> window = new WindowWrap<>(
            windowLengthMs, calculateWindowStart(timeMillis), newEmptyBucket()
        );
        return array.compareAndSet(idx, null, window) ? window : null;
    }

    long windowStart = calculateWindowStart(timeMillis);
    if (old.windowStart() == windowStart) {
        // 命中当前窗口
        return old;
    } else if (old.windowStart() < windowStart) {
        // 窗口过期 → 重置
        updateLock.lock();
        try {
            old.resetTo(windowStart);
            return old;
        } finally {
            updateLock.unlock();
        }
    }
    // 理论上不会走到这里
    return old;
}
```

**关键设计：** 环形数组复用，CAS + 分段锁，无锁化读，性能极高。

### 2.5 MetricBucket 统计

```java
public class MetricBucket {
    // 使用 LongAdder 数组，每个事件类型一个计数器
    private final LongAdder[] counters;

    public MetricBucket() {
        counters = new LongAdder[MetricEvent.values().length];
        for (MetricEvent event : MetricEvent.values()) {
            counters[event.ordinal()] = new LongAdder();
        }
    }

    // 统计成功请求
    public void addSuccess(int n) {
        add(MetricEvent.SUCCESS, n);
    }

    // 统计异常请求
    public void addException(int n) {
        add(MetricEvent.EXCEPTION, n);
    }

    // 统计通过的请求
    public void addPass(int n) {
        add(MetricEvent.PASS, n);
    }

    // 统计被阻塞的请求
    public void addBlock(int n) {
        add(MetricEvent.BLOCK, n);
    }

    // 统计 RT
    public void addRt(long rt) {
        add(MetricEvent.RT, rt);
    }
}
```

## 三、限流算法详解

### 3.1 FlowSlot 限流判断

```java
public class FlowSlot extends AbstractLinkedProcessorSlot<DefaultNode> {

    @Override
    public void entry(Context context, ResourceWrapper resourceWrapper,
                      DefaultNode node, int count, Object... args) throws Throwable {
        checkFlow(resourceWrapper, context, node, count);
        fireEntry(context, resourceWrapper, node, count, args);
    }

    void checkFlow(ResourceWrapper resource, Context context,
                   DefaultNode node, int count) throws BlockException {
        // 获取该资源的所有限流规则
        List<FlowRule> rules = FlowRuleManager.getRules(resource.getName());
        if (rules == null) return;

        for (FlowRule rule : rules) {
            // 根据规则进行流量检查
            if (!passLocalCheck(rule, context, node, count, args)) {
                throw new FlowException(rule.getLimitApp(), rule);
            }
        }
    }
}
```

### 3.2 三种限流模式

```java
public class TrafficShapingController {

    // 直接拒绝（默认）
    public boolean canPass(Node node, int acquireCount, boolean prioritized) {
        // 当前滑动窗口 QPS >= 阈值 → 拒绝
        long currentCount = node.passQps();
        return currentCount + acquireCount <= rule.getCount();
    }

    // Warm Up（冷启动/预热）
    public boolean canPass(Node node, int acquireCount, boolean prioritized) {
        long passQps = node.passQps();
        long warningQps = calculateWarmUpQps(rule.getCount(), warmUpPeriodInSec);
        return passQps + acquireCount <= warningQps;
    }

    // 排队等待（匀速通过）
    public boolean canPass(Node node, int acquireCount, boolean prioritized) {
        // 通过时间戳计算下次放行时间
        long currentTime = TimeUtil.currentTimeMillis();
        long costTime = Math.round(1.0 * 1000 / count) * acquireCount;
        long expectedTime = costTime + latestPassedTime.get();
        if (expectedTime <= currentTime) {
            latestPassedTime.set(currentTime);
            return true;  // 立即放行
        }
        // 需要等待
        long waitTime = expectedTime - currentTime;
        if (waitTime <= maxQueueingTimeMs) {
            latestPassedTime.set(expectedTime);
            return true;  // 排队等待后放行
        }
        return false;  // 超时拒绝
    }
}
```

| 模式 | 原理 | 适用场景 |
|------|------|----------|
| 直接拒绝 | QPS 超过阈值直接抛异常 | 常规限流 |
| Warm Up | 缓慢提升阈值，防止冷启动冲垮 | 接口预热 |
| 排队等待 | 请求排队匀速通过，类似漏斗 | 削峰填谷 |

## 四、熔断降级实现

### 4.1 熔断器状态机

```
                   连续失败达到阈值
        ┌──────────────────────────┐
        ↓                          │
  ┌────────┐               ┌───────┴──────┐
  │ CLOSED │               │    OPEN      │
  │ (关闭)  │──────────────→│ (熔断打开)   │
  └────────┘               └──────┬───────┘
        ↑                          │
        │   探活成功（半开请求通过）│ 超时（默认 5s）
        │                          ↓
        │                  ┌──────────────┐
        └──────────────────│   HALF_OPEN  │
                           │   （半开）    │
                           └──────────────┘
                                    │
                    探活失败 → 回到 OPEN
```

### 4.2 DegradeSlot 熔断判断

```java
public class DegradeSlot extends AbstractLinkedProcessorSlot<DefaultNode> {

    @Override
    public void entry(Context context, ResourceWrapper resourceWrapper,
                      DefaultNode node, int count, Object... args) throws Throwable {
        performChecking(resourceWrapper, context);
        fireEntry(context, resourceWrapper, node, count, args);
    }

    void performChecking(ResourceWrapper resource, Context context) throws BlockException {
        List<CircuitBreaker> circuitBreakers = DegradeRuleManager
            .getCircuitBreakers(resource.getName());
        if (circuitBreakers == null) return;

        for (CircuitBreaker cb : circuitBreakers) {
            // 检查熔断状态
            if (!cb.tryPass(context)) {
                throw new DegradeException(cb.getRule().getLimitApp(), cb.getRule());
            }
        }
    }
}
```

### 4.3 三种熔断策略

```java
// 慢调用比例熔断
class SlowRequestRatioCircuitBreaker extends AbstractCircuitBreaker {

    @Override
    protected boolean matchesException(Entry entry) {
        // RT > 阈值（如 500ms）→ 记为慢调用
        return entry.getRt() > rule.getSlowRatioThreshold();
    }

    @Override
    public boolean tryPass(Context context) {
        if (currentState == State.CLOSED) {
            return true; // 关闭状态直接放行
        }
        if (currentState == State.OPEN) {
            // 检测是否到半开时间点
            return retryTimeoutArrived() && fromOpenToHalfOpen(context);
        }
        // HALF_OPEN: 允许一个探活请求
        return true;
    }
}

// 异常比例熔断
class ErrorRatioCircuitBreaker extends AbstractCircuitBreaker {
    @Override
    public boolean tryPass(Context context) {
        // 异常数 / 总请求数 > 阈值（如 50%）→ 熔断
        if (currentState == State.CLOSED) {
            long errorCount = stat.error();
            long totalCount = stat.total();
            if (totalCount < minRequestAmount) return true;
            double errorRatio = (double) errorCount / totalCount;
            if (errorRatio > maxErrorRatio) {
                // 触发熔断
                transformToOpen();
                return false;
            }
            return true;
        }
        // ... OPEN / HALF_OPEN 处理
    }
}

// 异常数熔断
class ErrorCountCircuitBreaker extends AbstractCircuitBreaker {
    @Override
    public boolean tryPass(Context context) {
        // 错误计数达到阈值（如 1000）→ 熔断
        // ... 类似实现
    }
}
```

## 五、核心亮点总结

| 特性 | 实现方式 | 优势 |
|------|---------|------|
| **滑动窗口** | 环形数组 + CAS + LongAdder | 无锁化高性能统计 |
| **责任链** | ProcessorSlotChain SPI 扩展 | 高度可扩展 |
| **限流算法** | 直接拒绝/WarmUp/排队等待 | 3 种模式覆盖所有场景 |
| **熔断降级** | 状态机 + 指标统计 | 自动恢复、探活 |
| **动态规则** | 控制台推送 + 内存规则更新 | 不改代码热生效 |

## 六、面试追问

> **Q：滑动窗口为什么用环形数组而不用链表？**
> A：环形数组支持 O(1) 的随机访问和更新，内存连续、CPU 缓存友好。链表每次要遍历，性能差一个数量级。

> **Q：Sentinel 和 Hystrix 的熔断有什么区别？**
> A：Hystrix 基于线程池隔离，Sentinel 基于滑动窗口 + 信号量。Sentinel 性能更高，且支持更丰富的限流策略。

> **Q：一个请求进来，Sentinel 怎么判断要不要限流？**
> A：通过责任链依次执行各个 Slot：先统计指标（StatisticSlot），再检查规则（FlowSlot → DegradeSlot）。最终决定放行还是拒绝。

---

**总结：** Sentinel 的滑动窗口算法是其高性能的基础，环形数组 + CAS 的实现非常精巧。结合灵活的责任链模式，既能保证核心限流熔断功能，又能通过 SPI 机制轻松扩展。源码值得每一个后端开发者精读。
