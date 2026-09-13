#!/usr/bin/env python3
"""Exercise inert session recovery with two real Neovim processes and an RPC grid."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

import pynvim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import Grid, parse_grids  # noqa: E402


class Editor:
    def __init__(self, nvim: str, cols: int, rows: int, environment: dict[str, str], output: Path, with_ui: bool):
        self.nvim = nvim
        self.cols, self.rows = cols, rows
        self.environment, self.output, self.with_ui = environment, output, with_ui
        self.socket = f"/tmp/wb23-{secrets.token_hex(8)}.sock"
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.started = 0.0
        self.first_flush_ms: float | None = None
        self.command: list[str] = []

    def start(self) -> None:
        self.output.mkdir(parents=True, exist_ok=True)
        log = self.output / "startup.log"
        self.command = [
            self.nvim, "--clean", "--headless", "--listen", self.socket,
            "--startuptime", str(log),
            "--cmd", f"set lines={self.rows} columns={self.cols}",
            "--cmd", f"set runtimepath^={ROOT}",
        ]
        self.started = time.perf_counter()
        self.proc = subprocess.Popen(self.command, cwd=ROOT, env=self.environment, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not Path(self.socket).exists():
            if self.proc.poll() is not None:
                stdout, stderr = self.proc.communicate()
                raise RuntimeError(f"Neovim exited before RPC listen: {stdout}\n{stderr}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Neovim RPC socket did not appear")
            time.sleep(0.01)
        self.control = pynvim.attach("socket", path=self.socket)
        if self.with_ui:
            self.ui = pynvim.attach("socket", path=self.socket)
            self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
            self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb23-persistence-grid")
            self.thread.start()
            self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial Neovim grid")
            self.first_flush_ms = round((time.perf_counter() - self.started) * 1000, 3)

    def _ui_loop(self) -> None:
        assert self.ui is not None
        try:
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            return
        except Exception:
            with self.grid.condition:
                self.grid.callback_error = traceback.format_exc()
                self.grid.condition.notify_all()

    def close(self) -> None:
        if self.control is not None and self.proc is not None and self.proc.poll() is None:
            try:
                self.control.command("qa!")
            except Exception:
                pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2)
            self.control = None
            self.ui = None
            if self.thread is not None:
                self.thread.join(timeout=0.5)


def run_one(nvim: str, cols: int, rows: int, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="wb23-persist-") as temporary:
        base = Path(temporary)
        xdg = base / "xdg"
        for name in ("config", "data", "state", "cache"):
            (xdg / name).mkdir(parents=True)
        environment = os.environ.copy()
        environment.update({
            "XDG_CONFIG_HOME": str(xdg / "config"),
            "XDG_DATA_HOME": str(xdg / "data"),
            "XDG_STATE_HOME": str(xdg / "state"),
            "XDG_CACHE_HOME": str(xdg / "cache"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        state_dir = xdg / "state" / "nvim" / "workbench" / "sessions"
        state_dir.mkdir(parents=True)
        corrupt = state_dir / "session-corrupt.json"
        corrupt.write_text("{unreadable JSON", encoding="utf-8")
        workspace_a, workspace_b = base / "workspace-a", base / "workspace-b"
        workspace_a.mkdir(); workspace_b.mkdir()
        first = Editor(nvim, cols, rows, environment, output / "process-a", with_ui=True)
        second = Editor(nvim, cols, rows, environment, output / "process-b", with_ui=False)
        try:
            first.start()
            first_state = first.control.exec_lua(
                "local api=require('workbench'); local before=api.get_status(); local lazy=package.loaded['workbench.services.persistence']==nil; "
                "local no_provider=package.loaded['workbench.providers.rg']==nil; assert(api.setup({enabled=false,session={persist=true}})); "
                "return {before=before.state,lazy=lazy,setup_lazy=package.loaded['workbench.services.persistence']==nil,no_provider=no_provider,"
                "state_dir=vim.fs.joinpath(vim.fn.stdpath('state'),'workbench','sessions'),buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win()}"
            )
            if first_state["state_dir"] != str(state_dir) or not first_state["lazy"] or not first_state["setup_lazy"] or not first_state["no_provider"]:
                raise AssertionError(f"setup read or initialized persistence/providers before an explicit session action: {first_state}")
            save_a_started = time.perf_counter_ns()
            saved_a = first.control.exec_lua(
                "local api=require('workbench'); local result=assert(api.save_session({workspaces={{root=...,view={active='search'},search={query='alpha',flags={fixed=true},scope={kind='workspace'}}}}})); return result",
                str(workspace_a),
            )
            save_a_ms = round((time.perf_counter_ns() - save_a_started) / 1_000_000, 3)
            second.start()
            second_state = second.control.exec_lua(
                "local root,prior_id=...; local initial_buf=vim.api.nvim_get_current_buf(); local initial_win=vim.api.nvim_get_current_win(); "
                "local api=require('workbench'); local lazy=package.loaded['workbench.services.persistence']==nil; assert(api.setup({enabled=false,session={persist=true}})); "
                "local uv=vim.uv; local started=uv.hrtime(); "
                "local result=assert(api.save_session({workspaces={{root=root,view={active='files'},search={query='beta',flags={fixed=true},scope={kind='workspace'}}}}})); "
                "local save_ms=(uv.hrtime()-started)/1000000; started=uv.hrtime(); local records=assert(api.list_sessions()); local list_ms=(uv.hrtime()-started)/1000000; "
                "started=uv.hrtime(); local restored=assert(api.restore_session(prior_id)); local restore_ms=(uv.hrtime()-started)/1000000; local bad,bad_error=api.restore_session('corrupt'); "
                "return {lazy=lazy,own=result.id,records=records,restored=restored,bad=bad==nil,bad_code=bad_error.code,"
                "providers=package.loaded['workbench.providers.rg']==nil and package.loaded['workbench.providers.git']==nil,"
                "state=api.get_status().state,initial_buf=initial_buf,initial_win=initial_win,buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win(),"
                "timings={save_ms=save_ms,list_ms=list_ms,restore_ms=restore_ms}} ",
                str(workspace_b), saved_a["id"],
            )
            ids = [record["id"] for record in second_state["records"] if record["state"] == "available"]
            if saved_a["id"] == second_state["own"] or set(ids) != {saved_a["id"], second_state["own"]}:
                raise AssertionError(f"two editor sessions did not retain distinct files: {ids}")
            if second_state["restored"]["snapshot"]["workspaces"][0]["search"]["query"] != "alpha":
                raise AssertionError("explicit restore did not recover the first session's query metadata")
            if not second_state["restored"]["snapshot"]["workspaces"][0]["search"]["rerun_required"]:
                raise AssertionError("restored result state was not marked stale")
            if not second_state["bad"] or second_state["bad_code"] != "corrupt_state":
                raise AssertionError("corrupt session state was not safely reported")
            if not second_state["providers"] or second_state["state"] != "disabled":
                raise AssertionError(f"restoration activated runtime work: {second_state}")
            first_final = first.control.exec_lua("return {buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win()}")
            if first.grid.flushes < 1 or first_final["buf"] != first_state["buf"] or first_final["win"] != first_state["win"]:
                raise AssertionError("session recovery changed the editor's visible buffer/window")
            if second_state["buf"] != second_state["initial_buf"] or second_state["win"] != second_state["initial_win"]:
                raise AssertionError("session recovery changed the second editor's visible buffer/window")
            if not corrupt.exists() or not (state_dir / f"session-{saved_a['id']}.json").exists() or not (state_dir / f"session-{second_state['own']}.json").exists():
                raise AssertionError("session save overwrote corrupt history or failed to preserve one process's file")
            result = {
                "grid": f"{cols}x{rows}",
                "nvim": subprocess.run([nvim, "--version"], text=True, capture_output=True, check=True).stdout.splitlines()[0],
                "session_ids": [saved_a["id"], second_state["own"]],
                "distinct_session_files": True,
                "corrupt_file_preserved": True,
                "corrupt_restore_code": second_state["bad_code"],
                "restored_query": "alpha",
                "restored_results": "stale; explicit rerun required",
                "provider_loaded_or_started": False,
                "workbench_state_after_restore": second_state["state"],
                "ui_grid_flushes": first.grid.flushes,
                "first_startup_to_grid_ms": first.first_flush_ms,
                "initial_buffer_lines": first.control.api.buf_get_lines(first_state["buf"], 0, -1, False),
                "save_session_ms": save_a_ms,
                "second_save_session_ms": round(second_state["timings"]["save_ms"], 3),
                "list_sessions_ms": round(second_state["timings"]["list_ms"], 3),
                "restore_session_ms": round(second_state["timings"]["restore_ms"], 3),
                "record_summaries": second_state["records"],
            }
            (output / "screen.txt").write_text("\n".join(first.grid.lines()) + "\n", encoding="utf-8")
            (output / "ui-grid.json").write_text(json.dumps(first.grid.snapshot(), indent=2) + "\n", encoding="utf-8")
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            return result
        except Exception as error:
            (output / "failure.json").write_text(json.dumps({"error": str(error), "traceback": traceback.format_exc(), "screen": first.grid.snapshot()}, indent=2) + "\n", encoding="utf-8")
            raise
        finally:
            second.close()
            first.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb23")
    args = parser.parse_args()
    nvim = str(Path(args.nvim).resolve()) if Path(args.nvim).exists() else (shutil.which(args.nvim) or str(Path(args.nvim).resolve()))
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        try:
            print(json.dumps({"artifacts": str(output), **run_one(nvim, cols, rows, output)}, indent=2))
        except Exception as error:
            print(f"WB-23 Persistence UI failed at {cols}x{rows}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
