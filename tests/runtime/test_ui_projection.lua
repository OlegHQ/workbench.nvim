local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("local root = ...; vim.opt.runtimepath:prepend(root)", { root })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["failed mounts preserve sibling views and release only provisional resources"] = function()
    local result=evaluate([[
      local layout=assert(require('workbench.ui.layout').new())
      local editor=vim.api.nvim_get_current_win()
      local first=assert(layout:mount({id='first',placement='sidebar',focus=false,model={items={{id='a',label='alpha'}}}}))
      local second=assert(layout:mount({id='second',placement='results',focus=false,model={items={{id='b',label='beta'}}}}))
      local state=layout.tabs[vim.api.nvim_get_current_tabpage()]
      local function unchanged()
        assert(not first.closed and not second.closed and state.scope.alive)
        assert(vim.api.nvim_win_is_valid(first.window) and vim.api.nvim_win_is_valid(second.window))
        assert(vim.api.nvim_buf_is_valid(first.buffer) and vim.api.nvim_buf_is_valid(second.buffer))
        assert(layout:status().active_views==2 and vim.api.nvim_get_current_win()==editor)
      end
      local original=layout._install_hooks
      layout._install_hooks=function() return nil,{code='injected_hooks',message='hook failure'} end
      local view,err=layout:mount({id='third'})
      layout._install_hooks=original
      assert(not view and err.code=='injected_hooks'); unchanged()
      original=state.scope.child
      state.scope.child=function() return nil,{code='injected_scope',message='scope failure'} end
      view,err=layout:mount({id='third'})
      state.scope.child=original
      assert(not view and err.code=='injected_scope'); unchanged()
      original=layout._place
      layout._place=function() return nil,{code='injected_place',message='window failure'} end
      view,err=layout:mount({id='third'})
      layout._place=original
      assert(not view and err.code=='injected_place'); unchanged()
      layout._place=function() return nil,{code='injected_replace',message='replacement window failure'} end
      view,err=layout:mount({id='first',replace=true})
      layout._place=original
      assert(not view and err.code=='injected_replace'); unchanged()
      assert(layout:get('first')==first)
      local replacement=assert(layout:mount({id='first',replace=true,focus=false,model={items={{id='c',label='replacement'}}}}))
      assert(first.closed and not second.closed and layout:get('first')==replacement)
      assert(not vim.api.nvim_buf_is_valid(first.buffer) and layout:status().active_views==2)
      local third=assert(layout:mount({id='third',focus=false}))
      assert(third and layout:status().active_views==3)
      layout:dispose()
      assert(vim.api.nvim_win_is_valid(editor) and layout:status().active_views==0)
      return true
    ]])
    expect.equality(result,true)
  end,

  ["tree projection retains IDs, sibling order and explicit expansion"] = function()
    local result = evaluate([[
      local projection = require('workbench.ui.projection')
      local items = {
        { id = 'root', label = 'workspace', kind = 'directory' },
        { id = 'a', label = 'alpha', kind = 'directory', parent_id = 'root' },
        { id = 'a-file', label = 'alpha.txt', parent_id = 'a' },
        { id = 'b', label = 'beta', kind = 'directory', parent_id = 'root' },
        { id = 'b-file', label = 'beta.txt', parent_id = 'b' },
      }
      local expanded, info = projection.tree(items, { root = true, a = true, b = false })
      local collapsed = projection.tree(items, { root = false })
      return {
        ids = vim.tbl_map(function(row) return row.id end, expanded),
        first_child = expanded[2],
        collapsed_ids = vim.tbl_map(function(row) return row.id end, collapsed),
        truncated = info.truncated,
      }
    ]])
    expect.equality(result.ids, { "root", "a", "a-file", "b" })
    expect.equality(result.first_child.parent_id, "root")
    expect.equality(result.first_child.depth, 1)
    expect.equality(result.first_child.has_children, true)
    expect.equality(result.collapsed_ids, { "root" })
    expect.equality(result.truncated, false)
  end,

  ["selection follows stable IDs and falls back to next sibling then parent"] = function()
    local result = evaluate([[
      local projection = require('workbench.ui.projection')
      local before = projection.tree({
        { id = 'root', label = 'root' },
        { id = 'a', label = 'a', parent_id = 'root' },
        { id = 'b', label = 'b', parent_id = 'root' },
        { id = 'c', label = 'c', parent_id = 'root' },
      }, { root = true })
      local stable = projection.reconcile_selection(before, 'b', before)
      local after = projection.tree({
        { id = 'root', label = 'root' },
        { id = 'a', label = 'a', parent_id = 'root' },
        { id = 'c', label = 'c', parent_id = 'root' },
      }, { root = true })
      local next_sibling = projection.reconcile_selection(after, 'b', before)
      local only_parent = projection.tree({ { id = 'root', label = 'root' } }, { root = true })
      local parent = projection.reconcile_selection(only_parent, 'b', before)
      return { stable = stable, next_sibling = next_sibling, parent = parent }
    ]])
    expect.equality(result.stable, "b")
    expect.equality(result.next_sibling, "c")
    expect.equality(result.parent, "root")
  end,

  ["list projection preserves order and reports bounded output"] = function()
    local result = evaluate([[
      local projection = require('workbench.ui.projection')
      local rows, info = projection.list({
        { id = 'third', label = 'third' },
        { id = 'first', label = 'first' },
        { id = 'second', label = 'second' },
      }, 2)
      return { ids = vim.tbl_map(function(row) return row.id end, rows), info = info }
    ]])
    expect.equality(result.ids, { "third", "first" })
    expect.equality(result.info.truncated, true)
    expect.equality(result.info.total, 3)
  end,

  ["duplicate IDs and parent cycles are rejected"] = function()
    local result = evaluate([[
      local projection = require('workbench.ui.projection')
      local duplicate, duplicate_error = projection.list({ { id = 'x', label = 'one' }, { id = 'x', label = 'two' } })
      local cycle, cycle_error = projection.tree({
        { id = 'a', label = 'a', parent_id = 'b' },
        { id = 'b', label = 'b', parent_id = 'a' },
      }, {})
      return { duplicate = duplicate, duplicate_error = duplicate_error, cycle = cycle, cycle_error = cycle_error }
    ]])
    expect.equality(result.duplicate, nil)
    expect.equality(result.duplicate_error, "duplicate projection id: x")
    expect.equality(result.cycle, nil)
    expect.equality(result.cycle_error, "projection contains a parent cycle at a")
  end,

  ["sparse and keyed item collections are rejected"] = function()
    local result = evaluate([[
      local projection = require('workbench.ui.projection')
      local keyed, keyed_error = projection.list({ item = { id = 'x', label = 'x' } })
      local sparse, sparse_error = projection.list({ [1] = { id = 'x', label = 'x' }, [3] = { id = 'z', label = 'z' } })
      return { keyed = keyed, keyed_error = keyed_error, sparse = sparse, sparse_error = sparse_error }
    ]])
    expect.equality(result.keyed, nil)
    expect.equality(result.keyed_error, "projection items must be a dense array")
    expect.equality(result.sparse, nil)
    expect.equality(result.sparse_error, "projection items must be a dense array")
  end,
})
