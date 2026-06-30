---
title: 【深入Spring】Spring Boot @Scheduled 定时任务深度解析：从注解到分布式调度演进
date: 2026-06-30 08:05:00
tags:
  - Java
  - Spring Boot
  - 定时任务
categories:
  - Java
  - Spring
author: 东哥
---

# 【深入Spring】Spring Boot @Scheduled 定时任务深度解析：从注解到分布式调度演进

## 一、什么是 @Scheduled？

`@Scheduled` 是 Spring 提供的一个方法级别注解，用于声明一个方法应该以**固定频率、固定延迟或 Cron 表达式**来定时执行。它是 Spring 内置调度器的核心入口，无需引入外部依赖，开箱即用。

## 二、快速入门

### 2.1 启用调度

```java
@SpringBootApplication
@EnableScheduling  // 开启定时任务支持
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
```

### 2.2 三种基本用法

```java
@Component
@Slf4j
public class ScheduledTasks {

    // 1. fixedRate：固定频率执行（不考虑上次执行是否完成）
    @Scheduled(fixedRate = 5000)
    public void reportCurrentTime() {
        log.info("当前时间：{}", LocalDateTime.now());
    }

    // 2. fixedDelay：上次执行完成后延迟固定时间再执行
    @Scheduled(fixedDelay = 3000)
    public void processPendingOrders() {
        log.info("处理待处理订单...");
        // 模拟耗时操作
        ThreadUtil.sleep(1000);
    }

    // 3. cron：Cron 表达式
    @Scheduled(cron = "0 0 2 * * ?")  // 每天凌晨2点执行
    public void dailyCleanupTask() {
        log.info("执行每日数据清理...");
    }
}
```

### 2.3 各参数对比

| 属性 | 含义 | 示例 |
|------|------|------|
| `fixedRate` | 固定间隔执行（单位 ms） | `fixedRate = 5000` |
| `fixedDelay` | 上次执行结束后延迟（单位 ms） | `fixedDelay = 5000` |
| `initialDelay` | 首次执行前延迟（单位 ms） | `initialDelay = 10000` |
| `cron` | Cron 表达式 | `cron = "0 0/5 * * * ?"` |
| `zone` | Cron 时区 | `zone = "Asia/Shanghai"` |

> ⚠️ **关键区别**：`fixedRate` 是**不管上次是否完成**，到点就触发；`fixedDelay` 是**等上次跑完再等指定时间**。如果业务逻辑有严格的先后依赖，用 `fixedDelay`。

---

## 三、源码解析：@Scheduled 是怎么工作的？

### 3.1 核心组件

@Scheduled 的执行链路涉及三个核心组件：

```
@EnableScheduling
    ↓
SchedulingConfiguration（自动注册）
    ↓
ScheduledAnnotationBeanPostProcessor（后处理器，扫描 @Scheduled）
    ↓
TaskScheduler（实际执行调度）
    ↓
线程池 + ScheduledExecutorService（JDK 层面执行）
```

### 3.2 扫描与注册流程

`ScheduledAnnotationBeanPostProcessor.postProcessAfterInitialization()` 扫描每个 Bean 中标记了 `@Scheduled` 的方法：

```java
// 简化后的核心逻辑
protected void processScheduled(Scheduled scheduled, Method method, Object bean) {
    Runnable task = new ScheduledMethodRunnable(bean, method);
    
    if (scheduled.cron() != null) {
        // 解析 cron 表达式 -> CronTrigger
        CronTrigger trigger = new CronTrigger(scheduled.cron(), timeZone);
        // 注册到 ScheduledTaskRegistrar
        tasks.add(this.registrar.scheduleCronTask(new CronTask(task, trigger)));
    }
    else if (scheduled.fixedRate() > 0) {
        // fixedRate 使用 ScheduledExecutorService.scheduleAtFixedRate
        tasks.add(this.registrar.scheduleFixedRateTask(
            new IntervalTask(task, scheduled.fixedRate(), scheduled.initialDelay())));
    }
    else if (scheduled.fixedDelay() > 0) {
        // fixedDelay 使用 ScheduledExecutorService.scheduleWithFixedDelay
        tasks.add(this.registrar.scheduleFixedDelayTask(
            new IntervalTask(task, scheduled.fixedDelay(), scheduled.initialDelay())));
    }
}
```

### 3.3 TaskScheduler 的选择

Spring 默认使用 `ThreadPoolTaskScheduler`，其内部封装了 JDK 的 `ScheduledThreadPoolExecutor`：

```java
// ThreadPoolTaskScheduler 初始化
public class ThreadPoolTaskScheduler extends ExecutorConfigurationSupport implements TaskScheduler {
    private ScheduledExecutorService scheduledExecutor;
    
    @Override
    protected void initializeExecutor(ThreadFactory threadFactory, RejectedExecutionHandler rejectedHandler) {
        this.scheduledExecutor = createExecutor(this.poolSize, threadFactory, rejectedHandler);
    }
    
    protected ScheduledExecutorService createExecutor(int poolSize, ThreadFactory threadFactory, 
                                                       RejectedExecutionHandler rejectedHandler) {
        return new ScheduledThreadPoolExecutor(poolSize, threadFactory, rejectedHandler);
    }
}
```

### 3.4 线程模型：一个重要的坑

来看一个经典问题：

```java
@Component
public class Tasks {
    @Scheduled(fixedRate = 3000)
    public void taskA() {
        log.info("TaskA 开始");
        ThreadUtil.sleep(10000);  // 耗时10秒
        log.info("TaskA 结束");
    }
    
    @Scheduled(fixedRate = 3000)
    public void taskB() {
        log.info("TaskB 执行");
    }
}
```

**预期**：taskA 每3秒执行一次，taskB 每3秒执行一次。

**实际**：taskA 每3秒触发、但前一次还没跑完所以会等它结束再跑下一轮；而 **taskB 也要等 taskA 跑完才能执行**。

> 原因：默认的 `ThreadPoolTaskScheduler` 的 `poolSize = 1`，所有 @Scheduled 方法共享一个线程！

**解决方案**：

```java
@Configuration
public class SchedulerConfig implements SchedulingConfigurer {
    @Override
    public void configureTasks(ScheduledTaskRegistrar taskRegistrar) {
        ThreadPoolTaskScheduler scheduler = new ThreadPoolTaskScheduler();
        scheduler.setPoolSize(5);  // 设置为5个线程
        scheduler.setThreadNamePrefix("scheduled-task-");
        scheduler.setWaitForTasksToCompleteOnShutdown(true);
        scheduler.setAwaitTerminationSeconds(30);
        scheduler.initialize();
        taskRegistrar.setTaskScheduler(scheduler);
    }
}
```

---

## 四、Cron 表达式详解

### 4.1 格式

```
秒 分 时 日 月 周
```

| 位置 | 含义 | 取值范围 |
|------|------|---------|
| 1 | 秒（Seconds） | 0-59 |
| 2 | 分钟（Minutes） | 0-59 |
| 3 | 小时（Hours） | 0-23 |
| 4 | 日（Day-of-Month） | 1-31 |
| 5 | 月（Month） | 1-12 |
| 6 | 星期（Day-of-Week） | 1-7（1 = SUN）或 SUN-SAT |

### 4.2 常用示例

| 表达式 | 说明 |
|--------|------|
| `0 0 2 * * ?` | 每天凌晨2点 |
| `0 0/5 * * * ?` | 每5分钟 |
| `0 0 9-18 * * ?` | 每天9点到18点每小时 |
| `0 0 2 ? * MON-FRI` | 工作日凌晨2点 |
| `0 0 2 1 * ?` | 每月1号凌晨2点 |
| `0 0/30 9-17 * * MON-FRI` | 工作日9-17点每半小时 |

> Spring 的 Cron 表达式比标准 Unix cron 多一个**秒**字段，这是常见混淆点。

---

## 五、高级实战技巧

### 5.1 动态修改定时任务

```java
@Component
public class DynamicScheduledTask {
    
    private final TaskScheduler taskScheduler;
    private ScheduledFuture<?> scheduledFuture;
    
    public DynamicScheduledTask(TaskScheduler taskScheduler) {
        this.taskScheduler = taskScheduler;
    }
    
    @PostConstruct
    public void startTask() {
        // 初始每10秒执行
        reschedule("0/10 * * * * ?");
    }
    
    // 动态调整 cron 表达式
    public void reschedule(String cron) {
        if (scheduledFuture != null) {
            scheduledFuture.cancel(false);  // 取消当前任务
        }
        scheduledFuture = taskScheduler.schedule(
            () -> System.out.println("动态任务执行: " + LocalDateTime.now()),
            new CronTrigger(cron)
        );
    }
}
```

> 这在**运营管理系统**中非常实用，比如通过 API 动态调整数据同步频率。

### 5.2 异步定时任务（@Async + @Scheduled）

```java
@Component
@EnableAsync
public class AsyncScheduledTasks {
    
    @Async  // 让每个任务在独立的线程中执行
    @Scheduled(cron = "0 */5 * * * ?")
    public void heavyDataSync() {
        log.info("异步执行数据同步，线程：{}", Thread.currentThread().getName());
        // 不需要等这个方法结束，调度器线程立即返回
    }
}
```

> 原理：`@Async` 让方法在 `AsyncTaskExecutor` 中执行，调度器线程不会被阻塞。

### 5.3 条件执行（跳过节假日）

```java
@Component
public class ConditionalTask {
    
    @Scheduled(cron = "0 0 9 * * ?")
    public void dailyReport() {
        if (isHoliday()) {
            log.info("今天是节假日，跳过日报生成");
            return;
        }
        log.info("生成每日运营报告...");
    }
    
    private boolean isHoliday() {
        LocalDate today = LocalDate.now();
        // 检查节假日配置表
        return holidayService.isHoliday(today);
    }
}
```

### 5.4 记录任务执行状态

```java
@Component
public class MonitoredTask {
    
    @Scheduled(cron = "0 0/1 * * * ?")
    public void monitoredTask() {
        long start = System.currentTimeMillis();
        try {
            // 业务逻辑
            log.info("任务执行成功，耗时：{}ms", System.currentTimeMillis() - start);
            // 上报到 Prometheus
            Metrics.gauge("task_execution_time", System.currentTimeMillis() - start);
        } catch (Exception e) {
            log.error("任务执行失败，耗时：{}ms", System.currentTimeMillis() - start, e);
            Metrics.counter("task_execution_error").increment();
        }
    }
}
```

---

## 六、从单机到分布式

@Scheduled 基于 JDK 的调度 API，天然是**单机、单进程**的。部署多实例时，每个实例都会执行同样的定时任务，导致：

- 数据重复处理
- 资源竞争
- 业务错误（如重复发送通知）

### 6.1 解决方案对比

| 方案 | 原理 | 复杂度 | 适用场景 |
|------|------|--------|---------|
| @Scheduled + Redis分布式锁 | 利用 SETNX 争抢执行权 | 低 | 中小项目 |
| @Scheduled + 数据库行锁 | 数据库唯一锁记录 | 低 | 无 Redis 场景 |
| XXL-Job / Elastic-Job | 调度中心统一分配任务 | 中 | 任务多、逻辑复杂 |
| Quartz 集群模式 | JDBC 存储触发器 | 中 | 已有 Quartz |

### 6.2 Redis 分布式锁示例

```java
@Component
public class DistributedScheduledTask {
    
    @Autowired
    private StringRedisTemplate redisTemplate;
    
    @Scheduled(cron = "0 0 2 * * ?")
    public void dailyCleanup() {
        String lockKey = "task:lock:dailyCleanup";
        String instanceId = UUID.randomUUID().toString();
        
        // 尝试获取锁，10秒自动过期（防止死锁）
        Boolean locked = redisTemplate.opsForValue()
            .setIfAbsent(lockKey, instanceId, Duration.ofSeconds(10));
        
        if (Boolean.TRUE.equals(locked)) {
            try {
                log.info("当前实例获得执行权，开始清理...");
                // 业务逻辑
            } finally {
                // 使用 Lua 脚本释放自己的锁（防止误删别人的锁）
                String luaScript = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";
                redisTemplate.execute(new DefaultRedisScript<>(luaScript, Long.class), 
                    Collections.singletonList(lockKey), instanceId);
            }
        } else {
            log.info("其他实例正在执行，跳过本次");
        }
    }
}
```

---

## 七、面试常见追问

### Q1：@Scheduled 和 Quartz 有什么区别？

| 对比维度 | @Scheduled | Quartz |
|---------|------------|--------|
| 依赖 | 无（Spring 内置） | 需要 Quartz 依赖 |
| 持久化 | 无（内存调度） | 支持 JDBC 持久化 |
| 集群 | 不支持 | 支持集群模式 |
| 调度灵活性 | 固定频率/cron | 支持 misfire 策略、Calendar 排除 |
| 管理界面 | 无 | 提供 Web 管理界面（可选） |
| 适用场景 | 简单定时任务 | 企业级复杂调度 |

### Q2：@Scheduled 默认是单线程吗？为什么？

是的，默认 `poolSize = 1`。Spring 设计者认为大多数场景下任务应该互不依赖，但如果用户需要并发，应该显式配置线程池。这是**安全默认**原则 —— 避免用户无意中引入并发问题。

### Q3：如果 fixedRate = 5000 但任务执行耗时 8 秒，会发生什么？

默认单线程下：第一次任务在第 0 秒开始，执行 8 秒后在第 8 秒结束。第二次任务本应在第 5 秒触发但由于线程被占用，会在第 8 秒（上次结束）立即执行。不会再等 5 秒。

**用公式表述：**
- `fixedRate`：下一次调度时间 = max(上一次开始时间 + fixedRate, 当前时间)
- `fixedDelay`：下一次调度时间 = 上一次结束时间 + fixedDelay

---

## 八、总结

Spring @Scheduled 支持轻量级定时任务，开箱即用，适合绝大多数单机场景。关键要点：

1. **默认单线程**——多任务场景记得配线程池
2. **fixedRate vs fixedDelay**——理解执行时间对调度的影响
3. **Cron 表达式**——Spring 版本多一个秒字段
4. **分布式扩展**——加 Redis 分布式锁即可实现多实例互斥
5. **动态调度**——利用 `TaskScheduler.schedule()` 实现运行时调参

> 从单机的 @Scheduled 到分布式调度框架（XXL-Job、Elastic-Job），核心逻辑都是「谁来做、什么时候做、做完了告诉别人」。理解了底层的 ThreadPoolTaskScheduler，再看分布式调度框架会轻松很多。
