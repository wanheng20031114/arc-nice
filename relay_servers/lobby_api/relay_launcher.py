"""
Relay 进程启动器。
通过 subprocess 启动 Godot Headless 实例，每个房间一个独立进程和端口。
"""

from __future__ import annotations

import os
import subprocess
import threading
import signal
from typing import Optional

from . import config


class RelayLauncher:
    """管理 Godot Headless Relay 进程的生命周期。"""

    def __init__(self) -> None:
        # relay_port → subprocess.Popen
        self._processes: dict[int, subprocess.Popen] = {}
        self._lock = threading.Lock()

    def allocate_port(self) -> Optional[int]:
        """分配一个未被占用的 Relay 端口。"""
        with self._lock:
            for port in range(config.RELAY_PORT_START, config.RELAY_PORT_END + 1):
                if port not in self._processes:
                    return port
        return None

    def start_relay(self, port: int) -> Optional[int]:
        """
        启动一个 Relay 实例，返回进程 PID。
        失败返回 None。
        """
        godot_path = config.GODOT_SERVER_PATH
        project_path = config.RELAY_PROJECT_PATH

        if not os.path.isfile(godot_path):
            print(f"[RelayLauncher] Godot 可执行文件不存在: {godot_path}")
            return None

        if not os.path.isdir(project_path):
            print(f"[RelayLauncher] Relay 项目路径不存在: {project_path}")
            return None

        cmd = [
            godot_path,
            "--headless",
            "--path", project_path,
            "--", f"--port={port}",
        ]

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=os.setsid if hasattr(os, "setsid") else None,
            )
        except Exception as e:
            print(f"[RelayLauncher] 启动 Relay 失败 (port={port}): {e}")
            return None

        with self._lock:
            self._processes[port] = proc

        print(f"[RelayLauncher] Relay 已启动 port={port}, pid={proc.pid}")
        return proc.pid

    def stop_relay(self, port: int) -> bool:
        """停止指定端口的 Relay 进程。"""
        with self._lock:
            proc = self._processes.pop(port, None)

        if proc is None:
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
            except Exception:
                pass

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
