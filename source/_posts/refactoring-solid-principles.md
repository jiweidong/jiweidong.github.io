---
title: 代码重构与 SOLID 设计原则实战指南
date: 2026-06-17 09:15:00
tags:
  - 重构
  - SOLID
  - 设计原则
  - 代码质量
  - Clean Code
  - 软件设计
categories:
  - 设计模式
author: 东哥
---

# 代码重构与 SOLID 设计原则实战指南

## 一、为什么需要重构？

代码如同花园，需要持续的照料和修剪。没有重构的代码会逐渐腐化，最终变成"不可触碰的遗留系统"——每次修改都如履薄冰。

**不重构的代价**：
- 新功能开发周期越来越长
- Bug 修复引入新 Bug
- 新人上手成本急剧增加
- 技术债务利息持续累积

Robert Martin 说过："代码首先是为人类编写的，其次才是机器。"

本文将从 SOLID 五大原则入手，结合代码坏味道识别和实战重构案例，帮助你系统地提升代码质量。

<!-- more -->

## 二、SOLID 五大原则详解

SOLID 是面向对象设计的五大基本原则的缩写，由 Robert C. Martin 提出：

| 缩写 | 全称 | 核心思想 |
|------|------|----------|
| **S** | 单一职责原则 | 一个类只应有一个引起它变化的原因 |
| **O** | 开闭原则 | 对扩展开放，对修改关闭 |
| **L** | 里氏替换原则 | 子类必须能够替换其父类 |
| **I** | 接口隔离原则 | 接口应小而专，不应臃肿 |
| **D** | 依赖倒置原则 | 依赖抽象，不依赖具体实现 |

### 2.1 单一职责原则（SRP）

**定义**：一个类应该只有一个引起它变化的原因。

**反例**：一个类处理报告数据获取、格式化和发送：

```java
// ❌ 违反 SRP - 这个类做了三件事
public class ReportService {

    public Report fetchData() {
        // 从数据库获取数据
        Connection conn = DriverManager.getConnection("jdbc:mysql://localhost:3306/report");
        // ... 查询逻辑
        return report;
    }

    public String formatReport(Report report, String format) {
        // 格式化为 HTML 或 PDF
        if ("HTML".equals(format)) {
            return "<html><body>" + report.getTitle() + "</body></html>";
        } else if ("PDF".equals(format)) {
            // PDF 生成逻辑...
            return "pdf data";
        }
        return report.getContent();
    }

    public void sendReport(String content, String email) {
        // 发送邮件报告
        Session session = Session.getInstance(new Properties());
        Message message = new MimeMessage(session);
        // ... 邮件发送逻辑
    }
}
```

**重构后**：拆分为三个独立类

```java
// ✅ 符合 SRP - 每个类只有一个职责

// 职责1：数据获取
public class ReportRepository {
    public Report fetchData() {
        // 从数据库获取数据
        return report;
    }
}

// 职责2：格式转换
public class ReportFormatter {
    public String toHtml(Report report) {
        return "<html><body>" + report.getTitle() + "</body></html>";
    }

    public byte[] toPdf(Report report) {
        // PDF 生成逻辑
        return new byte[0];
    }
}

// 职责3：消息发送
public class EmailSender {
    public void send(String recipient, String content) {
        // 邮件发送逻辑
    }
}

// 协调者：只做编排
public class ReportFacade {
    private final ReportRepository repository;
    private final ReportFormatter formatter;
    private final EmailSender sender;

    public void generateAndSendReport(String email) {
        Report report = repository.fetchData();
        String html = formatter.toHtml(report);
        sender.send(email, html);
    }
}
```

**判断是否违反 SRP 的方法**：如果写类注释时需要用"和（and）"连接多个概念，大概率已经违反了。

### 2.2 开闭原则（OCP）

**定义**：软件实体（类、模块、函数）应该对扩展开放，对修改关闭。

**反例**：每次新增支付方式都需要修改现有代码：

```java
// ❌ 违反 OCP - 新增支付方式需修改 PaymentService
public class PaymentService {

    public void pay(String type, double amount) {
        if ("ALIPAY".equals(type)) {
            // 支付宝支付逻辑
            AlipayApi alipay = new AlipayApi();
            alipay.pay(amount);
        } else if ("WECHAT".equals(type)) {
            // 微信支付逻辑
            WechatPayApi wechat = new WechatPayApi();
            wechat.pay(amount);
        } else if ("UNIONPAY".equals(type)) {
            // 银联支付逻辑
            UnionPayApi unionpay = new UnionPayApi();
            unionpay.pay(amount);
        }
        // 每次新增类型都要修改这里！❌
    }
}
```

**重构后**：利用策略模式实现扩展性：

```java
// ✅ 符合 OCP - 抽象支付接口
public interface PaymentStrategy {
    boolean supports(String type);
    PayResult pay(double amount);
}

// 支付宝实现
public class AlipayStrategy implements PaymentStrategy {
    @Override
    public boolean supports(String type) {
        return "ALIPAY".equals(type);
    }

    @Override
    public PayResult pay(double amount) {
        // 支付宝具体逻辑
        return new PayResult(true, "支付宝支付成功");
    }
}

// 微信支付实现
public class WechatPayStrategy implements PaymentStrategy {
    @Override
    public boolean supports(String type) {
        return "WECHAT".equals(type);
    }

    @Override
    public PayResult pay(double amount) {
        // 微信支付具体逻辑
        return new PayResult(true, "微信支付成功");
    }
}

// 支付调度器 - 永不修改
public class PaymentDispatcher {

    private final List<PaymentStrategy> strategies;

    public PaymentDispatcher(List<PaymentStrategy> strategies) {
        this.strategies = strategies;
    }

    public PayResult execute(String type, double amount) {
        return strategies.stream()
            .filter(s -> s.supports(type))
            .findFirst()
            .orElseThrow(() -> new IllegalArgumentException("不支持的支付类型: " + type))
            .pay(amount);
    }
}

// 新增支付方式 → 新建类，不修改已有代码
public class StripeStrategy implements PaymentStrategy {
    @Override
    public boolean supports(String type) {
        return "STRIPE".equals(type);
    }

    @Override
    public PayResult pay(double amount) {
        // Stripe 支付逻辑（不需要修改 PaymentDispatcher）
        return new PayResult(true, "Stripe 支付成功");
    }
}
```

开闭原则的本质是 **抽象化**——通过接口或抽象类定义扩展点，让新增功能通过新增类而非修改现有类来实现。

### 2.3 里氏替换原则（LSP）

**定义**：派生类（子类）必须能够透明地替换其基类（父类），而不影响系统的正确性。

**反例**：经典的"正方形不是矩形"问题：

```java
// ❌ 违反 LSP
public class Rectangle {
    protected int width;
    protected int height;

    public void setWidth(int width) { this.width = width; }
    public void setHeight(int height) { this.height = height; }
    public int getArea() { return width * height; }
}

public class Square extends Rectangle {
    @Override
    public void setWidth(int width) {
        super.setWidth(width);
        super.setHeight(width);  // 保持正方形特性
    }

    @Override
    public void setHeight(int height) {
        super.setWidth(height);  // 强制宽度等于高度
        super.setHeight(height);
    }
}

// 客户端代码
public class AreaCalculator {
    public void resizeAndPrint(Rectangle rect) {
        rect.setWidth(5);
        rect.setHeight(10);
        // 期望：5 * 10 = 50
        // 如果传入 Square：10 * 10 = 100 ❌
        System.out.println("面积: " + rect.getArea());
    }
}
```

**重构后**：使用合成而非继承：

```java
// ✅ 符合 LSP - 抽象出 Shape 接口
public interface Shape {
    int getArea();
}

public class Rectangle implements Shape {
    protected int width;
    protected int height;

    public Rectangle(int width, int height) {
        this.width = width;
        this.height = height;
    }

    @Override
    public int getArea() {
        return width * height;
    }
}

public class Square implements Shape {
    private int side;

    public Square(int side) {
        this.side = side;
    }

    @Override
    public int getArea() {
        return side * side;
    }
}

// 客户端代码对任意 Shape 都统一处理
class AreaPrinter {
    public void print(Shape shape) {
        System.out.println("面积: " + shape.getArea());
    }
}
```

**LSP 的判定方法**：子类是否修改了父类的约定？如果子类抛出了父类未声明的新异常、返回了不同类型的值、或者改变了方法的语义，就违反了 LSP。

### 2.4 接口隔离原则（ISP）

**定义**：客户端不应强制依赖它不需要的接口方法。

**反例**：一个臃肿的 Worker 接口：

```java
// ❌ 违反 ISP - 接口过于臃肿
public interface Worker {
    void work();
    void eat();
    void sleep();
    void code();
    void design();
    void test();
    void deploy();
}

// Developer 需要实现所有方法，但很多是不需要的
public class Developer implements Worker {
    @Override
    public void work() { /* 工作 */ }
    @Override
    public void eat() { /* 吃饭 */ }
    @Override
    public void sleep() { /* 睡觉 */ }
    @Override
    public void code() { /* 写代码 */ }
    @Override
    public void design() { /* 设计 */ }
    @Override
    public void test() { /* 测试 */ }
    @Override
    public void deploy() { /* 部署 */ }
}

// Robot 不需要 eat/sleep，但不得不实现
public class Robot implements Worker {
    @Override
    public void work() { /* 工作 */ }
    @Override
    public void eat() { throw new UnsupportedOperationException("机器人不需要吃饭"); } // ❌
    @Override
    public void sleep() { throw new UnsupportedOperationException("机器人不需要睡觉"); } // ❌
    @Override
    public void code() { /* 编程 */ }
    @Override
    public void design() { /* 设计 */ }
    @Override
    public void test() { /* 测试 */ }
    @Override
    public void deploy() { /* 部署 */ }
}
```

**重构后**：拆分为多个细化接口：

```java
// ✅ 符合 ISP - 接口小而专
public interface Workable {
    void work();
}

public interface Eatable {
    void eat();
}

public interface Sleepable {
    void sleep();
}

public interface Codeable {
    void code();
}

public interface Testable {
    void test();
}

public interface Deployable {
    void deploy();
}

// Developer 只实现需要的接口
public class Developer implements Workable, Eatable, Sleepable, Codeable, Testable, Deployable {
    @Override public void work() { /* 工作 */ }
    @Override public void eat() { /* 吃饭 */ }
    @Override public void sleep() { /* 睡觉 */ }
    @Override public void code() { /* 写代码 */ }
    @Override public void test() { /* 测试 */ }
    @Override public void deploy() { /* 部署 */ }
}

// Robot 只实现需要的接口 - 不再有空的实现
public class Robot implements Workable, Codeable, Testable {
    @Override public void work() { /* 工作 */ }
    @Override public void code() { /* 编程 */ }
    @Override public void test() { /* 测试 */ }
}
```

**ISP 的简单判断**：如果你的接口方法数量超过 5 个，或者实现类需要抛出 `UnsupportedOperationException`，很可能违反了 ISP。

### 2.5 依赖倒置原则（DIP）

**定义**：高层模块不应依赖低层模块，两者都应依赖抽象；抽象不应依赖细节，细节应依赖抽象。

**反例**：高层模块直接依赖低层实现：

```java
// ❌ 违反 DIP - 高层模块直接依赖低层实现
public class UserController {

    private final MySQLUserRepository repository;    // 直接依赖具体实现

    public UserController() {
        this.repository = new MySQLUserRepository(); // 硬编码依赖
    }

    public User getUser(Long id) {
        return repository.findById(id);
    }
}
```

**重构后**：依赖抽象接口：

```java
// ✅ 符合 DIP

// 抽象接口（定义在高层模块）
public interface UserRepository {
    User findById(Long id);
    void save(User user);
}

// 低层实现依赖抽象
public class MySQLUserRepository implements UserRepository {
    @Override
    public User findById(Long id) {
        // MySQL 查询逻辑
        return user;
    }
    @Override
    public void save(User user) {
        // MySQL 插入逻辑
    }
}

public class MongoUserRepository implements UserRepository {
    @Override
    public User findById(Long id) {
        // MongoDB 查询逻辑
        return user;
    }
    @Override
    public void save(User user) {
        // MongoDB 插入逻辑
    }
}

// 高层模块只依赖抽象
public class UserController {
    private final UserRepository repository;  // 依赖抽象，非具体实现

    public UserController(UserRepository repository) { // 构造器注入
        this.repository = repository;
    }

    public User getUser(Long id) {
        return repository.findById(id);
    }
}

// 通过依赖注入容器组装
@Configuration
public class AppConfig {
    @Bean
    public UserRepository userRepository() {
        return new MySQLUserRepository(); // 绑定在这里，随时可切换
    }

    @Bean
    public UserController userController(UserRepository repository) {
        return new UserController(repository);
    }
}
```

## 三、代码坏味道识别

重构的第一步是识别代码的"坏味道"（Code Smell）。Martin Fowler 在《重构》中列出了 20+ 种坏味道，以下是 Java 开发中最常见的 10 种：

### 3.1 代码坏味道清单

| # | 坏味道 | 识别特征 | 常用重构手法 |
|---|--------|----------|-------------|
| 1 | **过长方法** | 方法超过 20-30 行，滚动条才能看完 | 提取方法、提取到独立类 |
| 2 | **过大的类** | 类内方法超过 20 个，职责模糊 | 提取类、提取子类 |
| 3 | **长参数列表** | 方法参数超过 3-4 个 | 引入参数对象 |
| 4 | **重复代码** | 相同结构的代码在不同地方出现 | 提取方法、提取超类 |
| 5 | **发散式变化** | 修改一个需求需要改多个类 | 提取类、移动方法 |
| 6 | **霰弹式修改** | 一个类因多个需求频繁修改 | 搬移方法、搬移字段 |
| 7 | **依恋情结** | 方法更多地依赖其他类的数据 | 搬移方法 |
| 8 | **基本类型偏执** | 大量使用基本类型代替对象 | 引入参数对象、以对象取代基本类型 |
| 9 | **临时字段** | 字段只在特定场景下才非空 | 提取类、引入 Null 对象 |
| 10 | **过度耦合的消息链** | `a.getB().getC().getD().doSomething()` | 隐藏委托、提取方法 |

### 3.2 坏味道识别与重构代码示例

**坏味道示例：过长方法 + 长参数列表**

```java
// ❌ 坏味道：过长方法（70+行）+ 长参数列表（7个参数）
public class OrderProcessor {

    public void processOrder(String orderId, String customerName, String customerEmail,
                             String shippingAddress, String paymentMethod, 
                             double amount, String couponCode) {
        // 1. 验证订单
        if (orderId == null || orderId.isEmpty()) {
            throw new IllegalArgumentException("订单ID不能为空");
        }
        System.out.println("验证客户: " + customerName);

        // 2. 计算价格
        double finalAmount = amount;
        if (couponCode != null && !couponCode.isEmpty()) {
            if (couponCode.equals("VIP50")) {
                finalAmount = amount * 0.5;
                System.out.println("VIP 5折优惠");
            } else if (couponCode.equals("NEW10")) {
                finalAmount = amount * 0.9;
                System.out.println("新用户9折优惠");
            }
        }
        System.out.println("最终金额: " + finalAmount);

        // 3. 处理支付
        if ("CREDIT_CARD".equals(paymentMethod)) {
            // 信用卡支付逻辑...
            System.out.println("使用信用卡支付: " + finalAmount);
        } else if ("ALIPAY".equals(paymentMethod)) {
            // 支付宝支付逻辑...
            System.out.println("使用支付宝支付: " + finalAmount);
        }
        // ... 还有更多支付方式

        // 4. 发送通知
        System.out.println("发送邮件到: " + customerEmail);
        System.out.println("订单 " + orderId + " 处理完成");

        // 5. 更新库存
        System.out.println("更新库存中...");
    }
}
```

## 四、核心重构手法实战

### 4.1 提取方法（Extract Method）

最常用的重构手法，将一段独立逻辑抽取为方法。

**重构前**：

```java
public void printInvoice(Invoice invoice) {
    // 计算
    double basePrice = invoice.getQuantity() * invoice.getItemPrice();
    double discount = Math.max(0, invoice.getQuantity() - 500) * invoice.getItemPrice() * 0.05;
    double shippingCost = Math.min(basePrice * 0.1, 100.0);
    double total = basePrice - discount + shippingCost;

    // 打印
    System.out.println("===== 发票 =====");
    System.out.println("基础价: " + basePrice);
    System.out.println("折扣: " + discount);
    System.out.println("运费: " + shippingCost);
    System.out.println("总计: " + total);
    System.out.println("================");
}
```

**重构后**：

```java
public void printInvoice(Invoice invoice) {
    double basePrice = calculateBasePrice(invoice);
    double discount = calculateDiscount(invoice);
    double shippingCost = calculateShipping(basePrice);
    double total = calculateTotal(basePrice, discount, shippingCost);
    printInvoiceDetail(basePrice, discount, shippingCost, total);
}

private double calculateBasePrice(Invoice invoice) {
    return invoice.getQuantity() * invoice.getItemPrice();
}

private double calculateDiscount(Invoice invoice) {
    return Math.max(0, invoice.getQuantity() - 500) 
           * invoice.getItemPrice() * 0.05;
}

private double calculateShipping(double basePrice) {
    return Math.min(basePrice * 0.1, 100.0);
}

private double calculateTotal(double basePrice, double discount, double shipping) {
    return basePrice - discount + shipping;
}

private void printInvoiceDetail(double basePrice, double discount, 
                                 double shipping, double total) {
    System.out.println("===== 发票 =====");
    System.out.println("基础价: " + basePrice);
    System.out.println("折扣: " + discount);
    System.out.println("运费: " + shipping);
    System.out.println("总计: " + total);
    System.out.println("================");
}
```

### 4.2 引入参数对象（Introduce Parameter Object）

当一组参数经常一起出现时，将它们封装为对象。

**重构前**：

```java
public void createBooking(String customerName, String customerEmail, 
                          String customerPhone, String roomType, 
                          LocalDate checkIn, LocalDate checkOut) {
    // 使用多个参数...
}
```

**重构后**：

```java
// 引入的参数对象
public class CustomerInfo {
    private final String name;
    private final String email;
    private final String phone;

    public CustomerInfo(String name, String email, String phone) {
        this.name = name;
        this.email = email;
        this.phone = phone;
    }

    // getters...
}

public class BookingPeriod {
    private final LocalDate checkIn;
    private final LocalDate checkOut;

    public BookingPeriod(LocalDate checkIn, LocalDate checkOut) {
        if (checkOut.isBefore(checkIn)) {
            throw new IllegalArgumentException("退房日期不能早于入住日期");
        }
        this.checkIn = checkIn;
        this.checkOut = checkOut;
    }

    public int getNights() {
        return (int) DAYS.between(checkIn, checkOut);
    }

    // getters...
}

// 重构后：参数更少，语义更清晰
public void createBooking(CustomerInfo customer, String roomType, BookingPeriod period) {
    // 验证逻辑已在参数对象中完成
    System.out.println("客户: " + customer.getName());
    System.out.println("入住: " + period.getNights() + "晚");
}
```

### 4.3 搬移方法（Move Method）

当一个方法与另一个类关系更密切时，将其搬移到那个类。

**重构前**：

```java
public class Order {
    private Customer customer;
    private List<OrderItem> items;

    public double calculateShippingCost() {
        // 实际上这个方法更依赖 Customer 的数据
        String city = customer.getAddress().getCity();
        double weight = items.stream().mapToDouble(OrderItem::getWeight).sum();
        
        if ("北京".equals(city)) {
            return weight > 10 ? 30 : 15;
        } else if ("上海".equals(city)) {
            return weight > 10 ? 25 : 12;
        } else {
            return weight > 10 ? 40 : 20;
        }
    }
}
```

**重构后**：

```java
public class Address {
    private String city;

    public double calculateShippingCost(double weight) {
        // 运费计算搬到 Address 中更合理
        return switch (city) {
            case "北京" -> weight > 10 ? 30 : 15;
            case "上海" -> weight > 10 ? 25 : 12;
            default -> weight > 10 ? 40 : 20;
        };
    }
}

public class Order {
    private Customer customer;
    private List<OrderItem> items;

    public double calculateShippingCost() {
        double weight = items.stream().mapToDouble(OrderItem::getWeight).sum();
        return customer.getAddress().calculateShippingCost(weight);
    }
}
```

## 五、完整实战重构案例

### 案例：订单系统重构

让我们将一个混乱的订单处理系统逐步重构为整洁架构。

**原始代码（混乱版本）**：

```java
// ❌ 混乱的订单处理器 - 集所有问题于一身
public class OrderHandler {
    private Connection conn;

    public OrderHandler() throws SQLException {
        conn = DriverManager.getConnection("jdbc:mysql://localhost:3306/store");
    }

    public String handle(String json) {
        try {
            JSONObject obj = new JSONObject(json);
            String id = obj.getString("id");
            String uid = obj.getString("uid");
            JSONArray items = obj.getJSONArray("items");
            
            double total = 0;
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.getJSONObject(i);
                String sku = item.getString("sku");
                int qty = item.getInt("qty");
                
                // 查价格
                Statement stmt = conn.createStatement();
                ResultSet rs = stmt.executeQuery("SELECT price FROM products WHERE sku='" + sku + "'");
                rs.next();
                double price = rs.getDouble("price");
                total += price * qty;
                rs.close();
                stmt.close();
            }
            
            // 检查库存
            PreparedStatement ps = conn.prepareStatement("SELECT stock FROM inventory WHERE sku=?");
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.getJSONObject(i);
                ps.setString(1, item.getString("sku"));
                ResultSet rs = ps.executeQuery();
                rs.next();
                int stock = rs.getInt("stock");
                if (stock < item.getInt("qty")) {
                    return "{\"status\":\"FAILED\",\"reason\":\"库存不足:" + item.getString("sku") + "\"}";
                }
                rs.close();
            }
            ps.close();
            
            // 扣减库存
            PreparedStatement updatePs = conn.prepareStatement("UPDATE inventory SET stock=stock-? WHERE sku=?");
            for (int i = 0; i < items.length(); i++) {
                JSONObject item = items.getJSONObject(i);
                updatePs.setInt(1, item.getInt("qty"));
                updatePs.setString(2, item.getString("sku"));
                updatePs.executeUpdate();
            }
            updatePs.close();
            
            // 保存订单
            PreparedStatement orderPs = conn.prepareStatement("INSERT INTO orders(id, user_id, total, status) VALUES(?,?,?,?)");
            orderPs.setString(1, id);
            orderPs.setString(2, uid);
            orderPs.setDouble(3, total);
            orderPs.setString(4, "CREATED");
            orderPs.executeUpdate();
            orderPs.close();
            
            return "{\"status\":\"SUCCESS\",\"orderId\":\"" + id + "\",\"total\":" + total + "}";
            
        } catch (Exception e) {
            return "{\"status\":\"ERROR\",\"reason\":\"" + e.getMessage() + "\"}";
        } finally {
            try { conn.close(); } catch (Exception e) {}
        }
    }
}
```

**这个类的问题**（坏味道清单）：

| # | 问题 | 违反原则 |
|---|------|----------|
| 1 | 过于庞大，一个方法包含所有逻辑 | SRP |
| 2 | JSON 处理、SQL、业务逻辑混在一起 | SRP |
| 3 | 构造函数中硬编码数据库连接 | DIP |
| 4 | 无异常处理，直接 SQL 注入风险 | - |
| 5 | 重复的数据库操作代码 | DRY |
| 6 | 返回 JSON 字符串，类型不安全 | - |

### 重构过程（逐步进行）

**第1步：分离数据访问层**

```java
// === Step 1: 数据访问层 ===
public class ProductRepository {
    private final DataSource dataSource;

    public ProductRepository(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    public double getPrice(String sku) {
        String sql = "SELECT price FROM products WHERE sku = ?";
        try (Connection conn = dataSource.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {
            ps.setString(1, sku);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return rs.getDouble("price");
                }
                throw new ProductNotFoundException(sku);
            }
        } catch (SQLException e) {
            throw new DataAccessException("查询商品价格失败", e);
        }
    }
}

public class InventoryRepository {
    private final DataSource dataSource;

    public int getStock(String sku) {
        // ... 查询库存逻辑
    }

    public void deductStock(String sku, int quantity) {
        // ... 扣减库存逻辑
    }
}

public class OrderRepository {
    private final DataSource dataSource;

    public void save(Order order) {
        // ... 保存订单逻辑
    }
}
```

**第2步：定义领域模型**

```java
// === Step 2: 领域模型 ===
public record OrderItem(String sku, int quantity, double unitPrice) {
    public double getSubtotal() {
        return unitPrice * quantity;
    }
}

public record Order(String id, String userId, List<OrderItem> items, double total, OrderStatus status) {
    public static Order create(String id, String userId, List<OrderItem> items) {
        double total = items.stream().mapToDouble(OrderItem::getSubtotal).sum();
        return new Order(id, userId, items, total, OrderStatus.CREATED);
    }
}

public enum OrderStatus {
    CREATED, PAID, SHIPPED, COMPLETED, CANCELLED
}
```

**第3步：实现核心业务服务**

```java
// === Step 3: 业务服务层 ===
@Service
public class OrderService {

    private final ProductRepository productRepo;
    private final InventoryRepository inventoryRepo;
    private final OrderRepository orderRepo;

    public OrderService(ProductRepository productRepo,
                        InventoryRepository inventoryRepo,
                        OrderRepository orderRepo) {
        this.productRepo = productRepo;
        this.inventoryRepo = inventoryRepo;
        this.orderRepo = orderRepo;
    }

    @Transactional
    public OrderResult placeOrder(String orderId, String userId, List<OrderItemRequest> items) {
        // 1. 获取价格并构建订单项
        List<OrderItem> orderItems = items.stream()
            .map(req -> {
                double price = productRepo.getPrice(req.sku());
                return new OrderItem(req.sku(), req.quantity(), price);
            })
            .toList();

        // 2. 检查库存
        for (OrderItem item : orderItems) {
            int stock = inventoryRepo.getStock(item.sku());
            if (stock < item.quantity()) {
                return OrderResult.failure("库存不足: " + item.sku());
            }
        }

        // 3. 扣减库存
        for (OrderItem item : orderItems) {
            inventoryRepo.deductStock(item.sku(), item.quantity());
        }

        // 4. 创建并保存订单
        Order order = Order.create(orderId, userId, orderItems);
        orderRepo.save(order);

        return OrderResult.success(orderId, order.total());
    }
}
```

**第4步：Controller 层**

```java
// === Step 4: Controller 层 ===
@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping
    public ResponseEntity<OrderResponse> createOrder(@RequestBody @Valid CreateOrderRequest request) {
        OrderResult result = orderService.placeOrder(
            UUID.randomUUID().toString(),
            request.userId(),
            request.items()
        );

        if (result.isSuccess()) {
            return ResponseEntity.status(HttpStatus.CREATED)
                .body(new OrderResponse(result.orderId(), result.total()));
        } else {
            return ResponseEntity.badRequest()
                .body(new OrderResponse(null, 0, result.errorMessage()));
        }
    }
}
```

**重构前后对比**：

| 维度 | 重构前 | 重构后 |
|------|--------|--------|
| 类数量 | 1个（魔类） | 10+个（各司其职） |
| 方法行数 | ~60行 | ~15行/方法 |
| 职责清晰度 | 一锅粥 | 分层清晰 |
| 测试性 | 几乎不可测 | 每个类可独立测试 |
| 可扩展性 | 新增功能需修改魔类 | 新增功能只需新增类/方法 |
| 数据库耦合 | 硬编码 | 通过接口解耦 |
| 异常处理 | catch-all 掩盖异常 | 明确的异常类型 |

## 六、重构流程与最佳实践

### 6.1 安全重构的步骤

```
1. 确保有测试覆盖
    │
2. 小步前进（每次只做一个重构）
    │
3. 运行测试验证（必须绿色通过）
    │
4. 提交代码（Git commit）
    │
5. 重复 2-4
```

**黄金法则**：重构时不要同时添加新功能，反之亦然。一次只做一件事。

### 6.2 常见的误区

| 误区 | 正确理解 |
|------|----------|
| 重构 = 重写 | 重构是逐渐改善设计，而非推倒重来 |
| 等模块稳定再重构 | 越早重构，成本越低 |
| 重构需要专门的时间 | 童子军规则：每次修改时顺手改善 |
| 设计模式是重构的目标 | 设计模式是工具，过度设计也是坏味道 |
| 重构会导致更多 Bug | 没有测试保障的重构才会引入 Bug |

### 6.3 实用重构清单

推荐的重构优先顺序（从最安全到最复杂）：

```java
// 1. 重命名（Rename）——最安全，提升可读性
// IDE 重构：Shift+F6 (IntelliJ)

// 2. 提取方法（Extract Method）——拆分长方法
// IDE 重构：Ctrl+Alt+M (IntelliJ)

// 3. 提取常量/变量（Extract Constant/Variable）
// IDE 重构：Ctrl+Alt+C / Ctrl+Alt+V (IntelliJ)

// 4. 内联（Inline）——移除不必要的间接层
// IDE 重构：Ctrl+Alt+N (IntelliJ)

// 5. 搬移方法/字段（Move Method/Field）
// IDE 重构：F6 (IntelliJ)

// 6. 提取接口/超类（Extract Interface/Superclass）

// 7. 用多态替代条件（Replace Conditional with Polymorphism）

// 8. 引入设计模式（Strategy, Template Method, Factory 等）

// 9. 拆分模块/服务（Module/Service Extraction）
```

## 七、总结

SOLID 原则不是教条，而是**指导我们写出可维护代码的经验总结**。理解每个原则背后的思想，比背下名称更重要：

- **SRP** 告诉你：一个类只专注做好一件事
- **OCP** 告诉你：用扩展代替修改
- **LSP** 告诉你：子类要尊重父类的约定
- **ISP** 告诉你：接口要小而专
- **DIP** 告诉你：依赖抽象，不依赖具体

重构是持续的过程，不是一次性的活动。每次修改代码时，让自己比离开时留下更整洁的代码——这就是著名的**童子军规则**。

推荐延伸阅读：
- 《重构：改善既有代码的设计》—— Martin Fowler
- 《Clean Code》—— Robert C. Martin
- 《Agile Software Development, Principles, Patterns, and Practices》—— Robert C. Martin
- 《Working Effectively with Legacy Code》—— Michael Feathers
