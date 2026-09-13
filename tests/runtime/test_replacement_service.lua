local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  local wrapped = "local args={...}; local unpack_fn=unpack or table.unpack; local ok,result=xpcall(function(...)\n" .. source .. "\nend,debug.traceback,unpack_fn(args)); if not ok then return {__child_error=result} end; return result"
  local result = child.lua(wrapped, { ... })
  if type(result) == "table" and result.__child_error then error("replacement-service child evaluation failed: " .. vim.inspect(result.__child_error), 2) end
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
  ["reviewed unloaded replacement preserves CRLF and mode and journals the exact preimage"] = function()
    local result = evaluate([[
      local uv=vim.uv; local root=vim.fn.tempname()..'-wb22-disk'; local state=root..'-state'
      assert(vim.fn.mkdir(root,'p')==1); root=assert(uv.fs_realpath(root))
      local path=root..'/target.txt'; local original='café needle needle\r\nkeep\r\n'
      local fd=assert(uv.fs_open(path,'wx',420)); assert(uv.fs_write(fd,original,0)==#original); uv.fs_close(fd); assert(uv.fs_chmod(path,420))
      local line='café needle needle'; local first=assert(line:find('needle',1,true)); local second=assert(line:find('needle',first+6,true))
      local Resource=require('workbench.core.resource'); local Location=require('workbench.core.location')
      local function item(id,first_byte,last_byte)
        local resource=assert(Resource.from_path(path,{workspace_id='ws'}))
        local location=assert(Location.new(resource,{range={start={line=0,character=first_byte},finish={line=0,character=last_byte}},encoding='utf-8'}))
        return {id=id,kind='match',location=location,payload={provider_id='rg',byte_start=first_byte,byte_end=last_byte,match_bytes=line:sub(first_byte+1,last_byte)}}
      end
      local selected={{item=item('m1',first-1,first-1+6)},{item=item('m2',second-1,second-1+6)}}
      local service=assert(require('workbench.services.replacement').new({state_dir=state}))
      local plan=assert(service:prepare({id='ws',generation=4,roots={{path=root}}},selected,'done',{literal=true}))
      assert(plan.state=='validated' and plan.matched_count==2)
      assert(plan.diff:find('- café needle needle',1,true) and plan.diff:find('+ café done done',1,true))
      local premature,premature_error=service:apply(plan)
      assert(not premature and premature_error.code=='review_required')
      assert(assert(uv.fs_stat(path)).size==#original)
      assert(service:review(plan)); local applied,recovery=service:apply(plan); assert(applied,recovery and recovery.message)
      local fd2=assert(uv.fs_open(path,'r',0)); local actual=assert(uv.fs_read(fd2,1024,0)); uv.fs_close(fd2)
      assert(actual=='café done done\r\nkeep\r\n')
      local mode=uv.fs_stat(path).mode%512
      service:dispose()
      local restarted=assert(require('workbench.services.replacement').new({state_dir=state}))
      local records=assert(restarted:recoveries()); local recovery_record=assert(records[1])
      local preimage=recovery_record.resources[1].preimage_file
      local sidecar_fd=assert(uv.fs_open(state..'/'..preimage,'r',0)); local saved=assert(uv.fs_read(sidecar_fd,#original,0)); uv.fs_close(sidecar_fd)
      local still_applied=assert(uv.fs_stat(path)).size==#actual
      restarted:dispose(); vim.fn.delete(root,'rf'); vim.fn.delete(state,'rf')
      return {state=plan.state,mode=mode,actual=actual,recovery=recovery_record,preimage=saved,still_applied=still_applied,unreviewed=premature_error.code}
    ]])
    expect.equality(result.state, "applied")
    expect.equality(result.mode, 420)
    expect.equality(result.actual, "café done done\r\nkeep\r\n")
    expect.equality(result.preimage, "café needle needle\r\nkeep\r\n")
    expect.equality(result.still_applied, true)
    expect.equality(result.recovery.state, "applied")
    expect.equality(result.recovery.automatic_apply_on_restart, false)
    expect.equality(result.recovery.resources[1].state, "applied")
    expect.equality(result.unreviewed, "review_required")
  end,

  ["overlapping and stale edits fail closed without replacing newer content"] = function()
    local result = evaluate([[
      local uv=vim.uv; local root=vim.fn.tempname()..'-wb22-stale'; assert(vim.fn.mkdir(root,'p')==1); root=assert(uv.fs_realpath(root))
      local path=root..'/target.txt'; local original='needle stays\n'; assert(vim.fn.writefile({'needle stays'},path)==0)
      local Resource=require('workbench.core.resource'); local Location=require('workbench.core.location')
      local function item(id,start,finish,bytes)
        local resource=assert(Resource.from_path(path,{workspace_id='ws'})); local location=assert(Location.new(resource,{range={start={line=0,character=start},finish={line=0,character=finish}},encoding='utf-8'}))
        return {id=id,kind='match',location=location,payload={provider_id='rg',byte_start=start,byte_end=finish,match_bytes=bytes}}
      end
      local service=assert(require('workbench.services.replacement').new({journal=false}))
      local overlap,overlap_error=service:prepare({id='ws',generation=1,roots={{path=root}}},{{item=item('a',0,5,'needl')},{item=item('b',2,6,'edle')}},'x',{literal=true})
      local stale=assert(service:prepare({id='ws',generation=1,roots={{path=root}}},{{item=item('c',0,6,'needle')}},'fresh',{literal=true}))
      assert(service:review(stale)); assert(vim.fn.writefile({'new content'},path)==0)
      local applied,stale_error=service:apply(stale)
      local content=table.concat(vim.fn.readfile(path),'\n')
      local applied_count=#stale.recovery.applied; local unapplied_count=#stale.recovery.unapplied
      service:dispose(); vim.fn.delete(root,'rf')
      return {overlap=overlap==nil,overlap_code=overlap_error.code,applied=applied==true,stale_code=stale_error.code,content=content,state=stale.state,applied_count=applied_count,unapplied_count=unapplied_count,original=original}
    ]])
    expect.equality(result.overlap, true)
    expect.equality(result.overlap_code, "overlapping_matches")
    expect.equality(result.applied, false)
    expect.equality(result.stale_code, "stale_preimage")
    expect.equality(result.content, "new content")
    expect.equality(result.state, "failed")
    expect.equality(result.applied_count, 0)
    expect.equality(result.unapplied_count, 1)
  end,

  ["dirty buffer snapshots apply as one undo group and stale snapshots are rejected"] = function()
    local setup = evaluate([[
      local root=vim.fn.tempname()..'-wb22-buffer'; assert(vim.fn.mkdir(root,'p')==1); root=assert(vim.uv.fs_realpath(root))
      local path=root..'/target.txt'; assert(vim.fn.writefile({'disk needle needle'},path)==0)
      local buf=vim.fn.bufadd(path); vim.fn.bufload(buf); vim.bo[buf].fileformat='dos'; vim.api.nvim_buf_set_lines(buf,0,-1,false,{'dirty needle needle','second'}); vim.bo[buf].modified=true
      vim.api.nvim_buf_call(buf,function() vim.cmd('normal! A!') end)
      _G.wb22_root=root; _G.wb22_path=path; _G.wb22_buf=buf
      return {root=root,path=path,buf=buf}
    ]])
    local applied = evaluate([[
      local path,buf=...; local captured=assert(require('workbench.services.buffers').capture({scope={kind='file',path=path}})).snapshots[1]
      local token=vim.fn.sha256(captured.id); local snapshot={id=token,bufnr=captured.bufnr,path=captured.path,uri=captured.uri,changedtick=captured.changedtick,fileformat=captured.fileformat,endofline=captured.endofline,bomb=captured.bomb,fileencoding=captured.fileencoding,encoding=captured.encoding,content_hash=vim.fn.sha256(captured.content)}
      local Resource=require('workbench.core.resource'); local Location=require('workbench.core.location')
      local function item(id,start)
        local resource=assert(Resource.from_path(path,{workspace_id='ws'})); local location=assert(Location.new(resource,{range={start={line=0,character=start},finish={line=0,character=start+6}},encoding='utf-8'}))
        return {id=id,kind='match',location=location,payload={provider_id='rg',byte_start=start,byte_end=start+6,match_bytes='needle',source_snapshot={id=token}}}
      end
      local service=assert(require('workbench.services.replacement').new({journal=false})); _G.wb22_service=service
      local selected={{item=item('a',6),source_snapshot=snapshot},{item=item('b',13),source_snapshot=snapshot}}
      local plan=assert(service:prepare({id='ws',generation=2,roots={{path=vim.fs.dirname(path)}}},selected,'done',{literal=true})); assert(service:review(plan)); assert(service:apply(plan)); _G.wb22_plan=plan
      return vim.api.nvim_buf_get_lines(buf,0,-1,false)
    ]], setup.path, setup.buf)
    local undo = evaluate([[
      local path=...; local buf=_G.wb22_buf
      vim.api.nvim_buf_call(buf,function() vim.cmd('undo') end)
      local undone=vim.api.nvim_buf_get_lines(buf,0,-1,false)
      assert(undone[1]=='dirty needle needle!' and undone[2]=='second',vim.inspect(undone))
      local captured=assert(require('workbench.services.buffers').capture({scope={kind='file',path=path}})).snapshots[1]
      local token=vim.fn.sha256(captured.id); local snapshot={id=token,bufnr=buf,path=path,uri=captured.uri,changedtick=captured.changedtick,fileformat=captured.fileformat,endofline=captured.endofline,bomb=captured.bomb,fileencoding=captured.fileencoding,encoding='utf-8',content_hash=vim.fn.sha256(captured.content)}
      local resource=assert(require('workbench.core.resource').from_path(path,{workspace_id='ws'})); local location=assert(require('workbench.core.location').new(resource,{range={start={line=0,character=6},finish={line=0,character=12}},encoding='utf-8'}))
      local item={id='stale',kind='match',location=location,payload={provider_id='rg',byte_start=6,byte_end=12,match_bytes='needle',source_snapshot={id=token}}}
      local plan=assert(_G.wb22_service:prepare({id='ws',generation=2,roots={{path=vim.fs.dirname(path)}}},{{item=item,source_snapshot=snapshot}},'fresh',{literal=true})); assert(_G.wb22_service:review(plan)); _G.wb22_stale_plan=plan
      return undone
    ]], setup.path)
    local stale = evaluate([[
      local path=...; local buf=_G.wb22_buf; vim.api.nvim_buf_set_lines(buf,0,1,false,{'user changed needle'})
      local okay,err=_G.wb22_service:apply(_G.wb22_stale_plan)
      local result={stale_ok=okay==true,stale_code=err.code,user_line=vim.api.nvim_buf_get_lines(buf,0,1,false)[1],disk=table.concat(vim.fn.readfile(path),'\n'),ledger=_G.wb22_stale_plan.recovery}
      _G.wb22_service:dispose(); vim.bo[buf].modified=false; vim.fn.delete(_G.wb22_root,'rf')
      return result
    ]], setup.path)
    local result = { after = applied, undone = undo, stale_ok = stale.stale_ok, stale_code = stale.stale_code, user_line = stale.user_line, disk = stale.disk, ledger = stale.ledger }
    expect.equality(result.after, { "dirty done done!", "second" })
    expect.equality(result.undone, { "dirty needle needle!", "second" })
    expect.equality(result.stale_ok, false)
    expect.equality(result.stale_code, "stale_preimage")
    expect.equality(result.user_line, "user changed needle")
    expect.equality(result.disk, "disk needle needle")
    expect.equality(result.ledger.applied, {})
    expect.equality(#result.ledger.unapplied, 1)
  end,

  ["partial multi-file failure identifies exact applied and unapplied resources"] = function()
    local result = evaluate([[
      local uv=vim.uv; local root=vim.fn.tempname()..'-wb22-partial'; local state=root..'-state'; assert(vim.fn.mkdir(root,'p')==1); root=assert(uv.fs_realpath(root))
      local a=root..'/a.txt'; local b=root..'/b.txt'; assert(vim.fn.writefile({'needle A'},a)==0); assert(vim.fn.writefile({'needle B'},b)==0)
      local fail=true; local injected=setmetatable({fs_rename=function(source,target) if target==b and source:find('.workbench-replace',1,true) and fail then fail=false; return nil,'EIO injected second-file failure' end; return uv.fs_rename(source,target) end},{__index=uv})
      local Resource=require('workbench.core.resource'); local Location=require('workbench.core.location')
      local function item(path,id,suffix)
        local resource=assert(Resource.from_path(path,{workspace_id='ws'})); local location=assert(Location.new(resource,{range={start={line=0,character=0},finish={line=0,character=6}},encoding='utf-8'}))
        return {id=id,kind='match',location=location,payload={provider_id='rg',byte_start=0,byte_end=6,match_bytes='needle'}}
      end
      local service=assert(require('workbench.services.replacement').new({uv=injected,state_dir=state}))
      local plan=assert(service:prepare({id='ws',generation=3,roots={{path=root}}},{{item=item(a,'a')},{item=item(b,'b')}},'done',{literal=true})); assert(service:review(plan))
      local applied,apply_error=service:apply(plan)
      local result_a=table.concat(vim.fn.readfile(a),'\n'); local result_b=table.concat(vim.fn.readfile(b),'\n')
      local ledger=vim.deepcopy(plan.recovery)
      local records=assert(service:recoveries()); local journal=assert(records[1])
      service:dispose(); vim.fn.delete(root,'rf'); vim.fn.delete(state,'rf')
      return {applied=applied==true,code=apply_error.code,state=plan.state,a=result_a,b=result_b,recovery=ledger,journal_state=journal.state,journal_resources=journal.resources}
    ]])
    expect.equality(result.applied, false)
    expect.equality(result.code, "atomic_replace_failed")
    expect.equality(result.state, "partial")
    expect.equality(result.a, "done A")
    expect.equality(result.b, "needle B")
    expect.equality(result.recovery.applied, { result.journal_resources[1].path })
    expect.equality(result.recovery.unapplied, { result.journal_resources[2].path })
    expect.equality(result.journal_state, "partial")
    expect.equality(result.journal_resources[1].state, "applied")
    expect.equality(result.journal_resources[2].state, "unapplied")
  end,

  ["unloaded read-only files refuse replacement before a plan can be reviewed"] = function()
    local result = evaluate([[
      local uv=vim.uv; local root=vim.fn.tempname()..'-wb22-permission'; assert(vim.fn.mkdir(root,'p')==1); root=assert(uv.fs_realpath(root))
      local path=root..'/readonly.txt'; assert(vim.fn.writefile({'needle'},path)==0); assert(uv.fs_chmod(path,292))
      local resource=assert(require('workbench.core.resource').from_path(path,{workspace_id='ws'})); local location=assert(require('workbench.core.location').new(resource,{range={start={line=0,character=0},finish={line=0,character=6}},encoding='utf-8'}))
      local item={id='readonly',kind='match',location=location,payload={provider_id='rg',byte_start=0,byte_end=6,match_bytes='needle'}}
      local service=assert(require('workbench.services.replacement').new({journal=false}))
      local plan,err=service:prepare({id='ws',generation=1,roots={{path=root}}},{{item=item}},'done',{literal=true})
      local mode=uv.fs_stat(path).mode%512; service:dispose(); vim.fn.delete(root,'rf')
      return {plan=plan==nil,code=err.code,mode=mode}
    ]])
    expect.equality(result.plan, true)
    expect.equality(result.code, "permission_denied")
    expect.equality(result.mode, 292)
  end,

  ["cancelled and disposed plans release captured replacements without mutation"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb22-cancel'; assert(vim.fn.mkdir(root,'p')==1); root=assert(vim.uv.fs_realpath(root))
      local path=root..'/target.txt'; assert(vim.fn.writefile({'needle'},path)==0)
      local resource=assert(require('workbench.core.resource').from_path(path,{workspace_id='ws'})); local location=assert(require('workbench.core.location').new(resource,{range={start={line=0,character=0},finish={line=0,character=6}},encoding='utf-8'}))
      local item={id='cancel',kind='match',location=location,payload={provider_id='rg',byte_start=0,byte_end=6,match_bytes='needle'}}
      local service=assert(require('workbench.services.replacement').new({journal=false}))
      local plan=assert(service:prepare({id='ws',generation=1,roots={{path=root}}},{{item=item}},'done',{literal=true}))
      local cancelled=service:cancel(plan); local repeated=service:cancel(plan); local active=service:status().active
      local contents=table.concat(vim.fn.readfile(path),'\n')
      local disposed=service:dispose(); local repeated_dispose=service:dispose(); local status=service:status()
      vim.fn.delete(root,'rf')
      return {cancelled=cancelled,repeated=repeated,active=active,state=plan.state,contents=contents,disposed=disposed,repeated_dispose=repeated_dispose,service_disposed=status.disposed}
    ]])
    expect.equality(result.cancelled, true)
    expect.equality(result.repeated, false)
    expect.equality(result.active, 0)
    expect.equality(result.state, "cancelled")
    expect.equality(result.contents, "needle")
    expect.equality(result.disposed, true)
    expect.equality(result.repeated_dispose, false)
    expect.equality(result.service_disposed, true)
  end,
})
