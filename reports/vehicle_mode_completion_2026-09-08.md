# 小车模式完整性检查与完善（2026-09-08）

本次基于远程 `38a8742dd28d` 的十二波战役完善，不保留已被该远程实现替代的早期重复方案。小车仍为单人标准模式的独立战役变体，冻结的联机模式 ID 与网络模式目录没有修改。

## 已解决的玩法问题

1. **开局缺少完整目标/操作说明，缺少再战入口。** 增加开局简报和“启动引擎”，确认前驾驶锁定、首波倒计时不推进。简报跟随实际键位显示驾驶、装填、暂停、榴弹操作，说明十二波目标、免费收藏品、波间维护和息壤升级。胜败结算增加本局统计、评级、个人纪录，以及调用真实 GameLoadCoordinator 的重新出发按钮。
2. **确定性火力不足。** 原始攻击 10 对终波主战机器人的 40 点物防只能造成 1 点最低物理伤害。三选一随机收藏品不能保证弥补这个差距。第 1–11 波领取奖励后固定增加 4 攻击、10 耐久上限，维修新耐久上限的 25%，取消装填并补满弹匣；终波前保底 54 攻击与 210 耐久上限，另叠加真实收藏品/属性升级。
3. **升级覆盖波间成长的结构风险。** 每次维护按连续波次幂等提交到既有 RunState party status ledger，在现有总额上增加本波的 4 攻击、10 耐久，保留同名属性的其他奖励来源；Player 使用原有完整投影路径。因此购买升级、拾取/丢弃收藏品和全量属性刷新都保留成长，重复或跳波服务不重复治疗。已核查当前其他同键写入者属于小车不启用的 Rogue 遭遇/稀有宝箱，但回归仍主动注入独立的 +7 攻击、+13 耐久，验证后续维护不会覆盖。
4. **背包开放时敌人仍行动，奖励独自写 SceneTree.paused。** 单人模态暂停统一进入 GameplayPause，使用 WeakRef 拥有者和 tree_exiting 自动释放，库存、奖励、暂停菜单相互独立。只在最后一个拥有者退出后恢复世界，临时效果的公共游戏时钟也冻结。网络会话的清理哨兵不会错误解除单人模态。原有网络暂停协议保持由主机控制。
5. **奖励界面吞掉暂停键。** 保留强制三选一及原有满背包整理流程，同时允许打开暂停菜单；菜单打开时卡片快捷键与过期选择信号不可领取奖励。回到卡片仍是同一组候选，关闭菜单不会提前恢复战场。
6. **车头射击与榴弹方向不一致。** 榴弹现在沿当前车头方向发射；更新专属角色配置与开局提示，保留其他角色的原技能方向规则。
7. **实机画面可读性。** 小车场景单独提高夜间 CanvasModulate 亮度，保留战斗/休整色调转换。背包小车预览从约 17 像素放大为整数倍的清晰预览，使用同一涂装材质；HUD 增加得分、战斗时间、息壤余额、当前攻击，并更新入口为十二波战役描述。
8. **UI 重挂重复连接。** 原 UIAudio 在按钮离树时清理实例登记但保留 pressed 连接，原节点重新入树会重复 connect。现在使用原生 Signal.is_connected 对齐节点生命周期，并增加同一 UI 子树摘挂后的唯一连接回归。

## 计分与纪录

真实击败一名敌人 10 分；每波完成 100 分，低于 `45 + 8 × (波次 - 1)` 战斗秒再加 100 分，该波未损失耐久再加 100 分；通关额外 500 分。483 名敌人的理论满分 8930，S 阈值 8200，A 阈值 7400，其余通关为 B。

战斗时间只计入 WAVE_ACTIVE 的真实物理步进，倒计时/选择/暂停不计时。敌人和波次结算使用现有终结账本，重复信号不重复加分。原生 ConfigFile 保存 `user://vehicle_records.cfg` 中的最高分、最远波次、最快胜利时间；新一局只加载纪录，不恢复上一局的力量、收藏品或升级。测试通过 `save_run_records=false` 避免写用户纪录，ConfigFile 回归仅使用独立临时测试文件并立即删除。

## 验证记录

### 十二波结构与边界回归

入口 `dev_tools/verify_vehicle_mode.tscn` 使用实际场景、实际延迟预热/激活、真实生成队列和真实 Enemy 伤害/死亡/退树结算。此项为了快速覆盖所有分支将敌人设为 1 HP，**不代表实战难度验证**。

真实渲染轮次：519 名真实敌人终结、12 次成功奖励、2774 个断言、0 失败、退出码 0，日志无错误或退出泄漏警告。519 包括十二波战役的 **483** 名敌人，以及奖励中死亡、奖励中拆场景两项独立边界用例各 18 名敌人；额外 36 名不参与战役计分。覆盖十二波连通与并发上限、三张互异且兼容收藏品、重复领取/重入事件、满背包整理、奖励期间死亡/拆场景、开局等待确认、成长账本及购买升级后保留、精确 25% 维修/装填边界、ConfigFile 隔离及最快通关纪录、菜单/库存/奖励嵌套暂停、冻结游戏时钟、节点退树自动释放、UI 重挂唯一声音连接。

账本同键共存修改后的末轮无头回归：同样 519 名终结、12 次奖励，**2771 个断言、0 失败、退出码 0**，无错误或警告。比渲染轮次增加 2 个账本断言、省去 5 个截图断言。日志 `dev_tools/output/vehicle_contract_ledger_final_20260908.log`；使用同一命令加 `--headless`、去掉 `--capture-ui` 即可重现。结束后命令核实 `--vehicle-audit-*` Godot 进程为 0。

命令：

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --path 'C:/Users/wh/Documents/arc-nice' --scene 'res://dev_tools/verify_vehicle_mode.tscn' --resolution 1280x720 --max-fps 60 --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/vehicle_contract_final_20260908.log' -- --vehicle-audit-contract --capture-ui
```

### 实时驾驶和视觉检查

新增 `dev_tools/vehicle_playtest.tscn` 是可复现的正常输入机器人：保持原敌人血量、刷新间隔和波间倒计时，不注入货币、不强制伤害、不瞬移。它通过真实升级按钮、卡片选择、重开/返回按钮走完整场景生命周期；正常转向、油门、射击与榴弹输入驱动实际物理和投射物。简单机器人不具备人类躲弹和路线决策能力，结果用于检查实际行为，不能作为平衡性评分。

首轮不购买任何改装：真实击破 114 个敌人，完成 4 波后在第 5 波战败，战斗时间 176.45 秒、20 次装填、10 次榴弹，最高速度准确限制为 100。失败结算 → 真实加载器重开 → 初始属性和账本恢复 → 返回主菜单，断言 0 失败。首轮证据保留在 `dev_tools/output/vehicle_playtest_no_upgrades/` 及同名日志。

最终实战从真实主菜单进入涂装工坊并选择红色车漆，经原生按钮启动、用本局真实收入购买改装，通过正常输入击破 55 名敌人、完成 2 波后在第 3 波战败，战斗时间 93.03 秒、6 次装填、5 次榴弹，最高速度 100。失败结算、重开清零、返回菜单均通过，断言 0 失败、退出码 0。仅有一条 ObjectDB 退出警告，无脚本解析或 RID 泄漏错误；其后的完整结构渲染回归已无退出警告。这项实战**没有宣称以正常血量打通十二波**。证据在 `dev_tools/output/vehicle_playtest/result.json` 与同目录 PNG。

有一轮旧版机器人在第一波最后一名敌人的墙前停滞，人工终止；此轮明确不计通过。之后仅改进测试驾驶员，沿项目既有 GridPathfinder 路径绕障，并添加 90 秒无进展终止。没有为通过测试改变玩家碰撞、敌人血量或产品寻路规则。

原生 Godot Forward+ / NVIDIA RTX 3060 Laptop 渲染导出的开局、战斗、背包、奖励和结算截图用于逐张检查。Computer-use 的窗口抓图接口返回 Windows `SetIsBorderRequired 0x80004002`；因此视觉判断来自真实 Godot viewport PNG，而没有把无法取得的桌面截图当成验证成功。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --path 'C:/Users/wh/Documents/arc-nice' --scene 'res://dev_tools/vehicle_playtest.tscn' --resolution 1280x720 --max-fps 60 --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/vehicle_playtest_20260908.log' -- --vehicle-audit-playtest
```

## 约束和已识别的项目级问题

- 所有新增产品 UI 节点由 `.tscn` 原生 Label、HBoxContainer、Button 描述，复用既有卡片、HUD 主题、像素车和涂装 Shader，没有生成替代图像资产。
- 参考 Godot 官方 [Control](https://docs.godotengine.org/en/stable/classes/class_control.html)、[Timer](https://docs.godotengine.org/en/stable/classes/class_timer.html) 与 [SceneTree](https://docs.godotengine.org/en/stable/tutorials/scripting/scene_tree.html) 的容器、信号与场景生命周期能力。
- 初始与前两轮验证退出均有既有 761 resources 引用循环泄漏。根任务已从源头修复项目循环引用，最终完整结构回归退出码 0、无资源泄漏警告。
- 首次实战返回菜单后约 0.6 秒即退出，`VEHICLE_PLAYTEST failures=0` 之后才出现图鉴后台加载链中的 PlantDefense 场景解析错误。根任务已引入异步资源生命周期协调并验证主菜单提前退出；fixture 也等待真实菜单预加载终态。最后结构回归没有解析错误。
- 最终开局、胜利、失败界面的真实渲染证据位于 `dev_tools/output/vehicle_contract_capture/`，1280×720 下文字和双按钮完整、没有遮挡裁切；胜利截图中的 00:00 来自上述加速结构用例，不冒充真实通关成绩。
- 验证用进程全部带 `--vehicle-audit-*` 标记；每轮完成/终止后均以 Win32_Process 精确筛选并命令核实，不关闭用户编辑器或其他检查任务。最终渲染回归后残留 0 个。

## 全部敌人优化整合后的最终复验（北京时间 07:24）

最终再读成长、胜败、重试、纪录与暂停链路，没有发现需新增修改的产品逻辑缺陷。保底成长按连续波次在前 11 次维护中幂等叠加，收藏品与购买升级仍使用同一个权威账本；胜败只由现有终结账本结算，重试先拆场景并解除暂停，再创建全新的 RunState。ConfigFile 仅保存个人成绩，未用于恢复上一局力量。

小车确实继承默认 `LAYERED_CONTACT` 调度，因此补上原契约未覆盖的交互：在开波前创建一只未计入波次账本的真实 CombatRobot，经过真实 coordinator 准入后打开库存，再叠加 ESC 暂停。Engine 的 physics frame 继续前进时，实际模拟 tick、敌人位置、Robot 懒更新冲刺冷却和原生接触冷却全部保持不变；关闭库存不会解除 ESC 的暂停，最后拥有者退出时也不补扣暂停期间的时间，随后真实物理步骤正常推进两种冷却。探针立即释放，未增加战役击杀或波次目标。

本轮在原 Godot 4.6.2 Forward+ / RTX 3060 Laptop 环境完整运行：**519 名终结、12 次奖励、2788 个断言、0 失败、exit 0，无错误或警告**。其中原账本回归 2771 项、5 项实际截图保存、12 项新的活敌暂停集成断言。仍使用 1 HP 的波次结构用例；没有把本轮结果描述为正常血量通关。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --path 'C:/Users/wh/Documents/arc-nice' --scene 'res://dev_tools/verify_vehicle_mode.tscn' --resolution 1280x720 --max-fps 60 --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/vehicle_contract_integrated_final_20260908.log' -- --vehicle-audit-final-contract --capture-ui
```

已逐张读取 `dev_tools/output/vehicle_contract_capture/briefing.png`、`victory.png`、`defeat.png`：1280×720 下目标、成长说明、当前用户键位、得分记录与两个操作按钮均完整可读，无遮挡裁切；胜利画面正确显示 483 击破与 8930 分。原阶段截图另存 `dev_tools/output/vehicle_contract_capture_before_integrated_final/`，没有丢弃前次证据。

终波为 65 名敌人、并发上限 20；现有 DamageResolver 用真实初始配置与保底成长证明最终伤害由 1 提高至 14。没有发现新的确定性“无法通关”缺陷。此结论只覆盖已证明的数值和流程，不从简单驾驶机器人此前死亡反推难度不合理。

07:24 再次以 Win32_Process 命令核实本任务 `--vehicle-audit-*` Godot 进程 **0**，随后明确把 CPU/GPU 验证窗口交给其他任务。
