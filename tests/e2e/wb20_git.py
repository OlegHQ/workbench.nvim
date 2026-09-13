#!/usr/bin/env python3
"""Read-only Git status and explicit diff preview on a real Neovim RPC grid."""

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


class GitRun(Run):
    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.fixture = tempfile.TemporaryDirectory(prefix="wb20-git-")
        base = Path(self.fixture.name)
        self.workspace = base / "repository"
        self.editor_cwd = base / "editor-cwd"
        self.workspace.mkdir()
        self.editor_cwd.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.workspace)], check=True)
        subprocess.run(["git", "-C", str(self.workspace), "config", "user.name", "Workbench E2E"], check=True)
        subprocess.run(["git", "-C", str(self.workspace), "config", "user.email", "workbench@example.invalid"], check=True)
        (self.workspace / "changed.txt").write_text("before\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.workspace), "add", "--", "changed.txt"], check=True)
        subprocess.run(["git", "-C", str(self.workspace), "commit", "--quiet", "-m", "base"], check=True)
        (self.workspace / "changed.txt").write_text("after\n", encoding="utf-8")
        (self.workspace / "new file.txt").write_text("new content\n", encoding="utf-8")
        self.origin = base / "origin.txt"
        self.origin.write_text("editor-owned origin\n", encoding="utf-8")

        self.xdg = tempfile.TemporaryDirectory(prefix="wb20-xdg-")
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
        self.proc = subprocess.Popen(
            self.command, cwd=self.editor_cwd, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb20-git-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.control.api.set_option("mouse", "a")
        self.phase = "open-status"
        self.lua(
            "local args=...; vim.o.hidden=true; "
            "vim.api.nvim_cmd({cmd='edit',args={args[1]}},{}); "
            "_G.wb20_origin_win=vim.api.nvim_get_current_win(); "
            "_G.wb20_workspace=assert(require('workbench.services.workspace').new({"
            "root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},"
            "ignore_service={snapshot=function() return {hidden='include',ignored='include',symlinks='never',include={},exclude={}} end}"
            "})):open({explicit_root=args[2]}); "
            "_G.wb20_layout=assert(require('workbench.ui.layout').new({min_editor_width=30,min_editor_height=8,results_height=8})); "
            "_G.wb20_git_calls=0; local system=vim.system; "
            "_G.wb20_provider=assert(require('workbench.providers.git').new({system=function(...) "
            "_G.wb20_git_calls=_G.wb20_git_calls+1; return system(...) end})); "
            "_G.wb20_actions=require('workbench.core.actions').new(); "
            "_G.wb20_controller=assert(require('workbench.controllers.git').new({layout=_G.wb20_layout,"
            "provider=_G.wb20_provider,actions=_G.wb20_actions})); "
            "_G.wb20_view,_G.wb20_session=assert(_G.wb20_controller:open(_G.wb20_workspace,{focus=true})); "
            "return {workspace=_G.wb20_workspace.roots[1].path,view=_G.wb20_view.mode}",
            str(self.origin), str(self.workspace),
        )
        self.wait_lua(
            "return _G.wb20_session.snapshot~=nil and _G.wb20_view.model.status=='ready'",
            "real Git status",
        )
        self.wait_screen("changed.txt")
        self.wait_screen("new file.txt")

    def _exercise(self):
        self.phase = "cursor-movement-does-not-run-git"
        initial = self.lua(
            "return {calls=_G.wb20_git_calls,selected=_G.wb20_view.selected_id,"
            "files=#_G.wb20_session.snapshot.files,aggregate=_G.wb20_session.snapshot.aggregate,"
            "actions=_G.wb20_actions:list({workspace=_G.wb20_workspace})}"
        )
        if initial["calls"] != 2 or initial["files"] != 2:
            raise AssertionError(f"status should use one identity + one porcelain process: {initial}")
        self.lua("local selected=...; _G.wb20_initial_selection=selected", initial["selected"])
        self.input("j")
        self.wait_lua("return _G.wb20_view.selected_id~=_G.wb20_initial_selection", "Git row selection")
        moved = self.lua("return {calls=_G.wb20_git_calls,selected=_G.wb20_view.selected_id}")
        if moved["calls"] != initial["calls"]:
            raise AssertionError(f"cursor movement launched a Git process: {moved}")

        self.phase = "explicit-selected-file-diff"
        started = time.perf_counter_ns()
        self.input("d")
        self.wait_lua(
            "return _G.wb20_session.diff_view and _G.wb20_session.diff_view.model.status=='ready'",
            "bounded selected-file diff",
        )
        self.wait_lua(
            "return _G.wb20_git_calls==3 and _G.wb20_session.diff_view.model.title:find('new file.txt',1,true)~=nil",
            "exactly one selected-file diff process",
        )
        for index in range(12):
            if any("+new content" in line for line in self.grid.lines()):
                break
            current = self.lua("return _G.wb20_session.diff_view.selected_id")
            self.lua("local id=...; _G.wb20_previous_diff_selection=id", current)
            self.input("j")
            self.wait_lua(
                "return _G.wb20_session.diff_view.selected_id~=_G.wb20_previous_diff_selection",
                f"diff row navigation {index + 1}",
            )
        if not any("+new content" in line for line in self.grid.lines()):
            debug = self.lua(
                "local v=_G.wb20_session.diff_view; return {selected=v.selected_id,scroll=v.scroll_offset,"
                "rows=#v.rows,visible=v.visible_rows,focus=vim.api.nvim_get_current_win()==v.window,"
                "cursor=v.window and vim.api.nvim_win_get_cursor(v.window),model=v.model.status}"
            )
            raise AssertionError(f"diff row navigation did not reveal content: {debug}; screen={self.grid.lines()}")
        self.grid.wait_for(lambda: any("+new content" in line for line in self.grid.lines()), 5, "diff content in rendered grid")
        diff_ms = (time.perf_counter_ns() - started) / 1_000_000
        diff_state = self.lua(
            "local s=_G.wb20_session; return {calls=_G.wb20_git_calls,items=#s.diff_view.model.items,"
            "diff_status=s.diff_view.model.status,focus=vim.api.nvim_get_current_win()==s.diff_view.window,"
            "cwd=vim.fn.getcwd(),workspace=s.workspace.roots[1].path,layout=_G.wb20_layout:status()}"
        )
        if diff_state["calls"] != 3 or not diff_state["focus"]:
            raise AssertionError(f"diff did not remain read-only and focus its own result view: {diff_state}")
        diff_screen = self.grid.snapshot()["text"]
        (self.output / "diff-screen.txt").write_text("\n".join(diff_screen) + "\n", encoding="utf-8")

        self.phase = "close-diff-and-status"
        self.input("q")
        self.wait_lua(
            "return not _G.wb20_session.diff_view and vim.api.nvim_get_current_win()==_G.wb20_view.window",
            "closing diff returns to Git status",
        )
        self.input("q")
        self.wait_lua(
            "return _G.wb20_layout:status().active_views==0 and _G.wb20_controller:status().session_count==0",
            "closing all Git consumers",
        )
        final = self.lua(
            "return {calls=_G.wb20_git_calls,provider=_G.wb20_provider:status(),"
            "controller=_G.wb20_controller:status(),layout=_G.wb20_layout:status(),"
            "origin=vim.api.nvim_buf_get_lines(1,0,1,false)[1],cwd=vim.fn.getcwd()}"
        )
        status = subprocess.run(
            ["git", "-C", str(self.workspace), "status", "--porcelain=v2", "-z"],
            capture_output=True, check=True,
        ).stdout
        if status.count(b"\0") != 2 or b"new file.txt" not in status or b"changed.txt" not in status:
            raise AssertionError(f"Git UI changed repository state: {status!r}")
        if final["provider"]["active_requests"] != 0 or final["layout"]["active_views"] != 0:
            raise AssertionError(f"closing views retained Git/UI work: {final}")
        self.lua("_G.wb20_controller:dispose(); _G.wb20_provider:dispose(); _G.wb20_layout:dispose()")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "status_processes": initial["calls"],
            "cursor_movement_processes": moved["calls"] - initial["calls"],
            "selected_diff_processes": diff_state["calls"] - initial["calls"],
            "diff_latency_ms": round(diff_ms, 3),
            "diff_items": diff_state["items"],
            "readonly_status_bytes": len(status),
            "closed_resources": final,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="120x35")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb20")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = GitRun(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(
                f"WB-20 Git UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n"
                f"{type(error).__name__}: {error}\n{traceback.format_exc()}",
                file=sys.stderr,
            )
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
