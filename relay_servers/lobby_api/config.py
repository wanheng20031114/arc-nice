"""
大厅服务器配置。
"""

import math
import os

from .models import (
    DEFAULT_PLAYERS_PER_ROOM as DOMAIN_DEFAULT_PLAYERS_PER_ROOM,
    MAX_SUPPORTED_PLAYERS_PER_ROOM,
    MIN_PLAYERS_PER_ROOM as DOMAIN_MIN_PLAYERS_PER_ROOM,
)
from .relay_admission import (
    MAX_TICKET_REFRESH_BURST,
    MAX_TICKET_REFRESH_WINDOW_SECONDS,
    MIN_TICKET_REFRESH_BURST,
    MIN_TICKET_REFRESH_WINDOW_SECONDS,
)


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    """读取有界整数；部署错误必须在服务启动前失败。"""
    raw_value = os.getenv(name, str(default))
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} 必须是整数，当前值: {raw_value}") from exc
    if value < minimum or value > maximum:
        raise ValueError(
            f"{name} 必须在 {minimum}..{maximum} 之间，当前值: {value}"
        )
    return value


def _bounded_float(
    name: str,
    default: float,
    minimum: float,
    maximum: float,
) -> float:
    """读取有限有界浮点数；限流边界不能用 NaN/inf 绕过。"""
    raw_value = os.getenv(name, str(default))
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} 必须是数字，当前值: {raw_value}") from exc
    if not math.isfinite(value) or value < minimum or value > maximum:
        raise ValueError(
            f"{name} 必须在 {minimum}..{maximum} 之间，当前值: {value}"
        )
    return value


def _strict_bool(name: str, default: bool) -> bool:
    raw_value = os.getenv(name, "true" if default else "false").strip().lower()
    if raw_value == "true":
        return True
    if raw_value == "false":
        return False
    raise ValueError(f"{name} 只能是 true 或 false，当前值: {raw_value}")


def _required_secret(name: str, minimum_bytes: int = 32) -> bytes:
    """读取不可预测的 HMAC secret；错误信息绝不回显 secret。"""
    raw_value = os.getenv(name)
    if raw_value is None or raw_value != raw_value.strip():
        raise ValueError(f"{name} 必须显式配置且不能包含首尾空白")
    encoded = raw_value.encode("utf-8")
    if len(encoded) < minimum_bytes or len(set(encoded)) < 12:
        raise ValueError(
            f"{name} 强度不足：至少 {minimum_bytes} bytes 且字符种类不少于 12"
        )
    return encoded


# ─── 网络 ────────────────────────────────────────
LOBBY_HOST = os.getenv("LOBBY_HOST", "0.0.0.0")
LOBBY_PORT = _bounded_int("LOBBY_PORT", 8000, 1, 65535)

# ─── Relay 端口范围 ──────────────────────────────
RELAY_PORT_START = _bounded_int("RELAY_PORT_START", 40001, 1, 65535)
RELAY_PORT_END = _bounded_int("RELAY_PORT_END", 40100, 1, 65535)
if RELAY_PORT_START > RELAY_PORT_END:
    raise ValueError(
        "RELAY_PORT_START 不能大于 RELAY_PORT_END，"
        f"当前为 {RELAY_PORT_START} > {RELAY_PORT_END}"
    )

# ─── Godot Headless 路径 ─────────────────────────
# 阿里云 Linux 上的 Godot Server 二进制路径
GODOT_SERVER_PATH = os.getenv(
    "GODOT_SERVER_PATH",
    "/opt/godot/Godot_v4.6-stable_linux.x86_64"
)

# Relay Godot 项目路径
RELAY_PROJECT_PATH = os.getenv(
    "RELAY_PROJECT_PATH",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "relay_godot_project")
)

# ─── 生命周期租约 ──────────────────────────────────


def _positive_seconds(name: str, default: float) -> float:
    """读取严格为正的秒数，拒绝会关闭回收边界的部署配置。"""
    raw_value = os.getenv(name, str(default))
    try:
        value = float(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} 必须是秒数，当前值: {raw_value}") from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} 必须是有限正数，当前值: {value}")
    return value


def _seconds_at_least(name: str, default: float, minimum: float) -> float:
    value = _positive_seconds(name, default)
    if value < minimum:
        raise ValueError(f"{name} 不能低于 {minimum} 秒，当前值: {value}")
    return value


def _seconds_between(
    name: str,
    default: float,
    minimum: float,
    maximum: float,
) -> float:
    value = _seconds_at_least(name, default, minimum)
    if value > maximum:
        raise ValueError(f"{name} 不能高于 {maximum} 秒，当前值: {value}")
    return value


# 客户端在游戏中每 60 秒续租；180 秒允许两个续租周期抖动。该 deadline
# 只由 IN_GAME 房主心跳推进，等待大厅阶段暂不建立，也不能突破绝对上限。
ROOM_IDLE_TIMEOUT_SECONDS = _seconds_at_least(
    "ROOM_IDLE_TIMEOUT_SECONDS",
    180.0,
    120.0,
)

# Relay 从启动到首次 ENet 连接的独立窗口。
RELAY_STARTUP_IDLE_TIMEOUT_SECONDS = _positive_seconds(
    "RELAY_STARTUP_IDLE_TIMEOUT_SECONDS",
    120.0,
)

# 所有玩家离开后的空载窗口需长于客户端 90 秒重连宽限。
RELAY_EMPTY_IDLE_TIMEOUT_SECONDS = _seconds_at_least(
    "RELAY_EMPTY_IDLE_TIMEOUT_SECONDS",
    120.0,
    91.0,
)

# 无论 keepalive 或 ENet 活跃度如何，一局及其 Relay 都不能超过该绝对上限。
GAME_MAX_DURATION_SECONDS = _positive_seconds("GAME_MAX_DURATION_SECONDS", 36000.0)

# 清理轮询只决定过期后最多再等待多久，不参与续租期限计算。
CLEANUP_INTERVAL_SECONDS = _positive_seconds("CLEANUP_INTERVAL_SECONDS", 30.0)

# Relay 启动后给 Godot/ENet 完成监听的等待时间（秒）
RELAY_STARTUP_GRACE_SECONDS = _positive_seconds("RELAY_STARTUP_GRACE_SECONDS", 5.0)

# admission ticket 是单次使用的短连接能力；重连必须用 member_token 换新票。
RELAY_ADMISSION_TICKET_TTL_SECONDS = _seconds_between(
    "RELAY_ADMISSION_TICKET_TTL_SECONDS",
    60.0,
    15.0,
    120.0,
)
# 每个已验证成员允许短突发，覆盖 HTTP/认证 ack 丢失后的即时重试；随后按滚动
# 窗口收紧，避免合法 member_token 被用来持续制造新 nonce。
RELAY_ADMISSION_REFRESH_BURST = _bounded_int(
    "RELAY_ADMISSION_REFRESH_BURST",
    3,
    MIN_TICKET_REFRESH_BURST,
    MAX_TICKET_REFRESH_BURST,
)
RELAY_ADMISSION_REFRESH_WINDOW_SECONDS = _seconds_between(
    "RELAY_ADMISSION_REFRESH_WINDOW_SECONDS",
    5.0,
    MIN_TICKET_REFRESH_WINDOW_SECONDS,
    MAX_TICKET_REFRESH_WINDOW_SECONDS,
)


def _require_strict_order(
    lower_name: str,
    lower_value: float,
    upper_name: str,
    upper_value: float,
) -> None:
    if lower_value >= upper_value:
        raise ValueError(
            f"生命周期配置必须满足 {lower_name} < {upper_name}，"
            f"当前为 {lower_value} >= {upper_value}"
        )


_require_strict_order(
    "CLEANUP_INTERVAL_SECONDS",
    CLEANUP_INTERVAL_SECONDS,
    "ROOM_IDLE_TIMEOUT_SECONDS",
    ROOM_IDLE_TIMEOUT_SECONDS,
)
_require_strict_order(
    "ROOM_IDLE_TIMEOUT_SECONDS",
    ROOM_IDLE_TIMEOUT_SECONDS,
    "GAME_MAX_DURATION_SECONDS",
    GAME_MAX_DURATION_SECONDS,
)
_require_strict_order(
    "RELAY_STARTUP_GRACE_SECONDS",
    RELAY_STARTUP_GRACE_SECONDS,
    "RELAY_ADMISSION_TICKET_TTL_SECONDS",
    RELAY_ADMISSION_TICKET_TTL_SECONDS,
)
_require_strict_order(
    "RELAY_STARTUP_GRACE_SECONDS",
    RELAY_STARTUP_GRACE_SECONDS,
    "RELAY_STARTUP_IDLE_TIMEOUT_SECONDS",
    RELAY_STARTUP_IDLE_TIMEOUT_SECONDS,
)
_require_strict_order(
    "RELAY_STARTUP_IDLE_TIMEOUT_SECONDS",
    RELAY_STARTUP_IDLE_TIMEOUT_SECONDS,
    "GAME_MAX_DURATION_SECONDS",
    GAME_MAX_DURATION_SECONDS,
)
_require_strict_order(
    "RELAY_EMPTY_IDLE_TIMEOUT_SECONDS",
    RELAY_EMPTY_IDLE_TIMEOUT_SECONDS,
    "GAME_MAX_DURATION_SECONDS",
    GAME_MAX_DURATION_SECONDS,
)

# ─── 限制 ────────────────────────────────────────
_relay_port_capacity = RELAY_PORT_END - RELAY_PORT_START + 1
MAX_ROOMS = _bounded_int("MAX_ROOMS", 100, 1, _relay_port_capacity)
MIN_PLAYERS_PER_ROOM = DOMAIN_MIN_PLAYERS_PER_ROOM
DEFAULT_PLAYERS_PER_ROOM = DOMAIN_DEFAULT_PLAYERS_PER_ROOM
MAX_PLAYERS_PER_ROOM = _bounded_int(
    "MAX_PLAYERS_PER_ROOM",
    MAX_SUPPORTED_PLAYERS_PER_ROOM,
    DEFAULT_PLAYERS_PER_ROOM,
    MAX_SUPPORTED_PLAYERS_PER_ROOM,
)
# 公网 API、Launcher 与 Relay 必须从同一个容量真源派生，避免某一层仍把
# 合法的 3..8 人房间截断或拒绝。
PUBLIC_RELAY_MAX_PLAYERS = MAX_PLAYERS_PER_ROOM

# 创建/加入响应尚未被客户端确认前只授予短租约；这条服务端兜底不依赖
# 客户端取消请求一定能送达。
ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS = _seconds_between(
    "ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS",
    60.0,
    30.0,
    60.0,
)
# cancel 可能先于原请求到达；墓碑必须覆盖客户端 12 秒请求上限与临时租约。
ACQUISITION_TOMBSTONE_TTL_SECONDS = _seconds_between(
    "ACQUISITION_TOMBSTONE_TTL_SECONDS",
    120.0,
    120.0,
    600.0,
)
_require_strict_order(
    "ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS",
    ACQUISITION_PROVISIONAL_TIMEOUT_SECONDS,
    "ACQUISITION_TOMBSTONE_TTL_SECONDS",
    ACQUISITION_TOMBSTONE_TTL_SECONDS,
)

# 活动索引与取消墓碑共享容量，并为每个活动占位预留一个墓碑槽。
ACQUISITION_TOKEN_CAPACITY = _bounded_int(
    "ACQUISITION_TOKEN_CAPACITY",
    4096,
    MAX_ROOMS * MAX_PLAYERS_PER_ROOM + 1,
    100_000,
)

# capability 只覆盖 preflight 到实际命令的短窗口；成员确认改用独立 member_token。
ACQUISITION_CAPABILITY_TTL_SECONDS = _bounded_int(
    "ACQUISITION_CAPABILITY_TTL_SECONDS",
    45,
    15,
    60,
)
ACQUISITION_CAPABILITY_HMAC_SECRET = _required_secret(
    "ACQUISITION_CAPABILITY_HMAC_SECRET"
)

# 旧客户端只能由部署者显式开启；生产模板默认拒绝无 capability 的 acquisition。
ALLOW_LEGACY_ACQUISITION_REQUESTS = _strict_bool(
    "ALLOW_LEGACY_ACQUISITION_REQUESTS",
    False,
)

# preflight 与显式 legacy acquisition 共用一个进程内双层 token bucket。
ACQUISITION_ADMISSION_GLOBAL_BURST = _bounded_int(
    "ACQUISITION_ADMISSION_GLOBAL_BURST",
    120,
    1,
    10_000,
)
ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND = _bounded_float(
    "ACQUISITION_ADMISSION_GLOBAL_REFILL_PER_SECOND",
    4.0,
    0.01,
    1_000.0,
)
ACQUISITION_ADMISSION_SOURCE_BURST = _bounded_int(
    "ACQUISITION_ADMISSION_SOURCE_BURST",
    8,
    1,
    ACQUISITION_ADMISSION_GLOBAL_BURST,
)
ACQUISITION_ADMISSION_SOURCE_REFILL_PER_SECOND = _bounded_float(
    "ACQUISITION_ADMISSION_SOURCE_REFILL_PER_SECOND",
    0.5,
    0.01,
    1_000.0,
)
ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY = _bounded_int(
    "ACQUISITION_ADMISSION_SOURCE_BUCKET_CAPACITY",
    4096,
    ACQUISITION_ADMISSION_GLOBAL_BURST,
    100_000,
)
ACQUISITION_ADMISSION_SOURCE_IDLE_TTL_SECONDS = _bounded_float(
    "ACQUISITION_ADMISSION_SOURCE_IDLE_TTL_SECONDS",
    600.0,
    60.0,
    86_400.0,
)

# ─── 公网 IP ─────────────────────────────────────
# 用于告诉客户端 Relay 地址，需设置为阿里云 ECS 公网 IP
PUBLIC_IP = os.getenv("PUBLIC_IP", "127.0.0.1")
