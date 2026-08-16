"""
数据模型定义。
"""

from __future__ import annotations

import secrets
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class RoomStatus(str, Enum):
    STARTING = "starting"     # Relay 已分配，等待房主连接
    WAITING = "waiting"       # 等待玩家加入
    DIRECT = "direct"         # 已直连开始游戏
    RELAY = "relay"           # 通过 Relay 中继
    IN_GAME = "in_game"       # 游戏进行中
    CLOSED = "closed"         # 已关闭


class GameMode(str, Enum):
    # 这是不能随发布入口收缩的 wire/JSON 兼容表：旧客户端、历史房间和诊断工具
    # 仍需识别全部稳定值。生产大厅是否允许使用某模式由下方正式清单决定。
    STANDARD = "standard"
    TOWER_DEFENSE = "tower_defense"
    TEST_ARENA_P1 = "test_arena_p1"
    TEST_ARENA_P2 = "test_arena_p2"
    TEST_ARENA_P3 = "test_arena_p3"
    TEST_ARENA_P1B = "test_arena_p1b"
    TEST_ARENA_P1C = "test_arena_p1c"
    TEST_ARENA_P1D = "test_arena_p1d"
    TEST_ARENA_P1E = "test_arena_p1e"


# 正式大厅模式准入的唯一真源。TEST_ARENA_P3 是已发布 Rogue 的稳定 wire key，
# 名称虽保留历史 test 前缀，仍属于正式内容；其余 TEST_ARENA 值只供兼容解码。
RELEASE_GAME_MODES: frozenset[GameMode] = frozenset(
    {
        GameMode.STANDARD,
        GameMode.TOWER_DEFENSE,
        GameMode.TEST_ARENA_P3,
    }
)


def is_release_game_mode(game_mode: GameMode) -> bool:
    """判断模式是否获准进入正式大厅运行生命周期。"""
    return game_mode in RELEASE_GAME_MODES


@dataclass
class PlayerInfo:
    name: str
    peer_id: int = 0
    joined_at: float = field(default_factory=time.time)
    member_token: str = field(
        default_factory=lambda: secrets.token_urlsafe(24),
        repr=False,
    )


@dataclass
class RoomInfo:
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:8])
    name: str = ""
    host_name: str = ""
    host_token: str = field(default_factory=lambda: secrets.token_urlsafe(24))
    host_ip: str = ""
    host_peer_id: int = 0
    port: int = 29170
    max_players: int = 4
    game_mode: GameMode = GameMode.STANDARD
    status: RoomStatus = RoomStatus.WAITING
    players: dict[str, PlayerInfo] = field(default_factory=dict)  # name → PlayerInfo
    relay_port: int = 0
    relay_pid: int = 0
    # 端口会复用；实例世代与端口共同标识本房间真正拥有的 Relay。
    relay_instance_id: int = 0
    # 非零表示该精确死亡世代已进入受控重启，reap 只能清绑定不能删房。
    relay_restart_instance_id: int = 0
    # 两个单调 deadline 分别表达“需要心跳”和“任何心跳都不能越过”的边界。
    # Lobby 阶段客户端尚不发心跳，因此 idle 只在首次进入 IN_GAME 时建立。
    idle_deadline: Optional[float] = None
    absolute_deadline: float = field(default_factory=time.monotonic)

    @property
    def player_count(self) -> int:
        return len(self.players)

    @property
    def is_full(self) -> bool:
        return self.player_count >= self.max_players

    @property
    def is_joinable(self) -> bool:
        return (
            self.status == RoomStatus.WAITING
            and self.relay_port > 0
            and self.host_peer_id > 0
            and not self.is_full
        )

    def to_public_dict(self) -> dict:
        """返回可公开的房间信息（用于房间列表）。"""
        return {
            "id": self.id,
            "room_id": self.id,
            "name": self.name,
            "host_name": self.host_name,
            "host_peer_id": self.host_peer_id,
            "player_count": self.player_count,
            "max_players": self.max_players,
            "game_mode": self.game_mode.value,
            "status": self.status.value,
        }

    def to_join_dict(
        self,
        public_ip: str,
        include_host_token: bool = False,
        member_name: Optional[str] = None,
    ) -> dict:
        """返回加入房间时所需的详细信息。"""
        result = self.to_public_dict()
        result["host_ip"] = self.host_ip
        result["host_peer_id"] = self.host_peer_id
        result["port"] = self.port
        result["players"] = [
            {"name": player.name, "peer_id": player.peer_id}
            for player in self.players.values()
        ]
        if include_host_token:
            result["host_token"] = self.host_token
        if member_name is not None:
            member = self.players.get(member_name)
            if member is not None:
                result["member_token"] = member.member_token
        if self.relay_port > 0:
            result["relay_ip"] = public_ip
            result["relay_port"] = self.relay_port
        return result
