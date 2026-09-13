local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  local wrapped = "local args={...}; local unpack_fn=unpack or table.unpack; local ok,result=xpcall(function(...)\n" .. source
    .. "\nend,debug.traceback,unpack_fn(args)); if not ok then return {__child_error=result} end; return result"
  local result = child.lua(wrapped, { ... })
  if type(result) == "table" and result.__child_error then
    error("Workbench host child evaluation failed: " .. vim.inspect(result.__child_error), 2)
  end
  return result
end

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("local root, plugin = ...; vim.opt.runtimepath:prepend(root); dofile(plugin)", { root, root .. "/plugin/workbench.lua" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["public sidebar root changes replace Files Outline and Problems only after successful mounts"] = function()
    local result=evaluate([[
      local base=vim.fn.tempname()..'-sidebar-roots'
      local a,b=base..'/A',base..'/B'
      vim.fn.mkdir(a,'p'); vim.fn.mkdir(b,'p')
      vim.fn.writefile({'a'},a..'/a.lua'); vim.fn.writefile({'b'},b..'/b.lua')
      vim.cmd.edit(a..'/a.lua')
      local editor=vim.api.nvim_get_current_win()
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false},sidebar={follow_active_file=false}}))
      local files_a=assert(app:open('files',{root=a,focus=false}))
      local files_b=assert(app:open('files',{root=b,focus=false}))
      local tab=vim.api.nvim_get_current_tabpage(); local bundle=app.runtime.bundle
      assert(files_b~=files_a and files_a.closed and bundle.layout:get('files')==files_b)
      local files_session; for _,s in pairs(bundle.files.sessions) do files_session=s end
      assert(files_session.workspace.roots[1].path==assert((vim.uv or vim.loop).fs_realpath(b)))
      local outline_a=assert(app:open('outline',{root=a,focus=false}))
      local outline_b=assert(app:open('outline',{root=b,focus=false}))
      assert(outline_b~=outline_a and outline_a.closed and bundle.outline.sessions[tab].workspace.id==app.runtime.tab_workspaces[tab].id)
      local problems_a=assert(app:open('problems',{root=a,focus=false}))
      local problems_b=assert(app:open('problems',{root=b,focus=false}))
      local problems_session,problem_sessions; problem_sessions=0
      for _,s in pairs(bundle.problems.sessions) do problems_session=s; problem_sessions=problem_sessions+1 end
      assert(problem_sessions==1,vim.inspect(bundle.problems:status()))
      assert(problems_b~=problems_a,vim.inspect({a=problems_a.buffer,b=problems_b.buffer}))
      assert(problems_a.closed,vim.inspect({closed=problems_a.closed,layout=bundle.layout:status()}))
      assert(problems_session.workspace.id==app.runtime.tab_workspaces[tab].id,
        vim.inspect({session=problems_session.workspace.id,runtime=app.runtime.tab_workspaces[tab].id}))
      assert(vim.api.nvim_get_current_win()==editor,vim.inspect({current=vim.api.nvim_get_current_win(),editor=editor}))
      assert(bundle.layout:status().active_views==1,vim.inspect(bundle.layout:status()))
      app:dispose()
      assert(bundle.layout:status().active_views==0 and vim.api.nvim_win_is_valid(editor))
      vim.fn.delete(base,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["Files and Problems retain scrolled projections across public sidebar switching"] = function()
    local result=evaluate([[
      vim.o.columns=120; vim.o.lines=35
      local root=vim.fn.tempname()..'-sidebar-scroll'
      vim.fn.mkdir(root,'p')
      for i=1,100 do vim.fn.writefile({'line'},root..string.format('/file%03d.txt',i)) end
      vim.cmd.edit(root..'/file001.txt')
      local buffer=vim.api.nvim_get_current_buf()
      local ns=vim.api.nvim_create_namespace('workbench-retention')
      local diagnostics={}
      for i=1,100 do diagnostics[i]={lnum=0,col=0,severity=1,message=string.format('message %03d',i)} end
      vim.diagnostic.set(ns,buffer,diagnostics)
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false},sidebar={follow_active_file=false}}))
      local files=assert(app:open('files',{root=root}))
      assert(vim.wait(3000,function() return #files.rows>=101 end,5))
      for _=1,69 do files:move(1) end
      local files_id,files_scroll=files.selected_id,files.scroll_offset
      assert(files_scroll>0)
      local problems=assert(app:open('problems'))
      for _,item in ipairs(problems.model.items) do
        if item.kind=='directory' or item.kind=='file' then problems.expanded[item.id]=true end
      end
      problems:update(problems.model)
      for _=1,69 do problems:move(1) end
      local problems_id,problems_scroll=problems.selected_id,problems.scroll_offset
      local expanded=vim.deepcopy(problems.expanded)
      assert(problems_scroll>0)
      files=assert(app:open('files'))
      assert(files.selected_id==files_id and files.scroll_offset==files_scroll,'Files scroll was lost')
      problems=assert(app:open('problems'))
      assert(problems.selected_id==problems_id and problems.scroll_offset==problems_scroll,'Problems scroll was lost')
      assert(vim.deep_equal(problems.expanded,expanded),'Problems expansion was lost')
      app:dispose()
      assert(#vim.diagnostic.get(buffer,{namespace=ns})==100)
      vim.diagnostic.reset(ns,buffer)
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["public Outline retains state across switching with real Pyright replies"] = function()
    local command=vim.fn.exepath('pyright-langserver')
    if command=='' then MiniTest.skip('pyright-langserver is not installed on this host') end
    local result=evaluate([[
      local command=...
      local root=vim.fn.tempname()..'-outline-pyright'
      vim.fn.mkdir(root,'p')
      vim.fn.writefile({'class Alpha:','    def method(self):','        return 1','','class Beta:','    pass'},root..'/sample.py')
      vim.cmd.edit(root..'/sample.py')
      local buf=vim.api.nvim_get_current_buf()
      local editor=vim.api.nvim_get_current_win()
      local client_id=assert(vim.lsp.start({name='workbench-retention-pyright',cmd={command,'--stdio'},root_dir=root},{bufnr=buf}))
      assert(vim.wait(20000,function()
        local client=vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[buf]
      end,10))
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true}))
      local view=assert(app:open('outline',{root=root,focus=false}))
      local controller=app.runtime.bundle.outline
      local tab=vim.api.nvim_get_current_tabpage()
      local session=controller.sessions[tab]
      assert(vim.wait(20000,function() return session.status=='ready' end,10),vim.inspect(session.error))
      local alpha,beta
      for _,item in ipairs(session.items) do
        if item.label=='Alpha' then alpha=item.id end
        if item.label=='Beta' then beta=item.id end
      end
      assert(alpha and beta,vim.inspect(session.items))
      assert(controller:set_order('name'))
      assert(view:toggle_expanded(alpha))
      for _=1,10 do if view.selected_id==beta then break end; assert(view:move(1)) end
      assert(view.selected_id==beta and view.expanded[alpha]==false)
      assert(app:open('files',{focus=false}))
      assert(controller:status().session_count==0 and controller:status().request_count==0)
      view=assert(app:open('outline',{focus=false}))
      session=controller.sessions[tab]
      assert(vim.wait(20000,function() return session.status=='ready' end,10))
      assert(view.selected_id==beta and view.expanded[alpha]==false and session.order=='name')
      assert(vim.api.nvim_get_current_win()==editor)
      app:dispose()
      local client=assert(vim.lsp.get_client_by_id(client_id))
      assert(not client:is_stopped())
      vim.lsp.stop_client(client_id,true)
      assert(vim.wait(5000,function() return vim.lsp.get_client_by_id(client_id)==nil end,10))
      vim.fn.delete(root,'rf')
      return true
    ]],command)
    expect.equality(result,true)
  end,

  ["public sidebar views load lazily switch exclusively and obey live view configuration"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false}}))
      local root=vim.fn.tempname()..'-sidebar-views'
      vim.fn.mkdir(root,'p'); vim.fn.writefile({'local needle=1'},root..'/note.lua')
      vim.cmd.edit(root..'/note.lua')
      local editor=vim.api.nvim_get_current_win()
      local files=assert(app:open('files',{root=root,focus=false}))
      assert(package.loaded['workbench.controllers.outline']==nil and package.loaded['workbench.controllers.problems']==nil)
      assert(app:open('search',{query='needle',focus=false}))
      local bundle=app.runtime.bundle
      local tab=vim.api.nvim_get_current_tabpage()
      local search=bundle.search.active[tab]
      assert(vim.wait(3000,function() return search.phase=='Complete' end,5))
      local listed=app.actions:list({workspace=app.runtime.tab_workspaces[tab]})
      local found=false
      for _,action in ipairs(listed) do if action.id=='problems.open' then found=true end end
      assert(found and package.loaded['workbench.controllers.problems']==nil and package.loaded['workbench.providers.diagnostics']==nil)
      local other_root=root..'/constructor-root'; vim.fn.mkdir(other_root,'p')
      local old_workspace=vim.deepcopy(app.runtime.tab_workspaces[tab])
      local place=bundle.layout._place
      bundle.layout._place=function() return nil,{code='injected_mount',message='failed Search window'} end
      local failed_search,search_error=app:open('search',{root=other_root,query='needle',focus=false})
      bundle.layout._place=place
      assert(not failed_search and search_error.code=='injected_mount')
      assert(vim.deep_equal(app.runtime.tab_workspaces[tab],old_workspace))
      assert(not files.closed and bundle.search.active[tab]==search and not search.view.closed)
      local outline_module=require('workbench.controllers.outline')
      local constructor=outline_module.new
      local provisional_provider
      outline_module.new=function(deps) provisional_provider=deps.provider; return nil,'injected constructor failure' end
      local failed,construction_error=app:open('outline',{root=other_root,focus=false})
      outline_module.new=constructor
      assert(not failed and construction_error.code=='composition_error')
      assert(provisional_provider.disposed and bundle.outline==nil)
      assert(vim.deep_equal(app.runtime.tab_workspaces[tab],old_workspace),'constructor failure changed workspace')
      assert(not files.closed and bundle.search.active[tab]==search and not search.view.closed)
      assert(vim.api.nvim_get_current_win()==editor)
      local original_place=bundle.layout._place
      bundle.layout._place=function() return nil,{code='injected_sidebar_mount',message='failed sidebar window'} end
      local failed_mount,mount_error=app:open('outline',{root=other_root,focus=false})
      bundle.layout._place=original_place
      assert(not failed_mount and mount_error.code=='injected_sidebar_mount')
      assert(vim.deep_equal(app.runtime.tab_workspaces[tab],old_workspace),'sidebar mount failure changed workspace')
      assert(not files.closed and bundle.search.active[tab]==search and not search.view.closed)
      assert(bundle.layout:get('files')==files and bundle.layout:get('outline')==nil)
      assert(vim.api.nvim_get_current_win()==editor)
      local function only(name)
        local count=0
        for _,v in ipairs(bundle.layout:status().views) do
          if v.placement=='sidebar' then
            assert(v.id==(name=='problems' and 'workbench-problems' or name)); count=count+1
          end
        end
        assert(count==1 and bundle.search.active[tab]==search,vim.inspect({name=name,count=count,layout=bundle.layout:status(),search=bundle.search:status()}))
      end
      local outline=assert(app:open('outline',{focus=false})); only('outline')
      assert(files.closed and vim.api.nvim_get_current_win()==editor)
      local outline_workspace=vim.deepcopy(app.runtime.tab_workspaces[tab])
      local outline_place=bundle.layout._place
      bundle.layout._place=function() return nil,{code='injected_outline_replace',message='failed replacement'} end
      local replaced,replaced_error=app:open('outline',{root=other_root,focus=false})
      bundle.layout._place=outline_place
      assert(not replaced and replaced_error.code=='injected_outline_replace')
      assert(app.runtime.tab_workspaces[tab].id==outline_workspace.id and bundle.layout:get('outline')==outline)
      assert(not outline.closed and vim.api.nvim_get_current_win()==editor)
      local problems=assert(app:open('problems',{focus=false})); only('problems')
      assert(outline.closed and vim.api.nvim_get_current_win()==editor)
      assert(app:open('files',{focus=false})); only('files')
      assert(problems.closed)
      local action=app.actions:execute('problems.open',{workspace=app.runtime.tab_workspaces[tab]})
      assert(action.ok,vim.inspect(action)); only('problems')
      assert(app:configure({sidebar={views={'outline','problems'}}}))
      local other=root..'/other'; vim.fn.mkdir(other,'p')
      local before=vim.deepcopy(app.runtime.tab_workspaces[tab])
      local service_before={active_id=bundle.workspace.active_id,generation=bundle.workspace.generation,
        workspaces=vim.deepcopy(bundle.workspace.workspaces),cache=vim.deepcopy(bundle.workspace.canonical_roots)}
      local denied,err=app:open('files',{root=other,focus=false})
      assert(not denied and err.code=='view_disabled')
      assert(vim.deep_equal(app.runtime.tab_workspaces[tab],before))
      assert(vim.deep_equal(service_before,{active_id=bundle.workspace.active_id,generation=bundle.workspace.generation,
        workspaces=bundle.workspace.workspaces,cache=bundle.workspace.canonical_roots}))
      only('problems')
      assert(app:open('outline',{focus=false})); only('outline')
      assert(not app:configure({sidebar={views={}}}))
      only('outline')
      assert(app:configure({sidebar={views={'files'}}}))
      assert(bundle.layout:status().active_views==1)
      local disabled=app.actions:execute('problems.open',{workspace=app.runtime.tab_workspaces[tab]})
      assert(not disabled.ok and disabled.error.code=='view_disabled',vim.inspect(disabled))
      assert(bundle.layout:status().active_views==1)
      assert(app:configure({sidebar={views={'files','outline','problems'}}}))
      assert(app:open('problems',{focus=false})); only('problems')
      app:dispose()
      assert(bundle.outline.disposed and bundle.problems.disposed)
      assert(vim.api.nvim_win_is_valid(editor))
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["Files follows editor buffers only while enabled and rejects stale reveal continuations"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,sidebar={follow_active_file=false}}))
      local root=vim.fn.tempname()..'-follow-file'
      vim.fn.mkdir(root..'/nested','p')
      vim.fn.mkdir(root..'/late','p'); vim.fn.writefile({'c'},root..'/late/c.txt')
      vim.fn.writefile({'a'},root..'/a.txt'); vim.fn.writefile({'b'},root..'/nested/b.txt')
      root=assert((vim.uv or vim.loop).fs_realpath(root))
      local alias=root..'-alias'
      assert((vim.uv or vim.loop).fs_symlink(root,alias))
      vim.cmd.edit(root..'/a.txt')
      local editor=vim.api.nvim_get_current_win()
      assert(app:open('files',{root=root,focus=false}))
      local files=app.runtime.bundle.files
      local tab=vim.api.nvim_get_current_tabpage()
      local session; for _,s in pairs(files.sessions) do session=s end
      assert(vim.wait(3000,function() return session.loaded[session.root_id] end,5))
      assert(not session.follow_scope)
      for _=1,3 do
        assert(app:configure({sidebar={follow_active_file=true}}))
        assert(vim.wait(3000,function()
          local item=session.nodes[session.selected_id]
          return item and item.payload.raw_name=='a.txt'
        end,5))
        assert(session.follow_scope and vim.api.nvim_get_current_win()==editor)
        assert(app:configure({sidebar={follow_active_file=false}}))
        assert(not session.follow_scope)
      end
      vim.cmd.split(root..'/nested/b.txt')
      editor=vim.api.nvim_get_current_win()
      assert(session.nodes[session.selected_id].payload.raw_name=='a.txt')
      assert(app:configure({sidebar={follow_active_file=true}}))
      assert(vim.wait(3000,function()
        local item=session.nodes[session.selected_id]; return item and item.payload.raw_name=='b.txt'
      end,5))
      assert(vim.api.nvim_get_current_win()==editor)
      assert(files:reveal(alias..'/a.txt',tab))
      assert(session.nodes[session.selected_id].payload.raw_name=='a.txt')
      local rejected,err=files:reveal(vim.fn.fnamemodify(root,':h'),tab)
      assert(not rejected and err.code=='outside_root')
      assert(files:reveal(root..'/late/c.txt',tab))
      local pending=assert(session.pending_reveal)
      local owner=session.follow_scope
      assert(app:close('files'))
      assert(pending.continuation()==nil)
      assert(not owner.alive and not session.follow_scope and not session.pending_reveal)
      vim.cmd.edit(root..'/a.txt')
      assert(not session.follow_scope)
      assert(app:open('files',{focus=false}))
      assert(session.follow_scope)
      local selected=session.selected_id
      local current_root=app.runtime.tab_workspaces[tab].id
      vim.cmd.enew()
      assert(session.selected_id==selected and app.runtime.tab_workspaces[tab].id==current_root)
      owner=session.follow_scope
      app:dispose()
      assert(not owner.alive)
      assert((vim.uv or vim.loop).fs_unlink(alias))
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["live visibility policies refresh Files and Search and dispose overrides"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false},search={debounce_ms=0}}))
      local root=vim.fn.tempname()..'-visibility-settings'
      vim.fn.mkdir(root,'p')
      vim.fn.writefile({'needle'},root..'/visible.txt')
      vim.fn.writefile({'needle'},root..'/.hidden.txt')
      vim.fn.writefile({'needle'},root..'/ignored.txt')
      vim.fn.writefile({'ignored.txt'},root..'/.gitignore')
      assert(app:open('files',{root=root,focus=false}))
      assert(app:open('search',{query='needle',focus=false}))
      local tab=vim.api.nvim_get_current_tabpage()
      local bundle=app.runtime.bundle
      local active=bundle.search.active[tab]
      local function count(n)
        assert(vim.wait(3000,function() return active.phase=='Complete' end,5),active.phase)
        assert(bundle.store:summary(active.investigation.current.result_id).item_count==n)
        assert(vim.wait(3000,function()
          for _,s in pairs(bundle.files.sessions) do
            if s.tab==tab then return s.loaded[s.root_id] and vim.deep_equal(s.workspace.policy,active.investigation.workspace.policy) end
          end
        end,5))
      end
      count(1)
      for _=1,3 do
        assert(app:configure({search={hidden=true}})); count(2)
        assert(app:configure({search={ignored=true}})); count(3)
        assert(app:configure({search={hidden=false,ignored=false}})); count(1)
      end
      local override=assert(app.settings:set_override('workspace',active.investigation.workspace.id,'search.hidden',true))
      count(2); assert(override:dispose()); count(1)
      assert(app:configure({search={follow_symlinks=true}}))
      assert(active.phase=='Unavailable' and not active.request)
      assert(active.investigation.workspace.policy.symlinks=='all')
      assert(app:configure({search={follow_symlinks=false}})); count(1)
      assert(bundle.search:toggle_policy(active,'hidden')); count(2)
      assert(app:configure({search={ignored=true}})); count(3)
      local files_session
      for _,s in pairs(bundle.files.sessions) do if s.tab==tab then files_session=s end end
      assert(bundle.files:_toggle_policy(files_session,'hidden')); count(2)
      assert(app:configure({search={ignored=false}})); count(1)
      assert(bundle.search:_set_glob_policy(active,'exclude',{'visible.txt'})); count(0)
      assert(bundle.search:_set_glob_policy(active,'exclude',{})); count(1)
      local before=vim.deepcopy(app.runtime.tab_workspaces[tab])
      local invalid,err=app.runtime:_update_policy(before,{include={bad='*'}})
      assert(not invalid and err.code=='invalid_policy')
      assert(vim.deep_equal(before,app.runtime.tab_workspaces[tab]))
      local entries=0; for _ in pairs(bundle.search.capabilities) do entries=entries+1 end
      assert(entries==1)
      app:dispose(); vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["history settings prune closed and live investigations without losing current results"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false},search={debounce_ms=0},session={max_results_history=16}}))
      local root=vim.fn.tempname()..'-history-settings'
      vim.fn.mkdir(root,'p'); vim.fn.writefile({'needle'},root..'/note.txt')
      assert(app:open('search',{root=root,query='needle',focus=false}))
      local tab=vim.api.nvim_get_current_tabpage()
      local search=app.runtime.bundle.search
      local active=search.active[tab]
      local function settled()
        assert(vim.wait(3000,function() return active.phase=='Complete' end,5),active.phase)
      end
      settled()
      for _=1,17 do assert(search:set_query(active,'needle',true)); settled() end
      local investigation=active.investigation
      assert(#investigation.history==16)
      assert(search:resume(active,1))
      local current=investigation.current
      local discarded=investigation.history[2].store_session
      assert(app:configure({session={max_results_history=2}}))
      assert(#investigation.history==2 and investigation.current==current)
      assert(not app.runtime.bundle.store.sessions[discarded.id])
      local override=assert(app.settings:set_override('session',tostring(tab),'session.max_results_history',1))
      assert(#investigation.history==1 and investigation.history[1]==current)
      assert(override:dispose())
      assert(search:set_query(active,'needle',true)); settled()
      assert(#investigation.history==2)
      assert(app:close())
      assert(app:configure({session={max_results_history=1}}))
      assert(#investigation.history==1)
      assert(app:open('search',{focus=false}))
      assert(search.active[tab].investigation==investigation)
      app:dispose(); vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["live search limits and debounce remain session scoped and cancel stale work"] = function()
    local result = evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false},search={max_results=2,debounce_ms=0}}))
      local root=vim.fn.tempname()..'-search-settings'
      vim.fn.mkdir(root,'p')
      vim.fn.writefile({'needle','needle','needle','needle','needle'},root..'/note.txt')
      assert(app:open('search',{root=root,query='needle',focus=false}))
      local tab=vim.api.nvim_get_current_tabpage()
      local search=app.runtime.bundle.search
      local active=search.active[tab]
      local function settled(count,phase)
        assert(vim.wait(3000,function() return active.phase==phase end,5),active.phase)
        local summary=assert(app.runtime.bundle.store:summary(active.investigation.current.result_id))
        assert(summary.item_count==count,vim.inspect(summary))
        assert(not active.request_scope and not active.request)
      end
      settled(2,'Partial')
      local old=active.investigation.current.result_id
      assert(app:configure({search={max_results=5}}))
      settled(5,'Complete')
      assert(app.runtime.bundle.store:summary(old).item_count==2)
      local generation=active.query_generation
      assert(app:configure({search={debounce_ms=300}}))
      assert(active.query_generation==generation)
      assert(search:set_query(active,'needle',false))
      assert(active.phase=='Debouncing' and active.timer_scope)
      local timer=active.timer_scope
      assert(app:configure({search={debounce_ms=0}}))
      settled(5,'Complete')
      assert(not timer.alive)
      vim.cmd('tabnew')
      assert(app:open('search',{root=root,query='needle',focus=false}))
      local sibling=search.active[vim.api.nvim_get_current_tabpage()]
      assert(vim.wait(3000,function() return sibling.phase=='Complete' end,5))
      local sibling_generation=sibling.query_generation
      local override=assert(app.settings:set_override('session',tostring(tab),'search.max_results',1))
      settled(1,'Partial')
      assert(sibling.query_generation==sibling_generation)
      assert(override:dispose())
      settled(5,'Complete')
      assert(app.runtime.bundle.store.limits.max_items==10000)
      assert(app.runtime.bundle.rg.limits.max_items==10000)
      vim.api.nvim_set_current_tabpage(tab)
      vim.fn.writefile({'disk without match'},root..'/overlay.txt')
      local overlay=vim.fn.bufadd(root..'/overlay.txt'); vim.fn.bufload(overlay)
      vim.api.nvim_buf_set_lines(overlay,0,-1,false,{'needle','needle','needle'})
      assert(search:set_query(active,'needle',true))
      settled(5,'Partial')
      assert(app.runtime.bundle.store:summary(active.investigation.current.result_id).error.code=='result_item_limit')
      vim.api.nvim_buf_delete(overlay,{force=true})
      assert(app:close())
      assert(app:configure({search={max_results=2}}))
      assert(app:open('search',{focus=false}))
      active=search.active[tab]
      settled(2,'Partial')
      assert(app:configure({search={debounce_ms=300}}))
      assert(search:set_query(active,'needle',false))
      timer=active.timer_scope
      local provider=app.runtime.bundle.rg
      app:dispose()
      assert(not timer.alive and provider.disposed)
      vim.wait(350,function() return false end,10)
      assert(next(provider.requests)==nil)
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["runtime settings apply to real sidebar geometry and preview lifetimes with rollback"] = function()
    local result = evaluate([[
      vim.o.columns=200; vim.o.lines=60
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,sidebar={width=40,position='right'},preview={enabled=false,max_bytes=1024}}))
      local root=vim.fn.tempname()..'-live-settings'
      vim.fn.mkdir(root,'p'); vim.fn.writefile({'needle '..string.rep('x',3000)},root..'/note.txt')
      local editor=vim.api.nvim_get_current_win()
      local files=assert(app:open('files',{root=root,focus=false}))
      assert(vim.api.nvim_win_get_width(files.window)==40)
      assert(vim.api.nvim_win_get_position(files.window)[2]>0)
      assert(app:open('search',{root=root,query='needle',focus=false}))
      local tab=vim.api.nvim_get_current_tabpage()
      local active=app.runtime.bundle.search.active[tab]
      assert(vim.wait(3000,function() return active.phase=='Complete' end,5))
      assert(not active.preview:status().open and active.preview.last_preview==nil)
      assert(app.runtime.bundle.navigation:status().active_previews==0)
      local inventory=active.scope_owner:inventory().resource_count
      for _=1,3 do
        assert(app:configure({preview={enabled=true},sidebar={width=44,position='left'}}))
        assert(vim.wait(3000,function() return active.preview.last_preview and active.preview.last_preview.lines end,5))
        assert(active.preview.last_preview.total_bytes<=1024 and active.preview.last_preview.truncated)
        assert(vim.api.nvim_win_get_width(files.window)==44)
        assert(vim.api.nvim_win_get_position(files.window)[2]==0)
        assert(vim.api.nvim_get_current_win()==editor)
        assert(app:configure({preview={enabled=false}}))
        assert(not active.preview:status().open and active.preview.last_preview==nil)
        assert(active.scope_owner:inventory().resource_count==inventory)
      end
      local override=assert(app.settings:set_override('session',tostring(tab),'sidebar.width',48))
      assert(vim.api.nvim_win_get_width(files.window)==48)
      assert(override:dispose())
      assert(vim.api.nvim_win_get_width(files.window)==44)
      local preview_override=assert(app.settings:set_override('workspace',active.investigation.workspace.id,'preview.enabled',true))
      assert(vim.wait(3000,function() return active.preview.last_preview and active.preview.last_preview.lines end,5))
      assert(preview_override:dispose())
      assert(not active.preview:status().open)

      local layout=app.runtime.bundle.layout
      local original=layout.apply_settings
      layout.apply_settings=function(self)
        if app.settings:get('sidebar.width').effective==45 then return nil,{message='injected layout failure'} end
        return original(self)
      end
      local before=app:get_config()
      local applied,err=app:configure({sidebar={width=45},preview={enabled=true}})
      assert(not applied and err.code=='setting_apply_failed' and err.rollback_error==nil)
      assert(vim.deep_equal(app:get_config(),before))
      assert(vim.api.nvim_win_get_width(files.window)==44 and not active.preview:status().open)
      layout.apply_settings=original
      assert(app:configure({sidebar={width=16}}))
      assert(vim.api.nvim_win_get_width(files.window)==16)
      assert(app:configure({sidebar={width=80}}))
      assert(vim.api.nvim_win_get_width(files.window)==80)
      app:dispose()
      assert(not vim.api.nvim_buf_is_valid(files.buffer))
      assert(vim.api.nvim_win_is_valid(editor))
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["explicit commands open the public exploration views and disabling releases only owned UI"] = function()
    local result = evaluate([[
      local workbench = require('workbench')
      local temp_root = vim.fn.tempname() .. '-wb25-host'
      assert(vim.fn.mkdir(temp_root, 'p') == 1)
      assert(vim.fn.writefile({'workspace needle'}, temp_root .. '/note.txt') == 0)
      vim.cmd('enew')
      local user_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, {'unsaved user text'})
      vim.bo[user_buf].modified = true
      vim.cmd('tcd ' .. vim.fn.fnameescape(temp_root))

      local not_setup, not_setup_error = workbench.open('files')
      assert(not_setup == nil and not_setup_error.code == 'not_setup')
      assert(workbench.setup({enabled=false}))
      local disabled, disabled_error = workbench.open('files')
      assert(disabled == nil and disabled_error.code == 'disabled')
      assert(workbench.get_status().runtime == nil)
      vim.cmd('Workbench enable')
      assert(workbench.get_status().state == 'enabled')
      vim.cmd('Workbench files')
      local files_open = workbench.get_status().runtime.layout.active_views == 1
      assert(vim.wait(3000, function()
        local sessions = workbench.get_status().runtime.files.sessions
        return sessions[1] and sessions[1].loaded_nodes > 1
      end, 10), 'public Files command did not enumerate the explicit workspace')
      vim.cmd('Workbench search')
      local both_open = workbench.get_status().runtime.layout.active_views == 2
      local runtime = workbench.get_status().runtime
      assert(runtime.files.session_count == 1 and runtime.files.sessions[1].mounted and runtime.search.active_views == 1)

      vim.cmd('Workbench disable')
      local disabled = workbench.get_status()
      local restored_user = vim.api.nvim_buf_is_valid(user_buf)
        and vim.bo[user_buf].modified and vim.api.nvim_buf_get_lines(user_buf, 0, 1, false)[1] == 'unsaved user text'
      local no_views = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
      local workbench_windows = 0
      for _, win in ipairs(no_views) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == 'workbench' then workbench_windows = workbench_windows + 1 end
      end
      assert(workbench.get_status().state == 'disabled')
      local repeated_cycles = 0
      for _ = 1, 3 do
        vim.cmd('Workbench enable')
        local reopened, reopen_error = workbench.open('files', {root=temp_root,focus=false})
        assert(reopened, reopen_error and reopen_error.message)
        vim.cmd('Workbench disable')
        local cycle_status = workbench.get_status()
        assert(cycle_status.state == 'disabled' and cycle_status.runtime == nil)
        repeated_cycles = repeated_cycles + 1
      end
      assert(vim.api.nvim_buf_is_valid(user_buf) and vim.bo[user_buf].modified)
      assert(vim.fn.delete(temp_root, 'rf') == 0)
      vim.bo[user_buf].modified = false
      return {
        not_setup = not_setup_error.code,
        disabled = disabled_error.code,
        files_open = files_open,
        both_open = both_open,
        files_count = runtime.files.session_count,
        disabled = disabled.state,
        runtime_removed = disabled.runtime == nil,
        restored_user = restored_user,
        workbench_windows = workbench_windows,
        repeated_cycles = repeated_cycles,
      }
    ]])
    expect.equality(result.not_setup, "not_setup")
    expect.equality(result.disabled, "disabled")
    expect.equality(result.files_open, true)
    expect.equality(result.both_open, true)
    expect.equality(result.disabled, "disabled")
    expect.equality(result.runtime_removed, true)
    expect.equality(result.restored_user, true)
    expect.equality(result.workbench_windows, 0)
    expect.equality(result.repeated_cycles, 3)
  end,

  ["public views retain per-tab roots across cwd changes and release closed-tab state"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,preview={enabled=false}}))
      local root=vim.fn.tempname()..'-runtime-roots'
      vim.fn.mkdir(root..'/A','p'); vim.fn.mkdir(root..'/B','p')
      vim.fn.writefile({'needle A'},root..'/A/a.txt'); vim.fn.writefile({'needle B'},root..'/B/b.txt')
      root=assert((vim.uv or vim.loop).fs_realpath(root))
      local first=vim.api.nvim_get_current_tabpage()
      local files=assert(app:open('files',{root=root..'/A',focus=false}))
      vim.cmd.tcd({args={root..'/B'}})
      assert(app:open('search',{query='needle',focus=false}))
      local search=app.runtime.bundle.search
      assert(search.active[first].investigation.workspace.roots[1].path==root..'/A')
      assert(app:close())
      assert(app:open('files',{focus=false}))
      assert(app.runtime.tab_workspaces[first].roots[1].path==root..'/A')
      vim.cmd('tabnew')
      local second=vim.api.nvim_get_current_tabpage()
      assert(app:open('files',{root=root..'/B',focus=false}))
      assert(app:open('search',{query='needle',focus=false}))
      assert(search.active[second].investigation.workspace.roots[1].path==root..'/B')
      vim.api.nvim_set_current_tabpage(first)
      assert(app:open('search',{focus=false}))
      assert(search.active[first].investigation.workspace.roots[1].path==root..'/A')
      local actions_workspace=search.get_workspace()
      assert(actions_workspace.roots[1].path==root..'/A')
      actions_workspace.roots[1].path='mutated snapshot'
      assert(search.get_workspace().roots[1].path==root..'/A')
      local first_id=app.runtime.tab_workspaces[first].id
      local active=search.active[first]
      local rejected,reject_error=app:open('search',{root=root..'/B',query={}})
      assert(not rejected and reject_error.code=='invalid_query')
      assert(not active.closed and app.runtime.tab_workspaces[first].id==first_id)
      assert(app:open('files',{root=root..'/B',focus=false}))
      assert(active.closed and not active.scope_owner.alive)
      assert(app.runtime.bundle.workspace:snapshot(first_id)==nil)
      assert(app:open('search',{query='needle',focus=false}))
      assert(search.active[first].investigation.workspace.roots[1].path==root..'/B')
      local shared_id=app.runtime.tab_workspaces[first].id
      vim.cmd('tabclose')
      assert(vim.wait(1000,function() return app.runtime.tab_workspaces[first]==nil end,5))
      assert(app.runtime.tab_workspaces[second].id==shared_id)
      assert(app.runtime.bundle.workspace:snapshot(shared_id))
      local invalid,err=app:open('files',{root=root..'/B/b.txt'})
      assert(not invalid and err.code=='workspace_unavailable')
      assert(app.runtime.tab_workspaces[second].id==shared_id)
      local runtime=app.runtime
      app:dispose()
      assert(next(runtime.tab_workspaces)==nil)
      vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,
})
