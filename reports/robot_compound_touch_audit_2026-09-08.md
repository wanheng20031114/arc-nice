# 机械小怪复合接触查询：验证但拒绝部署（2026-09-08）

**结论：功能验证通过，正式发行运行的 ABBA 对照显示明显性能倒退，因此撤销该扩展。** Robot 继续使用已有原生 Area2D 玩家/建筑接触机制，未扩大其他家族的 indexed 能力。只单独保留已在原有单形状家族验证的 `_unregister_contact_proxy` Area 所有权释放修复。

四轮严格同参数发行测试：256 个建筑、正式第 12 波配比的 300 个敌人、1800 ticks，GPU 时间均约 2.58 ms、产水均 448。A 为既有 native Area，B 为本报告的 compound indexed 扩展。

| 顺序 | 接触机制 | 帧间隔 p95 | 原始证据目录 |
| --- | --- | --- | --- |
| A1 | native Area | 89.857 ms | `dev_tools/output/tower_density_20260908_070209_794/` |
| B1 | compound indexed | 141.195 ms | `dev_tools/output/tower_density_20260908_070300_163/` |
| B2 | compound indexed | 122.688 ms | `dev_tools/output/tower_density_20260908_070522_932/` |
| A2 | native Area | 85.717 ms | `dev_tools/output/tower_density_20260908_070613_398/` |

B2 末尾有 299 个存活敌人，因此不是严格同存活数的一轮；该限制不能抹去 A1/B1 与反向 A2 的显著差距，也不支持把 B 上线。GPU 几乎一致，增加的 native shape 逐候选调用和脚本维护没有被省下的 Area 成本抵消。该判断针对本次实测 cohort 和实现，不泛化为所有 Godot 索引方案都慢。

生产文件通过经过 SHA-256 与当前内容双重校验的 `dev_tools/output/compound_ab_20260908/select_variant.py native-area` 恢复。未提交的 helper 与三个测试场景/脚本精确移至 `dev_tools/output/compound_ab_20260908/rejected_extension/`，保留完整实验归档；原始日志、截图与报告均保留。归档测试的 `res://` 路径对应实验期源布局，不属于当前发布回归入口。下文是**被拒绝实验版本**的实现和语义证据。

## 结构原因

`CombatRobot` 的身体和剑各有独立的碰撞矩形，TouchDamageArea 同样有两块形状。此前敌人之间的共享接触已保留精确的非凸 union，但 Player/Plant 接触只接受单 Shape2D：多形状时 `contact_attacker_shape` 被置为 null，注册和几何重建还各有一次 `size == 1` 门槛。因此 61 个后期机械精英一直保留双形状 Area2D 的物理重叠维护。

实验保留 CharacterBody2D 的两块实际身体形状，把这一个已验证家族的 Player/Plant 接触接入同一空间索引。单形状家族继续原有单次 native collide 路径。该实验现已撤回。

## 实现边界

- 新的 `CombatNativeTouchUnion` 只保存同一次有效几何捕获的 Shape2D 资源和各自相对根节点的 Transform2D，不保存场景节点。查询逐子形状调用 Godot 原生 `Shape2D.collide()`，任一命中即返回 true，目标只入集合一次。
- 未使用凸包填平身体与剑之间的间隙，也未把 AABB、包围圆或 swept 预测结果用作伤害判定。已有 union AABB/半径和静态净空证书只用于保守候选筛选。
- 新增 `Enemy.supports_compound_indexed_touch_authority()`，默认 false。只有 CombatRobot 精确的原始/精英共用脚本显式启用；未来继承脚本、剑士、忍者及其他家族不自动获得该证明。原有单形状门槛仍存在。
- 面向镜像、根旋转、局部偏移和 Shape2D.changed 均在现有几何边界整体重建。只有共享 contact proxy 更新成功后才发布新的 native union；失败时保留旧 union/anchor，执行原有整组兼容模式回退。
- 显式支持复合接触的 Robot 使用当前 proxy 的世界包围半径加 anchor 到根节点距离，作为动态玩家索引的保守范围。不会继续使用初始化时未含后续根缩放的局部半径；旧单形状家族数值保持不变。两倍缩放后逐角点验证范围仍包住全部原生子形状。
- 顺带修复 `_unregister_contact_proxy` 的接管生命周期：单体暂停/注销除了移除共享 proxy，也必须释放 indexed Area 所有权。原有 deferred commit 仍决定活体恢复和死体继续禁用，不能在失去登记后留下旧接触快照。

Godot 官方 [Shape2D](https://docs.godotengine.org/en/stable/classes/class_shape2d.html) 明确区分当前相交 `collide` 和包含运动的 `collide_with_motion`，此处只使用前者。官方 [Area2D](https://docs.godotengine.org/en/stable/classes/class_area2d.html) 说明多个 CollisionShape2D 共同定义同一个区域，overlap 列表在物理步骤更新，不保证节点移动后即时变化。因此回归分别检查所有权的 deferred 边界、实际物理 enter/exit 信号，以及稳定后的当前接触集合。

## 验证

`dev_tools/robot_touch_union_fixture.tscn` 是原生场景，内含两个独立矩形的 Area2D 和实际 CharacterBody2D 探针。独立主循环动态加载并销毁场景，避免资源循环。

最终完整语义验证：**432 个断言、0 失败、退出码 0，无引擎错误或警告**，日志 `dev_tools/output/robot_touch_union_complete.log`，原始结果 `dev_tools/output/robot_touch_union_regression.json`。

- 三个旋转方向、小探针与同时触及两个子形状的大探针，以及移动 Area 与真实 StaticBody2D 建筑探针：合计 18 次真实 body_entered、18 次 body_exited，独立间隙无接触，双命中只有一条目标接触记录。原始物理帧号保存在 JSON 的 `native_phase_records`。
- 真正塔防运行时生成机械精英和真实玩家/建筑；indexed 玩家与建筑集合等于原生子形状相交的 OR。接管后两块 TouchDamageArea 形状同时关闭，身体碰撞保持原状。
- 平移复用、朝向镜像、根旋转、剑局部偏移、资源尺寸修改、原本禁用剑以及重新启用剑；禁用后自然回到既有单形状路径，再启用后恢复两块形状。
- 同时覆盖多个攻击子形状的一个建筑，同一物理帧的重复更新只产生一次真实伤害。暂停后冷却不提前结束；恢复后首步不会产生第二次伤害，原冷却截止之后恰好产生第二次伤害。
- 主动让共享接触服务拒绝下一次几何更新，核实旧 native union 与 anchor 未半更新，整组退回兼容模式，再次有效准入后可以恢复。
- 新源码下重新运行 `robot_cooldown_regression.gd`：9521 个断言、0 失败、退出码 0、无警告；30/60/120 Hz 原始 scalar 状态机与懒更新状态机完整 trace 仍相等。日志 `dev_tools/output/robot_cooldown_after_union.log`。

早期测试错误地用直接瞬移 StaticBody2D 作为玩家运动探针，没有得到有效的动态 enter/exit 样本；改为与玩家一致的 CharacterBody2D。另一轮在 deferred Area 开关尚未完成全部物理更新时读取了上个 overlap，现已将两种相位明确分开。保留原始失败日志，不用它们作为通过证据。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/robot_touch_union_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/robot_touch_union_complete.log' -- --vehicle-audit-union-regression
```

## 性能结论约束

本阶段新增 native exact 查询在一个候选上最多检查两块真实形状，目的是取消全局 Area 重叠维护，不能单凭减少 Area 数量断言整体帧率。正式 256 建筑、300 混合敌人的发行运行由根任务在源码冻结窗口独立测量，结果见开头 ABBA 表。功能正确不等于优化成功，本实验没有上线。

最终 432 断言语义回归后，已再次通过 Win32_Process 命令核实本任务 `--vehicle-audit-*` Godot 进程残留 0，没有关闭其他 agent 进程或用户编辑器。
