#!/usr/bin/env python3
"""Real-grid acceptance for bounded preview and navigation continuity."""

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
from typing import Any

import pynvim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import Grid, git_head, parse_grids  # noqa: E402


class Run:
    def __init__(self, nvim: str, cols: int, rows: int, output: Path):
        candidate = Path(nvim)
        self.nvim = str(candidate.resolve()) if candidate.exists() else (shutil.which(nvim) or str(candidate.resolve()))
        self.cols, self.rows, self.output = cols, rows, output
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.socket = f"/tmp/wb08-{secrets.token_hex(8)}.sock"
        self.command: list[str] = []
        self.xdg: tempfile.TemporaryDirectory[str] | None = None
        self.fixture: tempfile.TemporaryDirectory[str] | None = None
        self.failure: str | None = None
        self.returncode: int | None = None
        self.child_reaped = False
        self.phase = "setup"
        self.outcome: dict[str, Any] = {}

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def wait_lua(self, expression: str, description: str, timeout: float = 6.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(f"return ({expression})"):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}")

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb08-navigation-")
        base = Path(self.fixture.name)
        workspace = base / "workspace"
        workspace.mkdir()
        origin = workspace / "origin.txt"
        target = workspace / "result.txt"
        origin.write_text("disk user content\n", encoding="utf-8")
        target.write_text("before result\nneedle selected result\nafter result\n", encoding="utf-8")
        self.xdg = tempfile.TemporaryDirectory(prefix="wb08-xdg-")
        xdg_root = Path(self.xdg.name)
        for name in ("config", "data", "state", "cache"):
            (xdg_root / name).mkdir()
        environment = os.environ.copy()
        environment.update({
            "XDG_CONFIG_HOME": str(xdg_root / "config"),
            "XDG_DATA_HOME": str(xdg_root / "data"),
            "XDG_STATE_HOME": str(xdg_root / "state"),
            "XDG_CACHE_HOME": str(xdg_root / "cache"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.command = [
            self.nvim, "--clean", "--headless", "--listen", self.socket,
            "--cmd", f"set lines={self.rows} columns={self.cols}",
            "--cmd", f"set runtimepath^={ROOT}",
        ]
        self.proc = subprocess.Popen(self.command, cwd=workspace, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not Path(self.socket).exists():
            if self.proc.poll() is not None:
                stdout, stderr = self.proc.communicate()
                raise RuntimeError(f"Neovim exited before RPC listen: {stdout}\n{stderr}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Neovim RPC socket did not appear")
            time.sleep(0.01)
        self.control = pynvim.attach("socket", path=self.socket)
        self.ui = pynvim.attach("socket", path=self.socket)
        self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb08-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.lua("local args=...; local base=args[1]; vim.o.hidden=true; _G.wb08_origin=base..'/origin.txt'; _G.wb08_target=base..'/result.txt'; vim.api.nvim_cmd({cmd='edit',args={_G.wb08_origin}},{}); _G.wb08_origin_win=vim.api.nvim_get_current_win(); _G.wb08_origin_buf=vim.api.nvim_get_current_buf(); vim.api.nvim_buf_set_lines(_G.wb08_origin_buf,0,-1,false,{'USER MODIFIED ORIGIN','second user line'}); vim.bo[_G.wb08_origin_buf].modified=true; _G.wb08_origin_cursor=vim.api.nvim_win_get_cursor(_G.wb08_origin_win); _G.wb08_jump_before=vim.fn.getjumplist(_G.wb08_origin_win)", str(workspace))

    def _exercise(self) -> dict[str, Any]:
        self.phase = "preview"
        preview_started = time.perf_counter_ns()
        preview = self.lua("local args=...; local path=args[1]; local nav=assert(require('workbench.services.navigation').new({context_before=1,context_after=1})); local Preview=require('workbench.ui.preview'); local view=assert(Preview.new({navigation=nav,session_id='grid-preview'})); local resource=assert(require('workbench.core.resource').from_path(path)); local location=assert(require('workbench.core.location').new(resource,{range={start={line=1,character=7},finish={line=1,character=15}},encoding='utf-8'})); _G.wb08_nav,_G.wb08_view,_G.wb08_location=nav,view,location; local started=(vim.uv or vim.loop).hrtime(); local request=assert(view:preview(location,'grid-preview',function(value) _G.wb08_preview=value end)); return {started=started,request=request~=nil,source_focus=vim.api.nvim_get_current_win()==_G.wb08_origin_win,origin_modified=vim.bo[_G.wb08_origin_buf].modified,origin_line=vim.api.nvim_buf_get_lines(_G.wb08_origin_buf,0,1,false)[1],target_buffer=vim.fn.bufnr(path)}", str(self.fixture.name) + "/workspace/result.txt")
        self.wait_lua("_G.wb08_preview ~= nil", "preview read completion")
        self.grid.wait_for(lambda: any("needle selected result" in line for line in self.grid.lines()), 6, "preview context in the real UI grid")
        preview_view_ms = (time.perf_counter_ns() - preview_started) / 1_000_000
        preview_state = self.lua("local s=_G.wb08_view:status(); local p=_G.wb08_preview; local j=vim.fn.getjumplist(_G.wb08_origin_win); return {status=s,source=p.source,modified=p.modified,target_line=p.target_line,truncated=p.truncated,focus=vim.api.nvim_get_current_win()==_G.wb08_origin_win,buffer_line=vim.api.nvim_buf_get_lines(_G.wb08_origin_buf,0,1,false)[1],origin_modified=vim.bo[_G.wb08_origin_buf].modified,jump_same=vim.deep_equal(_G.wb08_jump_before,j),target_buffer=vim.fn.bufnr(_G.wb08_target),clients=s.buf and #vim.lsp.get_clients({bufnr=s.buf}) or -1,preview_lines=vim.api.nvim_buf_get_lines(s.buf,0,-1,false),source_width=vim.api.nvim_win_get_width(_G.wb08_origin_win),preview_width=s.win and vim.api.nvim_win_get_width(s.win) or 0,source_height=vim.api.nvim_win_get_height(_G.wb08_origin_win),preview_height=s.win and vim.api.nvim_win_get_height(s.win) or 0}")
        if preview_state["source"] != "disk" or preview_state["modified"] or not preview_state["focus"]:
            raise AssertionError(f"preview read/ownership state was wrong: {preview_state}")
        if preview_state["buffer_line"] != "USER MODIFIED ORIGIN" or not preview_state["origin_modified"] or not preview_state["jump_same"]:
            raise AssertionError(f"preview damaged modified origin or jumplist: {preview_state}")
        if preview_state["target_buffer"] >= 0 or preview_state["clients"] != 0:
            raise AssertionError(f"preview opened a live result buffer or attached LSP: {preview_state}")
        expected_mode = "vertical" if self.cols >= 100 else "horizontal"
        if expected_mode == "vertical" and preview_state["preview_width"] < 24:
            raise AssertionError(f"vertical preview is too narrow: {preview_state}")
        if expected_mode == "horizontal" and preview_state["preview_height"] < 4:
            raise AssertionError(f"horizontal preview is too short: {preview_state}")

        self.lua("assert(_G.wb08_view:show({status='loading',path=_G.wb08_target,target_line=1}))")
        self.grid.wait_for(lambda: any("Loading bounded source context" in line for line in self.grid.lines()), 3, "visible loading preview state")
        loading_state_visible = any("Loading bounded source context" in line for line in self.grid.lines())
        self.lua("assert(_G.wb08_view:show({code='read_error',message='permission denied; retry'}))")
        self.grid.wait_for(lambda: any("permission denied" in line for line in self.grid.lines()), 3, "visible preview read error")
        error_state_visible = any("permission denied" in line for line in self.grid.lines())
        self.lua("assert(_G.wb08_view:show(_G.wb08_preview))")
        self.grid.wait_for(lambda: any("needle selected result" in line for line in self.grid.lines()), 3, "restored preview context")
        if not loading_state_visible or not error_state_visible:
            raise AssertionError("preview loading/error state was not rendered in the RPC UI grid")
        preview_screen = self.grid.snapshot()

        self.phase = "commit-return"
        opened = self.lua("local result=assert(_G.wb08_nav:open(_G.wb08_location,'split',_G.wb08_origin_win,'grid-preview')); _G.wb08_opened=result; return {win=result.win,buf=result.buf,jumps_added=result.jumps_added,target_name=vim.api.nvim_buf_get_name(result.buf),target_cursor=vim.api.nvim_win_get_cursor(result.win)}")
        if opened["jumps_added"] != 1 or opened["target_cursor"][0] != 2:
            raise AssertionError(f"committed navigation did not produce one jump at the selected line: {opened}")
        self.control.api.input("<C-O>")
        self.wait_lua("vim.api.nvim_get_current_buf() == _G.wb08_origin_buf", "native jumplist return")
        returned = self.lua("local result=assert(_G.wb08_nav:return_to_origin('grid-preview')); return {win=result.win,focus=vim.api.nvim_get_current_win()==_G.wb08_origin_win,buffer=vim.api.nvim_win_get_buf(result.win),modified=vim.bo[_G.wb08_origin_buf].modified,line=vim.api.nvim_buf_get_lines(_G.wb08_origin_buf,0,1,false)[1]}")
        if not returned["focus"] or not returned["modified"] or returned["line"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"return did not restore user editing state: {returned}")
        self.lua("_G.wb08_view:dispose(); _G.wb08_nav:dispose(); pcall(vim.api.nvim_win_close,_G.wb08_opened.win,true)")
        teardown = self.lua("local view=_G.wb08_view:status(); local nav=_G.wb08_nav:status(); return {view=view,nav=nav,origin_valid=vim.api.nvim_buf_is_valid(_G.wb08_origin_buf),origin_modified=vim.bo[_G.wb08_origin_buf].modified,origin_line=vim.api.nvim_buf_get_lines(_G.wb08_origin_buf,0,1,false)[1],target_buffer=vim.fn.bufnr(_G.wb08_target),origin_focus=vim.api.nvim_get_current_win()==_G.wb08_origin_win}")
        if teardown["view"]["open"] or teardown["view"].get("buf") is not None or teardown["nav"]["pending_reads"] != 0:
            raise AssertionError(f"preview teardown left owned resources: {teardown}")
        if not teardown["origin_valid"] or not teardown["origin_modified"] or teardown["origin_line"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"preview teardown damaged the origin buffer: {teardown}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "layout": expected_mode,
            "preview_source": preview_state["source"],
            "first_preview_view_ms": round(preview_view_ms, 3),
            "preview_content_visible": True,
            "loading_state_visible": loading_state_visible,
            "error_state_visible": error_state_visible,
            "modified_origin_preserved": teardown["origin_modified"],
            "preview_has_no_lsp_client": preview_state["clients"] == 0,
            "target_file_not_loaded_for_preview": preview_state["target_buffer"] < 0,
            "preview_jump_delta": 0,
            "open_jumps_added": opened["jumps_added"],
            "native_ctrl_o_return": True,
            "resume_origin_state": returned,
            "preview_screen": preview_screen["text"],
            "teardown": teardown,
        }

    def _ui_loop(self):
        try:
            assert self.ui is not None
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            if self.proc is not None and self.proc.poll() is None:
                with self.grid.condition:
                    self.grid.callback_error = "RPC UI disconnected while Neovim remained active"
                    self.grid.condition.notify_all()

    def _cleanup(self):
        if self.proc and self.proc.poll() is None and self.control is not None:
            try:
                self.control.command("qa!", async_=True)
            except Exception:
                pass
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.proc:
            self.returncode = self.proc.wait(timeout=3)
            self.child_reaped = True
        for session in (self.control, self.ui):
            if session is not None:
                try:
                    session.close()
                except Exception:
                    pass
        if self.thread:
            self.thread.join(timeout=1)
        Path(self.socket).unlink(missing_ok=True)
        if self.xdg:
            self.xdg.cleanup()
        if self.fixture:
            self.fixture.cleanup()

    def _write_artifacts(self):
        self.output.mkdir(parents=True, exist_ok=True)
        snapshot = self.grid.snapshot()
        (self.output / "ui-grid.json").write_text(json.dumps(snapshot, indent=2, default=str) + "\n")
        (self.output / "screen.txt").write_text("\n".join(snapshot["text"]) + "\n")
        version = subprocess.run([self.nvim, "--version"], text=True, capture_output=True, timeout=3, check=False)
        metadata = {
            "nvim": self.nvim,
            "nvim_version": version.stdout.splitlines()[0] if version.stdout else "unavailable",
            "grid": f"{self.cols}x{self.rows}",
            "command": self.command,
            "environment": {"workbench_head": git_head(ROOT)},
            "returncode": self.returncode,
            "child_reaped": self.child_reaped,
            "failure": self.failure,
            "phase": self.phase,
            "outcome": self.outcome,
        }
        (self.output / ("failure.json" if self.failure else "result.json")).write_text(json.dumps(metadata, indent=2) + "\n")

    def run(self):
        try:
            self._start()
            self.outcome = self._exercise()
            return self.outcome
        except Exception as error:
            self.failure = f"{type(error).__name__}: {error}"
            raise
        finally:
            self._cleanup()
            self._write_artifacts()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb08")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = Run(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-08 navigation UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
