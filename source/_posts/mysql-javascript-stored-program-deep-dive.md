---
title: 【MySQL 9】JavaScript 存储程序深度解析：GraalVM 运行时、能力边界与 Java 侧落地取舍
date: 2026-11-10 08:00:00
tags:
  - MySQL
  - JavaScript
  - GraalVM
  - 存储过程
  - 数据库
categories:
  - 数据库
author: 东哥
---

# 【MySQL 9】JavaScript 存储程序深度解析

## 前言

MySQL 9.0 干了一件在 MySQL 历史上挺反常识的事：**把 JavaScript 引擎塞进了数据库服务器进程里**。你可以在 `CREATE FUNCTION` / `CREATE PROCEDURE` 里直接写 ECMAScript，用 GraalVM 执行，而不是写那段让所有人都不想维护的 SQL/PSM 存储过程。

这个特性的定位很明确——**干掉"为了几十行数据加工逻辑专门建一个中间服务"的尴尬**。但它同时也带来了一堆必须想清楚的边界问题：能不能读文件？能不能发 HTTP？出错怎么排查？性能到底比 SQL 过程快还是慢？什么时候该用它，什么时候该老老实实回 Java 应用层写？

这篇我们把这套机制从运行时、语法、能力边界、性能、生产治理到 Java 侧落地完整过一遍。**注意：JavaScript 存储程序是 MySQL 企业版特性**，社区版用不了，这一点在做技术选型时是第一道门槛。

---

## 一、为什么 MySQL 要引入 JavaScript

先看一张"同一件事四种写法"的对比，这是理解这个特性价值的最快方式。

需求：给订单打一个风控标签，输入是 JSON 明细，输出是等级。

| 方案 | 代码位置 | 优点 | 缺点 |
|---|---|---|---|
| SQL 存储过程（PSM） | 数据库内 | 无网络开销、事务内原子 | 语法晦涩、无生态、JSON 处理痛苦、调试靠 SELECT |
| JavaScript 存储程序 | 数据库内 | 无网络开销、JSON 原生、生态语法熟悉 | 企业版限定、沙箱受限、调试弱、不可版本化 |
| Java UDF（`CREATE FUNCTION ... SONAME`） | 数据库内 | 性能最好、可复用 Java 库 | 需要编译 so、崩溃拖垮 mysqld、升级麻烦 |
| 应用层 Service | 应用内 | 可测试、可观测、可灰度 | 多一次网络往返、跨服务事务难 |

JavaScript 存储程序吃的是中间那一格：**比 SQL 过程好写，比 Java UDF 安全，比应用层少一跳**。

它的典型适用场景其实很窄，但很痛：

- 数据清洗/迁移脚本里的复杂字段变换（尤其是 JSON 嵌套结构重组）
- 报表/对账场景里的一次性聚合加工，不想为它发一次应用版本
- 触发器里需要做条件分支 + 字符串/正则处理
- ETL 前置的轻量加工，减少出库数据量

---

## 二、运行时：GraalVM 在 mysqld 里怎么跑

MySQL 的 JavaScript 支持基于 **GraalVM 的 ECMAScript 实现**，以"多语言引擎（MLE）"组件的形式加载进服务器进程。几个关键点：

1. **同一进程、同一地址空间**。JS 代码跑在 mysqld 进程内，不是外部子进程。所以它**没有网络隔离之外的进程隔离**，一个死循环就能拖住一个连接线程。
2. **每个会话有独立的执行上下文**。变量不跨会话共享，函数是"无状态"的（除非你读写表）。
3. **能力被显式裁剪**。没有 `fetch`、没有 `require`、没有 `fs`，标准库里只有纯计算部分。这是设计上的安全底线，不是配置项。
4. **解释 + JIT**。GraalVM 会在热点代码上做 JIT 编译，所以"第一次调用慢、后续变快"是正常现象，压测时要把 warmup 算进去。

组件安装大致是这样（具体组件名以你的 9.x 版本为准）：

```sql
-- 需要企业版，且安装后通常要重启生效
INSTALL COMPONENT 'file://component_mle';

-- 确认已加载
SELECT component_urn FROM mysql.component;
```

资源限制由 `mle.*` 系列系统变量控制（内存上限、执行超时等），默认值在共享实例上**一定要调**，否则一个写坏的 JS 递归能把整台实例的内存吃掉：

```sql
SHOW VARIABLES LIKE 'mle%';
-- 典型治理：单会话内存上限 + 执行时间上限
-- SET GLOBAL mle.max_memory = 64;   -- 单位以官方文档为准
```

> 生产建议：JS 存储程序**只放在只读从库或专用实例上**跑批处理，不要和核心交易实例混部。原因很简单——它和你的业务连接共享同一个 buffer pool 和同一份 CPU。

---

## 三、语法与实战

### 3.1 一个最小函数

```sql
CREATE FUNCTION js_order_level(amount DECIMAL(12,2), vip TINYINT)
RETURNS VARCHAR(16)
LANGUAGE JAVASCRIPT
AS $$
  if (amount >= 10000 || (vip === 1 && amount >= 3000)) {
    return 'HIGH';
  }
  if (amount >= 1000) {
    return 'MID';
  }
  return 'LOW';
$$;
```

调用和普通函数完全一致：

```sql
SELECT id, js_order_level(amount, is_vip) AS lvl
FROM t_order
WHERE created_at >= '2026-11-01';
```

### 3.2 JSON 加工才是它的主场

SQL/PSM 处理嵌套 JSON 要写一堆 `JSON_EXTRACT` + `JSON_UNQUOTE`，可读性极差。JS 里就是普通对象操作：

```sql
CREATE FUNCTION js_flatten_items(payload JSON)
RETURNS JSON
LANGUAGE JAVASCRIPT
AS $$
  const src = JSON.parse(payload);
  const items = Array.isArray(src.items) ? src.items : [];

  const merged = {};
  let total = 0;

  for (const it of items) {
    const sku = String(it.sku || '').toUpperCase();
    if (!sku) continue;
    const qty = Number(it.qty) || 0;
    const price = Number(it.price) || 0;
    if (!merged[sku]) {
      merged[sku] = { sku: sku, qty: 0, amount: 0 };
    }
    merged[sku].qty += qty;
    merged[sku].amount += qty * price;
    total += qty * price;
  }

  return JSON.stringify({
    total: Math.round(total * 100) / 100,
    count: Object.keys(merged).length,
    lines: Object.values(merged).sort((a, b) => b.amount - a.amount)
  });
$$;
```

同样逻辑写成 SQL 过程，长度至少翻三倍，而且没人愿意 review。

### 3.3 过程 + 事务边界

```sql
CREATE PROCEDURE js_purge_stale_cart(IN keep_days INT)
LANGUAGE JAVASCRIPT
AS $$
  const days = Number(keep_days) || 7;

  // 只做计算不够，存储程序的价值在于能操作表
  const rs = mysql.query(
    'SELECT COUNT(*) AS c FROM t_cart WHERE updated_at < NOW() - INTERVAL ? DAY',
    [days]
  );
  const candidates = rs[0].c;

  if (candidates > 100000) {
    // 大批量删除必须分批，否则一个长事务能把 undo 撑爆
    throw new Error('too many rows: ' + candidates + ', use batched job instead');
  }

  const r = mysql.query(
    'DELETE FROM t_cart WHERE updated_at < NOW() - INTERVAL ? DAY LIMIT 50000',
    [days]
  );
  return r.affectedRows;
$$;
```

注意两点：

- `mysql.query` 这类内置对象是 MLE 提供的数据库访问入口，**具体 API 名称随版本可能不同**，写之前先 `SELECT` 一个探针函数验证。
- 存储程序里**不要写长事务**。它跟你手写 `BEGIN...COMMIT` 一样会持有 MDL 和行锁，且更容易因为逻辑复杂而忘记提交。

### 3.4 错误处理

JS 里抛异常会被转成 SQL 错误：

```sql
CREATE FUNCTION js_safe_div(a DECIMAL(12,4), b DECIMAL(12,4))
RETURNS DECIMAL(12,4)
LANGUAGE JAVASCRIPT
AS $$
  if (b === 0 || b === null) {
    // 自定义错误码，方便应用侧统一识别
    const e = new Error('DIV_BY_ZERO');
    e.sqlState = '45000';
    throw e;
  }
  return a / b;
$$;
```

Java 侧就能按 `SQLState = 45000` 做统一兜底，而不是去解析错误文本。

---

## 四、能力边界：它能做什么，绝对不能做什么

这是最容易踩坑的部分。很多同学看完 demo 就想"那我是不是可以把一些服务端逻辑搬进数据库"——答案是**大部分不能**。

| 能力 | 支持情况 | 说明 |
|---|---|---|
| 纯计算 / 字符串 / 正则 / JSON | ✅ 完整 | 这是主战场 |
| 读当前会话变量、执行 SQL | ✅ | 通过内置数据库访问 API |
| 收发网络请求（HTTP/RPC） | ❌ 禁止 | 无 `fetch`、无 socket。数据库不该做服务调用 |
| 读写文件系统 | ❌ 禁止 | 无 `fs`。想导数据用 `SELECT ... INTO OUTFILE` |
| 引入第三方 npm 包 | ❌ 禁止 | 没有模块加载器，只能用内置标准库 |
| 多线程 / 异步回调 | ❌ 禁止 | 执行模型是同步的，`Promise` 基本没意义 |
| 常驻内存缓存 | ❌ 不保证 | 会话级上下文，连接断开即丢 |
| 访问其他数据库 | ❌ 禁止 | 只能访问本实例 |
| DDL | ⚠️ 受限 | 不要在函数里做 DDL，可能引发元数据锁雪崩 |
| 递归 | ⚠️ 危险 | 深度递归易栈溢出，配合内存上限才安全 |

一句话总结：**它是一台"能碰本地表的纯函数计算器"，不是一个"跑在数据库里的应用服务器"。**

这条边界直接决定了它的定位：**就近计算，减少数据搬运**，而不是"把微服务下沉到 DB"。

---

## 五、性能：什么时候真的更快

很多人以为"消除网络往返 = 一定更快"，实测并非如此。影响因素有三个：

1. **调用次数**。如果一条 SQL 处理 10 万行、每行调用一次 JS 函数，那就是 10 万次跨语言调用（SQL 引擎 ↔ JS 引擎），开销远大于省下的网络往返。
2. **JIT 是否预热**。冷启动时是解释执行，第一批数据会明显慢。
3. **数据搬运方向**。真正的收益来自"不出库"：本来要把 5 万行 JSON 拉到应用层加工，现在在库里算完只返回汇总结果。

一个粗略的经验判断：

| 场景 | 建议 |
|---|---|
| 逐行调用的简单函数（如格式化、加解密） | ❌ 别用，SQL 表达式或应用层更快 |
| 逐行调用的复杂 JSON 重组 | ⚠️ 先测。批量场景用聚合写法一次处理多行更好 |
| 全表/大范围扫描后就地聚合 | ✅ 收益最大，减少出库数据量 |
| 触发器内的轻量分支 | ✅ 可接受，但注意别放大写放大 |
| 跨表复杂业务事务 | ❌ 回应用层，可测性/可观测性差太多 |

压测时一定要区分 **warmup 后吞吐** 和 **首批延迟**，并且和"应用层批处理 + 批量写入"的基线对比——后者往往才是最优解。

---

## 六、Java 侧怎么落地

### 6.1 调用方式：跟普通函数没区别

```java
@Repository
public class OrderLevelRepository {

    private final JdbcTemplate jdbc;

    public OrderLevelRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Map<Long, String> batchLevel(List<Long> orderIds) {
        if (orderIds.isEmpty()) {
            return Map.of();
        }
        String in = orderIds.stream().map(id -> "?").collect(Collectors.joining(","));
        String sql = "SELECT id, js_order_level(amount, is_vip) AS lvl FROM t_order WHERE id IN (" + in + ")";
        Map<Long, String> result = new HashMap<>();
        jdbc.query(sql, rs -> {
            result.put(rs.getLong("id"), rs.getString("lvl"));
        }, orderIds.toArray());
        return result;
    }
}
```

### 6.2 一定要做的三件事

**第一，函数不存在时不能让接口 500。** 把"数据库能力"当作可选依赖：

```java
public boolean jsEnabled() {
    try {
        jdbc.queryForObject("SELECT js_order_level(1, 0)", String.class);
        return true;
    } catch (DataAccessException e) {
        log.warn("JS stored program unavailable, fallback to java impl", e);
        return false;
    }
}
```

**第二，Java 侧保留一份等价实现。** 这不是重复劳动，是**可回滚能力**。DB 侧逻辑出问题时，改配置切回 Java 实现，比发版回滚快得多。

**第三，把 SQL 里的 JS 代码纳入版本管理。** 它住在数据库里，天生游离于 Git 之外。建议：

```
/db/functions/js_order_level.sql
/db/functions/js_flatten_items.sql
```

用 Flyway/Liquibase 管理，`CREATE OR REPLACE` 保证幂等。**不要**让人在客户端手敲 `CREATE FUNCTION` 改线上逻辑——这是最常见的"线上代码和仓库不一致"事故源。

### 6.3 什么时候我会明确劝阻

- 团队没有 DBA 值守，数据库变更走不了审核流程
- 逻辑需要单测、需要断点调试、需要 traceId 全链路日志
- 逻辑将来可能需要访问外部服务（一旦需要，就得整体搬迁）
- 用的是社区版（用不了，别设计进架构）

---

## 七、生产治理清单

| 项目 | 做法 |
|---|---|
| 版本控制 | 全部 DDL 入 Git，Flyway 管理，禁止手工改线上 |
| 资源隔离 | 专用实例/只读从库，`mle.*` 内存与超时上限必须设置 |
| 权限最小化 | 执行函数的账号只给 `EXECUTE` + 必要的表 `SELECT`，不给 `FILE`、不给 `SUPER` |
| 可观测 | 慢查询日志 + `performance_schema` 里按 `PROCEDURE`/`FUNCTION` 维度聚合 |
| 灰度 | 先在一个从库验证，用影子流量对比 Java 实现结果 |
| 回滚 | Java 侧保留等价实现 + 开关 |
| 禁止项 | 网络调用、文件读写、DDL、长事务、深递归、按行调用百万次 |

## 八、面试常见追问

**Q1：MySQL 为什么要用 GraalVM 而不是 V8？**
A：GraalVM 本身就是多语言运行时，天然支持"宿主语言 + 嵌入语言"的互操作和统一内存管理，而且它能在同一个 VM 里做 JIT 和沙箱裁剪。V8 是独立引擎，嵌进 C++ 服务要自己处理隔离和资源配额，工程量更大。这里的关键不是"哪个 JS 引擎快"，而是"哪个更容易安全地嵌进已有进程"。

**Q2：JS 存储程序能替代应用层逻辑吗？**
A：不能。它没有网络、没有文件、没有模块、没有异步，且无法单测和全链路追踪。它的价值是**消除数据搬运**，不是**承载业务编排**。判断标准：这段逻辑是否需要与外部系统交互、是否需要独立扩缩容、是否需要灰度——只要有一个"是"，就留在应用层。

**Q3：为什么逐行调用 JS 函数可能比应用层还慢？**
A：跨语言调用有固定开销（参数封送、类型转换、上下文切换）。10 万行 × 每次调用 = 10 万次穿越边界，这个开销可能远超一次网络往返摊到 10 万行上的成本。正确姿势是把"按行调用"改成"集合处理"：一次传入一批数据，返回一个结果集。

**Q4：如何在数据库内保证这段 JS 逻辑和 Java 实现一致？**
A：双跑比对。用影子流量把同一批输入分别喂给 DB 函数和 Java 实现，落库比对差异率，差异率低于阈值再切流。这比"code review 觉得没问题"可靠一个量级。

**Q5：这个特性和 `CREATE FUNCTION ... SONAME`（UDF）比怎么选？**
A：UDF 是原生代码，性能最好但**崩溃会带走整个 mysqld**，且升级要重启、要处理 so 依赖，安全审计几乎不可行。JS 存储程序跑在受控运行时里，异常是 SQL 错误而不是段错误。除非是极致性能的标量函数（比如加解密、哈希），否则优先 JS。

---

## 九、总结

- JavaScript 存储程序解决的是"**就近计算**"问题，不是"服务下沉"问题。
- 它的甜区是 **JSON 重组、字段变换、批量清洗**，并且**企业版限定**。
- 能力边界非常硬：无网络、无文件、无模块、无异步。设计时先把这条记在脑门上。
- 性能收益来自"减少出库数据量"，不是"消除网络往返"。逐行调用大概率更慢。
- Java 侧要保留等价实现 + 开关 + 版本化管理，否则它会变成一台没人敢动的黑盒。

一句话给做技术选型的同学：**当你的痛点是"为了 30 行 JSON 加工专门发一次应用版本"，它值得；当你的痛点是"微服务调用链太长"，它一点都不值得。**
