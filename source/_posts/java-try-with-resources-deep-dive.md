---
title: 【Java核心】try-with-resources 原理与资源关闭机制深度解析
date: 2026-07-03 08:01:00
tags:
  - Java
  - 异常处理
  - 基本功
categories:
  - Java
  - Java基础
author: 东哥
---

# 【Java核心】try-with-resources 原理与资源关闭机制深度解析

## 从一段"优雅"的旧代码说起

先看一段代码，猜猜有什么问题：

```java
// 老式 try-finally 资源关闭
public static String readFile(String path) throws IOException {
    BufferedReader br = null;
    try {
        br = new BufferedReader(new FileReader(path));
        return br.readLine();
    } finally {
        if (br != null) {
            br.close(); // 问题就出在这
        }
    }
}
```

看起来没毛病？如果在 `br.readLine()` 抛出异常 A，然后 `br.close()` 又抛出异常 B，会发生什么？

答案是：**异常 A 被吞掉了，只抛出异常 B。** 这种"异常屏蔽"问题在 try-finally 模式中非常隐蔽且致命。

## try-with-resources 的诞生

Java 7 引入了 try-with-resources 语法糖，完美解决了这个问题：

```java
// Java 7+ 写法
public static String readFile(String path) throws IOException {
    try (BufferedReader br = new BufferedReader(new FileReader(path))) {
        return br.readLine();
    }
}
```

不仅代码量减少 50%，而且异常处理更正确——如果有多个异常发生，**close 异常会被"压制"（suppressed）在主异常上**，而不是覆盖主异常。

## 编译原理：语法糖的真相

try-with-resources 是编译器提供的语法糖，我们来揭开它的真面目。

### 一条 close 时的反编译

```java
// 写源码
try (BufferedReader br = new BufferedReader(new FileReader(path))) {
    return br.readLine();
}
```

**编译器处理后（简化反编译）：**

```java
BufferedReader br = new BufferedReader(new FileReader(path));
Throwable primaryEx = null;
try {
    return br.readLine();
} catch (Throwable t) {
    primaryEx = t;
    throw t;
} finally {
    if (br != null) {
        if (primaryEx != null) {
            try {
                br.close();
            } catch (Throwable suppressed) {
                primaryEx.addSuppressed(suppressed); // 压抑制异常
            }
        } else {
            br.close();
        }
    }
}
```

核心逻辑：
1. 捕获 try 块中的原始异常作为 primaryEx
2. 在 finally 中调用 close，如果 close 也抛出异常，通过 `addSuppressed()` 将其添加为压制异常
3. 最终抛出 primaryEx，压制异常可以通过 `getSuppressed()` 获取

### 多条资源时的编译

```java
// 源码
try (Connection conn = getConnection();
     PreparedStatement ps = conn.prepareStatement(sql);
     ResultSet rs = ps.executeQuery()) {
    // 使用资源
}
```

编译器会生成嵌套的 try-finally 块，**关闭顺序与创建顺序相反**（后创建的先关闭），且所有关闭异常都不会覆盖原始异常。

## AutoCloseable 与 Closeable 接口

### 接口定义

```java
// JDK 7 引入 - 所有可关闭资源的父接口
public interface AutoCloseable {
    void close() throws Exception;
}

// JDK 5 已有 - I/O 资源的关闭接口
public interface Closeable extends AutoCloseable {
    @Override
    public void close() throws IOException; // 缩小了异常类型
}
```

区别：
- `AutoCloseable.close()` 声明抛出 `Exception`
- `Closeable.close()` 声明抛出 `IOException`（更具体）
- 一般实现 `Closeable` 即可，仅当资源是 IO 外的场景时实现 `AutoCloseable`

### 哪些类实现了 AutoCloseable？

几乎所有需要关闭的资源都实现了它：

| 类别 | 类名 | 说明 |
|------|------|------|
| IO 流 | InputStream, OutputStream, Reader, Writer | 数据读写 |
| 网络 | Socket, ServerSocket, HttpURLConnection | 网络连接 |
| JDBC | Connection, Statement, PreparedStatement, ResultSet | 数据库连接 |
| NIO | Channel, Selector, FileChannel | NIO 通道 |
| 锁 | Lock（需手动实现） | 非 `AutoCloseable`，但可以这么用 |
| 自定义 | 实现 AutoCloseable 即可 | 任何需要释放的资源 |

## 自定义资源类

```java
public class DatabaseResource implements AutoCloseable {
    private final String name;
    private boolean closed = false;
    
    public DatabaseResource(String name) {
        this.name = name;
        System.out.println("打开资源: " + name);
    }
    
    public void query(String sql) {
        if (closed) throw new IllegalStateException("资源已关闭");
        System.out.println("执行查询: " + sql + " on " + name);
        if (sql.contains("error")) {
            throw new RuntimeException("查询失败: " + sql);
        }
    }
    
    @Override
    public void close() {
        if (!closed) {
            closed = true;
            System.out.println("关闭资源: " + name);
            // 模拟关闭异常
            throw new RuntimeException("关闭异常: " + name);
        }
    }
}
```

使用：

```java
public static void main(String[] args) {
    try (DatabaseResource db1 = new DatabaseResource("DB_主库");
         DatabaseResource db2 = new DatabaseResource("DB_从库")) {
        db1.query("SELECT * FROM users");
        db2.query("SELECT error FROM broken"); // 这里抛异常
    } catch (Exception e) {
        System.out.println("主异常: " + e.getMessage());
        Throwable[] suppressed = e.getSuppressed();
        for (Throwable s : suppressed) {
            System.out.println("压制异常: " + s.getMessage());
        }
    }
}
```

输出：

```
打开资源: DB_主库
打开资源: DB_从库
执行查询: SELECT * FROM users on DB_主库
执行查询: SELECT error FROM broken on DB_从库
关闭资源: DB_从库
关闭资源: DB_主库
主异常: 查询失败: SELECT error FROM broken
压制异常: 关闭异常: DB_从库
压制异常: 关闭异常: DB_主库
```

注意关闭顺序：**从库先关，主库后关**（与创建顺序相反）。所有关闭异常都被压制，主异常完整保留。

## 从源码看异常压制机制

### Throwable.addSuppressed()

```java
// Throwable.java - JDK 7+
public final synchronized void addSuppressed(Throwable exception) {
    if (exception == this)
        throw new IllegalArgumentException("Self-suppression not permitted");
    if (exception == null)
        throw new NullPointerException("exception == null");
    
    if (suppressedExceptions == null) // SUPPRESSED_SENTINEL 表示已禁止添加
        return;
    if (suppressedExceptions == SUPPRESSED_SENTINEL) {
        suppressedExceptions = new ArrayList<>();
    }
    suppressedExceptions.add(exception);
}

public final synchronized Throwable[] getSuppressed() {
    if (suppressedExceptions == SUPPRESSED_SENTINEL ||
        suppressedExceptions == null)
        return EMPTY_THROWABLE_ARRAY;
    return suppressedExceptions.toArray(new Throwable[0]);
}
```

### 为什么有时候 getSuppressed() 是空的？

如果 try 块没有抛出异常，只是 close 抛出异常，那么这个 close 异常就是主异常，没有压制异常。

```java
try (Resource r = new Resource()) {
    // 正常执行，无异常
    // close 时抛出异常
}
// catch 块捕获的就是 close 异常本身
```

## 经典陷阱与最佳实践

### 陷阱 1：在 finally 中"多此一举"关闭资源

```java
// ❌ 错误 - 双重关闭！
try (BufferedReader br = new BufferedReader(...)) {
    return br.readLine();
} finally {
    if (br != null) br.close(); // br 已经被 try-with-resources 自动关了
}
```

会怎样？close 被调用两次！如果 `BufferedReader` 的 `close()` 不是幂等的，第二次 close 可能抛出异常。

### 陷阱 2：在 try-with-resources 外声明变量

```java
// ❌ 编译错误 - 变量必须在 try 的括号内声明
BufferedReader br = new BufferedReader(...);
try (br) {
    return br.readLine(); // ❌ Java 9 之前不行
}

// ✅ Java 9+ 可以 - effectively final 变量
BufferedReader br = new BufferedReader(...);
try (br) { // Java 9 引入的增强
    return br.readLine();
}
```

### 陷阱 3：在 try-with-resources 中"透传"资源

```java
// ❌ 危险 - 如果把流传到方法外，try-with-resources 会关闭它
public static byte[] readBytes(String path) throws IOException {
    FileInputStream fis = new FileInputStream(path);
    try (fis) {
        byte[] data = readAllBytes(fis);
        return data; // ✅ 可以，返回的是 byte[]，不是流
    }
}

// ❌ 但如果返回的是流本身，外面就读到了已关闭的流
public static InputStream openStream(String path) throws IOException {
    FileInputStream fis = new FileInputStream(path);
    try (fis) {
        return fis; // ❌ 返回后立即关闭，外面拿到的流已被关闭！
    }
}
```

### 陷阱 4：自定义 close 异常被压制但没处理

```java
// 如果 close 抛出的异常很重要（如提交事务失败），不能让它悄悄被压制
public class TransactionResource implements AutoCloseable {
    private boolean rollbackOnly = false;
    
    public void commit() { /* 提交事务 */ }
    public void rollback() { rollbackOnly = true; }
    
    @Override
    public void close() {
        if (rollbackOnly) {
            rollback();
        } else {
            commit(); // 如果这里抛异常，被压制后就丢了
        }
    }
}
```

### 最佳实践 1：结合 try-catch 处理

```java
// 分开捕获资源关闭异常和执行异常
try (FileInputStream fis = new FileInputStream("data.bin")) {
    process(fis);
} catch (IOException e) {
    // 这里捕获到的异常可能是 process 异常 + close 压制异常
    logger.error("处理失败", e);
    if (e.getSuppressed().length > 0) {
        logger.warn("资源关闭时也发生了异常", e.getSuppressed()[0]);
    }
}
```

### 最佳实践 2：使用 Objects.requireNonNull 避免空资源

```java
// 传入 null 资源时 try-with-resources 会立即抛 NPE
try (InputStream is = getStreamOrNull()) { // 如果返回 null
    // ⚠️ NullPointerException - 因为 close() 调用在 null 上
}
```

### 最佳实践 3：为锁使用 try-with-resources

```java
// 用 try-with-resources 安全释放锁
public class LockResource implements AutoCloseable {
    private final Lock lock;
    
    public LockResource(Lock lock) {
        this.lock = lock;
        this.lock.lock();
    }
    
    @Override
    public void close() {
        this.lock.unlock();
    }
}

// 使用
Lock lock = new ReentrantLock();
try (LockResource ignored = new LockResource(lock)) {
    // 临界区代码
    // 无论是否异常，锁都会释放
}
```

## 面试常见追问

### Q1：try-with-resources 能否捕获异常？

可以。try-with-resources 可以配合 catch 和 finally 使用：

```java
try (BufferedReader br = new BufferedReader(...)) {
    // 使用
} catch (IOException e) {
    // 处理异常
} finally {
    // 额外的清理逻辑
}
```

### Q2：如果多个资源都抛出异常，异常如何处理？

规则：**保留第一个异常，后续异常（包括 close 异常）全部压制。**

```
try {
    res1.use();  ← 抛出异常 A（主异常）
} finally {
    res2.close(); ← 抛出异常 B（压制到 A）
    res1.close(); ← 抛出异常 C（压制到 A）
}
结果：抛出 A，B 和 C 通过 addSuppressed 附加
```

### Q3：try-with-resources 一定比 try-finally 好吗？

**绝大部分场景是的**，因为：
1. 代码更简洁
2. 异常压制机制更正确
3. 不会遗漏 close

但少数场景下可能需要 try-finally：
- 需要在多个 finally 步骤间做特殊处理
- 资源本身不是 `AutoCloseable`
- 需要手动控制关闭时机

### Q4：有没有 try-with-resources 解决不了的场景？

有。比如 **分阶段提交** 的资源：

```java
// 事务管理器需要两阶段提交
ResourceManager.begin();
try (Resource r = getResource()) {
    r.use();
} // 自动 close 但可能只是想 release，不想 rollback
```

这种场景不适合 try-with-resources，需要手动管理生命周期。

## 总结

| 特性 | try-finally | try-with-resources |
|------|-------------|-------------------|
| 语法简洁度 | 差，模板代码多 | 优秀，一行声明 |
| 异常屏蔽 | 会屏蔽主异常 | 压制而非屏蔽 |
| 关闭遗漏风险 | 高，易忘记 | 零 |
| 多资源管理 | 嵌套地狱 | 并列声明 |
| 适用版本 | JDK 7 前 | JDK 7+ |
| 自定义资源 | 无限制 | 需实现 AutoCloseable |

try-with-resources 是 Java 7 引入的最实用的语法糖之一。它解决了 I/O 操作中长期存在的资源泄漏和异常屏蔽问题，是每个 Java 开发者必须掌握的基础技能。
