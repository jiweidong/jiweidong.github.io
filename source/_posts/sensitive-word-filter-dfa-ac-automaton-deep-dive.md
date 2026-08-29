---
title: 【Java 实战】敏感词过滤深度实战：DFA 状态机与 AC 自动机原理与实现
date: 2026-08-29 08:00:00
tags:
  - Java
  - 算法
  - 字符串
  - 面试
categories:
  - Java
author: 东哥
---

# 【Java 实战】敏感词过滤深度实战：DFA 状态机与 AC 自动机原理与实现

## 面试官：用户发了一条评论，你怎么在 10ms 内完成敏感词检测？敏感词库有 10 万条、文本 1000 字。

很多人的第一反应是 `for` 循环 + `String.contains()`，或者正则表达式一把梭。但敏感词库 10 万条、每条平均 4 个词，正则引擎会退化到 O(词库大小 × 文本长度) 甚至更糟，10ms 根本打不住。这一篇我们从**暴力匹配 → DFA 状态机 → AC 自动机**一路演进，讲透敏感词过滤的底层原理与工程实现。

## 一、先看暴力方案的性能灾难

### 1.1 逐个 contains 匹配

```java
// 暴力方案：10万敏感词 × 1000字文本 = 1亿次子串比较
for (String word : sensitiveWords) {
    if (text.contains(word)) {
        return word;
    }
}
```

`contains` 底层是 KMP 或朴素匹配，单次复杂度 O(n×m)。10 万次调用，最坏情况就是**亿级字符比较**，再叠加 GC 压力，线上必然超时。

### 1.2 正则表达式方案

```java
String regex = "(" + String.join("|", words) + ")";
Pattern p = Pattern.compile(regex);
Matcher m = p.matcher(text);
```

正则引擎的 `|` 分支匹配在最坏情况下是指数级的（回溯爆炸），10 万分支的正则基本不可用。而且 Java 正则默认不支持**同时匹配多个重叠词**的优雅处理。

**核心矛盾**：敏感词检测本质是「多模式串匹配」问题，而 contains/正则都是「单模式串匹配」思路。要快，就得把 10 万条词**预处理成一棵共用前缀的树**——这就是 Trie（字典树）。

## 二、DFA 状态机：敏感词过滤的地基

### 2.1 什么是 DFA

DFA（Deterministic Finite Automaton，确定性有限自动机）由五元组构成：状态集合、输入符号集合、转移函数、初始状态、接受状态集合。简单说就是：**读入一个字符，根据当前状态和字符决定下一个状态，全程无回溯**。

敏感词过滤中，我们通常用「字典树形式的 DFA」：每个节点是一个状态，边是字符转移，根节点是初始状态，词尾节点是接受状态。

### 2.2 构建敏感词树

以「赌博」「博彩」「彩票」为例构建：

```
          根
        / | \
       赌  博  彩
      /    |    |
     博    彩   票
    /      |
   彩      票?  (博彩 词尾)
  /
 票  (赌博彩? 非词，忽略)
```

Java 实现（基于 HashMap 的 DFA，空间换时间的经典做法）：

```java
public class DfaSensitiveFilter {

    /** 状态节点：key 为字符，value 为子节点 */
    private final Map<Character, Object> root = new HashMap<>();
    /** 词尾结束标志 */
    private static final char END = '\u0000';

    /** 构建 DFA，支持批量加载 */
    public void loadWords(Collection<String> words) {
        for (String word : words) {
            if (word == null || word.isEmpty()) continue;
            Map<Character, Object> node = root;
            for (int i = 0; i < word.length(); i++) {
                char c = word.charAt(i);
                Object child = node.get(c);
                if (child == null) {
                    Map<Character, Object> next = new HashMap<>();
                    node.put(c, next);
                    node = next;
                } else {
                    node = (Map<Character, Object>) child;
                }
            }
            // 词尾打标记（不覆盖已有词尾）
            node.putIfAbsent(END, null);
        }
    }

    /** 检测并替换敏感词 */
    public String filter(String text, char replacement) {
        StringBuilder sb = new StringBuilder(text);
        for (int i = 0; i < sb.length(); i++) {
            Map<Character, Object> node = root;
            int j = i;
            boolean hit = false;
            while (j < sb.length()) {
                Object child = node.get(sb.charAt(j));
                if (child == null) break;              // 该分支断了
                node = (Map<Character, Object>) child;
                if (node.containsKey(END)) {            // 走到词尾，命中！
                    hit = true;
                    break;
                }
                j++;
            }
            if (hit) {
                // 把 [i, j] 区间全部替换
                for (int k = i; k <= j; k++) {
                    sb.setCharAt(k, replacement);
                }
                i = j; // 跳跃到词尾，避免重叠误判
            }
        }
        return sb.toString();
    }
}
```

### 2.3 复杂度分析

- **构建**：O(总词长)，10 万词一次性构建毫秒级完成。
- **查询**：最坏 O(文本长度 × 敏感词最大长度)，但**平均情况接近 O(n)**，因为大多数分支在第一个字符就断了。1000 字文本检测在 1ms 内完成。
- **内存**：HashMap 方案每个节点是一个 Map，10 万词大约消耗 30~60MB（可用数组或 Double-Array Trie 压缩到几 MB）。

### 2.4 DFA 的局限

DFA 的问题是**每次匹配都要从根节点重新开始**。文本「中国赌博合法吗」检测「赌博」时，匹配到「赌」后如果发现后面不是「博」，指针就得退回重新找——这就是「回溯」。文本越长、词越碎，浪费越多。

有没有一种算法，让**匹配失败时指针不后退**？有——AC 自动机。

## 三、AC 自动机：一次扫描完成多模式匹配

### 3.1 核心思想

AC 自动机（Aho–Corasick） = **Trie + KMP 的失配指针**。它把 KMP 的「单模式失配回退」推广到「多模式」：匹配失败时，通过 **fail 指针**跳到当前已匹配后缀的最长前缀处继续匹配，**主串指针永不回溯**，一次扫描 O(n) 找出所有敏感词。

### 3.2 两个关键指针

- **fail 指针**：节点 u 的 fail 指向「u 对应的字符串的最长真后缀」在 Trie 中能匹配到的节点。根节点的 fail 指向自己。
- **输出（output）**：每个节点记录「从根到该节点的字符串」以及「沿 fail 链能到达的所有词尾」，这样命中一个节点就能输出所有以它为后缀的敏感词。

```
例子：words = {he, she, his, hers}
              root
            /   |   \
          h     s    ...
        /      / \
      e       h   e
     / \      |
    r   *     i
    |         |
    *         s
              |
              *
   * 表示词尾；虚线是 fail 指针（示意）
   e(r).fail = e(在 she 中的 e)? → 需要 BFS 构建
```

### 3.3 构建 fail 指针（BFS 层序构建）

```java
public class AcAutomaton {

    private static final int MAX_NODES = 500_000;
    private final int[][] next = new int[MAX_NODES][256]; // 字符集表
    private final int[] fail = new int[MAX_NODES];
    private final boolean[] out = new boolean[MAX_NODES];
    private int nodeCnt = 1; // 0 号是根

    public void insert(String word) {
        int p = 0;
        for (char c : word.toCharArray()) {
            int idx = c & 0xFF;
            if (next[p][idx] == 0) next[p][idx] = nodeCnt++;
            p = next[p][idx];
        }
        out[p] = true; // 词尾
    }

    /** BFS 构建 fail 指针 */
    public void build() {
        Deque<Integer> queue = new ArrayDeque<>();
        // 第一层字符直接指向根
        for (int c = 0; c < 256; c++) {
            if (next[0][c] != 0) {
                fail[next[0][c]] = 0;
                queue.offer(next[0][c]);
            }
        }
        while (!queue.isEmpty()) {
            int u = queue.poll();
            for (int c = 0; c < 256; c++) {
                int v = next[u][c];
                if (v != 0) {
                    // 核心：失配指针 = 父节点失配指针的同字符孩子（若没有则沿链继续，等价于补全 goto）
                    fail[v] = next[fail[u]][c] == 0 ? 0 : next[fail[u]][c];
                    // 输出合并：命中 v 等价于同时命中 fail[v] 上的词尾
                    out[v] |= out[fail[v]];
                    queue.offer(v);
                } else {
                    // 补全 goto 表：让失配时的转移也变成 O(1)
                    next[u][c] = next[fail[u]][c];
                }
            }
        }
    }

    /** 一次扫描，返回所有命中的敏感词（区间） */
    public List<int[]> search(String text) {
        List<int[]> hits = new ArrayList<>();
        int p = 0;
        for (int i = 0; i < text.length(); i++) {
            int c = text.charAt(i) & 0xFF;
            p = next[p][c]; // 失败时自动沿 fail 跳转（goto 已补全）
            if (out[p]) {
                // 找到以 i 结尾的敏感词，长度需回溯 fail 链获取（工程上可记录 depth）
                hits.add(new int[]{i, p});
            }
        }
        return hits;
    }
}
```

> 工程优化：字符集 256 的二维数组在稀疏时浪费内存，可换 `HashMap` 子节点 + fail 跳转的写法（理解原理后二选一）；需要「命中的词是什么」时，在每个节点记录 `depth`（从根到该节点的长度）并在命中时沿 fail 链收集词尾节点。

### 3.4 复杂度对比

| 方案 | 预处理 | 单次扫描 | 内存 | 适用场景 |
|---|---|---|---|---|
| 暴力 contains | O(1) | O(词数×n×m) | 极低 | 词库极小、非实时 |
| 正则 | O(词数) | 最坏指数级 | 低 | 词库 < 50 条 |
| DFA(Trie) | O(总词长) | O(n×词长) 平均 O(n) | 中 | 词库 < 1 万、实现简单 |
| **AC 自动机** | O(总词长) | **O(n) 严格** | 中高 | **词库大、QPS 高、必须稳定延迟** |

### 3.5 生产级注意点

1. **扫描与替换分离**：检测返回命中区间列表，替换逻辑单独做（支持不同策略：替换 `*`、直接删除、人工审核标记）。
2. **skip 字符处理**：用户会输入「赌 博」「赌_博」绕过。生产方案：构建时忽略空白/特殊符号，或扫描时把 `_`、空格等映射为跳过标记。
3. **拼音/谐音变体**：单纯 AC 无法覆盖「du bo」。工程做法是**拼音归一化**：先把文本转拼音再建一个拼音 AC 树，双树并行检测。
4. **热更新**：词库变更时**双 Buffer 交替**（旧树服务中、新树构建完原子切换），避免构建期间命中率下降。
5. **结合分词**：对新闻等长文本，先 IK 分词再匹配短语级敏感词，能减少误伤（比如「建设银行」不是敏感词但「行贿」的「行」会误命中——需要上下文/白名单词表兜底）。

## 四、面试高频追问

### 追问 1：AC 自动机的 fail 指针为什么用 BFS 构建而不是 DFS？

因为 fail 指针指向的是「最长真后缀」，而**真后缀的深度一定小于当前节点深度**。BFS 按层遍历保证：处理节点 u 时，所有深度小于 u 的节点的 fail 都已构建完毕，可以直接用父节点的 fail 推导。DFS 无法保证这个拓扑序。

### 追问 2：构建时 `next[u][c] = next[fail[u]][c]` 这行是干嘛的？

这叫 **goto 表补全（trie 图）**。原始 AC 自动机失配时要 while 循环沿 fail 链跳，最坏 O(链长)。补全后，每个节点对每个字符都有确定的转移目标（要么是真实孩子，要么是失配后的等效状态），扫描时**任何字符都只需一次数组访问**，把扫描严格压到 O(n)。

### 追问 3：DFA 和 AC 自动机本质区别？

DFA 强调「确定性的状态转移、无回溯」；AC 自动机是 DFA 的一种**具体构造**（Trie + fail 链的确定性化）。实现上 DFA 敏感词过滤通常用 Trie 直接匹配（失败即回退），而 AC 自动机通过 fail 链把「回退」变成了「跳转」，所以 AC 是 DFA 思想的工程极致。

### 追问 4：10 万词、内存紧张怎么办？

- 用 **Double-Array Trie（双数组字典树）**，把 HashMap 的指针开销换成两个 int 数组，内存可降到原来的 1/5~1/10。
- 对 ASCII 字符用 256 数组、对中文用 HashMap 或双数组，**混合存储**。
- 冷热分离：高频词放内存 AC 树，长尾词放 Redis/LMDB，未命中再查。

## 五、完整工程示例（Spring Boot + AC 自动机）

```java
@Component
public class SensitiveWordService {

    private volatile AcAutomaton automaton; // volatile + 双 Buffer 热更新

    @PostConstruct
    public void init() {
        automaton = buildFromDb();
    }

    /** 热更新：构建新树，原子切换 */
    public void reload() {
        AcAutomaton fresh = buildFromDb();
        this.automaton = fresh;
    }

    private AcAutomaton buildFromDb() {
        AcAutomaton ac = new AcAutomaton();
        List<String> words = sensitiveWordMapper.selectAll();
        words.forEach(ac::insert);
        ac.build();
        return ac;
    }

    /** 校验并替换（上线前必须的兜底） */
    public String sanitize(String text) {
        if (text == null || text.isEmpty()) return text;
        AcAutomaton ac = this.automaton;
        List<int[]> hits = ac.search(text);
        if (hits.isEmpty()) return text;
        char[] chars = text.toCharArray();
        for (int[] hit : hits) {
            int len = ac.depthAt(hit[1]); // 命中节点深度 = 敏感词长度
            for (int i = hit[0] - len + 1; i <= hit[0]; i++) {
                chars[i] = '*';
            }
        }
        return new String(chars);
    }
}
```

**压测参考**：10 万词库 + 1000 字文本，AC 自动机单次扫描约 **0.3~1ms**，单机 8 核可支撑 **每秒数千次**全文检测；配合布隆过滤器（见本站《布隆过滤器原理与实战》）做「快速放行」前置判断，QPS 还能再翻几倍。

## 总结

| 维度 | 结论 |
|---|---|
| 选型 | 词库 < 1 万用 DFA；词库大/高 QPS/延迟敏感用 AC 自动机 |
| 原理 | AC = Trie + fail 指针 + goto 补全，主串指针永不回退 |
| 工程 | 双 Buffer 热更新、拼音归一化、skip 字符、白名单防误伤 |
| 面试 | 能手写 insert/build/search 三件套 + 说清 BFS 构建原因 |

敏感词过滤看着简单，但「多模式匹配 + 低延迟 + 大词库」组合起来，就是一道经典的算法工程题。理解 DFA 和 AC 自动机，不仅面试能打，线上也真能救命。
