extends RefCounted

## 协议与版本
const PROTOCOL_VERSION := 1

## 玩家限制
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
## 1: 玩家状态上报 — unreliable_ordered
## 2: 玩家/敌人状态快照 — unreliable_ordered
## 3: 投射物/技能事件 — unreliable_ordered
## 4: 伤害、死亡、生成、掉落、升级事件 — reliable
const CH_AUTH := 0
const CH_INPUT := 1
const CH_STATE := 2
const CH_PROJECTILE := 3
const CH_EVENT := 4
const CHANNEL_COUNT := 5

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
const RELAY_IDLE_TIMEOUT_SEC := 10 * 60 * 60
