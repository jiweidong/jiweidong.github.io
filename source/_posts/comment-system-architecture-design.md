---
title: 【系统设计】评论系统架构设计：多级评论、存储模型、计数与排序全解析
date: 2026-10-02 08:30:00
tags:
  - 系统设计
  - 高并发
  - 数据库设计
  - 评论系统
categories:
  - 系统设计
  - 后端架构
author: 东哥
---

# 【系统设计】评论系统架构设计：多级评论、存储模型、计数与排序全解析

## 面试官：设计一个类似微博/知乎的评论系统，支持多级回复、点赞和海量数据

评论系统是系统设计面试的常客。它不像秒杀那样极端，但把**数据建模、分页、计数一致性、缓存、排序**这几个经典问题全揉在了一起。

尤其"多级评论"这一块，是区分候选人水平的分水岭——很多人上来就说"用 parent_id 递归查"，然后就被追问死了。

---

## 一、需求拆解

| 维度 | 需求 |
| --- | --- |
| 层级 | 支持一级评论 + 二级回复（最多两层），不无限嵌套 |
| 排序 | 一级按热度/时间，二级按时间 |
| 分页 | 一级评论分页，二级默认展示前 3 条 + "查看更多" |
| 计数 | 评论数、回复数、点赞数，允许秒级延迟 |
| 数据量 | 单内容最多百万评论，全站百亿级 |
| 操作 | 发表、删除、点赞、举报、审核 |

**关键的产品决策**：绝大多数成熟产品（微博、YouTube、Twitter）都采用**两层结构**——一级评论 + 二级回复拉平。为什么？因为无限嵌套在 UI 上难以展示、在查询上难以分页、在移动端体验极差。所以：

```text
评论 A（一级）
├── 回复 A1（二级）
├── 回复 A2（二级）
└── 回复 A3（二级）
评论 B（一级）
└── ...
```

所有回复都挂在**根评论**下，只在回复内容里 @ 被回复人。这个决策一旦定下来，后面的存储和查询就简单多了。

---

## 二、存储模型：四种树形结构对比

如果要支持真正的多级树，有四种经典方案：

| 方案 | 结构 | 查某节点子树 | 插入 | 移动 | 适用 |
| --- | --- | --- | --- | --- | --- |
| 邻接表 | 存 parent_id | 递归/多次查询 | O(1) | O(1) | 层数浅、写入多 |
| 路径枚举 | 存 path 如 `1/5/12` | `LIKE '1/5/%'` | O(1) | 修改子树 | 读多写少、层数固定 |
| 嵌套集 | 存 lft/rgt | 范围查询很快 | O(N) | O(N) | 极少改动 |
| 闭包表 | 单独关系表 | join 快 | O(depth) | O(depth) | 复杂树、查询多 |

评论场景的特点：**写入频繁、层级浅（2 层）、查询以"某根评论下的回复列表"为主**。所以最合适的其实是**反范式化**：

```sql
CREATE TABLE comment (
    id            BIGINT PRIMARY KEY AUTO_INCREMENT,
    content_id    BIGINT       NOT NULL COMMENT '被评论的内容ID',
    root_id       BIGINT       NOT NULL DEFAULT 0 COMMENT '根评论ID，一级评论为0或自身',
    parent_id     BIGINT       NOT NULL DEFAULT 0 COMMENT '直接父评论ID',
    reply_to_uid  BIGINT       NOT NULL DEFAULT 0 COMMENT '被回复人',
    user_id       BIGINT       NOT NULL,
    content       TEXT         NOT NULL,
    reply_count   INT          NOT NULL DEFAULT 0,
    like_count    INT          NOT NULL DEFAULT 0,
    status        TINYINT      NOT NULL DEFAULT 1 COMMENT '1正常 0删除 2审核中',
    create_time   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_content_root (content_id, root_id, id),
    KEY idx_root_time (root_id, create_time)
) ENGINE=InnoDB;
```

设计要点：

1. **`root_id` 是关键**。一级评论 `root_id = 0`（或自身 id），二级回复 `root_id = 一级评论 id`。查某条一级评论下的所有回复，只需 `WHERE root_id = ?`，走 `idx_root_time` 索引，一次查询搞定，不需要递归。
2. **`parent_id` 保留**，用于 UI 上展示"回复 @某某"。
3. **`reply_count` 冗余**，避免每次 count(*)。
4. **软删除**（status），保留数据用于审计和被回复链的完整性。

这个设计彻底避免了递归查询——用一点点冗余换来了查询的简单和高效。

---

## 三、分页：深分页是评论系统的第一大坑

一条爆款微博可能有 50 万条评论。用户翻到第 100 页时，`LIMIT 200000, 20` 会扫 20 万行再丢弃，慢到无法接受。

### 3.1 游标分页（Keyset Pagination）

评论列表天然适合游标分页，因为有序字段是 `id`（或 `create_time + id`）：

```sql
-- 第一页
SELECT * FROM comment
WHERE content_id = ? AND root_id = 0 AND status = 1
ORDER BY id DESC
LIMIT 20;

-- 下一页：带上上一页最后一条的 id
SELECT * FROM comment
WHERE content_id = ? AND root_id = 0 AND status = 1
  AND id < :lastId
ORDER BY id DESC
LIMIT 20;
```

`id < :lastId` 可以直接用索引定位，复杂度 O(log N + 20)，与翻页深度无关。

### 3.2 热度排序怎么办？

如果一级评论按"热度"排序，游标分页就不好用了，因为热度会变。工程上的常见做法是**时间切片 + 热度**：把评论按小时/天分桶，桶内按热度排，桶间按时间。或者干脆"热度排序只支持前 N 页"，再往后按时间。

另一种做法是**离线算好 Top N 存 Redis**，比如每个内容维护一个 ZSet：

```text
comment:hot:{contentId}  ->  ZSet(member=commentId, score=hotScore)
```

只展示 Top 200，再往后走时间序游标分页。这样既保证了热度榜的实时和高效，也不怕翻页。

---

## 四、计数一致性：评论数、回复数、点赞数

计数是评论系统里最容易出 bug 的地方，因为它天然是"高频写、热点行"。

### 4.1 分层计数

| 计数 | 存储 | 一致性 |
| --- | --- | --- |
| 内容的评论总数 | Redis Hash，异步落库 | 最终一致，允许秒级延迟 |
| 单条评论的回复数 | Redis + DB 冗余字段 | 最终一致 |
| 单条评论的点赞数 | Redis 计数（见点赞系统设计） | 最终一致，分钟级落库 |

### 4.2 避免数据库热点行

如果用 `UPDATE comment SET reply_count = reply_count + 1 WHERE id = ?`，爆款评论的计数行会成为热点，行锁竞争严重。做法：

1. **Redis 原子自增**（`HINCRBY`），先返回给用户。
2. **MQ 异步聚合**，定时批量写回 DB。
3. DB 里的值只作为"基准值"，最终展示 = DB 基准 + 待同步增量（可选）。

### 4.3 对账

计数一定要有对账任务：

```sql
-- 定时校正：以明细表为准，重算计数并修正
SELECT root_id, COUNT(*) FROM comment
WHERE status = 1 AND root_id <> 0
GROUP BY root_id;
```

发现偏差就修正并告警。这是防止长期漂移的唯一手段。

---

## 五、缓存设计

评论是典型的"读多写多"，缓存要分层。

### 5.1 热评论缓存

```text
本地缓存（Caffeine，100ms TTL）      <- 抗瞬时热点
   ↓ miss
Redis（一级评论第一页，TTL 60s）      <- 抗常规热点
   ↓ miss
MySQL                                <- 最终数据源
```

对爆款内容，第一页评论的 QPS 极高，本地缓存 100ms 就能挡掉绝大部分重复请求。

### 5.2 缓存穿透与击穿

- **穿透**：查一个不存在的 content_id。用空值缓存 + 布隆过滤器。
- **击穿**：热点 key 过期瞬间大量请求打 DB。用**逻辑过期**（不设 TTL，后台异步更新）或**互斥重建**（分布式锁，只允许一个请求回源）。
- **雪崩**：大量 key 同时过期。给 TTL 加随机扰动。

### 5.3 大 Key 问题

如果用一个 Redis List 存整个评论列表，爆款内容会形成几十万长度的大 key。正确做法是**用 ZSet + 分页**，或者直接不缓存全量，只缓存前 N 页。

---

## 六、发布链路：写扩散与同步

### 6.1 发表评论的完整流程

```text
1. 参数校验（长度、频率、敏感词）
2. 风控校验（刷评论检测）
3. 内容审核（机审 + 人审队列）
4. 落库（status=审核中）
5. 发 MQ：更新计数、推送给内容作者、更新搜索索引
6. 返回评论 ID
```

要点：

- **审核异步**：用户发出后先展示"审核中"，通过后才对外可见。同步审核会拖慢响应。
- **计数和通知异步**：不要在主链路里同步更新计数、发通知、写 ES。
- **限频**：同一用户 N 秒内只能发一条，用 Redis 计数器。

### 6.2 删除的连锁处理

删一条一级评论时，它的所有二级回复怎么处理？常见策略：

- **级联软删除**：一起来标记删除，但保留数据。
- **占位显示**：显示"该评论已删除"，保留回复的上下文。
- **计数修正**：同步更新 reply_count。

这些都要在删除的异步任务里处理，避免主链路阻塞。

---

## 七、代码实战：查询一级评论 + 前 N 条回复

```java
public PageResult<CommentVO> listComments(long contentId, Long cursor, int size) {
    // 1. 查一级评论
    List<Comment> roots = commentMapper.selectRoots(contentId, cursor, size);
    if (roots.isEmpty()) {
        return PageResult.empty();
    }

    List<Long> rootIds = roots.stream().map(Comment::getId).toList();

    // 2. 批量查每条根评论的前 3 条回复（一次查询，不是 N 次）
    List<Comment> replies = commentMapper.selectTopReplies(rootIds, 3);
    Map<Long, List<Comment>> replyMap = replies.stream()
            .collect(Collectors.groupingBy(Comment::getRootId));

    // 3. 组装
    List<CommentVO> vos = roots.stream().map(r -> new CommentVO(
            r.getId(),
            r.getUserId(),
            r.getContent(),
            r.getCreateTime(),
            r.getLikeCount(),
            r.getReplyCount(),
            replyMap.getOrDefault(r.getId(), List.of()).stream()
                    .map(this::toBrief).toList()
    )).toList();

    Long nextCursor = roots.size() < size ? null : roots.get(roots.size() - 1).getId();
    return new PageResult<>(vos, nextCursor);
}
```

对应的批量查询 SQL（关键：**用 IN 一次查完，避免 N+1**）：

```sql
-- 取每条根评论最新的 3 条回复：MySQL 8 用窗口函数
SELECT * FROM (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY root_id ORDER BY id DESC) AS rn
    FROM comment c
    WHERE c.root_id IN (:rootIds) AND c.status = 1
) t WHERE t.rn <= 3;
```

N+1 查询是评论系统最常见的性能杀手。100 条一级评论如果逐条查回复，就是 101 次 DB 往返。用 IN + 窗口函数一次搞定。

---

## 八、高频追问

**追问 1：为什么不做无限层级？**

三层以上在 UI 上展示困难（缩进爆炸），查询和分页复杂度指数上升，而用户真正需要的通常只有"回复某人"。所以主流产品都限制为两层，用 "回复 @某人" 来表达层级关系。

**追问 2：回复的回复怎么显示？**

因为它和普通二级回复一样挂在根评论下，所以按时间排列在二级列表里，UI 上显示"用户 A 回复 用户 B"。不需要额外的树结构。

**追问 3：如何实现"评论盖楼"？**

"盖楼"（同一主题下连续回复）本质上还是两层结构，只是把 parent_id 串起来展示。存储不变，展示时按 parent 链回溯即可。

**追问 4：分表怎么分？**

- 按 `content_id` 哈希分表：同一内容的评论在一张表，查询高效。
- 按时间分表：适合归档。
- 实践中常见"分 1024 表 + 按 content_id 取模"，配合分库。

**追问 5：如何保证大量并发下的稳定性？**

- 写：MQ 削峰 + 限频 + 异步审核。
- 读：本地缓存 + Redis + 游标分页 + 批量查询。
- 计数：Redis 原子 + 异步落库 + 定时对账。
- 兜底：热点内容单独降级（只展示 Top 50 + 加载更多按钮）。

---

## 九、总结

评论系统的设计可以归纳为四点：

1. **两层扁平化**：用 root_id 消灭递归，用 parent_id 表达回复关系。
2. **游标分页**：彻底解决深分页，复杂度与翻页深度无关。
3. **分层计数**：Redis 扛写入，DB 做基准，定时对账防漂移。
4. **读写分离 + 异步化**：写走 MQ 削峰，读走多级缓存，N+1 用批量查询消灭。

把"树形结构怎么存"和"深分页怎么解"这两点讲透，评论系统这道题就答到点上了。
