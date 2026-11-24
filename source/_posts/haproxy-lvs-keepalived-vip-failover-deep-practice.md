---
title: 【负载均衡】LVS、HAProxy 与 keepalived 深度实战：VIP 漂移、四层转发与脑裂防护
date: 2026-11-24 08:00:00
tags:
  - Java
  - 负载均衡
  - LVS
  - HAProxy
  - keepalived
  - 高可用
categories:
  - 中间件
author: 东哥
---

# 【负载均衡】LVS、HAProxy 与 keepalived 深度实战

## 前言：所有故障的第一现场，都在流量入口

Java 后端写久了容易有一个错觉：服务是我写的，问题就该在我的代码里。但真实的生产事故里，**「服务没挂、监控全绿、用户全白屏」**的场景，十有八九发生在流量入口——VIP 漂了但 ARP 没更新、LB 健康检查比业务超时还慢、发布时把还在处理请求的节点直接摘掉、心跳网断了两个 keepalived 都抢着当 master。

这一篇把三层入口拆开讲透：

```
DNS / 客户端
    │
    ▼
LVS（四层，内核态，DR/NAT/TUN）+ keepalived（VRRP 选主、VIP 漂移）
    │
    ▼
HAProxy / Nginx（四层或七层，用户态，健康检查、连接管理）
    │
    ▼
Java 服务（Tomcat/Netty，优雅停机、readiness）
```

很多人把 LVS 和 HAProxy 当成「都能做负载均衡，随便选一个」，其实它们解决的是完全不同的问题：**LVS 解决「如何用一台机器扛住百万并发连接并把包转出去」，keepalived 解决「这台机器挂了谁来接 VIP」，HAProxy 解决「怎么判断后端还活着、怎么把连接优雅地挪走」。** 三者是叠加关系，不是替代关系。

---

## 一、LVS 三种模式：DR 为什么是默认答案

LVS（IPVS）是内核模块，工作在网络层（四层）。它有三种转发模式，差别只在**如何把请求送到 real server，以及回包走哪条路**。

| 模式 | 请求路径 | 回包路径 | 是否改包 | Director 带宽压力 | 后端要求 |
|---|---|---|---|---|---|
| NAT | 改目的 IP/端口，转发给 RS | **必须回到 Director** 再做 SNAT | 改目的地址 | 双向都过，容易成瓶颈 | 网关指向 Director |
| DR（Direct Routing） | 改目的 **MAC**，IP 不变 | RS **直接回给客户端** | 只改二层 | 只承受入向流量 | 需在 lo 上配 VIP + 抑制 ARP |
| TUN | IP-in-IP 隧道封装 | RS 直接回客户端 | 加隧道头 | 只承受入向 | 需支持 IPIP，可跨机房 |

DR 模式是绝大多数自建机房的默认选择，原因很简单：**回包（通常远大于请求）不经过 Director**，一台 Director 可以带几十台 RS。代价是它把复杂度推给了网络配置：

```bash
# 每台 real server 上（DR 模式）
ip addr add 10.0.0.100/32 dev lo      # VIP 挂在 lo 上
sysctl -w net.ipv4.conf.all.arp_ignore=1
sysctl -w net.ipv4.conf.all.arp_announce=2
sysctl -w net.ipv4.conf.lo.arp_ignore=1
sysctl -w net.ipv4.conf.lo.arp_announce=2
```

这两行 sysctl 是面试高频追问点：

- `arp_ignore=1`：只回答「目标 IP 配在收到 ARP 请求的那块网卡上」的请求。VIP 在 `lo` 上，从 `eth0` 收到的「谁是 10.0.0.100」就不回答，避免 RS 抢走 VIP 的 ARP。
- `arp_announce=2`：发送 ARP 时一律使用最合适的本地地址，忽略 IP 包源地址，防止 RS 用自己的物理 IP 去宣告 VIP。

**配置漏了会怎样？** 上游交换机的 ARP 表里 VIP 可能指向某台 RS 的 MAC，流量直接绕过 Director 打到单台后端，其余机器空转；或者多台 RS 轮流应答，形成 ARP 抖动，表现为「一会儿正常一会儿 502」。这类问题抓包看 `who-has 10.0.0.100 tell ...` 的应答者就能定位。

### LVS 调度算法速查

| 算法 | 适用 | 坑 |
|---|---|---|
| rr / wrr | 短连接、同质后端 | 长连接会严重倾斜 |
| lc / wlc | 长连接、异构后端 | 连接数不等于负载 |
| sh（源地址哈希） | 需要会话保持 | NAT 出口后大量用户同一 IP |
| mh | 一致性哈希 | 后端变更时重分布不均 |

生产上更常见的组合是：**LVS 用 wlc 做粗分流，HAProxy/Nginx 做细粒度健康检查与按权重的灰度**。

---

## 二、keepalived：VIP 漂移的机制与它最脆弱的地方

keepalived 用 VRRP 协议选主。核心字段只有几个：

- `state MASTER/BACKUP`：**初始**状态，不是最终状态，别把它当配置意图。
- `priority`：0–255，越大越优先；255 一般保留给 VIP 的真实持有者。
- `advert_int`：通告间隔，默认 1s；backup 在 `3 × advert_int + skew` 收不到通告就接管。
- `preempt` / `nopreempt`：是否抢占。默认抢占，`nopreempt` 只对「曾经是 master 的 backup」生效，细节很容易配错。
- `unicast_peer`：云环境普遍禁组播，必须改单播，否则两个节点互相听不到，**同时认为对方挂了**。

一个能用的配置骨架：

```conf
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight -30
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    nopreempt
    unicast_src_ip 10.0.0.11
    unicast_peer { 10.0.0.12 }
    authentication { auth_type PASS; auth_pass *** }
    virtual_ipaddress { 10.0.0.100/24 dev eth0 }
    track_script { chk_haproxy }
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault  "/etc/keepalived/notify.sh fault"
}
```

### 脑裂：不是「两个 master」这么简单

VRRP 的失效假设是「收不到通告 = 对方死了」。可现实是**网络分区**：心跳网线拔了、交换机 ACL 挡了 VRRP、云安全组没放行 112 协议号，两边业务网都通，于是两边都成为 master，**同时把 VIP 配到自己网卡上**。

后果比「两台都当主」更糟：上游交换机的 ARP 表会在两个 MAC 之间反复改写，流量一半打到 A 一半打到 B；如果后端是无状态服务还能撑，一旦是有会话状态或写主库的场景，就是数据错乱。

防护要分四层，缺一层都不算稳：

1. **链路冗余**：两条心跳走不同交换机/不同网段，`unicast_peer` 配多个对端。
2. **双向检测**：`track_script` 不能只检查本机 haproxy 进程，还要 `curl` 对端管理口；「我能看到对端」才算健康。
3. **仲裁/围栏**：三节点 quorum，或至少让「抢到 VIP」这个动作需要外部许可（云上直接用 SLB/弹性 IP，别自建 VIP）。
4. **可观测**：两个节点都上报 `ip addr` 里的 VIP 持有状态，出现「双持有」立即告警；`notify_*` 脚本里打日志 + 上报事件。

> 一个真实的判断技巧：在 A 上 `arping -c 3 -I eth0 10.0.0.100`，如果 B 也应答，说明 VIP 双持有；再看 `tcpdump -i eth0 -nn proto 112`，如果只有自己发的 VRRP 没有对方的，基本就是单播/组播被挡。

### VIP 漂移成功，业务却黑了 30 秒

这是最经典的「监控说切成功了，用户说挂了」。链路是：

1. keepalived 检测到 master 失联，backup 提升并**发送免费 ARP（Gratuitous ARP）**刷新上游交换机和客户端的 ARP 缓存。
2. 如果上游交换机开了 ARP 抑制、端口安全，或云网络不转发 GARP，**客户端的 ARP 缓存仍然指向旧 master 的 MAC**（Linux 默认 `gc_stale_time=60s`，中间网络设备可能更久）。
3. 这段时间客户端把包发到已经死掉的机器，表现为**连接超时而不是拒绝**（因为没有 RST）。

排查动作固定三步：

```bash
# 1. 新 master 上确认 VIP 真的在
ip -4 addr show dev eth0 | grep 10.0.0.100

# 2. 主动补发免费 ARP（notify_master 里就该做）
arping -c 3 -U -I eth0 10.0.0.100

# 3. 在客户端侧看 ARP 缓存指向谁
ip neigh show 10.0.0.100
```

根治办法：**别自建 VIP**。云上用 SLB/NLB + 弹性 IP，把漂移交给云网络；必须自建时，在 `notify_master` 里循环发 GARP，并把「切换后 60s 内错误率」纳入演练验收。

---

## 三、HAProxy：连接治理与「优雅摘流」

LVS 只做转发，不做应用层健康判断。HAProxy 补的就是这块：`mode tcp` 做四层，`mode http` 做七层，核心价值是**健康检查 + 连接队列 + 动态权重/上下线**。

```conf
global
    maxconn 100000
    nbthread 8
    stats socket /var/run/haproxy.sock mode 660 level admin

defaults
    mode tcp
    timeout connect 3s
    timeout client  60s
    timeout server  60s
    retries 3
    option redispatch

backend java_app
    balance leastconn
    option tcp-check
    tcp-check connect
    tcp-check send-binary 50494e47   # "PING"
    tcp-check expect binary 504f4e47 # "PONG"
    default-server inter 2s fall 3 rise 2 weight 100
    server app1 10.0.1.11:8080 check
    server app2 10.0.1.12:8080 check
```

几个必须算清楚的数：

- **故障发现时间 ≈ `inter × fall`**。上面是 6s；想更快就 `inter 1s fall 2`，代价是健康检查流量与误判率上升。
- **`timeout server` 必须大于业务 P99，但小于上游调用方超时**。否则 HAProxy 先断开，Java 侧还在写响应，日志里全是 `Broken pipe`。
- **`maxconn` 是全局连接上限，不是 QPS**。超过后新连接进队列，队列满则拒绝；配合 `nbthread` 才能吃满多核。
- **`option redispatch` + `retries` 只在幂等请求上安全**。POST 创建订单被重试两次，就是三张订单。

### 发布期：先把连接「排空」，再停进程

发布事故里最冤的一类，是代码没问题、流量也没问题，纯粹是**摘流顺序错了**。正确顺序：

```
1. readiness 置 false（K8s）或 LB 权重置 0 / 状态 drain（自建）
2. 等待 ≥ 健康检查发现时间 + 在途请求 P99（一般 10~30s）
3. 发 SIGTERM，Spring Boot 优雅停机停止接收新连接
4. 等待在途请求完成（含异步、SSE、WebSocket 的主动取消）
5. 进程退出
```

自建 HAProxy 用 stats socket 做排空：

```bash
# 把节点标记为 drain：不再分配新连接，已有连接继续
echo "set server java_app/app1 state drain" | socat stdio /var/run/haproxy.sock

# 观察剩余连接数，归零后再发 SIGTERM
echo "show stat" | socat stdio /var/run/haproxy.sock | grep java_app
```

Java 侧对应配置：

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

```java
@Component
public class DrainGuard {
    private final AtomicBoolean draining = new AtomicBoolean(false);

    @EventListener(ContextClosedEvent.class)
    public void onShutdown() {
        draining.set(true);   // readiness 端点立即返回 503
    }

    public boolean isDraining() {
        return draining.get();
    }
}
```

注意 `ContextClosedEvent` 触发时 Tomcat 已经开始停止接收请求，**readiness 必须更早变**——所以生产上通常是「外部编排先摘流」，代码只做兜底。

长连接是优雅停机的天敌：SSE/WebSocket 会一直占着连接，`graceful` 等满 30s 也会强杀。正确做法是在停机钩子里**主动发结束事件并关闭会话**，让客户端走重连逻辑，而不是等超时。

---

## 四、三层入口的容量算式

面试常问「一台 LB 能扛多少」，答案取决于层：

| 层 | 瓶颈 | 估算 |
|---|---|---|
| LVS-DR | 网卡 PPS / 带宽 | 10Gbps 网卡约 100~200 万并发连接（内核连接表内存） |
| LVS-NAT | conntrack 表 + 回包带宽 | 回包翻倍，通常先撞带宽 |
| HAProxy（四层） | 单进程事件循环 + 内存 | 单核约 3~8 万新建连接/s，连接内存约 2~4KB/条 |
| Nginx（七层） | 正则/缓冲区/上游连接 | 单机 5~10 万 QPS 视响应体大小 |

两个容易忽略的点：

1. **文件描述符**：`ulimit -n` 必须 ≥ `maxconn × 2 + 监听数`，systemd 下要改 `LimitNOFILE`，否则半夜 `EMFILE`。
2. **TIME_WAIT**：LB 作为客户端连后端时会产生大量 TIME_WAIT，`net.ipv4.tcp_tw_reuse=1` 只对**客户端主动连接**有效，且要求时间戳开启。

---

## 五、面试追问与检查清单

**Q1：LVS-DR 模式下，后端机器为什么要把 VIP 配在 lo 上，配在 eth0 上行不行？**
不行。配在 eth0 会让这台机器对外宣告「我拥有 VIP」，破坏 Director 的唯一入口；配在 lo + `arp_ignore/arp_announce` 才能既接收目的地址为 VIP 的包，又不抢 ARP。

**Q2：keepalived 的 `weight` 和 `priority` 是什么关系？**
脚本失败时按 `weight` 调整优先级（可为负），再参与 VRRP 比较。注意如果两台都掉到低于对方，会来回切换；把 `weight` 设计成「掉下去就必输」的绝对值更稳。

**Q3：为什么健康检查过了，用户还是 502？**
健康检查只证明「端口能连/能返回 200」，不证明「依赖可用」。典型是 Java 服务连不上数据库但 `/health` 只检查了进程存活。readiness 必须包含关键依赖或至少包含「能拿到连接池连接」。

**Q4：HAProxy 的 `timeout client` 设 60s，为什么长轮询还是断？**
`timeout client` 是**连接空闲超时**，长轮询期间没有数据往来就会被断开。要么调大，要么让服务端定期发心跳/注释行。

**Q5：四层 LB 能不能做灰度？**
能，但只能按连接粒度（源 IP 哈希/权重）。按用户/请求头灰度必须在七层做，或者在 Java 侧用流量染色。

### 上线前检查清单

- [ ] DR 模式：所有 RS 的 `arp_ignore=1`、`arp_announce=2`、VIP 在 lo
- [ ] keepalived：`unicast_peer` 已配、双心跳链路、`notify_*` 有日志与告警
- [ ] 切换演练：手动停 master，记录 VIP 漂移耗时 + 业务错误率恢复时间
- [ ] HAProxy：`inter × fall` 与业务超时匹配、`maxconn` 与 fd 匹配
- [ ] 发布流程：先 drain 再 SIGTERM，长连接有主动关闭逻辑
- [ ] 监控：VIP 持有状态、LB 后端 up/down 数、5xx 与超时率、`Recv-Q`

入口这一层没有「写对一次就永久正确」的配置，只有「每次变更都演练过」的流程。把它当成代码一样做变更评审和回归，比事后排查便宜太多。
