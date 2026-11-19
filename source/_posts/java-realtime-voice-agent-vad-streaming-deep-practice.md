---
title: 【Java AI】实时语音 Agent 深度实战：VAD 断句、流式 ASR、双工打断与端到端延迟预算
date: 2026-11-19 08:30:00
tags:
  - Java
  - AI
  - Agent
  - 语音
  - WebSocket
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】实时语音 Agent 深度实战

## 前言

做语音助手，最容易低估的一句话是：「ASR 和 TTS 我都调通了，怎么体验还是像个对讲机？」

因为**能转写 ≠ 能对话**。真人对话的核心不是识别准确率，而是三件事：

1. **什么时候该听**（端点检测，不能用户喘口气就抢话）；
2. **什么时候该说**（首包要快，但不能把半句话念出去）；
3. **什么时候该停**（用户一开口，立刻闭嘴）。

这三件事没有一件是 ASR/TTS 厂商 API 帮你解决的，全部要在编排层实现。本文用 Java（Spring WebFlux + 虚拟线程）搭一条完整的实时语音链路，把 VAD、流式 ASR、LLM、流式 TTS、双工打断和延迟预算逐段拆开。

---

## 一、链路拆解与延迟预算

一条最小的实时语音链路：

```
麦克风采集(20ms/帧)
   ↓
VAD 帧级判定 ──→ 状态机（静音/说话/拖尾）
   ↓ 端点确认
流式 ASR（partial → final）
   ↓ final 文本
LLM（流式 token）
   ↓ 按句切分
流式 TTS（首包 → 音频块）
   ↓
播放队列（jitter buffer）
```

用户感知的「响应延迟」不是整条链路的总时长，而是一个特定区间：

> **用户停止说话的那一刻 → 扬声器播出第一个音节**

这个指标业内常叫 **response latency** 或 **voice-to-voice latency**。拆开算：

| 阶段 | 典型耗时 | 优化手段 |
|---|---|---|
| 采集缓冲 | 20~60ms | 帧长 20ms，别用 100ms |
| VAD 拖尾确认 | 300~500ms | 拖尾从 700ms 降到 400ms（代价是误切） |
| ASR final 产出 | 150~300ms | 流式 ASR，final 紧跟在端点后 |
| LLM 首 token | 300~800ms | 小模型优先、prompt 精简、prefix cache |
| TTS 首包 | 150~300ms | 按句合成，首句短切 |
| 网络往返 | 50~150ms | 同地域部署、长连接 |
| **合计** | **1.0~1.9s** | 目标 < 1.2s |

可以看到，**VAD 拖尾 + LLM 首 token 就占了 60%**。所以优化顺序应该是：端点策略 → 首句切分 → 模型选择，而不是一上来换更快的 ASR。

---

## 二、音频基础：先把单位算对

Java 侧最容易出错的是采样率和字节数。

| 参数 | 常用值 | 说明 |
|---|---|---|
| 采样率 | 16000 Hz | ASR 通用；TTS 可能是 24000 Hz |
| 位深 | 16 bit | PCM signed little-endian |
| 声道 | 1（mono） | 双声道要先降混 |
| 帧长 | 20ms | 320 samples = **640 bytes** |

```java
public record AudioFormat(int sampleRate, int channels, int bitsPerSample) {
    public int bytesPerFrame(int frameMillis) {
        return sampleRate * frameMillis / 1000 * channels * bitsPerSample / 8;
    }
}

AudioFormat F16K = new AudioFormat(16000, 1, 16);
int bytes = F16K.bytesPerFrame(20); // 640
```

采样率不匹配是最常见的「声音变调/语速异常」原因：

- 麦克风 48kHz，直接当 16kHz 送给 ASR → 语速变快 3 倍；
- TTS 返回 24kHz，按 16kHz 播放 → 声音低沉、变慢。

**每个边界都要显式重采样**，不要相信「上游说它是 16k」。

```java
// 简易线性重采样（生产建议用 TarsosDSP / soxr / JNI）
public static short[] resample(short[] in, int from, int to) {
    if (from == to) return in;
    int outLen = (int) ((long) in.length * to / from);
    short[] out = new short[outLen];
    double step = (double) from / to;
    for (int i = 0; i < outLen; i++) {
        double pos = i * step;
        int i0 = (int) pos;
        int i1 = Math.min(i0 + 1, in.length - 1);
        double frac = pos - i0;
        out[i] = (short) (in[i0] * (1 - frac) + in[i1] * frac);
    }
    return out;
}
```

---

## 三、VAD：不要一上来就上模型

### 3.1 能量 VAD 的可用版本

大多数安静场景（耳机、办公室）用能量 + 过零率就能做到 90 分。核心是**自适应噪声底**：

```java
public final class EnergyVad {
    private double noiseFloor = 300;      // 初始噪声 RMS
    private static final double ALPHA = 0.95;
    private static final double TRIGGER_RATIO = 3.0;  // 高于噪声底 3 倍认为有声
    private static final double ABS_MIN_RMS = 250;    // 绝对下限，防静音时误触发

    /** @return 该帧是否为语音 */
    public boolean accept(short[] frame) {
        double rms = rms(frame);
        boolean speech = rms > Math.max(noiseFloor * TRIGGER_RATIO, ABS_MIN_RMS);
        if (!speech) {
            // 只在非语音帧更新噪声底，避免把说话声学成噪声
            noiseFloor = ALPHA * noiseFloor + (1 - ALPHA) * rms;
        }
        return speech;
    }

    private static double rms(short[] frame) {
        double sum = 0;
        for (short s : frame) sum += (double) s * s;
        return Math.sqrt(sum / frame.length);
    }
}
```

调参经验：

- `TRIGGER_RATIO` 2.5~4，太小会被键盘声触发，太大会漏掉轻声；
- 噪声底更新必须在「非语音」帧做，否则说话时噪声底被抬高，越说越迟钝；
- 加分贝门限更直观：`dBFS = 20 * log10(rms / 32768)`，人声通常在 -35dBFS 以上。

### 3.2 什么时候需要模型 VAD

能量 VAD 的失效场景很明确：

- 背景有持续人声（办公室、咖啡厅）；
- 麦克风增益自动调整（AGC）导致噪声底漂移；
- 需要区分「说话」和「电视声」。

这时用 Silero VAD（ONNX Runtime Java）：

```java
// 输入 512 samples @16k（32ms），输出语音概率
try (OrtEnvironment env = OrtEnvironment.getEnvironment();
     OrtSession session = env.createSession("silero_vad.onnx", new OrtSession.SessionOptions())) {

    float[][] input = new float[1][512];
    float[][][] state = new float[2][1][128];
    // 每帧填充 input、执行 session.run、读取 prob
}
```

工程上建议**双门限**：

```
能量 VAD 负责「快速触发」（低延迟）
模型 VAD 负责「确认」（低误触）
两者取与：能量命中 + 模型概率 > 0.5 才进入 SPEAKING
```

### 3.3 端点检测状态机

```java
public enum VadState { SILENCE, SPEAKING, TRAILING }

public final class EndpointDetector {
    private VadState state = VadState.SILENCE;
    private int speechMs = 0;
    private int silenceMs = 0;

    private final int minSpeechMs = 200;    // 太短的咔嗒声忽略
    private final int trailingSilenceMs = 400;
    private final int maxUtteranceMs = 15_000;

    /** @return true 表示一句话结束 */
    public boolean onFrame(boolean isSpeech, int frameMs) {
        switch (state) {
            case SILENCE -> {
                if (isSpeech) {
                    speechMs = frameMs;
                    state = VadState.SPEAKING;
                }
            }
            case SPEAKING -> {
                if (isSpeech) {
                    speechMs += frameMs;
                    silenceMs = 0;
                    if (speechMs >= maxUtteranceMs) {
                        reset();
                        return true;  // 强制切分，避免无限长句
                    }
                } else {
                    silenceMs = frameMs;
                    state = VadState.TRAILING;
                }
            }
            case TRAILING -> {
                if (isSpeech) {
                    speechMs += frameMs;
                    silenceMs = 0;
                    state = VadState.SPEAKING;
                } else {
                    silenceMs += frameMs;
                    if (silenceMs >= trailingSilenceMs) {
                        boolean valid = speechMs >= minSpeechMs;
                        reset();
                        return valid;
                    }
                }
            }
        }
        return false;
    }

    private void reset() {
        state = VadState.SILENCE;
        speechMs = 0;
        silenceMs = 0;
    }
}
```

拖尾时间是最需要产品化的参数：

- 400ms：响应快，但用户思考性停顿会被切断；
- 700ms：更宽容，但对话明显变慢；
- 更好的方案是**语义端点**：ASR partial 结果稳定 + 末尾有标点 + 停顿时长，三者加权。

---

## 四、流式 ASR：partial 只用来展示，final 才做决策

流式 ASR 通常返回两类结果：

| 类型 | 语义 | 用途 |
|---|---|---|
| partial（中间结果） | 可能还会变 | UI 实时字幕、提前预热 LLM |
| final（最终结果） | 端点确认后不再变 | 送入 LLM、写入对话历史 |

三个坑：

1. **不要用 partial 触发业务**。用户说「帮我订明……天去上海」，partial 可能在「明」就给出一个看似完整的句子；
2. **要处理 final 重复**。有些厂商在长句中会多次给 final，需要按 segment id 去重；
3. **要处理空 final**。VAD 误触发时 final 为空串，直接送 LLM 会浪费一次调用。

```java
public void onAsrResult(AsrResult r) {
    if (r.isFinal()) {
        String text = r.text().strip();
        if (text.isEmpty() || text.equals(lastFinalText)) return;
        lastFinalText = text;
        pipeline.onUserUtterance(text);
    } else {
        ui.pushPartial(r.text());
    }
}
```

### 4.1 投机启动（speculative start）

如果 partial 已经稳定（连续 2 帧不变）且长度 > 6 字，可以用它**预热** LLM：

- 先发一个 `max_tokens=1` 的请求，把 prompt 的 prefix cache 建好；
- final 到达后再发正式请求，首 token 延迟能降 100~200ms。

代价是多花一次极小请求的钱。对高价值场景（客服、陪伴）值得。

---

## 五、LLM → TTS：按句合成，首句要短

如果等 LLM 全部生成完再送 TTS，首包延迟 = LLM 总时长，直接不可用。正确做法是**流式切句**：

```java
public final class SentenceChunker {
    private final StringBuilder buf = new StringBuilder();
    private static final String DELIMS = "。！？；!?;\n";
    private static final int MIN_FIRST = 6;   // 首句至少 6 字，避免「好的」单独成句
    private static final int MAX_LEN = 60;

    /** 返回可以送去合成的句子（可能为空） */
    public List<String> push(String delta) {
        buf.append(delta);
        List<String> out = new ArrayList<>();
        int start = 0;
        for (int i = 0; i < buf.length(); i++) {
            boolean isDelim = DELIMS.indexOf(buf.charAt(i)) >= 0;
            int len = i - start + 1;
            if (isDelim && len >= MIN_FIRST) {
                out.add(buf.substring(start, i + 1));
                start = i + 1;
            } else if (len >= MAX_LEN) {
                out.add(buf.substring(start, i + 1));  // 长句强制切
                start = i + 1;
            }
        }
        buf.delete(0, start);
        return out;
    }

    public String flush() {
        String rest = buf.toString();
        buf.setLength(0);
        return rest;
    }
}
```

首句策略：

- 首句目标 8~15 字，太长首包慢，太短语调碎；
- 后续句子可以 30~50 字，音质更自然；
- 遇到代码、URL、数字，单独处理（TTS 读法差异很大）。

TTS 侧用并行请求 + 顺序播放：

```java
// 虚拟线程池，限制每会话并发，避免把供应商配额打满
private final ExecutorService ttsPool = Executors.newVirtualThreadPerTaskExecutor();
private final Semaphore ttsInflight = new Semaphore(3);

void synthesize(String sentence, long seq) {
    ttsPool.submit(() -> {
        ttsInflight.acquire();
        try {
            byte[] audio = ttsClient.synthesize(sentence);
            playback.enqueue(seq, audio);   // 按 seq 排序，防乱序
        } finally {
            ttsInflight.release();
        }
    });
}
```

**顺序不能乱**：TTS 请求是并发的，返回顺序不保证。播放端必须按 `seq` 排队，否则会出现「第二句先播、第一句后播」的鬼畜效果。

---

## 六、双工打断：整条链路最难的部分

### 6.1 状态机

```java
public enum DialogState {
    LISTENING,     // 收音中
    THINKING,      // 已送 LLM，等首 token
    SPEAKING,      // 正在播放 TTS
    INTERRUPTED    // 被打断，清理中
}
```

打断发生时（用户在 `SPEAKING` 阶段开口）：

1. 立刻停止播放，清空 jitter buffer；
2. 取消 TTS 未完成的请求；
3. 取消 LLM 流（关闭 SSE / 取消 `Disposable`）；
4. 把「已播放的部分回复」写入对话历史，并标注「（被打断）」；
5. 状态切回 `LISTENING`，开始收新音频。

```java
public void onBargeIn() {
    if (state != DialogState.SPEAKING) return;
    state = DialogState.INTERRUPTED;

    playback.stopAndFlush();          // 1. 停播 + 清缓冲
    ttsCancellations.forEach(Runnable::run);  // 2. 取消 TTS
    llmStream.dispose();              // 3. 取消 LLM 流（Reactor）

    String spoken = playback.spokenText();     // 4. 记录已说内容
    history.appendAssistant(spoken + "（被打断）");
    state = DialogState.LISTENING;              // 5. 回到收音
}
```

### 6.2 回声：打断功能的头号杀手

不戴耳机时，扬声器的声音会被麦克风收进去，VAD 判定为「用户说话」，于是 AI 自己把自己的话打断，陷入死循环。

三种解法，按成本排序：

| 方案 | 效果 | 成本 |
|---|---|---|
| 强制耳机 / 半双工（播放时静音麦克风） | 100% 解决，但体验差 | 0 |
| 播放期间提高 VAD 阈值 + 参考信号门控 | 解决 80% | 低 |
| AEC（回声消除，WebRTC AEC3 / Speex） | 解决 95%+ | 高（需要参考信号对齐） |

最低成本的工程做法：**播放时把 TTS 音频能量作为参考，若麦克风能量不超过播放能量的某个比例，判定为回声**。

```java
boolean isEcho = micRms < playbackRms * 0.35 && withinMs(lastPlaybackTs, 200);
if (isEcho) return;  // 忽略
```

### 6.3 打断后的上下文

被打断的回复，不能整段丢弃，也不能当成完整回复。建议存成：

```json
{
  "role": "assistant",
  "content": "上海明天多云，气温 18 到 24 度，建议……",
  "meta": { "interrupted": true, "spokenChars": 14 }
}
```

下一轮 prompt 里可以提示模型：「上一轮回复被用户打断，仅说到第 14 个字」。这样模型不会重复已说的内容，也不会假装自己说完了。

---

## 七、Java 编排：WebSocket + 虚拟线程

### 7.1 会话对象

```java
public final class VoiceSession {
    private final String sessionId;
    private final WebSocketSession ws;
    private final EnergyVad vad = new EnergyVad();
    private final EndpointDetector endpoint = new EndpointDetector();
    private final AtomicReference<DialogState> state = new AtomicReference<>(DialogState.LISTENING);
    private final PlaybackQueue playback = new PlaybackQueue();
    private final Semaphore llmInflight = new Semaphore(1);  // 同一会话串行
    private volatile Disposable llmStream;

    public void onAudioFrame(short[] pcm16) {
        boolean speech = vad.accept(pcm16);
        if (speech && state.get() == DialogState.SPEAKING) {
            onBargeIn();                      // 双工打断
        }
        if (endpoint.onFrame(speech, 20)) {
            asr.finishUtterance();            // 触发 final
        }
        asr.send(pcm16);                      // 同时持续送流式 ASR
    }
}
```

### 7.2 背压：音频不能无限排队

一个常见事故：ASR 上游变慢，音频帧在内存里越堆越多，几分钟后 OOM。

音频是**实时流**，堆积没有意义——迟到的音频不如丢掉。所以队列必须有界，并且策略是「丢旧保新」：

```java
public final class BoundedAudioQueue {
    private final ArrayDeque<short[]> queue = new ArrayDeque<>();
    private final int capacity;

    public synchronized void offer(short[] frame) {
        if (queue.size() >= capacity) {
            queue.pollFirst();   // 丢最旧的，保证低延迟
            dropped.increment();
        }
        queue.addLast(frame);
    }
}
```

同时监控 `dropped` 计数：持续丢帧说明下游容量不足，要么扩容，要么降采样/降码率。

### 7.3 会话级并发隔离

每个会话一个虚拟线程处理音频，但**上游 API 调用要限流**：

```java
// 全局：最多 200 路并发 ASR
private final Semaphore globalAsr = new Semaphore(200);

void sendToAsr(short[] frame) {
    if (!globalAsr.tryAcquire()) {
        metrics.counter("asr.rejected").increment();
        return;  // 快速失败，不要阻塞音频线程
    }
    try {
        asrClient.send(frame);
    } finally {
        globalAsr.release();
    }
}
```

虚拟线程解决了「一线程一会话」的成本问题，但**解决不了上游配额问题**。限流必须单独做。

---

## 八、延迟测量：别靠感觉

在每个环节打时间戳，算两段关键指标：

```java
public record TurnTiming(
        long userStopTs,      // VAD 判定端点
        long asrFinalTs,
        long llmFirstTokenTs,
        long ttsFirstByteTs,
        long firstAudioPlayedTs
) {
    public long endpointLatency() { return asrFinalTs - userStopTs; }
    public long llmLatency()      { return llmFirstTokenTs - asrFinalTs; }
    public long ttsLatency()      { return ttsFirstByteTs - llmFirstTokenTs; }
    public long responseLatency() { return firstAudioPlayedTs - userStopTs; }
}
```

要看的不是平均值，而是 **P50 / P90 / P99**：

- P50 决定「感觉顺不顺」；
- P99 决定「有没有想砸手机」。

经验阈值（供参考）：

| 指标 | 良好 | 可接受 | 需要优化 |
|---|---|---|---|
| response latency P50 | < 800ms | 800~1200ms | > 1200ms |
| response latency P99 | < 1500ms | 1500~2500ms | > 2500ms |
| 打断响应（停止播放） | < 100ms | 100~200ms | > 200ms |
| ASR final 延迟 | < 200ms | 200~400ms | > 400ms |

---

## 九、成本算例

一通 3 分钟的语音对话，假设：

- 用户说话占比 60% → ASR 音频 108 秒；
- AI 回复共 900 字 → TTS 900 字符；
- LLM 输入 3000 token/轮 × 6 轮，输出 150 token/轮。

| 项目 | 计量 | 说明 |
|---|---|---|
| ASR | 按音频秒 | 108s，注意很多厂商按 15s/60s 向上取整 |
| LLM | 按 token | 输入远大于输出，prompt 复用和缓存很关键 |
| TTS | 按字符 | 900 字，注意标点/SSML 是否计费 |
| 网络/计算 | 固定 | WebSocket 长连接、转码 |

降本三板斧：

1. **VAD 前置**：静音段不送 ASR，直接省 30~40%；
2. **首句短切**：不是省钱，是省延迟；真正省钱的是**避免重复合成**（打断后已取消的请求要真的取消）；
3. **ASR 双档**：实时档用便宜模型，需要高准确率时再对关键片段做二次识别。

---

## 十、踩坑清单

| 现象 | 根因 | 修复 |
|---|---|---|
| 声音变调/语速异常 | 采样率不匹配 | 每个边界显式重采样 |
| AI 自己打断自己 | 扬声器回声触发 VAD | 耳机 / 门控 / AEC |
| 用户停顿被切断 | 拖尾太短 | 400→700ms 或语义端点 |
| 首包 3 秒 | 等 LLM 全文再 TTS | 流式切句 |
| 句子顺序乱 | TTS 并发返回乱序 | 按 seq 排序播放 |
| 内存持续上涨 | 音频队列无界 | 有界队列 + 丢旧保新 |
| final 重复触发 | 未按 segment 去重 | segment id 去重 |
| 打断后模型重复前文 | 历史未记录已说部分 | 记录 spokenChars + interrupted 标记 |
| 移动端切后台断流 | 音频焦点丢失 | 监听生命周期，主动重连 |
| 长句 TTS 超时 | 单次合成文本过长 | 60 字强制切分 |

---

## 十一、面试追问

**Q1：实时语音 Agent 的端到端延迟主要花在哪？**

VAD 拖尾（300~500ms）和 LLM 首 token（300~800ms）是大头。优化顺序是端点策略 → 首句切分 → 模型选择，而不是先换 ASR。

**Q2：为什么不能用 ASR 的 partial 结果驱动业务？**

partial 会回退和改写，同一句话可能给出多个版本。业务决策必须等 final，partial 只用于 UI 和投机预热。

**Q3：双工打断最难的是什么？**

回声。不戴耳机时 TTS 声音会被麦克风收进去，误判为用户说话。需要门控或 AEC，否则会陷入「AI 打断自己」的循环。

**Q4：为什么音频队列要有界且丢旧？**

音频是实时流，迟到的帧没有价值。无界队列只会把延迟越堆越高，最后 OOM。丢旧保新是唯一合理策略，同时要监控丢帧率。

**Q5：虚拟线程能解决语音 Agent 的并发问题吗？**

解决「每会话一线程」的成本问题，但解决不了上游 ASR/TTS 的配额问题。仍然需要会话级串行 + 全局信号量限流。

---

## 十二、总结

实时语音 Agent 的门槛不在模型，而在**时序**：

- VAD 决定「什么时候算一句话」；
- 流式 ASR 决定「多快拿到确定文本」；
- 切句 + 流式 TTS 决定「多快开口」；
- 打断状态机决定「像不像人」。

把这四段当成一个**实时系统**来设计——有状态机、有背压、有超时、有指标——而不是把三个 API 串起来，体验才会有质变。

最后给一个判断标准：如果你自己跟它对话时，会不自觉地等它说完再开口，那说明打断还没做好；如果它能被你随时打断、并且接着你的新话题往下聊，那才算真的「实时」。
