---
title: 【Java核心】Java 随机数生成器深度解析：Random、ThreadLocalRandom 与 SecureRandom 原理与最佳实践
date: 2026-07-07 08:00:00
tags:
  - Java
  - 随机数
  - 并发
  - 安全
categories:
  - Java
  - Java核心
author: 东哥
---

# 【Java核心】Java 随机数生成器深度解析：Random、ThreadLocalRandom 与 SecureRandom 原理与最佳实践

## 再平凡的 API 也有不平凡的故事

几乎每个 Java 开发者都写过 `new Random().nextInt()` 或 `Math.random()`。

但你真的了解它们背后的机制吗？

- 为什么高并发下 `Random` 性能会断崖式下降？
- `ThreadLocalRandom` 是如何解决这个问题的？
- 密码学中的 `SecureRandom` 和普通随机数有什么区别？
- 为什么说 `Math.random()` 是一个"坑"？

本文将从源码到实战，系统梳理 Java 三大随机数生成器的核心原理与选型策略。

---

## 一、Random：最常用的随机数生成器

### 1.1 核心原理：线性同余生成器（LCG）

`java.util.Random` 基于**线性同余生成器（Linear Congruential Generator, LCG）**算法：

```
seed = (seed * multiplier + addend) % modulus
     = (seed * 0x5DEECE66DL + 0xBL) & ((1L << 48) - 1)
```

每次调用 `next()` 时，通过一个 **CAS 操作**更新种子：

```java
private final AtomicLong seed;

protected int next(int bits) {
    long oldseed, nextseed;
    AtomicLong seed = this.seed;
    do {
        oldseed = seed.get();
        nextseed = (oldseed * multiplier + addend) & mask;
    } while (!seed.compareAndSet(oldseed, nextseed));
    return (int)(nextseed >>> (48 - bits));
}
```

**关键点**：
- 种子是 `AtomicLong` 类型，保证了多线程下的线程安全
- CAS 自旋是并发问题的根源——当多个线程竞争同一个种子时，大量 CAS 失败导致性能下降

### 1.2 性能瓶颈分析

开启 8 个线程并发调用 `Random.nextInt()`，对比单线程测试：

```
单线程：          ~35 ns/op
8 线程并发：      ~3500 ns/op（性能下降 100 倍！）
```

**性能断崖的原因**：
1. 所有线程共享同一个 `AtomicLong` 种子
2. 每次生成随机数都需要 CAS 更新
3. 高并发下 CAS 自旋次数急剧上升，甚至触发缓存行伪共享

### 1.3 nextInt() 的"不均匀"问题

`Random` 的 `nextInt(n)` 方法如果 `n` 不是 2 的幂，需要进行**拒绝采样**：

```java
public int nextInt(int bound) {
    if (bound <= 0)
        throw new IllegalArgumentException(BadBound);

    int r = next(31);
    int m = bound - 1;
    if ((bound & m) == 0)  // 2 的幂
        r = (int)((bound * (long)r) >> 31);
    else {
        for (int u = r; u - (r = u % bound) + m < 0;  // 拒绝采样循环
            u = next(31))
            ;
    }
    return r;
}
```

当 `bound` 不是 2 的幂时，有概率进入拒绝采样循环，增加不确定性的延迟。

---

## 二、ThreadLocalRandom：并发场景的救星

### 2.1 设计思想：每个线程一个种子

`ThreadLocalRandom` 是 JDK 7 引入的并发专用随机数生成器，核心思想是**每个线程持有自己的种子**，避免 CAS 竞争：

```java
public class ThreadLocalRandom extends Random {
    // 种子存储在 Thread 对象的 threadLocalRandomSeed 字段中
    // 通过 Unsafe 直接存取

    public int nextInt(int bound) {
        if (bound <= 0)
            throw new IllegalArgumentException(BadBound);
        int r = mix32(nextSeed());
        int m = bound - 1;
        if ((bound & m) == 0)    // 2 的幂
            r &= m;
        else {
            for (int u = r >>> 1; u + m - (r = u % bound) < 0; u = mix32(nextSeed()) >>> 1)
                ;
        }
        return r;
    }
}
```

### 2.2 种子如何做到线程私有？

通过 `Thread` 类的三个字段实现：

```java
// java.lang.Thread 中
@jdk.internal.vm.annotation.Contended("tlr")
long threadLocalRandomSeed;       // 种子

@jdk.internal.vm.annotation.Contended("tlr")
int threadLocalRandomProbe;      // 探针哈希（用于初始化）

@jdk.internal.vm.annotation.Contended("tlr")
int threadLocalRandomSecondarySeed;  // 辅助种子（ForkJoinPool 使用）
```

`ThreadLocalRandom` 通过 `Unsafe.putLong()` 直接操作当前线程的 `threadLocalRandomSeed` 字段，完全避免了 CAS 竞争和对象分配：

```java
final long nextSeed() {
    Thread t = Thread.currentThread();
    long s; // 读取当前线程种子
    U.putLong(t, SEED, s = U.getLong(t, SEED) + GAMMA);
    return s;
}
```

**注意**：这里用的是 `putLong` 而不是 CAS！因为每个线程只操作自己的种子，没有竞争，不需要 CAS。

### 2.3 @Contended 注解与伪共享优化

`@Contended("tlr")` 注解使得 `threadLocalRandomSeed`、`threadLocalRandomProbe`、`threadLocalRandomSecondarySeed` 三个字段被填充在独立的缓存行中，避免与其他线程的 `Thread` 字段发生**伪共享（False Sharing）**。

### 2.4 性能对比

```
8 线程并发性能对比：
Random：             ~3500 ns/op
ThreadLocalRandom：  ~35 ns/op（性能提升 100 倍）
```

### 2.5 使用方式

```java
// 正确用法
int randomInt = ThreadLocalRandom.current().nextInt(100);
double randomDouble = ThreadLocalRandom.current().nextDouble();

// 错误用法：不要实例化
ThreadLocalRandom r = new ThreadLocalRandom();  // 编译错误！构造器是包级私有的
```

---

## 三、SecureRandom：密码学级安全随机数

### 3.1 为什么普通 Random 不适合加密？

**可预测性**：`Random` 的 LCG 算法是确定性的，只要知道当前种子，就能预测所有后续输出。

```java
// 攻击者如果可以获取少量随机数，就能反向推算出种子
long seed = 12345L;
Random r = new Random(seed);
int a = r.nextInt();   // 假设攻击者拿到 a
int b = r.nextInt();   // 攻击者可以推算出 b
```

### 3.2 SecureRandom 的工作原理

`SecureRandom` 使用**真随机熵源**或**密码学安全的伪随机数生成器（CSPRNG）**：

```
熵源收集器（Entropy Gathering）
    ↓
熵池（Entropy Pool）— 维护随机性
    ↓
SHA1PRNG / NativePRNG — 密码学安全算法
    ↓
输出不可预测的随机数
```

**熵源来源**（因操作系统而异）：
- Linux：`/dev/random`（阻塞，高熵）和 `/dev/urandom`（非阻塞，低熵但足够）
- Windows：`CryptGenRandom()`
- macOS：`/dev/urandom`

### 3.3 不同 Provider 的阻塞问题

```java
// 默认实现（在 Linux 上是 NativePRNG）
SecureRandom sr = new SecureRandom();
byte[] bytes = sr.generateSeed(20);  // 可能阻塞等待熵

// 使用 SHA1PRNG 算法（不阻塞）
SecureRandom sr = SecureRandom.getInstance("SHA1PRNG");

// 解决阻塞问题：使用 /dev/urandom
java -Djava.security.egd=file:/dev/urandom MyApp
```

### 3.4 性能对比

```
生成 100 万次随机数：
Random：              ~15ms
ThreadLocalRandom：   ~12ms
SecureRandom：        ~800ms（慢 50-70 倍）
```

---

## 四、Math.random() 的真相

绝大多数人不知道，`Math.random()` 内部使用的就是 `Random`：

```java
public static double random() {
    return RandomNumberGeneratorHelper.nextDouble(ThreadLocalRandom.current());
    // 注意：在较新 JDK 中已改为 ThreadLocalRandom！
    // 早期 JDK 中是静态 Random 实例，会引发并发竞争
}
```

在 JDK 7+ 中，`Math.random()` 已改为委托给 `ThreadLocalRandom`，性能问题已基本解决。

**但还有一个隐藏的问题**：
```java
// 每次调用都要拿 current()，虽然开销很小（~3ns），
// 但如果不小心在循环中调用上亿次，还是有影响的

// OK: 少量调用
for (int i = 0; i < 100; i++) {
    Math.random();  // 没问题
}

// Better: 批量调用
ThreadLocalRandom r = ThreadLocalRandom.current();
for (int i = 0; i < 1000000; i++) {
    r.nextDouble();  // 比 Math.random() 快一点
}
```

---

## 五、选型指南与最佳实践

### 5.1 选型对照表

| 场景 | 推荐方案 | 原因 |
|-----|---------|------|
| 单线程，非安全 | `new Random()` | 简单、够用 |
| 高并发，非安全 | `ThreadLocalRandom` | 性能最佳 |
| 密码学/安全令牌 | `SecureRandom` | 不可预测 |
| UUID/OID 生成 | `SecureRandom` | 需唯一性保证 |
| 游戏/模拟 | `ThreadLocalRandom` 或 `SplittableRandom` | 高吞吐 |
| 科学计算/蒙特卡洛 | `SplittableRandom` | 可拆分、并行友好 |

### 5.2 SplittableRandom：JDK 8 的又一利器

`SplittableRandom` 专为 ForkJoinPool 和并行流设计，支持高效裂变（split）：

```java
SplittableRandom sr = new SplittableRandom();
// 生成两个独立的随机数生成器
SplittableRandom child1 = sr.split();
SplittableRandom child2 = sr.split();
```

### 5.3 常见陷阱

**陷阱 1：每次调用 new Random()**
```java
// 坏习惯：每次调用都 new，种子重复概率高
for (int i = 0; i < 100; i++) {
    int val = new Random().nextInt(100);
    // 在同一毫秒内创建的 Random，种子相同！
}
```

**陷阱 2：不要重用 SecureRandom 种子**
```java
SecureRandom sr = SecureRandom.getInstance("SHA1PRNG");
byte[] seed = sr.generateSeed(20);  // 消耗熵池
SecureRandom sr2 = new SecureRandom(seed);  // 复制种子，不推荐
```

**陷阱 3：用随机数模拟真随机做安全校验**
```java
// 非常危险！攻击者可预测
Random r = new Random();
String token = String.valueOf(r.nextLong());  // ❌ 不要用来生成令牌

// 正确做法
SecureRandom sr = new SecureRandom();
byte[] token = new byte[16];
sr.nextBytes(token);
```

---

## 总结

| 生成器 | 算法 | 线程安全 | 性能 | 安全性 | 适用场景 |
|--------|-----|---------|------|--------|---------|
| Random | LCG | CAS 同步 | 低（并发）~ 中（串行） | ❌ | 单线程非安全 |
| ThreadLocalRandom | LCG 变体 | 线程私有 | **极高** | ❌ | 高并发非安全 |
| SecureRandom | CSPRNG | 同步 | 低 | ✅ | 安全/加密场景 |
| SplittableRandom | 改良 LCG | 裂变 | 高 | ❌ | 并行计算/ForkJoin |

选择合适的随机数生成器，既能避免性能瓶颈，也能规避安全风险。
