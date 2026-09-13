local Scope = require("workbench.core.scope")
local Location = require("workbench.core.location")
local OutlineUi = require("workbench.ui.outline")

local M = {}
local Controller = {}
Controller.__index = Controller

local METHOD = "textDocument/documentSymbol"
local DEBOUNCE_MS = 80
local MAX_CACHED_BUFFERS = 4
local MAX_SAVED_VIEWS = 16
local next_controller_id = 0

local function error_value(code, message)
  return { code = code, message = message }
end

local function real_buffer(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr)
    or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  return vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function current_editor(tab)
  if tab == vim.api.nvim_get_current_tabpage() then
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    if real_buffer(buf) then return buf, win end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if real_buffer(buf) then return buf, win end
  end
end

local function raw_range(item, prefer_symbol)
  local payload = item.payload or {}
  if prefer_symbol and type(payload.symbol_range) == "table" then
    local range = payload.symbol_range
    return { start = range.start, finish = range.finish or range["end"] }
  end
  local range = item.location and item.location.range
  if type(range) ~= "table" then return nil end
  return { start = range.start, finish = range.finish or range["end"] }
end

local function resolve_range(bufnr, item, prefer_symbol, line_cache)
  local range = raw_range(item, prefer_symbol)
  local location = item.location
  if not range or not location or not location.encoding then return nil end
  local range_location = Location.new(location.resource, {
    range = range,
    encoding = location.encoding,
    client_id = location.client_id,
    version = location.version,
  })
  if not range_location then return nil end
  local lines = {}
  for _, position in ipairs({ range.start, range.finish }) do
    if type(position) ~= "table" or type(position.line) ~= "number" then return nil end
    local line = line_cache[position.line]
    if line == nil then
      local values = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)
      if #values == 0 then return nil end
      line = values[1]
      line_cache[position.line] = line
    end
    lines[position.line + 1] = line
  end
  return Location.resolve_range(range_location, lines)
end

local function stable_range_key(range)
  if not range then return nil end
  return table.concat({
    tostring(range.start.line), tostring(range.start.character),
    tostring(range.finish.line), tostring(range.finish.character),
  }, ":")
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then
    return nil, error_value("invalid_dependency", "Outline controller requires a native layout manager")
  end
  if type(deps.provider) ~= "table" or type(deps.provider.capabilities) ~= "function"
    or type(deps.provider.start) ~= "function" then
    return nil, error_value("invalid_dependency", "Outline controller requires an LSP discovery provider")
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.open) ~= "function" then
    return nil, error_value("invalid_dependency", "Outline controller requires the shared navigation service")
  end
  next_controller_id = next_controller_id + 1
  return setmetatable({
    id = next_controller_id,
    layout = deps.layout,
    provider = deps.provider,
    navigation = deps.navigation,
    scope = Scope.new("workbench-outline-controller:" .. next_controller_id),
    sessions = {},
    requests = {},
    snapshots = {},
    view_states = {},
    view_state_order = {},
    snapshot_clock = 0,
    next_session_id = 0,
    buffer_watchers = {},
    observer_handle = nil,
    observer_group = nil,
    disposed = false,
  }, Controller)
end

function Controller:_model(session)
  return OutlineUi.project(session.items, {
    status = session.status,
    reason = session.reason,
    error = session.error,
    partial_message = session.partial_message,
    filter = session.filter,
    order = session.order,
    active_id = session.active_id,
    breadcrumbs = session.breadcrumbs,
    breadcrumbs_enabled = session.breadcrumbs_enabled,
  })
end

local function view_state_key(session, bufnr)
  if not real_buffer(bufnr) then return nil end
  return tostring(session.tab) .. "\0" .. (session.workspace and session.workspace.id or "")
    .. "\0" .. vim.api.nvim_buf_get_name(bufnr)
end

function Controller:_remember_view(session)
  local key = view_state_key(session, session.buffer)
  if self.disposed or not key or not session.view or not vim.api.nvim_tabpage_is_valid(session.tab) then return end
  local view = session.view
  local state = {
    tab = session.tab, filter = session.filter, order = session.order,
    breadcrumbs = session.breadcrumbs_enabled, selected_id = view.selected_id,
    expanded = vim.deepcopy(view.expanded), scroll_offset = view.scroll_offset,
  }
  if session.restore_state then
    state.selected_id = session.restore_state.selected_id
    state.expanded = vim.deepcopy(session.restore_state.expanded)
    state.scroll_offset = session.restore_state.scroll_offset
  end
  for index, saved_key in ipairs(self.view_state_order) do
    if saved_key == key then table.remove(self.view_state_order, index); break end
  end
  self.view_states[key] = state
  self.view_state_order[#self.view_state_order + 1] = key
  while #self.view_state_order > MAX_SAVED_VIEWS do self.view_states[table.remove(self.view_state_order, 1)] = nil end
end

function Controller:forget_tab(tab)
  for index = #self.view_state_order, 1, -1 do
    local key = self.view_state_order[index]
    if self.view_states[key].tab == tab then
      self.view_states[key] = nil
      table.remove(self.view_state_order, index)
    end
  end
end

function Controller:_restore_view(session, bufnr)
  local key = view_state_key(session, bufnr)
  local state = key and self.view_states[key]
  session.restore_state = state and vim.deepcopy(state) or nil
  if state then
    session.filter, session.order = state.filter, state.order
    session.breadcrumbs_enabled = state.breadcrumbs
  else
    session.filter, session.order, session.breadcrumbs_enabled = "", "source", true
  end
end

function Controller:_update(session, immediate)
  if not session.view or session.view.closed then return false end
  local model, err = self:_model(session)
  if not model then return nil, error_value("projection_error", err) end
  if session.restore_state and session.status == "ready" then
    local state = session.restore_state
    session.view.selected_id = state.selected_id
    session.view.expanded = vim.deepcopy(state.expanded)
    session.view.scroll_offset = state.scroll_offset
    session.restore_state = nil
  end
  if immediate then return session.view:update(model) end
  return session.view:render_later(model)
end

function Controller:_update_dynamic(session)
  if not session.view or session.view.closed then return false end
  local header = OutlineUi.header({
    breadcrumbs = session.breadcrumbs,
    breadcrumbs_enabled = session.breadcrumbs_enabled,
    partial_message = session.partial_message,
  })
  return session.view:update_dynamic(session.active_id, header)
end

function Controller:_ensure_observer()
  if self.observer_handle then return true end
  if self.disposed or not self.scope.alive then return nil, error_value("controller_disposed", "Outline controller is disposed") end
  local group = vim.api.nvim_create_augroup("WorkbenchOutlineObserver" .. self.id, { clear = true })
  local ok, failure = pcall(function()
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
      group = group,
      callback = function(event) self:_on_editor_event(event) end,
    })
    vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
      group = group,
      callback = function(event) self:_on_lsp_event(event) end,
    })
  end)
  if not ok then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return nil, error_value("observer_setup_failed", tostring(failure))
  end
  local handle, err = self.scope:defer(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if self.observer_group == group then self.observer_group = nil end
  end, "outline-visible-buffer-observer", "autocmd")
  if not handle then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return nil, err
  end
  self.observer_group = group
  self.observer_handle = handle
  return true
end

function Controller:_release_observer_if_idle()
  if next(self.sessions) ~= nil or not self.observer_handle then return false end
  local handle = self.observer_handle
  self.observer_handle = nil
  handle:dispose()
  return true
end

function Controller:_watch_buffer(session, bufnr)
  local watcher = self.buffer_watchers[bufnr]
  if not watcher then
    local scope, scope_err = self.scope:child("buffer:" .. bufnr)
    if not scope then return nil, scope_err end
    local uv = vim.uv or vim.loop
    local timer_ok, timer = pcall(uv.new_timer)
    if not timer_ok or not timer then
      scope:dispose()
      return nil, error_value("timer_unavailable", tostring(timer or "could not create Outline debounce timer"))
    end
    local _, timer_err = scope:defer(function()
      pcall(timer.stop, timer)
      if not timer:is_closing() then timer:close() end
    end, "outline-edit-debounce:" .. bufnr, "timer")
    if timer_err then
      pcall(timer.close, timer)
      scope:dispose()
      return nil, timer_err
    end

    local group = vim.api.nvim_create_augroup("WorkbenchOutlineBuffer" .. self.id .. "_" .. bufnr, { clear = true })
    local ok, failure = pcall(function()
      vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        buffer = bufnr,
        callback = function() self:_on_cursor_moved(bufnr) end,
      })
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = bufnr,
        callback = function() self:_on_text_changed(bufnr) end,
      })
      vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        buffer = bufnr,
        callback = function() self:_on_buffer_wipeout(bufnr) end,
      })
    end)
    if not ok then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      scope:dispose()
      return nil, error_value("buffer_watch_failed", tostring(failure))
    end
    local _, group_err = scope:defer(function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
      "outline-buffer-events:" .. bufnr, "autocmd")
    if group_err then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      scope:dispose()
      return nil, group_err
    end
    watcher = { bufnr = bufnr, scope = scope, timer = timer, sessions = {} }
    self.buffer_watchers[bufnr] = watcher
  end
  watcher.sessions[session] = true
  session.watched_buffer = bufnr
  return true
end

function Controller:_unwatch_buffer(session)
  local bufnr = session.watched_buffer
  if not bufnr then return false end
  session.watched_buffer = nil
  local watcher = self.buffer_watchers[bufnr]
  if not watcher then return false end
  watcher.sessions[session] = nil
  if next(watcher.sessions) == nil then
    self.buffer_watchers[bufnr] = nil
    watcher.scope:dispose()
  end
  return true
end

function Controller:_unsubscribe(session, reason)
  local key = session.request_key
  if not key then return false end
  session.request_key = nil
  local entry = self.requests[key]
  if not entry then return false end
  entry.sessions[session] = nil
  if next(entry.sessions) == nil then
    self.requests[key] = nil
    if entry.handle and entry.handle:is_active() then entry.handle:cancel(reason or "cancelled") end
  end
  return true
end

function Controller:_invalidate_buffer(bufnr, reason)
  self.snapshots[bufnr] = nil
  local pending = {}
  for key, entry in pairs(self.requests) do
    if entry.bufnr == bufnr then pending[#pending + 1] = { key = key, entry = entry } end
  end
  for _, pair in ipairs(pending) do
    local entry = pair.entry
    self.requests[pair.key] = nil
    for session in pairs(entry.sessions) do
      entry.sessions[session] = nil
      if session.request_key == pair.key then session.request_key = nil end
    end
    if entry.handle and entry.handle:is_active() then entry.handle:cancel(reason or "document_changed") end
  end
end

function Controller:_on_text_changed(bufnr)
  local watcher = self.buffer_watchers[bufnr]
  if not watcher or self.disposed then return end
  self:_invalidate_buffer(bufnr, "document_changed")
  for session in pairs(watcher.sessions) do
    session.items = {}
    session.range_index = nil
    session.active_id = nil
    session.breadcrumbs = {}
    session.status = "loading"
    session.reason = nil
    session.error = nil
    session.partial_message = nil
    self:_update(session, true)
  end
  pcall(watcher.timer.stop, watcher.timer)
  local started = pcall(watcher.timer.start, watcher.timer, DEBOUNCE_MS, 0, function()
    watcher.scope:schedule(function()
      if self.disposed or self.buffer_watchers[bufnr] ~= watcher then return end
      for session in pairs(watcher.sessions) do
        if session.buffer == bufnr and not session.disposed then self:_request_snapshot(session, true) end
      end
    end)
  end)
  if not started then
    watcher.scope:schedule(function()
      for session in pairs(watcher.sessions) do if session.buffer == bufnr then self:_request_snapshot(session, true) end end
    end)
  end
end

function Controller:_on_buffer_wipeout(bufnr)
  local watcher = self.buffer_watchers[bufnr]
  if not watcher then return end
  self:_invalidate_buffer(bufnr, "buffer_closed")
  local sessions = {}
  for session in pairs(watcher.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    self:_unwatch_buffer(session)
    if session.buffer == bufnr then
      session.buffer = nil
      session.editor_window = nil
      session.document_version = nil
      session.items = {}
      session.range_index = nil
      session.active_id = nil
      session.breadcrumbs = {}
      session.status = "unavailable"
      session.reason = "source buffer was closed"
      self:_update(session, true)
    end
  end
end

function Controller:_on_cursor_moved(bufnr)
  local watcher = self.buffer_watchers[bufnr]
  if not watcher or self.disposed then return end
  for session in pairs(watcher.sessions) do
    local win = session.editor_window
    if session.view and session.buffer == bufnr and win and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == bufnr then
      local cursor = vim.api.nvim_win_get_cursor(win)
      local active_id = OutlineUi.enclosing(session.items, cursor[1] - 1, cursor[2], session.range_index)
      if active_id ~= session.active_id then
        session.active_id = active_id
        session.breadcrumbs = OutlineUi.breadcrumbs(session.items, active_id, session.range_index)
        self:_update_dynamic(session)
      end
    end
  end
end

function Controller:_on_editor_event(event)
  if self.disposed or not self.observer_handle or next(self.sessions) == nil then return end
  local tab = vim.api.nvim_get_current_tabpage()
  local session = self.sessions[tab]
  if not session or session.disposed then return end
  local win = vim.api.nvim_get_current_win()
  local bufnr = event.event == "BufEnter" and event.buf or vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr or not real_buffer(bufnr) then return end
  if session.buffer ~= bufnr or session.editor_window ~= win then self:_track_editor_buffer(session, bufnr, win) end
end

function Controller:_on_lsp_event(event)
  if self.disposed or type(event.buf) ~= "number" then return end
  local watcher = self.buffer_watchers[event.buf]
  if not watcher then return end
  self:_invalidate_buffer(event.buf, "cancelled")
  for session in pairs(watcher.sessions) do
    session.status = "loading"
    session.reason = nil
    session.items = {}
    session.range_index = nil
    session.active_id = nil
    session.breadcrumbs = {}
    session.partial_message = nil
    self:_update(session, true)
  end
  local tick = watcher.scope:schedule(function()
    if self.buffer_watchers[event.buf] ~= watcher then return end
    for session in pairs(watcher.sessions) do if not session.disposed then self:_request_snapshot(session, true) end end
  end)
  if not tick then
    for session in pairs(watcher.sessions) do session.status = "unavailable"; session.reason = "Outline refresh was disposed"; self:_update(session, true) end
  end
end

function Controller:_track_editor_buffer(session, bufnr, win)
  if session.buffer == bufnr then
    session.editor_window = win
    if session.document_version ~= vim.api.nvim_buf_get_changedtick(bufnr) then self:_request_snapshot(session, false) end
    self:_on_cursor_moved(bufnr)
    return true
  end
  self:_remember_view(session)
  self:_restore_view(session, bufnr)
  self:_unsubscribe(session, "cancelled")
  self:_unwatch_buffer(session)
  session.buffer = bufnr
  session.editor_window = win
  session.document_version = vim.api.nvim_buf_get_changedtick(bufnr)
  session.items = {}
  session.range_index = nil
  session.active_id = nil
  session.breadcrumbs = {}
  session.status = "loading"
  session.reason = nil
  session.error = nil
  session.partial_message = nil
  local watched, watch_error = self:_watch_buffer(session, bufnr)
  if not watched then
    session.status = "error"
    session.error = watch_error
    return self:_update(session, true)
  end
  self:_update(session, true)
  return self:_request_snapshot(session, false)
end

local function prepare_item(bufnr, item, source_order, line_cache)
  local copy = vim.tbl_extend("force", {}, item)
  copy.payload = vim.tbl_extend("force", {}, item.payload or {})
  copy.payload.source_order = source_order
  copy.payload.selection_range_bytes = resolve_range(bufnr, copy, false, line_cache)
  copy.payload.source_range_bytes = resolve_range(bufnr, copy, true, line_cache)
  return copy
end

local function semantic_key(item)
  local payload = item.payload or {}
  local range = stable_range_key(payload.selection_range_bytes)
  if not range then return nil end
  return table.concat({
    item.location and item.location.resource and item.location.resource.uri or "",
    item.label or "",
    tostring(payload.symbol_kind or ""),
    payload.container_name or "",
    range,
  }, "\0")
end

function Controller:_collect_items(entry)
  local client_ids = {}
  for id in pairs(entry.items_by_client) do client_ids[#client_ids + 1] = id end
  table.sort(client_ids)
  local line_cache, items, seen, id_map = {}, {}, {}, {}
  local source_order = 0
  for _, id in ipairs(client_ids) do
    for _, raw in ipairs(entry.items_by_client[id]) do
      source_order = source_order + 1
      local item = prepare_item(entry.bufnr, raw, source_order, line_cache)
      local key = semantic_key(item)
      local existing = key and seen[key]
      if existing then
        id_map[raw.id] = existing.id
      else
        if item.parent_id then item.parent_id = id_map[item.parent_id] or item.parent_id end
        items[#items + 1] = item
        if key then seen[key] = item end
        id_map[raw.id] = item.id
      end
    end
  end
  return items
end

function Controller:_remember_snapshot(bufnr, version, workspace_id, workspace_generation, items, partial_message, range_index)
  self.snapshot_clock = self.snapshot_clock + 1
  self.snapshots[bufnr] = {
    version = version,
    workspace_id = workspace_id,
    workspace_generation = workspace_generation,
    items = items,
    partial_message = partial_message,
    range_index = range_index,
    used = self.snapshot_clock,
  }
  local count, oldest_buf, oldest_used = 0, nil, math.huge
  for key, snapshot in pairs(self.snapshots) do
    count = count + 1
    if snapshot.used < oldest_used then oldest_buf, oldest_used = key, snapshot.used end
  end
  if count > MAX_CACHED_BUFFERS and oldest_buf then self.snapshots[oldest_buf] = nil end
end

local function partial_message(done)
  local clients = done.error and done.error.clients or {}
  local first = clients[1]
  if first then return first.message or first.code end
  return done.error and done.error.message or nil
end

function Controller:_finish_entry(key, entry, done)
  if self.requests[key] ~= entry then return end
  self.requests[key] = nil
  local current = vim.api.nvim_buf_is_valid(entry.bufnr)
    and vim.api.nvim_buf_get_changedtick(entry.bufnr) == entry.document_version
  local items = current and self:_collect_items(entry) or {}
  local range_index = current and OutlineUi.build_enclosing_index(items) or nil
  local partial = done.status == "partial" and partial_message(done) or nil
  if current and done.status ~= "cancelled" and done.status ~= "error" then
    self:_remember_snapshot(entry.bufnr, entry.document_version, entry.workspace_id,
      entry.workspace_generation, items, partial, range_index)
  end
  local sessions = {}
  for session in pairs(entry.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    entry.sessions[session] = nil
    if session.request_key == key then session.request_key = nil end
    if session.disposed or not session.view or session.buffer ~= entry.bufnr
      or session.document_version ~= entry.document_version then
      -- A closed/retargeted session never accepts an old snapshot.
    elseif not current then
      session.status = "loading"
      session.items = {}
      session.range_index = nil
      self:_update(session, true)
    elseif done.status == "complete" or (done.status == "partial" and #items > 0) then
      session.items = items
      session.range_index = range_index
      session.status = "ready"
      session.reason = nil
      session.error = nil
      session.partial_message = partial
      local cursor = { 1, 0 }
      local win = session.editor_window
      if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == session.buffer then
        local ok, position = pcall(vim.api.nvim_win_get_cursor, win)
        if ok then cursor = position end
      end
      session.active_id = OutlineUi.enclosing(items, cursor[1] - 1, cursor[2], range_index)
      session.breadcrumbs = OutlineUi.breadcrumbs(items, session.active_id, range_index)
      self:_update(session, true)
    elseif done.status == "error" then
      session.items = {}
      session.range_index = nil
      session.status = "error"
      session.error = done.error or error_value("lsp_error", "document symbols could not be loaded")
      self:_update(session, true)
    else
      session.items = items
      session.range_index = range_index
      session.status = "unavailable"
      session.reason = done.error and done.error.message or "document-symbol request was cancelled"
      self:_update(session, true)
    end
  end
end

function Controller:_request_snapshot(session, force)
  if self.disposed or session.disposed or not session.view then return nil, error_value("session_disposed", "Outline session is closed") end
  local bufnr = session.buffer
  if not real_buffer(bufnr) then
    session.items = {}
    session.range_index = nil
    session.active_id = nil
    session.breadcrumbs = {}
    session.status = "unavailable"
    session.reason = "no named editor buffer is active"
    return self:_update(session, true)
  end
  local version = vim.api.nvim_buf_get_changedtick(bufnr)
  session.document_version = version
  local workspace_id = type(session.workspace) == "table" and session.workspace.id or ""
  local workspace_generation = session.workspace_generation or 0
  local key = table.concat({ tostring(bufnr), tostring(version), tostring(workspace_id), tostring(workspace_generation) }, ":")
  if session.snapshot_key ~= key then self:_unsubscribe(session, "cancelled") end
  session.snapshot_key = key

  local snapshot = self.snapshots[bufnr]
  if not force and snapshot and snapshot.version == version
    and snapshot.workspace_id == workspace_id and snapshot.workspace_generation == workspace_generation then
    self.snapshot_clock = self.snapshot_clock + 1
    snapshot.used = self.snapshot_clock
    session.items = snapshot.items
    session.range_index = snapshot.range_index
    session.partial_message = snapshot.partial_message
    session.status = "ready"
    session.reason = nil
    session.error = nil
    local cursor = { 1, 0 }
    local win = session.editor_window
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      local ok, position = pcall(vim.api.nvim_win_get_cursor, win)
      if ok then cursor = position end
    end
    session.active_id = OutlineUi.enclosing(session.items, cursor[1] - 1, cursor[2], session.range_index)
    session.breadcrumbs = OutlineUi.breadcrumbs(session.items, session.active_id, session.range_index)
    return self:_update(session, true)
  end

  local capability = self.provider:capabilities({ bufnr = bufnr, method = METHOD })
  if capability.state ~= "ready" then
    session.items = {}
    session.range_index = nil
    session.active_id = nil
    session.breadcrumbs = {}
    session.partial_message = nil
    session.status = "unavailable"
    session.reason = capability.reason or capability.code or "document symbols are unavailable"
    session.error = capability.state == "error" and capability or nil
    return self:_update(session, true)
  end

  local existing = self.requests[key]
  if existing then
    existing.sessions[session] = true
    session.request_key = key
    session.status = "loading"
    session.reason = nil
    session.error = nil
    return self:_update(session, true)
  end

  session.status = "loading"
  session.reason = nil
  session.error = nil
  session.items = {}
  session.range_index = nil
  session.active_id = nil
  session.breadcrumbs = {}
  session.partial_message = nil
  self:_update(session, true)
  session.request_generation = session.request_generation + 1
  local request_generation = session.request_generation
  local entry = {
    key = key,
    bufnr = bufnr,
    document_version = version,
    workspace_id = workspace_id,
    workspace_generation = workspace_generation,
    generation = request_generation,
    sessions = { [session] = true },
    items_by_client = {},
    handle = nil,
  }
  self.requests[key] = entry
  session.request_key = key
  local request, request_error = self.provider:start({
    bufnr = bufnr,
    method = METHOD,
    params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
    workspace = session.workspace,
    workspace_generation = session.workspace_generation,
    generation = request_generation,
    session_id = session.id,
    is_current = function()
      return self.requests[key] == entry and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == version
        and session.workspace_generation == entry.workspace_generation
        and session.request_generation == entry.generation
    end,
  }, function(event)
    if self.disposed or self.requests[key] ~= entry then return end
    if event.kind == "batch" then
      local items = entry.items_by_client[event.client_id]
      if not items then items = {}; entry.items_by_client[event.client_id] = items end
      for _, item in ipairs(event.items) do items[#items + 1] = item end
    elseif event.kind == "done" then
      self:_finish_entry(key, entry, event)
    end
  end)
  if not request then
    self.requests[key] = nil
    entry.sessions = {}
    session.request_key = nil
    session.status = "error"
    session.error = request_error
    return self:_update(session, true)
  end
  entry.handle = request
  return request
end

function Controller:_close_session(session)
  if session.disposed then return false end
  self:_remember_view(session)
  session.disposed = true
  self:_unsubscribe(session, "cancelled")
  self:_unwatch_buffer(session)
  if self.sessions[session.tab] == session then self.sessions[session.tab] = nil end
  session.view = nil
  self:_release_observer_if_idle()
  if next(self.sessions) == nil then self.snapshots = {} end
  return true
end

function Controller:_keymaps(session)
  return {
    ["/"] = {
      desc = "Workbench Outline: filter loaded symbols",
      run = function()
        vim.ui.input({ prompt = "Filter Outline symbols: " }, function(value)
          if value ~= nil then self:set_filter(value, session.tab) end
        end)
      end,
    },
    o = { desc = "Workbench Outline: toggle symbol order", run = function()
      self:set_order(session.order == "source" and "name" or "source", session.tab)
    end },
    b = { desc = "Workbench Outline: toggle breadcrumbs", run = function()
      session.breadcrumbs_enabled = not session.breadcrumbs_enabled
      self:_update(session, true)
    end },
  }
end

function Controller:open(opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, error_value("controller_disposed", "Outline controller is disposed") end
  local tab = opts.tabpage or vim.api.nvim_get_current_tabpage()
  if tab ~= vim.api.nvim_get_current_tabpage() then
    return nil, error_value("tab_not_current", "Outline can only be mounted in the current tab")
  end
  local existing = self.sessions[tab]
  local replacing = existing and existing.view and not existing.view.closed
    and not vim.deep_equal(existing.workspace, opts.workspace)
  if existing and existing.view and not existing.view.closed and not replacing then
    if opts.focus ~= false and existing.view.window and vim.api.nvim_win_is_valid(existing.view.window) then
      vim.api.nvim_set_current_win(existing.view.window)
    end
    return existing.view
  end

  local bufnr, win = opts.bufnr, nil
  if bufnr and not real_buffer(bufnr) then return nil, error_value("invalid_buffer", "Outline requires a named real editor buffer") end
  if bufnr then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(candidate) == bufnr then win = candidate; break end
    end
  else
    bufnr, win = current_editor(tab)
  end

  local scope, scope_err = self.scope:child("tab:" .. tostring(tab))
  if not scope then return nil, scope_err end
  self.next_session_id = self.next_session_id + 1
  local session = {
    id = "outline:" .. self.id .. ":" .. tostring(tab) .. ":" .. self.next_session_id,
    tab = tab,
    scope = scope,
    buffer = nil,
    editor_window = nil,
    watched_buffer = nil,
    document_version = nil,
    workspace = opts.workspace,
    workspace_generation = type(opts.workspace) == "table" and opts.workspace.generation or 0,
    request_generation = 0,
    request_key = nil,
    snapshot_key = nil,
    items = {},
    active_id = nil,
    breadcrumbs = {},
    breadcrumbs_enabled = opts.breadcrumbs ~= false,
    filter = "",
    order = opts.order == "name" and "name" or "source",
    status = bufnr and "loading" or "unavailable",
    reason = bufnr and nil or "no named editor buffer is active",
    partial_message = nil,
    view = nil,
    disposed = false,
  }
  local _, cleanup_error = scope:defer(function() self:_close_session(session) end,
    "outline-session:" .. session.id, "session")
  if cleanup_error then scope:dispose(); return nil, cleanup_error end
  self.sessions[tab] = session
  self:_restore_view(session, bufnr)
  if opts.order ~= nil then session.order = opts.order == "name" and "name" or "source" end
  if opts.breadcrumbs ~= nil then session.breadcrumbs_enabled = opts.breadcrumbs ~= false end

  local view, view_error = self.layout:mount({
    id = opts.view_id or "outline",
    replace = replacing and true or false,
    title = "Outline",
    kind = "tree",
    placement = "sidebar",
    focus = opts.focus ~= false,
    help_lines = {
      "j/k move; Enter opens symbol; Space/l expand; h/Left parent",
      "/ filters symbols; o toggles source/name order",
      "b toggles breadcrumbs; cursor follows the last real editor buffer",
      "Manual selection is independent of editor cursor; q closes Outline",
    },
    keymaps = self:_keymaps(session),
    model = self:_model(session),
    on_dispose = function() if session.scope.alive then session.scope:dispose() end end,
  })
  if not view then
    scope:dispose()
    if replacing and existing and not existing.disposed then self.sessions[tab] = existing end
    return nil, view_error
  end
  session.view = view
  view.on_select = function(id, row, activate)
    session.selected_id = id
    if activate then return self:_activate(session, id, row) end
  end
  if bufnr then
    local watched, watch_error = self:_watch_buffer(session, bufnr)
    if not watched then
      session.status = "error"
      session.error = watch_error
      self:_update(session, true)
    end
    session.buffer = bufnr
    session.editor_window = win
    session.document_version = vim.api.nvim_buf_get_changedtick(bufnr)
  end
  local observed, observe_error = self:_ensure_observer()
  if not observed then
    view:close()
    return nil, observe_error
  end
  if bufnr then self:_request_snapshot(session, false) end
  return view
end

function Controller:_activate(session, id)
  local item
  for _, candidate in ipairs(session.items) do if candidate.id == id then item = candidate; break end end
  if not item or not item.location then return nil, error_value("symbol_location_unavailable", "selected symbol has no navigable file location") end
  local win = session.editor_window
  if not win or not vim.api.nvim_win_is_valid(win) or not real_buffer(vim.api.nvim_win_get_buf(win)) then
    return nil, error_value("editor_window_unavailable", "the source editor window is no longer available")
  end
  return self.navigation:open(item.location, "current", win, session.id)
end

function Controller:set_filter(value, tab)
  local session = self.sessions[tab or vim.api.nvim_get_current_tabpage()]
  if not session or not session.view then return nil, error_value("outline_unavailable", "Outline is not open in this tab") end
  if value ~= nil and type(value) ~= "string" then return nil, error_value("invalid_filter", "Outline filter must be a string") end
  session.filter = value or ""
  return self:_update(session, true)
end

function Controller:set_order(value, tab)
  local session = self.sessions[tab or vim.api.nvim_get_current_tabpage()]
  if not session or not session.view then return nil, error_value("outline_unavailable", "Outline is not open in this tab") end
  if value ~= "source" and value ~= "name" then return nil, error_value("invalid_order", "Outline order must be source or name") end
  session.order = value
  return self:_update(session, true)
end

function Controller:status()
  local sessions, request_count, watcher_count = {}, 0, 0
  for key, session in pairs(self.sessions) do
    sessions[#sessions + 1] = {
      key = tostring(key),
      buffer = session.buffer,
      document_version = session.document_version,
      selection = session.view and session.view.selected_id or session.selected_id,
      active_symbol = session.active_id,
      filter = session.filter,
      order = session.order,
      status = session.status,
      mounted = session.view ~= nil and not session.view.closed,
      request_pending = session.request_key ~= nil,
    }
  end
  table.sort(sessions, function(a, b) return a.key < b.key end)
  for _ in pairs(self.requests) do request_count = request_count + 1 end
  for _ in pairs(self.buffer_watchers) do watcher_count = watcher_count + 1 end
  return {
    disposed = self.disposed,
    session_count = #sessions,
    observer_active = self.observer_handle ~= nil and self.observer_handle:is_active(),
    request_count = request_count,
    watcher_count = watcher_count,
    sessions = sessions,
    resources = self.scope:inventory(),
  }
end

function Controller:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  local sessions = {}
  for _, session in pairs(self.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    if session.view and not session.view.closed then session.view:close()
    elseif session.scope.alive then session.scope:dispose() end
  end
  self.disposal_report = self.scope:dispose()
  self.sessions = {}
  self.requests = {}
  self.buffer_watchers = {}
  self.snapshots = {}
  self.view_states = {}
  self.view_state_order = {}
  self.observer_handle = nil
  return self.disposal_report
end

return M
