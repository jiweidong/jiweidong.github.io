---
title: 【Java 安全】国密算法深度实战：SM2/SM3/SM4 原理与 Java 实现全解析
date: 2026-08-24 09:00:00
tags:
  - Java
  - 安全
  - 国密
  - 加密
  - 面试
categories:
  - Java
  - 安全
author: 东哥
---

# 【Java 安全】国密算法深度实战：SM2/SM3/SM4 原理与 Java 实现全解析

## 面试官：什么是国密算法？为什么现在都在谈国密？

**国密算法**是国家密码管理局发布的商用密码算法标准，核心四件套：

| 算法 | 类型 | 对标国际算法 | 标准编号 |
| --- | --- | --- | --- |
| SM2 | 非对称加密/签名 | RSA、ECDSA | GB/T 32918 |
| SM3 | 哈希摘要 | SHA-256 | GB/T 32905 |
| SM4 | 对称加密 | AES | GB/T 32907 |
| SM9 | 基于标识的加密/签名 | IBE | GB/T 38635 |

**为什么重要**：
1. **合规驱动**：金融、政务、运营商等关键行业被要求通过等保 2.0、密评（商用密码应用安全性评估），核心系统必须使用国密算法；
2. **自主可控**：摆脱对国外密码算法供应链的依赖（信创战略）；
3. **安全考量**：理论上一旦有后门或算法被攻破，使用国密可规避风险；
4. **生态成熟**：从 JDK（OpenJDK 已部分支持）到 BouncyCastle、Hutool、Nginx、Tomcat、主流云厂商都已支持国密。

## 一、SM4：对称加密

### 原理要点
- **分组密码**，分组长度 128 位（16 字节），密钥长度 128 位；
- 32 轮非线性迭代结构（与 AES 的 SPN 结构不同），每轮用 S 盒做非线性变换 + 线性变换；
- 加解密结构对称（解密密钥是加密密钥的逆序轮密钥），硬件实现友好；
- 分组模式与 AES 通用：ECB、CBC、CTR、GCM 等。

### 与 AES 对比
| 维度 | SM4 | AES |
| --- | --- | --- |
| 分组大小 | 128 bit | 128 bit |
| 密钥长度 | 128 bit | 128/192/256 bit |
| 轮数 | 32 轮 | 10/12/14 轮 |
| 结构 | 广义 Feistel | SPN |
| 性能 | 软实现略慢于 AES（有硬件加速后接近） | 有 AES-NI 硬件指令，极快 |

### Java 实现（BouncyCastle）
```xml
<dependency>
    <groupId>org.bouncycastle</groupId>
    <artifactId>bcprov-jdk18on</artifactId>
    <version>1.78</version>
</dependency>
```

```java
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;
import java.security.Security;

static {
    if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
        Security.addProvider(new BouncyCastleProvider());
    }
}

public static byte[] sm4Encrypt(byte[] key, byte[] iv, byte[] plain) throws Exception {
    // SM4/CBC/PKCS7Padding
    Cipher cipher = Cipher.getInstance("SM4/CBC/PKCS7Padding", "BC");
    SecretKeySpec keySpec = new SecretKeySpec(key, "SM4");
    IvParameterSpec ivSpec = new IvParameterSpec(iv);
    cipher.init(Cipher.ENCRYPT_MODE, keySpec, ivSpec);
    return cipher.doFinal(plain);
}

public static byte[] sm4Decrypt(byte[] key, byte[] iv, byte[] cipherData) throws Exception {
    Cipher cipher = Cipher.getInstance("SM4/CBC/PKCS7Padding", "BC");
    SecretKeySpec keySpec = new SecretKeySpec(key, "SM4");
    IvParameterSpec ivSpec = new IvParameterSpec(iv);
    cipher.init(Cipher.DECRYPT_MODE, keySpec, ivSpec);
    return cipher.doFinal(cipherData);
}
```

**工程注意**：生产环境优先用 **GCM 模式**（带认证，防篡改），不要用裸 ECB；IV 每次加密随机生成，随密文一起传输。

## 二、SM3：密码杂凑算法

### 原理要点
- 输出 256 位（32 字节）摘要，与 SHA-256 等长；
- 基于 Merkle-Damgård 结构，消息分组 512 位，64 轮压缩函数；
- 安全强度 128 位（抗碰撞），满足商用密码安全要求。

### 与 SHA-256 对比
| 维度 | SM3 | SHA-256 |
| --- | --- | --- |
| 输出长度 | 256 bit | 256 bit |
| 分组 | 512 bit | 512 bit |
| 轮数 | 64 轮 | 64 轮 |
| 速度 | 略慢（软实现约 SHA-256 的 60%~80%） | 快，有硬件加速 |

### Java 实现
```java
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import java.security.MessageDigest;
import java.security.Security;

static {
    if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
        Security.addProvider(new BouncyCastleProvider());
    }
}

public static String sm3Hex(String data) throws Exception {
    MessageDigest digest = MessageDigest.getInstance("SM3", "BC");
    byte[] hash = digest.digest(data.getBytes(StandardCharsets.UTF_8));
    return HexFormat.of().formatHex(hash); // JDK 17+ 自带 HexFormat
}
```

**注意**：JDK 19+（JEP 408? 实际是 JEP 通过 OpenJDK 支持）——OpenJDK 已在若干版本内置 SM3/SM4 支持（JDK 21 的 JEP 通过 `SunJCE` 提供 SM4 部分能力），但为兼容性和确定性，**生产环境仍建议显式引入 BouncyCastle**。

### 典型应用
- 密码存储：SM3 哈希 + 随机盐（不可逆）；
- 完整性校验：文件校验、固件校验、数据防篡改；
- 与 SM2 配合：SM2withSM3 签名（国密标准签名方案）。

## 三、SM2：非对称加密与数字签名

### 原理要点
- 基于**椭圆曲线密码（ECC）**，推荐曲线 sm2p256v1（256 位素数域）；
- 密钥长度 256 位，但安全强度等效 RSA-3072 级别，**密钥更短、性能更快**；
- 三个功能：**加密**（公钥加密、私钥解密）、**签名**（私钥签名、公钥验签）、**密钥交换**（双方协商会话密钥）；
- 与 SM3 配合的签名方案是 `SM3withSM2`（业界标准用法）。

### 与 RSA 对比
| 维度 | SM2 | RSA |
| --- | --- | --- |
| 数学基础 | 椭圆曲线离散对数 | 大整数分解 |
| 密钥长度 | 256 bit（等效 RSA-3072） | 2048/3072/4096 bit |
| 加解密性能 | 快（尤其签名） | 慢，密钥越长越慢 |
| 密文膨胀 | 小 | 大（RSA 密文=密钥长度） |
| 密钥生成 | 快 | 慢（需素数筛选） |

### Java 实现：SM2 签名 + 验签
```java
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import java.security.*;

static { /* 注册 BC Provider，同上 */ }

// 生成密钥对
public static KeyPair generateSm2KeyPair() throws Exception {
    KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC", "BC");
    kpg.initialize(new ECGenParameterSpec("sm2p256v1"));
    return kpg.generateKeyPair();
}

// SM3withSM2 签名
public static byte[] sign(PrivateKey privateKey, byte[] data) throws Exception {
    Signature sig = Signature.getInstance("SM3withSM2", "BC");
    sig.initSign(privateKey);
    sig.update(data);
    return sig.sign();
}

// 验签
public static boolean verify(PublicKey publicKey, byte[] data, byte[] signature) throws Exception {
    Signature sig = Signature.getInstance("SM3withSM2", "BC");
    sig.initVerify(publicKey);
    sig.update(data);
    return sig.verify(signature);
}
```

### SM2 加密（公钥加密）
```java
Cipher cipher = Cipher.getInstance("SM2", "BC");
cipher.init(Cipher.ENCRYPT_MODE, publicKey);
byte[] enc = cipher.doFinal(plain);
```

**工程注意**：
- SM2 密文有固定格式（C1C3C2 或 C1C2C3，需与对端约定）；
- 密钥对生成后要妥善保管私钥（硬件密码机/HSM、KMS）；
- 跨语言对接时（Java ↔ Go/Node），注意点坐标编码和密文排列顺序的兼容性。

## 四、国密 SSL（GMTLS）与生产实践

### GMTLS 是什么
国密 SSL 是基于 TLS 的国产化改造（GB/T 38636-2020）：握手用 **SM2 证书 + SM2 签名**，密钥交换用 SM2，对称加密用 **SM4-GCM**，摘要用 **SM3**。典型做法是**双证书**（国密证书 + 国际证书并存），兼容老浏览器。

### Java 生态接入方式
1. **应用层**：BouncyCastle + 自研 SSLContext 装配（复杂）；
2. **网关/中间件**：Nginx（`nginx-http-sm4` 补丁版）、Tomcat（`-Djsse.enableSNIExtension` + 国密 Provider）；
3. **工具库**：Hutool-crypto 对 SM2/SM3/SM4 封装极友好，适合快速落地：

```java
// Hutool 一行搞定 SM4 加解密
String key = RandomUtil.randomString(16);
SM4 sm4 = SmUtil.sm4(key.getBytes());
String encryptHex = sm4.encryptHex("敏感数据");

// SM3 摘要
String digestHex = SmUtil.sm3("待摘要内容");

// SM2 签名
SM2 sm2 = SmUtil.sm2(); // 自动生成密钥对
byte[] sign = sm2.sign("data".getBytes());
boolean valid = sm2.verify("data".getBytes(), sign);
```

### 生产落地清单
- **密钥管理**：对称密钥用 KMS 或密码机托管，禁止硬编码在配置/代码里；
- **加盐**：SM3 存密码必须加随机盐 + 迭代（如 PBKDF2 思路）；
- **算法套件选择**：对称加密优先 SM4-GCM，签名用 SM3withSM2；
- **合规**：涉及等保三级/密评的系统，提前做国密改造评估，新系统直接上国密；
- **性能**：SM2 签名性能远好于 RSA，但加解密略慢于 AES（无硬件加速时），高并发场景评估用密码机/加速卡。

## 面试追问环节

**Q1：SM2 和 RSA 谁更安全？**
同安全强度下 SM2 密钥更短（256 bit ≈ RSA-3072），且基于椭圆曲线离散对数难题；RSA 依赖大整数分解。两者目前都安全，SM2 在密钥长度和签名性能上有优势。

**Q2：SM3 和 SHA-256 能混用吗？**
不能直接混用——算法不同，摘要值不兼容；但可以共存（双算法签名），迁移期常见做法。

**Q3：国密算法有开源实现吗？**
有：BouncyCastle（事实标准）、OpenSSL 1.1.1+ 官方支持 SM2/SM3/SM4、GmSSL（国密官方开源项目）、Hutool 封装。都是合规可用的。

**Q4：为什么金融行业强推国密？**
密评合规要求 + 自主可控战略。核心交易、身份认证、数据传输链路都要用国密算法替代或并存（双栈模式）。

## 总结

- 国密四件套：SM2（非对称/签名）、SM3（摘要）、SM4（对称）、SM9（标识密码）；
- Java 落地首选 BouncyCastle（`bcprov-jdk18on`），Hutool 提供更简洁的封装；
- 对称用 SM4-GCM、签名用 SM3withSM2、密码存储用 SM3+盐，是标准姿势；
- 生产必做：密钥托管、IV 随机、加盐迭代、跨语言兼容性验证；
- 国密是合规刚需，也是 Java 安全面试的高频加分项。

掌握了国密这套组合拳，无论是信创改造还是密评合规，都能游刃有余。
