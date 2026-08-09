---
title: 【设计模式】装饰器模式深度解析：从 Java IO 流到 Spring 框架的层层包装艺术
date: 2026-08-09 08:00:00
tags:
  - Java
  - 设计模式
  - 源码
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】装饰器模式深度解析：从 Java IO 流到 Spring 框架的层层包装艺术

## 面试官：装饰器模式和代理模式有什么区别？Java 里哪里用了装饰器？

装饰器模式（Decorator Pattern）是结构型设计模式里最高频的面试题之一。它解决的核心问题是：**在不修改原有类代码的前提下，动态地给对象添加职责**。而且它和代理模式长得特别像，面试官最爱问区别。

今天我们从「给咖啡加料」的经典例子入手，深挖 Java IO 流的装饰器源码、装饰器与代理/继承的对比，以及 Spring、MyBatis 等框架中的装饰器实践。

## 一、装饰器模式要解决什么问题？

### 1.1 场景：给对象动态加功能

假设你有一个 `Coffee` 接口，实现类有 `Espresso`（浓缩咖啡）。现在要支持加牛奶、加糖、加奶泡……如果直接用继承：

```
Espresso + 牛奶 → MilkEspresso
Espresso + 糖 → SugarEspresso
Espresso + 牛奶 + 糖 → MilkSugarEspresso
Espresso + 牛奶 + 糖 + 奶泡 → ...
```

**继承爆炸**！功能组合是指数级的，每加一种配料就要新写一堆类。装饰器模式的解法是：**用组合代替继承，把「附加功能」做成一层层的包装**。

### 1.2 装饰器模式的标准结构

```
                    ┌────────────┐
                    │ Component  │  抽象构件：定义接口
                    └─────┬──────┘
              ┌───────────┴───────────┐
      ┌───────┴───────┐       ┌───────┴────────┐
      │ConcreteComponent│      │  Decorator    │  装饰器：持有 Component 引用
      │  具体构件(被装饰)│      └───────┬────────┘
      └───────────────┘      ┌─────────┴─────────┐
                    ┌────────┴───────┐   ┌────────┴────────┐
                    │ConcreteDecoratorA│ │ConcreteDecoratorB│
                    └────────────────┘   └─────────────────┘
```

四个角色：
1. **Component（抽象构件）**：定义对象接口
2. **ConcreteComponent（具体构件）**：被装饰的原始对象
3. **Decorator（抽象装饰器）**：持有 Component 引用，转发请求
4. **ConcreteDecorator（具体装饰器）**：在转发前后附加功能

### 1.3 手写实现：咖啡加料

```java
// 1. 抽象构件
public interface Coffee {
    String getDescription();
    double cost();
}

// 2. 具体构件
public class Espresso implements Coffee {
    public String getDescription() { return "浓缩咖啡"; }
    public double cost() { return 15.0; }
}

// 3. 抽象装饰器：核心是持有 Component
public abstract class CoffeeDecorator implements Coffee {
    protected Coffee coffee;
    public CoffeeDecorator(Coffee coffee) { this.coffee = coffee; }
    public String getDescription() { return coffee.getDescription(); }
    public double cost() { return coffee.cost(); }
}

// 4. 具体装饰器
public class MilkDecorator extends CoffeeDecorator {
    public MilkDecorator(Coffee coffee) { super(coffee); }
    public String getDescription() { return coffee.getDescription() + " + 牛奶"; }
    public double cost() { return coffee.cost() + 3.0; }
}

public class SugarDecorator extends CoffeeDecorator {
    public SugarDecorator(Coffee coffee) { super(coffee); }
    public String getDescription() { return coffee.getDescription() + " + 糖"; }
    public double cost() { return coffee.cost() + 1.5; }
}

// 使用：层层包装
public class Main {
    public static void main(String[] args) {
        Coffee coffee = new Espresso();                      // 浓缩咖啡 15
        coffee = new MilkDecorator(coffee);                  // +牛奶 18
        coffee = new SugarDecorator(coffee);                 // +糖 19.5
        coffee = new MilkDecorator(coffee);                  // 再加一层牛奶 22.5
        System.out.println(coffee.getDescription() + " = " + coffee.cost());
        // 输出: 浓缩咖啡 + 牛奶 + 糖 + 牛奶 = 22.5
    }
}
```

**看到没**：配料自由组合，想加几层加几层，不用创建任何新类！这就是装饰器「动态叠加职责」的威力。

## 二、源码实战：Java IO 流就是装饰器的教科书

### 2.1 你看不懂的 IO 流嵌套之谜

```java
// 最经典的装饰器用法：缓冲 + 字符转换 + 文件读取
BufferedReader reader = new BufferedReader(
        new InputStreamReader(
                new FileInputStream("data.txt"), StandardCharsets.UTF_8));
```

每个 Java 初学者都见过这行代码，但很少有人意识到这是三层装饰器！

### 2.2 对应关系拆解

```
Component（抽象构件）:   InputStream / Reader
ConcreteComponent:      FileInputStream（被装饰的原始对象）
Decorator（抽象装饰器）: FilterInputStream / FilterReader
ConcreteDecorator:      BufferedInputStream、DataInputStream、
                        PushbackInputStream、LineNumberInputStream...
```

看 JDK 源码，`FilterInputStream` 就是标准装饰器：

```java
// JDK 源码：java.io.FilterInputStream
public class FilterInputStream extends InputStream {
    // 持有被装饰的 Component —— 装饰器的标志！
    protected volatile InputStream in;

    protected FilterInputStream(InputStream in) {
        this.in = in;
    }

    // 转发请求，不做任何增强
    public int read() throws IOException {
        return in.read();
    }
    // ... 其他方法全部转发
}
```

而 `BufferedInputStream` 继承 `FilterInputStream`，**重写 read 方法增加缓冲功能**——这就是在转发的基础上附加职责：

```java
// JDK 源码：java.io.BufferedInputStream（简化）
public class BufferedInputStream extends FilterInputStream {
    protected volatile byte buf[];   // 缓冲数组
    protected int count;
    protected int pos;

    public synchronized int read() throws IOException {
        if (pos >= count) {
            fill();                   // 一次读一大块到缓冲
            if (pos >= count)
                return -1;
        }
        return getBufIfOpen()[pos++] & 0xff;  // 直接从缓冲取
    }
}
```

### 2.3 为什么 JDK 要这么设计？

- **职责分离**：FileInputStream 只管读文件，BufferedInputStream 只管加缓冲，各干各的
- **自由组合**：`new BufferedInputStream(new FileInputStream(...))` 随意嵌套
- **开闭原则**：想加新功能（比如加密流 CipherInputStream），只需新写一个 FilterInputStream 子类，不改任何现有代码

## 三、装饰器 vs 代理 vs 继承：面试必考对比

### 3.1 装饰器 vs 代理模式（最容易被问晕的一组）

| 对比维度 | 装饰器模式 | 代理模式 |
|----------|-----------|----------|
| 目的 | 增强功能（加配料） | 控制访问（权限、延迟、日志） |
| 接口 | 必须实现与被装饰者相同的接口 | 可以只暴露部分接口 |
| 构建方式 | 客户端手动层层包装 | 代理类持有目标引用，通常由工厂/框架创建 |
| 关注点 | 功能叠加，可多层嵌套 | 访问控制，通常一层 |
| 典型例子 | Java IO 流、Spring 的 TransactionAwareCacheDecorator | JDK 动态代理、Spring AOP、MyBatis Mapper 代理 |

**一句话区分**：装饰器是「我变强了」（增强能力，客户端感知不到差别，还是同一个接口），代理是「我替你把门」（控制访问，可能附加额外逻辑但本质是替身）。

### 3.2 装饰器 vs 继承

| 维度 | 继承 | 装饰器 |
|------|------|--------|
| 组合能力 | 编译期固定，无法动态组合 | 运行期动态叠加 |
| 类爆炸 | 功能组合指数级膨胀 | 每个功能一个装饰器类，线性增长 |
| 修改范围 | 影响所有子类 | 只影响被包装的那个对象 |
| 破坏封装 | 继承破坏封装（暴露父类细节） | 不破坏，透明包装 |

## 四、框架中的装饰器实践

### 4.1 Spring 中的装饰器

Spring 里最典型的装饰器是 **`TransactionAwareCacheDecorator`**——给 Cache 包装上事务感知能力：

```java
// Spring 源码（简化）
public class TransactionAwareCacheDecorator implements Cache {
    private final Cache targetCache;   // 持有被装饰的 Cache

    @Override
    public void put(Object key, Object value) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            // 事务中：延迟到事务提交后再写缓存（增强逻辑）
            TransactionSynchronizationManager.registerSynchronization(
                    new TransactionSynchronization() {
                        @Override
                        public void afterCommit() {
                            targetCache.put(key, value);  // 转发给目标
                        }
                    });
        } else {
            targetCache.put(key, value);  // 无事务直接转发
        }
    }
}
```

还有 **`BeanPostProcessor` 体系里的各种包装**、`WebClient` 的 filter 链，本质上都是装饰器思想。

### 4.2 MyBatis 中的装饰器

MyBatis 的 **`Executor`** 就是用装饰器层层包装的：

```
BaseExecutor（基础执行器）
    └── CachingExecutor（二级缓存装饰器：先查缓存再委托）
            └── 实际执行时还有 StatementHandler 层面的装饰
```

```java
// MyBatis 源码：CachingExecutor 就是标准装饰器
public class CachingExecutor implements Executor {
    private final Executor delegate;   // 持有被装饰的 Executor

    public CachingExecutor(Executor delegate) {
        this.delegate = delegate;
    }

    @Override
    public <E> List<E> query(MappedStatement ms, Object parameter, ...) {
        // 1. 先查二级缓存
        Cache cache = ms.getCache();
        if (cache != null) {
            // 命中缓存直接返回...
            if (result != null) return result;
        }
        // 2. 缓存没命中，委托给被装饰的 Executor
        return delegate.query(ms, parameter, rowBounds, resultHandler, cacheKey, boundSql);
    }
}
```

### 4.3 其他常见场景

| 框架/场景 | 装饰器应用 |
|-----------|-----------|
| Java IO | FilterInputStream/FilterOutputStream/FilterReader/FilterWriter 全家桶 |
| JDK 集合 | Collections.synchronizedList()、unmodifiableList() 返回的就是包装类 |
| Spring | TransactionAwareCacheDecorator、HttpServletRequestWrapper（Servlet API） |
| MyBatis | CachingExecutor 装饰 Executor |
| Dubbo | ProtocolFilterWrapper 等层层包装 |

## 五、装饰器模式的优缺点与使用场景

### 5.1 优点

- ✅ 开闭原则：不修改原类即可扩展功能
- ✅ 组合优于继承：动态叠加，避免类爆炸
- ✅ 职责单一：每个装饰器只做一件事
- ✅ 透明：客户端无感知，接口不变

### 5.2 缺点

- ❌ 类数量增多，调试变复杂（一层层包装，堆栈深）
- ❌ 多层装饰后对象关系难理解（`new A(new B(new C(new D())))` 谁包谁容易懵）
- ❌ 出错时堆栈信息不直观，定位问题成本高

### 5.3 使用场景判断

- ✅ 需要动态、透明地给对象加功能，且功能可以任意组合
- ✅ 不能使用继承（final 类）或继承会导致类爆炸
- ✅ 有多个正交的增强维度（如「缓冲/压缩/加密」×「读/写」）
- ❌ 功能固定不变，直接继承或写进原类更简单

## 六、手写一个实战装饰器：带统计的 HTTP 客户端

```java
// 给 HttpClient 加「调用统计」装饰器（不侵入原实现）
public class StatisticsHttpClientDecorator implements HttpClient {

    private final HttpClient delegate;
    private final AtomicLong requestCount = new AtomicLong();
    private final AtomicLong totalCostMs = new AtomicLong();

    public StatisticsHttpClientDecorator(HttpClient delegate) {
        this.delegate = delegate;
    }

    @Override
    public HttpResponse send(HttpRequest request) {
        long start = System.nanoTime();
        try {
            return delegate.send(request);
        } finally {
            requestCount.incrementAndGet();
            totalCostMs.addAndGet((System.nanoTime() - start) / 1_000_000);
        }
    }

    public String getStats() {
        long count = requestCount.get();
        double avg = count == 0 ? 0 : (double) totalCostMs.get() / count;
        return String.format("请求数=%d, 平均耗时=%.2fms", count, avg);
    }
}
```

加超时重试？再写一个 `RetryHttpClientDecorator`，组合使用即可，**零侵入、可插拔**——这就是装饰器在生产中的价值。

## 七、总结

| 要点 | 结论 |
|------|------|
| 核心思想 | 用组合代替继承，动态叠加职责 |
| 结构关键 | 装饰器持有 Component 引用，转发 + 增强 |
| 最佳教材 | Java IO 流（FilterInputStream 体系） |
| 与代理区别 | 装饰器增强功能、透明多层；代理控制访问、通常单层 |
| 与继承区别 | 装饰器运行期动态组合、避免类爆炸 |
| 框架实例 | MyBatis CachingExecutor、Spring TransactionAwareCacheDecorator |
| 适用场景 | 功能可自由组合、需要透明增强、避免继承膨胀 |

**面试总结话术**：「装饰器模式通过持有抽象构件的引用实现功能叠加，Java IO 的 FilterInputStream 就是教科书实现；它和代理模式最大的区别是目的不同——装饰器是为了增强功能且对客户端透明，代理是为了控制访问；和继承相比，装饰器是运行期动态组合，不会造成类爆炸，完美符合开闭原则。」把结构、源码、对比、实践说全，这道题就稳了。
