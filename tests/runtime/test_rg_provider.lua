local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source)
  return child.lua(source, { root })
end

local helpers = [[
local function make_workspace(root, policy, scope)
  policy = policy or { hidden='exclude', ignored='exclude', symlinks='never', include={}, exclude={} }
  local workspace = assert(require('workbench.services.workspace').new({
    root_service = { canonicalize=function(_, path) return path end },
    ignore_service = { snapshot=function() return policy end },
  }))
  return assert(workspace:open({ explicit_root=root, scope=scope })), workspace
end
local function write_bytes(path, value)
  local file=assert(io.open(path,'wb'))
  assert(file:write(value))
  assert(file:close())
end
local function finished(events)
  local last=events[#events]
  return last and (last.kind=='done' or last.kind=='error')
end
local function wait_finished(events)
  assert(vim.wait(5000,function() return finished(events) end,5),'timed out waiting for provider completion')
end
local function items(events)
  local result={}
  for _,event in ipairs(events) do
    if event.kind=='batch' then
      for _,item in ipairs(event.items) do result[#result+1]=item end
    end
  end
  return result
end
local function fake_system()
  local fake={ calls={} }
  fake.run=function(argv,opts,on_exit)
    local call={ argv=vim.deepcopy(argv),opts=opts,on_exit=on_exit,kills={} }
    function call:kill(signal) self.kills[#self.kills+1]=signal end
    fake.calls[#fake.calls+1]=call
    return call
  end
  return fake
end
]]

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], { root, root .. "/tests" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["request item caps are validated and do not change sibling requests"] = function()
    local result=evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-request-caps'
      vim.fn.mkdir(root,'p'); write_bytes(root..'/note.txt','needle\nneedle\nneedle\n')
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new({max_items=3}))
      for _,invalid in ipairs({0,-1,1.5,'1',false}) do
        local handle,err=provider:start({workspace=snapshot,query='needle',max_items=invalid},function() end)
        assert(not handle and err.code=='invalid_request')
      end
      local small,large={},{}
      assert(provider:start({workspace=snapshot,query='needle',generation=1,session_id='small',max_items=1},function(e) small[#small+1]=e end))
      assert(provider:start({workspace=snapshot,query='needle',generation=1,session_id='large',max_items=100},function(e) large[#large+1]=e end))
      wait_finished(small); wait_finished(large)
      assert(#items(small)==1 and small[#small].status=='partial')
      assert(#items(large)==3 and large[#large].status=='complete')
      assert(provider.limits.max_items==3 and provider:status().active_requests==0)
      provider:dispose(); vim.fn.delete(root,'rf')
      return true
    ]])
    expect.equality(result,true)
  end,

  ["real ripgrep produces typed byte locations for Unicode lines and raw newline paths"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-raw-path'
      assert(vim.fn.mkdir(root,'p')==1)
      local raw_name='line:'..string.char(10)..'break.txt'
      write_bytes(root..'/'..raw_name,'🙂 needle after\r\n')
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new())
      local events={}
      local handle=assert(provider:start({workspace=snapshot,query='needle',generation=1,session_id='raw'},function(event) events[#events+1]=event end))
      wait_finished(events)
      local found=items(events)
      local item=assert(found[1])
      local output={
        state=provider:status(),event=events[#events],items=#found,request_scope=handle.scope:inventory(),
        retained={sink=handle.sink,query=handle.query,root=handle.root,provider=handle.provider},
        raw_path=item.payload.raw_path,label=item.label,detail=item.detail,
        match_bytes=item.payload.match_bytes,raw_line=item.payload.raw_line,
        start=item.location.range.start.character,finish=item.location.range.finish.character,
        line=item.location.range.start.line,encoding=item.location.encoding,
        generation=events[#events].generation,argv=handle.id,
      }
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.event.kind, "done")
    expect.equality(result.event.total, 1)
    expect.equality(result.items, 1)
    expect.equality(result.raw_path, "./line:\nbreak.txt")
    expect.equality(result.label, "🙂 needle after")
    expect.equality(result.detail:find("line\\:\\x0Abreak.txt:1", 1, true) ~= nil, true)
    expect.equality(result.match_bytes, "needle")
    expect.equality(result.raw_line, "🙂 needle after")
    expect.equality(result.start, 5)
    expect.equality(result.finish, 11)
    expect.equality(result.line, 0)
    expect.equality(result.encoding, "utf-8")
    expect.equality(result.generation, 1)
    expect.equality(result.state.active_requests, 0)
    expect.equality(result.request_scope.alive, false)
    expect.equality(result.request_scope.pending_callbacks, 0)
    expect.equality(result.request_scope.resource_count, 0)
    expect.equality(result.retained.sink, nil)
    expect.equality(result.retained.query, nil)
    expect.equality(result.retained.root, nil)
    expect.equality(result.retained.provider, nil)
  end,

  ["real rg honors explicit hidden and project-ignore policy without global Git excludes"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-policy'
      assert(vim.fn.mkdir(root..'/.git/info','p')==1)
      write_bytes(root..'/.git/HEAD','ref: refs/heads/main\n')
      write_bytes(root..'/.git/info/exclude','excluded.txt\n')
      write_bytes(root..'/.gitignore','ignored.txt\n')
      write_bytes(root..'/.ignore','shared.txt\n')
      write_bytes(root..'/.hidden','policy marker\n')
      assert(vim.fn.mkdir(root..'/.private','p')==1)
      write_bytes(root..'/.private/hidden-child.txt','policy marker\n')
      write_bytes(root..'/visible.txt','policy marker\n')
      write_bytes(root..'/ignored.txt','policy marker\n')
      write_bytes(root..'/shared.txt','policy marker\n')
      write_bytes(root..'/excluded.txt','policy marker\n')
      local provider=assert(require('workbench.providers.rg').new())
      local function search(policy,generation)
        local snapshot=make_workspace(root,policy)
        local events={}
        assert(provider:start({workspace=snapshot,query='policy marker',generation=generation,session_id='policy-'..generation,flags={fixed=true}},function(event) events[#events+1]=event end))
        wait_finished(events)
        local names={}
        for _,item in ipairs(items(events)) do names[vim.fs.basename(item.location.resource.path)]=true end
        return names,events[#events]
      end
      local default,default_done=search({hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}},1)
      local included,included_done=search({hidden='exclude',ignored='include',symlinks='never',include={},exclude={}},2)
      local all,all_done=search({hidden='include',ignored='include',symlinks='never',include={},exclude={}},3)
      local globbed,globbed_done=search({hidden='exclude',ignored='exclude',symlinks='never',include={'.hidden','.private/**'},exclude={}},4)
      local strict_snapshot=make_workspace(root,{hidden='exclude',ignored='exclude',symlinks='never',include={},exclude={}})
      local ignored_file_events={}
      assert(provider:start({workspace=strict_snapshot,query='policy marker',flags={fixed=true},scope={kind='file',explicit=true,path=root..'/ignored.txt'},generation=5},function(event) ignored_file_events[#ignored_file_events+1]=event end))
      wait_finished(ignored_file_events)
      local include_snapshot=make_workspace(root,{hidden='exclude',ignored='exclude',symlinks='never',include={'*.txt'},exclude={}})
      local include_handle,include_error=provider:start({workspace=include_snapshot,query='policy marker',flags={fixed=true},scope={kind='file',explicit=true,path=root..'/visible.txt'},generation=6},function() end)
      provider:dispose(); vim.fn.delete(root,'rf')
      return {default=default,default_done=default_done,included=included,included_done=included_done,all=all,all_done=all_done,globbed=globbed,globbed_done=globbed_done,ignored_file=items(ignored_file_events),ignored_done=ignored_file_events[#ignored_file_events],include_handle=include_handle,include_error=include_error}
    ]])
    expect.equality(result.default_done.kind, "done")
    expect.equality(result.default["visible.txt"], true)
    expect.equality(result.default["excluded.txt"], true)
    expect.equality(result.default["ignored.txt"], nil)
    expect.equality(result.default["shared.txt"], nil)
    expect.equality(result.default[".hidden"], nil)
    expect.equality(result.included["visible.txt"], true)
    expect.equality(result.included["excluded.txt"], true)
    expect.equality(result.included["ignored.txt"], true)
    expect.equality(result.included["shared.txt"], true)
    expect.equality(result.included[".hidden"], nil)
    expect.equality(result.all[".hidden"], true)
    expect.equality(result.all_done.kind, "done")
    expect.equality(next(result.globbed), nil)
    expect.equality(result.globbed_done.total, 0)
    -- An explicitly selected regular file is a direct ripgrep target, so the
    -- native ignore engine does not prune it. The UI labels this exception.
    expect.equality(#result.ignored_file, 1)
    expect.equality(result.ignored_done.kind, "done")
    expect.equality(result.include_handle, nil)
    expect.equality(result.include_error.code, "file_scope_policy_unsupported")
  end,

  ["leading-dash query is data, invalid regex is an error, and no matches are complete"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-query'
      assert(vim.fn.mkdir(root,'p')==1)
      write_bytes(root..'/dash.txt','-token appears here\n')
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new())
      local function search(query,flags,generation)
        local events={}
        local handle,err=provider:start({workspace=snapshot,query=query,flags=flags,generation=generation,session_id='query-'..generation},function(event) events[#events+1]=event end)
        if handle then wait_finished(events) end
        return events,err
      end
      local dash=search('-token',{fixed=true},1)
      local invalid=search('(',{case='sensitive'},2)
      local empty=search('not-present-anywhere',{fixed=true},3)
      local output={dash=items(dash),dash_done=dash[#dash],invalid=invalid[#invalid],empty=empty[#empty],status=provider:status()}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(#result.dash, 1)
    expect.equality(result.dash_done.kind, "done")
    expect.equality(result.invalid.kind, "error")
    expect.equality(result.invalid.error.code, "invalid_regex")
    expect.equality(result.empty.kind, "done")
    expect.equality(result.empty.total, 0)
    expect.equality(result.empty.completeness, "complete")
    expect.equality(result.status.active_requests, 0)
  end,

  ["non-UTF-8 match bytes survive ripgrep's JSON bytes encoding"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-bytes'
      assert(vim.fn.mkdir(root,'p')==1)
      write_bytes(root..'/bytes.txt',string.char(255)..'needle\n')
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new())
      local events={}
      assert(provider:start({workspace=snapshot,query='needle',flags={fixed=true},generation=1,session_id='bytes'},function(event) events[#events+1]=event end))
      wait_finished(events)
      local item=assert(items(events)[1])
      local output={event=events[#events],raw_path=item.payload.raw_path,raw_line=item.payload.raw_line,label=item.label,match=item.payload.match_bytes,uri=item.location.resource.uri,start=item.location.range.start.character}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.event.kind, "done")
    expect.equality(result.event.total, 1)
    expect.equality(result.raw_path, "./bytes.txt")
    expect.equality(result.raw_line, string.char(255) .. "needle")
    expect.equality(result.label, "\\xFFneedle")
    expect.equality(result.match, "needle")
    expect.equality(result.start, 1)
    expect.equality(result.uri:find("bytes.txt", 1, true) ~= nil, true)
  end,

  ["split JSON Lines chunks preserve partial JSON, UTF-8 bytes, and explicit argv"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-chunks'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end}))
      local events={}
      local handle=assert(provider:start({workspace=snapshot,query='-needle',flags={fixed=true,word=true},generation=9,session_id='chunks'},function(event) events[#events+1]=event end))
      local call=fake.calls[1]
      local raw_name=string.char(255)..'.txt'
      local encoded=vim.json.encode({type='match',data={path={bytes=vim.base64.encode(raw_name)},lines={text='🙂 -needle text\n'},line_number=1,submatches={{match={text='-needle'},start=5,['end']=12}}}})..'\n'
      for index=1,#encoded do call.opts.stdout(nil,encoded:sub(index,index)) end
      call.opts.stderr(nil,'')
      call.on_exit({code=0,signal=0})
      wait_finished(events)
      local item=assert(items(events)[1])
      local positions={}
      for index,value in ipairs(call.argv) do positions[value]=index end
      local output={events=events,items=items(events),cwd=call.opts.cwd,text=call.opts.text,argv=call.argv,query_after_e=call.argv[positions['-e']+1],path_after_separator=call.argv[positions['--']+1],status=provider:status(),location=item.location,raw_path=item.payload.raw_path}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.events[#result.events].kind, "done")
    expect.equality(#result.items, 1)
    expect.equality(result.location.range.start.character, 5)
    expect.equality(result.location.range.finish.character, 12)
    expect.equality(result.raw_path, string.char(255) .. ".txt")
    expect.equality(result.location.resource.uri:find("%%ff") ~= nil, true)
    expect.equality(result.query_after_e, "-needle")
    expect.equality(result.path_after_separator, ".")
    expect.equality(result.text, false)
    expect.equality(result.cwd ~= "", true)
    expect.equality(result.status.active_requests, 0)
    expect.equality(table.concat(result.argv, " "):find("--no-config", 1, true) ~= nil, true)
    expect.equality(table.concat(result.argv, " "):find("--no-ignore-global", 1, true) ~= nil, true)
    expect.equality(table.concat(result.argv, " "):find("--sort path", 1, true) == nil, true)
  end,

  ["empty query and missing ripgrep never spawn a process"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-missing'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local missing=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '' end}))
      local capability=missing:capabilities({workspace=snapshot})
      local empty_events={}
      local empty=assert(missing:start({workspace=snapshot,query='',generation=1,session_id='empty'},function(event) empty_events[#empty_events+1]=event end))
      wait_finished(empty_events)
      local absent,absent_error=missing:start({workspace=snapshot,query='anything',generation=2,session_id='missing'},function() end)
      local output={capability=capability,empty_events=empty_events,empty_active=empty.active,absent=absent,absent_error=absent_error,calls=#fake.calls}
      missing:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.capability.state, "unavailable")
    expect.equality(result.empty_events[1].status, "empty")
    expect.equality(result.empty_events[#result.empty_events].kind, "done")
    expect.equality(result.empty_active, false)
    expect.equality(result.absent, nil)
    expect.equality(result.absent_error.code, "missing_dependency")
    expect.equality(result.calls, 0)
  end,

  ["symlink policies that cannot be safely reproduced are explicitly unavailable"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-symlinks'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root,{hidden='exclude',ignored='exclude',symlinks='internal',include={},exclude={}})
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end}))
      local capability=provider:capabilities({workspace=snapshot})
      local handle,err=provider:start({workspace=snapshot,query='anything',generation=1},function() end)
      provider:dispose(); vim.fn.delete(root,'rf')
      return {capability=capability,handle=handle,error=err,calls=#fake.calls}
    ]])
    expect.equality(result.capability.state, "unsupported")
    expect.equality(result.capability.reason, "symlink_policy_unsupported")
    expect.equality(result.handle, nil)
    expect.equality(result.error.code, "symlink_policy_unsupported")
    expect.equality(result.calls, 0)
  end,

  ["folder scopes stay inside the explicit workspace root"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-scope'
      local nested=root..'/nested'
      local outside=vim.fn.tempname()..'-wb09-rg-outside'
      assert(vim.fn.mkdir(nested,'p')==1)
      assert(vim.fn.mkdir(outside,'p')==1)
      write_bytes(nested..'/inside.txt','scope marker\n')
      write_bytes(nested..'/sibling.txt','scope marker\n')
      write_bytes(nested..'/bang!name[1].txt','special scope marker\n')
      write_bytes(outside..'/outside.txt','scope marker\n')
      local link_path=root..'/external-link'
      local link_err=(vim.uv or vim.loop).fs_symlink(outside,link_path,{dir=true})
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new())
      local events={}
      assert(provider:start({workspace=snapshot,query='scope',scope={kind='folder',explicit=true,path=nested},generation=1},function(event) events[#events+1]=event end))
      wait_finished(events)
      local scoped=items(events)
      local file_events={}
      assert(provider:start({workspace=snapshot,query='scope marker',flags={fixed=true},scope={kind='file',explicit=true,path=nested..'/inside.txt'},generation=2},function(event) file_events[#file_events+1]=event end))
      wait_finished(file_events)
      local file_items=items(file_events)
      local special_events={}
      assert(provider:start({workspace=snapshot,query='special scope marker',flags={fixed=true},scope={kind='file',explicit=true,path=nested..'/bang!name[1].txt'},generation=3},function(event) special_events[#special_events+1]=event end))
      wait_finished(special_events)
      local special_items=items(special_events)
      local outside_handle,outside_error=provider:start({workspace=snapshot,query='scope',scope={kind='folder',explicit=true,path=outside},generation=2},function() end)
      local link_handle,link_error
      if not link_err then link_handle,link_error=provider:start({workspace=snapshot,query='scope',scope={kind='file',explicit=true,path=link_path..'/outside.txt'},generation=4},function() end) end
      local scoped_nested=true
      for _,item in ipairs(scoped) do if not item.location.resource.path:find('nested/',1,true) then scoped_nested=false end end
      local output={count=#scoped,scoped_nested=scoped_nested,file_count=#file_items,file_path=file_items[1] and file_items[1].location.resource.path,special_count=#special_items,special_path=special_items[1] and special_items[1].location.resource.path,outside_handle=outside_handle,outside_error=outside_error,link_error=link_error,link_created=not link_err}
      provider:dispose(); vim.fn.delete(root,'rf'); vim.fn.delete(outside,'rf')
      return output
    ]])
    expect.equality(result.count, 3)
    expect.equality(result.scoped_nested, true)
    expect.equality(result.file_count, 1)
    expect.equality(result.file_path:find("nested/inside.txt", 1, true) ~= nil, true)
    expect.equality(result.special_count, 1)
    expect.equality(result.special_path:find("bang!name[1].txt", 1, true) ~= nil, true)
    expect.equality(result.outside_handle, nil)
    expect.equality(result.outside_error.code, "outside_root")
    if result.link_created then
      expect.equality(result.link_error.code, "symlink_scope_unsupported")
    end
  end,

  ["oversized JSON records become visible truncation and stderr retention is bounded"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-limits'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_json_line_bytes=16,max_pending_output_bytes=1024,max_stderr_bytes=8,max_error_bytes=64}))
      local truncated_events={}
      local truncated=assert(provider:start({workspace=snapshot,query='x',generation=1,session_id='long'},function(event) truncated_events[#truncated_events+1]=event end))
      local too_long=fake.calls[1]
      too_long.opts.stdout(nil,string.rep('x',17))
      assert(vim.wait(1000,function() return truncated_events[2] and truncated_events[2].status=='partial' end,5),'oversized line did not trigger a bounded partial status')
      too_long.on_exit({code=143,signal=15})
      wait_finished(truncated_events)
      local error_events={}
      assert(provider:start({workspace=snapshot,query='y',generation=2,session_id='stderr'},function(event) error_events[#error_events+1]=event end))
      local noisy=fake.calls[2]
      noisy.opts.stderr(nil,string.rep('E',80))
      noisy.on_exit({code=2,signal=0})
      wait_finished(error_events)
      local output={truncated=truncated_events[#truncated_events],truncated_status=truncated_events[2],killed=#too_long.kills,stderr=error_events[#error_events],active=provider:status().active_requests}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.truncated.kind, "done")
    expect.equality(result.truncated.status, "partial")
    expect.equality(result.truncated.completeness, "truncated")
    expect.equality(result.truncated_status.reason, "json_line_limit")
    expect.equality(result.killed > 0, true)
    expect.equality(result.stderr.kind, "error")
    expect.equality(result.stderr.error.stderr_truncated, true)
    expect.equality(#result.stderr.error.message < 100, true)
    expect.equality(result.active, 0)
  end,

  ["new session generations cancel old process output and enforce request concurrency"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-races'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_active_requests=4,max_concurrent_per_workspace=2}))
      local old_events,new_events,third_events={},{},{}
      local old=assert(provider:start({workspace=snapshot,query='old',generation=1,session_id='same'},function(event) old_events[#old_events+1]=event end))
      local old_call=fake.calls[1]
      old_call.opts.stdout(nil,vim.json.encode({type='match',data={path={text='staged.txt'},lines={text='staged old\n'},line_number=1,submatches={{match={text='old'},start=7,['end']=10}}}})..'\n')
      local current=assert(provider:start({workspace=snapshot,query='new',generation=2,session_id='same'},function(event) new_events[#new_events+1]=event end))
      local second=assert(provider:start({workspace=snapshot,query='other',generation=3,session_id='other'},function(event) third_events[#third_events+1]=event end))
      local third,third_error=provider:start({workspace=snapshot,query='overflow',generation=4,session_id='third'},function() end)
      old_call.opts.stdout(nil,vim.json.encode({type='match',data={path={text='stale.txt'},lines={text='old\n'},line_number=1,submatches={{match={text='old'},start=0,['end']=3}}}})..'\n')
      old_call.on_exit({code=0,signal=0})
      old:cancel('test cleanup'); current:cancel('test cleanup'); second:cancel('test cleanup')
      provider:dispose()
      local output={old_status=old_events[#old_events],new_status=new_events[#new_events],old_batches=items(old_events),old_kills=#old_call.kills,old_scope=old.scope:inventory(),third=third,third_error=third_error,calls=#fake.calls,active=provider:status().active_requests}
      vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.old_status.status, "cancelled")
    expect.equality(#result.old_batches, 0)
    expect.equality(result.old_kills, 1)
    expect.equality(result.old_scope.pending_callbacks, 0)
    expect.equality(result.old_scope.resource_count, 0)
    expect.equality(result.third, nil)
    expect.equality(result.third_error.code, "request_capacity")
    expect.equality(result.calls, 3)
    expect.equality(result.active, 0)
  end,

  ["result, batch, and pending-output limits stop producers visibly"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-result-limits'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_items=1,max_batch_items=1,max_json_line_bytes=4096}))
      local events={}
      local handle=assert(provider:start({workspace=snapshot,query='x',generation=1,session_id='count'},function(event) events[#events+1]=event end))
      local record=vim.json.encode({type='match',data={path={text='hit.txt'},lines={text='x\n'},line_number=1,submatches={{match={text='x'},start=0,['end']=1}}}})..'\n'
      fake.calls[1].opts.stdout(nil,record..record)
      assert(vim.wait(1000,function() for _,event in ipairs(events) do if event.status=='partial' then return true end end return false end,5),'item cap did not report truncation')
      fake.calls[1].on_exit({code=143,signal=15})
      wait_finished(events)
      local queue_provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_pending_output_bytes=32}))
      local queue_events={}
      assert(queue_provider:start({workspace=snapshot,query='y',generation=2,session_id='queue'},function(event) queue_events[#queue_events+1]=event end))
      fake.calls[2].opts.stdout(nil,string.rep('q',64))
      assert(vim.wait(1000,function() return queue_events[2] and queue_events[2].status=='partial' end,5),'queue cap did not report truncation')
      fake.calls[2].on_exit({code=143,signal=15})
      wait_finished(queue_events)
      local batch_provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_batch_bytes=16}))
      local batch_events={}
      assert(batch_provider:start({workspace=snapshot,query='z',generation=3,session_id='batch'},function(event) batch_events[#batch_events+1]=event end))
      fake.calls[3].opts.stdout(nil,vim.json.encode({type='match',data={path={text='long-name.txt'},lines={text='z\n'},line_number=1,submatches={{match={text='z'},start=0,['end']=1}}}})..'\n')
      assert(vim.wait(1000,function() return batch_events[2] and batch_events[2].status=='partial' end,5),'single-item batch cap did not report truncation')
      fake.calls[3].on_exit({code=143,signal=15})
      wait_finished(batch_events)
      local output={count=events[#events],count_items=#items(events),count_kills=#fake.calls[1].kills,queue=queue_events[#queue_events],queue_kills=#fake.calls[2].kills,batch=batch_events[#batch_events],batch_items=#items(batch_events),batch_kills=#fake.calls[3].kills,old_scope=handle.scope:inventory()}
      provider:dispose(); queue_provider:dispose(); batch_provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.count.status, "partial")
    expect.equality(result.count.limit_reason, "result_count_limit")
    expect.equality(result.count_items, 1)
    expect.equality(result.count_kills > 0, true)
    expect.equality(result.queue.status, "partial")
    expect.equality(result.queue.limit_reason, "output_queue_limit")
    expect.equality(result.queue_kills > 0, true)
    expect.equality(result.batch.status, "partial")
    expect.equality(result.batch.limit_reason, "item_batch_limit")
    expect.equality(result.batch_items, 0)
    expect.equality(result.batch_kills > 0, true)
    expect.equality(result.old_scope.alive, false)
    expect.equality(result.old_scope.pending_callbacks, 0)
    expect.equality(result.old_scope.resource_count, 0)
  end,

  ["real ripgrep oversized single lines stop at the bounded JSON tail"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-huge-line'
      assert(vim.fn.mkdir(root,'p')==1)
      write_bytes(root..'/huge.txt','needle'..string.rep('x',128*1024)..'\n')
      local snapshot=make_workspace(root)
      local provider=assert(require('workbench.providers.rg').new({max_json_line_bytes=16*1024,max_pending_output_bytes=256*1024}))
      local events={}
      assert(provider:start({workspace=snapshot,query='needle',flags={fixed=true},generation=1},function(event) events[#events+1]=event end))
      assert(vim.wait(5000,function() for _,event in ipairs(events) do if event.status=='partial' then return true end end return false end,2),'large rg line did not trigger bounded truncation')
      assert(vim.wait(5000,function() return events[#events] and events[#events].kind=='done' end,2),'terminated large-line process was not reaped')
      local output={events=events,items=#items(events),scope=provider:status()}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.events[#result.events].kind, "done")
    expect.equality(result.events[#result.events].status, "partial")
    expect.equality(result.events[#result.events].completeness, "truncated")
    expect.equality(result.events[#result.events].limit_reason, "json_line_limit")
    expect.equality(result.items, 0)
    expect.equality(result.scope.active_requests, 0)
  end,

  ["one hundred cancelled searches dispose owned callbacks and process handles"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-churn'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end}))
      local empty_record=vim.json.encode({type='begin',data={path={text='late.txt'}}})..'\n'
      local all_scopes_clean=true
      for index=1,100 do
        local handle=assert(provider:start({workspace=snapshot,query='cycle',generation=index,session_id='cycle-'..index},function() end))
        local call=fake.calls[index]
        call.opts.stdout(nil,empty_record)
        assert(handle:cancel('cycle cleanup'))
        call.opts.stdout(nil,empty_record)
        call.on_exit({code=0,signal=0})
        local inventory=handle.scope:inventory()
        if inventory.alive or inventory.pending_callbacks~=0 or inventory.resource_count~=0 then all_scopes_clean=false end
      end
      local status=provider:status()
      local root_scope=provider.scope:inventory()
      provider:dispose(); vim.fn.delete(root,'rf')
      return {calls=#fake.calls,all_scopes_clean=all_scopes_clean,status=status,root_scope=root_scope}
    ]])
    expect.equality(result.calls, 100)
    expect.equality(result.all_scopes_clean, true)
    expect.equality(result.status.active_requests, 0)
    expect.equality(result.status.requests, {})
    expect.equality(result.root_scope.resource_count, 0)
    expect.equality(result.root_scope.pending_callbacks, 0)
  end,

  ["reentrant cancellation during batch delivery stops remaining submatches"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb09-rg-reentrant'
      assert(vim.fn.mkdir(root,'p')==1)
      local snapshot=make_workspace(root)
      local fake=fake_system()
      local provider=assert(require('workbench.providers.rg').new({system=fake.run,executable=function() return '/fake/rg' end,max_batch_items=1}))
      local events,handle={},nil
      handle=assert(provider:start({workspace=snapshot,query='x',generation=1},function(event)
        events[#events+1]=event
        if event.kind=='batch' then handle:cancel(string.rep('reason',1000)..'\n\27[31m') end
      end))
      local call=fake.calls[1]
      call.opts.stdout(nil,vim.json.encode({type='match',data={path={text='same.txt'},lines={text='xx\n'},line_number=1,submatches={{match={text='x'},start=0,['end']=1},{match={text='x'},start=1,['end']=2}}}})..'\n')
      assert(vim.wait(1000,function() return not handle.active end,5),'reentrant cancellation did not dispose the request')
      call.on_exit({code=0,signal=0})
      local found=items(events)
      local output={items=#found,last=events[#events],kills=#call.kills,scope=handle.scope:inventory(),provider=provider:status()}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.items, 1)
    expect.equality(result.last.status, "cancelled")
    expect.equality(#result.last.reason <= 2048, true)
    expect.equality(result.last.reason:find("\n", 1, true), nil)
    expect.equality(result.last.reason:find("\27", 1, true), nil)
    expect.equality(result.kills, 1)
    expect.equality(result.scope.alive, false)
    expect.equality(result.scope.pending_callbacks, 0)
    expect.equality(result.scope.resource_count, 0)
    expect.equality(result.provider.active_requests, 0)
  end,
})
