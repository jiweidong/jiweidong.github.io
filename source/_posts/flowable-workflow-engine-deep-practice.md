---
title: 【Java实战】Flowable 工作流引擎深度实战：从 BPMN 建模到审批流开发
date: 2026-08-17 08:00:00
tags:
  - Java
  - Flowable
  - 工作流
  - Spring Boot
categories:
  - Java
  - 实战
author: 东哥
---

# 【Java实战】Flowable 工作流引擎深度实战：从 BPMN 建模到审批流开发

## 一、为什么需要工作流引擎？

"请假审批""报销流程""合同会签""工单流转"——这些业务的核心都是**流程状态流转**。自己写的话，你需要维护状态机、待办表、历史表、权限判断，一套下来至少几千行代码，而且需求一变（加个会签节点、改个审批人）就得改代码。

工作流引擎把流程的定义和执行**分离**：流程定义（BPMN 文件）可以热部署，改流程不动代码；引擎负责节点流转、任务分配、历史记录、超时提醒。Flowable 是目前 Java 生态最主流的开源工作流引擎（Activiti 的继承者），本文带你从原理到实战完整走一遍。

## 二、Flowable 核心概念

| 概念 | 说明 | 类比 |
|------|------|------|
| ProcessDefinition | 流程定义，BPMN 文件的运行时表示 | 类 |
| ProcessInstance | 一次具体的流程执行 | 对象 |
| Execution | 执行实例，流程走到哪里的游标 | 线程执行位置 |
| Task | 待办任务（用户任务/服务任务） | 待办事项 |
| Deployment | 流程定义的部署单元 | JAR 包 |
| IdentityLink | 任务与用户/组的关联 | 权限绑定 |
| HistoricActivityInstance | 历史活动记录 | 审计日志 |

关键点：**ProcessDefinition 是静态的"模具"，ProcessInstance 是动态的"实例"**。一个流程定义可以同时跑成千上万个实例，互不干扰。

## 三、BPMN 建模：流程长什么样

BPMN 2.0 是 OMG 标准，Flowable 用 XML 描述流程。一个最简单的请假流程：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<definitions xmlns="http://www.omg.org/spec/BPMN/20100524/MODEL"
             xmlns:flowable="http://flowable.org/bpmn"
             targetNamespace="http://flowable.org/bpmn">
  <process id="leaveProcess" name="请假流程" isExecutable="true">
    <!-- 开始事件 -->
    <startEvent id="start" name="发起请假"/>
    <!-- 用户任务：员工填写 -->
    <userTask id="apply" name="填写请假单" flowable:assignee="${applyUser}"/>
    <!-- 排他网关：按天数路由 -->
    <exclusiveGateway id="gateway" name="天数判断"/>
    <!-- 用户任务：部门经理审批 -->
    <userTask id="managerApprove" name="经理审批" flowable:assignee="${managerUser}"/>
    <!-- 用户任务：总监审批（>=3天走这） -->
    <userTask id="directorApprove" name="总监审批" flowable:assignee="${directorUser}"/>
    <!-- 结束事件 -->
    <endEvent id="end" name="结束"/>

    <sequenceFlow id="f1" sourceRef="start" targetRef="apply"/>
    <sequenceFlow id="f2" sourceRef="apply" targetRef="gateway"/>
    <sequenceFlow id="f3" sourceRef="gateway" targetRef="managerApprove">
      <conditionExpression xsi:type="tFormalExpression"><![CDATA[${days < 3}]]></conditionExpression>
    </sequenceFlow>
    <sequenceFlow id="f4" sourceRef="gateway" targetRef="directorApprove">
      <conditionExpression xsi:type="tFormalExpression"><![CDATA[${days >= 3}]]></conditionExpression>
    </sequenceFlow>
    <sequenceFlow id="f5" sourceRef="managerApprove" targetRef="end"/>
    <sequenceFlow id="f6" sourceRef="directorApprove" targetRef="end"/>
  </process>
</definitions>
```

生产环境一般用 **Flowable Modeler**（可视化建模工具）画流程图，导出 BPMN XML 后部署。注意每个节点都要设置**审批人表达式**（`${assignee}`），运行时通过流程变量解析。

## 四、Spring Boot 集成与部署

### 1. 引入依赖

```xml
<dependency>
    <groupId>org.flowable</groupId>
    <artifactId>flowable-spring-boot-starter</artifactId>
    <version>7.1.0</version>
</dependency>
```

### 2. 部署流程定义

```java
@Service
public class ProcessDeployService {

    @Autowired
    private RepositoryService repositoryService;

    public Deployment deploy(String bpmnPath, String processKey) {
        Deployment deployment = repositoryService.createDeployment()
                .addClasspathResource(bpmnPath)   // 从 classpath 加载 BPMN 文件
                .name("请假流程-" + System.currentTimeMillis())
                .deploy();
        return deployment;
    }
}
```

流程定义可以放在 `resources/processes/` 下自动部署，也可以通过 API 手动部署（生产推荐手动部署 + 版本管理，方便灰度）。

### 3. 发起流程实例

```java
@Autowired
private RuntimeService runtimeService;

public String startLeaveProcess(String applyUser, String managerUser, int days) {
    Map<String, Object> variables = new HashMap<>();
    variables.put("applyUser", applyUser);
    variables.put("managerUser", managerUser);
    variables.put("days", days);

    ProcessInstance instance = runtimeService.startProcessInstanceByKey(
            "leaveProcess",      // 流程定义 key
            "BIZ-" + orderNo(),  // 业务 key，关联业务表
            variables);          // 流程变量
    return instance.getId();
}
```

**流程变量（Process Variables）**是工作流引擎的"内存"：审批人、天数、金额都放这里，网关条件、任务表达式都依赖它。

### 4. 查询待办 & 审批

```java
@Autowired
private TaskService taskService;

// 查某人的待办
public List<Task> queryTodo(String userId) {
    return taskService.createTaskQuery()
            .taskAssignee(userId)          // 指定办理人
            .orderByTaskCreateTime().desc()
            .list();
}

// 审批（同意/驳回）
public void approve(String taskId, boolean approved, String comment) {
    taskService.addComment(taskId, null, comment);  // 记录审批意见
    if (approved) {
        taskService.complete(taskId);      // 完成当前任务，自动流转到下一节点
    } else {
        // 驳回：回到上一个任务（需要记录上一步 task 的 key）
        taskService.complete(taskId, Collections.singletonMap("reject", true));
    }
}
```

驳回的经典实现是**流程变量记录上一个节点 key**，驳回时用 `runtimeService.createChangeActivityStateBuilder().moveActivityIdTo(...)` 跳转回指定节点。

## 五、核心 API 速查

| Service | 职责 | 常用方法 |
|---------|------|---------|
| RepositoryService | 流程定义/部署管理 | `createDeployment()`、`createProcessDefinitionQuery()` |
| RuntimeService | 流程实例/执行管理 | `startProcessInstanceByKey()`、`signal()`、`trigger()` |
| TaskService | 任务办理 | `createTaskQuery()`、`complete()`、`addComment()` |
| HistoryService | 历史数据查询 | `createHistoricProcessInstanceQuery()`、`createHistoricActivityInstanceQuery()` |
| IdentityService | 用户/组管理 | `newUser()`、`createGroup()` |
| ManagementService | 引擎管理（job、表） | `createJobQuery()`、`executeJob()` |
| FormService | 表单管理 | `getTaskFormData()` |

## 六、进阶功能

### 1. 会签（多实例任务）

```xml
<userTask id="countersign" name="会签" flowable:assignee="${assignee}">
  <multiInstanceLoopCharacteristics isSequential="false"
        flowable:collection="assigneeList"
        flowable:elementVariable="assignee">
    <completionCondition>${nrOfCompletedInstances >= nrOfInstances / 2 + 1}</completionCondition>
  </multiInstanceLoopCharacteristics>
</userTask>
```

`collection` 是审批人列表（流程变量），`completionCondition` 定义**过半通过**的完成条件。

### 2. 定时器事件（超时自动处理）

```xml
<userTask id="managerApprove" name="经理审批" flowable:assignee="${managerUser}">
  <boundaryEvent id="timeout" attachedToRef="managerApprove">
    <timerEventDefinition>
      <timeDuration>PT24H</timeDuration>
    </timerEventDefinition>
  </boundaryEvent>
</userTask>
```

24 小时未审批触发边界事件，可以接一个服务任务自动提醒或自动转交。

### 3. 服务任务（自动节点）

```xml
<serviceTask id="deductStock" name="扣减库存"
    flowable:delegateExpression="${stockDeductDelegate}"/>
```

```java
@Component("stockDeductDelegate")
public class StockDeductDelegate implements JavaDelegate {
    @Override
    public void execute(DelegateExecution execution) {
        Long orderId = (Long) execution.getVariable("orderId");
        // 扣库存逻辑
        execution.setVariable("deductResult", true);
    }
}
```

## 七、生产实践避坑指南

1. **流程引擎表单独建库**：Flowable 默认生成 70+ 张表（`ACT_*` 前缀），建议独立 schema，避免和业务表混在一起，方便单独备份。
2. **业务数据与流程数据分离**：流程变量只放"流转相关"的数据（审批人、金额），业务详情放业务表，用 `businessKey` 关联。别把大对象塞流程变量——它要序列化进 `ACT_RU_VARIABLE`。
3. **异步执行器调优**：定时器、异步任务依赖 `AsyncExecutor`，默认线程数偏小，高并发场景要调大 `flowable.async-executor-core-pool-size`。
4. **历史数据归档**：`ACT_HI_*` 历史表增长极快，定期归档（按月分区或迁移到历史库），否则查询越来越慢。
5. **数据库锁注意**：`complete()` 时引擎会更新流程实例状态，高并发下可能出现死锁，重试机制要有（Spring Retry）。
6. **权限控制**：待办查询要带上租户/部门过滤条件，防止 A 部门的人看到 B 部门的流程实例。

## 八、面试常见追问

**Q1：Activiti 和 Flowable 什么关系？**
Activiti 5 的作者创立了 Flowable 分支（2016 年），社区重心迁移到 Flowable。Activiti 7 改为云原生架构（Activiti Cloud），而 Flowable 保持传统嵌入式引擎路线，国内企业落地最多的是 Flowable 6/7。

**Q2：Flowable 和状态机（Spring StateMachine）怎么选？**
状态机适合**单对象、状态少、流转简单**的场景（订单状态：待支付→已支付→已发货），轻量无表；工作流引擎适合**多参与人、会签、超时、人工审批**的复杂流程，自带待办/历史/权限体系。规则：流程涉及人 → Flowable；流程只涉及状态 → 状态机。

**Q3：流程引擎的性能瓶颈在哪？怎么压测？**
瓶颈主要在 `ACT_RU_TASK`、`ACT_RU_EXECUTION` 运行时表的竞争和命令执行的数据库事务。压测用 JMeter 直打"发起流程 + 完成任务"接口，关注 TPS 和 `ACT_HI_*` 表增长速率。优化方向：批量完成任务、减少流程变量、历史表归档。

**Q4：如何实现流程的灰度发布？**
利用 `ProcessDefinition.version`：部署新版本后，`startProcessInstanceByKey` 默认用最新版本。灰度做法：部署时指定版本，老流程实例走完老版本（引擎天然支持），新发起按比例路由到新版本，观察无问题后切换默认版本。

## 总结

工作流引擎解决的是"**流程即代码**"的问题：BPMN 可视化建模 + 热部署，让流程变更不再动业务代码。掌握 Flowable 的五大核心 Service（Repository/Runtime/Task/History/Identity）和流程变量机制，配合会签、定时器、服务任务这些进阶能力，足以应对 90% 的企业审批流需求。
