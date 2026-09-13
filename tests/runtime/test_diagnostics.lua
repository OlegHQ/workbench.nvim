local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local helpers = [[
  local function make_workspace(paths)
    local Resource = require('workbench.core.resource')
    local Workspace = require('workbench.core.workspace')
    local roots = {}
    for _, path in ipairs(paths) do roots[#roots + 1] = assert(Resource.from_path(path)) end
    return assert(Workspace.new({
      id = Workspace.id_for_roots(roots), generation = 1, roots = roots,
      active_root_uri = roots[1].uri, root_origin = 'explicit',
      scope = { kind = 'all_roots', explicit = true },
      policy = { hidden = 'exclude', ignored = 'exclude', symlinks = 'never', include = {}, exclude = {} },
    }))
  end
  local function setup()
    vim.o.columns, vim.o.lines, vim.o.hidden = 120, 40, true
    local root_a = vim.fn.tempname() .. '-wb16-a'
    local root_b = vim.fn.tempname() .. '-wb16-b'
    local outside = vim.fn.tempname() .. '-wb16-outside'
    assert(vim.fn.mkdir(root_a .. '/sub', 'p') == 1)
    assert(vim.fn.mkdir(root_b, 'p') == 1)
    assert(vim.fn.mkdir(outside, 'p') == 1)
    root_a = assert(vim.uv.fs_realpath(root_a))
    root_b = assert(vim.uv.fs_realpath(root_b))
    outside = assert(vim.uv.fs_realpath(outside))
    local a = root_a .. '/main.lua'
    local a_sub = root_a .. '/sub/other.lua'
    local b = root_b .. '/second.lua'
    local outside_file = outside .. '/outside.lua'
    assert(vim.fn.writefile({ 'local a = 1', 'print(a)' }, a) == 0)
    assert(vim.fn.writefile({ 'local other = 2' }, a_sub) == 0)
    assert(vim.fn.writefile({ 'local b = 3', 'print(b)' }, b) == 0)
    assert(vim.fn.writefile({ 'local out = 4' }, outside_file) == 0)
    local function buffer(path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      return bufnr
    end
    local a_buf, a_sub_buf, b_buf, outside_buf = buffer(a), buffer(a_sub), buffer(b), buffer(outside_file)
    vim.api.nvim_win_set_buf(0, a_buf)
    local one_root = make_workspace({ root_a })
    local two_roots = make_workspace({ root_a, root_b })
    local Resource = require('workbench.core.resource')
    return {
      root_a = root_a, root_b = root_b, outside = outside, a = a, a_sub = a_sub, b = b, outside_file = outside_file,
      a_buf = a_buf, a_sub_buf = a_sub_buf, b_buf = b_buf, outside_buf = outside_buf,
      workspace = one_root, two_roots = two_roots, Resource = Resource,
    }
  end
  local function diagnostic(line, col, severity, source, message, code)
    return { lnum = line, col = col, end_lnum = line, end_col = col + 1,
      severity = severity, source = source, message = message, code = code }
  end
  local function cleanup(state)
    vim.diagnostic.reset(nil, state.a_buf)
    vim.diagnostic.reset(nil, state.a_sub_buf)
    vim.diagnostic.reset(nil, state.b_buf)
    vim.diagnostic.reset(nil, state.outside_buf)
    vim.fn.delete(state.root_a, 'rf')
    vim.fn.delete(state.root_b, 'rf')
    vim.fn.delete(state.outside, 'rf')
  end
]]

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], { root, root .. "/tests" })
    end,
    post_case = function() if child then pcall(child.stop); child = nil end end,
  },
}, {
  ["native snapshots preserve namespace provenance and exclude unnamed and unrelated-root buffers"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local first_ns = vim.api.nvim_create_namespace('wb16-first-linter')
      local second_ns = vim.api.nvim_create_namespace('wb16-second-linter')
      local outside_ns = vim.api.nvim_create_namespace('wb16-outside-linter')
      local unnamed_ns = vim.api.nvim_create_namespace('wb16-unnamed-linter')
      vim.diagnostic.set(first_ns, state.a_buf, { diagnostic(0, 0, 1, 'compiler', 'bad token', 'E001') })
      vim.diagnostic.set(second_ns, state.a_buf, { diagnostic(1, 2, 2, 'lint', 'unused value', 'W001') })
      vim.diagnostic.set(first_ns, state.a_sub_buf, { diagnostic(0, 1, 3, 'compiler', 'style hint', 'I001') })
      vim.diagnostic.set(outside_ns, state.outside_buf, { diagnostic(0, 0, 1, 'outside', 'external', 'O001') })
      local unnamed = vim.api.nvim_create_buf(false, true)
      vim.diagnostic.set(unnamed_ns, unnamed, { diagnostic(0, 0, 1, 'unnamed', 'no URI', 'U001') })
      local empty_path = state.root_a .. '/empty.lua'
      assert(vim.fn.writefile({}, empty_path) == 0)
      local empty_buf = vim.fn.bufadd(empty_path)
      vim.fn.bufload(empty_buf)
      local provider = assert(require('workbench.providers.diagnostics').new())
      local events = {}
      local lease = assert(provider:subscribe(state.workspace, function(event) events[#events + 1] = event end))
      local snapshot = assert(lease:snapshot())
      local by_path = {}
      for _, report in ipairs(snapshot.reports) do by_path[report.resource.path] = report end
      local main = assert(by_path[state.a], 'provider snapshot omitted diagnostics inside its workspace root')
      local output = {
        coverage = snapshot.coverage,
        completeness = snapshot.completeness,
        files = vim.tbl_count(by_path),
        namespaces = #main.namespaces,
        error = main.counts.error,
        warning = main.counts.warning,
        sub_info = by_path[state.a_sub] and by_path[state.a_sub].counts.information,
        outside_excluded = by_path[state.outside_file] == nil,
        unnamed_excluded = #snapshot.reports == 2,
        provenance = {},
        hooks = provider:status().hook_count,
      }
      vim.diagnostic.set(first_ns, empty_buf, {})
      output.empty_resource_event_count = #events
      for _, namespace in ipairs(main.namespaces) do output.provenance[namespace.id] = namespace.name end
      lease:release()
      output.inactive_hooks = provider:status().hook_count
      output.editor_diagnostics_preserved = #vim.diagnostic.get(state.a_buf) == 2
      provider:dispose()
      vim.diagnostic.reset(nil, empty_buf)
      vim.fn.delete(empty_path)
      cleanup(state)
      return output
    ]])
    expect.equality(result.coverage, "reported-only")
    expect.equality(result.completeness, "unknown")
    expect.equality(result.files, 2)
    expect.equality(result.namespaces, 2)
    expect.equality(result.error, 1)
    expect.equality(result.warning, 1)
    expect.equality(result.sub_info, 1)
    expect.equality(result.outside_excluded, true)
    expect.equality(result.unnamed_excluded, true)
    expect.equality(result.empty_resource_event_count, 0)
    expect.equality(result.hooks, 2)
    expect.equality(result.inactive_hooks, 0)
    expect.equality(result.editor_diagnostics_preserved, true)
  end,

  ["DiagnosticChanged replaces only the changed native buffer snapshot and deletion clears its report"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local first_ns = vim.api.nvim_create_namespace('wb16-live-first')
      local second_ns = vim.api.nvim_create_namespace('wb16-live-second')
      vim.diagnostic.set(first_ns, state.a_buf, { diagnostic(0, 0, 1, 'compiler', 'error', 'E1') })
      vim.diagnostic.set(second_ns, state.a_buf, { diagnostic(1, 0, 2, 'lint', 'warning', 'W1') })
      local provider = assert(require('workbench.providers.diagnostics').new())
      local events = {}
      local lease = assert(provider:subscribe(state.workspace, function(event) events[#events + 1] = event end))
      local initial = assert(lease:snapshot()).reports[1]
      vim.diagnostic.reset(first_ns, state.a_buf)
      assert(vim.wait(1000, function()
        local event = events[#events]
        return event and event.report and event.report.counts.warning == 1
      end, 5))
      local after_one_namespace = events[#events].report
      vim.diagnostic.reset(second_ns, state.a_buf)
      assert(vim.wait(1000, function() return events[#events] and events[#events].report == nil end, 5))
      local output = {
        initial_namespaces = #initial.namespaces,
        after_first_error = after_one_namespace.counts.error,
        after_first_warning = after_one_namespace.counts.warning,
        after_first_namespaces = #after_one_namespace.namespaces,
        after_delete = events[#events].report == nil,
        event_resource_correct = events[#events].resource.path == state.a,
      }
      lease:release()
      provider:dispose()
      cleanup(state)
      return output
    ]])
    expect.equality(result.initial_namespaces, 2)
    expect.equality(result.after_first_error, 0)
    expect.equality(result.after_first_warning, 1)
    expect.equality(result.after_first_namespaces, 1)
    expect.equality(result.after_delete, true)
    expect.equality(result.event_resource_correct, true)
  end,

  ["detaching a native LSP client removes only its diagnostics and keeps the shared listener live"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local server = ...
      local path = state.root_a .. '/diagnostic.lua'
      assert(vim.fn.writefile({ 'local value = 1' }, path) == 0)
      local buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
      local python = vim.fn.exepath('python3')
      assert(python ~= '', 'python3 is required by the development test environment')
      local client_id = assert(vim.lsp.start({ name = 'wb16-detach', cmd = { python, server }, root_dir = state.root_a,
        capabilities = vim.lsp.protocol.make_client_capabilities() }, { bufnr = buffer }))
      assert(vim.wait(5000, function()
        local client = vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[buffer]
          and #vim.diagnostic.get(buffer) > 0
      end, 10), 'fake LSP diagnostic did not arrive')
      local provider = assert(require('workbench.providers.diagnostics').new())
      local events = {}
      local lease = assert(provider:subscribe(state.workspace, function(event) events[#events + 1] = event end))
      local snapshot = assert(lease:snapshot())
      local reported = false
      for _, report in ipairs(snapshot.reports) do
        if report.resource.path == path and report.namespaces[1].diagnostics[1].source == 'fake-client' then reported = true end
      end
      vim.lsp.stop_client(client_id, true)
      assert(vim.wait(5000, function()
        return vim.lsp.get_client_by_id(client_id) == nil and #vim.diagnostic.get(buffer) == 0
      end, 10), 'native detach did not clear the fake client diagnostics')
      assert(vim.wait(1000, function() return events[#events] and events[#events].report == nil end, 5))
      local output = { reported = reported, client_detached = vim.lsp.get_client_by_id(client_id) == nil,
        cleared = #vim.diagnostic.get(buffer) == 0, lease_active = lease.active, hooks = provider:status().hook_count }
      lease:release()
      provider:dispose()
      vim.fn.delete(path)
      cleanup(state)
      return output
    ]], root .. "/tests/fixtures/lsp_server.py")
    expect.equality(result.reported, true)
    expect.equality(result.client_detached, true)
    expect.equality(result.cleared, true)
    expect.equality(result.lease_active, true)
    expect.equality(result.hooks, 2)
  end,

  ["Problems filters by severity source and root and navigates reported locations through shared history"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local compiler = vim.api.nvim_create_namespace('wb16-compiler')
      local linter = vim.api.nvim_create_namespace('wb16-linter')
      vim.diagnostic.set(compiler, state.a_buf, { diagnostic(0, 0, 1, 'compiler', 'bad token', 'E1') })
      vim.diagnostic.set(linter, state.b_buf, {
        diagnostic(1, 1, 2, 'lint', 'unused value', 'W1'),
        diagnostic(0, 0, 2, 'lint', 'style issue', 'W2'),
      })
      vim.diagnostic.set(compiler, state.outside_buf, { diagnostic(0, 0, 1, 'compiler', 'outside root', 'E2') })
      local layout = assert(require('workbench.ui.layout').new({ min_editor_width = 24, min_editor_height = 6 }))
      local provider = assert(require('workbench.providers.diagnostics').new())
      local navigation = assert(require('workbench.services.navigation').new())
      local actions = require('workbench.core.actions').new()
      local controller = assert(require('workbench.controllers.problems').new({ layout = layout, provider = provider,
        navigation = navigation, actions = actions }))
      local view, session = assert(controller:open(state.two_roots, { focus = false }))
      local function diagnostic_items()
        local items = {}
        for _, item in ipairs(view.model.items) do if item.kind == 'diagnostic' then items[#items + 1] = item end end
        return items
      end
      local initial_count = #diagnostic_items()
      assert(controller:set_filter(session, 'severity', 'warning'))
      local severity_count = #diagnostic_items()
      local root_a_uri = state.two_roots.roots[1].uri
      local root_b_uri = state.two_roots.roots[2].uri
      assert(controller:set_filter(session, 'root', root_a_uri), 'root A filter failed')
      local no_root_match = #diagnostic_items() == 0
      local explicit_incomplete = false
      for _, item in ipairs(view.model.items) do
        if item.label:find('No reported diagnostics match', 1, true) then explicit_incomplete = true end
      end
      assert(controller:set_filter(session, 'root', root_b_uri), 'root B filter failed')
      assert(controller:set_filter(session, 'source', 'lint'), 'source filter failed')
      local source_count = #diagnostic_items()
      assert(controller:set_filter(session, 'clear'), 'clearing filters failed')
      local target
      local target_paths = {}
      for _, item in ipairs(diagnostic_items()) do
        target_paths[#target_paths + 1] = item.location and item.location.resource.path or "<no path>"
        if item.location.resource.path == state.b and item.payload.code == 'W1' then target = item; break end
      end
      assert(target, "missing diagnostic for " .. state.b .. "; found: " .. table.concat(target_paths, ", "))
      local file_id = target and target.parent_id
      local root_id
      for _, item in ipairs(view.model.items) do if item.id == file_id then root_id = item.parent_id; break end end
      if file_id then view.expanded[file_id] = true end
      if root_id then view.expanded[root_id] = true end
      controller:_render(session)
      local opened = assert(controller:open_selected(session, target.id), vim.inspect({
        root_id = root_id, file_id = file_id, expanded = view.expanded, rows = session.view.rows,
      }))
      local location = { path = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()), line = vim.api.nvim_win_get_cursor(0)[1], col = vim.api.nvim_win_get_cursor(0)[2] }
      assert(controller:return_to_origin(session))
      local returned = vim.api.nvim_win_get_buf(session.origin.win) == state.a_buf
      local actions_available = false
      for _, action in ipairs(actions:list({ workspace = state.two_roots })) do if action.id == 'problems.open' then actions_available = action.available.enabled end end
      local output = { initial = initial_count, severity = severity_count, root_empty = no_root_match,
        incomplete_notice = explicit_incomplete, source = source_count, navigated = opened ~= nil,
        target_correct = location.path == state.b, target_line = location.line, target_col = location.col,
        returned = returned, action = actions_available }
      view:close()
      controller:dispose(); provider:dispose(); navigation:dispose(); layout:dispose()
      cleanup(state)
      return output
    ]])
    expect.equality(result.initial, 3)
    expect.equality(result.severity, 2)
    expect.equality(result.root_empty, true)
    expect.equality(result.incomplete_notice, true)
    expect.equality(result.source, 2)
    expect.equality(result.navigated, true)
    expect.equality(result.target_correct, true)
    expect.equality(result.target_line, 2)
    expect.equality(result.target_col, 1)
    expect.equality(result.returned, true)
    expect.equality(result.action, true)
  end,

  ["empty Problems explicitly says coverage is reported-only and does not claim the workspace clean"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local layout = assert(require('workbench.ui.layout').new())
      local provider = assert(require('workbench.providers.diagnostics').new())
      local navigation = assert(require('workbench.services.navigation').new())
      local controller = assert(require('workbench.controllers.problems').new({ layout = layout, provider = provider, navigation = navigation }))
      local view, session = assert(controller:open(state.workspace, { focus = false }))
      local text = table.concat(view.model.header, ' ') .. ' ' .. table.concat(vim.tbl_map(function(item) return item.label end, view.model.items), ' ')
      local output = { coverage = session.coverage, has_incomplete_header = text:find('workspace completeness unknown', 1, true) ~= nil,
        has_non_clean_empty = text:find('does not prove every file is clean', 1, true) ~= nil,
        status = view.model.status, resources = provider:status().lease_count }
      view:close()
      output.after_close = provider:status().lease_count
      controller:dispose(); provider:dispose(); navigation:dispose(); layout:dispose()
      cleanup(state)
      return output
    ]])
    expect.equality(result.coverage, "reported-only")
    expect.equality(result.has_incomplete_header, true)
    expect.equality(result.has_non_clean_empty, true)
    expect.equality(result.status, "ready")
    expect.equality(result.resources, 1)
    expect.equality(result.after_close, 0)
  end,

  ["Files badges and Problems share one native hook; closing consumers leaves editor diagnostics and foreign hooks intact"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local ns = vim.api.nvim_create_namespace('wb16-shared')
      vim.diagnostic.set(ns, state.a_buf, { diagnostic(0, 0, 1, 'compiler', 'bad token', 'E1') })
      local foreign_group = vim.api.nvim_create_augroup('WB16ForeignDiagnosticHook', { clear = true })
      local foreign_events = 0
      vim.api.nvim_create_autocmd('DiagnosticChanged', { group = foreign_group, callback = function() foreign_events = foreign_events + 1 end })
      local diagnostic_provider = assert(require('workbench.providers.diagnostics').new())
      local file_provider = {}
      function file_provider:invalidate() end
      function file_provider:enumerate(workspace, directory, options, sink)
        local request = { active = true }
        function request:cancel() self.active = false end
        vim.schedule(function()
          if not request.active then return end
          if directory == state.root_a then
            local resource = assert(state.Resource.from_path(state.a, { workspace_id = workspace.id }))
            sink({ kind = 'batch', items = {{ id = 'file:' .. resource.uri, kind = 'file', label = 'main.lua',
              detail = nil, payload = { resource = resource, lexical_path = state.a, raw_name = 'main.lua', ancestors = { state.root_a } } }} })
          else
            sink({ kind = 'batch', items = {} })
          end
          sink({ kind = 'done', completeness = 'complete' })
        end)
        return request
      end
      local layout = assert(require('workbench.ui.layout').new({ min_editor_width = 24, min_editor_height = 6 }))
      local files = assert(require('workbench.controllers.files').new({ layout = layout, provider = file_provider, diagnostics = diagnostic_provider }))
      local files_view = assert(files:open(state.workspace, { focus = false }))
      local files_session = files.sessions[next(files.sessions)]
      assert(vim.wait(2000, function() return files_session.loaded[files_session.root_id] end, 5))
      local file_id
      for id, item in pairs(files_session.nodes) do if item.payload and item.payload.lexical_path == state.a then file_id = id end end
      assert(file_id)
      local initial_file_badge = files_session.nodes[file_id].detail
      local initial_root_badge = files_session.nodes[files_session.root_id].detail
      vim.cmd('tabnew')
      vim.api.nvim_win_set_buf(0, state.a_buf)
      local navigation = assert(require('workbench.services.navigation').new())
      local problems = assert(require('workbench.controllers.problems').new({ layout = layout, provider = diagnostic_provider, navigation = navigation }))
      local problems_view, problems_session = assert(problems:open(state.workspace, { focus = false }))
      local shared = diagnostic_provider:status()
      vim.diagnostic.set(ns, state.a_buf, { diagnostic(1, 0, 2, 'compiler', 'warning', 'W1') })
      assert(vim.wait(1000, function()
        return files_session.nodes[file_id].detail and files_session.nodes[file_id].detail:find('W1', 1, true)
          and problems_session.root_counts[state.workspace.roots[1].uri].warning == 1
      end, 5))
      problems_view:close()
      local one_left = diagnostic_provider:status()
      vim.diagnostic.set(ns, state.a_buf, { diagnostic(0, 0, 3, 'compiler', 'info', 'I1') })
      assert(vim.wait(1000, function() return files_session.nodes[file_id].detail and files_session.nodes[file_id].detail:find('I1', 1, true) end, 5))
      files_view:close()
      local none_left = diagnostic_provider:status()
      local diagnostics_preserved = #vim.diagnostic.get(state.a_buf) == 1
      local foreign_present = #vim.api.nvim_get_autocmds({ group = foreign_group, event = 'DiagnosticChanged' }) == 1
      local before_foreign = foreign_events
      vim.diagnostic.set(ns, state.a_buf, { diagnostic(0, 0, 1, 'compiler', 'still native', 'E2') })
      local foreign_fired = foreign_events > before_foreign
      local output = { initial_file_badge = initial_file_badge, initial_root_badge = initial_root_badge,
        shared_leases = shared.lease_count, shared_hooks = shared.hook_count, shared_groups = shared.autocmd_groups,
        one_left = one_left.lease_count, one_hook = one_left.hook_count,
        no_left = none_left.lease_count, no_hook = none_left.hook_count,
        diagnostics_preserved = diagnostics_preserved, foreign_present = foreign_present, foreign_fired = foreign_fired }
      files:dispose(); problems:dispose(); diagnostic_provider:dispose(); navigation:dispose(); layout:dispose()
      pcall(vim.api.nvim_del_augroup_by_id, foreign_group)
      cleanup(state)
      return output
    ]])
    expect.equality(result.initial_file_badge, "E1")
    expect.equality(result.initial_root_badge, "E1")
    expect.equality(result.shared_leases, 2)
    expect.equality(result.shared_hooks, 2)
    expect.equality(result.shared_groups, 1)
    expect.equality(result.one_left, 1)
    expect.equality(result.one_hook, 2)
    expect.equality(result.no_left, 0)
    expect.equality(result.no_hook, 0)
    expect.equality(result.diagnostics_preserved, true)
    expect.equality(result.foreign_present, true)
    expect.equality(result.foreign_fired, true)
  end,
})
