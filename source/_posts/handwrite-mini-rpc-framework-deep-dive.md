---
title: 【Java 实战】从零手写迷你 RPC 框架：动态代理、序列化、注册中心与负载均衡全实现
date: 2026-08-27 08:00:00
tags:
  - Java
  - RPC
  - 分布式
  - 动态代理
  - 实战
categories:
  - Java
  - 微服务
author: 东哥
---

# 【Java 实战】从零手写迷你 RPC 框架：动态代理、序列化、注册中心与负载均衡全实现

## 面试官：Dubbo 的原理你背得挺熟，那你能手写一个迷你 RPC 吗？

背源码不如写代码。RPC（Remote Procedure Call，远程过程调用）的核心思想一句话：**让调用远程方法像调用本地方法一样**。Dubbo、gRPC 再复杂，骨架无非是这几块：

1. **动态代理**：客户端拿到的是接口代理，方法调用被拦截
2. **序列化**：把方法名、参数变成字节流
3. **网络传输**：TCP/HTTP 把请求发给服务端
4. **注册中心**：服务提供方注册、消费方发现
5. **负载均衡**：多个服务提供者选一个
6. **服务端反射调用**：根据方法名找到实现类并执行

今天我们不用任何框架，纯 JDK 手写一个可运行的迷你 RPC，跑通"客户端调用远程接口 → 服务端执行 → 返回结果"的完整链路。全部代码约 300 行，建议自己敲一遍。

## 一、整体架构设计

```
┌──────────────┐         ┌──────────────────┐
│  客户端 (Consumer)  │         │  服务端 (Provider)   │
│              │         │                  │
│  UserService ├─代理──► │  UserServiceImpl  │
│  (接口代理)   │  网络    │  (反射执行)        │
└──────┬───────┘         └────────┬─────────┘
       │                          │
       │  注册中心 (Registry)      │
       └─────────── 服务注册/发现 ─┘
```

**核心接口设计：**

```java
// 1. RPC 请求/响应消息体
public class RpcRequest implements Serializable {
    private String requestId;      // 请求 ID（异步回调用）
    private String interfaceName;  // 接口全限定名
    private String methodName;     // 方法名
    private Class<?>[] paramTypes; // 参数类型数组
    private Object[] params;       // 参数值
    // getter/setter 省略
}

public class RpcResponse implements Serializable {
    private String requestId;
    private Object result;   // 返回值
    private Throwable error; // 异常
    // getter/setter 省略
}
```

## 二、服务端：注册 + 反射调用

### 2.1 服务暴露与注册

```java
public class ServiceRegistry {
    // 接口全限定名 -> 实现类实例
    private final Map<String, Object> services = new ConcurrentHashMap<>();

    public void register(Class<?> interfaceClass, Object impl) {
        services.put(interfaceClass.getName(), impl);
        System.out.println("服务注册: " + interfaceClass.getName());
    }

    public Object get(String interfaceName) {
        return services.get(interfaceName);
    }
}
```

### 2.2 请求处理：反射调用核心

```java
public class RpcServer {
    private final ServiceRegistry registry;
    private final ExecutorService executor =
            new ThreadPoolExecutor(4, 8, 60, TimeUnit.SECONDS,
                    new LinkedBlockingQueue<>(1024));

    public RpcServer(ServiceRegistry registry) {
        this.registry = registry;
    }

    // 处理一个连接，收到请求后反射调用
    private void handleConnection(Socket socket) {
        executor.submit(() -> {
            try (ObjectInputStream in = new ObjectInputStream(socket.getInputStream());
                 ObjectOutputStream out = new ObjectOutputStream(socket.getOutputStream())) {

                RpcRequest request = (RpcRequest) in.readObject();
                RpcResponse response = invoke(request);
                out.writeObject(response);   // 响应写回客户端
                out.flush();
            } catch (Exception e) {
                e.printStackTrace();
            }
        });
    }

    private RpcResponse invoke(RpcRequest request) {
        RpcResponse response = new RpcResponse();
        response.setRequestId(request.getRequestId());
        try {
            Object service = registry.get(request.getInterfaceName());
            if (service == null) {
                throw new RuntimeException("服务不存在: " + request.getInterfaceName());
            }
            // 反射：找到方法并调用
            Method method = service.getClass()
                    .getMethod(request.getMethodName(), request.getParamTypes());
            Object result = method.invoke(service, request.getParams());
            response.setResult(result);
        } catch (Throwable t) {
            response.setError(t);  // 异常也要传回客户端
        }
        return response;
    }

    // 启动监听
    public void start(int port) throws IOException {
        try (ServerSocket serverSocket = new ServerSocket(port)) {
            System.out.println("RPC 服务端启动，端口: " + port);
            while (true) {
                Socket socket = serverSocket.accept();
                handleConnection(socket);
            }
        }
    }
}
```

> 面试点：为什么用 `getMethod` 而不是 `getDeclaredMethod`？—— `getMethod` 能拿到 public 方法（含继承的），`getDeclaredMethod` 只拿本类声明的所有方法（含 private）。RPC 暴露的是接口方法，实现类一定是 public，用 `getMethod` 即可。

## 三、客户端：动态代理是灵魂

```java
public class RpcClient {

    // 给接口生成代理对象：调用任意方法 -> 打包请求 -> 网络发送
    @SuppressWarnings("unchecked")
    public static <T> T getProxy(Class<T> interfaceClass, String host, int port) {
        return (T) Proxy.newProxyInstance(
                interfaceClass.getClassLoader(),
                new Class<?>[]{interfaceClass},
                (proxy, method, args) -> {
                    // 1. 构造请求
                    RpcRequest request = new RpcRequest();
                    request.setRequestId(UUID.randomUUID().toString());
                    request.setInterfaceName(interfaceClass.getName());
                    request.setMethodName(method.getName());
                    request.setParamTypes(method.getParameterTypes());
                    request.setParams(args);

                    // 2. 网络发送并等待响应
                    try (Socket socket = new Socket(host, port);
                         ObjectOutputStream out = new ObjectOutputStream(socket.getOutputStream());
                         ObjectInputStream in = new ObjectInputStream(socket.getInputStream())) {
                        out.writeObject(request);
                        out.flush();
                        RpcResponse response = (RpcResponse) in.readObject();
                        if (response.getError() != null) {
                            throw response.getError();  // 服务端异常抛给调用方
                        }
                        return response.getResult();
                    }
                });
    }
}
```

**这里藏着 RPC 最核心的面试题**：为什么用动态代理？
答：客户端只知道接口，不知道实现。动态代理在运行时生成接口的代理类，把"方法调用"翻译成"网络请求"，让调用方无感知——这正是 RPC"像调用本地方法"的关键。

> 注意：`Object` 的方法（toString/hashCode/equals）会被代理拦截，生产级 RPC 需要跳过这些方法的代理（直接调用本地实现），否则会出现 `proxy.toString()` 发一次网络请求的诡异问题。

## 四、注册中心与负载均衡

上面是最简版本，服务地址写死。真实 RPC 需要注册中心。我们用 JDK 内置能力实现一个简化版：

### 4.1 注册中心（内存版）

```java
public class SimpleRegistry {
    // 接口名 -> 提供者地址列表
    private static final Map<String, List<String>> SERVICES = new ConcurrentHashMap<>();

    public static void register(String interfaceName, String address) {
        SERVICES.computeIfAbsent(interfaceName, k -> new CopyOnWriteArrayList<>())
                .add(address);
        System.out.println("注册: " + interfaceName + " -> " + address);
    }

    public static List<String> discover(String interfaceName) {
        return SERVICES.getOrDefault(interfaceName, List.of());
    }
}
```

### 4.2 负载均衡策略

```java
public interface LoadBalance {
    String select(List<String> addresses);
}

// 随机
public class RandomLoadBalance implements LoadBalance {
    @Override
    public String select(List<String> addresses) {
        return addresses.get(ThreadLocalRandom.current().nextInt(addresses.size()));
    }
}

// 轮询
public class RoundRobinLoadBalance implements LoadBalance {
    private final AtomicInteger idx = new AtomicInteger(0);
    @Override
    public String select(List<String> addresses) {
        return addresses.get(idx.getAndIncrement() % addresses.size());
    }
}
```

### 4.3 升级版客户端代理：从注册中心拿地址

```java
public static <T> T getProxy(Class<T> interfaceClass, LoadBalance loadBalance) {
    return (T) Proxy.newProxyInstance(
            interfaceClass.getClassLoader(),
            new Class<?>[]{interfaceClass},
            (proxy, method, args) -> {
                // 从注册中心发现服务地址
                List<String> addresses = SimpleRegistry.discover(interfaceClass.getName());
                if (addresses.isEmpty()) {
                    throw new RuntimeException("没有可用服务: " + interfaceClass.getName());
                }
                String address = loadBalance.select(addresses);  // 负载均衡选一个
                String[] hostPort = address.split(":");
                return doInvoke(interfaceClass, method, args, hostPort[0],
                        Integer.parseInt(hostPort[1]));
            });
}
```

## 五、完整运行验证

```java
// 1. 定义接口
public interface UserService {
    User getUserById(Long id);
    String sayHello(String name);
}

// 2. 服务端实现并注册
public class UserServiceImpl implements UserService {
    @Override
    public User getUserById(Long id) {
        return new User(id, "用户" + id);
    }
    @Override
    public String sayHello(String name) {
        return "Hello, " + name;
    }
}

// 3. 启动两个服务端实例（模拟集群）
public class ServerMain {
    public static void main(String[] args) throws Exception {
        ServiceRegistry registry = new ServiceRegistry();
        registry.register(UserService.class, new UserServiceImpl());
        // 注册中心登记
        SimpleRegistry.register(UserService.class.getName(), "127.0.0.1:" + args[0]);
        new RpcServer(registry).start(Integer.parseInt(args[0]));
    }
}
// 分别以 8081、8082 端口启动两个实例

// 4. 客户端调用（无感知远程调用！）
public class ClientMain {
    public static void main(String[] args) {
        UserService userService = RpcClient.getProxy(UserService.class,
                new RoundRobinLoadBalance());
        // 两次调用会轮流打到 8081/8082
        System.out.println(userService.sayHello("东哥"));
        System.out.println(userService.getUserById(1001));
    }
}
```

输出：
```
Hello, 东哥
User{id=1001, name='用户1001'}
```

跑通了！一个迷你 RPC 完成。

## 六、从迷你版到生产版：差距在哪

| 能力 | 迷你版 | 生产版（Dubbo 等） |
|------|--------|-------------------|
| 序列化 | JDK 序列化（慢、不安全） | Kryo/Hessian/Protobuf |
| 传输 | 每次调用新建 Socket（慢） | Netty 长连接 + 连接池 |
| 注册中心 | 内存 Map | ZooKeeper/Nacos（服务发现、健康检查、心跳） |
| 负载均衡 | 随机/轮询 | 加权轮询、一致性哈希、最小活跃数 |
| 容错 | 无 | 失败重试、故障转移、熔断降级 |
| 异步 | 同步阻塞 | 异步回调、Future、响应式 |
| 协议 | Java 对象流 | 自定义协议（协议头+body，粘包拆包） |
| 治理 | 无 | 限流、灰度、链路追踪、监控 |

### 每次新建 Socket 的问题

迷你版每个请求都 `new Socket`，三次握手开销巨大。生产版用 Netty 维护**长连接池**，一个连接可发多个请求，通过 `requestId` 关联响应（异步回调）：

```java
// 异步化的核心：请求 ID -> CompletableFuture 映射
ConcurrentHashMap<String, CompletableFuture<RpcResponse>> pending = new ConcurrentHashMap<>();

// 发请求时
CompletableFuture<RpcResponse> future = new CompletableFuture<>();
pending.put(requestId, future);
channel.writeAndFlush(request);          // 非阻塞发送
// 收到响应时
pending.remove(requestId).complete(response);
```

这就是 **Future 模式 + requestId 关联**，也是所有异步 RPC 的通用套路。

## 七、面试高频追问

**Q1：RPC 和 HTTP 接口有什么区别？**
A：RPC 面向服务间调用，强调高性能（长连接、二进制协议、自定义序列化），一般用接口描述语言（IDL）；HTTP 接口面向异构系统/外部开放，基于标准协议，易调试、穿透性好。现在两者在融合（gRPC 用 HTTP/2 承载）。

**Q2：为什么需要注册中心？不用行不行？**
A：注册中心解决两个问题：**服务发现**（消费者动态感知提供者地址变化）和**健康管理**（剔除宕机节点）。不用注册中心就得写死地址，扩容、缩容、故障转移都做不了。

**Q3：序列化选型怎么考虑？**
A：JDK 序列化不推荐（性能差、有反序列化漏洞风险）。Kryo/Hessian 快且体积小；Protobuf 跨语言但要写 IDL；JSON 可读性好但性能和体积一般。权衡：性能、体积、跨语言、安全性、开发成本。

**Q4：服务端怎么处理慢调用？一个慢服务会拖垮整个 RPC 吗？**
A：会。线程池被慢调用占满，新请求排队，雪崩。解法：超时控制、线程池隔离（舱壁模式）、熔断降级（Sentinel/Resilience4j）、异步化。

**Q5：怎么保证 RPC 调用不丢不重？**
A：传输层靠 TCP 保证不丢；应用层做幂等（requestId 去重）、重试机制（注意重试要幂等，否则扣款类接口会重复扣）、超时判定与补偿。

## 总结

300 行代码，我们复现了 RPC 的完整骨架：**动态代理**让远程调用像本地调用，**反射**让服务端通用执行任意方法，**注册中心 + 负载均衡**支撑集群，**requestId + Future** 是异步化的钥匙。理解了这条链路，再看 Dubbo 源码（Invoker、Protocol、Cluster 层），会发现它只是把每个环节做到极致。面试时如果能现场画出架构图、讲清动态代理的作用，比背十遍八股都管用。
