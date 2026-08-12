from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest.mock import MagicMock, patch

from fastapi import HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import (
    CreateRoomRequest,
    HostReadyRequest,
    HostTokenRequest,
    JoinRoomRequest,
    LeaveRoomRequest,
    QuickMatchRequest,
    UpdateRoomRequest,
)
from relay_servers.lobby_api.models import GameMode, RoomInfo, RoomStatus
from relay_servers.lobby_api.room_manager import RoomManager


class LobbyGameModeTests(unittest.TestCase):
    ALL_GAME_MODES = (
        GameMode.STANDARD,
        GameMode.TOWER_DEFENSE,
        GameMode.TEST_ARENA_P1,
        GameMode.TEST_ARENA_P2,
        GameMode.TEST_ARENA_P3,
        GameMode.TEST_ARENA_P1B,
        GameMode.TEST_ARENA_P1C,
        GameMode.TEST_ARENA_P1D,
        GameMode.TEST_ARENA_P1E,
    )

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

    def test_request_models_accept_every_game_mode(self) -> None:
        for game_mode in self.ALL_GAME_MODES:
            with self.subTest(game_mode=game_mode):
                self.assertEqual(
                    CreateRoomRequest(
                        host_name="Host",
                        game_mode=game_mode.value,
                    ).game_mode,
                    game_mode,
                )
                self.assertEqual(
                    JoinRoomRequest(
                        player_name="Client",
                        game_mode=game_mode.value,
                    ).game_mode,
                    game_mode,
                )
                self.assertEqual(
                    QuickMatchRequest(
                        player_name="Quick",
                        game_mode=game_mode.value,
                    ).game_mode,
                    game_mode,
                )

    def test_request_models_bound_untrusted_text_fields(self) -> None:
        invalid_requests = (
            lambda: CreateRoomRequest(host_name="H" * 33),
            lambda: CreateRoomRequest(host_name="Host", name="R" * 65),
            lambda: JoinRoomRequest(player_name="P" * 33),
            lambda: LeaveRoomRequest(
                player_name="Member",
                member_token="M" * 129,
            ),
            lambda: LeaveRoomRequest(player_name="Member"),
            lambda: QuickMatchRequest(player_name="Q" * 33),
            lambda: HostTokenRequest(host_token="T" * 129),
            lambda: HostReadyRequest(host_token="T" * 129, host_peer_id=1),
            lambda: UpdateRoomRequest(status="S" * 33, host_token="token"),
        )
        for build_request in invalid_requests:
            with self.subTest(build_request=build_request):
                with self.assertRaises(ValidationError):
                    build_request()

    def test_room_public_contract_includes_every_game_mode(self) -> None:
        for game_mode in self.ALL_GAME_MODES:
            with self.subTest(game_mode=game_mode):
                room = RoomInfo(game_mode=game_mode)
                self.assertEqual(
                    room.to_public_dict()["game_mode"],
                    game_mode.value,
                )
                self.assertEqual(
                    room.to_join_dict("127.0.0.1")["game_mode"],
                    game_mode.value,
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
        test_p1_room = self._create_joinable_room(
            manager,
            "TestP1Host",
            GameMode.TEST_ARENA_P1,
        )
        test_p2_room = self._create_joinable_room(
            manager,
            "TestP2Host",
            GameMode.TEST_ARENA_P2,
        )
        test_p3_room = self._create_joinable_room(
            manager,
            "TestP3Host",
            GameMode.TEST_ARENA_P3,
        )
        test_p1b_room = self._create_joinable_room(
            manager,
            "TestP1BHost",
            GameMode.TEST_ARENA_P1B,
        )
        test_p1c_room = self._create_joinable_room(
            manager,
            "TestP1CHost",
            GameMode.TEST_ARENA_P1C,
        )
        test_p1d_room = self._create_joinable_room(
            manager,
            "TestP1DHost",
            GameMode.TEST_ARENA_P1D,
        )
        test_p1e_room = self._create_joinable_room(
            manager,
            "TestP1EHost",
            GameMode.TEST_ARENA_P1E,
        )

        expected_rooms = {
            GameMode.STANDARD: standard_room,
            GameMode.TOWER_DEFENSE: tower_room,
            GameMode.TEST_ARENA_P1: test_p1_room,
            GameMode.TEST_ARENA_P2: test_p2_room,
            GameMode.TEST_ARENA_P3: test_p3_room,
            GameMode.TEST_ARENA_P1B: test_p1b_room,
            GameMode.TEST_ARENA_P1C: test_p1c_room,
            GameMode.TEST_ARENA_P1D: test_p1d_room,
            GameMode.TEST_ARENA_P1E: test_p1e_room,
        }
        for game_mode, expected_room in expected_rooms.items():
            with self.subTest(game_mode=game_mode):
                self.assertIs(
                    manager.find_match(game_mode),
                    expected_room,
                )

        self.assertIsNone(
            manager.join_room(
                tower_room.id,
                "WrongMode",
                GameMode.STANDARD,
            )
        )
        self.assertNotIn("WrongMode", tower_room.players)
        self.assertIsNone(
            manager.join_room(
                test_p1_room.id,
                "P1BMismatch",
                GameMode.TEST_ARENA_P1B,
            )
        )
        self.assertNotIn("P1BMismatch", test_p1_room.players)

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

            test_p2_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP2Client",
                        game_mode=GameMode.TEST_ARENA_P2,
                    )
                )
            )
            self.assertEqual(test_p2_result["room_id"], test_p2_room.id)
            self.assertEqual(test_p2_result["game_mode"], "test_arena_p2")

            test_p3_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP3Client",
                        game_mode=GameMode.TEST_ARENA_P3,
                    )
                )
            )
            self.assertEqual(test_p3_result["room_id"], test_p3_room.id)
            self.assertEqual(test_p3_result["game_mode"], "test_arena_p3")

            test_p1b_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP1BClient",
                        game_mode=GameMode.TEST_ARENA_P1B,
                    )
                )
            )
            self.assertEqual(test_p1b_result["room_id"], test_p1b_room.id)
            self.assertEqual(test_p1b_result["game_mode"], "test_arena_p1b")

            test_p1c_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP1CClient",
                        game_mode=GameMode.TEST_ARENA_P1C,
                    )
                )
            )
            self.assertEqual(test_p1c_result["room_id"], test_p1c_room.id)
            self.assertEqual(test_p1c_result["game_mode"], "test_arena_p1c")

            test_p1d_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP1DClient",
                        game_mode=GameMode.TEST_ARENA_P1D,
                    )
                )
            )
            self.assertEqual(test_p1d_result["room_id"], test_p1d_room.id)
            self.assertEqual(test_p1d_result["game_mode"], "test_arena_p1d")

            test_p1e_result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="TestP1EClient",
                        game_mode=GameMode.TEST_ARENA_P1E,
                    )
                )
            )
            self.assertEqual(test_p1e_result["room_id"], test_p1e_room.id)
            self.assertEqual(test_p1e_result["game_mode"], "test_arena_p1e")

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

    def test_join_response_issues_only_callers_private_member_token(self) -> None:
        manager = RoomManager()
        room = self._create_joinable_room(
            manager,
            "PublicHost",
            GameMode.STANDARD,
        )
        launcher = MagicMock()
        launcher.reap_exited.return_value = []

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            response = asyncio.run(
                lobby_main.join_room(
                    room.id,
                    JoinRoomRequest(player_name="Member"),
                )
            )

        host_token = room.players[room.host_name].member_token
        member_token = room.players["Member"].member_token
        self.assertEqual(response["member_token"], member_token)
        self.assertNotEqual(member_token, host_token)
        self.assertNotIn("member_token", room.to_public_dict())
        self.assertNotIn("member_token", room.to_join_dict("127.0.0.1"))
        self.assertTrue(
            all("member_token" not in player for player in response["players"])
        )

    def test_leave_requires_matching_member_token_for_host_and_member(self) -> None:
        manager = RoomManager()
        room = self._create_joinable_room(
            manager,
            "PublicHost",
            GameMode.STANDARD,
        )
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        launcher = MagicMock()

        authorized, removed = manager.leave_room(
            room.id,
            room.host_name,
            "wrong-token",
        )
        self.assertFalse(authorized)
        self.assertIsNone(removed)
        self.assertIs(manager.get_room(room.id), room)
        self.assertIn(room.host_name, room.players)

        unicode_authorized, unicode_removed = manager.leave_room(
            room.id,
            room.host_name,
            "伪造令牌",
        )
        self.assertFalse(unicode_authorized)
        self.assertIsNone(unicode_removed)

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    lobby_main.leave_room(
                        room.id,
                        LeaveRoomRequest(
                            player_name=room.host_name,
                            member_token=room.players["Member"].member_token,
                        ),
                    )
                )

        self.assertEqual(raised.exception.status_code, 403)
        self.assertIs(manager.get_room(room.id), room)
        launcher.stop_relay.assert_not_called()

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            result = asyncio.run(
                lobby_main.leave_room(
                    room.id,
                    LeaveRoomRequest(
                        player_name=room.host_name,
                        member_token=room.players[room.host_name].member_token,
                    ),
                )
            )

        self.assertEqual(result, {"status": "ok"})
        self.assertIsNone(manager.get_room(room.id))
        launcher.stop_relay.assert_called_once_with(room.relay_port)

    def test_member_leave_and_tokenized_host_destroy_remain_available(self) -> None:
        manager = RoomManager()
        room = self._create_joinable_room(
            manager,
            "PublicHost",
            GameMode.STANDARD,
        )
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token
        launcher = MagicMock()

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            leave_result = asyncio.run(
                lobby_main.leave_room(
                    room.id,
                    LeaveRoomRequest(
                        player_name="Member",
                        member_token=member_token,
                    ),
                )
            )
            self.assertEqual(leave_result, {"status": "ok"})
            self.assertNotIn("Member", room.players)
            self.assertIs(manager.get_room(room.id), room)
            launcher.stop_relay.assert_not_called()

            with self.assertRaises(HTTPException) as replayed:
                asyncio.run(
                    lobby_main.leave_room(
                        room.id,
                        LeaveRoomRequest(
                            player_name="Member",
                            member_token=member_token,
                        ),
                    )
                )
            self.assertEqual(replayed.exception.status_code, 403)

            destroy_result = asyncio.run(
                lobby_main.destroy_room(
                    room.id,
                    HostTokenRequest(host_token=room.host_token),
                )
            )

        self.assertEqual(destroy_result, {"status": "ok"})
        self.assertIsNone(manager.get_room(room.id))
        launcher.stop_relay.assert_called_once_with(room.relay_port)

    def test_member_token_authorizes_only_one_concurrent_leave(self) -> None:
        manager = RoomManager()
        room = self._create_joinable_room(
            manager,
            "PublicHost",
            GameMode.STANDARD,
        )
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    lambda _index: manager.leave_room(
                        room.id,
                        "Member",
                        member_token,
                    ),
                    range(2),
                )
            )

        self.assertEqual([authorized for authorized, _room in results].count(True), 1)
        self.assertEqual([authorized for authorized, _room in results].count(False), 1)
        self.assertNotIn("Member", room.players)

    def test_leave_http_contract_requires_matching_member_token(self) -> None:
        manager = RoomManager()
        room = self._create_joinable_room(
            manager,
            "PublicHost",
            GameMode.STANDARD,
        )
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token
        launcher = MagicMock()

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            TestClient(lobby_main.app) as client,
        ):
            missing = client.post(
                f"/rooms/{room.id}/leave",
                json={"player_name": "Member"},
            )
            forged = client.post(
                f"/rooms/{room.id}/leave",
                json={
                    "player_name": "Member",
                    "member_token": "forged-token",
                },
            )
            accepted = client.post(
                f"/rooms/{room.id}/leave",
                json={
                    "player_name": "Member",
                    "member_token": member_token,
                },
            )

        self.assertEqual(missing.status_code, 422)
        self.assertEqual(forged.status_code, 403)
        self.assertEqual(accepted.status_code, 200)
        self.assertNotIn("Member", room.players)


if __name__ == "__main__":
    unittest.main()
