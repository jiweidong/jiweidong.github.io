---
title: 【Java IO】Java 文件锁 FileLock 深度解析：共享锁、独占锁原理与跨进程同步实战
date: 2026-09-04 08:00:00
tags:
  - Java
  - IO
  - 并发
categories:
  - Java
  - Java 基础
author: 东哥
---

# 【Java IO】Java 文件锁 FileLock 深度解析：共享锁、独占锁原理与跨进程同步实战

## 面试官：两个 JVM 进程要同时写一个文件，怎么保证不互相覆盖？synchronized 行不行？

`synchronized`、`ReentrantLock` 只能管住**同一个 JVM 内的线程**。线上场景经常是：多实例部署（多个 JVM）要抢同一个磁盘文件——定时任务只允许一个实例执行、多进程写同一个日志/数据文件、分布式任务争抢本地资源文件。这时候就需要**跨进程的锁**，而 Java 自带的答案就是 `java.nio.channels.FileLock`：**基于操作系统文件锁的跨进程互斥机制**，不需要引入 Redis、ZooKeeper，单机场景的轻量级首选。

---

## 一、FileLock 是什么？

`FileLock` 是 NIO 提供的**文件区域锁**：它锁的不是"文件对象"，而是**文件的一段字节范围（region）**。通过 `FileChannel` 获取：

```java
try (FileChannel channel = FileChannel.open(
        Path.of("/data/app.lock"),
        StandardOpenOption.CREATE, StandardOpenOption.WRITE)) {

    // 独占锁：整个文件范围（0 ~ Long.MAX_VALUE）
    FileLock lock = channel.lock();
    try {
        // 临界区：只有拿到锁的进程能进来
    } finally {
        lock.release();   // 释放锁（或 channel.close() 自动释放）
    }
}
```

### 1.1 两种锁类型

| 类型 | 方法 | 语义 | 典型场景 |
|---|---|---|---|
| 独占锁（排它锁） | `lock()` / `tryLock()` | 同一区域同时只能有一个进程持有 | 写文件互斥、单例进程 |
| 共享锁（读锁） | `lock(0, Long.MAX_VALUE, true)` | 多个进程可同时持有共享锁；共享锁与独占锁互斥 | 多进程并发读、写者与读者互斥 |

**面试追问：`lock()` 和 `tryLock()` 什么区别？**

- `lock()`：阻塞直到拿到锁（可响应中断）；
- `tryLock()`：**非阻塞**，拿不到立刻返回 `null`，不等待；
- 带参数的 `tryLock(position, size, shared)`：尝试锁指定区域，拿不到返回 null；
- 两者都有带 position/size/shared 的重载，用于**只锁文件的一部分**。

```java
FileLock shared = channel.tryLock(0, Long.MAX_VALUE, true);  // 共享锁，非阻塞
if (shared == null) {
    // 有其他进程持独占锁，做兜底处理
}
```

### 1.2 锁的是区域，不是整个文件

```java
// 只锁前 100 字节：适合锁"文件头"这种元信息区域
FileLock lock = channel.lock(0, 100, false);

// 锁从 100 字节到文件末尾
FileLock lock2 = channel.lock(100, Long.MAX_VALUE, false);
```

多个进程可以**锁同一文件的不同区域**互不干扰——这是 FileLock 比"锁整个文件"精细的地方，适合做"分片文件"的并发写入（每个进程写自己的区段）。

---

## 二、底层原理：Java 锁是怎么落到操作系统上的？

### 2.1 调用链

```
FileChannel.lock()/tryLock()
  -> FileChannelImpl.lock()
     -> FileDispatcher.lock()   （Unix 走 fcntl，Windows 走 LockFile）
        -> 本地方法（native）   -> 操作系统文件锁
```

JDK 实现里，`FileChannelImpl` 维护了一个 **`FileLockTable`**（JVM 进程内已获取锁的注册表）。加锁流程：

1. 先查 FileLockTable，如果**当前 JVM 内已有重叠区域**的锁（哪怕是另一个 FileChannel），直接抛 `OverlappingFileLockException`；
2. 通过 `FileDispatcher` 调用 OS 原生锁（Linux/macOS 上底层是 `fcntl(F_SETLK/F_SETLKW)`，Windows 上是 `LockFileEx`）；
3. OS 层成功后再注册进 FileLockTable。

### 2.2 面试追问：两个进程各开一个 FileChannel 锁同一区域，会发生什么？

- 进程 A `lock()` 成功；
- 进程 B `lock()` **阻塞等待**（或 `tryLock()` 返回 null）；
- 进程 A 释放或关闭 channel 后，B 才拿到锁。
- **注意**：如果 A、B 在**同一个 JVM** 里，B 不会去等 OS，而是直接抛 `OverlappingFileLockException`——因为 JVM 内重叠锁被 FileLockTable 拦下了。

### 2.3 面试追问：为什么 `FileLock` 是进程级而不是线程级的？

`FileLock` 代表的是"持有它的**进程**"对文件区域的占用，不是某个线程。所以它**不能替代 synchronized 做线程间互斥**（同 JVM 线程互斥请用 synchronized/Lock）。反过来，同一进程内**两个线程**各自拿到同一文件的锁对象，OS 层会认为是"同一个进程持有"，第二次获取会抛 `OverlappingFileLockException`（被 JVM 拦截）——这恰好保证了同进程内也不会重复加锁。

---

## 三、最容易踩的坑（实战血泪）

### 坑 1：用 FileOutputStream/FileWriter 打开文件，锁不住！

```java
// 错误示范：FileOutputStream 拿不到 FileChannel 的锁控制权
FileOutputStream fos = new FileOutputStream("/data/app.lock");
FileChannel ch = fos.getChannel();          // 能拿到 channel
FileLock lock = ch.lock();                  // 可能抛异常或行为异常

// 正确姿势：用 FileChannel.open 或 RandomAccessFile
try (FileChannel ch = FileChannel.open(Path.of("/data/app.lock"),
        StandardOpenOption.CREATE, StandardOpenOption.WRITE)) {
    try (FileLock ignored = ch.lock()) {
        // 临界区
    }
}
```

原因：部分平台对"以只写/截断模式打开的文件加锁"支持不完整；**推荐用 `RandomAccessFile`（rw 模式）或 `FileChannel.open`**，读写锁都稳。

### 坑 2：关闭流/Channel 会静默释放锁

```java
FileChannel ch = ...;
FileLock lock = ch.lock();
ch.close();          // ⚠️ 锁被自动释放了！后续代码还以为自己持锁
```

**`FileChannel.close()` 会释放该 channel 上的所有锁。** 所以持有锁期间千万别关 channel；释放锁用 `lock.release()`，别用 close 隐式释放（除非你确定不再需要）。

### 坑 3：锁和写入必须用同一个 Channel

```java
// 错误：用 channel A 加锁，用另一个流去写文件 —— 锁了个寂寞
FileLock lock = chA.lock();
FileOutputStream fos = new FileOutputStream("/data/app.lock"); // 绕过了锁
fos.write(...);

// 正确：加锁、写入、释放都在同一个 channel 上进行
try (FileChannel ch = FileChannel.open(path, WRITE)) {
    try (FileLock ignored = ch.lock()) {
        ch.write(ByteBuffer.wrap(data), 0);   // 用 ch 自己的 write
        ch.force(true);                        // 刷盘，别偷懒
    }
}
```

### 坑 4：进程崩溃了，锁会一直占着吗？

**不会。** 文件锁由 OS 内核管理，**持有锁的进程退出（包括崩溃、kill -9）后，内核自动释放**。这比"锁文件里写 PID + 手动清理"的方案可靠得多——你不需要在 finally 里做清理（当然正常路径还是建议显式 release）。

### 坑 5：跨平台差异

| 平台 | 底层调用 | 注意点 |
|---|---|---|
| Linux/macOS | `fcntl` 记录锁 | 锁与"进程"绑定：进程内再次获取重叠锁会失败/异常；NFS 文件系统上锁语义可能不可靠 |
| Windows | `LockFileEx` | 语义略有差异；某些场景下共享/独占行为与 Unix 不完全一致 |

**NFS 警告**：跨机器共享的 NFS 卷上，fcntl 锁的可靠性取决于 NFS 服务端实现，**生产别把关键互斥寄托在 NFS 文件锁上**——单机磁盘用 FileLock 没问题。

### 坑 6：锁区域超出当前文件大小

锁的范围基于**字节区间**，即使区间超出文件当前大小也合法（未来文件增长到这个区域依然受锁保护）。但注意**文件被截断（truncate）可能影响锁语义**，别边锁边 truncate 同一个文件。

---

## 四、实战案例

### 案例 1：多实例定时任务互斥（进程单例）

```java
public class SingletonGuard implements AutoCloseable {
    private final FileChannel channel;
    private final FileLock lock;

    private SingletonGuard(FileChannel channel, FileLock lock) {
        this.channel = channel;
        this.lock = lock;
    }

    /** 尝试成为"唯一实例"，拿不到锁返回 null */
    public static SingletonGuard tryAcquire(String lockFile) {
        try {
            FileChannel ch = FileChannel.open(Path.of(lockFile),
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
            FileLock lock = ch.tryLock();          // 非阻塞，拿不到立刻返回 null
            if (lock == null) {
                ch.close();
                return null;
            }
            return new SingletonGuard(ch, lock);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override
    public void close() throws IOException {
        lock.release();
        channel.close();
    }
}

// 用法：每个 JVM 实例启动定时任务前抢锁
try (SingletonGuard guard = SingletonGuard.tryAcquire("/data/job.lock")) {
    if (guard == null) {
        log.warn("其他实例已在执行，本实例跳过");
        return;
    }
    doDailyJob();   // 只有拿到锁的实例会执行
}
```

**为什么比"写 PID 到文件判断进程是否活着"强？** PID 文件方案要处理"进程崩溃后残留 PID 文件、PID 被复用"等边界；FileLock 由内核自动释放，**进程死了锁就没了，天然无残留**。

### 案例 2：多进程写共享数据文件（写前加独占锁）

```java
private static final long HEADER_LEN = 16;  // 假设文件头 16 字节存元信息

void appendRecord(Path file, byte[] record) throws IOException {
    try (FileChannel ch = FileChannel.open(file,
            StandardOpenOption.CREATE, StandardOpenOption.READ,
            StandardOpenOption.WRITE)) {

        // 锁整个文件（也可细化到只锁"元信息区"）
        try (FileLock ignored = ch.lock()) {
            // 1. 读文件头拿当前长度/游标
            ByteBuffer header = ByteBuffer.allocate((int) HEADER_LEN);
            ch.read(header, 0);
            // 2. 在文件末尾追加
            long size = ch.size();
            ch.write(ByteBuffer.wrap(record), size);
            ch.force(false);
            // 3. 更新文件头游标（仍在锁内，保证原子性）
        }
    }
}
```

关键点：**读-改-写整个操作都在锁内完成**，否则两个进程同时"读游标 → 写末尾 → 改游标"会互相覆盖。

### 案例 3：读写互斥（共享锁 + 独占锁配合）

```java
// 写者：独占锁
try (FileLock ignored = ch.lock(0, Long.MAX_VALUE, false)) { writeAll(); }

// 读者：共享锁，多个读者可并行
try (FileLock ignored = ch.lock(0, Long.MAX_VALUE, true)) { readAll(); }
```

多个读者可同时持有共享锁；写者必须等所有读者释放。适合"多进程读、单进程写"的配置/缓存文件场景。

---

## 五、FileLock 与分布式锁怎么选？

| 维度 | FileLock（单机文件锁） | Redis 分布式锁 | ZooKeeper 锁 |
|---|---|---|---|
| 范围 | 单机多进程 | 多机分布式 | 多机分布式 |
| 依赖 | JDK + 本地磁盘 | Redis 集群 | ZK 集群 |
| 可靠性 | OS 内核保证释放 | 需处理锁过期/续期 | 会话机制较可靠 |
| 性能 | 高（本地 syscall） | 高 | 中 |
| 适用 | 单机多实例部署、本地资源互斥 | 分布式任务、缓存互斥 | 强一致场景 |

**结论**：多实例部署在同一台机器（或共享本地盘）时，FileLock 是最轻的跨进程互斥方案，零依赖；跨机器场景才需要引入分布式锁。**别杀鸡用牛刀，也别用牛刀杀鸡。**

---

## 六、总结：面试速记卡

**Q1：Java 怎么实现跨进程文件互斥？**
`FileChannel.lock()/tryLock()` 获取 `FileLock`，底层走 OS 文件锁（Linux fcntl / Windows LockFileEx），进程退出自动释放。

**Q2：共享锁和独占锁的区别？**
独占锁：同一区域同时仅一个进程持有；共享锁：多进程可同时持有，但与独占锁互斥。`lock(pos, size, true)` 第三参为 true 即共享锁。

**Q3：同 JVM 内两个线程能同时锁同一文件吗？**
不能。JVM 的 FileLockTable 检测到重叠区域直接抛 `OverlappingFileLockException`。线程互斥请用 synchronized/Lock。

**Q4：FileLock 有什么坑？**
① 别用 FileOutputStream 加锁，用 FileChannel.open / RandomAccessFile；② close channel 会释放锁；③ 锁、写、释放必须同一 channel；④ 进程崩溃锁自动释放（这是优点）；⑤ NFS 上别依赖文件锁。

一句话总结：**FileLock 是 JDK 自带的跨进程互斥利器——锁区域精确到字节、进程崩溃内核兜底释放、单机多实例场景零依赖搞定互斥；记住"同一 Channel 加锁读写、关闭即释放、同 JVM 重叠即异常"三条铁律，就能用得又稳又准。**
