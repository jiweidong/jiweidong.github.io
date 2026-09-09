---
title: 【数据同步实战】Canal 增量同步深度解析：从 binlog 主从协议伪装、HA 故障转移到缓存/ES 双写一致性落地
date: 2026-09-09 08:00:00
tags:
  - Canal
  - MySQL
  - binlog
  - 数据同步
categories:
  - 中间件
  - 数据同步
author: 东哥
---

# 【数据同步实战】Canal 增量同步深度解析：从 binlog 主从协议伪装、HA 故障转移到缓存/ES 双写一致性落地

## 面试官：缓存和数据库一致性，除了延迟双删你们还怎么做的？知道 Canal 吗？

只要做过"先更新 DB 再删缓存"之外的方案，就一定绕不开一个痛点：**业务双写（写 MySQL 又写 ES/Redis）本质是分布式事务**，要么引入 MQ 增加链路复杂度，要么忍受双删窗口期的脏读。而 **Canal（阿里开源，基于 MySQL binlog 的增量订阅&消费组件）** 给出了第三条路：**让 MySQL 自己"开口说话"——主从复制协议本来就是 MySQL 同步数据的官方机制，Canal 只是伪装成一个从库，把 binlog 解析成结构化事件推给下游**。

本文从"伪装从库"的底层原理讲到 HA 部署与缓存/ES 同步落地，属于中间件原理 + 实战的硬核内容。

## 一、Canal 到底做了什么？

一句话：**Canal 把自己伪装成 MySQL 的一个 slave，向主库发送 dump 协议请求，拿到 binlog 后解析成 JSON 事件，再推送给自己的客户端（Consumer）。**

```
业务应用 --写--> MySQL(主)
                   │  binlog（开启 ROW 格式 + log_slave_updates）
                   ▼
Canal Server ──伪装成 slave，dump 协议拉取──► 解析/过滤/存储
                   │
                   ▼
         Canal Client / Adapter（自研或官方）
                   ├──► Redis 缓存更新
                   ├──► Elasticsearch 索引同步
                   └──► 异构库 / 数仓 / MQ
```

**核心前提（部署前必须确认）**：

```ini
# MySQL 侧配置
server_id = 1                 # 不能与 Canal 的 slaveId 重复
log_bin = mysql-bin
binlog_format = ROW           # 必须 ROW！Statement 格式拿不到变更前后的行数据
binlog_row_image = FULL       # 需要旧值（before image）时必须 FULL
expire_logs_days = 7          # 视消费速度而定，别让 binlog 被过早 purge
```

## 二、Canal 的架构与核心组件

Canal 分 **Server**（服务端）与 **Client/Adapter**（消费端）两层。Server 内部每个 **instance**（对应一个 MySQL 实例的订阅任务）由三大模块组成：

| 模块 | 职责 | 关键点 |
|---|---|---|
| **EventParser** | 伪装 slave 连接主库，拉取并解析 binlog | 解析成 CanalEntry（RowChange 等 protobuf 结构） |
| **EventSink** | 解析结果入队、过滤、分发 | 支持过滤规则（库/表/黑名单） |
| **EventStore** | 内存环形队列存储事件 | 默认 `MemoryEventStoreWithBuffer`，可配容量；不落盘 |
| **MetaManager** | 记录消费位点 | 支持内存 / zookeeper（HA 必选） |

**位点（position）机制**：Canal 会记录"我已经解析到主库 binlog 的哪个文件哪个偏移量"。宕机重启后从位点继续，配合**客户端 ack 机制**，实现 at-least-once 投递——所以**下游消费必须幂等**（跟 MQ 一个道理）。

**为什么它"不丢数据"？** Canal 的位点在 binlog 被 MySQL purge 之前一直有效；只要下游 ack 及时、binlog 保留期足够，就不会丢。

## 三、核心原理深挖：binlog 里到底有什么？

ROW 格式下，一条 UPDATE 会生成类似这样的事件序列（Canal 解析后）：

```json
{
  "type": "UPDATE",
  "table": "t_order",
  "database": "mall",
  "es": 1690000000,
  "data": [
    { "id": 1001, "status": 2, "pay_time": "2026-09-09 10:00:00" }   // 新值
  ],
  "old": [
    { "status": 1 }                                                  // 旧值（仅变更列）
  ]
}
```

几个易错点：

1. **`old` 只包含变更的列**，不是整行旧值——除非 `binlog_row_image=FULL` 配合 Canal 配置，但默认也只会给变更列；
2. **一条 SQL 影响多行**，`data` 就是数组；**一个大事务**会产生海量事件，Canal 会按事务边界分批推送；
3. **DDL 语句**（ALTER/CREATE）也会被解析成 `type: "QUERY"` 或 `type: "DDL"` 事件，下游做 ES 映射变更、缓存结构变更时必须处理；
4. Canal 内部事件用 **protobuf** 定义（`CanalEntry`），网络传输紧凑高效。

## 四、Canal Client 实战：拉取与消费

```xml
<dependency>
    <groupId>com.alibaba.otter</groupId>
    <artifactId>canal.client</artifactId>
    <version>1.1.7</version>
</dependency>
```

```java
public class CanalConsumer {
    public static void main(String[] args) {
        CanalConnector connector = CanalConnectors.newSingleConnector(
                new InetSocketAddress("127.0.0.1", 11111), "example", "", "");
        connector.connect();
        connector.subscribe("mall\\..*");   // 订阅 mall 库所有表，支持正则
        connector.rollback();               // 回滚到上次 ack 位点，保证不丢

        while (running) {
            Message message = connector.getWithoutAck(500); // 批量拉取，不自动 ack
            long batchId = message.getId();
            if (batchId == -1 || message.getEntries().isEmpty()) {
                Thread.sleep(1000);
                continue;
            }
            try {
                for (CanalEntry.Entry entry : message.getEntries()) {
                    if (entry.getEntryType() != CanalEntry.EntryType.ROWDATA) continue;
                    CanalEntry.RowChange rowChange = CanalEntry.RowChange.parseFrom(entry.getStoreValue());
                    // 根据 rowChange.getEventType()（INSERT/UPDATE/DELETE）
                    // 和 rowChange.getRowDatasList() 里的 beforeColumns/afterColumns
                    // 组装自己的同步逻辑：更新 Redis / 写 ES / 发 MQ
                    syncToDownstream(rowChange);
                }
                connector.ack(batchId);      // 处理成功才 ack
            } catch (Exception e) {
                connector.rollback(batchId); // 失败回滚，下次重新拉这批
            }
        }
    }
}
```

**消费模型要点**：

- `getWithoutAck` + `ack` / `rollback` 是 Canal 的**可靠投递**核心，用法和 RocketMQ 的消费确认一模一样；
- 同一个 instance 的客户端**串行消费**，天然保序（单表变更顺序 = binlog 顺序）；
- 追求吞吐就自己开多线程消费，但**同一个业务主键的变更要路由到同一线程**，否则会乱序覆盖。

## 五、HA 高可用部署

Canal Server 单点会挂，位点放 zookeeper 后可以做主备：

```
Canal Server A（active）───┐
                          ├── Zookeeper（位点 + 选主 + 客户端路由）
Canal Server B（standby）──┘
```

- 两个 Canal Server 配置同一个 `canal.zkServers`，同一 destination（instance）通过 zookeeper 临时节点竞争，**同一时刻只有一个实例在拉 binlog**（避免重复解析）；
- 客户端连的是 zk 路由出来的**活着的 server**；
- MySQL 主从切换时，把 Canal 的 `canal.instance.master.address` 切到新主即可，配合 `gtid` 位点模式（`canal.instance.gtid=true`）切换更顺滑。

## 六、落地场景与选型对比

| 场景 | 方案 | 说明 |
|---|---|---|
| 缓存一致性 | **Canal → Redis** | 彻底替代延迟双删：DB 提交 → binlog → Canal → 更新缓存，窗口期≈0 |
| 搜索同步 | **Canal → ES** | 替代业务双写 ES，天然拿到全量字段变更 |
| 异构数据 | Canal → MQ → 数仓/其他库 | 解耦下游消费速度 |
| 数据归档/审计 | Canal 订阅 DELETE 事件 | 逻辑删变物理删时的兜底 |

**Canal vs 其他同步工具**：

| 维度 | Canal | Debezium | DataX |
|---|---|---|---|
| 同步方式 | 增量（binlog） | 增量（binlog） | 批量（全量/定时增量） |
| 语言/生态 | Java（阿里系文档友好） | Java（Confluent/Kafka 生态） | Java（离线批导） |
| 消费方式 | 自定义 Client / Adapter | Kafka Connect 框架 | 任务式 |
| 适合场景 | 缓存/ES 等实时增量 | CDC 入湖入仓、事件驱动 | 大数据量一次性迁移 |

**大坑提醒**：

1. **binlog 保留期**：消费慢于 binlog purge 速度 = 丢数据，务必监控位点落后量；
2. **大事务**：一次 UPDATE 十万行会生成超大事件，下游 ES/Redis 要做好批量与限流；
3. **幂等消费**：at-least-once 语义下，重复投递靠业务主键去重；
4. **DDL 兼容**：加列后 ES mapping 不更新会写失败，建议监听 DDL 事件做映射迁移。

## 七、面试高频追问

- Canal 为什么能拿到 binlog？→ 伪装 slave，走主从复制 dump 协议
- 为什么要求 `binlog_format=ROW`？→ Statement 拿不到行级前后值
- Canal 怎么保证不丢？→ 位点持久化（zk）+ 客户端 ack/rollback
- 消费怎么保证有序？→ 单 instance 串行投递；自研多线程需按主键路由
- Canal 挂了怎么办？→ 双机 HA + zk 选主，位点续传
- 和延迟双删比优势？→ 无窗口期、无业务侵入、天然拿到 before/after 数据

**一句话总结：Canal = 给 MySQL 装一个"旁路总线"，把 binlog 变成可编程的数据流。缓存一致性、ES 同步、异构数据分发，一条链路全搞定——这是高并发架构里"DB 为唯一事实源"思想的标准实践。**
