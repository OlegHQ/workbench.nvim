#!/usr/bin/env python3
"""Reviewed Files mutations on a real Neovim RPC grid."""

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
import traceback
from pathlib import Path

import pynvim

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run  # noqa: E402


class OperationsRun(Run):
    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="w-", dir="/tmp")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.editor_cwd = base / "editor-cwd"
        self.workspace.mkdir()
        self.editor_cwd.mkdir()
        (self.workspace / "keep.txt").write_text("workspace file stays in place\n", encoding="utf-8")
        (self.workspace / "nested").mkdir()
        self.origin = base / "origin.txt"
        self.origin.write_text("editor-owned origin\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb21-xdg-")
        xdg_root = Path(self.xdg.name)
        for name in ("config", "data", "state", "cache"):
            (xdg_root / name).mkdir()
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
        self.control = pynvim.attach("socket", path=self.socket)
        self.ui = pynvim.attach("socket", path=self.socket)
        self.ui.ui_attach(self.cols, self.rows, rgb=True, ext_linegrid=True)
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb21-operations-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.control.api.set_option("mouse", "a")
        self.lua(
            "local args=...; vim.o.hidden=true; vim.api.nvim_cmd({cmd='edit',args={args[1]}},{}); "
            "_G.wb21_origin_win=vim.api.nvim_get_current_win(); _G.wb21_origin_buf=vim.api.nvim_get_current_buf(); "
            "_G.wb21_origin_lines=vim.api.nvim_buf_get_lines(_G.wb21_origin_buf,0,-1,false); "
            "_G.wb21_origin_cwd=vim.fn.getcwd(); local root=args[2]; "
            "_G.wb21_workspace=assert(require('workbench.services.workspace').new({"
            "root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},"
            "ignore_service={snapshot=function() return {hidden='include',ignored='include',symlinks='never',include={},exclude={}} end}"
            "})):open({explicit_root=root}); "
            "_G.wb21_layout=assert(require('workbench.ui.layout').new({min_editor_width=30,min_editor_height=8,results_height=8})); "
            "_G.wb21_provider=assert(require('workbench.providers.filesystem').new()); "
            "local input,select=vim.ui.input,vim.ui.select; "
            "_G.wb21_controller=assert(require('workbench.controllers.files').new({layout=_G.wb21_layout,provider=_G.wb21_provider,"
            "input=function(opts,cb) _G.wb21_input_prompt=opts.prompt; return input(opts,cb) end,"
            "select=function(items,opts,cb) _G.wb21_review_prompt=opts.prompt; return select(items,opts,cb) end})); "
            "_G.wb21_view=assert(_G.wb21_controller:open(_G.wb21_workspace,{focus=true})); "
            "_G.wb21_session=_G.wb21_controller.sessions[_G.wb21_controller:_session_key(_G.wb21_workspace,vim.api.nvim_get_current_tabpage())]; "
            "return {root=_G.wb21_workspace.roots[1].path,cwd=_G.wb21_origin_cwd,origin=_G.wb21_origin_lines,view=_G.wb21_view.mode}",
            str(self.origin), str(self.workspace),
        )
        self.wait_lua("return _G.wb21_session.loaded[_G.wb21_session.root_id] == true", "Files root enumeration")
        self.wait_screen("keep.txt")

    def _exercise(self):
        target = self.workspace / "created.txt"
        self.phase = "actual-files-key-and-name-input"
        first_input = time.perf_counter_ns()
        self.input("a")
        self.grid.wait_for(lambda: self.grid.lines()[-1].rstrip().endswith(":"), 8, "create-file input prompt")
        self.input("created.txt\r")

        self.phase = "exact-reviewed-create-visible"
        expected_target = self.lua("return _G.wb21_workspace.roots[1].path") + "/created.txt"
        self.wait_screen("Operation: create_file")
        self.wait_screen("To:")
        self.wait_screen(expected_target)
        if target.exists():
            raise AssertionError("destination was mutated before the user confirmed the review")
        self.wait_screen("Apply this exact operation")
        review = "\n".join(self.grid.lines())
        if "To:" not in review or expected_target not in review:
            raise AssertionError(f"rendered review did not contain the exact create destination: {review!r}")
        (self.output / "review-screen.txt").write_text(review + "\n", encoding="utf-8")
        self.input("1\r")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and not target.exists():
            time.sleep(0.01)
        if not target.exists():
            raise TimeoutError(f"review confirmation did not create the exact destination; screen={self.grid.lines()}")
        if any("Press ENTER or type command to continue" in line for line in self.grid.lines()):
            self.input("\r")
        review_prompt = self.lua("return _G.wb21_review_prompt")
        if "Operation: create_file" not in review_prompt or f"To: {expected_target}" not in review_prompt:
            raise AssertionError(f"review callback did not preserve the exact create destination: {review_prompt!r}")
        self.wait_screen("created")
        operation_ms = (time.perf_counter_ns() - first_input) / 1_000_000

        applied = self.lua(
            "local s=_G.wb21_session; local status=_G.wb21_controller.operations:status(); "
            "local plan=status.plans[#status.plans]; return {plan=plan,focus=vim.api.nvim_get_current_win()==_G.wb21_view.window,"
            "cwd=vim.fn.getcwd(),origin_name=vim.api.nvim_buf_get_name(_G.wb21_origin_buf),"
            "origin_lines=vim.api.nvim_buf_get_lines(_G.wb21_origin_buf,0,-1,false),origin_modified=vim.bo[_G.wb21_origin_buf].modified,"
            "root_loaded=s.loaded[s.root_id],selected=s.selected_id,provider=_G.wb21_provider:status(),layout=_G.wb21_layout:status()}"
        )
        if not applied["plan"] or applied["plan"]["state"] != "applied":
            raise AssertionError(f"reviewed operation did not reach applied state: {applied}")
        if not applied["focus"] or applied["origin_modified"] or applied["origin_lines"] != ["editor-owned origin"]:
            raise AssertionError(f"Files stole focus/cwd or changed the editor-owned buffer: {applied}")
        if target.read_text(encoding="utf-8") != "":
            raise AssertionError("created file should be empty")

        self.phase = "close-and-dispose"
        self.input("q")
        self.wait_lua("local c=_G.wb21_controller:status(); return _G.wb21_layout:status().active_views==0 and c.session_count==1 and not c.sessions[1].mounted", "Files view disposal")
        closed = self.lua(
            "return {provider=_G.wb21_provider:status(),controller=_G.wb21_controller:status(),layout=_G.wb21_layout:status(),"
            "operations=_G.wb21_controller.operations:status(),origin_win=vim.api.nvim_get_current_win()==_G.wb21_origin_win,"
            "cwd=vim.fn.getcwd()}"
        )
        if closed["operations"]["active"] != 0 or closed["provider"]["active_requests"] != 0:
            raise AssertionError(f"closing Files retained requests: {closed}")
        self.lua("_G.wb21_controller:dispose(); _G.wb21_provider:dispose(); _G.wb21_layout:dispose()")
        disposed = self.lua("return {controller=_G.wb21_controller:status(),operations=_G.wb21_controller.operations:status(),provider=_G.wb21_provider:status(),layout=_G.wb21_layout:status()}")
        if not disposed["operations"]["disposed"] or disposed["operations"]["resources"]["resource_count"] != 0:
            raise AssertionError(f"operation service did not dispose cleanly: {disposed}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "reviewed_target": expected_target,
            "mutated_before_confirmation": False,
            "operation_latency_ms": round(operation_ms, 3),
            "ui_submit_to_review_ms": round((time.perf_counter_ns() - first_input) / 1_000_000, 3),
            "plan": applied["plan"],
            "closed": closed,
            "disposed": disposed,
            "review_screen_artifact": "review-screen.txt",
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="120x35")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb21")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = OperationsRun(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-21 Files operations failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n"
                  f"{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
