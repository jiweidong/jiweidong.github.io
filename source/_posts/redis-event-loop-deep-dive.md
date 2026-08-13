---
title: 【Redis 原理】Redis 事件循环深度解析：文件事件、时间事件与 IO 多路复用
date: 2026-08-13 08:00:00
tags:
  - Redis
  - 源码
  - 面试
categories:
  - 中间件
  - Redis
author: 东哥
---

# 【Redis 原理】Redis 事件循环深度解析：文件事件、时间事件与 IO 多路复用

## 面试官：Redis 为什么快？单线程模型到底是怎么运作的？

「Redis 基于内存、单线程、IO 多路复用」——这几乎是背烂了的答案。但再往深问一层：「单线程是怎么同时处理那么多连接的？文件事件和时间事件是什么关系？为什么 6.0 又引入了多线程？」

这篇文章从 Redis 源码（ae.c / ae_epoll.c）出发，把事件循环（Event Loop）的底层机制彻底讲透。

## 一、Redis 为什么选单线程 + IO 多路复用？

### 1.1 核心原因

1. **内存操作极快**：Redis 命令基本都是内存读写，微秒级完成，CPU 不是瓶颈；
2. **避免上下文切换和锁竞争**：多线程要处理并发安全（加锁、原子操作），单线程天然无锁，杜绝了线程切换开销；
3. **IO 多路复用**：单个线程可以同时监听成千上万个 socket 连接的就绪事件，只在有数据可读/可写时才处理，非阻塞 IO 让线程不会被某个慢连接拖住；
4. **模型简单**：没有竞态条件，没有死锁问题，调试和维护成本极低。

### 1.2 单线程模型的瓶颈

单线程意味着**一条慢命令会阻塞所有请求**，所以：

- 禁止使用 `KEYS *`、`SMEMBERS`（大集合）等 O(N) 命令；
- `SLOWLOG` 慢查询要监控，复杂 Lua 脚本要谨慎；
- 大 Key 操作（大 Value 的 `GET`/`DEL`）会阻塞事件循环。

> 注意：Redis 6.0 起引入了**多线程 IO**，但只用于网络读写（read/write 系统调用），命令执行仍然在单线程。原因：网络 IO 才是高并发下的主要开销，命令执行本身足够快。

## 二、事件循环总体架构

Redis 的事件驱动框架在 `ae.c` 中，核心数据结构：

```c
typedef struct aeEventLoop {
    int maxfd;                    // 当前最大文件描述符
    aeFileEvent *events;          // 文件事件表（监听的事件）
    aeFiredEvent *fired;          // 就绪事件表（epoll 返回的）
    aeTimeEvent *timeEventHead;   // 时间事件链表
    int stop;                     // 停止标志
    void *apidata;                // 底层多路复用数据（epoll/kqueue/select）
    aeBeforeSleepProc *beforesleep; // 循环开始前的回调
    aeBeforeSleepProc *aftersleep;  // 循环结束后的回调
} aeEventLoop;
```

主循环在 `aeMain`：

```c
void aeMain(aeEventLoop *eventLoop) {
    eventLoop->stop = 0;
    while (!eventLoop->stop) {
        aeProcessEvents(eventLoop, AE_ALL_EVENTS | AE_CALL_BEFORE_SLEEP | AE_CALL_AFTER_SLEEP);
    }
}
```

**一次循环 = 处理时间事件 + 阻塞等待文件事件 + 处理就绪的文件事件**，周而复始。

## 三、文件事件（File Event）

文件事件抽象了 **socket 的可读/可写** 状态，对应结构：

```c
typedef struct aeFileEvent {
    int mask;                        // AE_READABLE / AE_WRITABLE
    aeFileProc *rfileProc;           // 读事件处理器
    aeFileProc *wfileProc;           // 写事件处理器
    void *clientData;                // 关联数据（如 client）
} aeFileEvent;
```

### 3.1 Redis 的三种文件事件处理器

| 处理器 | 对应事件 | 作用 |
| --- | --- | --- |
| 连接应答处理器 | 监听 socket 可读 | 接受新连接，创建 client，并把 client 的 socket 注册为可读事件 |
| 命令请求处理器 | client socket 可读 | 读取并解析客户端发来的命令，执行命令，把结果写入输出缓冲区 |
| 命令回复处理器 | client socket 可写 | 把输出缓冲区中的回复数据写回客户端，写完删除可写事件监听 |

处理流程（以一次 `SET key value` 为例）：

```
1. 客户端 connect → 监听 socket 可读 → 连接应答处理器 accept，创建 client
2. client 发送命令 → client socket 可读 → 命令请求处理器读入命令、解析、执行
3. 执行结果写入 client 输出缓冲区，注册可写事件
4. client socket 可写 → 命令回复处理器把结果发回客户端
5. 回复完毕 → 删除可写事件监听（避免 busy loop）
```

注意一个细节：**每个 client 最多注册一个文件事件（可读或可写）**，`aeCreateFileEvent` 前会先 `aeDeleteFileEvent` 清掉旧事件，避免读写事件同时注册导致的忙轮询。

## 四、IO 多路复用底层实现

Redis 封装了多套底层实现，编译时按平台选择：

```
ae_epoll.c（Linux）→ ae_kqueue.c（macOS/BSD）→ ae_evport.c（Solaris）→ ae_select.c（兜底）
```

`aeApiCreate` 在 Linux 上就是封装 `epoll_create`，`aeApiPoll` 封装 `epoll_wait`。

### 4.1 epoll 的三个关键点

1. **epoll_create**：创建 epoll 实例；
2. **epoll_ctl**：注册/修改/删除 fd 与事件的监听（`EPOLL_CTL_ADD/MOD/DEL`），对应 Redis 的 `aeApiAddEvent`/`aeApiDelEvent`；
3. **epoll_wait**：阻塞等待就绪事件，超时时间由最近的时间事件决定。

```c
static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    aeApiState *state = eventLoop->apidata;
    int retval, numevents = 0;
    retval = epoll_wait(state->epfd, state->events, AE_SETSIZE, tvp ? (tvp->tv_sec*1000 + tvp->tv_usec/1000) : -1);
    // 遍历就绪事件，填充 fired 数组
    for (int j = 0; j < retval; j++) {
        ...
        eventLoop->fired[j].fd = e->data.fd;
        eventLoop->fired[j].mask = ...;  // EPOLLIN→AE_READABLE, EPOLLOUT→AE_WRITABLE
    }
    return numevents;
}
```

### 4.2 为什么是 epoll 而不是 select/poll？

| 对比项 | select | poll | epoll |
| --- | --- | --- | --- |
| fd 数量限制 | 1024（FD_SETSIZE） | 无 | 无（受系统限制） |
| 效率 | O(N) 轮询所有 fd | O(N) 轮询 | O(1) 就绪回调，只遍历就绪 fd |
| 拷贝 | 每次调用需要用户态/内核态拷贝 fd 集合 | 同 select | mmap 共享内存，无需重复拷贝 |
| 水平/边缘触发 | 水平触发 | 水平触发 | 支持水平（LT）和边缘（ET）触发，Redis 用 LT |

Redis 使用 **epoll 的水平触发模式**：只要 socket 缓冲区还有数据，就会持续触发可读事件，配合非阻塞 IO，保证不会漏读。

## 五、时间事件（Time Event）

```c
typedef struct aeTimeEvent {
    long long id;                  // 事件 ID
    long long when_sec;            // 触发时间（秒）
    long long when_ms;             // 触发时间（毫秒）
    aeTimeProc *timeProc;          // 处理函数，返回 AE_NOMORE 删除，返回延时时长则周期性执行
    aeEventFinalizerProc *finalizerProc;
    void *clientData;
    struct aeTimeEvent *next;      // 链表指针
} aeTimeEvent;
```

时间事件分两类：

- **周期性事件**：处理函数返回非 `AE_NOMORE`，下次按返回值续期；
- **一次性事件**：处理函数返回 `AE_NOMORE`，执行后从链表删除。

### 5.1 Redis 最重要的时间事件：serverCron

`serverCron` 是周期性时间事件，默认 **100ms 执行一次**（`hz` 配置，默认 10，即每秒 10 次），负责：

- 更新服务器各类统计信息（内存、连接数、命令数）；
- 过期键的定期删除（配合惰性删除）；
- 持久化触发（RDB 快照、AOF 重写）；
- 集群节点状态检查、复制重连；
- 客户端超时清理、慢查询日志轮转。

> `hz` 调大（如 100）会让定时任务更及时，但会增加 CPU 开销；`hz` 调小则相反。生产环境一般保持默认。

## 六、aeProcessEvents：两种事件的调度

```c
int aeProcessEvents(aeEventLoop *eventLoop, int flags) {
    // 1. 计算阻塞超时时间：如果有时间事件，取"最近时间事件 - 当前时间"作为 epoll_wait 的超时
    if (timeEventHead != NULL) {
        shortest = aeSearchNearestTimer(eventLoop);  // 找最近的时间事件
        ...
        tvp = &tv;  // epoll_wait 最多阻塞到最近时间事件触发
    }

    // 2. 阻塞等待文件事件（带超时）
    numevents = aeApiPoll(eventLoop, tvp);

    // 3. 处理就绪的文件事件（先读后写）
    for (j = 0; j < numevents; j++) {
        // 读事件优先处理，再处理写事件
        if (mask & AE_READABLE) rfired = 1; ...
        eventLoop->fired[j].mask &= ~(AE_READABLE|AE_WRITABLE);
        fe->rfileProc(eventLoop, fd, fe->clientData, mask);   // 读
        fe->wfileProc(eventLoop, fd, fe->clientData, mask);   // 写
    }

    // 4. 处理到期的时间事件（processTimeEvents）
    processTimeEvents(eventLoop);
}
```

**调度规则总结**：

1. `epoll_wait` 的阻塞时长 = 最近时间事件的剩余时间（没有时间事件则无限阻塞，只等文件事件）；
2. 文件事件就绪则立即处理，处理完后再看时间事件是否到期；
3. **文件事件优先于时间事件**（代码顺序：先处理文件事件，再处理时间事件）——保证命令响应及时；
4. 时间事件的实际执行时间可能晚于预定时间（被前面的文件事件处理延迟），所以 serverCron 并不精确，这是 Redis 定时任务「尽力而为」的原因。

### beforeSleep 与 afterSleep

- `beforeSleep`：每次进入阻塞等待前执行——例如把 `handleClientsWithPendingWrites`（把待写 client 注册可写事件）、更新缓存时间等；
- `afterSleep`：阻塞返回后执行（主要用于集群模块的钩子）。

## 七、Redis 6.0 多线程 IO 是怎么回事？

高并发场景下，**网络读写（read/write 系统调用 + 数据拷贝）成为瓶颈**。6.0 引入多线程 IO：

```
主线程：接收连接、解析命令、执行命令、写缓冲区分发
IO 线程（默认关闭，io-threads 4）：只做 socket 读入/写出的数据搬运
```

关键点：

- 命令**执行仍然在主线程**（保证无锁、有序）；
- IO 线程只处理「读入请求数据」和「写出回复数据」两个阶段，通过原子变量自旋等待任务分发，无锁设计；
- `io-threads-do-reads` 默认关闭，因为大部分场景单线程 IO 已够用。

**一句话：6.0 多线程 IO 解决的是网络读写开销，不是命令执行并行化。**

## 八、面试高频追问

### 追问 1：Redis 单线程为什么比多线程的 MySQL 快？

- **数据在内存**：Redis 全内存操作 vs MySQL 磁盘（即便有 Buffer Pool，也要考虑随机 IO）；
- **无锁无上下文切换**：单线程执行命令零竞争；
- **IO 多路复用**：一个线程监听海量连接，非阻塞读写；
- **数据结构高效**：跳表、哈希表、SDS、压缩列表等为内存场景极致优化。

### 追问 2：epoll 和 select 的本质区别？

- select 每次调用都要把 fd 集合从用户态拷贝到内核态，且 O(N) 遍历；epoll 通过内核事件表 + 回调机制，只返回就绪 fd，O(1) 复杂度，且用 mmap 减少拷贝；
- select 有 1024 个 fd 上限；epoll 无上限；
- select 跨平台性好，epoll 仅 Linux。

### 追问 3：Redis 事件循环和 Netty 的事件循环有什么区别？

| 维度 | Redis | Netty |
| --- | --- | --- |
| 底层 | epoll/kqueue 封装（ae_epoll.c） | NIO + epoll 封装（EpollEventLoop） |
| 线程模型 | 单线程处理所有事件 | Reactor 模型，EventLoopGroup 多线程 |
| 任务模型 | 文件事件 + 时间事件（单链表） | 任务队列 + 定时任务（HashedWheelTimer） |
| 目标 | 简单极致，避免并发 | 高并发网络框架，支持多线程 |

两者都是「事件循环 + IO 多路复用」的思想，但 Netty 通过多 EventLoop 支持并发处理，Redis 为了简单性和无锁选择单线程。

### 追问 4：一条慢命令会怎么影响 Redis？

慢命令在主线程执行，会阻塞整个事件循环：期间新连接无法 accept、其他命令无法执行、心跳超时导致主从复制断连。排查用 `SLOWLOG GET`，优化方向：拆分大 Key、避免 O(N) 命令、控制 Lua 脚本执行时间。

## 九、总结

Redis 高性能的核心链路：

```
aeMain（死循环）
  → aeProcessEvents
    → 计算最近时间事件，设置 epoll_wait 超时
    → epoll_wait 阻塞等待 socket 就绪（文件事件）
    → 处理就绪连接：应答/命令请求/命令回复处理器
    → processTimeEvents 处理到期时间事件（serverCron 等）
```

**单线程 + 非阻塞 IO + 多路复用 + 内存数据结构**，四者缺一不可。理解了事件循环，你就真正理解了「Redis 为什么快」，也就能解释 6.0 多线程 IO 的动机与边界。这是 Redis 面试里区分「背答案」和「真懂」的关键一题。
