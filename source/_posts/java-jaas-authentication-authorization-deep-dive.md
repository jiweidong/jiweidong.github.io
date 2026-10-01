---
title: 【Java 安全】JAAS 深度解析：Subject、Principal、LoginModule 与认证授权体系演进
date: 2026-10-01 08:00:00
tags:
  - Java
  - 安全
  - JAAS
  - 认证授权
categories:
  - Java
  - Java 核心
author: 东哥
---

# 【Java 安全】JAAS 深度解析：Subject、Principal、LoginModule 与认证授权体系演进

## 面试官：讲讲 Java 原生的安全体系

大多数人的回答是：`SecurityManager` + `AccessController` + `Policy`。面试官会继续问：

> "那 JAAS 呢？`LoginModule` 的执行流程是怎样的？为什么 Spring Security 没有用它？"

JAAS（Java Authentication and Authorization Service）是 JDK 1.4 就引入的标准 API，比 Spring Security 早了近十年。它定义了 Java 世界里**认证（Authentication）**与**授权（Authorization）**的标准抽象，至今仍在 Kerberos、LDAP、SASL 等场景中被使用。

理解 JAAS，能帮你看清"为什么最终是 Spring Security 赢了"，也是理解 Java 安全体系演进的关键一环。

## 一、JAAS 要解决的两个问题

### 1.1 认证（Authentication）：你是谁？

在没有 JAAS 的年代，每个框架自己造轮子：自己写登录、自己存用户、自己判断密码。JAAS 的目标是提供一套**可插拔的认证抽象**：

- **不管**你是用文件、数据库、Kerberos 还是 LDAP 认证；
- 只要实现统一的 `LoginModule` 接口；
- 应用只依赖 JAAS API，不依赖具体实现。

### 1.2 授权（Authorization）：你能做什么？

认证之后，JAAS 用 `Subject` + `Principal` 描述"主体"及其身份，再结合 `Policy` 做权限判断（基于 `CodeSource` 和 `Principal` 的权限授予）。

### 1.3 JAAS 的三层架构

```
应用代码
   │  使用 JAAS API
   ▼
JAAS 核心（javax.security.auth.*）
   ├── Subject / Principal / Credential   ← 身份抽象
   ├── LoginContext / LoginModule         ← 认证 SPI
   └── Policy / Permission                ← 授权
   │
   ▼
底层实现（javax.security.auth.spi 的实现类）
   ├── UnixLoginModule       （/etc/passwd + shadow）
   ├── Krb5LoginModule       （Kerberos）
   ├── LdapLoginModule       （LDAP 目录）
   └── JndiLoginModule       （JNDI 目录服务）
```

## 二、核心概念：Subject、Principal、Credential

### 2.1 Subject：一个"身份主体"

`Subject` 代表一个**请求来源的主体**——可以是人、服务、设备。它持有两组关键信息：

```java
public final class Subject implements Serializable {
    // 身份集合：可以有多个身份
    private final Set<Principal> principals;

    // 公开凭证：如证书、公钥
    private transient SecureSet<Object> pubCredentials;

    // 私有凭证：如密码、私钥、Kerberos ticket
    private transient SecureSet<Object> privCredentials;
}
```

关键设计：**Subject 用 `SecureSet` 存放凭证，并通过 `AccessControlContext` 做访问控制**，只有"被授权的代码"才能读写其中的私有凭证。

### 2.2 Principal：一个具体身份

`Principal` 是身份的载体，只有一个方法：

```java
public interface Principal {
    String getName();
    boolean equals(Object another);
    String toString();
    int hashCode();
    // 1.8 起有默认实现
    default boolean implies(Subject subject) { ... }
}
```

典型实现：

| Principal 实现 | 含义 |
| --- | --- |
| `NTUserPrincipal` | Windows 域账号 |
| `UnixPrincipal` | Unix 用户名 |
| `Krb5Principal` | Kerberos principal，如 `user@REALM.COM` |
| `X500Principal` | X.509 证书主体，如 `CN=dong,O=example` |
| `Group` | 表示一个组，是 Principal 的子接口 |

你可以自定义，比如：

```java
public class RolePrincipal implements Principal, Serializable {
    private final String role;

    public RolePrincipal(String role) { this.role = role; }

    @Override public String getName() { return role; }
    @Override public boolean equals(Object o) {
        return o instanceof RolePrincipal && role.equals(((RolePrincipal) o).role);
    }
    @Override public int hashCode() { return role.hashCode(); }
    @Override public String toString() { return "RolePrincipal[" + role + "]"; }
}
```

### 2.3 Credential：凭证

- **公有凭证**：可以公开，如公钥证书；
- **私有凭证**：必须保护，如密码、私钥、Kerberos Ticket。

`Subject` 提供 `doAs` / `doAsPrivileged` 在有身份上下文中执行代码：

```java
Subject.doAs(subject, (PrivilegedAction<Void>) () -> {
    // 这里的代码可以看到 subject 的身份
    // Subject.getSubject(AccessController.getContext())
    return null;
});
```

> Java 17+ 之后由于 `AccessController` 被废弃，需要配合 `-Djava.security.manager=allow` 或改用替代方案，这也是 JAAS 在现代 Java 中逐渐边缘化的原因之一。

## 三、认证核心：LoginContext 与 LoginModule

### 3.1 LoginContext：认证的入口

```java
Subject subject = new Subject();
LoginContext lc = new LoginContext("Sample", subject,
        new DialogCallbackHandler(),
        new JaasConfig());   // 可选，自定义配置
lc.login();
```

`LoginContext.login()` 的流程：

```
LoginContext.login()
   │
   ├─ 1. 从配置中读取 "Sample" 对应的 LoginModule 列表
   │     com.sun.security.auth.module.Krb5LoginModule required;
   │     com.example.MyLoginModule optional;
   │
   ├─ 2. 依次实例化 LoginModule
   │
   ├─ 3. 阶段一：调用每个 module 的 login()
   │       ├─ 成功 → 记录为 "committed" 候选
   │       └─ 失败 → 记录为 "ignored" 候选
   │
   ├─ 4. 根据 required / requisite / sufficient / optional 计算整体结果
   │
   ├─ 5. 阶段二：调用 module 的 commit()
   │       └─ 把 Principal / Credential 塞进 Subject
   │
   └─ 6. 若整体失败 → 调用所有 module 的 abort()
```

**注意：`login()` 和 `commit()` 是两个独立阶段**——这是 JAAS 一个很巧妙的容错设计：所有 module 先在 `login()` 里完成凭证校验（此时**不修改 Subject**），全部通过之后才在 `commit()` 中统一写入。这样避免了"一半模块成功、一半失败"导致的 Subject 不一致。

### 3.2 LoginModule 生命周期

```java
public interface LoginModule {
    void initialize(Subject subject, CallbackHandler callbackHandler,
                    Map<String, ?> sharedState,
                    Map<String, ?> options);

    boolean login() throws LoginException;    // 阶段一：验证凭证
    boolean commit() throws LoginException;   // 阶段二：写入 Subject
    boolean abort() throws LoginException;    // 阶段二：撤销，清理
    boolean logout() throws LoginException;   // 登出：清理 Subject
}
```

四个方法的职责：

| 方法 | 何时调用 | 应该做什么 |
| --- | --- | --- |
| `initialize` | 实例化后立即调用 | 保存 subject、callbackHandler、共享状态和配置项 |
| `login` | 认证开始 | 获取凭证并**验证**，成功返回 true，但**不要修改 Subject** |
| `commit` | 整体认证成功 | 把 Principal / Credential 加入 Subject |
| `abort` | 整体认证失败 | 清理 `login` 阶段的中间状态 |
| `logout` | 主动登出 | 从 Subject 移除自己的 Principal 与 Credential |

### 3.3 一个完整的自定义 LoginModule

```java
public class JdbcLoginModule implements LoginModule {

    private Subject subject;
    private CallbackHandler callbackHandler;
    private Map<String, ?> sharedState;
    private Map<String, ?> options;

    private boolean succeeded;
    private final List<Principal> pendingPrincipals = new ArrayList<>();
    private String username;

    @Override
    public void initialize(Subject subject, CallbackHandler callbackHandler,
                           Map<String, ?> sharedState, Map<String, ?> options) {
        this.subject = subject;
        this.callbackHandler = callbackHandler;
        this.sharedState = sharedState;
        this.options = options;
    }

    @Override
    public boolean login() throws LoginException {
        NameCallback nameCb = new NameCallback("用户名: ");
        PasswordCallback passCb = new PasswordCallback("密码: ", false);

        try {
            callbackHandler.handle(new Callback[]{nameCb, passCb});
        } catch (IOException | UnsupportedCallbackException e) {
            throw new LoginException("回调失败: " + e.getMessage());
        }

        username = nameCb.getName();
        char[] password = passCb.getPassword();

        // 真正的校验：查库 / 比对 BCrypt
        boolean valid = userRepository.verify(username, password);
        Arrays.fill(password, '\0');   // 及时清除密码

        if (!valid) {
            succeeded = false;
            clear();
            throw new FailedLoginException("用户名或密码错误");
        }

        // 关键：这里只准备，不写入 Subject
        pendingPrincipals.add(new UserPrincipal(username));
        roleRepository.findRoles(username)
                .forEach(r -> pendingPrincipals.add(new RolePrincipal(r)));

        succeeded = true;
        return true;
    }

    @Override
    public boolean commit() throws LoginException {
        if (!succeeded) return false;
        subject.getPrincipals().addAll(pendingPrincipals);
        pendingPrincipals.clear();
        return true;
    }

    @Override
    public boolean abort() throws LoginException {
        if (!succeeded) return false;
        clear();
        return true;
    }

    @Override
    public boolean logout() throws LoginException {
        subject.getPrincipals().removeAll(pendingPrincipals);
        clear();
        return true;
    }

    private void clear() {
        pendingPrincipals.clear();
        username = null;
        succeeded = false;
    }
}
```

### 3.4 CallbackHandler：解耦"怎么拿到凭证"

`LoginModule` 不能假设凭证来自命令行、Web 表单还是 Kerberos ticket。所以 JAAS 定义了 `Callback` / `CallbackHandler`：

```
LoginModule ──handle(Callback[])──▶ CallbackHandler ──▶ 具体来源
```

常见 Callback：

| Callback | 用途 |
| --- | --- |
| `NameCallback` | 请求用户名 |
| `PasswordCallback` | 请求密码 |
| `ChoiceCallback` | 多选一（如选择认证方式） |
| `ConfirmationCallback` | 确认（Yes/No/Cancel） |
| `TextOutputCallback` | 输出提示信息 |
| `LanguageCallback` | 请求语言区域 |

命令行实现：

```java
public class DialogCallbackHandler implements CallbackHandler {
    @Override
    public void handle(Callback[] callbacks) throws IOException, UnsupportedCallbackException {
        for (Callback cb : callbacks) {
            if (cb instanceof NameCallback) {
                System.out.print(((NameCallback) cb).getPrompt());
                ((NameCallback) cb).setName(new BufferedReader(
                        new InputStreamReader(System.in)).readLine());
            } else if (cb instanceof PasswordCallback) {
                System.out.print(((PasswordCallback) cb).getPrompt());
                char[] pw = System.console().readPassword();
                ((PasswordCallback) cb).setPassword(pw);
            } else {
                throw new UnsupportedCallbackException(cb, "不支持的回调类型");
            }
        }
    }
}
```

**这个设计的意义**：同一个 `LoginModule` 既可以在命令行用，也可以在 Web 容器里用（Web 端实现一个从 HttpServletRequest 取参数的 CallbackHandler 即可）。

## 四、配置：登录模块怎么被找到

### 4.1 配置文件语法

默认配置文件是 `$JAVA_HOME/conf/security/jaas.conf`（旧版本是 `lib/security/`）：

```
Sample {
    com.example.JdbcLoginModule required
        debug=true
        driver="com.mysql.cj.jdbc.Driver"
        url="jdbc:mysql://localhost:3306/auth";
    com.example.AuditLoginModule optional;
};
```

语法要点：

- `模块类名 控制标志 [选项...];`
- 标志后没有 `=` 的键值对是**选项（options）**，会作为 `initialize()` 的 `options` 参数传入；
- 键值对用 `k="v"` 形式，支持多行续接（行尾用 `\`）。

### 4.2 四种控制标志（Control Flag）

这是 JAAS 设计的精髓，也是面试高频点：

| 标志 | 成功时 | 失败时 | 说明 |
| --- | --- | --- | --- |
| `required` | 继续 | **整体立即失败** | 必须成功 |
| `requisite` | 继续 | **整体立即失败** | 必须成功，但失败时不再执行后续 module |
| `sufficient` | **整体立即成功** | 继续下一个 | 成功即短路，失败不影响 |
| `optional` | 继续 | 继续 | 成败都不影响整体 |

更精确的语义（来自官方文档）：

- **`required`**：该模块必须成功。失败 → 整体认证失败（其余模块的 `commit` 不会执行）。
- **`requisite`**：该模块必须成功。失败 → 立即返回失败，**不再继续处理后续模块**（区别在这里：`required` 在判定阶段是"继续执行其他模块，但最终失败"）。
- **`sufficient`**：只要它成功，且之前没有失败的 `required`/`requisite`，**整体立即成功**，后续模块直接跳过。
- **`optional`**：成功则计入，失败则忽略。

典型组合：

```
Sample {
    com.example.TokenLoginModule  sufficient;   # 有 token 就直接过
    com.example.JdbcLoginModule   required;     # 没有 token 就走账密，必须成功
    com.example.MfaLoginModule    optional;     # 有二次验证就校验
};
```

### 4.3 运行时指定配置

```bash
java -Djava.security.auth.login.config=/etc/app/jaas.conf -jar app.jar
```

或在代码里显式传入：

```java
Configuration config = new Configuration() {
    @Override
    public AppConfigurationEntry[] getAppConfigurationEntry(String name) {
        Map<String, String> options = new HashMap<>();
        options.put("driver", "com.mysql.cj.jdbc.Driver");
        return new AppConfigurationEntry[]{
            new AppConfigurationEntry(
                "com.example.JdbcLoginModule",
                AppConfigurationEntry.LoginModuleControlFlag.REQUIRED,
                options)
        };
    }
};
LoginContext lc = new LoginContext("Sample", subject, callbackHandler, config);
```

## 五、授权：Policy 与 Permission

JAAS 的授权建立在 Java 的**沙箱模型**之上。`Policy` 决定"哪个代码来源（CodeSource）+ 哪个身份（Principal）"拥有"哪些权限（Permission）"。

策略文件示例：

```
grant codeBase "file:/opt/app/lib/-" {
    permission java.io.FilePermission "/data/-", "read";
};

grant codeBase "file:/opt/app/lib/-",
      principal com.example.RolePrincipal "ADMIN" {
    permission java.io.FilePermission "/data/-", "read,write,delete";
    permission java.net.SocketPermission "*:80", "connect";
};
```

第二条的意思是：**来自该 codeBase 且 Subject 中带有 ADMIN 角色**的代码，才拥有写权限。判断方式：

```java
Subject.doAs(subject, (PrivilegedExceptionAction<Void>) () -> {
    // 这里会触发 AccessController 检查
    Files.delete(Paths.get("/data/tmp.txt"));
    return null;
});
```

> 注意：从 JDK 17 开始 `SecurityManager` 被废弃，JDK 24 正式移除（JEP 486），`AccessController` 也随之失效。这意味着 **JAAS 的"授权"部分在现代 Java 中基本失去了运行时支撑**，但"认证"部分（`LoginModule`）仍然是 Kerberos/SASL 等协议的标准接入方式。

## 六、JAAS 在 JDK 中的实际使用场景

虽然 Spring Security 抢走了 Web 应用市场，JAAS 至今仍活跃在这些地方：

| 场景 | 使用方式 |
| --- | --- |
| **Kerberos 认证** | `Krb5LoginModule`，Hadoop / Kafka / HBase 的安全模式全靠它 |
| **LDAP 认证** | `LdapLoginModule`，企业内网目录服务 |
| **SASL** | `SaslClient` / `SaslServer` 通过 `CallbackHandler` 与 JAAS 集成 |
| **JMX 安全** | 远程 JMX 的认证授权 |
| **Java Web Start / Applet** | 历史场景（已废弃） |
| **Hadoop 安全** | `UserGroupInformation`（UGI）就是 JAAS `Subject` 的封装 |

**Kafka 的 SASL/Kerberos 配置**就是典型的 JAAS 应用：

```properties
sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required \
    useKeyTab=true \
    storeKey=true \
    keyTab="/etc/kafka/kafka.keytab" \
    principal="kafka/broker1@EXAMPLE.COM";
```

**Hadoop 的 UGI**（`UserGroupInformation`）内部就是一个 `Subject`：

```java
UserGroupInformation ugi = UserGroupInformation.loginUserFromKeytabAndReturnUGI(
        "hdfs@EXAMPLE.COM", "/etc/hadoop/hdfs.keytab");
ugi.doAs((PrivilegedExceptionAction<Void>) () -> {
    // 以 hdfs 身份访问 HDFS
    return null;
});
```

## 七、为什么 Spring Security 赢了

| 维度 | JAAS | Spring Security |
| --- | --- | --- |
| 定位 | 通用认证授权 SPI | Web 应用安全框架 |
| 认证入口 | `LoginContext.login()` | `AuthenticationManager` / `FilterChain` |
| 身份模型 | `Subject` + `Principal` | `Authentication` + `GrantedAuthority` |
| 授权 | `Policy` + `Permission`（已废弃） | `AccessDecisionManager` / `AuthorizationManager` |
| 与 Web 集成 | 需要自己写 CallbackHandler | 原生 Filter 链 |
| 会话管理 | 无 | Session / Remember-Me / CSRF |
| 生态 | 仅 JDK 内置 | OAuth2、OIDC、JWT、SAML 全覆盖 |
| 可测试性 | 差（静态上下文） | 好（全面可注入） |

三个核心原因：

1. **Web 场景适配差**：JAAS 面向"进程内代码沙箱"，而 Web 安全需要处理 HTTP 语义（Session、CSRF、CORS、跨域）；
2. **授权模型与 JDK 绑定过深**：`Policy` 依赖 `SecurityManager`，而后者已被 JDK 移除；
3. **Spring 的 DI 与 AOP 让安全逻辑可组合**：注解式权限（`@PreAuthorize`）、方法级安全、过滤器链，开发体验碾压基于 JAAS 配置文件的方式。

**但这不是说 JAAS 没用了**：在**非 Web 的企业集成场景**（Hadoop 生态、Kerberos 单点登录、ZooKeeper SASL），JAAS 依然是标准答案。

## 八、面试高频追问

**Q1：`login()` 和 `commit()` 为什么分开？**

为了实现"全部校验通过后再统一写入身份"。`login()` 只做验证、不改 `Subject`；`commit()` 才写入 Principal/Credential。这样当有多个 LoginModule 时，不会出现"部分模块已写入身份、部分失败"的中间状态。

**Q2：四种控制标志的区别？**

`required` 必须成功（失败则整体失败但继续执行其他模块）；`requisite` 必须成功（失败立即中断后续模块）；`sufficient` 成功即短路整体成功；`optional` 成败不影响。核心区别在**失败时的中断行为**和**成功时的短路行为**。

**Q3：`Subject` 里的凭证为什么分公有和私有？**

公有凭证（如公钥证书）可被任何代码读取；私有凭证（密码、私钥）只有在 `AccessControlContext` 中拥有相应权限的代码才能访问，防止恶意代码窃取密码。

**Q4：`Subject.doAs` 的作用？**

把 `Subject` 绑定到当前线程的 `AccessControlContext`，使后续代码在"以该身份运行"的上下文中执行，从而让 `Policy` 能够基于 Principal 做授权判断。

**Q5：JAAS 为什么现在用得少了？**

三个原因：`SecurityManager`/`AccessController` 在 JDK 17 废弃、JDK 24 移除，导致 JAAS 授权能力失去运行时基础；Web 领域被 Spring Security 全面取代；JAAS 的配置文件方式静态且难以测试。但在 Kerberos/SASL/Hadoop 场景仍然不可替代。

**Q6：`LoginModule` 里的 `sharedState` 有什么用？**

它是在同一 `LoginContext` 的所有 LoginModule 之间共享的 Map。典型用法：第一个模块完成某种昂贵的认证后，把结果放进 `sharedState`，后续模块直接复用，避免重复认证（比如 SSO 场景）。

**Q7：怎么实现"多因素认证"？**

配置多个 LoginModule，前一个用 `sufficient`（如 Token），后面用 `required`（如密码），再用 `sharedState` 传递用户名。但要注意 `sufficient` 短路机制下后续模块可能不执行——真正的多因素认证更推荐在一个 LoginModule 内部串联校验，或用 `required` + `required` 组合。

## 九、总结

| 概念 | 一句话总结 |
| --- | --- |
| `Subject` | 身份主体，含多个 Principal 与两类凭证 |
| `Principal` | 具体身份（用户、角色、组、Kerberos 主体） |
| `LoginContext` | 认证入口，协调多个 LoginModule 的两阶段执行 |
| `LoginModule` | 认证 SPI，`login` 验证、`commit` 写入、`abort` 清理 |
| `CallbackHandler` | 解耦凭证获取方式，让模块与来源无关 |
| Control Flag | `required` / `requisite` / `sufficient` / `optional` 决定组合语义 |
| `Policy` | 基于 CodeSource + Principal 的授权，随 SecurityManager 一起日落 |

JAAS 是 Java 世界里**第一个把认证授权抽象成 API 的尝试**，它留下的 `Subject` / `Principal` 概念至今仍是很多安全框架的建模基础。它没有赢得 Web，但它赢得了企业集成——理解它，理解的是 Java 安全设计的起点。

---

**参考**

- Oracle 官方文档：Java Authentication and Authorization Service (JAAS) Reference Guide
- JEP 486: Permanently Disable the Security Manager
- Hadoop `UserGroupInformation` 源码
