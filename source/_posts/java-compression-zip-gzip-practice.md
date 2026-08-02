---
title: 【Java实战】Java 压缩与解压深度实战：ZIP、GZIP、Deflater 原理与最佳实践
date: 2026-08-02 08:00:00
tags:
  - Java
  - 压缩
  - 实战
  - 性能
categories:
  - Java
  - Java实战
author: 东哥
---

# 【Java实战】Java 压缩与解压深度实战：ZIP、GZIP、Deflater 原理与最佳实践

## 面试官：HTTP 的 Content-Encoding: gzip 是怎么实现的？ZIP 和 GZIP 有什么区别？压缩会拖慢接口吗？

压缩是 Java 开发中最常用却被最忽视的技术之一：接口响应 gzip、日志压缩归档、Excel/CSV 导出压缩、大数据批量传输……处处都有它的身影。但很多开发者只会 `new GZIPOutputStream(outputStream)` 这一行，遇到"压缩后反而更大""CPU 被打满""大文件内存溢出"就抓瞎了。

本篇文章从 zlib 压缩原理讲起，覆盖 Java 压缩 API 全景、性能调优与生产避坑，一篇搞定。

## 一、压缩原理：Deflate 算法家族

### 1. zlib / Deflate 是什么？

Java 的 `java.util.zip` 包底层封装的是 **zlib 库**，核心压缩算法是 **DEFLATE**（RFC 1951），由两部分组成：

1. **LZ77 算法**：用滑动窗口找重复数据，把重复串替换成"距离 + 长度"对（如 `(back 4096, length 8)`），消除**重复冗余**；
2. **Huffman 编码**：对 LZ77 输出的 token 再做统计编码，高频字符用短码、低频用长码，消除**统计冗余**。

两层合起来就是 Deflate。在此基础上：

- **GZIP**（RFC 1952）= Deflate 数据 + 文件头（magic `1f 8b`、mtime、可选文件名）+ 尾部（CRC32 校验和）。**GZIP 只能压缩单个文件流，没有目录结构**；
- **ZIP**（RFC 1950 容器）= 多个条目（entry）的集合，每个 entry 可独立选择是否压缩、用何种算法，还带**中央目录**（central directory），支持目录结构、加密、分卷；
- **ZLib**（RFC 1950）= Deflate 数据 + 2 字节头 + Adler-32 校验，主要用于流式协议内部（如 PNG、HTTP）。

### 2. 压缩级别 trade-off

压缩级别 0~9（默认 -1 表示 6）：级别越高，压缩率越好，但 **CPU 耗时和内存占用越大**。

| 级别 | 别名 | CPU 开销 | 压缩率 | 适用场景 |
|------|------|---------|--------|---------|
| 0 | NO_COMPRESSION | 极小（仅存储） | 无 | 已压缩数据（图片/视频）、要求极快 |
| 1~3 | BEST_SPEED | 低 | 较低 | 高吞吐日志、实时响应压缩 |
| 6 | 默认 | 中 | 中 | 通用场景 |
| 9 | BEST_COMPRESSION | 高 | 最高 | 离线归档、冷数据 |

实测经验：**级别 6→9 压缩率只提升 3~5%，CPU 时间却增加 2~3 倍**。生产环境默认用 6，除非明确要极致压缩率。

## 二、Java 压缩 API 全景图

```
java.util.zip
├── Deflater / Inflater          — 底层原始 Deflate 流（最灵活，需自己管缓冲区）
├── DeflaterOutputStream / InflaterInputStream
├── GZIPOutputStream / GZIPInputStream        — 单文件流压缩
├── ZipOutputStream / ZipInputStream          — 多文件归档 + 压缩
├── ZipFile / ZipEntry                        — 随机读取 ZIP
├── CRC32 / Adler32 / CheckedOutputStream     — 校验和
└── ZipError / ZipException
```

**选择口诀**：单个数据流 → GZIP；多个文件/目录归档 → ZIP；追求极致性能与精细控制 → 直接用 Deflater。

## 三、核心实战：四种写法

### 1. GZIP：HTTP 响应压缩（最常用）

```java
public static byte[] gzip(byte[] data) throws IOException {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    try (GZIPOutputStream gzip = new GZIPOutputStream(bos)) {
        gzip.write(data);
    }
    return bos.toByteArray();
}

public static byte[] gunzip(byte[] data) throws IOException {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    try (GZIPInputStream gzip = new GZIPInputStream(new ByteArrayInputStream(data))) {
        byte[] buf = new byte[8192];
        int n;
        while ((n = gzip.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
    }
    return bos.toByteArray();
}
```

Spring Boot 里做接口 gzip 有两种方式：

```yaml
# 方式一：容器层（推荐，透明无侵入）
server:
  compression:
    enabled: true
    mime-types: application/json,text/html,application/xml
    min-response-size: 1024  # 小于 1KB 不压缩，避免小响应得不偿失
```

```java
// 方式二：过滤器层，对特定响应手动压缩
@Component
public class GzipResponseFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest req = (HttpServletRequest) request;
        HttpServletResponse resp = (HttpServletResponse) response;
        // 仅当客户端声明支持 gzip 才压缩
        String acceptEncoding = req.getHeader("Accept-Encoding");
        if (acceptEncoding != null && acceptEncoding.contains("gzip")) {
            GzipResponseWrapper wrapper = new GzipResponseWrapper(resp);
            chain.doFilter(req, wrapper);
            wrapper.finish();
        } else {
            chain.doFilter(req, resp);
        }
    }
}
```

> 要点：**判断 Accept-Encoding**，否则给不支持的客户端发 gzip 会乱码；**小响应不要压缩**（gzip 头 + 字典开销可能让 200 字节变成 300 字节）。

### 2. ZIP：多文件归档

```java
public static void zipFiles(List<Path> files, Path zipPath) throws IOException {
    try (ZipOutputStream zos = new ZipOutputStream(
            Files.newOutputStream(zipPath), StandardCharsets.UTF_8)) {
        zos.setLevel(6); // 全局压缩级别
        for (Path file : files) {
            // 每个文件一个 entry，用相对路径保持目录结构
            ZipEntry entry = new ZipEntry(file.getFileName().toString());
            entry.setTime(Files.getLastModifiedTime(file).toMillis());
            zos.putNextEntry(entry);
            Files.copy(file, zos); // 流式拷贝，不整文件读入内存
            zos.closeEntry();
        }
    }
}

// 读取 ZIP 指定条目
public static byte[] readZipEntry(Path zipPath, String entryName) throws IOException {
    try (ZipFile zipFile = new ZipFile(zipPath.toFile(), StandardCharsets.UTF_8)) {
        ZipEntry entry = zipFile.getEntry(entryName);
        if (entry == null) return null;
        try (InputStream in = zipFile.getInputStream(entry)) {
            return in.readAllBytes();
        }
    }
}
```

关键点：

- **`new ZipOutputStream(out, Charset)` 必须指定 UTF-8**，否则中文文件名会出现乱码/GBK 兼容问题；
- `ZipFile` 支持**随机读取**（基于 central directory），比 `ZipInputStream` 顺序扫描快得多——读大 ZIP 中的少量文件时用 `ZipFile`；
- 条目名（entry name）若包含 `../` 会有**路径穿越安全风险**，解压时必须校验。

### 3. 解压时防 Zip Slip 攻击（安全必做）

```java
public static void safeUnzip(Path zipPath, Path destDir) throws IOException {
    try (ZipFile zipFile = new ZipFile(zipPath.toFile())) {
        Enumeration<? extends ZipEntry> entries = zipFile.entries();
        while (entries.hasMoreElements()) {
            ZipEntry entry = entries.nextElement();
            Path outPath = destDir.resolve(entry.getName()).normalize();
            // 关键校验：解析后的路径必须仍在目标目录内！
            if (!outPath.startsWith(destDir)) {
                throw new SecurityException("非法路径: " + entry.getName());
            }
            if (entry.isDirectory()) {
                Files.createDirectories(outPath);
                continue;
            }
            Files.createDirectories(outPath.getParent());
            try (InputStream in = zipFile.getInputStream(entry)) {
                Files.copy(in, outPath, StandardCopyOption.REPLACE_EXISTING);
            }
        }
    }
}
```

**Zip Slip** 是 OWASP 十大常见漏洞之一：恶意 ZIP 里带 `../../etc/cron.d/xxx` 的条目名，解压时逃逸出目标目录写文件。**任何接收用户上传 ZIP 的系统都必须做路径校验**。

### 4. 底层 Deflater：精细控制与性能

```java
public static byte[] deflate(byte[] data, int level) throws IOException {
    Deflater deflater = new Deflater(level, true); // true = nowrap，不带 zlib 头
    deflater.setInput(data);
    deflater.finish();
    ByteArrayOutputStream bos = new ByteArrayOutputStream(data.length / 2);
    byte[] buf = new byte[8192];
    while (!deflater.finished()) {
        int n = deflater.deflate(buf);
        bos.write(buf, 0, n);
    }
    deflater.end(); // 释放 native 内存，必须调用！
    return bos.toByteArray();
}
```

两个容易犯的错：

1. **`deflater.end()` 必须调用**：Deflater 持有 native 内存，不 end 会在高并发下泄漏 native 内存直至崩溃；
2. **Deflater 非线程安全**：每个线程必须独立实例，用 `ThreadLocal` 池化复用（见下文）。

## 四、性能优化与生产实践

### 1. ThreadLocal 池化 Deflater（压缩高吞吐核心）

创建 Deflater 是重量级操作（初始化 zlib 状态），高并发场景必须复用：

```java
public final class CompressUtil {
    private static final int LEVEL = 6;
    private static final ThreadLocal<Deflater> DEFLATER =
            ThreadLocal.withInitial(() -> new Deflater(LEVEL, true));
    private static final ThreadLocal<Inflater> INFLATER =
            ThreadLocal.withInitial(() -> new Inflater(true));

    public static byte[] compress(byte[] data) throws IOException {
        Deflater deflater = DEFLATER.get();
        deflater.reset(); // 复用前必须 reset，清空上次状态
        deflater.setInput(data);
        deflater.finish();
        ByteArrayOutputStream bos = new ByteArrayOutputStream(data.length / 2);
        byte[] buf = new byte[8192];
        while (!deflater.finished()) {
            int n = deflater.deflate(buf);
            bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }

    public static byte[] decompress(byte[] data) throws IOException {
        Inflater inflater = INFLATER.get();
        inflater.reset();
        inflater.setInput(data);
        ByteArrayOutputStream bos = new ByteArrayOutputStream(data.length * 2);
        byte[] buf = new byte[8192];
        while (!inflater.finished()) {
            int n = inflater.inflate(buf);
            if (n == 0) {
                if (inflater.needsDictionary()) throw new IOException("需要字典");
                if (inflater.needsInput()) break;
            }
            bos.write(buf, 0, n);
        }
        return bos.toByteArray();
    }
}
```

`ThreadLocal` 池化后，压缩吞吐可以提升 3~10 倍（省去每次创建/销毁 Deflater 的开销）。

### 2. 大文件必须流式处理，禁止 readAllBytes

压缩 2GB 文件如果 `readAllBytes()` 直接 OOM。正确姿势是流式管道：

```java
// 流式压缩：文件 → GZIP → 输出，全程固定内存
try (InputStream in = Files.newInputStream(src);
     GZIPOutputStream gz = new GZIPOutputStream(Files.newOutputStream(dst))) {
    in.transferTo(gz); // 内部用 8KB 缓冲区流转
}
```

### 3. 压缩效果实测对比

用 100MB 的 JSON 日志文件测试（JDK 17，单线程）：

| 方案 | 压缩后大小 | 压缩耗时 | 内存峰值 |
|------|-----------|---------|---------|
| 不压缩 | 100MB | - | - |
| GZIP level 1 | 12.8MB | 0.9s | 低 |
| GZIP level 6 | 11.2MB | 2.3s | 中 |
| GZIP level 9 | 10.6MB | 6.1s | 高 |
| **文本/JSON 数据压缩率通常在 85~92%**，而图片（JPG/PNG）、视频、已压缩格式（PDF、ZIP 套 ZIP）压缩率趋近 0，白耗 CPU！ | | | |

**重要结论**：对**已压缩格式**（jpg、png、mp4、pdf、zip）再压缩不仅没收益，还浪费 CPU。接口响应压缩前最好按 Content-Type 白名单过滤。

## 五、ZIP vs GZIP vs 其他压缩格式选型

| 维度 | GZIP | ZIP | Zstandard (zstd) | LZ4 |
|------|------|-----|------------------|-----|
| 结构 | 单流 | 多条目容器 | 单流/多帧 | 单流 |
| 压缩率 | 中 | 中 | **高（比 gzip 高 10~20%）** | 低 |
| 压缩速度 | 中 | 中 | 中~快 | **极快** |
| 解压速度 | 快 | 快 | **极快（比 gzip 快 3~5 倍）** | 极快 |
| Java 支持 | JDK 内置 | JDK 内置 | 需引入 zstd-jni | 需引入 lz4-java |
| 场景 | HTTP、日志归档 | 文件分发、打包 | 大数据传输、Kafka 消息压缩 | 实时日志、缓存 |

**选型建议**：

- HTTP 响应、通用归档 → **GZIP/ZIP**（零依赖）；
- Kafka 消息压缩 → Kafka 自带 `compression.type=zstd`（Kafka 3.x 起 zstd 是默认，解压快是关键）；
- 追求极致吞吐（日志采集、实时传输）→ **LZ4**（压缩/解压速度是 gzip 的 5~10 倍，压缩率稍低）；
- 既要高压缩率又要快解压 → **Zstandard**。

## 六、面试官追问环节

**Q1：GZIP 和 ZIP 到底什么区别？**
答：GZIP 是**单个数据流的压缩格式**，无目录结构，适合流式传输（HTTP、文件流）；ZIP 是**归档容器**，可包含多个条目（文件/目录），每个条目独立压缩，带中央目录支持随机访问，适合文件打包分发。可以把 ZIP 想象成"文件夹"，GZIP 想象成"对单个文件/流做压缩"。

**Q2：为什么压缩后的数据反而更大？**
答：两种原因：① **数据本身不可压缩**（已压缩的图片/视频/加密数据），压缩算法找不到冗余，反而加上格式头、校验和、字典等开销；② **小数据**：gzip 头 + CRC + 算法固定开销对几十字节的小响应占比过高。所以压缩前要判断数据类型和数据量（如 `min-response-size: 1024`）。

**Q3：压缩和解压哪个更耗 CPU？**
答：**压缩远贵于解压**（通常 3~10 倍）。所以生产上"压一次、解多次"的场景（CDN 静态资源、消息批量压缩）性价比极高；而高 QPS 接口如果每次响应都现压，要评估 CPU 预算，必要时预压缩或降级。

**Q4：解压 zip 文件时如何防止安全攻击？**
答：三个层面：① **Zip Slip 路径穿越**——entry name normalize 后必须 startsWith 目标目录；② **解压炸弹（Zip Bomb）**——压缩比极高的嵌套 zip（如 42.zip），解压时限制总解压大小、条目数、单文件大小、嵌套深度；③ 超时与资源配额控制。**永远不要无校验地解压用户上传的 ZIP**。

**Q5：Deflater 的 nowrap 参数是什么意思？**
答：`new Deflater(level, nowrap)`，nowrap=true 时**不写 zlib 头（2 字节）和 Adler-32 校验**，输出纯 Deflate 流。与 GZIP 的区别：GZIP 用 CRC32 校验 + 10 字节头；zlib 用 Adler-32 + 2 字节头。注意解压端必须用**相同格式**（Inflater 的 nowrap 要一致），否则数据错乱。

## 七、总结

- **原理**：Deflate = LZ77（去重复）+ Huffman（去统计冗余），GZIP/ZIP/ZLib 是不同封装；
- **选型**：单流用 GZIP，归档用 ZIP，极致性能用 zstd/LZ4；
- **性能**：ThreadLocal 池化 Deflater、流式处理大文件、级别 6 是性价比最优；
- **安全**：解压必防 Zip Slip 与解压炸弹，路径校验是底线；
- **常见坑**：不调 end() 泄漏 native 内存、中文文件名乱码（指定 UTF-8）、对已压缩数据白耗 CPU。

压缩不是"一行 API"那么简单，理解了原理与权衡，你才能在吞吐、压缩率、安全之间做出正确的工程决策。
