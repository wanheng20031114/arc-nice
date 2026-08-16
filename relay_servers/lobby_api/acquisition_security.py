"""公网 acquisition capability 与单进程准入限流。"""

from __future__ import annotations

import base64
import hashlib
import hmac
import math
import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Optional


CAPABILITY_VERSION = "acq1"
CAPABILITY_ACTIONS = frozenset({"create", "join", "quick_match"})
_NONCE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{22}$")
_FINGERPRINT_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_SIGNATURE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")


class AcquisitionCapabilityError(ValueError):
    """capability 格式、签名、动作或参数无效。"""


class AcquisitionCapabilityExpiredError(AcquisitionCapabilityError):
    """capability 已超过当前端点允许的时间窗口。"""


@dataclass(frozen=True)
class AcquisitionCapabilityClaims:
    action: str
    expires_at: int
    payload_fingerprint: str
    nonce: str = field(repr=False)


@dataclass(frozen=True)
class IssuedAcquisitionCapability:
    token: str = field(repr=False)
    expires_at: int


def fingerprint_canonical_payload(
    action: str,
    canonical_payload: tuple[str, ...],
) -> str:
    """长度前缀消除字段拼接歧义，动作同时进入 payload 指纹。"""
    if action not in CAPABILITY_ACTIONS:
        raise ValueError("未知 acquisition action")
    digest = hashlib.sha256()
    for value in (action, *canonical_payload):
        encoded = value.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
    return digest.hexdigest()


class AcquisitionCapabilitySigner:
    def __init__(
        self,
        secret: bytes,
        ttl_seconds: int,
        *,
        clock: Callable[[], float] = time.time,
        nonce_factory: Callable[[int], bytes] = secrets.token_bytes,
    ) -> None:
        if len(secret) < 32 or len(set(secret)) < 12:
            raise ValueError("HMAC secret 强度不足")
        if ttl_seconds <= 0 or ttl_seconds > 60:
            raise ValueError("capability TTL 必须在 1..60 秒")
        self._secret = bytes(secret)
        self._ttl_seconds = ttl_seconds
        self._clock = clock
        self._nonce_factory = nonce_factory

    def issue(
        self,
        action: str,
        canonical_payload: tuple[str, ...],
    ) -> IssuedAcquisitionCapability:
        now = self._checked_now()
        fingerprint = fingerprint_canonical_payload(action, canonical_payload)
        nonce_bytes = self._nonce_factory(16)
        if len(nonce_bytes) != 16:
            raise RuntimeError("nonce_factory 必须返回 16 bytes")
        nonce = self._encode_urlsafe(nonce_bytes)
        expires_at = int(now) + self._ttl_seconds
        unsigned = self._unsigned_token(action, expires_at, nonce, fingerprint)
        signature = self._encode_urlsafe(
            hmac.digest(self._secret, unsigned.encode("ascii"), "sha256")
        )
        return IssuedAcquisitionCapability(
            token=f"{unsigned}.{signature}",
            expires_at=expires_at,
        )

    def verify(
        self,
        token: str,
        *,
        expected_action: Optional[str] = None,
        expected_payload: Optional[tuple[str, ...]] = None,
        expiry_grace_seconds: float = 0.0,
    ) -> AcquisitionCapabilityClaims:
        if expiry_grace_seconds < 0 or not math.isfinite(expiry_grace_seconds):
            raise ValueError("expiry_grace_seconds 必须是有限非负数")
        parts = token.split(".")
        if len(parts) != 6 or parts[0] != CAPABILITY_VERSION:
            raise AcquisitionCapabilityError("acquisition capability 格式无效")
        _version, action, expiry_text, nonce, fingerprint, signature = parts
        if (
            action not in CAPABILITY_ACTIONS
            or not expiry_text.isascii()
            or not expiry_text.isdigit()
            or len(expiry_text) not in (10, 11)
            or _NONCE_PATTERN.fullmatch(nonce) is None
            or _FINGERPRINT_PATTERN.fullmatch(fingerprint) is None
            or _SIGNATURE_PATTERN.fullmatch(signature) is None
        ):
            raise AcquisitionCapabilityError("acquisition capability 格式无效")
        expires_at = int(expiry_text)
        unsigned = self._unsigned_token(action, expires_at, nonce, fingerprint)
        expected_signature = self._encode_urlsafe(
            hmac.digest(self._secret, unsigned.encode("ascii"), "sha256")
        )
        if not hmac.compare_digest(signature, expected_signature):
            raise AcquisitionCapabilityError("acquisition capability 签名无效")
        if expected_action is not None and action != expected_action:
            raise AcquisitionCapabilityError("acquisition capability 动作不匹配")
        if expected_payload is not None:
            if expected_action is None:
                raise ValueError("校验 payload 时必须提供 expected_action")
            expected_fingerprint = fingerprint_canonical_payload(
                expected_action,
                expected_payload,
            )
            if not hmac.compare_digest(fingerprint, expected_fingerprint):
                raise AcquisitionCapabilityError("acquisition capability 参数不匹配")
        if self._checked_now() >= expires_at + expiry_grace_seconds:
            raise AcquisitionCapabilityExpiredError("acquisition capability 已过期")
        return AcquisitionCapabilityClaims(
            action=action,
            expires_at=expires_at,
            payload_fingerprint=fingerprint,
            nonce=nonce,
        )

    def _checked_now(self) -> float:
        now = self._clock()
        if not math.isfinite(now) or now < 0:
            raise RuntimeError("capability clock 必须返回有限非负数")
        return now

    @staticmethod
    def _unsigned_token(
        action: str,
        expires_at: int,
        nonce: str,
        fingerprint: str,
    ) -> str:
        return ".".join(
            (
                CAPABILITY_VERSION,
                action,
                str(expires_at),
                nonce,
                fingerprint,
            )
        )

    @staticmethod
    def _encode_urlsafe(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: float = 0.0


@dataclass
class _TokenBucket:
    tokens: float
    refilled_at: float
    last_seen_at: float


class DualTokenBucketRateLimiter:
    """同锁原子消费全局与来源桶；不会相信任何转发请求头。"""

    def __init__(
        self,
        *,
        global_burst: int,
        global_refill_per_second: float,
        source_burst: int,
        source_refill_per_second: float,
        source_bucket_capacity: int,
        source_idle_ttl_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        values = (
            global_burst,
            global_refill_per_second,
            source_burst,
            source_refill_per_second,
            source_bucket_capacity,
            source_idle_ttl_seconds,
        )
        if any(not math.isfinite(float(value)) or value <= 0 for value in values):
            raise ValueError("rate limiter 边界必须是有限正数")
        if source_burst > global_burst:
            raise ValueError("来源 burst 不能大于全局 burst")
        if source_bucket_capacity < global_burst:
            raise ValueError("来源桶容量不能小于全局 burst")
        self._global_burst = float(global_burst)
        self._global_refill_per_second = float(global_refill_per_second)
        self._source_burst = float(source_burst)
        self._source_refill_per_second = float(source_refill_per_second)
        self._source_bucket_capacity = int(source_bucket_capacity)
        self._source_idle_ttl_seconds = float(source_idle_ttl_seconds)
        self._clock = clock
        now = self._checked_now()
        self._global_bucket = _TokenBucket(self._global_burst, now, now)
        self._source_buckets: dict[str, _TokenBucket] = {}
        self._lock = threading.Lock()

    def consume(self, source: str) -> RateLimitDecision:
        normalized_source = source.strip() or "<unknown>"
        with self._lock:
            now = self._checked_now()
            self._prune_sources_locked(now)
            self._refill_locked(
                self._global_bucket,
                self._global_burst,
                self._global_refill_per_second,
                now,
            )
            global_retry = self._retry_after(
                self._global_bucket.tokens,
                self._global_refill_per_second,
            )
            if global_retry > 0:
                # 全局预算耗尽时不能让伪造来源借机污染有界 source map。
                return RateLimitDecision(False, global_retry)
            source_bucket = self._source_buckets.get(normalized_source)
            if source_bucket is None:
                if len(self._source_buckets) >= self._source_bucket_capacity:
                    return RateLimitDecision(
                        False,
                        self._source_capacity_retry_after_locked(now),
                    )
                source_bucket = _TokenBucket(self._source_burst, now, now)
                self._source_buckets[normalized_source] = source_bucket
            self._refill_locked(
                source_bucket,
                self._source_burst,
                self._source_refill_per_second,
                now,
            )
            source_bucket.last_seen_at = now
            source_retry = self._retry_after(
                source_bucket.tokens,
                self._source_refill_per_second,
            )
            if source_retry > 0:
                return RateLimitDecision(False, source_retry)
            self._global_bucket.tokens -= 1.0
            source_bucket.tokens -= 1.0
            return RateLimitDecision(True)

    def source_bucket_count(self) -> int:
        with self._lock:
            return len(self._source_buckets)

    def _checked_now(self) -> float:
        now = self._clock()
        if not math.isfinite(now) or now < 0:
            raise RuntimeError("rate limiter clock 必须返回有限非负数")
        return now

    def _prune_sources_locked(self, now: float) -> None:
        for source, bucket in list(self._source_buckets.items()):
            if now - bucket.last_seen_at >= self._source_idle_ttl_seconds:
                self._source_buckets.pop(source, None)

    def _source_capacity_retry_after_locked(self, now: float) -> float:
        if not self._source_buckets:
            return self._source_idle_ttl_seconds
        oldest_seen = min(
            bucket.last_seen_at for bucket in self._source_buckets.values()
        )
        return max(
            0.001,
            self._source_idle_ttl_seconds - (now - oldest_seen),
        )

    @staticmethod
    def _refill_locked(
        bucket: _TokenBucket,
        burst: float,
        refill_per_second: float,
        now: float,
    ) -> None:
        elapsed = max(0.0, now - bucket.refilled_at)
        bucket.tokens = min(burst, bucket.tokens + elapsed * refill_per_second)
        bucket.refilled_at = now

    @staticmethod
    def _retry_after(tokens: float, refill_per_second: float) -> float:
        if tokens >= 1.0:
            return 0.0
        return (1.0 - tokens) / refill_per_second
