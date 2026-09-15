---
title: 【Redis 运维】内存碎片深度解析与治理：mem_fragmentation_ratio 背后的真相与 activedefrag 实战
date: 2026-09-15 08:00:00
tags:
  - Redis
  - 内存管理
  - 运维
  - 性能优化
categories:
  - Redis
  - 中间件
author: 东哥
---

# 【Redis 运维】内存碎片深度解析与治理：mem_fragmentation_ratio 背后的真相与 activedefrag 实战

## 面试官：Redis 实际占用 8G，但数据只有 4G，多出来的内存去哪了？

这是 Redis 运维里最容易被误判的告警之一。

监控告警一响，多数人的第一反应是「内存泄漏了」或者「是不是大 Key」。但真实原因经常是另一回事：**内存碎片（Memory Fragmentation）**。

更微妙的是，碎片这件事在 Redis 里有一堆**反直觉**的细节：

- `mem_fragmentation_ratio < 1` 通常不报错，但它其实是**交换分区正在被使用**的严重信号；
- 内存碎片率超过 1.5 就该告警，但**不是所有场景都该开 `activedefrag`**；
- 有时候碎片率很高，`activedefrag` 却一动不动——因为它被主从复制、持久化、集群模式悄悄拦住了。

这篇文章把碎片的**成因、观测、治理**讲完整，并重点说清 `activedefrag` 为什么经常「失效」。

---

## 一、Redis 内存到底花在哪了

在看碎片之前，先建立完整的内存全景。`INFO memory` 输出的关键字段：

```bash
127.0.0.1:6379> INFO memory
# Memory
used_memory:4294967296                     # Redis 自己统计的「数据」内存（字节）
used_memory_human:4.00G
used_memory_rss:8589934592                 # 操作系统看到的「进程实际驻留物理内存」
used_memory_rss_human:8.00G
used_memory_peak:4831838208
used_memory_lua:37888
used_memory_scripts:0
maxmemory:10737418240
maxmemory_policy:allkeys-lru
mem_fragmentation_ratio:2.00               # = rss / used_memory
mem_allocator:jemalloc-5.1.0
```

**第一个关键等式：**

```
mem_fragmentation_ratio = used_memory_rss / used_memory
```

它衡量的是「操作系统给我的物理内存」与「Redis 自己认为的数据内存」的比值。

但这里有个必须先破除的误区：**`used_memory` 不包含内存碎片，也不包含分配器开销。** 所以：

```
used_memory  = 数据 + 各种缓存/缓冲区（客户端缓冲、复制缓冲、AOF 缓冲、Lua 等）
used_memory_rss = used_memory + 碎片 + 分配器元数据 + 进程其他开销
```

因此：

| 比值 | 含义 | 处理 |
| --- | --- | --- |
| ≈ 1.0 ~ 1.3 | 健康 | 无需处理 |
| > 1.5 | **碎片率偏高** | 考虑 `activedefrag` 或重启 |
| >> 1.5（如 2.0+） | 碎片严重 | 必须治理 |
| **< 1.0** | **极度危险** | 说明发生了 swap，性能已崩 |

### 为什么 `< 1` 是灾难而不是好事？

比率小于 1，意味着 `rss` 比 `used_memory` 还小。物理内存怎么会比数据还少？**因为一部分内存被换出到 swap 了。**

操作系统把 Redis 的页换到磁盘，`rss` 统计里就"少"了。而 Redis 是延迟敏感型服务，任何一次访问触发缺页中断（page fault）从磁盘换入，延迟会从微秒级直接跳到毫秒级甚至更高。

**所以监控规则应该是**：

```
mem_fragmentation_ratio < 0.9  → P0 告警（swap 已发生）
mem_fragmentation_ratio > 1.5  → P2 告警（碎片偏高）
```

顺带一句：**生产环境 Redis 机器不建议开 swap**（或者把 `vm.swappiness` 调到很低）。让 Redis 因为 OOM 快速失败，比让它悄无声息地变慢要好得多。

---

## 二、碎片是怎么产生的

碎片不是「泄漏」，内存没有被丢掉，只是**被切得太碎、无法复用**。产生路径主要有四条。

### 2.1 jemalloc 的分层分配机制

Redis 默认使用 **jemalloc** 作为内存分配器（`mem_allocator:jemalloc-5.x`）。jemalloc 用「size class + arena + bin」的分层结构来加速分配：

- 请求的内存会被**向上取整到最近的 size class**（例如请求 100 字节，实际给 112 字节）
- 每个 size class 有自己的一组 bin（空闲块链表）
- 每个线程绑定一个 arena，减少锁竞争

这套设计大幅提升了分配性能，代价是：

1. **内部碎片**：请求 100 字节拿到 112 字节，浪费 12 字节
2. **外部碎片**：不同 size class 的空闲块不能互相复用——一个 112 字节的空闲块，永远无法满足 256 字节的请求

### 2.2 数据频繁增删导致的不均匀释放

这是生产环境最常见的成因。典型场景：

```
写入 100 万个小 String（占满 arena 的小块区）
→ 删除一半（释放出大量散落的小块）
→ 写入 10 万个 Hash（需要中大块）
→ 小块无法复用，新申请中大块 → RSS 涨了，used_memory 没涨那么多 → 碎片率上升
```

**碎片率高的本质是「释放的块」和「需要的块」形状不匹配。**

### 2.3 大 Key 增删造成的锯齿

一个 500 万元素的 Hash，如果 Redis 7.2 之前一次性删除，会在一瞬间释放大量不连续内存；如果这些内存分布在不同 size class 上，回收后很难被重新组织利用。

Redis 后来引入了 `lazyfree`（`UNLINK`、`lazyfree-lazy-*` 系列参数）解决删除卡顿，但**懒删除并不解决碎片**——它只是把释放动作异步化。

### 2.4 过期删除的影响

`actively-expire` 的定时删除和内存淘汰策略都会在运行时摘除数据，效果同 2.2。**也就是说：一个持续有过期键在循环写入的实例，天然就是碎片生产机。**

---

## 三、观测：怎么判断碎片是「问题」还是「正常」

### 3.1 基础字段

```bash
INFO memory | grep -E "used_memory:|used_memory_rss:|mem_fragmentation_ratio|allocator_frag"
```

Redis 4.0+ 还暴露了 **分配器视角的碎片指标**：

```bash
127.0.0.1:6379> INFO memory
allocator_active:5368709120
allocator_allocated:4294967296
allocator_resident:8589934592
allocator_frag_ratio:1.25          # allocator_active / allocator_allocated
allocator_frag_bytes:1073741824
allocator_rss_ratio:1.60           # allocator_resident / allocator_active
allocator_rss_bytes:3221225472
rss_overhead_ratio:1.02            # rss / allocator_resident
rss_overhead_bytes:167772160
```

它们的关系是层层向上的：

```
allocator_allocated  （Redis 请求的字节总数，含对齐开销）
    ↓ ×allocator_frag_ratio
allocator_active     （jemalloc 实际持有的 arena 内存，含未使用的空闲块）
    ↓ ×allocator_rss_ratio
allocator_resident   （物理驻留内存，含脏页/未归还页）
    ↓ ×rss_overhead_ratio
used_memory_rss      （进程总驻留内存）
```

**这套指标的价值**在于精确定位碎片来源：

| 指标偏高 | 说明什么 | 对策 |
| --- | --- | --- |
| `allocator_frag_ratio` 高 | **jemalloc 层面碎片**，空闲块无法复用 | `activedefrag` 最有效 |
| `allocator_rss_ratio` 高 | 分配器持有但 OS 未回收的页 | 部分归还可通过重启；`activedefrag` 有限 |
| `rss_overhead_ratio` 高 | 非分配器开销（如 fork COW、THP 等） | 查持久化/fork 与 THP 配置 |

### 3.2 对比 `used_memory_peak`

如果 `used_memory_peak` 很高（历史曾到 9G）但当前只有 4G，说明**曾经有过大规模数据**，碎片很可能是它留下的遗迹。这时碎片率高低是「历史遗留」而非「当前压力」。

### 3.3 压测基准法

最靠谱的判断方式：**在业务量稳定的窗口期，对比重启前后的 `used_memory_rss`**。

如果重启后 RSS 从 8G 掉到 4.5G，且业务数据量没变，那 3.5G 就是货真价实的碎片。

---

## 四、治理方案一：activedefrag 主动碎片整理

Redis 4.0 引入了 `activedefrag`，可以在运行时把碎片整理掉，不用重启。

### 4.1 开启方式

**运行时开启：**

```bash
CONFIG SET activedefrag yes
```

**配置文件中（推荐，可持久化）：**

```conf
# 开关
activedefrag yes

# 触发阈值：碎片字节数下限（默认 100MB）
active-defrag-ignore-bytes 100mb

# 触发阈值：碎片率下限（默认 1.1）
active-defrag-threshold-lower 10

# 触发上限：碎片率超过此值则全速整理（默认 1.5）
active-defrag-threshold-upper 100

# 每次整理的 CPU 占用下限/上限（百分比）
active-defrag-cycle-min 1
active-defrag-cycle-max 25

# 单次扫描的最大字典/跳跃表/列表节点数占比
active-defrag-max-scan-fields 1000
```

`active-defrag-threshold-lower/upper` 的语义容易看错，这里说清：

- 碎片率 **低于** `lower`（默认 10%）→ 完全不整理
- 碎片率 **在 lower 和 upper 之间** → 按 `active-defrag-cycle-min` 的 CPU 比例**渐进整理**
- 碎片率 **高于** `upper` → **全速整理**（最多吃到 `cycle-max` 的 CPU）

### 4.2 效果验证

```bash
INFO memory | grep -E "mem_fragmentation_ratio|allocator_frag_ratio"
```

观察 `allocator_frag_ratio`（不是 `mem_fragmentation_ratio`）才是正确姿势——**activedefrag 整理的是 jemalloc 的 arena 碎片，通常表现为 `allocator_frag_ratio` 下降明显，而 `mem_fragmentation_ratio` 下降有限。**

这是很多人误以为「activedefrag 没用」的原因。

### 4.3 ⚠️ activedefrag 失效的四个场景

这是本文最值钱的部分。**开了 activedefrag 却一点不动，通常是下面四条之一：**

**① 启用了 RDB/AOF 持久化的 fork 期间**

`activedefrag` 依赖对内存的搬迁，期间会触发页的写时复制（COW）。如果同时在做 RDB fork 或 AOF rewrite，Redis 会主动抑制/降低 defrag 强度以避免放大 COW。

**② 主从复制场景下的 slave**

复制链路要求主从数据一致，defrag 的搬迁会加大复制缓冲区压力，因此在特定版本/配置下会被限制。

**③ 集群模式（cluster-enabled yes）**

官方向来对集群下的 activedefrag 持保守态度：节点间搬迁与迁移（migrate）操作可能冲突。

**④ 碎片率没到阈值**

前面说的 `active-defrag-ignore-bytes`（100MB）和 `active-defrag-threshold-lower`（10%）是**同时满足**才触发。默认配置下，很多「看着很高」的碎片率其实没到触发线——比如 `mem_fragmentation_ratio=1.3` 但 `allocator_frag_ratio` 只有 1.05，那确实没什么好整理的。

**排查命令：**

```bash
# 看当前是否在 defrag、整理了多少
INFO stats | grep -E "active_defrag"
# active_defrag_running:0
# lazyfree_pending_objects:0
```

`active_defrag_running` 长期为 0 而碎片率又很高，就按上面四条逐一排除。

---

## 五、治理方案二：重启与主从切换

当 `activedefrag` 无力回天（比如 `allocator_rss_ratio` 高，即页已归还 OS 却未释放），最干脆的方案是**滚动重启**。

标准操作（利用主从切换做到不停机）：

```bash
# 1. 重启从节点
redis-cli -h slave-1 SHUTDOWN NOSAVE
# 启动 slave-1，等待全量/增量同步完成
redis-cli -h master INFO replication | grep slave1

# 2. slave-1 与 master 做角色切换
redis-cli -h slave-1 REPLICAOF NO ONE
redis-cli -h master  REPLICAOF slave-1

# 3. 重启旧的 master（现为从节点），完成后等待同步
```

**注意事项：**

- 重启前确认 `maxmemory` 小于机器物理内存的 70%~80%，否则重启后可能直接 OOM
- 重启会触发全量同步（RDB 传输 + 加载），耗时与数据量成正比，务必在业务低峰期
- `SHUTDOWN NOSAVE` 避免重启前又写一次 RDB
- 客户端需要能自动感知主从切换（Sentinel / Cluster / 客户端多分片配置）

### 5.1 不重启的「折中方案」：配置回收

jemalloc 有一个行为：**只有在特定条件下才会把空闲的脏页归还 OS**（`madvise(MADV_DONTNEED)`）。可以通过环境变量微调：

```bash
# 调整 jemalloc 的脏页衰减时间（毫秒），默认 10000ms
MALLOC_CONF="dirty_decay_ms:1000,muzzy_decay_ms:0"
```

这个手段收益不稳定（取决于版本和碎片分布），属于「可以试试，别指望它」的级别。

---

## 六、预防：从源头减少碎片

治不如防。下面六条是长期有效的工程实践。

### 6.1 规划好数据结构的尺寸

```bash
# 差：把 100 万字段塞进一个 Hash
HSET big:hash field1 v1 field2 v2 ...  # 百万次

# 好：按业务维度分片
HSET user:{1..10000}:profile field1 v1
```

**单 Key 元素数量控制在几千以内**，既避免大 Key，也让内存块形状更均匀。

### 6.2 用 UNLINK 代替 DEL

```bash
# 优雅删除大 Key，避免主线程阻塞
UNLINK big:hash
```

配置层面全局开启：

```conf
lazyfree-lazy-eviction yes     # 淘汰时异步释放
lazyfree-lazy-expire yes       # 过期时异步释放
lazyfree-lazy-server-del yes   # 隐式 DEL 异步化
replica-lazy-flush yes         # 从节点加载前 flush 异步化
lazyfree-lazy-user-del yes     # 用户 DEL 异步化
lazyfree-lazy-user-flush yes
```

### 6.3 避免「大进大出」的缓存模式

```java
// 差：整批写入、整批删除，产生剧烈的内存形状变化
redisTemplate.delete(keyList);
redisTemplate.opsForValue().multiSet(bigMap);

// 好：控制批大小，保持内存分配平稳
for (int i = 0; i < list.size(); i += 500) {
    // 分批处理
}
```

### 6.4 处理 jemalloc arena 与线程的关系

Redis 是单线程处理命令的（6.0 的 IO 多线程只处理网络读写），因此 arena 竞争不严重。但 `io-threads` 开启后会有多个线程，可以显式设置：

```bash
MALLOC_CONF="background_thread:true"
```

`background_thread` 让 jemalloc 在后台线程做内存整理/归还，能显著减少碎片堆积——**这是最容易被忽略、但收益最实在的一条配置。**

### 6.5 关闭透明大页（THP）

```bash
# 检查
cat /sys/kernel/mm/transparent_hugepage/enabled
# [always] madvise never  ← 中括号在 always 表示已开启，需要关掉

# 永久关闭
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

THP 会导致 fork 时 COW 放大、内存归还粒度变粗（2MB 大页难以部分释放），是 Redis 官方明确建议关闭的项。**它同时恶化碎片和持久化延迟。**

### 6.6 合理设置 maxmemory

```conf
maxmemory 8gb                  # 留出 20%~30% 给碎片和开销
maxmemory-policy allkeys-lru
maxmemory-samples 5
```

**关键原则：不要把 `maxmemory` 设成机器内存的全量。** 碎片、复制缓冲、客户端缓冲都会额外占用，设置过满会在碎片高企时直接触发 OS OOM Killer。

---

## 七、面试常见追问

**Q1：`mem_fragmentation_ratio < 1` 说明什么？**

说明 `used_memory_rss < used_memory`，即部分内存已被换出到 swap。这是**性能事故的前兆**，不是"内存利用得好"。处理方式是检查 swap 配置、`vm.swappiness`、并确认机器内存是否被其他进程挤占。

**Q2：碎片率高一定要处理吗？**

不一定。判断标准是「是否影响可用内存与稳定性」：如果 `maxmemory` 还有充足余量、没有触发淘汰、延迟 P99 正常，`ratio=1.4` 完全可以接受。**碎片是成本问题，不是正确性问题。**

**Q3：activedefrag 会影响性能吗？**

会，但可控。通过 `active-defrag-cycle-min/max` 把 CPU 占用限制在 1%~25%，且 `activedefrag` 的整理工作是**在事件循环的空闲时间分片执行**的，不会长时间阻塞主线程。但它会加剧 fork COW，所以**不要在 RDB/AOF 重写期间全速整理**。

**Q4：为什么我开了 activedefrag，`mem_fragmentation_ratio` 还是很高？**

因为 `activedefrag` 整理的是 **jemalloc 的 arena 内部碎片**，它能让空闲块重新可用（`allocator_frag_ratio` 下降），但**不负责把整页归还给操作系统**。判断 activedefrag 是否生效，要看 `allocator_frag_ratio` 和 `INFO stats` 里的 `active_defrag_running`，而不是 `mem_fragmentation_ratio`。

**Q5：Redis 6 的 IO 多线程对碎片有影响吗？**

有间接影响。IO 线程不执行命令，但会带来更多的内存分配路径。可以配合 `MALLOC_CONF="background_thread:true"` 让 jemalloc 的后台线程处理碎片，收益比调 `io-threads` 更明显。

**Q6：怎么预估重启能回收多少内存？**

在业务稳定期采集 `used_memory_peak` 与当前 `used_memory`。两者的差值加上 `allocator_frag_bytes`，大致就是重启后能回收的上限。**更稳妥的做法是先在从节点重启一次，实测 RSS 变化后再决定是否滚动全量重启。**

---

## 八、一句话总结

> `mem_fragmentation_ratio = rss / used_memory`，**>1.5 是碎片，<1 是 swap，两者是完全不同的事故等级。**
>
> 治理顺序：**先看 `allocator_frag_ratio` 定位碎片层级 → 开 `activedefrag` 并调好阈值 → 用 `background_thread` + 关 THP 从源头抑制 → 最后才考虑滚动重启。**
