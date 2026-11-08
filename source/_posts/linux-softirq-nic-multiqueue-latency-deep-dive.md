---
title: 【性能调优】软中断与网卡多队列深度解析：Java 服务 P99 抖动的另一半真相
date: 2026-11-08 08:10:00
tags:
  - 性能优化
  - Linux
  - Netty
  - 网络
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】软中断与网卡多队列深度解析：Java 服务 P99 抖动的另一半真相

## 前言

一个很典型的求助场景：

> 8 核机器，Java 服务 CPU 使用率只有 25%，GC 日志干净得像教科书，JFR 里也没有长停顿，可是接口 P99 每隔几分钟就抖到 300ms，而且业务量并没有波动。

`top` 按 `1` 展开每核：

```
%Cpu0  :  8.2 us,  0.0 sy,  0.0 ni, 55.0 id,  0.0 wa,  0.0 hi, 36.8 si,  0.0 st
%Cpu1  : 18.4 us,  2.1 sy,  0.0 ni, 79.5 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
...
```

`si`（softirq）36.8%，而 `us` 只有 8%。CPU0 被软中断吃掉了三分之一，应用线程一旦被调度到这颗核上，就会莫名其妙地"变慢"。

**这类问题的战场不在 JVM 里，在网卡到 socket 的那 200 微秒里。** 这篇把中断 → 软中断 → NAPI → 协议栈 → socket 接收队列这条链路拆开，讲清楚它怎么变成 Java 服务的尾延迟。

---

## 一、一个包进来，内核做了什么

```
网卡 DMA 写 ring buffer
      ↓  硬中断（上半部，只做登记，几十纳秒）
      ↓  raise NET_RX_SOFTIRQ
   ┌──────────────────────────────┐
   │  软中断（下半部）             │
   │  net_rx_action → NAPI poll   │
   │  → GRO 合并 → 协议栈处理      │
   │  → 找到 socket → sk_rmem     │
   └──────────────────────────────┘
      ↓  唤醒等待的进程
   应用 read() / epoll_wait 返回
```

三层要点：

| 阶段 | 执行上下文 | 关键约束 |
|---|---|---|
| 硬中断（`hi`） | 中断上下文，关抢占 | **必须极短**，只登记并触发软中断 |
| 软中断（`si`） | 软中断上下文 / `ksoftirqd/N` 线程 | 有 budget 限制（`netdev_budget`），超预算转 `ksoftirqd` |
| 协议栈 + socket | 同上 | 接收队列满 → 丢包（`tcp_rmem`、backlog） |

所以 `si` 高意味着：**协议栈处理（校验和、路由查找、TCP 状态机、拷贝到 socket 缓冲）被压在了少数几颗 CPU 上**。

---

## 二、默认配置为什么把压力堆到 CPU0

绝大多数网卡在单队列模式下，**所有 RX 中断都绑到 CPU0**（或者 irqbalance 看似均衡但没起作用）。此时：

- 100 万 PPS 的流量，全部由 CPU0 的一个软中断上下文处理；
- 其他 7 颗核在空闲（`id` 高）；
- 应用线程被调度到 CPU0 时，要么等软中断做完，要么频繁被抢占；
- 表现出来就是：**总 CPU 不高，但尾延迟很难看**。

```bash
# 看每个 IRQ 落在哪颗 CPU：列是 CPU0..CPUn，数值是中断次数
cat /proc/interrupts | grep -E "eth0|ens|nvme"
```

典型的坏例子：

```
 42:  98123456   0   0   0   0   0   0   0   PCI-MSI-edge  eth0-TxRx-0
```

一个队列，全在 CPU0。

```bash
# 看软中断分布
cat /proc/softirqs | head -5
watch -n1 'cat /proc/softirqs | grep NET_RX'
```

---

## 三、RSS / RPS / RFS / XPS：四个容易混淆的机制

| 机制 | 工作层 | 是否改变物理队列 | 目的 | 配置位置 |
|---|---|---|---|---|
| **RSS** | 网卡硬件 | 是 | 多队列并行收包，硬件哈希分流 | `ethtool -L eth0 combined N` |
| **RPS** | 内核软中断 | 否 | 单队列网卡也能把软中断摊到多核 | `/sys/class/net/eth0/queues/rx-0/rps_cpus` |
| **RFS** | 内核软中断 | 否 | 让同一 flow 落到**应用线程所在 CPU**，提升 cache 命中 | `rps_flow_cnt` + `rps_sock_flow_entries` |
| **XPS** | 内核发送侧 | 否 | 发送时选与中断同核的队列，减少跨核 | `/sys/class/net/eth0/queues/tx-0/xps_cpus` |

一句话区分：**RSS 是"多开几条收银台"，RPS 是"一条收银台但多个收银员分流"，RFS 是"让熟客去找他最熟悉的那位收银员"。**

查看与开启：

```bash
# 1) 网卡是否支持多队列
ethtool -l eth0
# Combined: 1  ← 只有 1 个队列，说明没开 RSS

# 2) 开启 8 个队列（需网卡/驱动支持，可能要重载驱动）
ethtool -L eth0 combined 8

# 3) 确认中断已经分散（此时应有 eth0-TxRx-0..7）
grep eth0 /proc/interrupts

# 4) 没有多队列硬件能力时，用 RPS 兜底：把 rx-0 的软中断摊到 CPU0-3
echo 0f > /sys/class/net/eth0/queues/rx-0/rps_cpus

# 5) 开启 RFS（需内核 CONFIG_RPS + 应用侧 SO_INCOMING_CPU 配合）
sysctl -w net.core.rps_sock_flow_entries=32768
echo 4096 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt
```

⚠️ **RPS 的代价**：包在内核里要经过一次跨 CPU 的队列传递（`process_queue`），会增加 cache miss 与延迟抖动。所以**优先 RSS，RPS 只作为没有多队列硬件时的兜底**。

⚠️ **容器里的坑**：RPS 的 CPU 掩码是**宿主机视角**的 CPU 编号。如果容器只被分配了 cpuset `4-7`，你写 `0f` 是无效的（指向了容器外的核），必须写 `f0`。这个坑在 K8s 环境里非常常见——配置"看起来生效了"，实际包仍然堆在宿主机 CPU0 上。

---

## 四、诊断三件套：`softnet_stat`、`ethtool -S`、`ss`

### 4.1 `/proc/net/softnet_stat`：软中断的账本

```bash
cat /proc/net/softnet_stat
# 每行对应一颗 CPU，字段是十六进制
# 第1列 processed        处理过的包数
# 第2列 dropped          因为 backlog 满而丢弃（严重！）
# 第3列 time_squeeze     软中断预算耗尽、被迫让出 CPU 的次数
```

解读：

| 现象 | 含义 | 处理 |
|---|---|---|
| 第 2 列在涨 | `netdev_max_backlog` 不够，**真的丢包了** | 调大 backlog，或上游限速 |
| 第 3 列在涨 | 单次软中断没处理完预算就超时 | 调大 `netdev_budget` / `netdev_budget_usecs`，或分摊到多核 |
| 某一行远高于其他行 | 软中断集中在一颗核 | 检查 RSS/RPS/中断亲和性 |

```bash
sysctl net.core.netdev_max_backlog   # 默认 1000，万兆网卡建议 8192+
sysctl net.core.netdev_budget        # 默认 300 个包/轮
sysctl net.core.netdev_budget_usecs  # 默认 2000 微秒/轮
```

### 4.2 `ethtool -S`：网卡侧的丢包真相

```bash
ethtool -S eth0 | grep -Ei "drop|err|miss|no_buffer|fifo"
```

重点字段：

- `rx_missed_errors` / `rx_no_buffer_count`：**网卡 ring buffer 满了**，包在进入内核之前就被丢了 → 调大 `ethtool -G eth0 rx 4096`。
- `rx_fifo_errors`：FIFO 溢出，同样是收不过来。
- `tx_dropped`：发送侧队列满。

这类丢包在应用侧表现为"TCP 重传 + 延迟尖刺"，而不是"连接失败"，所以很多人查不到。

### 4.3 `ss` 与 `netstat -s`：socket 层

```bash
ss -lnt | head            # Send-Q 列 = listen backlog 上限；Recv-Q = 当前全连接队列长度
netstat -s | grep -i -E "overflow|retrans|pruned"
```

如果 `Recv-Q` 长期接近 `Send-Q`，说明**全连接队列快满了**：不是网络慢，是你的 accept 速度跟不上（Java 侧 `accept` 线程或 Netty boss 线程不够）。这属于"应用层背压"，和软中断是两个不同环节，但现象都是"连接超时"。

---

## 五、把中断亲和性和应用线程绑核配合起来

这是本篇最容易被忽略、但收益最大的一节。

**错误做法**：中断分散到 8 颗核，Netty worker 也跑在 8 颗核。结果两边互相抢，`si` 抢占应用线程，尾延迟抖动。

**正确做法**：**中断核与业务核物理隔离**。

```bash
# 例：8 核机器
# CPU0-1：留给系统与软中断
# CPU2-7：跑 Java 应用

# 1) 关掉 irqbalance，手工绑定
systemctl stop irqbalance

# 2) 把 eth0 的 8 个队列中断绑到 CPU0-1（掩码 0x3）
for i in $(grep eth0 /proc/interrupts | awk -F: '{print $1}'); do
  echo 3 > /proc/irq/$i/smp_affinity
done

# 3) 应用绑到 CPU2-7
taskset -c 2-7 java -jar app.jar
```

在 K8s 上对应的做法是：

```yaml
# 1) 用 cpuset 给 Pod 独占核（需 kubelet 开启 static CPU manager policy）
resources:
  limits:
    cpu: "6"
    memory: 8Gi

# 2) 用 topologyManagerPolicy: single-numa-node 保证 NUMA 局部性
# 3) 使用 CNI 的多队列 + 中断亲和（多数云厂商的 Terway/Cilium 已有配套）
```

⚠️ 别用 `cpu: "6"` 这种**十进制小数**表达 CPU 数（K8s 里 `"6"` 是 6 核，`6.5` 是 6.5 核，但 `6000m` 与 `6` 在现代版本等价）。真正决定"独占核"的是 kubelet 的 `cpuManagerPolicy: static` + **Guaranteed QoS**（requests == limits，且是整数核）。

Java 侧对应的线程规模：

```java
// Netty：worker 线程数默认 = CPU * 2，绑核后要按"可用核数"配，而不是机器核数
EventLoopGroup boss = new NioEventLoopGroup(1);
EventLoopGroup worker = new NioEventLoopGroup(
        Integer.getInteger("io.netty.eventLoopThreads",
                Math.max(2, Runtime.getRuntime().availableProcessors())));

ServerBootstrap b = new ServerBootstrap();
b.group(boss, worker)
 .channel(NioServerSocketChannel.class)   // Linux 上可选 EpollServerSocketChannel
 .option(ChannelOption.SO_BACKLOG, 4096)  // 与 ss 看到的 Send-Q 对应
 .childOption(ChannelOption.SO_RCVBUF, 1 << 20)
 .childOption(ChannelOption.TCP_NODELAY, true);
```

`Runtime.availableProcessors()` 在容器里读的是 **cgroup CPU quota 换算值**（JDK 10+ 支持 `UseContainerSupport`），在 cpuset 场景下读的是 cpuset 大小。这两个语义在混合部署时可能不一致，**显式用参数覆盖**比依赖默认值稳。

---

## 六、一次真实的调优记录

**环境**：8C16G 云主机，万兆网卡单队列，Spring Cloud Gateway（WebFlux/Netty），QPS 6 万，小包为主（平均 380 字节）。

**现象**：P99 从 40ms 抖到 300ms，`si` 在 CPU0 上到 35%，`softnet_stat` 第 3 列（time_squeeze）持续增长，`ethtool -S` 的 `rx_missed_errors` 每小时涨几百。

**处置与效果**：

| 步骤 | 动作 | 效果 |
|---|---|---|
| 1 | `ethtool -L eth0 combined 8` 开多队列 | `si` 从单核 35% 摊到 8 核各 5%，P99 → 90ms |
| 2 | 中断绑 CPU0-1，应用 `taskset -c 2-7` | P99 → 55ms，抖动频率下降一个量级 |
| 3 | `netdev_max_backlog=16384`、`netdev_budget_usecs=4000` | `time_squeeze` 归零 |
| 4 | `ethtool -G eth0 rx 4096` | `rx_missed_errors` 停止增长 |
| 5 | `ethtool -C eth0 rx-usecs 32`（中断合并） | P99 → 18ms，但**平均延迟略升** |

最后一步值得单独说：**中断合并是拿延迟换 CPU**。`rx-usecs` 调大后，一次中断处理更多包，中断次数下降、`si` 下降，但**每个包的等待时间上升**。低延迟场景（交易、实时推送）要往小调；高吞吐场景（日志采集、大数据管道）可以往大调。这个参数没有"最佳值"，只有"匹配你的 SLA"。

---

## 七、Java 工程师需要建立的三条直觉

**直觉一：`si` 是"看不见的 CPU 消耗"。**
`top` 里 `us + sy + si + wa` 才是完整账本。只看 `us` 会得出"CPU 很闲"的错误结论，然后去怀疑 GC、怀疑锁、怀疑数据库——全都查不到。

**直觉二：网络问题的第一现场在 `/proc`，不在 JVM。**
`jstack` 里看到线程卡在 `epollWait` 不代表"没问题"，只代表"没数据可读"。数据可能在上游就被丢了（`rx_missed_errors`）、在内核 backlog 里被丢了（`softnet_stat` 第 2 列）、在 listen 队列里被拒（`Recv-Q` 满）。

**直觉三：绑核是双刃剑。**
绑核能消除抖动，但也会放大"单核打满"的风险。绑核之后必须重新评估线程数（GC 线程、Netty worker、业务线程池），否则原本被 8 核摊掉的峰值会集中到 2 核上。

---

## 八、面试高频追问

**Q1：硬中断和软中断的区别？**

硬中断由硬件触发、在中断上下文执行、必须极短；软中断由内核在 `raise_softirq` 后延迟执行，可被硬中断抢占，NET_RX 软中断负责协议栈收包。软中断有 budget（`netdev_budget`），超预算后转由 `ksoftirqd/N` 内核线程继续处理。

**Q2：RPS 和 RSS 有什么区别？**

RSS 是网卡硬件多队列，真正的并行收包，包在各队列的 ring buffer 里；RPS 是单队列下的软件分流，在 `netif_receive_skb` 之后把包投递到其他 CPU 的 backlog 队列，会多一次跨核传递。**能用 RSS 就不要用 RPS。**

**Q3：`softnet_stat` 第 3 列在涨说明什么？**

`time_squeeze`：软中断一轮处理用完了 `netdev_budget` 或 `netdev_budget_usecs` 预算，还有包没处理完，被迫让出 CPU。持续增长会导致接收队列积压、最终丢包，尾延迟抖动。调大 budget 或增加队列/分散中断。

**Q4：TCP 全连接队列满了，应用侧看到什么？**

`ss -lnt` 的 `Recv-Q` 逼近 `Send-Q`，`netstat -s` 里 `listen queue overflowed` 增长。客户端表现为连接超时或 `Connection reset`。根因是 accept 速率不足：Java 侧 boss 线程太少、`accept` 后有同步阻塞操作、或者 `SO_BACKLOG` 设置过小。

**Q5：为什么 GSO/GRO 会影响延迟？**

GRO 在接收侧把同一条流的多个小包合并成一个大包再交给协议栈，减少每包开销；但合并需要等待（微秒级），低延迟场景关掉 GRO（`ethtool -K eth0 gro off`）可以降低抖动、提高 CPU 消耗。生产上通常保持开启，除非有极端低延迟需求。

---

## 九、踩坑清单

1. **`ethtool -L` 改了队列数但中断没重新分布**——驱动可能复位失败，必须回查 `/proc/interrupts`。
2. **容器里 RPS 掩码写成宿主机 CPU0-3**——cpuset 场景下无效，掩码要按宿主机编号写。
3. **`irqbalance` 和手工绑核打架**——两者同时存在时，手工配置会被周期性覆盖。
4. **只调 backlog 不调 ring buffer**——`netdev_max_backlog` 是内核 backlog，`ethtool -G rx` 是网卡 ring，两者是不同环节的队列，丢包要看是哪一个在涨。
5. **`netdev_budget` 调太大**——软中断会长时间占用 CPU，反而让应用线程饿死；配合 `netdev_budget_usecs` 一起调，保证单轮有时限。
6. **绑核后 GC 线程数没跟着降**——JVM 默认按 `availableProcessors` 起 GC 线程，绑到 2 核还开 8 个 GC 线程会加剧争抢。
7. **把 `st`（steal）当成 `si`**——`st` 是虚拟化层的 CPU 被宿主机抢走，调内核参数没用，要找云厂商或换规格。
8. **忽略网卡中断合并对 P99 的正向作用**——很多团队只调 `si` 占比，不看实际尾延迟，`rx-usecs` 往往是最便宜的一档优化。

---

## 十、总结

回到开头那个案例：那个"CPU 只有 25%、GC 干净、P99 抖动"的服务，最终定位于**单队列网卡 + 软中断全压在 CPU0**，通过开多队列、隔离中断核、调 backlog 与 ring buffer 解决。整个过程没改一行 Java 代码。

这就是这一层知识的意义：**当 JVM 里所有指标都正常，说明瓶颈已经不在 JVM 里了。** 从 `si`、`softnet_stat`、`ethtool -S` 这三个入口往下看，你会发现很多"玄学抖动"其实都有非常确定的解释——只是它们不在你平时看的那些图表上。
