# macOS KPS/CPS 实现审查与优化建议

日期：2026-04-06  
范围：仅评审 macOS 当前实现（`KeyStats/`）中的 KPS/CPS 逻辑  
目标读者：开发者本人，直接按文档执行优化

---

## 1. 结论摘要

当前 KPS/CPS 实现整体**可用**，统计口径也基本一致：

- 实时 KPS/CPS = 过去 1 秒内的按键/点击数量
- 峰值 KPS/CPS = 当日内出现过的最大 1 秒滑动窗口值

但实现中存在几类值得尽快处理的问题：

### P0：必须优先处理
1. **`currentStats` 相关读写缺少统一线程安全保护**
2. **峰值更新与跨日重置之间存在竞态条件**
3. **部分 `Timer` 依赖调用线程的 RunLoop，时机不够稳**

### P1：建议处理
4. **滑动窗口实现使用 `Array + filter`，存在不必要的重复扫描和分配**
5. **KPS/CPS 统计使用 `Date()` 而非单调时钟，边界情况下不够稳**

### P2：可选整理
6. **当前值与峰值的数据类型不统一（`Int` vs `Double`）**
7. **命名偏窄，部分注释和定义不够明确**
8. **实时刷新策略还有进一步降噪/降负载空间**

推荐执行顺序：

1. 先做线程安全和跨日原子性修复
2. 再重构滑动窗口与时间基准
3. 最后做类型、命名和展示层清理

---

## 2. 当前实现概览

主要涉及文件：

- `KeyStats/StatsManager.swift`
- `KeyStats/InputMonitor.swift`
- `KeyStats/KPSDetailView.swift`
- `KeyStats/MenuBarController.swift`
- `KeyStats/StatsModels.swift`

### 当前数据流

1. `InputMonitor` 监听全局输入事件
2. 键盘事件进入 `StatsManager.incrementKeyPresses(...)`
3. 鼠标点击事件进入 `incrementLeftClicks(...)` / `incrementRightClicks(...)` / 侧键点击方法
4. 每次键盘/点击事件都会：
   - 更新 `currentStats` 的累计计数
   - 调用 `recordKeyForPeakKPS()` 或 `recordClickForPeakCPS()`
   - 触发菜单栏/UI 刷新
5. 菜单栏与 KPS 弹窗通过定时器周期性读取 `getCurrentKPS()` / `getCurrentCPS()`

### 当前统计定义

- `getCurrentKPS()`：统计过去 1 秒内 `recentKeyTimestamps` 的数量
- `getCurrentCPS()`：统计过去 1 秒内 `recentClickTimestamps` 的数量
- `peakKPS` / `peakCPS`：每次新事件到来时，如果当前 1 秒窗口值更高则更新峰值

这个口径本身没有明显问题，问题主要在**并发安全、时序一致性和实现效率**。

---

## 3. 详细问题与优化方案

## P0-1. `currentStats` 缺少统一线程安全保护

### 现状

`InputMonitor` 的事件回调不保证在主线程。当前实现中，`StatsManager` 的这些方法可能被后台事件线程调用：

- `incrementKeyPresses(...)`
- `incrementLeftClicks(...)`
- `incrementRightClicks(...)`
- `incrementSideBackClicks(...)`
- `incrementSideForwardClicks(...)`
- `recordKeyForPeakKPS()`
- `recordClickForPeakCPS()`

而 `currentStats` 会同时被：

- 输入事件线程写入
- 主线程 UI 读取
- 午夜重置逻辑写入
- 导入/导出逻辑读写

目前只有 `recentKeyTimestamps` / `recentClickTimestamps` 受到 `peakRateLock` 保护，`currentStats` 本身没有统一锁。

### 风险

- 多个输入事件并发修改 `currentStats`，出现丢写或覆盖
- UI 读取时碰到中间状态，得到不一致值
- reset / import / save 与输入事件并发时，统计可能错位

### 优化方案

为**所有统计状态**建立统一的串行保护机制，二选一：

#### 方案 A：单一 `NSLock` / `os_unfair_lock` 保护全部 stats 状态（推荐）
维护一个统一的锁，保护以下内容：

- `currentStats`
- `recentKeyTimestamps`
- `recentClickTimestamps`
- 任何与 KPS/CPS 相关的瞬时状态

优点：
- 实现简单
- 适合当前项目规模
- 容易保证跨字段原子性

缺点：
- 锁粒度偏大，但当前吞吐量完全可接受

#### 方案 B：专用串行 `DispatchQueue`
所有 stats 状态读写都切到同一个串行队列。

优点：
- 结构清晰
- 更容易避免锁遗漏

缺点：
- 需要重新整理大量同步/异步访问点
- 对现有同步 getter 改动更大

### 推荐实现

优先用**方案 A**。

建议新增一个专门的状态锁，例如：

- `private let statsStateLock = NSLock()`

然后把这些逻辑归入同一把锁：

- 计数增长
- 峰值更新
- 跨日切换检查
- reset 时清空滑动窗口
- `currentStats` 快照读取

### 实施建议

1. 不要再让 `peakRateLock` 和 `currentStats` 分离保护
2. 为 UI 提供只读快照方法，例如：
   - `currentStatsSnapshot()`
   - `currentRatesSnapshot()`
3. UI 层尽量只读快照，不直接拼接多个非原子 getter

### 验证点

- 高频连点/连键时，累计值稳定递增
- UI 不出现负数、回跳、短暂不一致
- 峰值不会偶发丢失

---

## P0-2. 峰值更新与跨日重置之间存在竞态条件

### 现状

现在 `recordKeyForPeakKPS()` / `recordClickForPeakCPS()` 的结构大致是：

1. 加锁处理时间戳数组
2. 计算当前窗口值
3. 解锁
4. 如果当前值大于 `currentStats.peakKPS/CPS`，则更新峰值

而跨日时 `resetStats(for:)` 会：

- 重置 `currentStats`
- 清空 `recentKeyTimestamps`
- 清空 `recentClickTimestamps`

这些步骤与输入事件可能并发发生。

### 风险

典型竞态：

1. 某个输入事件刚算出 `currentKPS = 12`
2. 主线程午夜 reset，把 `currentStats` 换成新一天
3. 旧事件随后把 `peakKPS = 12` 写进新一天

这样会导致**新一天刚开始就带着前一天尾部峰值**。

### 优化方案

把以下操作做成同一个临界区中的原子事务：

- 确认当前归属日期
- 更新累计计数
- 修剪滑动窗口
- 计算当前 KPS/CPS
- 更新峰值

同时，`resetStats(for:)` 也要进入同一把锁，确保不会和输入事件交错写入。

### 推荐实现

将“按键事件处理”和“点击事件处理”改成统一模式：

- `withStatsStateLock { ... }`
- 锁内完成 `ensureCurrentDay` / 累计统计 / 峰值更新
- 锁外只做 UI 通知和异步刷新

### 实施建议

1. 避免在锁外比较并写峰值
2. 避免 reset 只清 timestamp、不与计数更新同锁
3. 把“当天切换”和“峰值窗口状态重置”统一处理

### 验证点

- 接近午夜连续输入时，新一天的峰值从 0 正常开始
- 不会出现新一天瞬间继承旧峰值
- reset 后 `getCurrentKPS()` / `getCurrentCPS()` 立即归零

---

## P0-3. `Timer` 依赖调用线程 RunLoop，不够稳

### 现状

当前项目中多处使用 `Timer.scheduledTimer(...)`。这类 timer 依赖创建时所在线程有可运行的 RunLoop。

对于 KPS/CPS 相关路径，风险主要在：

- `scheduleSave()` 可能由非主线程触发
- 某些 debounce/刷新逻辑虽然会切主线程，但整体模式不统一

### 风险

- timer 创建成功但不触发
- 保存时机飘忽
- 特定线程环境下行为不一致

### 优化方案

统一策略，二选一：

#### 方案 A：所有 UI/保存相关 `Timer` 仅在主线程创建（推荐）
简单直接，适合当前 AppKit 项目。

#### 方案 B：后台逻辑改成 `DispatchSourceTimer`
适合需要线程无关、更加明确调度语义的场景。

### 推荐实现

优先采用**方案 A**：

- 所有 `Timer.scheduledTimer` 前先保证切回主线程
- 非 UI 的节流/保存也统一主线程调度，减少心智负担

如果后续感觉主线程上 timer 太多，再把纯后台逻辑迁移到 `DispatchSourceTimer`。

### 实施建议

1. 审查 `saveTimer` / `statsUpdateTimer` / `kpsRefreshTimer` / `midnightCheckTimer`
2. 给每一个 timer 建立明确规则：
   - UI 刷新：主线程
   - 持久化节流：主线程或 `DispatchSourceTimer`
   - 状态变更：不要隐式依赖当前线程

### 验证点

- 高频输入后，数据仍能按预期持久化
- 菜单栏刷新稳定
- 睡眠唤醒后 timer 行为正常

---

## P1-1. 滑动窗口实现使用 `Array + filter`，效率一般

### 现状

当前 KPS/CPS 实现：

- 每次事件 append 一个 `Date`
- 通过 `filter { $0 > cutoff }` 清理 1 秒前的数据
- 当前值直接取数组长度

查询当前 KPS/CPS 时，又会再做一次 `filter` 计数。

### 风险

逻辑上没大错，但存在这些问题：

- 每次输入都要遍历数组
- `filter` 会创建新数组
- 高频输入时分配和复制增多
- 读接口也在重复扫描

### 优化方案

改为真正的队列式滑动窗口：

- 新事件进来：append 到尾部
- 移除过期事件：持续从头部弹出
- 当前值：队列长度

### 推荐实现

对于当前项目，推荐两种可实现方式：

#### 方案 A：简单数组 + 头指针
维护：

- `[TimeInterval] timestamps`
- `headIndex`

修剪时只移动 `headIndex`，必要时再压缩数组。

优点：
- Swift 原生实现最简单
- 避免频繁 `removeFirst()` 的 O(n)

#### 方案 B：自定义轻量队列结构
封装一个 `SlidingWindowCounter` 或 `TimestampQueue`。

优点：
- 复用性更好
- KPS/CPS 共用同一逻辑

### 推荐实现

优先选 **方案 B**，但保持实现轻量。

建议抽成一个非常小的内部结构，职责只做三件事：

- `record(now:)`
- `prune(before:)`
- `count(now:)`

### 验证点

- 高 KPS/CPS 下菜单栏刷新稳定
- 长时间运行后内存不异常增长
- 结果与旧实现保持一致

---

## P1-2. 使用 `Date()` 作为时间基准，不如单调时钟稳

### 现状

当前 1 秒窗口依赖 `Date()` 与 `addingTimeInterval(-1.0)`。

### 风险

`Date()` 受系统墙钟时间影响：

- 系统时间手动修改
- 自动校时
- 睡眠唤醒后的时钟调整

这些情况可能让“过去 1 秒”的判断产生边界误差。

### 优化方案

改用单调时钟，例如：

- `ProcessInfo.processInfo.systemUptime`
- 或 `CACurrentMediaTime()`

### 推荐实现

优先使用：

- `ProcessInfo.processInfo.systemUptime`

理由：
- 不依赖系统墙钟
- 语义清晰
- 对这种滑动窗口统计更合理

### 实施建议

1. KPS/CPS 的时间戳存储类型改成 `TimeInterval`
2. `record` / `getCurrent` / `reset` 全部切到同一种时基
3. 不要混用 `Date` 和单调时钟

### 验证点

- 手动改系统时间后，KPS/CPS 没有异常跳变
- 睡眠唤醒后，窗口统计能快速恢复到正确状态

---

## P2-1. 当前值是 `Int`，峰值是 `Double`，定义不统一

### 现状

- `getCurrentKPS()` / `getCurrentCPS()` 返回 `Int`
- `peakKPS` / `peakCPS` 存在 `DailyStats` 里是 `Double`
- 某些 UI 显示 `Int(...)`，某些显示保留 1 位小数

### 风险

- 同一个指标在不同位置表现不同
- 读代码时不容易判断峰值是否支持小数
- UI 和数据模型语义不统一

### 优化方案

#### 方案 A：全部改为 `Int`（推荐）
如果定义就是“过去 1 秒内的事件数”，则本质是整数。

#### 方案 B：全部改为 `Double`
如果未来要引入平滑速率、EMA、子秒采样换算，则可以保留浮点。

### 推荐实现

当前推荐 **方案 A：统一成 `Int`**。

只有在准备引入“平滑 KPS/CPS”时，才值得保留 `Double`。

### 实施建议

1. 评估持久化兼容性
2. 如果不想动持久化格式，也可以短期保持模型是 `Double`，但内部全部按整数写入和展示
3. 若正式改类型，记得同步处理解码兼容

### 验证点

- 所有界面上的 KPS/CPS 口径一致
- 导入旧数据不崩溃

---

## P2-2. 命名与职责可更清晰

### 现状

一些命名带有历史痕迹，例如：

- `kpsRefreshTimer` 实际服务的是菜单栏实时速率刷新
- `recordKeyForPeakKPS()` 不仅记录，还会裁剪窗口并更新峰值
- `getCurrentKPS()` / `getCurrentCPS()` 实际也隐含窗口清理逻辑的需求

### 风险

- 后续维护时误解方法职责
- 扩展到更多实时指标时命名变得别扭

### 优化方案

建议做小范围重命名：

- `kpsRefreshTimer` -> `rateRefreshTimer` 或 `menuBarRateRefreshTimer`
- `recordKeyForPeakKPS()` -> `recordKeyEventAndUpdatePeakKPS()`
- `recordClickForPeakCPS()` -> `recordClickEventAndUpdatePeakCPS()`

如果引入公共结构：

- `keyRateWindow`
- `clickRateWindow`

### 验证点

- 新命名一眼能看出职责
- 阅读调用链时不再需要反复跳转确认含义

---

## P2-3. 建议补充统计定义注释，避免后续误解

### 现状

现在代码里能看出是“过去 1 秒滑动窗口”，但并没有把这个定义写得非常明确。

### 风险

以后容易出现这些争议：

- 为什么峰值不是平滑后的？
- 为什么某些测试时看起来比整秒采样更高？
- 为什么 KPS 是瞬时滑窗而不是平均速率？

### 优化方案

在模型和方法注释中明确写出：

- 当前 KPS/CPS = trailing 1-second sliding-window count
- 峰值 KPS/CPS = max trailing 1-second sliding-window count observed today

### 推荐落点

- `DailyStats.peakKPS / peakCPS`
- `getCurrentKPS() / getCurrentCPS()`
- 详情 UI 或设置文案（如未来有设置项）

---

## P2-4. 菜单栏与详情弹窗的刷新策略可进一步整理

### 现状

- 菜单栏依赖 `StatsManager.startKPSRefreshTimer()` 每 0.3 秒刷新
- `KPSDetailView` 自己也有一个 0.3 秒 `Timer.publish(...)`

### 风险

- 存在双处定时刷新
- 后续如果再增加实时组件，刷新来源会越来越分散

### 优化方案

短期不一定要改，但可以考虑未来统一为一种模式：

#### 方案 A：各视图自带刷新
简单，但分散。

#### 方案 B：由 `StatsManager` 提供统一实时更新源
例如统一 handler 或可观察对象。

### 推荐实现

当前阶段不作为优先项处理。只建议：

- 保持菜单栏和详情弹窗的刷新周期一致
- 避免新增第三种刷新机制

---

## 4. 推荐实施顺序

## 阶段 1：先修正确性（必须）

1. 引入统一 stats 状态锁
2. 将累计计数、滑窗修剪、峰值更新、跨日切换纳入同一临界区
3. 统一 reset 与输入事件处理的原子性
4. 审查相关 timer，保证创建线程稳定

### 阶段完成标准

- 高频输入时统计稳定
- 跨日切换不会串日
- 峰值不会丢失或误写新一天

---

## 阶段 2：再修实现质量（推荐）

5. 把滑动窗口改成队列式结构
6. 使用单调时钟替代 `Date()`
7. 为 UI 提供快照读取接口，减少直接读内部状态

### 阶段完成标准

- KPS/CPS 结果与现有定义一致
- 性能更稳，逻辑更清晰
- 时间调整/唤醒情况下表现更稳定

---

## 阶段 3：最后做模型和可维护性整理（可选）

8. 统一 KPS/CPS 类型
9. 重命名方法和 timer
10. 补充注释和定义说明
11. 视需要统一实时刷新策略

### 阶段完成标准

- 代码语义清晰
- 数据模型与 UI 展示一致
- 后续扩展成本更低

---

## 5. 建议的实现边界

本轮优化建议尽量**聚焦 KPS/CPS 自身**，不要顺手做过多无关重构。

建议纳入本轮：

- KPS/CPS 线程安全
- 滑动窗口结构
- 时间基准
- 相关 timer 的稳定性
- UI 读取一致性

建议暂不纳入本轮：

- 大规模重构整个 `StatsManager`
- 所有统计项统一架构改造
- 菜单栏 UI 样式重做
- 跨平台统一抽象

---

## 6. 验收清单

完成优化后，至少手动验证以下场景：

### 基础功能
- [ ] 连续打字时，实时 KPS 正常变化
- [ ] 连续点击时，实时 CPS 正常变化
- [ ] 峰值 KPS/CPS 会被更新
- [ ] 停止输入约 1 秒后，当前 KPS/CPS 回到 0

### 并发/稳定性
- [ ] 高频输入时，累计按键/点击数不回退
- [ ] 菜单栏与详情弹窗显示口径一致
- [ ] 不出现偶发跳变、负值、明显错位

### 跨日/重置
- [ ] 手动触发 reset 后，当前 KPS/CPS 归零
- [ ] reset 后峰值归零
- [ ] 跨日后不会继承前一天尾部峰值

### 持久化/生命周期
- [ ] 高频输入后数据仍会落盘
- [ ] 应用切后台、回前台后实时统计正常
- [ ] 睡眠唤醒后实时统计恢复正常

### 时钟相关
- [ ] 修改系统时间后，KPS/CPS 不出现明显异常

---

## 7. 最终建议

如果只做一轮最值得做的优化，建议按下面这个最小闭环执行：

1. **统一锁住 `currentStats + KPS/CPS 窗口状态`**
2. **把峰值更新和跨日 reset 放进同一原子流程**
3. **将滑动窗口改成队列式实现**
4. **将时间基准改为单调时钟**

这四步完成后，当前 macOS 的 KPS/CPS 实现会从“功能可用”提升到“逻辑稳、可长期维护”。

如果时间有限：

- 最少先做 1 + 2
- 有余力再做 3 + 4
- 类型统一和命名整理放到最后

---

## 8. 相关代码定位

便于开工时快速定位：

- `KeyStats/StatsManager.swift`
  - `incrementKeyPresses(...)`
  - `incrementLeftClicks(...)`
  - `incrementRightClicks(...)`
  - `incrementSideBackClicks(...)`
  - `incrementSideForwardClicks(...)`
  - `recordKeyForPeakKPS()`
  - `recordClickForPeakCPS()`
  - `getCurrentKPS()`
  - `getCurrentCPS()`
  - `startKPSRefreshTimer()`
  - `resetStats(for:)`
  - `scheduleSave()`

- `KeyStats/InputMonitor.swift`
  - `handleEvent(type:event:)`

- `KeyStats/KPSDetailView.swift`
  - `refreshData()`

- `KeyStats/MenuBarController.swift`
  - `updateMenuBarAppearance()`

- `KeyStats/StatsModels.swift`
  - `DailyStats.peakKPS`
  - `DailyStats.peakCPS`
