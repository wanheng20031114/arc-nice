# 机械小怪冲刺冷却与事件睡眠（2026-09-08）

## 原因与改动

正式塔防第十二波的 300 敌人配比包含 61 个 `CombatRobot` 精英。旧实现要求冲刺冷却已归零才能睡眠，因此即使 CHASE 状态没有接触事件、运动计划已稳定，冷却期间仍每帧进入协调器事件队列、重复登记检查与家族方法。

现在冷却由协调器的逻辑步时钟驱动。时钟只在真正进入兼容/分层玩法阶段时前进；SceneTree 暂停和接触预检失败不会产生时钟步。它不引用 Node、Enemy、Coordinator 或其他玩法对象，只记录逻辑 tick 与每次 delta 变化的起点，避免引用环，也不逐帧创建时间记录。

`CombatRobot.dash_cooldown_left` 在决策读取时追补自上次读取以来的实际逻辑步。每一步仍执行原来的 `maxf(remaining - delta, 0)`，没有用一次乘法近似多次浮点减法；30/60/120 Hz、变速和零 delta 下，准备攻击的零值边界保持一致。事件重新进入时不会再次扣除已经被决策 getter 追补的时间。

冷却归零本身没有事件副作用，所以没有新增 cooldown 截止事件。原来的三 tick 感知/决策节奏会读取最新冷却并尝试蓄力；成功进入 WINDUP 时明确撤销已有睡眠证书，协调器在决策末将它放回事件队列。WINDUP/DASH 继续每步执行，首次醒来只消费当前步实际 delta，不把此前 CHASE 睡眠时间扣到蓄力上；蓄力完成当步仍仅进入 DASH，下一步才开始位移。

原有 Player/Plant 的 Area2D 复合接触方式保持不变。没有扩大 `supports_indexed_touch_authority()`，没有简化碰撞形状、降低攻击判定频率或把伤害变成预测结果。

生命周期处理覆盖正常注册、同帧注册隔离、单体暂停/恢复、直接协调器暂停/恢复、退役、重新注册、切回 LEGACY 以及清空协调器。暂停某个敌人会脱离共享时钟，其他敌人的运行不会消耗它的冷却；重新绑定后的第一个真实事件才确定首个可消费的逻辑步。LEGACY 恢复普通逐步扣减。

## 回归证据

入口：`dev_tools/robot_cooldown_regression.gd`。纯 SceneTree 入口只动态加载可销毁测试节点，避免在主循环静态持有完整玩法资源。实际机器人来自原有场景；其碰撞体采用 Godot 原生 `DISABLE_MODE_KEEP_ACTIVE`，以便禁用自动游戏循环后仍能验证原生冲刺位移。

最终 **9521 个断言全部通过，退出码 0，日志无错误或警告**：`dev_tools/output/robot_cooldown_regression_final.log`，机器可读结果 `dev_tools/output/robot_cooldown_regression.json`。最终轮次与另一 agent 的资源加载检查并行，只用于功能结论。

- 18 组初始冷却/Hz 组合，各 700 个逻辑步；包括连续改变 delta、零 delta、每三步或十七步才读取、同一步重复读取。每次读取与独立原始 scalar 逐步计算 **精确相等**。
- 30/60/120 Hz 各 600 步真实机器人状态机，对比冷却睡眠与测试中保留的原始 scalar 家族事件（不调用新 helper.advance_event 或新家族事件方法），检查全部状态、冷却、蓄力/冲刺剩余时间、真实位置、朝向、冲刺准备标记和警示 Polygon2D 数据完全一致。含移动目标和暂时无目标机会。
- 真实 coordinator 调度 240 步，sleep on/off 的状态、冷却、蓄力/冲刺时间和原生位置完整 trace 相等。事件执行 **240 → 139**，减少 **42.08%**。此数仅为该单机器人测试的事件访问次数，不是六人整场景帧率提升。
- 真实暂停 0.25 秒，Engine 的物理帧仍增长，而逻辑 tick 和冷却保持不变；恢复不吞掉墙钟帧。另有单体暂停、直接 coordinator API、退役/重新注册、切回 LEGACY、clear(true) 后仍正常逐步倒计时的检查。
- 同帧注册会等待首个实际准入事件，不能把注册前的其他敌人 tick 错算进自身冷却。

首轮测试有 fixture 类型推导错误，随后一轮错误地禁用碰撞体所在的整棵场景，导致原生物理空间为空；这两轮不作为通过证据。修正测试场景的原生 disable_mode 后，状态机及实际调度轮次均无引擎错误。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/robot_cooldown_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/robot_cooldown_regression_final.log' -- --vehicle-audit-cooldown-regression
```

## 范围与后续观测

此阶段只迁移 `CombatRobot` 的冲刺冷却，没有把其他远程机器人、法术持续事件或 WINDUP/DASH 迁移到睡眠。`chase_cooldown_event_sleep_enabled` 默认真，保留一个明确的实例比较开关供真实场景 A/B 使用。

时钟记录数量随 **delta 改变次数** 增长，普通固定物理步只有一个记录；它在本场景协调器销毁时整体释放。当前不引入弱引用计时器注册表或复杂历史压缩；若未来产品增加每帧连续调整 time_scale 的机制，需再按可观测的最早冷却读取位置压缩 epochs。现有测试 700 步、多次速度切换只产生 6 条记录。

根任务完成正式 400 建筑/300 混合敌人、600 tick GPU 场景：本阶段后帧间隔 p95 180.948 ms，前一阶段 187.14 ms；事件计数 123287→101917。整帧改善温和，仍存在严重 CPU 卡顿，不能据此宣称性能问题已经解决。具体环境及全量指标由根任务综合性能报告保留。触碰冷却的旧暂停问题由根任务独立修复，此阶段没有修改该计时器。

最终验证结束后，已再次通过 `Win32_Process` 命令筛选本任务 `--vehicle-audit-*` 标记，核实验证 Godot 进程残留 0；没有关闭用户编辑器或其他 agent 的测试进程。
