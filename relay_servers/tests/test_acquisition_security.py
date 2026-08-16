"""HMAC capability 与双层 admission limiter 的纯边界测试。"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

os.environ.setdefault(
    "ACQUISITION_CAPABILITY_HMAC_SECRET",
    "test-only-acquisition-hmac-secret-32-bytes-minimum",
)

from relay_servers.lobby_api.acquisition_security import (
    AcquisitionCapabilityError,
    AcquisitionCapabilityExpiredError,
    AcquisitionCapabilitySigner,
    DualTokenBucketRateLimiter,
    fingerprint_canonical_payload,
)
from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.models import GameMode
from relay_servers.lobby_api.room_manager import RoomManager


class ManualClock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class AcquisitionCapabilityTests(unittest.TestCase):
    def new_signer(self, clock: ManualClock) -> AcquisitionCapabilitySigner:
        return AcquisitionCapabilitySigner(
            b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*",
            45,
            clock=clock,
            nonce_factory=lambda size: bytes(range(size)),
        )

    def test_capability_binds_action_payload_expiry_and_nonce(self) -> None:
        clock = ManualClock()
        signer = self.new_signer(clock)
        payload = ("Room", "Host", "4", "standard")
        issued = signer.issue("create", payload)
        self.assertNotIn(issued.token, repr(issued))
        claims = signer.verify(
            issued.token,
            expected_action="create",
            expected_payload=payload,
        )
        self.assertEqual(claims.expires_at, int(clock.now) + 45)
        self.assertEqual(
            claims.payload_fingerprint,
            fingerprint_canonical_payload("create", payload),
        )
        with self.assertRaises(AcquisitionCapabilityError):
            signer.verify(
                issued.token,
                expected_action="join",
                expected_payload=payload,
            )
        with self.assertRaises(AcquisitionCapabilityError):
            signer.verify(
                issued.token,
                expected_action="create",
                expected_payload=("Other", "Host", "4", "standard"),
            )

    def test_tamper_and_weak_secret_fail_closed_without_echoing_token(self) -> None:
        clock = ManualClock()
        signer = self.new_signer(clock)
        issued = signer.issue("quick_match", ("Player", "standard"))
        tampered = issued.token[:-1] + ("A" if issued.token[-1] != "A" else "B")
        with self.assertRaises(AcquisitionCapabilityError) as raised:
            signer.verify(tampered)
        self.assertNotIn(tampered, str(raised.exception))
        with self.assertRaises(ValueError):
            AcquisitionCapabilitySigner(b"a" * 32, 45)

        random_signer = AcquisitionCapabilitySigner(
            b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*",
            45,
            clock=clock,
        )
        first = random_signer.issue("quick_match", ("Player", "standard"))
        second = random_signer.issue("quick_match", ("Player", "standard"))
        self.assertNotEqual(first.token, second.token)

    def test_expiry_grace_is_bounded_for_cancel_only(self) -> None:
        clock = ManualClock()
        signer = self.new_signer(clock)
        issued = signer.issue("join", ("room", "Player", "standard"))
        clock.advance(45.0)
        with self.assertRaises(AcquisitionCapabilityExpiredError):
            signer.verify(
                issued.token,
                expected_action="join",
                expected_payload=("room", "Player", "standard"),
            )
        signer.verify(issued.token, expiry_grace_seconds=120.0)
        clock.advance(120.0)
        with self.assertRaises(AcquisitionCapabilityExpiredError):
            signer.verify(issued.token, expiry_grace_seconds=120.0)


class DualTokenBucketRateLimiterTests(unittest.TestCase):
    def new_limiter(
        self,
        clock: ManualClock,
        *,
        global_burst: int = 4,
        source_burst: int = 2,
        source_capacity: int = 8,
    ) -> DualTokenBucketRateLimiter:
        return DualTokenBucketRateLimiter(
            global_burst=global_burst,
            global_refill_per_second=1.0,
            source_burst=source_burst,
            source_refill_per_second=0.5,
            source_bucket_capacity=source_capacity,
            source_idle_ttl_seconds=60.0,
            clock=clock,
        )

    def test_source_limit_refills_and_rejection_does_not_spend_global(self) -> None:
        clock = ManualClock(100.0)
        limiter = self.new_limiter(clock)
        self.assertTrue(limiter.consume("198.51.100.1").allowed)
        self.assertTrue(limiter.consume("198.51.100.1").allowed)
        rejected = limiter.consume("198.51.100.1")
        self.assertFalse(rejected.allowed)
        self.assertAlmostEqual(rejected.retry_after_seconds, 2.0)
        # 来源桶拒绝不能部分消费全局桶，另一来源仍保留两个全局令牌。
        self.assertTrue(limiter.consume("198.51.100.2").allowed)
        self.assertTrue(limiter.consume("198.51.100.2").allowed)
        clock.advance(2.0)
        self.assertTrue(limiter.consume("198.51.100.1").allowed)

    def test_global_limit_and_concurrent_consumption_are_exact(self) -> None:
        clock = ManualClock(200.0)
        limiter = self.new_limiter(
            clock,
            global_burst=5,
            source_burst=5,
        )
        with ThreadPoolExecutor(max_workers=16) as executor:
            decisions = list(
                executor.map(
                    lambda _index: limiter.consume("203.0.113.9").allowed,
                    range(32),
                )
            )
        self.assertEqual(sum(decisions), 5)
        self.assertFalse(limiter.consume("203.0.113.10").allowed)
        source_count_at_exhaustion = limiter.source_bucket_count()
        for index in range(20):
            self.assertFalse(
                limiter.consume(f"198.51.100.{index + 1}").allowed
            )
        self.assertEqual(
            limiter.source_bucket_count(),
            source_count_at_exhaustion,
        )
        clock.advance(1.0)
        self.assertTrue(limiter.consume("203.0.113.10").allowed)

    def test_source_map_capacity_fails_closed_then_prunes_idle_bucket(self) -> None:
        clock = ManualClock(300.0)
        limiter = self.new_limiter(
            clock,
            global_burst=1,
            source_burst=1,
            source_capacity=1,
        )
        self.assertTrue(limiter.consume("192.0.2.1").allowed)
        clock.advance(1.0)
        full = limiter.consume("192.0.2.2")
        self.assertFalse(full.allowed)
        self.assertGreater(full.retry_after_seconds, 0.0)
        clock.advance(60.0)
        self.assertTrue(limiter.consume("192.0.2.2").allowed)
        self.assertEqual(limiter.source_bucket_count(), 1)


class AcquisitionSecurityApiTests(unittest.TestCase):
    SECRET = b"9wA!q2L@x3P#c4V$k5M%z6R^t7Y&u8I*"

    def new_limiter(
        self,
        clock: ManualClock,
        *,
        global_burst: int = 100,
        source_burst: int = 100,
    ) -> DualTokenBucketRateLimiter:
        return DualTokenBucketRateLimiter(
            global_burst=global_burst,
            global_refill_per_second=1.0,
            source_burst=source_burst,
            source_refill_per_second=1.0,
            source_bucket_capacity=max(16, global_burst),
            source_idle_ttl_seconds=60.0,
            clock=clock,
        )

    def test_preflight_is_resource_free_and_capability_binds_actual_command(self) -> None:
        wall_clock = ManualClock()
        monotonic_clock = ManualClock(10.0)
        signer = AcquisitionCapabilitySigner(
            self.SECRET,
            45,
            clock=wall_clock,
            nonce_factory=lambda size: bytes(range(size)),
        )
        limiter = self.new_limiter(monotonic_clock)
        manager = RoomManager(
            capability_clock=wall_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        fake_relay = AsyncMock(return_value=(40001, 901))
        client = TestClient(
            lobby_main.app,
            client=("198.51.100.20", 50000),
        )
        create_payload = {
            "name": "Bound",
            "host_name": "Host",
            "max_players": 4,
            "game_mode": GameMode.STANDARD.value,
        }
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_capability_signer", signer),
            patch.object(lobby_main, "acquisition_admission_limiter", limiter),
            patch.object(lobby_main, "_get_or_start_room_relay", fake_relay),
            patch.object(
                lobby_main.config,
                "ALLOW_LEGACY_ACQUISITION_REQUESTS",
                False,
            ),
        ):
            preflight = client.post(
                "/acquisitions/preflight",
                json={"action": "create", "payload": create_payload},
            )
            self.assertEqual(preflight.status_code, 200, preflight.text)
            self.assertEqual(manager.list_joinable_rooms(), [])
            signed = preflight.json()["acquisition_token"]

            missing = client.post("/rooms", json=create_payload)
            self.assertEqual(missing.status_code, 428)
            created = client.post(
                "/rooms",
                json={**create_payload, "acquisition_token": signed},
            )
            self.assertEqual(created.status_code, 200, created.text)
            self.assertEqual(len(manager._rooms), 1)
            self.assertNotEqual(
                created.json()["member_token"],
                created.json()["acquisition_token"],
            )

            mismatched = client.post(
                "/rooms",
                json={
                    **create_payload,
                    "name": "Other",
                    "acquisition_token": signed,
                },
            )
            self.assertEqual(mismatched.status_code, 409)
            self.assertEqual(len(manager._rooms), 1)

    def test_release_grace_is_bounded_and_invalid_input_writes_no_tombstone(self) -> None:
        wall_clock = ManualClock()
        signer = AcquisitionCapabilitySigner(
            self.SECRET,
            45,
            clock=wall_clock,
            nonce_factory=lambda size: bytes(range(size)),
        )
        manager = RoomManager(
            capability_clock=wall_clock,
            acquisition_provisional_timeout_seconds=60.0,
            acquisition_tombstone_ttl_seconds=120.0,
            acquisition_token_capacity=32,
        )
        client = TestClient(lobby_main.app)
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_capability_signer", signer),
        ):
            invalid = client.post(
                "/acquisitions/release",
                json={"acquisition_token": "random-client-token"},
            )
            self.assertEqual(invalid.status_code, 200)
            self.assertEqual(invalid.json()["result"], "ignored")
            self.assertEqual(manager._acquisition_tombstones, {})

            within_grace = signer.issue(
                "join",
                ("room", "Member", GameMode.STANDARD.value),
            )
            wall_clock.advance(45.0)
            accepted = client.post(
                "/acquisitions/release",
                json={"acquisition_token": within_grace.token},
            )
            self.assertEqual(accepted.status_code, 200)
            self.assertEqual(accepted.json()["result"], "tombstoned_unknown")
            self.assertEqual(len(manager._acquisition_tombstones), 1)

            too_old = signer.issue(
                "quick_match",
                ("Other", GameMode.STANDARD.value),
            )
            wall_clock.advance(165.0)
            ignored = client.post(
                "/acquisitions/release",
                json={"acquisition_token": too_old.token},
            )
            self.assertEqual(ignored.status_code, 200)
            self.assertEqual(ignored.json()["result"], "ignored")
            self.assertEqual(len(manager._acquisition_tombstones), 1)

    def test_preflight_rate_limit_uses_socket_host_and_ignores_xff(self) -> None:
        limiter_clock = ManualClock(20.0)
        limiter = self.new_limiter(
            limiter_clock,
            global_burst=10,
            source_burst=2,
        )
        client = TestClient(
            lobby_main.app,
            client=("203.0.113.30", 50000),
        )
        body = {
            "action": "quick_match",
            "payload": {
                "player_name": "Player",
                "game_mode": GameMode.STANDARD.value,
            },
        }
        with patch.object(
            lobby_main,
            "acquisition_admission_limiter",
            limiter,
        ):
            first = client.post(
                "/acquisitions/preflight",
                json=body,
                headers={"X-Forwarded-For": "192.0.2.1"},
            )
            second = client.post(
                "/acquisitions/preflight",
                json=body,
                headers={"X-Forwarded-For": "192.0.2.2"},
            )
            denied = client.post(
                "/acquisitions/preflight",
                json=body,
                headers={"X-Forwarded-For": "192.0.2.3"},
            )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(denied.status_code, 429)
        self.assertGreaterEqual(int(denied.headers["Retry-After"]), 1)

    def test_preflight_and_explicit_legacy_share_the_same_admission_budget(self) -> None:
        limiter_clock = ManualClock(30.0)
        limiter = self.new_limiter(
            limiter_clock,
            global_burst=1,
            source_burst=1,
        )
        manager = RoomManager()
        fake_relay = AsyncMock(return_value=(40001, 902))
        client = TestClient(
            lobby_main.app,
            client=("198.51.100.40", 50000),
        )
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "acquisition_admission_limiter", limiter),
            patch.object(lobby_main, "_get_or_start_room_relay", fake_relay),
            patch.object(
                lobby_main.config,
                "ALLOW_LEGACY_ACQUISITION_REQUESTS",
                True,
            ),
        ):
            admitted = client.post(
                "/acquisitions/preflight",
                json={
                    "action": "create",
                    "payload": {"host_name": "Preflight"},
                },
            )
            denied_legacy = client.post(
                "/rooms",
                json={"host_name": "Legacy"},
            )
        self.assertEqual(admitted.status_code, 200)
        self.assertEqual(denied_legacy.status_code, 429)
        self.assertEqual(manager._rooms, {})

    def test_config_requires_strong_secret_without_echoing_it(self) -> None:
        command = [
            sys.executable,
            "-c",
            "from relay_servers.lobby_api import config",
        ]
        missing_env = dict(os.environ)
        missing_env.pop("ACQUISITION_CAPABILITY_HMAC_SECRET", None)
        missing = subprocess.run(
            command,
            cwd=os.getcwd(),
            env=missing_env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("ACQUISITION_CAPABILITY_HMAC_SECRET", missing.stderr)

        weak_secret = "predictable-predictable-predictable"
        weak_env = dict(missing_env)
        weak_env["ACQUISITION_CAPABILITY_HMAC_SECRET"] = weak_secret
        weak = subprocess.run(
            command,
            cwd=os.getcwd(),
            env=weak_env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(weak.returncode, 0)
        self.assertNotIn(weak_secret, weak.stderr)

        strong_env = dict(missing_env)
        strong_env["ACQUISITION_CAPABILITY_HMAC_SECRET"] = (
            "test-only-acquisition-hmac-secret-32-bytes-minimum"
        )
        invalid_boundaries = (
            {"ALLOW_LEGACY_ACQUISITION_REQUESTS": "1"},
            {
                "ACQUISITION_ADMISSION_GLOBAL_BURST": "120",
                "ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY": "119",
            },
            {"ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND": "nan"},
            {"ACQUISITION_CAPABILITY_TTL_SECONDS": "61"},
        )
        for overrides in invalid_boundaries:
            with self.subTest(overrides=overrides):
                invalid_env = {**strong_env, **overrides}
                invalid = subprocess.run(
                    command,
                    cwd=os.getcwd(),
                    env=invalid_env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(invalid.returncode, 0)


if __name__ == "__main__":
    unittest.main()
