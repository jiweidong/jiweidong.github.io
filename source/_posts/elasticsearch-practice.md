---
title: Elasticsearch 搜索引擎核心技术与实战
date: 2026-06-15 09:00:00
tags:
  - Elasticsearch
  - 搜索引擎
  - 全文检索
  - ELK
categories:
  - 中间件
author: 东哥
---

# Elasticsearch 搜索引擎核心技术与实战

> Elasticsearch 是当前最流行的分布式搜索引擎，广泛应用于日志分析、全文检索、数据分析等场景。本文从底层原理到实战演练，带你全面掌握 ES。

## 一、Elasticsearch 核心概念

### 1.1 什么是 Elasticsearch

Elasticsearch 是一个基于 Lucene 的分布式搜索和分析引擎，具有以下特点：

- **分布式**：自动分片，水平扩展
- **高可用**：副本机制，故障自动转移
- **近实时**：写入后 1s 即可搜索
- **RESTful**：基于 HTTP 的 JSON API
- **全文搜索**：强大的分词和相关性评分

### 1.2 核心术语

| 关系型数据库 | Elasticsearch |
|-------------|---------------|
| Database | Index（索引） |
| Table | Type（类型，7.x 已废弃） |
| Row | Document（文档） |
| Column | Field（字段） |
| Index | 倒排索引 |
| SQL | Query DSL |

### 1.3 集群架构

```
┌──────────────────────────────────────────┐
│          Elasticsearch Cluster            │
│   ┌──────┐  ┌──────┐  ┌──────┐          │
│   │Node-1│  │Node-2│  │Node-3│          │
│   │  P1  │  │  P2  │  │  P3  │          │
│   │  R2  │  │  R3  │  │  R1  │          │
│   └──────┘  └──────┘  └──────┘          │
│                                          │
│   P = Primary Shard   R = Replica Shard  │
└──────────────────────────────────────────┘
```

- **Node**：集群中的一个节点
- **Cluster**：多个节点组成的集群
- **Shard**：分片，索引数据的物理承载单元
- **Replica**：副本分片，提供高可用和读能力

## 二、安装与快速上手

### 2.1 Docker 安装

```bash
# 单节点
docker run -d --name es \
  -p 9200:9200 -p 9300:9300 \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  docker.elastic.co/elasticsearch/elasticsearch:8.12.0

# 验证
curl http://localhost:9200
```

### 2.2 Kibana 安装

```bash
docker run -d --name kibana \
  -p 5601:5601 \
  -e "ELASTICSEARCH_HOSTS=http://localhost:9200" \
  docker.elastic.co/kibana/kibana:8.12.0
```

### 2.3 基本操作

```bash
# 创建索引
PUT /products
{
  "settings": {
    "number_of_shards": 3,
    "number_of_replicas": 1
  },
  "mappings": {
    "properties": {
      "title": { "type": "text", "analyzer": "ik_max_word" },
      "price": { "type": "double" },
      "description": { "type": "text", "analyzer": "ik_smart" },
      "category": { "type": "keyword" },
      "tags": { "type": "keyword" },
      "created_at": { "type": "date" }
    }
  }
}

# 插入文档
POST /products/_doc/1
{
  "title": "华为 Mate 60 Pro",
  "price": 6999.00,
  "description": "华为最新旗舰手机，搭载麒麟芯片，支持卫星通信",
  "category": "手机",
  "tags": ["华为", "5G", "旗舰"],
  "created_at": "2026-06-15"
}

# 搜索
GET /products/_search
{
  "query": {
    "match": {
      "title": "华为手机"
    }
  }
}
```

## 三、映射 Mapping 详解

### 3.1 字段类型

```json
{
  "mappings": {
    "properties": {
      "name": { "type": "text", "analyzer": "standard" },
      "age": { "type": "integer" },
      "price": { "type": "float" },
      "is_active": { "type": "boolean" },
      "birthday": { "type": "date", "format": "yyyy-MM-dd" },
      "address": { 
        "type": "text",
        "fields": {
          "keyword": { "type": "keyword" }
        }
      },
      "location": { "type": "geo_point" },
      "roles": { "type": "keyword" },
      "content": { 
        "type": "text",
        "analyzer": "ik_max_word",
        "search_analyzer": "ik_smart"
      }
    }
  }
}
```

### 3.2 动态映射

ES 可以自动推断字段类型，但生产环境建议显式定义 Mapping 以避免类型推断错误。

```json
{
  "mappings": {
    "dynamic": "strict", // 禁止动态新增字段
    "properties": { ... }
  }
}
```

## 四、查询 DSL 实战

### 4.1 全文搜索

```json
// match 查询（分词匹配）
GET /products/_search
{
  "query": {
    "match": {
      "title": "华为手机"
    }
  }
}

// match_phrase（短语匹配）
GET /products/_search
{
  "query": {
    "match_phrase": {
      "description": "卫星通信"
    }
  }
}

// multi_match（多字段搜索）
GET /products/_search
{
  "query": {
    "multi_match": {
      "query": "华为",
      "fields": ["title^3", "description", "tags^2"]
    }
  }
}
```

### 4.2 精确查询

```json
// term（精确匹配）
GET /products/_search
{
  "query": {
    "term": {
      "category": "手机"
    }
  }
}

// terms（多值匹配）
GET /products/_search
{
  "query": {
    "terms": {
      "tags": ["华为", "5G"]
    }
  }
}

// range（范围查询）
GET /products/_search
{
  "query": {
    "range": {
      "price": {
        "gte": 3000,
        "lte": 8000
      }
    }
  }
}
```

### 4.3 复合查询

```json
// bool 查询
GET /products/_search
{
  "query": {
    "bool": {
      "must": [
        { "match": { "title": "华为" } }
      ],
      "filter": [
        { "term": { "category": "手机" } },
        { "range": { "price": { "gte": 5000 } } }
      ],
      "should": [
        { "match": { "tags": "旗舰" } }
      ],
      "must_not": [
        { "term": { "is_active": false } }
      ]
    }
  }
}
```

### 4.4 聚合分析

```json
// 按分类统计
GET /products/_search
{
  "size": 0,
  "aggs": {
    "category_count": {
      "terms": {
        "field": "category",
        "size": 10
      }
    },
    "price_stats": {
      "stats": {
        "field": "price"
      }
    }
  }
}

// 日期直方图
GET /orders/_search
{
  "size": 0,
  "aggs": {
    "orders_over_time": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "day"
      }
    }
  }
}
```

## 五、中文分词

### 5.1 安装 IK 分词器

```bash
# 在线安装
docker exec -it es ./bin/elasticsearch-plugin install https://github.com/medcl/elasticsearch-analysis-ik/releases/download/v8.12.0/elasticsearch-analysis-ik-8.12.0.zip

# 重启 ES
docker restart es
```

### 5.2 测试分词效果

```json
POST /_analyze
{
  "analyzer": "ik_max_word",
  "text": "华为Mate60Pro是一款非常不错的旗舰手机"
}
// 结果：华为 / Mate / 60 / Pro / 是 / 一款 / 非常 / 不错 / 旗舰 / 手机

POST /_analyze
{
  "analyzer": "ik_smart",
  "text": "华为Mate60Pro是一款非常不错的旗舰手机"
}
// 结果：华为 / Mate60Pro / 是 / 一款 / 非常 / 不错 / 旗舰 / 手机
```

### 5.3 自定义词典

在 `config/analysis-ik/` 目录下创建自定义词典文件：

```text
# custom.dic
华为Mate60Pro
麒麟芯片
卫星通信
```

在 `IKAnalyzer.cfg.xml` 中配置：

```xml
<properties>
    <entry key="ext_dict">custom.dic</entry>
</properties>
```

## 六、性能优化

### 6.1 写入优化

```json
// 批量写入
POST /_bulk
{"index": {"_index": "products", "_id": "1"}}
{"title": "商品1", "price": 100}
{"index": {"_index": "products", "_id": "2"}}
{"title": "商品2", "price": 200}

// 写入时设置 refresh
PUT /products/_settings
{
  "index": {
    "refresh_interval": "30s",
    "number_of_replicas": 0  // 写入时关副本
  }
}
```

### 6.2 查询优化

```json
// 使用 filter 而非 query
// filter 会缓存结果，不计算评分
GET /products/_search
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "status": "active" } }
      ]
    }
  }
}

// 控制返回字段
GET /products/_search
{
  "_source": ["title", "price"],
  "query": { ... }
}
```

### 6.3 索引优化

```json
// force merge 合并段
POST /products/_forcemerge?max_num_segments=1

// 滚动索引
// 按时间创建索引，如 orders-2026-06
```

### 6.4 硬件与配置

```yaml
# elasticsearch.yml
# JVM 堆内存设置（不超过物理内存的 50%，不超过 32GB）
-Xms8g
-Xmx8g

# 重要配置
bootstrap.memory_lock: true
discovery.seed_hosts: ["node1", "node2", "node3"]
cluster.initial_master_nodes: ["node1", "node2"]
```

## 七、ELK 日志收集实战

### 7.1 Filebeat 配置

```yaml
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/spring-app/*.log
  multiline.pattern: '^\d{4}-\d{2}-\d{2}'
  multiline.negate: true
  multiline.match: after

output.elasticsearch:
  hosts: ["http://elasticsearch:9200"]
  index: "spring-app-%{+yyyy.MM.dd}"
```

### 7.2 Logstash 处理

```ruby
input {
  beats {
    port => 5044
  }
}

filter {
  grok {
    match => { "message" => "%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} %{JAVACLASS:class} - %{GREEDYDATA:message}" }
  }
  date {
    match => ["timestamp", "ISO8601"]
  }
}

output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "spring-app-%{+YYYY.MM.dd}"
  }
}
```

## 八、总结

Elasticsearch 是一个强大但复杂的分布式系统。本文从核心概念、Mapping 设计、查询 DSL、中文分词到生产优化，覆盖了 ES 使用的全流程。建议在实践中逐步深入，先掌握基础 CRUD 和简单搜索，再逐步学习聚合分析和集群调优。

记住一条原则：**了解你的数据模型，设计合理的 Mapping，ES 会给你飞一般的搜索体验。**
