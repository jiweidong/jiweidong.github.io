---
title: 【Java 实战】二维码生成与识别深度实战：ZXing 原理、容错等级与生产落地
date: 2026-10-06 08:15:00
tags:
  - Java
  - ZXing
  - 二维码
  - 实战
categories:
  - Java
  - Java 实战
author: 东哥
---

# 【Java 实战】二维码生成与识别深度实战：ZXing 原理、容错等级与生产落地

## 面试官：扫码登录是怎么实现的？二维码里到底存了什么？

很多人做过扫码登录，但被追问一句"二维码最多能存多少字节""为什么二维码被挡住一角还能扫出来"，就露馅了。

二维码（QR Code，Quick Response Code）看着简单，背后是**里德-所罗门纠错编码 + 掩码 + 数据分块**的完整体系。Java 里最主流的实现是 Google 的 **ZXing**（Zebra Crossing）。这篇文章从原理讲到生产落地。

---

## 一、二维码的物理结构

一个标准 QR 码由这些部分组成：

| 区域 | 作用 |
| --- | --- |
| 定位图案（3 个大回字形） | 让扫描器确定位置和方向，支持 360° 扫描 |
| 校正图案 | 版本 ≥ 2 时出现，矫正形变 |
| 定时图案 | 黑白相间的细线，帮助定位模块坐标 |
| 格式信息 | 存储纠错等级和掩码编号 |
| 版本信息 | 版本 ≥ 7 时出现，标明 21×21 到 177×177 的尺寸 |
| 数据与纠错码 | 真正的数据区，按块交织 |

**版本（Version 1~40）** 决定尺寸：版本 n 的边长是 `4n + 17` 个模块。版本 1 是 21×21，版本 40 是 177×177。

**纠错等级（Error Correction Level）** 决定冗余度：

| 等级 | 可恢复比例 | 数据容量（版本 40） | 典型用途 |
| --- | --- | --- | --- |
| L（Low） | ~7% | 最大 | 内容多、环境干净 |
| M（Medium） | ~15% | 中等 | 默认，最常用 |
| Q（Quartile） | ~25% | 较小 | 一般工业场景 |
| H（High） | ~30% | 最小 | 中心放 Logo、恶劣环境 |

> 这就是"二维码被挡住一角还能扫出来"的原因：数据被里德-所罗门编码冗余保护，只要损坏不超过纠错能力，就能完整还原。

---

## 二、ZXing 依赖

```xml
<dependency>
    <groupId>com.google.zxing</groupId>
    <artifactId>core</artifactId>
    <version>3.5.3</version>
</dependency>
<!-- 生成图片需要 javase 模块 -->
<dependency>
    <groupId>com.google.zxing</groupId>
    <artifactId>javase</artifactId>
    <version>3.5.3</version>
</dependency>
```

---

## 三、生成二维码

### 1. 最简版：存一段文本

```java
import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;
import com.google.zxing.client.j2se.MatrixToImageWriter;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

public class QrGenerator {

    public static void generate(String content, int size, Path out) throws Exception {
        Map<EncodeHintType, Object> hints = new HashMap<>();
        hints.put(EncodeHintType.CHARACTER_SET, "UTF-8");         // 中文必须指定
        hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);
        hints.put(EncodeHintType.MARGIN, 1);                       // 白边宽度，默认 4

        QRCodeWriter writer = new QRCodeWriter();
        BitMatrix matrix = writer.encode(content, BarcodeFormat.QR_CODE, size, size, hints);
        MatrixToImageWriter.writeToPath(matrix, "PNG", out);
    }
}
```

### 2. 带 Logo 的二维码（H 级纠错）

```java
import javax.imageio.ImageIO;
import java.awt.*;
import java.awt.image.BufferedImage;
import java.io.File;

public static BufferedImage withLogo(BitMatrix matrix, File logoFile) throws Exception {
    int size = matrix.getWidth();
    BufferedImage image = new BufferedImage(size, size, BufferedImage.TYPE_INT_RGB);
    for (int x = 0; x < size; x++) {
        for (int y = 0; y < size; y++) {
            image.setRGB(x, y, matrix.get(x, y) ? 0xFF000000 : 0xFFFFFFFF);
        }
    }
    BufferedImage logo = ImageIO.read(logoFile);
    int logoSize = size / 5;                       // 建议不超过 1/5，否则影响识别
    Image scaled = logo.getScaledInstance(logoSize, logoSize, Image.SCALE_SMOOTH);

    Graphics2D g = image.createGraphics();
    g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
    int x = (size - logoSize) / 2;
    // 先画白色底板，避免 Logo 与二维码"糊"在一起
    g.setColor(Color.WHITE);
    g.fillRoundRect(x - 4, x - 4, logoSize + 8, logoSize + 8, 8, 8);
    g.drawImage(scaled, x, x, null);
    g.dispose();
    return image;
}
```

**要点：放 Logo 一定要用 `ErrorCorrectionLevel.H`**，并且 Logo 面积控制在 1/5 以内、中心居中。否则扫码率会断崖式下降。

### 3. 彩色 / 高对比度二维码

二维码识别依赖**灰度对比度**，前景/背景色亮度差要足够大：

```java
// 深蓝前景 + 浅黄背景，对比度依然足够
int fg = new Color(20, 40, 100).getRGB();
int bg = new Color(255, 250, 230).getRGB();
image.setRGB(x, y, matrix.get(x, y) ? fg : bg);
```

> 反色（白码黑底）在部分老扫描器上无法识别，生产慎用。

---

## 四、识别二维码

```java
import com.google.zxing.*;
import com.google.zxing.client.j2se.BufferedImageLuminanceSource;
import com.google.zxing.common.HybridBinarizer;

import javax.imageio.ImageIO;
import java.io.File;
import java.util.EnumMap;
import java.util.Map;

public class QrReader {

    public static String decode(File file) throws Exception {
        BufferedImage image = ImageIO.read(file);
        LuminanceSource source = new BufferedImageLuminanceSource(image);
        // HybridBinarizer 比 GlobalHistogramBinarizer 更适合二维码
        BinaryBitmap bitmap = new BinaryBitmap(new HybridBinarizer(source));

        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(DecodeHintType.CHARACTER_SET, "UTF-8");
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE); // 提高识别率，代价是变慢

        Result result = new MultiFormatReader().decode(bitmap, hints);
        return result.getText();
    }
}
```

### 识别率优化技巧

| 问题 | 手段 |
| --- | --- |
| 图片太小 / 模糊 | 先放大、锐化，再解码 |
| 光照不均 | `HybridBinarizer`（局部二值化）比全局阈值强 |
| 有旋转 | 用 `TRY_HARDER` 或先做透视矫正 |
| 只有二维码区域 | 先裁剪 ROI 再解码，速度快数倍 |
| 彩色码 | 统一转灰度后再处理 |

---

## 五、生产场景：扫码登录

扫码登录的二维码里，**绝不放用户敏感信息**，而是放一个一次性的 `ticket`：

```
1. 客户端请求二维码 → 服务端生成 uuid，写入 Redis：qr:ticket:{uuid} = WAITING（TTL 2min）
2. 二维码内容 = https://example.com/qr?ticket=xxx
3. 手机扫码 → 解析出 ticket → 用户在 App 内确认登录
4. 服务端把 Redis 改为 CONFIRMED，并绑定 userId
5. 网页端轮询/长连接 → 拿到 CONFIRMED → 用 ticket 换 JWT，登录完成
```

Java 侧的关键代码：

```java
public String createTicket() {
    String ticket = UUID.randomUUID().toString().replace("-", "");
    redis.opsForValue().set("qr:ticket:" + ticket, "WAITING", 2, TimeUnit.MINUTES);
    return "https://example.com/qr?ticket=" + ticket;
}

public boolean confirm(String ticket, Long userId) {
    String key = "qr:ticket:" + ticket;
    // 只允许从 WAITING 变成 CONFIRMED，天然防重复
    Boolean ok = redis.opsForValue().setIfPresent(key, "CONFIRMED:" + userId, 2, TimeUnit.MINUTES);
    return Boolean.TRUE.equals(ok);
}
```

要点：**ticket 一次性、有过期、状态机控制**，防止二维码被截图后无限次使用。

---

## 六、性能与容量

| 版本 | 尺寸 | 数字 | 字母数字 | 字节 | 汉字（GB2312） |
| --- | --- | --- | --- | --- | --- |
| 1 | 21×21 | 41 | 25 | 17 | ~10 |
| 10 | 57×57 | 652 | 395 | 271 | ~160 |
| 20 | 97×97 | 2061 | 1249 | 858 | ~520 |
| 40 | 177×177 | 7089 | 4296 | 2953 | ~1817 |

**结论：二维码不适合存大数据**。超过几百字节，二维码会变得极其密集，低端摄像头识别率骤降。**正确做法是存短链或 ID**，数据放服务端。

### 生成性能

- 版本 10 以内，单次生成 ~1ms，完全无压力；
- 高频场景可以**缓存生成结果**（内容不变则图片不变）；
- 千万别在循环里每次都 `ImageIO.write` 到磁盘，用 `ByteArrayOutputStream` 返回流。

---

## 七、常见坑

1. **中文乱码**：不指定 `CHARACTER_SET=UTF-8` 时，部分实现按 ISO-8859-1 处理；
2. **白边（MARGIN）太小**：识别器需要静默区（quiet zone），建议 margin ≥ 1（默认 4 更安全）；
3. **尺寸非整数倍**：`BitMatrix` 缩放时若出现半像素，会导致边界模糊，尽量用整数倍缩放；
4. **Logo 太大**：超过 1/5 且不是 H 级纠错，识别率暴跌；
5. **`ImageIO` 在无头服务器上字体缺失**：绘制文字到二维码里（如"扫码登录"），需保证 JRE 有字体，或用 `-Djava.awt.headless=true` 并避免依赖系统字体。

---

## 八、面试追问连环炮

**Q1：二维码为什么能 360° 扫？**
靠三个定位图案确定三个角，第四个角由三点的相对位置推出来，因此无论旋转多少度都能定位。

**Q2：纠错等级怎么选？**
默认 `M`；要放 Logo 用 `H`；内容特别长又要求尺寸小用 `L`。没有银弹，按场景权衡。

**Q3：二维码是加密的吗？**
不是。它只是编码，任何扫描器都能读出明文。绝不能存敏感信息，要存就存**一次性 token**。

**Q4：为什么扫一些二维码会跳到奇怪网站？**
因为二维码内容是纯文本 URL，可被伪装。防御靠"落地页安全检测 + 短链域名白名单 + 二次确认"。

**Q5：如何做二维码防伪/防篡改？**
在 URL 里带一段基于内容的签名（如 `HMAC-SHA256(url + secret)`），服务端校验签名，篡改即失效。

---

## 九、总结

1. **二维码 = 数据分块 + RS 纠错 + 掩码 + 定位图案**，纠错能力决定了容错；
2. **ZXing 生成用 `QRCodeWriter`，识别用 `MultiFormatReader` + `HybridBinarizer`**；
3. **放 Logo 必须 H 级纠错，Logo ≤ 1/5**；
4. **二维码只存短链/一次性 ticket，敏感数据放服务端**；
5. 生产三件套：防篡改签名、一次性 token、短时效过期。

掌握这些，扫码登录、电子票务、支付码、公众号推广码这些场景都能稳稳落地。
