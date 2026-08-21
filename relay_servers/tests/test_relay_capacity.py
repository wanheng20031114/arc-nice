from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import time
import unittest
from unittest.mock import AsyncMock, MagicMock, mock_open, patch

from fastapi import HTTPException, Request
from pydantic import ValidationError

os.environ.setdefault(
    "ACQUISITION_CAPABILITY_HMAC_SECRET",
    "test-only-acquisition-hmac-secret-32-bytes-minimum",
)

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import (
    HostTokenRequest,
    JoinRoomRequest,
    QuickMatchRequest,
)
from relay_servers.lobby_api.models import GameMode, RoomInfo, RoomStatus
from relay_servers.lobby_api.relay_launcher import (
    MAX_RELAY_CLIENTS,
    MIN_RELAY_CLIENTS,
    RelayLauncher,
    RelayProcessLease,
)
from relay_servers.lobby_api.room_manager import RoomManager


TEST_ROOM_ID = "room-under-test"
TEST_ADMISSION_SECRET = "s" * 43


def direct_request() -> Request:
    return Request(
        {
            "type": "http",
            "http_version": "1.1",
            "method": "POST",
            "scheme": "http",
            "path": "/",
            "raw_path": b"/",
            "query_string": b"",
            "headers": [],
            "client": ("198.51.100.51", 12345),
            "server": ("testserver", 80),
        }
    )


class RelayCapacityTests(unittest.TestCase):
    def setUp(self) -> None:
        lobby_main._relay_start_tasks.clear()
        self._legacy_patch = patch.object(
            lobby_main.config,
            "ALLOW_LEGACY_ACQUISITION_REQUESTS",
            True,
        )
        self._admission_patch = patch.object(
            lobby_main,
            "_consume_acquisition_admission",
            return_value=None,
        )
        self._legacy_patch.start()
        self._admission_patch.start()

    def tearDown(self) -> None:
        self._admission_patch.stop()
        self._legacy_patch.stop()
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

    def test_public_request_defaults_to_four_and_caps_at_eight(self) -> None:
        self.assertEqual(lobby_main.config.MIN_PLAYERS_PER_ROOM, 2)
        self.assertEqual(lobby_main.config.DEFAULT_PLAYERS_PER_ROOM, 4)
        self.assertEqual(lobby_main.config.MAX_PLAYERS_PER_ROOM, 8)
        self.assertEqual(lobby_main.config.PUBLIC_RELAY_MAX_PLAYERS, 8)
        self.assertEqual(RoomInfo().max_players, 4)
        default_room = RoomManager().create_room("Default", "Host", "")
        self.assertIsNotNone(default_room)
        assert default_room is not None
        self.assertEqual(default_room.max_players, 4)
        self.assertEqual(
            lobby_main.CreateRoomRequest(host_name="Host").max_players,
            4,
        )
        self.assertEqual(
            lobby_main.CreateRoomRequest(
                host_name="Host",
                max_players=8,
            ).max_players,
            8,
        )
        with self.assertRaises(ValidationError):
            lobby_main.CreateRoomRequest(host_name="Host", max_players=1)
        with self.assertRaises(ValidationError):
            lobby_main.CreateRoomRequest(host_name="Host", max_players=9)

        low_room = RoomManager().create_room(
            "Low",
            "LowHost",
            "",
            max_players=1,
        )
        high_room = RoomManager().create_room(
            "High",
            "HighHost",
            "",
            max_players=9,
        )
        self.assertIsNotNone(low_room)
        self.assertIsNotNone(high_room)
        assert low_room is not None and high_room is not None
        self.assertEqual(low_room.max_players, 2)
        self.assertEqual(high_room.max_players, 8)

    def test_eight_player_domain_room_can_start_a_public_relay(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=8)

        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        assert grant is not None
        self.assertEqual(grant.max_clients, 8)
        self.assertEqual(room.max_players, 8)
        self.assertEqual(room.status, RoomStatus.STARTING)

    def test_legacy_quick_match_auto_room_uses_four_player_default(self) -> None:
        manager = RoomManager()
        ensure_relay = AsyncMock(return_value={"status": "created"})

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "_ensure_room_relay", ensure_relay),
            patch.object(lobby_main, "_reconcile_exited_relays"),
        ):
            result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="QuickHost",
                        game_mode=GameMode.STANDARD,
                    ),
                    direct_request(),
                )
            )

        self.assertEqual(result, {"status": "created"})
        ensure_relay.assert_awaited_once()
        created_room_id = ensure_relay.await_args.args[0]
        created_room = manager.get_room(created_room_id)
        self.assertIsNotNone(created_room)
        assert created_room is not None
        self.assertEqual(created_room.max_players, 4)

    def test_acquisition_quick_match_auto_room_uses_four_player_default(
        self,
    ) -> None:
        manager = RoomManager()
        canonical_payload = ("QuickHost", GameMode.STANDARD.value)
        claim = manager.begin_quick_match_acquisition(
            "quick-default-capacity",
            canonical_payload,
            "QuickHost",
            GameMode.STANDARD,
            capability_expires_at=time.time() + 60.0,
        )

        self.assertIsNotNone(claim)
        assert claim is not None
        created_room = manager.get_room(claim.room_id)
        self.assertIsNotNone(created_room)
        assert created_room is not None
        self.assertEqual(created_room.max_players, 4)

    def test_ensure_room_relay_passes_public_eight_player_capacity(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=8)
        launcher = MagicMock()
        lease = RelayProcessLease(40031, 12031, 31)
        launcher.start_new_relay.return_value = (40031, lease, [])
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(
                lobby_main._ensure_room_relay(
                    room.id,
                    room.host_token,
                    room.host_name,
                )
            )

        start_args = launcher.start_new_relay.call_args.args
        self.assertEqual(start_args[0], 8)
        self.assertGreater(start_args[1], 0.0)
        self.assertEqual(start_args[2], room.id)
        self.assertEqual(start_args[3], room.admission_secret)
        self.assertEqual(result["max_players"], 8)
        self.assertEqual(result["relay_port"], 40031)
        self.assertEqual(
            result["member_token"],
            room.players[room.host_name].member_token,
        )

    def test_request_relay_passes_public_eight_player_capacity(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=8)
        launcher = MagicMock()
        lease = RelayProcessLease(40032, 12032, 32)
        launcher.start_new_relay.return_value = (40032, lease, [])
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

        start_args = launcher.start_new_relay.call_args.args
        self.assertEqual(start_args[0], 8)
        self.assertGreater(start_args[1], 0.0)
        self.assertEqual(start_args[2], room.id)
        self.assertEqual(start_args[3], room.admission_secret)
        self.assertEqual(
            set(result),
            {
                "room_id",
                "player_name",
                "role",
                "relay_ip",
                "relay_port",
                "host_peer_id",
                "relay_admission_ticket",
            },
        )
        self.assertEqual(result["relay_port"], 40032)
        self.assertEqual(result["room_id"], room.id)
        self.assertEqual(result["player_name"], room.host_name)
        self.assertEqual(result["role"], "host")
        self.assertEqual(result["host_peer_id"], 0)
        self.assertIn("relay_admission_ticket", result)

    def test_new_allocation_closes_room_owned_by_reaped_relay(self) -> None:
        manager = RoomManager()
        old_room = self._create_room(manager, max_players=2)
        old_room.relay_port = 40001
        old_room.relay_pid = 10001
        old_room.relay_instance_id = 1
        new_room = self._create_room(manager, max_players=2)
        launcher = MagicMock()
        new_lease = RelayProcessLease(40001, 10002, 2)
        old_lease = RelayProcessLease(40001, 10001, 1)
        launcher.reap_exited.return_value = [old_lease]
        launcher.start_new_relay.return_value = (40001, new_lease, [])
        launcher.is_relay_running.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            result = asyncio.run(
                lobby_main._ensure_room_relay(
                    new_room.id,
                    new_room.host_token,
                    new_room.host_name,
                )
            )

        self.assertIsNone(manager.get_room(old_room.id))
        self.assertEqual(manager.get_room(new_room.id), new_room)
        self.assertEqual(result["relay_port"], 40001)

    def test_relay_restart_keeps_current_room_when_reaping_its_port(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=2)
        room.relay_port = 40001
        room.relay_pid = 10001
        room.relay_instance_id = 1
        launcher = MagicMock()
        launcher.is_relay_running.side_effect = [False, False, True]
        new_lease = RelayProcessLease(40001, 10002, 2)
        old_lease = RelayProcessLease(40001, 10001, 1)
        launcher.reap_exited.side_effect = [[old_lease], []]
        launcher.start_new_relay.return_value = (40001, new_lease, [])

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
        self.assertEqual(room.relay_instance_id, 2)
        self.assertEqual(result["relay_port"], 40001)
        self.assertEqual(result["role"], "host")
        self.assertEqual(result["host_peer_id"], 0)
        self.assertIn("relay_admission_ticket", result)

    def test_concurrent_request_relay_starts_only_one_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=2)
        launcher = MagicMock()
        lease = RelayProcessLease(40041, 12041, 41)
        launcher.start_new_relay.return_value = (40041, lease, [])
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
        start_args = launcher.start_new_relay.call_args.args
        self.assertEqual(start_args[0], 2)
        self.assertGreater(start_args[1], 0.0)
        self.assertEqual(room.relay_port, 40041)

    def test_concurrent_ensure_room_relay_starts_only_one_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=2)
        launcher = MagicMock()
        lease = RelayProcessLease(40042, 12042, 42)
        launcher.start_new_relay.return_value = (40042, lease, [])
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
                    lobby_main._ensure_room_relay(
                        room.id,
                        room.host_token,
                        room.host_name,
                    )
                )
                await grace_entered.wait()
                second = asyncio.create_task(
                    lobby_main._ensure_room_relay(
                        room.id,
                        room.host_token,
                        room.host_name,
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
            [40042, 40042],
        )
        start_args = launcher.start_new_relay.call_args.args
        self.assertEqual(start_args[0], 2)
        self.assertGreater(start_args[1], 0.0)

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
            patch.dict(
                os.environ,
                {
                    "PATH": "relay-runtime-path",
                    "APPDATA": "relay-roaming-data",
                    "LOCALAPPDATA": "relay-local-data",
                    "LC_TEST": "relay-locale",
                    "ACQUISITION_CAPABILITY_HMAC_SECRET": "must-not-leak",
                    "DATABASE_URL": "must-not-leak-either",
                },
                clear=False,
            ),
        ):
            lease = launcher.start_relay(
                40033,
                8,
                room_id=TEST_ROOM_ID,
                admission_secret=TEST_ADMISSION_SECRET,
            )

        self.assertIsNotNone(lease)
        assert lease is not None
        self.assertEqual(lease.pid, 12345)
        command = popen.call_args.args[0]
        self.assertIn("--port=40033", command)
        self.assertIn("--max-clients=8", command)
        self.assertIn("--startup-idle-timeout=120.0", command)
        self.assertIn("--empty-idle-timeout=120.0", command)
        self.assertIn("--max-lifetime=36000.0", command)
        self.assertNotIn(TEST_ROOM_ID, command)
        self.assertNotIn(TEST_ADMISSION_SECRET, command)
        environment = popen.call_args.kwargs["env"]
        self.assertEqual(
            environment["ARC_NICE_RELAY_ROOM_ID"],
            TEST_ROOM_ID,
        )
        self.assertEqual(
            environment["ARC_NICE_RELAY_ADMISSION_SECRET"],
            TEST_ADMISSION_SECRET,
        )
        self.assertEqual(environment["PATH"], "relay-runtime-path")
        self.assertEqual(environment["APPDATA"], "relay-roaming-data")
        self.assertEqual(environment["LOCALAPPDATA"], "relay-local-data")
        self.assertEqual(environment["LC_TEST"], "relay-locale")
        self.assertNotIn("ACQUISITION_CAPABILITY_HMAC_SECRET", environment)
        self.assertNotIn("DATABASE_URL", environment)

    def test_launcher_rejects_capacity_outside_two_to_eight(self) -> None:
        launcher = RelayLauncher()
        self.assertEqual(MIN_RELAY_CLIENTS, 2)
        self.assertEqual(MAX_RELAY_CLIENTS, 8)
        with patch(
            "relay_servers.lobby_api.relay_launcher.subprocess.Popen"
        ) as popen:
            self.assertIsNone(launcher.start_relay(40034, 1))
            self.assertIsNone(launcher.start_relay(40034, 9))
        popen.assert_not_called()

    def test_launcher_fails_closed_without_room_admission_context(self) -> None:
        launcher = RelayLauncher()
        with patch(
            "relay_servers.lobby_api.relay_launcher.subprocess.Popen"
        ) as popen:
            self.assertIsNone(launcher.start_relay(40035, 2))
            self.assertIsNone(
                launcher.start_relay(
                    40035,
                    2,
                    room_id=TEST_ROOM_ID,
                    admission_secret="short",
                )
            )
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
                        lambda _index: launcher.start_relay(
                            port,
                            2,
                            room_id=TEST_ROOM_ID,
                            admission_secret=TEST_ADMISSION_SECRET,
                        ),
                        range(2),
                    )
                )

        leases = [result for result in results if result is not None]
        self.assertEqual(len(leases), 1)
        self.assertEqual(leases[0].pid, 14001)
        self.assertEqual(results.count(None), 1)
        popen.assert_called_once()

    def test_launcher_reuses_dead_relay_port_and_closes_logs(self) -> None:
        launcher = RelayLauncher()
        dead_process = MagicMock()
        dead_process.pid = 11001
        dead_process.poll.return_value = 0
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = dead_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)
        launcher._instance_ids[first_port] = 1

        dead_lease = RelayProcessLease(first_port, 11001, 1)
        self.assertEqual(launcher.reap_exited(), [dead_lease])
        self.assertIsNone(launcher.allocate_port())
        self.assertNotIn(first_port, launcher._processes)
        self.assertNotIn(first_port, launcher._log_files)
        stdout_file.close.assert_called_once_with()
        stderr_file.close.assert_called_once_with()
        self.assertTrue(launcher.acknowledge_reaped(dead_lease))
        self.assertEqual(launcher.allocate_port(), first_port)
        self.assertTrue(launcher.release_port(first_port))

    def test_launcher_does_not_reuse_live_relay_port(self) -> None:
        launcher = RelayLauncher()
        live_process = MagicMock()
        live_process.pid = 11002
        live_process.poll.return_value = None
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = live_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)
        launcher._instance_ids[first_port] = 2

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
        dead_process.pid = 11003
        dead_process.poll.return_value = 7
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        first_port = lobby_main.config.RELAY_PORT_START
        launcher._processes[first_port] = dead_process
        launcher._log_files[first_port] = (stdout_file, stderr_file)
        launcher._instance_ids[first_port] = 3

        dead_lease = RelayProcessLease(first_port, 11003, 3)
        self.assertEqual(launcher.reap_exited(), [dead_lease])
        # 未经 Room 对账确认时重复 reap 必须继续发布同一隔离项。
        self.assertEqual(launcher.reap_exited(), [dead_lease])
        self.assertTrue(launcher.acknowledge_reaped(dead_lease))
        self.assertTrue(launcher.acknowledge_reaped(dead_lease))
        self.assertEqual(launcher.reap_exited(), [])
        stdout_file.close.assert_called_once_with()
        stderr_file.close.assert_called_once_with()

    def test_list_and_join_reject_room_whose_relay_exited(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=2)
        room.relay_port = 40051
        room.relay_pid = 13051
        room.relay_instance_id = 51
        room.host_peer_id = 1
        room.status = RoomStatus.WAITING
        launcher = MagicMock()
        exited_lease = RelayProcessLease(40051, 13051, 51)
        launcher.reap_exited.side_effect = [[exited_lease], []]

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
                        direct_request(),
                    )
                )

        self.assertEqual(raised.exception.status_code, 404)
        self.assertIsNone(manager.get_room(room.id))

    def test_quick_match_skips_room_whose_relay_exited(self) -> None:
        manager = RoomManager()
        stale_room = self._create_room(manager, max_players=2)
        stale_room.relay_port = 40052
        stale_room.relay_pid = 13052
        stale_room.relay_instance_id = 52
        stale_room.host_peer_id = 1
        stale_room.status = RoomStatus.WAITING
        healthy_room = manager.create_room(
            name="Healthy room",
            host_name="HealthyHost",
            host_ip="",
            max_players=2,
        )
        self.assertIsNotNone(healthy_room)
        assert healthy_room is not None
        healthy_room.relay_port = 40053
        healthy_room.relay_pid = 13053
        healthy_room.relay_instance_id = 53
        healthy_room.host_peer_id = 1
        healthy_room.status = RoomStatus.WAITING
        launcher = MagicMock()
        launcher.reap_exited.return_value = [
            RelayProcessLease(40052, 13052, 52)
        ]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            result = asyncio.run(
                lobby_main.quick_match(
                    QuickMatchRequest(
                        player_name="QuickClient",
                        game_mode=GameMode.STANDARD,
                    ),
                    direct_request(),
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
        room = self._create_room(manager, max_players=2)
        room.relay_port = 40054
        room.relay_pid = 13054
        room.relay_instance_id = 54
        launcher = MagicMock()
        launcher.reap_exited.return_value = [
            RelayProcessLease(40054, 13054, 54)
        ]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            lobby_main._cleanup_once()

        self.assertIsNone(manager.get_room(room.id))

    def test_failed_startup_closes_room_and_stops_spawned_process(self) -> None:
        manager = RoomManager()
        room = self._create_room(manager, max_players=2)
        launcher = MagicMock()
        lease = RelayProcessLease(40055, 13055, 55)
        launcher.start_new_relay.return_value = (40055, lease, [])
        launcher.is_relay_running.return_value = False

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    lobby_main._ensure_room_relay(
                        room.id,
                        room.host_token,
                        room.host_name,
                    )
                )

        self.assertEqual(raised.exception.status_code, 500)
        self.assertIsNone(manager.get_room(room.id))
        launcher.stop_relay.assert_called_once_with(40055, 55)

    def test_relay_project_freezes_public_capacity_channels_and_protocol_v92(
        self,
    ) -> None:
        relay_root = Path(__file__).resolve().parents[1]
        project_root = relay_root.parent
        relay_source = (relay_root / "relay_godot_project" / "relay_server.gd").read_text(
            encoding="utf-8"
        )
        relay_peer_bytes = (
            relay_root
            / "relay_godot_project"
            / "authenticated_relay_multiplayer_peer.gd"
        ).read_bytes()
        relay_peer_source = relay_peer_bytes.decode("utf-8")
        game_relay_peer_bytes = (
            project_root
            / "scene"
            / "multiplayer"
            / "transport"
            / "authenticated_relay_multiplayer_peer.gd"
        ).read_bytes()
        net_manager_source = (
            project_root / "scene" / "multiplayer" / "net_manager.gd"
        ).read_text(encoding="utf-8")
        relay_stub_source = (
            relay_root / "relay_godot_project" / "relay_net_manager_stub.gd"
        ).read_text(encoding="utf-8")
        readme = (relay_root / "README.md").read_text(encoding="utf-8")
        export_presets = (project_root / "export_presets.cfg").read_text(
            encoding="utf-8"
        )

        self.assertEqual(game_relay_peer_bytes, relay_peer_bytes)
        self.assertIn("const PROTOCOL_VERSION := 92", relay_source)
        self.assertIn("const MAX_CLIENTS := 8", relay_source)
        self.assertIn("const CH_MEMBERSHIP := 8", relay_source)
        self.assertIn(
            "const RELAY_CONTROL_CHANNEL := CH_MEMBERSHIP + 1", relay_source
        )
        self.assertIn(
            "const RELAY_SERVICE_CHANNEL := RELAY_CONTROL_CHANNEL",
            relay_source,
        )
        self.assertIn("const ENET_MAX_CHANNEL := RELAY_CONTROL_CHANNEL", relay_source)
        self.assertIn("const CHANNEL_COUNT := CH_MEMBERSHIP + 1", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 90", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 89", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 88", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 87", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 86", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 85", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 84", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 83", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 82", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 81", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 80", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 79", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 78", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 77", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 76", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 75", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 74", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 70", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 69", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 68", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 67", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 66", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 65", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 64", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 63", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 62", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 61", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 60", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 59", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 58", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 57", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 56", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 55", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 54", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 53", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 52", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 51", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 50", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 49", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 48", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 47", relay_source)
        self.assertNotIn("const PROTOCOL_VERSION := 46", relay_source)
        self.assertIn('arg.begins_with("--max-clients=")', relay_source)
        self.assertIn(
            "transport.create_server(_port, transport_capacity, ENET_MAX_CHANNEL)",
            relay_source,
        )
        self.assertIn("multiplayer.server_relay = false", relay_source)
        self.assertIn("extends MultiplayerPeerExtension", relay_peer_source)
        self.assertIn("const TOPOLOGY_CHANNEL := 9", relay_peer_source)
        self.assertIn(
            "const RELAY_SERVICE_CHANNEL := TOPOLOGY_CHANNEL", relay_peer_source
        )
        self.assertIn("func _is_server_relay_supported() -> bool:", relay_peer_source)
        self.assertIn("const AUTH_PENDING_RESERVE := MAX_CLIENTS", relay_source)
        self.assertIn(
            "multiplayer.peer_authenticating.connect(_on_peer_authenticating)",
            relay_source,
        )
        self.assertIn("has_authenticated_room_capacity(", relay_source)
        self.assertIn(
            "parsed_max_clients < MIN_CLIENTS or parsed_max_clients > MAX_CLIENTS",
            relay_source,
        )
        for service_rpc in (
            "_rpc_relay_player_registration_forward",
            "_rpc_relay_kick_peer",
            "_rpc_relay_identity_lookup",
            "_rpc_relay_identity_result",
        ):
            with self.subTest(service_rpc=service_rpc):
                self.assertRegex(
                    relay_stub_source,
                    rf'@rpc\([^\n]*"reliable", 9\)\s+func {service_rpc}\(',
                )
        for membership_rpc in (
            "_rpc_registration_accepted",
            "_rpc_content_rejected",
            "_rpc_protocol_rejected",
            "_rpc_join_rejected",
            "_rpc_sync_player_list",
        ):
            with self.subTest(membership_rpc=membership_rpc):
                self.assertRegex(
                    relay_stub_source,
                    rf'@rpc\([^\n]*"reliable", 8\)\s+func {membership_rpc}\(',
                )
        self.assertIn("最小 2 人、默认 4 人、最大 8 人", readme)
        self.assertIn("`CH_MEMBERSHIP=8`", readme)
        self.assertIn("`CHANNEL_COUNT=9`", readme)
        self.assertIn("`RELAY_CONTROL_CHANNEL=9`", readme)
        self.assertIn("`RELAY_SERVICE_CHANNEL=9`", readme)
        self.assertIn("`ENET_MAX_CHANNEL=9`", readme)
        self.assertIn(
            '"res://scene/multiplayer/transport/'
            'authenticated_relay_multiplayer_peer.gd"',
            net_manager_source,
        )
        self.assertNotIn(
            '"res://relay_servers/relay_godot_project/'
            'authenticated_relay_multiplayer_peer.gd"',
            net_manager_source,
        )
        self.assertIn('include_filter="resources/font/*.txt"', export_presets)
        self.assertIn("relay_servers/*", export_presets)
        self.assertNotIn(
            "relay_servers/relay_godot_project/"
            "authenticated_relay_multiplayer_peer.gd",
            export_presets,
        )


if __name__ == "__main__":
    unittest.main()
