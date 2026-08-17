---
title: 【系统设计】支付系统架构设计：对账、幂等、资金安全与高可用
date: 2026-08-17 08:00:00
tags:
  - 系统设计
  - 支付
  - 高可用
  - 架构
categories:
  - 系统设计
  - 架构
author: 东哥
---

# 【系统设计】支付系统架构设计：对账、幂等、资金安全与高可用

## 一、支付系统为什么难做？

支付系统是**"钱"的系统**，对一致性、安全性、可追溯性的要求远超普通业务系统。面试中"设计一个支付系统"是系统设计类的压轴题，考察点集中在：

- **资金安全**：不能多扣、不能少扣、不能重复扣
- **一致性**：支付状态、订单状态、账务记录三方必须最终一致
- **对账能力**：和微信/支付宝/银行的对账单能对上
- **高可用**：支付挂 1 分钟，业务可能损失惨重

本文从架构分层讲到核心链路，把支付系统的设计要点一次讲清。

## 二、整体架构分层

```
┌─────────────────────────────────────────────┐
│              接入层（网关/风控/限流）          │
├─────────────────────────────────────────────┤
│              交易核心（收单/下单/支付确认）      │
├─────────────────────────────────────────────┤
│         账务核心（记账/流水/余额）             │
├─────────────────────────────────────────────┤
│         对账中心（渠道对账/差错处理）           │
├─────────────────────────────────────────────┤
│         渠道层（微信/支付宝/银联/银行网关）      │
└─────────────────────────────────────────────┘
```

### 核心模块职责

| 模块 | 职责 | 关键技术 |
|------|------|---------|
| 支付网关 | 统一入口、签名验签、限流 | 签名（RSA/SM2）、令牌桶限流 |
| 交易系统 | 创建支付单、状态机流转 | 分布式事务、幂等表 |
| 账务系统 | 记账、冻结、解冻、清分 | 借贷记账法、流水表 |
| 渠道网关 | 对接三方渠道、异步通知处理 | 重试、回调幂等 |
| 对账系统 | 拉取渠道账单、逐笔核对 | 对账文件解析、差错处理 |
| 风控系统 | 交易风控、反欺诈 | 规则引擎、实时计算 |

## 三、核心支付链路（以微信支付为例）

### 1. 下单（预支付）

```
客户端 → 商户后端 → 支付网关(创建支付单) → 微信下单API → 返回 prepay_id
```

支付单状态机：

```
待支付 → 支付中 → 已支付 → 已退款 → 已关闭
              ↘ 支付失败 → 待支付（可重试）
```

**注意**：支付单（payment）和业务订单（order）是**两个概念、两张表**。订单是业务视角，支付单是资金视角，通过 `order_id` 关联。一个订单可以有多笔支付单（部分支付、失败重试），支付单必须唯一约束（`payment_no` 唯一索引）。

### 2. 支付回调（异步通知）

**回调处理是支付系统最容易出 bug 的地方**，核心规则：

```java
@PostMapping("/wxpay/notify")
public String notify(@RequestBody String xml, @RequestHeader("Wechatpay-Signature") String sign) {
    // 1. 验签：用微信平台证书验证签名，防止伪造回调
    if (!verifySign(xml, sign)) {
        return fail("验签失败");
    }

    // 2. 幂等处理：以微信支付单号+商户支付单号为唯一键
    //    先查本地支付单，已处理直接返回成功
    Payment payment = paymentService.getByOutTradeNo(outTradeNo);
    if (payment.getStatus() == PAID) {
        return success();  // 重复回调，直接返回成功
    }

    // 3. 更新状态（用状态机 + 乐观锁，防止并发重复入账）
    boolean updated = paymentService.markPaid(payment, wxTransactionId);
    if (!updated) {
        return fail("状态冲突，稍后重试");  // 让微信稍后重推
    }

    // 4. 触发业务：发 MQ 让订单系统确认订单
    mqSender.send(OrderConfirmEvent.of(orderId, paymentNo));
    return success();
}
```

三个铁律：**验签 → 幂等 → 状态机更新**。

### 3. 查询兜底

回调可能丢失（网络故障、服务重启），所以要有**主动查询**兜底：

```java
// 定时任务：扫"支付中"超过 N 分钟的支付单，主动查渠道
@Scheduled(fixedDelay = 60_000)
public void queryPendingPayments() {
    List<Payment> pendings = paymentService.findPendingOlderThan(5, TimeUnit.MINUTES);
    for (Payment p : pendings) {
        WxPayQueryResult result = wxPayClient.queryOrder(p.getPaymentNo());
        if (result.isSuccess()) {
            paymentService.markPaid(p, result.getTransactionId());
        } else if (result.isClosed()) {
            paymentService.close(p);
        }
    }
}
```

**回调 + 定时查询双保险**，是支付一致性的第一道防线。

## 四、幂等设计：支付系统的命根子

### 幂等场景盘点

| 场景 | 风险 | 幂等方案 |
|------|------|---------|
| 用户重复点支付 | 生成多个支付单 | 支付单号由业务单号 + 幂等键生成，唯一索引 |
| 渠道重复回调 | 重复入账 | 支付单状态机 + 唯一索引（渠道流水号） |
| 回调重试 | 重复通知业务 | MQ 消费端幂等（业务单据号去重） |
| 退款重复提交 | 重复退款 | 退款单唯一键 + 状态机 |

### 幂等实现三板斧

1. **唯一索引兜底**：`payment_no`、`refund_no`、渠道流水号建唯一索引，重复插入直接报错
2. **状态机约束**：只有"待支付 → 已支付"合法，已支付的单子拒绝再次入账
3. **分布式锁**：同订单并发操作时（如同时回调 + 主动查询结果），用 `orderId` 做分布式锁串行化

```java
// 用唯一索引 + 状态机，天然幂等
public boolean markPaid(Payment p, String channelTxId) {
    // UPDATE ... SET status='PAID', channel_tx_id=? 
    // WHERE id=? AND status='PENDING'   -- 乐观锁，返回影响行数
    int rows = paymentMapper.markPaidIfPending(p.getId(), channelTxId);
    return rows == 1;
}
```

## 五、账务与资金安全：借贷记账法

支付成功后要**记账**。业务系统可以记流水，但资金账务系统必须用**复式记账（借贷记账法）**：

```sql
-- 资金流水表（不可修改，只追加）
CREATE TABLE fund_flow (
    id BIGINT PRIMARY KEY,
    flow_no VARCHAR(32) UNIQUE,        -- 流水号，全局唯一
    account_no VARCHAR(32),            -- 账户
    direction TINYINT,                 -- 1=借 2=贷
    amount DECIMAL(18,2),
    biz_type VARCHAR(32),              -- 支付/退款/提现...
    ref_no VARCHAR(64),                -- 关联单据号
    status TINYINT,                    -- 1=待入账 2=已入账 3=已冲正
    create_time DATETIME
);
```

**记账铁律**：

1. **有借必有贷，借贷必相等**：支付成功 = 借"用户待清算账户" + 贷"商户收入账户"，两条流水一起落库（本地事务保证原子性）
2. **流水只追加不修改**：记错了用**冲正**（反向流水），绝不 UPDATE 原流水——这是审计的基础
3. **金额用 DECIMAL(18,2)**，绝不用 double/float
4. **分账/清结算**：平台抽佣、渠道手续费、分给多商户，都要按规则拆分成多笔分录

## 六、对账系统：最后的防线

即使有回调、有查询，还是可能漏单（比如回调丢了、查询时机不对）。**对账**是最终防线：

```
每日凌晨：拉取渠道账单文件（微信/支付宝对账单 CSV）
→ 解析为标准格式
→ 与本系统支付单比对（按渠道流水号/金额/时间）
→ 输出差异：长款（我方有渠道无）/ 短款（渠道有我方无）/ 金额不符
→ 差错单进入人工/自动处理流程
```

```java
public void reconcile(LocalDate date) {
    List<ChannelBillItem> channelItems = channelClient.downloadBill(date);
    List<Payment> localPayments = paymentService.findByDate(date);

    // 以渠道流水号建立索引，双集合比对
    Map<String, ChannelBillItem> channelMap = channelItems.stream()
            .collect(Collectors.toMap(ChannelBillItem::getTxId, Function.identity()));

    for (Payment p : localPayments) {
        ChannelBillItem item = channelMap.get(p.getChannelTxId());
        if (item == null) {
            reconcileService.createDiff(DiffType.LONG_BILL, p);   // 长款：我方已付，渠道无记录（疑似异常）
        } else if (!item.getAmount().equals(p.getAmount())) {
            reconcileService.createDiff(DiffType.AMOUNT_MISMATCH, p);
        }
        channelMap.remove(p.getChannelTxId());
    }
    // 剩下的 channelMap 条目就是"短款"：渠道有、我方没有（可能是漏单）
    channelMap.values().forEach(item -> reconcileService.createDiff(DiffType.SHORT_BILL, item));
}
```

对账差异处理原则：**长款优先拦截资金风险（可能被黑客利用），短款优先补单（用户付了钱要发货）**。

## 七、高可用设计

1. **读多写少分离**：支付单查询走只读库，写走主库
2. **渠道降级**：微信支付挂了下发到支付宝？不行——**渠道是强依赖**，所以要做：渠道超时快速失败 + 重试队列 + 多渠道容灾（多商户号、多银行）
3. **异步化**：回调处理 → 发 MQ 解耦，业务确认异步执行，支付核心只保证"状态正确"
4. **限流与风控**：网关层令牌桶限流，风控规则（单用户频次、大额、异常时段）前置拦截
5. **灰度与演练**：支付链路要做故障演练（渠道超时、MQ 积压、DB 主从切换），保证应急预案有效
6. **监控告警**：支付成功率、回调延迟、对账差异数、未决单量（支付中状态堆积量）都要有指标和告警

## 八、面试常见追问

**Q1：回调丢了怎么办？**
三层兜底：① 定时任务主动查单（支付中状态超过阈值就去渠道查询）；② 每日对账发现漏单补单；③ 对极端情况提供用户端"刷新支付状态"入口触发查询。

**Q2：重复回调怎么保证只入账一次？**
验签后按渠道流水号查本地支付单，已支付直接返回成功；更新用乐观锁（`WHERE status='PENDING'`），影响行数为 0 则拒绝；支付单号唯一索引兜底。

**Q3：用户支付成功但订单系统没确认（数据不一致）？**
回调处理时发 MQ 通知订单系统，MQ 消费失败会重试；重试仍失败进死信队列人工处理；最终对账兜底。原则是**支付单状态以渠道为准，业务状态允许短暂延迟，最终一致**。

**Q4：退款超时、重复退款怎么处理？**
退款也走"退款单 + 状态机 + 唯一键"，与支付同构；渠道退款结果靠回调 + 主动查询；退款单幂等键是 `refund_no`，重复提交直接返回原退款单。

**Q5：怎么保证金额不错？**
数据库用 DECIMAL；记账用复式记账（借贷相等）；支付/退款金额与渠道回调金额比对，不符即告警挂起；对账逐笔核对金额。

## 总结

支付系统的设计核心就四个词：**幂等、状态机、对账、复式记账**。幂等防重复，状态机保顺序，对账兜底漏单，复式记账保资金平衡。面试时按"下单 → 回调 → 查单 → 记账 → 对账"的主链路讲，再补充幂等和高可用细节，就能体现出对"钱"的敬畏和架构功底。
