---
title: 【AI 工程化】生成式 UI 与流式交互深度解析：从 token 流到可操作界面的工程体系
date: 2026-11-24 08:20:00
tags:
  - Java
  - AI
  - 前端交互
  - 流式
  - 工程化
categories:
  - AI 工程
author: 东哥
---

# 【AI 工程化】生成式 UI 与流式交互深度解析

## 前言：模型能力相同，为什么用户体验差一个时代

同一个模型、同一套 RAG，两个团队做出来的产品，用户评价可能天差地别。差别通常不在模型，而在**交互层**：

- A 产品：点击发送 → 转圈 8 秒 → 一次性吐出 2000 字 → 用户已经切走了。
- B 产品：0.6 秒出现第一句话 → 边生成边渲染 → 随时可停 → 生成到一半就能点「复制代码」→ 引用可点击回原文。

用户感知的「智能」，很大程度是**延迟、可控性与可读性**的复合体。这一篇讲 AI 应用的交互工程：流式渲染管线、生成式 UI 的协议与安全、可取消/可编辑的交互原语、以及 Java 后端该承担的职责。

---

## 一、三种 UI 范式：从「聊天框」到「会自己长出来的界面」

| 范式 | 形态 | 适合场景 | 主要难点 |
|---|---|---|---|
| Chat | 纯对话气泡 | 问答、客服、探索式任务 | 长回答阅读体验差、结构化信息难操作 |
| Streaming Artifact | 侧栏/画布实时生成文档、代码、表格 | 写作、编码、报告 | 增量渲染、版本管理、编辑冲突 |
| Generative UI | 模型输出「组件描述」，前端渲染成真实 UI | 表单、看板、审批、数据查询 | 组件白名单、schema 校验、降级 |

三者的关系不是替代，而是**同一产品里分层使用**：主对话是 Chat，产出物进 Artifact，需要用户操作的步骤渲染成 Generative UI 组件（比如「选择要退款的订单」直接给一个可选择列表，而不是让用户打字描述订单号）。

### Generative UI 的核心协议

不要让模型输出 HTML/JS——那是 XSS 与 RCE 的入口。正确做法是让模型输出**受限的 UI Schema**：

```json
{
  "schemaVersion": "1.2",
  "component": "OrderSelector",
  "props": {
    "title": "请选择要退款的订单",
    "orders": [
      {"id": "A1001", "amount": "199.00", "status": "paid"},
      {"id": "A1002", "amount": "59.00", "status": "paid"}
    ],
    "actions": [{"id": "refund", "label": "申请退款", "confirm": true}]
  }
}
```

前端维护一个**组件注册表（registry）**，按 `component` 名映射到 React/Vue 组件；`props` 用 JSON Schema 校验；`schemaVersion` 不匹配或组件不存在时**降级为纯文本**。

三条安全红线：

1. **组件名必须白名单**，未知组件一律降级，绝不动态 `import()`。
2. **props 必须过 schema 校验**，尤其是 URL 字段（防 `javascript:`）、HTML 字段（禁用或强制转义）。
3. **动作必须回到后端执行**。UI 只负责「用户点了什么」，真正的写操作走带权限校验的 API，不能让前端根据模型给的参数直接改数据。

---

## 二、流式渲染管线：把 token 变成界面的五个阶段

```
SSE chunk → 增量解析 → 部分对象 → 乐观渲染 → 最终校验替换
```

### 2.1 事件协议要先设计好

不要只发「文本片段」。一个可维护的流式协议至少包含这些事件类型：

```
event: start      data: {"requestId":"r-123","model":"...","schemaVersion":"1.2"}
event: delta      data: {"text":"根据"}
event: delta      data: {"text":"订单记录，"}
event: tool       data: {"name":"queryOrders","status":"running","args":{...}}
event: ui         data: {"component":"OrderSelector","props":{...}}
event: citation   data: {"docId":"kb-88","span":[120,168]}
event: usage      data: {"promptTokens":812,"completionTokens":156}
event: error      data: {"code":"UPSTREAM_TIMEOUT","retryable":true}
event: done       data: {"finishReason":"stop"}
```

设计要点：

- **`requestId` 必须由前端生成并贯穿全链路**，用于幂等、取消、日志关联。
- **`done` 一定要发**，哪怕出错也要发 `error` + `done`，否则前端只能等超时。
- **`usage` 单独发**，不要在 `done` 里才给，前端可以实时显示「已用 1.2k tokens」。
- **`ui` 事件与 `delta` 分开**：文本是文本，组件是组件，前端可以分别处理与降级。

### 2.2 增量解析：只展示，不决策

模型输出结构化内容时（比如一个 JSON artifact），流式片段是**合法前缀但非法 JSON**：

```
{"title":"季度总结","sections":[{"heading":"一、
```

前端要么用容错的增量解析器，要么**按行/按字段**设计输出格式（NDJSON 更友好）。核心原则：**流式阶段只做「展示」，任何写操作、工具调用、状态变更都必须等完整对象 + 校验通过**。这条原则能挡掉一大类「半截 JSON 被当成命令执行」的事故。

### 2.3 乐观渲染与最终替换

生成式 UI 常见做法是：`delta` 阶段先渲染「文字骨架」，`ui` 事件到达后替换为真实组件。替换要满足：

- **DOM 不闪烁**：用稳定的 key（`component + hash(props)`），避免整块重挂载。
- **焦点不丢失**：如果用户正在输入，替换时要恢复焦点与光标位置。
- **滚动不跳**：流式追加时保持「用户是否在底部」的状态，用户手动上滑后不要再自动吸底。

---

## 三、交互原语：让用户「有控制感」

AI 产品最伤体验的不是慢，而是**不可控**。五个必须做好的原语：

### 3.1 停止生成

点击停止后：

1. 前端立即停止渲染，保留已生成内容（不要清空）。
2. 发送 `POST /chat/{requestId}/cancel`。
3. 后端取消上游 LLM 请求（`Disposable.dispose()` / `Future.cancel(true)`），**并把已消耗的 token 结算掉**。
4. 释放连接，避免线程泄漏。

```java
@PostMapping(value = "/chat/{requestId}/cancel")
public ResponseEntity<Void> cancel(@PathVariable String requestId) {
    ChatSession session = registry.get(requestId);
    if (session != null) {
        session.cancel();          // 取消上游 + 关闭 emitter
        usageLedger.settle(requestId);  // 按已用量结算，不能白送
    }
    return ResponseEntity.accepted().build();
}
```

### 3.2 重新生成

不要简单地重发同一个请求。正确的「重新生成」要区分：

- **同参数重试**：温度不变，用于网络失败；
- **换种子重试**：温度略升，用于「换个说法」；
- **带反馈重试**：用户说「太长了」，把反馈作为新消息追加。

UI 上要给用户选择，而不是一个按钮三种行为随机发生。

### 3.3 编辑重发

用户改了第 3 条消息，第 4 条之后的回答就失效了。正确语义是**截断历史 + 从该点重新生成**，而不是「在末尾追加一条修改说明」。这要求后端消息表有 `parentId`/`seq`，支持分支对话（类似 git 的分支），否则历史会越来越脏。

### 3.4 引用与溯源

RAG 场景下，引用不是装饰，是信任的基础：

- 每个引用要有 `docId + span + snippet`，点击能定位到原文高亮。
- 引用编号与正文的角标要**双向对应**，不能只在末尾列一堆链接。
- 模型说的每一句不一定都有引用，UI 要能区分「有依据」与「模型推断」，而不是给整段都挂引用造成虚假可信。

### 3.5 错误恢复

错误提示要回答三个问题：**发生了什么、我的内容还在吗、我该怎么办**。

| 错误 | 文案 | 操作 |
|---|---|---|
| 上游超时 | 模型响应超时，已生成内容已保留 | 重试 / 换模型 |
| 限流 429 | 当前请求较多，N 秒后自动重试 | 自动倒计时重试 |
| 内容被拦截 | 该请求未通过安全检查 | 修改后重发 |
| 连接断开 | 网络中断，正在尝试恢复 | 自动重连（Last-Event-ID） |

---

## 四、后端职责：SSE 不只是「往外写字符串」

Java 侧要把四件事做对：事件编码、心跳、背压、取消传播。

### 4.1 SSE 编码与心跳

```java
@GetMapping(value = "/chat/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
public SseEmitter stream(@RequestParam String q, @RequestParam String requestId) {
    SseEmitter emitter = new SseEmitter(0L);   // 0 = 不超时，靠业务超时控制
    emitter.onTimeout(emitter::complete);
    emitter.onError(e -> log.warn("sse error {}", requestId, e));
    emitter.onCompletion(() -> registry.remove(requestId));

    executor.execute(() -> {
        try {
            emitter.send(SseEmitter.event().name("start")
                .data(Map.of("requestId", requestId), MediaType.APPLICATION_JSON));
            llm.stream(q)
                .doOnNext(chunk -> send(emitter, "delta", Map.of("text", chunk)))
                .doOnComplete(() -> {
                    send(emitter, "done", Map.of("finishReason", "stop"));
                    emitter.complete();
                })
                .doOnError(e -> {
                    send(emitter, "error", Map.of("code", classify(e), "retryable", isRetryable(e)));
                    emitter.complete();
                })
                .blockLast();
        } catch (Exception e) {
            emitter.completeWithError(e);
        }
    });
    return emitter;
}
```

生产上还有几个必要配置：

- **心跳**：每 15~30 秒发一个 `: ping\n\n` 注释行，防止 Nginx/云 LB 按空闲超时断开。`proxy_read_timeout` 必须大于心跳间隔。
- **禁用代理缓冲**：`X-Accel-Buffering: no` 或 Nginx `proxy_buffering off`，否则用户会看到「一次性吐出」。
- **压缩要慎用**：gzip 会缓冲小片段，破坏流式效果；SSE 一般不开压缩，或只在大于阈值时开。
- **连接数**：SSE 占长连接，Tomcat 的 `maxConnections` 要按「在线用户数」而不是 QPS 估算；虚拟线程可以显著降低成本，但要注意 pinning 与下游阻塞调用。

### 4.2 取消传播：客户端断开必须向上游传导

```java
emitter.onCompletion(() -> {
    // 浏览器关闭 / 用户点停止 / 网络断开，都会触发
    Disposable d = registry.remove(requestId);
    if (d != null && !d.isDisposed()) {
        d.dispose();     // 取消上游 LLM 流
    }
});
```

没有这一步，用户关掉页面后上游还在生成，token 照算、钱照花、线程照占。这是流式应用最常见的成本泄漏点。

### 4.3 幂等：重连不能重复扣费

断线重连时，前端带 `Last-Event-ID` 或 `requestId` 重连，后端要能：

- 若该 `requestId` 仍在生成：**接着推**，不重新调用模型；
- 若已完成：直接回放已生成内容 + `done`；
- 若已失败：返回错误事件，不自动重试（避免重复副作用）。

实现上用一个 `ConcurrentHashMap<String, StreamSession>` 保存「缓冲区 + 状态 + 订阅者」，缓冲区设上限（比如最近 200 个事件），超出的丢弃但保留完整文本快照。

---

## 五、度量：交互层的四个核心指标

| 指标 | 定义 | 目标 | 异常含义 |
|---|---|---|---|
| TTFT | 请求到第一个 token | < 800ms | 上游慢/排队/首包被缓冲 |
| ITL | 相邻 token 间隔 | < 50ms P95 | 上游限速/网络抖动 |
| 完成率 | `done` / 总请求 | > 95% | 超时、断连、上游错误 |
| 中断率 | 用户主动停止占比 | 观察值 | 过高说明啰嗦或答非所问 |
| 重试率 | 重新生成 / 总请求 | < 15% | 质量或提示词问题 |
| 任务成功率 | 业务目标达成 | 按场景 | 最终北极星 |

特别提醒：**不要用「平均响应时间」衡量流式体验**。一个 20 秒生成、0.5 秒出首字的回答，体感远好于 5 秒才出首字、总共 6 秒的回答。TTFT 和 ITL 才是用户真正感知的延迟。

---

## 六、六个生产坑

1. **代理缓冲**：本地测流式正常，上线变成一次性输出。99% 是 Nginx `proxy_buffering on` 或 CDN 缓冲。加 `X-Accel-Buffering: no` 并确认 CDN 支持流式。
2. **心跳缺失**：用户停留 60 秒看长回答，中间某段模型「思考」，连接被 LB 静默断开，前端表现为「卡住」。心跳 + 客户端超时重连是标配。
3. **取消不彻底**：只关了 SSE，上游还在跑。必须 `dispose()` 并结算已用 token。
4. **UI 组件注入**：让模型输出 HTML 或组件名，前端动态渲染。XSS 与任意组件加载风险极高，必须白名单 + schema 校验。
5. **无障碍缺失**：`aria-live="polite"` 让屏幕阅读器逐 token 播报，用户体验灾难。正确做法是**按句子/段落粒度**更新 live region，或者只在完成时播报。
6. **移动端后台断连**：切后台再回来，连接已断且前端不知道。重连 + 快照回放，比「重新生成一遍」便宜得多。

---

## 七、面试追问

**Q1：SSE、WebSocket、长轮询怎么选？**
服务端单向推送选 SSE（HTTP 兼容、自动重连、实现简单）；需要双向（语音、协同编辑）选 WebSocket；老环境不支持 SSE 才用长轮询。LLM 文本流 99% 的场景 SSE 足够。

**Q2：生成式 UI 和低代码平台有什么区别？**
低代码是「人拖拽生成配置」，生成式 UI 是「模型生成配置」。相同点是都受限于组件白名单与 schema；不同点是生成式 UI 必须假设**模型会输出非法/恶意内容**，所以校验和降级要求更高。

**Q3：为什么流式阶段不能直接执行工具调用？**
因为参数可能不完整或被后续 chunk 修正，提前执行会造成重复副作用。正确做法是等完整参数 + schema 校验 + 幂等键，再执行。工具调用可以在流中「展示进度」，但不能「边流边执行」。

**Q4：如何降低 TTFT？**
四个方向：模型侧（更小的模型/更快的推理）、请求侧（缩短 prompt、减少检索耗时）、传输侧（禁用缓冲、就近接入）、渲染侧（先出骨架、首字优先）。多数团队最后发现**检索耗时**才是 TTFT 的大头。

**Q5：多轮对话里 UI 状态放哪？**
放前端 + 服务端各一份：前端负责即时交互，服务端存「消息 + 组件状态 + 版本」。刷新页面要能恢复到最后一次完整状态，未完成的流用快照回放，不要重新生成。

### 落地检查清单

- [ ] 事件协议有 start/delta/tool/ui/citation/usage/error/done
- [ ] 心跳 + 禁缓冲 + 断线重连（Last-Event-ID）
- [ ] 取消能传到上游并结算 token
- [ ] 生成式 UI 组件白名单 + props schema 校验 + 降级
- [ ] 流式只展示，写操作等完整响应
- [ ] TTFT/ITL/完成率/中断率/重试率有看板
- [ ] 无障碍按句子粒度播报
- [ ] 刷新/切后台能恢复状态

AI 应用的交互层，本质是把「模型的不确定性」包装成「用户可理解、可控制的过程」。模型你换不了，但**首字快不快、能不能停、错了能不能救**，全在工程手里。这部分做扎实，产品体验的差距比换一个更强的模型更明显。
