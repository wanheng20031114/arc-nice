"""创建/加入响应前的 acquisition 租约与并发顺序测试。"""

from __future__ import annotations

import asyncio
import os
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from fastapi import HTTPException, Request
from pydantic import ValidationError

os.environ.setdefault(
    "ACQUISITION_CAPABILITY_HMAC_SECRET",
    "test-only-acquisition-hmac-secret-32-bytes-minimum",
)

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.acquisition_security import AcquisitionCapabilitySigner
from relay_servers.lobby_api.models import GameMode
from relay_servers.lobby_api.room_manager import (
    AcquisitionCancelledError,
    AcquisitionCapacityError,
    AcquisitionClaimState,
    AcquisitionConflictError,
    AcquisitionReleaseResult,
    RoomManager,
)


class ManualClock:
    def __init__(self, now: float = 100.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def token(character: str) -> str:
    return character * 64


def direct_request(host: str = "198.51.100.10") -> Request:
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
            "client": (host, 12345),
            "server": ("testserver", 80),
        }
    )


def capability(action: str, payload: tuple[str, ...]) -> str:
    return lobby_main.acquisition_capability_signer.issue(action, payload).token


LIVE_CAPABILITY_EXPIRY = 145.0


class AcquisitionLeaseTests(unittest.TestCase):
    def new_manager(
        self,
        clock: ManualClock | None = None,
        capacity: int = 32,
    ) -> RoomManager:
        shared_clock = clock or ManualClock()
        return RoomManager(
            clock=shared_clock,
            capability_clock=shared_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=capacity,
        )

    def create_joinable_room(
        self,
        manager: RoomManager,
        max_players: int = 4,
    ):
        room = manager.create_room(
            "Room",
            "Host",
            "",
            max_players=max_players,
            game_mode=GameMode.STANDARD,
        )
        self.assertIsNotNone(room)
        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        self.assertTrue(manager.attach_relay(grant, 40001, 901, 1))
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 1))
        return room

    def test_http_capability_is_hidden_and_legacy_field_remains_optional(self) -> None:
        legacy = lobby_main.CreateRoomRequest(host_name="Legacy")
        self.assertIsNone(legacy.acquisition_token)
        signed = capability(
            "create",
            ("Protected 的房间", "Protected", "4", GameMode.STANDARD.value),
        )
        protected = lobby_main.CreateRoomRequest(
            host_name="Protected",
            acquisition_token=signed,
        )
        self.assertNotIn(signed, repr(protected))
        for invalid in ("", "a" * 257):
            with self.assertRaises(ValidationError):
                lobby_main.JoinRoomRequest(
                    player_name="Client",
                    acquisition_token=invalid,
                )

    def test_deployment_template_and_readme_publish_acquisition_contract(self) -> None:
        repo_root = Path(__file__).resolve().parents[2]
        deploy_source = (repo_root / "relay_servers/scripts/deploy.sh").read_text(
            encoding="utf-8"
        )
        readme_source = (repo_root / "relay_servers/README.md").read_text(
            encoding="utf-8"
        )
        start_source = (
            repo_root / "relay_servers/scripts/start_lobby.sh"
        ).read_text(encoding="utf-8")
        expected_defaults = {
            "ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS": "60",
            "ACQUISITION_TOMBSTONE_TTL_SECONDS": "120",
            "ACQUISITION_TOKEN_CAPACITY": "4096",
            "ACQUISITION_CAPABILITY_TTL_SECONDS": "45",
            "ALLOW_LEGACY_ACQUISITION_REQUESTS": "false",
            "ACQUISITION_ADMISSION_GLOBAL_BURST": "120",
            "ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND": "4.0",
            "ACQUISITION_ADMISSION_SOURCE_BURST": "8",
            "ACQUISITION_ADMISSION_SOURCE_REFILL_PER_SECOND": "0.5",
            "ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY": "4096",
            "ACQUISITION_ADMISSION_SOURCE_IDLE_TTL_SECONDS": "600",
        }
        for name, default in expected_defaults.items():
            self.assertIn(f"{name}={default}", deploy_source)
            self.assertIn(f"`{name}`", readme_source)
        self.assertIn("`/acquisitions/preflight`", readme_source)
        self.assertIn("`/acquisitions/confirm`", readme_source)
        self.assertIn("`/acquisitions/release`", readme_source)
        self.assertIn("滚动升级必须先部署服务端", readme_source)
        self.assertIn("openssl rand -hex 48", deploy_source)
        self.assertIn("chmod 600", deploy_source)
        self.assertIn("--workers 1", start_source)
        self.assertIn("--no-proxy-headers", start_source)
        self.assertIn("`--no-proxy-headers`", readme_source)
        self.assertIn("同锁 begin 紧前再次验签", readme_source)
        self.assertIn("单调保留 TTL", readme_source)
        self.assertIn('. "$ROOT_DIR/.env"', start_source)
        self.assertNotIn("xargs", start_source)
        self.assertNotIn(
            'echo "  ACQUISITION_CAPABILITY_HMAC_SECRET=',
            deploy_source,
        )

    def test_same_token_and_payload_freezes_one_idempotent_response(self) -> None:
        manager = self.new_manager()
        canonical = ("Room", "Host", "4", GameMode.STANDARD.value)
        first = manager.begin_create_acquisition(
            token("a"),
            canonical,
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertIsNotNone(first)
        self.assertEqual(first.state, AcquisitionClaimState.NEW)
        duplicate = manager.begin_create_acquisition(
            token("a"),
            canonical,
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(duplicate.state, AcquisitionClaimState.PENDING)
        frozen = manager.freeze_acquisition_response(
            token("a"),
            canonical,
            "203.0.113.1",
        )
        frozen["name"] = "caller mutation"
        replay = manager.begin_create_acquisition(
            token("a"),
            canonical,
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(replay.state, AcquisitionClaimState.FROZEN)
        self.assertEqual(replay.frozen_response["name"], "Room")
        self.assertNotEqual(replay.frozen_response["member_token"], token("a"))
        self.assertEqual(replay.frozen_response["acquisition_token"], token("a"))

    def test_same_token_rejects_different_payload_or_action(self) -> None:
        manager = self.new_manager()
        canonical = ("Room", "Host", "4", GameMode.STANDARD.value)
        claim = manager.begin_create_acquisition(
            token("b"),
            canonical,
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertIsNotNone(claim)
        with self.assertRaises(AcquisitionConflictError):
            manager.begin_create_acquisition(
                token("b"),
                ("Other", "Host", "4", GameMode.STANDARD.value),
                "Other",
                "Host",
                "",
                4,
                GameMode.STANDARD,
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            )
        with self.assertRaises(AcquisitionConflictError):
            manager.begin_join_acquisition(
                token("b"),
                (claim.room_id, "Host", GameMode.STANDARD.value),
                claim.room_id,
                "Host",
                GameMode.STANDARD,
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            )

    def test_join_and_quick_replays_never_duplicate_membership(self) -> None:
        join_manager = self.new_manager()
        join_room = self.create_joinable_room(join_manager)
        join_payload = (join_room.id, "Joiner", GameMode.STANDARD.value)
        first_join = join_manager.begin_join_acquisition(
            token("a"),
            join_payload,
            join_room.id,
            "Joiner",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(first_join.state, AcquisitionClaimState.NEW)
        join_manager.freeze_acquisition_response(
            token("a"), join_payload, "203.0.113.1"
        )
        replayed_join = join_manager.begin_join_acquisition(
            token("a"),
            join_payload,
            join_room.id,
            "Joiner",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(replayed_join.state, AcquisitionClaimState.FROZEN)
        self.assertEqual(join_manager.get_room(join_room.id).player_count, 2)

        quick_manager = self.new_manager()
        quick_room = self.create_joinable_room(quick_manager)
        quick_payload = ("Quick", GameMode.STANDARD.value)
        first_quick = quick_manager.begin_quick_match_acquisition(
            token("b"),
            quick_payload,
            "Quick",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(first_quick.state, AcquisitionClaimState.NEW)
        quick_manager.freeze_acquisition_response(
            token("b"), quick_payload, "203.0.113.1"
        )
        replayed_quick = quick_manager.begin_quick_match_acquisition(
            token("b"),
            quick_payload,
            "Quick",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(replayed_quick.state, AcquisitionClaimState.FROZEN)
        self.assertEqual(quick_manager.get_room(quick_room.id).player_count, 2)

    def test_cancel_before_commit_blocks_late_create(self) -> None:
        manager = self.new_manager()
        result = manager.release_acquisition(
            token("c"),
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertEqual(result, AcquisitionReleaseResult.TOMBSTONED_UNKNOWN)
        with self.assertRaises(AcquisitionCancelledError):
            manager.begin_create_acquisition(
                token("c"),
                ("Late", "Host", "4", GameMode.STANDARD.value),
                "Late",
                "Host",
                "",
                4,
                GameMode.STANDARD,
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            )

    def test_expired_capability_deadline_blocks_every_begin_action(self) -> None:
        monotonic_clock = ManualClock()
        capability_clock = ManualClock()
        manager = RoomManager(
            clock=monotonic_clock,
            capability_clock=capability_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        room = self.create_joinable_room(manager)
        expired_at = capability_clock.now

        with self.assertRaises(AcquisitionCancelledError):
            manager.begin_create_acquisition(
                token("7"),
                ("Expired", "Host2", "4", GameMode.STANDARD.value),
                "Expired",
                "Host2",
                "",
                4,
                GameMode.STANDARD,
                capability_expires_at=expired_at,
            )
        with self.assertRaises(AcquisitionCancelledError):
            manager.begin_join_acquisition(
                token("8"),
                (room.id, "ExpiredJoin", GameMode.STANDARD.value),
                room.id,
                "ExpiredJoin",
                GameMode.STANDARD,
                capability_expires_at=expired_at,
            )
        with self.assertRaises(AcquisitionCancelledError):
            manager.begin_quick_match_acquisition(
                token("9"),
                ("ExpiredQuick", GameMode.STANDARD.value),
                "ExpiredQuick",
                GameMode.STANDARD,
                capability_expires_at=expired_at,
            )

        self.assertEqual(len(manager._rooms), 1)
        self.assertEqual(set(manager.get_room(room.id).players), {"Host"})

    def test_cancel_after_commit_closes_host_and_invalidates_relay_cas(self) -> None:
        manager = self.new_manager()
        canonical = ("Room", "Host", "4", GameMode.STANDARD.value)
        claim = manager.begin_create_acquisition(
            token("d"),
            canonical,
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        grant = manager.begin_relay_start(claim.room_id, claim.host_token)
        self.assertIsNotNone(grant)
        self.assertEqual(
            manager.release_acquisition(
                token("d"),
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            ),
            AcquisitionReleaseResult.RELEASED,
        )
        self.assertIsNone(manager.get_room(claim.room_id))
        self.assertFalse(manager.attach_relay(grant, 40002, 902, 2))
        self.assertIsNone(manager.fail_relay_start(grant))
        self.assertEqual(
            manager.release_acquisition(
                token("d"),
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            ),
            AcquisitionReleaseResult.ALREADY_RELEASED,
        )

    def test_unconfirmed_membership_expires_but_confirmed_membership_survives(self) -> None:
        clock = ManualClock()
        manager = self.new_manager(clock)
        room = self.create_joinable_room(manager)
        first = manager.begin_join_acquisition(
            token("e"),
            (room.id, "First", GameMode.STANDARD.value),
            room.id,
            "First",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        second = manager.begin_join_acquisition(
            token("f"),
            (room.id, "Second", GameMode.STANDARD.value),
            room.id,
            "Second",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        first_response = manager.freeze_acquisition_response(
            token("e"),
            (room.id, "First", GameMode.STANDARD.value),
            "203.0.113.1",
        )
        # 冻结响应等价于客户端已经收到占位；尚未连上 Relay/confirm 仍属短租约。
        manager.freeze_acquisition_response(
            token("f"),
            (room.id, "Second", GameMode.STANDARD.value),
            "203.0.113.1",
        )
        self.assertTrue(
            manager.confirm_member_acquisition(
                room.id,
                "First",
                first_response["member_token"],
            )
        )
        clock.advance(61.0)
        live = manager.get_room(room.id)
        self.assertIn("First", live.players)
        self.assertNotIn("Second", live.players)
        with self.assertRaises(AcquisitionCancelledError):
            manager.begin_join_acquisition(
                token("f"),
                (room.id, "Second", GameMode.STANDARD.value),
                room.id,
                "Second",
                GameMode.STANDARD,
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            )

    def test_acquisition_release_removes_only_the_matching_member(self) -> None:
        manager = self.new_manager()
        room = self.create_joinable_room(manager)
        claim = manager.begin_join_acquisition(
            token("0"),
            (room.id, "Member", GameMode.STANDARD.value),
            room.id,
            "Member",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        self.assertIsNotNone(claim)
        response = manager.freeze_acquisition_response(
            token("0"),
            (room.id, "Member", GameMode.STANDARD.value),
            "203.0.113.1",
        )
        self.assertTrue(
            manager.confirm_member_acquisition(
                room.id,
                "Member",
                response["member_token"],
            )
        )
        self.assertEqual(
            manager.release_acquisition(
                token("0"),
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            ),
            AcquisitionReleaseResult.RELEASED,
        )
        live = manager.get_room(room.id)
        self.assertIsNotNone(live)
        self.assertNotIn("Member", live.players)
        self.assertIn("Host", live.players)

    def test_member_confirm_near_deadline_uses_exact_member_credentials(self) -> None:
        clock = ManualClock()
        manager = self.new_manager(clock)
        room = self.create_joinable_room(manager)
        valid_payload = (room.id, "Valid", GameMode.STANDARD.value)
        wrong_payload = (room.id, "Wrong", GameMode.STANDARD.value)
        manager.begin_join_acquisition(
            token("a"),
            valid_payload,
            room.id,
            "Valid",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        manager.begin_join_acquisition(
            token("b"),
            wrong_payload,
            room.id,
            "Wrong",
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        valid_response = manager.freeze_acquisition_response(
            token("a"), valid_payload, "203.0.113.1"
        )
        wrong_response = manager.freeze_acquisition_response(
            token("b"), wrong_payload, "203.0.113.1"
        )

        clock.advance(59.9)
        self.assertTrue(
            manager.confirm_member_acquisition(
                room.id,
                "Valid",
                valid_response["member_token"],
            )
        )
        # 正确秘密配错成员名也不能推进 provisional deadline。
        self.assertFalse(
            manager.confirm_member_acquisition(
                room.id,
                "Other",
                wrong_response["member_token"],
            )
        )
        self.assertFalse(
            manager.confirm_member_acquisition(
                room.id,
                "Wrong",
                "not-the-member-secret",
            )
        )

        clock.advance(0.2)
        live = manager.get_room(room.id)
        self.assertIn("Valid", live.players)
        self.assertNotIn("Wrong", live.players)

    def test_unconfirmed_host_expiry_closes_room(self) -> None:
        clock = ManualClock()
        manager = self.new_manager(clock)
        claim = manager.begin_create_acquisition(
            token("1"),
            ("Room", "Host", "4", GameMode.STANDARD.value),
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        grant = manager.begin_relay_start(claim.room_id, claim.host_token)
        self.assertTrue(manager.attach_relay(grant, 40010, 910, 10))
        clock.advance(61.0)
        self.assertIsNone(manager.get_room(claim.room_id))
        terminations = manager.drain_termination_grants()
        self.assertEqual(len(terminations), 1)
        self.assertEqual(terminations[0].reason.value, "acquisition_unconfirmed")

    def test_host_ready_confirms_provisional_host(self) -> None:
        clock = ManualClock()
        manager = self.new_manager(clock)
        claim = manager.begin_create_acquisition(
            token("9"),
            ("Room", "Host", "4", GameMode.STANDARD.value),
            "Room",
            "Host",
            "",
            4,
            GameMode.STANDARD,
            capability_expires_at=LIVE_CAPABILITY_EXPIRY,
        )
        grant = manager.begin_relay_start(claim.room_id, claim.host_token)
        self.assertTrue(manager.attach_relay(grant, 40009, 909, 9))
        self.assertIsNotNone(
            manager.mark_host_ready(claim.room_id, claim.host_token, 1)
        )
        clock.advance(61.0)
        self.assertIsNotNone(manager.get_room(claim.room_id))

    def test_quick_match_selection_and_membership_commit_share_one_lock(self) -> None:
        manager = self.new_manager(capacity=64)
        room = self.create_joinable_room(manager, max_players=2)

        def acquire(index: int):
            player_name = f"Player{index}"
            acquisition_token = ("2" if index == 0 else "3") * 64
            return manager.begin_quick_match_acquisition(
                acquisition_token,
                (player_name, GameMode.STANDARD.value),
                player_name,
                GameMode.STANDARD,
                capability_expires_at=LIVE_CAPABILITY_EXPIRY,
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            claims = list(executor.map(acquire, range(2)))
        original_room_claims = [claim for claim in claims if claim.room_id == room.id]
        created_room_claims = [claim for claim in claims if claim.room_id != room.id]
        self.assertEqual(len(original_room_claims), 1)
        self.assertEqual(len(created_room_claims), 1)
        self.assertFalse(original_room_claims[0].is_host)
        self.assertTrue(created_room_claims[0].is_host)
        self.assertEqual(manager.get_room(room.id).player_count, 2)

    def test_unknown_cancel_capacity_requires_ttl_and_capability_expiry(self) -> None:
        monotonic_clock = ManualClock()
        capability_clock = ManualClock()
        capability_expiry = 500.0
        manager = RoomManager(
            clock=monotonic_clock,
            capability_clock=capability_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=2,
        )
        manager.release_acquisition(
            token("4"),
            capability_expires_at=capability_expiry,
        )
        monotonic_clock.advance(61.0)
        manager.release_acquisition(
            token("5"),
            capability_expires_at=capability_expiry,
        )
        with self.assertRaises(AcquisitionCapacityError):
            manager.release_acquisition(
                token("6"),
                capability_expires_at=capability_expiry,
            )
        # 单调 TTL 已过但签名仍可提交时，墓碑与饱和 fence 都不能被回收。
        monotonic_clock.advance(60.0)
        late_create_payload = ("Late", "Host", "4", GameMode.STANDARD.value)
        with self.assertRaises(AcquisitionCapacityError):
            manager.begin_create_acquisition(
                token("6"),
                late_create_payload,
                "Late",
                "Host",
                "",
                4,
                GameMode.STANDARD,
                capability_expires_at=capability_expiry,
            )
        room = self.create_joinable_room(manager)
        with self.assertRaises(AcquisitionCapacityError):
            manager.begin_join_acquisition(
                token("6"),
                (room.id, "Late", GameMode.STANDARD.value),
                room.id,
                "Late",
                GameMode.STANDARD,
                capability_expires_at=capability_expiry,
            )
        with self.assertRaises(AcquisitionCapacityError):
            manager.begin_quick_match_acquisition(
                token("6"),
                ("Late", GameMode.STANDARD.value),
                "Late",
                GameMode.STANDARD,
                capability_expires_at=capability_expiry,
            )
        monotonic_clock.advance(61.0)
        capability_clock.advance(400.0)
        self.assertEqual(
            manager.release_acquisition(
                token("6"),
                capability_expires_at=capability_expiry,
            ),
            AcquisitionReleaseResult.TOMBSTONED_UNKNOWN,
        )


class AcquisitionApiConcurrencyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        lobby_main._acquisition_tasks.clear()
        lobby_main._relay_start_tasks.clear()

    async def asyncTearDown(self) -> None:
        await asyncio.sleep(0)
        await lobby_main._cancel_inflight_shared_tasks()

    async def test_shutdown_cancels_detached_acquisition_task(self) -> None:
        task_started = asyncio.Event()

        async def sleeper() -> dict:
            task_started.set()
            await asyncio.Event().wait()
            return {}

        task = asyncio.create_task(sleeper())
        lobby_main._acquisition_tasks[token("b")] = task
        await task_started.wait()
        await lobby_main._cancel_inflight_shared_tasks()
        self.assertTrue(task.cancelled())
        self.assertEqual(lobby_main._acquisition_tasks, {})

    async def test_saturated_unknown_release_and_late_create_return_503(self) -> None:
        manager = RoomManager(
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=1,
        )
        first_capability = capability(
            "create",
            ("First", "Host", "4", GameMode.STANDARD.value),
        )
        late_capability = capability(
            "create",
            ("Late 的房间", "Late", "4", GameMode.STANDARD.value),
        )
        with patch.object(lobby_main, "room_mgr", manager):
            first = await lobby_main.release_acquisition(
                lobby_main.AcquisitionTokenRequest(
                    acquisition_token=first_capability
                )
            )
            self.assertEqual(first["result"], "tombstoned_unknown")
            with self.assertRaises(HTTPException) as saturated_release:
                await lobby_main.release_acquisition(
                    lobby_main.AcquisitionTokenRequest(
                        acquisition_token=late_capability
                    )
                )
            with self.assertRaises(HTTPException) as late_create:
                await lobby_main.create_room(
                    lobby_main.CreateRoomRequest(
                        host_name="Late",
                        acquisition_token=late_capability,
                    ),
                    direct_request(),
                )
        self.assertEqual(saturated_release.exception.status_code, 503)
        self.assertEqual(late_create.exception.status_code, 503)

    async def test_concurrent_same_create_request_shares_one_frozen_result(self) -> None:
        manager = RoomManager(
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        relay_started = asyncio.Event()
        allow_relay = asyncio.Event()
        relay_call_count = 0

        async def fake_start(_room_id: str, _host_token: str) -> tuple[int, int]:
            nonlocal relay_call_count
            relay_call_count += 1
            relay_started.set()
            await allow_relay.wait()
            return 40001, 901

        canonical = ("Concurrent", "Host", "4", GameMode.STANDARD.value)
        signed = capability("create", canonical)
        request_model = lobby_main.CreateRoomRequest(
            name="Concurrent",
            host_name="Host",
            max_players=4,
            game_mode=GameMode.STANDARD,
            acquisition_token=signed,
        )
        http_request = direct_request()
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "_get_or_start_room_relay", fake_start),
        ):
            first = asyncio.create_task(
                lobby_main.create_room(request_model, http_request)
            )
            await relay_started.wait()
            second = asyncio.create_task(
                lobby_main.create_room(request_model, http_request)
            )
            await asyncio.sleep(0)
            allow_relay.set()
            first_response, second_response = await asyncio.gather(first, second)
            conflicting_request = lobby_main.CreateRoomRequest(
                name="Different",
                host_name="Host",
                max_players=4,
                game_mode=GameMode.STANDARD,
                acquisition_token=signed,
            )
            with self.assertRaises(HTTPException) as payload_conflict:
                await lobby_main.create_room(conflicting_request, http_request)
            with self.assertRaises(HTTPException) as action_conflict:
                await lobby_main.quick_match(
                    lobby_main.QuickMatchRequest(
                        player_name="Host",
                        game_mode=GameMode.STANDARD,
                        acquisition_token=signed,
                    ),
                    http_request,
                )
        self.assertEqual(relay_call_count, 1)
        self.assertEqual(first_response, second_response)
        self.assertEqual(first_response["acquisition_token"], signed)
        self.assertEqual(first_response["room_id"], second_response["room_id"])
        self.assertEqual(payload_conflict.exception.status_code, 409)
        self.assertEqual(action_conflict.exception.status_code, 409)

    async def test_release_during_create_prevents_late_task_from_resurrecting_room(self) -> None:
        manager = RoomManager(
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        relay_started = asyncio.Event()
        allow_relay = asyncio.Event()

        async def fake_start(_room_id: str, _host_token: str) -> tuple[int, int]:
            relay_started.set()
            await allow_relay.wait()
            return 40001, 902

        signed = capability(
            "create",
            ("Cancelled", "Host", "4", GameMode.STANDARD.value),
        )
        request_model = lobby_main.CreateRoomRequest(
            name="Cancelled",
            host_name="Host",
            max_players=4,
            game_mode=GameMode.STANDARD,
            acquisition_token=signed,
        )
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "_get_or_start_room_relay", fake_start),
        ):
            create_task = asyncio.create_task(
                lobby_main.create_room(request_model, direct_request())
            )
            await relay_started.wait()
            release_response = await lobby_main.release_acquisition(
                lobby_main.AcquisitionTokenRequest(
                    acquisition_token=signed
                )
            )
            allow_relay.set()
            with self.assertRaises(HTTPException) as raised:
                await create_task
        self.assertEqual(release_response["status"], "ok")
        self.assertEqual(raised.exception.status_code, 410)
        self.assertEqual(manager.list_joinable_rooms(), [])

    async def test_release_before_delayed_join_survives_monotonic_tombstone_ttl(
        self,
    ) -> None:
        wall_clock = ManualClock(1_700_000_000.0)
        monotonic_clock = ManualClock()
        signer = AcquisitionCapabilitySigner(
            b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*",
            45,
            clock=wall_clock,
        )
        manager = RoomManager(
            clock=monotonic_clock,
            capability_clock=wall_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        room = manager.create_room(
            "Join target",
            "Host",
            "",
            max_players=4,
            game_mode=GameMode.STANDARD,
        )
        self.assertIsNotNone(room)
        relay_grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertTrue(manager.attach_relay(relay_grant, 40001, 901, 1))
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 1))

        canonical = (room.id, "LateJoin", GameMode.STANDARD.value)
        signed = signer.issue("join", canonical)
        request_model = lobby_main.JoinRoomRequest(
            player_name="LateJoin",
            game_mode=GameMode.STANDARD,
            acquisition_token=signed.token,
        )
        reconcile_entered = threading.Event()
        allow_reconcile = threading.Event()

        def blocked_reconcile() -> None:
            reconcile_entered.set()
            if not allow_reconcile.wait(timeout=5.0):
                raise TimeoutError("join barrier 未释放")

        task = None
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_capability_signer", signer),
            patch.object(lobby_main, "_reconcile_exited_relays", blocked_reconcile),
        ):
            try:
                task = asyncio.create_task(
                    lobby_main.join_room(room.id, request_model, direct_request())
                )
                self.assertTrue(
                    await asyncio.to_thread(reconcile_entered.wait, 2.0),
                    "join 必须停在初次验签后的真实异步边界",
                )
                released = await lobby_main.release_acquisition(
                    lobby_main.AcquisitionTokenRequest(
                        acquisition_token=signed.token
                    )
                )
                self.assertEqual(released["result"], "tombstoned_unknown")
                monotonic_clock.advance(121.0)
                allow_reconcile.set()
                with self.assertRaises(HTTPException) as raised:
                    await task
                self.assertEqual(raised.exception.status_code, 410)
            finally:
                allow_reconcile.set()
                if task is not None and not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)

        live_room = manager.get_room(room.id)
        self.assertIsNotNone(live_room)
        self.assertEqual(set(live_room.players), {"Host"})
        self.assertIn(signed.token, manager._acquisition_tombstones)

    async def test_release_before_delayed_quick_survives_monotonic_tombstone_ttl(
        self,
    ) -> None:
        wall_clock = ManualClock(1_700_000_000.0)
        monotonic_clock = ManualClock()
        signer = AcquisitionCapabilitySigner(
            b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*",
            45,
            clock=wall_clock,
        )
        manager = RoomManager(
            clock=monotonic_clock,
            capability_clock=wall_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        canonical = ("LateQuick", GameMode.STANDARD.value)
        signed = signer.issue("quick_match", canonical)
        request_model = lobby_main.QuickMatchRequest(
            player_name="LateQuick",
            game_mode=GameMode.STANDARD,
            acquisition_token=signed.token,
        )
        reconcile_entered = threading.Event()
        allow_reconcile = threading.Event()

        def blocked_reconcile() -> None:
            reconcile_entered.set()
            if not allow_reconcile.wait(timeout=5.0):
                raise TimeoutError("quick barrier 未释放")

        task = None
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_capability_signer", signer),
            patch.object(lobby_main, "_reconcile_exited_relays", blocked_reconcile),
        ):
            try:
                task = asyncio.create_task(
                    lobby_main.quick_match(request_model, direct_request())
                )
                self.assertTrue(
                    await asyncio.to_thread(reconcile_entered.wait, 2.0),
                    "quick 必须停在初次验签后的真实异步边界",
                )
                released = await lobby_main.release_acquisition(
                    lobby_main.AcquisitionTokenRequest(
                        acquisition_token=signed.token
                    )
                )
                self.assertEqual(released["result"], "tombstoned_unknown")
                monotonic_clock.advance(121.0)
                allow_reconcile.set()
                with self.assertRaises(HTTPException) as raised:
                    await task
                self.assertEqual(raised.exception.status_code, 410)
            finally:
                allow_reconcile.set()
                if task is not None and not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)

        self.assertEqual(manager.list_joinable_rooms(), [])
        self.assertIn(signed.token, manager._acquisition_tombstones)

    async def test_quick_revalidates_expiry_after_barrier_before_begin(self) -> None:
        wall_clock = ManualClock(1_700_000_000.0)
        monotonic_clock = ManualClock()
        signer = AcquisitionCapabilitySigner(
            b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*",
            45,
            clock=wall_clock,
        )
        manager = RoomManager(
            clock=monotonic_clock,
            capability_clock=wall_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        canonical = ("ExpiredQuick", GameMode.STANDARD.value)
        signed = signer.issue("quick_match", canonical)
        request_model = lobby_main.QuickMatchRequest(
            player_name="ExpiredQuick",
            game_mode=GameMode.STANDARD,
            acquisition_token=signed.token,
        )
        reconcile_entered = threading.Event()
        allow_reconcile = threading.Event()

        def blocked_reconcile() -> None:
            reconcile_entered.set()
            if not allow_reconcile.wait(timeout=5.0):
                raise TimeoutError("expiry barrier 未释放")

        task = None
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_capability_signer", signer),
            patch.object(lobby_main, "_reconcile_exited_relays", blocked_reconcile),
            patch.object(signer, "verify", wraps=signer.verify) as verify_spy,
            patch.object(
                manager,
                "begin_quick_match_acquisition",
                wraps=manager.begin_quick_match_acquisition,
            ) as begin_spy,
        ):
            try:
                task = asyncio.create_task(
                    lobby_main.quick_match(request_model, direct_request())
                )
                self.assertTrue(
                    await asyncio.to_thread(reconcile_entered.wait, 2.0),
                    "quick 必须先完成初验再进入 barrier",
                )
                self.assertEqual(verify_spy.call_count, 1)
                wall_clock.advance(45.0)
                allow_reconcile.set()
                with self.assertRaises(HTTPException) as raised:
                    await task
                self.assertEqual(raised.exception.status_code, 410)
                self.assertEqual(verify_spy.call_count, 2)
                begin_spy.assert_not_called()
            finally:
                allow_reconcile.set()
                if task is not None and not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)

        self.assertEqual(manager.list_joinable_rooms(), [])


if __name__ == "__main__":
    unittest.main()
