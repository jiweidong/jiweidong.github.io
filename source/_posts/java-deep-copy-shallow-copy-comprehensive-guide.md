---
title: Java 深拷贝与浅拷贝：Cloneable、序列化、JSON 方式全面对比
date: 2026-06-27 08:00:03
tags:
  - Java
  - 面试
  - 基础
categories:
  - Java
  - Java基础
author: 东哥
---

# Java 深拷贝与浅拷贝：Cloneable、序列化、JSON 方式全面对比

## 一、开篇：一个 ArrayList 引发的 bug

来看看一个真实场景：

```java
List<String> original = new ArrayList<>();
original.add("A");
original.add("B");

List<String> copied = original;  // 这叫"拷贝"吗？
copied.add("C");

System.out.println(original);  // [A, B, C]  咦？original 也被改了！
```

这不是拷贝，这是**引用赋值**——两个变量指向同一个对象。

## 二、三种拷贝层次

### 2.1 引用赋值（不是拷贝）

```java
Student s1 = new Student("张三", 20);
Student s2 = s1;  // 只是复制了引用
s2.setName("李四");
System.out.println(s1.getName()); // "李四" — 改了 s2，s1 也变了
```

### 2.2 浅拷贝（Shallow Copy）

```java
public class Student implements Cloneable {
    private String name;
    private Address address;  // 引用类型字段
    
    @Override
    protected Object clone() throws CloneNotSupportedException {
        return super.clone();  // Object 的 clone() 是浅拷贝
    }
}
```

浅拷贝的特点：
- **基本类型**：复制值，修改不影响原对象
- **引用类型**：复制引用，修改引用对象的内容会影响原对象

```java
Student s1 = new Student("张三", new Address("北京", "朝阳区"));
Student s2 = (Student) s1.clone();

s2.setName("李四");           // ✅ 基本类型/String 不受影响
s2.getAddress().setCity("上海"); // ❌ Address 是同一个对象，s1 也被改了！
```

### 2.3 深拷贝（Deep Copy）

深拷贝递归复制所有引用对象，新对象和原对象完全独立：

```java
Student s1 = new Student("张三", new Address("北京", "朝阳区"));
Student s2 = deepCopy(s1);  // 深拷贝

s2.getAddress().setCity("上海");
System.out.println(s1.getAddress().getCity()); // 北京 — 不受影响！
```

## 三、深拷贝的七种实现方式

### 方式一：重写 clone() 逐层深拷贝

```java
public class Student implements Cloneable {
    private String name;
    private Address address;
    
    @Override
    protected Object clone() throws CloneNotSupportedException {
        Student cloned = (Student) super.clone();
        cloned.address = (Address) address.clone(); // 手动深拷贝引用字段
        return cloned;
    }
}

public class Address implements Cloneable {
    private String city;
    private String district;
    
    @Override
    protected Object clone() throws CloneNotSupportedException {
        return super.clone(); // Address 里全是基本类型/String，浅拷贝就够了
    }
}
```

**优点**：性能好，类型安全  
**缺点**：需要所有层级实现 Cloneable，代码量大，层级多时维护困难

### 方式二：序列化方式（推荐）

利用 Java 序列化机制，将对象写入流再读回来，天然实现深拷贝：

```java
@SuppressWarnings("unchecked")
public static <T extends Serializable> T deepCopyBySerialization(T obj) {
    try {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        ObjectOutputStream oos = new ObjectOutputStream(bos);
        oos.writeObject(obj);
        oos.flush();
        
        ByteArrayInputStream bis = new ByteArrayInputStream(bos.toByteArray());
        ObjectInputStream ois = new ObjectInputStream(bis);
        return (T) ois.readObject();
    } catch (Exception e) {
        throw new RuntimeException("深拷贝失败", e);
    }
}

// 使用
// 注意：所有涉及的类都需要 implements Serializable
Student copy = deepCopyBySerialization(s1);
```

**优点**：代码通用，无需每层手动实现 clone  
**缺点**：所有类必须实现 Serializable；性能比 clone 差；transient 字段会丢失

### 方式三：JSON 序列化（最常用）

```java
// 使用 Jackson
public static <T> T deepCopyByJson(T obj, Class<T> clazz) {
    try {
        ObjectMapper mapper = new ObjectMapper();
        String json = mapper.writeValueAsString(obj);
        return mapper.readValue(json, clazz);
    } catch (Exception e) {
        throw new RuntimeException("JSON深拷贝失败", e);
    }
}

// 使用 Gson
public static <T> T deepCopyByGson(T obj, Class<T> clazz) {
    Gson gson = new Gson();
    String json = gson.toJson(obj);
    return gson.fromJson(json, clazz);
}
```

**优点**：最简洁，不需要 Serializable，处理循环引用（Gson 支持）  
**缺点**：性能最差（序列化+反序列化），JSON 字段名映射问题

### 方式四：Apache Commons Lang3

```xml
<dependency>
    <groupId>org.apache.commons</groupId>
    <artifactId>commons-lang3</artifactId>
</dependency>
```

```java
// 使用 SerializationUtils
Student copy = SerializationUtils.clone(s1);
// 需要 Serializable，但一行搞定
```

### 方式五：Kryo 序列化（高性能）

```java
public static <T> T deepCopyByKryo(T obj) {
    Kryo kryo = new Kryo();
    kryo.setRegistrationRequired(false);
    
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    Output output = new Output(bos);
    kryo.writeObject(output, obj);
    output.close();
    
    Input input = new Input(new ByteArrayInputStream(bos.toByteArray()));
    return kryo.readObject(input, obj.getClass());
}
```

**优点**：性能远超 Java 序列化，不需要 Serializable  
**缺点**：额外依赖，需要配置

### 方式六：手动递归复制（控制力最强）

```java
public class DeepCopier {
    public static Map<String, Object> deepCopyMap(Map<String, Object> original) {
        Map<String, Object> copy = new HashMap<>();
        for (Map.Entry<String, Object> entry : original.entrySet()) {
            Object value = entry.getValue();
            if (value instanceof Map) {
                copy.put(entry.getKey(), deepCopyMap((Map<String, Object>) value));
            } else if (value instanceof List) {
                copy.put(entry.getKey(), deepCopyList((List<Object>) value));
            } else {
                copy.put(entry.getKey(), value); // 不可变对象/基本类型
            }
        }
        return copy;
    }
}
```

**优点**：完全可控，类型精确  
**缺点**：工作量大，容易遗漏

### 方式七：Spring BeanUtils + 深拷贝变通

Spring 的 `BeanUtils.copyProperties` 是**浅拷贝**，但可以组合成深拷贝模式：

```java
// 配合序列化实现 Spring 风格深拷贝
public static <T> T springDeepCopy(T source, Class<T> targetClass) {
    T target = BeanUtils.instantiateClass(targetClass);
    BeanUtils.copyProperties(source, target);
    // 手动处理引用字段深拷贝
    if (source.getAddress() != null) {
        Address addrCopy = new Address();
        BeanUtils.copyProperties(source.getAddress(), addrCopy);
        target.setAddress(addrCopy);
    }
    return target;
}
```

## 四、七种方式横向对比

| 方式 | 代码量 | 性能 | 需 Serializable | 类型安全 | 通用性 |
|------|--------|------|----------------|---------|--------|
| 重写 clone() | 多 | 最高 | 否 | ✅ | 差 |
| Java 序列化 | 少（工具类） | 中 | ✅ 必须 | ✅ | 好 |
| JSON 序列化 | 极少 | 最差 | 否 | ⚠️ 需传 Class | 最好 |
| Commons Lang3 | 极少 | 中 | ✅ 必须 | ✅ | 好 |
| Kryo 序列化 | 少 | 高 | 否 | ⚠️ 需配置 | 好 |
| 手动递归 | 最多 | 最高 | 否 | ✅ | 差 |
| Spring BeanUtils | 中 | 高 | 否 | ✅ | 中 |

## 五、面试现场：深拷贝常见追问

### Q1：Object 的 clone() 是浅拷贝还是深拷贝？

**深拷贝** 也不对，**浅拷贝** 也不完全对。准确说：`super.clone()` 对**基本类型是值拷贝**，对**引用类型是引用拷贝**。所以是**浅拷贝**。但如果引用类型是不可变对象（如 String、Integer），表现上与深拷贝效果一样——因为不可变对象改了就是创建新对象，不影响原对象。

### Q2：String 在浅拷贝中为什么感觉像深拷贝？

```java
Student s1 = new Student("张三", new Address());
Student s2 = (Student) s1.clone();

s2.setName("李四"); // s1.getName() 还是 "张三" — 好像深拷贝？
```

因为 `setName("李四")` 本质是 `this.name = "李四"`，String 是不可变的，修改时赋值的是一个新字符串引用。原对象的 name 仍然指向 "张三"，所以**看起来像深拷贝**。但地址字段 `address` 修改内容是 mutable 对象，就露馅了。

### Q3：为什么阿里巴巴 Java 规范禁止在 Entity 上重写 clone()？

实体类通常有复杂的关联关系，重写 clone() 容易遗漏深拷贝，导致数据共享异常。推荐使用 JSON 序列化或 BeanUtils 在 DTO 层面处理拷贝。

### Q4：深拷贝的性能如何？

大致排序（从快到慢）：

1. 手动 clone（几十 MB/s 级别）  
2. Kryo 序列化  
3. Spring BeanUtils 组合（如果层级浅）  
4. Java 原生序列化  
5. JSON 序列化（最慢，但最灵活）

实际项目中如果对象层级简单，直接手动 clone 或 JSON 序列化就够用了。百万级拷贝才需要考虑 Kryo。

## 六、实用工具类封装

```java
public class DeepCopyUtils {
    
    private static final ObjectMapper MAPPER = new ObjectMapper();
    
    // JSON 方式（通用，推荐日常使用）
    public static <T> T jsonCopy(T obj, Class<T> clazz) {
        try {
            return MAPPER.readValue(MAPPER.writeValueAsString(obj), clazz);
        } catch (Exception e) {
            throw new RuntimeException("深拷贝失败", e);
        }
    }
    
    // JSON 方式（泛型，处理 List/Map 等）
    @SuppressWarnings("unchecked")
    public static <T> T jsonCopy(T obj, TypeReference<T> typeRef) {
        try {
            return MAPPER.readValue(MAPPER.writeValueAsString(obj), typeRef);
        } catch (Exception e) {
            throw new RuntimeException("深拷贝失败", e);
        }
    }
    
    // 序列化方式（高性能，需 Serializable）
    @SuppressWarnings("unchecked")
    public static <T extends Serializable> T serialCopy(T obj) {
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            new ObjectOutputStream(bos).writeObject(obj);
            return (T) new ObjectInputStream(
                new ByteArrayInputStream(bos.toByteArray())).readObject();
        } catch (Exception e) {
            throw new RuntimeException("深拷贝失败", e);
        }
    }
}
```

## 七、不同场景推荐方案

| 场景 | 推荐方案 | 理由 |
|------|---------|------|
| 简单的 POJO/DTO | JSON 方式 | 代码最少，不需要额外配置 |
| 性能敏感的内部对象 | 手动 clone() | 性能最好 |
| 已有 Serializable 的旧系统 | Java 序列化 | 不需要额外工作 |
| 高并发、深度嵌套 | Kryo | 性能与便利的平衡 |
| RPC 调用中的参数拷贝 | JSON 方式 | 通用，传输时也有序列化流程 |

深拷贝看似简单，但选对方式能让代码质量提升不少。记住先搞清楚场景——**90% 情况下 JSON 序列化就够了**，过早优化是万恶之源。
