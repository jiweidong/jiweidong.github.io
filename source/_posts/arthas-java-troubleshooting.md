---
title: Java在线诊断利器：Arthas实战指南
date: 2026-06-17 08:00:00
author: 东哥
categories:
  - Java
  - 运维
tags:
  - Arthas
  - Java诊断
  - 性能优化
  - 在线调试
cover: /images/arthas-banner.png
---

## 一、引言

在生产环境遇到 Java 应用 CPU 飙升、内存泄漏、响应缓慢的问题时，传统的排查手段往往捉襟见肘——线上环境不能随意重启，不能加断点，日志打印又不够精细。阿里巴巴开源的 **Arthas**（阿尔萨斯）正是为解决这一痛点而生。

Arthas 是一款 Java 在线诊断工具，它采用 Java Agent 技术动态附着到目标 JVM 进程上，无需修改应用代码、无需重启服务，即可实时观测方法调用、查看参数和返回值、监控线程状态、甚至热更新代码。本文将带你从安装到进阶，全面掌握 Arthas 的核心能力。

## 二、安装与启动

### 2.1 快速安装

Arthas 支持多种安装方式，最常用的是通过 `curl` 一键下载：

```bash
# 方式一：一键安装脚本（推荐）
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar

# 方式二：通过 as.sh 脚本
curl -L https://arthas.aliyun.com/install.sh | sh
./as.sh

# 方式三：Docker 环境
docker exec -it <container_id> /bin/bash
curl -O https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar
```

启动后，Arthas 会列出当前系统中的 Java 进程，输入序号即可选择目标进程附着。

### 2.2 启动参数说明

```bash
# 指定目标 PID
java -jar arthas-boot.jar <PID>

# 指定监听端口（默认 3658）
java -jar arthas-boot.jar --telnet-port 9999 --http-port 9998

# 非交互模式（执行单条命令后退出）
java -jar arthas-boot.jar <PID> -c "dashboard -n 1"

# 以脚本方式执行命令文件
java -jar arthas-boot.jar <PID> -f /tmp/commands.txt
```

### 2.3 退出与卸载

```bash
# 退出当前 Arthas 会话
exit
quit

# 停止 Arthas 服务端（会卸载 Agent）
stop
```

## 三、基础诊断命令

### 3.1 dashboard — 实时系统面板

`dashboard` 是 Arthas 最直观的命令，提供 JVM 的实时运行概览：

```bash
# 查看实时面板（默认每5秒刷新一次）
dashboard

# 指定刷新间隔和次数
dashboard -i 2000 -n 5
```

输出包含三大板块：

| 板块 | 内容 | 关键作用 |
|------|------|----------|
| 线程信息 | 线程名称、状态、CPU 时间、负载 | 快速定位高 CPU 线程 |
| 内存信息 | 堆/非堆使用量、GC 次数、GC 耗时 | 判断内存压力 |
| 运行时信息 | 系统负载、进程信息、JVM 参数 | 宏观性能基线 |

**实战案例**：CPU 飙升时，先运行 `dashboard`，观察哪些线程 CPU 占用最高，然后使用 `thread` 命令进一步分析。

### 3.2 thread — 线程诊断

```bash
# 查看所有线程信息
thread

# 查看最繁忙的 N 个线程（按 CPU 使用率排序）
thread -n 5

# 查看指定线程的堆栈
thread <thread_id>

# 查看当前阻塞的线程
thread -b
```

`thread -b` 特别适合死锁检测，它会自动找出当前正在阻塞其他线程的锁持有者：

```bash
# 示例输出
"http-nio-8080-exec-10" Id=42 BLOCKED on java.util.HashMap@123456
    at com.example.service.OrderService.createOrder(OrderService.java:120)
    - waiting to lock <0x000000076b5f6a98> (a java.util.HashMap)
```

### 3.3 jvm — JVM 信息查看

```bash
# 查看 JVM 详细信息
jvm
```

输出涵盖：JVM 版本、启动参数、类加载统计、编译器信息、内存管理、操作系统信息等。特别适合在迁移或升级后验证 JVM 参数是否生效。

### 3.4 memory — 内存使用详情

```bash
# 查看内存各区域使用情况
memory
```

| 区域 | 说明 | 监控要点 |
|------|------|----------|
| heap | 堆内存总量 | 总体使用率 |
| eden | 新生代 Eden 区 | Minor GC 频率 |
| survivor | 幸存者区 | 对象晋升情况 |
| old | 老年代 | Full GC 触发阈值 |
| metaspace | 元空间 | 类加载泄漏 |
| code_cache | 代码缓存 | JIT 编译压力 |

## 四、方法观测能力

### 4.1 watch — 方法观测

`watch` 可以观测方法调用的入参、返回值、异常等信息，是 Arthas 最常用的命令之一：

```bash
# 简单观测方法返回值
watch com.example.service.OrderService createOrder

# 观测入参和返回值（-x 指定展开深度）
watch com.example.service.OrderService createOrder "{params,returnObj}" -x 3

# 条件过滤：只观测特定条件的方法调用
watch com.example.service.OrderService createOrder "{params,returnObj}" "params[0].amount > 1000"

# 观测异常情况
watch com.example.service.OrderService createOrder "{params,throwExp}" -e

# 观测方法执行耗时
watch com.example.service.OrderService createOrder "{params,returnObj,throwExp,cost}" "#cost>100"
```

**watch 表达式中的变量**：

| 变量 | 含义 |
|------|------|
| params | 方法入参数组 |
| returnObj | 返回值 |
| throwExp | 异常对象 |
| target | 当前对象（this） |
| clazz | 当前类 |
| method | 当前方法 |
| cost | 执行耗时（毫秒） |

### 4.2 trace — 方法调用链路

`trace` 可以追踪方法内部的所有子调用及其耗时，是性能瓶颈分析的利器：

```bash
# 追踪方法内部调用链路
trace com.example.service.OrderService createOrder

# 限制追踪深度
trace com.example.service.OrderService createOrder -n 3

# 只追踪耗时超过 100ms 的调用
trace com.example.service.OrderService createOrder "#cost > 100"

# 跳过 jdk 内部类
trace --skipJDKMethod false com.example.service.OrderService createOrder
```

**实战案例**：某接口响应缓慢，trace 后发现 90% 的时间花在 `UserService.validateUser()` 中的一次数据库查询上，进而定位到缺少索引的问题。

```bash
trace com.example.controller.UserController getUserInfo
`---ts=2026-06-17 10:23:45;thread_name=http-nio-8080-exec-3;id=42;is_daemon=true;priority=5;
    `---[1802.34ms] com.example.controller.UserController:getUserInfo()
        `---[1800.12ms] com.example.service.UserService:validateUser()
            `---[1789.45ms] com.example.dao.UserMapper:selectByPrimaryKey()
```

### 4.3 stack — 方法调用栈

`stack` 输出当前方法的完整调用栈，适合排查"这个方法从哪里被调用"：

```bash
# 查看方法被调用的堆栈
stack com.example.service.OrderService createOrder

# 条件过滤
stack com.example.service.OrderService createOrder "params[0].userId==1001"
```

### 4.4 monitor — 方法调用监控

`monitor` 对方法进行周期性的调用统计：

```bash
# 每 5 秒输出一次统计
monitor com.example.service.OrderService createOrder -c 5
```

输出示例：

```
monitor com.example.service.PaymentService pay
Press Ctrl+C to abort.
Affect(class count:1, method count:1) cost in 68 ms, listenerId:1

 timestamp            class                              method   total   success  fail   avg-rt(ms)  fail-rate
-------------------------------------------------------------------------------------------------------------------
 2026-06-17 10:30:00  com.example.service.PaymentService  pay      120     118      2      45.23       1.67%
```

### 4.5 tt — TimeTunnel 时空隧道

`tt` 可以记录方法的历史调用数据，并支持回放，相当于给方法调用装上了 DVR：

```bash
# 记录方法调用
tt -t com.example.service.OrderService createOrder

# 查看历史记录
tt -l

# 查看某次调用的详细参数和返回值
tt -i 1001

# 重新执行某次调用
tt -i 1001 -p

# 重新执行并修改参数
tt -i 1001 -p "params[0].setAmount(500)"
```

## 五、类与对象诊断

### 5.1 sc — 查看 JVM 中加载的类

```bash
# 模糊搜索类
sc com.example.service.*

# 查看类详细信息（包括类加载器、注解等）
sc -d com.example.service.OrderService

# 查看类字段信息
sc -d -f com.example.service.OrderService
```

### 5.2 sm — 查看类中加载的方法

```bash
# 查看类的所有方法
sm com.example.service.OrderService

# 查看指定方法详细信息
sm -d com.example.service.OrderService createOrder
```

### 5.3 OGNL 表达式

OGNL（Object-Graph Navigation Language）是 Arthas 的杀手级特性，可以直接调用对象方法、修改字段值：

```bash
# 获取静态字段值
ognl "@com.example.config.AppConfig@timeout"

# 调用静态方法
ognl "@java.lang.System@getProperty('java.version')"

# 获取 Spring Bean 并调用方法
ognl "#context=@com.example.SpringContextUtil@getApplicationContext(), #bean=#context.getBean('userService'), #bean.getUser(1001)"

# 修改静态字段值
ognl "@com.example.config.AppConfig@timeout=5000"
```

**实战场景**：生产环境的配置中心挂了，通过 OGNL 直接修改 Bean 中的超时配置，临时恢复服务。

```bash
# 获取 Spring 容器中的配置 Bean
ognl "#bean=@com.example.ApplicationContextProvider@getBean('orderConfig'), #bean.setTimeout(30000), #bean"
```

## 六、热更新与诊断

### 6.1 redefine — 类的热替换

```bash
# 将编译好的 class 文件替换到 JVM 中
redefine /tmp/OrderService.class

# 输出：redefine success, size: 1
```

### 6.2 retransform — 增强版热更新

`retransform` 比 `redefine` 更强大，支持对已增强的类进行还原：

```bash
# 重转换类
retransform /tmp/OrderService.class

# 查看重转换的类列表
retransform -l

# 删除指定重转换
retransform -d 123456

# 删除所有重转换，恢复原始类
retransform --deleteAll
```

| 特性 | redefine | retransform |
|------|----------|-------------|
| 支持还原 | ❌ | ✅ |
| 支持多个 class | ✅ | ✅ |
| 与 watch 共存 | ❌ 会清除增强 | ✅ 保留增强 |
| 推荐使用 | 紧急修复 | 日常诊断 |

**实战案例**：线上发现某个日志打印了敏感信息，临时修改代码去掉日志后，编译 class 文件热替换：

```bash
# 1. 修改 Java 源码，去掉敏感日志
# 2. 编译为 class
javac -cp $(java -jar arthas-boot.jar --classpath) -d /tmp /tmp/OrderService.java
# 3. 热替换
retransform /tmp/com/example/service/OrderService.class
```

### 6.3 vmtool — 虚拟机工具

Arthas 3.5+ 新增的 `vmtool` 可以通过表达式获取对象引用：

```bash
# 获取 Spring 容器中的 Bean
vmtool --action getInstances --className org.springframework.context.ApplicationContext

# 调用实例方法
vmtool --action getInstances --className com.example.service.OrderService \
  --express "instances[0].getOrder('ORD20260617001')"
```

## 七、性能分析：Profiler 火焰图

`profiler` 命令基于 async-profiler 生成 CPU 或内存的火焰图，是定位性能瓶颈的终极武器。

### 7.1 CPU 性能分析

```bash
# 启动 CPU 采样（默认 10 秒）
profiler start

# 等待一段时间后停止并生成火焰图
profiler stop --format html

# 指定采样时间（单位：秒）
profiler start --duration 30

# 指定事件类型
profiler start --event alloc  # 内存分配采样
profiler start --event lock   # 锁竞争采样
profiler start --event cache-misses  # CPU 缓存未命中
```

### 7.2 火焰图解读

火焰图生成的 HTML 文件默认存放在 `/tmp/arthas-output/` 目录，可通过 HTTP 访问。

```bash
# 查看生成的火焰图文件列表
profiler list

# 在浏览器中查看（Arthas 默认 HTTP 端口 8563）
# http://<host>:8563/arthas-output/
```

火焰图的解读原则：

- **X 轴**：表示调用栈的宽度（即采样出现的频次），越宽说明该路径消耗资源越多
- **Y 轴**：表示调用栈深度，顶部是实际执行的方法
- **颜色**：非业务代码（橙/红）通常是 JDK 或框架内部调用
- **关注点**：顶层宽条 + 业务代码包名 → 优化目标

### 7.3 生成 SVG 格式

```bash
# 生成 SVG 火焰图
profiler stop --format svg --file /tmp/flamegraph.svg
```

## 八、WebConsole 远程连接

Arthas 支持通过浏览器远程连接，摆脱 SSH 限制。

### 8.1 服务端配置

在目标服务器启动 Arthas 时，指定 HTTP 端口（默认 8563）：

```bash
java -jar arthas-boot.jar --http-port 8563
# 或配置为 0.0.0.0 以允许外部访问
java -jar arthas-boot.jar --target-ip 0.0.0.0
```

### 8.2 客户端访问

浏览器打开 `http://<服务器IP>:8563`，在 WebConsole 页面中：

1. 输入 IP 和端口（默认 127.0.0.1:3658）
2. 点击 Connect
3. 即可在浏览器中使用 Arthas 所有命令

> ⚠️ **安全警告**：WebConsole 应配合防火墙或 Nginx 反向代理使用，切勿直接暴露到公网。

### 8.3 Nginx 反向代理配置

```nginx
server {
    listen 443 ssl;
    server_name arthas.example.com;
    
    location / {
        proxy_pass http://127.0.0.1:8563;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

## 九、生产环境安全使用规范

### 9.1 权限控制

```bash
# 只允许本地访问 Telnet 端口
java -jar arthas-boot.jar --target-ip 127.0.0.1

# 限制可执行的命令（白名单模式）
# 在 arthas.properties 中配置
arthas.command.whitelist=dashboard,thread,jvm,memory,watch,trace
```

### 9.2 操作规范

| 原则 | 说明 |
|------|------|
| 最小权限 | 只附着目标进程，不附着同一 JVM 的其他无关进程 |
| 只读优先 | 先用 dashboard/thread/jvm 排查，慎用 redefine/retransform |
| 限时使用 | 诊断完成后及时退出，避免常驻 Agent 影响性能 |
| 观测限频 | watch -n 限制次数，避免大量输出拖垮应用 |
| 日志审计 | 关键操作记录到操作日志，方便追溯 |

### 9.3 动态开关

生产环境中可以配合开关服务，确保 Arthas Agent 可按需启用：

```bash
# 通过脚本动态判断是否开启 Arthas
if curl -s http://config-center/arthas-enabled | grep -q "true"; then
    java -jar arthas-boot.jar $PID
fi
```

## 十、综合实战案例

### 案例：定位高 CPU 线程

**场景**：线上告警 CPU 使用率持续 90%+，应用响应超时。

**排查步骤**：

```bash
# Step 1: 附着到目标进程
java -jar arthas-boot.jar 12345

# Step 2: 查看实时面板，找到 CPU 最高的线程
dashboard
# 观察到 thread ID=67 的线程 CPU 占用 45%

# Step 3: 查看线程堆栈
thread 67
# 发现卡在 com.example.processor.DataProcessor:process()
```

**问题代码**：

```java
public class DataProcessor {
    public void process(List<Data> dataList) {
        // 问题：无界循环中频繁创建 StringBuilder，触发 GC
        for (Data data : dataList) {
            String json = data.toJson();
            // ... 处理逻辑
        }
    }
}
```

**进一步验证**：

```bash
# 使用 trace 追踪方法
trace com.example.processor.DataProcessor process

# 使用 profiler 采样
profiler start --duration 20
profiler stop --format html
```

火焰图清晰显示 `StringBuilder.toString()` 占用大量 CPU。最终优化方案：采用 `StringWriter` 批量处理。

## 十一、最佳实践总结

Arthas 作为 Java 在线诊断的神兵利器，掌握了它就能在生产环境中游刃有余地排查各种疑难杂症。核心工作流如下：

```
问题发现 → dashboard 宏观监控 → thread 线程分析
  ↓
trace 方法链路 → watch 参数返回值
  ↓
ognl 对象探查 → profiler 火焰图 → 定位根因
  ↓
热修复（retransform） → 验证 → 下线恢复
```

**建议**：在日常开发和测试环境中就多使用 Arthas，熟悉它的命令体系和输出格式，这样在生产环境中才能做到冷静应对、精准出手。

## 十二、参考资料

- Arthas 官方文档：<https://arthas.aliyun.com/doc/>
- Arthas GitHub：<https://github.com/alibaba/arthas>
- async-profiler：<https://github.com/jvm-profiling-tools/async-profiler>
