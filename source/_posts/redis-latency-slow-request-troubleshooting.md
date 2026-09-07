---
title: 【Redis 运维】Redis 变慢排查实战：从延迟基线、slowlog 到内核网络的全链路诊断
date: 2026-09-07 08:06:00
tags:
  - Redis
  - 性能调优
  - 运维
  - 故障排查
categories:
  - Java
  - 中间件
author: 东哥
---

# 【Redis 运维】Redis 变慢排查实战：从延迟基线、slowlog 到内核网络的全链路诊断

## 现象：接口偶发 2 秒超时，Redis 却"看起来"没问题

线上告警：某核心接口 P99 从 30ms 飙到 1.8s，链路追踪显示耗时几乎全在 Redis 调用上。运维登上 Redis 一看：`INFO` 输出正常、CPU 不高、内存没满、`hit_rate` 也还行——但业务就是慢。最后排查出来，是**一台 Redis 所在物理机的网卡软中断被打满**，而 Redis 进程自己毫不知情。

Redis 是单线程模型，它的"慢"通常不是自己一个进程的事：可能是命令本身慢、可能是 fork 阻塞、可能是内核/网络/邻居干扰。本文给出一套从**客户端视角**到**服务器内核视角**的完整排查路径。

## 一、先建立基线：你到底有多慢？

没有基线，"变慢"无从谈起。三个必查指标：

```bash
# 1. 本机 intrinsic 延迟（排除网络，纯看 Redis 进程 + 内核调度）
redis-cli --intrinsic-latency 100
# 输出示例：Max latency so far: 1 microseconds. （健康值应 < 10us 级别）

# 2. 端到端网络延迟（客户端机器执行，含网络 RTT）
redis-cli -h your.redis.host -p 6379 --latency -i 1
# 输出示例：avg: 0.35ms  min: 0.10ms  max: 15.2ms   ← max 飙高说明有抖动

# 3. 周期性采样看抖动分布
redis-cli --latency-history -i 1
```

- `--intrinsic-latency` 在 **Redis 服务器本机**跑：如果本机都高，问题在服务器（进程/内核/虚拟化邻居）；
- `--latency` 在**客户端**跑：差值就是网络链路延迟；
- 抖动（max 远大于 avg）比平均延迟更能暴露问题——偶发慢请求通常来自抖动。

## 二、慢命令定位：slowlog 与 LATENCY 监控

### 1. slowlog：直接告诉你哪条命令慢

```bash
# 设置慢查询阈值（微秒），建议 10ms 起步，线上可 5ms
CONFIG SET slowlog-log-slower-than 10000
CONFIG SET slowlog-max-len 1024

# 查看最近 100 条慢命令
SLOWLOG GET 100
```

每条慢日志包含：**时间戳、执行耗时、命令及参数、客户端地址**。重点看耗时 TOP 的命令类型：

```bash
SLOWLOG GET 100 | grep -oP '"\w+"' | sort | uniq -c | sort -rn | head
# 统计慢命令分布，高频出现的基本就是元凶
```

典型慢命令黑名单：`KEYS *`、`SMEMBERS`（大 set）、`HGETALL`（大 hash）、`LRANGE 0 -1`（大 list）、`SINTER/SUNION`（大集合运算）、`ZRANGEBYSCORE` 全量、`MGET` 打满大 key。**`KEYS *` 会阻塞 Redis 数秒，线上绝对禁用**，用 `SCAN` 替代。

### 2. LATENCY 命令：Redis 内置的延迟事件监控

Redis 2.8.13+ 内置了延迟监控，能记录**事件发生的时刻和耗时**，专门抓"偶发变慢但抓不到现场"的场景：

```bash
# 开启
CONFIG SET latency-monitor-threshold 100   # 记录超过 100ms 的事件

# 查看所有事件类型
LATENCY LATEST
# 1) 1) "command"        ← 事件类型
#    2) (integer) 1754100000
#    3) (integer) 812     ← 耗时 812ms
#    4) (integer) 812

# 查看历史
LATENCY HISTORY command
```

LATENCY 能监控的事件类型包括：

| 事件 | 含义 | 常见根因 |
|---|---|---|
| `command` | 命令执行耗时 | 慢命令、大 key |
| `fork` | fork 子进程耗时 | 内存大 + 系统忙（RDB/AOF 重写触发） |
| `aof-write` | AOF 写入阻塞 | 磁盘慢、`appendfsync=always` |
| `aof-fsync-always` | 同步刷盘 | 磁盘 IO 瓶颈 |
| `rdb-unlink-temp-file` | 删除临时文件 | 大文件 + 慢盘 |
| `expire-cycle` | 过期键清理循环 | 大量同时过期的 key |

`fork` 事件尤其值得注意：Redis 做 RDB 快照或 AOF 重写时要 fork 子进程，**fork 期间主线程会阻塞**（要复制页表）。内存 10GB 的实例，fork 可能阻塞 100ms~1s 级别——所以大内存实例要错峰做持久化、避免频繁重写。

## 三、命令级检查：为什么这条命令慢

### 1. 大 key 是万恶之源

```bash
# 用 --bigkeys 扫描（内部是 SCAN，不阻塞）
redis-cli --bigkeys

# 更精细：按类型分析
redis-cli --memkeys --bigkeys
```

大 key 的危害：`HGETALL`/`SMEMBERS`/`LRANGE` 一次返回几十 MB，单线程执行期间**所有其他请求排队**；同时大 key 的删除（`DEL`）本身也会阻塞——Redis 4.0+ 用 `UNLINK` 异步删除，或对 hash/set/zset 用 `HSCAN` 分批删。

### 2. 检查对象编码是否退化

```bash
OBJECT ENCODING user:10086   # 返回 int/embstr/raw/hashtable...
```

listpack/ziplist 编码的 hash/zset 操作是 O(1) 级别的紧凑内存操作；一旦元素过多退化成 `hashtable`/`skiplist`，同样命令会变慢几个数量级。Redis 7.4 全面转向 listpack 后此问题缓解，老版本要关注 `hash-max-listpack-entries` 等阈值配置。

### 3. 客户端侧：连接池与请求模式

慢不一定是 Redis 慢，也可能是客户端用法问题：

- **连接数打满**：`INFO clients` 看 `connected_clients` 是否逼近 `maxclients`，连接排队；
- **频繁建连**：每次请求新建连接（内网建连也要 0.1~1ms），用连接池；
- **Pipeline 缺失**：批量小命令一条条发，RTT 叠加，改用 Pipeline 或 Lua；
- **序列化过大**：value 是几 KB 的 JSON 字符串，网络传输和内存拷贝都放大延迟。

## 四、服务器层：fork、内存、Swap、碎片

### 1. 看 INFO 关键指标

```bash
redis-cli INFO | grep -E "used_memory_human|mem_fragmentation_ratio|evicted_keys|expired_keys|total_commands_processed|instantaneous_ops_per_sec|rdb_last_bgsave_status|aof_last_bgrewrite_status"
```

重点：
- `mem_fragmentation_ratio` > 1.5：内存碎片严重，考虑 `activedefrag yes`（Redis 4.0+）或重启大版本升级；
- `evicted_keys` 飙升：内存淘汰触发，可能伴随大量 `DEL` 和缓存击穿；
- `rdb_last_bgsave_status` 非 ok：持久化失败，IO 有问题。

### 2. Swap：性能杀手

Redis 要求所有数据在内存，一旦发生 **Swap**（内存页被换到磁盘），延迟直接从微秒级跳到**毫秒~秒级**，且极难排查：

```bash
# 服务器上查看 Redis 进程 swap 情况
cat /proc/$(pgrep redis-server)/status | grep -i swap
# VmSwap: 12 kB   ← 正常应该接近 0，只要出现几百 KB 以上就要警惕

# 内存分配情况
redis-cli INFO memory | grep -E "used_memory|maxmemory"
```

出现 Swap 的处置：确认 `maxmemory` 设置合理、检查是否有同机其他进程抢内存、考虑 `memory policy`；Swap 一旦发生，即使换回也需要很长时间，严重时直接主从切换重启。

### 3. 透明大页（THP）必须关

Linux 的 Transparent Huge Pages 会导致 Redis 在写操作时发生 **内存页拷贝**（COW 放大），是 Redis 延迟抖动的经典来源：

```bash
# 检查（应该输出 never / madvise 中非 always 且对 redis 无影响）
cat /sys/kernel/mm/transparent_hugepage/enabled

# 关闭（需写入 /etc/rc.local 或 systemd 持久化）
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

Redis 官方文档明确建议关闭 THP，否则 fork 后的 COW 会把写延迟放大几个数量级。

## 五、内核与网络层：看不见的邻居

Redis 进程没问题、命令没问题，还慢？往上走：

### 1. 网卡软中断与 CPU 亲和性

```bash
# 查看软中断分布
cat /proc/softirqs | grep NET
# 多队列网卡每个队列绑一个 CPU，如果 Redis 的 CPU 和网卡中断 CPU 是同一个且被打满，
# Redis 线程会被频繁抢占 → 抖动

# Redis 绑核（避免被调度器迁移）
taskset -pc <cpu_list> $(pgrep redis-server)
```

云上虚拟机尤其要查**宿主机邻居**：同物理机的其他 VM 打满带宽/CPU，你的延迟就会莫名抖动。用 `--intrinsic-latency` 在本机测，如果本机都抖，基本就是宿主机/内核问题。

### 2. 网络层排查清单

```bash
# 客户端机器上看 TCP 重传（重传 = 延迟暴涨）
netstat -s | grep -i retrans
# 丢包率
ping -c 100 your.redis.host | grep loss
# 连接队列溢出（accept queue 满导致握手慢）
ss -lnt | grep 6379
```

### 3. 内核参数

```bash
# 查看是否有内存回收压力（redis 被换出的前兆）
grep -E "pgscand|pgsteal" /proc/vmstat
```

## 六、完整排查流程图

```
业务侧 Redis 调用变慢
│
├─ 1. 客户端 --latency 测试 → 抖动大？
│     ├─ 是 → 服务器本机 --intrinsic-latency
│     │        ├─ 本机也高 → 查宿主机/内核/THP/Swap/软中断
│     │        └─ 本机正常 → 网络链路问题（丢包/带宽/防火墙）
│     └─ 否 → 平均延迟高？→ 网络 RTT 或命令本身慢
│
├─ 2. SLOWLOG GET → 有慢命令？
│     ├─ KEYS*/大集合操作 → 改 SCAN/拆分/限制返回量
│     └─ 慢命令指向大 key → --bigkeys 定位 → 拆分/异步删除
│
├─ 3. LATENCY LATEST → fork 事件多？
│     ├─ 是 → 大内存实例频繁 BGSAVE/BGREWRITEAOF → 错峰/调参
│     └─ aof-write 慢 → 磁盘 IO 瓶颈 → 换盘/调 appendfsync
│
├─ 4. INFO 检查 → 碎片率高/evicted_keys 飙升/发生 Swap
│     └─ 对症处理：activedefrag / 调 maxmemory / 主从切换
│
└─ 5. 都正常？→ 客户端连接池/序列化/业务并发模式复盘
```

## 面试连环问

**Q：Redis 为什么是单线程，变慢排查为什么难？**
A：单线程意味着任何一条慢命令、任何一次 fork/刷盘阻塞都会让**所有请求排队**，所以"偶发变慢"往往不是当前请求的问题，而是某个瞬时事件（慢命令、fork、Swap、邻居干扰）造成的全局抖动，需要从命令、进程、内核、网络分层排查。

**Q：KEYS 命令为什么不能在生产用？**
A：KEYS 会遍历全库匹配，O(N) 且期间阻塞单线程，数据量大时直接卡死服务几秒到几十秒。用 SCAN 游标式分批扫描替代。

**Q：大 key 删除也会阻塞？怎么安全删？**
A：DEL 大 key 需要释放连续内存块，期间阻塞。Redis 4.0+ 用 UNLINK 异步删除；老版本用 HSCAN/SSCAN 分批删除，或对集合用 `SUNIONSTORE` 技巧先取出再删。

**Q：fork 为什么会阻塞主线程？**
A：RDB 快照/AOF 重写需 fork 子进程，fork 要复制父进程页表，内存越大、系统越忙耗时越长，期间主线程阻塞。所以大内存实例要错峰持久化、控制重写频率，并关闭 THP 减少 COW 放大。

**Q：排查 Redis 变慢，你的第一反应是什么？**
A：先做基线分层：客户端 `--latency` 和服务器 `--intrinsic-latency` 对比，区分是网络问题还是进程问题；再看 `SLOWLOG` 和 `LATENCY LATEST` 抓慢命令和事件；然后查 `INFO`（碎片、淘汰、Swap）；最后查内核层（THP、软中断、宿主机邻居）。切忌一上来就重启。

## 总结

Redis 变慢排查的本质是**分层定位 + 抓瞬时现场**：用 `--intrinsic-latency` 划清网络与进程的边界，用 `slowlog` 和 `LATENCY` 抓住"案发时刻"，用 `INFO`/`/proc` 排除内存与内核干扰。预防层面：关 THP、监控 Swap、大 key 治理、持久化错峰、`slowlog` 常态化开启——把这些做成巡检项，比出事后再排查值钱得多。
