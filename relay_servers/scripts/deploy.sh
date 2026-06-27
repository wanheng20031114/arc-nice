#!/bin/bash
# ARC NICE Relay Server 部署脚本 (阿里云 Linux)
# 使用方法: chmod +x deploy.sh && ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════"
echo "  ARC NICE Relay Server 部署"
echo "═══════════════════════════════════════════"

# ─── 1. 安装 Python 依赖 ─────────────────────
echo ""
echo "[1/4] 安装 Python 依赖..."
cd "$ROOT_DIR"
pip3 install -r requirements.txt

# ─── 2. 下载 Godot Server (如果不存在) ────────
GODOT_VERSION="4.6-stable"
GODOT_DIR="/opt/godot"
GODOT_BIN="$GODOT_DIR/Godot_v${GODOT_VERSION}_linux.x86_64"

if [ ! -f "$GODOT_BIN" ]; then
    echo ""
    echo "[2/4] 下载 Godot Server..."
    mkdir -p "$GODOT_DIR"
    cd "$GODOT_DIR"
    
    DOWNLOAD_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
    echo "  下载: $DOWNLOAD_URL"
    wget -q "$DOWNLOAD_URL" -O godot_server.zip
    unzip -o godot_server.zip
    rm godot_server.zip
    chmod +x "$GODOT_BIN"
    echo "  Godot Server 已安装到: $GODOT_BIN"
else
    echo ""
    echo "[2/4] Godot Server 已存在: $GODOT_BIN"
fi

# ─── 3. 配置环境变量 ─────────────────────────
echo ""
echo "[3/4] 配置环境变量..."

# 自动检测公网 IP
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "127.0.0.1")
echo "  检测到公网 IP: $PUBLIC_IP"

ENV_FILE="$ROOT_DIR/.env"
cat > "$ENV_FILE" <<EOF
PUBLIC_IP=$PUBLIC_IP
GODOT_SERVER_PATH=$GODOT_BIN
RELAY_PROJECT_PATH=$ROOT_DIR/relay_godot_project
LOBBY_HOST=0.0.0.0
LOBBY_PORT=8000
RELAY_PORT_START=40001
RELAY_PORT_END=40100
MAX_ROOMS=100
ROOM_IDLE_TIMEOUT=36000
RELAY_IDLE_TIMEOUT=36000
EOF

echo "  环境变量已写入: $ENV_FILE"

# ─── 4. 防火墙提示 ───────────────────────────
echo ""
echo "[4/4] 防火墙配置提示"
echo "  请确保以下端口已在阿里云安全组中开放："
echo "    TCP 8000          (大厅 API)"
echo "    UDP 40001-40100   (Relay 端口范围)"
echo ""
echo "  阿里云控制台 → ECS → 安全组 → 配置规则 → 添加入方向规则"

# ─── 完成 ────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  部署完成！"
echo ""
echo "  启动大厅 API:"
echo "    cd $ROOT_DIR && ./scripts/start_lobby.sh"
echo "═══════════════════════════════════════════"
