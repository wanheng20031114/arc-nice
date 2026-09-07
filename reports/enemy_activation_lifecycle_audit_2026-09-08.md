# 敌人调度登记与接触所有权修复（2026-09-08）

## 变更

`EnemySimulationCoordinator._ensure_registration_active_for_tick` 把同一物理帧重复阶段检查内联到已经证明 registration 非空、非 tombstone 的分支中。移除只在此处调用的 `_registration_remains_active_this_tick`，省掉一次 GDScript VM 调用和三个重复 guard。保留 `active_this_tick`、`last_authoritative_physics_frame`、暂停状态以及每一阶段**即时**的实例有效性、queued deletion、死亡检查。

这不是“本帧第一次存活就永远有效”的缓存。event 中死亡、被释放、暂停的敌人仍不能继续 decision/motion；同 tick 暂停与死亡的检查顺序、下一 tick 检查顺序、首次登记的 activation fence 与 COMPAT/anchor 同帧去重均保留原行为。

另修复 `_unregister_contact_proxy`：暂停一个已接管 Player/Plant 接触的登记时，除了删除共享 proxy，立即释放敌人的 indexed 接触所有权。继续复用 Enemy 已有 deferred commit 恢复作者设定的 Area2D layer/mask/monitoring/monitorable 和形状开关。死亡对象仍保持禁用，身体碰撞不受影响。此修复覆盖既有单形状敌人，与已拒绝的 Robot compound 扩展无关。

## 验证

### 调度状态与原始实现逐项对照

`dev_tools/enemy_activation_fixture.gd` 内嵌两个原始 admission 方法作为独立 reference；它不会调用生产新方法判断同帧有效性。

- 240 种状态组合：首次/同帧、last_authoritative 三种帧值、active/suspended/tombstone 布尔值，以及 alive/dead/null/queued/free 五种真实 Enemy 状态；每组比较本次、重复阶段和下个 tick 的返回值、登记状态、注册字典和指标计数。
- event→decision→motion 之间实际死亡、queue_free/free、公开 suspend/resume；同帧已准入后恢复可以继续，首次暂停拒绝后同帧恢复则不得补发准入。
- 注册初帧 fence、倒序/重复帧、anchor 重复拒绝、退役 token 与新登记替换。
- **1563 个断言，0 失败，exit 0，无引擎错误或警告。** `dev_tools/output/enemy_activation_complete.log` 和 `enemy_activation_regression.json`。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/enemy_activation_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/enemy_activation_complete.log' -- --vehicle-audit-activation
```

可选 `--benchmark` 提供等调用入口的 ABBA 100000 次同帧检查微基准；本轮未执行，避免干扰其他最终压力测试，故不宣称该局部改动的整体 FPS 百分比。

### 真正单形状接触生命周期

`dev_tools/indexed_touch_lifecycle_fixture.gd` 加载实际 TowerDefenseGame，分别生成原始 `slime_golden` 和 `cardboard_monster_large`，通过原有单形状 capability 与共享服务准入。

- 接管关闭原生传感器；直接 coordinator suspend 立即清除 indexed ownership，并在 deferred 边界恢复完整作者设定。
- 把真实 CharacterBody2D 玩家移到敌人处，经历四个物理帧后原生 Area `overlaps_body` 与 `body_entered` 维护的 contact dictionary 均正确，证实恢复的传感器实际工作。
- resume 后原子重新准入和刷新快照；unregister/re-register 使用新 token，延迟的旧 token 无权暂停新登记；LEGACY 回退恢复 Area。
- 死亡后 suspend 释放 indexed ownership，但 deferred commit 不重新启用死体接触；CharacterBody2D 物理身体始终保留。
- **127 个断言，0 失败，exit 0，无引擎错误或警告。** `dev_tools/output/indexed_touch_lifecycle_complete.log` 和 `indexed_touch_lifecycle_regression.json`。

首跑只因测试释放回调缺少必需的第三参数而解析失败，已修正 fixture 并完整重跑；未据此改动生产 API。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/indexed_touch_lifecycle_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/indexed_touch_lifecycle_complete.log' -- --vehicle-audit-touch-lifecycle
```

本阶段结束后以 Win32_Process 命令核实所有本任务带 `--vehicle-audit-*` 参数的 Godot 验证进程为 **0**，未停止其他 agent 的进程或用户编辑器。CPU 窗口已交给网络最终压力验证。
