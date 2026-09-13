local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  local wrapped = "local args={...}; local unpack_fn=unpack or table.unpack; local ok,result=xpcall(function(...)\n" .. source .. "\nend,debug.traceback,unpack_fn(args)); if not ok then return {__child_error=result} end; return result"
  local result = child.lua(wrapped, { ... })
  if type(result) == "table" and result.__child_error then error("persistence-service child evaluation failed: " .. vim.inspect(result.__child_error), 2) end
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
  ["application persistence setting gates writes immediately without automatic saving"] = function()
    local result=evaluate([[
      local app=assert(require('workbench.compose').new())
      assert(app:configure({enabled=true}))
      local base=vim.fn.tempname()..'-persist-setting'
      vim.fn.mkdir(base..'/workspace','p')
      local snapshot={workspaces={{root=base..'/workspace'}}}
      local saved,err=app:save_session(snapshot)
      assert(not saved and err.code=='persistence_disabled' and app.persistence==nil)
      local service=assert(require('workbench.services.persistence').new({state_dir=base..'/state',session_id='setting'}))
      app.persistence=service
      for _=1,3 do
        assert(app:configure({session={persist=true}}))
        assert(#app:list_sessions()<=1)
        saved=assert(app:save_session(snapshot))
        assert(app:configure({session={persist=false}}))
        local denied,denied_error=app:save_session(snapshot)
        assert(not denied and denied_error.code=='persistence_disabled')
        assert(app:restore_session(saved.id).automatic_execution==false)
      end
      local tab=tostring(vim.api.nvim_get_current_tabpage())
      local override=assert(app.settings:set_override('session',tab,'session.persist',true))
      assert(app:save_session(snapshot))
      assert(override:dispose())
      assert(not app:save_session(snapshot))
      assert(app:delete_session(saved.id))
      assert(#app:list_sessions()==0)
      assert(app:configure({session={persist=true}}))
      assert(#app:list_sessions()==0)
      app:dispose(); vim.fn.delete(base,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["save is explicit, stores only bounded data fields, and marks restored results stale"] = function()
    local result = evaluate([[
      local uv=vim.uv; local base=vim.fn.tempname()..'-wb23-save'; assert(vim.fn.mkdir(base,'p')==1); base=assert(uv.fs_realpath(base))
      local root=base..'/workspace'; assert(vim.fn.mkdir(root,'p')==1); local state=base..'/state/sessions'
      local Persistence=require('workbench.services.persistence'); local service=assert(Persistence.new({state_dir=state,session_id='save-one'}))
      local dormant=uv.fs_lstat(state)==nil
      local snapshot={workspaces={{root=root,view={active='search',selected_path='src/main.lua',expanded_paths={'src','src/lib'},scroll_line=8,window=91},
        search={query='needle',flags={fixed=true,ignore_case=false,smart_case=true,whole_word=false},scope={kind='folder',path='src'},selection={path='src/main.lua',line=12},result_id='ephemeral',items={{text='never persist'}},run=function() error('executable state') end}}},
        buffers={bufnr=9},jobs={handle='not data'}}
      local saved=assert(service:save(snapshot)); local listed=assert(service:list()); local restored=assert(service:restore(saved.id))
      local fd=assert(uv.fs_open(saved.path,'r',0)); local raw=assert(uv.fs_read(fd,1024*1024,0)); uv.fs_close(fd); local document=assert(vim.json.decode(raw))
      local workspace=restored.snapshot.workspaces[1]
      local disposed=service:dispose(); local repeated_dispose=service:dispose(); vim.fn.delete(base,'rf')
      return {dormant=dormant,id=saved.id,list_count=#listed,list_state=listed[1].state,available=workspace.available,active=workspace.view.active,
        query=workspace.search.query,scope=workspace.search.scope.path,stale=workspace.search.result_state,rerun=workspace.search.rerun_required,
        no_result_id=workspace.search.result_id==nil,no_window=workspace.view.window==nil,no_job=document.snapshot.jobs==nil,no_function=document.snapshot.workspaces[1].search.run==nil,
        migrated=restored.migrated_from,automatic=restored.automatic_execution,disposed=disposed,repeated_dispose=repeated_dispose}
    ]])
    expect.equality(result.dormant, true)
    expect.equality(result.id, "save-one")
    expect.equality(result.list_count, 1)
    expect.equality(result.list_state, "available")
    expect.equality(result.available, true)
    expect.equality(result.active, "search")
    expect.equality(result.query, "needle")
    expect.equality(result.scope, "src")
    expect.equality(result.stale, "stale")
    expect.equality(result.rerun, true)
    expect.equality(result.no_result_id, true)
    expect.equality(result.no_window, true)
    expect.equality(result.no_job, true)
    expect.equality(result.no_function, true)
    expect.equality(result.migrated, nil)
    expect.equality(result.automatic, false)
    expect.equality(result.disposed, true)
    expect.equality(result.repeated_dispose, false)
  end,

  ["corrupt and future-version records are reported without breaking listing"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb23-corrupt'; assert(vim.fn.mkdir(root..'/sessions','p')==1); root=assert(vim.uv.fs_realpath(root))
      local dir=root..'/sessions'; assert(vim.fn.writefile({'{not valid json'},dir..'/session-corrupt.json')==0)
      assert(vim.fn.writefile({vim.json.encode({schema=19,session_id='future'})},dir..'/session-future.json')==0)
      assert(vim.fn.writefile({vim.json.encode({schema=1,session_id='shape',owner_token='owned',written_at='not-a-time',snapshot={workspaces='not-an-array'}})},dir..'/session-shape.json')==0)
      local service=assert(require('workbench.services.persistence').new({state_dir=dir,session_id='reader'}))
      local records=assert(service:list()); local by_id={}; for _,record in ipairs(records) do by_id[record.id]=record end
      local corrupt,corrupt_error=service:restore('corrupt'); local future,future_error=service:restore('future'); local shape,shape_error=service:restore('shape')
      service:dispose(); vim.fn.delete(root,'rf')
      return {count=#records,corrupt_state=by_id.corrupt.state,corrupt_code=corrupt_error.code,future_state=by_id.future.state,future_code=future_error.code,
        shape_state=by_id.shape.state,shape_code=shape_error.code,shape_nil=shape==nil,corrupt_nil=corrupt==nil,future_nil=future==nil}
    ]])
    expect.equality(result.count, 3)
    expect.equality(result.corrupt_state, "corrupt")
    expect.equality(result.corrupt_code, "corrupt_state")
    expect.equality(result.future_state, "unsupported")
    expect.equality(result.future_code, "unsupported_version")
    expect.equality(result.shape_state, "corrupt")
    expect.equality(result.shape_code, "corrupt_state")
    expect.equality(result.shape_nil, true)
    expect.equality(result.corrupt_nil, true)
    expect.equality(result.future_nil, true)
  end,

  ["missing roots are unavailable and the documented legacy schema migrates without execution"] = function()
    local result = evaluate([[
      local uv=vim.uv; local root=vim.fn.tempname()..'-wb23-legacy'; assert(vim.fn.mkdir(root..'/sessions','p')==1); root=assert(uv.fs_realpath(root))
      local legacy={schema=0,root=root..'/removed-workspace',query='old query',flags={fixed=true},scope={kind='workspace'},view={active='search',selected_path='lost.txt'}}
      assert(vim.fn.writefile({vim.json.encode(legacy)},root..'/sessions/session-old.json')==0)
      local service=assert(require('workbench.services.persistence').new({state_dir=root..'/sessions',session_id='reader'}))
      local restored=assert(service:restore('old')); local workspace=restored.snapshot.workspaces[1]
      service:dispose(); vim.fn.delete(root,'rf')
      return {schema=restored.schema,migrated=restored.migrated_from,root=workspace.root,available=workspace.available,
        stale=workspace.search.result_state,rerun=workspace.search.rerun_required,automatic=restored.automatic_execution}
    ]])
    expect.equality(result.schema, 1)
    expect.equality(result.migrated, 0)
    expect.equality(result.available, false)
    expect.equality(result.stale, "stale")
    expect.equality(result.rerun, true)
    expect.equality(result.automatic, false)
  end,

  ["permission failures and byte/count caps fail without publishing partial state"] = function()
    local result = evaluate([[
      local uv=vim.uv; local base=vim.fn.tempname()..'-wb23-limits'; assert(vim.fn.mkdir(base,'p')==1); base=assert(uv.fs_realpath(base))
      local workspace=base..'/workspace'; assert(vim.fn.mkdir(workspace,'p')==1); local dir=base..'/sessions'
      local blocked=setmetatable({fs_open=function(path,flags,mode) if flags=='wx' then return nil,'EACCES injected' end return uv.fs_open(path,flags,mode) end},{__index=uv})
      local denied=assert(require('workbench.services.persistence').new({state_dir=dir,session_id='denied',uv=blocked}))
      local denied_save,denied_error=denied:save({workspaces={{root=workspace}}}); denied:dispose()
      local one=assert(require('workbench.services.persistence').new({state_dir=dir,session_id='one',max_sessions=1,max_record_bytes=1024,max_total_bytes=1024}))
      local first=assert(one:save({workspaces={{root=workspace}}}))
      local second=assert(require('workbench.services.persistence').new({state_dir=dir,session_id='two',max_sessions=1,max_record_bytes=1024,max_total_bytes=1024}))
      local full,full_error=second:save({workspaces={{root=workspace}}})
      local large,large_error=one:save({workspaces={{root=workspace,search={query=string.rep('q',1000)}}}})
      local records=assert(second:list()); local deleted=assert(second:delete(first.id)); local after_delete=assert(second:save({workspaces={{root=workspace}}}))
      local total_dir=base..'/total-sessions'; local total_services={}; local total_saved=0; local total_code
      for _,id in ipairs({'total-a','total-b','total-c','total-d'}) do
        local current=assert(require('workbench.services.persistence').new({state_dir=total_dir,session_id=id,max_sessions=4,max_record_bytes=1024,max_total_bytes=1024}))
        total_services[#total_services+1]=current
        local saved,save_error=current:save({workspaces={{root=workspace}}})
        if saved then total_saved=total_saved+1 else total_code=save_error.code; break end
      end
      for _,current in ipairs(total_services) do current:dispose() end
      one:dispose(); second:dispose(); vim.fn.delete(base,'rf')
      return {denied=denied_save==nil,denied_code=denied_error.code,partial=uv.fs_lstat(dir..'/session-denied.json')~=nil,
        full=full==nil,full_code=full_error.code,large=large==nil,large_code=large_error.code,record_count=#records,deleted=deleted,after_id=after_delete.id,
        total_saved=total_saved,total_code=total_code}
    ]])
    expect.equality(result.denied, true)
    expect.equality(result.denied_code, "state_write_failed")
    expect.equality(result.partial, false)
    expect.equality(result.full, true)
    expect.equality(result.full_code, "session_limit")
    expect.equality(result.large, true)
    expect.equality(result.large_code, "session_limit")
    expect.equality(result.record_count, 1)
    expect.equality(result.deleted, true)
    expect.equality(result.after_id, "two")
    expect.equality(result.total_code, "session_limit")
    expect.equality(result.total_saved < 4, true)
  end,

  ["separate session identifiers isolate concurrent writers and traversal paths are rejected"] = function()
    local result = evaluate([[
      local uv=vim.uv; local base=vim.fn.tempname()..'-wb23-two'; assert(vim.fn.mkdir(base,'p')==1); base=assert(uv.fs_realpath(base))
      local workspace=base..'/workspace'; assert(vim.fn.mkdir(workspace,'p')==1); local dir=base..'/sessions'
      local Persistence=require('workbench.services.persistence')
      local first=assert(Persistence.new({state_dir=dir,session_id='process-a'})); local second=assert(Persistence.new({state_dir=dir,session_id='process-b'}))
      local a=assert(first:save({workspaces={{root=workspace,search={query='first'}}}}))
      local b=assert(second:save({workspaces={{root=workspace,search={query='second'}}}}))
      local conflict=assert(Persistence.new({state_dir=dir,session_id='process-a'})); local conflict_save,conflict_error=conflict:save({workspaces={{root=workspace}}})
      local records=assert(first:list()); local restored_a=assert(first:restore('process-a')); local restored_b=assert(first:restore('process-b'))
      local unsafe,unsafe_error=first:save({workspaces={{root=workspace,view={selected_path='../outside'}}}})
      local filenames={uv.fs_lstat(a.path)~=nil,uv.fs_lstat(b.path)~=nil}
      first:dispose(); second:dispose(); conflict:dispose(); vim.fn.delete(base,'rf')
      return {different=a.id~=b.id,records=#records,queries={restored_a.snapshot.workspaces[1].search.query,restored_b.snapshot.workspaces[1].search.query},
        conflict=conflict_save==nil,conflict_code=conflict_error.code,unsafe=unsafe==nil,unsafe_code=unsafe_error.code,filenames=filenames}
    ]])
    expect.equality(result.different, true)
    expect.equality(result.records, 2)
    expect.equality(result.queries, { "first", "second" })
    expect.equality(result.conflict, true)
    expect.equality(result.conflict_code, "session_conflict")
    expect.equality(result.unsafe, true)
    expect.equality(result.unsafe_code, "invalid_session")
    expect.equality(result.filenames, { true, true })
  end,
})
