---
title: 【数据库实战】Liquibase 深度实战：从 changelog 到与 Flyway 的全面对比
date: 2026-08-19 08:00:00
tags:
  - Java
  - Liquibase
  - 数据库
categories:
  - Java
  - 数据库
author: 东哥
---

# 【数据库实战】Liquibase 深度实战：从 changelog 到与 Flyway 的全面对比

## 为什么需要数据库版本管理？

"生产环境的表结构又和测试环境对不上了！"

"这个 `ALTER TABLE` 是 DBA 手动执行的，代码里根本没有记录！"

"回滚？回滚是不可能回滚的，因为没人知道上一个版本的表结构长什么样。"

如果你经历过上面的任何一个场景，说明你的团队迫切需要**数据库版本管理（Database Migration / Schema Change Management）**。数据库的 Schema 变更应该和代码一样：**可版本化、可评审、可回滚、可追溯**。而 Java 生态中两大主流方案就是 **Liquibase** 和 **Flyway**。

本篇文章我们从零开始，系统梳理 Liquibase 的核心概念、常用标签、Spring Boot 集成、多环境管理、与 Flyway 的深度对比，以及生产环境的最佳实践。

### 一句话概括

Liquibase 是一个开源的数据库变更管理工具：把每次 Schema 变更写成一个 **changeset（变更集）**，通过 **changelog（变更日志）** 统一组织，用 **DATABASECHANGELOG 表** 记录执行历史，从而让数据库结构像 Git 一样可追踪、可升级、可回滚。

---

## 一、Liquibase 核心概念

### 1.1 Changelog：变更日志

changelog 是 Liquibase 的入口文件，可以是一个，也可以是多个（通过 `include` / `includeAll` 组合）。支持三种格式：

- **XML**：Liquibase 的原生格式，能力最全
- **YAML**：简洁易读，目前最主流
- **JSON**：适合程序生成

示例（YAML 格式）：

```yaml
# db/changelog/db.changelog-master.yaml
databaseChangeLog:
  - includeAll:
      path: db/changelog/changes/
      relativeToChangelogFile: true
```

### 1.2 Changeset：变更集

每个 changeset 是**一次最小粒度的变更单元**，拥有唯一标识 `id + author + filePath` 三元组：

```yaml
databaseChangeLog:
  - changeSet:
      id: 20260819-001
      author: dongge
      comment: 创建用户表
      changes:
        - createTable:
            tableName: t_user
            columns:
              - column:
                  name: id
                  type: BIGINT
                  autoIncrement: true
                  constraints:
                    primaryKey: true
                    nullable: false
              - column:
                  name: username
                  type: VARCHAR(64)
                  constraints:
                    nullable: false
                    unique: true
              - column:
                  name: password_hash
                  type: VARCHAR(128)
                  constraints:
                    nullable: false
              - column:
                  name: created_at
                  type: DATETIME
                  defaultValueComputed: CURRENT_TIMESTAMP
```

**关键机制：** Liquibase 根据三元组（id、author、changelog 文件路径）计算 changeset 的 MD5 校验和，执行后写入 `DATABASECHANGELOG` 表。下次启动时对比：

1. **未执行过** → 执行并记录
2. **执行过且校验和一致** → 跳过
3. **执行过但校验和变了** → 报错（`ValidationFailedException`），阻止启动！

这第三个行为是很多人踩坑的地方：**已经执行过的 changeset 绝对不能修改**。要改，就新建一个 changeset 去"打补丁"。

### 1.3 DATABASECHANGELOG 表

Liquibase 首次运行时会在目标库自动创建两张表：

| 表名 | 作用 |
|------|------|
| `DATABASECHANGELOG` | 记录所有已执行的 changeset（id、author、filename、MD5SUM、执行时间、执行顺序） |
| `DATABASECHANGELOGLOCK` | 分布式锁，防止多个实例并发执行变更 |

```sql
SELECT ID, AUTHOR, FILENAME, DATEEXECUTED, ORDEREXECUTED, MD5SUM
FROM DATABASECHANGELOG
ORDER BY ORDEREXECUTED;
```

`DATABASECHANGELOGLOCK` 表是 Liquibase 保证**集群安全**的关键：多个应用实例同时启动时，只有一个能拿到锁执行变更，其余实例等待（默认等待时间可配）。这一点在微服务多实例部署时至关重要。

---

## 二、常用变更标签实战

### 2.1 表结构变更

```yaml
- changeSet:
    id: 20260819-002
    author: dongge
    changes:
      - addColumn:
          tableName: t_user
          columns:
            - column:
                name: nickname
                type: VARCHAR(32)
                afterColumn: username
      - addUniqueConstraint:
          tableName: t_user
          columnNames: nickname
          constraintName: uk_t_user_nickname
      - createIndex:
          tableName: t_user
          indexName: idx_t_user_created_at
          columns:
            - column:
                name: created_at
```

### 2.2 数据变更（DML）

用 `sql` 标签直接写 SQL，适合存量数据初始化：

```yaml
- changeSet:
    id: 20260819-003
    author: dongge
    changes:
      - sql:
          sql: |
            INSERT INTO t_dict (dict_type, dict_code, dict_name)
            VALUES ('USER_STATUS', '1', '启用'), ('USER_STATUS', '0', '禁用');
```

更优雅的方式是 `loadData` + CSV 文件，天然支持跨数据库：

```yaml
- changeSet:
    id: 20260819-004
    author: dongge
    changes:
      - loadData:
          tableName: t_dict
          file: data/t_dict.csv
          relativeToChangelogFile: true
          separator: ','
```

### 2.3 回滚：rollback 不是免费的

Liquibase 一个核心卖点是**支持回滚**，但请注意：**只有声明了回滚逻辑，回滚才可靠**。

```yaml
- changeSet:
    id: 20260819-005
    author: dongge
    changes:
      - addColumn:
          tableName: t_user
          columns:
            - column:
                name: email
                type: VARCHAR(128)
    rollback:
      - dropColumn:
          tableName: t_user
          columnName: email
```

Liquibase 对很多标签有**自动生成回滚语句**的能力（如 createTable → dropTable），但 `sql`、`modifySql` 等标签不会自动回滚，必须手写 `rollback` 段。

```bash
# 回滚最近 N 个 changeset
liquibase rollback-count 3

# 回滚到某个 tag
liquibase rollback v1.2.0

# 回滚到指定日期
liquibase rollback-to-date 2026-08-01T00:00:00
```

> ⚠️ **生产警示**：回滚会执行 `rollback` 段中的语句，如果是 `DROP TABLE` 这种**不可逆操作**，数据会永久丢失。生产环境更推荐"**向前补偿**"而不是"回滚"——即用新的 changeset 把数据迁回来。回滚主要用于开发/测试环境。

### 2.4 条件执行：preConditions

某些变更只在特定数据库或特定条件下才执行：

```yaml
- changeSet:
    id: 20260819-006
    author: dongge
    preConditions:
      - onFail: MARK_RAN   # 条件不满足时标记为已执行，不报错
      - tableExists:
          tableName: t_old_order
    changes:
      - renameTable:
          oldTableName: t_old_order
          newTableName: t_order
```

`onFail` 可选值：`HALT`（默认，中止）、`CONTINUE`（跳过继续）、`MARK_RAN`（标记已执行）。这在**多环境差异处理**（比如开发库有、生产库没有的测试表）中非常有用。

### 2.5 上下文与标签：一套 changelog 玩转多环境

```yaml
- changeSet:
    id: 20260819-007
    author: dongge
    context: dev, test        # 只在 dev/test 执行
    changes:
      - sql:
          sql: INSERT INTO t_user (username) VALUES ('seed_dev_user');

- changeSet:
    id: 20260819-008
    author: dongge
    labels: performance-test  # 按标签过滤
    changes:
      - createIndex:
          tableName: t_order
          indexName: idx_t_order_user_id
```

执行时通过参数过滤：

```bash
liquibase update --contexts=dev --labels=performance-test
```

---

## 三、Spring Boot 集成

### 3.1 依赖与配置

```xml
<dependency>
    <groupId>org.liquibase</groupId>
    <artifactId>liquibase-core</artifactId>
</dependency>
```

Spring Boot 2.4+ 会自动从 `classpath:/db/changelog/db.changelog-master.yaml` 加载，也可自定义：

```yaml
spring:
  liquibase:
    enabled: true
    change-log: classpath:db/changelog/db.changelog-master.yaml
    contexts: ${LIQUIBASE_CONTEXTS:dev}
    default-schema: public
    # 集群模式下等待锁的时间
    liquibase-tablespace: public
    # 启动时校验 changeset 未变
    test-rollback-on-update: false
```

启动时观察日志：

```
Starting Liquibase at ...: 2026-08-19 08:00:01
Running Changeset: db/changelog/changes/20260819-001.yaml::20260819-001::dongge
Liquibase: Update has been successful. Ran 3 changesets
```

### 3.2 与多数据源共存

当项目有多个数据源时，需要为每个数据源单独指定 changelog：

```java
@Configuration
public class LiquibaseConfig {

    @Bean
    public SpringLiquibase orderLiquibase(
            @Qualifier("orderDataSource") DataSource dataSource) {
        SpringLiquibase liquibase = new SpringLiquibase();
        liquibase.setDataSource(dataSource);
        liquibase.setChangeLog("classpath:db/changelog/order/db.changelog-master.yaml");
        return liquibase;
    }

    @Bean
    public SpringLiquibase userLiquibase(
            @Qualifier("userDataSource") DataSource dataSource) {
        SpringLiquibase liquibase = new SpringLiquibase();
        liquibase.setDataSource(dataSource);
        liquibase.setChangeLog("classpath:db/changelog/user/db.changelog-master.yaml");
        return liquibase;
    }
}
```

> 💡 主数据源使用 Boot 自动配置的 Liquibase，其他数据源手动注册 `SpringLiquibase` Bean，并确保在 `JPA/MyBatis` 初始化**之前**执行（可用 `@DependsOn` 控制顺序）。

---

## 四、Liquibase vs Flyway 深度对比

### 4.1 理念差异：声明式 vs 命令式

这是两者最本质的区别：

- **Flyway**：命令式。每个迁移就是一个 SQL 文件（`V1__create_user.sql`），按版本号顺序执行，简单直接。
- **Liquibase**：声明式。用 XML/YAML 描述"想要什么结果"，由 Liquibase 翻译成目标数据库的方言 SQL。

### 4.2 全维度对比表

| 对比维度 | Liquibase | Flyway |
|---------|-----------|--------|
| 文件格式 | XML / YAML / JSON / SQL | SQL / Java |
| 核心概念 | changelog + changeset | versioned migration |
| 版本标识 | id + author + 文件路径（三元组） | 文件名前缀 `V1__`、`V2__` |
| 回滚能力 | ✅ 原生支持（rollback 段） | ❌ 官方版不支持，需社区插件 flyway-maven 或手写 undo |
| 跨数据库 | ✅ 极强，一套 changelog 多库方言 | ✅ 但 SQL 文件需按库维护 |
| 校验和机制 | ✅ MD5 校验，改动已执行 changeset 直接报错 | ✅ 校验和校验，改动已执行脚本报错 |
| 集群锁 | ✅ DATABASECHANGELOGLOCK 表锁 | ✅ 同款机制 |
| 学习曲线 | 陡峭（标签多、概念多） | 平缓（就是 SQL） |
| 与 Spring Boot 集成 | 自动配置成熟 | 自动配置成熟 |
| 多环境支持 | context / labels / preConditions | 仅靠目录/命名约定 |
| 生成文档 | ✅ 可生成 HTML 变更报告 | ❌ |
| 适合场景 | 复杂 Schema、多库方言、需要回滚的大型团队 | 中小项目、追求简单直接 |

### 4.3 如何选型？

- **简单至上**：团队 SQL 水平高、库单一（如只 MySQL）、项目不大 → **Flyway**，零学习成本。
- **复杂治理**：多数据库方言（MySQL + PostgreSQL + Oracle）、需要回滚、需要评审变更报告 → **Liquibase**。
- **已有 Flyway 想换**：可以考虑双轨过渡，但更推荐**锁定一个**——两种工具同时跑会互相打架（都建自己的历史表，但 schema 变更彼此不可见）。

---

## 五、生产环境最佳实践

### 5.1 团队协作规范

1. **changeset 一旦合入主干并执行，永不修改**。要调整就写新 changeset 补偿。
2. **每个 changeset 只做一件事**：一个建表、一个加列、一个数据初始化。方便回滚和 Review。
3. **id 规范**：`yyyyMMdd-序号`（如 `20260819-001`），author 用统一账号（如 `dongge`），避免个人账号造成混乱。
4. **Code Review 必须包含 changelog**：把数据库变更纳入 MR/PR 评审，和代码一起走 CI。
5. **CI 中校验**：`liquibase update-sql` 生成即将执行的 SQL 供人工确认，或 `liquibase validate` 校验未执行 changeset 的语法。

### 5.2 大表变更的坑

Liquibase 的 `addColumn` 在 MySQL 大表（千万级）上会触发 Online DDL，可能锁表。生产实践：

1. 大表变更不要直接上 Liquibase 原生标签，改为 `sql` 标签 + `pt-osc` / `gh-ost` 工具：
```yaml
- changeSet:
    id: 20260819-009
    author: dba
    changes:
      - sql:
          sql: |
            pt-online-schema-change D=trade,t=t_order \
              --alter "ADD COLUMN buyer_remark VARCHAR(255) NULL" \
              --execute
```
2. 或者先把表结构变更做进版本，再在低峰期由 DBA 手动执行并 `markChangeSetRan`：
```bash
liquibase changelog-sync --change-log=... # 仅记录不执行
```

### 5.3 发布流程示例

```bash
# 1. 本地/CI 环境先验证
liquibase --changeLogFile=db/changelog/db.changelog-master.yaml \
          --url=jdbc:mysql://ci-host:3306/app_db \
          update-sql > preview.sql   # 人工评审

# 2. 测试环境
liquibase update

# 3. 生产环境（应用启动时自动执行，或由 DBA 手动）
liquibase --contexts=prod update
```

### 5.4 监控与排查

```sql
-- 查看最近执行的变更
SELECT ID, AUTHOR, DATEEXECUTED, ORDEREXECUTED
FROM DATABASECHANGELOG
ORDER BY ORDEREXECUTED DESC LIMIT 20;

-- 查看锁占用（应用启动卡住时优先查这里）
SELECT * FROM DATABASECHANGELOGLOCK;
```

应用启动长时间卡在 Liquibase 阶段，90% 是 `DATABASECHANGELOGLOCK` 被占（上次变更被 kill 没释放锁），删掉锁记录重启即可。

---

## 六、面试高频追问

**Q1：Liquibase 怎么判断一个 changeset 是否执行过？**
通过 `id + author + changelog 文件路径` 三元组查 `DATABASECHANGELOG` 表；执行过的还会比对 MD5SUM，校验和不一致直接抛 `ValidationFailedException` 阻止应用启动。

**Q2：多实例部署时，多个应用同时启动会不会重复执行变更？**
不会。Liquibase 先获取 `DATABASECHANGELOGLOCK` 表上的行锁，拿到锁的实例执行变更，其他实例阻塞等待，执行完成释放锁后继续。

**Q3：生产环境的表结构变更出错，怎么处理？**
优先"向前补偿"：写一个新的 changeset 把结构/数据修正回来，保持变更历史线性向前。除非确认可逆（rollback 段明确），否则不在生产做 rollback，避免数据丢失。

**Q4：Liquibase 和 Flyway 能不能混用？**
不建议。两者各自维护变更历史表，互不感知对方的变更，会导致"以为执行了实际没执行"或校验混乱。选定一个并坚持。

---

## 七、总结

Liquibase 的本质是**把数据库结构当作一等公民纳入版本管理**。它比 Flyway 更重、学习曲线更陡，但换来的是跨数据库方言、原生回滚、上下文过滤和变更报告等治理能力。对于追求简单直接的团队，Flyway 依然是极佳选择；但对于**多数据库、多环境、强治理**的中大型团队，Liquibase 的投入是值得的。

记住三条铁律：**已执行的 changeset 永不修改；每个 changeset 只做一件事；生产环境回滚要三思而后行。**

如果你正在为"表结构和代码不同步"头疼，今天就把第一个 changelog 建起来吧。
