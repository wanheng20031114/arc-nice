# 2026-09-08 敌人血条与运行时资源审计

本报告覆盖本次全量审查中的敌人血条、场景退出、资源引用与内容完整性。联机同步、建筑生产和小车玩法的结果见同目录其他审计报告。验证引擎为 Windows 官方 Godot 4.6.2 `71f334935`。

## 已修复：敌人血条的重复工作

远端新增的血条采用原生 `ProgressBar`，没有增加每敌人逐帧轮询，这个结构保留。原实现每次生命快照都赋值 `value`，场景的 `Range.step` 又设为 `1.0`。Godot 4.6 的 `Range.set_value()` 即使数值未改变，仍会执行可访问性更新；非零 step 还会进入十进制吸附计算。输入生命值本来就是整数，不需要重复吸附。

修改 `enemy_health_bar.gd`：先计算合法整数显示值，仅在其改变时写入 `value`；修改 `enemy_health_bar.tscn`：设置 `step = 0.0`。最大生命、满血隐藏、死亡隐藏与受伤显示的规则保持一致。

同一进程、300 个血条、各 60,000 次调用的本机微基准：

| 调用类型 | 原实现 | 修改后 | 降低 |
| --- | ---: | ---: | ---: |
| 生命值实际变化 | 154.99 ms | 41.10 ms | 73.5% |
| 重复快照 | 144.64 ms | 26.35 ms | 81.8% |

主代理独立复测约为 159.5/146.9 ms → 41.4/27.0 ms。此数字是血条局部开销，不应解读为游戏整体帧率提升倍数。

验证：`dev_tools/enemy_health_bar_regression.gd` 覆盖边界生命值、最大生命改变、重复快照和原生 `value_changed` 信号；既有 `dev_tools/verify_enemy_health_bars.gd` 覆盖 64 类敌人、1 个 Boss HUD、11 个致死案例，5,309 项断言全部通过。完成后续资源修复后，两者均正常退出。

依据：[Godot 4.6 Range 源码](https://github.com/godotengine/godot/blob/4.6/scene/gui/range.cpp)、[Range.step 文档](https://docs.godotengine.org/en/4.6/classes/class_range.html#class-range-property-step)。

## 已修复：退出时上千资源滞留及访问冲突

这是可复现的问题，不能当作正常 headless 噪声忽略。原始塔防场景退出出现约 1,117 个资源未释放及 Windows `0xC0000005`；编辑器导入退出约 293 个资源滞留。另一方面，三次场景进出后的节点、对象、资源数量均不随轮数增长，所以没有把它归因于“每局敌人没有释放”。

通过只加载资源、不生成任何游戏实体的二分隔离，依赖链收敛为：

`塔防场景 → Rogue 探索 → 浅层矿洞 → 紧急战斗池 → 紧急地下水道 → 迅捷原石虫 + 石头人`

最终不需要任何 `.tscn` 或战役配置即可复现：

| 最小操作 | 原代码退出结果 |
| --- | --- |
| 单独加载原石虫脚本 | 正常，无泄漏 |
| 单独加载石头人脚本 | 正常，无泄漏 |
| 先加载石头人，再加载原石虫 | 正常，无泄漏 |
| 先加载原石虫，再加载石头人 | 293 个资源滞留，`0xC0000005` |
| 先加载骑士基类，再加载石头人 | 同样复现 |

石头人派生脚本拥有两项诊断静态变量。将这些静态存储从 `StoneGolem` 继承图中移到独立的 `RefCounted` 脚本后，同一失败加载顺序恢复正常。新的 `stone_golem_performance_metrics.gd` 仅持有布尔开关和数字字典，不引用游戏脚本、场景或节点。石头人的攻击行为、计时边界、指标含义和三个公开静态诊断方法保持不变。

修复没有增加退出时的广泛强制清理，也没有改动引擎。实测证明这是当前项目中由继承脚本的静态存储触发的退出引用滞留。上游也记录了同版本 GDScript 资源晚于语言运行时销毁导致的退出崩溃，但未经原生调试器确认，不能把本次触发点直接等同于某个上游修复。参见 [Godot #119279](https://github.com/godotengine/godot/issues/119279)。

修复后的结果：

| 验证 | 结果 |
| --- | --- |
| 原石虫 → 石头人最小脚本顺序 | exit 0，零错误、零资源泄漏 |
| 诊断开启、关闭、读取并重置、快照不与共享字典别名 | 全部通过 |
| 完整塔防 PackedScene 加载与释放 | exit 0，无 RID/资源警告 |
| 三轮真实场景启动、30 敌人、冷冻及 600 秒燃烧状态、完整退出 | exit 0，无 RID/资源警告 |
| 64 敌人血条全语义回归 | 5,309 断言通过，exit 0，无退出资源警告 |
| `--headless --editor --import --quit` | exit 0，零 ERROR、零 WARNING |

## 已修复：生产进度测试容器延迟释放

生产进度回归直接继承 `SceneTree` 并静态引用暂停控制器等游戏类型。断言全部通过且退出码为 0，仍会留下 `net_manager.gd`、`settings_panel.gd` 和 `gameplay_pause.gd` 三个脚本资源。完整游戏场景的正常生命周期不复现这一组警告。

将原有断言完整移入可释放的 `production_progress_projection_fixture.gd` Node；原入口保留为轻量 SceneTree runner，动态加载 fixture，等待 `tree_exited`，释放脚本引用并等待四帧后再退出。对照验证保持所有断言通过，同时三个警告全部消失。没有为测试修改游戏暂停或网络逻辑。

## 运行中生命周期证据

三轮塔防生命周期测量采用真实场景和正常 `prepare_for_scene_teardown()`，没有手工清空全局缓存。每轮都对 30 个敌人施加冷冻与长期燃烧，实际确认调度器已登记后退出。

最终异步加载收尾接入后的稳定测量：

| 指标 | 活跃场景 | 每轮退出后 |
| --- | ---: | ---: |
| 节点 | 6,092 | 290（与 autoload 基线一致） |
| 孤儿节点 | 0 | 0 |
| 对象 | 17,497 | 4,711，三轮一致 |
| 资源 | 3,614 | 1,907，三轮一致 |
| 冷冻目标 / 调度堆 | 30 / 1 | 0 / 0 |
| 收藏品状态目标 / 调度堆 | 30 / 30 | 0 / 0 |

首轮后保留的资源是固定加载状态，随后不增长；分配器内存存在约 0.4 MB 的预热波动，不据此断言泄漏。回归脚本现在将退出后节点恢复、孤儿节点归零、状态队列清空、预热后对象和资源数量不增加作为失败条件。三轮测试不能代替数小时真实联机的全部行为覆盖，但排除了这一场景往返与两类长期状态调度的逐轮积累。

详细检查完整日志后，三轮测试最初仍有独立的 ObjectDB 警告：10 个引用数为 0 的原生 `RefCounted`，没有游戏节点或 GDScript 资源。它们对应 `FateCoordinator.setup()` 启动而测试未完成预热消费的 10 个精英资源请求。补充下面的实际应用退出收尾后，同一三轮测试为 exit 0、零警告，证据为 `lifecycle_shutdown_final.log`。

## 已修复：后台资源加载期间退出

主菜单第一帧就启动图鉴后台加载。原“退出”按钮直接调用 `SceneTree.quit()`；窗口关闭虽经过公网房间租约释放，也没有等待后台资源请求。实际复现三次（按钮两次、窗口一次），均在 `THREAD_LOAD_IN_PROGRESS` 时退出，随后出现图鉴卡片和图鉴脚本共八条加载/解析错误，退出码仍是 0。不能用退出码为 0 判定这个路径正常，也不能仅延迟测试退出来掩盖它。

新增独立的 `threaded_resource_lifetime.gd`，仅登记路径与未消费次数，不引用游戏场景或 owner。六类现有加载来源通过它调用原生 request/get：主菜单、场景加载器、普通模式预热、塔防 Boss、命运精英配置、玩家樱花资源。正常图形后端的并发参数保持原值；无头后端的原生并发缺陷规避见下一节。

菜单按钮和窗口关闭现在统一进入 `PublicRoomLeaseStore.request_application_shutdown()`：停止新请求及场景加载推进，完成现有网络租约收尾，逐帧等待已发资源请求进入终态，取回未被旧 owner 消费的结果，释放原生加载 token，再退出引擎。只在终态调用 get，不阻塞主线程等待尚未加载完成的资源。

Godot 4.6 的原生加载器会为每次线程请求保留一个用户 token，正常 get 才会消费它；退出时清理未被取回的 token 有不同的释放路径。这解释了为什么“等到加载完成”本身仍不足以代替“取回结果”。依据：[ResourceLoader 源码](https://github.com/godotengine/godot/blob/4.6/core/io/resource_loader.cpp)、[线程加载 API 文档](https://docs.godotengine.org/en/4.6/classes/class_resourceloader.html#class-resourceloader-method-load-threaded-get)。

`threaded_resource_lifetime_regression.gd` 已验证：同路径两次请求与两个独立取回；接管外部已存在的 native token；失败资源终态的取回；旧 owner 放弃结果后退出收尾；退出开始后拒绝新工作。失败用例主动写入无效资源，只在明确的 `EXPECTED_RESOURCE_LOAD_FAILURE` 标记间产生两条预期错误，其他检查与退出均正常。

一次冷图鉴退出收尾耗时 2,365 ms，其间主循环运行 142 帧，最长帧间隔 16.712 ms，表明等待没有冻结界面。菜单按钮和窗口关闭复测均 exit 0、零警告、零错误。三轮场景进出后通过相同真实退出边界结束，原来 10 个 native `RefCounted` 警告也全部消失。

## 引擎缺陷规避：Dummy 渲染器并发句柄损坏

网络负载中出现过 `Attempting to initialize the wrong RID`、`Parameter "t" is null`、`mesh_clear` 等原生错误。其 GDScript 回溯落在加载进度界面的 `ColorRect.modulate`，不能据此判定是进度条、NinePatchRect 或 AtlasTexture 逻辑错误。

通过完全独立的 Godot 项目隔离：没有 autoload、没有游戏脚本、没有任何 UI 节点，只有一个 SpriteFrames 引用 512 个 4×4 的 ImageTexture 原生资源。按相同路径使用原生线程请求与终态 get，逐个检查取回的纹理图像。

| 后端与参数 | 重复次数 | 有效纹理 / 512 | 原生错误与退出 |
| --- | ---: | --- | --- |
| Dummy，`use_sub_threads=false` | 2 | 512、512 | 每次零错误，exit 0 |
| Dummy，`use_sub_threads=true` | 3 | 509、511、509 | 每次 3–7 条错误，exit 1 |
| GLES3，`use_sub_threads=true` | 3 | 512、512、512 | 每次零错误警告，exit 0 |

原生源码给出了对应结构原因：Dummy 的 `RID_PtrOwner<DummyTexture>` 与 `RID_Owner<DummyMesh>` 没有启用线程保护，而 RenderingServer 在调用线程直接分配 RID，随后才将初始化送入渲染队列。GLES3 对应容器明确使用 `RID_Owner<Texture, true>`。这将原问题收敛到当前引擎的无头资源并发分配，而非游戏 UI。[Dummy TextureStorage](https://github.com/godotengine/godot/blob/4.6.2-stable/servers/rendering/dummy/storage/texture_storage.h)、[RenderingServerDefault](https://github.com/godotengine/godot/blob/4.6.2-stable/servers/rendering/rendering_server_default.h)、[GLES3 TextureStorage](https://github.com/godotengine/godot/blob/4.6.2-stable/drivers/gles3/storage/texture_storage.h)。

仅关闭依赖子线程仍不完整：主菜单同时发出多个顶层收藏品请求时，又复现了同类错误。因此 helper 仅在 `DisplayServer.get_name() == "headless"` 时使用一个 FIFO，每次启动一个原生异步请求，并关闭它的依赖子线程；队列中的状态保持 `IN_PROGRESS` 与零进度，仍由正常逐帧查询推进。每条成功请求都保留独立 native token，不用额外的资源缓存或游戏对象引用替代原生生命周期。实际图形后端直接保留原有并发与缓存参数。

原生 WorkerThreadPool 的最大线程数是初始化设置，脚本没有重新配置接口，而且它影响的范围超出资源加载；Godot 4.6 的默认 feature tags 也不含 headless，不能据此为 Dummy 单独覆盖全局线程池。[WorkerThreadPool](https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html)、[Feature tags](https://docs.godotengine.org/en/4.6/tutorials/export/feature_tags.html)。

某些调用原本允许阻塞首次取回，例如 Player 第一枚樱花火箭。helper 为这一语义在排队时临时增加一个当前 native 请求的引用，再通过原生 get 等待并消费这个临时引用，原 owner 的引用保留。没有用睡眠轮询等待线程，也没有跳过第一发。真实塔防 Player/Enemy 回归分别验证 REUSE、REPLACE、IGNORE 三种缓存模式：火箭确实排队尚未开始，每次第一次触发均生成且仅生成一枚真实投射物，目标与 17 点伤害正确，原任务的两位消费者仍取得相同 Resource，所有计数归零。日志 `threaded_sakura_launch.log` 为 exit 0、零错误警告。

FIFO 合约验证了重复排队路径、实际 native 请求尚未开始、取消后重入、外部已有 token、失败终态以及完整退出。一次冷加载排队收尾为 2,298 ms，138 帧仍可响应，最长间隔 16.691 ms。此前失败的收藏品预热中退出连续三次零错误警告；加载场景过程中关窗、正式场景 PREPARING 时关窗和三轮真实场景往返退出也全部清洁通过。

这是应用层对已复现引擎缺陷的规避，没有声称修改 Godot 引擎。关闭依赖子线程的单次六人对照中，无头加载略慢约 7–9%（host 10,082→11,048 ms，client 约 5,630→6,015 ms），这组数据不代表 FIFO 全量后的最终加载时间，也不能当作游戏帧率提升。完整网络结果另见联机报告。

独立重现工具为 `dev_tools/probe_threaded_texture_loading.py`，它在指定 output 目录生成隔离原生资源工程并记录 PID、错误数与有效纹理数。受影响的 Dummy 参数组合会明确返回失败；没有屏蔽输出。原始证据为 `dummy_loader_results.json` 与 `gles3_loader_results.json`。

另一个明确区分的兼容性限制：以 GLES3 加载完整图鉴时，既有 `hydrangea_rain_tower.tscn` 的粒子子发射器会报告 Compatibility 后端不支持。helper 合约仍然通过且无资源退出泄漏；该警告与 Dummy 句柄损坏不同，也不应从 GLES3 强制测试推断默认图形后端的行为。

## 密度验证容器修正

`tower_density_probe.gd` 改为轻量 runner，玩法对象与所有指标采样迁入可释放的 `tower_density_fixture.gd`。它现在在 deferred activation 下等待正式预热 READY 后再运行，退出前销毁测试容器，并经过真实应用资源收尾。采样结果在等待截图前冻结，避免“请求 600 帧但统计到 601 帧”。增加产水总量及足够长的活跃生产用例必须实际产水的断言。

16 建筑、12 敌人、60 帧烟测为 exit 0、零警告，模拟指标严格记录 60 个物理 tick。大型、混合敌人与实际 GPU 密度测量由主性能审计继续完成，不能由此小烟测推断全场景帧率。

## 资源完整性与解析检查

新增 `dev_tools/audit_resource_integrity.py` 检查 Git 工作集中的 `.gd/.tscn/.tres/project.godot` 显式依赖，并按最近的 `project.godot` 正确解析独立 relay 子项目的 `res://` 根。最终提交前复跑覆盖 598 个 GDScript、836 个资源、364 个场景和 2 个项目配置，共 5,054 条字面量加载/外部资源引用，缺失为 0。

此静态检查针对显式路径；动态拼接的资源路径需要运行时用例覆盖。完整编辑器导入补充了脚本解析与资源导入验证，最终日志无解析错误或导入警告。此前持枪机器人的 SpriteFrames UID 警告来自本地编辑器缓存，源文件 UID 与场景引用一致；正常重新导入后不再出现，无需删除源 UID 或清空整个 `.godot` 目录。

网络测试中加载界面曾出现 dummy renderer `Parameter "t" is null` 的行号回溯，所指源码实际为 `ColorRect.modulate`，不能据此推断它是 NinePatchRect/AtlasTexture 逻辑错误。本审计没有添加 headless 跳过渲染分支来掩盖警告。

## 可复现命令与日志

```powershell
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/resource_reference_cycle_probe.gd -- --enemy-inheritance
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/runtime_resource_lifecycle_probe.gd -- --cycles=3 --enemies=30
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/production_progress_projection_regression.gd
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/verify_enemy_health_bars.gd
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/main_menu_shutdown_probe.gd -- --route=window
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/threaded_resource_lifetime_regression.gd
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --script res://dev_tools/threaded_sakura_launch_regression.gd
& 'C:/Program Files/Godot/Godot.exe' --headless --path . --editor --import --quit
python -X utf8 dev_tools/audit_resource_integrity.py
```

本地证据保存在未提交的 `dev_tools/output/deep_audit_20260908/`：`resource_lifecycle_before.json`、`resource_lifecycle_after.json`、`resource_lifecycle_final.json`、`fast_golem_scripts.log`、`golem_fast_reverse.log`、`isolated_metrics_tower.log`、`isolated_metrics_enemy_bars.log`、`projection_original_afterfix.log`、`projection_final.log`、`import_after_resource_fix.log`、`import_resource_final.log`、`literal_resource_integrity_final.json`。

最终 FIFO 证据：`threaded_fifo_contract.log`、`menu_collectibles_fifo_0.log`、`menu_collectibles_fifo_1.log`、`menu_collectibles_fifo_2.log`、`menu_loading_fifo_final.log`、`menu_prewarm_fifo_final.log`、`lifecycle_fifo_final.log`、`threaded_sakura_launch.log`、`import_threaded_sakura_final.log`。

异步收尾初始证据：`menu_shutdown_before_button_3.log`、`menu_shutdown_before_window_4.log`、`menu_shutdown_fixed_button.log`、`menu_shutdown_fixed_window.log`、`threaded_lifetime_contract_full.log`、`lifecycle_shutdown_final.log`、`density_fixture_small.log`。

验证进程均按启动 PID 记录，仅检查和清理本代理创建的进程；提交前命令核实已记录的 124 个 Godot 验证 PID 均无活跃残留，当时全机 headless/check-only 进程也为 0，没有关闭用户的正常编辑器。后续其他代理的验证进程由各自按 PID 管理。
