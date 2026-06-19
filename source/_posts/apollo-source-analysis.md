---
title: 分布式配置中心 Apollo 源码深度剖析：架构设计与核心实现
date: 2026-06-19 09:00:00
tags:
  - Apollo
  - 配置中心
  - 源码分析
categories:
  - 中间件
author: 东哥
---
Apollo（阿波罗）是携程开源的一款分布式配置中心，支持配置的集中管理、实时推送、灰度发布等功能。它是目前国内使用最广泛的配置中心之一。本文将从源码层面深度剖析 Apollo 的架构设计、核心实现机制，帮助读者理解其背后的设计思想。

<!-- more -->

## 一、Apollo 整体架构

Apollo 的架构可以概括为"一个 Portal + 两个 Service + 一个 Meta Server"：

![Apollo架构示意图](/images/apollo-arch.png)

### 1.1 模块划分

| 模块 | 责任 | 核心技术栈 |
|-----|------|-----------|
| **Config Service** | 配置读取、推送、客户端长轮询 | Spring Boot、Netty |
| **Admin Service** | 配置管理、发布、回滚 | Spring Boot、JPA |
| **Portal** | Web 管理界面 | Spring Boot + Vue.js |
| **Meta Server** | 服务发现和路由 | 简单的 HTTP 接口 |
| **Client** | 客户端 SDK | Java，支持 Spring/Spring Boot 集成 |

### 1.2 核心数据流

```
用户 → Portal → Admin Service → Config Service → 通知客户端 → 客户端拉取配置
```

**启动流程**：
1. Client 启动时向 Meta Server 获取 Config Service 地址列表
2. 从 Config Service 拉取全量配置并缓存到本地
3. 建立长轮询连接等待配置变更通知
4. 用户通过 Portal 修改配置，调用 Admin Service 发布
5. Admin Service 通知 Config Service 配置已更新
6. Config Service 通知等待中的客户端长轮询
7. 客户端收到通知后，主动拉取最新配置

## 二、核心数据模型

### 2.1 数据库表结构设计

Apollo 的数据模型围绕"App → Namespace → Config"的层级设计：

```sql
-- 核心表结构（MySQL）

-- App 应用表
CREATE TABLE App (
    Id INT PRIMARY KEY AUTO_INCREMENT,
    AppId VARCHAR(64) NOT NULL COMMENT '应用ID',
    Name VARCHAR(128) NOT NULL COMMENT '应用名称',
    OwnerName VARCHAR(64) COMMENT '所有者',
    OrgId VARCHAR(32) COMMENT '部门ID',
    OrgName VARCHAR(64) COMMENT '部门名称',
    DataChange_CreatedBy VARCHAR(64),
    DataChange_LastModifiedBy VARCHAR(64),
    DataChange_CreatedTime DATETIME DEFAULT CURRENT_TIMESTAMP,
    DataChange_LastTime DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX IX_AppId (AppId),
    INDEX IX_DataChange_LastTime (DataChange_LastTime)
);

-- Namespace 命名空间表
CREATE TABLE Namespace (
    Id INT PRIMARY KEY AUTO_INCREMENT,
    AppId VARCHAR(64) NOT NULL,
    ClusterName VARCHAR(64) NOT NULL DEFAULT 'default',
    NamespaceName VARCHAR(128) NOT NULL COMMENT '命名空间名称',
    Format VARCHAR(32) DEFAULT 'properties' COMMENT '配置文件格式',
    DataChange_CreatedBy VARCHAR(64),
    DataChange_LastModifiedBy VARCHAR(64),
    DataChange_CreatedTime DATETIME DEFAULT CURRENT_TIMESTAMP,
    DataChange_LastTime DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX IX_Namespace (AppId, ClusterName, NamespaceName)
);

-- Item 配置项表
CREATE TABLE Item (
    Id INT PRIMARY KEY AUTO_INCREMENT,
    NamespaceId INT NOT NULL COMMENT '所属命名空间',
    `Key` VARCHAR(128) NOT NULL COMMENT '配置key',
    `Value` TEXT COMMENT '配置value',
    Comment VARCHAR(512) COMMENT '注释',
    LineNum INT DEFAULT 0 COMMENT '行号',
    Type INT DEFAULT 0 COMMENT '数据类型',
    DataChange_CreatedBy VARCHAR(64),
    DataChange_LastModifiedBy VARCHAR(64),
    DataChange_CreatedTime DATETIME DEFAULT CURRENT_TIMESTAMP,
    DataChange_LastTime DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX IX_NamespaceId (NamespaceId),
    INDEX IX_DataChange_LastTime (DataChange_LastTime)
);

-- Release 发布表
CREATE TABLE Release (
    Id INT PRIMARY KEY AUTO_INCREMENT,
    ReleaseKey VARCHAR(64) NOT NULL COMMENT '发布唯一标识',
    Name VARCHAR(64) COMMENT '发布名称',
    Comment VARCHAR(1024) COMMENT '发布备注',
    AppId VARCHAR(64) NOT NULL,
    ClusterName VARCHAR(64) NOT NULL DEFAULT 'default',
    NamespaceName VARCHAR(128) NOT NULL,
    Configurations TEXT NOT NULL COMMENT '发布时的全量配置JSON',
    DataChange_CreatedBy VARCHAR(64),
    DataChange_LastModifiedBy VARCHAR(64),
    DataChange_CreatedTime DATETIME DEFAULT CURRENT_TIMESTAMP,
    DataChange_LastTime DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX IX_ReleaseKey (ReleaseKey),
    INDEX IX_DataChange_LastTime (DataChange_LastTime)
);

-- ReleaseHistory 发布历史表
CREATE TABLE ReleaseHistory (
    Id INT PRIMARY KEY AUTO_INCREMENT,
    AppId VARCHAR(64) NOT NULL,
    ClusterName VARCHAR(64) NOT NULL,
    NamespaceName VARCHAR(128) NOT NULL,
    ReleaseId INT NOT NULL COMMENT '关联发布的ID',
    PreviousReleaseId INT COMMENT '上一次发布的ID',
    Operation INT NOT NULL COMMENT '操作类型：0-正常发布，1-回滚',
    OperationContext TEXT COMMENT '操作上下文（JSON）',
    DataChange_CreatedBy VARCHAR(64),
    DataChange_LastModifiedBy VARCHAR(64),
    DataChange_CreatedTime DATETIME DEFAULT CURRENT_TIMESTAMP,
    DataChange_LastTime DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX IX_Namespace (AppId, ClusterName, NamespaceName),
    INDEX IX_ReleaseId (ReleaseId),
    INDEX IX_DataChange_LastTime (DataChange_LastTime)
);
```

### 2.2 核心实体类

```java
// com.ctrip.framework.apollo.common.entity.App 实体
@Entity
@Table(name = "App")
public class App {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private long id;
    
    @Column(name = "AppId", nullable = false)
    private String appId;
    
    @Column(name = "Name", nullable = false)
    private String name;
    
    @Column(name = "OwnerName")
    private String ownerName;
    
    // ... 忽略 getter/setter，以及 DataChangeEntity 继承的审计字段
}

// 审计基类
@MappedSuperclass
public abstract class BaseEntity {
    @Column(name = "DataChange_CreatedBy")
    private String dataChangeCreatedBy;
    
    @Column(name = "DataChange_LastModifiedBy")
    private String dataChangeLastModifiedBy;
    
    @Column(name = "DataChange_CreatedTime")
    private Date dataChangeCreatedTime;
    
    @Column(name = "DataChange_LastTime")
    private Date dataChangeLastTime;
}
```

## 三、配置发布流程源码追踪

配置发布是 Apollo 最核心的业务流程。我们从 Portal 端发起保存开始，到 Config Service 通知 Client 结束，完整跟踪源码：

### 3.1 Portal 发布入口

```java
// com.ctrip.framework.apollo.portal.controller.NamespaceController
@RestController
public class NamespaceController {
    
    @Autowired
    private ConfigService configService;
    
    @Autowired
    private NamespaceService namespaceService;
    
    @PostMapping("/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/items")
    public List<ItemDTO> modifyItems(
            @PathVariable String appId,
            @PathVariable String env,
            @PathVariable String clusterName,
            @PathVariable String namespaceName,
            @RequestBody List<ItemDTO> items) {
        // 1. 校验权限
        // 2. 保存配置项
        return namespaceService.modifyItemsByNamespace(appId, env, clusterName, namespaceName, items);
    }
}
```

### 3.2 Admin Service 保存与发布

```java
// com.ctrip.framework.apollo.adminservice.controller.ItemSetController
@RestController
public class ItemSetController {
    
    @Autowired
    private ConfigService configService;
    
    @PostMapping("/apps/{appId}/clusters/{clusterName}/namespaces/{namespaceName}/itemset")
    public List<ItemDTO> itemSet(
            @PathVariable String appId,
            @PathVariable String clusterName,
            @PathVariable String namespaceName,
            @RequestBody List<ItemDTO> items) {
        List<Item> savedItems = configService.saveItems(appId, clusterName, namespaceName, items);
        return ItemDTOs.fromItems(savedItems);
    }
}

// com.ctrip.framework.apollo.adminservice.service.ConfigService
@Service
public class ConfigService {
    
    @Autowired
    private ItemService itemService;
    
    @Autowired
    private NamespaceService namespaceService;
    
    public List<Item> saveItems(String appId, String clusterName, String namespaceName, List<ItemDTO> items) {
        Namespace namespace = namespaceService.findOne(appId, clusterName, namespaceName);
        
        // 1. 删除该 Namespace 下所有原有 Item
        itemService.batchDelete(namespace.getId());
        
        // 2. 批量插入新的 Item
        List<Item> savedItems = itemService.batchCreate(itemsDTOToItems(items, namespace));
        
        // 3. 发布事件，触发 Config Service 通知客户端
        configFileController.publishNamespace(appId, clusterName, namespaceName, 
            "自动发布", false);
        
        return savedItems;
    }
}
```

### 3.3 Admin Service 调用 Config Service 通知

这里一个重要设计是：Admin Service 通过 Meta Server 发现 Config Service 地址，调用其 REST API 触发通知：

```java
// com.ctrip.framework.apollo.adminservice.controller.ConfigFileController
@RestController
public class ConfigFileController {
    
    @Autowired
    private ReleaseService releaseService;
    
    @Autowired
    private ConfigFileResourceHandler configFileResourceHandler;
    
    @PostMapping("/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/publish")
    public ReleaseDTO publish(@PathVariable String appId, ...) {
        // 1. 创建新的 Release 记录
        Release release = releaseService.publish(
            appId, clusterName, namespaceName, title, comment, operator, isEmergencyPublish);
        
        // 2. 发送配置变更通知消息到 Config Service
        //    实际通过消息队列（meta server 发现）或直接 REST 调用
        configFileResourceHandler.publishNamespace(...);
        
        return ReleaseDTO.fromRelease(release);
    }
}
```

## 四、客户端长轮询实现（核心机制）

Apollo 客户端通过长轮询实现配置变更的实时感知，这是 Apollo 架构中最精妙的设计之一。

### 4.1 Config Service 端：DeferredResult + Spring 异步

```java
// com.ctrip.framework.apollo.configservice.controller.ConfigServlet
@RestController
public class ConfigFileController {
    
    // 配置查询接口，客户端每 30 秒轮询一次
    @GetMapping("/configs/{appId}/{clusterName}/{namespaceName}")
    public ConfigDTO queryConfig(
            @PathVariable String appId,
            @PathVariable String clusterName,
            @PathVariable String namespaceName,
            @RequestParam("dataCenter") String dataCenter,
            @RequestParam(value = "releaseKey", defaultValue = "-1") String clientSideReleaseKey) {
        
        // 1. 检查配置是否有变更
        Config config = configService.findConfig(appId, clusterName, namespaceName, dataCenter);
        if (config == null) {
            return null; // 404
        }
        
        // 2. 比较 releaseKey
        if (!config.getReleaseKey().equals(clientSideReleaseKey)) {
            // 配置已更新，立即返回新配置
            return transformConfig2DTO(config);
        }
        
        // 3. 配置无变化，返回空（客户端会继续轮询）
        return null;
    }
}

// 长轮询的核心实现
@RestController
@RequestMapping("/notifications")
public class NotificationControllerV2 {
    
    // 使用 DeferredResult 实现长轮询
    // 客户端请求到达后，不会立即返回，而是挂起
    @GetMapping
    public DeferredResult<List<ApolloConfigNotification>> pollNotification(
            @RequestParam("appId") String appId,
            @RequestParam("cluster") String cluster,
            @RequestParam(value = "notifications", defaultValue = "{}") String notificationsAsString,
            HttpServletRequest request) {
        
        // 1. 创建 DeferredResult，超时时间 60 秒
        DeferredResult<List<ApolloConfigNotification>> deferredResult = 
            new DeferredResult<>(ConfigConsts.LONG_POLL_TIMEOUT);
        
        // 2. 解析客户端通知状态
        Map<String, Long> clientSideNotifications = 
            gson.fromJson(notificationsAsString, Map.class);
        
        // 3. 将 deferredResult 注册到通知管理器
        deferredResult.onTimeout(() -> {
            // 超时后返回空列表，客户端会再次发起轮询
            deferredResult.setResult(Collections.emptyList());
        });
        
        deferredResult.onCompletion(() -> {
            // 清理注册
            deferredResultManager.unregister(deferredResult);
        });
        
        deferredResultManager.register(appId, cluster, deferredResult, clientSideNotifications);
        
        return deferredResult;
    }
}
```

### 4.2 通知管理器（NotificationManager）

```java
// com.ctrip.framework.apollo.configservice.service.DeferredResultManager
@Component
public class DeferredResultManager {
    
    // 存储所有等待中的 DeferredResult
    // key: "${appId}+${clusterName}"，value: 等待的连接列表
    private final Multimap<String, DeferredResultWrapper> deferredResults = 
        Multimaps.synchronizedSetMultimap(HashMultimap.create());
    
    public void register(String appId, String cluster, 
                         DeferredResult<List<ApolloConfigNotification>> result,
                         Map<String, Long> clientSideNotifications) {
        String key = assembleKey(appId, cluster);
        DeferredResultWrapper wrapper = new DeferredResultWrapper(result, clientSideNotifications);
        deferredResults.put(key, wrapper);
    }
    
    // 当配置发布时调用此方法
    public void onConfigChanged(String appId, String cluster, 
                                String namespaceName, String newReleaseKey) {
        String key = assembleKey(appId, cluster);
        
        // 找到所有等待该 appId+cluster 的 DeferredResult
        for (DeferredResultWrapper wrapper : deferredResults.get(key)) {
            // 检查客户端关心的 namespace 是否包含变更的 namespace
            ApolloConfigNotification notification = new ApolloConfigNotification(namespaceName, 1);
            notification.addMessage(namespaceName, newReleaseKey);
            
            // 设置结果，触发 DeferredResult 完成
            wrapper.getDeferredResult().setResult(List.of(notification));
        }
    }
    
    private String assembleKey(String appId, String cluster) {
        return appId + "+" + cluster;
    }
}
```

### 4.3 客户端长轮询

```java
// com.ctrip.framework.apollo.internals.RemoteConfigRepository
public class RemoteConfigRepository extends AbstractConfigRepository {
    
    private volatile AtomicReference<RemoteMessages> remoteMessages;
    
    @Override
    protected void sync() {
        // 1. 构建请求参数，携带当前已应用的 releaseKey
        // 2. 发起 HTTP GET 请求到 Config Service
        //    请求会 block 住，直到超时或配置变更
        ConfigServiceLocator serviceLocator = ...;
        List<ServiceDTO> configServices = serviceLocator.getConfigServices();
        
        for (int i = 0; i < configServices.size(); i++) {
            try {
                // 选择 Config Service 实例，带重试
                ServiceDTO serviceDTO = randomChooseConfigService(configServices);
                String url = assembleQueryConfigUrl(serviceDTO.getHomepageUrl(), 
                    appId, cluster, namespace, dataCenter, clientSideReleaseKey);
                
                // 4. 如果配置有变更，立即返回全量配置
                ConfigDTO configDTO = restTemplate.getForObject(url, ConfigDTO.class);
                if (configDTO != null) {
                    // 更新本地配置缓存
                    setLocalConfig(configDTO.getConfigurations());
                    fireConfigChange(new ConfigFileChangeEvent(namespace, ...));
                }
                break; // 成功则跳出重试循环
            } catch (Exception e) {
                // Config Service 不可用，尝试下一个
                logger.error("Failed to load config from {}", serviceDTO.getHomepageUrl(), e);
            }
        }
        
        // 5. 如果所有 Config Service 都不可用，使用本地缓存的配置
    }
}
```

**长轮询的完整交互时序**：

```
Client                    Config Service               Admin Service
  |                            |                            |
  |--- GET /notifications ---->|                            |
  |     (长轮询，60s超时)       |                            |
  |                            |                            |
  |                            |         用户发布配置 ------>|
  |                            |                            |
  |                            |<--- 发布事件通知 ----------|
  |                            |                            |
  |                            | 找到匹配的 DeferredResult  |
  |                            | 设置结果返回给 Client      |
  |<--- 通知配置变更 ----------|                            |
  |     (namespace + version)  |                            |
  |                            |                            |
  |--- GET /configs ---------->|                            |
  |     (携带 releaseKey)      |                            |
  |<--- 返回最新配置 ----------|                            |
  |                            |                            |
```

## 五、配置实时推送机制

### 5.1 ReleaseMessage 的实现

Apollo 通过数据库中的 `ReleaseMessage` 表实现 Admin Service 到 Config Service 的消息通知：

```java
// ReleaseMessage 表结构
@Entity
@Table(name = "ReleaseMessage", indexes = {
    @Index(name = "IX_MessageContent", columnList = "MessageContent"),
    @Index(name = "IX_DataChange_LastTime", columnList = "DataChange_LastTime")
})
public class ReleaseMessage {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private long id;
    
    @Column(name = "MessageContent", nullable = false)
    private String messageContent;  // 格式：appId+cluster+namespace
    
    // 审计字段
}
```

### 5.2 ConfigService 轮询 ReleaseMessage

```java
// com.ctrip.framework.apollo.configservice.service.ReleaseMessageService
@Component
public class ReleaseMessageService {
    
    @Autowired
    private ReleaseMessageRepository releaseMessageRepository;
    
    private volatile long maxIdScanned;
    
    @Scheduled(fixedRate = 1000) // 每秒扫描一次
    public void scanNewReleaseMessages() {
        // 每次检查自上次扫描后有没有新的 ReleaseMessage
        List<ReleaseMessage> newMessages = 
            releaseMessageRepository.findFirst100ByMessageContentAndIdGreaterThan(
                "default", maxIdScanned, PageRequest.of(0, 100));
        
        for (ReleaseMessage message : newMessages) {
            // 解析消息内容
            String[] parts = message.getMessageContent().split("+");
            String appId = parts[0];
            String cluster = parts[1];
            String namespace = parts[2];
            
            // 触发通知管理器
            deferredResultManager.onConfigChanged(appId, cluster, namespace, ...);
            
            // 更新已扫描的最大 ID
            maxIdScanned = Math.max(maxIdScanned, message.getId());
        }
    }
}
```

**为什么不用消息中间件？** Apollo 选择数据库轮询而不是 MQ 的考虑：

1. **减少部署依赖**：不强制使用 MQ（Kafka/RabbitMQ），降低运维成本
2. **可靠性**：MySQL 作为最终存储，保证消息不丢失
3. **事务一致性**：配置发布和消息写入在同一数据库事务中
4. **秒级延迟**：1 秒轮询间隔对配置变更场景足够

## 六、缓存设计

### 6.1 服务端缓存

```java
// Config Service 使用两级缓存
@Service
public class ConfigServiceWithCache {
    
    // 一级缓存：Caffeine 本地缓存（微秒级）
    @Cacheable(cacheNames = "configCache", key = "#appId + '_' + #clusterName + '_' + #namespace")
    public Config findConfig(String appId, String clusterName, String namespace) {
        return loadConfigFromDB(appId, clusterName, namespace);
    }
    
    // 二级缓存：Redis（可选配置）
    @Autowired(required = false)
    private StringRedisTemplate redisTemplate;
    
    private static final String CONFIG_CACHE_PREFIX = "apollo:config:";
    
    public Config findConfigWithRedis(String appId, String clusterName, String namespace) {
        String key = CONFIG_CACHE_PREFIX + appId + ":" + clusterName + ":" + namespace;
        
        // 先查 Redis
        String cached = redisTemplate.opsForValue().get(key);
        if (cached != null) {
            return JSON.parseObject(cached, Config.class);
        }
        
        // Redis 没有则查 DB，并回填 Redis
        Config config = loadConfigFromDB(appId, clusterName, namespace);
        redisTemplate.opsForValue().set(key, JSON.toJSONString(config), 5, TimeUnit.MINUTES);
        return config;
    }
}
```

### 6.2 客户端本地缓存

客户端 SDK 会同时维护多级缓存：

```java
// com.ctrip.framework.apollo.internals.LocalFileConfigRepository
public class LocalFileConfigRepository extends AbstractConfigRepository {
    
    // 缓存策略
    private ConfigCacheFile cacheFile;  // 本地文件缓存
    private Properties cachedProperties; // 内存缓存
    
    // 容灾设计
    @Override
    protected void sync() {
        Properties currentProperties = loadFromRemote();
        
        if (currentProperties == null) {
            // 远程加载失败，使用本地文件缓存
            currentProperties = loadFromLocalCacheFile();
            logger.warn("Fallback to local cache file");
        }
        
        if (currentProperties == null) {
            // 本地文件也不存在，尝试加载 classpath 下的 application.properties
            currentProperties = loadFromClasspath();
        }
        
        if (currentProperties == null) {
            throw new ConfigNotFoundException("No config found for " + namespace);
        }
        
        // 更新内存缓存
        this.cachedProperties = currentProperties;
        // 更新本地文件
        persistLocalCacheFile(currentProperties);
    }
}
```

**客户端缓存优先级**：内存缓存 → 本地文件缓存 → classpath 配置。

## 七、高可用方案与 Meta Server

### 7.1 Meta Server 选址策略

```java
// com.ctrip.framework.apollo.core.MetaDomainConsts
public class MetaDomainConsts {
    
    // Meta Server 地址配置
    // 从 apollo-env.properties 读取
    private static final String DEV_META = "http://dev.meta.com";
    private static final String FAT_META = "http://fat.meta.com";
    private static final String UAT_META = "http://uat.meta.com";
    private static final String PRO_META = "http://pro.meta.com";
}
```

```java
// com.ctrip.framework.apollo.internals.ConfigServiceLocator
public class ConfigServiceLocator {
    
    // 从 Meta Server 获取 Config Service 地址
    public List<ServiceDTO> getConfigServices() {
        List<ServiceDTO> services = new ArrayList<>();
        
        // 1. 从 Meta Server 获取
        String metaServerUrl = getMetaServerUrl();
        try {
            ResponseEntity<List<ServiceDTO>> response = restTemplate.exchange(
                metaServerUrl + "/services/config",
                HttpMethod.GET,
                null,
                new ParameterizedTypeReference<List<ServiceDTO>>() {}
            );
            services = response.getBody();
        } catch (Exception e) {
            logger.error("Failed to get config services from meta server", e);
        }
        
        // 2. 如果 Meta Server 不可用，使用本地缓存的地址
        if (services.isEmpty()) {
            services = loadFromLocalCache();
        }
        
        return services;
    }
}
```

### 7.2 高可用部署架构

| 组件 | 高可用方案 | 部署建议 |
|-----|-----------|---------|
| Portal | 多实例 + Nginx 负载均衡 | 至少 2 节点 |
| Config Service | 多实例 + 无状态 | 至少 2 节点 |
| Admin Service | 多实例 + 无状态 | 至少 2 节点 |
| Meta Server | 多实例 + DNS 轮询 | 与 Config Service 同进程 |
| MySQL | 主从复制 + 半同步 | 一主一从 |

## 八、开放平台 API

Apollo 提供了开放平台 API，允许第三方系统通过 HTTP 调用管理配置：

```java
// 开放平台认证
// 1. 申请 OpenAPI 授权
// Portal → 管理员工具 → 开放平台授权
// 会生成 AppId 对应的 token

// 2. 使用 token 访问 API
@RestController
@RequestMapping("/openapi/v1")
public class OpenApiController {
    
    @Autowired
    private NamespaceService namespaceService;
    
    // 创建 Namespace
    @PostMapping("/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces")
    public NamespaceDTO createNamespace(
            @PathVariable String appId,
            @PathVariable String env,
            @PathVariable String clusterName,
            @RequestBody NamespaceDTO dto,
            @RequestHeader("Authorization") String token) {
        
        // 1. 校验 token 权限
        openApiAuthService.validate(token, appId, PermissionType.CREATE_NAMESPACE);
        
        // 2. 创建 Namespace
        return namespaceService.createNamespace(appId, env, clusterName, dto);
    }
    
    // 发布配置
    @PostMapping("/apps/{appId}/envs/{env}/clusters/{clusterName}/namespaces/{namespaceName}/releases")
    public ReleaseDTO publish(
            @PathVariable String appId,
            @PathVariable String env,
            @PathVariable String clusterName,
            @PathVariable String namespaceName,
            @RequestBody ReleaseRequest request,
            @RequestHeader("Authorization") String token) {
        
        openApiAuthService.validate(token, appId, PermissionType.CREATE_RELEASE);
        
        return releaseService.publish(appId, env, clusterName, namespaceName,
            request.getReleaseTitle(), request.getReleaseComment(),
            request.getOperator(), request.isEmergencyPublish());
    }
}
```

**开放平台 API 常用场景**：

- CI/CD 流水线中自动发布配置
- 配置迁移工具（从其他配置中心迁移到 Apollo）
- 与其他系统（发布系统、监控系统）集成

## 九、核心类与接口一览

| 类/接口 | 所在模块 | 核心职责 |
|---------|---------|---------|
| `ConfigService` | admin-service | 配置 CRUD、发布管理 |
| `ReleaseService` | admin-service | 配置发布、回滚 |
| `NamespaceService` | admin-service | 命名空间管理 |
| `NotificationControllerV2` | config-service | 长轮询端点 |
| `ConfigFileController` | config-service | 配置查询端点 |
| `DeferredResultManager` | config-service | 长轮询连接管理 |
| `RemoteConfigRepository` | client | 客户端配置仓库 |
| `ConfigUtil` | client | 配置读取工具 |
| `DefaultConfig` | client | 默认配置实现 |
| `ConfigServiceLocator` | client | Config Service 发现 |
| `SpringValueProcessor` | client | Spring 集成处理器 |

## 总结

Apollo 作为一款经过生产大规模验证的配置中心，其架构设计有以下几个值得学习的核心思想：

1. **无状态设计**：Config Service 和 Admin Service 都是无状态的，可以水平扩展
2. **数据库轮询替代 MQ**：用数据库轮询实现消息通知，降低运维复杂度
3. **多级缓存**：服务端本地缓存 + Redis + 客户端本地文件缓存，保证高可用
4. **长轮询机制**：基于 DeferredResult 的长轮询，在实时性和资源消耗之间取得平衡
5. **容灾设计**：客户端在 Config Service 不可用时自动降级到本地缓存

理解这些源码层面的设计细节，不仅有助于更好地使用 Apollo，对设计其他分布式基础组件也有很高的参考价值。
