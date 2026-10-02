---
title: 【Java 实战】Java 网络爬虫深度实战：Jsoup、WebMagic、反爬对抗与分布式抓取架构
date: 2026-10-02 08:40:00
tags:
  - Java
  - 爬虫
  - Jsoup
  - WebMagic
categories:
  - Java
  - 实战
author: 东哥
---

# 【Java 实战】Java 网络爬虫深度实战：Jsoup、WebMagic、反爬对抗与分布式抓取架构

## 面试官：用 Java 写一个爬虫，你会怎么设计？

爬虫是 Java 工程师绕不开的一类需求：数据采集、竞品监控、内容聚合、搜索索引构建。但"能跑起来"和"生产可用"之间隔着巨大的鸿沟——动态渲染、反爬对抗、URL 去重、分布式调度、限速、容错，每一个都是坑。

这篇文章从最小可用爬虫一路讲到分布式抓取架构。

---

## 一、爬虫的基本模型

任何爬虫都可以抽象成一个循环：

```text
1. 从队列取出一个 URL
2. 下载页面（HTTP 请求）
3. 解析页面（提取数据 + 提取新 URL）
4. 保存数据
5. 把新 URL 去重后入队
6. 回到第 1 步
```

对应到工程上，就是五大组件：

| 组件 | 职责 |
| --- | --- |
| Scheduler（调度器） | 管理待抓取 URL 队列、去重 |
| Downloader（下载器） | 发起 HTTP 请求，获取页面 |
| PageProcessor（解析器） | 从页面提取数据和链接 |
| Pipeline（管道） | 数据持久化、清洗 |
| Engine（引擎) | 串联以上组件，控制并发 |

理解这个模型，用哪个框架都只是实现细节。

---

## 二、HTTP 客户端选型

### 2.1 JDK HttpClient（推荐，零依赖）

Java 11+ 自带的 `java.net.http.HttpClient` 已经非常完善，支持 HTTP/2、连接池、异步、超时：

```java
public class HttpFetcher {

    private final HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .followRedirects(HttpClient.Redirect.NORMAL)
            // 自定义线程池，控制爬虫并发
            .executor(Executors.newFixedThreadPool(16))
            .build();

    public String get(String url) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(10))
                .header("User-Agent",
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                + "(KHTML, like Gecko) Chrome/122.0 Safari/537.36")
                .header("Accept-Language", "zh-CN,zh;q=0.9")
                .GET()
                .build();

        HttpResponse<String> response =
                client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (response.statusCode() != 200) {
            throw new IllegalStateException("HTTP " + response.statusCode() + " for " + url);
        }
        return response.body();
    }
}
```

要点：

- **超时必须设置**，否则某些响应慢的站点会拖死整个线程池。
- **复用 HttpClient 实例**，它内部维护连接池；每次 new 会浪费握手开销。
- **并发要有限制**，见后面的限速章节。

### 2.2 OkHttp（生态成熟，拦截器好用）

```java
OkHttpClient client = new OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .addInterceptor(new RetryInterceptor(3))
        .addInterceptor(new RandomUaInterceptor(uaPool))
        .build();
```

OkHttp 的**拦截器**非常适合统一处理重试、UA 轮换、Cookie 管理、代理切换。

---

## 三、解析：Jsoup 的选择器威力

Jsoup 是 Java 里最好用的 HTML 解析库，提供了类似 jQuery 的 CSS 选择器 API。

### 3.1 基础用法

```java
Document doc = Jsoup.parse(html, "https://example.com");

// 1. 标题
String title = doc.title();

// 2. 按 CSS 选择器提取列表
Elements items = doc.select("div.article-list > article");
for (Element item : items) {
    String link  = item.selectFirst("a.title").absUrl("href"); // 自动补全为绝对 URL
    String text  = item.selectFirst("a.title").text();
    String time  = item.selectFirst("span.time").text();
    String desc  = item.selectFirst("p.summary").text();
    System.out.printf("%s | %s | %s%n", time, text, link);
}
```

### 3.2 常用选择器速查

| 选择器 | 含义 |
| --- | --- |
| `#id` | id 选择 |
| `.class` | class 选择 |
| `div > p` | 直接子元素 |
| `div p` | 后代元素 |
| `a[href^=https]` | 属性前缀匹配 |
| `li:eq(0)` | 第 0 个（Jsoup 用 `:eq`） |
| `li:lt(3)` | 前 3 个 |

### 3.3 处理动态渲染页面

很多现代网站的内容是 JS 渲染的，Jsoup 拿到的 HTML 里没有数据。解决方案：

**方案一：找接口**。打开 DevTools 的 Network 面板，通常能发现返回 JSON 的 XHR 接口。直接请求接口比解析 HTML 稳定得多：

```java
// 直接调 API，返回 JSON
String json = get("https://api.example.com/list?page=1&size=20");
```

**方案二：浏览器自动化**。用 Selenium 或 Playwright 驱动真实浏览器：

```java
try (Playwright playwright = Playwright.create()) {
    Browser browser = playwright.chromium().launch();
    Page page = browser.newPage();
    page.navigate("https://example.com/list");
    page.waitForSelector("div.article-item");   // 等待 JS 渲染完成
    String html = page.content();
    Document doc = Jsoup.parse(html);
}
```

浏览器自动化成本高（内存、CPU），只对必要页面使用，能调接口就调接口。

---

## 四、WebMagic：一站式爬虫框架

如果要快速搭一个成品爬虫，WebMagic 是最流行的选择。它的设计几乎完全对应前面说的五大组件。

### 4.1 核心概念

```java
public class MyProcessor implements PageProcessor {

    // 1. 页面解析 + 新链接发现
    @Override
    public void process(Page page) {
        // 提取数据
        page.putField("title", page.getHtml().css("h1.title").get());
        page.putField("author", page.getHtml().xpath("//span[@class='author']/text()").get());

        // 提取并加入待抓取队列
        page.addTargetRequests(
                page.getHtml().css("a.next").links().all());
    }

    private Site site = Site.me()
            .setRetryTimes(3)
            .setSleepTime(1000)                 // 每次请求间隔 1s，礼貌抓取
            .setTimeOut(10_000)
            .setUserAgent("Mozilla/5.0 ...");

    @Override
    public Site getSite() {
        return site;
    }
}
```

### 4.2 启动

```java
Spider.create(new MyProcessor())
        .addUrl("https://example.com/list")
        .addPipeline(new JsonFilePipeline("/data/crawl"))
        .thread(5)                    // 5 个线程并发
        .run();
```

WebMagic 内置了：

- **Scheduler**：默认用 `QueueScheduler`（内存队列），也可换成 Redis 队列实现分布式。
- **Downloader**：内置 HttpClient / OkHttp 实现，支持代理、Cookie。
- **Pipeline**：控制台、文件、JSON 输出，可自定义入库。
- **去重**：默认用 HashSet 记录已抓 URL，可换 BloomFilter。

### 4.3 三大选择器

WebMagic 同时支持三种抽取方式：

```java
// CSS 选择器
page.getHtml().css("div.content").get();

// XPath
page.getHtml().xpath("//div[@class='content']/text()").get();

// 正则
page.getHtml().regex("<title>(.*?)</title>").get();
```

再加上 `.links()`、`.all()`、`.toString()` 等链式 API，写抓取规则非常快。

---

## 五、URL 去重：从 HashSet 到布隆过滤器

爬虫最核心的问题之一是**不重复抓取**。URL 去重的空间随抓取量线性增长，1 亿个 URL 用 HashSet 要好几 GB 内存。

### 5.1 分层去重

```text
1. 本地布隆过滤器（百万级，内存几十 MB）   -> 快速否决
2. Redis Set / 布隆过滤器（全局共享）      -> 精确/分布式去重
3. 数据库唯一索引                          -> 最终兜底
```

### 5.2 布隆过滤器的取舍

| 特性 | 说明 |
| --- | --- |
| 空间 | 1 亿条、1% 误判率约需 114MB（约 9.6 bit/元素） |
| 假阳性 | 存在（可能没抓过却判断为抓过，丢数据） |
| 假阴性 | 不存在（不会漏掉已抓的） |
| 删除 | 不支持（需 Counting Bloom Filter） |

爬虫里可以接受假阳性（少抓几个页面），但不能接受假阴性（重复抓取，浪费带宽和被封风险）。所以布隆过滤器很合适。

Redis 端可以用 RedisBloom 模块：

```bash
BF.RESERVE crawl:visited 0.001 100000000
BF.ADD crawl:visited https://example.com/page/1
BF.EXISTS crawl:visited https://example.com/page/1
```

---

## 六、反爬对抗

这是爬虫里最"猫鼠游戏"的部分。常见反爬手段和应对：

### 6.1 常见反爬与应对

| 反爬手段 | 应对 |
| --- | --- |
| UA 检测 | 维护 UA 池随机轮换 |
| IP 频率限制 | 代理 IP 池 + 请求限速 |
| Cookie/Session 校验 | CookieJar 自动管理 + 登录态维护 |
| 验证码 | 打码平台 / 行为模拟 / 换策略 |
| JS 加密参数（sign） | 逆向 JS，或用浏览器自动化 |
| 字体反爬 | 下载字体文件做映射还原 |
| CSS 偏移/伪元素 | 解析 CSS 提取真实内容 |
| 蜜罐链接 | 只抓白名单路径，不盲目跟链接 |
| 行为检测（鼠标轨迹） | 浏览器自动化 + 人类化操作 |

### 6.2 限速：礼貌且安全

无论从道德还是从"不被封"的角度，限速都是必须的。Guava 的 `RateLimiter` 非常合适：

```java
// 每秒 2 个请求（即 500ms 一个）
private final RateLimiter limiter = RateLimiter.create(2.0);

public String fetch(String url) throws Exception {
    limiter.acquire();   // 拿不到令牌就阻塞，天然限速
    return httpFetcher.get(url);
}
```

**按域名限速**更精细——对同一个站点限速，对多个站点可以并发：

```java
private final ConcurrentHashMap<String, RateLimiter> domainLimiters = new ConcurrentHashMap<>();

public String fetch(String url) throws Exception {
    String host = URI.create(url).getHost();
    RateLimiter limiter = domainLimiters.computeIfAbsent(host,
            h -> RateLimiter.create(1.0)); // 每站 1 QPS
    limiter.acquire();
    return httpFetcher.get(url);
}
```

### 6.3 代理 IP 池

```java
public class ProxyPool {

    private final BlockingQueue<Proxy> pool = new LinkedBlockingQueue<>();

    public Proxy acquire() throws InterruptedException {
        Proxy p = pool.poll(3, TimeUnit.SECONDS);
        if (p == null) {
            throw new IllegalStateException("代理池耗尽");
        }
        return p;
    }

    public void release(Proxy p) {
        pool.offer(p);
    }

    /** 定期健康检查，剔除失效代理 */
    public void healthCheck() {
        for (Proxy p : pool) {
            if (!ping(p)) {
                pool.remove(p);
            }
        }
    }
}
```

代理要配合**失败重试 + 自动剔除**，否则失效代理会拖慢整体速度。

---

## 七、分布式抓取架构

单机爬虫的瓶颈在带宽、CPU 和 IP 数量。规模上去后要拆成分布式：

```text
               ┌────────────────┐
               │  Master 调度中心 │
               │  - URL 队列(Kafka)│
               │  - 去重(Redis)   │
               │  - 任务分配       │
               └────────┬────────┘
                        │ 分发 URL
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
   │ Worker1 │    │ Worker2 │    │ Worker3 │  下载+解析
   │ (Jsoup) │    │ (Jsoup) │    │ (Jsoup) │
   └────┬────┘    └────┬────┘    └────┬────┘
        │               │               │
        └───────────────┼───────────────┘
                        │ 数据 + 新 URL
               ┌────────▼────────┐
               │  统一存储/入库    │
               │  MySQL/ES/OSS   │
               └─────────────────┘
```

### 7.1 用 Kafka 做 URL 队列

- **多消费者**：Worker 数量可弹性扩缩。
- **按域名分区**：同一站点的 URL 路由到同一分区，天然实现按站限速。
- **持久化**：任务不丢，重启可续。
- **背压**：下游处理不过来时，队列积压可监控告警。

### 7.2 用 Redis 做全局去重与状态

```text
crawl:visited:{domain}   -> BloomFilter（已抓 URL）
crawl:cookie:{domain}    -> Hash（登录态）
crawl:fail:{url}         -> 计数器（失败次数，超阈值进死信）
```

### 7.3 增量抓取

全量抓取成本太高，生产爬虫都是增量的：

- **列表页只抓第一页**，靠 `crawl:visited` 判断是否新内容。
- **内容页用更新时间戳判断**，只在变更时重新抓取。
- **定时调度**：热点站点 5 分钟一次，冷门站点 1 天一次。

---

## 八、健壮性：失败是常态

生产爬虫必须假设"每次请求都可能失败"。

```java
public Optional<String> fetchWithRetry(String url) {
    int retries = 0;
    while (retries < 3) {
        try {
            return Optional.of(httpFetcher.get(url));
        } catch (Exception e) {
            retries++;
            // 指数退避 + 抖动
            long backoff = (long) (Math.pow(2, retries) * 500)
                    + ThreadLocalRandom.current().nextLong(200);
            sleep(backoff);
        }
    }
    // 进入死信队列，人工/离线处理
    deadLetterQueue.add(url);
    return Optional.empty();
}
```

配套的**可观测性**也很重要：

- 抓取成功/失败率、平均延迟（Micrometer + Prometheus）。
- 队列积压长度。
- 各域名 QPS 与封禁情况。
- 数据质量（字段缺失率）。

---

## 九、合规红线

爬虫是技术，但更是法律和道德问题。必须遵守：

1. **robots.txt**：尊重站点的爬取协议。
2. **用户协议与版权**：不抓取明确禁止的数据，不抓个人隐私。
3. **限速礼貌**：不要把目标站压垮，这既是道德也是"别被封"的实用考量。
4. **数据用途合规**：遵守《数据安全法》《个人信息保护法》，不采集、不滥用个人信息。
5. **身份可识别**：建议 UA 中带上联系邮箱，出问题时对方能找到你。

技术能力越强，越要守住这条线。

---

## 十、高频追问

**追问 1：Jsoup 和 Selenium 怎么选？**

优先 Jsoup（快、省资源），只在页面确实需要 JS 渲染、且找不到接口时用 Selenium/Playwright。真实项目大多是"接口优先，Jsoup 兜底，Selenium 最后"。

**追问 2：怎么处理登录态？**

用 CookieJar 保存登录后的 Cookie；对 Cookie 有时效的站点，写一个定时刷新任务；对验证码，能打码平台就打码，能换策略就换策略。

**追问 3：怎么保证不重复抓取？**

三层去重：本地布隆过滤器 → Redis 全局去重 → DB 唯一索引。同时用"URL 规范化"（统一大小写、去掉无意义 query 参数、排序参数）避免同一页面产生多个 URL。

**追问 4：怎么提升抓取速度？**

并发 + 分片 + 代理池。但注意**每个站点要单独限速**，全局提速不能以压垮目标站为代价。

**追问 5：WebMagic 的调度器怎么换成分布式的？**

继承 `Scheduler` 接口，用 Redis 的 List/ZSet 实现 `push`/`poll`/`peek`，并在 `push` 时做去重（Redis Set）。WebMagic 官方就有 `RedisScheduler` 可以直接用。

---

## 十一、总结

一个生产级 Java 爬虫的骨架：

1. **下载**：HttpClient/OkHttp，超时 + 重试 + 连接池。
2. **解析**：Jsoup CSS 选择器优先，动态页面才上浏览器自动化。
3. **框架**：WebMagic 提供完整的调度/下载/解析/管道抽象，快速落地。
4. **去重**：布隆过滤器 + Redis + 唯一索引三层。
5. **反爬**：UA 池、代理池、限速、Cookie 管理，按域名隔离。
6. **分布式**：Kafka 做队列、Redis 做状态、Worker 可水平扩展。
7. **健壮**：指数退避、死信队列、可观测性、增量抓取。
8. **合规**：robots、限速、隐私红线。

爬虫的难点从来不是"解析 HTML"，而是**在对抗中保持稳定、在规模下保持可控、在法律内保持克制**。
