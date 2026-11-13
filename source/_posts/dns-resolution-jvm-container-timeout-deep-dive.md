---
title: 【Java 网络】DNS 解析与 JVM 深度解析：InetAddress 缓存、ndots 陷阱与容器内 5 秒超时归因
date: 2026-11-13 08:10:00
tags:
  - Java
  - 网络
  - DNS
  - Kubernetes
  - 排查
categories:
  - Java 网络
author: 东哥
---

# 【Java 网络】DNS 解析与 JVM 深度解析：InetAddress 缓存、ndots 陷阱与容器内 5 秒超时归因

## 前言

有一类故障特别折磨人：服务本身逻辑没问题，压测也过，但线上偶发 `UnknownHostException`，或者每隔一段时间有几个请求「凭空」多了 5 秒、10 秒；`curl` 手动访问秒回，Java 客户端却慢；K8s 里 Service 滚动更新后，部分实例一直连老 IP，重启才好。

这些现象背后几乎都是同一件事：**DNS 解析**。而 DNS 在 Java 里是一条特别长的链路——JVM 有自己的缓存、glibc/musl 有自己的搜索域逻辑、`/etc/resolv.conf` 有 `ndots` 和超时重试、下层的 DNS 服务器还有 UDP 截断转 TCP 的行为。任何一层出问题，表现都是「网络慢」，但根因完全不同。

这篇文章把这条链路完整拆开，包括 JVM 缓存的两个 ttl、`ndots:5` 为什么会放大成 5 倍查询、Alpine 镜像（musl）与 glibc 的行为差异、Netty/gRPC 自己的 NameResolver，以及一套可以直接照着做的排查手册。

## 一、一次 `new InetAddress` 到底走了多少层

```java
InetAddress.getByName("order-svc.payment.svc.cluster.local");
```

展开后：

```
Java 应用
  └─ InetAddress.getByName()
       ├─ 1. JVM 层缓存（InetAddress.cache）
       │     ├─ 正向缓存 networkaddress.cache.ttl         默认 30s
       │     └─ 负向缓存 networkaddress.cache.negative.ttl 默认 10s
       ├─ 2. NameService SPI（默认 dns,sun）
       │     └─ Inet4AddressImpl.lookupAllHostAddr() → getaddrinfo()
       ├─ 3. glibc getaddrinfo（Alpine 是 musl）
       │     ├─ /etc/nsswitch.conf：hosts: files dns
       │     ├─ /etc/hosts
       │     └─ /etc/resolv.conf：nameserver / search / ndots / timeout / attempts
       └─ 4. DNS 查询（UDP 53，截断时转 TCP 53）
```

关键认知：**JVM 缓存是「进程级、按主机名」的，跟 DNS 的 TTL 完全无关**。DNS 记录 TTL 是 5 秒也好、30 秒也好，JVM 只认自己那两个属性。这就是「Service IP 变了但 Java 进程还在连老 IP」的根本原因。

## 二、JVM 缓存：两个 ttl 的精确语义

### 2.1 属性与默认值

```bash
# 正向缓存：解析成功后缓存多久（秒）
-Dsun.net.inetaddr.ttl=30
# 等价的安全属性写法（JDK 9+ 仍生效）
-Djava.security.properties=...
# networkaddress.cache.ttl=30

# 负向缓存：解析失败（NXDOMAIN）缓存多久（秒）
-Dsun.net.inetaddr.negative.ttl=10
```

| 配置 | 默认值 | 含义 | 生产建议 |
|---|---|---|---|
| `networkaddress.cache.ttl` | 30（有 SecurityManager 时 -1） | 成功解析结果缓存时长 | 容器内可降到 5~10，或配合服务发现 |
| `networkaddress.cache.negative.ttl` | 10 | 失败结果缓存时长 | 保留 0~10，避免故障恢复后仍打不通 |
| `-1` | — | 永久缓存 | **绝对不要用**，滚动发布会踩死 |

注意一个历史包袱：JDK 早期在启用 SecurityManager 时，`networkaddress.cache.ttl` 默认是 `-1`（永久）。JDK 17 之后 SecurityManager 已废弃，但**属性语义没变**，很多老项目的启动脚本里还留着 `-1`，这就是「DNS 改了不生效」的元凶。

### 2.2 怎么验证缓存真的在生效

```java
public class DnsCacheProbe {
    public static void main(String[] args) throws Exception {
        for (int i = 0; i < 6; i++) {
            long t0 = System.nanoTime();
            InetAddress[] addrs = InetAddress.getAllByName("order-svc.payment.svc.cluster.local");
            long cost = (System.nanoTime() - t0) / 1_000_000;
            System.out.printf("round=%d cost=%dms -> %s%n", i, cost,
                    Arrays.stream(addrs).map(InetAddress::getHostAddress).toList());
            Thread.sleep(5_000);
        }
    }
}
```

判读方式：

- 第 1 次几十毫秒，后续 0~1ms → 缓存生效（30s 内）。
- 每次都是几十毫秒 → 缓存被关掉了（ttl=0 或 -1 的反面）。
- 每 30 秒出现一次慢 → 正常过期重解析。

想绕过 JVM 缓存做「真实解析」，只能用外部命令或自建 resolver：

```bash
getent hosts order-svc.payment.svc.cluster.local   # 走 glibc，但 glibc 也有 nscd 缓存
dig +short order-svc.payment.svc.cluster.local @10.96.0.10
```

## 三、ndots:5——容器里最贵的五个字符

K8s 默认给 Pod 生成的 `/etc/resolv.conf`：

```
nameserver 10.96.0.10
search payment.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` 的语义是：**如果域名里的「点」少于 5 个，就先当成相对域名，依次拼接 search 列表去查，全都失败后才查原名。**

于是 `order-svc.payment.svc.cluster.local`（4 个点 < 5）的解析过程是：

```
1. order-svc.payment.svc.cluster.local.payment.svc.cluster.local   ✗
2. order-svc.payment.svc.cluster.local.svc.cluster.local           ✗
3. order-svc.payment.svc.cluster.local.cluster.local               ✗
4. order-svc.payment.svc.cluster.local                             ✓  ← 第 4 次才命中
```

**一个 FQDN 变成了 4 次查询。** 如果 DNS 服务器慢或者丢包，`timeout:2 attempts:3` 的默认配置下，最坏情况是：

```
4 次查询 × 2s × 3 attempts = 24 秒
```

这就是「偶发 5 秒/10 秒超时」的经典来源——注意 5 秒正好是 `2s × 3 attempts` 减去一点，或者两次 attempt 的耗时。

三种解法：

| 解法 | 做法 | 代价 |
|---|---|---|
| 用绝对域名 | 结尾加点：`order-svc.payment.svc.cluster.local.` | 代码里到处是尾点，容易漏 |
| 调小 ndots | Pod 的 `dnsConfig.options: [{name: ndots, value: "2"}]` | 外部域名（如 `api.openai.com`）会多查几次 |
| 应用层预热 | 启动时解析一次并缓存 IP 列表 | 需要自己处理刷新 |

`ndots` 的取舍很现实：**内部短名多就调小，外部域名多就保持 5**。混合场景最优解是「内部用 FQDN 尾点，外部保持默认」。

## 四、musl 与 glibc：Alpine 镜像的隐藏差异

Java 镜像从 `openjdk:17-slim`（Debian/glibc）换成 `eclipse-temurin:17-alpine`（musl）后，DNS 行为会变：

| 维度 | glibc | musl |
|---|---|---|
| `ndots` 支持 | 完整 | 支持，但对 search 数量上限更严 |
| `attempts` | 支持 | 部分版本忽略，只发一次 |
| 负向缓存 | 有（JVM 之上还有 nscd 可选） | 无进程级负缓存 |
| `getaddrinfo` 并发 | 内部串行 | 串行 |
| UDP 截断转 TCP | 支持 | 支持，但超时更短 |

实际影响：**Alpine 镜像在 DNS 抖动时更容易直接抛 `UnknownHostException`，而不是重试成功**。如果你的服务对 DNS 稳定性敏感，优先用 `-slim`/`-jammy` 这类 glibc 基础镜像；非要用 Alpine，就把 `dnsConfig` 的 `timeout` 调大、`attempts` 明确写出来。

## 五、Netty 与 gRPC：它们有自己的 resolver

### 5.1 Netty

Netty 默认用 JDK 的 `InetAddress`（`DefaultNameResolver`），但可以切换到自带的 `DnsNameResolver`：

```java
EventLoopGroup group = new NioEventLoopGroup(1);
DnsNameResolver resolver = new DnsNameResolverBuilder(group.next())
        .channelType(NioDatagramChannel.class)
        .nameServerProvider(new SingletonDnsServerAddressStreamProvider(
                InetSocketAddress.createUnresolved("10.96.0.10", 53)))
        .queryTimeoutMillis(2000)
        .negativeTtl(10)
        .cache(new DefaultDnsCache(30, 10, 60))   // minTtl, maxTtl, negativeTtl
        .optResourceEnabled(false)
        .build();

resolver.resolve("order-svc.payment.svc.cluster.local")
        .addListener((Future<InetAddress> f) -> {
            if (f.isSuccess()) System.out.println(f.getNow());
            else f.cause().printStackTrace();
        });
```

要点：

- `DefaultDnsCache(30, 10, 60)` 的三个参数顺序是 `(minTtl, negativeTtl, maxTtl)`，**很多人写反了**，导致缓存要么过长要么为 0。
- Netty 的 resolver 默认不做 search domain 拼接，**所以用 Netty resolver 时必须传 FQDN**，否则解析不到短名。
- 它有自己的 TTL 感知，比 JVM 缓存更贴近 DNS 真实语义，适合做服务发现。

### 5.2 gRPC

gRPC 的 `DnsNameResolverProvider` 底层走 `InetAddress.getAllByName`，**因此完全受 JVM 缓存影响**。它额外提供了两个参数：

```
grpc.dns.min_time_between_resolutions=30s   # 两次重解析最小间隔
grpc.service_config_disable_resolution=0
```

滚动发布期间 gRPC 长连接不断、又缓存了老 IP，就是「新 Pod 起来了但流量进不来」的常见原因。解法组合：

1. 用 headless service + `dns:///` scheme，让 gRPC 拿到所有 Pod IP 而不是 ClusterIP。
2. 把 `grpc.dns.min_time_between_resolutions` 调到 10~30s。
3. 服务端配 `MAX_CONNECTION_AGE`，强制客户端周期性重建连接。

## 六、一个可落地的 Java DNS 缓存层

如果不想依赖 JVM 那两个全局属性（改一个就影响全进程），可以自己包一层可控的缓存：

```java
public class ManagedDnsResolver {

    private final LoadingCache<String, List<InetAddress>> cache;

    public ManagedDnsResolver(Duration ttl, Duration negativeTtl) {
        this.cache = Caffeine.newBuilder()
                .expireAfterWrite(ttl)
                .maximumSize(4096)
                .recordStats()
                .build(key -> {
                    try {
                        return List.of(InetAddress.getAllByName(key));
                    } catch (UnknownHostException e) {
                        // 不缓存失败：让下一次请求立即重试
                        throw new UncheckedIOException(e);
                    }
                });
    }

    public List<InetAddress> resolve(String host) {
        try {
            return cache.get(host);
        } catch (Exception e) {
            throw new IllegalStateException("dns resolve failed: " + host, e);
        }
    }

    /** 轮询 + 失败转移，避免总打第一个 IP */
    public InetSocketAddress pick(String host, int port, AtomicInteger cursor) {
        List<InetAddress> list = resolve(host);
        int idx = Math.floorMod(cursor.getAndIncrement(), list.size());
        return new InetSocketAddress(list.get(idx), port);
    }
}
```

四个设计要点：

1. **失败不缓存**（或者只缓存极短时间），避免 DNS 恢复后仍打不通。
2. **永远 `getAllByName` 而不是 `getByName`**，K8s headless service 会返回多个 Pod IP，只取第一个等于放弃负载均衡。
3. **轮询索引要单调递增**，不要每次 `random`——`random` 在小样本下分布很不均。
4. **暴露缓存命中率**（Caffeine 的 `recordStats`），否则 DNS 抖动时你不知道是缓存问题还是网络问题。

## 七、排查手册：5 秒超时到底花在哪

按顺序执行，基本能定位到层：

```bash
# 1. 看容器的 DNS 配置（重点：ndots 与 search）
cat /etc/resolv.conf

# 2. 直接问 DNS 服务器（绕过所有本地缓存）
dig +short +time=2 +tries=2 order-svc.payment.svc.cluster.local @10.96.0.10
# 计时：time dig ...

# 3. 看搜索域放大（比较相对名和绝对名的耗时）
time getent hosts order-svc
time getent hosts order-svc.payment.svc.cluster.local.

# 4. 看 Java 进程实际发了哪些 DNS 请求
strace -f -e trace=network -p <pid> 2>&1 | grep -E "sendto|connect.*:53"

# 5. 判断是不是 JVM 缓存（对比 getent 与 Java 的结果）
jcmd <pid> VM.system_properties | grep -i inetaddr

# 6. 看是否 UDP 截断转 TCP（大响应、多记录时）
dig +ignore order-svc.payment.svc.cluster.local   # 忽略截断标志
```

常见归因表：

| 现象 | 根因 | 处置 |
|---|---|---|
| `curl` 快、Java 慢 | JVM 缓存 + ndots 放大 | 调 ttl、用 FQDN |
| 每 30s 一次慢 | 正向缓存过期重解析 | 预热 + 缩短依赖链 |
| 5s / 10s 整倍数超时 | `timeout × attempts` 打满 | 调 `dnsConfig` |
| 滚动发布后连旧 IP | JVM 永久缓存（ttl=-1） | 删掉 `-1` |
| 只有 Alpine 镜像出问题 | musl 不重试 | 换 glibc 基础镜像 |
| 多副本流量不均 | 只取了 `getByName` 第一个 IP | 改 `getAllByName` + 轮询 |
| 大响应偶发失败 | UDP 截断转 TCP 被防火墙拦 | 放行 TCP 53 |

## 八、面试常见追问

**Q1：DNS 有 TTL，为什么 Java 还要自己缓存？**

因为每次解析都要走系统调用、可能阻塞，高频调用下开销不可接受；而 JVM 层缓存是进程内内存查表，纳秒级。代价是**缓存与 DNS 真实状态可能不一致**，所以容器场景要调小 ttl 或改用服务发现。

**Q2：`networkaddress.cache.ttl=-1` 意味着什么？为什么生产禁用？**

永久缓存，进程生命周期内不再重解析。K8s 里 Service ClusterIP 一般不变，但 **headless service、StatefulSet、外部依赖切换**都会变 IP，永久缓存会导致流量打到已下线的实例，且只有重启才能恢复。

**Q3：`ndots:5` 为什么会导致 5 秒超时？**

域名点数小于 5 时按相对名处理，先拼 search 域逐个查询，全部失败才查原名。4 次查询 × `timeout(2s)` × `attempts(3)` ≈ 24s 最坏；实际观测到的 5s 通常是单次 attempt 内多次查询累加。

**Q4：负向缓存有什么用？会不会有害？**

好处是避免对确定不存在的域名反复查询（防 DNS 放大攻击、降低延迟）。害处是**故障恢复延迟**：域名刚恢复可用，客户端还在负缓存期，表现为「服务已经好了但客户端还在报错」。所以 negative ttl 一般不超过 10s。

**Q5：怎么在不改 JVM 全局参数的前提下，只让某个下游用短 TTL？**

自建 resolver（如上面的 `ManagedDnsResolver`），或用支持 TTL 的客户端（Netty `DnsNameResolver`、gRPC 的 `dns:///` resolver），把缓存粒度从「进程级全局」下沉到「按 host 可控」。

## 九、总结

- Java 的 DNS 是一条四层链路：JVM 缓存 → NameService SPI → libc `getaddrinfo` → DNS 服务器。
- **JVM 缓存与 DNS TTL 无关**，两个属性：正向 30s、负向 10s；`-1` 是生产事故源头。
- `ndots:5` 会把一个 FQDN 放大成 4~5 次查询，是容器内「偶发 5 秒」的头号嫌疑。
- Alpine（musl）在重试与负缓存上与 glibc 有实质差异，敏感服务优先 glibc 基础镜像。
- Netty/gRPC 有自己的 resolver，但 gRPC 默认仍走 `InetAddress`，受 JVM 缓存影响。
- 排查顺序固定：`resolv.conf` → `dig` 直连 → `getent` 对比 → `strace` 看实际请求 → `jcmd` 看 JVM 属性。

DNS 这类基础设施的特点是：**正常时你感觉不到它，出问题时它伪装成任何东西**——数据库慢、下游超时、GC 抖动。能把这条链路讲清楚，基本就具备了「从现象追到内核」的排查能力。
