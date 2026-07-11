---
title: 【Java实战】Apache POI 与 EasyExcel 百万级 Excel 导入导出方案
date: 2026-07-11 08:00:00
tags:
  - Java
  - Excel
  - EasyExcel
  - POI
categories:
  - Java
author: 东哥
---

# 【Java实战】Apache POI 与 EasyExcel 百万级 Excel 导入导出方案

## 前言

Excel 导入导出是 Java 后端开发中最常见的需求之一。从运营后台的数据报表导出，到批量数据导入，几乎每个项目都离不开 Excel 处理。

但很多人会踩坑：几万条数据导出就 OOM，导入时内存暴涨，大文件处理慢如蜗牛。

本文系统梳理 Apache POI 和阿里 EasyExcel 的核心用法，重点解决百万级数据导入导出中的内存与性能问题。

<!-- more -->

---

## 一、技术选型：POI vs EasyExcel

### 1.1 基础知识

Java 处理 Excel 的主流方案：

| 框架 | 维护方 | 支持格式 | 内存模型 | 学习成本 |
|------|--------|---------|---------|---------|
| Apache POI | Apache | .xls/.xlsx | 用户模式（全量内存） | 高 |
| EasyExcel | 阿里 | .xls/.xlsx | 流式读写（逐行） | 低 |
| JXL | 已停止维护 | .xls | 用户模式 | 低 |

**Apache POI** 是业界标准，功能最全，但 HSSFWorkbook 读取 .xlsx 时会将整个文档加载到内存，**10万行数据就可能撑爆 1G 堆内存**。

**EasyExcel** 基于 POI 做了 SAX 模式的封装，逐行解析 Excel，**1 百万行数据的内存占用可以控制在几十 MB**。

### 1.2 选型建议

```text
简单小文件（<1万行） → POI/Hutool 都可以，代码简单
大文件导出（>10万行） → EasyExcel SXSSFWorkbook 流式写入
大文件导入（>10万行） → EasyExcel 监听器 + 分批入库
.xls 格式（兼容旧系统） → POI HSSFWorkbook
需要操作格式/样式/图表 → POI（功能最全）
```

---

## 二、Apache POI 基础操作

### 2.1 Maven 引入

```xml
<dependency>
    <groupId>org.apache.poi</groupId>
    <artifactId>poi-ooxml</artifactId>
    <version>5.3.0</version>
</dependency>
```

### 2.2 用 HSSFWorkbook 创建 Excel（.xls 格式）

```java
public void createXls() throws IOException {
    HSSFWorkbook workbook = new HSSFWorkbook();
    HSSFSheet sheet = workbook.createSheet("用户数据");

    // 创建表头
    HSSFRow headerRow = sheet.createRow(0);
    String[] headers = {"ID", "姓名", "邮箱", "创建时间"};
    for (int i = 0; i < headers.length; i++) {
        headerRow.createCell(i).setCellValue(headers[i]);
    }

    // 填充数据
    for (int i = 1; i <= 1000; i++) {
        HSSFRow row = sheet.createRow(i);
        row.createCell(0).setCellValue(i);
        row.createCell(1).setCellValue("用户" + i);
        row.createCell(2).setCellValue("user" + i + "@example.com");
        row.createCell(3).setCellValue(new Date().toString());
    }

    // 输出
    try (FileOutputStream fos = new FileOutputStream("users.xls")) {
        workbook.write(fos);
    }
    workbook.close();
}
```

### 2.3 用 XSSFWorkbook 创建 Excel（.xlsx 格式）

```java
XSSFWorkbook workbook = new XSSFWorkbook();
XSSFSheet sheet = workbook.createSheet("数据");
// 使用方式与 HSSFWorkbook 一致
```

### 2.4 样式与格式化

```java
XSSFWorkbook workbook = new XSSFWorkbook();
XSSFSheet sheet = workbook.createSheet("报表");

// 创建单元格样式
XSSFCellStyle headerStyle = workbook.createCellStyle();
headerStyle.setFillForegroundColor(new XSSFColor(Color.LIGHT_BLUE, new DefaultIndexedColorMap()));
headerStyle.setFillPattern(FillPatternType.SOLID_FOREGROUND);
headerStyle.setBorderBottom(BorderStyle.THIN);
headerStyle.setBorderTop(BorderStyle.THIN);
headerStyle.setBorderLeft(BorderStyle.THIN);
headerStyle.setBorderRight(BorderStyle.THIN);

// 创建字体
XSSFFont font = workbook.createFont();
font.setBold(true);
font.setFontHeightInPoints((short) 12);
headerStyle.setFont(font);

// 设置列宽
sheet.setColumnWidth(0, 10 * 256);  // 10个字符宽
sheet.setColumnWidth(1, 20 * 256);

// 合并单元格
sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 3));
```

---

## 三、大文件导出性能优化（SXSSFWorkbook）

### 3.1 SXSSFWorkbook 原理

`XSSFWorkbook` 在写入大文件时，所有行数据都驻留在内存中。想象一下，100 万行 × 10 列，每行几百字节，光数据就几百 MB。

`SXSSFWorkbook` 是 POI 3.8+ 提供的**流式写入**方案：内部维护一个滑动窗口，只有窗口内的行在内存中，窗口之外的行被刷入磁盘的临时文件。

```java
// 核心参数：内存中保留 100 行，其余写入临时文件
SXSSFWorkbook workbook = new SXSSFWorkbook(100);
// 注意：SXSSFWorkbook 继承自 XSSFWorkbook，但写出的仍然是 .xlsx
```

### 3.2 百万级数据导出实战

```java
public void exportLargeExcel(List<User> users, OutputStream outputStream) throws IOException {
    // 1. 创建流式 Workbook，内存保留 100 行
    SXSSFWorkbook workbook = new SXSSFWorkbook(100);
    // 开启压缩：临时文件使用 gzip 压缩，减少磁盘 I/O
    workbook.setCompressTempFiles(true);

    try {
        Sheet sheet = workbook.createSheet("用户数据");

        // 2. 创建表头
        Row headerRow = sheet.createRow(0);
        String[] headers = {"ID", "姓名", "邮箱", "手机号", "注册时间", "状态"};
        for (int i = 0; i < headers.length; i++) {
            Cell cell = headerRow.createCell(i);
            cell.setCellValue(headers[i]);
        }

        // 3. 分批写入数据
        int rowNum = 1;
        for (User user : users) {
            Row row = sheet.createRow(rowNum++);
            row.createCell(0).setCellValue(user.getId());
            row.createCell(1).setCellValue(user.getName());
            row.createCell(2).setCellValue(user.getEmail());
            row.createCell(3).setCellValue(user.getPhone());
            row.createCell(4).setCellValue(user.getCreateTime().toString());
            row.createCell(5).setCellValue(user.getStatus());

            // 每 10000 行刷一次到临时文件，释放内存
            if (rowNum % 10000 == 0) {
                ((SXSSFSheet) sheet).flushRows(10000);
                log.info("已写入 {} 行", rowNum);
            }
        }

        workbook.write(outputStream);
    } finally {
        // 4. 清理临时文件
        workbook.dispose();
    }
}
```

### 3.3 性能对比

| 实现方式 | 10万行 | 50万行 | 100万行 |
|---------|--------|--------|---------|
| XSSFWorkbook | ~800MB 内存 ❌ | OOM ❌ | OOM ❌ |
| SXSSFWorkbook(100) | ~30MB ✅ | ~50MB ✅ | ~80MB ✅ |
| SXSSFWorkbook + 压缩 | ~25MB ✅ | ~40MB ✅ | ~60MB ✅ |

---

## 四、EasyExcel 大文件处理

### 4.1 引入依赖

```xml
<dependency>
    <groupId>com.alibaba</groupId>
    <artifactId>easyexcel</artifactId>
    <version>4.0.3</version>
</dependency>
```

### 4.2 EasyExcel 大文件写入

```java
public void easyExcelWrite(List<User> users) {
    String fileName = "users_easy.xlsx";

    // 流式写入：一行数据写完就刷到磁盘
    EasyExcel.write(fileName, User.class)
        .sheet("用户数据")
        .doWrite(() -> {
            // 分页查询，每次返回一批
            return userService.pageQuery(pageNum, 5000);
        });
}

// 使用 @ExcelProperty 注解映射
@Data
public class User {
    @ExcelProperty("ID")
    private Long id;

    @ExcelProperty("姓名")
    private String name;

    @ExcelProperty("邮箱")
    @ColumnWidth(30)
    private String email;

    @ExcelProperty("手机号")
    @ColumnWidth(15)
    private String phone;

    @ExcelProperty("注册时间")
    @DateTimeFormat("yyyy-MM-dd HH:mm:ss")
    private Date createTime;

    @ExcelProperty("状态")
    private String status;
}
```

### 4.3 EasyExcel 大文件读取（核心）

EasyExcel 的**流式读取**是最有特色的功能，使用「监听器 + 行级回调」的方式，逐行解析 Excel，避免了把整个文件加载到内存。

```java
// 1. 定义监听器
public class UserDataListener implements ReadListener<User> {
    private static final int BATCH_SIZE = 1000;
    private final List<User> cachedData = new ArrayList<>(BATCH_SIZE);
    private final UserService userService;

    public UserDataListener(UserService userService) {
        this.userService = userService;
    }

    @Override
    public void invoke(User user, AnalysisContext context) {
        cachedData.add(user);
        // 每 BATCH_SIZE 条数据批量入库
        if (cachedData.size() >= BATCH_SIZE) {
            saveData();
        }
    }

    @Override
    public void doAfterAllAnalysed(AnalysisContext context) {
        // 处理剩余数据
        if (!cachedData.isEmpty()) {
            saveData();
        }
    }

    private void saveData() {
        userService.batchInsert(cachedData);
        cachedData.clear();
    }
}

// 2. 读取文件
public void importUsers(MultipartFile file) {
    EasyExcel.read(file.getInputStream(), User.class, new UserDataListener(userService))
        .sheet()
        .doRead();
}
```

### 4.4 读取时的常见问题处理

```java
// 跳过前 N 行（表头之外的垃圾行）
EasyExcel.read(file, User.class, listener)
    .headRowNumber(2)  // 第2行才是真正的表头
    .sheet()
    .doRead();

// 指定从第几行开始读取
EasyExcel.read(file, User.class, listener)
    .sheet()
    .headRowNumber(1)
    .doRead();

// 处理多 Sheet
ExcelReader excelReader = EasyExcel.read(file.getInputStream()).build();
ReadSheet sheet1 = EasyExcel.readSheet(0).head(User.class).registerReadListener(listener1).build();
ReadSheet sheet2 = EasyExcel.readSheet(1).head(Order.class).registerReadListener(listener2).build();
excelReader.read(sheet1, sheet2);
excelReader.finish();
```

### 4.5 自定义转换器

```java
public class LocalDateTimeConverter implements Converter<LocalDateTime> {
    @Override
    public Class<?> supportJavaTypeKey() {
        return LocalDateTime.class;
    }

    @Override
    public CellDataTypeEnum supportExcelTypeKey() {
        return CellDataTypeEnum.STRING;
    }

    @Override
    public LocalDateTime convertToJavaData(ReadCellData<?> cellData, ExcelContentProperty contentProperty,
            GlobalConfiguration globalConfiguration) {
        return LocalDateTime.parse(cellData.getStringValue(), DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"));
    }

    @Override
    public WriteCellData<?> convertToExcelData(LocalDateTime value, ExcelContentProperty contentProperty,
            GlobalConfiguration globalConfiguration) {
        return new WriteCellData<>(value.format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")));
    }
}

// 使用
@Data
public class Order {
    @ExcelProperty(value = "创建时间", converter = LocalDateTimeConverter.class)
    private LocalDateTime createTime;
}
```

---

## 五、生产实践：通用 Excel 工具类

### 5.1 泛型导出工具

```java
@Component
public class ExcelExportUtil {
    /**
     * 导出 Excel（支持百万级数据流式导出）
     */
    public <T> void exportExcel(HttpServletResponse response, String fileName,
                                Class<T> clazz, List<T> data) throws IOException {
        response.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        response.setCharacterEncoding("utf-8");
        // URL 编码处理文件名
        String encodedFileName = URLEncoder.encode(fileName, "UTF-8").replaceAll("\\+", "%20");
        response.setHeader("Content-disposition", "attachment;filename*=utf-8''" + encodedFileName + ".xlsx");

        EasyExcel.write(response.getOutputStream(), clazz)
            .autoCloseStream(true)
            .sheet("Sheet1")
            .doWrite(data);
    }

    /**
     * 分页流式导出（适合海量数据）
     */
    public <T> void exportLargeExcel(HttpServletResponse response, String fileName,
                                      Class<T> clazz, QueryFunction queryFunc) throws IOException {
        response.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        response.setCharacterEncoding("utf-8");

        EasyExcel.write(response.getOutputStream(), clazz)
            .autoCloseStream(true)
            .sheet("Sheet1")
            .doWrite(() -> {
                // 每次返回一页数据，由 EasyExcel 逐页拉取
                return queryFunc.pageQuery(1, 5000);
            });
    }

    @FunctionalInterface
    public interface QueryFunction {
        List<?> pageQuery(int pageNum, int pageSize);
    }
}
```

### 5.2 导入校验工具

```java
@Component
public class ExcelImportValidator {
    private static final Set<String> VALID_STATUS = Set.of("启用", "禁用");

    public static List<ExcelError> validate(List<User> users) {
        List<ExcelError> errors = new ArrayList<>();
        for (int i = 0; i < users.size(); i++) {
            User user = users.get(i);
            int rowNum = i + 2; // 从第2行开始（第1行是表头）

            if (StringUtils.isBlank(user.getName())) {
                errors.add(new ExcelError(rowNum, "姓名", "姓名不能为空"));
            }
            if (!VALID_STATUS.contains(user.getStatus())) {
                errors.add(new ExcelError(rowNum, "状态", "状态只能是'启用'或'禁用'"));
            }
        }
        return errors;
    }

    @Data
    @AllArgsConstructor
    public static class ExcelError {
        private int rowNum;
        private String fieldName;
        private String errorMsg;
    }
}
```

---

## 六、性能优化最佳实践

### 6.1 内存优化 checklist

| 优化项 | 说明 | 效果 |
|-------|------|------|
| 使用 SXSSFWorkbook | 流式写入，不驻留全部行内存 | 内存降 90%+ |
| 设置 flushRows | 定期刷到磁盘 | 控制窗口大小 |
| 启用压缩 | SXSSFWorkbook.setCompressTempFiles(true) | 减少磁盘 I/O |
| 使用 EasyExcel 读 | SAX 逐行解析 | 大文件导入可行 |
| 分批入库 | 监听器中 1000 条一批 | 避免大事务 |
| 关闭样式 | 大文件导出避免复杂样式 | 提升写入速度 3-5 倍 |
| 使用 BufferedOutputStream | 减少磁盘写入次数 | 提升 20% 以上 |

### 6.2 常见坑点

**坑1：导出时内存暴增**

```java
// ❌ 错误：一次性加载全部数据
List<User> allUsers = userService.findAll(); // 100万条数据 -> 内存爆炸
EasyExcel.write(fileName, User.class).sheet().doWrite(allUsers);

// ✅ 正确：分页流式
EasyExcel.write(fileName, User.class).sheet().doWrite(() -> {
    return userService.pageQuery(pageNum, 5000);
});
```

**坑2：POI 临时文件不清理**

```java
// SXSSFWorkbook 使用完必须 dispose()
SXSSFWorkbook workbook = new SXSSFWorkbook();
try {
    // ... 写入操作
    workbook.write(os);
} finally {
    workbook.dispose();  // 删除临时文件！
    workbook.close();
}
```

**坑3：BigDecimal 精度丢失**

```java
// EasyExcel 默认将数字转为 Double，可能丢失精度
// 解决方案：注解指定类型
@ExcelProperty(value = "金额")
@NumberFormat("#.##")
private BigDecimal amount;
```

---

## 七、面试常见追问

**Q1：为何 XSSFWorkbook 读取大文件会 OOM？**

A：XSSFWorkbook 采用 DOM 模式，将整个 XML 文档解析为对象树存放在内存中，一个 10MB 的 .xlsx 文件可能在内存中膨胀到几百 MB 乃至 1GB+。

**Q2：EasyExcel 为什么能处理超大文件？**

A：EasyExcel 采用 SAX（Simple API for XML）模式，逐行读取 XML 内容，解析完一行就释放一行引用，只保留当前行在内存中。这就好比看一部电影——DOM 模式是先把整部电影下载到本地再播放，SAX 模式是边下边播。

**Q3：SXSSFWorkbook 的滑动窗口原理？**

A：SXSSFWorkbook 构造时指定一个 `windowSize`（默认 100），只有最后 windowSize 行在内存中，更早的行被写入磁盘临时 XML 文件。当再次 flushRows 时，当前最旧的一批行被刷入临时文件。

**Q4：EasyExcel 支持 xls 格式吗？**

A：支持，但不推荐。xls 格式（Excel 97-2003）最大只支持 65536 行 × 256 列，且解析性能不如 xlsx。建议新系统统一使用 .xlsx。

---

## 总结

Excel 处理看似简单，但在海量数据场景下对内存和性能的挑战不容忽视。

- **小数据**：POI 或 Hutool，怎么简单怎么来
- **大数据导出**：SXSSFWorkbook 或 EasyExcel 流式写入
- **大数据导入**：EasyExcel 监听器 + 分批入库
- **复杂样式/图表**：使用 POI 原生 API

记住一个核心原则：**不要把全部数据加载到内存再处理**——流式读写才是大文件的正确打开方式。
