---
title: 【性能调优】overlayfs 与容器写放大深度解析：copy-up、page cache 双份与 Java 应用 ENOSPC 归因
date: 2026-11-14 08:20:00
tags:
  - Linux
  - Docker
  - overlayfs
  - 性能调优
  - 容器
categories:
  - 性能调优
author: 东哥
---

# 【性能调优】overlayfs 与容器写放大深度解析

## 前言

一个很典型的生产故障：Java 服务在虚拟机里跑得好好的，迁到 Kubernetes 之后，日志一多就 `No space left on device`，节点磁盘明明还有空间；或者某个服务启动特别慢，`strace` 一看全耗在 `openat` 上；再或者容器内存莫名其妙翻倍，`jcmd GC.heap_info` 显示堆只用了 1G，cgroup 却记账 2.5G。

这三个现象背后经常是同一个东西：**overlayfs 的写时复制（copy-up）**。

容器镜像分层是 Docker 的核心设计，但很多人只记住了「分层省空间」，没意识到**任何对镜像层文件的写操作，都会先把整个文件复制到可写层**。这个「整文件复制」就是写放大的源头。

这篇从 overlay2 的目录结构讲起，把 copy-up 的触发条件、放大倍数、page cache 双份、观测手段和 Java 侧治理讲透。

---

## 一、overlay2 的四层结构

```bash
$ mount | grep overlay
overlay on /var/lib/docker/overlay2/xxxx/merged type overlay
  (rw,relatime,lowerdir=/var/lib/docker/overlay2/l/AAA:/var/lib/docker/overlay2/l/BBB,
   upperdir=/var/lib/docker/overlay2/xxxx/diff,
   workdir=/var/lib/docker/overlay2/xxxx/work)
```

| 目录 | 角色 | 可写 | 说明 |
|---|---|---|---|
| `lowerdir` | 镜像层（可能多层） | ❌ | 只读，多个用 `:` 分隔，**右边的优先级低** |
| `upperdir` | 容器可写层 | ✅ | 容器生命周期内所有写都落这里 |
| `workdir` | 内部工作目录 | — | overlayfs 自己用，必须与 upperdir 同文件系统 |
| `merged` | 挂载点（容器看到的根） | ✅ | 合并视图 |

读文件时，overlayfs 从上往下找第一个存在的层；写文件时：

- 文件只在 upperdir → 直接写；
- 文件在 lowerdir → **先 copy-up 整个文件到 upperdir**，再写。

```
读：merged/app/config.yml
      ├─ upperdir 有？ 有 → 用
      └─ 没有 → 逐层往下找 lowerdir

写：merged/app/config.yml（只在 lowerdir）
      └─ copy-up：整个 config.yml → upperdir/diff/app/config.yml
                  （连同元数据、扩展属性）
         然后才在 upperdir 的副本上写
```

---

## 二、copy-up 的四个触发条件（比你想的多）

不只是 `write()` 会触发：

| 操作 | 是否 copy-up | 说明 |
|---|---|---|
| `open(O_WRONLY)` / `O_RDWR` | ✅ | 打开即复制，还没写也算 |
| `truncate` / `ftruncate` | ✅ | 改大小 |
| `chmod` / `chown` / `setxattr` | ✅ | 改元数据也复制整个文件 |
| `rename` 下层文件 | ✅ | 需要在新层有实体 |
| **删除**下层文件 | ❌（创建 whiteout） | upperdir 里建 0/0 字符设备 |
| 只读 `open(O_RDONLY)` | ❌ | 直接用下层 |

两个高频误伤场景：

1. **日志框架打开文件时用 `O_APPEND|O_CREAT|O_WRONLY`** → 触发 copy-up。如果镜像里预置了一个 500MB 的历史日志文件，容器每次启动都要复制 500MB。
2. **`chown -R` 镜像里的目录** → 目录下每个文件都 copy-up。很多 Dockerfile 里一句 `RUN chown -R app:app /app` 就把镜像层里的所有文件复制了一遍，镜像体积直接翻倍。

---

## 三、写放大到底放大多少

设文件在镜像层的大小为 `S`，应用写入 `w` 字节：

```
实际落盘写 = S（copy-up） + w（业务写） + 元数据
放大倍数 ≈ (S + w) / w
```

举几个真实量级（NVMe，overlay2 on xfs）：

| 场景 | 文件在镜像层大小 | 业务写 | 实际写盘 | 放大 |
|---|---|---|---|---|
| 追加日志到 1GB 历史文件 | 1 GB | 4 KB | ~1 GB | **25 万倍** |
| 改 200MB 配置包里的一个文件 | 200 MB | 1 KB | ~200 MB | 20 万倍 |
| 写入全新文件（不在镜像层） | 0 | 100 MB | 100 MB | 1 倍 |
| 写挂载卷（volume） | — | 100 MB | 100 MB | 1 倍 |
| 随机写 1GB 已存在的数据库文件 | 1 GB | 1 GB | ~2 GB | 2 倍 |

所以判断标准很简单：**文件是不是来自镜像层**。来自镜像层的大文件，第一次写就是灾难。

### 3.1 目录 rename 的隐藏放大

overlayfs 的 `redirect_dir` 默认关闭（`redirect_dir=off`）时，`rename` 一个来自下层的目录会退化成「递归 copy-up 整棵子树」：

```bash
# 镜像层有 /opt/app/data/（10 万个文件，20GB）
$ mv /opt/app/data /opt/app/data.bak   # 触发整树 copy-up
```

容器启动脚本里做「备份旧目录」是常见操作，代价可能是几十 GB 写入。解法：挂 volume，或在 Dockerfile 里就不要把可变目录放进镜像层。

---

## 四、page cache 双份：内存记账翻倍的真相

这是最容易被误判为「JVM 内存泄漏」的问题。

当进程 A 只读打开下层文件（page cache 挂在 lower inode 上），进程 B 以写方式打开同一文件触发 copy-up 后，**upperdir 里是一个新 inode**，page cache 是**按 inode 记账**的 → 同一份内容在内存里存了两份。

```
进程 A  read-only → lower inode  → page cache 页组 #1
进程 B  open(RW)  → copy-up → upper inode → page cache 页组 #2
```

在 cgroup v2 下，这两份都算在容器的 `memory.current` 的 file 部分。于是一个 2GB 的镜像层文件被容器里两个进程分别读写，可能记账 4GB+。

判断方法：

```bash
# 容器内看 file 页缓存
cat /sys/fs/cgroup/memory.stat | grep -E "^(file|inactive_file|active_file) "

# 宿主机看某个文件的 page cache（需要 fincore/vmtouch）
fincore /var/lib/docker/overlay2/xxxx/diff/app/big.dat
```

注意：page cache 是**可回收**的，`memory.current` 高不等于 OOM。判断 OOM 风险要看 `memory.stat` 里的 `anon`，以及 `memory.events` 的 `oom` 计数。

---

## 五、观测：五条命令定位写放大

### 5.1 容器可写层有多大

```bash
$ docker ps -s
CONTAINER ID   SIZE       VIRTUAL SIZE
a1b2c3d4       1.82GB     3.4GB
```

`SIZE` 就是 upperdir 的大小。如果它随时间线性增长，先查是谁在写。

### 5.2 谁在写

```bash
# 容器内
$ du -sh /var/lib/docker/overlay2/<id>/diff/* 2>/dev/null | sort -h | tail

# 或者进了容器直接找大文件（注意会触发 atime/元数据，慎用）
$ find / -xdev -type f -size +100M -exec ls -lh {} \;
```

### 5.3 cgroup v2 的 IO 记账

```bash
$ cat /sys/fs/cgroup/io.stat
8:16 rbytes=1200349184 wbytes=8842190336 rios=42113 wios=201884 dbytes=0 dios=0
```

`wbytes` 是「发到块设备的字节数」，包含 copy-up。对比容器内应用自己统计的写入量，差值就是放大。

```bash
$ cat /sys/fs/cgroup/io.pressure
some avg10=12.31 avg60=8.02 avg300=3.11 total=88421903
full avg10=9.87  avg60=6.44 avg300=2.05 total=70112334
```

`full` 高说明所有任务都在等 IO，不是个别慢。

### 5.4 确认挂载类型

```bash
$ findmnt -T /app/logs -o TARGET,SOURCE,FSTYPE
TARGET     SOURCE                          FSTYPE
/app/logs  /dev/nvme0n1p1[/var/lib/...]    xfs     ← 其实是 overlay 上的目录
```

最可靠的是看 `/proc/self/mountinfo`：

```bash
$ grep -m1 overlay /proc/self/mountinfo
```

### 5.5 用 bpftrace 抓 copy-up（内核 5.x + 支持 BTF）

```bash
bpftrace -e 'kprobe:ovl_copy_up_one { @[comm] = count(); }'
```

---

## 六、Java 应用为什么特别容易踩

Java 服务的典型形态是「启动时读一堆配置文件、写一堆日志、偶尔 dump 堆」，每一条都踩在 copy-up 上。

| Java 行为 | 风险 | 建议 |
|---|---|---|
| logback 写 `/app/logs/app.log`（镜像层预置） | 整文件 copy-up | 日志输出 stdout，或挂 volume |
| `System.getProperty("java.io.tmpdir")` 默认 `/tmp` | 写容器层 | 挂 `emptyDir` 或 `--tmpfs /tmp` |
| `HeapDumpOnOutOfMemoryError` 写工作目录 | 大 dump 落可写层，可能撑爆磁盘 | 指定到挂载卷 |
| JFR 录制 `.jfr` 文件 | 同上 | 同上 |
| 本地缓存（RocksDB / Lucene 索引） | 大量随机写 + fsync | 必须挂 volume，且用 local SSD |
| 解压依赖到工作目录 | 整包复制 | 解压到 tmpfs |

### 6.1 一个启动自检：日志目录是不是可写层

```java
@Component
@Slf4j
public class StorageLayoutChecker implements ApplicationRunner {

    private static final Set<String> RISKY_FS =
            Set.of("overlay", "overlay2", "fuse.fuse-overlayfs", "aufs");

    @Override
    public void run(ApplicationArguments args) {
        Path[] mustBeVolume = {
                Path.of("/app/logs"),
                Path.of(System.getProperty("java.io.tmpdir")),
                Path.of("/app/data")
        };
        for (Path p : mustBeVolume) {
            String fs = fstypeOf(p);
            if (RISKY_FS.contains(fs)) {
                log.warn("路径 {} 位于 {} 文件系统（容器可写层），大文件写入会触发 copy-up 写放大", p, fs);
            }
        }
    }

    /** 从 /proc/self/mountinfo 找最长匹配挂载点 */
    private String fstypeOf(Path path) {
        String target = path.toAbsolutePath().normalize().toString();
        String best = null;
        int bestLen = -1;
        try (Stream<String> lines = Files.lines(Path.of("/proc/self/mountinfo"))) {
            for (String line : (Iterable<String>) lines::iterator) {
                String[] parts = line.split(" ");
                if (parts.length < 5) continue;
                String mountPoint = parts[4];
                String fsType = parts[parts.length - 3 >= 0 ? parts.length - 3 : 0];
                // mountinfo 中 fstype 在 " - " 之后
                int sep = line.indexOf(" - ");
                if (sep > 0) {
                    String[] post = line.substring(sep + 3).split(" ");
                    if (post.length > 0) fsType = post[0];
                }
                if ((target.equals(mountPoint) || target.startsWith(mountPoint + "/"))
                        && mountPoint.length() > bestLen) {
                    bestLen = mountPoint.length();
                    best = fsType;
                }
            }
        } catch (IOException e) {
            log.debug("读取 mountinfo 失败", e);
        }
        return best == null ? "unknown" : best;
    }
}
```

这段代码不完美（mountinfo 解析要处理转义空格），但足以在启动日志里给出明确告警。生产上更推荐直接用 `findmnt -T <path> -o FSTYPE -n` 的 sidecar 检查。

### 6.2 日志写入的正确姿势

```yaml
# logback-spring.xml：只输出到 stdout，让容器运行时接管
<appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
  <encoder>
    <pattern>%d{ISO8601} %-5level [%thread] %logger{36} - %msg%n</pattern>
  </encoder>
</appender>

<root level="INFO">
  <appender-ref ref="CONSOLE"/>
</root>
```

如果业务必须落文件（比如审计日志），挂独立 volume，并设置滚动上限：

```yaml
# k8s
volumeMounts:
  - name: logs
    mountPath: /app/logs
volumes:
  - name: logs
    emptyDir:
      sizeLimit: 5Gi
```

---

## 七、fuse-overlayfs / rootless：额外一层税

rootless 容器（Podman rootless、Docker rootless）常退化为 `fuse-overlayfs`：文件操作要走 FUSE 用户态，每次 `open/write` 多两次上下文切换。

实测差异（同一台机器，写 10 万个 4KB 小文件）：

| 存储驱动 | 耗时 | 相对开销 |
|---|---|---|
| overlay2（root） | 18.4s | 1.0x |
| fuse-overlayfs（rootless） | 41.2s | 2.2x |
| 直接写 xfs | 15.1s | 0.8x |

所以 rootless 环境里，**小文件密集写入的 Java 应用（Lucene、RocksDB、日志）性能会明显下降**，能挂 volume 就挂 volume。

---

## 八、治理清单：把写放大按死在设计阶段

1. **镜像不可变**：可变目录（日志、缓存、数据、临时文件）一律不放进镜像层。
2. **只读根文件系统**：`readOnlyRootFilesystem: true`，强制暴露「谁在偷偷写盘」。
3. **`/tmp` 用 tmpfs**：`--tmpfs /tmp:size=512m`，避免临时文件落盘 + 顺带提速。
4. **Dockerfile 避免 `chown -R`**：用 `COPY --chown`，只对新增文件生效。
5. **合并 RUN 指令**：减少层数不减少字节，但能减少层查找开销；真正省空间靠多阶段构建。
6. **大文件不预置**：基础镜像里别塞 JDK 源码包、历史日志、示例数据。
7. **监控可写层增长**：`docker ps -s` 或 kubelet 的 `container_fs_usage_bytes` 告警。
8. **容量预留**：`/var/lib/docker` 与业务数据盘分离，避免日志写满拖垮数据库。

---

## 九、踩坑实录

**坑 1：容器磁盘满但节点还有空间**
节点 500G，容器报 ENOSPC。原因是 Docker 的 `data-root` 单独挂了一块 50G 盘，容器可写层写满。`docker info | grep "Docker Root Dir"` 一看便知。

**坑 2：日志文件越滚越大，删了也不释放**
应用 `rm` 了日志文件但进程还持有 fd，空间不释放；在 overlayfs 上更麻烦，因为上层 whiteout 与下层原文件同时存在，`du` 和 `df` 会对不上。用 `lsof +L1` 找 deleted 文件。

**坑 3：`mv` 目录导致启动卡 3 分钟**
启动脚本 `mv /data /data.bak`，`/data` 在镜像层有 8 万个小文件，递归 copy-up。改成挂 volume 后启动 4 秒。

**坑 4：容器内存 2.5G 但堆只有 1G**
page cache 双份 + JVM 堆外。看 `memory.stat` 的 `file` 与 `anon` 分离，`file` 高不是泄漏。

**坑 5：`fsync` 变慢导致 Kafka 消费延迟**
Kafka 容器把 `log.dirs` 放在可写层，副本写入触发 copy-up + 与镜像层同盘的 IO 竞争。必须挂 local volume。

---

## 十、面试追问

**Q1：overlayfs 的 copy-up 什么时候触发？**
A：任何会修改下层文件内容或元数据的操作：`open` 写模式、`truncate`、`chmod`、`chown`、`setxattr`、`rename`。删除不复制，而是创建 whiteout。

**Q2：为什么容器里删了文件，磁盘空间没释放？**
A：删除只是在上层建 whiteout，下层文件仍在；如果进程还持有 fd，inode 也不会释放。另外 whiteout 本身占少量空间。

**Q3：overlayfs 的写放大怎么算？**
A：写放大 ≈（镜像层文件大小 + 业务写入量）/ 业务写入量。所以对「已存在的大文件」做小修改，放大倍数可以是几万倍。

**Q4：为什么容器 page cache 会双份？**
A：copy-up 产生了新的 upper inode，page cache 按 inode 记账，旧 lower inode 的缓存不会立刻失效，两份都被 cgroup 计入 file 页。

**Q5：怎么判断容器慢是存储问题？**
A：看 `io.pressure` 的 `full`、`io.stat` 的 `wbytes` 与业务写入量比值、`docker ps -s` 的可写层增长、以及 `bpftrace` 抓 `ovl_copy_up_one`。

**Q6：为什么 rootless 容器更慢？**
A：常用 `fuse-overlayfs`，文件操作走用户态 FUSE，每次 syscall 多两次上下文切换；小文件密集场景开销可达 2 倍以上。

---

## 总结

overlayfs 的设计目标是「镜像分层复用 + 快速启动」，它把「写」的代价转移到了第一次修改上。这个代价在无状态服务里几乎无感，但在**日志、缓存、数据库、临时文件**这四类写入面前会被无限放大。

工程上的解法不是调参，而是**布局**：让可变数据离开可写层。想清楚这一点，容器里的 ENOSPC、启动慢、内存翻倍，大半都能提前避免。

下一篇换个方向，讲数据库代理层：ProxySQL / MySQL Router 如何解决连接数爆炸，以及「连接复用」在事务和 session 变量面前为什么会变成事故。
