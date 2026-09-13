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
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], { root, root .. "/tests" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["independent branches filter restoration open and session retention remain stable"] = function()
    local result = evaluate([[
      vim.o.columns, vim.o.lines = 120, 35
      local fs = vim.uv or vim.loop
      local root = vim.fn.tempname() .. '-wb-files-controller'
      assert(vim.fn.mkdir(root .. '/A', 'p') == 1)
      assert(vim.fn.mkdir(root .. '/B', 'p') == 1)
      assert(vim.fn.writefile({'needle'}, root .. '/A/needle.lua') == 0)
      assert(vim.fn.writefile({'other'}, root .. '/B/readme.md') == 0)
      assert(vim.fn.writefile({'hidden'}, root .. '/.hidden') == 0)
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local layout = require('workbench.ui.layout').new()
      local provider = assert(require('workbench.providers.filesystem').new())
      local opened
      local controller = assert(require('workbench.controllers.files').new({
        layout = layout,
        provider = provider,
        on_open = function(resource) opened = resource; return true end,
      }))
      local view = assert(controller:open(snapshot, { focus = false }))
      local function session() return controller.sessions[next(controller.sessions)] end
      local function wait_loaded(id)
        assert(vim.wait(5000, function() return session().loaded[id] == true end, 5))
      end
      wait_loaded(session().root_id)
      local by_name = {}
      for id, item in pairs(session().nodes) do if item.payload then by_name[item.payload.raw_name] = id end end
      local a, b = by_name.A, by_name.B
      assert(a and b)
      view:toggle_expanded(a)
      view:toggle_expanded(b)
      wait_loaded(a)
      wait_loaded(b)
      local needle
      for id, item in pairs(session().nodes) do if item.payload and item.payload.raw_name == 'needle.lua' then needle = id end end
      assert(needle)
      view.selected_id = needle
      assert(view:activate())
      local selection_before = view.selected_id
      local branch_states = { a = view.expanded[a], b = view.expanded[b] }
      assert(controller:set_filter('needle.lua'))
      local filtered_ids = {}
      for _, row in ipairs(view.rows) do filtered_ids[row.id] = true end
      local filtered_selection = filtered_ids[needle] == true
      assert(controller:set_filter(''))
      local restored = view.expanded[a] == branch_states.a and view.expanded[b] == branch_states.b
      view:close()
      local closed = controller:status()
      local reopened = assert(controller:open(snapshot, { focus = false }))
      local session_retained = reopened.selected_id == selection_before and reopened.expanded[a] == branch_states.a
      local changed = vim.deepcopy(snapshot)
      changed.generation = changed.generation + 1
      changed.policy.hidden = 'include'
      assert(controller:set_workspace(changed))
      assert(vim.wait(5000, function()
        local s = session()
        if not s.loaded[s.root_id] then return false end
        for _, item in pairs(s.nodes) do if item.payload and item.payload.raw_name == '.hidden' then return true end end
      end, 5))
      local hidden_enabled = false
      for _, item in pairs(session().nodes) do
        if item.payload and item.payload.raw_name == '.hidden' then hidden_enabled = true end
      end
      local cwd_unchanged = vim.fn.getcwd() ~= root
      controller:dispose()
      provider:dispose()
      layout:dispose()
      vim.fn.delete(root, 'rf')
      return {
        opened = opened and opened.path,
        filter_selected_match = filtered_selection,
        filter_restored_branches = restored,
        closed_session_retained = closed.sessions[1].mounted == false,
        reopened_state_retained = session_retained,
        hidden_policy_reloaded = hidden_enabled,
        cwd_unchanged = cwd_unchanged,
      }
    ]])
    expect.equality(result.filter_selected_match, true)
    expect.equality(result.filter_restored_branches, true)
    expect.equality(result.closed_session_retained, true)
    expect.equality(result.reopened_state_retained, true)
    expect.equality(result.hidden_policy_reloaded, true)
    expect.equality(result.cwd_unchanged, true)
  end,

  ["root change clears stale nodes and stale requests while preserving the mounted view"] = function()
    local result = evaluate([[
      vim.o.columns, vim.o.lines = 120, 35
      local root_a = vim.fn.tempname() .. '-wb-root-a'
      local root_b = vim.fn.tempname() .. '-wb-root-b'
      assert(vim.fn.mkdir(root_a, 'p') == 1)
      assert(vim.fn.mkdir(root_b, 'p') == 1)
      assert(vim.fn.writefile({'a'}, root_a .. '/from-a.txt') == 0)
      assert(vim.fn.writefile({'b'}, root_b .. '/from-b.txt') == 0)
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot_a = assert(workspace:open({ explicit_root = root_a }))
      local snapshot_b = assert(workspace:open({ explicit_root = root_b }))
      local layout = require('workbench.ui.layout').new()
      local provider = assert(require('workbench.providers.filesystem').new())
      local controller = assert(require('workbench.controllers.files').new({ layout = layout, provider = provider }))
      local view = assert(controller:open(snapshot_a, { focus = false }))
      local session = controller.sessions[next(controller.sessions)]
      assert(vim.wait(5000, function() return session.loaded[session.root_id] end, 5))
      local old_id = session.root_id
      assert(controller:set_workspace(snapshot_b))
      assert(session.root_id ~= old_id)
      assert(vim.wait(5000, function()
        if not session.loaded[session.root_id] then return false end
        for _, item in pairs(session.nodes) do
          if item.payload and item.payload.raw_name == 'from-b.txt' then return true end
        end
      end, 5))
      local found_b, found_a = false, false
      for _, item in pairs(session.nodes) do
        if item.payload and item.payload.raw_name == 'from-b.txt' then found_b = true end
        if item.payload and item.payload.raw_name == 'from-a.txt' then found_a = true end
      end
      local mounted = controller:status().sessions[1].mounted
      local view_valid = view.closed == false
      controller:dispose()
      provider:dispose()
      layout:dispose()
      vim.fn.delete(root_a, 'rf')
      vim.fn.delete(root_b, 'rf')
      return { found_b = found_b, stale_a_removed = not found_a, mounted = mounted, view_valid = view_valid }
    ]])
    expect.equality(result.found_b, true)
    expect.equality(result.stale_a_removed, true)
    expect.equality(result.mounted, true)
    expect.equality(result.view_valid, true)
  end,

  ["a single layout manager mounts one Files view per tab and disposes a closed tab"] = function()
    local result = evaluate([[
      vim.o.columns, vim.o.lines = 120, 35
      local root = vim.fn.tempname() .. '-wb-tabs'
      assert(vim.fn.mkdir(root, 'p') == 1)
      assert(vim.fn.writefile({'tab-safe'}, root .. '/file.txt') == 0)
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local layout = require('workbench.ui.layout').new()
      local provider = assert(require('workbench.providers.filesystem').new())
      local controller = assert(require('workbench.controllers.files').new({ layout = layout, provider = provider }))
      local first = assert(controller:open(snapshot, { focus = false }))
      local first_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd('tabnew')
      local second_tab = vim.api.nvim_get_current_tabpage()
      local second, err = controller:open(snapshot, { focus = false })
      assert(second, err and err.message or 'second tab did not mount a view')
      assert(vim.wait(5000, function() return controller:status().session_count == 2 end, 5))
      local mounted = layout:status()
      local isolated = second ~= first and second.window ~= first.window
        and vim.api.nvim_win_get_tabpage(first.window) == first_tab
        and vim.api.nvim_win_get_tabpage(second.window) == second_tab
      vim.cmd('tabclose')
      local wait_error
      local closed = vim.wait(5000, function()
        local ok, done = pcall(function()
          return controller:status().session_count == 1 and layout:status().active_views == 1
        end)
        if not ok then wait_error = done; return true end
        return done
      end, 5)
      assert(not wait_error, wait_error)
      assert(closed == true, 'second-tab Files view did not dispose')
      local after_close = controller:status()
      controller:dispose()
      provider:dispose()
      layout:dispose()
      vim.fn.delete(root, 'rf')
      return {
        active_views_before_close = mounted.active_views,
        isolated_windows = isolated,
        sessions_after_close = after_close.session_count,
        active_views_after_close = layout:status().active_views,
      }
    ]])
    expect.equality(result.active_views_before_close, 2)
    expect.equality(result.isolated_windows, true)
    expect.equality(result.sessions_after_close, 1)
    expect.equality(result.active_views_after_close, 0)
  end,
})
