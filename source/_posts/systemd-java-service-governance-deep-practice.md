---
title: 【运维实战】systemd 与 Java 服务治理：sd_notify、看门狗、cgroup 限额与优雅停机
date: 2026-11-21 08:10:00
tags:
  - Java
  - Linux
  - systemd
  - 运维
  - 生产实践
categories:
  - 生产运维
author: 东哥
---

# 【运维实战】systemd 与 Java 服务治理

## 前言

一个 Java 服务上线，多数团队的做法是 `nohup java -jar app.jar &`，或者写个 `start.sh` 里套 `nohup`，之后再补一个 `kill -9 $PID` 的 `stop.sh`。这套东西在单机上能跑三年，但一旦碰上这几种情况就会露馅：

- 机器重启后服务没起来（没人记得加 `rc.local`）。
- 进程 OOM 被内核杀了，没人知道，直到用户投诉。
- 服务假死（线程全卡住但进程还在），负载均衡还在往上打流量。
- 运维 `kill` 了一下，正在处理的事务被硬切，产生脏数据。
- 日志把磁盘写满，整个节点上的服务一起挂。

systemd 不是"启动脚本管理器"，它是**进程生命周期的唯一权威**：它管启动顺序、管重启策略、管资源上限、管日志、管优雅退出、还管"这个进程还活着吗"。这篇文章讲清楚 Java 服务该怎么和它配合，以及那些配置项背后的真实语义。

## 一、先选对 Type：simple / exec / notify / forking

| Type | systemd 认为"启动完成"的时机 | 适用场景 |
|---|---|---|
| `simple` | `fork()` 之后立刻认为启动成功 | 最简单，但启动失败也被当成功 |
| `exec` | `execve()` 成功之后 | 比 `simple` 稍好，能捕获"二进制不存在" |
| `notify` | 进程主动发 `READY=1` | **Java 服务推荐**，Spring 容器就绪才算启动完成 |
| `forking` | 父进程退出、子进程接管 | 传统守护进程，Java 基本不用 |
| `oneshot` | 进程退出且 exit=0 | 初始化任务、迁移脚本 |

很多人用 `Type=simple`，然后抱怨"服务启动失败 systemd 也不重启"。原因很直接：`simple` 下 systemd 在 fork 完就认为成功了，之后的 `ClassNotFoundException`、端口占用、配置缺失，全都被当成"运行中崩溃"——如果 `Restart=on-failure` 配了还好，没配就静默躺平。

`Type=notify` 才是正解：进程真正 ready 之后才发信号，启动阶段的失败会被算作启动失败，能触发 `StartLimitBurst` 的熔断逻辑。

### 1.1 Java 怎么发 `READY=1`

systemd 的协议极其简单：往 `$NOTIFY_SOCKET` 指向的 **Unix datagram socket** 发一行文本，比如 `READY=1\n`。

Java 没有标准库支持（`java.net` 不支持 Unix domain socket），所以只有两条路：

**路线一：调 `systemd-notify` 二进制（零依赖）**

```java
public final class SystemdNotify {
    private static final String SOCKET = System.getenv("NOTIFY_SOCKET");

    public static boolean available() {
        return SOCKET != null && !SOCKET.isEmpty();
    }

    /** 发送任意状态字符串，例如 "READY=1"、"WATCHDOG=1"、"STATUS=Serving" */
    public static void notify(String state) {
        if (!available()) return;
        try {
            new ProcessBuilder("systemd-notify", state)
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .start()
                    .waitFor(2, TimeUnit.SECONDS);
        } catch (Exception e) {
            // 通知失败不能影响主流程，只记录
            log.warn("sd_notify failed: {}", e.toString());
        }
    }
}
```

关键点：**`systemd-notify` 是从另一个 PID 发出的**，systemd 默认只接受主进程的通知（`NotifyAccess=main`），所以 unit 里必须写：

```ini
NotifyAccess=all
```

否则你会看到 systemd 一直等到 `TimeoutStartSec` 然后判定启动失败，而应用日志里一切正常 —— 这个坑非常经典。

**路线二：用 JNA / junixsocket 直接写 socket**

零 fork 开销，适合看门狗（15 秒一次，一天 5760 次 fork 不算多，但在容器里有 PID 上限和 `TasksMax` 的场景仍要留意）。如果团队已有 JNA 依赖，直接调用 `socket(AF_UNIX, SOCK_DGRAM)` + `sendto` 即可；不想维护 JNI 代码就用路线一。

### 1.2 什么时候发 READY

不要放在 `main()` 第一行。正确时机是 **Spring 容器刷新完成、端口已监听、下游连接池预热完成之后**：

```java
@Component
public class ReadinessNotifier implements ApplicationListener<ApplicationReadyEvent> {
    @Override
    public void onApplicationEvent(ApplicationReadyEvent event) {
        SystemdNotify.notify("READY=1");
        SystemdNotify.notify("STATUS=HTTP 8080 ready, profile=" + env);
    }
}
```

`ApplicationReadyEvent` 在 `ContextRefreshedEvent` 之后、Web 服务器启动之后触发，是"可以接流量"的信号。用 `ContextRefreshedEvent` 早了半步（Tomcat 可能还没 bind 完）。

## 二、看门狗：把"假死"变成"自动重启"

这是 systemd 对 Java 服务最有价值、也最少人用的功能。

```ini
WatchdogSec=30
Restart=always
```

语义：systemd 要求进程**每 30 秒内至少发一次 `WATCHDOG=1`**，超时未收到 → 判定进程失活 → 发 `SIGABRT`（默认 `WatchdogSignal`）→ `Restart=always` 拉起。

注意：`WatchdogSec` 不是"每 30 秒检查一次"，而是"距离上次心跳超过 30 秒就杀"。所以发送间隔要取一半左右：

```java
ScheduledExecutorService wd = Executors.newSingleThreadScheduledExecutor(
        r -> { Thread t = new Thread(r, "sd-watchdog"); t.setDaemon(true); return t; });

wd.scheduleAtFixedRate(() -> {
    if (healthIsOk()) {
        SystemdNotify.notify("WATCHDOG=1");
    } else {
        // 故意不发：让 systemd 在 WatchdogSec 后杀掉并重启
        log.error("health DOWN, withholding watchdog heartbeat");
    }
}, 15, 15, TimeUnit.SECONDS);
```

**把心跳和健康检查绑在一起，是这个机制真正的价值**：默认的 `Restart=on-failure` 只能处理"进程死了"，处理不了"进程活着但所有请求超时"。后者的典型原因是数据库连接池耗尽、线程池打满、下游全挂 —— 这些情况下进程 RSS 正常、CPU 可能还很低，Kubernetes 的 liveness 探针要额外配 HTTP 检查，而 systemd 场景下用看门狗是零成本的。

### 2.1 一个必须避免的写法

```java
// 反模式：无条件发心跳
wd.scheduleAtFixedRate(() -> SystemdNotify.notify("WATCHDOG=1"), 15, 15, SECONDS);
```

这就是"给死人接心电图"——心跳只证明调度线程活着，不证明服务可用。心跳函数里必须有实质判断：最近一次成功请求的时间戳、连接池可用连接数、事件循环延迟。

### 2.2 `WATCHDOG_USEC` 要读环境变量

别把 15 秒硬编码。systemd 会把实际超时（微秒）放在 `WATCHDOG_USEC`，同时把应接收心跳的 PID 放在 `WATCHDOG_PID`（若设置了 `WatchdogSec` 且 unit 由 systemd 管理）。自定义配置改了 `WatchdogSec` 而代码没改，就会出现"永远差一点"的反复重启。

```java
String usec = System.getenv("WATCHDOG_USEC");
long intervalMs = usec == null ? 15_000 : Long.parseLong(usec) / 1000 / 2;
```

## 三、优雅停机：`KillMode` 决定你是"优雅"还是"硬切"

Spring Boot 2.3+ 支持优雅停机：

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

但这段配置只有收到 `SIGTERM` 才生效。如果 systemd 直接 `SIGKILL`，Spring 根本没机会执行 `SmartLifecycle#stop`。

### 3.1 三层超时必须严格递增

```ini
[Service]
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=60
```

| 层级 | 配置 | 含义 |
|---|---|---|
| 应用内 | `timeout-per-shutdown-phase: 30s` | 等正在处理的请求结束 |
| systemd | `TimeoutStopSec=60` | 等 60 秒还没退就 `SIGKILL` |
| 上游 | LB `deregistration_delay` | 先把流量摘掉，再发 SIGTERM |

顺序必须是 **LB 摘流量 → SIGTERM → 应用优雅停机 → 进程退出**。如果 LB 摘流量和应用停机同时发生，就会有一批请求打到已经关掉的端口，表现为 502。

### 3.2 `KillMode` 的三种语义

| 值 | 行为 | 后果 |
|---|---|---|
| `control-group`（默认） | 向 cgroup 内**所有**进程发 SIGTERM | 如果服务 fork 了子进程（比如调用 `ffmpeg`、`python` 脚本），它们会被一起杀，可能来不及清理临时文件 |
| `mixed` | 只向主进程发 SIGTERM，超时后向整个 cgroup 发 SIGKILL | **Java 服务推荐**，主进程有机会优雅退出，超时后强制清场 |
| `process` | 只向主进程发信号，不碰其他进程 | 有子进程时可能产生孤儿进程 |

`mixed` 是折中方案：给主进程优雅退出的窗口，也给超时后的强杀兜底。

### 3.3 退出码的真相

`systemctl status` 里看到的退出码：

- `0` / `143`（128+15，SIGTERM）：正常。
- `137`（128+9，SIGKILL）：被强杀 —— 要么 `TimeoutStopSec` 超了，要么内核 OOM killer。
- `134`（128+6，SIGABRT）：JVM 崩溃或 `-XX:+CrashOnOutOfMemoryError`。
- `1`：应用自己 `System.exit(1)`。

**`137` 是最需要警惕的**：它可能是"优雅停机超时被 systemd 杀"，也可能是"cgroup OOM 被内核杀"。区分方法：

```bash
journalctl -u myapp --since "10 min ago" | grep -iE "oom|killed process"
dmesg -T | grep -i "killed process"
systemctl show myapp -p Result -p ExecMainStatus
```

`Result=oom-kill` 是内核 OOM；`Result=timeout` 是 `TimeoutStopSec` 超时。两者的优化方向完全相反。

## 四、cgroup 限额与 JVM 的双重记账

systemd 在 cgroup v2 上的资源控制项，会直接影响 JVM：

```ini
[Service]
MemoryHigh=3G
MemoryMax=3.5G
CPUQuota=200%
TasksMax=4096
LimitNOFILE=65535
```

### 4.1 `MemoryMax` 与堆大小的关系

JVM 在容器里通过 cgroup 读内存上限来算默认堆（`MaxRAMPercentage` 默认 25%）。但 `MemoryHigh`/`MemoryMax` 的语义不同：

- `MemoryHigh`：软限。超过后内核开始**强制回收**（直接 reclaim），进程会被限速但不会被杀。表现是"服务变慢、GC 变频繁"，非常隐蔽。
- `MemoryMax`：硬限。超过 → cgroup OOM killer 杀进程，退出码 137。

危险组合是：`MemoryMax=3.5G`，JVM 用默认 `MaxRAMPercentage=25%` → 堆只有 875M，浪费；如果手动设 `-Xmx3G`，则堆 + Metaspace + 线程栈 + Direct Buffer + JNI 很容易突破 3.5G。

务实公式：

```text
MemoryMax ≈ heap / 0.7
```

`-Xmx2.4G` 配 `MemoryMax=3.5G`，留 1.1G 给非堆。同时打开：

```text
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/var/log/myapp/heapdump.hprof
-XX:+ExitOnOutOfMemoryError
```

⚠️ 但堆转储文件可能等于堆大小。如果 `/var/log` 和容器 writable layer 在同一块盘，一次 OOM 就能把磁盘打满，进而触发节点级故障。**堆转储目录必须是独立挂载或独立磁盘**，并且加 `ReadWritePaths` 白名单。

### 4.2 `CPUQuota` 不会改变 `availableProcessors()`

`CPUQuota=200%` 表示"最多用 2 个核的算力"，但 JVM 的 `Runtime.availableProcessors()` **只认 cpuset（`cpuset.cpus`），不认 quota**。所以 `nproc` 看到 32、JVM 也看到 32，于是 ForkJoinPool、GC 线程数、Netty 的 event loop 全按 32 开，然后被 quota 限到 2 核 —— 上下文切换暴增，延迟抖动。

解法（任选）：

```text
-XX:ActiveProcessorCount=2
```

或者用 cpuset 而不是 quota 限核（`AllowedCPUs=0-1`）。前者更常用，因为 quota 允许突发。

### 4.3 `LimitNOFILE` 与 fd 耗尽

systemd unit 的默认 `LimitNOFILE` 继承 `DefaultLimitNOFILE`，很多发行版是 1024。对一个有 200 个下游 HTTP 连接 + 50 个 DB 连接 + 大量日志文件的服务，1024 很快不够，表现为 `Too many open files`。

```ini
LimitNOFILE=65535
TasksMax=4096
```

`TasksMax` 是 cgroup 的 pids 上限（线程也算）。虚拟线程场景下，平台线程数没变化，但 `TasksMax` 仍然要留足；如果用了大量 `new Thread()` 或 `ForkJoinPool`，4096 是个安全起点。

## 五、安全加固：几行配置挡住大部分横向移动

```ini
[Service]
User=app
Group=app
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/myapp /var/lib/myapp
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

逐条说明容易踩的地方：

- `ProtectSystem=strict` 把整个文件系统挂成只读（`/dev`、`/proc`、`/sys` 除外），**包括 `/tmp`**？不，`/tmp` 由 `PrivateTmp` 管。但应用如果要写 `/opt/app/config` 或当前目录下的临时文件，就会 `Read-only file system`。必须用 `ReadWritePaths` 显式开洞。
- `PrivateTmp=true` 给服务一个私有的 `/tmp`，**跨服务共享 `/tmp` 文件的方案会立刻失效**（比如某些 sidecar 通过 `/tmp` 传 socket）。
- `ProtectHome=true` 让 `/home`、`/root` 不可见。如果 JVM 参数里 `-javaagent:/root/agent.jar`，会启动失败。
- `RestrictAddressFamilies` 限制 socket 类型。用了 Unix domain socket 的（本地 Redis、Docker socket）必须包含 `AF_UNIX`；用了 `AF_NETLINK`（某些监控采集）也要加。

## 六、日志：journald 与 logback 的分工

```ini
[Service]
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp
```

这里有一个高频事故：**logback 写文件 + systemd 收 stdout，同一份日志写两遍**，磁盘占用翻倍；更麻烦的是 journald 有速率限制：

```ini
[Service]
LogRateLimitIntervalSec=30s
LogRateLimitBurst=10000
```

超过后 journald 会**丢弃**日志并打一条 `Suppressed N messages`。这意味着故障时最关键的日志恰恰可能被丢 —— 因为故障时日志量最大。

三种务实方案：

| 方案 | 做法 | 适用 |
|---|---|---|
| 全量 journald | logback 只写 console，`StandardOutput=journal` | 中小规模，统一用 `journalctl` 查 |
| 全量文件 | `StandardOutput=null`，logback 写文件 + logrotate | 已有 ELK/Loki 采集 |
| 混合（推荐） | console 走 journald 做 `systemctl status` 速查；文件走采集做长期检索 | 生产 |

`journalctl` 的常用姿势：

```bash
journalctl -u myapp -f                    # 实时
journalctl -u myapp --since "10 min ago" -o cat
journalctl -u myapp -p err --since today  # 只要 error 及以上
journalctl -u myapp -b -1                 # 上一次启动
journalctl --disk-usage && journalctl --vacuum-size=2G
```

`-o cat` 只输出消息体，去掉时间戳和主机名，读起来干净很多。

## 七、完整的 unit 模板

```ini
[Unit]
Description=Order Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=notify
NotifyAccess=all
User=app
Group=app
WorkingDirectory=/opt/order
EnvironmentFile=-/etc/sysconfig/order
Environment="JAVA_HOME=/usr/lib/jvm/jdk-21"
ExecStart=/usr/lib/jvm/jdk-21/bin/java \
  -XX:MaxRAMPercentage=70 \
  -XX:ActiveProcessorCount=4 \
  -XX:+ExitOnOutOfMemoryError \
  -XX:+HeapDumpOnOutOfMemoryError \
  -XX:HeapDumpPath=/var/lib/order/dump \
  -jar /opt/order/order.jar

SuccessExitStatus=143
Restart=always
RestartSec=5
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=60
WatchdogSec=30

MemoryHigh=3G
MemoryMax=3.5G
CPUQuota=400%
TasksMax=4096
LimitNOFILE=65535

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/order /var/lib/order
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

StandardOutput=journal
StandardError=journal
SyslogIdentifier=order

[Install]
WantedBy=multi-user.target
```

`SuccessExitStatus=143` 其实非必需（systemd 默认把 SIGTERM 视为干净退出），但写上更明确，避免有人改 `KillSignal=SIGUSR2` 后行为变化。

## 八、排障命令速查

```bash
systemd-analyze verify /etc/systemd/system/order.service   # 语法 + 依赖检查
systemctl cat order                                        # 看最终生效配置（含 drop-in）
systemctl show order -p MainPID -p Result -p ExecMainStatus -p NRestarts
systemctl status order                                     # 最近日志 + 退出码
journalctl -u order -b --no-pager | tail -100
systemd-cgls /system.slice/order.service                   # 看 cgroup 内进程树
systemctl reset-failed order                               # 触发 StartLimit 后必须重置
```

`systemctl show -p Result` 的输出是最有价值的：

| `Result` | 含义 |
|---|---|
| `success` | 正常退出 |
| `exit-code` | 应用返回非零 |
| `signal` | 被信号杀死（看 `ExecMainStatus` 是否 137/143） |
| `oom-kill` | cgroup 内存超限被内核杀 |
| `timeout` | 启动或停止超时 |
| `watchdog` | 看门狗超时 |

## 九、面试追问

**Q：`Type=notify` 和健康检查探针（liveness）有什么区别？**

`Type=notify` 只解决"启动完成"这一个时刻的判定，属于一次性事件；liveness 探针是持续判定。systemd 的对应物是 `WatchdogSec` + 周期性 `WATCHDOG=1`。两者解决的是不同问题：前者防"启动失败被当成功"，后者防"运行中假死"。

**Q：为什么 Java 服务推荐 `KillMode=mixed` 而不是默认的 `control-group`？**

默认模式会把 SIGTERM 发给 cgroup 里所有进程。如果服务启动了子进程（外部工具、shell 脚本），它们会同时收到信号，可能在主进程还在优雅退出时就已经死掉，导致主进程等待子进程结果超时。`mixed` 只给主进程发 SIGTERM，超时后再对整个 cgroup 强杀。

**Q：`MemoryHigh` 和 `MemoryMax` 哪个更危险？**

`MemoryHigh` 更阴险。它不杀进程，只触发强制回收和限速，表现为"服务变慢但监控没有明显错误"，很难归因。`MemoryMax` 至少会留下明确的 OOM 记录和 137 退出码。

**Q：`Restart=always` 会不会导致无限重启风暴？**

会被 `StartLimitBurst`/`StartLimitIntervalSec` 拦住。默认是 5 次/10 秒，超过后 unit 进入 `failed` 状态，**不再自动重启**，必须 `systemctl reset-failed`。这正是"启动配置错误"应该有的行为 —— 快速失败并告警，而不是无限刷日志。

## 十、落地清单

1. `Type=notify` + `NotifyAccess=all`，在 `ApplicationReadyEvent` 发 `READY=1`。
2. 看门狗间隔取 `WATCHDOG_USEC` 的一半，且心跳必须绑定健康判断。
3. `TimeoutStopSec` > Spring `timeout-per-shutdown-phase`，上游先摘流量。
4. `KillMode=mixed`。
5. `MemoryMax ≈ heap / 0.7`，堆转储目录必须独立挂载。
6. `CPUQuota` 场景必须显式 `-XX:ActiveProcessorCount`。
7. `LimitNOFILE=65535`，`TasksMax` 留足。
8. `ProtectSystem=strict` 必须配 `ReadWritePaths`，否则应用写不了文件。
9. 日志选一条路，别双写；journald 速率限制要按峰值流量调。
10. 告警里带 `Result` 字段，别只报"服务挂了"。

systemd 的这些能力，Kubernetes 里对应的是探针、`resources.limits`、`preStop`、`PDB`。但大量团队的真实环境仍是"物理机/虚机 + systemd"，把这层配好，等于不花钱买到了 80% 的编排能力。
