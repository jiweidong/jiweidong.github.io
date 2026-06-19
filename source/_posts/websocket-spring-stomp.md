---
title: WebSocket 与 STOMP 协议在 Spring 中的实践指南
date: 2026-06-17 08:00:00
tags:
  - WebSocket
  - STOMP
  - Spring
  - 实时通信
  - Java
categories:
  - 后端开发
author: 东哥
---

# WebSocket 与 STOMP 协议在 Spring 中的实践指南

> 在当今互联网应用中，实时通信已经成为标配。从即时聊天、消息推送，到实时数据看板、在线协作编辑，WebSocket 技术无处不在。本文将从基础原理到 Spring 框架的完整实践，带你全面掌握 WebSocket + STOMP 在企业级项目中的应用。

## 一、WebSocket 协议基础

### 1.1 什么是 WebSocket

WebSocket 是一种在单个 TCP 连接上进行**全双工通信**的协议。与传统的 HTTP 请求-响应模式不同，WebSocket 允许服务器主动向客户端推送数据。

**HTTP 轮询 vs WebSocket 对比：**

| 特性 | HTTP 轮询 | HTTP 长轮询 | WebSocket |
|------|-----------|------------|-----------|
| **通信方向** | 单向（客户端→服务器） | 半双工 | 全双工 |
| **协议开销** | 每次请求≈800B Header | 每次请求≈800B Header | 建立连接后≈2B/帧 |
| **实时性** | 取决于轮询间隔 | 接近实时 | 实时 |
| **服务器压力** | 高（大量无效请求） | 中 | 低 |
| **连接数** | 无状态 | 需维持连接池 | 单个长连接 |
| **适用场景** | 非实时数据 | 消息通知 | 高频实时通信 |

### 1.2 WebSocket 握手过程

WebSocket 握手通过 HTTP Upgrade 机制实现：

```
客户端请求：
GET /ws/chat HTTP/1.1
Host: server.example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13

服务器响应：
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

### 1.3 WebSocket 帧结构

WebSocket 数据传输以帧（Frame）为单位：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
|N|V|V|V|       |S|             |   (if payload len==126/127)   |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - +
|     Extended payload length continued, if payload len == 127  |
+ - - - - - - - - - - - - - - - +-------------------------------+
|                               |Masking-key, if MASK set to 1  |
+-------------------------------+-------------------------------+
| Masking-key (continued)       |          Payload Data         |
+-------------------------------- - - - - - - - - - - - - - - +
:                     Payload Data continued ...                :
+ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
|                     Payload Data (continued)                  |
+---------------------------------------------------------------+
```

## 二、STOMP 协议简介

### 2.1 为什么需要 STOMP

原生 WebSocket 只提供**二进制帧传输**，没有定义消息格式和路由方式。STOMP（Simple Text Oriented Messaging Protocol）在 WebSocket 之上提供了类似消息队列的**发布-订阅模型**：

```
命令                          Header                     Body
┌──────┐  ┌──────────────────────────────────┐  ┌──────────────┐
│SEND   │  │destination:/topic/chat          │  │{"msg":"Hello"}│
│       │  │content-type:application/json    │  │              │
│       │  │content-length:17                │  │              │
├──────┤  ├──────────────────────────────────┤  ├──────────────┤
│     \n│  │                                  │  │        \0    │
└──────┴──┴──────────────────────────────────┴──┴──────────────┘
```

### 2.2 STOMP 帧结构

```
┌──────────┬─────────────────────────────────────┐
│  命令     │ SEND, SUBSCRIBE, UNSUBSCRIBE,      │
│          │ MESSAGE, CONNECT, CONNECTED, ACK    │
├──────────┼─────────────────────────────────────┤
│  Header  │ destination, id, subscription,      │
│          │ content-type, receipt, heart-beat   │
├──────────┼─────────────────────────────────────┤
│  Body    │ 消息体内容（可选）                    │
├──────────┼─────────────────────────────────────┤
│   结束符  │ NULL 字符 (\0)                      │
└──────────┴─────────────────────────────────────┘
```

**完整的 STOMP 帧示例：**

```stomp
CONNECT
accept-version:1.2
host:localhost
heart-beat:10000,10000

\0

SUBSCRIBE
id:sub-1
destination:/topic/public
ack:auto

\0

SEND
destination:/app/chat.sendMessage
content-type:application/json

{"sender":"东哥","content":"大家好！"}
\0
```

## 三、Spring WebSocket 架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                   客户端 (JavaScript)                         │
│            SockJS  +  STOMP.js / @stomp/stompjs              │
└─────────────────────────┬───────────────────────────────────┘
                          │ WebSocket / SockJS
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                 Spring WebSocket 服务端                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │           WebSocketHandler / HandshakeInterceptor      │  │
│  └──────────────────────────┬────────────────────────────┘  │
│                             │                               │
│  ┌──────────────────────────▼────────────────────────────┐  │
│  │              STOMP 协议层处理                            │  │
│  │   ┌─────────────────┐    ┌────────────────────────┐    │  │
│  │   │ @MessageMapping  │    │ ChannelInterceptor     │    │  │
│  │   │ @SubscribeMapping│    │ （认证/鉴权/过滤）      │    │  │
│  │   └────────┬────────┘    └────────────────────────┘    │  │
│  └────────────┼───────────────────────────────────────────┘  │
│               │                                              │
│  ┌────────────▼───────────────────────────────────────────┐  │
│  │                 消息代理 (Message Broker)                │  │
│  │  ┌──────────────────────┐  ┌────────────────────────┐  │  │
│  │  │  Simple Broker (内存) │  │  External Broker       │  │  │
│  │  │  默认实现，单节点可用   │  │  RabbitMQ/ActiveMQ     │  │  │
│  │  └──────────────────────┘  └────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 核心组件

| 组件 | 职责 | 说明 |
|------|------|------|
| **WebSocketHandler** | 处理原始 WebSocket 连接 | 很少直接使用 |
| **HandshakeInterceptor** | 握手拦截器 | 在连接建立前做认证 |
| **ChannelInterceptor** | 消息通道拦截器 | 拦截入站/出站消息 |
| **@MessageMapping** | 消息映射注解 | 类似 @RequestMapping |
| **@SendTo** | 指定响应目的地 | 广播消息 |
| **@SendToUser** | 指定用户响应目的地 | 点对点消息 |
| **SimpMessagingTemplate** | 编程式消息发送 | 从任意位置发送 |
| **MessageBroker** | 消息代理 | 路由消息到订阅者 |

## 四、配置 WebSocket 端点与拦截器

### 4.1 基础配置

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {

    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        // 消息代理前缀：这些目的地的消息由代理转发给订阅者
        // 即客户端订阅 /topic/xxx 或 /queue/xxx 来接收消息
        config.enableSimpleBroker("/topic", "/queue");
        
        // 应用目的地前缀：客户端发送到 /app 开头的消息
        // 会路由到 @MessageMapping 方法处理
        config.setApplicationDestinationPrefixes("/app");
        
        // 用户目的地前缀
        config.setUserDestinationPrefix("/user");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        // 注册 STOMP 端点，客户端通过此端点建立连接
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("*")
                .addInterceptors(new AuthHandshakeInterceptor())
                .withSockJS();  // 启用 SockJS 回退
    }
}
```

### 4.2 握手拦截器

```java
/**
 * WebSocket 握手拦截器 — 在连接建立前进行 Token 验证
 */
public class AuthHandshakeInterceptor implements HandshakeInterceptor {
    
    @Override
    public boolean beforeHandshake(ServerHttpRequest request, 
                                   ServerHttpResponse response,
                                   WebSocketHandler wsHandler, 
                                   Map<String, Object> attributes) {
        
        // 从查询参数中获取 Token
        String token = null;
        if (request instanceof ServletServerHttpRequest) {
            ServletServerHttpRequest servletRequest = 
                (ServletServerHttpRequest) request;
            token = servletRequest.getServletRequest()
                .getParameter("token");
        }
        
        // 验证 Token（示例用简化逻辑）
        if (token != null && validateToken(token)) {
            String userId = extractUserId(token);
            attributes.put("userId", userId);
            attributes.put("username", extractUsername(token));
            return true;
        }
        
        log.warn("WebSocket 握手失败：无效的 token");
        return false;  // 拒绝连接
    }

    @Override
    public void afterHandshake(ServerHttpRequest request,
                               ServerHttpResponse response,
                               WebSocketHandler wsHandler,
                               Exception exception) {
        // 握手完成后的处理
    }
    
    private boolean validateToken(String token) {
        return token != null && token.length() > 10;
    }
    
    private String extractUserId(String token) {
        return "user_" + token.hashCode();
    }
    
    private String extractUsername(String token) {
        return "user_" + Math.abs(token.hashCode() % 10000);
    }
}
```

## 五、STOMP 消息代理

### 5.1 简单代理（Simple Broker）

简单代理是 Spring 内置的**内存消息代理**，适用于单节点部署：

```java
// 配置简单代理
config.enableSimpleBroker("/topic", "/queue");

// 配置线程池
@Bean
public TaskExecutor clientInboundChannelExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(4);
    executor.setMaxPoolSize(10);
    executor.setQueueCapacity(1000);
    executor.setThreadNamePrefix("ws-inbound-");
    executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
    return executor;
}

@Bean
public TaskExecutor clientOutboundChannelExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(4);
    executor.setMaxPoolSize(10);
    executor.setQueueCapacity(1000);
    executor.setThreadNamePrefix("ws-outbound-");
    return executor;
}

@Bean
public TaskExecutor brokerChannelExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(2);
    executor.setMaxPoolSize(5);
    executor.setQueueCapacity(500);
    executor.setThreadNamePrefix("ws-broker-");
    return executor;
}
```

### 5.2 外部代理（RabbitMQ）

生产环境中推荐使用外部消息代理实现**集群部署**和**高可用**：

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketRabbitMQConfig implements WebSocketMessageBrokerConfigurer {

    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        // 使用 RabbitMQ 作为外部消息代理
        config.enableStompBrokerRelay("/topic", "/queue")
                .setRelayHost("rabbitmq.example.com")
                .setRelayPort(61613)         // STOMP 端口
                .setClientLogin("guest")
                .setClientPasscode("guest")
                .setSystemLogin("guest")
                .setSystemPasscode("guest")
                .setSystemHeartbeatSendInterval(10000)
                .setSystemHeartbeatReceiveInterval(10000);
        
        config.setApplicationDestinationPrefixes("/app");
        config.setUserDestinationPrefix("/user");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        registry.addEndpoint("/ws")
                .setAllowedOriginPatterns("*")
                .withSockJS();
    }
}
```

### 5.3 简单代理 vs 外部代理对比

| 维度 | Simple Broker | External Broker (RabbitMQ) |
|------|--------------|--------------------------|
| **适用规模** | 单节点、小规模 | 集群、大规模 |
| **配置复杂度** | 低 | 高 |
| **内存占用** | 高（所有消息在内存） | 低（消息在代理端） |
| **消息持久化** | ❌ 不支持 | ✅ 支持 |
| **集群支持** | ❌ 不支持 | ✅ 原生集群 |
| **消息积压** | 易导致 OOM | ✅ 可持久化积压 |
| **运维成本** | 无 | 需独立部署 RabbitMQ |
| **推荐场景** | 开发测试、小型系统 | 生产环境、高并发系统 |

## 六、@MessageMapping 注解使用详解

### 6.1 基础用法

```java
@Controller
public class ChatController {

    /**
     * 接收客户端发往 /app/chat.sendMessage 的消息
     * 处理后将结果广播到 /topic/public
     */
    @MessageMapping("/chat.sendMessage")
    @SendTo("/topic/public")
    public ChatMessage sendMessage(@Payload ChatMessage chatMessage,
                                    SimpMessageHeaderAccessor headerAccessor) {
        String username = (String) headerAccessor.getSessionAttributes()
            .get("username");
        chatMessage.setSender(username);
        chatMessage.setTimestamp(Instant.now().toString());
        return chatMessage;
    }

    /**
     * 用户加入处理
     */
    @MessageMapping("/chat.addUser")
    @SendTo("/topic/public")
    public ChatMessage addUser(@Payload ChatMessage chatMessage,
                                SimpMessageHeaderAccessor headerAccessor) {
        headerAccessor.getSessionAttributes()
            .put("username", chatMessage.getSender());
        chatMessage.setType(MessageType.JOIN);
        chatMessage.setTimestamp(Instant.now().toString());
        return chatMessage;
    }
}
```

### 6.2 高级特性

```java
@Controller
public class AdvancedController {

    /**
     * 带路径变量的消息映射
     */
    @MessageMapping("/chat/{roomId}/send")
    @SendTo("/topic/chat/{roomId}")
    public ChatMessage sendToRoom(@Payload ChatMessage message,
                                   @DestinationVariable String roomId) {
        message.setRoomId(roomId);
        return message;
    }

    /**
     * 返回值可以转换，返回多个目的地
     */
    @MessageMapping("/notification/broadcast")
    @SendTo("/topic/notifications")
    public Notification broadcast(@Payload Notification notification) {
        return notification;
    }

    /**
     * 使用 @Header 获取消息头
     */
    @MessageMapping("/chat/private")
    public void sendPrivate(@Payload PrivateMessage message,
                            @Header("simpSessionId") String sessionId,
                            Principal principal) {
        log.info("用户 {} 发送私信，sessionId={}", principal.getName(), sessionId);
        // 处理私信
    }

    /**
     * 订阅映射 — 当客户端订阅某个目的地时触发
     */
    @SubscribeMapping("/topic/initial")
    public List<ChatMessage> onSubscribe() {
        // 返回连接后立即推送的初始化数据
        return chatHistoryService.getRecentMessages(20);
    }
}
```

### 6.3 消息流说明

```
客户端                    服务端
  │                        │
  │  SUBSCRIBE             │  订阅消息
  │  /topic/public         │
  │────────────────────────→│
  │                        │
  │  SEND                  │
  │  /app/chat.sendMessage │  @MessageMapping 处理
  │────────────────────────→│
  │                        │
  │                        │  @SendTo("/topic/public")
  │  MESSAGE               │
  │  /topic/public         │  广播给所有订阅者
  │←───────────────────────│
```

## 七、广播与点对点消息

### 7.1 广播消息

```java
/**
 * 广播消息到所有连接的客户端
 */
@MessageMapping("/broadcast/system")
@SendTo("/topic/system")
public SystemMessage broadcastSystemMessage(@Payload SystemMessage message) {
    message.setTimestamp(System.currentTimeMillis());
    return message;
}
```

### 7.2 点对点消息

```java
@Controller
public class PrivateMessageController {

    /**
     * 处理私信：客户端发送到 /app/private，服务端转发给指定用户
     */
    @MessageMapping("/private")
    public void handlePrivateMessage(@Payload PrivateMessage message,
                                      Principal principal,
                                      SimpMessagingTemplate messagingTemplate) {
        
        // 记录发送者
        message.setFromUser(principal.getName());
        message.setTimestamp(System.currentTimeMillis());
        
        // 使用 SimpMessagingTemplate 发送给指定用户
        // 客户端订阅 /user/queue/private-messages
        messagingTemplate.convertAndSendToUser(
            message.getToUser(),
            "/queue/private-messages",
            message
        );
    }
}
```

### 7.3 SimpMessagingTemplate 使用

```java
@Service
public class NotificationService {

    @Autowired
    private SimpMessagingTemplate messagingTemplate;

    /**
     * 用户收到新消息时推送通知
     */
    public void sendNewMessageNotification(String userId, MessageNotification notification) {
        // 发送给指定用户
        messagingTemplate.convertAndSendToUser(
            userId,
            "/queue/notifications",
            notification
        );
    }

    /**
     * 系统广播通知
     */
    public void sendSystemAlert(SystemAlert alert) {
        messagingTemplate.convertAndSend("/topic/system-alerts", alert);
    }

    /**
     * 业务数据更新推送（如订单状态变更）
     */
    public void notifyOrderUpdate(String userId, OrderUpdateDTO update) {
        messagingTemplate.convertAndSendToUser(
            userId,
            "/queue/orders",
            update
        );
    }

    /**
     * 发送到指定 session
     */
    public void sendToSession(String sessionId, Object payload) {
        messagingTemplate.convertAndSend(
            "/queue/session-" + sessionId,
            payload
        );
    }
}
```

## 八、用户订阅与消息路由

### 8.1 用户身份识别

```java
/**
 * 通过 ChannelInterceptor 获取用户身份并设置 Principal
 */
@Component
public class UserChannelInterceptor implements ChannelInterceptor {

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = 
            MessageHeaderAccessor.getAccessor(message, StompHeaderAccessor.class);
        
        if (StompCommand.CONNECT.equals(accessor.getCommand())) {
            // 从 Header 中获取 Token
            String token = accessor.getFirstNativeHeader("auth-token");
            if (token != null) {
                // 验证并设置用户
                UserPrincipal user = authenticate(token);
                accessor.setUser(user);
            }
        }
        
        return message;
    }
    
    private UserPrincipal authenticate(String token) {
        // 实际项目中调用认证服务
        return new UserPrincipal(extractUserId(token));
    }
}
```

```java
// 注册拦截器
@Override
public void configureClientInboundChannel(ChannelRegistration registration) {
    registration.interceptors(new UserChannelInterceptor());
}
```

### 8.2 消息路由规则

```
客户端订阅 ──→ 目的地 ──→ 处理逻辑
─────────────────────────────────
/user/queue/private-messages  ──→ 用户私信队列
/user/queue/notifications     ──→ 用户通知队列
/topic/public                  ──→ 公共聊天室
/topic/chat/{roomId}           ──→ 聊天室路由
/topic/system-alerts           ──→ 系统告警广播
/queue/orders                  ──→ 外部代理队列
```

## 九、心跳机制与断线重连

### 9.1 服务端配置

```java
@Override
public void configureMessageBroker(MessageBrokerRegistry config) {
    config.enableSimpleBroker("/topic", "/queue")
            .setHeartbeatValue(new long[]{10000, 10000});  // 每10秒发送心跳
}
```

### 9.2 前端心跳处理

```javascript
// 前端 STOMP 客户端自动处理心跳
const client = new StompJs.Client({
    brokerURL: 'ws://localhost:8080/ws',
    heartbeatIncoming: 10000,  // 期待服务端心跳间隔（毫秒）
    heartbeatOutgoing: 10000,  // 发送心跳间隔（毫秒）
    reconnectDelay: 5000,      // 断线重连延迟
});
```

### 9.3 完整的断线重连实现

```javascript
const stompClient = new StompJs.Client({
    brokerURL: wsUrl,
    connectHeaders: {
        'auth-token': getToken()
    },
    debug: function(str) {
        console.log('STOMP: ' + str);
    },
    reconnectDelay: 5000,
    heartbeatIncoming: 10000,
    heartbeatOutgoing: 10000,
    
    onConnect: function(frame) {
        console.log('WebSocket 连接成功！');
        updateConnectionStatus('connected');
        
        // 重新订阅
        subscribeChannels();
    },
    
    onStompError: function(frame) {
        console.error('STOMP 错误:', frame.headers['message']);
        updateConnectionStatus('error');
    },
    
    onWebSocketClose: function() {
        console.log('WebSocket 已关闭，正在重连...');
        updateConnectionStatus('reconnecting');
    }
});

// 订阅管理
const subscriptions = {};

function subscribeChannels() {
    // 公共频道
    subscriptions.public = stompClient.subscribe('/topic/public', 
        onMessageReceived);
    
    // 用户私信
    subscriptions.private = stompClient.subscribe(
        '/user/queue/private-messages',
        onPrivateMessage
    );
    
    // 系统通知
    subscriptions.notifications = stompClient.subscribe(
        '/user/queue/notifications',
        onNotification
    );
}
```

## 十、Spring Security 集成认证

### 10.1 基于 Token 的 WebSocket 认证

```java
@Component
public class WebSocketSecurityInterceptor implements ChannelInterceptor {

    @Autowired
    private JwtTokenProvider tokenProvider;

    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = 
            MessageHeaderAccessor.getAccessor(message, StompHeaderAccessor.class);
        
        if (accessor == null) return message;
        
        switch (accessor.getCommand()) {
            case CONNECT:
                // 从 CONNECT 帧的 Header 中获取 Token
                String token = accessor.getFirstNativeHeader("auth-token");
                if (token != null && tokenProvider.validateToken(token)) {
                    String userId = tokenProvider.getUserIdFromToken(token);
                    String username = tokenProvider.getUsernameFromToken(token);
                    
                    // 创建认证对象
                    UsernamePasswordAuthenticationToken authentication =
                        new UsernamePasswordAuthenticationToken(
                            userId, null, 
                            List.of(new SimpleGrantedAuthority("ROLE_USER"))
                        );
                    authentication.setDetails(username);
                    
                    accessor.setUser(authentication);
                    log.debug("WebSocket 用户 {} 认证通过", username);
                } else {
                    log.warn("WebSocket 连接认证失败：无效 Token");
                    throw new AuthenticationCredentialsNotFoundException("认证失败");
                }
                break;
                
            case SUBSCRIBE:
                // 验证订阅权限
                String destination = accessor.getDestination();
                Principal principal = accessor.getUser();
                
                if (destination != null && destination.startsWith("/queue/")) {
                    if (principal == null) {
                        throw new AccessDeniedException("未认证用户无法订阅私有队列");
                    }
                }
                break;
                
            case SEND:
                // 验证消息发送权限
                break;
        }
        
        return message;
    }
}
```

### 10.2 安全配置

```java
@Configuration
@EnableWebSocketSecurity
public class WebSocketSecurityConfig {
    
    @Bean
    public AuthorizationManager<Message<?>> messageAuthorizationManager() {
        // 定义消息授权规则
        AuthorizationManager<Message<?>> authorizationManager =
            MessageMatcherDelegatingAuthorizationManager.builder()
                .simpDestMatchers("/topic/public").permitAll()
                .simpDestMatchers("/topic/**").authenticated()
                .simpDestMatchers("/queue/**").authenticated()
                .simpDestMatchers("/app/**").authenticated()
                .simpTypeMatchers(SimpMessageType.CONNECT).authenticated()
                .simpSubscribeDestMatchers("/user/**").authenticated()
                .anyMessage().denyAll()
                .build();
        
        return authorizationManager;
    }
}
```

## 十一、前端 JavaScript SockJS + STOMP 客户端

### 11.1 基础 HTML 页面

```html
<!DOCTYPE html>
<html>
<head>
    <title>实时聊天</title>
    <script src="/webjars/sockjs-client/sockjs.min.js"></script>
    <script src="/webjars/stomp-websocket/stomp.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@stomp/stompjs@7.0.0/bundles/stomp.umd.min.js">
    </script>
</head>
<body>
    <div id="chat-container">
        <div id="messages"></div>
        <div id="input-area">
            <input type="text" id="message-input" placeholder="输入消息...">
            <button onclick="sendMessage()">发送</button>
        </div>
    </div>
    
    <script>
        let stompClient = null;
        const token = localStorage.getItem('auth-token');
        
        function connect() {
            // 方式1：SockJS + STOMP
            const socket = new SockJS('/ws?token=' + token);
            stompClient = Stomp.over(socket);
            
            // 方式2：原生 WebSocket + STOMP（推荐）
            // const client = new StompJs.Client({
            //     brokerURL: 'ws://localhost:8080/ws',
            //     connectHeaders: { 'auth-token': token }
            // });
            
            stompClient.connect({}, onConnected, onError);
        }
        
        function onConnected() {
            console.log('连接成功！');
            
            // 订阅公共聊天频道
            stompClient.subscribe('/topic/public', onMessageReceived);
            
            // 订阅私信
            stompClient.subscribe('/user/queue/private-messages', onPrivateMessage);
            
            // 发送用户加入通知
            stompClient.send("/app/chat.addUser", {}, 
                JSON.stringify({sender: username, type: 'JOIN'}));
        }
        
        function sendMessage() {
            const content = document.getElementById('message-input').value;
            
            stompClient.send("/app/chat.sendMessage", {}, 
                JSON.stringify({content: content}));
            
            document.getElementById('message-input').value = '';
        }
        
        function onMessageReceived(payload) {
            const message = JSON.parse(payload.body);
            displayMessage(message);
        }
        
        function onError(error) {
            console.error('STOMP 错误:', error);
            setTimeout(connect, 5000); // 5秒后重连
        }
    </script>
</body>
</html>
```

## 十二、实际应用场景

### 12.1 实时聊天系统

```java
@Controller
public class ChatRoomController {
    
    @MessageMapping("/chat/{roomId}/send")
    @SendTo("/topic/chat/{roomId}")
    public ChatMessage sendToRoom(@Payload ChatMessage message,
                                   @DestinationVariable String roomId,
                                   Principal principal) {
        message.setSender(principal.getName());
        message.setTimestamp(LocalDateTime.now().toString());
        message.setRoomId(roomId);
        
        // 持久化聊天记录
        chatHistoryRepository.save(message);
        
        return message;
    }
    
    @SubscribeMapping("/chat/{roomId}/history")
    public List<ChatMessage> loadHistory(@DestinationVariable String roomId) {
        return chatHistoryRepository
            .findByRoomIdOrderByTimestampDesc(roomId, PageRequest.of(0, 50));
    }
}
```

### 12.2 消息推送系统

```java
@Service
public class PushNotificationService {
    
    @Autowired
    private SimpMessagingTemplate messagingTemplate;
    
    /**
     * 订单状态变更推送
     */
    public void pushOrderStatusChange(String userId, Long orderId, 
                                       String oldStatus, String newStatus) {
        OrderNotification notification = OrderNotification.builder()
            .type("ORDER_STATUS_CHANGE")
            .orderId(orderId)
            .oldStatus(oldStatus)
            .newStatus(newStatus)
            .timestamp(LocalDateTime.now())
            .build();
        
        messagingTemplate.convertAndSendToUser(
            userId, "/queue/notifications", notification
        );
    }
    
    /**
     * 批量推送（使用 CompletableFuture 异步）
     */
    public void batchPush(List<String> userIds, Notification notification) {
        CompletableFuture<?>[] futures = userIds.stream()
            .map(userId -> CompletableFuture.runAsync(() -> {
                try {
                    messagingTemplate.convertAndSendToUser(
                        userId, "/queue/notifications", notification
                    );
                } catch (Exception e) {
                    log.error("推送失败 userId={}", userId, e);
                }
            }))
            .toArray(CompletableFuture[]::new);
        
        CompletableFuture.allOf(futures).join();
    }
}
```

### 12.3 实时数据看板

```java
@Controller
public class RealtimeDashboardController {
    
    @Autowired
    private SimpMessagingTemplate messagingTemplate;
    
    @Autowired
    private DashboardDataService dashboardService;
    
    /**
     * 定时推送仪表盘数据（如每秒一次）
     */
    @Scheduled(fixedRate = 1000)
    public void pushDashboardData() {
        DashboardData data = DashboardData.builder()
            .activeUsers(dashboardService.getActiveUserCount())
            .ordersPerSecond(dashboardService.getOrdersPerSecond())
            .totalRevenue(dashboardService.getTodayRevenue())
            .errorRate(dashboardService.getErrorRate())
            .serverMetrics(dashboardService.getServerMetrics())
            .timestamp(System.currentTimeMillis())
            .build();
        
        messagingTemplate.convertAndSend("/topic/dashboard", data);
    }
    
    /**
     * 按需更新特定用户看板
     */
    public void updateUserDashboard(String userId) {
        UserDashboardData data = userDashboardService.getData(userId);
        messagingTemplate.convertAndSendToUser(
            userId, "/queue/dashboard", data
        );
    }
}
```

## 十三、性能优化与集群部署

### 13.1 性能优化

| 优化项 | 方案 | 效果 |
|-------|------|------|
| **配置线程池** | 合理配置入站/出站通道线程池 | 避免线程瓶颈 |
| **消息体压缩** | 使用 GZIP 压缩大消息 | 减少网络传输 |
| **消息合并** | 高频更新合并成批量推送 | 减少帧数量 |
| **心跳调优** | 根据场景调整心跳间隔 | 降低无谓网络开销 |
| **消息过滤** | 在服务端过滤后再推送 | 减少无效推送 |
| **异步发送** | 使用 @Async 异步发送 | 提升吞吐量 |
| **限制订阅数** | 限制单个连接订阅数量 | 防止资源泄漏 |

### 13.2 集群部署方案

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Nginx     │    │   Nginx     │    │   Nginx     │
│  负载均衡    │    │  负载均衡    │    │  负载均衡    │
└──────┬──────┘    └──────┬──────┘    └──────┬──────┘
       │                  │                  │
       └──────────────────┼──────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────┐
│            Nginx + Sticky Session               │
│       (WebSocket 需要会话保持)                   │
├───────────────────────────────────────────────┤
│                                                │
│   ┌───────────┐   ┌───────────┐   ┌───────────┐  │
│   │ Spring    │   │ Spring    │   │ Spring    │  │
│   │ App 1     │   │ App 2     │   │ App 3     │  │
│   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘  │
│         │               │               │         │
│         └───────────────┼───────────────┘         │
│                         │                         │
│   ┌─────────────────────▼─────────────────────┐   │
│   │          RabbitMQ (STOMP Relay)           │   │
│   │         统一消息路由 & 广播                 │   │
│   └───────────────────────────────────────────┘   │
└───────────────────────────────────────────────┘
```

**Nginx 配置：**

```nginx
upstream websocket_cluster {
    # 黏性会话（基于 IP hash）
    ip_hash;
    
    server app1.example.com:8080;
    server app2.example.com:8080;
    server app3.example.com:8080;
}

server {
    listen 443 ssl;
    server_name chat.example.com;
    
    location /ws {
        proxy_pass http://websocket_cluster;
        proxy_http_version 1.1;
        
        # WebSocket 必要配置
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时配置（必须大于心跳间隔）
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        
        # 其他 proxy 头
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # 缓冲关闭（WebSocket 不需要缓冲）
        proxy_buffering off;
    }
}
```

### 13.3 监控与排错

```java
@Component
public class WebSocketMonitor {

    private final AtomicInteger activeConnections = new AtomicInteger(0);
    private final AtomicLong totalMessages = new AtomicLong(0);
    private final ConcurrentHashMap<String, Long> sessionCreateTime = new ConcurrentHashMap<>();

    @EventListener
    public void handleSessionConnected(SessionConnectedEvent event) {
        StompHeaderAccessor accessor = StompHeaderAccessor.wrap(event.getMessage());
        String sessionId = accessor.getSessionId();
        
        activeConnections.incrementAndGet();
        sessionCreateTime.put(sessionId, System.currentTimeMillis());
        
        log.info("WebSocket 连接建立 [{}]，当前连接数：{}", 
            sessionId, activeConnections.get());
    }

    @EventListener
    public void handleSessionDisconnected(SessionDisconnectEvent event) {
        StompHeaderAccessor accessor = StompHeaderAccessor.wrap(event.getMessage());
        String sessionId = accessor.getSessionId();
        
        activeConnections.decrementAndGet();
        sessionCreateTime.remove(sessionId);
        
        log.info("WebSocket 连接断开 [{}]，当前连接数：{}", 
            sessionId, activeConnections.get());
    }

    @EventListener
    public void handleMessage(MessageEvent event) {
        totalMessages.incrementAndGet();
    }

    @Scheduled(fixedRate = 60000)
    public void reportMetrics() {
        Metrics.gauge("websocket.connections", activeConnections);
        Metrics.counter("websocket.messages.total", totalMessages.get());
        
        log.info("WebSocket 指标: 连接数={}, 总消息数={}, 平均连接时长={}s",
            activeConnections.get(),
            totalMessages.get(),
            sessionCreateTime.values().stream()
                .mapToLong(create -> System.currentTimeMillis() - create)
                .average()
                .orElse(0) / 1000
        );
    }
}
```

## 十四、总结

WebSocket + STOMP 是构建实时应用的最佳实践组合：

**Spring WebSocket 提供的核心能力：**
- 基于注解的编程模型（@MessageMapping、@SendTo）
- 完整的消息认证和授权框架
- 与 Spring Security 无缝集成
- 灵活的消息代理选择（简单代理或外部代理）
- 强大的 SimpMessagingTemplate 编程式发送

**适用场景：**
- 即时通讯系统
- 实时通知推送
- 监控数据看板
- 在线协作编辑
- 游戏服务器
- 物联网数据推送

**生产环境建议：**
1. 使用外部消息代理（RabbitMQ）实现集群
2. 配置 Nginx + Sticky Session 做负载均衡
3. 实现完善的断线重连和心跳机制
4. 做好连接数监控和资源隔离
5. 实现消息积压降级策略

掌握 WebSocket + STOMP 技术，让你轻松应对各种实时通信需求，构建高质量的响应式应用！
