---
title: 【设计模式】设计模式拼图补齐：原型、备忘录、中介者、解释器与访问者五大模式实战
date: 2026-08-24 09:00:00
tags:
  - Java
  - 设计模式
  - 面试
categories:
  - Java
author: 东哥
---

# 【设计模式】设计模式拼图补齐：原型、备忘录、中介者、解释器与访问者五大模式实战

## 为什么是这五个模式？

单例、工厂、策略、责任链这些「明星模式」大家都熟，但面试官最喜欢在结尾来一句：「除了常用的，你还了解哪些设计模式？」——这时候能流畅讲出下面五个「冷门」模式，才是真正的加分项。它们不是不重要，而是应用场景更隐蔽：**原型藏在克隆里、备忘录藏在编辑器撤销里、中介者藏在消息中间件里、解释器藏在表达式引擎里、访问者藏在编译器里**。

## 一、原型模式（Prototype）：用克隆代替 new

### 场景
创建对象成本高（大量 IO、复杂初始化、数据库查询），且对象之间只有少量差异时，直接复制原型比 `new` 再初始化快得多。典型应用：Spring 的 `@Scope("prototype")`、`ArrayList` 的 `clone()`、原型注册表。

### 实现要点
Java 的 `Cloneable` 接口是**标记接口**（不实现任何方法），真正的复制逻辑在 `Object.clone()`，它是 protected 的 native 方法，**浅拷贝**：基本类型和引用复制，但引用指向的**对象不复制**。

```java
public class Order implements Cloneable {
    private List<Item> items = new ArrayList<>();

    @Override
    public Order clone() {
        try {
            Order copy = (Order) super.clone();   // 浅拷贝
            copy.items = new ArrayList<>(this.items); // 手动深拷贝可变引用
            return copy;
        } catch (CloneNotSupportedException e) {
            throw new AssertionError(e);
        }
    }
}
```

### 浅拷贝 vs 深拷贝
| 方式 | 原理 | 深拷贝程度 | 性能 |
| --- | --- | --- | --- |
| `Object.clone()` | native 内存复制 | 浅 | 最快 |
| 手动 clone + 复制引用 | 逐个深拷贝 | 可控 | 快 |
| 序列化 | 流式拷贝 | 深（但要求可序列化） | 慢 |
| JSON（Jackson/Gson） | 序列化到字符串再反序列化 | 深 | 最慢 |

**面试高频追问**：`clone()` 为什么不建议用于生产？—— 浅拷贝有共享引用隐患；深拷贝要手写大量代码；`Cloneable` 是标记接口，不强制实现就抛 `CloneNotSupportedException`；业界更推荐**拷贝构造器**或 **Builder** 模式替代。

## 二、备忘录模式（Memento）：时光回溯的快照

### 场景
需要保存对象某一时刻的完整状态，并在之后恢复到该状态。经典应用：IDE/编辑器的 Ctrl+Z 撤销、游戏存档、数据库事务的回滚日志。

### 三角色结构
- **Originator（发起人）**：业务对象，负责创建备忘录和从备忘录恢复；
- **Memento（备忘录）**：状态快照，对外只读；
- **Caretaker（管理者）**：持有备忘录列表，不修改内容。

```java
// 备忘录：不可变快照
public record EditorState(String content, int cursorPos) {}

// 发起人
public class Editor {
    private String content;
    private int cursorPos;

    public EditorState save() {
        return new EditorState(content, cursorPos); // record 天然不可变
    }

    public void restore(EditorState state) {
        this.content = state.content();
        this.cursorPos = state.cursorPos();
    }
}

// 管理者：撤销栈
public class History {
    private final Deque<EditorState> stack = new ArrayDeque<>();
    public void push(EditorState s) { stack.push(s); }
    public EditorState pop() { return stack.pop(); }
}
```

**实践提醒**：快照会占内存，大对象建议只存差异（diff）而非全量快照；配合命令模式（Command）实现「可撤销的操作」是教科书级组合。

## 三、中介者模式（Mediator）：让同事之间不再互相认识

### 场景
多个对象两两交互会形成「网状依赖」，引入一个中介者把交互集中起来，变成「星形结构」：所有对象只和中介者通信。经典应用：聊天室（用户 ↔ 聊天服务器）、MVC 中的 Controller（View 与 Model 通过 Controller 交互）、**消息中间件**（生产者/消费者通过 Broker 解耦）、Java AWT 的 `EventQueue`。

```java
// 中介者接口
public interface ChatMediator {
    void sendMessage(String msg, User user);
    void addUser(User user);
}

// 同事类：只持有中介者引用
public class User {
    private final String name;
    private final ChatMediator mediator;

    public User(String name, ChatMediator mediator) {
        this.name = name;
        this.mediator = mediator;
    }

    public void send(String msg) {
        mediator.sendMessage(msg, this); // 自己不关心发给谁
    }
    public void receive(String msg) {
        System.out.println(name + " 收到: " + msg);
    }
}

// 具体中介者：负责路由
public class ChatRoom implements ChatMediator {
    private final List<User> users = new ArrayList<>();
    public void addUser(User u) { users.add(u); }
    public void sendMessage(String msg, User from) {
        users.forEach(u -> { if (u != from) u.receive(from.getName() + ": " + msg); });
    }
}
```

### 与观察者模式的区别（面试必问）
| 维度 | 中介者 | 观察者 |
| --- | --- | --- |
| 通信方向 | 多对多 → 集中到中介 | 一对多发布/订阅 |
| 交互双方 | 不直接认识，只认识中介 | 观察者注册到被观察者 |
| 典型例子 | 聊天室、MVC Controller | 事件监听、消息发布订阅 |
| 关注点 | 交互逻辑集中管理 | 状态变化通知扩散 |

**一句话区分**：观察者解决「通知扩散」，中介者解决「交互耦合」。

## 四、解释器模式（Interpreter）：用对象表达语法规则

### 场景
定义一门语言的文法，用对象树表示句子并解释执行。经典应用：正则表达式引擎、SQL 解析器、SpEL（Spring 表达式）、模板引擎、规则引擎（Drools）。

### 核心思路
每个语法规则对应一个类，组合成**抽象语法树（AST）**，然后递归求值。

```java
// 抽象表达式
interface Expression { int interpret(Map<String, Integer> ctx); }

// 终结符表达式：变量
record Variable(String name) implements Expression {
    public int interpret(Map<String, Integer> ctx) { return ctx.get(name); }
}

// 非终结符表达式：加法
record Add(Expression left, Expression right) implements Expression {
    public int interpret(Map<String, Integer> ctx) {
        return left.interpret(ctx) + right.interpret(ctx);
    }
}

// 使用：解析 "a + b + 10"
Expression expr = new Add(new Variable("a"),
        new Add(new Variable("b"), new Constant(10)));
System.out.println(expr.interpret(Map.of("a", 3, "b", 5))); // 18
```

**实战教训**：解释器模式类数量随文法规模爆炸，适合**小型、稳定**的文法；复杂语言请直接用现成的解析库（ANTLR、JavaCC），不要自己造轮子。Spring 的 SpEL、MyBatis 的 `${}` 解析内部都有解释器思想的影子。

## 五、访问者模式（Visitor）：给对象结构「开外挂」

### 场景
对象结构稳定（类很少变），但操作频繁增加——把操作从对象里抽出来做成 Visitor，避免改每个类。核心机制是**双分派（Double Dispatch）**：运行时先确定对象实际类型，再确定 Visitor 实际类型。

### 经典实现
```java
interface Element { void accept(Visitor v); }

class Book implements Element {
    public void accept(Visitor v) { v.visit(this); } // 第一重分派
}
class Fruit implements Element {
    public void accept(Visitor v) { v.visit(this); }
}

interface Visitor {
    void visit(Book book);
    void visit(Fruit fruit);
}

// 新增操作：打折——不用改 Book/Fruit，只加 Visitor
class DiscountVisitor implements Visitor {
    public void visit(Book book)  { System.out.println("图书 8 折"); }
    public void visit(Fruit fruit){ System.out.println("水果 9 折"); }
}

// 客户端
for (Element e : List.of(new Book(), new Fruit())) {
    e.accept(new DiscountVisitor()); // accept 里 this 是动态类型 → 双分派
}
```

### 真实应用
- **ASM 字节码框架**：`ClassVisitor`/`MethodVisitor` 就是访问者模式，遍历类文件结构做插桩；
- **编译器和静态分析工具**：遍历 AST 做类型检查、代码生成；
- **Spring 的 `BeanDefinitionVisitor`**：遍历 Bean 定义做占位符替换。

**缺点（面试要主动说）**：新增 Element 类型要改所有 Visitor，违反开闭原则；破坏了封装（Visitor 需要访问对象内部状态）。

## 五大模式一图对比

| 模式 | 一句话本质 | 典型场景 | 面试关键词 |
| --- | --- | --- | --- |
| 原型 | 克隆代替 new | 高成本对象复制、Spring Prototype | Cloneable、浅/深拷贝 |
| 备忘录 | 状态快照与回滚 | 编辑器撤销、游戏存档 | Originator/Caretaker |
| 中介者 | 网状变星形 | 聊天室、MVC、消息中间件 | 解耦、集中交互 |
| 解释器 | 用对象表达文法 | 表达式引擎、SpEL、规则引擎 | AST、终结符/非终结符 |
| 访问者 | 操作与结构分离 | ASM、编译器、静态分析 | 双分派 |

## 面试追问总结

1. **原型模式里 clone() 为什么是浅拷贝？** native 实现只复制字段值，引用指向同一对象；
2. **备忘录怎么避免快照过大？** 只存差异、快照压缩、限制历史栈深度；
3. **中介者和观察者怎么选？** 交互集中且双向 → 中介者；状态单向扩散 → 观察者；
4. **解释器模式什么时候该放弃？** 文法变复杂、类爆炸时，改用 ANTLR 等解析器；
5. **访问者模式的双分派怎么理解？** 第一次分派在 `accept(v)` 里（动态绑定 this），第二次在 `v.visit(this)`（动态绑定 Visitor 类型）。

把这五个模式装进自己的工具箱，下次面试被问「设计模式还有哪些」，你就能从容地讲出别人讲不出的深度。
