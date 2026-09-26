---
title: 【Java 安全】SecurityManager 深度解析：沙箱模型、权限检查原理与 JDK 17/24 的废弃之路
date: 2026-09-26 08:00:00
tags:
  - Java
  - 安全
  - JVM
  - 面试
categories:
  - Java
  - Java 核心
author: 东哥
---

# 【Java 安全】SecurityManager 深度解析：沙箱模型、权限检查原理与 JDK 17/24 的废弃之路

## 面试官：SecurityManager 是干嘛的？为什么 JDK 要把它废弃掉？

这是个非常"有味道"的问题。十年前它是 Java 安全体系的基石，现在它是一具"还没完全下葬的尸体"。答好这一题，能同时考察你对 JVM 安全模型、类加载器、栈帧权限检查以及 Java 平台演进方向的理解。

先说结论：**SecurityManager 是 Java 早期为了在同一个 JVM 内运行不可信代码而设计的沙箱机制，它通过"权限检查 + 调用栈回溯"来决定一段代码能不能做一个敏感操作。由于性能开销大、绕过手段多、与现代容器化/进程隔离的部署模型不匹配，它在 JDK 17（JEP 411）被标记为 deprecated for removal，并在 JDK 24（JEP 486）被永久禁用。**

下面我们把这个结论拆开，一层层往下挖。

## 一、SecurityManager 解决的到底是什么问题

1995 年 Java 诞生时，最大的卖点之一是 **Applet**：从网页下载一段字节码，在你本机 JVM 里跑。这就带来一个根本矛盾：

> 我要执行你的代码，但我不能信任你的代码。

传统做法是操作系统级别的进程隔离，但 Applet 希望"轻量、快速、无进程启动开销"。于是 Java 给出的答案是**在同一个 JVM 进程内做细粒度沙箱**：

- 代码按来源分成不同的 **CodeSource**（从哪个 URL 加载、有没有签名）；
- 每个 CodeSource 对应一个 **ProtectionDomain**，绑定一组 **Permission**；
- 执行敏感操作（读文件、开 socket、反射、加载本地库）前，检查当前调用链上**所有**代码是否都拥有该权限。

这就是"栈式权限检查"（stack-based access control）。

```java
// 敏感操作内部大致长这样
public static SecurityManager getSecurityManager() {
    return security;
}

// FileInputStream 构造时会做检查
SecurityManager security = System.getSecurityManager();
if (security != null) {
    security.checkRead(name);
}
```

如果 `security == null`，也就是没有安装 SecurityManager，那么所有检查直接短路返回——**这就是为什么很多老代码虽然写了 checkPermission，实际上默认根本没生效**。

## 二、核心组件拆解

| 组件 | 作用 | 关键点 |
| --- | --- | --- |
| `SecurityManager` | 权限检查入口 | 每个 checkXxx 最终委托给 `AccessController.checkPermission` |
| `AccessController` | 权限判定引擎 | 遍历调用栈，逐个 ProtectionDomain 检查 |
| `ProtectionDomain` | 代码与权限的绑定 | 由 CodeSource + PermissionCollection + ClassLoader 决定 |
| `Policy` | 权限策略来源 | 默认从 `java.policy` 或 `-Djava.security.policy` 加载 |
| `Permission` | 权限抽象 | `FilePermission`、`SocketPermission`、`RuntimePermission` 等 |
| `AccessControlContext` | 上下文快照 | `doPrivileged` 与线程继承的关键 |

### 权限检查的真实链路

```java
System.setSecurityManager(new SecurityManager());
System.out.println("set ok");

try {
    new FileInputStream("/etc/passwd");
} catch (SecurityException e) {
    // java.security.AccessControlException: access denied
    e.printStackTrace();
}
```

调用链大致是：

```
FileInputStream.<init>
  -> SecurityManager.checkRead(file)
    -> SecurityManager.checkPermission(new FilePermission(file, "read"))
      -> AccessController.checkPermission(perm)
        -> AccessControlContext.checkPermission(perm)
          -> 遍历 ProtectionDomain[]，逐个 implies(perm)
```

`AccessController.checkPermission` 会从**当前线程的栈顶往下走**，收集每一个栈帧所属类的 ProtectionDomain，然后要求**所有** ProtectionDomain 都 `implies(perm) == true` 才放行。任何一个环节没有权限，就抛 `AccessControlException`。

注意这里的设计哲学：**"取交集"而不是"取并集"**。也就是说，即使是你自己完全受信任的代码，只要它被不可信代码"调用"到了，权限检查就会因为不可信那一层而失败。这正是沙箱的核心。

### ProtectionDomain.implies 的判断过程

```java
// 简化后的逻辑
public boolean implies(Permission perm) {
    if (hasAllPerm) return true;          // 拥有 AllPermission
    if (!staticPermissions.implies(perm)) return false;
    // 再检查动态绑定的权限（Policy 可动态变更）
    if (dynamicPermissions != null && !dynamicPermissions.implies(perm)) return false;
    return true;
}
```

`staticPermissions` 来自策略文件在类加载时算出的权限集合；`dynamicPermissions` 用于支持 `Policy.refresh()` 后的动态授权。**这也是历史上一个著名的坑：权限判定结果会被缓存/依赖类加载时机，导致行为难以预测。**

## 三、doPrivileged：为什么它是沙箱的"逃生舱"

上面的"取交集"规则太严格了。假设 `java.io` 的类要读一个系统文件，它被 Applet 调用，那么按交集规则也会被拒绝。于是有了 `AccessController.doPrivileged`：

```java
AccessController.doPrivileged((PrivilegedAction<String>) () -> {
    // 这里只检查"我"（以及我上层的调用者）有没有权限，
    // 不再检查更下面的栈帧
    return System.getProperty("user.home");
});
```

它的语义是：**"截断调用栈"**。执行到 doPrivileged 边界时，权限检查不再往下（栈底方向）继续，而是只看 doPrivileged 调用者及其上方（受信任）的帧。

- 正确使用：受信任的库代码在完成敏感操作后，把**结果**返回给不可信代码，绝不把敏感对象本身泄漏出去。
- 错误使用（经典漏洞模式）：`return System.getSecurityManager();` 或者返回 `File` 句柄，让不可信代码拿着特权对象绕过检查。

```java
// 反例：特权边界内把敏感能力泄漏出去
static class Leak {
    static FileInputStream fs;
    static FileInputStream open(final String path) {
        return AccessController.doPrivileged(
            (PrivilegedAction<FileInputStream>) () -> {
                try {
                    Leak.fs = new FileInputStream(path); // 泄漏！
                    return Leak.fs;
                } catch (Exception e) { return null; }
            });
    }
}
```

**面试追问：doPrivileged 一定安全吗？** 不一定。只要被保护的资源能被"传递"出去，边界就形同虚设。这是安全编码中最容易犯的错。

## 四、代价：为什么它注定被淘汰

### 1. 性能开销

每次敏感操作都要遍历整个调用栈。反射、类加载、文件、网络、线程、系统属性……全部要查。深层调用栈 + 高频操作 = 明显开销。

对比一下（示意，不代表精确基准）：

| 操作 | 无 SM | 有 SM |
| --- | --- | --- |
| 创建 FileInputStream | 快 | 需要栈遍历 + 策略判定 |
| 反射 Method.invoke | 快 | 叠加多次 RuntimePermission 检查 |
| ClassLoader.defineClass | 快 | 多次权限检查 + 上下文快照 |
| Thread 创建 | 快 | modifyThreadGroup 等检查 |

### 2. 绕过手段层出不穷

- 反射把私有字段/方法直接打开（`setAccessible`）；
- 自定义 ClassLoader 加载一份"合法"的类；
- 通过 JNI/Unsafe 绕过 Java 层检查；
- 利用 doPrivileged 边界泄漏；
- 利用策略文件的宽松配置（现实中最常见，`grant { permission java.security.AllPermission; }`）。

一句话：**基于同进程的沙箱，只要攻击者能执行任意代码，逃逸只是时间问题。**

### 3. 与部署模型不匹配

现代 Java 应用跑在 Docker/K8s/Pod 里。真要做隔离，用：

- 进程隔离 + 容器（namespace/cgroup/seccomp/AppArmor）
- 独立 JVM / 独立服务
- 最小权限的运行用户
- 内核级隔离（gVisor、Kata、Firecracker）

这些方案的隔离强度、可维护性、可观测性都远好于 JVM 内的 SecurityManager。

### 4. 维护负担

JDK 内部大量 `System.getSecurityManager()` 判断散布在各处，调用点难以彻底移除，且长期处于"默认关闭"状态，实际上早已名存实亡——**安全问题只是"看起来被保护了"**。

## 五、废弃时间线（面试高频）

| 版本 | 事件 | 影响 |
| --- | --- | --- |
| JDK 1.0 | 引入 SecurityManager | Applet 沙箱基础 |
| JDK 9 | 模块系统 JPMS 引入 | 强封装成为新的封装边界 |
| JDK 17 | JEP 411：deprecated for removal | 出现 `@Deprecated(forRemoval=true)` 警告 |
| JDK 18/19+ | 逐步弃用相关 API | `System.setSecurityManager` 等开始警告 |
| JDK 24 | JEP 486：permanently disable | 相关 API 调用直接抛异常/无效果 |

JDK 24 之后的行为可以概括为：

- `System.setSecurityManager` 无法再安装（除非配合特殊的启动参数开启"仍允许"的过渡模式）；
- `System.getSecurityManager()` 不再返回可用实例；
- `AccessController` 相关方法的行为退化；
- 与 SM 强耦合的旧 API（部分 RMI 用法、`Policy` 相关）基本失去实际意义。

**面试追问：JDK 24 里 setSecurityManager 会怎样？** 默认情况下它不再能生效，调用会被拒绝（典型实现是抛 `UnsupportedOperationException`）；官方保留了过渡用的兼容开关，但明确是临时的、不推荐使用的。

**面试追问：为什么用"permanently disable"而不是"删除 API"？** 因为大量生态代码还在调用这些方法（尤其是老中间件、老测试框架）。直接删除会导致二进制不兼容和大量链接期错误；永久"空实现/禁用"可以在保证源码兼容的前提下，把安全语义彻底移除。

## 六、替代方案怎么选

| 目标 | 推荐方案 | 说明 |
| --- | --- | --- |
| 防插件越权访问系统资源 | 独立进程 + IPC/RPC | 最彻底，工程成本可控 |
| 限制某段代码只能做特定事 | 容器 + 最小权限用户 + seccomp | 内核级强隔离 |
| 防止反射破坏封装 | JPMS 强封装（module-info + opens 控制） | JDK 9+ 的正统替代 |
| 沙箱化不可信脚本 | 独立 JVM / WASM / 受限解释器 | 不要在同 JVM 里跑不可信代码 |
| 运行第三方 Java 插件 | 自定义 ClassLoader + 白名单 API + 独立进程 | ClassLoader 只能做"命名空间隔离"，不是安全边界 |
| 网络/资源访问控制 | 代理层、网关、Sidecar、ServiceMesh | 用架构而非语言特性解决 |

特别注意：**自定义 ClassLoader 永远不等于安全沙箱**。它能做类可见性隔离（比如让插件看不到你的内部类），但无法阻止插件拿到 `Class.forName("java.lang.Runtime")`（除非 JDK 自身限制，而 SM 已经没了）。要真正安全，必须靠进程/容器边界。

## 七、代码：一个"类沙箱"的正确姿势

假设你要跑一段用户自定义的规则代码：

```java
public final class RuleRunner {
    public static Object run(String className, String method, Object... args)
            throws Exception {
        // 1) 独立 URLClassLoader，只暴露"规则 API"包给你的插件
        URLClassLoader pluginLoader = new URLClassLoader(
                new URL[]{ new File("/opt/plugins").toURI().toURL() },
                RuleRunner.class.getClassLoader() /* 或者一个受限的父加载器 */);

        Class<?> clazz = pluginLoader.loadClass(className);

        // 2) 只允许实现约定接口
        RuleApi rule = (RuleApi) clazz.getDeclaredConstructor().newInstance();

        // 3) 真正的隔离靠外部：进程 / 容器 / 资源限额
        return rule.evaluate(args);
    }
}
```

再叠加外部约束：

```yaml
# k8s 里跑不可信插件的 Pod 片段
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
resources:
  limits: { cpu: "500m", memory: "512Mi" }
```

**关键认知：隔离强度由最外层决定。语言层的沙箱只能是"防君子"，容器和进程边界才是"防小人"。**

## 八、迁移清单：老项目怎么办

1. 全局搜索这些关键字：`setSecurityManager`、`getSecurityManager`、`checkPermission`、`AccessController`、`doPrivileged`、`java.policy`、`Policy.setPolicy`；
2. 区分用途：
   - 若是**安全用途** → 迁移到容器/进程隔离，删除 SM 相关代码；
   - 若是**代码风格/误用**（例如为了"禁止 System.exit"）→ 用 `SecurityManager` 之外的方式，比如自定义 ClassLoader + 字节码校验、或者直接接受该风险；
3. 检查依赖：老版本 RMI、老版本 Tomcat/WebLogic 的安全配置、部分测试框架、老版 Spring 的 `SecurityManager` 分支；
4. 打开 `-Djava.security.manager=allow`（过渡期）并观察日志，确认无强依赖后再彻底移除；
5. CI 里加上 `--release 21/24` 编译告警开关，把 forRemoval 警告纳入质量门禁。

## 九、面试高频追问速查

**Q1：SecurityManager 默认是开启的吗？**
不是。默认 `System.getSecurityManager()` 返回 null，所以大量 `checkXxx` 形同虚设。要显式 `System.setSecurityManager(new SecurityManager())` 才生效。

**Q2：为什么说它是"栈式"权限检查？**
因为 `AccessController.checkPermission` 会遍历当前调用栈的每一帧，逐帧确认 ProtectionDomain 是否拥有该权限，全部满足才放行。

**Q3：doPrivileged 的作用一句话说清？**
截断权限检查的栈遍历范围，让受信任代码可以在不被下层不可信代码"拖累"的情况下执行敏感操作。前提是**不得把敏感能力泄漏出去**。

**Q4：不用 SecurityManager，怎么控制第三方库的文件访问？**
靠操作系统/容器：只挂载它需要的目录、用只读文件系统、独立运行用户、seccomp 限制系统调用。语言层做不到可靠控制。

**Q5：JPMS 能替代 SecurityManager 吗？**
不能完全替代。JPMS 解决的是**封装性和依赖可见性**（代码组织层面的访问控制），不是"恶意代码的权限控制"。它能让反射被限制在 `opens`/`exports` 允许的范围内，但挡不住进程内的资源滥用。

## 总结

- SecurityManager = **同进程细粒度沙箱**，核心是 ProtectionDomain + Policy + 调用栈权限检查（取交集）。
- `doPrivileged` 是权限检查的"栈截断"，也是历史上漏洞最集中的地方。
- 它被废弃的根本原因是：**性能开销 + 绕过容易 + 与容器化部署模型错位**。
- JDK 17 标记 for removal，JDK 24 永久禁用；替代方案是容器/进程隔离、JPMS 强封装、独立 JVM 或 WASM。
- 面试回答的加分点在于：能说清"为什么语言层沙箱靠不住"，并给出分层隔离的工程方案。
