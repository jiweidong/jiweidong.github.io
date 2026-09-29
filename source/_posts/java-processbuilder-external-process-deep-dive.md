---
title: 【Java 实战】ProcessBuilder 与 Runtime.exec 深度解析：外部进程调用、流死锁与超时治理
date: 2026-09-29 08:00:00
tags:
  - Java
  - IO
  - 生产实战
categories:
  - Java
  - 基础进阶
author: 东哥
---

# 【Java 实战】ProcessBuilder 与 Runtime.exec 深度解析：外部进程调用、流死锁与超时治理

## 面试官：Java 调用外部命令有几种方式？

很多人第一反应是 `Runtime.getRuntime().exec("ls -l")`。再问「`exec` 和 `ProcessBuilder` 有什么区别？为什么生产上大量用 `exec` 的服务会莫名卡死？」——这个问题能筛掉一大半人。

`Process` 这一块是 Java 里典型的「API 看起来简单、坑深到能埋人」的领域。本文从进程创建、IO 模型讲到流死锁、超时治理、环境变量、退出码与信号，最后给一套可以直接抄的生产级封装。

## 一、`Runtime.exec` vs `ProcessBuilder`：不是「新旧」，是「控制力」

`Runtime.exec` 是 JDK 1.0 的产物，`ProcessBuilder` 在 JDK 1.5 引入。两者最终都落到 `ProcessImpl`，但入口能力差别很大：

| 维度 | `Runtime.exec` | `ProcessBuilder` |
| --- | --- | --- |
| 命令与参数 | 字符串会被 `StringTokenizer` 按空白拆分 | 显式传入 `List<String>`，不拆分 |
| 工作目录 | 不支持 | `directory(File)` |
| 环境变量 | 只能全量替换 `String[] envp` | `environment()` 可增量修改 |
| 错误流合并 | 需 `ProcessBuilder` 或手动读 | `redirectErrorStream(true)` |
| 重定向 | 无 | `redirectOutput/Input/Error`、`Redirect.to()` |
| 推荐度 | 遗留，仅简单场景 | 现代首选 |

### 3 个最常见的 `exec` 坑

**坑 1：参数含空格被拆散。**

```java
// 错误：路径 "/tmp/my file.txt" 会被拆成两个参数
Runtime.getRuntime().exec("cp /tmp/my file.txt /backup/");

// 正确：显式传数组
Runtime.getRuntime().exec(new String[]{"cp", "/tmp/my file.txt", "/backup/"});

// 或者用 ProcessBuilder
new ProcessBuilder("cp", "/tmp/my file.txt", "/backup/").start();
```

**坑 2：shell 元字符不生效。**

`exec("ls *.java")` 里的 `*.java` 不会被 shell 展开，因为它根本没经过 shell。想用管道、通配符、`&&`，必须显式调用 shell：

```java
// Linux/macOS
new ProcessBuilder("/bin/sh", "-c", "ps -ef | grep java | wc -l").start();

// Windows
new ProcessBuilder("cmd.exe", "/c", "dir | findstr java").start();
```

**坑 3：`exec` 不做转义，存在命令注入风险。**

如果命令里拼了用户输入，就是标准的命令注入漏洞。生产上**永远不要拼字符串**，要么用参数数组，要么对输入做白名单校验。

## 二、最致命的坑：管道缓冲区死锁

这是生产事故里出现频率最高的一个。看这段经典代码：

```java
// ☠️ 典型的死锁代码
Process p = new ProcessBuilder("some-long-output-command").start();
int code = p.waitFor();               // 等待进程结束
String out = new String(p.getInputStream().readAllBytes()); // 进程结束后才读
System.out.println(code + out);
```

**为什么会死锁？** 子进程的标准输出流是一个操作系统管道，容量有限（Linux 默认 64KB）。当子进程输出超过这个容量：

1. 子进程写管道阻塞，等着父进程读；
2. 父进程在 `waitFor()` 阻塞，等着子进程退出；
3. 双方互等 → 死锁。

**正确做法：必须并发消费输出流。** 最稳的姿势是「启动读取线程 / 或用 `redirectErrorStream` + 异步读取」。

```java
public static ProcessResult run(List<String> command, Duration timeout, File dir) throws Exception {
    ProcessBuilder pb = new ProcessBuilder(command)
            .directory(dir)
            // 把 stderr 合并到 stdout，避免两个流都要读却只读了一个
            .redirectErrorStream(true);

    Process process = pb.start();

    // 关键：立刻异步把输出抽干，防止管道写满阻塞子进程
    StringBuilder output = new StringBuilder();
    Thread reader = new Thread(() -> {
        try (BufferedReader br = new BufferedReader(
                new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = br.readLine()) != null) {
                output.append(line).append('\n');
            }
        } catch (IOException ignored) {
            // 进程被强杀时流会抛异常，正常现象
        }
    }, "proc-reader");
    reader.setDaemon(true);
    reader.start();

    boolean finished = process.waitFor(timeout.toMillis(), TimeUnit.MILLISECONDS);
    if (!finished) {
        process.destroy();                       // 发 SIGTERM
        if (!process.waitFor(2, TimeUnit.SECONDS)) {
            process.destroyForcibly();           // 发 SIGKILL
        }
        reader.join(1000);
        return new ProcessResult(-1, output.toString(), true);
    }
    reader.join(1000);
    return new ProcessResult(process.exitValue(), output.toString(), false);
}

record ProcessResult(int exitCode, String output, boolean timedOut) {}
```

### 为什么 `redirectErrorStream(true)` 这么重要？

如果不合并，你有两个流要读。只读 `stdout`、不管 `stderr`，那么当子进程往 stderr 写满 64KB 时，同样会阻塞。很多「偶发卡死」都是这么来的——只有在报错多的时候才复现。

## 三、超时治理：Java 8 没有 `waitFor(Duration)`

`waitFor(long, TimeUnit)` 是 JDK 8 才有的；更早的版本只能手动开线程。另外几个必须注意的点：

1. **超时后必须 `destroyForcibly()`。** `destroy()` 发的是 SIGTERM，被调进程可能装了信号处理器、或者根本还在阻塞，不会退出。
2. **强制杀进程不会关闭流。** 你依然要 `close()` 流，并 `join` 读取线程，否则可能残留线程。
3. **`Process.isAlive()` / `exitValue()` 的语义。** `exitValue()` 在进程未结束时抛 `IllegalThreadStateException`，别在没 `waitFor` 前调用。
4. **`ProcessHandle`（JDK 9+）是更好的替代。**

```java
Process p = new ProcessBuilder("sleep", "300").start();
ProcessHandle h = p.toHandle();
h.onExit().thenAccept(ph -> System.out.println("exit=" + ph.exitValue()));
System.out.println("alive=" + h.isAlive() + " pid=" + h.pid());
h.descendants().forEach(ph -> System.out.println("子进程: " + ph.pid()));
h.destroyForcibly();
```

`ProcessHandle.descendants()` 在排查「子进程变成孤儿」时特别有用：杀掉父进程不会自动杀掉它 fork 出来的孙子进程。

## 四、环境变量：`environment()` 是「修改」不是「替换」

这是 `ProcessBuilder` 相对 `exec` 最实用的改进之一：

```java
ProcessBuilder pb = new ProcessBuilder("my-script.sh");
pb.environment().put("JAVA_HOME", "/opt/jdk21");   // 在继承的父进程环境上叠加
pb.environment().remove("LD_PRELOAD");
```

而 `Runtime.exec(cmd, envp)` 语义是「**用 envp 完全替换**」环境变量——传了不完整的环境，脚本可能因为找不到 `PATH` 直接失败。这个差异导致很多从 `exec` 迁到 `ProcessBuilder` 的人反而「变正常了」。

另一个必知陷阱：**PATH 解析**。`ProcessBuilder("mycmd")` 依赖父进程 PATH，容器里 PATH 常常和你想的不一样。生产建议 **写绝对路径**，或者启动时显式 `environment().put("PATH", ...)`。

## 五、退出码与「看起来成功但其实失败」

`exitCode == 0` 是唯一可靠的「成功」信号——但要注意：

- **shell 的 `-c` 会吞掉真实退出码？** 不会，`sh -c 'cmd'` 会正确返回 `cmd` 的退出码，但如果命令串是 `cmd1 | cmd2`，返回的是**最后一个**命令的退出码（除非开 `pipefail`）。
- **`waitFor` 返回不代表流读完了。** 子进程退出后，管道里可能还有数据，必须等读取线程 `join` 完成。
- **`exitCode` 为 137 通常是被 SIGKILL（OOM Killer）**，143 是 SIGTERM。这些在容器里排查 OOM 时非常有用：

```java
int code = p.exitValue();
// 128 + signal 的约定：128+9=137(SIGKILL/OOM), 128+15=143(SIGTERM)
if (code == 137) {
    log.error("子进程被 SIGKILL，常见原因是容器内存超限（OOMKilled）");
}
```

## 六、输入流与交互式进程

需要给子进程喂数据时，`getOutputStream()` 是写入端（命名反直觉）：

```java
Process p = new ProcessBuilder("grep", "ERROR").start();
try (BufferedWriter w = new BufferedWriter(
        new OutputStreamWriter(p.getOutputStream(), StandardCharsets.UTF_8))) {
    w.write("INFO ok\n");
    w.write("ERROR boom\n");
}
// 关闭输入流 = 给 grep 发 EOF，它才会结束
String out = new String(p.getInputStream().readAllBytes());
p.waitFor();
```

**必须关闭 `getOutputStream()`**，否则子进程（如 `grep`、`sort`）会一直等输入，永不退出。

更优雅的做法是用 `redirectInput(File)` 直接重定向文件，完全绕开手写流的麻烦。

## 七、重定向：让 IO 交给内核

`ProcessBuilder.Redirect` 能把子进程的 IO 直接指向文件，既省内存又避免死锁：

```java
File log = new File("/var/log/task.log");
ProcessBuilder pb = new ProcessBuilder("long-task.sh")
        .redirectOutput(Redirect.appendTo(log))   // stdout -> 文件追加
        .redirectErrorStream(true)
        .redirectInput(Redirect.from(new File("/data/in.txt")));
Process p = pb.start();
```

注意 `Redirect.INHERIT` 会让子进程复用父进程的 fd——在容器里这会把输出打到 Java 进程自己的 stdout，日志可能和业务日志混在一起，慎用。

## 八、生产级封装要点清单

把上面的坑收拢成一份清单：

- ✅ 用 `ProcessBuilder` + **参数数组/List**，绝不拼字符串；
- ✅ 需要 shell 特性时显式 `/bin/sh -c`，并做输入白名单；
- ✅ **启动即异步读流**，或 `redirectOutput` 到文件；`redirectErrorStream(true)` 防 stderr 堵死；
- ✅ 超时用 `waitFor(timeout)` + `destroyForcibly()`，并 `join` 读取线程；
- ✅ 用 `ProcessHandle` 管理生命周期、看 `descendants()`；
- ✅ 命令用**绝对路径**，环境变量用 `environment()` 叠加；
- ✅ 用退出码判定结果，识别 137/143 的信号语义；
- ✅ 并发调用要**限流**（信号量/线程池），避免 fork 风暴把机器打爆；
- ✅ 记录 `pid`、命令、耗时、退出码、输出摘要，便于复盘。

## 九、面试追问速答

**Q：`Process` 是线程安全的吗？**
不是。多个线程同时操作同一个 `Process` 的流会互相干扰。要并发就各管各的流。

**Q：子进程会继承父进程的文件描述符吗？**
默认继承，`ProcessBuilder` 里可以用 `Redirect` 精细控制。继承 fd 是容器里「句柄泄漏」的常见来源。

**Q：为什么杀掉进程后 `getInputStream()` 还会抛异常？**
`destroyForcibly()` 关掉了管道写端，读取端 `read()` 会立刻返回 -1 或抛 `IOException: Stream closed`，读线程里要 catch 掉。

**Q：Linux 下和 Windows 下的差异？**
Windows 没有 POSIX 信号，`destroy()` 会调用 `TerminateProcess`（相当于强杀），SIGTERM/SIGKILL 的区分在 Windows 上不成立；命令解析与 PATH 规则也不同。跨平台代码要把命令构造抽象出来。

**Q：容器里 fork 进程要注意什么？**
注意 PID 1 的僵尸进程回收、`--pids-limit`、以及 seccomp 对 `clone/fork` 的限制。Java 进程作为 PID 1 时不会自动 reap 孤儿进程，需自行处理。

## 十、小结

`ProcessBuilder` 的知识密度不高，但「流死锁」和「超时后不清理」这两个点，每年都在生产事故复盘里出现。记住一句话就够了：**启动进程后，第一件事是把它的输出抽干，第二件事是给它一个确定的死期。**
