---
title: 【定时调度】Quartz 深度解析：JobStore、Misfire 补偿策略与集群分布式调度原理
date: 2026-10-07 08:20:00
tags:
  - Java
  - Quartz
  - 定时任务
  - 分布式调度
categories:
  - Java
  - 中间件
author: 东哥
---

# 【定时调度】Quartz 深度解析：JobStore、Misfire 补偿策略与集群分布式调度原理

## 面试官：集群部署下，凌晨的对账任务怎么保证只跑一次？

> "你的对账服务部署了 8 个实例，任务要求每天凌晨 1 点触发一次。如果用 `@Scheduled`，会发生什么？"

答案很直接：**8 个实例各跑一遍，对账跑 8 次，数据全乱**。

`@Scheduled` 是**单机**定时器，它不知道集群的存在。要解决"集群只跑一次"，就得引入分布式调度框架：Quartz（数据库锁版本）、Elastic-Job（ZooKeeper/分片）、XXL-Job（中心调度器 + 执行器）。

其中 Quartz 是最经典、也是理解分布式调度原理最好的入口。这一篇从组件模型讲到集群锁，再到 Misfire 补偿，面试高频点全覆盖。

## 一、核心组件模型

```
Scheduler (调度器)
  ├── JobDetail     —— 任务定义：做什么（Job 类 + JobDataMap），JobKey 唯一
  ├── Trigger       —— 触发器：什么时候做（Cron/Simple），TriggerKey 唯一
  ├── JobStore      —— 存储：任务与触发器存哪（RAMJobStore / JobStoreSupport）
  └── ThreadPool    —— 执行线程池（默认 SimpleThreadPool）
```

关系：**一个 JobDetail 可以绑定多个 Trigger，但一个 Trigger 只能绑定一个 JobDetail**。

```java
public class ReconcileJob implements Job {
    @Override
    public void execute(JobExecutionContext ctx) {
        String bizDate = ctx.getMergedJobDataMap().getString("bizDate");
        log.info("开始对账，bizDate={}, fireInstanceId={}",
                bizDate, ctx.getFireInstanceId());
        // 幂等：先抢全局唯一令牌，抢不到直接返回
        if (!reconcileService.tryLock(bizDate)) {
            return;
        }
        reconcileService.reconcile(bizDate);
    }
}
```

调度器装配：

```java
Properties props = new Properties();
props.put("org.quartz.scheduler.instanceId", "AUTO");           // 集群下自动生成实例 ID
props.put("org.quartz.scheduler.instanceName", "ReconcileScheduler");
props.put("org.quartz.threadPool.threadCount", "10");

// 集群必须用 JDBC JobStore，RAMJobStore 无法跨实例协调
props.put("org.quartz.jobStore.class",
        "org.quartz.impl.jdbcjobstore.JobStoreTX");
props.put("org.quartz.jobStore.driverDelegateClass",
        "org.quartz.impl.jdbcjobstore.StdJDBCDelegate");
props.put("org.quartz.jobStore.tablePrefix", "QRTZ_");
props.put("org.quartz.jobStore.isClustered", "true");           // 开启集群
props.put("org.quartz.jobStore.clusterCheckinInterval", "10000"); // 10s 心跳

SchedulerFactory factory = new StdSchedulerFactory(props);
Scheduler scheduler = factory.getScheduler();
scheduler.start();

JobDetail job = JobBuilder.newJob(ReconcileJob.class)
        .withIdentity("reconcile", "finance")
        .usingJobData("bizDate", "2026-10-06")
        .storeDurably()
        .build();

Trigger trigger = TriggerBuilder.newTrigger()
        .withIdentity("reconcile-trigger", "finance")
        .withSchedule(CronScheduleBuilder.cronSchedule("0 0 1 * * ?")
                .withMisfireHandlingInstructionDoNothing())   // 错过的直接跳过
        .build();

scheduler.scheduleJob(job, trigger);
```

## 二、JobStore：调度状态的落地点

| 类型 | 存储 | 集群 | 持久化 | 适用 |
| --- | --- | --- | --- | --- |
| RAMJobStore | 内存 | ❌ | ❌ | 单机、可重建的临时任务 |
| JobStoreTX | JDBC（自管事务） | ✅ | ✅ | 主流，集群首选 |
| JobStoreCMT | JDBC（容器事务） | ✅ | ✅ | 老 J2EE 容器 |

JDBC JobStore 会创建 **11 张 `QRTZ_` 前缀表**，理解它们就理解了 Quartz 的全部状态：

| 表 | 作用 |
| --- | --- |
| `QRTZ_JOB_DETAILS` | 任务定义（Job 类、持久化标志、JobDataMap） |
| `QRTZ_TRIGGERS` | 触发器（下次触发时间、状态、Misfire 策略） |
| `QRTZ_CRON_TRIGGERS` | Cron 表达式与时区 |
| `QRTZ_SIMPLE_TRIGGERS` | 简单触发器（重复次数、间隔） |
| `QRTZ_FIRED_TRIGGERS` | **已触发但未完成的实例**，集群判断"谁在跑"的关键 |
| `QRTZ_PAUSED_TRIGGER_GRPS` | 暂停的触发器组 |
| `QRTZ_SCHEDULER_STATE` | **集群实例心跳**（instance_name + last_checkin_time） |
| `QRTZ_LOCKS` | 悲观锁表（TRIGGER_ACCESS / STATE_ACCESS / CALENDAR_ACCESS） |
| `QRTZ_BLOB_TRIGGERS` | 自定义 Trigger 的序列化 BLOB |
| `QRTZ_CALENDARS` | 排除日历（如节假日不跑） |
| `QRTZ_SIMPROP_TRIGGERS` | 简单属性型 Trigger |

## 三、调度线程模型：谁在"看表"？

Quartz 内部有一组后台线程，最关键的是 **`QuartzSchedulerThread`**：

```
QuartzSchedulerThread 循环：
  1. 加 TRIGGER_ACCESS 锁（数据库行锁）
  2. 查询 30s 内即将触发的 Trigger（acquireNextTriggers）
  3. 把它们写入 FIRED_TRIGGERS，标记状态 ACQUIRED
  4. 释放锁
  5. 到点后交给 ThreadPool 执行 Job
  6. 执行完更新 TRIGGERS.NEXT_FIRE_TIME、删除 FIRED_TRIGGERS
```

**集群去重的秘密就在第 2~3 步**：多个实例都去查同一批待触发 trigger，谁先拿到 `TRIGGER_ACCESS` 行锁、谁先把状态置为 `ACQUIRED`，就只有它能执行。后到的实例看到状态已经是 `ACQUIRED`，就跳过。这就是"**数据库悲观锁 + 状态机**"实现的分布式互斥。

### 集群实例的存活判定

每个实例每 `clusterCheckinInterval`（默认 15s）往 `QRTZ_SCHEDULER_STATE` 写一次心跳。如果某实例的 `last_checkin_time` 超过了 `clusterCheckinInterval + org.quartz.jobStore.clusterCheckinInterval` 的容忍范围，其他实例会认为它挂了，把它持有的 `FIRED_TRIGGERS` 中的任务**恢复（recover）**，交给活着的实例重跑。

因此集群部署有一条铁律：

> **所有实例的时钟必须同步（NTP），否则会把别人正在跑的任务误判为失败并重复执行。**

## 四、Misfire：错过了怎么办？

这是 Quartz 最容易被忽视、也最容易出事故的地方。

**什么叫 Misfire？** 触发器到了该触发的时间，但因为线程池满、实例宕机、调度器被暂停等原因，没能在"合理时间"内执行。Quartz 会检测到 `nextFireTime` 已过期，按策略处理。

### CronTrigger 的 Misfire 策略

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| `withMisfireHandlingInstructionIgnoreMisfires` | 立即补跑所有错过的（可能瞬间打爆） | 几乎不用 |
| `withMisfireHandlingInstructionFireAndProceed`（默认） | 立刻触发一次，然后按原计划继续 | 通用 |
| `withMisfireHandlingInstructionDoNothing` | 不补，等下一个周期 | **对账/报表类首选** |

### SimpleTrigger 的 Misfire 策略

| 策略 | 行为 |
| --- | --- |
| `FireNow` | 立刻补一次，并重置重复计数 |
| `RescheduleNowWithExistingRepeatCount` | 立刻执行，保留剩余次数 |
| `RescheduleNowWithRemainingRepeatCount` | 立刻执行，按剩余次数重新计算间隔 |
| `RescheduleNextWithRemainingCount` | 从下一个周期继续，保留剩余次数 |
| `RescheduleNextWithExistingCount` | 从下一个周期继续，重算总次数 |

### 关键阈值：misfireThreshold

```properties
org.quartz.jobStore.misfireThreshold=60000
```

默认 60s。意思是：**只有"迟到超过 60 秒"才算 Misfire**，60 秒内的延迟属于正常调度抖动。这个值调小会让抖动被当成 Misfire 处理，调大则补跑更迟。经验值：秒级任务 5s，分钟级任务 30~60s。

**真实事故案例**：某报表任务配置了 `IgnoreMisfires`，数据库维护停服 2 小时后重启，Quartz 检测到过去 2 小时有 120 次错过的触发，**瞬间把 120 个任务全部提交线程池**，DB 连接被打满，连带影响线上业务。教训就是：**批处理类任务一律用 `DoNothing`，再用业务层的"补数"机制按天补偿**。

## 五、实战：把"只跑一次"做扎实

Quartz 的数据库锁解决了"同时只有一个人跑"，但**不能解决**"跑了但没跑完"和"重复触发"的问题。生产上必须叠三层防御：

```java
@Component
public class ReconcileJob implements Job {

    @Override
    public void execute(JobExecutionContext ctx) {
        String bizDate = ctx.getMergedJobDataMap().getString("bizDate");
        String lockKey = "reconcile:" + bizDate;

        // 第一层：分布式锁（幂等 + 防重）
        boolean locked = redisLock.tryLock(lockKey, Duration.ofMinutes(30));
        if (!locked) {
            log.warn("已有实例在对账，跳过：{}", bizDate);
            return;
        }
        try {
            // 第二层：状态表断言，已成功则直接跳过（可重入、可回溯）
            ReconcileTask task = taskMapper.findByBizDate(bizDate);
            if (task != null && task.getStatus() == SUCCESS) {
                return;
            }
            taskMapper.upsertRunning(bizDate, ctx.getFireInstanceId());

            // 第三层：业务分批 + 断点续传，避免单次执行超时
            for (String shard : shardList()) {
                reconcileService.doReconcile(bizDate, shard);
            }
            taskMapper.markSuccess(bizDate);
        } catch (Exception e) {
            log.error("对账失败，bizDate={}", bizDate, e);
            taskMapper.markFailed(bizDate, e.getMessage());
            throw e;   // 抛出后以"任务失败"而非"任务成功"结束
        } finally {
            redisLock.unlock(lockKey);
        }
    }
}
```

**注意最后那个 `throw e`**：如果吞掉异常，Quartz 认为执行成功，不会重试也不会告警，问题会被静默。正确做法是让异常上抛，由监听器统一处理：

```java
public class JobFailureListener implements JobListener {
    @Override
    public String getName() { return "JobFailureListener"; }

    @Override
    public void jobExecutionVetoed(JobExecutionContext ctx) { }

    @Override
    public void jobToBeExecuted(JobExecutionContext ctx) { }

    @Override
    public void jobWasExecuted(JobExecutionContext ctx, JobExecutionException ex) {
        if (ex != null) {
            String key = ctx.getJobDetail().getKey().toString();
            alertService.send(AlertLevel.P1, "定时任务失败", key + " : " + ex.getMessage());
        }
    }
}
```

## 六、Quartz vs 现代分布式调度框架

| 维度 | Quartz | Elastic-Job | XXL-Job |
| --- | --- | --- | --- |
| 协调 | 数据库悲观锁 | ZooKeeper | 中心调度器 |
| 分片 | ❌ 需自己实现 | ✅ 原生分片 | ✅ 广播/分片 |
| 控制台 | 弱 | ✅ | ✅ 完善 |
| 失败重试 | 基础 | ✅ | ✅ |
| 运维成本 | 低（只需 DB） | 中（要 ZK） | 中（要部署中心） |
| 适用 | 中小规模、任务不多 | 海量任务、需弹性分片 | 中大型、要可视化 |

**选型建议**：

- 任务 < 100 个、不想引入新中间件 → Quartz + JDBC JobStore；
- 任务多、需要分片和弹性扩容 → Elastic-Job / XXL-Job；
- 云原生 + Kubernetes → 优先考虑 XXL-Job 或直接用 K8s CronJob（但要自己解决幂等）。

## 七、面试追问速查

| 追问 | 回答要点 |
| --- | --- |
| Quartz 集群如何防重复执行？ | `QRTZ_LOCKS` 行锁 + `TRIGGERS` 状态机，抢到 `ACQUIRED` 的实例独占执行 |
| 实例宕机后正在跑的任务会丢吗？ | 不会，`FIRED_TRIGGERS` 有记录，其他实例心跳超时后会 recover 重跑 |
| 为什么集群必须 NTP 对时？ | 心跳与 fire time 都基于本地时钟，时钟漂移会误判、导致重复触发 |
| `@DisallowConcurrentExecution` 作用范围？ | 对**同一个 JobDetail** 禁止并发，跨节点也生效（基于 JobKey 与 DB 状态） |
| 什么叫"合理时间"？ | `misfireThreshold`，默认 60s，迟到在这个范围内不算 Misfire |
| 任务执行时间超过触发间隔怎么办？ | 加 `@DisallowConcurrentExecution`，否则会堆叠触发；再考虑用 Cron 而非固定间隔 |
| 为什么不推荐 RAMJobStore？ | 状态在内存，重启即丢，无法跨实例协调 |
| 长任务如何避免超时/中断？ | 分批分片 + 断点续传 + 状态表记录进度，而不是靠单次执行跑完 |

## 小结

Quartz 的三个核心知识点：

1. **组件模型**——Scheduler / JobDetail / Trigger / JobStore / ThreadPool，理解各自职责；
2. **集群原理**——数据库悲观锁（`QRTZ_LOCKS`）+ 状态机（`TRIGGERS`/`FIRED_TRIGGERS`）+ 心跳（`SCHEDULER_STATE`）；
3. **Misfire 策略**——对账报表类用 `DoNothing` + 业务补偿，绝不用 `IgnoreMisfires`。

记住一句话：**调度框架只保证"什么时候触发"，"只跑一次、跑完为止"必须靠业务侧的幂等、状态表和分布式锁**。这是所有分布式任务设计的分层底线。
