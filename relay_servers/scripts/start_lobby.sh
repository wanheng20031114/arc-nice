#!/bin/bash
# 启动大厅 API 服务
# 使用方法: ./start_lobby.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# 加载环境变量
if [ -f "$ROOT_DIR/.env" ]; then
    export $(grep -v '^#' "$ROOT_DIR/.env" | xargs)
fi

echo "启动 ARC NICE 大厅 API..."
echo "  PUBLIC_IP=$PUBLIC_IP"
echo "  LOBBY_PORT=$LOBBY_PORT"
echo "  RELAY_PORT_RANGE=$RELAY_PORT_START-$RELAY_PORT_END"

cd "$ROOT_DIR"
uvicorn lobby_api.main:app \
    --host "${LOBBY_HOST:-0.0.0.0}" \
    --port "${LOBBY_PORT:-8000}" \
    --log-level info
