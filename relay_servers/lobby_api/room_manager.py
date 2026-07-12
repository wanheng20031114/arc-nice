"""
房间生命周期管理。
"""

from __future__ import annotations

import time
import threading
from typing import Optional

from .models import GameMode, RoomInfo, RoomStatus, PlayerInfo
from . import config


class RoomManager:
    """线程安全的房间管理器。"""

    def __init__(self) -> None:
        self._rooms: dict[str, RoomInfo] = {}
        self._lock = threading.Lock()

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
            if len(self._rooms) >= config.MAX_ROOMS:
                return None

            room = RoomInfo(
                name=name,
                host_name=host_name,
                host_ip=host_ip,
                port=port,
                max_players=min(max(max_players, 2), config.MAX_PLAYERS_PER_ROOM),
                game_mode=game_mode,
                status=RoomStatus.STARTING,
            )

            # Host 自身作为第一个玩家
            room.players[host_name] = PlayerInfo(name=host_name)
            self._rooms[room.id] = room
            return room

    # ─── 查询 ────────────────────────────────────

    def get_room(self, room_id: str) -> Optional[RoomInfo]:
        with self._lock:
            return self._rooms.get(room_id)

    def list_joinable_rooms(self) -> list[dict]:
        with self._lock:
            return [
                room.to_public_dict()
                for room in self._rooms.values()
                if room.is_joinable
            ]

    # ─── 加入 / 离开 ─────────────────────────────

    def join_room(
        self,
        room_id: str,
        player_name: str,
        game_mode: GameMode = GameMode.STANDARD,
    ) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None
            if not room.is_joinable:
                return None
            if room.game_mode != game_mode:
                return None
            if player_name in room.players:
                return None  # 重名

            room.players[player_name] = PlayerInfo(name=player_name)
            room.touch()
            return room

    def leave_room(self, room_id: str, player_name: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None

            was_host = player_name == room.host_name
            room.players.pop(player_name, None)
            room.touch()

            # Host 离开或房间空了，关闭房间。
            if was_host or room.player_count == 0:
                room.status = RoomStatus.CLOSED
                self._rooms.pop(room_id, None)
                return room

            return None

    # ─── 状态更新 ─────────────────────────────────

    def verify_host_token(self, room_id: str, host_token: str) -> bool:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return False
            return bool(host_token) and host_token == room.host_token

    def update_room_status(
        self,
        room_id: str,
        status: RoomStatus,
        host_token: str,
    ) -> bool:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return False
            if not host_token or host_token != room.host_token:
                return False
            room.status = status
            room.touch()
            return True

    def set_relay_info(self, room_id: str, relay_port: int, relay_pid: int) -> bool:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return False
            room.relay_port = relay_port
            room.relay_pid = relay_pid
            room.touch()
            return True

    def mark_host_ready(self, room_id: str, host_token: str, host_peer_id: int) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            if host_peer_id <= 0:
                return None
            room.host_peer_id = host_peer_id
            room.status = RoomStatus.WAITING
            if room.host_name in room.players:
                room.players[room.host_name].peer_id = host_peer_id
            room.touch()
            return room

    def keep_room_alive(self, room_id: str, host_token: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            room.touch()
            return room

    # ─── 销毁 ────────────────────────────────────

    def destroy_room(self, room_id: str, host_token: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None
            if not host_token or host_token != room.host_token:
                return None
            self._rooms.pop(room_id, None)
            room.status = RoomStatus.CLOSED
            return room

    # ─── 快速匹配 ─────────────────────────────────

    def find_match(self, game_mode: GameMode = GameMode.STANDARD) -> Optional[RoomInfo]:
        """找一个人数最多但未满的房间。"""
        with self._lock:
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

    def cleanup_idle_rooms(self) -> list[RoomInfo]:
        """清理超时的空闲房间，返回被清理的列表。"""
        now = time.time()
        to_remove: list[str] = []
        with self._lock:
            for room_id, room in self._rooms.items():
                if now - room.last_activity > config.ROOM_IDLE_TIMEOUT:
                    to_remove.append(room_id)

            removed: list[RoomInfo] = []
            for room_id in to_remove:
                room = self._rooms.pop(room_id, None)
                if room is not None:
                    room.status = RoomStatus.CLOSED
                    removed.append(room)
            return removed
