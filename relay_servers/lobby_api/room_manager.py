"""
房间生命周期管理。
"""

from __future__ import annotations

import time
import threading
from typing import Optional

from .models import RoomInfo, RoomStatus, PlayerInfo
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
            )

            # Host 自身作为第一个玩家
            room.players[host_name] = PlayerInfo(name=host_name, peer_id=1)
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

    def join_room(self, room_id: str, player_name: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return None
            if not room.is_joinable:
                return None
            if player_name in room.players:
                return None  # 重名

            room.players[player_name] = PlayerInfo(name=player_name)
            room.touch()
            return room

    def leave_room(self, room_id: str, player_name: str) -> bool:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
                return False

            room.players.pop(player_name, None)
            room.touch()

            # 如果房间空了，标记关闭
            if room.player_count == 0:
                room.status = RoomStatus.CLOSED
                self._rooms.pop(room_id, None)

            return True

    # ─── 状态更新 ─────────────────────────────────

    def update_room_status(self, room_id: str, status: RoomStatus) -> bool:
        with self._lock:
            room = self._rooms.get(room_id)
            if room is None:
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
            room.status = RoomStatus.RELAY
            room.touch()
            return True

    # ─── 销毁 ────────────────────────────────────

    def destroy_room(self, room_id: str) -> Optional[RoomInfo]:
        with self._lock:
            room = self._rooms.pop(room_id, None)
            if room is not None:
                room.status = RoomStatus.CLOSED
            return room

    # ─── 快速匹配 ─────────────────────────────────

    def find_match(self) -> Optional[RoomInfo]:
        """找一个人数最多但未满的房间。"""
        with self._lock:
            joinable = [r for r in self._rooms.values() if r.is_joinable]
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
