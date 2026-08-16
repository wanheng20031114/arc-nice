from __future__ import annotations

import asyncio
import os
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, mock_open, patch

from fastapi import HTTPException, Request

os.environ.setdefault(
    "ACQUISITION_CAPABILITY_HMAC_SECRET",
    "test-only-acquisition-hmac-secret-32-bytes-minimum",
)

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api import config
from relay_servers.lobby_api.main import (
    HostTokenRequest,
    JoinRoomRequest,
    LeaveRoomRequest,
    UpdateRoomRequest,
)
from relay_servers.lobby_api.models import GameMode, RoomStatus
from relay_servers.lobby_api.relay_launcher import RelayLauncher, RelayProcessLease
from relay_servers.lobby_api.room_manager import (
    ExpiredRoom,
    RoomExpirationReason,
    RoomManager,
    RoomTerminationGrant,
)


class ManualClock:
    """不依赖 wall clock 的确定性单调测试时钟。"""

    def __init__(self, initial: float = 0.0) -> None:
        self.now = initial

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        if seconds < 0:
            raise ValueError("测试时钟不能倒退")
        self.now += seconds


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
            "client": ("198.51.100.52", 12345),
            "server": ("testserver", 80),
        }
    )


class RoomLifecycleLeaseTests(unittest.TestCase):
    def setUp(self) -> None:
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

    def _create_attached_room(
        self,
        manager: RoomManager,
        *,
        instance_id: int = 11,
    ):
        room = manager.create_room(
            name="Lease room",
            host_name="Host",
            host_ip="",
        )
        self.assertIsNotNone(room)
        assert room is not None
        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        assert grant is not None
        self.assertTrue(
            manager.attach_relay(grant, 40011, 12011, instance_id)
        )
        return room

    def test_only_host_heartbeat_renews_idle_deadline(self) -> None:
        clock = ManualClock()
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=180.0,
            game_max_duration_seconds=1000.0,
        )
        room = self._create_attached_room(manager)
        self.assertIsNone(room.idle_deadline)

        self.assertIsNotNone(
            manager.mark_host_ready(room.id, room.host_token, 1)
        )
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token
        self.assertEqual(
            manager.leave_room(room.id, "Member", member_token),
            (True, None),
        )
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.RELAY,
                room.host_token,
            )
        )
        self.assertIsNone(room.idle_deadline)
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.IN_GAME,
                room.host_token,
            )
        )
        initial_deadline = room.idle_deadline
        self.assertEqual(initial_deadline, 180.0)

        clock.advance(60.0)
        # 重复状态包只能幂等，不能冒充 heartbeat 延租。
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.IN_GAME,
                room.host_token,
            )
        )
        self.assertEqual(room.idle_deadline, initial_deadline)
        self.assertIsNone(
            manager.keep_room_alive(
                room.id,
                room.host_token,
                room.relay_port,
                room.relay_instance_id + 1,
            )
        )
        self.assertEqual(room.idle_deadline, initial_deadline)
        self.assertIs(
            manager.keep_room_alive(
                room.id,
                room.host_token,
                room.relay_port,
                room.relay_instance_id,
            ),
            room,
        )
        self.assertEqual(room.idle_deadline, 240.0)

    def test_http_keepalive_checks_exact_live_relay_before_touch(self) -> None:
        clock = ManualClock()
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=180.0,
            game_max_duration_seconds=1000.0,
        )
        room = self._create_attached_room(manager, instance_id=17)
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.IN_GAME,
                room.host_token,
            )
        )
        clock.advance(60.0)
        launcher = MagicMock()
        launcher.reap_exited.return_value = []
        launcher.is_relay_running.return_value = False

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    lobby_main.keep_room_alive(
                        room.id,
                        HostTokenRequest(host_token=room.host_token),
                    )
                )
            self.assertEqual(room.idle_deadline, 180.0)

            launcher.is_relay_running.return_value = True
            response = asyncio.run(
                lobby_main.keep_room_alive(
                    room.id,
                    HostTokenRequest(host_token=room.host_token),
                )
            )

        self.assertEqual(raised.exception.status_code, 503)
        self.assertEqual(response, {"status": "ok", "relay_running": True})
        self.assertEqual(room.idle_deadline, 240.0)
        launcher.is_relay_running.assert_called_with(40011, 17)

    def test_room_without_heartbeat_expires_on_idle_deadline(self) -> None:
        clock = ManualClock(100.0)
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=180.0,
            game_max_duration_seconds=1000.0,
        )
        room = self._create_attached_room(manager)
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.IN_GAME,
                room.host_token,
            )
        )

        clock.advance(179.999)
        self.assertEqual(manager.cleanup_expired_rooms(), [])
        clock.advance(0.001)
        self.assertEqual(
            manager.cleanup_expired_rooms(),
            [
                ExpiredRoom(
                    room=room,
                    reason=RoomExpirationReason.IDLE_LEASE_EXPIRED,
                )
            ],
        )

    def test_active_heartbeat_cannot_cross_absolute_deadline(self) -> None:
        clock = ManualClock()
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=100.0,
            game_max_duration_seconds=250.0,
        )
        room = self._create_attached_room(manager)
        self.assertTrue(
            manager.update_room_status(
                room.id,
                RoomStatus.IN_GAME,
                room.host_token,
            )
        )

        for target in (60.0, 120.0, 180.0, 240.0):
            clock.advance(target - clock.now)
            self.assertIsNotNone(
                manager.keep_room_alive(
                    room.id,
                    room.host_token,
                    room.relay_port,
                    room.relay_instance_id,
                )
            )
        self.assertEqual(room.idle_deadline, room.absolute_deadline)

        clock.advance(10.0)
        self.assertIsNone(
            manager.keep_room_alive(
                room.id,
                room.host_token,
                room.relay_port,
                room.relay_instance_id,
            )
        )
        # 任意入口命中绝对期限都会在同一锁内立即终结，不等待下一轮扫描。
        self.assertEqual(manager.cleanup_expired_rooms(), [])
        self.assertEqual(
            manager.drain_termination_grants()[0].reason,
            RoomExpirationReason.ABSOLUTE_LIFETIME_EXPIRED,
        )

    def test_reaped_old_generation_does_not_close_rebound_room(self) -> None:
        manager = RoomManager()
        room = self._create_attached_room(manager, instance_id=22)

        removed = manager.reconcile_reaped_relays([(40011, 21)])

        self.assertEqual(removed, [])
        self.assertIs(manager.get_room(room.id), room)

    def test_waiting_room_survives_beyond_in_game_idle_window(self) -> None:
        clock = ManualClock()
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=180.0,
            game_max_duration_seconds=1000.0,
        )
        room = self._create_attached_room(manager)
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 1))

        clock.advance(181.0)

        self.assertEqual(manager.cleanup_expired_rooms(), [])
        self.assertIs(manager.get_room(room.id), room)
        self.assertIsNone(room.idle_deadline)

    def test_deadline_is_enforced_by_every_publication_entry_point(self) -> None:
        """绝对期限命中后，列表、加入、状态、挂接和请求均不能再发布房间。"""

        def new_manager() -> tuple[ManualClock, RoomManager]:
            clock = ManualClock()
            return clock, RoomManager(
                clock=clock,
                room_idle_timeout_seconds=2.0,
                game_max_duration_seconds=5.0,
            )

        clock, manager = new_manager()
        listed_room = self._create_attached_room(manager)
        self.assertIsNotNone(
            manager.mark_host_ready(listed_room.id, listed_room.host_token, 1)
        )
        clock.advance(5.0)
        self.assertEqual(manager.list_joinable_rooms(), [])
        self.assertIsNone(manager.get_room(listed_room.id))

        clock, manager = new_manager()
        joined_room = self._create_attached_room(manager)
        self.assertIsNotNone(
            manager.mark_host_ready(joined_room.id, joined_room.host_token, 1)
        )
        clock.advance(5.0)
        self.assertIsNone(
            manager.join_room(joined_room.id, "Late", GameMode.STANDARD)
        )

        clock, manager = new_manager()
        status_room = self._create_attached_room(manager)
        clock.advance(5.0)
        self.assertFalse(
            manager.update_room_status(
                status_room.id,
                RoomStatus.IN_GAME,
                status_room.host_token,
            )
        )
        self.assertIsNone(
            manager.mark_host_ready(status_room.id, status_room.host_token, 1)
        )

        clock, manager = new_manager()
        attaching_room = manager.create_room("Attach", "Host", "")
        assert attaching_room is not None
        grant = manager.begin_relay_start(
            attaching_room.id,
            attaching_room.host_token,
        )
        assert grant is not None
        clock.advance(5.0)
        self.assertFalse(manager.attach_relay(grant, 40021, 12021, 21))
        self.assertIsNone(manager.get_room(attaching_room.id))

        clock, manager = new_manager()
        requested_room = manager.create_room("Request", "Host", "")
        assert requested_room is not None
        clock.advance(5.0)
        launcher = MagicMock()
        launcher.reap_exited.return_value = []
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            self.assertRaises(HTTPException) as raised,
        ):
            asyncio.run(
                lobby_main.request_relay(
                    requested_room.id,
                    HostTokenRequest(host_token=requested_room.host_token),
                )
            )
        self.assertEqual(raised.exception.status_code, 404)
        launcher.start_new_relay.assert_not_called()

    def test_patch_closed_terminally_removes_room_and_stops_exact_relay(self) -> None:
        manager = RoomManager()
        room = self._create_attached_room(manager, instance_id=27)
        launcher = MagicMock()
        launcher.reap_exited.return_value = []
        launcher.stop_relay.return_value = True

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            response = asyncio.run(
                lobby_main.update_room(
                    room.id,
                    UpdateRoomRequest(
                        status=RoomStatus.CLOSED.value,
                        host_token=room.host_token,
                    ),
                )
            )

        self.assertEqual(response, {"status": "ok"})
        self.assertIsNone(manager.get_room(room.id))
        self.assertFalse(
            manager.update_room_status(
                room.id,
                RoomStatus.WAITING,
                room.host_token,
            )
        )
        launcher.stop_relay.assert_called_once_with(40011, 27)

    def test_termination_handoff_exception_requeues_immutable_grant(self) -> None:
        manager = RoomManager()
        room = self._create_attached_room(manager, instance_id=29)
        self.assertIsNotNone(manager.destroy_room(room.id, room.host_token))
        launcher = MagicMock()
        launcher.stop_relay.side_effect = [RuntimeError("handoff failed"), True]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            lobby_main._flush_room_termination_grants()
            lobby_main._flush_room_termination_grants()

        self.assertEqual(launcher.stop_relay.call_count, 2)
        launcher.stop_relay.assert_called_with(40011, 29)
        self.assertEqual(manager.drain_termination_grants(), [])

    def test_async_leave_does_not_block_event_loop_during_process_wait(self) -> None:
        manager = RoomManager()
        room = self._create_attached_room(manager, instance_id=33)
        launcher = MagicMock()
        launcher.reap_exited.return_value = []
        stop_entered = threading.Event()
        release_stop = threading.Event()
        released_in_time: list[bool] = []

        def slow_stop(_port: int, _instance_id: int) -> bool:
            stop_entered.set()
            released = release_stop.wait(timeout=1.0)
            released_in_time.append(released)
            return released

        launcher.stop_relay.side_effect = slow_stop

        async def scenario() -> dict:
            task = asyncio.create_task(
                lobby_main.leave_room(
                    room.id,
                    LeaveRoomRequest(
                        player_name=room.host_name,
                        member_token=room.players[room.host_name].member_token,
                    ),
                )
            )
            entered = await asyncio.to_thread(stop_entered.wait, 1.0)
            self.assertTrue(entered)
            self.assertFalse(task.done())
            release_stop.set()
            return await task

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            response = asyncio.run(scenario())

        self.assertEqual(response, {"status": "ok"})
        self.assertEqual(released_in_time, [True])

    def test_relay_restart_uses_room_absolute_remaining_lifetime(self) -> None:
        clock = ManualClock()
        manager = RoomManager(
            clock=clock,
            room_idle_timeout_seconds=20.0,
            game_max_duration_seconds=100.0,
        )
        room = self._create_attached_room(manager, instance_id=41)
        clock.advance(40.0)
        launcher = MagicMock()
        old_lease = RelayProcessLease(40011, 12011, 41)
        new_lease = RelayProcessLease(40011, 12042, 42)
        launcher.is_relay_running.side_effect = [False, False, True]
        launcher.reap_exited.side_effect = [[old_lease], []]
        launcher.start_new_relay.return_value = (40011, new_lease, [])

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
        ):
            response = asyncio.run(
                lobby_main.request_relay(
                    room.id,
                    HostTokenRequest(host_token=room.host_token),
                )
            )

        self.assertEqual(response["relay_port"], 40011)
        max_clients, max_lifetime = launcher.start_new_relay.call_args.args
        self.assertEqual(max_clients, room.max_players)
        self.assertEqual(max_lifetime, 60.0)
        self.assertEqual(room.relay_instance_id, 42)

    def test_inflight_start_task_is_never_shared_with_wrong_host_token(self) -> None:
        manager = RoomManager()
        room = manager.create_room("Auth", "Host", "")
        assert room is not None
        launcher = MagicMock()
        lease = RelayProcessLease(40045, 12045, 45)
        launcher.start_new_relay.return_value = (40045, lease, [])
        launcher.is_relay_running.return_value = True
        real_sleep = asyncio.sleep

        async def scenario() -> dict:
            grace_entered = asyncio.Event()
            release_grace = asyncio.Event()

            async def gated_grace(_delay: float) -> None:
                grace_entered.set()
                await release_grace.wait()

            with patch.object(lobby_main.asyncio, "sleep", new=gated_grace):
                valid_task = asyncio.create_task(
                    lobby_main.request_relay(
                        room.id,
                        HostTokenRequest(host_token=room.host_token),
                    )
                )
                await grace_entered.wait()
                try:
                    with self.assertRaises(HTTPException) as raised:
                        await asyncio.wait_for(
                            lobby_main.request_relay(
                                room.id,
                                HostTokenRequest(host_token="wrong-token"),
                            ),
                            timeout=0.2,
                        )
                    self.assertEqual(raised.exception.status_code, 404)
                finally:
                    release_grace.set()
                await real_sleep(0)
                return await valid_task

        lobby_main._relay_start_tasks.clear()
        try:
            with (
                patch.object(lobby_main, "room_mgr", manager),
                patch.object(lobby_main, "relay_launcher", launcher),
            ):
                response = asyncio.run(scenario())
        finally:
            lobby_main._relay_start_tasks.clear()

        self.assertEqual(response["relay_port"], 40045)
        launcher.start_new_relay.assert_called_once()

    def test_destroy_during_spawn_prevents_attach_and_stops_child(self) -> None:
        manager = RoomManager()
        room = manager.create_room("Cancel", "Host", "")
        assert room is not None
        launcher = MagicMock()
        launcher.reap_exited.return_value = []
        launcher.is_relay_running.return_value = True
        spawn_entered = threading.Event()
        release_spawn = threading.Event()
        lease = RelayProcessLease(40046, 12046, 46)

        def gated_start(
            _max_clients: int,
            _max_lifetime_seconds: float,
        ) -> tuple[int, RelayProcessLease, list[RelayProcessLease]]:
            spawn_entered.set()
            self.assertTrue(release_spawn.wait(timeout=2.0))
            return 40046, lease, []

        launcher.start_new_relay.side_effect = gated_start

        async def scenario() -> tuple[dict, HTTPException]:
            start_task = asyncio.create_task(
                lobby_main.request_relay(
                    room.id,
                    HostTokenRequest(host_token=room.host_token),
                )
            )
            self.assertTrue(
                await asyncio.to_thread(spawn_entered.wait, 2.0)
            )
            destroyed = await lobby_main.destroy_room(
                room.id,
                HostTokenRequest(host_token=room.host_token),
            )
            release_spawn.set()
            try:
                await start_task
            except HTTPException as exc:
                return destroyed, exc
            self.fail("销毁后的在途 Relay 不得成功 attach")

        lobby_main._relay_start_tasks.clear()
        try:
            with (
                patch.object(lobby_main, "room_mgr", manager),
                patch.object(lobby_main, "relay_launcher", launcher),
                patch.object(lobby_main.asyncio, "sleep", new=AsyncMock()),
            ):
                destroyed, start_error = asyncio.run(scenario())
        finally:
            release_spawn.set()
            lobby_main._relay_start_tasks.clear()

        self.assertEqual(destroyed, {"status": "ok"})
        self.assertEqual(start_error.status_code, 404)
        self.assertIsNone(manager.get_room(room.id))
        launcher.stop_relay.assert_called_once_with(40046, 46)
        launcher.acknowledge_reaped.assert_called_once_with(lease)

    def test_reaped_port_is_quarantined_until_old_room_is_reconciled(self) -> None:
        manager = RoomManager()
        room = self._create_attached_room(manager, instance_id=51)
        room.relay_port = config.RELAY_PORT_START
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 1))
        launcher = RelayLauncher()
        process = MagicMock()
        process.pid = 12011
        process.poll.return_value = 7
        self._register_launcher_process_for_room(
            launcher,
            room.relay_port,
            room.relay_instance_id,
            process,
        )
        dead_lease = RelayProcessLease(config.RELAY_PORT_START, 12011, 51)

        self.assertEqual(launcher.reap_exited(), [dead_lease])
        # Room 对账尚未确认前，即使端口物理上已空闲也不能被 B 房复用。
        self.assertIsNone(launcher.allocate_port())

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
            self.assertRaises(HTTPException) as raised,
        ):
            asyncio.run(
                lobby_main.join_room(
                    room.id,
                    JoinRoomRequest(player_name="Late"),
                    direct_request(),
                )
            )

        self.assertEqual(raised.exception.status_code, 404)
        self.assertIsNone(manager.get_room(room.id))
        self.assertEqual(launcher.allocate_port(), config.RELAY_PORT_START)
        self.assertTrue(launcher.release_port(config.RELAY_PORT_START))

    @staticmethod
    def _register_launcher_process_for_room(
        launcher: RelayLauncher,
        port: int,
        instance_id: int,
        process: MagicMock,
    ) -> None:
        launcher._processes[port] = process
        launcher._log_files[port] = (MagicMock(), MagicMock())
        launcher._instance_ids[port] = instance_id

    def test_cleanup_phases_and_room_stops_isolate_exceptions(self) -> None:
        manager = MagicMock()
        first_room = MagicMock(
            id="first",
            name="First",
            relay_port=40031,
            relay_instance_id=31,
        )
        second_room = MagicMock(
            id="second",
            name="Second",
            relay_port=40032,
            relay_instance_id=32,
        )
        manager.cleanup_expired_rooms.return_value = [
            ExpiredRoom(first_room, RoomExpirationReason.IDLE_LEASE_EXPIRED),
            ExpiredRoom(second_room, RoomExpirationReason.IDLE_LEASE_EXPIRED),
        ]
        manager.drain_termination_grants.return_value = [
            RoomTerminationGrant(
                "first",
                "First",
                40031,
                13031,
                31,
                RoomExpirationReason.IDLE_LEASE_EXPIRED,
            ),
            RoomTerminationGrant(
                "second",
                "Second",
                40032,
                13032,
                32,
                RoomExpirationReason.IDLE_LEASE_EXPIRED,
            ),
        ]
        launcher = MagicMock()
        launcher.reap_exited.side_effect = RuntimeError("reap failed")
        launcher.stop_relay.side_effect = [RuntimeError("stop failed"), True]

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "relay_launcher", launcher),
        ):
            lobby_main._cleanup_once()

        manager.cleanup_expired_rooms.assert_called_once_with()
        self.assertEqual(launcher.stop_relay.call_count, 2)


class RelayLauncherLeaseTests(unittest.TestCase):
    def _register_process(
        self,
        launcher: RelayLauncher,
        port: int,
        instance_id: int,
        process: MagicMock,
    ) -> tuple[MagicMock, MagicMock]:
        process.pid = 15000 + instance_id
        stdout_file = MagicMock()
        stderr_file = MagicMock()
        launcher._processes[port] = process
        launcher._log_files[port] = (stdout_file, stderr_file)
        launcher._instance_ids[port] = instance_id
        return stdout_file, stderr_file

    def test_delayed_old_stop_cannot_terminate_reused_port(self) -> None:
        launcher = RelayLauncher()
        port = lobby_main.config.RELAY_PORT_START
        new_process = MagicMock()
        new_process.poll.return_value = None
        self._register_process(launcher, port, 2, new_process)

        self.assertFalse(launcher.stop_relay(port, 1))
        new_process.terminate.assert_not_called()
        new_process.kill.assert_not_called()
        self.assertIs(launcher._processes[port], new_process)

    def test_failed_stop_keeps_process_identity_and_port_reserved(self) -> None:
        launcher = RelayLauncher()
        port = lobby_main.config.RELAY_PORT_START
        process = MagicMock()
        process.poll.return_value = None
        process.terminate.side_effect = RuntimeError("term failed")
        process.kill.side_effect = RuntimeError("kill failed")
        stdout_file, stderr_file = self._register_process(
            launcher,
            port,
            3,
            process,
        )

        self.assertFalse(launcher.stop_relay(port, 3))

        self.assertIs(launcher._processes[port], process)
        self.assertEqual(launcher._instance_ids[port], 3)
        stdout_file.close.assert_not_called()
        stderr_file.close.assert_not_called()
        allocated = launcher.allocate_port()
        self.assertEqual(allocated, port + 1)
        assert allocated is not None
        self.assertTrue(launcher.release_port(allocated))

        process.poll.return_value = 0
        self.assertTrue(launcher.stop_relay(port, 3))
        self.assertNotIn(port, launcher._processes)
        lease = RelayProcessLease(port, process.pid, 3)
        self.assertIn(lease, launcher.reap_exited())
        self.assertTrue(launcher.acknowledge_reaped(lease))
        self.assertEqual(launcher.allocate_port(), port)

    def test_default_leases_cover_client_heartbeat_and_reconnect_windows(self) -> None:
        self.assertGreaterEqual(config.LOBBY_PORT, 1)
        self.assertLessEqual(config.LOBBY_PORT, 65535)
        self.assertGreaterEqual(config.RELAY_PORT_START, 1)
        self.assertLessEqual(config.RELAY_PORT_END, 65535)
        self.assertLessEqual(config.RELAY_PORT_START, config.RELAY_PORT_END)
        self.assertLessEqual(
            config.MAX_ROOMS,
            config.RELAY_PORT_END - config.RELAY_PORT_START + 1,
        )
        self.assertGreaterEqual(config.MAX_PLAYERS_PER_ROOM, 2)
        self.assertLessEqual(config.MAX_PLAYERS_PER_ROOM, 8)
        self.assertGreaterEqual(config.ROOM_IDLE_TIMEOUT_SECONDS, 120.0)
        self.assertGreater(config.RELAY_EMPTY_IDLE_TIMEOUT_SECONDS, 90.0)
        self.assertLess(
            config.CLEANUP_INTERVAL_SECONDS,
            config.ROOM_IDLE_TIMEOUT_SECONDS,
        )
        self.assertLess(
            config.ROOM_IDLE_TIMEOUT_SECONDS,
            config.GAME_MAX_DURATION_SECONDS,
        )
        self.assertLess(
            config.RELAY_STARTUP_GRACE_SECONDS,
            config.RELAY_STARTUP_IDLE_TIMEOUT_SECONDS,
        )
        self.assertLess(
            config.RELAY_STARTUP_IDLE_TIMEOUT_SECONDS,
            config.GAME_MAX_DURATION_SECONDS,
        )
        self.assertLess(
            config.RELAY_EMPTY_IDLE_TIMEOUT_SECONDS,
            config.GAME_MAX_DURATION_SECONDS,
        )

    def test_non_finite_timeout_configuration_is_rejected(self) -> None:
        for raw_value in ("nan", "inf", "-inf", "0", "-1"):
            with (
                self.subTest(raw_value=raw_value),
                patch.dict(os.environ, {"TEST_RELAY_TIMEOUT": raw_value}),
                self.assertRaises(ValueError),
            ):
                config._positive_seconds("TEST_RELAY_TIMEOUT", 1.0)

    def test_bounded_integer_configuration_is_rejected(self) -> None:
        for raw_value in ("not-an-int", "1.5", "0", "9"):
            with (
                self.subTest(raw_value=raw_value),
                patch.dict(os.environ, {"TEST_RELAY_INT": raw_value}),
                self.assertRaises(ValueError),
            ):
                config._bounded_int("TEST_RELAY_INT", 4, 2, 8)

        with patch.dict(os.environ, {"TEST_RELAY_INT": "8"}):
            self.assertEqual(config._bounded_int("TEST_RELAY_INT", 4, 2, 8), 8)

    def test_invalid_timeout_relationship_is_rejected(self) -> None:
        for lower, upper in ((1.0, 1.0), (2.0, 1.0)):
            with (
                self.subTest(lower=lower, upper=upper),
                self.assertRaises(ValueError),
            ):
                config._require_strict_order("LOWER", lower, "UPPER", upper)

    def test_launcher_rejects_non_finite_hard_lifetime(self) -> None:
        launcher = RelayLauncher()
        with patch(
            "relay_servers.lobby_api.relay_launcher.subprocess.Popen"
        ) as popen:
            for lifetime in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(lifetime=lifetime):
                    self.assertIsNone(
                        launcher.start_relay(
                            config.RELAY_PORT_START,
                            4,
                            lifetime,
                        )
                    )
        popen.assert_not_called()

    def test_relay_project_enforces_three_independent_monotonic_limits(self) -> None:
        relay_source = (
            Path(__file__).resolve().parents[1]
            / "relay_godot_project"
            / "relay_server.gd"
        ).read_text(encoding="utf-8")

        self.assertIn('arg.begins_with("--startup-idle-timeout=")', relay_source)
        self.assertIn('arg.begins_with("--empty-idle-timeout=")', relay_source)
        self.assertIn('arg.begins_with("--max-lifetime=")', relay_source)
        self.assertIn("var now_msec := Time.get_ticks_msec()", relay_source)
        self.assertIn(
            "_elapsed_seconds(_started_at_msec, now_msec) >= _max_lifetime_sec",
            relay_source,
        )
        self.assertNotIn('arg.begins_with("--idle-timeout=")', relay_source)
        self.assertNotIn("maxf(timeout_str.to_float()", relay_source)

    def test_reap_cannot_release_port_owned_by_concurrent_stop(self) -> None:
        launcher = RelayLauncher()
        port = lobby_main.config.RELAY_PORT_START
        process = MagicMock()
        process.poll.return_value = None
        wait_entered = threading.Event()
        release_wait = threading.Event()

        def gated_wait(timeout: float) -> int:
            self.assertEqual(timeout, 5)
            wait_entered.set()
            self.assertTrue(release_wait.wait(timeout=2.0))
            return 0

        process.wait.side_effect = gated_wait
        self._register_process(launcher, port, 4, process)

        with ThreadPoolExecutor(max_workers=1) as executor:
            stop_future = executor.submit(launcher.stop_relay, port, 4)
            self.assertTrue(wait_entered.wait(timeout=2.0))
            process.poll.return_value = 0
            self.assertEqual(launcher.reap_exited(), [])
            allocated = launcher.allocate_port()
            self.assertEqual(allocated, port + 1)
            assert allocated is not None
            self.assertTrue(launcher.release_port(allocated))
            release_wait.set()
            self.assertTrue(stop_future.result(timeout=2.0))

        self.assertNotIn(port, launcher._processes)
        lease = RelayProcessLease(port, process.pid, 4)
        self.assertEqual(launcher.reap_exited(), [lease])
        self.assertTrue(launcher.acknowledge_reaped(lease))
        self.assertEqual(launcher.allocate_port(), port)

    def test_failed_termination_is_retried_by_next_reap(self) -> None:
        launcher = RelayLauncher()
        port = config.RELAY_PORT_START
        process = MagicMock()
        process.poll.return_value = None
        process.terminate.side_effect = [RuntimeError("term failed"), None]
        process.kill.side_effect = RuntimeError("kill failed")
        self._register_process(launcher, port, 5, process)
        lease = RelayProcessLease(port, process.pid, 5)

        self.assertFalse(launcher.stop_relay(port, 5))
        self.assertIn(port, launcher._termination_requests)
        # 新一轮分配会先重试终止；成功后仍须留在 quarantine 等待 Room ack。
        self.assertIsNone(launcher.allocate_port())
        self.assertEqual(launcher.reap_exited(), [lease])
        self.assertEqual(process.terminate.call_count, 2)
        self.assertNotIn(port, launcher._processes)
        self.assertIsNone(launcher.allocate_port())
        self.assertTrue(launcher.acknowledge_reaped(lease))
        self.assertEqual(launcher.allocate_port(), port)

    def test_shutdown_cancels_process_that_finishes_starting_late(self) -> None:
        launcher = RelayLauncher()
        port = config.RELAY_PORT_START
        process = MagicMock()
        process.pid = 16001
        process.poll.return_value = None
        popen_entered = threading.Event()
        release_popen = threading.Event()

        def gated_popen(*_args, **_kwargs):
            popen_entered.set()
            self.assertTrue(release_popen.wait(timeout=2.0))
            return process

        with (
            patch(
                "relay_servers.lobby_api.relay_launcher.os.path.isfile",
                return_value=True,
            ),
            patch(
                "relay_servers.lobby_api.relay_launcher.os.path.isdir",
                return_value=True,
            ),
            patch("relay_servers.lobby_api.relay_launcher.os.makedirs"),
            patch("builtins.open", mock_open()),
            patch(
                "relay_servers.lobby_api.relay_launcher.subprocess.Popen",
                side_effect=gated_popen,
            ) as popen,
            ThreadPoolExecutor(max_workers=2) as executor,
        ):
            start_future = executor.submit(
                launcher.start_relay,
                port,
                4,
                100.0,
            )
            self.assertTrue(popen_entered.wait(timeout=2.0))
            stop_future = executor.submit(launcher.stop_all)
            try:
                shutdown_seen = False
                for _index in range(100):
                    with launcher._lock:
                        shutdown_seen = launcher._shutdown_requested
                    if shutdown_seen:
                        break
                    threading.Event().wait(0.001)
                self.assertTrue(shutdown_seen)
                self.assertFalse(stop_future.done())
            finally:
                release_popen.set()

            self.assertIsNone(start_future.result(timeout=2.0))
            stop_future.result(timeout=2.0)

        popen.assert_called_once()
        process.terminate.assert_called_once_with()
        self.assertEqual(launcher._processes, {})
        self.assertEqual(launcher._starting_ports, set())
        self.assertEqual(launcher._quarantined_leases, {})
        self.assertIsNone(launcher.allocate_port())

    def test_shutdown_retries_failed_stop_until_later_success(self) -> None:
        clock = ManualClock()
        launcher = RelayLauncher(clock=clock, sleeper=clock.advance)
        port = config.RELAY_PORT_START
        process = MagicMock()
        process.poll.return_value = None
        process.terminate.side_effect = [RuntimeError("term failed"), None]
        process.kill.side_effect = RuntimeError("kill failed")
        stdout_file, stderr_file = self._register_process(
            launcher,
            port,
            61,
            process,
        )

        remaining = launcher.stop_all(
            total_timeout_seconds=0.3,
            retry_backoff_seconds=0.1,
        )

        self.assertEqual(remaining, [])
        self.assertEqual(process.terminate.call_count, 2)
        self.assertNotIn(port, launcher._processes)
        self.assertNotIn(port, launcher._termination_requests)
        self.assertNotIn(port, launcher._quarantined_leases)
        stdout_file.close.assert_called_once_with()
        stderr_file.close.assert_called_once_with()

    def test_shutdown_returns_exact_leases_that_permanently_fail(self) -> None:
        clock = ManualClock()
        launcher = RelayLauncher(clock=clock, sleeper=clock.advance)
        port = config.RELAY_PORT_START
        process = MagicMock()
        process.poll.return_value = None
        process.terminate.side_effect = RuntimeError("term failed")
        process.kill.side_effect = RuntimeError("kill failed")
        stdout_file, stderr_file = self._register_process(
            launcher,
            port,
            62,
            process,
        )
        expected = RelayProcessLease(port, process.pid, 62)

        remaining = launcher.stop_all(
            total_timeout_seconds=0.25,
            retry_backoff_seconds=0.1,
        )

        self.assertEqual(remaining, [expected])
        self.assertAlmostEqual(clock.now, 0.25)
        self.assertGreaterEqual(process.terminate.call_count, 2)
        self.assertIs(launcher._processes[port], process)
        self.assertEqual(launcher._termination_requests[port], expected)
        self.assertNotIn(port, launcher._quarantined_leases)
        stdout_file.close.assert_not_called()
        stderr_file.close.assert_not_called()

    def test_lifespan_raises_when_shutdown_cannot_terminate_relay(self) -> None:
        launcher = MagicMock()
        lease = RelayProcessLease(config.RELAY_PORT_START, 17001, 71)
        launcher.stop_all.return_value = [lease]

        async def scenario() -> None:
            async with lobby_main.lifespan(lobby_main.app):
                pass

        with (
            patch.object(lobby_main, "relay_launcher", launcher),
            patch("builtins.print") as print_mock,
            self.assertRaises(RuntimeError) as raised,
        ):
            asyncio.run(scenario())

        self.assertIn("仍有 Relay 未能终止", str(raised.exception))
        rendered_logs = "\n".join(
            str(call.args[0])
            for call in print_mock.call_args_list
            if call.args
        )
        self.assertIn("严重错误", rendered_logs)
        self.assertNotIn("Relay 已全部终止", rendered_logs)


if __name__ == "__main__":
    unittest.main()
