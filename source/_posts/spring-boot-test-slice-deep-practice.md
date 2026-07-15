---
title: 【Spring Boot 实战】测试切片深度解析：@WebMvcTest / @DataJpaTest 源码与最佳实践
date: 2026-07-15 08:00:00
tags:
  - Spring Boot
  - 测试
  - JUnit
  - Mockito
categories:
  - Spring Boot
  - 测试
author: 东哥
---

# 【Spring Boot 实战】测试切片深度解析：@WebMvcTest / @DataJpaTest 源码与最佳实践

## 引言

在 Spring Boot 项目中写单元测试时，很多开发者会直接使用 `@SpringBootTest` 启动整个应用程序上下文。这样做的后果是：启动慢（加载所有 Bean）、依赖多（需要数据库、消息队列等外部组件）、测试不纯粹（一个测试失败可能是因为不相关的 Bean 出了问题）。

Spring Boot 提供了一套**测试切片（Test Slice）**注解，可以只加载测试所需的特定层级的 Bean，大大提升测试速度和专注度。

本文将从源码层面解析 Spring Boot 测试切片机制，并通过实战展示 `@WebMvcTest`、`@DataJpaTest`、`@JsonTest`、`@RestClientTest` 等注解的正确用法。

---

## 一、Spring Boot 测试切片机制原理

### 1.1 什么是测试切片？

测试切片是 Spring Boot 提供的一组注解，它们通过**限定自动配置的范围**，只加载测试所需的少数 Bean。核心思想：**只测你想测的，不用的别加载**。

| 测试切片注解 | 测试目标 | 自动配置范围 |
|---|---|---|
| `@WebMvcTest` | Controller 层 | Web MVC 相关 Bean |
| `@DataJpaTest` | Repository 层 | JPA 相关 Bean + 嵌入式数据库 |
| `@JsonTest` | JSON 序列化/反序列化 | Jackson/Gson 相关 Bean |
| `@RestClientTest` | REST 客户端 | RestTemplate/WebClient 相关 Bean |
| `@DataRedisTest` | Redis 操作 | Redis 相关 Bean |
| `@DataMongoTest` | MongoDB 操作 | MongoDB 相关 Bean |
| `@DataLdapTest` | LDAP 操作 | LDAP 相关 Bean |
| `@JdbcTest` | JDBC 操作 | JDBC 相关 Bean |
| `@DataJdbcTest` | Spring Data JDBC | JDBC Repository 相关 Bean |

### 1.2 源码分析：@WebMvcTest 是如何工作的？

先看 `@WebMvcTest` 的注解定义：

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@BootstrapWith(SpringBootTestContextBootstrapper.class)
@ExtendWith(SpringExtension.class)
@OverrideAutoConfiguration(enabled = false)          // 关键：关闭全量自动配置
@TypeExcludeFilters(WebMvcTypeExcludeFilter.class)   // 关键：类型排除过滤器
@AutoConfigureMockMvc                                 // 自动配置 MockMvc
@AutoConfigureCache                                   // 自动配置缓存
@AutoConfigureWebMvc                                  // 自动配置 Web MVC
@AutoConfigureMockRestServiceServer                   // 自动配置 Mock Rest Server
@ImportAutoConfiguration                              // 导入特定的自动配置
public @interface WebMvcTest {
    // 指定要测试的 Controller
    Class<?>[] value() default {};
    // 是否启用安全过滤
    boolean useDefaultFilters() default true;
    // 包含的过滤器
    Filter[] includeFilters() default {};
    // 排除的过滤器
    Filter[] excludeFilters() default {};
    // 排除的自动配置类
    @AliasFor("excludeAutoConfiguration")
    Class<?>[] excludeAutoConfiguration() default {};
}
```

关键机制解析：

1. **`@OverrideAutoConfiguration(enabled = false)`**：禁用默认的全部自动配置，改为只加载特定的自动配置
2. **`@TypeExcludeFilters(WebMvcTypeExcludeFilter.class)`**：自定义类型过滤器，**只保留** Controller 层相关的 Bean（`@Controller`、`@ControllerAdvice`、`WebMvcConfigurer` 等），其他如 `@Service`、`@Repository` 都会被排除
3. **`@AutoConfigureMockMvc`**：自动配置 `MockMvc`，用于模拟 HTTP 请求
4. **`@ImportAutoConfiguration`**：导入 Web MVC 所需的自动配置类

`WebMvcTypeExcludeFilter` 的核心逻辑：

```java
public class WebMvcTypeExcludeFilter extends StandardAnnotationCustomizableTypeExcludeFilter<WebMvcTest> {
    @Override
    protected Set<String> getComponentIncludes() {
        // 只包含这些类型的 Bean
        return Set.of(
            Controller.class.getName(),
            ControllerAdvice.class.getName(),
            JsonComponent.class.getName(),
            WebMvcConfigurer.class.getName(),
            // ...
        );
    }
}
```

### 1.3 源码分析：@DataJpaTest 的工作机制

```java
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Documented
@Inherited
@BootstrapWith(SpringBootTestContextBootstrapper.class)
@ExtendWith(SpringExtension.class)
@OverrideAutoConfiguration(enabled = false)
@TypeExcludeFilters(DataJpaTypeExcludeFilter.class)
@Transactional                                       // 每个测试方法自动回滚
@AutoConfigureCache
@AutoConfigureDataJpa                                // 配置 JPA 相关
@AutoConfigureTestDatabase                           // 配置嵌入式数据库
@AutoConfigureTestEntityManager                      // 配置 EntityManager
@ImportAutoConfiguration
public @interface DataJpaTest {
    // 是否在测试后自动回滚事务
    @AliasFor(annotation = Transactional.class, attribute = "propagation")
    Propagation propagation() default Propagation.REQUIRED;
    // 是否启用 SQL 输出
    boolean showSql() default true;
    // ...
}
```

`@DataJpaTest` 的关键特性：
- **`@Transactional`**：默认每个测试方法结束后自动回滚，不影响数据库数据
- **`@AutoConfigureTestDatabase`**：自动替换为嵌入式数据库（H2），无需真实数据库
- **只加载** `@Repository`、JPA 相关 Bean，不加载 `@Service` 和 `@Controller`

---

## 二、@WebMvcTest 实战：Controller 层测试

### 2.1 基础使用

```java
@WebMvcTest(UserController.class)  // 只加载 UserController
class UserControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean   // 模拟 Service 层
    private UserService userService;

    @Test
    void shouldReturnUserList() throws Exception {
        // 准备数据
        when(userService.listUsers()).thenReturn(List.of(
            new User(1L, "张三", "zhangsan@example.com"),
            new User(2L, "李四", "lisi@example.com")
        ));

        // 执行请求并验证
        mockMvc.perform(get("/api/users")
                .accept(MediaType.APPLICATION_JSON))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.length()").value(2))
            .andExpect(jsonPath("$[0].name").value("张三"))
            .andExpect(jsonPath("$[1].email").value("lisi@example.com"));

        // 验证 Service 被调用
        verify(userService).listUsers();
    }
}
```

### 2.2 参数验证测试

```java
@WebMvcTest(UserController.class)
class UserControllerValidationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private UserService userService;

    @Test
    void shouldReturn400WhenEmailInvalid() throws Exception {
        String invalidRequest = """
            {"name": "test", "email": "not-an-email", "age": 150}
            """;

        mockMvc.perform(post("/api/users")
                .contentType(MediaType.APPLICATION_JSON)
                .content(invalidRequest))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.errors").isArray())
            .andExpect(jsonPath("$.errors[?(@.field == 'email')]").exists())
            .andExpect(jsonPath("$.errors[?(@.field == 'age')]").exists());
    }
}
```

### 2.3 异常场景测试

```java
@WebMvcTest(UserController.class)
class UserControllerExceptionTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private UserService userService;

    @Test
    void shouldReturn404WhenUserNotFound() throws Exception {
        when(userService.getUser(999L))
            .thenThrow(new UserNotFoundException("用户不存在"));

        mockMvc.perform(get("/api/users/999"))
            .andExpect(status().isNotFound())
            .andExpect(jsonPath("$.message").value("用户不存在"));
    }

    @Test
    void shouldReturn403WhenNoPermission() throws Exception {
        when(userService.deleteUser(1L))
            .thenThrow(new AccessDeniedException("无权限"));

        mockMvc.perform(delete("/api/users/1"))
            .andExpect(status().isForbidden());
    }
}
```

### 2.4 安全上下文注入

```java
@WebMvcTest(AdminController.class)
@AutoConfigureMockMvc(addFilters = false)  // 关闭安全过滤器，单独测试 Controller 逻辑
class AdminControllerTest {
    // ...
}

// 或者使用 @WithMockUser 模拟认证用户
@WebMvcTest(AdminController.class)
class AdminControllerSecurityTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private AdminService adminService;

    @Test
    @WithMockUser(roles = "ADMIN")  // 模拟 ADMIN 角色
    void adminCanAccessDashboard() throws Exception {
        mockMvc.perform(get("/admin/dashboard"))
            .andExpect(status().isOk());
    }

    @Test
    void anonymousUserCannotAccessDashboard() throws Exception {
        mockMvc.perform(get("/admin/dashboard"))
            .andExpect(status().isUnauthorized());
    }
}
```

### 2.5 文件上传测试

```java
@WebMvcTest(FileController.class)
class FileUploadTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private FileService fileService;

    @Test
    void shouldUploadFile() throws Exception {
        MockMultipartFile file = new MockMultipartFile(
            "file",
            "test.txt",
            "text/plain",
            "Hello, World!".getBytes()
        );

        when(fileService.upload(anyString(), any(MultipartFile.class)))
            .thenReturn("file-uuid-123");

        mockMvc.perform(multipart("/api/files/upload")
                .file(file)
                .header("X-Request-ID", "req-001"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.fileId").value("file-uuid-123"));
    }
}
```

---

## 三、@DataJpaTest 实战：Repository 层测试

### 3.1 基础 CRUD 测试

```java
@DataJpaTest
class UserRepositoryTest {

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private TestEntityManager entityManager;

    @Test
    void shouldSaveAndFindUser() {
        // 使用 EntityManager 预置数据
        User saved = entityManager.persistAndFlush(
            new User(null, "张三", "zhangsan@example.com", 25)
        );

        // 通过 Repository 查询
        Optional<User> found = userRepository.findById(saved.getId());

        assertThat(found).isPresent();
        assertThat(found.get().getName()).isEqualTo("张三");
    }

    @Test
    void shouldFindByEmail() {
        entityManager.persist(
            new User(null, "李四", "lisi@example.com", 30)
        );

        Optional<User> found = userRepository.findByEmail("lisi@example.com");

        assertThat(found).isPresent();
        assertThat(found.get().getName()).isEqualTo("李四");
    }
}
```

### 3.2 自定义查询测试

```java
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE) // 使用真实数据库
@ActiveProfiles("test")
class UserRepositoryCustomQueryTest {

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private TestEntityManager entityManager;

    @BeforeEach
    void setUp() {
        entityManager.persist(new User(null, "张三", "zhang@test.com", 25, "北京"));
        entityManager.persist(new User(null, "李四", "li@test.com", 30, "上海"));
        entityManager.persist(new User(null, "王五", "wang@test.com", 28, "北京"));
        entityManager.persist(new User(null, "赵六", "zhao@test.com", 35, "广州"));
        entityManager.flush();
    }

    @Test
    void shouldFindUsersByCity() {
        List<User> beijingUsers = userRepository.findByCity("北京");
        assertThat(beijingUsers).hasSize(2);
    }

    @Test
    void shouldFindUsersOlderThan() {
        List<User> users = userRepository.findUsersOlderThan(30);
        assertThat(users).hasSize(1)
            .extracting(User::getName)
            .containsExactly("赵六");
    }
}
```

### 3.3 事务与回滚行为测试

```java
@DataJpaTest
@Transactional  // 每个测试后自动回滚
class UserRepositoryTransactionTest {

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private TestEntityManager entityManager;

    @Test
    void shouldRollbackOnFailure() {
        // 第一条记录成功
        userRepository.save(new User(null, "张三", "z@test.com", 20));

        // 注意：因为 @DataJpaTest 自动回滚，
        // 这个测试中插入的数据不会影响其他测试
        assertThat(userRepository.count()).isEqualTo(1);
    }

    @Test
    void testDatabaseIsClean() {
        // 上一条测试插入的数据已回滚
        assertThat(userRepository.count()).isZero();
    }
}
```

---

## 四、其他测试切片实战

### 4.1 @JsonTest：JSON 序列化测试

```java
@JsonTest
class UserJsonTest {

    @Autowired
    private JacksonTester<User> json;

    @Test
    void shouldSerializeToJson() throws IOException {
        User user = new User(1L, "张三", "zhang@example.com", 25);

        // 序列化
        assertThat(json.write(user)).isStrictlyEqualToJson("user.json");
        assertThat(json.write(user)).hasJsonPathStringValue("$.name");
        assertThat(json.write(user)).extractingJsonPathStringValue("$.name")
            .isEqualTo("张三");
    }

    @Test
    void shouldDeserializeFromJson() throws IOException {
        String jsonContent = """
            {"id": 1, "name": "李四", "email": "li@example.com", "age": 30}
            """;

        User user = json.parseObject(jsonContent);

        assertThat(user.getName()).isEqualTo("李四");
        assertThat(user.getAge()).isEqualTo(30);
    }

    @Test
    void shouldHandleNullFields() throws IOException {
        User user = new User(null, null, null, 0);

        assertThat(json.write(user))
            .doesNotHaveJsonPath("$.id")
            .doesNotHaveJsonPath("$.name");
    }
}
```

### 4.2 @RestClientTest：REST 客户端测试

```java
@RestClientTest(UserServiceClient.class)  // 指定要测试的客户端
class UserServiceClientTest {

    @Autowired
    private MockRestServiceServer server;

    @Autowired
    private UserServiceClient client;

    @Test
    void shouldGetUser() {
        // 模拟远端服务响应
        server.expect(requestTo("/api/users/1"))
            .andExpect(method(HttpMethod.GET))
            .andRespond(withSuccess("""
                {"id": 1, "name": "张三", "email": "z@test.com"}
                """, MediaType.APPLICATION_JSON));

        // 执行客户端调用
        User user = client.getUser(1L);

        assertThat(user.getId()).isEqualTo(1L);
        assertThat(user.getName()).isEqualTo("张三");

        // 验证所有预期请求都已完成
        server.verify();
    }

    @Test
    void shouldHandleServerError() {
        server.expect(requestTo("/api/users/999"))
            .andRespond(withServerError());

        assertThatThrownBy(() -> client.getUser(999L))
            .isInstanceOf(HttpServerErrorException.class);
    }
}
```

---

## 五、测试切片选择与对比

### 5.1 启动速度对比

| 测试方式 | Bean 数量 | 启动时间 | 加载范围 |
|---|---|---|---|
| `@SpringBootTest` | 200-500+ | 15-60s | 全量 Bean |
| `@WebMvcTest` | 20-50 | 3-8s | Controller + Web 相关 |
| `@DataJpaTest` | 15-30 | 3-6s | Repository + JPA 相关 |
| `@JsonTest` | 5-10 | 2-4s | Jackson/Gson 相关 |

> 在大规模微服务项目中，启动时间差异可达数倍。合理使用测试切片，可以让整个测试套件的执行时间从 30 分钟降到 3 分钟。

### 5.2 常见误区

**误区一：所有测试都使用 @SpringBootTest**

```java
// ❌ 错误：测试 Controller 却加载了整个应用
@SpringBootTest
class UserControllerBadTest {
    @Autowired
    private UserController userController;  // 虽然也能工作，但太慢了
}

// ✅ 正确：精确加载
@WebMvcTest(UserController.class)
class UserControllerGoodTest {
    @Autowired
    private MockMvc mockMvc;
}
```

**误区二：忽略 TestEntityManager**

```java
@DataJpaTest
class UserRepositoryBadTest {
    @Autowired
    private UserRepository userRepository;

    @Test
    void testQuery() {
        // ❌ 直接在 Repository 上 save 来准备数据，破坏了测试意图
        userRepository.save(new User(null, "张三", "z@test.com", 25));
        // 实际上是在测试 Repository 本身 + 准备数据混在一起
    }
}

// ✅ 正确：使用 TestEntityManager 准备预置数据，测试更清晰
@DataJpaTest
class UserRepositoryGoodTest {
    @Autowired
    private UserRepository userRepository;

    @Autowired
    private TestEntityManager entityManager;

    @Test
    void testCustomQuery() {
        entityManager.persist(new User(null, "张三", "z@test.com", 25));
        entityManager.flush();

        List<User> result = userRepository.findByCity("北京");
        // 只测试 Repository 的查询逻辑
    }
}
```

---

## 六、面试常见追问

**Q1：@WebMvcTest 和 @SpringBootTest + @AutoConfigureMockMvc 有什么区别？**

A：`@WebMvcTest` 只加载 Web 层相关 Bean（Controller、ControllerAdvice、WebMvcConfigurer），不加载 Service 和 Repository，需要手动 `@MockBean` 模拟。而 `@SpringBootTest + @AutoConfigureMockMvc` 加载完整的应用上下文，适合端到端测试。前者更快更专注，后者更完整但更慢。

**Q2：测试切片如何处理跨层依赖（如 Spring Security）？**

A：测试切片提供了多种方式：
- 使用 `@WithMockUser` 模拟认证用户
- 在 `@WebMvcTest` 中添加 `@Import(SecurityConfig.class)` 导入安全配置
- 使用 `@AutoConfigureMockMvc(addFilters = false)` 跳过安全过滤器

**Q3：@DataJpaTest 如何连接真实数据库而非 H2？**

A：使用 `@AutoConfigureTestDatabase(replace = NONE)` 并使用 `@ActiveProfiles("test")` 加载真实的数据库配置。但需要注意，这会使测试变慢且依赖外部环境。

**Q4：测试切片自定义配置怎么做？**

A：可以通过实现 `TypeExcludeFilter` 或使用 `@ImportAutoConfiguration` 来定制。Spring Boot 允许通过 `spring.test.enabled` 属性控制测试切片的默认行为。

**Q5：如何测试 Feign/OpenFeign 客户端？**

A：推荐使用 `@RestClientTest` 配合 `MockRestServiceServer`，或者使用 `WireMock` 搭建独立的 HTTP Mock 服务。OpenFeign 客户端也可以通过 `@MockBean` 完全模拟。

---

## 七、总结

Spring Boot 测试切片是提升测试效率的利器：

1. **专注**：只测试目标层的逻辑，不耦合其他组件
2. **快速**：启动时间从数十秒降到数秒
3. **可靠**：减少外部依赖，避免不相关 Bean 导致测试失败
4. **全面**：覆盖了 MVC、JPA、JSON、Redis、MongoDB 等常用场景

**最佳实践**：
- Controller 测试用 `@WebMvcTest` + `MockMvc`
- Repository 测试用 `@DataJpaTest` + `TestEntityManager`
- JSON 序列化用 `@JsonTest` + `JacksonTester`
- REST 客户端用 `@RestClientTest` + `MockRestServiceServer`
- 端到端集成测试用 `@SpringBootTest`

使用测试切片，你会发现写测试不再是一件痛苦的事情，而是一种高效、愉悦的开发体验。
