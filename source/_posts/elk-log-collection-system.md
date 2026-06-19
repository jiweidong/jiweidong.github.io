---
title: ELK（Elasticsearch + Logstash + Kibana）日志收集体系实战
date: 2026-06-17 09:45:00
tags:
  - ELK
  - Elasticsearch
  - Logstash
  - Kibana
  - Filebeat
  - 日志收集
  - 监控
categories:
  - 运维
author: 东哥
---

# ELK（Elasticsearch + Logstash + Kibana）日志收集体系实战

## 一、引言

在分布式系统中，日志是排查问题、监控系统健康、分析用户行为的核心数据源。然而随着微服务数量激增，传统登录服务器 `tail -f` 查看日志的方式已完全不可行。ELK 栈（Elasticsearch + Logstash + Kibana）凭借其强大的搜索能力、灵活的管道处理和美观的可视化，成为日志收集领域的事实标准。

本文将深入讲解 ELK 架构的演进路线、Logstash 管道的详细配置、Filebeat 的轻量采集方案、结构化日志的最佳实践、索引生命周期管理（ILM），以及 Spring Boot 项目与 ELK 的完整集成方案。

## 二、ELK 架构演进

### 2.1 经典 3 节点架构

```
App → Logstash → Elasticsearch → Kibana
```

最简单的架构，App 直接将日志通过 TCP/UDP 发送给 Logstash，Logstash 处理后写入 ES，Kibana 展示。

**优点**：部署简单，适合小规模场景。
**缺点**：Logstash 作为集中式采集端，资源消耗大，无法横向扩展。

### 2.2 引入 Filebeat 的轻量架构

```
App (日志文件) → Filebeat → Logstash → Elasticsearch → Kibana
```

Filebeat 是 Elastic 官方推出的轻量级日志采集器（Go 语言编写，内存占用极低），安装在每台业务机器上读取日志文件，转发给 Logstash 做集中处理。

| 组件 | 语言 | 内存占用 | 功能定位 |
|------|------|----------|----------|
| Filebeat | Go | 10-50 MB | 轻量采集、读取日志文件 |
| Logstash | Java/JRuby | 256 MB - 1 GB+ | 数据解析、转换、过滤、路由 |
| Elasticsearch | Java | 2 GB - 32 GB+ | 分布式存储、全文搜索 |
| Kibana | JavaScript (Node) | 100-200 MB | 可视化、仪表盘、管理 |

### 2.3 引入 Kafka 的高可用架构

```
App → Filebeat → Kafka → Logstash → Elasticsearch → Kibana
                            ↑
                   可并行多个 Logstash 实例
```

在日志量极大（每秒数万条）的场景下，引入 Kafka 作为消息缓冲层：

- **削峰填谷**：应对突发流量洪峰
- **解耦**：采集端与消费端独立扩展
- **重放**：Logstash 挂掉后可以从 Kafka 的 offset 继续消费
- **多消费**：同一份日志数据可以供多个消费者使用

### 2.4 引入 Elastic Agent 的新一代架构

```
App → Elastic Agent → Fleet Server → Elasticsearch → Kibana
                        ↓
             集成 APM、Metricbeat、Heartbeat
```

Elastic Agent 是 Elastic 8.x 推出的统一代理，整合了 Filebeat、Metricbeat、Heartbeat 等功能，通过 Fleet Server 集中管理。适合较新的 8.x 集群。

## 三、Logstash 管道配置详解

### 3.1 Logstash 管道生命周期

Logstash 管道由三个阶段组成：

```
Input → Filter → Output
```

每个阶段可以配置多个插件，数据按顺序流经所有插件。

### 3.2 完整管道配置示例

```ruby
# /etc/logstash/conf.d/spring-boot.conf

input {
  beats {
    port => 5044
    ssl => false
    client_inactivity_timeout => 60
  }
}

filter {
  # 解析 JSON 格式日志
  json {
    source => "message"
    target => "parsed_json"
    skip_on_invalid_json => true
  }

  # 解析 Spring Boot 日志时间戳
  date {
    match => ["timestamp", "ISO8601", "yyyy-MM-dd HH:mm:ss.SSS"]
    target => "@timestamp"
    timezone => "Asia/Shanghai"
  }

  # 添加业务字段
  mutate {
    add_field => {
      "environment" => "%{[fields][env]}"
      "app_name"    => "%{[fields][app]}"
    }
    remove_field => ["message", "tags", "beat", "input", "host", "ecs"]
  }

  # 如果解析失败，使用 grok 兜底
  if "_jsonparsefailure" in [tags] {
    grok {
      match => {
        "message" => [
          "%{TIMESTAMP_ISO8601:timestamp}\s+%{LOGLEVEL:level}\s+%{NUMBER:pid}\s+---\s+\[%{DATA:thread}\]\s+%{DATA:logger}\s*:\s*%{GREEDYDATA:log_message}",
          "%{TIMESTAMP_ISO8601:timestamp}\s+%{LOGLEVEL:level}\s+\[%{DATA:thread}\]\s+%{DATA:logger}\s*:\s*%{GREEDYDATA:log_message}"
        ]
      }
      remove_tag => ["_grokparsefailure"]
    }
  }

  # 异常堆栈合并
  multiline {
    pattern => "^\s+at\s|^\s+\.\.\.\s+\d+\s+common\s+frames\s+omitted"
    what => "previous"
    negate => false
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "%{[fields][app]}-%{[fields][env]}-%{+YYYY.MM.dd}"
    user => "logstash_writer"
    password => "${ES_PASSWORD}"
    ilm_enabled => true
    ilm_rollover_alias => "%{[fields][app]}-%{[fields][env]}"
    ilm_pattern => "000001"
    ilm_policy => "log-retention-30d"
  }

  # 调试：输出到控制台
  # stdout { codec => rubydebug }
}
```

### 3.3 常用 Filter 插件对比

| 插件 | 用途 | 适用场景 | 性能影响 |
|------|------|----------|----------|
| `grok` | 基于正则的日志解析 | 非结构化日志 | 中（正则引擎） |
| `json` | JSON 字段解析 | 结构化日志 | 低 |
| `mutate` | 字段增删改重命名 | 通用数据清洗 | 低 |
| `date` | 时间戳解析与转换 | 日志时间处理 | 低 |
| `dissect` | 固定分隔符文本解析 | HTTP日志、CSV | 极低 |
| `geoip` | IP 地址地理定位 | 访问日志分析 | 中（数据库查询） |
| `useragent` | User-Agent 解析 | 浏览器日志 | 低 |
| `multiline` | 多行合并 | Java异常栈 | 中（需缓存状态） |
| `kv` | key=value 格式解析 | 自定义日志 | 低 |
| `translate` | KV 字典翻译 | 状态码映射 | 低 |

### 3.4 Grok 模式详解

Grok 是 Logstash 最核心的插件之一，其核心思想是将非结构化文本通过正则表达式匹配为结构化字段。

```ruby
# 自定义 grok 模式
filter {
  grok {
    match => {
      "message" => "%{IP:client_ip} %{DATA:http_method} %{URIPATHPARAM:request_path} %{NUMBER:response_code} %{NUMBER:response_time:float}"
    }
    patterns_dir => ["/etc/logstash/patterns"]
    break_on_match => false
  }
}
```

自定义模式文件 `/etc/logstash/patterns/extra`：

```
HTTP_LOG %{IP:client_ip} %{DATA:http_method} %{URIPATHPARAM:request_path} %{NUMBER:response_code} %{NUMBER:response_time:float}
TIMEOUT_LOG %{DATA:service} timed out after %{NUMBER:timeout_ms}ms
```

## 四、Filebeat 轻量日志采集

### 4.1 Filebeat 安装与基础配置

```yaml
# /etc/filebeat/filebeat.yml
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/app/*.log
      - /var/log/access/*.log
    exclude_files: ['\.gz$', '^\.swp']
    exclude_lines: ['^DEBUG', '^TRACE']
    multiline:
      type: pattern
      pattern: '^\d{4}-\d{2}-\d{2}'
      negate: true
      match: after
      timeout: 5s
    fields:
      app: user-service
      env: production
    fields_under_root: false

output.logstash:
  hosts: ["logstash-01:5044", "logstash-02:5044"]
  loadbalance: true
  ssl.enabled: false
  worker: 2
  bulk_max_size: 2048

# 监控自身
monitoring:
  enabled: true
  elasticsearch:
    hosts: ["http://elasticsearch:9200"]
    username: "filebeat_system"
    password: "${ES_PASSWORD}"
```

### 4.2 Filebeat Module 体系

Filebeat 内置了大量常见应用的日志采集模块：

```bash
# 查看可用模块
filebeat modules list

# 启用 Nginx 和 MySQL 模块
filebeat modules enable nginx mysql

# 生成模块配置
filebeat modules enable system
```

启用后，Filebeat 会自动解析 Nginx、MySQL 等标准应用的日志格式，无需手写 grok 模式。

### 4.3 多行日志处理

Java 应用的异常堆栈跨越多行，需要特殊处理：

```yaml
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/spring-boot/*.log
    multiline:
      # 匹配时间戳开头的行为新日志起点
      type: pattern
      pattern: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
      negate: true
      match: after
      # 超时强制拆分（防止无限等待）
      timeout: 5s
    # 限制单条日志最大长度
    max_bytes: 1048576
```

### 4.4 Filebeat 与 Logstash 资源对比

| 指标 | Filebeat | Logstash |
|------|----------|----------|
| 内存 (典型) | 20-50 MB | 512 MB - 2 GB |
| CPU | 低 | 中 |
| 磁盘占用 | <30 MB | ~300 MB |
| 部署方式 | 每个节点 | 集中式集群 |
| 启动时间 | <1s | 5-30s |
| 支持的输入 | 文件、容器日志 | 50+ 输入插件 |

## 五、结构化日志（JSON 格式）

### 5.1 为什么需要结构化日志

传统的文本日志（如 `2026-06-17 10:00:00 INFO [main] com.example.UserService - user created: 10001`）在 Logstash 中需要用 grok 逐字段解析，不仅效率低，而且容错性差。使用 JSON 格式的日志，Logstash 可以直接解析为结构化数据。

### 5.2 Spring Boot JSON 日志配置

```xml
<!-- pom.xml -->
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>8.0</version>
</dependency>
```

```xml
<!-- src/main/resources/logback-spring.xml -->
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <include resource="org/springframework/boot/logging/logback/defaults.xml"/>

    <!-- 定义应用名称 -->
    <springProperty scope="context" name="appName" source="spring.application.name"/>
    <springProperty scope="context" name="env" source="spring.profiles.active"/>

    <!-- 标准控制台输出（带颜色） -->
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="ch.qos.logback.classic.encoder.PatternLayoutEncoder">
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} %highlight(%-5level) [%thread] %cyan(%logger{36}) - %msg%n</pattern>
        </encoder>
    </appender>

    <!-- JSON 格式文件输出（给 Filebeat 采集） -->
    <appender name="JSON_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>/var/log/app/${appName}.log</file>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>/var/log/app/${appName}.%d{yyyy-MM-dd}.log.gz</fileNamePattern>
            <maxHistory>7</maxHistory>
        </rollingPolicy>
        <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
            <providers>
                <timestamp>
                    <timeZone>Asia/Shanghai</timeZone>
                </timestamp>
                <version/>
                <logLevel/>
                <threadName/>
                <loggerName/>
                <message/>
                <mdc/>
                <arguments/>
                <stackTrace>
                    <throwableConverter class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
                        <maxDepthPerThrowable>30</maxDepthPerThrowable>
                        <maxLength>2048</maxLength>
                        <shortenedClassNameLength>20</shortenedClassNameLength>
                        <exclude>sun\.reflect\..*</exclude>
                        <rootCauseFirst>true</rootCauseFirst>
                    </throwableConverter>
                </stackTrace>
                <context/>
                <!-- 自定义字段 -->
                <pattern>
                    <omitEmptyFields>false</omitEmptyFields>
                    <pattern>
                        {
                            "app": "${appName}",
                            "environment": "${env}",
                            "hostname": "${HOSTNAME:-unknown}"
                        }
                    </pattern>
                </pattern>
            </providers>
        </encoder>
    </appender>

    <!-- Logstash TCP 直推（可选，不经过 Filebeat） -->
    <appender name="LOGSTASH" class="net.logstash.logback.appender.LogstashTcpSocketAppender">
        <destination>logstash:5000</destination>
        <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
            <providers>
                <mdc/>
                <pattern>
                    <pattern>
                        {
                            "app": "${appName:-app}",
                            "env": "${env:-dev}",
                            "timestamp": "%d{yyyy-MM-dd'T'HH:mm:ss.SSSZ}",
                            "level": "%level",
                            "thread": "%thread",
                            "logger": "%logger",
                            "message": "%message",
                            "traceId": "%X{traceId:-}",
                            "userId": "%X{userId:-}"
                        }
                    </pattern>
                </pattern>
            </providers>
        </encoder>
    </appender>

    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
        <appender-ref ref="JSON_FILE"/>
    </root>
</configuration>
```

### 5.3 输出的 JSON 日志示例

```json
{
  "@timestamp": "2026-06-17T10:30:00.123+08:00",
  "@version": "1",
  "level": "INFO",
  "thread": "http-nio-8080-exec-4",
  "logger": "com.example.service.UserService",
  "message": "用户创建成功",
  "mdc": {
    "traceId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "userId": "10001",
    "requestId": "req-20260617-001"
  },
  "arguments": {
    "userId": 10001,
    "username": "张三"
  },
  "app": "user-service",
  "environment": "production",
  "hostname": "app-node-01"
}
```

## 六、日志索引生命周期管理（ILM）

### 6.1 为什么需要 ILM

Elasticsearch 中索引会不断增长，如果不加控制，会出现磁盘写满、查询性能下降等问题。ILM 允许你定义索引在不同阶段（Hot → Warm → Cold → Delete）的自动流转策略。

### 6.2 创建 ILM 策略

```json
PUT _ilm/policy/log-retention-30d
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_size": "50GB",
            "max_age": "1d",
            "max_docs": 50000000
          },
          "set_priority": {
            "priority": 100
          }
        }
      },
      "warm": {
        "min_age": "3d",
        "actions": {
          "allocate": {
            "number_of_replicas": 1
          },
          "forcemerge": {
            "max_num_segments": 1
          },
          "shrink": {
            "number_of_shards": 1
          },
          "set_priority": {
            "priority": 50
          }
        }
      },
      "cold": {
        "min_age": "7d",
        "actions": {
          "allocate": {
            "require": {
              "data_tier": "data_cold"
            }
          },
          "set_priority": {
            "priority": 0
          }
        }
      },
      "delete": {
        "min_age": "30d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

### 6.3 ILM 各阶段说明

| 阶段 | 时间点 | 典型操作 | 硬件类型 |
|------|--------|----------|----------|
| Hot | 当前活跃 | 读写、rollover | SSD / NVMe |
| Warm | 3天后 | 只读、合并、压缩 | SSD / HDD |
| Cold | 7天后 | 只读、降低副本 | HDD |
| Delete | 30天后 | 删除索引 | 无 |

### 6.4 创建索引模板

```json
PUT _index_template/logs-template
{
  "index_patterns": ["*-production-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "log-retention-30d",
      "index.lifecycle.rollover_alias": "logs-production",
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "refresh_interval": "10s",
      "translog.durability": "async",
      "translog.sync_interval": "5s"
    },
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_keyword": {
            "match_mapping_type": "string",
            "mapping": {
              "type": "text",
              "fields": {
                "keyword": {
                  "type": "keyword",
                  "ignore_above": 256
                }
              }
            }
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" },
        "level": { "type": "keyword" },
        "logger": { "type": "keyword" },
        "message": {
          "type": "text",
          "analyzer": "ik_max_word"
        },
        "traceId": { "type": "keyword" },
        "userId": { "type": "long" },
        "response_time": { "type": "float" },
        "status_code": { "type": "integer" }
      }
    },
    "aliases": {
      "logs-production": {}
    }
  }
}
```

### 6.5 索引管理常用操作

```bash
# 查看所有索引
GET _cat/indices?v

# 手动触发 rollover
POST /logs-production/_rollover

# 查看 ILM 执行状态
GET _ilm/status

# 查看具体策略执行详情
GET /logs-production-*/_ilm/explain

# 强制合并（减小存储）
POST /logs-production-2026.06.15-000001/_forcemerge?max_num_segments=1

# 查看索引存储大小
GET _cat/indices?v&s=pri.store.size:desc
```

## 七、Kibana 可视化大盘

### 7.1 创建 Data View

```
Management → Stack Management → Data Views
```

创建 data view 匹配 `*-production-*` 模式，时间字段选择 `@timestamp`。

### 7.2 常用可视化类型

| 可视化类型 | 适用场景 | 示例 |
|-----------|----------|------|
| Lens | 通用拖拽式可视化 | 日志量趋势图 |
| TSVB | 时序数据 | 接口响应时间 P99 |
| Vega | 高级自定义 | 桑基图、热力图 |
| Maps | 地理分布 | 请求来源分布 |
| Dashboard | 组合多个可视化 | 系统监控总览 |
| Discover | 日志搜索浏览 | 关键字搜索 |

### 7.3 典型监控大盘指标

```json
// 请求量趋势
{
  "title": "每分钟请求数",
  "metrics": {"count": "count"},
  "time_field": "@timestamp",
  "interval": "1m",
  "breakdown": {"field": "level.keyword"}
}

// 错误率
{
  "title": "错误率（5xx）",
  "ratio_field": "status_code",
  "ratio_value": "^5[0-9]{2}$"
}

// P99 响应时间
{
  "title": "接口响应 P99",
  "field": "response_time",
  "percentile": 99
}

// 错误日志 TOP Logger
{
  "title": "产生最多 ERROR 的类",
  "bucket_field": "logger.keyword",
  "metric": "count",
  "size": 10,
  "filter": {"level.keyword": "ERROR"}
}
```

### 7.4 告警配置（Elastic 8.x）

```yaml
# Kibana 告警规则配置
rule:
  rule_type_id: elasticsearch-query-alert
  params:
    index: ["*-production-*"]
    timeField: "@timestamp"
    timeWindowSize: 5
    timeWindowUnit: "m"
    threshold:
      - 10
    condition: "count >= threshold"
    size: 10
    searchQuery: |
      {
        "query": {
          "bool": {
            "filter": [
              {"range": {"@timestamp": {"gte": "now-5m"}}},
              {"term": {"level.keyword": "ERROR"}}
            ]
          }
        }
      }
  actions:
    - group: default
      id: slack-notification
      params:
        message: "在过去 5 分钟内，生产环境产生了 {{ctx.results.count}} 条 ERROR 日志"
```

## 八、Elasticsearch 集群运维

### 8.1 节点角色规划

| 节点角色 | 职责 | 推荐配置 |
|----------|------|----------|
| Master | 集群元数据、索引管理 | 4C8G x 3 |
| Data Hot | 热数据读写（SSD） | 16C32G x 3+ |
| Data Warm | 温数据存储（HDD） | 8C16G x 3+ |
| Data Cold | 冷数据归档（HDD） | 4C8G x 3 |
| Coordinating | 请求路由、聚合 | 8C16G x 2 |
| Ingest | 管道预处理 | 4C8G x 2 |

### 8.2 性能调优

```yaml
# elasticsearch.yml
# 段合并
index.merge.scheduler.max_thread_count: 1
index.merge.policy.segments_per_tier: 10
index.merge.policy.max_merged_segment: 5gb

# 刷新间隔（可接受延迟则调大）
index.refresh_interval: 30s

# Translog（可接受少量丢数据则异步）
index.translog.durability: async
index.translog.sync_interval: 30s

# 分片恢复
indices.recovery.max_bytes_per_sec: 100mb

# 字段数量限制
index.mapping.total_fields.limit: 2000

# 查询超时
search.default_search_timeout: 30s
```

## 九、ELK 最佳实践清单

- ✅ 日志必须结构化（JSON 格式），避免使用 grok 做大量解析
- ✅ 生产环境每台机器部署 Filebeat，不要用 Logstash 直接采集文件
- ✅ 必须配置 ILM 策略管理索引生命周期
- ✅ 日志中必须包含 traceId 用于跨服务调用链路追踪
- ✅ 敏感信息（密码、身份证）必须脱敏
- ✅ 设置 Logstash 和 ES 的 JVM heap 不超过 50%（留一半给 OS page cache）
- ✅ 使用 index template 统一管理 mapping 和 settings
- ✅ 避免字段过多导致 mapping 爆炸，控制日志字段在 50 个以内
- ✅ 日志等级分级：ERROR（报警）、WARN（关注）、INFO（常规）、DEBUG（开发）
- ✅ 定期监控 ES 集群健康状态：`GET _cluster/health`

## 十、结语

ELK 栈经过多年的发展，已经从简单的日志收集工具演变为完整的可观测性平台。本文从架构设计、组件配置、结构化日志、索引管理到可视化大盘，覆盖了 ELK 体系在生产环境中落地的主要环节。

记住一个原则：**日志不是写给人看的，而是写给机器查的**。做好结构化和索引规划，ELK 才能发挥最大的数据洞察能力。
