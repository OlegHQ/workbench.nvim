#!/usr/bin/env python3
"""Native diagnostic aggregation and Problems interaction on real Neovim grids."""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run  # noqa: E402


class ProblemsRun(Run):
    def _start(self) -> None:
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb16-problems-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.editor_cwd = base / "editor-cwd"
        root_a = self.workspace / "A"
        root_b = self.workspace / "B"
        root_a.mkdir(parents=True)
        root_b.mkdir()
        self.editor_cwd.mkdir()
        self.origin = root_a / "main.lua"
        self.target = root_b / "second.lua"
        self.origin.write_text("local broken = true\nprint(broken)\n", encoding="utf-8")
        self.target.write_text("local second = true\nprint(second)\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb16-xdg-")
        xdg_root = Path(self.xdg.name)
        for name in ("config", "data", "state", "cache"):
            (xdg_root / name).mkdir()
        import os
        import subprocess
        import threading

        environment = os.environ.copy()
        environment.update({
            "XDG_CONFIG_HOME": str(xdg_root / "config"),
            "XDG_DATA_HOME": str(xdg_root / "data"),
            "XDG_STATE_HOME": str(xdg_root / "state"),
            "XDG_CACHE_HOME": str(xdg_root / "cache"),
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
        import pynvim

        self.control = pynvim.attach("socket", path=self.socket)
        self.ui = pynvim.attach("socket", path=self.socket)
        self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
        self.control.api.set_option("mouse", "a")
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb16-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.lua(
            "local args=...; local origin,target,root_a,root_b=args[1],args[2],args[3],args[4]; "
            "vim.o.hidden=true; vim.api.nvim_cmd({cmd='edit',args={origin}},{}); "
            "_G.wb16_origin_buf=vim.api.nvim_get_current_buf(); _G.wb16_origin_win=vim.api.nvim_get_current_win(); "
            "vim.api.nvim_win_set_cursor(_G.wb16_origin_win,{2,0}); local uv=vim.uv or vim.loop; "
            "local Resource=require('workbench.core.resource'); local Workspace=require('workbench.core.workspace'); "
            "local roots={assert(Resource.from_path(assert(uv.fs_realpath(root_a)))),assert(Resource.from_path(assert(uv.fs_realpath(root_b))))}; "
            "_G.wb16_workspace=assert(Workspace.new({id=Workspace.id_for_roots(roots),generation=1,roots=roots,"
            "active_root_uri=roots[1].uri,root_origin='explicit',scope={kind='all_roots',explicit=true},"
            "policy={hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}}})); "
            "_G.wb16_layout=assert(require('workbench.ui.layout').new({min_editor_width=24,min_editor_height=6})); "
            "_G.wb16_diagnostics=assert(require('workbench.providers.diagnostics').new()); "
            "_G.wb16_navigation=assert(require('workbench.services.navigation').new()); "
            "_G.wb16_actions=require('workbench.core.actions').new(); "
            "_G.wb16_problems=assert(require('workbench.controllers.problems').new({layout=_G.wb16_layout,"
            "provider=_G.wb16_diagnostics,navigation=_G.wb16_navigation,actions=_G.wb16_actions})); "
            "_G.wb16_session=function() for _,s in pairs(_G.wb16_problems.sessions) do return s end end; "
            "_G.wb16_palette=assert(require('workbench.ui.palette').new({layout=_G.wb16_layout,actions=_G.wb16_actions,"
            "context=function() return {workspace=_G.wb16_workspace,bufnr=_G.wb16_origin_buf,win=_G.wb16_origin_win} end})); "
            "local target_buf=vim.fn.bufadd(target); vim.fn.bufload(target_buf); _G.wb16_target_buf=target_buf; "
            "_G.wb16_compiler=vim.api.nvim_create_namespace('wb16-e2e-compiler'); "
            "_G.wb16_lint=vim.api.nvim_create_namespace('wb16-e2e-lint'); "
            "vim.diagnostic.set(_G.wb16_compiler,_G.wb16_origin_buf,{{lnum=0,col=0,end_lnum=0,end_col=6,severity=1,source='compiler',code='E1',message='syntax issue'}}); "
            "vim.diagnostic.set(_G.wb16_lint,_G.wb16_origin_buf,{{lnum=1,col=0,end_lnum=1,end_col=5,severity=2,source='lint',code='W1',message='unused value'}}); "
            "vim.diagnostic.set(_G.wb16_lint,target_buf,{{lnum=1,col=3,end_lnum=1,end_col=9,severity=2,source='lint',code='B1',message='secondary warning'}}); "
            "_G.wb16_palette_key=function() _G.wb16_palette:open({focus=true}) end; "
            "vim.keymap.set('n','P',_G.wb16_palette_key,{buffer=_G.wb16_origin_buf,silent=true}); "
            "return {roots=vim.tbl_map(function(r) return r.path end,roots),diagnostics=#vim.diagnostic.get(_G.wb16_origin_buf)+#vim.diagnostic.get(target_buf)}",
            str(self.origin), str(self.target), str(self.workspace / "A"), str(self.workspace / "B"),
        )
        self.wait_screen("local broken")

    def _exercise(self) -> dict[str, Any]:
        self.phase = "open-through-shared-action-palette"
        started = time.perf_counter_ns()
        self.input("P")
        self.wait_screen("Actions · Enter runs")
        self.prompt("/", "problems.open", "Filter actions:")
        self.wait_screen("Open reported Problems")
        self.input("\r")
        self.wait_lua(
            "local s=_G.wb16_problems:status(); return s.session_count==1 and s.provider.lease_count==1",
            "Problems action opens a leased view",
        )
        self.wait_screen("Reported diagnostics only")
        open_ms = (time.perf_counter_ns() - started) / 1_000_000

        file_a = self.lua(
            "local s=_G.wb16_session(); for id,i in pairs(s.item_by_id) do "
            "if i.kind=='file' and i.payload.resource.path:match('/A/main%.lua$') then return id end end"
        )
        if not file_a:
            raise AssertionError("the originating file was not represented in Problems")
        self._move_to_row(file_a)
        self.input(" ")
        self.wait_screen("syntax issue")

        self.phase = "diagnostic-changed-incremental-render"
        changed_start = time.perf_counter_ns()
        self.lua(
            "vim.diagnostic.set(_G.wb16_lint,_G.wb16_origin_buf,{{lnum=1,col=0,end_lnum=1,end_col=5,"
            "severity=2,source='lint',code='W1',message='unused value refreshed'}})"
        )
        self.wait_lua(
            "local s=_G.wb16_session(); return s and s.root_counts[_G.wb16_workspace.roots[1].uri].error==1 "
            "and s.root_counts[_G.wb16_workspace.roots[1].uri].warning==1 and s.item_by_id and "
            "(function() for _,i in pairs(s.item_by_id) do if i.kind=='diagnostic' and i.label:find('unused value refreshed',1,true) then return true end end return false end)()",
            "changed native diagnostics update the view while retaining sibling namespace errors",
        )
        self.grid.wait_for(lambda: any("unused value r" in line for line in self.grid.lines()), 5, "updated diagnostic rendered in grid")
        changed_ms = (time.perf_counter_ns() - changed_start) / 1_000_000

        self.phase = "severity-and-source-filters"
        view_window = self.lua("local s=_G.wb16_session(); return s.view.window")
        self.control.api.set_current_win(view_window)
        filter_start = time.perf_counter_ns()
        self.input("2")
        self.wait_lua(
            "local s=_G.wb16_session(); return s.filters.severity==2 "
            "and (function() local n=0; for _,i in pairs(s.item_by_id) do if i.kind=='diagnostic' then n=n+1; if i.payload.severity~='warning' then return false end end end return n==2 end)()",
            "warning-only severity filter",
        )
        self.wait_screen("severity warning")
        self.prompt("f", "lint", "Diagnostic source")
        self.wait_lua(
            "local s=_G.wb16_session(); return s.filters.source=='lint' "
            "and (function() local n=0; for _,i in pairs(s.item_by_id) do if i.kind=='diagnostic' then n=n+1; if i.payload.source~='lint' then return false end end end return n==2 end)()",
            "exact source filter",
        )
        self.grid.wait_for(lambda: any("unused value r" in line for line in self.grid.lines()), 5, "source-filtered diagnostic remains rendered")
        filter_ms = (time.perf_counter_ns() - filter_start) / 1_000_000

        self.phase = "root-cycle-filter"
        self.input("r")
        self.wait_lua(
            "local s=_G.wb16_session(); return s.filters.root_uri==_G.wb16_workspace.roots[1].uri "
            "and (function() for _,i in pairs(s.item_by_id) do if i.kind=='diagnostic' then return i.location.resource.path:match('/A/')~=nil end end return false end)()",
            "first workspace-root filter",
        )
        self.input("r")
        self.wait_lua(
            "local s=_G.wb16_session(); return s.filters.root_uri==_G.wb16_workspace.roots[2].uri "
            "and (function() for _,i in pairs(s.item_by_id) do if i.kind=='diagnostic' then return i.location.resource.path:match('/B/')~=nil end end return false end)()",
            "second workspace-root filter",
        )
        file_b = self.lua(
            "local s=_G.wb16_session(); for id,i in pairs(s.item_by_id) do "
            "if i.kind=='file' and i.payload.resource.path:match('/B/second%.lua$') then return id end end"
        )
        if not file_b:
            raise AssertionError("the second-root file was not represented in Problems")
        self._move_to_row(file_b)
        self.input(" ")
        self.wait_screen("secondary")

        self.phase = "diagnostic-navigation-and-return"
        self.input("C")
        self.wait_lua(
            "local s=_G.wb16_session(); return not s.filters.severity and not s.filters.source and not s.filters.root_uri",
            "clear all Problems filters",
        )
        target_id = self.lua(
            "local s=_G.wb16_session(); for id,i in pairs(s.item_by_id) do "
            "if i.kind=='diagnostic' and i.payload.code=='B1' then return id end end"
        )
        self._move_to_row(target_id)
        self.input("\r")
        self.wait_lua(
            "return vim.api.nvim_get_current_win()==_G.wb16_origin_win and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match('second%.lua$')~=nil",
            "open the selected native diagnostic location",
        )
        opened = self.lua(
            "return {path=vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()),line=vim.api.nvim_win_get_cursor(0)[1],"
            "column=vim.api.nvim_win_get_cursor(0)[2],origin=_G.wb16_origin_buf,target=_G.wb16_target_buf}"
        )
        if opened["line"] != 2 or opened["column"] != 3:
            raise AssertionError(f"diagnostic navigation did not target its reported location: {opened}")
        self.input("\x17p")
        self.wait_lua("return vim.api.nvim_get_current_win()==" + str(view_window), "return focus to Problems after navigation")
        self.input("R")
        self.wait_lua(
            "return vim.api.nvim_get_current_win()==_G.wb16_origin_win and vim.api.nvim_get_current_buf()==_G.wb16_origin_buf "
            "and vim.api.nvim_win_get_cursor(_G.wb16_origin_win)[1]==2",
            "return to the captured origin location",
        )

        self.phase = "retained-projection-after-reopen"
        self.lua(
            "_G.wb16_bulk=vim.api.nvim_create_namespace('wb16-bulk'); local items={}; "
            "for i=1,100 do items[i]={lnum=0,col=0,severity=2,source='bulk',message=string.format('bulk %03d',i)} end; "
            "vim.diagnostic.set(_G.wb16_bulk,_G.wb16_origin_buf,items)"
        )
        self.input("\x17p")
        self.wait_lua("return vim.api.nvim_get_current_win()==" + str(view_window), "refocus Problems to close")
        self.input("2")
        self.prompt("f", "bulk", "Diagnostic source")
        self.wait_lua("local s=_G.wb16_session(); return s.filters.source=='bulk' and #s.view.rows>100", "long filtered diagnostic projection")
        self.input("j" * 69)
        self.wait_lua("return _G.wb16_session().view.scroll_offset>0", "manual Problems scrolling")
        self.lua(
            "local s=_G.wb16_session(); local v=s.view; _G.wb16_saved={buffer=v.buffer,selected=v.selected_id,"
            "scroll=v.scroll_offset,expanded=vim.deepcopy(v.expanded),filters=vim.deepcopy(s.filters),"
            "lines=vim.api.nvim_buf_get_lines(v.buffer,0,-1,false)}"
        )
        self.input("q")
        self.wait_lua("return _G.wb16_diagnostics:status().lease_count==0", "closed retained Problems releases lease")
        self.input(":lua assert(_G.wb16_problems:open(_G.wb16_workspace))\r")
        self.wait_lua(
            "local s=_G.wb16_session(); local v=s.view; local old=_G.wb16_saved; return v and v.buffer~=old.buffer "
            "and v.selected_id==old.selected and v.scroll_offset==old.scroll "
            "and vim.deep_equal(v.expanded,old.expanded) and vim.deep_equal(s.filters,old.filters) "
            "and vim.deep_equal(vim.api.nvim_buf_get_lines(v.buffer,0,-1,false),old.lines)",
            "fresh Problems view restores the retained projection",
        )
        self.wait_screen("bulk")
        (self.output / "problems-reopened-grid.json").write_text(json.dumps(self.grid.snapshot(), indent=2) + "\n", encoding="utf-8")
        self.lua("vim.diagnostic.reset(_G.wb16_bulk,_G.wb16_origin_buf)")
        self.input("C")
        self.phase = "lease-and-editor-diagnostic-cleanup"
        self.input("q")
        self.wait_lua(
            "local s=_G.wb16_problems:status(); return s.provider.lease_count==0 and s.provider.hook_count==0 "
            "and s.sessions[1] and not s.sessions[1].mounted",
            "closing Problems releases its listeners",
        )
        final = self.lua(
            "return {coverage=_G.wb16_problems:status().sessions[1].coverage,remaining_diagnostics=#vim.diagnostic.get(_G.wb16_origin_buf)+"
            "#vim.diagnostic.get(_G.wb16_target_buf),provider=_G.wb16_diagnostics:status(),problem=_G.wb16_problems:status(),"
            "origin=vim.api.nvim_get_current_buf()==_G.wb16_origin_buf}"
        )
        if final["coverage"] != "reported-only" or final["remaining_diagnostics"] != 3 or final["provider"]["lease_count"] != 0 or not final["origin"]:
            raise AssertionError(f"closing Problems altered native state or retained listeners: {final}")
        before_dispose = self.grid.snapshot()
        (self.output / "problems-closed-grid.json").write_text(json.dumps(before_dispose, indent=2) + "\n", encoding="utf-8")
        self.lua(
            "_G.wb16_palette:dispose(); _G.wb16_problems:dispose(); _G.wb16_diagnostics:dispose(); "
            "_G.wb16_navigation:dispose(); _G.wb16_layout:dispose(); vim.diagnostic.reset(nil,_G.wb16_origin_buf); "
            "vim.diagnostic.reset(nil,_G.wb16_target_buf)"
        )
        return {
            "grid": f"{self.cols}x{self.rows}",
            "coverage": final["coverage"],
            "native_diagnostics_preserved_after_close": final["remaining_diagnostics"] == 3,
            "filters": ["severity", "source", "root"],
            "navigated_to": {"path": opened["path"], "line": opened["line"], "column": opened["column"]},
            "returned_to_origin": final["origin"],
            "retained_projection_after_reopen": True,
            "timings_ms": {"action_to_view": round(open_ms, 3), "diagnostic_changed_to_render": round(changed_ms, 3), "severity_and_source_filters": round(filter_ms, 3)},
            "closed_provider": {"leases": final["provider"]["lease_count"], "hooks": final["provider"]["hook_count"]},
            "artifact": "problems-closed-grid.json",
        }

    def _move_to_row(self, item_id: str) -> None:
        state = self.lua(
            "local s=_G.wb16_session(); local target,current; "
            "for index,row in ipairs(s.view.rows) do if row.id==" + json.dumps(item_id) + " then target=index end; "
            "if row.id==s.view.selected_id then current=index end end; return {target=target,current=current,selected=s.view.selected_id}"
        )
        if not state["target"]:
            raise AssertionError(f"Problems item is not visible in the current tree: {item_id} ({state})")
        distance = state["target"] - (state["current"] or 1)
        if distance:
            self.input(("j" if distance > 0 else "k") * abs(distance))
            self.wait_lua(
                "local s=_G.wb16_session(); return s.view.selected_id==" + json.dumps(item_id),
                f"move to Problems row {item_id}",
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb16")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = ProblemsRun(args.nvim, cols, rows, output)
        try:
            print(json.dumps({"artifacts": str(output), **run.run()}, indent=2))
        except Exception as error:
            print(f"WB-16 Problems UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
