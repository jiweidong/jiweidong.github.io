---
title: 【Java 基础】Java 字符编码与 Unicode 深度解析：从编码历史到乱码排查实战
date: 2026-08-24 09:00:00
tags:
  - Java
  - 基础
  - 字符串
  - 面试
categories:
  - Java
author: 东哥
---

# 【Java 基础】Java 字符编码与 Unicode 深度解析：从编码历史到乱码排查实战

## 面试官：为什么 Java 的 char 是 16 位？一个汉字能存进去吗？

这是面试 Java 基础时的高频开场问题。要答好它，必须把「字符集（Charset）」和「编码（Encoding）」这两个概念彻底分开，再顺着编码演进的历史一路捋下来。

**字符集**：给每个字符分配一个唯一的编号（码点 Code Point），比如「中」在 Unicode 中的码点是 `U+4E2D`。
**编码**：把码点转换成字节序列的具体规则，同一个字符集可以有多种编码，例如 Unicode 字符集对应 UTF-8、UTF-16、UTF-32 三种主流编码。

Java 的 `char` 是 16 位（2 字节），本质是一个 **UTF-16 编码单元（Code Unit）**。因为 Java 设计之初（1995 年）Unicode 还只有 65536 个字符，16 位刚好够用。但后来 Unicode 扩展到超过 110 万个字符（emoji、古文字、生僻字等），一个 char 装不下了，于是引入了**代理对（Surrogate Pair）**机制。所以更准确的说法是：**Java 的 char 能表示 BMP 平面内的一个字符，而增补平面内的字符需要两个 char 组合（一个高代理 + 一个低代理）**。

```java
String emoji = "😀"; // U+1F600，增补平面
System.out.println(emoji.length()); // 2 —— 两个 char！
System.out.println(emoji.codePointCount(0, emoji.length())); // 1 —— 一个码点
```

这就是经典面试陷阱：`"😀".length() == 2`。统计字符数要用 `codePointCount`，遍历要按码点遍历。

## 编码演进史：为什么会有乱码

### 第一代：ASCII（1963 年）
只用了 7 个 bit，128 个字符，包含英文字母、数字、控制符。`A` = 65，`a` = 97。

### 第二代：扩展 ASCII 与各国本地化编码
8 个 bit 能表示 256 个字符，高 128 位被各国拿来装自己的文字：

| 编码 | 说明 | 特点 |
| --- | --- | --- |
| ISO-8859-1（Latin-1） | 西欧字符 | 单字节，与 ASCII 兼容 |
| GB2312 / GBK / GB18030 | 简体中文 | 双字节为主，GB18030 兼容 UTF-8 的四字节 |
| Shift_JIS | 日文 | 双字节，与 GBK 有冲突区 |

**乱码的本质**：同一个字节序列，用错误的编码去解码。比如 `中` 在 GBK 中是 `D6 D0`，如果你用 ISO-8859-1 解码，就会变成两个乱码字符 `ÖÐ`。

### 第三代：Unicode 一统天下
Unicode 给全世界每个字符分配唯一码点，彻底消灭「同一码位不同含义」的混乱。但存储时怎么编码？于是有了：

| 编码 | 说明 | 字节数 |
| --- | --- | --- |
| UTF-32 | 每个码点固定 4 字节 | 4 字节/字符，浪费空间 |
| UTF-16 | 每个码点 2 或 4 字节（代理对） | 2~4 字节 |
| UTF-8 | 变长，ASCII 区 1 字节，中文 3 字节 | 1~4 字节 |

**UTF-8 是事实标准**：兼容 ASCII（纯英文文本与 ASCII 完全一致），无字节序问题（BOM 可选），互联网传输最省流量。

## String 底层：JDK 9 的 COMPACT_STRINGS

很多人以为 String 底层是 `char[]`，这在 JDK 8 是对的，但 JDK 9 开始（JEP 254）改成了 `byte[] + coder` 标志：

```java
// JDK 9+ String 内部结构（简化）
private final byte[] value;  // 字节数组
private final byte coder;    // 0 = LATIN1，1 = UTF16
```

- 如果字符串只包含 Latin-1（单字节）字符，用 **LATIN1** 编码存储，每个字符占 1 字节，内存省一半；
- 只要出现一个中文字符，整个字符串切换到 **UTF16** 编码，每个字符占 2 字节；
- 这是为什么 `"abc".getBytes().length == 3` 而 `"中文".getBytes().length` 取决于平台默认字符集（UTF-8 下是 6 字节）。

```java
String s1 = "abc";                 // coder = LATIN1，3 字节
String s2 = "abc中文";             // coder = UTF16，10 字节（5 字符 × 2）
System.out.println(s1.getBytes().length);  // 3
System.out.println(s2.getBytes().length);  // 10（默认 UTF-8 下实际 9 字节）
```

## 编码转换：getBytes 与 new String 的正确姿势

转换口诀：**「编码转字节用 getBytes(指定字符集)，字节转字符串用 new String(字节, 指定字符集)」**——永远显式指定字符集，永远不要依赖平台默认值。

```java
String s = "中文";
// 正确：显式指定
byte[] utf8 = s.getBytes(StandardCharsets.UTF_8);
String back = new String(utf8, StandardCharsets.UTF_8);

// 错误示范：依赖平台默认，换台服务器就乱码
byte[] bytes = s.getBytes();
```

**乱码能不能恢复？** 如果乱码只是「编码/解码不一致」造成的字节无损转换（比如 UTF-8 字节被 GBK 解码），那字节还在，可以逆操作恢复：

```java
// UTF-8 字节被 GBK 解码成乱码字符串 → 反着转回去
String garbled = new String(utf8Bytes, Charset.forName("GBK"));
byte[] recovered = garbled.getBytes(Charset.forName("GBK")); // 拿回原始字节
String origin = new String(recovered, StandardCharsets.UTF_8); // 恢复！
```

但如果中间经过了「?」替换、截断、或再次错误编码，字节已丢失，就**不可逆**了。排查乱码时先判断：是字节还在（可恢复）还是字节已丢（只能找源头）。

## JDK 18 JEP 400：默认字符集终于统一为 UTF-8

历史遗留问题：JDK 一直用「平台默认字符集」，Windows 上默认 GBK，Linux 上默认 UTF-8，导致同一段代码在不同环境行为不一致。JDK 18 起（JEP 400）**默认字符集统一为 UTF-8**，`String.getBytes()`、`new String(byte[])`、`FileReader` 等默认行为全部标准化。这是 Java 消灭乱码的重要一步，也是面试加分点。

## 实战：乱码排查五步法

1. **确认源头编码**：数据从哪来？数据库表字符集（`SHOW CREATE TABLE`）、HTTP 响应头 `Content-Type: text/html; charset=utf-8`、文件头 BOM；
2. **确认目标解码**：当前代码用什么字符集读的？IDE 右下角编码、`file.encoding`、`-Dfile.encoding=UTF-8`；
3. **确认链路每一跳**：浏览器 → Nginx → 应用 → 数据库，任何一跳的编码不一致都会产生乱码；
4. **判断是否可逆**：用十六进制看字节（`xxd`、`HexDump`），若字节仍是原始编码字节则可逆，逐层反向转换；
5. **统一标准**：全链路统一 UTF-8，包括 JVM 参数、连接池 `characterEncoding=utf8`、HTTP 头、文件读写。

```bash
# Linux 下查看文件编码与字节
file -i test.txt          # charset=utf-8
xxd test.txt | head -3    # 看原始字节，判断是否被转码
```

## 面试追问环节

**Q1：`char` 能存下所有 Unicode 字符吗？**
不能。char 是 UTF-16 编码单元，增补平面字符需要两个 char（代理对）。统计字符数用 `String.codePointCount()`。

**Q2：UTF-8 和 UTF-16 怎么选？**
纯英文/网络传输场景选 UTF-8（省空间、兼容 ASCII）；JVM 内存中 String 默认 UTF-16 存储（JDK 9 起有 LATIN1 优化）；需要随机访问字符的场景 UTF-16 更友好。

**Q3：什么是 BOM？**
Byte Order Mark，UTF-16 用来标记字节序的 `FE FF`，UTF-8 的 BOM 是 `EF BB BF`。UTF-8 不需要 BOM，但 Windows 记事本会加，可能导致文件首字符解析异常（如 JSON 解析报错），处理时要 `skipBom` 或去掉。

**Q4：Emoji 为什么是两个 char？**
`😀` 码点 U+1F600 在增补平面（>U+FFFF），UTF-16 用高代理 `D83D` + 低代理 `DE00` 表示，正好两个 char。这也是为什么数据库里存 emoji 必须用 `utf8mb4`（MySQL 的 `utf8` 只支持 3 字节，存不下 4 字节的 emoji）。

## 总结

- 字符集是「编号体系」，编码是「存储规则」，乱码 = 编码/解码不匹配；
- Java `char` 是 UTF-16 编码单元，增补平面字符要代理对；
- JDK 9+ String 用 `byte[] + coder`，LATIN1/UTF16 动态切换；
- 永远显式指定字符集，JDK 18 起默认 UTF-8；
- 乱码先判断字节是否还在，可逆则逐层还原，不可逆则回源头修。

把这一篇吃透，编码类面试题基本通杀，线上乱码排查也不再慌。
