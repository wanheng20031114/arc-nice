#!/bin/bash
# 启动大厅 API 服务
# 使用方法: ./start_lobby.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# 加载环境变量
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # .env 由 deploy.sh 以 0600 创建；直接在当前 shell 加载，避免秘密进入子进程参数。
    . "$ROOT_DIR/.env"
    set +a
fi

echo "启动 ARC NICE 大厅 API..."
echo "  PUBLIC_IP=$PUBLIC_IP"
echo "  LOBBY_PORT=$LOBBY_PORT"
echo "  RELAY_PORT_RANGE=$RELAY_PORT_START-$RELAY_PORT_END"

cd "$ROOT_DIR"
uvicorn lobby_api.main:app \
    --host "${LOBBY_HOST:-0.0.0.0}" \
    --port "${LOBBY_PORT:-8000}" \
    --workers 1 \
    --no-proxy-headers \
    --log-level info
