---
title: 【设计模式】模板方法模式深度解析：从骨架方法到 Spring、AQS、MyBatis 框架级应用
date: 2026-08-05 08:00:00
tags:
  - Java
  - 设计模式
  - Spring
  - AQS
  - 面试
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】模板方法模式深度解析：从骨架方法到 Spring、AQS、MyBatis 框架级应用

## 面试官：AQS 的源码你看过吗？为什么子类只需要重写 tryAcquire 几个方法就能实现各种锁？

能回答上来的同学，基本都理解了**模板方法模式（Template Method Pattern）**。AQS 是模板方法模式在并发领域最经典的运用：父类把 `acquire()`、`release()` 的骨架流程写死，把 `tryAcquire()`、`tryRelease()` 这些"变化点"留给子类实现。本文从手写模板方法开始，拆解 AQS、Spring、MyBatis 中的框架级应用。

<!-- more -->

## 一、什么是模板方法模式

**定义**：定义一个操作中的算法骨架，将一些步骤延迟到子类中实现。模板方法使得子类可以不改变算法结构的情况下，重新定义算法中的某些步骤。

**核心角色**：

- **AbstractClass（抽象类）**：定义模板方法（骨架）和抽象步骤方法（钩子）
- **ConcreteClass（具体子类）**：实现步骤方法，不改变骨架

**两个关键概念**：

1. **模板方法（Template Method）**：定义流程骨架，通常用 `final` 修饰，禁止子类修改流程
2. **钩子方法（Hook）**：骨架中留给子类覆写的步骤；空实现或默认实现，子类可选择覆写

**经典示例**：做菜流程 = 备菜 → 烹饪 → 装盘，骨架固定，但"烹饪"这一步中餐是炒、西餐是烤。

## 二、手写一个模板方法

以"数据导入"为例：读文件 → 解析 → 校验 → 入库 → 记录日志，其中解析和校验因数据源而异。

```java
// 1. 抽象类：定义骨架
public abstract class DataImporter {

    // 模板方法：流程骨架，final 防止子类篡改流程
    public final void importData(String filePath) {
        System.out.println("【骨架】开始导入：" + filePath);

        String content = readFile(filePath);      // 固定步骤
        List<Record> records = parse(content);    // 变化步骤①（抽象方法）
        validate(records);                        // 变化步骤②（抽象方法）
        save(records);                            // 固定步骤
        log(filePath, records.size());            // 钩子方法：默认记录，可覆写

        System.out.println("【骨架】导入完成");
    }

    // 固定步骤：子类不可覆写
    private String readFile(String filePath) {
        // 读取文件逻辑
        return "file content";
    }

    // 抽象步骤：必须由子类实现
    protected abstract List<Record> parse(String content);

    protected abstract void validate(List<Record> records);

    // 固定步骤
    private void save(List<Record> records) {
        // 入库逻辑
    }

    // 钩子方法：默认实现，子类可选择性覆写
    protected void log(String filePath, int count) {
        System.out.println("导入 " + filePath + "，共 " + count + " 条");
    }
}

// 2. 具体子类：CSV 导入
public class CsvImporter extends DataImporter {
    @Override
    protected List<Record> parse(String content) {
        // CSV 解析逻辑
        return new ArrayList<>();
    }

    @Override
    protected void validate(List<Record> records) {
        // CSV 校验逻辑
    }
}

// 3. 具体子类：Excel 导入
public class ExcelImporter extends DataImporter {
    @Override
    protected List<Record> parse(String content) {
        // Excel 解析逻辑
        return new ArrayList<>();
    }

    @Override
    protected void validate(List<Record> records) {
        // Excel 校验逻辑
    }

    @Override
    protected void log(String filePath, int count) {
        // 覆写钩子：Excel 导入额外上报监控
        super.log(filePath, count);
        System.out.println("上报监控指标");
    }
}
```

**核心价值**：导入流程（读 → 解析 → 校验 → 入库 → 日志）被固化在父类，新增一种数据源只需新建子类实现 `parse` 和 `validate`，**流程代码零重复**。

## 三、框架源码中的模板方法

### 3.1 AQS：并发领域的模板方法巅峰

`AbstractQueuedSynchronizer`（AQS）是 `ReentrantLock`、`Semaphore`、`CountDownLatch` 的共同基类。它的设计哲学就是模板方法模式：

**父类定骨架（模板方法）**：

```java
// 模板方法：获取锁的完整流程（获取失败→入队→阻塞→中断处理）
public final void acquire(int arg) {
    if (!tryAcquire(arg) &&
        acquireQueued(addWaiter(Node.EXCLUSIVE), arg))
        selfInterrupt();
}

// 模板方法：释放锁的完整流程
public final boolean release(int arg) {
    if (tryRelease(arg)) {
        Node h = head;
        if (h != null && h.waitStatus != 0)
            unparkSuccessor(h);   // 唤醒下一个等待线程
        return true;
    }
    return false;
}
```

**子类只实现钩子（变化点）**：

```java
// ReentrantLock 中：非公平锁只重写 tryAcquire
static final class NonfairSync extends Sync {
    protected final boolean tryAcquire(int acquires) {
        // 直接抢锁，不看队列
        final Thread current = Thread.currentThread();
        int c = getState();
        if (c == 0) {
            if (compareAndSetState(0, acquires)) {
                setExclusiveOwnerThread(current);
                return true;
            }
        }
        // ... 重入逻辑
        return false;
    }
}
```

| AQS 钩子方法 | ReentrantLock | Semaphore | CountDownLatch |
|-------------|--------------|-----------|----------------|
| `tryAcquire` | 抢独占锁 | ✖（用 acquireShared） | ✖ |
| `tryRelease` | 释放独占锁 | ✖ | ✖ |
| `tryAcquireShared` | ✖ | 获取信号量许可 | 判断 count 是否为 0 |
| `tryReleaseShared` | ✖ | 归还许可 | count 减一 |

**这就是"骨架复用 + 差异定制"的极致体现**：JDK 团队把最复杂的队列、阻塞、唤醒逻辑写一遍，20 多个并发工具类只需各自实现几个钩子方法。

### 3.2 Spring 中的模板方法

**JdbcTemplate**：把"获取连接 → 创建 Statement → 执行 SQL → 处理结果集 → 释放资源"的骨架固定，使用者只需实现 `RowMapper` 回调：

```java
public <T> List<T> query(String sql, RowMapper<T> rowMapper) {
    // 骨架：连接管理、异常转换、资源释放全部封装
    return execute(new StatementCallback<>() {
        @Override
        public T doInStatement(Statement stmt) throws SQLException {
            ResultSet rs = stmt.executeQuery(sql);
            return mapRow(rs, rowMapper);   // 变化点交给回调
        }
    });
}
```

**RestTemplate**：`execute()` 定义请求执行骨架，`doExecute` 留给子类/回调。还有 `JdbcTemplate`、`JmsTemplate`、`RedisTemplate` 这一整个 Template 家族，都是模板方法模式。

**HttpServlet**：最早的模板方法应用——`service()` 根据请求方法调用 `doGet()`/`doPost()` 等钩子，开发者继承 `HttpServlet` 只需覆写 `doGet`/`doPost`。

### 3.3 MyBatis 中的模板方法

MyBatis 的 `BaseExecutor` 定义了查询执行的骨架：

```java
public abstract class BaseExecutor implements Executor {
    @Override
    public <E> List<E> query(MappedStatement ms, Object parameter, ...) {
        // 骨架：缓存处理 → 核心查询 → 缓存写入
        if (queryStack == 0 && ms.isFlushCacheRequired()) {
            clearLocalCache();
        }
        // ...
        return queryFromDatabase(ms, parameter, rowBounds, resultHandler,
                                 key, boundSql);
    }

    // 抽象步骤：不同 Executor 有不同实现
    protected abstract <E> List<E> doQuery(...);
}
```

- `SimpleExecutor`：每次执行都创建新的 Statement
- `ReuseExecutor`：复用 Statement
- `BatchExecutor`：批量执行

三个子类共用父类的缓存、日志、延迟加载骨架，只差异化"如何执行 SQL"这一步。

## 四、模板方法 vs 策略模式

| 对比项 | 模板方法 | 策略模式 |
|--------|---------|---------|
| 复用粒度 | 复用整个流程骨架 | 复用算法接口 |
| 变化方式 | **继承**：子类覆写步骤 | **组合**：替换策略对象 |
| 关系 | 父子类关系（is-a） | 接口与实现（has-a） |
| 代码耦合 | 子类依赖父类骨架 | 完全解耦 |
| 典型例子 | AQS、JdbcTemplate | Comparator、线程池拒绝策略 |

**经验法则**：能确定整体流程、只有个别步骤会变 → 模板方法；整个算法都可能替换 → 策略模式。Spring 中大量使用"模板方法 + 回调（Callback）"的组合，把继承改为组合，降低了耦合。

## 五、生产实践建议

1. **模板方法用 `final` 修饰**，防止子类意外修改骨架流程
2. **钩子方法给默认实现**，子类按需覆写，避免强制实现用不到的步骤
3. **抽象步骤方法用 `protected`**，只暴露给子类，不对外暴露
4. **警惕继承的脆弱性**：父类骨架改动会影响所有子类，接口变更要谨慎
5. **组合优先于继承**：能用回调/函数式接口（如 `Consumer`）替代抽象方法时，耦合更低

```java
// 函数式版本的"模板"：把变化点参数化为函数
public class DataImporter {
    public void importData(String path,
                           Function<String, List<Record>> parser,
                           Predicate<Record> validator) {
        String content = readFile(path);
        List<Record> records = parser.apply(content);
        records.removeIf(r -> !validator.test(r));
        save(records);
    }
}
```

## 六、面试追问总结

1. **模板方法模式的核心是什么？** → 父类定骨架（final 模板方法），子类实现变化步骤
2. **钩子方法和抽象方法有什么区别？** → 抽象方法必须实现；钩子有默认实现可选择性覆写
3. **AQS 为什么是模板方法模式？** → acquire/release 骨架固定，tryAcquire 等留给子类
4. **模板方法和策略模式怎么选？** → 流程固定选模板方法，算法整体可替换选策略
5. **Spring 里哪些地方用了模板方法？** → JdbcTemplate、RestTemplate、HttpServlet、AQS

## 七、总结

模板方法模式是"**继承复用**"思想的集大成者：把不变的流程上收到父类，把变化点下沉给子类。读 AQS 源码时，只要意识到"我在看模板方法模式的应用"，那些看似复杂的 `acquire` 流程就变得清晰——骨架是固定的，变的只是几个钩子。理解它，你就拿到了阅读 Spring、MyBatis 等框架源码的一把钥匙。
