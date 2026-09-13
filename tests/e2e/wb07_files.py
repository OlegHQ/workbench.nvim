#!/usr/bin/env python3
"""Real RPC-grid acceptance for the read-only Files provider/controller."""

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
        if os.path.sep in nvim or (os.path.altsep and os.path.altsep in nvim):
            self.nvim = str(Path(nvim).resolve())
        else:
            self.nvim = shutil.which(nvim) or str(Path(nvim).resolve())
        self.cols = cols
        self.rows = rows
        self.output = output
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.socket = f"/tmp/wb07-{secrets.token_hex(8)}.sock"
        self.watchdog: threading.Timer | None = None
        self.child_reaped = False
        self.returncode: int | None = None
        self.failure: str | None = None
        self.outcome: dict[str, Any] = {}
        self.command: list[str] = []
        self.xdg: tempfile.TemporaryDirectory[str] | None = None
        self.fixture: tempfile.TemporaryDirectory[str] | None = None
        self.workspace: Path | None = None
        self.editor_cwd: Path | None = None
        self.symlinks: dict[str, bool] = {}
        self.first_view_ms = 0.0
        self.phase = "setup"

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def wait_lua(self, expression: str, description: str, timeout: float = 8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(f"return ({expression})"):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}")

    def wait_screen(self, fragment: str, timeout: float = 6.0):
        self.grid.wait_for(lambda: any(fragment in line for line in self.grid.lines()), timeout, fragment)

    def _fixture(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="wb07-files-")
        base = Path(self.fixture.name)
        self.workspace = base / "workspace"
        self.editor_cwd = base / "different-cwd"
        self.workspace.mkdir()
        self.editor_cwd.mkdir()
        (self.workspace / "alpha").mkdir()
        (self.workspace / "beta").mkdir()
        (self.workspace / "vanish").mkdir()
        (self.workspace / "git-ignored").mkdir()
        (self.workspace / "shared-ignored").mkdir()
        (self.workspace / "empty-ignored").mkdir()
        (self.workspace / "alpha" / "alpha.lua").write_text("return 'alpha'\n", encoding="utf-8")
        (self.workspace / "alpha" / "needle-alpha.lua").write_text("return 'needle alpha'\n", encoding="utf-8")
        (self.workspace / "alpha" / "nested-ignored.txt").write_text("nested git ignore\n", encoding="utf-8")
        (self.workspace / "alpha" / "alpha-ignored").mkdir()
        (self.workspace / "alpha" / "alpha-ignored" / "private.txt").write_text("hidden by nested gitignore\n", encoding="utf-8")
        (self.workspace / "beta" / "needle-beta.lua").write_text("return 'needle beta'\n", encoding="utf-8")
        (self.workspace / "beta" / "readme.md").write_text("beta\n", encoding="utf-8")
        (self.workspace / "vanish" / "gone.txt").write_text("will vanish\n", encoding="utf-8")
        (self.workspace / "git-ignored" / "file.txt").write_text("git ignored\n", encoding="utf-8")
        (self.workspace / "shared-ignored" / "file.txt").write_text("ignore file\n", encoding="utf-8")
        (self.workspace / "root-ignored.txt").write_text("ignored root file\n", encoding="utf-8")
        (self.workspace / "line\nbreak.txt").write_text("raw path\n", encoding="utf-8")
        (self.workspace / "界-file.txt").write_text("wide path\n", encoding="utf-8")
        (self.workspace / ".secret").write_text("hidden\n", encoding="utf-8")
        (self.workspace / ".gitignore").write_text(
            "git-ignored/\nempty-ignored/\nroot-ignored.txt\n", encoding="utf-8"
        )
        (self.workspace / ".ignore").write_text("shared-ignored/\n", encoding="utf-8")
        (self.workspace / "alpha" / ".gitignore").write_text(
            "nested-ignored.txt\nalpha-ignored/\n", encoding="utf-8"
        )
        outside = base / "outside-target"
        outside.mkdir()
        (outside / "outside.txt").write_text("external\n", encoding="utf-8")
        symlinks: dict[str, bool] = {}
        for name, target in (("external-link", outside), ("cycle-link", self.workspace)):
            try:
                (self.workspace / name).symlink_to(target, target_is_directory=True)
                symlinks[name] = True
            except OSError:
                symlinks[name] = False
        try:
            (self.workspace / "alpha" / "cycle-link").symlink_to(self.workspace, target_is_directory=True)
            symlinks["nested-cycle"] = True
        except OSError:
            symlinks["nested-cycle"] = False
        return symlinks

    def _start(self):
        self.output.mkdir(parents=True, exist_ok=False)
        self.symlinks = self._fixture()
        assert self.workspace is not None and self.editor_cwd is not None
        self.xdg = tempfile.TemporaryDirectory(prefix="wb07-xdg-")
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
        self.proc = subprocess.Popen(self.command, cwd=self.editor_cwd, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb07-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial UI frame")
        self.control.api.set_option("mouse", "a")
        self.lua("vim.o.hidden=true; _G.wb07_origin_buf=vim.api.nvim_get_current_buf(); _G.wb07_origin_win=vim.api.nvim_get_current_win(); _G.wb07_cwd=vim.fn.getcwd(); vim.api.nvim_buf_set_lines(_G.wb07_origin_buf,0,-1,true,{'USER OWNED CONTENT'}); vim.bo[_G.wb07_origin_buf].modified=true")
        assert self.symlinks

    def _session(self):
        return self.lua("for _,s in pairs(_G.wb07_controller.sessions) do if s.tab==vim.api.nvim_get_current_tabpage() then return s end end")

    def _wait_loaded(self, expression: str, description: str):
        self.wait_lua(expression, description)

    def _names(self):
        return self.lua("local s=_G.wb07_session; local out={}; for _,id in ipairs(s.children[s.root_id] or {}) do local n=s.nodes[id]; if n and n.payload then out[n.payload.raw_name]={id=id,kind=n.kind,expandable=n.expandable,detail=n.detail,label=n.label} end end; return out")

    def _exercise(self):
        assert self.workspace is not None
        root = str(self.workspace)
        self.phase = "open-root"
        layout_mode = "split" if self.cols >= 93 and self.rows >= 13 else "overlay"
        started = time.perf_counter_ns()
        setup = self.lua(
            "local args=...; local root=args[1]; local Workspace=require('workbench.services.workspace'); _G.wb07_workspace=assert(Workspace.new({root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='internal',include={},exclude={}} end}})); _G.wb07_snapshot=assert(_G.wb07_workspace:open({explicit_root=root})); _G.wb07_layout=require('workbench.ui.layout').new(); _G.wb07_provider=assert(require('workbench.providers.filesystem').new()); _G.wb07_controller=assert(require('workbench.controllers.files').new({layout=_G.wb07_layout,provider=_G.wb07_provider,update_policy=function(snapshot,changes) local next=vim.deepcopy(snapshot); next.generation=next.generation+1; for key,value in pairs(changes) do next.policy[key]=value end; _G.wb07_snapshot=next; return next end,on_search=function(snapshot,path) _G.wb07_search={root=snapshot.roots[1].path,scope=path} end})); _G.wb07_view=assert(_G.wb07_controller:open(_G.wb07_snapshot,{focus=true})); for _,s in pairs(_G.wb07_controller.sessions) do _G.wb07_session=s end; return {mode=_G.wb07_view.mode,root=_G.wb07_session.root_id,cwd=vim.fn.getcwd(),help=_G.wb07_view.help_lines}",
            root,
        )
        if setup["mode"] != layout_mode:
            raise AssertionError(f"Files layout mode mismatch at {self.cols}x{self.rows}: {setup}")
        if "Global and .git/info excludes unavailable" not in setup["help"]:
            raise AssertionError(f"Files did not report unavailable global ignore sources: {setup['help']}")
        policy_limitations = self.lua("return _G.wb07_controller:status().policy_limitations")
        if policy_limitations != ["global-ignore-sources", "git-info-exclude"]:
            raise AssertionError(f"Files capability status did not identify unsupported ignore sources: {policy_limitations}")
        self.wait_screen(self.workspace.name)
        self.first_view_ms = (time.perf_counter_ns() - started) / 1_000_000
        self.wait_lua("_G.wb07_session.loaded[_G.wb07_session.root_id] == true", "root directory enumeration")

        root_names = self._names()
        for excluded in (".secret", "git-ignored", "empty-ignored", "shared-ignored", "root-ignored.txt", ".git"):
            if excluded in root_names:
                raise AssertionError(f"workspace policy failed to exclude {excluded}: {root_names}")
        if root_names.get("alpha", {}).get("kind") != "directory" or root_names.get("beta", {}).get("kind") != "directory":
            raise AssertionError(f"immediate directories missing: {root_names}")
        raw_newline_name = root_names.get("line\nbreak.txt")
        if raw_newline_name and raw_newline_name.get("label") != "line\\x0Abreak.txt":
            raise AssertionError(f"raw path/escaped display contract failed: {raw_newline_name}")
        if self.lua("return vim.fn.getcwd() == _G.wb07_cwd") is not True:
            raise AssertionError("Files changed Neovim's cwd while enumerating an explicit workspace root")

        # Keyboard-expand alpha and assert its local ignore rules apply.
        self.control.api.input("j")
        self.wait_lua("_G.wb07_session.selected_id == _G.wb07_session.nodes[_G.wb07_session.children[_G.wb07_session.root_id][1]].id", "keyboard selection of first directory")
        self.control.api.input("l")
        self.wait_lua("_G.wb07_session.loaded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/alpha'] == true", "alpha branch enumeration")
        self.wait_screen("needle-alpha.lua")
        self.phase = "expand-alpha"
        alpha = self.lua("local s=_G.wb07_session; for id,n in pairs(s.nodes) do if n.payload and n.payload.raw_name=='alpha' then return id end end")
        alpha_names = self.lua("local args=...; local parent=args[1]; local s=_G.wb07_session; local out={}; for _,id in ipairs(s.children[parent] or {}) do local n=s.nodes[id]; if n and n.payload then out[n.payload.raw_name]=n.kind end end; return out", alpha)
        if "nested-ignored.txt" in alpha_names or "alpha-ignored" in alpha_names:
            raise AssertionError(f"nested .gitignore was not applied to alpha: {alpha_names}")

        # Use a real grid mouse event to select beta, then keyboard-expand it.
        screen = self.grid.lines()
        beta_row = next(index for index, line in enumerate(screen) if " beta" in line or line.rstrip().endswith("beta"))
        beta_col = screen[beta_row].index("beta")
        self.control.api.input_mouse("left", "press", "", 0, beta_row, beta_col)
        self.control.api.input_mouse("left", "release", "", 0, beta_row, beta_col)
        self.wait_lua("_G.wb07_session.nodes[_G.wb07_session.selected_id].payload.raw_name == 'beta'", "mouse selection of beta")
        self.control.api.input("l")
        beta = self.lua("local s=_G.wb07_session; for id,n in pairs(s.nodes) do if n.payload and n.payload.raw_name=='beta' then return id end end")
        self.wait_lua("_G.wb07_session.loaded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta'] == true", "beta branch enumeration")
        self.wait_screen("needle-beta.lua")
        self.phase = "expand-beta"
        beta_file = self.lua("local s=_G.wb07_session; for id,n in pairs(s.nodes) do if n.payload and n.payload.raw_name=='needle-beta.lua' then return id end end")

        self.control.api.input("y")
        absolute_copy = self.lua("return vim.fn.getreg('" + '"' + "')")
        self.control.api.input("Y")
        relative_copy = self.lua("return vim.fn.getreg('" + '"' + "')")
        self.control.api.input("s")
        folder_search = self.lua("return _G.wb07_search")
        expected_root_path = str(self.workspace.resolve())
        expected_beta_path = str((self.workspace / "beta").resolve())
        if absolute_copy != expected_beta_path or relative_copy != "beta":
            raise AssertionError(f"Files path-copy actions returned incorrect paths: absolute={absolute_copy!r}, relative={relative_copy!r}")
        if not folder_search or folder_search["root"] != expected_root_path or folder_search["scope"] != expected_beta_path:
            raise AssertionError(f"Files search-in-folder action returned the wrong scope: {folder_search}")

        # Explicit r/R refreshes update the selected branch and workspace root.
        assert self.workspace is not None
        (self.workspace / "beta" / "manual-refresh.lua").write_text("branch refresh\\n", encoding="utf-8")
        self.control.api.input("r")
        self.wait_lua("_G.wb07_session.nodes and (function() for _,n in pairs(_G.wb07_session.nodes) do if n.payload and n.payload.raw_name=='manual-refresh.lua' then return true end end end)()", "selected-directory refresh")
        self.wait_screen("manual-refresh.lua")
        (self.workspace / "root-manual-refresh.lua").write_text("root refresh\\n", encoding="utf-8")
        self.control.api.input("R")
        self.wait_lua("(function() for _,n in pairs(_G.wb07_session.nodes) do if n.payload and n.payload.raw_name=='root-manual-refresh.lua' then return true end end end)()", "workspace-root refresh")

        # Filter is explicitly local to loaded branches and clearing restores expansion.
        self.lua("local v=_G.wb07_view; _G.wb07_expanded_before=vim.deepcopy(v.expanded)")
        self.lua("assert(_G.wb07_controller:set_filter('needle-beta.lua'))")
        filtered = self.lua("local args=...; local target=args[1]; local v=_G.wb07_view; local found=false; local ids={}; for _,row in ipairs(v.rows) do ids[#ids+1]=row.id; if row.id==target then found=true end end; return {found=found,title=v.title,count=#v.rows,ids=ids,target=target}", beta_file)
        if not filtered["found"] or "loaded tree filter" not in filtered["title"]:
            raise AssertionError(f"loaded-tree filtering did not preserve the matching row: {filtered}")
        self.lua("assert(_G.wb07_controller:set_filter(''))")
        self.phase = "filter"
        filter_restore = self.lua("local v=_G.wb07_view; return v.expanded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/alpha']==_G.wb07_expanded_before['file:' .. _G.wb07_snapshot.roots[1].uri .. '/alpha'] and v.expanded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta']==_G.wb07_expanded_before['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta']")
        if not filter_restore:
            raise AssertionError("clearing the Files filter did not restore saved branch expansion")
        self.wait_screen("alpha.lua")
        self.wait_screen("readme.md")

        # The real Enter action opens into the originating editor window.
        screen = self.grid.lines()
        file_row = next(index for index, line in enumerate(screen) if "needle-beta.lua" in line)
        file_col = screen[file_row].index("needle-beta.lua")
        self.control.api.input_mouse("left", "press", "", 0, file_row, file_col)
        self.control.api.input_mouse("left", "release", "", 0, file_row, file_col)
        try:
            self.wait_lua("_G.wb07_session.nodes[_G.wb07_session.selected_id].payload.raw_name == 'needle-beta.lua'", "mouse select beta file")
        except TimeoutError as error:
            state = self.lua(f"local v=_G.wb07_view; local s=_G.wb07_session; return {{selected=s.selected_id,node=s.nodes[s.selected_id],current=vim.api.nvim_get_current_win(),window=v.window,cursor=vim.api.nvim_win_get_cursor(v.window),mode=vim.api.nvim_get_mode().mode,click={{row={file_row},col={file_col}}}}}")
            raise RuntimeError(f"{error}; mouse state {state}") from error
        self.control.api.input("\r")
        self.phase = "open-file"
        self.wait_lua("vim.api.nvim_get_current_win() == _G.wb07_origin_win", "focus returned to editor after opening file")
        opened = self.lua("local b=vim.api.nvim_win_get_buf(_G.wb07_origin_win); return {name=vim.api.nvim_buf_get_name(b),modified=vim.bo[_G.wb07_origin_buf].modified,origin=vim.api.nvim_buf_is_valid(_G.wb07_origin_buf),line=vim.api.nvim_buf_get_lines(_G.wb07_origin_buf,0,1,false)[1],save_hooks=#vim.api.nvim_get_autocmds({event='BufWritePost',buffer=b})}")
        if not opened["name"].endswith("beta/needle-beta.lua") or not opened["modified"] or not opened["origin"] or opened["line"] != "USER OWNED CONTENT" or opened["save_hooks"] != 1:
            raise AssertionError(f"file open damaged editor state or missed scoped save invalidation: {opened}")
        self.lua("vim.api.nvim_exec_autocmds('BufWritePost',{buffer=vim.api.nvim_win_get_buf(_G.wb07_origin_win)}); vim.api.nvim_set_current_win(_G.wb07_view.window)")

        # Policy controls are delegated to the shared policy updater and re-enumerate.
        self.phase = "policy-toggle"
        self.control.api.input("H")
        self.wait_lua("_G.wb07_session.workspace.policy.hidden == 'include' and _G.wb07_session.loaded[_G.wb07_session.root_id] == true", "hidden policy update")
        hidden_on = self._names()
        if ".secret" not in hidden_on:
            raise AssertionError("hidden toggle did not reveal dot files")
        self.control.api.input("H")
        self.wait_lua("_G.wb07_session.workspace.policy.hidden == 'exclude' and _G.wb07_session.loaded[_G.wb07_session.root_id] == true", "hidden policy restore")
        self.control.api.input("I")
        self.wait_lua("_G.wb07_session.workspace.policy.ignored == 'include' and _G.wb07_session.loaded[_G.wb07_session.root_id] == true", "ignored policy update")
        ignored_on = self._names()
        if "git-ignored" not in ignored_on or "shared-ignored" not in ignored_on or "empty-ignored" not in ignored_on:
            raise AssertionError(f"ignored toggle failed to expose deliberately handled empty/non-empty ignored dirs: {ignored_on}")
        self.control.api.input("I")
        self.wait_lua("_G.wb07_session.workspace.policy.ignored == 'exclude' and _G.wb07_session.loaded[_G.wb07_session.root_id] == true", "ignored policy restore")
        if "git-ignored" in self._names() or "shared-ignored" in self._names():
            raise AssertionError("ignored paths remained visible after the shared policy was restored")

        # Stable reveal selects a known path without changing cwd; outside paths fail with an actionable root action.
        self.phase = "reveal"
        reveal = self.lua("local args=...; local s=_G.wb07_session; local ok,err=_G.wb07_controller:reveal(args[1]); return {ok=ok,code=err and err.code,selected=s.selected_id}", str(self.workspace.resolve() / "beta" / "needle-beta.lua"))
        if not reveal["ok"] or reveal["selected"] != beta_file:
            raise AssertionError(f"reveal did not select the stable file ID: {reveal}")
        outside = self.lua("local args=...; local ok,err=_G.wb07_controller:reveal(args[1]); return {ok=ok,code=err and err.code,action=err and err.action}", str((Path(self.fixture.name) / "outside.txt").resolve()))
        if outside.get("ok") is not None or outside["code"] != "outside_root" or outside["action"] != "select_root":
            raise AssertionError(f"outside-root reveal did not offer explicit root selection: {outside}")

        # Vanished directories show a retryable error rather than a false empty state.
        self.phase = "vanished"
        vanish = self.workspace.resolve() / "vanish"
        shutil.rmtree(vanish)
        refresh = self.lua("local args=...; local path=args[1]; _G.wb07_provider:invalidate(path); local request,err=_G.wb07_controller:refresh(path); return {ok=request~=nil,error=err and err.code}", str(vanish))
        if not refresh["ok"]:
            raise AssertionError("could not refresh a vanished directory row")
        self.wait_lua("_G.wb07_session.last_error and _G.wb07_session.last_error.code == 'directory_vanished'", "vanished directory error")

        # A second tab gets an independent session; switching tabs preserves both branches and selection.
        self.phase = "tabs"
        self.control.command("tabnew")
        self.lua("vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), _G.wb07_origin_buf)")
        second_tab = self.lua("_G.wb07_tab2=vim.api.nvim_get_current_tabpage(); local view,err=_G.wb07_controller:open(_G.wb07_snapshot,{focus=false}); _G.wb07_view2=view; for _,s in pairs(_G.wb07_controller.sessions) do if s.tab==_G.wb07_tab2 then _G.wb07_session2=s end end; return {ok=view~=nil,code=err and err.code,message=err and err.message,tab=vim.api.nvim_get_current_tabpage(),layout=_G.wb07_layout:status(),sessions=_G.wb07_controller:status()}")
        if not second_tab["ok"]:
            raise AssertionError(f"could not open isolated Files session in new tab: {second_tab}")
        self.wait_lua("_G.wb07_session2.loaded[_G.wb07_session2.root_id] == true", "second-tab root enumeration")
        self.lua("_G.wb07_session2.selected_id=_G.wb07_session2.root_id; _G.wb07_view2.selected_id=_G.wb07_session2.root_id")
        self.control.command("tabprevious")
        self.lua("_G.wb07_session=_G.wb07_controller.sessions[_G.wb07_session.key]")
        tab_isolation = self.lua("local args=...; return _G.wb07_session.tab ~= _G.wb07_session2.tab and _G.wb07_session.selected_id == args[1] and _G.wb07_session.view.expanded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta'] == true", beta_file)
        if not tab_isolation:
            raise AssertionError("workspace tabs shared Files selection or expansion state")
        self.control.command("tabnext")
        self.control.command("tabclose")
        try:
            self.wait_lua("_G.wb07_controller:status().session_count == 1", "second-tab Files session disposal")
        except TimeoutError as error:
            status = self.lua("return {tab_valid=vim.api.nvim_tabpage_is_valid(_G.wb07_tab2),current_tab=vim.api.nvim_get_current_tabpage(),controller=_G.wb07_controller:status(),layout=_G.wb07_layout:status()}")
            raise RuntimeError(f"{error}; tab-close state {status}") from error
        self.control.command("tabprevious")

        # Close/reopen retains the loaded tree, selection and expansion state.
        self.phase = "reopen"
        before_close = self.lua("return {selection=_G.wb07_session.view.selected_id, beta=_G.wb07_session.view.expanded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta']}")
        self.lua("vim.api.nvim_set_current_win(_G.wb07_view.window)")
        self.control.api.input("q")
        self.wait_lua("_G.wb07_session.view == nil", "Files view close")
        self.lua("_G.wb07_view=assert(_G.wb07_controller:open(_G.wb07_snapshot,{focus=false})); _G.wb07_session=_G.wb07_controller.sessions[_G.wb07_session.key]")
        after_open = self.lua("return {selection=_G.wb07_view.selected_id,beta=_G.wb07_view.expanded['file:' .. _G.wb07_snapshot.roots[1].uri .. '/beta'],loaded=_G.wb07_session.loaded[_G.wb07_session.root_id]}")
        if after_open["selection"] != before_close["selection"] or after_open["beta"] != before_close["beta"] or not after_open["loaded"]:
            raise AssertionError(f"Files state did not survive close/reopen: {before_close}, {after_open}")

        # Switching workspace roots invalidates stale nodes without replacing the editor buffer.
        self.phase = "root-change"
        other = Path(self.fixture.name) / "other-workspace"
        other.mkdir()
        (other / "other-root.txt").write_text("other root\n", encoding="utf-8")
        changed = self.lua("local args=...; local snap=assert(_G.wb07_workspace:open({explicit_root=args[1]})); assert(_G.wb07_controller:set_workspace(snap)); return snap.id", str(other))
        self.wait_lua("_G.wb07_session.loaded[_G.wb07_session.root_id] == true", "new workspace root enumeration")
        root_changed = self.lua("local s=_G.wb07_session; local found=false; local stale=false; for _,n in pairs(s.nodes) do if n.payload and n.payload.raw_name=='other-root.txt' then found=true end; if n.payload and n.payload.raw_name=='needle-beta.lua' then stale=true end end; return {id=s.workspace.id,found=found,stale=stale,modified=vim.bo[_G.wb07_origin_buf].modified}")
        if root_changed["id"] != changed or not root_changed["found"] or root_changed["stale"] or not root_changed["modified"]:
            raise AssertionError(f"root change retained stale filesystem rows or damaged editor state: {root_changed}")

        status = self.lua("local s=_G.wb07_controller:status(); local l=_G.wb07_layout:status(); return {controller=s,layout=l}")
        owned_view_buffers = [view["buffer"] for view in status["layout"]["views"]]
        self.lua("_G.wb07_controller:dispose(); _G.wb07_provider:dispose(); _G.wb07_layout:dispose()")
        final = self.lua("local args=...; local owned={}; for _,buffer in ipairs(args[1]) do owned[#owned+1]=vim.api.nvim_buf_is_valid(buffer) end; return {buffer=vim.api.nvim_buf_is_valid(_G.wb07_origin_buf),modified=vim.bo[_G.wb07_origin_buf].modified,line=vim.api.nvim_buf_get_lines(_G.wb07_origin_buf,0,1,false)[1],cwd=vim.fn.getcwd()==_G.wb07_cwd,owned_view_buffers=owned,controller=_G.wb07_controller:status(),provider=_G.wb07_provider:status(),layout=_G.wb07_layout:status()}", owned_view_buffers)
        if not final["buffer"] or not final["modified"] or final["line"] != "USER OWNED CONTENT" or not final["cwd"]:
            raise AssertionError(f"Files teardown damaged editor-owned state: {final}")
        if final["controller"]["session_count"] != 0 or not final["provider"]["disposed"] or final["provider"]["active_requests"] != 0 or final["provider"]["cache_directories"] != 0:
            raise AssertionError(f"Files teardown retained controller/provider state: {final}")
        if final["layout"]["active_views"] != 0 or final["layout"]["resources"]["resource_count"] != 0 or any(final["owned_view_buffers"]):
            raise AssertionError(f"Files teardown retained UI resources: {final}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "sidebar_mode": layout_mode,
            "first_interactive_view_ms": round(self.first_view_ms, 3),
            "root_policy_exclusions": ["hidden files", ".git", ".gitignore", ".ignore", ".gitignore ignored directory", ".ignore ignored directory", "empty ignored directory"],
            "unsupported_ignore_sources_reported": policy_limitations,
            "raw_path_display": "line\\x0Abreak.txt; raw newline retained in payload",
            "keyboard_expand": True,
            "mouse_select": True,
            "context_actions": {
                "absolute_copy": absolute_copy,
                "relative_copy": relative_copy,
                "search_folder": folder_search,
                "selected_directory_refresh": "manual-refresh.lua appeared after r",
                "workspace_root_refresh": "root-manual-refresh.lua appeared after R",
            },
            "independent_branches": True,
            "filter_clear_restores_expansion": filter_restore,
            "file_open_focus_return": opened,
            "save_invalidation_buffer_hooks": opened["save_hooks"],
            "hidden_toggle": ".secret appeared only while included",
            "ignored_toggle": "gitignored, .ignore and empty ignored dirs appeared only while included",
            "external_symlink_nonfollowed": not self.symlinks["external-link"] or root_names.get("external-link", {}).get("expandable") is False,
            "nested_cycle_stops": not self.symlinks["nested-cycle"] or alpha_names.get("cycle-link") == "symlink_cycle",
            "inside_root_reveal": reveal,
            "outside_root_reveal": outside,
            "vanished_directory": "directory_vanished retryable error shown",
            "tab_isolation": tab_isolation,
            "close_reopen_state": {"before": before_close, "after": after_open},
            "root_change": root_changed,
            "cwd_unchanged": final["cwd"],
            "teardown": {
                "controller_sessions": final["controller"]["session_count"],
                "provider_active_requests": final["provider"]["active_requests"],
                "provider_cache_directories": final["provider"]["cache_directories"],
                "layout_active_views": final["layout"]["active_views"],
                "layout_resources": final["layout"]["resources"]["resource_count"],
                "owned_view_buffers_released": not any(final["owned_view_buffers"]),
            },
            "layout_resources_before_dispose": status["layout"]["resources"]["resource_count"],
            "provider_cache_before_dispose": status["controller"]["provider"]["cache_directories"],
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
        name = "failure.json" if self.failure else "result.json"
        (self.output / name).write_text(json.dumps(metadata, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb07")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = Run(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-07 Files UI failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
