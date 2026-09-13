local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local helpers = [[
  local function setup(available)
    vim.o.columns, vim.o.lines = 120, 35
    vim.o.hidden = true
    local buffer = vim.api.nvim_get_current_buf()
    local path = vim.fn.tempname() .. '-outline.lua'
    vim.api.nvim_buf_set_name(buffer, path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
      'local Zoo = {}',
      '  function inner() return true end',
      'local alpha = 1',
    })
    local provider = { available = available ~= false, requests = {} }
    function provider:capabilities()
      if not self.available then
        return { state = 'unavailable', code = 'no_attached_client', reason = 'No attached language server supports document symbols' }
      end
      return { state = 'ready', clients = { { id = 7, encoding = 'utf-16' } } }
    end
    function provider:start(options, callback)
      local request = { options = options, callback = callback, active = true }
      self.requests[#self.requests + 1] = request
      local handle = {}
      function handle:is_active() return request.active end
      function handle:cancel(reason)
        request.active = false
        request.cancelled = reason
        return true
      end
      request.handle = handle
      return handle
    end
    local layout = assert(require('workbench.ui.layout').new())
    local navigation = assert(require('workbench.services.navigation').new())
    local controller = assert(require('workbench.controllers.outline').new({
      layout = layout, provider = provider, navigation = navigation,
    }))
    local view = assert(controller:open({ focus = false }))
    local session = controller.sessions[vim.api.nvim_get_current_tabpage()]
    return { buffer = buffer, path = path, provider = provider, layout = layout,
      navigation = navigation, controller = controller, view = view, session = session }
  end

  local function item(state, id, label, parent_id, first_line, last_line, first_col, last_col)
    local uri = vim.uri_from_fname(state.path)
    local location = assert(require('workbench.core.location').new({ uri = uri, scheme = 'file', path = state.path }, {
      range = { start = { line = first_line, character = first_col }, finish = { line = first_line, character = first_col + 2 } },
      encoding = 'utf-16', client_id = 7,
    }))
    return {
      id = id, label = label, parent_id = parent_id, kind = 'symbol', location = location,
      payload = {
        client_id = 7, symbol_kind = 12,
        symbol_range = { start = { line = first_line, character = first_col }, ['end'] = { line = last_line, character = last_col } },
        selection_range = { start = { line = first_line, character = first_col }, ['end'] = { line = first_line, character = first_col + 2 } },
      },
    }
  end

  local function symbols(state, prefix)
    prefix = prefix or ''
    return {
      item(state, prefix .. 'zoo', 'Zoo', nil, 0, 2, 0, 15),
      item(state, prefix .. 'inner', 'inner', prefix .. 'zoo', 1, 1, 2, 30),
      item(state, prefix .. 'alpha', 'alpha', nil, 2, 2, 0, 15),
    }
  end

  local function complete(request, items, status)
    request.callback({ kind = 'batch', client_id = 7, items = items })
    request.callback({ kind = 'done', status = status or 'complete' })
  end

  local function dispose(state)
    state.controller:dispose()
    state.navigation:dispose()
    state.layout:dispose()
  end
]]

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], {
        root,
        root .. "/tests",
      })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["Outline restores scroll for a long projection after fresh symbols arrive"] = function()
    local result=evaluate(helpers .. [[
      local state=setup(true)
      local rows={}
      for index=1,100 do rows[index]=item(state,'row-'..index,'Symbol '..index,nil,0,0,0,10) end
      complete(state.provider.requests[1],rows)
      for _=1,69 do assert(state.view:move(1)) end
      local offset=state.view.scroll_offset
      assert(offset>0)
      state.view:close()
      local view=assert(state.controller:open({focus=false}))
      complete(state.provider.requests[#state.provider.requests],rows)
      assert(view.selected_id=='row-70' and view.scroll_offset==offset)
      dispose(state)
      return true
    ]])
    expect.equality(result,true)
  end,

  ["closed Outline retains view preferences without retaining requests or watchers"] = function()
    local result=evaluate(helpers .. [[
      local state=setup(true)
      complete(state.provider.requests[1],symbols(state))
      state.controller:set_order('name')
      state.session.breadcrumbs_enabled=false
      state.view.expanded.zoo=false
      state.view.selected_id='alpha'
      state.view:render()
      state.view:close()
      local status=state.controller:status()
      assert(status.session_count==0 and status.request_count==0 and status.watcher_count==0 and not status.observer_active)
      local view=assert(state.controller:open({focus=false}))
      local session=state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      assert(session.order=='name' and session.breadcrumbs_enabled==false)
      complete(state.provider.requests[#state.provider.requests],symbols(state))
      assert(view.selected_id=='alpha' and view.expanded.zoo==false)
      state.controller:set_filter('Zoo')
      view:close()
      view=assert(state.controller:open({focus=false}))
      session=state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      assert(session.filter=='Zoo')
      local request=state.provider.requests[#state.provider.requests]
      view:close()
      complete(request,symbols(state,'stale-'))
      view=assert(state.controller:open({focus=false}))
      session=state.controller.sessions[vim.api.nvim_get_current_tabpage()]
      assert(session.filter=='Zoo')
      complete(state.provider.requests[#state.provider.requests],symbols(state))
      view:close()
      assert(#state.controller.view_state_order==1)
      state.controller:forget_tab(vim.api.nvim_get_current_tabpage())
      assert(next(state.controller.view_states)==nil)
      for index=1,18 do
        vim.api.nvim_buf_set_name(state.buffer,state.path..'-'..index)
        view=assert(state.controller:open({focus=false}))
        view:close()
      end
      assert(#state.controller.view_state_order==16)
      dispose(state)
      assert(next(state.controller.view_states)==nil)
      return true
    ]])
    expect.equality(result,true)
  end,

  ["nested symbols share one snapshot for ordering filter active symbol and breadcrumbs"] = function()
    local result = evaluate(helpers .. [[
      local state = setup(true)
      local request = state.provider.requests[1]
      assert(request and request.options.method == 'textDocument/documentSymbol')
      assert(request.options.generation == 1 and request.options.session_id == state.session.id)
      complete(request, symbols(state))

      local initial = {}
      for _, row in ipairs(state.view.rows) do initial[#initial + 1] = row.id end
      local initial_nested = initial[1] == 'zoo' and initial[2] == 'inner'
      local initial_selection = state.view.selected_id
      state.controller:set_order('name')
      local by_name = {}
      for _, row in ipairs(state.view.rows) do by_name[#by_name + 1] = row.id end
      local name_order = by_name[1] == 'alpha' and by_name[2] == 'zoo' and by_name[3] == 'inner'
      state.controller:set_filter('inner')
      local filtered = {}
      for _, row in ipairs(state.view.rows) do filtered[#filtered + 1] = row.id end
      local ancestor_kept = #filtered == 2 and filtered[1] == 'zoo' and filtered[2] == 'inner'
      state.controller:set_filter('')
      state.controller:set_order('source')

      state.view.selected_id = 'alpha'
      local header_before = #state.view.model.header
      local full_updates, dynamic_updates = 0, 0
      local update, update_dynamic = state.view.update, state.view.update_dynamic
      state.view.update = function(self, ...) full_updates = full_updates + 1; return update(self, ...) end
      state.view.update_dynamic = function(self, ...) dynamic_updates = dynamic_updates + 1; return update_dynamic(self, ...) end
      vim.api.nvim_win_set_cursor(state.session.editor_window, { 2, 8 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = state.buffer })
      local active = state.session.active_id
      local breadcrumb = state.session.breadcrumbs[1] and state.session.breadcrumbs[1].label .. ' › ' .. state.session.breadcrumbs[2].label
      local selection_independent = state.view.selected_id == 'alpha'
      local ns = vim.api.nvim_get_namespaces()['workbench.ui.view']
      local active_highlight, selected_highlight
      local marks = vim.api.nvim_buf_get_extmarks(state.view.buffer, ns, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        local line = mark[2] + 1
        if line == state.view.visible_row_lines.inner then active_highlight = mark[4].hl_group end
        if line == state.view.visible_row_lines.alpha then selected_highlight = mark[4].hl_group end
      end
      local one_request = #state.provider.requests == 1
      local header = table.concat(state.view.model.header or {}, '\n')
      local breadcrumb_projected = header:find('Breadcrumbs: Zoo › inner', 1, true) ~= nil
      local result = { initial_nested = initial_nested, initial_selection = initial_selection,
        name_order = name_order, ancestor_kept = ancestor_kept, active = active,
        breadcrumb = breadcrumb, selection_independent = selection_independent,
        one_request = one_request, breadcrumb_projected = breadcrumb_projected,
        dynamic_updates = dynamic_updates, full_updates = full_updates,
        header_before = header_before, header_after = #state.view.model.header,
        active_highlight = active_highlight, selected_highlight = selected_highlight }
      dispose(state)
      return result
    ]])
    expect.equality(result.initial_nested, true)
    expect.equality(result.initial_selection, "zoo")
    expect.equality(result.name_order, true)
    expect.equality(result.ancestor_kept, true)
    expect.equality(result.active, "inner")
    expect.equality(result.breadcrumb, "Zoo › inner")
    expect.equality(result.selection_independent, true)
    expect.equality(result.one_request, true)
    expect.equality(result.breadcrumb_projected, true)
    expect.equality(result.dynamic_updates, 1)
    expect.equality(result.full_updates, 0)
    expect.equality(result.active_highlight, "WorkbenchEnclosingSymbol")
    expect.equality(result.selected_highlight, "WorkbenchSelection")
  end,

  ["unavailable capability is precise and LSP attach refreshes the visible outline"] = function()
    local result = evaluate(helpers .. [[
      local state = setup(false)
      local unavailable = state.view.model.reason
      local initial_calls = #state.provider.requests
      state.provider.available = true
      vim.api.nvim_exec_autocmds('LspAttach', { buffer = state.buffer, data = { client_id = 7 } })
      assert(vim.wait(1000, function() return #state.provider.requests == 1 end, 5))
      local request = state.provider.requests[1]
      complete(request, symbols(state))
      local ready = state.session.status == 'ready' and #state.view.rows == 3
      dispose(state)
      return { unavailable = unavailable, initial_calls = initial_calls, ready = ready }
    ]])
    expect.equality(result.unavailable, "No attached language server supports document symbols")
    expect.equality(result.initial_calls, 0)
    expect.equality(result.ready, true)
  end,

  ["source edits cancel pending work reject stale replies and dispose only owned observers"] = function()
    local result = evaluate(helpers .. [[
      local state = setup(true)
      local foreign_group = vim.api.nvim_create_augroup('OutlineForeignWatcher', { clear = true })
      vim.api.nvim_create_autocmd('TextChanged', { group = foreign_group, buffer = state.buffer, callback = function() end })
      local old_request = state.provider.requests[1]
      assert(old_request.options.is_current())
      vim.api.nvim_buf_set_lines(state.buffer, 0, 1, false, { 'local New = {}' })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = state.buffer })
      assert(old_request.cancelled == 'document_changed')
      assert(vim.wait(1500, function() return #state.provider.requests == 2 end, 5))
      local fresh = state.provider.requests[2]
      local generation_advanced = fresh.options.generation > old_request.options.generation
      local stale_guard = old_request.options.is_current() == false
      complete(old_request, symbols(state, 'stale-'))
      local no_stale_items = #state.session.items == 0
      complete(fresh, symbols(state, 'fresh-'))
      local fresh_won = state.session.status == 'ready' and state.view.rows[1].id == 'fresh-zoo'
      local selected_before_close = state.view.selected_id
      state.view:close()
      local closed = state.controller:status()
      local foreign_preserved = #vim.api.nvim_get_autocmds({ group = foreign_group, event = 'TextChanged', buffer = state.buffer }) == 1
      local clean = closed.session_count == 0 and not closed.observer_active and closed.watcher_count == 0 and closed.request_count == 0
      dispose(state)
      return { generation_advanced = generation_advanced, stale_guard = stale_guard,
        no_stale_items = no_stale_items, fresh_won = fresh_won,
        selection_before_close = selected_before_close, clean = clean, foreign_preserved = foreign_preserved }
    ]])
    expect.equality(result.generation_advanced, true)
    expect.equality(result.stale_guard, true)
    expect.equality(result.no_stale_items, true)
    expect.equality(result.fresh_won, true)
    expect.equality(result.selection_before_close, "fresh-zoo")
    expect.equality(result.clean, true)
    expect.equality(result.foreign_preserved, true)
  end,

  ["flat repeated symbols remain distinct and crossing ranges retain exact scan behavior"] = function()
    local result = evaluate([[
      local Outline = require('workbench.ui.outline')
      local items = {
        { id = 'flat-a', label = 'Repeat', payload = { source_order = 1, source_range_bytes = { start = { line = 0, character = 0 }, finish = { line = 0, character = 10 } } } },
        { id = 'flat-b', label = 'Repeat', payload = { source_order = 2, source_range_bytes = { start = { line = 0, character = 5 }, finish = { line = 0, character = 15 } } } },
      }
      local index = assert(Outline.build_enclosing_index(items))
      local projected = assert(Outline.project(items, { filter = 'repeat', status = 'ready' }))
      return { count = #projected.items, first = projected.items[1].id, second = projected.items[2].id,
        indexed = index.indexed, laminar = index.laminar, overlap_choice = Outline.enclosing(items, 0, 7, index) }
    ]])
    expect.equality(result.count, 2)
    expect.equality(result.first, "flat-a")
    expect.equality(result.second, "flat-b")
    expect.equality(result.indexed, true)
    expect.equality(result.laminar, false)
    expect.equality(result.overlap_choice, "flat-a")
  end,

  ["Outline follows the last real editor buffer and cancels pending work on close"] = function()
    local result = evaluate(helpers .. [[
      local state = setup(true)
      local first_buffer = state.buffer
      local first_request = state.provider.requests[1]
      local foreign_group = vim.api.nvim_create_augroup('OutlineForeignAcrossBufferSwitch', { clear = true })
      vim.api.nvim_create_autocmd('BufEnter', { group = foreign_group, buffer = first_buffer, callback = function() end })
      vim.api.nvim_set_current_win(state.view.window)
      local sidebar_ignored = state.session.buffer == first_buffer
      vim.api.nvim_set_current_win(state.session.editor_window)
      local second_path = vim.fn.tempname() .. '-outline-second.lua'
      assert(vim.fn.writefile({ 'local Second = {}', 'function duplicate() end' }, second_path) == 0)
      vim.api.nvim_cmd({ cmd = 'edit', args = { second_path } }, {})
      local second_buffer = vim.api.nvim_get_current_buf()
      assert(vim.wait(1000, function() return #state.provider.requests == 2 end, 5))
      local second_request = state.provider.requests[2]
      local followed = state.session.buffer == second_buffer and second_request.options.bufnr == second_buffer
      local first_cancelled = first_request.cancelled == 'cancelled'
      state.path = second_path
      vim.api.nvim_set_current_win(state.view.window)
      local sidebar_still_ignored = state.session.buffer == second_buffer
      state.view:close()
      local close_status = state.controller:status()
      local second_cancelled = second_request.cancelled == 'cancelled'
      complete(second_request, symbols(state, 'late-'))
      local foreign_preserved = #vim.api.nvim_get_autocmds({ group = foreign_group, event = 'BufEnter', buffer = first_buffer }) == 1
      local clean = close_status.session_count == 0 and not close_status.observer_active
        and close_status.watcher_count == 0 and close_status.request_count == 0
      dispose(state)
      return { sidebar_ignored = sidebar_ignored, sidebar_still_ignored = sidebar_still_ignored,
        followed = followed, first_cancelled = first_cancelled, second_cancelled = second_cancelled,
        foreign_preserved = foreign_preserved, clean = clean }
    ]])
    expect.equality(result.sidebar_ignored, true)
    expect.equality(result.sidebar_still_ignored, true)
    expect.equality(result.followed, true)
    expect.equality(result.first_cancelled, true)
    expect.equality(result.second_cancelled, true)
    expect.equality(result.foreign_preserved, true)
    expect.equality(result.clean, true)
  end,
})
