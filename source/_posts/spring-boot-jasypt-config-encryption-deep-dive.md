---
title: 【Spring Boot 实战】Jasypt 配置加密深度实战：配置文件敏感信息加密从入门到原理
date: 2026-08-27 08:00:00
tags:
  - Java
  - Spring Boot
  - 安全
  - 加密
categories:
  - Java
  - Spring Boot
author: 东哥
---

# 【Spring Boot 实战】Jasypt 配置加密深度实战：配置文件敏感信息加密从入门到原理

## 面试官：你们的数据库密码是明文写在配置文件里的吗？

很多团队把 `spring.datasource.password=123456` 直接明文放在 application.yml 里，还提交到了 Git 仓库——这是生产环境最典型的安全隐患之一。任何一个能读到代码仓库的人，都拿到了你所有环境的数据库口令。

今天的主题就是解决这个问题：**用 Jasypt（Java Simplified Encryption）对 Spring Boot 配置中的敏感信息进行加密**。从引入依赖、加解密命令、配置方式，一路挖到它的底层原理和源码实现。

## 一、Jasypt 是什么

Jasypt 是一个 Java 加密库，提供简单易用的 API 进行对称/非对称加密。它和 Spring Boot 集成后，可以在**配置加载阶段**自动解密 `ENC(...)` 包裹的密文：

```yaml
spring:
  datasource:
    username: root
    # ENC() 包裹的即为密文，应用启动时自动解密
    password: ENC(Xy3vL8kPq2wE7uRz9mN1bCd4fGh5jKl6)
```

开发者提交到仓库的是密文，真正密码只有运维/密钥持有者知道。**密钥通过环境变量或启动参数注入**，不进代码库。

## 二、快速上手

### 2.1 引入依赖

```xml
<dependency>
    <groupId>com.github.ulisesbocchio</groupId>
    <artifactId>jasypt-spring-boot-starter</artifactId>
    <version>3.0.5</version>
</dependency>
```

### 2.2 生成密文

方式一：命令行（需要先 `mvn package` 拿到 jar，或用 Maven 插件）：

```bash
# 使用 jasypt 命令行工具
java -cp jasypt-1.9.3.jar org.jasypt.intf.cli.JasyptPBEStringEncryptionCLI \
  input="MyP@ssw0rd" password="your-secret-key" algorithm=PBEWithMD5AndDES
```

方式二：Java 代码生成（更常用，CI 里可以写脚本）：

```java
import org.jasypt.encryption.pbe.StandardPBEStringEncryptor;

public class EncryptDemo {
    public static void main(String[] args) {
        StandardPBEStringEncryptor encryptor = new StandardPBEStringEncryptor();
        encryptor.setPassword("your-secret-key");          // 密钥
        encryptor.setAlgorithm("PBEWithHMACSHA512AndAES_256"); // 算法
        
        String plain = "MyP@ssw0rd";
        String encrypted = encryptor.encrypt(plain);
        System.out.println("密文: ENC(" + encrypted + ")");
        
        // 验证解密
        System.out.println("解密: " + encryptor.decrypt(encrypted));
    }
}
```

### 2.3 配置使用

```yaml
jasypt:
  encryptor:
    # 密钥来源：环境变量，不写死在配置文件
    password: ${JASYPT_PASSWORD}
    algorithm: PBEWithHMACSHA512AndAES_256
    iv-generator-classname: org.jasypt.iv.RandomIvGenerator
```

启动时通过环境变量注入密钥：

```bash
export JASYPT_PASSWORD=your-secret-key
java -jar app.jar
# 或者：java -jar app.jar --jasypt.encryptor.password=your-secret-key
```

> ⚠️ **重要**：Jasypt 3.x 默认算法从 `PBEWithMD5AndDES` 升级为 `PBEWITHHMACSHA512ANDAES_256`，且默认要求提供 IV 生成器。老配置不显式指定算法会启动报错，迁移时注意。

## 三、进阶用法

### 3.1 自定义前缀/后缀

默认 `ENC(...)`，可以改成自定义的：

```yaml
jasypt:
  encryptor:
    property:
      prefix: "DEC["
      suffix: "]"
```

### 3.2 自定义加密器（对接公司密钥管理系统 KMS）

生产环境更推荐对接 KMS 或自研加解密服务，实现 `StringEncryptor` 接口即可：

```java
import org.jasypt.encryption.StringEncryptor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class JasyptConfig {

    @Bean("jasyptStringEncryptor")
    public StringEncryptor kmsStringEncryptor() {
        return new StringEncryptor() {
            @Override
            public String encrypt(String plainText) {
                // 调用公司 KMS / 加解密服务
                return KmsClient.encrypt(plainText);
            }

            @Override
            public String decrypt(String encryptedText) {
                return KmsClient.decrypt(encryptedText);
            }
        };
    }
}
```

### 3.3 多密钥/密钥轮换

密钥泄露后要轮换：Jasypt 支持在配置里放多个密钥（用逗号分隔），解密时按顺序尝试：

```yaml
jasypt:
  encryptor:
    password: ${OLD_PASSWORD},${NEW_PASSWORD}
```

先解密旧密文，再重新加密为新密钥的密文，完成平滑轮换。

## 四、原理剖析：Jasypt 是如何在启动时解密的

### 4.1 核心：BeanFactoryPostProcessor 钩子

Jasypt 的原理可以用一句话概括：

> **在 Spring 容器加载配置后、创建 Bean 之前，拦截所有 PropertySource，把 `ENC(...)` 包裹的值替换为解密后的明文。**

它靠的是 Spring 的扩展点 **`BeanFactoryPostProcessor`**（更准确说是 `EnvironmentPostProcessor` + 自定义 `PropertySourceWrapper`）：

```java
// jasypt-spring-boot 核心类：EncryptablePropertySourceWrapper
public class EncryptablePropertySourceWrapper<T> extends EnumerablePropertySource<T>
        implements PropertySource<T> {
    private final PropertySource<T> delegate;

    @Override
    public Object getProperty(String name) {
        Object value = delegate.getProperty(name);
        if (value instanceof String) {
            String stringValue = (String) value;
            // 命中 ENC(...) 则解密
            if (stringValue.startsWith(prefix) && stringValue.endsWith(suffix)) {
                return decrypt(stringValue);
            }
        }
        return value;
    }
}
```

### 4.2 完整的启动流程

```
SpringApplication.run()
  → EnvironmentPostProcessor（jasypt 注册的）
      → 用 EncryptablePropertySourceWrapper 包装所有 PropertySource
  → 读取配置（此时 getProperty 触发解密）
  → 创建数据源等 Bean（拿到的是解密后的明文密码）
```

### 4.3 底层加密算法

- **PBEWithMD5AndDES**（旧版默认）：基于口令的加密（Password Based Encryption），用 MD5 派生密钥，DES 加密——已不推荐，DES 密钥只有 56 位，可被暴力破解。
- **PBEWithHMACSHA512AndAES_256**（3.x 默认）：HMAC-SHA512 派生密钥 + AES-256 加密，安全性大幅提升。

PBE 的基本流程：

```
口令(password) + 盐(salt)
   → 密钥派生函数（PBKDF2：迭代 HMAC-SHA512）
   → 得到对称密钥
   → AES-256 加密明文 → 密文
```

IV（初始化向量）随机生成并随密文存储，保证同一明文每次加密结果不同，防止字典攻击。

## 五、安全性实践清单（面试加分项）

| 实践 | 说明 | 是否推荐 |
|------|------|---------|
| 密钥放环境变量/启动参数 | 不进代码仓库 | ✅ 必须 |
| 密钥放本地文件 | 服务器本地文件，权限 600 | ✅ 可以 |
| 密钥写死在 application.yml | 加密等于白做 | ❌ 禁止 |
| 密钥提交到 Git | 严重事故 | ❌ 禁止 |
| 使用默认算法 PBEWithMD5AndDES | 强度不足 | ❌ 不推荐 |
| 定期轮换密钥 | 泄露面控制 | ✅ 建议 |
| 对接 KMS 统一管理 | 企业级方案 | ✅ 推荐 |

**面试追问：Jasypt 加密了密码，为什么还是有人说它不安全？**
答：Jasypt 本身是安全的，不安全的是**密钥管理**。如果密钥和密文放在一起（比如都写在配置文件里），等于把保险柜钥匙挂在保险柜上。真正决定安全性的是密钥的保管方式，而不是加密库本身。另外要注意：配置文件里能看到密文，不代表能破解，但**暴力破解风险**取决于密钥强度和加密算法，这也是 3.x 升级到 AES-256 的原因。

**面试追问：Jasypt 会影响启动性能吗？**
答：会有一点。每个 `ENC()` 值在启动时都要做一次 PBE 解密（PBKDF2 迭代计算较耗时），配置项多时启动时间会增加几十到几百毫秒。可以用 `jasypt.encryptor.pool-size` 调线程池，或在性能敏感场景用更轻的算法。生产上一般可接受。

## 六、常见坑与排查

**坑 1：3.x 升级后启动报错**
```
Encryptor has not been set properly...
```
解决：显式指定 `jasypt.encryptor.algorithm=PBEWithHMACSHA512AndAES_256` 和 `iv-generator-classname=org.jasypt.iv.RandomIvGenerator`。

**坑 2：密钥含特殊字符**
密钥里有 `$`、`\` 等字符时，YAML/环境变量解析会被转义。建议用单引号包裹或 Base64 编码密钥。

**坑 3：配置中心（Nacos/Apollo）场景**
Jasypt 默认只包装本地 PropertySource，从配置中心拉取的配置需要额外处理。可以配合配置中心自带的加密能力，或把 `ENC()` 密文直接放配置中心（Jasypt 的包装对远程源同样生效，因为 Nacos 的配置最终也会进入 Spring Environment，前提是 Jasypt 版本支持动态刷新——注意：**动态刷新场景下新值可能不经过解密包装，需要自定义处理**）。

**坑 4：解密失败**
```
Decryption failed. Please make sure the password and algorithm are correct.
```
多为密钥不一致（多环境密钥不同）或密文被截断（复制时丢了字符）。先本地用同一密钥验证解密，再排查环境变量是否真的注入。

## 七、完整示例：数据库密码加密全流程

```bash
# 1. 生成密文（用 Java 或 CLI）
encrypted="$(java -cp jasypt-1.9.3.jar org.jasypt.intf.cli.JasyptPBEStringEncryptionCLI \
  input='MyP@ssw0rd' password='KMS-2026-Secret' algorithm=PBEWithHMACSHA512AndAES_256 \
  ivGeneratorClassName=org.jasypt.iv.RandomIvGenerator | grep -o 'ENC([^)]*)')"

# 2. 写入配置文件
# application.yml:
#   spring.datasource.password: ${DB_PASSWORD_ENC}
#   jasypt.encryptor.password: ${JASYPT_PASSWORD}

# 3. 部署时注入密钥
export JASYPT_PASSWORD='KMS-2026-Secret'
docker run -e JASYPT_PASSWORD="$JASYPT_PASSWORD" -e DB_PASSWORD_ENC="$encrypted" myapp:1.0
```

## 总结

Jasypt 通过 `EnvironmentPostProcessor` 包装 PropertySource，在 Spring 容器装配前自动解密 `ENC(...)` 密文，让敏感配置以密文形式进入代码仓库。它的安全核心不在加密库本身，而在于**密钥的隔离管理**：密钥走环境变量/KMS，密文走配置文件/配置中心。理解它的原理（PBE 算法、BeanFactoryPostProcessor 钩子、PropertySource 包装），你就能在生产环境安全地落地配置加密，也能在面试中把这个问题讲透。
