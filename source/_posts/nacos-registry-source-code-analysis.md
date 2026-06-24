---
title: 【源码深度】Nacos 注册中心源码解析：服务注册、发现与一致性协议
date: 2026-06-24 08:00:00
tags:
  - Java
  - Spring Cloud
  - Nacos
  - 源码
categories:
  - Java
  - 微服务
author: 东哥
---

# 【源码深度】Nacos 注册中心源码解析：服务注册、发现与一致性协议

## 面试官：Nacos 作为注册中心是怎么保证数据一致性的？

Nacos（Dynamic Naming and Configuration Service）是阿里巴巴开源的一站式微服务基础设施，集注册中心与配置中心于一身。本文将从源码层面深入分析 Nacos 注册中心的核心实现。

## 一、Nacos 架构概览

### 1.1 核心组件

```
┌─────────────────────────────────────────────────┐
│                  Nacos Server                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │ AP协议    │  │ CP协议    │  │ 配置管理      │  │
│  │ (Distro)  │  │ (Raft)   │  │ (Config)     │  │
│  └─────┬────┘  └─────┬────┘  └──────┬───────┘  │
│        │              │              │           │
│  ┌─────┴──────────────┴──────────────┴───────┐  │
│  │          Nacos 集群节点通信               │  │
│  └───────────────────────────────────────────┘  │
└──────────────────────┬──────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
       Service       Service       Service
         A              B             C
```

- **AP 协议（Distro）**：服务注册发现场景，保证可用性
- **CP 协议（JRaft）**：配置管理 + 选举场景，保证一致性

### 1.2 数据模型

Nacos 注册中心的数据模型分为三层：

```
Namespace (命名空间)
  └── Group (分组)
       └── Service (服务)
            └── Cluster (集群)
                 └── Instance (实例)
```

## 二、服务注册源码分析

### 2.1 服务端入口

当客户端发起注册请求时，请求到达 Nacos 服务端的 `InstanceController`：

```java
@RestController
@RequestMapping("/nacos/v1/ns")
public class InstanceController {
    
    @PostMapping("/instance")
    public String register(HttpServletRequest request) throws Exception {
        // 1. 解析请求参数
        String namespaceId = WebUtils.optional(request, "namespaceId", Constants.DEFAULT_NAMESPACE_ID);
        String serviceName = WebUtils.required(request, "serviceName");
        String ip = WebUtils.required(request, "ip");
        int port = Integer.parseInt(WebUtils.required(request, "port"));
        
        // 2. 构建 Instance 对象
        Instance instance = new Instance();
        instance.setIp(ip);
        instance.setPort(port);
        instance.setServiceName(serviceName);
        // ... 其他参数
        
        // 3. 调用核心注册逻辑
        instanceService.registerInstance(namespaceId, serviceName, instance);
        return "ok";
    }
}
```

### 2.2 核心注册逻辑

```java
// NacosInstanceService
public void registerInstance(String namespaceId, String serviceName, Instance instance) {
    // 1. 获取或创建 Service
    Service service = getService(namespaceId, serviceName);
    if (service == null) {
        service = new Service(namespaceId, serviceName);
        createServiceIfAbsent(service);
    }
    
    // 2. 添加实例到 Service
    addInstance(namespaceId, serviceName, instance.isEphemeral(), instance);
}

private void addInstance(String namespaceId, String serviceName, 
                          boolean ephemeral, Instance instance) {
    // 根据是否是临时实例选择不同的存储
    if (ephemeral) {
        // 临时实例 → 内存存储（Distro 协议）
        ephemeralInstanceService.addInstance(serviceName, instance);
    } else {
        // 持久实例 → 持久化存储（CP 协议 + 数据库）
        persistentInstanceService.addInstance(serviceName, instance);
    }
}
```

**关键设计**：临时实例（ephemeral）和持久实例（persistent）使用不同的存储和一致性协议。

### 2.3 心跳机制

客户端注册后，会启动心跳定时任务：

```java
// Nacos 客户端
public class BeatReactor {
    private ScheduledExecutorService executorService;
    
    public void addBeatInfo(String serviceName, BeatInfo beatInfo) {
        executorService.schedule(
            new BeatTask(beatInfo),
            beatInfo.getPeriod(),
            TimeUnit.MILLISECONDS
        );
    }
    
    class BeatTask implements Runnable {
        @Override
        public void run() {
            // 发送心跳到服务端
            Result result = serverProxy.sendBeat(beatInfo);
            // 如果心跳返回需要重新注册
            if (result.isLightBeatEnabled()) {
                // 轻量心跳：仅更新时间戳
            } else {
                // 完整心跳：重新发送所有数据
            }
            // 调度下一次心跳
            executorService.schedule(this, beatInfo.getPeriod(), TimeUnit.MILLISECONDS);
        }
    }
}
```

服务端处理心跳：

```java
// 服务端心跳处理
@PutMapping("/instance/beat")
public JSONObject beat(HttpServletRequest request) throws Exception {
    String namespaceId = WebUtils.optional(request, "namespaceId", Constants.DEFAULT_NAMESPACE_ID);
    String serviceName = WebUtils.required(request, "serviceName");
    String ip = WebUtils.required(request, "ip");
    int port = Integer.parseInt(WebUtils.required(request, "port"));
    
    // 更新实例的最后心跳时间
    Instance instance = instanceService.getInstance(namespaceId, serviceName, ip, port);
    instance.setLastBeat(System.currentTimeMillis());
    
    // 如果实例已被标记为不健康，重新标记为健康
    if (!instance.isHealthy()) {
        instance.setHealthy(true);
    }
    
    return buildBeatResult(instance);
}
```

**临时实例的自动摘除机制**：
```
客户端注册 → 每5s发心跳 → 服务端更新 lastBeat
                                    ↓
                    健康检查线程每10s扫描所有实例
                                    ↓
                   检查 lastBeat 是否超过15s
                    ┌──── 否 ────→ 健康
                    └──── 是 ────→ 标记不健康 → 再过30s 仍无心跳 → 删除实例
```

## 三、服务发现源码解析

### 3.1 客户端发现

```java
// 客户端调用
List<Instance> instances = namingService.selectInstances("service-name", true);

// 服务端查询
@GetMapping("/instance/list")
public JSONObject list(HttpServletRequest request) throws Exception {
    String namespaceId = WebUtils.optional(request, "namespaceId", Constants.DEFAULT_NAMESPACE_ID);
    String serviceName = WebUtils.required(request, "serviceName");
    boolean healthyOnly = Boolean.parseBoolean(
        WebUtils.optional(request, "healthyOnly", "false"));
    
    return doSrvIPxtz(namespaceId, serviceName, healthyOnly);
}
```

### 3.2 客户端缓存与推送

Nacos 支持 **UDP 推送** 和 **长轮询** 两种方式更新客户端缓存：

```java
// 客户端 HostReactor
public class HostReactor {
    // 本地缓存
    private Map<String, ServiceInfo> serviceInfoMap;
    
    public ServiceInfo getServiceInfo(final String serviceName, String clusters) {
        // 1. 先从本地缓存获取
        ServiceInfo serviceInfo = serviceInfoMap.get(serviceName);
        if (serviceInfo == null) {
            // 缓存未命中，同步拉取
            serviceInfo = namingService.getServiceInfoFromServer(serviceName, clusters);
            serviceInfoMap.put(serviceName, serviceInfo);
        }
        
        // 2. 启动定时更新任务
        scheduleUpdateIfAbsent(serviceName, clusters);
        return serviceInfo;
    }
    
    private void scheduleUpdateIfAbsent(String serviceName, String clusters) {
        // 使用长轮询定时拉取服务列表
        executorService.scheduleWithFixedDelay(
            new UpdateTask(serviceName, clusters),
            0, 10, TimeUnit.SECONDS  // 每10秒拉取一次
        );
    }
}
```

长轮询更新：

```java
class UpdateTask implements Runnable {
    @Override
    public void run() {
        // 带版本号的长轮询请求
        String result = namingService.subscribe(serviceName, clusters, 
            currentVersion, timeoutMs);
        if (result != null && !result.isEmpty()) {
            // 服务列表已变更，更新本地缓存
            ServiceInfo newInfo = NamingProxy.parseServiceInfo(result);
            serviceInfoMap.put(serviceName, newInfo);
            // 通知所有监听者
            notifyListeners(serviceName, newInfo);
        }
    }
}
```

## 四、一致性协议：Distro（AP协议）

### 4.1 Distro 协议原理

Nacos 的 Distro 协议是自研的 AP 协议，针对服务注册场景设计：

**核心思想**：

```
Nacos 集群（3节点）
┌─────────┐    ┌─────────┐    ┌─────────┐
│ Node1   │◄──►│ Node2   │◄──►│ Node3   │
│ (负责A,B)│    │ (负责C,D)│    │ (负责E,F)│
└────┬────┘    └────┬────┘    └────┬────┘
     │              │              │
     └──────────────┴──────────────┘
             异步同步

服务 A 注册到 Node1：
  1. Node1 在本地内存写入服务 A 数据
  2. 异步将数据复制到 Node2、Node3
  3. 立即返回注册成功（不等待同步完成）
```

**特点**：
- 写操作只写入当前节点内存，异步复制到其他节点
- 读操作可以从任意节点读取（当前节点可能不是最新的）
- 牺牲强一致性换取高可用

### 4.2 源码实现

```java
// DistroConsistencyServiceImpl
@Component
public class DistroConsistencyServiceImpl implements EphemeralConsistencyService {
    
    @Override
    public void put(String key, Record value) throws NacosException {
        // 1. 写入本地内存
        onPut(key, value);
        
        // 2. 将变更记录到 Distro 任务
        distroTaskEngine.addTask(key, new DistroKey(key, Type.INSTANCE));
        
        // 3. 异步同步到其他节点
        distroProtocol.syncToDistro(distroKey, data);
    }
    
    // 同步任务执行
    private void syncToDistro(DistroKey distroKey, DistroData data) {
        // 获取集群其他节点列表
        List<String> servers = serverMemberManager.allOtherNodes();
        
        for (String server : servers) {
            // 异步发送变更数据
            distroHttpRegistry.getTransport().syncData(data, server);
        }
    }
}
```

### 4.3 节点间数据同步

```java
// 接收同步请求
@PostMapping("/distro/instances")
public void receiveSyncData(HttpServletRequest request) {
    List<Instance> instances = parseInstances(request);
    
    for (Instance instance : instances) {
        // 更新到本地内存
        ephemeralInstanceService.addInstance(instance);
    }
}
```

**节点健康检查**：节点间互相发送心跳，如果超过一定时间未收到心跳，将该节点标记为不可用。

## 五、一致性协议：JRaft（CP协议）

对于持久实例和配置管理，Nacos 使用 JRaft（基于 Raft 算法的实现）。

### 5.1 Raft 选举

```java
// JRaft 节点状态
public enum PeerState {
    FOLLOWER,   // 跟随者
    CANDIDATE,  // 候选者
    LEADER      // 领导者
}
```

**选举过程**：
1. Follower 超时未收到 Leader 心跳 → 转为 Candidate
2. Candidate 发起投票请求（RequestVote RPC）
3. 获得多数派投票 → 成为 Leader
4. Leader 定期发送心跳（AppendEntries RPC）维持地位

### 5.2 日志复制

```java
// Leader 写入日志并复制到 Follower
public void write(byte[] data) {
    // 1. 写入本地 Raft 日志
    Closure done = (status) -> {
        if (status.isOk()) {
            // 写入成功，应用到状态机
            applyToStateMachine(data);
        }
    };
    node.apply(new Task(data, done));
    
    // 2. 日志自动复制到多数 Follower
    // 3. 多数派确认后，提交日志
    // 4. 应用到状态机
}
```

| 特性 | Distro (AP) | JRaft (CP) |
|------|------------|------------|
| 一致性级别 | 最终一致性 | 强一致性 |
| 可用性 | 极高（任何节点可写） | 高（Leader 挂后需选举） |
| 性能 | 高（异步复制） | 中等（多数派确认） |
| 适用场景 | 临时实例注册 | 持久实例/配置 |

## 六、Spring Cloud 集成原理

```java
// NacosServiceDiscovery
public class NacosServiceDiscovery implements ServiceDiscovery {
    
    @Override
    public List<ServiceInstance> getInstances(String serviceId) {
        // 调用 Nacos 客户端 SDK 获取实例列表
        List<Instance> instances = namingService.selectInstances(serviceId, true);
        return hostToServiceInstanceList(instances, serviceId);
    }
}
```

## 七、高可用与最佳实践

### 7.1 集群部署建议

- 部署 3 或 5 节点（奇偶数，利于 Raft 选举）
- 开启元数据持久化（MySQL 后端）
- 配置 VIP 或 SLB 做负载均衡

### 7.2 常见问题

**Q：临时实例和持久实例的区别？**
A：临时实例基于心跳保活，不存活则自动摘除；持久实例需要主动注销，适合人工管理的场景。

**Q：Nacos 的 AP 和 CP 模式如何切换？**
A：Nacos 内部根据操作类型自动选择 —— 临时实例用 Distro (AP)，持久实例和配置用 JRaft (CP)。不需要手动切换。

**Q：Nacos 与 Eureka 的区别？**
A：Nacos 支持 AP+CP 双模、支持配置中心、支持权重路由、支持健康检查更丰富。

## 八、总结

Nacos 注册中心的设计充分体现了 **分治思想**：
- 临时/持久实例分离，使用不同协议
- 读/写分离，兼顾性能与一致性
- 客户端缓存 + 服务端推送，减少网络开销

理解 Nacos 的源码设计，不仅能帮助你面试通关，更能让你在实际生产中游刃有余地排查问题、做出架构决策。

🔥 **面试追问准备**：
1. Nacos 为什么要设计 Distro 协议？为什么不用 Raft？
2. Nacos 客户端是如何感知服务变更的？（UDP 推送 vs 长轮询）
3. Nacos 集群节点间如何同步数据？
4. 注册中心选型：Nacos vs Eureka vs Consul vs Zookeeper？
