---
title: 【Java 实战】Java PDF 生成与处理深度实战：iText、PDFBox 与 OpenPDF 对比与最佳实践
date: 2026-08-29 08:00:00
tags:
  - Java
  - PDF
  - iText
  - 实战
categories:
  - Java
author: 东哥
---

# 【Java 实战】Java PDF 生成与处理深度实战：iText、PDFBox 与 OpenPDF 对比与最佳实践

## 面试官：要做一个电子合同/发票/报表下载功能，PDF 生成你选哪个库？中文乱码怎么处理？百万级 PDF 怎么扛？

PDF 是 Java 后端最常见的「硬需求」之一：合同、发票、对账单、报表导出。但选错库、踩中文乱码、内存 OOM 的坑，几乎每个团队都趟过。这篇从**三大主流库的底层架构对比**讲起，给出中文处理、模板套打、批量生成的完整方案。

## 一、三大 PDF 库全景对比

### 1.1 库的定位与血缘

| 库 | 开源协议 | 底层模型 | 强项 | 弱项 |
|---|---|---|---|---|
| **iText 5/7** | AGPL（商业需授权） | 对象流 + 内容流直接操作 | 功能最全：表单、数字签名、水印、PDF/A、PDF/UA | 授权费贵；5.x 已 EOL |
| **Apache PDFBox** | Apache 2.0（宽松） | 低层对象模型，贴近 PDF 规范 | 免费可商用；文本抽取、加密、合并拆分 | 高级排版弱；中文字体嵌入要手写较多代码 |
| **OpenPDF** | LGPL/MPL | 脱胎于 iText 4（LGPL 时代分支） | 免费、API 接近老 iText | 停更风险；新 PDF 特性缺失（PDF/A、数字签名弱） |

### 1.2 底层原理：PDF 到底是什么

PDF 文件 = **对象（Object）+ 交叉引用表（xref）+ trailer**。对象类型包括：

- **Catalog（文档目录）**：整份 PDF 的根
- **Pages 树**：Page 对象树
- **Content Stream**：每页的绘图指令流（`BT /F1 12 Tf 100 700 Td (Hello) Tj ET` 这种）
- **Font 对象**：内嵌字体（**CIDFont + ToUnicode CMap** 才能正确显示中文）
- **Resource 字典**：页面引用的字体/图片资源

所以「生成 PDF」本质是：**组装对象图 + 序列化内容流 + 计算 xref 偏移**。iText/OpenPDF 帮你封装了这层，PDFBox 则把对象模型直接暴露给你。

### 1.3 三个库的 Hello World

**iText 7（最现代，语法块式）**：

```java
PdfWriter writer = new PdfWriter(new FileOutputStream("a.pdf"));
PdfDocument pdf = new PdfDocument(writer);
Document doc = new Document(pdf);
doc.add(new Paragraph("Hello iText 7")
        .setFont(PdfFontFactory.createFont("STSong-Light",
             "UniGB-UCS2-H", PdfFontFactory.EmbeddingStrategy.PREFER_EMBEDDED)));
doc.close();
```

**PDFBox（贴近规范，手写字体嵌入）**：

```java
try (PDDocument doc = new PDDocument()) {
    PDPage page = new PDPage(PDRectangle.A4);
    doc.addPage(page);
    try (PDPageContentStream cs = new PDPageContentStream(doc, page)) {
        cs.beginText();
        // 必须显式加载并嵌入支持中文的 TTF
        PDType0Font font = PDType0Font.load(doc, new File("fonts/simsun.ttf"));
        cs.setFont(font, 12);
        cs.newLineAtOffset(100, 700);
        cs.showText("Hello PDFBox 中文");
        cs.endText();
    }
    doc.save("b.pdf");
}
```

**OpenPDF（老 iText 风格，极简）**：

```java
Document doc = new Document(PageSize.A4);
PdfWriter.getInstance(doc, new FileOutputStream("c.pdf"));
doc.open();
BaseFont bf = BaseFont.createFont("STSong-Light", "UniGB-UCS2-H",
        BaseFont.NOT_EMBEDDED);
doc.add(new Paragraph("Hello OpenPDF 中文", new Font(bf, 12)));
doc.close();
```

## 二、中文乱码：90% 团队的第一个坑

### 2.1 为什么会乱码

PDF 的**标准 14 种字体（Helvetica/Times/Courier）不含中文**。直接 `setFont(FontFactory.getFont(FontFactory.HELVETICA))` 写中文，生成的 PDF 里没有对应字形，阅读器要么显示豆腐块，要么乱码。

### 2.2 三种解决方案

| 方案 | 原理 | 优点 | 缺点 |
|---|---|---|---|
| **内置 CID 字体**（STSong-Light + UniGB-UCS2-H） | 用 PDF 规范内置的 CJK 字体库（阅读器自带） | 文件小、无需字体文件 | **不嵌入字体**，换设备/打印可能缺失；iText 才支持 |
| **嵌入 TTF 子集** | 把用到的字符字形子集嵌入 PDF | 跨平台 100% 一致 | 文件变大（几 MB）；需提供字体文件 |
| **转图片渲染** | 先用 Java2D/Swing 画再转 PDF 图片 | 样式 100% 还原 | 不可复制文本、文件巨大、性能差 |

**生产推荐**：**嵌入 TTF 子集**，字体选思源黑体（SourceHanSansSC）或阿里巴巴普惠体（都是开源可商用）。

```java
// iText 7 嵌入思源黑体
PdfFont font = PdfFontFactory.createFont(
        "fonts/SourceHanSansSC-Regular.otf",
        PdfEncodings.IDENTITY_H,
        PdfFontFactory.EmbeddingStrategy.PREFER_EMBEDDED);
```

```java
// PDFBox 嵌入（注意 OTF 用 PDType0Font 加载）
PDType0Font font = PDType0Font.load(doc, new File("fonts/SourceHanSansSC-Regular.otf"));
```

**避坑**：
1. 字体文件要**随应用发布**，别依赖服务器路径。
2. 只嵌入子集时，**动态拼接文本**（用户输入）可能用到未嵌入字形——要么预加载全量常用字，要么开启「按需嵌入」。
3. 数字/英文尽量用西文字体，中文用中文字体，混排时**切换字体对象**，避免中文粗体靠「伪粗」实现导致样式崩。

## 三、模板套打：合同/发票/报表的工业级姿势

手写 `doc.add()` 一个个拼版式，改一版样式改一周代码。生产上两种主流姿势：

### 3.1 方案 A：HTML + PDF 引擎（推荐给运营要频繁改样式）

用 **Openhtmltopdf**（Java 实现的 HTML→PDF，支持 CSS 2.1 子集）或 **wkhtmltopdf**（WebKit 内核，样式还原最好但需装二进制）。

```xml
<dependency>
    <groupId>com.openhtmltopdf</groupId>
    <artifactId>openhtmltopdf-pdfbox</artifactId>
    <version>1.0.10</version>
</dependency>
```

```java
String html = """
        <html><head><meta charset="utf-8">
        <style>
          body { font-family: 'SourceHanSansSC'; font-size: 14px; }
          .title { text-align:center; font-size: 20px; font-weight: bold; }
          table { width: 100%; border-collapse: collapse; }
          td { border: 1px solid #333; padding: 6px; }
        </style></head>
        <body>
          <div class="title">采购合同 #{{contractNo}}</div>
          <table><tr><td>甲方</td><td>{{partyA}}</td></tr>
          <tr><td>金额</td><td>￥{{amount}}</td></tr></table>
        </body></html>""";

String filled = html.replace("{{contractNo}}", "HT20260829001")
        .replace("{{partyA}}", "东哥科技")
        .replace("{{amount}}", "12,800.00");

try (FileOutputStream os = new FileOutputStream("contract.pdf")) {
    PdfRendererBuilder builder = new PdfRendererBuilder();
    builder.useFont(new File("fonts/SourceHanSansSC-Regular.otf"), "SourceHanSansSC");
    builder.withHtmlContent(filled, null);
    builder.toStream(os);
    builder.run();
}
```

> 模板引擎用 Thymeleaf/Freemarker 渲染变量（注意 Freemarker 输出要关闭 HTML 转义，或直接用 Thymeleaf 的 `th:text` 自动转义防注入）。

### 3.2 方案 B：AcroForm 表单填充（固定版式合同）

用 iText 的 `PdfStamper`/`PdfAcroForm` 填预先设计好的 PDF 表单：

```java
// iText 7 填 AcroForm
PdfDocument pdf = new PdfDocument(
        new PdfReader("template.pdf"),
        new PdfWriter("filled.pdf"));
PdfAcroForm form = PdfAcroForm.getAcroForm(pdf, true);
form.getField("contractNo").setValue("HT20260829001");
form.getField("partyA").setValue("东哥科技");
form.getField("amount").setValue("12,800.00");
form.flattenFields(); // 展平：防止用户改内容，也是防篡改的常规操作
pdf.close();
```

**flattenFields 很重要**：不展平的话，合同内容还能被 PDF 编辑器改掉；展平后字段变成普通文本，配合数字签名才是完整的防篡改链路。

### 3.3 防篡改：数字签名（iText 7 + BouncyCastle）

```java
PdfSigner signer = new PdfSigner(new PdfReader("filled.pdf"),
        new FileOutputStream("signed.pdf"), new StampingProperties());
signer.setCertificationLevel(PdfSigner.CERTIFIED_NO_CHANGES_ALLOWED);

// 加载 PKCS#12 证书（由 CA 或企业内部 CA 签发）
KeyStore ks = KeyStore.getInstance("PKCS12");
ks.load(new FileInputStream("company.p12"), "password".toCharArray());
PrivateKey pk = (PrivateKey) ks.getKey("alias", "password".toCharArray());
Certificate[] chain = ks.getCertificateChain("alias");

PdfSignatureAppearance appearance = signer.getSignatureAppearance();
appearance.setReason("电子合同签署");
appearance.setLocation("上海");
appearance.setPageRect(new Rectangle(36, 36, 200, 60));

signer.signDetached(new BouncyCastleDigest(), pk, chain, null, null, null, 0,
        PdfSigner.CryptoStandard.CMS);
```

> 企业电子合同合规还涉及**可信时间戳（TSA）**：`signDetached` 的倒数第二、三个参数可以传 TSA 客户端，把签名时间锚定到权威时间源，防止「签名时间被改」。

## 四、高性能批量生成：百万 PDF 的架构思考

### 4.1 单机优化三板斧

1. **复用 Document/字体对象**：字体加载一次全局缓存，不要每条数据 new 一个字体（字体解析是最大的隐性开销）。
2. **流式写出**：iText 7 默认就是流式（PdfWriter 直写输出流）；PDFBox 的 `doc.save()` 前尽量用 `saveIncremental` 或边构建边写。
3. **异步 + 限流**：PDF 生成是 CPU 密集（排版+压缩），线程池大小 = CPU 核数，别用无界队列。

### 4.2 典型架构：任务队列 + 对象存储

```
API 请求 → 发 MQ（订单号、模板ID、参数JSON）
              ↓
Worker 集群（每个 Worker 消费消息）
    ↓ 渲染 PDF（模板 + 数据）
    ↓ 上传 OSS/MinIO（见本站 MinIO 文章）
    ↓ 回写下载地址到业务表 + 通知（WebSocket/短信）
用户端 → 从 OSS 直接下载（CDN 加速）
```

**为什么不让请求线程同步生成？** 因为单份合同渲染 200ms，10 个并发就要 2 个核满负荷；双 11 高峰直接打爆。异步化后：
- 高峰削峰：请求只落库 + 发消息，秒回「生成中」。
- 失败重试：渲染失败的消息进入死信队列（见本站 RabbitMQ 死信文章），人工或自动重试。
- 弹性扩缩：K8s HPA 按队列积压量扩 Worker。

### 4.3 内存与文件大小控制

- 大图片先压缩再插入：`ImageIO` 读图后按目标 DPI 缩放，避免一张 5MB 照片直接塞进 PDF。
- 文本分页：`doc.add` 超长内容用 `ColumnText`/`Document` 自动分页，别手动拼一页。
- 监控：批量任务统计「单份耗时 P99、文件大小、内存峰值」，超过阈值报警。

## 五、文本抽取与合规审计

反向需求（解析 PDF）同样常见：审计、全文检索、数据迁移。

```java
// PDFBox 抽取文本（含布局，LayoutTextStripper 保序）
try (PDDocument doc = PDDocument.load(new File("report.pdf"))) {
    LayoutTextStripper stripper = new LayoutTextStripper();
    String text = stripper.getText(doc);
    System.out.println(text);
}
```

```java
// iText 7 抽取
PdfDocument pdf = new PdfDocument(new PdfReader("report.pdf"));
String text = PdfTextExtractor.getTextFromPage(pdf.getPage(1));
```

注意：**扫描件 PDF（纯图片）抽取出来是空字符串**，需要先 OCR（Tesseract + 中文语言包）再抽取。

## 六、选型决策树

```
需要数字签名/PDF-A/无障碍？ ──是──> iText 7（商业授权评估）
        │否
需要免费商用 + 文本抽取/合并拆分？ ──是──> Apache PDFBox
        │否
团队熟悉老 iText API + 预算为 0？ ──是──> OpenPDF（注意停更风险）
        │否
运营常改样式？ ──> HTML 模板方案（Openhtmltopdf/wkhtmltopdf）优先于手写排版
```

## 总结

| 关键点 | 结论 |
|---|---|
| 选库 | 要签名/合规选 iText 7；免费商用选 PDFBox；快速上手选 OpenPDF |
| 中文 | 一律嵌入开源中文字体子集（思源黑体/普惠体），别裸用标准字体 |
| 版式 | 高频改样式走 HTML→PDF；固定版式走 AcroForm 填充 + flatten |
| 批量 | MQ 异步 + Worker 集群 + OSS 存储 + CDN 下载，别同步渲染 |
| 合规 | 合同类必须数字签名 + 时间戳 + 防篡改证书级别 |

PDF 生成不是「调个 API」那么简单，选型、中文、模板、性能、合规五座大山，这篇帮你一次跨过。
