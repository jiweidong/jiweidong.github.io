---
title: 云原生存储技术对比与实践：Ceph vs Longhorn vs JuiceFS
date: 2026-06-19 08:00:00
tags:
  - 云原生
  - 存储
  - Ceph
  - Longhorn
  - JuiceFS
categories:
  - DevOps
author: 东哥
---

## 引言

随着 Kubernetes 成为容器编排的事实标准，有状态应用（StatefulSet、数据库、中间件）的上云需求日益迫切。云原生存储不再是"存数据"那么简单，它关乎性能、扩展性、运维成本和企业级可靠性。当前社区最热门的三个云原生存储方案分别是：Ceph（SDS 软件定义存储标杆）、Longhorn（K8s 原生轻量存储）、JuiceFS（面向云原生的分布式文件系统）。本文将从架构原理、部署实践、性能对比和选型建议四个维度，带读者全面了解这三个方案。

## 一、Ceph：老牌 SDS 的全面能力

### 1.1 架构核心：RADOS 与 CRUSH

Ceph 的基石是 **RADOS**（Reliable Autonomic Distributed Object Store），一个自愈、自管理的分布式对象存储层。所有数据最终都以对象形式存储在 RADOS 中，每个对象默认 4MB，分布在集群的 OSD（Object Storage Daemon）上。

Ceph 使用 **CRUSH**（Controlled Replication Under Scalable Hashing）算法替代了传统的元数据查询中心节点。客户端直接通过 CRUSH 计算出数据所在位置，无需 Query 任何中心化的元数据服务。这使得 Ceph 拥有理论上无限的水平扩展能力。

```
┌─────────────────────────────────────────────────┐
│              应用 / 客户端                         │
│  ┌──────┐  ┌──────┐  ┌──────┐                    │
│  │ RBD  │  │ RGW  │  │CephFS│  ← 三种访问接口     │
│  └──┬───┘  └──┬───┘  └──┬───┘                    │
│     └─────────┼─────────┘                         │
│               │  librados                          │
│               ▼                                    │
│         ┌──────────┐                               │
│         │ RADOS 层 │  ← 自愈分布式对象存储          │
│         │ CRUSH算法 │  ← 去中心化数据分布           │
│         └──────────┘                               │
└─────────────────────────────────────────────────┘
```

### 1.2 三种访问接口

| 接口 | 协议 | 典型场景 | 特点 |
|------|------|---------|------|
| **RBD** (RADOS Block Device) | `librbd` / Kernel 模块 | Kubernetes PVC（块存储）、虚拟机磁盘 | 低延迟、高性能、支持快照/克隆 |
| **RGW** (RADOS Gateway) | S3 / Swift 兼容 API | 对象存储、备份归档、媒体存储 | 兼容 AWS S3 API，HTTP 访问 |
| **CephFS** | POSIX 文件系统 | 共享文件系统、HPC 作业、日志 | 多客户端挂载、支持元数据分片 |

### 1.3 Bluestore 与性能调优

Ceph 的 OSD 后端从 Filestore（基于 XFS）演进到 **Bluestore**，后者直接管理裸设备，跳过了文件系统层，显著降低写放大。

```bash
# 查看 OSD 的 Bluestore 状态
ceph osd metadata <osd-id> | grep bluestore

# 关键调优参数示例
ceph config set osd osd_op_num_threads_per_shard 2
ceph config set osd osd_op_num_shards 8
ceph config set osd bluestore_block_size 1073741824         # 1GB block
ceph config set osd bluestore_cache_size_hdd 1G             # HDD 缓存
ceph config set osd bluestore_cache_size_ssd 3G             # SSD 缓存
ceph config set osd osd_memory_target 4G                    # OSD 进程内存上限
```

**调优重点：**
- **网络**: 推荐 25GbE 以上网卡，分离 Public 与 Cluster 网络
- **存储介质**: OSD 使用 NVMe SSD + 大容量 HDD 混搭
- **PG 数量**: `PG数 = (OSD总数 × 100) / 副本数`
- **内存**: 每个 OSD 至少 4GB 内存，建议 8GB+

### 1.4 部署复杂度

Ceph 的部署复杂度公认较高。目前社区主要使用 **Rook Operator**（K8s 原生部署 Ceph）：

```bash
# 使用 Rook 部署 Ceph 集群
kubectl create -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/crds.yaml
kubectl create -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/common.yaml
kubectl create -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/operator.yaml

# 创建 CephCluster 资源
cat <<EOF | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  dataDirHostPath: /var/lib/rook
  mon:
    count: 3
    allowMultiplePerNode: false
  storage:
    useAllNodes: true
    useAllDevices: false
    config:
      databaseSizeMB: "1024"
      journalSizeMB: "1024"
    nodes:
    - name: "node1"
      devices:
      - name: "nvme0n1"
      - name: "sdb"
EOF

# 创建 StorageClass 给 K8s 使用
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

# 验证集群状态
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

Ceph 集群的日常运维涉及 MON 选举、OSD 替换、PG 修复、scrub 调度等复杂操作，建议团队至少配置一名专职存储工程师。

## 二、Longhorn：K8s 原生的轻量级存储

### 2.1 Engine / Replica 架构

Longhorn 是 Rancher（现 SUSE）开源的 K8s 原生分布式块存储，采用微服务架构，每个卷由一个 Engine（管理实例）和多个 Replica（副本实例）组成。

```
              Pod
               │
        ┌──────┴──────┐
        │  Longhorn   │
        │  Engine     │  ← 接收 iSCSI/SPDK I/O 请求，管理副本
        └──────┬──────┘
               │
     ┌─────────┼─────────┐
     │         │         │
     ▼         ▼         ▼
  Replica1  Replica2  Replica3  ← 每个副本在不同的 K8s 节点上
     │         │         │
     ▼         ▼         ▼
  /host/...  /host/...  /host/...  ← 本地磁盘目录
```

- **Engine**: 每个卷的 I/O 入口，实现读写复制与数据同步
- **Replica**: 数据的物理副本，默认 3 副本
- 通过 **iSCSI** 或 **SPDK**（v1.4+）暴露块设备

### 2.2 卷快照与备份

Longhorn 的快照基于 **copy-on-write (CoW)**，秒级创建，几乎不占空间（仅记录差异块）。

```bash
# 创建卷快照
longhornctl snapshot create --volume pvc-xxx-yyy

# 创建周期性快照（通过 VolumeSnapshotClass）
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
driver: driver.longhorn.io
deletionPolicy: Delete
EOF
```

**灾难恢复配置**，Backup Target 支持 S3、NFS、Azure Blob、Google Cloud Storage：

```bash
# 设置 S3 备份目标（通过 Longhorn UI 或 kubectl）
kubectl -n longhorn-system edit settings.longhorn.io backup-target

# 配置内容示例
# backup-target: "s3://my-bucket@ap-east-1/"
# backup-target-credential-secret: "s3-secret"
```

灾难恢复操作：
```
1. 在新集群中安装 Longhorn
2. 配置同样的 Backup Target
3. 在 UI 中点击 "Restore Latest Backup"
4. Longhorn 会自动从 S3 拉取数据并创建卷
```

每个卷的快照和备份都支持 **可恢复的增量备份**（基于快照差异），这是相比 Ceph 的一个易用性亮点。

### 2.3 iSCSI vs SPDK

| 特性 | iSCSI（传统） | SPDK（v1.4+） |
|------|-------------|--------------|
| 处理路径 | 内核 iSCSI → 用户空间 | 纯用户空间轮询模式 |
| 延迟 | ~200μs | ~30μs |
| CPU 占用 | 上下文切换开销大 | 无中断、轮询模式 |
| 吞吐量 | 中等 | 高（接近裸设备） |
| 兼容性 | 所有 Linux 内核 | 需要 Hugepage + 特定驱动 |

SPDK 模式需要额外配置：

```bash
# 启用 SPDK（需要在 Longhorn 设置中启用）
# Settings → General → Enable SPDK

# SPDK 需要分配给 Engine 的 CPU 隔离
# 建议预留 4 个以上的物理核
```

### 2.4 运维体验

Longhorn 最大的亮点是 **UI 管理界面**。通过 Longhorn Dashboard，用户可以：

- 直观查看集群存储使用情况
- 操作卷的创建、扩容、快照、备份、克隆
- 重建失败的 Replica
- 管理节点和磁盘
- 实时监控 I/O 性能

运维简单，普通 K8s 工程师即可上手。生产环境中建议关注 Replica 重建对集群 I/O 的影响。

## 三、JuiceFS：云原生的分布式文件系统

### 3.1 架构总览

JuiceFS 是一个面向云环境的 POSIX 兼容分布式文件系统，采用 **数据与元数据分离** 的架构：

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│ JuiceFS CLI  │   │ JuiceFS FUSE │   │  CSI Driver  │  ← 多种挂载方式
│    客户端    │   │   客户端     │   │   (K8s)      │
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │
           ┌─────────────┴─────────────┐
           │      Metadata Engine       │  ← Redis / MySQL / PostgreSQL / SQLite
           └─────────────┬─────────────┘
                         │
           ┌─────────────┴─────────────┐
           │      Object Storage        │  ← S3 / MinIO / Ceph RGW / GCS / OSS
           └───────────────────────────┘
```

**元数据引擎**支持多种选择，各有优劣：

| 元数据引擎 | 场景 | 性能 | 可用性 |
|-----------|------|------|--------|
| **Redis** | 高性能低延迟，小文件密集 | 极高（NAS 级别） | 需 Redis Sentinel/Cluster 加持 |
| **MySQL** | 一致性优先，事务需求 | 中等 | Mysql HA 成熟 |
| **PostgreSQL** | 复杂查询、多事务 | 中等偏上 | PG HA（Patroni） |
| **SQLite** | 单机测试、小规模 | 低 | 不支持多节点 |
| **TiKV** | 云原生、水平扩展 | 高 | TiDB 集群 |

### 3.2 数据存储与缓存

JuiceFS 将文件内容切分为默认 4MB 的 Chunk（可配置），每个 Chunk 进一步分为 64KB 的 Slice，最终以对象形式存储在对象存储中。

**缓存机制**是 JuiceFS 性能的关键：

```bash
# 创建文件系统
juicefs format \
  --storage s3 \
  --bucket https://my-bucket.s3.ap-east-1.amazonaws.com \
  --access-key AKIA... \
  --secret-key ... \
  redis://localhost:6379/1 \
  myjfs

# 挂载文件系统（使用本地缓存）
juicefs mount \
  --cache-dir /var/jfsCache \
  --cache-size 102400 \      # 100GB 本地缓存
  --free-space-ratio 0.1 \   # 缓存目录保留 10% 空闲空间
  --attr-cache 7200 \        # 属性缓存 2h
  --entry-cache 7200 \       # 条目缓存 2h
  --dir-entry-cache 7200 \   # 目录条目缓存 2h
  redis://localhost:6379/1 \
  /mnt/jfs
```

### 3.3 Kubernetes CSI 集成

```yaml
---
# StorageClass 配置
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: juicefs-sc
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: juicefs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-publish-secret-name: juicefs-secret
  csi.storage.k8s.io/node-publish-secret-namespace: default
---
# PVC 使用
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: juicefs-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: juicefs-sc
  resources:
    requests:
      storage: 10Gi
---
# Deployment 挂载
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: app
        image: nginx:alpine
        volumeMounts:
        - name: shared-data
          mountPath: /data
      volumes:
      - name: shared-data
        persistentVolumeClaim:
          claimName: juicefs-pvc
```

## 四、三方详细对比

### 4.1 性能基准对比（基于三副本、NVMe SSD 集群）

| 指标 | Ceph RBD | Longhorn (iSCSI) | Longhorn (SPDK) | JuiceFS (Redis) |
|------|----------|-----------------|-----------------|-----------------|
| **4K 随机读 IOPS** | 40K~80K | 10K~25K | 30K~60K | 15K~30K |
| **4K 随机写 IOPS** | 20K~40K | 6K~15K | 15K~35K | 8K~20K |
| **顺序读 MB/s** | 800~1500 | 300~600 | 600~1200 | 400~800 |
| **顺序写 MB/s** | 400~800 | 200~400 | 400~800 | 200~500 |
| **写延迟 (P99)** | ~1ms | ~5ms | ~1.5ms | ~3ms |
| **读延迟 (P99)** | ~0.5ms | ~3ms | ~1ms | ~1ms |

> 数据基于 3 节点、全 NVMe SSD、25GbE 网络测试，不同环境差异较大。

### 4.2 功能与运维对比

| 维度 | Ceph | Longhorn | JuiceFS |
|------|------|----------|---------|
| **存储类型** | 块/对象/文件 | 块 | 文件（POSIX） |
| **K8s 集成** | Rook Operator | 原生 CSI + UI | CSI Driver |
| **快照** | ✅ RBD 原生快照 | ✅ CoW 快照 | ✅ 分钟级快照 |
| **备份恢复** | rbd export/import | Backup to S3/NFS | dump + S3 |
| **灾难恢复** | 跨集群 RBD mirror | Backup Target 恢复 | 跨集群恢复 |
| **多读多写** | 仅 CephFS（性能受限） | ❌ 单节点挂载 | ✅ 原生多读多写 |
| **扩容方式** | 加 OSD + 自动再平衡 | 加节点 + 再平衡 | 扩容对象存储 + Redis |
| **运维门槛** | ⭐高（需专用团队） | ⭐低（K8s 团队即可） | ⭐中（需 Redis 管理） |
| **监控指标** | Prometheus Exporter 丰富 | 内置 Prometheus | Prometheus + 客户端指标 |
| **社区活跃度** | 极高（Star 14K+） | 高（Star 8K+） | 高（Star 11K+） |

### 4.3 生产案例参考

| 方案 | 典型用户 | 场景 |
|------|---------|------|
| **Ceph** | 腾讯云、华为云、SAP、中国移动 | 大规模虚拟化、私有云 Iaas |
| **Longhorn** | 知乎、Shopify、Spotify | K8s 数据库、有状态微服务 |
| **JuiceFS** | 字节跳动、小红书、知乎 | AI 训练数据、日志、共享存储 |

## 五、选型建议

### 选择 Ceph 当...

- 团队有专职存储工程师
- 已建设或计划建设私有云
- 需要同时提供块、文件、对象三种存储
- 集群规模在 100+ 节点

### 选择 Longhorn 当...

- 中小规模 K8s 集群（5~50 节点）
- 团队以 K8s 运维为主，没有存储专家
- 需要简单的快照和灾难恢复
- 对 IOPS 没有极致要求

### 选择 JuiceFS 当...

- 需要 POSIX 兼容的文件系统
- AI/ML 训练数据场景需要多节点共享
- 对象存储（S3/MinIO）已有现成部署
- 小文件密集场景（Redis 元数据引擎）

## 六、总结

三个方案没有绝对的优劣，更多是场景匹配度的问题。Ceph 提供最全面的存储能力但运维成本最高；Longhorn 胜在 K8s 原生体验和易用性；JuiceFS 在文件共享和 AI 场景独具优势。建议根据团队技术储备和业务需求，选择最适合的方案，或者组合使用（Ceph RBD + JuiceFS 共享文件系y统）。在云原生时代，存储已经不再只是"存数据"，它是架构决策的核心组成部分。

如果你正在做选型决策，最好的方式是在非生产环境搭建 POC，用实际业务负载跑性能测试。书籍里的数字永远只是参考，你的业务数据说真话。
