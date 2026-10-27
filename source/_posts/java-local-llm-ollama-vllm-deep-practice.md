---
title: 【Java AI】本地大模型部署与 Java 调用深度实战：Ollama、vLLM 与 OpenAI 兼容协议
date: 2026-10-27 08:00:00
tags:
  - Java
  - AI
  - Ollama
  - vLLM
  - Spring AI
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】本地大模型部署与 Java 调用深度实战

## 前言

做 AI 应用开发，Java 工程师遇到的第一道现实问题是：**模型跑在哪？**

走公有云 API 最省事，但企业场景里经常会撞上四种硬约束：

1. **数据不能出内网**（金融、医疗、政企）；
2. **成本不可控**（高频调用下按 token 计费比自建贵一个量级）；
3. **需要私有微调模型**（行业术语、内部代码库）；
4. **离线/边缘环境**（工厂、车载）。

这时候就必须自建推理服务。好消息是：**推理服务的对外接口已经高度标准化成 OpenAI 兼容协议**，Java 侧根本不需要关心底层是 Ollama、vLLM 还是 TGI——只要对方暴露 `/v1/chat/completions`，Spring AI、LangChain4j、甚至裸 `HttpClient` 都能接。

这篇文章讲三件事：怎么选推理引擎、怎么在 Java 里接、以及生产环境里那些没人告诉你的坑。

---

## 一、推理引擎选型：Ollama vs vLLM vs LM Studio

先说结论：**开发调试用 Ollama，生产并发用 vLLM，个人桌面用 LM Studio。**

| 维度 | Ollama | vLLM | LM Studio |
|---|---|---|---|
| 定位 | 本地开发/单机部署 | 生产级高吞吐推理 | 桌面 GUI 工具 |
| 底层 | llama.cpp（GGUF，CPU/GPU 混合） | PyTorch + PagedAttention | llama.cpp |
| 并发能力 | 弱（默认单请求串行，`OLLAMA_NUM_PARALLEL` 可调但有限） | 强（Continuous Batching，吞吐高 5~20 倍） | 极弱（单用户） |
| 显存效率 | 中（量化友好，4bit 可跑） | 高（PagedAttention + Prefix Caching） | 中 |
| 量化支持 | Q4_K_M / Q5_K_M / Q8_0 等 GGUF | AWQ / GPTQ / FP8 / INT8 | 同 Ollama |
| 模型格式 | GGUF | HuggingFace 原生 / safetensors | GGUF |
| OpenAI 兼容 | ✅ `/v1/chat/completions` | ✅ 原生兼容 | ✅ |
| 多卡/张量并行 | ❌（弱） | ✅ `--tensor-parallel-size` | ❌ |
| 运维复杂度 | 极低（单二进制） | 中（Python 环境 + CUDA） | 极低 |
| 适用场景 | 开发、POC、内网小流量 | 生产 API、批量推理 | 个人试用 |

### 1.1 一个常见的误判

很多团队用 Ollama 上了生产，然后在压测时发现：**QPS 上不去，GPU 利用率只有 20%**。

原因不是模型不行，而是 Ollama 的调度模型：它默认对同一模型的请求做排队（`OLLAMA_NUM_PARALLEL=1`），即使 GPU 还有余量也不会并行处理。把 `OLLAMA_NUM_PARALLEL` 调到 4~8 能缓解，但它是**静态分配 KV Cache** 的——每个并行槽位都要预留完整的上下文空间，显存浪费严重。

vLLM 的 PagedAttention 则把 KV Cache 按 block 管理（类似操作系统的虚拟内存分页），显存利用率能做到 90% 以上，配合 Continuous Batching，同样硬件吞吐能高一个数量级。

**判断标准**：如果并发请求数长期 > 4，或者需要「多用户同时对话」，就别用 Ollama 上生产。

### 1.2 显存估算：先算再买卡

上模型前必须算显存，否则跑到一半 OOM 会非常痛苦。

```
显存 ≈ 模型参数量 × 每参数字节数 + KV Cache + 激活值开销

每参数字节数：
  FP16  → 2 bytes
  INT8  → 1 byte
  INT4  → 0.5 byte

KV Cache（每 token）≈ 2 × layers × hidden_size × 2 bytes  (FP16)
```

举例：Qwen2.5-7B（28 层，hidden 3584），FP16：

- 权重：7B × 2 = 14GB
- KV Cache（每 token）：2 × 28 × 3584 × 2 ≈ 401KB
- 8K 上下文 × 4 并发：0.4MB × 8192 × 4 ≈ 13GB
- 合计约 27GB → 需要 32GB 显存的卡（A100 40G / 4090 24G 不够跑 4 并发 8K）

如果换 INT4 量化（AWQ）：权重降到 3.5GB，KV Cache 不变（除非用 FP8 KV），总需求约 17GB → 单张 4090 可以跑。

| 模型规模 | FP16 权重 | INT4 权重 | 建议显卡（4 并发 4K 上下文） |
|---|---|---|---|
| 7B | 14GB | 3.5GB | 24GB（4090/L4） |
| 14B | 28GB | 7GB | 48GB（A6000/L40S） |
| 32B | 64GB | 16GB | 80GB（A100/H100） |
| 72B | 144GB | 36GB | 2×80GB（张量并行） |

---

## 二、Ollama 部署与配置

### 2.1 安装与拉模型

```bash
curl -fsSL https://ollama.com/install.sh | sh

# 拉模型（4bit 量化，约 4.7GB）
ollama pull qwen2.5:7b-instruct-q4_K_M

# 验证
ollama run qwen2.5:7b-instruct-q4_K_M "用一句话解释什么是幂等"
```

### 2.2 关键环境变量

```bash
# /etc/systemd/system/ollama.service.d/override.conf
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=4"        # 并行请求数
Environment="OLLAMA_MAX_LOADED_MODELS=2"   # 同时驻留内存的模型数
Environment="OLLAMA_KEEP_ALIVE=30m"        # 模型驻留时间，避免反复加载
Environment="OLLAMA_FLASH_ATTENTION=1"     # 开启 FlashAttention，省显存
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"    # KV Cache 量化，省一半显存
```

`OLLAMA_KEEP_ALIVE` 特别重要。默认是 5 分钟，意味着低峰期模型会被卸载，下一个请求要重新加载——7B 模型加载要 3~10 秒，用户会看到「第一次特别慢」。

### 2.3 验证 OpenAI 兼容端点

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5:7b-instruct-q4_K_M",
    "messages": [{"role":"user","content":"你好"}],
    "stream": false
  }'
```

只要能返回标准 OpenAI 格式，Java 侧就可以完全按 OpenAI 协议来接。

---

## 三、vLLM 部署

### 3.1 启动命令

```bash
pip install vllm

vllm serve Qwen/Qwen2.5-7B-Instruct \
  --served-model-name qwen2.5-7b \
  --host 0.0.0.0 --port 8000 \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --max-num-seqs 32 \
  --enable-prefix-caching \
  --quantization awq
```

关键参数解释：

| 参数 | 作用 | 调优建议 |
|---|---|---|
| `--max-model-len` | 最大上下文 | 按业务实际需要设，设大了浪费 KV Cache |
| `--gpu-memory-utilization` | 显存占用上限比例 | 0.85~0.92，太高会和 CUDA 上下文冲突 |
| `--max-num-seqs` | 最大并发序列数 | 决定吞吐，显存够就往上调 |
| `--enable-prefix-caching` | 复用相同前缀的 KV | **强烈建议开**，系统提示词相同能省 30%+ 计算 |
| `--tensor-parallel-size` | 张量并行卡数 | 单卡放不下时用，通常等于 GPU 数 |
| `--quantization` | 量化方式 | awq/gptq/fp8 |

### 3.2 Docker 部署（生产推荐）

```bash
docker run --gpus all --shm-size=16g -p 8000:8000 \
  -v /data/models:/models \
  vllm/vllm-openai:latest \
  --model /models/Qwen2.5-7B-Instruct-AWQ \
  --served-model-name qwen2.5-7b \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --enable-prefix-caching
```

`--shm-size=16g` 必须给够，vLLM 的多进程通信依赖共享内存，默认 64MB 会直接崩。

---

## 四、Java 侧接入：三种方式

### 4.1 方式一：Spring AI（推荐，工程化程度最高）

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-openai-spring-boot-starter</artifactId>
    <version>1.0.0</version>
</dependency>
```

```yaml
spring:
  ai:
    openai:
      base-url: http://localhost:11434     # 指向 Ollama
      api-key: ollama                       # 本地服务不校验，随便填
      chat:
        options:
          model: qwen2.5:7b-instruct-q4_K_M
          temperature: 0.7
          max-tokens: 2048
      # 生产建议加超时
      client:
        connect-timeout: 5s
        read-timeout: 120s
```

```java
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.stereotype.Service;
import reactor.core.publisher.Flux;

@Service
public class LocalLlmService {

    private final ChatClient chatClient;

    public LocalLlmService(ChatClient.Builder builder) {
        this.chatClient = builder
            .defaultSystem("你是一个严谨的 Java 技术专家，回答要给出代码示例。")
            .build();
    }

    /** 同步调用 */
    public String ask(String question) {
        return chatClient.prompt()
            .user(question)
            .call()
            .content();
    }

    /** 流式调用（SSE） */
    public Flux<String> stream(String question) {
        return chatClient.prompt()
            .user(question)
            .stream()
            .content();
    }
}
```

Spring AI 的好处是：**换模型只改 `base-url` 和 `model`**，从 Ollama 切到 vLLM 切到 OpenAI 官方，业务代码零改动。

### 4.2 方式二：裸 HttpClient（零依赖，适合轻量场景）

不想引 Spring AI 的时候，JDK 11+ 的 `HttpClient` 足够：

```java
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.*;
import java.time.Duration;
import java.util.List;
import java.util.Map;

public class RawLlmClient {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private final HttpClient http = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();

    private final String baseUrl;
    private final String model;

    public RawLlmClient(String baseUrl, String model) {
        this.baseUrl = baseUrl;
        this.model = model;
    }

    public String chat(String prompt) throws Exception {
        Map<String, Object> body = Map.of(
            "model", model,
            "messages", List.of(Map.of("role", "user", "content", prompt)),
            "stream", false,
            "temperature", 0.7
        );

        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create(baseUrl + "/v1/chat/completions"))
            .timeout(Duration.ofSeconds(120))
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer local")
            .POST(HttpRequest.BodyPublishers.ofString(
                MAPPER.writeValueAsString(body)))
            .build();

        HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) {
            throw new IllegalStateException("LLM error: " + resp.statusCode()
                + " " + resp.body());
        }
        JsonNode root = MAPPER.readTree(resp.body());
        return root.path("choices").path(0).path("message").path("content").asText();
    }
}
```

### 4.3 方式三：流式解析（SSE）

流式的关键是把 `stream: true` 打开，然后按 `data: ` 前缀逐行解析：

```java
public void chatStream(String prompt, java.util.function.Consumer<String> onToken)
        throws Exception {

    Map<String, Object> body = Map.of(
        "model", model,
        "messages", List.of(Map.of("role", "user", "content", prompt)),
        "stream", true
    );

    HttpRequest req = HttpRequest.newBuilder()
        .uri(URI.create(baseUrl + "/v1/chat/completions"))
        .header("Content-Type", "application/json")
        .POST(HttpRequest.BodyPublishers.ofString(MAPPER.writeValueAsString(body)))
        .build();

    HttpResponse<java.util.stream.Stream<String>> resp =
        http.send(req, HttpResponse.BodyHandlers.ofLines());

    resp.body()
        .filter(line -> line.startsWith("data: "))
        .map(line -> line.substring(6))
        .takeWhile(data -> !"[DONE]".equals(data))
        .forEach(data -> {
            try {
                JsonNode delta = MAPPER.readTree(data)
                    .path("choices").path(0).path("delta");
                String token = delta.path("content").asText("");
                if (!token.isEmpty()) {
                    onToken.accept(token);
                }
            } catch (Exception ignored) {
                // 单行解析失败不影响整体流
            }
        });
}
```

> 踩坑：`BodyHandlers.ofLines()` 的流**必须在 try-with-resources 或显式关闭**，否则连接不会释放，压测时会看到连接数暴涨。

---

## 五、生产化的六个关键问题

### 5.1 超时怎么设

LLM 调用和普通 HTTP 完全不同：**首 token 时间（TTFT）可能 1~3 秒，完整生成可能要 60~120 秒**。

```yaml
# Spring AI 的 OpenAI 客户端
spring.ai.openai.client.read-timeout: 180s
```

但更重要的是**业务侧的超时**要小于 Nginx/网关的超时，形成「业务超时 < 网关超时」的梯度，否则用户看到的是 502 而不是友好提示。

| 层级 | 建议超时 |
|---|---|
| 业务方法 | 90s（非流式）/ 首 token 10s（流式） |
| HTTP 客户端 read-timeout | 120s |
| Nginx `proxy_read_timeout` | 150s |
| 网关 | 180s |

### 5.2 并发模型：虚拟线程是天然搭档

LLM 调用是**典型的重 IO 等待**（CPU 在远端 GPU 上干活，本地线程纯等），非常适合虚拟线程：

```java
@Bean
public ExecutorService llmExecutor() {
    return Executors.newVirtualThreadPerTaskExecutor();
}
```

```yaml
spring:
  threads:
    virtual:
      enabled: true
```

压测数据（vLLM 单卡 4090，7B 模型，平均输出 200 token）：

| 线程模型 | 并发 32 | 并发 64 | 并发 128 |
|---|---|---|---|
| 平台线程池（200） | 吞吐 18 req/s，P99 12s | 吞吐 19 req/s，P99 25s | 大量超时 |
| 虚拟线程 | 吞吐 19 req/s，P99 11s | 吞吐 20 req/s，P99 13s | 吞吐 19 req/s，P99 22s |

注意：**吞吐上限由 GPU 决定，虚拟线程只解决「排队等待不占资源」的问题**。它能让你用更少的内存支撑更多并发连接，但不会让 GPU 变快。这跟虚拟线程跑数据库 IO 是同一个道理。

### 5.3 限流：必须做，否则 GPU 会雪崩

vLLM 的 `--max-num-seqs` 是硬上限，超出的请求会在队列里等。如果上游不限流，用户会看到「请求发出去了但 60 秒没响应」。

在 Java 侧用信号量做准入控制：

```java
private final Semaphore permits = new Semaphore(32);

public String chatWithLimit(String prompt) throws Exception {
    if (!permits.tryAcquire(3, TimeUnit.SECONDS)) {
        throw new RejectedExecutionException("LLM 服务繁忙，请稍后重试");
    }
    try {
        return chat(prompt);
    } finally {
        permits.release();
    }
}
```

信号量大小 ≈ `--max-num-seqs`，或者略小一点，留出系统请求的余量。

### 5.4 模型加载与预热

冷启动是真痛点。7B 模型首次加载 + CUDA 初始化要 10~30 秒。做法：

1. 容器启动后跑一次 `health check` 请求（`"hi"`，`max_tokens=1`）；
2. K8s 的 `readinessProbe` 指向 `/v1/models`，它只检查服务是否就绪，不保证模型已加载；
3. 更稳的做法是自定义一个 `/warmup` 端点，内部真的发一次推理。

### 5.5 上下文长度与成本

本地部署虽然不按 token 计费，但**上下文长度直接决定显存和延迟**：

- 输入 8K vs 2K，Prefill 阶段耗时差 4 倍；
- KV Cache 线性增长，并发数会被迫下降。

所以「把整个知识库塞进 prompt」在本地部署里是自杀式做法，该用 RAG 还是得用 RAG。

### 5.6 监控指标

vLLM 暴露 Prometheus 指标（`/metrics`），必须盯这几个：

| 指标 | 含义 | 告警阈值 |
|---|---|---|
| `vllm:num_requests_waiting` | 排队请求数 | 持续 > 10 说明容量不足 |
| `vllm:gpu_cache_usage_perc` | KV Cache 使用率 | > 0.9 会开始抢占/驱逐 |
| `vllm:time_to_first_token_seconds` | TTFT | P99 > 5s 需排查 |
| `vllm:avg_generation_throughput_toks_per_s` | 生成吞吐 | 突然下降说明 GPU 争抢 |

---

## 六、五个真实踩坑

### 坑 1：Ollama 默认只监听 127.0.0.1

容器化部署时，Java 服务在另一个容器，连不上。必须设 `OLLAMA_HOST=0.0.0.0:11434`。

### 坑 2：vLLM 启动报 `No available memory for the cache blocks`

`--gpu-memory-utilization` 设太高（0.95+），或者 `--max-model-len` 设太大，导致权重加载后没有空间给 KV Cache。降到 0.9 并缩短上下文。

### 坑 3：流式响应被 Nginx 缓冲

Nginx 默认 `proxy_buffering on`，会把 SSE 数据攒着一起发，用户看到的是「等 30 秒然后一次性出现」。

```nginx
location /v1/ {
    proxy_pass http://vllm:8000;
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header Connection '';
    proxy_http_version 1.1;
    chunked_transfer_encoding off;
    proxy_read_timeout 300s;
}
```

### 坑 4：`temperature=0` 仍然不完全确定

由于浮点运算的并行归约顺序不固定，GPU 上的推理即使 `temperature=0` 也可能有微小差异。需要严格可复现时，只能固定 `seed` 并接受「近似确定性」。

### 坑 5：中文乱码 / 截断

Ollama 的 `num_ctx` 默认是 2048（老版本），超长输入会被**静默截断**，表现为「模型好像没看到后面的内容」。必须显式设置：

```bash
ollama run qwen2.5:7b --parameter num_ctx 8192
```

或在 API 请求里传 `options: {"num_ctx": 8192}`。

---

## 七、面试追问

**Q1：Ollama 和 vLLM 的本质区别是什么？**

Ollama 基于 llama.cpp，核心是「让模型能在消费级硬件上跑起来」，优化方向是量化、CPU/GPU 混合推理、易用性；vLLM 是基于 PyTorch 的生产级推理引擎，核心是 PagedAttention + Continuous Batching，优化方向是高并发下的吞吐和显存利用率。一个是「能跑」，一个是「跑得多」。

**Q2：PagedAttention 解决了什么问题？**

传统推理要为每个请求预留「最大上下文长度」的连续 KV Cache 空间，造成大量内部碎片（实际用 2K，预留 8K，浪费 75%）。PagedAttention 把 KV Cache 切成固定大小的 block，按需分配、非连续存储，用页表映射，显存浪费降到 4% 以下，从而能支撑更大的 batch。

**Q3：为什么本地部署也要做限流？**

因为 GPU 是独占资源，并发超过 `max-num-seqs` 后请求只会排队，延迟线性上升。不做准入控制的话，一个突发流量会让所有请求都超时，表现为「服务完全不可用」。限流的目的是「快速失败」而不是「全部拖死」。

**Q4：Java 接本地模型，最大的工程挑战是什么？**

不是调用本身（协议已标准化），而是：① 超时与重试策略（LLM 不是幂等的，重试可能重复计费/重复副作用）；② 流式响应的连接管理（SSE 长连接容易泄漏）；③ 并发与背压（GPU 容量有限，必须有队列和降级）；④ 可观测性（token 数、TTFT、首包失败率）。

**Q5：什么情况下不应该自建？**

并发低（< 1 QPS）、模型能力要求高（需要 GPT-4 级别）、团队没有 GPU 运维能力——这三种情况自建的综合成本远高于调用 API。自建的临界点通常在「月调用量超过 500 万次」或「数据合规硬要求」。

---

## 八、总结

Java 工程师做本地大模型落地，路径其实很清晰：

1. **协议层已经统一**，认准 OpenAI 兼容接口，Java 侧用 Spring AI 一套代码通吃 Ollama / vLLM / 云端。
2. **引擎选型看并发**：开发用 Ollama，生产并发用 vLLM，别用 Ollama 硬扛生产。
3. **显存先算再买**，权重 + KV Cache + 激活值，量化能省 4 倍但要接受精度损失。
4. **超时、限流、预热、监控**四件事必须做，否则生产必翻车。
5. **虚拟线程适合 LLM IO**，但记住它优化的是「等待」不是「算力」。

把这套跑通，你就具备了「在企业内网交付一个可用 AI 应用」的完整能力——这正是当前 Java 转型 AI 应用开发最值钱的那块拼图。
