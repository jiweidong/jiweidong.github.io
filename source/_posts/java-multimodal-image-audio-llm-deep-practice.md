---
title: 【Java AI】多模态落地深度实战：图片理解、语音转写与 TTS 的 Java 工程化实现
date: 2026-10-28 09:30:00
tags:
  - Java
  - AI
  - 多模态
  - Spring AI
  - 语音
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】多模态落地深度实战：图片理解、语音转写与 TTS 的 Java 工程化实现

## 前言

过去两年，Java 团队接 AI 需求基本是「文本进、文本出」：客服问答、文档摘要、SQL 生成。但真实业务里，用户扔过来的往往是**一张发票照片、一段 30 秒的语音、一份扫描版 PDF**。

这就是多模态（Multimodal）要解决的问题：让模型同时理解文本、图像、音频。对 Java 后端来说，挑战不在「调 API」，而在：

- 图片怎么传？base64 还是 URL？体积和延迟差多少？
- 语音文件格式不对怎么办？ASR 的时长/大小限制怎么绕？
- 一次请求要处理 20 张图，怎么并发？虚拟线程值不值得上？
- Token 成本怎么估？一张图到底算多少 token？
- 流式语音怎么和现有的 SSE/WebSocket 架构拼起来？

这篇文章用 Spring AI 为主体（辅以 LangChain4j 和原生 HTTP），把三类模态的**工程落地**讲透。所有代码都是可以直接改吧改吧上生产的骨架。

## 一、多模态能力地图

先明确「多模态」在工程上到底包含哪些能力，别被概念绕晕：

| 能力 | 输入 | 输出 | 典型模型 | 典型场景 |
|---|---|---|---|---|
| 图像理解（VLM） | 图片 + 文本 | 文本 | GPT-4o、Qwen-VL、Claude、Gemini | 票据识别、质检、看图问答 |
| OCR | 图片/PDF | 文本 + 坐标 | PaddleOCR、云厂商 OCR | 发票、合同、身份证 |
| 语音转写（ASR） | 音频 | 文本 + 时间戳 | Whisper、Paraformer | 会议纪要、客服录音 |
| 语音合成（TTS） | 文本 | 音频 | TTS-1、CosyVoice | 播报、有声内容 |
| 视频理解 | 视频/帧序列 | 文本 | Gemini、Qwen-VL-Max | 内容审核、监控分析 |
| 图像生成 | 文本 | 图片 | DALL·E、SD、通义万相 | 营销素材 |

对 Java 后端，**优先级排序**通常是：图像理解 > OCR > ASR > TTS > 视频。因为前三个直接对应「把非结构化数据变成可检索文本」，是 RAG 和企业知识库的入口。

视频理解本质是「抽帧 + 图片理解」，成本高、延迟大，一般放异步任务。

## 二、图像理解：三种传图方式与它们的代价

### 2.1 Spring AI 的统一抽象

Spring AI 把所有模态统一成 `Media`，挂在 `UserMessage` 上：

```java
// 依赖：spring-ai-openai-spring-boot-starter（或对应厂商 starter）
@Autowired
private ChatClient chatClient;

public String describe(byte[] imageBytes, String mimeType, String question) {
    Media media = new Media(MimeTypeUtils.parseMimeType(mimeType),
                            new ByteArrayResource(imageBytes));

    return chatClient.prompt()
            .user(u -> u.text(question).media(media))
            .call()
            .content();
}
```

多图也简单——`media()` 可以调多次：

```java
public String compare(List<byte[]> images, String question) {
    return chatClient.prompt()
            .user(u -> {
                u.text(question);
                images.forEach(bytes -> u.media(
                        MimeTypeUtils.IMAGE_JPEG, new ByteArrayResource(bytes)));
            })
            .call()
            .content();
}
```

### 2.2 base64 vs URL：别小看这 33%

图片有两种传法：

**方式一：base64 内联**

```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "这张发票的金额是多少？"},
    {"type": "image_url",
     "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQSkZJRg..."}}
  ]
}
```

**方式二：公网 URL**

```json
{"type": "image_url", "image_url": {"url": "https://cdn.example.com/inv/123.jpg"}}
```

对比：

| 维度 | base64 | URL |
|---|---|---|
| 请求体积 | 原图 × 1.33 + JSON 开销 | 几十字节 |
| 是否需要公网可访问 | 否 | 是（模型厂商要能拉取） |
| 内网/私有化部署 | 友好 | 需要对象存储暴露 |
| 首字节延迟 | 高（大 body 上传慢） | 低（厂商 CDN 拉取） |
| 安全 | 图片不出你的网关 | 图片 URL 可能被第三方访问 |
| 适用 | 小图（<500KB）、内网、私有化 | 大图、高并发、已有 CDN |

**实测经验：一张 2MB 的发票照片，base64 后请求体约 2.7MB。** 走公网 API 时，上传耗时可能比模型推理还长。高并发场景下这是灾难——你的出口带宽会先被打满。

所以生产建议：

1. 客户端**直传对象存储**（OSS/S3/MinIO），拿到 URL；
2. 后端只把 URL 传给模型；
3. 如果模型厂商要求可访问，用**预签名 URL**（有效期 5~10 分钟），避免长期暴露；
4. 私有化部署（vLLM + Qwen-VL）时用 base64，避免内网穿透问题。

### 2.3 图片预处理：不处理会吃大亏

模型对图片有尺寸上限（常见 2048×2048 或 1568px 长边），超了会被缩放。但**缩放前先压缩**能省大量 token 和带宽：

```java
public byte[] preprocess(byte[] original, int maxEdge, float quality) throws IOException {
    BufferedImage src = ImageIO.read(new ByteArrayInputStream(original));
    if (src == null) {
        throw new IllegalArgumentException("不支持的图片格式");
    }

    // 1. 处理 EXIF 旋转（手机拍照必备）
    src = applyExifOrientation(src, original);

    // 2. 等比缩放到 maxEdge
    int w = src.getWidth(), h = src.getHeight();
    double scale = Math.min(1.0, (double) maxEdge / Math.max(w, h));
    int nw = (int) (w * scale), nh = (int) (h * scale);

    BufferedImage dst = new BufferedImage(nw, nh,
            src.getColorModel().hasAlpha() ? BufferedImage.TYPE_INT_ARGB
                                           : BufferedImage.TYPE_INT_RGB);
    Graphics2D g = dst.createGraphics();
    g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                       RenderingHints.VALUE_INTERPOLATION_BILINEAR);
    g.drawImage(src, 0, 0, nw, nh, null);
    g.dispose();

    // 3. 重新编码为 JPEG（quality 0.85 通常肉眼无损）
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    ImageWriter writer = ImageIO.getImageWritersByFormatName("jpg").next();
    ImageWriteParam param = writer.getDefaultWriteParam();
    param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
    param.setCompressionQuality(quality);
    try (ImageOutputStream ios = ImageIO.createImageOutputStream(out)) {
        writer.setOutput(ios);
        writer.write(null, new IIOImage(dst, null, null), param);
    } finally {
        writer.dispose();
    }
    return out.toByteArray();
}
```

**EXIF 旋转是必踩的坑。** 手机拍的照片经常带 `Orientation=6`（顺时针转 90°），`ImageIO.read` 不会自动应用，结果模型看到一张躺着的发票，识别率暴跌。要么用 `metadata-extractor` 读 EXIF 手动旋转，要么统一让前端用 canvas 纠正后再上传。

### 2.4 图片 token 怎么算

以 OpenAI 系为例（其他厂商逻辑类似）：

- **low detail**：固定 85 token，不管图多大；
- **high detail**：先缩放到 2048 内，再按 512×512 切块，每块 170 token，加基础 85。

```java
public int estimateImageTokens(int width, int height, boolean highDetail) {
    if (!highDetail) return 85;
    // 缩放到 2048 以内
    double scale = Math.min(1.0, 2048.0 / Math.max(width, height));
    int w = (int) (width * scale), h = (int) (height * scale);
    // 缩放到 768 短边（保持比例）
    scale = Math.min(1.0, 768.0 / Math.min(w, h));
    w = (int) Math.ceil(w * scale);
    h = (int) Math.ceil(h * scale);
    int tiles = (int) Math.ceil(w / 512.0) * (int) Math.ceil(h / 512.0);
    return 85 + 170 * tiles;
}
```

一张 1920×1080 的截图，high detail 大约 **85 + 170×6 = 1105 token**。如果一天 10 万张图，光图片输入就是 1.1 亿 token——按 $2.5/M 算，每天 275 美元。

**成本优化三招：**

1. 能用 low detail 就用（比如「这张图里有没有人」这种二分类）；
2. 预处理时把长边压到 1024，块数直接减半；
3. 加缓存：同一张图的 hash → 结果，命中率在票据/商品图场景能到 40%+。

## 三、语音转写：文件格式是第一道坎

### 3.1 Spring AI 的 TranscriptionModel

```java
@Autowired
private TranscriptionModel transcriptionModel;   // 早期版本叫 AudioTranscriptionModel

public String transcribe(byte[] audio, String filename) {
    Resource resource = new ByteArrayResource(audio) {
        @Override
        public String getFilename() {
            return filename;   // 必须给文件名，模型靠扩展名判断格式
        }
    };
    TranscriptionResponse response = transcriptionModel.transcribe(resource);
    return response.getText();
}
```

**`getFilename()` 必须重写。** 很多 `ByteArrayResource` 默认 filename 是 null，OpenAI SDK 会因此报 400。这个坑我见过至少三次。

带时间戳（用于会议纪要、字幕）：

```java
TranscriptionOptions options = TranscriptionOptions.builder()
        .responseFormat(TranscriptionResponseFormat.VERBOSE_JSON)
        .timestampGranularity(List.of(TimestampGranularity.WORD))
        .language("zh")
        .build();

TranscriptionResponse resp = transcriptionModel.transcribe(resource, options);
resp.getSegments().forEach(s ->
        log.info("[{}-{}] {}", s.getStart(), s.getEnd(), s.getText()));
```

### 3.2 格式与限制

| 维度 | 常见限制 | 应对 |
|---|---|---|
| 文件大小 | 25MB（OpenAI） | 切分或压缩码率 |
| 时长 | 数分钟~1 小时 | 按静音切段 |
| 格式 | mp3/mp4/mpeg/mpga/m4a/wav/webm | 统一转 16kHz 单声道 wav |
| 采样率 | 建议 16kHz | `ffmpeg -ar 16000 -ac 1` |

**为什么统一转 16kHz 单声道？** 因为 ASR 模型内部就是这么处理的，你传 48kHz 立体声只是让上传变慢 3 倍，识别质量一点不提升。

用 ffmpeg 在 Java 里转：

```java
public byte[] toWav16kMono(byte[] input) throws IOException, InterruptedException {
    Path in = Files.createTempFile("asr-in-", ".bin");
    Path out = Files.createTempFile("asr-out-", ".wav");
    try {
        Files.write(in, input);
        Process p = new ProcessBuilder(
                "ffmpeg", "-y", "-i", in.toString(),
                "-ar", "16000", "-ac", "1", "-f", "wav",
                out.toString())
                .redirectErrorStream(true)
                .start();
        String logs = new String(p.getInputStream().readAllBytes());
        if (!p.waitFor(30, TimeUnit.SECONDS) || p.exitValue() != 0) {
            throw new IllegalStateException("ffmpeg 失败: " + logs);
        }
        return Files.readAllBytes(out);
    } finally {
        Files.deleteIfExists(in);
        Files.deleteIfExists(out);
    }
}
```

生产上别每次起进程——**用 `ffmpeg` 命令行是最简单的方式，但高并发下建议上 JNI 封装或独立转码服务**。临时文件也要记得清理，否则 `/tmp` 会被撑爆（这是真实事故）。

### 3.3 长音频：按静音切分

一个 1 小时的会议录音，25MB 限制基本必超。切分策略：

```java
// 用 ffmpeg 的静音检测切分，比按固定时长切更自然
// ffmpeg -i input.mp3 -af silencedetect=noise=-30dB:d=1 -f null -
// 解析 stderr 里的 silence_start / silence_end，在静音中点切
```

切完逐段转写，最后按时间偏移拼接。注意**跨段的句子会被切断**，所以每段前后各留 0.5 秒重叠，拼接时按最长公共子串去重。

## 四、TTS：把文本变成能播的音频

```java
@Autowired
private SpeechModel speechModel;   // 早期叫 AudioSpeechModel

public byte[] synthesize(String text, String voice) {
    SpeechOptions options = SpeechOptions.builder()
            .voice(voice)                 // alloy / echo / fable / onyx / nova / shimmer
            .speed(1.0f)
            .build();
    byte[] mp3 = speechModel.call(text, options);
    return mp3;
}
```

TTS 在 Java 后端最常见的用途是**异步播报**：生成音频 → 存 OSS → 推送 URL 给客户端。不要同步等着返回音频流，用户体验会很差。

如果要「边说边播」，把长文本按句切分，逐句合成后用 SSE 推送 base64 分片，前端用 `MediaSource` 拼接：

```java
@GetMapping(value = "/tts/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter streamTts(@RequestParam String text) {
    SseEmitter emitter = new SseEmitter(0L);
    executor.execute(() -> {
        try {
            for (String sentence : splitSentences(text, 60)) {   // 每句 ≤60 字
                byte[] audio = speechModel.call(sentence, SpeechOptions.builder()
                        .voice("nova").build());
                emitter.send(SseEmitter.event()
                        .name("audio")
                        .data(Base64.getEncoder().encodeToString(audio)));
            }
            emitter.send(SseEmitter.event().name("done").data("ok"));
            emitter.complete();
        } catch (Exception e) {
            emitter.completeWithError(e);
        }
    });
    return emitter;
}
```

**这里有个音质的坑**：逐句合成再拼接，句与句之间会有明显的停顿和语调断裂。要自然，必须用支持「流式 TTS」的模型（返回 PCM chunk），并且前端边收边播，而不是拼完整文件。

## 五、并发：20 张图怎么处理

批量图片理解是典型 IO 密集任务。JDK 21 的虚拟线程在这里非常合适：

```java
@Bean
public ExecutorService visionExecutor() {
    // 虚拟线程：每个任务一个线程，阻塞等待 HTTP 也不占平台线程
    return Executors.newVirtualThreadPerTaskExecutor();
}

public List<ImageResult> analyzeBatch(List<String> imageUrls) {
    List<Future<ImageResult>> futures = imageUrls.stream()
            .map(url -> visionExecutor().submit(() -> analyzeOne(url)))
            .toList();

    return futures.stream().map(f -> {
        try {
            return f.get(60, TimeUnit.SECONDS);
        } catch (Exception e) {
            return ImageResult.failed(e.getMessage());
        }
    }).toList();
}
```

**但要注意限流。** 虚拟线程让你能瞬间发出 1000 个请求，模型厂商的 RPM/TPM 限制会让你瞬间收到 429。必须配信号量：

```java
private final Semaphore permits = new Semaphore(20);   // 最多 20 并发

public ImageResult analyzeOne(String url) {
    permits.acquireUninterruptibly();
    try {
        return doAnalyze(url);
    } finally {
        permits.release();
    }
}
```

或者用 `Resilience4j` 的 `Bulkhead` + `RateLimiter`，把限流和重试都交给它。

**重试策略**：429 和 5xx 要重试，400（图片格式错误）不要重试。退避用指数 + 抖动：

```java
RetryConfig config = RetryConfig.custom()
        .maxAttempts(3)
        .intervalFunction(IntervalFunction.ofExponentialRandomBackoff(500, 2.0, 0.5))
        .retryOnException(e -> e instanceof RateLimitException
                            || e instanceof ServerErrorException)
        .build();
```

## 六、完整链路：票据识别服务

把上面拼起来，一个可上生产的票据识别流程：

```
客户端上传图片
   ↓
对象存储（返回 key）
   ↓
异步任务（MQ）
   ↓
预处理：EXIF 纠正 → 缩放 1024 → JPEG 0.85
   ↓
VLM 调用（结构化输出 JSON）
   ↓
JSON Schema 校验 + 失败重试（降级到 low detail）
   ↓
落库 + 人工复核队列（置信度低的）
   ↓
回调通知业务系统
```

结构化输出是关键，**不要解析自然语言**：

```java
public record InvoiceInfo(
        String invoiceNo,
        BigDecimal amount,
        String invoiceDate,
        String sellerName,
        String buyerName,
        Double confidence) {}

public InvoiceInfo parseInvoice(byte[] image) {
    String json = chatClient.prompt()
            .system("""
                    你是发票识别引擎。只输出 JSON，不要任何解释。
                     字段：invoiceNo, amount, invoiceDate(YYYY-MM-DD),
                     sellerName, buyerName, confidence(0~1)
                    """)
            .user(u -> u.text("识别这张发票").media(MimeTypeUtils.IMAGE_JPEG,
                    new ByteArrayResource(image)))
            .call()
            .content();

    return objectMapper.readValue(stripCodeFence(json), InvoiceInfo.class);
}
```

`stripCodeFence` 是必须的——模型经常返回 ````json ... ````，直接 `readValue` 会炸。

## 七、踩坑清单

**1. 图片 EXIF 旋转** —— 手机照片必现，识别率从 95% 掉到 40%。

**2. base64 撑爆内存** —— 20MB 图片 base64 后 27MB，再复制几份进 `String`，一个请求就是 100MB 堆占用。用 `byte[]` + 流式编码，别用 `String`。

**3. 语音格式不对** —— 微信语音是 `.amr`/`.silk`，OpenAI 不支持。必须先用 ffmpeg 转。

**4. 临时文件不清理** —— `/tmp` 打满导致整个机器异常。用 `try-with-resources` + 定时清理任务。

**5. 时区/日期格式** —— 模型输出的日期可能是 `2026/10/28`、`10月28日`、`Oct 28, 2026`，校验时统一用 `DateTimeFormatter` 多格式尝试。

**6. 中文乱码** —— 传 URL 时如果 URL 含中文参数没编码，模型侧拉取失败。统一 `URLEncoder.encode(..., UTF_8)`。

**7. 大图被静默降采样** —— 你以为模型看了 4000px 的图，其实它只看了 768px，细小的数字当然识别不出来。**票据类场景要先把关键区域裁剪放大**，而不是整图丢进去。

## 八、面试追问

**Q1：多模态模型的图片是怎么「看懂」的？**

图片被切成 patch（类似 ViT 的 14×14 或 16×16 方块），过视觉编码器（CLIP/SigLIP）变成一组 embedding，再通过投影层映射到 LLM 的 token 空间，和文本 token 拼在一起送进 Transformer。所以**图片在模型眼里就是一堆 token**，这也是按 token 计费的原因。

**Q2：为什么 base64 会让延迟变高？**

三重开销：编码 CPU（约 100MB/s）、请求体膨胀 33%、网关/客户端要完整接收才能转发。URL 方式下模型厂商直接走 CDN 拉取，你的服务只传几十字节。

**Q3：ASR 能流式吗？**

能。流式 ASR 用 chunk 输入、增量输出，适合实时字幕。但准确率通常低于整段转写，因为缺少右侧上下文。会议纪要场景建议整段转写（准确率优先），实时字幕用流式。

**Q4：虚拟线程跑 LLM 调用有什么坑？**

三个：一是 `synchronized` 块里阻塞会导致载体线程 pinning（JDK 24 前），要用 `ReentrantLock`；二是很多 HTTP 客户端（老版本 OkHttp、Apache HttpClient）内部有 `synchronized`，同样会 pinning；三是无限创建虚拟线程会打爆下游限流。**虚拟线程解决的是「线程成本」，不是「下游容量」。**

**Q5：多模态 RAG 怎么做？**

两条路：一是「图片 → 文本描述 → 走文本 RAG」，简单但丢细节；二是「图片 → CLIP embedding → 多向量库」，能图文互搜但要处理模态对齐。生产上常见混合方案：OCR/描述文本做召回，原图做重排和多模态 rerank。

## 结语

多模态在 Java 侧的技术含量，不在「调用模型」，而在**数据的进出**：图片怎么压、音频怎么转、文件怎么传、并发怎么控、成本怎么算。

把这几件事做扎实，你会发现「支持图片和语音」只是给现有链路加了两个适配器；做不扎实，就会变成内存泄漏、429 风暴和账单惊吓。

下一步建议：先做一个「票据/名片识别」的小闭环（上传 → 异步 → 结构化 → 落库），跑通整条链路，再往语音和视频扩展。顺序错了，复杂度会指数上升。
