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

当前网络基线为协议 v30、8 个 ENet 通道。Relay 只转发 RPC，不重复实现游戏状态逻辑；
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
| `POST` | `/rooms/{id}/leave` | 离开房间 |
| `PATCH` | `/rooms/{id}` | 更新房间状态 |
| `POST` | `/rooms/{id}/request_relay` | 请求 Relay 中继 |
| `DELETE` | `/rooms/{id}` | 销毁房间 |
| `POST` | `/matchmaking/quick` | 快速匹配 |

创建房间或快速匹配自动创建房间时，响应会返回 `host_token`。只有房主需要保存它；普通 `join` 响应不会包含该字段。

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
