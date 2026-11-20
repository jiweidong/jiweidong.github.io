---
title: 【Java AI】大模型流式审计与脱敏深度实战：不可篡改账本、滑窗脱敏与双通道治理
date: 2026-11-20 08:30:00
tags:
  - Java
  - AI
  - 安全
  - 合规
categories:
  - AI 工程
author: 东哥
---

# 【Java AI】大模型流式审计与脱敏深度实战

## 前言

大模型应用上线到企业环境后，技术团队通常会被问到三个问题：

1. 用户问了什么、模型答了什么，**能不能查**？
2. 里面有没有手机号、身份证、客户名单，**能不能证明没泄露**？
3. 出了纠纷，这条记录**能不能当证据**（有没有被改过）？

这三个问题对应的不是"内容审核"，而是**审计（audit）**。两者的目标完全不同：

| 维度 | 内容审核（moderation） | 审计（audit） |
|---|---|---|
| 目标 | 拦住有害/违规输出 | 留下可追溯、可取证的事实 |
| 时机 | 输出前拦截 | 全量记录，不阻断业务 |
| 失败策略 | fail-closed（宁可拒答） | 不可丢（宁可背压） |
| 数据 | 风险标签、处置动作 | 原文（加密）+ 脱敏视图 + 完整性证明 |
| 读者 | 风控系统 | 合规、法务、事故复盘 |

已有文章分别讲过内容审核护栏、日志脱敏、MCP Server 审计。这一篇只解决一个具体但很硬的问题：**流式输出场景下，怎么做既不泄敏、又能取证的审计**。

流式是难点所在——token 一个一个吐，手机号会被切成 `138` + `0013` + `8000` 三段。

## 一、审计事件模型：先定 schema，再谈实现

审计最容易失败的姿势是"把整个请求响应塞进一张大表"。半年后你既查不动，也不敢删。正确的做法是先定义**事件**。

```java
public record LlmAuditEvent(
        String eventId,            // UUID，幂等去重键
        String traceId,            // 与 APM 打通
        String tenantId,
        String userId,
        String appId,              // 哪个业务应用调的
        String modelAlias,         // 逻辑模型名，不是快照名
        String modelSnapshot,      // 实际调用的快照/版本，取证必需
        String promptCipher,       // 原文密文（信封加密）
        String outputCipher,       // 输出密文
        String maskedPreview,      // 脱敏视图，供运营/客服检索
        List<ToolCall> toolCalls,  // 工具名、参数摘要、结果码、耗时
        List<String> retrievedIds, // RAG 命中的文档 ID（不是全文）
        int promptTokens,
        int completionTokens,
        long latencyMs,
        Instant startedAt,
        Instant finishedAt,
        String decision,           // allow / masked / blocked
        String prevHash,           // 链式哈希
        String recordHash
) {}
```

几个字段值得单独解释：

- **`modelAlias` 与 `modelSnapshot` 都要存**。别名会漂移（`gpt-4o-latest` 指向变了），取证时必须知道"当时到底是哪个快照"。只有别名，三个月后你无法复现。
- **`retrievedIds` 而不是文档全文**。审计要证明"模型看到了什么"，ID 足以回溯；存全文会让审计库膨胀十倍，还多一份泄密面。
- **`toolCalls` 必须记参数**。Agent 场景里，真正的风险往往在工具调用（`refund(amount=99999)`），而不是那句自然语言。
- **`maskedPreview` 是检索入口**。合规同学不会拿密文搜，他们搜"退款"关键词，需要一个可读视图。

## 二、完整性：哈希链 + 每日锚定

"能查"不等于"能当证据"。数据库管理员能改的行，法律上证明力很弱。最低成本的防篡改方案是**链式哈希**：

```text
recordHash[n] = SHA256( prevHash[n] || canonicalJson(eventWithoutHash) )
prevHash[n]   = recordHash[n-1]
```

按租户分链（不是全局一条链），避免跨租户耦合导致一条链断全表废。

```java
public String chainHash(LlmAuditEvent e, String prevHash) {
    String canonical = canonicalJson(e);          // 字段排序 + 固定时间格式
    return sha256Hex(prevHash + "|" + canonical);
}

private String sha256Hex(String s) {
    MessageDigest md = MessageDigest.getInstance("SHA-256");
    return HexFormat.of().formatHex(md.digest(s.getBytes(StandardCharsets.UTF_8)));
}
```

`canonicalJson` 必须**字段排序、时间用 epoch millis、禁止 null 与空串混用**。否则同样的数据两次序列化结果不同，校验永远失败。

链只能防"悄悄改一行"，防不了"从中间整段删掉再重算"。所以要加**每日锚定**：

```text
每天 00:05
  root = 当天最后一条记录的 recordHash
  写入 WORM 存储（对象锁/Oss Worm）或可信时间戳服务
  同时记录当天记录条数 count
```

校验时同时比对 `root` 与 `count`——只改数据不改锚点会被发现，改了锚点则需要攻破 WORM，成本陡增。

**校验任务本身要上监控**：每天跑一次全链校验（或抽样 + 首尾），失败立刻告警。一个没人看的校验脚本等于没有。

## 三、流式脱敏：为什么不能逐 chunk 做正则

### 3.1 问题本质

```text
chunk1: "您的手机号是 138"
chunk2: "0013"
chunk3: "8000，已为您登记"
```

对每个 chunk 单独跑 `1[3-9]\d{9}`，三段都不匹配，全部原样吐给前端——**完整泄露**。

### 3.2 三种方案对比

| 方案 | 做法 | 首 token 延迟 | 泄露风险 | 适用 |
|---|---|---|---|---|
| 全缓冲 | 收完再脱敏再一次性返回 | 极差（等于非流式） | 无 | 非流式场景 |
| 固定窗口 | 保留末尾 N 字符不发送 | +0（仅尾部延迟） | N < 实体长度时仍漏 | 实体长度已知（手机/身份证） |
| 词边界 + 上限 | 只在完整 token 边界放行，超长强制遮 | 略增 | 低 | 通用（推荐） |

固定窗口的问题是：你永远不知道"这个名字有几个字"。中文人名、地址、自由文本里的公司名，长度不可枚举。所以工程上更稳的是**词边界策略**。

### 3.3 实现：按词边界放行

核心思路：只在"确定安全"的位置切分输出。

```java
public final class StreamingMasker {

    private static final int MAX_HOLD = 256;          // 兜底：不允许无限攒

    private final StringBuilder pending = new StringBuilder();
    private final PiiMasker masker;                   // 正则 + 词典 + 可选 NER

    /**
     * @param chunk 模型新吐出的片段
     * @param last  是否是最后一片
     * @return 可以安全下发的文本（已脱敏），可能为空串
     */
    public synchronized String accept(String chunk, boolean last) {
        pending.append(chunk);
        if (last) {
            String out = masker.mask(pending.toString());
            pending.setLength(0);
            return out;
        }

        int cut = safeBoundary(pending);
        if (cut <= 0) {
            // 还没到安全边界；但如果攒太久，宁可整段遮也不能无限延迟
            if (pending.length() >= MAX_HOLD) {
                String out = masker.mask(pending.toString());
                pending.setLength(0);
                return out;
            }
            return "";
        }

        String emit = pending.substring(0, cut);
        pending.delete(0, cut);
        return masker.mask(emit);
    }

    /** 找一个"实体不可能跨越"的切点：空白、标点、换行 */
    private int safeBoundary(CharSequence sb) {
        for (int i = sb.length() - 1; i >= 0; i--) {
            char c = sb.charAt(i);
            if (Character.isWhitespace(c) || isPunct(c)) {
                return i + 1;
            }
        }
        return 0;
    }

    private boolean isPunct(char c) {
        return "，。！？；：、,.!?;:()（）【】[]\"'".indexOf(c) >= 0;
    }
}
```

三个设计取舍，必须写进注释：

1. **`MAX_HOLD=256` 是兜底**。如果模型吐了一长串没有标点的内容（代码块、URL、base64），不能一直攒着不返回，否则用户看到"卡住"。超过上限就整段脱敏后放行——**宁可多遮，不可漏遮**。
2. **代码块要特殊处理**。代码里的 `1e10`、`0x138000` 会被手机号正则误伤。实践做法：检测到 ``` 围栏后切换到"仅遮密钥类"模式。
3. **`synchronized` 是为了顺序**。同一个会话的 chunk 可能来自不同回调线程，脱敏是有状态的，必须串行。

### 3.4 遮什么：分层规则

| 层 | 目标 | 手段 | 误伤率 |
|---|---|---|---|
| L1 硬规则 | 手机号、身份证、银行卡（Luhn 校验）、邮箱 | 正则 + 校验位 | 低 |
| L2 密钥类 | `sk-`、`AKIA`、`ghp_`、JWT | 前缀 + 长度 + 熵 | 极低 |
| L3 词典 | 客户名、项目代号、内部域名 | AC 自动机（Aho-Corasick） | 中（需维护词表） |
| L4 模型 | 人名、地址、自由文本 PII | 小 NER 模型 / 二次 LLM 调用 | 高，**不要放在主链路** |

L4 千万别同步做：一是延迟，二是"用大模型审大模型"会引入新的不确定性。正确位置是**离线抽样审计**——每天抽 1% 的会话跑 NER，评估 L1~L3 的漏检率，反过来补充规则。

银行卡一定要做 Luhn 校验，否则你会把订单号、流水号全遮掉，业务方第二天就来投诉。

## 四、双通道：给用户看的，和给审计看的

```text
                    ┌─→ 展示通道：脱敏后文本 → SSE → 前端
模型流 → Masker ────┤
                    └─→ 审计通道：原文 → 信封加密 → WAL → Kafka → 审计库
```

关键点：

### 4.1 审计通道不能丢，所以要有 WAL

审计消息直接发 Kafka，一遇到 broker 抖动就会丢（`acks=1` + 本地队列满）。做法是**先落本地 append-only 文件**，再异步 ship：

```java
public void audit(LlmAuditEvent event) {
    byte[] line = (json(event) + "\n").getBytes(UTF_8);
    // 1) 本地 WAL：fsync 由组提交控制，崩溃最多丢最后一批
    wal.append(line);
    // 2) 异步投递，失败由 WAL 重放补偿
    kafka.sendAsync(event);
}
```

WAL 按小时滚动，ship 成功且超过保留期后删除。这条链路和数据库的 redo 是一个思路：**先持久化，再传播**。

### 4.2 原文加密：信封加密 + 按租户隔离

```java
// 每个租户一个 DEK，DEK 由 KMS 的 CMK 加密后存配置中心
byte[] dek = kms.decryptDataKey(tenantId);          // 进程内缓存 + TTL
String cipher = aesGcmEncrypt(dek, plaintext, aadFor(eventId));
```

`aad`（附加认证数据）带 `eventId` + `tenantId`，防止把 A 租户的密文搬到 B 租户的记录里还能解密。

### 4.3 谁能看原文：二次授权 + 访问审计

审计库的原文列**不给业务系统账号任何权限**。查看走独立服务：

```text
合规人员 → 提交查看申请（事由 + 工单号） → 审批 → 临时凭证（15 分钟）
        → 审计服务解密 → 返回 → 本次查看本身再写一条审计
```

"看审计的人也被审计"，这是合规体系的基本闭环。

## 五、指标与容量

| 指标 | 含义 | 告警阈值 |
|---|---|---|
| `audit.write.lag.ms` | 从请求结束到审计落库 | p99 > 5s |
| `audit.wal.pending.bytes` | 未 ship 的 WAL 体积 | > 500MB 持续 10min |
| `mask.hit.count{type}` | 各类 PII 命中数 | 突增 3 倍（可能被探测） |
| `mask.holdback.flush.max` | 强制放行次数 | 持续增长说明规则太宽 |
| `audit.chain.verify.fail` | 链校验失败 | **> 0 立即 P1** |
| `audit.raw.access.count` | 原文查看次数 | 异常时段突增 |

容量估算：一条审计事件（含 2KB prompt + 2KB output，密文后约 6KB）按每天 50 万次调用算，约 **3GB/天**，一年 1TB。所以：

- 热数据（30 天）放 ClickHouse/ES，支持检索；
- 冷数据转对象存储，只保留 `recordHash` 与索引；
- **保留期必须由合规给，不是技术拍**。常见是 6 个月到 3 年，金融更长。

## 六、四个生产踩坑

1. **脱敏把 JSON 结构破坏了**。模型输出结构化 JSON 时，如果正则在字符串外匹配到数字（`"amount": 13800138000`），替换成 `[PHONE]` 会让下游 `ObjectMapper` 解析失败。解法：结构化输出场景先解析再对**字符串值**脱敏，或用 JSON-aware 的 masker。
2. **审计写入拖垮主链路**。同步写审计库，DB 一抖，聊天接口就 500。审计必须异步 + WAL + 有界队列，队列满时**拒绝新请求**而不是丢审计（这是与内容审核相反的策略）。
3. **哈希链在并发下断裂**。多线程同时算 `prevHash`，链会分叉。必须按租户串行（单分区单写者），或用数据库行锁 + 序号。
4. **忘了记 `decision`**。只记"答了什么"，不记"当时是放行、脱敏还是拦截"，事故复盘时无法还原处置链路。

## 七、面试追问

**Q1：审计和日志有什么区别？为什么不直接看应用日志？**

日志是**运维视角**的、可采样、可丢弃、有轮转；审计是**合规视角**的、不可采样、不可丢、有保留期与完整性证明。技术上差在三点：写路径（WAL + 不可丢）、存储（加密 + 访问控制）、完整性（哈希链 + 锚定）。把审计塞进 logback，等于把证据交给一个随时会 `rm` 的目录。

**Q2：流式脱敏为什么不能等全部输出完再做？**

那就不是流式了——首 token 延迟从 300ms 变成 8s，产品体验直接崩。流式脱敏的本质是**在"尽快输出"和"确认安全"之间找切点**，词边界 + 兜底上限就是这个切点的工程实现。

**Q3：哈希链能防住 DBA 改数据吗？**

只能"发现"，不能"阻止"。DBA 有库权限，改完数据重算整条链是可以做到的——所以需要**外部锚点**（WORM、时间戳服务）把每日 root 固化到 DBA 权限之外。链 + 锚点组合，才把篡改成本抬到"需要攻破另一个系统"。

**Q4：为什么不干脆不存原文？**

看场景。如果只需要"证明说过什么类别的话"，存 hash + 脱敏视图足够，这是**数据最小化**的优选。但事故复盘、法务取证、模型质量回溯都需要原文，否则你无法回答"模型当时为什么这么答"。折中是：**分级保留**——高风险场景（涉及资金、合同、医疗）存原文并加密，普通问答只存脱敏视图 + hash。

## 总结

- 审计 ≠ 内容审核：前者要"可取证、不可丢、不可改"，后者要"拦住风险"。
- 事件模型要含 `modelSnapshot`、`toolCalls`、`retrievedIds`、`decision`，这四项决定了三个月后还能不能复盘。
- 完整性靠**按租户的哈希链 + 每日 WORM 锚定**，链只防悄悄改，锚点才防整段重算。
- 流式脱敏的关键是**词边界放行 + 上限兜底**，绝不能逐 chunk 跑正则。
- 双通道：展示通道脱敏、审计通道加密原文，中间用 WAL 保证不丢。
- 原文访问必须二次授权，且"看审计的人也要被审计"。
