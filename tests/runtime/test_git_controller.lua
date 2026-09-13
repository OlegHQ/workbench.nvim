local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local helpers = [[
local function write(path,value)
  local file=assert(io.open(path,'wb')); assert(file:write(value)); assert(file:close())
end
local function git(root,...)
  local argv={'git','-C',root}; for _,value in ipairs({...}) do argv[#argv+1]=value end
  local result=vim.system(argv,{text=false}):wait(10000)
  assert(result.code==0,table.concat(argv,' ')..': '..(result.stderr or ''))
end
local function setup_workspace(root)
  local service=assert(require('workbench.services.workspace').new({
    root_service={canonicalize=function(_,path) return path end},
    ignore_service={snapshot=function() return {hidden='include',ignored='include',symlinks='never',include={},exclude={}} end},
  }))
  return assert(service:open({explicit_root=root}))
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
  ["cursor motion is process-free; explicit preview is bounded and closing releases consumers"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb20-git-ui'
      assert(vim.fn.mkdir(root,'p')==1)
      assert(vim.system({'git','init','--quiet',root},{text=false}):wait(10000).code==0)
      git(root,'config','user.name','Workbench Test'); git(root,'config','user.email','workbench@example.invalid')
      write(root..'/changed.txt','before\n'); git(root,'add','--','changed.txt'); git(root,'commit','--quiet','-m','base')
      write(root..'/changed.txt','after\n'); write(root..'/new file.txt','new content\n')
      local calls=0
      local provider=assert(require('workbench.providers.git').new({system=function(argv,opts,on_exit)
        calls=calls+1
        return vim.system(argv,opts,on_exit)
      end}))
      local layout=assert(require('workbench.ui.layout').new())
      local actions=require('workbench.core.actions').new()
      local controller=assert(require('workbench.controllers.git').new({layout=layout,provider=provider,actions=actions}))
      local snapshot=setup_workspace(root)
      local view,session=assert(controller:open(snapshot,{focus=false}))
      assert(vim.wait(10000,function() return session.snapshot~=nil end,5),'Git status did not complete')
      assert(view.model.status=='ready' and #session.snapshot.files==2)
      local status_calls=calls
      view:move(1)
      assert(calls==status_calls,'cursor movement spawned Git')
      assert(controller:_preview(session))
      assert(vim.wait(10000,function() return session.diff_view and session.diff_view.model.status=='ready' end,5),'selected diff did not complete')
      local preview_lines={}
      for _,item in ipairs(session.diff_view.model.items) do preview_lines[#preview_lines+1]=item.label end
      local joined=table.concat(preview_lines,'\n')
      for _=1,#session.diff_view.rows do session.diff_view:move(1) end
      local selected_visible=false
      for _,row in ipairs(session.diff_view.visible_rows) do
        if row.id==session.diff_view.selected_id then selected_visible=true end
      end
      local preview_calls=calls
      assert(preview_calls==status_calls+1,'one selected-file diff should spawn one Git process')
      assert(selected_visible,'diff navigation lost the selected line outside its viewport')
      assert(layout:close('workbench-git-diff'))
      assert(vim.wait(1000,function() return vim.api.nvim_get_current_win()==view.window end,5),'focus did not return to Git status')
      local restored=vim.api.nvim_get_current_win()==view.window
      assert(layout:close('workbench-git'))
      local status={provider=provider:status(),controller=controller:status(),layout=layout:status(),calls=calls}
      controller:dispose(); provider:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return {status_calls=status_calls,preview_calls=preview_calls,restored=restored,preview=joined,status=status}
    ]])
    expect.equality(result.status_calls, 2)
    expect.equality(result.preview_calls, 3)
    expect.equality(result.preview:find("+new content", 1, true) ~= nil, true)
    expect.equality(result.restored, true)
    expect.equality(result.status.provider.active_requests, 0)
    expect.equality(result.status.controller.session_count, 0)
    expect.equality(result.status.layout.active_views, 0)
  end,

  ["closing during refresh cancels Git work and ignores a delayed process exit"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb20-close-refresh'
      assert(vim.fn.mkdir(root,'p')==1)
      local fake={calls={}}
      fake.run=function(argv,opts,on_exit)
        local call={argv=vim.deepcopy(argv),opts=opts,on_exit=on_exit,kills={}}
        function call:kill(signal) self.kills[#self.kills+1]=signal end
        fake.calls[#fake.calls+1]=call
        return call
      end
      local provider=assert(require('workbench.providers.git').new({system=fake.run,executable='/fake/git'}))
      local layout=assert(require('workbench.ui.layout').new())
      local controller=assert(require('workbench.controllers.git').new({layout=layout,provider=provider}))
      local view=assert(controller:open(setup_workspace(root),{focus=false}))
      assert(#fake.calls==1 and provider:status().active_requests==1)
      assert(layout:close('workbench-git'))
      fake.calls[1].opts.stdout(nil,'late bytes')
      fake.calls[1].on_exit({code=0,signal=0})
      local output={kills=fake.calls[1].kills,provider=provider:status(),controller=controller:status(),layout=layout:status()}
      controller:dispose(); provider:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.kills[1], "sigterm")
    expect.equality(result.provider.active_requests, 0)
    expect.equality(result.provider.active_processes, 0)
    expect.equality(result.controller.session_count, 0)
    expect.equality(result.layout.active_views, 0)
  end,

  ["missing Git remains explicitly unavailable without spawning a process"] = function()
    local result = evaluate(helpers .. [[
      local root=vim.fn.tempname()..'-wb20-missing-git'
      assert(vim.fn.mkdir(root,'p')==1)
      local provider=assert(require('workbench.providers.git').new({executable=''}))
      local layout=assert(require('workbench.ui.layout').new())
      local actions=require('workbench.core.actions').new()
      local controller=assert(require('workbench.controllers.git').new({layout=layout,provider=provider,actions=actions}))
      local snapshot=setup_workspace(root)
      local view=assert(controller:open(snapshot,{focus=false}))
      local action
      for _,item in ipairs(actions:list({workspace=snapshot})) do if item.id=='git.open' then action=item end end
      local output={state=view.model.status,reason=view.model.reason,action=action and action.available,provider=provider:status()}
      layout:close('workbench-git'); controller:dispose(); provider:dispose(); layout:dispose(); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.state, "unavailable")
    expect.equality(result.reason, "git executable was not found on PATH")
    expect.equality(result.action.enabled, false)
    expect.equality(result.provider.active_processes, 0)
  end,
})
