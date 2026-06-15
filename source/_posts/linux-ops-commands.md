---
title: Linux 运维常用命令与实战技巧
date: 2026-06-15 10:00:00
tags:
  - Linux
  - 运维
  - 命令行
  - Shell
categories:
  - 运维
author: 东哥
---

# Linux 运维常用命令与实战技巧

> Linux 是后端开发和运维的基石。很多开发者在日常工作中离不开 Linux 终端，但往往只掌握最基本的命令。本文系统梳理了高频实用的 Linux 命令和技巧，帮你提升终端效率。

## 一、文件管理

### 1.1 文件操作

```bash
# 创建文件
touch file.txt

# 查看文件（推荐顺序）
cat file.txt           # 一次性输出
less file.txt          # 分页查看（按 q 退出）
head -n 20 file.txt    # 前 20 行
tail -f app.log        # 实时跟踪日志

# 查找文件
find /var/log -name "*.log" -mtime -7   # 7天内修改的日志
find . -type f -size +100M              # 大于100MB的文件
locate nginx.conf                       # 快速定位（需 updatedb）

# 文件统计
wc -l file.txt         # 行数
wc -c file.txt         # 字节数
du -sh /var/log        # 目录总大小
du -sh * | sort -rh    # 按大小排序
```

### 1.2 文本处理三剑客

**grep —— 搜索**

```bash
# 基本搜索
grep "ERROR" app.log
grep -i "error" app.log                # 忽略大小写
grep -r "Exception" /app/logs/         # 递归搜索
grep -A 5 "ERROR" app.log              # 匹配行 + 后5行
grep -B 5 "ERROR" app.log              # 匹配行 + 前5行
grep -C 5 "ERROR" app.log              # 匹配行 + 前后各5行
grep -v "INFO" app.log                 # 排除匹配行
grep -c "ERROR" app.log                # 统计匹配行数

# 正则搜索
grep -E "ERROR|WARN" app.log           # 扩展正则（OR）
grep -P "\d{4}-\d{2}-\d{2}" app.log   # Perl正则（日期）
```

**sed —— 流编辑器**

```bash
# 替换
sed -i 's/old/new/g' file.txt          # 全局替换
sed -i 's/old/new/2' file.txt          # 仅替换每行第2个
sed -i '/pattern/s/old/new/g' file.txt # 只处理匹配行

# 删除
sed -i '/^#/d' config.conf             # 删除注释行
sed -i '/^$/d' file.txt                # 删除空行
sed -i '1,10d' file.txt                # 删除1-10行

# 行操作
sed -n '10,20p' file.txt               # 打印10-20行
sed -i '3i\new line' file.txt          # 在第3行前插入
sed -i '5a\append line' file.txt       # 在第5行后追加
```

**awk —— 文本处理利器**

```bash
# 基本用法
awk '{print $1, $NF}' access.log          # 打印第1列和最后一列
awk -F':' '{print $1, $3}' /etc/passwd    # 指定分隔符

# 条件过滤
awk '$11 > 500 {print $1, $11}' access.log  # 响应时间 > 500ms
awk '/ERROR/ {print NR, $0}' app.log        # 打印错误行号

# 统计汇总
awk '{ips[$1]++} END {for(ip in ips) print ip, ips[ip]}' access.log

# 时间区间过滤
awk '$4 >= "[15/Jun/2026:00:00:00" && $4 <= "[15/Jun/2026:23:59:59"' access.log
```

## 二、进程管理

### 2.1 ps —— 进程快照

```bash
# 常用组合
ps -ef                     # 全格式进程列表
ps aux                     # 另一种风格
ps -ef | grep java         # 查找 Java 进程
ps aux --sort=-%mem        # 按内存排序
ps aux --sort=-%cpu        # 按 CPU 排序
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head

# 进程树
pstree -p                  # 树形结构显示进程关系
```

### 2.2 top —— 实时监控

```bash
# 交互命令
top                    # 启动
  P                # 按 CPU 排序
  M                # 按内存排序
  1                # 查看各 CPU 核心
  k                # 杀死进程
  q                # 退出

# 批量模式
top -b -n 1 | head -n 20   # 一次性输出

# 更现代的工具
htop                    # 更友好的 top（需安装）
```

### 2.3 后台进程

```bash
# 后台运行
nohup java -jar app.jar > app.log 2>&1 &

# 结合 disown
command &
disown

# screen / tmux
screen -S mysession     # 创建会话
screen -r mysession     # 恢复会话
Ctrl+A D                # 分离会话

tmux new -s mysession   # tmux 版
tmux attach -t mysession
```

## 三、磁盘与文件系统

### 3.1 磁盘信息

```bash
# 磁盘使用
df -h                    # 人类可读格式
df -hT                   # 包含文件系统类型

# 目录空间
du -sh /var/log
du -sh * | sort -rh | head -5    # 最大的5个

# 查找大文件
find / -type f -size +1G -exec ls -lh {} \;
```

### 3.2 IO 监控

```bash
# iostat
iostat -x 1 3            # 扩展统计，每秒1次，共3次

# iotop
iotop -o                 # 只显示有 IO 的进程

# 定位 IO 瓶颈
# r/s = 读请求/s, w/s = 写请求/s, rkB/s, wkB/s
# await = IO 平均响应时间（毫秒）, %util = 磁盘繁忙度
```

## 四、网络排查

### 4.1 网络连接

```bash
# 查看端口
ss -tlnp                 # TCP 监听端口（推荐用 ss 替代 netstat）
ss -tan | grep ESTAB     # 已建立的 TCP 连接
ss -s                    # 统计信息

# 进程级连接
lsof -i :8080            # 谁在使用 8080 端口
lsof -i :80 -s TCP:LISTEN

# 连接数统计
ss -tan | awk '{print $4}' | cut -d: -f2 | sort | uniq -c | sort -rn
```

### 4.2 网络诊断

```bash
# ping（测试连通性）
ping -c 5 google.com

# traceroute（路由追踪）
traceroute google.com
mtr google.com           # 更强大的 traceroute

# DNS 查询
nslookup example.com
dig example.com +short

# HTTP 调试
curl -I https://api.example.com          # 查看响应头
curl -v https://api.example.com          # 详细信息
curl -w "耗时: %{time_total}s" https://api.example.com

# 网络带宽测试
iperf3 -c server_ip -t 30   # 测试带宽
```

### 4.3 TCP 连接状态分析

```bash
# 查看各状态连接数
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# 定位 TIME_WAIT 过多
ss -tan state time-wait | wc -l

# 查看连接队列溢出
netstat -s | grep -i listen
```

## 五、性能分析

### 5.1 CPU 分析

```bash
# 查看各核心负载
mpstat -P ALL 1

# 进程级 CPU
pidstat -p PID 1

# CPU 火焰图（简版）
perf record -ag -- sleep 30
perf report
```

### 5.2 内存分析

```bash
# 内存使用
free -h
cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable"

# 进程级内存
ps aux --sort=-%rss | head -10

# page cache
cat /proc/meminfo | grep -E "Cached|Buffers"

# OOM Killer 日志
dmesg | grep -i oom
journalctl -k | grep -i oom
```

### 5.3 系统负载分析

```bash
# 查看负载
uptime
cat /proc/loadavg

# 负载分解
# 1 分钟 / 5 分钟 / 15 分钟负载
# 理想情况：负载 < CPU 核心数 * 0.7

# 查看 CPU 核数
nproc
grep -c processor /proc/cpuinfo
```

## 六、系统安全

### 6.1 用户与权限

```bash
# 用户管理
useradd -m newuser       # 添加用户
passwd newuser           # 设置密码
usermod -aG sudo user    # 添加 sudo 权限
userdel -r user          # 删除用户

# 文件权限
chmod 755 script.sh      # 权限数字法
chmod u+x script.sh      # 权限符号法
chown user:group file    # 修改所有者和组

# sudo 配置
visudo                   # 编辑 /etc/sudoers
# 添加：username ALL=(ALL) NOPASSWD: ALL
```

### 6.2 防火墙

```bash
# firewalld（CentOS/RHEL）
firewall-cmd --list-all
firewall-cmd --add-port=8080/tcp --permanent
firewall-cmd --reload

# ufw（Ubuntu）
ufw enable
ufw allow 22/tcp
ufw allow 8080
ufw status

# iptables
iptables -L -n -v
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
```

### 6.3 SSH 安全加固

```bash
# /etc/ssh/sshd_config 关键配置
# Port 22222                     # 修改默认端口
# PermitRootLogin no             # 禁止 root 登录
# PasswordAuthentication no      # 禁用密码登录
# PubkeyAuthentication yes       # 使用密钥登录
# AllowUsers dongge              # 限制登录用户

# 重启 SSH
systemctl restart sshd
```

## 七、日志管理

### 7.1 journalctl（systemd 日志）

```bash
journalctl -u nginx.service       # 查看 nginx 日志
journalctl -u nginx -f            # 实时跟踪
journalctl -u nginx --since "1 hour ago"
journalctl -u nginx -p err        # 只显示错误级别

# 永久保存日志
# 修改 /etc/systemd/journald.conf
# Storage=persistent
```

### 7.2 日志轮转 logrotate

```bash
# /etc/logrotate.d/myapp
/var/log/myapp/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    sharedscripts
    postrotate
        kill -HUP $(cat /var/run/myapp.pid)
    endscript
}
```

## 八、实用 Shell 技巧

### 8.1 一行命令技巧

```bash
# 统计 IP 访问量 Top 10
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head -10

# 查看历史执行最多的命令
history | awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# 批量杀死进程
ps aux | grep "myapp" | grep -v grep | awk '{print $2}' | xargs kill -9

# 批量重命名文件
rename 's/\.jpg$/\.png/' *.jpg

# 监控命令实时输出
watch -n 1 'ps aux --sort=-%cpu | head -5'
```

### 8.2 Shell 配置优化

```bash
# ~/.bashrc 或 ~/.zshrc 常用别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias g='grep -i --color=auto'
alias df='df -h'
alias du='du -sh'
alias psg='ps aux | grep -v grep | grep'
alias ports='ss -tlnp'
alias ..='cd ..'
alias ...='cd ../..'

# 设置 PATH
export PATH=$PATH:/usr/local/bin:~/bin

# PS1 显示 Git 分支（bash）
parse_git_branch() {
    git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}
export PS1="\u@\h \w\$(parse_git_branch)\$ "
```

## 九、总结

Linux 命令行是后端开发者的基本功。本文涵盖了从文件管理、进程监控、网络排查到性能分析的常用命令和技巧。

**学习建议：**
1. 遇到问题先尝试用命令行解决
2. 每个命令深入研究其 man page
3. 建立自己的命令笔记和别名库
4. 多写 Shell 脚本自动化日常工作

记住：**花时间掌握命令行，是回报率最高的技术投资之一。**
