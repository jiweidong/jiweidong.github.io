---
title: 【Java AI】JVM 内本地推理深度实战：DJL + ONNX Runtime 跑 Embedding 与 Reranker
date: 2026-11-27 08:15:00
tags:
  - Java
  - AI
  - ONNX Runtime
  - DJL
  - Embedding
  - 本地推理
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】JVM 内本地推理深度实战：DJL + ONNX Runtime 跑 Embedding 与 Reranker

## 前言

做 RAG 的 Java 团队迟早会撞上这道选择题：**Embedding 到底调远程 API，还是在 JVM 里自己跑？**

远程 API 的账很好算：一次 embedding 请求 20ms~80ms，按 token 计费，量小的时候几美元，量大了就是每月几千美元；更要命的是**数据出网**——很多金融、医疗、政企客户的文档根本不允许发到第三方。

本地推理的账则没那么直观：

- 模型能不能在 JVM 里跑？
- 一个 4 核 8G 的 Pod 能扛多少 QPS？
- `NDArray` 会不会把堆外内存吃光？
- 换模型之后索引怎么办？

这篇文章用 **DJL + ONNX Runtime** 把一条完整的 JVM 内推理链路写出来：模型加载、tokenizer、批处理、线程模型、内存控制、Spring AI 集成、与远程 API 的混合路由。所有代码都是可运行的 Java，不是伪代码。

---

## 一、先明确边界：什么该本地跑，什么不该

不是所有模型都适合放进 JVM。判断标准只有三条：**模型大小、延迟敏感度、数据合规**。

| 场景 | 推荐方案 | 理由 |
|---|---|---|
| Embedding（bge-small / m3e / gte-small） | **JVM 内本地推理** | 模型小（~100MB）、无生成、批处理吞吐高 |
| Cross-encoder Reranker（bge-reranker-base） | **JVM 内本地推理** | 单次 20~40ms，比远程少一次网络往返 |
| 生成式 LLM（7B+） | 远程 API / 独立推理服务 | 显存与吞吐不是 JVM 该干的活 |
| 多模态大模型 | 远程 API | 同上 |
| 极低延迟（<5ms）的向量化 | 本地小模型 + 缓存 | 网络 RTT 都不止 5ms |

一句话：**判别式小模型（Embedding / Reranker / 分类）放 JVM，生成式大模型放外面。** 这条边界划清楚，后面的工程才有意义。

---

## 二、技术栈分层：DJL 与 ONNX Runtime 各干什么

很多人以为 DJL 是"另一个推理引擎"，其实它是**引擎之上的抽象层**：

```
┌─────────────────────────────────────────────┐
│ 你的业务代码（Spring AI EmbeddingModel 实现） │
├─────────────────────────────────────────────┤
│ DJL API：Model / Predictor / Translator      │  ← 统一抽象、生命周期管理
│          NDArray / NDManager（内存池）        │
├─────────────────────────────────────────────┤
│ Engine SPI：OnnxRuntime / PyTorch / MXNet    │  ← 可替换
├─────────────────────────────────────────────┤
│ ONNX Runtime native（C++）                    │  ← 真正的计算
│   CPU EP / CUDA EP / TensorRT EP             │
└─────────────────────────────────────────────┘
```

- **ONNX Runtime**：跨平台推理引擎，负责图优化（常量折叠、算子融合）、内存规划、多线程执行；
- **DJL**：负责模型加载、`NDManager` 内存池（避免 native 内存泄漏）、`Translator` 前后处理抽象、以及一套统一的 API 让你以后能换引擎；
- **HuggingFace Tokenizers（JNI）**：Rust 实现的分词器，性能和 Python 侧一致，避免自己手写 BPE。

如果你的团队只想"最快跑起来"，也可以绕过 DJL，直接用 `OrtSession` + DJL 的 tokenizer。下面两条路线都会给。

---

## 三、依赖与镜像：三个容易翻车的点

```groovy
dependencies {
    implementation "ai.djl:api:0.31.0"
    implementation "ai.djl.onnxruntime:onnxruntime-engine:0.31.0"
    implementation "ai.djl.huggingface:tokenizers:0.31.0"
    // 纯 Java 侧只需要上面三个；GPU 场景额外引入：
    // implementation "com.microsoft.onnxruntime:onnxruntime_gpu:1.20.0"
}
```

### 3.1 native 库是运行时下载的

DJL 的 engine 依赖里**不含 native 库**，首次加载模型时会从 `djl.ai` 的 S3 下载到 `~/.djl.ai/`。这在生产环境有三个问题：

1. 容器无外网 → 启动时卡住直到超时；
2. 多 Pod 同时启动 → 重复下载、拖慢扩容；
3. 镜像不可复现 → 今天能跑，明天 S3 挂了就跑不起来。

正确做法是**构建镜像时预热**：

```dockerfile
# 构建阶段：跑一次最小加载，把 native 与模型固化进镜像
RUN java -Dai.djl.offline=false -cp app.jar com.example.Warmup && \
    ls -R /root/.djl.ai

# 运行阶段：强制离线，缺失就直接失败（快速暴露问题）
ENV JAVA_TOOL_OPTIONS="-Dai.djl.offline=true"
```

### 3.2 glibc 依赖

ONNX Runtime 的 Linux 原生库是**动态链接 glibc** 的。`alpine`（musl）直接报 `Error loading libonnxruntime.so`。用 `debian-slim` / `ubuntu` / `amazonlinux` 基础镜像，或者接受 `gcompat` 的兼容层（不推荐，偶发符号解析失败）。

### 3.3 模型文件放哪

三种方式，按生产推荐度排序：

| 方式 | 优点 | 缺点 |
|---|---|---|
| 打进镜像（`/models`） | 启动快、可复现、无外部依赖 | 镜像大 100~300MB |
| 启动时从对象存储拉 | 镜像小、模型可独立升级 | 冷启动慢、需要重试与校验 |
| 挂载 PVC / OSS | 多 Pod 共享 | 依赖存储可用性 |

Embedding 模型只有 100MB 左右，**直接打进镜像**是最省心的选择；真要独立升级，用"模型版本目录 + 启动参数指定"即可。

---

## 四、路线 A：ONNX Runtime 原生 + DJL Tokenizer（推荐）

这条路线最可控：前后处理全在自己手里，出问题能精确定位到哪一步。

### 4.1 模型准备

从 HuggingFace 下载 ONNX 版本的模型（`bge-small-zh-v1.5` 为例）：

```
models/bge-small-zh-v1.5/
├── model.onnx          # 或者 model_quantized.onnx
├── tokenizer.json
└── config.json
```

用 `optimum-cli` 导出，或者直接用社区已导出的 ONNX 仓库。**注意确认输入名**，不同导出脚本会不一样：

```bash
python -c "
import onnxruntime as ort
s = ort.InferenceSession('models/bge-small-zh-v1.5/model.onnx')
print([i.name for i in s.get_inputs()])
print([o.name for o in s.get_outputs()])
"
# 常见输出：['input_ids', 'attention_mask', 'token_type_ids']
# 输出：['last_hidden_state']
```

### 4.2 核心实现

```java
@Component
public class LocalEmbeddingModel implements AutoCloseable {

    private static final int MAX_LEN = 512;

    private final OrtEnvironment env;
    private final OrtSession session;
    private final HuggingFaceTokenizer tokenizer;
    private final int dimension;

    public LocalEmbeddingModel(@Value("${ai.embedding.model-path}") String modelPath)
            throws Exception {
        this.env = OrtEnvironment.getEnvironment();

        OrtSession.SessionOptions opts = new OrtSession.SessionOptions();
        // 关键：线程数必须与容器 CPU limit 对齐，见第五节
        int threads = Math.max(1, Runtime.getRuntime().availableProcessors());
        opts.setIntraOpNumThreads(threads);
        opts.setInterOpNumThreads(1);
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
        // 关闭 CPU 内存 arena 可以降低 RSS 峰值，代价是少量分配开销
        opts.setCPUArenaAllocator(false);

        this.session = env.createSession(modelPath + "/model.onnx", opts);

        this.tokenizer = HuggingFaceTokenizer.builder()
            .optTokenizerPath(Paths.get(modelPath, "tokenizer.json"))
            .optMaxLength(MAX_LEN)
            .optTruncation(true)
            .optPadding(false)   // 由我们自己按 batch 内最长 padding
            .build();

        this.dimension = readDimension(modelPath);
    }

    /** 单条：查询向量化 */
    public float[] embed(String text) {
        return embedBatch(List.of(text)).get(0);
    }

    /** 批量：按 token 数排序 + 分桶，减少 padding 浪费 */
    public List<float[]> embedBatch(List<String> texts) {
        if (texts.isEmpty()) return List.of();

        List<Encoding> encodings = tokenizer.batchEncode(texts);

        // 按长度排序，让同 batch 内长度接近（padding 浪费最小）
        Integer[] order = IntStream.range(0, encodings.size()).boxed()
            .sorted(Comparator.comparingInt(i -> encodings.get(i).getIds().length))
            .toArray(Integer[]::new);

        float[][] result = new float[texts.size()][];
        int batchSize = 32;

        for (int start = 0; start < order.length; start += batchSize) {
            int end = Math.min(start + batchSize, order.length);
            Integer[] slice = Arrays.copyOfRange(order, start, end);
            float[][] vectors = runBatch(slice, encodings);
            for (int k = 0; k < slice.length; k++) {
                result[slice[k]] = vectors[k];
            }
        }
        return Arrays.asList(result);
    }

    private float[][] runBatch(Integer[] idx, List<Encoding> encodings) {
        int batch = idx.length;
        int seqLen = Arrays.stream(idx)
            .mapToInt(i -> encodings.get(i).getIds().length).max().orElse(1);

        long[] ids = new long[batch * seqLen];
        long[] mask = new long[batch * seqLen];
        long[] types = new long[batch * seqLen];

        for (int b = 0; b < batch; b++) {
            Encoding e = encodings.get(idx[b]);
            long[] eIds = e.getIds();
            long[] eMask = e.getAttentionMask();
            long[] eTypes = e.getTypeIds();
            for (int t = 0; t < seqLen; t++) {
                int p = b * seqLen + t;
                boolean valid = t < eIds.length;
                ids[p]   = valid ? eIds[t] : 0;          // pad id
                mask[p]  = valid ? eMask[t] : 0;         // padding 必须 mask 掉
                types[p] = valid ? eTypes[t] : 0;
            }
        }

        long[] shape = {batch, seqLen};
        try (OnnxTensor idsT  = OnnxTensor.createTensor(env, LongBuffer.wrap(ids), shape);
             OnnxTensor maskT = OnnxTensor.createTensor(env, LongBuffer.wrap(mask), shape);
             OnnxTensor typeT = OnnxTensor.createTensor(env, LongBuffer.wrap(types), shape)) {

            Map<String, OnnxTensor> feeds = new HashMap<>();
            feeds.put("input_ids", idsT);
            feeds.put("attention_mask", maskT);
            if (session.getInputNames().contains("token_type_ids")) {
                feeds.put("token_type_ids", typeT);
            }

            try (OrtSession.Result out = session.run(feeds)) {
                float[][][] hidden = (float[][][]) out.get(0).getValue();
                float[][] vectors = new float[batch][];
                for (int b = 0; b < batch; b++) {
                    vectors[b] = clsPoolAndNormalize(hidden[b]);
                }
                return vectors;
            }
        } catch (OrtException e) {
            throw new IllegalStateException("onnx inference failed", e);
        }
    }

    /** bge 系列：取 [CLS]（第 0 个 token）+ L2 归一化 */
    private float[] clsPoolAndNormalize(float[][] tokenVectors) {
        float[] v = tokenVectors[0].clone();
        double norm = 0;
        for (float x : v) norm += x * x;
        norm = Math.sqrt(norm);
        if (norm > 1e-12) {
            for (int i = 0; i < v.length; i++) v[i] /= (float) norm;
        }
        return v;
    }

    @Override
    public void close() throws Exception {
        session.close();
        tokenizer.close();
    }
}
```

### 4.3 四个必须理解的细节

**（1）pooling 方式必须与模型训练时一致**

| 模型 | pooling | 归一化 | 维度 |
|---|---|---|---|
| bge-small-zh-v1.5 | CLS（第 0 个 token） | L2 | 512 |
| bge-base-zh-v1.5 | CLS | L2 | 768 |
| m3e-small | CLS | L2 | 512 |
| gte-small | 平均池化（mean） | L2 | 384 |
| all-MiniLM-L6-v2 | mean | L2 | 384 |

用错 pooling 不会报错，只会让**相似度排序变差**——这是最隐蔽的一类 bug，因为它"看起来还能用"。判断方法：拿 20 组已知相似/不相似的句子，算余弦相似度，与模型卡片的示例对比。

**（2）padding 必须 mask**

`attention_mask=0` 的位置在 self-attention 里会被屏蔽。如果忘了传 mask，padding token 会参与计算，**同一个句子在不同 batch 里会得到不同的向量**——这会导致"离线建索引"和"在线查询"的向量分布不一致，召回率悄悄下降。

**（3）`batchEncode` 的顺序**

DJL 的 `batchEncode` 保持输入顺序，但**不要假设**；代码里用 `order` 数组显式回填，避免任何顺序假设。

**（4）`OnnxTensor` 必须关闭**

`OnnxTensor` 持有 native 内存，必须 `try-with-resources`。JVM 的 GC 不会感知 native 分配，堆很健康但 RSS 一路涨到 OOMKilled，是这个 API 最经典的坑。

---

## 五、线程模型：最容易把 CPU 打爆的地方

### 5.1 ONNX Runtime 的线程是 native 线程

`setIntraOpNumThreads(N)` 会创建 N 个 native 工作线程做算子内并行。问题是：**这些线程不受 JVM 的 ForkJoinPool 管理，也不感知 cgroup CPU quota。**

典型事故：

- 容器 `limits.cpu=2`，但 `Runtime.availableProcessors()` 在某些配置下返回宿主机核数（64）；
- 代码里 `setIntraOpNumThreads(64)`；
- 结果 64 个 native 线程争抢 2 核，上下文切换爆炸，P99 从 20ms 涨到 800ms。

正确做法：

```java
// 方案 1：显式配置，不依赖 availableProcessors
@Value("${ai.embedding.intra-op-threads:2}")
private int intraOpThreads;

// 方案 2：从 cgroup 读真实配额（Java 10+ 已支持 cgroup v2）
// Runtime.availableProcessors() 在 -XX:+UseContainerSupport（默认开）下
// 会按 cpu.max 计算，但某些老版本/特殊配置会读错，建议显式配置兜底
```

经验值：**`intra_op_num_threads = CPU limit`，`inter_op_num_threads = 1`**。Embedding 模型小，算子内并行的收益远小于线程争抢的成本。

### 5.2 并发请求：Session 线程安全，但要限流

`OrtSession.run()` 是线程安全的，可以多线程并发调用。但并发数不受控会导致：

- native 内存峰值 = 并发数 × 单次中间张量；
- CPU 排队，P99 抖动。

用信号量做准入控制（Java 21 虚拟线程下依然需要，因为它保护的是 native 资源）：

```java
private final Semaphore permits = new Semaphore(8); // 2 × CPU limit

public float[] embedWithLimit(String text) {
    if (!permits.tryAcquire(200, TimeUnit.MILLISECONDS)) {
        throw new RejectedExecutionException("embedding queue full");
    }
    try {
        return embed(text);
    } finally {
        permits.release();
    }
}
```

配合 Micrometer 打点（队列深度、拒绝数、推理耗时），这就是一个可运维的推理服务。

### 5.3 虚拟线程的边界

虚拟线程解决的是"阻塞等待"的并行度，**不解决 CPU 密集**。Embedding 是纯 CPU 计算，开 1 万个虚拟线程只会让 8 个核更忙。虚拟线程在这里的正确用法是：**让上层调用（等远程 LLM、等 DB）不占平台线程**，而不是给推理本身加并发。

---

## 六、内存：RSS 是真正的敌人

### 6.1 模型权重的账

| 模型 | 参数量 | fp32 权重 | int8 量化后 |
|---|---|---|---|
| bge-small-zh-v1.5 | ~24M | ~96MB | ~24MB |
| bge-base-zh-v1.5 | ~102M | ~400MB | ~100MB |
| bge-reranker-base | ~278M | ~1.1GB | ~280MB |

除了权重，ONNX Runtime 还有：

- **activation arena**：中间张量，随 batch × seqLen 增长；
- **CPU arena**：分配器缓存，`setCPUArenaAllocator(false)` 可降低峰值；
- **JNI 与 direct buffer**：`OnnxTensor` 的数据拷贝。

一个 `bge-small` + batch 32 × 512 token 的实例，稳态 RSS 大约 **400~600MB**（含 JVM 堆）。容器 limit 给 1.5GB 比较稳。

### 6.2 内存公式

```
container_limit ≥ JVM_heap + 模型权重 + activation_peak + native_overhead
                  (512MB)   (96MB)      (batch×seq×hidden×4×层数系数)   (200MB)
```

`-XX:MaxRAMPercentage=60` 是保守起点；堆外部分用 NMT + `smaps_rollup` 观测，别只看堆。

### 6.3 量化：省内存也省 CPU

ONNX Runtime 支持动态量化（`quantize_dynamic`），把 MatMul 的权重转 int8：

```python
from onnxruntime.quantization import quantize_dynamic, QuantType
quantize_dynamic("model.onnx", "model_int8.onnx", weight_type=QuantType.QInt8)
```

效果（示例，实际以你的模型为准）：

- 模型体积 ≈ 1/4；
- CPU 推理速度提升 1.5~2.5 倍（AVX2/AVX512 的 VNNI 指令）；
- 余弦相似度平均下降 < 0.005，Top-10 召回基本无损。

**但一定要用黄金集验证**：量化对中文长文本的影响可能大于英文，别直接上线。

---

## 七、集成 Spring AI：让本地模型"伪装"成远程模型

Spring AI 的 `EmbeddingModel` 是一个接口，实现它就能无缝接入 `VectorStore`、`EmbeddingRequest` 等上层能力：

```java
@Component
public class LocalEmbeddingModelAdapter implements EmbeddingModel {

    private final LocalEmbeddingModel delegate;

    @Override
    public EmbeddingResponse call(EmbeddingRequest request) {
        List<float[]> vectors = delegate.embedBatch(request.getInstructions());

        List<Embedding> embeddings = IntStream.range(0, vectors.size())
            .mapToObj(i -> new Embedding(vectors.get(i), i))
            .toList();

        // 本地推理没有 token 计费，但仍要给出 usage 便于观测
        Usage usage = new Usage(
            request.getInstructions().stream().mapToInt(String::length).sum(), 0);

        return new EmbeddingResponse(embeddings,
            new EmbeddingResponseMetadata("local-bge-small-zh-v1.5", usage));
    }

    @Override
    public float[] embed(String text) {
        return delegate.embed(text);
    }

    @Override
    public int dimensions() {
        return delegate.dimension();
    }
}
```

三点注意：

1. **`dimensions()` 必须与索引一致**。换模型 = 换维度 = 必须重建索引，没有任何兼容余地；
2. **模型标识要写进向量元数据**。查询时校验 `model_id`，防止"用 A 模型的查询去搜 B 模型的索引"这种静默错误；
3. **不要在 `embed()` 里做重试**。本地推理失败通常是 OOM 或 native 崩溃，重试只会放大问题，应该快速失败并降级。

---

## 八、混合路由：本地打底，远程兜底

生产上很少"全本地"或"全远程"，更常见的是分层：

```java
@Service
public class HybridEmbeddingService {

    private final LocalEmbeddingModel local;
    private final EmbeddingModel remote;
    private final CircuitBreaker breaker;

    public float[] embed(String text) {
        // 超长文本本地会截断，直接走远程（远程模型上下文更大）
        if (estimateTokens(text) > 480) {
            return remote.embed(text);
        }
        try {
            return breaker.run(() -> local.embed(text),
                fallback -> remote.embed(text));
        } catch (Exception e) {
            return remote.embed(text);
        }
    }
}
```

路由维度建议：

| 维度 | 规则 |
|---|---|
| 文本长度 | > 阈值走远程（避免截断丢信息） |
| 语言 | 小语种走远程（本地模型中文/英文强） |
| 租户等级 | 免费租户走本地（成本优先），付费走远程（质量优先） |
| 熔断状态 | 本地 CPU 饱和 → 溢流到远程 |

**注意**：本地与远程模型的向量**不在同一空间**，不能混用。要么按租户/语料分索引，要么统一走一个模型。这是混合路由最容易踩的坑。

---

## 九、性能实测与容量估算

测试环境：8C16G 容器（`limits.cpu=4`），bge-small-zh-v1.5 int8，batch 32，seqLen 128。

| 指标 | 数值（示例） |
|---|---|
| 单条（seqLen 32）P50 | 6ms |
| 单条 P99 | 15ms |
| batch 32（seqLen 128） | 95ms |
| 吞吐（4 核） | ~1100 token/s |
| 稳态 RSS | 520MB |

容量公式：

```
所需核数 ≈ QPS × 平均 token 数 ÷ 单核吞吐(token/s)
         = QPS × 80 ÷ 275
```

例如 50 QPS、平均 80 token：`50 × 80 ÷ 275 ≈ 14.5` 核。这个量级下，远程 API 的成本可能更低——**所以本地推理的真正价值在合规与延迟稳定性，不是"一定更便宜"**。

---

## 十、踩坑清单

| 现象 | 根因 | 处理 |
|---|---|---|
| 堆很稳但 RSS 涨到 OOMKilled | `OnnxTensor`/`NDArray` 未关闭 | try-with-resources；开 NMT 跟踪 |
| 同一句话两次向量不同 | 忘了传 `attention_mask` 或 padding 方式不一致 | 检查 mask、固定 padding 策略 |
| 相似度排序明显变差 | pooling 用错（mean vs CLS）或漏了 L2 归一化 | 按模型卡片实现 |
| 启动卡 60s 后失败 | native 库在线下载超时 | 镜像内预热 + `-Dai.djl.offline=true` |
| `libonnxruntime.so` 找不到 | alpine/musl 不兼容 | 换 glibc 基础镜像 |
| P99 抖动严重 | intra-op 线程数 > CPU limit | 显式配置线程数 + 信号量限流 |
| 换模型后召回暴跌 | 向量空间变了，索引没重建 | 模型版本进索引元数据，换模型必重建 |
| 导入模型报 opset 不支持 | ONNX opset 高于 runtime 支持版本 | 导出时指定 `opset=17` 以下 |

---

## 十一、面试高频追问

**Q1：为什么 Embedding 适合放 JVM，而 LLM 不适合？**
Embedding 是单次前向的判别式模型，参数量小（千万级）、无自回归解码、可批处理，CPU 即可满足；LLM 是自回归生成，参数量大、依赖显存带宽与 KV Cache，JVM 不是合适的运行时。

**Q2：DJL 和直接调 ONNX Runtime 有什么区别？**
DJL 提供引擎抽象、`NDManager` 内存池、Translator 前后处理和模型管理，屏蔽不同引擎差异；直接调 ORT 更可控、依赖更少，但要自己管 native 内存与前后处理。生产上常见组合是"ORT 做推理 + DJL tokenizer"。

**Q3：`OnnxTensor` 为什么要显式关闭？**
它的数据在 native 内存（或 direct buffer），不受 JVM 堆 GC 管理。不关闭会导致 native 内存泄漏，表现为堆正常但容器 RSS 持续增长直到 OOMKilled。

**Q4：batch 越大越好吗？**
不是。batch 增大会线性增加 activation 内存，并拉高单次延迟（P99）；同时 padding 浪费随 batch 内长度差异放大。工程上是"按 token 数分桶 + 适中 batch（16~32）"。

**Q5：本地 embedding 和远程 embedding 能混用吗？**
不能。不同模型的向量空间不可比，余弦相似度没有意义。必须保证"索引与查询使用同一模型、同一 pooling、同一归一化"。

---

## 十二、总结

JVM 内跑 Embedding / Reranker 是一件**工程问题**，不是算法问题。真正的难点不在模型，而在：

1. **内存**：native 内存不受 GC 管理，容器 limit 要按"堆 + 权重 + activation"算；
2. **线程**：ORT 的 native 线程不感知 cgroup，必须显式配置；
3. **一致性**：pooling、归一化、模型版本三者必须与索引严格对齐；
4. **可运维**：离线化 native 库、信号量限流、指标打点，一样都不能少。

落地路径建议：

- 第一步：用 bge-small + int8 量化跑通单机，拿 20 组样本验证向量质量；
- 第二步：接 Spring AI `EmbeddingModel`，替换远程实现，观察召回是否一致；
- 第三步：加混合路由（超长/小语种/熔断溢流），把本地当"主力"、远程当"兜底"；
- 第四步：把模型版本、pooling 方式、归一化开关写进索引元数据，做成发布门禁。

做完这四步，你就有了一套"数据不出网、延迟可预期、成本可核算"的 Java 侧向量化基础设施。
