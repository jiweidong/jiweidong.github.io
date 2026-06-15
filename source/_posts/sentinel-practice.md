---
title: 微服务治理之 Sentinel 限流熔断降级实战
date: 2026-06-15 23:00:00
tags:
  - Sentinel
  - 限流
  - 熔断
  - 降级
  - Spring Cloud
categories:
  - 架构
author: 东哥
---

# 微服务治理之 Sentinel 限流熔断降级实战

> 在微服务架构中，Sentinel 是保障系统稳定性的利器。本文从限流、熔断、降级三大核心功能入手，结合 Spring Cloud 生态，带你掌握 Sentinel 的生产级使用。

## 一、为什么需要 Sentinel

### 1.1 微服务面临的挑战

```
正常流量 → [服务A] → [服务B] → [服务C]
    │                        │
    └── 突发流量导致 A 挂掉 ──┘  ⇒  雪崩效应
```

- **流量突增**：秒杀、促销活动导致流量暴增
- **服务依赖**：单个服务故障可能引发级联故障
- **资源有限**：数据库连接、线程池等资源有限

### 1.2 Sentinel vs Hystrix

| 特性 | Sentinel | Hystrix |
|------|----------|---------|
| 隔离策略 | 信号量隔离 | 线程池隔离/信号量 |
| 熔断降级 | 基于响应时间/异常比例 | 基于失败比率 |
| 实时监控 | 控制台实时监控 | 简略 |
| 配置动态 | 支持（Nacos/APOLLO） | 有限 |
| 流量控制 | 丰富的流控策略 | 不支持 |
| 系统自适应 | 支持（Load/CPU 保护） | 不支持 |

## 二、快速接入

### 2.1 Maven 依赖

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
</dependency>
```

### 2.2 配置

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080   # Sentinel 控制台地址
      eager: true                    # 延迟加载
      datasource:
        ds1:
          nacos:
            server-addr: localhost:8848
            data-id: ${spring.application.name}-sentinel
            group-id: DEFAULT_GROUP
            data-type: json
            rule-type: flow
```

### 2.3 Sentinel 控制台安装

```bash
# 下载启动
java -Dserver.port=8080 -jar sentinel-dashboard-1.8.7.jar
# 访问 http://localhost:8080 (默认 sentinel/sentinel)
```

## 三、流量控制

### 3.1 入门示例

```java
@RestController
public class OrderController {

    @GetMapping("/order/create")
    @SentinelResource(value = "createOrder", 
                      blockHandler = "createOrderBlock")
    public String createOrder(Long userId) {
        return "创建订单成功";
    }

    public String createOrderBlock(Long userId, BlockException e) {
        return "请求频繁，请稍后再试";
    }
}
```

### 3.2 流控模式

```java
// 1. 直接模式：达到阈值直接限流
// 2. 关联模式：关联资源达到阈值时限流
@GetMapping("/order/list")
@SentinelResource(value = "queryOrder", 
                  blockHandler = "queryOrderBlock")
public String queryOrder(@RequestParam(defaultValue = "1") Integer page) {
    return "查询订单列表";
}

// 3. 链路模式：只对指定入口生效
@SentinelResource(value = "doSomething", 
                  entryType = EntryType.IN)
public void doSomething() {
    // 业务逻辑
}
```

### 3.3 流控效果

```yaml
# 规则配置
# 1. 快速失败：直接抛异常
# 2. Warm Up：预热模式（冷启动）
# 3. 排队等待：匀速通过（漏桶算法）

# Warm Up 示例（preview code）
rules:
  - resource: "createOrder"
    grade: 1        # QPS 模式
    count: 1000     # 目标 QPS
    controlBehavior: 1  # Warm Up
    warmUpPeriodSec: 10  # 预热时长
```

## 四、熔断降级

### 4.1 熔断策略

```java
@Service
public class UserService {

    @SentinelResource(value = "getUserById",
                      fallback = "getUserFallback",
                      fallbackClass = UserServiceFallback.class)
    public User getUserById(Long id) {
        if (id == null || id < 0) {
            throw new IllegalArgumentException("参数异常");
        }
        return userMapper.selectById(id);
    }
}

@Component
public class UserServiceFallback implements UserService {

    @Override
    public User getUserById(Long id) {
        return new User().setName("默认用户");
    }
}
```

### 4.2 熔断规则

```java
// 基于响应时间
DegradeRule rule = new DegradeRule("getUserById")
    .setGrade(RuleConstant.DEGRADE_GRADE_RT)  // RT 模式
    .setCount(200)       // 响应时间 > 200ms
    .setTimeWindow(10);  // 熔断时长 10s
DegradeRuleManager.loadRules(Collections.singletonList(rule));

// 基于异常比例
DegradeRule exRule = new DegradeRule("getUserById")
    .setGrade(RuleConstant.DEGRADE_GRADE_EXCEPTION_RATIO) // 异常比例
    .setCount(0.5)       // 异常比例 > 50%
    .setMinRequestAmount(5)   // 最小请求数
    .setStatIntervalMs(1000)  // 统计时长
    .setTimeWindow(10);
```

### 4.3 熔断状态机

```
Closed (关闭)
   │
   ├── 请求失败率 > 阈值 → Open (开启)
   │
 Open (开启, 请求直接返回 fallback)
   │
   ├── 熔断时长过后 → Half-Open (半开)
   │
 Half-Open (半开, 试探一个请求)
   │
   ├── 成功 → Closed
   └── 失败 → Open (重新熔断)
```

## 五、热点参数限流

```java
@GetMapping("/product/get")
@SentinelResource(value = "getProductById",
                  blockHandler = "hotBlockHandler")
public Product getProductById(
        @RequestParam Long id,
        @RequestParam(required = false) String category) {
    return productService.getById(id);
}

// 热点规则配置
// 对参数 id 进行限流，阈值 100 QPS
// 对特定参数值（如 id=1 热门商品）限流 10 QPS
```

## 六、系统自适应保护

```yaml
# 系统规则（自动调节）
# 支持维度：
#   - Load（系统负载）
#   - CPU usage
#   - 平均 RT
#   - 入口 QPS
#   - 并发线程数

SystemRule rule = new SystemRule()
    .setHighestSystemLoad(10.0)      // Load 阈值
    .setAvgRt(100)                    // 平均 RT 阈值
    .setMaxCpuUsage(0.8);            // CPU 使用率阈值
SystemRuleManager.loadRules(Collections.singletonList(rule));
```

## 七、Spring Cloud Gateway 整合

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/order/**
      default-filters:
        - name: RequestRateLimiter
          args:
            key-resolver: "#{@userKeyResolver}"
            redis-rate-limiter:
              replenishRate: 100
              burstCapacity: 200
```

## 八、生产最佳实践

### 8.1 规则动态配置

```java
@PostConstruct
public void initRules() {
    // 从 Nacos/Appolo 拉取规则
    List<FlowRule> rules = readRulesFromNacos();
    FlowRuleManager.loadRules(rules);
    
    // 监听配置变化
    configListener.addListener(config -> {
        List<FlowRule> newRules = parseRules(config);
        FlowRuleManager.loadRules(newRules);
    });
}
```

### 8.2 监控与告警

```java
// 自定义事件监听
@Component
public class SentinelEventListener
        implements SentinelEventPublisher {

    @EventListener
    public void onBlockEvent(SentinelEvent event) {
        if (event instanceof BlockEvent) {
            // 限流事件：发送告警
            alertService.sendAlert(event.getResource(),
                "触发限流，当前 QPS: " + event.getCount());
        }
    }
}
```

## 九、总结

Sentinel 提供了流量控制、熔断降级、系统保护三大能力，是 Spring Cloud Alibaba 生态的核心组件。相比于 Hystrix，它的功能更丰富、配置更灵活。建议在生产环境搭配 Nacos 实现规则的动态推送，配合 Prometheus + Grafana 实现监控告警。
