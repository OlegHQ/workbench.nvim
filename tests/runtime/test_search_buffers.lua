local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source)
  return child.lua(source, { root })
end

local setup = [[
local function workspace_at(root, policy)
  local service=assert(require('workbench.services.workspace').new({
    root_service={canonicalize=function(_,path) return assert((vim.uv or vim.loop).fs_realpath(path)) end},
    ignore_service={snapshot=function() return policy or {hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}} end},
  }))
  return assert(service:open({explicit_root=root})),service
end
local function buf(path, lines)
  local buffer=vim.fn.bufadd(path); vim.fn.bufload(buffer)
  if lines then vim.api.nvim_buf_set_lines(buffer,0,-1,false,lines) end
  return buffer
end
local function wait_search(controller, store)
  local active=controller.active[vim.api.nvim_get_current_tabpage()]
  local finished=vim.wait(5000,function()
    local entry=active.investigation.current
    local summary=entry and store:summary(entry.result_id)
    return summary and summary.status~='running'
  end,5)
  if not finished then
    local entry=active.investigation.current
    local summary=entry and store:summary(entry.result_id)
    local runner=active.runner
    local lanes={}; if runner then for name,lane in pairs(runner.lanes) do lanes[name]={complete=lane.complete,status=lane.status,error=lane.error} end end
    error('buffer search did not reach a terminal state: '..vim.inspect({phase=active.phase,summary=summary,
      runner=runner and {expected=runner.expected,completed=runner.completed,lanes=lanes,disk_items=#runner.disk_items,
        included=runner.included,requests=#(controller.provider.requests or {}),events=controller.provider.events} or nil,
      provider=controller.provider and controller.provider.status and controller.provider:status()}))
  end
  local entry=active.investigation.current
  return active,entry,assert(store:summary(entry.result_id))
end
local function make_controller(workspace)
  local layout=require('workbench.ui.layout').new({min_editor_width=30})
  local real=assert(require('workbench.providers.rg').new())
  local provider={calls=0}
  function provider:capabilities(context) return real:capabilities(context) end
  function provider:start(request,sink)
    self.calls=self.calls+1
    return real:start(request,sink)
  end
  local store=assert(require('workbench.services.results').new())
  local navigation=assert(require('workbench.services.navigation').new())
  local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=provider,store=store,navigation=navigation,workspace=workspace,debounce_ms=1,
    buffer_list_factory=function(deps) return require('workbench.controllers.buffers').new(deps) end}))
  return controller,provider,real,store,navigation,layout
end
local function close_controller(controller,provider,real,store,navigation,layout)
  controller:dispose(); real:dispose(); navigation:dispose(); store:dispose(); layout:dispose()
end
]]

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
  ["dirty disk overlay supersedes matching files under identical policy with at most two rg runs"] = function()
    local result = evaluate(setup .. [[
      local root=vim.fn.tempname()..'-wb18-mixed-search'; assert(vim.fn.mkdir(root,'p')==1)
      vim.fn.writefile({'disk needle removed by edit'},root..'/removed.txt')
      vim.fn.writefile({'disk needle replaced by buffer'},root..'/updated.txt')
      vim.fn.writefile({'old disk contents'},root..'/saved.txt')
      vim.fn.writefile({'ignored.txt'},root..'/.gitignore')
      vim.fn.writefile({'disk needle ignored'},root..'/ignored.txt')
      vim.fn.writefile({'disk needle excluded'},root..'/excluded.txt')
      local policy={hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={'excluded.txt'}}
      local workspace=workspace_at(root,policy)
      local removed=buf(root..'/removed.txt',{'no longer matches'}); vim.bo[removed].modified=true
      local updated=buf(root..'/updated.txt',{'unsaved needle from buffer'}); vim.bo[updated].modified=true
      local ignored=buf(root..'/ignored.txt',{'unsaved needle but ignored'}); vim.bo[ignored].modified=true
      local excluded=buf(root..'/excluded.txt',{'unsaved needle but excluded'}); vim.bo[excluded].modified=true
      local saved=buf(root..'/saved.txt')
      vim.fn.writefile({'needle from external disk change'},root..'/saved.txt')
      assert(vim.api.nvim_buf_get_lines(saved,0,1,false)[1]=='old disk contents' and not vim.bo[saved].modified)
      vim.api.nvim_set_current_buf(updated)
      local controller,provider,real,store,navigation,layout=make_controller(workspace)
      local view=assert(controller:open({workspace=workspace,query='needle',focus=false}))
      local active,entry,summary=wait_search(controller,store)
      local page=assert(store:page(entry.result_id,0,200))
      local found={}; local updated_item
      for _,item in ipairs(page.items) do
        local name=vim.fs.basename(item.location.resource.path)
        found[name]=found[name] or {}
        found[name][#found[name]+1]=item
        if name=='updated.txt' then updated_item=item end
      end
      local header=table.concat(view.model.header or {},' | ')
      local match_line=updated_item and updated_item.payload.raw_line
      if updated_item then
        active.selected_id=updated_item.id
        vim.api.nvim_buf_set_lines(updated,0,-1,false,{'edited again after search'})
        local opened,stale_err=controller:open_selected(active)
        local stale_notice=active.notice and active.notice.label
        local stale_count=vim.wait(1000,function() return table.concat(view.model.header or {},' | '):find('changed since capture',1,true)~=nil end,5)
        local status={opened=opened==nil,code=stale_err and stale_err.code,notice=stale_notice,stale_count=stale_count}
        controller:dispose(); real:dispose(); navigation:dispose(); store:dispose(); layout:dispose()
        vim.bo[removed].modified=false; vim.bo[updated].modified=false; vim.bo[ignored].modified=false; vim.bo[excluded].modified=false
        vim.fn.delete(root,'rf')
        return {count=summary.item_count,status=summary.status,processes=provider.calls,removed=found['removed.txt']~=nil,
          updated=found['updated.txt']~=nil,updated_line=match_line,saved=found['saved.txt']~=nil,saved_line=found['saved.txt'] and found['saved.txt'][1].payload.raw_line,
          ignored=found['ignored.txt']~=nil,excluded=found['excluded.txt']~=nil,header=header,source=updated_item.payload.source_snapshot,
          stale=status,provider_active=real:status().active_requests}
      end
      close_controller(controller,provider,real,store,navigation,layout); vim.fn.delete(root,'rf')
      return {missing_updated=true}
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 2)
    expect.equality(result.processes, 3)
    expect.equality(result.removed, false)
    expect.equality(result.updated, true)
    expect.equality(result.updated_line, "unsaved needle from buffer")
    expect.equality(result.saved, true)
    expect.equality(result.saved_line, "needle from external disk change")
    expect.equality(result.ignored, false)
    expect.equality(result.excluded, false)
    expect.equality(result.header:find("Source: disk plus 4 modified buffer snapshots",1,true)~=nil,true)
    expect.equality(type(result.source.content_hash), "string")
    expect.equality(result.stale.opened, true)
    expect.equality(result.stale.code, "stale_buffer_snapshot")
    expect.equality(result.stale.notice, "Result is from an older buffer snapshot")
    expect.equality(result.stale.stale_count, true)
    expect.equality(result.provider_active, 0)
  end,

  ["explicit open-buffer search uses loaded memory for workspace and external files, excludes scratch buffers, and opens the exact buffer"] = function()
    local result = evaluate(setup .. [[
      local root=vim.fn.tempname()..'-wb18-open-search'; local outside=vim.fn.tempname()..'-wb18-external.txt'
      assert(vim.fn.mkdir(root,'p')==1); vim.fn.writefile({'diskneedle on disk'},root..'/inside.txt'); vim.fn.writefile({'external old'},outside)
      local workspace=workspace_at(root)
      local inside=buf(root..'/inside.txt',{'memoryneedle from loaded buffer'}); vim.bo[inside].modified=false
      local external=buf(outside,{'memoryneedle outside workspace'}); vim.bo[external].buflisted=false; vim.bo[external].modified=true
      local inside_path=assert((vim.uv or vim.loop).fs_realpath(root..'/inside.txt'))
      local outside_path=assert((vim.uv or vim.loop).fs_realpath(outside))
      local unnamed=vim.api.nvim_create_buf(false,true); vim.api.nvim_buf_set_lines(unnamed,0,-1,false,{'memoryneedle unnamed'})
      local special=vim.api.nvim_create_buf(false,true); vim.bo[special].buftype='nofile'; vim.api.nvim_buf_set_lines(special,0,-1,false,{'memoryneedle special'})
      vim.api.nvim_set_current_buf(inside)
      local controller,provider,real,store,navigation,layout=make_controller(workspace)
      local view=assert(controller:search_open_buffers(workspace,{query='memoryneedle',focus=false}))
      local active,entry,summary=wait_search(controller,store)
      local page=assert(store:page(entry.result_id,0,200)); local found={}; local inside_item
      for _,item in ipairs(page.items) do
        found[item.location.resource.path]=item
        if item.location.resource.path==inside_path then inside_item=item end
      end
      local header=table.concat(view.model.header or {},' | ')
      active.selected_id=inside_item and inside_item.id
      local opened=inside_item and assert(controller:open_selected(active))
      local opened_exact=opened and opened.buf==inside and vim.api.nvim_buf_get_lines(inside,0,1,false)[1]=='memoryneedle from loaded buffer'
      local returned=opened and assert(controller:return_to_origin(active))
      local returned_origin=returned and returned.win==active.origin.win
      local list_view=assert(controller:open_buffer_list({focus=false}))
      local list_count=0; for _,row in ipairs(list_view.rows) do if row.kind=='buffer' then list_count=list_count+1 end end
      if inside_item then
        list_view.selected_id='buffer:'..inside_item.location.resource.uri
        assert(list_view:activate())
      end
      local list_open_exact=vim.api.nvim_get_current_buf()==inside
      local output={status=summary.status,count=summary.item_count,processes=provider.calls,inside=found[inside_path]~=nil,
        external=found[outside_path]~=nil,disk_only=found[inside_path] and found[inside_path].payload.raw_line=='diskneedle on disk',
        unnamed=found[vim.api.nvim_buf_get_name(unnamed)]~=nil,special=found[vim.api.nvim_buf_get_name(special)]~=nil,
        header=header,open_exact=opened_exact,returned=returned_origin,list_rows=list_count,list_open_exact=list_open_exact,
        excluded_unnamed=active.snapshot_excluded and active.snapshot_excluded.unnamed or nil}
      list_view:close(); view:close(); close_controller(controller,provider,real,store,navigation,layout)
      vim.bo[external].modified=false; vim.api.nvim_buf_delete(unnamed,{force=true}); vim.api.nvim_buf_delete(special,{force=true})
      vim.fn.delete(root,'rf'); vim.fn.delete(outside)
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 2)
    expect.equality(result.processes, 1)
    expect.equality(result.inside, true)
    expect.equality(result.external, true)
    expect.equality(result.disk_only, false)
    expect.equality(result.unnamed, false)
    expect.equality(result.special, false)
    expect.equality(result.header:find("Scope: open buffers",1,true)~=nil,true)
    expect.equality(result.header:find("in-memory text of 2 named loaded buffer snapshots",1,true)~=nil,true)
    expect.equality(result.open_exact, true)
    expect.equality(result.returned, true)
    expect.equality(result.list_rows >= 2, true)
    expect.equality(result.list_open_exact,true)
  end,

  ["cancelling aggregate dirty-buffer scans removes snapshots and rejects every late lane callback"] = function()
    local result = evaluate(setup .. [[
      local root=vim.fn.tempname()..'-wb18-cancel'; assert(vim.fn.mkdir(root,'p')==1); vim.fn.writefile({'disk needle'},root..'/dirty.txt')
      local workspace=workspace_at(root)
      local buffer=buf(root..'/dirty.txt',{'unsaved needle'}); vim.bo[buffer].modified=true
      local fake={calls={}}
      function fake:capabilities() return {state='ready',operations={'search'}} end
      function fake:start(request,sink)
        local call={request=vim.deepcopy(request),sink=sink,cancelled=false}
        function call:cancel() self.cancelled=true; return true end
        self.calls[#self.calls+1]=call
        return call
      end
      local layout=require('workbench.ui.layout').new(); local store=assert(require('workbench.services.results').new())
      local navigation=assert(require('workbench.services.navigation').new())
      local controller=assert(require('workbench.controllers.search').new({layout=layout,provider=fake,store=store,navigation=navigation,workspace=workspace,debounce_ms=0}))
      local view=assert(controller:open({workspace=workspace,focus=false}))
      local active=controller.active[vim.api.nvim_get_current_tabpage()]
      local cleaned=0; local late_ignored=true
      for cycle=1,25 do
        assert(controller:set_query(active,'needle-'..cycle,true))
        local first=(cycle-1)*3+1
        assert(#fake.calls==first+2)
        local staged_root=fake.calls[first+1].request.workspace.roots[1].path
        assert((vim.uv or vim.loop).fs_lstat(staged_root))
        local entry=active.investigation.current
        assert(controller:cancel(active))
        assert(active.request==nil and active.request_scope==nil and active.runner==nil)
        local removed=(vim.uv or vim.loop).fs_lstat(staged_root)==nil
        if removed then cleaned=cleaned+1 end
        for index=first,first+2 do
          local call=fake.calls[index]
          if not call.cancelled then error('aggregate lane was not cancelled') end
          call.sink({kind='batch',generation=call.request.generation,items={{id='late-'..index,kind='match',label='late'}}})
        end
        local summary=assert(store:summary(entry.result_id))
        if summary.status~='cancelled' or summary.item_count~=0 then late_ignored=false end
      end
      local call_count=#fake.calls
      view:close(); local status=controller:status()
      controller:dispose(); navigation:dispose(); store:dispose(); layout:dispose()
      vim.bo[buffer].modified=false; vim.fn.delete(root,'rf')
      return {calls=call_count,cleaned=cleaned,late_ignored=late_ignored,active_views=status.active_views}
    ]])
    expect.equality(result.calls, 75)
    expect.equality(result.cleaned, 25)
    expect.equality(result.late_ignored, true)
    expect.equality(result.active_views, 0)
  end,
})
