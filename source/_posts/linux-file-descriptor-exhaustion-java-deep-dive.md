---
title: 【性能调优】文件描述符耗尽深度治理：Too many open files 的 Java 根因定位、fd 泄漏排查与容量估算
date: 2026-11-10 08:10:00
tags:
  - Linux
  - 性能调优
  - Java
  - 故障排查
  - 网络编程
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】文件描述符耗尽深度治理

## 前言

`java.io.IOException: Too many open files` 这个异常，几乎每个 Java 工程师都在某次深夜告警里见过。它的迷惑性在于：**代码看起来没问题，连接池也配了上限，但 fd 就是一直涨**。

更麻烦的是，它的表现形式千奇百怪：

- 接口偶发 500，重启就好，过几天再犯
- `accept` 失败但 `connect` 正常（新连接进不来，老连接还在用）
- 日志突然不写了（logback 打不开新文件）
- 明明 `lsof` 只有 3000 个 fd，`ulimit -n` 是 65535，却还是报错

这篇把 fd 从内核数据结构讲到 Java 侧泄漏点，给一套**能在 5 分钟内定位到具体泄漏源**的排查方法论，最后给容量估算公式。

---

## 一、fd 到底是什么：三层配额

先建立一个模型。一个进程能打开多少文件，受**三层**限制，任何一层撞墙都会报 `EMFILE` 或 `ENFILE`：

| 层级 | 限制项 | 查看方式 | 超出后果 |
|---|---|---|---|
| 进程级（soft） | `RLIMIT_NOFILE` | `ulimit -Sn` / `cat /proc/<pid>/limits` | `EMFILE: Too many open files` |
| 进程级（hard） | `RLIMIT_NOFILE` hard | `ulimit -Hn` | 无法再调高 soft |
| 系统级 | `fs.file-max` | `cat /proc/sys/fs/file-max` | `ENFILE: File table overflow` |
| 系统级（nr_open） | `fs.nr_open` | `cat /proc/sys/fs/nr_open` | `setrlimit` 直接失败 |

```bash
# 当前进程实际生效的限制（最准，别信 ulimit，它看的是当前 shell）
cat /proc/$(pgrep -f myapp.jar)/limits | grep -i "open files"

# 系统整体使用量：已分配 / 未使用 / 上限
cat /proc/sys/fs/file-nr

# 当前 shell 的
ulimit -Sn; ulimit -Hn
```

**三个常见误区**：

1. **`ulimit -n` 改的是当前 shell，不是 systemd 拉起的服务**。systemd 服务要在 unit 里配 `LimitNOFILE`，或在 `/etc/systemd/system/<svc>.service.d/limits.conf` 里覆盖。
2. **容器里 `ulimit -n` 可能显示 1048576，但 `LimitNOFILE` 在 docker run 时被覆盖成 1024**。进容器 `cat /proc/1/limits` 才是真相。
3. **`fs.nr_open` 是"任何单进程的上限"，`fs.file-max` 是"全系统上限"**，前者必须 ≤ 后者，否则 `setrlimit` 会静默失败。

---

## 二、一个 Java 进程的 fd 都花在哪了

这是排查的核心：**先分类，再看增长**。一个典型的 Spring Boot + Tomcat + Redis + MySQL 应用，fd 构成大致是：

| 类别 | 典型数量 | 说明 |
|---|---|---|
| Socket（已建立连接） | 数百~数万 | 每个 HTTP 连接、每条 DB 连接、每个 Redis 连接都是 1 个 fd |
| Listen socket | 1~3 | Tomcat 监听端口 |
| epoll fd | 1~N | NIO 的 selector，每个 selector 1 个 epoll fd |
| eventfd / timerfd | 2~10 | Netty、JVM、定时器 |
| Jar / 类路径文件 | 数十~数千 | **fat jar 里的嵌套 jar 在 Spring Boot 3 下是内存映射，不占大量 fd；但 `JarFile` 未关闭会泄漏** |
| 日志文件 | 数个 | logback 当前 + 归档 |
| `/dev/random`、`/dev/urandom` | 1~2 | SecureRandom |
| 管道 / 匿名 inode | 数个 | 进程间通信 |
| **`/proc/<pid>/fd` 里的 `(deleted)`** | ⚠️ 异常信号 | 文件已删但 fd 未关，**磁盘空间不释放** |

一条命令看清分布：

```bash
PID=$(pgrep -f myapp.jar)
ls -l /proc/$PID/fd 2>/dev/null \
  | awk '{print $NF}' \
  | sed -E 's#(socket):.*#\1#; s#(pipe):.*#\1#; s#(anon_inode):.*#\1#; s#/.*(/[^/]+)$#...\1#' \
  | sort | uniq -c | sort -rn | head -30
```

输出大概长这样，一眼就能看出问题：

```
  18432 socket:[3847561]
    412 anon_inode:[eventpoll]
     96 /data/logs/app.log
      3 .../app.jar
      2 /dev/urandom
      1 pipe:[123456]
```

**18432 个 socket、日志文件 96 个** → 两个独立问题：连接泄漏 + logback 归档没关流。

再看 socket 的对端，判断是"连出去的"还是"被连进来的"：

```bash
# 按对端 IP:PORT 聚合，找出泄漏目标
ls -l /proc/$PID/fd | grep socket | grep -o 'socket:\[[0-9]*\]' | grep -o '[0-9]*' \
  | while read ino; do grep -l "socket:\[$ino\]" /proc/net/tcp /proc/net/tcp6 2>/dev/null; done | wc -l

# 更快的方式：直接看 ss，按状态和 peer 聚合
ss -tanp | grep "pid=$PID" | awk '{print $1, $5}' | sort | uniq -c | sort -rn | head -20
```

输出里如果有 `ESTAB 18400 10.0.3.15:6379`，那基本就锁定了：**Redis 连接泄漏**（连接池没归还/没上限）。

---

## 三、Java 侧六大泄漏源（按发生频率排序）

### 3.1 HTTP 客户端没配连接池上限（最高频）

```java
// ❌ 灾难写法：每次请求 new 一个 client，且没设上限
public String call(String url) {
    HttpClient client = HttpClient.newHttpClient();   // 每次新建 selector + 连接池
    return client.send(request, BodyHandlers.ofString()).body();
}
```

`HttpClient.newHttpClient()` 每次都会创建自己的 selector 和连接池，**并且不会自动关闭**（Java 11 的 HttpClient 实现了 `AutoCloseable` 但很多人不知道）。压测 10 分钟，fd 直接上万。

```java
// ✅ 单例 + 显式上限 + 用完关 body
@Bean(destroyMethod = "close")
public HttpClient httpClient() {
    return HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(Duration.ofSeconds(2))
            .executor(Executors.newFixedThreadPool(16))
            .build();   // JDK 21+ 支持 close()
}
```

OkHttp 同理，而且更隐蔽：

```java
// ❌ 每个请求一个 OkHttpClient → 每个都有自己的 ConnectionPool 和 Dispatcher 线程
OkHttpClient c = new OkHttpClient();

// ✅ 全局单例，显式限制空闲连接
OkHttpClient ok = new OkHttpClient.Builder()
        .connectionPool(new ConnectionPool(64, 5, TimeUnit.MINUTES))  // maxIdle, keepAlive
        .build();

// body 必须关，否则连接不归还
try (Response resp = ok.newCall(req).execute()) {
    return resp.body().string();
}
```

### 3.2 流 / 连接 / ResultSet 没关

```java
// ❌ 异常路径泄漏
InputStream in = url.openStream();
byte[] data = in.readAllBytes();
in.close();   // 上面抛异常就到不了这行

// ✅ try-with-resources（注意：包装流只需要关最外层）
try (InputStream in = url.openStream()) {
    return in.readAllBytes();
}
```

JDBC 侧更要注意：`Connection`、`Statement`、`ResultSet` **三层都要关**，或者只关最外层（关闭会自动级联）。Spring 的 `JdbcTemplate` 已经帮你处理了，但手写 `DataSource.getConnection()` 的场景（比如 MyBatis 插件、批量任务）经常漏。

### 3.3 连接池"有上限"但没生效

这是最坑的一类：配置写了 `maximumPoolSize=20`，fd 还是涨到 5000。

| 原因 | 表现 | 排查 |
|---|---|---|
| 多数据源，每个池都有自己的上限 | fd = 池数 × 上限 | 数一下有几个 `DataSource` |
| `maxPerRoute` 没配，只有 `maxTotal` | 单目标占用全部配额 | HttpClient/OkHttp 双层限制 |
| 连接池被反复创建（`@RefreshScope`、动态数据源路由） | 旧池没 close，fd 泄漏 | heap dump 里数池实例个数 |
| 用了 `DriverManager` 而非 `DataSource` | 每次都新建物理连接 | `grep DriverManager` |
| Lettuce 共享连接 vs 独占连接 | 集群模式下每个节点多条 | 看 `ClientResources` 配置 |

```java
// HikariCP 关键：leakDetectionThreshold 能把"借了不还"打成日志
HikariConfig cfg = new HikariConfig();
cfg.setMaximumPoolSize(20);
cfg.setMinimumIdle(5);
cfg.setLeakDetectionThreshold(10_000);   // 10s 未归还就 WARN + 堆栈
cfg.setConnectionTimeout(3_000);
```

> `leakDetectionThreshold` 的日志里有**完整的借用堆栈**，这是定位"谁借了不还"的最快手段。生产建议开在 10~30s。

### 3.4 `JarFile` / `ZipFile` / `WatchService`

```java
// ❌ WatchService 每个实例占 1 个 inotify fd，不 close 就永久泄漏
WatchService ws = FileSystems.getDefault().newWatchService();
path.register(ws, ENTRY_MODIFY);
// ... 忘了 ws.close()

// ❌ JarFile 手工打开不关
JarFile jf = new JarFile(path);
jf.getEntry("x");   // 未 close
```

`WatchService` 还有个放大效应：**每个注册的目录都消耗 inotify watch，而 `max_user_watches` 是单独的配额**，和 fd 不是一回事，但报错很像。`sysctl fs.inotify.max_user_watches`。

### 3.5 Netty Channel 未关闭

Netty 的 fd 泄漏通常伴随两个信号：

- `ResourceLeakDetector` 报 `LEAK: ByteBuf.release() was not called`
- 连接数只涨不跌，`ChannelGroup.size()` 持续增长

```java
// ✅ 出站连接必须有超时 + 失败关闭
Bootstrap b = new Bootstrap()
        .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 2000)
        .handler(new ChannelInitializer<SocketChannel>() {
            @Override protected void initChannel(SocketChannel ch) {
                ch.pipeline().addLast(new IdleStateHandler(0, 0, 60));
                ch.pipeline().addLast(new ReadTimeoutHandler(10));
            }
        });

// 用完必须 close，且要处理 closeFuture 的异常
Channel ch = b.connect(host, port).sync().channel();
try {
    // ...
} finally {
    ch.close().awaitUninterruptibly(3, TimeUnit.SECONDS);
}
```

生产建议开 `-Dio.netty.leakDetection.level=paranoid`（仅压测环境，开销大）。

### 3.6 日志框架：rolling 时没关旧流

```xml
<!-- ❌ 按大小滚动但不设 maxHistory 和 totalSizeCap -->
<rollingPolicy class="ch.qos.logback.core.rolling.SizeAndTimeBasedRollingPolicy">
  <fileNamePattern>app.%d{yyyy-MM-dd}.%i.log</fileNamePattern>
  <maxFileSize>500MB</maxFileSize>
  <!-- 缺 maxHistory -->
</rollingPolicy>
```

正常情况 logback 滚动会关旧流，但**如果 `fileNamePattern` 里有 `%i` 且 `maxFileSize` 配置异常，或者自定义了 `TriggeringPolicy`，可能出现多个活跃流**。上面排查脚本里"日志文件 96 个"就是这个症状。

---

## 四、5 分钟定位法（可直接执行）

```bash
#!/bin/bash
# fd_diag.sh — 一次输出：总量 / 分类 / 增长速率 / 可疑对端
PID=${1:-$(pgrep -f 'java.*jar' | head -1)}
echo "=== PID $PID, limit: $(grep 'open files' /proc/$PID/limits | awk '{print $4}') ==="

echo "--- total fd ---"
ls /proc/$PID/fd 2>/dev/null | wc -l

echo "--- top categories ---"
ls -l /proc/$PID/fd 2>/dev/null | awk '{print $NF}' \
 | sed -E 's#socket:.*#socket#; s#pipe:.*#pipe#; s#anon_inode:.*#anon_inode#; s#/.*/([^/]+)$#\1#' \
 | sort | uniq -c | sort -rn | head -15

echo "--- socket peers (top 10) ---"
ss -tanp 2>/dev/null | grep "pid=$PID," | awk '{print $1, $5}' \
 | sort | uniq -c | sort -rn | head -10

echo "--- deleted-but-open (磁盘不释放的元凶) ---"
ls -l /proc/$PID/fd 2>/dev/null | grep -c deleted

echo "--- growth sample (5s) ---"
a=$(ls /proc/$PID/fd | wc -l); sleep 5; b=$(ls /proc/$PID/fd | wc -l)
echo "before=$a after=$b delta=$((b-a)) /5s"
```

判读规则：

| 现象 | 结论 |
|---|---|
| socket 占 90%+，且对端固定 | 某下游连接池泄漏，按 peer 定位 |
| socket 分散在大量不同对端 | 端口耗尽/客户端未复用，查 `TIME_WAIT` 与连接池 |
| `deleted` 数量持续增长 | 文件被删但流没关（日志/临时文件），查 `rm` 后重启前的老进程 |
| `anon_inode` 极多 | selector/epoll 泄漏，典型是反复 new `HttpClient`/`Selector` |
| 增量稳定（每秒 +N 且 N≈QPS） | 每请求泄漏 1 fd，看 QPS 对齐哪个下游 |

Java 侧还能用一段程序做定期巡检（不依赖外部命令）：

```java
@Component
public class FdMonitor {

    private final MeterRegistry registry;

    public FdMonitor(MeterRegistry registry) { this.registry = registry; }

    @Scheduled(fixedDelay = 30_000)
    public void sample() {
        Path fdDir = Paths.get("/proc/self/fd");
        if (!Files.isDirectory(fdDir)) return;   // 非 Linux 直接跳过

        Map<String, Long> byType = new HashMap<>();
        try (Stream<Path> s = Files.list(fdDir)) {
            s.forEach(p -> {
                String type = "other";
                try {
                    String target = Files.readSymbolicLink(p).toString();
                    if (target.startsWith("socket:")) type = "socket";
                    else if (target.startsWith("pipe:")) type = "pipe";
                    else if (target.startsWith("anon_inode:")) type = "anon_inode";
                    else if (target.endsWith("(deleted)")) type = "deleted";
                    else type = "file";
                } catch (IOException ignored) {
                }
                byType.merge(type, 1L, Long::sum);
            });
        } catch (IOException e) {
            return;
        }

        byType.forEach((k, v) -> registry.gauge("app.fd.count", Tags.of("type", k), v));
        long total = byType.values().stream().mapToLong(Long::longValue).sum();
        registry.gauge("app.fd.total", total);

        // 超过阈值告警，留足排查时间（别等撞上限）
        long limit = readLimit();
        if (limit > 0 && total > limit * 0.8) {
            log.error("fd usage {}/{} over 80%, top={}", total, limit, byType);
        }
    }

    private long readLimit() {
        try {
            for (String line : Files.readAllLines(Paths.get("/proc/self/limits"))) {
                if (line.startsWith("Max open files")) {
                    return Long.parseLong(line.substring(15).trim().split("\\s+")[0]);
                }
            }
        } catch (Exception ignored) {
        }
        return -1;
    }
}
```

**关键：按类型打点，而不是只打总量。** 总量只能告诉你"要炸了"，分类才能告诉你"是谁在炸"。

---

## 五、容量估算：别拍脑袋定 65535

一个可用的估算公式：

```
所需 fd ≈ 基线 + 入站连接 + 出站连接 × 池数 + 文件类 + 安全余量

基线（JVM + 框架）≈ 200 ~ 500
入站连接 = QPS × 平均耗时(s)  （Little's Law）
出站连接 = 每个下游的池上限之和（注意 maxPerRoute 与 maxTotal 取小）
文件类 = 日志 + jar + 临时文件，通常 < 200
安全余量 = 30%
```

算例：QPS 3000、平均 RT 50ms、下游 6 个（每个池 50）、日志 20 个：

```
入站 = 3000 × 0.05 = 150
出站 = 6 × 50 = 300
基线 400 + 20 文件
合计 ≈ 870 → 加 30% ≈ 1131
```

看起来 4096 就够，但**为什么线上还是炸了**？因为上面的公式算的是"稳态"，真实事故都来自**瞬时泄漏**：

- 一批定时任务同时打开 5000 个文件（比如批量导出）
- 某个下游超时，请求堆积导致连接池外的"临时连接"暴涨
- 重试风暴下，每次重试都新建连接

所以实践建议是：**软限设成估算值的 4~8 倍，硬限设成 2 倍软限，同时上 80% 告警**。真正该治理的是泄漏，不是把数字调大——把 `nofile` 从 65535 调到 1000000 只是把爆炸时间推后。

---

## 六、`Too many open files` 的四种变体，别搞混

| 报错 | 语义 | 根因 |
|---|---|---|
| `Too many open files`（EMFILE） | **进程** fd 到顶 | 泄漏 / 上限太低 |
| `Too many open files in system`（ENFILE） | **系统** fd 到顶 | 全机器进程加起来超 `file-max` |
| `Cannot assign requested address`（EADDRNOTAVAIL） | **本地端口**耗尽 | 短连接太多，`TIME_WAIT` 堆积，与 fd 无关 |
| `Connection reset` / 超时，但 fd 没满 | accept 队列满 | `somaxconn` / `tcp_abort_on_overflow`，与 fd 无关 |

第三、四种最容易被误判成 fd 问题。区分方法：

```bash
# 端口耗尽看这里
ss -s | grep -i timewait
cat /proc/sys/net/ipv4/ip_local_port_range

# accept 队列溢出看这里（ListenOverflows / ListenDrops 增长）
nstat -az | grep -i listen
```

如果是 `TIME_WAIT` 太多，解决方案是**连接复用**（长连接 + 连接池），不是调 `tcp_tw_reuse`。调内核参数只是掩盖症状。

---

## 七、治理清单

| 层面 | 措施 |
|---|---|
| 代码 | 所有 `Closeable` 用 try-with-resources；HTTP 客户端全局单例；池必须有上限 |
| 连接池 | Hikari `leakDetectionThreshold`；OkHttp `ConnectionPool(maxIdle, keepAlive)`；HttpClient 单例 |
| 框架 | Spring Boot 3 的 `JarFile` 已优化；自定义 ClassLoader 要 close |
| 运行环境 | systemd `LimitNOFILE`；容器 `--ulimit nofile`；确认 `/proc/1/limits` |
| 监控 | 按类型打点（socket/pipe/file/deleted），80% 阈值告警 |
| 排查 | 固化 `fd_diag.sh`，故障时一键跑；保留 `lsof -p` 快照 |
| 防复发 | 压测时开 Netty paranoid 泄漏检测；定期比对 fd 增长率 |

## 八、面试常见追问

**Q1：`ulimit -n` 改了为什么服务还是报错？**
A：`ulimit` 只影响当前 shell 及其子进程。systemd 拉起的服务继承的是 unit 里的 `LimitNOFILE`（默认常是 1024 或 65536），要用 `systemctl edit` 加 `[Service] LimitNOFILE=65535` 并 `daemon-reexec`。容器里则要看 `docker run --ulimit` 或 k8s 的 `securityContext`，进容器 `cat /proc/1/limits` 才是准的。

**Q2：fd 泄漏和内存泄漏的排查思路有什么不同？**
A：内存泄漏看堆（heap dump、引用链），fd 泄漏看**内核 fd 表**（`/proc/pid/fd`），heap dump 里往往什么都看不到——因为 `FileDescriptor` 对象可能已经被 GC 了，但内核里的 fd 还在（这就是经典的"GC 掉了对象但没 close"）。所以 fd 泄漏必须用**系统视角**排查，Java 视角只能辅助（比如 Hikari 的借用堆栈）。

**Q3：为什么 `Files.readAllBytes` 之后不 close 也可能不报错？**
A：小文件读完会自动读到 EOF，某些实现下流对象被 GC 时 `finalize`/`Cleaner` 会兜底关闭。但这**完全不可依赖**：GC 时机不确定，高并发下 fd 早就耗尽了。`Cleaner` 是最后保险，不是正确性保证。

**Q4：`TIME_WAIT` 很多是 fd 问题吗？**
A：不是。`TIME_WAIT` 是 TCP 状态，占的是**本地端口**（`ip_local_port_range` 默认约 2.8 万个），不是 fd。它会导致 `Cannot assign requested address`，和 `EMFILE` 是两回事。解法是连接复用，不是调 `tcp_tw_reuse`（后者在 NAT 环境还有风险）。

**Q5：怎么证明某个连接池是泄漏源？**
A：三个证据链：① `ss` 显示 fd 集中指向同一 `peer`；② fd 增长率 ≈ 该下游 QPS；③ 开 `leakDetectionThreshold` 后日志里出现借用堆栈。三者对齐即可定案。只靠"重启能好"永远定不了案。

---

## 九、总结

- fd 有**三层配额**（进程 soft/hard、系统 file-max、fs.nr_open），撞哪层报错不同。
- 排查第一步永远是**分类**：socket / pipe / anon_inode / file / deleted，五类分开数。
- Java 侧最高频的三个泄漏源：HTTP 客户端非单例、流没关、连接池上限没生效。
- `deleted` 计数增长意味着**磁盘空间没释放**，这是很多人忽略的连带故障。
- 定容量用 Little's Law 算稳态，再乘 4~8 倍留泄漏余量；但真正的解法是治泄漏，不是调大上限。
- `EMFILE` / `ENFILE` / `EADDRNOTAVAIL` / accept 队列溢出是四个不同的问题，别一律当 fd 处理。

把这套流程固化成脚本 + 监控，下次告警你就不用靠重启蒙了。
