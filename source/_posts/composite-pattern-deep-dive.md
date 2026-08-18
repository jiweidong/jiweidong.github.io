---
title: 【设计模式】组合模式深度解析：从文件系统到树形结构的设计之道
date: 2026-08-18 08:00:00
tags:
  - Java
  - 设计模式
  - 组合模式
  - 数据结构
categories:
  - Java
  - 设计模式
author: 东哥
---

# 【设计模式】组合模式深度解析：从文件系统到树形结构的设计之道

## 面试官：你用过组合模式吗？它在哪些框架里出现过？

组合模式（Composite Pattern）是结构型设计模式里"存在感"最强的一个——**它完美解决树形结构的问题**，而树形结构在业务里无处不在：文件系统、组织架构、菜单权限、分类目录、表达式解析……

本文从原理到源码到实战，一次讲透。

---

## 一、组合模式解决什么问题？

**核心痛点：让"单个对象"和"对象的组合"具有一致的使用方式。**

看一个最典型的例子——文件系统：

- 文件（File）是叶子节点，不能包含子节点；
- 文件夹（Directory）是容器节点，可以包含文件和子文件夹。

没有组合模式时，你的代码会写成：

```java
// 不使用组合模式：到处都是类型判断
public void print(Node node) {
    if (node instanceof File) {
        System.out.println("文件: " + node.getName());
    } else if (node instanceof Directory) {
        System.out.println("目录: " + node.getName());
        for (Node child : ((Directory) node).getChildren()) {
            print(child);   // 递归，还得强转
        }
    }
}
```

调用方必须知道每个节点的具体类型，才能决定怎么处理。**一旦新增节点类型，所有遍历代码都要改**——这违反了开闭原则。

组合模式的解法：**让叶子节点和容器节点实现同一个接口，容器内部持有子节点集合**。调用方无需关心处理的是文件还是文件夹，统一调用 `print()` 即可：

```java
public void print(Node node) {
    node.print();   // 文件和目录都实现了 print，内部自己处理
}
```

---

## 二、模式结构：三种角色

| 角色 | 说明 | 示例 |
|------|------|------|
| Component（抽象构件） | 叶子与容器的公共接口 | `FileSystemNode` |
| Leaf（叶子构件） | 无子节点，实现接口的具体行为 | `File` |
| Composite（容器构件） | 持有子节点集合，管理增删，实现接口并递归委托 | `Directory` |

```java
// Component：抽象构件
public abstract class FileSystemNode {
    protected String name;
    public FileSystemNode(String name) { this.name = name; }
    public abstract void print(int depth);
    // 默认实现：叶子节点不支持添加子节点
    public void add(FileSystemNode node) {
        throw new UnsupportedOperationException("叶子节点不支持添加");
    }
}

// Leaf：文件
public class File extends FileSystemNode {
    private long size;
    public File(String name, long size) { super(name); this.size = size; }

    @Override
    public void print(int depth) {
        System.out.println("  ".repeat(depth) + "📄 " + name + " (" + size + "B)");
    }
}

// Composite：目录
public class Directory extends FileSystemNode {
    private List<FileSystemNode> children = new ArrayList<>();

    public Directory(String name) { super(name); }

    @Override
    public void add(FileSystemNode node) { children.add(node); }

    public void remove(FileSystemNode node) { children.remove(node); }

    public List<FileSystemNode> getChildren() { return children; }

    @Override
    public void print(int depth) {
        System.out.println("  ".repeat(depth) + "📁 " + name + "/");
        for (FileSystemNode child : children) {
            child.print(depth + 1);   // 递归：目录的打印 = 子节点打印的叠加
        }
    }
}
```

**递归是组合模式的灵魂**：容器节点的行为 = 子节点行为的叠加，天然形成递归结构。

---

## 三、透明式 vs 安全式：两个变体

这是组合模式最经典的"二选一"设计权衡，面试官最爱问。

### 透明式（Transparent）
在 Component 接口中**定义所有方法**（包括 add/remove），叶子节点也"假装"有这些方法，调用时抛异常或空实现。

```java
public abstract class Node {
    public abstract void print();
    public void add(Node node) { throw new UnsupportedOperationException(); }
}
```

优点：叶子与容器完全一致，客户端无需任何判断（**透明**）。缺点：叶子节点暴露了不该有的方法，违背接口隔离原则。

### 安全式（Safe）
add/remove 只定义在 Composite 里，Component 只定义公共业务方法。

优点：接口职责清晰，叶子不会有 add。缺点：客户端**必须用 instanceof 判断**再强转，丧失透明性。

**选型建议**：业务中树形结构如果"添加子节点"是常态（菜单、目录），推荐**透明式**（方便统一递归）；如果叶子与容器行为差异大，用**安全式**。

---

## 四、JDK 与框架中的组合模式

组合模式在 Java 生态里无处不在，举几个能"背出来"的例子：

### 1. java.awt.Container / Component
`Container` 是容器，`Component` 是抽象构件。`Container.add(Component)` 组合子组件，`paint()` 方法递归调用所有子组件的 `paint()`——**教科书级的组合模式**。

### 2. HashMap 的树化节点（TreeNode）
JDK 8 的 HashMap 中，链表长度超过 8 会转红黑树。`TreeNode` 既是树的节点又持有 `next`/`prev` 链表指针，`treeify()` 递归构建树结构——虽然是内部实现，但体现了树形结构的递归思想。

### 3. Spring 的 CompositePropertySource
Spring 环境抽象中，`CompositePropertySource` 持有多个 `PropertySource`（叶子），`getProperty(name)` 遍历所有子源查找——**组合模式用于"统一入口聚合多个数据源"**。

### 4. MyBatis 的 SqlNode 组合
动态 SQL 的 `<if>`、`<where>`、`<foreach>` 都实现 `SqlNode` 接口，`MixedSqlNode` 持有多个子 SqlNode，`apply()` 递归拼接 SQL。**动态 SQL 的嵌套本质就是组合树**。

### 5. 文件遍历工具
`java.nio.file.Files.walk()` 返回树形遍历流，本质也是递归遍历目录树。

面试时能说出 **AWT Container、Spring CompositePropertySource、MyBatis SqlNode** 三个例子，就足以证明你真正理解了这个模式。

---

## 五、实战场景：菜单权限树

业务中最常见的组合模式应用——菜单/组织架构树：

```java
// 菜单树：目录菜单可以挂子菜单，按钮菜单是叶子
public class Menu {
    private Long id;
    private String name;
    private Integer type;          // 1=目录 2=菜单 3=按钮
    private List<Menu> children;   // 组合核心：子节点集合

    // 构建树：将扁平列表转成树
    public static List<Menu> buildTree(List<Menu> flatList) {
        Map<Long, Menu> map = flatList.stream()
                .collect(Collectors.toMap(Menu::getId, m -> m));
        List<Menu> roots = new ArrayList<>();
        for (Menu menu : flatList) {
            if (menu.getParentId() == 0) {
                roots.add(menu);
            } else {
                Menu parent = map.get(menu.getParentId());
                if (parent != null) parent.getChildren().add(menu);
            }
        }
        return roots;
    }

    // 递归输出整棵树（权限树转前端树形组件）
    public void toTreeJson() {
        // 递归序列化 children
    }
}
```

配套的递归遍历套路（DFS 三件套）：
- **递归找所有叶子**：`node.getChildren().isEmpty()` 即叶子；
- **递归统计节点数**：1 + sum(子节点数)；
- **递归过滤权限**：从根往下按条件剪枝。

---

## 六、组合模式的边界与坑

### 1. 和装饰器模式的区别（高频混淆点）
- **组合模式**：强调"部分-整体"的树形结构，容器包含叶子，**递归聚合**；
- **装饰器模式**：强调"增强"，包装者和被包装者**类型相同但职责叠加**（Java IO 流）。

区分口诀：组合模式是"一棵树"，装饰器是"一层皮"。

### 2. 和迭代器模式的关系
组合模式经常和迭代器模式配合：遍历组合树时，用迭代器封装递归逻辑，客户端无需感知树结构（如菜单树的遍历器）。

### 3. 常见坑
- **循环引用**：子节点指向祖先节点会造成无限递归（构建树时务必校验 parentId 不能形成环）；
- **深树递归栈溢出**：层级特别深（上万层）时递归会爆栈，可考虑改迭代 + 显式栈；
- **叶子节点误调用 add**：透明式实现中要给出清晰异常信息，便于排查。

---

## 七、面试官连环追问

**Q1：组合模式的本质是什么？**
把"整体与部分"的关系抽象成同一接口，用递归实现树形结构的一致处理，使客户端无需区分叶子与容器。**一句话：用统一接口 + 递归，让树形结构用起来像单个对象**。

**Q2：透明式和安全式你怎么选？**
多数业务场景选透明式（统一递归方便）；如果叶子与容器行为差异巨大、不允许误操作，选安全式。回答时能指出两者在"接口隔离 vs 使用透明"上的权衡即可。

**Q3：组合模式在 JDK 里的例子？**
AWT 的 Container/Component、HashMap 的 TreeNode、`javax.swing` 的树组件。框架层面：Spring 的 CompositePropertySource、MyBatis 的 SqlNode 组合、Shiro 的权限树。

**Q4：组合模式有哪些缺点？**
设计上会"过度通用"：透明式让叶子承担无意义的方法；树结构复杂时递归性能差、难调试；新增行为时若走"给每个节点加方法"的老路会破坏一致性。**改进：结合访问者模式分离操作**。

**Q5：什么业务场景用组合模式？**
菜单权限树、组织架构、文件目录、分类树（商品类目）、表达式语法树、地区级联选择器——**凡是"整体包含部分、部分又可能包含整体"的递归结构**。

---

## 八、总结

组合模式用一张图就能记住：

```
Component（接口/抽象类：统一业务方法）
├── Leaf（叶子：实现方法，无子节点）
└── Composite（容器：持有 List<Component>，递归委托）
```

三个关键词：**统一接口、递归聚合、一致使用**。面试时按"解决什么问题 → 结构 → 透明/安全变体 → JDK 实例 → 实战树构建"的顺序讲，逻辑完整且干货密度高。日常开发中遇到树形数据（菜单、组织、类目），先想组合模式，再配一个递归构建工具类，代码会优雅很多。
