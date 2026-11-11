---
title: 【Java AI】RAG 文档摄取管线深度实战：Tika/PDFBox 解析、版面感知分块与幂等增量
date: 2026-11-11 08:15:00
tags:
  - Java
  - AI
  - RAG
  - Tika
  - PDFBox
categories:
  - Java AI
author: 东哥
---

# 【Java AI】RAG 文档摄取管线深度实战：Tika/PDFBox 解析、版面感知分块与幂等增量

## 前言

做 RAG 最容易踩的坑，是把 80% 的精力花在选模型、调 Prompt、换向量库上，最后发现答不准的根因是**文档根本没被正确读进来**：PDF 双栏被读成"左栏一行、右栏一行"交错；表格被读成一堆没有列语义的数字；扫描件只有空白字符；同一个文档被重复摄入 7 次，检索结果全是重复片段。

在 Java 技术栈里，这条链路对应的是 **Tika（格式识别与文本抽取）+ PDFBox（PDF 版面与坐标）+ 自研分块器 + Spring AI VectorStore**。Python 生态有 Unstructured、LlamaIndex 的成熟封装，Java 侧需要自己组装——但组装得好，工程可控性反而更强。

本文按"采集 → 解析 → 清洗 → 分块 → 富化 → 索引"六段拆解，每一段给出可运行的 Java 代码、选型对比表和质量门禁指标。

---

## 一、管线全景

```
┌────────┐  ┌──────────────┐  ┌────────┐  ┌──────────────┐  ┌────────┐  ┌──────────┐
│ 采集    │→│ 解析          │→│ 清洗    │→│ 版面感知分块  │→│ 富化    │→│ 幂等索引  │
│ 对象存储│  │ Tika/PDFBox  │  │ 去噪    │  │ 标题树+滑窗   │  │ 元数据  │  │ upsert   │
│ 增量同步│  │ POI/Jsoup    │  │ 归一化  │  │ 表格单独处理  │  │ 摘要    │  │ 版本指纹  │
└────────┘  └──────────────┘  └────────┘  └──────────────┘  └────────┘  └──────────┘
      │            │                │              │              │            │
   内容指纹      质量门禁        乱码率检测      块大小分布     关键词       孤儿块清理
```

六个阶段里，**解析和分块决定了检索效果的上限**，索引阶段决定了系统的可维护性。下面逐段展开。

---

## 二、解析：先解决"能不能读对"

### 2.1 格式与工具选型

| 格式 | 首选 | 备选 | 主要坑 |
|---|---|---|---|
| PDF（文本型） | PDFBox（坐标级控制） | Tika（`PDFParser` 内部也是 PDFBox） | 双栏顺序、页眉页脚、连字/断词 |
| PDF（扫描型） | Tika + Tesseract（tess4j） | 云 OCR | 中文识别率、版面重排、成本 |
| DOCX | Apache POI（XWPF） | Tika | 修订痕迹、批注、页眉重复、文本框 |
| XLSX | POI（XSSF，事件模型） | Tika | 合并单元格、多 Sheet 语义、公式缓存值 |
| PPTX | POI（XSLF） | Tika | 备注页、SmartArt 丢字 |
| HTML | Jsoup | Tika | 导航栏/广告噪音、正文密度判定 |
| Markdown | flexmark / commonmark | — | 代码块被误当正文 |
| 邮件 EML | Jakarta Mail | Tika | 附件递归、引用链噪音 |

实践建议：**用 Tika 做"格式识别 + 统一兜底"，用专用库做"关键格式的精细解析"**。Tika 的 `AutoDetectParser` 负责"这是什么文件、用什么解析器"，PDF/DOCX 这类高频格式再走专用路径。

### 2.2 Tika 统一入口

```java
import org.apache.tika.metadata.Metadata;
import org.apache.tika.parser.AutoDetectParser;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.sax.BodyContentHandler;
import org.xml.sax.ContentHandler;

import java.io.InputStream;

public record ParsedDoc(String text, Metadata metadata, String mimeType) {}

public class TikaExtractor {

    private final AutoDetectParser parser = new AutoDetectParser();

    public ParsedDoc extract(InputStream in) throws Exception {
        Metadata md = new Metadata();
        // writeLimit：单文档最大字符数，防止超大文件打爆内存
        ContentHandler handler = new BodyContentHandler(20 * 1024 * 1024);
        ParseContext ctx = new ParseContext();
        parser.parse(in, handler, md, ctx);

        String mime = md.get(Metadata.CONTENT_TYPE);
        return new ParsedDoc(handler.toString(), md, mime);
    }
}
```

三个细节：

- `BodyContentHandler` 的 `writeLimit` 必须设。不设的话一个 500MB 的日志文件能把堆吃穿。
- `ParseContext` 里可以注入 `EmbeddedDocumentExtractor` 来自定义"附件是否递归解析"，默认会递归，容易把一封邮件里的 30 个附件全抽出来。
- Tika 3.x 需要 Java 11+，且 `tika-parsers-standard-package` 体积很大（100MB+），建议用 `tika-core` + 按需引入 `tika-parser-pdf-module` 等子模块，减小镜像。

### 2.3 PDF 版面感知：自己写 `PDFTextStripper`

默认 `PDFTextStripper` 按"内容流顺序"输出，双栏 PDF 会左右交错。要按视觉顺序读，必须用坐标重排：

```java
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** 按「列 → 行」重排的 PDF 抽取器 */
public class ColumnAwareStripper extends PDFTextStripper {

    private final List<TextPosition> pageChars = new ArrayList<>();
    private final List<String> pages = new ArrayList<>();

    public ColumnAwareStripper() throws IOException {
        setSortByPosition(false);   // 关掉内置排序，自己做
    }

    @Override
    protected void startPage(org.apache.pdfbox.pdmodel.PDPage page) throws IOException {
        super.startPage(page);
        pageChars.clear();
    }

    @Override
    protected void writeString(String text, List<TextPosition> positions) {
        pageChars.addAll(positions);
    }

    @Override
    protected void endPage(org.apache.pdfbox.pdmodel.PDPage page) throws IOException {
        float pageWidth = page.getMediaBox().getWidth();
        float midX = pageWidth / 2f;

        // 1) 判断是否双栏：左右两半都有足够字符，且中间存在明显空隙
        long left = pageChars.stream().filter(p -> p.getXDirAdj() < midX).count();
        long right = pageChars.size() - left;
        boolean twoColumn = pageChars.size() > 200
                && left > pageChars.size() * 0.25
                && right > pageChars.size() * 0.25;

        Comparator<TextPosition> order = twoColumn
                ? Comparator.<TextPosition>comparingInt(p -> p.getXDirAdj() < midX ? 0 : 1)
                    .thenComparing(p -> Math.round(p.getYDirAdj() / 4f))   // 4pt 容差归为同一行
                    .thenComparing(TextPosition::getXDirAdj)
                : Comparator.<TextPosition>comparingLong(p -> Math.round(p.getYDirAdj() / 4f))
                    .thenComparing(TextPosition::getXDirAdj);

        // 2) 按行聚合，行内按 x 拼接，字号突变视为标题
        StringBuilder sb = new StringBuilder();
        List<TextPosition> sorted = pageChars.stream().sorted(order).toList();
        Float lastY = null;
        float lastFont = 0;

        for (TextPosition tp : sorted) {
            float y = tp.getYDirAdj();
            if (lastY != null && Math.abs(y - lastY) > 4f) {
                sb.append('\n');
                if (tp.getFontSizeInPt() > lastFont * 1.15f && sb.length() > 0) {
                    sb.insert(sb.lastIndexOf("\n") + 1, "## ");   // 粗判标题
                }
            }
            sb.append(tp.getUnicode());
            lastY = y;
            lastFont = tp.getFontSizeInPt();
        }
        pages.add(sb.toString());
    }

    public List<String> getPages() { return pages; }

    public static List<String> extract(PDDocument doc) throws IOException {
        ColumnAwareStripper stripper = new ColumnAwareStripper();
        stripper.setStartPage(1);
        stripper.setEndPage(doc.getNumberOfPages());
        stripper.getText(doc);
        return stripper.getPages();
    }
}
```

> 这段代码不是"开箱即用的完美方案"（真实 PDF 有旋转、缩进、脚注、跨页表格），但它把"版面信息"这件事显式化了。工程上更重要的是：**每份文档解析后保存一份"解析产物快照"（文本 + 坐标 + 字号）**，这样分块策略调整时可以重放，不必重新解析原文件。

### 2.4 表格：单独通道

表格是 RAG 里最容易被毁掉的结构。三种处理方式：

| 方案 | 实现 | 优点 | 缺点 |
|---|---|---|---|
| 转 Markdown | tabula-java / 自研坐标聚类 | 保留列语义，LLM 友好 | 复杂合并单元格易错 |
| 逐行转句子 | `列名: 值, 列名: 值` | 检索友好（每行独立成块） | 丢失跨行关系 |
| 整表存 + 摘要 | 表存对象存储，块里放"表标题 + 摘要 + 前 3 行" | 省 Token | 需要二次取数能力 |

推荐组合：**表头 + 每行转"列名: 值"的句子作为可检索块，同时把整表 Markdown 存进 metadata 的 `tableRef`**，命中后由 Agent 按引用取原表。

---

## 三、清洗：别让噪音进向量库

清洗规则要看格式，但有几条通用：

```java
public final class TextCleaner {

    private static final Pattern PAGE_NO   = Pattern.compile("(?m)^\\s*[-—]?\\s*\\d{1,3}\\s*[-—]?\\s*$");
    private static final Pattern MULTI_NL  = Pattern.compile("\\n{3,}");
    private static final Pattern SOFT_HYPHEN = Pattern.compile("(\\p{Alpha})-[\\r\\n]+(\\p{Alpha})");
    private static final Pattern CTRL       = Pattern.compile("[\\p{Cntrl}&&[^\\n\\t]]");

    public static String clean(String raw) {
        String s = raw.replace('\u00A0', ' ')          // NBSP
                      .replaceAll("\\uFEFF", "");      // BOM
        s = SOFT_HYPHEN.matcher(s).replaceAll("$1$2"); // 断词连字符
        s = PAGE_NO.matcher(s).replaceAll("");         // 页码行
        s = CTRL.matcher(s).replaceAll("");
        s = MULTI_NL.matcher(s).replaceAll("\n\n");
        return s.strip();
    }

    /** 乱码率：非中日韩、非 ASCII 可打印字符的占比 */
    public static double garbageRatio(String s) {
        if (s.isEmpty()) return 1.0;
        long bad = s.codePoints()
                .filter(cp -> !(cp >= 0x20 && cp < 0x7F)
                        && !(cp >= 0x4E00 && cp <= 0x9FFF)
                        && !(cp >= 0x3000 && cp <= 0x303F)
                        && !(cp >= 0xFF00 && cp <= 0xFFEF)
                        && cp != '\n' && cp != '\t')
                .count();
        return (double) bad / s.codePointCount(0, s.length());
    }
}
```

`garbageRatio > 0.15` 基本可以判定为"字体缺失/编码错误"，直接进人工队列，不要喂给 embedding 模型——**垃圾进、垃圾出，而且会污染整个索引**。

---

## 四、分块：版面感知 > 固定长度

### 4.1 四种策略对比

| 策略 | 块边界 | 检索质量 | 实现成本 | 适用 |
|---|---|---|---|---|
| 固定字符数（500/50 overlap） | 任意 | 差（切断语义） | 极低 | 快速验证 |
| 递归字符切分 | 段落/句子 | 中 | 低 | 通用兜底 |
| 标题树 + 段内滑窗 | 章节 | 好 | 中 | 手册、规范、合同 |
| 语义切分（embedding 相似度突变） | 语义段 | 最好 | 高（要跑模型） | 高质量知识库 |

Java 侧推荐 **标题树 + 段内滑窗**：结构清晰、成本可控、可解释（每个块都知道自己属于哪一节，这对引用溯源至关重要）。

### 4.2 代码：结构块 + 滑窗

```java
import java.util.ArrayList;
import java.util.List;

public record Chunk(String id, String docId, String sectionPath,
                    int index, String text, int tokenEstimate) {}

public class StructureChunker {

    private final int targetTokens;
    private final int overlapTokens;

    public StructureChunker(int targetTokens, int overlapTokens) {
        this.targetTokens = targetTokens;
        this.overlapTokens = overlapTokens;
    }

    public List<Chunk> chunk(String docId, List<Section> sections) {
        List<Chunk> out = new ArrayList<>();
        int idx = 0;
        for (Section sec : sections) {
            String[] paras = sec.text().split("\\n\\s*\\n");
            StringBuilder buf = new StringBuilder();
            for (String p : paras) {
                if (estimateTokens(buf) + estimateTokens(p) > targetTokens && buf.length() > 0) {
                    out.add(new Chunk(chunkId(docId, idx), docId, sec.path(), idx++, buf.toString().strip(), estimateTokens(buf)));
                    String tail = tail(buf.toString(), overlapTokens);   // 保留语义尾部做重叠
                    buf.setLength(0);
                    buf.append(tail);
                }
                buf.append(p).append("\n\n");
            }
            if (buf.length() > 0) {
                out.add(new Chunk(chunkId(docId, idx), docId, sec.path(), idx++, buf.toString().strip(), estimateTokens(buf)));
            }
        }
        return out;
    }

    /** 中英混排的粗略估算：中文 1 字≈1 token，英文 4 字符≈1 token */
    static int estimateTokens(CharSequence s) {
        int cjk = 0, other = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c >= 0x4E00 && c <= 0x9FFF) cjk++; else other++;
        }
        return cjk + other / 4;
    }

    private static String tail(String s, int tokens) {
        int keep = Math.min(s.length(), tokens * 2);
        return s.substring(s.length() - keep);
    }

    private static String chunkId(String docId, int idx) {
        return docId + ":" + idx;
    }
}
```

关键参数经验值：

| 场景 | 块大小 | 重叠 | 理由 |
|---|---|---|---|
| FAQ / 短文档 | 200~300 token | 0~30 | 一问一答，块太大反而稀释 |
| 技术手册 | 400~600 token | 50~80 | 一节一概念，覆盖完整论证 |
| 合同/法务 | 300~500 token | 100 | 条款边界必须完整，重叠保上下文 |
| 会议纪要 | 按议题切 | 0 | 议题天然边界 |

**块大小不是越大越好**：块越大，单块向量越"平均"，检索精度下降；块越小，上下文缺失导致 LLM 答不全。400~600 token 是大多数技术文档的甜点区。

---

## 五、幂等增量索引：最容易埋雷的一段

### 5.1 三个版本号决定 `chunkId`

```
chunkId = sha256(docId + chunkIndex + chunkerVersion + parserVersion)
```

- `parserVersion`：解析器升级（比如 PDF 抽取从"流顺序"改成"版面重排"）必须换版本，否则旧块永远不会被替换。
- `chunkerVersion`：分块策略变更同理。
- `contentHash`：文档内容变了才重新摄取，避免"每天全量重跑"。

```java
public record DocFingerprint(String docId, String contentSha256,
                             String parserVersion, String chunkerVersion) {
    public String pipelineKey() {
        return contentSha256 + "|" + parserVersion + "|" + chunkerVersion;
    }
}
```

### 5.2 增量同步：先删后插，别只插不删

```java
import org.springframework.ai.document.Document;
import org.springframework.ai.vectorstore.VectorStore;
import org.springframework.ai.vectorstore.filter.FilterExpressionBuilder;

import java.util.List;

public class IdempotentIndexer {

    private final VectorStore vectorStore;

    public IdempotentIndexer(VectorStore vectorStore) {
        this.vectorStore = vectorStore;
    }

    public void upsert(String docId, List<Chunk> chunks, String pipelineKey) {
        // 1) 先按 docId 删除该文档的所有旧块（包括"新版本里已不存在的块"）
        vectorStore.delete(new FilterExpressionBuilder()
                .eq("docId", docId).build());

        // 2) 再批量写入新块
        List<Document> docs = chunks.stream()
                .map(c -> new Document(c.id(), c.text(), java.util.Map.of(
                        "docId", docId,
                        "sectionPath", c.sectionPath() == null ? "" : c.sectionPath(),
                        "chunkIndex", c.index(),
                        "pipelineKey", pipelineKey,
                        "tokenEstimate", c.tokenEstimate())))
                .toList();
        vectorStore.add(docs);
    }

    /** 文档被删除时调用，避免"孤儿块" */
    public void deleteDoc(String docId) {
        vectorStore.delete(new FilterExpressionBuilder().eq("docId", docId).build());
    }
}
```

三个必须注意的点：

1. **只 upsert 不 delete 会出现"孤儿块"**：文档第 3 节被删了，旧块还在索引里，检索时永远命中已删除内容。这是 RAG 最隐蔽的"答错"来源之一。
2. **删除必须按 `docId` 过滤**，不能按 `chunkId` 列表删（你无法保证旧块列表还完整）。
3. **批量写入要控批**：一次 5000 块会让 embedding 服务超时、向量库事务过大。200~500 块一批，失败重试用指数退避。

### 5.3 全量重建的安全姿势

用"影子集合 + 别名切换"而不是原地清空：

```
1. 建新集合 kb_v2（新 parserVersion/chunkerVersion）
2. 全量写入 kb_v2
3. 校验：块数、抽样检索、黄金集通过率
4. 别名 kb → kb_v2 原子切换（ES: _aliases；Milvus: alias；pgvector: 视图切换）
5. 保留 kb_v1 一周后删除
```

原地 `delete all + reindex` 的窗口期内，线上问答会"失忆"，且一旦重建失败回滚成本极高。

---

## 六、质量门禁：把"坏摄取"挡在索引外

| 指标 | 计算 | 阈值 | 处置 |
|---|---|---|---|
| 抽取字符数 | `text.length()` | < 200（PDF > 3 页） | 疑似扫描件 → OCR 队列 |
| 乱码率 | `garbageRatio` | > 0.15 | 字体问题 → 人工复核 |
| 空块率 | 空块/总块 | > 5% | 分块器 bug |
| 重复率 | 块间 3-gram Jaccard | > 0.3 | 页眉页脚未清洗 |
| 块大小分布 | P50/P95 token | P95 > 1200 | 分块参数失配 |
| 表格还原率 | 表格块/原表数 | < 0.8 | 表格通道失效 |

这些指标应当作为**摄取任务的返回值**记录到数据库，形成"文档质量看板"。RAG 效果排查时，第一步永远是看这份看板，而不是换模型。

---

## 七、生产踩坑清单

1. **PDFBox 全量加载内存爆**：`PDDocument.load()` 会把整个文档读进内存，几百页的扫描件能吃掉 1GB。用 `MemoryUsageSetting.setupTempFileOnly()`，或按页范围分批处理。
2. **字体缺失导致 CID 乱码**：PDF 里嵌入子集字体时，抽取出来是 `(cid:123)`。需要用 `PDFTextStripper` 的 `getAvailableFonts` 检测，或直接用 OCR 兜底。
3. **加密 PDF 静默失败**：`InvalidPasswordException` 被 catch 成"空文本"，最后成了"文档没内容"。必须区分"解析失败"和"内容为空"。
4. **DOCX 页眉页脚重复**：POI 的 `XWPFWordExtractor` 会带页眉，长文档里同一句出现上百次，直接污染检索。用 `XWPFDocument.getParagraphs()` 自己遍历正文。
5. **Excel 合并单元格**：POI 事件模型拿不到合并信息，必须用 `XSSFSheet.getMergedRegions()` 补齐，否则会出现大量空列。
6. **Tika 递归解析附件**：一封邮件带 50 个附件 → 一次摄取产出上万块。用 `ParseContext` 关闭递归，附件单独入队。
7. **embedding 批大小与限流**：OpenAI 类接口有 TPM 限制，批量太大会 429；按 token 数而非条数分批，并做退避。
8. **增量任务无幂等键**：MQ 重投导致同一文档被摄取两次，向量库里出现完全重复的块。用 `docId + pipelineKey` 做去重，或让索引操作天然幂等。

---

## 八、面试常见追问

**Q1：RAG 答不准，你怎么定位是检索问题还是生成问题？**
先看"黄金集召回率"：给定标准问题，检索 Top5 里是否包含正确片段。召回不行 → 摄取/分块/embedding 问题；召回行但答案错 → 生成/Prompt/上下文组织问题。而召回不行的第一嫌疑永远是解析质量。

**Q2：为什么要保留"解析产物快照"？**
因为分块策略会反复调。没有快照就要重新解析原文件（慢、且解析器版本变化导致结果不可复现）。有快照才能"只换分块器"快速做 A/B。

**Q3：块大小怎么定？**
按文档类型定，不看模型上下文长度。FAQ 200~300 token，技术手册 400~600，合同 300~500 且必须在条款边界切。判断标准是"单块能否独立回答一个问题"。

**Q4：为什么不能只 upsert？**
文档更新后旧块残留形成"孤儿块"，检索会命中已删除内容；文档删除后块还在，属于数据一致性事故（也是权限泄漏风险）。必须"按 docId 先删后插"。

**Q5：表格为什么不能直接当纯文本？**
列语义丢失后，"2024 年营收 3.2 亿"会变成孤立的数字串，既检索不到也理解不了。要么转 Markdown 保结构，要么按行转"列名: 值"的句子。

**Q6：全量重建怎么做到不停机？**
影子集合 + 别名原子切换 + 黄金集校验门禁。切换是元数据操作（毫秒级），失败则别名指回旧集合，不需要回滚数据。

---

## 九、小结

- RAG 的效果上限在摄取阶段就被决定了，解析与分块是第一优先级，不是模型。
- Tika 做格式识别与兜底，PDFBox 做版面感知，POI 做 Office 精细解析，表格走单独通道。
- 分块优先按结构（标题树）切，块内再滑窗，400~600 token 是技术文档的甜点区。
- 幂等的三要素：`docId` 级先删后插、`parserVersion/chunkerVersion` 参与 `chunkId`、全量重建走影子集合 + 别名切换。
- 质量门禁（字符数、乱码率、空块率、重复率、块大小分布）要变成摄取任务的产出指标，它是 RAG 排障的第一现场。
