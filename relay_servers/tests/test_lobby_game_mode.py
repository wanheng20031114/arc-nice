from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

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
from relay_servers.lobby_api.models import (
    RELEASE_GAME_MODES,
    GameMode,
    RoomInfo,
    RoomStatus,
)
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
    HIDDEN_GAME_MODES = tuple(
        game_mode
        for game_mode in ALL_GAME_MODES
        if game_mode not in RELEASE_GAME_MODES
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
        room.relay_pid = 10001
        room.relay_instance_id = 1
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

    def test_release_admission_single_source_has_exactly_three_modes(self) -> None:
        self.assertEqual(set(self.ALL_GAME_MODES), set(GameMode))
        self.assertEqual(
            RELEASE_GAME_MODES,
            frozenset(
                {
                    GameMode.STANDARD,
                    GameMode.TOWER_DEFENSE,
                    GameMode.TEST_ARENA_P3,
                }
            ),
        )
        self.assertEqual(len(self.HIDDEN_GAME_MODES), 6)

    def test_every_release_mode_can_create_and_quick_match(self) -> None:
        for game_mode in RELEASE_GAME_MODES:
            with self.subTest(game_mode=game_mode):
                manager = RoomManager()
                launcher = MagicMock()
                launcher.reap_exited.return_value = []

                async def freeze_created_room(
                    room_id: str,
                    _host_token: str,
                    host_name: str,
                ) -> dict:
                    room = manager.get_room(room_id)
                    assert room is not None
                    return room.to_join_dict(
                        "127.0.0.1",
                        include_host_token=True,
                        member_name=host_name,
                    )

                ensure_relay = AsyncMock(side_effect=freeze_created_room)
                with (
                    patch.object(lobby_main, "room_mgr", manager),
                    patch.object(lobby_main, "relay_launcher", launcher),
                    patch.object(
                        lobby_main,
                        "_ensure_room_relay",
                        ensure_relay,
                    ),
                ):
                    created = asyncio.run(
                        lobby_main.create_room(
                            CreateRoomRequest(
                                host_name="ReleaseHost",
                                game_mode=game_mode,
                            )
                        )
                    )
                    room = manager.get_room(created["room_id"])
                    assert room is not None
                    room.relay_port = 40001
                    room.relay_pid = 10001
                    room.relay_instance_id = 1
                    room.host_peer_id = 1
                    room.status = RoomStatus.WAITING

                    matched = asyncio.run(
                        lobby_main.quick_match(
                            QuickMatchRequest(
                                player_name="ReleaseClient",
                                game_mode=game_mode,
                            )
                        )
                    )

                self.assertEqual(created["game_mode"], game_mode.value)
                self.assertEqual(matched["room_id"], room.id)
                self.assertEqual(matched["game_mode"], game_mode.value)
                self.assertIn("ReleaseClient", room.players)
                ensure_relay.assert_awaited_once()

    def test_hidden_create_and_quick_match_return_403_without_side_effects(self) -> None:
        manager = RoomManager()
        launcher = MagicMock()
        launcher.stop_all.return_value = []
        ensure_relay = AsyncMock()

        with (
            patch.object(
                manager,
                "create_room",
                wraps=manager.create_room,
            ) as create_room_spy,
            patch.object(
                manager,
                "find_match",
                wraps=manager.find_match,
            ) as find_match_spy,
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main, "_ensure_room_relay", ensure_relay),
            TestClient(lobby_main.app) as client,
        ):
            for game_mode in self.HIDDEN_GAME_MODES:
                with self.subTest(game_mode=game_mode):
                    create_response = client.post(
                        "/rooms",
                        json={
                            "host_name": "HiddenHost",
                            "game_mode": game_mode.value,
                        },
                    )
                    quick_response = client.post(
                        "/matchmaking/quick",
                        json={
                            "player_name": "HiddenQuick",
                            "game_mode": game_mode.value,
                        },
                    )
                    self.assertEqual(create_response.status_code, 403)
                    self.assertEqual(quick_response.status_code, 403)
                    self.assertIn("未向正式大厅开放", create_response.json()["detail"])
                    self.assertIn("未向正式大厅开放", quick_response.json()["detail"])

        self.assertEqual(manager._rooms, {})
        create_room_spy.assert_not_called()
        find_match_spy.assert_not_called()
        ensure_relay.assert_not_awaited()
        launcher.start_new_relay.assert_not_called()
        launcher.start_relay.assert_not_called()

    def test_join_rejects_mode_mismatch_and_every_hidden_room_path(self) -> None:
        manager = RoomManager()
        release_room = self._create_joinable_room(
            manager,
            "ReleaseHost",
            GameMode.TOWER_DEFENSE,
        )
        hidden_room = self._create_joinable_room(
            manager,
            "HiddenHost",
            GameMode.TEST_ARENA_P1,
        )
        launcher = MagicMock()
        launcher.reap_exited.return_value = []

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            with self.assertRaises(HTTPException) as mismatch:
                asyncio.run(
                    lobby_main.join_room(
                        release_room.id,
                        JoinRoomRequest(
                            player_name="Mismatch",
                            game_mode=GameMode.STANDARD,
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as hidden_request:
                asyncio.run(
                    lobby_main.join_room(
                        hidden_room.id,
                        JoinRoomRequest(
                            player_name="HiddenWire",
                            game_mode=GameMode.TEST_ARENA_P1,
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as disguised_request:
                asyncio.run(
                    lobby_main.join_room(
                        hidden_room.id,
                        JoinRoomRequest(
                            player_name="ReleaseWire",
                            game_mode=GameMode.STANDARD,
                        ),
                    )
                )

        self.assertEqual(mismatch.exception.status_code, 404)
        self.assertEqual(hidden_request.exception.status_code, 403)
        self.assertEqual(disguised_request.exception.status_code, 403)
        self.assertNotIn("Mismatch", release_room.players)
        self.assertNotIn("HiddenWire", hidden_room.players)
        self.assertNotIn("ReleaseWire", hidden_room.players)

    def test_raw_rest_cannot_join_hidden_historical_room(self) -> None:
        manager = RoomManager()
        hidden_room = self._create_joinable_room(
            manager,
            "HiddenHost",
            GameMode.TEST_ARENA_P1E,
        )
        launcher = MagicMock()
        launcher.stop_all.return_value = []

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            TestClient(lobby_main.app) as client,
        ):
            hidden_wire = client.post(
                f"/rooms/{hidden_room.id}/join",
                json={
                    "player_name": "HiddenWire",
                    "game_mode": GameMode.TEST_ARENA_P1E.value,
                },
            )
            release_wire = client.post(
                f"/rooms/{hidden_room.id}/join",
                json={
                    "player_name": "ReleaseWire",
                    "game_mode": GameMode.STANDARD.value,
                },
            )

        self.assertEqual(hidden_wire.status_code, 403)
        self.assertEqual(release_wire.status_code, 403)
        self.assertNotIn("HiddenWire", hidden_room.players)
        self.assertNotIn("ReleaseWire", hidden_room.players)
        launcher.start_new_relay.assert_not_called()

    def test_hidden_history_is_not_listed_or_advanced_but_can_be_destroyed(self) -> None:
        manager = RoomManager()
        release_room = self._create_joinable_room(
            manager,
            "ReleaseHost",
            GameMode.STANDARD,
        )
        hidden_room = self._create_joinable_room(
            manager,
            "HiddenHost",
            GameMode.TEST_ARENA_P2,
        )
        launcher = MagicMock()
        launcher.reap_exited.return_value = []

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            listed = asyncio.run(lobby_main.list_rooms())
            with self.assertRaises(HTTPException) as ready_error:
                asyncio.run(
                    lobby_main.host_ready(
                        hidden_room.id,
                        HostReadyRequest(
                            host_token=hidden_room.host_token,
                            host_peer_id=2,
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as status_error:
                asyncio.run(
                    lobby_main.update_room(
                        hidden_room.id,
                        UpdateRoomRequest(
                            status=RoomStatus.IN_GAME.value,
                            host_token=hidden_room.host_token,
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as relay_error:
                asyncio.run(
                    lobby_main.request_relay(
                        hidden_room.id,
                        HostTokenRequest(host_token=hidden_room.host_token),
                    )
                )
            with self.assertRaises(HTTPException) as keepalive_error:
                asyncio.run(
                    lobby_main.keep_room_alive(
                        hidden_room.id,
                        HostTokenRequest(host_token=hidden_room.host_token),
                    )
                )
            peer_id_before_destroy = hidden_room.host_peer_id
            status_before_destroy = hidden_room.status
            destroyed = asyncio.run(
                lobby_main.destroy_room(
                    hidden_room.id,
                    HostTokenRequest(host_token=hidden_room.host_token),
                )
            )

        self.assertEqual([room["room_id"] for room in listed], [release_room.id])
        self.assertEqual(ready_error.exception.status_code, 403)
        self.assertEqual(status_error.exception.status_code, 403)
        self.assertEqual(relay_error.exception.status_code, 403)
        self.assertEqual(keepalive_error.exception.status_code, 403)
        self.assertEqual(peer_id_before_destroy, 1)
        self.assertEqual(status_before_destroy, RoomStatus.WAITING)
        self.assertEqual(destroyed, {"status": "ok"})
        self.assertIsNone(manager.get_room(hidden_room.id))
        launcher.start_new_relay.assert_not_called()

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
        launcher.stop_relay.assert_called_once_with(
            room.relay_port,
            room.relay_instance_id,
        )

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
        launcher.stop_relay.assert_called_once_with(
            room.relay_port,
            room.relay_instance_id,
        )

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
        launcher.stop_all.return_value = []

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
