---
title: 【AI 体系】KV Cache 与 PagedAttention 深度解析：显存账、分页调度与并发容量规划
date: 2026-11-14 08:50:00
tags:
  - AI
  - LLM
  - 推理优化
  - vLLM
  - 显存
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】KV Cache 与 PagedAttention 深度解析

## 前言

很多人算「一台机器能扛多少并发」时，算法是：

```
显存 80G - 模型权重 16G = 64G 可用
每个请求上下文 8k，好像能跑很多个？
```

然后上线发现并发到 20 就开始排队、OOM、请求被拒。

问题出在：**大模型推理的显存大头不是权重，而是 KV Cache**。它跟「上下文长度 × 并发数」线性相关，而这两者都是业务侧不断往上加的参数。

这篇把 KV Cache 的显存账、PagedAttention 的分页思想、prefix caching 的工程价值讲清楚，最后给一套 Java 侧可用的容量规划模型和准入控制代码。

---

## 一、为什么 decode 阶段是 memory-bound

Transformer 推理分两段：

| 阶段 | 计算 | 瓶颈 | 指标 |
|---|---|---|---|
| Prefill | 一次性处理整个 prompt，矩阵乘 | 算力（compute-bound） | TTFT（首 token 延迟） |
| Decode | 逐 token 生成，每步一个矩阵乘 | **显存带宽（memory-bound）** | TPOT（每 token 延迟） |

Decode 每一步都要把模型权重从 HBM 读一遍（8B 模型 fp16 = 16GB），但只做一次「1×d @ d×d」的乘法——算力利用率极低。所以 decode 的速度基本由显存带宽决定：

```
TPOT ≈ 模型权重字节数 / 显存带宽
```

A100 80G 带宽 2TB/s，8B fp16 权重 16GB → 理论 8ms/token。这也是为什么量化（fp8/int4）能直接提速——权重变小，读得就快。

而 **KV Cache 占的是显存容量，不是带宽**。它决定了「同时能装下多少个请求」，也就是并发上限。

---

## 二、KV Cache 显存公式

每个 token 的 KV Cache 大小：

```
bytes_per_token = 2 × n_layers × n_kv_heads × head_dim × bytes_per_elem
                  ↑ K 和 V 各一份
```

以 Llama-3-8B 为例（32 层、GQA 8 个 KV 头、head_dim 128、fp16）：

```
2 × 32 × 8 × 128 × 2 = 131,072 B = 128 KB / token
```

于是：

| 上下文长度 | 单请求 KV Cache | 32 并发 |
|---|---|---|
| 2k | 256 MB | 8 GB |
| 8k | 1 GB | 32 GB |
| 32k | 4 GB | 128 GB（爆） |
| 128k | 16 GB | 512 GB（想都别想） |

对比 MHA（32 个 KV 头，不共享）：

```
2 × 32 × 32 × 128 × 2 = 512 KB / token   → 8k 上下文 4 GB/请求
```

**GQA/MQA 的价值就在这里**：KV 头从 32 降到 8，KV Cache 直接降到 1/4。这也是为什么现在的开源模型几乎都用 GQA。

### 2.1 完整的显存预算表

| 组成 | 8B 模型（A100 80G） | 说明 |
|---|---|---|
| 模型权重 | 16 GB（fp16） | 固定 |
| 激活值 / 临时 buffer | 2~4 GB | 与 batch、序列长度相关 |
| CUDA context / 碎片 | 2~3 GB | 固定开销 |
| **KV Cache 可用** | **~55 GB** | 剩下的才是并发空间 |

按 8k 上下文、128 KB/token：

```
55 GB / 1 GB ≈ 55 并发
```

这就是真实答案：**80G 卡跑 8B 模型、8k 上下文，并发 50 左右**，不是几百。

---

## 三、朴素 KV Cache 的三个浪费

如果实现方式是「按 `max_seq_len` 预分配连续显存」：

```python
# 伪代码：每个请求预分配 max_len 的 KV 空间
kv = torch.empty(batch, 2, layers, kv_heads, max_len, head_dim)
```

会有三类浪费：

| 浪费类型 | 成因 | 量级 |
|---|---|---|
| **内部碎片**（reserved > used） | 预分配 max_len，实际只用了 200 token | 极大，常见 60%~80% |
| **外部碎片** | 不同长度请求反复分配/释放，留下空洞 | 中 |
| **无法共享** | 相同前缀（system prompt）也不能复用 | 中~大 |

vLLM 的论文里给的数据是：朴素方案只有 **20%~40%** 的 KV 显存真正存了有效 token，其余全是浪费。

---

## 四、PagedAttention：把虚拟内存思想搬到显存

核心思想一句话：**KV Cache 不连续分配，切成固定大小的 block，用 block table 做映射。**

```
逻辑序列（请求视角）:
  block 0      block 1      block 2
  [t0..t15]    [t16..t31]   [t32..t40]

block table（每个请求一张）:
  logical 0 → physical 7
  logical 1 → physical 2
  logical 2 → physical 19

物理显存池:
  [0][1][2: t16..t31][3]...[7: t0..t15]...[19: t32..t40]
```

好处：

1. **内部碎片只剩最后一个 block**（block=16 token，最多浪费 15 个 token 的空间）；
2. **无外部碎片**：所有 block 等大，分配器就是空闲链表；
3. **可共享**：相同前缀的请求指向同一批物理 block，引用计数 + copy-on-write。

vLLM 实测：显存浪费从 60%~80% 降到 **4% 以下**，吞吐提升 2~4 倍。

### 4.1 Copy-on-Write：并行采样和 beam search 的救星

```
请求 A: system prompt (block 0,1) + user question (block 2)
请求 B: 同一 system prompt，不同 question → 共享 block 0,1

采样出 3 个候选（n=3）:
  三个分支共享 prompt 的 block，
  只有新生成的 token 需要各自分配新 block
```

没有 CoW 时，3 个候选要复制 3 份 prompt 的 KV；有了 CoW，只多出生成部分的 block。论文里 beam search 场景节省 **55%** 显存。

### 4.2 调度：continuous batching + chunked prefill

PagedAttention 只是「存储层」，真正让吞吐起飞的是「调度层」：

| 技术 | 作用 |
|---|---|
| Continuous batching | 请求完成即退出 batch，新请求立刻加入，不等整批结束 |
| Chunked prefill | 长 prompt 切成多块，和 decode 混跑，避免长请求阻塞短请求 |
| Preemption | 显存不够时，抢占低优先级请求（swap 到 CPU 或直接丢弃重算） |

一个常见现象：**P99 TTFT 抖动**，往往是长 prompt 的 prefill 把 decode 挤住了。开 chunked prefill，把 prefill 切小，能让 TPOT 稳定，代价是长请求 TTFT 略升。

---

## 五、Prefix Caching：多轮对话的免费加速

如果两个请求的前缀完全相同（同一个 system prompt、同一段 RAG 上下文），它们的 KV 可以完全复用。

```
请求 1: [system 2000 token][user Q1]
请求 2: [system 2000 token][user Q2]
         └── 这 2000 token 的 KV 可复用
```

收益：

- **TTFT 大幅下降**：省掉 2000 token 的 prefill；
- **显存更省**：共享 block。

工程要点：

1. **前缀必须完全一致**（逐 token 相同）。差一个空格、差一个时间戳，缓存就失效。
2. **静态内容放前面**：system prompt、工具定义、few-shot 示例放最前，用户输入放最后。
3. **路由亲和**：多副本部署时，同一会话要打到同一副本才能命中缓存（一致性哈希 / session affinity）。
4. **安全隔离**：缓存不能跨租户共享，否则可能通过「前缀命中时间差」推断其他租户的内容。生产上按 tenant id 做命名空间。
5. **TTL 与淘汰**：LRU 为主，注意长尾租户把缓存挤掉。

### 5.1 与云 API 的 prompt caching 对应

| 维度 | 自建（vLLM/SGLang） | 云 API |
|---|---|---|
| 命中条件 | 前缀 token 完全一致 | 通常有最小 token 数（如 1024） |
| 计费 | 省算力 | 缓存写入贵、命中读便宜 |
| TTL | 自己定 | 通常 5~60 分钟 |
| 控制粒度 | block 级 | 请求级 |

云 API 的「缓存写入」是有成本的，所以**只在同一前缀会被复用多次时才值得**。一次性请求加 cache 标记反而更贵。

---

## 六、KV Cache 量化：再省一半

| 精度 | 每 token | 相对 fp16 | 质量影响 |
|---|---|---|---|
| FP16 | 128 KB | 1x | 基线 |
| FP8 | 64 KB | 0.5x | 很小 |
| INT8 | 64 KB | 0.5x | 小（需 per-channel scale） |
| INT4 | 32 KB | 0.25x | 明显，长上下文更敏感 |

注意：**KV 量化和权重量化是两件事**。权重 INT4 + KV FP16 很常见；KV 也压到 INT4 时，长上下文的任务（如多跳推理）质量下降会更明显。上线前按任务类型分别评测。

---

## 七、Java 侧：容量规划与准入控制

Java 应用通常不直接跑推理（推理服务是 Python/C++），但**必须为自己的调用做容量规划**，否则上游一限流，业务就是一片超时。

### 7.1 一个容量计算器

```java
public record ModelSpec(
        int layers,
        int kvHeads,
        int headDim,
        int bytesPerElem,   // fp16=2, fp8=1
        long weightBytes
) {
    /** 每 token KV Cache 字节数 */
    public long kvBytesPerToken() {
        return 2L * layers * kvHeads * headDim * bytesPerElem;
    }
}

public record Capacity(
        int maxConcurrency,
        int recommendedConcurrency,
        double kvUtilization
) {}

public final class KvCapacityPlanner {

    /**
     * @param gpuMemBytes   单卡显存（如 80GB）
     * @param reservedBytes 激活值 + CUDA context + 碎片预留
     * @param ctxTokens     业务约定的最大上下文
     * @param safetyFactor  安全系数（建议 0.8）
     */
    public static Capacity plan(ModelSpec spec, long gpuMemBytes, long reservedBytes,
                                int ctxTokens, double safetyFactor) {
        long kvBudget = (long) ((gpuMemBytes - spec.weightBytes() - reservedBytes) * safetyFactor);
        if (kvBudget <= 0) throw new IllegalStateException("显存不足以容纳模型");

        long perReq = spec.kvBytesPerToken() * ctxTokens;
        int max = (int) (kvBudget / perReq);

        return new Capacity(
                max,
                Math.max(1, (int) (max * 0.8)),   // 留 20% 余量给突发
                (double) perReq * max / kvBudget
        );
    }

    public static void main(String[] args) {
        // Llama-3-8B, 80GB, 8k 上下文
        ModelSpec llama3_8b = new ModelSpec(32, 8, 128, 2, 16L << 30);
        Capacity c = plan(llama3_8b, 80L << 30, 6L << 30, 8192, 0.85);
        System.out.printf("max=%d, recommended=%d, util=%.2f%n",
                c.maxConcurrency(), c.recommendedConcurrency(), c.kvUtilization());
        // 输出：max=46, recommended=36, util=1.00（kvBudget 已乘安全系数）
    }
}
```

这段代码可以直接放进配置中心，按「模型 + 卡型 + 上下文」自动算出每个副本的并发上限，避免拍脑袋。

### 7.2 准入控制：用信号量而不是线程池

推理服务的瓶颈是 KV 显存，不是 Java 线程。所以限流要按「在途 token 预算」而不是「请求数」：

```java
@Component
public class LlmAdmissionController {

    private final Semaphore slots;
    private final int maxTokensPerRequest;
    private final AtomicLong inflightTokens = new AtomicLong();

    public LlmAdmissionController(LlmCapacityProperties props) {
        this.slots = new Semaphore(props.getRecommendedConcurrency(), true);
        this.maxTokensPerRequest = props.getMaxContextTokens();
    }

    public <T> T call(long estimatedTokens, Supplier<T> task) {
        if (estimatedTokens > maxTokensPerRequest) {
            throw new IllegalArgumentException("prompt 超出上下文预算: " + estimatedTokens);
        }
        if (!slots.tryAcquire()) {
            throw new RejectedExecutionException("推理并发已满，请稍后重试");
        }
        try {
            inflightTokens.addAndGet(estimatedTokens);
            return task.get();
        } finally {
            inflightTokens.addAndGet(-estimatedTokens);
            slots.release();
        }
    }

    /** 给监控用：当前在途 token 占预算比例 */
    public double pressure() {
        return (double) inflightTokens.get() / ((long) slots.availablePermits() + inflightTokens.get());
    }
}
```

更精细的做法是按 tenant 分配配额（比如大客户 40%、普通 60%），避免一个大客户把并发吃光。

### 7.3 必须观测的五个指标

| 指标 | 含义 | 告警阈值参考 |
|---|---|---|
| `TTFT` P95 | 首 token 延迟 | > 2s |
| `TPOT` P95 | 每 token 延迟 | > 80ms（流式体验） |
| `queue_depth` | 排队请求数 | 持续 > 并发上限的 20% |
| `kv_cache_hit_rate` | prefix 命中率 | 多轮场景 < 50% 要查 |
| `preempted_requests` | 被抢占数 | 持续 > 0 说明显存不足 |

推理服务（vLLM）暴露 `/metrics`，Java 侧用 Micrometer 抓取后统一告警即可。

---

## 八、自建 vs 云 API：一张决策表

| 维度 | 自建推理（vLLM/SGLang） | 云 API |
|---|---|---|
| 固定成本 | GPU 租金（高） | 0 |
| 边际成本 | 低（跑满时） | 高（按 token） |
| 冷启动 | 模型加载几十秒~分钟 | 无 |
| 并发弹性 | 受显存限制，扩副本慢 | 秒级 |
| 数据合规 | 数据不出域 | 需评估 |
| 运维 | 重（驱动/版本/调度） | 轻 |
| 适合 | 高频、稳定流量、敏感数据 | 波峰波谷、试错期、低频 |

经验分界线：**日均 token 消耗 × API 单价 > GPU 月租的 1.5 倍**时，自建开始划算；但还要算上人力成本。

---

## 九、踩坑清单

1. **按「请求数」估并发** → 忽略上下文长度，实际并发只有估算的 1/5。
2. **不限制 `max_tokens`** → 单个请求生成 4000 token，KV 一直占着，把别人挤掉。
3. **system prompt 里带时间戳** → prefix cache 永远不命中。
4. **多副本无会话亲和** → 多轮对话每次打到不同副本，缓存全失效。
5. **长 prompt 不切 chunked prefill** → 一个 30k 的请求把 TPOT 拉到几百毫秒。
6. **KV 量化压到 INT4 却不评测** → 长上下文任务质量断崖。
7. **把 swap 当万能** → 抢占到 CPU 的 KV 回传要走 PCIe，延迟爆炸，不如直接重算。
8. **忽略 CUDA context 和碎片** → 算出来 60 并发，实际 45 就 OOM。
9. **多租户共享 prefix cache** → 安全隔离问题（侧信道）。
10. **只看平均延迟** → P99 早炸了，平均值还很好看。

---

## 十、面试追问

**Q1：KV Cache 存的是什么？为什么需要它？**
A：存的是每层注意力的 Key 和 Value 向量。自回归生成时，历史 token 的 K/V 不会变，缓存起来避免每步重算，把 decode 的复杂度从 O(n²) 降到 O(n)。

**Q2：为什么说 decode 是 memory-bound？**
A：每生成一个 token 要把全部权重读一遍，但只做一次极小的矩阵乘，算力利用率低，速度由显存带宽决定。

**Q3：PagedAttention 解决了什么问题？**
A：朴素预分配导致严重的内部/外部碎片且无法共享。PagedAttention 用固定大小 block + block table 做非连续分配，浪费降到 4% 以下，并支持 CoW 共享。

**Q4：prefix caching 在什么情况下无效？**
A：前缀不完全一致（时间戳、随机 id、动态内容在前）、多副本无亲和路由、前缀太短低于服务商最小缓存长度、缓存已被淘汰。

**Q5：GQA 为什么能省显存？**
A：多个 query 头共享同一组 KV 头，KV 头数从 32 降到 8，KV Cache 直接降到 1/4，同时质量损失很小。

**Q6：显存不够时，抢占（preemption）怎么做？**
A：两种：swap（把 KV 换到 CPU 内存，恢复时换回）和 recompute（丢弃 KV，恢复时重新 prefill）。swap 受 PCIe 带宽限制，recompute 受算力限制，通常按序列长度选择。

**Q7：怎么估算一台机器的并发？**
A：`(显存 - 权重 - 激活/上下文开销) × 安全系数 / (每 token KV × 最大上下文)`。8B 模型 80G 卡、8k 上下文大致 40~55 并发。

---

## 总结

KV Cache 是大模型推理里最容易被低估的成本项：它不参与计算，却决定了并发上限；它随上下文线性增长，而业务永远在要求更长的上下文。

PagedAttention 的价值不只是「省显存」，更是把操作系统的虚拟内存思想引入了推理调度——有了分页，才有 continuous batching、prefix caching、CoW 共享这些上层优化。

对 Java 工程师来说，不需要自己实现调度器，但**必须会算这笔账**：算清楚一个副本能扛多少并发、一个租户该分多少配额、什么时候该自建什么时候该用 API。这些判断，比会调 vLLM 参数更值钱。

---

> 本日 5 篇（3 Java + 2 AI）到此结束：
> 1. MySQL InnoDB TDE 表空间加密
> 2. overlayfs 容器写放大
> 3. ProxySQL / MySQL Router 数据库代理层
> 4. ColBERT late interaction 检索
> 5. KV Cache 与 PagedAttention
