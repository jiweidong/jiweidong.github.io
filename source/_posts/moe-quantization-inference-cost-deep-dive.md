---
title: 【AI 体系】MoE 与量化深度解析：大模型推理成本到底花在哪
date: 2026-11-03 08:20:00
tags:
  - AI
  - MoE
  - 量化
  - 推理优化
  - 成本治理
  - LLM
categories:
  - AI 工程
author: 东哥
---

# 【AI 体系】MoE 与量化深度解析：推理成本到底花在哪

## 前言

2026 年做大模型应用，你会发现一个奇怪的现象：

- API 价格一年降了 10 倍，但你的账单反而涨了——因为用量涨了 30 倍
- 同一个「70B」模型，不同厂商价格差 5 倍，质量看起来差不多
- 自己部署开源模型，24G 显存的卡跑不起来 32B，但厂商说他们「用 8 卡跑 671B」

这些现象背后是两件事：**MoE（混合专家）改变了「参数量 ≈ 成本」的等式**，**量化改变了「精度 ≈ 显存」的等式**。

不理解这两件事，你在做技术选型和成本核算时会一直算错。这篇文章从原理讲到工程决策，最后给一套 Java 侧的「精度档位灰度 + 质量门禁」落地代码。

---

## 一、先把成本公式写对

### 1.1 三个不同的「参数量」

这是最容易搞混的地方：

| 概念 | 含义 | 决定什么 |
|---|---|---|
| **总参数量**（Total Params） | 所有权重之和 | **显存占用**（权重部分） |
| **激活参数量**（Active Params） | 单次前向实际参与计算的参数 | **单 token 计算量（FLOPs）** |
| **KV Cache** | 推理时缓存的 K/V | 长上下文下的**显存爆炸源** |

举例（典型 MoE 配置）：

```
总参数 671B，激活 37B，64 个专家，top-2 路由
```

含义：模型文件要装 671B 个参数（显存），但每生成一个 token 只算 37B（算力）。**显存按总参数算，算力按激活参数算。** 这就是「8 卡能跑 671B」的原理，也是「为什么 MoE 便宜」的原理。

### 1.2 显存账

```
权重显存 = 总参数 × 每参数字节数
KV Cache = 2 × 层数 × 头数 × head_dim × 序列长度 × batch × 每元素字节数
激活/临时 = 与 batch、序列长度相关（较小但不可忽略）
```

精度对应字节：

| 精度 | 字节/参数 | 7B 模型权重 | 70B 模型权重 | 671B 模型权重 |
|---|---|---|---|---|
| FP32 | 4 | 28 GB | 280 GB | 2.7 TB |
| BF16/FP16 | 2 | 14 GB | 140 GB | 1.3 TB |
| FP8 | 1 | 7 GB | 70 GB | 670 GB |
| INT4（W4A16） | ~0.5 | 3.5 GB | 35 GB | ~335 GB |

⚠️ 注意最后一行：**INT4 的 671B 仍要 335GB**，不是「一张 4090 就能跑」。网上那些「单卡跑 671B」的说法，要么是激活参数口径，要么是极激进量化 + 卸载到内存（慢到不可用）。

### 1.3 算力账（以及为什么 MoE 是访存瓶颈）

```
每 token FLOPs ≈ 2 × 激活参数   （前向，乘加各算一次）
```

但真实推理的瓶颈往往不是 FLOPs，而是**显存带宽**：

```
每生成 1 个 token，要把「用到的权重」从 HBM 读进计算单元一次
耗时 ≈ 权重字节数 / HBM 带宽
```

对 Dense 7B（BF16）：14GB / 2TB/s ≈ **7ms/token**（理论下限）
对 MoE（激活 37B，BF16）：74GB / 2TB/s ≈ **37ms/token**

所以：

> **小 batch 下，推理是「访存受限」（memory-bound），不是「算力受限」（compute-bound）。**

这解释了两件事：

1. **量化能加速**：不是因为算得快，是因为**读得少**（权重字节数减半，带宽压力减半）
2. **MoE 在大 batch 下才划算**：batch 大了，权重读一次可以服务多个请求，摊薄访存成本，而激活参数的算力优势才体现出来

---

## 二、MoE 的结构与代价

### 2.1 基本结构

```
输入 token 的隐状态 h
        │
        ▼
   ┌─────────┐
   │ Router  │  W_gate: [d_model, n_experts]
   └────┬────┘
        │ softmax → 每个专家的权重
        ▼
   top-k 选择（通常 k=2，从 8/64/128 个专家里选）
        │
   ┌────┴────┬─────────┐
   ▼         ▼         ▼
Expert_3  Expert_17  (其余不激活)
   │         │
   └────┬────┘
        ▼
  加权求和 → 输出
```

关键设计点：

| 设计 | 常见选择 | 影响 |
|---|---|---|
| 专家数量 | 8 / 16 / 64 / 128 / 256 | 越多容量越大，通信越贵 |
| top-k | 1 / 2 / 4 | 越大质量越好，算力越高 |
| 专家粒度 | 粗粒度（整个 FFN）/ 细粒度（FFN 拆小份） | 细粒度路由更灵活 |
| 共享专家 | DeepSeekMoE 的 shared expert | 保证通用能力不被路由抖动影响 |
| 路由方式 | token-choice / expert-choice | 负载均衡特性不同 |

### 2.2 Dense vs MoE 对比

| 维度 | Dense | MoE |
|---|---|---|
| 显存（权重） | 按总参数 | 按**总参数**（不省） |
| 算力（每 token） | 按总参数 | 按**激活参数**（省） |
| 小 batch 延迟 | 较好 | **较差**（要读全部专家的路由 + all-to-all） |
| 大 batch 吞吐 | 一般 | **优秀**（专家并行度高） |
| 训练稳定性 | 好 | 差（路由坍缩） |
| 部署复杂度 | 低 | 高（专家并行、通信） |
| 适合场景 | 边缘/低延迟 | 云端高吞吐 |

**一句话：MoE 用「显存」换「算力」，用「部署复杂度」换「单位 token 成本」。**

### 2.3 三个真实工程问题

**问题 1：负载不均衡（Load Imbalance）**

如果 90% 的 token 都路由到 Expert_3，那这个专家就是瓶颈，其他专家在空转。极端情况叫**专家坍缩（Expert Collapse）**——router 退化成「只用一两个专家」，等于白搭了参数。

缓解手段：

- **辅助损失（auxiliary loss）**：惩罚路由分布的熵过低
- **容量因子（capacity factor）**：每个专家最多接收 `capacity_factor × tokens / n_experts` 个 token，超了丢弃或走残差
- **专家-choice 路由**：让专家选 token，天然均衡（但因果性变差，不能用于自回归生成）
- **无辅助损失的负载均衡**（DeepSeek 的做法：给 router 加 bias 调整）

**问题 2：All-to-All 通信**

专家并行时，token 要跨 GPU 送到对应专家所在的卡，算完再送回来。这是 **all-to-all 集合通信**，对互联带宽要求极高：

| 互联 | 带宽 | 影响 |
|---|---|---|
| NVLink（同机） | 900 GB/s | 可接受 |
| PCIe 4.0 | 64 GB/s | 明显瓶颈 |
| 跨机 InfiniBand | 400 Gb/s ≈ 50 GB/s | 需要精心切分专家 |

所以 MoE 部署有一条铁律：**专家尽量放在同一台机器内**，跨机 all-to-all 会吃掉所有收益。

**问题 3：显存装不下**

671B × BF16 = 1.3TB，8 卡 H100（80G）= 640GB，装不下。所以厂商必须叠加量化（FP8 → 670GB，勉强）+ 专家切分 + KV cache 优化。

---

## 三、量化：不是「降精度」这么简单

### 3.1 量化的基本形式

```
w_q = round(w / scale) + zero_point
w_deq = (w_q - zero_point) × scale
```

关键参数：

| 参数 | 说明 |
|---|---|
| `scale` | 缩放因子，决定数值范围映射 |
| `zero_point` | 零点偏移（对称量化时为 0） |
| 量化粒度 | per-tensor / per-channel / per-group |
| 对称性 | 对称（INT8 常见）/ 非对称（UINT8 常见） |

### 3.2 粒度决定质量

| 粒度 | 说明 | 精度损失 | 开销 |
|---|---|---|---|
| per-tensor | 整个张量一个 scale | 大 | 最低 |
| per-channel | 每个输出通道一个 scale | 中 | 低 |
| **per-group（group_size=128）** | 每 128 个权重一个 scale | **小** | 中 |
| per-group（group_size=32） | 更细 | 更小 | 更高 |

**现代 INT4 量化几乎都用 per-group（group_size=128 或 64）**。这是 GPTQ/AWQ 能「4bit 几乎不掉点」的核心原因：细粒度 scale 极大缓解了离群值问题。

### 3.3 激活量化才是难点

权重是静态的，可以离线校准；**激活是动态的，每个 token 分布都在变**。所以：

| 方案 | 权重 | 激活 | 说明 |
|---|---|---|---|
| W16A16 | FP16 | FP16 | 基线 |
| W8A16 | INT8 | FP16 | 只省显存，不提速（激活还是 FP16） |
| **W8A8** | INT8 | INT8 | 真提速，但需要 SmoothQuant 处理离群值 |
| W4A16 | INT4 | FP16 | 主流部署方案（GPTQ/AWQ） |
| W4A8 | INT4 | INT8 | 激进，质量风险高 |
| FP8（E4M3） | FP8 | FP8 | H100/L40S 原生支持，质量接近 BF16 |

### 3.4 离群值：量化误差的主因

LLM 的激活里存在**极少数超大值**（几十到上百倍于均值）。如果按 per-tensor 量化，这些离群值会把 scale 拉大到「正常值全部压成 0」。

三个经典解法：

1. **LLM.int8()**：离群维度用 FP16 单独算，其余用 INT8（混合精度分解）
2. **SmoothQuant**：把激活的量化难度「迁移」到权重上（数学等价变换：`X·W = (X/s)·(s·W)`）
3. **AWQ**：观察到「约 1% 的显著权重」决定质量，对这些通道做保护（按激活幅度缩放）

```python
# SmoothQuant 的核心思想（示意）
s = (max(|X|) ** alpha) / (max(|W|) ** (1 - alpha))   # alpha ≈ 0.5
X_scaled = X / s          # 激活变小，好量化
W_scaled = W * s          # 权重变大，但权重本来就小，扛得住
```

这个技巧很优雅：**不动模型数学结果，只改「谁来承担量化难度」**。

### 3.5 KV Cache 量化

长上下文场景下，KV Cache 可能比权重还大：

```
KV = 2 × L × H × d_head × S × B × bytes
```

以 70B（80 层，64 头，head_dim=128，GQA 后 8 个 KV 头）为例，S=32K，B=1，BF16：

```
2 × 80 × 8 × 128 × 32768 × 2 ≈ 10.7 GB
```

batch=16 就是 171GB。所以：

| 手段 | 效果 |
|---|---|
| GQA / MQA | KV 头数减少 4~8 倍（架构级，最有效） |
| KV Cache INT8 | 减半，质量损失很小 |
| KV Cache FP8 | 减半，几乎无损（推荐） |
| PagedAttention | 消除碎片，提升有效容量 30%+ |
| 滑窗 / 稀疏注意力 | 只保留部分 KV（会丢信息） |

---

## 四、成本算例：三个方案横向对比

假设业务：每天 1000 万次请求，平均输入 2000 token、输出 500 token。

| 方案 | 单位成本假设 | 日成本 | 质量 | 备注 |
|---|---|---|---|---|
| 闭源大模型 API（旗舰） | ¥0.02 / 1K 输入，¥0.06 / 1K 输出 | 1000万 ×(2×0.02 + 0.5×0.06) = **70 万元** | ★★★★★ | 不适合高并发简单任务 |
| 闭源小模型 API | ¥0.002 / ¥0.006 | **7 万元** | ★★★☆ | 多数场景够用 |
| 自建 MoE（INT4）+ 8×H100 | 设备摊销 ¥3000/天 + 电费 ¥300 | **≈ 3300 元** | ★★★★ | 需要 MLOps 团队 |
| 自建 Dense 32B（W4A16）| 4×L40S 摊销 ¥800/天 | **≈ 1000 元** | ★★★ | 简单任务足够 |

⚠️ **这张表的意义不是「自建一定便宜」**，而是要看清成本结构：

- API 成本 = **token 数 × 单价**（线性，随用量爆炸）
- 自建成本 = **固定摊销 + 电费**（阶梯，用量越大越划算）

所以决策分界线是**日均 token 量**：

| 日 token 量 | 推荐 |
|---|---|
| < 5000 万 | 用 API（省人力） |
| 5000 万 ~ 5 亿 | 混合：核心用 API，边缘任务自建小模型 |
| > 5 亿 | 自建 MoE + 量化，成本优势明显 |

**人力成本永远要算进去**：一个能维护推理集群的工程师，年薪可能就是几百万 token 的 API 费用。

---

## 五、Java 侧怎么落地：精度档位灰度 + 质量门禁

多数 Java 团队不会自己训练/量化模型，但一定会**调用**不同精度档位的模型（API 的「标准版/极速版/旗舰版」，或自建 vLLM 的 `fp8`/`awq` 实例）。这里的核心风险是：**量化后的模型质量漂移，往往是静默的**。

### 5.1 模型档位注册表

```java
public enum PrecisionTier {
    FP16("fp16", 1.0),      // 基线，质量最高
    FP8("fp8", 0.95),       // 质量几乎无损
    W4A16("awq-int4", 0.85),// 有损，需评测
    W8A8("int8", 0.92);

    private final String tag;
    private final double expectedQuality;   // 历史评测得分（归一化）

    PrecisionTier(String tag, double q) { this.tag = tag; this.expectedQuality = q; }
    public String tag() { return tag; }
    public double expectedQuality() { return expectedQuality; }
}

public record ModelEndpoint(
    String modelId,          // qwen-72b
    PrecisionTier tier,
    String baseUrl,
    double inputPrice,       // 元 / 1K tokens
    double outputPrice,
    int maxContext
) {}
```

### 5.2 按任务类型路由

```java
@Component
public class PrecisionRouter {
    private final Map<String, List<ModelEndpoint>> pool = new ConcurrentHashMap<>();

    /** 任务敏感度 → 允许的最低档位 */
    private static final Map<TaskType, PrecisionTier> MIN_TIER = Map.of(
        TaskType.CLASSIFY,   PrecisionTier.W4A16,   // 分类任务鲁棒
        TaskType.EXTRACT,    PrecisionTier.W8A8,    // 结构化抽取，怕漏字段
        TaskType.SUMMARIZE,  PrecisionTier.FP8,
        TaskType.REASONING,  PrecisionTier.FP16,    // 推理链对精度敏感
        TaskType.CODE,       PrecisionTier.FP16
    );

    public ModelEndpoint pick(TaskType task, int inputTokens) {
        PrecisionTier min = MIN_TIER.get(task);
        return pool.get(task.name()).stream()
            .filter(e -> e.tier().ordinal() <= min.ordinal())   // ordinal 越大越激进
            .filter(e -> e.maxContext() >= inputTokens)
            .min(Comparator.comparingDouble(ModelEndpoint::inputPrice))
            .orElseThrow(() -> new NoAvailableModelException(task));
    }
}
```

⚠️ **`ordinal()` 依赖枚举顺序，是脆弱设计**。生产上应显式给每个档位一个 `rank` 字段，别用 ordinal（重构时顺序一变，路由就错）。

### 5.3 质量门禁：用小模型当裁判

量化漂移的检测不能靠「感觉」，要自动化：

```java
@Component
public class QualityGate {
    private final ChatClient judge;              // 用 FP16 档位当裁判
    private final GoldenSetRepository goldenSet; // 黄金集（人工标注过）

    /**
     * 抽样回归：对当前档位跑黄金集，与基线对比
     * 返回是否允许继续放量
     */
    public GateResult evaluate(PrecisionTier tier, int sampleSize) {
        List<GoldenCase> cases = goldenSet.sample(sampleSize);
        int pass = 0, formatFail = 0;

        for (GoldenCase c : cases) {
            String out = callWithTier(tier, c.input());
            // 1) 格式合规（JSON Schema 校验，硬门槛）
            if (!c.schema().matches(out)) { formatFail++; continue; }
            // 2) 语义正确（裁判模型打分 1~5，≥4 算过）
            int score = judgeScore(c, out);
            if (score >= 4) pass++;
        }

        double passRate = (double) pass / cases.size();
        double formatRate = 1.0 - (double) formatFail / cases.size();

        // 硬门槛：格式合规率必须 100%，语义通过率不低于基线 3 个点
        boolean ok = formatRate >= 0.999 && passRate >= 0.90;
        return new GateResult(ok, passRate, formatRate, cases.size());
    }
}
```

关键设计：

1. **格式合规是硬门槛**（100%），因为量化最容易破坏的就是「严格按 JSON 输出」这种能力
2. **语义用裁判模型打分**，不要用 perplexity——困惑度和业务质量相关性很弱
3. **黄金集要覆盖边界**：超长输入、多语言、否定句、数值计算、格式约束

### 5.4 灰度与熔断

```java
@Component
public class TierCanary {
    private final AtomicInteger canaryPercent = new AtomicInteger(0);
    private final QualityGate gate;
    private final MeterRegistry meter;

    /** 定时任务：每 10 分钟评估一次，自动放量/回滚 */
    @Scheduled(fixedDelay = 600_000)
    public void tick() {
        GateResult r = gate.evaluate(PrecisionTier.W4A16, 100);
        meter.counter("tier.canary.pass", "tier", "w4a16").increment(r.passRate());

        if (!r.ok()) {
            if (canaryPercent.get() > 0) {
                canaryPercent.set(0);   // 立即全量回滚到 FP16
                alert.fire("量化档位质量不达标，已回滚: " + r);
            }
            return;
        }
        // 每次最多 +10%，且不超过 50%，留人工确认
        canaryPercent.updateAndGet(p -> Math.min(50, p + 10));
    }

    public boolean useCanary(String traceId) {
        int p = canaryPercent.get();
        if (p == 0) return false;
        return Math.floorMod(traceId.hashCode(), 100) < p;   // 稳定分桶
    }
}
```

**「用 traceId 做稳定分桶」** 这个细节很重要：同一个请求链路必须始终命中同一个档位，否则 A/B 对比没有意义。

---

## 六、面试追问

**Q1：MoE 的总参数和激活参数有什么区别？为什么能降成本？**
总参数决定显存（所有权重都要装），激活参数决定算力（每 token 只算 top-k 专家）。所以 MoE 用更多显存换更少算力，在 batch 较大时单位 token 成本显著降低。

**Q2：为什么 MoE 在小 batch 下反而慢？**
推理是访存受限。小 batch 时每个请求都要把「被路由到的专家权重」从 HBM 读一遍，加上路由本身的开销和 all-to-all 通信，固定成本摊不开。batch 大了权重读取可以复用，优势才体现。

**Q3：INT4 量化为什么能几乎不掉点？**
三个原因：per-group 细粒度 scale（缓解离群值）、只量化权重不量化激活（W4A16，激活保持 FP16）、以及 GPTQ/AWQ 这类「按重要性保护显著通道」的算法。但「几乎不掉点」是平均指标，具体任务（尤其是格式约束、数值推理）仍可能明显退化。

**Q4：W8A8 和 W4A16 怎么选？**
W8A8 权重和激活都量化，能真正提速（INT8 有硬件加速），但激活离群值难处理，需要 SmoothQuant 之类的技巧；W4A16 只量化权重，主要收益是省显存、减少访存，算力仍走 FP16。显存紧张选 W4A16，吞吐要求高且硬件支持 INT8 选 W8A8。

**Q5：为什么不能用 perplexity 评估量化效果？**
困惑度衡量的是「预测下一个 token 的概率分布」，和业务质量弱相关。量化最容易破坏的是「指令遵循」「格式约束」「长链推理」，这些在 perplexity 上几乎看不出来。必须用任务级评测集 + 格式合规率。

**Q6：MoE 部署为什么强调「专家放同一台机器」？**
因为 top-k 路由会产生 all-to-all 通信。跨机 all-to-all 受限于网络带宽（IB 400Gb/s ≈ 50GB/s）远低于 NVLink（900GB/s），通信时间会超过计算时间，把算力优势吃光。

**Q7：长上下文下成本为什么不是线性增长？**
KV Cache 随序列长度线性增长，但注意力计算是 O(S²)。此外 KV Cache 挤占显存会降低 batch size，进一步推高单位 token 成本。所以 32K 上下文的成本往往远超 4× 的 8K 成本。

---

## 七、给 Java 工程师的实践清单

1. **先算清 token 结构**：输入/输出比例决定成本重心。输出 token 通常贵 3~5 倍，能缓存就别重算。
2. **别用旗舰模型做分类/抽取**：这类任务小模型 + 量化完全够，成本差 10 倍。
3. **prompt caching 优先级高于模型降级**：缓存命中省的是 100%，换模型省的是 50%，但前者不损质量。
4. **量化档位必须有自己的评测门禁**：厂商说「无损」是按他们的平均指标，你的任务可能正好踩在损失区。
5. **给每个档位独立打点**：`model_id + precision_tier` 作为 metric tag，否则出问题无法归因。
6. **长上下文单独定价**：把「输入 > 8K」的请求单独统计，这类请求的成本结构完全不同。
7. **关注输出长度分布**：P99 输出长度往往是均值的 10 倍，成本预算按均值算一定超支。

---

## 八、总结

把两个概念收束成一句话：

> **MoE 改变的是「算力/显存」的兑换比例，量化改变的是「精度/显存」的兑换比例。两者叠加，才让大模型推理成本在两年内降了一个数量级。**

但对应用开发者，真正要建立的认知是：

- **成本不是单价，是「单价 × token 结构 × 调用次数」**
- **量化不是「免费加速」，是「用可控的质量损失换成本」，必须有评测门禁**
- **模型档位要像数据库索引一样管理：有注册表、有灰度、有回滚**

技术选型时最危险的一句话是「反正模型会越来越便宜」。它会便宜，但你的用量涨得更快。**能算清成本结构的团队，才有资格谈规模化。**
