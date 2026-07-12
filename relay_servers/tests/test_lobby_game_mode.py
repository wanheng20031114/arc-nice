from __future__ import annotations

import asyncio
import unittest
from unittest.mock import patch

from fastapi import HTTPException

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import (
    CreateRoomRequest,
    JoinRoomRequest,
    QuickMatchRequest,
)
from relay_servers.lobby_api.models import GameMode, RoomInfo, RoomStatus
from relay_servers.lobby_api.room_manager import RoomManager


class LobbyGameModeTests(unittest.TestCase):
    def _create_joinable_room(
        self,
        manager: RoomManager,
        host_name: str,
        game_mode: GameMode,
    ) -> RoomInfo:
        room = manager.create_room(
            name=f"{host_name} room",
            host_name=host_name,
            host_ip="",
            game_mode=game_mode,
        )
        self.assertIsNotNone(room)
        assert room is not None
        room.relay_port = 40001
        room.host_peer_id = 1
        room.status = RoomStatus.WAITING
        return room

    def test_request_models_default_to_standard(self) -> None:
        self.assertEqual(
            CreateRoomRequest(host_name="Host").game_mode,
            GameMode.STANDARD,
        )
        self.assertEqual(
            JoinRoomRequest(player_name="Client").game_mode,
            GameMode.STANDARD,
        )
        self.assertEqual(
            QuickMatchRequest(player_name="Quick").game_mode,
            GameMode.STANDARD,
        )

    def test_room_public_contract_includes_game_mode(self) -> None:
        room = RoomInfo(game_mode=GameMode.TOWER_DEFENSE)
        self.assertEqual(room.to_public_dict()["game_mode"], "tower_defense")
        self.assertEqual(
            room.to_join_dict("127.0.0.1")["game_mode"],
            "tower_defense",
        )

    def test_join_and_quick_match_never_cross_modes(self) -> None:
        manager = RoomManager()
        standard_room = self._create_joinable_room(
            manager,
            "StandardHost",
            GameMode.STANDARD,
        )
        tower_room = self._create_joinable_room(
            manager,
            "TowerHost",
            GameMode.TOWER_DEFENSE,
        )

        self.assertIs(
            manager.find_match(GameMode.STANDARD),
            standard_room,
        )
        self.assertIs(
            manager.find_match(GameMode.TOWER_DEFENSE),
            tower_room,
        )
        self.assertIsNone(
            manager.join_room(
                tower_room.id,
                "WrongMode",
                GameMode.STANDARD,
            )
        )
        self.assertNotIn("WrongMode", tower_room.players)

        with patch.object(lobby_main, "room_mgr", manager):
            quick_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TowerClient",
                        game_mode=GameMode.TOWER_DEFENSE,
                    )
                )
            )
            self.assertEqual(quick_result["room_id"], tower_room.id)
            self.assertEqual(quick_result["game_mode"], "tower_defense")

            with self.assertRaises(HTTPException):
                asyncio.run(
                    lobby_main.join_room(
                        standard_room.id,
                        JoinRoomRequest(
                            player_name="MismatchClient",
                            game_mode=GameMode.TOWER_DEFENSE,
                        ),
                    )
                )


if __name__ == "__main__":
    unittest.main()
