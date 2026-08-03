---
title: 【Redis 实战】Redis 缓存与数据库一致性：双写、延迟双删与 Canal 终极方案
date: 2026-08-03 08:00:00
tags:
  - Java
  - Redis
  - 缓存
  - 面试
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 实战】Redis 缓存与数据库一致性：双写、延迟双删与 Canal 终极方案

## 面试官：数据更新时，你是怎么保证 Redis 缓存和 MySQL 数据一致性的？

这是 Redis 面试的"必考题"，也是生产环境最容易踩坑的地方。很多同学背了"先更新数据库，再删缓存"的口诀，但被追问一句"那并发情况下还有问题吗"就卡住了。今天我们把缓存一致性这个问题**从方案到原理到代码**彻底讲透。

## 一、先搞清楚：为什么会有缓存不一致？

缓存不一致的根源只有一个：**对同一份数据，MySQL 和 Redis 各存了一份，而更新操作不是原子的**。

- 更新 MySQL 成功、更新 Redis 失败 → 不一致；
- 更新 Redis 成功、更新 MySQL 失败 → 不一致；
- 两个都成功，但**执行顺序不同** → 中间态不一致；
- 并发读写交叉 → 旧数据覆盖新数据。

要理解各种方案，先看业界标准的四种缓存读写模式：

| 模式 | 读 | 写 | 特点 |
|------|----|----|------|
| Cache Aside（旁路缓存） | 读 Miss 后回源 DB | 先更新 DB，再删缓存 | 最常用，简单可控 |
| Read Through | 缓存组件负责回源 | 同 Cache Aside | 对应用透明，需中间件支持 |
| Write Through | 读缓存 | 先写缓存，缓存同步写 DB | 强一致但写放大严重 |
| Write Behind（异步写回） | 读缓存 | 只写缓存，异步批量写 DB | 性能最好，数据有丢失风险 |

生产环境 99% 用 **Cache Aside**，所以下面的讨论都基于它。

## 二、Cache Aside 的写入顺序之争

Cache Aside 更新数据的标准动作是：**先更新数据库，再删除缓存**（Update DB then Delete Cache）。

### 为什么不"先更新缓存，再更新数据库"？

如果先更新 Redis 再更新 MySQL：更新 Redis 成功、MySQL 失败，缓存里就是**脏数据**，而且后续读全部命中脏缓存，问题持续时间不可控。而"先 DB 后删缓存"即使删缓存失败，最多是**下次读时回源**，把旧缓存覆盖掉，自愈能力强。

### 为什么不"先删缓存，再更新数据库"？

经典的反例（A 先删缓存，B 读回源写回旧值，A 再更新 DB）：

```
时间线：
T1: 请求 A 删除缓存 key（此时 DB 里还是旧值 10）
T2: 请求 B 读缓存 Miss，回源 DB 读到旧值 10
T3: 请求 B 把旧值 10 写回缓存
T4: 请求 A 更新 DB 为 20
结果：缓存里是 10，DB 里是 20，永久不一致（除非缓存过期）
```

这个问题的窗口期是"T2 回源 DB 到 T3 写回缓存"这个网络往返，概率不高，但**一旦发生就是长期脏数据**。所以标准答案是：**先更新 DB，后删缓存**。

### 先更新 DB 再删缓存，就万无一失了吗？

仍有两个漏洞：

**漏洞 1：删除缓存失败。** 更新 DB 成功后删缓存时 Redis 超时/宕机，缓存留着旧数据。

**漏洞 2：并发读写竞态（罕见但存在）。** 请求 A 更新 DB 为 20，请求 B 是旧事务，读 DB 读到 20 之前……实际上这个竞态要求 B 的读发生在 A 写 DB 之前、但 B 写缓存发生在 A 删缓存之后，窗口极小（需要 B 回源极慢），业界普遍认为**可接受**，配合过期时间兜底即可。

## 三、方案一：延迟双删（Delay Double Delete）

针对"漏洞 1"和上面那个小概率竞态，经典改进方案是**延迟双删**：

```java
public void updateData(Long id, String newValue) {
    // 1. 更新数据库
    jdbcTemplate.update("UPDATE t_user SET name = ? WHERE id = ?", newValue, id);

    // 2. 第一次删除缓存
    redisTemplate.delete("user:" + id);

    // 3. 延迟一段时间（比如 500ms，大于一次 DB 读 + 缓存写的耗时）
    Thread.sleep(500);

    // 4. 第二次删除缓存
    redisTemplate.delete("user:" + id);
}
```

**原理**：第二次删除的目的，是把"并发读请求写回缓存的旧值"再次清掉。延迟时间要**大于 B 请求从回源 DB 到写回缓存的最长耗时**，一般取 500ms~1s。

**延迟双删的缺点也很明显**：
- 业务代码里 `sleep` 是坏味道，阻塞线程；
- 延迟时间不好定，压测环境 200ms 够，生产网络抖动可能要 1s+；
- 删除仍然可能失败（第二次也失败）。

所以延迟双删只是"尽力而为"的方案，**配合缓存过期时间**（如 5 分钟）作为最终兜底，才是一个可上线的方案。

## 四、方案二：消息队列 + 重试（删除缓存失败兜底）

把"删除缓存"改成"发消息异步删除"，删除失败就重试，彻底解决删缓存失败的问题：

```java
// 更新 DB（事务内）
@Transactional
public void updateUser(User user) {
    userMapper.updateById(user);
    // 事务提交后发消息，保证 DB 一定成功了
    TransactionSynchronizationManager.registerSynchronization(
        new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                mqTemplate.send("cache-del-topic", "user:" + user.getId());
            }
        });
}

// 消费端
@RabbitListener(queues = "cache-del-topic")
public void onDel(String key) {
    try {
        redisTemplate.delete(key);
    } catch (Exception e) {
        // 删除失败：记录并重试（最多 N 次，最终人工/定时任务补偿）
        throw new AmqpRejectAndDontRequeueException(e);
    }
}
```

**要点**：
1. 消息一定要在**事务提交后**发送（`afterCommit`），否则 DB 回滚了消息却发出去，会把好数据删掉；
2. 消费端删除失败要**重试**（MQ 的 retry + 死信队列），重试 N 次仍失败进死信队列告警人工处理；
3. 这个方案把"删除失败"的概率从"会发生"降到了"几乎不可能"，是生产最常用的方案。

## 五、方案三：Canal 监听 Binlog（终极方案）

上面两个方案都要**侵入业务代码**（每个更新方法都要写删除逻辑）。有没有不侵入业务代码的方案？有——**Canal**。

Canal 的原理是**伪装成 MySQL 的从库，订阅 Binlog**，任何对 DB 的写操作都会被它捕获：

```
应用（无感知，正常写 MySQL）
  │
  ▼
MySQL Master ──binlog──▶ Canal ──▶ MQ（canal-topic）
                                      │
                                      ▼
                              缓存更新服务（删除/更新 Redis）
```

```java
// Canal 消费端伪代码
@RabbitListener(queues = "canal-topic")
public void onBinlog(ChangeRow row) {
    // row 里包含库名、表名、变更类型（INSERT/UPDATE/DELETE）、主键
    if ("t_user".equals(row.getTableName())) {
        String key = "user:" + row.getPrimaryKey();
        if (row.getEventType() == EventType.DELETE) {
            redisTemplate.delete(key);
        } else {
            // 简单方案：删除缓存让读侧回源；也可以直接更新缓存
            redisTemplate.delete(key);
        }
    }
}
```

**Canal 方案的优势**：
- **业务零侵入**：改数据的方法完全不用动，删缓存是自动的；
- **可靠性高**：Binlog 是 MySQL 主从复制的标准机制，Canal 挂了重启后可以从上次位点续传，不丢数据；
- **覆盖面广**：不只你写的业务代码，DBA 手工改数据、报表批量导入、其他团队直接改库，全部能同步到缓存。

**注意**：Canal 引入了一套新组件（Canal server + MQ + 消费服务），架构复杂度上升，适合缓存一致性要求高、DB 变更入口多的大型系统。

## 六、什么时候必须用强一致？

聊了这么多"最终一致性"方案，必须说清楚边界：**以上所有方案都是最终一致，都存在一个极短的窗口期**。以下场景不能依赖缓存：

- **金融交易类**（余额、转账）：直接读 DB，或者用分布式锁 + 缓存版本号（`compareAndSet`）严格校验；
- **分布式锁的 value**：必须读 DB 权威值；
- **超时强校验**（如秒杀库存）：走 Redis Lua 原子操作，本质是"以 Redis 为权威"，而不是"让 Redis 和 DB 一致"。

如果一定要"缓存与 DB 强一致"，唯一可靠的办法是**放弃缓存**（直接读 DB + 数据库层缓存如 MySQL Buffer Pool），或者接受写放大用 **Write Through** 模式——性能代价极大，99% 的场景不值得。

## 七、面试追问整理

**Q1：为什么是"更新 DB 后删缓存"，而不是"更新缓存"？**
答：删缓存是惰性更新，下次读时自然回源，永远拿最新值；更新缓存需要知道完整的业务对象组装逻辑，耦合重，且更新 DB 成功而更新缓存失败时会产生长期脏数据。删缓存失败最多多一次 DB 读，代价最小。

**Q2：延迟双删的延迟时间怎么定？**
答：大于"并发读请求从回源 DB 到写回缓存"的最长耗时。一般取 500ms~1s，具体要压测 + 看网络 RT 的 P99。时间设短了起不到作用，设长了影响写接口的响应时间（因为是同步 sleep）。

**Q3：如果删缓存失败怎么办？**
答：三条防线：① MQ 异步删除 + 重试 + 死信告警；② 缓存设置过期时间兜底（业务能容忍的时长）；③ 定时任务扫描对账（对比缓存与 DB 的版本号/更新时间）。

**Q4：Canal 的原理是什么？**
答：Canal 模拟 MySQL Slave 的交互协议，向 Master 发送 dump 请求，订阅并解析 Binlog，把行变更事件推送给客户端。它依赖 MySQL 开启 binlog（`binlog_format=ROW`），通过维护位点（position）保证断点续传、不丢不重（配合 MQ 的幂等）。

**Q5：缓存一致性方案怎么选型？**
答：并发量小、一致性要求一般 → 先更新 DB 再删缓存 + 过期兜底即可；删除失败敏感 → 加 MQ 异步重试；DB 变更入口多/团队多 → Canal；强一致场景 → 放弃缓存或走分布式锁 + 版本号。

## 八、总结

缓存一致性的核心结论就三句话：
1. **写操作：先更新数据库，再删除缓存**，这是地基；
2. **删除失败的兜底：MQ 异步重试，别在业务代码里裸 sleep**；
3. **终极形态：Canal 订阅 Binlog 自动删缓存，业务零侵入**。

面试时从"为什么先 DB 后删缓存"讲到"并发竞态"，再引出延迟双删、MQ 重试、Canal，最后说明"最终一致 vs 强一致的边界"，一套组合拳下来，这个题就稳了。
