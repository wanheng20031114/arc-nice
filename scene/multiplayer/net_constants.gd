extends RefCounted

## 协议与版本
## v24：在 v23 制作/围栏协议上合入塔防命运投票与序列化权威传送。
## v25：玩家生命升级为 signed int32，玩家位置升级为 signed int32 × 10，
## 并统一固定宽度网络战斗值的合法范围。
## v26：竹筒迫击炮视觉动作携带本轮已提交的蓄热时长，确保攻击间隔支援
## 在Host、实时事件与中途加入快照之间保持一致。
## v27：洛茜赌怪券牌局新增空白牌结果类型，隔离无法识别 kind=5 的旧客户端。
## v28：新增 Tango 角色快照编码与由 Host 独立计时的可靠蓄力/释放/取消协议；
## 多人房间同步总人数容量，并新增测试场景 P1 / P2 模式与测试场景权威昼夜切换事件。
## 旧客户端无法安全解释新增模式、RPC 参数与角色状态。
## v29：Tango 废除持续光束，改为 Host 权威的三炮原子齐射批包，并在既有
## 输入流中同步松键后的持续瞄准。
## v30：Tango 新增 Host 权威的“电能涌动”固定区域、8 秒强化状态与中途加入
## 重放；敌人状态快照 bit16 表示永久电元素附着。
## v31：电能涌动可靠事件绑定自动弹幕序列，技能结束后不会被跨信道迟到齐射
## 重新拉起；无按键的鼠标被动瞄准改为变化即时发送与6帧保活。
## v32：新增 P3 肉鸽路线多人模式与 Host 权威的完整路线/移动增量协议。
## 旧客户端无法识别新增 wire 游戏模式值 4。
## v33：P3 路线世界新增约 12Hz 的轻量角色姿态上报、Host 校验/广播、
## 跨信道路线 revision 隔离与可靠位置纠正。
## v34：P3 路线全量快照新增 runtime_contract_hash，防止旧客户端忽略
## 新字段后继续使用与 Host 不一致的世界几何。
## v35：新增战斗机器人枪手弹丸类型与玩家受击来源 wire ID 17；旧客户端
## 无法验证或实例化该 Host 权威弹丸。
## v36：新增测试场景 P1B 的 wire 游戏模式值 5；原 P1 对外显示为 P1A，
## 但继续保留稳定 key test_arena_p1，旧客户端无法识别 P1B 房间与加载目标。
## v37：P3 神奇遭遇新增 Host 权威的逐人对白确认、投票、结算与经济快照；
## 路线完整快照同时携带遭遇和经济状态，旧客户端无法解释新的 RPC 参数。
## v38：新增 Host 权威的爆炸无人机投射物类型；客户端需按固定部署、飞行与
## 爆炸三阶段合同重建表现，旧客户端无法实例化该类型。
## v39：敌人视觉状态快照新增举盾机器人盾牌阶段位，且敌人动作协议新增格挡
## 与破盾表现；旧客户端无法正确恢复盾牌耐久阶段或消费对应弹体表现。
## v40：P3 神奇遭遇池新增会说话的史莱姆、三选项投票与多页权威结果；
## 旧客户端会拒绝新 option_id，亦无法解释 result_pages。
## v41：P3 神奇遭遇池新增“鬼影”事件及其独立选项/结果 wire ID；v40 客户端
## 无法渲染该事件，也会拒绝其投票快照。
## v42：P3 神奇遭遇新增“荧光坑洞”的多轮投票、逐轮结果确认 RPC，以及共享
## 核心/最大生命惩罚账本；v41 客户端无法解释升级后的 Session/Economy 快照。
## v43：肉鸽路线权威快照新增待显示作战简报状态；v42 客户端无法解释新增字段。
## v44：小葱“濒危核心”新增第二阶段全局增益投票；v43 客户端无法解释
## 新阶段，也会拒绝携带增益 ID 的濒危核心投票。
## v45：新增忍者战斗机器人受击加速动作，并让敌人视觉状态 bit5 在该场景中
## 表示短时加速态；v44 客户端无法实例化该敌人或恢复对应尾影状态。
## v46：在 v45 内容上为肉鸽战斗重连新增独立 ACTIVATED 确认，将场景准备
## 与实际激活拆成两个幂等阶段；v45 客户端无法关闭或恢复该重连失败窗口。
## 该独立版本也防止并行开发的两套不同 v45 契约被误判为彼此兼容。
## v47：新增精英战斗机器人的独立配置、场景与动画资源合同；敌人动作仍复用
## 既有协议补播蓄力、冲刺与提前结束表现。v46 客户端缺少对应资源合同。
## v48：肉鸽地下商店新增 Host 权威的购买、出售、退出回执与逐人私有货架快照，
## 路线完整快照追加目标玩家的商店状态。8 个 ENet 通道保持不变；v47 客户端
## 无法解释新增 RPC 与完整快照参数。
## v49：在 v48 地下商店契约上新增精英持枪战斗机器人、独立紫色弹丸类型及
## 玩家受击来源 wire ID 18。RPC 表面和 8 个 ENet 通道不变，但 v48 客户端
## 无法实例化新的敌人与投射物资源合同。
const PROTOCOL_VERSION := 49

## 固定宽度网络战斗值契约。运行时仍使用 GDScript signed int64；只有在
## 进入固定宽度快照或 PackedArray 之前才应用此边界，越界值必须拒绝。
const NETWORK_COMBAT_VALUE_MIN := 0
const NETWORK_COMBAT_VALUE_MAX := 0x7FFFFFFF


static func is_valid_network_combat_value(value: int) -> bool:
	return value >= NETWORK_COMBAT_VALUE_MIN and value <= NETWORK_COMBAT_VALUE_MAX

## 玩家限制
const MIN_ROOM_PLAYERS := 2
const DEFAULT_ROOM_MAX_PLAYERS := 4
const MAX_PLAYERS := 8
const MAX_PLAYER_NAME_LENGTH := 12

## 连接超时
const DIRECT_CONNECT_TIMEOUT_MS := 3000
const RELAY_CONNECT_TIMEOUT_MS := 5000
const UPNP_DISCOVER_TIMEOUT_MS := 2000

## 端口
const ENET_PORT_DEFAULT := 29170
const RELAY_PORT_RANGE_START := 40001
const RELAY_PORT_RANGE_END := 40100
const PUBLIC_LOBBY_API_BASE_URL := "http://47.123.6.127:8000"
const PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS := 60.0

## ENet 信道定义
## 0: 认证、加载、完整状态恢复 — reliable
## 1: 玩家输入上报 — unreliable_ordered
## 2: 玩家实时状态 — unreliable_ordered
## 3: 敌人分块状态 — unreliable
## 4: 投射物请求与表现 — reliable / unreliable_ordered
## 5: 敌人、植物、地形、基地等持久世界事件 — reliable
## 6: 库存、经济、洛茜与仓库事务 — reliable
## 7: 可丢弃的战斗反馈 — unreliable
const CH_AUTH := 0
const CH_INPUT := 1
const CH_PLAYER_STATE := 2
const CH_ENEMY_STATE := 3
const CH_PROJECTILE := 4
const CH_WORLD_EVENT := 5
const CH_TRANSACTION := 6
const CH_FEEDBACK := 7
const CHANNEL_COUNT := 8

## 同步频率 (Hz)
const HOST_PHYSICS_HZ := 60
const INPUT_SEND_HZ := 60
const PLAYER_SNAPSHOT_HZ := 60
const ENEMY_SNAPSHOT_HZ := 30

## 同步频率对应的物理帧间隔
## 在 60 Hz 物理帧下，每 N 帧执行一次
const INPUT_SEND_INTERVAL_FRAMES := 1
const INPUT_KEEPALIVE_INTERVAL_FRAMES := 6
const PLAYER_SNAPSHOT_INTERVAL_FRAMES := 1
const ENEMY_SNAPSHOT_INTERVAL_FRAMES := 2

## P3 路线世界只同步移动姿态，不携带塔防战斗状态；12Hz 足以配合角色侧
## 的像素视觉平滑，同时显著低于标准战场的 60Hz 玩家快照带宽。
const ROGUE_ROUTE_AVATAR_SYNC_HZ := 12
const ROGUE_ROUTE_AVATAR_SYNC_INTERVAL_SECONDS := (
	1.0 / float(ROGUE_ROUTE_AVATAR_SYNC_HZ)
)

## 插值
const INTERPOLATION_BUFFER_SIZE := 6
const INTERPOLATION_DELAY_FACTOR := 2.5   # 默认渲染延迟 = delay_factor × snapshot_interval
const PLAYER_INTERPOLATION_DELAY_FACTOR := 2.0
const ENEMY_INTERPOLATION_DELAY_FACTOR := 2.5
const MAX_EXTRAPOLATION_SECONDS := 0.12
const PLAYER_MAX_EXTRAPOLATION_SECONDS := 0.05
const ENEMY_MAX_EXTRAPOLATION_SECONDS := 0.12

## Relay 空闲超时（秒）
const RELAY_IDLE_TIMEOUT_SEC := 36000
