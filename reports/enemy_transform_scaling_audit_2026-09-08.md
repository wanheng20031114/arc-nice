# 敌人变换与接触热点检查（2026-09-08）

## 已验证的结构改动

`CombatContactShapeProxy` 是不可变的纯平移接触几何。原来每一次根节点移动通知都会重算形状变换的轴长度、点积、行列式、旋转角和缩放，即使本次只改了位置；接触走廊判定又重复获取根变换并与形状局部变换相乘。

现在代理在捕获时保存已经验证过的两条基轴。运行时仅当 `x`、`y` **精确相等**，且新位置有限时直接认可纯平移；发生任一基轴变化时继续原有完整验证，保留原始容差和拒绝状态。不会把“与上一帧很接近”连锁缓存，因此微小旋转不能逐帧积累成漏检。接触协调器向走廊检查传入同一已获取的形状变换，省去重复的 Node2D 访问和矩阵乘法。

`Enemy` 的已验证直接移动判定先检查证书存在、目标有效、导航版本一致。没有证书的普通阻挡移动无需再做方向长度/动态目标点积计算，仍进入原生 `CharacterBody2D.move_and_slide()`；合法直接移动仍保留全部净空、方向、导航版本、动态目标在前方的条件。没有扩大净空范围、删除物理测试或替换真实接触形状。

接触目标选择中，原 `_select_touching_plant` 对每个候选先执行 `can_attack_plant_target`，再经 `can_attack_combat_target` 重复类型转换、生命/移除/水面规则检查；玩家选择也重复检查共同阵营。现在每次同步选择只计算一次对玩家共同阵营的有向关系，每个候选仍即时检查生命、移除、排队删除和水建筑规则。敌人与建筑的接触阻挡判断使用同一去重方式；距离/网络 ID/实例 ID 和玩家 peer ID 的排序规则完全保留。没有跨帧缓存友军关系或目标存活状态。

依据 Godot 官方 [Transform2D](https://docs.godotengine.org/en/stable/classes/class_transform2d.html)，`x`、`y` 完整表示旋转、缩放与倾斜，`origin` 单独表示平移。测试墙采用原生 [StaticBody2D](https://docs.godotengine.org/en/stable/classes/class_staticbody2d.html) 与 [CollisionShape2D](https://docs.godotengine.org/en/stable/classes/class_collisionshape2d.html)，场景结构保留在 `.tscn`。

## 回归与测量

保留的回归入口为 `dev_tools/enemy_transform_scaling_regression.gd`，主循环不持有玩法脚本静态引用；实际类型加载和资源由可销毁的原生场景 `enemy_transform_fixture.tscn` 承担。

- 最终含选择循环及 ABBA 的回归：**2443 个断言、0 失败、退出码 0，无警告**，日志 `dev_tools/output/enemy_transform_regression_final.log`，机器可读结果 `dev_tools/output/enemy_transform_regression_final.json`。本轮基于 `5abc407c2f313d6094fd541d1dad39a35e78f86e` 加本报告列出的三项生产源码改动。
- Circle/Capsule/Rectangle/ConvexPolygon/Segment、偏移和非凸 Compound；多组初始旋转/缩放，平移、改变旋转、缩放、非均匀缩放、反射、倾斜、NaN/Infinity、零基轴、细小旋转累积和恢复原变换。返回状态逐项与保留在测试中的原实现对照。
- 复合形状间隙不会变成凸包或包围盒接触；沿间隙的高速扫描保持无接触，真实穿过子形状的高速扫描仍检测命中；胶囊长轴不会变成包围圆。
- 原生剑士场景朝真实墙连续发起 30 次移动：30 次 `move_and_slide`、0 次无证书直接移动，未穿墙，未凭空产生伤害。
- 真正的塔防运行时内，骑士、剑士（复合形状）、AK 猫猫虫、石魔完成注册、纯平移复用、旋转失效、显式局部形状位置更新、原生 Shape2D.changed、退役和错误 token 拒绝。主战精英仍使用原有兼容接触方式；测试不会为了获得共享代理而改变其能力声明。
- 三个实际生成的建筑和两个真实玩家节点验证距离/网络 ID/实例 ID/peer ID 优先级、即时死亡和移除、水建筑排除、单向敌对改变与恢复、敌人自身阵营改变；计数版关系服务明确验证一次选择只有一次共同阵营查询。

微基准使用同一方法签名、相同基类实例访问和相同的 100000 次调用，每次均核实 100000 次接受；原实现放入测试用子类，避免用动态属性访问造成不公平对照。最终 ABBAABBA 样本中，原实现中位 **112.951 ms**，优化后 **49.402 ms**，纯平移校验成本下降 **56.26%**。这是局部函数测量，**不能推导为整体 FPS 增长 56.26%**。首次回归错误假设主战精英应注册共享接触，已纠正测试预期；保留该次原始失败日志及随后 2417 断言通过日志。最终所有数据来自完整通过的 2443 断言轮次。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/enemy_transform_scaling_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/enemy_transform_regression_final.log' -- --vehicle-audit-enemy-transform --benchmark --output=res://dev_tools/output/enemy_transform_regression_final.json
```

省去 `--benchmark` 可执行轻量功能回归；用 `--output=res://dev_tools/output/another_result.json` 保存独立结果。

截至北京时间 05:53:55，已通过 Win32_Process 命令筛选 `--vehicle-audit-*` 标记，验证辅助 Godot 进程残留 **0**；没有关闭正常编辑器或其他任务进程。随后明确把 CPU 窗口交回网络压力测试，冻结这三项生产源码，避免性能样本读取到修改中间态。

## 剩余热点

正式十二波后期混合敌人样本显示，事件、决策和通用目标有效性判断仍然占主要 CPU 时间。当前改动消除变换重复校验，不宣称已解决全部帧长尾；根任务继续检查阵营查询、建筑目标选择及六人真实 Relay 数据。

## 后续阶段：有序事件/决策队列

事件 ready 队列通常沿用上一帧的模拟 ID 顺序，但 `_insert_event_work_registration` 和 `_insert_decision_work_registration` 之前对每个有序尾项也执行 GDScript 二分查找和 Array.insert。现在只增加一个明确的尾 ID 判断：当队列为空或新 ID 大于末尾 ID，直接 append；否则仍使用原有二分插入与 `minimum_index` 游标边界，重复帧和墓碑检查保持在最前面。

独立 `dev_tools/enemy_work_queue_regression.gd` 验证已排序、倒序、乱序、同帧重复、已移除节点、最小插入边界、事件中更高 ID 唤醒/插队、不得回访已处理 ID、决策中同帧紧急请求、新注册初帧隔离。**40 个断言、0 失败、退出码 0、无警告**；完成后命令核实该任务 Godot 进程为 0。

同签名 ABBAABBA、每样本 200 轮×300 条有序工作：事件队列中位 91.838 ms→41.379 ms（约 -54.94%），决策队列 87.937 ms→38.520 ms（约 -56.20%）。同样只表示局部有序构建成本，不冒充全场景帧率。日志与原始 JSON 保留在 `dev_tools/output/enemy_work_queue_regression_final.log`、`dev_tools/output/enemy_work_queue_regression.json`。

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path 'C:/Users/wh/Documents/arc-nice' --script 'res://dev_tools/enemy_work_queue_regression.gd' --log-file 'C:/Users/wh/Documents/arc-nice/dev_tools/output/enemy_work_queue_regression_final.log' -- --vehicle-audit-enemy-queue --benchmark
```
