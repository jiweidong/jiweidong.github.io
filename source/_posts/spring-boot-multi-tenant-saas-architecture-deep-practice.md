---
title: 【架构设计】Spring Boot 多租户 SaaS 架构深度实战：数据隔离、动态数据源与租户上下文透传
date: 2026-10-08 08:20:00
tags:
  - Spring Boot
  - 多租户
  - SaaS
  - 架构设计
categories:
  - Java
  - 架构设计
author: 东哥
---

# 【架构设计】Spring Boot 多租户 SaaS 架构深度实战：数据隔离、动态数据源与租户上下文透传

## 面试官：一套系统卖给 500 家公司，数据怎么隔离？

> "我们一开始是给一家客户做的定制系统，后来老板说要做成 SaaS，卖给了 200 多家企业。
> 现在的问题是：**A 公司的管理员通过接口查到了 B 公司的订单**。老板说要防止再发生，你打算怎么改？"

这是多租户（Multi-Tenancy）的**第一性问题**：数据隔离。它比"怎么动态切库"重要得多——**先保证不串，再谈怎么优雅地不串**。

这篇文章按"隔离级别选型 → 租户上下文设计 → 数据层落地（动态数据源 / 租户列 / RLS）→ 全链路透传 → 运营与运维"的顺序，把多租户 SaaS 讲透。

---

## 一、隔离级别：三种模型与五种方案

### 1.1 三个维度

多租户隔离可以从三个层面看：

| 维度 | 选项 | 说明 |
| --- | --- | --- |
| **数据** | 独立库 / 共享库独立 Schema / 共享表加租户列 | 隔离强度递减，成本递增 |
| **计算** | 独立实例 / 共享实例 | 大客户可独享（hybrid） |
| **资源** | 独立限流/配额 / 共享 | CPU、连接数、存储额度 |

### 1.2 五种落地方案对比

| 方案 | 隔离性 | 成本 | 扩租户 | 跨租户统计 | 适用 |
| --- | --- | --- | --- | --- | --- |
| ① 独立数据库（物理实例） | ★★★★★ | ★★★★★ | 需新建实例 | 极难 | 金融、政务、大客户 |
| ② 独立库（同实例多 DB） | ★★★★ | ★★★★ | 建库+迁移 | 难（跨库 JOIN 不可能） | 中大型客户 |
| ③ 独立 Schema（同库多 Schema） | ★★★★ | ★★★ | 建 Schema 快 | 难 | PostgreSQL 常见 |
| ④ 共享表 + 租户列（`tenant_id`） | ★★ | ★ | 插一行 | 容易 | 中小客户，默认方案 |
| ⑤ 分片组合（④ + 按租户分片） | ★★★ | ★★★ | 看分片策略 | 需汇聚 | 超大 SaaS（飞书/Salesforce 模式） |

**行业实践**：Salesforce、飞书、钉钉这类超大规模 SaaS 走的是 **⑤：逻辑上共享，物理上按租户 Hash 分片，大客户独立分片或独立库（Hybrid）**。

**中小型 SaaS 的务实选择**：

> **统一用方案 ④（共享表 + `tenant_id`）拿订单，另保留"升级到大客户独享"的逃生舱。**
> 因为真正让 SaaS 崩溃的从来不是隔离性不足，而是**客户量小的时候背上了独立库的运维复杂度**。

---

## 二、租户上下文：一切的源头

无论用哪种方案，都需要一个"当前请求属于哪个租户"的上下文。

### 2.1 `TenantContext`：用 ThreadLocal 还是 ScopedValue？

```java
public final class TenantContext {

    private static final ThreadLocal<TenantInfo> CTX = new ThreadLocal<>();

    public record TenantInfo(Long tenantId, String tenantCode, boolean systemTenant) {}

    public static void set(TenantInfo info) { CTX.set(info); }

    public static TenantInfo get() {
        TenantInfo info = CTX.get();
        if (info == null) {
            throw new TenantMissingException("租户上下文缺失，拒绝执行");
        }
        return info;
    }

    /** 系统级/后台任务可获取"无租户"上下文 */
    public static TenantInfo getOrSystem() {
        return CTX.get();
    }

    public static void clear() { CTX.remove(); }
}
```

**关键设计点**：

1. **`get()` 在缺失时直接抛异常，而不是返回 null**。这是"防串"的第一道防线：任何忘记设置上下文的代码路径都会**快速失败**，而不是"查不到租户然后查了全表"。
2. **一定要 `clear()`**，否则线程池复用会串租户（这是最经典的 Bug，后面详述）。
3. **`ScopedValue`（JDK 21+ 预览 / JDK 25 转正）是更好的选择**：它天然不可变、随作用域自动失效、和虚拟线程配合无副作用，不存在"忘记 clear"的问题：

```java
// JDK 25+ ScopedValue 版本
public final class TenantContext {
    public static final ScopedValue<TenantInfo> CURRENT = ScopedValue.newInstance();

    public static TenantInfo get() {
        if (!CURRENT.isBound()) throw new TenantMissingException("租户上下文缺失");
        return CURRENT.get();
    }
}

// 在过滤器里绑定
ScopedValue.where(TenantContext.CURRENT, info)
           .run(() -> chain.doFilter(req, resp));
```

---

## 三、租户识别：从请求中解析出租户

租户来源有四种，通常需要组合使用：

| 来源 | 示例 | 优先级 | 备注 |
| --- | --- | --- | --- |
| 子域名 | `acme.saas.com` | 高 | 最直观，需要泛域名证书 |
| 请求头 | `X-Tenant-Id: acme` | 高 | 内部服务调用推荐 |
| JWT Claim | `"tid": 10086` | **最高** | **最可信，不可被前端篡改** |
| 路径 | `/api/t/{code}/orders` | 中 | 简单，但 URL 传染 |
| 用户映射 | 登录用户所属租户 | 兜底 | 单用户单租户时有效 |

### 3.1 过滤器实现（Servlet 栈）

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class TenantFilter extends OncePerRequestFilter {

    private final TenantResolver resolver;

    @Override
    protected void doFilterInternal(HttpServletRequest req,
                                    HttpServletResponse resp,
                                    FilterChain chain) throws ServletException, IOException {
        TenantInfo info = resolver.resolve(req);   // 单一入口解析
        try {
            TenantContext.set(info);
            chain.doFilter(req, resp);
        } finally {
            TenantContext.clear();                  // 🔑 必须清理
        }
    }

    /** 白名单：健康检查、登录、注册等不需要租户 */
    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        String uri = req.getRequestURI();
        return uri.startsWith("/actuator") || uri.startsWith("/auth/login");
    }
}
```

### 3.2 解析器：优先级 + 一致性校验

```java
@Component
public class TenantResolver {

    public TenantInfo resolve(HttpServletRequest req) {
        // 1) JWT claim 最可信
        String fromToken = extractFromJwt(req);
        // 2) 请求头 / 子域名作为辅助
        String fromHeader = req.getHeader("X-Tenant-Id");
        String fromHost   = extractSubdomain(req.getServerName());

        String code = firstNonBlank(fromToken, fromHeader, fromHost);

        // 3) 交叉校验：token 里的租户必须与 host/header 一致，否则拒绝
        if (fromToken != null && fromHeader != null
                && !fromToken.equals(fromHeader)) {
            throw new ForbiddenException("租户标识冲突，疑似越权访问");
        }
        if (code == null) throw new TenantMissingException("无法识别租户");

        return tenantRegistry.getByCode(code);      // 带缓存
    }
}
```

**"交叉校验"这一步非常关键**：它能直接拦住"攻击者用 A 租户的 token 访问 B 租户子域名"这类越权。**只信任一个来源，其余全部用于比对**。

---

## 四、数据层落地（一）：共享表 + 租户列

### 4.1 表结构

```sql
CREATE TABLE orders (
    id         BIGINT       NOT NULL,
    tenant_id  BIGINT       NOT NULL,
    order_no   VARCHAR(32)  NOT NULL,
    amount     DECIMAL(18,4) NOT NULL,
    created_at DATETIME     NOT NULL,
    PRIMARY KEY (id),
    -- 🔑 所有唯一索引必须带 tenant_id，否则租户间会冲突
    UNIQUE KEY uk_tenant_order_no (tenant_id, order_no),
    KEY idx_tenant_created (tenant_id, created_at)
) ENGINE=InnoDB;
```

**两条铁律**：

1. **业务唯一键必须是 `(tenant_id, biz_key)` 复合唯一索引**。否则 A 公司建了个 `ORDER-001`，B 公司就再也建不了 `ORDER-001`。
2. **所有查询条件都必须带 `tenant_id`，且它应该是索引的最左前缀**。

### 4.2 MyBatis-Plus 多租户插件：自动注入 `tenant_id`

手写 `WHERE tenant_id = ?` 一定会漏。用 `TenantLineInnerInterceptor` 在 SQL 解析层自动注入：

```java
@Configuration
public class MybatisPlusConfig {

    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor() {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();

        // 多租户插件：自动给 SELECT/UPDATE/DELETE 加 tenant_id 条件，
        // INSERT 自动填充 tenant_id 列
        TenantLineInnerInterceptor tenant = new TenantLineInnerInterceptor(
                new TenantLineHandler() {
                    @Override
                    public Expression getTenantId() {
                        return new LongValue(TenantContext.get().tenantId());
                    }

                    @Override
                    public String getTenantIdColumn() { return "tenant_id"; }

                    /** 哪些表忽略（全局表：字典、配置、租户表本身） */
                    @Override
                    public boolean ignoreTable(String tableName) {
                        return Set.of("sys_dict", "sys_config", "t_tenant")
                                  .contains(tableName.toLowerCase());
                    }
                });

        interceptor.addInnerInterceptor(tenant);
        interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));
        return interceptor;
    }
}
```

**插件的能力与边界**：

| 场景 | 是否自动处理 | 备注 |
| --- | --- | --- |
| 单表 SELECT / UPDATE / DELETE | ✅ | 自动加 `tenant_id` |
| INSERT | ✅ | 自动补列和值 |
| **JOIN** | ⚠️ 部分 | 需要每个表都能推断别名，复杂 SQL 容易出错 |
| **子查询 / UNION** | ⚠️ | 支持不完整，需实测 |
| **手写 XML 复杂 SQL** | ⚠️ | 可能被解析失败，建议加白名单/人工复核 |
| 原生 SQL（JdbcTemplate/存储过程） | ❌ | **完全绕过**，必须人工加 |

**因此，插件只是"降低漏写概率"，不是"保证不串"**。还要配合：

- **Code Review 规范**：任何绕过 `BaseMapper` 的 SQL 必须显式带 `tenant_id`；
- **单元测试**：写一个"跨租户越权测试"用例（以 A 租户登录查 B 租户数据，断言 404）；
- **SQL 审计**：在 `prepareStatement` 层面拦截未带 `tenant_id` 的订单类表查询（灰度期可用）。

### 4.3 JPA / Hibernate 方案

```java
public interface TenantAware {
    Long getTenantId();
    void setTenantId(Long tenantId);
}

// Hibernate 6 用 @TenantId 注解 + 自动过滤
@Entity
@Table(name = "orders")
public class Order {
    @Id private Long id;

    @TenantId                       // 🔑 Hibernate 自动识别并加过滤条件
    @Column(name = "tenant_id", nullable = false, updatable = false)
    private Long tenantId;
}
```

Hibernate 6 的 `@TenantId` 会自动给所有查询加租户过滤，并在持久化时填充。**但要注意它和 `@Filter` 的区别**：`@TenantId` 是内建的、无状态的；`@Filter` 需要手动 `session.enableFilter()`，更适合"按状态过滤"这类动态条件。

### 4.4 PostgreSQL 方案：RLS（行级安全）

如果底层是 PG，还能把隔离下沉到数据库：

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
    USING (tenant_id = current_setting('app.tenant_id', true)::bigint)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::bigint);
```

应用侧每个连接设置：

```java
jdbcTemplate.execute("SELECT set_config('app.tenant_id', '" + tenantId + "', true)");
```

**RLS 的最大优势**：即使应用层漏加了 `WHERE tenant_id`，数据库也不会返回别人的数据，**形成"兜底防线"**。代价是：① 需要为每个连接设置变量（配连接池要小心）；② 执行计划可能变差；③ DBA 不熟悉的团队排查成本高。

> ⚠️ **务必注意 SQL 注入**：`set_config` 的值一定要经过校验（必须数字），否则就是注入点。更安全的是用 JDBC prepared statement 绑定 + `SET LOCAL`。

---

## 五、数据层落地（二）：共享库 + 独立 Schema / 动态数据源

当客户升级为"独立库"时，需要在运行时切换数据源。

### 5.1 `AbstractRoutingDataSource` 动态路由

```java
public class TenantRoutingDataSource extends AbstractRoutingDataSource {

    @Override
    protected Object determineCurrentLookupKey() {
        TenantInfo info = TenantContext.getOrSystem();
        return info == null ? "default" : info.tenantCode();
        // 返回的 key 会被用来从 targetDataSources 里找 DataSource
    }
}
```

```java
@Configuration
public class DataSourceConfig {

    @Bean
    public DataSource dataSource(TenantDataSourceRegistry registry) {
        TenantRoutingDataSource ds = new TenantRoutingDataSource();
        ds.setDefaultTargetDataSource(defaultDs());
        ds.setTargetDataSources(registry.all());   // Map<Object, DataSource>
        ds.afterPropertiesSet();
        return ds;
    }
}
```

**三个致命坑**：

1. **`determineCurrentLookupKey` 在事务内被调用，但事务已绑定连接。**
   如果在拿到连接后切换租户，**不会生效**。必须保证：**租户上下文在发起事务之前就已确定**。也就是说切换租户不能发生在 `@Transactional` 方法内部。

2. **动态数据源 + `@Transactional` 顺序**：`AbstractRoutingDataSource` 的路由发生在 `getConnection()` 时。如果有 AOP 切面在事务开启之后再设置 `TenantContext`，连接已经绑到旧租户了，**会出现"改了上下文但没换库"的静默错误**。建议在 Filter 层（事务之前）就把租户确定下来。

3. **懒加载数据源会耗尽连接**：200 个租户 × 每个 20 连接 = 4000 连接。必须：① 用 `HikariCP` 的小池子（每租户 2~5 个）；② 加**空闲数据源回收**（`LRU + 超时关闭`）；③ 或者干脆不改数据源，改成"同库不同 Schema"用 `search_path` 切换，成本低得多。

### 5.2 动态数据源管理的最佳实践：`TenantDataSourceRegistry`

```java
@Component
public class TenantDataSourceRegistry {

    private final Map<String, HikariDataSource> cache = new ConcurrentHashMap<>();
    private final Map<String, Long> lastAccess = new ConcurrentHashMap<>();
    private static final long IDLE_TIMEOUT_MS = 30 * 60 * 1000;   // 30 分钟
    private static final int MAX_POOLED_TENANTS = 100;            // 最多缓存 100 个

    public DataSource get(String tenantCode) {
        HikariDataSource ds = cache.get(tenantCode);
        if (ds == null) {
            synchronized (this) {
                ds = cache.get(tenantCode);
                if (ds == null) {
                    evictIfNeeded();
                    ds = create(tenantCode);
                    cache.put(tenantCode, ds);
                }
            }
        }
        lastAccess.put(tenantCode, System.currentTimeMillis());
        return ds;
    }

    /** 由定时任务每分钟清理空闲/超量数据源，避免连接泄漏 */
    @Scheduled(fixedDelay = 60_000)
    public void evictIdle() {
        long now = System.currentTimeMillis();
        lastAccess.forEach((code, ts) -> {
            if (now - ts > IDLE_TIMEOUT_MS) {
                HikariDataSource ds = cache.remove(code);
                lastAccess.remove(code);
                if (ds != null) ds.close();
            }
        });
    }
    // create / evictIfNeeded 略
}
```

---

## 六、全链路透传：不只 HTTP

租户上下文必须在**所有跨线程、跨进程的地方**传递，漏一个就会串。

### 6.1 异步 / 线程池：`TaskDecorator`

```java
public class TenantTaskDecorator implements TaskDecorator {
    @Override
    public Runnable decorate(Runnable task) {
        TenantInfo captured = TenantContext.getOrSystem();   // 捕获提交线程的上下文
        return () -> {
            TenantInfo previous = TenantContext.getOrSystem();
            try {
                TenantContext.set(captured);   // 在子线程里恢复
                task.run();
            } finally {
                if (previous == null) TenantContext.clear();
                else TenantContext.set(previous);   // 还原，防止池化污染
            }
        };
    }
}

// 注册
ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
executor.setTaskDecorator(new TenantTaskDecorator());
```

### 6.2 `@Async` / `CompletableFuture`

`@Async` 的 `AsyncConfigurer` 里用同一个 `TaskDecorator`。`CompletableFuture.supplyAsync(..., executor)` 只要用带 `TaskDecorator` 的 executor 就自动带上；如果用了 `ForkJoinPool.commonPool()`，**上下文会丢**——这类代码要在 Code Review 里明确禁止。

### 6.3 定时任务 / 消息消费：显式指定租户

这两类没有"请求"，必须显式迭代租户：

```java
@Scheduled(cron = "0 0 2 * * ?")
public void dailySettleForAllTenants() {
    for (TenantInfo t : tenantRegistry.allActive()) {
        // 每个租户独立上下文 + 独立事务 + 独立异常隔离
        try {
            TenantContext.set(t);
            settleService.settle(t.tenantId());   // @Transactional
        } catch (Exception e) {
            log.error("租户 {} 结算失败", t.tenantCode(), e);   // 一个租户失败不影响其他
        } finally {
            TenantContext.clear();
        }
    }
}
```

**要点：一个租户失败不能影响其他租户**（异常隔离），且每个租户用独立事务（避免一个大事务锁住全表）。

Kafka/RocketMQ 消费同理：**消息体里必须携带 `tenantId`**，消费前 `TenantContext.set()`。绝不能"从数据库反查租户"——那会引入额外查询，也可能因数据缺失而错乱。

### 6.4 跨服务调用（Feign / RestTemplate / gRPC）

```java
@Bean
public RequestInterceptor tenantFeignInterceptor() {
    return template -> {
        TenantInfo info = TenantContext.getOrSystem();
        if (info != null) template.header("X-Tenant-Id", info.tenantCode());
    };
}
```

下游服务在过滤器里解析这个头即可。**同时要在网关做一次"净化"**：剥离外部请求自带的 `X-Tenant-Id`，只保留网关重新签发的那个，防止伪造。

### 6.5 虚拟线程下的陷阱

虚拟线程是**每个任务一个新线程**，`ThreadLocal` 不会串（因为不复用），但：

1. **`ThreadLocal` 在虚拟线程里仍然可用，只是数量级可能爆炸**（百万虚拟线程 × 每个一个 `TenantInfo`）；
2. **`InheritableThreadLocal` 在虚拟线程里行为不一致**，不要依赖它做传递；
3. **推荐 `ScopedValue`**：它专为虚拟线程设计，绑定在作用域上，随作用域销毁，零泄漏风险。

---

## 七、运维与治理：租户是个"运维单元"

### 7.1 租户级可观测性

日志 MDC 里必须带 `tenant`：

```java
MDC.put("tenant", info.tenantCode());
```

配合 Logback pattern：`%X{tenant}`。这样线上排查时可以直接按租户过滤。

指标也要打 tag：

```java
Counter.builder("http.server.requests")
       .tag("tenant", info.tenantCode())   // ⚠️ 高基数标签要小心
```

**注意高基数问题**：500 个租户 × 每个接口一条时间线，Prometheus 直接爆炸。正确做法：**只给 Top 20 大客户 + `other` 聚合桶**打 tag，明细写到日志/链路追踪里。

### 7.2 配额与限流

多租户最怕"一个客户把系统打挂"。需要**租户级限流**：

```java
// 基于 Redis 的租户级令牌桶
public boolean tryAcquire(String tenantCode, String api, int qps) {
    String key = "rl:" + tenantCode + ":" + api + ":" + System.currentTimeMillis() / 1000;
    Long count = redis.opsForValue().increment(key);
    if (count != null && count == 1) redis.expire(key, 2, TimeUnit.SECONDS);
    return count != null && count <= qps;
}
```

配额维度：QPS、并发数、存储量、导出次数、任务并发度。**每种资源都要有额度，否则"邻居噪音（Noisy Neighbor）"会拖垮整个平台。**

### 7.3 租户生命周期

| 阶段 | 操作 |
| --- | --- |
| 开通 | 建租户记录、初始化角色权限、可选建独立 Schema |
| 扩容 | 升级套餐、调整配额、必要时迁到独立库（混合部署） |
| 停用 | 只读、禁止写入、保留数据 N 天 |
| 注销 | 导出数据 → 逻辑删除 → 冷备 → 物理清理（满足合规） |

**数据导出/删除能力是合规刚需**（GDPR、《个保法》），系统设计之初就要考虑"能否按租户精确删除全链路数据"。**没有租户维度的数据是删不掉的**——这条反过来也证明了 `tenant_id` 必须贯穿所有表。

---

## 八、面试常见追问

**Q1：为什么不用独立数据库，隔离不是更好？**
成本。② 独立库的成本是"运维复杂度 × 客户数"：备份、升级、监控、连接数都要乘 N。**SaaS 的毛利来自共享**，一般先用共享表，只对愿意付钱的"大客户"独立部署（Hybrid 模式）。

**Q2：`tenant_id` 会不会成为查询瓶颈？**
会。**所有索引都要以 `tenant_id` 为前缀**，这会让索引选择度下降。对策：① 复合索引 `(tenant_id, biz_col)`；② 超大租户走分片/独立库；③ 定期做租户级数据归档，控制单表行数。

**Q3：MyBatis-Plus 多租户插件能完全防串吗？**
不能。它只处理能被 SQL 解析器识别的简单语句，**复杂 JOIN、UNION、存储过程、原生 SQL、动态表名都会绕过**。所以还需要"快速失败上下文 + 越权测试 + 数据库 RLS 兜底 + SQL 审计"组合拳。

**Q4：ThreadLocal 忘了 `clear()` 会怎样？**
线程池复用时，下一个请求会拿到**上一个租户的上下文**——直接在 A 租户的请求里返回 B 的数据。这是真实事故，**根本解法是用 `ScopedValue`**，或者所有 `set` 都包在 `try/finally` 里。

**Q5：定时任务怎么保证不漏租户、不乱租户？**
① 显式遍历租户列表（从租户中心取，不是从业务表反推，避免"新租户没数据就不被处理"）；② 每租户独立事务 + 独立 try/catch；③ 处理结果落到 `task_execution_log(tenant_id, date, status)`，做**对账式补偿**（谁没跑成功一目了然）；④ 分片执行（xxl-job/ElasticJob 的分片参数来选租户分片）。

**Q6：如果客户要求"跨租户数据联合分析"（比如集团下多家公司汇总）怎么办？**
不要破坏隔离。做法是**建独立的分析域**：业务库 → CDC/binlog → 数仓（按 `tenant_id` 分区）→ 用专门的"租户层级关系表（`tenant_group`）"做汇聚授权。分析域的权限模型是"租户组"，与业务系统的租户隔离物理分离。

---

## 九、总结

多租户的本质是：**把"租户"提升为一等公民，渗透到数据、上下文、链路、运维的每一层。**

```
请求 → TenantResolver（多来源交叉校验）
     → TenantFilter（set + finally clear）
     → TenantContext（ThreadLocal / ScopedValue）
     → 数据层（tenant_id 自动注入 / 动态数据源 / RLS 兜底）
     → 异步透传（TaskDecorator / MQ 消息体 / Feign Header）
     → 运维（租户级日志、指标、配额、生命周期）
```

三条底线：

1. **宁快失败，不静默降级**：拿不到租户就抛异常，绝不"当全局处理"；
2. **上下文必有终**：`set` 必配 `finally clear`，新项目用 `ScopedValue`；
3. **隔离靠多层**：插件 + 复合唯一键 + RLS + 越权测试 + Code Review，任何单层都不可信。

做到这三点，面试官问"怎么防止 A 查到 B 的数据"，你就能答出一套**完整、可落地、有兜底**的方案——而不是只说一句"加个 `tenant_id` 就行"。
