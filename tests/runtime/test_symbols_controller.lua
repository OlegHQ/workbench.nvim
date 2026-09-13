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
    local root = vim.fn.tempname() .. '-wb14'
    assert(vim.fn.mkdir(root, 'p') == 1)
    local source_path = root .. '/source.lua'
    local outside_path = root .. '-outside.lua'
    assert(vim.fn.writefile({ 'local Alpha = 1', 'print(Alpha)' }, source_path) == 0)
    assert(vim.fn.writefile({ 'return Alpha' }, outside_path) == 0)
    local buffer = vim.fn.bufadd(source_path)
    vim.fn.bufload(buffer)
    vim.api.nvim_win_set_buf(0, buffer)
    local workspace = { id = 'workspace-14', generation = 4, roots = { { path = root } } }
    local methods = opts.methods or {
      ['workspace/symbol'] = true,
      ['workspaceSymbol/resolve'] = true,
      ['textDocument/references'] = true,
      ['textDocument/definition'] = true,
      ['textDocument/typeDefinition'] = true,
      ['textDocument/implementation'] = true,
    }
    local provider = { clients = { { id = 7, name = 'fake-7', encoding = 'utf-16' }, { id = 8, name = 'fake-8', encoding = 'utf-8' } }, requests = {} }
    function provider:capabilities(context)
      local supported = methods[context.method] == true
      local attached, clients = {}, {}
      for _, client in ipairs(self.clients) do
        attached[#attached + 1] = { id = client.id, name = client.name }
        local wanted = context.client_ids == nil
        if context.client_ids then for _, id in ipairs(context.client_ids) do if id == client.id then wanted = true end end end
        if wanted and supported then clients[#clients + 1] = { id = client.id, name = client.name, encoding = client.encoding } end
      end
      if #clients == 0 then
        return { state = 'unavailable', code = #self.clients == 0 and 'no_attached_client' or 'unsupported_method',
          reason = #self.clients == 0 and 'no language server is attached to this buffer' or 'attached language servers do not support ' .. context.method,
          clients = attached, operations = {} }
      end
      return { state = 'ready', clients = clients, operations = { 'request' } }
    end
    function provider:start(options, sink)
      local request = { options = options, sink = sink, active = true }
      self.requests[#self.requests + 1] = request
      local handle = {}
      function handle:cancel(reason)
        if not request.active then return false end
        request.active, request.cancelled = false, reason
        return true
      end
      function handle:dispose() return self:cancel('disposed') end
      request.handle = handle
      return handle
    end
    local layout = assert(require('workbench.ui.layout').new({ min_editor_width = 30 }))
    local store = assert(require('workbench.services.results').new())
    local navigation = assert(require('workbench.services.navigation').new())
    local actions = require('workbench.core.actions').new()
    local controller = assert(require('workbench.controllers.symbols').new({
      layout = layout, provider = provider, store = store, navigation = navigation, actions = actions,
      workspace = workspace, settings = opts.settings, get_settings = opts.get_settings, debounce_ms = opts.debounce_ms or 10,
    }))
    return { root = root, source_path = source_path, outside_path = outside_path, buffer = buffer,
      workspace = workspace, methods = methods, provider = provider, layout = layout, store = store,
      navigation = navigation, actions = actions, controller = controller }
  end

  local function location(path, workspace_id, encoding, first, finish)
    local resource = assert(require('workbench.core.resource').from_path(path, { workspace_id = workspace_id }))
    return assert(require('workbench.core.location').new(resource, {
      range = { start = { line = 0, character = first or 0 }, finish = { line = 0, character = finish or 5 } },
      encoding = encoding or 'utf-16', client_id = encoding == 'utf-8' and 8 or 7,
    }))
  end

  local function result_item(state, id, path, client_id, encoding)
    local found_location = location(path, state.workspace.id, encoding, 0, 5)
    return { id = id, kind = 'location', label = 'Alpha', location = found_location,
      payload = { client_id = client_id or found_location.client_id, method = 'textDocument/references', encoding = encoding or 'utf-16' } }
  end

  local function emit(request, kind, payload)
    payload = payload or {}
    if kind == 'done' then request.active, request.finished = false, true end
    payload.kind = kind
    payload.generation = request.options.generation
    payload.session_id = request.options.session_id
    request.sink(payload)
  end

  local function complete(request, items, status, err)
    if items and #items > 0 then emit(request, 'batch', { items = items }) end
    emit(request, 'done', { status = status or 'complete', completeness = status == 'partial' and 'partial' or 'complete', error = err })
  end

  local function dispose(state)
    state.controller:dispose()
    state.navigation:dispose()
    state.store:dispose()
    state.layout:dispose()
    vim.fn.delete(state.root, 'rf')
    vim.fn.delete(state.outside_path)
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
  ["workspace symbols use the shared result store and query the exact source client context"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local original = assert(state.store:create({ id = 'search:wb14', provider_id = 'rg', workspace_id = state.workspace.id, generation = 9,
        query = { query = 'needle', scope = { kind = 'workspace' } }, status = 'running', completeness = 'unknown' }))
      local view = assert(state.controller:workspace_symbols(state.workspace, 'Alpha', { bufnr = state.buffer, win = vim.api.nvim_get_current_win(), immediate = true, focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local request = state.provider.requests[1]
      local params = request.options.params({ id = 7, offset_encoding = 'utf-16' })
      complete(request, { {
        id = 'ws-alpha', kind = 'symbol', label = 'Alpha', location = location(state.source_path, state.workspace.id),
        payload = { client_id = 7, method = 'workspace/symbol', symbol_kind = 13 },
      } })
      local summary = state.store:summary(active.current.result_id)
      local old = state.store:summary(original.id)
      local result = { method = request.options.method, query = params.query, source_buffer = request.options.bufnr == state.buffer,
        status = summary.status, symbol_count = summary.item_count, search_count = old.item_count,
        shared_actions = state.actions:list({ workspace = state.workspace, bufnr = state.buffer, win = vim.api.nvim_get_current_win() }),
        selected = view.selected_id, panel = view.placement }
      dispose(state)
      return result
    ]])
    expect.equality(result.method, "workspace/symbol")
    expect.equality(result.query, "Alpha")
    expect.equality(result.source_buffer, true)
    expect.equality(result.status, "complete")
    expect.equality(result.symbol_count, 1)
    expect.equality(result.search_count, 0)
    expect.equality(result.panel, "results")
    local ids = {}
    for _, action in ipairs(result.shared_actions) do ids[action.id] = action end
    expect.equality(ids["symbols.workspace"].available.enabled, true)
    expect.equality(ids["symbols.references"].available.enabled, true)
  end,

  ["references use explicit settings, deduplicate by encoding, and do not mutate prior search state"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ settings = { symbols = { include_declaration = false } } })
      local original_location = location(state.source_path, state.workspace.id)
      assert(state.store:create({ id = 'search:retained', provider_id = 'rg', workspace_id = state.workspace.id, generation = 2,
        query = { query = 'needle', scope = { kind = 'workspace' } }, status = 'running', completeness = 'unknown' }))
      assert(state.store:merge('search:retained', { { id = 'match:one', kind = 'match', label = 'needle', location = original_location } }))
      assert(state.store:finish('search:retained', 'complete', 'complete'))
      local old_session = assert(state.store:open_session('search:retained', { id = 'search:retained:view', selected_id = 'match:one' }))
      local view = assert(state.controller:references(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local request = state.provider.requests[1]
      local params = request.options.params({ id = 7, offset_encoding = 'utf-16' })
      local a = result_item(state, 'ref-from-7', state.source_path, 7, 'utf-16')
      local b = result_item(state, 'ref-from-8', state.source_path, 8, 'utf-16')
      complete(request, { a, b })
      local summary = state.store:summary(active.current.result_id)
      local page = state.store:page(active.current.result_id, 0, 20)
      local merged = page.items[1]
      local retained = old_session:snapshot()
      local output = { include = params.context.includeDeclaration, position = params.position,
        method = request.options.method, count = summary.item_count, clients = merged.payload.client_ids,
        old_count = state.store:summary('search:retained').item_count, old_selected = retained.selected_id,
        separate_set = active.current.result_id ~= 'search:retained', panel = view.placement }
      dispose(state)
      return output
    ]])
    expect.equality(result.method, "textDocument/references")
    expect.equality(result.include, false)
    expect.equality(type(result.position.line), "number")
    expect.equality(result.count, 1)
    expect.equality(#result.clients, 2)
    expect.equality(result.old_count, 1)
    expect.equality(result.old_selected, "match:one")
    expect.equality(result.separate_set, true)
    expect.equality(result.panel, "results")
  end,

  ["a semantic view hidden in another tab does not refresh its provider"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local view = assert(state.controller:references(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local request = state.provider.requests[1]
      complete(request, { result_item(state, 'hidden-reference', state.source_path, 7, 'utf-16') })
      local origin_tab = vim.api.nvim_get_current_tabpage()
      local before = #state.provider.requests
      vim.cmd('tabnew')
      assert(vim.api.nvim_get_current_tabpage() ~= origin_tab)
      vim.api.nvim_exec_autocmds('BufEnter', { buffer = state.buffer, modeline = false })
      vim.wait(80)
      local hidden = vim.api.nvim_tabpage_is_valid(origin_tab) and vim.api.nvim_win_is_valid(view.window)
      local during = #state.provider.requests
      vim.cmd('tabclose')
      local after = #state.provider.requests
      local output = { before = before, during = during, after = after, hidden = hidden,
        tab_returned = vim.api.nvim_get_current_tabpage() == origin_tab,
        result_count = state.store:summary(active.current.result_id).item_count,
        layout_views = state.layout:status().active_views }
      dispose(state)
      return output
    ]])
    expect.equality(result.before, 1)
    expect.equality(result.during, result.before)
    expect.equality(result.after, result.before)
    expect.equality(result.hidden, true)
    expect.equality(result.tab_returned, true)
    expect.equality(result.result_count, 1)
    expect.equality(result.layout_views, 1)
  end,

  ["definition results outside the selected workspace use shared navigation and return to origin"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local origin_win = vim.api.nvim_get_current_win()
      local original_buffer = state.buffer
      local cwd = vim.fn.getcwd()
      local view = assert(state.controller:definition(state.workspace, state.buffer, origin_win, { focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local request = state.provider.requests[1]
      complete(request, { result_item(state, 'definition-outside', state.outside_path, 7, 'utf-16') })
      local opened = assert(state.controller:open_selected(active))
      local opened_path = vim.api.nvim_buf_get_name(opened.buf)
      local returned = assert(state.controller:return_to_origin(active))
      local output = { method = request.options.method, outside = vim.fs.normalize(opened_path) == vim.fs.normalize((vim.uv or vim.loop).fs_realpath(state.outside_path)),
        returned = returned ~= nil, origin_buffer = vim.api.nvim_win_get_buf(origin_win) == original_buffer,
        cwd_same = vim.fn.getcwd() == cwd, view_open = not view.closed }
      dispose(state)
      return output
    ]])
    expect.equality(result.method, "textDocument/definition")
    expect.equality(result.opened_path, result.expected_path)
    expect.equality(result.outside, true)
    expect.equality(result.returned, true)
    expect.equality(result.origin_buffer, true)
    expect.equality(result.view_open, true)
  end,

  ["unresolved workspace symbols resolve through their original client and replace the retained row"] = function()
    local result = evaluate(helpers .. [[
      local state = setup()
      local view = assert(state.controller:workspace_symbols(state.workspace, 'Alpha', { bufnr = state.buffer, win = vim.api.nvim_get_current_win(), immediate = true, focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local search = state.provider.requests[1]
      local unresolved = { id = 'unresolved-alpha', kind = 'symbol', label = 'Alpha', detail = 'module',
        payload = { client_id = 8, method = 'workspace/symbol', resolve_item = { name = 'Alpha', kind = 13, data = { token = 'original-8' } } } }
      complete(search, { unresolved })
      view.selected_id = unresolved.id
      local resolved_ok, resolved_err = state.controller:resolve_selected(active)
      local request = state.provider.requests[2]
      local params = request.options.params({ id = 8, offset_encoding = 'utf-8' })
      local target = result_item(state, 'temporary-resolved-id', state.outside_path, 8, 'utf-8')
      target.kind = 'symbol'
      target.payload.method = 'workspaceSymbol/resolve'
      complete(request, { target })
      local item = state.store:item(active.current.result_id, unresolved.id)
      local output = { started = resolved_ok == true, error = resolved_err and resolved_err.code,
        method = request.options.method, client_ids = request.options.client_ids,
        params_name = params.name, params_data = params.data.token, count = state.store:summary(active.current.result_id).item_count,
        id_preserved = item.id == unresolved.id, location = item.location.resource.path == state.outside_path,
        action_available = (function()
          for _, action in ipairs(state.actions:list({ workspace = state.workspace, bufnr = state.buffer, win = vim.api.nvim_get_current_win(), symbols = active })) do
            if action.id == 'symbols.resolve' then return action.available.enabled end
          end
        end)() }
      dispose(state)
      return output
    ]])
    expect.equality(result.started, true)
    expect.equality(result.method, "workspaceSymbol/resolve")
    expect.equality(result.client_ids[1], 8)
    expect.equality(result.params_name, "Alpha")
    expect.equality(result.params_data, "original-8")
    expect.equality(result.count, 1)
    expect.equality(result.id_preserved, true)
    expect.equality(result.location, true)
    expect.equality(result.action_available, false)
  end,

  ["workspace-symbol debounce cancels superseded generations and disposal keeps foreign hooks"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ debounce_ms = 15 })
      local group = vim.api.nvim_create_augroup('WB14Foreign', { clear = true })
      local foreign_calls = 0
      vim.api.nvim_create_autocmd('User', { group = group, pattern = 'WB14Keep', callback = function() foreign_calls = foreign_calls + 1 end })
      local view = assert(state.controller:workspace_symbols(state.workspace, '', { bufnr = state.buffer, win = vim.api.nvim_get_current_win(), focus = false }))
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      state.controller:set_query(active, 'old')
      state.controller:set_query(active, 'newest')
      assert(vim.wait(1000, function() return #state.provider.requests == 1 end, 5), 'debounced query did not start')
      local first = state.provider.requests[1]
      local first_params = first.options.params({ id = 7, offset_encoding = 'utf-16' })
      state.controller:set_query(active, 'replacement', true)
      local second = state.provider.requests[2]
      local stale = { id = 'stale', kind = 'symbol', label = 'stale', location = location(state.source_path, state.workspace.id) }
      complete(first, { stale })
      local second_summary = state.store:summary(active.current.result_id)
      view:close()
      vim.api.nvim_exec_autocmds('User', { pattern = 'WB14Keep' })
      local output = { calls = #state.provider.requests, first_query = first_params.query,
        first_cancelled = first.cancelled ~= nil, replacement_count = second_summary.item_count,
        closed = state.controller:status().sessions[1] and not state.controller:status().sessions[1].view,
        foreign_calls = foreign_calls, foreign_hook = #vim.api.nvim_get_autocmds({ group = group }) }
      dispose(state)
      vim.api.nvim_del_augroup_by_id(group)
      return output
    ]])
    expect.equality(result.calls, 2)
    expect.equality(result.first_query, "newest")
    expect.equality(result.first_cancelled, true)
    expect.equality(result.replacement_count, 0)
    expect.equality(result.closed, true)
    expect.equality(result.foreign_calls, 1)
    expect.equality(result.foreign_hook, 1)
  end,

  ["missing LSP support is reported distinctly from an empty complete result"] = function()
    local result = evaluate(helpers .. [[
      local state = setup({ methods = {}, settings = { symbols = { include_declaration = false } } })
      local available
      for _, action in ipairs(state.actions:list({ workspace = state.workspace, bufnr = state.buffer, win = vim.api.nvim_get_current_win() })) do
        if action.id == 'symbols.references' then available = action.available end
      end
      local view, err = state.controller:references(state.workspace, state.buffer, vim.api.nvim_get_current_win(), { focus = false })
      local active = state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      local summary = state.store:summary(active.current.result_id)
      local output = { disabled = available.enabled == false, reason = available.reason,
        error = err and err.code, status = summary.status, completeness = summary.completeness }
      dispose(state)
      return output
    ]])
    expect.equality(result.disabled, true)
    expect.equality(result.reason:find("do not support textDocument/references", 1, true) ~= nil, true)
    expect.equality(result.error, "unsupported_method")
    expect.equality(result.status, "error")
    expect.equality(result.completeness, "unknown")
  end,
})
