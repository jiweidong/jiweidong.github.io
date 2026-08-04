---
title: 【中间件原理】时间轮算法（TimingWheel）深度解析：从 Kafka 到 Netty 的延迟任务实现
date: 2026-08-04 08:30:00
tags:
  - Java
  - 中间件
  - 算法
  - 源码
categories:
  - Java
  - 中间件
author: 东哥
---

# 【中间件原理】时间轮算法（TimingWheel）深度解析：从 Kafka 到 Netty 的延迟任务实现

## 引子：延迟任务为什么难做？

**面试官：** 假如你要实现一个延迟消息队列——用户下单 30 分钟后未支付就自动关闭订单，你会怎么做？

**候选人：** 最简单的方案是用 `ScheduledExecutorService.schedule()`，或者用一个后台线程定时扫描数据库里的订单表……

**面试官：** 那如果订单量是百万级、千万级呢？每 1 秒扫一次全表？延迟精度怎么保证？定时任务线程怎么管理？

**候选人：** ……这就引出今天的主角了——**时间轮（TimingWheel）算法**。

## 一、传统延迟任务方案的痛点

### 1.1 方案一：定时扫描数据库

```java
@Scheduled(fixedDelay = 1000)
public void scanExpiredOrders() {
    // 每 1 秒扫描一次超时未支付订单
    List<Order> orders = orderMapper.selectExpiredOrders(now);
    orders.forEach(order -> closeOrder(order.getId()));
}
```

痛点：
- **扫描粒度粗**：1 秒扫一次，延迟误差最高 1 秒；想提高精度就要扫得更频繁，DB 压力成倍增长
- **空扫浪费**：绝大多数扫描没有数据变更，白白消耗 DB 与 CPU
- **大数据量下不可扩展**：千万订单全表扫描是灾难

### 1.2 方案二：JDK 延迟队列 DelayQueue / ScheduledThreadPoolExecutor

```java
ScheduledExecutorService scheduler = Executors.newScheduledThreadPool(4);
scheduler.schedule(() -> closeOrder(orderId), 30, TimeUnit.MINUTES);
```

痛点：
- **堆结构 O(log n)**：`ScheduledThreadPoolExecutor` 内部用**小顶堆**（DelayQueue），插入和删除都是 O(log n)
- **任务量大时堆操作有竞争**：大量任务同时提交，堆调整频繁，锁竞争激烈
- 高并发下千万级任务，堆的 log n 也不可小觑，且**堆无法做到 O(1) 级别的插入**

### 1.3 方案三：时间轮（TimingWheel）

**核心思想**：用一个环形数组 + 刻度指针，把"什么时候执行"映射到"转第几圈、停在第几格"，插入任务 **O(1)**，推进指针 **O(1)**。

这就是 Kafka、Netty（HashedWheelTimer）、Redisson（延迟队列底层）、XXL-Job（部分场景）都在用的算法。

## 二、时间轮基础版：单层时间轮

### 2.1 数据结构

想象一个钟表：有 60 个刻度（60 个槽位），一根秒针每秒走一格。

```java
public class SimpleTimingWheel {
    // 槽位数组，每个槽位挂一个任务链表
    private final List<Task>[] slots;
    private final int tickDuration;  // 每格代表的时间跨度，比如 1 秒
    private final int wheelSize;     // 槽位数量，比如 60
    private int currentIndex = 0;    // 当前指针位置

    public void addTask(Task task, int delaySeconds) {
        // 计算目标槽位：当前指针 + delay 对应的格数，再取模
        int targetSlot = (currentIndex + delaySeconds) % wheelSize;
        slots[targetSlot].add(task);
    }

    public void advance() {
        // 指针前进一步，执行该槽位上到期的所有任务
        List<Task> dueTasks = slots[currentIndex];
        dueTasks.forEach(Task::run);
        currentIndex = (currentIndex + 1) % wheelSize;
    }
}
```

### 2.2 问题：延迟超过一圈怎么办？

上面的实现有个明显缺陷：如果轮盘 60 格、每格 1 秒，延迟 90 秒的任务，`(0 + 90) % 60 = 30`，会被放到第 30 格——但它在第 30 秒就会被执行，**早了 60 秒**！

解法是给任务增加**圈数（rounds）**字段：

```java
public class Task {
    private final Runnable action;
    private int remainingRounds;  // 还需要转几圈才到期
}

public void addTask(Task task, int delaySeconds) {
    int ticks = delaySeconds / tickDuration;      // 需要走多少格
    int targetSlot = (currentIndex + ticks) % wheelSize;
    task.remainingRounds = ticks / wheelSize;     // 圈数
    slots[targetSlot].add(task);
}

public void advance() {
    List<Task> dueTasks = slots[currentIndex];
    // 只执行 remainingRounds == 0 的任务，其余任务圈数减一
    dueTasks.removeIf(t -> {
        if (t.remainingRounds > 0) {
            t.remainingRounds--;
            return false;  // 还没到期，留在槽里
        }
        t.run();
        return true;
    });
    currentIndex = (currentIndex + 1) % wheelSize;
}
```

### 2.3 单层时间轮的局限

- 圈数很大的任务，指针每转一圈都要**遍历一次**槽位链表，检查 `remainingRounds`
- 刻度固定，**精度与容量互相制约**：格子细（精度高）则容量小，格子粗则延迟误差大
- 大量任务堆积在少数槽位时，链表遍历退化成 O(n)

## 三、分层时间轮：Kafka 的 Purgatory 实现

### 3.1 为什么分层？

Kafka 的 **DelayedOperationPurgatory**（延迟操作收容所）用来管理延迟的生产/消费请求，任务量巨大且延迟跨度从毫秒到数小时。单层时间轮满足不了，于是 Kafka 实现了**分层时间轮**：

```
第 2 层（小时轮）： 24 格 × 1 小时 = 24 小时
第 1 层（分钟轮）： 60 格 × 1 分钟 = 60 分钟
第 0 层（秒级轮）： 20 格 × 1 秒   = 20 秒
```

**规则**：任务总是优先放入**最底层**（粒度最细的轮）。当任务的延迟超过当前层的覆盖范围时，就升级到上一层。

### 3.2 层级之间的"降级"机制

看一个例子：延迟 3 小时的任务。

1. 放入小时轮：`第 2 层，当前指针 + 3 格`
2. 1 小时后，小时轮指针走到该格，任务**降级（downgrade）**到分钟轮
3. 分钟轮继续走，60 分钟后任务降级到秒级轮
4. 秒级轮指针到达时，任务到期执行

```java
// Kafka TimingWheel 核心逻辑（简化）
public void add(TimerTaskEntry entry) {
    long expiration = entry.expirationMs;
    if (expiration < currentTime + tickMs) {
        // 已经过期，直接执行
        entry.cancel();
        taskExecutor.execute(entry.timerTask);
    } else if (expiration < currentTime + interval) {
        // 在当前轮的覆盖范围内，计算槽位
        long ticks = (expiration - currentTime) / tickMs;
        int slotIndex = (int) (ticks & (wheelSize - 1));  // 用位运算替代取模
        buckets[slotIndex].add(entry);
    } else if (overflowWheel == null) {
        // 超出当前轮范围，创建/复用上一层时间轮
        addOverflowWheel();
        overflowWheel.add(entry);
    } else {
        overflowWheel.add(entry);
    }
}
```

注意几个 Kafka 实现细节：
- **`tickMs` 与 `wheelSize` 都是 2 的幂**，所以取模可以用 `& (wheelSize - 1)` 位运算，性能更好
- 时间轮是**惰性创建**的：`overflowWheel` 只在需要时才 new
- 槽位用 `TimerTaskList`（双向链表 + 过期时间戳）承载，同时维护了**过期时间**，用于快速判断槽内任务是否全部到期

### 3.3 Kafka 时间轮 vs 简单实现的关键差异

| 维度 | 简单时间轮 | Kafka 分层时间轮 |
|------|-----------|-----------------|
| 容量 | 固定，受轮盘大小限制 | 层级扩展，容量近乎无限 |
| 大延迟任务 | 圈数遍历开销大 | 自动升级到高层轮 |
| 槽位查找 | O(1) | O(1)，层级数恒定（log 级别） |
| 到期判断 | 遍历链表检查圈数 | 链表头带过期时间，惰性清理 |
| 线程模型 | 单线程推进 | 独立线程推进 + 任务线程池执行 |

**Kafka 时间轮的驱动线程**：`Timer` 类内部有一个后台线程，以 `tickMs` 为周期调用 `advanceClock()`，将 `currentTime` 推进，并处理到期槽位。

## 四、Netty 的 HashedWheelTimer

Netty 作为高性能网络框架，超时管理（连接超时、请求超时）用的就是 `HashedWheelTimer`。它的设计：

```java
public class HashedWheelTimer implements Timer {
    private final HashedWheelBucket[] wheel;   // 槽位数组
    private final long tickDuration;            // 每个 tick 的时长（纳秒）
    private final int mask;                     // wheel.length - 1，用于位运算取模
    private volatile long startTime;            // 启动时间，所有任务的相对基准
    private final Queue<HashedWheelTimeout> timeouts = 
            PlatformDependent.newMpscQueue();   // MPSC 无锁队列缓存新任务
}
```

**Netty 与 Kafka 的实现差异**：

1. **任务先入 MPSC 队列**：新任务不直接进轮盘，先放无锁队列，由工作线程批量搬入轮盘，**减少锁竞争**（Netty 追求极致的无锁化）
2. **相对时间基准**：所有任务的 deadline 是相对 `startTime` 的纳秒数，避免系统时间被修改导致混乱
3. **bucket 是链表**：每个槽位一个 `HashedWheelTimeout` 双向链表

```java
// 计算目标槽位
private static long waitForNextTick() { ... }

public void expireTimeouts(long deadline) {
    // 处理队列中已到期的任务
    HashedWheelTimeout timeout = pollTimeout();
    // 计算剩余轮数
    long ticks = ((deadline - timeout.deadline) + tickDuration - 1) / tickDuration;
    int idx = (int) (timeout.remainingRounds & mask);
    ...
}
```

## 五、时间轮的 Java 手写实现（面试加分项）

面试时手写一个**单层时间轮 + 圈数**版本，足够展示功底：

```java
public class TimingWheelDemo {

    static class TimerTask {
        Runnable action;
        long delayMs;
        long rounds;       // 剩余圈数
        TimerTask next;    // 链表指针

        TimerTask(Runnable action, long delayMs, long rounds) {
            this.action = action;
            this.delayMs = delayMs;
            this.rounds = rounds;
        }
    }

    private final TimerTask[] wheel;
    private final int wheelSize;
    private final long tickMs;
    private final ScheduledExecutorService executor;
    private int currentIndex = 0;
    private long currentTimeMs;

    public TimingWheelDemo(int wheelSize, long tickMs) {
        this.wheelSize = wheelSize;
        this.tickMs = tickMs;
        this.wheel = new TimerTask[wheelSize];
        this.currentTimeMs = System.currentTimeMillis();
        this.executor = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "timing-wheel");
            t.setDaemon(true);
            return t;
        });
        // 每 tickMs 推进一次指针
        executor.scheduleAtFixedRate(this::advance, tickMs, tickMs, TimeUnit.MILLISECONDS);
    }

    public void addTask(Runnable action, long delayMs) {
        long targetTime = System.currentTimeMillis() + delayMs;
        long ticks = (targetTime - currentTimeMs) / tickMs;
        long rounds = ticks / wheelSize;
        int index = (int) ((currentIndex + ticks) % wheelSize);
        TimerTask task = new TimerTask(action, targetTime, rounds);
        synchronized (this) {
            task.next = wheel[index];
            wheel[index] = task;
        }
    }

    private void advance() {
        currentTimeMs += tickMs;
        currentIndex = (currentIndex + 1) % wheelSize;
        TimerTask head = wheel[currentIndex];
        if (head == null) return;
        wheel[currentIndex] = null;
        // 遍历链表，执行到期任务
        while (head != null) {
            TimerTask next = head.next;
            if (head.rounds > 0) {
                head.rounds--;   // 未到期，圈数减一
                addBack(head);   // 重新入槽
            } else {
                executor.submit(head.action);  // 到期执行
            }
            head = next;
        }
    }

    private void addBack(TimerTask task) {
        synchronized (this) {
            task.next = wheel[currentIndex];
            wheel[currentIndex] = task;
        }
    }
}
```

**手写时要主动点出的设计点**：
- 为什么用**环形数组**而不是优先队列？（O(1) 插入，无堆调整）
- 为什么任务用**链表**？（一个槽位多个任务，且到期时间相同）
- 为什么指针推进用 `scheduleAtFixedRate`？（驱动线程与业务线程隔离）
- 边界情况：延迟小于一个 tick 怎么处理？（立即执行或就近入槽）

## 六、时间轮的应用场景盘点

| 中间件 | 使用场景 | 实现特点 |
|--------|---------|---------|
| Kafka | 延迟生产/延迟消费请求（Purgatory） | 分层时间轮，tick=1ms，wheelSize=20 |
| Netty | 连接超时、空闲检测 | HashedWheelTimer，MPSC 队列 |
| Dubbo | 心跳超时、请求超时 | 复用 Netty 的 HashedWheelTimer |
| Redisson | 分布式延迟队列、看门狗续期 | 基于 Netty 时间轮 |
| RocketMQ | 延迟消息（18 个等级） | 定时消息用时间轮 + 定时扫描 |
| XXL-Job | 任务调度超时控制 | 时间轮管理触发窗口 |

## 七、面试官追问环节

### Q1：时间轮和 DelayQueue 怎么选？

- **时间轮**：插入 O(1)，适合**海量任务 + 相对均匀分布**的场景（Kafka Purgatory 千万级任务）
- **DelayQueue（堆）**：插入 O(log n)，但支持**任意精度**、删除指定任务方便，JDK 内置无需依赖
- 工程上常**两者结合**：时间轮负责粗粒度调度，DelayQueue 管理时间轮本身（如 Kafka 用一个 DelayQueue 驱动时间轮推进）

### Q2：时间轮的精度受什么影响？

两个因素：**tick 时长**（指针每步的时间粒度）和 **槽位数量**。tick 越小精度越高但 CPU 开销越大；实际误差还受驱动线程调度影响。Kafka 选择 tick=1ms，足以覆盖大部分延迟场景。

### Q3：时间轮能保证任务准时执行吗？

不能严格保证。它是**近似定时器（approximate timer）**：任务的实际执行时间落在 `[deadline, deadline + tickMs)` 区间内。需要毫秒级精确执行的场景（如数据库超时）要慎用。

### Q4：如果大量任务同时到期，会怎样？

会集中执行，造成"惊群"——这是所有定时器的共性问题。缓解手段：任务执行用**独立线程池**异步化，避免阻塞时间轮驱动线程；必要时做**任务合并/批量处理**。

### Q5：时间轮为什么用位运算取模？

Kafka 的 `wheelSize` 取 2 的幂（如 20→实际用 2 的幂扩展），这样 `index = ticks & (wheelSize - 1)` 替代 `%` 运算。位运算在 JIT 后是单条指令，比整数除法快一个数量级——在每毫秒推进一次的驱动线程里，这点优化是值得的。

## 八、总结

时间轮算法的本质是**用空间换时间**：用一个环形数组 + 指针，把"精确到时刻"的定时问题转化为"转圈数刻度"的近似定时问题，换来 O(1) 的插入与推进。

掌握三个层次，面试就能从容应对：
1. **基础层**：环形数组 + 指针 + 槽位链表，理解 O(1) 的本质
2. **进阶层**：圈数字段解决大延迟，分层时间轮解决容量扩展
3. **工程层**：Kafka 的位运算优化、Netty 的 MPSC 队列、惰性创建上层轮等生产级细节
