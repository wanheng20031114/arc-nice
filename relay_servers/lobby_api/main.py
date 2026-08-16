"""
ARC NICE 多人大厅 API (FastAPI)

启动方式:
    uvicorn lobby_api.main:app --host 0.0.0.0 --port 8000 --workers 1 --no-proxy-headers
"""

from __future__ import annotations

import asyncio
import math
from contextlib import asynccontextmanager, suppress
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import config
from .acquisition_security import (
    AcquisitionCapabilityClaims,
    AcquisitionCapabilityError,
    AcquisitionCapabilityExpiredError,
    AcquisitionCapabilitySigner,
    DualTokenBucketRateLimiter,
    fingerprint_canonical_payload,
)
from .models import GameMode, RoomStatus, is_release_game_mode
from .room_manager import (
    AcquisitionAction,
    AcquisitionCancelledError,
    AcquisitionCapacityError,
    AcquisitionClaim,
    AcquisitionClaimState,
    AcquisitionConflictError,
    RelayRestartGrant,
    RelayStartGrant,
    RoomManager,
    RoomTerminationGrant,
)
from .relay_launcher import RelayLauncher, RelayProcessLease


# ─── 全局实例 ────────────────────────────────────
room_mgr = RoomManager()
relay_launcher = RelayLauncher()
acquisition_capability_signer = AcquisitionCapabilitySigner(
    config.ACQUISITION_CAPABILITY_HMAC_SECRET,
    config.ACQUISITION_CAPABILITY_TTL_SECONDS,
)
# 这是进程内边界，必须用单 worker 运行；多 worker 需要共享限流/租约后端。
acquisition_admission_limiter = DualTokenBucketRateLimiter(
    global_burst=config.ACQUISITION_ADMISSION_GLOBAL_BURST,
    global_refill_per_second=(
        config.ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND
    ),
    source_burst=config.ACQUISITION_ADMISSION_SOURCE_BURST,
    source_refill_per_second=(
        config.ACQUISITION_ADMISSION_SOURCE_REFILL_PER_SECOND
    ),
    source_bucket_capacity=(
        config.ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY
    ),
    source_idle_ttl_seconds=(
        config.ACQUISITION_ADMISSION_SOURCE_IDLE_TTL_SECONDS
    ),
)
_cleanup_task: Optional[asyncio.Task] = None
# 单 worker 的事件循环共享同一启动任务；多 worker 部署仍需外部协调器。
_relay_start_tasks: dict[str, asyncio.Task[tuple[int, int]]] = {}
# acquisition task 由服务进程持有；单个断开的 HTTP waiter 不能取消 Relay CAS。
_acquisition_tasks: dict[str, asyncio.Task[dict]] = {}


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


async def _cancel_inflight_shared_tasks() -> None:
    """停服先收束脱离 HTTP waiter 的共享任务，再让 Launcher 终止进程。"""
    tasks = set(_acquisition_tasks.values()) | set(_relay_start_tasks.values())
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    _acquisition_tasks.clear()
    _relay_start_tasks.clear()


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
        await _cancel_inflight_shared_tasks()
        await asyncio.to_thread(_flush_room_termination_grants)
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

class _StrictPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateAcquisitionPayload(_StrictPayload):
    name: str = Field(default="", max_length=64)
    host_name: str = Field(min_length=1, max_length=32)
    max_players: int = Field(default=4, ge=2, le=8)
    game_mode: GameMode = GameMode.STANDARD


class CreateRoomRequest(CreateAcquisitionPayload):
    acquisition_token: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=256,
        repr=False,
    )


class JoinAcquisitionPayload(_StrictPayload):
    room_id: str = Field(min_length=1, max_length=64)
    player_name: str = Field(min_length=1, max_length=32)
    game_mode: GameMode = GameMode.STANDARD


class JoinRoomRequest(_StrictPayload):
    player_name: str = Field(min_length=1, max_length=32)
    game_mode: GameMode = GameMode.STANDARD
    acquisition_token: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=256,
        repr=False,
    )


class LeaveRoomRequest(BaseModel):
    player_name: str = Field(min_length=1, max_length=32)
    member_token: str = Field(min_length=1, max_length=128, repr=False)


class UpdateRoomRequest(BaseModel):
    status: str = Field(min_length=1, max_length=32)
    host_token: str = Field(min_length=1, max_length=128, repr=False)


class HostTokenRequest(BaseModel):
    host_token: str = Field(min_length=1, max_length=128, repr=False)


class HostReadyRequest(BaseModel):
    host_token: str = Field(min_length=1, max_length=128, repr=False)
    host_peer_id: int = Field(ge=1)


class QuickMatchAcquisitionPayload(_StrictPayload):
    player_name: str = Field(min_length=1, max_length=32)
    game_mode: GameMode = GameMode.STANDARD


class QuickMatchRequest(QuickMatchAcquisitionPayload):
    acquisition_token: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=256,
        repr=False,
    )


class AcquisitionTokenRequest(BaseModel):
    acquisition_token: str = Field(
        min_length=1,
        max_length=256,
        repr=False,
    )


class AcquisitionPreflightRequest(_StrictPayload):
    action: str = Field(min_length=1, max_length=32)
    payload: dict[str, object]


class ConfirmMemberAcquisitionRequest(_StrictPayload):
    room_id: str = Field(min_length=1, max_length=64)
    player_name: str = Field(min_length=1, max_length=32)
    member_token: str = Field(min_length=1, max_length=128, repr=False)


def _canonical_create(req: CreateAcquisitionPayload) -> tuple[str, ...]:
    room_name = req.name if req.name else f"{req.host_name} 的房间"
    return (
        room_name,
        req.host_name,
        str(req.max_players),
        req.game_mode.value,
    )


def _canonical_join(
    room_id: str,
    player_name: str,
    game_mode: GameMode,
) -> tuple[str, ...]:
    return (room_id, player_name, game_mode.value)


def _canonical_quick(req: QuickMatchAcquisitionPayload) -> tuple[str, ...]:
    return (req.player_name, req.game_mode.value)


def _consume_acquisition_admission(request: Request) -> None:
    """只采用直连 socket 来源；公网请求头不能扩大来源桶。"""
    source = request.client.host if request.client is not None else "<unknown>"
    decision = acquisition_admission_limiter.consume(source)
    if decision.allowed:
        return
    retry_after = max(1, math.ceil(decision.retry_after_seconds))
    raise HTTPException(
        status_code=429,
        detail="acquisition 请求过于频繁，请稍后重试",
        headers={"Retry-After": str(retry_after)},
    )


def _require_command_capability(
    request: Request,
    token: Optional[str],
    action: AcquisitionAction,
    canonical_payload: tuple[str, ...],
) -> Optional[AcquisitionCapabilityClaims]:
    """验证新 capability；显式 legacy 模式仍经过同一准入限流。"""
    if token is None:
        if not config.ALLOW_LEGACY_ACQUISITION_REQUESTS:
            raise HTTPException(
                status_code=428,
                detail="此服务要求先调用 acquisition preflight",
            )
        _consume_acquisition_admission(request)
        return None
    return _verify_command_capability(token, action, canonical_payload)


def _verify_command_capability(
    token: str,
    action: AcquisitionAction,
    canonical_payload: tuple[str, ...],
) -> AcquisitionCapabilityClaims:
    """验签并冻结 expiry；endpoint 会在最后一个 await 后再次调用。"""
    try:
        claims = acquisition_capability_signer.verify(token)
    except AcquisitionCapabilityExpiredError as exc:
        raise HTTPException(
            status_code=410,
            detail="acquisition capability 已过期，请重新 preflight",
        ) from exc
    except AcquisitionCapabilityError as exc:
        raise HTTPException(
            status_code=401,
            detail="acquisition capability 无效",
        ) from exc
    expected_fingerprint = fingerprint_canonical_payload(
        action.value,
        canonical_payload,
    )
    if (
        claims.action != action.value
        or claims.payload_fingerprint != expected_fingerprint
    ):
        raise HTTPException(
            status_code=409,
            detail="acquisition capability 与动作或参数不匹配",
        )
    return claims


def _parse_preflight_payload(
    action: AcquisitionAction,
    payload: dict[str, object],
) -> tuple[tuple[str, ...], GameMode]:
    try:
        if action == AcquisitionAction.CREATE:
            parsed = CreateAcquisitionPayload.model_validate(payload)
            return _canonical_create(parsed), parsed.game_mode
        if action == AcquisitionAction.JOIN:
            parsed = JoinAcquisitionPayload.model_validate(payload)
            return (
                _canonical_join(
                    parsed.room_id,
                    parsed.player_name,
                    parsed.game_mode,
                ),
                parsed.game_mode,
            )
        parsed = QuickMatchAcquisitionPayload.model_validate(payload)
        return _canonical_quick(parsed), parsed.game_mode
    except ValidationError as exc:
        # payload 不含秘密；仍避免把 Pydantic 的原始 input 镜像回公网响应。
        raise HTTPException(
            status_code=422,
            detail="acquisition preflight payload 无效",
        ) from exc


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


def _raise_acquisition_http_error(exc: Exception) -> None:
    if isinstance(exc, AcquisitionConflictError):
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if isinstance(exc, AcquisitionCancelledError):
        raise HTTPException(status_code=410, detail=str(exc)) from exc
    if isinstance(exc, AcquisitionCapacityError):
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    raise exc


async def _complete_host_acquisition(claim: AcquisitionClaim) -> dict:
    """Relay 启动与响应冻结属于同一 acquisition；失败必须精确回滚。"""
    try:
        await _get_or_start_room_relay(claim.room_id, claim.host_token)
        return room_mgr.freeze_acquisition_response(
            claim.token,
            claim.canonical_payload,
            config.PUBLIC_IP,
        )
    except BaseException:
        try:
            room_mgr.release_acquisition(
                claim.token,
                capability_expires_at=claim.capability_expires_at,
            )
            await asyncio.to_thread(_flush_room_termination_grants)
        except AcquisitionCapacityError:
            # 活动 acquisition 已预留墓碑槽；若此处失败说明内部不变量已破坏。
            print("[Lobby] 严重错误: acquisition 回滚无法写取消墓碑")
        raise


def _forget_acquisition_task(
    token: str,
    task: asyncio.Task[dict],
) -> None:
    if _acquisition_tasks.get(token) is task:
        _acquisition_tasks.pop(token, None)
    if not task.cancelled():
        task.exception()


async def _resolve_acquisition_claim(claim: AcquisitionClaim) -> dict:
    try:
        if claim.state == AcquisitionClaimState.FROZEN:
            return dict(claim.frozen_response or {})
        if not claim.is_host:
            return room_mgr.freeze_acquisition_response(
                claim.token,
                claim.canonical_payload,
                config.PUBLIC_IP,
            )
        task = _acquisition_tasks.get(claim.token)
        if task is None:
            task = asyncio.create_task(_complete_host_acquisition(claim))
            _acquisition_tasks[claim.token] = task
            task.add_done_callback(
                lambda done_task, token=claim.token: _forget_acquisition_task(
                    token,
                    done_task,
                )
            )
        return await asyncio.shield(task)
    except (
        AcquisitionConflictError,
        AcquisitionCancelledError,
        AcquisitionCapacityError,
    ) as exc:
        _raise_acquisition_http_error(exc)
        raise AssertionError("unreachable")


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


@app.post("/acquisitions/preflight")
async def preflight_acquisition(
    request: Request,
    req: AcquisitionPreflightRequest,
) -> dict:
    """签发短期、参数绑定的能力；本端点绝不创建 Room 或占用 Relay。"""
    _consume_acquisition_admission(request)
    try:
        action = AcquisitionAction(req.action)
    except ValueError as exc:
        raise HTTPException(
            status_code=422,
            detail="未知 acquisition action",
        ) from exc
    canonical_payload, game_mode = _parse_preflight_payload(action, req.payload)
    _require_release_game_mode(game_mode)
    issued = acquisition_capability_signer.issue(
        action.value,
        canonical_payload,
    )
    return {
        "acquisition_token": issued.token,
        "expires_at": issued.expires_at,
    }


@app.post("/rooms")
async def create_room(
    req: CreateRoomRequest,
    request: Request,
) -> dict:
    """创建新房间。"""
    # 必须在创建 Room/Relay 之前准入，拒绝请求不能留下任何资源副作用。
    _require_release_game_mode(req.game_mode)
    canonical_payload = _canonical_create(req)
    room_name = canonical_payload[0]
    capability_claims = _require_command_capability(
        request,
        req.acquisition_token,
        AcquisitionAction.CREATE,
        canonical_payload,
    )

    if capability_claims is not None:
        # 即使当前路径没有 await，也统一在同锁 begin 紧前重验并把签名截止交给 CAS。
        capability_claims = _verify_command_capability(
            req.acquisition_token or "",
            AcquisitionAction.CREATE,
            canonical_payload,
        )
        try:
            claim = room_mgr.begin_create_acquisition(
                req.acquisition_token or "",
                canonical_payload,
                room_name,
                req.host_name,
                "",
                req.max_players,
                req.game_mode,
                capability_expires_at=capability_claims.expires_at,
            )
        except (
            AcquisitionConflictError,
            AcquisitionCancelledError,
            AcquisitionCapacityError,
        ) as exc:
            _raise_acquisition_http_error(exc)
            raise AssertionError("unreachable")
        if claim is None:
            raise HTTPException(status_code=503, detail="房间已满，无法创建更多房间")
        return await _resolve_acquisition_claim(claim)

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
async def join_room(
    room_id: str,
    req: JoinRoomRequest,
    request: Request,
) -> dict:
    """加入指定房间。"""
    # 同时校验请求值和房间真实值：二者任一隐藏都不能借模式错配绕过。
    _require_release_game_mode(req.game_mode)
    canonical_payload = _canonical_join(
        room_id,
        req.player_name,
        req.game_mode,
    )
    capability_claims = _require_command_capability(
        request,
        req.acquisition_token,
        AcquisitionAction.JOIN,
        canonical_payload,
    )
    await _require_release_room(room_id)
    await asyncio.to_thread(_reconcile_exited_relays)

    if capability_claims is not None:
        # 房间/Relay 对账会 await；其后必须重新验签，过期 capability 不得进入同锁 begin。
        capability_claims = _verify_command_capability(
            req.acquisition_token or "",
            AcquisitionAction.JOIN,
            canonical_payload,
        )
        try:
            claim = room_mgr.begin_join_acquisition(
                req.acquisition_token or "",
                canonical_payload,
                room_id,
                req.player_name,
                req.game_mode,
                capability_expires_at=capability_claims.expires_at,
            )
        except (
            AcquisitionConflictError,
            AcquisitionCancelledError,
            AcquisitionCapacityError,
        ) as exc:
            _raise_acquisition_http_error(exc)
            raise AssertionError("unreachable")
        await asyncio.to_thread(_flush_room_termination_grants)
        if claim is None:
            raise HTTPException(
                status_code=404,
                detail="房间不存在、已满、模式不匹配或玩家名重复",
            )
        return await _resolve_acquisition_claim(claim)

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


@app.post("/acquisitions/confirm")
async def confirm_acquisition(req: ConfirmMemberAcquisitionRequest) -> dict:
    """成员连通 Relay 后，以独立成员秘密确认临时占位。"""
    if not room_mgr.confirm_member_acquisition(
        req.room_id,
        req.player_name,
        req.member_token,
    ):
        await asyncio.to_thread(_flush_room_termination_grants)
        raise HTTPException(status_code=410, detail="acquisition 已取消、过期或不存在")
    await asyncio.to_thread(_flush_room_termination_grants)
    return {
        "status": "ok",
        "room_id": req.room_id,
        "player_name": req.player_name,
    }


@app.post("/acquisitions/release")
async def release_acquisition(req: AcquisitionTokenRequest) -> dict:
    """验证全局取消能力；随机或过旧输入幂等忽略且不写墓碑。"""
    try:
        capability_claims = acquisition_capability_signer.verify(
            req.acquisition_token,
            expiry_grace_seconds=(
                config.ACQUISITION_TOMBSTONE_TTL_SECONDS
            ),
        )
    except AcquisitionCapabilityError:
        return {"status": "ok", "result": "ignored"}
    try:
        result = room_mgr.release_acquisition(
            req.acquisition_token,
            capability_expires_at=capability_claims.expires_at,
        )
    except AcquisitionCapacityError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    await asyncio.to_thread(_flush_room_termination_grants)
    return {"status": "ok", "result": result.value}


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
async def quick_match(
    req: QuickMatchRequest,
    request: Request,
) -> dict:
    """快速匹配：找一个最佳房间加入。"""
    # 必须先于房间扫描和自动创建；隐藏请求不会触发 Room/Relay 生命周期。
    _require_release_game_mode(req.game_mode)
    canonical_payload = _canonical_quick(req)
    capability_claims = _require_command_capability(
        request,
        req.acquisition_token,
        AcquisitionAction.QUICK_MATCH,
        canonical_payload,
    )
    await asyncio.to_thread(_reconcile_exited_relays)

    if capability_claims is not None:
        # Relay 对账之后紧邻 begin 再验一次；RoomManager 同锁还会复核该 expiry。
        capability_claims = _verify_command_capability(
            req.acquisition_token or "",
            AcquisitionAction.QUICK_MATCH,
            canonical_payload,
        )
        try:
            claim = room_mgr.begin_quick_match_acquisition(
                req.acquisition_token or "",
                canonical_payload,
                req.player_name,
                req.game_mode,
                capability_expires_at=capability_claims.expires_at,
            )
        except (
            AcquisitionConflictError,
            AcquisitionCancelledError,
            AcquisitionCapacityError,
        ) as exc:
            _raise_acquisition_http_error(exc)
            raise AssertionError("unreachable")
        await asyncio.to_thread(_flush_room_termination_grants)
        if claim is None:
            raise HTTPException(status_code=503, detail="无法创建或加入房间")
        return await _resolve_acquisition_claim(claim)

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
