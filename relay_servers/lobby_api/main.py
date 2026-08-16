"""
ARC NICE 多人大厅 API (FastAPI)

启动方式:
    uvicorn lobby_api.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from . import config
from .models import GameMode, RoomStatus, is_release_game_mode
from .room_manager import (
    RelayRestartGrant,
    RelayStartGrant,
    RoomManager,
    RoomTerminationGrant,
)
from .relay_launcher import RelayLauncher, RelayProcessLease


# ─── 全局实例 ────────────────────────────────────
room_mgr = RoomManager()
relay_launcher = RelayLauncher()
_cleanup_task: Optional[asyncio.Task] = None
# 单 worker 的事件循环共享同一启动任务；多 worker 部署仍需外部协调器。
_relay_start_tasks: dict[str, asyncio.Task[tuple[int, int]]] = {}


# ─── 生命周期 ────────────────────────────────────

async def _periodic_cleanup() -> None:
    """定期清理空闲房间和死亡的 Relay 进程。"""
    while True:
        await asyncio.sleep(config.CLEANUP_INTERVAL_SECONDS)
        try:
            # 进程 wait/kill 只在受限线程池执行，不能阻塞 FastAPI 事件循环。
            await asyncio.to_thread(_cleanup_once)
        except Exception as exc:
            # 后台租约守护不能因单次基础设施异常永久退出。
            print(f"[Cleanup] 清理轮询异常，下一周期重试: {exc}")


def _cleanup_once() -> None:
    """执行一次 Relay/房间对账和空闲回收。"""
    try:
        _reconcile_exited_relays()
    except Exception as exc:
        print(f"[Cleanup] Relay 对账失败，本周期继续检查房间租约: {exc}")
    try:
        expired_rooms = room_mgr.cleanup_expired_rooms()
    except Exception as exc:
        print(f"[Cleanup] 房间租约扫描失败: {exc}")
        return
    _flush_room_termination_grants()
    for expired in expired_rooms:
        print(
            f"[Cleanup] 已清理过期房间: {expired.room.id} "
            f"({expired.room.name}, reason={expired.reason.value})"
        )


def _stop_termination_grant(grant: RoomTerminationGrant) -> bool:
    """提交不可变终止权；Launcher 在失败后持久负责后续重试。"""
    lease = RelayProcessLease(
        grant.relay_port,
        grant.relay_pid,
        grant.relay_instance_id,
    )
    stopped = relay_launcher.stop_relay(lease.port, lease.instance_id)
    # Room 已原子终结；若实例此时已在 quarantine，可立即确认释放端口。
    relay_launcher.acknowledge_reaped(lease)
    return stopped


def _flush_room_termination_grants() -> None:
    for grant in room_mgr.drain_termination_grants():
        try:
            _stop_termination_grant(grant)
        except Exception as exc:
            # Launcher 未确认接管时把终止权归还 Room 账本，下一轮继续提交。
            room_mgr.requeue_termination_grant(grant)
            print(
                f"[Cleanup] Relay 终止提交异常，终止权已归还待重试: "
                f"room={grant.room_id}, instance={grant.relay_instance_id}, "
                f"error={exc}"
            )


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _cleanup_task
    _cleanup_task = asyncio.create_task(_periodic_cleanup())
    print(f"[Lobby] 大厅 API 启动于 {config.LOBBY_HOST}:{config.LOBBY_PORT}")
    try:
        yield
    finally:
        if _cleanup_task:
            _cleanup_task.cancel()
            with suppress(asyncio.CancelledError):
                await _cleanup_task
        unterminated_leases = await asyncio.to_thread(relay_launcher.stop_all)
        if unterminated_leases:
            details = ", ".join(
                f"port={lease.port}/pid={lease.pid}/instance={lease.instance_id}"
                for lease in unterminated_leases
            )
            message = f"大厅退出时仍有 Relay 未能终止: {details}"
            print(f"[Lobby] 严重错误: {message}")
            raise RuntimeError(message)
        print("[Lobby] 大厅 API 已关闭，Relay 已全部终止")


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


def _require_release_game_mode(game_mode: GameMode) -> None:
    """拒绝只为协议兼容保留、尚未向正式大厅开放的模式。"""
    if not is_release_game_mode(game_mode):
        raise HTTPException(
            status_code=403,
            detail=f"游戏模式未向正式大厅开放: {game_mode.value}",
        )


async def _require_release_room(room_id: str) -> None:
    """读取历史房间时 fail-close，同时保留各端点原有的缺失/鉴权语义。"""
    room = room_mgr.get_room(room_id)
    # get_room 会顺带判定到期并签发终止权，必须在任何返回分支提交账本。
    await asyncio.to_thread(_flush_room_termination_grants)
    if room is not None:
        # 请求参数即使伪装成正式模式，也不能加入或推进隐藏历史房间。
        _require_release_game_mode(room.game_mode)


async def _ensure_room_relay(
    room_id: str,
    host_token: str,
    host_name: str,
) -> dict:
    """启动并挂接 Relay，再从 Room 锁内冻结创建响应。"""
    await _get_or_start_room_relay(room_id, host_token)
    response = room_mgr.get_join_dict(
        room_id,
        config.PUBLIC_IP,
        expected_host_token=host_token,
        include_host_token=True,
        member_name=host_name,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if response is None:
        raise HTTPException(status_code=404, detail="房间已过期或不存在")
    return response


async def _get_or_start_room_relay(
    room_id: str,
    host_token: str,
) -> tuple[int, int]:
    """同一房间的并发调用共享一项完整恢复/启动任务。"""
    # 必须先认证当前调用者，不能把合法房主的在途任务泄露给错误令牌。
    relay_ref = room_mgr.get_authorized_relay_ref(room_id, host_token)
    await asyncio.to_thread(_flush_room_termination_grants)
    if relay_ref is None:
        raise HTTPException(status_code=404, detail="房间不存在、已过期或令牌无效")
    if (
        relay_ref.instance_id > 0
        and await asyncio.to_thread(
            relay_launcher.is_relay_running,
            relay_ref.port,
            relay_ref.instance_id,
        )
    ):
        return relay_ref.port, relay_ref.pid

    task = _relay_start_tasks.get(room_id)
    if task is None:
        task = asyncio.create_task(_start_room_relay(room_id, host_token))
        _relay_start_tasks[room_id] = task
        task.add_done_callback(
            lambda done_task, room_id=room_id: _forget_relay_start_task(
                room_id,
                done_task,
            )
        )
    # 单个 HTTP 连接取消不能连带取消其他调用者共享的进程启动。
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


async def _start_room_relay(
    room_id: str,
    host_token: str,
) -> tuple[int, int]:
    """执行死亡绑定隔离、剩余时长签发、spawn 与 attach CAS。"""
    port: int | None = None
    lease: RelayProcessLease | None = None
    start_grant: RelayStartGrant | None = None
    restart_grant: RelayRestartGrant | None = None
    attached = False
    try:
        relay_ref = room_mgr.get_authorized_relay_ref(room_id, host_token)
        await asyncio.to_thread(_flush_room_termination_grants)
        if relay_ref is None:
            raise HTTPException(status_code=404, detail="房间不存在或已过期")

        if relay_ref.instance_id > 0:
            if await asyncio.to_thread(
                relay_launcher.is_relay_running,
                relay_ref.port,
                relay_ref.instance_id,
            ):
                return relay_ref.port, relay_ref.pid
            restart_grant = room_mgr.begin_relay_restart(
                room_id,
                host_token,
                relay_ref,
            )
            await asyncio.to_thread(_flush_room_termination_grants)
            if restart_grant is None:
                raise HTTPException(status_code=409, detail="Relay 重启状态已变化")

            await asyncio.to_thread(_reconcile_exited_relays)
            rebound_ref = room_mgr.get_authorized_relay_ref(room_id, host_token)
            await asyncio.to_thread(_flush_room_termination_grants)
            if rebound_ref is None:
                raise HTTPException(status_code=404, detail="Relay 退出后房间已终结")
            if rebound_ref.instance_id > 0:
                room_mgr.cancel_relay_restart(restart_grant)
                if await asyncio.to_thread(
                    relay_launcher.is_relay_running,
                    rebound_ref.port,
                    rebound_ref.instance_id,
                ):
                    return rebound_ref.port, rebound_ref.pid
                raise HTTPException(status_code=503, detail="Relay 状态暂不可确认")

        # 任何其他死亡实例都必须先完成 Room 对账并解除端口隔离。
        await asyncio.to_thread(_reconcile_exited_relays)
        start_grant = room_mgr.begin_relay_start(room_id, host_token)
        await asyncio.to_thread(_flush_room_termination_grants)
        if start_grant is None:
            raise HTTPException(status_code=409, detail="房间当前不能启动 Relay")

        while True:
            remaining_seconds = room_mgr.get_relay_start_remaining_seconds(
                start_grant
            )
            await asyncio.to_thread(_flush_room_termination_grants)
            if remaining_seconds is None or remaining_seconds <= 0:
                raise HTTPException(status_code=410, detail="房间绝对生命周期已到期")
            port, lease, reaped_leases = await asyncio.to_thread(
                relay_launcher.start_new_relay,
                start_grant.max_clients,
                remaining_seconds,
            )
            if reaped_leases:
                await asyncio.to_thread(
                    _apply_reaped_relay_leases,
                    reaped_leases,
                )
                continue
            if port is None:
                raise HTTPException(status_code=503, detail="无可用 Relay 端口")
            if lease is None:
                raise HTTPException(status_code=500, detail="启动 Relay 失败")
            break

        await asyncio.sleep(config.RELAY_STARTUP_GRACE_SECONDS)
        if not await asyncio.to_thread(
            relay_launcher.is_relay_running,
            port,
            lease.instance_id,
        ):
            raise HTTPException(status_code=500, detail="Relay 启动后异常退出")

        if not room_mgr.attach_relay(
            start_grant,
            port,
            lease.pid,
            lease.instance_id,
        ):
            await asyncio.to_thread(_flush_room_termination_grants)
            raise HTTPException(status_code=404, detail="房间已在 Relay 启动期间关闭")
        attached = True
        return port, lease.pid
    except BaseException:
        if start_grant is not None:
            room_mgr.fail_relay_start(start_grant)
            await asyncio.to_thread(_flush_room_termination_grants)
        elif restart_grant is not None:
            room_mgr.cancel_relay_restart(restart_grant)
        raise
    finally:
        if lease is not None and not attached:
            await asyncio.to_thread(_stop_unattached_relay, lease)


def _stop_unattached_relay(lease: RelayProcessLease) -> None:
    """未 attach 的实例没有 Room 所有者，停止成功后可直接解除隔离。"""
    relay_launcher.stop_relay(lease.port, lease.instance_id)
    relay_launcher.acknowledge_reaped(lease)


def _apply_reaped_relay_leases(
    relay_leases: list[RelayProcessLease],
) -> None:
    """先在 Room 域终结/清绑定，再逐一确认可复用端口。"""
    removed = room_mgr.reconcile_reaped_relays(
        [(lease.port, lease.instance_id) for lease in relay_leases],
    )
    _flush_room_termination_grants()
    for lease in relay_leases:
        relay_launcher.acknowledge_reaped(lease)
    for room in removed:
        print(
            f"[Cleanup] Relay 已退出，关闭房间: {room.id} "
            f"({room.name}, port={room.relay_port}, "
            f"instance={room.relay_instance_id})"
        )


def _reconcile_exited_relays(
) -> list[RelayProcessLease]:
    """回收已退出进程，并同步关闭仍引用它们的房间。"""
    reaped_leases = relay_launcher.reap_exited()
    if reaped_leases:
        _apply_reaped_relay_leases(reaped_leases)
    else:
        _flush_room_termination_grants()
    return reaped_leases


# ─── API 端点 ────────────────────────────────────

@app.get("/health")
async def health_check() -> dict:
    await asyncio.to_thread(_reconcile_exited_relays)
    return {
        "status": "ok",
        "public_ip": config.PUBLIC_IP,
        "active_relays": await asyncio.to_thread(
            relay_launcher.get_active_count,
        ),
    }


@app.get("/rooms")
async def list_rooms() -> list[dict]:
    """获取所有可加入的房间列表。"""
    await asyncio.to_thread(_reconcile_exited_relays)
    # 历史隐藏模式仍可由数据模型序列化，但生产发现面只发布正式清单。
    result = [
        room
        for room in room_mgr.list_joinable_rooms()
        if is_release_game_mode(GameMode(room["game_mode"]))
    ]
    await asyncio.to_thread(_flush_room_termination_grants)
    return result


@app.post("/rooms")
async def create_room(req: CreateRoomRequest) -> dict:
    """创建新房间。"""
    # 必须在创建 Room/Relay 之前准入，拒绝请求不能留下任何资源副作用。
    _require_release_game_mode(req.game_mode)
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

    return await _ensure_room_relay(room.id, room.host_token, room.host_name)


@app.post("/rooms/{room_id}/join")
async def join_room(room_id: str, req: JoinRoomRequest) -> dict:
    """加入指定房间。"""
    # 同时校验请求值和房间真实值：二者任一隐藏都不能借模式错配绕过。
    _require_release_game_mode(req.game_mode)
    await _require_release_room(room_id)
    await asyncio.to_thread(_reconcile_exited_relays)
    room = room_mgr.join_room(room_id, req.player_name, req.game_mode)
    await asyncio.to_thread(_flush_room_termination_grants)
    if room is None:
        raise HTTPException(
            status_code=404,
            detail="房间不存在、已满、模式不匹配或玩家名重复",
        )

    response = room_mgr.get_join_dict(
        room_id,
        config.PUBLIC_IP,
        member_name=req.player_name,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if response is None:
        raise HTTPException(status_code=404, detail="房间已在加入期间终结")
    return response


@app.post("/rooms/{room_id}/host_ready")
async def host_ready(room_id: str, req: HostReadyRequest) -> dict:
    """房主已连接 Relay，登记真实 host peer id，并开放房间加入。"""
    await _require_release_room(room_id)
    await asyncio.to_thread(_reconcile_exited_relays)
    room = room_mgr.mark_host_ready(room_id, req.host_token, req.host_peer_id)
    await asyncio.to_thread(_flush_room_termination_grants)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效、房间不存在或 host peer id 无效")
    response = room_mgr.get_join_dict(
        room_id,
        config.PUBLIC_IP,
        expected_host_token=req.host_token,
        include_host_token=True,
        member_name=room.host_name,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if response is None:
        raise HTTPException(status_code=404, detail="房间已在就绪期间终结")
    return response


@app.post("/rooms/{room_id}/keepalive")
async def keep_room_alive(room_id: str, req: HostTokenRequest) -> dict:
    """房主续租房间，防止游戏中被空闲清理任务回收。"""
    await _require_release_room(room_id)
    await asyncio.to_thread(_reconcile_exited_relays)
    relay_ref = room_mgr.get_authorized_relay_ref(room_id, req.host_token)
    await asyncio.to_thread(_flush_room_termination_grants)
    if relay_ref is None:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")

    # 先校验精确 Relay 世代仍活着，再以同一世代 CAS 推进 host heartbeat。
    relay_running = (
        relay_ref.port > 0
        and relay_ref.instance_id > 0
        and await asyncio.to_thread(
            relay_launcher.is_relay_running,
            relay_ref.port,
            relay_ref.instance_id,
        )
    )
    if not relay_running:
        raise HTTPException(status_code=503, detail="房间 Relay 已离线")

    room = room_mgr.keep_room_alive(
        room_id,
        req.host_token,
        relay_ref.port,
        relay_ref.instance_id,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if room is None:
        raise HTTPException(status_code=409, detail="房间租约已过期或 Relay 已变更")
    return {
        "status": "ok",
        "relay_running": True,
    }


@app.post("/rooms/{room_id}/leave")
async def leave_room(room_id: str, req: LeaveRoomRequest) -> dict:
    """离开指定房间。"""
    await asyncio.to_thread(_reconcile_exited_relays)
    authorized, removed = room_mgr.leave_room(
        room_id,
        req.player_name,
        req.member_token,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if not authorized:
        raise HTTPException(status_code=403, detail="成员身份令牌无效或房间不存在")
    return {"status": "ok"}


@app.patch("/rooms/{room_id}")
async def update_room(room_id: str, req: UpdateRoomRequest) -> dict:
    """更新房间状态。"""
    await _require_release_room(room_id)
    await asyncio.to_thread(_reconcile_exited_relays)
    try:
        status = RoomStatus(req.status)
    except ValueError:
        raise HTTPException(status_code=400, detail=f"无效状态: {req.status}")

    success = room_mgr.update_room_status(room_id, status, req.host_token)
    await asyncio.to_thread(_flush_room_termination_grants)
    if not success:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")
    return {"status": "ok"}


@app.post("/rooms/{room_id}/request_relay")
async def request_relay(room_id: str, req: HostTokenRequest) -> dict:
    """请求为指定房间启动 Relay 中继。"""
    await _require_release_room(room_id)
    port, _pid = await _get_or_start_room_relay(room_id, req.host_token)

    return {
        "relay_ip": config.PUBLIC_IP,
        "relay_port": port,
    }


@app.delete("/rooms/{room_id}")
async def destroy_room(room_id: str, req: HostTokenRequest) -> dict:
    """销毁指定房间及其 Relay。"""
    await asyncio.to_thread(_reconcile_exited_relays)
    room = room_mgr.destroy_room(room_id, req.host_token)
    await asyncio.to_thread(_flush_room_termination_grants)
    if room is None:
        raise HTTPException(status_code=403, detail="房主令牌无效或房间不存在")

    return {"status": "ok"}


@app.post("/matchmaking/quick")
async def quick_match(req: QuickMatchRequest) -> dict:
    """快速匹配：找一个最佳房间加入。"""
    # 必须先于房间扫描和自动创建；隐藏请求不会触发 Room/Relay 生命周期。
    _require_release_game_mode(req.game_mode)
    await asyncio.to_thread(_reconcile_exited_relays)
    room = room_mgr.find_match(req.game_mode)
    await asyncio.to_thread(_flush_room_termination_grants)

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
        return await _ensure_room_relay(room.id, room.host_token, room.host_name)

    # 加入找到的房间
    joined = room_mgr.join_room(room.id, req.player_name, req.game_mode)
    await asyncio.to_thread(_flush_room_termination_grants)
    if joined is None:
        raise HTTPException(status_code=409, detail="加入房间失败")

    response = room_mgr.get_join_dict(
        room.id,
        config.PUBLIC_IP,
        member_name=req.player_name,
    )
    await asyncio.to_thread(_flush_room_termination_grants)
    if response is None:
        raise HTTPException(status_code=409, detail="房间已在匹配期间终结")
    return response
