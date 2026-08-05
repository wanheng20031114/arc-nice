"""
Relay 进程启动器。
通过 subprocess 启动 Godot Headless 实例，每个房间一个独立进程和端口。
"""

from __future__ import annotations

import os
import subprocess
import threading
import signal
from typing import IO, Optional

from . import config


MIN_RELAY_CLIENTS = 2
MAX_RELAY_CLIENTS = 8


class RelayLauncher:
    """管理 Godot Headless Relay 进程的生命周期。"""

    def __init__(self) -> None:
        # relay_port → subprocess.Popen
        self._processes: dict[int, subprocess.Popen] = {}
        self._log_files: dict[int, tuple[IO[str], IO[str]]] = {}
        # A port is reserved from allocation until start_relay either commits the
        # process or releases it after a failure.  Without this state, two
        # allocate -> start callers can both observe the same free port.
        self._reserved_ports: set[int] = set()
        self._starting_ports: set[int] = set()
        self._lock = threading.Lock()

    def allocate_port(self) -> Optional[int]:
        """预留一个未被占用的 Relay 端口。

        调用方必须随后调用 ``start_relay`` 提交预留，或者在放弃时
        调用 ``release_port``。新代码应优先使用 ``start_new_relay``。
        """
        port, _reaped_ports = self.allocate_port_with_reaped()
        return port

    def allocate_port_with_reaped(self) -> tuple[Optional[int], list[int]]:
        """原子回收死亡 Relay，并预留可用端口。"""
        with self._lock:
            reaped_ports = self._reap_exited_locked()
            for port in range(config.RELAY_PORT_START, config.RELAY_PORT_END + 1):
                if (
                    port not in self._processes
                    and port not in self._reserved_ports
                ):
                    self._reserved_ports.add(port)
                    return port, reaped_ports
        return None, reaped_ports

    def release_port(self, port: int) -> bool:
        """释放尚未提交为进程的端口预留。"""
        with self._lock:
            if port in self._processes or port in self._starting_ports:
                return False
            if port not in self._reserved_ports:
                return False
            self._reserved_ports.remove(port)
            return True

    def start_new_relay(
        self,
        max_clients: int,
    ) -> tuple[Optional[int], Optional[int], list[int]]:
        """预留并启动一个 Relay，避免向业务层暴露竞态窗口。

        返回 ``(port, pid, reaped_ports)``。``port is None`` 表示没有
        可用端口；``pid is None`` 表示该预留端口启动失败且已释放。
        """
        port, reaped_ports = self.allocate_port_with_reaped()
        if port is None:
            return None, None, reaped_ports
        pid = self.start_relay(port, max_clients)
        return port, pid, reaped_ports

    def reap_exited(self) -> list[int]:
        """回收已自行退出的 Relay，并返回被释放的端口。"""
        with self._lock:
            return self._reap_exited_locked()

    def _reap_exited_locked(self) -> list[int]:
        """在持有 ``_lock`` 时回收死亡进程及其日志句柄。"""
        reaped_ports: list[int] = []
        for port, proc in list(self._processes.items()):
            try:
                return_code = proc.poll()
            except Exception as exc:
                print(f"[RelayLauncher] 检查 Relay 状态失败 port={port}: {exc}")
                continue
            if return_code is None:
                continue

            self._processes.pop(port, None)
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
            reaped_ports.append(port)
            print(
                f"[RelayLauncher] 已回收退出的 Relay port={port}, "
                f"return_code={return_code}"
            )
        return reaped_ports

    def start_relay(self, port: int, max_clients: int) -> Optional[int]:
        """
        启动一个 Relay 实例，返回进程 PID。
        失败返回 None。
        """
        # Claim the start operation before doing filesystem/process work.  A
        # second caller for the same reserved port must never spawn a process.
        with self._lock:
            if port in self._processes or port in self._starting_ports:
                return None
            self._reserved_ports.add(port)
            self._starting_ports.add(port)

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
            f"--idle-timeout={config.RELAY_IDLE_TIMEOUT}",
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
            proc = subprocess.Popen(
                cmd,
                stdout=stdout_file,
                stderr=stderr_file,
                preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            )
        except Exception as e:
            stdout_file.close()
            stderr_file.close()
            self._release_failed_start(port)
            print(f"[RelayLauncher] 启动 Relay 失败 (port={port}): {e}")
            return None

        with self._lock:
            self._starting_ports.discard(port)
            self._reserved_ports.discard(port)
            self._processes[port] = proc
            self._log_files[port] = (stdout_file, stderr_file)

        print(
            f"[RelayLauncher] Relay 已启动 port={port}, max_clients={max_clients}, "
            f"pid={proc.pid}, "
            f"stdout={stdout_path}, stderr={stderr_path}"
        )
        return proc.pid

    def _release_failed_start(self, port: int) -> None:
        """启动失败后归还端口；必须覆盖所有失败分支。"""
        with self._lock:
            self._starting_ports.discard(port)
            self._reserved_ports.discard(port)

    def stop_relay(self, port: int) -> bool:
        """停止指定端口的 Relay 进程。"""
        with self._lock:
            proc = self._processes.pop(port, None)
            log_files = self._log_files.pop(port, None)
            self._reserved_ports.discard(port)

        if proc is None:
            if log_files is not None:
                for log_file in log_files:
                    log_file.close()
            return False

        try:
            if hasattr(os, "killpg"):
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            else:
                proc.terminate()
            proc.wait(timeout=5)
        except Exception as e:
            print(f"[RelayLauncher] 停止 Relay 失败 (port={port}): {e}")
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
        finally:
            if log_files is not None:
                for log_file in log_files:
                    log_file.close()

        print(f"[RelayLauncher] Relay 已停止 port={port}")
        return True

    def stop_all(self) -> None:
        """停止所有 Relay 进程。"""
        with self._lock:
            ports = list(self._processes.keys())
        for port in ports:
            self.stop_relay(port)

    def is_relay_running(self, port: int) -> bool:
        """检查指定端口的 Relay 是否仍在运行。"""
        with self._lock:
            proc = self._processes.get(port)
        if proc is None:
            return False
        return proc.poll() is None

    def get_active_count(self) -> int:
        """返回当前活跃的 Relay 数量。"""
        with self._lock:
            return sum(1 for p in self._processes.values() if p.poll() is None)
