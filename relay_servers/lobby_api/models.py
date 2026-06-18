"""
数据模型定义。
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class RoomStatus(str, Enum):
    WAITING = "waiting"       # 等待玩家加入
    DIRECT = "direct"         # 已直连开始游戏
    RELAY = "relay"           # 通过 Relay 中继
    IN_GAME = "in_game"       # 游戏进行中
    CLOSED = "closed"         # 已关闭


@dataclass
class PlayerInfo:
    name: str
    peer_id: int = 0
    joined_at: float = field(default_factory=time.time)


@dataclass
class RoomInfo:
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    name: str = ""
    host_name: str = ""
    host_ip: str = ""
    port: int = 29170
    max_players: int = 4
    status: RoomStatus = RoomStatus.WAITING
    players: dict[str, PlayerInfo] = field(default_factory=dict)  # name → PlayerInfo
    relay_port: int = 0
    relay_pid: int = 0
    created_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)

    @property
    def player_count(self) -> int:
        return len(self.players)

    @property
    def is_full(self) -> bool:
        return self.player_count >= self.max_players

    @property
    def is_joinable(self) -> bool:
        return self.status == RoomStatus.WAITING and not self.is_full

    def to_public_dict(self) -> dict:
        """返回可公开的房间信息（用于房间列表）。"""
        return {
            "id": self.id,
            "name": self.name,
            "host_name": self.host_name,
            "player_count": self.player_count,
            "max_players": self.max_players,
            "status": self.status.value,
        }

    def to_join_dict(self, public_ip: str) -> dict:
        """返回加入房间时所需的详细信息。"""
        result = self.to_public_dict()
        result["host_ip"] = self.host_ip
        result["port"] = self.port
        if self.relay_port > 0:
            result["relay_ip"] = public_ip
            result["relay_port"] = self.relay_port
        return result

    def touch(self) -> None:
        """更新最后活跃时间。"""
        self.last_activity = time.time()
