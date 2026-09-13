#!/usr/bin/env python3
"""Exercise Workbench through the actual nvim-config host mappings and commands."""
from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tests.e2e.driver import PLUGIN_ROOT, ProbeRun, host_config_root, parse_grids


class HostRun(ProbeRun):
    def __init__(self, nvim: str, cols: int, rows: int, output: Path):
        super().__init__(nvim, cols, rows, "wb25-host", output, host=True)

    def _child_args(self, socket_path: str, xdg: Path, log: Path) -> list[str]:
        config = host_config_root()
        if config is None:
            raise RuntimeError("the actual nvim-config host checkout could not be located")
        return [
            self.nvim, "-u", str(config / "init.lua"), "-i", "NONE", "-n",
            "--headless", "--listen", socket_path, "--startuptime", str(log),
            "--cmd", f"set lines={self.rows} columns={self.cols}",
        ]

    def _exercise(self) -> dict[str, object]:
        assert self.control is not None
        self.grid.wait_for(lambda: self.grid.flushes > 0, 5.0, "host first UI frame")
        self.first_flush_at = time.monotonic()
        self.origin_buffer = self.control.api.get_current_buf()
        self.origin_buf = int(self.origin_buffer.handle)
        self.origin_win = int(self.control.api.get_current_win().handle)
        self.control.api.buf_set_lines(self.origin_buffer, 0, -1, False, ["HOST OWNED UNSAVED TEXT"])
        self.control.api.buf_set_option(self.origin_buffer, "modified", True)

        workspace = self.output / "workspace"
        workspace.mkdir()
        (workspace / "note.txt").write_text("host workspace needle\nsecond needle\n", encoding="utf-8")
        (workspace / ".hidden.txt").write_text("hidden workspace needle\n", encoding="utf-8")
        (workspace / "follow.txt").write_text("follow target\n", encoding="utf-8")
        for index in range(100):
            (workspace / f"zz-scroll-{index:03d}.txt").write_text("scroll fixture\n", encoding="utf-8")
        self.control.exec_lua("local root=...; vim.cmd.tcd({args={root}})", str(workspace))
        before = self.control.exec_lua("return require('workbench').get_status()")
        self._assert(before["state"] == "disabled" and not before.get("runtime"), f"unexpected eager Workbench state: {before}")

        self.control.api.input(":Workbench enable\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return require('workbench').get_status().state") == "enabled",
            3.0, "explicit enable command",
        )
        mappings = self.control.exec_lua(
            "local f=vim.fn.maparg('<leader>W','n',false,true); local s=vim.fn.maparg('<leader>/','n',false,true); "
            "local q=vim.fn.maparg('<leader>f','n',false,true); "
            "return {f={lhs=f.lhs,desc=f.desc},s={lhs=s.lhs,desc=s.desc},quick=q.lhs}"
        )
        self._assert(mappings["f"].get("desc") == "Workbench: open Files", f"Files map missing: {mappings}")
        self._assert(mappings["s"].get("desc") == "Workbench: open Search", f"Search map missing: {mappings}")
        self._assert(bool(mappings["quick"]), "the existing Space f quick file picker mapping was removed")

        self.input_at = time.monotonic()
        self.control.api.input(" W")
        self.grid.wait_for(lambda: any("note.txt" in line for line in self.grid.lines()), 5.0, "Files enumeration")
        self.input_flush_at = time.monotonic()
        files_frame = self.grid.snapshot()
        current = self.control.api.get_current_buf()
        self._assert(self.control.api.buf_get_option(current, "filetype") == "workbench", "Files did not focus its view")

        self.control.api.input(":silent tcd ..\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return vim.fn.getcwd()") != str(workspace),
            3.0, "cwd change after selecting the workspace",
        )
        self.control.api.input(" /")
        self.grid.wait_for(lambda: "Search" in "\n".join(self.grid.lines()), 4.0, "Search mapping")
        self.control.api.input("/")
        self.grid.wait_for(lambda: "Search workspace:" in "\n".join(self.grid.lines()), 3.0, "query prompt")
        self.control.api.input("needle\n")
        def search_state() -> dict[str, object]:
            return self.control.exec_lua(
                "local s=require('workbench').get_status().runtime; local active=s.search.sessions[1]; "
                "local buffer; for _,view in ipairs(s.layout.views) do if view.id=='workbench-search' then buffer=view.buffer end end; "
                "return {query=active and active.query,phase=active and active.phase,buffer=buffer,"
                "lines=buffer and vim.api.nvim_buf_get_lines(buffer,0,-1,false) or {}}"
            )

        def search_completed() -> bool:
            state = search_state()
            return bool(
                state["query"] == "needle"
                and state["phase"] == "Complete"
                and any("host workspace needle" in line for line in state["lines"])
            )
        self.grid.wait_for(
            search_completed,
            5.0, "real ripgrep result",
        )
        rendered_search = search_state()
        self._assert(
            self.control.exec_lua(
                "local expected=...; local s=require('workbench').get_status(); "
                "local w=s.runtime.workspaces[vim.api.nvim_get_current_tabpage()]; "
                "return w and w.roots[1].path==(vim.uv or vim.loop).fs_realpath(expected)", str(workspace)
            ),
            "opening Search replaced the tab's chosen workspace with cwd",
        )
        search_frame = self.grid.snapshot()
        self._assert(
            self.control.api.buf_get_option(self.control.api.get_current_buf(), "filetype") == "workbench",
            "Search did not focus its view",
        )

        search_generation = self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].generation")
        self.control.api.input(":lua assert(require('workbench').setup({preview={enabled=false},sidebar={width=24,position='right'}}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua(
                "local s=require('workbench').get_status(); local disabled=false; "
                "for _,v in ipairs(s.settings) do if v.path=='preview.enabled' then disabled=v.effective==false end end; "
                "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.b[vim.api.nvim_win_get_buf(w)].workbench_preview then return false end end; "
                "for _,v in ipairs(s.runtime.layout.views) do if v.id=='files' and v.mode=='split' then "
                "if vim.api.nvim_win_get_width(v.window)~=24 or vim.api.nvim_win_get_position(v.window)[2]==0 then return false end end end; return disabled"
            ),
            4.0, "live preview disable and sidebar geometry",
        )
        self.control.api.input(":lua assert(require('workbench').setup({preview={enabled=true}}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua(
                "for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.b[vim.api.nvim_win_get_buf(w)].workbench_preview then return true end end; return false"
            ),
            4.0, "live preview re-enable",
        )
        self._assert(
            self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].generation") == search_generation,
            "changing preview or sidebar settings restarted Search",
        )
        for cap, phase in ((1, "Partial"), (2, "Complete")):
            self.control.api.input(f":lua assert(require('workbench').setup({{search={{max_results={cap},debounce_ms=0}}}}))\n")
            self.grid.wait_for(
                lambda: self.control.exec_lua(
                    "local s=require('workbench').get_status().runtime.search.sessions[1]; "
                    "local phase,generation=...; return s.phase==phase and s.generation>generation and not s.request_active",
                    phase, search_generation,
                ),
                4.0, f"live Search limit {cap}",
            )
            self._assert(
                self.control.exec_lua(
                    "local text=table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(),0,-1,false),'\\n'); "
                    "return text:find(...,1,true)~=nil", phase,
                ),
                f"Search did not render {phase} after changing its limit",
            )
            search_generation = self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].generation")
        for hidden in (True, False):
            value = "true" if hidden else "false"
            self.control.api.input(f":lua assert(require('workbench').setup({{search={{max_results=3,hidden={value}}}}}))\n")
            self.grid.wait_for(
                lambda: self.control.exec_lua(
                    "local expected,generation=...; local s=require('workbench').get_status().runtime.search.sessions[1]; "
                    "if s.phase~='Complete' or s.generation<=generation then return false end; "
                    "local text=table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(),0,-1,false),'\\n'); "
                    "return (text:find('.hidden.txt',1,true)~=nil)==expected", hidden, search_generation,
                ),
                4.0, f"live hidden policy {value}",
            )
            search_generation = self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].generation")
        alternate = self.output / "alternate-workspace"
        alternate.mkdir()
        (alternate / "alternate.txt").write_text("alternate needle\n", encoding="utf-8")
        self.control.exec_lua("vim.g.wb_alternate_root=...", str(alternate))
        self.control.api.input(
            ":silent lua local w=require('workbench'); local before=w.get_status().runtime.workspaces; local buf=vim.api.nvim_get_current_buf(); "
            "local v=require('workbench.ui.view'); local make=v.new; v.new=function() return nil,'injected create failure' end; "
            "local opened,err=w.open('search',{root=vim.g.wb_alternate_root,query='needle'}); v.new=make; "
            "assert(not opened and err.code=='view_create_failed'); assert(vim.deep_equal(before,w.get_status().runtime.workspaces)); "
            "assert(buf==vim.api.nvim_get_current_buf()); vim.g.wb_search_failure_preserved=true\n"
        )
        self.grid.wait_for(lambda: self.control.exec_lua("return vim.g.wb_search_failure_preserved==true"), 4.0, "failed root replacement preserves Search")
        self.control.api.input(":silent lua assert(require('workbench').open('search',{root=vim.g.wb_alternate_root,query='needle'}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].phase=='Complete' and table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('alternate.txt',1,true)~=nil"),
            4.0, "retry root replacement with real rg results",
        )
        self.control.exec_lua("vim.g.wb_original_root=...", str(workspace))
        self.control.api.input(":silent lua assert(require('workbench').open('search',{root=vim.g.wb_original_root,query='needle'}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return require('workbench').get_status().runtime.search.sessions[1].phase=='Complete' and table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('note.txt',1,true)~=nil"),
            4.0, "return to original workspace results",
        )
        self.control.api.input(":silent lua assert(require('workbench').open('files',{root=vim.g.wb_alternate_root}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('alternate.txt',1,true)~=nil"),
            4.0, "Files renders alternate root",
        )
        self.control.api.input(":silent lua assert(require('workbench').open('files',{root=vim.g.wb_original_root}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('zz-scroll-000.txt',1,true)~=nil"),
            4.0, "Files replaces alternate root with original root",
        )
        self.control.api.input(":silent lua assert(require('workbench').open('search',{root=vim.g.wb_original_root,query='needle'}))\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return vim.api.nvim_buf_get_name(0):find('workbench%-search')~=nil and require('workbench').get_status().runtime.search.sessions[1].phase=='Complete'"),
            4.0, "Search ready for action discovery",
        )
        self._assert(self.control.exec_lua("return package.loaded['workbench.controllers.problems']==nil"), "Problems loaded before discovery")
        self.control.api.input("P")
        self.grid.wait_for(lambda: self.control.exec_lua("return vim.api.nvim_buf_get_name(0):find('workbench%-palette')~=nil"), 4.0, "shared action palette")
        self.control.api.input("/")
        self.grid.wait_for(lambda: self.control.exec_lua("return vim.fn.getcmdtype()=='@'"), 4.0, "action filter prompt")
        self.control.api.input("problems.open\r")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('Open reported Problems',1,true)~=nil"),
            4.0, "discover Problems before its first open",
        )
        self.control.api.input("\r")
        self.grid.wait_for(lambda: self.control.exec_lua("return vim.api.nvim_buf_get_name(0):find('workbench%-problems')~=nil"), 4.0, "execute discovered Problems action")
        for command, view_id in (("outline", "outline"), ("problems", "workbench-problems"), ("files", "files")):
            self.control.api.input(f":Workbench {command}\n")
            self.grid.wait_for(
                lambda: self.control.exec_lua(
                    "local expected=...; local count=0; local found=false; "
                    "for _,v in ipairs(require('workbench').get_status().runtime.layout.views) do "
                    "if v.placement=='sidebar' then count=count+1; found=v.id==expected and vim.api.nvim_get_current_win()==v.window end end; "
                    "return count==1 and found", view_id,
                ),
                4.0, f"public sidebar switch to {command}",
            )
        self.grid.wait_for(
            lambda: self.control.exec_lua("return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),' '):find('zz-scroll-000.txt',1,true)~=nil"),
            4.0, "Files directory rows loaded after root changes",
        )
        self.control.api.input("j" * 69)
        self.grid.wait_for(
            lambda: self.control.exec_lua(
                "local s=require('workbench').get_status().runtime.files.sessions[1]; "
                "return s.selection and s.selection:find('zz-scroll-',1,true)~=nil"
            ),
            4.0, "manual Files scrolling",
        )
        scrolled = self.control.exec_lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)")
        scrolled_buffer = self.control.exec_lua("return vim.api.nvim_get_current_buf()")
        self.control.api.input("q:Workbench files\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua("return vim.api.nvim_get_current_buf()") != scrolled_buffer
            and self.control.exec_lua("return vim.api.nvim_buf_get_lines(0,0,-1,false)") == scrolled,
            4.0, "Files restores rendered scroll position",
        )
        self.control.api.input(":lua assert(require('workbench').setup({sidebar={views={'files','problems','outline'}}}))\n")
        for keys, view_id in (("]v", "workbench-problems"), ("]v", "outline"), ("[v", "workbench-problems")):
            self.control.api.input(keys)
            self.grid.wait_for(
                lambda: self.control.exec_lua(
                    "local expected=...; local count=0; local found=false; "
                    "for _,v in ipairs(require('workbench').get_status().runtime.layout.views) do "
                    "if v.placement=='sidebar' then count=count+1; found=v.id==expected and vim.api.nvim_get_current_win()==v.window end end; "
                    "return count==1 and found", view_id,
                ),
                4.0, f"configured sidebar order with {keys}",
            )
        self.control.api.input(":Workbench files\n")
        self.control.api.input(":lua assert(require('workbench').setup({sidebar={views={'files'}}}))\n")
        self.control.api.input(
            ":lua local w=require('workbench'); local before=w.get_status().runtime; "
            "local win=vim.api.nvim_get_current_win(); local v,e=w.open('outline',{root=vim.fn.getcwd()}); "
            "assert(not v and e.code=='view_disabled'); local after=w.get_status().runtime; "
            "assert(vim.deep_equal(before.workspaces,after.workspaces)); "
            "assert(vim.deep_equal(before.layout,after.layout)); "
            "assert(win==vim.api.nvim_get_current_win()); vim.g.wb_rejected_root=true\n"
        )
        self.grid.wait_for(
            lambda: self.control.exec_lua("return vim.g.wb_rejected_root==true"),
            4.0, "disabled view preserves workspace and mounted UI",
        )
        self.control.api.input(":lua assert(require('workbench').setup({sidebar={follow_active_file=true}}))\n")
        target = self.control.exec_lua("return vim.fn.fnameescape(...)", str(workspace / "follow.txt"))
        self.control.api.input(f":split {target}\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua(
                "local s=require('workbench').get_status().runtime.files.sessions[1]; "
                "return s.selection and s.selection:find('follow.txt',1,true)~=nil "
                "and vim.api.nvim_buf_get_name(0):find('follow.txt',1,true)~=nil"
            ),
            4.0, "Files follows editor without taking focus",
        )
        self.control.api.input(":close\n")
        self.control.api.input(":Workbench disable\n")
        self.grid.wait_for(
            lambda: self.control.exec_lua(
                "local s=require('workbench').get_status(); return s.state=='disabled' and s.runtime==nil"
            ),
            4.0, "disable cleanup",
        )
        self._assert(self.control.api.get_current_buf().handle == self.origin_buf, "disable did not restore the user's buffer")
        self._assert(self.control.api.get_current_win().handle == self.origin_win, "disable did not restore the user's window")
        self._assert(self.control.api.get_current_line() == "HOST OWNED UNSAVED TEXT", "modified editor text changed")
        self._assert(self.control.api.buf_get_option(self.origin_buffer, "modified"), "modified state was cleared")
        return {
            "default_state": before["state"],
            "default_runtime_created": bool(before.get("runtime")),
            "files_map": mappings["f"].get("desc"),
            "search_map": mappings["s"].get("desc"),
            "quick_file_picker_preserved": bool(mappings["quick"]),
            "files_rendered_note": any("note.txt" in line for line in files_frame["text"]),
            "search_rendered_result": any(
                "host workspace needle" in line for line in rendered_search["lines"]
            ) and "Search" in "\n".join(search_frame["text"]),
            "disable_released_runtime": True,
            "live_preview_and_sidebar_settings": True,
            "live_search_limits": True,
            "live_hidden_policy": True,
            "follow_active_file_preserves_focus": True,
            "public_sidebar_switching": True,
            "problems_discovered_before_first_open": True,
            "search_root_replacement_failure_and_retry": True,
            "files_root_replacement": True,
            "configured_sidebar_order": True,
            "files_scroll_restored": True,
            "disabled_view_preserves_workspace": True,
            "workspace_retained_after_cwd_change": True,
            "modified_origin_preserved": True,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    args = parser.parse_args()
    base = PLUGIN_ROOT / ".test-output" / "e2e" / "wb25"
    base.mkdir(parents=True, exist_ok=True)
    results = []
    for cols, rows in parse_grids(args.grid_sizes):
        output = base / f"local-{cols}x{rows}-{secrets.token_hex(3)}"
        result = HostRun(args.nvim, cols, rows, output).run()
        result.update({"cols": cols, "rows": rows, "output": str(output.relative_to(PLUGIN_ROOT))})
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        results.append(result)
        print(f"WB25 host {cols}x{rows}: {output}")
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
