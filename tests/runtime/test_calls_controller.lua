local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local helpers = [[
  local function setup(opts)
    opts = opts or {}
    vim.o.columns, vim.o.lines, vim.o.hidden = 120, 40, true
    local root = vim.fn.tempname() .. '-wb15'
    assert(vim.fn.mkdir(root, 'p'))
    local source_path, caller_path, target_path = root .. '/source.lua', root .. '/caller.lua', root .. '/target.lua'
    assert(vim.fn.writefile({ 'local Root = 1', 'Root()' }, source_path) == 0)
    assert(vim.fn.writefile({ 'local Caller = 2', 'Root()' }, caller_path) == 0)
    assert(vim.fn.writefile({ 'local Target = 3', 'Target()' }, target_path) == 0)
    local buffer = vim.fn.bufadd(source_path)
    vim.fn.bufload(buffer)
    vim.api.nvim_win_set_buf(0, buffer)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local workspace = { id = 'workspace-15', generation = 5, roots = { { path = root } } }
    local supported = opts.supported or {
      ['textDocument/prepareCallHierarchy'] = true,
      ['callHierarchy/incomingCalls'] = true,
      ['callHierarchy/outgoingCalls'] = true,
    }
    local provider = { clients = opts.clients or {
      { id = 7, name = 'fake-7', encoding = 'utf-16' },
      { id = 8, name = 'fake-8', encoding = 'utf-8' },
    }, requests = {}, supported = supported }
    function provider:capabilities(context)
      local clients = {}
      for _, client in ipairs(self.clients) do
        local selected = context.client_ids == nil
        if context.client_ids then for _, id in ipairs(context.client_ids) do if id == client.id then selected = true end end end
        if selected and self.supported[context.method] then
          clients[#clients + 1] = { id = client.id, name = client.name, encoding = client.encoding }
        end
      end
      if #clients == 0 then
        return { state = 'unavailable', code = #self.clients == 0 and 'no_attached_client' or 'unsupported_method',
          reason = #self.clients == 0 and 'no language server is attached to this buffer' or 'attached language servers do not support ' .. context.method,
          clients = {}, operations = {} }
      end
      return { state = 'ready', clients = clients, operations = { 'request' } }
    end
    function provider:start(options, sink)
      local request = { options = options, sink = sink, active = true }
      self.requests[#self.requests + 1] = request
      local handle = {}
      function handle:cancel(reason)
        if not request.active then return false end
        request.active, request.cancelled = false, reason or 'cancelled'
        return true
      end
      function handle:dispose() return self:cancel('disposed') end
      request.handle = handle
      return handle
    end
    local layout = assert(require('workbench.ui.layout').new({ min_editor_width = 30 }))
    local navigation = assert(require('workbench.services.navigation').new())
    local actions = require('workbench.core.actions').new()
    local controller = assert(require('workbench.controllers.calls').new({
      layout = layout, provider = provider, navigation = navigation, actions = actions, workspace = workspace,
      max_depth = opts.max_depth, max_children = opts.max_children, max_edges = opts.max_edges,
    }))
    return { root = root, source_path = source_path, caller_path = caller_path, target_path = target_path,
      buffer = buffer, workspace = workspace, provider = provider, layout = layout, navigation = navigation,
      actions = actions, controller = controller }
  end

  local function raw_call(name, path, start, finish, token, kind)
    return {
      name = name, kind = kind or 12, uri = vim.uri_from_fname(path), detail = 'mod.' .. name,
      range = { start = { line = 0, character = start or 0 }, ['end'] = { line = 0, character = finish or 8 } },
      selectionRange = { start = { line = 0, character = (start or 0) + 1 }, ['end'] = { line = 0, character = (finish or 8) - 1 } },
      data = { token = token },
    }
  end

  local function workbench_item(state, id, call_item, client_id, direction, ranges)
    local encoding = client_id == 8 and 'utf-8' or 'utf-16'
    local resource = assert(require('workbench.core.resource').from_uri(call_item.uri, { workspace_id = state.workspace.id }))
    local selected = call_item.selectionRange
    local range = selected
    if direction == 'incoming' and ranges and ranges[1] then range = ranges[1] end
    local norm = { start = range.start, finish = range['end'] }
    local location = assert(require('workbench.core.location').new(resource, {
      range = norm, encoding = encoding, client_id = client_id,
    }))
    local normalized_ranges = {}
    for index, item_range in ipairs(ranges or {}) do
      normalized_ranges[index] = { start = item_range.start, finish = item_range['end'] }
    end
    return { id = id, kind = 'call', label = call_item.name, detail = call_item.detail, location = location,
      payload = { client_id = client_id, encoding = encoding, call_item = vim.deepcopy(call_item),
        call_ranges = normalized_ranges, direction = direction } }
  end

  local function emit(request, kind, payload)
    payload = payload or {}
    payload.kind = kind
    payload.generation = request.options.generation
    payload.session_id = request.options.session_id
    request.sink(payload)
  end

  local function complete(request, items, status, err)
    request.active, request.finished = false, true
    if items and #items > 0 then emit(request, 'batch', { items = items }) end
    emit(request, 'done', { status = status or 'complete', completeness = status == 'partial' and 'partial' or 'complete', error = err })
  end

  local function dispose(state)
    state.controller:dispose()
    state.navigation:dispose()
    state.layout:dispose()
    vim.fn.delete(state.root, 'rf')
  end

  local function same_path(left, right)
    local uv = vim.uv or vim.loop
    return vim.fs.normalize(uv.fs_realpath(left) or left) == vim.fs.normalize(uv.fs_realpath(right) or right)
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
  ["preparation keeps multiple roots and only expansion requests the originating client's edges"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local view, active = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local prepare = state.provider.requests[1]
      assert(prepare, vim.inspect(active))
      local params7 = prepare.options.params({ id = 7, offset_encoding = 'utf-16' })
      local params8 = prepare.options.params({ id = 8, offset_encoding = 'utf-8' })
      local root = raw_call('Root', state.source_path, 0, 8, 'opaque-root')
      local other_root = raw_call('OtherRoot', state.caller_path, 0, 8, 'opaque-other')
      complete(prepare, {
        workbench_item(state, 'root-7', root, 7, 'outgoing'),
        workbench_item(state, 'root-8', other_root, 8, 'outgoing'),
      })
      local action
      for _, item in ipairs(state.actions:list({ workspace = state.workspace, bufnr = state.buffer, win = vim.api.nvim_get_current_win() })) do
        if item.id == 'calls.hierarchy' then action = item.available end
      end
      local first = active.roots[1]
      view:toggle_expanded(first.id)
      local expansion = state.provider.requests[2]
      local request_params = expansion.options.params({ id = 7, offset_encoding = 'utf-16' })
      local repeated = raw_call('Root', state.source_path, 0, 8, 'opaque-root')
      local branch = raw_call('Branch', state.target_path, 0, 8, 'opaque-branch')
      complete(expansion, {
        workbench_item(state, 'self-edge', repeated, 7, 'outgoing', {
          { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 4 } },
        }),
        workbench_item(state, 'branch-edge', branch, 7, 'outgoing', {
          { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 6 } },
          { start = { line = 2, character = 0 }, ['end'] = { line = 2, character = 6 } },
        }),
      })
      local self_node, branch_one, branch_two = first.children[1], first.children[2], first.children[3]
      view:toggle_expanded(branch_one.id)
      local mutual = state.provider.requests[3]
      local returns_to_root = raw_call('Root', state.source_path, 0, 8, 'opaque-root')
      complete(mutual, { workbench_item(state, 'mutual-edge', returns_to_root, 7, 'outgoing', {
        { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 4 } },
      }) })
      local cycle = branch_one.children[1]
      local opened = assert(state.controller:open_selected(active, branch_one.id))
      local target_path = vim.api.nvim_buf_get_name(opened.buf)
      assert(state.controller:return_to_origin(active))
      local output = {
        roots = #active.roots,
        request_count_after_prepare = 1,
        prepare_method = prepare.options.method,
        prepare_client_ids = prepare.options.client_ids,
        params7 = params7.position.character,
        params8 = params8.position.character,
        action_available = action and action.enabled,
        expansion_method = expansion.options.method,
        expansion_client_ids = expansion.options.client_ids,
        expansion_max_items = expansion.options.max_items,
        item_data = request_params.item.data.token,
        same_target_edges = branch_one.id ~= branch_two.id and branch_one.call_item.uri == branch_two.call_item.uri,
        direct_recursion = self_node.cycle and not self_node.expandable,
        mutual_recursion = cycle.cycle and not cycle.expandable,
        edge_count = active.edge_count,
        target_opened = same_path(target_path, state.target_path),
        return_to_source = vim.api.nvim_get_current_win() == active.source_win,
      }
      dispose(state)
      return output
    ]])
    expect.equality(result.roots, 2)
    expect.equality(result.request_count_after_prepare, 1)
    expect.equality(result.prepare_method, "textDocument/prepareCallHierarchy")
    expect.equality(result.action_available, true)
    expect.equality(result.expansion_method, "callHierarchy/outgoingCalls")
    expect.equality(result.expansion_client_ids, { 7 })
    expect.equality(result.expansion_max_items, 201)
    expect.equality(result.item_data, "opaque-root")
    expect.equality(result.same_target_edges, true)
    expect.equality(result.direct_recursion, true)
    expect.equality(result.mutual_recursion, true)
    expect.equality(result.edge_count, 4)
    expect.equality(result.target_opened, true)
    expect.equality(result.return_to_source, true)
  end,

  ["direction switching and collapse cancel expansions and reject late edges; incoming rows navigate to call sites"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ clients = { { id = 7, name = 'fake-7', encoding = 'utf-16' } } })
      local view, active = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local root_item = raw_call('Root', state.source_path, 0, 8, 'root')
      complete(state.provider.requests[1], { workbench_item(state, 'root', root_item, 7, 'outgoing') })
      local root = active.roots[1]
      view:toggle_expanded(root.id)
      local stale_request = state.provider.requests[2]
      assert(state.controller:set_direction(active, 'incoming'))
      local stale = raw_call('StaleOutgoing', state.target_path, 0, 8, 'stale')
      complete(stale_request, { workbench_item(state, 'stale-edge', stale, 7, 'outgoing') })
      local after_stale = #root.children
      view:toggle_expanded(root.id)
      local collapsed_request = state.provider.requests[3]
      view:toggle_expanded(root.id)
      local cancelled_after_collapse = collapsed_request.cancelled ~= nil
      local stale_caller = raw_call('StaleCaller', state.target_path, 0, 8, 'stale-caller')
      complete(collapsed_request, { workbench_item(state, 'late-caller', stale_caller, 7, 'incoming', {
        { start = { line = 0, character = 3 }, ['end'] = { line = 0, character = 8 } },
      }) })
      local after_cancel = #root.children
      view:toggle_expanded(root.id)
      local incoming = state.provider.requests[4]
      local caller = raw_call('Caller', state.caller_path, 0, 8, 'caller')
      complete(incoming, { workbench_item(state, 'incoming-edge', caller, 7, 'incoming', {
        { start = { line = 1, character = 2 }, ['end'] = { line = 1, character = 6 } },
        { start = { line = 1, character = 8 }, ['end'] = { line = 1, character = 12 } },
      }) })
      local first, second = root.children[1], root.children[2]
      local opened = assert(state.controller:open_selected(active, first.id))
      local opened_path = vim.api.nvim_buf_get_name(opened.buf)
      local cursor = opened.cursor
      assert(state.controller:return_to_origin(active))
      local output = {
        stale_cancelled = stale_request.cancelled ~= nil,
        after_direction_stale = after_stale,
        collapse_cancelled = cancelled_after_collapse,
        after_collapse_stale = after_cancel,
        direction = active.direction,
        method = incoming.options.method,
        callsite_distinct_ids = first.id ~= second.id,
        first_start = first.location.range.start.character,
        second_start = second.location.range.start.character,
        opened_caller = same_path(opened_path, state.caller_path),
        opened_line = cursor[1],
        cursor_byte = cursor[2],
      }
      dispose(state)
      return output
    ]])
    expect.equality(result.stale_cancelled, true)
    expect.equality(result.after_direction_stale, 0)
    expect.equality(result.collapse_cancelled, true)
    expect.equality(result.after_collapse_stale, 0)
    expect.equality(result.direction, "incoming")
    expect.equality(result.method, "callHierarchy/incomingCalls")
    expect.equality(result.callsite_distinct_ids, true)
    expect.equality(result.first_start, 2)
    expect.equality(result.second_start, 8)
    expect.equality(result.opened_caller, true)
    expect.equality(result.opened_line, 2)
    expect.equality(result.cursor_byte, 2)
  end,

  ["partial preparation and expansion preserve good data and report scoped failures"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local view, active = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local root_item = raw_call('Root', state.source_path, 0, 8, 'root')
      local prepare = state.provider.requests[1]
      emit(prepare, 'batch', { items = { workbench_item(state, 'root-7', root_item, 7, 'outgoing') } })
      complete(prepare, nil, 'partial', { message = 'client 8 timed out' })
      local root = active.roots[1]
      view:toggle_expanded(root.id)
      local expansion = state.provider.requests[2]
      local branch = raw_call('Branch', state.target_path, 0, 8, 'branch')
      complete(expansion, { workbench_item(state, 'branch', branch, 7, 'outgoing', {
        { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 5 } },
      }) }, 'partial', { message = 'server disconnected after first edge' })
      local output = {
        prepare_phase = active.phase,
        prepare_roots = #active.roots,
        prepare_notice = active.notice,
        expansion = root.expansion,
        child_count = #root.children,
        partial_row = root.children[2] and root.children[2].label,
      }
      dispose(state)
      return output
    ]])
    expect.equality(result.prepare_phase, "Partial")
    expect.equality(result.prepare_roots, 1)
    expect.equality(result.prepare_notice, "client 8 timed out")
    expect.equality(result.expansion, "partial")
    expect.equality(result.child_count, 2)
    expect.equality(result.partial_row:find("Partial result", 1, true) ~= nil, true)
  end,

  ["per-node and depth caps are visible and do not permit hidden eager work"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ clients = { { id = 7, name = 'fake-7', encoding = 'utf-16' } }, max_depth = 1, max_children = 2 })
      local view, active = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local root_item = raw_call('Root', state.source_path, 0, 8, 'root')
      complete(state.provider.requests[1], { workbench_item(state, 'root', root_item, 7, 'outgoing') })
      local root = active.roots[1]
      view:toggle_expanded(root.id)
      local expansion = state.provider.requests[2]
      local edge1 = raw_call('A', state.target_path, 0, 8, 'a')
      local edge2 = raw_call('B', state.caller_path, 0, 8, 'b')
      local edge3 = raw_call('C', state.source_path, 0, 8, 'c')
      local function range(line) return { start = { line = line, character = 0 }, ['end'] = { line = line, character = 2 } } end
      complete(expansion, {
        workbench_item(state, 'edge-a', edge1, 7, 'outgoing', { range(1) }),
        workbench_item(state, 'edge-b', edge2, 7, 'outgoing', { range(1) }),
        workbench_item(state, 'edge-c', edge3, 7, 'outgoing', { range(1) }),
      })
      local first_row = view.rows[view.row_index[root.children[1].id] ]
      local output = {
        accepted_edges = active.edge_count,
        child_nodes = #root.children,
        capped_state = root.expansion,
        cap_label = root.children[3] and root.children[3].label,
        first_depth = root.children[1].depth,
        first_expandable = first_row and first_row.has_children,
        request_count = #state.provider.requests,
      }
      dispose(state)
      return output
    ]])
    expect.equality(result.accepted_edges, 2)
    expect.equality(result.child_nodes, 3)
    expect.equality(result.capped_state, "partial")
    expect.equality(result.cap_label:find("at most 2 call edges", 1, true) ~= nil, true)
    expect.equality(result.first_depth, 1)
    expect.equality(result.first_expandable, false)
    expect.equality(result.request_count, 2)
  end,

  ["unsupported call hierarchy is visible and a changed source cannot expand a stale prepared item"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ supported = {} })
      local available
      for _, action in ipairs(state.actions:list({ workspace = state.workspace, bufnr = state.buffer, win = vim.api.nvim_get_current_win() })) do
        if action.id == 'calls.hierarchy' then available = action.available end
      end
      local unavailable_view, unavailable_err = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local unavailable_session = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local unsupported = { disabled = available and not available.enabled, reason = available and available.reason,
        error = unavailable_err and unavailable_err.code, phase = unavailable_session.phase, requests = #state.provider.requests }
      unavailable_view:close()
      state.provider.supported['textDocument/prepareCallHierarchy'] = true
      local view, active = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local call = raw_call('Root', state.source_path, 0, 8, 'root')
      complete(state.provider.requests[1], { workbench_item(state, 'root', call, 7, 'outgoing') })
      vim.api.nvim_buf_set_lines(state.buffer, 0, 1, false, { 'local Edited = 9' })
      view:toggle_expanded(active.roots[1].id)
      local output = { unsupported = unsupported, request_count = #state.provider.requests,
        expansion = active.roots[1].expansion, notice = active.roots[1].children[1] and active.roots[1].children[1].label }
      dispose(state)
      return output
    ]])
    expect.equality(result.unsupported.disabled, true)
    expect.equality(result.unsupported.error, "unsupported_method")
    expect.equality(result.unsupported.phase, "Unavailable")
    expect.equality(result.unsupported.requests, 0)
    expect.equality(result.unsupported.reason:find("do not support textDocument/prepareCallHierarchy", 1, true) ~= nil, true)
    expect.equality(result.request_count, 1)
    expect.equality(result.expansion, "error")
    expect.equality(result.notice:find("Source document changed", 1, true) ~= nil, true)
  end,

  ["closing one tab cancels its pending expansion without interfering with another tab"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ clients = { { id = 7, name = 'fake-7', encoding = 'utf-16' } } })
      local tab1 = vim.api.nvim_get_current_tabpage()
      local view1, active1 = state.controller:open(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local root1 = raw_call('First', state.source_path, 0, 8, 'first')
      complete(state.provider.requests[1], { workbench_item(state, 'root-1', root1, 7, 'outgoing') })
      view1:toggle_expanded(active1.roots[1].id)
      local request1 = state.provider.requests[2]

      local second_path = state.root .. '/second.lua'
      assert(vim.fn.writefile({ 'local Second = 2' }, second_path) == 0)
      vim.cmd('tabnew')
      local second_buffer = vim.fn.bufadd(second_path)
      vim.fn.bufload(second_buffer)
      vim.api.nvim_win_set_buf(0, second_buffer)
      local tab2 = vim.api.nvim_get_current_tabpage()
      local view2, active2 = state.controller:open(state.workspace, second_buffer, vim.api.nvim_get_current_win(), { focus = false })
      local second = raw_call('Second', second_path, 0, 8, 'second')
      complete(state.provider.requests[3], { workbench_item(state, 'root-2', second, 7, 'outgoing') })
      view2:toggle_expanded(active2.roots[1].id)
      local request2 = state.provider.requests[4]
      state.layout:close('workbench-calls', tab1)
      local first_stale = raw_call('Late', state.target_path, 0, 8, 'late')
      complete(request1, { workbench_item(state, 'late-1', first_stale, 7, 'outgoing') })
      local target = raw_call('Target', state.target_path, 0, 8, 'target')
      complete(request2, { workbench_item(state, 'edge-2', target, 7, 'outgoing', {
        { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 4 } },
      }) })
      local output = { first_cancelled = request1.cancelled ~= nil, second_active = request2.cancelled == nil,
        first_edges = active1.edge_count, second_edges = active2.edge_count, second_child = active2.roots[1].children[1].call_item.name,
        sessions = #state.controller:status().sessions, tabs_different = tab1 ~= tab2 }
      dispose(state)
      return output
    ]])
    expect.equality(result.first_cancelled, true)
    expect.equality(result.second_active, true)
    expect.equality(result.first_edges, 0)
    expect.equality(result.second_edges, 1)
    expect.equality(result.second_child, "Target")
    expect.equality(result.sessions, 1)
    expect.equality(result.tabs_different, true)
  end,
})
