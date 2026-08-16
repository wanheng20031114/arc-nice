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
## v50：拾取配置拆分为拾取触发道具与消耗品资源合同，普通敌人默认掉落表不再
## 产出消耗品。RPC 与 ENet 通道数不变；v49 客户端缺少新的资源分类与路径合同。
## v51：在 v50 消耗品资源合同上新增精英爆炸无人机操作员及独立紫能无人机
## 投射物类型；客户端继续
## 复用固定部署、飞行、爆炸三阶段补偿，但必须按新类型选择资源与独立对象池。
## RPC 表面、攻击来源 ID 与 8 个 ENet 通道均不变；v50 客户端缺少该资源合同。
## v52：新增精英举盾战斗机器人的独立配置、场景、四阶段动画与紫能盾牌表现
## 资源合同，并为肉鸽物资节点新增共享光石账本、独立光石 revision 与可增加
## 行动力的路线快照 schema；精英盾兵继续复用既有盾况快照位和格挡/破盾动作。
## RPC 表面、投射物类型、攻击来源 ID 与 8 个 ENet 通道均不变；v51 客户端既
## 缺少精英盾兵资源合同，也无法验证新增的 party economy 与路线状态字段。
## v53：新增精英忍者战斗机器人的独立配置、场景与紫能强化资源合同；继续复用
## 既有忍者受击加速动作、视觉状态 bit5 与共享无染色尾影着色器。RPC 表面、
## 投射物类型、攻击来源 ID 与 8 个 ENet 通道均不变；v52 客户端缺少对应资源合同。
## v54：新增十二种消耗品资源与效果合同，玩家实时快照追加虚空电池充能绝对位；
## 肉鸽地下商店会话升级为逐人同步完整消耗品价格表，并按低/中/高档位确定性抽价。
## RPC 表面与 8 个 ENet 通道均不变；v53 客户端无法解释新增玩家状态字节、商店
## session schema 与资源路径合同。
## v55：肉鸽“稀有宝箱”节点新增逐玩家私有候选、永久属性奖励与
## 共享状态账本 CAS；完整路线快照按目标 peer 导出私有候选与结算记录。
## RPC 表面与 8 个 ENet 通道不变；v54 客户端缺少 rare-chest schema 与运行合同。
## v56：肉鸽“狭路相逢”作战将敌人组成、生成节奏、同时存活上限与红门
## 均衡随机策略统一收归波次资源，并将完整波次内容纳入运行时合同。
## RPC 表面与 8 个 ENet 通道不变；v55 客户端缺少新的资源与合同语义。
## v57：新增测试场景 P1C 的稳定 wire 游戏模式值 6，并加入纸箱怪人工造物资源
## 合同。RPC 表面、投射物类型、攻击来源 ID 与 8 个 ENet 通道均不变；v56
## 客户端无法识别 P1C 房间或加载对应 Campaign 与敌人资源。
## v58：新增“疯穿箱子”神奇遭遇、遭遇跟随强制作战及按 combat_config_id
## 解析的作战准备协议，并把奖励列表纳入皮箱之战结算合同。v57 客户端无法
## 解释 Briefing schema 2、Encounter Session schema 4 或新的作战准备参数。
## v59：新增测试场景 P1D 的稳定 wire 游戏模式值 7，并加入地下教堂地图与
## 独立纸箱怪 Campaign 资源合同。v58 客户端无法识别 P1D 房间或加载对应资源。
## v60：普通作战由单一配置升级为按节点内容种子确定性选择的带权资源池，并将
## 完整普通作战池纳入楼层运行时合同。v59 客户端无法复算普通节点对应作战。
## v61：新增大纸箱怪的运行资源、图鉴合同，并将 P1C 调整为普通/大纸箱怪各500只
## 的严格轮转压力波次。RPC 表面、攻击来源 ID 与 8 个 ENet 通道均不变；v60
## 客户端缺少大纸箱怪资源，无法加载新的 P1C Campaign 波次。
## v62：敌人伤害反馈由单一粒子布尔值升级为表现位集，Host 可独立同步命中粒子
## 与直接命中闪红；聚合伤害和可靠致死事件统一使用该位集。v61 客户端会把新的
## int 表现位误解为旧 bool，无法保持直接命中与持续伤害表现一致。
## v63：新增“隐形海参”神奇遭遇、海参消耗品与五秒隐藏表现；玩家持久属性
## 账本追加冲刺冷却减秒字段，party status / economy schema 分别升为 3 / 6。
## v62 客户端缺少新资源、option_id 和固定账本字段，不能安全加入。
## v64：登记主战机器人精英与 P1E 测试场景的稳定 wire 游戏模式值 8，并在既有
## 玩家伤害确认 RPC 尾部追加 Host 确认的燃烧/减速状态位。运行视觉尚未通过原生
## 像素资格门，因此 P1E 在正式菜单、大厅和加载入口保持不可选择。v63 客户端既
## 无法识别该模式，也无法解析扩展后的确认载荷，不能安全加入。
## v65：开放 P1E 的正式测试入口；神奇遭遇新增本局已遭遇历史、按历史过滤的确定性
## 抽取及全部耗尽后的鬼影回退。Encounter Session schema 升为 5，party economy
## schema 升为 7 并携带遭遇历史账本。v64 客户端无法解析新的会话与经济快照。
## v66：新增塔防移速强化塔的资源与植物注册合同；玩家快照中既有移速 u16
## 定点字段改为“Host 最终有效移速 ÷ 角色稳定初始移速”，以收敛支援塔等加法
## 属性与瞬时倍率。包宽、RPC 表面与 8 个 ENet 通道不变；v65 客户端既缺少
## speed_tower 资源，也会把该字段当作纯运行时倍率并重复计入加法属性，不能安全加入。
## v67：新增塔防攻速强化塔的资源与植物注册合同。攻速加成由 Host 和客户端从
## 可靠植物生命周期分别派生，射击仍由 Host 按最终有效间隔复核；包宽、RPC 表面
## 与 8 个 ENet 通道不变。v66 客户端缺少 attack_speed_tower 配置、场景与注册项，
## 无法实例化 Host 广播的植物或派生对应射速，不能安全加入。
## v68：植被桩扩散合同由五格/五十秒升级为六格/六十秒。最终地形仍由 Host 通过
## 既有可靠地形增量与完整快照权威同步，客户端只按运行时进度重建扩散预览；包宽、
## RPC 表面与 8 个 ENet 通道不变。v67 客户端会按旧几何解释相同的运行时进度，
## 产生缺失或残留的外圈预览，不能安全加入。
## v69：新增植被桩蔓延增强科研 wire ID，并将植被桩运行时 schema 升为 2，携带
## 以基础速率工作进度秒计量的 elapsed 与权威传播倍率。迟加入客户端按采样年龄乘
## 快照倍率外推，科研中途完成只加速剩余进度。v68 客户端缺少新科研注册项，也无法
## 解析倍率快照或安全重建科研后的传播预览，不能加入。
## v70：地下教会正式普通作战的敌人构成由纸箱怪/持枪机器人/史莱姆 20/20/30
## 调整为 10/20/40，同时存活上限由 20 降为 15；总数 70 与 0.2 秒生成间隔不变。
## RPC 表面、快照宽度与 8 个 ENet 通道均不变；v69 客户端仍持有旧作战资源合同，
## 无法安全复现同一正式作战，不能加入。
## v71：新增地下水道普通作战（迅捷原石虫/火焰原石虫/自爆原石虫/法师 Capoo
## 20/20/4/3）与紧急作战（迅捷原石虫/石头人/火焰原石虫/精英持枪战斗机器人
## 20/2/15/10）；两者均绑定 Game04 的 Spawn1/Spawn2（spawn mask 3），并分别加入
## 普通/紧急作战池。RPC 表面、快照宽度与 8 个 ENet 通道均不变；v70 客户端缺少
## 新编成、双出生点和池成员合同，无法安全复现同一 Rogue 路线运行，不能加入。
## v72：正式塔防新增四日战役与内嵌地下探索流程，战斗流追加稳定 wire 状态
## ROGUE_EXPLORATION=8；塔防完整快照可携带带 epoch/每日幂等发放账本的路线状态，
## 支持同图跨日、断线重连与失败后下一日换图。v71 客户端无法解释该状态及快照，
## 也可能重复发放行动力或错误恢复塔防世界，不能安全加入。
## v73：CH0 roster 明确区分传输在线与重连宽限成员，并携带单调成员 revision；
## v72 客户端会把宽限成员误当在线 Player，也无法安全执行 final departure。
## v74：17 类携带玩家身份的 CH6 权威结果新增 Host 会话世代。v73 客户端
## 无法隔离断开后重开房间的旧可靠包，可能把旧局结果提交到新局同号玩家。
## v75：CH0 roster 为每个成员新增 Host 单调分配的 participant incarnation；
## 17 类 CH6 结果以该世代解析当前 peer，隔离同局 transport ID 复用产生的 ABA。
## v76：Relay 模式的逻辑 Host 可经由 Relay 服务端可靠踢出不兼容或投影超时成员。
## 该控制 RPC 避免 Relay 拓扑中 Host 侧 get_peer(target != 1) 为 null 而让
## RECONNECTING 成员永久滞留；v75 及更旧客户端/Relay stub 不具备该控制面，不能加入。
## v77：注册握手新增 schema 1 内容摘要与 Host 明确 accepted/rejected 回执；Client
## 只有在本地 ACTIVE roster 和匹配的 accepted 三元组同时到达后才进入大厅。
## v76 客户端无法证明敌人、道具、Campaign 及依赖闭包与 Host 相同，不能加入。
## v78：P3 Route 新增 Host 权威玩家升级请求，并在路线完整快照末尾追加逐玩家
## progression ledger；v77 客户端既没有该 RPC，也会按旧五参解码完整快照。
## v79：正式塔防的通用 T 目录放置请求改为 canonical 建筑物品的 Host 权威付费；
## Host 按请求者本人背包优先、共享仓库补足的顺序扣除物品。v78 Host 只把同形状
## 请求理解为沙盒免费放置，无法识别该正式付费语义，不能与 v79 客户端混联。
const PROTOCOL_VERSION := 79

## 会话世代走 wire 固定正整数；同一 NetManager 生命周期内只递增不回绕。
const MAX_GAME_SESSION_INCARNATION := 0x7FFFFFFF
## 成员世代同样只递增不回绕，但生命周期属于 Host 成员账本而非单局流程。
const MAX_PARTICIPANT_INCARNATION := 0x7FFFFFFF

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
## 当前默认值仅指向测试服；正式服上线前必须在部署环境改为受信任 HTTPS 地址。
const TEST_SERVER_PUBLIC_LOBBY_API_BASE_URL := "http://47.123.6.127:8000"
const PUBLIC_LOBBY_API_BASE_URL_ENV := "ARC_PUBLIC_LOBBY_API_BASE_URL"
## 服务端进入 IN_GAME 后的 180 秒 idle lease 以 60 秒节奏续租。
const PUBLIC_ROOM_KEEPALIVE_INTERVAL_SECONDS := 60.0


## 公网大厅地址只允许从这一处读取，避免 lease/场景各自漂移。
static func get_public_lobby_api_base_url() -> String:
	var configured := OS.get_environment(PUBLIC_LOBBY_API_BASE_URL_ENV).strip_edges()
	if configured.is_empty():
		configured = TEST_SERVER_PUBLIC_LOBBY_API_BASE_URL
	return configured.trim_suffix("/")

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
