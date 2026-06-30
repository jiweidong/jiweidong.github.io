---
title: 【微服务】Spring Cloud LoadBalancer 源码解析：从 RestTemplate 到 WebClient 的负载均衡
date: 2026-06-30 08:15:00
tags:
  - Java
  - Spring Cloud
  - 负载均衡
categories:
  - Spring Cloud
  - 微服务
author: 东哥
---

# 【微服务】Spring Cloud LoadBalancer 源码解析：从 RestTemplate 到 WebClient 的负载均衡

## 一、为什么从 Ribbon 换到 LoadBalancer？

Spring Cloud 早期的负载均衡方案是 **Netflix Ribbon**，但在 Spring Cloud 2020.0.0（Ilford）之后，Ribbon 进入**维护模式**，官方推荐使用 **Spring Cloud LoadBalancer**。

| 对比维度 | Netflix Ribbon（已废弃） | Spring Cloud LoadBalancer |
|---------|------------------------|--------------------------|
| 维护状态 | 仅维护，不开发新功能 | 活跃维护 |
| 实现语言 | Java | 纯 Spring 生态 |
| 支持 Reactive | 不支持 | 原生支持（WebClient + Reactor） |
| 负载策略 | 7种内置 | 3种内置，可扩展 |
| 健康检查 | 需额外配置 | 集成 Spring 健康检查 |
| 配置复杂度 | 较重 | 轻量，自动配置 |

核心优势：**Spring Cloud LoadBalancer 是 Spring 官方实现，更轻量、与 Spring 生态集成更好，且原生支持响应式编程。**

---

## 二、快速入门

### 2.1 添加依赖

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-loadbalancer</artifactId>
</dependency>
```

对于 Spring Cloud 2022.0.x（及以后版本），加上 Nacos/Eureka 的服务发现后，无需额外配置即可使用。

### 2.2 三种调用方式

```java
// 方式一：@LoadBalanced RestTemplate
@Configuration
public class BeanConfig {
    @Bean
    @LoadBalanced  // 关键！让 RestTemplate 具备负载均衡能力
    public RestTemplate restTemplate() {
        return new RestTemplate();
    }
}

@Service
public class OrderService {
    @Autowired
    private RestTemplate restTemplate;
    
    public User getUser(Long userId) {
        // 使用服务名（不是 IP！）
        return restTemplate.getForObject("http://user-service/users/" + userId, User.class);
    }
}
```

```java
// 方式二：WebClient.Builder
@Configuration
public class WebClientConfig {
    @Bean
    @LoadBalanced
    public WebClient.Builder webClientBuilder() {
        return WebClient.builder();
    }
}

// 使用
@Service
public class ReactiveOrderService {
    @Autowired
    private WebClient.Builder webClientBuilder;
    
    public Mono<User> getUser(Long userId) {
        return webClientBuilder.build()
            .get()
            .uri("http://user-service/users/" + userId)
            .retrieve()
            .bodyToMono(User.class);
    }
}
```

```java
// 方式三：WebClient（功能式，Spring Cloud 2020+）
@Service
public class FunctionalOrderService {
    
    @Autowired
    private LoadBalancerClient loadBalancerClient;
    
    public String callService(String serviceId, String path) {
        RequestData request = RequestData.create(
            HttpMethod.GET,
            URI.create("http://" + serviceId + path),
            new DefaultHttpHeaders());
        
        // 通过 LoadBalancerClient 获取
        return loadBalancerClient.execute(serviceId, request, (clientRequest) -> {
            // 这里拿到的是已经负载均衡后的请求
            return Mono.just(new DefaultResponseData("success", new DefaultHttpHeaders()));
        }).block().getBody();
    }
}
```

---

## 三、源码深度解析

### 3.1 核心接口体系

Spring Cloud LoadBalancer 的核心接口只有 5 个：

```
LoadBalancerClient（客户端入口）
    └── ReactiveLoadBalancer（响应式负载均衡器接口）
         └── LoadBalancer（负载均衡策略接口）
              ├── RoundRobinLoadBalancer（轮询）
              ├── RandomLoadBalancer（随机）
              └── 自定义实现
```

### 3.2 拦截器机制的实现

`@LoadBalanced` 注解是如何让 RestTemplate 具备负载均衡能力的？

关键：**LoadBalancerInterceptor**

```java
// LoadBalancerInterceptor 实现了 ClientHttpRequestInterceptor
public class LoadBalancerInterceptor implements ClientHttpRequestInterceptor {
    
    private final LoadBalancerClient loadBalancer;
    
    @Override
    public ClientHttpResponse intercept(HttpRequest request, byte[] body, 
                                         ClientHttpRequestExecution execution) {
        URI originalUri = request.getURI();
        String serviceId = originalUri.getHost();  // "user-service"
        
        // 核心：交给 LoadBalancerClient 处理
        return this.loadBalancer.execute(serviceId, request, body, execution);
    }
}
```

**注册拦截器的流程：**

```
@LoadBalanced 注解
    ↓
LoadBalancerAutoConfiguration 发现被 @LoadBalanced 修饰的 RestTemplate Bean
    ↓
为每个这样的 RestTemplate 添加 LoadBalancerInterceptor 到拦截器列表
    ↓
RestTemplate 发起请求时，先走拦截器 → 替换服务名为实际 IP:Port
```

### 3.3 核心流程：从服务名到 IP:Port

```java
// LoadBalancerClient.execute() 简化流程
public <T> T execute(String serviceId, HttpRequest request, byte[] body,
                     ClientHttpRequestExecution execution) {
    
    // 1. 根据 serviceId 选择具体实例
    ServiceInstance instance = choose(serviceId);
    
    // 2. 用实例的 IP:Port 替换原始 URI 中的服务名
    URI originalUri = request.getURI();
    URI newUri = LoadBalancerURIUtils.reconstructURI(instance, originalUri);
    // 例如：http://user-service/users/1 → http://192.168.1.10:8080/users/1
    
    // 3. 用真实 URI 执行 HTTP 请求
    HttpRequest newRequest = new ServiceRequestWrapper(request, newUri, this.loadBalancer);
    return execution.execute(newRequest, body);
}

// 选择实例
protected ServiceInstance choose(String serviceId) {
    // 获取该服务的所有可用实例
    List<ServiceInstance> instances = discoveryClient.getInstances(serviceId);
    
    // 用负载均衡策略选一个
    Response<ServiceInstance> response = loadBalancer.choose(serviceId);
    return response.getServer();
}
```

### 3.4 内置策略源码对比

**RoundRobinLoadBalancer（轮询）：**

```java
public class RoundRobinLoadBalancer implements ReactorServiceInstanceLoadBalancer {
    
    private final AtomicInteger position = new AtomicInteger(0);
    
    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        // 获取所有实例
        Flux<ServiceInstance> instances = discoveryClient.getInstances(serviceId);
        
        return instances.collectList().map(instanceList -> {
            if (instanceList.isEmpty()) {
                return new EmptyResponse();
            }
            // 核心：原子自增取模
            int pos = this.position.incrementAndGet() % instanceList.size();
            ServiceInstance instance = instanceList.get(pos);
            return new DefaultResponse(instance);
        });
    }
}
```

**RandomLoadBalancer（随机）：**

```java
public class RandomLoadBalancer implements ReactorServiceInstanceLoadBalancer {
    
    private final Random random = new Random();
    
    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        return instances.collectList().map(instanceList -> {
            if (instanceList.isEmpty()) {
                return new EmptyResponse();
            }
            // 核心：随机选取
            int index = random.nextInt(instanceList.size());
            return new DefaultResponse(instanceList.get(index));
        });
    }
}
```

### 3.5 WebClient 的负载均衡原理

对于 WebClient（响应式），不再使用拦截器，而是通过 **ExchangeFilterFunction** 实现：

```java
// LoadBalancerExchangeFilterFunction（简化）
public class LoadBalancerExchangeFilterFunction implements ExchangeFilterFunction {
    
    private final LoadBalancerClient loadBalancerClient;
    
    @Override
    public Mono<ClientResponse> filter(ClientRequest request, ExchangeFunction next) {
        URI uri = request.url();
        String serviceId = uri.getHost();
        
        return loadBalancerClient
            .choose(serviceId)  // 选择实例（Reactive 方式）
            .flatMap(instance -> {
                // 替换 URI 中的服务名为真实 IP:Port
                URI newUri = reconstructURI(instance, uri);
                ClientRequest newRequest = ClientRequest.from(request)
                    .url(newUri)
                    .build();
                return next.exchange(newRequest);
            });
    }
}
```

---

## 四、自定义负载均衡策略

### 4.1 实现自定义策略（按权重+最少连接）

```java
public class WeightedLeastConnectionsLoadBalancer 
        implements ReactorServiceInstanceLoadBalancer {
    
    private final String serviceId;
    private final ObjectProvider<LoadBalancerClient> loadBalancerClientProvider;
    
    @Override
    public Mono<Response<ServiceInstance>> choose(Request request) {
        return Mono.from(discoveryClient.getInstances(serviceId))
            .collectList()
            .map(instances -> {
                if (instances.isEmpty()) return new EmptyResponse();
                
                // 按权重计算选择概率
                double totalWeight = instances.stream()
                    .mapToDouble(this::getWeight)
                    .sum();
                double random = ThreadLocalRandom.current().nextDouble(totalWeight);
                double cumulativeWeight = 0;
                
                for (ServiceInstance instance : instances) {
                    cumulativeWeight += getWeight(instance);
                    if (random <= cumulativeWeight) {
                        return new DefaultResponse(instance);
                    }
                }
                return new DefaultResponse(instances.get(0));
            });
    }
    
    // 从元数据获取权重（如 user-service 配置了不同实例的权重）
    private double getWeight(ServiceInstance instance) {
        String weightStr = instance.getMetadata().get("weight");
        return weightStr != null ? Double.parseDouble(weightStr) : 1.0;
    }
}
```

### 4.2 注册自定义策略

```java
@Configuration
public class LoadBalancerConfig {
    
    @Bean
    public ReactorLoadBalancer<ServiceInstance> reactorServiceInstanceLoadBalancer(
            Environment environment, LoadBalancerClientFactory loadBalancerClientFactory) {
        String name = environment.getProperty(LoadBalancerClientFactory.PROPERTY_NAME);
        return new WeightedLeastConnectionsLoadBalancer(
            name, loadBalancerClientFactory.getLazyProvider(name, LoadBalancerClient.class));
    }
}
```

### 4.3 为不同服务配置不同策略

```java
// 为 user-service 启用自定义策略
@Configuration
@LoadBalancerClient(name = "user-service", configuration = UserServiceLoadBalancerConfig.class)
public class UserServiceLoadBalancerConfig {
    
    @Bean
    public ReactorLoadBalancer<ServiceInstance> userServiceLoadBalancer(
            Environment environment, LoadBalancerClientFactory factory) {
        return new RandomLoadBalancer(
            factory.getLazyProvider(environment.getProperty(PROPERTY_NAME), 
                ServiceInstanceListSupplier.class), 
            environment.getProperty(PROPERTY_NAME));
    }
}
```

---

## 五、生产级最佳实践

### 5.1 配置超时与重试

```yaml
# application.yml
spring:
  cloud:
    loadbalancer:
      retry:
        enabled: true
      # 慢启动（防止新启动的实例立即接收大量请求）
      health-check:
        initial-delay: 10s
        refetch-instances-interval: 30s

# 配合 RestTemplate 超时配置
@Bean
@LoadBalanced
public RestTemplate restTemplate() {
    HttpComponentsClientHttpRequestFactory factory = new HttpComponentsClientHttpRequestFactory();
    factory.setConnectTimeout(3000);
    factory.setReadTimeout(5000);
    factory.setConnectionRequestTimeout(2000);
    return new RestTemplate(factory);
}
```

### 5.2 缓存服务实例列表

```yaml
spring:
  cloud:
    loadbalancer:
      cache:
        enabled: true  # 默认开启
        ttl: 30s       # 缓存30秒
        capacity: 1024
```

> 缓存实例列表可以大幅减少每次请求都去注册中心拉取的开销，但在服务动态扩缩容时有短暂的不一致窗口。

### 5.3 同区域优先

```yaml
spring:
  cloud:
    loadbalancer:
      zone: zone-a  # 优先选择同区域的实例
```

实现方式：通过 `ServiceInstanceListSupplier` 的 `getHealthCheck()` 结合实例元数据中的 zone 信息，筛选同区域的实例。

---

## 六、面试常见追问

### Q1：@LoadBalanced 的工作原理是什么？

通过 `LoadBalancerAutoConfiguration` 自动配置类，为所有标注了 `@LoadBalanced` 的 `RestTemplate` Bean 添加 `LoadBalancerInterceptor`。这个拦截器在请求发送前截获，将 URL 中的服务名替换为实际 `IP:Port`。

### Q2：Ribbon 被废弃后，代码迁移到 LoadBalancer 需要注意什么？

1. **配置文件格式不同**：Ribbon 用 `服务名.ribbon.listOfServers`，LoadBalancer 用 `spring.cloud.loadbalancer.config` 配合 `ServiceInstanceListSupplier`
2. **自定义策略接口不同**：从 `IRule` → `ReactorServiceInstanceLoadBalancer`
3. **响应式支持**：LoadBalancer 原生支持，Ribbon 需要额外适配

### Q3：负载均衡和服务发现的关系？

服务发现（Nacos/Eureka）负责**维护可用的服务实例列表**；负载均衡负责**从列表中选一个**。两者分工明确：发现是"有哪些"，均衡是"选哪个"。

---

## 七、总结

Spring Cloud LoadBalancer 作为 Ribbon 的继任者，设计更现代化：

- **响应式原生**：基于 Reactor，天然支持 Spring WebFlux
- **接口简洁**：核心仅 5 个接口，易于扩展
- **与 Spring 生态深度集成**：自动配置、健康检查、缓存等开箱即用
- **配置灵活**：可针对不同服务配置不同策略

> 理解 LoadBalancer 的工作机制，不仅是面试必备，更是微服务架构中排查「请求路由异常」「负载不均衡」等线上问题的基础。
