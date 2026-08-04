from __future__ import annotations

import asyncio
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, MagicMock, mock_open, patch

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import HostTokenRequest
from relay_servers.lobby_api.relay_launcher import RelayLauncher
from relay_servers.lobby_api.room_manager import RoomManager


class RelayCapacityTests(unittest.TestCase):
    def _create_room(
        self,
        manager: RoomManager,
        *,
        max_players: int,
    ):
        room = manager.create_room(
            name="Capacity room",
            host_name="Host",
            host_ip="",
            max_players=max_players,
        )
        self.assertIsNotNone(room)
        assert room is not None
        return room

    def test_ensure_room_relay_passes_room_capacity(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=6)
        launcher = MagicMock()
        launcher.allocate_port.return_value = 40031
        launcher.start_relay.return_value = 12031
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(lobby_main._ensure_room_relay(room))

        launcher.start_relay.assert_called_once_with(40031, 6)
        self.assertEqual(result["max_players"], 6)
        self.assertEqual(result["relay_port"], 40031)

    def test_request_relay_passes_room_capacity(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=3)
        launcher = MagicMock()
        launcher.allocate_port.return_value = 40032
        launcher.start_relay.return_value = 12032
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(
                lobby_main.request_relay(
                    room.id,
                    HostTokenRequest(host_token=room.host_token),
                )
            )

        launcher.start_relay.assert_called_once_with(40032, 3)
        self.assertEqual(result["relay_port"], 40032)

    def test_launcher_includes_max_clients_argument(self) -> None:
        launcher = RelayLauncher()
        process = MagicMock()
        process.pid = 12345

        with (
            patch(
                "relay_servers.lobby_api.relay_launcher.os.path.isfile",
                return_value=True,
            ),
            patch(
                "relay_servers.lobby_api.relay_launcher.os.path.isdir",
                return_value=True,
            ),
            patch(
                "relay_servers.lobby_api.relay_launcher.os.makedirs",
            ),
            patch(
                "builtins.open",
                mock_open(),
            ),
            patch(
                "relay_servers.lobby_api.relay_launcher.subprocess.Popen",
                return_value=process,
            ) as popen,
        ):
            pid = launcher.start_relay(40033, 5)

        self.assertEqual(pid, 12345)
        command = popen.call_args.args[0]
        self.assertIn("--port=40033", command)
        self.assertIn("--max-clients=5", command)

    def test_launcher_rejects_capacity_outside_two_to_eight(self) -> None:
        launcher = RelayLauncher()
        with patch(
            "relay_servers.lobby_api.relay_launcher.subprocess.Popen"
        ) as popen:
            self.assertIsNone(launcher.start_relay(40034, 1))
            self.assertIsNone(launcher.start_relay(40034, 9))
        popen.assert_not_called()

    def test_relay_project_uses_capacity_argument_and_protocol_v44(self) -> None:
        relay_source = (
            Path(__file__).resolve().parents[1]
            / "relay_godot_project"
            / "relay_server.gd"
        ).read_text(encoding="utf-8")

        self.assertIn("const PROTOCOL_VERSION := 44", relay_source)
        self.assertIn('arg.begins_with("--max-clients=")', relay_source)
        self.assertIn(
            "peer.create_server(_port, _max_clients, CHANNEL_COUNT)",
            relay_source,
        )
        self.assertIn(
            "parsed_max_clients < MIN_CLIENTS or parsed_max_clients > MAX_CLIENTS",
            relay_source,
        )


if __name__ == "__main__":
    unittest.main()
