#!/usr/bin/env python3
"""Real Neovim RPC-grid acceptance for scoped Search and the action palette."""

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
        self.nvim = str(Path(nvim).resolve()) if Path(nvim).exists() else (shutil.which(nvim) or str(Path(nvim).resolve()))
        self.cols, self.rows, self.output = cols, rows, output
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.socket = f"/tmp/wb10-{secrets.token_hex(8)}.sock"
        self.xdg: tempfile.TemporaryDirectory[str] | None = None
        self.fixture: tempfile.TemporaryDirectory[str] | None = None
        self.workspace: Path | None = None
        self.editor_cwd: Path | None = None
        self.command: list[str] = []
        self.failure: str | None = None
        self.returncode: int | None = None
        self.child_reaped = False
        self.phase = "setup"
        self.first_shell_ms: float | None = None
        self.outcome: dict[str, Any] = {}

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def wait_lua(self, expression: str, description: str, timeout: float = 8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(expression):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}")

    def wait_screen(self, fragment: str, timeout: float = 8.0):
        self.grid.wait_for(lambda: any(fragment in line for line in self.grid.lines()), timeout, fragment)

    def input(self, keys: str):
        assert self.control is not None
        self.control.request("nvim_input", keys, async_=True)

    def prompt(self, key: str, value: str, prompt_fragment: str, pending_fragment: str | None = None):
        self.input(key)
        self.wait_screen(prompt_fragment)
        self.input("\x15" + value + "\r")
        if pending_fragment:
            self.wait_screen(pending_fragment)
        time.sleep(0.08)

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb10-search-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.editor_cwd = base / "editor-cwd"
        (self.workspace / "A").mkdir(parents=True)
        (self.workspace / "B").mkdir()
        self.editor_cwd.mkdir()
        self.origin = base / "origin.txt"
        self.target = self.workspace / "A" / "a-target.txt"
        self.sibling = self.workspace / "A" / "sibling.txt"
        self.origin.write_text("original disk origin\nsecond origin line\n", encoding="utf-8")
        self.target.write_text("\n".join(f"disk needle line {index}" for index in range(1, 7)) + "\n", encoding="utf-8")
        self.sibling.write_text("\n".join(f"sibling needle match {index}" for index in range(1, 5)) + "\n", encoding="utf-8")
        (self.workspace / "B" / "cwd-decoy.txt").write_text("needle outside chosen folder\n", encoding="utf-8")
        (self.workspace / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
        (self.workspace / "ignored.txt").write_text("needle ignored by workspace policy\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb10-xdg-")
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
        self.proc = subprocess.Popen(self.command, cwd=self.editor_cwd, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb10-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.control.api.set_option("mouse", "a")
        shell_started = time.perf_counter_ns()
        self.lua("local args=...; vim.o.hidden=true; _G.wb10_origin_path=args[1]; _G.wb10_target_path=assert((vim.uv or vim.loop).fs_realpath(args[2])); vim.api.nvim_cmd({cmd='edit',args={_G.wb10_origin_path}},{}); _G.wb10_origin_win=vim.api.nvim_get_current_win(); _G.wb10_origin_buf=vim.api.nvim_get_current_buf(); vim.api.nvim_buf_set_lines(_G.wb10_origin_buf,0,-1,false,{'USER MODIFIED ORIGIN','second user line'}); vim.bo[_G.wb10_origin_buf].modified=true; _G.wb10_jump_before=vim.fn.getjumplist(_G.wb10_origin_win); local root=args[3]; local Workspace=require('workbench.services.workspace'); _G.wb10_workspace=assert(Workspace.new({root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=root}); _G.wb10_layout=require('workbench.ui.layout').new({min_editor_width=30,min_editor_height=8,results_height=8}); _G.wb10_provider=assert(require('workbench.providers.rg').new({max_items=8,max_batch_items=2})); _G.wb10_store=assert(require('workbench.services.results').new()); _G.wb10_nav=assert(require('workbench.services.navigation').new()); _G.wb10_actions=require('workbench.core.actions').new(); _G.wb10_controller=assert(require('workbench.controllers.search').new({layout=_G.wb10_layout,provider=_G.wb10_provider,store=_G.wb10_store,navigation=_G.wb10_nav,actions=_G.wb10_actions,workspace=_G.wb10_workspace,debounce_ms=80})); local dirty=vim.fn.bufadd(_G.wb10_target_path); vim.fn.bufload(dirty); vim.api.nvim_buf_set_lines(dirty,0,-1,false,{'USER EDITED needle target','unsaved second line','unsaved third line'}); vim.bo[dirty].modified=true; _G.wb10_dirty_buf=dirty; _G.wb10_cwd=vim.fn.getcwd(); _G.wb10_view=assert(_G.wb10_controller:search_in_folder(_G.wb10_workspace,assert((vim.uv or vim.loop).fs_realpath(root))..'/A',{focus=true})); return {workspace=_G.wb10_workspace.roots[1].path,cwd=_G.wb10_cwd,view=_G.wb10_view.mode,dirty=vim.bo[dirty].modified}", str(self.origin), str(self.target), str(self.workspace))
        self.grid.wait_for(lambda: any("Query: (empty query)" in line for line in self.grid.lines()), 8, "empty Search shell in grid")
        self.wait_screen("Enter / to search the selected scope")
        self.wait_lua("return _G.wb10_provider:status().active_requests==0 and _G.wb10_controller.active[vim.api.nvim_get_current_tabpage()].query==''", "empty query without repository scan")
        empty_screen = self.grid.snapshot()["text"]
        (self.output / "empty-query-screen.txt").write_text("\n".join(empty_screen) + "\n", encoding="utf-8")
        self.first_shell_ms = (time.perf_counter_ns() - shell_started) / 1_000_000

    def _exercise(self) -> dict[str, Any]:
        assert self.workspace is not None and self.target is not None
        self.phase = "real-query-input"
        started = time.perf_counter_ns()
        self.prompt("/", "needle", "Search folder:", pending_fragment="Waiting for query debounce")
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; local r=e and _G.wb10_store:summary(e.result_id); return r and r.status~='running'", "real ripgrep completion")
        self.wait_screen("Scope: folder:A")
        self.wait_screen("Query: needle")
        self.wait_lua("return _G.wb10_controller.active[vim.api.nvim_get_current_tabpage()].total>0", "first visible result batch")
        first_result_ms = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; return s.preview and s.preview.last_preview~=nil", "bounded result preview")
        self.grid.wait_for(lambda: any("[Preview]" in line for line in self.grid.lines()), 8, "preview in actual grid")
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; local item=s.selected_id and _G.wb10_store:item(e.result_id,s.selected_id); return item and item.location.resource.path==_G.wb10_target_path and s.preview.last_preview and s.preview.last_preview.path==_G.wb10_target_path and s.preview.last_preview.modified", "modified-buffer preview")
        self.grid.wait_for(lambda: any("USER EDITED needle target" in line for line in self.grid.lines()), 8, "modified-buffer preview in the rendered grid")

        self.phase = "scope-policy-and-preview"
        first_state = self.lua("local c=_G.wb10_controller; local s=c.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; local summary=_G.wb10_store:summary(e.result_id); local paths={}; for _,item in ipairs(_G.wb10_store:page(e.result_id,0,200).items) do paths[vim.api.nvim_buf_get_name(vim.fn.bufadd(item.location.resource.path))]=true end; local names={}; for path in pairs(paths) do names[vim.fn.fnamemodify(path,':t')]=true end; local action={}; for _,a in ipairs(_G.wb10_actions:list(c:_action_context({workspace=_G.wb10_workspace,search=s}))) do if a.id=='search.toggle_ignored' or a.id=='search.open_buffers' then action[a.id]={enabled=a.available.enabled,reason=a.available.reason} end end; return {summary=summary,total=s.total,names=names,header=s.view.model.header,phase=s.phase,view_mode=s.view.mode,preview=s.preview.last_preview,focus=vim.api.nvim_get_current_win()==s.view.window,cwd=vim.fn.getcwd(),cwd_expected=_G.wb10_cwd,dirty=vim.bo[_G.wb10_dirty_buf].modified,dirty_lines=vim.api.nvim_buf_get_lines(_G.wb10_dirty_buf,0,-1,false),actions=action,screen=s.view.buffer and vim.api.nvim_buf_get_lines(s.view.buffer,0,-1,false) or {}}")
        # Ripgrep streams file groups in filesystem traversal order; the bounded
        # eight-item disk cap can retain two or four sibling matches depending
        # on which file group arrives first. The modified target still replaces
        # every disk result for that URI, so the merged partial set is 3–5.
        if first_state["summary"]["status"] != "partial" or not 3 <= first_state["total"] <= 5:
            raise AssertionError(f"search cap was not represented as partial: {first_state}")
        if set(first_state["names"]) != {"a-target.txt", "sibling.txt"}:
            raise AssertionError(f"folder scope leaked or omitted results: {first_state['names']}")
        if not any("Scope: folder:A" in line for line in first_state["header"]):
            raise AssertionError(f"folder scope is not visible: {first_state['header']}")
        if not any("disk plus 1 modified buffer snapshot" in line for line in first_state["header"]):
            raise AssertionError(f"disk-vs-unsaved warning was not shown: {first_state['header']}")
        if first_state["cwd"] != first_state["cwd_expected"] or not first_state["dirty"]:
            raise AssertionError(f"search changed cwd or dirtied-buffer state: {first_state}")
        if not first_state["preview"]["modified"] or not first_state["focus"]:
            raise AssertionError(f"preview did not label the loaded modified buffer or preserve Search focus: {first_state}")
        if not first_state["actions"]["search.toggle_ignored"]["enabled"]:
            raise AssertionError("workspace ignored-policy toggle unexpectedly unavailable for folder scope")

        mouse_target = self.lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local visible={}; for _,row in ipairs(s.view.visible_rows) do visible[row.id]=row end; for line,id in pairs(s.view.row_by_line) do local row=visible[id]; if row and (row.kind=='match' or row.kind=='file') then local pos=vim.fn.screenpos(s.view.window,line,1); return {id=id,kind=row.kind,row=pos.row-1,col=pos.col+7} end end")
        if not mouse_target or mouse_target["row"] < 0:
            raise AssertionError(f"no selectable Search result row is visible for mouse selection: {mouse_target}")
        self.lua("local args=...; _G.wb10_expected_mouse_id=args[1]", mouse_target["id"])
        self.control.api.input_mouse("left", "press", "", 0, mouse_target["row"], mouse_target["col"])
        self.control.api.input_mouse("left", "release", "", 0, mouse_target["row"], mouse_target["col"])
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; return s.view.selected_id==_G.wb10_expected_mouse_id and vim.api.nvim_get_current_win()==s.view.window", "mouse selection reaches a visible Search result row")
        mouse_selection = self.lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; return {selected=s.view.selected_id,active_match=s.selected_id,preview_line=s.preview.last_preview.target_line,focus=vim.api.nvim_get_current_win()==s.view.window}")
        if mouse_selection["selected"] != mouse_target["id"] or not mouse_selection["focus"]:
            raise AssertionError(f"mouse selection did not select the visible Search row while retaining focus: {mouse_selection}")

        self.phase = "action-palette"
        self.input("P")
        self.wait_screen("Actions · Enter")
        self.prompt("/", "open buffers", "Filter actions:")
        self.wait_screen("Search open buffers")
        palette_state = self.lua("local p=_G.wb10_controller.palette.active[vim.api.nvim_get_current_tabpage()]; local a=p.by_id['search.open_buffers']; return {enabled=a and a.available.enabled,reason=a and a.available.reason,items=p.view.model.items}")
        if not palette_state["items"] or not palette_state["enabled"]:
            raise AssertionError(f"palette did not expose the implemented open-buffer search action: {palette_state}")
        self.input("q")
        self.wait_lua("return _G.wb10_controller.palette:status().active==0", "palette disposal")

        self.phase = "open-return-resume"
        self.lua("vim.api.nvim_set_current_win(_G.wb10_view.window)")
        open_ready = self.lua("local v=_G.wb10_view; local w=v.window; local m=vim.fn.maparg('o','n',false,true); return {window=w,valid=w and vim.api.nvim_win_is_valid(w),current=vim.api.nvim_get_current_win(),buffer=w and vim.api.nvim_win_get_buf(w),view_buffer=v.buffer,map_desc=m.desc,map_callback=type(m.callback),mode=vim.api.nvim_get_mode().mode}")
        if not open_ready["valid"] or open_ready["buffer"] != open_ready["view_buffer"] or "Open selected" not in (open_ready["map_desc"] or ""):
            raise AssertionError(f"Search open key was not mounted in its native view: {open_ready}")
        self.input("o")
        self.wait_lua("return _G.wb10_nav:status().navigation_entries==1", "committed search navigation")
        opened = self.lua("local wins=vim.api.nvim_tabpage_list_wins(0); local target; for _,w in ipairs(wins) do local b=vim.api.nvim_win_get_buf(w); if vim.api.nvim_buf_get_name(b)==_G.wb10_target_path then target={win=w,buf=b,cursor=vim.api.nvim_win_get_cursor(w)} end end; return target")
        if not opened or opened["cursor"][0] > 3:
            raise AssertionError(f"selected result did not open at its reported location: {opened}")
        self.lua("vim.api.nvim_set_current_win(_G.wb10_view.window)")
        self.input("R")
        self.wait_lua("return vim.api.nvim_get_current_buf()==_G.wb10_origin_buf", "return to modified search origin")
        returned = self.lua("return {modified=vim.bo[_G.wb10_origin_buf].modified,line=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1],jump_same=vim.deep_equal(_G.wb10_jump_before,vim.fn.getjumplist(_G.wb10_origin_win)),cwd=vim.fn.getcwd()}")
        if not returned["modified"] or returned["line"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"search navigation damaged the modified origin: {returned}")
        if not returned["jump_same"]:
            raise AssertionError(f"search preview/open changed the origin jumplist: {returned}")

        query_id = first_state["summary"]["id"]
        self.lua("vim.api.nvim_set_current_win(_G.wb10_view.window)")
        self.input("q")
        self.wait_lua("return _G.wb10_controller:status().active_views==0", "Search view disposal")
        reopened = self.lua("local v=assert(_G.wb10_controller:open({workspace=_G.wb10_workspace,focus=true})); _G.wb10_view=v; local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; return {query=s.query,id=s.investigation.current.result_id,selected=s.selected_id~=nil,phase=s.phase}")
        self.wait_screen("Query: needle")
        if reopened["query"] != "needle" or reopened["id"] != query_id or not reopened["selected"]:
            raise AssertionError(f"reopening Search did not resume its query and selection: {reopened}")

        self.phase = "search-error-and-empty-states"
        self.input("l")
        self.prompt("/", "[", "Search folder:")
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; return _G.wb10_store:summary(e.result_id).status=='error'", "invalid-regex error state")
        self.wait_screen("Search failed")
        error_screen = self.grid.snapshot()["text"]
        (self.output / "invalid-regex-screen.txt").write_text("\n".join(error_screen) + "\n", encoding="utf-8")
        regex_error = self.lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local r=_G.wb10_store:summary(s.investigation.current.result_id); return {fixed=s.flags.fixed,status=r.status,error=r.error and r.error.code}")
        if regex_error["fixed"] or regex_error["status"] != "error":
            raise AssertionError(f"invalid regex did not reach an explicit Search error state: {regex_error}")
        self.input("l")
        self.prompt("/", "WB10_NO_MATCH_SENTINEL", "Search folder:")
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; local r=_G.wb10_store:summary(s.investigation.current.result_id); return r.status=='complete' and r.item_count==0", "complete no-match state")
        self.wait_screen("No matches")
        no_match_screen = self.grid.snapshot()["text"]
        (self.output / "no-match-screen.txt").write_text("\n".join(no_match_screen) + "\n", encoding="utf-8")

        self.phase = "debounce-cancel"
        self.prompt("/", "needle", "Search folder:")
        self.input("x")
        self.wait_lua("local s=_G.wb10_controller.active[vim.api.nvim_get_current_tabpage()]; return s.phase=='Cancelled' and s.request==nil", "cancel visible search debounce")
        self.wait_screen("State: Cancelled")
        final = self.lua("local c=_G.wb10_controller; local s=c.active[vim.api.nvim_get_current_tabpage()]; local r=_G.wb10_store:summary(s.investigation.current.result_id); return {phase=s.phase,query=s.query,history=#s.investigation.history,provider=_G.wb10_provider:status(),layout=_G.wb10_layout:status(),result=r,dirty=vim.bo[_G.wb10_dirty_buf].modified,dirty_line=vim.api.nvim_buf_get_lines(_G.wb10_dirty_buf,0,1,false)[1],cwd=vim.fn.getcwd(),cwd_expected=_G.wb10_cwd,origin=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1]}")
        if final["provider"]["active_requests"] != 0 or final["layout"]["active_views"] != 1:
            raise AssertionError(f"Search teardown/cancel retained live work: {final}")
        cancelled_grid_text = self.grid.snapshot()["text"]
        (self.output / "cancelled-screen.txt").write_text("\n".join(cancelled_grid_text) + "\n", encoding="utf-8")
        cleanup = self.lua("local c=_G.wb10_controller; c:dispose(); _G.wb10_nav:dispose(); _G.wb10_provider:dispose(); _G.wb10_store:dispose(); _G.wb10_layout:dispose(); return {controller_views=c:status().active_views,provider_requests=_G.wb10_provider:status().active_requests,layout_views=_G.wb10_layout:status().active_views,dirty=vim.bo[_G.wb10_dirty_buf].modified,origin=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1]}")
        if cleanup["controller_views"] != 0 or cleanup["provider_requests"] != 0 or cleanup["layout_views"] != 0:
            raise AssertionError(f"Search disposal retained owned UI or provider work: {cleanup}")
        if not cleanup["dirty"] or cleanup["origin"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"Search disposal damaged editor-owned buffers: {cleanup}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "view_layout": first_state["view_mode"],
            "scope": "folder:A",
            "empty_query_no_scan": True,
            "debounce_state_visible": True,
            "invalid_regex_state": {"status": regex_error["status"], "error": regex_error["error"], "visible": "Search failed" in "\n".join(error_screen)},
            "no_matches_state": {"status": "complete", "count": 0, "visible": "No matches" in "\n".join(no_match_screen)},
            "cwd_unchanged": final["cwd"] == final["cwd_expected"],
            "partial_results_visible": first_state["summary"]["status"] == "partial",
            "preview_source": first_state["preview"]["source"],
            "dirty_buffer_preserved": final["dirty"] and final["dirty_line"].startswith("USER EDITED"),
            "palette_open_buffers_enabled": palette_state["enabled"],
            "mouse_selected_visible_result_row": mouse_selection["selected"] == mouse_target["id"] and mouse_selection["focus"],
            "navigation_returned": returned["line"] == "USER MODIFIED ORIGIN",
            "search_resumed": reopened["id"] == query_id and reopened["query"] == "needle",
            "first_shell_ms": round(self.first_shell_ms or 0, 3),
            "first_result_ms": round(first_result_ms, 3),
            "final": {
                "phase": final["phase"],
                "query": final["query"],
                "history": final["history"],
                "result_status": final["result"]["status"],
                "provider_requests": final["provider"]["active_requests"],
                "active_layout_views": final["layout"]["active_views"],
                "cwd_unchanged": final["cwd"] == final["cwd_expected"],
                "dirty_buffer_preserved": final["dirty"] and final["dirty_line"].startswith("USER EDITED"),
            },
            "disposed": cleanup,
            "empty_query_screen_artifact": "empty-query-screen.txt",
            "invalid_regex_screen_artifact": "invalid-regex-screen.txt",
            "no_match_screen_artifact": "no-match-screen.txt",
            "cancelled_screen_artifact": "cancelled-screen.txt",
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
    parser.add_argument("--grid-sizes", default="120x35,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb10")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = Run(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-10 Search UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
