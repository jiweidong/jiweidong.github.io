---
title: 【Java实战】Hutool 工具库全栈指南：从字符串处理到加密解密的生产级实战
date: 2026-07-11 08:00:00
tags:
  - Java
  - Hutool
  - 工具库
categories:
  - Java
author: 东哥
---

# 【Java实战】Hutool 工具库全栈指南：从字符串处理到加密解密的生产级实战

## 前言

在日常 Java 开发中，我们常常需要写大量「与业务无关」的工具代码：日期格式化、文件读写、字符串处理、Http 请求、加密解密、Excel 操作……虽然 JDK 已经提供了很多 API，但用起来往往不够顺手。

**Hutool** 是 GitHub 上最受欢迎的国产 Java 工具库，star 数 28k+。它把开发中高频使用的工具方法封装成简单易用的 API，核心口号是「让你的 Java 开发效率翻倍」。

> 对比一下：用 JDK 写一个 Http 请求通常要 20+ 行代码（URLConnection + 缓冲流 + 异常处理），用 Hutool 只需 1 行：`HttpUtil.get(url)`。

本文从实战出发，覆盖 Hutool 最常用的 10 大模块。

<!-- more -->

---

## 一、Hutool 概览

### 1.1 Maven 引入

```xml
<dependency>
    <groupId>cn.hutool</groupId>
    <artifactId>hutool-all</artifactId>
    <version>5.8.30</version>
</dependency>
```

如果只需特定模块，可以按需引入：

```xml
<dependency>
    <groupId>cn.hutool</groupId>
    <artifactId>hutool-core</artifactId>     <!-- 核心模块 -->
    <version>5.8.30</version>
</dependency>
<dependency>
    <groupId>cn.hutool</groupId>
    <artifactId>hutool-http</artifactId>     <!-- HTTP 客户端 -->
    <version>5.8.30</version>
</dependency>
<dependency>
    <groupId>cn.hutool</groupId>
    <artifactId>hutool-crypto</artifactId>   <!-- 加密解密 -->
    <version>5.8.30</version>
</dependency>
```

### 1.2 模块概览

| 模块 | 功能 | 典型类 |
|------|------|--------|
| hutool-core | Bean、集合、字符串、日期 | StrUtil / DateUtil / BeanUtil |
| hutool-http | HTTP 客户端 | HttpUtil / HttpRequest |
| hutool-crypto | 对称/非对称/摘要加密 | SecureUtil / AES / RSA |
| hutool-poi | Excel Word 操作 | ExcelUtil / ExcelReader |
| hutool-json | JSON 处理 | JSONUtil |
| hutool-cache | 缓存工具 | CacheUtil / LRUCache |
| hutool-captcha | 验证码生成 | CaptchaUtil / LineCaptcha |
| hutool-socket | Socket 通信 | NetUtil / IoUtil |
| hutool-setting | 配置文件读取 | Setting / Props |
| hutool-log | 日志自动适配 | LogFactory / StaticLog |

---

## 二、字符串与集合操作

### 2.1 StrUtil —— 比你想象的更强大

```java
// 字符串判空
StrUtil.isEmpty(null);          // true
StrUtil.isEmpty("");             // true
StrUtil.isBlank("  ");           // true（空格也算空）
StrUtil.isNotBlank("hello");     // true

// 字符串格式化
StrUtil.format("姓名：{}，年龄：{}", "张三", 25);
// 结果："姓名：张三，年龄：25"

// 驼峰与下划线互转
StrUtil.toCamelCase("user_name");        // "userName"
StrUtil.toUnderlineCase("userName");      // "user_name"

// 脱敏（常用）
StrUtil.hide("13812345678", 3, 7);       // "138****5678"
StrUtil.hide("张三", 1, 1);               // "张*"

// 截取
StrUtil.sub("abcdefg", 2, 5);             // "cde"
StrUtil.subSuf("hello.txt", 4);          // ".txt"

// 填充
StrUtil.padPre("1", 4, '0');             // "0001"
StrUtil.padAfter("1", 4, '0');           // "1000"

// UUID 去横线
String uuid = IdUtil.fastSimpleUUID();   // "a0b1c2d3e4f5g6h7i8j9k0l1"
```

### 2.2 CollUtil —— 集合操作利器

```java
// 创建集合
List<String> list = CollUtil.newArrayList("a", "b", "c");
Set<String> set = CollUtil.newHashSet("a", "b", "c");

// 集合判空
CollUtil.isEmpty(list);                  // false
CollUtil.isNotEmpty(list);               // true

// 交集、并集、差集
List<String> list1 = CollUtil.newArrayList("a", "b", "c");
List<String> list2 = CollUtil.newArrayList("b", "c", "d");

CollUtil.intersection(list1, list2);     // ["b", "c"]
CollUtil.union(list1, list2);            // ["a", "b", "c", "d"]
CollUtil.subtract(list1, list2);         // ["a"]

// 分组
User user1 = new User("张三", "A组");
User user2 = new User("李四", "B组");
User user3 = new User("王五", "A组");
Map<String, List<User>> groupMap = CollUtil.groupBy(
    CollUtil.newArrayList(user1, user2, user3),
    User::getGroup
);
```

### 2.3 BeanUtil —— Bean 操作

```java
// 对象属性拷贝（替代 BeanUtils.copyProperties）
UserVO userVO = new UserVO();
BeanUtil.copyProperties(user, userVO);

// Map 转 Bean
Map<String, Object> map = MapUtil.ofEntries(
    MapUtil.entry("name", "张三"),
    MapUtil.entry("age", 25)
);
User user = BeanUtil.toBean(map, User.class);

// Bean 转为 Map
Map<String, Object> beanMap = BeanUtil.beanToMap(user);

// 获取属性的值
Object value = BeanUtil.getFieldValue(user, "name");

// 判断是否为 Bean
BeanUtil.isBean(user.getClass());    // true（有 getter/setter）
```

---

## 三、日期时间处理

### 3.1 DateUtil —— 告别 SimpleDateFormat 线程安全问题

```java
// 获取当前时间
Date now = DateUtil.date();                     // 当前时间
Date date = DateUtil.date(Calendar.getInstance());

// 字符串解析
Date parsed = DateUtil.parse("2026-07-11");                    // 自动识别格式
Date parsed2 = DateUtil.parse("2026-07-11 08:00:00");           // 同样支持
Date parsed3 = DateUtil.parse("2026/07/11", "yyyy/MM/dd");     // 指定格式

// 格式化
String formatted = DateUtil.format(date, "yyyy-MM-dd HH:mm:ss");

// 时间偏移
Date nextDay = DateUtil.offsetDay(date, 1);        // 明天
Date lastMonth = DateUtil.offsetMonth(date, -1);   // 上个月此时
Date nextHour = DateUtil.offsetHour(date, 2);      // 两小时后

// 时间差计算
long betweenDays = DateUtil.betweenDay(date1, date2, false);   // 相差天数
long betweenHours = DateUtil.between(date1, date2, DateUnit.HOUR);

// 年龄计算
int age = DateUtil.ageOfNow("1995-06-15");   // 31

// 星座 & 生肖
String zodiac = DateUtil.getZodiac(Month.JULY.getValue(), 11);         // 巨蟹座
String chineseZodiac = DateUtil.getChineseZodiac(1995);                // 猪
```

### 3.2 LocalDateTimeUtil —— Java 8+ 时间 API 的增强

```java
// 获取当前时间
LocalDateTime now = LocalDateTimeUtil.now();

// 解析
LocalDateTime dt = LocalDateTimeUtil.parse("2026-07-11 08:00:00", "yyyy-MM-dd HH:mm:ss");

// 时间差
Duration duration = LocalDateTimeUtil.between(start, end);
duration.toHours();       // 相差小时数

// 一天的开始和结束
LocalDateTime beginOfDay = LocalDateTimeUtil.beginOfDay(date);
LocalDateTime endOfDay = LocalDateTimeUtil.endOfDay(date);
```

---

## 四、文件与 IO 操作

### 4.1 FileUtil —— 文件操作

```java
// 创建文件（自动创建父目录）
FileUtil.touch("/tmp/data/config.properties");

// 写入文件
FileUtil.writeUtf8String("Hello Hutool", "/tmp/hello.txt");        // 覆盖写入
FileUtil.appendUtf8String("\n下一行", "/tmp/hello.txt");            // 追加写入

// 读取文件
String content = FileUtil.readUtf8String("/tmp/hello.txt");
List<String> lines = FileUtil.readUtf8Lines("/tmp/hello.txt");

// 文件复制
FileUtil.copy("/tmp/source.txt", "/tmp/target.txt", true);         // true=覆盖

// 获取文件扩展名
String ext = FileUtil.extName("photo.jpg");                         // "jpg"
String ext2 = FileUtil.extName("data.tar.gz");                      // "gz"

// 获取文件主名
String mainName = FileUtil.mainName("photo.jpg");                   // "photo"

// 获取文件大小（自动格式化）
String size = FileUtil.readableFileSize(new File("/tmp/bigfile.data"));  // "102.5 MB"

// 遍历目录
FileUtil.loopFiles("/tmp", file -> file.getName().endsWith(".txt"));
```

### 4.2 IoUtil —— 流操作

```java
// 输入流转字符串
String content = IoUtil.readUtf8(inputStream);

// 输入流转字节数组
byte[] bytes = IoUtil.readBytes(inputStream);

// 复制流
IoUtil.copy(inputStream, outputStream, IoUtil.DEFAULT_BUFFER_SIZE);

// 读取指定大小的内容
byte[] part = IoUtil.readBytes(inputStream, 1024);
```

### 4.3 FileTypeUtil —— 文件类型识别

```java
// 根据文件头识别真实类型（不依赖扩展名）
File file = new File("photo.jpg");
String type = FileTypeUtil.getType(file);
// 即使扩展名被改为 .pdf，也能识别出真实类型为 "jpg"
```

---

## 五、HTTP 客户端

### 5.1 HttpUtil —— 简化 HTTP 请求

```java
// GET 请求
String result = HttpUtil.get("https://api.example.com/users?id=1");

// 带参数的 GET
HashMap<String, Object> params = new HashMap<>();
params.put("page", 1);
params.put("size", 20);
String result = HttpUtil.get("https://api.example.com/users", params);

// POST 请求（JSON 格式）
String jsonBody = JSONUtil.toJsonStr(user);
String result = HttpUtil.post("https://api.example.com/user/add", jsonBody);

// POST 表单
HashMap<String, Object> form = new HashMap<>();
form.put("username", "test");
form.put("password", "123456");
String result = HttpUtil.post("https://api.example.com/login", form);
```

### 5.2 高级用法 —— 完整的请求配置

```java
// 完整的请求控制
String result = HttpRequest.post("https://api.example.com/data")
    .header("Authorization", "Bearer token123")     // 设置请求头
    .header("Content-Type", "application/json")
    .body(jsonBody)                                   // 请求体
    .timeout(5000)                                    // 超时时间（毫秒）
    .setHttpProxy("127.0.0.1", 8888)                 // HTTP 代理
    .execute()                                        // 执行
    .body();                                          // 获取响应体

// 文件上传
HttpRequest.post("https://api.example.com/upload")
    .form("file", FileUtil.file("/tmp/photo.jpg"))
    .form("description", "用户头像")
    .execute();

// 下载文件
HttpUtil.downloadFile("https://example.com/photo.jpg",
    FileUtil.file("/tmp/download/photo.jpg"));
// 带进度回调
HttpUtil.downloadFile("https://example.com/bigfile.zip",
    FileUtil.file("/tmp/download/bigfile.zip"),
    new StreamProgress() {
        @Override
        public void start() { log.info("开始下载..."); }
        @Override
        public void progress(long total, long progressSize) {
            log.info("已下载：{}/{}", progressSize, total);
        }
        @Override
        public void finish() { log.info("下载完成"); }
    });
```

---

## 六、加密解密

### 6.1 摘要加密

```java
// MD5（不可逆）
String md5Hex = SecureUtil.md5("password123");
// SHA-256
String sha256Hex = SecureUtil.sha256("password123");

// BCrypt（推荐密码存储）
String bcryptHash = BCrypt.hashpw("password123", BCrypt.gensalt());
boolean match = BCrypt.checkpw("password123", bcryptHash);  // true

// 加盐
String md5WithSalt = SecureUtil.md5("password123" + "random_salt");
```

### 6.2 对称加密

```java
// AES 加解密
String content = "这是一段敏感数据";
String key = "1234567890123456";  // 16 位密钥

AES aes = SecureUtil.aes(key.getBytes());

String encryptHex = aes.encryptHex(content);     // 加密（Hex 格式存储）
String decrypt = aes.decryptStr(encryptHex);     // 解密
System.out.println(decrypt);                     // "这是一段敏感数据"
```

### 6.3 非对称加密

```java
// RSA 生成密钥对
KeyPair pair = SecureUtil.generateKeyPair("RSA");
PrivateKey privateKey = pair.getPrivate();
PublicKey publicKey = pair.getPublic();

// 公钥加密，私钥解密
RSA rsa = new RSA(privateKey, publicKey);
String encrypt = rsa.encryptHex("敏感信息", KeyType.PublicKey);
String decrypt = rsa.decryptStr(encrypt, KeyType.PrivateKey);

// 私钥签名，公钥验证
byte[] sign = SecureUtil.sign(SignAlgorithm.SHA256withRSA, privateKey, "数据内容".getBytes());
boolean verify = SecureUtil.verify(SignAlgorithm.SHA256withRSA, publicKey, "数据内容".getBytes(), sign);
```

---

## 七、Excel 操作

### 7.1 读取 Excel

```java
// 方式一：简单读取（小文件）
ExcelReader reader = ExcelUtil.getReader("test.xlsx");
List<List<Object>> list = reader.read();  // 读取所有行

// 方式二：映射为 Bean（推荐）
List<User> users = ExcelUtil.getReader("users.xlsx")
    .addHeaderAlias("姓名", "name")
    .addHeaderAlias("年龄", "age")
    .addHeaderAlias("邮箱", "email")
    .readAll(User.class);
```

### 7.2 写入 Excel

```java
// 方式一：简单写入
List<User> users = userService.list();
ExcelUtil.getWriter("output.xlsx")
    .addHeaderAlias("name", "姓名")
    .addHeaderAlias("age", "年龄")
    .addHeaderAlias("email", "邮箱")
    .write(users)
    .close();

// 方式二：合并单元格
BigExcelWriter writer = ExcelUtil.getBigWriter("large.xlsx");
writer.write(users, true);  // true=写入表头
writer.merge(0, 1, "用户数据报表");
writer.close();
```

> 对于大数据量，Hutool 底层也使用了 SXSSFWorkbook 流式写入，支持百万级数据导出。

---

## 八、JSON 工具

```java
// 对象转 JSON
User user = new User("张三", 25);
String json = JSONUtil.toJsonStr(user);
// {"name":"张三","age":25}

// JSON 转对象
User parsed = JSONUtil.toBean(json, User.class);

// JSON 转 List
List<User> userList = JSONUtil.toList(jsonArray, User.class);

// 从 JSON 中取值
JSONObject obj = JSONUtil.parseObj(json);
String name = obj.getStr("name");
int age = obj.getInt("age");

// 格式化 JSON
String prettyJson = JSONUtil.formatJsonStr(json);

// XML 转 JSON
String jsonFromXml = JSONUtil.toJsonStr(XmlUtil.parseXml(xmlStr));
```

---

## 九、其他高频工具

### 9.1 验证码生成

```java
// 生成线段干扰验证码
LineCaptcha captcha = CaptchaUtil.createLineCaptcha(200, 100, 4, 50);
// 输出到流
captcha.write("captcha.png");
// 获取验证码文本
String code = captcha.getCode();          // "a1b2"

// 生成圆形干扰验证码
CircleCaptcha captcha2 = CaptchaUtil.createCircleCaptcha(200, 100, 4, 10);

// 生成算数验证码
ShearCaptcha captcha3 = CaptchaUtil.createShearCaptcha(200, 100, 4, 4);
String expression = captcha3.getCode();    // "3+5=?"
```

### 9.2 身份证工具

```java
// 身份证号解析
String idCard = "110101199506152345";
String province = IdcardUtil.getProvinceByIdCard(idCard);  // "北京市"
int age = IdcardUtil.getAgeByIdCard(idCard);                // 31
String birth = IdcardUtil.getBirthByIdCard(idCard);          // "1995-06-15"
String gender = IdcardUtil.getGenderByIdCard(idCard);        // "女" 或 "男"
boolean valid = IdcardUtil.isValidCard(idCard);              // true
```

### 9.3 网络工具

```java
// 获取本机 IP
String ip = NetUtil.getLocalhostStr();         // "192.168.1.100"

// 端口检测
boolean used = NetUtil.isUsableLocalPort(8080);

// URL 编码解码
String encoded = URLUtil.encode("中文参数", CharsetUtil.CHARSET_UTF_8);
String decoded = URLUtil.decode(encoded, CharsetUtil.CHARSET_UTF_8);

// 判断是否为内网 IP
boolean internal = NetUtil.isInnerIP("192.168.1.1");  // true
```

### 9.4 反射工具

```java
// 获取所有字段（包括父类）
Field[] fields = ReflectUtil.getFields(User.class);

// 获取方法
Method method = ReflectUtil.getMethod(User.class, "getName");

// 调用方法
Object result = ReflectUtil.invoke(user, "setName", "李四");

// 获取类上的注解
Annotation annotation = ClassUtil.getAnnotation(UserService.class, Service.class);
```

---

## 十、生产实践：通用 API 封装

```java
@Service
public class HutoolApiService {

    /**
     * 带重试的 HTTP GET
     */
    public String retryableGet(String url, int maxRetries) {
        return RetryUtil.retry(() ->
            HttpUtil.get(url, 5000),
            retryCount -> log.warn("第{}次重试", retryCount),
            maxRetries
        );
    }

    /**
     * 生成 AES 加密的 Token
     */
    public String encryptToken(Long userId) {
        AES aes = SecureUtil.aes(config.getSecretKey().getBytes());
        JSONObject obj = JSONUtil.createObj()
            .set("userId", userId)
            .set("expireTime", DateUtil.offsetHour(new Date(), 2).getTime());
        return aes.encryptHex(obj.toString());
    }

    /**
     * 分页导出 Excel
     */
    public void exportLargeExcel(HttpServletResponse response, String fileName,
                                 List<?> data, Class<?> clazz) {
        ExcelWriter writer = ExcelUtil.getWriter(true);
        writer.write(data, true);
        writer.flush(response.getOutputStream());
    }
}
```

---

## 十一、面试常见追问

**Q1：Hutool 和 Apache Commons、Guava 的关系？**

A：Hutool 的设计理念是「国人开发的最佳实践」，吸收了 Commons 和 Guava 的优点，同时补充了加密、HTTP、POI 等 Commons 不提供的功能。三者的定位有重叠但不冲突：Guava 强在集合增强，Commons 强在基础工具，Hutool 是全方位覆盖。

**Q2：Hutool 的 HttpUtil 和 RestTemplate 选哪个？**

A：简单 HTTP 请求用 Hutool（代码少、上手快）；复杂的 Restful API 调用推荐 RestTemplate/WebClient（更标准的 HTTP 语义、更丰富的媒体类型支持）。

**Q3：Hutool 会不会有兼容性问题？**

A：Hutool 5.x 系列保持向后兼容。从 4.x 到 5.x 是大的 API 重构，升级时需要注意。生产环境中建议锁定版本号。

---

## 总结

Hutool 的核心价值不在于「创造了什么新功能」，而在于「把别人写过千百遍的重复代码，封装成一行能解决的问题」。

| 场景 | 传统代码量 | Hutool 代码量 | 提升 |
|------|-----------|--------------|------|
| HTTP GET 请求 | 20+ 行 | 1 行 `HttpUtil.get()` | 20x |
| Excel 导出 | 30+ 行 | 3 行 `ExcelUtil.getWriter().write().close()` | 10x |
| AES 加密 | 15+ 行 | 2 行 `SecureUtil.aes().encryptHex()` | 7x |
| 文件读取 | 10+ 行 | 1 行 `FileUtil.readUtf8String()` | 10x |

如果你还在项目里写大段大段的 IO 流代码、手工拼接 HTTP 请求、用 SimpleDateFormat 处理日期，不妨试试 Hutool。好的工具就应该「用了就回不去」。
