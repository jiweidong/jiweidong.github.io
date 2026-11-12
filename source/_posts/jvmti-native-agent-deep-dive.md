---
title: 【JVM 底层】JVMTI 与 Native Agent 深度解析：从 Capabilities 到 Attach、堆遍历与字节码重转换
date: 2026-11-12 08:15:00
tags:
  - JVM
  - JVMTI
  - Agent
  - Java
categories:
  - JVM
author: 东哥
---

# 【JVM 底层】JVMTI 与 Native Agent 深度解析：从 Capabilities 到 Attach、堆遍历与字节码重转换

## 前言

面试官问："Java Agent 是怎么把 `main` 方法增强的？" 大多数人能答出 `premain` / `agentmain` + `Instrumentation` + `ClassFileTransformer`。但如果再追一句："`Instrumentation` 又是谁实现的？JVM 怎么知道要回调你？" 就答不上来了。

答案在 **JVMTI（Java Virtual Machine Tool Interface）**——JVM 暴露给 native 代码的一套 C 接口。Java Agent 只是 JVMTI 的一层薄封装：`Instrumentation.redefineClasses` 最终落到 `RedefineClasses`，`retransformClasses` 落到 `RetransformClasses`。

本文从 JVMTI 的运行时模型讲起，手写一个能遍历堆并输出对象直方图的 native agent，再讲清楚它与 Instrumentation、JFR、debug 接口的分工。

---

## 一、五层工具接口的分工

| 层 | 接口 | 语言 | 典型使用者 | 能做什么 |
|---|---|---|---|---|
| **JVMTI** | `jvmtiEnv` | C/C++ | APM、profiler、debugger | 几乎所有：断点、堆遍历、类重定义、线程事件 |
| **JPLIS（java.lang.instrument）** | `Instrumentation` | Java | Java Agent、SkyWalking | 类转换、redefine/retransform、getObjectSize |
| **JFR** | `jdk.jfr` | Java/C | JFR 事件、JMC | 低开销采样、自定义事件 |
| **JMX** | `MBeanServer` | Java | 监控 | 应用级指标、管理操作 |
| **Serviceability Agent（SA）** | `sun.jvm.hotspot` | Java | jhsdb | 离线 core dump 分析 |

关系是：**JVMTI 是地基，其余都是它的上层建筑**。JPLIS 本质是 JVM 内置的一个 JVMTI agent（`libinstrument.so`），它注册 `ClassFileLoadHook` 回调，把字节码交给 Java 层的 `ClassFileTransformer`。

---

## 二、JVMTI 的运行时模型

### 2.1 三件套：环境、能力、事件

```c
jvmtiEnv *jvmti;              // 每个 agent 一个环境（可多个）
jvmtiCapabilities caps;       // 你申请的能力
jvmtiEventCallbacks callbacks;// 你关心的事件
```

关键点：**能力必须先申请（`AddCapabilities`），否则对应接口返回 `JVMTI_ERROR_MISSING_CAPABILITY`**。这不是形式主义——每个能力都有真实开销，JVM 需要提前改运行时行为。比如一旦有人申请 `can_generate_breakpoint_events`，JIT 就必须在方法入口保留可打断的指令位置。

### 2.2 常用 Capabilities 与代价

| Capability | 用途 | 开销 |
|---|---|---|
| `can_tag_objects` | 给对象打 tag（堆分析必备） | 低（存对象头旁的 side table） |
| `can_generate_field_modification_events` | 字段写 watchpoint | **高**（取消 JIT 对该字段的优化） |
| `can_generate_method_entry_events` | 方法进出 | 高（影响内联） |
| `can_redefine_classes` | 替换方法体 | 中（触发 deopt） |
| `can_retransform_classes` | 重新走 ClassFileLoadHook | 中 |
| `can_get_bytecodes` | 读取方法字节码 | 低 |
| `can_access_local_variables` | 读栈上局部变量 | 高（需 safepoint 且阻止优化） |
| `can_suspend` | 挂起线程 | 高（易死锁） |

> 经验：APM 只申请 `can_redefine_classes` + `can_retransform_classes` + `can_get_bytecodes` 就够；一旦申请 `can_generate_field_modification_events`，你的应用会立刻掉 20%~40% 性能。

---

## 三、Agent 生命周期

```
JVM 启动: -agentpath:/path/libagent.so=opt1,opt2
   → Agent_OnLoad(JavaVM *vm, char *options, void *reserved)
   → ... 应用运行 ...
   → Agent_OnUnload(JavaVM *vm)

运行期: jcmd <pid> JVMTI.agent_load /path/libagent.so opt1
   → Agent_OnAttach(JavaVM *vm, char *options, void *reserved)
   → ... 
   → Agent_OnUnload
```

`Agent_OnLoad` 里拿不到 `JNIEnv`（线程还没 attach），要用 `vm->GetEnv((void**)&jvmti, JVMTI_VERSION_1_2)`。`Agent_OnAttach` 同样。两者的区别是：OnLoad 阶段不能做耗时操作（会拖慢启动），OnAttach 阶段不能假设类已加载完毕。

---

## 四、手写一个堆直方图 Agent

目标：attach 到运行中的 JVM，遍历所有可达对象，按类统计实例数与浅大小。

```c
#include <jni.h>
#include <jvmti.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAX_CLASSES 4096

typedef struct {
    jclass  klass;
    char    name[256];
    jlong   count;
    jlong   size;
} ClassStat;

static ClassStat g_stats[MAX_CLASSES];
static int       g_nstat = 0;
static jvmtiEnv *g_jvmti;

// 回调：每遇到一个对象调用一次
static jvmtiIterationControl JNICALL
on_heap_object(jlong class_tag, jlong size, jlong *tag_ptr,
               void *user_data) {
    // class_tag 由 SetTag 阶段写入，这里直接当数组下标用
    int idx = (int) class_tag;
    if (idx >= 0 && idx < g_nstat) {
        g_stats[idx].count++;
        g_stats[idx].size += size;
    }
    return JVMTI_ITERATION_CONTINUE;
}

JNIEXPORT jint JNICALL
Agent_OnAttach(JavaVM *vm, char *options, void *reserved) {
    jvmtiCapabilities caps;
    memset(&caps, 0, sizeof(caps));
    caps.can_tag_objects = 1;   // GetLoadedClasses 不需要额外能力，遍历堆的 tag 需要

    if ((*vm)->GetEnv(vm, (void **) &g_jvmti, JVMTI_VERSION_1_2) != JNI_OK)
        return JNI_ERR;

    if ((*g_jvmti)->AddCapabilities(g_jvmti, &caps) != JVMTI_ERROR_NONE)
        return JNI_ERR;

    // 1) 枚举类，给每个 jclass 一个 tag，并记录名字
    jint nclasses = 0;
    jclass *classes = NULL;
    (*g_jvmti)->GetLoadedClasses(g_jvmti, &nclasses, &classes);

    for (jint i = 0; i < nclasses && g_nstat < MAX_CLASSES; i++) {
        char *sig = NULL;
        if ((*g_jvmti)->GetClassSignature(g_jvmti, classes[i], &sig, NULL) != JVMTI_ERROR_NONE)
            continue;
        g_stats[g_nstat].klass = classes[i];
        snprintf(g_stats[g_nstat].name, sizeof(g_stats[g_nstat].name), "%s", sig);
        g_stats[g_nstat].count = 0;
        g_stats[g_nstat].size  = 0;
        // 用 tag 记录类在数组中的下标，供 heap 遍历时回填
        (*g_jvmti)->SetTag(g_jvmti, classes[i], (jlong) g_nstat);
        (*g_jvmti)->Deallocate(g_jvmti, (unsigned char *) sig);
        g_nstat++;
    }

    // 2) 遍历堆（只走可达对象，等价于 live set）
    jvmtiHeapCallbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.heap_iteration_callback = on_heap_object;
    (*g_jvmti)->IterateOverReachableObjects(g_jvmti, NULL, NULL, &cb, NULL);

    // 3) 排序并输出，写文件避免 attach 时 stdout 丢失
    FILE *f = fopen("/tmp/heap_histo.txt", "w");
    for (int i = 0; i < g_nstat; i++) {
        if (g_stats[i].count == 0) continue;
        fprintf(f, "%-70s %10lld %12lld\n",
                g_stats[i].name,
                (long long) g_stats[i].count,
                (long long) g_stats[i].size);
    }
    fclose(f);
    return JNI_OK;
}
```

编译（Linux/macOS 分别用 .so/.dylib）：

```bash
gcc -shared -fPIC -O2 -o libhisto.so histo.c \
    -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux"
```

加载：

```bash
jcmd $(pgrep -f my-app) JVMTI.agent_load /tmp/libhisto.so
sort -k3 -nr /tmp/heap_histo.txt | head -20
```

三个技术要点：

1. **`IterateOverReachableObjects` 是"存活对象"遍历**，会触发一次 safepoint（JDK 里是 VM operation），对 4GB 堆大约 200ms~1s 停顿。生产上要在低峰执行。
2. **`SetTag` 必须对 `jclass` 也设置**，否则 `heap_iteration_callback` 拿到的 `class_tag` 是 0，全部统计到第一个类上——这是新手最常踩的坑。
3. **tag 的唯一性由你保证**。JVMTI 不校验 tag 冲突，两个类打同一个 tag 会导致统计错乱。

---

## 五、Attach 机制的完整链路

`jcmd ... JVMTI.agent_load` 背后是一条 Unix domain socket：

```
jcmd 进程
  → AttachListener（目标 JVM 内的监听线程，socket 在 /tmp/.java_pid<pid>）
  → 发送 "load" 命令 + .so 路径
  → 目标 JVM dlopen(.so) 并调用 Agent_OnAttach
```

Java 侧等价写法：

```java
VirtualMachine vm = VirtualMachine.attach(String.valueOf(pid));
try {
    vm.loadAgentPath("/tmp/libhisto.so", "opt=1");
} finally {
    vm.detach();
}
```

⚠️ 生产常见失败：

- 容器内 `/tmp` 被设为 `noexec` 或 attach socket 不可写 → `AttachNotSupportedException`。
- JDK 21+ 默认开启 `-XX:+EnableDynamicAgentLoading`? 实际上**动态加载 agent 从 JDK 21 起会打印警告，JDK 以后版本将默认拒绝**，需要显式 `-XX:+EnableDynamicAgentLoading`。
- `jcmd` 与目标 JVM 用户不同 → socket 权限拒绝。

---

## 六、Java Agent 与 JVMTI 的对应关系

| Java 侧 API | JVMTI 接口 | 说明 |
|---|---|---|
| `Instrumentation.redefineClasses` | `RedefineClasses` | 只能改方法体，不能加字段/方法 |
| `Instrumentation.retransformClasses` | `RetransformClasses` | 重新触发 `ClassFileLoadHook` |
| `ClassFileTransformer.transform` | `ClassFileLoadHook` 回调 | 拿到原始字节码返回新字节码 |
| `Instrumentation.getAllLoadedClasses` | `GetLoadedClasses` | |
| `Instrumentation.getObjectSize` | `GetObjectSize` | 浅大小，不含引用对象 |
| `Instrumentation.isModifiableClass` | — | 靠 `can_redefine_classes` 逐类探测 |

一次典型的 APM 埋点流程：

```
agentmain → retransformClasses(target) 
         → JVM 触发 ClassFileLoadHook 
         → transformer 用 ASM 插桩 
         → JVM 用新字节码替换旧方法体 
         → 所有已存在实例立即生效（方法调用走新入口）
         → 触发 deopt，热点方法重新 JIT
```

注意最后两步：**retransform 会让方法掉出 JIT 优化状态**，大范围 retransform 会造成一次明显的性能抖动（俗称 "agent 一挂，TP99 起飞"）。

---

## 七、与 JFR / async-profiler / debugger 的边界

- **JFR**：走 JVMTI 的采样与事件机制，但做了极致优化（线程本地缓冲、无锁写入），开销 <1%，适合长期开启。
- **async-profiler**：用 `AsyncGetCallTrace`（HotSpot 内部非标准接口）+ perf_events，避免 safepoint 偏差，是火焰图首选。
- **debugger（jdb/IDEA）**：JVMTI 的 `can_generate_breakpoint_events` + `SuspendThread`，开销最大，**永远不要在生产开**。
- **JVMTI agent**：适合做"一次性诊断"（堆直方图、类加载溯源、方法耗时插桩），不适合常驻高频事件。

---

## 八、生产使用清单

1. 只在需要时 attach，用完 `Agent_OnUnload` 释放（`DisposeEnvironment`）。
2. 遍历堆前先看堆大小，>8GB 建议改用 `jcmd GC.class_histogram`（内部实现更高效）或 JFR 的 `ObjectCount` 事件。
3. 不要申请 `can_suspend`，挂起线程极易与其他工具的 safepoint 请求死锁。
4. agent 内部不要做阻塞 IO 或调用 Java 层代码（会引入新的类加载，递归触发 hook）。
5. 容器里优先用 `-agentpath` 启动时加载，避免 attach 权限问题。

---

## 九、实战二：类加载溯源（找出"谁加载了这个类"）

线上常见问题：Metaspace 缓慢上涨，`jcmd GC.class_histogram` 看不出异常，但 `jmap -clstats` 显示类数量持续增长。此时需要回答：**这个类是被哪个 ClassLoader、从哪个 jar 加载的？**

JVMTI 的 `ClassPrepare` 事件能在类"准备阶段"（链接完成、静态字段赋值前）回调，比 `ClassLoad` 更安全（此时类已可访问）。

```c
static void JNICALL
on_class_prepare(jvmtiEnv *jvmti, JNIEnv *jni, jthread thread, jclass klass) {
    char *sig = NULL, *generic = NULL;
    if ((*jvmti)->GetClassSignature(jvmti, klass, &sig, &generic) != JVMTI_ERROR_NONE) return;

    // 只关心业务包，避免刷爆日志
    if (strncmp(sig, "Lcom/example/", 13) != 0) {
        (*jvmti)->Deallocate(jvmti, (unsigned char *) sig);
        return;
    }

    // 拿 ClassLoader 与来源（需要 can_get_source_file_name / can_get_class_loader）
    jobject loader = NULL;
    (*jvmti)->GetClassLoader(jvmti, klass, &loader);

    char *source = NULL;
    (*jvmti)->GetSourceFileName(jvmti, klass, &source);

    fprintf(g_log, "%s | loader=%p | source=%s\n", sig, (void *) loader,
            source ? source : "unknown");

    if (source) (*jvmti)->Deallocate(jvmti, (unsigned char *) source);
    (*jvmti)->Deallocate(jvmti, (unsigned char *) sig);
}

// 注册：
// caps.can_generate_class_prepare_events = 1;
// (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE,
//         JVMTI_EVENT_CLASS_PREPARE, NULL);   // NULL = 所有线程
// callbacks.ClassPrepare = &on_class_prepare;
```

关键点：

- 第三个参数 `jthread` 为 `NULL` 表示监听**所有线程**；指定线程只监听该线程加载的类（启动阶段类加载是分散在多线程的，单线程监听会漏）。
- `ClassPrepare` 的回调在**类加载线程上下文**执行，不能用 `FindClass`（会触发新的类加载，形成递归），只能用已缓存的 `jclass` 引用。
- 日志必须异步写（环形缓冲 + 独立刷盘线程），否则一次批量类加载（比如热部署）会把业务线程拖死。

顺带一个经验数值：一个典型的 Spring Boot 应用启动会加载 12000~20000 个类，其中你自己写的通常不到 500 个。所以这类 agent 一定要**先按包名前缀过滤**，再做任何字符串拼接。

## 十、兼容性与稳定性：五个真实崩溃点

| 现象 | 根因 | 规避 |
|---|---|---|
| attach 后 JVM 直接 crash（SIGSEGV） | 在 `Agent_OnAttach` 里调用了未初始化完成的 JNI 函数 | 只用 `GetEnv` 拿到的 `jvmtiEnv`，不要假设 `JNIEnv` 可用 |
| 偶发 `fatal error: guaranteeing safepoint` | 回调里阻塞或调用 Java 层，导致 VM 无法进入 safepoint | 回调只做拷贝，逻辑丢到独立线程 |
| 卸载后再次 attach 报错 | 没有 `DisposeEnvironment`，或全局变量未重置 | OnUnload 里释放所有 `GetXXX` 分配的内存 |
| JDK 升级后 agent 失效 | JVMTI 版本/函数表布局变化，或用了 HotSpot 内部符号 | 用 `JVMTI_VERSION_1_2`，不碰 `AsyncGetCallTrace` 这类非标接口 |
| 容器里 `agent_load` 失败 | `/tmp` 不共享、`noexec`、或 attach socket 权限 | 改为启动参数 `-agentpath`，或把 socket 目录挂到可写卷 |

一条铁律：**JVMTI agent 里的任何 bug 都会变成 JVM 的 crash，而不是一个可捕获的 Java 异常**。所以在预发环境要用 `-Xcheck:jni` + `-XX:+ErrorFileToStdout` 跑一遍，再看 core dump。

## 十一、面试追问

**Q1：Instrumentation 的底层实现？**
JVM 内置 `libinstrument.so`（一个 JVMTI agent），注册 `ClassFileLoadHook`，把字节码转交给 `sun.instrument.InstrumentationImpl`，再由它遍历所有 `ClassFileTransformer`。`retransformClasses` 就是让 JVM 重新对指定类触发一次 hook。

**Q2：为什么 redefine 不能加方法？**
因为已加载类的 vtable/itable 布局、字段偏移、常量池索引都是"一次成型"的，新增成员会破坏已编译代码的假设。JVM 只允许替换方法体（且方法签名、字段、父类不变）。

**Q3：JVMTI 堆遍历为什么要 STW？**
遍历需要一致的堆视图；若并发修改对象图，tag 与引用关系会自相矛盾。所以 `IterateOverReachableObjects` 以 VM operation 形式在 safepoint 执行。

---

## 十二、总结

- **JVMTI 是 JVM 可观测性与诊断能力的真正入口**，Instrumentation / JFR / debugger 都建在它上面。
- 用它的核心是**能力申请**：申请越多，JIT 越束手束脚；只申请必需的 capability。
- 三个高频实操场景：堆直方图（`IterateOverReachableObjects`）、方法插桩（`RetransformClasses`）、类加载溯源（`ClassPrepare` 事件）。
- 生产铁律：**能采样就不要埋点，能离线就不要在线，能 JFR 就不要 JVMTI 高频事件**。
