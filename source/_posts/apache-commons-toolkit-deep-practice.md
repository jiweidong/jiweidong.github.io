---
title: 【Java进阶】Apache Commons 工具库深度实战：从字符串处理到集合、IO、数学与并发
date: 2026-07-25 08:00:00
tags:
  - Java
  - Apache Commons
  - 工具库
  - 开发效率
categories:
  - Java
  - Java进阶
author: 东哥
---

# 【Java进阶】Apache Commons 工具库深度实战：从字符串处理到集合、IO、数学与并发

## 前言

「不要重复造轮子」是软件开发的第一原则。Apache Commons 作为 Java 生态最老牌、最成熟的开源工具库集合，提供了从字符串处理、IO 操作到数学计算、并发增强的 **一整套生产级工具**。

很多开发者只会用 `StringUtils.isEmpty()`，但实际上 Commons 20 多个子项目中充满了「用了就回不去」的神器方法。本文精选 **6 个最常用的 Commons 组件**，通过实战案例让你彻底吃透。

> **注意：** 部分功能已被 Guava 或 Java 新版本（如 `String.join` / `Files.readString`）覆盖，但在生产环境（很多项目仍用 Java 8/11）和遗留系统中，Commons 仍然是不可或缺的存在。

---

## 一、Commons Lang3：Java 标准库的增强版

`commons-lang3` 是最核心的组件，几乎每个 Java 项目都在用。

### 1.1 StringUtils：字符串操作利器

```java
// 空字符串判断
boolean blank = StringUtils.isBlank(str);     // 判断 null/""/" "/null
boolean empty = StringUtils.isEmpty(str);     // 仅 null/""
boolean notBlank = StringUtils.isNotBlank(str);

// 默认值
String safe = StringUtils.defaultIfBlank(str, "default");
String safe2 = StringUtils.defaultString(str, "default");

// 截断与补全
String truncated = StringUtils.abbreviate("Hello World", 8);    // "Hello..."
String padded = StringUtils.leftPad("1", 5, "0");               // "00001"

// 包含判断
boolean containsAny = StringUtils.containsAny("abc", 'a', 'd'); // true
boolean containsIgnoreCase = StringUtils.containsIgnoreCase("Hello", "HELLO");

// 重复与连接
String repeat = StringUtils.repeat("ab", 3);     // "ababab"
String join = StringUtils.join(array, ",");      // 数组拼接

// 提取数字
String digits = StringUtils.getDigits("order-10086");  // "10086"

// 首字母大小写
String cap = StringUtils.capitalize("hello");    // "Hello"
String uncap = StringUtils.uncapitalize("Hello");// "hello"
```

> **对比 JDK 11+：** `String.isBlank()`、`String.join()`、`String.repeat()` 已原生支持。但 `StringUtils.defaultIfBlank()`、`StringUtils.abbreviate()` 仍在 JDK 标准库中没有等价方法。

### 1.2 ObjectUtils：对象操作

```java
// 安全的相等比较
boolean eq = Objects.equals(obj1, obj2);       // JDK 7+ 已提供
boolean eq2 = ObjectUtils.equals(obj1, obj2);   // Lang3 版本

// 取第一个非 null
String first = ObjectUtils.firstNonNull(null, null, "a", "b");  // "a"

// 提供默认值
String val = ObjectUtils.defaultIfNull(obj, "default");

// toString 安全版（null 返回空字符串）
String str = ObjectUtils.toString(obj);  // "" if obj is null

// 比较
int cmp = ObjectUtils.compare(a, b);    // null-safe 比较
```

### 1.3 数字与布尔工具

```java
// NumberUtils
int num = NumberUtils.toInt("123", 0);          // 默认为 0
boolean isDigits = NumberUtils.isDigits("123"); // true
boolean isNumber = NumberUtils.isParsable("12.5"); // true
int min = NumberUtils.min(3, 1, 5, 2);          // 1
long max = NumberUtils.max(3L, 1L, 5L);         // 5L

// 安全的数字创建
Number n = NumberUtils.createNumber("0x1A");   // 26
Number n2 = NumberUtils.createNumber("3.14");   // 3.14 (BigDecimal)

// BooleanUtils
boolean yes = BooleanUtils.toBoolean("yes");    // true
boolean on = BooleanUtils.toBoolean("ON");      // true
BooleanUtils.toString(true, "是", "否");         // "是"
```

### 1.4 构建器模式

```java
// equals 和 hashCode 不再手写
public class User {
    private Long id;
    private String name;
    private Integer age;

    @Override
    public boolean equals(Object obj) {
        return EqualsBuilder.reflectionEquals(this, obj);
    }

    @Override
    public int hashCode() {
        return HashCodeBuilder.reflectionHashCode(this);
    }

    @Override
    public String toString() {
        return ToStringBuilder.reflectionToString(this, ToStringStyle.JSON_STYLE);
    }

    // CompareToBuilder
    @Override
    public int compareTo(User other) {
        return new CompareToBuilder()
                .append(this.age, other.age)
                .append(this.name, other.name)
                .toComparison();
    }
}
```

---

## 二、Commons IO：IO 操作的瑞士军刀

`commons-io` 极大简化了 Java IO 编程——JDK 的 IO 操作代码量通常是 Commons IO 的 3-5 倍。

### 2.1 文件读写

```java
// 读文件（一行搞定）
String content = FileUtils.readFileToString(new File("test.txt"), StandardCharsets.UTF_8);
List<String> lines = FileUtils.readLines(new File("test.txt"), StandardCharsets.UTF_8);
byte[] bytes = FileUtils.readFileToByteArray(new File("test.bin"));

// 写文件
FileUtils.writeStringToFile(new File("out.txt"), "Hello World", StandardCharsets.UTF_8);
FileUtils.writeLines(new File("out.txt"), lines);
FileUtils.writeByteArrayToFile(new File("out.bin"), data);

// 拷贝文件/目录
FileUtils.copyFile(src, dest);
FileUtils.copyDirectory(srcDir, destDir);
FileUtils.copyURLToFile(url, localFile);

// 文件操作
FileUtils.deleteDirectory(dir);            // 递归删除
FileUtils.forceMkdir(dir);                 // 创建目录（含父目录）
FileUtils.cleanDirectory(dir);             // 清空目录（不删目录本身）
FileUtils.sizeOfDirectory(dir);            // 目录总大小

// 临时文件
File temp = FileUtils.getTempDirectory();
```

### 2.2 IO Utils：流操作

```java
// 流拷贝
try (InputStream in = new FileInputStream("in.big");
     OutputStream out = new FileOutputStream("out.big")) {
    IOUtils.copy(in, out);                  // 自动缓冲
    // IOUtils.copyLarge(in, out);          // 大文件专用（返回 byte 数）
}

// 流到字符串
String json = IOUtils.toString(inputStream, StandardCharsets.UTF_8);

// 关闭（null-safe）
IOUtils.closeQuietly(inputStream);          // 不抛异常
IOUtils.close(inputStream, outputStream);   // 多资源一起关

// 读取资源目录中的文件
List<String> lines = IOUtils.readLines(
        getClass().getResourceAsStream("/data.txt"), StandardCharsets.UTF_8);
```

### 2.3 文件监控

```java
// 使用 FileAlterationMonitor 监听文件变化
FileAlterationObserver observer = new FileAlterationObserver("config/");
observer.addListener(new FileAlterationListenerAdaptor() {
    @Override
    public void onFileChange(File file) {
        System.out.println("文件修改了: " + file.getName());
        // 重新加载配置...
    }

    @Override
    public void onFileCreate(File file) {
        System.out.println("新文件: " + file.getName());
    }

    @Override
    public void onFileDelete(File file) {
        System.out.println("文件被删: " + file.getName());
    }
});

FileAlterationMonitor monitor = new FileAlterationMonitor(5000, observer);
monitor.start();  // 每 5 秒扫描一次

// 程序退出时停止
// monitor.stop();
```

> **生产应用：** 用于配置文件热更新、日志文件滚动监控、资源目录监听等场景。

---

## 三、Commons Collections：集合操作的增强版

`commons-collections4` 提供了 JDK `java.util.*` 中没有的集合类型和工具方法。

### 3.1 CollectionUtils

```java
// 判空
boolean empty = CollectionUtils.isEmpty(list);
boolean notEmpty = CollectionUtils.isNotEmpty(list);

// 交集、并集、差集
Collection<Integer> intersection = CollectionUtils.intersection(listA, listB);
Collection<Integer> union = CollectionUtils.union(listA, listB);
Collection<Integer> subtract = CollectionUtils.subtract(listA, listB);  // A - B
Collection<Integer> disjunction = CollectionUtils.disjunction(listA, listB); // 对称差集

// 集合判断
boolean containsAny = CollectionUtils.containsAny(listA, listB);
boolean containsAll = CollectionUtils.containsAll(listA, listB);
boolean isSubCollection = CollectionUtils.isSubCollection(listA, listB);

// 过滤
CollectionUtils.filter(list, obj -> obj instanceof String);  // 原地过滤

// 选取
List<String> selected = ListUtils.select(originList, obj -> obj != null);

// 安全转换
List<String> typed = CollectionUtils.collect(objectList, TransformerUtils.stringValueTransformer());
```

### 3.2 MapUtils

```java
// 安全取值
String val = MapUtils.getString(map, "key", "default");
Integer num = MapUtils.getInteger(map, "count", 0);
Boolean bool = MapUtils.getBoolean(map, "debug", false);

// 取 Map 中的数组/列表
List<String> list = MapUtils.getListValue(map, "tags");

// 调试输出
MapUtils.debugPrint(System.out, "MyMap", map);
```

### 3.3 队列与栈

```java
// 循环队列（大小固定）
CircularFifoQueue<String> fifo = new CircularFifoQueue<>(3);
fifo.add("A"); fifo.add("B"); fifo.add("C");
fifo.add("D");  // A 被移除
System.out.println(fifo);  // [B, C, D]

// 双向映射
BidiMap<String, String> bidi = new TreeBidiMap<>();
bidi.put("key1", "value1");
bidi.put("key2", "value2");
System.out.println(bidi.inverseBidiMap().get("value1")); // key1

// 多值 Map
MultiValuedMap<String, String> multiMap = new ArrayListValuedHashMap<>();
multiMap.put("key", "a");
multiMap.put("key", "b");
multiMap.put("key", "c");
System.out.println(multiMap.get("key"));  // [a, b, c]

// 滞后 Map（缓存版 LazyMap）
Map<String, String> lazy = LazyMap.lazyMap(
        new HashMap<>(), key -> "computed-" + key);
System.out.println(lazy.get("test"));  // computed-test
```

---

## 四、Commons Codec：编解码与加密

`commons-codec` 是很多流行框架（Spring Security、Tomcat）的底层依赖，提供常见的编码和安全算法。

### 4.1 Base64

```java
// 编码
String encoded = Base64.encodeBase64String("Hello".getBytes());
byte[] decoded = Base64.decodeBase64(encoded);

// URL 安全的 Base64（替换 +/ 为 -_）
String urlSafe = Base64.encodeBase64URLSafeString(data);

// 带分行的 BASE64（邮件格式）
byte[] encodedChunked = Base64.encodeBase64Chunked(data);
```

### 4.2 消息摘要

```java
// MD5
String md5Hex = DigestUtils.md5Hex(data);
// SHA-256
String sha256Hex = DigestUtils.sha256Hex(data);
// SHA-512
String sha512Hex = DigestUtils.sha512Hex(data);

// 大文件摘要
try (InputStream in = new FileInputStream("large-file.bin")) {
    String md5 = DigestUtils.md5Hex(in);
    String sha256 = DigestUtils.sha256Hex(in);  // MD5 已消耗流，需要重新打开！
}
```

### 4.3 十六进制与语音编码

```java
// Hex
String hexString = Hex.encodeHexString(bytes);
byte[] decodedHex = Hex.decodeHex(hexString);

// Soundex（按发音编码，英文名相似度）
Soundex soundex = new Soundex();
int diff = soundex.difference("Smith", "Smythe");  // 发音相似度评分
```

---

## 五、Commons Math3：数学与统计工具

`commons-math3` 是 Java 生态中最全面的数学库，覆盖了**统计、线性代数、数值分析、优化、概率分布**等领域。

### 5.1 基础统计

```java
double[] values = {1.2, 3.4, 5.6, 7.8, 9.0};

DescriptiveStatistics stats = new DescriptiveStatistics();
for (double v : values) {
    stats.addValue(v);
}

System.out.println("均值: " + stats.getMean());
System.out.println("标准差: " + stats.getStandardDeviation());
System.out.println("方差: " + stats.getVariance());
System.out.println("中位数: " + stats.getPercentile(50));
System.out.println("四分位距: " + (stats.getPercentile(75) - stats.getPercentile(25)));
System.out.println("最大值: " + stats.getMax());
System.out.println("最小值: " + stats.getMin());
System.out.println("总和: " + stats.getSum());
System.out.println("样本量: " + stats.getN());
```

### 5.2 线性回归

```java
// 简单线性回归 y = a + bx
SimpleRegression regression = new SimpleRegression();
regression.addData(1, 2);
regression.addData(2, 4);
regression.addData(3, 5);
regression.addData(4, 4);
regression.addData(5, 6);

System.out.println("斜率: " + regression.getSlope());
System.out.println("截距: " + regression.getIntercept());
System.out.println("R²: " + regression.getRSquare());
System.out.println("预测 x=6: " + regression.predict(6));
```

### 5.3 概率分布

```java
// 正态分布
NormalDistribution normal = new NormalDistribution(0, 1);  // 标准正态分布
double density = normal.density(1.96);   // 概率密度
double cumulative = normal.cumulativeProbability(1.96);  // 累积概率 ≈ 0.975

// 二项分布
BinomialDistribution binomial = new BinomialDistribution(10, 0.5);
double prob9 = binomial.probability(9);   // 10 次抛硬币 9 次正面的概率
```

### 5.4 矩阵运算

```java
// 创建矩阵
double[][] data = {{1, 2}, {3, 4}};
RealMatrix matrix = MatrixUtils.createRealMatrix(data);

// 转置
RealMatrix transposed = matrix.transpose();

// 求逆
RealMatrix inverse = new LUDecomposition(matrix).getSolver().getInverse();

// 行列式
double det = new LUDecomposition(matrix).getDeterminant();

// 矩阵乘法
RealMatrix product = matrix.multiply(transposed);
```

---

## 六、Commons Pool2：对象池

很多数据库连接池（如 DBCP2）、Redis 连接池都基于 Commons Pool2。

### 6.1 自定义对象池

```java
// 1. 定义对象工厂
public class ConnectionFactory extends BasePooledObjectFactory<Connection> {
    @Override
    public Connection create() throws Exception {
        return DriverManager.getConnection("jdbc:mysql://localhost:3306/db");
    }

    @Override
    public PooledObject<Connection> wrap(Connection conn) {
        return new DefaultPooledObject<>(conn);
    }

    @Override
    public boolean validateObject(PooledObject<Connection> p) {
        try {
            return !p.getObject().isClosed();
        } catch (SQLException e) {
            return false;
        }
    }

    @Override
    public void destroyObject(PooledObject<Connection> p) throws Exception {
        p.getObject().close();
    }
}

// 2. 配置池参数
GenericObjectPoolConfig<Connection> config = new GenericObjectPoolConfig<>();
config.setMaxTotal(10);
config.setMaxIdle(5);
config.setMinIdle(2);
config.setTestOnBorrow(true);
config.setTestWhileIdle(true);

// 3. 创建池
GenericObjectPool<Connection> pool = new GenericObjectPool<>(new ConnectionFactory(), config);

// 4. 使用
try (Connection conn = pool.borrowObject()) {
    conn.createStatement().execute("SELECT 1");
}  // 自动归还到池中
```

---

## 七、面试追问

> **Q：Commons Lang3 的 StringUtils 和 Guava 的 Strings 有什么区别？**
> A：Commons Lang3 历史悠久，API 覆盖更全（如 `abbreviate`、`getDigits`、`defaultIfBlank`），在 Java 8-11 项目中使用更广泛。Guava 的设计更现代，配合流式编程更好。在同一个项目里不建议同时引入，会增加包冲突风险。

> **Q：Commons IO 的 FileUtils 和 JDK 7+ 的 Files 类怎么选？**
> A：JDK 7 引入 `java.nio.file.Files` 后，Commons IO 的优势在削弱。但 `FileUtils.copyDirectory`、`FileUtils.deleteDirectory`、`FileUtils.sizeOfDirectory` 仍然是 `Files` 类没有的直接方法。大项目通常两者都有。

> **Q：Commons Math3 有哪些实际应用场景？**
> A：风控系统的评分卡（统计分布）、推荐系统的协同过滤（矩阵运算）、监控系统的异常检测（统计偏移量）、科学研究的数据分析（回归和分布检验）。

> **Q：Commons Pool2 和 HikariCP 的池有什么区别？**
> A：HikariCP 是专为 JDBC 连接优化的一级池实现，性能极高。Commons Pool2 是通用对象池框架，可以池化任何对象（连接、线程、资源）。HikariCP 底层也使用了类似的对象池思想，但不依赖 Commons Pool2。

> **Q：项目中同时引入 Commons Lang3、Guava、Hutool 会怎样？**
> A：功能大量重叠，包体积膨胀，类冲突风险增加。**建议统一选一个工具库作为主力**。Commons Lang3 是保守选择（大部分项目在用），Guava 更现代（函数式风格强），Hutool 更适合中文社区（中文文档好）。

---

## 总结

Apache Commons 是 Java 生态的基石级工具库，虽然部分功能被 JDK 新版本和 Guava 替代，但其**稳定性、全面性、向后兼容性**至今无法被完全替代。

**各组件使用场景速记：**

| 组件 | 一句话记住 |
|------|-----------|
| Lang3 | 字符串 + 构建器 + 数字工具 |
| IO | 文件/流操作的瑞士军刀 |
| Collections | 缺啥补啥的集合增强 |
| Codec | Base64 + 摘要 + Hex |
| Math3 | 统计 + 矩阵 + 概率 |
| Pool2 | 什么都能池化 |

哪怕你的项目已经用了 Guava 或 Hutool，**Commons Codec、IO 和 Pool2** 仍然是无法被完全取代的存在。了解它们，你的工具库就多了一层底气。
