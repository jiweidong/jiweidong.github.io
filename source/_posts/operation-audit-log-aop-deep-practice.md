---
title: 【Java 实战】操作日志与数据变更审计深度实战：AOP、注解与变更 Diff 全解析
date: 2026-10-11 08:30:00
tags:
  - Java
  - Spring Boot
  - AOP
  - 审计日志
categories:
  - Java
  - 工程实战
author: 东哥
---

# 【Java 实战】操作日志与数据变更审计深度实战：AOP、注解与变更 Diff 全解析

## 面试官：你们的系统有操作日志吗？说说怎么实现的

这是中高级后端面试里非常能拉开差距的一题。初级回答是"用 AOP 加个注解记录一下"，中级回答是"记录操作人和时间"，而真正做过合规项目的工程师会反问你三个问题：

1. **记的是"操作"还是"变更"？**（能否还原"张三把金额从 100 改成 200"）
2. **日志会不会因为业务事务回滚而错记？**
3. **日志本身能不能被篡改？**

这三个问题，正好对应操作日志的三层难度：**记录 → 变更对比 → 审计可信**。这篇文章从最基础的 AOP 方案讲起，一路做到字段级 Diff 与防篡改。

---

## 一、先分清三个概念

很多人把这三个词混着用，实际职责完全不同：

| 类型 | 目的 | 使用者 | 典型内容 |
| --- | --- | --- | --- |
| **操作日志** | 追溯"谁做了什么" | 运维 / 客服 / 用户 | 操作人、IP、接口、结果、耗时 |
| **变更审计** | 追溯"数据怎么变的" | 合规 / 风控 / 排查 | 字段级 before/after |
| **业务日志** | 排查问题 | 开发 | 堆栈、上下游、SQL |

**操作日志回答"谁点了什么按钮"；变更审计回答"这条记录的字段被谁改成了什么"。** 合规要求（如等保、SOX、金融行业）通常两者都要，且审计日志要求**不可篡改 + 保留期至少 6 个月到 3 年**。

---

## 二、基础方案：注解 + AOP

### 2.1 定义注解

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface OpLog {

    /** 模块，如 "订单管理" */
    String module();

    /** 操作类型 */
    OpType type();

    /** 描述，支持 SpEL，如 "'取消订单 ' + #orderNo" */
    String desc() default "";

    /** 是否记录请求参数 */
    boolean saveParams() default true;

    /** 是否记录返回值 */
    boolean saveResult() default false;

    /** 是否做字段级变更对比 */
    boolean diff() default false;
}

public enum OpType { QUERY, CREATE, UPDATE, DELETE, EXPORT, IMPORT, LOGIN, LOGOUT }
```

### 2.2 切面实现

```java
@Aspect
@Component
@RequiredArgsConstructor
public class OpLogAspect {

    private final OpLogRecorder recorder;
    private final SpelExpressionParser parser = new SpelExpressionParser();

    @Around("@annotation(opLog)")
    public Object around(ProceedingJoinPoint pjp, OpLog opLog) throws Throwable {
        long start = System.currentTimeMillis();
        OpLogRecord record = new OpLogRecord();
        record.setModule(opLog.module());
        record.setType(opLog.type());
        record.setMethod(pjp.getSignature().toShortString());

        // 1. 操作人 / 请求上下文
        fillUserAndRequest(record);

        // 2. 参数快照（序列化要防大对象）
        if (opLog.saveParams()) {
            record.setParams(safeSerialize(pjp.getArgs()));
        }

        // 3. SpEL 计算描述
        record.setDesc(evalDesc(opLog.desc(), pjp));

        try {
            Object result = pjp.proceed();
            record.setSuccess(true);
            if (opLog.saveResult()) {
                record.setResult(safeSerialize(result));
            }
            return result;
        } catch (Throwable e) {
            record.setSuccess(false);
            record.setErrorMsg(abbreviate(e.getMessage(), 500));
            throw e;
        } finally {
            record.setCostMs(System.currentTimeMillis() - start);
            // 4. 异步落库，绝不影响业务
            recorder.asyncSave(record);
        }
    }
}
```

### 2.3 请求上下文：不要每个方法都传参

操作人、IP、UA 这些信息在 Controller 层到处都要用，正确做法是用 `ThreadLocal`（或 Spring 的 `RequestContextHolder`）统一管理：

```java
public final class RequestContext {

    private static final ThreadLocal<CurrentUser> HOLDER = new ThreadLocal<>();

    public static void set(CurrentUser user) { HOLDER.set(user); }
    public static CurrentUser get() { return HOLDER.get(); }
    public static void clear() { HOLDER.remove(); }
}

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class RequestContextFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest req,
                                    HttpServletResponse resp,
                                    FilterChain chain) throws ServletException, IOException {
        try {
            CurrentUser user = new CurrentUser();
            user.setUserId(parseUserId(req));
            user.setUsername(req.getHeader("X-User-Name"));
            user.setIp(IpUtils.getRealIp(req));   // 注意代理头
            user.setTraceId(MDC.get("traceId"));
            RequestContext.set(user);
            chain.doFilter(req, resp);
        } finally {
            RequestContext.clear();   // 必须清理，否则线程池复用会串数据
        }
    }
}
```

> **面试陷阱**：`RequestContextHolder` 用的是 `InheritableThreadLocal`，在**异步线程池**里拿不到请求上下文。跨线程取不到是高频事故，解法是显式传参或用 `TransmittableThreadLocal`（TTL）。

---

## 三、进阶：字段级变更 Diff

只记录"谁调了 updateOrder 接口"是不够的。合规审计要看的是：

```
订单 ORD-20261011-001
  状态:  待支付 → 已取消
  金额:  199.00 → 0.00
  备注:  "" → "用户主动取消"
```

### 3.1 思路：环绕前查旧值，成功后比对

```java
@Around("@annotation(opLog) && @annotation(diffAnn)")
public Object aroundWithDiff(ProceedingJoinPoint pjp, OpLog opLog) throws Throwable {
    // 1. 从参数里解析出主键与实体类型
    DiffContext ctx = resolveDiffContext(pjp, opLog);

    // 2. 查旧值（在事务外或使用独立事务，见后文坑位）
    Object before = ctx != null ? ctx.loadOld() : null;

    Object result = pjp.proceed();

    if (ctx != null) {
        Object after = ctx.loadNew();   // 重新查一次，拿最新值
        List<FieldChange> changes = DiffUtils.diff(before, after, ctx.ignoreFields());
        if (!changes.isEmpty()) {
            auditService.saveChanges(ctx, changes);
        }
    }
    return result;
}
```

### 3.2 通用 Diff 工具（反射 + 注解）

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.FIELD)
public @interface AuditField {
    /** 字段中文名 */
    String value();
    /** 是否脱敏 */
    boolean sensitive() default false;
    /** 顺序 */
    int order() default 0;
}

public final class DiffUtils {

    public static List<FieldChange> diff(Object before, Object after, Set<String> ignore) {
        if (before == null || after == null) return List.of();
        List<FieldChange> changes = new ArrayList<>();

        for (Field f : before.getClass().getDeclaredFields()) {
            if (ignore.contains(f.getName())) continue;
            AuditField ann = f.getAnnotation(AuditField.class);
            if (ann == null) continue;
            if (Modifier.isStatic(f.getModifiers())) continue;

            f.setAccessible(true);
            try {
                Object oldV = f.get(before);
                Object newV = f.get(after);
                if (Objects.equals(oldV, newV)) continue;

                String oldStr = format(oldV);
                String newStr = format(newV);
                if (ann.sensitive()) {
                    oldStr = MaskUtils.mask(oldStr);
                    newStr = MaskUtils.mask(newStr);
                }
                changes.add(new FieldChange(ann.value(), oldStr, newStr, ann.order()));
            } catch (IllegalAccessException ignored) { }
        }
        changes.sort(Comparator.comparingInt(FieldChange::getOrder));
        return changes;
    }

    private static String format(Object v) {
        if (v == null) return "";
        if (v instanceof Date d) return DateFmt.yyyyMMddHHmmss(d);
        if (v instanceof BigDecimal bd) return bd.toPlainString();
        if (v instanceof Enum<?> e) return e.name();
        String s = String.valueOf(v);
        return s.length() > 500 ? s.substring(0, 500) + "..." : s;
    }
}
```

### 3.3 实体示例

```java
@Data
public class Order {

    @AuditField(value = "订单号", order = 1)
    private String orderNo;

    @AuditField(value = "订单状态", order = 2)
    private OrderStatus status;

    @AuditField(value = "订单金额", order = 3)
    private BigDecimal amount;

    @AuditField(value = "收货手机号", order = 4, sensitive = true)
    private String receiverPhone;

    // 不记录
    private Date updateTime;
    private Long updateBy;
}
```

产出的审计记录：

```json
{
  "bizType": "ORDER",
  "bizId": "ORD-20261011-001",
  "operator": "zhangsan",
  "changes": [
    {"field": "订单状态", "old": "待支付", "new": "已取消"},
    {"field": "订单金额", "old": "199.00", "new": "0.00"}
  ],
  "traceId": "a1b2c3d4"
}
```

---

## 四、五个必须踩过的坑

### 坑一：事务回滚，日志却记了

`finally` 里落库，如果业务事务回滚，日志却已经写进去了——**"日志说改了，数据其实没改"，这是审计里最致命的错误**。

**正确做法**：用 `TransactionSynchronizationManager` 注册事务回调，只在**提交后**写日志：

```java
private void saveAfterCommit(OpLogRecord record) {
    if (TransactionSynchronizationManager.isSynchronizationActive()) {
        TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCommit() {
                        recorder.asyncSave(record);
                    }
                });
    } else {
        recorder.asyncSave(record);
    }
}
```

更优雅的方式是发布事件 + `@TransactionalEventListener(phase = AFTER_COMMIT)`：

```java
@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
public void onOpLog(OpLogEvent event) {
    recorder.asyncSave(event.toRecord());
}
```

### 坑二：查旧值受事务隔离影响

`loadOld()` 如果在同一个事务里，读到的是**本事务的快照**；如果前面已经更新过，可能读到中间态。**审计的旧值必须来自更新前的真实快照**——要么在进入方法前查（先于业务写），要么用 `REQUIRES_NEW` 独立事务读。

实践中推荐：**在业务方法入口处就先查一遍旧值并放进上下文**，而不是等业务改完再回头查。

### 坑三：日志同步写，拖慢主流程

写日志是 IO 操作，不能占用业务线程。用**异步 + 有界队列**：

```java
ExecutorService logExecutor = new ThreadPoolExecutor(
        2, 4, 60L, TimeUnit.SECONDS,
        new ArrayBlockingQueue<>(5000),           // 有界，防内存暴涨
        new NamedThreadFactory("op-log-"),
        new ThreadPoolExecutor.CallerRunsPolicy() // 队列满则退化为同步，绝不丢日志
);
```

> `CallerRunsPolicy` 看似会阻塞业务，但它保证了**日志不丢**；审计场景"宁可慢一点，不能丢一条"。

### 坑四：大参数/敏感信息入库

- 文件流、`MultipartFile`、`InputStream` 不能直接序列化，会 OOM 或产生巨大字符串；
- 密码、身份证、银行卡必须脱敏（`sensitive = true` + 统一的 `MaskUtils`）；
- 建议白名单字段 + 单字段 500 字截断 + 单条记录 4KB 上限。

### 坑五：日志表被当成业务表做大查询

审计表只增不改，几个月就上亿行。**解法**：按月分表（或分区表）、只建必要索引（`biz_type + biz_id`、`operator + create_time`）、冷数据归档到对象存储。

---

## 五、审计可信：防篡改设计

合规场景下，"日志能改"就等于"日志无效"。三板斧：

**① 哈希链（Hash Chain）**：每条记录存前一条的哈希，形成链式结构。

```java
public class AuditChain {

    public AuditRecord seal(AuditRecord prev, AuditRecord cur) {
        String payload = cur.canonical() + (prev == null ? "GENESIS" : prev.getHash());
        cur.setPrevHash(prev == null ? "GENESIS" : prev.getHash());
        cur.setHash(sha256(payload));
        return cur;
    }

    /** 校验：任意一条被改动，链就会断 */
    public boolean verify(List<AuditRecord> chain) {
        for (int i = 0; i < chain.size(); i++) {
            AuditRecord cur = chain.get(i);
            AuditRecord prev = i == 0 ? null : chain.get(i - 1);
            String expect = sha256(cur.canonical()
                    + (prev == null ? "GENESIS" : prev.getHash()));
            if (!expect.equals(cur.getHash())) return false;
        }
        return true;
    }
}
```

**② 定期存证**：把某时间段的链尾哈希写入独立的不可变存储（对象存储 WORM、区块链、第三方存证）。

**③ 权限隔离**：审计库与应用库分库；应用账号只有 `INSERT`/`SELECT`，**没有 `UPDATE`/`DELETE`**；查询走单独的只读账号。

```sql
-- 应用写入账号：只有 INSERT
GRANT INSERT, SELECT ON audit_db.audit_log TO 'app_write'@'%';

-- 审计平台：只读
GRANT SELECT ON audit_db.* TO 'auditor_ro'@'%';

-- 绝不给应用 UPDATE/DELETE 权限
```

---

## 六、表结构参考

```sql
CREATE TABLE op_log (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    trace_id     VARCHAR(64)  NOT NULL DEFAULT '',
    module       VARCHAR(64)  NOT NULL,
    op_type      VARCHAR(16)  NOT NULL,
    method       VARCHAR(255) NOT NULL,
    operator_id  BIGINT       NULL,
    operator     VARCHAR(64)  NULL,
    ip           VARCHAR(64)  NULL,
    uri          VARCHAR(255) NULL,
    params       MEDIUMTEXT   NULL,
    result       MEDIUMTEXT   NULL,
    success      TINYINT      NOT NULL DEFAULT 1,
    error_msg    VARCHAR(512) NULL,
    cost_ms      INT          NOT NULL DEFAULT 0,
    create_time  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    KEY idx_operator_time (operator, create_time),
    KEY idx_trace (trace_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE audit_change (
    id          BIGINT      NOT NULL AUTO_INCREMENT,
    biz_type    VARCHAR(64) NOT NULL,
    biz_id      VARCHAR(64) NOT NULL,
    operator    VARCHAR(64) NULL,
    field_name  VARCHAR(64) NOT NULL,
    old_value   VARCHAR(512) NULL,
    new_value   VARCHAR(512) NULL,
    trace_id    VARCHAR(64) NULL,
    prev_hash   CHAR(64)    NOT NULL,
    hash        CHAR(64)    NOT NULL,
    create_time DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    KEY idx_biz (biz_type, biz_id, create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## 七、面试高频追问

**追问一：AOP 能不能拦截私有方法 / 同类内部调用？**

不能。Spring AOP 基于**代理**，私有方法、`static` 方法、`final` 方法以及**同类内部方法自调用**都不会走代理。自调用要么改造（注入自身代理、`AopContext.currentProxy()`），要么换 AspectJ 编译期/加载期织入。

**追问二：异步线程里怎么拿到操作人？**

`ThreadLocal` 不会自动传递。方案：① 显式把上下文作为参数传给日志服务（最稳）；② 用 `TransmittableThreadLocal` 包装线程池；③ 在提交任务前手动 `MDC` 快照传递。

**追问三：怎么保证日志不丢？**

分层保障：**内存队列 → 本地磁盘文件（WAL）→ MQ → 落库**。线程池队列满用 `CallerRunsPolicy`，落库失败则落本地文件 + 定时补偿重投，绝不静默吞异常。

**追问四：字段级 Diff 性能怎么优化？**

① 只对标注 `@AuditField` 的字段做反射；② 缓存 `Class → Field[]` 的元数据；③ 大表更新不重新查询新旧两行，而是从**更新参数 + 原值快照**计算；④ 变更记录批量插入。

---

## 总结

操作日志这件事，写起来是 AOP 加注解，做好却要跨过五道坎：**注解切面、上下文传递、字段级 Diff、事务提交后落库、审计防篡改**。

面试时的加分姿势是主动点出那两个"反直觉"的点：

1. **日志必须在事务提交后写**，否则回滚会造成审计与数据不一致；
2. **审计表要哈希链 + 权限隔离**，因为"能改的日志等于没有日志"。

能把这两点讲清楚，说明你不只是用过 AOP，而是真的为一条日志的**可信性**负责过。
