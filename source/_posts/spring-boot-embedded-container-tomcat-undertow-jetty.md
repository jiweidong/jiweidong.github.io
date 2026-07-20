---
title: Spring Boot 内嵌容器（Tomcat/Undertow/Jetty）选型与深度配置实战
date: 2026-07-20 08:00:00
tags:
  - Spring Boot
  - Tomcat
  - Undertow
  - Jetty
  - 性能优化
categories:
  - Spring Boot
  - 容器与部署
author: 东哥
---

# Spring Boot 内嵌容器（Tomcat/Undertow/Jetty）选型与深度配置实战

## 一、为什么需要了解内嵌容器？

Spring Boot 的一大特色就是 **内嵌容器**（Embedded Container），它让应用可以直接执行 `java -jar` 启动，不再需要预先安装和配置独立的 Tomcat 或 Jetty 服务器。

但目前 Spring Boot 支持三种内嵌容器：

| 容器 | Starter 依赖 | 默认 WebServer |
|---|---|---|
| **Tomcat** | `spring-boot-starter-tomcat` | **默认 Web starter** |
| **Undertow** | `spring-boot-starter-undertow` | 需排除 Tomcat |
| **Jetty** | `spring-boot-starter-jetty` | 需排除 Tomcat |

`spring-boot-starter-web` 默认引入 Tomcat。如果要用 Undertow 或 Jetty，需要在 Maven 中排除 Tomcat 并添加对应 starter：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
    <exclusions>
        <exclusion>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-tomcat</artifactId>
        </exclusion>
    </exclusions>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-undertow</artifactId>
</dependency>
```

## 二、三大容器核心特性对比

### 2.1 概述对比

| 特性 | Tomcat | Undertow | Jetty |
|---|---|---|---|
| **开发方** | Apache 软件基金会 | JBoss（Red Hat） | Eclipse 基金会 |
| **最初版本** | 1999 年 | 2013 年 | 1995 年 |
| **Java EE 规范** | Java Servlet、JSP、WebSocket | Java Servlet、WebSocket | Java Servlet、JSP、WebSocket |
| **编程模型** | 阻塞 IO（BIO）/ NIO | **纯 NIO（XNIO 框架）** | NIO |
| **默认 IO 模型** | NIO2（JDK 8+） | NIO（XNIO） | NIO |
| **HTTP/2 支持** | 是（Tomcat 8.5+） | 是 | 是 |
| **SPDY 支持** | 是（已废弃） | 否 | 是 |
| **Servlet 版本** | 6.0（Tomcat 10.1+） | 6.0 | 6.0 |
| **连接数上限** | 数千（默认 200） | **数万（轻量级）** | 数千 |
| **JSP 支持** | ✅ 原生 | ❌ 需额外配置 | ✅ 原生 |
| **Spring Boot 默认** | ✅ 是 | ❌ | ❌ |

### 2.2 性能对比（基准测试参考）

以下是基于 Spring Boot 3.x 的简单 HTTP 接口压测数据（仅供参考，实际数据因机器配置而异）：

```
场景：GET 接口，返回 JSON，并发 500 连接，压测 60 秒
机器：4C8G，JDK 17

                  Tomcat 10.1    Undertow 2.x    Jetty 12
吞吐量 (req/s)      ≈ 18,000       ≈ 22,000       ≈ 16,000
P99 延迟 (ms)        ≈ 45           ≈ 32           ≈ 52
内存占用 (MB)        ≈ 180          ≈ 145          ≈ 195
启动时间 (s)         ≈ 3.5          ≈ 3.0          ≈ 3.8
```

**解读**：
- **Undertow** 在吞吐量和延迟方面通常略胜一筹，内存占用更优
- **Tomcat** 生态最成熟、兼容性最好
- **Jetty** 在嵌入式场景中可定制性最强

## 三、Tomcat 深度配置

### 3.1 默认配置

Spring Boot 为 Tomcat 提供了一系列自动配置类：

```java
// 核心自动配置类
org.springframework.boot.autoconfigure.web.servlet.ServletWebServerFactoryAutoConfiguration
org.springframework.boot.autoconfigure.web.embedded.TomcatWebServerFactoryCustomizer
```

### 3.2 application.yml 配置

```yaml
server:
  port: 8080
  tomcat:
    # 最大连接数（已连接但尚未处理的连接数）
    max-connections: 10000
    # 最大线程数
    threads:
      max: 200
      min-spare: 10
    # 连接超时时间（毫秒）
    connection-timeout: 20000
    # 请求体最大大小
    max-swallow-size: 2MB
    # 请求头最大大小
    max-http-form-post-size: 2MB
    # URI 编码
    uri-encoding: UTF-8
    # 基于 Accept header 的重定向
    redirect-context-root: true
    # 访问日志
    accesslog:
      enabled: true
      directory: logs
      pattern: "%h %l %u %t \"%r\" %s %b %D"
    # 远程 IP 阀（用于反向代理获取真实 IP）
    remoteip:
      protocol-header: X-Forwarded-Proto
      remote-ip-header: X-Forwarded-For
```

### 3.3 自定义 TomcatConnectorCustomizer

```java
@Configuration
public class TomcatConfig {
    
    @Bean
    public TomcatConnectorCustomizer tomcatConnectorCustomizer() {
        return connector -> {
            // 设置协议处理器
            connector.setProperty("maxThreads", "400");
            connector.setProperty("minSpareThreads", "50");
            connector.setProperty("acceptCount", "200");
            
            // 启用 NIO2
            connector.setProperty("protocol", "org.apache.coyote.http11.Http11Nio2Protocol");
            
            // 配置连接器超时
            connector.setProperty("connectionTimeout", "30000");
            connector.setProperty("keepAliveTimeout", "60000");
            
            // 配置 Executor
            ThreadPoolExecutor executor = new ThreadPoolExecutor(
                50, 400, 60, TimeUnit.SECONDS,
                new LinkedBlockingQueue<>(1000)
            );
            connector.setExecutor(executor);
        };
    }
    
    @Bean
    public WebServerFactoryCustomizer<TomcatServletWebServerFactory> tomcatFactoryCustomizer() {
        return factory -> {
            // 添加错误页面
            factory.addErrorPages(new ErrorPage(HttpStatus.NOT_FOUND, "/404.html"));
            
            // 配置 SSL
            factory.addConnectorCustomizers(connector -> {
                connector.setSecure(true);
                connector.setScheme("https");
            });
        };
    }
}
```

### 3.4 Tomcat 性能优化 checklist

```java
@Component
public class TomcatOptimizer {
    
    // 优化连接器的 keepAlive 设置
    @Bean
    public TomcatConnectorCustomizer keepAliveOptimizer() {
        return connector -> {
            connector.setProperty("keepAliveTimeout", "30000"); // 30s
            connector.setProperty("maxKeepAliveRequests", "10000"); // 最大请求数
            connector.setProperty("soTimeout", "30000"); // Socket 超时
            connector.setProperty("socket.appReadBufSize", "16384"); // 读缓冲区
            connector.setProperty("socket.appWriteBufSize", "16384"); // 写缓冲区
            connector.setProperty("socket.bufferPool", "500");
        };
    }
    
    // 静态资源缓存
    @Bean
    public WebServerFactoryCustomizer<TomcatServletWebServerFactory> staticResourceOptimizer() {
        return factory -> factory.addContextCustomizers(context -> {
            context.setUsePrivateXConverters(true);
            context.setResources(new CacheEntryValuedResourceRoot(
                context.getResources(), 
                3600 // 缓存 1 小时
            ));
        });
    }
}
```

## 四、Undertow 深度配置

### 4.1 Undertow 的优势

Undertow 基于 JBoss 的 **XNIO** 框架，具有以下特点：

- **纯 NIO 架构**：没有阻塞 IO，资源效率极高
- **轻量级**：最小化内存占用
- **高性能**：在相同资源配置下通常高于 Tomcat
- **WebSocket 优化**：原生 WebSocket 支持，性能优秀

### 4.2 application.yml 配置

```yaml
server:
  port: 8080
  undertow:
    # IO 线程数（处理网络 IO，通常设置为 CPU 核数 * 2）
    io-threads: 8
    # 工作线程数（处理业务逻辑，通常为 IO 线程数 * 8）
    threads:
      worker: 64
    # 缓冲区配置
    buffer-size: 16384
    direct-buffers: true
    # 请求体最大大小
    max-http-post-size: 10MB
    # 访问日志
    accesslog:
      dir: logs
      enabled: true
      pattern: "%h %l %u %t \"%r\" %s %b %D"
      prefix: access
      suffix: log
    # HTTP/2 支持
    server-option:
      ENABLE_HTTP2: true
    # Socket 配置
    socket-option:
      BACKLOG: 1024
      REUSE_ADDRESSES: true
```

### 4.3 自定义 UndertowBuilderCustomizer

```java
@Configuration
public class UndertowConfig {

    @Bean
    public UndertowBuilderCustomizer undertowBuilderCustomizer() {
        return builder -> {
            // 配置 ServerOption
            builder.setServerOption(ServerOption.ENABLE_HTTP2, true);
            builder.setServerOption(ServerOption.MAX_HEADER_SIZE, 8 * 1024);
            builder.setServerOption(ServerOption.MAX_CONCURRENT_REQUESTS, 5000);
            
            // 配置 SocketOption
            builder.setSocketOption(Options.WORKER_IO_THREADS, 8);
            builder.setSocketOption(Options.WORKER_TASK_CORE_THREADS, 64);
            builder.setSocketOption(Options.WORKER_TASK_MAX_THREADS, 256);
            builder.setSocketOption(Options.CONNECTION_HIGH_WATER, 10000);
            builder.setSocketOption(Options.CONNECTION_LOW_WATER, 5000);
            
            // 添加 HttpHandler
            builder.addHttpHandler(new io.undertow.server.handlers.GracefulShutdownHandler());
        };
    }
    
    @Bean
    public WebServerFactoryCustomizer<UndertowServletWebServerFactory> undertowFactoryCustomizer() {
        return factory -> {
            // 添加 BuilderCustomizer
            factory.addBuilderCustomizers(builder -> {
                builder.setServerOption(ServerOption.RECORD_REQUEST_START_TIME, true);
            });
            
            // 添加错误页面
            factory.addErrorPages(new ErrorPage(HttpStatus.NOT_FOUND, "/404.html"));
        };
    }
}
```

### 4.4 Undertow 的 IO 线程模型

```
请求到达
    │
    ▼
┌─────────────┐
│  XNIO Worker │  ← 少量的 IO 线程（io-threads）
│  (NIO线程)   │     处理网络事件的读写
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   Worker    │  ← 工作线程（worker-threads）
│  ThreadPool │     执行业务 Handler
└─────────────┘
```

**配置建议**：
- `ioThreads = CPU核心数 * 2`
- `workerThreads = ioThreads * 8`
- `direct-buffers = true`（使用直接内存，减少 GC 压力）

## 五、Jetty 深度配置

### 5.1 Jetty 的优势

Jetty 的特色在于 **可定制性** 和 **模块化设计**：

- **模块化架构**：按需加载组件
- **细粒度配置**：可以对每个连接器、处理器进行精细配置
- **热部署友好**：开发环境体验好

### 5.2 application.yml 配置

```yaml
server:
  port: 8080
  jetty:
    # 线程池配置
    threads:
      acceptors: 4
      selectors: 8
      max: 200
      min: 10
      max-queue-capacity: 1000
    # 连接池配置
    connection-idle-timeout: 30000
    # 最大连接数
    max-connections: 10000
```

### 5.3 自定义 Jetty Connector

```java
@Configuration
public class JettyConfig {

    @Bean
    public WebServerFactoryCustomizer<JettyServletWebServerFactory> jettyFactoryCustomizer() {
        return factory -> {
            factory.addServerCustomizers(server -> {
                // 配置 QueuedThreadPool
                QueuedThreadPool threadPool = server.getBean(QueuedThreadPool.class);
                if (threadPool != null) {
                    threadPool.setMaxThreads(200);
                    threadPool.setMinThreads(10);
                    threadPool.setIdleTimeout(60000);
                }
            });
            
            factory.addConnectorCustomizers(connector -> {
                if (connector instanceof ServerConnector serverConnector) {
                    // 配置连接器参数
                    serverConnector.setAcceptQueueSize(1024);
                    serverConnector.setIdleTimeout(30000);
                    
                    // 配置 ConnectionFactory
                    HttpConnectionFactory http = serverConnector
                            .getConnectionFactory(HttpConnectionFactory.class);
                    if (http != null) {
                        http.getHttpConfiguration().setOutputBufferSize(32768);
                        http.getHttpConfiguration().setRequestHeaderSize(8192);
                        http.getHttpConfiguration().setResponseHeaderSize(8192);
                    }
                }
            });
        };
    }
    
    @Bean
    public JettyConnectionCustomizer jettyConnectionCustomizer() {
        return connector -> {
            // 配置 SSL/TLS 连接器
            if (connector instanceof ServerConnector serverConnector) {
                SslConnectionFactory ssl = serverConnector
                        .getConnectionFactory(SslConnectionFactory.class);
                if (ssl != null) {
                    SslContextFactory.Server sslContextFactory = 
                            (SslContextFactory.Server) ssl.getSslContextFactory();
                    sslContextFactory.setIncludeCipherSuites(
                            "TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384");
                }
            }
        };
    }
}
```

## 六、容器选型决策树

```
你的应用需要内嵌容器吗？
  ├─ 是 → 
  │    需要 JSP 吗？
  │      ├─ 是 → Tomcat ✅（默认支持最好）
  │      └─ 否 →
  │            需要极致性能/低内存？
  │              ├─ 是 → Undertow ✅
  │              └─ 否 → 继续
  │                    需要高度可定制/热部署？
  │                      ├─ 是 → Jetty ✅
  │                      └─ 否 → Tomcat ✅（生态最成熟）
  │
  └─ 否 → 使用独立部署（传统方式）
```

## 七、容器的编程式替换（Spring Boot 3.x）

在 Spring Boot 3.x 中，可以通过编程方式动态选择容器：

```java
@SpringBootApplication
public class DynamicContainerApplication {

    public static void main(String[] args) {
        SpringApplication app = new SpringApplication(DynamicContainerApplication.class);
        
        // 根据环境变量动态选择容器
        String container = System.getProperty("server.container", "tomcat");
        switch (container) {
            case "undertow" -> app.setWebApplicationType(WebApplicationType.SERVLET);
            case "jetty" -> app.setWebApplicationType(WebApplicationType.SERVLET);
            default -> app.setWebApplicationType(WebApplicationType.SERVLET);
        }
        
        app.run(args);
    }
}
```

## 八、常见性能调优对比

| 调优项 | Tomcat | Undertow | Jetty |
|---|---|---|---|
| 线程模型 | BIO/NIO/NIO2 可选 | 纯 NIO（XNIO） | NIO（Eclipse Jetty） |
| 连接器优化 | `maxConnections` + `maxThreads` | `io-threads` + `worker` | `acceptors` + `selectors` |
| 内存优化 | 调整 `maxSwallowSize` | 调整 `buffer-size` + `direct-buffers` | 调整 `outputBufferSize` |
| 优雅关闭 | `GracefulShutdown`（Spring Boot 2.3+） | `GracefulShutdownHandler` | `Graceful` 模式 |
| 访问日志 | 原生支持 | 原生支持 | 需额外配置 |

## 九、面试高频题

### Q1：Spring Boot 默认为什么选 Tomcat 而不是性能更好的 Undertow？

历史原因 + 生态成熟度。Tomcat 作为最老牌的 Servlet 容器，用户基数最大、文档最全、兼容性问题最少。对大多数应用来说，性能差异并不明显。

### Q2：Undertow 真的比 Tomcat 快吗？

在纯 IO 密集型场景中，Undertow 通常有 **10%-20%** 的性能优势。但对业务中带有数据库查询、RPC 调用的实际应用来说，性能差异基本可以忽略。选择合适的容器更重要的是看 **特性匹配** 而非单纯追求性能。

### Q3：内嵌容器和独立 Tomcat 部署的区别？

| 维度 | 内嵌容器 | 独立部署 |
|---|---|---|
| 部署方式 | `java -jar app.jar` | 放入 `webapps/` 目录 |
| 运维复杂度 | 低 | 中 |
| 资源利用率 | 高 | 一般 |
| 监控管理 | 通过 Actuator | 需额外配置 JMX |
| 热部署 | 支持（DevTools） | 支持（Manager App） |

### Q4：如何实现在同一个端口上同时支持 HTTP 和 HTTPS？

```yaml
server:
  port: 8080
  ssl:
    enabled: true
    key-store: classpath:keystore.p12
    key-store-password: password
  http2:
    enabled: true
  # Tomcat 会自动把 HTTP 重定向到 HTTPS
  tomcat:
    redirect-context-root: true
    remoteip:
      protocol-header: X-Forwarded-Proto
```

## 十、总结

| 容器 | 最佳适用场景 | 核心优势 |
|---|---|---|
| **Tomcat** | 通用场景、需要 JSP、生态成熟 | 兼容性最好、社区最活跃 |
| **Undertow** | 高并发 IO 密集型、微服务、容器化 | 性能最优、内存占用最小 |
| **Jetty** | 需要高度可定制、集成到其他框架 | 模块化设计、灵活度最高 |

了解 Spring Boot 内嵌容器的特性和配置方式，能够帮助你在不同场景下做出最合适的技术选型，并在遇到性能瓶颈时快速定位和优化。
