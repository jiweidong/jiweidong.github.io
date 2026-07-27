---
title: 【Kafka源码】Kafka Producer 发送流程源码深度解析：从 send() 到分区选择与批处理
date: 2026-07-27 08:00:00
tags:
  - Kafka
  - Producer
  - 源码分析
  - 消息队列
categories:
  - 中间件
  - Kafka
author: 东哥
---

# 【Kafka源码】Kafka Producer 发送流程源码深度解析：从 send() 到分区选择与批处理

## 前言

在 Kafka 客户端三剑客中，Producer 是最复杂也最体现设计智慧的一个。当你调用 `producer.send()` 时，消息并不是直接发到 Broker——而是要经过**拦截器 → 序列化器 → 分区器 → 累加器 → 发送线程**等一系列流程。

理解 Producer 的完整发送链路，是深入掌握 Kafka 性能调优和问题排查的关键。

本文基于 **Kafka 3.x 源码**，逐层解析 Producer 发送流程的每一个环节。

---

## 一、Producer 整体架构

先上大图——Kafka Producer 的内部模块：

```
┌─────────────────────────────────────────────────────────┐
│                    KafkaProducer                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │Interceptor│→│Serializer│→│Partitioner│              │
│  └──────────┘  └──────────┘  └──────────┘              │
│                        ↓                                │
│  ┌─────────────────────────────────────────────────┐   │
│  │             RecordAccumulator                    │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐           │   │
│  │  │Batch(tp0)│ │Batch(tp1)│ │Batch(tp2)│  ...    │   │
│  │  └─────────┘ └─────────┘ └─────────┘           │   │
│  └─────────────────────┬───────────────────────────┘   │
│                        ↓                                │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Sender Thread                       │   │
│  │  ↓ 对每个 Node 构建请求 → NetworkClient → Broker  │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

用户调用 `send()` 是**异步非阻塞**的——消息进入 accumulator 缓冲后立即返回 Future。真正的网络发送由独立的 **Sender 线程**完成。

---

## 二、send() 方法入口

```java
// KafkaProducer.java
@Override
public Future<RecordMetadata> send(ProducerRecord<K, V> record) {
    return send(record, null);
}

@Override
public Future<RecordMetadata> send(ProducerRecord<K, V> record, Callback callback) {
    // 1. 拦截器处理
    ProducerRecord<K, V> interceptedRecord = this.interceptors.onSend(record);
    
    // 2. 异步发送核心逻辑
    return doSend(interceptedRecord, callback);
}
```

`interceptors.onSend()` 依次调用所有注册的 ProducerInterceptor：

```java
// 自定义拦截器示例
public class MetricsInterceptor implements ProducerInterceptor<String, String> {
    @Override
    public ProducerRecord<String, String> onSend(ProducerRecord<String, String> record) {
        // 可在发送前修改 record 或附加统计信息
        return record;
    }
    
    @Override
    public void onAcknowledgement(RecordMetadata metadata, Exception exception) {
        // 发送确认后的回调
    }
}
```

---

## 三、doSend 核心逻辑

```java
private Future<RecordMetadata> doSend(ProducerRecord<K, V> record, Callback callback) {
    TopicPartition tp = null;
    try {
        // 1. 元数据获取与等待
        ClusterAndWaitTime clusterAndWaitTime = waitOnMetadata(record.topic(), 
            record.partition(), maxBlockTimeMs);
        long remainingWaitMs = Math.max(0, maxBlockTimeMs - clusterAndWaitTime.waitedOnMetadataMs);
        Cluster cluster = clusterAndWaitTime.cluster;
        
        // 2. 序列化 key 和 value
        byte[] serializedKey = keySerializer.serialize(record.topic(), 
            record.headers(), record.key());
        byte[] serializedValue = valueSerializer.serialize(record.topic(), 
            record.headers(), record.value());
        
        // 3. 确定分区
        int partition = partition(record, serializedKey, serializedValue, cluster);
        tp = new TopicPartition(record.topic(), partition);
        
        // 4. 设置消息头
        Header[] headers = record.headers().toArray();
        
        // 5. 估算消息大小，检查是否超过 max.request.size
        int serializedSize = AbstractRecords.estimateSizeInBytesUpperBound(
            apiVersions.maxUsableProduceMagicBytes(),
            compressionType, serializedKey, serializedValue, headers);
        ensureValidRecordSize(serializedSize);
        
        // 6. 写入 accumulator
        long timestamp = record.timestamp() == null ? time.milliseconds() : record.timestamp();
        RecordAccumulator.RecordAppendResult result = accumulator.append(
            tp, timestamp, serializedKey, serializedValue, headers, 
            interceptCallback, remainingWaitMs, true, nowMs);
        
        // 7. 唤醒 Sender 线程
        if (result.batchIsFull || result.newBatchCreated) {
            log.trace("Waking up the sender since topic {} partition {} is either full or getting a new batch",
                record.topic(), partition);
            this.sender.wakeup();
        }
        
        return result.future;
    } catch (...) {
        // 异常处理
    }
}
```

### 3.1 waitOnMetadata — 元数据获取阻塞

```java
// 关键：如果元数据过期或 topic 不存在，会阻塞等待
private ClusterAndWaitTime waitOnMetadata(String topic, Integer partition, long maxWaitMs) {
    // 从 Metadata 缓存中获取集群信息
    Cluster cluster = metadata.fetch();
    
    // 如果 topic 不在缓存中或元数据过期
    if (cluster.needsRefresh() || !cluster.topics().contains(topic)) {
        // 请求更新元数据
        metadata.add(topic, now);
        metadata.requestUpdate();
        // 唤醒 Sender 发送 MetadataRequest
        sender.wakeup();
        
        // 阻塞等待——最多等 maxWaitMs
        do {
            // 从唤醒中再次获取新的 metadata
            cluster = metadata.fetch();
            // ... 等待通知或超时
        } while (cluster.needsRefresh() || ...);
    }
    return cluster;
}
```

**调优启示**：`metadata.max.age.ms`（默认 5 分钟）控制元数据刷新间隔。如果频繁发送新 topic 的消息，适当缩短这个值可以减少首次发送的等待时间。

---

## 四、分区选择策略

```java
private int partition(ProducerRecord<K, V> record, byte[] serializedKey, 
                      byte[] serializedValue, Cluster cluster) {
    Integer partition = record.partition();
    // 1. 用户指定了分区 —— 直接用
    if (partition != null) {
        return partition;
    }
    
    // 2. 使用分区器
    return this.partitioner.partition(
        record.topic(), record.key(), serializedKey, 
        record.value(), serializedValue, cluster);
}
```

### 4.1 默认分区器（DefaultPartitioner）

Kafka 3.x 默认分区策略是 **Sticky Partition**（粘性分区）：

```java
// DefaultPartitioner 核心逻辑
public int partition(String topic, Object key, byte[] keyBytes, 
                     Object value, byte[] valueBytes, Cluster cluster) {
    List<PartitionInfo> partitions = cluster.partitionsForTopic(topic);
    int numPartitions = partitions.size();
    
    // 有 key：对 key 取 hash
    if (keyBytes != null) {
        return Utils.toPositive(Utils.murmur2(keyBytes)) % numPartitions;
    }
    
    // 无 key：使用粘性分区
    return stickyPartitionCache.partition(topic, cluster);
}
```

**Sticky Partition** 的工作机制：

```
传统轮询（v2.4 之前）：
batch1: [msg1] → partition 0
batch2: [msg2] → partition 1
batch3: [msg3] → partition 2
→ 每个 batch 很小，请求数量多

粘性分区（v2.4+）：
batch1: [msg1, msg2, msg3, msg4, msg5] → partition 0
batch2: [msg6, msg7, msg8, msg9, msg10] → partition 1
→ batch 更大，请求更少，吞吐量更高
```

### 4.2 自定义分区器

```java
public class CustomPartitioner implements Partitioner {
    @Override
    public int partition(String topic, Object key, byte[] keyBytes,
                         Object value, byte[] valueBytes, Cluster cluster) {
        // 按业务维度分区：例如 orderId % 分区数
        String orderId = (String) key;
        return Math.abs(orderId.hashCode()) % cluster.partitionCountForTopic(topic);
    }
    
    @Override
    public void close() {}
    
    @Override
    public void configure(Map<String, ?> configs) {}
}
```

```properties
# 配置自定义分区器
partitioner.class=com.example.CustomPartitioner
```

---

## 五、RecordAccumulator — 消息累加器

这是 Producer 最精妙的设计——**将小消息合并成大 batch**，减少网络请求次数。

### 5.1 accumulator 核心结构

```java
public final class RecordAccumulator {
    // 核心数据结构：Map<TopicPartition, Deque<ProducerBatch>>
    private final ConcurrentMap<TopicPartition, Deque<ProducerBatch>> batches;
    
    // BufferPool —— 内存池，避免频繁 GC
    private final BufferPool free;
    
    // 管理未完成 batch 的大小追踪
    private final IncompleteBatches incomplete;
    
    // ... 构造函数参数
}
```

### 5.2 append 方法执行流程

```java
public RecordAppendResult append(TopicPartition tp,
                                  long timestamp, byte[] key, byte[] value, 
                                  Header[] headers, Callback callback, 
                                  long maxTimeToBlock, boolean abortOnNewBatch, long nowMs) {
    Deque<ProducerBatch> dq = getOrCreateDeque(tp);
    synchronized (dq) {
        // 1. 尝试追加到已有的 batch
        RecordAppendResult result = tryAppend(
            timestamp, key, value, headers, callback, dq, nowMs);
        if (result != null) return result;
    }
    
    // 2. 没有可用 batch 或 batch 已满 —— 分配新 batch
    //    从 BufferPool 申请内存
    int size = Math.max(this.batchSize, AbstractRecords.estimateSizeInBytesUpperBound(
        maxUsableMagic, compressionType, key, value, headers));
    
    ByteBuffer buffer = free.allocate(size, maxTimeToBlock);
    
    synchronized (dq) {
        // 再次尝试——防止并发下其他线程已经创建了新 batch
        RecordAppendResult result = tryAppend(...);
        if (result != null) {
            free.deallocate(buffer);
            return result;
        }
        
        // 创建新的 ProducerBatch
        MemoryRecordsBuilder recordsBuilder = MemoryRecords.builder(
            buffer, maxUsableMagic, compressionType, timestamp, batchSize);
        ProducerBatch batch = new ProducerBatch(tp, recordsBuilder, time.milliseconds());
        
        // 追加消息
        FutureRecordMetadata future = Utils.notNull(batch.tryAppend(...));
        
        dq.addLast(batch);
        incomplete.add(batch);
        
        return new RecordAppendResult(future, batch.size() > 0, 
            dq.size() > 1 || batch.isFull(), true);
    }
}
```

**关键要点**：

| 机制 | 说明 |
|------|------|
| BufferPool | 复用 ByteBuffer，避免 GC 压力。`buffer.memory` 控制总大小 |
| Deque<ProducerBatch> | 每个分区一个双端队列，Sender 从队首取 batch，Producer 往队尾追加 |
| tryAppend 两次 | 先不加锁尝试，再加锁尝试，最后才分配——这叫**乐观追加** |
| batch.size | 控制 batch 大小的上限，默认 16KB |

### 5.3 BufferPool 内存池

```java
public class BufferPool {
    private final long totalMemory;      // buffer.memory 配置值
    private final int poolableSize;      // batch.size 值（每个 ByteBuffer 大小）
    private final Deque<ByteBuffer> free; // 空闲 ByteBuffer 池
    private final Deque<Condition> waiters; // 等待内存的线程
    
    public ByteBuffer allocate(int size, long maxTimeToMs) {
        if (size == poolableSize) {
            // 恰好等于 batch.size —— 从池中取
            ByteBuffer buffer = free.pollFirst();
            if (buffer != null) return buffer;
        }
        
        // 池中没有空闲或尺寸不匹配：从堆内存分配
        int freeSize = free.size() * poolableSize;
        if (freeSize >= size) {
            // 有足够内存可以释放（回收已分配的内存）
            // 但需要先把池中的 ByteBuffer 释放给 JVM
            freeUp(size);
        }
        
        // 还不够？阻塞等待
        if (size > this.totalMemory - this.nonPooledAvailableMemory) {
            // 阻塞——等待有 batch 被发送出去释放内存
        }
        
        return ByteBuffer.allocate(size);
    }
}
```

**调优启示**：`buffer.memory` 默认 32MB，`batch.size` 默认 16KB。如果生产流量大，这两个值需要相应调大，不然 Producer 会因为拿不到内存而阻塞。

---

## 六、Sender 线程 — 攒够就发

### 6.1 run 方法主循环

```java
// Sender.java
void run(long now) {
    // 1. 从 accumulator 中获取已准备好的 batch
    //    按 Node 组织：Map<Node, List<ProducerBatch>>
    Map<Integer, List<ProducerBatch>> batches = accumulator.drain(
        cluster,  // 当前元数据
        maxRequestSize,
        now);
    
    // 2. 发送请求
    sendProducerData(now);
}

private void sendProducerData(long now) {
    // 遍历每个 Node
    for (Map.Entry<Integer, List<ProducerBatch>> entry : batches.entrySet()) {
        Node node = cluster.nodeById(entry.getKey());
        // 构建 ProduceRequest
        ProduceRequestData requestData = new ProduceRequestData();
        // ... 填充 batch 数据
        
        // 通过 NetworkClient 发送
        client.send(clientRequest, now);
    }
}
```

### 6.2 drain 方法：攒够的 batch 才发

```java
public Map<Integer, List<ProducerBatch>> drain(Cluster cluster, ...) {
    Map<Integer, List<ProducerBatch>> ready = new HashMap<>();
    
    for (Map.Entry<TopicPartition, Deque<ProducerBatch>> entry : this.batches.entrySet()) {
        TopicPartition tp = entry.getKey();
        Deque<ProducerBatch> dq = entry.getValue();
        
        // 检查 batch 是否已准备好发送
        // 条件：batch 已满 OR 等待时间超过 linger.ms OR 有其他 batch 堆积
        if (readyCheck(dq.peekFirst(), now)) {
            ready.computeIfAbsent(leaderNode.id(), k -> new ArrayList<>())
                 .add(batch);
        }
    }
    return ready;
}

private boolean readyCheck(ProducerBatch batch, long now) {
    if (batch == null) return false;
    
    // 1. batch 满了 → 发
    if (batch.isFull()) return true;
    
    // 2. 等待时间超过 linger.ms → 发
    if (now - batch.createdMs >= lingerMs) return true;
    
    // 3. 已达最大等待时间 → 发
    if (flushedSince(now)) return true;
    
    // 4. 该分区有多个 batch 排队（说明生产者速度快于发送速度）→ 发
    if (dq.size() >= 2) return true;
    
    return false;
}
```

### 6.3 linger.ms 与 batch.size 的配合

这两个参数共同控制 Producer 的延迟与吞吐量平衡：

| linger.ms | batch.size | 效果 |
|-----------|-----------|------|
| 0（默认） | 16KB | 低延迟，立即发送，可能 batch 不满 |
| 5-10ms | 32KB-64KB | 吞吐优先，batch 更满，吞吐量更高 |
| 100ms+ | 64KB+ | 批量最大化，但增加延迟 |

```properties
# 高吞吐配置
linger.ms=10
batch.size=32768
buffer.memory=134217728  # 128MB
compression.type=snappy
```

---

## 七、重试机制

### 7.1 可重试异常与不可重试异常

```java
// 在 Sender 的 completeBatch 中处理
private void completeBatch(ProducerBatch batch, Errors error, long baseOffset, ...) {
    if (error == Errors.NONE) {
        // 成功 → 通知回调
        batch.done(baseOffset, ...);
    } else if (error == Errors.INVALID_REQUIRED_ACKS) {
        // ❌ 不可重试
        batch.done(null, new KafkaException(...));
    } else {
        // 可重试错误：
        // - LEADER_NOT_AVAILABLE → 分区 leader 不可用
        // - NOT_LEADER_OR_FOLLOWER → leader 切换中
        // - NETWORK_EXCEPTION → 网络临时故障
        // - REQUEST_TIMED_OUT → 请求超时
        if (canRetry(batch, error)) {
            // 重新放入 accumulator，等待下一轮发送
            accumulator.reenqueue(batch, now);
            // Sender 会再次尝试
            this.sender.wakeup();
        } else {
            // 超过重试次数或重试时间 → 抛出异常
            batch.done(null, new TimeoutException(...));
        }
    }
}
```

### 7.2 retries 与 delivery.timeout.ms 的关系

```properties
# ❌ 旧版（Kafka 2.0 之前）—— 只配置 retries
retries=3

# ✅ 新版（Kafka 2.1+）—— 使用 delivery.timeout.ms
delivery.timeout.ms=120000  # 总超时时间，包含等待+发送+重试
retries=2147483647           # 实际上由 delivery.timeout.ms 兜底
```

**核心变化**：Kafka 2.1 引入 `delivery.timeout.ms` 后，`retries` 实际上是无限次——只要没超过 delivery.timeout.ms，就会一直重试。

---

## 八、完整配置调优参考

```properties
# Producer 核心配置
bootstrap.servers=kafka1:9092,kafka2:9092,kafka3:9092
key.serializer=org.apache.kafka.common.serialization.StringSerializer
value.serializer=org.apache.kafka.common.serialization.StringSerializer

# 可靠性配置
acks=all                          # 等待所有副本确认
enable.idempotence=true           # 开启幂等（防止重复消息）
max.in.flight.requests.per.connection=5  # 幂等时可以设 >1

# 性能配置
batch.size=32768                  # 32KB
linger.ms=10                      # 等 10ms 凑 batch
buffer.memory=134217728           # 128MB 缓冲区
compression.type=snappy           # 压缩（减少网络带宽）
delivery.timeout.ms=120000        # 2 分钟总超时

# 请求配置
max.request.size=1048576          # 1MB 最大请求大小
request.timeout.ms=30000          # 30s 请求超时
```

---

## 九、面试高频问题

**Q1：Kafka Producer 是异步还是同步？**

`send()` 方法是异步的——消息进入 accumulator 后立即返回 Future。但如果调用了 `Future.get()` 或 `flush()`，会阻塞等待发送完成，变为同步。

**Q2：消息在 Producer 端什么时候真正发送？**

由 Sender 线程决定，满足任一条件就发送：batch 满了、等待超过 `linger.ms`、有新的 batch 排到队首、用户调用了 `flush()`。

**Q3：如何保证消息不丢？**

三管齐下：`acks=all`（等所有副本确认） + `enable.idempotence=true`（幂等生产者） + 合理的 `delivery.timeout.ms`。

**Q4：粘性分区和轮询分区有什么区别？**

轮询分区每个消息分不同分区，batch 积攒不充分；粘性分区将一批消息持续发往同一分区，batch 更大、吞吐更高、请求更少。

**Q5：Producer 端如何调优？**

核心是调 `batch.size`、`linger.ms`、`buffer.memory` 三件套。大 batch 高吞吐（适合离线、批量写入场景），小 batch 低延迟（适合实时场景），按业务取舍。

---

## 总结

Kafka Producer 的发送链路是一个**精密的异步流水线**：

```
send() → 拦截器 → 序列化 → 分区 → 写入 BufferPool
    ↓
Sender 线程：drain batch → 构建 ProduceRequest → NetworkClient 发送
    ↓
收到响应 → 回调用户 Callback → 完成 Future
```

理解这条链路，你就能在生产环境中精准回答"为什么 Kafka 这么快"以及"我的消息去哪了"这类问题。知道调整哪个参数对应优化哪个环节，是 Kafka 高手的标志。
