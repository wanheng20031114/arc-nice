"""
大厅服务器配置。
"""

import os

# ─── 网络 ────────────────────────────────────────
LOBBY_HOST = os.getenv("LOBBY_HOST", "0.0.0.0")
LOBBY_PORT = int(os.getenv("LOBBY_PORT", "8000"))

# ─── Relay 端口范围 ──────────────────────────────
RELAY_PORT_START = int(os.getenv("RELAY_PORT_START", "40001"))
RELAY_PORT_END = int(os.getenv("RELAY_PORT_END", "40100"))

# ─── Godot Headless 路径 ─────────────────────────
# 阿里云 Linux 上的 Godot Server 二进制路径
GODOT_SERVER_PATH = os.getenv(
    "GODOT_SERVER_PATH",
    "/opt/godot/Godot_v4.6-stable_linux.x86_64"
)

# Relay Godot 项目路径
RELAY_PROJECT_PATH = os.getenv(
    "RELAY_PROJECT_PATH",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "relay_godot_project")
)

# ─── 房间超时 ────────────────────────────────────
# 房间空闲超时（秒），超时后自动销毁
ROOM_IDLE_TIMEOUT = int(os.getenv("ROOM_IDLE_TIMEOUT", "600"))

# Relay 进程无连接超时（秒）
RELAY_IDLE_TIMEOUT = int(os.getenv("RELAY_IDLE_TIMEOUT", "300"))

# Relay 启动后给 Godot/ENet 完成监听的等待时间（秒）
RELAY_STARTUP_GRACE_SECONDS = float(os.getenv("RELAY_STARTUP_GRACE_SECONDS", "5.0"))

# ─── 限制 ────────────────────────────────────────
MAX_ROOMS = int(os.getenv("MAX_ROOMS", "100"))
MAX_PLAYERS_PER_ROOM = int(os.getenv("MAX_PLAYERS_PER_ROOM", "8"))

# ─── 公网 IP ─────────────────────────────────────
# 用于告诉客户端 Relay 地址，需设置为阿里云 ECS 公网 IP
PUBLIC_IP = os.getenv("PUBLIC_IP", "127.0.0.1")
