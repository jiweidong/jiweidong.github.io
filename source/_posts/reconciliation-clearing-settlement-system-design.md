---
title: 【系统设计】清结算与对账系统架构设计：账务模型、双边对账、差错处理与资金安全全解析
date: 2026-10-09 08:15:00
tags:
  - Java
  - 系统设计
  - 架构
  - 支付
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】清结算与对账系统架构设计：账务模型、双边对账、差错处理与资金安全全解析

## 面试官：支付做完就完了吗？钱怎么和商户、渠道对平？

很多人做支付只想到"下单 + 扣款 + 回调"，但真正让系统"能上线"的是后半段——**清分（Clearing）、结算（Settlement）、对账（Reconciliation）**。

面试官一追问就很致命：

1. 用户付了钱，钱在哪个账户？怎么记账？
2. 微信账单和你系统差 3 分钱，你怎么定位？
3. T+1 给商户打款，打多了怎么办？
4. 每天几百万笔，对账怎么做才能在一小时内跑完？
5. 渠道回调丢了、重复回调了，账怎么才能对平？

这篇文章把清结算/对账的**账务模型、对账体系、差错处理、资金安全**讲清楚。

## 一、概念先理清：支付 ≠ 清算 ≠ 结算 ≠ 对账

| 概念 | 英文 | 含义 |
| --- | --- | --- |
| 支付 | Payment | 用户完成资金动作（扣款成功） |
| 清分 | Clearing | 算清楚"这笔钱该归谁、分多少"（按费率、分润拆分） |
| 结算 | Settlement | 把清分结果变成真实的资金划转（打款给商户） |
| 对账 | Reconciliation | 平台、渠道、商户三方账单核对，找出差异 |

关系链：

```
支付成功
   → 记账（入账 / 待结算账户）
   → 清分（扣手续费、分润、算出净额）
   → 结算（T+1 打款，生成结算单）
   → 对账（平台 vs 渠道 vs 商户 vs 银行）
   → 差错处理（补单 / 冲正 / 挂账）
```

## 二、账务模型：一切的基础

### 2.1 复式记账（Double-Entry）

金额不能"改"只能"记"。每一笔业务都生成至少两条分录（借贷相等）：

| 流水号 | 账户 | 方向 | 金额 |
| --- | --- | --- | --- |
| P20261009001 | 用户余额 | 借（+） | 100.00 |
| P20261009001 | 平台待结算 | 贷（−） | 100.00 |

好处：

- **可审计**：任何时刻所有账户余额之和 = 0（或 = 初始值）。
- **可追溯**：出问题能追到具体分录。
- **可校验**：用"借贷平衡"做完整性检查。

### 2.2 账户体系设计

| 账户类型 | 用途 | 说明 |
| --- | --- | --- |
| 用户余额账户 | 用户充值/提现 | 可用 + 冻结 |
| 平台收入账户 | 手续费收入 | 平台自己的钱 |
| 商户待结算账户 | 商户应收 | 清算后、打款前 |
| 渠道过渡账户 | 三方渠道在途资金 | 用于对账 |
| 平台垫资账户 | 补贴、退款垫付 | 需风控 |

**"可用余额 + 冻结余额"是最小设计**，任何涉及扣款的场景都要先冻结、后扣减，防止并发超扣。

```java
public enum AccountStatus { NORMAL, FROZEN, CLOSED }

public class Account {
    private Long id;
    private Long ownerId;
    private String currency;      // 多币种必留
    private BigDecimal available; // 可用
    private BigDecimal frozen;    // 冻结
    private Long version;         // 乐观锁
}
```

### 2.3 流水与余额分离（重要）

**不要把余额当唯一真相**。正确做法：

- **流水表（journal）**：只增不改，不可变（immutable），是真相来源。
- **余额表（balance）**：由流水汇总出来的"快照 / 缓存"，用于快速查询。

日终要做**"余额 = 流水汇总"的校验**，不一致就是事故。

```sql
-- 校验：某账户某日流水汇总是否等于余额变动
SELECT account_id,
       SUM(CASE WHEN direction='CREDIT' THEN amount ELSE -amount END) AS delta
FROM account_journal
WHERE account_id = #{id} AND biz_date = #{date}
GROUP BY account_id;
```

### 2.4 幂等是资金系统的生命线

每一笔资金操作都必须有**唯一业务号（bizNo）**，并建唯一索引：

```sql
CREATE TABLE account_journal (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    biz_no        VARCHAR(64)  NOT NULL COMMENT '业务唯一号',
    biz_type      VARCHAR(32)  NOT NULL COMMENT '业务类型',
    account_id    BIGINT       NOT NULL,
    direction     VARCHAR(8)   NOT NULL COMMENT 'DEBIT/CREDIT',
    amount        DECIMAL(18,2) NOT NULL,
    biz_date      DATE         NOT NULL,
    create_time   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_bizno_dir (biz_no, direction, account_id)
) COMMENT '账务流水，只增不改';
```

插入冲突即代表重复请求，直接返回成功——这就是幂等。

## 三、清分：钱该归谁

清分按**规则链**计算：

```
原始金额
  → 渠道手续费（按签约费率，可能有封顶/阶梯）
  → 平台服务费
  → 分润（多级商户、代理商）
  → 营销补贴（平台承担或商户承担）
  = 商户净结算额
```

规则用**配置化 + 版本化**，不能写死在代码：

```java
public interface ClearingRule {
    ClearingResult clear(ClearingContext ctx);
}

// 费率：支持固定值、百分比、阶梯、封顶
public class RateRule implements ClearingRule {
    public BigDecimal fee(BigDecimal amount, RateConfig cfg) {
        BigDecimal fee = amount.multiply(cfg.getRate());
        if (cfg.getMinFee() != null) fee = fee.max(cfg.getMinFee());
        if (cfg.getCapFee() != null) fee = fee.min(cfg.getCapFee());
        return fee.setScale(2, RoundingMode.HALF_UP);
    }
}
```

**关键原则：清分只产生"应收应付"记录，不动真实资金。** 真实资金在结算阶段划转。

## 四、结算：把账变成钱

### 4.1 结算流程

```
T 日业务数据
  → T+1 凌晨 生成结算单（结算金额 = 应收 − 手续费 − 已退款 − 冻结）
  → 风控/合规校验（黑名单、限额、证件到期）
  → 生成打款指令 → 提交银行/渠道
  → 银行回执 → 更新结算单状态
  → 冲销待结算账户，写入银行过渡账户
```

### 4.2 结算单状态机

```java
public enum SettlementStatus {
    INIT,            // 生成
    RISK_REVIEW,     // 风控中
    APPROVED,        // 审核通过
    PAYING,          // 打款中
    PAID,            // 已到账
    FAILED,          // 打款失败
    REJECTED,        // 驳回
    REVERSED         // 冲正
}
```

用状态机 + 乐观锁保证：**一笔结算不会被打两次款**。

```sql
UPDATE settlement SET status = 'PAYING', update_time = NOW()
WHERE id = #{id} AND status = 'APPROVED';
-- rows == 1 才能继续提交给银行
```

### 4.3 结算与打款的"两阶段"

打款是外部系统调用，必须**先落库状态、再调外部**（outbox 模式）：

```java
@Transactional
public void pay(Long settlementId) {
    // 1. 状态置为 PAYING 并落库（本地事务）
    int rows = settlementMapper.casStatus(settlementId, APPROVED, PAYING);
    if (rows == 0) return;                      // 已被处理，幂等
    // 2. 写打款指令（同一事务）
    payInstructionMapper.insert(new PayInstruction(settlementId, ...));
}

// 3. 独立 worker 读 PAYING 的指令去调银行，成功置 PAID，失败置 FAILED
```

这样即使调用银行超时（不知道成没成），也能靠**银行对账**回填最终状态——这就是为什么对账不是"锦上添花"，而是**资金正确性的最后防线**。

## 五、对账体系：核心中的核心

### 5.1 对账的层级

| 层级 | 对账双方 | 目的 |
| --- | --- | --- |
| 内部对账 | 业务库 vs 账务库 | 防漏记、错记 |
| 通道对账 | 平台 vs 微信/支付宝/银行 | 保证收付一致 |
| 商户对账 | 平台 vs 商户账单 | 保证商户认可 |
| 银行对账 | 平台银行账户 vs 银行流水 | 保证真实资金流一致 |

### 5.2 对账四步法

```
1. 拉取     从渠道下载对账单（文件/API），落 OSS 或本地
2. 解析     解析成标准格式，批量入库（对账临时表）
3. 比对     以业务单号为主键，双向 FULL OUTER JOIN
4. 处理     差异分流：补单 / 冲正 / 挂账 / 人工
```

比对的核心 SQL（简化）：

```sql
-- 平台有、渠道无  -> 可能渠道未成功，需查单
SELECT p.* FROM platform_bill p
LEFT JOIN channel_bill c ON p.trade_no = c.trade_no
WHERE c.trade_no IS NULL AND p.biz_date = #{date};

-- 渠道有、平台无  -> 可能回调丢失，需补单
SELECT c.* FROM channel_bill c
LEFT JOIN platform_bill p ON p.trade_no = c.trade_no
WHERE p.trade_no IS NULL AND c.biz_date = #{date};

-- 金额不一致
SELECT p.trade_no, p.amount AS p_amt, c.amount AS c_amt
FROM platform_bill p JOIN channel_bill c ON p.trade_no = c.trade_no
WHERE p.amount <> c.amount AND p.biz_date = #{date};
```

### 5.3 对账差异分类

| 差异类型 | 典型原因 | 处理 |
| --- | --- | --- |
| 平台有、渠道无 | 支付未成功 / 渠道延迟 | 查询渠道最终状态，必要时关单 |
| 渠道有、平台无 | 回调丢失 | **补单**（重放回调逻辑，幂等） |
| 金额不符 | 手续费差异 / 部分退款 | 人工核验 + 调整 |
| 状态不符 | 一方成功一方失败 | 以渠道为准 / 以资金流为准 |
| 重复单 | 重复回调 | 幂等去重 |
| 时间跨天 | 23:59 支付、00:00 回调 | 按渠道账期归属，设置容差 |

**"渠道有、平台无"是最危险的**——用户付了钱但系统不知道。必须建立**主动查单**机制（不是只等回调）：

```java
@Scheduled(fixedDelay = 60_000)
public void queryUnknownTrades() {
    List<Trade> unknown = tradeMapper.selectByStatusIn(
            List.of(TradeStatus.PAYING, TradeStatus.UNKNOWN), 30);
    for (Trade t : unknown) {
        ChannelResult r = channelClient.query(t.getTradeNo());   // 主动查询
        if (r.isSuccess()) {
            tradeService.handlePaySuccess(t.getTradeNo(), r);
        }
    }
}
```

### 5.4 对账的性能设计

几百万笔/天的对账，不能一条条比。要点：

1. **批量 + 分片**：按 `biz_date + 渠道 + 分片键` 并行处理，用线程池提吞吐。
2. **临时表 + 索引**：渠道账单先入临时表并对 `trade_no` 建索引，比对走索引连接。
3. **只比"变化"**：已对平的单据落状态位，重跑只处理差异。
4. **幂等重跑**：对账任务支持按天重跑，结果可覆盖，不能产生重复分录。
5. **增量 + 全量结合**：日常增量对账，周/月做全量兜底。

```java
// 分片并行对账
IntStream.range(0, SHARDS).parallel().forEach(shard -> {
    reconcileService.reconcile(channel, bizDate, shard, SHARDS);
});
```

**注意**：并行要用受控线程池（不要让并行流直接用 commonPool），并且每个 shard 独立事务，互不阻塞。

## 六、差错处理：不能只报警

**对账的目的不是"发现问题"，而是"处理问题"。** 差错处理要有闭环：

```
发现差异
  → 自动分类（可自动处理 / 需人工）
  → 自动处理：补单、冲正、重推
  → 人工处理：生成工单，指派+时限+留痕
  → 复核通过后调整账务（调整分录，不删原分录）
  → 归档，统计差异率
```

**账务调整原则：只增不改。** 调账也要走"冲正 + 重记"两条新分录，保留完整痕迹：

```java
// 冲正：反向写一条，抵消原分录
public void reverse(Long journalId, String reason) {
    AccountJournal origin = journalMapper.selectById(journalId);
    journalMapper.insert(new AccountJournal(
        "REVERSE_" + origin.getBizNo(),     // 冲正业务号唯一
        origin.getAccountId(),
        origin.getDirection().opposite(),
        origin.getAmount(),
        reason));
    // 同时写一条关联记录，标明冲正关系
}
```

## 七、资金安全与合规

| 风险点 | 措施 |
| --- | --- |
| 超扣 / 负余额 | 冻结机制 + 乐观锁 + 余额校验 |
| 重复打款 | 结算单状态机 + 幂等 + 打款指令唯一 |
| 内部人员篡改 | 分录不可变 + 操作留痕 + 双人复核 |
| 二清风险 | 平台不碰商户资金，走持牌机构 |
| 金额精度 | 整数"分"或 BigDecimal，禁止 double |
| 对账绕过 | 对账任务与业务解耦，独立账号只读业务库 |
| 数据泄露 | 账号脱敏、加密存储、最小权限 |

**金额精度**值得单独强调。Java 里绝对不能：

```java
double amount = 0.1 + 0.2;   // 0.30000000000000004
```

正确做法：用 `long` 存"分"或用 `BigDecimal`，且除法必须指定 `RoundingMode`：

```java
BigDecimal fee = amount.multiply(new BigDecimal("0.006"))
                        .setScale(2, RoundingMode.HALF_UP);
```

## 八、面试追问

**Q1：对账一定要 T+1 吗？能不能实时？**

可以做实时对账（准实时，秒级/分钟级）：通过渠道回调 + 主动查单 + 准实时比对，在交易发生后几分钟内发现异常。但**全量最终校验仍然要 T+1**，因为渠道账单通常次日才给全，且要处理跨天、延迟入账。**实时对账做预警，T+1 对账做兜底**是最佳实践。

**Q2：回调丢了怎么办？**

三层防护：
1. **主动查单**（定时 + 延迟队列）——最可靠；
2. **渠道账单 T+1 对账**——兜底；
3. **用户侧可见**（"支付处理中"页面 + 手动刷新）——最后一道。
绝不能"只依赖回调"。

**Q3：为什么余额要由流水推导，不能直接更新？**

直接更新余额有三个问题：无法审计（改了就没了）、无法校验（错了发现不了）、并发下容易乱（多笔同时改）。流水不可变 + 余额可重算，才满足资金系统的**审计性与自愈能力**——余额错了好歹能重算回来。

**Q4：清分和结算为什么要分开？**

因为时间粒度不同：清分是"算账"（每天都做，纯计算），结算是"转账"（按周期，动真金）。分开的好处是**结算可以失败、可以重试、可以改周期**，而清分结果始终是完整可查的。合并的话，一旦打款失败，账就乱了。

**Q5：小公司做对账要投入多少？**

至少要三件事：**唯一业务号 + 幂等落库、渠道账单拉取与比对、差异告警与工单**。哪怕只有几百笔/天，没有对账就是"钱错了不知道"。对账不是大厂专利，是资金业务的底线。

## 九、小结

- **账务用复式记账 + 只增不改的流水**，余额是流水推导出的快照。
- **幂等（唯一业务号）+ 状态机（乐观锁）** 是资金系统的两条生命线。
- **清分算账、结算打款、对账校验**，三者分离，各司其职。
- **对账不是终点，差错闭环处理才是**：自动补单 + 人工工单 + 冲正调账。
- **主动查单 + T+1 全量对账** 双保险，永远不要只依赖回调。
- **金额用整数分或 BigDecimal**，这是底线中的底线。

能把"支付 → 记账 → 清分 → 结算 → 对账 → 差错"这条完整链路讲明白，面试官就知道你是真做过资金系统的人。
