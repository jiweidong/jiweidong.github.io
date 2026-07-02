---
title: Java 安全编码实战：反序列化漏洞、SQL注入防御与安全编码规范
date: 2026-07-02 08:00:00
tags:
  - Java
  - 安全
  - 反序列化
  - SQL注入
categories:
  - Java
  - 安全
author: 东哥
---

# Java 安全编码实战：反序列化漏洞、SQL注入防御与安全编码规范

## 引言

**"每 1000 行 Java 代码中平均有 0.5 个安全缺陷。"** — OWASP 2025 行业报告

Java 作为企业级开发的主力语言，其网络安全攻击面覆盖了从 JVM 层面到业务逻辑的各个维度。本文将从**反序列化漏洞**、**SQL注入防御**、**输入验证**、**文件操作安全**四大方面，结合真实漏洞案例与修复方案，帮你建立 Java 安全编码的系统性认知。

## 一、反序列化漏洞：Java 最危险的攻击面之一

### 1.1 漏洞原理

Java 反序列化漏洞的核心在于：`ObjectInputStream.readObject()` 在恢复对象时，会调用被恢复对象中所有可序列化类的 `readObject()` 方法（包括自定义的），攻击者通过构造恶意序列化数据，在反序列化过程中触发执行链（Gadget Chain）。

```java
// ❌ 高危示例：直接反序列化不可信数据
ObjectInputStream ois = new ObjectInputStream(request.getInputStream());
Object obj = ois.readObject();  // 如果 obj 是精心构造的攻击对象...
```

### 1.2 经典攻击链：Commons-Collections

```text
攻击者输入
    ↓
HashMap.readObject()
    ↓
TiedMapEntry.getValue()
    ↓
LazyMap.get()
    ↓
ChainedTransformer.transform()
    ↓
InvokerTransformer.transform()
    ↓
Runtime.exec("calc.exe")  ← 命令执行！
```

### 1.3 防御方案

```java
// ✅ 方案一：使用安全的序列化协议（推荐）
// 改用 Jackson 或 Gson 处理 JSON 格式，而非 Java 原生序列化

// ✅ 方案二：白名单反序列化
public class SafeObjectInputStream extends ObjectInputStream {
    private static final Set<String> WHITE_LIST = Set.of(
        "com.example.User",
        "java.util.ArrayList"
    );

    @Override
    protected Class<?> resolveClass(ObjectStreamClass desc) throws IOException {
        if (!WHITE_LIST.contains(desc.getName())) {
            throw new InvalidClassException("Unexpected class: " + desc.getName());
        }
        return super.resolveClass(desc);
    }
}

// ✅ 方案三：使用 SerialKiller 等第三方过滤库
// https://github.com/ikkisoft/SerialKiller
```

### 1.4 实战修复建议

| 措施 | 优先级 | 说明 |
|------|--------|------|
| 避免使用原生 Java 序列化 | 🔴 最高 | 改用 JSON/Protobuf 替代 |
| 配置 RMI 反序列化过滤器 | 🔴 高 | `JAVA_OPTS` 设置 `-Dcom.sun.jndi.rmi.object.trustURLCodebase=false` |
| 更新第三方依赖 | 🟡 中 | Commons-Collections 升级到 3.2.2+、Jackson 升级最新版 |
| 部署 WAF 规则 | 🟢 低 | 补丁方式，不能根治 |

## 二、SQL 注入：永远的老问题

### 2.1 Java 中最常见的三种注入场景

**场景一：JDBC 拼接（错误写法）**
```java
// ❌ 高危：字符串拼接
String sql = "SELECT * FROM users WHERE name = '" + userName + "'";
Statement stmt = conn.createStatement();
ResultSet rs = stmt.executeQuery(sql);
// 输入：' OR '1'='1  → 全表数据泄露！
```

**场景二：MyBatis ${} 注入**
```xml
<!-- ❌ 高危：使用 ${} 直接拼接 -->
<select id="getUser" resultType="User">
    SELECT * FROM user WHERE name = '${name}'
</select>
```

**场景三：Spring Data JPA 原生查询**
```java
// ❌ 高危：@Query 中使用字符串拼接
@Query("SELECT u FROM User u WHERE u.name = '" + name + "'")
User findByNameUnsafe(@Param("name") String name);
```

### 2.2 正确防御方案

```java
// ✅ JDBC 预编译
String sql = "SELECT * FROM users WHERE name = ? AND age > ?";
try (PreparedStatement pstmt = conn.prepareStatement(sql)) {
    pstmt.setString(1, userName);
    pstmt.setInt(2, minAge);
    ResultSet rs = pstmt.executeQuery();  // 参数完全隔离
}

// ✅ MyBatis #{} 参数占位
<select id="getUser" resultType="User">
    SELECT * FROM user WHERE name = #{name}  <!-- 自动预编译 -->
</select>

// ✅ 动态排序场景的解决方案
<select id="searchUsers" resultType="User">
    SELECT * FROM user
    WHERE name LIKE CONCAT('%', #{keyword}, '%')
    <if test="orderBy != null">
        ORDER BY ${orderBy}  <!-- 必须用白名单校验 -->
    </if>
</select>
```

### 2.3 动态排序的安全实践

**动态排序的特殊性**：`ORDER BY`、`表名` 不能使用预编译，因为它们是结构关键字。解决方案：

```java
// ✅ 白名单校验动态排序
private static final Set<String> ALLOWED_SORT_COLUMNS = Set.of(
    "create_time", "update_time", "name", "status"
);

public List<User> getUsers(String sortColumn, boolean asc) {
    if (!ALLOWED_SORT_COLUMNS.contains(sortColumn)) {
        throw new IllegalArgumentException("非法的排序字段: " + sortColumn);
    }
    String sql = "SELECT * FROM user ORDER BY " + sortColumn +
                 (asc ? " ASC" : " DESC");
    // ...
}
```

## 三、输入验证与参数校验

### 3.1 XSS 跨站脚本防御

```java
// ❌ 危险：直接输出用户输入
model.addAttribute("username", request.getParameter("username"));
// 用户输入 <script>alert('XSS')</script>  → HTML 中被当作脚本执行

// ✅ 方案一：Spring Boot 默认的 HTML 转义
// Thymeleaf / Freemarker 默认开启，无需额外配置
// 如果使用 @ResponseBody，Jackson 不会转义，需手动处理

// ✅ 方案二：自定义 XSS 过滤器
@Component
public class XSSFilter implements Filter {
    @Override
    public void doFilter(ServletRequest request, ServletResponse response,
                         FilterChain chain) {
        chain.doFilter(new XSSRequestWrapper((HttpServletRequest) request), response);
    }
}

// ✅ 方案三：使用 OWASP Java Encoder
import org.owasp.encoder.Encode;

model.addAttribute("username", Encode.forHtml(userInput));
```

### 3.2 参数校验最佳实践

```java
// 使用 Bean Validation + 全局异常处理
public class CreateUserRequest {
    @NotBlank(message = "用户名不能为空")
    @Size(min = 2, max = 20, message = "用户名长度2-20")
    private String username;

    @Pattern(regexp = "^(https?://).+", message = "URL格式不正确")
    private String website;

    @Email(message = "邮箱格式不正确")
    private String email;

    @AssertTrue(message = "必须同意协议")
    private boolean agreement;
}
```

## 四、文件操作安全

### 4.1 路径遍历攻击防御

```java
// ❌ 危险：直接拼接用户输入的文件名
String filePath = "/data/uploads/" + request.getParameter("file");

// ✅ 安全做法：规范化路径后校验
public void downloadFile(String filename) {
    Path baseDir = Path.of("/data/uploads/").normalize();
    Path filePath = baseDir.resolve(filename).normalize();

    // 关键：确保解析后的路径仍在基目录内
    if (!filePath.startsWith(baseDir)) {
        throw new SecurityException("非法路径访问: " + filename);
    }

    Files.copy(filePath, response.getOutputStream());
}
```

### 4.2 文件上传安全检查清单

```java
@PostMapping("/upload")
public String handleUpload(@RequestParam("file") MultipartFile file) {
    // 1. 文件大小限制
    if (file.getSize() > 10 * 1024 * 1024) {
        throw new FileUploadException("文件不能超过10MB");
    }

    // 2. 文件类型检测（基于魔数，非扩展名）
    byte[] magicBytes = new byte[4];
    file.getInputStream().read(magicBytes);
    if (!isAllowedMagicNumber(magicBytes)) {
        throw new FileUploadException("不支持的文件类型");
    }

    // 3. 文件名消毒
    String safeName = file.getOriginalFilename()
        .replaceAll("[<>:\"/\\|?*]", "_");
        // 避免路径遍历和特殊字符

    // 4. 存储到不可直接访问的目录
    Path storePath = Path.of("/secure/storage/", safeName);
    file.transferTo(storePath.toFile());
}
```

## 五、OWASP Top 10 在 Java 中的映射

| OWASP 风险 | Java 防御要点 |
|-----------|--------------|
| A01 访问控制 | Spring Security 方法级别 `@PreAuthorize` |
| A02 加密失败 | 使用 `java.security` 标准库，避免自实现加密 |
| A03 注入 | PreparedStatement / MyBatis #{} / 输入白名单 |
| A04 不安全设计 | 安全设计评审，最小权限原则 |
| A05 安全配置错误 | 不硬编码密钥，使用 Vault / KMS |
| A06 易受攻击组件 | 定期 `mvn versions:display-dependency-updates` |
| A07 认证失败 | Spring Security 多因素认证 |
| A08 数据完整性 | JWT 签名校验、防篡改校验和 |
| A09 日志监控不足 | 统一日志框架 + ELK 告警 |
| A10 SSRF | URL 白名单，禁止内网请求 |

## 六、面试高频追问

### Q1：Java 反序列化漏洞的根本原因是什么？
**A：** 根本原因在于 `ObjectInputStream.readObject()` 在调用构造函数前会执行 `readObject()` 和 `readResolve()` 方法，攻击者通过构造恶意 Gadget Chain 在反序列化过程中执行任意代码。核心问题不是序列化本身，而是**Java 反射 + 多态**的组合被攻击者利用。

### Q2：MyBatis 中 #{} 和 ${} 的区别及安全性？
**A：** `#{}` 使用 JDBC 预编译，参数通过 `?` 占位符传递，完全隔离 SQL 结构，**安全**；`${}` 直接拼接字符串，**存在注入风险**。动态排序、表名等需要结构性变更的场景必须用白名单校验 + `${}` 组合。

### Q3：如何检测项目中是否存在反序列化漏洞依赖？
**A：** 使用 OWASP Dependency-Check Maven 插件：
```xml
<plugin>
    <groupId>org.owasp</groupId>
    <artifactId>dependency-check-maven</artifactId>
    <version>10.0.0</version>
    <configuration>
        <failBuildOnCVSS>7</failBuildOnCVSS>
    </configuration>
</plugin>
```
执行 `mvn dependency-check:check` 即可生成报告。

### Q4：Spring Boot 应用中最容易忽略的安全配置是什么？
**A：** 三个最容易忽略的点：① Actuator 端点暴露（`management.endpoints.web.exposure.include=*`）；② 默认 H2 Console 未关闭（应在生产环境禁用）；③ 静态资源目录直接暴露敏感文件。

---

## 总结

Java 安全编码不是某个单一技术点，而是一套**贯穿开发全流程的安全意识体系**：

- **输入不可信** — 所有用户输入都是有害的，必须校验
- **最小权限** — 代码只获取必要的数据和资源
- **纵深防御** — 不止依赖一种防御机制（预编译 + 权限校验 + WAF）
- **默认安全** — 框架的安全配置默认不要轻易关闭

推荐读完本文后，在项目中引入 **SpotBugs + Find Sec Bugs** 插件，持续自动化检测安全漏洞，将安全意识转化为工程实践。
