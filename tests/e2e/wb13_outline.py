#!/usr/bin/env python3
"""Real RPC-grid acceptance for Outline nesting, cursor tracking and teardown."""

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


class OutlineRun:
    def __init__(self, nvim: str, cols: int, rows: int, output: Path):
        self.nvim = str(Path(nvim).resolve()) if Path(nvim).exists() else (shutil.which(nvim) or str(Path(nvim).resolve()))
        self.cols, self.rows, self.output = cols, rows, output
        self.socket = f"/tmp/wb13-{secrets.token_hex(8)}.sock"
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.fixture: tempfile.TemporaryDirectory[str] | None = None
        self.xdg: tempfile.TemporaryDirectory[str] | None = None
        self.command: list[str] = []
        self.failure: str | None = None
        self.returncode: int | None = None
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

    def input(self, keys: str):
        assert self.control is not None
        self.control.request("nvim_input", keys, async_=True)

    def wait_screen(self, fragment: str):
        self.grid.wait_for(lambda: any(fragment in line for line in self.grid.lines()), 6, fragment)

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb13-outline-")
        self.xdg = tempfile.TemporaryDirectory(prefix="wb13-xdg-")
        xdg = Path(self.xdg.name)
        for name in ("config", "data", "state", "cache"):
            (xdg / name).mkdir()
        workspace = Path(self.fixture.name)
        source = workspace / "outline.lua"
        source.write_text("local Zoo = {}\nfunction inner() return true end\nlocal alpha = 1\n", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "XDG_CONFIG_HOME": str(xdg / "config"),
            "XDG_DATA_HOME": str(xdg / "data"),
            "XDG_STATE_HOME": str(xdg / "state"),
            "XDG_CACHE_HOME": str(xdg / "cache"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.command = [
            self.nvim, "--clean", "--headless", "--listen", self.socket,
            "--cmd", f"set lines={self.rows} columns={self.cols}",
            "--cmd", f"set runtimepath^={ROOT}",
        ]
        self.proc = subprocess.Popen(self.command, cwd=workspace, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb13-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.lua(
            "local args=...; vim.o.hidden=true; vim.api.nvim_cmd({cmd='edit',args={args[1]}},{}); vim.api.nvim_win_set_cursor(0,{1,8}); "
            "_G.wb13_buffer=vim.api.nvim_get_current_buf(); _G.wb13_editor=vim.api.nvim_get_current_win(); "
            "local provider={available=true,requests={}}; function provider:capabilities() "
            "if not self.available then return {state='unavailable',code='no_attached_client',reason='No attached language server supports document symbols'} end; "
            "return {state='ready',clients={{id=7,encoding='utf-8'}}} end; "
            "function provider:start(options,sink) local request={options=options,sink=sink,active=true}; self.requests[#self.requests+1]=request; "
            "local handle={}; function handle:is_active() return request.active end; function handle:cancel(reason) request.active=false; request.cancelled=reason; return true end; "
            "request.handle=handle; return handle end; _G.wb13_provider=provider; "
            "_G.wb13_layout=assert(require('workbench.ui.layout').new({min_editor_width=30,min_editor_height=8})); "
            "_G.wb13_navigation=assert(require('workbench.services.navigation').new()); "
            "_G.wb13_controller=assert(require('workbench.controllers.outline').new({layout=_G.wb13_layout,provider=provider,navigation=_G.wb13_navigation})); "
            "_G.wb13_view=assert(_G.wb13_controller:open({focus=true})); "
            "_G.wb13_session=_G.wb13_controller.sessions[vim.api.nvim_get_current_tabpage()]; "
            "_G.wb13_foreign_group=vim.api.nvim_create_augroup('WB13Foreign', {clear=true}); "
            "vim.api.nvim_create_autocmd('TextChanged',{group=_G.wb13_foreign_group,buffer=_G.wb13_buffer,callback=function() end}); "
            "return {mode=_G.wb13_view.mode,requests=#provider.requests}",
            str(source),
        )
        self.wait_screen("Outline")

    def _complete_symbols(self):
        self.lua(
            "local buffer,path=_G.wb13_buffer,vim.api.nvim_buf_get_name(_G.wb13_buffer); local uri=vim.uri_from_fname(path); "
            "local function make(id,label,parent,sl,sc,el,ec,pl,pc) local location=assert(require('workbench.core.location').new("
            "{uri=uri,scheme='file',path=path},{range={start={line=sl,character=sc},finish={line=sl,character=sc+2}},encoding='utf-8',client_id=7})); "
            "return {id=id,label=label,parent_id=parent,kind='symbol',location=location,payload={client_id=7,symbol_kind=12,"
            "symbol_range={start={line=sl,character=sc},['end']={line=el,character=ec}},"
            "selection_range={start={line=sl,character=sc},['end']={line=sl,character=sc+2}}}} end; "
            "local req=_G.wb13_provider.requests[#_G.wb13_provider.requests]; req.sink({kind='batch',client_id=7,items={"
            "make('zoo','Zoo',nil,0,6,2,15),make('inner','inner','zoo',1,9,1,32),make('alpha','alpha',nil,2,6,2,15)}}); "
            "req.sink({kind='done',status='complete'}); return true"
        )
        self.wait_lua("_G.wb13_session.status=='ready' and #_G.wb13_view.rows==3", "document symbols projected")

    def _exercise(self) -> dict[str, Any]:
        self.phase = "nested-outline-and-cursor-tracking"
        self._complete_symbols()
        self.wait_screen("Zoo")
        self.wait_screen("inner")
        active_start = self.lua("return {active=tostring(_G.wb13_session.active_id),selected=tostring(_G.wb13_view.selected_id),requests=#_G.wb13_provider.requests}")
        if active_start["active"] != "zoo" or active_start["selected"] != "zoo":
            raise AssertionError(f"unexpected initial Outline state: {active_start}")

        self.input("j")
        self.wait_lua("_G.wb13_view.selected_id=='inner'", "manual selection of nested symbol")
        self.lua("vim.api.nvim_set_current_win(_G.wb13_editor); vim.api.nvim_win_set_cursor(_G.wb13_editor,{3,8}); vim.api.nvim_exec_autocmds('CursorMoved',{buffer=_G.wb13_buffer})")
        self.wait_lua("_G.wb13_session.active_id=='alpha'", "cursor highlight follows enclosing symbol")
        selection = self.lua("return {selected=_G.wb13_view.selected_id,active=_G.wb13_session.active_id,requests=#_G.wb13_provider.requests}")
        if selection != {"selected": "inner", "active": "alpha", "requests": 1}:
            raise AssertionError(f"editor cursor stole the manual Outline selection or made another request: {selection}")

        self.lua("vim.api.nvim_set_current_win(_G.wb13_view.window)")
        self.input("o")
        self.wait_lua("_G.wb13_view.rows[1].id=='alpha' and _G.wb13_view.model.title:find('name order')~=nil", "name-order mapping")
        self.wait_screen("name order")
        self.lua("_G.wb13_controller:set_filter('inner')")
        self.wait_lua("#_G.wb13_view.rows==2 and _G.wb13_view.rows[1].id=='zoo'", "filter retains matching symbol ancestor")
        self.wait_screen("Zoo")
        filtered = self.grid.snapshot()
        (self.output / "filtered-grid.json").write_text(json.dumps(filtered, indent=2) + "\n", encoding="utf-8")
        self.lua("_G.wb13_controller:set_filter(''); _G.wb13_controller:set_order('source'); _G.wb13_view.selected_id='inner'; _G.wb13_view:update(_G.wb13_view.model)")

        self.lua("vim.api.nvim_set_current_win(_G.wb13_editor); vim.api.nvim_win_set_cursor(_G.wb13_editor,{2,18}); vim.api.nvim_exec_autocmds('CursorMoved',{buffer=_G.wb13_buffer})")
        self.wait_lua("_G.wb13_session.active_id=='inner'", "cursor returns to nested symbol")

        self.lua("vim.api.nvim_set_current_win(_G.wb13_view.window)")
        self.input("b")
        self.wait_lua("_G.wb13_session.breadcrumbs_enabled==false", "optional breadcrumb toggle")
        self.input("b")
        self.wait_lua("_G.wb13_session.breadcrumbs_enabled==true", "breadcrumb restoration")
        self.wait_screen("Breadcrumbs: Zoo › inner")
        breadcrumb_grid = self.grid.snapshot()
        (self.output / "breadcrumbs-grid.json").write_text(json.dumps(breadcrumb_grid, indent=2) + "\n", encoding="utf-8")

        # Enter activates the currently selected symbol through shared Navigation.
        self.input("\r")
        self.wait_lua("vim.api.nvim_get_current_win()==_G.wb13_editor and vim.api.nvim_win_get_cursor(_G.wb13_editor)[1]==2", "navigation to selected symbol")
        nav = self.lua("return _G.wb13_navigation:status()")
        if nav.get("navigation_entries") != 1:
            raise AssertionError(f"Outline did not use the shared navigation history: {nav}")

        self.lua("vim.api.nvim_set_current_win(_G.wb13_view.window)")
        self.input("q")
        self.wait_lua("_G.wb13_controller:status().session_count==0", "Outline close cleanup")
        teardown = self.lua(
            "local s=_G.wb13_controller:status(); local foreign=#vim.api.nvim_get_autocmds({group=_G.wb13_foreign_group,event='TextChanged',buffer=_G.wb13_buffer}); "
            "return {sessions=s.session_count,observer=s.observer_active,watchers=s.watcher_count,requests=s.request_count,foreign=foreign,layout=_G.wb13_layout:status().active_views}"
        )
        if teardown != {"sessions": 0, "observer": False, "watchers": 0, "requests": 0, "foreign": 1, "layout": 0}:
            raise AssertionError(f"Outline teardown leaked resources or removed a foreign autocmd: {teardown}")
        self.lua(
            "_G.wb13_view=assert(_G.wb13_controller:open({focus=true})); "
            "_G.wb13_session=_G.wb13_controller.sessions[vim.api.nvim_get_current_tabpage()]"
        )
        self._complete_symbols()
        self.wait_lua("_G.wb13_view.selected_id=='inner'", "manual selection restored after reopen")
        self.wait_screen("inner")
        self.input("q")
        self.wait_lua("_G.wb13_controller:status().session_count==0", "reopened Outline close cleanup")
        self.lua("_G.wb13_controller:dispose(); _G.wb13_navigation:dispose(); _G.wb13_layout:dispose()")
        final_grid = self.grid.snapshot()
        (self.output / "final-grid.json").write_text(json.dumps(final_grid, indent=2) + "\n", encoding="utf-8")
        return {"grid": f"{self.cols}x{self.rows}", "initial": active_start, "cursor_selection": selection, "navigation": nav, "teardown": teardown, "reopen_selection_restored": True}

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
            self.proc.kill()
        if self.proc:
            self.returncode = self.proc.wait(timeout=3)
        for session in (self.control, self.ui):
            if session is not None:
                try:
                    session.close()
                except Exception:
                    pass
        if self.thread:
            self.thread.join(timeout=1)
        Path(self.socket).unlink(missing_ok=True)
        if self.fixture:
            self.fixture.cleanup()
        if self.xdg:
            self.xdg.cleanup()

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
            snapshot = self.grid.snapshot()
            (self.output / "ui-grid.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
            (self.output / "screen.txt").write_text("\n".join(snapshot["text"]) + "\n", encoding="utf-8")
            metadata = {
                "nvim": self.nvim, "grid": f"{self.cols}x{self.rows}", "command": self.command,
                "workbench_head": git_head(ROOT), "returncode": self.returncode,
                "failure": self.failure, "phase": self.phase, "outcome": self.outcome,
            }
            (self.output / ("failure.json" if self.failure else "result.json")).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb13")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = OutlineRun(args.nvim, cols, rows, output)
        try:
            print(json.dumps({"artifacts": str(output), **run.run()}, indent=2))
        except Exception as error:
            print(f"WB-13 Outline UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
