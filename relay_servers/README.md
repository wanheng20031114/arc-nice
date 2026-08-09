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

当前网络基线为协议 v51、8 个 ENet 通道。v51 新增精英爆炸无人机操作员与独立
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
P1B 模式、P1A 显示名及稳定 key `test_arena_p1`/`test_arena_p1b` 保持兼容。
v35 的战斗机器人枪手弹丸及玩家受击来源 wire ID 17 保持兼容；
P3 路线世界继续使用约 12Hz 的轻量角色姿态同步：
Client 在输入信道上报，Host 校验后在玩家状态信道广播，非法位置通过可靠信道纠正。
v34 的 P3 路线全量快照携带 `runtime_contract_hash`，Host 与 Client 必须使用相同的世界几何契约；
v50 及更旧客户端不能加入 v51 房间。
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
