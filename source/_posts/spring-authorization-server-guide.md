---
title: Spring Authorization Server实战指南
date: 2026-06-20 08:00:00
tags:
  - Spring Security
  - OAuth2
  - Authorization Server
  - 安全
  - JWT
categories:
  - Spring Security
author: 东哥
---

# Spring Authorization Server实战指南

Spring Authorization Server是Spring Security团队正式推出的OAuth 2.1授权服务器实现，取代了已废弃的Spring Security OAuth 2.0项目。本文将深入讲解如何基于Spring Authorization Server 3.x构建生产级授权服务器。

## 一、OAuth 2.1的变化

### 1.1 OAuth 2.0 vs 2.1 核心变化

| 特性 | OAuth 2.0 (RFC 6749) | OAuth 2.1 (RFC尚未正式发布，draft) |
|-----|---------------------|--------------------------------|
| 授权码模式 | PKCE可选 | PKCE强制要求 |
| 简化模式(Implicit) | 支持 | 已移除 |
| 密码模式 | 支持 | 已移除 |
| 客户端凭证 | 支持 | 支持 |
| Refresh Token | 可选 | 可选但推荐 |
| Redirect URI | 部分匹配 | 精确匹配 |
| JWT用于授权码 | 不支持 | 支持(JARM) |
| Token Replay检测 | 不强制 | 推荐 |

### 1.2 Spring Authorization Server支持的OAuth 2.1授权流程

1. **授权码流程（Authorization Code + PKCE）**
2. **客户端凭证流程（Client Credentials）** 
3. **设备授权流程（Device Authorization Grant）**
4. **Token刷新流程（Refresh Token）**
5. **OIDC 1.0支持**

## 二、项目搭建

### 2.1 依赖配置

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.2.0</version>
</parent>

<dependencies>
    <!-- Spring Authorization Server -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-authorization-server</artifactId>
    </dependency>
    
    <!-- Spring Security -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>
    
    <!-- Spring Web -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    
    <!-- JPA + PostgreSQL (用于持久化客户端和授权信息) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
        <groupId>org.postgresql</groupId>
        <artifactId>postgresql</artifactId>
    </dependency>
    
    <!-- Redis (Token存储) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-redis</artifactId>
    </dependency>
</dependencies>
```

### 2.2 核心配置类

```java
@Configuration
@EnableWebSecurity
public class AuthorizationServerConfig {
    
    // 授权服务器安全配置
    @Bean
    @Order(1)
    public SecurityFilterChain authorizationServerSecurityFilterChain(
            HttpSecurity http, RegisteredClientRepository clientRepository,
            AuthorizationServerSettings authorizationServerSettings) throws Exception {
        
        OAuth2AuthorizationServerConfiguration.applyDefaultSecurity(http);
        
        http.getConfigurer(OAuth2AuthorizationServerConfigurer.class)
            .authorizationEndpoint(auth -> auth
                .authenticationProviders(providers -> 
                    providers.add(new PkceAuthenticationProvider())))
            .tokenEndpoint(token -> token
                .accessTokenRequestConverters(converters -> 
                    converters.add(new CustomTokenRequestConverter())))
            .clientAuthentication(client -> client
                .authenticationProviders(this::configureClientAuth));
        
        http.oauth2ResourceServer(oauth2 -> oauth2
            .jwt(Customizer.withDefaults()));
        
        return http.build();
    }
    
    // Spring Security 登录页面配置
    @Bean
    @Order(2)
    public SecurityFilterChain defaultSecurityFilterChain(HttpSecurity http) 
            throws Exception {
        http.authorizeHttpRequests(authorize -> authorize
                .requestMatchers("/auth/**", "/login", "/oauth2/**").permitAll()
                .anyRequest().authenticated())
            .formLogin(Customizer.withDefaults());
        return http.build();
    }
    
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
    
    @Bean
    public AuthorizationServerSettings authorizationServerSettings() {
        return AuthorizationServerSettings.builder()
            .issuer("https://auth.example.com")
            .authorizationEndpoint("/oauth2/authorize")
            .tokenEndpoint("/oauth2/token")
            .tokenRevocationEndpoint("/oauth2/revoke")
            .tokenIntrospectionEndpoint("/oauth2/introspect")
            .jwkSetEndpoint("/oauth2/jwks")
            .oidcUserInfoEndpoint("/userinfo")
            .oidcLogoutEndpoint("/logout")
            .build();
    }
}
```

## 三、客户端注册与配置

### 3.1 持久化客户端注册信息

```java
@Entity
@Table(name = "oauth2_registered_client")
public class ClientEntity {
    
    @Id
    private String id;
    
    @Column(name = "client_id", unique = true, nullable = false)
    private String clientId;
    
    @Column(name = "client_secret")
    private String clientSecret;
    
    @Column(name = "client_name", nullable = false)
    private String clientName;
    
    @Column(name = "client_authentication_methods", nullable = false)
    private String clientAuthenticationMethods;
    
    @Column(name = "authorization_grant_types", nullable = false)
    private String authorizationGrantTypes;
    
    @Column(name = "redirect_uris")
    private String redirectUris;
    
    @Column(name = "scopes", nullable = false)
    private String scopes;
    
    @Column(name = "client_settings")
    private String clientSettings;
    
    @Column(name = "token_settings")
    private String tokenSettings;
    
    // getters and setters
}

@Repository
public interface ClientRepository extends JpaRepository<ClientEntity, String> {
    Optional<ClientEntity> findByClientId(String clientId);
}

@Component
public class JpaRegisteredClientRepository implements RegisteredClientRepository {
    
    private final ClientRepository clientRepository;
    
    public JpaRegisteredClientRepository(ClientRepository clientRepository) {
        this.clientRepository = clientRepository;
    }
    
    @Override
    public void save(RegisteredClient registeredClient) {
        ClientEntity entity = toEntity(registeredClient);
        clientRepository.save(entity);
    }
    
    @Override
    public RegisteredClient findById(String id) {
        return clientRepository.findById(id)
            .map(this::toObject)
            .orElse(null);
    }
    
    @Override
    public RegisteredClient findByClientId(String clientId) {
        return clientRepository.findByClientId(clientId)
            .map(this::toObject)
            .orElse(null);
    }
    
    private RegisteredClient toObject(ClientEntity entity) {
        Set<String> clientAuthMethods = Set.of(
            entity.getClientAuthenticationMethods().split(","));
        Set<String> grantTypes = Set.of(
            entity.getAuthorizationGrantTypes().split(","));
        Set<String> scopes = Set.of(entity.getScopes().split(","));
        
        return RegisteredClient.withId(entity.getId())
            .clientId(entity.getClientId())
            .clientSecret(entity.getClientSecret())
            .clientName(entity.getClientName())
            .clientAuthenticationMethods(methods -> 
                clientAuthMethods.forEach(m -> 
                    methods.add(new ClientAuthenticationMethod(m))))
            .authorizationGrantTypes(grants -> 
                grantTypes.forEach(g -> 
                    grants.add(new AuthorizationGrantType(g))))
            .redirectUris(uris -> 
                Arrays.stream(entity.getRedirectUris().split(","))
                    .forEach(uris::add))
            .scopes(s -> scopes.forEach(s::add))
            .clientSettings(ClientSettings.builder()
                .requireAuthorizationConsent(true)
                .requireProofKey(true)
                .build())
            .tokenSettings(TokenSettings.builder()
                .accessTokenTimeToLive(Duration.ofHours(1))
                .refreshTokenTimeToLive(Duration.ofDays(30))
                .reuseRefreshTokens(false)
                .build())
            .build();
    }
    
    private ClientEntity toEntity(RegisteredClient client) {
        ClientEntity entity = new ClientEntity();
        entity.setId(client.getId());
        entity.setClientId(client.getClientId());
        entity.setClientSecret(client.getClientSecret());
        entity.setClientName(client.getClientName());
        entity.setClientAuthenticationMethods(String.join(",",
            client.getClientAuthenticationMethods().stream()
                .map(ClientAuthenticationMethod::getValue).toList()));
        entity.setAuthorizationGrantTypes(String.join(",",
            client.getAuthorizationGrantTypes().stream()
                .map(AuthorizationGrantType::getValue).toList()));
        entity.setRedirectUris(String.join(",", client.getRedirectUris()));
        entity.setScopes(String.join(",", client.getScopes()));
        return entity;
    }
}
```

### 3.2 初始化客户端配置

```java
@Component
public class ClientInitializer implements CommandLineRunner {
    
    private final RegisteredClientRepository clientRepository;
    private final PasswordEncoder passwordEncoder;
    
    @Override
    public void run(String... args) {
        // 注册 SPA 前端客户端
        registerSpaClient();
        
        // 注册 移动端 客户端
        registerMobileClient();
        
        // 注册 后端服务 客户端
        registerBackendClient();
    }
    
    private void registerSpaClient() {
        if (clientRepository.findByClientId("spa-client") != null) return;
        
        RegisteredClient spaClient = RegisteredClient.withId(UUID.randomUUID().toString())
            .clientId("spa-client")
            .clientSecret(passwordEncoder.encode("spa-secret"))
            .clientName("Single Page Application")
            .clientAuthenticationMethods(methods -> 
                methods.add(ClientAuthenticationMethod.NONE))  // SPA使用PKCE
            .authorizationGrantTypes(grants -> 
                grants.add(AuthorizationGrantType.AUTHORIZATION_CODE))
            .redirectUris(uris -> {
                uris.add("http://localhost:3000/callback");
                uris.add("http://localhost:3000/silent-refresh");
            })
            .scopes(scopes -> {
                scopes.add("openid");
                scopes.add("profile");
                scopes.add("email");
                scopes.add("api:read");
                scopes.add("api:write");
            })
            .clientSettings(ClientSettings.builder()
                .requireAuthorizationConsent(true)
                .requireProofKey(true)  // PKCE强制
                .build())
            .tokenSettings(TokenSettings.builder()
                .accessTokenTimeToLive(Duration.ofMinutes(30))
                .refreshTokenTimeToLive(Duration.ofDays(7))
                .reuseRefreshTokens(false)
                .build())
            .build();
        
        clientRepository.save(spaClient);
    }
    
    private void registerBackendClient() {
        if (clientRepository.findByClientId("backend-service") != null) return;
        
        RegisteredClient backendClient = RegisteredClient.withId(UUID.randomUUID().toString())
            .clientId("backend-service")
            .clientSecret(passwordEncoder.encode("backend-secret-2024"))
            .clientName("Backend Microservice")
            .clientAuthenticationMethods(methods -> 
                methods.add(ClientAuthenticationMethod.CLIENT_SECRET_BASIC))
            .authorizationGrantTypes(grants -> 
                grants.add(AuthorizationGrantType.CLIENT_CREDENTIALS))
            .scopes(scopes -> {
                scopes.add("api:read");
                scopes.add("api:write");
                scopes.add("internal:admin");
            })
            .tokenSettings(TokenSettings.builder()
                .accessTokenTimeToLive(Duration.ofHours(2))
                .build())
            .build();
        
        clientRepository.save(backendClient);
    }
}
```

## 四、Token定制与签发

### 4.1 自定义JWT Token

```java
@Component
public class CustomTokenCustomizer implements OAuth2TokenCustomizer<JwtEncodingContext> {
    
    @Override
    public void customize(JwtEncodingContext context) {
        // 根据授权类型添加不同claims
        switch (context.getAuthorizationGrantType().getValue()) {
            case "authorization_code" -> customizeForUser(context);
            case "client_credentials" -> customizeForService(context);
        }
    }
    
    private void customizeForUser(JwtEncodingContext context) {
        OAuth2Authentication authentication = context.getPrincipal();
        UserDetails userDetails = (UserDetails) authentication.getPrincipal();
        
        context.getClaims().claims(claims -> {
            // 用户基本信息
            claims.put("sub", userDetails.getUsername());
            claims.put("name", userDetails.getDisplayName());
            claims.put("email", userDetails.getEmail());
            
            // 用户角色和权限
            claims.put("roles", userDetails.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .filter(a -> a.startsWith("ROLE_"))
                .collect(Collectors.toList()));
            claims.put("permissions", userDetails.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .filter(a -> !a.startsWith("ROLE_"))
                .collect(Collectors.toList()));
            
            // 安全增强
            claims.put("auth_time", Instant.now().getEpochSecond());
            claims.put("client_id", context.getRegisteredClient().getClientId());
        });
    }
    
    private void customizeForService(JwtEncodingContext context) {
        context.getClaims().claims(claims -> {
            claims.put("sub", context.getRegisteredClient().getClientId());
            claims.put("client_name", context.getRegisteredClient().getClientName());
            
            // 服务间调用的安全信息
            claims.put("service_type", "backend");
            claims.put("allowed_ips", List.of("10.0.0.0/8", "172.16.0.0/12"));
        });
    }
}
```

### 4.2 JWT密钥管理

```java
@Configuration
public class JwkConfig {
    
    @Value("${jwt.rsa.public-key-location}")
    private String publicKeyLocation;
    
    @Value("${jwt.rsa.private-key-location}")
    private String privateKeyLocation;
    
    @Bean
    public JWKSource<SecurityContext> jwkSource() {
        RSAKey rsaKey = loadRsaKey();
        JWKSet jwkSet = new JWKSet(rsaKey);
        return (jwkSelector, securityContext) -> jwkSelector.select(jwkSet);
    }
    
    private RSAKey loadRsaKey() {
        try {
            // 从文件加载RSA密钥对
            PrivateKey privateKey = loadPrivateKey(privateKeyLocation);
            PublicKey publicKey = loadPublicKey(publicKeyLocation);
            
            return new RSAKey.Builder(publicKey)
                .privateKey(privateKey)
                .keyID(UUID.randomUUID().toString())
                .keyUse(KeyUse.SIGNATURE)
                .algorithm(JWSAlgorithm.RS256)
                .issueTime(new Date())
                .build();
        } catch (Exception e) {
            throw new RuntimeException("Failed to load RSA key", e);
        }
    }
    
    @Bean
    public NimbusJwtDecoder jwtDecoder(JWKSource<SecurityContext> jwkSource) {
        return NimbusJwtDecoder.withJwkSource(jwkSource).build();
    }
}
```

### 4.3 Token持久化

```java
@Component
public class RedisAuthorizationService implements OAuth2AuthorizationService {
    
    private final StringRedisTemplate redisTemplate;
    private static final String TOKEN_PREFIX = "oauth2:token:";
    private static final long TOKEN_TTL = 3600; // 1 hour
    
    public RedisAuthorizationService(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }
    
    @Override
    public void save(OAuth2Authorization authorization) {
        String key = TOKEN_PREFIX + authorization.getId();
        try {
            String value = serialize(authorization);
            redisTemplate.opsForValue().set(key, value, TOKEN_TTL, TimeUnit.SECONDS);
        } catch (IOException e) {
            throw new RuntimeException("Failed to save authorization", e);
        }
    }
    
    @Override
    public void remove(OAuth2Authorization authorization) {
        redisTemplate.delete(TOKEN_PREFIX + authorization.getId());
    }
    
    @Override
    public OAuth2Authorization findById(String id) {
        String value = redisTemplate.opsForValue().get(TOKEN_PREFIX + id);
        if (value == null) return null;
        try {
            return deserialize(value);
        } catch (IOException e) {
            return null;
        }
    }
    
    @Override
    public OAuth2Authorization findByToken(String token, OAuth2TokenType tokenType) {
        // 实际应用中需要建立token值到authorization的索引
        // 这里使用Token本身的值作为搜索键
        Set<String> keys = redisTemplate.keys(TOKEN_PREFIX + "*");
        if (keys == null) return null;
        
        for (String key : keys) {
            try {
                OAuth2Authorization auth = deserialize(redisTemplate.opsForValue().get(key));
                if (auth != null && matchesToken(auth, token, tokenType)) {
                    return auth;
                }
            } catch (IOException ignored) {}
        }
        return null;
    }
}
```

## 五、资源服务器集成

### 5.1 资源服务器配置

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://auth.example.com
          jwk-set-uri: https://auth.example.com/oauth2/jwks
```

```java
@Configuration
@EnableWebSecurity
public class ResourceServerConfig {
    
    @Bean
    public SecurityFilterChain resourceServerFilterChain(HttpSecurity http) throws Exception {
        http.authorizeHttpRequests(authorize -> authorize
                .requestMatchers("/api/public/**").permitAll()
                .requestMatchers("/api/admin/**").hasAuthority("SCOPE_internal:admin")
                .requestMatchers("/api/users/**").hasAuthority("SCOPE_api:read")
                .requestMatchers("/api/orders/**").hasAuthority("SCOPE_api:write")
                .anyRequest().authenticated())
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt
                    .jwtAuthenticationConverter(jwtAuthenticationConverter())));
        return http.build();
    }
    
    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter grantedConverter = new JwtGrantedAuthoritiesConverter();
        grantedConverter.setAuthorityPrefix("SCOPE_");
        grantedConverter.setAuthoritiesClaimName("scope");
        
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(grantedConverter);
        
        // 自定义用户信息提取
        converter.setJwtGrantedAuthoritiesConverter(jwt -> {
            Collection<GrantedAuthority> authorities = new ArrayList<>();
            
            // 从scope获取权限
            jwt.getClaimAsStringList("scope").forEach(scope -> 
                authorities.add(new SimpleGrantedAuthority("SCOPE_" + scope)));
            
            // 从roles获取权限
            List<String> roles = jwt.getClaim("roles");
            if (roles != null) {
                roles.forEach(role -> 
                    authorities.add(new SimpleGrantedAuthority(role)));
            }
            
            return authorities;
        });
        
        return converter;
    }
}
```

### 5.2 获取当前用户信息

```java
@RestController
@RequestMapping("/api")
public class UserController {
    
    @GetMapping("/me")
    public ResponseEntity<UserInfoResponse> getCurrentUser(
            @AuthenticationPrincipal Jwt jwt) {
        
        UserInfoResponse response = new UserInfoResponse(
            jwt.getSubject(),
            jwt.getClaimAsString("name"),
            jwt.getClaimAsString("email"),
            jwt.getClaimAsStringList("roles"),
            jwt.getClaimAsStringList("permissions")
        );
        
        return ResponseEntity.ok(response);
    }
    
    // 使用@CurrentUser自定义注解
    @GetMapping("/orders")
    public ResponseEntity<List<Order>> getOrders(
            @CurrentUser UserDetails user) {
        return ResponseEntity.ok(orderService.findByUserId(user.getId()));
    }
}

// 自定义注解
@Target(ElementType.PARAMETER)
@Retention(RetentionPolicy.RUNTIME)
public @interface CurrentUser {}

@Component
public class CurrentUserArgumentResolver implements HandlerMethodArgumentResolver {
    
    @Override
    public boolean supportsParameter(MethodParameter parameter) {
        return parameter.hasParameterAnnotation(CurrentUser.class)
            && UserDetails.class.isAssignableFrom(parameter.getParameterType());
    }
    
    @Override
    public Object resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof UserDetails user) {
            return user;
        }
        return null;
    }
}
```

## 六、OIDC与UserInfo端点

### 6.1 OIDC配置

```java
@Component
public class OidcConfigurer {
    
    @Bean
    public OidcUserInfoService oidcUserInfoService(UserService userService) {
        return authentication -> {
            JwtAuthenticationToken jwtAuth = (JwtAuthenticationToken) authentication;
            String username = jwtAuth.getToken().getSubject();
            
            UserDetails user = userService.findByUsername(username);
            
            return new OidcUserInfo()
                .claim("sub", user.getUsername())
                .claim("name", user.getDisplayName())
                .claim("preferred_username", user.getUsername())
                .claim("email", user.getEmail())
                .claim("email_verified", user.isEmailVerified())
                .claim("picture", user.getAvatarUrl())
                .claim("updated_at", user.getUpdatedAt());
        };
    }
}
```

### 6.2 PKCE流程完整示例（前端侧）

```javascript
// 前端SPA PKCE授权码流程
class AuthService {
  constructor() {
    this.clientId = 'spa-client';
    this.redirectUri = 'http://localhost:3000/callback';
    this.authorizationEndpoint = 'https://auth.example.com/oauth2/authorize';
    this.tokenEndpoint = 'https://auth.example.com/oauth2/token';
  }

  // 生成PKCE验证码和挑战码
  async generatePKCE() {
    const array = new Uint8Array(32);
    crypto.getRandomValues(array);
    const verifier = this.base64URLEncode(array);
    
    const hash = await crypto.subtle.digest('SHA-256', 
      new TextEncoder().encode(verifier));
    const challenge = this.base64URLEncode(new Uint8Array(hash));
    
    return { verifier, challenge };
  }

  base64URLEncode(buffer) {
    return btoa(String.fromCharCode(...new Uint8Array(buffer)))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');
  }

  // 开始授权流程
  async login() {
    const { verifier, challenge } = await this.generatePKCE();
    
    // 存储验证码到sessionStorage
    sessionStorage.setItem('pkce_verifier', verifier);
    
    // 构建授权请求URL
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: this.clientId,
      redirect_uri: this.redirectUri,
      code_challenge: challenge,
      code_challenge_method: 'S256',
      scope: 'openid profile email api:read api:write',
      state: this.generateState()
    });
    
    sessionStorage.setItem('oauth_state', params.get('state'));
    window.location.href = `${this.authorizationEndpoint}?${params}`;
  }

  // 处理回调
  async handleCallback(code, state) {
    const savedState = sessionStorage.getItem('oauth_state');
    if (state !== savedState) {
      throw new Error('State mismatch - CSRF detected');
    }
    
    const verifier = sessionStorage.getItem('pkce_verifier');
    
    const response = await fetch(this.tokenEndpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: this.redirectUri,
        client_id: this.clientId,
        code_verifier: verifier
      })
    });
    
    const tokens = await response.json();
    this.storeTokens(tokens);
    return tokens;
  }
}
```

## 七、安全增强实践

### 7.1 Token安全策略

```java
@Bean
public OAuth2TokenGenerator<?> tokenGenerator(JWKSource<SecurityContext> jwkSource) {
    JwtGenerator jwtGenerator = new JwtGenerator(jwkSource);
    jwtGenerator.setJwtCustomizer(tokenCustomizer());
    
    // OIDC ID Token配置
    OAuth2TokenGenerator<OidcIdToken> oidcGenerator = 
        new OidcIdTokenGenerator(jwtGenerator);
    
    return new DelegatingOAuth2TokenGenerator(
        jwtGenerator,
        oidcGenerator,
        new OAuth2AccessTokenGenerator(),
        new OAuth2RefreshTokenGenerator()
    );
}

// Token安全配置
@Bean
public OAuth2AuthorizationServerConfigurer authorizationServerConfigurer() {
    OAuth2AuthorizationServerConfigurer configurer = 
        new OAuth2AuthorizationServerConfigurer();
    
    // 启用Token Replay Detection
    configurer.tokenIntrospectionEndpoint(introspection -> 
        introspection.introspectionRequestConverter(new CustomIntrospectionConverter()));
    
    // JARM (JWT Secured Authorization Response Mode)
    configurer.authorizationEndpoint(auth -> 
        auth.authorizationResponseConverters(converters -> 
            converters.add(new JwtAuthorizationResponseConverter())));
    
    return configurer;
}
```

### 7.2 多租户支持

```java
@Component
public class TenantAwareClientRepository implements RegisteredClientRepository {
    
    private final Map<String, RegisteredClientRepository> tenantRepositories;
    
    @Override
    public void save(RegisteredClient registeredClient) {
        String tenantId = resolveTenant();
        tenantRepositories.get(tenantId).save(registeredClient);
    }
    
    @Override
    public RegisteredClient findById(String id) {
        String tenantId = resolveTenant();
        return tenantRepositories.get(tenantId).findById(id);
    }
    
    @Override
    public RegisteredClient findByClientId(String clientId) {
        // 根据clientId前缀解析租户
        String tenantId = clientId.split("_")[0];
        return tenantRepositories.get(tenantId).findByClientId(clientId);
    }
    
    private String resolveTenant() {
        // 从请求上下文中获取租户
        HttpServletRequest request = ((ServletRequestAttributes) 
            RequestContextHolder.currentRequestAttributes()).getRequest();
        return request.getHeader("X-Tenant-Id");
    }
}
```

## 八、运维与监控

### 8.1 Actuator监控

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,metrics,auditevents
  endpoint:
    auditevents:
      enabled: true

# 审计日志追踪
spring:
  security:
    oauth2:
      authorization-server:
        audit:
          event-repository:
            in-memory:
              capacity: 10000
```

### 8.2 Token颁发量监控

```java
@Component
public class TokenMetricCollector {
    
    private final MeterRegistry meterRegistry;
    
    @EventListener
    public void onTokenIssued(AuthorizationGrantAuthenticationToken event) {
        Counter.builder("oauth2.token.issued")
            .tag("grant_type", event.getGrantType().getValue())
            .tag("client_id", event.getClientPrincipal().getName())
            .register(meterRegistry)
            .increment();
    }
}
```

## 九、总结

Spring Authorization Server为Java生态提供了现代、标准化的OAuth 2.1授权服务器实现。在生产环境中使用时应关注：

1. **PKCE强制使用**：SPA和移动端必须启用PKCE
2. **密钥轮转**：定期轮换JWT签名密钥
3. **Token生命周期**：Access Token短生命周期（15-30分钟），Refresh Token可长期（7-30天）
4. **审计日志**：记录所有Token颁发和认证事件
5. **性能考量**：高并发场景下使用Redis存储Token，引入JWT缓存
6. **多环境配置**：开发/测试/生产环境使用不同的密钥和端点
