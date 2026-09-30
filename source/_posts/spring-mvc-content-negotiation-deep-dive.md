---
title: 【Spring MVC 源码】内容协商（Content Negotiation）深度解析：Accept 解析、MediaType 匹配与消息转换
date: 2026-09-30 08:00:00
tags:
  - Spring MVC
  - Spring
  - 源码
  - 面试
categories:
  - Spring
  - 后端面试
author: 东哥
---

# 【Spring MVC 源码】内容协商（Content Negotiation）深度解析：Accept 解析、MediaType 匹配与消息转换

## 面试官：同一个接口，浏览器返回 HTML，Postman 返回 JSON，这是怎么做到的？

这个问题看起来简单，但能往下追很深：

- 请求头里那个 `Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8` 是怎么解析的？
- `q=0.9` 是什么意思？为什么 `*/*` 排在最后？
- 匹配到 MediaType 之后，`@ResponseBody` 的内容是怎么被序列化成对应格式的？
- 如果匹配不上，Spring 返回 406，这个 406 是哪里抛的？

这一整套机制叫**内容协商（Content Negotiation）**。它在 Spring MVC 的 `AbstractMessageConverterMethodProcessor` 里实现，是 `@ResponseBody`、`ResponseEntity`、`@RestController` 的公共底座。本文从请求头一路追到 `HttpMessageConverter`，把这条链路彻底讲透。

## 一、什么是内容协商

内容协商解决的核心问题是：**同一个资源，客户端想要不同表现形式，服务端如何选择？**

HTTP 规范里定义了两类：

| 类型 | 驱动方 | 机制 | Spring 支持 |
| --- | --- | --- | --- |
| 服务端驱动（Proactive） | 服务端看请求头决定 | `Accept` / `Accept-Language` / `Accept-Encoding` | ✅ 默认方式 |
| 客户端驱动（Reactive） | 服务端给多个 URL，客户端选 | 多个链接，客户端自己挑 | ❌ 不涉及 |

Spring MVC 用的是服务端驱动。一次典型的请求-响应：

```http
GET /api/users/1 HTTP/1.1
Host: api.example.com
Accept: application/json
Accept-Language: zh-CN,zh;q=0.9,en;q=0.8
```

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=UTF-8

{"id":1,"name":"东哥"}
```

如果换成 `Accept: application/xml`，同一个 Controller 方法返回的对象会被序列化成 XML：

```http
HTTP/1.1 200 OK
Content-Type: application/xml;charset=UTF-8

<user><id>1</id><name>东哥</name></user>
```

**Controller 代码一行没改**，变的只有响应格式——这就是内容协商的威力。

## 二、Accept 头到底怎么解析

### 2.1 q 值：媒体类型的优先级

`Accept` 的完整语法允许给每个媒体类型加权重：

```http
Accept: text/html, application/xhtml+xml, application/xml;q=0.9, image/webp;q=0.8, */*;q=0.1
```

`q`（quality factor）是 0~1 的浮点数，代表"期望程度"：

| q 值 | 含义 |
| --- | --- |
| 1（省略时默认） | 最高优先级 |
| 0.9 | 次高 |
| 0.1 | 很低但可以接受 |
| 0 | **明确拒绝** |

规则细节：

1. 不写 `q` 等价于 `q=1`；
2. `q` 最多 3 位小数（`q=0.888` 合法，`q=0.8888` 是非法但 Spring 会容错）；
3. **具体类型优先于通配符**：`text/html` 比 `text/*` 比 `*/*` 更具体，即使 q 值相同也是具体类型优先；
4. `q=0` 表示显式排斥，例如 `Accept: */*;q=1, text/html;q=0` 意思是"什么都要，就是不要 HTML"。

### 2.2 Spring 的解析入口

Spring 用 JDK 自带的 `javax.servlet.http.HttpServletRequest#getHeaders("Accept")`，然后交给 `MediaType.parseMediaTypes()`：

```java
// org.springframework.http.MediaType
public static List<MediaType> parseMediaTypes(@Nullable String mediaTypes) {
    if (!StringUtils.hasLength(mediaTypes)) {
        return Collections.emptyList();
    }
    String[] tokens = StringUtils.tokenizeToStringArray(mediaTypes, ",");
    List<MediaType> result = new ArrayList<>(tokens.length);
    for (String token : tokens) {
        result.add(parseMediaType(token));
    }
    return result;
}
```

解析出来之后，关键一步是排序：

```java
// MediaType.sortBySpecificityAndQuality(list)
// 排序规则（从高到低）：
//   1. 更具体的类型优先（text/html > text/* > */*）
//   2. q 值大的优先
//   3. 通配符数量少的优先
```

`MediaType` 内部用一套 `MimeType.SpecificityComparator` 实现，核心是这两个字段：

```java
private final String type;        // "text"
private final String subtype;     // "html" 或 "*"
private final Map<String, String> parameters;  // charset, q 等
private final double qualityValue;              // q 值
```

### 2.3 一个真实解析示例

```java
// 输入
String accept = "text/*;q=0.3, text/html;q=0.7, text/html;level=1, "
              + "text/html;level=2;q=0.4, */*;q=0.5";

List<MediaType> types = MediaType.parseMediaTypes(accept);
MediaType.sortBySpecificityAndQuality(types);
types.forEach(System.out::println);
```

输出（按优先级从高到低）：

```text
text/html;level=1                    // q=1，且带参数最具体
text/html;q=0.7                      // q=0.7
*/*;q=0.5                            // q=0.5，通配符
text/html;level=2;q=0.4              // q=0.4
text/*;q=0.3                         // q=0.3，含通配符
```

注意 `text/html;level=1` 排在第一：它 q=1 且参数更多（更具体）；`text/*;q=0.3` 排最后：它是通配符且 q 最低。

## 三、内容协商的完整决策链

### 3.1 决策流程图

```text
请求进入 RequestMappingHandlerAdapter
        │
        ▼
HandlerMethodReturnValueHandlerComposite
        │  选中 RequestResponseBodyMethodProcessor
        ▼
AbstractMessageConverterMethodProcessor.writeWithMessageConverters()
        │
        ├─ 1. 计算可产出的 MediaType 列表 (producible)
        │      ├─ 来自 @RequestMapping(produces=...)
        │      ├─ 来自 @RestController 的默认值（无 produces 时 = 全部已注册的）
        │      └─ 若返回 String，还有 StringHttpMessageConverter 的 text/plain
        │
        ├─ 2. 确定目标 MediaType (selectedMediaType)
        │      ├─ 有 Accept → 与 producible 做匹配协商
        │      ├─ 无 Accept → 用默认策略（defaultContentType / PathExtension / Parameter）
        │      └─ 匹配不上 → 抛 HttpMediaTypeNotAcceptableException → 406
        │
        ├─ 3. 遍历所有 HttpMessageConverter
        │      └─ converter.canWrite(returnType, selectedMediaType)
        │
        └─ 4. 找到第一个能写的 converter → 写入响应
```

### 3.2 源码：`writeWithMessageConverters`

这是整条链路的灵魂，精简后如下：

```java
protected <T> void writeWithMessageConverters(
        @Nullable T value, MethodParameter returnType,
        ServletServerHttpRequest inputMessage,
        ServletServerHttpResponse outputMessage) throws IOException {

    // 1. 拿到响应体类型和泛型
    Class<?> valueType = getReturnValueType(value, returnType);
    Type genericType = returnType.getGenericParameterType();

    // 2. 计算可产出的 MediaType（关键：来自 @RequestMapping 的 produces）
    List<MediaType> acceptableTypes;
    try {
        acceptableTypes = getAcceptableMediaTypes(inputMessage.getServletRequest());
    } catch (HttpMediaTypeNotAcceptableException ex) {
        // ... 处理 Accept 解析异常
    }
    List<MediaType> producibleTypes = getProducibleMediaTypes(
            inputMessage.getServletRequest(), valueType, genericType);

    // 3. 协商：acceptableTypes ∩ producibleTypes，按质量排序
    List<MediaType> mediaTypesToUse = new ArrayList<>();
    for (MediaType accepted : acceptableTypes) {
        for (MediaType producible : producibleTypes) {
            if (accepted.isCompatibleWith(producible)) {
                mediaTypesToUse.add(getMostSpecificMediaType(accepted, producible));
            }
        }
    }
    if (mediaTypesToUse.isEmpty()) {
        // produces 与 Accept 完全不兼容
        throw new HttpMediaTypeNotAcceptableException(producibleTypes);
    }
    MediaType.sortBySpecificityAndQuality(mediaTypesToUse);

    // 4. 按优先级遍历，找第一个能写的 converter
    MediaType selectedMediaType = null;
    for (MediaType mediaType : mediaTypesToUse) {
        if (mediaType.isConcrete()) {
            selectedMediaType = mediaType;
            break;
        } else if (mediaType.isPresentIn(MediaType.ALL) || ...) {
            // 通配符 -> 用 converter 支持的默认类型
            selectedMediaType = MediaType.APPLICATION_OCTET_STREAM;
            break;
        }
    }

    // 5. 逐个 converter 尝试
    for (HttpMessageConverter<?> converter : this.messageConverters) {
        GenericHttpMessageConverter genericConverter = ...;
        if (genericConverter.canWrite(targetType, valueType, selectedMediaType)) {
            // 内容协商的另一半：决定 Content-Type
            outputMessage.getHeaders().setContentType(selectedMediaType);
            genericConverter.write(body, targetType, selectedMediaType, outputMessage);
            return;
        }
    }
    // 全部失败 -> 406 或 500
    if (selectedMediaType != null) {
        throw new HttpMediaTypeNotAcceptableException(
                getSupportedMediaTypes().toArray(new MediaType[0]));
    }
    logger.debug("No converter found for return value of type: " + valueType);
    throw new HttpMessageNotWritableException(...);
}
```

几个容易忽略的点：

1. **`producibleTypes` 是"能产出"的集合**，来源是 `@RequestMapping(produces=...)` 或所有 converter 支持的类型的并集；
2. **`getMostSpecificMediaType`** 会取交集里更具体的那个（比如 `text/html` 与 `text/*` 取 `text/html`）；
3. **`MediaType.sortBySpecificityAndQuality` 的排序决定了 conent-type 的最终结果**，如果你写了 `@GetMapping(produces={"application/json","application/xml"})` 而 Accept 是 `*/*`，第一个（json）会赢；
4. 最后遍历 converter 的顺序就是 **`RequestMappingHandlerAdapter.messageConverters` 的注册顺序**。

## 四、三种内容协商策略

Spring 允许你配置"没有 Accept 头时怎么办"。策略接口是 `ContentNegotiationStrategy`，实现在 `ContentNegotiationManager` 中。

### 4.1 HeaderContentNegotiationStrategy（默认，最常用）

只看 `Accept` 头。没有 Accept 就返回 `*/*`。

### 4.2 ParameterContentNegotiationStrategy

通过 URL 参数指定，例如 `/api/users/1?format=json`：

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void configureContentNegotiation(ContentNegotiationConfigurer configurer) {
        configurer
            .parameterName("format")            // ?format=json
            .favorParameter(true)               // 开启参数策略
            .ignoreAcceptHeader(false)          // Accept 仍然参与
            .defaultContentType(MediaType.APPLICATION_JSON)
            .mediaType("json", MediaType.APPLICATION_JSON)
            .mediaType("xml", MediaType.APPLICATION_XML)
            .mediaType("html", MediaType.TEXT_HTML);
    }
}
```

### 4.3 PathExtensionContentNegotiationStrategy（路径后缀）

`/api/users/1.json`、`/api/users/1.xml`。

⚠️ **Spring Boot 2.6+ 默认关闭路径后缀匹配**（`useSuffixPatternMatch=false`），原因是历史漏洞（绕过安全规则、`/user.json` 与 `/user` 走不同逻辑）。要恢复必须显式开启，但**不建议**：

```properties
# 不推荐，仅用于兼容老系统
spring.mvc.contentnegotiation.favor-path-extension=true
spring.mvc.pathmatch.use-suffix-pattern=true
```

### 4.4 优先级关系

当多个策略同时开启时，`ContentNegotiationManager` 内部按顺序询问，**先返回非 null 的胜出**。默认顺序是：

```text
PathExtension > Parameter > Header
```

可以通过构造函数自定义顺序：

```java
ContentNegotiationManager manager = new ContentNegotiationManager(
    new HeaderContentNegotiationStrategy(),
    new ParameterContentNegotiationStrategy(Map.of("format", MediaType.APPLICATION_JSON))
);
```

**生产建议：只用 Header 策略 + 显式 `produces`。** 参数策略容易和业务参数冲突（用户参数叫 `format` 就完蛋），路径后缀策略有安全风险且和 RESTful 风格相悖。

## 五、HttpMessageConverter 的匹配与注册

内容协商只决定"要什么格式"，真正"怎么序列化"由 `HttpMessageConverter` 负责。

### 5.1 默认注册的 Converter（Spring Boot 中）

| 顺序 | Converter | 支持的类型 | 说明 |
| --- | --- | --- | --- |
| 1 | `ByteArrayHttpMessageConverter` | `byte[]` | `application/octet-stream`, `*/*` |
| 2 | `StringHttpMessageConverter` | `String` | `text/plain`, `*/*` |
| 3 | `ResourceHttpMessageConverter` | `Resource` | `*/*` |
| 4 | `ResourceRegionHttpMessageConverter` | `ResourceRegion` | 支持断点续传 |
| 5 | `AllEncompassingFormHttpMessageConverter` | `MultiValueMap` | `application/x-www-form-urlencoded`, `multipart/form-data` |
| 6 | `MappingJackson2HttpMessageConverter` | 任意对象 | `application/json` |
| 7 | `MappingJackson2XmlHttpMessageConverter` | 任意对象 | `application/xml`（需 jackson-dataformat-xml） |
| 8 | `Jaxb2RootElementHttpMessageConverter` | 带 JAXB 注解的对象 | `application/xml` |
| 9 | `ProtobufHttpMessageConverter` | `Message` | `application/x-protobuf` |
| 10 | `KotlinSerializationJsonHttpMessageConverter` | 任意对象 | `application/json`（Kotlin 项目） |

**注意第 2 个 `StringHttpMessageConverter`**：它的 `supportedMediaTypes` 里包含 `*/*`，所以任何返回 `String` 的接口，即使你写了 `produces=application/json`，它也可能"抢"到写入权，导致返回的 JSON 字符串被原样输出成 `text/plain` 或带引号。这是 **String 返回值最容易踩的坑**，详见第六节。

### 5.2 自定义 Converter 的注册与顺序

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {

    @Override
    public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
        // 注意：这里能修改已有的 converter 列表（推荐）
        // convertMessageConverters 则是覆盖全部（危险）
        for (HttpMessageConverter<?> converter : converters) {
            if (converter instanceof MappingJackson2HttpMessageConverter jackson) {
                ObjectMapper mapper = jackson.getObjectMapper();
                mapper.setSerializationInclusion(JsonInclude.Include.NON_NULL);
                mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
                mapper.registerModule(new JavaTimeModule());
                mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
            }
        }
    }

    @Override
    public void configureMessageConverters(List<HttpMessageConverter<?>> converters) {
        // 这个方法是"完全替换"，一旦实现，Spring Boot 的默认 converter 全部失效！
        // 除非你明确知道自己要什么，否则用 extendMessageConverters
    }
}
```

**踩坑提示**：`configureMessageConverters` 与 `extendMessageConverters` 的区别是经典面试题：

- `configureMessageConverters`：**替换**默认列表，且**只有在你不调用 `super`/不添加默认时才会跳过 Boot 的自动配置**。如果直接 `converters.add(...)` 而不加默认的，Jackson 就没了，接口全变 406；
- `extendMessageConverters`：在 Boot 装配完成之后调用，**追加/修改**，安全得多。

### 5.3 自定义一个 Converter

需求：让某个自定义类型以 `application/x-custom` 输出。

```java
public class CustomMessageConverter extends AbstractHttpMessageConverter<CustomDTO> {

    public CustomMessageConverter() {
        // 声明支持的 MediaType
        super(new MediaType("application", "x-custom", StandardCharsets.UTF_8));
    }

    @Override
    protected boolean supports(Class<?> clazz) {
        return CustomDTO.class.isAssignableFrom(clazz);
    }

    @Override
    protected CustomDTO readInternal(Class<? extends CustomDTO> clazz, HttpInputMessage inputMessage)
            throws IOException {
        return new CustomDTO(new String(inputMessage.getBody().readAllBytes(), StandardCharsets.UTF_8));
    }

    @Override
    protected void writeInternal(CustomDTO dto, HttpOutputMessage outputMessage) throws IOException {
        outputMessage.getBody().write(dto.serialize().getBytes(StandardCharsets.UTF_8));
    }
}
```

注册时**要插到前面**，否则 Jackson 会先抢走：

```java
@Override
public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
    converters.add(0, new CustomMessageConverter());   // 插到最前面
}
```

## 六、实战踩坑清单

### 6.1 返回 String 时 produces 不生效

```java
@RestController
public class DemoController {

    // 期望返回 JSON，实际返回 text/plain
    @GetMapping(value = "/demo", produces = MediaType.APPLICATION_JSON_VALUE)
    public String demo() {
        return "{\"ok\":true}";
    }
}
```

服务端响应头实际是 `Content-Type: text/plain;charset=UTF-8`？

**原因**：`StringHttpMessageConverter` 在列表里排在 `MappingJackson2HttpMessageConverter` **前面**，且它支持 `*/*`。协商结果是 `application/json`，但 `canWrite(String.class, application/json)` 对 `StringHttpMessageConverter` 返回 true（因为它支持所有类型 + 它的 `supportedMediaTypes` 含 `*/*`），于是它先写。

**要让 `produces=application/json` 生效**，正确做法是返回对象而不是字符串：

```java
@GetMapping(value = "/demo", produces = MediaType.APPLICATION_JSON_VALUE)
public Map<String, Object> demo() {
    return Map.of("ok", true);   // 交给 Jackson
}
```

或者显式修改 String converter 支持的媒体类型：

```java
@Override
public void extendMessageConverters(List<HttpMessageConverter<?>> converters) {
    converters.stream()
        .filter(c -> c instanceof StringHttpMessageConverter)
        .map(c -> (StringHttpMessageConverter) c)
        .forEach(c -> c.setSupportedMediaTypes(List.of(MediaType.TEXT_PLAIN)));
}
```

### 6.2 XML 依赖缺失导致 406

`Accept: application/xml` 时返回 406，通常是忘了加依赖：

```xml
<dependency>
    <groupId>com.fasterxml.jackson.dataformat</groupId>
    <artifactId>jackson-dataformat-xml</artifactId>
</dependency>
```

### 6.3 `charset` 与 `Content-Type` 不一致

Spring 5.2+ 默认不再给 `application/json` 加 `charset=UTF-8`（因为 JSON 规范规定 UTF-8，加了反而冗余）。如果下游系统强依赖响应头里的 charset，需要显式指定：

```java
@GetMapping(value = "/demo", produces = "application/json;charset=UTF-8")
```

### 6.4 406 排查三步

```java
// 1. 打印服务端能产出的类型
// 在 writeWithMessageConverters 里断点，或临时加日志
@GetMapping(value = "/debug", produces = {MediaType.APPLICATION_JSON_VALUE})
public List<MediaType> debug(HttpServletRequest req) {
    // 观察实际协商结果
    return MediaType.parseMediaTypes(req.getHeader("Accept"));
}
```

排查思路：

| 现象 | 原因 |
| --- | --- |
| 406 | `Accept` 与 `produces`（或已注册 converter）完全不兼容 |
| 405 | 方法不匹配（GET/POST） |
| 415 | 请求体 `Content-Type` 没有对应的 converter 能读 |
| 500 `HttpMessageNotWritableException` | 选了 MediaType 但没有 converter 能写（GBK 编码等） |

**注意 406 与 415 的区别**：406 是"你要的格式我给不了"（响应侧），415 是"你给的格式我读不了"（请求侧）。

## 七、面试常见追问

**Q1：`Accept: */*` 时 Spring 怎么定 Content-Type？**

协商结果里 `*/*` 与 `producibleTypes` 的每个类型都兼容，`getMostSpecificMediaType` 会取 producible 里那个更具体的。如果 `produces` 没写，则用 `MediaType.sortBySpecificityAndQuality` 排序后的第一个，实际结果取决于 converter 注册顺序——所以**不要依赖 `*/*` 的默认行为，显式写 produces 才是正道**。

**Q2：`produces` 和 `converters` 谁先决定结果？**

先由 `produces` 与 `Accept` 协商出 `selectedMediaType`，再由 converter 的 `canWrite` 判断能否写。**如果 `produces` 里的类型没有任何 converter 支持，一样会 406**（或者 500）。两者必须同时满足。

**Q3：内容协商发生在哪个阶段？返回值处理之前还是之后？**

在返回值处理阶段，具体是 `AbstractMessageConverterMethodProcessor#writeWithMessageConverters`。前置阶段（`HandlerMethodArgumentResolver`）里也有对应逻辑，那是**读请求体**时的协商（`readWithMessageConverters`，对应 415）。

**Q4：`@RestController` 和 `@Controller` + `@ResponseBody` 在内容协商上有区别吗？**

没有。`@RestController` 只是 `@Controller` + `@ResponseBody` 的组合注解，最终都走 `RequestResponseBodyMethodProcessor`。

**Q5：怎么实现"根据客户端类型返回不同结构"？**

三种方式：

1. 多个 `produces` + 同一个方法返回不同对象（不优雅）；
2. 写多个方法，用 `produces` 区分（推荐）：

```java
@GetMapping(value = "/users/{id}", produces = MediaType.APPLICATION_JSON_VALUE)
public UserJson getUserJson(@PathVariable Long id) { ... }

@GetMapping(value = "/users/{id}", produces = MediaType.APPLICATION_XML_VALUE)
public UserXml getUserXml(@PathVariable Long id) { ... }
```

3. 用 `ResponseEntity` + `ContentNegotiationManager` 手动决定（最灵活）。

**Q6：`Accept` 头解析会不会有性能问题？**

会。`MediaType.parseMediaTypes` + `sortBySpecificityAndQuality` 每次请求都会执行，且用了正则。**高频接口建议：**

- 显式写 `produces`，避免遍历所有 converter；
- 避免在 `Accept` 里塞几十个类型（客户端行为）；
- 网关层做 `Accept` 规范化和缓存。

## 八、一图总结

```text
                    ┌───────────────────────────┐
  Accept: ...   ───▶│ ContentNegotiationManager │
                    │  Header / Param / PathExt  │
                    └─────────────┬─────────────┘
                                  │  List<MediaType>
                                  ▼
  @RequestMapping(produces) ──▶ getProducibleMediaTypes()
                                  │
                                  ▼
                        协商 = 交集 + 排序（specificity, q）
                                  │
                        ┌─────────┴─────────┐
                        │  selectedMediaType │
                        └─────────┬─────────┘
                                  ▼
                 遍历 messageConverters，canWrite() 命中
                                  │
                                  ▼
                        converter.write() → 响应体
```

**三句话记住这套机制：**

1. `Accept` 的 `q` 值决定优先级，具体类型优先于通配符；
2. `produces` 与 `Accept` 取交集并按具体度/质量排序，选不中就是 406；
3. 选中 MediaType 后，由注册顺序里的第一个 `canWrite` 成功的 `HttpMessageConverter` 完成序列化——**顺序即优先级**，这是所有"produces 不生效"问题的根因。
