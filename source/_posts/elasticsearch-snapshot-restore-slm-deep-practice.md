---
title: 【ES 运维】Elasticsearch 快照与恢复深度实战：增量段去重、SLM 生命周期与恢复演练
date: 2026-11-23 08:40:00
tags:
  - Java
  - Elasticsearch
  - 数据备份
  - 运维
categories:
  - 中间件
author: 东哥
---

# 【ES 运维】Elasticsearch 快照与恢复深度实战

## 面试官：ES 集群要备份，直接 `cp -r data/` 行不行？

不行，而且这是能把恢复窗口从"小时级"变成"永远"的错误。

Lucene 的段文件在写入过程中不断变化：`refresh` 生成新 segment、`merge` 合并旧段并删除文件、`translog` 记录未落盘的写操作。**直接拷贝目录会拿到一个跨时刻的、不一致的文件集合**，更别提 Lucene 还依赖 `segments_N` 这类提交点文件的原子切换。你拷到的很可能是一个永远打不开的索引。

ES 官方给的路径是 Snapshot & Restore（下称快照）。它的正确理解方式是：**快照不是"复制数据"，而是"记录一组不可变段文件的引用 + 集群元数据"**。这个定义直接推出了它的全部特性：快照很快、增量天然成立、恢复只还原到快照时刻、和 translog 无关。

## 一、快照的物理本质

```
索引 = 多个 segment（不可变） + 一个 commit point（segments_N）
                    ↑
            写入只产生新段，从不改旧段
merge 后：旧段被删除，新段生成
```

因为段不可变，快照只需要：

1. 触发一次 flush，确保当前写入落到段（或至少把 translog 里已 flush 的部分固化）。
2. 记录当前所有 segment 文件的**文件名与大小**（文件名里带 UUID，全局唯一）。
3. 把仓库里"还缺的段文件"上传上去。

于是增量是**天然**的：第二次快照时，绝大多数段文件和上次同名同大小，仓库里已有，直接跳过；只有 merge 新产生的段需要上传，外加一个很小的元数据文件。这就是为什么"1TB 索引的每日快照"可能只传几十 GB——传的是**变化量**，不是全量。

反过来说，**merge 是增量大小的主要驱动**。如果你的索引每天大量 merge，快照增量就会偏大；`forcemerge` 之后第一次快照会一次性上传大量新段，要避开业务高峰。

## 二、仓库配置：三种常见形态

```json
// 1) 共享文件系统（所有节点必须能访问同一路径）
PUT _snapshot/fs_backup
{
  "type": "fs",
  "settings": {
    "location": "/mnt/es-backup",
    "compress": true,
    "max_snapshot_bytes_per_sec": "200mb",
    "max_restore_bytes_per_sec": "200mb"
  }
}
```

```json
// 2) S3（需安装 repository-s3 插件）
PUT _snapshot/s3_backup
{
  "type": "s3",
  "settings": {
    "bucket": "prod-es-snapshot",
    "base_path": "es/2026",
    "server_side_encryption": true,
    "storage_class": "standard_ia"
  }
}
```

```json
// 3) 只读 URL 仓库（用于跨集群分发/归档）
PUT _snapshot/url_backup
{
  "type": "url",
  "settings": { "url": "file:/mnt/readonly-snapshots" }
}
```

三个必须知道的约束：

- **`path.repo` 必须在 `elasticsearch.yml` 里配置且重启生效**，仓库路径必须是它的子目录。忘了配就会得到 `repository_verification_exception: path.repo not set`。
- **同一仓库同一时刻只能有一个快照在跑**（`snapshot.max_concurrent_operations` 默认 1）。多个索引并行会分散到不同节点，但快照任务本身是串行的。
- **仓库元数据由 master 写**：`_snapshot` 的写入是集群级操作，master 抖动会导致快照失败（`master_not_discovered_exception`），不是存储的问题。

## 三、快照与 SLM：把"记得备份"变成策略

手工快照一定会忘。SLM（Snapshot Lifecycle Management）就是定时器 + 保留策略：

```json
PUT _slm/policy/daily-prod
{
  "schedule": "0 30 2 * * ?",          // 每天 02:30
  "name": "<prod-{now/d}>",            // 索引名带日期
  "repository": "s3_backup",
  "config": {
    "indices": ["orders-*", "users-*", "logs-*"],
    "ignore_unavailable": true,
    "include_global_state": false,     // 关键：不要把集群级状态一起回滚
    "partial": false                   // 有索引不可用就整体失败，避免"半份备份"
  },
  "retention": {
    "expire_after": "7d",
    "min_count": 3,
    "max_count": 10
  }
}
```

两个反直觉的点：

**1. `include_global_state: true` 是危险默认。** 它会把索引模板、ILM 策略、持久化集群设置一起写进快照。恢复时如果勾选它，可能把**现在的**模板覆盖成七天前的版本，导致新索引建错 mapping。生产建议 `false`，模板用 Git 管理。

**2. `partial: false` 让失败变"可见"。** 如果某个索引正好在 relocate，快照可能失败；`partial: true` 会跳过不可用索引生成"部分快照"，看起来很成功，恢复时才发现少了一个索引。宁可失败告警，也不要静默残缺——除非你明确知道自己在做什么。

## 四、恢复：三个硬约束

```json
POST _snapshot/s3_backup/prod-2026.11.23/_restore
{
  "indices": "orders-2026.11",
  "ignore_unavailable": true,
  "include_global_state": false,
  "rename_pattern": "orders-(.+)",
  "rename_replacement": "orders-restored-$1",
  "include_aliases": false,
  "index_settings": {
    "index.number_of_replicas": 0
  }
}
```

约束一：**目标索引必须不存在或已 close**。想恢复到同名索引，先 close 或删掉；想保留原索引，就用 `rename_pattern` 改名。

约束二：**恢复顺序是"先主分片、后副本"**，且副本在恢复期间不分配。所以恢复大索引时把 `number_of_replicas` 临时设为 0，恢复完再 `PUT settings` 调回来，能显著缩短时间——省掉的是"边恢复边复制"的双倍网络与磁盘 IO。

约束三：**恢复速度受 `max_restore_bytes_per_sec` 与磁盘吞吐双重限制**。默认 40MB/s 往往太保守；NVMe 集群可以调到 200~500MB/s，但要先用一台节点测顺序读带宽，别把恢复流量和业务查询抢在一起。

恢复不是 PITR（point-in-time recovery）：**RPO 等于快照间隔**。想要 5 分钟级 RPO，靠的是副本 + CCR，不是快照。

## 五、容量与成本算例

假设：`orders-*` 共 1.2TB，日增 40GB，merge 导致每天约 15% 的数据被重写，保留 7 天。

```
首次全量快照：    1.2TB（压缩后约 0.6~0.8TB，取决于字段类型）
每日增量：        约 40GB 新增 + 1.2TB × 15% 的重写段
                ≈ 40 + 180 = 220GB（未压缩）
7 天总量：        约 0.8TB + 6 × 0.15TB ≈ 1.7TB（压缩后）
```

如果用的是 S3 Standard-IA，1.7TB 月成本约几十美元，比"多一套从库"便宜一个数量级。但如果索引是日志类且 `logsdb` 模式（合成 `_source`），快照体积会比原数据小很多——因为 `_source` 不再单独存。

一个常被忽略的成本：**快照流量**。跨 AZ/跨 region 写 S3 会产生出网费用，别把仓库配在另一个 region。

## 六、Java 侧：把恢复演练自动化

备份的价值只有在"恢复成功"时才成立。建议每月做一次自动演练：恢复到隔离集群 → 校验文档数与抽样内容 → 报告。

```java
@Component
public class SnapshotDrillJob {

    private final RestClient client;   // 复用业务 ES 客户端
    private final ObjectMapper mapper = new ObjectMapper();

    /** 1. 触发恢复到演练集群（不同 endpoint） */
    public String startRestore(String snapshot, String index, String target) throws Exception {
        String body = """
            {
              "indices": "%s",
              "include_global_state": false,
              "rename_pattern": "(.+)",
              "rename_replacement": "%s-$1",
              "index_settings": { "index.number_of_replicas": 0 }
            }
            """.formatted(index, target);

        Response resp = client.performRequest(new Request(
            "POST", "/_snapshot/s3_backup/" + snapshot + "/_restore",
            Map.of("wait_for_completion", "false"),
            new StringEntity(body, ContentType.APPLICATION_JSON)));

        return mapper.readTree(resp.getEntity().getContent()).get("snapshot").get("name").asText();
    }

    /** 2. 轮询恢复状态 */
    public boolean waitDone(String index, Duration timeout) throws Exception {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (System.nanoTime() < deadline) {
            Response r = client.performRequest(new Request(
                "GET", "/" + index + "/_recovery", Map.of("active_only", "true")));
            JsonNode root = mapper.readTree(r.getEntity().getContent());
            boolean active = root.elements().next().get("shards").elements().next()
                                 .get("stage").asText().equals("DONE") == false;
            if (!active) return true;
            Thread.sleep(5_000);
        }
        return false;
    }

    /** 3. 校验：文档数 + 抽样主键存在性 */
    public void verify(String index, long expectedDocs) throws Exception {
        Response count = client.performRequest(new Request("GET", "/" + index + "/_count"));
        long actual = mapper.readTree(count.getEntity().getContent()).get("count").asLong();
        if (actual != expectedDocs) {
            throw new IllegalStateException(
                "doc count mismatch: expected=" + expectedDocs + ", actual=" + actual);
        }
    }
}
```

三个工程细节：

- **`wait_for_completion=false`**：恢复可能几十分钟，同步等待会超时。用轮询 + 告警，而不是阻塞线程。
- **校验不要只比文档数**：文档数相同但内容错位是可能的（比如恢复到了错误快照）。抽样 100 条按 `_id` 取回比对 `_source` 的哈希。
- **演练集群要真的隔离**：不要在同集群用改名恢复做演练，`number_of_replicas: 0` 的临时设置如果忘了改回来，会造成副本缺失。

## 七、故障速查表

| 现象 | 根因 | 处理 |
|---|---|---|
| `path.repo not set` | 未配置仓库根路径 | 改 `elasticsearch.yml` 并滚动重启 |
| `repository_verification_exception` | 节点无写权限/路径不可见 | 检查挂载与 `chown elasticsearch` |
| 快照成功但恢复缺索引 | `partial: true` 跳过了不可用索引 | 改 `false`，失败即告警 |
| 恢复卡在 `INIT`/`PEER` | 磁盘水位超限、分片分配被禁 | 检查 watermark 与 `cluster.routing.allocation.enable` |
| 恢复后 alias 丢了 | `include_aliases: false` | 恢复后重建 alias，写进 Runbook |
| 恢复后 mapping 变了 | `include_global_state: true` 覆盖了模板 | 关掉它，模板走 Git |
| 快照体积暴涨 | merge 频繁 / `forcemerge` 后首快照 | 避开高峰，监控仓库增长速率 |
| 快照超时 | master 抖动 / 仓库限流 | 看 master 日志与 `max_snapshot_bytes_per_sec` |

## 八、面试追问

**Q：快照是热备吗？能直接切流吗？**
不是。快照是冷备，RPO = 间隔。要热备用 CCR（跨集群复制），但它复制的是操作而不是段，且不能替代归档。

**Q：为什么快照不需要停写？**
因为段不可变，快照引用的段在快照期间不会被修改；merge 只会删除"未被引用"的旧段，仓库里的段文件仍然完整。

**Q：快照期间 merge 会不会导致快照损坏？**
不会。快照开始时会固定一份段清单，merge 删掉本地文件不影响仓库里已上传的副本；如果某段还没上传就被 merge 删除，ES 会重新从新段上传。

**Q：恢复 1TB 索引要多久？**
取决于磁盘顺序读带宽与 `max_restore_bytes_per_sec`。单节点 500MB/s 顺序读，理想情况 30~40 分钟；实际受分片并行度、副本设置、网络影响，通常按 1~2 小时估算。

**Q：能不能只恢复某几个文档？**
不能。快照是索引/分片级。要文档级恢复，只能恢复到临时索引再用 `_reindex` 挑出来。

## 小结

ES 快照的核心认知只有一句：**快照记录的是不可变段的引用，所以又快又增量**。围绕这句话，仓库配置、SLM 策略、恢复的副本技巧、以及"快照不是 PITR"的边界，都能自然推出来。真正拉开差距的是最后一步——**定期演练恢复**，因为没演练过的备份，只是一个占用存储的假设。
