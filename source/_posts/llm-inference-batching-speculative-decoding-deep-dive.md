---
title: 【AI 体系】推理服务批调度与投机解码深度解析：吞吐、TTFT 与加速比的真实账本
date: 2026-11-07 08:00:00
tags:
  - AI
  - 推理优化
  - 投机解码
  - 连续批处理
  - 系统设计
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】推理服务批调度与投机解码深度解析：吞吐、TTFT 与加速比的真实账本

## 前言：为什么同一张卡，别人吞吐是你的 5 倍

自建推理服务的第一课，通常是这样的对比：

- 你用 HuggingFace `model.generate()` 起一个 HTTP 服务，单卡 A100 跑 7B 模型，**每秒 8 个请求**；
- 隔壁用 vLLM 起同一个模型，**每秒 40 个请求**。

硬件一样、模型一样、精度一样。差别几乎全部来自两件事：**批调度（batching / scheduling）** 和 **解码优化（speculative decoding）**。

很多人对这两个词的理解停留在"vLLM 快""投机解码能加速 2 倍"。但真到做容量规划、SLA 设计、成本核算的时候，你需要知道：**为什么快、快多少、在什么条件下不快**。这篇就从推理的物理约束讲起。

## 一、先理解推理的两个阶段

LLM 推理分两段，特性完全相反：

| 阶段 | 计算形态 | 瓶颈 | 关键指标 |
|---|---|---|---|
| Prefill（预填充） | 一次处理整个 prompt，矩阵乘 | **算力密集** | TTFT（首 token 延迟） |
| Decode（解码） | 每步生成 1 个 token，矩阵-向量乘 | **显存带宽密集** | TPOT / ITL（token 间隔） |

这个不对称是整个优化的根源：

- Decode 阶段 GPU 算力利用率通常只有 **5%~15%**，绝大部分时间在等显存把权重搬进来；
- 所以 **batch 越大，decode 越划算**——同一份权重可以服务 N 个请求，边际成本极低；
- 但 prefill 是算力密集的，把它和 decode 混在一起会拖慢 decode 的节奏。

**连续批处理（continuous batching）** 就是用来吃满这个空隙的：不等整个 batch 里最慢的请求结束，而是**每生成一个 token 就重新调度一次**——完成的请求立刻退出，排队的请求立刻补进来。

```
静态批处理：
[req1 ████████████████]
[req2 ███████         ]  ← 等 req1 结束，GPU 空转
[req3 ███             ]

连续批处理：
[req1 ████████████████]
[req2 ███████][req4 █████████]
[req3 ███][req5 █████████████]
```

Orca（OSDI'22）提出 iteration-level scheduling 后，这套做法成了所有推理框架的标配：vLLM、TensorRT-LLM、SGLang、TGI 都是连续批处理。

## 二、KV Cache：真正的显存大头

### 2.1 账怎么算

以 Llama-3-8B 为例（32 层，8 个 KV head，head_dim 128，fp16）：

```
每 token 每层的 KV = 2（K 和 V） × 8 × 128 × 2B = 4KB
每 token 全模型   = 4KB × 32 层 = 128KB
32k 上下文        = 128KB × 32768 ≈ 4GB
```

**一个 32k 上下文的请求就要 4GB KV Cache。** 一张 80G 的 A100，权重占 16G，剩下 60G 看似能放 15 个并发——实际上因为碎片和预留，往往只能放 8~10 个。

传统做法是**预分配最大长度**：每个请求按 `max_model_len` 预留，一个只要 200 token 的请求也占 4GB。这就是"显存利用率 30%"的来源。

### 2.2 PagedAttention

vLLM 的核心创新：把 KV Cache 切成分页的 block（默认 16 个 token 一块），用**页表**把逻辑位置映射到物理 block，按需分配。

- 碎片从"外部碎片"变成"内部碎片"，后者上限是一个 block（16 token）；
- 相同前缀的请求可以**共享 block**（copy-on-write），这就是 prefix caching 的基础；
- 显存利用率从 30% 提到 90%+，等价于并发数翻 2~3 倍。

Prefix caching 对 Agent 场景收益极大：同一个 system prompt、同一份 RAG 上下文，在多次调用间完全复用，**TTFT 能降 40%~70%**。

## 三、调度器的三个旋钮

vLLM 里最影响性能的三个参数：

```bash
vllm serve meta-llama/Llama-3.1-8B-Instruct \
  --max-num-seqs 256 \              # 同时在跑的请求数上限
  --max-num-batched-tokens 8192 \   # 单次迭代的 token 预算
  --enable-chunked-prefill \        # 长 prompt 切片，避免饿死 decode
  --gpu-memory-utilization 0.90 \
  --enable-prefix-caching
```

**`max-num-seqs`**：并发上限。调大能提吞吐，但 KV Cache 不够时会触发抢占（preemption），被抢占的请求要重算，反而更慢。经验值：先用 `KV 可用显存 / 单请求平均 KV` 估一个上限，再从 0.7 倍开始压测。

**`max-num-batched-tokens`**：一次迭代处理多少 token。太小则 GPU 吃不饱，太大则长 prompt 会阻塞 decode，TPOT 抖动。8k~16k 是常见甜点。

**chunked prefill**：把 32k 的 prompt 切成 2k 一片，和多路 decode 混跑。代价是 TTFT 略微上升，收益是 TPOT 稳定——**对聊天类应用，TPOT 稳定比 TTFT 快 200ms 更重要**，因为用户感知的是"字打得顺不顺"。

## 四、投机解码：用小模型给大模型"打草稿"

### 4.1 基本思路

Decode 阶段是带宽瓶颈，GPU 算力闲着。投机解码的想法很直接：

1. 用一个小而快的 **draft 模型**，连续猜 γ 个 token；
2. 用**目标模型**一次性并行验证这 γ 个 token；
3. 从头开始，保留连续正确的部分，第一个错的位置由目标模型重新采样。

关键在于：**验证是并行的**，一次前向就能验 γ 个位置，成本约等于生成 1 个 token。所以只要猜对得多，就赚了。

### 4.2 加速比怎么算

设 draft 的接受率为 α，草稿长度 γ，draft 单步成本是 target 的 c 倍（c 通常 0.02~0.1），则：

```
每轮期望接受 token 数：E = (1 - α^(γ+1)) / (1 - α)
每轮成本：1 + γ·c
加速比 ≈ E / (1 + γ·c)
```

代入 α=0.8、γ=4、c=0.05：

```
E = (1 - 0.8^5) / 0.2 = (1 - 0.328) / 0.2 = 3.36
加速比 = 3.36 / 1.2 ≈ 2.8x
```

代入 α=0.5、γ=4、c=0.05：

```
E = (1 - 0.5^5)/0.5 = 1.94
加速比 = 1.94/1.2 ≈ 1.6x
```

再代入 α=0.3：

```
E = (1 - 0.3^5)/0.7 = 1.42
加速比 = 1.42/1.2 ≈ 1.18x
```

**结论：α 低于 0.5 时，投机解码基本白忙。** 而 α 高度依赖任务：

| 任务类型 | 典型 α | 是否值得 |
|---|---|---|
| 代码补全 / 格式化输出 | 0.8~0.9 | 非常值得 |
| 摘要 / 翻译 | 0.7~0.8 | 值得 |
| RAG 问答（有明确上下文） | 0.6~0.75 | 值得 |
| 开放式创作 | 0.4~0.6 | 边际 |
| 数学推理 / 长链 CoT | 0.3~0.5 | 往往不值得 |

原因很直观：**输出越"可预测"，草稿越容易猜对**。代码和摘要高度模式化；而推理链每一步都在引入新信息，draft 模型跟不上。

### 4.3 主流方案对比

| 方案 | 草稿来源 | 额外显存 | 典型加速 | 落地难度 |
|---|---|---|---|---|
| Draft-target（双模型） | 独立小模型 | +1 个模型 | 1.8~2.5x | 低 |
| Medusa | 目标模型 + 多个预测头 | 很小 | 2.0~2.8x | 中 |
| EAGLE / EAGLE-2 | 特征层 + 自回归头 | 小 | 2.5~3.5x | 中高 |
| Lookahead / n-gram | 检索历史或 prompt 中的 n-gram | 0 | 1.3~2.0x | 低 |
| Self-speculative | 目标模型跳层 | 0 | 1.5~2.0x | 中 |

**n-gram lookahead** 特别适合 RAG 和代码场景：草稿直接从"输入上下文里出现过的片段"里取，不需要额外模型，对"复制粘贴型"输出（比如把文档里的字段抽出来）命中率极高。

### 4.4 正确性：不是"近似"

很多人担心投机解码会改变输出分布。**标准的 speculative sampling 是严格等价的**：

- 对每个位置，draft 采样出 token `x`，概率 `q(x)`；target 概率 `p(x)`；
- 以 `min(1, p(x)/q(x))` 的概率接受；
- 拒绝时，从归一化的 `max(0, p(x) - q(x))` 分布重新采样。

数学上可以证明，最终采样分布恰好是 `p`。所以**投机解码只影响速度，不影响质量**（随机种子相同的情况下，分布一致，但具体输出序列可能不同）。

工程上要注意：**验证时必须用 target 的 logits，且要处理 batch 内不同请求的接受长度不一致**。这也是各家实现差异最大的地方。

## 五、Java 侧怎么用起来

### 5.1 客户端：OpenAI 兼容协议

vLLM/SGLang/TGI 都提供 OpenAI 兼容接口，Spring AI 可以直接接：

```java
@Bean
OpenAiApi vllmApi() {
    return OpenAiApi.builder()
        .baseUrl("http://vllm-internal:8000")
        .apiKey("EMPTY")
        .build();
}

@Bean
ChatModel chatModel(OpenAiApi api) {
    return new OpenAiChatModel(api, OpenAiChatOptions.builder()
        .model("llama-3.1-8b-instruct")
        .temperature(0.2)
        .maxTokens(1024)
        .build());
}
```

### 5.2 关键：把 TTFT 和 TPOT 分开度量

流式接口下，用 `ChatClient.stream()` 拿到每个 chunk 的时间戳：

```java
public CompletionMetrics stream(String prompt) {
    long start = System.nanoTime();
    AtomicLong firstToken = new AtomicLong(-1);
    AtomicInteger tokens = new AtomicInteger();

    chatClient.prompt().user(prompt).stream().content()
        .doOnNext(chunk -> {
            firstToken.compareAndSet(-1, System.nanoTime());
            tokens.incrementAndGet();
        })
        .blockLast();

    long ttftMs = (firstToken.get() - start) / 1_000_000;
    long totalMs = (System.nanoTime() - start) / 1_000_000;
    double tpotMs = tokens.get() > 1
        ? (totalMs - ttftMs) / (double) (tokens.get() - 1) : 0;

    return new CompletionMetrics(ttftMs, tpotMs, tokens.get());
}
```

这两个指标要**分别设 SLO**：聊天场景 TTFT < 800ms、TPOT < 50ms；批处理场景只看总吞吐。

### 5.3 路由：什么时候该走自建，什么时候走 API

```java
public ModelRoute decide(RequestMeta meta) {
    // 长 prompt + 高并发 → 自建（prefix cache 收益大）
    if (meta.promptTokens() > 8000 && meta.concurrency() > 20) {
        return ModelRoute.SELF_HOSTED;
    }
    // 突发流量 → 云 API（弹性）
    if (meta.qps() > capacity.qps() * 0.8) {
        return ModelRoute.CLOUD_API;
    }
    // 低延迟敏感 → 云 API（边缘节点更近）
    if (meta.sloTtftMs() < 300) {
        return ModelRoute.CLOUD_API;
    }
    return ModelRoute.SELF_HOSTED;
}
```

一个常被忽略的事实：**自建不等于便宜**。8×A100 的月成本约 3~5 万元（云上），按 40 req/s 跑满，单请求成本才划算；如果你只有 2 req/s，云 API 便宜一个数量级。**投机解码只在自建且算力有富余时才有意义**——它省的是延迟，不是钱。

## 六、容量规划的一个算例

需求：7B 模型，平均输入 1500 token、输出 300 token，目标 30 req/s，P95 TTFT < 1s。

**Step 1：算 KV 需求。**

```
单请求 KV = 1800 token × 128KB/token ≈ 230MB
30 并发（留 3 倍余量 = 90 并发）→ 20.7GB
```

**Step 2：算显存。** 权重 16GB（fp16）+ KV 20.7GB + 激活 4GB ≈ 41GB → **单卡 A100 80G 够用，还有余量开 prefix cache**。

**Step 3：算吞吐。** A100 上 7B 模型 decode 大约 3000~4000 token/s（batch 32）。总输出需求 = 30 × 300 = 9000 token/s → **需要 3 张卡**。

**Step 4：加投机解码。** 若 α=0.7、γ=4，加速比约 2.2x，理论上 1.5 张卡就够。但**必须实测**——真实 α 受 prompt 分布影响，我们见过离线测 0.75、线上只有 0.52 的情况（线上输入更杂）。

## 七、踩坑清单

**坑 1：拿离线 benchmark 的吞吐做容量规划。** 离线用固定长度输入、固定输出，连续批处理能吃满；线上输入长度方差大，长尾请求会拖住整个 batch。**要用真实流量回放。**

**坑 2：`max-num-seqs` 调太大。** 超过 KV 容量后触发抢占，被抢占的请求要重算全部 token，吞吐反而下降。看 `vllm:num_preemptions_total` 指标，非零就要降并发。

**坑 3：投机解码在低 QPS 下无效。** batch=1 时，draft 模型的额外开销全打在延迟上，加速比可能 <1。**投机解码的前提是有 batch 可吃**。

**坑 4：prefix caching 命中率低。** 如果 system prompt 每次都带时间戳、用户 ID，前缀就永远不匹配。**把动态内容放到 prompt 末尾**，静态部分放前面，命中率能从 10% 提到 80%。

**坑 5：忽略 prefill 的算力挤占。** 长 prompt 的 prefill 会占满算力，导致同期 decode 的 TPOT 抖动。开 chunked prefill，或者把长 prompt 请求路由到独立实例。

## 八、面试追问

**Q：连续批处理为什么比静态批处理快？**
A：静态批处理要等 batch 内最长的请求结束，短请求完成后 GPU 空转；连续批处理每个 token 迭代重新调度，完成的请求立刻出队、新请求立刻补入，GPU 利用率从 30% 提到 80%+。

**Q：PagedAttention 解决什么问题？**
A：KV Cache 的显存碎片和预分配浪费。分页 + 页表让 KV 按需分配，内部碎片上限是一个 block，并且支持前缀共享（copy-on-write）。

**Q：投机解码会不会降低质量？**
A：标准 speculative sampling 通过拒绝采样保证输出分布与目标模型完全一致，不影响质量。但如果你用的是"简化版"（比如直接接受 draft 结果不验证），那就会降质。

**Q：什么场景不该用投机解码？**
A：batch 很小（<4）、输出高度开放（创意写作、长链推理）、或者 draft 模型和目标模型分布差异大（α < 0.5）。这些情况下额外开销大于收益。

**Q：TTFT 和 TPOT 哪个更难优化？**
A：TTFT 主要由 prefill 决定，靠 prefix cache、chunked prefill、更快的 attention 内核优化；TPOT 由 decode 的带宽效率决定，靠更大 batch、量化、投机解码。两者会互相挤占算力，必须一起看。

## 结语

推理优化的本质，是在**算力、带宽、显存**三个约束下做调度。连续批处理解决"算力闲置"，PagedAttention 解决"显存浪费"，投机解码解决"带宽瓶颈"——每一个都有明确的适用边界。

下次有人跟你说"上了 vLLM 快 5 倍"，你可以追问一句：**在什么输入长度分布、什么并发、什么 α 下？** 答案往往就没那么乐观了。
