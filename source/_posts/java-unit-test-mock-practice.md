---
title: Java 单元测试与 Mock 框架实战指南（JUnit 5 + Mockito + Testcontainers）
date: 2026-06-17 09:00:00
tags:
  - JUnit5
  - Mockito
  - Testcontainers
  - 单元测试
  - TDD
  - 集成测试
categories:
  - 测试
author: 东哥
---

# Java 单元测试与 Mock 框架实战指南（JUnit 5 + Mockito + Testcontainers）

## 一、为什么单元测试如此重要？

在许多团队中，"没时间写测试"是最常见的借口。但实际上，**没有测试的代码不是遗留代码，无法安全修改的代码才是真正的遗留代码**。

根据行业统计：
- 引入自动化测试的团队，Bug 率平均降低 **40-80%**
- 每次代码修改的回归风险降低 **60%**
- 代码评审效率提升 **2-3 倍**

本文将从 JUnit 5 基础出发，覆盖 Mockito 高级用法、Testcontainers 集成测试、Spring Boot Test 实战、TDD 最佳实践以及 JaCoCo 覆盖率工具的使用，帮你建立完整的 Java 测试技能树。

<!-- more -->

## 二、JUnit 5 核心详解

JUnit 5 = **JUnit Platform** + **JUnit Jupiter** + **JUnit Vintage**

| 组件 | 功能 |
|------|------|
| JUnit Platform | 启动测试框架的基础，提供 TestEngine API |
| JUnit Jupiter | 新一代编程模型+扩展模型（JUnit 5 新注解） |
| JUnit Vintage | 向后兼容 JUnit 4 运行 |

### 2.1 核心注解

```java
import org.junit.jupiter.api.*;
import static org.junit.jupiter.api.Assertions.*;

class CalculatorTest {

    @BeforeAll
    static void setupAll() {
        System.out.println("所有测试前执行一次（必须 static）");
    }

    @BeforeEach
    void setup() {
        System.out.println("每个测试方法前执行");
    }

    @Test
    void testAddition() {
        Calculator calc = new Calculator();
        assertEquals(5, calc.add(2, 3), "2 + 3 应该等于 5");
        assertNotNull(calc);
        assertTrue(calc.add(1, 1) == 2);
    }

    @Test
    void testDivision() {
        Calculator calc = new Calculator();
        assertThrows(ArithmeticException.class, () -> calc.divide(1, 0),
            "除以零应该抛出异常");
    }

    @AfterEach
    void teardown() {
        System.out.println("每个测试方法后执行");
    }

    @AfterAll
    static void teardownAll() {
        System.out.println("所有测试后执行一次（必须 static）");
    }
}
```

### 2.2 断言详解

JUnit 5 的 `Assertions` 类提供了丰富的断言方法：

```java
class AssertionsDemo {

    @Test
    void standardAssertions() {
        assertEquals(4, 2 + 2);
        assertNotEquals(5, 2 + 2);
        assertTrue(10 > 0);
        assertFalse(10 < 0);
        assertNull(null);
        assertNotNull("hello");
    }

    @Test
    void groupedAssertions() {
        Person person = new Person("东哥", 30);

        // 分组断言：组内全部执行，所有失败一起报告
        assertAll("person",
            () -> assertEquals("东哥", person.getName()),
            () -> assertEquals(30, person.getAge()),
            () -> assertTrue(person.getAge() > 18)
        );
    }

    @Test
    void exceptionAssertions() {
        // 验证异常类型和消息
        Exception exception = assertThrows(IllegalArgumentException.class, () -> {
            throw new IllegalArgumentException("年龄不能为负数");
        });
        assertTrue(exception.getMessage().contains("不能为负数"));
    }

    @Test
    void timeoutAssertions() {
        // 超时断言
        assertTimeout(Duration.ofMillis(100), () -> {
            Thread.sleep(50);  // 不会超时
        });

        // 超时断言（等待完成后才报错）
        assertTimeoutPreemptively(Duration.ofMillis(100), () -> {
            Thread.sleep(50);
        });
    }
}
```

> **`assertAll` 与多个 `assert` 的区别**：多个独立的 `assert` 方法中如果第一个失败，后续不会执行。而 `assertAll` 中的每个断言都会执行，所有失败会被一次性报告——这在调试时非常有用。

### 2.3 参数化测试

JUnit 5 的 **参数化测试** 极大地减少了重复代码：

```java
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.*;

class ParametrizedTest {

    // 方式1：直接值
    @ParameterizedTest
    @ValueSource(ints = {1, 2, 3, 4, 5})
    void testWithValueSource(int number) {
        assertTrue(number > 0);
    }

    // 方式2：CSV
    @ParameterizedTest
    @CsvSource({
        "apple,     1",
        "banana,    2",
        "'lemon,lime', 3"
    })
    void testWithCsvSource(String fruit, int rank) {
        assertNotNull(fruit);
        assertTrue(rank > 0);
    }

    // 方式3：CSV 文件
    @ParameterizedTest
    @CsvFileSource(resources = "/test-data.csv", numLinesToSkip = 1)
    void testWithCsvFileSource(String name, int age, boolean active) {
        assertNotNull(name);
        assertTrue(age >= 0);
    }

    // 方式4：Enum 源
    @ParameterizedTest
    @EnumSource(DayOfWeek.class)
    void testWithEnumSource(DayOfWeek day) {
        assertNotNull(day);
    }

    // 方式5：方法源（最灵活）
    @ParameterizedTest
    @MethodSource("provideTestData")
    void testWithMethodSource(String input, int expected) {
        assertEquals(expected, input.length());
    }

    static Stream<Arguments> provideTestData() {
        return Stream.of(
            Arguments.of("hello", 5),
            Arguments.of("world!", 6),
            Arguments.of("JUnit 5", 7)
        );
    }
}
```

### 2.4 嵌套测试

使用 `@Nested` 可以在测试类内部组织层次化的测试结构，非常适合测试复杂对象：

```java
class UserServiceTest {

    private UserService userService;

    @BeforeEach
    void setup() {
        userService = new UserService();
    }

    @Nested
    class UserCreation {

        @Test
        void shouldCreateUserWithValidData() {
            User user = userService.createUser("Alice", "alice@example.com");
            assertNotNull(user.getId());
            assertEquals("Alice", user.getName());
        }

        @Test
        void shouldThrowWhenEmailInvalid() {
            assertThrows(ValidationException.class,
                () -> userService.createUser("Bob", "invalid-email"));
        }
    }

    @Nested
    class UserDeletion {

        @BeforeEach
        void setupUsers() {
            userService.createUser("Alice", "alice@example.com");
            userService.createUser("Bob", "bob@example.com");
        }

        @Test
        void shouldDeleteExistingUser() {
            assertTrue(userService.deleteUser(1L));
        }

        @Test
        void shouldNotDeleteNonExistentUser() {
            assertFalse(userService.deleteUser(999L));
        }
    }
}
```

## 三、Mockito — Java Mock 框架之王

Mockito 是 Java 最流行的 Mock 框架，支持行为验证和打桩（Stubbing）。结合 JUnit 5 使用时，推荐通过 `@ExtendWith(MockitoExtension.class)` 集成。

### 3.1 快速上手

```java
import org.mockito.*;
import org.mockito.junit.jupiter.MockitoExtension;
import org.junit.jupiter.api.extension.ExtendWith;

@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock
    private PaymentService paymentService;

    @Mock
    private InventoryService inventoryService;

    @InjectMocks  // 自动注入 mock 到被测对象
    private OrderService orderService;

    @Test
    void shouldCompleteOrderWhenInventoryAvailable() {
        // 1. 打桩（Stub）
        when(inventoryService.checkStock("SKU-001", 1)).thenReturn(true);
        when(paymentService.charge("order-123", 99.99)).thenReturn(PaymentStatus.SUCCESS);

        // 2. 执行
        OrderResult result = orderService.placeOrder("order-123", "SKU-001", 1, 99.99);

        // 3. 验证结果
        assertTrue(result.isSuccess());

        // 4. 验证交互行为
        verify(inventoryService).checkStock("SKU-001", 1);
        verify(paymentService).charge("order-123", 99.99);
    }
}
```

### 3.2 打桩高级技巧

```java
@ExtendWith(MockitoExtension.class)
class MockingAdvancedTest {

    @Mock
    private UserRepository userRepository;

    @Mock
    private EmailService emailService;

    @InjectMocks
    private UserService userService;

    @Test
    void shouldHandleDifferentStubPatterns() {
        // === 1. 返回值打桩 ===
        when(userRepository.findById(1L)).thenReturn(Optional.of(new User("Alice")));
        when(userRepository.findById(2L)).thenReturn(Optional.empty());

        // === 2. 异常打桩 ===
        when(userRepository.findById(-1L)).thenThrow(IllegalArgumentException.class);

        // === 3. void 方法打桩 ===
        doNothing().when(emailService).sendWelcomeEmail(anyString());

        // === 4. 连续调用返回不同值 ===
        when(userRepository.findByName("test"))
            .thenReturn(Optional.of(new User("test")))
            .thenThrow(new RuntimeException("第二次调用失败"))
            .thenReturn(Optional.empty());

        // === 5. 自定义 Answer ===
        when(userRepository.findByName(anyString())).thenAnswer(invocation -> {
            String name = invocation.getArgument(0);
            if (name.length() < 2) {
                throw new ValidationException("名称太短");
            }
            return Optional.of(new User(name));
        });

        // === 6. any() 匹配器 ===
        when(userRepository.save(any(User.class))).thenAnswer(invocation -> {
            User user = invocation.getArgument(0);
            user.setId(ThreadLocalRandom.current().nextLong());
            return user;
        });
    }
}
```

### 3.3 行为验证

```java
@ExtendWith(MockitoExtension.class)
class VerificationTest {

    @Mock
    private EmailService emailService;

    @Mock
    private AuditLogService auditLogService;

    @Test
    void shouldVerifyInteractions() {
        // === 调用次数验证 ===
        verify(emailService, times(1)).sendWelcomeEmail(anyString());
        verify(emailService, never()).sendGoodbyeEmail(anyString());
        verify(emailService, atLeastOnce()).sendNotification(any());
        verify(emailService, atMost(3)).sendNotification(any());

        // === 顺序验证 ===
        InOrder inOrder = inOrder(emailService, auditLogService);
        inOrder.verify(emailService).sendWelcomeEmail("alice@example.com");
        inOrder.verify(auditLogService).log("USER_REGISTERED", "alice@example.com");

        // === 超时验证 ===
        verify(emailService, timeout(1000)).sendAsyncEmail(anyString());

        // === 零交互验证 ===
        verifyNoInteractions(auditLogService);
        verifyNoMoreInteractions(emailService);
    }
}
```

### 3.4 BDDMockito 风格

如果你的团队采用 BDD（行为驱动开发），Mockito 提供了 BDD 风格的别名：

```java
import static org.mockito.BDDMockito.*;

@ExtendWith(MockitoExtension.class)
class BddStyleTest {

    @Mock
    private PaymentService paymentService;

    @InjectMocks
    private OrderService orderService;

    @Test
    void shouldCompletePaymentInBddStyle() {
        // === Given：给定条件 ===
        given(paymentService.charge(anyString(), anyDouble()))
            .willReturn(PaymentStatus.SUCCESS);

        // === When：执行动作 ===
        PaymentResult result = orderService.processPayment("order-001", 199.99);

        // === Then：验证结果 && 行为 ===
        then(result).extracting(PaymentResult::getStatus)
            .isEqualTo(PaymentStatus.SUCCESS);
        then(paymentService).should(times(1))
            .charge("order-001", 199.99);
    }
}
```

BDD 风格的 `given/willReturn` 替代 `when/thenReturn`，`then().should()` 替代 `verify()`。这对于非技术 PM 也能看懂的测试报告非常友好。

### 3.5 Spy 与 Partial Mock

```java
@Test
void testPartialMockWithSpy() {
    List<String> list = new LinkedList<>();
    List<String> spy = spy(list);

    // 真实行为
    spy.add("one");
    spy.add("two");
    assertEquals("one", spy.get(0));

    // 覆盖部分方法
    when(spy.size()).thenReturn(100);
    assertEquals(100, spy.size());   // 返回打桩值
    assertEquals("one", spy.get(0)); // 仍然是真实值
}

@Test
void testSpyWithDoReturn() {
    PaymentService realService = new PaymentService();
    PaymentService spyService = spy(realService);

    // 注意：void 方法用 doReturn 而非 when
    doReturn(PaymentStatus.SUCCESS).when(spyService).process(anyString());
    
    assertEquals(PaymentStatus.SUCCESS, spyService.process("test"));
}
```

> **`spy` 与 `mock` 的区别**：`mock` 是纯模拟对象，所有方法返回默认值；`spy` 是对真实对象的包装，默认调用真实方法，可以选择性打桩。

## 四、Testcontainers — 真实环境集成测试

Testcontainers 让你在测试中启动 Docker 容器，使用真实的数据库、消息队列、Redis 等中间件进行集成测试——再也不用依赖嵌入式数据库（如 H2）来模拟了。

### 4.1 依赖配置

```xml
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>testcontainers</artifactId>
    <version>1.20.1</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>mysql</artifactId>
    <version>1.20.1</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>junit-jupiter</artifactId>
    <version>1.20.1</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.testcontainers</groupId>
    <artifactId>kafka</artifactId>
    <version>1.20.1</version>
    <scope>test</scope>
</dependency>
```

### 4.2 数据库集成测试

```java
import org.testcontainers.containers.MySQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

@Testcontainers
class UserRepositoryIntegrationTest {

    // ⚡ 类级别容器（所有测试共享）
    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0")
        .withDatabaseName("testdb")
        .withUsername("test")
        .withPassword("test");

    private UserRepository userRepository;

    @BeforeEach
    void setup() {
        // 从容器获取 JDBC URL
        String jdbcUrl = mysql.getJdbcUrl();
        String username = mysql.getUsername();
        String password = mysql.getPassword();

        // 初始化数据库连接和表结构
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(jdbcUrl);
        config.setUsername(username);
        config.setPassword(password);

        DataSource ds = new HikariDataSource(config);
        initDatabase(ds);           // 建表脚本
        userRepository = new UserRepository(ds);
    }

    @Test
    void shouldPersistAndFindUser() {
        // 真实 MySQL 数据库操作
        User user = new User("东哥", "dong@example.com");
        userRepository.save(user);

        Optional<User> found = userRepository.findByEmail("dong@example.com");
        assertTrue(found.isPresent());
        assertEquals("东哥", found.get().getName());
    }

    @Test
    void shouldEnforceUniqueEmailConstraint() {
        userRepository.save(new User("Alice", "duplicate@example.com"));
        assertThrows(DataIntegrityViolationException.class,
            () -> userRepository.save(new User("Bob", "duplicate@example.com")));
    }

    private void initDatabase(DataSource ds) {
        // 执行建表 SQL
        try (Connection conn = ds.getConnection();
             Statement stmt = conn.createStatement()) {
            stmt.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id BIGINT AUTO_INCREMENT PRIMARY KEY,
                    name VARCHAR(100) NOT NULL,
                    email VARCHAR(200) NOT NULL UNIQUE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """);
        } catch (SQLException e) {
            throw new RuntimeException("初始化数据库失败", e);
        }
    }
}
```

### 4.3 多容器集成测试

```java
import org.testcontainers.containers.Network;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.containers.KafkaContainer;

@Testcontainers
class MicroserviceIntegrationTest {

    // 共享网络
    static Network network = Network.newNetwork();

    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withNetwork(network)
        .withNetworkAliases("redis")
        .withExposedPorts(6379)
        .waitingFor(Wait.forLogMessage(".*Ready to accept connections.*\\n", 1));

    @Container
    static KafkaContainer kafka = new KafkaContainer(
        DockerImageName.parse("confluentinc/cp-kafka:7.5.0"))
        .withNetwork(network)
        .withNetworkAliases("kafka");

    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0")
        .withNetwork(network)
        .withNetworkAliases("mysql")
        .withDatabaseName("orderdb");

    @Test
    void shouldProcessOrderWithRealDependencies() {
        // 使用真实 Redis 做缓存
        try (Jedis jedis = new Jedis(redis.getHost(), redis.getMappedPort(6379))) {
            jedis.set("product:SKU-001", "{\"price\": 99.99, \"stock\": 10}");
            assertEquals("{\"price\": 99.99, \"stock\": 10}", jedis.get("product:SKU-001"));
        }

        // 使用真实 Kafka 发送消息
        Properties props = new Properties();
        props.put("bootstrap.servers", kafka.getBootstrapServers());
        try (Producer<String, String> producer = new KafkaProducer<>(props,
                 new StringSerializer(), new StringSerializer())) {
            producer.send(new ProducerRecord<>("orders", "order-001", "{\"amount\": 199.99}"));
            producer.flush();
        }

        // 使用真实 MySQL
        assertTrue(mysql.isRunning());
    }
}
```

### 4.4 复用容器（提升性能）

默认每个测试类都会创建新容器，通过 `@Testcontainers(parallel = true)` 和容器复用可以加快速度：

```java
@Testcontainers
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class ReusableContainerTest {

    @Container
    static MySQLContainer<?> mysql = new MySQLContainer<>("mysql:8.0")
        .withReuse(true)          // 启用复用（需要在 ~/.testcontainers.properties 配置）
        .withDatabaseName("testdb");

    // 多个测试方法共享同一个容器
    @Test
    @Order(1)
    void firstTest() {
        System.out.println("容器创建，URL: " + mysql.getJdbcUrl());
    }

    @Test
    @Order(2)
    void secondTest() {
        System.out.println("复用容器，URL: " + mysql.getJdbcUrl());
        // URL 不变，说明同一个容器
    }
}
```

> 在 `~/.testcontainers.properties` 中添加 `testcontainers.reuse.enable=true` 启用复用。**注意**：复用容器不会自动清理数据，需要在测试间自行清理。

## 五、Spring Boot Test 实战

Spring Boot 提供 `@SpringBootTest` + `@AutoConfigureMockMvc` 来测试 Controller 层：

```java
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
@ActiveProfiles("test")
class OrderControllerIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean  // Spring Boot 3.4+，替代 @MockBean
    private OrderService orderService;

    @Test
    void shouldCreateOrder() throws Exception {
        // 打桩
        CreateOrderRequest request = new CreateOrderRequest("SKU-001", 2);
        when(orderService.createOrder(any(CreateOrderRequest.class)))
            .thenReturn(new OrderResponse("order-001", OrderStatus.CREATED));

        // 执行 HTTP 请求
        mockMvc.perform(post("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"sku\": \"SKU-001\", \"quantity\": 2}"))
            .andExpect(status().isCreated())
            .andExpect(jsonPath("$.id").value("order-001"))
            .andExpect(jsonPath("$.status").value("CREATED"));

        verify(orderService).createOrder(any(CreateOrderRequest.class));
    }

    @Test
    void shouldReturn400WhenInvalidRequest() throws Exception {
        // 缺少必填字段
        mockMvc.perform(post("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"sku\": \"\"}"))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.errors").isArray());
    }

    @Test
    @Transactional // 测试后自动回滚
    @Testcontainers
    @Container  // 用真实数据库
    void shouldPersistToDatabase() throws Exception {
        mockMvc.perform(post("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"sku\": \"SKU-001\", \"quantity\": 1}"))
            .andExpect(status().isCreated());
        
        // 验证数据库中有记录（测试结束后回滚）
    }
}
```

## 六、覆盖率工具 JaCoCo

### 6.1 Maven 配置

```xml
<plugin>
    <groupId>org.jacoco</groupId>
    <artifactId>jacoco-maven-plugin</artifactId>
    <version>0.8.11</version>
    <executions>
        <execution>
            <goals>
                <goal>prepare-agent</goal>
            </goals>
        </execution>
        <execution>
            <id>report</id>
            <phase>verify</phase>
            <goals>
                <goal>report</goal>
            </goals>
        </execution>
        <execution>
            <id>check</id>
            <phase>verify</phase>
            <goals>
                <goal>check</goal>
            </goals>
            <configuration>
                <rules>
                    <rule>
                        <element>BUNDLE</element>
                        <limits>
                            <limit>
                                <counter>INSTRUCTION</counter>
                                <value>COVEREDRATIO</value>
                                <minimum>0.80</minimum>
                            </limit>
                            <limit>
                                <counter>BRANCH</counter>
                                <value>COVEREDRATIO</value>
                                <minimum>0.70</minimum>
                            </limit>
                            <limit>
                                <counter>LINE</counter>
                                <value>COVEREDRATIO</value>
                                <minimum>0.80</minimum>
                            </limit>
                        </limits>
                    </rule>
                </rules>
                <excludes>
                    <exclude>**/dto/**</exclude>
                    <exclude>**/entity/**</exclude>
                    <exclude>**/config/**</exclude>
                </excludes>
            </configuration>
        </execution>
    </executions>
</plugin>
```

### 6.2 覆盖率指标说明

| 指标 | 含义 | 建议 |
|------|------|------|
| **指令覆盖率** | 字节码指令覆盖情况 | ≥ 80% |
| **分支覆盖率** | if/else/switch 分支覆盖 | ≥ 70% |
| **行覆盖率** | 源代码行覆盖情况 | ≥ 80% |
| **方法覆盖率** | 方法是否被调用 | ≥ 80% |
| **类覆盖率** | 类是否被覆盖 | ≥ 95% |

### 6.3 生成并查看报告

```bash
# 生成覆盖率报告
mvn clean verify

# 报告位置：target/site/jacoco/index.html
```

**重要提示**：覆盖率数字不是目标，**高质量的测试**才是。100% 覆盖率的糟糕测试不如 80% 覆盖率的健壮测试。关注被测代码的业务逻辑是否被覆盖，而不仅仅是数字。

## 七、TDD 实战：一个完整的测试驱动开发案例

以"用户密码校验器"为例演示 TDD 的 Red-Green-Refactor 循环：

### 7.1 Red（先写失败的测试）

```java
class PasswordValidatorTest {

    private PasswordValidator validator;

    @BeforeEach
    void setup() {
        validator = new PasswordValidator();
    }

    @Test
    void shouldRejectPasswordShorterThan8Chars() {
        assertThrows(ValidationException.class,
            () -> validator.validate("Ab1!"));
    }

    @Test
    void shouldRejectPasswordWithoutUppercase() {
        assertThrows(ValidationException.class,
            () -> validator.validate("abc12345!"));
    }

    @Test
    void shouldRejectPasswordWithoutDigit() {
        assertThrows(ValidationException.class,
            () -> validator.validate("Abcdefgh!"));
    }

    @Test
    void shouldRejectPasswordWithoutSpecialChar() {
        assertThrows(ValidationException.class,
            () -> validator.validate("Abcdefg1"));
    }

    @Test
    void shouldAcceptValidPassword() {
        assertDoesNotThrow(
            () -> validator.validate("Abcd1234!"));
    }
}
```

### 7.2 Green（实现使测试通过的最简代码）

```java
public class PasswordValidator {

    private static final int MIN_LENGTH = 8;
    private static final String UPPERCASE_PATTERN = ".*[A-Z].*";
    private static final String DIGIT_PATTERN = ".*\\d.*";
    private static final String SPECIAL_CHAR_PATTERN = ".*[!@#$%^&*()].*";

    public void validate(String password) {
        if (password == null || password.length() < MIN_LENGTH) {
            throw new ValidationException("密码长度至少8位");
        }
        if (!password.matches(UPPERCASE_PATTERN)) {
            throw new ValidationException("密码需要包含大写字母");
        }
        if (!password.matches(DIGIT_PATTERN)) {
            throw new ValidationException("密码需要包含数字");
        }
        if (!password.matches(SPECIAL_CHAR_PATTERN)) {
            throw new ValidationException("密码需要包含特殊字符");
        }
    }
}
```

### 7.3 Refactor（重构：参数化测试减少重复）

```java
@ExtendWith(MockitoExtension.class)
class PasswordValidatorTest {

    private PasswordValidator validator;

    @BeforeEach
    void setup() {
        validator = new PasswordValidator();
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "Ab1!",           // 太短
        "abc12345!",      // 无大写
        "Abcdefgh!",      // 无数字
        "Abcdefg1"        // 无特殊字符
    })
    void shouldRejectInvalidPasswords(String password) {
        assertThrows(ValidationException.class,
            () -> validator.validate(password));
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "Abcd1234!",
        "StrongP@ss1",
        "HelloWorld#99"
    })
    void shouldAcceptValidPasswords(String password) {
        assertDoesNotThrow(() -> validator.validate(password));
    }

    @Test
    void shouldProvideMeaningfulErrorMessage() {
        ValidationException e = assertThrows(ValidationException.class,
            () -> validator.validate("weak"));
        assertTrue(e.getMessage().contains("至少8位"));
    }
}
```

## 八、最佳实践总结

### 8.1 测试金字塔建议

```
         ╱╲
        ╱ E2E ╲            ← 5-10%，关键端到端流程
       ╱────────╲
      ╱ 集成测试 ╲         ← 20-30%，数据库/外部服务
     ╱────────────╲
    ╱  单元测试    ╲       ← 60-70%，业务逻辑全覆盖
   ╱────────────────╲
```

### 8.2 测试命名规范

| 模式 | 示例 |
|------|------|
| should_xxx_when_xxx | `shouldThrowExceptionWhenEmailInvalid` |
| given_xxx_then_xxx | `givenEmptyCart_thenCheckoutFails` |
| xxx_xxx_xxx | `placeOrder_whenStockAvailable_createsOrder` |

### 8.3 编写高质量测试的10条原则

1. **FIRST 原则**：Fast（快速）、Independent（独立）、Repeatable（可重复）、Self-Validating（自验证）、Timely（及时）
2. **一个测试只测一个逻辑概念**：不要在一个测试方法中测试多个不相关的场景
3. **避免测试实现细节**：测试行为（Behavior）而非实现（Implementation）
4. **使用有意义的断言消息**：`assertEquals(5, result, "预期服务返回5个结果")`
5. **避免 Mock 不需要的对象**：过多的 Mock 导致脆弱的测试
6. **保持测试简洁**：测试代码同样需要干净和可维护
7. **优先使用真实的依赖**（Testcontainers）而非嵌入式的模拟（H2）
8. **使用 `@Nested` 组织测试**：提高可读性和可维护性
9. **定期检查覆盖率报告**：关注未覆盖的边界条件
10. **将测试视为一等公民**：和生产代码一起评审、一起维护

## 九、总结

本文从 JUnit 5 的核心注解和断言开始，深入讲解了 Mockito 的打桩、验证和 BDD 风格，展示了 Testcontainers 如何用真实容器提升集成测试的可靠性，最后通过 TDD 实战演示了完整的测试驱动开发流程。

掌握这套测试技术栈，你不仅能写出更可靠的代码，还能在重构时充满信心。记住：测试不是成本，而是对未来代码修改的保险。

最后推荐几个值得深入的工具：
- **ArchUnit**：架构测试，验证包依赖、类命名规范
- **Pitest**：变异测试，评估测试的有效性
- **WireMock**：HTTP API Mock，测试微服务间调用
