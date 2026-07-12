---
title: 【工程实战】Flyway 数据库版本迁移：从入门到团队协作最佳实践
date: 2026-07-12 08:00:00
tags:
  - Java
  - Flyway
  - 数据库
  - 版本管理
categories:
  - Java
  - 工程实践
author: 东哥
---

# 【工程实战】Flyway 数据库版本迁移：从入门到团队协作最佳实践

## 一、为什么需要数据库版本管理？

在团队协作中，数据库结构变更（DDL）经常出现以下问题：

| 问题 | 场景 | 后果 |
|------|------|------|
| 字段不一致 | 开发A加了字段，开发B不知道 | 部署报错 |
| 迁移顺序混乱 | 多人同时修改数据库结构 | 线上迁移失败 |
| 回滚困难 | 上线后发现 SQL 写错了 | 手动回滚不可追溯 |
| 环境差异 | 开发/测试/生产库结构不同 | 测试通过，上线挂掉 |

**Flyway 的解决方案**：像 Git 管理代码一样管理数据库变更，每个 SQL 脚本有版本号，按顺序执行，记录执行历史。

## 二、Flyway 核心原理

### 2.1 工作流程

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  读取迁移   │ ──► │  检查 flyway_    │ ──► │  执行未运行  │
│  脚本列表   │     │  schema_history  │     │  的迁移脚本  │
└─────────────┘     └──────────────────┘     └──────────────┘
                           │                        │
                           ▼                        ▼
                   ┌──────────────────┐     ┌──────────────┐
                   │  记录已执行的     │     │  更新校验和   │
                   │  迁移记录         │     └──────────────┘
                   └──────────────────┘
```

Flyway 会在数据库中创建一张 `flyway_schema_history` 表，记录每次迁移的执行情况：

```sql
-- flyway 自动创建的记录表
CREATE TABLE flyway_schema_history (
    installed_rank INT NOT NULL,
    version VARCHAR(50),
    description VARCHAR(200) NOT NULL,
    type VARCHAR(20) NOT NULL,
    script VARCHAR(1000) NOT NULL,
    checksum INT,
    installed_by VARCHAR(100) NOT NULL,
    installed_on TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    execution_time INT NOT NULL,
    success BOOLEAN NOT NULL,
    PRIMARY KEY (installed_rank)
);
```

### 2.2 迁移脚本命名规范

```
前缀        版本号(数字+点)    分隔符      描述              后缀
  │            │               │           │                │
  V          1.2.3          __         create_user      .sql
  │            │                       table              │
  └─ V=版本迁移                          │                └─ .sql / .java
     U=撤销迁移     ┌───────────────────┘
     R=可重复迁移  描述（可读，下划线代替空格）
```

**命名示例：**

```
V1__init_schema.sql
V1.1__add_user_table.sql
V1.2__add_user_email_index.sql
V2__create_order_table.sql
V2.1__add_order_status_index.sql
R__init_data_cleanup.sql    -- 可重复迁移（每次checksum变化重新执行）
```

## 三、Spring Boot 集成实战

### 3.1 依赖配置

```xml
<dependency>
    <groupId>org.flywaydb</groupId>
    <artifactId>flyway-core</artifactId>
</dependency>
<dependency>
    <groupId>org.flywaydb</groupId>
    <artifactId>flyway-mysql</artifactId>
</dependency>
```

### 3.2 application.yml 配置

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mydb?useSSL=false&allowPublicKeyRetrieval=true
    username: root
    password: root
  flyway:
    enabled: true
    # 迁移脚本存放目录（默认 classpath:db/migration）
    locations: classpath:db/migration
    # 编码
    encoding: UTF-8
    # 基线版本（对已有数据库设置基线）
    baseline-on-migrate: true
    baseline-version: 0
    # 执行迁移时是否校验 checksum
    validate-on-migrate: true
    # 禁止清理（生产环境务必开启！）
    clean-disabled: true
    # 迁移历史表名
    table: flyway_schema_history
    # 连接重试次数
    connect-retries: 3
```

### 3.3 完整迁移示例

**V1__create_user_table.sql**
```sql
CREATE TABLE `user` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(50) NOT NULL,
    `email` VARCHAR(100),
    `phone` VARCHAR(20),
    `status` TINYINT DEFAULT 1 COMMENT '1:正常 0:禁用',
    `create_time` DATETIME DEFAULT CURRENT_TIMESTAMP,
    `update_time` DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY `uk_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';
```

**V2__add_user_role_table.sql**
```sql
CREATE TABLE `user_role` (
    `id` BIGINT AUTO_INCREMENT PRIMARY KEY,
    `user_id` BIGINT NOT NULL,
    `role_code` VARCHAR(20) NOT NULL,
    `create_time` DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY `uk_user_role` (`user_id`, `role_code`),
    CONSTRAINT `fk_user_role_user` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户角色表';
```

## 四、如何应对已有数据库？

生产环境通常已有数据，需要设置基线（Baseline）：

```yaml
spring:
  flyway:
    # 对已有数据库做基线
    baseline-on-migrate: true
    baseline-version: 1
    baseline-description: Base migration
```

**执行流程：**

1. Flyway 检查到 `flyway_schema_history` 不存在
2. 创建历史表
3. 插入一条 Baseline 记录（版本=1，描述="Base migration"）
4. 后续只会执行版本号 > 1 的脚本

```bash
# 或手动设置基线
mvn flyway:baseline -Dflyway.baselineVersion=1
```

## 五、多环境管理策略

### 5.1 环境差异化配置

```yaml
# application-dev.yml
spring:
  flyway:
    clean-disabled: false  # 开发环境允许清理

# application-prod.yml
spring:
  flyway:
    clean-disabled: true   # 生产环境禁止清理！
```

### 5.2 分支策略

| Git 分支 | 迁移脚本目录 | 策略 |
|----------|-------------|------|
| main | db/migration | 所有正式迁移 |
| feature/xxx | db/migration/feature | 功能分支独有，合并后移到 main |
| release/* | db/migration | 仅包含版本相关迁移 |

## 六、常见问题与避坑指南

### 6.1 校验和不一致

```bash
# 场景：有人修改了已执行的 SQL 脚本
# 错误信息：Migration checksum mismatch for migration version 1.1

# 解决方案一：手动修复 checksum（不推荐）
UPDATE flyway_schema_history SET checksum = ? WHERE version = '1.1';

# 解决方案二：repair 命令
mvn flyway:repair
```

### 6.2 迁移失败处理

Flyway 默认迁移失败后**不会自动回滚已执行的部分**，因为它使用事务保证每个脚本的原子性（MySQL DDL 隐式提交，不支持回滚！）。

```bash
# 修复步骤
1. mvn flyway:repair    # 标记失败的迁移
2. 手动修复数据库状态
3. 重新执行迁移
```

### 6.3 多人协作冲突处理

| 场景 | 推荐做法 |
|------|---------|
| 同时开发两个功能都改 user 表 | 各自写独立迁移脚本，避免改同一个 V 版本 |
| 合并冲突 | Git 冲突解决后，确保版本号递增 |
| 版本号冲突 | CI 中加版本号检查：`grep -r "^V" db/migration \| sort` |

## 七、与 Liquibase 对比

| 对比维度 | Flyway | Liquibase |
|---------|--------|-----------|
| 学习曲线 | 低（纯 SQL） | 中（XML/YAML/JSON/SQL） |
| 配置复杂度 | 简单 | 中等 |
| 回滚能力 | 需手动写 U 脚本 | 自动生成回滚脚本 |
| 功能丰富度 | 核心功能精简 | 更多高级特性 |
| 社区活跃 | ★★★★★ | ★★★★ |
| Spring Boot 集成 | 原生支持 | 原生支持 |
| 推荐场景 | 中小型团队/简洁风格 | 大型企业/复杂变更需求 |

## 八、生产最佳实践 Checklist

- [x] `clean-disabled: true` 生产环境必须开启
- [x] 每个迁移脚本**原子化**：一个脚本只做一件事
- [x] **不允许修改已执行的脚本**（用新版本修复）
- [x] 迁移脚本通过 **CI/CD** 自动执行
- [x] 版本号**全局唯一递增**，不允许跳跃
- [x] 迁移脚本包含**可回滚脚本**（U 脚本）
- [x] 使用 `utf8mb4` 字符集避免 emoji 问题
- [x] DDL 中包含 `IF NOT EXISTS` 防止重复执行

## 九、总结

Flyway 是目前 Java 生态中**最简洁、最流行**的数据库版本迁移工具。它的核心优势在于：

1. **约定优于配置**：命名规范 + 自动执行
2. **纯 SQL 友好**：无需学习 DSL 语法
3. **Spring Boot 零配置集成**：加依赖即用
4. **CI/CD 友好**：可在流水线中自动执行迁移

坚持使用 Flyway 管理数据库变更，能让团队告别「手拉 SQL 上线」「环境差异」「回滚困难」的痛点。
