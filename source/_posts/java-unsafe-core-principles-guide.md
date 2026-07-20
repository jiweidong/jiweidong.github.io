---
title: Java Unsafe 类核心原理与正确使用指南：从内存操作到安全替代
date: 2026-07-20 08:00:00
tags:
  - Java
  - Unsafe
  - 底层原理
  - 并发
categories:
  - Java
  - 底层原理
author: 东哥
---

# Java Unsafe 类核心原理与正确使用指南：从内存操作到安全替代

## 一、Unsafe 是什么？

`sun.misc.Unsafe` 是 JDK 中一个"非常特殊"的类。它提供了一系列 **底层、不安全的操作**，包括：

- 直接读写内存（堆外内存）
- 直接操作对象字段（绕过构造方法）
- CAS 原子操作
- 线程挂起和恢复（park/unpark）
- 加载和存储屏障

> 之所以叫 "Unsafe"，是因为这些操作跳过了 Java 语言的安全检查（如数组边界检查、final 字段不可变性等），使用不当会导致 JVM 崩溃。

### 1.1 如何获取 Unsafe 实例

Unsafe 类的构造方法是 `private` 的，且 `getUnsafe()` 方法做了类加载器检查：

```java
public final class Unsafe {
    private Unsafe() {}
    
    public static Unsafe getUnsafe() {
        Class<?> caller = Reflection.getCallerClass();
        // 非 Bootstrap 类加载器加载的类调用会抛出 SecurityException
        if (!VM.isSystemDomainLoader(caller.getClassLoader())) {
            throw new SecurityException("Unsafe");
        }
        return theUnsafe;
    }
}
```

所以常规方式获取 Unsafe 会抛异常。以下是几种变通方式：

```java
// 方式一：反射获取 theUnsafe 字段
public static Unsafe getUnsafe() throws Exception {
    Field field = Unsafe.class.getDeclaredField("theUnsafe");
    field.setAccessible(true);
    return (Unsafe) field.get(null);
}

// 方式二：在 JDK 9+ 中，通过 Module API 导出
// 需要添加 --add-opens java.base/jdk.internal.misc=ALL-UNNAMED
```

## 二、Unsafe 的核心能力

### 2.1 内存操作

Unsafe 提供了堆外内存的分配、读写和释放操作：

```java
// 分配指定字节数的堆外内存，返回内存地址
long address = unsafe.allocateMemory(1024L);

// 在指定地址写入值
unsafe.putAddress(address, 100L);      // 按 long 写入
unsafe.putInt(address, 42);             // 按 int 写入
unsafe.putByte(address, (byte) 1);      // 按 byte 写入

// 从指定地址读取值
long value = unsafe.getAddress(address); // 按 long 读取
int intValue = unsafe.getInt(address);   // 按 int 读取

// 内存拷贝
unsafe.copyMemory(srcAddr, dstAddr, size);

// 设置内存（类似 C 语言的 memset）
unsafe.setMemory(address, 1024L, (byte) 0);

// 释放堆外内存
unsafe.freeMemory(address);
```

**实战：直接内存统计工具**

```java
public class DirectMemoryTracker {
    private static final Unsafe UNSAFE = getUnsafe();
    private static final AtomicLong totalAllocated = new AtomicLong();
    
    public static long allocate(long size) {
        long address = UNSAFE.allocateMemory(size);
        totalAllocated.addAndGet(size);
        // 注册清理回调
        Cleaner.create(Thread.currentThread(), () -> {
            UNSAFE.freeMemory(address);
            totalAllocated.addAndGet(-size);
        });
        return address;
    }
    
    public static long getAllocatedBytes() {
        return totalAllocated.get();
    }
}
```

### 2.2 对象字段操作

跳过构造方法和安全检查直接操作对象内存：

```java
public class User {
    private final int id = 1;   // final 字段
    private String name;
    
    // 省略构造方法、getter/setter
}

// 直接修改 final 字段
User user = new User();
long idOffset = unsafe.objectFieldOffset(
        User.class.getDeclaredField("id"));
// 即使 id 是 final 的，Unsafely 也能修改
unsafe.putInt(user, idOffset, 999);

// 获取静态字段偏移量
long staticOffset = unsafe.staticFieldOffset(
        User.class.getDeclaredField("name"));

// 获取对象中字段的起始地址
Object base = unsafe.staticFieldBase(
        User.class.getDeclaredField("name"));
```

> ⚠️ **警告**：修改 `final` 字段会导致不可预期的行为！JVM 会内联 final 字段的值，修改后读取到的值可能还是原来的。

### 2.3 直接创建对象（跳过构造方法）

```java
// 不调用任何构造方法，直接创建对象
User user = (User) unsafe.allocateInstance(User.class);
// user 的所有字段都是默认值（null / 0 / false）
```

这在以下场景非常有用：
- **反序列化框架**：Kryo、FST 等高性能序列化框架使用此方式
- **Objenesis**：当类没有无参构造器时创建对象
- **模拟代理对象**

### 2.4 CAS 原子操作

CAS（Compare-And-Swap/Swap）是 Java 并发包的"基石"：

```java
// 对象字段的 CAS 操作
public final native boolean compareAndSwapObject(
        Object o, long offset, Object expected, Object x);
public final native boolean compareAndSwapInt(
        Object o, long offset, int expected, int x);
public final native boolean compareAndSwapLong(
        Object o, long offset, long expected, long x);
```

**工作流程**：

```
线程 A 执行 CAS(&counter, oldValue, newValue)
    1. 读取 counter 当前值
    2. 比较当前值是否等于 oldValue
    3. 如果相等，将 counter 更新为 newValue，返回 true
    4. 如果不相等，返回 false（不更新）
```

**实战：自己实现一个 CAS 计数器**

```java
public class CasCounter {
    private static final Unsafe UNSAFE = getUnsafe();
    private static final long valueOffset;
    
    static {
        try {
            valueOffset = UNSAFE.objectFieldOffset(
                    CasCounter.class.getDeclaredField("value"));
        } catch (Exception e) {
            throw new Error(e);
        }
    }
    
    private volatile int value;
    
    public int increment() {
        int oldValue;
        do {
            oldValue = value;
        } while (!UNSAFE.compareAndSwapInt(this, valueOffset, oldValue, oldValue + 1));
        return oldValue + 1;
    }
}
```

### 2.5 线程挂起与恢复（Park/Unpark）

`LockSupport` 的底层实现依赖 Unsafe 的 park/unpark：

```java
// 挂起当前线程，isAbsolute=false 表示相对时间（纳秒）
unsafe.park(false, 0L);     // 无限期等待

// 挂起指定时长
unsafe.park(false, 1000000000L);  // 挂起 1 秒

// 恢复指定线程
unsafe.unpark(thread);
```

**与 wait/notify 的区别**：

| 特性 | park/unpark | wait/notify |
|---|---|---|
| 使用前是否需要获取锁 | 不需要 | 需要在 synchronized 块中 |
| 是否支持超时 | 支持 | 支持 |
| 是否支持先 unpark 后 park | 支持（许可机制） | 不支持 |
| 唤醒顺序 | 不保证 | 不保证（和锁有关） |
| 是否精确唤醒 | 按线程精确唤醒 | 随机唤醒一个等待线程 |

### 2.6 内存屏障

Unsafe 提供了三种内存屏障操作：

```java
// 读取屏障（LoadLoad barrier）
// 确保屏障前的读操作在屏障后的读操作之前完成
unsafe.loadFence();

// 写入屏障（StoreStore barrier）
// 确保屏障前的写操作在屏障后的写操作之前完成
unsafe.storeFence();

// 全屏障（LoadStore + StoreLoad barrier）
// 同时保证读和写的顺序
unsafe.fullFence();
```

这些屏障在实现自定义并发数据结构时非常有用，例如 `StampedLock` 和 `Exchanger` 的底层实现都用到了它们。

## 三、Unsafe 的实际应用

### 3.1 Java 并发库中的 Unsafe

| JDK 类 | 使用 Unsafe 的功能 |
|---|---|
| `AtomicInteger` | CAS 操作更新 int 值 |
| `AtomicReference` | CAS 操作引用 |
| `ReentrantLock` | park/unpark 挂起/恢复线程 |
| `ConcurrentLinkedQueue` | CAS 操作链表节点 |
| `StampedLock` | 内存屏障 + CAS |
| `ThreadPoolExecutor` | AQS 的 park/unpark |
| `Exchanger` | CAS + 内存屏障 |

### 3.2 高性能框架中的应用

| 框架 | 使用方式 |
|---|---|
| **Netty** | 通过 `PlatformDependent` 封装 Unsafe，实现堆外内存分配和零拷贝 |
| **Kryo** | `allocateInstance` 跳过构造方法创建对象 |
| **Lombok** | 不直接使用，但 `@SneakyThrows` 利用 Unsafe 的 `throwException` |
| **Caffeine** | Striped 缓存中的 CAS 操作 |
| **Disruptor** | 通过 Unsafe 实现高效的内存填充（解决伪共享问题） |

## 四、Unsafe 的安全替代方案

随着 JDK 版本演进，Java 逐步提供了 Unsafe 的替代方案：

| Unsafe 功能 | JDK 9+ 替代 | 说明 |
|---|---|---|
| `compareAndSwapInt` | `VarHandle.compareAndSet()` | `java.lang.invoke.VarHandle` |
| `getInt`/`putInt` | `VarHandle.get()`/`set()` | VarHandle 提供类型安全的字段访问 |
| `allocateMemory` | `ByteBuffer.allocateDirect()` | 推荐使用标准 API |
| `park`/`unpark` | `LockSupport.park()`/`unpark()` | 已有标准替代 |
| `allocateInstance` | - | 仍无安全替代，建议用 Objenesis |
| `throwException` | - | 利用泛型 + 类型擦除实现 |

### 4.1 VarHandle 示例

```java
// JDK 9+ 推荐的 VarHandle 替代
public class VarHandleCounter {
    private volatile int value;
    private static final VarHandle VALUE;
    
    static {
        try {
            VALUE = MethodHandles.lookup()
                    .findVarHandle(VarHandleCounter.class, "value", int.class);
        } catch (Exception e) {
            throw new Error(e);
        }
    }
    
    public int increment() {
        int old;
        do {
            old = (int) VALUE.getVolatile(this);
        } while (!VALUE.compareAndSet(this, old, old + 1));
        return old + 1;
    }
}
```

**VarHandle 对比 Unsafe 的优势**：
- **类型安全**：编译期类型检查
- **安全受控**：JVM 可以进行安全验证
- **可读性强**：API 设计更清晰
- **性能相近**：JIT 同样能内联和优化

## 五、伪共享与 @Contended 注解

Unsafe 在解决 **伪共享（False Sharing）** 问题上扮演了重要角色。

### 5.1 什么是伪共享？

多个线程修改不同的变量，但这些变量恰好在同一个 CPU 缓存行（通常 64 字节）中，导致缓存行无效 → 缓存一致性流量 → 性能下降。

### 5.2 Unsafe 实现缓存行填充

```java
class PaddedCounter {
    // 通过 Unsafe 在字段前后填充 64 字节，确保一个缓存行只有一个热点字段
    @Contended  // JDK 8+ 注解方式，底层通过 Unsafe 实现
    volatile long value;
}
```

## 六、面试高频题

### Q1：Unsafe 的 CAS 操作在底层是怎么实现的？

`unsafe.compareAndSwapInt()` 是 `native` 方法，在 HotSpot 中通过 C++ 的 `Atomic::cmpxchg` 实现，最终映射到 CPU 的 **`CMPXCHG` 指令**（x86 架构）或 `LDXR`/`STXR`（ARM 架构）。

### Q2：使用 Unsafe 的常见风险有哪些？

1. **直接崩溃**：错误的内存地址操作会导致 JVM Crash 而非 Java 异常
2. **内存泄漏**：忘记调用 `freeMemory` 导致堆外内存泄漏
3. **安全性问题**：破坏 final 语义、绕过安全检查
4. **可移植性问题**：Unsafe 的具体行为因 JVM 实现而异
5. **版本兼容性**：不同 JDK 版本的 Unsafe 内部结构可能不同

### Q3：Unsafe 中哪个方法最常用？

从 JDK 源码引用统计来看，`compareAndSwapInt` 和 `park`/`unpark` 是使用频率最高的两个功能。

### Q4：JDK 9+ 为什么不推荐使用 Unsafe？

模块化系统（JPMS）将 Unsafe 放在了 `jdk.unsupported` 模块中，目的是逐步淘汰 Unsafe，用更安全的 `VarHandle` 等 API 替代。虽然短期内 Unsafe 不会被移除，但新项目应优先使用标准 API。

## 七、总结

| 能力维度 | 核心 API | 安全替代方案 |
|---|---|---|
| 原子操作 | `compareAndSwapXxx` | `VarHandle.compareAndSet()` |
| 线程控制 | `park`/`unpark` | `LockSupport` |
| 堆外内存 | `allocateMemory`/`freeMemory` | `ByteBuffer.allocateDirect()` |
| 字段操作 | `objectFieldOffset`/`putInt` | `VarHandle.set()` |
| 对象创建 | `allocateInstance` | Objenesis 或工厂方法 |
| 内存屏障 | `loadFence`/`storeFence`/`fullFence` | `VarHandle` 中的各种访问模式 |

Unsafe 是 Java 底层能力的体现，理解它对于深入理解 JVM 和高性能框架（Netty、Disruptor 等）非常有帮助。但在生产代码中，除非你明确知道自己在做什么并且有其他方案无法满足需求，否则 **强烈不建议直接使用 Unsafe**。
