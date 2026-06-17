---
title: WebSocket 与实时推送架构实战：从原理到生产
date: 2026-06-17 12:00:00
tags:
  - WebSocket
  - 实时推送
  - SSE
  - 后端架构
categories:
  - 后端技术
author: 东哥
---

# WebSocket 与实时推送架构实战：从原理到生产

## 一、实时推送技术的选型

在构建即时通讯、实时通知、行情推送等场景时，选择合适的推送技术至关重要。主流的方案有四种：

| 技术 | 方向 | 连接类型 | 延迟 | 浏览器支持 | 适用场景 |
|------|------|---------|------|-----------|---------|
| 轮询 (Polling) | 单向 | HTTP 短连接 | 高 | 所有 | 已过时 |
| SSE (Server-Sent Events) | 服务端→客户端 | HTTP 长连接 | 中 | 主流 | 单向推送 |
| WebSocket | 双向 | TCP 长连接 | 低 | 主流 | 交互式推送 |
| gRPC Stream | 双向 | HTTP/2 | 极低 | 需代理 | 服务间推送 |

### 1.1 WebSocket vs SSE

```
WebSocket:
  Client ───────────────────────────► Server
    ◄────────────────────────────────
        双向、全双工、任意时刻互发

SSE:
  Client ──────────► Server
    ◄────────────────
        单向、只能 Server 推 Client
        自动重连（EventSource 内置）
```

| 特性 | WebSocket | SSE |
|------|-----------|-----|
| 通信方向 | 全双工 | 服务端→客户端 |
| 协议 | ws:// / wss:// | HTTP（标准协议） |
| 自动重连 | 需手动实现 | 内置（EventSource） |
| 二进制数据 | 支持 | 仅文本（可通过 Base64） |
| 最大并发连接 | 受限于服务器 | 浏览器限制（HTTP/1.1 6个） |
| 实现复杂度 | 中 | 低 |

## 二、WebSocket 协议原理

### 2.1 握手过程

WebSocket 的握手基于 HTTP 协议，先通过 HTTP Upgrade 机制升级到 WebSocket 协议：

**客户端请求：**
```
GET /ws/notifications HTTP/1.1
Host: example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
Origin: https://example.com
```

**服务端响应：**
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

服务端 Sec-WebSocket-Accept 的计算：
```
Accept = Base64(SHA1(Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

### 2.2 数据帧结构

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌──────┬─────┬──────┬─────────┬──────────┬──────────────────────┐
│ FIN  │ RSV │ OpCode │ MASK  │ Payload  │ Extended             │
│      │     │(4bit)  │(1bit) │ Length    │ Payload Length       │
│      │     │        │       │ (7bit)    │ (16/64 bit)          │
├──────┴─────┴────────┴───────┴──────────┴──────────────────────┤
│                     Masking Key (4 bytes, if MASK=1)          │
├───────────────────────────────────────────────────────────────┤
│                    Payload Data                                │
└───────────────────────────────────────────────────────────────┘
```

| OpCode | 含义 | 说明 |
|--------|------|------|
| 0x0 | Continuation Frame | 延续帧（分片消息中间帧） |
| 0x1 | Text Frame | UTF-8 文本帧 |
| 0x2 | Binary Frame | 二进制帧 |
| 0x8 | Connection Close | 关闭连接 |
| 0x9 | Ping | 心跳 Ping |
| 0xA | Pong | 心跳 Pong |

## 三、Spring Boot 集成 WebSocket

### 3.1 原生 WebSocket (STOMP)

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-websocket</artifactId>
</dependency>
```

```java
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {
    
    @Override
    public void configureMessageBroker(MessageBrokerRegistry config) {
        // 服务端推送给客户端的地址前缀
        config.enableSimpleBroker("/topic", "/queue");
        // 客户端发送消息的地址前缀
        config.setApplicationDestinationPrefixes("/app");
        // 点对点前缀
        config.setUserDestinationPrefix("/user");
    }
    
    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        // 注册 STOMP 端点
        registry.addEndpoint("/ws")
            .setAllowedOriginPatterns("*")
            .withSockJS();  // 支持 SockJS 降级
    }
}
```

### 3.2 消息推送

```java
@Controller
public class WebSocketController {
    
    private final SimpMessagingTemplate messagingTemplate;
    
    @MessageMapping("/notification")
    @SendTo("/topic/notifications")
    public Notification broadcastNotification(Notification msg) {
        // 群发到所有订阅 /topic/notifications 的客户端
        return msg;
    }
    
    // 点对点推送
    public void sendToUser(Long userId, Notification notification) {
        messagingTemplate.convertAndSendToUser(
            userId.toString(), 
            "/queue/notifications", 
            notification
        );
    }
    
    // 推送到指定频道
    public void sendToChannel(String channel, Object payload) {
        messagingTemplate.convertAndSend("/topic/" + channel, payload);
    }
}
```

### 3.3 使用 @EventListener 监听连接事件

```java
@Component
public class WebSocketEventListener {
    
    @EventListener
    public void handleSessionConnected(SessionConnectedEvent event) {
        StompHeaderAccessor headers = StompHeaderAccessor.wrap(event.getMessage());
        String sessionId = headers.getSessionId();
        log.info("WebSocket 连接建立: sessionId={}", sessionId);
    }
    
    @EventListener
    public void handleSessionDisconnect(SessionDisconnectEvent event) {
        StompHeaderAccessor headers = StompHeaderAccessor.wrap(event.getMessage());
        String sessionId = headers.getSessionId();
        Long userId = (Long) headers.getSessionAttributes().get("userId");
        log.info("WebSocket 断开: sessionId={}, userId={}", sessionId, userId);
        
        // 清理用户连接映射
        UserConnectionManager.removeConnection(userId, sessionId);
    }
    
    @EventListener
    public void handleSubscribeEvent(SessionSubscribeEvent event) {
        StompHeaderAccessor headers = StompHeaderAccessor.wrap(event.getMessage());
        String destination = headers.getDestination();
        log.info("用户订阅: destination={}, sessionId={}", 
            destination, headers.getSessionId());
    }
}
```

### 3.4 连接认证

```java
@Component
public class AuthChannelInterceptor implements ChannelInterceptor {
    
    private final JwtTokenProvider jwtProvider;
    
    @Override
    public Message<?> preSend(Message<?> message, MessageChannel channel) {
        StompHeaderAccessor accessor = 
            MessageHeaderAccessor.getAccessor(message, StompHeaderAccessor.class);
        
        if (StompCommand.CONNECT.equals(accessor.getCommand())) {
            // 从请求头提取 token
            String token = accessor.getFirstNativeHeader("Authorization");
            if (token != null && token.startsWith("Bearer ")) {
                token = token.substring(7);
                try {
                    Long userId = jwtProvider.getUserIdFromToken(token);
                    accessor.setUser(new Principal() {
                        @Override
                        public String getName() {
                            return userId.toString();
                        }
                    });
                    log.info("WebSocket 认证成功: userId={}", userId);
                    return message;
                } catch (Exception e) {
                    log.warn("WebSocket 认证失败: {}", e.getMessage());
                }
            }
            throw new AuthenticationException("认证失败");
        }
        return message;
    }
}
```

## 四、高并发 WebSocket 架构

### 4.1 分布式 WebSocket 方案

单机 WebSocket 服务器有连接数上限（受限于文件句柄和内存）。在生产环境必须使用分布式架构：

```
                     ┌───────────────┐
                     │   Nginx/LB    │
                     │   (负载均衡)   │
                     └───────┬───────┘
                             │
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                 ▼
     ┌──────────┐     ┌──────────┐     ┌──────────┐
     │ WS-App-1 │     │ WS-App-2 │     │ WS-App-3 │
     │ (Node-1) │     │ (Node-2) │     │ (Node-3) │
     └────┬─────┘     └────┬─────┘     └────┬─────┘
          │                │                │
          └────────────────┼────────────────┘
                           │
                    ┌──────▼──────┐
                    │   Redis     │
                    │ Pub/Sub     │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   业务服务   │
                    └─────────────┘
```

### 4.2 基于 Redis Pub/Sub 的广播

```java
@Component
public class DistributedWebSocketManager {
    
    private final RedisTemplate<String, Object> redisTemplate;
    private final SimpMessagingTemplate messagingTemplate;
    
    // 本地连接的 Session 映射
    private final ConcurrentHashMap<Long, Set<String>> userSessions = 
        new ConcurrentHashMap<>();
    
    public DistributedWebSocketManager(
            RedisTemplate<String, Object> redisTemplate,
            SimpMessagingTemplate messagingTemplate) {
        this.redisTemplate = redisTemplate;
        this.messagingTemplate = messagingTemplate;
        initSubscriber();
    }
    
    private void initSubscriber() {
        // 订阅 Redis 频道
        redisTemplate.listenToPattern("ws:notification:*", (message) -> {
            String channel = new String(message.getChannel());
            String payload = new String(message.getBody());
            
            // 反序列化消息
            WsMessage wsMsg = JSON.parseObject(payload, WsMessage.class);
            
            // 推送给本地连接的客户端
            Set<String> sessions = userSessions.get(wsMsg.getUserId());
            if (sessions != null) {
                sessions.forEach(sessionId -> {
                    messagingTemplate.convertAndSendToUser(
                        wsMsg.getUserId().toString(),
                        "/queue/notifications",
                        wsMsg.getData()
                    );
                });
            }
        });
    }
    
    // 发送消息（无论目标用户在哪个节点）
    public void sendToUser(Long userId, Object data) {
        // 先检查本地是否有该用户的连接
        if (userSessions.containsKey(userId)) {
            messagingTemplate.convertAndSendToUser(
                userId.toString(), "/queue/notifications", data);
        }
        
        // 广播到 Redis，让其他节点检查
        WsMessage msg = new WsMessage(userId, data);
        redisTemplate.convertAndSend("ws:notification:" + userId, 
            JSON.toJSONString(msg));
    }
}
```

### 4.3 Nginx 代理配置

```nginx
upstream ws_backend {
    hash $remote_addr consistent;  # IP Hash 实现会话粘性
    server 192.168.1.10:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.11:8080 max_fails=3 fail_timeout=30s;
    server 192.168.1.12:8080 max_fails=3 fail_timeout=30s;
}

server {
    listen 443 ssl;
    server_name api.example.com;
    
    # HTTP API
    location /api/ {
        proxy_pass http://api_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    # WebSocket 端点
    location /ws {
        proxy_pass http://ws_backend;
        proxy_http_version 1.1;
        
        # WebSocket 关键配置
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        
        # 长连接超时
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        
        # 缓冲区
        proxy_buffering off;
        
        # 客户端最大数据量
        client_max_body_size 4k;
        client_body_buffer_size 128k;
    }
}
```

## 五、心跳与重连

### 5.1 服务端心跳

```java
@Configuration
public class WebSocketHeartbeatConfig {
    
    @Bean
    public TaskScheduler heartBeatScheduler() {
        return new ConcurrentTaskScheduler();
    }
    
    // 每 10 秒发送一次心跳
    @Scheduled(fixedRate = 10000)
    public void sendHeartbeat() {
        // 使用 dedicated heartbeat
    }
}

// 配置心跳
@Configuration
@EnableWebSocketMessageBroker
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {
    
    @Override
    public void configureWebSocketTransport(
            WebSocketTransportRegistration registration) {
        registration
            .setSendTimeLimit(15 * 1000)       // 发送超时
            .setSendBufferSizeLimit(512 * 1024) // 发送缓冲区
            .setMessageSizeLimit(128 * 1024);   // 消息大小限制
    }
}
```

### 5.2 客户端重连策略

```javascript
// 前端 WebSocket 重连
class ReconnectingWebSocket {
    constructor(url, options = {}) {
        this.url = url;
        this.maxReconnectAttempts = options.maxAttempts || 10;
        this.reconnectInterval = options.interval || 1000;
        this.maxInterval = options.maxInterval || 30000;
        this.attempts = 0;
        this.connect();
    }
    
    connect() {
        this.ws = new WebSocket(this.url);
        
        this.ws.onopen = () => {
            this.attempts = 0;
            console.log('WebSocket 已连接');
        };
        
        this.ws.onclose = (event) => {
            if (event.code !== 1000) {  // 非正常关闭
                this.reconnect();
            }
        };
        
        this.ws.onerror = (error) => {
            console.error('WebSocket 错误:', error);
        };
    }
    
    reconnect() {
        if (this.attempts >= this.maxReconnectAttempts) {
            console.error('重连次数已达上限');
            return;
        }
        
        const delay = Math.min(
            this.reconnectInterval * Math.pow(2, this.attempts),
            this.maxInterval
        );
        
        console.log(`将在 ${delay}ms 后重连 (第${this.attempts + 1}次)`);
        
        setTimeout(() => {
            this.attempts++;
            this.connect();
        }, delay);
    }
    
    send(data) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            this.ws.send(data);
        }
    }
}
```

## 六、生产注意事项

### 6.1 连接数规划

| 资源 | 单机容量 | 8核16G预估 | 建议预留 |
|------|---------|-----------|---------|
| 最大连接数 | 65,535 (端口限制) | 50,000 | 30,000 |
| 内存消耗 | 20-50 KB/连接 | ~1.5 GB | 50% |
| 文件句柄 | 受 ulimit 限制 | ≤ 100,000 | 开到 100k |

### 6.2 系统调优

```bash
# /etc/sysctl.conf
# 最大文件句柄
fs.file-max = 200000

# TCP 调优
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# WebSocket 连接数
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
```

WebSocket 是现代 Web 应用中实现实时通信的事实标准。从简单的在线状态提示，到复杂的即时通讯和行情推送系统，掌握 WebSocket 的架构设计和生产部署，是后端工程师从"增删改查"走向"高并发实时系统"的重要一步。
