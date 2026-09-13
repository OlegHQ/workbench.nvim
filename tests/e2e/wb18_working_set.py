#!/usr/bin/env python3
"""Working-set search, buffer navigation and UI acceptance on real Neovim grids."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import statistics
import subprocess
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


class WorkingSetRun(Run):
    def __init__(self, nvim: str, cols: int, rows: int, output: Path, normal_fixture: bool = False):
        super().__init__(nvim, cols, rows, output)
        self.normal_fixture = normal_fixture
        self.fixture_file_count = 0
        self.samples_per_mode = 20 if normal_fixture else 3

    def _start(self) -> None:
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="w18-", dir="/tmp")
        base = Path(self.fixture.name)
        if self.normal_fixture:
            from bench.fixtures import make_fixture

            metadata = make_fixture("normal", base / "normal", 20260912)
            self.workspace = Path(str(metadata["workspace"]))
            self.fixture_file_count = int(metadata["files"])
            (self.workspace / "inaccessible").chmod(0o700)
            hot_match = self.workspace / "files" / "batch-0000" / "file-000002.txt"
            with hot_match.open("a", encoding="utf-8") as benchmark_file:
                benchmark_file.write("needle early benchmark match\n")
        else:
            self.workspace = base / "workspace"
            self.workspace.mkdir()
        self.editor_cwd = base / "editor-cwd"
        self.editor_cwd.mkdir()
        self.origin = self.workspace / "origin.txt"
        self.open_file = self.workspace / "open.txt"
        self.removed_file = self.workspace / "removed.txt"
        self.ignored_file = self.workspace / "ignored.txt"
        self.saved_file = self.workspace / "saved.txt"
        self.external_file = base / "outside.txt"
        self.origin.write_text("origin line one\norigin line two\n", encoding="utf-8")
        self.open_file.write_text("disk needle must be replaced by buffer text\n", encoding="utf-8")
        self.removed_file.write_text("disk needle removed in memory\n", encoding="utf-8")
        ignore_file = self.workspace / ".gitignore"
        ignore_rules = ignore_file.read_text(encoding="utf-8") if ignore_file.exists() else ""
        if "ignored.txt" not in ignore_rules.splitlines():
            ignore_file.write_text(ignore_rules + ("" if not ignore_rules or ignore_rules.endswith("\n") else "\n") + "ignored.txt\n", encoding="utf-8")
        self.ignored_file.write_text("disk needle ignored\n", encoding="utf-8")
        self.saved_file.write_text("old saved buffer content\n", encoding="utf-8")
        self.external_file.write_text("external old content\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb18-xdg-")
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
        import pynvim
        import threading

        self.control = pynvim.attach("socket", path=self.socket)
        self.ui = pynvim.attach("socket", path=self.socket)
        self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
        self.control.api.set_option("mouse", "a")
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb18-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        setup_start = time.perf_counter_ns()
        state = self.lua(
            "local args=...; local origin,workspace,open_path,removed_path,ignored_path,saved_path,external_path=args[1],args[2],args[3],args[4],args[5],args[6],args[7]; "
            "vim.o.hidden=true; vim.api.nvim_cmd({cmd='cd',args={vim.fn.fnamemodify(origin,':h')}},{}); "
            "vim.api.nvim_cmd({cmd='edit',args={origin}},{}); _G.wb18_origin_buf=vim.api.nvim_get_current_buf(); _G.wb18_origin_win=vim.api.nvim_get_current_win(); "
            "local Workspace=require('workbench.services.workspace'); _G.wb18_workspace=assert(Workspace.new({"
            "root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},"
            "ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=workspace}); "
            "local function named(path,lines,modified,listed) local b=vim.fn.bufadd(path); vim.fn.bufload(b); if lines then vim.api.nvim_buf_set_lines(b,0,-1,false,lines) end; "
            "vim.bo[b].modified=modified; if listed==false then vim.bo[b].buflisted=false end; return b end; "
            "_G.wb18_open=named(open_path,{'memory needle from open buffer'},true); "
            "_G.wb18_removed=named(removed_path,{'memory has no target'},true); "
            "_G.wb18_ignored=named(ignored_path,{'needle visible only in open buffers'},true); "
            "_G.wb18_saved=named(saved_path,nil,false); vim.fn.writefile({'needle from an external disk change'},saved_path); "
            "_G.wb18_external=named(external_path,{'needle from outside the workspace'},false,false); "
            "_G.wb18_unnamed=vim.api.nvim_create_buf(false,false); vim.bo[_G.wb18_unnamed].bufhidden='hide'; vim.api.nvim_buf_set_lines(_G.wb18_unnamed,0,-1,false,{'needle unnamed must be excluded'}); "
            "_G.wb18_special=vim.api.nvim_create_buf(false,true); vim.bo[_G.wb18_special].bufhidden='hide'; vim.bo[_G.wb18_special].buftype='nofile'; vim.api.nvim_buf_set_lines(_G.wb18_special,0,-1,false,{'needle special must be excluded'}); "
            "_G.wb18_layout=assert(require('workbench.ui.layout').new({min_editor_width=24,min_editor_height=6,results_height=8})); "
            "_G.wb18_rg=assert(require('workbench.providers.rg').new()); _G.wb18_store=assert(require('workbench.services.results').new()); "
            "_G.wb18_nav=assert(require('workbench.services.navigation').new()); _G.wb18_actions=require('workbench.core.actions').new(); "
            "_G.wb18_metrics={requests={}}; local rg_start=_G.wb18_rg.start; function _G.wb18_rg:start(request,sink) "
            "local lane=request.enumerate_files and 'eligibility' or request.session_id:match(':overlay$') and 'overlay' or 'disk'; "
            "local record={lane=lane,session_id=request.session_id,started=(vim.uv or vim.loop).hrtime()}; table.insert(_G.wb18_metrics.requests,record); "
            "return rg_start(self,request,function(event) local now=(vim.uv or vim.loop).hrtime(); if event.kind=='batch' and not record.first_batch_ms then record.first_batch_ms=(now-record.started)/1000000 end; "
            "if event.kind=='done' or event.kind=='error' then record.duration_ms=(now-record.started)/1000000; record.status=event.status end; return sink(event) end) end; "
            "_G.wb18_search=assert(require('workbench.controllers.search').new({layout=_G.wb18_layout,provider=_G.wb18_rg,store=_G.wb18_store,"
            "navigation=_G.wb18_nav,actions=_G.wb18_actions,workspace=_G.wb18_workspace,debounce_ms=" + ("0" if self.normal_fixture else "80") + ","
            "buffer_list_factory=function(deps) return require('workbench.controllers.buffers').new(deps) end})); "
            "_G.wb18_view=assert(_G.wb18_search:open({workspace=_G.wb18_workspace,focus=true})); _G.wb18_cwd=vim.fn.getcwd(); "
            "return {cwd=_G.wb18_cwd,modified={vim.bo[_G.wb18_open].modified,vim.bo[_G.wb18_removed].modified,vim.bo[_G.wb18_ignored].modified},"
            "saved_memory=vim.api.nvim_buf_get_lines(_G.wb18_saved,0,1,false)[1],external_listed=vim.bo[_G.wb18_external].buflisted}",
            str(self.origin), str(self.workspace), str(self.open_file), str(self.removed_file), str(self.ignored_file), str(self.saved_file), str(self.external_file),
        )
        self.first_shell_ms = (time.perf_counter_ns() - setup_start) / 1_000_000
        self.wait_screen("Query: (empty query)")
        self.wait_screen("Enter / to search the selected scope")
        (self.output / "empty-search-screen.txt").write_text("\n".join(self.grid.snapshot()["text"]) + "\n", encoding="utf-8")
        if state["saved_memory"] != "old saved buffer content" or state["external_listed"]:
            raise AssertionError(f"fixture did not retain the intended loaded-buffer state: {state}")

    def _wait_search(self, previous_id: str | None, description: str, timeout: float = 8.0) -> dict[str, Any]:
        self.wait_lua(
            "local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; "
            "local r=e and _G.wb18_store:summary(e.result_id); return r and r.status~='running' and e.result_id~=" + json.dumps(previous_id),
            description,
            timeout,
        )
        return self.lua(
            "local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; local summary=_G.wb18_store:summary(e.result_id); "
            "local found={}; for _,item in ipairs(_G.wb18_store:page(e.result_id,0,200).items) do local name=vim.fs.basename(item.location.resource.path); "
            "found[name]=found[name] or {}; table.insert(found[name],{raw_line=item.payload.raw_line,source=item.payload.source_snapshot,uri=item.location.resource.uri,path=item.location.resource.path,id=item.id}) end; "
            "local r=_G.wb18_rg:status(); return {id=e.result_id,status=summary.status,count=summary.item_count,query=s.query,scope=s.scope.kind,found=found,header=s.view.model.header,phase=s.phase,"
            "requests=#_G.wb18_metrics.requests,active_requests=r.active_requests,cwd=vim.fn.getcwd(),modified={vim.bo[_G.wb18_open].modified,vim.bo[_G.wb18_removed].modified,vim.bo[_G.wb18_ignored].modified},"
            "open_text=vim.api.nvim_buf_get_lines(_G.wb18_open,0,-1,false),removed_text=vim.api.nvim_buf_get_lines(_G.wb18_removed,0,-1,false),ignored_text=vim.api.nvim_buf_get_lines(_G.wb18_ignored,0,-1,false)}"
        )

    def _measure(self, mode: str, initial: bool = False) -> dict[str, Any]:
        assert self.control is not None
        previous = self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; return s.investigation.current and s.investigation.current.result_id")
        request_before = self.lua("return #_G.wb18_metrics.requests")
        flush_before = self.grid.flushes
        started = time.perf_counter_ns()
        if initial:
            self.input("/")
            self.wait_screen("Search workspace:")
            self.input("\x15needle\r")
        elif mode == "open_buffers" and self.lua("return _G.wb18_search.active[vim.api.nvim_get_current_tabpage()].scope.kind~='open_buffers'"):
            self.input("B")
        else:
            self.input("r")
        visible_names = ("file-000002.txt", "open.txt", "removed.txt", "saved.txt") if self.normal_fixture and mode == "workspace_disk" else ("open.txt",)
        self.wait_lua(
            "local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; "
            "local r=e and _G.wb18_store:summary(e.result_id); return r and e.result_id~=" + json.dumps(previous) + " and r.item_count>0",
            f"{mode} first result batch reaches the Search model",
        )
        self.grid.wait_for(lambda: self.grid.flushes > flush_before, 5, f"{mode} first result frame is painted")
        self.grid.wait_for(lambda: any(name in line for name in visible_names for line in self.grid.lines()), 5, f"{mode} first result is visible in the Neovim grid")
        first_render_ms = (time.perf_counter_ns() - started) / 1_000_000
        state = self._wait_search(previous, f"{mode} search reaches a terminal state")
        self.grid.wait_for(lambda: self.grid.flushes > flush_before, 5, f"{mode} results render in the Neovim grid")
        elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
        state["header"] = self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; return vim.deepcopy(s.view.model.header)")
        metrics = self.lua("local r={}; for i=" + str(request_before + 1) + ",#_G.wb18_metrics.requests do r[#r+1]=vim.deepcopy(_G.wb18_metrics.requests[i]) end; return r")
        state["latency_ms"] = round(elapsed_ms, 3)
        state["first_render_ms"] = round(first_render_ms, 3)
        state["request_count"] = len(metrics)
        state["lanes"] = [item["lane"] for item in metrics]
        state["provider_ms"] = [round(float(item.get("duration_ms", 0)), 3) for item in metrics]
        state["provider_first_batch_ms"] = [round(float(item.get("first_batch_ms", 0)), 3) for item in metrics]
        state["first_batch_ms"] = round(min((item["first_batch_ms"] for item in metrics if item.get("first_batch_ms") is not None), default=0), 3)
        state["provider_statuses"] = [item.get("status") for item in metrics]
        return state

    def _exercise(self) -> dict[str, Any]:
        self.phase = "workspace-dirty-search"
        dirty_samples = [self._measure("workspace_dirty", initial=True)]
        if dirty_samples[0]["status"] != "complete" or dirty_samples[0]["request_count"] != 3:
            raise AssertionError(f"dirty workspace search did not finish with the three bounded aggregate scans: {dirty_samples[0]}")
        found = dirty_samples[0]["found"]
        expected_dirty = {"open.txt", "saved.txt"}
        expected_disk = {"open.txt", "removed.txt", "saved.txt"}
        if self.normal_fixture:
            expected_dirty.add("file-000002.txt")
            expected_disk.add("file-000002.txt")
        if set(found) != expected_dirty:
            raise AssertionError(f"dirty overlay did not replace disk results or respect ignore scope: {found}")
        if not found["open.txt"][0]["source"] or found["open.txt"][0]["raw_line"] != "memory needle from open buffer":
            raise AssertionError(f"dirty search did not identify the exact in-memory source snapshot: {found['open.txt']}")
        if found["saved.txt"][0].get("source") or found["saved.txt"][0]["raw_line"] != "needle from an external disk change":
            raise AssertionError(f"external disk changes were not searched for a clean loaded buffer: {found['saved.txt']}")
        if not any("Scope: workspace" in line for line in dirty_samples[0]["header"]):
            raise AssertionError(f"workspace scope is not visible: {dirty_samples[0]['header']}")
        if not any("disk plus 3 modified buffer snapshots" in line for line in dirty_samples[0]["header"]):
            raise AssertionError(f"disk and dirty snapshot sources are not distinguished: {dirty_samples[0]['header']}")
        for _ in range(self.samples_per_mode - 1):
            dirty_samples.append(self._measure("workspace_dirty"))
            if dirty_samples[-1]["request_count"] != 3:
                raise AssertionError(f"dirty-buffer process count grew with query repetition: {dirty_samples[-1]}")
        dirty_screen = self.grid.snapshot()
        (self.output / "workspace-dirty-grid.json").write_text(json.dumps(dirty_screen, indent=2, default=str) + "\n", encoding="utf-8")

        self.phase = "search-result-buffer-navigation"
        self.lua(
            "local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
            "for _,item in ipairs(_G.wb18_store:page(e.result_id,0,200).items) do if vim.fs.basename(item.location.resource.path)=='open.txt' then s.selected_id=item.id; break end end; "
            "vim.api.nvim_set_current_win(s.view.window)"
        )
        self.input("o")
        self.wait_lua("return _G.wb18_nav:status().navigation_entries==1 and vim.api.nvim_get_current_buf()==_G.wb18_open", "open the captured unsaved buffer result")
        opened = self.lua("return {buffer=vim.api.nvim_get_current_buf(),line=vim.api.nvim_get_current_line(),modified=vim.bo[_G.wb18_open].modified}")
        if opened["line"] != "memory needle from open buffer" or not opened["modified"]:
            raise AssertionError(f"opening a buffer result did not preserve the exact source buffer: {opened}")
        self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("R")
        self.wait_lua("return vim.api.nvim_get_current_buf()==_G.wb18_origin_buf", "return from buffer result to the captured editor origin")

        self.phase = "open-recent-buffer-view"
        self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("P")
        self.wait_screen("Actions · Enter")
        self.prompt("/", "buffers.list", "Filter actions:")
        self.wait_lua("local p=_G.wb18_search.palette.active[vim.api.nvim_get_current_tabpage()]; return p and p.by_id['buffers.list'] and p.by_id['buffers.list'].available.enabled", "find the available buffer-list palette action")
        palette_selection = self.lua(
            "local p=_G.wb18_search.palette.active[vim.api.nvim_get_current_tabpage()]; p.view:_sync_selection(); "
            "return {selected=p.view.selected_id,filter=p.filter,mode=vim.api.nvim_get_mode().mode}"
        )
        if palette_selection["selected"] != "buffers.list" or palette_selection["mode"] != "n":
            raise AssertionError(f"action palette did not settle on the filtered buffer-list action: {palette_selection}")
        self.input("\r")
        self.wait_lua(
            "local tab=vim.api.nvim_get_current_tabpage(); local p=_G.wb18_search.palette.active[tab]; "
            "return not p and _G.wb18_search.buffer_controller:status().session_count==1",
            "execute the buffer-list palette action and close its filter prompt",
        )
        self.wait_screen("Open and recent buffers")
        listed = self.lua(
            "local c=_G.wb18_search.buffer_controller; local tab=vim.api.nvim_get_current_tabpage(); local s=c.sessions[tab]; "
            "local target; for _,row in ipairs(s.view.rows) do if row.payload and row.payload.bufnr==_G.wb18_open then target={id=row.id,bufnr=row.payload.bufnr,detail=row.detail,label=row.label} end end; "
            "if target then s.view.selected_id=target.id end; return {target=target,count=s.snapshot.total,unnamed=s.snapshot.excluded.unnamed,special=s.snapshot.excluded.special}"
        )
        if not listed["target"] or listed["count"] < 5:
            raise AssertionError(f"recent buffer view omitted loaded named buffers or included invalid buffers: {listed}")
        if listed["unnamed"] < 1 or listed["special"] < 1:
            raise AssertionError(f"working-set snapshot did not report the loaded unnamed/special exclusions: {listed}")
        self.input("\r")
        self.wait_lua("return vim.api.nvim_get_current_buf()==_G.wb18_open", "open selected buffer from the recent list")
        self.lua("local s=_G.wb18_search.buffer_controller.sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("q")
        self.wait_lua(
            "local tab=vim.api.nvim_get_current_tabpage(); local s=_G.wb18_search.active[tab]; "
            "return _G.wb18_search.buffer_controller:status().session_count==0 and s and s.view and not s.view.closed",
            "close the recent-buffer view and dispose its navigation history",
        )

        self.phase = "disk-only-control"
        self.lua("vim.bo[_G.wb18_open].modified=false; vim.bo[_G.wb18_removed].modified=false; vim.bo[_G.wb18_ignored].modified=false")
        self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        disk_samples = [self._measure("workspace_disk")]
        if disk_samples[0]["request_count"] != 1 or set(disk_samples[0]["found"]) != expected_disk:
            raise AssertionError(f"disk-only control did not use the real saved tree: {disk_samples[0]}")
        for _ in range(self.samples_per_mode - 1):
            disk_samples.append(self._measure("workspace_disk"))
            if disk_samples[-1]["request_count"] != 1:
                raise AssertionError(f"clean workspace search started extra processes: {disk_samples[-1]}")
        self.lua("vim.bo[_G.wb18_open].modified=true; vim.bo[_G.wb18_removed].modified=true; vim.bo[_G.wb18_ignored].modified=true")

        self.phase = "explicit-open-buffer-search"
        self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        open_samples = [self._measure("open_buffers")]
        if open_samples[0]["scope"] != "open_buffers" or open_samples[0]["request_count"] != 1:
            raise AssertionError(f"explicit open-buffer search had the wrong scope or process count: {open_samples[0]}")
        found = open_samples[0]["found"]
        if set(found) != {"open.txt", "ignored.txt", "outside.txt"}:
            raise AssertionError(f"open-buffer scope did not use all named in-memory files or included scratch buffers: {found}")
        if not any("in-memory text of" in line for line in open_samples[0]["header"]):
            raise AssertionError(f"open-buffer scope did not describe its source set: {open_samples[0]['header']}")
        for _ in range(self.samples_per_mode - 1):
            open_samples.append(self._measure("open_buffers"))
            if open_samples[-1]["request_count"] != 1:
                raise AssertionError(f"open-buffer search started per-buffer processes: {open_samples[-1]}")
        open_screen = self.grid.snapshot()
        (self.output / "open-buffers-grid.json").write_text(json.dumps(open_screen, indent=2, default=str) + "\n", encoding="utf-8")

        self.phase = "search-and-resource-cleanup"
        final = self.lua(
            "local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; return {provider=_G.wb18_rg:status(),layout=_G.wb18_layout:status(),"
            "cwd=vim.fn.getcwd(),cwd_expected=_G.wb18_cwd,open=vim.api.nvim_buf_get_lines(_G.wb18_open,0,-1,false),"
            "removed=vim.api.nvim_buf_get_lines(_G.wb18_removed,0,-1,false),ignored=vim.api.nvim_buf_get_lines(_G.wb18_ignored,0,-1,false),"
            "modified={vim.bo[_G.wb18_open].modified,vim.bo[_G.wb18_removed].modified,vim.bo[_G.wb18_ignored].modified},active_scope=s.scope.kind}"
        )
        if final["provider"]["active_requests"] != 0 or final["cwd"] != final["cwd_expected"] or not all(final["modified"]):
            raise AssertionError(f"search altered editor state or retained provider jobs: {final}")
        self.lua("local s=_G.wb18_search.active[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("q")
        self.wait_lua("return _G.wb18_search:status().active_views==0 and _G.wb18_rg:status().active_requests==0", "close Search and release all owned scans")
        cleanup = self.lua(
            "local c=_G.wb18_search; c:dispose(); _G.wb18_nav:dispose(); _G.wb18_rg:dispose(); _G.wb18_store:dispose(); _G.wb18_layout:dispose(); "
            "return {views=c:status().active_views,provider=_G.wb18_rg:status().active_requests,layout=_G.wb18_layout:status().active_views,"
            "buffers=_G.wb18_search.buffer_controller:status().session_count,open=vim.api.nvim_buf_get_lines(_G.wb18_open,0,-1,false),"
            "modified=vim.bo[_G.wb18_open].modified,origin=vim.api.nvim_buf_get_name(_G.wb18_origin_buf)}"
        )
        if cleanup["views"] or cleanup["provider"] or cleanup["layout"] or cleanup["buffers"] or not cleanup["modified"]:
            raise AssertionError(f"Search/working-set teardown retained resources or damaged the user buffer: {cleanup}")

        def summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
            values = sorted(item["latency_ms"] for item in samples)
            first_render = sorted(item["first_render_ms"] for item in samples)
            first_batch = sorted(item["first_batch_ms"] for item in samples)
            p95_index = max(0, (95 * len(values) + 99) // 100 - 1)
            return {
                "samples": len(values),
                "latency_ms": values,
                "p50_ms": round(statistics.median(values), 3),
                "p95_nearest_rank_ms": round(values[p95_index], 3),
                "first_render_ms": first_render,
                "first_render_p50_ms": round(statistics.median(first_render), 3),
                "first_render_p95_nearest_rank_ms": round(first_render[p95_index], 3),
                "first_batch_ms": first_batch,
                "first_batch_p50_ms": round(statistics.median(first_batch), 3),
                "first_batch_p95_nearest_rank_ms": round(first_batch[p95_index], 3),
                "max_requests_per_query": max(item["request_count"] for item in samples),
                "mean_provider_ms": round(statistics.mean(sum(item["provider_ms"]) for item in samples), 3),
            }

        result = {
            "grid": f"{self.cols}x{self.rows}",
            "fixture": "normal-10000-files" if self.normal_fixture else "working-set-small",
            "fixture_generated_files": self.fixture_file_count,
            "first_shell_ms": round(self.first_shell_ms or 0, 3),
            "dirty_workspace": summary(dirty_samples),
            "disk_only_control": summary(disk_samples),
            "open_buffers": summary(open_samples),
            "dirty_scope_sources": sorted(dirty_samples[0]["found"]),
            "open_buffer_sources": sorted(open_samples[0]["found"]),
            "external_disk_change_used": open_samples[0]["found"].get("saved.txt") is None,
            "ignored_buffer_is_explicitly_searchable": "ignored.txt" in open_samples[0]["found"],
            "unnamed_and_special_buffers_excluded": listed["unnamed"] > 0 and listed["special"] > 0,
            "buffer_result_navigation": opened["buffer"] == listed.get("target", {}).get("bufnr", opened["buffer"]),
            "return_to_origin": True,
            "cwd_unchanged": final["cwd"] == final["cwd_expected"],
            "modified_buffers_preserved": all(final["modified"]) and cleanup["open"] == final["open"],
            "cleanup": cleanup,
            "artifacts": ["empty-search-screen.txt", "workspace-dirty-grid.json", "open-buffers-grid.json"],
        }
        for name, screen in (("workspace-dirty-screen.txt", dirty_screen["text"]), ("open-buffers-screen.txt", open_screen["text"])):
            (self.output / name).write_text("\n".join(screen) + "\n", encoding="utf-8")
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb18")
    parser.add_argument("--normal-fixture", action="store_true", help="exercise the generated warm 10,000-file workspace fixture")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = WorkingSetRun(args.nvim, cols, rows, output, normal_fixture=args.normal_fixture)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-18 working-set UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
