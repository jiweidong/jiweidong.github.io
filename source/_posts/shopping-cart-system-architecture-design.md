---
title: 【系统设计】购物车系统架构设计：存储选型、多端合并、价格计算与过期治理
date: 2026-10-04 08:30:00
tags:
  - 系统设计
  - 高并发
  - Redis
  - 购物车
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】购物车系统架构设计：存储选型、多端合并、价格计算与过期治理

## 面试官：设计一个淘宝/京东的购物车，支持未登录、多端、海量商品

"购物车不就是存个商品列表吗？"——如果这么答，面试基本就结束了。

购物车真正的难点在于：**它是唯一一个既要在未登录态工作、又要在登录后合并、还要保证价格永远实时的模块**。它同时踩了缓存设计、读写分离、数据一致性、热点 key 四个坑。

---

## 一、需求拆解

| 维度 | 需求 |
| --- | --- |
| 未登录 | 本地/游客购物车，无需登录即可添加 |
| 登录后 | 游客车与用户车**合并**，同商品数量叠加 |
| 多端 | App、H5、小程序、PC 数据同步 |
| 容量 | 单用户上限 200 个 SKU（防刷） |
| 价格 | **永远实时**，不能存快照价 |
| 操作 | 加购、改数量、删除、选中、清空、失效商品区 |
| 规模 | 数亿用户，QPS 峰值数十万 |

关键决策一：**购物车不存价格**。
存价格会导致商品调价后购物车显示错误，且每次改价要全量刷新缓存。所以只存 `skuId + 数量 + 选中状态 + 加入时间`，价格在下单/展示时批量查。

关键决策二：**购物车不是订单**。
购物车可以随时丢，所以可以容忍"最终落库"；订单必须强一致。这个定位决定了后面可以放心用 Redis 做主力存储。

---

## 二、存储选型

| 方案 | 优点 | 缺点 | 适用 |
| --- | --- | --- | --- |
| 纯 MySQL | 强一致、可分析 | 高并发扛不住、券过期清理贵 | 小流量 |
| 纯 Redis | 快、天然 TTL | 丢数据、成本高、无法离线分析 | 纯缓存 |
| **Redis + MySQL 异步落库** | 快 + 可靠 | 实现复杂 | ✅ 主流 |

主流电商（阿里/京东）都是 **Redis 为主、MySQL 兜底**：

- 读：99% 走 Redis；
- 写：先写 Redis 返回成功，异步（MQ/日志订阅）落 MySQL；
- 兜底：Redis 未命中时从 MySQL 重建。

为什么敢这么做？因为购物车**丢一点数据不致命**，用户重新加购即可。这是拿"可靠性"换"性能"的经典 trade-off。

---

## 三、Redis 数据结构设计

用 **Hash** 存单个用户的购物车，field 是 skuId，value 是信息：

```text
Key:   cart:{userId}
Type:  Hash
Field: {skuId}
Value: {数量}|{选中状态}|{加入时间戳}|{营销活动id}
TTL:   30 天（每次操作续期）
```

```java
// 加购：HINCRBY 原子自增，天然处理并发重复加购
public void addItem(long userId, long skuId, int qty) {
    String key = "cart:" + userId;
    String field = String.valueOf(skuId);
    Long newQty = redis.hincrBy(key, field, qty);
    if (newQty != null && newQty > MAX_QTY_PER_SKU) {
        redis.hset(key, field, String.valueOf(MAX_QTY_PER_SKU)); // 回滚到上限
        throw new BizException("单个商品最多 " + MAX_QTY_PER_SKU + " 件");
    }
    redis.expire(key, 30, TimeUnit.DAYS);
    // 异步落库
    mq.send(new CartChangeEvent(userId, skuId, newQty));
}
```

几个细节值得说：

1. **用 `HINCRBY` 而不是 `HGET` + `HSET`**，避免并发下数量被覆盖。
2. **数量上限要在写入后校验并回滚**，因为 `HINCRBY` 是无条件自增。
3. **总 SKU 数上限**用 `HLEN` 判断，但 `HLEN` 在大 hash 下是 O(1)（Redis 维护了长度），可以放心调。
4. **大 hash 问题**：如果热门用户购物车有几千个 SKU，单 key 会成为 hot key。解法是**分片**：`cart:{userId}:{shard}`，shard = `hash(skuId) % 4`，读时合并。牺牲一次 `HMGET` 的原子性，换取热点打散。

---

## 四、未登录购物车与合并

未登录时数据在**客户端本地**（App 数据库 / localStorage / Cookie）：

| 端 | 存储 |
| --- | --- |
| App | SQLite / MMKV |
| H5 | localStorage |
| 小程序 | Storage |

登录成功后触发**购物车合并**：

```java
public void merge(long userId, List<LocalItem> localItems) {
    // 1. 拉取用户云端购物车
    Map<Long, Integer> cloud = getCloudCart(userId);
    // 2. 逐条合并：同 SKU 数量相加（不覆盖！），受上限约束
    for (LocalItem item : localItems) {
        int merged = Math.min(
            cloud.getOrDefault(item.skuId, 0) + item.qty,
            MAX_QTY_PER_SKU);
        cloud.put(item.skuId, merged);
    }
    // 3. 一次性回写 + 清空本地
    saveCloudCart(userId, cloud);
    clearLocalCart();
}
```

**合并的坑**：必须是"相加"而不是"覆盖"。如果云端已有 3 件、本地也是 3 件，合并后应该是 6（截断到上限），不是 3。很多初级实现会在这里丢数据，被用户投诉。

**并发合并**要加分布式锁 `lock:cart:merge:{userId}`，否则用户在两端同时登录会重复合并。

---

## 五、价格实时计算

购物车展示时需要：商品现价、促销价、优惠券可用性、运费、小计。这些**都不能缓存在购物车 key 里**，因为价格变更是常态。

标准做法是**批量聚合**，避免 N+1：

```java
public CartVO render(long userId) {
    List<CartItem> items = cartService.list(userId);      // 1 次 Redis
    List<Long> skuIds = items.stream().map(CartItem::getSkuId).toList();

    // 2. 批量查商品中心（内部 RPC 批量接口，或缓存 MGET）
    Map<Long, SkuInfo> skus = skuService.batchGet(skuIds);

    // 3. 批量查营销/价格中心，算最优促销
    Map<Long, Promotion> promos = promoService.batchCalc(userId, skuIds, items);

    // 4. 内存组装，一次返回
    return assemble(items, skus, promos);
}
```

⚠️ 面试高频追问：**为什么不让商品服务每次调价时推送更新购物车缓存？**

因为：
1. 价格变更的下游不止购物车，还有搜索、详情、推荐，推模式会爆炸；
2. 购物车缓存 key 是按用户分的，一次调价要更新几亿个 key —— 不可行。

所以购物车**永远是拉模式**：展示时实时拉，缓存只缓存商品价格本身（商品维度的缓存可以按 skuId 更新）。

---

## 六、失效商品与过期治理

购物车有三类"失效"：

| 类型 | 原因 | 处理 |
| --- | --- | --- |
| 下架/删除 | 商品不可售 | 移到失效区，不可下单 |
| 无库存 | 售罄 | 保留，提示补货 |
| 促销结束 | 活动价失效 | 保留，按原价展示 |

**过期治理**有两个层次：

1. **Redis TTL 自动过期**：30 天不操作即消失。
2. **MySQL 归档**：落库的购物车数据定期归档，避免表无限膨胀；
   长期不活跃用户（如 90 天）的购物车可以**降级为只读快照**甚至直接清理。

⚠️ 不要给每个 SKU 单独设 TTL（Redis Hash 做不到 field 级 TTL，除非用 7.4 的 `HEXPIRE`）。统一用整个 cart key 的 TTL 更简单。

---

## 七、热点与容量

大促期间热门 SKU（比如 iPhone）会被几十万人加购，写入集中。缓解手段：

1. **合并写**：同一用户短时间内多次改数量，客户端防抖 + 服务端合并。
2. **异步落库**：MySQL 只承接最终值，不承接每次变更。
3. **分片 hash**：如上文，按 skuId 取模拆分大购物车。
4. **限流**：单用户购物车操作 QPS 限流（如 10/s），防脚本刷。

---

## 八、缓存一致性与降级

购物车允许最终一致，但**不能出现"加了购却看不到"**这种明显错误。所以异步落库要遵循两条规则：

1. **先写缓存、再发消息**。缓存写失败直接返回失败，让用户重试；消息发送失败进入本地消息表，由定时任务重投。
2. **读时以缓存为准，缓存未命中回源 MySQL**。回源后要写回缓存（`SETNX`，避免并发回源时的覆盖）。

```java
public Cart getCart(long userId) {
    String key = "cart:" + userId;
    Map<String, String> cache = redis.hgetAll(key);
    if (cache != null && !cache.isEmpty()) {
        return convert(cache);
    }
    // 缓存未命中：加锁回源，防止缓存击穿
    String lock = "lock:cart:rebuild:" + userId;
    if (redis.setnx(lock, "1", 5, TimeUnit.SECONDS)) {
        try {
            Cart cart = loadFromDb(userId);
            if (cart != null) {
                redis.hsetAll(key, toMap(cart));
                redis.expire(key, 30, TimeUnit.DAYS);
            }
            return cart;
        } finally {
            redis.del(lock);
        }
    }
    // 没抢到锁，短暂等待后返回 DB 结果（避免大量请求打 DB）
    return loadFromDb(userId);
}
```

**降级策略**（大促必备）：Redis 集群故障时，购物车可以降级为**只读 + 本地缓存**，禁止加购并提示用户；同时把写请求转成同步写 MySQL（限流保护），保证核心下单链路不受影响。购物车永远不是核心链路——想清楚这一点，降级方案就很好设计。

## 九、数据模型与扩展字段

实际生产中，购物车条目上还会挂不少业务字段，设计时要预留扩展性：

| 字段 | 用途 |
| --- | --- |
| `activityId` | 加购时参与的秒杀/拼团活动，用于锁定活动价 |
| `source` | 加购来源（商详页/推荐流/购物车页） |
| `ext` | JSON 扩展，存放赠品、配件等组合信息 |
| `checked` | 是否勾选结算 |

注意 `checked`（勾选状态）也放在 Redis 里，但**结算时必须二次校验**：用户勾选的商品可能已经失效，不能直接信任客户端的勾选结果。校验逻辑应是"服务端重新拉取商品状态 → 过滤失效项 → 计算金额"。

## 面试官追问

**Q：Redis 挂了，购物车数据丢了怎么办？**

A：分层兜底：
1. 主从 + 哨兵/Cluster 保证高可用；
2. MySQL 里有异步落库的副本，Redis 未命中时回源重建；
3. 最坏情况，用户重新加购 —— 业务上可接受，因为购物车不是资产。这也是为什么敢把 Redis 当主存储。

**Q：多端同时改同一个商品数量，以谁为准？**

A：不要用"最后写入"（last-write-wins）覆盖，因为网络乱序会导致旧值覆盖新值。可以用**版本号 + 时间戳**：客户端带 `version`，服务端 CAS 更新，冲突时以服务端为准并返回最新值让客户端刷新。对于"数量"这种可合并的字段，也可以退化为"取最大值"或"服务端增量累加"。

**Q：加购要不要校验库存？**

A：要，但**只做软校验**。加购时校验"是否有货"，不预占库存（预占是下单的事）。否则用户把商品放在购物车几个月，库存就被锁死了。加购校验失败也允许放进去，标记为"暂不可购"即可。

---

## 总结

| 设计点 | 选择 | 理由 |
| --- | --- | --- |
| 主存储 | Redis Hash | 高并发、天然 TTL |
| 兜底 | MySQL 异步落库 | 可靠、可分析 |
| 价格 | 不存，实时批量拉 | 保证价格准确 |
| 合并 | 数量相加 + 分布式锁 | 避免丢数据/重复合并 |
| 失效 | 状态标记，不删除 | 保留用户意图 |
| 过期 | Redis TTL + 离线归档 | 控制内存与表体积 |

购物车设计的精髓是：**敢于把它当成"可以丢的缓存"来设计**。想清楚哪些数据必须强一致（价格、库存）、哪些可以最终一致（购物车条目本身），架构自然就清晰了。
