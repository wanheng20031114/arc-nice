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
const PROTOCOL_VERSION := 28

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
