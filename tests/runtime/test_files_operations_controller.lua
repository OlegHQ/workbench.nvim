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
  ["Files exposes reviewed create actions and refreshes only after the confirmed mutation"] = function()
    local result = evaluate([[
      vim.o.columns, vim.o.lines = 120, 35
      local root = vim.fn.tempname() .. '-wb-files-operations'
      assert(vim.fn.mkdir(root, 'p') == 1)
      local uv = vim.uv
      root = assert(uv.fs_realpath(root))
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return assert(uv.fs_realpath(path)) end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }), 'workspace open failed')
      local layout = assert(require('workbench.ui.layout').new(), 'layout creation failed')
      local provider = assert(require('workbench.providers.filesystem').new(), 'filesystem provider creation failed')
      local review_prompt, selected_label, input_prompt
      local notifications = {}
      local controller = assert(require('workbench.controllers.files').new({
        layout = layout,
        provider = provider,
        input = function(opts, callback) input_prompt = opts.prompt; callback('created.txt') end,
        select = function(items, opts, callback)
          review_prompt = opts.prompt
          assert(not uv.fs_lstat(root .. '/created.txt'), 'review must precede filesystem mutation')
          selected_label = items[1]
          callback(items[1])
        end,
        notify = function(message) notifications[#notifications + 1] = message end,
      }), 'Files controller creation failed')
      local view = assert(controller:open(snapshot, { focus = false }), 'Files open failed')
      local session = controller.sessions[next(controller.sessions)]
      assert(vim.wait(5000, function() return session.loaded[session.root_id] == true end, 5), 'initial Files scan timed out')
      view.selected_id = session.root_id
      view.keymaps.a.run(view)
      local rendered = vim.wait(5000, function() return session.loaded[session.root_id] and session.nodes['file:' .. vim.uri_from_fname(root .. '/created.txt')] ~= nil end, 5)
      local exists = uv.fs_stat(root .. '/created.txt') ~= nil
      local result = {
        file_exists = exists,
        trash_hidden = view.keymaps.d == nil,
        input_context = input_prompt:find(root, 1, true) ~= nil,
        exact_review = review_prompt:find('Operation: create_file', 1, true) ~= nil
          and review_prompt:find('To: ' .. root .. '/created.txt', 1, true) ~= nil,
        explicit_confirmation = selected_label == 'Apply this exact operation',
        completed_notice = notifications[#notifications] == 'create file completed',
      }
      controller:dispose()
      provider:dispose()
      layout:dispose()
      vim.fn.delete(root, 'rf')
      return result
    ]])
    expect.equality(result.file_exists, true)
    expect.equality(result.trash_hidden, true)
    expect.equality(result.input_context, true)
    expect.equality(result.exact_review, true)
    expect.equality(result.explicit_confirmation, true)
    expect.equality(result.completed_notice, true)
  end,

  ["workspace changes cancel pending review and ignore a late confirmation"] = function()
    local result = evaluate([[
      local root = vim.fn.tempname() .. '-wb-files-operation-cancel'
      local first_root, second_root = root .. '/first', root .. '/second'
      assert(vim.fn.mkdir(first_root, 'p') == 1 and vim.fn.mkdir(second_root, 'p') == 1)
      local uv = vim.uv
      first_root, second_root = assert(uv.fs_realpath(first_root)), assert(uv.fs_realpath(second_root))
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return assert(uv.fs_realpath(path)) end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local first = assert(workspace:open({ explicit_root = first_root }))
      local second = assert(workspace:open({ explicit_root = second_root }))
      local layout = assert(require('workbench.ui.layout').new())
      local provider = assert(require('workbench.providers.filesystem').new())
      local confirmation
      local controller = assert(require('workbench.controllers.files').new({
        layout = layout,
        provider = provider,
        input = function(_, callback) callback('pending.txt') end,
        select = function(_, _, callback) confirmation = callback end,
        notify = function() end,
      }))
      local view = assert(controller:open(first, { focus = false }))
      local session = controller.sessions[next(controller.sessions)]
      assert(vim.wait(5000, function() return session.loaded[session.root_id] == true end, 5))
      view.selected_id = session.root_id
      view.keymaps.a.run(view)
      local plan = assert(session.pending_operation)
      local target = first_root .. '/pending.txt'
      assert(not uv.fs_lstat(target))
      assert(controller:set_workspace(second, session.tab))
      local cancelled_by_workspace_change = session.pending_operation == nil and plan.state == 'cancelled'
      confirmation('Apply this exact operation')
      local late_choice_ignored = plan.state == 'cancelled' and uv.fs_lstat(target) == nil
      local state = { cancelled = cancelled_by_workspace_change, late_choice_ignored = late_choice_ignored,
        workspace = session.workspace.roots[1].path, expected_workspace = second_root }
      controller:dispose()
      provider:dispose()
      layout:dispose()
      vim.fn.delete(root, 'rf')
      return state
    ]])
    expect.equality(result.cancelled, true)
    expect.equality(result.late_choice_ignored, true)
    expect.equality(result.workspace, result.expected_workspace)
  end,
})
