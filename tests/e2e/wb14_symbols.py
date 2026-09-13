#!/usr/bin/env python3
"""Real Pyright and RPC-grid acceptance for semantic reference navigation."""

from __future__ import annotations

import json
import os
import argparse
import secrets
import shutil
import sys
import tempfile
import time
import traceback
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run as SearchRun  # noqa: E402


class SymbolsRun(SearchRun):
    def _start(self) -> None:
        self.output.mkdir(parents=True, exist_ok=False)
        pyright = shutil.which("pyright-langserver")
        if not pyright:
            raise RuntimeError("WB-14 real-server gate requires pyright-langserver on PATH")
        self.fixture = tempfile.TemporaryDirectory(prefix="wb14-symbols-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.workspace.mkdir()
        self.editor_cwd = base / "editor-cwd"
        self.editor_cwd.mkdir()
        self.origin = self.workspace / "main.py"
        self.target = self.origin
        self.helper = self.workspace / "helpers.py"
        self.origin.write_text(
            "from helpers import target_fn\n\n"
            "target_fn()\n"
            "print('search-retained')\n",
            encoding="utf-8",
        )
        self.helper.write_text("def target_fn() -> int:\n    return 7\n", encoding="utf-8")
        self.xdg = tempfile.TemporaryDirectory(prefix="wb14-xdg-")
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
        import subprocess

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
        import threading

        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb14-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        setup = self.lua(
            "local args=...; local pyright,path,workspace=args[1],args[2],args[3]; vim.o.hidden=true; "
            "vim.api.nvim_cmd({cmd='edit',args={path}},{}); _G.wb14_origin_buf=vim.api.nvim_get_current_buf(); "
            "_G.wb14_origin_win=vim.api.nvim_get_current_win(); vim.api.nvim_win_set_cursor(0,{1,0}); "
            "local ws=assert(require('workbench.services.workspace').new({"
            "root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},"
            "ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=workspace}); "
            "_G.wb14_workspace=ws; _G.wb14_layout=assert(require('workbench.ui.layout').new({min_editor_width=24,min_editor_height=6,results_height=12})); "
            "_G.wb14_store=assert(require('workbench.services.results').new()); _G.wb14_nav=assert(require('workbench.services.navigation').new()); "
            "_G.wb14_actions=require('workbench.core.actions').new(); _G.wb14_rg=assert(require('workbench.providers.rg').new({max_items=64,max_batch_items=16})); "
            "_G.wb14_lsp=assert(require('workbench.providers.lsp').new({request_timeout_ms=30000})); "
            "_G.wb14_request_metrics={rg_starts=0,lsp_methods={},lsp_requests={}}; "
            "local rg_start=_G.wb14_rg.start; function _G.wb14_rg:start(request,sink) _G.wb14_request_metrics.rg_starts=_G.wb14_request_metrics.rg_starts+1; return rg_start(self,request,sink) end; "
            "local lsp_start=_G.wb14_lsp.start; function _G.wb14_lsp:start(request,sink) local method=request.method; "
            "_G.wb14_request_metrics.lsp_methods[method]=(_G.wb14_request_metrics.lsp_methods[method] or 0)+1; "
            "local record={method=method,started=vim.uv.hrtime()}; table.insert(_G.wb14_request_metrics.lsp_requests,record); "
            "return lsp_start(self,request,function(event) if event.kind=='done' then record.duration_ms=(vim.uv.hrtime()-record.started)/1000000 end; sink(event) end) end; "
            "_G.wb14_client=assert(vim.lsp.start({name='workbench-wb14-pyright',cmd={pyright,'--stdio'},root_dir=ws.roots[1].path,"
            "capabilities=vim.lsp.protocol.make_client_capabilities()},{bufnr=_G.wb14_origin_buf})); "
            "_G.wb14_search=assert(require('workbench.controllers.search').new({layout=_G.wb14_layout,provider=_G.wb14_rg,store=_G.wb14_store,"
            "navigation=_G.wb14_nav,actions=_G.wb14_actions,workspace=ws,debounce_ms=20})); "
            "_G.wb14_symbols=assert(require('workbench.controllers.symbols').new({layout=_G.wb14_layout,provider=_G.wb14_lsp,"
            "store=_G.wb14_store,navigation=_G.wb14_nav,actions=_G.wb14_actions,workspace=ws,"
            "get_settings=function() return {symbols={include_declaration=true}} end,debounce_ms=20})); "
            "return {workspace=ws.roots[1].path,client=_G.wb14_client,source=vim.api.nvim_buf_get_name(_G.wb14_origin_buf)}",
            str(pyright), str(self.origin), str(self.workspace),
        )
        self.wait_lua(
            "local c=vim.lsp.get_client_by_id(_G.wb14_client); return c and c.initialized and c.attached_buffers[_G.wb14_origin_buf]",
            "real Pyright initialization and source-buffer attachment",
            timeout=30,
        )
        self.lua("_G.wb14_search_view=assert(_G.wb14_search:search_current_file(_G.wb14_workspace,_G.wb14_origin_path or vim.api.nvim_buf_get_name(_G.wb14_origin_buf),{focus=true}))")
        self.wait_screen("Query: (empty query)")
        self.lua("_G.wb14_search_origin=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()].origin")

    def _exercise(self) -> dict[str, Any]:
        self.phase = "real-file-search"
        self.lua("local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; assert(_G.wb14_search:set_query(s,'target_fn',true))")
        self.wait_lua(
            "local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; "
            "local r=e and _G.wb14_store:summary(e.result_id); return r and r.status~='running' and r.item_count>=2",
            "real ripgrep results for the symbol",
        )
        self.wait_screen("Query: target_fn")
        search_before = self.lua(
            "local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
            "return {id=e.result_id,query=s.query,scope=s.scope.path,selected=s.selected_id,count=_G.wb14_store:summary(e.result_id).item_count,"
            "source=vim.api.nvim_buf_get_name(_G.wb14_origin_buf)}"
        )

        self.lua("local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; _G.wb14_initial_search_selection=s.view.selected_id")
        self.input("j")
        self.wait_lua(
            "local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
            "local id=s.view.selected_id; local item=id and _G.wb14_store:item(e.result_id,id); return item and item.kind=='match' and id~=_G.wb14_initial_search_selection",
            "select the next real text-search match with Neovim input",
        )
        search_before["selected"] = self.lua("return _G.wb14_search.active[vim.api.nvim_get_current_tabpage()].selected_id")
        self.input("o")
        deadline = time.monotonic() + 4
        opened = False
        while time.monotonic() < deadline:
            opened = bool(self.lua("return vim.api.nvim_get_current_win()~=_G.wb14_origin_win and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match('main%.py$')~=nil"))
            if opened:
                break
            time.sleep(0.02)
        if not opened:
            state = self.lua(
                "local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
                "local item=s.selected_id and _G.wb14_store:item(e.result_id,s.selected_id); local view=s.view; return {current=vim.api.nvim_get_current_win(),origin=_G.wb14_origin_win,"
                "mode=vim.fn.mode(),selected=s.selected_id,view_selected=view.selected_id,kind=item and item.kind,path=item and item.location and item.location.resource.path,"
                "error=s.view.last_error,notice=s.notice,nav=_G.wb14_nav:status(),wins=vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())}"
            )
            raise TimeoutError(f"selected text-search match did not open in the editor: {state}")
        self.lua("_G.wb14_target_win=vim.api.nvim_get_current_win(); vim.api.nvim_win_set_cursor(_G.wb14_target_win,{3,2})")
        self.grid.wait_for(lambda: any("Search" in line for line in self.grid.lines()), 5, "Search results remain visible before references")

        self.phase = "references-through-action-registry"
        self.lua("vim.api.nvim_set_current_win(_G.wb14_search_view.window)")
        self.input("P")
        self.wait_screen("Actions · Enter")
        self.prompt("/", "symbols.references", "Filter actions:")
        self.wait_screen("Find references")
        action = self.lua(
            "local p=_G.wb14_search.palette.active[vim.api.nvim_get_current_tabpage()]; local a=p.by_id['symbols.references']; "
            "return {available=a and a.available.enabled,reason=a and a.available.reason,selected=p.view.selected_id,win=p.context().win,bufnr=p.context().bufnr}"
        )
        if not action["available"] or action["win"] != self.lua("return _G.wb14_target_win"):
            raise AssertionError(f"Find references was not available for the opened Search match: {action}")
        request_counts_before = self.lua("return vim.deepcopy(_G.wb14_request_metrics)")
        semantic_action_started = time.perf_counter_ns()
        self.input("\r")
        self.wait_lua(
            "local s=_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()]; local e=s and s.current; "
            "return e and e.method=='textDocument/references'",
            "shared action palette dispatches actual Pyright references",
        )
        self.wait_lua(
            "local s=_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()]; local e=s and s.current; "
            "local r=e and _G.wb14_store:summary(e.result_id); return r and r.status~='running'",
            "actual Pyright references response",
            timeout=30,
        )
        action["ok"] = True
        action["method"] = "textDocument/references"
        self.wait_screen("Include declaration: true")
        semantic_input_to_render_ms = (time.perf_counter_ns() - semantic_action_started) / 1_000_000
        references = self.lua(
            "local a=_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()]; local e=a.current; local r=_G.wb14_store:summary(e.result_id); "
            "local page=_G.wb14_store:page(e.result_id,0,200); local clients={}; for _,item in ipairs(page.items) do "
            "for _,id in ipairs(item.payload.client_ids or {item.payload.client_id}) do clients[#clients+1]=id end end; "
            "local search=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local se=search.investigation.current; "
            "return {method=e.method,status=r.status,count=r.item_count,include=e.include_declaration,client=_G.wb14_client,clients=clients,"
            "search_id=se.result_id,search_count=_G.wb14_store:summary(se.result_id).item_count,search_query=search.query,"
            "search_selected=search.selected_id,search_scope=search.scope.path,rows=a.view.rows,layout=_G.wb14_layout:status().active_views}"
        )
        if references["method"] != "textDocument/references" or references["status"] != "complete" or references["count"] < 2:
            raise AssertionError(f"Pyright returned no complete declaration/call reference set: {references}")
        if references["include"] is not True or references["search_id"] != search_before["id"] or references["search_count"] != search_before["count"]:
            raise AssertionError(f"semantic inspection altered the original Search result model: {references}")
        if references["search_query"] != search_before["query"] or references["search_selected"] != search_before["selected"] or references["search_scope"] != search_before["scope"]:
            raise AssertionError(f"semantic inspection changed Search query/scope/selection: {search_before} -> {references}")
        if references["client"] not in references["clients"]:
            raise AssertionError(f"reference rows lost their native Pyright client provenance: {references}")
        request_metrics = self.lua("return vim.deepcopy(_G.wb14_request_metrics)")
        methods_before = request_counts_before["lsp_methods"] if isinstance(request_counts_before["lsp_methods"], dict) else {}
        reference_requests = request_metrics["lsp_methods"].get("textDocument/references", 0) - methods_before.get("textDocument/references", 0)
        if reference_requests != 1:
            raise AssertionError(f"one Find References interaction must issue exactly one native request, got {reference_requests}: {request_metrics}")
        if request_counts_before["rg_starts"] != 1 or len(request_metrics["lsp_requests"]) != 1 or request_metrics["lsp_requests"][0].get("duration_ms", 0) <= 0:
            raise AssertionError(f"expected one Search request and one completed/timed semantic request: before={request_counts_before}, after={request_metrics}")
        self.grid.wait_for(lambda: any("target_fn" in line for line in self.grid.lines()), 8, "real semantic results rendered in the terminal grid")
        snapshot = self.grid.snapshot()
        (self.output / "references-grid.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

        self.input("j")
        self.wait_lua(
            "local a=_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()]; return a.preview and a.preview.last_preview~=nil",
            "bounded preview of a real reference",
        )
        self.input("\r")
        self.wait_lua("return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match('%.py$')~=nil", "open selected Pyright reference")
        self.lua("vim.api.nvim_set_current_win(_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()].view.window)")
        self.input("R")
        self.wait_lua(
            "return vim.api.nvim_get_current_buf()==vim.api.nvim_win_get_buf(_G.wb14_target_win) and vim.api.nvim_get_current_win()==_G.wb14_target_win",
            "return from a reference to its captured source location",
        )

        self.phase = "return-and-resume-search"
        self.lua("vim.api.nvim_set_current_win(_G.wb14_search_view.window)")
        self.input("R")
        self.wait_lua("return vim.api.nvim_get_current_win()==_G.wb14_origin_win and vim.api.nvim_get_current_buf()==_G.wb14_origin_buf", "return to the original Search origin")
        self.lua("vim.api.nvim_set_current_win(_G.wb14_search_view.window)")
        self.input("q")
        self.wait_lua("return _G.wb14_search:status().active_views==0", "close retained Search view")
        resumed = self.lua(
            "local view=assert(_G.wb14_search:open({workspace=_G.wb14_workspace,scope={kind='file',explicit=true,path=vim.api.nvim_buf_get_name(_G.wb14_origin_buf)},focus=true})); "
            "_G.wb14_search_view=view; local s=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
            "return {query=s.query,scope=s.scope.path,selected=s.selected_id,id=e.result_id,count=_G.wb14_store:summary(e.result_id).item_count,view=not view.closed}"
        )
        if resumed["query"] != search_before["query"] or resumed["scope"] != search_before["scope"] or resumed["selected"] != search_before["selected"] or resumed["count"] != search_before["count"]:
            raise AssertionError(f"reopened Search did not retain its original investigation: before={search_before}, resumed={resumed}")

        hidden_before = self.lua("return vim.deepcopy(_G.wb14_request_metrics)")
        hidden_started = time.perf_counter_ns()
        self.lua("vim.cmd('tabnew')")
        self.wait_lua("return vim.api.nvim_tabpage_get_number(vim.api.nvim_get_current_tabpage())==2", "switch to a tab with both discovery views hidden")
        time.sleep(0.12)
        hidden_during = self.lua("return vim.deepcopy(_G.wb14_request_metrics)")
        self.lua("vim.cmd('tabclose')")
        self.wait_lua("return vim.api.nvim_tabpage_get_number(vim.api.nvim_get_current_tabpage())==1", "return to the tab containing discovery views")
        hidden_tab_ms = (time.perf_counter_ns() - hidden_started) / 1_000_000
        hidden_view_requests_unchanged = hidden_before["rg_starts"] == hidden_during["rg_starts"] and hidden_before["lsp_methods"] == hidden_during["lsp_methods"]
        if not hidden_view_requests_unchanged:
            raise AssertionError(f"hidden Search/Symbols views started refresh work on tab changes: before={hidden_before}, during={hidden_during}")

        self.lua(
            "local symbol=_G.wb14_symbols.sessions[vim.api.nvim_get_current_tabpage()]; _G.wb14_layout:close('workbench-symbols',symbol.tab); "
            "local search=_G.wb14_search.active[vim.api.nvim_get_current_tabpage()]; _G.wb14_layout:close('workbench-search',search.tab)"
        )
        self.lua(
            "_G.wb14_symbols:dispose(); _G.wb14_search:dispose(); _G.wb14_rg:dispose(); _G.wb14_lsp:dispose(); "
            "_G.wb14_store:dispose(); _G.wb14_nav:dispose(); _G.wb14_layout:dispose(); vim.lsp.stop_client(_G.wb14_client,true)"
        )
        self.wait_lua("return vim.lsp.get_client_by_id(_G.wb14_client)==nil", "Pyright process cleanup", timeout=5)
        final = self.lua(
            "return {symbols=_G.wb14_symbols:status().sessions,search=_G.wb14_search:status().active_views,"
            "lsp=_G.wb14_lsp:status().active_requests,rg=_G.wb14_rg:status().active_requests,layout=_G.wb14_layout:status().active_views}"
        )
        if any(final.values()):
            raise AssertionError(f"WB-14 left semantic/search resources active: {final}")
        self.wait_screen("target_fn")
        final_grid = self.grid.snapshot()
        (self.output / "resumed-search-grid.json").write_text(json.dumps(final_grid, indent=2) + "\n", encoding="utf-8")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "server": "host Pyright language server over Neovim native LSP",
            "journey": "current-file rg -> open match -> Pyright references -> open -> return to source -> return to Search origin -> reopen retained Search",
            "ux_ids": ["UX-05"],
            "references": references["count"],
            "references_include_declaration": references["include"],
            "search_state_resumed": resumed["query"] == search_before["query"] and resumed["selected"] == search_before["selected"],
            "requests_per_interaction": {
                "workspace_search_query": request_counts_before["rg_starts"],
                "find_references": reference_requests,
                "lsp_method_counts": request_metrics["lsp_methods"],
                "lsp_request_durations_ms": [round(record.get("duration_ms", 0), 3) for record in request_metrics["lsp_requests"]],
            },
            "timings_ms": {"find_references_input_to_render": round(semantic_input_to_render_ms, 3), "hidden_tab_round_trip": round(hidden_tab_ms, 3)},
            "hidden_views_no_refresh": hidden_view_requests_unchanged,
            "resources": final,
            "action": action,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb14")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = SymbolsRun(args.nvim, cols, rows, output)
        try:
            print(json.dumps({"artifacts": str(output), **run.run()}, indent=2))
        except Exception as error:
            print(f"WB-14 semantic UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
