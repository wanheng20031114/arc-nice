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
## 全量原生资源加载补充（06:29）

除显式路径与编辑器导入检查外，新增 `dev_tools/audit_native_resources.py` 与
`dev_tools/resource_native_load_probe.gd`，通过 Git 跟踪清单逐项执行原生同步
`ResourceLoader.load(..., CACHE_MODE_REUSE)`。主游戏与独立 Relay 使用各自
`project.godot` 的资源根；所有脚本（包括继承 SceneTree 的测试入口）只加载、
不实例化，不调用它们的 `_initialize` 或测试逻辑。结果保留逐项路径、实际类型、
原生加载耗时、当次源码 SHA256、Git HEAD 与工作区差异。

2026-09-08 本轮结果：主工程 592 个 `.gd`、836 个 `.tres`、363 个 `.tscn`，
合计 **1791 / 1791** 非空加载；独立 Relay 5 个 `.gd`、1 个 `.tscn`，
**6 / 6** 非空加载。两进程退出码均为 0，完整合并日志没有 SCRIPT ERROR、
ERROR、WARNING、ObjectDB 或 RID 警告；耗时分别 11.922 秒与 0.375 秒。
此结论针对清单中的 Git 跟踪工作文件，尚未跟踪的新测试脚本不计入上述数字。
只加载不能证明所有场景实例化后的节点路径、动态拼接资源或 GPU shader 均正确；
正式场景生命周期、实际渲染和玩法回归仍是独立验证。

证据目录 `dev_tools/output/deep_audit_20260908/native_all_resources_first/`：
`metadata.json`、每工程 `manifest.json/results.json/godot.log/source_hashes.json`，
以及命令核实的 `cleanup_verified.json`。独立 owner 标记的 PID 11652、17432
均已结束，Win32_Process 再查 **0 残留**；未关闭其他任务或用户编辑器。

可重跑命令（首次 `--manifest-only` 仅列出清单）：

```powershell
python -X utf8 dev_tools/audit_native_resources.py --output dev_tools/output/native_resource_audit --manifest-only
python -X utf8 dev_tools/audit_native_resources.py --output dev_tools/output/native_resource_audit
```

## 交叉审查：保留有效调度边界，移除紧邻重复通知

`Enemy._clear_cached_navigation_move_direction()` 入口本身就调用 urgent 通知；
随后的字段重置与 `FlowQueryContext.invalidate()` 没有信号或用户回调。
原 8 个调用点在相邻位置再次发送同一通知，重复进入所属注册表、事件唤醒与决策排队。
现移除这 8 次相邻调用，保留 objective 属性 setter、同步 `objective_target_changed`
回调和真正接触/移除变化各自的通知。未采用跨帧缓存，也没有跳过已提交攻击期间的
动态目标更新；后者仍可能改变指定目标的失效、负缓存与自动回退状态，不能当成纯读删除。

扩展的 `enemy_work_queue_regression.gd` 38 个断言全部通过，覆盖首次/已有玩家目标、
相同目标无变化、同步目标监听者的真实重入通知、接触批次变化与相同批次静默、最近选择、
死亡/移除、稀疏队列唯一性，以及原有同帧 ID 顺序/已消费游标和首次激活边界。
原 `enemy_transform_scaling_regression.gd` 2435 个断言全部通过，继续检查真实场景下
最近接触目标、死亡/水陆/有向阵营、几何及注册生命周期。两项最终退出码 0，日志没有
ERROR/WARNING；命令核实专属 `--resource-audit-wake` 验证进程 0 残留。
证据为 `wake_queue_retry.log`、`wake_contact_final.log`、`wake_cleanup_verified.json`。
初版测试错传了移除回调参数，已修正后重跑；该首次失败日志保留，未计为通过。

## 远程敌人：先检查确定禁止移动的攻击状态

`LayeredRangedEnemy._can_run_layered_area_motion()` 原先先执行
`SimpleChaseLayeredEnemy` 的目标/接触检查，再查询具体家族的纯 bool 状态门槛。
AK47、Mage、RPG、Sniper、Fire、Frost、Lightning 在 WINDUP/BURST/LOCK/SUMMON，
以及已消费最后一发的 CHASE tick 都明确禁止移动，却仍然重复选择接触目标。
本次只交换这两个短路谓词的顺序；SMG 的家族门槛恒 true，仍完整进入原接触检查，
Gunner 自己覆盖运动门槛，不受这个基类方法影响。

这项修改允许无关 stale 接触成员及其重复 urgent 通知延后到下一次真实接触查询清理，
不要求内部字典每个相位完全相同。实际观察边界保持：7 族完整 decision interval 均为 1，
锁定状态的 family event sleep 恒 false；动态目标刷新、family decision、事件 touch/delta
维护、facing、伤害结算均未跳过。实际攻击通过 `get_contact_combat_target()` 重新选择，
攻击状态推进直接验证已提交目标；重新允许 CHASE 时才走原生接触门槛。`_is_combat_sense_refresh_due()`
只读物理帧与固定相位，不依赖被省去的 urgent 次数。没有引入缓存、额外采样间隔或新队列。

新增 `ranged_motion_gate_regression.gd` / `ranged_motion_gate_fixture.gd` 在正式 TD READY
后实例化 7 族真实场景；比对空/活玩家/死玩家/活建筑/死建筑/移除中建筑/友方/恢复敌对/
已释放玩家，以及已消费事件的 CHASE、死亡攻击者。AK47 另用同一实际 physics tick
同时推进 authored LEGACY、原顺序 layered 和新顺序 layered，比较逐 tick 状态、移动、
子弹数、冷却、前摇和已提交目标。该三路使用仅改门槛的测试派生脚本，手动调用真实相位，
因此并不声称它自身验证 exact-script coordinator admission；真实注册继续由原
`enemy_transform_scaling_regression.gd` 覆盖。

初轮 fixture 关闭 runtime 自动处理时，未设置测试碰撞身体的原生 KEEP_ACTIVE，导致
CharacterBody2D 脱离物理 space；另外串行运行的三路落在不同 20 Hz sense 相位，产生了
伪差异。已把测试身体保留在物理世界，并在同一 physics frame 推进三路，完整保留首次
失败日志 `ranged_motion_gate_first.log`。随后 `ranged_motion_gate_retry.log` 463 项通过，
exit 0 且无 ERROR/WARNING。最后一发实际保持当 tick 静止、下一 tick 才追击；死亡/友方
目标在发射前取消。6 万次锁定门槛微基准：原 206.3 ms / 60000 次 contact scan，
修改后 27.3 ms / 0 次。它只代表该局部门槛，不代表整局 FPS 或 CPU 总收益。


## 稀疏事件睡眠：推迟纯读的接触冷却证明

`SimpleChaseLayeredEnemy._can_enter_layered_area_event_sleep()` 提前计算的
`_has_sleepable_layered_touch_damage_cooldown()` 只读时钟、目标与阵营，不承担清理或通知。
现将调用保留在原 OR 表达式内，让死亡、无有效静态目标、运动状态未知、family 必须
保持活跃等门槛先短路。没有把 deadline 推导缓存到新字段；实际允许 sleep 时仍按原
路径再次读取 cooldown deadline，保持每族取最早截止帧的协议。

新增 truth-table 在 768 个组合检查旧/新结果、deadline 不变以及实际 helper 调用次数，
包括 null/static/dynamic 目标、死亡、未知运动、family awake、接触空/活/死/已释放、
无冷却/未来冷却/已过期/暂停冻结，以及是否能够移动。初次扩展运行全部通过；同轮
释放已提交目标测试揭露了下述旧问题，因此整次运行未计为成功。

## 释放目标的类型校验顺序缺陷

真实 AK47 在跨 tick 保留的 `attack_target` 已经 free 后，将该失效引用直接传入
`_is_ranged_combat_target_valid(target: Node2D)`。Godot 在进入函数前就拒绝 freed Object，
内部 `is_instance_valid` 检查无法执行。LEGACY、原顺序 layered、新顺序 layered 三路
均连续报同一错误并保持 WINDUP，不是本次 motion gate 重排造成的问题。
`ranged_motion_gate_final.log` 保留该 2788 项扩展运行的完整失败证据；其余边界通过。


随后在 7 族真实场景中分别于事件开始前、事件结束后/发射决策前释放实际敌人目标，
并测试三族法师的感知缓存释放。修复前 `ranged_lifetime_before_fix.log` 记录 **40 个
SCRIPT ERROR**，涉及全部 7 族；修复只在缓存持有者首次跨 tick/phase 读取字段处
增加 `is_instance_valid` 短路，随后沿用原来的类型化目标、距离、视线、取消与冻结阵营
逻辑。没有把公共类型改成 Variant，也没有给同一同步调用链每层重复增加检查。

最终 `ranged_motion_lifetime_fixed.log` **2827 项通过，exit 0，零 ERROR/WARNING**。
其中 768 项 sleep 组合各验证结果/时钟不变/调用次数；释放目标的所有前后相位均安全取消，
既有冷却只按原时钟推进。三路 AK47 最后一发各自实际注册到 RapidFire service，活跃
记录合计增加 3，当 tick 不动、次 tick 恢复；目标死亡/转友方/移除/释放均不会额外发射。
`ranged_motion_contact_final.log` 原 **2435 项真实目标选择/接触/注册回归再次通过**，
exit 0，零 ERROR/WARNING。门槛局部最终微基准为 60000 次：motion scan
192.1 → 28.7 ms（60000 → 0 次接触查询）；family 已禁止睡眠且有活接触冷却时，sleep
proof 162.8 → 28.6 ms（60000 → 0 次冷却证明）。后一组特意包含有效接触冷却，
不能外推到没有 touch cooldown 的远程敌人或整局帧率。

最终阶段全部专属测试 PID 8884、3620、2096、18176、6716、10712 经 Win32_Process
按 PID/owner marker 核实为 **0 残留**，证据 `ranged_motion_cleanup_verified.json`。
上述输出均在 `dev_tools/output/deep_audit_20260908/`；失败日志完整保留，不混入成功统计。


## 接触更新中的同步重复查询（07:27）

保留全部接触选择、过期清理、目标优先级、有效 delta 记录、冷却/伤害和 urgent 通知。
`Enemy._update_touch_damage_unprofiled` 只有外层的两个调用者，而外层刚对相同的
“两个接触集合均空且无动态接触”条件返回，因此删除内层不可命中的二次 guard，
并删除没有读取的 delta 形参。动态 Enemy 接触是纯读取：runtime getter 仅取已有节点，
contact service 仅读 entry/current-contact 字典。植物选择间的过期记录清理只断开信号、
删本地成员、清导航和标记调度队列，不执行回调、不改变目标/位置/阵营或 contact service。
因此在已有有效植物优先目标时可省略动态接触查询；否则才查询，空集合的原 fast-return
仍保持。没有删除 weapon-only 家族的整段 touch 更新，也没有改 Gunner 的真实接触伤害。

`_select_touching_plant` 在完成存活/移除/水陆/敌对验证后，若候选距离严格更远便跳过
无用的稳定 ID 读取；首个候选和相等距离仍走原 net_id/instance_id tie-break。严格 `>`
在 NaN 时为 false，沿用原后续处理，未加新浮点兜底。过期候选始终先清理再考虑距离。

新增 `touch_update_order_fixture.gd` / `touch_update_order_regression.gd` 复用前阶段 7 族
真实相位/lifetime/sleep 回归，增加 AK47/RPG/Gunner 60 组空/玩家/植物/混合/死亡/
释放/动态 Enemy 接触 × 冷却状态的旧算法对照；比对选中对象、成员数、delta、冷却时间
与 deadline、实际生命变化、尝试次数和唤醒次数。动态场景验证了真实 Enemy 接触成立；
Gunner 实际命中玩家、植物和 Enemy，AK/RPG 保持无隐形 touch 伤害。
最终 **2979 项通过、exit 0、无 ERROR/WARNING**；原真实接触/注册回归 **2435 项再次
通过并清洁退出**。首轮仅 fixture 虚设 1e7 玩家生命与第一次受伤触发正式 50 HP 属性
重算不一致，已使用角色真实 maxHP 初始化并完整重跑，失败结果没有计为通过。

独立旧算法 reference（保留原重复 guard，但未计额外内层 VM 调用）对照新生产代码，
60000 次已有有效植物接触更新为 327.5 → 267.8 ms，动态查询 60000 → 0。
32 候选 × 2000 次选择：近者先入字典 105.2 → 93.4 ms；混合顺序 106.5 → 93.8 ms；
距离持续递减、无法省略 stable-ID 读取的对照 108.1 → 112.2 ms；全等距 108.9 → 104.2 ms。
后两项说明额外距离门槛并非所有排列都加速，不能只选最好数字；这些都是局部微基准，
不是整局 FPS。部分动态查询从外层推迟到计时的内部区域后，诊断 `touch_damage_usec`
覆盖范围略增，跨阶段的该计数不能直接当同口径 CPU 优化率。

证据：`touch_update_order_first.log/json`、`touch_update_order_final.log/json`、
`touch_update_contact_final.log`、`touch_update_cleanup_verified.json`，均位于
`dev_tools/output/deep_audit_20260908/`。PID 3820、11688、1732 及专属 owner marker
经过 Win32_Process 检查 **0 残留**。

## 收尾时的最终完整性复核

用户恢复中断任务后限定只做收尾。撤回未完成验证的集水器显示和额外接触实验后，
原生编辑器 import 正常 exit 0，无错误或警告，并补齐本任务新增脚本的 UID。
随后同一全量加载工具检查最终工作区：主工程 **1820 / 1820**（617 脚本、836 资源、
367 场景），独立 Relay **6 / 6**，共 **1826** 项全部非空原生加载。
两个引擎进程均 exit 0，零 SCRIPT ERROR、ERROR、WARNING、退出资源滞留。

这是所有受 Git 跟踪脚本/场景/资源的原生加载与解析，不等于逐个实例化全部场景；
战役、塔防、网络与暂停的实际交互证据见对应专项报告。未在收尾阶段新增功能或压测。

记录：`dev_tools/output/deep_audit_20260908/native_all_resources_closeout/`，含逐资源
SHA256、版本差异、原生日志、完成计数与退出码。最后 Win32_Process 再次专门检查
Godot 的 `--headless`、`--check-only` 和任务 owner 参数：**测试 Godot 0、全部 Godot 0、
本任务 Python 验证辅助进程 0**。清理证据为
`dev_tools/output/closeout_process_cleanup_20260908.json`，没有关闭用户正常编辑器。
