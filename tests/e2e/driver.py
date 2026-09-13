#!/usr/bin/env python3
"""Drive an isolated Neovim instance through a real RPC UI grid."""

from __future__ import annotations

import argparse
import json
import os
import platform
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path
from typing import Any

import msgpack
import pynvim


PLUGIN_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = Path(__file__).resolve().parent / "fixtures" / "probe"
GRID_EVENTS = {
    "default_colors_set",
    "grid_clear",
    "grid_cursor_goto",
    "grid_destroy",
    "grid_line",
    "grid_resize",
    "hl_attr_define",
    "hl_group_set",
    "mode_change",
    "mode_info_set",
    "option_set",
    "win_float_pos",
    "win_hide",
    "win_pos",
    "win_viewport",
    "flush",
}


class Grid:
    def __init__(self) -> None:
        self.condition = threading.Condition()
        self.width = 0
        self.height = 0
        self.cells: list[list[tuple[str, int]]] = []
        self.highlights: dict[int, Any] = {}
        self.events = 0
        self.flushes = 0
        self.callback_error: str | None = None
        self.raw_events: list[str] = []

    def _resize(self, grid: int, width: int, height: int) -> None:
        if grid != 1:
            return
        self.width, self.height = width, height
        self.cells = [[(" ", 0) for _ in range(width)] for _ in range(height)]

    def _line(self, payload: Any) -> None:
        if not isinstance(payload, (list, tuple)) or len(payload) < 4:
            return
        grid, row, start, chunks = payload[:4]
        if grid != 1 or row >= len(self.cells) or start >= self.width:
            return
        col = start
        current_hl = 0
        for chunk in chunks:
            if isinstance(chunk, str):
                text, count = chunk, 1
            elif isinstance(chunk, (list, tuple)) and chunk:
                text = str(chunk[0])
                if len(chunk) > 1:
                    current_hl = int(chunk[1])
                count = int(chunk[2]) if len(chunk) > 2 else 1
            else:
                continue
            for _ in range(max(count, 1)):
                if col >= self.width:
                    break
                self.cells[row][col] = (text or " ", current_hl)
                col += 1

    def _event(self, event: Any) -> None:
        if not isinstance(event, (list, tuple)) or not event:
            return
        name = event[0]
        if not isinstance(name, str) or name not in GRID_EVENTS:
            return
        self.events += 1
        for payload in event[1:]:
            if name == "grid_resize" and isinstance(payload, (list, tuple)) and len(payload) >= 3:
                self._resize(int(payload[0]), int(payload[1]), int(payload[2]))
            elif name == "grid_clear" and isinstance(payload, (list, tuple)) and payload:
                self._resize(int(payload[0]), self.width, self.height)
            elif name == "grid_line":
                self._line(payload)
            elif name == "hl_attr_define" and isinstance(payload, (list, tuple)) and len(payload) >= 3:
                self.highlights[int(payload[0])] = payload[1]
            elif name == "flush":
                self.flushes += 1

    def _walk(self, node: Any) -> None:
        if isinstance(node, (list, tuple)):
            if node and isinstance(node[0], str) and node[0] in GRID_EVENTS:
                self._event(node)
                return
            for item in node:
                self._walk(item)

    def notify(self, method: str, args: list[Any]) -> None:
        if method != "redraw":
            return
        with self.condition:
            try:
                if len(self.raw_events) < 12:
                    self.raw_events.append(repr(args))
                self._walk(args)
            except Exception:
                self.callback_error = traceback.format_exc()
            self.condition.notify_all()

    def wait_for(self, predicate, timeout: float, description: str) -> None:
        end = time.monotonic() + timeout
        with self.condition:
            while not predicate():
                if self.callback_error:
                    raise RuntimeError(f"UI redraw callback failed:\n{self.callback_error}")
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for {description}")
                self.condition.wait(min(remaining, 0.05))

    def lines(self) -> list[str]:
        return ["".join(text for text, _ in row) for row in self.cells]

    def snapshot(self) -> dict[str, Any]:
        return {
            "width": self.width,
            "height": self.height,
            "text": self.lines(),
            "highlight_ids": [[hl for _, hl in row] for row in self.cells],
            "highlights": self.highlights,
            "redraw_events": self.events,
            "flushes": self.flushes,
            "raw_redraw_samples": self.raw_events,
        }


def host_config_root() -> Path | None:
    for parent in PLUGIN_ROOT.parents:
        if (parent / "init.lua").is_file() and (parent / "pack" / "plugins" / "start" / "workbench.nvim").resolve() == PLUGIN_ROOT:
            return parent
    return None


class ProbeRun:
    def __init__(self, nvim: str, cols: int, rows: int, mode: str, output: Path, host: bool = False):
        self.nvim = nvim
        self.cols = cols
        self.rows = rows
        self.mode = mode
        self.output = output
        self.host = host
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.ui_thread: threading.Thread | None = None
        self.grid = Grid()
        self.started_at = 0.0
        self.first_flush_at: float | None = None
        self.input_at: float | None = None
        self.input_flush_at: float | None = None
        self.origin_buf: int | None = None
        self.origin_win: int | None = None
        self.origin_buffer = None
        self.failure: str | None = None
        self.child_reaped = False
        self.returncode: int | None = None
        self.nvim_state: dict[str, Any] = {}
        self.command: list[str] = []
        self.outcome: dict[str, Any] = {}
        self.watchdog_fired = False
        self.watchdog: threading.Timer | None = None

    def _child_args(self, socket_path: str, xdg: Path, log: Path) -> list[str]:
        args = [self.nvim]
        config_root = host_config_root() if self.host else None
        if config_root:
            args.extend(["-u", str(config_root / "init.lua"), "-i", "NONE", "-n"])
        else:
            args.extend(["--clean", "-i", "NONE", "-n"])
        args.extend(
            [
                "--headless",
                "--listen",
                socket_path,
                "--startuptime",
                str(log),
                "--cmd",
                f"set lines={self.rows} columns={self.cols}",
                "--cmd",
                f"set runtimepath^={FIXTURE_ROOT}",
                "--cmd",
                "lua require('probe').setup()",
            ]
        )
        return args

    def _environment(self, xdg: Path) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "XDG_DATA_HOME": str(xdg / "data"),
                "XDG_STATE_HOME": str(xdg / "state"),
                "XDG_CACHE_HOME": str(xdg / "cache"),
                "WORKBENCH_E2E_MODE": self.mode,
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )
        if not self.host:
            env["XDG_CONFIG_HOME"] = str(xdg / "config")
        elif (config_root := host_config_root()) is not None:
            env["XDG_CONFIG_HOME"] = str(config_root.parent)
        return env

    def _current_buf_name(self) -> str:
        assert self.control is not None
        return self.control.api.get_current_buf().name

    def _assert(self, condition: bool, message: str) -> None:
        if not condition:
            raise AssertionError(message)

    def _exercise(self) -> dict[str, Any]:
        assert self.control is not None
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5.0, "first UI frame")
        self.first_flush_at = time.monotonic()

        self.origin_buffer = self.control.api.get_current_buf()
        self.origin_buf = int(self.origin_buffer.handle)
        self.origin_win = int(self.control.api.get_current_win().handle)
        self.input_at = time.monotonic()
        self.control.api.input("iUSER OWNED CONTENT\x1b")
        self.grid.wait_for(
            lambda: self.control.api.get_current_line() == "USER OWNED CONTENT"
            and any("USER OWNED CONTENT" in line for line in self.grid.lines()),
            3.0,
            "first real key input and its rendered frame",
        )
        self.input_flush_at = time.monotonic()

        self.control.api.input(":WorkbenchProbe\n")
        self.grid.wait_for(
            lambda: any("Workbench E2E ready" in line for line in self.grid.lines()),
            3.0,
            "probe view render",
        )

        current_buffer = self.control.api.get_current_buf()
        current_buf = int(current_buffer.handle)
        current_win = int(self.control.api.get_current_win().handle)
        current_name = current_buffer.name
        self._assert(current_name == "workbench://probe", f"expected probe buffer focus, got {current_name!r}")
        self._assert(current_win != self.origin_win, "opening the probe did not move editor focus")

        if self.mode != "wrong-focus":
            lines = self.grid.lines()
            target = next((row for row, line in enumerate(lines) if "mouse-target" in line), None)
            self._assert(target is not None, "mouse target is not visible in the attached UI grid")
            assert target is not None
            col = lines[target].index("mouse-target")
            self.control.api.input_mouse("left", "press", "", 1, target, col)
            self.control.api.input_mouse("left", "release", "", 1, target, col)
            self.grid.wait_for(
                lambda: self.control.api.get_current_line() == "mouse-target",
                2.0,
                "mouse selection",
            )

            self.control.api.input("q")
            self.grid.wait_for(
                lambda: self.control.api.get_current_buf().handle == self.origin_buf,
                3.0,
                "keyboard close and focus return",
            )
            self._assert(self.control.api.get_current_win().handle == self.origin_win, "focus did not return to origin window")
            self._assert(self.control.api.get_current_line() == "USER OWNED CONTENT", "modified origin text changed")
            self._assert(self.control.api.buf_get_option(self.origin_buffer, "modified"), "modified origin state was lost")

        return {
            "origin_buffer": self.origin_buf,
            "origin_window": self.origin_win,
            "rendered_buffer": current_buf,
            "rendered_window": current_win,
            "selected_by_mouse": self.mode != "wrong-focus",
            "returned_by_key": self.mode != "wrong-focus",
            "modified_origin_preserved": self.mode != "wrong-focus",
        }

    def run(self) -> dict[str, Any]:
        self.output.mkdir(parents=True, exist_ok=False)
        self.started_at = time.monotonic()
        socket_path = f"/tmp/wb-{secrets.token_hex(8)}.sock"
        try:
            with tempfile.TemporaryDirectory(prefix="wb-xdg-") as temporary:
                xdg = Path(temporary)
                for name in ("config", "data", "state", "cache"):
                    (xdg / name).mkdir()
                log = self.output / "startup.log"
                self.command = self._child_args(socket_path, xdg, log)
                self.proc = subprocess.Popen(
                    self.command,
                    cwd=PLUGIN_ROOT,
                    env=self._environment(xdg),
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.watchdog = threading.Timer(12.0, self._expire_child)
                self.watchdog.daemon = True
                self.watchdog.start()
                deadline = time.monotonic() + 5.0
                while not Path(socket_path).exists():
                    if self.proc.poll() is not None:
                        stdout, stderr = self.proc.communicate()
                        raise RuntimeError(f"Neovim exited before RPC listen socket appeared: {stdout}\n{stderr}")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Neovim RPC socket did not appear within 5 seconds")
                    time.sleep(0.01)

                self.control = pynvim.attach("socket", path=socket_path)
                self.ui = pynvim.attach("socket", path=socket_path)
                self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
                self.ui_thread = threading.Thread(
                    target=self._run_ui_loop,
                    daemon=True,
                    name="workbench-e2e-ui",
                )
                self.ui_thread.start()
                result = self._exercise()
                result["startup_to_first_flush_ms"] = round((self.first_flush_at - self.started_at) * 1000, 3)
                result["first_input_state_ms"] = round((self.input_flush_at - self.input_at) * 1000, 3)
                result["startup_marker_ms"] = self._startup_marker(log)
                self.outcome = result
                return result
        except Exception as error:
            self.failure = f"{type(error).__name__}: {error}"
            raise
        finally:
            self._cleanup(socket_path)
            self._write_artifacts()

    @staticmethod
    def _startup_marker(path: Path) -> float | None:
        if not path.exists():
            return None
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "--- NVIM STARTED ---" in line:
                try:
                    return float(line.split()[0])
                except (IndexError, ValueError):
                    return None
        return None

    def _cleanup(self, socket_path: str) -> None:
        if self.watchdog is not None:
            self.watchdog.cancel()
        if self.failure and not self.watchdog_fired and self.control is not None and self.proc is not None and self.proc.poll() is None:
            try:
                self.nvim_state = {
                    "current_buffer": self._current_buf_name(),
                    "current_line": self.control.api.get_current_line(),
                    "current_window": self.control.api.get_current_win().handle,
                    "window_count": len(self.control.api.list_wins()),
                    "mode": self.control.api.get_mode(),
                    "errmsg": self.control.eval("v:errmsg"),
                    "messages": self.control.command_output("messages"),
                }
            except Exception as error:
                self.nvim_state = {"diagnostic_error": repr(error)}
        if self.proc is not None and self.proc.poll() is None and self.control is not None:
            try:
                self.control.api.command("qa!", async_=True)
            except Exception:
                pass
            try:
                self.proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.proc is not None:
            try:
                self.returncode = self.proc.wait(timeout=2.0)
                self.child_reaped = True
            except subprocess.TimeoutExpired:
                self.returncode = None
        for session in (self.control, self.ui):
            if session is not None:
                try:
                    session.close()
                except Exception:
                    pass
        if self.ui_thread is not None:
            self.ui_thread.join(timeout=1.0)
        try:
            Path(socket_path).unlink(missing_ok=True)
        except OSError:
            pass

    def _expire_child(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.watchdog_fired = True
            self.proc.terminate()

    def _run_ui_loop(self) -> None:
        assert self.ui is not None
        try:
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            if self.proc is not None and self.proc.poll() is None:
                with self.grid.condition:
                    self.grid.callback_error = "RPC UI connection closed while Neovim was still running"
                    self.grid.condition.notify_all()
        except Exception:
            with self.grid.condition:
                self.grid.callback_error = traceback.format_exc()
                self.grid.condition.notify_all()

    def _write_artifacts(self) -> None:
        self.output.mkdir(parents=True, exist_ok=True)
        snapshot = self.grid.snapshot()
        (self.output / "ui-grid.json").write_text(json.dumps(snapshot, indent=2, default=str) + "\n")
        (self.output / "screen.txt").write_text("\n".join(snapshot["text"]) + "\n")
        stdout = ""
        stderr = ""
        if self.proc is not None and self.proc.poll() is not None:
            try:
                stdout, stderr = self.proc.communicate(timeout=0.2)
            except Exception:
                pass
        (self.output / "messages.txt").write_text(f"stdout:\n{stdout or ''}\nstderr:\n{stderr or ''}")
        nvim_version = "unavailable"
        try:
            version = subprocess.run([self.nvim, "--version"], text=True, capture_output=True, timeout=3, check=False)
            if version.stdout:
                nvim_version = version.stdout.splitlines()[0]
        except (OSError, subprocess.SubprocessError):
            pass
        metadata = {
            "nvim": self.nvim,
            "nvim_version": nvim_version,
            "environment": {
                "os": platform.platform(),
                "machine": platform.machine(),
                "python": platform.python_version(),
                "pynvim": pynvim.__version__,
                "msgpack": msgpack.__version__,
                "fixture_seed": 20260912,
                "workbench_git_head": git_head(PLUGIN_ROOT),
                "host_git_head": git_head(host_config_root()) if self.host else "not loaded",
            },
            "grid": f"{self.cols}x{self.rows}",
            "mode": self.mode,
            "host_config": self.host,
            "pid": self.proc.pid if self.proc else None,
            "returncode": self.returncode,
            "child_reaped": self.child_reaped,
            "failure": self.failure,
            "nvim_state": self.nvim_state,
            "command": self.command,
            "outcome": self.outcome,
        }
        name = "failure.json" if self.failure else "result.json"
        (self.output / name).write_text(json.dumps(metadata, indent=2) + "\n")


def new_output(base: Path, label: str) -> Path:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    return base / f"{stamp}-{label}-{secrets.token_hex(3)}"


def git_head(path: Path | None) -> str:
    if path is None:
        return "unavailable"
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True,
            capture_output=True,
            timeout=2,
            check=True,
        )
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def parse_grids(value: str) -> list[tuple[int, int]]:
    grids = []
    for item in value.split(","):
        width, height = item.lower().split("x", 1)
        grids.append((int(width), int(height)))
    return grids


def self_test(args: argparse.Namespace) -> int:
    python = sys.executable
    script = str(Path(__file__).resolve())
    base = args.output_root
    cases = [("probe", True), ("wrong-render", False), ("wrong-focus", False)]
    for mode, should_pass in cases:
        target = new_output(base, f"self-{mode}")
        command = [
            python,
            script,
            "--case",
            mode,
            "--nvim",
            args.nvim,
            "--cols",
            "80",
            "--rows",
            "24",
            "--output",
            str(target),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        passed = result.returncode == 0
        metadata_path = target / ("result.json" if should_pass else "failure.json")
        metadata = json.loads(metadata_path.read_text()) if metadata_path.exists() else {}
        if passed != should_pass or (not should_pass and not metadata.get("child_reaped")):
            print(f"harness self-test failed for {mode}: exit={result.returncode}\n{result.stdout}\n{result.stderr}", file=sys.stderr)
            return 1
        print(f"{mode}: {'passed' if passed else 'detected expected failure'}; child reaped={metadata.get('child_reaped')}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default=os.environ.get("NVIM", "nvim"))
    parser.add_argument("--case", choices=("probe", "wrong-render", "wrong-focus"), default="probe")
    parser.add_argument("--cols", type=int, default=80)
    parser.add_argument("--rows", type=int, default=24)
    parser.add_argument("--grid-sizes", default="80x24")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--host", action="store_true", help="load the enclosing nvim-config init.lua")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-root", type=Path, default=PLUGIN_ROOT / ".test-output" / "e2e")
    args = parser.parse_args()

    if args.self_test:
        return self_test(args)

    grids = parse_grids(args.grid_sizes)
    if args.output is not None and len(grids) != 1:
        parser.error("--output can only be used with one grid size")
    results = []
    for cols, rows in grids:
        output = args.output or new_output(args.output_root, f"{args.case}-{cols}x{rows}")
        try:
            result = ProbeRun(args.nvim, cols, rows, args.case, output, args.host).run()
        except Exception as error:
            print(f"E2E {args.case} failed at {cols}x{rows}; artifacts: {output}\n{error}", file=sys.stderr)
            return 1
        results.append({"artifacts": str(output), **result})
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
