#!/usr/bin/env python3
"""Reviewed literal replacement through actual Search keys and Neovim UI prompts."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
import tempfile
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run  # noqa: E402


class ReplacementRun(Run):
    def wait_lua_args(self, expression: str, description: str, *args, timeout: float = 8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(expression, *args):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}")

    def replacement_input(self, value: str):
        self.input("X")
        self.wait_lua("return _G.wb22_input_prompt and _G.wb22_input_prompt:find('Literal replacement',1,true)~=nil", "replacement input prompt")
        self.input("\x15" + value + "\r")
        time.sleep(0.08)

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb22-replacement-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.editor_cwd = base / "editor-cwd"
        self.workspace.mkdir()
        self.editor_cwd.mkdir()
        self.origin = base / "origin.txt"
        self.origin.write_text("editor origin stays unchanged\n", encoding="utf-8")
        self.target = self.workspace / "target.txt"
        self.target.write_bytes(b"needle A\r\nneedle B\r\nkeep\r\n")
        self.target.chmod(0o640)

        self.xdg = tempfile.TemporaryDirectory(prefix="wb22-xdg-")
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
        import threading

        self.proc = subprocess.Popen(self.command, cwd=self.editor_cwd, env=environment, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb22-replacement-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial terminal grid")
        self.control.api.set_option("mouse", "a")
        self.lua(
            "local args=...; vim.o.hidden=true; vim.api.nvim_cmd({cmd='edit',args={args[1]}},{}); "
            "_G.wb22_origin_buf=vim.api.nvim_get_current_buf(); _G.wb22_origin_lines=vim.api.nvim_buf_get_lines(_G.wb22_origin_buf,0,-1,false); "
            "local root=args[2]; _G.wb22_workspace=assert(require('workbench.services.workspace').new({"
            "root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},"
            "ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}"
            "})):open({explicit_root=root}); "
            "_G.wb22_layout=require('workbench.ui.layout').new({min_editor_width=30,min_editor_height=8,results_height=8}); "
            "_G.wb22_provider=assert(require('workbench.providers.rg').new({max_items=100,max_batch_items=16})); "
            "_G.wb22_store=assert(require('workbench.services.results').new()); _G.wb22_nav=assert(require('workbench.services.navigation').new()); "
            "_G.wb22_controller=assert(require('workbench.controllers.search').new({layout=_G.wb22_layout,provider=_G.wb22_provider,store=_G.wb22_store,navigation=_G.wb22_nav,workspace=_G.wb22_workspace,debounce_ms=1,"
            "input=function(opts,cb) _G.wb22_input_prompt=opts.prompt; return vim.ui.input(opts,cb) end,"
            "select=function(items,opts,cb) _G.wb22_review_prompt=opts.prompt; return vim.ui.select(items,opts,cb) end})); "
            "_G.wb22_view=assert(_G.wb22_controller:open({workspace=_G.wb22_workspace,focus=true})); "
            "return {workspace=_G.wb22_workspace.roots[1].path,origin=_G.wb22_origin_lines,view=_G.wb22_view.mode}",
            str(self.origin), str(self.workspace),
        )
        self.wait_screen("Query: (empty query)")
        self.initial_action = self.lua(
            "local c=_G.wb22_controller; local s=c.active[vim.api.nvim_get_current_tabpage()]; "
            "for _,a in ipairs(c.actions:list(c:_action_context({search=s}))) do "
            "if a.id=='search.replace_selected' then return {enabled=a.available.enabled,reason=a.available.reason,eager=c.replacement~=nil} end end"
        )
        if self.initial_action["enabled"] or self.initial_action["eager"]:
            raise AssertionError(f"replacement should be unavailable and lazy before a completed search: {self.initial_action}")

    def _exercise(self):
        assert self.workspace is not None and self.target is not None
        original = self.target.read_bytes()
        self.phase = "real-literal-search"
        search_started = time.perf_counter_ns()
        self.prompt("/", "needle", "Search workspace:")
        self.wait_lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; local r=e and _G.wb22_store:summary(e.result_id); return r and r.status=='complete' and r.item_count==2",
            "two complete literal matches",
        )
        ready_action = self.lua(
            "local c=_G.wb22_controller; local s=c.active[vim.api.nvim_get_current_tabpage()]; "
            "for _,a in ipairs(c.actions:list(c:_action_context({search=s}))) do "
            "if a.id=='search.replace_selected' then return {enabled=a.available.enabled,eager=c.replacement~=nil} end end"
        )
        if not ready_action["enabled"] or ready_action["eager"]:
            raise AssertionError(f"a completed literal search should enable replacement without eager service creation: {ready_action}")
        search_ms = (time.perf_counter_ns() - search_started) / 1_000_000
        self.wait_screen("Query: needle")
        self.wait_lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return s.selected_id~=nil", "initial selected match")

        self.phase = "mark-selected-matches"
        first = self.lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return s.selected_id")
        self.input("m")
        self.wait_lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local n=0; for _ in pairs(s.marked_matches) do n=n+1 end; return n==1", "first match mark")
        self.input("j")
        self.wait_lua_args(
            "local wanted=...; local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return s.selected_id~=nil and s.selected_id~=wanted",
            "move to second match",
            first,
        )
        second = self.lua("return _G.wb22_controller.active[vim.api.nvim_get_current_tabpage()].selected_id")
        self.input("m")
        self.wait_lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local n=0; for _ in pairs(s.marked_matches) do n=n+1 end; return n==2", "second match mark")
        marks = self.lua("local first=...; local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return {first=s.marked_matches[first],selected=s.selected_id,second=s.marked_matches[s.selected_id],count=(function() local n=0; for _ in pairs(s.marked_matches) do n=n+1 end; return n end)()}", first)
        if marks["count"] != 2 or marks["selected"] != second:
            raise AssertionError(f"two selected matches were not retained: {marks}")

        self.phase = "cancel-reviewed-plan"
        self.replacement_input("discarded")
        self.wait_screen("Literal single-line replacement")
        self.wait_screen("+ discarded")
        self.control.request("nvim_input", "2\r")
        self.grid.wait_for(lambda: not any("Select the first item to apply" in line for line in self.grid.lines()), 5, "cancelled replacement review")
        self.wait_lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local p=_G.wb22_controller.replacement; return s.pending_replacement==nil and p:status().plans[1].state=='cancelled'",
            "review cancellation",
        )
        cancelled_id = self.lua("return _G.wb22_controller.replacement:status().plans[1].id")
        if self.target.read_bytes() != original:
            raise AssertionError("cancelling the replacement review mutated the file")

        self.phase = "review-exact-diff"
        review_started = time.perf_counter_ns()
        self.replacement_input("replaced")
        self.wait_screen("Literal single-line replacement")
        self.wait_screen("- needle")
        self.wait_screen("+ replaced")
        review_screen = "\n".join(self.grid.lines())
        (self.output / "review-screen.txt").write_text(review_screen + "\n", encoding="utf-8")
        pending = self.lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local p=s.pending_replacement; return {state=p and p.state,count=p and p.matched_count,review=p and p.review,diff=p and p.diff,marked=(function() local n=0; for _ in pairs(s.marked_matches) do n=n+1 end; return n end)()}"
        )
        if pending["state"] != "validated" or pending["count"] != 2 or pending["marked"] != 2:
            raise AssertionError(f"review plan did not freeze the two marked matches: {pending}")
        if self.target.read_bytes() != original:
            raise AssertionError("review mutated the file before explicit confirmation")
        if "needle" not in pending["diff"] or "replaced" not in pending["diff"]:
            raise AssertionError(f"review did not expose the exact diff: {pending}")
        review_ms = (time.perf_counter_ns() - review_started) / 1_000_000
        apply_started = time.perf_counter_ns()
        self.input("1\r")
        self.wait_lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return s.notice and s.notice.id=='replacement-applied' and s.last_replacement and s.last_replacement.state=='applied'",
            "reviewed replacement apply",
        )
        apply_ms = (time.perf_counter_ns() - apply_started) / 1_000_000
        expected = b"replaced A\r\nreplaced B\r\nkeep\r\n"
        if self.target.read_bytes() != expected:
            raise AssertionError(f"selected literal replacement produced unexpected bytes: {self.target.read_bytes()!r}")
        mode = self.target.stat().st_mode & 0o777
        if mode != 0o640:
            raise AssertionError(f"replacement did not preserve file mode: {oct(mode)}")
        plan_state = self.lua("return _G.wb22_controller.replacement:status().plans")

        self.phase = "stale-reviewed-preimage"
        stale_path = self.workspace / "stale.txt"
        stale_path.write_text("needle stale source\n", encoding="utf-8")
        self.input("r")
        self.wait_lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; local r=e and _G.wb22_store:summary(e.result_id); return r and r.status=='complete' and r.item_count==1",
            "rerun against newly-added stale fixture",
        )
        self.wait_lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return s.selected_id~=nil", "stale fixture selection")
        self.replacement_input("later")
        self.wait_screen("Literal single-line replacement")
        self.wait_screen("+ later")
        stale_original = stale_path.read_bytes()
        stale_plan = self.lua("local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; return {state=s.pending_replacement.state,path=s.pending_replacement.affected_resources[1]}")
        if stale_plan["state"] != "validated":
            raise AssertionError(f"stale review did not present a validated plan: {stale_plan}")
        stale_path.write_text("external change after review\n", encoding="utf-8")
        self.input("1\r")
        self.wait_lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local p=_G.wb22_controller.replacement; local q=p and p:status().plans; return s.notice and s.notice.id=='replacement-failed' and q and q[#q].state=='failed'",
            "stale preimage refusal",
        )
        stale_status = self.lua(
            "local s=_G.wb22_controller.active[vim.api.nvim_get_current_tabpage()]; local p=_G.wb22_controller.replacement; return {notice=s.notice,plans=p:status().plans,plan=s.last_replacement,failure=s.last_replacement_error}"
        )
        if stale_path.read_bytes() != b"external change after review\n":
            raise AssertionError("stale review overwrote subsequently changed file content")
        if stale_status["failure"]["code"] != "stale_preimage" or stale_status["plan"]["recovery"]["applied"] or stale_status["plan"]["recovery"]["unapplied"] != [stale_plan["path"]]:
            raise AssertionError(f"stale failure did not report the exact unapplied resource: {stale_status}")

        self.phase = "dispose-owned-resources"
        self.lua("_G.wb22_controller:dispose(); _G.wb22_nav:dispose(); _G.wb22_provider:dispose(); _G.wb22_store:dispose(); _G.wb22_layout:dispose()")
        disposed = self.lua("return {controller=_G.wb22_controller:status(),replacement=_G.wb22_controller.replacement==nil,provider=_G.wb22_provider:status(),layout=_G.wb22_layout:status(),origin=vim.api.nvim_buf_get_lines(_G.wb22_origin_buf,0,-1,false)}")
        if disposed["controller"]["active_views"] != 0 or not disposed["replacement"] or disposed["provider"]["active_requests"] != 0:
            raise AssertionError(f"replacement/Search resources were not disposed: {disposed}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "search_matches": 2,
            "replacement_unavailable_before_search": self.initial_action,
            "replacement_available_after_search": ready_action,
            "search_to_complete_ms": round(search_ms, 3),
            "marked_match_ids": [first, second],
            "cancelled_plan_id": cancelled_id,
            "reviewed_plan_state": "validated before confirmation",
            "review_latency_ms": round(review_ms, 3),
            "apply_latency_ms": round(apply_ms, 3),
            "mutated_before_confirmation": False,
            "replaced_bytes": expected.decode("utf-8"),
            "preserved_mode": oct(mode),
            "stale_change_preserved": stale_path.read_bytes().decode("utf-8"),
            "stale_notice": stale_status["notice"],
            "first_plan": plan_state,
            "stale_plan": stale_status,
            "review_screen_artifact": "review-screen.txt",
            "disposed": disposed,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb22")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = ReplacementRun(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-22 Replacement UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
