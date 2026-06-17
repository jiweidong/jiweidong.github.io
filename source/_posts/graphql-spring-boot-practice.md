---
title: GraphQL 入门与 Spring GraphQL 实战：从 REST 到 GraphQL
date: 2026-06-17 08:20:00
tags:
  - GraphQL
  - Spring GraphQL
  - API设计
  - Spring Boot
categories:
  - 架构设计
author: 东哥
---

# GraphQL 入门与 Spring GraphQL 实战：从 REST 到 GraphQL

## 一、为什么需要 GraphQL

### 1.1 RESTful API 的痛点

假设我们要开发一个博客应用的 API，需要展示文章列表及其作者信息。

**RESTful 方案面临的困境：**

| 问题 | 表现 | 影响 |
|------|------|------|
| 过度获取（Over-fetching） | /posts 返回所有字段，但前端只需要 title 和 date | 浪费带宽 |
| 获取不足（Under-fetching） | /posts 不包含作者信息，需要额外请求 /users/:id | 多次请求 |
| 版本管理 | 需要 /api/v1/posts, /api/v2/posts | API 臃肿 |
| 前端耦合 | 不同页面需要不同数据，需要后端提供多个端点 | 沟通成本高 |

```bash
# RESTful 方案需要多个请求
GET /posts              → 文章列表（返回过多字段）
GET /posts/1/author     → 作者信息
GET /posts/1/comments   → 评论列表
# 总共 3 次 HTTP 请求，每次都有冗余数据
```

**GraphQL 方案：一个请求搞定**

```graphql
# 一次请求，精确获取所需数据
query {
  posts {
    title
    date
    author {
      name
      avatar
    }
    comments(limit: 5) {
      content
      createdAt
    }
  }
}
```

### 1.2 GraphQL vs REST 对比

| 特性 | REST | GraphQL |
|------|------|---------|
| 数据获取 | 服务端决定返回结构 | 客户端决定返回结构 |
| 请求次数 | 多个端点，可能多次请求 | 单端点，一次请求 |
| 版本管理 | URI 版本号（/v1/） | 无需版本号，通过 Schema 演进 |
| 缓存 | HTTP 缓存天然支持 | 需要额外实现 |
| 学习曲线 | 低 | 中高 |
| 文件上传 | 简单（multipart） | 需要特殊处理 |
| 查询性能 | 可控（服务端决定） | 需要防深度查询攻击 |
| 工具生态 | Postman / Swagger | GraphiQL / Apollo DevTools |

## 二、GraphQL 核心概念

### 2.1 Schema 定义语言（SDL）

```graphql
# 类型定义
type User {
  id: ID!
  name: String!
  email: String!       # ! 表示非空
  avatar: String       # 可选字段
  posts: [Post!]!      # 关联关系
  createdAt: DateTime
}

type Post {
  id: ID!
  title: String!
  content: String
  published: Boolean!
  author: User!
  comments: [Comment!]!
  tags: [String!]!
}

type Comment {
  id: ID!
  content: String!
  author: User!
  createdAt: DateTime!
}

# 查询入口
type Query {
  post(id: ID!): Post
  posts(page: Int, size: Int, tag: String): [Post!]!
  searchPosts(keyword: String!): [Post!]!
}

# 变更入口
type Mutation {
  createPost(input: CreatePostInput!): Post!
  updatePost(id: ID!, input: UpdatePostInput!): Post!
  deletePost(id: ID!): Boolean!
}

# 订阅入口（实时推送）
type Subscription {
  postCreated: Post!
  commentAdded(postId: ID!): Comment!
}

# 输入类型
input CreatePostInput {
  title: String!
  content: String!
  tags: [String!]
}
```

### 2.2 查询操作详解

```graphql
# 基本查询
query GetPost {
  post(id: "1") {
    title
    content
    published
  }
}

# 带参数的查询
query GetPosts($page: Int, $tag: String) {
  posts(page: $page, tag: $tag) {
    id
    title
    published
  }
}

# 别名 — 同时查询多个资源
query {
  recentPosts: posts(page: 1, size: 5) {
    title
    date
  }
  popularPosts: posts(page: 1, size: 3) {
    title
    viewCount
  }
}

# 片段 — 复用字段组合
fragment PostFields on Post {
  id
  title
  createdAt
}

query GetPostsWithFragment {
  recent: posts(page: 1, size: 5) {
    ...PostFields
    author { name }
  }
  featured: post(id: "featured") {
    ...PostFields
    content
  }
}
```

## 三、Spring GraphQL 实战

### 3.1 项目搭建

```xml
<!-- pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-graphql</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
```

### 3.2 Schema 定义

创建 `src/main/resources/graphql/schema.graphqls`：

```graphql
type Query {
    posts(page: Int = 1, size: Int = 10): PostConnection!
    post(id: ID!): Post
    postsByTag(tag: String!): [Post!]!
}

type Mutation {
    createPost(input: CreatePostInput!): Post!
    updatePost(id: ID!, input: UpdatePostInput!): Post!
    deletePost(id: ID!): Boolean!
}

type PostConnection {
    edges: [PostEdge!]!
    pageInfo: PageInfo!
    totalCount: Int!
}

type PostEdge {
    node: Post!
    cursor: String!
}

type PageInfo {
    hasNextPage: Boolean!
    hasPreviousPage: Boolean!
    startCursor: String
    endCursor: String
}

type Post {
    id: ID!
    title: String!
    content: String!
    excerpt: String
    published: Boolean!
    author: User!
    comments: [Comment!]!
    tags: [String!]!
    createdAt: DateTime!
    updatedAt: DateTime!
}

type User {
    id: ID!
    name: String!
    email: String!
    avatar: String
}

type Comment {
    id: ID!
    content: String!
    author: User!
    createdAt: DateTime!
}

input CreatePostInput {
    title: String!
    content: String!
    tags: [String!]
}

input UpdatePostInput {
    title: String
    content: String
    published: Boolean
    tags: [String!]
}
```

### 3.3 DataFetcher 实现

```java
@Component
public class PostController implements GraphQlResolver {

    private final PostService postService;
    private final UserService userService;

    // 查询文章列表
    @QueryMapping
    public PostConnection posts(@Argument int page, @Argument int size) {
        Page<Post> postPage = postService.findAll(page, size);
        List<PostEdge> edges = postPage.getContent().stream()
            .map(post -> new PostEdge(post, Base64.encode(post.getId())))
            .toList();
        return new PostConnection(
            edges,
            new PageInfo(
                postPage.hasNext(),
                postPage.hasPrevious(),
                edges.isEmpty() ? null : edges.get(0).cursor(),
                edges.isEmpty() ? null : edges.get(edges.size() - 1).cursor()
            ),
            (int) postPage.getTotalElements()
        );
    }

    // 查询单篇文章
    @QueryMapping
    public Post post(@Argument String id) {
        return postService.findById(id)
            .orElseThrow(() -> new PostNotFoundException(id));
    }

    // 创建文章
    @MutationMapping
    public Post createPost(@Argument CreatePostInput input) {
        return postService.create(input);
    }

    // 批量加载作者（解决 N+1 问题）
    @BatchMapping
    public Map<Post, User> author(List<Post> posts) {
        Set<String> userIds = posts.stream()
            .map(Post::getAuthorId)
            .collect(Collectors.toSet());
        Map<String, User> users = userService.findByIds(userIds).stream()
            .collect(Collectors.toMap(User::getId, Function.identity()));
        return posts.stream()
            .collect(Collectors.toMap(Function.identity(), p -> users.get(p.getAuthorId())));
    }
}
```

### 3.4 异常处理

```java
@ControllerAdvice
public class GraphQLExceptionHandler {

    @ExceptionHandler(PostNotFoundException.class)
    public GraphQLError handlePostNotFound(PostNotFoundException ex) {
        return GraphQLError.newError()
            .message(ex.getMessage())
            .errorType(ErrorType.NOT_FOUND)
            .extensions(Map.of(
                "code", "POST_NOT_FOUND",
                "postId", ex.getPostId()
            ))
            .build();
    }

    @ExceptionHandler(ConstraintViolationException.class)
    public GraphQLError handleValidation(ConstraintViolationException ex) {
        return GraphQLError.newError()
            .message("输入参数校验失败")
            .errorType(ErrorType.BAD_REQUEST)
            .extensions(Map.of(
                "code", "VALIDATION_ERROR",
                "violations", ex.getConstraintViolations().stream()
                    .map(v -> v.getPropertyPath() + ": " + v.getMessage())
                    .toList()
            ))
            .build();
    }
}
```

### 3.5 安全控制

```java
@Component
public class GraphQLSecurityFilter implements WebGraphQlInterceptor {

    @Override
    public Mono<WebGraphQlResponse> intercept(WebGraphQlRequest request, Chain chain) {
        // 检查认证
        String token = request.getHeaders().getFirst("Authorization");
        if (token == null || !token.startsWith("Bearer ")) {
            return Mono.just(response(request, "未登录"));
        }

        // 区分查询和变更操作
        String operationName = request.getDocument();
        if (operationName.contains("mutation")) {
            // 变更操作需要更高权限
            if (!hasWritePermission(token)) {
                return Mono.just(response(request, "无写入权限"));
            }
        }

        return chain.next(request);
    }

    private WebGraphQlResponse response(WebGraphQlRequest request, String message) {
        return WebGraphQlResponse.builder(request)
            .data(Map.of())
            .errors(List.of(
                GraphQLError.newError()
                    .message(message)
                    .errorType(ErrorType.UNAUTHORIZED)
                    .build()
            ))
            .build();
    }
}
```

## 四、性能优化

### 4.1 解决 N+1 查询问题

```java
// ❌ 问题：每个 Post 单独查询 author，产生 N+1 次查询
@SchemaMapping
public User author(Post post) {
    return userService.findById(post.getAuthorId()); // 每次请求查一次
}

// ✅ 使用 DataLoader 批量加载
@Component
public class UserDataLoader implements BatchLoader<String, User> {

    private final UserService userService;

    @Override
    public CompletableFuture<List<User>> load(List<String> keys) {
        return CompletableFuture.supplyAsync(() ->
            userService.findByIds(keys));
    }
}

@Configuration
public class DataLoaderConfig implements GraphQlSourceBuilderCustomizer {

    @Override
    public void customize(GraphQlSource.SchemaResourceBuilder builder) {
        builder.dataLoader("user", new UserDataLoader());
    }
}
```

### 4.2 查询深度限制

```yaml
# application.yml
spring:
  graphql:
    schema:
      locations: classpath:graphql/
    graphiql:
      enabled: true
    # 限制查询深度
    graphql:
      query-complexity:
        enabled: true
        max-complexity: 100
```

```java
// 自定义深度限制
@Component
public class QueryDepthLimitInterceptor implements GraphQlSourceBuilderCustomizer {

    @Override
    public void customize(GraphQlSource.SchemaResourceBuilder builder) {
        builder.instrumentation(new QueryDepthInstrumentation(10)); // 最大深度 10
    }
}
```

### 4.3 持久化查询（Persisted Queries）

```java
// 服务端定义允许的查询（类似白名单）
@Component
public class PersistedQueryRegistry implements RuntimeWiringConfigurer {

    private static final Map<String, String> PERSISTED_QUERIES = Map.of(
        "getPost", "query getPost($id: ID!) { post(id: $id) { id title content author { name } } }",
        "getPosts", "query getPosts { posts { id title } }"
    );

    @Override
    public void configure(RuntimeWiring.Builder builder) {
        builder.type("Query", typeWiring -> typeWiring
            .dataFetcher("__persistedQuery", env -> {
                String queryId = env.getArgument("id");
                return PERSISTED_QUERIES.get(queryId);
            })
        );
    }
}
```

## 五、从 REST 迁移到 GraphQL

### 5.1 渐进式迁移策略

```
阶段 1：共存
Client ──→ /api/rest/users    (旧 API)
        ──→ /graphql            (新 GraphQL API)

阶段 2：新功能走 GraphQL
新功能全部使用 GraphQL，REST 仅维护存量

阶段 3：全面切换
所有流量切换到 GraphQL，REST 下线
```

### 5.2 REST 与 GraphQL 双模式

```java
@RestController
@RequestMapping("/api")
public class HybridController {

    private final GraphQlService graphQlService;

    // 兼容旧 REST 客户端
    @GetMapping("/posts")
    public List<Post> getPosts(@RequestParam int page, @RequestParam int size) {
        // 内部调用 GraphQL
        String query = """
            query($page: Int, $size: Int) {
                posts(page: $page, size: $size) {
                    id title content author { name } createdAt
                }
            }
            """;
        ExecutionResult result = graphQlService.execute(query, Map.of("page", page, "size", size));
        return ((PostConnection) result.getData()).getEdges().stream()
            .map(PostEdge::getNode)
            .toList();
    }
}
```

## 六、生产环境最佳实践

### 6.1 监控与日志

```java
@Component
public class GraphQLMetricsInstrumentation extends SimpleInstrumentation {
    private final MeterRegistry meterRegistry;

    @Override
    public InstrumentationState createState() {
        return new InstrumentationState() {};
    }

    @Override
    public CompletableFuture<InstrumentationExecutionResult> instrumentExecution(
        ExecutionInput executionInput,
        InstrumentationExecutionParameters parameters,
        InstrumentationState state,
        CompletableFuture<InstrumentationExecutionResult> result) {

        String operation = executionInput.getOperationName() != null
            ? executionInput.getOperationName()
            : "anonymous";

        long start = System.currentTimeMillis();
        return result.thenApply(r -> {
            long duration = System.currentTimeMillis() - start;
            meterRegistry.timer("graphql.execution", "operation", operation)
                .record(Duration.ofMillis(duration));
            return r;
        });
    }
}
```

### 6.2 缓存策略

```java
@Configuration
public class GraphQLCacheConfig {

    // 对查询结果做缓存
    @Bean
    public CachingGraphQlService cachingGraphQlService(
            GraphQlService delegate, CacheManager cacheManager) {
        return new CachingGraphQlService(delegate, cacheManager) {
            @Override
            protected boolean shouldCache(ExecutionInput input) {
                // 只对查询（query）做缓存，不对变更（mutation）做缓存
                return !input.getDocument().startsWith("mutation");
            }
        };
    }
}
```

### 6.3 安全建议

- 始终启用查询深度限制，防止恶意查询
- 使用持久化查询（白名单）模式
- 对文件上传使用专门的 GraphQL Multpart Request
- 敏感字段添加 `@deprecated` 或使用权限注解
- 使用 Rate Limiting 防止 API 滥用

GraphQL 为 API 开发带来了全新的思路——让客户端精确获取所需数据。配合 Spring GraphQL，能在 Spring Boot 生态中快速构建高性能的 GraphQL API。但要注意，GraphQL 不是 REST 的替代品，而是特定场景下的更好的选择。如果 API 简单且缓存是强需求，REST 仍然是好选择。
