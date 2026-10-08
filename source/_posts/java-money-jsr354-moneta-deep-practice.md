---
title: 【Java 实战】JSR 354 货币与金额深度实战：Moneta、Money 运算、汇率换算与金融精度陷阱
date: 2026-10-08 08:00:00
tags:
  - Java
  - 金额计算
  - JSR 354
  - 金融
categories:
  - Java
  - Java 实战
author: 东哥
---

# 【Java 实战】JSR 354 货币与金额深度实战：Moneta、Money 运算、汇率换算与金融精度陷阱

## 面试官：一个 0.1 元的退款，为什么会让对账差了 3000 块？

> "我们做的是跨境电商，订单金额里既有人民币、美元、欧元，还有日元这种没有小数的币种。
> 前阵子上线了促销活动，退款按比例拆分，结果财务对账时发现：**几千笔退款加起来，和订单总额差了 3000 多块钱**。
> 代码就是最普通的 `double amount = total * ratio;`。你不是说 Java 很严谨吗？这钱去哪了？"

这个问题的答案有三层，层层递进，也正好对应了 Java 里做金额计算的三个段位：

1. **别用 double/float** —— 二进制浮点数根本表示不了大多数十进制小数；
2. **用 BigDecimal 但用不对** —— scale、RoundingMode、`equals` vs `compareTo`，处处是坑；
3. **用 JSR 354（Moneta）** —— 金额不是"一个数字"，而是"数值 + 币种 + 舍入规则"的三元组。

前两层是面试必答，第三层是"加分项"，也是真正做过金融/电商系统的工程师才会主动提的东西。这篇文章按这三层深挖到底。

---

## 一、第一层：为什么 double 一定会错

先把"玄学"讲清楚。`double` 遵循 IEEE 754 双精度浮点标准：1 位符号 + 11 位指数 + 52 位尾数。它的本质是 **二进制科学计数法**：`±1.xxxx × 2^n`。

关键点：**二进制小数只能精确表示 `1/2^k` 形式的分数**。

- `0.5` = 1/2 ✅ 精确
- `0.25` = 1/4 ✅ 精确
- `0.1` = 1/10 ❌ 分母含质因数 5，二进制无法有限表示

```java
System.out.println(0.1 + 0.2);          // 0.30000000000000004
System.out.println(1.0 - 0.9);          // 0.09999999999999998
System.out.println(new BigDecimal(0.1));// 0.1000000000000000055511151231257827021181583404541015625
System.out.println(4.015 * 100);        // 401.49999999999994
```

最后一行最致命：`4.015 * 100` 本应是 401.5，浮点算出来是 401.49999999999994，再 `Math.round` 得到 401，**少收一分钱**。

### 累加误差的恐怖：Kahan 求和问题

单笔误差在 1e-16 量级，看起来无所谓。但退款系统里是**按比例拆分再累加**，误差会随规模放大：

```java
// 把 1000 元按 3 份均分再求和
double total = 0;
for (int i = 0; i < 3; i++) total += 1000.0 / 3;
System.out.println(total);              // 1000.0000000000001

// 一亿笔交易，每笔误差 1e-16，累计偏差可达万元级
```

再加上 `double` 的**有效数字只有约 15~17 位十进制**。当金额超过 `2^53 ≈ 9.007e15` 时，连**整数**都不再能精确表示：

```java
long a = 9007199254740993L;             // 2^53 + 1
double d = a;
System.out.println((long) d);           // 9007199254740992  —— 差 1！
```

对于以"分"为单位的超大金额（比如日流水 9e15 分 = 90 万亿元），`double` 直接失真。**这个数字换成"毫秒时间戳"或"ID"同样成立**，所以任何"精确整数运算"都不该用浮点。

> **面试口径**：金额、货币、坐标、时间戳这类需要精确表示的十进制/整数场景，禁止使用 float/double；用 BigDecimal 或 long（最小货币单位）。

---

## 二、第二层：BigDecimal 的六个坑

`BigDecimal` 用 `BigInteger unscaledValue` + `int scale` 表示 `unscaledValue × 10^(-scale)`，天生精确。但它有自己的一堆坑。

### 坑 1：`new BigDecimal(double)` 保留误差

```java
new BigDecimal(0.1);                    // 0.1000000000000000055511151231257827021181583404541015625
new BigDecimal("0.1");                  // 0.1  ✅
BigDecimal.valueOf(0.1);                // 0.1  ✅（内部走 Double.toString）
```

**只允许用 String 构造器或 `valueOf`**，静态扫描规则里应该直接禁掉 `new BigDecimal(double)`。

### 坑 2：`equals` 比 `compareTo` 多比了 scale

```java
BigDecimal a = new BigDecimal("1.0");
BigDecimal b = new BigDecimal("1.00");
System.out.println(a.equals(b));        // false  ❗ scale 不同
System.out.println(a.compareTo(b) == 0);// true
```

**去重 / 判等 / 做 HashMap key 时，`equals` 的语义是"数值 + 精度都相等"**。用 `BigDecimal` 当 Map key 是经典事故源。要判数值相等一律 `compareTo`（或用 `stripTrailingZeros` 归一化，注意它会把 `100` 变成 `1E+2`，仍然 `equals` 失败）。

### 坑 3：`divide` 不整除直接抛异常

```java
new BigDecimal("10").divide(new BigDecimal("3"));
// java.lang.ArithmeticException: Non-terminating decimal expansion; no exact representable decimal result.
```

**必须显式指定 scale 和舍入模式**：

```java
new BigDecimal("10").divide(new BigDecimal("3"), 2, RoundingMode.HALF_UP); // 3.33
```

这是业务里最容易被线上流量打出来的异常之一，尤其是"按比例分摊"。

### 坑 4：舍入模式选错

| 模式 | 含义 | 直觉 | 典型使用 |
| --- | --- | --- | --- |
| `HALF_UP` | 四舍五入（远离零） | 中国人习惯的"四舍五入" | 展示价、非金融口径 |
| `HALF_EVEN` | 银行家舍入：5 前一位为偶数则舍 | 0.5→0, 1.5→2, 2.5→2 | **金融统计/利息/分摊** |
| `HALF_DOWN` | 五舍六入 | — | 少见于业务 |
| `UP` | 远离零进位（1.0001→1.01） | 有零就进 | 税费上限 |
| `DOWN` | 截断（1.9999→1.99） | 直接砍 | 折扣 |
| `CEILING` / `FLOOR` | 朝正无穷 / 负无穷 | 与正负号有关 | 特殊场景 |
| `UNNECESSARY` | 断言无需舍入 | 不精确就抛 | 校验 |

`HALF_EVEN` 的意义：`HALF_UP` 在大样本下会**系统性偏高**（因为 .5 总是进），银行家舍入让 .5 一半进一半舍，长期期望无偏。**对账系统必须统一舍入口径**，否则两套系统各算各的，差异永远无法归零。

### 坑 5：`scale` 与金额的关系没说清

"分"和"元"的转换最容易出问题：

```java
BigDecimal yuan = new BigDecimal("19.99");
BigDecimal fen = yuan.movePointRight(2);        // 1999
BigDecimal back = fen.movePointLeft(2);         // 19.99
```

`movePointRight` 只是改 scale，不做舍入，安全；`multiply(new BigDecimal(100))` 则可能改变 scale 并带来后续 `equals` 问题。**建议统一：DB 存 bigint 分，或者 DECIMAL(18,4) 的整数型语义**。

### 坑 6：`setScale` 不是原地修改

`BigDecimal` 不可变，`setScale` 返回新对象，忘了接收返回值 = 白改：

```java
BigDecimal x = new BigDecimal("1.005");
x.setScale(2, RoundingMode.HALF_UP);            // ❌ 无效果
x = x.setScale(2, RoundingMode.HALF_UP);        // ✅ 1.01（注：1.005 是 double，字符串是精确的）
```

---

## 三、第三层：JSR 354 与 Moneta —— 金额是"数值 + 币种 + 精度"

到了这里，面试官通常会问："那我用 BigDecimal 加一个 String currencyCode 不就行了吗？"

**行，但极其痛苦**。你会被迫自己维护：

- 不同币种的小数位不同（JPY 0 位、KWD 3 位、USD 2 位）；
- 跨币种运算要先换算，汇率从哪来、什么时候的汇率；
- 不同币种相减要抛异常，不能静默算；
- 金额的分组/符号/小数分隔符在不同 Locale 下格式不同；
- 序列化到 JSON / 存 DB / 传给前端要统一约定。

这套约定，**JSR 354 已经标准化了**。

### 3.1 标准与实现

- **JSR 354 (Money and Currency API)**：定义接口 `javax.money.*`
- **Moneta**：参考实现（原 JSR 354 RI），Maven 坐标 `org.javamoney:moneta`

```xml
<dependency>
  <groupId>org.javamoney</groupId>
  <artifactId>moneta</artifactId>
  <version>1.4.4</version>
</dependency>
```

### 3.2 核心类型全景

| 类型 | 作用 | 关键点 |
| --- | --- | --- |
| `CurrencyUnit` | 币种 | `Monetary.getCurrency("CNY")`，含默认小数位 |
| `MonetaryAmount` | 金额抽象 | 所有金额的根接口 |
| `Money` | 任意精度金额 | 底层 BigDecimal，精度可大于币种位数 |
| `FastMoney` | 固定精度金额 | 底层 long（按币种小数位缩放），**快但不可变精度** |
| `MonetaryAmountFactory` | 工厂 | `Monetary.getDefaultAmountFactory()` |
| `MonetaryOperator` | 一元运算 | 舍入、取绝对值、百分比 |
| `MonetaryQuery` | 查询 | 提取数值、判断正负 |
| `ExchangeRateProvider` | 汇率 | 汇率+有效期+来源 |
| `CurrencyConversion` | 换算上下文 | 封装 provider 与汇率 |
| `MonetaryAmountFormat` | 格式化 | Locale 感知 |
| `AmountFormatQuery` | 格式查询 | 构造格式化器 |

### 3.3 创建与运算

```java
CurrencyUnit cny = Monetary.getCurrency("CNY");
CurrencyUnit usd = Monetary.getCurrency("USD");
CurrencyUnit jpy = Monetary.getCurrency("JPY");   // 0 位小数
CurrencyUnit kwd = Monetary.getCurrency("KWD");   // 3 位小数

MonetaryAmount price = Monetary.getDefaultAmountFactory()
        .setCurrency(cny).setNumber("199.90").create();   // 用 String！

MonetaryAmount tax = price.multiply(0.13);        // 乘法
MonetaryAmount total = price.add(tax);            // 同币种加法
```

**跨币种运算会被直接拒绝**，这是最关键的设计：

```java
MonetaryAmount a = Money.of(100, "CNY");
MonetaryAmount b = Money.of(100, "USD");
a.add(b);
// javax.money.MonetaryException: Currency mismatch: USD/CNY
```

这一条如果自己用 BigDecimal 实现，几乎一定会漏掉，结果就是"100 美元 + 100 人民币 = 200 元"这种事故。

### 3.4 `Money` vs `FastMoney`：性能与语义的取舍

```java
// Money：BigDecimal 后端，精度由运算决定
Money m = Money.of(10, "USD");
Money divided = m.divide(3);            // 保留较高精度，不抛异常

// FastMoney：long 后端，按币种小数位缩放
FastMoney fm = FastMoney.of(10, "USD"); // 内部 1000（分）
FastMoney d = fm.divide(3);             // 3.34，自动按币种精度舍入
```

| 维度 | `Money` | `FastMoney` |
| --- | --- | --- |
| 后端 | `BigDecimal` | `long` |
| 精度 | 可超过币种小数位（如 199.999） | 严格等于币种小数位 |
| 除法 | 保留高精度，可能"除不尽但不报错" | 立即按币种舍入 |
| 性能 | 较慢（对象 + BigDecimal） | 快 2~5 倍，内存更小 |
| 溢出 | 无 | 有（超过 long 上限） |
| 适用 | 计算链路、需要对账留痕 | 高频报价、撮合、统计 |

经验法则：**核心账务用 `Money`，高频计算/聚合用 `FastMoney`，但两者最终写入 DB 前都要按币种精度 `setScale`**。

### 3.5 舍入：`MonetaryOperator`

```java
CurrencyUnit cny = Monetary.getCurrency("CNY");
MonetaryAmount v = Money.of(199.995, cny);

MonetaryOperator rounding = Monetary.getRounding(
        RoundingQueryBuilder.create()
            .setScale(2)
            .set(RoundingMode.HALF_EVEN)   // 银行家舍入
            .build());

MonetaryAmount r = v.with(rounding);       // 200.00
```

Moneta 内置常用 operator：

```java
v.with(MonetaryOperators.percent(8));      // 8% 折算
v.with(MonetaryOperators.majorPart());     // 整数部分
v.with(MonetaryOperators.minorPart());     // 小数部分
MonetaryAmount.realAmount / getNumber().numberValue(BigDecimal.class);
```

### 3.6 汇率换算实战

Moneta 内置多个 `ExchangeRateProvider`：

- `ECBExchangeRateProvider`：欧洲央行，日更，指定货币对；
- `IMFExchangeRateProvider`：IMF 特别提款权；
- `IdentityExchangeRateProvider`：汇率恒为 1（测试用）；
- **`MonetaExchangeRateProvider` / 自定义 provider**：接自己的行情源（推荐，因为金融系统不能依赖第三方可用性）。

```java
// 自定义汇率 provider：接内部汇率服务
public class MyRateProvider implements ExchangeRateProvider {
    @Override
    public ExchangeRate getExchangeRate(ConversionQuery query) {
        String src = query.getBaseCurrency().getCurrencyCode();
        String tgt = query.getCurrency().getCurrencyCode();
        // 1. 查缓存（Redis）2. 查 DB 3. 兜底
        BigDecimal rate = rateRepo.lookup(src, tgt, query.get(LocalDate.class));
        if (rate == null) return null;   // 交给下一个 provider
        return ExchangeRateBuilder.of(getContext())
                .setBase(query.getBaseCurrency())
                .setTerm(query.getCurrency())
                .setFactor(rate)
                .setProviderName("internal")
                .build();
    }
    // getContext / isAvailable / getProviders...
}
```

使用：

```java
CurrencyConversion conv = MonetaryConversions.getConversion("USD",
        "internal");   // 指定 provider 顺序

MonetaryAmount cny = Money.of(100, "USD");
MonetaryAmount usd = cny.with(conv);   // 换算成 USD
System.out.println(usd);
```

**汇率换算的四个硬要求**（面试加分点）：

1. **汇率必须有时间戳/生效日期**，账务要能复现历史换算；
2. **四舍五入只在最后一步做**，中间结果用高精度，避免"链式换算损失"（USD→EUR→CNY 不能每跳都舍入）；
3. **换算方向要定义清楚**：`rate` 是 "1 单位 base = rate 单位 term"，配置反了就是灾难；
4. **换算结果要落库**（原币金额、目标币金额、汇率、汇率来源、汇率时间），否则对账无法回溯。

### 3.7 序列化：Jackson + MonetaModule

金额传给前端/写日志，最怕格式不统一。Moneta 提供 `JavaMoneyModule`：

```java
ObjectMapper om = new ObjectMapper();
om.registerModule(new JavaMoneyModule());
// FastMoney 序列化为 {"currency":"CNY","number":199.90}
// Money 类似，number 保留高精度
```

如果不希望引入模块，最稳妥的做法是**自定义 DTO**，对外只暴露 `{ amount: "199.90", currency: "CNY" }` 字符串：

```java
public record MoneyDTO(String amount, String currency) {
    public static MoneyDTO of(MonetaryAmount m) {
        return new MoneyDTO(
            m.with(Monetary.getRounding(
                 RoundingQueryBuilder.create().setScale(
                     m.getCurrency().getDefaultFractionDigits()).build()))
             .getNumber().numberValue(BigDecimal.class)
             .toPlainString(),
            m.getCurrency().getCurrencyCode());
    }
}
```

**金额永远不要以 JSON number 传**：JavaScript 的 `Number` 是 double，`199.90` 到了前端可能变成 `199.9`，超过 2^53 更是直接失真。用字符串是业界共识。

### 3.8 持久化：JPA / MyBatis 落地

JPA 用 `AttributeConverter`：

```java
@Converter(autoApply = true)
public class MoneyConverter implements AttributeConverter<MonetaryAmount, BigDecimal> {
    // 只支持人民币，多币种需要两列：amount + currency
    @Override public BigDecimal convertToDatabaseColumn(MonetaryAmount m) {
        return m == null ? null : m.with(Monetary.getRounding(
                RoundingQueryBuilder.create().setScale(2)
                    .set(RoundingMode.HALF_UP).build()))
            .getNumber().numberValue(BigDecimal.class);
    }
    @Override public MonetaryAmount convertToEntityAttribute(BigDecimal db) {
        return db == null ? null : Money.of(db, "CNY");
    }
}
```

多币种实体建议直接落两列：

```sql
CREATE TABLE orders (
  id            BIGINT PRIMARY KEY,
  amount        DECIMAL(18,4) NOT NULL,   -- 原币金额
  currency      CHAR(3)       NOT NULL,   -- ISO 4217
  settle_amount DECIMAL(18,4),            -- 结算币金额
  settle_ccy    CHAR(3),
  fx_rate       DECIMAL(18,8),            -- 汇率
  fx_time       DATETIME,
  KEY idx_ccy (currency)
);
```

**为什么 DECIMAL(18,4) 而不是 (18,2)**？因为中间计算/汇率换算需要更多小数位，存储留冗余，**出账时再按币种舍入到 2 位**。KWD 这类 3 位币种也不会被截断。

---

## 四、银行系统的"分摊"算法：误差必须归零

回到开头的退款场景。正确做法不是"每笔算完四舍五入"，而是：

```java
/**
 * 把 total 按 weights 分摊，保证 sum(result) == total（一分不差）
 */
public static List<BigDecimal> allocate(BigDecimal total, List<BigDecimal> weights,
                                        RoundingMode mode) {
    BigDecimal weightSum = weights.stream().reduce(BigDecimal.ZERO, BigDecimal::add);
    List<BigDecimal> result = new ArrayList<>(weights.size());
    BigDecimal allocated = BigDecimal.ZERO;

    for (int i = 0; i < weights.size(); i++) {
        BigDecimal part;
        if (i == weights.size() - 1) {
            part = total.subtract(allocated);          // 最后一笔兜底
        } else {
            part = total.multiply(weights.get(i))
                        .divide(weightSum, 2, mode);
            allocated = allocated.add(part);
        }
        result.add(part);
    }
    return result;
}
```

核心思想：**前 n-1 笔正常舍入，最后一笔用 `总额 - 已分配` 兜底**，把舍入误差集中到最后一笔，保证恒等式成立。这套思路在优惠券分摊、优惠券核销、积分分摊、账单拆分里都是通用的。

如果分摊金额差距大，还可以用"最大余数法（Largest Remainder）"，把舍入产生的余数按小数部分从大到小分配，更公平。

---

## 五、面试常见追问

**Q1：BigDecimal 一定比 double 好吗？**
不是。BigDecimal 是对象，运算开销大，且不可变会频繁产生临时对象。**科学计算、图形、机器学习**用 double 更合适；**金额、精确十进制**才用 BigDecimal/Moneta。选型看语义，不是"越精确越好"。

**Q2：为什么用 `HALF_EVEN` 而不是 `HALF_UP`？**
`HALF_UP` 对所有 .5 都进位，大样本下系统性偏高，长期对账会产生单向偏差；`HALF_EVEN`（银行家舍入）对 .5 一半进一半舍，统计期望无偏。金融计息、分摊普遍用 `HALF_EVEN`。

**Q3：`Money` 和 `FastMoney` 怎么选？**
看是否需要超过币种精度的中间值、是否有高频性能压力、是否可能溢出。计算链路用 `Money`，高频聚合用 `FastMoney`，落库前统一按币种 `setScale`。

**Q4：跨币种相加，Moneta 怎么处理？**
直接抛 `MonetaryException: Currency mismatch`。需要换算时必须显式走 `CurrencyConversion`，强迫开发者思考"用哪个汇率、什么时候的汇率"——这正是它的价值。

**Q5：金额用 JSON number 传前端有什么问题？**
JS `Number` 是 IEEE 754 double，`0.1+0.2=0.30000000000000004`，大额整数超过 2^53 失真，且会丢尾随零。**金额一律用字符串传**，前端也统一按字符串/分处理。

**Q6：如果只能上一个改进，对账差异怎么根治？**
① 统一舍入口径（存在配置中心，全链路读同一份）；② 分摊算法保证"误差归零"；③ 每笔换算落库完整参数（汇率/来源/时间）以便复现。三件套做完，差异从"查不出来"变成"能解释每一分"。

---

## 六、总结

| 层次 | 问题 | 解法 |
| --- | --- | --- |
| 表达式 | 浮点无法精确表示十进制 | 禁用 float/double 做金额 |
| 数值类型 | BigDecimal 的 scale/舍入/不可变 | String 构造、显式 scale、HALF_EVEN、compareTo |
| 领域模型 | 金额不只是数字 | JSR 354 + Moneta：CurrencyUnit + MonetaryAmount + 汇率 + 格式化 |
| 工程落地 | 分摊/换算/序列化/持久化 | 误差归零分摊、汇率落库、字符串传输、DECIMAL(18,4) |

一句话总结：**金额计算不是"数值计算"，而是"带币种和舍入规则的领域建模"**。把这条想清楚，面试官问什么你都能顺着回答；想不清楚，线上就会用 3000 块的差账教你做人。
