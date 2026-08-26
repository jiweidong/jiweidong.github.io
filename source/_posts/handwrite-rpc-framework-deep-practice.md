---
title: 【Java 实战】手写一个 RPC 框架：从动态代理、序列化到 Netty 通信的完整实现
date: 2026-08-26 08:00:00
tags:
  - Java
  - RPC
  - Netty
  - 微服务
categories:
  - Java
  - 微服务
author: 东哥
---

# 【Java 实战】手写一个 RPC 框架：从动态代理、序列化到 Netty 通信的完整实现

## 面试官：RPC 框架的原理是什么？如果让你从零实现一个，你会怎么设计？

RPC（Remote Procedure Call，远程过程调用）就是让调用方像调用本地方法一样调用远程服务。Dubbo、gRPC、Thrift 这些框架本质都在解决同一件事：**把"本地方法调用"翻译成"网络消息收发"**。

很多同学面试被问到 RPC 原理时只会背概念，本文带大家**手写一个迷你 RPC 框架**，把 RPC 的五大核心模块全部落地：

1. **动态代理**：调用方无感知，像调本地方法一样调远程
2. **协议设计**：消息怎么封装，怎么区分请求/响应
3. **序列化**：对象 ↔ 字节流互转
4. **网络通信**：基于 Netty 的 TCP 长连接
5. **注册中心**：服务发现与负载均衡

## 一、RPC 整体架构

先画清脉络：

```
┌─────────────┐   本地调用    ┌──────────────┐
│   Service A  │ ───────────▶ │  Proxy 代理    │
│  (消费者)     │              │ (动态代理)     │
└─────────────┘              └──────┬───────┘
                                    │ 序列化 + 协议封装
                                    ▼
                              ┌──────────────┐    TCP    ┌──────────────┐
                              │  Netty Client │ ◀────────▶ │  Netty Server │
                              └──────────────┘            └──────┬───────┘
                                                                 │ 反序列化 + 反射调用
                                                                 ▼
                                                           ┌──────────────┐
                                                           │  Service B   │
                                                           │  (提供者)      │
                                                           └──────────────┘
```

核心流程一句话：**消费者通过代理发起调用 → 序列化成请求消息 → Netty 发送 → 提供者反序列化 → 反射调用真实方法 → 结果序列化返回 → 消费者拿到结果**。

## 二、模块一：协议设计（最容易被忽视的部分）

网络传输的是字节，我们必须定义一套**消息格式**，让双方能解析。参考主流 RPC 的协议设计（Dubbo 协议、自定义私有协议），一个健壮的协议头应该包含：

| 字段 | 长度 | 说明 |
|------|------|------|
| 魔数 | 2 字节 | 协议标识，如 `0xCAFE`，防止解析到无关数据 |
| 版本号 | 1 字节 | 协议版本，方便兼容演进 |
| 消息类型 | 1 字节 | 请求(0x01)/响应(0x02)/心跳(0x03) |
| 序列化方式 | 1 字节 | JSON(1)/Hessian(2)/Kryo(3)/Protobuf(4) |
| 状态码 | 1 字节 | 响应状态：成功/失败/超时 |
| 请求 ID | 8 字节 | 全局唯一 ID，用于**异步响应配对** |
| 数据长度 | 4 字节 | 消息体长度（关键！解决粘包半包） |

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       魔数 (0xCAFE)        | 版本 | 类型 | 序列化 | 状态码     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        请求 ID (8 字节)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       数据长度 (4 字节)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         消息体 (业务数据)                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 为什么"数据长度"字段是灵魂？

TCP 是**流协议**，没有消息边界。一次 `write` 的数据可能被拆成多个包（半包），多次 `write` 的数据可能粘在一起（粘包）。有了长度字段，接收端就能按"读 18 字节头 → 读 N 字节体"精确切分消息。Netty 提供了现成的解码器，后面讲。

## 三、模块二：序列化与反序列化

消息体是 Java 对象，必须转成字节。定义一个序列化接口，方便扩展多种实现：

```java
public interface Serializer {
    <T> byte[] serialize(T obj);
    <T> T deserialize(byte[] bytes, Class<T> clazz);
}
```

### JSON 实现（简单，生产慎用）

```java
public class JsonSerializer implements Serializer {
    private final ObjectMapper mapper = new ObjectMapper();

    @Override
    public <T> byte[] serialize(T obj) {
        try {
            return mapper.writeValueAsBytes(obj);
        } catch (JsonProcessingException e) {
            throw new RuntimeException("序列化失败", e);
        }
    }

    @Override
    public <T> T deserialize(byte[] bytes, Class<T> clazz) {
        try {
            return mapper.readValue(bytes, clazz);
        } catch (IOException e) {
            throw new RuntimeException("反序列化失败", e);
        }
    }
}
```

### 序列化方案对比（面试高频）

| 方案 | 性能 | 体积 | 跨语言 | 安全 | 场景 |
|------|------|------|--------|------|------|
| Java 原生 | 差 | 大 | 否 | 有反序列化漏洞风险 | 几乎不用 |
| JSON (Jackson/Gson) | 中 | 中 | 是 | 需配置 | 调试、HTTP 接口 |
| Hessian2 | 中上 | 中 | 部分 | 一般 | Dubbo 默认之一 |
| Kryo | 高 | 小 | 否 | 一般 | 同语言高性能场景 |
| Protobuf | 极高 | 极小 | 是 | 好 | gRPC、跨语言 RPC |

## 四、模块三：网络通信层（Netty）

基于 Netty 实现客户端和服务端。先用刚才的协议定义请求/响应消息：

```java
public class RpcRequest {
    private String requestId;    // 请求 ID（与协议头对应）
    private String interfaceName;// 接口全限定名
    private String methodName;   // 方法名
    private Class<?>[] paramTypes;// 参数类型数组（反射需要）
    private Object[] params;     // 参数值
    // getter/setter 省略
}

public class RpcResponse {
    private String requestId;    // 对应请求 ID
    private Object result;       // 返回值
    private Throwable error;     // 异常信息
    // getter/setter 省略
}
```

### 服务端：解码 + 处理 + 编码

服务端 Pipeline 的核心三件套：

```java
pipeline.addLast(new LengthFieldBasedFrameDecoder(65536, 18, 4, 0, 0));
// 参数说明：maxFrameLength=64KB, lengthFieldOffset=18(跳到长度字段),
//         lengthFieldLength=4, lengthAdjustment=0, initialBytesToStrip=0
pipeline.addLast(new RpcDecoder());   // 字节 → RpcRequest
pipeline.addLast(new RpcEncoder());   // RpcResponse → 字节
pipeline.addLast(new RpcServerHandler());
```

`LengthFieldBasedFrameDecoder` 是 Netty 解决粘包半包的**神器**：它先读 18 字节头部，取出偏移 18 处的 4 字节长度，然后等够 `长度` 字节的数据才向下传递——**自动完成拆包**。

### 服务端处理器：反射调用真实方法

```java
public class RpcServerHandler extends SimpleChannelInboundHandler<RpcRequest> {

    // 接口名 → 实现类实例（启动时从 Spring 容器或注册表注入）
    private final Map<String, Object> serviceRegistry;

    @Override
    protected void channelRead0(ChannelHandlerContext ctx, RpcRequest request) throws Exception {
        RpcResponse response = new RpcResponse();
        response.setRequestId(request.getRequestId());
        try {
            // 1. 按接口名找到实现类
            Object service = serviceRegistry.get(request.getInterfaceName());
            // 2. 反射定位方法
            Method method = service.getClass().getMethod(
                    request.getMethodName(), request.getParamTypes());
            // 3. 反射调用
            Object result = method.invoke(service, request.getParams());
            response.setResult(result);
        } catch (Throwable t) {
            response.setError(t);
        }
        // 4. 写回响应（编码器会序列化）
        ctx.writeAndFlush(response);
    }
}
```

**注意**：真实 RPC 框架不会直接 `method.invoke`，而是用 MethodHandle 或字节码生成调用器，避免反射性能损耗；方法级缓存 `Method` 对象也是标配。

## 五、模块四：客户端动态代理（核心中的核心）

客户端要"像调本地方法一样调远程"，靠的就是 JDK 动态代理：

```java
public class RpcProxyFactory {

    private final RpcClient rpcClient;  // Netty 客户端（负责发送请求）

    public <T> T create(Class<T> interfaceClass) {
        return (T) Proxy.newProxyInstance(
                interfaceClass.getClassLoader(),
                new Class[]{interfaceClass},
                (proxy, method, args) -> {
                    // 1. 组装请求
                    RpcRequest request = new RpcRequest();
                    request.setRequestId(UUID.randomUUID().toString());
                    request.setInterfaceName(interfaceClass.getName());
                    request.setMethodName(method.getName());
                    request.setParamTypes(method.getParameterTypes());
                    request.setParams(args);
                    // 2. 发送并同步等待响应（内部用 Future + 请求ID 配对）
                    RpcResponse response = rpcClient.send(request);
                    if (response.getError() != null) {
                        throw response.getError();
                    }
                    return response.getResult();
                });
    }
}
```

### 同步等待是怎么实现的？——请求 ID 配对

Netty 是异步的，`writeAndFlush` 不会阻塞等待响应。所以客户端要维护一个"待响应表"：

```java
public class RpcClient {
    // requestId → CompletableFuture（响应到达时完成）
    private final ConcurrentHashMap<String, CompletableFuture<RpcResponse>>
            pendingRequests = new ConcurrentHashMap<>();

    public RpcResponse send(RpcRequest request) {
        CompletableFuture<RpcResponse> future = new CompletableFuture<>();
        pendingRequests.put(request.getRequestId(), future);
        channel.writeAndFlush(request);          // 异步发送
        try {
            // 同步等待：调用方阻塞在这里，最大 5 秒
            return future.get(5, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            pendingRequests.remove(request.getRequestId());
            throw new RuntimeException("RPC 调用超时: " + request.getRequestId());
        }
    }

    // 由 ClientHandler 在收到响应时回调
    public void onResponse(RpcResponse response) {
        CompletableFuture<RpcResponse> future =
                pendingRequests.remove(response.getRequestId());
        if (future != null) {
            future.complete(response);           // 唤醒等待的调用方
        }
    }
}
```

这就是 Dubbo 的 `DefaultFuture`、gRPC 的 StreamObserver 背后共同的套路：**请求 ID 关联 + Future 异步回调**。理解了这张表，你就理解了所有 RPC 客户端。

## 六、模块五：注册中心与服务发现

生产环境服务提供者有多台，消费者怎么知道连哪台？需要一个注册中心。这里用一个极简的内存版演示思想（生产可用 ZooKeeper/Nacos/Etcd）：

```java
// 注册中心：接口名 → 服务地址列表
public class SimpleRegistry {
    private final ConcurrentHashMap<String, List<String>> services = new ConcurrentHashMap<>();

    // 提供者启动时注册
    public void register(String interfaceName, String address) {
        services.computeIfAbsent(interfaceName, k -> new CopyOnWriteArrayList<>())
                .add(address);
    }

    // 消费者获取地址列表（可带负载均衡策略）
    public List<String> discover(String interfaceName) {
        return services.getOrDefault(interfaceName, Collections.emptyList());
    }
}
```

消费者拿到多个地址后，用负载均衡策略选一个。最简单的**轮询**：

```java
public class RoundRobinLoadBalancer {
    private final AtomicInteger index = new AtomicInteger();

    public String select(List<String> addresses) {
        if (addresses.isEmpty()) throw new IllegalStateException("无可用服务");
        return addresses.get(index.getAndIncrement() % addresses.size());
    }
}
```

生产级负载均衡还有随机、加权轮询、一致性哈希（结合虚拟节点）、最少活跃调用等策略。

## 七、完整调用链路串起来

```java
// ===== 服务提供者启动 =====
// 1. 注册实现类到本地注册表
serviceRegistry.put(UserService.class.getName(), new UserServiceImpl());
// 2. 注册到注册中心
registry.register(UserService.class.getName(), "192.168.1.10:8080");
// 3. 启动 Netty Server 监听 8080
new RpcServer(8080, serviceRegistry).start();

// ===== 服务消费者调用 =====
// 1. 从注册中心拿到地址列表
List<String> addresses = registry.discover(UserService.class.getName());
// 2. 连接选中的服务端（建立 Netty 长连接）
RpcClient client = new RpcClient(loadBalancer.select(addresses));
// 3. 创建代理，像调本地方法一样调用！
UserService userService = new RpcProxyFactory(client).create(UserService.class);
User user = userService.getUserById(1001);   // 幕后发生了一次远程调用
System.out.println(user);
```

## 八、进阶优化：真实 RPC 框架还做了什么？

| 能力 | 实现思路 | 代表框架 |
|------|---------|---------|
| 连接复用 | TCP 长连接 + 连接池 | Dubbo、gRPC |
| 心跳保活 | 定时发送心跳包，空闲检测断线重连 | Netty IdleStateHandler |
| 超时控制 | Future.get(timeout) + 定时清理 | 所有 RPC |
| 异步化 | 提供异步接口，避免线程阻塞 | Dubbo async |
| 泛化调用 | 不依赖接口 jar 包，传字符串调用 | Dubbo GenericService |
| 优雅关闭 | 摘除注册 + 等待在途请求完成 | 生产必备 |
| 服务治理 | 限流、熔断、降级、链路追踪 | Sentinel + SkyWalking |
| 高性能序列化 | Kryo/Protobuf + 缓存序列化器 | gRPC、sofa-bolt |

## 九、面试追问汇总

1. **RPC 和 HTTP 的区别？** RPC 面向服务间内部调用，注重性能与治理（自定义协议、连接复用、序列化高效）；HTTP 面向通用场景、跨语言好、易调试。Dubbo 走 RPC 协议，Spring Cloud OpenFeign 走 HTTP。
2. **为什么需要请求 ID？** Netty 异步模型下多个请求共用一个连接，响应到达时必须知道对应哪个请求。
3. **粘包半包怎么解决？** 固定长度、分隔符、长度字段（Netty `LengthFieldBasedFrameDecoder`）、TLV 编码。
4. **动态代理在 RPC 里起什么作用？** 屏蔽网络细节，调用方零感知。
5. **注册中心挂了怎么办？** 消费者本地缓存服务列表 + 直连配置兜底；生产要求注册中心高可用。
6. **序列化怎么选？** 同语言高性能选 Kryo/Hessian，跨语言选 Protobuf，追求简单可调试选 JSON。

## 总结

手写 RPC 的核心就四件事：**协议定边界、序列化转字节、Netty 传消息、代理藏细节**。再往上一层是注册中心和服务治理。能把动态代理 + 请求 ID 配对 + LengthFieldBasedFrameDecoder 这条链路讲清楚并写出核心代码，RPC 相关的面试题基本都能拿下。建议读者照着本文把代码敲一遍，理解会完全不一样。
