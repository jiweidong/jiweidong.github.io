---
title: ZooKeeper vs Etcd 分布式协调服务选型与实战
date: 2026-06-17 08:45:00
tags:
  - ZooKeeper
  - Etcd
  - 分布式协调
  - Raft
  - Paxos
  - 服务发现
categories:
  - 分布式
author: 东哥
---

# ZooKeeper vs Etcd 分布式协调服务选型与实战

## 一、前言

在微服务和云原生时代，分布式协调服务是构建可靠分布式系统的基石。从服务注册与发现、分布式锁、配置管理到领导者选举，几乎每个分布式系统都需要一个强一致性的协调组件来保证各节点协同工作。

目前业界最主流的两大分布式协调服务分别是 **Apache ZooKeeper** 和 **Etcd**。ZooKeeper 诞生于 2006 年，源自 Google Chubby 论文，是 Hadoop/大数据生态的标配；Etcd 诞生于 2013 年，由 CoreOS 团队开发，是云原生生态（Kubernetes、Cloud Foundry）的核心组件。

本文将从架构协议、一致性模型、性能对比、选型建议和实战代码等多个维度深度剖析两者的异同。

<!-- more -->

## 二、ZooKeeper 深度解析

### 2.1 ZooKeeper 整体架构

ZooKeeper 采用 **Leader-Follower** 架构，一个集群通常包含 3 或 5 个节点。节点角色如下：

| 角色 | 说明 |
|------|------|
| **Leader** | 负责处理所有写请求，通过 ZAB 协议保证事务顺序 |
| **Follower** | 处理读请求，参与 Leader 选举和投票 |
| **Observer** | 只处理读请求，不参与投票（水平扩展读能力） |
| **Learner** | 泛指 Follower + Observer |

### 2.2 ZAB 协议详解

ZooKeeper 的核心一致协议是 **ZAB（ZooKeeper Atomic Broadcast）**，这是一个类 Paxos 的原子广播协议。

ZAB 协议分为两个阶段：

**阶段一：崩溃恢复（Leader 选举）**

当 Leader 宕机或超过半数 Follower 断开时，集群进入崩溃恢复模式。选举算法基于 **Fast Leader Election**，每个节点投给数据最新的节点，得票过半即为新 Leader。

选举完成后，新 Leader 通过 **Epoch** 和 **ZXID**（ZooKeeper Transaction ID）对比来同步数据。ZXID 是一个 64 位数字，高 32 位代表 Epoch（Leader 任期），低 32 位是事务计数器。

```
ZXID = epoch << 32 | counter
```

**阶段二：消息广播**

Leader 接收写请求后，生成 Proposal 并广播给所有 Follower：

```
1. Leader 生成 Proposal + ZXID
2. Leader 广播 Proposal 到所有 Follower
3. Follower 写入事务日志并回复 ACK
4. Leader 收到过半 ACK → 提交（Commit）
5. Leader 广播 Commit 消息
6. Follower 在内存数据树上应用变更
```

### 2.3 ZooKeeper 数据模型

ZooKeeper 的数据模型是一个 **分层命名空间（类似文件系统树）**，每个节点称为 **ZNode**。

```
/
├── /services
│   ├── /services/user-service
│   │   ├── inst_001  → "192.168.1.10:8080" (临时节点)
│   │   └── inst_002  → "192.168.1.11:8080" (临时节点)
│   └── /services/order-service
├── /config
│   └── /config/app-config
└── /locks
    └── /locks/distributed-lock (顺序节点)
```

ZNode 有四种类型：

| 类型 | 持久性 | 特性 | 使用场景 |
|------|--------|------|----------|
| 持久节点 | 持久 | 直到显式删除 | 配置数据、元数据 |
| 临时节点 | 会话绑定 | 会话断开自动删除 | 服务实例注册 |
| 顺序节点 | 持久/临时 | 自动追加序号 | 分布式锁、Leader 选举 |
| Container 节点 | 持久 | 子节点为空自动删除 | 容器化管理 |

### 2.4 Watch 机制

ZooKeeper 提供了 **Watch** 机制，允许客户端监听 ZNode 的变化（创建、删除、数据变更、子节点变更）。Watch 是一次性的——触发后立即失效，需要重新注册才能继续监听。

```java
// Watch 注册示例
public class ZkWatcherExample {
    public static void main(String[] args) throws Exception {
        ZooKeeper zk = new ZooKeeper("localhost:2181", 3000, watchedEvent -> {
            System.out.println("收到事件: " + watchedEvent.getType());
        });

        // 注册一次性 Watch
        zk.getData("/config/db-url", 
            event -> System.out.println("数据变更: " + event.getPath()), 
            null);

        // 永久监听需要重新注册
        byte[] data = zk.getData("/config/db-url", 
            event -> {
                System.out.println("数据已变更，重新监听");
                try {
                    zk.getData("/config/db-url", this, null);
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }, 
            null);
        System.out.println("当前值: " + new String(data));
    }
}
```

> **注意事项**：Watch 是一次性的，如果接收到大量变更通知，需要每次触发后重新注册。Curator 框架提供了 `TreeCache`、`PathChildrenCache` 等高级监听器来简化永久监听。

## 三、Etcd 深度解析

### 3.1 Etcd 整体架构

Etcd 使用 **Raft 协议** 实现强一致性，核心组件包括：

| 组件 | 功能 |
|------|------|
| **Raft 模块** | 实现 Leader 选举、日志复制、安全性保证 |
| **MVCC 存储引擎** | 基于 BoltDB（Go 语言嵌入式 KV 数据库），支持多版本并发控制 |
| **gRPC API** | 对外暴露 v3 API，通过 gRPC 与服务端通信 |
| **Watch 模块** | 支持长轮询的事件监听，基于 gRPC Stream |
| **认证鉴权** | 支持 RBAC（基于角色的访问控制） |

### 3.2 Raft 协议核心原理

Raft 将一致性算法拆解为三个子问题：

**1. Leader 选举**

每个节点有三个状态：Follower、Candidate、Leader。

- Follower 在选举超时（150-300ms 随机）内未收到 Leader 心跳 → 变为 Candidate
- Candidate 自增 Term，发起投票请求（RequestVote RPC）
- 获得过半（quorum）投票 → 成为新 Leader
- Leader 定期发送心跳（AppendEntries RPC）维持权威

**2. 日志复制**

```
Client → Leader 提交写请求
    │
    ├─ 1. Leader 将日志条目追加到本地日志
    ├─ 2. Leader 并行向 Follower 发送 AppendEntries RPC
    ├─ 3. 过半 Follower 成功写入后 → 日志条目进入 Committed 状态
    ├─ 4. Leader 向客户端返回成功
    └─ 5. Leader 通知 Follower 应用日志到状态机
```

**3. 安全性保证**

- **Election Safety**：一个 Term 内最多选出一个 Leader
- **Leader Append-Only**：Leader 不会覆盖自己的日志
- **Log Matching**：两个日志条目的索引和 Term 相同 → 内容一定相同
- **Leader Completeness**：已提交的日志必定在新 Leader 中存在
- **State Machine Safety**：所有节点按相同顺序执行相同命令

### 3.3 MVCC 与事务

Etcd v3 引入了 **MVCC**，每次 Put 操作都会生成新的 Revision，旧版本数据不会被覆盖：

```
Key: /app/config
Revision 5: value="v1"  ← 创建（CreateRevision = 5）
Revision 8: value="v2"  ← 更新（ModRevision = 8）  
Revision 12: value="v3" ← 更新（ModRevision = 12）
```

**事务支持：** Etcd 的 `Txn` 提供了类似数据库的 Compare-And-Swap 语义：

```go
// Etcd 事务示例: 乐观锁实现
txn := client.Txn(ctx)
txn.If(
    clientv3.Compare(clientv3.Value("/lock/key"), "=", "expected_value"),
    clientv3.Compare(clientv3.CreateRevision("/lock/key"), ">", 0),
)
txn.Then(clientv3.OpPut("/lock/key", "new_value"))
txn.Else(clientv3.OpGet("/lock/key"))

txnResp, err := txn.Commit()
if txnResp.Succeeded {
    fmt.Println("CAS 成功")
} else {
    fmt.Println("CAS 失败，当前值:", string(txnResp.Responses[0].GetResponseRange().Kvs[0].Value))
}
```

### 3.4 Watch 机制

与 ZooKeeper 的一次性 Watch 不同，Etcd 的 Watch 是 **持久化长连接订阅**，基于 gRPC Stream：

```go
// Etcd Watch 示例 - 持久化监听
watchChan := client.Watch(ctx, "/config/", clientv3.WithPrefix())
for watchResp := range watchChan {
    for _, ev := range watchResp.Events {
        fmt.Printf("事件类型: %s | Key: %s | Value: %s\n", 
            ev.Type, ev.Kv.Key, ev.Kv.Value)
        // Etcd Watch 是持久的，不需要重新注册
    }
}
```

## 四、关键技术对比

### 4.1 一致性协议对比

| 对比维度 | ZooKeeper (ZAB) | Etcd (Raft) |
|----------|-----------------|-------------|
| 设计思想 | 类 Paxos 原子广播 | 易于理解的强一致性协议 |
| 读写策略 | 写由 Leader 处理，读任意节点（可能读到 stale 数据） | 写由 Leader 处理，读可配置一致性级别 |
| 线性一致性 | 写是线性一致的，读默认是最终一致 | 默认读也是线性一致的（从 Leader 读） |
| 脑裂保护 | 过半机制，分裂部分不可服务 | 过半机制，分裂部分不可服务 |

ZooKeeper 如果不使用 `sync()`，Follower 可能读到未同步的旧数据：

```java
// ZooKeeper 强一致性读
zk.sync(null, (rc, path, ctx) -> {
    zk.getData("/config/key", false, null, null);
}, null);
```

Etcd 默认保证线性一致性读，也可以通过 `WithSerializable()` 退化为可序列化读（性能更高）：

```go
// Etcd 可序列化读（不保证线性一致，但性能更好）
resp, _ := client.Get(ctx, "/key", clientv3.WithSerializable())
```

### 4.2 CAP 理论对比

| 特性 | ZooKeeper | Etcd |
|------|-----------|------|
| **一致性** | 强一致（可通过 sync 保证） | 强一致（默认线性一致） |
| **可用性** | 半可用（读仍可用，写不可用） | 半可用（读仍可用，写不可用） |
| **分区容忍** | CP 系统 | CP 系统 |
| **网络分区时行为** | 少数派节点拒绝写请求 | 少数派节点拒绝写请求 |

两者在 CAP 分类中都属于 **CP 系统**——在发生网络分区时优先保证一致性而非可用性。

### 4.3 性能基准对比

| 场景 | ZooKeeper (3节点) | Etcd (3节点) |
|------|------------------|--------------|
| 写吞吐（小数据） | ~10K QPS | ~15K QPS |
| 读吞吐 | ~30K QPS（Follower 可读） | ~50K QPS（可线性一致读） |
| 延迟 P99 | ~5ms | ~3ms |
| 数据上限 | 约 1GB（全量内存） | ~10GB（带 BoltDB 持久化） |
| 单个 Key 数据 | <1MB 推荐 | <1MB 推荐（实际支持更大） |

> 以上数据基于社区基准测试，实际性能受硬件、网络、数据大小等因素影响。

### 4.4 社区与生态对比

| 对比维度 | ZooKeeper | Etcd |
|----------|-----------|------|
| 语言 | Java | Go |
| 启动维护复杂度 | 中等（需配置 Java 环境） | 简单（单二进制文件） |
| 客户端 | Java、C、Python 等 | Go、Java（Jetcd）、Python |
| 监控 | JMX + 第三方 | Prometheus + metrics 内置 |
| Kubernetes 集成 | 无 | 核心依赖（存储所有集群数据） |
| Spring Cloud 集成 | Spring Cloud Zookeeper | Spring Cloud Etcd（较新） |

## 五、实战：服务发现实现

### 5.1 基于 ZooKeeper + Curator 的服务注册发现

Apache Curator 是 ZooKeeper 的 Java 客户端高级框架，封装了连接管理、重试、事件监听等复杂性：

```java
public class ZookeeperServiceRegistry {
    private static final String BASE_PATH = "/services";
    private final CuratorFramework client;
    private final ServiceInstance<Void> instance;

    public ZookeeperServiceRegistry(String zkAddress, String serviceName, String address, int port) 
            throws Exception {
        // 1. 创建 Curator 客户端
        client = CuratorFrameworkFactory.builder()
            .connectString(zkAddress)
            .sessionTimeoutMs(5000)
            .connectionTimeoutMs(3000)
            .retryPolicy(new ExponentialBackoffRetry(1000, 3))
            .build();
        client.start();

        // 2. 创建服务实例
        instance = ServiceInstance.<Void>builder()
            .name(serviceName)
            .address(address)
            .port(port)
            .payload("v1.0.0")
            .build();

        // 3. 注册到 ZooKeeper
        ServiceDiscoveryBuilder<Void> discoveryBuilder = 
            ServiceDiscoveryBuilder.builder(Void.class)
                .client(client)
                .basePath(BASE_PATH)
                .watchInstances(true);

        try (ServiceDiscovery<Void> discovery = discoveryBuilder.build()) {
            discovery.start();
            discovery.registerService(instance);
            System.out.println("服务注册成功: " + serviceName + "@" + address + ":" + port);
        }
    }

    // 服务发现
    public static List<ServiceInstance<Void>> discoverService(String zkAddress, String serviceName) 
            throws Exception {
        CuratorFramework client = CuratorFrameworkFactory.newClient(zkAddress, 
            new ExponentialBackoffRetry(1000, 3));
        client.start();

        ServiceDiscovery<Void> discovery = ServiceDiscoveryBuilder.builder(Void.class)
            .client(client)
            .basePath(BASE_PATH)
            .build();
        discovery.start();

        Collection<ServiceInstance<Void>> instances = discovery.queryForInstances(serviceName);
        return new ArrayList<>(instances);
    }

    public void close() {
        client.close();
    }

    public static void main(String[] args) throws Exception {
        // 注册服务
        ZookeeperServiceRegistry registry = new ZookeeperServiceRegistry(
            "localhost:2181", "user-service", "192.168.1.10", 8080);
        
        // 发现服务
        List<ServiceInstance<Void>> instances = discoverService("localhost:2181", "user-service");
        instances.forEach(ins -> 
            System.out.println("发现实例: " + ins.getAddress() + ":" + ins.getPort()));
        
        registry.close();
    }
}
```

### 5.2 基于 Etcd + Jetcd 的服务注册发现

Jetcd 是 Etcd 的 Java 客户端：

```java
public class EtcdServiceRegistry {
    private static final String PREFIX = "/services/";
    private final Client client;
    private final String fullPath;
    private final String instanceValue;

    public EtcdServiceRegistry(String endpoints, String serviceName, String address, int port) {
        this.client = Client.builder().endpoints(endpoints).build();
        this.fullPath = PREFIX + serviceName + "/" + address + ":" + port;
        this.instanceValue = address + ":" + port + ":v1.0.0";

        // 注册（带租约实现心跳）
        long leaseId = registerWithLease();
        System.out.println("服务注册成功，Lease ID: " + leaseId);
    }

    private long registerWithLease() {
        try {
            KV kvClient = client.getKVClient();
            Lease leaseClient = client.getLeaseClient();

            // 创建 10 秒 TTL 的租约
            long leaseId = leaseClient.grant(10).get().getID();

            // 写入数据并绑定租约
            kvClient.put(ByteSequence.from(UTF_8.encode(fullPath)),
                         ByteSequence.from(UTF_8.encode(instanceValue)),
                         PutOption.newBuilder().withLeaseId(leaseId).build()).get();

            // 自动续约（后台持续心跳）
            leaseClient.keepAlive(leaseId).thenAccept(keepAliveResponse -> 
                System.out.println("续约成功"));

            return leaseId;
        } catch (Exception e) {
            throw new RuntimeException("服务注册失败", e);
        }
    }

    // 服务发现（监听模式）
    public static void watchService(String endpoints, String serviceName) {
        Client client = Client.builder().endpoints(endpoints).build();
        KV kvClient = client.getKVClient();
        Watch watchClient = client.getWatchClient();

        String prefix = PREFIX + serviceName + "/";
        
        // 全量获取
        try {
            GetResponse response = kvClient.get(
                ByteSequence.from(UTF_8.encode(prefix)), 
                GetOption.newBuilder().withPrefix(ByteSequence.from(UTF_8.encode(prefix))).build()
            ).get();
            
            System.out.println("=== 当前可用实例 ===");
            response.getKvs().forEach(kv -> 
                System.out.println(new String(kv.getValue().getBytes())));
        } catch (Exception e) {
            e.printStackTrace();
        }

        // 持续监听变更
        watchClient.watch(ByteSequence.from(UTF_8.encode(prefix)), 
            WatchOption.newBuilder().withPrefix(ByteSequence.from(UTF_8.encode(prefix))).build())
            .thenAccept(watchResponse -> {
                watchResponse.getEvents().forEach(event -> {
                    System.out.println("事件类型: " + event.getEventType());
                    System.out.println("Key: " + new String(event.getKeyValue().getKey().getBytes()));
                    System.out.println("Value: " + new String(event.getKeyValue().getValue().getBytes()));
                });
            });

        System.out.println("正在监听服务变更...");
    }
}
```

## 六、分布式锁实现

### 6.1 ZooKeeper 分布式锁（基于 Curator）

```java
public class ZookeeperDistributedLock {
    private final InterProcessMutex lock;

    public ZookeeperDistributedLock(String zkAddress, String lockPath) {
        CuratorFramework client = CuratorFrameworkFactory.newClient(
            zkAddress, new ExponentialBackoffRetry(1000, 3));
        client.start();
        this.lock = new InterProcessMutex(client, lockPath);
    }

    public void executeWithLock(String taskId) {
        try {
            System.out.println("[" + taskId + "] 尝试获取分布式锁...");
            if (lock.acquire(5, TimeUnit.SECONDS)) {
                try {
                    System.out.println("[" + taskId + "] 获取锁成功！执行业务逻辑...");
                    // 模拟业务处理
                    TimeUnit.SECONDS.sleep(2);
                    System.out.println("[" + taskId + "] 业务逻辑完成");
                } finally {
                    lock.release();
                    System.out.println("[" + taskId + "] 释放锁");
                }
            } else {
                System.out.println("[" + taskId + "] 获取锁超时，跳过");
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static void main(String[] args) {
        ZookeeperDistributedLock lock = new ZookeeperDistributedLock(
            "localhost:2181", "/locks/order-payment");

        // 模拟 3 个并发任务
        ExecutorService executor = Executors.newFixedThreadPool(3);
        for (int i = 1; i <= 3; i++) {
            int taskId = i;
            executor.submit(() -> lock.executeWithLock("Task-" + taskId));
        }
        executor.shutdown();
    }
}
```

### 6.2 Etcd 分布式锁

Etcd 的 `concurrency` 包提供了分布式锁实现：

```java
public class EtcdDistributedLock {
    private final Client client;
    private final Lock lockClient;

    public EtcdDistributedLock(String endpoints) {
        this.client = Client.builder().endpoints(endpoints).build();
        this.lockClient = client.getLockClient();
    }

    public void executeWithLock(String lockKey, String taskId) {
        String lockPath = "/locks/" + lockKey;
        ByteSequence lockKeyBytes = ByteSequence.from(UTF_8.encode(lockPath));
        
        try {
            System.out.println("[" + taskId + "] 尝试获取分布式锁: " + lockPath);
            
            // 获取锁（绑定默认 60 秒租约）
            lockClient.lock(lockKeyBytes, 60L, TimeUnit.SECONDS)
                .thenAccept(execution -> {
                    try {
                        System.out.println("[" + taskId + "] 获取锁成功，执行业务...");
                        TimeUnit.SECONDS.sleep(2);
                        System.out.println("[" + taskId + "] 业务执行完成");
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    } finally {
                        // 释放锁
                        execution.unlock();
                        System.out.println("[" + taskId + "] 释放锁完成");
                    }
                }).get(10, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            System.out.println("[" + taskId + "] 获取锁超时");
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static void main(String[] args) {
        EtcdDistributedLock lock = new EtcdDistributedLock("http://localhost:2379");
        
        ExecutorService executor = Executors.newFixedThreadPool(3);
        for (int i = 1; i <= 3; i++) {
            int taskId = i;
            executor.submit(() -> lock.executeWithLock("payment-lock", "Task-" + taskId));
        }
        executor.shutdown();
    }
}
```

## 七、Spring Cloud 集成

### 7.1 Spring Cloud ZooKeeper

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-zookeeper-discovery</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-zookeeper-config</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  application:
    name: user-service
  cloud:
    zookeeper:
      connect-string: localhost:2181
      discovery:
        enabled: true
        root: /services
        register: true
      config:
        enabled: true
        root: /config
        default-context: user-service
```

```java
@SpringBootApplication
@EnableDiscoveryClient
public class UserServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}

@RestController
public class UserController {
    @Autowired
    private DiscoveryClient discoveryClient;

    @GetMapping("/discover/{serviceName}")
    public List<ServiceInstance> discoverService(@PathVariable String serviceName) {
        return discoveryClient.getInstances(serviceName);
    }
}
```

### 7.2 Spring Cloud Etcd

Etcd 在 Spring Cloud 生态中的集成相对较新，但社区正在积极推进：

```yaml
# application.yml
spring:
  application:
    name: order-service
  cloud:
    etcd:
      endpoints: http://localhost:2379
      discovery:
        enabled: true
        root: /services
      config:
        enabled: true
        root: /config
```

```java
@SpringBootApplication
@EnableDiscoveryClient
public class OrderServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(OrderServiceApplication.class, args);
    }
}
```

## 八、选型建议

### 8.1 决策矩阵

| 场景 | 推荐 | 理由 |
|------|------|------|
| **Kubernetes / 云原生** | Etcd | Kubernetes 原生依赖，天然契合 |
| **大数据 / Hadoop 生态** | ZooKeeper | HBase、Kafka、Solr 原生集成 |
| **Spring Cloud 微服务** | ZooKeeper | Spring Cloud 生态成熟度高 |
| **配置中心** | Etcd | Watch 机制更稳定，MVCC 支持版本回滚 |
| **分布式锁** | 两者皆可 | Curator 锁更完善，Etcd 锁更轻量 |
| **高吞吐配置变更** | Etcd | 性能略优，gRPC Stream 监听更高效 |
| **已有 Java 基础设施** | ZooKeeper | Curator 客户端强大，社区丰富 |

### 8.2 经验总结

1. **性能考量**：如果对线性一致性读有强要求，Etcd 更优（默认保证）；ZooKeeper 需要通过 `sync()` 额外操作。
2. **运维成本**：Etcd 单二进制文件部署，Prometheus 指标内置，运维远优于 ZooKeeper（需 JMX 配置）。
3. **大数据场景**：Kafka、HBase、Solr 等重度依赖 ZooKeeper，在这些生态中避不开。
4. **云原生场景**：Kubernetes 用 Etcd 做存储，引入 ZooKeeper 意味着多维护一套组件。

**一句话总结**：做大数据选 ZooKeeper，做云原生选 Etcd，两者共存也常见——没有银弹，按场景选型。

## 九、Kubernetes 中的 Etcd 应用

Kubernetes 是 Etcd 最知名的用户。Kubernetes 将所有集群数据存储在 Etcd 中：

```
/registry/
├── /registry/pods/
├── /registry/services/
├── /registry/deployments/
├── /registry/nodes/
├── /registry/secrets/
├── /registry/configmaps/
└── /registry/namespaces/
```

### Kubernetes Etcd 集群配置要点：

```yaml
# Etcd 集群配置示例（kubeadm 参数）
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      listen-client-urls: "https://127.0.0.1:2379,https://10.0.0.1:2379"
      advertise-client-urls: "https://10.0.0.1:2379"
      listen-peer-urls: "https://10.0.0.1:2380"
      initial-advertise-peer-urls: "https://10.0.0.1:2380"
      initial-cluster: "etcd-0=https://10.0.0.1:2380,etcd-1=https://10.0.0.2:2380,etcd-2=https://10.0.0.3:2380"
      initial-cluster-state: "new"
      auto-compaction-retention: "8"   # 自动压缩保留 8 个 revision
      quota-backend-bytes: "8589934592" # 8GB 存储配额
```

**生产环境 Etcd 运维建议**：
- 定期进行 **defrag**（碎片整理）防止存储空间膨胀
- 设置合理的 **auto-compaction-retention** 自动清理历史版本
- Etcd 集群不应与其他工作负载混部
- 磁盘 IO 性能直接影响整个集群稳定性（推荐 SSD）

## 十、总结

ZooKeeper 和 Etcd 都是优秀的分布式协调服务，各自经历了大规模生产环境的验证。ZooKeeper 在大数据生态中不可撼动，Etcd 在云原生领域风光无限。理解它们各自的协议原理、数据模型和适用场景，才能在面对具体业务需求时做出合理的技术选型。

掌握两者的核心差异，对分布式系统的设计能力有本质上的提升——这不仅仅是选 ZooKeeper 还是 Etcd 的问题，而是对 CAP、共识算法、分布式一致性的深刻理解。
