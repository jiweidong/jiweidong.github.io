---
title: 【生产实战】发布期 502/504 全链路归因：Nginx upstream、Tomcat 队列、readiness 与流量排空
date: 2026-11-22 08:10:00
tags:
  - Java
  - Nginx
  - Kubernetes
  - 微服务
  - 故障排查
categories:
  - 生产实战
author: 东哥
---

# 【生产实战】发布期 502/504 全链路归因

## 前言

很多团队都有这样的经历：平时系统稳如老狗，一到发布就零星报错。监控上看到一小段 502/504，持续 30 秒到 2 分钟，发布完成后自动恢复。因为「时间短、能自愈」，往往被当成正常现象记进发布须知。

但从用户视角，这几十秒就是**下单失败、支付中断、页面白屏**。而且这类问题的根因分布很广：Nginx 连接复用、Tomcat 接受队列、K8s 探针、注册中心摘除延迟、优雅停机顺序……任何一环配错都会复现。

这篇文章按**请求链路**逐跳拆解 502/504，给出可落地的配置基线和排查命令。

---

## 一、先搞清 502 和 504 是谁返回的

| 状态码 | 语义 | 常见返回方 |
|---|---|---|
| 502 Bad Gateway | 上游返回了非法响应 / 连接被重置 / 无法建连 | Nginx、网关 |
| 504 Gateway Timeout | 上游在超时时间内没有返回 | Nginx、网关 |
| 499 | 客户端主动断开（Nginx 自定义） | Nginx |
| 503 | 服务不可用 / 队列满 | Tomcat、网关、应用 |

排查第一步永远是看**谁写的这条日志**。如果是 Nginx 的 `error.log`：

```
upstream prematurely closed connection while reading response header from upstream
connect() failed (111: Connection refused) while connecting to upstream
upstream timed out (110: Connection timed out) while reading response header
```

三句话对应三种根因：**上游主动关闭**（停机/崩溃）、**连不上**（端口没起/被摘除）、**读超时**（处理太慢）。

---

## 二、发布期 502 的经典时间线

以 K8s 滚动发布为例，一次「教科书级」的错误顺序：

```
T+0s   Deployment 更新，新 Pod 启动
T+3s   readiness 探针第一次成功 → Endpoints 加入新 Pod
T+5s   旧 Pod 收到 SIGTERM
T+5s   Spring Boot 开始优雅停机，Tomcat 停止接受新连接
T+8s   Nginx 仍持有到旧 Pod 的 keepalive 连接，直接复用
T+8s   → 502 upstream prematurely closed connection
T+30s  Endpoints 才真正摘除旧 Pod（kube-proxy/Ingress 同步延迟）
```

核心矛盾：**流量摘除的速度，赶不上进程关闭的速度**。

- K8s 的 Endpoints 更新是异步的，Ingress Controller / kube-proxy / 服务网格各有自己的同步周期；
- Nginx 的 `upstream keepalive` 会缓存空闲连接，后端关闭后这些连接变成「半死」；
- Spring Boot 优雅停机默认只等 `spring.lifecycle.timeout-per-shutdown-phase=30s`，但**不会等外部负载均衡器更新**。

### 2.1 正确顺序：先摘流量，再停进程

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 15"]   # 给 Endpoints 同步留时间
terminationGracePeriodSeconds: 60
```

`preStop` 的 sleep 是「作弊但有效」的做法：让 Pod 在收到 SIGTERM 后先装死 15 秒，等所有流量平面都更新完，再真正关闭 Tomcat。生产上 10~20 秒是常见值。

### 2.2 Nginx 侧兜底

```nginx
upstream backend {
    server 10.0.0.11:8080 max_fails=3 fail_timeout=10s;
    server 10.0.0.12:8080 max_fails=3 fail_timeout=10s;
    keepalive 64;
    keepalive_timeout 60s;
    keepalive_requests 1000;
}

location / {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_next_upstream error timeout http_502 http_503;
    proxy_next_upstream_tries 2;
    proxy_connect_timeout 1s;
    proxy_send_timeout 5s;
    proxy_read_timeout 10s;
}
```

注意几个高频坑：

1. **`keepalive` 必须配 `proxy_http_version 1.1` 和 `Connection ""`**，否则长连接不生效，每请求都新建 TCP；
2. `proxy_next_upstream` 里加 `http_502` 能让 Nginx 自动重试下一个节点，但**非幂等请求要慎重**；
3. `max_fails` 只在 `fail_timeout` 内累计，别指望它瞬间摘除故障节点。

---

## 三、504 的两个完全不同的原因

504 不一定是「业务慢」，也可能是「根本没轮到执行」。

### 3.1 上游处理慢

```
upstream timed out (110: Connection timed out) while reading response header from upstream
```

说明连接建立了、请求发出去了，但对端在 `proxy_read_timeout` 内没返回响应头。此时要查：

- 应用线程池是否打满（请求在队列里排队）；
- 下游依赖是否变慢；
- 是否有大查询/大文件/慢接口。

### 3.2 连接排队（更隐蔽）

Tomcat 的 `maxConnections`（NIO 默认 8192）和 `acceptCount`（默认 100）决定了「能同时持有多少连接」和「内核队列多长」。当连接数超过 `maxConnections`，新连接进入 `acceptCount` 队列；队列满后，内核直接拒绝或丢弃 SYN。

表现为：`curl` 有时通有时不通，Nginx 侧是 `connect() failed (111)` 或超时。**这时候应用日志里什么都没有**，因为请求根本没进来。

```yaml
server:
  tomcat:
    threads:
      max: 200
      min-spare: 20
    accept-count: 200
    max-connections: 8192
    connection-timeout: 5s
```

同时检查内核：

```bash
sysctl net.core.somaxconn        # 建议 >= accept-count
sysctl net.ipv4.tcp_max_syn_backlog
ss -lnt | grep 8080              # Recv-Q 持续 > 0 说明队列堆积
```

`ss -lnt` 的 `Recv-Q` 是判断 accept 队列是否打满的最快手段：持续非 0 且增长，就是应用 accept 不过来。

---

## 四、探针配置：最常见的「发布期抖动」来源

```yaml
startupProbe:           # 启动慢的应用必须有，避免 liveness 误杀
  httpGet: { path: /actuator/health/liveness, port: 8080 }
  failureThreshold: 30
  periodSeconds: 2
livenessProbe:
  httpGet: { path: /actuator/health/liveness, port: 8080 }
  initialDelaySeconds: 20
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /actuator/health/readiness, port: 8080 }
  periodSeconds: 5
  failureThreshold: 2
```

三个高频错误：

1. **liveness 和 readiness 用同一个健康检查**。数据库短暂抖动导致 readiness 失败是合理的（摘流量），但如果 liveness 也失败，Pod 会被**重启**，把小故障放大成大故障。
2. **没有 startupProbe**。Spring 应用启动 40 秒，liveness 的 `initialDelaySeconds: 10` 会在启动期直接杀 Pod，形成 `CrashLoopBackOff`。
3. **readiness 检查太重**。探针里查数据库、查 Redis、调下游，探针本身成了压垮系统的最后一根稻草。readiness 应该只反映「本进程能否接流量」。

Spring Boot 3 需要显式开启：

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
  health:
    livenessstate:
      enabled: true
    readinessstate:
      enabled: true
```

---

## 五、优雅停机的完整链路

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 25s
```

收到 SIGTERM 后，Spring Boot 会：

1. 停止接受新请求（Tomcat connector pause）；
2. 等待正在处理的请求完成（最多 25 秒）；
3. 关闭线程池、数据源、Kafka consumer 等资源。

但有几个「等不到」的坑：

- **异步任务**：`@Async` 线程池不在优雅停机范围内，需要自己 `executor.shutdown()` + `awaitTermination`；
- **Kafka 消费者**：默认可能提交了 offset 但业务没处理完，需要 `AckMode.MANUAL` + 停机钩子；
- **定时任务**：`@Scheduled` 正在跑的长任务会被直接打断；
- **长连接/SSE**：需要主动发送关闭事件，让客户端重连。

一个可复用的停机钩子：

```java
@Component
public class GracefulShutdownHook implements ApplicationListener<ContextClosedEvent> {
    private final ThreadPoolTaskExecutor bizExecutor;

    @Override
    public void onApplicationEvent(ContextClosedEvent event) {
        bizExecutor.shutdown();
        try {
            if (!bizExecutor.getThreadPoolExecutor()
                    .awaitTermination(20, TimeUnit.SECONDS)) {
                log.warn("biz executor did not terminate in 20s, forcing shutdown");
                bizExecutor.getThreadPoolExecutor().shutdownNow();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
```

---

## 六、一张排查决策表

| 现象 | 优先怀疑 | 验证方式 |
|---|---|---|
| 502 集中在发布后 30s 内 | 流量未排空 / keepalive 复用 | 对比发布时间与错误时间；看 Nginx error.log |
| 502 持续到发布结束 | 端口未就绪 / 探针过早通过 | 看 Pod 事件、readiness 时间 |
| 504 偶发且 RT 分布长尾 | 线程池排队 | 看 `http_server_requests` P99、线程池队列 |
| 504 伴随 `Recv-Q` 增长 | accept 队列满 | `ss -lnt`、`netstat -s` 的 listen 段 |
| 502 与 504 混合 | 节点被摘除但连接未断 | 检查 preStop、`terminationGracePeriodSeconds` |
| 只有部分节点报错 | 单节点资源问题 | 对比节点 CPU/内存/连接数 |

常用命令：

```bash
# Nginx 上游状态
curl -s http://127.0.0.1/nginx_status
# 连接状态分布
ss -s
# 内核丢包/溢出
netstat -s | grep -E "listen|overflow|retransmit"
# K8s 事件
kubectl get events --sort-by=.lastTimestamp | tail -30
```

---

## 七、面试追问

**Q：为什么发布时总有一小段 502，怎么彻底消除？**

本质是「摘流量」和「停进程」的竞态。彻底消除需要三件事：preStop 延迟让流量平面先更新、Nginx 对 502 做幂等重试、应用优雅停机等待在途请求。三者缺一不可，只做其中一个都还会有零星错误。

**Q：502 和 504 哪个更严重？**

504 通常更严重，说明上游还活着但处理不过来，往往是容量或慢依赖问题；502 更多是连接层问题（进程重启、端口未就绪），通常是瞬时的。但 502 如果持续，说明服务真的挂了。

**Q：`proxy_next_upstream` 能解决所有 502 吗？**

不能。它只对「连接失败/读失败」且**请求可重放**的场景有效。POST 请求重放可能造成重复下单，必须配合幂等键。另外流式响应（SSE）一旦开始写响应头就无法重试。

**Q：K8s 的 readiness 和 Nginx 的健康检查是什么关系？**

两层独立机制。readiness 决定 Pod 是否在 Endpoints 里，Nginx 的 `max_fails` 决定它自己的节点池是否剔除。两者同步周期不同，所以会出现「K8s 认为健康、Nginx 认为故障」的窗口期。

---

## 八、总结

1. 502/504 先定位「谁返回的」，再看「哪一跳断的」。
2. 发布期 502 的根因是竞态：**先摘流量，再停进程**，preStop 延迟是必要成本。
3. 504 要区分「处理慢」和「没排上队」，`ss -lnt` 的 Recv-Q 是最快判据。
4. 探针要分 liveness/readiness/startup 三种，别让健康检查变成故障放大器。
5. 优雅停机要覆盖异步线程池、MQ 消费者、定时任务和长连接，不能只配一个 `shutdown: graceful`。

发布不是「把新代码放上去」，而是一次有严格顺序的流量迁移。把这些细节写进发布 checklist，比事后复盘一百次都管用。
