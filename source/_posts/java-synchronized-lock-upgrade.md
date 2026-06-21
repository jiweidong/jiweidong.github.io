---
title: 面试官：说说 Synchronized 的锁升级过程？
date: 2026-06-21 08:00:00
tags:
  - Java
  - 并发
  - 面试
categories:
  - Java
  - 后端面试
author: 东哥
---

# 面试官：说说 Synchronized 的锁升级过程？

## 面试官：先说说 Synchronized 的基本用法吧

Synchronized 是 Java 最基础的同步机制，从 JDK 1.0 就有了。用法分三种：

| 用法 | 锁对象 | 作用范围 |
|------|--------|----------|
| 修饰实例方法 | 当前实例对象 `this` | 整个方法 |
| 修饰静态方法 | 当前 Class 对象 | 整个方法 |
| 同步代码块 | 指定的任意对象 | 代码块内 |

```java
public class SyncDemo {
    // 实例方法锁 - 锁的是 this
    public synchronized void instanceMethod() {
        // ...
    }
    
    // 静态方法锁 - 锁的是 Class 对象
    public static synchronized void staticMethod() {
        // ...
    }
    
    // 代码块锁 - 锁的是指定对象
    public void blockMethod() {
        synchronized (this) {
            // ...
        }
    }
}
```

**面试官：嗯，那 Synchronized 在 JDK 6 之后做了哪些优化？**

这就是关键了。JDK 6 之前，Synchronized 是 **重量级锁**，依赖操作系统的 Mutex Lock 实现，线程阻塞和唤醒需要用户态到内核态的切换，开销很大。所以早期很多人说 Synchronized 是"重量级锁"、"性能差"。

但从 JDK 6 开始，HotSpot 虚拟机对 Synchronized 做了大量优化，引入了**锁升级**（也叫锁膨胀）机制：**无锁 → 偏向锁 → 轻量级锁 → 重量级锁**。

注意这个方向是**单向的**，锁只能升级不能降级。

## 面试官：先讲讲偏向锁吧，原理是什么？

### 偏向锁的背景

偏向锁的核心思想：**大多数情况下，锁不仅不存在多线程竞争，而且总是由同一线程多次获得**。

如果每次同一个线程获取锁都要走 CAS，还是有点浪费。偏向锁让**第一个获取锁的线程，之后再次获取该锁时，只需要检查一下标记位就行，连 CAS 都省了**。

### 偏向锁的存储结构

Java 对象在内存中分为三部分：**对象头 + 实例数据 + 对齐填充**。偏向锁的信息存在对象头的 Mark Word 中。

以 64 位 JVM 为例，Mark Word 的结构：

| 锁状态 | 63（分代年龄） | 62-62 | 偏向线程ID（54bit） | 偏向时间戳 | 偏向锁标志 | 锁标志位 |
|--------|------|-------|------------|------------|------|------|
| 无锁 | age | 0 | - | - | 0 | 01 |
| 偏向锁 | age | 0 | thread_id | epoch | 1 | 01 |
| 轻量级锁 | - | - | 指向栈中锁记录的指针 | 00 |
| 重量级锁 | - | - | 指向重量级锁（monitor）的指针 | 10 |
| GC标记 | - | - | - | 11 |

关键点：无锁和偏向锁的标志位都是 **01**，区别在于倒数第三位的 **biased_lock**（偏向锁标志位）。

### 偏向锁的获得过程

```java
public class BiasLockDemo {
    static final Object lock = new Object();
    
    public static void main(String[] args) {
        // 线程A第一次获取锁
        synchronized (lock) {
            // 此时 Mark Word 记录 Thread A 的 ID
            doWork();
        }
        // 线程A再次获取锁——只需检查偏向线程ID，连CAS都不用
        synchronized (lock) {
            doMoreWork();
        }
    }
}
```

**流程：**
1. 第一次获取锁时，通过 CAS 将线程 ID 写入 Mark Word 的偏向线程 ID 字段
2. CAS 成功 → 获得偏向锁，进入同步代码块
3. 之后同一线程再次获取时，检查偏向线程 ID 是否等于当前线程 ID
4. 相等 → 直接进入，不需要 CAS，零开销

### 偏向锁的撤销

偏向锁的撤销不是发生在持有锁的线程，而是**在竞争发生的时候**。

当另一个线程尝试获取这个偏向锁时：
1. 检查持有偏向锁的线程是否存活
2. 如果不存活 → 将对象头置为无锁状态，重新偏向
3. 如果存活 → 在 **全局安全点**（SafePoint）暂停该线程
4. 撤销偏向锁 → 升级为轻量级锁或恢复到无锁状态

**注意：偏向锁的撤销成本很高**，需要等待全局安全点。所以在高并发场景下，可以禁用偏向锁：`-XX:-UseBiasedLocking`。

**面试官：什么时候会撤销偏向锁？**

- **有竞争时**：另一个线程尝试获取该锁
- **调用 hashCode() 时**：偏向锁的 Mark Word 没有空间存 hashCode，一旦调用 hashCode，偏向锁立即撤销
- **批量重偏向**：当同一个类的多个对象的偏向锁被撤销次数超过阈值（默认20），JVM 会批量重偏向，不再撤销
- **批量撤销**：当超过阈值（默认40），JVM 会认为这个类不适合偏向锁，直接批量撤销该类所有偏向锁

## 面试官：很好，那轻量级锁呢？

### 轻量级锁的原理

轻量级锁的目标是：**在没有多线程真正竞争的情况下，用 CAS 替代互斥量，减少重量级锁的开销**。

### 加锁过程

```java
public class LightweightLockDemo {
    static final Object lock = new Object();
    
    public static void main(String[] args) {
        // 线程A和线程B交替执行，基本不重叠
        new Thread(() -> {
            synchronized (lock) {
                // 轻量级锁
                doWork();
            }
        }).start();
        
        new Thread(() -> {
            synchronized (lock) {
                // 还是轻量级锁，因为交替执行
                doWork();
            }
        }).start();
    }
}
```

**加锁流程：**

1. 判断当前对象是否处于无锁状态（锁标志位 01，偏向锁标志 0）
2. 如果是，在当前线程的栈帧中创建一个 **Lock Record** 空间
3. 将对象头 Mark Word 复制到 Lock Record 中（称为 **Displaced Mark Word**）
4. 通过 CAS 尝试将对象头的 Mark Word 替换为指向 Lock Record 的指针
5. CAS 成功 → 获得轻量级锁
6. CAS 失败 → 检查是否当前线程已持有该锁（可重入），否则说明有竞争，**锁膨胀为重量级锁**

### 可重入优化

对于同一个线程多次获取同一把锁（可重入），JDK 在 Lock Record 中做了优化：

```java
synchronized (lock) {     // 第一次获取，创建 Lock Record
    synchronized (lock) { // 第二次获取，再创建一个 Lock Record
                          // Displaced Mark Word 设置为 null
    }
}
```

可重入时不重复 CAS，而是将 Lock Record 的 displaced mark word 设为 null 作为重入计数。

### 解锁过程

1. 如果 Lock Record 的 displaced mark word 为 null → 是重入，直接忽略
2. 否则通过 CAS 将 displaced mark word 替换回对象头
3. CAS 成功 → 解锁完成
4. CAS 失败 → 说明锁已经膨胀为重量级锁，需要唤醒等待的线程

## 面试官：那什么时候会升级成重量级锁？

### 重量级锁

重量级锁依赖操作系统的 **Mutex Lock** 实现，JDK 中对应 **ObjectMonitor**。

当多个线程**真正并发竞争**同一把锁时，轻量级锁 CAS 失败，就会**锁膨胀**：

```java
public class HeavyweightLockDemo {
    static final Object lock = new Object();
    static int counter = 0;
    
    public static void main(String[] args) throws Exception {
        // 多线程真正并发竞争
        for (int i = 0; i < 10; i++) {
            new Thread(() -> {
                for (int j = 0; j < 100000; j++) {
                    synchronized (lock) {
                        counter++;
                    }
                }
            }).start();
        }
        Thread.sleep(2000);
        System.out.println(counter);
    }
}
```

**锁膨胀流程：**

1. 轻量级锁 CAS 失败 → 说明有真实竞争
2. 分配并初始化 ObjectMonitor 对象
3. 将 ObjectMonitor 的地址写入对象头的 Mark Word
4. 锁标志位设为 10（重量级锁）
5. 未获取到锁的线程进入 ObjectMonitor 的 _EntryList 阻塞队列
6. 线程阻塞，依赖操作系统互斥量实现

### ObjectMonitor 内部结构

```
ObjectMonitor {
    _header       → 对象头
    _count        → 计数器
    _owner        → 持有锁的线程
    _WaitSet      → 调用 wait() 的线程队列
    _EntryList    → 等待获取锁的线程队列
    _recursions   → 重入次数
}
```

**重量级锁的获取流程：**
1. 尝试 CAS 将 _owner 设为自己
2. 成功 → 获得锁
3. 失败 → 进入 _EntryList 阻塞等待
4. 持有锁的线程调用 wait() → 进入 _WaitSet 并释放锁
5. 持有锁的线程退出同步块 → 释放锁，唤醒 _EntryList 中的线程

## 面试官：拿整张图总结一下锁升级的完整流程

```
                    ┌─────────────┐
                    │   无锁状态    │
                    │  (01, biased=0)│
                    └──────┬──────┘
                           │ 一个线程获取锁
                           ▼
                    ┌─────────────┐
                    │   偏向锁      │ ◄── 同一线程再获取
                    │  (01, biased=1)│     零成本进入
                    └──────┬──────┘
                           │ 另一个线程尝试获取
                           ▼
                    ┌─────────────┐
                    │  轻量级锁     │ ◄── CAS 自旋等待
                    │     (00)     │
                    └──────┬──────┘
                           │ CAS 持续失败，真实竞争
                           ▼
                    ┌─────────────┐
                    │  重量级锁     │ ◄── 线程阻塞，OS调度
                    │     (10)     │
                    └─────────────┘
```

**面试官：好，那说说为什么锁只能升级不能降级？**

这是出于性能和实现的考虑：

1. **避免复杂性**：如果锁可以降级，JVM 需要跟踪更复杂的状态转换，增加实现复杂度
2. **偏向锁撤销成本高**：撤销偏向锁已经需要 SafePoint 暂停了，如果再允许降级，条件判断更复杂
3. **概率极低**：一旦发生竞争，大概率后续还会竞争，降级意义不大
4. **压力测试结论**：HotSpot 团队测试发现，锁降级带来的收益远小于其实现和维护成本

但不代表绝对不降级——**重量级锁在线程被 GC 时可能会降级**，但这是 GC 的副产品，不是主动行为。

## 面试官：那怎么观察锁的状态？

可以用 `jol`（Java Object Layout）工具来观察：

```xml
<dependency>
    <groupId>org.openjdk.jol</groupId>
    <artifactId>jol-core</artifactId>
    <version>0.17</version>
</dependency>
```

```java
import org.openjdk.jol.info.ClassLayout;

public class JOLDemo {
    static final Object lock = new Object();
    
    public static void main(String[] args) throws Exception {
        System.out.println("=== 无锁状态 ===");
        System.out.println(ClassLayout.parseInstance(lock).toPrintable());
        
        // 偏向锁在 JVM 启动后 4 秒才激活
        Thread.sleep(5000);
        
        System.out.println("=== 偏向锁状态 ===");
        synchronized (lock) {
            System.out.println(ClassLayout.parseInstance(lock).toPrintable());
        }
        
        System.out.println("=== 轻量级锁（交替执行）===");
        Thread t = new Thread(() -> {
            synchronized (lock) {
                System.out.println(ClassLayout.parseInstance(lock).toPrintable());
            }
        });
        t.start();
        t.join();
    }
}
```

JVM 参数：
- `-XX:+UseBiasedLocking`：启用偏向锁（JDK 8 默认开启，JDK 15 默认关闭，JDK 21 已移除）
- `-XX:BiasedLockingStartupDelay=0`：关闭偏向锁延迟（默认延迟4秒）
- `-XX:-UseBiasedLocking`：禁用偏向锁

## 面试官：说说 JDK 不同版本对 Synchronized 的演进

| JDK 版本 | 关键变化 |
|----------|----------|
| JDK 5 | 引入 Lock 接口和 ReentrantLock，与 Synchronized 对比 |
| JDK 6 | 引入锁升级机制（偏向锁、轻量级锁、锁粗化、锁消除） |
| JDK 8 | 默认开启偏向锁，4秒延迟启动 |
| JDK 9 | 偏向锁延迟改为 5 秒 |
| JDK 15 | **默认关闭偏向锁**（JEP 374） |
| JDK 18 | 偏向锁标记为废弃 |
| JDK 21 | **彻底移除偏向锁**（JEP 453） |

JDK 21 移除偏向锁的原因：
1. 偏向锁的代码维护成本高
2. 高并发场景下偏向锁撤销的开销很大
3. 虚拟线程等新并发模型的引入，偏向锁的存在意义降低
4. 现代应用基本不会单一线程反复获取锁

## 面试官：Synchronized 和 ReentrantLock 怎么选？

| 特性 | Synchronized | ReentrantLock |
|------|-------------|---------------|
| 语法 | 关键字，简洁 | API，需要手动加解锁 |
| 锁类型 | 非公平锁 | 公平锁 / 非公平锁 |
| 中断响应 | 不持锁线程不可中断 | `lockInterruptibly()` 可中断 |
| 超时 | 不支持 | `tryLock(timeout, unit)` 支持 |
| 条件等待 | `wait/notify`，一个条件队列 | `newCondition()`，多个条件队列 |
| 可重入 | 支持 | 支持 |
| 性能 | JDK 6优化后与ReentrantLock基本持平 | 同左 |

**选择建议：**
- 能用 Synchronized 就用 Synchronized（简洁、不易出错）
- 需要超时、可中断、多个条件队列时用 ReentrantLock
- 读多写少场景考虑 ReadWriteLock 或 StampedLock

## 总结

Synchronized 从 JDK 6 开始的锁升级机制，让它从一个"重量级"选手变成了一个"自适应"的同步工具：

- **偏向锁**：单线程反复获取时，零CAS零开销
- **轻量级锁**：线程交替执行时，CAS代替互斥量
- **重量级锁**：真正多线程竞争时，OS互斥量保证公平

**面试追问列表：**
1. ❓ 偏向锁为什么默认有 4 秒延迟？→ JVM 启动时大量对象分配，避免大量锁撤销
2. ❓ 调用 hashCode 为什么会导致偏向锁撤销？→ Mark Word 空间有限，存不下 hashCode
3. ❓ 重量级锁的 wait/notify 实现原理？→ ObjectMonitor 的 _WaitSet 和 _EntryList 协作
4. ❓ JDK 21 移除偏向锁后有什么影响？→ 少量性能回归，但可接受
5. ❓ Synchronized 在 try-finally 中是怎么实现的？→ monitorenter/monitorexit 字节码指令对

理解 Synchronized 的锁升级机制，不仅能帮你写出更好的并发代码，还能让你在面试时展现对 JVM 底层实现的深入理解。
