from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

os.environ.setdefault(
    "ACQUISITION_CAPABILITY_HMAC_SECRET",
    "test-only-acquisition-hmac-secret-32-bytes-minimum",
)

from fastapi import HTTPException

from relay_servers.lobby_api import main as lobby_main
from relay_servers.lobby_api.main import RelayAdmissionTicketRequest
from relay_servers.lobby_api.models import GameMode
from relay_servers.lobby_api.relay_admission import (
    ROLE_HOST,
    ROLE_MEMBER,
    RelayAdmissionTicketError,
    RelayAdmissionTicketSigner,
)
from relay_servers.lobby_api.room_manager import (
    RelayAdmissionRefreshRateLimitError,
    RoomManager,
)


class ManualClock:
    def __init__(self, initial: float) -> None:
        self.now = initial

    def __call__(self) -> float:
        return self.now


class RelayAdmissionTicketTests(unittest.TestCase):
    SECRET = "fixture-room-admission-secret-0123456789abcdef"

    def setUp(self) -> None:
        self.wall_clock = ManualClock(1_700_000_000.0)
        self.signer = RelayAdmissionTicketSigner(
            clock=self.wall_clock,
            nonce_factory=lambda: "fixture-nonce",
        )

    def test_role_bound_ticket_round_trips_and_has_stable_wire_envelope(self) -> None:
        ticket = self.signer.issue(
            self.SECRET,
            "fixture-room",
            ROLE_HOST,
            "FixtureHost",
            60.0,
        )

        self.assertTrue(ticket.startswith("ra1."))
        self.assertEqual(len(ticket.split(".")), 3)
        self.assertNotIn(self.SECRET, ticket)
        claims = self.signer.verify(ticket, self.SECRET, "fixture-room")
        self.assertEqual(claims.role, ROLE_HOST)
        self.assertEqual(claims.player_name, "FixtureHost")
        self.assertEqual(claims.expires_at, 1_700_000_060)
        with self.assertRaises(ValueError):
            RoomManager(relay_admission_ticket_ttl_seconds=121.0)
        with self.assertRaises(ValueError):
            RoomManager(relay_admission_refresh_burst=10)
        with self.assertRaises(ValueError):
            RoomManager(relay_admission_refresh_window_seconds=1.0)
        with self.assertRaises(ValueError):
            RoomManager(relay_admission_refresh_window_seconds=61.0)

    def test_tamper_wrong_room_expiry_and_weak_secret_fail_closed(self) -> None:
        ticket = self.signer.issue(
            self.SECRET,
            "fixture-room",
            ROLE_MEMBER,
            "Member",
            60.0,
        )

        tampered = ticket[:-1] + ("0" if ticket[-1] != "0" else "1")
        for candidate, secret, room_id in (
            (tampered, self.SECRET, "fixture-room"),
            (ticket, self.SECRET, "another-room"),
        ):
            with self.subTest(candidate=candidate[-8:], room_id=room_id):
                with self.assertRaises(RelayAdmissionTicketError):
                    self.signer.verify(candidate, secret, room_id)
        self.wall_clock.now = 1_700_000_060.0
        with self.assertRaises(RelayAdmissionTicketError):
            self.signer.verify(ticket, self.SECRET, "fixture-room")
        with self.assertRaises(ValueError):
            self.signer.issue("short", "fixture-room", ROLE_MEMBER, "Member", 60.0)
        with self.assertRaises(ValueError):
            self.signer.issue(
                self.SECRET,
                "fixture-room",
                ROLE_MEMBER,
                "Member",
                121.0,
            )
        self.wall_clock.now = 1_700_000_000.0

        def sign_raw_claims(claims: dict) -> str:
            payload = base64.urlsafe_b64encode(
                json.dumps(
                    claims,
                    ensure_ascii=True,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
            ).rstrip(b"=").decode("ascii")
            message = f"ra1.{payload}"
            signature = hmac.new(
                self.SECRET.encode("ascii"),
                message.encode("ascii"),
                hashlib.sha256,
            ).hexdigest()
            return f"{message}.{signature}"

        overlong_claims = {
            "exp": 1_700_000_060,
            "iat": 1_700_000_000,
            "nonce": "n" * 65,
            "player_name": "Member",
            "role": ROLE_MEMBER,
            "room_id": "fixture-room",
            "v": 1,
        }
        with self.assertRaises(RelayAdmissionTicketError):
            self.signer.verify(
                sign_raw_claims(overlong_claims),
                self.SECRET,
                "fixture-room",
            )
        overlong_ttl_claims = dict(
            overlong_claims,
            exp=1_700_000_121,
            nonce="valid-nonce",
        )
        with self.assertRaises(RelayAdmissionTicketError):
            self.signer.verify(
                sign_raw_claims(overlong_ttl_claims),
                self.SECRET,
                "fixture-room",
            )

    def test_room_manager_issues_private_host_and_member_tickets_only(self) -> None:
        monotonic_clock = ManualClock(100.0)
        wall_clock = ManualClock(1_700_000_000.0)
        manager = RoomManager(
            clock=monotonic_clock,
            wall_clock=wall_clock,
            game_max_duration_seconds=600.0,
        )
        room = manager.create_room(
            "Admission",
            "Host",
            "",
            max_players=2,
            game_mode=GameMode.STANDARD,
        )
        self.assertIsNotNone(room)
        assert room is not None
        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        assert grant is not None
        self.assertEqual(grant.admission_secret, room.admission_secret)
        self.assertTrue(manager.attach_relay(grant, 40001, 12345, 1))
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 2))

        host_response = manager.get_join_dict(
            room.id,
            "127.0.0.1",
            expected_host_token=room.host_token,
            include_host_token=True,
            member_name="Host",
        )
        self.assertIsNotNone(host_response)
        assert host_response is not None
        host_claims = self.signer.verify(
            host_response["relay_admission_ticket"],
            room.admission_secret,
            room.id,
        )
        self.assertEqual(host_claims.role, ROLE_HOST)
        self.assertEqual(host_claims.expires_at, 1_700_000_060)

        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_response = manager.get_join_dict(
            room.id,
            "127.0.0.1",
            member_name="Member",
        )
        self.assertIsNotNone(member_response)
        assert member_response is not None
        member_claims = self.signer.verify(
            member_response["relay_admission_ticket"],
            room.admission_secret,
            room.id,
        )
        self.assertEqual(member_claims.role, ROLE_MEMBER)
        self.assertEqual(member_claims.player_name, "Member")
        self.assertNotEqual(
            host_response["relay_admission_ticket"],
            member_response["relay_admission_ticket"],
        )

        public_room = room.to_public_dict()
        anonymous_join = room.to_join_dict("127.0.0.1")
        for payload in (public_room, anonymous_join):
            self.assertNotIn("admission_secret", payload)
            self.assertNotIn("relay_admission_ticket", payload)
        self.assertNotIn(room.admission_secret, repr(room))
        self.assertNotIn(room.host_token, repr(room))

        refreshed = manager.issue_member_relay_admission_ticket(
            room.id,
            "Member",
            room.players["Member"].member_token,
            "127.0.0.1",
        )
        self.assertIsNotNone(refreshed)
        assert refreshed is not None
        self.assertEqual(refreshed["role"], ROLE_MEMBER)
        self.assertEqual(refreshed["relay_port"], 40001)
        self.assertEqual(refreshed["host_peer_id"], 2)
        self.assertNotEqual(
            refreshed["relay_admission_ticket"],
            member_response["relay_admission_ticket"],
        )
        self.assertIsNone(
            manager.issue_member_relay_admission_ticket(
                room.id,
                "Member",
                "wrong-token",
                "127.0.0.1",
            )
        )

    def test_member_ticket_refresh_allows_retry_burst_then_rate_limits(self) -> None:
        monotonic_clock = ManualClock(100.0)
        manager = RoomManager(
            clock=monotonic_clock,
            relay_admission_refresh_burst=3,
            relay_admission_refresh_window_seconds=5.0,
        )
        room = manager.create_room("RefreshLimit", "Host", "")
        self.assertIsNotNone(room)
        assert room is not None
        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        assert grant is not None
        self.assertTrue(manager.attach_relay(grant, 40001, 12345, 1))
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 2))
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token

        for _attempt in range(3):
            self.assertIsNotNone(
                manager.issue_member_relay_admission_ticket(
                    room.id,
                    "Member",
                    member_token,
                    "127.0.0.1",
                )
            )
        with self.assertRaises(RelayAdmissionRefreshRateLimitError) as raised:
            manager.issue_member_relay_admission_ticket(
                room.id,
                "Member",
                member_token,
                "127.0.0.1",
            )
        self.assertAlmostEqual(raised.exception.retry_after_seconds, 5.0)

        monotonic_clock.now = 105.0
        self.assertIsNotNone(
            manager.issue_member_relay_admission_ticket(
                room.id,
                "Member",
                member_token,
                "127.0.0.1",
            )
        )
        self.assertIsNone(
            manager.issue_member_relay_admission_ticket(
                room.id,
                "Host",
                room.players["Host"].member_token,
                "127.0.0.1",
            )
        )

    def test_relay_source_has_no_first_connector_host_fallback(self) -> None:
        source = (
            Path(__file__).resolve().parents[1]
            / "relay_godot_project"
            / "relay_server.gd"
        ).read_text(encoding="utf-8")

        self.assertIn("multiplayer.auth_callback = _on_auth_payload", source)
        self.assertIn("multiplayer.complete_auth(peer_id)", source)
        self.assertIn("multiplayer.get_authenticating_peers()", source)
        self.assertIn("try_consume_ticket_nonce", source)
        self.assertIn("_host_was_authenticated", source)
        self.assertIn("ARC_NICE_RELAY_ADMISSION_SECRET", source)
        connected_handler = source.split(
            "func _on_peer_connected(peer_id: int) -> void:", 1
        )[1].split("func _on_peer_disconnected", 1)[0]
        self.assertNotIn("_host_peer_id = peer_id", connected_handler)
        self.assertNotIn("if _host_peer_id <= 0", connected_handler)

    def test_http_refresh_exchanges_only_matching_member_token(self) -> None:
        manager = RoomManager()
        room = manager.create_room("Refresh", "Host", "")
        self.assertIsNotNone(room)
        assert room is not None
        grant = manager.begin_relay_start(room.id, room.host_token)
        self.assertIsNotNone(grant)
        assert grant is not None
        self.assertTrue(manager.attach_relay(grant, 40001, 12345, 1))
        self.assertIsNotNone(manager.mark_host_ready(room.id, room.host_token, 2))
        self.assertIsNotNone(
            manager.join_room(room.id, "Member", GameMode.STANDARD)
        )
        member_token = room.players["Member"].member_token

        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "_reconcile_exited_relays"),
            patch.object(lobby_main, "_flush_room_termination_grants"),
        ):
            response = asyncio.run(
                lobby_main.issue_relay_admission_ticket(
                    room.id,
                    RelayAdmissionTicketRequest(
                        player_name="Member",
                        member_token=member_token,
                    ),
                )
            )
            self.assertEqual(
                set(response),
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
            self.assertEqual(response["room_id"], room.id)
            self.assertEqual(response["player_name"], "Member")
            self.assertEqual(response["role"], ROLE_MEMBER)
            self.assertEqual(response["relay_ip"], lobby_main.config.PUBLIC_IP)
            self.assertEqual(response["relay_port"], 40001)
            self.assertEqual(response["host_peer_id"], 2)
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    lobby_main.issue_relay_admission_ticket(
                        room.id,
                        RelayAdmissionTicketRequest(
                            player_name="Member",
                            member_token="wrong-token",
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as host_raised:
                asyncio.run(
                    lobby_main.issue_relay_admission_ticket(
                        room.id,
                        RelayAdmissionTicketRequest(
                            player_name="Host",
                            member_token=room.players["Host"].member_token,
                        ),
                    )
                )
            for _retry in range(2):
                asyncio.run(
                    lobby_main.issue_relay_admission_ticket(
                        room.id,
                        RelayAdmissionTicketRequest(
                            player_name="Member",
                            member_token=member_token,
                        ),
                    )
                )
            with self.assertRaises(HTTPException) as rate_raised:
                asyncio.run(
                    lobby_main.issue_relay_admission_ticket(
                        room.id,
                        RelayAdmissionTicketRequest(
                            player_name="Member",
                            member_token=member_token,
                        ),
                    )
                )
        self.assertEqual(raised.exception.status_code, 403)
        self.assertEqual(host_raised.exception.status_code, 403)
        self.assertEqual(rate_raised.exception.status_code, 429)
        self.assertEqual(rate_raised.exception.headers, {"Retry-After": "5"})

    def test_http_refresh_rejects_non_release_room_before_ticket_exchange(self) -> None:
        manager = RoomManager()
        room = manager.create_room(
            "HiddenRefresh",
            "Host",
            "",
            game_mode=GameMode.TEST_ARENA_P1,
        )
        self.assertIsNotNone(room)
        assert room is not None
        with (
            patch.object(lobby_main, "room_mgr", manager),
            patch.object(lobby_main, "_reconcile_exited_relays"),
            patch.object(lobby_main, "_flush_room_termination_grants"),
            self.assertRaises(HTTPException) as raised,
        ):
            asyncio.run(
                lobby_main.issue_relay_admission_ticket(
                    room.id,
                    RelayAdmissionTicketRequest(
                        player_name="Host",
                        member_token=room.players["Host"].member_token,
                    ),
                )
            )
        self.assertEqual(raised.exception.status_code, 403)


if __name__ == "__main__":
    unittest.main()
