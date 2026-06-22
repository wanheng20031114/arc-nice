"""
ARC NICE 多人大厅 API (FastAPI)

启动方式:
    uvicorn lobby_api.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from . import config
from .models import RoomStatus
from .room_manager import RoomManager
from .relay_launcher import RelayLauncher


# ─── 全局实例 ────────────────────────────────────
room_mgr = RoomManager()
relay_launcher = RelayLauncher()
_cleanup_task: Optional[asyncio.Task] = None


# ─── 生命周期 ────────────────────────────────────

async def _periodic_cleanup() -> None:
    """定期清理空闲房间和死亡的 Relay 进程。"""
    while True:
        await asyncio.sleep(60)
        removed = room_mgr.cleanup_idle_rooms()
        for room in removed:
            if room.relay_port > 0:
                relay_launcher.stop_relay(room.relay_port)
            print(f"[Cleanup] 已清理空闲房间: {room.id} ({room.name})")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _cleanup_task
    _cleanup_task = asyncio.create_task(_periodic_cleanup())
    print(f"[Lobby] 大厅 API 启动于 {config.LOBBY_HOST}:{config.LOBBY_PORT}")
    yield
    if _cleanup_task:
        _cleanup_task.cancel()
    relay_launcher.stop_all()
    print("[Lobby] 大厅 API 已关闭")


app = FastAPI(title="ARC NICE Lobby", lifespan=lifespan)


# ─── 请求/响应模型 ───────────────────────────────

class CreateRoomRequest(BaseModel):
    name: str = ""
    host_name: str
    max_players: int = Field(default=4, ge=2, le=8)


class JoinRoomRequest(BaseModel):
    player_name: str


class UpdateRoomRequest(BaseModel):
    status: str
    host_token: str


class HostTokenRequest(BaseModel):
    host_token: str


class HostReadyRequest(BaseModel):
    host_token: str
    host_peer_id: int = Field(ge=1)


class QuickMatchRequest(BaseModel):
    player_name: str


async def _ensure_room_relay(room) -> dict:
    """Start a relay for a newly-created room and attach its port."""
    port = relay_launcher.allocate_port()
    if port is None:
        room_mgr.destroy_room(room.id, room.host_token)
        raise HTTPException(status_code=503, detail="无可用 Relay 端口")

    pid = relay_launcher.start_relay(port)
    if pid is None:
        room_mgr.destroy_room(room.id, room.host_token)
        raise HTTPException(status_code=500, detail="启动 Relay 失败")

    await asyncio.sleep(config.RELAY_STARTUP_GRACE_SECONDS)
    if not relay_launcher.is_relay_running(port):
        relay_launcher.stop_relay(port)
        room_mgr.destroy_room(room.id, room.host_token)
        raise HTTPException(status_code=500, detail="Relay 启动后异常退出")

    room_mgr.set_relay_info(room.id, port, pid)
    return room.to_join_dict(config.PUBLIC_IP, include_host_token=True)


# ─── API 端点 ────────────────────────────────────

@app.get("/health")
async def health_check() -> dict:
    return {
        "status": "ok",
        "public_ip": config.PUBLIC_IP,
        "active_relays": relay_launcher.get_active_count(),
    }


@app.get("/rooms")
async def list_rooms() -> list[dict]:
    """获取所有可加入的房间列表。"""
    return room_mgr.list_joinable_rooms()


@app.post("/rooms")
async def create_room(req: CreateRoomRequest) -> dict:
    """创建新房间。"""
    room_name = req.name if req.name else f"{req.host_name} 的房间"

    room = room_mgr.create_room(
        name=room_name,
        host_name=req.host_name,
        host_ip="",  # Host 的公网 IP 将由 Host 自行通知
        max_players=req.max_players,
    )

    if room is None:
        raise HTTPException(status_code=503, detail="房间已满，无法创建更多房间")

    return await _ensure_room_relay(room)


@app.post("/rooms/{room_id}/join")
async def join_room(room_id: str, req: JoinRoomRequest) -> dict:
    """加入指定房间。"""
    room = room_mgr.join_room(room_id, req.player_name)
    if room is None:
        raise HTTPException(status_code=404, detail="房间不存在、已满或玩家名重复")

    return room.to_join_dict(config.PUBLIC_IP)


@app.post("/rooms/{room_id}/host_ready")
async def host_ready(room_id: str, req: HostReadyRequest) -> dict:
    """房主已连接 Relay，登记真实 host peer id，并开放房间加入。"""
    room = room_mgr.mark_host_ready(room_id, req.host_token, req.host_peer_id)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效、房间不存在或 host peer id 无效")
    return room.to_join_dict(config.PUBLIC_IP, include_host_token=True)


@app.post("/rooms/{room_id}/leave")
async def leave_room(room_id: str, req: JoinRoomRequest) -> dict:
    """离开指定房间。"""
    room = room_mgr.get_room(room_id)
    if room is None:
        raise HTTPException(status_code=404, detail="房间不存在")
    removed = room_mgr.leave_room(room_id, req.player_name)
    if removed is not None and removed.relay_port > 0:
        relay_launcher.stop_relay(removed.relay_port)
    return {"status": "ok"}


@app.patch("/rooms/{room_id}")
async def update_room(room_id: str, req: UpdateRoomRequest) -> dict:
    """更新房间状态。"""
    try:
        status = RoomStatus(req.status)
    except ValueError:
        raise HTTPException(status_code=400, detail=f"无效状态: {req.status}")

    success = room_mgr.update_room_status(room_id, status, req.host_token)
    if not success:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")
    return {"status": "ok"}


@app.post("/rooms/{room_id}/request_relay")
async def request_relay(room_id: str, req: HostTokenRequest) -> dict:
    """请求为指定房间启动 Relay 中继。"""
    room = room_mgr.get_room(room_id)
    if room is None:
        raise HTTPException(status_code=404, detail="房间不存在")
    if not room_mgr.verify_host_token(room_id, req.host_token):
        raise HTTPException(status_code=403, detail="房主令牌无效")

    # 如果已有 Relay 且仍在运行，直接返回
    if room.relay_port > 0 and relay_launcher.is_relay_running(room.relay_port):
        return {
            "relay_ip": config.PUBLIC_IP,
            "relay_port": room.relay_port,
        }

    # 分配新端口
    port = relay_launcher.allocate_port()
    if port is None:
        raise HTTPException(status_code=503, detail="无可用 Relay 端口")

    # 启动 Relay 进程
    pid = relay_launcher.start_relay(port)
    if pid is None:
        raise HTTPException(status_code=500, detail="启动 Relay 失败")

    # 等待 Relay 就绪（给 Godot/ENet 一点启动时间）
    await asyncio.sleep(config.RELAY_STARTUP_GRACE_SECONDS)

    # 检查进程是否仍在运行
    if not relay_launcher.is_relay_running(port):
        relay_launcher.stop_relay(port)
        raise HTTPException(status_code=500, detail="Relay 启动后异常退出")

    room_mgr.set_relay_info(room_id, port, pid)

    return {
        "relay_ip": config.PUBLIC_IP,
        "relay_port": port,
    }


@app.delete("/rooms/{room_id}")
async def destroy_room(room_id: str, req: HostTokenRequest) -> dict:
    """销毁指定房间及其 Relay。"""
    room = room_mgr.destroy_room(room_id, req.host_token)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")

    if room.relay_port > 0:
        relay_launcher.stop_relay(room.relay_port)

    return {"status": "ok"}


@app.post("/matchmaking/quick")
async def quick_match(req: QuickMatchRequest) -> dict:
    """快速匹配：找一个最佳房间加入。"""
    room = room_mgr.find_match()

    if room is None:
        # 没有可用房间，自动创建一个
        room = room_mgr.create_room(
            name=f"{req.player_name} 的房间",
            host_name=req.player_name,
            host_ip="",
            max_players=4,
        )
        if room is None:
            raise HTTPException(status_code=503, detail="无法创建房间")
        return await _ensure_room_relay(room)

    # 加入找到的房间
    joined = room_mgr.join_room(room.id, req.player_name)
    if joined is None:
        raise HTTPException(status_code=409, detail="加入房间失败")

    return joined.to_join_dict(config.PUBLIC_IP)
