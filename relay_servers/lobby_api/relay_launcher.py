"""
Relay 进程启动器。
通过 subprocess 启动 Godot Headless 实例，每个房间一个独立进程和端口。
"""

from __future__ import annotations

import math
import os
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import IO, Callable, Optional

from . import config


MIN_RELAY_CLIENTS = config.MIN_PLAYERS_PER_ROOM
MAX_RELAY_CLIENTS = config.PUBLIC_RELAY_MAX_PLAYERS
DEFAULT_SHUTDOWN_TIMEOUT_SECONDS = 15.0
DEFAULT_SHUTDOWN_RETRY_BACKOFF_SECONDS = 0.1
MAX_SHUTDOWN_PHASE_WAIT_SECONDS = 1.0
RELAY_ROOM_ID_ENV = "ARC_NICE_RELAY_ROOM_ID"
RELAY_ADMISSION_SECRET_ENV = "ARC_NICE_RELAY_ADMISSION_SECRET"
MIN_ADMISSION_SECRET_LENGTH = 32
MAX_ADMISSION_SECRET_LENGTH = 256
# Relay 只需操作系统运行时上下文；Lobby 的 HMAC、数据库或第三方凭据绝不能
# 因 `os.environ.copy()` 被复制到每房间子进程。
RELAY_ENVIRONMENT_ALLOWLIST = frozenset(
    {
        "PATH",
        "SYSTEMROOT",
        "WINDIR",
        "COMSPEC",
        "PATHEXT",
        "HOME",
        "USERPROFILE",
        "APPDATA",
        "LOCALAPPDATA",
        "HOMEDRIVE",
        "HOMEPATH",
        "TMP",
        "TEMP",
        "TMPDIR",
        "LANG",
        "LANGUAGE",
        "TZ",
        "LD_LIBRARY_PATH",
        "DYLD_LIBRARY_PATH",
        "XDG_RUNTIME_DIR",
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    }
)


@dataclass(frozen=True)
class RelayProcessLease:
    """一个物理 Relay 进程的不可复用身份。"""

    port: int
    pid: int
    instance_id: int


class RelayLauncher:
    """管理 Godot Headless Relay 进程的生命周期。"""

    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        # relay_port → subprocess.Popen
        self._processes: dict[int, subprocess.Popen] = {}
        self._log_files: dict[int, tuple[IO[str], IO[str]]] = {}
        # 端口从分配起即被预留，直到进程提交或启动失败；并发调用不能拿到同一端口。
        self._reserved_ports: set[int] = set()
        self._starting_ports: set[int] = set()
        # 终止完成前继续占住端口，避免旧进程尚未释放 UDP socket 就复用。
        self._stopping_ports: set[int] = set()
        self._instance_ids: dict[int, int] = {}
        # 已成功退出的端口先隔离；只有业务层关闭旧房间并确认后才能复用。
        self._quarantined_leases: dict[int, RelayProcessLease] = {}
        # 停止失败不会丢失所有者；后续 reap 会按不可变世代继续重试。
        self._termination_requests: dict[int, RelayProcessLease] = {}
        self._next_instance_id = 1
        self._shutdown_requested = False
        self._lock = threading.Condition(threading.Lock())
        self._clock = clock
        self._sleep = sleeper

    def allocate_port(self) -> Optional[int]:
        """预留一个未被占用的 Relay 端口。

        调用方必须随后调用 ``start_relay`` 提交预留，或者在放弃时
        调用 ``release_port``。新代码应优先使用 ``start_new_relay``。
        """
        port, _reaped_ports = self.allocate_port_with_reaped()
        return port

    def allocate_port_with_reaped(
        self,
    ) -> tuple[Optional[int], list[RelayProcessLease]]:
        """先发布所有待对账隔离项；未确认前不分配任何新端口。"""
        reaped_leases = self.reap_exited()
        if reaped_leases:
            return None, reaped_leases
        with self._lock:
            if self._shutdown_requested:
                return None, []
            for port in range(config.RELAY_PORT_START, config.RELAY_PORT_END + 1):
                if (
                    port not in self._processes
                    and port not in self._reserved_ports
                    and port not in self._stopping_ports
                    and port not in self._quarantined_leases
                ):
                    self._reserved_ports.add(port)
                    return port, []
        return None, []

    def release_port(self, port: int) -> bool:
        """释放尚未提交为进程的端口预留。"""
        with self._lock:
            if (
                port in self._processes
                or port in self._starting_ports
                or port in self._stopping_ports
                or port in self._quarantined_leases
            ):
                return False
            if port not in self._reserved_ports:
                return False
            self._reserved_ports.remove(port)
            return True

    def start_new_relay(
        self,
        max_clients: int,
        max_lifetime_seconds: float,
        room_id: str,
        admission_secret: str,
    ) -> tuple[
        Optional[int],
        Optional[RelayProcessLease],
        list[RelayProcessLease],
    ]:
        """预留并启动一个 Relay，避免向业务层暴露竞态窗口。

        返回 ``(port, lease, reaped_leases)``。``port is None`` 表示容量
        耗尽；``lease is None`` 表示该端口启动失败且预留已经释放。
        """
        port, reaped_leases = self.allocate_port_with_reaped()
        if port is None:
            return None, None, reaped_leases
        lease = self.start_relay(
            port,
            max_clients,
            max_lifetime_seconds,
            room_id,
            admission_secret,
        )
        return port, lease, reaped_leases

    def reap_exited(self) -> list[RelayProcessLease]:
        """重试待终止实例并返回所有尚未确认的隔离租约。"""
        self.retry_requested_terminations()
        with self._lock:
            self._reap_exited_locked()
            return list(self._quarantined_leases.values())

    def acknowledge_reaped(self, lease: RelayProcessLease) -> bool:
        """业务层已终结旧房间后，按完整世代解除端口隔离。"""
        with self._lock:
            quarantined = self._quarantined_leases.get(lease.port)
            # 并发对账可能重复确认；已经确认过视为幂等成功。
            if quarantined is None:
                return True
            if quarantined != lease:
                return False
            self._quarantined_leases.pop(lease.port, None)
            return True

    def _reap_exited_locked(self) -> None:
        """在持有 ``_lock`` 时回收死亡进程及其日志句柄。"""
        for port, proc in list(self._processes.items()):
            # 条件停止拥有该实例的终结权；reap 不得并发释放同一端口。
            if port in self._stopping_ports:
                continue
            try:
                return_code = proc.poll()
            except Exception as exc:
                print(f"[RelayLauncher] 检查 Relay 状态失败 port={port}: {exc}")
                continue
            if return_code is None:
                continue

            instance_id = self._instance_ids.get(port, 0)
            try:
                pid = int(proc.pid)
            except (TypeError, ValueError) as exc:
                print(
                    f"[RelayLauncher] Relay PID 无效，保持端口占用 "
                    f"port={port}: {exc}"
                )
                continue
            if instance_id <= 0 or pid <= 0:
                # 身份不完整时宁可保持占用，也不能把未知世代端口交给新房间。
                print(
                    f"[RelayLauncher] Relay 世代身份缺失，保持端口占用 "
                    f"port={port}, pid={pid}, instance={instance_id}"
                )
                continue
            lease = RelayProcessLease(
                port=port,
                pid=pid,
                instance_id=instance_id,
            )
            self._processes.pop(port, None)
            self._instance_ids.pop(port, None)
            self._termination_requests.pop(port, None)
            log_files = self._log_files.pop(port, None)
            if log_files is not None:
                for log_file in log_files:
                    try:
                        log_file.close()
                    except Exception as exc:
                        print(
                            "[RelayLauncher] 关闭已退出 Relay 的日志失败 "
                            f"port={port}: {exc}"
                        )
            self._quarantined_leases[port] = lease
            print(
                f"[RelayLauncher] 已回收退出的 Relay port={port}, "
                f"return_code={return_code}"
            )

    def start_relay(
        self,
        port: int,
        max_clients: int,
        max_lifetime_seconds: float = config.GAME_MAX_DURATION_SECONDS,
        room_id: str = "",
        admission_secret: str = "",
    ) -> Optional[RelayProcessLease]:
        """
        启动一个 Relay 实例，返回不可复用的进程租约。
        失败返回 None。
        """
        # 文件与进程操作前先声明 STARTING，阻止同一预留端口被并发 spawn。
        with self._lock:
            if (
                self._shutdown_requested
                or port in self._processes
                or port in self._starting_ports
                or port in self._stopping_ports
                or port in self._quarantined_leases
            ):
                return None
            self._reserved_ports.add(port)
            self._starting_ports.add(port)

        if (
            not math.isfinite(max_lifetime_seconds)
            or max_lifetime_seconds <= 0
        ):
            print(
                "[RelayLauncher] Relay 剩余绝对生命周期必须大于 0 "
                f"(max_lifetime_seconds={max_lifetime_seconds})"
            )
            self._release_failed_start(port)
            return None

        if (
            max_clients < MIN_RELAY_CLIENTS
            or max_clients > MAX_RELAY_CLIENTS
        ):
            print(
                "[RelayLauncher] Relay 最大连接数超出允许范围 "
                f"(max_clients={max_clients}, "
                f"allowed={MIN_RELAY_CLIENTS}..{MAX_RELAY_CLIENTS})"
            )
            self._release_failed_start(port)
            return None

        if (
            not room_id
            or len(room_id) > 64
            or not room_id.isascii()
            or any(
                not (character.isalnum() or character in "-_")
                for character in room_id
            )
        ):
            print("[RelayLauncher] Relay room_id 无效，拒绝启动")
            self._release_failed_start(port)
            return None
        try:
            encoded_secret = admission_secret.encode("ascii")
        except UnicodeEncodeError:
            encoded_secret = b""
        if not (
            MIN_ADMISSION_SECRET_LENGTH
            <= len(encoded_secret)
            <= MAX_ADMISSION_SECRET_LENGTH
        ):
            print("[RelayLauncher] Relay admission secret 无效，拒绝启动")
            self._release_failed_start(port)
            return None

        godot_path = config.GODOT_SERVER_PATH
        project_path = config.RELAY_PROJECT_PATH

        if not os.path.isfile(godot_path):
            print(f"[RelayLauncher] Godot 可执行文件不存在: {godot_path}")
            self._release_failed_start(port)
            return None

        if not os.path.isdir(project_path):
            print(f"[RelayLauncher] Relay 项目路径不存在: {project_path}")
            self._release_failed_start(port)
            return None

        cmd = [
            godot_path,
            "--headless",
            "--path", project_path,
            "--",
            f"--port={port}",
            (
                "--startup-idle-timeout="
                f"{config.RELAY_STARTUP_IDLE_TIMEOUT_SECONDS}"
            ),
            (
                "--empty-idle-timeout="
                f"{config.RELAY_EMPTY_IDLE_TIMEOUT_SECONDS}"
            ),
            f"--max-lifetime={max_lifetime_seconds}",
            f"--max-clients={max_clients}",
        ]

        log_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")
        stdout_path = os.path.join(log_dir, f"relay_{port}.out.log")
        stderr_path = os.path.join(log_dir, f"relay_{port}.err.log")
        try:
            os.makedirs(log_dir, exist_ok=True)
            stdout_file = open(
                stdout_path,
                "a",
                encoding="utf-8",
                buffering=1,
            )
            try:
                stderr_file = open(
                    stderr_path,
                    "a",
                    encoding="utf-8",
                    buffering=1,
                )
            except Exception:
                stdout_file.close()
                raise
        except Exception as exc:
            self._release_failed_start(port)
            print(f"[RelayLauncher] 打开 Relay 日志失败 (port={port}): {exc}")
            return None

        try:
            relay_environment = self._build_relay_environment(
                room_id,
                admission_secret,
            )
            proc = subprocess.Popen(
                cmd,
                stdout=stdout_file,
                stderr=stderr_file,
                env=relay_environment,
            )
        except Exception as e:
            stdout_file.close()
            stderr_file.close()
            self._release_failed_start(port)
            print(f"[RelayLauncher] 启动 Relay 失败 (port={port}): {e}")
            return None

        with self._lock:
            instance_id = self._next_instance_id
            self._next_instance_id += 1
            self._starting_ports.discard(port)
            self._reserved_ports.discard(port)
            self._processes[port] = proc
            self._log_files[port] = (stdout_file, stderr_file)
            self._instance_ids[port] = instance_id
            cancelled_by_shutdown = self._shutdown_requested
            self._lock.notify_all()

        lease = RelayProcessLease(
            port=port,
            pid=proc.pid,
            instance_id=instance_id,
        )

        print(
            f"[RelayLauncher] Relay 已启动 port={port}, max_clients={max_clients}, "
            f"pid={proc.pid}, "
            f"stdout={stdout_path}, stderr={stderr_path}"
        )
        if cancelled_by_shutdown:
            print(
                f"[RelayLauncher] Relay 启动完成时服务已关闭，禁止发布实例 "
                f"port={port}, instance={instance_id}"
            )
            return None
        return lease

    @staticmethod
    def _build_relay_environment(
        room_id: str,
        admission_secret: str,
    ) -> dict[str, str]:
        environment = {
            key: value
            for key, value in os.environ.items()
            if (
                key.upper() in RELAY_ENVIRONMENT_ALLOWLIST
                or key.upper().startswith("LC_")
            )
        }
        environment[RELAY_ROOM_ID_ENV] = room_id
        environment[RELAY_ADMISSION_SECRET_ENV] = admission_secret
        return environment

    def _release_failed_start(self, port: int) -> None:
        """启动失败后归还端口；必须覆盖所有失败分支。"""
        with self._lock:
            self._starting_ports.discard(port)
            self._reserved_ports.discard(port)
            self._lock.notify_all()

    def stop_relay(
        self,
        port: int,
        expected_instance_id: int,
        *,
        wait_timeout_seconds: float = 5.0,
    ) -> bool:
        """仅停止预期世代；确认退出前不释放实例身份或端口。"""
        if (
            not math.isfinite(wait_timeout_seconds)
            or wait_timeout_seconds < 0
        ):
            raise ValueError("wait_timeout_seconds 必须是有限非负数")
        with self._lock:
            actual_instance_id = self._instance_ids.get(port)
            if actual_instance_id != expected_instance_id:
                pending = self._termination_requests.get(port)
                if pending is not None and pending.instance_id == expected_instance_id:
                    self._termination_requests.pop(port, None)
                return False
            proc = self._processes.get(port)
            log_files = self._log_files.get(port)
            if proc is None:
                return False
            lease = RelayProcessLease(port, int(proc.pid), expected_instance_id)
            self._termination_requests[port] = lease
            if port in self._stopping_ports:
                return False
            self._stopping_ports.add(port)

        stopped = False
        try:
            stopped = proc.poll() is not None
        except Exception as exc:
            print(f"[RelayLauncher] 检查待停止 Relay 失败 (port={port}): {exc}")

        if not stopped:
            try:
                # Relay 不派生业务子进程；精确操作 Popen，避免 PID/PGID 复用误杀。
                proc.terminate()
                proc.wait(timeout=wait_timeout_seconds)
                stopped = True
            except Exception as exc:
                print(f"[RelayLauncher] Relay 优雅停止失败 (port={port}): {exc}")
                try:
                    proc.kill()
                    proc.wait(timeout=wait_timeout_seconds)
                    stopped = True
                except Exception as kill_exc:
                    print(
                        f"[RelayLauncher] Relay 强制停止失败 (port={port}): "
                        f"{kill_exc}"
                    )

        if not stopped:
            with self._lock:
                self._stopping_ports.discard(port)
            # process/log/instance 与 termination request 一并保留供下轮 reap 重试。
            return False

        with self._lock:
            if (
                self._processes.get(port) is not proc
                or self._instance_ids.get(port) != expected_instance_id
            ):
                self._stopping_ports.discard(port)
                return False
            self._processes.pop(port, None)
            self._log_files.pop(port, None)
            self._instance_ids.pop(port, None)
            self._termination_requests.pop(port, None)
            self._reserved_ports.discard(port)
            self._starting_ports.discard(port)
            self._stopping_ports.discard(port)
            self._quarantined_leases[port] = lease

        if log_files is not None:
            for log_file in log_files:
                try:
                    log_file.close()
                except Exception as exc:
                    print(
                        f"[RelayLauncher] 关闭 Relay 日志失败 port={port}: {exc}"
                    )

        print(f"[RelayLauncher] Relay 已停止 port={port}")
        return True

    def retry_requested_terminations(self) -> None:
        """重试所有仍绑定同一物理实例的终止请求。"""
        with self._lock:
            pending = list(self._termination_requests.values())
        for lease in pending:
            self.stop_relay(lease.port, lease.instance_id)

    def stop_all(
        self,
        total_timeout_seconds: float = DEFAULT_SHUTDOWN_TIMEOUT_SECONDS,
        retry_backoff_seconds: float = DEFAULT_SHUTDOWN_RETRY_BACKOFF_SECONDS,
    ) -> list[RelayProcessLease]:
        """在单调总期限内反复停止并 reap，返回仍未终止的精确实例。"""
        if (
            not math.isfinite(total_timeout_seconds)
            or total_timeout_seconds <= 0
        ):
            raise ValueError("total_timeout_seconds 必须是有限正数")
        if (
            not math.isfinite(retry_backoff_seconds)
            or retry_backoff_seconds <= 0
        ):
            raise ValueError("retry_backoff_seconds 必须是有限正数")

        with self._lock:
            self._shutdown_requested = True
            # Popen 提交前还没有 PID/lease 可返回，因此必须等待其完成 CAS；
            # 提交者看到 shutdown 标记后不会向业务层发布 ACTIVE。
            while self._starting_ports:
                self._lock.wait()
            leases = [
                RelayProcessLease(port, int(proc.pid), self._instance_ids[port])
                for port, proc in self._processes.items()
                if port in self._instance_ids
            ]
        if not leases:
            return []

        deadline = self._clock() + total_timeout_seconds
        unresolved = leases
        while unresolved:
            with self._lock:
                self._reap_exited_locked()
                unresolved = [
                    lease
                    for lease in leases
                    if self._instance_ids.get(lease.port) == lease.instance_id
                    and lease.port in self._processes
                ]
            for lease in leases:
                if lease not in unresolved:
                    self.acknowledge_reaped(lease)
            if not unresolved:
                return []

            for index, lease in enumerate(unresolved):
                remaining_seconds = deadline - self._clock()
                if remaining_seconds <= 0:
                    break
                remaining_count = len(unresolved) - index
                # 为本轮尚未尝试的实例公平分配 terminate/kill 两段 wait 预算。
                phase_wait_seconds = min(
                    MAX_SHUTDOWN_PHASE_WAIT_SECONDS,
                    remaining_seconds / float(remaining_count * 2),
                )
                self.stop_relay(
                    lease.port,
                    lease.instance_id,
                    wait_timeout_seconds=phase_wait_seconds,
                )

            with self._lock:
                self._reap_exited_locked()
                unresolved = [
                    lease
                    for lease in leases
                    if self._instance_ids.get(lease.port) == lease.instance_id
                    and lease.port in self._processes
                ]
            for lease in leases:
                if lease not in unresolved:
                    self.acknowledge_reaped(lease)
            if not unresolved:
                return []

            remaining_seconds = deadline - self._clock()
            if remaining_seconds <= 0:
                break
            self._sleep(min(retry_backoff_seconds, remaining_seconds))

        # 失败实例仍留在 process/termination ledger 中，绝不释放端口。
        return unresolved

    def is_relay_running(self, port: int, expected_instance_id: int) -> bool:
        """检查指定世代的 Relay 是否仍在运行。"""
        with self._lock:
            if self._instance_ids.get(port) != expected_instance_id:
                return False
            proc = self._processes.get(port)
            if proc is None:
                return False
            try:
                return proc.poll() is None
            except Exception as exc:
                print(f"[RelayLauncher] 检查 Relay 状态失败 port={port}: {exc}")
                return False

    def get_active_count(self) -> int:
        """返回当前活跃的 Relay 数量。"""
        with self._lock:
            active_count = 0
            for port, proc in self._processes.items():
                try:
                    if proc.poll() is None:
                        active_count += 1
                except Exception as exc:
                    print(
                        f"[RelayLauncher] 统计 Relay 状态失败 port={port}: {exc}"
                    )
            return active_count
