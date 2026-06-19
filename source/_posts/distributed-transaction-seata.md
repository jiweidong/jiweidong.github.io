---
title: 分布式事务解决方案深度解析：Seata、TCC与Saga实战
date: 2026-06-17 08:02:00
tags:
  - 分布式事务
  - Seata
  - TCC
  - Saga
  - 微服务
categories: 分布式系统
author: 东哥
---

# 分布式事务解决方案深度解析：Seata、TCC与Saga实战

## 一、分布式事务的困境

在单体应用中，数据库ACID事务保证了数据一致性。但在微服务架构下，一个业务操作可能涉及多个服务、多个数据库，传统的本地事务无法跨服务生效。

### 1.1 典型场景：订单创建

```
下单操作涉及：
用户服务 → 扣减余额
订单服务 → 创建订单
库存服务 → 扣减库存
积分服务 → 增加积分
```

任何一个步骤失败，都需要撤销前面的操作。这就是分布式事务要解决的核心问题。

### 1.2 CAP理论与BASE理论

| 理论 | 核心内容 | 适用场景 |
|------|---------|---------|
| CAP | 一致性、可用性、分区容忍性不可兼得 | 架构设计权衡 |
| BASE | 基本可用、软状态、最终一致性 | 分布式系统设计 |

## 二、Seata AT模式实战

Seata是阿里巴巴开源的分布式事务解决方案，AT模式是其核心模式，对业务代码侵入最小。

### 2.1 AT模式原理

AT模式通过**两阶段提交**实现：

- **第一阶段（Branch Register）**：执行本地事务，同时记录undo_log
- **第二阶段（Commit/Rollback）**：协调器通知所有分支提交或回滚

```java
// 1. 引入依赖
// <dependency>
//     <groupId>com.alibaba.cloud</groupId>
//     <artifactId>spring-cloud-starter-alibaba-seata</artifactId>
// </dependency>

// 2. 业务代码 - 只需一个注解
@GlobalTransactional(name = "create-order", rollbackFor = Exception.class)
public void createOrder(CreateOrderRequest request) {
    // 扣减余额
    accountService.debit(request.getUserId(), request.getAmount());
    
    // 扣减库存
    inventoryService.deduct(request.getProductId(), request.getQuantity());
    
    // 创建订单
    orderService.create(request);
    
    // 增加积分
    pointService.add(request.getUserId(), request.getAmount().intValue() / 10);
}
```

### 2.2 关键配置

```yaml
# application.yml
seata:
  enabled: true
  application-id: order-service
  tx-service-group: default_tx_group
  service:
    vgroup-mapping:
      default_tx_group: default
    grouplist:
      default: 192.168.1.100:8091
  config:
    type: nacos
    nacos:
      server-addr: 192.168.1.100:8848
      group: SEATA_GROUP
  registry:
    type: nacos
    nacos:
      server-addr: 192.168.1.100:8848
      group: SEATA_GROUP
```

### 2.3 undo_log表结构

```sql
CREATE TABLE `undo_log` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `branch_id` bigint(20) NOT NULL,
  `xid` varchar(100) NOT NULL,
  `context` varchar(128) NOT NULL,
  `rollback_info` longblob NOT NULL,
  `log_status` int(11) NOT NULL,
  `log_created` datetime NOT NULL,
  `log_modified` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `ux_undo_log` (`xid`, `branch_id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;
```

## 三、TCC模式实战

TCC是Try-Confirm-Cancel的缩写，需要业务方提供三个接口。

### 3.1 TCC接口定义

```java
public interface AccountTccService {
    
    /**
     * Try阶段：预留资源
     * 冻结用户资金，但不实际扣减
     */
    @TwoPhaseBusinessAction(
        name = "accountTccAction",
        confirmMethod = "confirm",
        cancelMethod = "cancel"
    )
    void prepare(@BusinessActionContextParameter(paramName = "userId") Long userId,
                 @BusinessActionContextParameter(paramName = "amount") BigDecimal amount);
    
    /**
     * Confirm阶段：确认执行
     * 将冻结资金正式扣减
     */
    boolean confirm(BusinessActionContext context);
    
    /**
     * Cancel阶段：取消执行
     * 释放冻结资金
     */
    boolean cancel(BusinessActionContext context);
}
```

### 3.2 实现示例

```java
@Service
@Slf4j
public class AccountTccServiceImpl implements AccountTccService {
    
    @Autowired
    private AccountMapper accountMapper;
    
    @Override
    public void prepare(Long userId, BigDecimal amount) {
        log.info("TCC Try: 冻结用户{}金额{}", userId, amount);
        
        // 检查账户余额
        Account account = accountMapper.selectById(userId);
        if (account.getBalance().compareTo(amount) < 0) {
            throw new BusinessException("余额不足");
        }
        
        // 冻结金额（业务层面冻结）
        accountMapper.freezeBalance(userId, amount);
    }
    
    @Override
    public boolean confirm(BusinessActionContext context) {
        Long userId = Long.parseLong(context.getActionContext("userId").toString());
        BigDecimal amount = new BigDecimal(context.getActionContext("amount").toString());
        
        log.info("TCC Confirm: 确认扣减用户{}金额{}", userId, amount);
        
        // 实际扣减：将冻结金额转为实际扣减
        accountMapper.confirmDeduct(userId, amount);
        return true;
    }
    
    @Override
    public boolean cancel(BusinessActionContext context) {
        Long userId = Long.parseLong(context.getActionContext("userId").toString());
        BigDecimal amount = new BigDecimal(context.getActionContext("amount").toString());
        
        log.info("TCC Cancel: 释放用户{}冻结金额{}", userId, amount);
        
        // 释放冻结金额
        accountMapper.unfreezeBalance(userId, amount);
        return true;
    }
}
```

### 3.3 TCC vs AT模式对比

| 维度 | AT模式 | TCC模式 |
|------|-------|---------|
| 侵入性 | 低（注解即可） | 高（需实现三个接口） |
| 性能 | 较低（需要undo_log） | 高（无额外日志） |
| 一致性 | 最终一致性 | 强一致性 |
| 隔离性 | 全局锁保证 | 业务层面保证 |
| 适用场景 | 简单事务场景 | 高性能要求场景 |

## 四、Saga模式实战

Saga模式适用于长事务场景，通过补偿事务来实现回滚。

### 4.1 Saga编排模式

```java
// 基于Spring Boot的Saga编排
@Configuration
public class SagaConfig {
    
    @Bean
    public SagaOrchestrator sagaOrchestrator() {
        return SagaOrchestrator.create()
            .step("deduct-inventory")
            .invoke(inventoryService::deduct)
            .withCompensation(inventoryService::compensateDeduct)
            .step("create-order")
            .invoke(orderService::create)
            .withCompensation(orderService::cancel)
            .step("deduct-account")
            .invoke(accountService::debit)
            .withCompensation(accountService::compensateDebit)
            .step("add-points")
            .invoke(pointService::add)
            .withCompensation(pointService::compensateAdd)
            .build();
    }
}

// 使用Saga
@Service
public class OrderService {
    
    @Autowired
    private SagaOrchestrator sagaOrchestrator;
    
    public void createOrder(OrderRequest request) {
        SagaExecutionResult result = sagaOrchestrator.execute(request);
        
        if (result.isFailed()) {
            // Saga已自动执行补偿
            log.error("订单创建失败，已回滚: {}", result.getError());
            throw new BusinessException("订单创建失败");
        }
    }
}
```

### 4.2 状态机Saga（Apache ServiceComb）

```yaml
# saga-definition.yaml
name: order-saga
version: 1.0.0
states:
  - name: start
    type: START
    transition: deduct-inventory
  
  - name: deduct-inventory
    type: SERVICE
    service: inventory-service
    function: deduct
    retry: 3
    retryDelay: 1000
    compensation:
      service: inventory-service
      function: compensateDeduct
    transition: create-order
    catch: compensate-inventory
  
  - name: create-order
    type: SERVICE
    service: order-service
    function: create
    compensation:
      service: order-service
      function: cancel
    transition: deduct-account
    catch: compensate-order
  
  - name: deduct-account
    type: SERVICE
    service: account-service
    function: debit
    compensation:
      service: account-service
      function: compensateDebit
    transition: add-points
    catch: compensate-account
  
  - name: add-points
    type: SERVICE
    service: point-service
    function: add
    transition: end
    catch: compensate-points
  
  - name: compensate-inventory
    type: COMPENSATION
    transition: fail
  
  - name: compensate-order
    type: COMPENSATION
    transition: compensate-inventory
  
  - name: compensate-account
    type: COMPENSATION
    transition: compensate-order
  
  - name: compensate-points
    type: COMPENSATION
    transition: compensate-account
  
  - name: end
    type: END
    status: SUCCESS
  
  - name: fail
    type: END
    status: FAILED
```

## 五、消息队列实现最终一致性

除了框架方案，消息队列结合本地事件表也是常见的最终一致性方案。

```java
// 本地事件表方案
@Service
public class OrderService {
    
    @Autowired
    private OrderMapper orderMapper;
    
    @Autowired
    private EventPublisher eventPublisher;
    
    @Transactional
    public void createOrder(OrderRequest request) {
        // 1. 创建订单
        Order order = new Order();
        order.setUserId(request.getUserId());
        order.setAmount(request.getAmount());
        order.setStatus(OrderStatus.CREATED);
        orderMapper.insert(order);
        
        // 2. 写入本地事件表（同一事务）
        EventMessage event = new EventMessage();
        event.setType("ORDER_CREATED");
        event.setContent(JSON.toJSONString(order));
        event.setStatus(EventStatus.PENDING);
        eventMapper.insert(event);
    }
    
    @Scheduled(fixedDelay = 5000)
    @Transactional
    public void publishPendingEvents() {
        List<EventMessage> pendingEvents = eventMapper.selectPendingEvents();
        
        for (EventMessage event : pendingEvents) {
            try {
                // 发送到消息队列
                eventPublisher.publish(event.getType(), event.getContent());
                
                // 标记已发送
                event.setStatus(EventStatus.PUBLISHED);
                eventMapper.updateById(event);
            } catch (Exception e) {
                log.error("事件发送失败: {}", event.getId(), e);
                // 下次重试
            }
        }
    }
}
```

## 六、方案选型建议

| 方案 | 一致性 | 性能 | 复杂度 | 适用场景 |
|------|-------|------|-------|---------|
| Seata AT | 强 | 中 | 低 | 简单事务、少量服务 |
| TCC | 强 | 高 | 高 | 高性能核心交易 |
| Saga | 最终 | 高 | 中 | 长事务、跨很多服务 |
| 本地消息表 | 最终 | 高 | 中 | 非关键路径、异步场景 |
| MQ事务消息 | 最终 | 高 | 低 | 简单异步场景 |

## 七、总结

分布式事务没有银弹。选择哪种方案取决于业务场景对一致性、性能和复杂度的权衡。如果业务允许最终一致性，优先选择消息队列或Saga模式；如果要求强一致性且并发量不大，Seata AT是最简单的方式；如果追求极致性能且能接受代码复杂度，TCC方案是最佳选择。关键是要理解每种方案的原理和代价，做出合理的技术决策。
