---
title: 【系统设计】高并发抽奖系统架构设计：奖池概率、库存扣减、幂等防刷与限流
date: 2026-10-02 08:10:00
tags:
  - 系统设计
  - 高并发
  - Redis
  - 抽奖
categories:
  - 系统设计
  - 高并发
author: 东哥
---

# 【系统设计】高并发抽奖系统架构设计：奖池概率、库存扣减、幂等防刷与限流

## 面试官：设计一个"双十一万人秒杀抽奖"活动，要求不超发、不重复、可审计

抽奖系统是一个特别有意思的题目。它比秒杀更"软"——秒杀的核心是"抢到/抢不到"的确定性，而抽奖的核心是**概率**；但它在工程上又和秒杀高度重合：都要处理**库存、并发、幂等、防刷、限流**。

这篇文章把抽奖系统从概率模型到分布式一致性拆开讲一遍。

---

## 一、需求拆解

先定义清楚边界，再动手：

| 需求 | 说明 |
| --- | --- |
| 奖池 | 一等奖 1 个、二等奖 10 个、优惠券 10000 张、谢谢惠顾无限 |
| 概率 | 每个奖品有固定中奖概率，概率之和为 1 |
| 频次 | 每个用户每天最多抽 3 次 |
| 库存 | 实物奖品有数量上限，抽完即停 |
| 幂等 | 同一次抽奖请求重试不能重复发奖 |
| 防刷 | 防止脚本、批量小号恶意抽奖 |
| 可审计 | 每一次抽奖都要留流水，能对账 |

一套完整的抽奖系统，实际上由四个子系统组成：**概率决策、库存扣减、幂等与限流、审计与对账**。

---

## 二、概率决策：把"随机"做对

### 2.1 方案一：区间法（最直观）

给每个奖品分配一个区间，随机落到哪个区间就是哪个奖品：

```java
public class IntervalLottery {

    // 累计概率区间
    private static final double[] BOUNDS = {0.001, 0.011, 0.511, 1.0};

    private static final String[] PRIZES = {
            "IPHONE",   // 0    ~ 0.001
            "CASH_100", // 0.001 ~ 0.011
            "COUPON",   // 0.011 ~ 0.511
            "THANKS"    // 0.511 ~ 1.0
    };

    public String draw(double r) {
        int idx = Arrays.binarySearch(BOUNDS, r);
        if (idx < 0) {
            idx = -idx - 1; // 转换成插入点
        }
        return PRIZES[idx];
    }
}
```

优点：简单、可解释、支持任意概率分布。
缺点：每次抽奖都要 O(log N) 查找（二分）。奖品少时无所谓，奖品几百上千时略有开销。

### 2.2 方案二：Alias Method（O(1) 采样）

当奖品数量多、抽奖 QPS 极高时，可以用 Alias Method（别名采样法）把单次采样降到 O(1)。预处理一次 O(N)，之后每次采样只做一次随机 + 一次查表：

```java
public class AliasMethod {

    private final int[] alias;
    private final double[] prob;
    private final String[] items;

    public AliasMethod(List<Prize> prizes) {
        int n = prizes.size();
        this.items = prizes.stream().map(Prize::name).toArray(String[]::new);
        this.alias = new int[n];
        this.prob = new double[n];

        double[] scaled = new double[n];
        for (int i = 0; i < n; i++) {
            scaled[i] = prizes.get(i).probability() * n;
        }

        Deque<Integer> small = new ArrayDeque<>();
        Deque<Integer> large = new ArrayDeque<>();
        for (int i = 0; i < n; i++) {
            (scaled[i] < 1.0 ? small : large).push(i);
        }

        while (!small.isEmpty() && !large.isEmpty()) {
            int s = small.pop();
            int l = large.pop();
            // s 的概率被"填满"1，剩下概率转移到 l
            prob[s] = scaled[s];
            alias[s] = l;
            scaled[l] = scaled[l] + scaled[s] - 1.0;
            (scaled[l] < 1.0 ? small : large).push(l);
        }
        while (!large.isEmpty()) {
            int l = large.pop();
            prob[l] = 1.0;
        }
        while (!small.isEmpty()) {
            int s = small.pop();
            prob[s] = 1.0;
        }
    }

    public String sample() {
        int i = ThreadLocalRandom.current().nextInt(items.length);
        double r = ThreadLocalRandom.current().nextDouble();
        return r < prob[i] ? items[i] : items[alias[i]];
    }
}
```

**面试加分点**：能说出"别名采样把 O(N) 累积概率查找降成 O(1)"，说明你不仅会用，还知道为什么。

### 2.3 概率配置化

概率绝对不能硬编码。常见的做法是配置中心（Apollo/Nacos）下发奖池配置，支持：

- 动态调整概率（运营活动期间实时调控）
- 灰度：不同用户群体走不同概率（新用户概率更高）
- 版本号：每次抽奖记录使用的配置版本，便于复盘

---

## 三、库存扣减：不超发是底线

抽奖和秒杀在库存上的诉求完全一致：**不超卖**。

### 3.1 库存模型

```text
lottery:stock:{prizeId}  ->  剩余库存（Redis String，DECR 原子）
lottery:total:{prizeId}  ->  总库存
```

扣减用 Lua 脚本保证"判断 + 扣减"的原子性：

```lua
-- KEYS[1]: 库存 key
-- ARGV[1]: 扣减数量
local stock = tonumber(redis.call('GET', KEYS[1]) or '-1')
if stock < tonumber(ARGV[1]) then
    return -1     -- 库存不足
end
redis.call('DECRBY', KEYS[1], ARGV[1])
return stock - tonumber(ARGV[1])
```

为什么必须用 Lua？因为在 Redis 里，`GET` 和 `DECRBY` 是两条命令，中间可能被其他客户端插入，导致超卖。Lua 脚本在 Redis 中**串行执行**，天然原子。

### 3.2 库存预热与对账

- 活动开始前，把 DB 库存加载到 Redis（预热）。
- Redis 只做"流量拦截"，扣减成功后异步写 DB 流水。
- 定时任务对账：`Redis 已扣减 = DB 已发奖 + 在途`，不一致则告警并修复。

### 3.3 超发兜底：数据库唯一约束

Redis 也可能因为主从切换、cluster 迁移等原因丢数据。所以最终防线是数据库：

```sql
CREATE TABLE prize_record (
    id          BIGINT PRIMARY KEY AUTO_INCREMENT,
    user_id     BIGINT NOT NULL,
    prize_id    BIGINT NOT NULL,
    request_id  VARCHAR(64) NOT NULL,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_request (request_id),
    UNIQUE KEY uk_prize_seq (prize_id, seq_no)
);
```

`uk_prize_seq` 里的 `seq_no` 是"第几个中奖名额"，靠它把超发拦在数据库层。即使 Redis 算错了，插入也会失败。

---

## 四、幂等：重试不重复发奖

用户点抽奖，由于网络抖动客户端重试了一次，绝不能发放两次奖品。

**方案：请求 ID + 唯一索引 + Redis SETNX 前置拦截**

```java
public DrawResult draw(long userId, String requestId) {
    // 1. 前置幂等拦截：SETNX 占位，带过期时间
    String idemKey = "lottery:idem:" + userId + ":" + requestId;
    Boolean first = redis.opsForValue().setIfAbsent(idemKey, "1", Duration.ofMinutes(10));
    if (!Boolean.TRUE.equals(first)) {
        // 已处理过，直接返回上次结果（从 DB 查）
        return queryResult(userId, requestId);
    }

    try {
        // 2. 频次校验
        checkDailyLimit(userId);

        // 3. 概率决策
        String prize = aliasMethod.sample();

        // 4. 库存扣减（Lua 原子）
        if (!"THANKS".equals(prize)) {
            Long left = deductStock(prize);
            if (left == null || left < 0) {
                // 库存不足，降级为谢谢惠顾
                prize = "THANKS";
            }
        }

        // 5. 落库（唯一索引兜底）
        saveRecord(userId, prize, requestId);
        return DrawResult.of(prize);
    } catch (DuplicateKeyException e) {
        // 并发/重放，返回已有结果
        return queryResult(userId, requestId);
    } catch (Exception e) {
        redis.delete(idemKey); // 失败要释放占位，允许重试
        throw e;
    }
}
```

要点：

1. **SETNX 只是第一层**，它拦住了绝大多数重复请求。
2. **唯一索引是第二层**，万一 Redis 失效也能兜住。
3. **失败要释放幂等键**，否则用户永远无法重试。
4. **返回同一个结果**，而不是报错，用户体验更好。

---

## 五、限流与防刷

抽奖是典型的"高风险接口"，必须有防刷。

### 5.1 分层限流

| 层级 | 手段 |
| --- | --- |
| 网关层 | IP 限流、Nginx limit_req、Sentinel 集群流控 |
| 用户层 | 每日次数、每分钟次数（Redis 计数器） |
| 设备层 | 设备指纹、设备 ID 限流 |
| 行为层 | 行为序列异常检测（风控） |

用户级限流用 Redis 的固定窗口或滑动窗口即可：

```lua
-- 每日抽奖次数限制
-- KEYS[1] = lottery:limit:20261002:{userId}
-- ARGV[1] = 上限
local cnt = redis.call('INCR', KEYS[1])
if cnt == 1 then
    redis.call('EXPIRE', KEYS[1], 90000) -- 覆盖到第二天
end
if cnt > tonumber(ARGV[1]) then
    return -1
end
return cnt
```

注意 `INCR` 和 `EXPIRE` 必须放在同一个 Lua 里，否则第一条 `INCR` 之后进程崩溃，key 就永远不会过期，用户被永久限流。

### 5.2 风控联动

- 黑名单：命中直接拒绝。
- 灰名单：正常返回但**不发真实奖品**（发"谢谢惠顾"或虚拟券），避免打草惊蛇。
- 设备聚集检测：同一设备/同一 IP 短时间内大量注册并抽奖，标记为风险。

---

## 六、整体架构图

```text
                 ┌─────────────┐
   用户请求 ───▶ │  网关限流    │
                 └──────┬──────┘
                        │
                 ┌──────▼──────┐
                 │  风控前置    │ 黑名单/设备/行为
                 └──────┬──────┘
                        │
                 ┌──────▼──────┐
                 │ 幂等 + 频次  │ Redis SETNX + 计数
                 └──────┬──────┘
                        │
                 ┌──────▼──────┐
                 │  概率决策    │ Alias / 区间法，配置中心下发
                 └──────┬──────┘
                        │
                 ┌──────▼──────┐
                 │  库存扣减    │ Redis Lua 原子
                 └──────┬──────┘
                        │
                 ┌──────▼──────┐
                 │ 异步落库     │ MQ -> DB 流水 + 唯一索引
                 └─────────────┘
```

---

## 七、高频追问

**追问 1：随机数种子会不会被预测？**

`ThreadLocalRandom` 是伪随机，理论上可预测。安全敏感场景（如抽奖发实物）应使用 `SecureRandom`，或者引入服务器端随机源 + 不可预测的 salt。更重要的是：**概率服务不要暴露给客户端**，一切在服务端决策。

**追问 2：为什么库存不足要降级成"谢谢惠顾"而不是报错？**

抽奖的用户体验强调"无感失败"。库存不足时直接报"奖品已抽完"会泄露库存信息，也会让用户觉得系统出问题。降级为"谢谢惠顾"既保护了信息，也维持了流程的流畅。

**追问 3：Redis 扣减成功但落库失败怎么办？**

这是典型的分布式一致性问题，解决思路：

1. **本地消息表 / 事务消息**：扣减成功后写一条消息到 MQ，消费者落库，失败重试。
2. **定时对账补偿**：对比 Redis 扣减记录和 DB 流水，差量补发。
3. **接受最终一致**，但把"在途"状态显式建模，避免重复发奖。

**追问 4：怎么防止超发又保证高可用？**

核心是**把超发的风险从"概率问题"变成"确定性问题"**：

- Redis 做流量拦截（可能误放行，不能少发）。
- DB 唯一索引做最终裁决（不会超发）。
- 中间用**配额预分配**：一次从 DB 申请 100 个名额，Redis 内部分发，用不完归还。这样既减少了 DB 压力，又不会超发。

**追问 5：抽奖系统怎么压测？**

- 用 JMeter/Gatling 构造真实分布的用户行为（不是无脑压同一个用户）。
- 重点关注：P99 延迟、Redis 单分片 QPS、Lua 脚本耗时、DB 写入瓶颈。
- 验证指标：库存最终是否为 0、发奖总数是否等于库存总数、是否存在重复 requestId。

---

## 八、保底与连抽：产品规则怎么落到工程

真实的抽奖活动很少是"纯随机"，往往带有保底和连抽规则，这些规则在工程上同样有讲究。

### 8.1 保底规则（N 次必中）

"抽 10 次必中一个奖"这类规则，最朴素实现是在用户维度记录计数：

```text
lottery:miss:{userId}:{activityId}  ->  连续未中奖次数
```

每次抽奖前先读计数，达到阈值就强制命中最低奖。要注意两点：

1. **计数与抽奖必须在同一个原子操作里**。否则并发下可能出现"两人同时读到 9，都触发保底"，导致多发。可以用 Lua 把"读计数 + 扣减/清零"包在一起。
2. **活动结束要清理计数**，用带活动 ID 的 key 加 EXPIRE。

### 8.2 十连抽的实现

十连抽本质是**批量抽奖**，必须保证：

- **原子性**：要么 10 次都成功，要么都不发生（或明确告知部分失败）。
- **库存原子扣减**：一次扣 10 个的库存优先，不够时再逐个降级。
- **幂等**：整批用一个 requestId，避免重复发奖。

实现上可以一次性生成 10 个结果，然后**合并库存扣减**（同奖品合并为一次 DECRBY），能显著减少 Redis 往返：

```java
public List<DrawResult> drawTen(long userId, String requestId) {
    Map<String, Integer> need = new HashMap<>();
    List<DrawResult> results = new ArrayList<>(10);
    for (int i = 0; i < 10; i++) {
        String prize = aliasMethod.sample();
        results.add(DrawResult.of(prize));
        need.merge(prize, 1, Integer::sum);
    }
    // 合并扣减：一次 Lua 处理所有奖品
    Map<String, Boolean> ok = batchDeduct(need);
    // 扣减失败的奖品降级为谢谢惠顾
    results.replaceAll(r -> ok.getOrDefault(r.prize(), false) ? r : DrawResult.of("THANKS"));
    saveBatch(userId, results, requestId);
    return results;
}
```

### 8.3 概率公示与合规

如果活动涉及"有奖销售"，很多地区法规要求**公示中奖概率**。所以奖池配置本身要可追溯、可导出，并且和线上执行的结果对得上——这也是"配置版本号"必须记录的原因。

---

## 九、总结

抽奖系统的设计可以浓缩成四句话：

1. **概率要可配置、可解释、可采样**（区间法 / Alias Method）。
2. **库存要原子扣减 + 多层兜底**（Lua + 唯一索引 + 对账）。
3. **幂等要靠请求 ID + SETNX + 唯一索引**三位一体。
4. **防刷要分层限流 + 风控联动**，灰名单静默拦截。

把"随机"做对，把"库存"守住，把"重复"拦住，把"恶意"过滤掉——抽奖系统就成立了。

彩蛋一句：抽奖系统的所有代码，最终都要经得起"对账"的检验。库存对不对、发奖有没有重复、概率是否接近配置值——能把这三件事用数据证明清楚，才算真正交付。
