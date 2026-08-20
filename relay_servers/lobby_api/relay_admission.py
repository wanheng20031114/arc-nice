"""Relay admission ticket issuing and verification.

Tickets are room-scoped bearer capabilities.  The room secret is shared only
between the single-worker Lobby process and that room's Relay subprocess.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import math
import secrets
import time
from dataclasses import dataclass
from typing import Callable


TICKET_PREFIX = "ra1"
TICKET_VERSION = 1
ROLE_HOST = "host"
ROLE_MEMBER = "member"
VALID_ROLES = frozenset({ROLE_HOST, ROLE_MEMBER})
MIN_ROOM_SECRET_LENGTH = 32
MAX_ROOM_SECRET_LENGTH = 256
MAX_TICKET_LENGTH = 2048
MAX_TICKET_TTL_SECONDS = 120
MIN_TICKET_REFRESH_BURST = 2
MAX_TICKET_REFRESH_BURST = 3
MIN_TICKET_REFRESH_WINDOW_SECONDS = 5.0
MAX_TICKET_REFRESH_WINDOW_SECONDS = 60.0


class RelayAdmissionTicketError(ValueError):
    """The ticket is malformed, expired, or does not authenticate."""


@dataclass(frozen=True)
class RelayAdmissionClaims:
    room_id: str
    role: str
    player_name: str
    issued_at: int
    expires_at: int
    nonce: str


class RelayAdmissionTicketSigner:
    """Issue and verify the wire format understood by the Godot Relay."""

    def __init__(
        self,
        clock: Callable[[], float] = time.time,
        nonce_factory: Callable[[], str] = (
            lambda: secrets.token_urlsafe(12)
        ),
    ) -> None:
        self._clock = clock
        self._nonce_factory = nonce_factory

    @staticmethod
    def _validate_secret(room_secret: str) -> bytes:
        try:
            encoded = room_secret.encode("ascii")
        except UnicodeEncodeError as exc:
            raise ValueError("Relay admission secret must be ASCII") from exc
        if not MIN_ROOM_SECRET_LENGTH <= len(encoded) <= MAX_ROOM_SECRET_LENGTH:
            raise ValueError("Relay admission secret length is invalid")
        return encoded

    def issue(
        self,
        room_secret: str,
        room_id: str,
        role: str,
        player_name: str,
        ttl_seconds: float,
    ) -> str:
        secret_bytes = self._validate_secret(room_secret)
        if not room_id or len(room_id) > 64:
            raise ValueError("room_id must contain 1..64 characters")
        if role not in VALID_ROLES:
            raise ValueError("Relay admission role is invalid")
        if not player_name or len(player_name) > 32:
            raise ValueError("player_name must contain 1..32 characters")
        if (
            not math.isfinite(ttl_seconds)
            or ttl_seconds <= 0
            or ttl_seconds > MAX_TICKET_TTL_SECONDS
        ):
            raise ValueError("Relay admission ticket TTL is outside 0..120 seconds")

        now = self._clock()
        if not math.isfinite(now) or now < 0:
            raise ValueError("Relay admission wall clock is invalid")
        issued_at = int(now)
        # Anchor both wire timestamps to the same integer second. This keeps the
        # signed validity span within the hard 120-second verifier bound while
        # allowing a sub-second remaining room lifetime one final short ticket.
        expires_at = issued_at + max(1, int(math.ceil(ttl_seconds)))
        nonce = self._nonce_factory()
        if not isinstance(nonce, str) or not nonce or len(nonce) > 64:
            raise ValueError("Relay admission nonce is invalid")
        claims = {
            "exp": expires_at,
            "iat": issued_at,
            "nonce": nonce,
            "player_name": player_name,
            "role": role,
            "room_id": room_id,
            "v": TICKET_VERSION,
        }
        payload_bytes = json.dumps(
            claims,
            ensure_ascii=True,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        payload = base64.urlsafe_b64encode(payload_bytes).rstrip(b"=").decode(
            "ascii"
        )
        signed_message = f"{TICKET_PREFIX}.{payload}".encode("ascii")
        signature = hmac.new(
            secret_bytes,
            signed_message,
            hashlib.sha256,
        ).hexdigest()
        return f"{TICKET_PREFIX}.{payload}.{signature}"

    def verify(
        self,
        ticket: str,
        room_secret: str,
        expected_room_id: str,
    ) -> RelayAdmissionClaims:
        """Strict verifier used by backend tests to guarantee Godot parity."""
        secret_bytes = self._validate_secret(room_secret)
        if not ticket or len(ticket) > MAX_TICKET_LENGTH:
            raise RelayAdmissionTicketError("invalid ticket length")
        parts = ticket.split(".")
        if len(parts) != 3 or parts[0] != TICKET_PREFIX:
            raise RelayAdmissionTicketError("invalid ticket envelope")
        payload, supplied_signature = parts[1], parts[2]
        if len(supplied_signature) != hashlib.sha256().digest_size * 2:
            raise RelayAdmissionTicketError("invalid ticket signature length")
        try:
            int(supplied_signature, 16)
        except ValueError as exc:
            raise RelayAdmissionTicketError("invalid ticket signature") from exc

        signed_message = f"{TICKET_PREFIX}.{payload}".encode("ascii")
        expected_signature = hmac.new(
            secret_bytes,
            signed_message,
            hashlib.sha256,
        ).hexdigest()
        if not hmac.compare_digest(supplied_signature, expected_signature):
            raise RelayAdmissionTicketError("invalid ticket signature")

        padding = "=" * ((4 - len(payload) % 4) % 4)
        try:
            payload_bytes = base64.b64decode(
                (payload + padding).encode("ascii"),
                altchars=b"-_",
                validate=True,
            )
            decoded = json.loads(payload_bytes.decode("utf-8"))
        except (
            UnicodeEncodeError,
            UnicodeDecodeError,
            binascii.Error,
            json.JSONDecodeError,
        ) as exc:
            raise RelayAdmissionTicketError("invalid ticket payload") from exc
        if not isinstance(decoded, dict) or set(decoded) != {
            "exp",
            "iat",
            "nonce",
            "player_name",
            "role",
            "room_id",
            "v",
        }:
            raise RelayAdmissionTicketError("invalid ticket claims")
        version = decoded.get("v")
        if (
            isinstance(version, bool)
            or not isinstance(version, int)
            or version != TICKET_VERSION
        ):
            raise RelayAdmissionTicketError("invalid ticket version")
        if decoded.get("room_id") != expected_room_id:
            raise RelayAdmissionTicketError("ticket is for another room")
        role = decoded.get("role")
        player_name = decoded.get("player_name")
        nonce = decoded.get("nonce")
        issued_at = decoded.get("iat")
        expires_at = decoded.get("exp")
        if (
            role not in VALID_ROLES
            or not isinstance(player_name, str)
            or not player_name
            or len(player_name) > 32
            or not isinstance(nonce, str)
            or not nonce
            or len(nonce) > 64
            or isinstance(issued_at, bool)
            or not isinstance(issued_at, int)
            or isinstance(expires_at, bool)
            or not isinstance(expires_at, int)
            or issued_at < 0
            or expires_at <= issued_at
            or expires_at - issued_at > MAX_TICKET_TTL_SECONDS
        ):
            raise RelayAdmissionTicketError("invalid ticket claims")
        now = self._clock()
        if (
            not math.isfinite(now)
            or now < 0
            or now < issued_at - 30
            or now >= expires_at
        ):
            raise RelayAdmissionTicketError("ticket is outside its validity window")
        return RelayAdmissionClaims(
            room_id=expected_room_id,
            role=role,
            player_name=player_name,
            issued_at=issued_at,
            expires_at=expires_at,
            nonce=nonce,
        )
