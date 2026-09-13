#!/usr/bin/env python3
"""Exercise semantic themes and keyboard/mouse usability in a real Nvim grid."""

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
HOST_ROOT = ROOT.parents[3]
THEMEKIT_ROOT = HOST_ROOT / "pack" / "plugins" / "start" / "themekit.nvim"
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import Grid, parse_grids  # noqa: E402


class Editor:
    def __init__(self, nvim: str, cols: int, rows: int, xdg: Path, output: Path):
        self.nvim, self.cols, self.rows = nvim, cols, rows
        self.xdg, self.output = xdg, output
        self.socket = f"/tmp/wb24-{secrets.token_hex(8)}.sock"
        self.proc: subprocess.Popen[str] | None = None
        self.control = None
        self.ui = None
        self.thread: threading.Thread | None = None
        self.grid = Grid()
        self.command: list[str] = []
        self.first_flush_ms: float | None = None

    def lua(self, source: str, *args):
        assert self.control is not None
        return self.control.exec_lua(source, list(args))

    def wait_lua(self, expression: str, description: str, timeout: float = 8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.lua(expression):
                return
            time.sleep(0.01)
        raise TimeoutError(f"timed out waiting for {description}: {expression}")

    def wait_screen(self, fragment: str, timeout: float = 8.0):
        self.grid.wait_for(lambda: any(fragment in line for line in self.grid.lines()), timeout, fragment)

    def start(self, cwd: Path):
        environment = os.environ.copy()
        environment.update({
            "XDG_CONFIG_HOME": str(self.xdg / "config"),
            "XDG_DATA_HOME": str(self.xdg / "data"),
            "XDG_STATE_HOME": str(self.xdg / "state"),
            "XDG_CACHE_HOME": str(self.xdg / "cache"),
            "GIT_CONFIG_NOSYSTEM": "1",
        })
        self.command = [
            self.nvim, "--clean", "--headless", "--listen", self.socket,
            "--cmd", f"set lines={self.rows} columns={self.cols}",
            "--cmd", f"set runtimepath^={THEMEKIT_ROOT}",
            "--cmd", f"set runtimepath^={ROOT}",
        ]
        started = time.perf_counter()
        self.proc = subprocess.Popen(self.command, cwd=cwd, env=environment, text=True,
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
        self.ui.ui_attach(self.cols, self.rows, rgb=self.cols != 80, ext_linegrid=True)
        self.thread = threading.Thread(target=self._ui_loop, daemon=True, name="wb24-theme-grid")
        self.thread.start()
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5, "initial Neovim grid")
        self.first_flush_ms = round((time.perf_counter() - started) * 1000, 3)
        self.control.api.set_option("mouse", "a")

    def _ui_loop(self):
        assert self.ui is not None
        try:
            self.ui.run_loop(lambda _method, _args: None, self.grid.notify)
        except (EOFError, OSError):
            return
        except Exception:
            with self.grid.condition:
                self.grid.callback_error = traceback.format_exc()
                self.grid.condition.notify_all()

    def close(self):
        if self.control is not None and self.proc is not None and self.proc.poll() is None:
            try:
                self.control.command("qa!")
            except Exception:
                pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2)
        self.control = None
        self.ui = None
        if self.thread is not None:
            self.thread.join(timeout=0.5)


def contrast_ratio(foreground: int, background: int) -> float:
    def luminance(rgb: int) -> float:
        channels = [((rgb >> shift) & 255) / 255 for shift in (16, 8, 0)]
        linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in channels]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    light, dark = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def run_one(nvim: str, cols: int, rows: int, output: Path) -> dict[str, Any]:
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="wb24-theme-") as temporary:
        base = Path(temporary)
        xdg = base / "xdg"
        for name in ("config", "data", "state", "cache"):
            (xdg / name).mkdir(parents=True)
        config = xdg / "config" / "nvim"
        (config / "themes").mkdir(parents=True)
        theme_sources = {
            "github_light": HOST_ROOT / "themes" / "github_light.toml",
            "dark_high_contrast": HOST_ROOT / "themes" / "dark_high_contrast.toml",
        }
        for name, source in theme_sources.items():
            shutil.copyfile(source, config / "themes" / f"{name}.toml")
        workspace = base / "workspace"
        editor_cwd = base / "unrelated-cwd"
        workspace.mkdir()
        editor_cwd.mkdir()
        (workspace / "alpha.txt").write_text("alpha\n", encoding="utf-8")
        (workspace / "folder").mkdir()
        (workspace / "folder" / "inside.txt").write_text("inside\n", encoding="utf-8")
        long_name = "long-界-" + ("filename-" * 18) + ".txt"
        (workspace / long_name).write_text("long name\n", encoding="utf-8")
        editor = Editor(nvim, cols, rows, xdg, output)
        phases: dict[str, Any] = {}
        try:
            editor.start(editor_cwd)
            root = str(workspace.resolve())
            setup_started = time.perf_counter_ns()
            initial = editor.lua(
                "local args=...; local workbench_root,themekit_root,probe_file,root=args[1],args[2],args[3],args[4]; "
                "vim.opt.runtimepath:prepend(themekit_root); vim.opt.runtimepath:prepend(workbench_root); "
                "vim.o.hidden=true; vim.o.termguicolors=false; vim.o.mouse='a'; "
                "assert(dofile(probe_file).run()); "
                "local Workspace=require('workbench.services.workspace'); _G.wb24_workspace=assert(Workspace.new({"
                "root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},"
                "ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='internal',include={},exclude={}} end}})); "
                "_G.wb24_snapshot=assert(_G.wb24_workspace:open({explicit_root=root})); "
                "_G.wb24_layout=require('workbench.ui.layout').new(); local provider=assert(require('workbench.providers.filesystem').new()); "
                "local enumerate=provider.enumerate; provider.wb24_enumerations=0; provider.enumerate=function(self,...) self.wb24_enumerations=self.wb24_enumerations+1; return enumerate(self,...) end; _G.wb24_provider=provider; "
                "_G.wb24_controller=assert(require('workbench.controllers.files').new({layout=_G.wb24_layout,provider=provider})); "
                "_G.wb24_view=assert(_G.wb24_controller:open(_G.wb24_snapshot,{focus=true})); "
                "for _,session in pairs(_G.wb24_controller.sessions) do _G.wb24_session=session end; "
                "local links={WorkbenchNormal='Normal',WorkbenchSelection='CursorLine',WorkbenchMuted='Comment',WorkbenchDirectory='Directory',WorkbenchLoading='MoreMsg'}; "
                "local valid=true; for name,target in pairs(links) do valid=valid and vim.api.nvim_get_hl(0,{name=name,link=true}).link==target end; "
                "_G.wb24_cwd=vim.fn.getcwd(); return {links=valid,window=_G.wb24_view.window,origin=_G.wb24_cwd,generation=_G.wb24_view.render_generation,selected=_G.wb24_view.selected_id}",
                str(ROOT), str(THEMEKIT_ROOT), str(THEMEKIT_ROOT / "tests" / "workbench_semantics.lua"), root,
            )
            editor.wait_lua("return _G.wb24_session.loaded[_G.wb24_session.root_id] == true", "root directory listing")
            editor.wait_screen(workspace.name)
            if not initial["links"]:
                raise AssertionError(f"standalone default semantic links missing: {initial}")
            phases["setup_ms"] = round((time.perf_counter_ns() - setup_started) / 1_000_000, 3)
            root_names = editor.lua("local s=_G.wb24_session; local out={}; for _,id in ipairs(s.children[s.root_id] or {}) do local n=s.nodes[id]; if n and n.payload then out[n.payload.raw_name]=n.id end end; return out")
            if set(root_names) != {"alpha.txt", "folder", long_name}:
                raise AssertionError(f"Files fixture was not projected as expected: {root_names}")
            editor.wait_screen("long-")
            long_rows = [line for line in editor.grid.lines() if "long-" in line]
            if not long_rows or not any("…" in line for line in long_rows):
                raise AssertionError(f"long filename did not truncate at {cols}x{rows}: {editor.grid.lines()}")
            if any(0xE000 <= ord(char) <= 0xF8FF for line in editor.grid.lines() for char in line):
                raise AssertionError("view emitted a private-use icon glyph without an icon dependency")
            if editor.lua("return vim.fn.getcwd()") != initial["origin"]:
                raise AssertionError("Files view changed the editor cwd")

            editor.lua("require('themekit.config').themes_dir=vim.fn.stdpath('config')..'/themes'")
            theme_baseline = editor.lua("return {generation=_G.wb24_view.render_generation,window=vim.api.nvim_get_current_win(),buffer=_G.wb24_view.buffer}")
            before_light_flushes = editor.grid.flushes
            light = editor.lua(
                "local args=...; local name=args[1]; local theme=assert(require('themekit.library').get_theme(name)); local started=(vim.uv or vim.loop).hrtime(); "
                "require('themekit.loader').apply(theme,name); return {name=name,elapsed_ms=((vim.uv or vim.loop).hrtime()-started)/1000000,"
                "selection=vim.api.nvim_get_hl(0,{name='WorkbenchSelection'}),normal=vim.api.nvim_get_hl(0,{name='WorkbenchNormal'}),window=vim.api.nvim_get_current_win()}",
                "github_light",
            )
            editor.grid.wait_for(lambda: editor.grid.flushes > before_light_flushes, 5, "light-theme repaint")
            (output / "light-grid.json").write_text(json.dumps(editor.grid.snapshot(), indent=2) + "\n", encoding="utf-8")
            light_contrast = editor.lua(
                "local sel=vim.api.nvim_get_hl(0,{name='WorkbenchSelection'}); local normal=vim.api.nvim_get_hl(0,{name='WorkbenchNormal'}); "
                "return {fg=sel.fg or normal.fg,bg=sel.bg or normal.bg}"
            )
            if not light_contrast["fg"] or not light_contrast["bg"]:
                raise AssertionError(f"light theme selection colors unavailable: {light_contrast}")
            light_ratio = contrast_ratio(light_contrast["fg"], light_contrast["bg"])
            if light_ratio < 4.5:
                raise AssertionError(f"light theme selection contrast {light_ratio:.2f}: {light_contrast}")
            before_dark_flushes = editor.grid.flushes
            dark = editor.lua(
                "local args=...; local name=args[1]; local theme=assert(require('themekit.library').get_theme(name)); local started=(vim.uv or vim.loop).hrtime(); "
                "require('themekit.loader').apply(theme,name); return {name=name,elapsed_ms=((vim.uv or vim.loop).hrtime()-started)/1000000,"
                "selection=vim.api.nvim_get_hl(0,{name='WorkbenchSelection'}),normal=vim.api.nvim_get_hl(0,{name='WorkbenchNormal'}),window=vim.api.nvim_get_current_win()}",
                "dark_high_contrast",
            )
            editor.grid.wait_for(lambda: editor.grid.flushes > before_dark_flushes, 5, "dark-theme repaint")
            (output / "dark-grid.json").write_text(json.dumps(editor.grid.snapshot(), indent=2) + "\n", encoding="utf-8")
            # Theme switches repaint the already-open view, not rebuild it.
            if dark["window"] != theme_baseline["window"] or editor.lua("return _G.wb24_view.render_generation") != theme_baseline["generation"]:
                raise AssertionError("theme switching recreated the view or rebuilt its rendered model")
            provider_state = editor.lua("return {calls=_G.wb24_provider.wb24_enumerations,loaded=_G.wb24_session.loaded[_G.wb24_session.root_id],rows=#_G.wb24_view.rows}")
            if provider_state["calls"] != 1 or not provider_state["loaded"]:
                raise AssertionError(f"theme switching restarted or invalidated the filesystem provider: {provider_state}")
            focus = editor.lua(
                "local sel=vim.api.nvim_get_hl(0,{name='WorkbenchSelection'}); local normal=vim.api.nvim_get_hl(0,{name='WorkbenchNormal'}); "
                "return {fg=sel.fg or normal.fg,bg=sel.bg or normal.bg,selection=sel,normal=normal,"
                "current=vim.api.nvim_get_current_win(),view=_G.wb24_view.window,selected=_G.wb24_view.selected_id}"
            )
            if not focus["fg"] or not focus["bg"]:
                raise AssertionError(f"selected-row foreground/background unavailable for contrast check: {focus}")
            ratio = contrast_ratio(focus["fg"], focus["bg"])
            if ratio < 4.5:
                raise AssertionError(f"dark theme selection contrast {ratio:.2f}: {focus}")
            if focus["current"] != focus["view"]:
                raise AssertionError(f"theme switch moved focus out of the view: {focus}")
            phases["themes"] = {
                "light": {"name": "github_light", "switch_ms": round(light["elapsed_ms"], 3)},
                "dark": {"name": "dark_high_contrast", "switch_ms": round(dark["elapsed_ms"], 3)},
                "selection_contrast_light": round(light_ratio, 2), "selection_contrast_dark": round(ratio, 2),
                "provider_enumerations_after_switch": provider_state["calls"],
                "selection_id_preserved": focus["selected"] == initial["selected"],
            }

            editor.control.api.input("j")
            editor.wait_lua("return _G.wb24_view.selected_id ~= nil and _G.wb24_view.selected_id ~= _G.wb24_session.root_id", "keyboard navigation to a child row")
            keyboard_selection = editor.lua("return {id=_G.wb24_view.selected_id,focus=vim.api.nvim_get_current_win()==_G.wb24_view.window}")
            if not keyboard_selection["focus"]:
                raise AssertionError(f"keyboard navigation lost panel focus: {keyboard_selection}")
            mouse_target = editor.lua(
                "local args=...; local v=_G.wb24_view; for _,row in ipairs(v.visible_rows) do if row.payload and row.payload.raw_name==args[1] then "
                "local line=v.visible_row_lines[row.id]; local pos=vim.fn.screenpos(v.window,line,7); "
                "return {id=row.id,row=pos.row-1,col=pos.col-1,line=line} end end; return nil", long_name,
            )
            phases["mouse_target_api"] = mouse_target
            if not mouse_target or mouse_target["row"] < 0 or mouse_target["col"] < 0:
                raise AssertionError(f"long file row has no valid mouse target: {mouse_target}")
            grid_row = next((index for index, line in enumerate(editor.grid.lines()) if "long-" in line), None)
            if grid_row is None:
                raise AssertionError("truncated long filename disappeared before mouse selection")
            grid_col = editor.grid.lines()[grid_row].index("long-") + 2
            phases["mouse_target_grid"] = {"row": grid_row, "col": grid_col}
            before_mouse_flushes = editor.grid.flushes
            editor.control.api.input_mouse("left", "press", "", 0, grid_row, grid_col)
            editor.control.api.input_mouse("left", "release", "", 0, grid_row, grid_col)
            editor.lua("local args=...; _G.wb24_expected_mouse_id=args[1]", long_name)
            editor.grid.wait_for(lambda: editor.grid.flushes > before_mouse_flushes, 2, "mouse-event grid update")
            mouse_debug = editor.lua(
                "local v=_G.wb24_view; return {expected=_G.wb24_expected_mouse_id,selected=v.selected_id,current=vim.api.nvim_get_current_win(),"
                "view=v.window,cursor=vim.api.nvim_win_get_cursor(v.window),target_line=v.visible_row_lines[_G.wb24_expected_mouse_id],"
                "target_row=v.row_by_line[v.visible_row_lines[_G.wb24_expected_mouse_id]],mode=vim.api.nvim_get_mode().mode}"
            )
            phases["mouse_after_input"] = mouse_debug
            if mouse_debug["selected"] != root_names[long_name]:
                raise AssertionError(f"mouse event did not select the rendered truncated row: {mouse_debug}, target={phases['mouse_target_grid']}")
            mouse_selection = editor.lua("return {id=_G.wb24_view.selected_id,focus=vim.api.nvim_get_current_win()==_G.wb24_view.window}")
            if mouse_selection["id"] != root_names[long_name] or not mouse_selection["focus"]:
                raise AssertionError(f"mouse target/focus mismatch: {mouse_selection}, target={mouse_target}")
            phases["input"] = {"keyboard_selected": keyboard_selection["id"], "mouse_selected": mouse_selection["id"], "focus_window": mouse_selection["focus"]}

            # Status copy is deliberately text-first so colorless terminals retain meaning.
            state_screens = {}
            for status, expected in (("loading", "Loading"), ("error", "Error: theme probe"), ("unavailable", "Unavailable: disabled")):
                editor.lua(
                    "local args=...; assert(_G.wb24_view:update({status=args[1],error=args[2],reason=args[3],items={}}))",
                    status, "theme probe" if status == "error" else None, "disabled" if status == "unavailable" else None,
                )
                editor.wait_screen(expected)
                state_screens[status] = expected
            editor.lua("vim.o.termguicolors=false; local names={'WorkbenchNormal','WorkbenchSelection','WorkbenchMuted','WorkbenchBorder','WorkbenchDirectory','WorkbenchMatch','WorkbenchError','WorkbenchWarning','WorkbenchInfo','WorkbenchGitAdded','WorkbenchGitModified','WorkbenchGitDeleted','WorkbenchDisabled','WorkbenchLoading'}; for _,name in ipairs(names) do vim.api.nvim_set_hl(0,name,{ctermfg=7,ctermbg=0}) end")
            monochrome = editor.lua(
                "local v=_G.wb24_view; assert(v:update({status='ready',items={{id='disabled',label='Disabled row [D]',selectable=false},{id='available',label='Available row [A]'}}})); "
                "return {rgb=vim.api.nvim_ui_get_rgb and vim.api.nvim_ui_get_rgb() or nil,termguicolors=vim.o.termguicolors,lines=vim.api.nvim_buf_get_lines(v.buffer,0,-1,false),disabled_line=v.visible_row_lines.disabled}"
            )
            editor.wait_screen("Disabled row [D]")
            editor.wait_screen("Available row [A]")
            if monochrome["termguicolors"] or not any("Disabled row [D]" in line for line in editor.grid.lines()):
                raise AssertionError(f"monochrome markers/state labels were not retained: {monochrome}")
            disabled_group = editor.lua(
                "local v=_G.wb24_view; local ns=vim.api.nvim_get_namespaces()['workbench.ui.view']; "
                "local marks=vim.api.nvim_buf_get_extmarks(v.buffer,ns,{v.visible_row_lines.disabled-1,0},{v.visible_row_lines.disabled,0},{details=true}); "
                "local result={}; for _,mark in ipairs(marks) do result[#result+1]=mark[4] end; return result"
            )
            phases["states"] = {"loading": state_screens["loading"], "error": state_screens["error"], "unavailable": state_screens["unavailable"],
                                "monochrome_disabled_row": "Disabled row [D]", "disabled_highlight_extmarks": disabled_group,
                                "termguicolors_in_monochrome": monochrome["termguicolors"], "no_icons": True}

            # Repeated view lifetimes must reuse loaded filesystem state and clean the layout hooks.
            editor.lua("assert(_G.wb24_view:update({status='ready',items=_G.wb24_controller:_all_items(_G.wb24_session)}))")
            for cycle in range(3):
                editor.control.api.input("q")
                editor.wait_lua("return _G.wb24_layout:status().active_views == 0", "view disposal")
                if cycle < 2:
                    editor.lua("_G.wb24_view=assert(_G.wb24_controller:open(_G.wb24_snapshot,{focus=true})); for _,s in pairs(_G.wb24_controller.sessions) do _G.wb24_session=s end")
                    editor.wait_screen("Files")
            final = editor.lua(
                "local before=_G.wb24_layout:status(); _G.wb24_controller:dispose(); _G.wb24_provider:dispose(); _G.wb24_layout:dispose(); "
                "return {layout_views=before.active_views,resources=before.resources.resource_count,provider_calls=_G.wb24_provider.wb24_enumerations,"
                "cwd=vim.fn.getcwd(),editor_cwd=_G.wb24_cwd,valid=vim.api.nvim_buf_is_valid(_G.wb24_view.buffer)}",
            )
            if final["layout_views"] != 0 or final["provider_calls"] != 1 or final["cwd"] != final["editor_cwd"]:
                raise AssertionError(f"theme/view lifecycle cleanup failed: {final}")
            snapshot = editor.grid.snapshot()
            (output / "grid.txt").write_text("\n".join(snapshot["text"]) + "\n", encoding="utf-8")
            (output / "grid.json").write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
            result = {
                "grid": f"{cols}x{rows}", "nvim": subprocess.run([nvim, "--version"], text=True, capture_output=True, check=True).stdout.splitlines()[0],
                "ui_rgb_capability": cols != 80, "first_frame_ms": editor.first_flush_ms,
                "view_mount_ms": phases["setup_ms"], "themes": phases["themes"], "input": phases["input"],
                "states": phases["states"], "provider_enumerations": final["provider_calls"],
                "three_view_lifecycles": True, "layout_active_views_after_close": final["layout_views"],
                "editor_cwd_preserved": final["cwd"] == final["editor_cwd"], "truncated_long_row": True,
                "theme_switch_did_not_rebuild_view_or_provider": True,
            }
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            return result
        except Exception as error:
            (output / "failure.json").write_text(json.dumps({"error": str(error), "traceback": traceback.format_exc(),
                "grid": editor.grid.snapshot(), "phases": phases, "command": editor.command}, indent=2) + "\n", encoding="utf-8")
            raise
        finally:
            editor.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb24")
    args = parser.parse_args()
    nvim = str(Path(args.nvim).resolve()) if Path(args.nvim).exists() else (shutil.which(args.nvim) or str(Path(args.nvim).resolve()))
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        try:
            print(json.dumps({"artifacts": str(output), **run_one(nvim, cols, rows, output)}, indent=2))
        except Exception as error:
            print(f"WB-24 theming UI failed at {cols}x{rows}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
