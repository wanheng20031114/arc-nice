"""
房间生命周期管理。
"""

from __future__ import annotations

import secrets
import time
import threading
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional

from .models import GameMode, RoomInfo, RoomStatus, PlayerInfo
from . import config


class RoomExpirationReason(str, Enum):
    """房间被服务端回收的可观察原因。"""

    IDLE_LEASE_EXPIRED = "idle_lease_expired"
    ABSOLUTE_LIFETIME_EXPIRED = "absolute_lifetime_expired"
    EXPLICITLY_CLOSED = "explicitly_closed"
    RELAY_EXITED = "relay_exited"
    RELAY_START_FAILED = "relay_start_failed"


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


@dataclass(frozen=True)
class RelayRestartGrant:
    """把一个已绑定房间切换到受控重启状态所需的回滚信息。"""

    room_id: str
    relay_ref: AuthorizedRelayRef
    previous_status: RoomStatus
    previous_host_peer_id: int


class RoomManager:
    """线程安全的房间管理器。"""

    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        room_idle_timeout_seconds: float = config.ROOM_IDLE_TIMEOUT_SECONDS,
        game_max_duration_seconds: float = config.GAME_MAX_DURATION_SECONDS,
    ) -> None:
        if room_idle_timeout_seconds <= 0:
            raise ValueError("room_idle_timeout_seconds 必须大于 0")
        if game_max_duration_seconds <= 0:
            raise ValueError("game_max_duration_seconds 必须大于 0")
        self._rooms: dict[str, RoomInfo] = {}
        self._lock = threading.Lock()
        self._clock = clock
        self._room_idle_timeout_seconds = room_idle_timeout_seconds
        self._game_max_duration_seconds = game_max_duration_seconds
        self._pending_terminations: dict[tuple[int, int], RoomTerminationGrant] = {}
        self._relay_start_attempts: dict[str, int] = {}
        self._next_relay_start_attempt_id = 1

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
    ) -> None:
        self._rooms.pop(room.id, None)
        self._relay_start_attempts.pop(room.id, None)
        room.status = RoomStatus.CLOSED
        if not relay_already_reaped:
            self._queue_termination_locked(room, reason)

    def _get_live_room_locked(
        self,
        room_id: str,
        now: float,
    ) -> Optional[RoomInfo]:
        room = self._rooms.get(room_id)
        if room is None:
            return None
        reason = self._expiration_reason_locked(room, now)
        if reason is not None:
            self._remove_room_locked(room, reason)
            return None
        return room

    def _expire_all_locked(self, now: float) -> list[ExpiredRoom]:
        expired: list[ExpiredRoom] = []
        for room in list(self._rooms.values()):
            reason = self._expiration_reason_locked(room, now)
            if reason is None:
                continue
            self._remove_room_locked(room, reason)
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
        max_players: int = 4,
        port: int = config.RELAY_PORT_START,
        game_mode: GameMode = GameMode.STANDARD,
    ) -> Optional[RoomInfo]:
        with self._lock:
            self._expire_all_locked(self._clock())
            if len(self._rooms) >= config.MAX_ROOMS:
                return None

            now = self._clock()
            room = RoomInfo(
                name=name,
                host_name=host_name,
                host_ip=host_ip,
                port=port,
                max_players=min(max(max_players, 2), config.MAX_PLAYERS_PER_ROOM),
                game_mode=game_mode,
                status=RoomStatus.STARTING,
                idle_deadline=None,
                absolute_deadline=now + self._game_max_duration_seconds,
            )

            # Host 自身作为第一个玩家
            room.players[host_name] = PlayerInfo(name=host_name)
            self._rooms[room.id] = room
            return room

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
            room = self._get_live_room_locked(room_id, self._clock())
            if room is None:
                return None
            if expected_host_token is not None and (
                not expected_host_token or expected_host_token != room.host_token
            ):
                return None
            return room.to_join_dict(
                public_ip,
                include_host_token=include_host_token,
                member_name=member_name,
            )

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
                room.status != RoomStatus.STARTING
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
            )
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

    def mark_host_ready(self, room_id: str, host_token: str, host_peer_id: int) -> Optional[RoomInfo]:
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
