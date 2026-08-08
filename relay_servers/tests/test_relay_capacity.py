from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, MagicMock, mock_open, patch

from fastapi import HTTPException

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import (
    HostTokenRequest,
    JoinRoomRequest,
    QuickMatchRequest,
)
from relay_servers.lobby_api.models import GameMode, RoomStatus
from relay_servers.lobby_api.relay_launcher import RelayLauncher
from relay_servers.lobby_api.room_manager import RoomManager


class RelayCapacityTests(unittest.TestCase):
    def setUp(self) -> None:
        lobby_main._relay_start_tasks.clear()

    def tearDown(self) -> None:
        lobby_main._relay_start_tasks.clear()

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
        launcher.start_new_relay.return_value = (40031, 12031, [])
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(lobby_main._ensure_room_relay(room))

        launcher.start_new_relay.assert_called_once_with(6)
        self.assertEqual(result["max_players"], 6)
        self.assertEqual(result["relay_port"], 40031)
        self.assertEqual(
            result["member_token"],
            room.players[room.host_name].member_token,
        )

    def test_request_relay_passes_room_capacity(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=3)
        launcher = MagicMock()
        launcher.start_new_relay.return_value = (40032, 12032, [])
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

        launcher.start_new_relay.assert_called_once_with(3)
        self.assertEqual(result["relay_port"], 40032)

    def test_new_allocation_closes_room_owned_by_reaped_relay(self) -> None:
        manager = RoomManager()
        old_room = self._create_room(manager, max_players=4)
        old_room.relay_port = 40001
        old_room.relay_pid = 10001
        new_room = self._create_room(manager, max_players=4)
        launcher = MagicMock()
        launcher.start_new_relay.return_value = (40001, 10002, [40001])
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(lobby_main._ensure_room_relay(new_room))

        self.assertIsNone(manager.get_room(old_room.id))
        self.assertEqual(manager.get_room(new_room.id), new_room)
        self.assertEqual(result["relay_port"], 40001)

    def test_relay_restart_keeps_current_room_when_reaping_its_port(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=4)
        room.relay_port = 40001
        room.relay_pid = 10001
        launcher = MagicMock()
        launcher.is_relay_running.side_effect = [False, True]
        launcher.start_new_relay.return_value = (40001, 10002, [40001])

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

        self.assertIs(manager.get_room(room.id), room)
        self.assertEqual(room.relay_port, 40001)
        self.assertEqual(room.relay_pid, 10002)
        self.assertEqual(result["relay_port"], 40001)

    def test_concurrent_request_relay_starts_only_one_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=4)
        launcher = MagicMock()
        launcher.start_new_relay.return_value = (40041, 12041, [])
        launcher.is_relay_running.return_value = True
        real_sleep = asyncio.sleep

        async def scenario() -> list[dict]:
            grace_entered = asyncio.Event()
            release_grace = asyncio.Event()

            async def gated_grace(_delay: float) -> None:
                grace_entered.set()
                await release_grace.wait()

            with patch.object(lobby_main.asyncio, "sleep", new=gated_grace):
                first = asyncio.create_task(
                    lobby_main.request_relay(
                        room.id,
                        HostTokenRequest(host_token=room.host_token),
                    )
                )
                await grace_entered.wait()
                second = asyncio.create_task(
                    lobby_main.request_relay(
                        room.id,
                        HostTokenRequest(host_token=room.host_token),
                    )
                )
                await real_sleep(0)
                release_grace.set()
                return await asyncio.gather(first, second)

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            results = asyncio.run(scenario())

        self.assertEqual(
            [result["relay_port"] for result in results],
            [40041, 40041],
        )
        launcher.start_new_relay.assert_called_once_with(4)
        self.assertEqual(room.relay_port, 40041)

    def test_concurrent_ensure_room_relay_starts_only_one_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=5)
        launcher = MagicMock()
        launcher.start_new_relay.return_value = (40042, 12042, [])
        launcher.is_relay_running.return_value = True
        real_sleep = asyncio.sleep

        async def scenario() -> list[dict]:
            grace_entered = asyncio.Event()
            release_grace = asyncio.Event()

            async def gated_grace(_delay: float) -> None:
                grace_entered.set()
                await release_grace.wait()

            with patch.object(lobby_main.asyncio, "sleep", new=gated_grace):
                first = asyncio.create_task(lobby_main._ensure_room_relay(room))
                await grace_entered.wait()
                second = asyncio.create_task(lobby_main._ensure_room_relay(room))
                await real_sleep(0)
                release_grace.set()
                return await asyncio.gather(first, second)

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            results = asyncio.run(scenario())

        self.assertEqual(
            [result["relay_port"] for result in results],
            [40042, 40042],
        )
        launcher.start_new_relay.assert_called_once_with(5)

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

    def test_launcher_port_reservations_are_unique_across_threads(self) -> None:
        launcher = RelayLauncher()
        with ThreadPoolExecutor(max_workers=2) as executor:
            ports = list(executor.map(lambda _index: launcher.allocate_port(), range(2)))

        self.assertEqual(len(set(ports)), 2)
        for port in ports:
            self.assertIsNotNone(port)
            assert port is not None
            self.assertTrue(launcher.release_port(port))

    def test_launcher_start_failure_releases_reserved_port(self) -> None:
        launcher = RelayLauncher()
        first_port = launcher.allocate_port()
        self.assertIsNotNone(first_port)
        assert first_port is not None

        self.assertIsNone(launcher.start_relay(first_port, 1))
        self.assertEqual(launcher.allocate_port(), first_port)
        self.assertTrue(launcher.release_port(first_port))

    def test_launcher_same_reserved_port_spawns_at_most_once(self) -> None:
        launcher = RelayLauncher()
        port = launcher.allocate_port()
        self.assertIsNotNone(port)
        assert port is not None
        process = MagicMock()
        process.pid = 14001

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
            patch("builtins.open", mock_open()),
            patch(
                "relay_servers.lobby_api.relay_launcher.subprocess.Popen",
                return_value=process,
            ) as popen,
        ):
            with ThreadPoolExecutor(max_workers=2) as executor:
                results = list(
                    executor.map(
                        lambda _index: launcher.start_relay(port, 4),
                        range(2),
                    )
                )

        self.assertCountEqual(results, [14001, None])
        popen.assert_called_once()

    def test_launcher_reuses_dead_relay_port_and_closes_logs(self) -> None:
        launcher = RelayLauncher()
        dead_process = MagicMock()
        dead_process.poll.return_value = 0
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = dead_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)

        self.assertEqual(launcher.allocate_port(), first_port)
        self.assertNotIn(first_port, launcher._processes)
        self.assertNotIn(first_port, launcher._log_files)
        stdout_file.close.assert_called_once_with()
        stderr_file.close.assert_called_once_with()
        self.assertTrue(launcher.release_port(first_port))

    def test_launcher_does_not_reuse_live_relay_port(self) -> None:
        launcher = RelayLauncher()
        live_process = MagicMock()
        live_process.poll.return_value = None
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = live_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)

        allocated_port = launcher.allocate_port()
        self.assertEqual(allocated_port, first_port + 1)
        self.assertIs(launcher._processes[first_port], live_process)
        stdout_file.close.assert_not_called()
        stderr_file.close.assert_not_called()
        assert allocated_port is not None
        self.assertTrue(launcher.release_port(allocated_port))

    def test_launcher_reap_is_idempotent(self) -> None:
        launcher = RelayLauncher()
        dead_process = MagicMock()
        dead_process.poll.return_value = 7
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = dead_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)

        self.assertEqual(launcher.reap_exited(), [first_port])
        self.assertEqual(launcher.reap_exited(), [])
        stdout_file.close.assert_called_once_with()
        stderr_file.close.assert_called_once_with()

    def test_list_and_join_reject_room_whose_relay_exited(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=4)
        room.relay_port = 40051
        room.relay_pid = 13051
        room.host_peer_id = 1
        room.status = RoomStatus.WAITING
        launcher = MagicMock()
        launcher.reap_exited.side_effect = [[40051], []]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            self.assertEqual(asyncio.run(lobby_main.list_rooms()), [])
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    lobby_main.join_room(
                        room.id,
                        JoinRoomRequest(player_name="Client"),
                    )
                )

        self.assertEqual(raised.exception.status_code, 404)
        self.assertIsNone(manager.get_room(room.id))

    def test_quick_match_skips_room_whose_relay_exited(self) -> None:
        manager = RoomManager()
        stale_room = self._create_room(manager, max_players=4)
        stale_room.relay_port = 40052
        stale_room.relay_pid = 13052
        stale_room.host_peer_id = 1
        stale_room.status = RoomStatus.WAITING
        healthy_room = manager.create_room(
            name="Healthy room",
            host_name="HealthyHost",
            host_ip="",
            max_players=4,
        )
        self.assertIsNotNone(healthy_room)
        assert healthy_room is not None
        healthy_room.relay_port = 40053
        healthy_room.relay_pid = 13053
        healthy_room.host_peer_id = 1
        healthy_room.status = RoomStatus.WAITING
        launcher = MagicMock()
        launcher.reap_exited.return_value = [40052]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="QuickClient",
                        game_mode=GameMode.STANDARD,
                    )
                )
            )

        self.assertEqual(result["room_id"], healthy_room.id)
        self.assertEqual(
            result["member_token"],
            healthy_room.players["QuickClient"].member_token,
        )
        self.assertIsNone(manager.get_room(stale_room.id))
        self.assertIn("QuickClient", healthy_room.players)

    def test_periodic_cleanup_reconciles_exited_relay_rooms(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=4)
        room.relay_port = 40054
        room.relay_pid = 13054
        launcher = MagicMock()
        launcher.reap_exited.return_value = [40054]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            lobby_main._cleanup_once()

        self.assertIsNone(manager.get_room(room.id))

    def test_failed_startup_closes_room_and_stops_spawned_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=4)
        launcher = MagicMock()
        launcher.start_new_relay.return_value = (40055, 13055, [])
        launcher.is_relay_running.return_value = False

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(lobby_main._ensure_room_relay(room))

        self.assertEqual(raised.exception.status_code, 500)
        self.assertIsNone(manager.get_room(room.id))
        launcher.stop_relay.assert_called_once_with(40055)

    def test_relay_project_uses_capacity_argument_and_protocol_v47(self) -> None:
        relay_source = (
            Path(__file__).resolve().parents[1]
            / "relay_godot_project"
            / "relay_server.gd"
        ).read_text(encoding="utf-8")

        self.assertIn("const PROTOCOL_VERSION := 47", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 46", relay_source)
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
