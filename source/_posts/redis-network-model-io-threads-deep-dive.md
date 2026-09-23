---
title: 【Redis 原理】Redis 网络模型深度解析：从单线程 Reactor 到多线程 IO（io-threads）
date: 2026-09-23 08:00:00
tags:
  - Redis
  - 网络编程
  - 面试
categories:
  - 中间件
  - Redis
author: 东哥
---

# 【Redis 原理】Redis 网络模型深度解析：从单线程 Reactor 到多线程 IO（io-threads）

## 面试官：Redis 为什么快？

这个问题能把 80% 的候选人分成两档。答「因为它是单线程」的属于第一档，能说清「单线程指的是什么、为什么不并行、6.0 之后又为什么引入多线程」的才算过关。

先把最容易混淆的一句话放在最前面：

> **Redis 的「单线程」指的是「命令执行是单线程」，而不是「整个 Redis 进程只有一个线程」。**

一个真实运行的 Redis 进程里至少有：

- **主线程（serverCron + 命令执行 + epoll 事件循环）**
- **bio 后台线程**：`bio_close_file`、`bio_aof_fsync`、`bio_lazy_free`（Redis 4.0 起，通常各 1 个，最大 3 个）
- **Redis 6.0 起的 io-threads**：默认关闭，最多 128 个，用来做网络读写和协议解析

所以「单线程」这个说法从 4.0 开始就已经不严格了。真正准确的说法是：**Redis 用单线程执行命令，用多线程处理网络 I/O 和一部分后台清理工作**。

## 一、单线程 Reactor：aeEventLoop 是怎么转起来的

Redis 的事件驱动核心是 `aeEventLoop`（`src/ae.c`），它同时管理两类事件：

| 事件类型 | 结构体 | 典型用途 |
| --- | --- | --- |
| 文件事件 | `aeFileEvent` | 客户端连接的读/写、监听套接字 |
| 时间事件 | `aeTimeEvent` | `serverCron`（每 100ms 一次） |

主循环的骨架极其简单：

```c
void aeMain(aeEventLoop *eventLoop) {
    eventLoop->stop = 0;
    while (!eventLoop->stop) {
        // 1. 处理到期的时间事件（serverCron 等）
        // 2. epoll_wait 拿就绪的文件事件
        // 3. 依次处理文件事件回调
        aeProcessEvents(eventLoop, AE_ALL_EVENTS | AE_CALL_BEFORE_SLEEP | AE_CALL_AFTER_SLEEP);
    }
}
```

`beforeSleep()` 是理解 Redis 性能的关键钩子，它做几件大事：

1. 把 `server.clients_pending_write` 里的待回复数据刷出去（`handleClientsWithPendingWrites()`）
2. `flushAppendOnlyFile()` —— AOF 的刷盘决策（always / everysec 策略在这里落地）
3. 处理 `unblocked_clients`（阻塞命令被唤醒的客户端）

命令执行路径上的文件事件处理器是 `readQueryFromClient`：

```
客户端发命令
  → epoll 触发可读
  → readQueryFromClient()
  → read() 读到 querybuf
  → processInputBuffer()
  → processMultibulkBuffer() 解析 RESP 协议
  → processCommand()            ← 在这里查命令表、鉴权、执行
  → addReply() 写入 client 输出缓冲
  → beforeSleep() 统一 write() 回客户端
```

注意 `addReply` **不会立刻 write**，而是把数据挂到客户端输出缓冲区，等下一轮 `beforeSleep` 批量写出。这个设计是 Redis 吞吐高的隐藏功臣：一次 `write` 系统调用可以合并多个命令的回复，减少了 syscall 次数和 TCP 小包。

## 二、为什么命令执行必须是单线程？

这是面试真正想听的。原因不是「作者偷懒」，而是一整套设计上的取舍：

**1）无锁就无竞争。** 所有数据结构（sds、dict、ziplist、skiplist、quicklist）全部按单线程访问设计，不需要任何锁。如果并行执行命令，`dict` 的渐进式 rehash、`expires` 字典的惰性删除都会立刻变成并发难题。

**2）原子性天然成立。** 一条命令从头到尾不被其他命令打断，这是 `INCR`、`SETNX`、`LPUSH` 这些原语能作为分布式锁/计数器基础的前提。多线程命令执行会直接摧毁这个语义。

**3）Lua 脚本和 MULTI/EXEC 的语义依赖单线程。** Redis 承诺脚本/事务期间不插入其他命令，这只有在单线程下才不需要额外机制。

**4）BIO 线程只做「不需要碰共享数据」的事。** `UNLINK` 的惰性释放、AOF fsync、关闭大文件——这些操作耗时但与内存数据无关，所以可以安全地甩给后台线程。

**5）内存分配器已经是线程安全的。** jemalloc 本身线程安全，但多线程同时分配会造成 arena 锁竞争，反而可能拖慢。

## 三、Redis 6.0 的多线程 IO：到底改了什么

单线程模型的天花板在网络 I/O 上。当 QPS 冲到十几万，`read()`/`write()` 和 RESP 协议解析占用的 CPU 时间开始逼近命令执行时间，主线程成了瓶颈。

Redis 6.0 的解法非常克制：**把「读请求、解析协议」和「写回复」这两段并行化，命令执行仍然死死钉在主线程。**

```
   [主线程 accept / 分发]
            │
   ┌────────┴────────┐
   │  IO 线程池 (N-1) │  ← 并行 read + RESP 解析
   └────────┬────────┘
            │  所有 IO 线程 join
   ┌────────┴────────┐
   │  主线程串行执行命令 │  ← 全局单线程，语义不变
   └────────┬────────┘
            │
   ┌────────┴────────┐
   │  IO 线程池 (N-1) │  ← 并行 write 回复
   └─────────────────┘
```

核心源码在 `networking.c`：

```c
int handleClientsWithPendingReadsUsingThreads(void) {
    if (!server.io_threads_active || !server.io_threads_do_reads) return 0;
    int processed = listLength(server.clients_pending_read);
    if (processed == 0) return 0;

    // 轮询把待读客户端分给各个 IO 线程
    listRewind(server.clients_pending_read, &li);
    while ((ln = listNext(&li))) {
        client *c = listNodeValue(ln);
        int target = c->id % server.io_threads_num;
        listAddNodeTail(io_threads_list[target], c);
    }

    // 唤醒所有 IO 线程
    for (int j = 0; j < server.io_threads_num; j++) {
        if (j == 0) continue;                 // 0 号是主线程
        pthread_mutex_lock(&io_threads_mutex[j]);
        pthread_cond_signal(&io_threads_cond[j]);
    }
    listRewind(io_threads_list[0], &li);
    while ((ln = listNext(&li))) {            // 主线程也干一份活
        client *c = listNodeValue(ln);
        readQueryFromClient(conn);
    }
    // 等待其余线程完成
    for (int j = 1; j < server.io_threads_num; j++) {
        pthread_mutex_lock(&io_threads_mutex[j]);
        while (io_threads_pending[j] != 0) pthread_cond_wait(&io_threads_cond[j], &io_threads_mutex[j]);
        pthread_mutex_unlock(&io_threads_mutex[j]);
    }
    ...
}
```

三个关键事实：

- **`io_threads_num` 包含主线程**。配 `io-threads 4` 意味着「1 主 + 3 IO」，不是 4 个额外线程。
- **`io-threads-do-reads` 默认是 `no`**。默认只并行写回复，读+解析要显式开启。
- **命令执行阶段一定是串行的**，所有 IO 线程在这个阶段都被 join 掉了。

### 配置建议

```
io-threads 4              # 4C 机器推荐 2~3；8C 推荐 4；不要超过 8
io-threads-do-reads yes   # 读多且大 value 场景收益明显
```

官方基准数据显示：在 4 核机器上 `io-threads 4` 相比单线程能提升近一倍吞吐；但 **8 线程以上收益急剧衰减甚至倒退**，因为主线程 join 的同步开销、以及 cache line 在核间弹跳的成本会吃掉收益。

> 实测经验：`redis-cli --intrinsic-latency 100` 先看基线。如果压测时 `redis-cli --latency` 显示延迟主要来自排队而不是 CPU，说明瓶颈在命令执行，开 io-threads 毫无意义。

## 四、面试常见追问

**追问 1：io-threads 开着，为什么 `INCR` 结果还是准确的？**
因为并行只发生在「读 socket 到 querybuf」和「把 reply 写回 socket」两段，`processCommand` 全程在主线程串行执行，`INCR` 的读-改-写之间不会被任何其他命令插入。

**追问 2：既然要并行，为什么不干脆让命令也并行？**
会破坏原子性语义（Lua、MULTI、`SETNX`、`INCR`），需要引入大量细粒度锁，且 `dict` 渐进式 rehash、惰性删除、`WATCH` 乐观锁都得重写。收益远小于代价。Redis 的选择是「保住语义，只优化 I/O」。

**追问 3：单线程怎么抗住大 key 删除？**
用 `UNLINK` 替代 `DEL`，把内存释放丢给 `bio_lazy_free` 后台线程；同时 Redis 6.0+ 支持 `lazyfree-lazy-eviction`、`lazyfree-lazy-expire`，让淘汰和过期删除也异步化。

**追问 4：`beforeSleep` 和 `serverCron` 谁更重要？**
`beforeSleep` 每轮事件循环都执行，是回复刷出、AOF flush 的关键路径；`serverCron` 默认 100ms 一次（`hz 10`），负责过期键采样、rehash 推进、客户端超时、持久化触发等周期性维护。前者影响延迟，后者影响正确性与内存回收节奏。

**追问 5：既然单线程，为什么还会 CPU 100%？**
常见原因：大 key 的 `HGETALL`/`SMEMBERS`/`DEL`（命令执行本身慢）、`KEYS` 全库扫描、复杂度 O(N) 的 Lua 脚本、大量 `expire` 集中触发、以及 AOF rewrite 期间的内存与 fork COW 开销。用 `SLOWLOG` + `--hotkeys` 定位。

## 五、小结

| 维度 | 结论 |
| --- | --- |
| 单线程指什么 | 命令执行串行，无锁、原子性天然保证 |
| 多线程指什么 | bio 后台线程（4.0）+ 网络 I/O 线程（6.0） |
| io-threads 推荐值 | 4~8，含主线程，超过 8 基本无收益 |
| 何时开启 | 压测确认瓶颈在网络 I/O 而非命令执行时 |
| 语义是否变化 | 不变，命令依然全局串行 |

把这张表记住，Redis 网络模型这道题基本就稳了。真正拉开差距的不是背结论，而是能说出「为什么这么设计、代价是什么、什么时候不该用」。
