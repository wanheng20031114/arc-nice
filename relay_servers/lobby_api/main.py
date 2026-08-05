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
from .models import GameMode, RoomStatus
from .room_manager import RoomManager
from .relay_launcher import RelayLauncher


# ─── 全局实例 ────────────────────────────────────
room_mgr = RoomManager()
relay_launcher = RelayLauncher()
_cleanup_task: Optional[asyncio.Task] = None
# Single-worker Uvicorn owns one event loop.  Sharing the in-flight task makes
# relay startup idempotent while its startup grace sleep yields to other
# requests.  Multi-worker deployments still require an external coordinator.
_relay_start_tasks: dict[str, asyncio.Task[tuple[int, int]]] = {}


# ─── 生命周期 ────────────────────────────────────

async def _periodic_cleanup() -> None:
    """定期清理空闲房间和死亡的 Relay 进程。"""
    while True:
        await asyncio.sleep(60)
        _cleanup_once()


def _cleanup_once() -> None:
    """执行一次 Relay/房间对账和空闲回收。"""
    _reconcile_exited_relays()
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
    name: str = Field(default="", max_length=64)
    host_name: str = Field(min_length=1, max_length=32)
    max_players: int = Field(default=4, ge=2, le=8)
    game_mode: GameMode = GameMode.STANDARD


class JoinRoomRequest(BaseModel):
    player_name: str = Field(min_length=1, max_length=32)
    game_mode: GameMode = GameMode.STANDARD


class LeaveRoomRequest(BaseModel):
    player_name: str = Field(min_length=1, max_length=32)
    member_token: str = Field(min_length=1, max_length=128)


class UpdateRoomRequest(BaseModel):
    status: str = Field(min_length=1, max_length=32)
    host_token: str = Field(min_length=1, max_length=128)


class HostTokenRequest(BaseModel):
    host_token: str = Field(min_length=1, max_length=128)


class HostReadyRequest(BaseModel):
    host_token: str = Field(min_length=1, max_length=128)
    host_peer_id: int = Field(ge=1)


class QuickMatchRequest(BaseModel):
    player_name: str = Field(min_length=1, max_length=32)
    game_mode: GameMode = GameMode.STANDARD


async def _ensure_room_relay(room) -> dict:
    """Start a relay for a newly-created room and attach its port."""
    await _get_or_start_room_relay(room)
    return room.to_join_dict(
        config.PUBLIC_IP,
        include_host_token=True,
        member_name=room.host_name,
    )


async def _get_or_start_room_relay(room) -> tuple[int, int]:
    """Return one shared startup result for all concurrent callers of a room."""
    if (
        room.relay_port > 0
        and relay_launcher.is_relay_running(room.relay_port)
    ):
        return room.relay_port, room.relay_pid

    task = _relay_start_tasks.get(room.id)
    if task is None:
        task = asyncio.create_task(_start_room_relay(room))
        _relay_start_tasks[room.id] = task
        task.add_done_callback(
            lambda done_task, room_id=room.id: _forget_relay_start_task(
                room_id,
                done_task,
            )
        )
    # A cancelled HTTP connection must not cancel the process startup shared by
    # another concurrent waiter.
    return await asyncio.shield(task)


def _forget_relay_start_task(
    room_id: str,
    task: asyncio.Task[tuple[int, int]],
) -> None:
    if _relay_start_tasks.get(room_id) is task:
        _relay_start_tasks.pop(room_id, None)
    # Retrieve an exception even when every HTTP waiter was cancelled, avoiding
    # an unhandled-task warning. Awaiters still receive the same exception.
    if not task.cancelled():
        task.exception()


async def _start_room_relay(room) -> tuple[int, int]:
    """Perform the one physical relay startup owned by an in-flight task."""
    port: int | None = None
    pid: int | None = None
    attached = False
    try:
        if room_mgr.get_room(room.id) is not room:
            raise HTTPException(status_code=404, detail="房间不存在")

        port, pid, reaped_ports = relay_launcher.start_new_relay(room.max_players)
        _close_rooms_for_reaped_relays(reaped_ports, {room.id})
        if port is None:
            raise HTTPException(status_code=503, detail="无可用 Relay 端口")
        if pid is None:
            raise HTTPException(status_code=500, detail="启动 Relay 失败")

        await asyncio.sleep(config.RELAY_STARTUP_GRACE_SECONDS)
        if not relay_launcher.is_relay_running(port):
            raise HTTPException(status_code=500, detail="Relay 启动后异常退出")

        # The host may destroy the room while startup is yielding.  Never leave
        # the newly-started child orphaned or attach it to a replaced room.
        if (
            room_mgr.get_room(room.id) is not room
            or not room_mgr.set_relay_info(room.id, port, pid)
        ):
            raise HTTPException(status_code=404, detail="房间已在 Relay 启动期间关闭")
        attached = True
        return port, pid
    except BaseException:
        # Failed STARTING rooms and WAITING rooms whose relay died are both
        # unusable. Close them before publishing the failed shared task so a
        # later request cannot race into a second startup.
        room_mgr.destroy_room(room.id, room.host_token)
        raise
    finally:
        if port is not None and pid is not None and not attached:
            relay_launcher.stop_relay(port)


def _close_rooms_for_reaped_relays(
    relay_ports: list[int],
    excluded_room_ids: set[str] | None = None,
) -> None:
    removed = room_mgr.close_rooms_for_relay_ports(
        relay_ports,
        excluded_room_ids,
    )
    for room in removed:
        print(
            f"[Cleanup] Relay 已退出，关闭房间: {room.id} "
            f"({room.name}, port={room.relay_port})"
        )


def _reconcile_exited_relays(
    excluded_room_ids: set[str] | None = None,
) -> list[int]:
    """回收已退出进程，并同步关闭仍引用它们的房间。"""
    reaped_ports = relay_launcher.reap_exited()
    _close_rooms_for_reaped_relays(reaped_ports, excluded_room_ids)
    return reaped_ports


# ─── API 端点 ────────────────────────────────────

@app.get("/health")
async def health_check() -> dict:
    _reconcile_exited_relays()
    return {
        "status": "ok",
        "public_ip": config.PUBLIC_IP,
        "active_relays": relay_launcher.get_active_count(),
    }


@app.get("/rooms")
async def list_rooms() -> list[dict]:
    """获取所有可加入的房间列表。"""
    _reconcile_exited_relays()
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
        game_mode=req.game_mode,
    )

    if room is None:
        raise HTTPException(status_code=503, detail="房间已满，无法创建更多房间")

    return await _ensure_room_relay(room)


@app.post("/rooms/{room_id}/join")
async def join_room(room_id: str, req: JoinRoomRequest) -> dict:
    """加入指定房间。"""
    _reconcile_exited_relays()
    room = room_mgr.join_room(room_id, req.player_name, req.game_mode)
    if room is None:
        raise HTTPException(
            status_code=404,
            detail="房间不存在、已满、模式不匹配或玩家名重复",
        )

    return room.to_join_dict(config.PUBLIC_IP, member_name=req.player_name)


@app.post("/rooms/{room_id}/host_ready")
async def host_ready(room_id: str, req: HostReadyRequest) -> dict:
    """房主已连接 Relay，登记真实 host peer id，并开放房间加入。"""
    room = room_mgr.mark_host_ready(room_id, req.host_token, req.host_peer_id)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效、房间不存在或 host peer id 无效")
    return room.to_join_dict(
        config.PUBLIC_IP,
        include_host_token=True,
        member_name=room.host_name,
    )


@app.post("/rooms/{room_id}/keepalive")
async def keep_room_alive(room_id: str, req: HostTokenRequest) -> dict:
    """房主续租房间，防止游戏中被空闲清理任务回收。"""
    room = room_mgr.keep_room_alive(room_id, req.host_token)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")

    relay_running = (
        room.relay_port > 0
        and relay_launcher.is_relay_running(room.relay_port)
    )
    return {
        "status": "ok",
        "relay_running": relay_running,
    }


@app.post("/rooms/{room_id}/leave")
async def leave_room(room_id: str, req: LeaveRoomRequest) -> dict:
    """离开指定房间。"""
    authorized, removed = room_mgr.leave_room(
        room_id,
        req.player_name,
        req.member_token,
    )
    if not authorized:
        raise HTTPException(status_code=403, detail="成员身份令牌无效或房间不存在")
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

    port, _pid = await _get_or_start_room_relay(room)

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
    _reconcile_exited_relays()
    room = room_mgr.find_match(req.game_mode)

    if room is None:
        # 没有可用房间，自动创建一个
        room = room_mgr.create_room(
            name=f"{req.player_name} 的房间",
            host_name=req.player_name,
            host_ip="",
            max_players=4,
            game_mode=req.game_mode,
        )
        if room is None:
            raise HTTPException(status_code=503, detail="无法创建房间")
        return await _ensure_room_relay(room)

    # 加入找到的房间
    joined = room_mgr.join_room(room.id, req.player_name, req.game_mode)
    if joined is None:
        raise HTTPException(status_code=409, detail="加入房间失败")

    return joined.to_join_dict(config.PUBLIC_IP, member_name=req.player_name)
