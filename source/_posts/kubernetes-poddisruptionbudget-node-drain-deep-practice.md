---
title: 【云原生】PodDisruptionBudget 与节点维护全链路：drain、驱逐预算与发布期容量坍塌
date: 2026-11-23 08:00:00
tags:
  - Java
  - Kubernetes
  - 云原生
  - 高可用
categories:
  - 云原生
author: 东哥
---

# 【云原生】PodDisruptionBudget 与节点维护全链路

## 面试官：集群要升级内核，运维说"我们有 PDB，直接 drain 就行"，你怎么看？

这道题的分水岭在于：你是否知道 **PDB 只约束"自愿驱逐"**，而线上真正把服务打挂的，往往是 PDB 管不到的那几类中断。

很多团队把 PDB 当成"高可用开关"：配一个 `minAvailable: 50%`，就以为节点维护期间业务无感。真实事故里常见的是三种情况：

1. `drain` 卡在 `Cannot evict pod as it would violate the pod's disruption budget`，运维加了 `--force --grace-period=0`，直接把 Pod 打掉，请求 502。
2. PDB 允许驱逐，但**同一时刻**滚动发布也在删 Pod，两股"合法"的中断叠加，可用副本瞬间掉到 1。
3. 节点是空的，但**流量没摘干净**：Endpoint 更新有延迟，Pod 收到 SIGTERM 后立刻关端口，几十秒的 5xx。

所以这道题的正确答法是先分类，再算预算，最后讲编排顺序。

## 一、先把"驱逐"这个词拆开

Kubernetes 里至少有四种让 Pod 消失的路径，语义完全不同：

| 路径 | 触发者 | 是否尊重 PDB | 是否有优雅期 | 典型场景 |
|---|---|---|---|---|
| Eviction API（`policy/v1 Eviction`） | `kubectl drain`、descheduler、集群升级 | **是** | 是（默认 grace） | 节点维护、主动腾挪 |
| kubelet 压力驱逐 | kubelet（memory/nodefs/pid 压力） | **否** | 很短（软驱逐可配） | 节点内存打满、磁盘写满 |
| 直接删除（`kubectl delete pod`、Deployment 滚动） | 控制器/人 | **否** | 是 | 发布、扩缩容 |
| 节点失联 / NotReady | node controller | 否 | `pod-eviction-timeout` 后强制删 | 宕机、网络分区 |

这张表要能背下来。它直接解释了两个高频追问：

- "我们配了 PDB，为什么节点内存打满时还是全挂了？"——因为 kubelet 压力驱逐不查 PDB。
- "drain 为什么不动？"——因为 Eviction API 会查 PDB，`disruptionsAllowed == 0` 时返回 429。

## 二、PDB 的预算到底怎么算

PDB 只有两个字段二选一：`minAvailable`（最小可用）或 `maxUnavailable`（最大不可用），都支持百分比。核心是三个数：

```
expectedPods        = selector 匹配到的 Pod 总数（只统计 Running/Ready，且必须有 controller）
desiredHealthy      = minAvailable 或 (expectedPods - maxUnavailable)
currentHealthy      = 当前 Ready 的 Pod 数
disruptionsAllowed  = currentHealthy - desiredHealthy   // 小于 0 时按 0 处理
```

三个必须注意的细节：

**1. 百分比取整方向相反。** `minAvailable: 50%` 在 3 副本时向上取整为 2（只能驱逐 1 个）；`maxUnavailable: 50%` 在 3 副本时向下取整为 1（也只能驱逐 1 个）。副本数是奇数时，两种写法结果一样；副本数是偶数时就会分叉，别凭感觉写。

**2. 没有 controller 的裸 Pod 不参与计算。** PDB 只对 ReplicaSet/StatefulSet/Deployment 这类有 owner 的 Pod 生效。裸 Pod 会被算进 `expectedPods` 的干扰项，导致预算永远算不对。

**3. `minAvailable: 100%` 是"永远不允许自愿驱逐"。** 它看起来最安全，实际会让所有节点维护永久阻塞。3 副本服务想要"最多挂 1 个"，写 `maxUnavailable: 1`；想要"至少 2 个"，写 `minAvailable: 2`，语义清晰且不会被取整坑到。

一个生产可用的写法：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: order-service-pdb
spec:
  maxUnavailable: 1          # 明确表达"一次最多少一个"
  selector:
    matchLabels:
      app: order-service
  unhealthyPodEvictionPolicy: AlwaysAllow   # 1.27+：不健康 Pod 允许直接驱逐，避免卡死
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  replicas: 4
  strategy:
    rollingUpdate:
      maxUnavailable: 0      # 发布期间靠 surge 起新 Pod，不靠"先删后建"
      maxSurge: 1
  template:
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: app
          image: registry/order-service:1.8.3
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 8"]   # 等 Endpoint 摘干净
```

注意 `maxUnavailable: 0` 的含义：发布期不缺容量，但**它不保护 drain**。drain 走的是 Eviction API，看的是 PDB，不是 Deployment 的滚动参数。这是两套独立预算，很多事故就出在"以为是一套"。

## 三、drain 的完整流程与卡点

`kubectl drain node-7` 的实际动作顺序：

1. `cordon`：把节点标记为 `SchedulingDisabled`，不再调度新 Pod。
2. 逐个对 Pod 发 Eviction 请求（每个 Pod 一次，带 grace period）。
3. DaemonSet 管理的 Pod 默认跳过；要驱逐必须显式 `--ignore-daemonsets`。
4. 使用 `emptyDir` 的 Pod 默认拒绝驱逐；要驱逐必须 `--delete-emptydir-data`（数据会丢，先确认无状态）。
5. 有本地存储（local PV）的 Pod 会直接拒绝，需要人工迁移数据。

三个高频卡点及排查命令：

```bash
# 1) PDB 卡住
kubectl get pdb -A
kubectl describe pdb order-service-pdb -n prod
# 关注 DisruptionsAllowed 是否为 0，以及 Events 里的
# "Cannot evict pod as it would violate the pod's disruption budget"

# 2) 到底是谁在占着预算
kubectl get pods -n prod -l app=order-service \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,NODE:.spec.nodeName

# 3) drain 卡住时不要 --force，先看还有哪些 Pod 没走
kubectl get pods -A --field-selector spec.nodeName=node-7
```

如果 `DisruptionsAllowed = 0` 且 `CurrentHealthy = ExpectedPods`，说明是**副本数刚好等于 minAvailable**——服务本身就没有冗余，drain 必然阻塞。这时候正确的做法是**先扩容**，而不是加 `--force`。

```bash
kubectl scale deploy order-service -n prod --replicas=5
# 等 5 个 Ready 后 drain 会自然放行
```

`--force --grace-period=0` 会绕过优雅期直接 SIGKILL，等于放弃所有在途请求。它应该只用于"确认无流量的测试集群"。

## 四、drain 期间的流量摘除时序

即使 PDB 放行、Pod 优雅退出，仍有一段**必然的 5xx 窗口**，原因在控制面延迟：

```
t0  Eviction 请求被接受
t1  Pod 进入 Terminating，同时从 Endpoints/EndpointSlice 标记 notReady
t2  kube-proxy / ingress controller / client-side LB 感知变更   ← 延迟 1~10s
t3  容器真正收到 SIGTERM                                        ← 与 t1 几乎同时
```

问题在于 t3 早于 t2。容器在 t1 就开始关连接，而还有一部分流量在往它身上打。解决办法就是 `preStop sleep`：让容器在收到 SIGTERM 后**先继续服务几秒**，等 Endpoint 传播完成再退出。

经验取值：`preStop sleep ≈ 2 × (端点传播延迟)`，Ingress/NLB 场景一般 5~15 秒。同时 `terminationGracePeriodSeconds` 必须大于 `preStop` + 应用自身关停时间，否则 kubelet 会在 grace 结束时 SIGKILL。

Java 侧配套三件事：

```java
// 1. 优雅停机：先拒绝新请求，再等在途请求结束
// application.yml
// server.shutdown: graceful
// spring.lifecycle.timeout-per-shutdown-phase: 30s

// 2. readiness 先失败（配合 preStop 更稳）：让 LB 提前摘流量
@RestController
class ReadinessController {
    private final AtomicBoolean draining = new AtomicBoolean(false);

    @PostMapping("/internal/drain")
    void drain() { draining.set(true); }

    @GetMapping("/actuator/health/readiness")
    ResponseEntity<String> ready() {
        return draining.get()
            ? ResponseEntity.status(503).body("draining")
            : ResponseEntity.ok("UP");
    }
}
```

```java
// 3. 线程池/消费者要能被关停，而不是靠 JVM 退出了事
@PreDestroy
void shutdown() throws InterruptedException {
    executor.shutdown();
    if (!executor.awaitTermination(20, TimeUnit.SECONDS)) {
        executor.shutdownNow();
    }
}
```

Kafka 消费者还有一个额外点：drain 触发的实例下线会引发 rebalance。若用 `@KafkaListener`，务必配置 `spring.kafka.listener.immediate-stop: true` 与合适的 `max.poll.interval.ms`，否则 consumer 会在关闭前提交失败，导致重复消费。

## 五、容量预算：把"能不能维护"算出来

面试里如果追问"一次能维护几台机器"，要给出可推导的答案，而不是拍脑袋。

设某服务副本数 `R`、PDB `maxUnavailable = M`、单机承载能力为整机 QPS 的 `1/R`，则一次可同时维护的节点数上限是 `M`（因为 Eviction 是逐个 Pod 判定，同一时刻最多让 `M` 个不健康）。但真实的容量约束更严：

```
单次维护窗口可用容量 = (R - M) / R
需要的冗余度        = 1 / (1 - M/R)
```

4 副本、`maxUnavailable: 1` → 维护期只剩 75% 容量。如果节点本身水位已达 70%，这个窗口是危险的。所以节点维护前要做两件事：

1. **确认剩余节点还有多少 headroom**：`kubectl describe node` 看 Allocated resources，或用 VPA/监控看实际 CPU/内存峰值。
2. **错开发布窗口**：发布（滚动）+ 维护（drain）叠加时，两者的不可用量要合并计算。最保守的策略是维护期间冻结发布。

还要注意**跨可用区**：如果 PDB 只按 `app` 选择，drain 可能把某 AZ 的副本全清空。多 AZ 部署应把 PDB selector 加上 `topology.kubernetes.io/zone` 维度，或用 `topologySpreadConstraints` 保证分布。

## 六、一份可执行的维护 Runbook

```text
[维护前 24h]
  1. kubectl get pdb -A，确认所有业务 PDB 的 DisruptionsAllowed > 0
  2. 检查目标节点上的 Pod：是否有裸 Pod / local PV / emptyDir 有状态服务
  3. 确认监控大盘：5xx 率、P99、Pending Pod 数、PDB 状态
  4. 通知业务方冻结发布窗口

[维护窗口]
  5. kubectl cordon node-7
  6. kubectl drain node-7 --ignore-daemonsets --delete-emptydir-data --timeout=15m
     （不要 --force；超时就停下来看 PDB）
  7. 观察 5xx 与 P99，超过阈值立即 kubectl uncordon 回滚
  8. 执行节点操作（内核升级/重启）

[恢复]
  9. kubectl uncordon node-7
 10. 观察新 Pod 调度与 PDB 恢复；确认无 Pending
 11. 记录本次最大不可用 Pod 数与 5xx 峰值
```

## 七、面试追问速答

**Q：PDB 和 Deployment 的 maxUnavailable 有什么区别？**
PDB 约束**自愿驱逐**（Eviction API），Deployment 的 maxUnavailable 约束**滚动更新**时的删旧建新。两者互不感知，同时发生会叠加。

**Q：为什么 drain 之后 Pod 一直 Pending？**
新节点没有足够资源、亲和性/污点不匹配、或 PVC 的拓扑限制（local PV / 单 AZ 云盘）。先看 `kubectl describe pod` 的 Events。

**Q：DaemonSet 的 Pod 会阻塞 drain 吗？**
不会阻塞，但默认不驱逐。加 `--ignore-daemonsets` 表示"跳过它们"，节点上的 DaemonSet Pod 会随节点重启自然重建。

**Q：PDB 能防住 OOMKilled 吗？**
不能。OOMKilled 是 cgroup 层杀进程，属于"非自愿中断"，PDB 完全不参与。这类保护要靠 QoS、`memory.high` 限流与堆外内存预算。

**Q：StatefulSet 的 drain 有什么额外风险？**
有状态 Pod 通常不能并发重建，且可能绑定 PVC 的可用区；同时 PDB 对 StatefulSet 生效但 `podManagementPolicy: OrderedReady` 会拉长重建时间，维护窗口要按"最慢单副本恢复时间 × 副本数"估算。

**Q：怎么验证 PDB 配置真的有效？**
在预发集群做一次 drain 演练，观察 `DisruptionsAllowed` 与 5xx；再故意把副本缩到 `minAvailable`，确认 drain 会阻塞——能阻塞才说明 PDB 真的在生效。

## 八、踩坑清单

| 坑 | 表现 | 正确做法 |
|---|---|---|
| `minAvailable: 100%` | drain 永久阻塞 | 用 `maxUnavailable: 1` |
| 直接 `--force` | 502 尖峰 | 先扩容再 drain |
| PDB selector 写错 label | PDB 匹配 0 个 Pod，形同虚设 | `kubectl get pdb -o wide` 核对 |
| 发布与维护同窗口 | 可用副本腰斩 | 冻结发布或分批 |
| 没有 preStop | drain 期间稳定 5xx | preStop sleep 5~15s |
| 忽略 DaemonSet 的本地日志 | 节点重启后日志丢失 | 日志外送，别存 emptyDir |
| 只按 app 选 | 单 AZ 副本被清空 | 加 zone 维度 + 拓扑打散 |

## 小结

PDB 不是"高可用开关"，它只是**自愿驱逐的预算闸门**。真正的节点维护安全来自四件事的组合：正确的预算（`maxUnavailable` 而非 100%）、足够的冗余（维护前先扩容）、干净的流量摘除（preStop + readiness）、以及错开的变更窗口。把这条链路讲清楚，比背十个 kubectl 参数更能体现工程判断力。
