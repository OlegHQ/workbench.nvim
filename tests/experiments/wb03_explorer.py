#!/usr/bin/env python3
"""Bounded MiniFiles-vs-native-split exploration experiment (WB-03 only)."""

from __future__ import annotations

import argparse
import hashlib
import math
import json
import os
import platform
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pynvim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import Grid  # noqa: E402


GRIDS = [(160, 50), (120, 35), (80, 24), (60, 20)]


def percentile(samples: list[float], p: float) -> float:
    values = sorted(samples)
    rank = (len(values) - 1) * p
    lower = math.floor(rank)
    upper = math.ceil(rank)
    value = values[lower] + (values[upper] - values[lower]) * (rank - lower)
    return round(value, 3)


def summarize(samples: list[float]) -> dict[str, float]:
    return {
        "runs": len(samples),
        "p50_ms": percentile(samples, 0.50),
        "p95_ms": percentile(samples, 0.95),
        "min_ms": round(min(samples), 3),
        "max_ms": round(max(samples), 3),
    }


class ExplorerExperiment:
    def __init__(self, nvim_bin: str, mini_root: Path, cols: int, rows: int, output: Path, cycles: int):
        self.nvim_bin = nvim_bin
        self.mini_root = mini_root.resolve()
        self.cols = cols
        self.rows = rows
        self.output = output
        self.cycles = cycles
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.ui_thread: threading.Thread | None = None
        self.grid = Grid()
        self.workspace: Path | None = None
        self.startup_log = output / "startup.log"
        self.screens: dict[str, list[str]] = {}
        self.child_reaped = False
        self.returncode: int | None = None
        self.socket_path = f"/tmp/wb03-{secrets.token_hex(8)}.sock"
        self.xdg_temp: tempfile.TemporaryDirectory[str] | None = None
        self.fixture_temp: tempfile.TemporaryDirectory[str] | None = None
        self.watchdog: threading.Timer | None = None
        self.watchdog_fired = False

    def _environment(self) -> dict[str, str]:
        assert self.xdg_temp is not None
        xdg = Path(self.xdg_temp.name)
        env = os.environ.copy()
        env.update(
            {
                "XDG_CONFIG_HOME": str(xdg / "config"),
                "XDG_DATA_HOME": str(xdg / "data"),
                "XDG_STATE_HOME": str(xdg / "state"),
                "XDG_CACHE_HOME": str(xdg / "cache"),
                "WB03_MINIFILES_ROOT": str(self.mini_root),
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )
        return env

    def _launch(self) -> None:
        self.output.mkdir(parents=True, exist_ok=False)
        self.xdg_temp = tempfile.TemporaryDirectory(prefix="wb03-xdg-")
        self.fixture_temp = tempfile.TemporaryDirectory(prefix="wb03-fixture-")
        self.workspace = Path(self.fixture_temp.name) / "workspace"
        for directory in ("alpha", "beta"):
            (self.workspace / directory).mkdir(parents=True)
            (self.workspace / directory / f"{directory}.py").write_text(
                f"# {directory} fixture\nvalue = '{directory}'\n", encoding="utf-8"
            )
        (self.workspace / "editor.txt").write_text("origin editor buffer\n", encoding="utf-8")
        for name in ("config", "data", "state", "cache"):
            (Path(self.xdg_temp.name) / name).mkdir()

        args = [
            self.nvim_bin,
            "--clean",
            "--headless",
            "--listen",
            self.socket_path,
            "--startuptime",
            str(self.startup_log),
            "--cmd",
            f"set lines={self.rows} columns={self.cols}",
            "--cmd",
            "lua vim.opt.runtimepath:append(vim.env.WB03_MINIFILES_ROOT)",
        ]
        self.proc = subprocess.Popen(
            args,
            cwd=ROOT,
            env=self._environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.watchdog = threading.Timer(45, self._expire_child)
        self.watchdog.daemon = True
        self.watchdog.start()
        deadline = time.monotonic() + 5
        while not Path(self.socket_path).exists():
            if self.proc.poll() is not None:
                stdout, stderr = self.proc.communicate()
                raise RuntimeError(f"Neovim exited before RPC listen: {stdout}\n{stderr}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Neovim RPC socket did not appear within 5 seconds")
            time.sleep(0.01)

        self.control = pynvim.attach("socket", path=self.socket_path)
        self.ui = pynvim.attach("socket", path=self.socket_path)
        self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
        self.ui_thread = threading.Thread(
            target=self._run_ui_loop,
            daemon=True,
            name="wb03-grid",
        )
        self.ui_thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial ext_linegrid frame")
        assert self.workspace is not None
        self.control.command("edit " + self.control.funcs.fnameescape(str(self.workspace / "editor.txt")))
        self.control.exec_lua("_G.wb03_origin_win = vim.api.nvim_get_current_win()")

    def _run_ui_loop(self) -> None:
        try:
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            if self.proc is not None and self.proc.poll() is None:
                with self.grid.condition:
                    self.grid.callback_error = "RPC UI connection closed while Neovim was still running"
                    self.grid.condition.notify_all()
        except Exception as exc:
            if self.proc is not None and self.proc.poll() is None:
                with self.grid.condition:
                    self.grid.callback_error = f"RPC UI loop failed: {exc!r}"
                    self.grid.condition.notify_all()

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def _state(self):
        return self.lua("return MiniFiles.get_explorer_state()")

    def _wait_state(self, expected: bool, description: str) -> None:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if bool(self._state()) == expected:
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for MiniFiles explorer {description}")

    def _capture(self, name: str) -> None:
        self.screens[name] = self.grid.lines()

    def _resize_grid(self, cols: int, rows: int) -> None:
        assert self.control is not None
        self.control.command(f"set columns={cols} lines={rows}")
        self.grid.wait_for(lambda: self.grid.width == cols and self.grid.height == rows, 3, f"grid resize {cols}x{rows}")

    def _input(self, keys: str) -> None:
        assert self.control is not None
        self.control.api.input(keys)

    def _close_mini(self) -> None:
        if self._state() is not None:
            self._input("q")
            self._wait_state(False, "close")

    def _measure_mini(self) -> list[float]:
        assert self.workspace is not None
        self.lua("require('mini.files').setup({ windows = { preview = true, width_focus = 28, width_nofocus = 22, width_preview = 28 } })")
        samples = []
        for _ in range(self.cycles):
            self._close_mini()
            before = self.grid.flushes
            start = time.perf_counter_ns()
            self.lua("local args = ...; MiniFiles.open(args[1], false)", str(self.workspace))
            self._wait_state(True, "open")
            self.grid.wait_for(lambda: self.grid.flushes > before, 3, "MiniFiles open render")
            samples.append((time.perf_counter_ns() - start) / 1_000_000)
        return samples

    def _mini_behavior(self) -> dict[str, object]:
        assert self.workspace is not None
        alpha = str(self.workspace / "alpha")
        beta = str(self.workspace / "beta")
        beta_file = str(self.workspace / "beta" / "beta.py")
        self.lua("local args = ...; MiniFiles.set_branch({ args[1], args[2] })", str(self.workspace), alpha)
        alpha_state = self._state()
        alpha_branch = list(alpha_state["branch"])
        self.lua("local args = ...; MiniFiles.set_branch({ args[1], args[2] })", str(self.workspace), beta)
        beta_state = self._state()
        beta_branch = list(beta_state["branch"])
        state_windows = beta_state["windows"]
        beta_win = next(window["win_id"] for window in state_windows if window["path"] == beta)
        beta_buf = self.control.api.win_get_buf(beta_win)
        lines = self.control.api.buf_get_lines(beta_buf, 0, -1, True)
        row = next(index for index, line in enumerate(lines, 1) if "beta.py" in line)
        self.control.api.win_set_cursor(beta_win, [row, 0])
        self.lua("MiniFiles.set_target_window(_G.wb03_origin_win)")
        self.control.api.set_current_win(beta_win)
        self._input("l")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if Path(self.control.api.win_get_buf(self.lua("return _G.wb03_origin_win")).name).resolve() == Path(beta_file).resolve():
                break
            time.sleep(0.01)
        target_buffer = self.control.api.win_get_buf(self.lua("return _G.wb03_origin_win"))
        assert Path(target_buffer.name).resolve() == Path(beta_file).resolve(), f"MiniFiles public go_in mapping did not open target: {target_buffer.name}"
        focused_after_open = self.control.api.get_current_win().handle
        focused_target = int(focused_after_open) == int(self.lua("return _G.wb03_origin_win"))
        focused_panel_wins = [window["win_id"] for window in self._state()["windows"]]
        self._capture("minifiles-open-beta")

        cursor_before_close = self.control.api.win_get_cursor(beta_win)
        self._close_mini()
        focus_after_close = int(self.control.api.get_current_win().handle) == int(self.lua("return _G.wb03_origin_win"))
        self.lua("local args = ...; MiniFiles.open(args[1], true)", str(self.workspace))
        self._wait_state(True, "reopen")
        reopened = self._state()
        reopened_branch = list(reopened["branch"])
        reopened_focus_win = reopened["windows"][reopened["depth_focus"] - 1]["win_id"]
        reopened_cursor = self.control.api.win_get_cursor(reopened_focus_win)
        self._capture("minifiles-reopened")
        configs = []
        for window in reopened["windows"]:
            config = self.control.api.win_get_config(window["win_id"])
            configs.append({"path": window["path"], **config})

        self._close_mini()
        clean_windows = len(self.control.api.list_wins()) == 1
        self.lua("local args = ...; MiniFiles.open(args[1], false)", str(self.workspace))
        self._wait_state(True, "resize probe open")
        resized: list[dict[str, object]] = []
        for cols, rows in GRIDS:
            self._resize_grid(cols, rows)
            state = self._state()
            windows = []
            for window in state["windows"]:
                config = self.control.api.win_get_config(window["win_id"])
                windows.append({"path": window["path"], **config})
            resized.append({"grid": f"{cols}x{rows}", "windows": windows})
            self._capture(f"minifiles-{cols}x{rows}")
        self._close_mini()

        return {
            "api_used": ["setup", "open", "get_explorer_state", "set_branch", "set_target_window", "close", "go_in via documented `l` mapping"],
            "alpha_branch": alpha_branch,
            "beta_branch": beta_branch,
            "two_sibling_branches_simultaneous": alpha in beta_branch and beta in alpha_branch,
            "beta_opened_in_target_window": Path(target_buffer.name).resolve() == Path(beta_file).resolve(),
            "focus_after_file_open_window": focused_after_open,
            "focus_after_file_open_is_editor": focused_target,
            "close_restores_editor_focus": focus_after_close,
            "mini_files_focus_window_ids": focused_panel_wins,
            "cursor_before_close": cursor_before_close,
            "reopened_branch": reopened_branch,
            "cursor_after_reopen": reopened_cursor,
            "reopen_preserved_branch_and_cursor": reopened_branch == beta_branch and reopened_cursor == cursor_before_close,
            "float_configs": configs,
            "resize_configs": resized,
            "all_resize_windows_fit": all(
                int(window.get("col", 0)) >= 0
                and int(window.get("col", 0)) + int(window.get("width", 0)) + 2 <= int(record["grid"].split("x")[0])
                for record in resized
                for window in record["windows"]
            ),
            "windows_clean_after_close": clean_windows,
        }

    def _native_open(self) -> dict[str, object]:
        return self.lua(
            r"""
            local origin = _G.wb03_origin_win
            vim.api.nvim_set_current_win(origin)
            vim.cmd('topleft 32vnew')
            local win = vim.api.nvim_get_current_win()
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_buf_set_name(buf, 'workbench://wb03-native')
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
              'Files  [native split experiment]',
              '  alpha/',
              '    alpha.py',
              '  beta/',
              '    beta.py',
            })
            vim.bo[buf].buftype = 'nofile'
            vim.bo[buf].bufhidden = 'wipe'
            vim.bo[buf].swapfile = false
            vim.bo[buf].modifiable = false
            vim.wo[win].number = false
            vim.wo[win].relativenumber = false
            vim.wo[win].signcolumn = 'no'
            vim.wo[win].wrap = false
            vim.wo[win].winfixwidth = true
            vim.api.nvim_win_set_width(win, math.min(32, vim.o.columns - 24))
            local saved = _G.wb03_native_selection or { 2, 0 }
            vim.api.nvim_win_set_cursor(win, saved)
            vim.keymap.set('n', 'q', function()
              _G.wb03_native_selection = vim.api.nvim_win_get_cursor(0)
              vim.api.nvim_win_close(0, true)
            end, { buffer = buf, desc = 'Close temporary native explorer' })
            _G.wb03_native_win, _G.wb03_native_buf = win, buf
            return { win = win, buf = buf, origin = origin, width = vim.api.nvim_win_get_width(win) }
            """
        )

    def _native_close(self) -> None:
        win = self.lua("return _G.wb03_native_win")
        if win and self.control.api.win_is_valid(win):
            self.control.api.set_current_win(win)
            self._input("q")
            self.grid.wait_for(lambda: not self.control.api.win_is_valid(win), 3, "native split close")

    def _native_behavior(self) -> dict[str, object]:
        samples = []
        for _ in range(self.cycles):
            self._native_close()
            before = self.grid.flushes
            start = time.perf_counter_ns()
            opened = self._native_open()
            self.grid.wait_for(lambda: self.grid.flushes > before, 3, "native split open render")
            samples.append((time.perf_counter_ns() - start) / 1_000_000)
        opened = {"win": self.lua("return _G.wb03_native_win"), "buf": self.lua("return _G.wb03_native_buf")}
        win = opened["win"]
        buffer = opened["buf"]
        lines = self.control.api.buf_get_lines(buffer, 0, -1, True)
        assert any("alpha/" in line for line in lines) and any("beta/" in line for line in lines)
        self._capture("native-split-two-branches")
        self.lua("vim.api.nvim_set_current_win(_G.wb03_origin_win)")
        focus_returned = self.control.api.get_current_win().handle == self.lua("return _G.wb03_origin_win")
        self.control.api.set_current_win(win)
        self._input("j")
        cursor_before_close = self.control.api.win_get_cursor(win)
        self._input("q")
        self.grid.wait_for(lambda: not self.control.api.win_is_valid(win), 3, "native split cleanup")
        reopened = self._native_open()
        reopened_cursor = self.control.api.win_get_cursor(reopened["win"])
        self._capture("native-split-reopened")
        resize_records = []
        for cols, rows in GRIDS:
            self._resize_grid(cols, rows)
            resized_width = self.control.api.win_get_width(reopened["win"])
            resize_records.append({
                "grid": f"{cols}x{rows}",
                "sidebar_width": resized_width,
                "editor_width": cols - resized_width - 1,
                "editor_meets_60_column_budget": cols - resized_width - 1 >= 60,
            })
            self._capture(f"native-split-{cols}x{rows}")
        self._native_close()
        final_windows = len(self.control.api.list_wins())
        buf_valid = self.control.api.buf_is_valid(buffer)
        return {
            "api_used": ["topleft 32vnew", "nvim_win_set_width", "nvim_set_current_win", "window-local options", "buffer-local q mapping"],
            "simultaneous_branches_rendered": ["alpha/", "beta/"],
            "editor_focus_returned": focus_returned,
            "cursor_before_close": cursor_before_close,
            "cursor_after_reopen": reopened_cursor,
            "reopen_preserved_selection": cursor_before_close == reopened_cursor,
            "resize": resize_records,
            "cleanup_restored_window_count": final_windows == 1,
            "cleanup_wiped_projection_buffer": not buf_valid,
            "open_to_first_frame": summarize(samples),
        }

    def run(self) -> dict[str, object]:
        error = None
        result: dict[str, object] = {}
        try:
            self._launch()
            mini_samples = self._measure_mini()
            mini_result = self._mini_behavior()
            mini_result["open_to_first_frame"] = summarize(mini_samples)
            self._capture("minifiles-before-native")
            self._resize_grid(self.cols, self.rows)
            native_result = self._native_behavior()
            result = {
                "nvim": subprocess.run([self.nvim_bin, "--version"], text=True, capture_output=True, check=True).stdout.splitlines()[0],
                "grid_start": f"{self.cols}x{self.rows}",
                "grids_tested": [f"{cols}x{rows}" for cols, rows in GRIDS],
                "cycles_per_layout": self.cycles,
                "mini_files": mini_result,
                "native_split": native_result,
                "comparison_note": "MiniFiles scans the identical generated directory tree but exposes a single parent-child branch; the native split is a minimal projection of the same two directories, not a feature-complete provider comparison.",
            }
        except Exception as exc:
            error = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            self._cleanup()
            self._write_artifacts(result, error)
        return result

    def _cleanup(self) -> None:
        if self.watchdog is not None:
            self.watchdog.cancel()
        if self.proc is not None and self.proc.poll() is None and self.control is not None:
            try:
                self.control.api.command("qa!", async_=True)
            except Exception:
                pass
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.proc is not None:
            self.returncode = self.proc.wait(timeout=2)
            self.child_reaped = True
        for session in (self.control, self.ui):
            if session is not None:
                try:
                    session.close()
                except Exception:
                    pass
        if self.ui_thread is not None:
            self.ui_thread.join(timeout=1)
        Path(self.socket_path).unlink(missing_ok=True)
        if self.fixture_temp is not None:
            self.fixture_temp.cleanup()
        if self.xdg_temp is not None:
            self.xdg_temp.cleanup()

    def _expire_child(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.watchdog_fired = True
            self.proc.terminate()

    def _write_artifacts(self, result: dict[str, object], error: str | None) -> None:
        self.output.mkdir(parents=True, exist_ok=True)
        for name, screen in self.screens.items():
            (self.output / f"{name}.txt").write_text("\n".join(screen) + "\n", encoding="utf-8")
        mini_source = self.mini_root / "lua" / "mini" / "files.lua"
        metadata = {
            "environment": {
                "os": platform.platform(),
                "machine": platform.machine(),
                "python": platform.python_version(),
                "pynvim": pynvim.__version__,
                "mini_files_root": str(self.mini_root),
                "mini_files_store_path": str(self.mini_root.resolve()),
                "mini_files_source_sha256": hashlib.sha256(mini_source.read_bytes()).hexdigest(),
                "fixture_seed": "temporary tree with two sibling directories alpha and beta",
            },
            "command": [self.nvim_bin, "--clean", "--headless", "--listen", self.socket_path],
            "returncode": self.returncode,
            "child_reaped": self.child_reaped,
            "watchdog_fired": self.watchdog_fired,
            "result": result,
            "error": error,
        }
        filename = "failure.json" if error else "result.json"
        (self.output / filename).write_text(json.dumps(metadata, indent=2, default=str) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--mini-root", type=Path, default=Path("/Users/snowbear/.local/share/nvim/site/pack/hm/start/mini.files"))
    parser.add_argument("--cols", type=int, default=160)
    parser.add_argument("--rows", type=int, default=50)
    parser.add_argument("--cycles", type=int, default=20)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.mini_root.is_dir():
        parser.error(f"installed MiniFiles directory not found: {args.mini_root}")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    output = args.output or ROOT / ".test-output" / "e2e" / f"wb03-{stamp}-{secrets.token_hex(3)}"
    try:
        result = ExplorerExperiment(args.nvim, args.mini_root, args.cols, args.rows, output, args.cycles).run()
    except Exception as exc:
        print(f"WB-03 experiment failed; inspect {output / 'failure.json'}: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({
        "artifacts": str(output),
        "nvim": result["nvim"],
        "cycles_per_layout": result["cycles_per_layout"],
        "mini_files": {
            "open_to_first_frame": result["mini_files"]["open_to_first_frame"],
            "two_sibling_branches_simultaneous": result["mini_files"]["two_sibling_branches_simultaneous"],
            "beta_opened_in_target_window": result["mini_files"]["beta_opened_in_target_window"],
            "focus_after_file_open_is_editor": result["mini_files"]["focus_after_file_open_is_editor"],
            "close_restores_editor_focus": result["mini_files"]["close_restores_editor_focus"],
            "reopen_preserved_branch_and_cursor": result["mini_files"]["reopen_preserved_branch_and_cursor"],
            "all_resize_windows_fit": result["mini_files"]["all_resize_windows_fit"],
            "windows_clean_after_close": result["mini_files"]["windows_clean_after_close"],
        },
        "native_split": {
            "open_to_first_frame": result["native_split"]["open_to_first_frame"],
            "simultaneous_branches_rendered": result["native_split"]["simultaneous_branches_rendered"],
            "editor_focus_returned": result["native_split"]["editor_focus_returned"],
            "reopen_preserved_selection": result["native_split"]["reopen_preserved_selection"],
            "resize": result["native_split"]["resize"],
            "cleanup_restored_window_count": result["native_split"]["cleanup_restored_window_count"],
            "cleanup_wiped_projection_buffer": result["native_split"]["cleanup_wiped_projection_buffer"],
        },
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
