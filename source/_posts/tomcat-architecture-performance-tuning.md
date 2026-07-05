---
title: Apache Tomcat 架构原理与性能调优：从连接器到容器全解析
date: 2026-07-05 08:00:00
tags:
  - Java
  - Tomcat
  - Web服务器
  - 性能调优
categories:
  - Java
  - 中间件
author: 东哥
---

# Apache Tomcat 架构原理与性能调优：从连接器到容器全解析

## 一、引言

Tomcat 作为 Java Web 领域最经典的 Servlet 容器，几乎所有 Java 后端开发都接触过。但真正理解它的架构设计和调优策略的人却不多。很多开发者只是把它当作一个"启动 jar 包跑就行"的东西，碰上了性能瓶颈就一筹莫展。

本文将带你深入 Tomcat 核心架构，搞懂：
- Tomcat 到底是怎么处理一个 HTTP 请求的？
- 线程模型是如何演进的？
- 生产环境如何命中最佳配置？

## 二、Tomcat 整体架构

### 2.1 架构分层

Tomcat 的核心由两大组件构成：

```
Tomcat Server
  └── Service
       ├── Connector（连接器）— 处理网络通信
       │    ├── ProtocolHandler
       │    │    ├── Endpoint（底层 I/O 实现）
       │    │    └── Processor（协议解析）
       │    └── Adapter（适配器，匹配到容器）
       │
       └── Container（Servlet 容器）— 处理请求
            ├── Engine（引擎）
            ├── Host（虚拟主机）
            ├── Context（Web 应用上下文）
            └── Wrapper（Servlet 包装器）
```

**核心职责**：
- **Connector**：监听端口、接受 TCP 连接、解析 HTTP 协议、生成 Request/Response 对象
- **Container**：管理 Servlet 生命周期、路由到指定 Servlet 执行业务逻辑

### 2.2 一次完整请求流程

```
Client → Connector(Endpoint → Processor → Adapter)
                                      ↓
                               Engine → Host → Context → Wrapper → Servlet
                                      ↓
                             返回 Response ← 逐级返回
```

1. **Endpoint** 监听端口，接收 Socket 连接
2. **Processor** 将 Socket 字节流解析为 `Request` 对象
3. **Adapter** 将 `Request` 传递给 `Engine`（适配 Servlet 规范）
4. **Engine** 根据 Host 匹配 → **Host** 根据 Context 路径匹配 → **Context** 根据 URL 匹配 **Wrapper**（Servlet）
5. Servlet 执行 `service()` 方法，业务处理
6. 响应沿原路返回，经 Processor 写出到 Socket

## 三、线程模型演进：BIO → NIO → NIO2 → APR

### 3.1 对比总览

| 模型 | 协议 | JDK 版本 | 连接处理 | 适用场景 |
|------|------|---------|---------|---------|
| BIO | HTTP/1.1 | 1.4+ | 一线程一连接 | 低并发、长连接少 |
| NIO | HTTP/1.1 | 1.4+ | 多路复用（Selector） | 高并发长连接 |
| NIO2 | HTTP/1.1 | 7+ | AIO 异步 I/O | 大并发 + 大文件 |
| APR | HTTP/1.1 | 7+ | 原生 C 库（OpenSSL） | 高性能 + TLS 卸载 |

### 3.2 NIO 模式（最常用）线程模型

Tomcat 8.5+ 默认使用 NIO 模式，其线程模型如下：

```
Acceptor 线程（1个）→ Poller 线程（默认2个）→ Worker 线程池
    │                    │                       │
    │ 接收 TCP 连接      │ 检测 I/O 事件        │ 执行业务逻辑
    │ 注册到 Poller      │ 读取/写入数据        │ Servlet.service()
```

**关键组件**：

**Acceptor**：负责接收客户端 TCP 连接（`ServerSocketChannel.accept()`），将连接注册到 Poller 的 Selector 上。

**Poller**：维护一个 Selector，轮询 I/O 就绪事件。当检测到数据可读时，将任务提交给 Worker 线程池处理。

**Worker 线程池**：执行实际的业务逻辑（Servlet、Filter 等）。默认 `maxThreads=200`。

### 3.3 源码层面验证

```java
// NioEndpoint 核心源码（Tomcat 9）
public class NioEndpoint extends AbstractJsseEndpoint<NioChannel,NioSocketWrapper> {
    
    // Acceptor
    protected class Acceptor extends AbstractEndpoint.Acceptor {
        @Override
        public void run() {
            while (running) {
                SocketChannel socket = serverSock.accept();
                setSocketOptions(socket);
                // 传递给 Poller
                poller.register(socket);
            }
        }
    }
    
    // Poller
    public class Poller implements Runnable {
        private Selector selector;
        
        @Override
        public void run() {
            while (running) {
                selector.select(selectorTimeout);
                Iterator<SelectionKey> iterator = selector.selectedKeys().iterator();
                while (iterator.hasNext()) {
                    SelectionKey key = iterator.next();
                    // 处理读/写事件
                    processKey(key);
                }
            }
        }
    }
}
```

## 四、关键配置参数详解

### 4.1 核心连接器配置（server.xml）

```xml
<Connector port="8080" 
           protocol="org.apache.coyote.http11.Http11NioProtocol"
           maxThreads="400"
           minSpareThreads="40"
           acceptCount="500"
           maxConnections="10000"
           connectionTimeout="20000"
           maxKeepAliveRequests="100"
           disableUploadTimeout="true"
           compression="on"
           compressionMinSize="2048"
           compressableMimeType="text/html,text/xml,text/plain,text/css,text/javascript,application/json" />
```

| 参数 | 默认值 | 说明 | 建议 |
|------|--------|------|------|
| `maxThreads` | 200 | 最大工作线程数 | 根据 CPU 核数 × 2~4 倍设置 |
| `minSpareThreads` | 10 | 最小空闲线程数 | 峰值 QPS 高时提高此值 |
| `acceptCount` | 100 | 等待队列最大长度 | 处理不过来时缓冲请求 |
| `maxConnections` | 10000 | 最大连接数 | NIO/NIO2 下控制并发连接上限 |
| `connectionTimeout` | 20000 | 连接超时(ms) | 短连接场景可适当减小 |
| `maxKeepAliveRequests` | 100 | Keep-Alive 最大请求数 | 防长时间占用连接 |

### 4.2 Executor 线程池配置

```xml
<Executor name="tomcatThreadPool" 
          namePrefix="catalina-exec-"
          maxThreads="400"
          minSpareThreads="40"
          maxIdleTime="60000"
          prestartminSpareThreads="true" />

<Connector executor="tomcatThreadPool"
           port="8080"
           protocol="org.apache.coyote.http11.Http11NioProtocol" />
```

## 五、生产环境最佳实践

### 5.1 线程数计算公式

```
最佳线程数 = (CPU 核数 × 2) / (1 - 阻塞系数)
```

- **纯计算型**（阻塞系数 ≈ 0）：线程数 ≈ CPU 核数 × 2
- **IO 密集型**（阻塞系数 ≈ 0.8~0.9）：线程数 = CPU 核数 × (10~20)

公式推导自利特尔法则：`QPS = 工作线程数 / 平均响应时间`

### 5.2 JVM 层调优

```
# catalina.sh 中添加
JAVA_OPTS="-Xms4g -Xmx4g -XX:+UseG1GC 
           -XX:MaxGCPauseMillis=200 
           -XX:+ParallelRefProcEnabled 
           -XX:+DisableExplicitGC
           -Djava.awt.headless=true"
```

### 5.3 常见优化手段

**① 启用 NIO2 提升大文件传输**

```xml
<Connector protocol="org.apache.coyote.http11.Http11Nio2Protocol" ... />
```

**② 开启静态文件缓存**

```xml
<Resources cachingAllowed="true" cacheMaxSize="102400" />
```

**③ 禁用访问日志（非必须）**

```xml
<Valve className="org.apache.catalina.valves.AccessLogValve" 
       enabled="false" />
```

**④ 使用 Sendfile 加速静态文件**

```xml
<Connector useSendfile="true" ... />
```

## 六、常见问题与排障

### 6.1 问题：Connection Timeout / 请求排队超时

**现象**：客户端大量 502/504，Tomcat 日志出现 "Connection timeout"

**排查步骤**：
1. `jstack PID | grep "http-nio"` 查看工作线程状态
2. 检查线程数是否达到 `maxThreads`
3. 检查 `acceptCount` 是否过小导致连接被拒绝
4. 检查业务服务的 RT（响应时间）

**解决方法**：
- 增大 `maxThreads` 和 `acceptCount`
- 优化业务逻辑缩短响应时间
- 水平扩展增加 Tomcat 实例

### 6.2 问题：OutOfMemoryError

**现象**：频繁 FGC、OOM

**排查**：
- 使用 `jstat -gcutil PID 1000` 监控 GC
- 使用 `jmap -dump:format=b,file=heap.hprof PID` 分析堆

**解决方法**：
- 检查最大线程数是否过大（每个线程默认栈 1MB）
- 增加堆内存
- 开启 `-XX:+HeapDumpOnOutOfMemoryError`

## 七、Tomcat 10 的变化

Tomcat 10 最主要的变化是将 `javax.servlet` 迁移到 `jakarta.servlet`：

| 版本 | Servlet 包名 | Spring Boot 支持 |
|------|-------------|------------------|
| Tomcat 9 | `javax.servlet.*` | Spring Boot 2.x |
| Tomcat 10 | `jakarta.servlet.*` | Spring Boot 3.x+ |

从 Tomcat 9 升级到 10 需要同步更新所有依赖中的 Servlet API 引用。

## 八、面试高频题

### Q：Tomcat 中为什么要分 Acceptor、Poller、Worker 三类线程？

> 职责分离 + 性能优化。Acceptor 只做连接接收，快速把连接交给 Poller；Poller 利用 Selector 多路复用检测 I/O 事件，避免阻塞；Worker 执行业务逻辑。三者各自专注，互不阻塞，最大化吞吐。

### Q：Tomcat NIO 模式下，一个线程可以处理多个连接吗？

> 可以。Poller 线程通过 Selector 管理数千个连接，只在 I/O 就绪时才派发 Worker 处理。Worker 处理期间其他连接不受影响。

### Q：maxConnections 和 maxThreads 的关系是什么？

> `maxConnections` 控制连接池上限，超过的连接会被等待或拒绝；`maxThreads` 控制同时处理请求的工作线程数。工作线程不够时，已建立的连接也会排队等待。通常 `maxConnections > maxThreads`。

## 九、总结

Tomcat 作为 Servlet 标准最经典的实现，其架构设计对理解 Java Web 运行的底层机制至关重要。理解 Connector/Container 分离、二阶段线程模型（Acceptor-Poller-Worker）以及核心调优参数背后的原理，才能在生产环境中自如地诊断和优化性能问题。

记住一句话：**Tomcat 不是随便配个端口就能跑的东西。它是最接近你代码的第一层基础设施，理解它就是理解你的 Web 应用如何工作。**
