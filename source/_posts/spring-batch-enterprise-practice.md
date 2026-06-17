---
title: Spring Batch 批处理框架：从入门到企业级任务调度
date: 2026-06-17 08:35:00
tags:
  - Spring Batch
  - 批处理
  - Spring Boot
  - 定时任务
categories:
  - Java
author: 东哥
---

# Spring Batch 批处理框架：从入门到企业级任务调度

## 一、为什么需要批处理框架

企业应用中大量场景涉及批量数据处理：

| 场景 | 数据量 | 频率 | 要求 |
|------|--------|------|------|
| 每日对账单生成 | 100万+ 交易记录 | 每日凌晨 | 零差错、可重跑 |
| 数据迁移 | 千万级记录 | 一次性 | 断点续传、性能可控 |
| 报表计算 | 百万级聚合 | 每小时 | 稳定可靠、可追溯 |
| 短信/邮件批量发送 | 10万+ | 定时 | 失败重试、跳过错误 |

不使用框架硬编码的痛点：
- **没有断点续传**：处理到一半失败就得重头再来
- **没有跳过机制**：一条数据错误整个 Job 卡死
- **缺少管理能力**：无法查看 Job 执行状态和日志
- **性能不可控**：一次性把所有数据加载到内存

Spring Batch 正是为应对这些挑战而生的批处理框架。

## 二、Spring Batch 核心架构

### 2.1 三层架构

```
┌─────────────────────────────────────────────┐
│             Application Layer               │
│   (业务逻辑：Reader/Processor/Writer)        │
├─────────────────────────────────────────────┤
│             Core Layer                      │
│   (Job Launcher, Job, Step, Chunk)          │
├─────────────────────────────────────────────┤
│             Infrastructure Layer            │
│   (JobRepository, Transaction Manager)      │
└─────────────────────────────────────────────┘
```

### 2.2 核心组件

```
Job → 包含多个 Step
│
├── Step (Chunk-Oriented: Tasklet)
│   └── Chunk: Repeat [Read → Process → Write]
│       ├── ItemReader  ─── 读取数据源
│       ├── ItemProcessor ── 处理/转换数据
│       └── ItemWriter ──── 写入目标
│
├── Step (Tasklet 模式：单一任务)
│   └── 执行一个原子操作（如清理临时文件）
│
├── JobLauncher ─── 启动 Job
├── JobRepository ── 存储 Job/Step 执行元数据
└── JobExplorer ──── 查询 Job 执行历史
```

### 2.3 JobRepository 元数据表

| 表名 | 说明 | 主要字段 |
|------|------|----------|
| BATCH_JOB_INSTANCE | Job 实例 | JOB_INSTANCE_ID, JOB_NAME, JOB_KEY |
| BATCH_JOB_EXECUTION | Job 执行记录 | JOB_EXECUTION_ID, STATUS, START_TIME, EXIT_CODE |
| BATCH_STEP_EXECUTION | Step 执行记录 | STEP_EXECUTION_ID, STEP_NAME, STATUS, READ_COUNT, WRITE_COUNT |
| BATCH_JOB_EXECUTION_PARAMS | Job 参数 | KEY, TYPE, VALUE, IDENTIFYING |
| BATCH_JOB_EXECUTION_CONTEXT | Job 上下文 | SHORT_CONTEXT, SERIALIZED_CONTEXT |
| BATCH_STEP_EXECUTION_CONTEXT | Step 上下文 | SHORT_CONTEXT, SERIALIZED_CONTEXT |

## 三、快速入门实战

### 3.1 项目配置

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-batch</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
<dependency>
    <groupId>mysql</groupId>
    <artifactId>mysql-connector-j</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/batch_db?useSSL=false
    username: root
    password: root
  batch:
    jdbc:
      initialize-schema: always  # 自动创建元数据表
    job:
      enabled: false             # 关闭自动启动，通过 API 触发
```

### 3.2 第一个 Job：CSV 文件导入数据库

```java
@Configuration
@EnableBatchProcessing
public class CsvImportJobConfig {

    @Autowired
    private JobBuilderFactory jobBuilderFactory;
    @Autowired
    private StepBuilderFactory stepBuilderFactory;

    // ---- ItemReader：读取 CSV ----
    @Bean
    public FlatFileItemReader<User> csvReader() {
        return new FlatFileItemReaderBuilder<User>()
            .name("userCsvReader")
            .resource(new FileSystemResource("/data/users.csv"))
            .delimited()
            .names("id", "name", "email", "phone", "age")
            .linesToSkip(1) // 跳过 CSV 表头
            .fieldSetMapper(new BeanWrapperFieldSetMapper<>() {{
                setTargetType(User.class);
            }})
            .build();
    }

    // ---- ItemProcessor：数据校验和转换 ----
    @Bean
    public ItemProcessor<User, User> userProcessor() {
        return user -> {
            // 数据校验
            if (user.getAge() < 0 || user.getAge() > 150) {
                throw new ValidationException("年龄不合法: " + user.getAge());
            }
            // 数据转换
            user.setEmail(user.getEmail().toLowerCase().trim());
            user.setName(user.getName().trim());
            if (user.getPhone() != null) {
                user.setPhone(user.getPhone().replaceAll("[^0-9]", ""));
            }
            return user;
        };
    }

    // ---- ItemWriter：写入数据库 ----
    @Bean
    public JdbcBatchItemWriter<User> dbWriter(DataSource dataSource) {
        return new JdbcBatchItemWriterBuilder<User>()
            .itemSqlParameterSourceProvider(new BeanPropertyItemSqlParameterSourceProvider<>())
            .sql("INSERT INTO users (id, name, email, phone, age, create_time) " +
                 "VALUES (:id, :name, :email, :phone, :age, NOW()) " +
                 "ON DUPLICATE KEY UPDATE name=VALUES(name), email=VALUES(email)")
            .dataSource(dataSource)
            .build();
    }

    // ---- Step 配置 ----
    @Bean
    public Step csvImportStep(ItemReader<User> reader,
                              ItemProcessor<User, User> processor,
                              ItemWriter<User> writer) {
        return stepBuilderFactory.get("csvImportStep")
            .<User, User>chunk(1000)    // 每 1000 条提交一次事务
            .reader(reader)
            .processor(processor)
            .writer(writer)
            .faultTolerant()            // 开启容错
            .skip(ValidationException.class)
            .skipLimit(10)              // 最多跳过 10 条错误数据
            .retry(DataAccessException.class)
            .retryLimit(3)              // 数据库异常重试 3 次
            .listener(new StepChunkListener())  // Step 监听器
            .build();
    }

    // ---- Job 配置 ----
    @Bean
    public Job csvImportJob(Step csvImportStep) {
        return jobBuilderFactory.get("csvImportJob")
            .incrementer(new RunIdIncrementer())  // 每次运行自动递增
            .listener(new JobCompletionListener())
            .start(csvImportStep)
            .build();
    }
}
```

### 3.3 Job 监听器

```java
@Component
public class JobCompletionListener extends JobExecutionListenerSupport {

    @Override
    public void beforeJob(JobExecution jobExecution) {
        log.info("=== Job 开始: {} ===", jobExecution.getJobInstance().getJobName());
    }

    @Override
    public void afterJob(JobExecution jobExecution) {
        String jobName = jobExecution.getJobInstance().getJobName();
        BatchStatus status = jobExecution.getStatus();
        log.info("=== Job 结束: {}, 状态: {} ===", jobName, status);

        if (status == BatchStatus.FAILED) {
            // 告警通知
            notificationService.sendAlert("批处理失败: " + jobName);
        }

        // 记录执行统计
        Map<String, Object> stats = new HashMap<>();
        stats.put("jobName", jobName);
        stats.put("status", status);
        stats.put("startTime", jobExecution.getStartTime());
        stats.put("endTime", jobExecution.getEndTime());
        stats.put("durationMs",
            jobExecution.getEndTime().getTime() - jobExecution.getStartTime().getTime());
        jobMetricsService.record(stats);
    }
}
```

### 3.4 通过 API 启动 Job

```java
@RestController
@RequestMapping("/batch")
public class JobController {

    @Autowired
    private JobLauncher jobLauncher;
    @Autowired
    @Qualifier("csvImportJob")
    private Job csvImportJob;
    @Autowired
    @Qualifier("reportGenerationJob")
    private Job reportGenerationJob;
    @Autowired
    private JobExplorer jobExplorer;

    @PostMapping("/import-csv")
    public String importCsv(@RequestParam String filePath) {
        JobParameters params = new JobParametersBuilder()
            .addString("filePath", filePath)
            .addDate("runDate", new Date())
            .toJobParameters();
        JobExecution execution = jobLauncher.run(csvImportJob, params);
        return "Job launched, executionId: " + execution.getId();
    }

    @PostMapping("/rerun/{jobName}")
    public String rerun(@PathVariable String jobName,
                        @RequestBody JobParameters params) {
        // 查找上次失败的 Job 实例
        JobInstance lastInstance = jobExplorer.getLastJobInstance(jobName);
        if (lastInstance != null) {
            List<JobExecution> executions = jobExplorer.getJobExecutions(lastInstance);
            JobExecution lastExec = executions.get(executions.size() - 1);
            if (lastExec.getStatus() == BatchStatus.FAILED) {
                // 从上次失败处续跑
                return restart(lastExec.getId());
            }
        }
        return "No failed job to restart";
    }

    @GetMapping("/status/{executionId}")
    public JobExecution getStatus(@PathVariable Long executionId) {
        return jobExplorer.getJobExecution(executionId);
    }

    @GetMapping("/history/{jobName}")
    public List<JobExecution> getHistory(@PathVariable String jobName) {
        JobInstance jobInstance = jobExplorer.getLastJobInstance(jobName);
        if (jobInstance == null) return List.of();
        return jobExplorer.getJobExecutions(jobInstance);
    }
}
```

## 四、企业级批处理模式

### 4.1 多步骤 Job 编排

```java
@Bean
public Job complexJob() {
    return jobBuilderFactory.get("complexJob")
        .start(validateStep)       // Step 1: 数据校验
        .next(transformStep)       // Step 2: 数据转换
        .next(processStep)         // Step 3: 业务处理
        .next(archiveStep)         // Step 4: 归档结果
        .on("FAILED").to(alertStep) // 失败执行告警 Step
        .from(processStep)
        .on("WARN").to(reviewStep)  // 警告进入人工审核
        .end()
        .build();
}
```

### 4.2 并行 Step 执行

```java
@Bean
public Job parallelJob() {
    // Step A 和 Step B 并行执行
    Flow flowA = new FlowBuilder<Flow>("flowA")
        .start(stepA).build();
    Flow flowB = new FlowBuilder<Flow>("flowB")
        .start(stepB).build();

    return jobBuilderFactory.get("parallelJob")
        .start(new FlowBuilder<SplitState>("split")
            .split(new SimpleAsyncTaskExecutor())
            .add(flowA, flowB)
            .build())
        .next(flowC) // 等 A 和 B 都完成后再执行 C
        .end()
        .build();
}
```

### 4.3 分区（Partitioning）处理海量数据

```java
@Bean
@StepScope
public FlatFileItemReader<DataRecord> partitionedReader(
        @Value("#{stepExecutionContext['filePath']}") String filePath) {
    // 每个分区读取不同的文件片段
    return new FlatFileItemReaderBuilder<DataRecord>()
        .name("partitionedReader")
        .resource(new FileSystemResource(filePath))
        .build();
}

@Bean
public Partitioner filePartitioner() {
    return gridSize -> {
        Map<String, ExecutionContext> partitions = new HashMap<>(gridSize);
        List<String> files = fileService.listDataFiles();
        for (int i = 0; i < files.size(); i++) {
            ExecutionContext ctx = new ExecutionContext();
            ctx.putString("filePath", files.get(i));
            ctx.putString("partitionId", "part" + i);
            partitions.put("Partition-" + i, ctx);
        }
        return partitions;
    };
}

@Bean
public Step masterStep() {
    return stepBuilderFactory.get("masterStep")
        .partitioner("workerStep", filePartitioner())
        .gridSize(4)       // 4 个分区并行
        .taskExecutor(new SimpleAsyncTaskExecutor())
        .build();
}
```

## 五、生产者消费者模式整合

### 5.1 Job 与消息队列配合

```java
@Component
public class BatchJobMessageHandler {

    @Autowired
    private JobLauncher jobLauncher;
    @Autowired
    private Job reportJob;

    // 监听到消息时触发批处理
    @RabbitListener(queues = "batch.job.trigger")
    public void handleJobTrigger(BatchJobMessage message) {
        JobParameters params = new JobParametersBuilder()
            .addString("businessDate", message.getBusinessDate())
            .addString("triggerSource", "rabbitmq")
            .addLong("timestamp", System.currentTimeMillis())
            .toJobParameters();

        try {
            jobLauncher.run(reportJob, params);
        } catch (Exception e) {
            log.error("启动批处理任务失败", e);
            // 发送到死信队列等待重试
            retryPublisher.send(message);
        }
    }
}
```

### 5.2 分批处理优化

```java
@Bean
public Step batchOptimizedStep() {
    return stepBuilderFactory.get("optimizedStep")
        .<Order, OrderSummary>chunk(2000)
        .reader(orderReader())
        .processor(orderProcessor())
        .writer(orderWriter())
        .readerIsTransactionalQueue(false) // 读取非事务性队列
        .listener(new ChunkListener() {
            @Override
            public void beforeChunk(ChunkContext context) {
                // 每个 Chunk 前记录进度
                StepExecution stepExec = context.getStepContext().getStepExecution();
                log.info("处理进度: {}/{} (已读/写入)",
                    stepExec.getReadCount(), stepExec.getWriteCount());
            }
        })
        .build();
}
```

## 六、监控与运维

### 6.1 集成 Actuator

```yaml
management:
  endpoints:
    web:
      exposure:
        include: "health,info,batch"
  endpoint:
    batch:
      enabled: true

# 访问端点获取 Job 状态
# GET /actuator/batch/jobs
# GET /actuator/batch/jobs/{jobName}
# GET /actuator/batch/executions/{executionId}
```

### 6.2 关键运维命令

```bash
# 查看所有 Job
curl http://localhost:8080/actuator/batch/jobs

# 查看指定 Job 的执行历史
curl http://localhost:8080/actuator/batch/jobs/csvImportJob

# 查看某个执行记录的详细信息
curl http://localhost:8080/actuator/batch/executions/42

# 停止正在运行的 Job
curl -X POST http://localhost:8080/actuator/batch/executions/42/stop
```

## 七、性能调优建议

| 参数 | 说明 | 推荐值 | 影响 |
|------|------|--------|------|
| chunk-size | 每批处理的行数 | 500-2000 | 越大吞吐越高，但事务变长 |
| commit-interval | 提交间隔 | 同 chunk-size | 事务提交频率 |
| page-size | 数据库每次查询的行数 | 2000-5000 | 减少数据库往返次数 |
| thread-count | 并行线程数 | 2-4 (CPU密集) / 8-16 (IO密集) | 并行度 |
| skip-limit | 错误跳过上限 | 10-50 | 容错能力 |
| retry-limit | 重试次数 | 3 | 临时故障恢复 |

```yml
# 性能调优配置示例
spring:
  batch:
    jdbc:
      initialize-schema: always
  datasource:
    hikari:
      maximum-pool-size: 10     # 连接池大小
      minimum-idle: 5
      idle-timeout: 30000
      max-lifetime: 1800000
# 批处理执行器线程池
batch:
  task-executor:
    core-pool-size: 4
    max-pool-size: 8
    queue-capacity: 100
```

Spring Batch 为企业级批处理提供了标准化、可重用的框架。它的价值在于不是重新发明轮子，而是在事务管理、性能控制、状态追踪、断点续传等方面都做了成熟的工程化设计。配合 Spring Cloud Task 和 Spring Cloud Data Flow 可以实现更复杂的分布式批处理编排。
