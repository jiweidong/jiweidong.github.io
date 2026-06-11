---
title: SpringBoot 整合 MyBatis-Plus 最佳实践
date: 2026-06-08 23:24:00
tags: [SpringBoot, MyBatis-Plus]
categories: SpringBoot
---

## 前言

MyBatis-Plus 是 MyBatis 的增强工具，在 MyBatis 的基础上只做增强不做改变，为简化开发而生。

## 快速入门

### 1. 引入依赖

```xml
<dependency>
    <groupId>com.baomidou</groupId>
    <artifactId>mybatis-plus-spring-boot3-starter</artifactId>
    <version>3.5.5</version>
</dependency>
```

### 2. 配置

```yaml
mybatis-plus:
  mapper-locations: classpath:mapper/*.xml
  configuration:
    log-impl: org.apache.ibatis.logging.stdout.StdOutImpl
    map-underscore-to-camel-case: true
  global-config:
    db-config:
      id-type: auto
```

### 3. 实体类

```java
@Data
@TableName("user")
public class User {
    @TableId(type = IdType.AUTO)
    private Long id;
    private String name;
    private Integer age;
    private String email;
    @TableField(fill = FieldFill.INSERT)
    private LocalDateTime createdAt;
}
```

### 4. Mapper

```java
@Mapper
public interface UserMapper extends BaseMapper<User> {
}
```

### 5. 使用

```java
@Service
public class UserService {
    @Autowired
    private UserMapper userMapper;

    public List<User> findAll() {
        return userMapper.selectList(null);
    }

    public User findById(Long id) {
        return userMapper.selectById(id);
    }
}
```

## 常用功能

### 条件构造器

```java
// 查询年龄大于 18 的用户
LambdaQueryWrapper<User> wrapper = new LambdaQueryWrapper<>();
wrapper.gt(User::getAge, 18);
List<User> users = userMapper.selectList(wrapper);
```

### 分页查询

```java
Page<User> page = userMapper.selectPage(
    new Page<>(1, 10), null
);
```

MyBatis-Plus 让数据库操作变得非常丝滑，强烈推荐！
