---
title: 【Spring Boot 实战】RBAC 权限模型与数据权限深度实战：从 RBAC0 到行级数据权限设计
date: 2026-09-01 08:00:00
tags:
  - Spring Boot
  - Spring Security
  - 权限
categories:
  - Java
  - Spring
author: 东哥
---

# 【Spring Boot 实战】RBAC 权限模型与数据权限深度实战：从 RBAC0 到行级数据权限设计

## 面试官：你们系统的权限是怎么设计的？用户 → 角色 → 权限，然后呢？

99% 的候选人能说出 RBAC 三张表，但问到「同一个角色，A 部门经理只能看自己部门的数据，B 部门经理只能看自己部门的数据，怎么实现？」就卡住了。这就是**数据权限（行级权限）**——RBAC 只管「能不能访问这个接口」，管不了「能看到哪些行」。

本文从 RBAC 模型演进讲起，到 Spring Security + 自定义数据权限注解的完整落地，一次讲透。

## 一、RBAC 模型家族：从 RBAC0 到 RBAC3

### 1.1 RBAC0（基础模型，90% 的系统够用）

```
用户(User) ──N:N──> 角色(Role) ──N:N──> 权限(Permission)
```

- **用户-角色**：一个用户可以有多个角色，一个角色可以有多个用户；
- **角色-权限**：权限不直接挂用户，而是挂角色；
- **核心价值**：权限变更只改角色，不用逐个改用户；用户入职/离职只需分配/回收角色。

对应表结构：

```sql
-- 用户表
CREATE TABLE sys_user (
    id BIGINT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password VARCHAR(100) NOT NULL,
    dept_id BIGINT,               -- 所属部门（数据权限要用）
    status TINYINT DEFAULT 1
);

-- 角色表
CREATE TABLE sys_role (
    id BIGINT PRIMARY KEY,
    role_code VARCHAR(50) UNIQUE NOT NULL,   -- 如 ADMIN、DEPT_MANAGER、SALES
    role_name VARCHAR(50) NOT NULL
);

-- 权限表（菜单/按钮/接口）
CREATE TABLE sys_permission (
    id BIGINT PRIMARY KEY,
    perm_code VARCHAR(100) UNIQUE NOT NULL,  -- 如 system:user:list
    perm_name VARCHAR(50) NOT NULL,
    perm_type TINYINT,                        -- 1菜单 2按钮 3接口
    parent_id BIGINT
);

-- 关联表
CREATE TABLE sys_user_role (user_id BIGINT, role_id BIGINT, PRIMARY KEY(user_id, role_id));
CREATE TABLE sys_role_permission (role_id BIGINT, permission_id BIGINT, PRIMARY KEY(role_id, permission_id));
```

### 1.2 RBAC1（角色继承）

角色可以继承（如「部门经理」继承「普通员工」的全部权限，再追加管理权限），适合组织层级明显的公司。实现上在角色表加 `parent_id`。

### 1.3 RBAC2（约束）

- **互斥角色**：一个用户不能同时拥有两个互斥角色（如「出纳」和「会计」不能兼任）；
- **基数约束**：一个角色最多 N 个用户（如「总经理」只能 1 人）；
- **先决条件角色**：要拥有 A 角色必须先拥有 B 角色。

### 1.4 RBAC3（继承 + 约束）

RBAC1 + RBAC2 的组合，完整模型。**实际生产 90% 用 RBAC0 + 少量自定义**就够，模型越复杂越难维护。

## 二、功能权限（能不能访问）的落地：Spring Security

功能权限控制「某个接口/按钮当前用户能不能调」。经典实现：权限点（`system:user:list`）→ 角色 → 用户，Spring Security 在过滤器链中校验。

### 2.1 权限数据加载

```java
@Service
public class UserDetailsServiceImpl implements UserDetailsService {

    @Autowired
    private SysUserMapper userMapper;

    @Override
    public UserDetails loadUserByUsername(String username) {
        SysUser user = userMapper.selectByUsername(username);
        if (user == null) {
            throw new UsernameNotFoundException("用户不存在");
        }
        // 查询角色编码 + 权限编码集合
        List<String> perms = userMapper.selectPermCodesByUserId(user.getId());
        // 放入 authorities，格式 ROLE_xxx 或权限码
        return new LoginUser(user, perms.stream()
            .map(SimpleGrantedAuthority::new).collect(Collectors.toList()));
    }
}
```

### 2.2 接口级权限校验

```java
@RestController
@RequestMapping("/system/user")
public class SysUserController {

    @PreAuthorize("hasAuthority('system:user:list')")   // 方法级权限
    @GetMapping("/list")
    public Result list(@Validated SysUserQuery query) {
        return Result.ok(userService.page(query));
    }

    @PreAuthorize("hasAuthority('system:user:delete')")
    @DeleteMapping("/{id}")
    public Result delete(@PathVariable Long id) {
        userService.deleteById(id);
        return Result.ok();
    }
}
```

需要开启方法级安全：

```java
@EnableMethodSecurity   // Spring Security 6.x；5.x 用 @EnableGlobalMethodSecurity
@SpringBootApplication
public class Application { ... }
```

**完整链路**：请求 → 过滤器链（认证）→ MethodSecurityInterceptor（鉴权）→ 有权限放行 / 无权限 403。

## 三、数据权限（能看到哪些行）的落地：自定义注解 + AOP

这是本文的重点。数据权限的典型场景：

| 场景 | 规则 |
|---|---|
| 全部数据 | 管理员看所有部门 |
| 本部门数据 | 部门经理看本部门 |
| 本部门及子部门 | 区域经理看本部门 + 下级 |
| 仅本人数据 | 销售只能看自己的订单 |
| 自定义 | 指定部门集合 |

### 3.1 设计思路

**在查询 SQL 上自动追加数据范围条件**，通过注解声明 + AOP 解析 + MyBatis 拦截器拼接，业务代码零侵入：

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface DataScope {
    String deptAlias() default "d";          // 部门表别名
    String deptIdColumn() default "dept_id"; // 部门 ID 列
    String userAlias() default "";           // 用户表别名（本人数据用）
    String userIdColumn() default "user_id"; // 用户 ID 列
}
```

### 3.2 规则解析器：根据角色算出数据范围

```java
@Component
public class DataScopeHandler {

    /** 返回 SQL 片段，如 " AND d.dept_id IN (1,2,3)" */
    public String buildScope(LoginUser user) {
        // 1. 超级管理员 → 不加条件（全量）
        if (user.isAdmin()) return "";

        // 2. 根据角色编码映射数据权限类型
        for (String roleCode : user.getRoles()) {
            switch (roleCode) {
                case "ALL_DATA":     return "";                                  // 全部
                case "DEPT_DATA":    return " AND d.dept_id = " + user.getDeptId();           // 本部门
                case "DEPT_CHILD":   return " AND d.dept_id IN (" + deptAndChildren(user.getDeptId()) + ")"; // 本部门及子部门
                case "SELF_DATA":    return " AND t.user_id = " + user.getUserId();            // 仅本人
            }
        }
        return " AND 1 = 0";   // 兜底：无权限数据范围，查不到任何数据
    }
}
```

注意 `deptAndChildren` 要递归查子部门树（用 `WITH RECURSIVE` 或先查全量部门树再内存过滤）。

### 3.3 MyBatis 拦截器：拦截查询，动态拼接

```java
@Intercepts({
    @Signature(type = Executor.class, method = "query",
        args = {MappedStatement.class, Object.class, RowBounds.class, ResultHandler.class})
})
@Component
public class DataScopeInterceptor implements Interceptor {

    @Override
    public Object intercept(Invocation invocation) throws Throwable {
        // 1. 从请求上下文拿当前用户（ThreadLocal 或 SecurityContext）
        LoginUser user = SecurityUtils.getLoginUser();
        if (user == null || user.isAdmin()) {
            return invocation.proceed();          // 管理员不拦截
        }

        // 2. 判断当前 MappedStatement 是否标记了 @DataScope
        MappedStatement ms = (MappedStatement) invocation.getArgs()[0];
        String scopeSql = DataScopeCache.get(ms.getId());
        if (scopeSql == null) return invocation.proceed();

        // 3. 改写 BoundSql，把数据权限条件拼进 WHERE
        BoundSql boundSql = ms.getBoundSql(invocation.getArgs()[1]);
        String sql = boundSql.getSql();
        String newSql = sql + scopeSql.build(user);   // 拼接 " AND d.dept_id IN (...)"
        // 4. 用反射替换 BoundSql.sql，继续执行
        ...
    }
}
```

**实现要点**：

- 拦截 `Executor.query`，在 SQL 执行前改写；
- 改写 `BoundSql` 需要反射操作（`BoundSql` 没有 setter）；
- 拼接条件要放在 `WHERE` 之后（简单场景直接 append，复杂 SQL 建议用 JSqlParser 解析 AST 精准注入）；
- **必须防止 SQL 注入**：部门 ID 集合先做数字校验，或用 `#{}` 参数绑定。

### 3.4 业务层使用

```java
@GetMapping("/list")
@PreAuthorize("hasAuthority('order:list')")   // 功能权限
@DataScope(deptAlias = "d", deptIdColumn = "dept_id")   // 数据权限
public Result list(OrderQuery query) {
    // 业务代码完全不用关心数据范围，SQL 自动带上
    return Result.ok(orderService.page(query));
}
```

```xml
<!-- Mapper 里必须 join 部门表并给别名，拦截器才能拼条件 -->
<select id="pageOrders" resultType="OrderVO">
    SELECT o.*, d.dept_name
    FROM biz_order o
    LEFT JOIN sys_dept d ON o.dept_id = d.id
    WHERE o.status = #{status}
</select>
```

最终执行的 SQL 变成：

```sql
SELECT o.*, d.dept_name FROM biz_order o
LEFT JOIN sys_dept d ON o.dept_id = d.id
WHERE o.status = ? AND d.dept_id IN (1, 2, 3)   -- 拦截器自动追加
```

## 四、数据权限的三种实现方案对比

| 方案 | 原理 | 优点 | 缺点 |
|---|---|---|---|
| **SQL 拼接（推荐）** | 拦截器/切面在 SQL 上加条件 | 性能好、可控、库压力小 | 实现复杂，需处理 SQL 改写 |
| **应用层过滤** | 查全量后在内存中过滤 | 实现简单 | 数据量大时灾难，严重浪费 |
| **视图/存储过程** | 数据库层封装权限条件 | 对应用透明 | 难维护、难扩展、性能差 |

生产环境几乎都是方案一：**MyBatis 拦截器动态拼接**（若依 RuoYi、MyBatis-Plus 的 `DataPermissionInterceptor` 都是这个思路）。

### MyBatis-Plus 内置方案

```java
// 4.x 内置数据权限拦截器
@Bean
public MybatisPlusInterceptor mybatisPlusInterceptor() {
    MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
    interceptor.addInnerInterceptor(new DataPermissionInterceptor(new MyDataPermissionHandler()));
    return interceptor;
}
```

## 五、功能权限 vs 数据权限 vs 字段权限

| 维度 | 功能权限 | 数据权限 | 字段权限 |
|---|---|---|---|
| 控制对象 | 接口/按钮/菜单 | 数据行 | 数据列 |
| 典型问题 | 能不能删除用户？ | 能不能看到别的部门的数据？ | 能不能看到手机号/身份证？ |
| 实现方式 | Spring Security + @PreAuthorize | SQL 拼接（MyBatis 拦截器） | 查询时 SELECT 列裁剪 + 返回脱敏 |
| 粒度 | 粗 | 中 | 细 |

三者的关系：**功能权限先拦「能不能进」，数据权限再拦「能看哪些行」，字段权限最后拦「能看哪些列」**。很多系统只做了第一层，第二、三层才是拉开差距的地方。

## 六、实践中的常见坑

### 坑 1：数据权限条件拼错位置，导致语法错误或绕过

复杂 SQL（带子查询、UNION、JOIN 嵌套）直接字符串 append 容易拼错。**用 JSqlParser 解析 AST，找到 WHERE 节点精准插入**，并对无法解析的 SQL 直接拒绝执行（fail-closed，安全优先）。

### 坑 2：超级管理员判断遗漏

所有拦截器逻辑第一行必须是：**管理员/内部调用放行**。否则管理员也被限死，或者内部定时任务（无用户上下文）全部查不到数据。用独立标识（如 `isAdmin` 字段或特殊角色）判断，不要硬编码用户 ID。

### 坑 3：角色编码硬编码在代码里

`case "DEPT_DATA"` 这种写法，角色一多就成意大利面。**把「角色 → 数据权限类型」做成配置**（数据库字典或配置中心），拦截器读配置动态解析。

### 坑 4：缓存了带用户条件的结果

数据权限条件因人而异，**带数据权限的查询结果不能进公共缓存**（否则 A 查到的数据缓存后 B 也能看到）。要么缓存 key 带用户维度，要么这类查询不缓存。

### 坑 5：漏掉「更新/删除」的数据权限

很多系统只给查询加了数据权限，`UPDATE`/`DELETE` 没加——用户改不了别人的数据？不，他可以直接 `DELETE FROM biz_order WHERE id = 别人的订单`。**所有涉及行级操作的 SQL 都要过数据权限拦截器。**

## 七、面试连环追问

**Q1：RBAC 的五张表是哪五张？**
用户、角色、权限三张主表 + 用户角色、角色权限两张关联表（实际是五张）。核心思想：用户不直接关联权限，中间隔一层角色。

**Q2：数据权限和功能权限的区别？**
功能权限回答「能不能做这个操作」（接口维度，Spring Security 方法级注解实现）；数据权限回答「能操作哪些数据」（行维度，SQL 拼接实现）。功能权限是粗粒度门禁，数据权限是细粒度过滤。

**Q3：你们的权限数据放在哪？为什么？**
生产用 Redis 缓存用户权限集合，key 为 `login:perms:{userId}`，登录时加载、修改权限时失效。避免每次请求都查库；权限变更通过发布事件/MQ 主动清理缓存。

**Q4：一个用户有多个角色，权限怎么合并？**
权限编码取并集（去重），数据权限取**最大范围**（比如「全部数据」+「本部门」→ 取全部数据）；如果有互斥约束（RBAC2），在分配角色时校验。

**Q5：如何防止越权（水平越权/垂直越权）？**
垂直越权靠功能权限（@PreAuthorize）拦；水平越权（A 用户改 B 用户的数据）靠**数据权限 + 资源归属校验**双保险：查出来数据后校验 `owner_id == 当前用户` 或走数据权限 SQL。**永远不要只依赖前端隐藏按钮，后端必须校验。**

## 总结

RBAC 是权限设计的基石：**用户 → 角色 → 权限**，先解决「能不能访问」。真正难的是数据权限——「能看哪些行」，生产实践是用 **@DataScope 注解 + MyBatis 拦截器 + SQL 动态拼接**，把数据范围条件自动织入所有查询，业务代码零侵入。设计时要记住三件事：管理员放行、SQL 注入防护、更新删除也要过数据权限。把功能权限、数据权限、字段权限三层都想清楚，你的权限设计就超过 90% 的系统了。
