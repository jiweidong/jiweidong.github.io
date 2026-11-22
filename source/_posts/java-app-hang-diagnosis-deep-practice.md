---
title: 【生产实战】Java 应用「假死」诊断全链路：进程活着、请求全超时——三池共振、线程栈判读与 GC/锁归因
date: 2026-11-22 08:00:00
tags:
  - Java
  - 故障排查
  - 线程池
  - JVM
  - 性能调优
categories:
  - 生产实战
author: 东哥
---

# 【生产实战】Java 应用「假死」诊断全链路

## 前言

线上最让人后背发凉的一类故障，不是进程挂了，而是**进程还活着**：

- 容器状态 `Running`，健康检查端口 `telnet` 得通；
- `top` 看 CPU 不高、内存也没打满；
- 但业务请求全部超时，网关一片 504，日志停在几分钟前不再滚动；
- 重启之后立刻恢复，过几天又复发。

这类现象业内俗称「假死」。它和 OOM、崩溃、CPU 100% 的区别在于：**JVM 还在跑，但已经没有能力处理新请求了**。很多人第一反应是「加内存」「重启了事」，结果根因没找到，故障按周期复发。

这篇文章把假死拆成一套可复用的诊断模型：先定位是**哪个池子**被耗尽，再判断是**排队、阻塞还是停顿**，最后用「超时预算 + 有界队列 + 隔离」做根治。

---

## 一、先分清四种「不响应」

| 现象 | 典型特征 | 主要根因 |
|---|---|---|
| 进程退出 | 容器重启、exit code 137/1 | OOM Kill、启动失败 |
| CPU 100% | load 高、火焰图集中在业务方法 | 死循环、正则回溯、频繁 GC |
| **假死** | CPU 不高、端口可连、请求全超时 | 线程池/连接池耗尽、锁阻塞、GC 停顿 |
| 半死 | 部分接口正常、部分超时 | 单一下游依赖故障、线程池隔离不当 |

关键判断：**CPU 低 + 请求全超时 ≈ 所有工作线程都在「等」**。等什么？等锁、等连接、等 socket 读、等 GC 结束。

---

## 二、假死的六类根因模型

### 2.1 Tomcat 工作线程打满

Spring Boot 默认 `server.tomcat.threads.max=200`，`accept-count=100`。当单请求 RT 从 50ms 涨到 2s，按 Little's Law：

```
并发线程数 = QPS × RT
```

1000 QPS × 2s = 2000 个并发，200 个线程瞬间打满，剩下的请求堆在 accept 队列（100 个）里，再多的直接被内核拒绝或挂起。**表现就是端口能连、请求没响应**。

### 2.2 业务线程池 + 无界队列

```java
// 典型事故写法：无界队列 + 默认拒绝策略
new ThreadPoolExecutor(8, 8, 0, TimeUnit.MILLISECONDS,
        new LinkedBlockingQueue<>()); // 容量 Integer.MAX_VALUE
```

无界队列意味着 `maximumPoolSize` 永远不生效，任务无限堆积。堆内存被任务对象撑爆之前，接口早就全部超时了。更隐蔽的是：**队列里的任务还在执行，日志看起来「系统还在工作」，其实处理的是几分钟前的请求**。

### 2.3 数据库连接池耗尽

HikariCP 默认 `connectionTimeout=30s`。一旦出现慢 SQL 或长事务，连接被占满，后续请求全部卡在 `getConnection()`：

```
java.sql.SQLTransientConnectionException:
  HikariPool-1 - Connection is not available,
  request timed out after 30000ms
```

注意：这个异常往往**不会出现在日志里**，因为请求早就被上游超时切断了，异常抛出时线程已经没人在等。

### 2.4 GC 停顿

Full GC 一次 3~10 秒，期间所有应用线程停在 SafePoint。如果堆大、对象晋升快，Full GC 可能连续触发，表现为「周期性假死几十秒」。

判据：`jstat -gcutil <pid> 1000` 看 `FGC` 计数是否在涨、`FGCT` 是否持续增加。

### 2.5 锁阻塞与死锁

- `synchronized` 锁住了一个被所有请求共享的对象；
- `ReentrantLock` 忘记 `unlock()`；
- 数据库行锁等待（`innodb_lock_wait_timeout` 默认 50s）；
- 分布式锁续期线程挂了，锁永远不释放。

### 2.6 连接建立阶段阻塞（最容易被忽略）

```java
// 没有 connectTimeout 的 HttpClient
HttpClient.newHttpClient()
    .send(HttpRequest.newBuilder(uri).build(), BodyHandlers.ofString());
```

DNS 解析慢、SYN 丢包、对端半开连接，都会让线程卡在 `socketConnect` / `socketRead0`，而且**没有超时**。这类线程在 jstack 里是 `RUNNABLE`，看起来「很忙」，实际什么都没干。

---

## 三、黄金五分钟：保留现场再重启

假死排查最大的敌人是「重启」。重启会销毁所有证据。正确顺序：

### 3.1 三份快照

```bash
PID=$(jps -l | grep your-app | awk '{print $1}')

# 1) 线程栈，间隔 5 秒采 3 次（看线程是否在动）
for i in 1 2 3; do jstack -l $PID > /tmp/jstack-$i.txt; sleep 5; done

# 2) GC 与堆
jstat -gcutil $PID 1000 10 > /tmp/jstat.txt

# 3) 原生内存与系统态
jcmd $PID VM.native_memory summary > /tmp/nmt.txt
ss -s > /tmp/ss.txt
netstat -anp | awk '{print $6}' | sort | uniq -c | sort -rn | head
```

### 3.2 线程栈判读表

| 栈顶特征 | 含义 | 下一步 |
|---|---|---|
| `java.net.SocketInputStream.socketRead0` | 等下游响应 | 查下游 RT、是否设了 readTimeout |
| `sun.nio.ch.SocketChannelImpl.checkConnect` | 建连阻塞 | 查 DNS、网络、connectTimeout |
| `com.zaxxer.hikari.pool.HikariPool.getConnection` | 连接池耗尽 | 查慢 SQL、长事务、连接泄漏 |
| `java.lang.Object.wait` + `ThreadPoolExecutor.getTask` | 线程空闲 | 说明瓶颈不在线程池 |
| `BLOCKED (on object monitor)` | 锁竞争 | 看持锁线程在干什么 |
| `TIMED_WAITING (parking)` + `Condition.await` | 等条件 | 查队列、信号是否丢失 |

**关键技巧**：把三份 jstack 里同一线程名的栈对比。如果 200 个 `http-nio-8080-exec-*` 三次都停在同一个方法，那就是稳定阻塞，不是偶发抖动。

### 3.3 一条命令定位「谁在持锁」

```bash
# 找出 BLOCKED 线程和它等待的锁地址，再反查持有者
grep -A 3 "BLOCKED" /tmp/jstack-1.txt | head -40
```

---

## 四、三池共振：假死从来不是单点问题

真实故障往往是链式的：

```
下游 A 变慢（RT 50ms → 3s）
  → 业务线程池排队（无界队列）
    → 请求持有 DB 连接不释放
      → HikariCP 耗尽
        → Tomcat 线程全部卡在 getConnection
          → 新请求进 accept 队列
            → 网关 504
```

这就是「三池共振」：**线程池、连接池、Tomcat 线程池**任何一个没有边界，都会把局部抖动放大成全局假死。

### 4.1 超时预算必须逐层递减

| 层级 | 配置 | 建议 |
|---|---|---|
| 网关 | `proxy_read_timeout` | 10s |
| Web 层 | `spring.mvc.async.request-timeout` | 8s |
| 业务线程池 | `Future.get(5, SECONDS)` | 5s |
| HTTP 客户端 | connect 1s / read 3s | 3s |
| DB | `socketTimeout=3000` | 3s |
| Redis | `timeout=500ms` | 500ms |

原则：**上游超时必须小于下游超时之和**，否则上游已经断开，下游还在傻等，资源白白占用。

### 4.2 有界队列 + 快速失败

```java
ThreadPoolExecutor executor = new ThreadPoolExecutor(
    16, 64,
    60, TimeUnit.SECONDS,
    new ArrayBlockingQueue<>(200),          // 有界
    new ThreadFactoryBuilder().setNameFormat("biz-pool-%d").build(),
    new ThreadPoolExecutor.AbortPolicy()     // 快速失败，别默默排队
);
```

配套：`RejectedExecutionHandler` 里打点 + 返回 503，让上游立刻重试或降级，而不是让请求在队列里「慢性死亡」。

### 4.3 隔离舱

按依赖拆分线程池：调用推荐服务一个池、调用支付一个池。推荐挂了不会拖死支付。这就是舱壁模式（Bulkhead）的核心价值。

### 4.4 看门狗

```java
ScheduledExecutorService watchdog = Executors.newSingleThreadScheduledExecutor();
watchdog.scheduleAtFixedRate(() -> {
    int active = executor.getActiveCount();
    int queued = executor.getQueue().size();
    if (queued > 150) {
        log.error("pool_backlog active={} queued={}", active, queued);
        Metrics.counter("pool.reject.risk").increment();
    }
}, 10, 10, TimeUnit.SECONDS);
```

假死的可怕之处是「静默」。任何池子都必须有**队列深度、活跃线程数、等待时长**三个指标，并且配置告警。

---

## 五、一个真实案例的复盘

某订单服务每周五下午固定假死，持续 10~20 分钟，重启恢复。按上面的流程走了一遍：

**第一次 jstack**：200 个 `http-nio-8080-exec-*` 全部卡在 `HikariPool.getConnection`，说明连接池耗尽。

**查连接池**：`active=50, idle=0, waiting=37`，HikariCP 最大连接数 50，确实满了。

**查谁占着连接**：`SHOW PROCESSLIST` 看到 12 个连接处于 `Sleep` 状态超过 300 秒，对应的是「导出报表」接口——它在拿到连接后做了一次远程文件上传，上传耗时 5 分钟，期间事务一直没提交。

**根因**：报表导出把「数据库查询」和「远程上传」放在同一个事务里，连接被长时间占用；周五下午是报表高峰，十几个并发就把 50 个连接吃光，其他接口全部排队。

**修复**：

1. 拆事务：先查数据（几百毫秒），提交事务释放连接，再做上传；
2. 导出走独立连接池（10 个连接），与在线业务隔离；
3. 给上传加 30 秒超时；
4. 加「连接持有时间 > 3s」的告警。

上线后同类故障再没出现。这个案例的教训是：**连接池耗尽从来不是「池子太小」，而是「有人占着不还」**。盲目调大 `maximumPoolSize` 只会把数据库连接数打满，把故障从应用层转移到 DB 层。

### 5.1 一个反直觉的结论

假死排查中，**「加资源」几乎总是错的**。线程池小了加线程、连接池小了加连接、内存小了加内存——这些操作会让系统在更高水位上运行，故障时的爆炸半径更大。正确顺序永远是：

```
先止血（限流/降级/重启） → 再定位（栈/池/GC） → 最后扩容（有数据支撑）
```

扩容是结论，不是起点。

---

## 六、面试追问

**Q：CPU 不高但接口全超时，你怎么排查？**

先确认是「等」还是「算」：`top -Hp` 看线程级 CPU，若都很低，基本是阻塞。然后三份 jstack 对比，看工作线程统一停在哪：socketRead、getConnection、BLOCKED、park。再对照连接池指标和 GC 日志，判断是下游慢、池子小还是锁。

**Q：线程池核心线程数怎么定？**

CPU 密集型 ≈ 核数 + 1；IO 密集型用 `核数 × (1 + 等待时间/计算时间)`，但更靠谱的是压测 + Little's Law 反推，并且一定要配队列上限和拒绝策略。容器环境还要注意 CPU Limit 会影响 `availableProcessors()`。

**Q：为什么加了内存假死反而更频繁？**

堆更大 → Full GC 单次停顿更长、回收周期更久；同时无界队列能堆更多任务，故障从「快速失败」变成「长时间假死」。加内存不解决排队问题，只会延后爆发。

**Q：优雅停机能避免假死吗？**

不能。优雅停机解决的是发布期流量排空，假死是运行期资源耗尽。两者属于不同层面，但都需要「有界 + 超时 + 可观测」。

---

## 七、总结

1. 假死 = 线程都在等，不是算不过来。先分清等锁、等连接、等 IO 还是等 GC。
2. **先留现场再重启**：三份 jstack + jstat + NMT，比重启一百次都有用。
3. 一切池子必须有界，一切调用必须有超时，超时预算逐层递减。
4. 三池共振是放大器的本质：局部慢 → 排队 → 占资源 → 全局死。
5. 可观测性要盯「队列深度」和「等待时长」，而不是只看 QPS 和错误率。

把这套模型固化成 runbook，下次告警响起时，你需要的不是运气，而是顺序。
