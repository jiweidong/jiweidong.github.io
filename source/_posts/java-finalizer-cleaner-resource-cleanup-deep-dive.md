---
title: 【JVM 底层】Finalizer 与 Cleaner 深度解析：finalize 的废弃、Cleaner 实现与资源泄漏治理
date: 2026-09-18 08:00:00
tags:
  - Java
  - JVM
  - 引用
  - 内存管理
categories:
  - Java
  - JVM
author: 东哥
---

# 【JVM 底层】Finalizer 与 Cleaner 深度解析：finalize 的废弃、Cleaner 实现与资源泄漏治理

## 面试官：`finalize()` 方法有什么用？为什么被废弃了？

「对象被回收前可以做最后一件事」——这个回答只值 30 分。真正的答法是：**它做过什么、为什么所有 JDK 专家都劝你别用、JDK 9 废弃它之后用什么替代、替代方案 `Cleaner` 本身又有什么坑。**

这是一个能把「引用体系 + GC 交互 + 工程权衡」串起来的绝佳话题。

---

## 一、`finalize()` 做过什么

```java
@Override
protected void finalize() throws Throwable {
    try {
        close();   // 释放资源
    } finally {
        super.finalize();
    }
}
```

设计初衷：给对象一次「临死前」清理 native 资源（文件句柄、Socket、DirectBuffer）的机会。

问题在于它把「资源释放」这件事绑在了「GC 时机」上，而 GC 时机 **完全不确定**。

---

## 二、为什么废弃：五个致命缺陷

### 2.1 执行时机不确定，甚至可能永远不执行

`finalize()` 由 JVM 内部的 **FinalizerThread** 调用，只有 `Finalizer` 引用（`FinalReference` 子类）被 GC 判定为「不可达」并放入 `ReferenceQueue` 后才会排队执行。

推论：**只要对象一直活着，或者堆一直没触发 GC，`finalize()` 就永远不执行。**

```java
// 典型事故：文件句柄泄漏
public class Leaky {
    private FileInputStream in;
    @Override protected void finalize() throws Throwable {
        in.close();   // 可能几小时后才执行，也可能永不执行
        super.finalize();
    }
}
```

堆内存充裕（`-Xmx8g`）而文件句柄耗尽的场景极其常见：GC 不着急回收，`finalize()` 不执行，句柄先耗尽 —— 这就是经典的 **「内存没满但 Too many open files」**。

### 2.2 让对象多活一轮，制造「GC 延迟」

这是最容易被低估的性能问题。GC 对可 finalize 对象的处理流程：

```text
第一次标记：对象不可达，但「需要 finalize」→ 不回收，放入 F-Queue
    ↓
FinalizerThread 异步取出并执行 finalize()
    ↓
第二次标记：对象真正不可达 → 回收
```

**结论：实现 `finalize()` 的对象至少要经历两次 GC 周期才能被回收，期间它一直占着内存。** 大批量创建这类对象会导致老年代快速膨胀、Full GC 频繁，出现「明明已经不用的对象却迟迟回收不掉」。

### 2.3 `FinalizerThread` 只有一个，还会阻塞

```java
@Override protected void finalize() {
    while (true) { /* 死循环 */ }   // FinalizerThread 永久卡死
}
```

`FinalizerThread` 是**单线程**的（优先级还很低）。任何一个 `finalize()` 阻塞 / 死循环 / 执行极慢，都会让 **整个 JVM 的所有 finalize 排队等待**，最终导致内存无法释放 → OOM。

### 2.4 异常被静默吞掉

`finalize()` 里抛出的异常会被 JVM **直接忽略**（只是不终止 finalize 的继续执行），你永远不会看到日志。排查问题时完全无迹可寻。

### 2.5 对象「复活」（Resurrection）

```java
@Override protected void finalize() {
    GlobalCache.holder = this;   // 把自己重新挂到可达对象上
}
```

对象可以在 `finalize()` 里把自己「复活」。而且 **同一个对象的 `finalize()` 只会被调用一次**，如果第二次又变成不可达，就会直接回收，不再有机会清理。这种语义让资源管理逻辑变得不可推理。

### 2.6 JDK 的废弃时间线

| 版本 | 变化 |
| --- | --- |
| JDK 9 | `Object.finalize()` 标记 `@Deprecated` |
| JDK 18 | 标记 `@Deprecated(forRemoval = true)` |
| 未来版本 | 计划移除 |

新代码中 **绝对不应该** 依赖 `finalize()`。

---

## 三、官方替代方案：`java.lang.ref.Cleaner`

JDK 9 引入 `Cleaner`（位于 `java.lang.ref`）：

```java
import java.lang.ref.Cleaner;

public class NativeResource implements AutoCloseable {

    private static final Cleaner CLEANER = Cleaner.create();

    private static class State implements Runnable {
        private long handle;
        private volatile boolean closed;

        State(long handle) { this.handle = handle; }

        @Override public void run() {
            if (!closed) {
                closed = true;
                nativeFree(handle);      // 释放 native 资源
                System.out.println("cleaned by Cleaner");
            }
        }
    }

    private final State state;
    private final Cleaner.Cleanable cleanable;

    public NativeResource(long handle) {
        this.state = new State(handle);
        this.cleanable = CLEANER.register(this, state);   // 注册清理动作
    }

    @Override public void close() {
        cleanable.clean();      // 显式清理：幂等，重复调用安全
    }

    private static native void nativeFree(long handle);
}
```

`Cleaner` 的设计要点：

| 特性 | 说明 |
| --- | --- |
| 基于虚引用 | 内部用 `PhantomReference`，比 `finalize` 更可靠 |
| 独立线程池 | 每个 `Cleaner` 实例有一个守护线程执行清理任务 |
| 注册与目标分离 | `register(observe, cleanupAction)` —— **清理动作不能引用被观察对象**（否则对象永远可达，永远不回收） |
| 幂等 | `clean()` 可重复调用，只执行一次清理 |
| 可显式调用 | 配合 `AutoCloseable` 实现确定性释放 |

### 3.1 核心实现原理

```java
public final class Cleaner {
    public static Cleaner create() {
        return new CleanerImpl();          // 内含 CleanerThread
    }
    public Cleanable register(Object obj, Runnable action);
}
```

内部结构（简化）：

```text
CleanerImpl
  ├── PhantomCleanable / phantom reference 链
  └── CleanerThread（守护线程）
        循环：ReferenceQueue.poll() → 取出 PhantomCleanable → 执行 thunk.run()
```

流程：

1. `register(target, action)` 创建一个 `PhantomReference`（`PhantomCleanable`），把 `action` 存在 `thunk` 字段里；
2. 当 `target` 只被虚引用「引用」时（虚引用不阻止回收），GC 把该 `PhantomReference` 入队；
3. `CleanerThread` 从队列取出并执行 `action.run()`；
4. 清理动作自己持有 `PhantomReference` 的强引用，保证执行期间不被重复清理。

**与 `finalize` 的本质区别**：虚引用在 **对象被回收之后** 才入队，且不影响对象的可达性判定；而 `finalize` 需要对象「先假复活一轮」。所以 `Cleaner` **不会让对象多活一轮**（内存能在第一次 GC 就被回收），执行时机也更早更可靠。

### 3.2 JDK 内部就在用 Cleaner

`DirectByteBuffer` 的堆外内存释放是经典案例：

```java
// 简化示意
DirectByteBuffer(int cap) {
    ...
    cleaner = Cleaner.create(this, new Deallocator(base, size, cap));
}
```

这就是为什么 **不显式释放的 DirectBuffer 也能被回收**——靠 Cleaner 在 GC 后调用 `Unsafe.freeMemory`。同时也是「Java 进程 RSS 不降」的常见原因：堆外内存要等堆内对象被 GC 且 Cleaner 执行才释放。

⚠️ 相关参数 `-XX:MaxDirectMemorySize` 与 `Cleaner` 的配合：如果 direct memory 达到上限会触发 `System.gc()`（默认行为），试图回收 DirectBuffer —— 这是 **显式 GC 的合法来源之一**，也是「明明没调用 System.gc 却有 Full GC」的解释。

---

## 四、最重要的坑：`Cleaner` 注册时不能引用目标对象

这是 Cleaner 使用失败的头号原因：

```java
// ❌ 错误写法：匿名内部类隐式持有 outer 引用
public class Bad {
    private static final Cleaner CLEANER = Cleaner.create();
    private final Cleaner.Cleanable cleanable;

    public Bad() {
        cleanable = CLEANER.register(this, () -> {
            System.out.println(this);      // 捕获了 this！
        });
    }
}
```

`register(this, action)` 中的 `action` 是 `this` 的 lambda，**匿名类持有外部类实例的强引用** → `this` 永远可达 → PhantomReference 永远不入队 → 清理永不执行。

**正确写法**：清理动作必须是 **静态类 / 静态方法 / 不引用目标的 lambda**，所有需要的数据通过构造参数传入（就像上面 `State` 的例子）。

判断方法：`action` 里凡是出现 `this.x`、`Outer.this` 的都应该改。

### 4.1 其它坑

| 坑 | 说明 | 规避 |
| --- | --- | --- |
| 清理线程异常 | CleanerThread 里抛异常会导致该线程退出，后续清理全部失效 | `action.run()` 内部加强 try-catch |
| 清理线程数量 | 每个 `Cleaner.create()` 一个线程；大量 create 会线程爆炸 | 用静态单例 `Cleaner` |
| 依赖 GC 触发 | 虽然比 finalize 可靠，但仍需 GC 才入队 | 必须同时实现 `AutoCloseable` |
| 清理顺序未定义 | 多个 Cleanable 的清理顺序不保证 | 不要依赖顺序 |
| 长时间阻塞 | CleanerThread 被阻塞 → 清理积压 → 内存/句柄压力 | 清理动作要快，慢活丢给线程池 |

### 4.2 Cleaner 不能替代 close

**Cleaner 只是「安全网」，不是「主路径」。** 正确姿势永远是：

```java
try (NativeResource r = new NativeResource(handle)) {
    r.use();
}   // close() → cleanable.clean() → 确定性释放
```

`Cleaner` 只兜底「使用者忘记 close」的情况。

---

## 五、正确释放资源的四层方案

按推荐度排序：

### 5.1 第一选择：`try-with-resources` + `AutoCloseable`

```java
try (Connection conn = ds.getConnection();
     PreparedStatement ps = conn.prepareStatement(SQL)) {
    ...
}
```

编译后自动生成 `finally` 调用 `close()`，异常抑制（`addSuppressed`）由编译器处理，是目前最可靠的确定性释放方式。

### 5.2 第二选择：`Cleaner` 兜底

在实现 `AutoCloseable` 的同时注册 `Cleaner`，防止调用方忘记 close。

### 5.3 第三选择：显式生命周期管理

框架级资源（连接池、线程池、Netty EventLoopGroup）用 `@PreDestroy` / `DisposableBean` / `shutdown()` 显式释放：

```java
@PreDestroy
public void destroy() {
    executor.shutdown();
    try { executor.awaitTermination(30, TimeUnit.SECONDS); }
    catch (InterruptedException e) { Thread.currentThread().interrupt(); executor.shutdownNow(); }
}
```

### 5.4 绝对不要：依赖 `finalize()`

如果接手的老代码里有 `finalize()`：

```java
// 迁移步骤
// 1) 实现 AutoCloseable，把 finalize 里的逻辑抽到静态 State#run
// 2) 注册 Cleaner 兜底
// 3) 全局搜索使用方，补上 try-with-resources
// 4) 删除 finalize 方法
```

---

## 六、资源泄漏排查实战

### 6.1 判断是堆泄漏 / 句柄泄漏 / 堆外泄漏

```bash
# 堆：看 old gen 与 Full GC 后回收率
jstat -gcutil <pid> 1000

# 堆外：JVM 内部统计
jcmd <pid> VM.native_memory summary          # 需 -XX:NativeMemoryTracking=summary
# 或
jcmd <pid> VM.metaspace
jcmd <pid> VM.info | grep -i direct

# 句柄：数量与类型
ls /proc/<pid>/fd | wc -l
ls -l /proc/<pid>/fd | awk '{print $11}' | sort | uniq -c | sort -rn | head
```

句柄持续增长但堆稳定 → **典型的「依赖 finalize / Cleaner 释放」导致的泄漏**。

### 6.2 确认 Finalizer 队列积压

```bash
jmap -finalizerinfo <pid>
```

输出：

```text
Number of objects awaiting finalization: 1283741
```

一旦这个数字很大，说明 `FinalizerThread` 处理不过来，堆里全是等 finalize 的对象。这是「OOM 但 heap dump 里看到大量 `Finalizer` 引用链」的原因。

heap dump 里 `java.lang.ref.Finalizer` 对象数量巨大，是非常明确的信号。

### 6.3 用 JFR 观察清理行为

```bash
jcmd <pid> JFR.start duration=60s filename=cleanup.jfr
```

关注：

- `jdk.ObjectAllocationInNewTLAB` / 类分布 —— 找异常增长的类；
- `jdk.GCPhasePause` —— 是否 GC 频繁且回收率低；
- `jdk.NativeMemoryUsage` —— 堆外是否增长。

### 6.4 真实案例：Netty 的 `ResourceLeakDetector`

Netty 的 `ByteBuf` 是「必须释放的引用计数对象」，它内置了泄漏检测：

```bash
-Dio.netty.leakDetection.level=paranoid
```

它靠 `WeakReference` / `PhantomReference` 追踪 `ByteBuf` 的回收路径，本质思想和 `Cleaner` 一致：**用引用机制做「安全网 + 诊断」，而不是做「主路径释放」**。

---

## 七、面试追问合集

**Q1：`finalize()` 和 `Cleaner` 的本质区别是什么？**
`finalize()` 需要对象「先复活一轮」才能执行清理，导致对象至少多活一个 GC 周期；`Cleaner` 基于虚引用，对象被回收后才入队执行清理，不影响可达性判定，也不让对象多活。两者都依赖 GC，但 `Cleaner` 更早、更可靠、更可控。

**Q2：为什么 Cleaner 的清理动作不能引用目标对象？**
因为 `register(target, action)` 中 `action` 若强引用 `target`，`target` 就永远可达，虚引用永远不入队，清理永不发生。必须把状态抽成静态类，只传数据不传对象引用。

**Q3：`System.gc()` 能保证清理执行吗？**
不能。`System.gc()` 只是「建议」。即使 GC 发生，`Cleaner` 的执行还要等 `CleanerThread` 调度，且 `System.gc()` 可以被 `-XX:+DisableExplicitGC` 忽略。

**Q4：`PhantomReference` 和 `WeakReference` 在 Cleaner 里的角色区别？**
`WeakReference` 在对象进入「弱可达」后就入队，可能在对象内存被回收前；`PhantomReference` 只在对象**即将被回收（内存已释放）** 时入队，保证清理动作执行时不会与对象状态冲突。Cleaner 选择虚引用就是为了「确定对象已死」。

**Q5：堆外内存为什么释放不及时？**
因为 `DirectByteBuffer` 的回收依赖两件事：堆内 `DirectByteBuffer` 对象被 GC + `Cleaner` 执行 `Unsafe.freeMemory`。堆充足时 GC 不触发，堆外就一直不释放。生产上要配合 `-XX:MaxDirectMemorySize` 限制与主动 `Unsafe`/`Cleaner` 释放（或改用池化方案，如 Netty 的 `PooledByteBufAllocator`）。

**Q6：为什么不给所有资源都加 Cleaner？**
Cleaner 有成本：每次 `register` 创建虚引用对象（增加 GC 压力）、每个 Cleaner 一个线程、清理时机仍不确定。**它只应作为「忘记 close」的兜底，主路径永远应是显式的 `try-with-resources`。**

---

## 八、小结

| 维度 | `finalize()` | `Cleaner` | `try-with-resources` |
| --- | --- | --- | --- |
| 引入版本 | Java 1.0 | JDK 9 | JDK 7 |
| 底层机制 | `FinalReference` + F-Queue | `PhantomReference` + `ReferenceQueue` | 编译器生成 finally |
| 执行时机 | 不确定，且对象多活一轮 | 相对确定，不影响对象存活 | 确定性 |
| 性能 | 差（延迟 GC、单线程） | 中（虚引用开销） | 最好 |
| 推荐度 | ❌ 禁用 | ⚠️ 兜底 | ✅ 主路径 |

三句话总结：

1. **`finalize()` 的废弃不是「风格问题」，而是「对象多活一轮 + 单线程 + 异常静默 + 时机不确定」四重工程缺陷**；
2. **`Cleaner` 是安全网而非主路径**，注册时清理动作绝不能持有目标对象引用；
3. **一切资源释放的第一原则永远是「显式、确定、幂等」**，让 GC 决定资源何时释放，本身就是设计缺陷。
