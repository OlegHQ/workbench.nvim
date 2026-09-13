#!/usr/bin/env python3
"""Real RPC-grid acceptance for WB-06 layout, rendering and teardown."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import pynvim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import Grid, git_head, parse_grids  # noqa: E402


class Run:
    def __init__(self, nvim: str, cols: int, rows: int, output: Path):
        self.nvim = nvim
        self.cols = cols
        self.rows = rows
        self.output = output
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.socket = f"/tmp/wb06-{secrets.token_hex(8)}.sock"
        self.watchdog: threading.Timer | None = None
        self.child_reaped = False
        self.returncode: int | None = None
        self.failure: str | None = None
        self.outcome: dict[str, Any] = {}
        self.command: list[str] = []
        self.xdg: tempfile.TemporaryDirectory[str] | None = None
        self.mount_focus: dict[str, Any] = {}
        self.first_view_ms = 0.0

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def wait_lua(self, expression: str, description: str, timeout: float = 5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(f"return ({expression})"):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}")

    def wait_screen(self, fragment: str, timeout: float = 4.0):
        self.grid.wait_for(lambda: any(fragment in line for line in self.grid.lines()), timeout, fragment)

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.xdg = tempfile.TemporaryDirectory(prefix="wb06-xdg-")
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
            self.nvim,
            "--clean",
            "--headless",
            "--listen",
            self.socket,
            "--cmd",
            f"set lines={self.rows} columns={self.cols}",
            "--cmd",
            f"set runtimepath^={ROOT}",
        ]
        self.proc = subprocess.Popen(self.command, cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.watchdog = threading.Timer(90, self._expire)
        self.watchdog.daemon = True
        self.watchdog.start()
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb06-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.control.api.set_option("mouse", "a")
        self.control.api.buf_set_lines(self.control.api.get_current_buf(), 0, -1, True, ["USER OWNED CONTENT"])
        self.control.api.buf_set_option(self.control.api.get_current_buf(), "modified", True)
        self.lua("_G.wb06_origin_buf=vim.api.nvim_get_current_buf(); _G.wb06_origin_win=vim.api.nvim_get_current_win(); _G.wb06_layout=require('workbench.ui.layout').new(); _G.foreign_events=0; _G.foreign_group=vim.api.nvim_create_augroup('WorkbenchForeignProbe',{clear=true}); vim.api.nvim_create_autocmd('User',{group=_G.foreign_group,pattern='ForeignProbe',callback=function() _G.foreign_events=_G.foreign_events+1 end})")

    def _mount(self):
        items = [
            {"id": "root", "label": "Workspace", "kind": "directory"},
            {"id": "alpha", "label": "alpha", "kind": "directory", "parent_id": "root"},
            {"id": "alpha-file", "label": "alpha.py", "kind": "file", "parent_id": "alpha"},
            {"id": "beta", "label": "beta", "kind": "directory", "parent_id": "root"},
            {"id": "beta-file", "label": "beta.py", "kind": "file", "parent_id": "beta"},
            {"id": "wide", "label": "界" + "wide-label-" * 30, "kind": "file", "parent_id": "root"},
        ]
        options = {
            "id": "files",
            "title": "Files",
            "kind": "tree",
            "placement": "sidebar",
            "focus": True,
            "expanded": {"root": True, "alpha": True, "beta": True},
            "model": {"status": "ready", "items": items},
        }
        started = time.perf_counter_ns()
        mounted = self.lua("local args=...; local opts=args[1]; local view,err=_G.wb06_layout:mount(opts); _G.wb06_view=view; if view then view.on_select=function(id, row, activate) _G.wb06_selected=id; if activate then _G.wb06_activated=id end end end; return {ok=view~=nil,error=err,errmsg=vim.v.errmsg}", options)
        if not mounted["ok"]:
            raise RuntimeError(f"layout mount failed: {mounted}")
        self.mount_focus = self.lua("return {current=vim.api.nvim_get_current_win(), view=_G.wb06_view.window, mode=_G.wb06_view.mode, focus=_G.wb06_layout:status().views[1].mode}")
        self.wait_screen("Workspace")
        self.first_view_ms = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_screen("beta.py")
        return self.lua("return _G.wb06_layout:status()")

    def _resize(self, cols: int, rows: int, expected_mode: str):
        assert self.control is not None
        self.control.command(f"set columns={cols} lines={rows}")
        self.grid.wait_for(lambda: self.grid.width == cols and self.grid.height == rows, 4, f"grid resize to {cols}x{rows}")
        self.wait_lua(f"_G.wb06_layout:status().views[1] and _G.wb06_layout:status().views[1].mode == '{expected_mode}'", f"layout reflow to {expected_mode}")
        focus = self.lua("return vim.api.nvim_get_current_win()")
        if focus != self.lua("return _G.wb06_origin_win"):
            raise AssertionError(f"resize stole editor focus while the view was unfocused: {focus}")

    def _exercise(self):
        assert self.control is not None
        initial = self._mount()
        expected_sidebar = "split" if self.cols >= 93 and self.rows >= 13 else "overlay"
        if initial["views"][0]["mode"] != expected_sidebar:
            raise AssertionError(f"wrong sidebar mode at {self.cols}x{self.rows}: {initial['views'][0]['mode']}")
        if len(self.control.api.list_wins()) < 2:
            raise AssertionError("view must preserve its editor window and add an owned panel")
        if self.control.api.win_get_buf(self.lua("return _G.wb06_origin_win")).handle != self.lua("return _G.wb06_origin_buf"):
            raise AssertionError("mount replaced the original editor buffer")

        self.control.api.input(":")
        self.wait_lua("vim.fn.getcmdtype() == ':'", "command prompt activation")
        prompt_attempt = self.lua("local v,err=_G.wb06_layout:mount({id='prompt-test',model={status='ready',items={}}}); return {mounted=v~=nil,error=err,active=_G.wb06_layout:status().active_views}")
        if prompt_attempt["mounted"] or prompt_attempt["error"]["code"] != "prompt_active" or prompt_attempt["active"] != 1:
            raise AssertionError(f"layout obscured or altered an active command prompt: {prompt_attempt}")
        self.control.api.input("\x1b")
        self.wait_lua("vim.fn.getcmdtype() == ''", "command prompt cancellation")

        screen = self.grid.lines()
        target_row = next(index for index, line in enumerate(screen) if "beta.py" in line)
        target_col = screen[target_row].index("beta.py")
        self.control.api.input_mouse("left", "press", "", 0, target_row, target_col)
        self.control.api.input_mouse("left", "release", "", 0, target_row, target_col)
        try:
            self.wait_lua("_G.wb06_selected == 'beta-file'", "mouse selection by stable ID")
        except TimeoutError as error:
            state = self.lua(f"local v=_G.wb06_view; return {{selected=_G.wb06_selected,window=v.window,current=vim.api.nvim_get_current_win(),cursor=vim.api.nvim_win_get_cursor(v.window),config=vim.api.nvim_win_get_config(v.window),mode=vim.api.nvim_get_mode().mode,position={{row={target_row},col={target_col}}}}}")
            raise RuntimeError(f"{error}; mounted={self.mount_focus}; mouse state {state}") from error
        self.control.api.input("?")
        self.wait_screen("Enter: activate")
        self.control.api.input("?")
        self.control.api.input("k")
        self.wait_lua("_G.wb06_selected == 'beta'", "keyboard selection by stable ID")
        self.control.api.input(" ")
        self.grid.wait_for(lambda: not any("beta.py" in line for line in self.grid.lines()), 3.0, "tree branch collapse")
        self.control.api.input(" ")
        self.wait_screen("beta.py")
        self.control.api.input("j")
        self.control.api.input("\r")
        self.wait_lua("_G.wb06_activated == 'beta-file'", "keyboard activation by stable ID")

        self.lua("local args=...; assert(_G.wb06_view:update(args[1]))", {"status": "ready", "items": [
            {"id": "root", "label": "Workspace", "kind": "directory"},
            {"id": "beta", "label": "beta", "kind": "directory", "parent_id": "root"},
            {"id": "beta-file", "label": "beta.py", "kind": "file", "parent_id": "beta"},
            {"id": "wide", "label": "界" + "wide-label-" * 30, "kind": "file", "parent_id": "root"},
        ]})
        self.wait_screen("beta.py")
        rendered = self.lua("local v=_G.wb06_view; local width=vim.api.nvim_win_get_width(v.window); local lines=vim.api.nvim_buf_get_lines(v.buffer,0,-1,false); local max=0; for _,line in ipairs(lines) do max=math.max(max,vim.fn.strdisplaywidth(line)) end; return {width=width,max=max,selected=v.selected_id,mode=v.mode}")
        if rendered["max"] > rendered["width"] - 2:
            raise AssertionError(f"display-cell truncation overflowed panel width: {rendered}")
        if rendered["selected"] != "beta-file":
            raise AssertionError(f"selection did not survive projection update: {rendered}")

        state_screens = {}
        for status, expected in (
            ("idle", "Not started"),
            ("loading", "Loading"),
            ("error", "Error: synthetic failure"),
            ("empty", "No items"),
            ("unavailable", "Unavailable: synthetic provider unavailable"),
        ):
            self.lua("local args=...; local status, expected=args[1],args[2]; assert(_G.wb06_view:update({status=status, error=expected:match('^Error: (.+)$'), reason=expected:match('^Unavailable: (.+)$'), items={}}))", status, expected)
            self.wait_screen("Unavailable" if status == "unavailable" else expected)
            state_screens[status] = expected
            if status in {"loading", "error"} and self.lua("return _G.wb06_view.selected_id") != "beta-file":
                raise AssertionError(f"transient {status} state discarded the stable selection")
        self.lua("local args=...; assert(_G.wb06_view:update(args[1]))", {"status": "ready", "items": [
            {"id": "root", "label": "Workspace", "kind": "directory"},
            {"id": "beta", "label": "beta", "kind": "directory", "parent_id": "root"},
            {"id": "beta-file", "label": "beta.py", "kind": "file", "parent_id": "beta"},
            {"id": "wide", "label": "界" + "wide-label-" * 30, "kind": "file", "parent_id": "root"},
        ]})
        self.wait_screen("beta.py")

        before_theme = self.lua("local names={WorkbenchTitle='Title',WorkbenchItem='Normal',WorkbenchSelection='CursorLine',WorkbenchHelp='Comment',WorkbenchError='ErrorMsg',WorkbenchDetail='NonText'}; local found={}; for name,target in pairs(names) do found[name]=vim.api.nvim_get_hl(0,{name=name,link=true}).link==target end; return found")
        self.control.command("colorscheme habamax")
        after_theme = self.lua("local names={WorkbenchTitle='Title',WorkbenchItem='Normal',WorkbenchSelection='CursorLine',WorkbenchHelp='Comment',WorkbenchError='ErrorMsg',WorkbenchDetail='NonText'}; local found={}; for name,target in pairs(names) do found[name]=vim.api.nvim_get_hl(0,{name=name,link=true}).link==target end; return found")
        if not all(before_theme.values()) or not all(after_theme.values()):
            raise AssertionError(f"semantic links were lost across a theme change: {before_theme}, {after_theme}")

        self.control.api.input("q")
        self.wait_lua("_G.wb06_layout:status().active_views == 0", "keyboard view close")
        focus = self.lua("return {win=vim.api.nvim_get_current_win(), buf=vim.api.nvim_get_current_buf(), origin_win=_G.wb06_origin_win, origin_buf=_G.wb06_origin_buf, modified=vim.bo[_G.wb06_origin_buf].modified, line=vim.api.nvim_buf_get_lines(_G.wb06_origin_buf,0,1,false)[1], resources=_G.wb06_layout:status().resources.resource_count}")
        if focus["win"] != focus["origin_win"] or focus["buf"] != focus["origin_buf"] or not focus["modified"] or focus["line"] != "USER OWNED CONTENT" or focus["resources"] != 0:
            raise AssertionError(f"view close did not restore the editor or preserve its state: {focus}")

        expected_results = "split" if self.rows >= 8 + 8 + 5 else "overlay"
        preview_items = [{"id": f"preview.line.{index:03d}", "kind": "preview", "label": f"Preview line {index:03d}"} for index in range(1, 41)]
        preview_view = self.lua("local args=...; local opts=args[1]; local v=assert(_G.wb06_layout:mount(opts)); return {mode=v.mode}", {
            "id": "preview",
            "title": "Preview",
            "kind": "list",
            "placement": "results",
            "focus": True,
            "model": {"status": "ready", "items": preview_items},
        })
        if preview_view["mode"] != expected_results:
            raise AssertionError(f"wrong synthetic preview geometry at {self.cols}x{self.rows}: {preview_view}")
        self.wait_screen("Preview line 001")
        self.control.api.input("j" * 20)
        self.wait_lua("_G.wb06_layout:get('preview').selected_id == 'preview.line.021'", "keyboard navigation to offscreen preview row")
        self.wait_screen("… previous items")
        self.wait_screen("Preview line 021")
        preview_selection = self.lua("local v=_G.wb06_layout:get('preview'); return {selected=v.selected_id,offset=v.scroll_offset}")
        if preview_selection["selected"] != "preview.line.021" or preview_selection["offset"] == 0:
            raise AssertionError(f"keyboard navigation did not scroll the preview projection: {preview_selection}")
        self.control.api.set_current_win(self.lua("return _G.wb06_origin_win"))
        if (self.cols, self.rows) != (120, 35):
            self._resize(120, 35, "split")
            self._resize(60, 20, "overlay")
            self._resize(self.cols, self.rows, expected_results)
        if self.lua("return _G.wb06_layout:get('preview').selected_id") != "preview.line.021":
            raise AssertionError("resize changed the selected stable preview ID")
        self.control.api.set_current_win(self.lua("return _G.wb06_layout:get('preview').window"))
        self.control.api.input("q")
        self.wait_lua("_G.wb06_layout:status().active_views == 0", "synthetic preview close")
        preview_close = self.lua("return {win=vim.api.nvim_get_current_win(),origin= _G.wb06_origin_win,resources=_G.wb06_layout:status().resources.resource_count}")
        if preview_close["win"] != preview_close["origin"] or preview_close["resources"] != 0:
            raise AssertionError(f"preview resize/close did not restore layout: {preview_close}")

        self.lua("_G.wb06_view=assert(_G.wb06_layout:mount({id='queued',title='Queued',focus=true,model={status='ready',items={{id='queued.item',label='queued'}}}})); _G.wb06_queue={}; _G.wb06_ticket=assert(_G.wb06_view:render_later({status='ready',items={{id='stale',label='STALE RENDER'}}},function(cb) table.insert(_G.wb06_queue,cb) end)); _G.wb06_old_view_buf=_G.wb06_view.buffer")
        self.control.command("tabnew")
        self.lua("vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), _G.wb06_origin_buf)")
        self.control.command("tabprevious")
        self.lua("assert(_G.wb06_layout:get('queued'))")
        self.control.command("tabnext")
        self.control.command("tabprevious")
        self.control.command("tabclose")
        self.wait_lua("_G.wb06_layout:status().active_views == 0", "tab closure disposal")
        self.lua("_G.wb06_queue[1]()")
        cleanup = self.lua("return {layout=_G.wb06_layout:status(), old_buffer_valid=vim.api.nvim_buf_is_valid(_G.wb06_old_view_buf), origin_valid=vim.api.nvim_buf_is_valid(_G.wb06_origin_buf), origin_modified=vim.bo[_G.wb06_origin_buf].modified, origin_line=vim.api.nvim_buf_get_lines(_G.wb06_origin_buf,0,1,false)[1]}")
        if cleanup["old_buffer_valid"] or not cleanup["origin_valid"] or not cleanup["origin_modified"] or cleanup["origin_line"] != "USER OWNED CONTENT":
            raise AssertionError(f"tab cleanup damaged user state or left view buffer live: {cleanup}")
        if cleanup["layout"]["active_views"] != 0 or cleanup["layout"]["resources"]["resource_count"] != 0:
            raise AssertionError(f"tab cleanup retained layout resources: {cleanup}")

        results_view = self.lua("local v=assert(_G.wb06_layout:mount({id='results',title='Results',kind='list',placement='results',focus=false,model={status='ready',items={{id='result-1',label='A result'}}}})); return {mode=v.mode,selected=v.selected_id}")
        if results_view["mode"] != expected_results:
            raise AssertionError(f"wrong results geometry at {self.cols}x{self.rows}: {results_view}")
        self.wait_screen("A result")
        self.lua("assert(_G.wb06_layout:close('results'))")

        cycles = 100
        self.lua("for i=1,100 do local view=assert(_G.wb06_layout:mount({id='cycle-'..i,title='Cycle',focus=false,model={status='ready',items={{id='cycle.item.'..i,label='item'}}}})); assert(view:close()); local s=_G.wb06_layout:status(); assert(s.active_views==0 and s.resources.resource_count==0, 'leak after cycle '..i) end")
        final = self.lua("return _G.wb06_layout:status()")
        if final["active_views"] != 0 or final["resources"]["resource_count"] != 0:
            raise AssertionError(f"100 mount/close cycles retained resources: {final}")
        self.lua("_G.wb06_layout:dispose(); vim.api.nvim_exec_autocmds('User',{pattern='ForeignProbe'}); assert(_G.foreign_events==1); assert(#vim.api.nvim_get_autocmds({group=_G.foreign_group})==1)")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "sidebar_mode": expected_sidebar,
            "results_mode": expected_results,
            "first_interactive_view_ms": round(self.first_view_ms, 3),
            "prompt_mount_rejected": True,
            "mouse_selected_id": "beta-file",
            "keyboard_activated_id": "beta-file",
            "selection_survived_update": rendered["selected"],
            "display_width": rendered["max"],
            "panel_width": rendered["width"],
            "semantic_theme_links_before_and_after": {"before": before_theme, "after": after_theme},
            "states_rendered": state_screens,
            "preview_scrolled_selection": preview_selection,
            "user_buffer_preserved": True,
            "queued_render_rejected_after_tab_close": not cleanup["old_buffer_valid"],
            "cycles": cycles,
            "final_resources": final["resources"]["resource_count"],
            "foreign_autocmd_preserved": True,
        }

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

    def _ui_loop(self):
        try:
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            if self.proc is not None and self.proc.poll() is None:
                with self.grid.condition:
                    self.grid.callback_error = "RPC UI disconnected while Neovim remained active"
                    self.grid.condition.notify_all()

    def _expire(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()

    def _cleanup(self):
        if self.watchdog:
            self.watchdog.cancel()
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
            "outcome": self.outcome,
        }
        name = "failure.json" if self.failure else "result.json"
        (self.output / name).write_text(json.dumps(metadata, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb06")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = Run(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-06 UI failed at {cols}x{rows}; artifacts: {output}\n{error}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
