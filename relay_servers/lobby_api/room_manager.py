"""
房间生命周期管理。
"""

from __future__ import annotations

import math
import secrets
import time
import threading
from copy import deepcopy
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional

from .models import GameMode, RoomInfo, RoomStatus, PlayerInfo
from .relay_admission import (
    MAX_TICKET_REFRESH_BURST,
    MAX_TICKET_REFRESH_WINDOW_SECONDS,
    MAX_TICKET_TTL_SECONDS,
    MIN_TICKET_REFRESH_BURST,
    MIN_TICKET_REFRESH_WINDOW_SECONDS,
    ROLE_HOST,
    ROLE_MEMBER,
    RelayAdmissionTicketSigner,
)
from . import config


class RoomExpirationReason(str, Enum):
    """房间被服务端回收的可观察原因。"""

    IDLE_LEASE_EXPIRED = "idle_lease_expired"
    ABSOLUTE_LIFETIME_EXPIRED = "absolute_lifetime_expired"
    EXPLICITLY_CLOSED = "explicitly_closed"
    RELAY_EXITED = "relay_exited"
    RELAY_START_FAILED = "relay_start_failed"
    ACQUISITION_UNCONFIRMED = "acquisition_unconfirmed"


class AcquisitionAction(str, Enum):
    """一个随机令牌只能绑定一种带规范参数的成员获取命令。"""

    CREATE = "create"
    JOIN = "join"
    QUICK_MATCH = "quick_match"


class AcquisitionClaimState(str, Enum):
    NEW = "new"
    PENDING = "pending"
    FROZEN = "frozen"


class AcquisitionConflictError(RuntimeError):
    """同一秘密令牌被复用于不同命令或参数。"""


class AcquisitionCancelledError(RuntimeError):
    """该令牌已经取消；迟到命令不得重新提交。"""


class AcquisitionCapacityError(RuntimeError):
    """安全索引没有空间时 fail-close。"""


class RelayAdmissionRefreshRateLimitError(RuntimeError):
    """一个已验证成员在短窗口内换取了过多 Relay admission ticket。"""

    def __init__(self, retry_after_seconds: float) -> None:
        self.retry_after_seconds = max(float(retry_after_seconds), 0.001)
        super().__init__("Relay admission ticket 刷新过于频繁")


@dataclass
class _AcquisitionRecord:
    token: str = field(repr=False)
    member_token: str = field(repr=False)
    action: AcquisitionAction
    canonical_payload: tuple[str, ...]
    room_id: str
    player_name: str
    is_host: bool
    capability_expires_at: float
    provisional_deadline: Optional[float]
    frozen_response: Optional[dict] = field(default=None, repr=False)


@dataclass
class _AcquisitionTombstone:
    """取消记录同时受单调保留期和签名可提交窗口保护。"""

    retention_deadline: float
    capability_expires_at: float


@dataclass(frozen=True)
class AcquisitionClaim:
    token: str = field(repr=False)
    action: AcquisitionAction
    canonical_payload: tuple[str, ...]
    room_id: str
    player_name: str
    is_host: bool
    capability_expires_at: float
    host_token: str = field(repr=False)
    state: AcquisitionClaimState
    frozen_response: Optional[dict] = field(default=None, repr=False)


class AcquisitionReleaseResult(str, Enum):
    RELEASED = "released"
    ALREADY_RELEASED = "already_released"
    TOMBSTONED_UNKNOWN = "tombstoned_unknown"


@dataclass(frozen=True)
class ExpiredRoom:
    room: RoomInfo
    reason: RoomExpirationReason


@dataclass(frozen=True)
class AuthorizedRelayRef:
    """令牌校验时冻结的房间 Relay 引用，供存活检查与续租 CAS 复用。"""

    port: int
    pid: int
    instance_id: int


@dataclass(frozen=True)
class RoomTerminationGrant:
    """Room 已终结后交给 Launcher 的不可变 Relay 终止权。"""

    room_id: str
    room_name: str
    relay_port: int
    relay_pid: int
    relay_instance_id: int
    reason: RoomExpirationReason


@dataclass(frozen=True)
class RelayStartGrant:
    """一次 Relay 启动的房间 CAS 与剩余绝对生命周期。"""

    room_id: str
    attempt_id: int
    max_clients: int
    max_lifetime_seconds: float
    admission_secret: str = field(repr=False)


@dataclass(frozen=True)
class RelayRestartGrant:
    """把一个已绑定房间切换到受控重启状态所需的回滚信息。"""

    room_id: str
    relay_ref: AuthorizedRelayRef
    previous_status: RoomStatus
    previous_host_peer_id: int
    previous_admission_secret: str = field(repr=False)


class RoomManager:
    """线程安全的房间管理器。"""

    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
        capability_clock: Callable[[], float] = time.time,
        room_idle_timeout_seconds: float = config.ROOM_IDLE_TIMEOUT_SECONDS,
        game_max_duration_seconds: float = config.GAME_MAX_DURATION_SECONDS,
        relay_admission_ticket_ttl_seconds: float = (
            config.RELAY_ADMISSION_TICKET_TTL_SECONDS
        ),
        relay_admission_refresh_burst: int = (
            config.RELAY_ADMISSION_REFRESH_BURST
        ),
        relay_admission_refresh_window_seconds: float = (
            config.RELAY_ADMISSION_REFRESH_WINDOW_SECONDS
        ),
        acquisition_provisional_timeout_seconds: float = (
            config.ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS
        ),
        acquisition_tombstone_ttl_seconds: float = (
            config.ACQUISITION_TOMBSTONE_TTL_SECONDS
        ),
        acquisition_token_capacity: int = config.ACQUISITION_TOKEN_CAPACITY,
    ) -> None:
        if room_idle_timeout_seconds <= 0:
            raise ValueError("room_idle_timeout_seconds 必须大于 0")
        if game_max_duration_seconds <= 0:
            raise ValueError("game_max_duration_seconds 必须大于 0")
        if (
            not math.isfinite(relay_admission_ticket_ttl_seconds)
            or relay_admission_ticket_ttl_seconds <= 0
            or relay_admission_ticket_ttl_seconds > MAX_TICKET_TTL_SECONDS
        ):
            raise ValueError("relay admission ticket TTL 必须在 0..120 秒内")
        if (
            isinstance(relay_admission_refresh_burst, bool)
            or not isinstance(relay_admission_refresh_burst, int)
            or relay_admission_refresh_burst < MIN_TICKET_REFRESH_BURST
            or relay_admission_refresh_burst > MAX_TICKET_REFRESH_BURST
        ):
            raise ValueError("relay admission refresh burst 必须是 2..3 的整数")
        if (
            not math.isfinite(relay_admission_refresh_window_seconds)
            or (
                relay_admission_refresh_window_seconds
                < MIN_TICKET_REFRESH_WINDOW_SECONDS
            )
            or (
                relay_admission_refresh_window_seconds
                > MAX_TICKET_REFRESH_WINDOW_SECONDS
            )
        ):
            raise ValueError("relay admission refresh window 必须在 5..60 秒内")
        if acquisition_provisional_timeout_seconds <= 0:
            raise ValueError("acquisition_provisional_timeout_seconds 必须大于 0")
        if (
            acquisition_tombstone_ttl_seconds
            <= acquisition_provisional_timeout_seconds
        ):
            raise ValueError("acquisition tombstone TTL 必须长于 provisional timeout")
        if acquisition_token_capacity <= 0:
            raise ValueError("acquisition_token_capacity 必须大于 0")
        self._rooms: dict[str, RoomInfo] = {}
        self._lock = threading.Lock()
        self._clock = clock
        self._admission_ticket_signer = RelayAdmissionTicketSigner(wall_clock)
        self._capability_clock = capability_clock
        self._room_idle_timeout_seconds = room_idle_timeout_seconds
        self._game_max_duration_seconds = game_max_duration_seconds
        self._relay_admission_ticket_ttl_seconds = (
            relay_admission_ticket_ttl_seconds
        )
        self._relay_admission_refresh_burst = relay_admission_refresh_burst
        self._relay_admission_refresh_window_seconds = (
            relay_admission_refresh_window_seconds
        )
        self._relay_admission_refresh_attempts: dict[
            tuple[str, str], list[float]
        ] = {}
        self._acquisition_provisional_timeout_seconds = (
            acquisition_provisional_timeout_seconds
        )
        self._acquisition_tombstone_ttl_seconds = acquisition_tombstone_ttl_seconds
        self._acquisition_token_capacity = acquisition_token_capacity
        self._acquisitions: dict[str, _AcquisitionRecord] = {}
        self._member_acquisition_tokens: dict[str, str] = {}
        self._acquisition_tombstones: dict[str, _AcquisitionTombstone] = {}
        self._acquisition_saturation_deadline = 0.0
        self._acquisition_saturation_capability_deadline = 0.0
        self._pending_terminations: dict[tuple[int, int], RoomTerminationGrant] = {}
        self._relay_start_attempts: dict[str, int] = {}
        self._next_relay_start_attempt_id = 1

    def _prune_acquisition_tombstones_locked(self, now: float) -> None:
        capability_now = self._checked_capability_now_locked()
        for token, tombstone in list(self._acquisition_tombstones.items()):
            # 单调 TTL 已过仍不能忘记一个当前可提交的签名，否则取消后的迟到请求会复活。
            if (
                now >= tombstone.retention_deadline
                and capability_now >= tombstone.capability_expires_at
            ):
                self._acquisition_tombstones.pop(token, None)

    def _checked_capability_now_locked(self) -> float:
        now = self._capability_clock()
        if not math.isfinite(now) or now < 0:
            raise RuntimeError("capability clock 必须返回有限非负数")
        return now

    @staticmethod
    def _checked_capability_deadline(capability_expires_at: float) -> float:
        deadline = float(capability_expires_at)
        if not math.isfinite(deadline) or deadline <= 0:
            raise ValueError("capability expiry 必须是有限正数")
        return deadline

    def _require_live_capability_deadline_locked(
        self,
        capability_expires_at: float,
    ) -> float:
        deadline = self._checked_capability_deadline(capability_expires_at)
        if self._checked_capability_now_locked() >= deadline:
            raise AcquisitionCancelledError("acquisition capability 已过期")
        return deadline

    def _reserve_acquisition_token_locked(self, now: float) -> None:
        """活动项预留未来墓碑槽；容量耗尽时不能接受不受保护的新令牌。"""
        self._prune_acquisition_tombstones_locked(now)
        capability_now = self._checked_capability_now_locked()
        if (
            now < self._acquisition_saturation_deadline
            or capability_now < self._acquisition_saturation_capability_deadline
        ):
            raise AcquisitionCapacityError("acquisition 取消索引仍处于饱和隔离期")
        if (
            len(self._acquisitions) + len(self._acquisition_tombstones)
            >= self._acquisition_token_capacity
        ):
            raise AcquisitionCapacityError("acquisition 安全索引已满")

    def _write_acquisition_tombstone_locked(
        self,
        token: str,
        now: float,
        capability_expires_at: float,
    ) -> None:
        capability_deadline = self._checked_capability_deadline(
            capability_expires_at
        )
        self._prune_acquisition_tombstones_locked(now)
        existing = self._acquisition_tombstones.get(token)
        if existing is not None:
            existing.retention_deadline = max(
                existing.retention_deadline,
                now + self._acquisition_tombstone_ttl_seconds,
            )
            existing.capability_expires_at = max(
                existing.capability_expires_at,
                capability_deadline,
            )
            return
        # 每个活动项都在进入索引前预留了这一槽；未知 token 则先显式检查。
        if (
            len(self._acquisitions) + len(self._acquisition_tombstones)
            >= self._acquisition_token_capacity
        ):
            raise AcquisitionCapacityError("acquisition 取消墓碑已满")
        self._acquisition_tombstones[token] = _AcquisitionTombstone(
            retention_deadline=now + self._acquisition_tombstone_ttl_seconds,
            capability_expires_at=capability_deadline,
        )

    def _retire_acquisition_locked(self, token: str, now: float) -> None:
        record = self._acquisitions.pop(token, None)
        if record is None:
            tombstone = self._acquisition_tombstones.get(token)
            if tombstone is None:
                return
            self._write_acquisition_tombstone_locked(
                token,
                now,
                tombstone.capability_expires_at,
            )
            return
        if (
            record is not None
            and self._member_acquisition_tokens.get(record.member_token) == token
        ):
            self._member_acquisition_tokens.pop(record.member_token, None)
        self._write_acquisition_tombstone_locked(
            token,
            now,
            record.capability_expires_at,
        )

    def _retire_room_acquisitions_locked(self, room_id: str, now: float) -> None:
        tokens = [
            token
            for token, record in self._acquisitions.items()
            if record.room_id == room_id
        ]
        for token in tokens:
            self._retire_acquisition_locked(token, now)

    def _expire_provisional_acquisitions_locked(self, now: float) -> None:
        self._prune_acquisition_tombstones_locked(now)
        expired_tokens = [
            token
            for token, record in self._acquisitions.items()
            if (
                record.provisional_deadline is not None
                and now >= record.provisional_deadline
            )
        ]
        for token in expired_tokens:
            record = self._acquisitions.get(token)
            if record is None:
                continue
            room = self._rooms.get(record.room_id)
            if room is not None and record.is_host:
                self._remove_room_locked(
                    room,
                    RoomExpirationReason.ACQUISITION_UNCONFIRMED,
                    now=now,
                )
                continue
            if room is not None:
                member = room.players.get(record.player_name)
                if member is not None and secrets.compare_digest(
                    member.member_token,
                    record.member_token,
                ):
                    room.players.pop(record.player_name, None)
            self._retire_acquisition_locked(token, now)

    def _get_existing_acquisition_claim_locked(
        self,
        token: str,
        action: AcquisitionAction,
        canonical_payload: tuple[str, ...],
        capability_expires_at: float,
        now: float,
    ) -> Optional[AcquisitionClaim]:
        self._expire_provisional_acquisitions_locked(now)
        if token in self._acquisition_tombstones:
            raise AcquisitionCancelledError("acquisition 已取消")
        record = self._acquisitions.get(token)
        if record is None:
            return None
        if (
            record.action != action
            or record.canonical_payload != canonical_payload
            or record.capability_expires_at != capability_expires_at
        ):
            raise AcquisitionConflictError("同一 acquisition token 的命令或参数不一致")
        room = self._get_live_room_locked(record.room_id, now)
        if room is None:
            self._retire_acquisition_locked(token, now)
            raise AcquisitionCancelledError("acquisition 所属房间已终结")
        state = (
            AcquisitionClaimState.FROZEN
            if record.frozen_response is not None
            else AcquisitionClaimState.PENDING
        )
        return AcquisitionClaim(
            token=record.token,
            action=record.action,
            canonical_payload=record.canonical_payload,
            room_id=record.room_id,
            player_name=record.player_name,
            is_host=record.is_host,
            capability_expires_at=record.capability_expires_at,
            host_token=room.host_token if record.is_host else "",
            state=state,
            frozen_response=(
                deepcopy(record.frozen_response)
                if record.frozen_response is not None
                else None
            ),
        )

    def _register_acquisition_locked(
        self,
        token: str,
        action: AcquisitionAction,
        canonical_payload: tuple[str, ...],
        room: RoomInfo,
        player_name: str,
        is_host: bool,
        capability_expires_at: float,
        now: float,
    ) -> AcquisitionClaim:
        self._reserve_acquisition_token_locked(now)
        member = room.players.get(player_name)
        if member is None:
            raise RuntimeError("acquisition 成员占位不存在")
        while member.member_token in self._member_acquisition_tokens:
            member.member_token = secrets.token_urlsafe(24)
        self._acquisitions[token] = _AcquisitionRecord(
            token=token,
            member_token=member.member_token,
            action=action,
            canonical_payload=canonical_payload,
            room_id=room.id,
            player_name=player_name,
            is_host=is_host,
            capability_expires_at=capability_expires_at,
            provisional_deadline=(
                now + self._acquisition_provisional_timeout_seconds
            ),
        )
        self._member_acquisition_tokens[member.member_token] = token
        return AcquisitionClaim(
            token=token,
            action=action,
            canonical_payload=canonical_payload,
            room_id=room.id,
            player_name=player_name,
            is_host=is_host,
            capability_expires_at=capability_expires_at,
            host_token=room.host_token if is_host else "",
            state=AcquisitionClaimState.NEW,
        )

    def _expiration_reason_locked(
        self,
        room: RoomInfo,
        now: float,
    ) -> Optional[RoomExpirationReason]:
        if now >= room.absolute_deadline:
            return RoomExpirationReason.ABSOLUTE_LIFETIME_EXPIRED
        if room.idle_deadline is not None and now >= room.idle_deadline:
            return RoomExpirationReason.IDLE_LEASE_EXPIRED
        return None

    def _queue_termination_locked(
        self,
        room: RoomInfo,
        reason: RoomExpirationReason,
    ) -> None:
        if room.relay_port <= 0 or room.relay_instance_id <= 0:
            return
        grant = RoomTerminationGrant(
            room_id=room.id,
            room_name=room.name,
            relay_port=room.relay_port,
            relay_pid=room.relay_pid,
            relay_instance_id=room.relay_instance_id,
            reason=reason,
        )
        self._pending_terminations[
            (grant.relay_port, grant.relay_instance_id)
        ] = grant

    def _remove_room_locked(
        self,
        room: RoomInfo,
        reason: RoomExpirationReason,
        *,
        relay_already_reaped: bool = False,
        now: Optional[float] = None,
    ) -> None:
        removal_time = self._clock() if now is None else now
        self._rooms.pop(room.id, None)
        self._relay_start_attempts.pop(room.id, None)
        self._retire_room_acquisitions_locked(room.id, removal_time)
        room.status = RoomStatus.CLOSED
        if not relay_already_reaped:
            self._queue_termination_locked(room, reason)

    def _get_live_room_locked(
        self,
        room_id: str,
        now: float,
    ) -> Optional[RoomInfo]:
        self._expire_provisional_acquisitions_locked(now)
        room = self._rooms.get(room_id)
        if room is None:
            return None
        reason = self._expiration_reason_locked(room, now)
        if reason is not None:
            self._remove_room_locked(room, reason)
            return None
        return room

    def _expire_all_locked(self, now: float) -> list[ExpiredRoom]:
        self._expire_provisional_acquisitions_locked(now)
        expired: list[ExpiredRoom] = []
        for room in list(self._rooms.values()):
            reason = self._expiration_reason_locked(room, now)
            if reason is None:
                continue
            self._remove_room_locked(room, reason, now=now)
            expired.append(ExpiredRoom(room=room, reason=reason))
        return expired

    def drain_termination_grants(self) -> list[RoomTerminationGrant]:
        """移交终止权；Launcher 接受后负责失败重试。"""
        with self._lock:
            grants = list(self._pending_terminations.values())
            self._pending_terminations.clear()
            return grants

    def requeue_termination_grant(self, grant: RoomTerminationGrant) -> None:
        """Launcher 未接住终止权时归还账本，避免异常吞掉进程所有者。"""
        if grant.relay_port <= 0 or grant.relay_instance_id <= 0:
            return
        with self._lock:
            self._pending_terminations[
                (grant.relay_port, grant.relay_instance_id)
            ] = grant

    # ─── 创建 ────────────────────────────────────

    def create_room(
        self,
        name: str,
        host_name: str,
        host_ip: str,
        max_players: int = config.DEFAULT_PLAYERS_PER_ROOM,
        port: int = config.RELAY_PORT_START,
        game_mode: GameMode = GameMode.STANDARD,
    ) -> Optional[RoomInfo]:
        with self._lock:
            self._expire_all_locked(self._clock())
            if len(self._rooms) >= config.MAX_ROOMS:
                return None

            return self._create_room_locked(
                name,
                host_name,
                host_ip,
                max_players,
                port,
                game_mode,
                self._clock(),
            )

    def _create_room_locked(
        self,
        name: str,
        host_name: str,
        host_ip: str,
        max_players: int,
        port: int,
        game_mode: GameMode,
        now: float,
    ) -> RoomInfo:
        room = RoomInfo(
            name=name,
            host_name=host_name,
            host_ip=host_ip,
            port=port,
            max_players=min(
                max(max_players, config.MIN_PLAYERS_PER_ROOM),
                config.MAX_PLAYERS_PER_ROOM,
            ),
            game_mode=game_mode,
            status=RoomStatus.STARTING,
            idle_deadline=None,
            absolute_deadline=now + self._game_max_duration_seconds,
        )
        room.players[host_name] = PlayerInfo(name=host_name)
        self._rooms[room.id] = room
        return room

    def begin_create_acquisition(
        self,
        token: str,
        canonical_payload: tuple[str, ...],
        name: str,
        host_name: str,
        host_ip: str,
        max_players: int,
        game_mode: GameMode,
        *,
        capability_expires_at: float,
    ) -> Optional[AcquisitionClaim]:
        with self._lock:
            now = self._clock()
            capability_deadline = self._require_live_capability_deadline_locked(
                capability_expires_at
            )
            existing = self._get_existing_acquisition_claim_locked(
                token,
                AcquisitionAction.CREATE,
                canonical_payload,
                capability_deadline,
                now,
            )
            if existing is not None:
                return existing
            self._expire_all_locked(now)
            if len(self._rooms) >= config.MAX_ROOMS:
                return None
            self._reserve_acquisition_token_locked(now)
            room = self._create_room_locked(
                name,
                host_name,
                host_ip,
                max_players,
                config.RELAY_PORT_START,
                game_mode,
                now,
            )
            return self._register_acquisition_locked(
                token,
                AcquisitionAction.CREATE,
                canonical_payload,
                room,
                host_name,
                True,
                capability_deadline,
                now,
            )

    def begin_join_acquisition(
        self,
        token: str,
        canonical_payload: tuple[str, ...],
        room_id: str,
        player_name: str,
        game_mode: GameMode,
        *,
        capability_expires_at: float,
    ) -> Optional[AcquisitionClaim]:
        with self._lock:
            now = self._clock()
            capability_deadline = self._require_live_capability_deadline_locked(
                capability_expires_at
            )
            existing = self._get_existing_acquisition_claim_locked(
                token,
                AcquisitionAction.JOIN,
                canonical_payload,
                capability_deadline,
                now,
            )
            if existing is not None:
                return existing
            self._reserve_acquisition_token_locked(now)
            room = self._get_live_room_locked(room_id, now)
            if (
                room is None
                or not room.is_joinable
                or room.game_mode != game_mode
                or player_name in room.players
            ):
                return None
            room.players[player_name] = PlayerInfo(name=player_name)
            return self._register_acquisition_locked(
                token,
                AcquisitionAction.JOIN,
                canonical_payload,
                room,
                player_name,
                False,
                capability_deadline,
                now,
            )

    def begin_quick_match_acquisition(
        self,
        token: str,
        canonical_payload: tuple[str, ...],
        player_name: str,
        game_mode: GameMode,
        *,
        capability_expires_at: float,
    ) -> Optional[AcquisitionClaim]:
        """选房与占位在同一把锁内提交，避免扫描后容量被并发抢走。"""
        with self._lock:
            now = self._clock()
            capability_deadline = self._require_live_capability_deadline_locked(
                capability_expires_at
            )
            existing = self._get_existing_acquisition_claim_locked(
                token,
                AcquisitionAction.QUICK_MATCH,
                canonical_payload,
                capability_deadline,
                now,
            )
            if existing is not None:
                return existing
            self._reserve_acquisition_token_locked(now)
            self._expire_all_locked(now)
            joinable = [
                room
                for room in self._rooms.values()
                if (
                    room.is_joinable
                    and room.game_mode == game_mode
                    and player_name not in room.players
                )
            ]
            joinable.sort(key=lambda room: room.player_count, reverse=True)
            if joinable:
                room = joinable[0]
                room.players[player_name] = PlayerInfo(name=player_name)
                return self._register_acquisition_locked(
                    token,
                    AcquisitionAction.QUICK_MATCH,
                    canonical_payload,
                    room,
                    player_name,
                    False,
                    capability_deadline,
                    now,
                )
            if len(self._rooms) >= config.MAX_ROOMS:
                return None
            room = self._create_room_locked(
                f"{player_name} 的房间",
                player_name,
                "",
                config.DEFAULT_PLAYERS_PER_ROOM,
                config.RELAY_PORT_START,
                game_mode,
                now,
            )
            return self._register_acquisition_locked(
                token,
                AcquisitionAction.QUICK_MATCH,
                canonical_payload,
                room,
                player_name,
                True,
                capability_deadline,
                now,
            )

    def freeze_acquisition_response(
        self,
        token: str,
        canonical_payload: tuple[str, ...],
        public_ip: str,
    ) -> dict:
        """同一锁内验证占位仍属该 token，并冻结所有幂等重放结果。"""
        with self._lock:
            now = self._clock()
            self._expire_provisional_acquisitions_locked(now)
            if token in self._acquisition_tombstones:
                raise AcquisitionCancelledError("acquisition 已取消")
            record = self._acquisitions.get(token)
            if record is None:
                raise AcquisitionCancelledError("acquisition 不存在")
            if record.canonical_payload != canonical_payload:
                raise AcquisitionConflictError("acquisition 参数不一致")
            if record.frozen_response is not None:
                return deepcopy(record.frozen_response)
            room = self._get_live_room_locked(record.room_id, now)
            member = room.players.get(record.player_name) if room is not None else None
            if (
                room is None
                or member is None
                or not secrets.compare_digest(
                    member.member_token,
                    record.member_token,
                )
            ):
                self._retire_acquisition_locked(token, now)
                raise AcquisitionCancelledError("acquisition 已失去成员占位")
            response = self._build_private_join_dict_locked(
                room,
                public_ip,
                include_host_token=record.is_host,
                member_name=record.player_name,
                now=now,
            )
            response["acquisition_token"] = token
            record.frozen_response = deepcopy(response)
            return deepcopy(response)

    def confirm_member_acquisition(
        self,
        room_id: str,
        player_name: str,
        member_token: str,
    ) -> bool:
        """Relay 连通后用独立成员秘密确认，避免 capability TTL 参与连接时序。"""
        with self._lock:
            now = self._clock()
            self._expire_provisional_acquisitions_locked(now)
            token = self._member_acquisition_tokens.get(member_token)
            if token is None:
                return False
            record = self._acquisitions.get(token)
            if (
                record is None
                or record.is_host
                or record.room_id != room_id
                or record.player_name != player_name
                or not secrets.compare_digest(record.member_token, member_token)
            ):
                return False
            room = self._get_live_room_locked(record.room_id, now)
            member = room.players.get(record.player_name) if room is not None else None
            if (
                room is None
                or member is None
                or not secrets.compare_digest(member.member_token, member_token)
            ):
                return False
            record.provisional_deadline = None
            return True

    def release_acquisition(
        self,
        token: str,
        *,
        capability_expires_at: float,
    ) -> AcquisitionReleaseResult:
        """token 即唯一删除能力；未知 token 写墓碑以拦截迟到提交。"""
        with self._lock:
            now = self._clock()
            capability_deadline = self._checked_capability_deadline(
                capability_expires_at
            )
            self._expire_provisional_acquisitions_locked(now)
            if token in self._acquisition_tombstones:
                self._write_acquisition_tombstone_locked(
                    token,
                    now,
                    capability_deadline,
                )
                return AcquisitionReleaseResult.ALREADY_RELEASED
            record = self._acquisitions.get(token)
            if record is None:
                try:
                    self._reserve_acquisition_token_locked(now)
                except AcquisitionCapacityError:
                    # 无槽位记录这个未知秘密时，以同 TTL 的全局 fence 拒绝所有
                    # 新 token；否则任一旧墓碑先过期后，该迟到命令仍可能提交。
                    self._acquisition_saturation_deadline = max(
                        self._acquisition_saturation_deadline,
                        now + self._acquisition_tombstone_ttl_seconds,
                    )
                    self._acquisition_saturation_capability_deadline = max(
                        self._acquisition_saturation_capability_deadline,
                        capability_deadline,
                    )
                    raise
                self._write_acquisition_tombstone_locked(
                    token,
                    now,
                    capability_deadline,
                )
                return AcquisitionReleaseResult.TOMBSTONED_UNKNOWN
            if record.capability_expires_at != capability_deadline:
                raise AcquisitionConflictError(
                    "同一 acquisition token 的签名截止时间不一致"
                )
            room = self._rooms.get(record.room_id)
            if room is not None and record.is_host:
                self._remove_room_locked(
                    room,
                    RoomExpirationReason.EXPLICITLY_CLOSED,
                    now=now,
                )
            else:
                if room is not None:
                    member = room.players.get(record.player_name)
                    if member is not None and secrets.compare_digest(
                        member.member_token,
                        record.member_token,
                    ):
                        room.players.pop(record.player_name, None)
                self._retire_acquisition_locked(token, now)
            return AcquisitionReleaseResult.RELEASED

    # ─── 查询 ────────────────────────────────────

    def get_room(self, room_id: str) -> Optional[RoomInfo]:
        with self._lock:
            return self._get_live_room_locked(room_id, self._clock())

    def list_joinable_rooms(self) -> list[dict]:
        with self._lock:
            self._expire_all_locked(self._clock())
            return [
                room.to_public_dict()
                for room in self._rooms.values()
                if room.is_joinable
            ]

    def get_join_dict(
        self,
        room_id: str,
        public_ip: str,
        *,
        expected_host_token: Optional[str] = None,
        include_host_token: bool = False,
        member_name: Optional[str] = None,
    ) -> Optional[dict]:
        """在同一生命周期锁内校验并冻结对外房间快照。"""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if room is None:
                return None
            if expected_host_token is not None and (
                not expected_host_token or expected_host_token != room.host_token
            ):
                return None
            return self._build_private_join_dict_locked(
                room,
                public_ip,
                include_host_token=include_host_token,
                member_name=member_name,
                now=now,
            )

    def _build_private_join_dict_locked(
        self,
        room: RoomInfo,
        public_ip: str,
        *,
        include_host_token: bool,
        member_name: Optional[str],
        now: float,
    ) -> dict:
        """Build one caller-private response and attach its role-bound ticket.

        This helper is only called while ``_lock`` is held, after the caller's
        host/member capability and the room lifetime have already been checked.
        """
        response = room.to_join_dict(
            public_ip,
            include_host_token=include_host_token,
            member_name=member_name,
        )
        if member_name is None:
            return response
        member = room.players.get(member_name)
        if member is None:
            return response
        role = ROLE_HOST if member_name == room.host_name else ROLE_MEMBER
        ticket = self._issue_relay_admission_ticket_locked(
            room,
            member.name,
            role,
            now,
        )
        if ticket is not None:
            response["relay_admission_ticket"] = ticket
        return response

    def _issue_relay_admission_ticket_locked(
        self,
        room: RoomInfo,
        player_name: str,
        role: str,
        now: float,
    ) -> Optional[str]:
        remaining_seconds = room.absolute_deadline - now
        if remaining_seconds <= 0:
            return None
        ticket_ttl_seconds = min(
            remaining_seconds,
            self._relay_admission_ticket_ttl_seconds,
        )
        return self._admission_ticket_signer.issue(
            room.admission_secret,
            room.id,
            role,
            player_name,
            ticket_ttl_seconds,
        )

    def issue_member_relay_admission_ticket(
        self,
        room_id: str,
        player_name: str,
        member_token: str,
        public_ip: str,
    ) -> Optional[dict]:
        """Use a durable member credential to mint one short, one-use ticket."""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if (
                room is None
                or player_name == room.host_name
                or room.host_peer_id <= 0
                or room.relay_port <= 0
                or room.relay_instance_id <= 0
            ):
                return None
            member = room.players.get(player_name)
            if (
                member is None
                or not member_token
                or not secrets.compare_digest(
                    member_token.encode("utf-8"),
                    member.member_token.encode("ascii"),
                )
            ):
                return None
            refresh_key = (room.id, member.name)
            cutoff = now - self._relay_admission_refresh_window_seconds
            for key, attempts in list(
                self._relay_admission_refresh_attempts.items()
            ):
                fresh_attempts = [
                    attempt for attempt in attempts if attempt > cutoff
                ]
                if fresh_attempts:
                    self._relay_admission_refresh_attempts[key] = fresh_attempts
                else:
                    self._relay_admission_refresh_attempts.pop(key, None)
            member_attempts = self._relay_admission_refresh_attempts.get(
                refresh_key,
                [],
            )
            if len(member_attempts) >= self._relay_admission_refresh_burst:
                retry_after = (
                    member_attempts[0]
                    + self._relay_admission_refresh_window_seconds
                    - now
                )
                raise RelayAdmissionRefreshRateLimitError(retry_after)
            ticket = self._issue_relay_admission_ticket_locked(
                room,
                member.name,
                ROLE_MEMBER,
                now,
            )
            if ticket is None:
                return None
            member_attempts.append(now)
            self._relay_admission_refresh_attempts[refresh_key] = member_attempts
            return {
                "room_id": room.id,
                "player_name": member.name,
                "role": ROLE_MEMBER,
                "relay_ip": public_ip,
                "relay_port": room.relay_port,
                "host_peer_id": room.host_peer_id,
                "relay_admission_ticket": ticket,
            }

    def issue_host_relay_admission_ticket(
        self,
        room_id: str,
        host_token: str,
        public_ip: str,
    ) -> Optional[dict]:
        """Mint the current Relay generation's Host ticket after authorization."""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if (
                room is None
                or not host_token
                or room.relay_port <= 0
                or room.relay_instance_id <= 0
                or not secrets.compare_digest(
                    host_token.encode("utf-8"),
                    room.host_token.encode("ascii"),
                )
            ):
                return None
            host = room.players.get(room.host_name)
            if host is None:
                return None
            ticket = self._issue_relay_admission_ticket_locked(
                room,
                host.name,
                ROLE_HOST,
                now,
            )
            if ticket is None:
                return None
            return {
                "room_id": room.id,
                "player_name": host.name,
                "role": ROLE_HOST,
                "relay_ip": public_ip,
                "relay_port": room.relay_port,
                "host_peer_id": room.host_peer_id,
                "relay_admission_ticket": ticket,
            }

    # ─── 加入 / 离开 ─────────────────────────────

    def join_room(
        self,
        room_id: str,
        player_name: str,
        game_mode: GameMode = GameMode.STANDARD,
    ) -> Optional[RoomInfo]:
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return None
            if not room.is_joinable:
                return None
            if room.game_mode != game_mode:
                return None
            if player_name in room.players:
                return None  # 重名

            room.players[player_name] = PlayerInfo(name=player_name)
            return room

    def leave_room(
        self,
        room_id: str,
        player_name: str,
        member_token: str,
    ) -> tuple[bool, Optional[RoomInfo]]:
        """校验成员身份并离房；房主离房会关闭整个房间。"""
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return False, None
            member = room.players.get(player_name)
            if (
                member is None
                or not member_token
                or not secrets.compare_digest(
                    member_token.encode("utf-8"),
                    member.member_token.encode("ascii"),
                )
            ):
                return False, None

            if player_name == room.host_name:
                self._remove_room_locked(
                    room,
                    RoomExpirationReason.EXPLICITLY_CLOSED,
                )
                return True, room
            room.players.pop(player_name, None)
            acquisition_token = self._member_acquisition_tokens.get(member_token)
            if acquisition_token is not None:
                self._retire_acquisition_locked(acquisition_token, self._clock())
            return True, None

    # ─── 状态更新 ─────────────────────────────────

    def verify_host_token(self, room_id: str, host_token: str) -> bool:
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return False
            return bool(host_token) and host_token == room.host_token

    def get_authorized_relay_ref(
        self,
        room_id: str,
        host_token: str,
    ) -> Optional[AuthorizedRelayRef]:
        """原子冻结已认证房间当前持有的 Relay 引用。"""
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None or not host_token or host_token != room.host_token:
                return None
            return AuthorizedRelayRef(
                port=room.relay_port,
                pid=room.relay_pid,
                instance_id=room.relay_instance_id,
            )

    def update_room_status(
        self,
        room_id: str,
        status: RoomStatus,
        host_token: str,
    ) -> bool:
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if room is None:
                return False
            if not host_token or host_token != room.host_token:
                return False
            if status == RoomStatus.CLOSED:
                self._remove_room_locked(
                    room,
                    RoomExpirationReason.EXPLICITLY_CLOSED,
                )
                return True
            # STARTING 只由 Relay 重启事务管理，外部状态 PATCH 不得伪造。
            if status == RoomStatus.STARTING and room.status != RoomStatus.STARTING:
                return False
            if status == RoomStatus.IN_GAME and room.idle_deadline is None:
                if room.relay_port <= 0 or room.relay_instance_id <= 0:
                    return False
                room.idle_deadline = min(
                    now + self._room_idle_timeout_seconds,
                    room.absolute_deadline,
                )
            room.status = status
            return True

    def begin_relay_start(
        self,
        room_id: str,
        host_token: str,
    ) -> Optional[RelayStartGrant]:
        """锁内签发单次启动权，并冻结房间剩余绝对生命周期。"""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            if (
                room.max_players > config.PUBLIC_RELAY_MAX_PLAYERS
                or room.max_players < config.MIN_PLAYERS_PER_ROOM
                or room.status != RoomStatus.STARTING
                or room.relay_port > 0
                or room.relay_instance_id > 0
                or room_id in self._relay_start_attempts
            ):
                return None
            attempt_id = self._next_relay_start_attempt_id
            self._next_relay_start_attempt_id += 1
            self._relay_start_attempts[room_id] = attempt_id
            return RelayStartGrant(
                room_id=room_id,
                attempt_id=attempt_id,
                max_clients=room.max_players,
                max_lifetime_seconds=room.absolute_deadline - now,
                admission_secret=room.admission_secret,
            )

    def attach_relay(
        self,
        grant: RelayStartGrant,
        relay_port: int,
        relay_pid: int,
        relay_instance_id: int,
    ) -> bool:
        """启动宽限后以 attempt CAS 挂接；过期房间绝不重新发布。"""
        with self._lock:
            room = self._get_live_room_locked(grant.room_id, self._clock())
            if room is None:
                return False
            if self._relay_start_attempts.get(grant.room_id) != grant.attempt_id:
                return False
            if (
                room.status != RoomStatus.STARTING
                or room.relay_port > 0
                or room.relay_instance_id > 0
                or relay_port <= 0
                or relay_pid <= 0
                or relay_instance_id <= 0
            ):
                return False
            room.relay_port = relay_port
            room.relay_pid = relay_pid
            room.relay_instance_id = relay_instance_id
            self._relay_start_attempts.pop(grant.room_id, None)
            return True

    def get_relay_start_remaining_seconds(
        self,
        grant: RelayStartGrant,
    ) -> Optional[float]:
        """在真正 spawn 前按同一 attempt 重算房间绝对剩余时间。"""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(grant.room_id, now)
            if (
                room is None
                or self._relay_start_attempts.get(grant.room_id)
                != grant.attempt_id
            ):
                return None
            return room.absolute_deadline - now

    def fail_relay_start(self, grant: RelayStartGrant) -> Optional[RoomInfo]:
        """只有仍拥有 attempt 的失败启动才能终结房间。"""
        with self._lock:
            room = self._rooms.get(grant.room_id)
            if (
                room is None
                or self._relay_start_attempts.get(grant.room_id) != grant.attempt_id
            ):
                return None
            self._remove_room_locked(
                room,
                RoomExpirationReason.RELAY_START_FAILED,
            )
            return room

    def begin_relay_restart(
        self,
        room_id: str,
        host_token: str,
        expected_ref: AuthorizedRelayRef,
    ) -> Optional[RelayRestartGrant]:
        """先关闭可加入门，再允许 reaper 清理该精确死亡世代。"""
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None or not host_token or host_token != room.host_token:
                return None
            if (
                room.relay_port != expected_ref.port
                or room.relay_pid != expected_ref.pid
                or room.relay_instance_id != expected_ref.instance_id
                or expected_ref.instance_id <= 0
                or room.relay_restart_instance_id > 0
            ):
                return None
            grant = RelayRestartGrant(
                room_id=room.id,
                relay_ref=expected_ref,
                previous_status=room.status,
                previous_host_peer_id=room.host_peer_id,
                previous_admission_secret=room.admission_secret,
            )
            room.admission_secret = secrets.token_urlsafe(32)
            room.relay_restart_instance_id = expected_ref.instance_id
            room.status = RoomStatus.STARTING
            room.host_peer_id = 0
            if room.host_name in room.players:
                room.players[room.host_name].peer_id = 0
            return grant

    def cancel_relay_restart(self, grant: RelayRestartGrant) -> bool:
        """仅当旧绑定尚未被 reaper 清理时回滚误判的重启准备。"""
        with self._lock:
            room = self._get_live_room_locked(grant.room_id, self._clock())
            if room is None:
                return False
            if (
                room.relay_restart_instance_id != grant.relay_ref.instance_id
                or room.relay_port != grant.relay_ref.port
                or room.relay_instance_id != grant.relay_ref.instance_id
            ):
                return False
            room.relay_restart_instance_id = 0
            room.status = grant.previous_status
            room.host_peer_id = grant.previous_host_peer_id
            room.admission_secret = grant.previous_admission_secret
            if room.host_name in room.players:
                room.players[room.host_name].peer_id = grant.previous_host_peer_id
            return True

    def reconcile_reaped_relays(
        self,
        relay_instances: list[tuple[int, int]],
    ) -> list[RoomInfo]:
        """原子关闭旧绑定；受控重启房只清绑定并保持 STARTING。"""
        normalized_instances = {
            (int(port), int(instance_id))
            for port, instance_id in relay_instances
            if int(port) > 0 and int(instance_id) > 0
        }
        if not normalized_instances:
            return []
        with self._lock:
            now = self._clock()
            removed: list[RoomInfo] = []
            for room_id, room in list(self._rooms.items()):
                binding = (room.relay_port, room.relay_instance_id)
                if binding not in normalized_instances:
                    continue
                reason = self._expiration_reason_locked(room, now)
                if (
                    reason is None
                    and room.status == RoomStatus.STARTING
                    and room.relay_restart_instance_id
                    == room.relay_instance_id
                ):
                    room.relay_port = 0
                    room.relay_pid = 0
                    room.relay_instance_id = 0
                    room.relay_restart_instance_id = 0
                    continue
                self._remove_room_locked(
                    room,
                    reason or RoomExpirationReason.RELAY_EXITED,
                    relay_already_reaped=True,
                )
                removed.append(room)
            return removed

    def mark_host_ready(
        self,
        room_id: str,
        host_token: str,
        host_peer_id: int,
    ) -> Optional[RoomInfo]:
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            if host_peer_id <= 0:
                return None
            if room.relay_port <= 0 or room.relay_instance_id <= 0:
                return None
            if room.status not in (RoomStatus.STARTING, RoomStatus.WAITING):
                return None
            room.host_peer_id = host_peer_id
            room.status = RoomStatus.WAITING
            if room.host_name in room.players:
                room.players[room.host_name].peer_id = host_peer_id
                host_member_token = room.players[room.host_name].member_token
                acquisition_token = self._member_acquisition_tokens.get(
                    host_member_token
                )
                acquisition = self._acquisitions.get(acquisition_token or "")
                if (
                    acquisition is not None
                    and acquisition.room_id == room.id
                    and acquisition.is_host
                ):
                    acquisition.provisional_deadline = None
            return room

    def keep_room_alive(
        self,
        room_id: str,
        host_token: str,
        expected_relay_port: int,
        expected_relay_instance_id: int,
    ) -> Optional[RoomInfo]:
        """在房间、Relay 世代与两个 deadline 都仍有效时续租。"""
        with self._lock:
            now = self._clock()
            room = self._get_live_room_locked(room_id, now)
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            if (
                expected_relay_port <= 0
                or expected_relay_instance_id <= 0
                or room.relay_port != expected_relay_port
                or room.relay_instance_id != expected_relay_instance_id
                or room.idle_deadline is None
            ):
                return None
            room.idle_deadline = min(
                now + self._room_idle_timeout_seconds,
                room.absolute_deadline,
            )
            return room

    # ─── 销毁 ────────────────────────────────────

    def destroy_room(self, room_id: str, host_token: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            self._remove_room_locked(
                room,
                RoomExpirationReason.EXPLICITLY_CLOSED,
            )
            return room

    # ─── 快速匹配 ─────────────────────────────────

    def find_match(self, game_mode: GameMode = GameMode.STANDARD) -> Optional[RoomInfo]:
        """找一个人数最多但未满的房间。"""
        with self._lock:
            self._expire_all_locked(self._clock())
            joinable = [
                room
                for room in self._rooms.values()
                if room.is_joinable and room.game_mode == game_mode
            ]
            if not joinable:
                return None
            # 优先匹配人数最多的房间
            joinable.sort(key=lambda r: r.player_count, reverse=True)
            return joinable[0]

    # ─── 清理 ────────────────────────────────────

    def cleanup_expired_rooms(self) -> list[ExpiredRoom]:
        """按空闲租约和不可续租的绝对上限原子回收房间。"""
        with self._lock:
            return self._expire_all_locked(self._clock())
