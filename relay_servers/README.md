# ARC NICE Relay Server

多人模式的云端服务组件，部署在阿里云 Linux ECS 上。

## 架构

```
relay_servers/
├── lobby_api/              # FastAPI 大厅 API
│   ├── main.py             # API 入口
│   ├── models.py           # 数据模型
│   ├── room_manager.py     # 房间生命周期管理
│   ├── acquisition_security.py # HMAC capability 与单进程准入限流
│   ├── relay_admission.py  # 每房间、角色绑定的 Relay admission ticket
│   ├── relay_launcher.py   # Godot Headless Relay 启动器
│   └── config.py           # 配置
├── relay_godot_project/    # Godot Headless Relay 项目
│   ├── project.godot
│   ├── authenticated_relay_multiplayer_peer.gd  # 认证感知的 ENet 转发/拓扑包装层
│   ├── relay_server.gd
│   ├── relay_net_manager_stub.gd  # 与主项目 NetManager RPC 表面一致
│   ├── relay_mp_game_stub.gd      # 与主项目 MpGame RPC 表面一致
│   └── relay_server.tscn
├── scripts/
│   ├── deploy.sh           # 一键部署
│   └── start_lobby.sh      # 启动大厅 API
├── requirements.txt
└── README.md
```

主游戏从 `scene/multiplayer/transport/authenticated_relay_multiplayer_peer.gd`
加载可导出的 canonical wrapper；独立 Relay 项目保留上图中的镜像副本。两份脚本
必须逐字节一致，并由 Relay parity/capacity 测试锁定。主游戏生产导出继续整体排除
`relay_servers/*`，不会把大厅后端或 Headless Relay 工程打进客户端。

当前网络基线为协议 v94。应用层使用 CH0..CH8 共 9 条逻辑信道；公网 Relay
的认证感知包装层另使用可靠 CH9 依次发布拓扑并承载 Relay 服务控制，因此公网
ENet 最大信道索引为 9。v94 将敌人高频连发压缩为 CH4 单次 burst，并通过
reliable CH5 收敛命中/取消结果及分块恢复迟加入客户端的活跃视觉弹体；其 RPC 表面和描述符合同与
v93 不同，不能安全混联。v93 扩展玩家快照以逐帧绝对复制最终开火间隔和临时
表现状态，并把天依 High Noon 目标列表迁入 reliable CH5。v92 将拾取 spawn、原子 collected 终端
与普通 remove 统一放在 reliable CH5，旧 v91 的 collected 仍在 CH6。
v91 关闭 `SceneMultiplayer.server_relay` 的私有 mesh，
只为已验票 transport 发布逻辑拓扑并显式转发数据包。v90 把公网成员的完整
注册元组并入原生认证 envelope，当时把成员发现、身份查询、注册回执/拒绝和大厅名单
统一放在 reliable CH8。v91 确立且 v93 保留的布局是：注册回执/拒绝与大厅名单等应用成员消息保留在 CH8；
ADD/REMOVE 逻辑 peer 拓扑与注册转发、身份查询/结果、踢人等 Relay 专用 RPC 都走 CH9。
这三类消息都不与 Godot 引擎硬编码在 CH0 的 auth/peer-discovery 系统包共用应用队列。
v90 及更旧客户端缺少 v91 的帧协议与
拓扑信道，不能与 v91 房间安全混联。v89 加入了公网 Relay admission
和 Host 身份查询/结果 RPC。v88 将 F10 调试作弊目录的
物品授予范围扩展到受信资源材料；其 RPC 签名与数量当时保持不变。v87 及更旧
客户端缺少该统一调试授权契约，不能与 v88 房间安全混联。v87 将
WaterCollector 固定为连续循环采集，并从产线面板隐藏单次/无限循环
mode；v86 及更旧客户端缺少该统一运行时契约，不能与 v87 房间安全混联。
v86 在正式塔防中新增 Client 到 Host 的“销毁最近建筑”可靠请求；Host 必须根据
请求者的权威玩家位置重新校验目标。v85 及更旧客户端缺少该
RPC 表面，不能与 v86 房间安全混联。v85 在科研账本新增
`building_defense_ii`、`building_defense_iii`、
`agave_cannon_muzzle_improvement`、`corn_machine_gun_cooling_system_improvement`、
`bamboo_mortar_concussive_modification` 与 `grape_arc_tower_surge_modification`
六个稳定 ID，并在玉米机枪塔 burst batch 增加逐动作 `shot_counts` packed 列；
v84 及更旧客户端既缺少完整科研项，也会按旧四列 RPC 解码，不能安全混联。
v84 新增生产循环开关 command，并将
ProductionBuilding runtime 升级至 schema5；v83 客户端缺少该 command，且不能安全解析
ProductionBuilding runtime schema5。v83 新增围栏强化科研 wire ID，
完成后所有围栏生命值 +1000、物理防御 +5；v82 客户端缺少该科研注册项，
不能安全解析完整科研账本。v82 新增采水速率提升科研 wire ID，
完成后水收集器单轮耗时缩短50%；v81 客户端缺少该科研注册项，不能安全解析
完整科研账本。v81 新增植被强化科研 wire ID，
完成后玩家站在草块上的每秒最大生命回复由20%提升至40%；v80 客户端缺少该
科研注册项，不能安全解析完整科研账本。v80 将 P3 神奇遭遇中的“鸡哥”与
“鬼影”保留为预留内容但移出正式随机池，地图固定分配四个不重复神奇遭遇，
且池耗尽不再回退鬼影。v79 客户端会按旧池容量与顺序复算地图内容，无法
安全混联。v79 将正式塔防的通用 T 目录放置请求升级为 canonical 建筑物品的
Host 权威付费：先扣请求者本人背包，再由共享仓库补足；v78 Host 仍把同形状请求
理解为沙盒免费放置，无法识别该正式付费语义。v78 为 P3
Route 新增 Host 权威玩家升级请求，并在路线完整快照末尾追加逐玩家 progression
ledger；v77 客户端既没有该 RPC，也会按旧五参解码完整快照。v77 在 ENet Host
的玩家注册阶段增加内容清单
schema 与 SHA-256 摘要门禁；只有摘要匹配且 ACTIVE 成员投影就绪
后，客户端才进入大厅已连接态。测试服保持现有明文 HTTP 大厅协议，摘要不进入
公网大厅 API，最终准入以 ENet Host 为准。v76 新增 Relay Host 到 Relay 服务端的可靠
踢人控制面：服务端仅接受已登记逻辑 Host 的请求，并只断开同房目标，以保证不兼容或
投影超时成员即便忽略 join_rejected 也会有界终结。v73 的 CH0 roster 将 transport 在线玩家
与仍在重连宽限期内的会话成员分离，并携带单调 membership revision；v74 为携带玩家
身份的 CH6 权威结果增加游戏会话世代；v75 再由 Host 为每个最终成员租约分配同局不复用的
participant incarnation，阻止旧局结果和同局 peer ID ABA 落入当前成员。v72 新增正式塔防四日战役与内嵌
Rogue 地下探索：稳定战斗流追加 `ROGUE_EXPLORATION=8`，Host 通过带地图 epoch、
每日行动力幂等账本和运行契约哈希的探索快照驱动同图跨日、失败换图与重连修复；
路线移动、简报、遭遇、商店和玩家姿态继续使用原有可靠/实时信道，未增加 ENet 信道。
v71 新增地下水道普通作战（迅捷原石虫/
火焰原石虫/自爆原石虫/法师 Capoo 20/20/4/3）与紧急作战（迅捷原石虫/石头人/
火焰原石虫/精英持枪战斗机器人 20/2/15/10）；两者均绑定 Game04 的 Spawn1/Spawn2
（spawn mask 3），并分别加入普通/紧急作战池。RPC 表面、快照宽度与通道数不变。
v70 将地下教会正式普通作战的敌人构成从纸箱怪/持枪机器人/史莱姆 20/20/30 调整为
10/20/40，同时存活上限从 20 降为 15；总数 70 与 0.2 秒生成间隔不变。v69 新增植被桩蔓延增强科研的 wire 注册项，
并将植被桩运行时快照升级为携带基础工作进度与权威传播倍率；科研完成只加速剩余进度，
迟加入客户端按采样年龄乘快照倍率重建预览，包宽与 RPC 表面不变。v68 将植被桩扩散合同升级为六格、
六十秒；最终地形仍由 Host 通过既有可靠地形增量与完整快照权威同步，客户端只按
运行时进度重建扩散预览，包宽与 RPC 表面不变。v67 新增塔防攻速强化塔的资源与植物
注册合同；攻速加成由 Host 与客户端从可靠植物生命周期分别派生，射击仍由 Host
按最终有效间隔复核，包宽与 RPC 表面不变。v66 新增塔防移速强化塔的资源与植物
注册合同，并在不改变玩家快照宽度的前提下，将既有移速定点字段的语义改为
“Host 最终有效移速 ÷ 角色稳定初始移速”，以统一收敛加法属性和瞬时倍率。
v65 开放 P1E 测试入口，并将神奇遭遇
Session schema 升为 5、party economy schema 升为 7：权威快照携带本局已遭遇
历史，房主仅从未遭遇内容中确定性抽取，全部耗尽后固定回退鬼影。v64 登记主战
机器人与 P1E 稳定 wire 模式值 8，并在既有玩家伤害确认 RPC 尾部追加 Host 确认
的燃烧/减速状态位；当时 P1E 在原生运行视觉发布前保持不可选择。v63 新增“隐形海参”神奇遭遇、
海参消耗品的五秒隐藏表现，并将冲刺冷却减秒加入玩家持久属性账本；
party status / economy schema 分别升为 3 / 6。v62 将敌人伤害表现升级为粒子/
直接命中闪红位集，并统一用于不可靠聚合反馈与可靠致死事件。v61 保留的大纸箱怪运行资源与图鉴合同，
并将 P1C 调整为普通/大纸箱怪各500只的严格轮转压力波次；v60 将肉鸽普通作战
升级为按节点种子确定性选择的带权资源池，并把地下教会与既有普通作战配置组成的
完整正式作战池纳入楼层运行时合同；v59 新增测试场景 P1D 的稳定 wire
游戏模式值 7、地下教堂地图与独立纸箱怪 Campaign 资源合同；v58 新增“疯穿箱子”神奇遭遇、
按作战配置 ID 分发的遭遇跟随强制作战、Briefing schema 2 与奖励列表结算合同；
v57 新增测试场景 P1C 的稳定 wire 游戏模式值 6 与纸箱怪人工造物资源合同，
投射物、攻击来源及通道数不变；
v56 将肉鸽“狭路相逢”的敌人组成、生成节奏、同时存活上限与红门均衡随机策略统一收归波次资源，并冻结完整波次运行时合同；v55 新增稀有宝箱私人候选、永久属性账本与逐玩家路线快照合同；v54 新增十二种消耗品资源与效果合同，
玩家实时快照追加虚空电池充能绝对位，并将肉鸽地下商店会话升级为逐人同步完整
消耗品价格表与低/中/高三档确定性抽价；v53 新增精英忍者战斗机器人的独立
配置、场景与紫能强化资源合同，继续复用既有忍者受击加速动作、视觉状态 bit5
与共享无染色尾影着色器；v52 新增精英举盾战斗机器人的独立
配置、场景、四阶段动画与紫能盾牌表现资源合同，继续复用既有盾况快照位和
格挡/破盾动作；同时新增肉鸽物资节点的共享光石账本、独立光石 revision 与
可增加行动力的路线快照 schema。v51 新增精英爆炸无人机操作员与独立
紫能无人机投射物类型，继续复用部署、飞行、爆炸三阶段补偿和唯一批量运动系统；
v50 将拾取配置拆分为拾取触发道具与
消耗品资源合同，并从普通敌人默认掉落表移除消耗品；v49 新增精英持枪战斗机器人、
独立紫色弹丸类型及玩家受击来源 wire ID 18；v48 新增肉鸽地下商店的购买、出售、
退出回执、逐人私有货架快照及路线完整快照中的目标玩家商店状态；v47 新增精英战斗
机器人的独立配置、场景与动画资源合同。客户端必须同时具备对应资源、RPC 表面与
wire 语义。v46 将内嵌肉鸽战斗的
`PREPARED`（场景已准备）与
`ACTIVATED`（本地运行时已激活）拆成独立确认，避免重复准备包提前关闭
重连失败窗口；v45 新增忍者战斗机器人的受击加速敌人动作，并让敌人视觉状态 bit5
在该场景中表示短时加速态，客户端必须能补播动作并从快照恢复尾影表现；v44 新增小葱“濒危核心”
第二阶段全局增益投票状态，并允许既有命运投票 RPC 的濒危核心负载携带已注册增益 ID；
同时保留 v43 引入的肉鸽作战简报权威状态快照与全员遮盖就绪确认；
同时保留 v42 引入的“荧光坑洞”多轮投票、
逐轮结果确认 RPC，以及共享核心/最大生命惩罚账本；v41 新增“鬼影”遭遇及其
独立选项/结果 wire ID；v40 新增会说话的史莱姆、三选项投票与多页权威结果；v39 新增
举盾机器人盾牌阶段快照位，并通过既有敌人动作协议同步格挡与破盾表现；v38
新增 Host 权威的爆炸无人机投射物类型，客户端按固定部署、飞行与爆炸三阶段
合同补播；v37 新增 P3 神奇遭遇的 Host 权威逐人对白确认、投票、结算与经济
快照。v36 的测试场景
P1B 模式、P1A 显示名及稳定 key `test_arena_p1`/`test_arena_p1b` 保持兼容；
P1C/P1D/P1E 分别使用稳定 key `test_arena_p1c`/`test_arena_p1d`/`test_arena_p1e`。
v35 的战斗机器人枪手弹丸及玩家受击来源 wire ID 17 保持兼容；
P3 路线世界继续使用约 12Hz 的轻量角色姿态同步：
Client 在输入信道上报，Host 校验后在玩家状态信道广播，非法位置通过可靠信道纠正。
v34 的 P3 路线全量快照携带 `runtime_contract_hash`，Host 与 Client 必须使用相同的世界几何契约；
v93 及更旧客户端不能加入 v94 房间。
Relay 只转发 RPC，不重复实现游戏状态逻辑；逻辑 Host 对不兼容、重连加载或
运行时投影超时成员的断开请求会可靠发送至 Relay 服务端（peer 1）。Relay 只
接受已登记 Host 的请求，并由服务端断开同房目标；普通客户端不能踢出其他成员。
每次调整主项目 RPC 的名称、注解、参数或通道后，都必须同步对应 stub，并在仓库根目录运行：

```bash
godot --headless --path . --script res://dev_tools/relay_rpc_parity_smoke_test.gd
```

### 公网 Relay 容量与真实验证边界

公网 Relay 支持 **最小 2 人、默认 4 人、最大 8 人（均含 Host）**。HTTP 创建模型
默认为 4，允许在 2 到部署上限之间选择房间容量；`MAX_PLAYERS_PER_ROOM`
默认为 8，它同时是公网入口与 Launcher 的部署上限。Launcher 把房间的实际
`max_players` 传给 `--max-clients`；Godot Relay 拒绝小于 2 或大于 8 的参数，
并在每次认证完成前按该房的 2..8 实际容量重新校验。DIRECT/LAN 同样保留 8 人上限。

v91 通过 `MultiplayerPeerExtension` 包装 ENet，不再使用 stock
`SceneMultiplayer.server_relay` 对第三个 transport 可复现停滞的私有发现路径。
Relay 仅在验票成功后才把物理 peer 加入可路由集合，并用自有帧发布幂等的
ADD/REMOVE 逻辑拓扑；未认证 transport 不会暴露给全房 mesh。容量契约虽已
统一为 8 人，发行门禁仍应在目标 Godot 二进制上跑通 Host + 7 members 的真实
E2E，并覆盖断线、重连、丢包和长时 soak。

`CH_MEMBERSHIP=8` 是应用成员控制信道，`CHANNEL_COUNT=9` 是 CH0..CH8 的应用
逻辑信道数。公网包装层额外固定 `RELAY_CONTROL_CHANNEL=9`，并令
`RELAY_SERVICE_CHANNEL=9` 与其共用同一可靠有序队列，所以 Relay 传给 ENet create API
的最大信道索引是 `ENET_MAX_CHANNEL=9`。DIRECT/LAN 不创建这条公网保留信道，
其 ENet 最大应用信道索引仍为 8。

## 快速部署

```bash
# 1. 上传到服务器
scp -r relay_servers/ root@your-server:/opt/arc-nice-relay/

# 2. SSH 登录后执行部署
cd /opt/arc-nice-relay
chmod +x scripts/*.sh
./scripts/deploy.sh

# 3. 启动服务
./scripts/start_lobby.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PUBLIC_IP` | `127.0.0.1` | 服务器公网 IP |
| `LOBBY_HOST` | `0.0.0.0` | API 监听地址 |
| `LOBBY_PORT` | `8000` | API 端口 |
| `RELAY_PORT_START` | `40001` | Relay 端口起始 |
| `RELAY_PORT_END` | `40100` | Relay 端口结束 |
| `GODOT_SERVER_PATH` | `/opt/godot/Godot_v4.6-stable_linux.x86_64` | Godot 可执行文件路径 |
| `RELAY_PROJECT_PATH` | `./relay_godot_project` | Relay 项目路径 |
| `MAX_ROOMS` | `100` | 最大房间数，不得超过 Relay 端口数量 |
| `MAX_PLAYERS_PER_ROOM` | `8` | 公网部署的每房上限，必须在 4..8；单房创建值可在 2..该上限之间选择，默认 4，标准最大值 8 |
| `ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS` | `60` | 创建/加入响应确认前的短租约，必须在 30..60 秒 |
| `ACQUISITION_TOMBSTONE_TTL_SECONDS` | `120` | 取消墓碑与饱和隔离期限，必须在 120..600 秒且长于短租约 |
| `ACQUISITION_TOKEN_CAPACITY` | `4096` | 活动 acquisition 与墓碑共享容量；必须至少为 `MAX_ROOMS * MAX_PLAYERS_PER_ROOM + 1`，至多 100000 |
| `ACQUISITION_CAPABILITY_TTL_SECONDS` | `45` | preflight HMAC capability 有效期，必须在 15..60 秒 |
| `ACQUISITION_CAPABILITY_HMAC_SECRET` | 无，必须配置 | HMAC 根秘密；至少 32 bytes、至少 12 种 byte，部署脚本生成 48-byte 随机值且不输出到日志 |
| `ALLOW_LEGACY_ACQUISITION_REQUESTS` | `false` | 是否临时接受未携带 capability 的旧 CREATE/JOIN/QUICK；只能是 `true`/`false` |
| `ACQUISITION_ADMISSION_GLOBAL_BURST` | `120` | 单进程 preflight/legacy 全局令牌桶 burst，1..10000 |
| `ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND` | `4.0` | 全局桶每秒补充量，0.01..1000 |
| `ACQUISITION_ADMISSION_SOURCE_BURST` | `8` | 单直连来源 burst，不得高于全局 burst |
| `ACQUISITION_ADMISSION_SOURCE_REFILL_PER_SECOND` | `0.5` | 单直连来源每秒补充量，0.01..1000 |
| `ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY` | `4096` | 有界来源桶数量，必须不少于全局 burst，至多 100000 |
| `ACQUISITION_ADMISSION_SOURCE_IDLE_TTL_SECONDS` | `600` | 空闲来源桶回收秒数，60..86400 |
| `ROOM_IDLE_TIMEOUT_SECONDS` | `180` | 房主心跳租约；不得低于 120 秒，当前客户端每 60 秒续租 |
| `RELAY_STARTUP_IDLE_TIMEOUT_SECONDS` | `120` | Relay 启动后从未收到 ENet 连接的回收期限 |
| `RELAY_EMPTY_IDLE_TIMEOUT_SECONDS` | `120` | 曾连接后全员离线的回收期限；必须长于 90 秒重连宽限 |
| `GAME_MAX_DURATION_SECONDS` | `36000` | 房间和 Relay 不可被心跳延长的绝对生命周期 |
| `CLEANUP_INTERVAL_SECONDS` | `30` | 大厅生命周期对账间隔 |
| `RELAY_STARTUP_GRACE_SECONDS` | `5` | spawn 后确认 Relay 仍存活再挂接房间的宽限 |
| `RELAY_ADMISSION_TICKET_TTL_SECONDS` | `60` | 单次 Relay admission ticket 的短连接窗口，必须在 15..120 秒且长于启动宽限 |
| `RELAY_ADMISSION_REFRESH_BURST` | `3` | 同一已验证成员在滚动窗口内可即时换票的次数；只能为 2..3，以覆盖 ack 丢失重试且维持 replay 账本上界 |
| `RELAY_ADMISSION_REFRESH_WINDOW_SECONDS` | `5` | 成员换票滚动限流窗口，必须在 5..60 秒 |

旧版 `ROOM_IDLE_TIMEOUT` / `RELAY_IDLE_TIMEOUT` 将 10 小时同时当作心跳租约、
首次连接等待和游戏上限，现已不再读取。升级部署时应删除这两个旧变量，并配置上表
六个独立边界。房间只接受房主 `keepalive` 推进心跳 deadline；加入、离开、状态更新
和 Relay 挂接都不会续租。当前客户端在大厅阶段不发送周期心跳，因此 STARTING/WAITING
不建立空闲 deadline；首次进入 IN_GAME 时才启用 180 秒房主心跳租约。即使心跳持续
成功，绝对生命周期到期后仍会回收。

新客户端先向 `/acquisitions/preflight` 提交 action 与严格 payload。服务端只签发
`acq1` HMAC capability，不创建 Room、不占 Relay；capability 绑定 action、长度前缀规范
payload 的 SHA-256 指纹、短期 expiry 与 128-bit 随机 nonce。实际 CREATE/JOIN/QUICK
必须携带该 capability，服务端在任何 Room/Relay 副作用前验签；同 capability、同参数
会重放同一份冻结响应，动作或参数不同返回 HTTP 409，签名无效或过期则拒绝。JOIN/QUICK
完成异步房间/Relay 对账后会在同锁 begin 紧前再次验签；CREATE 也走相同的最终验签与
RoomManager expiry CAS，因此初验后等待到期的请求不会提交。

提交后先授予 60 秒 provisional 短租约。响应中的 `member_token` 是与短期 capability
不同的独立成员秘密：普通成员先用响应中的 `relay_admission_ticket` 完成 Relay 原生认证，
再用 `(room_id, player_name, member_token)`
调用 `/acquisitions/confirm`；即使此时 capability 已过期仍可确认。房主由
`/rooms/{id}/host_ready` 确认。未确认身份即使客户端崩溃且取消从未送达也会自动回收。
目前该回收只作用于大厅目录：若恶意成员已经完成 Relay/Host 注册却故意不 confirm，
provisional 目录项到期后还没有服务端撤销消息同步踢出其 transport/Host 名册。因此这里
只是 acquisition 占位回收，不代表 provisional → ACTIVE 的端到端生命周期已经闭合；
正式容量对账仍需后续统一 directory-confirmed proof 或 revocation 协议。
响应到达后退出统一使用 `/rooms/{id}/leave` 与成员秘密；只有响应前不知道 room id 时，
才用 `/acquisitions/release` 携 capability 取消迟到提交。

`/acquisitions/release` 先离线验签。随机无效输入幂等返回 `ignored`，不会写墓碑；有效
capability 在 expiry 后只额外接受 `ACQUISITION_TOMBSTONE_TTL_SECONDS` 的有界取消宽限，
再旧同样忽略。宽限内若实际命令尚未到达，服务端写取消墓碑阻止迟到提交；若已提交，
则精确移除成员或关闭房主房间。墓碑只有在单调保留 TTL 和其签名可提交窗口都结束后才
能回收；即使异步对账等待超过墓碑 TTL，已取消请求也不能复活。墓碑索引饱和时继续对新
acquisition fail-close，饱和 fence 同样同时受这两个截止时间保护。

preflight 与显式 legacy 请求共用进程级 global/source 双令牌桶；同一把锁保证并发精确
消费，global 已耗尽时不会为伪造新来源分配桶。来源只取 ASGI `Request.client.host`，
明确忽略 `X-Forwarded-For`。`start_lobby.sh` 同时固定 `--workers 1` 和
`--no-proxy-headers`：后者禁止 Uvicorn 在 FastAPI 之前用转发头改写 ASGI `client`，因此
限流来源始终是原始 socket 对端。多 worker/多实例部署前必须把限流与 acquisition 状态迁到
共享后端。若前置反向代理，source 桶看到的是直连代理地址，不得靠不受信请求头恢复客户端 IP。

大厅使用可注入的单调时钟计算两个房间 deadline，Relay 使用 Godot 主循环的单调
`ticks` 同时检查首次连接、全员离线和绝对生命周期。重启 Relay 只获得房间绝对
deadline 的剩余时长，不会重新领取完整 10 小时。进程回收以“端口 + Relay 实例
世代”作为条件停止依据；停止失败保留终止账本和端口所有权，已退出实例先进入隔离，
只有旧房间完成对账后才允许复用，因此延迟到达的清理不会终止新实例。
大厅关闭时会在 15 秒单调总期限内短间隔重试停止和 reap；期限结束仍存活的精确
实例会作为关闭错误上报，且其端口与终止账本继续保留，不会伪报“全部终止”。

## 游戏模式准入

`GameMode` 的 9 个字符串是稳定的 wire/JSON 兼容表，不能因入口隐藏而删除；请求模型
仍可解析全部值，历史房间也仍可序列化，便于旧数据迁移和诊断。正式大厅的运行准入
另由单一清单管理，目前只开放 `standard`、`tower_defense` 与 `test_arena_p3`。其中
`test_arena_p3` 是正式 Rogue 模式沿用的稳定 wire key，并不表示该内容仍是调试模式。

原始 REST 请求若用其余 6 个隐藏值创建房间或快速匹配，会在创建 Room/Relay 前以
HTTP 403 拒绝。隐藏历史房间不会出现在公开房间列表中，也不能加入、登记房主就绪、
续租、更新状态或请求 Relay；成员离开和房主销毁仍然可用，以保证遗留资源能安全
收尾。正式房间的模式错配继续返回 404，避免把“房间不可加入”拆成可探测的内部状态。

## API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 健康检查 |
| `GET` | `/rooms` | 获取可加入房间列表 |
| `POST` | `/acquisitions/preflight` | 限流后签发 action/payload 绑定的短期 HMAC capability；不占房间资源 |
| `POST` | `/rooms` | 创建新房间 |
| `POST` | `/rooms/{id}/join` | 加入房间 |
| `POST` | `/rooms/{id}/host_ready` | 房主登记 Relay peer id 并开放加入 |
| `POST` | `/rooms/{id}/admission_ticket` | 普通成员用 `member_token` 换取新的单次短票（用于重连） |
| `POST` | `/rooms/{id}/keepalive` | 房主续租房间，避免游戏中被空闲清理 |
| `POST` | `/rooms/{id}/leave` | 使用成员令牌离开房间；房主离开会关闭房间 |
| `POST` | `/acquisitions/confirm` | Relay 连通后确认 provisional 成员身份 |
| `POST` | `/acquisitions/release` | 不依赖 room id，按 acquisition secret 幂等取消或释放 |
| `PATCH` | `/rooms/{id}` | 更新房间状态 |
| `POST` | `/rooms/{id}/request_relay` | 请求 Relay 中继 |
| `DELETE` | `/rooms/{id}` | 销毁房间 |
| `POST` | `/matchmaking/quick` | 快速匹配 |

创建房间或快速匹配自动创建房间时，响应会返回 `host_token`。只有房主需要保存它；普通
`join` 响应不会包含该字段。受保护请求的响应还会原样返回短期 `acquisition_token`，并
返回独立随机 `member_token`；二者不得相等，且都不会出现在房间列表或其他玩家资料中。
所有带调用者私有成员身份的 create/join/quick/host_ready 响应还会返回
`relay_admission_ticket`。房间列表、匿名房间快照和其他玩家资料绝不包含该票据。

### Relay 原生认证契约

每个 `RoomInfo` 在创建时生成独立随机 admission secret。Lobby 只通过子进程环境变量
`ARC_NICE_RELAY_ROOM_ID` 与 `ARC_NICE_RELAY_ADMISSION_SECRET` 传给对应 Godot Relay；
两者都不进入 Relay 命令行，其中 secret 也绝不进入 HTTP 响应或日志（room id 本身是
公开房间标识）。缺少任一值时 Relay/Launcher 均 fail-close，旧的
“第一个 ENet 连接自动成为 Host”行为已删除。

`relay_admission_ticket` 是以下 wire 格式：

```
ra1.<base64url-without-padding(canonical-json)>.<lowercase-hex-hmac-sha256>
```

HMAC 输入是 ASCII `ra1.<payload>`；JSON claims 精确包含 `v=1`、`room_id`、
`role`（`host` 或 `member`）、`player_name`、`iat`、`exp` 和随机 `nonce`。票据按房间
剩余绝对生命周期与 60 秒短连接窗的较小值过期，并由每房间 secret 隔离。Relay 在成功
准入前原子消费 nonce；同票重放（包括原连接断开后）、跨房间重放、篡改、未知字段和过期
均拒绝。消费账本先清过期项；容量按房间人数推导为
`1 + (max_clients - 1) * 73 + 64`。默认 4 人房的容量为 284，最大 8 人房的
硬上界为 576：覆盖每个 member 在 120 秒 TTL、每 5 秒 3 次刷新下的合法最坏窗口，
再加 Host/控制重试余量；满载时拒绝新认证而不继续增长。受控
Relay 重启还会轮换房间 secret，旧进程签发的短票不能跨世代重放。

双方必须在设置 `multiplayer_peer` 时配置非空 `SceneMultiplayer.auth_callback`。客户端在
`peer_authenticating` 中向 server peer 1 发送 UTF-8 JSON：

```json
{"v":1,"ticket":"ra1....","player_name":"...","character_id":"weishidaier","character_confirmed":true,"protocol_version":92,"reconnect_token":"<32 lowercase hex>","content_manifest_schema":1,"content_digest":"<64 lowercase hex>"}
```

Relay 验票成功后先用 `send_auth` 返回 ack，再调用 `complete_auth(peer_id)`：

```json
{"v":1,"ok":true,"room_id":"...","role":"host","player_name":"...","peer_id":2}
```

客户端核对 `ok/room_id/role` 后调用 `complete_auth(1)`。只有双方完成后才会产生
`connected_to_server/peer_connected`，认证中的 peer 不进入 `get_peers()`、RPC 或
`server_relay`。失败响应为 `{"v":1,"ok":false,"code":"..."}`，随后断连；客户端不得
依赖失败 ack 一定送达。只有 host ticket 能建立逻辑 Host 和三个 stub authority；member
ticket 在 Host 尚未认证时必定拒绝，同一 `player_name` 也不能同时占用多个连接。
请求必须精确包含上述 9 个字段；未知字段、类型/长度错误、非规范 token/digest，或
`player_name` 与票据 claims 不一致都会在认证阶段拒绝。Relay 为每个已认证 peer 保存票据
身份和这份原始注册元组；成员双方完成认证后，Relay 先在 reliable CH9 发布 ADD，
紧接着在同一物理信道向逻辑 Host 单次转发该元组。Host 只接受 peer 1 的转发 envelope，
并向 peer 1 二次查询该 transport
的认证身份。只有 Relay 返回同一 peer、请求号、房间、`member` 角色与完全一致的玩家名，
Host 才把注册交给成员账本；查询无响应、迟到、缺失或不一致都在统一 10 秒 registration
deadline 内断开，未绑定 peer 不进入 gameplay。身份查询/结果 RPC 于 v89 引入；认证
注册转发与统一 CH8 布局于 v90 引入；v91 引入认证感知帧协议，并把拓扑与 Relay
专用 RPC 统一放到 CH9，以物理可靠顺序消除 ADD/注册竞态。
只有认证双方都调用 `complete_auth` 并进入 `peer_connected` 后才开放成员准入；Host
success ack 若在此之前丢失，可用新 nonce 重试。同一 Relay 世代真正连入过 Host 后便
永久封闭 Host 槽，Host 断线后不接受替代 Host，符合当前无 Host 迁移约束。普通成员
transport 重连不能复用已消费票据，必须先向
`POST /rooms/{id}/admission_ticket` 提交 `{"player_name":"...","member_token":"..."}`，
换取当前 `relay_ip`、`relay_port`、非零 `host_peer_id` 与新的
`relay_admission_ticket`；该端点不为 Host 签票。
成功响应精确包含 7 个字段：`room_id`、`player_name`、`role`、`relay_ip`、
`relay_port`、`host_peer_id`、`relay_admission_ticket`，其中 `role` 固定为 `member`；
该正式端点也经过 release room 门禁，调试/隐藏模式不能绕过它换票。
该端点仅提供重新认证/重连的基础能力；当前游戏客户端尚未接通“掉线 → HTTP 刷新短票
→ 重建 ENet → 安全重载当前多人场景”的公网自动重连状态机，不能把此接口视为生产自动
重连已经完成。
同一已验证成员默认可在 5 秒内突发换票 3 次以覆盖响应/认证 ack 丢失，第 4 次返回
HTTP 429 和 `Retry-After`。Host 启动或受控重启 Relay 时，受 `host_token` 保护的
`POST /rooms/{id}/request_relay` 会返回新世代的 Host ticket；Host 不能使用成员换票端点。
该 Host 响应使用同一 7 字段 schema，`role` 固定为 `host`，并带当前 `host_peer_id`：
新 Relay 世代在 Host 尚未完成认证时为 `0`，完成
`host_ready` 后为实际 peer id。
底层 ENet transport 容量与业务房间容量分离：Relay 在房间实际容量之上额外
预留 8 个认证中 socket，并把 transport 硬上限限制为 16。因此默认 4 人房的
ENet transport 容量为 12，最大 8 人房为 16；认证中 peer 同时最多 8 个。
认证成功前还会再次按该房的 `max_clients` 检查业务人数。这样短期无效连接
不能直接占满所有合法席位，但公网部署仍应在防火墙/边缘层增加 UDP 来源限速，抵御分布式
来源持续占满这 8 个短暂 reserve。

生产 Launcher 只把运行 Godot 所需的 PATH/HOME/TMP/locale/动态库等 allowlist 环境和
`ARC_NICE_RELAY_ROOM_ID`、`ARC_NICE_RELAY_ADMISSION_SECRET` 交给单房 Relay；大厅的
acquisition HMAC、数据库或其他全局服务秘密不会继承。Launcher 和 Relay 日志只记录房间
端口、进程世代、peer id 与角色，不记录 secret 或 ticket；Relay secret 只走子进程环境，
ticket 只走 `send_auth` 的认证数据帧。

新装部署默认 `ALLOW_LEGACY_ACQUISITION_REQUESTS=false`，缺 capability 的
CREATE/JOIN/QUICK 以 HTTP 428 fail-close。若确有在线旧客户端需要滚动迁移，顺序必须是：
滚动升级必须先部署服务端，再发布新客户端，最后关闭临时兼容开关。

1. 先部署支持 preflight 的服务端，并由运维**显式**临时设置
   `ALLOW_LEGACY_ACQUISITION_REQUESTS=true`；legacy 请求仍经过同一全局/来源限流。
2. 发布会先 preflight、响应前用 capability release、响应后用 member leave 的新客户端。
3. 确认旧客户端淘汰后恢复 `false`；部署模板始终保持 `false`，不能把兼容窗口当默认值。

HMAC secret 只存在于服务端环境；不得写入客户端、响应或日志。轮换 secret 会立即使旧
capability 失效，应与最长 60 秒 capability 和 120 秒取消宽限一起安排短维护窗口。

以下房主操作必须在 JSON 请求体中携带 `host_token`：
- `PATCH /rooms/{id}`
- `POST /rooms/{id}/host_ready`
- `POST /rooms/{id}/keepalive`
- `POST /rooms/{id}/request_relay`
- `DELETE /rooms/{id}`

## 测试服 HTTP 边界

当前 Godot 默认大厅地址 `http://47.123.6.127:8000` 明确只用于 **TEST SERVER**，可由
`ARC_PUBLIC_LOBBY_API_BASE_URL` 在唯一配置读取口覆盖。本阶段按测试服要求保留明文 HTTP
可用性，没有关闭证书校验，也没有伪造无法验证的 HTTPS IP。正式公网发布前必须改为
受信任证书的 HTTPS 域名，或在大厅前部署终止 TLS 的反向代理，再把客户端环境变量指向
该 HTTPS 地址；不能继续通过 HTTP 传输 capability、member/host token。

## 防火墙配置

阿里云安全组需开放：
- **TCP 8000** — 大厅 API
- **UDP 40001-40100** — Relay 端口范围
