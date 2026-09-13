---
title: 【工程实战】单元测试覆盖率治理深度实战：JaCoCo 原理、增量覆盖率与变异测试（PIT）
date: 2026-09-13 08:00:00
tags:
  - Java
  - 单元测试
  - JaCoCo
  - 变异测试
  - 代码质量
categories:
  - Java
  - 工程质量
author: 东哥
---

# 【工程实战】单元测试覆盖率治理深度实战：JaCoCo 原理、增量覆盖率与变异测试（PIT）

## 面试官：你们团队的单元测试覆盖率多少？

「85%。」

「那……覆盖率 85% 就说明代码质量好吗？」

这个问题一问，很多人就卡住了。更狠的追问是：

- 覆盖率是怎么算出来的？行覆盖、分支覆盖、路径覆盖有什么区别？
- 为什么覆盖率能到 90%，线上还是天天出 Bug？
- JaCoCo 是怎么知道哪一行被执行了？它改了我的字节码吗？
- 只统计新增代码的覆盖率怎么做？CI 里怎么卡住不达标的分支？
- 变异测试和覆盖率是什么关系？

这篇文章从 **JaCoCo 的字节码探针原理**讲到 **增量覆盖率门禁**，再到 **PIT 变异测试**，把「覆盖率」这件事彻底讲清楚。

---

## 一、覆盖率的度量体系：别只知道「行覆盖」

### 1.1 五种覆盖率指标

假设有这样一段代码：

```java
public int discount(int price, boolean vip) {
    if (price > 100) {          // 分支 1
        if (vip) {              // 分支 2
            return (int) (price * 0.8);
        }
        return (int) (price * 0.95);
    }
    return price;
}
```

| 指标 | 定义 | 对上面代码举例 |
| --- | --- | --- |
| **行覆盖率（LINE）** | 被执行的可执行行 / 总可执行行 | 一行不落都跑到 = 100% |
| **指令覆盖率（INSTRUCTION）** | JVM 字节码指令覆盖比例 | JaCoCo 的**核心指标**，最细 |
| **分支覆盖率（BRANCH）** | 每个 if/switch 的两个方向都走到 | 需 4 组用例才能 100% |
| **圈复杂度（COMPLEXITY）** | McCabe 复杂度，衡量独立路径数 | 不是覆盖率，是复杂度度量 |
| **方法/类覆盖率** | 有多少方法/类至少被执行一次 | 颗粒度最粗，最容易刷 |

**关键区别**：JaCoCo 官方推荐用 **指令覆盖率 + 分支覆盖率**，因为它们最难「作弊」。行覆盖率可以通过「一行写多个语句」来刷。

### 1.2 为什么 100% 行覆盖 ≠ 没 Bug

看这个经典例子：

```java
public int divide(int a, int b) {
    return a / b;
}
```

一个测试用例 `divide(10, 2)` → 行覆盖率 **100%**，但它**完全没测到 `b == 0`**，上线就抛 `ArithmeticException`。

再看：

```java
public boolean isAdult(int age) {
    return age >= 18;     // 行覆盖 100%
}
```

测试只跑了 `isAdult(20) == true`，行覆盖也是 100%。**行覆盖率对「边界值」「异常路径」完全无感。**

这就是为什么：

> **覆盖率是「测试充分性的下限指标」，不是「质量指标」。**

它只能回答「哪些代码完全没人测」，不能回答「测的地方测得对不对」。

---

## 二、JaCoCo 原理：它到底怎么知道哪行跑过了

### 2.1 三种主流覆盖率工具的实现方式对比

| 工具 | 实现方式 | 特点 |
| --- | --- | --- |
| EMMA（已停维护） | 修改字节码插入探针 | JaCoCo 的前身 |
| Cobertura | 修改字节码 | 慢，不支持新字节码版本 |
| **JaCoCo** | **字节码插桩（on-the-fly / offline）** | 快，支持 Java 新版本，JacocoAgent 无侵入 |
| Clover | 源码插桩 | 商业工具 |
| IntelliJ 覆盖率 | 字节码 + 探针 | 仅 IDE |

JaCoCo 的核心创新是 **不修改源码，只修改字节码**，而且插的探针极其轻量。

### 2.2 探针（Probe）机制详解

JaCoCo 在字节码中插入的探针本质上就是一句：

```java
// 插桩前的字节码（概念上的 Java 代码）
public void foo() {
    doSomething();
}

// 插桩后（等价逻辑）
public void foo() {
    $jacocoData[7] = true;   // 探针：一个 boolean 数组赋值
    doSomething();
}
```

真实实现要更精妙：

1. **每个类一个 `boolean[] $jacocoData` 字段**。数组长度由该类中探针数量决定。
2. 探针不是插入在每一行，而是插入在**基本块（Basic Block）的边界**——具体是每个「分支出口」和「方法入口」。
3. 数组值 `true/false` 表示「这个基本块执行过吗」。**没有计数器**，只有布尔值——这是 JaCoCo 性能好的关键（避免并发累加的原子开销）。
4. 通过 `$jacocoInit()` 方法延迟初始化数组。

```java
// 实际插入的探针形式（简化）
private static transient boolean[] $jacocoData;

private static boolean[] $jacocoInit() {
    boolean[] data = $jacocoData;
    if (data == null) {
        data = new boolean[12];
        $jacocoData = data;
    }
    return data;
}

public int discount(int price, boolean vip) {
    boolean[] $d = $jacocoInit();
    if (price > 100) {
        $d[1] = true;
        if (vip) {
            $d[2] = true;
            return (int) (price * 0.8);
        }
        $d[3] = true;
        return (int) (price * 0.95);
    }
    $d[0] = true;
    return price;
}
```

**为什么用 boolean 而不是 int 计数？**

- 计数需要 `AtomicInteger` 或同步，高并发下开销巨大。
- JaCoCo 只需要知道「有没有执行过」，不需要「执行了几次」。
- 布尔数组是**幂等写**，多线程写同一个下标不会出错（结果都是 `true`）。

### 2.3 三种工作模式

| 模式 | 启动方式 | 适用场景 |
| --- | --- | --- |
| **On-the-fly** | JVM 参数挂 `-javaagent:jacocoagent.jar` | **集成测试/E2E**，JVM 运行中实时插桩 |
| **Offline** | 构建期用 `jacoco:instrument` 处理 class | 无法加 JVM 参数的环境（如某些容器） |
| **Surefire/Failsafe 集成** | Maven 插件自动挂 agent | **单元测试**，最常用 |

单元测试场景下，Maven 插件其实也是走 on-the-fly，只是帮你把 `-javaagent` 加好了。

### 2.4 数据文件与报告生成

```bash
# 单元测试执行时，agent 把执行数据写到 jacoco.exec
# 注意：jacoco.exec 是「执行数据」，不是报告
target/jacoco.exec

# 生成报告需要「执行数据 + class 文件 + 源码」三者结合
```

**这解释了一个常见困惑**：「为什么 `jacoco.exec` 文件很小？」

因为它只是一堆布尔数组的快照，不是逐行的明细。报告是在生成时，用 class 文件里的**行号表（LineNumberTable）** 把探针位置映射回源码行。

---

## 三、Maven 集成完整配置

### 3.1 单模块配置

```xml
<build>
  <plugins>
    <!-- 1. Surefire：跑测试 -->
    <plugin>
      <groupId>org.apache.maven.plugins</groupId>
      <artifactId>maven-surefire-plugin</artifactId>
      <version>3.2.5</version>
      <configuration>
        <!-- 复用 JVM，加速；但注意静态状态污染 -->
        <forkCount>1</forkCount>
        <reuseForks>true</reuseForks>
        <argLine>@{argLine} -Xmx1g -Dfile.encoding=UTF-8</argLine>
        <!-- 排除集成测试 -->
        <excludes>
          <exclude>**/*IT.java</exclude>
        </excludes>
      </configuration>
    </plugin>

    <!-- 2. JaCoCo -->
    <plugin>
      <groupId>org.jacoco</groupId>
      <artifactId>jacoco-maven-plugin</artifactId>
      <version>0.8.12</version>
      <executions>
        <!-- 关键：prepare-agent 必须在测试之前执行 -->
        <execution>
          <id>prepare-agent</id>
          <goals><goal>prepare-agent</goal></goals>
        </execution>
        <!-- 生成报告 -->
        <execution>
          <id>report</id>
          <phase>test</phase>
          <goals><goal>report</goal></goals>
        </execution>
        <!-- 覆盖率门禁 -->
        <execution>
          <id>check</id>
          <phase>verify</phase>
          <goals><goal>check</goal></goals>
          <configuration>
            <rules>
              <rule>
                <element>BUNDLE</element>
                <limits>
                  <limit>
                    <counter>INSTRUCTION</counter>
                    <value>COVEREDRATIO</value>
                    <minimum>0.70</minimum>
                  </limit>
                  <limit>
                    <counter>BRANCH</counter>
                    <value>COVEREDRATIO</value>
                    <minimum>0.60</minimum>
                  </limit>
                </limits>
              </rule>
              <!-- 对核心包要求更高 -->
              <rule>
                <element>PACKAGE</element>
                <includes>
                  <include>com.demo.core.*</include>
                </includes>
                <limits>
                  <limit>
                    <counter>BRANCH</counter>
                    <value>COVEREDRATIO</value>
                    <minimum>0.80</minimum>
                  </limit>
                </limits>
              </rule>
            </rules>
          </configuration>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

### 3.2 三个必踩的坑

**坑一：`argLine` 被覆盖。**

如果你用了 `@{argLine}` 占位符，就必须让 JaCoCo 的 `prepare-agent` 先执行——否则 `@{argLine}` 无法解析，报错：

```
Error: Could not find or load main class @{argLine}
```

**同时**，如果其他插件（如 `maven-surefire` 的 `argLine`、`spring-boot` 的配置）也设置 `argLine`，会互相覆盖。正确做法是**统一在属性里拼接**：

```xml
<properties>
  <argLine>-Xmx1g -Dfile.encoding=UTF-8</argLine>
</properties>
```

JaCoCo 的 `prepare-agent` 会自动追加到 `argLine` 属性（通过 `propertyName` 配置），所以**只要不用自定义 argLine 属性名，并保留 `@{argLine}` 即可**。

**坑二：Lombok 生成的代码被算进覆盖率。**

Lombok 在编译期生成 getter/setter/equals/hashCode，这些代码**没有测试价值**，却拉低覆盖率。解决方案：

```xml
<configuration>
  <!-- 方式一：排除注解标记的方法 -->
  <excludes>
    <exclude>**/generated/**</exclude>
  </excludes>
</configuration>
```

```ini
# 方式二（推荐）：项目根目录建 lombok.config
lombok.addLombokGeneratedAnnotation = true
```

加上这个配置后，Lombok 会在生成的方法上加 `@lombok.Generated`，**JaCoCo 0.8.2+ 会自动忽略带该注解的代码**。这是最干净的解法。

**坑三：Spring 配置文件、DTO、枚举拉低覆盖率。**

```xml
<configuration>
  <excludes>
    <exclude>**/*Application.class</exclude>
    <exclude>**/config/**</exclude>
    <exclude>**/dto/**</exclude>
    <exclude>**/entity/**</exclude>
    <exclude>**/vo/**</exclude>
    <exclude>**/constant/**</exclude>
    <exclude>**/proto/**</exclude>     <!-- Protobuf 生成代码 -->
    <exclude>**/*MapperImpl.class</exclude>  <!-- MapStruct 生成 -->
  </excludes>
</configuration>
```

### 3.3 通过率门禁的正确姿势

很多团队的做法是「整体覆盖率 < 80% 就 fail」。这是**错误**的，因为：

- **存量代码**多，整体覆盖率上不去，门禁一开就红，团队最后直接关掉。
- **新增代码**写了 100 个测试也可能因为存量拖累而不达标。

正确做法是**增量覆盖率（Diff Coverage）**。

---

## 四、增量覆盖率：只考核「你改动的代码」

### 4.1 核心思路

```
增量覆盖率 = (本次改动行中被覆盖的行数) / (本次改动行总数)
```

只考核 PR 的 diff 与新代码，存量代码不动。这样：

- 新人不会被历史债务吓退。
- 老代码在**被改动时**自然被逐步补齐（童子军原则）。

### 4.2 方案一：JaCoCo + git diff 自研脚本

```bash
#!/usr/bin/env bash
# diff-coverage.sh —— 计算本次改动的行覆盖率
set -euo pipefail

BASE_BRANCH="${1:-origin/main}"
cd "$(dirname "$0")"

# 1. 生成 JaCoCo XML 报告
mvn -q clean test jacoco:report
test -f target/site/jacoco/jacoco.xml || { echo "jacoco.xml 未生成"; exit 1; }

# 2. 取本次改动的行（只关心新增/修改的行）
git diff --unified=0 "${BASE_BRANCH}...HEAD" -- '*.java' \
  | awk '
    /^\+\+\+ b\// { file = substr($2, 3); next }
    /^@@/ {
      # 解析 @@ -a,b +c,d @@
      match($0, /\+[0-9]+(,[0-9]+)?/);
      hunk = substr($0, RSTART+1, RLENGTH-1);
      split(hunk, parts, ",");
      start = parts[1] + 0;
      len   = (parts[2] == "" ? 1 : parts[2] + 0);
      for (i = 0; i < len; i++) print file ":" (start + i);
    }
  ' | sort -u > /tmp/changed_lines.txt

# 3. 用 Python 解析 jacoco.xml，取每条改动行的覆盖状态
python3 - <<'PY'
import xml.etree.ElementTree as ET, collections, sys

changed = set()
with open('/tmp/changed_lines.txt') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        path, ln = line.rsplit(':', 1)
        changed.add((path, int(ln)))

tree = ET.parse('target/site/jacoco/jacoco.xml')
covered, missed, details = 0, 0, []
for pkg in tree.iter('package'):
    for cls in pkg.iter('class'):
        src = cls.get('sourcefilename')
        pkg_path = pkg.get('name').replace('/', '/')
        full = f"{pkg_path}/{src}"
        for line in cls.iter('line'):
            key = (full, int(line.get('nr')))
            if key not in changed:
                continue
            mi, ci = int(line.get('mi')), int(line.get('ci'))
            if ci > 0:
                covered += 1
            else:
                missed += 1
                details.append(f"{full}:{line.get('nr')}")

total = covered + missed
ratio = (covered / total * 100) if total else 100.0
print(f"增量行覆盖率: {ratio:.2f}%  ({covered}/{total})")
for d in details[:30]:
    print("  未覆盖:", d)

THRESHOLD = 80.0
sys.exit(0 if ratio >= THRESHOLD else 1)
PY
```

**要点**：脚本必须在 `mvn test` 之后运行，且 `jacoco.xml` 必须开启（`report` goal 默认同时生成 XML）。

### 4.3 方案二：用 diff-cover（更省事）

```bash
pip install diff-cover

# 生成 XML 报告后
diff-cover target/site/jacoco/jacoco.xml \
  --compare-branch=origin/main \
  --fail-under=80 \
  --html-report coverage-diff.html
```

### 4.4 方案三：SonarQube（企业首选）

SonarQube 的「New Code」概念天然支持增量：

```properties
# sonar-project.properties
sonar.projectKey=demo-service
sonar.sources=src/main/java
sonar.tests=src/test/java
sonar.java.binaries=target/classes
sonar.java.test.binaries=target/test-classes

# 复用 JaCoCo 报告（Sonar 不自己跑测试）
sonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml

# 新增代码覆盖率门禁（在 Web UI 的 Quality Gate 里配）
# Coverage on New Code >= 80%
# Duplicated Lines on New Code <= 3%
```

**Sonar 的正确用法**：让它**消费** JaCoCo 报告，而不是重复跑一遍测试。这样可以同时得到「覆盖率 + 代码异味 + 重复率 + 安全漏洞」的综合门禁。

### 4.5 GitHub Actions 里的落地

```yaml
name: PR Quality Gate
on:
  pull_request:
    branches: [main]

jobs:
  coverage:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # 关键！要拿完整历史才能 diff

      - uses: actions/setup-java@v4
        with:
          java-version: '21'
          distribution: 'temurin'
          cache: maven

      - name: Unit Test with JaCoCo
        run: mvn -B clean verify -DskipITs

      - name: Diff Coverage
        run: |
          pip install diff-cover
          diff-cover target/site/jacoco/jacoco.xml \
            --compare-branch=origin/${{ github.base_ref }} \
            --fail-under=80

      - name: Upload Report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: jacoco-report
          path: target/site/jacoco/
```

**`fetch-depth: 0` 是必须的**——默认浅克隆会导致 `--compare-branch` 找不到基准分支，diff-cover 直接报错。

---

## 五、变异测试：真正检验「测试有没有用」

### 5.1 覆盖率的终极盲区

看这段代码和测试：

```java
public boolean isValidPhone(String phone) {
    return phone != null && phone.matches("^1[3-9]\\d{9}$");
}
```

```java
@Test
void testValidPhone() {
    assertTrue(validator.isValidPhone("13800138000"));
}
```

行覆盖率 100%，分支覆盖率也是 100%（短路求值的两个方向……实际上 `phone != null` 的 false 分支没走到，所以分支覆盖不是 100%）。

问题在于：**即使覆盖率达标的测试，也可能「断言写得毫无意义」**，比如：

```java
@Test
void testValidPhone() {
    validator.isValidPhone("13800138000");   // 没有 assert！
}
```

覆盖率照样 100%。**覆盖率对「断言的有效性」完全无能为力。**

### 5.2 变异测试的原理

变异测试（Mutation Testing）的思路是：

> **如果我把你的代码「改坏」，你的测试应该能发现。如果改坏了测试还通过，说明测试有漏洞。**

常见变异算子（Mutator）：

| 变异算子 | 例子 |
| --- | --- |
| 条件边界（CONDITIONALS_BOUNDARY） | `>` 改成 `>=` |
| 数学运算符（MATH） | `+` 改成 `-` |
| 返回值（RETURN_VALS） | `return x` 改成 `return 0` |
| 取反（NEGATE_CONDITIONALS） | `==` 改成 `!=` |
| 删除方法调用（VOID_METHOD_CALLS） | 删掉一行 `a();` |
| 常量替换（INCREMENTS） | `i++` 改成 `i--` |

指标：

```
变异得分(Mutation Score) = 被杀死的变异体 / 总变异体
```

**被「杀死」= 某个测试因为变异而失败。** 如果变异体「存活」（测试全通过），说明测试漏了这个行为。

### 5.3 PIT 实战

PIT（pitest）是 Java 生态最成熟的变异测试工具。

```xml
<plugin>
  <groupId>org.pitest</groupId>
  <artifactId>pitest-maven</artifactId>
  <version>1.15.8</version>
  <dependencies>
    <!-- JUnit 5 支持 -->
    <dependency>
      <groupId>org.pitest</groupId>
      <artifactId>pitest-junit5-plugin</artifactId>
      <version>1.2.1</version>
    </dependency>
  </dependencies>
  <configuration>
    <targetClasses>
      <param>com.demo.core.*</param>
    </targetClasses>
    <targetTests>
      <param>com.demo.core.*Test</param>
    </targetTests>
    <mutationThreshold>70</mutationThreshold>       <!-- 低于 70 就 fail -->
    <coverageThreshold>80</coverageThreshold>
    <threads>4</threads>
    <timestampedReports>false</timestampedReports>
    <outputFormats>
      <param>HTML</param>
      <param>XML</param>
    </outputFormats>
    <excludedMethods>
      <param>get*</param>
      <param>set*</param>
      <param>equals</param>
      <param>hashCode</param>
      <param>toString</param>
    </excludedMethods>
    <!-- 避开等价的、无意义的重负载变异 -->
    <avoidCallsTo>
      <param>java.util.logging</param>
      <param>org.slf4j</param>
      <param>org.apache.logging.log4j</param>
    </avoidCallsTo>
  </configuration>
</plugin>
```

执行：

```bash
mvn org.pitest:pitest-maven:mutationCoverage
# 报告：target/pit-reports/index.html
```

### 5.4 变异测试的工程取舍

变异测试**很慢**：它要跑 N 遍测试（N = 变异体数量），可能是普通测试的 100~1000 倍。

工程上的正确用法：

1. **只对核心模块跑**（支付、计费、风控、权限），不要全项目跑。
2. **只对增量代码跑**（PIT 支持 `--withHistory` 复用历史结果，只重跑受影响的类）。
3. **CI 频率降低**：每周一次或只在 release 分支跑，不要每个 PR 都跑。
4. **不追求 100% 变异得分**：因为存在「等价变异体」（改了语义但行为不变，如 `i > 0` 改 `i >= 1`），70%~80% 已经是高水位。

```bash
# 启用历史，只重跑变更的类（第二次会快很多）
mvn pitest:mutationCoverage -DwithHistory=true
```

### 5.5 一个真实的变异测试发现

某计费模块「覆盖率 92%、分支覆盖 88%」，看起来无懈可击。跑 PIT 后：

```
Line 142: negated conditional → SURVIVED
    if (amount.compareTo(ZERO) > 0) {
```

存活原因：测试用例只覆盖了「正数金额」和「负数金额」，但**没有测 `amount == 0` 的边界**。变异成 `>= 0` 后行为在已测数据上完全一致，测试全通过。

而这个边界在线上真出过问题：**0 元订单被计费系统拒绝，导致免费活动订单无法创建。**

**这就是变异测试的价值——它找到的不是「没测的代码」，而是「测得不严的代码」。**

---

## 六、一套可落地的测试策略

### 6.1 分层策略：不同层用不同测试

```
         /\
        /E2E\       少（< 10%）—— 关键链路，Playwright/RestAssured
       /------\
      / 集成测试 \   中（20%）—— Testcontainers 起真实 MySQL/Redis
     /----------\
    /  单元测试   \  多（70%）—— JUnit5 + Mockito，快，覆盖率主战场
   /--------------\
```

**覆盖率的分层考核建议**：

| 模块类型 | 行覆盖率 | 分支覆盖率 | 说明 |
| --- | --- | --- | --- |
| 领域核心逻辑（domain） | ≥ 85% | ≥ 80% | 纯函数，必须测透 |
| Service 编排层 | ≥ 70% | ≥ 60% | 主要测分支与异常 |
| Controller | ≥ 60% | — | 测参数校验与状态码即可 |
| DTO / Entity / Config | 排除 | 排除 | 无逻辑 |
| 工具类 | ≥ 90% | ≥ 85% | 被复用最多，必须最稳 |

### 6.2 测试质量的三条硬规则

**规则一：每个测试必须至少一个断言，且断言要有区分度。**

```java
// ❌ 只断言不抛异常，等于没测
assertDoesNotThrow(() -> service.create(order));

// ✅ 断言具体结果
Order created = service.create(order);
assertThat(created.getId()).isNotNull();
assertThat(created.getStatus()).isEqualTo(OrderStatus.CREATED);
assertThat(created.getAmount()).isEqualByComparingTo("99.00");
```

**规则二：必测四类边界。**

| 类别 | 例子 |
| --- | --- |
| 空值 | `null`、空字符串、空集合 |
| 边界值 | 0、-1、`Integer.MAX_VALUE`、长度 0/1/上界 |
| 异常路径 | 依赖抛异常时的行为（回滚、降级、包装） |
| 并发/时序 | 重复调用、并发调用、乱序到达 |

**规则三：测试必须能「独立重跑」。**

```java
// ❌ 依赖执行顺序 / 全局静态状态
static int counter = 0;

@Test void a() { counter++; assertThat(counter).isEqualTo(1); }
@Test void b() { counter++; assertThat(counter).isEqualTo(2); }  // 换个顺序就挂
```

```java
@BeforeEach
void setUp() {
    counter = 0;     // ✅ 每个测试独立初始化
}
```

### 6.3 让测试变快的五个技巧

慢测试是覆盖率治理最大的敌人——测试跑 20 分钟，没人愿意补测试。

| 技巧 | 效果 |
| --- | --- |
| **Mock 掉远程调用与数据库**（单测层） | 从秒级到毫秒级 |
| **Testcontainers 复用容器**（`withReuse(true)`） | 集成测试从 30s 到 3s |
| **`forkCount>0` + `reuseForks=true`** | 避免每类启动 JVM |
| **并行执行**（JUnit 5 `junit.jupiter.execution.parallel.enabled=true`） | 多核提速 |
| **拆分单测与集成测试**（surefire / failsafe） | 提交前只跑单测（< 2 min） |

```properties
# src/test/resources/junit-platform.properties
junit.jupiter.execution.parallel.enabled = true
junit.jupiter.execution.parallel.mode.default = concurrent
junit.jupiter.execution.parallel.config.strategy = dynamic
```

**注意**：并行执行要求测试无共享可变状态，否则会出现「本地过、CI 挂」的灵异现象。

---

## 七、面试追问

**Q1：JaCoCo 会修改我的源码或 class 文件吗？**

- **On-the-fly 模式**：只在**内存中**修改字节码，磁盘上的 `.class` 不变（这也是为什么叫 on-the-fly）。
- **Offline 模式**：会**覆盖磁盘上的 `.class`**，所以要小心——一旦 offline 插桩的 class 被发布，线上会带上探针代码（虽然开销极小，但不干净）。

**Q2：为什么 `jacoco.exec` 文件那么小？**

因为它不是逐行记录，而是**每个类的 `boolean[]` 快照**。一个类可能只占几十字节。真正的行映射是靠生成报告时读取 class 文件的 `LineNumberTable` 完成的。

**Q3：多模块项目的覆盖率怎么合并？**

两种方式：

```xml
<!-- 方式一：聚合报告模块（推荐，报告可按模块下钻） -->
<plugin>
  <groupId>org.jacoco</groupId>
  <artifactId>jacoco-maven-plugin</artifactId>
  <executions>
    <execution>
      <id>report-aggregate</id>
      <phase>verify</phase>
      <goals><goal>report-aggregate</goal></goals>
    </execution>
  </executions>
</plugin>
```

```bash
# 方式二：手工合并
mvn jacoco:merge -Djacoco.dataFile=target/merged.exec
mvn jacoco:report -Djacoco.dataFile=target/merged.exec
```

**Q4：TDD 和覆盖率的关系？**

TDD（测试驱动开发）是**流程**，覆盖率是**结果指标**。TDD 天然会得到高覆盖率，但**高覆盖率不等于 TDD**。用「先写代码再补测试」刷出来的 90%，和 TDD 出来的 90%，在**测试的健壮性和设计反馈**上差距巨大——TDD 的核心收益是「测试反逼出可测试的设计」，而不是覆盖率数字。

**Q5：变异测试能替代单元测试吗？**

不能，但它是**最好的「测试质量审计工具」**。合理定位：

- **日常**：跑单元测试 + 覆盖率门禁（快）。
- **周期性**：对核心模块跑变异测试（慢但深）。
- **不能做的事**：用变异测试作为 CI 阻塞门禁（太慢，且等价变异体会造成大量假阳性）。

---

## 八、总结

把全文压缩成一张图：

```
覆盖率治理
├── 概念层
│   ├── 指标：指令 > 分支 > 行（越细越难作弊）
│   └── 本质：覆盖率 = 测试充分性下限，≠ 质量上限
├── 工具层（JaCoCo）
│   ├── 原理：字节码插桩 + boolean[] 探针（幂等、无锁、极快）
│   ├── 模式：on-the-fly / offline / surefire 集成
│   └── 数据：jacoco.exec（探针快照）+ class（行号表）= 报告
├── 门禁层
│   ├── ❌ 全量覆盖率门禁（历史债务导致必然失败）
│   ├── ✅ 增量覆盖率（diff-cover / Sonar New Code）
│   └── ✅ 分层阈值（domain 高、controller 低、DTO 排除）
├── 深化层（变异测试 PIT）
│   ├── 原理：改坏代码，看测试是否能发现
│   ├── 指标：Mutation Score，70~80% 已属高水位
│   └── 定位：周期性审计，只对核心模块 + 增量代码跑
└── 工程层
    ├── 分层测试策略（70% 单测 / 20% 集成 / 10% E2E）
    ├── 测试质量三规则（有断言、测边界、可独立重跑）
    └── 提速五技巧（Mock、Testcontainers、并行、fork、拆分）
```

三句总结：

1. **不要把覆盖率当 KPI，要把它当「死代码探测器」**——它的价值是告诉你「哪些代码完全没人管」，而不是「哪些代码测得好」。
2. **增量覆盖率是让门禁真正落地的唯一可行方式**——不给历史债务背锅，只管新增代码。
3. **当你觉得测试已经很完备时，跑一次变异测试**——它会用「存活变异体」告诉你，哪些断言其实在裸奔。
