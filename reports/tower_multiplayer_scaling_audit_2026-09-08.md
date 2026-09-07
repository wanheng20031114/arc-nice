# 塔防多人高密度性能与复制审计（2026-09-08）

本报告记录网络子系统的证据、修复与限制。建筑生产、接触战斗、小地图、血条与资源生命周期的独立检查由同一任务的其他报告补充。测试机器为 Windows、Ryzen 9 5900HS（8 核 16 线程）、32 GB 内存、Godot 4.6.2，实际运行原生 ENet Host 与独立 Client 进程。

**网络结构热点已得到修复，但正式第 12 波混合敌人、256 建筑、6 人同机 Relay 压力仍明显超过 Host 实时仿真能力。** 截至 06:32 的长测，1800 个物理 tick（30 秒游戏时间）实际用了 58.66 秒，Host process p95 为 296.70 ms。所有端库存和 revision 一致、没有不完整快照淘汰、退出干净，不代表游戏已经流畅。基础近战敌人的结果不能替代混合后期场景；此限制必须进入交付结论。

## 已确认的根因与修复

### 1. 为决定发送频率，每个物理帧重新遍历全部网络敌人

旧 `CombatRuntimeBase.get_network_enemy_count()` 调用 `get_network_enemies().size()`：先构造 ID 数组，再逐个验证正反向注册关系，最后构造 Enemy 数组。Host 每个物理帧都会调用，原来的整批编码还再次调用。300 个敌人的稳定场景，每 5 秒约 400 次全表扫描，与敌人实际增删无关。

修复使计数读取唯一权威注册字典的 `size()`，不维护第二份计数缓存。注册时连接原生 `tree_exited`，使用 `CONNECT_DEFERRED` 在本帧延迟阶段清理没有被模式生命周期消费的退出节点。正常 Tower/Wave 同步 `tree_exited` 仍先从注册表取得 net ID，完成 `DEFEATED/REMOVED/ESCAPED` 的终结与广播。重挂同一节点时，旧延迟退出回调不会注销其新挂载。

这一顺序是必要的：初稿使用 `tree_exiting` 立即注销，会让原有模式的 `tree_exited` 拿不到 net ID。代码评审发现后已改正，错误版本没有提交。回归包含两种信号连接顺序、真实 Tower/Standard 终结方法和真实 `WaveEnemyTerminalLedger`，并验证了败亡/移除/逃逸的准确发包数量。

300 个正式 Enemy 场景，计数 1000 次：旧路径约 297–302 ms，新路径约 0.13–0.15 ms。反复注册、变更 net ID、替换同 ID 实例、直接 free、queue_free、remove/readd、显式注销、错误 expected instance、整局清理均通过。

### 2. 敌人增量编码重复量化、验证、复制与缓冲区增长

优化前，300 个敌人的 100 次快照采样中，状态采集 172.5 ms、编码 307.0 ms、整个 cohort 分发 22.0 ms。其中真正的原生敌人 RPC 调用只有约 9.9 ms / 800 次。证据指向 GDScript 状态处理，而不是 ENet 发包本身。

旧发送基线保留完整浮点 `EnemyState`。比较每个字段时重新量化当前值和上次值，写入时再次量化当前值，再把完整状态复制到发送基线。协调器验证整批后，每个分块还验证一遍。

修复后：

- 发送基线使用专用 `EnemySendState`，直接保存上次实际写入的量化整数；当前浮点坐标与速度每批只量化一次。
- 整批一次验证成功后再编码各分块，末块非法不会提前提交前面分块的发送基线。
- 使用原生 `StreamPeerBuffer.resize()` 一次预留分块最大容量，完成后裁到实际 delta 长度。
- 现有 cohort 仍只编码一次，给所有已就绪成员复用；不降低原有 20/30 Hz，不增大关键帧间隔，不扩大 41 敌人 / 1191 byte 分块预算。

300 个敌人 × 240 个变化样本，共 1,764,840 bytes 与原 writer 逐字节一致。覆盖负坐标、饱和值、低于量化精度的运动、启停、治疗与 revision、死亡、表现位、阵营 trailer、自发全字段 delta、同 ID 新 incarnation、重连新基线、清会话以及末块非法原子拒绝。

5 轮交替执行旧/新编码，旧约 652–730 ms，新约 357–405 ms，编码 CPU 减少约 44%。此处为编码微基准，不是整局 FPS 提升比例。

### 3. 生产状态以重复字典经可靠通道逐成员序列化

生产进度每秒变化时，原先立即导出字典，延迟 flush 再深拷贝，然后每个成员分别原生 Variant 序列化。同一物理阶段内多次状态修改还会反复导出相同建筑。

修复保留 1 Hz 可见语义、revision/CAS、完整绝对状态与 reliable CH6。变更回调只记录脏建筑与采样时间，flush 导出最终状态一次。每个共享批次一次 native Variant 编码和 ZSTD 压缩，各成员复用同一 `PackedByteArray`。按实际压缩字节递归分块，包预算 1152 bytes；解压前检查 schema、精确原长度及 128 KiB 分配上界。解码拒绝尾随数据、列不匹配、非法时间/ID 等，仍由原生产协议验证 schema/revision。

24 个典型建筑：9744 bytes → 789 bytes，减少 91.9%。给 5 个远端成员的应用载荷估算为 48720 → 3945 bytes。300 批次的旧 5 次 Variant 序列化约 85–92 ms，新的一次压缩加 5 次小包序列化约 24–26 ms。准确浮点时间、64 位 revision、已销毁脏建筑、旧 revision/时间拒绝和更新修复均回归通过。

### 4. 生产完成时的仓库网络导出与持久账本重复转换

真实 2 人、400 建筑、300 敌人的 `-d --profiling` 把尖峰定位到 100 个水收集器同一秒完成产出。代表性脚本帧总计 125.5 ms，其中生产 tick 34.9 ms；仓库 journal 发布 16.3 ms，网络仓库变更回调 15.3 ms，其内部同步持久化 12.3 ms。对比没有产出的生产 tick 约 4.0 ms，说明仅测进度变化会漏掉真正的生产写入尖峰。

网络回调改为只保存脏仓库引用，在同一轮 flush 导出最终完整状态一次；仓库不再存在或已移除时不发送。100 个连续 storage 信号，flush 前网络导出 0 次、flush 后 1 次，最后 revision=99。原有同步持久化仍在每次信号时执行 100 次，没有把原子账本延后到网络 flush。

团队随后优化 `RunState` 与 Bridge 的受信本机路径：直接接收正式资源数组并一次编码，保持每次事件同步提交、revision/CAS、容量与物品合法性检查；不可信网络字典仍经过原严格解码。500 次单槽写入约 41.7→15.8 ms，20 满槽约 115.3→61.3 ms。该微基准不直接等于整局尖峰减少比例，实际后期混合敌人仍须单独测量。

### 5. 中继逻辑断开延迟与原生 ENet 物理断开之间的竞态

真实两人 Relay 正常结束时曾触发 `Invalid target peer`：包装层为了消费已排队的入站消息，将逻辑 peer 移除延后一个 poll；原生 ENet 同时已移除物理 socket。原转发代码只检查认证名单，因此仍会向逻辑在线、物理已断开的目标发送。

修复使用已有物理 peer 注册表，在转发选择和最终 `_write_transport_frame`（包括 connect 信号期间延迟的写入）检查目标可达性，不新增全表扫描或第二套连接状态。已断开的目标返回明确连接错误，保留原逻辑断开顺序，其余认证成员继续转发。

`relay_disconnect_race_regression.gd` 是“原生 ENet transport 边界 + 确定性状态夹具”：打开真实本地 ENet server，再手工安排认证/物理字典的断开窗口，覆盖定向、广播、可靠/不可靠以及延迟写入。它不等于多端实网测试。另有实际 6 游戏进程 + 1 Relay 进程的认证、游戏转发和正常离开集成，相关 Relay 日志没有再出现无效目标错误。

### 6. 敌人表现状态每次快照重复四轮扫描

在没有开启原生函数 profiler 的真实六人运行中，Host 每秒为 300 个敌人采样 20 次快照。旧 `Enemy.get_collectible_visual_status_mask()` 为燃烧、流血、标记、电磁分别扫描一次同一效果字典。新实现一轮遍历设置对应位，保留逻辑时钟过期边界、旧 `time_left` 表示、永久电磁状态，以及独立的减速倍率判断。三个带额外状态位的子类继续通过 `super` 叠加。

2184 项状态与边界断言通过。24,000 次调用，空效果约 46.0→12.0 ms、单效果约 100.1→28.7 ms、6 效果约 317.5→106.7 ms、24 效果约 796.0→378.9 ms。没有增加可能延迟过期或修改可见性的缓存。

### 7. 客户端敌人快照重复读取三次

新增默认关闭的接收阶段计时后，真实六人运行每个客户端约 10 秒中，敌人快照接收消耗 1.80–1.89 秒 CPU。原流程先预扫描结构与 ID，再完整解码并提交，最后重新打开 buffer 读取头部检查数量。

新网络入口将已有的批次 ID 集合传入唯一 staging 解码过程，同时校验包内/跨块重复、所有字段、完整长度与缺失增量基线；全部合法才提交基线和输出实体。协调器在解码前仍拒绝批次 metadata 不匹配、数量越界和空头部尾随数据。无效的新高 batch ID 不会推进接收水位。旧独立解码接口原有的“跳过缺失基线的 delta”语义保留，严格网络入口要求每条可恢复。仅用于显示预算的代理范围查询采用团队新增的无序查询，成员集合语义不变。

3401 项回归覆盖首/末条非法、每个截断位置、保留位、health/revision/faction、重复 ID、缺少基线、乱序分块、空批次和新高 batch 水位；实际 42 个注册 Enemy 参与协调器用例。300 敌人 × 120 样本交替运行，旧流程 417.96–426.25 ms，新流程 336.70–344.03 ms，解码流程 CPU 下降约 19.5%。之后真实六人混合 1800 tick 整合严格通过。

### 8. 实际断线恢复发现的身份与时钟错误

原身份重连最初在真实 LAN 测试中失败，Host 报“无法迁移地下探索路线身份”。原因是普通塔防只在首次进入地下探索时配置内嵌路线身份，重连却无条件尝试迁移未初始化的路线。修复读取已有 `_route_identity_configured` 与 `_active`，仅在确实存在路线身份或探索已 active 时执行严格投影。曾经初始化但目前 inactive 的路线仍迁移旧/new peer 的头像与商店身份；active 而身份异常缺失也不能越过原失败检查。

身份成功恢复后，进一步发现全部建筑能重建，敌人却一直为 0。重连客户端重新建立会话时钟；此前出生的敌人，其原始 Host 时间合法，但映射到新客户端时钟后可能为负数。旧 `_prepare_client_spawn` 错把这个映射值再拿去执行原始 wire 的非负校验，导致整块 spawn 被拒绝。修复对原始 incarnation token 保留非负验证，对本地映射时间只要求有限，不做 clamp。16 项单元断言覆盖精确负映射、幂等、旧 incarnation、非法 Host 时间/offset/path、批次首/末条非法和终结墓碑；真实 Enemy 与注册表参与测试，仅出生 VFX 用计数替身隔离。

同时修复拒绝连接的延迟收尾：等待 0.1 秒后，原 transport 或 peer 可能已经离开。回调持有并校验原 transport 身份，再检查当前 peer 集合，避免向已断开的原生 ENet peer 查询句柄，也避免旧回调作用于新会话。

恢复夹具还修正了一处测试身份问题：不能通过复制 `EnemyConfig` 后修改 health 来维持密度，因为复制资源的 `resource_path` 为空，正式完整 spawn roster 正确地拒绝未注册配置。当前夹具保持正式 catalog 配置，使用已有的运行时生命倍率并保持满血来获得 10,000,000 生命；没有放宽生产路径的 catalog 验证。

## 实际多进程测试方法

`dev_tools/run_tower_multiplayer_density_probe.ps1` 启动一个正式 Host 与 N−1 个独立 Client。各进程使用正式 NetManager 准入、成员确认、GameLoadCoordinator、开局加载屏障、MpGame RPC、原生敌人/建筑场景和实际代理。

密度夹具在正式地图合法未保留的 2×2 格中放置等量玉米机枪塔、龙舌兰炮、水收集器、橡木仓库，敌人为基本/硬壳原石虫 4:1。仅为稳定测量，关闭自动下一波、地形衰减并把建筑/敌人/玩家生命设为 10,000,000。生产、索敌、碰撞、接触伤害、建筑射击、原生运动、复制和客户端插值照常执行。部署阶段绕过购买和地形限制，以直接达到目标密度。

**正式多人队伍建筑准入上限原本为 256，未改变。400 建筑用于超额压力测试，不能称为正常 UI 可创建的对局。** 256 建筑另作为正常上限验收。所有成员分别确认已收到预期建筑/敌人数量后，预热 120 个物理帧，再采样。共享目录只用于启动信息、保存测量和协调结束，场景与实体同步均通过 ENet。

默认测量关闭 Enemy 细项、网络 CPU 计时和额外 Variant 载荷估算，记录墙钟间隔、既有快照/包计数、输入序号、生产结果、节点和内存。`-DetailedMetrics` 显式开启仿真/网络分阶段累计 CPU 和应用层估算字节；这种运行用于定位、不能当作默认体验。载荷估算关闭时，一些 RPC 通道字节为 0 表示未测，不表示该通道没有流量。原生敌人 packed snapshot 的已知字节计数仍有效。

`-ActiveInput` 为所有进程按正式 Input action 左右移动、持续向上射击，核对客户端已发送的输入序列、Host 已接受的每人序列及各端实际分配的本机弹体。生产配方仅在各进程内存把采水周期从正式 20 秒加速到 5 秒；磁盘资源不改，以便 600 tick 内覆盖至少两轮产出。所有端采样结束后，Host 才停止生产 Timer 并生成一个共同终态，客户端必须经真实可靠复制收敛到相同水数量和逐仓 revision 才通过。

`-EnemyWave res://.../wave_12.tres` 使用正式波次权重生成 300 个混合敌人并记录构成、实际最小/最大/末数量，不强行阻止正式自终结行为。默认 basic/shell 只代表基础近战密度，不能代表后期远程、连发与范围效果敌人的 CPU 成本。每轮记录 Git 提交、工作区源码 SHA-256、加载子线程参数和各端加载时间。

注意：Godot `Performance.TIME_PROCESS/TIME_PHYSICS_PROCESS` 部分监视器最长约 1 秒更新一次，其值的分位数不能当成逐帧原生 CPU 的精确分位数。墙钟 16.67 ms 包含等待与调度，也不能减去脚本 5 ms 后，把剩余 11 ms 直接解释为 physics CPU。实际函数热点用 `-d --profiling` 单独定位，不使用开启函数 profiler 的运行来报告 FPS。

## 初始复现证据

输出目录位于忽略的 `dev_tools/output/`，最终报告保留摘要，脚本可重新生成。

| 运行目录后缀 | 场景 | 主机 process p95 | 客户端 process p95 | 说明 |
| --- | --- | ---: | ---: | --- |
| `tower_network_20260908_045236` | 6 人、400 建筑、300 敌人 | 182.005 ms | 26.04–30.41 ms | 初始稳定密度，主机 300 个物理 tick 仅 37 个 process frame；复现主机连续追赶多个 physics tick 的容量崩溃 |
| `tower_network_20260908_045440` | 2 人、400 建筑、300 敌人 | 43.731 ms | 20.089 ms | 便于分离同机 6 进程争抢 CPU 的影响 |
| `tower_network_20260908_050157` | 2 人、400 建筑、300 敌人 | 31.168 ms | 另见原始 JSON | 敌人采集/编码/发送细分；后续全量计数与量化基线修复前 |

初始 6 人测量中，6 个进程均实际保持 400 建筑和 300 敌人。每个 Client 完成 157 个敌人快照批次、丢弃 4 个不完整批次，采样阶段没有额外 runtime repair。Host 初始完整修复为每个成员一次。2 人初始稳态 Host→Client 大约 CH2 玩家 9.6 KiB/s、CH3 敌人 56 KiB/s、CH4 弹体 2.5 KiB/s、CH6 生产 1.9 KiB/s。这些是应用侧抽样估算，未包含全部 ENet/IP 重传与链路开销。

上述初始测量完成，但当时引擎退出仍打印已知的资源/RID 残留错误，所以严格 runner 返回失败。不能把有 JSON 测量结果等同于整套测试无错误通过。该资源问题由独立资源生命周期审计继续定位。

## 整合实测与可达上限

除明确注明外，下面各运行均实际按 Input action 移动和射击，原生 Relay 负责票据认证与转发；生产周期在内存加速至 5 秒。测试均在一台笔记本内运行，六人意味着六个游戏进程加一个 Relay。它能证明复制与负载问题，不能推导六台独立玩家电脑的帧率。

| 运行目录后缀 | 配置 | Host process p95 | Client process p95 | 验证与解释 |
| --- | --- | ---: | ---: | --- |
| `054422` | 6 Relay，256 建筑，300 basic/shell，600 tick，详细指标关闭 | 118.16 ms | 20.05–23.07 ms | 6 个游戏进程严格通过，中继由 runner 收尾，共同水 192、逐仓 revision 一致；这轮尚未包含后续表现 getter 和接收合并 |
| `054742` | 2 Relay，同密度 600 tick，详细指标关闭 | 22.32 ms | 17.05 ms | 严格通过，共同水 128；Host 原生 CPU 约 83.34% 单核，Relay 13.99% 单核 |
| `055414` | 6 Relay，同密度 600 tick，详细指标关闭 | 125.89 ms | 20.49–23.34 ms | 严格通过，Host 约 104.41% 单核、Relay 14.92%；同机总计约 5.52 核 CPU，不是中继独占 CPU 饱和 |
| `061218` | 6 Relay，同密度 600 tick，详细指标开启，不开函数 profiler | 53.47 ms | 20.42–23.22 ms | 严格通过，共同水 128；用于细分热点，不能和 metricsOFF 直接归因比较 |
| `063004` | 6 Relay，256 建筑，正式 wave12 混合 300 敌，1800 tick，详细指标关闭 | **296.70 ms** | 20.99–23.92 ms | **严格通过但 Host 严重不实时**；Host 58.661 秒仅 224 个 process frame，所有端实际敌人数 min/max/end 均为 300；共同水 384、64 仓逐 revision 一致 |

`063004` 中客户端 1800 tick 各自约 30 秒结束采样，而 Host 相同 tick 需要 58.661 秒。客户端随后继续联机等待共同库存终态，但不再记录帧率与快照计数。因此它们各收到的 305–306 个完整快照，是自身约 30 秒的测量窗口，不能宣称已逐个验证 Host 全 58 秒约 600 个快照。测量窗口内各端 incomplete eviction=0、stale chunk=0；可靠库存的最终 checkpoint 在所有成员完成采样后单独验证。

相同运行的 Windows 原生累计 CPU 窗口 58.56 秒：Host 101.92% 单核，5 Client 分别 104.99%、82.23%、76.84%、80.79%、77.80%，Relay 13.26%。不同客户端可见实体/工作量和 OS 调度有差异。这些数据和单机混合敌人的独立 GPU 审计共同支持“Host 仿真线程容量与同机争用”的判断，不支持“中继服务器本身是主要瓶颈”或“仅减少发包即可根治”的说法。

### 原生吞吐与输入语义

`061218` 的 9.985 秒 Host 窗口累计发送 4,903,423 bytes、13,727 个 UDP 包，约 **491 kB/s（3.93 Mbit/s）**；每个 Client 约接收 103 kB/s、发送 7 kB/s。采用 `ENetConnection.pop_statistic()`，包含 ENet 帧和重发但不包括 IP/UDP 外层头。Host 物理 Relay 链路 RTT 14 ms，Client 12–17 ms。ENet 提供的 reliable loss 是约 10 秒更新的估计值，不等于应用层快照丢失。

混合长测 `063004` Host 累计发送 22,647,207 bytes / 58.661 秒（约 386 kB/s），客户端各自 30 秒窗口约接收 2.29–2.40 MB。Host 变慢后每墙钟秒快照频率也下降，较低吞吐并非性能提升。该轮 Host 的 ENet reliable RTT 达 62 ms、估计丢失 2.15%，客户端对应 11–12 ms、0.01–0.22%；即使 localhost 也会受主线程 poll 延后影响，不能将这些数据当公网链路测量。

没有为了追赶而合并、跳过或截断玩家输入。在正常开启详细指标、不启用原生函数 profiler 的 `061218` 中，Host 接收 2867 次输入共耗 189,579 μs，即每物理 tick 约 0.316 ms，最大单次 319 μs。此前 `-d --profiling` 控制台大量同步输出造成每 frame 积压 230 次输入的假象；据此跳过输入会损伤跳跃、射击、换弹边界，因此没有引入这种改变。

### 加载、退出与重连边界

最终六人运行采用资源审计修复后的原生请求 token 生命周期与 headless FIFO。真实图形后端仍保留原生后台并行；Dummy/headless 的原生纹理 RID 数据竞争由独立最小工程复现后，才实施串行边界。`063004` 所有 7 进程日志无错误、无警告，6 个游戏进程自然 exit 0；旧 runner 在 finally 清理 Relay，未单独检查其退出码，不能声称 Relay 自然 exit 0。runner 按本轮命令行再次确认残留进程 0。评审后新版 runner 增加等待 Relay 原生空房间 3 秒退出并验证退出码 0 的独立断言。早期有 Dummy RID 错误的结果不计为整合通过。

已开始的房间有明确准入契约：**全新身份没有断线席位会被拒绝**；旧 token 的席位保留 90 秒，并经过重新加载、身份迁移和权威首帧交付恢复。恢复夹具在完成性能取样之后关闭末客户端的真实 ENet 连接并卸载场景，等待 Host 进入 `SUSPENDED_GRACE`，先用陌生 token 验证确切拒绝原因，再用原 token、新 transport peer ID 重入。整个过程使用正式 NetManager 与 GameLoadCoordinator。Relay 每次认证使用新票据 nonce，保持原有防重放规则。共享文件仅协调测试及核对结果，不把实体数据注入客户端。

| 运行目录后缀 | 恢复场景 | 结果 |
| --- | --- | --- |
| `065204` | 2 人 LAN，16 建筑、12 敌、4 仓；地下探索从未初始化 | 原 token 恢复耗 5.911 秒（包含恢复后的 2 秒移动射击）；peer 81152666→857894175，稳定身份与 incarnation=2 保留，119 次新输入、11 个客户端弹体；12 敌/16 建筑逐 net ID 一致，共同水 8、逐仓 revision 一致；2 游戏自然 exit 0、日志干净、残留 0 |
| `070031` | 3 人 Relay，相同密度，原所有端使用正式事务预先配置路线身份，保持 inactive | 陌生 token 被真实 Host 拒绝；原 token 994874388→983954503，6.032 秒含 2 秒恢复射击；完整敌/建筑名册和水 8 一致；所有端保留路线旧 avatar 移除、新 avatar 与 3 人名册正确；Host 与恢复本人核对稳定 key。3 游戏与 Relay 自然 exit 0，Relay 空闲退出码单独断言，零错误/警告、残留 0 |

第二轮验证“已有但 inactive 的路线身份仍然迁移”的契约，预配置使用正式身份准备/提交方法，并未完整游玩一轮地下探索。第三方客户端不持有别人的重连 token；未进入 active 路线快照前，不要求它知道别人的稳定 key。这里验证手动调用正式重连入口，不声称提供了自动重连 UI、公网丢包恢复或新身份迟加入功能。

新版 Relay 自然退出断言于 `063651` 单独实测：2 个游戏进程、16 建筑、12 敌、60 tick，明确输出 `RELAY_EMPTY_IDLE_EXIT_PASS exit=0`，2 个游戏与 1 个 Relay 都自然 exit 0，所有日志干净，命令核实残留 0。该短测验证退出契约，不作为密度性能比较。

## 协议与服务器发布约束

生产批次 RPC 签名改变使协议升为 **v98**；敌人编码优化本身逐字节兼容，不再升协议。主项目与独立 Relay 的 NetManager 20、MpGame 152、MpRogueRoute 17 个 RPC（共 189）已静态核对签名、参数、注解；Relay transport wrapper 的镜像副本逐字节一致。

云端 Relay 进程必须与 v98 客户端同版。提交/推送客户端代码不等于更新已运行的云端进程。本次不宣称云端已部署。现有 `deploy.sh` 为首次安装脚本，会重写 `.env` 与 HMAC 密钥，不适合直接当成生产原地升级命令。具体本地验证、同版构建与现有服务更新步骤见 `relay_servers/README.md`。本地 Relay 压测将验证票据认证、CH9 拓扑和实际中继转发，但不会替代公网延迟、丢包和服务带宽测量。

## 可重复命令

```powershell
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/tower_network_scaling_regression.gd
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/enemy_snapshot_scaling_regression.gd
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/network_enemy_registry_regression.gd
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/enemy_visual_status_snapshot_regression.gd
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/enemy_snapshot_receive_regression.gd
& 'C:/Program Files/Godot/Godot_console.exe' --headless --path . --script res://dev_tools/enemy_reconnect_spawn_clock_regression.gd
python dev_tools/check_relay_rpc_parity.py
powershell -NoProfile -ExecutionPolicy Bypass -File dev_tools/run_tower_multiplayer_density_probe.ps1 -Players 6 -Buildings 256 -Enemies 300 -Frames 600
powershell -NoProfile -ExecutionPolicy Bypass -File dev_tools/run_tower_multiplayer_density_probe.ps1 -Players 6 -Buildings 400 -Enemies 300 -Frames 600
powershell -NoProfile -ExecutionPolicy Bypass -File dev_tools/run_tower_multiplayer_density_probe.ps1 -Players 6 -Buildings 256 -Enemies 300 -EnemyWave res://resources/config/campaigns/tower_defense/formal/wave_12.tres -Frames 1800 -Transport relay -ActiveInput -NativeCpu
powershell -NoProfile -ExecutionPolicy Bypass -File dev_tools/run_tower_multiplayer_density_probe.ps1 -Players 3 -Buildings 16 -Enemies 12 -Frames 360 -Transport relay -ActiveInput -ReconnectLastClient -PrepareRouteIdentity
```

Runner 使用隐藏窗口启动测试，正常或失败均在 `finally` 根据本次唯一输出目录、脚本/owner 参数和 `--headless` 查找 Godot console 包装进程及其真实 `Godot.exe` 子进程，停止后再次查询。不会依据进程名批量关闭正常编辑器。

## 官方依据

- [Node 生命周期信号与延迟连接](https://docs.godotengine.org/en/stable/classes/class_node.html)
- [StreamPeerBuffer 原生预分配](https://docs.godotengine.org/en/stable/classes/class_streampeerbuffer.html)
- [PackedByteArray 压缩与有界解压](https://docs.godotengine.org/en/stable/classes/class_packedbytearray.html)
- [Performance 监视器更新与时间含义](https://docs.godotengine.org/en/4.6/classes/class_performance.html)
- [Godot 多人通道与可靠传输](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)
- [ENetConnection 原生累计流量统计](https://docs.godotengine.org/en/4.6/classes/class_enetconnection.html)
- [ENetPacketPeer RTT、丢失估计与节流统计](https://docs.godotengine.org/en/4.6/classes/class_enetpacketpeer.html)

输出 JSON 与逐端日志保留在忽略目录，可用上述命令复现。工具默认只清理匹配本次唯一输出路径的辅助进程，正常 Godot 编辑器不受影响。
