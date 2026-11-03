---
title: 【Java 网络】io_uring 深度解析：从 epoll 到共享内存环形队列，Java 生态跟上了吗
date: 2026-11-03 08:10:00
tags:
  - Java
  - Netty
  - io_uring
  - epoll
  - NIO
  - 网络编程
categories:
  - Java 网络
author: 东哥
---

# 【Java 网络】io_uring 深度解析

## 前言

写 Java 网络服务的人，脑子里大多有一套固定模型：

```
Selector.select() → 拿到就绪事件 → 对每个 Channel 做 read/write
```

这套模型从 2002 年的 NIO 用到今天，底层是 Linux 的 **epoll**，二十多年没变过。它很成功，但有一个根本性的结构缺陷：**epoll 只告诉你「可以读了」，真正的读还要你自己发 syscall**。

也就是说，一次网络读要两次陷入内核：

1. `epoll_wait()` —— 问「谁就绪了」
2. `read()` —— 真正读数据

在 10 万 QPS 的场景下，这就是 20 万次 syscall。每次 syscall 意味着用户态/内核态切换、寄存器保存恢复、可能的 Spectre 缓解开销。

io_uring（Linux 5.1+）的思路完全不同：**把「提交请求」和「获取结果」变成两个共享内存环形队列，用户态和内核态通过无锁 ring 通信**，一次 syscall 可以批量提交成百上千个 IO。

这篇文章讲清楚：

1. io_uring 的机制（SQ/CQ、SQPOLL、注册资源、linked ops）
2. 和 epoll 的本质差异（readiness vs completion）
3. Java 生态的真实支持状况（Netty transport、Panama 调 liburing、Loom 的关系）
4. 什么场景该用、什么场景是坑

---

## 一、epoll 的天花板在哪

### 1.1 readiness 模型的代价

epoll 是**就绪通知（readiness）**模型：

```c
// 伪代码：一次读的完整路径
n = epoll_wait(epfd, events, maxevents, -1);   // syscall #1
for (i = 0; i < n; i++) {
    if (events[i].events & EPOLLIN) {
        len = read(fd, buf, size);              // syscall #2
        // 如果没读完，还要再 read
    }
}
```

问题：

| 问题 | 说明 |
|---|---|
| syscall 次数 = 事件数 + 1 | 高并发下线性增长 |
| 事件处理是「串行」的 | 一个线程一次只能推进一步 |
| 无法批量 | 每次 read 只针对一个 fd |
| 用户态要自己维护状态机 | 半包、背压、重试全靠应用层 |
| 文件 IO 不支持 | epoll 只管 socket/pipe，普通文件永远「就绪」 |

最后一条尤其致命：**epoll 对磁盘文件无效**（因为 page cache 命中就返回，不命中也立即返回，无法表达「等数据」）。所以 Java 读大文件只能靠阻塞 IO + 线程池。

### 1.2 Java AIO 为什么没成

JDK 7 引入 NIO.2（AIO），Linux 上底层是 **glibc 的 POSIX AIO**（用户态线程池模拟）或 **libaio**（限制极多：只能 O_DIRECT、不支持 socket）。

结果就是：**Java AIO 在 Linux 上既没有真正的异步，也没法用在网络上**，性能不如 NIO，最后只剩 Windows 上的 IOCP 实现是真异步。这也是 Netty 从来不用 AIO 的原因。

io_uring 补的正是这个坑：**统一的 completion 模型，socket 和文件都支持**。

---

## 二、io_uring 的机制

### 2.1 两个环形队列

```
用户态                                    内核态
┌──────────────────────┐        ┌──────────────────────┐
│  SQ (Submission Q)   │        │                      │
│  ┌───┬───┬───┬───┐   │  共享   │   取出 SQE           │
│  │SQE│SQE│SQE│   │───┼─内存──▶│   执行 IO            │
│  └───┴───┴───┴───┘   │  mmap   │                      │
│        ▲             │        │        │             │
│        │ 写索引       │        │        ▼             │
│  tail/head (原子)     │        │   写 CQE             │
├──────────────────────┤        ├──────────────────────┤
│  CQ (Completion Q)   │        │                      │
│  ┌───┬───┬───┬───┐   │◀───────┼─── 完成结果           │
│  │CQE│CQE│CQE│   │   │        │                      │
│  └───┴───┴───┴───┘   │        │                      │
└──────────────────────┘        └──────────────────────┘
```

核心设计：

- **SQ / CQ 是 mmap 的共享内存环形缓冲区**
- 用户态写 SQE（Submission Queue Entry，描述「我要做什么 IO」）
- 内核读 SQE、执行、写 CQE（Completion Queue Entry，含结果码）
- 用户态读 CQE，**不需要 syscall**
- 只有「通知内核有新请求」这一步需要 `io_uring_enter()`（或者用 SQPOLL 连这一步都省）

一次 `io_uring_enter` 可以提交 N 个请求，也可以收割 M 个完成事件。**syscall 次数从 O(事件数) 降到 O(批次)**。

### 2.2 SQE / CQE 里有什么

一个 SQE（64 字节）包含：

| 字段 | 含义 |
|---|---|
| `opcode` | 操作类型：READ/WRITE/ACCEPT/CONNECT/SEND/RECV/FSYNC/OPENAT… |
| `fd` | 目标文件描述符（或用 registered index） |
| `addr` / `len` | 缓冲区地址与长度 |
| `off` | 文件偏移 |
| `user_data` | **8 字节用户标识**，完成时原样返回（用来关联请求） |
| `flags` | IOSQE_IO_LINK / IOSQE_FIXED_FILE 等 |
| `personality` | 凭证（用于权限隔离） |

一个 CQE（16 字节）：

| 字段 | 含义 |
|---|---|
| `user_data` | 回传的标识 |
| `res` | 结果（字节数或负 errno） |
| `flags` | IORING_CQE_F_MORE（multishot 还有后续）等 |

`user_data` 这个设计特别关键：它就是「异步请求的凭证」，Java 侧对应的是 `long` 型的 request id，或者直接用对象地址（Panama 场景）。

### 2.3 关键能力

| 能力 | 说明 | 价值 |
|---|---|---|
| **SQPOLL** | 内核线程轮询 SQ，用户态完全不用 syscall | 极致低延迟（但吃一个核） |
| **注册文件（fixed files）** | 提前 `io_uring_register` 一批 fd，SQE 用索引引用 | 省掉每次 fget/fput |
| **注册缓冲区（fixed buffers）** | 提前注册内存，内核直接 DMA/拷贝 | 省掉 pin 页开销 |
| **Multishot accept/recv** | 一次提交，多次完成 | 长连接场景 syscall 大幅下降 |
| **Linked operations** | `IOSQE_IO_LINK`：A 完成才执行 B | 内核态串联 read→write，零往返 |
| **Timeout / Poll** | 超时也是 op | 不需要额外定时器线程 |
| **Buffer select** | 内核自动选缓冲区 | 减少用户态缓冲区管理 |

其中 **multishot recv** 对 Java 生态影响最大：一个连接提交一次，之后每次数据到达都产生 CQE，不需要重新提交。

---

## 三、epoll vs io_uring

| 维度 | epoll | io_uring |
|---|---|---|
| 模型 | readiness（就绪通知） | completion（完成通知） |
| syscall 次数 | 每事件 ≥1 次 | 批量，可低至 0（SQPOLL） |
| 支持普通文件 | ❌ | ✅ |
| 支持 socket | ✅ | ✅ |
| 批量提交 | ❌ | ✅ |
| 内核态串联操作 | ❌ | ✅（linked） |
| 缓冲区注册 | ❌ | ✅ |
| 用户态/内核态通信 | 内核写就绪列表 | **共享内存 ring** |
| 内核版本要求 | 2.6 | 5.1+（功能随版本递增） |
| 容器兼容性 | 好 | ⚠️ 常被 seccomp 拦 |
| 生态成熟度 | 极高 | 中（Netty 实验性、Nginx 实验性） |

### 3.1 一个直观的对比

假设 1000 个连接同时有数据到达：

```
epoll:
  epoll_wait() 返回 1000        → 1 syscall
  for each: read() × 1000       → 1000 syscalls
  合计 1001

io_uring（multishot recv + SQPOLL）:
  1000 个 CQE 已经在共享内存里  → 0 syscall
  重新提交（如果需要）         → 1 次 enter（或 0，SQPOLL）
  合计 0~1
```

这就是为什么在高 PPS 场景下，io_uring 能把 CPU 从「syscall 开销」里解放出来。

---

## 四、Java 生态的真实状况

### 4.1 JDK 本身：还没有

截至 JDK 25/26，**标准 NIO 仍然基于 epoll**。JDK 内部有对 io_uring 的探索性讨论（Loom 团队评估过用 io_uring 替代 epoll 做 IO 调度），但没有任何 JEP 落地。

原因不难理解：io_uring 是 Linux 专有（macOS/Windows 没有对等物），而 JDK 的 `Selector` 是跨平台抽象。为一个平台重写整个 IO 层，收益/风险比不划算。

### 4.2 Netty：有实验性 transport

Netty 4.1 提供了 `netty-transport-native-io_uring`（孵化状态）：

```xml
<dependency>
    <groupId>io.netty</groupId>
    <artifactId>netty-transport-native-io_uring</artifactId>
    <version>4.1.115.Final</version>
    <classifier>linux-x86_64</classifier>
</dependency>
```

使用方式和 epoll 几乎一样：

```java
EventLoopGroup boss = new IoUringEventLoopGroup(1);
EventLoopGroup worker = new IoUringEventLoopGroup();

ServerBootstrap b = new ServerBootstrap();
b.group(boss, worker)
 .channel(IoUringServerSocketChannel.class)
 .childHandler(new ChannelInitializer<SocketChannel>() {
     @Override
     protected void initChannel(SocketChannel ch) {
         ch.pipeline().addLast(new EchoHandler());
     }
 });

b.bind(8080).sync();
```

启动参数需要：

```bash
# Netty 的 io_uring 用反射/Unsafe 访问 JDK 内部，需要开模块
java --add-opens java.base/java.nio=ALL-UNNAMED \
     --add-opens java.base/sun.nio.ch=ALL-UNNAMED \
     -jar app.jar
```

⚠️ **实测建议**：Netty 的 io_uring transport 在 4.1 仍是孵化状态，API 可能与 epoll 实现有细微差异（尤其零拷贝、`FileRegion`、native 传输组合）。上生产前必须做长时间压测 + 回退预案（配置化切换 EventLoopGroup）。

### 4.3 Panama FFM 直接调 liburing

JDK 22 起 FFM API 转正，可以不用 JNI 直接调 `liburing`：

```java
public class LibUring implements AutoCloseable {
    private static final Linker LINKER = Linker.nativeLinker();
    private static final SymbolLookup LOOKUP = SymbolLookup.libraryLookup("uring", Arena.global());

    private static final MethodHandle IO_URING_QUEUE_INIT = LINKER.downcallHandle(
        LOOKUP.find("io_uring_queue_init").orElseThrow(),
        FunctionDescriptor.of(ValueLayout.JAVA_INT,
            ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));

    private static final MethodHandle IO_URING_GET_SQE = LINKER.downcallHandle(
        LOOKUP.find("io_uring_get_sqe").orElseThrow(),
        FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS));

    private static final MethodHandle IO_URING_SUBMIT = LINKER.downcallHandle(
        LOOKUP.find("io_uring_submit").orElseThrow(),
        FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));

    private final MemorySegment ring;

    public LibUring(int entries) throws Throwable {
        this.ring = Arena.ofAuto().allocate(512);   // 实际需要 sizeof(struct io_uring)
        int rc = (int) IO_URING_QUEUE_INIT.invokeExact(entries, ring, 0);
        if (rc < 0) throw new IllegalStateException("queue_init failed: " + rc);
    }

    public MemorySegment nextSqe() throws Throwable {
        return (MemorySegment) IO_URING_GET_SQE.invokeExact(ring);
    }

    public int submit() throws Throwable {
        return (int) IO_URING_SUBMIT.invokeExact(ring);
    }

    @Override
    public void close() { /* io_uring_queue_exit */ }
}
```

⚠️ 这条路**只适合自研中间件/网关**，因为：

- `struct io_uring` 的内部布局要自己按 `liburing` 头文件对齐（结构体版本差异）
- 生命周期管理（`Arena` 关闭时机 vs 内核仍在使用缓冲区）极易踩 use-after-free
- 需要处理 `-EAGAIN`、`-EBUSY`、`-ECANCELED` 各种 errno
- 每个环节都要做 native 内存边界检查，否则就是 JVM crash 而非异常

### 4.4 虚拟线程 vs io_uring：不是替代关系

这是最容易混淆的点。Loom 的虚拟线程解决的是 **「阻塞式写法如何不占线程」**，底层仍然是 epoll + park/unpark：

```
虚拟线程 read() →  carrier 线程 park → epoll 等待 → 数据到达 → unpark → 恢复执行
```

它**没有减少 syscall**，只是把「线程等待」变成了「调度器等待」。所以：

| 场景 | 虚拟线程 | io_uring |
|---|---|---|
| 每连接一个线程的阻塞写法 | ✅ 极大提升并发 | ❌ 用不上 |
| 磁盘文件高并发读 | ⚠️ 仍阻塞 carrier | ✅ 真正异步 |
| 极致 syscall 优化 | ❌ 不解决 | ✅ 核心价值 |
| 代码复杂度 | ✅ 几乎为零 | ❌ 高 |
| 跨平台 | ✅ | ❌ Linux only |

结论：**虚拟线程是「写法革命」，io_uring 是「系统调用革命」**。多数业务系统先吃虚拟线程的红利就够了；只有自研网关、消息中间件、存储引擎这类对 syscall 极敏感的组件，才值得上 io_uring。

---

## 五、生产落地：先解决这三个坑

### 5.1 容器里可能直接不可用

Docker 的默认 seccomp profile 会拦掉 `io_uring_setup` 等 syscall（历史上因为 io_uring 出过若干提权 CVE）。表现是：

```
io_uring_queue_init failed: -EPERM (-1)
```

排查：

```bash
# 看是否有 seccomp 限制
grep Seccomp /proc/self/status
# Seccomp: 2  (filter 模式)

# 检查是否被拦
dmesg | grep -i seccomp | tail
```

解决：自定义 seccomp profile 放行，或者 `--security-opt seccomp=unconfined`（生产不建议）。

**所以第一件事是：启动时探测 + 自动降级。**

```java
public final class IoUringSupport {
    private static final boolean AVAILABLE = probe();

    private static boolean probe() {
        try {
            Class.forName("io.netty.channel.uring.IoUring");
            // 进一步：尝试 queue_init，捕获 UnsatisfiedLinkError / EPERM
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    public static EventLoopGroup newEventLoopGroup(int threads) {
        return AVAILABLE
            ? new IoUringEventLoopGroup(threads)
            : new EpollEventLoopGroup(threads);   // 降级
    }
}
```

### 5.2 内核版本决定能力集

| 内核 | 关键能力 |
|---|---|
| 5.1 | 基础 read/write/accept |
| 5.5 | `IORING_OP_TIMEOUT`、`accept` 支持 |
| 5.6 | `send/recv`、`openat`、固定文件改进 |
| 5.7 | `IORING_OP_SEND_ZC`（零拷贝发送） |
| 5.19 | multishot recv 成熟、`IORING_SETUP_DEFER_TASKRUN` |
| 6.x | 更多 opcode、性能优化、部分安全加固 |

CentOS 7（3.10 内核）**完全不可用**。Alibaba Cloud Linux 3 / Ubuntu 22.04（5.15+）可用大部分能力。

⚠️ 特别注意：**内核 5.10 上 multishot 行为与 5.19+ 有差异**，跨机器混部时不要假设行为一致。

### 5.3 缓冲区生命周期是最大的坑

这是 io_uring 相比 epoll「难用」的核心原因。

epoll 模型下，数据是你 `read()` 拷进自己 buffer 的，buffer 什么时候释放你自己说了算。

io_uring 模型下：**你把 buffer 地址交给内核，内核异步写入，你必须在 CQE 回来之后才能碰这块内存。**

```java
// ❌ 严重错误：提交后立即复用缓冲区
ByteBuffer buf = ByteBuffer.allocateDirect(4096);
submitRead(fd, buf);
buf.clear();          // 内核可能正在往这块内存写！
```

正确做法：

- 每个 in-flight 请求独占一块 buffer（池化，但状态必须 `IN_FLIGHT`）
- CQE 收割后再归还池
- 用 `user_data` 严格关联 buffer 与请求

这也是为什么 Netty 的 io_uring 实现里，`ByteBuf` 的引用计数管理比 epoll 版本复杂得多——一旦 `release()` 早了就是脏数据或崩溃。

---

## 六、到底该不该上

### 6.1 值得上的场景

| 场景 | 理由 |
|---|---|
| 自研 API 网关 / 四层代理 | 高 PPS、syscall 是主要成本 |
| 消息队列 Broker | 大量顺序读写 + socket，批量价值高 |
| 对象存储/文件服务 | 普通文件异步 IO 是 epoll 的死角 |
| 极致 P99 延迟要求的服务 | SQPOLL + 固定缓冲区能省掉 μs 级抖动 |

### 6.2 不值得的场景

| 场景 | 理由 |
|---|---|
| 普通 CRUD 业务服务 | 瓶颈在 DB/GC，不在 syscall |
| 并发 < 1 万 | epoll + 虚拟线程完全够用 |
| 需要跨平台 | Linux only |
| 团队没有 native/内核排障能力 | 出问题定位成本极高 |
| 容器 seccomp 不可控 | 直接不可用 |

### 6.3 一个务实的演进路径

```
阶段 1：epoll + 虚拟线程（多数团队停在这里就够了）
   ↓ 压测发现 syscall 占比 > 20%
阶段 2：Netty epoll transport 调优（批量 flush、SO_REUSEPORT、多 EventLoop）
   ↓ 仍然不够，且确认瓶颈在内核态
阶段 3：Netty io_uring transport（灰度 + 自动降级）
   ↓ 需要更激进的优化
阶段 4：FFM 直调 liburing（自研组件，团队有 native 能力）
```

---

## 七、面试追问

**Q1：io_uring 和 epoll 的本质区别？**
epoll 是 readiness 模型：告诉你就绪，实际 IO 还要你自己发 syscall。io_uring 是 completion 模型：你提交请求（SQE），内核执行完把结果放到 CQ，全程通过共享内存 ring 通信，一次 syscall 可批量提交/收割。

**Q2：为什么 io_uring 能支持普通文件而 epoll 不行？**
epoll 的语义是「fd 可读」，而普通文件总是「可读」（page cache 命中直接返回，未命中则阻塞），无法表达「数据准备好了」。io_uring 的请求本身就是「读 N 字节到 addr」，内核可以在后台完成（走块层），完成后通知，语义天然适配。

**Q3：SQPOLL 是什么？代价是什么？**
内核起一个线程持续轮询 SQ ring，用户态提交请求完全不需要 syscall。代价是常驻占一个 CPU 核（`IORING_SETUP_SQPOLL` 需要 CAP_SYS_NICE 或 root），适合「CPU 有余、延迟敏感」的场景。

**Q4：Java 里怎么用 io_uring？**
三条路：Netty 的 `netty-transport-native-io_uring`（孵化，最省事）、Panama FFM 直调 liburing（灵活但要自己管内存）、JNI 封装（最麻烦，不推荐新项目）。JDK 标准 NIO 目前仍是 epoll。

**Q5：虚拟线程能替代 io_uring 吗？**
不能。虚拟线程解决「线程等待的成本」，不减少 syscall；io_uring 解决「syscall 与内核往返的成本」，不改善编程模型。二者正交，可以叠加。

**Q6：容器里 io_uring 报 EPERM 怎么排查？**
先看 `/proc/self/status` 的 `Seccomp` 字段，再看 dmesg 有无 seccomp 拒绝记录。Docker 默认 profile 会拦 `io_uring_setup`，需要自定义 profile 放行。生产上必须做启动探测 + 自动降级到 epoll。

---

## 八、总结

io_uring 是 Linux IO 接口二十年来最大的一次重构，它的价值不在于「更快」，而在于**把 IO 从「问内核好了没」变成「告诉内核做什么」**。这个范式转换顺带解决了 epoll 一直无解的两个问题：普通文件异步、批量提交。

但对 Java 生态，现实是：

- **JDK 标准库还没跟上**，NIO 仍基于 epoll
- **Netty 有实验性实现**，可用但要压测、要降级方案
- **FFM 让自研成为可能**，但 buffer 生命周期管理是硬门槛
- **容器兼容性是第一道关**，seccomp 拦掉就一切归零

所以我的判断是：**2026 年，io_uring 对 Java 仍然是「中间件团队的技术红利」，不是「业务团队的性能银弹」**。业务侧先用虚拟线程把并发模型理顺，把 DB 和 GC 调好，收益比折腾 io_uring 大一个数量级。

技术选型要看「投入产出比」，不是看「谁更先进」。
