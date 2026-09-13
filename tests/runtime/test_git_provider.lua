local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local helpers = [[
local function write_bytes(path, value)
  local file=assert(io.open(path,'wb'))
  assert(file:write(value))
  assert(file:close())
end
local function git(root,...)
  local argv={'git','-C',root}
  for _,value in ipairs({...}) do argv[#argv+1]=value end
  local result=vim.system(argv,{text=false}):wait(10000)
  assert(result.code==0, table.concat(argv,' ')..': '..(result.stderr or ''))
  return result
end
local function repo()
  local root=vim.fn.tempname()..'-wb20-git'
  assert(vim.fn.mkdir(root,'p')==1)
  assert(vim.system({'git','init','--quiet',root},{text=false}):wait(10000).code==0)
  git(root,'config','user.name','Workbench Test')
  git(root,'config','user.email','workbench@example.invalid')
  return root
end
local function workspace(root)
  local service=assert(require('workbench.services.workspace').new({
    root_service={canonicalize=function(_,path) return path end},
    ignore_service={snapshot=function() return {hidden='include',ignored='include',symlinks='never',include={},exclude={}} end},
  }))
  return assert(service:open({explicit_root=root}))
end
local function wait_done(events)
  assert(vim.wait(10000,function()
    return events[#events] and (events[#events].kind=='done' or events[#events].kind=='error')
  end,5),'timed out waiting for Git request')
end
]]

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root,test_root=...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], { root, root .. "/tests" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["porcelain v2 parser retains rename paths, spaces, newlines, conflicts and incremental aggregates"] = function()
    local result = evaluate([[
      local parser=require('workbench.providers.git')
      local ordinary='1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb ordinary name.txt'..string.char(0)
      local rename='2 R. N... 100644 100644 100644 ccccccc ddddddd R100 new name:'..string.char(10)..'break.txt'..string.char(0)..'old name.txt'..string.char(0)
      local conflict='u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc ddddddd conflicted.txt'..string.char(0)
      local untracked='? untracked:'..string.char(10)..'with spaces.txt'..string.char(0)
      local parsed=assert(parser.parse_status(ordinary..rename..conflict..untracked))
      return {files=parsed.files,aggregate=parsed.aggregate}
    ]])
    expect.equality(#result.files, 4)
    expect.equality(result.files[1].path, "ordinary name.txt")
    expect.equality(result.files[2].path, "new name:\nbreak.txt")
    expect.equality(result.files[2].original_path, "old name.txt")
    expect.equality(result.files[2].renamed, true)
    expect.equality(result.files[3].conflict, true)
    expect.equality(result.files[4].path, "untracked:\nwith spaces.txt")
    expect.equality(result.aggregate.total, 4)
    expect.equality(result.aggregate.staged, 1)
    expect.equality(result.aggregate.unstaged, 1)
    expect.equality(result.aggregate.untracked, 1)
    expect.equality(result.aggregate.conflicts, 1)
    expect.equality(result.aggregate.renames, 1)
  end,

  ["real status supports newline rename paths and selected staged diff"] = function()
    local result = evaluate(helpers .. [[
      local root=repo()
      write_bytes(root..'/old name.txt','before\n')
      git(root,'add','--','old name.txt')
      git(root,'commit','--quiet','-m','base')
      local renamed='new name:'..string.char(10)..'break.txt'
      git(root,'mv','--','old name.txt',renamed)
      write_bytes(root..'/'..renamed,'after\n')
      write_bytes(root..'/untracked:'..string.char(10)..'with spaces.txt','new file\n')
      local provider=assert(require('workbench.providers.git').new())
      local events={}
      assert(provider:refresh(workspace(root),function(event) events[#events+1]=event end))
      wait_done(events)
      local snapshot=assert(events[#events].snapshot)
      local renamed_record,untracked
      for _,record in ipairs(snapshot.files) do
        if record.path==renamed then renamed_record=record end
        if record.untracked then untracked=record end
      end
      assert(renamed_record and untracked)
      local diff_events={}
      assert(provider:diff(snapshot,renamed_record,function(event) diff_events[#diff_events+1]=event end))
      wait_done(diff_events)
      local result={event=events[#events],snapshot=snapshot,rename=renamed_record,untracked=untracked,diff=diff_events[#diff_events],state=provider:status()}
      provider:dispose()
      vim.fn.delete(root,'rf')
      return result
    ]])
    expect.equality(result.event.status, "ready")
    expect.equality(result.rename.original_path, "old name.txt")
    expect.equality(result.rename.path, "new name:\nbreak.txt")
    expect.equality(result.untracked.path, "untracked:\nwith spaces.txt")
    expect.equality(result.diff.kind, "done")
    expect.equality(result.diff.text:find("old name.txt", 1, true) ~= nil, true)
    expect.equality(result.diff.text:find("before", 1, true) ~= nil, true)
    expect.equality(result.state.active_requests, 0)
  end,

  ["non-Git root reports unsupported status and rapid same-root refreshes share one process chain"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb20-not-repo'
      assert(vim.fn.mkdir(root,'p')==1)
      local ws=workspace(root)
      local unavailable=assert(require('workbench.providers.git').new())
      local unavailable_events={}
      assert(unavailable:refresh(ws,function(event) unavailable_events[#unavailable_events+1]=event end))
      wait_done(unavailable_events)
      local not_repository=unavailable_events[#unavailable_events]
      unavailable:dispose()
      local fake={calls={}}
      fake.run=function(argv,opts,on_exit)
        local call={argv=vim.deepcopy(argv),opts=opts,on_exit=on_exit,kills={}}
        function call:kill(signal) self.kills[#self.kills+1]=signal end
        fake.calls[#fake.calls+1]=call
        return call
      end
      local provider=assert(require('workbench.providers.git').new({system=fake.run,executable='/fake/git'}))
      local first,second={},{}
      assert(provider:refresh(ws,{generation=11},function(event) first[#first+1]=event end))
      assert(provider:refresh(ws,{generation=12},function(event) second[#second+1]=event end))
      local repo_root='/fake/repository'
      fake.calls[1].opts.stdout(nil,repo_root..'\n'..repo_root..'/.git\n'..repo_root..'/.git\n\n')
      fake.calls[1].on_exit({code=0,signal=0})
      assert(#fake.calls==2)
      fake.calls[2].on_exit({code=0,signal=0})
      assert(vim.wait(5000,function()
        return first[#first] and first[#first].kind=='done' and second[#second] and second[#second].kind=='done'
      end,5))
      local cached={}
      assert(provider:refresh(ws,{generation=13},function(event) cached[#cached+1]=event end))
      assert(vim.wait(1000,function() return cached[#cached] and cached[#cached].kind=='done' end,5))
      local output={not_repository=not_repository,first=first[#first],second=second[#second],cached=cached[#cached],calls=#fake.calls,status=provider:status()}
      provider:dispose()
      vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.not_repository.status, "not_repository")
    expect.equality(result.first.status, "ready")
    expect.equality(result.second.status, "ready")
    expect.equality(result.first.generation, 11)
    expect.equality(result.second.generation, 12)
    expect.equality(result.cached.cached, true)
    expect.equality(result.cached.generation, 13)
    expect.equality(result.calls, 2)
    expect.equality(result.status.active_requests, 0)
  end,

  ["repository identity distinguishes linked worktrees and submodules"] = function()
    local result = evaluate(helpers .. [[
      local root=repo()
      write_bytes(root..'/base.txt','base\n')
      git(root,'add','--','base.txt'); git(root,'commit','--quiet','-m','base')
      local linked=root..'-linked'
      git(root,'worktree','add','--quiet','--detach',linked,'HEAD')
      local subrepo=repo()
      write_bytes(subrepo..'/sub.txt','submodule\n')
      git(subrepo,'add','--','sub.txt'); git(subrepo,'commit','--quiet','-m','sub')
      git(root,'-c','protocol.file.allow=always','submodule','add','--quiet',subrepo,'vendor/sub')
      git(root,'commit','--quiet','-m','add submodule')
      local provider=assert(require('workbench.providers.git').new())
      local function identify(path)
        local events={}
        assert(provider:refresh(workspace(path),function(event) events[#events+1]=event end))
        wait_done(events)
        assert(events[#events].kind=='done' and events[#events].snapshot)
        return events[#events].snapshot.repository
      end
      local ordinary=identify(root)
      local worktree=identify(linked)
      local submodule=identify(root..'/vendor/sub')
      local output={ordinary=ordinary,worktree=worktree,submodule=submodule}
      provider:dispose()
      vim.fn.delete(root,'rf'); vim.fn.delete(linked,'rf'); vim.fn.delete(subrepo,'rf')
      return output
    ]])
    expect.equality(result.ordinary.is_worktree, false)
    expect.equality(result.ordinary.is_submodule, false)
    expect.equality(result.worktree.is_worktree, true)
    expect.equality(result.worktree.is_submodule, false)
    expect.equality(result.submodule.is_submodule, true)
    expect.equality(result.submodule.is_worktree, false)
    expect.equality(result.submodule.superproject_root, result.ordinary.root)
  end,

  ["large selected diffs are bounded and untrusted records are refused"] = function()
    local result = evaluate(helpers .. [[
      local root=repo()
      local lines={}
      for index=1,400 do lines[index]='before '..index end
      write_bytes(root..'/large.txt',table.concat(lines,'\n')..'\n')
      git(root,'add','--','large.txt'); git(root,'commit','--quiet','-m','base')
      for index=1,#lines do lines[index]='after '..index end
      write_bytes(root..'/large.txt',table.concat(lines,'\n')..'\n')
      local provider=assert(require('workbench.providers.git').new({max_diff_lines=24,max_diff_bytes=65536}))
      local events={}
      assert(provider:refresh(workspace(root),function(event) events[#events+1]=event end))
      wait_done(events)
      local snapshot=events[#events].snapshot
      local fake={}; for _,item in ipairs(snapshot.files) do if item.path=='large.txt' then fake=item end end
      local forged,forged_error=provider:diff(snapshot,{path='../outside',id='forged',unstaged=true},function() end)
      local diff_events={}
      assert(provider:diff(snapshot,fake,function(event) diff_events[#diff_events+1]=event end))
      wait_done(diff_events)
      local diff=diff_events[#diff_events]
      local output={forged=forged,forged_error=forged_error,diff=diff,status=provider:status()}
      provider:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.forged, nil)
    expect.equality(result.forged_error.code, "invalid_record")
    expect.equality(result.diff.status, "partial")
    expect.equality(result.diff.truncated, true)
    expect.equality(result.diff.lines <= 24, true)
    expect.equality(result.status.active_requests, 0)
  end,
})
