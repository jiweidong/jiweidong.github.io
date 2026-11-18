---
title: 【云原生网络】容器网络包路径深度解析：veth、网桥、VXLAN 与 nftables 的每一跳
date: 2026-11-18 08:10:00
tags:
  - Kubernetes
  - 网络
  - CNI
  - nftables
  - Java
categories:
  - 云原生
author: 东哥
---

# 【云原生网络】容器网络包路径深度解析

## 前言

线上最让人抓狂的故障类型之一，是「服务端没日志、客户端超时」。在 Kubernetes 里，这类问题十有八九发生在**包路径**上：veth 丢包、conntrack 表满、MTU 黑洞、NetworkPolicy 静默 DROP、Service DNAT 后回程不对称。

这些问题有两个共同特点：

1. **应用层完全无感** —— Java 侧只看到 `SocketTimeoutException` 或者 gRPC `DEADLINE_EXCEEDED`；
2. **`kubectl logs` 什么都看不到** —— 因为包根本没到进程。

要定位它们，必须能在脑子里画出「一个包从 Pod A 的 socket 到 Pod B 的 socket 经过哪些设备、哪些表、哪些 hook」。这篇文章就把这条路径拆到每一跳，并给出可直接执行的排查命令。

---

## 一、先看清「一个 Pod 的网络长什么样」

创建 Pod 时，CRI 调用 CNI 插件，典型动作是：

```bash
# CNI 插件大致做的三件事
ip link add veth0 type veth peer name veth1
ip link set veth0 netns <pod-netns>
ip link set veth1 master cni0      # 或直接放进宿主路由 / eBPF
ip addr add 10.244.1.7/24 dev veth0     # 在 pod netns 内
ip route add default via 10.244.1.1 dev veth0
```

于是宿主机上能看到：

```
[root@node1 ~]# ip link show type veth
7: veth1a2b3c4d@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...
```

命名规则上，`vethXXXX` 是宿主机侧，`@ifN` 里的 N 是容器内的 interface index。**注意 MTU 1450 而不是 1500** —— 这是后面 MTU 黑洞的伏笔。

容器内视角：

```
[root@pod /]# ip addr
1: lo: <LOOPBACK,UP>
3: eth0@if7: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
    inet 10.244.1.7/24 brd 10.244.1.255 scope global eth0
[root@pod /]# ip route
default via 10.244.1.1 dev eth0
10.244.0.0/16 via 10.244.1.1 dev eth0
```

关键点：**Pod 里没有默认网卡概念，只有一个 eth0**。所有「多网卡」需求（数据面/管理面分离）都要靠 Multus 额外注入。

---

## 二、同节点 Pod → Pod：六跳

假设 Pod A（10.244.1.7）访问 Pod B（10.244.1.8），同节点：

```
[A eth0] → veth pair → [host vethA] → cni0 网桥 → [host vethB] → veth pair → [B eth0]
   1            2            3              4            5              6
```

逐跳说明：

1. **A 的 eth0 发出**：查路由表，目标 10.244.1.8 命中 `10.244.0.0/16 via 10.244.1.1`，需要走网关（网桥 IP），于是查 ARP 拿网关 MAC。
2. **veth pair 传递**：veth 是一对「虚拟网线」，从一端进入必然从另一端出来。此时包从容器 netns **切换到宿主 netns**。
3. **宿主 vethA 收到**：因为 `vethA` 是 `cni0` 的从设备，包被送入网桥。
4. **网桥转发**：`cni0` 查 FDB（ forwarding database），发现 10.244.1.8 的 MAC 在 `vethB` 上，转发过去。这一步会触发**ARP 广播**（首次通信时）。
5. **vethB → B 的 eth0**：包进入容器 netns。
6. **B 的协议栈处理**：如果 B 上没监听该端口，直接回 RST（`Connection refused`）；如果有监听但 accept 队列满，则**静默丢弃**（这是「超时而非拒绝」的经典来源）。

**排查命令**：

```bash
# 在宿主机看网桥的 FDB 与端口状态
bridge fdb show dev cni0 | grep -i 10.244
bridge link show

# 看 veth 是否 UP、是否有丢包
ip -s link show veth1a2b3c4d

# 在容器 netns 里抓包（不需要进容器，避免镜像里没 tcpdump）
nsenter -t $(pidof java) -n tcpdump -i eth0 -nnvv -c 20
```

---

## 三、跨节点 Pod → Pod：Overlay 的三层封装

跨节点时，包要经过隧道。以 Flannel VXLAN 为例：

```
[A eth0] → cni0 → flannel.1(VXLAN) → 宿主 eth0 → [物理网络] → 宿主 eth0 → flannel.1 → cni0 → [B eth0]
```

封装后的报文结构：

```
| Outer Eth | Outer IP | Outer UDP(8472) | VXLAN(8B) | Inner Eth | Inner IP | Payload |
     14          20           8                8            14          20        MSS
```

**MTU 算法**：

```
Pod MTU = 物理 MTU - Outer IP(20) - Outer UDP(8) - VXLAN(8)
        = 1500 - 20 - 8 - 8 = 1464
```

实际配置里常见 1450（留 14 字节余量给安全组/VLAN tag）。Calico IPIP 的算法是 `1500 - 20 = 1480`；Calico BGP（无封装）则是 1500。

### MTU 黑洞：最隐蔽的一类故障

现象：**小请求正常，大请求卡住**。典型是：

- `curl` 小接口 200ms 返回正常；
- 上传 10KB 以上 body 就超时；
- gRPC 一元调用正常，流式或大 payload 挂住；
- TLS 握手偶尔卡 30 秒（Certificate 消息超过 MTU）。

原因链条：

1. Pod MTU 配成 1500，但隧道实际只能过 1450；
2. 大包被置 `DF=1`（不可分片）；
3. 中间设备需要分片，但 `DF=1` 不能分，于是回 `ICMP Fragmentation Needed`；
4. **安全组/防火墙把 ICMP 丢了**；
5. 发送端永远等不到反馈，TCP 重传直到超时。

验证：

```bash
# 带 DF 标志 ping，逐步加大 size 找断点
ping -M do -s 1422 10.244.2.9      # 1422 + 8(ICMP) + 20(IP) = 1450
# 如果 1450 通、1451 不通 → MTU 就是 1450

# 看内核是否记录了需要分片的 ICMP
cat /proc/net/snmp | grep -A1 Icmp | grep -i frag
```

修复优先级：

| 手段 | 说明 | 副作用 |
|---|---|---|
| 修正 CNI MTU 配置 | 根治，Pod 重建后生效 | 需要滚动重启工作负载 |
| `net.ipv4.tcp_mtu_probing=1` | 内核自动探测，靠重传试探 | 首次连接慢，治标 |
| 应用侧减小 payload | 治标 | 需要改代码 |
| 放行 ICMP type 3 code 4 | 让 PMTUD 工作 | 安全策略需要审批 |

**Java 视角**：`HttpClient` 和 Netty 都没法主动设置 MSS，只能在 socket 上设 `TCP_MAXSEG`（且受路由 MTU 限制）。所以 MTU 问题必须在 CNI 层解决，应用层无解。

---

## 四、Service 访问：DNAT 与 conntrack

访问 `Service ClusterIP` 时，包路径上多了两条规则链（kube-proxy iptables 模式）：

```
PREROUTING → KUBE-SERVICES → KUBE-SVC-XXX(概率选择) → KUBE-SEP-YYY(DNAT) → 转发
POSTROUTING → KUBE-POSTROUTING(MASQUERADE，视情况)
```

关键点：**DNAT 只改目标地址，不改源地址**（除非需要 hairpin 或跨网段）。所以后端 Pod 看到的源 IP 是**客户端 Pod IP**（不是节点 IP），这也是为什么 NetworkPolicy 可以按 Pod 粒度做策略。

### conntrack：每条连接两个表项

DNAT 是有状态的，内核用 conntrack 记录「原始五元组 ↔ 转换后五元组」。一条 TCP 连接会产生**两个方向的表项**：

```
tcp 6 431998 ESTABLISHED src=10.244.1.7 dst=10.96.0.10 sport=43210 dport=80
    src=10.244.2.9 dst=10.244.1.7 sport=8080 dport=43210 [ASSURED]
```

压测时如果 QPS 高、连接短，conntrack 表会迅速膨胀。表满的表现是：

```
nf_conntrack: table full, dropping packet
```

**丢包发生在 `PREROUTING` 之前**，所以：
- 服务端完全没有连接记录；
- 客户端表现为 `connect timeout`（不是 refused）；
- `ss -s` 里 `TCP: inuse` 正常，但 `conntrack` 计数打满。

```bash
# 观察
conntrack -C                          # 当前表项数
cat /proc/sys/net/netfilter/nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count

# 按 Pod IP 统计表项（找出连接大户）
conntrack -L | grep 10.244.1.7 | wc -l
```

治理手段：

| 手段 | 效果 | 注意 |
|---|---|---|
| 提高 `nf_conntrack_max` | 直接扩容表 | 内存消耗约 300B/表项 |
| 缩短 `nf_conntrack_tcp_timeout_time_wait` | 加速回收 | 太小会导致 TIME_WAIT 复用问题 |
| 用长连接（HTTP keep-alive / gRPC） | 根本性减少表项 | 需要客户端配合 |
| 换 IPVS / eBPF 模式 | 减少 iptables 规则遍历 | IPVS 仍需 conntrack |

**长连接是性价比最高的手段**。一个 200 QPS 的短连接服务，如果每次请求新建 TCP，conntrack 表项 ≈ 200 × 60s(TIME_WAIT) = 12000 条；改成 keep-alive 后只剩几十条。

---

## 五、nftables 时代的变化

kube-proxy 从 1.29 起支持 `nftables` 模式，1.31 转为 GA。它解决的核心问题是：**iptables 线性遍历规则**，Service 数量上千后，每个包要过几千条规则，延迟随规模线性增长。

nftables 用 **set/map 做 O(1) 查找**：

```
table ip kube-proxy {
    map service-ips {
        type ipv4_addr . inet_proto . inet_service : verdict
        elements = { 10.96.0.10 . tcp . 80 : goto svc-abc,
                     10.96.0.11 . tcp . 443 : goto svc-def }
    }
    chain service-dispatch {
        ip daddr . meta l4proto . th dport vmap @service-ips
    }
}
```

差别：

| 维度 | iptables | nftables |
|---|---|---|
| 规则匹配 | 线性遍历 | set/map 哈希查找 |
| 大规模 Service | 延迟随数量增长 | 基本恒定 |
| 原子更新 | `iptables-restore` 全量替换 | 事务式增量更新 |
| 语法 | 每条命令一个规则 | 一次提交整个 ruleset |
| 观测 | `iptables -L -n -v` | `nft list ruleset` |

**但 nftables 不改变 conntrack 的存在**。DNAT 依然有状态，表满问题依然存在。很多人以为换了 nftables 就不用管 conntrack，这是误解。

排查命令也要换：

```bash
nft list ruleset | head -50
nft list map ip kube-proxy service-ips | wc -l
# 看某个 chain 的计数器
nft -a list chain ip kube-proxy service-dispatch
```

---

## 六、NetworkPolicy：静默 DROP 的重灾区

NetworkPolicy 由 CNI 实现（Calico / Cilium），默认行为是**DROP 而不是 REJECT**。这意味着：

- 客户端看到 `connect timeout`；
- 服务端没有 SYN 记录（`ss -lnt` 的 Recv-Q 不增长）；
- `tcpdump` 在 Pod 内**看不到入向 SYN**（在宿主侧就被丢了）。

定位方式（Calico）：

```bash
# 看策略命中计数
calicoctl get networkpolicy -A -o wide
# 用 felix 的 Prometheus 指标
curl -s localhost:9091/metrics | grep felix_iptables_rules
```

Cilium 更直接：

```bash
cilium monitor --type drop
cilium policy trace --src-k8s-pod default/client --dst-k8s-pod default/server --dport 8080
```

**Java 侧的判别技巧**：`connect timeout` + 服务端零日志 + 同节点直连 Pod IP 也超时 → 大概率是策略/路由问题，不是应用问题。此时不要去调 JVM 参数，先去查 CNI。

---

## 七、DNS：UDP 与 conntrack 的化学反应

集群 DNS（CoreDNS）默认走 UDP。UDP 的 conntrack 超时只有 30 秒（`nf_conntrack_udp_timeout`），而 glibc 的 DNS 缓存行为又会复用 socket。

经典故障：**偶发 5 秒 DNS 超时**。

原因链条：

1. Java 用 `InetAddress` 查询，底层 `getaddrinfo` 走 UDP；
2. CoreDNS 返回响应，但包在回程被丢（conntrack 表满 / 策略 / 节点负载）；
3. glibc 的默认超时是 5 秒，重试第二个 nameserver；
4. 业务侧看到「第一次调用慢 5 秒，之后正常」。

治理：

- 客户端加 DNS 缓存（`networkaddress.cache.ttl`，JVM 默认对 `InetAddress` 缓存 30s 正结果、10s 负结果，但很多框架自己又包了一层）；
- CoreDNS 前面用 NodeLocal DNSCache，把 UDP 查询收敛到节点本地，减少 conntrack 表项；
- 关键服务直接用 Headless Service + 客户端负载均衡，减少 DNS 依赖。

```java
// 让 JVM 缓存 DNS 结果，减少查询次数（注意：会掩盖服务发现变化）
java.security.Security.setProperty("networkaddress.cache.ttl", "30");
java.security.Security.setProperty("networkaddress.cache.negative.ttl", "5");
```

---

## 八、一张排查决策表

| 现象 | 最可能原因 | 首查命令 |
|---|---|---|
| connect timeout，服务端零日志 | 策略 DROP / conntrack 满 / 路由缺失 | `conntrack -C`、`nft list ruleset` |
| connect refused | 端口没监听 / 进程挂了 | `ss -lntp` in pod |
| 小包通、大包挂 | MTU 黑洞 | `ping -M do -s 1422` |
| 偶发 5s 延迟 | DNS UDP 丢包 | `tcpdump -i any port 53` |
| 跨节点不通、同节点通 | VXLAN/路由/安全组 | `ip route`、`bridge fdb` |
| 高并发下大量超时 | conntrack 表满 | `dmesg \| grep conntrack` |
| 只有新 Pod 不通 | CNI 未就绪 / IP 池耗尽 | `kubectl describe pod`、CNI 日志 |

---

## 九、面试追问

**Q1：veth 一端 down 了，另一端会怎样？**

veth 是成对的，一端 `DOWN` 时对端仍存在但**无法收发**（`NO-CARRIER`）。容器内 `eth0` 会显示 `state DOWN`，路由表仍存在但包发不出去。这也是为什么「容器内 `ip addr` 看着正常但 ping 不通」时要先查宿主侧 veth 状态。

**Q2：为什么 Service 的 ClusterIP ping 不通？**

ClusterIP 是**虚拟 IP**，只存在于 iptables/nftables 规则里，没有任何设备持有它。ICMP 没有对应 DNAT 规则时会被丢。所以 ping 不通是正常的，用 `curl`/`nc` 测 TCP 才有意义。

**Q3：kube-proxy IPVS 模式为什么还需要 iptables？**

IPVS 只处理 Service 的负载均衡，但 **MASQUERADE、NodePort 的 SNAT、hairpin** 这些仍需 iptables 规则配合。所以 IPVS 模式下 `iptables-save` 依然能看到 `KUBE-POSTROUTING` 等链。

**Q4：conntrack 表满为什么表现为超时而不是拒绝？**

因为丢包发生在 `nf_conntrack_in` 阶段（`PREROUTING` 的 conntrack hook），此时包还没进入 TCP 协议栈，内核不会生成 RST。客户端只能靠重传超时感知，所以是 `timeout`。

**Q5：如何在不重启 Pod 的情况下验证 MTU 假设？**

在 Pod 内执行 `ping -M do -s <size> <target>`，二分找断点；同时用 `tcpdump -i eth0 -nnvv 'tcp and tcp[tcpflags] & tcp-syn != 0'` 看 SYN 是否发出、是否有回包。如果 SYN 发出但无 SYN-ACK，且宿主侧也看不到，基本确定是路径 MTU 或策略问题。

---

## 十、小结

- 容器网络的每一跳都有明确的设备与 hook，**能画出来就能排查**。
- MTU 是最容易被忽略的参数：`Pod MTU = 物理 MTU - 封装开销`，配错就是「小包通大包挂」。
- conntrack 是有状态 NAT 的必然代价，短连接 + 高 QPS = 表项爆炸，**长连接是第一治理手段**。
- nftables 解决的是规则匹配复杂度，**不解决 conntrack**。
- NetworkPolicy 默认 DROP，超时优先怀疑它；`Connection refused` 才是应用层问题。
- DNS 走 UDP，超时 5 秒的偶发问题先查 53 端口丢包。

最后一句经验：**Java 应用报超时，先确认包有没有到进程**。`ss -lnt` 的 `Recv-Q` 和 `tcpdump` 能在一分钟内把这问题定性，比翻 GC 日志快得多。
