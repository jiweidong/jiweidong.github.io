---
title: 【Spring Boot 实战】文件上传与下载企业级实战：大文件、断点续传与安全控制
date: 2026-07-04 08:00:00
tags:
  - Spring Boot
  - 文件上传
  - 文件下载
  - 企业实战
categories:
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】文件上传与下载企业级实战：大文件、断点续传与安全控制

## 前言

文件上传下载是 Web 开发中最常见的需求之一，但看似简单的"上传文件"背后藏着不少门道：

- 单文件/多文件上传如何实现？
- 大文件上传如何处理内存溢出？
- 文件上传安全性如何保障（类型校验、大小限制、防路径穿越）？
- 如何实现断点续传？
- 如何支持大文件分片上传？

本文将系统梳理 Spring Boot 中文件上传下载的最佳实践，涵盖从基础到企业级的全场景。

---

## 一、Spring Boot 基础文件上传配置

### 1.1 配置参数

```yaml
# application.yml
spring:
  servlet:
    multipart:
      enabled: true
      max-file-size: 50MB         # 单个文件大小上限
      max-request-size: 200MB     # 整个请求大小上限（多文件时重要）
      file-size-threshold: 0      # 文件写入磁盘的阈值（0=直接写入磁盘）
      location: /tmp/uploads       # 临时文件存储路径
```

> **注意**：`max-request-size` 必须 >= `max-file-size`，对于多文件上传，前者应为后者的数倍。

### 1.2 单文件上传

```java
@RestController
@RequestMapping("/api/file")
@Slf4j
public class FileUploadController {

    @Value("${app.upload.dir:./uploads}")
    private String uploadDir;

    @PostMapping("/upload")
    public Result<String> upload(@RequestParam("file") MultipartFile file) {
        if (file.isEmpty()) {
            return Result.error("文件为空");
        }

        // 1. 校验文件类型
        String originalFilename = file.getOriginalFilename();
        String ext = FilenameUtils.getExtension(originalFilename);
        if (!ALLOWED_EXTENSIONS.contains(ext.toLowerCase())) {
            return Result.error("不支持的文件类型: " + ext);
        }

        // 2. 生成唯一文件名（防重名）
        String safeFilename = UUID.randomUUID() + "." + ext;

        // 3. 分区存储（按日期归档，避免单目录文件过多）
        String dateDir = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyy/MM/dd"));
        Path targetPath = Paths.get(uploadDir, dateDir, safeFilename);
        File targetFile = targetPath.toFile();
        targetFile.getParentFile().mkdirs();

        try {
            // 4. 保存文件
            file.transferTo(targetFile);
            log.info("文件上传成功: {} -> {}", originalFilename, targetPath);
            return Result.success("/files/" + dateDir + "/" + safeFilename);
        } catch (IOException e) {
            log.error("文件上传失败", e);
            return Result.error("上传失败: " + e.getMessage());
        }
    }
}
```

### 1.3 多文件上传

```java
@PostMapping("/upload/multi")
public Result<List<String>> uploadMultiple(@RequestParam("files") MultipartFile[] files) {
    List<String> urls = new ArrayList<>();
    for (MultipartFile file : files) {
        if (!file.isEmpty()) {
            // 复用单文件上传逻辑
            Result<String> result = upload(file);
            if (result.isSuccess()) {
                urls.add(result.getData());
            }
        }
    }
    return Result.success(urls);
}
```

---

## 二、文件上传安全防护

### 2.1 文件类型白名单校验

黑名单校验（禁止 exe、bat 等）永远不可靠，因为攻击者可以改后缀。正确做法是：

```java
@Component
public class FileValidationService {

    // 🔴 错误做法：只校验后缀
    public boolean validateByExtension(String filename) {
        return filename.endsWith(".jpg");  // ❌ 可以轻易绕过
    }

    // ✅ 正确做法：校验文件头魔数（Magic Number）
    private static final Map<String, List<String>> MAGIC_NUMBERS = new HashMap<>();

    static {
        MAGIC_NUMBERS.put("image/jpeg", Arrays.asList("FFD8FF"));
        MAGIC_NUMBERS.put("image/png", Arrays.asList("89504E47"));
        MAGIC_NUMBERS.put("image/gif", Arrays.asList("47494638"));
        MAGIC_NUMBERS.put("application/pdf", Arrays.asList("25504446"));
        MAGIC_NUMBERS.put("application/zip", Arrays.asList("504B0304"));
    }

    public boolean validateMagicNumber(byte[] fileBytes, String mimeType) {
        List<String> expectedHeaders = MAGIC_NUMBERS.get(mimeType);
        if (expectedHeaders == null) return false;

        String fileHex = bytesToHex(Arrays.copyOfRange(fileBytes, 0, 4));
        return expectedHeaders.stream().anyMatch(fileHex::startsWith);
    }

    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02X", b));
        }
        return sb.toString();
    }
}
```

### 2.2 路径穿越防护

攻击者可能通过 `../../../etc/passwd` 的文件名来覆盖系统文件：

```java
// ❌ 危险做法
String filename = file.getOriginalFilename();
File target = new File(uploadDir + "/" + filename);  // 存在路径穿越风险

// ✅ 安全做法
String filename = file.getOriginalFilename();
// 1. 清理文件名（去除路径）
String cleanName = FilenameUtils.getName(filename);
// 2. 重新生成唯一文件名
String safeName = UUID.randomUUID() + "." + FilenameUtils.getExtension(cleanName);
// 3. 确保目标路径在设定的目录内
Path targetPath = Paths.get(uploadDir, safeName).normalize();
if (!targetPath.startsWith(Paths.get(uploadDir).normalize())) {
    throw new SecurityException("非法文件路径");
}
```

### 2.3 文件大小与速率限制

```java
@Component
@Aspect
@Slf4j
public class UploadRateLimitAspect {

    private final LoadingCache<String, AtomicLong> uploadCounts = Caffeine.newBuilder()
        .expireAfterWrite(1, TimeUnit.MINUTES)
        .build();

    @Around("@annotation(rateLimit)")
    public Object checkRate(ProceedingJoinPoint pjp, RateLimit rateLimit) throws Throwable {
        // 获取客户端 IP
        HttpServletRequest request = ((ServletRequestAttributes) RequestContextHolder
            .getRequestAttributes()).getRequest();
        String ip = request.getRemoteAddr();

        AtomicLong count = uploadCounts.get(ip, k -> new AtomicLong(0));
        long current = count.incrementAndGet();
        if (current > rateLimit.maxPerMinute()) {
            return Result.error("上传太频繁，请稍后再试");
        }

        return pjp.proceed();
    }
}

@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
@interface RateLimit {
    int maxPerMinute() default 10;
}
```

---

## 三、文件下载实现

### 3.1 常规文件下载

```java
@GetMapping("/download/{dateDir}/{filename}")
public ResponseEntity<Resource> download(@PathVariable String dateDir,
                                          @PathVariable String filename) {
    Path filePath = Paths.get(uploadDir, dateDir, filename).normalize();

    // 安全检查：防止路径穿越
    if (!filePath.startsWith(Paths.get(uploadDir).normalize())) {
        throw new AccessDeniedException("非法路径");
    }

    Resource resource = new UrlResource(filePath.toUri());
    if (!resource.exists()) {
        return ResponseEntity.notFound().build();
    }

    // 设置 Content-Disposition 触发浏览器下载
    String encodedFilename = URLEncoder.encode(filename, StandardCharsets.UTF_8)
        .replace("+", "%20");

    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_OCTET_STREAM)
        .header(HttpHeaders.CONTENT_DISPOSITION,
            "attachment; filename*=UTF-8''" + encodedFilename)
        .body(resource);
}
```

### 3.2 断点续传（Range 请求）

支持 Range 请求头可以让浏览器暂停/恢复下载：

```java
@GetMapping("/download/range/{filename}")
public ResponseEntity<Resource> downloadWithRange(
        @PathVariable String filename,
        @RequestHeader(value = "Range", required = false) String rangeHeader,
        HttpServletRequest request) throws IOException {

    Path filePath = Paths.get(uploadDir, filename).normalize();
    File file = filePath.toFile();
    long fileLength = file.length();

    if (rangeHeader == null) {
        // 没有 Range 头，返回完整文件
        Resource resource = new FileSystemResource(file);
        return ResponseEntity.ok()
            .contentLength(fileLength)
            .contentType(MediaType.APPLICATION_OCTET_STREAM)
            .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=" + filename)
            .body(resource);
    }

    // 解析 Range 头：bytes=start-end
    String[] ranges = rangeHeader.replace("bytes=", "").split("-");
    long start = Long.parseLong(ranges[0]);
    long end = ranges.length > 1 ? Long.parseLong(ranges[1]) : fileLength - 1;

    if (start >= fileLength) {
        return ResponseEntity.status(HttpStatus.REQUESTED_RANGE_NOT_SATISFIABLE).build();
    }

    long contentLength = end - start + 1;
    InputStream inputStream = new FileInputStream(file);
    inputStream.skip(start);

    InputStreamResource resource = new InputStreamResource(inputStream);

    return ResponseEntity.status(HttpStatus.PARTIAL_CONTENT)
        .header(HttpHeaders.CONTENT_RANGE, "bytes " + start + "-" + end + "/" + fileLength)
        .contentLength(contentLength)
        .contentType(MediaType.valueOf(
            URLConnection.guessContentTypeFromName(filename) != null ?
            URLConnection.guessContentTypeFromName(filename) : "application/octet-stream"))
        .body(resource);
}
```

---

## 四、大文件分片上传

### 4.1 架构设计

```
前端：
┌─────────────────┐     1. 文件切片           ┌──────────────┐
│  计算文件 MD5   │ ──────────────────────────►  │  分片上传     │
│  SparkMD5 计算  │                              │  /upload/slice │
└─────────────────┘                              └──────┬───────┘
                                                         │
┌─────────────────┐     4. 合并通知           ┌──────────▼────┐
│  检查已上传分片  │ ◄───────────────────────── │  合并文件     │
│  /upload/check  │                              │  /upload/merge│
└─────────────────┘                              └───────────────┘
```

### 4.2 后端核心代码

```java
@RestController
@RequestMapping("/api/file/slice")
@Slf4j
public class SliceUploadController {

    @Value("${app.upload.slice-dir:./slice-uploads}")
    private String sliceDir;

    /**
     * 上传单个分片
     */
    @PostMapping("/upload")
    public Result<String> uploadSlice(
            @RequestParam("file") MultipartFile file,
            @RequestParam("identifier") String identifier,  // 文件 MD5
            @RequestParam("chunkNumber") int chunkNumber,
            @RequestParam("totalChunks") int totalChunks) {

        // 分片存储路径
        String chunkDir = sliceDir + "/" + identifier;
        File dir = new File(chunkDir);
        if (!dir.exists()) dir.mkdirs();

        Path chunkPath = Paths.get(chunkDir, String.valueOf(chunkNumber));
        try {
            file.transferTo(chunkPath.toFile());
            log.info("分片上传成功: {} chunk {}/{}", identifier, chunkNumber, totalChunks);
            return Result.success("分片上传成功");
        } catch (IOException e) {
            log.error("分片上传失败: {}", e.getMessage());
            return Result.error("分片上传失败");
        }
    }

    /**
     * 检查已上传的分片（用于断点续传）
     */
    @GetMapping("/check")
    public Result<SliceCheckVO> checkUploaded(@RequestParam("identifier") String identifier,
                                               @RequestParam("totalChunks") int totalChunks) {
        SliceCheckVO vo = new SliceCheckVO();
        File chunkDir = new File(sliceDir + "/" + identifier);

        if (chunkDir.exists()) {
            List<Integer> uploaded = Arrays.stream(chunkDir.list())
                .map(Integer::parseInt)
                .sorted()
                .collect(Collectors.toList());
            vo.setUploadedChunks(uploaded);
            vo.setUploaded(uploaded.size() == totalChunks);
        } else {
            vo.setUploadedChunks(Collections.emptyList());
            vo.setUploaded(false);
        }
        return Result.success(vo);
    }

    /**
     * 合并分片
     */
    @PostMapping("/merge")
    public Result<String> merge(@RequestParam("identifier") String identifier,
                                 @RequestParam("filename") String filename) throws IOException {

        File chunkDir = new File(sliceDir + "/" + identifier);
        File[] chunks = chunkDir.listFiles();
        if (chunks == null || chunks.length == 0) {
            return Result.error("未找到分片文件");
        }

        // 排序分片
        Arrays.sort(chunks, Comparator.comparingInt(f -> Integer.parseInt(f.getName())));

        // 合并文件
        String dateDir = LocalDate.now().format(DateTimeFormatter.ofPattern("yyyy/MM/dd"));
        File outputDir = new File(uploadDir, dateDir);
        outputDir.mkdirs();

        String safeName = UUID.randomUUID() + "_" + filename;
        File mergedFile = new File(outputDir, safeName);

        try (FileOutputStream fos = new FileOutputStream(mergedFile)) {
            for (File chunk : chunks) {
                Files.copy(chunk.toPath(), fos);
            }
        }

        // 清理分片目录
        FileUtils.deleteDirectory(chunkDir);

        log.info("文件合并完成: {} -> {}", filename, mergedFile.getAbsolutePath());
        return Result.success("/files/" + dateDir + "/" + safeName);
    }
}
```

---

## 五、文件上传下载最佳实践清单

| 关注点 | 最佳实践 |
|--------|---------|
| 文件存储 | 不要存 DB，存对象存储（OSS/S3/MinIO）或分布式文件系统 |
| 文件命名 | 不使用原始文件名，用 UUID + 扩展名 |
| 目录结构 | 按日期/Y/M/D 归档，避免单目录文件过多 |
| 类型校验 | 文件头魔数校验 + 扩展名白名单 |
| 大小限制 | Spring 配置 max-file-size + Nginx 层限制 |
| 限流 | 用户级别上传速率限制，防止滥用 |
| 临时文件清理 | 使用 `@PreDestroy` 或定时任务清理超时未合并的分片 |
| 访问控制 | 鉴权后才可下载，可签发临时 URL（OSS 风格） |
| 日志审计 | 记录上传人、时间、文件名、大小等 |
| 病毒扫描 | 上传文件进行 ClamAV / VirusTotal 扫描 |

---

## 六、总结

文件上传下载看似简单，但要在生产环境中做到健壮、安全、高性能，需要对各个环节有系统性的考虑。本文从基础配置出发，逐步深入到安全防护、断点续传、大文件分片上传等企业级场景。

核心要点：
1. **安全性第一**：文件类型校验 + 路径穿越防护 + 大小限制 + 限流
2. **大文件用分片**：支持断点续传，避免单个大文件占用过多内存
3. **推荐使用 OSS**：自建文件服务复杂度高，生产环境建议直接用阿里云 OSS / AWS S3 / MinIO
4. **做好日志和监控**：文件操作是高危操作，必须可审计、可追溯
