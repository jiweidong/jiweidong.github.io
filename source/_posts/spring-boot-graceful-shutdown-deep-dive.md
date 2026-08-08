---
title: 【Spring Boot 实战】优雅停机深度解析：从 kill 命令到 Graceful Shutdown 平滑下线
date: 2026-08-08 08:00:00
tags:
  - Spring Boot
  - 优雅停机
  - 生命周期
  - 生产实践
  - 面试
categories:
  - Spring Boot
  - 生产实践
author: 东哥
---

# 【Spring Boot 实战】优雅停机深度解析：从 kill 命令到 Graceful Shutdown 平滑下线

## 面试官：线上发版直接 kill -9 进程，会有什么问题？

很多人发版时的流程是：找到 PID → `kill -9` → 启动新包。运气好没事，运气不好就会出现：

- **正在处理的请求被中断**：用户下单到一半，接口 502；
- **数据不一致**：写入数据库一半的事务回滚，或者消息队列里的消息处理一半就丢了；
- **注册中心感知延迟**：服务还在被调用方请求，进程却已经没了。

本文从 Linux 信号机制讲起，完整梳理 Spring Boot 优雅停机的原理与配置，让"发版无感"成为标配。

<!-- more -->

## 一、先搞清楚：kill 到底在干什么？

### 1.1 信号与默认行为

`kill <pid>` 本质是向进程发送信号。常用信号：

| 信号 | 数值 | 默认行为 | 进程能否捕获 |
| --- | --- | --- | --- |
| SIGTERM | 15 | 终止进程 | **能**（可优雅处理） |
| SIGKILL | 9 | 立即杀死 | **不能**（内核直接回收） |
| SIGHUP | 1 | 挂断（终端断开） | 能 |
| SIGINT | 2 | Ctrl+C | 能 |

**关键结论**：
- `kill -9`（SIGKILL）无法被任何业务代码拦截，进程瞬间消失，**不可能优雅**；
- `kill`（默认 SIGTERM）可以被 JVM 和框架捕获，从而走"收尾流程"。

### 1.2 JVM 的 Shutdown Hook

JVM 收到 SIGTERM 后（以及 `System.exit()`、最后一个非守护线程结束时），会执行 **Shutdown Hook**（`Runtime.addShutdownHook` 注册的回调）：

```
SIGTERM → JVM 启动 shutdown 序列
        → ① 停止接收新任务
        → ② 执行所有 Shutdown Hook（并发执行，顺序不保证）
        → ③ 触发 finalizer、停止非守护线程
        → ④ JVM 退出
```

Spring Boot 的优雅停机正是基于这个机制实现的。

## 二、Spring Boot 优雅停机配置

### 2.1 最小配置（Spring Boot 2.3+）

```yaml
# application.yml
server:
  shutdown: graceful    # 优雅停机（默认 immediate 直接关闭）

spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s   # 每阶段最大等待时间
```

就这么两行。配置后，收到 SIGTERM 时 Spring Boot 会：

1. **停止接收新请求**：Web 容器（Tomcat/Netty）不再 accept 新连接；
2. **等待处理中的请求完成**：最多等 `timeout-per-shutdown-phase`；
3. 超时后强制关闭；
4. 依次执行 Bean 的销毁方法（`@PreDestroy`）、关闭线程池、释放资源。

### 2.2 三大主流容器的行为

| 容器 | 优雅停机行为 |
| --- | --- |
| **Tomcat** | 停止接收新连接，等待已接收请求处理完，连接超时后关闭（`connectionTimeout` 控制） |
| **Netty（WebFlux）** | 停止接收新事件，等待在途请求完成 |
| **Undertow** | 类似 Tomcat，支持 graceful shutdown |

### 2.3 验证优雅停机是否生效

```bash
# 1. 启动应用
java -jar app.jar &
# 2. 压测中发送 SIGTERM（不是 -9！）
kill -TERM <pid>
# 3. 观察日志：出现类似
# "Commencing graceful shutdown. Waiting for active requests to complete"
# "Graceful shutdown complete"
```

**注意**：Spring Boot 3.x 中，`server.shutdown=graceful` 只对 Web 容器生效，**业务线程池、MQ 消费者、定时任务**不会自动等待，需要自己处理（见下文）。

## 三、进阶：让停机真正"优雅"的五大收尾动作

只配两行配置远远不够。一个生产级应用在停机时应该完成：

### 3.1 ① 业务线程池平滑关闭

```java
@Configuration
public class ThreadPoolConfig {

    @Bean("bizExecutor")
    public ThreadPoolExecutor bizExecutor() {
        return new ThreadPoolExecutor(
            8, 16, 60, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(1000),
            new ThreadFactoryBuilder().setNameFormat("biz-pool-%d").build(),
            new ThreadPoolExecutor.CallerRunsPolicy());
    }
}

// 停机时等待队列任务处理完
@Component
public class GracefulShutdownListener {

    @Resource(name = "bizExecutor")
    private ThreadPoolExecutor executor;

    @PreDestroy
    public void shutdown() {
        executor.shutdown();   // 不再接受新任务
        try {
            // 等待存量任务完成，最多 30s
            if (!executor.awaitTermination(30, TimeUnit.SECONDS)) {
                executor.shutdownNow();  // 超时强杀
            }
        } catch (InterruptedException e) {
            executor.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }
}
```

### 3.2 ② 从注册中心摘除流量

优雅停机前，先把实例从服务注册中心（Nacos/Eureka）**摘除或标记下线**，让调用方不再路由新流量：

```yaml
# Spring Cloud 场景：停机时自动注销
spring:
  cloud:
    service-registry:
      auto-registration:
        fail-fast: true
```

```java
// 手动摘除示例（Nacos）
@Component
public class DeregisterOnShutdown {
    @PreDestroy
    public void deregister() {
        // 调用 Nacos OpenAPI 注销实例
        namingService.deregisterInstance(serviceName, ip, port);
        // 等待 2~3 个心跳周期（默认 5s），让调用方感知
        try { Thread.sleep(3000); } catch (InterruptedException ignored) {}
    }
}
```

> **为什么摘除后还要等几秒？** 注册中心的健康检查有延迟，调用方本地缓存的实例列表不会立刻更新。立刻杀进程，摘除动作等于白做。

### 3.3 ③ 消息消费者暂停拉取

```java
@Component
public class MqConsumerLifecycle {
    // Kafka 消费者示例
    @PreDestroy
    public void pauseAndClose() {
        consumer.pause(consumer.assignment());  // 暂停拉取新消息
        consumer.close(Duration.ofSeconds(30)); // 等待处理完再关闭
    }
    // 注意：配合 enable.auto.commit=false + 手动提交，
    // 处理完一批再提交 offset，才不会丢消息
}
```

**核心原则**：先暂停拉取，再等存量消息处理完，最后提交 offset 并关闭。否则重启后会重复消费或丢失消息。

### 3.4 ④ 释放外部资源与状态同步

- 数据库连接池：`HikariDataSource.close()`（Spring 容器销毁时自动处理）；
- Redis/缓存连接：`@PreDestroy` 中关闭；
- 分布式锁：停机前**主动释放**持有的锁（避免锁超时前的空窗期）；
- 本地缓存落盘：把内存中的待写数据 flush 到磁盘或 MQ。

### 3.5 ⑤ 健康检查与就绪探针配合（K8s 场景）

在 Kubernetes 中，优雅停机与探针配合是关键：

```yaml
# deployment.yaml
spec:
  terminationGracePeriodSeconds: 60   # 给足优雅停机时间
  containers:
    - name: app
      readinessProbe:                 # 就绪探针：false 时摘除 Service 流量
        httpGet:
          path: /actuator/health/readiness
          port: 8080
```

```
K8s 滚动更新流程：
1. 新 Pod 启动并就绪
2. 旧 Pod 的 readiness 探针失败 → 从 Service Endpoints 摘除
3. K8s 向旧 Pod 发送 SIGTERM → Spring Boot 优雅停机
4. 等待 terminationGracePeriodSeconds 后若未退出，发送 SIGKILL
```

**注意**：K8s 默认在探针失败和 SIGTERM 之间存在时间差，生产上建议在 `preStop` 钩子里加一个短暂 sleep，给流量摘除留出时间：

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]
```

## 四、完整停机时序图

```
            收到 SIGTERM
                │
                ▼
┌─────────────────────────────────────────────┐
│ ① 注册中心摘除实例（主动注销 + 等待感知）      │
│ ② Web 容器停止接收新请求（server.shutdown）   │
│ ③ 暂停 MQ 消费者拉取 / 停止定时任务调度        │
│ ④ 等待在途请求完成（timeout-per-shutdown）    │
│ ⑤ 业务线程池 shutdown + awaitTermination     │
│ ⑥ @PreDestroy 钩子：释放锁、落盘、关连接      │
│ ⑦ 容器销毁 → 连接池关闭 → JVM 退出            │
└─────────────────────────────────────────────┘
   超时兜底：任意一步超时 → shutdownNow / SIGKILL
```

## 五、常见坑与最佳实践

### 5.1 坑 1：用了 kill -9

运维脚本、CI/CD 里用了 `kill -9` 或 `docker stop` 不带超时——一切优雅停机配置全部失效。**规范：部署脚本一律 `kill`（SIGTERM）**，docker 的 `STOPSIGNAL SIGTERM` 是默认值，但 `docker stop -t 0` 等于立刻 SIGKILL。

### 5.2 坑 2：优雅停机超时设置太短

```yaml
spring:
  lifecycle:
    timeout-per-shutdown-phase: 5s   # ❌ 大流量下在途请求根本处理不完
```

根据业务 P99 耗时 × 队列深度估算，通常 **30s~60s** 起步。

### 5.3 坑 3：只配了 server.shutdown，没管业务线程池

Tomcat 停了，但异步线程池里的任务还在跑——进程退出时这些线程被强杀，任务丢失。**所有自建线程池都要实现关闭逻辑**。

### 5.4 坑 4：@PreDestroy 里做耗时操作

`@PreDestroy` 里 sleep、远程调用容易拖垮整体停机时间。原则：**摘除流量类动作放最前，本地快速清理放最后**，耗时操作设超时。

### 5.5 最佳实践清单

| 项 | 建议 |
| --- | --- |
| 停机信号 | 一律 SIGTERM，禁止脚本用 -9 |
| 配置 | `server.shutdown: graceful` + 30s+ 超时 |
| 线程池 | 全部 shutdown + awaitTermination |
| 注册中心 | 停机前摘除 + 等待 2~3 个心跳周期 |
| MQ | 暂停拉取 → 处理存量 → 手动提交 offset |
| K8s | readiness 探针 + preStop sleep + terminationGracePeriodSeconds |
| 验证 | 压测中发 SIGTERM，确认请求无失败、日志完整 |

## 六、总结

优雅停机的本质是**给"在途工作"一个体面的结局**：不再接新活，把手头的活干完，再体面退场。技术栈上就是三层配合：

1. **OS/JVM 层**：SIGTERM 可捕获，SIGKILL 不可——所以先保证不发 -9；
2. **框架层**：`server.shutdown: graceful` 让 Web 容器停止接收新请求并等待在途请求；
3. **业务层**：线程池、MQ、注册中心、分布式锁，每一个都需要显式的收尾逻辑。

下次发版，别再 `kill -9` 了。配上优雅停机，你的服务就能做到"零感知发布"——这也是一名 Java 工程师从"能跑"走向"专业"的重要一步。
