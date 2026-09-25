---
title: 【Spring MVC 源码】返回值处理机制深度解析：HandlerMethodReturnValueHandler 与 HttpMessageConverter
date: 2026-09-25 08:00:00
tags:
  - Spring
  - Spring MVC
  - 源码
  - 面试
categories:
  - Spring
  - Spring源码
author: 东哥
---

# 【Spring MVC 源码】返回值处理机制深度解析：HandlerMethodReturnValueHandler 与 HttpMessageConverter

## 面试官：@ResponseBody 是怎么把对象变成 JSON 的？

「你说说，一个 `@RestController` 的方法 return 一个 `User` 对象，Spring MVC 是怎么把它变成 JSON 写到响应里的？」

很多人的回答停留在「`@ResponseBody` 会走 Jackson」。但面试官接着问：

- `return "index"` 为什么是跳转视图，而 `@ResponseBody` 下的 `"index"` 却是纯文本？
- `return Callable<User>`、`DeferredResult<User>`、`ResponseBodyEmitter` 是怎么处理的？
- 同一个返回值，为什么 `produces`、`Accept` 不同会拿到 JSON 或 XML？
- 自定义 `HandlerMethodReturnValueHandler` 会影响哪些返回值？

要回答这些问题，得把 **`HandlerMethodReturnValueHandler` 这条链**讲清楚。它是 `HandlerMethodArgumentResolver`（参数解析）的对称组件，也是 Spring MVC 面试从「会用」进阶到「懂原理」的分水岭。

## 一、入口：DispatcherServlet 的 handleReturnValue

请求处理完成后，`RequestMappingHandlerAdapter#invokeHandlerMethod` 里拿到了 `ModelAndViewContainer` 与 `ServletInvocableHandlerMethod`。真正的返回处理是：

```java
// ServletInvocableHandlerMethod#invokeAndHandle
Object returnValue = invokeForRequest(webRequest, mavContainer, providedArgs);
setResponseStatus(webRequest);

if (returnValue == null) {
    // 204 / 已处理完（如 @ResponseBody 返回 null 且已提交）
    if (isRequestNotModified(webRequest) || getResponseStatus() != null
            || mavContainer.isRequestHandled()) {
        disableContentCachingIfNecessary(webRequest);
        mavContainer.setRequestHandled(true);
        return;
    }
}
else if (StringUtils.hasText(getResponseStatusReason())) {
    mavContainer.setRequestHandled(true);
    return;
}

mavContainer.setRequestHandled(false);
Assert.state(this.returnValueHandlers != null, "No return value handlers");
try {
    this.returnValueHandlers.handleReturnValue(
            returnValue, getReturnValueType(returnValue), mavContainer, webRequest);
}
```

关键点：
- `mavContainer.isRequestHandled()` 是「响应是否已被完全写完」的标记。`@ResponseBody`、`ResponseEntity`、`StreamingResponseBody` 这类处理器处理完会把请求标记为 handled，后续不再走视图渲染。
- 返回值是 `null` 且未被处理时，不会报错，而是走「无返回值」分支（可能由视图解析器选默认视图，或直接 200 空响应）。

## 二、HandlerMethodReturnValueHandler 体系

接口只有两个方法：

```java
public interface HandlerMethodReturnValueHandler {
    boolean supportsReturnType(MethodParameter returnType);
    void handleReturnValue(Object returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest) throws Exception;
}
```

由于一个返回值可能被多个处理器「可能支持」，Spring 用组合器 **`HandlerMethodReturnValueHandlerComposite`** 按顺序挑选：**第一个 `supportsReturnType` 返回 true 的处理器胜出**——与参数解析器完全一致的选择语义。

这意味着**注册顺序决定一切**。`WebMvcConfigurationSupport#addDefaultReturnValueHandlers` 给出一批默认处理器，注意顺序：

| 顺序 | 处理器 | 支持的返回值 |
| --- | --- | --- |
| 1 | `ModelAndViewMethodReturnValueHandler` | `ModelAndView` |
| 2 | `ModelMethodProcessor` | `Model` |
| 3 | `ViewMethodReturnValueHandler` | `View` |
| 4 | `ResponseBodyEmitterReturnValueHandler` | `ResponseBodyEmitter` / SSE（`SseEmitter`） |
| 5 | `StreamingResponseBodyReturnValueHandler` | `StreamingResponseBody` |
| 6 | `HttpEntityMethodProcessor` | `HttpEntity` / `ResponseEntity` |
| 7 | `HttpHeadersReturnValueHandler` | `HttpHeaders` |
| 8 | `CallableMethodReturnValueHandler` | `Callable` |
| 9 | `DeferredResultMethodReturnValueHandler` | `DeferredResult` / `ListenableFuture` / `CompletionStage` |
| 10 | `AsyncTaskMethodReturnValueHandler` | `WebAsyncTask` |
| 11 | `ServletModelAttributeMethodProcessor`（annotationNotRequired=false） | 带 `@ModelAttribute` |
| 12 | `RequestResponseBodyMethodProcessor` | `@ResponseBody` 标记 |
| 13 | `ViewNameMethodReturnValueHandler` | `String` / `void`（视图名） |
| 14 | `MapMethodProcessor` | `Map`（作为模型） |
| 15 | `ServletModelAttributeMethodProcessor`（annotationNotRequired=true） | 任意非简单类型（兜底） |

**面试高频考点就在顺序上**：
- 为什么 `String` 返回值默认当视图名？因为 `ViewNameMethodReturnValueHandler` 会接管 `String`——但前提是方法**没有** `@ResponseBody`，因为 `RequestResponseBodyMethodProcessor`（12）排在它（13）前面，且它的 `supportsReturnType` 检查 `@ResponseBody` 注解。
- 所以「`@ResponseBody` + `String`」= 纯文本，而「无 `@ResponseBody` + `String`」= 视图名。顺序与注解检查共同决定了行为。
- `Map` 返回值被 `MapMethodProcessor` 当作模型数据（不是响应体），要输出 JSON 必须加 `@ResponseBody`。

## 三、核心：RequestResponseBodyMethodProcessor

`@ResponseBody` 的处理器继承自 `AbstractMessageConverterMethodProcessor`，核心是 `writeWithMessageConverters`：

```java
protected <T> void writeWithMessageConverters(T value, MethodParameter returnType,
        ServletServerHttpRequest inputMessage, ServletServerHttpResponse outputMessage) {

    Object body;
    Class<?> valueType;
    Type targetType;
    // 1. 处理 CharSequence / byte[] 等特例
    if (value instanceof CharSequence) {
        body = value.toString();
        valueType = String.class;
        targetType = String.class;
    } else {
        body = value;
        valueType = getReturnValueType(body, returnType);
        targetType = GenericTypeResolver.resolveType(getGenericType(returnType), returnType.getContainingClass());
    }

    // 2. 内容协商：结合 produces、Accept、可用的 MediaType
    MediaType selectedMediaType = null;
    MediaType contentType = outputMessage.getHeaders().getContentType();
    boolean isContentTypePreset = contentType != null && contentType.isConcrete();
    if (isContentTypePreset) {
        selectedMediaType = contentType;
    } else {
        // 取出所有 HttpMessageConverter 能写的 MediaType
        // 与 produces、Accept 求交集，选最优
        selectedMediaType = resolveSelectedMediaType(...);
    }

    // 3. 找到能写该类型的 converter 并写出
    if (selectedMediaType != null) {
        for (HttpMessageConverter<?> converter : this.messageConverters) {
            if (converter.canWrite(valueType, selectedMediaType)) {
                body = getAdvice().beforeBodyWrite(body, returnType, selectedMediaType,
                        converter.getClass(), inputMessage, outputMessage);
                if (body != null) {
                    converter.write(body, selectedMediaType, outputMessage);
                }
                return;
            }
        }
    }
    // 没有可用 converter → HttpMediaTypeNotAcceptableException
}
```

这段代码信息量很大：

1. **`CharSequence` 特例**：`String` 返回值会先转成 `String`，因此**默认由 `StringHttpMessageConverter` 写出**。如果你在 `produces` 里写了 `application/json` 且返回 `String`，会走 `MappingJackson2HttpMessageConverter`（因为你显式指定了），得到带引号的 JSON 字符串。
2. **内容协商**：核心是「客户端 `Accept` ∩ 服务端 `produces` ∩ converter 能力」取最优。这解释了「同一个接口在浏览器和 Postman 里拿到不同格式」的现象。
3. **`beforeBodyWrite`**：这是 **`ResponseBodyAdvice`** 的钩子——全局统一响应体包装、脱敏、加密就挂在这里。

### 3.1 内容协商详解

三个输入：

| 来源 | 说明 |
| --- | --- |
| `Accept` 请求头 | 客户端想要的格式，带 q 权重，如 `Accept: application/json;q=0.9,text/html;q=0.8` |
| `produces` | 映射注解显式声明，如 `@GetMapping(produces = "application/json")` |
| `HttpMessageConverter` | 实际能写的类型，由 `MappingJackson2HttpMessageConverter`、`StringHttpMessageConverter`、`Jaxb2RootElementHttpMessageConverter` 等提供 |

策略由 `ContentNegotiationManager` 决策，可基于「路径扩展名 / `format` 参数 / `Accept` 头」。Spring Boot 2.6 之后**默认关闭了基于扩展名的协商**（`useRegisteredExtensionsOnly` 相关默认变更），这点常被问。

### 3.2 常见的 HttpMessageConverter

| Converter | 读写类型 |
| --- | --- |
| `ByteArrayHttpMessageConverter` | `byte[]` ↔ `application/octet-stream` |
| `StringHttpMessageConverter` | `String` ↔ `text/plain`（默认 `*/*`） |
| `ResourceHttpMessageConverter` | `Resource` ↔ 流 |
| `MappingJackson2HttpMessageConverter` | 对象 ↔ `application/json` |
| `MappingJackson2XmlHttpMessageConverter` | 对象 ↔ `application/xml`（需 Jackson XML 依赖） |
| `FormHttpMessageConverter` | `MultiValueMap` ↔ 表单 |
| `ProtobufHttpMessageConverter` | Protobuf |

## 四、其他重要返回值的处理

### 4.1 ResponseEntity / HttpEntity

`HttpEntityMethodProcessor` 支持 `HttpEntity`（含 `ResponseEntity`）。它先设置状态码与响应头，再复用 `writeWithMessageConverters` 写出 body —**这也是它和 `@ResponseBody` 共享同一套内容协商的原因**（两者都继承 `AbstractMessageConverterMethodProcessor`）。

### 4.2 Callable / DeferredResult / CompletionStage

`CallableMethodReturnValueHandler` / `DeferredResultMethodReturnValueHandler` 不会立刻写响应，而是把结果交给 `WebAsyncManager` 启动异步处理：

1. 请求线程立刻释放，Servlet 容器线程不会被长时间占用；
2. 异步结果回来（`Callable` 由 `AsyncTaskExecutor` 执行；`DeferredResult` 由业务在其他线程 `setResult`）后，再次进入 `invokeAndHandle`，用原返回值类型重新选择处理器写出。

**面试追问：为什么 `Callable` 能提高吞吐？**
因为 Servlet 3.0 异步支持让请求线程得以释放，避免线程池被慢逻辑（如 RPC/DB）耗尽。但注意：`Callable` 默认在 `SimpleAsyncTaskExecutor`（Spring Boot 会配 `applicationTaskExecutor`）执行，仍需要合理线程池；`DeferredResult` 更适合「等待外部事件」的场景（如消息回调驱动）。

### 4.3 ResponseBodyEmitter / SseEmitter / StreamingResponseBody

- `ResponseBodyEmitterReturnValueHandler`：处理 `ResponseBodyEmitter`（`SseEmitter` 是其子类），支持多次 `send`、超时、完成回调，是 SSE 的实现基础。
- `StreamingResponseBodyReturnValueHandler`：处理 `StreamingResponseBody`，直接把 `OutputStream` 给业务，适合大文件流式下载（不缓冲整个响应）。

### 4.4 null、void、String、Map

- `void` / `null`：一般是 `ViewNameMethodReturnValueHandler` 处理——视图名由请求路径推导（`RequestToViewNameTranslator`）。
- `String`：视图名或纯文本（看 `@ResponseBody`）。
- `Map` / `Model`：作为模型数据交给视图渲染。

## 五、实战：全局统一响应体

最常见需求：所有接口返回 `{"code":0,"msg":"ok","data":...}`。用 `ResponseBodyAdvice` 优雅实现：

```java
@RestControllerAdvice
public class GlobalResponseAdvice implements ResponseBodyAdvice<Object> {

    @Override
    public boolean supports(MethodParameter returnType, Class<? extends HttpMessageConverter<?>> converterType) {
        // 只在 JSON 转换时包装；跳过已经包过的类型、文件流、@IgnoreWrap 注解
        return MappingJackson2HttpMessageConverter.class.isAssignableFrom(converterType)
                && !returnType.hasMethodAnnotation(IgnoreWrap.class)
                && !Resource.class.isAssignableFrom(returnType.getParameterType());
    }

    @Override
    public Object beforeBodyWrite(Object body, MethodParameter returnType, MediaType selectedContentType,
            Class<? extends HttpMessageConverter<?>> selectedConverterType,
            ServerHttpRequest request, ServerHttpResponse response) {
        if (body instanceof Result) return body;
        return Result.ok(body);
    }
}
```

**坑点**：如果接口返回 `String` 类型，`StringHttpMessageConverter` 不在 `supports` 范围内（上面已排除），否则把 `Result` 交给 `StringHttpMessageConverter` 会直接 `ClassCastException`。这就是「String 返回值 + 全局包装」的经典事故。

## 六、自定义 HandlerMethodReturnValueHandler

场景：让 `byte[]` 直接以 Base64 输出，或实现一个 `@CsvBody` 注解。步骤：

```java
public class CsvReturnValueHandler implements HandlerMethodReturnValueHandler {
    @Override
    public boolean supportsReturnType(MethodParameter returnType) {
        return returnType.hasMethodAnnotation(CsvBody.class);
    }

    @Override
    public void handleReturnValue(Object returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest) throws Exception {
        mavContainer.setRequestHandled(true);          // 标记已处理，跳过视图渲染
        HttpServletResponse response = webRequest.getNativeResponse(HttpServletResponse.class);
        response.setContentType("text/csv;charset=UTF-8");
        // ... 序列化 returnValue 为 CSV 并写出
    }
}
```

注册（**放在合适的位置**，通常插到 `RequestResponseBodyMethodProcessor` 之前）：

```java
@Configuration
public class WebConfig implements WebMvcConfigurer {
    @Override
    public void addReturnValueHandlers(List<HandlerMethodReturnValueHandler> handlers) {
        handlers.add(0, new CsvReturnValueHandler());  // 优先匹配
    }
}
```

> 注意：自定义处理器被 `supportsReturnType` 命中的优先级由注册位置决定；不要无脑 `add(0, ...)`，否则可能抢走 `ModelAndView` 等内置能力。

## 七、面试追问合集

**Q1：`@ResponseBody` 和 `@RestController` 的关系？**
`@RestController = @Controller + @ResponseBody`，作用在类上等价于给所有方法加 `@ResponseBody`，于是它们的返回值都交给 `RequestResponseBodyMethodProcessor`。

**Q2：为什么返回 `String` 时中文乱码，返回对象却不乱码？**
`StringHttpMessageConverter` 的默认字符集在 Spring 5.2 之前是 ISO-8859-1（Spring Boot 2.x 已改为 UTF-8，并可通过 `spring.http.encoding`/`server.servlet.encoding.charset` 控制）。对象走 JSON 时 Jackson 默认输出 UTF-8，所以不受影响。

**Q3：`ResponseEntity` 和 `@ResponseBody` 的底层是同一套吗？**
是。都继承 `AbstractMessageConverterMethodProcessor`，共用 `writeWithMessageConverters` 与同一批 `HttpMessageConverter`；区别只是 `ResponseEntity` 额外携带状态码和响应头。

**Q4：`ResponseBodyAdvice` 为什么对 `String` 返回值会抛异常？**
`beforeBodyWrite` 返回值会交给「由 `selectedConverterType` 选中的 converter」。若 `String` 由 `StringHttpMessageConverter` 写出，而你把返回值换成了 `Result` 对象，转换器就会 `ClassCastException`。要么在 `supports` 排除，要么让包装后的类型仍由 JSON converter 写出。

**Q5：异步返回值和普通返回值在处理器链上有何区别？**
异步的处理器负责「启动异步」，结果回来时会**再次进入** `invokeAndHandle`，按原 `MethodParameter` 重新选择处理器并写出；`ResponseBodyEmitter` 则是请求保持打开、多次写出。

## 八、总结

- Spring MVC 返回处理由 `HandlerMethodReturnValueHandler` 链负责，**按注册顺序第一个 `supportsReturnType` 命中者胜出**——顺序即优先级，也是「String 当视图名还是纯文本」的答案。
- `@ResponseBody` / `ResponseEntity` 共享 `AbstractMessageConverterMethodProcessor`，核心是**内容协商 + `HttpMessageConverter` 写出**。
- `ResponseBodyAdvice` 是全局包装/脱敏的正确入口，但要注意 `String` 返回值与转换器类型的坑。
- 异步（`Callable`/`DeferredResult`/`SseEmitter`/`StreamingResponseBody`）各有专用处理器，理解它们才能写出不阻塞容器线程的接口。
- 想定制，实现 `HandlerMethodReturnValueHandler` 并用 `WebMvcConfigurer#addReturnValueHandlers` 控制顺序。

下一篇继续拆 Spring MVC 的「收尾」环节：**视图解析与 `ViewResolver` 链**，以及 `ContentNegotiatingViewResolver` 是怎么在众多视图中选出那一个的。
