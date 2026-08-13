# ARC NICE Relay Server

多人模式的云端服务组件，部署在阿里云 Linux ECS 上。

## 架构

```
relay_servers/
├── lobby_api/              # FastAPI 大厅 API
│   ├── main.py             # API 入口
│   ├── models.py           # 数据模型
│   ├── room_manager.py     # 房间生命周期管理
│   ├── relay_launcher.py   # Godot Headless Relay 启动器
│   └── config.py           # 配置
├── relay_godot_project/    # Godot Headless Relay 项目
│   ├── project.godot
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

当前网络基线为协议 v71、8 个 ENet 通道。v71 新增地下水道普通作战（迅捷原石虫/
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
v70 及更旧客户端不能加入 v71 房间。
Relay 只转发 RPC，不重复实现游戏状态逻辑；
每次调整主项目 RPC 的名称、注解、参数或通道后，都必须同步两个 stub，并在仓库根目录运行：

```bash
godot --headless --path . --script res://dev_tools/relay_rpc_parity_smoke_test.gd
```

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
| `MAX_ROOMS` | `100` | 最大房间数 |
| `ROOM_IDLE_TIMEOUT` | `36000` | 房间空闲超时(秒)，低于 10 小时会按 10 小时处理 |
| `RELAY_IDLE_TIMEOUT` | `36000` | Relay 空闲超时(秒)，低于 10 小时会按 10 小时处理 |

## API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 健康检查 |
| `GET` | `/rooms` | 获取可加入房间列表 |
| `POST` | `/rooms` | 创建新房间 |
| `POST` | `/rooms/{id}/join` | 加入房间 |
| `POST` | `/rooms/{id}/host_ready` | 房主登记 Relay peer id 并开放加入 |
| `POST` | `/rooms/{id}/keepalive` | 房主续租房间，避免游戏中被空闲清理 |
| `POST` | `/rooms/{id}/leave` | 使用成员令牌离开房间；房主离开会关闭房间 |
| `PATCH` | `/rooms/{id}` | 更新房间状态 |
| `POST` | `/rooms/{id}/request_relay` | 请求 Relay 中继 |
| `DELETE` | `/rooms/{id}` | 销毁房间 |
| `POST` | `/matchmaking/quick` | 快速匹配 |

创建房间或快速匹配自动创建房间时，响应会返回 `host_token`。只有房主需要保存它；普通 `join` 响应不会包含该字段。
每次创建或加入房间的响应还会向当前成员返回独立、不可猜测的 `member_token`；该字段不会出现在房间列表或其他玩家资料中。调用 `POST /rooms/{id}/leave` 时必须同时提交当前成员的 `player_name` 与 `member_token`。房主使用该接口离开时会安全关闭房间，原有携带 `host_token` 的 `DELETE` 接口继续保留。

以下房主操作必须在 JSON 请求体中携带 `host_token`：
- `PATCH /rooms/{id}`
- `POST /rooms/{id}/host_ready`
- `POST /rooms/{id}/keepalive`
- `POST /rooms/{id}/request_relay`
- `DELETE /rooms/{id}`

## 防火墙配置

阿里云安全组需开放：
- **TCP 8000** — 大厅 API
- **UDP 40001-40100** — Relay 端口范围
