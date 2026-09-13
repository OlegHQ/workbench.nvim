local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("local repo_root = ...; vim.opt.runtimepath:prepend(repo_root)", { root })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["capture is bounded, immutable, preserves buffer text and encoding metadata, and stages safely"] = function()
    local result = child.lua([[
      local root=vim.fn.tempname()..'-wb18-buffer-snapshot'
      assert(vim.fn.mkdir(root,'p')==1)
      local path=root..'/dir with spaces/λ.txt'
      local buffer=vim.fn.bufadd(path); vim.fn.bufload(buffer)
      vim.api.nvim_buf_set_lines(buffer,0,-1,false,{'first','café needle'})
      vim.bo[buffer].fileformat='dos'; vim.bo[buffer].endofline=false; vim.bo[buffer].bomb=true
      vim.bo[buffer].fileencoding='latin1'; vim.bo[buffer].modified=true
      local service=require('workbench.services.buffers')
      local result=assert(service.capture({workspace_root=root,scope={kind='all_roots'},modified_only=true}))
      local snapshot=assert(result.snapshots[1])
      local staged=assert(service.stage(result.snapshots,{workspace_root=root,mirror_ignore=true}))
      local record=assert(staged.files[1])
      local file=assert(io.open(record.staged_path,'rb')); local staged_bytes=file:read('*a'); file:close()
      local before_current=service.is_current(snapshot)
      vim.api.nvim_buf_set_lines(buffer,0,1,false,{'changed'})
      local after_current=service.is_current(snapshot)
      local values={
        total=result.candidate_count,count=#result.snapshots,skipped=result.skipped_count,
        content=snapshot.content,staged=staged_bytes,fileformat=snapshot.fileformat,eol=snapshot.endofline,
        bomb=snapshot.bomb,fileencoding=snapshot.fileencoding,encoding=snapshot.encoding,
        bytes=snapshot.byte_size,before=before_current,after=after_current,
        list_total=service.list().total,
      }
      staged:dispose(); local disposed=staged:dispose(); vim.bo[buffer].modified=false
      vim.fn.delete(root,'rf'); values.disposed=not disposed
      return values
    ]])
    expect.equality(result.total, 1)
    expect.equality(result.count, 1)
    expect.equality(result.skipped, 0)
    expect.equality(result.content, "first\r\ncafé needle")
    expect.equality(result.staged, result.content)
    expect.equality(result.fileformat, "dos")
    expect.equality(result.eol, false)
    expect.equality(result.bomb, true)
    expect.equality(result.fileencoding, "latin1")
    expect.equality(result.encoding, "utf-8")
    expect.equality(result.bytes, #result.content)
    expect.equality(result.before, true)
    expect.equality(result.after, false)
    expect.equality(result.disposed, true)
  end,

  ["working set excludes unnamed and special buffers and orders current/recent named files"] = function()
    local result = child.lua([[
      local root=vim.fn.tempname()..'-wb18-buffer-list'; assert(vim.fn.mkdir(root,'p')==1)
      local first=vim.fn.bufadd(root..'/first.txt'); vim.fn.bufload(first)
      local second=vim.fn.bufadd(root..'/second.txt'); vim.fn.bufload(second)
      vim.api.nvim_set_current_buf(first); vim.api.nvim_set_current_buf(second)
      local unnamed=vim.api.nvim_create_buf(false,false)
      local special=vim.api.nvim_create_buf(false,true); vim.bo[special].buftype='nofile'
      local result=require('workbench.services.buffers').list()
      local ids={}; for index,item in ipairs(result.items) do ids[index]=item.bufnr end
      local output={total=result.total,items=#result.items,current_first=ids[1]==second,recent_second=ids[2]==first,unnamed=result.excluded.unnamed,special=result.excluded.special}
      vim.api.nvim_buf_delete(first,{force=true}); vim.api.nvim_buf_delete(second,{force=true})
      vim.api.nvim_buf_delete(unnamed,{force=true}); vim.api.nvim_buf_delete(special,{force=true}); vim.fn.delete(root,'rf')
      return output
    ]])
    expect.equality(result.total, 2)
    expect.equality(result.items, 2)
    expect.equality(result.current_first, true)
    expect.equality(result.recent_second, true)
    expect.equality(result.unnamed >= 1, true)
    expect.equality(result.special >= 1, true)
  end,
})
