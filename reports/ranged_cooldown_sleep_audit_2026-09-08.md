# AK47 / RPG 精确冷却与稀疏事件（2026-09-08）

## 原因与范围

AK47 和 RPG 在 CHASE、攻击冷却尚未结束时仍每个物理 tick 执行完整 family event，唯一需要连续变化的量是冷却。AK47 站定射击时 `layered_area_last_can_move=false`，原有空接触睡眠入口又要求可移动，因此仅把 family 的冷却条件放宽仍不能让它休眠。

本阶段只让 AK47/RPG 继承专用 `LazyCooldownRangedEnemy`，复用此前 Robot 已验证的 `EnemySimulationCooldown` 和 `EnemySimulationStepClock`。SimpleChase 增加一个默认 false 的纯家族方法，允许这两个明确选择该契约的家族在空接触、已知运动状态、合法非 Enemy 目标下站定休眠。其他家族保持原来的门槛。

## 行为契约

- 决策频率仍为每个物理 tick；AK47 原有 combat-sense/LOS 采样规则未改。读冷却时按实际发生的逻辑 step/delta 逐次扣减，不用墙钟、不用一次乘法代替重复浮点运算。
- 只有 CHASE 可以睡眠。WINDUP、BURST/FIRE 的事件与视觉仍逐 tick 推进；首次唤醒使用当前逻辑 step 的 delta，不能把之前 CHASE 睡眠时长扣进预警或开火动画。
- 最后一发/最后恢复帧虽然已经转为 CHASE，其 `event_consumes_tick` 仍为 true，必须继续保留一个事件清除该标记。此帧仍不能移动，也不能直接永久休眠。
- 任何 touching_players/touching_plants 成员或 cached touched 对象都阻止这两个家族的休眠，即便存在 touch cooldown；接触清理与选择维护不被省略。动态 Enemy 目标保持原有禁止休眠规则。
- 首次准入前不追扣其他敌人的 tick；公开 coordinator suspend/resume、退役重登、切换 LEGACY、clear 和真实死亡均绑定/释放原来的逻辑时钟。时钟只保存 RefCounted 数值，不持有 Enemy/Node。
- AK47 同一次 CHASE 决策中，在首次合法 hold 后正冷却分支直接沿目标朝向保持站位，省掉不会提交的 windup 调用与重复 hold。冷却为零时保留真实攻击提交及提交失败后的第二次 LOS/范围复核，不能穿新墙开火。RPG 的目标 getter 会维护真实接触，因此未对其作提前跳过。

## 验证方法与当前证据

入口 `dev_tools/ranged_cooldown_regression.gd` 动态加载 fixture，并等待销毁后通过原生应用退出协调器收尾。

`_advance_original_event` 内嵌变更前的 AK47/RPG family event 和原始逐次 scalar 扣减，不调用新 cooldown.advance 或新 family event。AK 的原始 CHASE/decision 顺序也独立保留。真实场景实例的状态、精确浮点冷却、windup/fire/burst 计数、运动位置/速度、action_sequence、弹丸序号、muzzle 颜色/缩放逐帧比较；投射物仍进入真实 DATA/rocket service，未用 mock 替代武器。

三种 30/60/120 Hz 等效 delta、分段变 delta、零 delta、目标死亡与恢复和换向，每种 480 步。为加快功能覆盖，承载该离散 trace 的原生 SceneTree 设为 240 Hz；这些结果不是该频率下的 FPS 测量。真实 coordinator 的两轮 480 tick 对照则直接调用生产 `_physics_process`，检验稀疏队列确实省掉事件，完整输出仍一致。

在加入 AK 同次决策短路前的完整回归：**5601 断言，0 失败，exit 0，无引擎错误或警告**。真实 coordinator 的 AK47 event 为 480→228，RPG 为 480→67，所有逐帧状态相等。原始结果 `dev_tools/output/ranged_cooldown_complete.log` 与 `ranged_cooldown_regression.json`。这证明事件访问减少，不等价于整局帧率提高相同比例。

额外生命周期覆盖首次 activation fence、直接 suspend/resume、原生 SceneTree pause、退役重新注册、LEGACY 回退和恢复、coordinator clear，以及真实 `_die` 后旧时钟不能再推进冷却；对其余五个远程家族检查新 stationary hook 仍 false。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/ranged_cooldown_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/ranged_cooldown_final.log' -- --vehicle-audit-ranged-cooldown
```

整局性能应由同发行模板、同密度、同逻辑步与固定窗口对照报告；本报告不把局部事件比例当作 FPS 收益。

## 中断前最终结果与收尾

07:54:25 的 `ranged_cooldown_final.log` 记录 **5611 断言、0 失败、无引擎错误或警告**。
这一轮已包括最后的 AK 同次冷却短路：正常冷却 hold 2→1，真正提交失败后仍保持 2 次；
就绪、越界、目标死亡、变友方均与原算法相同。真实 coordinator 的两族完整逐帧 trace
也再次相同。源码修改时间均早于该最终日志；没有把之后未运行的检查算作通过。

用户恢复任务时只允许收尾，因此不再扩展性能实验。保留本轮已有验证的四个生产文件及
对应回归；最终阶段另统一进行资源完整性核验与自有验证进程清理。
