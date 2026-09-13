#!/usr/bin/env python3
"""Combined Files -> scoped Search -> preview/open/return/resume UI acceptance."""

from __future__ import annotations

import argparse
import json
import secrets
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tests.e2e.driver import parse_grids  # noqa: E402
from tests.e2e.wb10_search import Run as SearchRun  # noqa: E402


class ExplorationRun(SearchRun):
    def _capture(self, name: str) -> None:
        snapshot = self.grid.snapshot()
        (self.output / f"{name}-screen.txt").write_text("\n".join(snapshot["text"]) + "\n", encoding="utf-8")
        (self.output / f"{name}-grid.json").write_text(json.dumps(snapshot, indent=2, default=str) + "\n", encoding="utf-8")

    def _click_file_node(self, raw_name: str) -> dict[str, object]:
        target = self.lua(
            "local args=...; local wanted=args[1]; local s=_G.wb11_files_session; "
            "for line,id in pairs(s.view.row_by_line) do local node=s.nodes[id]; "
            "if node and node.payload and node.payload.raw_name==wanted then "
            "local pos=vim.fn.screenpos(s.view.window,line,1); "
            "return {id=id,row=pos.row-1,col=pos.col+3,kind=node.kind,label=node.label} end end",
            raw_name,
        )
        if not target:
            raise AssertionError(f"Files row {raw_name!r} is not visible")
        self.lua("local args=...; _G.wb11_expected_file_raw=args[1]", raw_name)
        self.control.api.input_mouse("left", "press", "", 0, target["row"], target["col"])
        self.control.api.input_mouse("left", "release", "", 0, target["row"], target["col"])
        self.wait_lua(
            "return _G.wb11_files_session.nodes[_G.wb11_files_session.selected_id].payload.raw_name == _G.wb11_expected_file_raw",
            f"mouse selection of Files row {raw_name}",
        )
        return target

    def _exercise(self) -> dict[str, object]:
        assert self.workspace is not None and self.target is not None and self.control is not None
        self.phase = "files-first"
        self.input("q")
        self.wait_lua("return _G.wb10_controller:status().active_views==0", "initial standalone Search shell close")

        hundred_path = self.workspace / "A" / "hundred-matches.txt"
        hundred_path.write_text("".join(f"hundred needle line {line}\n" for line in range(1, 101)), encoding="utf-8")
        workspace_b = (self.workspace / "B").resolve()
        files_started = time.perf_counter_ns()
        setup = self.lua(
            "local args=...; local folder_b=args[1]; "
            "local old=_G.wb10_controller; old:dispose(); _G.wb10_provider:dispose(); "
            "_G.wb10_store:dispose(); _G.wb10_nav:dispose(); "
            "vim.cmd({cmd='tcd',args={folder_b}}); _G.wb11_cwd=vim.fn.getcwd(); "
            "local layout=_G.wb10_layout; local Rg=require('workbench.providers.rg'); "
            "_G.wb11_rg=assert(Rg.new({max_items=256,max_batch_items=64})); "
            "_G.wb11_store=assert(require('workbench.services.results').new()); "
            "_G.wb11_nav=assert(require('workbench.services.navigation').new()); "
            "_G.wb11_actions=require('workbench.core.actions').new(); "
            "_G.wb11_search=assert(require('workbench.controllers.search').new({layout=layout,provider=_G.wb11_rg,store=_G.wb11_store,navigation=_G.wb11_nav,actions=_G.wb11_actions,workspace=_G.wb10_workspace,debounce_ms=80})); "
            "_G.wb11_fs=assert(require('workbench.providers.filesystem').new()); "
            "_G.wb11_files=assert(require('workbench.controllers.files').new({layout=layout,provider=_G.wb11_fs,on_search=function(snapshot,path) local view,err=_G.wb11_search:search_in_folder(snapshot,path,{focus=true}); _G.wb11_search_open_error=err; _G.wb11_search_view=view end})); "
            "_G.wb11_files_view=assert(_G.wb11_files:open(_G.wb10_workspace,{focus=true})); "
            "for _,session in pairs(_G.wb11_files.sessions) do _G.wb11_files_session=session end; "
            "return {tab=vim.api.nvim_get_current_tabpage(),cwd=_G.wb11_cwd,files_window=_G.wb11_files_view.window,help=_G.wb11_files_view.help_lines}",
            str(workspace_b),
        )
        self.wait_lua("return _G.wb11_files_session.loaded[_G.wb11_files_session.root_id] == true", "Files root enumeration")
        self.wait_lua(
            "local s=_G.wb11_files_session; local names={}; for _,id in ipairs(s.children[s.root_id] or {}) do local n=s.nodes[id]; if n and n.payload then names[n.payload.raw_name]=true end end; return names.A and names.B",
            "first Files root page",
        )
        first_files_shell_ms = (time.perf_counter_ns() - files_started) / 1_000_000
        if setup["cwd"] != str(workspace_b):
            raise AssertionError(f"terminal fixture did not begin in workspace B: {setup}")

        self.input("j")
        self.wait_lua("return _G.wb11_files_session.nodes[_G.wb11_files_session.selected_id].payload.raw_name=='A'", "keyboard selection of folder A")
        self.input("l")
        self.wait_lua(
            "return _G.wb11_files_session.loaded['file:' .. _G.wb10_workspace.roots[1].uri .. '/A']==true",
            "expand folder A",
        )
        self.wait_screen("a-target.txt")
        self._click_file_node("B")
        self.input("l")
        self.wait_lua(
            "return _G.wb11_files_session.loaded['file:' .. _G.wb10_workspace.roots[1].uri .. '/B']==true",
            "expand folder B",
        )
        self.wait_screen("cwd-decoy.txt")
        self._capture("files-both-branches")

        self.phase = "files-open-return"
        self._click_file_node("a-target.txt")
        self.input("\r")
        self.wait_lua("return vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())==_G.wb10_target_path", "open selected file in A")
        opened_file = self.lua(
            "local s=_G.wb11_files_session; local tab=vim.api.nvim_get_current_tabpage(); "
            "return {modified=vim.bo[_G.wb10_dirty_buf].modified,dirty_line=vim.api.nvim_buf_get_lines(_G.wb10_dirty_buf,0,1,false)[1], "
            "a=s.view.expanded['file:' .. _G.wb10_workspace.roots[1].uri .. '/A'],b=s.view.expanded['file:' .. _G.wb10_workspace.roots[1].uri .. '/B'],tab=tab}"
        )
        if not opened_file["modified"] or opened_file["dirty_line"] != "USER EDITED needle target" or not opened_file["a"] or not opened_file["b"]:
            raise AssertionError(f"opening A lost dirty text or independent branch state: {opened_file}")
        self.input("<C-^>")
        self.wait_lua("return vim.api.nvim_get_current_buf()==_G.wb10_origin_buf", "return from Files-opened file to original editor buffer")
        self.lua("_G.wb11_jump_before_search=vim.fn.getjumplist(_G.wb10_origin_win)")
        self.lua("vim.api.nvim_set_current_win(_G.wb11_files_view.window)")
        self._click_file_node("A")
        search_shell_started = time.perf_counter_ns()
        self.input("s")
        self.lua("local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; _G.wb11_jump_before_preview=vim.fn.getjumplist(s.origin.win)")

        self.phase = "folder-search-preview"
        self.wait_lua("return _G.wb11_search_view and _G.wb11_search:status().active_views==1", "Files search-in-folder action")
        self.wait_screen("Query: (empty query)")
        first_search_shell_ms = (time.perf_counter_ns() - search_shell_started) / 1_000_000
        search_started = time.perf_counter_ns()
        self.prompt("/", "needle", "Search folder:", pending_fragment="Waiting for query debounce")
        self.wait_lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; local e=s and s.investigation.current; "
            "local r=e and _G.wb11_store:summary(e.result_id); return r and r.status~='running'",
            "real rg completion for folder search",
        )
        self.wait_screen("Scope: folder:A")
        self.wait_screen("Query: needle")
        self.wait_lua("local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; return s.total>=100", "one hundred real rg matches")
        first_search_result_ms = (time.perf_counter_ns() - search_started) / 1_000_000
        self.wait_lua("local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; return s.preview and s.preview.last_preview~=nil", "first real result preview")
        self.wait_lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; "
            "return s.preview.last_preview and s.preview.last_preview.path==_G.wb10_target_path and s.preview.last_preview.modified",
            "modified-buffer preview among one hundred matches",
        )
        first_search = self.lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; local e=s.investigation.current; "
            "local r=_G.wb11_store:summary(e.result_id); local names={}; "
            "for _,item in ipairs(_G.wb11_store:page(e.result_id,0,256).items) do names[vim.fs.basename(item.location.resource.path)]=true end; "
            "return {id=e.result_id,query=s.query,scope=s.scope.path,count=r.item_count,status=r.status, "
            "names=names,modified_count=s.modified_count,selected=s.selected_id,preview=s.preview.last_preview, "
            "cwd=vim.fn.getcwd(),cwd_expected=_G.wb11_cwd,jumps=vim.deep_equal(_G.wb11_jump_before_preview,vim.fn.getjumplist(_G.wb10_origin_win))}"
        )
        if first_search["status"] != "complete" or first_search["count"] < 100 or first_search["modified_count"] != 1:
            raise AssertionError(f"100-match search or modified-buffer accounting was wrong: {first_search}")
        if not first_search["names"].get("hundred-matches.txt") or first_search["names"].get("cwd-decoy.txt"):
            raise AssertionError(f"selected folder scope leaked into workspace B: {first_search['names']}")
        if first_search["cwd"] != first_search["cwd_expected"] or not first_search["jumps"]:
            raise AssertionError(f"Search changed cwd or preview jumplist: {first_search}")
        self.grid.wait_for(lambda: any("USER EDITED needle target" in line for line in self.grid.lines()), 6, "modified-buffer preview in combined journey")
        self._capture("search-preview-100-matches")

        self.phase = "open-return-resume"
        self.input("o")
        self.wait_lua("return _G.wb11_nav:status().navigation_entries==1", "commit Search result navigation")
        opened_result = self.lua(
            "local target; for _,win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do local buf=vim.api.nvim_win_get_buf(win); "
            "if vim.api.nvim_buf_get_name(buf)==_G.wb10_target_path then target={win=win,buf=buf} end end; return target"
        )
        if not opened_result:
            raise AssertionError("Search did not open the selected modified result in an editor split")
        self.lua("vim.api.nvim_set_current_win(_G.wb11_search_view.window)")
        self.input("R")
        self.wait_lua("return vim.api.nvim_get_current_buf()==_G.wb10_origin_buf", "return to modified editor origin")
        returned = self.lua(
            "return {modified=vim.bo[_G.wb10_origin_buf].modified,line=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1], "
            "cwd=vim.fn.getcwd()}"
        )
        if not returned["modified"] or returned["line"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"Search return changed the editor origin: {returned}")
        first_id = first_search["id"]
        self.lua("vim.api.nvim_set_current_win(_G.wb11_search_view.window)")
        self.input("q")
        self.wait_lua("return _G.wb11_search:status().active_views==0", "close Search while retaining Files view")
        resumed = self.lua(
            "_G.wb11_search_view=assert(_G.wb11_search:open({workspace=_G.wb10_workspace,focus=true})); "
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; "
            "return {id=s.investigation.current.result_id,query=s.query,selected=s.selected_id,phase=s.phase}"
        )
        if resumed["id"] != first_id or resumed["query"] != "needle" or resumed["selected"] != first_search["selected"]:
            raise AssertionError(f"Search close/reopen did not resume the same 100-match session: {resumed}")

        self.phase = "retarget-open-search-from-files"
        self.lua("vim.api.nvim_set_current_win(_G.wb11_files_view.window)")
        self._click_file_node("B")
        self.input("s")
        self.wait_lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; "
            "local e=s and s.investigation.current; local r=e and _G.wb11_store:summary(e.result_id); "
            "return s and s.scope.path==_G.wb10_workspace.roots[1].path..'/B' and r and r.status=='complete' "
            "and r.item_count==1 and vim.api.nvim_get_current_win()==s.view.window",
            "Files retargets the open Search to B and focuses its result",
        )
        self.wait_screen("Scope: folder:B")
        self.wait_screen("cwd-decoy.txt")
        self._capture("search-retargeted-folder-b")
        self.lua("vim.api.nvim_set_current_win(_G.wb11_files_view.window)")
        self._click_file_node("A")
        self.input("s")
        self.wait_lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; "
            "local e=s and s.investigation.current; local r=e and _G.wb11_store:summary(e.result_id); "
            "return s and s.scope.path==_G.wb10_workspace.roots[1].path..'/A' and r and r.status=='complete' and r.item_count>=100",
            "Files retargets Search back to A",
        )

        self.phase = "tab-isolation-race-and-close"
        self.control.command("tabnew")
        tab_two = self.lua(
            "vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(),_G.wb10_origin_buf); "
            "local tab=vim.api.nvim_get_current_tabpage(); _G.wb11_tab_two=tab; "
            "local scope={kind='folder',explicit=true,path=_G.wb10_workspace.roots[1].path..'/B'}; "
            "_G.wb11_search_view_two=assert(_G.wb11_search:open({workspace=_G.wb10_workspace,scope=scope,focus=true,query='needle'})); "
            "local s=_G.wb11_search.active[tab]; return {tab=tab,query=s.query,scope=s.scope.path}"
        )
        self.wait_lua(
            "local s=_G.wb11_search.active[_G.wb11_tab_two]; local e=s and s.investigation.current; "
            "local r=e and _G.wb11_store:summary(e.result_id); return r and r.status=='complete'",
            "second-tab scoped Search result",
        )
        second_before = self.lua(
            "local s=_G.wb11_search.active[_G.wb11_tab_two]; local e=s.investigation.current; "
            "return {id=e.result_id,query=s.query,scope=s.scope.path,count=_G.wb11_store:summary(e.result_id).item_count,selected=s.selected_id}"
        )
        if second_before["scope"] != str(workspace_b) or second_before["count"] != 1:
            raise AssertionError(f"second tab did not search only folder B: {second_before}")

        race_setup = self.lua(
            "local real=_G.wb11_search.provider; _G.wb11_real_start=real.start; "
            "local fake={calls={}}; function fake:capabilities() return {state='ready',operations={'search'}} end; "
            "function fake:start(request,sink) local active=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; "
            "local call={request=request,result_id=assert(active and active.investigation.current and active.investigation.current.result_id),cancelled=false,finished=false}; self.calls[#self.calls+1]=call; "
            "call.sink=function(event) if event.kind=='done' or event.kind=='error' then call.finished=true end; return sink(event) end; "
            "return {cancel=function() if call.finished then return false end; call.cancelled=true; return true end} end; "
            "_G.wb11_fake=fake; _G.wb11_search.provider=fake; return {tab=vim.api.nvim_get_current_tabpage(),calls=0}"
        )
        if race_setup["tab"] != tab_two["tab"]:
            raise AssertionError(f"test remained in the wrong tab before rapid-search walkthrough: {race_setup}")

        race_calls = []
        for index, query in enumerate(("ux03-first", "ux03-second", "ux03-latest"), start=1):
            self.prompt("/", query, "Search folder:")
            self.wait_lua(f"return #_G.wb11_fake.calls >= {index}", f"controlled provider request {index}")
            call = self.lua(
                "local args=...; local c=_G.wb11_fake.calls[args[1]]; return {id=c.request.session_id,cancelled=c.cancelled,generation=c.request.generation}",
                index,
            )
            race_calls.append(call)
        self.lua(
            "local args=...; local r=assert(require('workbench.core.resource').from_path(args[1],{workspace_id=_G.wb10_workspace.id})); "
            "local l=assert(require('workbench.core.location').new(r,{range={start={line=0,character=0},finish={line=0,character=1}},encoding='utf-8'})); "
            "_G.wb11_race_resource=r; _G.wb11_race_location=l; return true",
            str(self.workspace / "B" / "cwd-decoy.txt"),
        )
        self.lua(
            "local call=_G.wb11_fake.calls[3]; local item={id='ux03-latest-match',kind='match',label='UX03 latest result',detail='cwd-decoy.txt:1',location=_G.wb11_race_location,payload={line_number=1,raw_line='UX03 latest result'}}; "
            "call.sink({kind='batch',generation=call.request.generation,items={item}}); call.sink({kind='done',generation=call.request.generation,status='complete'})",
        )
        self.wait_lua(
            "local s=_G.wb11_search.active[_G.wb11_tab_two]; local e=s.investigation.current; return _G.wb11_store:summary(e.result_id).status=='complete'",
            "latest rapid query completion",
        )
        self.grid.wait_for(lambda: any("UX03 latest result" in line for line in self.grid.lines()), 5, "latest rapid-query result in grid")
        self._capture("rapid-query-latest-only")
        self.lua(
            "local c=_G.wb11_fake.calls[1]; local item={id='ux03-stale-late',kind='match',label='STALE FIRST RESULT',location=_G.wb11_race_location,payload={line_number=1}}; "
            "c.sink({kind='batch',generation=c.request.generation,items={item}})",
        )
        race = self.lua(
            "local first,second,latest=_G.wb11_fake.calls[1],_G.wb11_fake.calls[2],_G.wb11_fake.calls[3]; "
            "local current=_G.wb11_search.active[_G.wb11_tab_two].investigation.current; "
            "return {first_cancelled=first.cancelled,second_cancelled=second.cancelled,latest_status=_G.wb11_store:summary(latest.result_id).status, "
            "latest_count=_G.wb11_store:summary(latest.result_id).item_count,first_count=_G.wb11_store:summary(first.result_id).item_count, "
            "second_count=_G.wb11_store:summary(second.result_id).item_count,query=current.options.query,selected=_G.wb11_search.active[_G.wb11_tab_two].selected_id}"
        )
        if not race["first_cancelled"] or not race["second_cancelled"] or race["latest_status"] != "complete" or race["latest_count"] != 1 or race["first_count"] != 0 or race["second_count"] != 0:
            raise AssertionError(f"rapid query race changed current results with stale generations: {race}")
        if race["query"] != "ux03-latest" or race["selected"] != "ux03-latest-match":
            raise AssertionError(f"latest rapid query did not retain its own query/selection: {race}")

        self.control.command("tabprevious")
        first_tab_state = self.lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; return {query=s.query,scope=s.scope.path,selected=s.selected_id,id=s.investigation.current.result_id}"
        )
        if first_tab_state["query"] != "needle" or first_tab_state["scope"] != str((self.workspace / "A").resolve()) or first_tab_state["selected"] != first_search["selected"]:
            raise AssertionError(f"switching to tab A changed its Search scope or selection: current={first_tab_state}, before={first_search}")
        self.control.command("tabnext")
        second_tab_state = self.lua(
            "local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; return {query=s.query,scope=s.scope.path,selected=s.selected_id,id=s.investigation.current.result_id}"
        )
        if second_tab_state["query"] != "ux03-latest" or second_tab_state["scope"] != str(workspace_b) or second_tab_state["selected"] != race["selected"]:
            raise AssertionError(f"switching back to tab B changed its Search scope or selection: {second_tab_state}")

        self.prompt("/", "ux06-pending", "Search folder:")
        self.wait_lua("return #_G.wb11_fake.calls==4", "pending second-tab search request")
        pending = self.lua("local c=_G.wb11_fake.calls[4]; return {id=c.request.session_id,result_id=c.result_id,generation=c.request.generation,cancelled=c.cancelled}")
        self.control.command("tabclose")
        self.wait_lua(
            "return not vim.api.nvim_tabpage_is_valid(_G.wb11_tab_two) and _G.wb11_search:status().active_views==1",
            "close tab during pending Search request",
        )
        late = self.lua(
            "local c=_G.wb11_fake.calls[4]; local item={id='ux06-after-close',kind='match',label='LATE TAB RESULT',location=_G.wb11_race_location,payload={line_number=1}}; "
            "c.sink({kind='batch',generation=c.request.generation,items={item}}); "
            "local r=_G.wb11_store:summary(c.result_id); return {cancelled=c.cancelled,status=r.status,count=r.item_count,views=_G.wb11_search:status().active_views}",
        )
        if not late["cancelled"] or late["status"] != "cancelled" or late["count"] != 0 or late["views"] != 1:
            raise AssertionError(f"closing tab left live Search state or accepted a late result: {late}")
        self.lua("_G.wb11_search.provider=_G.wb11_rg")

        self.phase = "workspace-reopen-and-dispose"
        search_layout_mode = self.lua("return _G.wb11_search_view.mode")
        first_active = self.lua("local s=_G.wb11_search.active[vim.api.nvim_get_current_tabpage()]; return {query=s.query,scope=s.scope.path,selected=s.selected_id}")
        if first_active["query"] != "needle" or first_active["scope"] != str((self.workspace / "A").resolve()):
            raise AssertionError(f"the surviving tab lost its retained Search: {first_active}")
        self.lua("vim.api.nvim_set_current_win(_G.wb11_search_view.window)")
        self.input("q")
        self.wait_lua("return _G.wb11_search:status().active_views==0", "close resumed Search view")
        self.lua("vim.api.nvim_set_current_win(_G.wb11_files_view.window)")
        self.input("q")
        self.wait_lua("return _G.wb11_files_session.view==nil", "close Files view")
        teardown = self.lua(
            "local before={search=_G.wb11_search:status(),files=_G.wb11_files:status(),layout=_G.wb10_layout:status(), "
            "rg=_G.wb11_rg:status(),fs=_G.wb11_fs:status(),dirty=vim.bo[_G.wb10_dirty_buf].modified,origin=vim.bo[_G.wb10_origin_buf].modified, "
            "origin_line=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1],cwd=vim.fn.getcwd()}; "
            "_G.wb11_search:dispose(); _G.wb11_files:dispose(); _G.wb11_rg:dispose(); _G.wb11_fs:dispose(); "
            "_G.wb11_store:dispose(); _G.wb11_nav:dispose(); _G.wb10_layout:dispose(); "
            "return {before=before,search_views=_G.wb11_search:status().active_views,files_sessions=_G.wb11_files:status().session_count, "
            "layout_views=_G.wb10_layout:status().active_views,rg_requests=_G.wb11_rg:status().active_requests,fs_requests=_G.wb11_fs:status().active_requests, "
            "dirty=vim.bo[_G.wb10_dirty_buf].modified,origin=vim.bo[_G.wb10_origin_buf].modified,origin_line=vim.api.nvim_buf_get_lines(_G.wb10_origin_buf,0,1,false)[1]}"
        )
        if teardown["search_views"] or teardown["files_sessions"] or teardown["layout_views"] or teardown["rg_requests"] or teardown["fs_requests"]:
            raise AssertionError(f"combined exploration retained owned resources: {teardown}")
        if not teardown["dirty"] or not teardown["origin"] or teardown["origin_line"] != "USER MODIFIED ORIGIN":
            raise AssertionError(f"combined exploration damaged editor-owned buffers: {teardown}")
        return {
            "grid": f"{self.cols}x{self.rows}",
            "journey": "Files A/B -> open A -> return -> search folder A -> preview -> open -> return -> resume",
            "ux_ids": ["UX-01", "UX-02", "UX-03", "UX-04", "UX-05 portion", "UX-06", "UX-09", "UX-11"],
            "layout": search_layout_mode,
            "first_files_shell_ms": round(first_files_shell_ms, 3),
            "first_search_shell_ms": round(first_search_shell_ms, 3),
            "first_search_result_ms": round(first_search_result_ms, 3),
            "files_opened_a_and_kept_both_branches": bool(opened_file["a"] and opened_file["b"]),
            "search_scope_a_unchanged_cwd_b": first_search["scope"] == str((self.workspace / "A").resolve()) and first_search["cwd"] == str(workspace_b),
            "real_rg_match_count": first_search["count"],
            "modified_buffer_preview": first_search["preview"]["modified"] and first_search["preview"]["source"] == "buffer",
            "search_navigation_returned": returned["line"] == "USER MODIFIED ORIGIN",
            "search_resumed": resumed["id"] == first_id and resumed["selected"] == first_search["selected"],
            "rapid_queries_latest_only": race["latest_count"] == 1 and race["first_count"] == 0 and race["second_count"] == 0,
            "tab_state_isolated": first_tab_state["selected"] != second_tab_state["selected"] and first_tab_state["scope"] != second_tab_state["scope"],
            "close_pending_tab_discarded_late_result": late["cancelled"] and late["count"] == 0 and late["views"] == 1,
            "teardown": {"search_views": teardown["search_views"], "files_sessions": teardown["files_sessions"], "layout_views": teardown["layout_views"], "rg_requests": teardown["rg_requests"], "fs_requests": teardown["fs_requests"]},
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nvim", default="nvim")
    parser.add_argument("--grid-sizes", default="160x50,120x35,80x24,60x20")
    parser.add_argument("--output-root", type=Path, default=ROOT / ".test-output" / "e2e" / "wb11")
    args = parser.parse_args()
    for cols, rows in parse_grids(args.grid_sizes):
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        output = args.output_root / f"{stamp}-{cols}x{rows}-{secrets.token_hex(3)}"
        run = ExplorationRun(args.nvim, cols, rows, output)
        try:
            result = run.run()
        except Exception as error:
            print(f"WB-11 exploration failed at {cols}x{rows}; phase={run.phase}; artifacts: {output}\n{type(error).__name__}: {error}\n{traceback.format_exc()}", file=sys.stderr)
            return 1
        print(json.dumps({"artifacts": str(output), **result}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
