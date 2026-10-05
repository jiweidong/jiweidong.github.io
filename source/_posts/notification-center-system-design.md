---
title: 面试官：设计一个推送通知中心，怎么保证"不重、不漏、不扰民"？
date: 2026-10-05 08:30:00
tags:
  - 系统设计
  - 消息推送
  - 幂等
  - 限流
  - 面试
categories:
  - 系统设计
  - 后端面试
author: 东哥
---

# 面试官：设计一个推送通知中心，怎么保证"不重、不漏、不扰民"？

## 面试官：订单支付成功后要给用户发通知，你怎么设计？

这个问题的第一反应通常是："发个短信不就行了？"

但顺着问下去，面试官的三个追问会把大部分人问穿：

1. 用户没收到怎么办？（**不漏**）
2. 用户收到两条怎么办？（**不重**）
3. 用户半夜收到一条营销推送，投诉了怎么办？（**不扰民**）

这三问，就是通知中心架构的全部核心。**通知中心是典型的"看起来简单、做起来全是坑"的系统**——它同时踩中了异步、幂等、多级降级、频控、可观测性五个高并发课题。

---

## 一、通知中心到底管什么

先划清边界。通知中心和 IM 的区别：

| 维度 | IM | 通知中心 |
| --- | --- | --- |
| 触发方 | 用户主动 | 系统事件驱动 |
| 渠道 | 长连接 | 多渠道（Push/短信/邮件/站内信/微信） |
| 可靠性 | 必达有序 | 尽力送达 + 可追溯 |
| 语义 | 会话 | 模板 + 变量 |
| 关注点 | 连接 | 触达率、成本、骚扰控制 |

通知中心要解决四个问题：

```text
1. 谁来发     → 业务系统通过统一 API / MQ 事件投递
2. 怎么发     → 模板渲染 + 渠道编排 + 供应商路由
3. 发得对不对 → 幂等去重 + 状态追踪 + 回执
4. 该不该发   → 频控、免打扰、退订、聚合降噪
```

按这四点画架构，链路就非常清晰：

```text
业务服务 ──(统一事件/API)→ 接入层(鉴权+校验+幂等)
                              ↓
                        消息队列(Kafka)
                              ↓
                     ┌────────┴────────┐
              通知编排服务           频控/免打扰服务
              (模板渲染、渠道决策)      (Redis 计数)
                     ↓
              渠道下发(短信/邮件/Push/站内信)
                     ↓
              回执收集 → 状态机 → 重试/降级 → 统计
```

---

## 二、消息模型：模板 + 变量 + 渠道策略

通知的第一原则：**业务方不应该拼接消息内容，只提交"模板 ID + 变量"。**

```json
{
  "bizId": "order_paid",
  "traceId": "pay_20261005_abc123",
  "userId": 10086,
  "templateCode": "ORDER_PAID",
  "params": { "orderNo": "2026100512345", "amount": "199.00" },
  "channels": ["PUSH", "SMS"],
  "priority": "HIGH"
}
```

- `traceId` / `bizId`：**幂等键**，同一个业务事件多次投递只发一次；
- `templateCode`：内容与代码解耦，运营可改文案、可多语言；
- `channels`：期望渠道，实际渠道由**渠道决策引擎**根据用户设置、成本、到达率决定；
- `priority`：HIGH 走实时通道，LOW 走批量聚合通道。

模板渲染要防注入（变量里的 `{}` 不能污染模板），也要做长度截断（短信 70 字/条），并且**渲染失败必须能回退到默认文案**，不能让通知静默消失。

```java
public String render(String templateCode, Map<String, Object> params) {
    NotificationTemplate tpl = tplCache.get(templateCode);   // 本地缓存 + 热更新
    if (tpl == null) {
        log.warn("template missing: {}", templateCode);
        return null;                                        // 触发兜底逻辑
    }
    try {
        return tpl.render(params);
    } catch (Exception e) {
        log.error("render fail, fallback to default", e);
        return tpl.getDefaultContent();
    }
}
```

---

## 三、不漏：重试、降级、兜底

"不漏"最容易被误解成"可靠消息"。但真正的漏斗是多级的，每一级都会丢：

```text
业务事件丢失 → 通知服务宕机 → 渠道下发失败 → 供应商失败 → 用户设备没收到
```

逐级对抗：

### 3.1 事件不丢：本地消息表 / 事务消息

业务侧写业务数据时，在**同一个事务**里写一条通知事件到本地消息表，由定时任务/CDC 投递到 Kafka。这是"业务成功则通知一定被投递"的唯一可靠做法。

```java
@Transactional
public void paySuccess(Order order) {
    orderMapper.markPaid(order.getId());
    // 同一事务写通知事件（本地消息表）
    notifyEventMapper.insert(NotifyEvent.of(order, "ORDER_PAID"));
}

// 异步投递器（幂等 + 至少一次投递）
@Scheduled(fixedDelay = 1000)
public void dispatchPending() {
    List<NotifyEvent> list = notifyEventMapper.lockPending(500);
    for (NotifyEvent e : list) {
        kafkaTemplate.send("notify-events", e.getBizId(), e);   // 同 bizId 同分区，天然有序
        notifyEventMapper.markSent(e.getId());
    }
}
```

### 3.2 下发不丢：状态机 + 多级重试

通知有明确的生命周期，用状态机管理：

```text
INIT → RENDERED → SENDING → SENT → DELIVERED
                    ↓ fail
                 RETRY(1..N) → FAILED → FALLBACK（换渠道）
```

重试策略要点：

- **指数退避**：1s、5s、30s、5min、30min，最多 N 次；
- **区分错误类型**：供应商限流（可重试）、用户号码无效（不可重试，直接失败）；
- **渠道降级**：Push 失败 → 短信兜底；短信失败 → 站内信 + APP 弹窗（下次拉起时展示）；
- **兜底不可忘**：站内信是"永不失败"的渠道（写 DB 即可），是所有通知的最终保底。

```java
public void onSendFail(Notification n, ChannelError err) {
    if (n.getRetryCount() < MAX_RETRY && err.isRetryable()) {
        schedule(n, backoff(n.getRetryCount()));
    } else if (n.hasNextChannel()) {
        n.setChannel(n.nextChannel());
        n.setRetryCount(0);
        doSend(n);
    } else {
        // 最终兜底：站内信 + 埋点告警
        inboxService.save(n.toInbox());
        alertService.notifyOps(n);
    }
}
```

### 3.3 用户没收到怎么办

- **回执机制**：Push 供应商（APNs/FCM/华为/小米）都有送达回执，采集后更新状态机；
- **触达率监控**：按渠道、供应商、用户群维度看到达率曲线，下跌即告警；
- **多供应商并行/热备**：短信同时接 2~3 家，按质量分路由（成功率、到达时延、成本加权）。

---

## 四、不重：幂等是通知的生命线

重复通知比漏发更伤——用户会被"支付成功"发三次的心态搞崩。

**幂等的三级防线**：

### 第一级：业务幂等键（推荐首选）

```text
唯一键 = bizId + templateCode + userId
在发送前用 Redis SETNX(ttl=24h) 抢占
```

```java
public boolean tryAcquire(String idempotentKey) {
    Boolean ok = redis.opsForValue().setIfAbsent(idempotentKey, "1", 24, TimeUnit.HOURS);
    return Boolean.TRUE.equals(ok);
}
```

### 第二级：数据库唯一索引兜底

Redis 会丢（重启、主从切换），所以**必须**还有 DB 唯一索引：

```sql
CREATE TABLE t_notification (
  id          BIGINT PRIMARY KEY AUTO_INCREMENT,
  biz_id      VARCHAR(64)  NOT NULL,
  template_code VARCHAR(64) NOT NULL,
  user_id     BIGINT       NOT NULL,
  channel     VARCHAR(16)  NOT NULL,
  status      TINYINT      NOT NULL,
  retry_count INT          NOT NULL DEFAULT 0,
  create_time DATETIME     NOT NULL,
  UNIQUE KEY uk_idem (biz_id, template_code, user_id, channel)
) ENGINE=InnoDB;
```

注意 `biz_id` 要选**业务唯一且稳定**的字段（订单号、支付流水号），不能选"每次都变的 UUID"，否则幂等直接失效。

### 第三级：渠道侧去重

短信/微信模板消息本身有频次限制，同内容短时间重复提交会被供应商拒，这也是天然兜底。

**面试加分点**：主动说明"幂等键的 TTL 要略大于重试窗口 + 最大人工重推窗口"，并且"换渠道要生成新的幂等键（channel 参与唯一键），否则降级到短信会被误判为重复"。

---

## 五、不扰民：频控、聚合、免打扰

这是通知中心最"产品化"的部分，也是最体现工程审美的地方。

### 5.1 频控：多维度、分层级

```text
用户级：单用户单渠道 10 条/天（营销类）、不限（交易类）
模板级：同一模板对同一用户 1 条/天
全局级：单渠道总 QPS（保护供应商配额）
```

实现用 Redis 计数器 + 滑动窗口，注意**交易类通知必须豁免频控**（支付、验证码不能因为频控被拦）。

```java
public boolean allowSend(Notification n) {
    if (n.isTransactional()) return true;          // 交易类豁免
    if (userSetting.isMuted(n.getUserId())) return false;   // 免打扰时段
    String k = "freq:" + n.getUserId() + ":" + today();
    Long c = redis.opsForValue().increment(k);
    redis.expire(k, Duration.ofDays(1));
    return c != null && c <= 10;
}
```

### 5.2 聚合降噪

- **时间窗聚合**：10 分钟内的 5 条点赞合并为"xxx 等 5 人赞了你"；
- **同类合并**：同一订单的多条物流状态，只推最终态 + 汇总；
- **内容折叠**：低频非关键通知进"消息盒子"，只角标提示，不弹窗、不响铃。

聚合通常用 Redis ZSet 做窗口缓冲 + 定时 flush。

### 5.3 免打扰与退订

- 免打扰时段（22:00 ~ 08:00）只投站内信，不投 Push/SMS；
- 按业务线粒度退订（用户可关掉"营销"但保留"交易"）；
- **重要通知要能突破免打扰**（验证码、安全提醒），需要白名单机制。

---

## 六、存储、回执与可观测

### 6.1 存储分层

| 数据 | 存储 | 保留 |
| --- | --- | --- |
| 通知记录 | MySQL 分表（按 user_id 或时间） | 3~6 个月 |
| 站内信 | MySQL + Redis 未读数 | 长期 |
| 回执流水 | ClickHouse / ES | 1 年（分析用） |
| 幂等键 | Redis | 24h |

未读数用 Redis `HINCRBY` 或 `INCR`，**不要每次 `COUNT(*)`**。

### 6.2 回执与追踪

每条通知携带 `traceId`，全链路串起来：

```text
业务事件 → 通知服务 → 渠道网关 → 供应商 → 客户端 → 点击 → 转化
```

这样能算出：**触达率、打开率、点击率、退订率、投诉率**。有了这些指标，才能持续优化"该不该发/发多少"。

### 6.3 告警

- 各渠道到达率环比下跌 > 20% → 告警；
- Kafka 积压 > 阈值 → 告警；
- 单供应商失败率 > 10% → 自动切换；
- 投诉率上升 → 触发运营侧降频。

---

## 七、面试常见追问

**Q1：为什么用 Kafka 而不是直接同步发短信？**
同步发会把短信供应商的延迟引入业务主链路（支付成功要等 300ms 发短信），且无法重试、无法削峰。异步解耦是通知中心的必然选择。

**Q2：Kafka 重复消费怎么办？**
同 `bizId` 做分区键保证有序，加上幂等键 + DB 唯一索引，重复消费天然被吃掉。这就是"至少一次投递 + 消费端幂等"的标准组合。

**Q3：怎么保证按用户顺序？**
按 `userId` 分区，保证同一用户的通知在 Kafka 内有序；若嫌热点，用 `bizId % N` 再在消费端按 `userId` 做本地串行队列。

**Q4：营销推送怎么防止超发预算？**
在渠道下发前加**配额预扣**（Redis Lua 原子扣减），发出即扣，回执失败再返还。绝不能用"先发后统计"。

**Q5：站内信为什么能当兜底渠道？**
因为它只依赖自己的 DB，不依赖任何外部供应商，失败概率最低。所有通知最终都能落到站内信，保证"可查"。

---

## 总结

通知中心的三条主线，一句话记住：

- **不漏**靠"本地消息表 + 状态机 + 多级重试 + 渠道降级 + 站内信兜底"五件套；
- **不重**靠"业务幂等键 + DB 唯一索引 + 渠道去重"三层防线；
- **不扰民**靠"多维频控 + 聚合降噪 + 免打扰/退订 + 交易豁免"。

这道题最考验的不是技术深度，而是**你有没有真的站在用户和运营的角度想过问题**——能主动提出"交易类通知必须豁免频控""站内信做最终兜底""投诉率驱动降频"，面试官就知道你做过真实系统。
