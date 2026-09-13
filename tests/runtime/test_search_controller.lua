local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  local wrapped = "local args={...}; local unpack_fn=unpack or table.unpack; local ok,result=xpcall(function(...)\n" .. source .. "\nend,debug.traceback,unpack_fn(args)); if not ok then return {__child_error=result} end; return result"
  local result = child.lua(wrapped, { ... })
  if type(result) == "table" and result.__child_error then error("search-controller child evaluation failed: " .. vim.inspect(result.__child_error), 2) end
  return result
end

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)", { root, root .. "/tests" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["workspace replacement keeps old Search alive on mount failure and retries cleanly"] = function()
    local result=evaluate([[
      local root=vim.fn.tempname()..'-search-replace'
      vim.fn.mkdir(root..'/A','p'); vim.fn.mkdir(root..'/B','p')
      vim.fn.writefile({'needle'},root..'/A/a.txt'); vim.fn.writefile({'needle'},root..'/B/b.txt')
      local service=assert(require('workbench.services.workspace').new({
        root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},
        ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never'} end},
      }))
      local a=assert(service:open({explicit_root=root..'/A'}))
      local b=assert(service:open({explicit_root=root..'/B'}))
      local layout=require('workbench.ui.layout').new()
      local provider=assert(require('workbench.providers.rg').new())
      local store=assert(require('workbench.services.results').new())
      local navigation=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,navigation=navigation,workspace=a}))
      local first=assert(controller:open({workspace=a,query='needle',focus=false}))
      local tab=vim.api.nvim_get_current_tabpage(); local active=controller.active[tab]
      assert(vim.wait(3000,function() return active.phase=='Complete' end,5))
      local entry=active.investigation.current
      local place=layout._place
      layout._place=function() return nil,{code='injected_mount',message='failed replacement'} end
      local failed,err=controller:open({workspace=b,query='needle',focus=false})
      layout._place=place
      assert(not failed and err.code=='injected_mount')
      assert(not first.closed and controller.active[tab]==active and layout:get('workbench-search')==first)
      assert(active.investigation.current==entry and active.phase=='Complete' and active.query=='needle')
      assert(layout:status().active_views==1)
      local second=assert(controller:open({workspace=b,query='needle',focus=false}))
      local replacement=controller.active[tab]
      assert(first.closed and active.closed and second~=first and replacement.investigation.workspace.id==b.id)
      assert(vim.wait(3000,function() return replacement.phase=='Complete' end,5))
      controller:dispose(); provider:dispose(); store:dispose(); navigation:dispose(); layout:dispose()
      assert(layout:status().active_views==0)
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["real rg renders grouped folder results, labels disk state, and leaves cwd/buffers intact"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb10-search'
      assert(vim.fn.mkdir(root..'/A','p')==1); assert(vim.fn.mkdir(root..'/B','p')==1)
      assert(vim.fn.writefile({'disk needle','second line'},root..'/A/one.txt')==0)
      assert(vim.fn.writefile({'disk needle'},root..'/A/two.txt')==0)
      assert(vim.fn.writefile({'disk needle'},root..'/B/other.txt')==0)
      local ws_service=assert(require('workbench.services.workspace').new({
        root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},
        ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end},
      }))
      local workspace=assert(ws_service:open({explicit_root=root}))
      local dirty_path=workspace.roots[1].path..'/A/one.txt'
      local dirty=vim.fn.bufadd(dirty_path); vim.fn.bufload(dirty)
      vim.api.nvim_buf_set_lines(dirty,0,-1,false,{'unsaved version','second line'}); vim.bo[dirty].modified=true
      vim.api.nvim_win_set_buf(0,dirty)
      vim.cmd('tcd '..vim.fn.fnameescape(root..'/B'))
      local cwd=vim.fn.getcwd()
      local layout=require('workbench.ui.layout').new({min_editor_width=30})
      local provider=assert(require('workbench.providers.rg').new())
      local store=assert(require('workbench.services.results').new())
      local nav=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,navigation=nav,workspace=workspace,debounce_ms=1}))
      local view=assert(controller:search_in_folder(workspace,workspace.roots[1].path..'/A',{focus=false}))
      local active=controller.active[vim.api.nvim_get_current_tabpage()]
      assert(controller:set_query(active,'needle',true))
      assert(vim.wait(5000,function()
        local entry=active.investigation.current
        local summary=entry and store:summary(entry.result_id)
        return summary and summary.status~='running'
      end,5),'real rg search did not finish')
      vim.wait(1000,function() return active.view and #active.view.rows>0 end,5)
      local entry=active.investigation.current
      local summary=assert(store:summary(entry.result_id))
      local page=assert(store:page(entry.result_id,0,200))
      local names={}; for _,item in ipairs(page.items) do names[vim.fs.basename(item.location.resource.path)]=true end
      local rows={}; for _,row in ipairs(view.rows) do rows[#rows+1]={kind=row.kind,label=row.label,id=row.id} end
      local header=table.concat(view.model.header or {},' | ')
      local cwd_same=vim.fn.getcwd()==cwd
      local dirty_still_modified=vim.bo[dirty].modified and vim.api.nvim_buf_get_lines(dirty,0,1,false)[1]=='unsaved version'
      local grouped_files=0; for _,row in ipairs(view.rows) do if row.kind=='file' then grouped_files=grouped_files+1 end end
      view:close()
      local closed=controller:status().active_views==0 and provider:status().active_requests==0
      controller:dispose(); nav:dispose(); provider:dispose(); store:dispose(); layout:dispose()
      vim.bo[dirty].modified=false; vim.fn.delete(root,'rf')
      return {count=summary.item_count,status=summary.status,names=names,rows=rows,header=header,cwd_same=cwd_same,dirty_still_modified=dirty_still_modified,grouped_files=grouped_files,closed=closed}
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 1)
    expect.equality(result.names["one.txt"], nil)
    expect.equality(result.names["two.txt"], true)
    expect.equality(result.names["other.txt"], nil)
    expect.equality(result.grouped_files, 1)
    expect.equality(result.header:find("Scope: folder:A",1,true)~=nil,true)
    expect.equality(result.header:find("Source: disk plus 1 modified buffer snapshot",1,true)~=nil,true)
    expect.equality(result.cwd_same,true)
    expect.equality(result.dirty_still_modified,true)
    expect.equality(result.closed,true)
  end,

  ["explicit folder and query changes apply to open and resumed searches"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-search-reopen'
      vim.fn.mkdir(root..'/A','p'); vim.fn.mkdir(root..'/B','p')
      vim.fn.writefile({'needle alpha'},root..'/A/a.txt')
      vim.fn.writefile({'needle beta'},root..'/B/b.txt')
      local workspace=assert(require('workbench.services.workspace').new({
        root_service={canonicalize=function(_,p) return p end},
        ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end},
      })):open({explicit_root=root})
      local layout=require('workbench.ui.layout').new()
      local provider=assert(require('workbench.providers.rg').new())
      local store=assert(require('workbench.services.results').new())
      local nav=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,navigation=nav,workspace=workspace,debounce_ms=0}))
      local tab=vim.api.nvim_get_current_tabpage()
      local function completed(path)
        assert(vim.wait(5000,function()
          local active=controller.active[tab]
          local entry=active and active.investigation.current
          local summary=entry and store:summary(entry.result_id)
          return summary and summary.status=='complete'
        end,5))
        local entry=controller.active[tab].investigation.current
        local page=assert(store:page(entry.result_id,0,20))
        assert(#page.items==1 and page.items[1].location.resource.path==path, 'search used the previous folder')
      end
      local first=assert(controller:search_in_folder(workspace,root..'/A',{query='needle',focus=false}))
      completed(root..'/A/a.txt')
      local second=assert(controller:search_in_folder(workspace,root..'/B',{query='beta',focus=false}))
      assert(second==first)
      completed(root..'/B/b.txt')
      local active=controller.active[tab]
      assert(active.query=='beta' and active.scope.path==root..'/B')
      first:close()
      local reopened=assert(controller:search_in_folder(workspace,root..'/A',{query='needle',focus=false}))
      completed(root..'/A/a.txt')
      assert(controller:open({workspace=workspace,query='',focus=false}))
      assert(controller.active[tab].query=='')
      local invalid,err=controller:open({workspace=workspace,query={},focus=false})
      assert(not invalid and err.code=='invalid_query')
      assert(controller:open({workspace=workspace}))
      assert(vim.api.nvim_get_current_win()==reopened.window, 'existing Search did not regain focus')
      local changed=vim.deepcopy(workspace)
      changed.generation=changed.generation+1
      changed.policy.hidden='include'
      local old_active=controller.active[tab]
      assert(controller:open({workspace=changed,query='alpha',focus=false}))
      assert(old_active.closed and not old_active.scope_owner.alive)
      completed(root..'/A/a.txt')
      assert(controller.active[tab].investigation.workspace.generation==changed.generation)
      controller:dispose(); nav:dispose(); provider:dispose(); store:dispose(); layout:dispose()
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result, true)
  end,

  ["stale generations are rejected, debounce coalesces input, and result history resumes"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb10-race'; assert(vim.fn.mkdir(root,'p')==1)
      assert(vim.fn.writefile({'x'},root..'/one.txt')==0)
      local workspace=assert(require('workbench.services.workspace').new({root_service={canonicalize=function(_,p) return p end},ignore_service={snapshot=function() return {hidden='exclude',ignored='include',symlinks='never',include={},exclude={}} end}})):open({explicit_root=root})
      local fake={calls={}}
      function fake:capabilities() return {state='ready',operations={'search'}} end
      function fake:start(request,sink)
        local call={request=request,cancelled=false,finished=false}; self.calls[#self.calls+1]=call
        call.sink=function(event)
          if event.kind=='done' or event.kind=='error' then call.finished=true end
          return sink(event)
        end
        return {cancel=function() if call.finished then return false end; call.cancelled=true; return true end}
      end
      local layout=require('workbench.ui.layout').new()
      local store=assert(require('workbench.services.results').new())
      local nav=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=fake,store=store,navigation=nav,workspace=workspace,debounce_ms=20}))
      local view=assert(controller:open({workspace=workspace,focus=false}))
      local active=controller.active[vim.api.nvim_get_current_tabpage()]
      controller:set_query(active,'first')
      controller:set_query(active,'stale')
      controller:set_query(active,'latest')
      assert(vim.wait(3000,function() return #fake.calls==1 end,5),'debounced input did not coalesce')
      local call=fake.calls[1]
      local Resource=require('workbench.core.resource'); local Location=require('workbench.core.location')
      local resource=assert(Resource.from_path(root..'/one.txt',{workspace_id=workspace.id}))
      local location=assert(Location.new(resource,{range={start={line=0,character=0},finish={line=0,character=1}},encoding='utf-8'}))
      local function item(id,label)
        return {id=id,kind='match',label=label,detail='one.txt:1',location=location,payload={line_number=1,raw_line=label}}
      end
      local id=active.investigation.current.result_id
      controller:set_query(active,'newer',true)
      local second=fake.calls[2]
      local second_id=active.investigation.current.result_id
      local searching_visible=vim.wait(1000,function()
        for _,row in ipairs(view.rows) do if row.label=='Searching…' then return true end end
        return false
      end,5)
      second.sink({kind='batch',generation=second.request.generation,items={item('new','new result')}})
      second.sink({kind='done',generation=second.request.generation,status='complete'})
      assert(vim.wait(1000,function() return store:summary(second_id).status=='complete' end,5))
      call.sink({kind='batch',generation=call.request.generation,items={item('late','late stale result')}})
      local stale_count=store:summary(id).item_count
      local latest_count=store:summary(second_id).item_count
      local history_count=#active.investigation.history
      assert(controller:resume(active,id))
      local resumed=active.investigation.current.result_id==id and active.query=='latest'
      controller:set_query(active,'closing',true)
      local closing=fake.calls[3]
      local closing_id=active.investigation.current.result_id
      assert(closing and closing.request.generation)
      view:close()
      closing.sink({kind='batch',generation=closing.request.generation,items={item('closed-late','late result after view disposal')}})
      local closed_summary=assert(store:summary(closing_id))
      local state=controller:status()
      controller:dispose(); nav:dispose(); store:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return {calls=#fake.calls,first_cancelled=call.cancelled,closing_cancelled=closing.cancelled,closed_status=closed_summary.status,closed_count=closed_summary.item_count,stale_count=stale_count,latest_count=latest_count,history_count=history_count,resumed=resumed,searching_visible=searching_visible,active_after_close=state.active_views}
    ]])
    expect.equality(result.calls, 3)
    expect.equality(result.first_cancelled, true)
    expect.equality(result.stale_count, 0)
    expect.equality(result.latest_count, 1)
    expect.equality(result.history_count, 2)
    expect.equality(result.resumed, true)
    expect.equality(result.searching_visible, true)
    expect.equality(result.closing_cancelled, true)
    expect.equality(result.closed_status, "cancelled")
    expect.equality(result.closed_count, 0)
    expect.equality(result.active_after_close, 0)
  end,

  ["closing Search cancels a reviewed replacement and ignores its late confirmation"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb22-close'; assert(vim.fn.mkdir(root,'p')==1)
      local path=root..'/one.txt'; assert(vim.fn.writefile({'needle stays'},path)==0)
      local workspace=assert(require('workbench.services.workspace').new({
        root_service={canonicalize=function(_,p) return assert((vim.uv or vim.loop).fs_realpath(p)) end},
        ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end},
      })):open({explicit_root=root})
      local layout=require('workbench.ui.layout').new(); local provider=assert(require('workbench.providers.rg').new())
      local store=assert(require('workbench.services.results').new()); local nav=assert(require('workbench.services.navigation').new())
      local confirmation; local calls={review=0,apply=0,cancel=0}
      local replacement={}
      function replacement:prepare(_,selected,value)
        assert(#selected==1 and value=='changed')
        return {id='late-plan',state='validated',matched_count=1,review='exact replacement'}
      end
      function replacement:review(plan) calls.review=calls.review+1; plan.state='reviewed'; return true end
      function replacement:apply(plan) calls.apply=calls.apply+1; plan.state='applied'; return true end
      function replacement:cancel(plan)
        calls.cancel=calls.cancel+1
        if plan.state=='cancelled' then return false end
        plan.state='cancelled'; return true
      end
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,navigation=nav,workspace=workspace,
        replacement=replacement,debounce_ms=1,select=function(_,_,callback) confirmation=callback end}))
      local view=assert(controller:search_in_folder(workspace,workspace.roots[1].path,{focus=false}))
      local active=controller.active[vim.api.nvim_get_current_tabpage()]
      assert(controller:set_query(active,'needle',true))
      assert(vim.wait(5000,function()
        local entry=active.investigation.current; local summary=entry and store:summary(entry.result_id)
        return summary and summary.status=='complete' and summary.item_count==1
      end,5),'real rg search did not finish')
      if not active.selected_id then active.selected_id=store:page(active.investigation.current.result_id,0,10).items[1].id end
      local plan=assert(controller:replace_selected(active,'changed'))
      assert(plan==active.pending_replacement and confirmation,'review was not retained while confirmation was pending')
      view:close()
      local closed=active.pending_replacement==nil and plan.state=='cancelled'
      confirmation('Apply this exact replacement')
      local content=table.concat(vim.fn.readfile(path),'\n')
      local result={closed=closed,state=plan.state,review_calls=calls.review,apply_calls=calls.apply,cancel_calls=calls.cancel,content=content,active_views=controller:status().active_views}
      controller:dispose(); nav:dispose(); provider:dispose(); store:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return result
    ]])
    expect.equality(result.closed, true)
    expect.equality(result.state, "cancelled")
    expect.equality(result.review_calls, 0)
    expect.equality(result.apply_calls, 0)
    expect.equality(result.cancel_calls, 2)
    expect.equality(result.content, "needle stays")
    expect.equality(result.active_views, 0)
  end,

  ["palette keeps unavailable capabilities discoverable and current-file ignore behavior explicit"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb10-palette'; assert(vim.fn.mkdir(root,'p')==1); assert(vim.fn.writefile({'needle'},root..'/file.txt')==0)
      local workspace=assert(require('workbench.services.workspace').new({root_service={canonicalize=function(_,p) return p end},ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=root})
      local layout=require('workbench.ui.layout').new(); local provider=assert(require('workbench.providers.rg').new()); local store=assert(require('workbench.services.results').new()); local actions=require('workbench.core.actions').new()
      local nav=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,actions=actions,navigation=nav,workspace=workspace,debounce_ms=1}))
      local buf=vim.fn.bufadd(root..'/file.txt'); vim.fn.bufload(buf); vim.api.nvim_win_set_buf(0,buf)
      local view=assert(controller:search_current_file(workspace,root..'/file.txt',{focus=false,query='needle'}))
      local active=controller.active[vim.api.nvim_get_current_tabpage()]
      assert(vim.wait(1000,function() return view.model.header and view.model.header[2] and view.model.header[2]:find('explicit current%-file target')~=nil end,5))
      local projection=actions:list(controller:_action_context({workspace=workspace,search=active}))
      local by_id={}; for _,action in ipairs(projection) do by_id[action.id]=action end
      local palette=assert(controller.palette:open({focus=false,context=controller:_action_context({workspace=workspace,search=active})}))
      local palette_state=controller.palette.active[vim.api.nvim_get_current_tabpage()]
      palette_state.filter='open buffers'; controller.palette:_show(palette_state)
      local palette_lines=vim.api.nvim_buf_get_lines(palette.buffer,0,-1,false)
      local output={
        open_buffers_enabled=by_id['search.open_buffers'].available.enabled,
        open_buffers_reason=by_id['search.open_buffers'].available.reason,
        buffers_list_enabled=by_id['buffers.list'].available.enabled,
        buffers_list_reason=by_id['buffers.list'].available.reason,
        ignored_toggle_enabled=by_id['search.toggle_ignored'].available.enabled,
        ignored_toggle_reason=by_id['search.toggle_ignored'].available.reason,
        header=table.concat(view.model.header or {},' | '),
        palette_has_disabled=table.concat(palette_lines,' | '):find('Search open buffers',1,true)~=nil,
        palette_detail=table.concat(palette_lines,' | '):find('WB-18',1,true)~=nil,
        palette_rows=#palette.rows,
      }
      controller.palette:close(); view:close(); controller:dispose(); nav:dispose(); provider:dispose(); store:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.open_buffers_enabled, true)
    expect.equality(result.open_buffers_reason, nil)
    expect.equality(result.buffers_list_enabled, false)
    expect.equality(result.buffers_list_reason, "the buffer-list view is not installed")
    expect.equality(result.ignored_toggle_enabled,false)
    expect.equality(result.ignored_toggle_reason:find("direct%-file semantics")~=nil,true)
    expect.equality(result.header:find("explicit current%-file target overrides ignore rules")~=nil,true)
    expect.equality(result.palette_has_disabled,true)
    expect.equality(result.palette_detail,false)
    expect.equality(result.palette_rows>0,true)
  end,

  ["empty and missing-rg states are explicit and repeated close releases owned views"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb10-unavailable'; assert(vim.fn.mkdir(root,'p')==1)
      local workspace=assert(require('workbench.services.workspace').new({root_service={canonicalize=function(_,p) return p end},ignore_service={snapshot=function() return {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end}})):open({explicit_root=root})
      local layout=require('workbench.ui.layout').new()
      local provider=assert(require('workbench.providers.rg').new({executable=function() return '' end}))
      local store=assert(require('workbench.services.results').new())
      local nav=assert(require('workbench.services.navigation').new())
      local actions=require('workbench.core.actions').new()
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,actions=actions,navigation=nav,workspace=workspace,debounce_ms=1}))
      local ctx=controller:_action_context({workspace=workspace})
      local listed=actions:list(ctx); local workspace_action
      for _,action in ipairs(listed) do if action.id=='search.workspace' then workspace_action=action end end
      assert(workspace_action and not workspace_action.available.enabled)
      local palette=assert(controller.palette:open({focus=false,context=ctx}))
      local palette_state=controller.palette.active[vim.api.nvim_get_current_tabpage()]
      local reason=palette_state.by_id['search.workspace'].available.reason
      assert(reason:find("ripgrep executable 'rg' was not found",1,true))
      controller.palette:close()
      local cycles=0
      for _=1,100 do
        local view=assert(controller:open({workspace=workspace,focus=false}))
        local active=controller.active[vim.api.nvim_get_current_tabpage()]
        assert(active.query=='')
        assert(provider:status().active_requests==0)
        assert(controller:set_query(active,'needle',true)==false)
        assert(vim.wait(1000,function()
          for _,row in ipairs(view.rows) do if row.label=='Search unavailable' then return true end end
          return false
        end,5),'missing ripgrep state was not rendered')
        assert(view:close())
        local layout_state=layout:status()
        assert(layout_state.active_views==0)
        assert(provider:status().active_requests==0)
        cycles=cycles+1
      end
      local status=controller:status()
      controller:dispose(); nav:dispose(); provider:dispose(); store:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return {reason=reason,cycles=cycles,active_views=status.active_views,active_requests=provider:status().active_requests,layout_views=layout:status().active_views}
    ]])
    expect.equality(result.reason:find("ripgrep executable 'rg' was not found",1,true)~=nil,true)
    expect.equality(result.cycles,100)
    expect.equality(result.active_views,0)
    expect.equality(result.active_requests,0)
    expect.equality(result.layout_views,0)
  end,
})
