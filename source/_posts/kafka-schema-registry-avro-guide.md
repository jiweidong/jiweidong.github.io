---
title: Kafka Schema Registry与Avro序列化实战
date: 2026-06-20 08:00:00
tags:
  - Kafka
  - Schema Registry
  - Avro
  - 消息中间件
  - 序列化
categories:
  - 消息中间件
author: 东哥
---

# Kafka Schema Registry与Avro序列化实战

在生产环境中使用Apache Kafka，消息数据的一致性、兼容性和可演化性是关键挑战。Confluent Schema Registry配合Apache Avro序列化，为Kafka消息提供了结构化的Schema管理能力。本文将深入讲解Schema Registry的架构、Avro序列化原理、兼容性策略和生产部署。

## 一、为什么需要Schema Registry？

### 1.1 不使用Schema的问题

```java
// 无Schema的消息发送
ProducerRecord<String, String> record = new ProducerRecord<>(
    "user-events", 
    "{\"userId\":123,\"name\":\"Alice\",\"email\":\"alice@example.com\"}"
);
producer.send(record);

// 消费者需要知道消息格式
// 问题1: 生产者改了字段名 → 消费者解析失败
// 问题2: 没有校验 → 错误数据写入Kafka
// 问题3: 耦合 → 生产者和消费者需要共享POJO类
// 问题4: 演化困难 → 无法知道字段是否可丢弃
```

### 1.2 Schema Registry解决的问题

| 问题 | 解决方案 | 效果 |
|-----|---------|------|
| 数据格式耦合 | Schema注册中心统一管理 | 生产者/消费者通过Schema Name解耦 |
| 数据兼容性 | 兼容性策略校验 | 前向/后向/完全兼容 |
| 数据大小 | Avro二进制编码 | JSON的1/5 ~ 1/10 |
| Schema演化 | Schema版本管理 | 支持字段增删改 |
| 数据验证 | Schema校验 | 写入即校验 |

## 二、架构设计

### 2.1 整体架构

```text
┌─────────────────────────────────────────────────────────┐
│                     Schema Registry                       │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐ │
│  │  REST API    │   │  Schema Store │   │  Compability │ │
│  │  (HTTP/8081) │   │  (Kafka内)    │   │  Engine      │ │
│  └──────┬───────┘   └──────┬───────┘   └──────┬───────┘ │
└─────────┼──────────────────┼───────────────────┼──────────┘
          │                  │                   │
    ┌─────┴──────┐          │                   │
    │   Producer  │          │                   │
    │   (Avro)    │          │                   │
    └─────┬──────┘          │                   │
          │ (1) 注册/获取Schema                   │
          ▼                  ▼                   ▼
    ┌─────────────────────────────────────────────────────┐
    │                   Kafka Cluster                       │
    │  Topic: user-events [P1] [P2] [P3]                    │
    │  Message: [Magic Byte][Schema ID][Avro Data]          │
    └───────────────────────────────────────────────────────┘
          ▲
    ┌─────┴──────┐
    │  Consumer   │
    │  (Avro)     │
    └────────────┘ (2) 获取Schema反序列化
```

### 2.2 消息格式

```
| 1 Byte Magic | 4 Bytes Schema ID | Avro Binary Data |
|    0x00      |    0x00000001     |  ...compact...   |
```

每条Kafka消息的开头都包含：
1. **Magic Byte（1字节）**：固定为0x00，标识Schema Registry格式
2. **Schema ID（4字节）**：全局唯一的Schema版本ID
3. **Avro负载**：Avro二进制编码的消息数据

这样设计的好处是：消息本身非常紧凑，Schema ID仅4字节，大幅减少网络传输和存储成本。

## 三、Avro Schema定义

### 3.1 Avro基础类型

```json
{
  "type": "record",
  "name": "UserEvent",
  "namespace": "com.example.events",
  "doc": "用户事件消息Schema",
  "fields": [
    {"name": "userId", "type": "long", "doc": "用户ID"},
    {"name": "name", "type": "string", "doc": "用户名"},
    {"name": "email", "type": ["null", "string"], "default": null, "doc": "邮箱"},
    {"name": "age", "type": "int", "default": 0, "doc": "年龄"},
    {"name": "tags", "type": {"type": "array", "items": "string"}, "default": [], "doc": "标签列表"},
    {"name": "address", "type": {
      "type": "record",
      "name": "Address",
      "fields": [
        {"name": "city", "type": "string"},
        {"name": "province", "type": "string"},
        {"name": "country", "type": "string", "default": "中国"}
      ]
    }, "doc": "地址"},
    {"name": "createdAt", "type": {"type": "long", "logicalType": "timestamp-millis"}, "doc": "创建时间"},
    {"name": "eventType", "type": {
      "type": "enum",
      "name": "EventType",
      "symbols": ["CREATED", "UPDATED", "DELETED", "LOGIN", "LOGOUT"]
    }, "doc": "事件类型"},
    {"name": "metadata", "type": {"type": "map", "values": "string"}, "default": {}, "doc": "扩展元数据"}
  ]
}
```

### 3.2 Avro逻辑类型

```json
{
  "name": "OrderEvent",
  "type": "record",
  "fields": [
    {"name": "orderId", "type": "string"},
    {"name": "amount", "type": {"type": "bytes", "logicalType": "decimal", "precision": 12, "scale": 2}},
    {"name": "createdAt", "type": {"type": "long", "logicalType": "timestamp-millis"}},
    {"name": "updatedAt", "type": {"type": "long", "logicalType": "timestamp-micros"}},
    {"name": "items", "type": {"type": "array", "items": {
      "type": "record",
      "name": "OrderItem",
      "fields": [
        {"name": "productId", "type": "string"},
        {"name": "quantity", "type": "int"},
        {"name": "price", "type": {"type": "bytes", "logicalType": "decimal", "precision": 10, "scale": 2}},
        {"name": "sku", "type": ["null", "string"], "default": null}
      ]
    }}}
  ]
}
```

| Avro类型 | 逻辑类型 | Java映射 | 说明 |
|---------|---------|---------|------|
| int | date | LocalDate | 日期(天) |
| int | time-millis | LocalTime | 时间(毫秒) |
| long | time-micros | LocalTime | 时间(微秒) |
| long | timestamp-millis | Instant | 时间戳(毫秒) |
| long | timestamp-micros | Instant | 时间戳(微秒) |
| bytes | decimal | BigDecimal | 高精度小数 |
| fixed | duration | Duration | 持续时间 |

## 四、Java集成实战

### 4.1 Maven依赖

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.confluent</groupId>
            <artifactId>kafka-avro-serializer</artifactId>
            <version>7.5.0</version>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <!-- Kafka Clients -->
    <dependency>
        <groupId>org.apache.kafka</groupId>
        <artifactId>kafka-clients</artifactId>
        <version>3.5.0</version>
    </dependency>
    
    <!-- Avro Serializer -->
    <dependency>
        <groupId>io.confluent</groupId>
        <artifactId>kafka-avro-serializer</artifactId>
    </dependency>
    
    <!-- Avro Compiler -->
    <dependency>
        <groupId>org.apache.avro</groupId>
        <artifactId>avro</artifactId>
        <version>1.11.3</version>
    </dependency>
    
    <!-- Maven Avro Plugin -->
    <dependency>
        <groupId>org.apache.avro</groupId>
        <artifactId>avro-maven-plugin</artifactId>
        <version>1.11.3</version>
    </dependency>
</dependencies>

<repositories>
    <repository>
        <id>confluent</id>
        <url>https://packages.confluent.io/maven/</url>
    </repository>
</repositories>

<build>
    <plugins>
        <plugin>
            <groupId>org.apache.avro</groupId>
            <artifactId>avro-maven-plugin</artifactId>
            <version>1.11.3</version>
            <executions>
                <execution>
                    <phase>generate-sources</phase>
                    <goals>
                        <goal>schema</goal>
                    </goals>
                    <configuration>
                        <sourceDirectory>${project.basedir}/src/main/avro/</sourceDirectory>
                        <outputDirectory>${project.basedir}/src/main/java/</outputDirectory>
                    </configuration>
                </execution>
            </executions>
        </plugin>
    </plugins>
</build>
```

### 4.2 Schema注册

```java
// 方式1：使用Avro Schema文件（推荐）
// 在 src/main/avro/UserEvent.avsc 放Schema定义
// Maven编译时自动生成Java类

// 方式2：编程方式注册
public class SchemaRegistrationExample {
    
    private static final String SCHEMA_REGISTRY_URL = "http://schema-registry:8081";
    
    public void registerSchema() throws Exception {
        // 1. 读取Schema定义
        Schema.Parser parser = new Schema.Parser();
        Schema schema = parser.parse(new File("src/main/avro/UserEvent.avsc"));
        
        // 2. 创建Schema Registry客户端
        try (SchemaRegistryClient registryClient = 
                new CachedSchemaRegistryClient(SCHEMA_REGISTRY_URL, 1000)) {
            
            // 3. 注册Schema - subject为 topic-name-value 或 topic-name-key
            int schemaId = registryClient.register("user-events-value", schema);
            System.out.println("Schema registered with ID: " + schemaId);
            
            // 4. 获取Schema版本
            int version = registryClient.getVersion("user-events-value", schema);
            System.out.println("Schema version: " + version);
            
            // 5. 检查兼容性
            boolean compatible = registryClient.testCompatibility("user-events-value", schema);
            System.out.println("Compatible with existing: " + compatible);
        }
    }
}
```

### 4.3 生产者实现

```java
public class AvroProducer {
    
    private static final String BOOTSTRAP_SERVERS = "kafka-1:9092,kafka-2:9092,kafka-3:9092";
    private static final String SCHEMA_REGISTRY_URL = "http://schema-registry:8081";
    private static final String TOPIC = "user-events";
    
    public static void main(String[] args) {
        // 1. 生产者配置
        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.RETRIES_CONFIG, 3);
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
        props.put(ProducerConfig.COMPRESSION_TYPE_CONFIG, "snappy");
        props.put(ProducerConfig.LINGER_MS_CONFIG, 10);
        props.put(ProducerConfig.BATCH_SIZE_CONFIG, 32768);
        
        // 2. Avro序列化器配置
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, 
            KafkaAvroSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, 
            KafkaAvroSerializer.class.getName());
        props.put(AbstractKafkaSchemaSerDeConfig.SCHEMA_REGISTRY_URL_CONFIG, 
            SCHEMA_REGISTRY_URL);
        
        // 3. 注册自动Schema注册行为
        // AUTO_REGISTER_SCHEMAS: true=自动注册(默认), false=手动注册
        props.put(AbstractKafkaSchemaSerDeConfig.AUTO_REGISTER_SCHEMAS, false);
        // 如果为false，需要设置USE_LATEST_VERSION配置
        // props.put(AbstractKafkaSchemaSerDeConfig.USE_LATEST_VERSION, true);
        
        // 4. 创建生产者
        try (KafkaProducer<UserEventKey, UserEvent> producer = 
                new KafkaProducer<>(props)) {
            
            // 5. 发送消息
            for (int i = 0; i < 1000; i++) {
                UserEventKey key = UserEventKey.newBuilder()
                    .setUserId((long) i)
                    .build();
                
                UserEvent event = UserEvent.newBuilder()
                    .setUserId((long) i)
                    .setName("User-" + i)
                    .setEmail("user" + i + "@example.com")
                    .setAge(20 + (i % 40))
                    .setTags(List.of("vip", "active"))
                    .setAddress(Address.newBuilder()
                        .setCity("Beijing")
                        .setProvince("Beijing")
                        .setCountry("China")
                        .build())
                    .setCreatedAt(System.currentTimeMillis())
                    .setEventType(EventType.CREATED)
                    .setMetadata(Map.of("source", "web", "version", "1.0"))
                    .build();
                
                ProducerRecord<UserEventKey, UserEvent> record = 
                    new ProducerRecord<>(TOPIC, key, event);
                
                // 同步发送
                RecordMetadata metadata = producer.send(record).get();
                log.info("Sent message to partition {} offset {}", 
                    metadata.partition(), metadata.offset());
            }
        } catch (Exception e) {
            log.error("Failed to send message", e);
        }
    }
}
```

### 4.4 消费者实现

```java
public class AvroConsumer {
    
    private static final String BOOTSTRAP_SERVERS = "kafka-1:9092,kafka-2:9092,kafka-3:9092";
    private static final String SCHEMA_REGISTRY_URL = "http://schema-registry:8081";
    private static final String TOPIC = "user-events";
    private static final String GROUP_ID = "user-event-consumer";
    
    public static void main(String[] args) {
        // 1. 消费者配置
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, BOOTSTRAP_SERVERS);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP_ID);
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 500);
        
        // 2. Avro反序列化器
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, 
            KafkaAvroDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, 
            KafkaAvroDeserializer.class.getName());
        props.put(AbstractKafkaSchemaSerDeConfig.SCHEMA_REGISTRY_URL_CONFIG, 
            SCHEMA_REGISTRY_URL);
        
        // 3. 反序列化为特定类型
        props.put(KafkaAvroDeserializerConfig.SPECIFIC_AVRO_READER_CONFIG, true);
        
        // 4. 创建消费者
        try (KafkaConsumer<UserEventKey, UserEvent> consumer = 
                new KafkaConsumer<>(props)) {
            
            consumer.subscribe(List.of(TOPIC));
            
            while (true) {
                ConsumerRecords<UserEventKey, UserEvent> records = 
                    consumer.poll(Duration.ofMillis(1000));
                
                for (ConsumerRecord<UserEventKey, UserEvent> record : records) {
                    UserEventKey key = record.key();
                    UserEvent value = record.value();
                    
                    log.info("Received event: partition={}, offset={}, key={}, event={}",
                        record.partition(), record.offset(),
                        key.getUserId(), value.getName());
                    
                    // 处理业务逻辑
                    processUserEvent(value);
                }
                
                // 手动提交offset
                consumer.commitSync();
            }
        }
    }
    
    private static void processUserEvent(UserEvent event) {
        // 反序列化后直接使用强类型对象
        long userId = event.getUserId();
        String name = event.getName().toString();
        EventType type = event.getEventType();
        
        // 记录业务处理
        log.info("Processing event: userId={}, action={}", userId, type);
    }
}
```

## 五、兼容性策略

### 5.1 兼容性类型

```json
{
  "compatibility": "BACKWARD",
  "subjects": {
    "user-events-value": {
      "version": 1,
      "schema": "{...}"
    }
  }
}
```

| 兼容性类型 | 说明 | Schema演化方向 | 适用场景 |
|-----------|------|--------------|---------|
| NONE | 不检查兼容性 | 任意修改 | 开发环境 |
| BACKWARD | 后向兼容(默认) | 新Schema可读旧数据 | 消费端先升级 |
| FORWARD | 前向兼容 | 旧Schema可读新数据 | 生产端先升级 |
| FULL | 完全兼容 | 前后向都兼容 | 生产环境推荐 |
| BACKWARD_TRANSITIVE | 传递后向兼容 | 对所有历史版本兼容 | 严格后向兼容 |
| FORWARD_TRANSITIVE | 传递前向兼容 | 对所有历史版本兼容 | 严格前向兼容 |
| FULL_TRANSITIVE | 传递完全兼容 | 对所有历史版本都兼容 | 最严格 |

### 5.2 Schema演化规则

```java
// 规则1：添加可选字段（BACKWARD安全）
// 旧Schema → 新Schema（添加nickname）
// 兼容: YES（有default值）
{
  "name": "UserEvent",
  "fields": [
    {"name": "userId", "type": "long"},
    {"name": "name", "type": "string"},
    {"name": "nickname", "type": ["null", "string"], "default": null}  // 新增
  ]
}

// 规则2：删除字段（FORWARD安全）
// 旧Schema → 新Schema（删除age）
// 兼容: YES（消费端需要forward兼容）
{
  "name": "UserEvent",
  "fields": [
    {"name": "userId", "type": "long"},
    {"name": "name", "type": "string"}
    // 删除了age字段
  ]
}

// 规则3：修改字段类型（不可直接修改）
// union类型转换：int → ["null", "int"] (需要default)
// type转换：string → bytes (安全)
// 但不允许：string → int

// 规则4：重命名字段（通过别名）
{
  "name": "UserEvent",
  "fields": [
    {"name": "userId", "type": "long"},
    {"name": "fullName", "type": "string", "aliases": ["name"]}  // 从name改来
  ]
}
```

### 5.3 设置兼容性

```bash
# 通过REST API设置兼容性
# 全局设置
curl -X PUT http://schema-registry:8081/config \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"compatibility": "FULL"}'

# 按Subject设置
curl -X PUT http://schema-registry:8081/config/user-events-value \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"compatibility": "BACKWARD"}'

# 查询兼容性
curl http://schema-registry:8081/config/user-events-value

# 测试兼容性
curl -X POST http://schema-registry:8081/compatibility/subjects/user-events-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schema": "{\"type\":\"record\",\"name\":\"UserEvent\",\"fields\":[...]}"}'
```

## 六、集群部署

### 6.1 Docker Compose部署

```yaml
version: '3.8'
services:
  # ZooKeeper
  zookeeper:
    image: confluentinc/cp-zookeeper:7.5.0
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    networks:
      - kafka-net

  # Kafka Brokers
  kafka-1:
    image: confluentinc/cp-kafka:7.5.0
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-1:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
    networks:
      - kafka-net

  kafka-2:
    image: confluentinc/cp-kafka:7.5.0
    depends_on:
      - zookeeper
    environment:
      KAFKA_BROKER_ID: 2
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-2:9092
    networks:
      - kafka-net

  kafka-3:
    image: confluentinc/cp-kafka:7.5.0
    depends_on:
      - zookeeper
    environment:
      KAFKA_BROKER_ID: 3
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka-3:9092
    networks:
      - kafka-net

  # Schema Registry集群
  schema-registry-1:
    image: confluentinc/cp-schema-registry:7.5.0
    depends_on:
      - kafka-1
    ports:
      - "8081:8081"
    environment:
      SCHEMA_REGISTRY_HOST_NAME: schema-registry-1
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: PLAINTEXT://kafka-1:9092
      SCHEMA_REGISTRY_LISTENERS: http://0.0.0.0:8081
      SCHEMA_REGISTRY_KAFKASTORE_TOPIC: _schemas
      SCHEMA_REGISTRY_KAFKASTORE_TOPIC_REPLICATION_FACTOR: 3
      SCHEMA_REGISTRY_MASTER_ELIGIBILITY: "true"
      SCHEMA_REGISTRY_ACCESS_CONTROL_ALLOW_METHODS: GET,POST,PUT,DELETE
      SCHEMA_REGISTRY_ACCESS_CONTROL_ALLOW_ORIGIN: "*"
    networks:
      - kafka-net

  schema-registry-2:
    image: confluentinc/cp-schema-registry:7.5.0
    depends_on:
      - kafka-1
    ports:
      - "8082:8081"
    environment:
      SCHEMA_REGISTRY_HOST_NAME: schema-registry-2
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: PLAINTEXT://kafka-1:9092
      SCHEMA_REGISTRY_LISTENERS: http://0.0.0.0:8081
      SCHEMA_REGISTRY_KAFKASTORE_TOPIC: _schemas
      SCHEMA_REGISTRY_KAFKASTORE_TOPIC_REPLICATION_FACTOR: 3
      SCHEMA_REGISTRY_MASTER_ELIGIBILITY: "true"
    networks:
      - kafka-net

  # Schema Registry UI
  schema-registry-ui:
    image: landoop/schema-registry-ui:latest
    ports:
      - "8000:8000"
    environment:
      SCHEMAREGISTRY_URL: http://schema-registry-1:8081
    depends_on:
      - schema-registry-1
    networks:
      - kafka-net

networks:
  kafka-net:
    driver: bridge
```

## 七、高级特性

### 7.1 Avro与其他序列化对比

| 序列化方式 | 编码大小 | 序列化速度 | 反序列化速度 | Schema支持 | 语言支持 |
|-----------|---------|-----------|------------|-----------|---------|
| Avro | 小 | 快 | 快 | 强 | 多语言 |
| Protobuf | 小 | 快 | 快 | 强 | 多语言 |
| JSON | 大 | 慢 | 慢 | 无 | 所有语言 |
| Thrift | 中 | 快 | 快 | 强 | 多语言 |
| Java Serializable | 大 | 慢 | 慢 | 弱 | 仅Java |

性能对比（10万条消息测试）：

| 序列化方式 | 总大小 | 生产者TPS | 消费者TPS |
|-----------|--------|----------|----------|
| Avro | 2.3MB | 85,000 | 92,000 |
| Protobuf | 2.1MB | 91,000 | 98,000 |
| JSON | 8.7MB | 42,000 | 38,000 |
| Java Serialization | 12.4MB | 25,000 | 18,000 |

### 7.2 Spring Kafka + Avro集成

```java
@Configuration
public class KafkaAvroConfig {
    
    @Value("${kafka.bootstrap-servers}")
    private String bootstrapServers;
    
    @Value("${kafka.schema-registry-url}")
    private String schemaRegistryUrl;
    
    @Bean
    public ProducerFactory<UserEventKey, UserEvent> avroProducerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, 
            KafkaAvroSerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, 
            KafkaAvroSerializer.class);
        props.put(AbstractKafkaSchemaSerDeConfig.SCHEMA_REGISTRY_URL_CONFIG, 
            schemaRegistryUrl);
        props.put(AbstractKafkaSchemaSerDeConfig.AUTO_REGISTER_SCHEMAS, false);
        
        return new DefaultKafkaProducerFactory<>(props);
    }
    
    @Bean
    public KafkaTemplate<UserEventKey, UserEvent> avroKafkaTemplate() {
        return new KafkaTemplate<>(avroProducerFactory());
    }
    
    @Bean
    public ConsumerFactory<UserEventKey, UserEvent> avroConsumerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, "avro-consumer-group");
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, 
            KafkaAvroDeserializer.class);
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, 
            KafkaAvroDeserializer.class);
        props.put(KafkaAvroDeserializerConfig.SPECIFIC_AVRO_READER_CONFIG, true);
        props.put(AbstractKafkaSchemaSerDeConfig.SCHEMA_REGISTRY_URL_CONFIG, 
            schemaRegistryUrl);
        props.put(AbstractKafkaSchemaSerDeConfig.AUTO_REGISTER_SCHEMAS, false);
        
        return new DefaultKafkaConsumerFactory<>(props);
    }
    
    @Bean
    public ConcurrentKafkaListenerContainerFactory<UserEventKey, UserEvent> 
            avroKafkaListenerContainerFactory() {
        ConcurrentKafkaListenerContainerFactory<UserEventKey, UserEvent> factory =
            new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(avroConsumerFactory());
        factory.setConcurrency(3);
        factory.getContainerProperties().setAckMode(ContainerProperties.AckMode.MANUAL);
        return factory;
    }
}

// 使用
@Service
public class UserEventService {
    
    @Autowired
    private KafkaTemplate<UserEventKey, UserEvent> kafkaTemplate;
    
    public void sendEvent(UserEvent event) {
        UserEventKey key = UserEventKey.newBuilder()
            .setUserId(event.getUserId())
            .build();
        
        kafkaTemplate.send("user-events", key, event);
    }
    
    @KafkaListener(topics = "user-events", 
                   containerFactory = "avroKafkaListenerContainerFactory")
    public void consumeEvent(UserEvent event, Acknowledgment ack) {
        log.info("Received: {}", event);
        ack.acknowledge();
    }
}
```

## 八、总结

Kafka Schema Registry + Avro是生产级Kafka消息系统的黄金组合：

**核心优势：**
1. **数据一致性**：所有消息都经过Schema校验
2. **Schema演化**：支持安全的前向/后向兼容
3. **节省空间**：Avro二进制编码，消息体积减少80%
4. **耦合低**：生产者和消费者通过Schema名称解耦
5. **强类型**：编译期类型检查，运行时高吞吐

**最佳实践：**
- 生产环境设置FULL兼容性策略
- 关闭自动Schema注册（auto.register.schemas=false）
- Schema变更走Git PR审核流程
- 每个Topic使用独立的Subject
- 关键Topic设置较高的replication factor

**适用场景：**
- 需要跨团队/跨服务数据共享
- 消息结构频繁演化的场景
- 大规模高吞吐的Kafka集群
- 数据湖/数据仓库的实时数据管道
