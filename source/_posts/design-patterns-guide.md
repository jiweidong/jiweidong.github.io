---
title: 设计模式精讲：23 种设计模式详解与实践
date: 2026-06-15 10:30:00
tags:
  - 设计模式
  - GoF
  - 面向对象
  - Java
categories:
  - Java
author: 东哥
---

# 设计模式精讲：23 种设计模式详解与实践

> 设计模式是前辈们总结的面向对象设计经验。掌握设计模式，能让你的代码更具可维护性、可扩展性和复用性。本文全面解析 GoF 23 种设计模式，并结合 Java 代码实战。

## 一、设计模式概述

### 1.1 设计模式的分类

| 类型 | 数量 | 模式名称 |
|------|------|----------|
| **创建型** | 5 | 单例、工厂方法、抽象工厂、建造者、原型 |
| **结构型** | 7 | 适配器、装饰器、代理、外观、桥接、组合、享元 |
| **行为型** | 11 | 策略、模板方法、观察者、迭代器、责任链、命令、备忘录、状态、访问者、中介者、解释器 |

### 1.2 设计原则（SOLID）

- **S** — 单一职责原则：一个类只负责一个功能
- **O** — 开闭原则：对扩展开放，对修改关闭
- **L** — 里氏替换原则：子类必须能替换父类
- **I** — 接口隔离原则：接口要小而专
- **D** — 依赖倒置原则：依赖抽象，不依赖具体

## 二、创建型模式

### 2.1 单例模式（Singleton）

确保一个类只有一个实例。

**饿汉式：**

```java
public class Singleton {
    private static final Singleton INSTANCE = new Singleton();
    private Singleton() {}
    public static Singleton getInstance() {
        return INSTANCE;
    }
}
```

**懒汉式（双重检查锁定）：**

```java
public class Singleton {
    private static volatile Singleton instance;
    private Singleton() {}
    
    public static Singleton getInstance() {
        if (instance == null) {
            synchronized (Singleton.class) {
                if (instance == null) {
                    instance = new Singleton();
                }
            }
        }
        return instance;
    }
}
```

**枚举式（最推荐）：**

```java
public enum Singleton {
    INSTANCE;
    public void doSomething() { }
}
```

### 2.2 工厂方法模式（Factory Method）

定义一个创建对象的接口，让子类决定实例化哪个类。

```java
// 产品接口
interface Database {
    void connect();
}

// 具体产品
class MySQL implements Database {
    public void connect() { System.out.println("连接 MySQL"); }
}
class PostgreSQL implements Database {
    public void connect() { System.out.println("连接 PostgreSQL"); }
}

// 工厂
interface DatabaseFactory {
    Database createDatabase();
}
class MySQLFactory implements DatabaseFactory {
    public Database createDatabase() { return new MySQL(); }
}
class PostgreSQLFactory implements DatabaseFactory {
    public Database createDatabase() { return new PostgreSQL(); }
}

// 使用
DatabaseFactory factory = new MySQLFactory();
Database db = factory.createDatabase();
db.connect();
```

### 2.3 抽象工厂模式（Abstract Factory）

创建相关或依赖对象的家族，而不指定具体类。

```java
// 抽象工厂
interface GUIFactory {
    Button createButton();
    Checkbox createCheckbox();
}

// 具体工厂族
class WinFactory implements GUIFactory {
    public Button createButton() { return new WinButton(); }
    public Checkbox createCheckbox() { return new WinCheckbox(); }
}
class MacFactory implements GUIFactory {
    public Button createButton() { return new MacButton(); }
    public Checkbox createCheckbox() { return new MacCheckbox(); }
}

// 使用
GUIFactory factory = new WinFactory();
Button btn = factory.createButton();
```

### 2.4 建造者模式（Builder）

分离复杂对象的构建和表示，同样构建过程可以创建不同的表示。

```java
public class User {
    private String name;
    private int age;
    private String email;
    private String phone;
    
    private User(Builder builder) {
        this.name = builder.name;
        this.age = builder.age;
        this.email = builder.email;
        this.phone = builder.phone;
    }
    
    public static class Builder {
        private String name;      // 必选
        private int age = 18;     // 可选，默认值
        private String email;     // 可选
        private String phone;     // 可选
        
        public Builder(String name) {
            this.name = name;
        }
        public Builder age(int age) { this.age = age; return this; }
        public Builder email(String email) { this.email = email; return this; }
        public Builder phone(String phone) { this.phone = phone; return this; }
        public User build() { return new User(this); }
    }
}

// 使用
User user = new User.Builder("张三")
    .age(25)
    .email("zhangsan@example.com")
    .phone("13800138000")
    .build();
```

## 三、结构型模式

### 3.1 适配器模式（Adapter）

将一个接口转换成客户希望的另一个接口。

```java
// 已有接口
interface MediaPlayer {
    void play(String audioType, String fileName);
}

// 不兼容的类
class AdvancedMediaPlayer {
    public void playVlc(String fileName) { }
    public void playMp4(String fileName) { }
}

// 适配器
class MediaAdapter implements MediaPlayer {
    private AdvancedMediaPlayer advancedPlayer;
    
    public MediaAdapter(String audioType) {
        advancedPlayer = new AdvancedMediaPlayer();
    }
    
    @Override
    public void play(String audioType, String fileName) {
        if ("mp4".equalsIgnoreCase(audioType)) {
            advancedPlayer.playMp4(fileName);
        }
    }
}
```

### 3.2 装饰器模式（Decorator）

动态地给一个对象添加额外的职责，比继承更灵活。

```java
// 组件接口
interface Coffee {
    double cost();
    String description();
}

// 具体组件
class SimpleCoffee implements Coffee {
    public double cost() { return 10; }
    public String description() { return "原味咖啡"; }
}

// 抽象装饰器
abstract class CoffeeDecorator implements Coffee {
    protected Coffee coffee;
    public CoffeeDecorator(Coffee coffee) {
        this.coffee = coffee;
    }
    public double cost() { return coffee.cost(); }
    public String description() { return coffee.description(); }
}

// 具体装饰器
class MilkDecorator extends CoffeeDecorator {
    public MilkDecorator(Coffee coffee) { super(coffee); }
    public double cost() { return super.cost() + 4; }
    public String description() { return super.description() + " + 牛奶"; }
}

class SugarDecorator extends CoffeeDecorator {
    public SugarDecorator(Coffee coffee) { super(coffee); }
    public double cost() { return super.cost() + 2; }
    public String description() { return super.description() + " + 糖"; }
}

// 使用
Coffee coffee = new SimpleCoffee();
coffee = new MilkDecorator(coffee);
coffee = new SugarDecorator(coffee);
System.out.println(coffee.description() + ": " + coffee.cost() + "元");
// 输出：原味咖啡 + 牛奶 + 糖: 16元
```

### 3.3 代理模式（Proxy）

为其他对象提供一种代理以控制对这个对象的访问。

```java
// 在 Spring AOP 中广泛应用
interface UserService {
    void save(String user);
}

class UserServiceImpl implements UserService {
    public void save(String user) {
        System.out.println("保存用户: " + user);
    }
}

// JDK 动态代理
class LogProxy {
    @SuppressWarnings("unchecked")
    public static <T> T createProxy(T target) {
        return (T) Proxy.newProxyInstance(
            target.getClass().getClassLoader(),
            target.getClass().getInterfaces(),
            (proxy, method, args) -> {
                System.out.println("[日志] 调用 " + method.getName());
                long start = System.currentTimeMillis();
                Object result = method.invoke(target, args);
                long elapsed = System.currentTimeMillis() - start;
                System.out.println("[日志] 耗时: " + elapsed + "ms");
                return result;
            }
        );
    }
}

// 使用
UserService proxy = LogProxy.createProxy(new UserServiceImpl());
proxy.save("张三");
```

## 四、行为型模式

### 4.1 策略模式（Strategy）

定义一系列算法，把每个算法封装起来，并且使它们可以相互替换。

```java
// 策略接口
interface PaymentStrategy {
    void pay(double amount);
}

// 具体策略
class AlipayStrategy implements PaymentStrategy {
    public void pay(double amount) {
        System.out.println("使用支付宝支付 " + amount + "元");
    }
}
class WechatPayStrategy implements PaymentStrategy {
    public void pay(double amount) {
        System.out.println("使用微信支付 " + amount + "元");
    }
}

// 上下文
class Order {
    private PaymentStrategy paymentStrategy;
    public void setPayment(PaymentStrategy strategy) {
        this.paymentStrategy = strategy;
    }
    public void checkout(double amount) {
        paymentStrategy.pay(amount);
    }
}

// 使用
Order order = new Order();
order.setPayment(new AlipayStrategy());
order.checkout(99.0);
```

### 4.2 观察者模式（Observer）

定义对象之间的一对多依赖，当一个对象状态改变时，所有依赖它的对象都得到通知。

```java
// Java 内置支持
import java.util.Observable;
import java.util.Observer;

// 被观察者
class WeatherData extends Observable {
    private float temperature;
    
    public void setMeasurement(float temperature) {
        this.temperature = temperature;
        setChanged();                     // 标记状态已改变
        notifyObservers(temperature);     // 通知所有观察者
    }
}

// 观察者
class Display implements Observer {
    private String name;
    public Display(String name) { this.name = name; }
    
    @Override
    public void update(Observable o, Object arg) {
        System.out.println(name + " 收到温度更新: " + arg);
    }
}

// 使用
WeatherData weather = new WeatherData();
weather.addObserver(new Display("手机 App"));
weather.addObserver(new Display("智能手表"));
weather.setMeasurement(25.5f);
```

### 4.3 责任链模式（Chain of Responsibility）

多个对象都有机会处理请求，避免请求的发送者和接收者耦合。

```java
abstract class Handler {
    protected Handler next;
    
    public void setNext(Handler next) { this.next = next; }
    
    public void handle(int level) {
        if (canHandle(level)) {
            process();
        } else if (next != null) {
            next.handle(level);
        }
    }
    
    protected abstract boolean canHandle(int level);
    protected abstract void process();
}

class Level1Handler extends Handler {
    protected boolean canHandle(int level) { return level <= 1; }
    protected void process() { System.out.println("L1 处理完成"); }
}
class Level2Handler extends Handler {
    protected boolean canHandle(int level) { return level <= 2; }
    protected void process() { System.out.println("L2 处理完成"); }
}
class Level3Handler extends Handler {
    protected boolean canHandle(int level) { return level <= 3; }
    protected void process() { System.out.println("L3 处理完成"); }
}

// 使用
Handler h1 = new Level1Handler();
Handler h2 = new Level2Handler();
Handler h3 = new Level3Handler();
h1.setNext(h2);
h2.setNext(h3);

h1.handle(2);  // L1 无法处理 → L2 处理 → 完成
```

### 4.4 模板方法模式（Template Method）

定义一个操作中的算法骨架，将一些步骤延迟到子类中。

```java
abstract class DataProcessor {
    // 模板方法（final 防止子类重写）
    public final void process() {
        loadData();
        if (wantParse()) {           // 钩子方法
            parseData();
        }
        saveData();
        cleanUp();
    }
    
    protected abstract void loadData();
    protected abstract void parseData();
    protected abstract void saveData();
    protected void cleanUp() { }      // 默认实现
    protected boolean wantParse() { return true; }  // 钩子
}

class CSVProcessor extends DataProcessor {
    protected void loadData() { System.out.println("加载 CSV"); }
    protected void parseData() { System.out.println("解析 CSV"); }
    protected void saveData() { System.out.println("保存数据"); }
}

class JSONProcessor extends DataProcessor {
    protected void loadData() { System.out.println("加载 JSON"); }
    protected void parseData() { System.out.println("解析 JSON"); }
    protected void saveData() { System.out.println("保存数据"); }
    protected boolean wantParse() { return false; }  // 不需要解析
}
```

## 五、设计模式在 Spring 中的应用

### 5.1 单例模式

Spring Bean 默认作用域就是单例：

```java
@Component  // 默认 scope = singleton
public class UserService { }
```

### 5.2 工厂模式

```java
// BeanFactory 是典型工厂模式
ApplicationContext context = new AnnotationConfigApplicationContext("com.example");
UserService userService = context.getBean(UserService.class);
```

### 5.3 代理模式

```java
// Spring AOP 使用 JDK 动态代理或 CGLIB
@Aspect
@Component
public class LoggingAspect {
    @Around("execution(* com.example.service.*.*(..))")
    public Object logAround(ProceedingJoinPoint joinPoint) throws Throwable {
        System.out.println("方法执行前");
        Object result = joinPoint.proceed();
        System.out.println("方法执行后");
        return result;
    }
}
```

### 5.4 模板方法

```java
// JdbcTemplate、RestTemplate、RedisTemplate 都是模板方法模式
jdbcTemplate.query("SELECT * FROM users", (rs, rowNum) -> {
    User user = new User();
    user.setId(rs.getLong("id"));
    user.setName(rs.getString("name"));
    return user;
});
```

### 5.5 观察者模式

```java
// Spring 事件机制
@Component
public class OrderEvent extends ApplicationEvent {
    public OrderEvent(Object source) { super(source); }
}

@Component
public class OrderEventListener {
    @EventListener
    public void handleOrderEvent(OrderEvent event) {
        System.out.println("订单事件触发");
    }
}
```

## 六、如何选择设计模式

| 场景 | 推荐模式 |
|------|----------|
| 需要确保一个类只有一个实例 | 单例模式 |
| 对象创建过程复杂 | 建造者模式 |
| 需要动态扩展对象功能 | 装饰器模式 |
| 需要控制对象访问 | 代理模式 |
| 算法可以相互替换 | 策略模式 |
| 一对多的依赖关系 | 观察者模式 |
| 请求需要多级处理 | 责任链模式 |
| 算法骨架固定，子步骤可变 | 模板方法模式 |
| 不兼容的接口需要协同工作 | 适配器模式 |

## 七、总结

设计模式是比较"元"的知识，它是经验的结晶。初学者不需要一次性掌握所有 23 种模式，建议：

1. **先掌握常用模式**：单例、工厂、代理、策略、模板方法、观察者
2. **结合框架学习**：在 Spring、MyBatis 等框架中找设计模式的影子
3. **切忌过度设计**：不要为了用模式而用模式，简单就是最好的
4. **理解而非背诵**：理解背后的设计原则比记住模式更重要

设计模式不是银弹，但掌握它们能让你的代码质量更上一层楼。
