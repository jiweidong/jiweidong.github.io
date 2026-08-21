---
title: 【系统设计】负载均衡算法深度解析：轮询、加权、最少连接与一致性哈希全对比
date: 2026-08-21 08:00:00
tags:
  - 负载均衡
  - 系统设计
  - 分布式
categories:
  - 系统设计
  - 高可用架构
author: 东哥
---

# 【系统设计】负载均衡算法深度解析：轮询、加权、最少连接与一致性哈希全对比

## 面试官：Nginx 的 upstream 里有十几种负载均衡算法，你怎么选？

负载均衡是分布式系统的地基：把请求分散到多台服务器，解决单点瓶颈。但"分散"的策略千差万别——是平均分配，还是按机器性能分配？是按连接数动态调整，还是保证同一用户永远打到同一台机器？这就是负载均衡算法的学问。

先给一张全景图，把主流算法按"是否感知服务器实时状态"分成两类：

| 分类 | 算法 | 是否感知后端负载 | 典型场景 |
|------|------|-----------------|---------|
| 静态算法 | 轮询（Round Robin） | 否 | 后端性能均匀 |
| 静态算法 | 加权轮询（WRR） | 否 | 后端性能不均 |
| 静态算法 | IP Hash / 一致性哈希 | 否 | 会话保持、缓存路由 |
| 动态算法 | 最少连接（Least Connections） | 是（连接数） | 长连接、耗时波动大 |
| 动态算法 | 加权最少连接 | 是 | 性能 + 负载双重考虑 |
| 动态算法 | 最快响应（EWMA） | 是（响应时间） | 延迟敏感服务 |

## 一、轮询（Round Robin）：最简单，也最"理想化"

轮流把请求分给每台服务器：1→2→3→1→2→3……

```java
public class RoundRobin {
    private final List<String> servers;
    private int index = 0;

    public RoundRobin(List<String> servers) { this.servers = servers; }

    public synchronized String next() {
        return servers.get(index++ % servers.size());
    }
}
```

**优点**：实现极简、绝对公平（请求数均分）。**缺点**：完全无视服务器实际状态——A 机器性能是 B 的 10 倍也只能分到同样的量；某台机器挂了还继续给它发请求（需要配合健康检查剔除）。

## 二、加权轮询（WRR）：给机器"打分"

按权重分配，性能强的机器多分请求。但朴素实现有个致命缺陷：**请求会"扎堆"**。

朴素实现：权重 5:1:1，顺序是 A A A A A B C——A 连续收到 5 个请求，压力依然集中。Nginx 采用的**平滑加权轮询（Smooth WRR，SWRR）** 解决了这个问题。

### 平滑加权轮询算法（重点）

每次选服务器时，把所有服务器的"当前权重"加上"初始权重"，选当前权重最大的那台，然后把它减去"总权重"。以 A=5, B=1, C=1 为例：

| 轮次 | 加权重后 | 最大 | 选中 | 减去总权重(7)后 |
|------|---------|------|------|----------------|
| 1 | A5 B1 C1 | A | A | A-2 B1 C1 |
| 2 | A3 B2 C2 | A | A | A-4 B2 C2 |
| 3 | A1 B3 C3 | B | B | A1 B-4 C3 |
| 4 | A6 B-3 C4 | A | A | A-1 B-3 C4 |
| 5 | A4 B-2 C5 | C | C | A4 B-2 C-2 |
| 6 | A9 B-1 C-1 | A | A | A2 B-1 C-1 |
| 7 | A7 B0 C0 | A | A | A0 B0 C0 |

最终序列：A A B A C A A —— 完美交错，既保证了 5:1:1 的比例，又没有请求扎堆。

```java
public class SmoothWeightedRoundRobin {
    static class Server {
        String name; int weight; int current;
        Server(String n, int w) { name = n; weight = w; }
    }

    public static Server next(List<Server> list) {
        int total = 0;
        Server best = null;
        for (Server s : list) {
            s.current += s.weight;   // 1. 每轮先加初始权重
            total += s.weight;
            if (best == null || s.current > best.current) best = s;
        }
        best.current -= total;       // 2. 选中的减去总权重
        return best;
    }
}
```

**这就是 Dubbo、gRPC Java 版、Ribbon 加权策略的底层模型**，面试手撕概率极高。

## 三、IP Hash 与一致性哈希：把"同一来源"钉在同一台机器

**IP Hash**：对客户端 IP 取哈希，模上服务器数量，得到目标机器。同一 IP 永远打到同一台机器——天然实现会话保持（Session 不漂移）。

**致命缺陷**：服务器数量变化（扩缩容、宕机）时，`hash(ip) % n` 的取模结果剧烈变化，**几乎所有映射关系都失效**，缓存全部击穿。

**一致性哈希** 解决这个问题：把服务器和请求都映射到一个 2^32 的哈希环上，请求沿环顺时针找第一台服务器。服务器增减只影响环上相邻的一小段区间，**只有约 1/n 的请求重新路由**。

为了均衡（服务器少时节点分布不均），引入**虚拟节点**：每台物理机在环上放 100~200 个虚拟副本，请求先落到虚拟节点再映射到物理机。

```java
public class ConsistentHash<T> {
    private final TreeMap<Integer, T> ring = new TreeMap<>();
    private final int virtualNodes;

    public ConsistentHash(List<T> nodes, int virtualNodes) {
        this.virtualNodes = virtualNodes;
        for (T node : nodes) add(node);
    }

    public void add(T node) {
        for (int i = 0; i < virtualNodes; i++) {
            int hash = hash(node.toString() + "#" + i);
            ring.put(hash, node);          // 虚拟节点 → 物理节点
        }
    }

    public T get(String key) {
        if (ring.isEmpty()) return null;
        int hash = hash(key);
        // 顺时针找第一个 >= hash 的节点，找不到则回到环头
        Map.Entry<Integer, T> entry = ring.ceilingEntry(hash);
        if (entry == null) entry = ring.firstEntry();
        return entry.getValue();
    }

    private int hash(String s) {
        // 用 MurmurHash/一致性哈希专用哈希，避免 String.hashCode 分布不均
        return s.hashCode() & 0x7fffffff;
    }
}
```

**应用场景**：Redis Cluster 的槽位路由（16384 个槽本质就是一致性哈希思想的工程化）、分布式缓存、网关会话保持。

## 四、最少连接（Least Connections）：动态感知后端压力

轮询系算法都是"盲发"，最少连接则统计每台服务器当前的活跃连接数，**永远选连接数最少的**。对长连接（WebSocket、数据库连接池、gRPC）和请求耗时波动大的服务，效果远好于轮询。

```java
public String next() {
    Server min = servers.get(0);
    for (Server s : servers) {
        if (s.activeConnections < min.activeConnections) min = s;
    }
    min.activeConnections++;
    return min.name;
}
```

Nginx 默认就是 `least_conn`；LVS、HAProxy 也都有对应策略。加权版就是 `least_conn` + 权重修正（连接数除以权重再比较）。

## 五、EWMA（指数加权移动平均）：让"慢机器"自动失宠

基于**响应时间**的动态算法：每台服务器维护一个 EWMA 值（历史平均响应时间，越近的采样权重越高），请求优先发给响应快的机器。

```
EWMA_new = α × 最近一次响应时间 + (1 - α) × EWMA_old    # α 通常取 0.1~0.3
```

它的好处是"自适应"：某台机器 GC 变慢、网络抖动，响应时间上升，EWMA 平滑上升，流量自动向其他机器倾斜，**不需要人工摘流**。Spring Cloud LoadBalancer、gRPC 的 weighted_target、Envoy 都有类似实现。

## 六、主流框架的负载均衡策略速查

| 框架/组件 | 默认策略 | 可选策略 |
|----------|---------|---------|
| Nginx | 加权轮询 | least_conn、ip_hash、hash key、random、fair |
| LVS | 加权轮询 | WLC（加权最少连接）、SH（源地址哈希）等 |
| Dubbo | 加权随机 | 加权轮询、最少活跃、一致性哈希、最短响应 |
| Spring Cloud LoadBalancer | 轮询 | 随机、权重、自定义（可以换成最少连接/一致性哈希） |
| gRPC | 加权轮询（pick_first/round_robin） | 一致性哈希（xds 场景） |
| Kafka 消费组 | RangeAssignor/CooperativeSticky | 按分区数均衡分配（类似最少连接思想） |

## 七、选型决策树（面试加分项）

1. **后端配置完全一样、请求无状态** → 轮询（简单可靠）
2. **后端性能有差异** → 平滑加权轮询（SWRR）
3. **需要会话保持/缓存亲和** → 一致性哈希 + 虚拟节点（注意：会牺牲均衡性，热 key 时要配合"最小节点"策略）
4. **长连接 / 请求耗时波动大** → 最少连接
5. **延迟敏感、自动故障转移** → EWMA/最快响应
6. **真实生产**：很少用单一算法，通常是"加权轮询/最少连接 + 健康检查 + 熔断剔除"的组合

**常见追问：一致性哈希和取模哈希的本质区别？**
取模哈希是"全局映射"——n 变化，所有 key 的映射都变；一致性哈希是"局部映射"——只影响环上相邻区间，迁移成本 O(1/n)。代价是实现复杂、分布可能不均（需虚拟节点）。

**再追问：Session 保持用 IP Hash 还是 Redis 共享 Session？**
有 Redis 就别用 IP Hash——IP Hash 在 NAT/移动网络下会失效（出口 IP 变化），且扩缩容会导致 Session 漂移。IP Hash 适合"没有共享存储"的存量系统；新系统优先"无状态化 + 外部 Session 存储"，负载均衡算法可以纯轮询。

## 总结

负载均衡算法从"盲发"到"感知"演进：轮询 → 平滑加权轮询（解决扎堆）→ 一致性哈希（解决缓存失效风暴）→ 最少连接/EWMA（动态感知后端）。选型没有银弹，核心是**结合请求特征（状态/耗时/长连接）与后端特征（性能/稳定性）**。面试时把 SWRR 的手撕代码、一致性哈希的环与虚拟节点、以及"为什么 Nginx 默认用 SWRR 而不是朴素加权轮询"讲清楚，基本就稳了。
