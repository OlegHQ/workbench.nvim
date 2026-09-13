#!/usr/bin/env python3
"""Real gopls call hierarchy over native LSP and an RPC-controlled Neovim grid."""

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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb14_symbols import SymbolsRun  # noqa: E402


class CallsRun(SymbolsRun):
    def _start(self) -> None:
        self.output.mkdir(parents=True, exist_ok=False)
        gopls = shutil.which("gopls")
        if not gopls:
            raise RuntimeError("WB-15 real-server gate requires gopls on PATH")
        self.fixture = tempfile.TemporaryDirectory(prefix="wb15-calls-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.workspace.mkdir()
        self.editor_cwd = base / "editor-cwd"
        self.editor_cwd.mkdir()
        self.source = self.workspace / "calls.go"
        self.source.write_text(
            "package main\n\n"
            "func Alpha() { Beta() }\n"
            "func Beta() { Alpha(); Gamma() }\n"
            "func Gamma() { Beta() }\n"
            "func main() { Alpha() }\n",
            encoding="utf-8",
        )
        (self.workspace / "go.mod").write_text("module example.org/workbench-wb15\n\ngo 1.23\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb15-xdg-")
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
            "GOTOOLCHAIN": "local",
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb15-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        setup = self.lua(
            "local args=...; local gopls,path,workspace=args[1],args[2],args[3]; vim.o.hidden=true; "
            "vim.api.nvim_cmd({cmd='edit',args={path}},{}); _G.wb15_origin_buf=vim.api.nvim_get_current_buf(); "
            "_G.wb15_origin_win=vim.api.nvim_get_current_win(); vim.api.nvim_win_set_cursor(_G.wb15_origin_win,{3,5}); "
            "local ws=assert(require('workbench.services.workspace').new({"
            "root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},"
            "ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=workspace}); "
            "_G.wb15_workspace=ws; _G.wb15_layout=assert(require('workbench.ui.layout').new({min_editor_width=24,min_editor_height=6,results_height=12})); "
            "_G.wb15_navigation=assert(require('workbench.services.navigation').new()); _G.wb15_actions=require('workbench.core.actions').new(); "
            "_G.wb15_lsp=assert(require('workbench.providers.lsp').new({request_timeout_ms=30000})); _G.wb15_requests={}; "
            "local native_start=_G.wb15_lsp.start; function _G.wb15_lsp:start(request,sink) "
            "_G.wb15_requests[#_G.wb15_requests+1]={method=request.method,direction=request.direction,client_ids=request.client_ids,max_items=request.max_items}; "
            "return native_start(self,request,sink) end; "
            "_G.wb15_client=assert(vim.lsp.start({name='workbench-wb15-gopls',cmd={gopls,'serve'},root_dir=ws.roots[1].path,"
            "capabilities=vim.lsp.protocol.make_client_capabilities()},{bufnr=_G.wb15_origin_buf})); "
            "_G.wb15_calls=assert(require('workbench.controllers.calls').new({layout=_G.wb15_layout,provider=_G.wb15_lsp,"
            "navigation=_G.wb15_navigation,actions=_G.wb15_actions,workspace=ws})); "
            "_G.wb15_palette=assert(require('workbench.ui.palette').new({layout=_G.wb15_layout,actions=_G.wb15_actions,context=function() "
            "return {workspace=_G.wb15_workspace,bufnr=_G.wb15_origin_buf,win=_G.wb15_origin_win} end})); "
            "vim.keymap.set('n','P',function() _G.wb15_palette:open({focus=true}) end,{buffer=_G.wb15_origin_buf,silent=true}); "
            "return {workspace=ws.roots[1].path,client=_G.wb15_client,source=vim.api.nvim_buf_get_name(_G.wb15_origin_buf)}",
            str(gopls), str(self.source), str(self.workspace),
        )
        self.wait_lua(
            "local c=vim.lsp.get_client_by_id(_G.wb15_client); return c and c.initialized and c.attached_buffers[_G.wb15_origin_buf]",
            "real gopls initialization and source-buffer attachment",
            timeout=45,
        )
        capability = self.lua(
            "local p=_G.wb15_lsp:capabilities({bufnr=_G.wb15_origin_buf,method='textDocument/prepareCallHierarchy'}); "
            "return {state=p.state,reason=p.reason,code=p.code,client=p.clients and p.clients[1]}"
        )
        if capability["state"] != "ready":
            raise RuntimeError(f"installed gopls does not provide call hierarchy: {capability}")
        self.capability = capability
        self.wait_screen("Alpha")

    def _exercise(self) -> dict[str, Any]:
        self.phase = "call-hierarchy-action-prepare"
        start = time.monotonic()
        self.input("P")
        self.wait_screen("Actions")
        self.wait_screen("Open call hierarchy")
        self.input("\r")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return s and #s.roots>0 and s.phase~='Preparing'",
            "gopls call hierarchy preparation",
            timeout=30,
        )
        prepare_ms = (time.monotonic() - start) * 1000
        prepared = self.lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return {phase=s.phase,direction=s.direction,"
            "roots=vim.tbl_map(function(n) return {id=n.id,name=n.call_item.name,client=n.client_id} end,s.roots),"
            "requests=vim.deepcopy(_G.wb15_requests),view=not s.view.closed,origin=vim.api.nvim_get_current_win()==s.view.window}"
        )
        if not prepared["roots"] or prepared["roots"][0]["name"] != "Alpha":
            raise AssertionError(f"gopls did not prepare Alpha at the source position: {prepared}")
        if len(prepared["requests"]) != 1 or prepared["requests"][0]["method"] != "textDocument/prepareCallHierarchy":
            raise AssertionError(f"opening call hierarchy issued more than its preparation request: {prepared}")
        self.wait_screen("Outgoing")
        self.wait_screen("Alpha")
        prepared_grid = self.grid.snapshot()
        (self.output / "prepared-grid.json").write_text(json.dumps(prepared_grid, indent=2) + "\n", encoding="utf-8")

        self.phase = "lazy-outgoing-expand"
        start = time.monotonic()
        self.input(" ")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return #_G.wb15_requests==2 and s.roots[1].expansion=='complete' and #s.roots[1].children>0",
            "one lazy outgoing-call expansion",
            timeout=20,
        )
        first_expansion_ms = (time.monotonic() - start) * 1000
        self.wait_screen("Beta")
        outgoing_root = self.lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return {names=vim.tbl_map(function(n) return n.call_item.name end,s.roots[1].children),"
            "requests=vim.deepcopy(_G.wb15_requests),edges=s.edge_count}"
        )
        if outgoing_root["requests"][1]["method"] != "callHierarchy/outgoingCalls":
            raise AssertionError(f"first expansion was not an outgoing call request: {outgoing_root}")
        if "Beta" not in outgoing_root["names"]:
            raise AssertionError(f"Alpha did not expand to Beta: {outgoing_root}")
        self.lua("local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("j")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; local n=s.nodes[s.view.selected_id]; return n and n.call_item.name=='Beta'",
            "select the real outgoing Beta edge",
        )
        self.input(" ")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; local n=s.nodes[s.view.selected_id]; return #_G.wb15_requests==3 and n.expansion=='complete' and #n.children>=2",
            "lazy expansion of the mutually recursive Beta node",
            timeout=20,
        )
        outgoing_tree = self.lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; local n=s.nodes[s.view.selected_id]; return {"
            "children=vim.tbl_map(function(c) return {name=c.call_item.name,cycle=c.cycle,client=c.client_id} end,n.children),"
            "requests=vim.deepcopy(_G.wb15_requests),edges=s.edge_count}"
        )
        if not any(item["name"] == "Alpha" and item["cycle"] for item in outgoing_tree["children"]):
            raise AssertionError(f"mutual recursion did not produce an Alpha cycle marker: {outgoing_tree}")
        if not any(item["name"] == "Gamma" for item in outgoing_tree["children"]):
            raise AssertionError(f"gopls omitted Beta's independent Gamma edge: {outgoing_tree}")
        self.wait_screen("Gamma")
        outgoing_grid = self.grid.snapshot()
        if not any("Alpha ↻" in line for line in outgoing_grid["text"]):
            raise AssertionError(f"cycle marker was not legible in the rendered call tree: {outgoing_grid['text']}")
        (self.output / "outgoing-grid.json").write_text(json.dumps(outgoing_grid, indent=2) + "\n", encoding="utf-8")

        self.phase = "direction-switch-and-incoming"
        self.input("I")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return s.direction=='incoming' and #s.roots[1].children==0 and s.view.expanded[s.roots[1].id]==false",
            "incoming direction selection without eager expansion",
        )
        after_switch = self.lua("return vim.deepcopy(_G.wb15_requests)")
        if len(after_switch) != 3:
            raise AssertionError(f"switching direction issued provider work before expansion: {after_switch}")
        self.input(" ")
        self.wait_lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return #_G.wb15_requests==4 and #s.roots[1].children>=2 and s.roots[1].expansion=='complete'",
            "one lazy incoming-call expansion",
            timeout=20,
        )
        incoming = self.lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return {names=vim.tbl_map(function(n) return n.call_item.name end,s.roots[1].children),"
            "ranges=vim.tbl_map(function(n) return n.location.range.start end,s.roots[1].children),requests=vim.deepcopy(_G.wb15_requests)}"
        )
        if incoming["requests"][3]["method"] != "callHierarchy/incomingCalls":
            raise AssertionError(f"direction switch did not route an incoming request: {incoming}")
        if "main" not in incoming["names"]:
            raise AssertionError(f"gopls incoming hierarchy did not find main: {incoming}")
        self.wait_screen("Incoming")
        incoming_grid = self.grid.snapshot()
        (self.output / "incoming-grid.json").write_text(json.dumps(incoming_grid, indent=2) + "\n", encoding="utf-8")

        main_id = self.lua(
            "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; for _,n in ipairs(s.roots[1].children) do "
            "if n.call_item.name=='main' then return n.id end end"
        )
        if not main_id:
            raise AssertionError(f"incoming caller item main is missing: {incoming}")
        for _ in range(8):
            selected = self.lua("local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return s.view.selected_id")
            if selected == main_id:
                break
            self.input("j")
            self.wait_lua(
                "local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return s.view.selected_id~=" + json.dumps(selected),
                "move through visible call edges",
            )
        self.wait_lua("local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; return s.view.selected_id==" + json.dumps(main_id), "select incoming main call")

        self.phase = "incoming-callsite-navigation-return"
        self.input("o")
        self.wait_lua(
            "return vim.api.nvim_get_current_win()~=_G.wb15_origin_win and vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):match('calls%.go$')~=nil",
            "open the selected incoming call location in the source file",
        )
        opened = self.lua(
            "local win=vim.api.nvim_get_current_win(); return {line=vim.api.nvim_win_get_cursor(win)[1],column=vim.api.nvim_win_get_cursor(win)[2],"
            "path=vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)),origin_buf=_G.wb15_origin_buf,origin_win=_G.wb15_origin_win}"
        )
        if opened["line"] != 6:
            raise AssertionError(f"incoming navigation did not target main's call site: {opened}")
        self.lua("local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("R")
        self.wait_lua(
            "return vim.api.nvim_get_current_win()==_G.wb15_origin_win and vim.api.nvim_get_current_buf()==_G.wb15_origin_buf",
            "return to the originating source window and buffer",
        )

        self.phase = "owned-resource-cleanup"
        self.lua("local s=_G.wb15_calls.sessions[vim.api.nvim_get_current_tabpage()]; vim.api.nvim_set_current_win(s.view.window)")
        self.input("q")
        self.wait_lua("return #_G.wb15_calls:status().sessions==0", "close call hierarchy session")
        self.lua("_G.wb15_palette:dispose(); _G.wb15_calls:dispose(); _G.wb15_lsp:dispose(); _G.wb15_navigation:dispose(); _G.wb15_layout:dispose(); vim.lsp.stop_client(_G.wb15_client,true)")
        self.wait_lua("return vim.lsp.get_client_by_id(_G.wb15_client)==nil", "gopls process cleanup", timeout=8)
        resources = self.lua(
            "return {calls_empty=#_G.wb15_calls:status().sessions==0,requests=_G.wb15_lsp:status().active_requests,"
            "layout=_G.wb15_layout:status().active_views,palette=_G.wb15_palette:status().active,client_active=vim.lsp.get_client_by_id(_G.wb15_client)~=nil}"
        )
        if resources != {"calls_empty": True, "requests": 0, "layout": 0, "palette": 0, "client_active": False}:
            raise AssertionError(f"WB-15 disposal left owned work or views active: {resources}")
        final_grid = self.grid.snapshot()
        (self.output / "final-grid.json").write_text(json.dumps(final_grid, indent=2) + "\n", encoding="utf-8")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "server": "gopls over Neovim native LSP",
            "client": self.capability["client"],
            "prepared_roots": prepared["roots"],
            "outgoing_edges": outgoing_root["names"],
            "mutual_recursion": outgoing_tree["children"],
            "incoming_edges": incoming["names"],
            "incoming_callsite": {"line": opened["line"], "column": opened["column"]},
            "requests": incoming["requests"],
            "lazy": len(prepared["requests"]) == 1 and len(outgoing_root["requests"]) == 2 and len(after_switch) == 3,
            "navigation_returned": True,
            "timings_ms": {
                "prepare": round(prepare_ms, 3),
                "first_outgoing_expansion": round(first_expansion_ms, 3),
            },
            "resources": resources,
            "artifacts": ["prepared-grid.json", "outgoing-grid.json", "incoming-grid.json", "final-grid.json"],
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb15")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = CallsRun(args.nvim, cols, rows, output)
        try:
            print(json.dumps({"artifacts": str(output), **run.run()}, indent=2))
        except Exception as error:
            print(f"WB-15 call hierarchy UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
