---
title: 【Java 实战】百万级数据查询 OOM？JDBC ResultSet 流式查询与 MyBatis Cursor 游标读取深度实战
date: 2026-09-03 08:00:00
tags:
  - JDBC
  - MyBatis
  - MySQL
  - 性能优化
  - 实战
categories:
  - Java
  - 数据库
author: 东哥
---

# 【Java 实战】百万级数据查询 OOM？JDBC ResultSet 流式查询与 MyBatis Cursor 游标读取深度实战

## 引子：一次导出功能引发的 OOM

业务方要导出一份 200 万行的对账明细。开发同学很自然地写了：

```java
List<OrderDO> list = orderMapper.selectAllForExport(); // 一次性全查出来
// ... 逐行写 Excel
```

上线当天，导出服务直接 OOM，`java.lang.OutOfMemoryError: Java heap space`。原因很直白：**MySQL 驱动默认会把查询结果一次性全部拉进客户端内存（ResultSet 全量物化），200 万行 × 每行几百字节 = 几个 G**，堆直接爆掉。

解决方案不是分页循环（深分页 LIMIT 一样会炸，且越翻越慢），而是**流式查询（Streaming Query）**：让数据库一行一行地把数据吐给客户端，边读边处理，内存占用恒定。本文从 JDBC 底层讲起，到 MyBatis Cursor 实战，把流式查询的机制、坑和最佳实践一次说清。

## 一、先理解默认行为：为什么查询会"一口气"拉完

MySQL Connector/J 默认查询行为是：**执行 `executeQuery()` 时，驱动就把服务端返回的所有行读取到客户端内存中**（通过 `RowDataStatic`/内部缓冲），此时 `ResultSet.next()` 只是在内存里移动指针。

这样设计的原因：MySQL 服务端与客户端之间有**网络往返**，如果一行一行的"按需拉取"，每条都要等一次网络 RTT，性能灾难。所以默认采用"一次全量传输，客户端本地遍历"。

流式查询的本质是**改变传输协议的行为**：让服务端**不缓冲全部结果**，而是客户端每调用一次 `next()`，驱动才向服务端请求下一批数据。服务端保持游标状态，持续发送，直到客户端读完或关闭。

## 二、JDBC 层面怎么开启流式查询

### 姿势一：设置 fetchSize = Integer.MIN_VALUE（经典魔法值）

```java
try (Connection conn = dataSource.getConnection();
     PreparedStatement ps = conn.prepareStatement(
         "SELECT * FROM trade_detail WHERE biz_date = ?")) {
    // 关键：fetchSize 设为 Integer.MIN_VALUE 触发流式模式
    ps.setFetchSize(Integer.MIN_VALUE);
    ps.setFetchDirection(ResultSet.FETCH_FORWARD);
    ps.setString(1, "2026-09-01");
    try (ResultSet rs = ps.executeQuery()) {
        while (rs.next()) {
            // 逐行处理，堆里永远只有一行
            process(rs);
        }
    }
}
```

**为什么是 Integer.MIN_VALUE？** 这是 MySQL Connector/J 的约定：当 `fetchSize` 恰好等于 `Integer.MIN_VALUE` 时，驱动走"逐行流式"逻辑，把结果集设置为 `RowDataDynamic`（动态按需读取）；设置成其他正数（如 1000）时，驱动会尝试用 `useCursorFetch=true` + 服务端游标，否则**静默忽略**——这也是很多人发现"设了 fetchSize 没用"的原因。

### 姿势二：useCursorFetch=true + 正数 fetchSize（服务端游标）

```properties
jdbc:mysql://localhost:3306/db?useCursorFetch=true&defaultFetchSize=1000
```

开启 `useCursorFetch` 后，驱动会用 MySQL 的**服务端游标（Server-Side Cursor）**：`COM_STMT_FETCH` 按批取数，每批 1000 行。相比 Integer.MIN_VALUE 模式，它支持**随机访问**且每批有网络缓冲，对大批量、需要批量处理的场景更友好。但注意：

- 服务端游标会占用**服务端内存**（结果集在服务端暂存）；
- 需要 `useSSL` 之外的额外配置，且对事务/连接状态有要求；
- 与某些连接池/代理不兼容，需要实测。

**结论**：快速方案用 `Integer.MIN_VALUE`；要精细控制批大小、需要可滚动结果集时用 `useCursorFetch`。两者都不能在**自动提交 + 无事务**的裸连接上可靠工作（见第四节坑位）。

## 三、MyBatis 里的流式查询：Cursor 游标

MyBatis 对 JDBC 流式做了封装，提供 `Cursor<T>`：

```java
public interface OrderMapper {
    // 返回 Cursor，MyBatis 内部自动开启流式模式
    @Select("SELECT * FROM trade_detail WHERE biz_date = #{date}")
    Cursor<TradeDetail> scanByDate(@Param("date") String date);
}
```

Service 层使用：

```java
@Transactional(readOnly = true)  // 重要！Cursor 必须在事务内读取
public void export(String date, OutputStream out) {
    try (Cursor<TradeDetail> cursor = orderMapper.scanByDate(date)) {
        Iterator<TradeDetail> it = cursor.iterator();
        while (it.hasNext()) {
            TradeDetail row = it.next();      // 每次只物化一行对象
            writeRow(out, row);
        }
    }
}
```

**MyBatis 做了什么？** 当 Mapper 方法返回 `Cursor` 时，`DefaultSqlSession` 会使用 `CursorExecutor`，其内部对 PreparedStatement 设置 `fetchSize = Integer.MIN_VALUE`（MySQL 场景），把 ResultSet 包装成 `MyBatisCursor`，并注册了一个**事务同步回调**——**事务提交/回滚/关闭时自动关闭 Cursor**。

两个关键约束必须记住：

1. **必须在事务内使用**：Cursor 的读取依赖底层连接不归还连接池。如果没有 `@Transactional`，MyBatis 默认在 `select` 结束后立即关闭 SqlSession/连接，Cursor 再 `next()` 就会抛 `java.sql.SQLException: Operation not allowed after ResultSet closed`。`@Transactional(readOnly=true)` 同时告诉 MySQL 走只读事务优化。
2. **Cursor 本身要 close**：用 try-with-resources 包裹，或用完 `cursor.close()`，否则连接可能无法正常释放回池。

## 四、流式查询的坑位清单（全是血泪）

| 坑 | 现象 | 原因与解法 |
|----|------|-----------|
| 没开事务就遍历 Cursor | ResultSet closed 异常 | Cursor 生命周期绑定 SqlSession，必须 @Transactional 包裹 |
| 与分页插件（PageHelper）混用 | 分页失效或异常 | PageHelper 会改 SQL 加 LIMIT，与流式冲突；流式场景禁用分页插件 |
| 遍历中途抛异常 | 连接/游标泄漏 | 异常时确保 finally 里 close；MyBatis 事务回滚会自动关，裸 JDBC 要自己管 |
| 读取期间执行同连接其他 SQL | 驱动报错/数据错乱 | 流式结果集未读完前，同一连接不能再执行语句（协议限制）；开新连接或读完再查 |
| fetchSize 设了 1000 没用 | 还是全量拉取 | 未开 useCursorFetch；或驱动版本旧。设 Integer.MIN_VALUE 兜底 |
| 大字段（TEXT/BLOB）行内多 | 单行内存大、GC 压力 | 流式只解决"行数多"，不解决"单行大"；必要时只 SELECT 需要的列 |
| 服务端游标未关闭 | 服务端临时表/内存膨胀 | 及时 close ResultSet/Statement；用 try-with-resources |
| 事务长时间不提交 | 长事务 + undo 膨胀 | 流式处理完立即提交；超大任务分段事务 |
| 连接池连接被借走不还 | 连接耗尽 | 确保 finally 归还；设置连接池 `maxLifetime`/借用超时兜底 |

另外还有一个隐藏点：**Integer.MIN_VALUE 流式模式下 `ResultSet` 只能 `FETCH_FORWARD` 顺序读**，不能 `absolute()`/`last()` 随机跳转，否则抛异常。

## 五、最佳实践：导出一千万行的完整模板

```java
@Service
public class ExportService {

    @Transactional(readOnly = true, timeout = 600)
    public void exportLarge(String date, OutputStream out) throws IOException {
        // 1. 写表头
        writeHeader(out);
        // 2. 流式扫描（每批 5000 行 flush 一次 Excel/CSV）
        long total = 0;
        try (Cursor<TradeDetail> cursor = orderMapper.scanByDate(date)) {
            for (TradeDetail row : cursor) {
                writeRow(out, row);
                if (++total % 5000 == 0) {
                    out.flush();                 // 防内存堆积
                    checkMemoryAndThrottle(total); // 可选：背压
                }
            }
        } catch (Exception e) {
            log.error("export failed at row {}", total, e);
            throw e;  // 事务回滚，Cursor 自动关闭
        }
        log.info("export done, total={}", total);
    }
}
```

配套注意点：

- **结果集只取需要的列**，别 `SELECT *` 拖 TEXT 大字段；
- **OutputStream 及时 flush**，防止写文件/网络侧再堆一层内存；
- 超大导出建议**异步任务 + 进度记录**（导出任务表），避免 HTTP 超时；
- 与 `LIMIT` 深分页对比：1000 万行用 LIMIT 翻页要扫描前面所有行（`OFFSET` 越大越慢），流式是**一次扫描 + 恒定内存**，大数据量导出/全量同步/批处理任务首选。

## 六、原理补充：这几种"批处理"别再混为一谈

| 概念 | 解决的问题 | 机制 |
|-----|-----------|------|
| fetchSize 批取 | 减少网络往返 | 每次 `next()` 取一批到本地缓冲 |
| 流式查询（MIN_VALUE） | 降低客户端内存 | 服务端不发完，客户端按需取 |
| useCursorFetch 服务端游标 | 可控批大小 + 可滚动 | 服务端暂存结果，COM_STMT_FETCH 分批拉 |
| PreparedStatement 批处理（addBatch） | 批量**写入** | 多条 SQL 一次网络发送 |
| 分页查询 | 用户浏览场景 | 每次只查一小段，天然低内存 |

流式查询只适用于**全量遍历型**任务（导出、迁移、全量计算、报表），不适用于"用户点下一页"的在线查询——在线查询请用 keyset 分页或普通 LIMIT。

## 七、小结

回到开头的 OOM：把 `List<OrderDO>` 全量查询改成 `Cursor` + 事务内流式遍历，内存占用从"几 G"降到"几十 M"，导出 200 万行稳定跑完。核心三件事：**返回值类型改成 Cursor / fetchSize 设 Integer.MIN_VALUE / 记得包事务**。面试被问"百万级数据怎么导出不 OOM"，按"默认全量物化 → 流式原理（服务端游标 vs 客户端逐行）→ MyBatis Cursor 约束 → 对比深分页"这条线答，就是一份满分的工程答案。
