---
title: 【并发编程】Java 死锁深度解析：产生条件、排查实战与预防策略
date: 2026-08-15 08:00:00
tags:
  - Java
  - 并发
  - 死锁
  - 面试
categories:
  - Java
  - 并发编程
  - 后端面试
author: 东哥
---

# 【并发编程】Java 死锁深度解析：产生条件、排查实战与预防策略

## 面试官：写一个死锁出来？死锁的四个必要条件是什么？线上死锁怎么排查？

死锁是并发编程面试的"必考送分题"——但送分的前提是你能**现场写出一个死锁**、**背出四个必要条件**、**说出排查手段**、**给出至少三种预防方案**。今天一篇全搞定，附带真实线上排查案例。

## 一、什么是死锁？先看一段能跑的死锁代码

```java
public class DeadlockDemo {

    private static final Object LOCK_A = new Object();
    private static final Object LOCK_B = new Object();

    public static void main(String[] args) {
        // 线程 1：先拿 A 再拿 B
        new Thread(() -> {
            synchronized (LOCK_A) {
                System.out.println(Thread.currentThread().getName() + " 持有 A，等待 B...");
                try { Thread.sleep(100); } catch (InterruptedException ignored) {}
                synchronized (LOCK_B) {
                    System.out.println(Thread.currentThread().getName() + " 获取到 B");
                }
            }
        }, "线程-1").start();

        // 线程 2：先拿 B 再拿 A —— 与线程 1 的加锁顺序相反
        new Thread(() -> {
            synchronized (LOCK_B) {
                System.out.println(Thread.currentThread().getName() + " 持有 B，等待 A...");
                try { Thread.sleep(100); } catch (InterruptedException ignored) {}
                synchronized (LOCK_A) {
                    System.out.println(Thread.currentThread().getName() + " 获取到 A");
                }
            }
        }, "线程-2").start();
    }
}
```

运行结果：两个线程各持一把锁，互相等待对方释放，**程序永远卡住，既不报错也不退出**。这就是死锁最阴险的地方——**没有异常，只有"卡死"**。

## 二、死锁的四个必要条件（背下来，缺一不可）

| 条件 | 含义 | 破坏手段 |
|------|------|----------|
| 1. 互斥 | 资源同一时刻只能被一个线程占用 | 无法破坏（锁的本质） |
| 2. 持有并等待 | 线程持有一个资源，同时等待另一个资源 | **一次性申请所有资源** |
| 3. 不可剥夺 | 资源只能由持有者主动释放 | **超时释放（tryLock）** |
| 4. 循环等待 | 多个线程形成"你等我、我等你"的环 | **全局有序加锁** |

> 死锁 = 四个条件**同时满足**。所以预防死锁的思路就是：**打破其中任意一个可操作的条件**。

## 三、死锁的排查实战

### 3.1 用 jstack 快速定位（最重要）

```bash
# 1. 先找到卡死的 Java 进程
jps -l
# 输出：12345 com.example.DeadlockDemo

# 2. 导出线程快照
jstack 12345
```

`jstack` 输出的末尾会直接给出死锁分析：

```
Found one Java-level deadlock:
=============================
"线程-1":
  waiting to lock monitor 0x00007f0d2c002f28 (object 0x000000076b5f8e80, a java.lang.Object),
  which is held by "线程-2"
"线程-2":
  waiting to lock monitor 0x00007f0d2c002f28 (object 0x000000076b5f8e80, a java.lang.Object),
  which is held by "线程-1"

Java stack information for the threads listed above:
===================================================
...
```

**关键看三点**：`Found one Java-level deadlock` 明确提示；两个线程的 `waiting to lock ... which is held by ...` 构成循环；堆栈中的业务方法名帮我们定位到代码位置。

### 3.2 实战排查三板斧

1. **jps 找进程** → `jstack <pid>` 看死锁报告；
2. 没有明确死锁提示但系统卡顿 → 看 `BLOCKED` 状态的线程，找它们各自等哪把锁、锁被谁持有，画依赖图找环；
3. **线程 Dump 要连续打 2~3 次**（间隔几秒），如果同一批线程持续 BLOCKED 且锁持有者不变，基本可以确认死锁而非偶发等待。

```bash
# 连续采样两次对比
for i in 1 2 3; do jstack 12345 > /tmp/dump_$i.txt; sleep 3; done
grep -c "BLOCKED" /tmp/dump_*.txt
```

### 3.3 数据库死锁 vs Java 死锁

| 维度 | Java 死锁 | MySQL 死锁 |
|------|-----------|------------|
| 报错 | 无异常，卡死 | 抛出 `Deadlock found when trying to get lock`，自动回滚一个事务 |
| 排查 | jstack 线程快照 | `SHOW ENGINE INNODB STATUS` 看 LATEST DETECTED DEADLOCK |
| 修复 | 代码加锁顺序 | SQL/事务顺序、索引设计 |

## 四、死锁的预防与解决策略

### 4.1 策略一：全局有序加锁（最常用）

所有线程**按相同顺序获取锁**，循环等待就不可能形成：

```java
// 统一约定：先锁 A 再锁 B，杜绝交叉
public void transfer(Account from, Account to, BigDecimal amount) {
    // 按账户 id 排序，保证所有线程加锁顺序一致
    Account first = from.getId() < to.getId() ? from : to;
    Account second = from.getId() < to.getId() ? to : from;

    synchronized (first) {
        synchronized (second) {
            // 转账逻辑
        }
    }
}
```

转账场景是教科书级案例：两个线程互相转钱，若不排序就会 A→B、B→A 形成环。

### 4.2 策略二：超时释放（tryLock）

用 `ReentrantLock` 的 `tryLock(timeout)` 代替无期限的 `lock()`，获取不到就放弃并回滚自己的操作：

```java
ReentrantLock lockA = new ReentrantLock();
ReentrantLock lockB = new ReentrantLock();

public void doWork() {
    if (lockA.tryLock(2, TimeUnit.SECONDS)) {
        try {
            if (lockB.tryLock(2, TimeUnit.SECONDS)) {
                try {
                    // 业务逻辑
                } finally {
                    lockB.unlock();
                }
            } else {
                // 获取 B 超时：释放 A，稍后重试（放弃本次操作）
            }
        } finally {
            lockA.unlock();
        }
    }
}
```

> 注意：tryLock 超时后要**释放已持有的锁**，否则"超时失败"会演变成"死等"；业务上通常配合重试或失败补偿。

### 4.3 策略三：一次性申请所有资源（原子获取）

要么全部拿到，要么一个都不拿。实现上可以用一个"资源管理器"统一分配，或用一个更粗粒度的锁包住多资源操作——代价是并发度下降。

### 4.4 策略四：减少锁粒度与持有时间

- 锁的持有时间越短，死锁窗口越小：**不要在锁内做 IO、网络调用、远程 RPC**；
- 能用 `synchronized` 块就不用方法级同步；
- 考虑 `ConcurrentHashMap`、`Atomic*`、不可变对象等**无锁/弱锁方案**，从根上消灭死锁。

### 4.5 策略五：检测与恢复

JVM 本身不做死锁检测（MySQL InnoDB 会自动检测并回滚），所以生产上要：

- 监控线程 BLOCKED 数量和线程 Dump；
- 设置**锁等待超时**告警；
- 出现死锁后 dump 现场、人工/自动重启受影响服务（兜底手段，治标不治本）。

## 五、面试常见追问

**Q1：synchronized 能超时吗？为什么推荐 tryLock？**
`synchronized` 不支持超时，会无限等待；`ReentrantLock.tryLock(timeout)` 支持超时放弃，从而破坏"不可剥夺"条件，是应对死锁的关键武器。

**Q2：死锁和活锁、饥饿有什么区别？**
- **死锁**：互相等待，永远阻塞；
- **活锁**：线程没阻塞但一直在重复做无用功（比如两个线程互相谦让、反复重试），资源可能被饿死；
- **饥饿**：低优先级线程长期得不到调度/锁，一直等不到执行。

**Q3：一个线程能自己把自己死锁吗？**
`synchronized` 是**可重入**的，同一线程重复获取同一把锁没问题。但**不可重入锁**（如自实现锁）或"锁顺序不当"（如先拿 A 再在持 A 时等 A 的另一个实例）可能造成单线程死锁——本质上还是循环等待。

**Q4：线上出现死锁第一件事做什么？**
先 `jstack` 抓现场（保留证据），确认死锁环路和涉及的代码位置，再评估影响；紧急时重启或 kill 掉卡住的线程（注意数据一致性），根因修复走"统一加锁顺序 / 超时 / 减小锁粒度"。

## 六、小结

死锁的本质是**四个必要条件同时成立**，预防就是打破其中一个。面试答题模板：**先写出可运行的死锁 demo → 背四个条件 → 说 jstack 排查 → 给预防方案（有序加锁、tryLock 超时、减少锁持有时间、无锁化）**。线上遇到"程序卡死不报错"的问题，第一个排查动作永远是线程 Dump。理解死锁，不只是为了面试——它直接决定你写的并发代码在真实流量下能不能活下来。
