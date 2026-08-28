---
title: 【系统设计】单点登录 SSO 架构深度解析：从 Session 共享到 CAS 票据与 OAuth2/OIDC 的演进
date: 2026-08-28 08:00:00
tags:
  - Java
  - 系统设计
  - 微服务
  - 面试
categories:
  - Java
  - 系统设计
author: 东哥
---

# 【系统设计】单点登录 SSO 架构深度解析：从 Session 共享到 CAS 票据与 OAuth2/OIDC 的演进

## 面试官：公司有 20 个系统，怎么做到"一次登录，全网通行"？

单点登录（Single Sign-On，SSO）是企业级应用绕不开的话题。面试官问这个问题，通常从最简单的场景开始，一路追问到 CAS 票据、OAuth2/OIDC、跨域 Cookie 这些细节。本文从**为什么要 SSO** 讲起，梳理三条技术路线，最后给出生产级方案。

## 一、为什么需要 SSO：痛点分析

没有 SSO 的世界是这样的：员工每天要登录 OA、ERP、GitLab、Jira、监控平台……每个系统一套账号密码，记不住、不安全、体验差。管理员的噩梦则是：离职员工的账号要在 20 个系统里逐个禁用。

SSO 的核心价值：

- **一次认证，多处访问**：在认证中心登录一次，所有接入系统免登录。
- **集中账号管理**：账号生命周期（入职/离职/改密）只在一处维护。
- **统一安全策略**：密码策略、二次认证（MFA）、风控集中在认证中心。

架构上引入一个**认证中心（Auth Center / IDP）**：

```
            ┌──────────────────────────┐
            │      认证中心 (SSO Server) │
            │  登录页 / 票据签发 / 会话管理 │
            └───────────┬──────────────┘
                        │ 信任关系
   ┌──────────┬─────────┼──────────┬──────────┐
   ▼          ▼         ▼          ▼          ▼
 系统A(OA)  系统B(ERP)  系统C(GitLab) 系统D(监控) 系统E(BI)
```

## 二、方案一：Session 共享（最简单，但治标不治本）

早期方案：把 Session 从各系统内存中挪到共享存储（Redis），所有系统共用一套 Session。

```yaml
# Spring Session + Redis
spring:
  session:
    store-type: redis
```

**优点**：改造小，Spring Session 一把梭。
**缺点**：

- 每个系统仍需自己的登录页（或跳转统一登录页）。
- 所有系统共享一个 Session 域，**耦合度高**：Session 里存什么字段各系统都得协商。
- 只解决了"会话存储"问题，没解决"认证"问题——各系统依然各自校验密码。

所以 Session 共享适合**同域下的简单多应用**，跨域、跨技术栈（Java + PHP + Go）就玩不转了。

## 三、方案二：CAS（中央认证服务）——票据机制

CAS（Central Authentication Service）是 Yale 提出的经典 SSO 协议，核心是 **TGT + ST 两级票据**：

| 票据 | 全称 | 生命周期 | 作用 |
|------|------|----------|------|
| TGT | Ticket Granting Ticket | 长（登录会话期） | 证明"用户已登录"，存在认证中心 |
| ST | Service Ticket | 短（几分钟） | 一次性，用于向具体系统换取本地会话 |
| TGC | Ticket Granting Cookie | 与 TGT 绑定 | 浏览器持有的凭证，用于免登录 |

### CAS 完整流程

```
浏览器               系统A(Client)          认证中心(CAS Server)
  │  1.访问系统A资源      │                        │
  │◄── 302 跳转 CAS 登录 ─┤                        │
  │──────────────────────────────► 2.带 service 参数 │
  │◄──── 3.返回统一登录页 ──────────────────────────┤
  │  4.输入账号密码 ────────────────────────────────►│
  │  5.校验成功：写 TGC Cookie，生成 ST             │
  │◄── 6.302 跳回 service?ticket=ST ───────────────┤
  │  7.浏览器访问系统A(带 ST)                        │
  │◄── 8.系统A 拿着 ST 去 CAS 校验 ────────────────►│
  │◄── 9.校验通过，系统A 创建本地 Session ──────────┤
  │  10.访问成功                                    │
  │                                                  │
  │  11.用户再访问系统B，浏览器带 TGC Cookie         │
  │  12.系统B 302 跳 CAS，CAS 见 TGC 有效           │
  │  13.直接发新 ST 回系统B，无需再输密码 ✓         │
```

关键代码（Java 侧使用 CAS 客户端，本质就是校验 ST）：

```java
// 伪代码：系统 A 校验 service ticket
public UserInfo validateTicket(String ticket, String service) {
    // 调用 CAS Server 的 /serviceValidate 接口
    String xml = casClient.validate(ticket, service);
    // 解析 XML 拿到 <cas:user> 用户名等属性
    return parseUser(xml);
}
```

### 核心技术点

1. **ST 一次性**：校验一次即作废，防重放。
2. **service 参数**：必须与票据签发时一致，防止票据被用于其他系统（防止"票据偷渡"）。
3. **TGC Cookie 的 Domain 问题**：CAS Server 的 Cookie 默认只对认证中心域名生效——所以跨域时浏览器每次访问新系统都要 302 到 CAS 走一遍"免登录"流程，虽然不用输密码，但**每次跳转有额外 RTT**，体验略差。

## 四、方案三：OAuth2 / OIDC——现代标准答案

CAS 解决了"登录态共享"，但它是**认证（Authentication）**协议，只回答"你是谁"。现代架构更常用 **OAuth 2.0 + OpenID Connect（OIDC）**：OAuth 管授权（Authorization），OIDC 在其上扩展了认证层（id_token）。

```
                ┌─────────────────┐
                │  认证中心 (IDP)   │
                │  Keycloak/Okta/  │
                │  自研 Spring Auth│
                └────────┬────────┘
                         │
   系统A ──OIDC 授权码───┤
   系统B ──OIDC 授权码───┤
   系统C ──SAML/ OIDC───┤
```

### 授权码模式（Authorization Code + PKCE）流程

1. 用户访问系统 A，未登录 → 系统 A 把用户重定向到认证中心 `/authorize`。
2. 用户在认证中心登录（若已有 SSO 会话则跳过）。
3. 认证中心回调系统 A：`redirect_uri?code=xxx`。
4. 系统 A 用 `code + client_secret + PKCE verifier` 换 `access_token + id_token`。
5. 系统 A 校验 `id_token`（JWT，验签）拿到用户信息，建立本地会话。

```java
// Spring Security OAuth2 Client 配置（Spring Boot 3.x）
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    http.oauth2Login(oauth -> oauth
            .loginPage("/oauth2/authorization/mysso")
            .defaultSuccessUrl("/home", true));
    return http.build();
}

// 拿到 id_token 中的用户信息
@GetMapping("/user")
public Object user(@AuthenticationPrincipal OidcUser oidcUser) {
    return Map.of(
        "name", oidcUser.getFullName(),
        "email", oidcUser.getEmail(),
        "issuer", oidcUser.getIssuer().toString()
    );
}
```

### 为什么 OIDC 是"标准答案"

| 维度 | CAS | OAuth2/OIDC |
|------|-----|-------------|
| 协议定位 | 认证 | 认证 + 授权 |
| 票据/令牌 | 私有协议 XML | 标准 JWT，可验签 |
| 生态 | 老牌，Java 友好 | 全语言通用，云厂商支持 |
| 第三方登录 | 不支持 | 天然支持（微信/Google/GitHub） |
| 适合场景 | 企业内部老系统 | 互联网产品、开放平台 |

## 五、跨域问题：SSO 的终极难点

面试官必问："系统 A 在 `a.company.com`，系统 B 在 `b.company.com`，Cookie 怎么共享？"

### 方案 1：顶级域共享 Cookie（最简单）

所有系统统一在 `.company.com` 域下，Cookie 设 `Domain=.company.com`，天然共享。

```java
Cookie cookie = new Cookie("SSO_TOKEN", token);
cookie.setDomain(".company.com");   // 关键：顶级域
cookie.setPath("/");
cookie.setHttpOnly(true);
cookie.setSecure(true);
```

**限制**：域名必须同一顶级域；`localhost` 调试时 `.localhost` 兼容性差；跨公司（不同域名）场景失效。

### 方案 2：认证中心重定向 + 票据下发（CAS 的做法，通用）

浏览器访问系统 B → 302 到认证中心 → 认证中心发现 TGC 有效 → 签发新 ST → 302 回系统 B → 系统 B 校验 ST 建会话。**Cookie 只在认证中心域名下，通过重定向完成跨域传递**，任何域名组合都能用。

### 方案 3：前端 + Token 方案（现代 SPA）

前后端分离架构下，登录态由前端持有（localStorage 存 access_token / refresh_token），各系统后端只验签 JWT，不依赖 Cookie 域。跨域问题变成纯前端的路由跳转问题，配合 iframe + postMessage 或直接跳转即可。

## 六、生产级 SSO 的选型与架构

自研还是用现成的？给出务实建议：

| 方案 | 成本 | 适用场景 |
|------|------|----------|
| Spring Authorization Server（自研） | 中 | 技术栈统一、需要深度定制 |
| Keycloak | 低 | 需要开箱即用的登录页、MFA、用户管理 |
| CAS Server（Apereo CAS） | 中 | 存量老系统改造、需要 CAS 协议 |
| 云 IDaaS（Authing/Okta） | 低 | 不想运维认证中心 |

**关键架构原则：**

1. **认证中心必须是独立部署、高可用的**——它挂了所有系统都登不了，比业务系统更金贵。
2. **接入方只认令牌不认密码**：业务系统永远不碰用户密码，密码只存在于认证中心。
3. **令牌最小化**：access_token 短时效（15 分钟）+ refresh_token 长时效（7 天）双令牌，降低泄露风险。
4. **统一登出（SLO）**：认证中心登出后要通知所有已接入系统销毁本地会话（回调或消息队列广播）。

## 七、面试追问汇总

**Q1：CAS 和 OAuth2 什么区别？**
答：CAS 是纯认证协议，回答"你是谁"；OAuth2 是授权协议，回答"允许你做什么"，OIDC 在 OAuth2 之上加认证层。现代新系统优先 OIDC，老系统改造可用 CAS，两者可以共存（Keycloak 两种协议都支持）。

**Q2：ST 和 access_token 都能防重放吗？**
答：ST 一次性使用天然防重放；access_token 是多次使用的，所以要靠短时效 + HTTPS + 必要时做 token 轮换/吊销来降低风险。

**Q3：用户改了密码，已登录的其他系统会掉线吗？**
答：取决于会话模型。认证中心改密后 TGT 失效，用户下次访问其他系统重新走免登录流程时会发现 TGT 无效而要求重新登录；但各系统本地已建立的会话（本地 Session/token）默认不受影响，除非做全局会话吊销（token 版本号 + 广播）。

**Q4：微服务架构下 SSO 怎么做？**
答：网关层统一鉴权——认证中心登录后发 JWT，网关校验 JWT 并透传用户上下文（`X-User-Id` 头），下游服务不再关心认证细节。这就是"认证下沉到网关"的模式。

## 总结

SSO 的演进脉络很清晰：**Session 共享解决存储 → CAS 票据解决跨系统认证 → OAuth2/OIDC 解决开放生态**。面试时从痛点出发，把 CAS 的 TGT/ST 两级票据和 OIDC 授权码流程画出来，再答出跨域 Cookie 和统一登出这两个细节，就能拿满分。
