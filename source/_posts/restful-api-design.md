---
title: RESTful API 设计规范与最佳实践
date: 2026-06-15 11:00:00
tags:
  - RESTful
  - API设计
  - 架构
  - HTTP
categories:
  - 架构
author: 东哥
---

# RESTful API 设计规范与最佳实践

> 良好的 API 设计是后端系统的命脉。一个设计优秀的 API 能让调用者感到愉悦，反之则是一场噩梦。本文从真实项目经验出发，系统梳理 RESTful API 的设计规范和最佳实践。

## 一、REST 核心原则

### 1.1 什么是 REST

**REST**（Representational State Transfer，表述性状态转移）是一种架构风格，核心原则：

1. **资源导向**：一切皆资源，用 URL 表示
2. **无状态**：每个请求包含所有必要信息
3. **统一接口**：使用标准 HTTP 方法操作资源
4. **可缓存**：响应应标示是否可缓存

### 1.2 HTTP 方法的语义

| 方法 | 含义 | 幂等 | 安全 |
|------|------|------|------|
| GET | 获取资源 | ✓ | ✓ |
| POST | 创建资源 | ✗ | ✗ |
| PUT | 完整更新资源 | ✓ | ✗ |
| PATCH | 部分更新资源 | ✗ | ✗ |
| DELETE | 删除资源 | ✓ | ✗ |
| HEAD | 获取响应头 | ✓ | ✓ |
| OPTIONS | 获取支持的 HTTP 方法 | ✓ | ✓ |

## 二、URL 设计规范

### 2.1 命名规范

```bash
# ✅ 正确示例
GET    /users                    # 获取用户列表
GET    /users/123                # 获取单个用户
POST   /users                    # 创建用户
PUT    /users/123                # 更新用户（全量）
PATCH  /users/123                # 更新用户（部分）
DELETE /users/123                # 删除用户

# ✅ 关联资源（子资源）
GET    /users/123/orders         # 用户的订单列表
GET    /orders/456/items         # 订单的商品列表

# ✅ 资源操作
POST   /users/123/lock           # 锁定用户（动作）
POST   /orders/456/cancel        # 取消订单

# ❌ 错误示例
GET    /getUsers                 # 不应在 URL 中用动词
POST   /createUser
PUT    /updateUser
GET    /userList                 # 复数形式统一
GET    /users/get?id=123         # 不应把 ID 放 query
POST   /users/userInfo           # 资源路径冗余
```

### 2.2 版本管理

```bash
# 推荐：URL 路径版本号
/api/v1/users
/api/v2/users

# 或：请求头版本
Accept: application/vnd.example.v1+json

# 不推荐：Query 参数版本
/users?version=1    # 容易污染缓存
```

### 2.3 搜索与过滤

```bash
# 过滤
GET /users?role=admin&status=active
GET /users?age=gte:18
GET /products?category=electronics&brand=apple&price=500-2000

# 搜索
GET /users?q=keyword
GET /products?q=华为

# 排序
GET /users?sort=created_at:desc,name:asc
GET /users?sort=-created_at      # 减号表示降序

# 分页
GET /users?page=1&size=20
GET /users?offset=0&limit=20

# 字段选择
GET /users?fields=id,name,email
```

## 三、请求与响应设计

### 3.1 统一响应格式

```json
// 成功响应
{
    "code": 200,
    "message": "success",
    "data": {
        "id": 123,
        "name": "张三",
        "email": "zhangsan@example.com"
    },
    "timestamp": "2026-06-15T10:30:00+08:00"
}

// 分页响应
{
    "code": 200,
    "message": "success",
    "data": {
        "items": [...],
        "pagination": {
            "page": 1,
            "size": 20,
            "total": 156,
            "totalPages": 8,
            "hasMore": true
        }
    },
    "timestamp": "2026-06-15T10:30:00+08:00"
}

// 错误响应
{
    "code": 40010,
    "message": "参数校验失败",
    "data": null,
    "errors": [
        {
            "field": "email",
            "message": "邮箱格式不正确"
        },
        {
            "field": "age",
            "message": "年龄必须在 0-150 之间"
        }
    ],
    "traceId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "timestamp": "2026-06-15T10:30:00+08:00"
}
```

### 3.2 HTTP 状态码使用

```java
// 2xx 成功
200 OK                    // GET 成功
201 Created               // POST 创建成功
204 No Content            // DELETE 成功（无响应体）

// 3xx 重定向
301 Moved Permanently     // 永久重定向
302 Found                 // 临时重定向
304 Not Modified          // 使用缓存

// 4xx 客户端错误
400 Bad Request           // 请求参数错误
401 Unauthorized          // 未认证（需要登录）
403 Forbidden             // 无权限
404 Not Found             // 资源不存在
405 Method Not Allowed    // HTTP 方法不支持
409 Conflict              // 资源冲突（重复创建）
422 Unprocessable Entity  // 语义错误
429 Too Many Requests     // 请求频率限制

// 5xx 服务端错误
500 Internal Server Error // 服务器内部错误
502 Bad Gateway           // 网关错误
503 Service Unavailable   // 服务不可用
504 Gateway Timeout       // 网关超时
```

## 四、安全设计

### 4.1 认证与授权

```bash
# 推荐：JWT Token 认证
Authorization: Bearer eyJhbGciOiJIUzI1NiIs...

# 不推荐：Cookie Session（不适合 API）
# 基本认证（仅适用于开发环境）
Authorization: Basic base64(username:password)
```

### 4.2 API Key 管理

```bash
# 方式一：请求头
X-API-Key: your-api-key

# 方式二：Query 参数（不推荐，日志会暴露）
/users?api_key=your-api-key
```

### 4.3 安全最佳实践

```yaml
# HTTPS 强制
强制全站 HTTPS，不要给 HTTP 留后门

# 速率限制（Rate Limiting）
X-RateLimit-Limit: 100           # 每小时限额
X-RateLimit-Remaining: 95        # 剩余次数
X-RateLimit-Reset: 1623744000    # 重置时间

# 敏感信息保护
- 响应中不返回密码、Token
- 手机号、身份证脱敏：138****8000
- 日志中不记录敏感字段
- 使用 IDS 而非自增 ID 暴露资源

# 防注入
- 所有输入做参数校验
- 使用参数化查询防止 SQL 注入
- 限制输入长度和格式
```

## 五、文档化

### 5.1 OpenAPI 规范（原 Swagger）

```yaml
openapi: 3.0.0
info:
  title: 用户管理 API
  version: 1.0.0
paths:
  /users:
    get:
      summary: 获取用户列表
      parameters:
        - name: page
          in: query
          schema: { type: integer, default: 1 }
        - name: size
          in: query
          schema: { type: integer, default: 20 }
      responses:
        '200':
          description: 成功
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/UserList'
    post:
      summary: 创建用户
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
      responses:
        '201':
          description: 创建成功
```

### 5.2 文档最佳实践

```
每个 API 需要说明：
1. 功能描述
2. HTTP 方法和 URL
3. 请求参数（路径、Query、Header、Body）
4. 请求示例
5. 成功响应示例
6. 错误响应示例
7. 频率限制
8. 变更日志
```

## 六、异常处理策略

### 6.1 全局异常处理器（Spring Boot）

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiResponse> handleValidation(
            MethodArgumentNotValidException ex) {
        List<FieldError> errors = ex.getBindingResult()
            .getFieldErrors().stream()
            .map(e -> new FieldError(e.getField(), e.getDefaultMessage()))
            .collect(Collectors.toList());
        
        return ResponseEntity.badRequest()
            .body(ApiResponse.error(40010, "参数校验失败", errors));
    }

    @ExceptionHandler(BusinessException.class)
    public ResponseEntity<ApiResponse> handleBusiness(BusinessException ex) {
        return ResponseEntity.status(ex.getHttpStatus())
            .body(ApiResponse.error(ex.getCode(), ex.getMessage()));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiResponse> handleUnknown(Exception ex) {
        log.error("未知异常", ex);
        return ResponseEntity.status(500)
            .body(ApiResponse.error(50000, "服务器内部错误"));
    }
}
```

### 6.2 日志记录

```java
// 使用 AOP 统一记录 API 日志
@Aspect
@Component
public class ApiLogAspect {
    
    @Around("@annotation(org.springframework.web.bind.annotation.RequestMapping)")
    public Object logAround(ProceedingJoinPoint joinPoint) throws Throwable {
        long start = System.currentTimeMillis();
        String method = joinPoint.getSignature().toShortString();
        
        try {
            Object result = joinPoint.proceed();
            long elapsed = System.currentTimeMillis() - start;
            log.info("[API] {} 成功, 耗时: {}ms", method, elapsed);
            return result;
        } catch (Exception e) {
            long elapsed = System.currentTimeMillis() - start;
            log.error("[API] {} 失败, 耗时: {}ms, 异常: {}", 
                method, elapsed, e.getMessage());
            throw e;
        }
    }
}
```

## 七、版本演进策略

### 7.1 向后兼容

```
1. 不要删除已有字段（标记为 deprecated 替代）
2. 新增字段使用可选（nullable）
3. 不改变已有字段的类型和语义
4. 不缩小响应数据范围
5. 提供兼容期（同时支持两个版本）

示例：
{
    "name": "张三",
    "phone": "13800138000",        // 旧字段，保留
    "phoneNumber": "13800138000",  // 新命名字段
    "_deprecated": ["phone"]       // 标记弃用
}
```

### 7.2 废弃策略

```yaml
弃用流程：
1. 文档标注 deprecated
2. 响应头添加 Sunset 字段
3. 保留至少 6 个月
4. 迁移完成后下线

响应头示例：
Sunset: Sat, 15 Dec 2026 00:00:00 GMT
Deprecation: true
```

## 八、性能优化

### 8.1 缓存策略

```bash
# 强制缓存
Cache-Control: max-age=3600, private

# 协商缓存
ETag: "33a64df551425fcc55e4d42a148795d9f25f89d4"
Last-Modified: Mon, 15 Jun 2026 08:00:00 GMT

# 条件请求
GET /users/123
If-None-Match: "33a64df551425fcc55e4d42a148795d9f25f89d4"
# 返回 304 Not Modified（无响应体）
```

### 8.2 批量操作

```bash
# 批量获取
GET /users?id=1,2,3,4,5

# 批量创建
POST /users/batch
{
    "items": [
        {"name": "张三", "email": "zs@example.com"},
        {"name": "李四", "email": "ls@example.com"}
    ]
}

# 异步操作（耗时操作）
POST /reports/export
{ "type": "monthly", "year": 2026, "month": 5 }

# 返回
HTTP 202 Accepted
Location: /tasks/abc123
```

## 九、总结

设计良好的 RESTful API 需要遵循规范和积累经验。核心要点：

1. **一致性**：命名、响应格式、错误处理保持统一
2. **简洁性**：URL 路径清晰，资源层次合理
3. **安全性**：HTTPS、认证、限流、防注入
4. **可发现性**：文档完善，错误信息友好
5. **性能**：合理使用缓存、分页、压缩

记住：**API 是一种比读代码更频繁的沟通方式。好的 API 设计是对调用者最大的善意。**
