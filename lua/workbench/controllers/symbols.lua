local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")

local M = { debounce_ms = 80, history_limit = 8, page_size = 200 }
local Controller = {}
Controller.__index = Controller

local METHODS = {
  workspace = "workspace/symbol",
  references = "textDocument/references",
  definition = "textDocument/definition",
  type_definition = "textDocument/typeDefinition",
  implementation = "textDocument/implementation",
}
local LOCATION_METHODS = {
  [METHODS.references] = true,
  [METHODS.definition] = true,
  [METHODS.type_definition] = true,
  [METHODS.implementation] = true,
}
local next_controller_id = 0

local function copy(value)
  return vim.deepcopy(value)
end

local function error_value(code, message, extra)
  local result = { code = code, message = message }
  if type(extra) == "table" then for key, value in pairs(extra) do result[key] = value end end
  return result
end

local function real_buffer(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function current_editor(tab)
  if tab == vim.api.nvim_get_current_tabpage() then
    local win = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(win)
    if real_buffer(bufnr) and not vim.b[bufnr].workbench_preview then return bufnr, win end
  end
  if not vim.api.nvim_tabpage_is_valid(tab) then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if real_buffer(bufnr) and not vim.b[bufnr].workbench_preview then return bufnr, win end
  end
end

local function capture_origin(bufnr, win, session_id)
  if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then return nil end
  return {
    win = win,
    buf = bufnr,
    cursor = vim.api.nvim_win_get_cursor(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    tab = vim.api.nvim_win_get_tabpage(win),
    session_id = session_id,
  }
end

local function method_name(method)
  for name, value in pairs(METHODS) do if value == method then return name end end
  return "symbols"
end

local function short(value, limit)
  value = tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " ")
  if #value > limit then return value:sub(1, limit - 3) .. "..." end
  return value
end

local function reference_key(item)
  local location = item.location
  local range = location and location.range
  if not location or not range then return nil end
  local start, finish = range.start, range.finish
  return table.concat({
    location.resource.uri,
    tostring(start.line), tostring(start.character), tostring(finish.line), tostring(finish.character),
    location.encoding or "?",
  }, "\0")
end

local function hash(value)
  local first, second = 2166136261, 5381
  for index = 1, #value do
    local byte = value:byte(index)
    first = (first * 33 + byte) % 4294967291
    second = (second * 65599 + byte) % 4294967279
  end
  return string.format("%08x%08x", first, second)
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then
    return nil, error_value("invalid_dependency", "Symbols controller requires the shared layout manager")
  end
  if type(deps.provider) ~= "table" or type(deps.provider.capabilities) ~= "function"
    or type(deps.provider.start) ~= "function" then
    return nil, error_value("invalid_dependency", "Symbols controller requires the native LSP discovery provider")
  end
  if type(deps.store) ~= "table" or type(deps.store.create) ~= "function"
    or type(deps.store.merge) ~= "function" or type(deps.store.page) ~= "function" then
    return nil, error_value("invalid_dependency", "Symbols controller requires the shared bounded result store")
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.preview) ~= "function"
    or type(deps.navigation.open) ~= "function" or type(deps.navigation.return_to_origin) ~= "function" then
    return nil, error_value("invalid_dependency", "Symbols controller requires the shared navigation service")
  end
  if deps.actions ~= nil and type(deps.actions.register) ~= "function" then
    return nil, error_value("invalid_dependency", "actions must be a shared action registry")
  end
  if deps.get_settings ~= nil and type(deps.get_settings) ~= "function" then
    return nil, error_value("invalid_dependency", "get_settings must return the effective workbench settings")
  end
  next_controller_id = next_controller_id + 1
  local self = setmetatable({
    id = next_controller_id,
    layout = deps.layout,
    provider = deps.provider,
    store = deps.store,
    navigation = deps.navigation,
    actions = deps.actions or require("workbench.core.actions").new(),
    owns_actions = deps.actions == nil,
    get_workspace = type(deps.get_workspace) == "function" and deps.get_workspace or function() return deps.workspace end,
    get_settings = deps.get_settings,
    settings = type(deps.settings) == "table" and copy(deps.settings) or {},
    default_include_declaration = deps.default_include_declaration ~= false,
    input = type(deps.input) == "function" and deps.input or vim.ui.input,
    notify = deps.notify or vim.notify,
    debounce = math.max(0, math.min(300, tonumber(deps.debounce_ms) or M.debounce_ms)),
    scope = Scope.new("workbench-symbols-controller:" .. next_controller_id),
    sessions = {},
    next_session = 0,
    next_result = 0,
    disposed = false,
  }, Controller)
  local registered, register_err = self:_register_actions()
  if not registered then self:dispose(); return nil, register_err end
  return self
end

function Controller:_include_declaration(workspace)
  local settings = self.settings
  if self.get_settings then
    local okay, value = pcall(self.get_settings, workspace)
    if okay and type(value) == "table" then settings = value end
  end
  local symbols = type(settings.symbols) == "table" and settings.symbols or nil
  local lsp = type(settings.lsp) == "table" and settings.lsp or nil
  local value = symbols and symbols.include_declaration
  if value == nil and lsp then value = lsp.include_declaration end
  if value == nil then value = settings.include_declaration end
  if type(value) == "boolean" then return value end
  return self.default_include_declaration
end

function Controller:_source(overrides)
  overrides = overrides or {}
  local tab = overrides.tab or vim.api.nvim_get_current_tabpage()
  local bufnr, win = overrides.bufnr, overrides.win
  if not real_buffer(bufnr) or not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    bufnr, win = current_editor(tab)
  end
  if not real_buffer(bufnr) or not win then
    return nil, nil, error_value("no_source_buffer", "semantic navigation requires a named, loaded editor buffer")
  end
  return bufnr, win
end

function Controller:_capability(bufnr, method, client_ids)
  local context = { bufnr = bufnr, method = method }
  if client_ids then context.client_ids = client_ids end
  local okay, capability = pcall(self.provider.capabilities, self.provider, context)
  if not okay or type(capability) ~= "table" then
    return { state = "error", code = "capability_check_failed", reason = "LSP capability check failed" }
  end
  return capability
end

function Controller:_position_params(bufnr, win, method, workspace, include_declaration)
  local capability = self:_capability(bufnr, method)
  if capability.state ~= "ready" then return nil, capability end
  if type(vim.lsp.util.make_position_params) ~= "function" then
    return nil, { state = "error", code = "position_params_unavailable", reason = "Neovim cannot build LSP position parameters" }
  end
  local captured = {}
  for _, client in ipairs(capability.clients or {}) do
    local okay, params = pcall(vim.lsp.util.make_position_params, win, client.encoding)
    if okay and type(params) == "table" then
      if method == METHODS.references then
        params.context = { includeDeclaration = include_declaration == true }
      end
      captured[client.id] = params
    end
  end
  if next(captured) == nil then
    return nil, { state = "error", code = "position_params_failed", reason = "Neovim could not capture the source position for an attached LSP client" }
  end
  return function(client)
    local params = captured[client.id]
    return params and copy(params) or nil
  end
end

function Controller:_action_context(overrides)
  overrides = overrides or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local active = self.sessions[tab]
  local workspace = overrides.workspace or (active and active.workspace) or self.get_workspace()
  local bufnr, win = self:_source({ bufnr = overrides.bufnr or (active and active.bufnr), win = overrides.win or (active and active.source_win), tab = tab })
  return vim.tbl_extend("force", {
    controller = self,
    actions = self.actions,
    workspace = workspace,
    bufnr = bufnr,
    win = win,
    symbols = active,
    capability = workspace and bufnr and self:_capability(bufnr, METHODS.workspace) or nil,
  }, overrides)
end

function Controller:_action_available(ctx, method, workspace_only)
  if type(ctx.workspace) ~= "table" then return { enabled = false, code = "no_workspace", reason = "no workbench workspace is active" } end
  if workspace_only then
    if type(ctx.bufnr) ~= "number" then return { enabled = false, code = "no_source_buffer", reason = "open a named editor file to select attached workspace-symbol clients" } end
  elseif not real_buffer(ctx.bufnr) then
    return { enabled = false, code = "no_source_buffer", reason = "a named, loaded editor buffer is required" }
  end
  local capability = self:_capability(ctx.bufnr, method)
  return {
    enabled = capability.state == "ready",
    code = capability.code or capability.state,
    reason = capability.reason,
  }
end

function Controller:_register(action)
  return self.actions:register(action, { scope = self.scope })
end

function Controller:_register_actions()
  local controller = self
  local actions = {
    {
      id = "symbols.workspace", title = "Search workspace symbols", category = "Symbols", scope = "workspace",
      available = function(ctx) return controller:_action_available(ctx, METHODS.workspace, true) end,
      run = function(ctx, args) return controller:_prompt_workspace(ctx.workspace, args.query) end,
      args_schema = { type = "object", properties = { query = { type = "string", max_length = 512 } }, additional_properties = false },
    },
    {
      id = "symbols.references", title = "Find references", category = "Symbols", scope = "buffer",
      available = function(ctx) return controller:_action_available(ctx, METHODS.references, false) end,
      run = function(ctx) return controller:references(ctx.workspace, ctx.bufnr, ctx.win) end,
    },
    {
      id = "symbols.definition", title = "Go to definition", category = "Symbols", scope = "buffer",
      available = function(ctx) return controller:_action_available(ctx, METHODS.definition, false) end,
      run = function(ctx) return controller:definition(ctx.workspace, ctx.bufnr, ctx.win) end,
    },
    {
      id = "symbols.type_definition", title = "Go to type definition", category = "Symbols", scope = "buffer",
      available = function(ctx) return controller:_action_available(ctx, METHODS.type_definition, false) end,
      run = function(ctx) return controller:type_definition(ctx.workspace, ctx.bufnr, ctx.win) end,
    },
    {
      id = "symbols.implementation", title = "Find implementations", category = "Symbols", scope = "buffer",
      available = function(ctx) return controller:_action_available(ctx, METHODS.implementation, false) end,
      run = function(ctx) return controller:implementation(ctx.workspace, ctx.bufnr, ctx.win) end,
    },
    {
      id = "symbols.resolve", title = "Resolve selected workspace symbol", category = "Symbols", scope = "item",
      available = function(ctx)
        local active = ctx.symbols
        local item = active and active.current and active.view and active.view.selected_id
          and controller.store:item(active.current.result_id, active.view.selected_id)
        if not item or not item.payload or not item.payload.resolve_item or item.location then
          return { enabled = false, code = "not_resolvable", reason = "select an unresolved workspace symbol first" }
        end
        local capability = controller:_capability(active.bufnr, "workspaceSymbol/resolve", { item.payload.client_id })
        return { enabled = capability.state == "ready", code = capability.code, reason = capability.reason }
      end,
      run = function(ctx) return controller:resolve_selected(ctx.symbols) end,
    },
    {
      id = "symbols.cancel", title = "Cancel semantic request", category = "Symbols", scope = "view",
      available = function(ctx) return { enabled = ctx.symbols ~= nil and ctx.symbols.request ~= nil, reason = "there is no active semantic request" } end,
      run = function(ctx) return controller:cancel(ctx.symbols) end,
    },
    {
      id = "symbols.return", title = "Return to semantic origin", category = "Navigation", scope = "view",
      available = function(ctx) return { enabled = ctx.symbols ~= nil and ctx.symbols.current ~= nil, reason = "there is no semantic navigation origin" } end,
      run = function(ctx) return controller:return_to_origin(ctx.symbols) end,
    },
  }
  for _, action in ipairs(actions) do
    local handle, err = self:_register(action)
    if not handle then return nil, err end
  end
  return true
end

function Controller:_new_session(workspace, bufnr, win, tab)
  local previous = self.sessions[tab]
  if previous and previous.workspace.id == workspace.id and previous.scope.alive then return previous end
  if previous then self:_dispose_session(previous) end
  self.next_session = self.next_session + 1
  local scope, err = self.scope:child("session:" .. self.next_session .. ":tab:" .. tostring(tab))
  if not scope then return nil, err end
  local active = {
    id = "symbols-" .. self.id .. "-" .. self.next_session,
    workspace = copy(workspace),
    tab = tab,
    bufnr = bufnr,
    source_win = win,
    scope = scope,
    view = nil,
    preview = nil,
    current = nil,
    history = {},
    request = nil,
    request_scope = nil,
    timer_scope = nil,
    generation = 0,
    query = "",
    method = nil,
    phase = "Ready",
    notice = nil,
    offset = 0,
    navigation_id = nil,
    origin = nil,
    disposed = false,
  }
  scope:defer(function() self:_dispose_session(active) end, "symbols-session:" .. active.id, "session")
  self.sessions[tab] = active
  return active
end

function Controller:_dispose_session(active)
  if not active or active.disposed then return false end
  active.disposed = true
  active.generation = active.generation + 1
  self:_cancel_timer(active)
  self:_cancel_request(active, "symbols session disposed")
  if active.preview then active.preview:dispose(); active.preview = nil end
  if active.current and active.current.store_session then active.current.store_session:close() end
  for _, entry in ipairs(active.history) do if entry.store_session then entry.store_session:close() end end
  if self.sessions[active.tab] == active then self.sessions[active.tab] = nil end
  return true
end

function Controller:_ensure_preview(active)
  if active.preview and not active.preview.disposed then return active.preview end
  local preview, err = require("workbench.ui.preview").new({ navigation = self.navigation, session_id = active.id })
  if not preview then return nil, err end
  active.preview = preview
  local _, defer_error = active.scope:defer(function() preview:dispose() end, "symbols-preview:" .. active.id, "view")
  if defer_error then preview:dispose(); active.preview = nil; return nil, defer_error end
  return preview
end

function Controller:_help(active)
  local lines = {
    "j/k: select · Enter/o: open or resolve · p: preview · R: return",
    "/: new workspace-symbol query · ]: show more · x: cancel · q: close",
  }
  local actions = self.actions:list(self:_action_context({ workspace = active.workspace, symbols = active, bufnr = active.bufnr, win = active.source_win }))
  for _, action in ipairs(actions) do
    if action.id:match("^symbols%.") and #lines < 10 then
      local state = action.available.enabled and "available" or action.available.reason or "unavailable"
      lines[#lines + 1] = string.format("%s — %s (%s)", action.id, action.title, short(state, 96))
    end
  end
  return lines
end

function Controller:_mount(active, focus)
  if active.view and not active.view.closed then return active.view end
  local model = self:_model(active)
  local view, err = self.layout:mount({
    id = "workbench-symbols",
    title = "Symbols",
    kind = "list",
    placement = "results",
    focus = focus ~= false,
    model = model,
    help_lines = self:_help(active),
    keymaps = {
      ["/"] = { desc = "Workbench: query workspace symbols", run = function() self:_prompt_workspace(active.workspace) end },
      ["]"] = { desc = "Workbench: load more semantic results", run = function() self:load_more(active) end },
      ["x"] = { desc = "Workbench: cancel semantic request", run = function() self:cancel(active) end },
      ["p"] = { desc = "Workbench: preview semantic result", run = function() self:preview_selected(active) end },
      ["o"] = { desc = "Workbench: open semantic result", run = function() self:open_selected(active) end },
      ["R"] = { desc = "Workbench: return to semantic origin", run = function() self:return_to_origin(active) end },
    },
    on_select = function(id, row, committed) return self:_select(active, id, row, committed) end,
    on_dispose = function()
      active.view = nil
      if active.request then self:_cancel_request(active, "symbols view closed") end
      if active.preview then active.preview:close() end
      if active.current and active.current.store_session then active.current.store_session:close() end
    end,
  })
  if not view then return nil, err end
  active.view = view
  return view
end

function Controller:_model(active)
  local entry = active.current
  if not entry then
    return { status = "empty", title = "Symbols", header = { "No semantic query yet", "Use the action palette or / to search workspace symbols." }, items = {} }
  end
  local summary = self.store:summary(entry.result_id)
  if not summary then
    return { status = "error", title = "Symbols", error = "semantic result history is unavailable", items = {} }
  end
  local page, page_err = self.store:page(entry.result_id, active.offset or 0, M.page_size)
  if not page then return { status = "error", title = "Symbols", error = page_err, items = {} } end
  local rows = {}
  for _, item in ipairs(page.items) do
    local location = item.location
    local line = location and location.range and (location.range.start.line + 1) or nil
    local path = location and location.resource and location.resource.display_path or nil
    local detail = item.detail or item.payload and item.payload.container_name
    if path then detail = (detail and (detail .. " · ") or "") .. Resource.escape_display(path) .. (line and (":" .. line) or "") end
    if not location and item.payload and item.payload.resolve_item then detail = (detail and detail .. " · " or "") .. "Enter to resolve location" end
    rows[#rows + 1] = {
      id = item.id,
      kind = item.kind == "symbol" and "symbol" or "location",
      label = short(item.label, 256),
      detail = detail and short(detail, 256) or nil,
      location = location,
      payload = item.payload,
    }
  end
  if page.next_offset then
    rows[#rows + 1] = { id = "symbols:more:" .. entry.result_id, kind = "notice", label = "More results available — press ]", selectable = false }
  end
  local status = summary.status
  local view_status = "ready"
  if status == "running" and #rows == 0 then view_status = "running"
  elseif status == "complete" and #page.items == 0 then view_status = "empty"
  elseif status == "error" and #page.items == 0 then view_status = "error"
  end
  if summary.error and #rows > 0 then
    rows[#rows + 1] = { id = "symbols:status:" .. entry.result_id, kind = "notice", label = short(summary.error.message or summary.error.code, 192), selectable = false }
  end
  local shown_start = #page.items > 0 and (page.offset + 1) or 0
  local shown_end = page.offset + #page.items
  local header = {
    string.format("%s%s", method_name(entry.method), entry.query ~= "" and (": " .. short(entry.query, 120)) or ""),
    string.format("State: %s · %d-%d of %d result%s%s", active.phase or status, shown_start, shown_end, summary.item_count,
      summary.item_count == 1 and "" or "s", summary.completeness == "truncated" and " · partial/capped" or ""),
  }
  if entry.method == METHODS.references then
    header[#header + 1] = "Include declaration: " .. tostring(entry.include_declaration)
  end
  if active.notice then header[#header + 1] = short(active.notice, 200) end
  return { status = view_status, title = "Symbols", header = header, items = rows, error = summary.error }
end

function Controller:_render(active)
  if not active.view or active.view.closed then return false end
  local model = self:_model(active)
  local okay, err = active.view:update(model)
  if not okay then active.last_error = err end
  return okay ~= nil
end

function Controller:_cancel_timer(active)
  if not active or not active.timer_scope then return false end
  local scope = active.timer_scope
  active.timer_scope = nil
  scope:dispose()
  return true
end

function Controller:_finish_entry(entry, status, completeness, err)
  if not entry or not entry.result_id then return nil end
  return self.store:finish(entry.result_id, status, completeness, err)
end

function Controller:_cancel_request(active, reason)
  if not active or not active.request then return false end
  local handle, request_scope = active.request, active.request_scope
  active.request, active.request_scope = nil, nil
  local entry = active.current
  local summary = entry and self.store:summary(entry.result_id)
  if summary and summary.status == "running" then
    self:_finish_entry(entry, "cancelled", "unknown", { code = "cancelled", message = reason or "semantic request cancelled" })
  end
  if handle.cancel then pcall(handle.cancel, handle, "cancelled") elseif handle.dispose then pcall(handle.dispose, handle) end
  if request_scope then request_scope:dispose() end
  return true
end

function Controller:_new_entry(active, method, query, include_declaration, seed_items)
  self.next_result = self.next_result + 1
  local result_id = string.format("symbols:%d:%d", self.id, self.next_result)
  local set, create_err = self.store:create({
    id = result_id,
    provider_id = "lsp.symbols",
    workspace_id = active.workspace.id,
    generation = active.generation,
    status = "running",
    completeness = "unknown",
    query = {
      method = method,
      query = query,
      include_declaration = include_declaration,
      source_uri = vim.uri_from_bufnr(active.bufnr),
    },
  })
  if not set then return nil, error_value("result_store_error", tostring(create_err)) end
  if seed_items then
    for index = 1, #seed_items, 512 do
      local batch = {}
      for item_index = index, math.min(#seed_items, index + 511) do batch[#batch + 1] = seed_items[item_index] end
      local merged, merge_err = self.store:merge(result_id, batch)
      if not merged then self.store:finish(result_id, "error", "unknown", { code = "result_copy_failed", message = tostring(merge_err) }); return nil, error_value("result_copy_failed", tostring(merge_err)) end
    end
  end
  local session, session_err = self.store:open_session(result_id, { id = result_id .. ":view", selected_id = active.selected_id, origin = active.origin })
  if not session then
    self.store:finish(result_id, "error", "unknown", { code = "view_session_failed", message = tostring(session_err) })
    return nil, error_value("view_session_failed", tostring(session_err))
  end
  local entry = {
    result_id = result_id,
    store_session = session,
    method = method,
    query = query or "",
    include_declaration = include_declaration,
    generation = active.generation,
    navigation_id = active.navigation_id,
  }
  if active.current and active.current.store_session then
    active.current.store_session:close()
    active.history[#active.history + 1] = active.current
    while #active.history > M.history_limit do
      local expired = table.remove(active.history, 1)
      if expired.store_session then expired.store_session:dispose() end
    end
  end
  active.current = entry
  active.selected_id = session.selected_id
  active.offset = 0
  return entry
end

function Controller:_schedule(active, generation)
  local timer_scope, scope_err = active.scope:child("debounce:" .. generation)
  if not timer_scope then return nil, scope_err end
  active.timer_scope = timer_scope
  local uv = vim.uv or vim.loop
  local timer_ok, timer_or_err = pcall(uv.new_timer)
  local timer = timer_ok and timer_or_err or nil
  if not timer then timer_scope:dispose(); active.timer_scope = nil; return nil, error_value("timer_unavailable", tostring(timer_or_err or "could not create a query debounce timer")) end
  local _, defer_err = timer_scope:defer(function()
    pcall(timer.stop, timer)
    if not timer:is_closing() then timer:close() end
  end, "symbols-query-debounce:" .. generation, "timer")
  if defer_err then timer_scope:dispose(); active.timer_scope = nil; return nil, defer_err end
  local started, start_err = pcall(timer.start, timer, self.debounce, 0, function()
    timer_scope:schedule(function()
      if active.timer_scope ~= timer_scope then return end
      active.timer_scope = nil
      timer_scope:dispose()
      if active.scope.alive and active.generation == generation then self:_start(active, generation) end
    end)
  end)
  if not started then
    timer_scope:dispose()
    active.timer_scope = nil
    return nil, error_value("timer_start_failed", tostring(start_err))
  end
  return true
end

function Controller:set_query(active, query, immediate)
  if not active or active.disposed or not active.scope.alive then return nil, error_value("session_closed", "semantic results session is closed") end
  if type(active.method) ~= "string" or active.method ~= METHODS.workspace then
    return nil, error_value("query_not_supported", "only workspace-symbol searches accept a text query")
  end
  if type(query) ~= "string" or #query > 512 then return nil, error_value("invalid_query", "workspace-symbol query must be a string of at most 512 bytes") end
  active.query = query
  active.generation = active.generation + 1
  local generation = active.generation
  self:_cancel_timer(active)
  self:_cancel_request(active, "workspace-symbol query superseded")
  if query == "" then
    active.phase = "Enter a query"
    active.notice = nil
    self:_render(active)
    return true
  end
  active.phase = "Searching"
  active.notice = nil
  self:_render(active)
  if immediate then return self:_start(active, generation) end
  return self:_schedule(active, generation)
end

function Controller:_start(active, generation)
  if active.disposed or generation ~= active.generation or not active.scope.alive then return false end
  local method = active.method
  local client_ids = active.client_ids
  local capability = self:_capability(active.bufnr, method, client_ids)
  local include = active.include_declaration
  local entry, entry_err = self:_new_entry(active, method, active.query, include, active.seed_items)
  active.seed_items = nil
  if not entry then
    active.phase = "Error"
    active.notice = entry_err.message
    self:_render(active)
    return nil, entry_err
  end
  active.phase = "Loading"
  active.dedupe_ids = {}
  active.dedupe_keys = {}
  active.dedupe_items = {}
  if capability.state ~= "ready" then
    self:_finish_entry(entry, "error", "unknown", { code = capability.code or "unsupported_method", message = capability.reason or "LSP method is unavailable" })
    active.phase = "Unavailable"
    active.notice = capability.reason or "LSP method is unavailable"
    self:_render(active)
    return nil, error_value(capability.code or "unsupported_method", active.notice)
  end
  if method == METHODS.workspace and active.query == "" then
    self:_finish_entry(entry, "complete", "complete")
    active.phase = "No query"
    self:_render(active)
    return true
  end
  local params
  if active.params then params = active.params
  elseif method == METHODS.workspace then params = function() return { query = active.query } end
  elseif method == "workspaceSymbol/resolve" then params = function() return copy(active.resolve_item) end
  end
  local scope, scope_err = active.scope:child("request:" .. generation)
  if not scope then
    self:_finish_entry(entry, "error", "unknown", { code = "request_scope_failed", message = scope_err and scope_err.message or "cannot own LSP request" })
    return nil, scope_err
  end
  local controller = self
  local request, request_err = self.provider:start({
    bufnr = active.bufnr,
    method = method,
    params = params,
    result_kind = method == "workspaceSymbol/resolve" and "symbol" or "auto",
    client_ids = client_ids,
    workspace = active.workspace,
    workspace_id = active.workspace.id,
    workspace_generation = active.workspace.generation,
    generation = generation,
    session_id = active.id .. ":" .. generation,
    is_current = function()
      return not active.disposed and active.scope.alive and active.generation == generation
        and active.workspace.generation == active.workspace_generation
    end,
  }, function(event) controller:_on_event(active, entry, generation, event) end)
  if not request then
    scope:dispose()
    self:_finish_entry(entry, "error", "unknown", request_err or { code = "request_failed", message = "LSP request could not start" })
    active.phase = "Error"
    active.notice = type(request_err) == "table" and request_err.message or tostring(request_err)
    self:_render(active)
    return nil, request_err
  end
  scope:defer(function() if request.dispose then request:dispose() end end, "lsp-request-handle:" .. generation, "lsp-request")
  active.request, active.request_scope = request, scope
  self:_render(active)
  return request
end

function Controller:_dedupe_reference_batch(active, items)
  local result = {}
  for _, item in ipairs(items) do
    local key = reference_key(item)
    if key then
      local id = active.dedupe_ids[key]
      if not id then
        id = "reference:" .. hash(key)
        local collision = 1
        while active.dedupe_keys[id] and active.dedupe_keys[id] ~= key do
          collision = collision + 1
          id = "reference:" .. hash(key) .. ":" .. collision
        end
        active.dedupe_ids[key], active.dedupe_keys[id] = id, key
      end
      local existing = active.dedupe_items[key] or self.store:item(active.current.result_id, id)
      local clients = existing and copy(existing.payload and existing.payload.client_ids or { existing.payload and existing.payload.client_id }) or {}
      local seen = {}
      for _, client_id in ipairs(clients) do if client_id then seen[client_id] = true end end
      local client_id = item.payload and item.payload.client_id
      if client_id and not seen[client_id] then clients[#clients + 1] = client_id end
      item.id = id
      item.payload = item.payload or {}
      item.payload.client_ids = clients
      active.dedupe_items[key] = item
    end
    result[#result + 1] = item
  end
  return result
end

function Controller:_on_event(active, entry, generation, event)
  if active.disposed or not active.scope.alive or active.current ~= entry or active.generation ~= generation then return false end
  if type(event) ~= "table" or event.generation ~= generation then return false end
  if event.kind == "batch" then
    local items = event.items or {}
    if entry.method == METHODS.references then items = self:_dedupe_reference_batch(active, items) end
    if active.resolve_item_id then
      local mapped = {}
      for _, item in ipairs(items) do
        item.id = active.resolve_item_id
        item.label = active.resolve_label or item.label
        mapped[#mapped + 1] = item
      end
      items = mapped
    end
    self.store:merge(entry.result_id, items)
    active.phase = "Receiving"
    local selected = active.selected_id or entry.store_session.selected_id
    if selected and self.store:item(entry.result_id, selected) then entry.store_session:select(selected) end
    self:_render(active)
    return true
  elseif event.kind == "status" then
    active.phase = event.status == "partial" and "Partial" or tostring(event.status or "Loading")
    self:_render(active)
    return true
  elseif event.kind == "error" then
    self:_finish_entry(entry, "error", "unknown", event.error or { code = "lsp_error", message = "semantic request failed" })
    local request_scope = active.request_scope
    active.request, active.request_scope = nil, nil
    if request_scope then request_scope:dispose() end
    active.phase = "Error"
    active.notice = event.error and event.error.message or "semantic request failed"
    self:_render(active)
    return true
  elseif event.kind == "done" then
    local status = event.status or (event.error and "partial" or "complete")
    local completeness = status == "complete" and "complete" or status == "partial" and "partial" or "unknown"
    local finish_error = event.error
    if status == "error" and type(finish_error) ~= "table" then finish_error = { code = "lsp_error", message = "all eligible language servers failed" } end
    self:_finish_entry(entry, status, completeness, finish_error)
    local request_scope = active.request_scope
    active.request, active.request_scope = nil, nil
    if request_scope then request_scope:dispose() end
    active.phase = status == "complete" and "Complete" or status == "partial" and "Partial" or status == "cancelled" and "Cancelled" or "Error"
    if finish_error then active.notice = finish_error.message or finish_error.code end
    local resolved = active.resolve_item_id and self.store:item(entry.result_id, active.resolve_item_id)
    local open_after = active.resolve_open_after
    active.resolve_item_id, active.resolve_label, active.resolve_open_after = nil, nil, nil
    self:_render(active)
    if open_after and resolved and resolved.location then self:open_selected(active) end
    return true
  end
  return false
end

function Controller:_prepare(active, method, opts)
  opts = opts or {}
  active.method = method
  active.bufnr = opts.bufnr
  active.source_win = opts.win
  active.workspace = copy(opts.workspace)
  active.workspace_generation = active.workspace.generation
  active.include_declaration = opts.include_declaration
  active.client_ids = opts.client_ids
  active.params = opts.params
  active.query = opts.query or ""
  active.generation = active.generation + 1
  active.phase = "Ready"
  active.notice = nil
  self:_cancel_timer(active)
  self:_cancel_request(active, "new semantic request")
  active.navigation_id = active.id .. ":navigation:" .. active.generation
  active.origin = capture_origin(active.bufnr, active.source_win, active.navigation_id)
  active.dedupe_ids, active.dedupe_keys, active.dedupe_items = {}, {}, {}
  active.selected_id = nil
  active.offset = 0
  return active
end

function Controller:_open(workspace, method, bufnr, win, opts)
  if self.disposed then return nil, error_value("controller_disposed", "Symbols controller is disposed") end
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" then
    return nil, error_value("no_workspace", "semantic navigation requires an active Workbench workspace")
  end
  if not real_buffer(bufnr) or not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil, error_value("no_source_buffer", "semantic navigation requires a named, loaded editor buffer")
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local active, active_err = self:_new_session(workspace, bufnr, win, tab)
  if not active then return nil, active_err end
  self:_prepare(active, method, vim.tbl_extend("force", opts or {}, { workspace = workspace, bufnr = bufnr, win = win }))
  local view, view_err = self:_mount(active, opts and opts.focus)
  if not view then return nil, view_err end
  if method == METHODS.workspace then
    self:set_query(active, opts and opts.query or "", opts and opts.immediate == true)
  else
    local capability = self:_capability(bufnr, method, opts and opts.client_ids)
    if capability.state ~= "ready" then
      active.generation = active.generation + 1
      active.method = method
      local entry, entry_err = self:_new_entry(active, method, "", opts and opts.include_declaration, nil)
      if entry then
        self:_finish_entry(entry, "error", "unknown", { code = capability.code or "unsupported_method", message = capability.reason or "LSP method is unavailable" })
        active.phase, active.notice = "Unavailable", capability.reason or "LSP method is unavailable"
        self:_render(active)
      end
      return view, entry_err or error_value(capability.code or "unsupported_method", capability.reason or "LSP method is unavailable")
    end
    local params, params_err = self:_position_params(bufnr, win, method, workspace, opts and opts.include_declaration)
    if not params then return view, error_value(params_err.code or "position_params_failed", params_err.reason or "could not build LSP position parameters") end
    active.params = params
    active.generation = active.generation + 1
    active.phase = "Loading"
    self:_start(active, active.generation)
  end
  return view, active
end

function Controller:workspace_symbols(workspace, query, opts)
  opts = opts or {}
  local bufnr, win, source_err = self:_source(opts)
  if not bufnr then return nil, source_err end
  opts = vim.tbl_extend("force", opts, { query = query or "", workspace = workspace, bufnr = bufnr, win = win })
  return self:_open(workspace, METHODS.workspace, bufnr, win, opts)
end

function Controller:_position_operation(method, workspace, bufnr, win, opts)
  opts = opts or {}
  local source_err
  if not real_buffer(bufnr) or not win then bufnr, win, source_err = self:_source(opts) end
  if not bufnr then return nil, source_err end
  workspace = workspace or self.get_workspace()
  local include
  if method == METHODS.references then include = self:_include_declaration(workspace) end
  return self:_open(workspace, method, bufnr, win, vim.tbl_extend("force", opts, {
    workspace = workspace,
    bufnr = bufnr,
    win = win,
    include_declaration = include,
  }))
end

function Controller:references(workspace, bufnr, win, opts)
  return self:_position_operation(METHODS.references, workspace, bufnr, win, opts)
end

function Controller:definition(workspace, bufnr, win, opts)
  return self:_position_operation(METHODS.definition, workspace, bufnr, win, opts)
end

function Controller:type_definition(workspace, bufnr, win, opts)
  return self:_position_operation(METHODS.type_definition, workspace, bufnr, win, opts)
end

function Controller:implementation(workspace, bufnr, win, opts)
  return self:_position_operation(METHODS.implementation, workspace, bufnr, win, opts)
end

function Controller:_prompt_workspace(workspace, preset)
  if type(workspace) ~= "table" then return nil, error_value("no_workspace", "no workbench workspace is active") end
  if type(preset) == "string" then return self:workspace_symbols(workspace, preset) end
  self.input({ prompt = "Workspace symbols: ", default = "" }, function(value)
    if value == nil then return end
    local view, err = self:workspace_symbols(workspace, value)
    if not view and err and self.notify then self.notify(err.message or tostring(err), vim.log.levels.WARN) end
  end)
  return true
end

function Controller:_active(tab)
  return self.sessions[tab or vim.api.nvim_get_current_tabpage()]
end

function Controller:load_more(active)
  if not active or not active.current then return false end
  local summary = self.store:summary(active.current.result_id)
  if not summary then return false end
  local page = self.store:page(active.current.result_id, active.offset or 0, M.page_size)
  if not page or not page.next_offset then return false end
  active.offset = page.next_offset
  self:_render(active)
  return true
end

function Controller:_selected(active)
  if not active or not active.current then return nil end
  local id = active.view and active.view.selected_id or active.selected_id or active.current.store_session.selected_id
  if not id then return nil end
  return self.store:item(active.current.result_id, id), id
end

function Controller:_select(active, id, row, committed)
  if not active or active.disposed or not active.current then return false end
  local item = self.store:item(active.current.result_id, id)
  if not item then return false end
  active.selected_id = id
  active.current.store_session:select(id)
  if committed then
    if item.location then return self:open_selected(active) end
    if item.payload and item.payload.resolve_item then return self:resolve_selected(active, { open_after = true }) end
    active.notice = "This workspace symbol has no navigable location and cannot be resolved."
    self:_render(active)
    return nil, error_value("location_unavailable", active.notice)
  end
  if item.location then return self:preview_selected(active) end
  if active.preview then active.preview:close() end
  return true
end

function Controller:preview_selected(active)
  local item = self:_selected(active)
  if not item or not item.location then return nil, error_value("location_unavailable", "the selected symbol has no location to preview") end
  local preview, preview_err = self:_ensure_preview(active)
  if not preview then return nil, preview_err end
  active.current.store_session:preview(item.id)
  local restore = active.view and active.view.window and vim.api.nvim_win_is_valid(active.view.window)
    and vim.api.nvim_get_current_win() == active.view.window
  local request, err = preview:preview(item.location, active.current.navigation_id, function(result)
    if active.disposed or not active.scope.alive or active.current == nil then return end
    if type(result) == "table" and result.code then
      active.notice = "Preview unavailable: " .. tostring(result.message or result.code)
      self:_render(active)
    end
  end)
  if restore and active.view.window and vim.api.nvim_win_is_valid(active.view.window) then pcall(vim.api.nvim_set_current_win, active.view.window) end
  return request, err
end

function Controller:open_selected(active)
  local item = self:_selected(active)
  if not item then return nil, error_value("selection_unavailable", "select a semantic result first") end
  if not item.location then
    if item.payload and item.payload.resolve_item then return self:resolve_selected(active, { open_after = true }) end
    return nil, error_value("location_unavailable", "the selected semantic result has no navigable location")
  end
  return self.navigation:open(item.location, "split", active.origin, active.current.navigation_id)
end

function Controller:return_to_origin(active)
  if not active or not active.current then return nil, error_value("origin_unavailable", "there is no semantic navigation origin") end
  return self.navigation:return_to_origin(active.current.navigation_id)
end

function Controller:cancel(active)
  if not active or not active.request then return false end
  active.generation = active.generation + 1
  self:_cancel_timer(active)
  self:_cancel_request(active, "semantic request cancelled")
  active.phase = "Cancelled"
  self:_render(active)
  return true
end

function Controller:resolve_selected(active, opts)
  opts = opts or {}
  local item, item_id = self:_selected(active)
  if not item or not item.payload or type(item.payload.resolve_item) ~= "table" or item.location then
    return nil, error_value("not_resolvable", "select an unresolved workspace symbol first")
  end
  local client_id = item.payload.client_id
  local capability = self:_capability(active.bufnr, "workspaceSymbol/resolve", { client_id })
  if capability.state ~= "ready" then return nil, error_value(capability.code or "unsupported_method", capability.reason or "the originating client cannot resolve workspace symbols") end
  local old = self.store:get(active.current.result_id)
  if not old then return nil, error_value("result_unavailable", "workspace-symbol results were evicted") end
  active.generation = active.generation + 1
  self:_cancel_request(active, "workspace-symbol resolution started")
  active.method = "workspaceSymbol/resolve"
  active.client_ids = { client_id }
  active.params = function() return copy(item.payload.resolve_item) end
  active.resolve_item = copy(item.payload.resolve_item)
  active.resolve_item_id = item_id
  active.resolve_label = item.label
  active.resolve_open_after = opts.open_after == true
  active.seed_items = {}
  for _, old_id in ipairs(old.order) do active.seed_items[#active.seed_items + 1] = old.items[old_id] end
  active.selected_id = item_id
  active.navigation_id = active.id .. ":resolve:" .. active.generation
  active.origin = capture_origin(active.bufnr, active.source_win, active.navigation_id)
  active.phase = "Resolving"
  local started, start_err = self:_start(active, active.generation)
  if not started then return nil, start_err end
  self:_render(active)
  return true
end

function Controller:status()
  local sessions = {}
  for tab, active in pairs(self.sessions) do
    if not active.disposed then
      local summary = active.current and self.store:summary(active.current.result_id)
      sessions[#sessions + 1] = {
        tab = tab,
        method = active.method,
        query = active.query,
        phase = active.phase,
        generation = active.generation,
        result_id = active.current and active.current.result_id,
        request_active = active.request ~= nil,
        view = active.view ~= nil and not active.view.closed,
        result_status = summary and summary.status,
        resources = active.scope:inventory(),
      }
    end
  end
  table.sort(sessions, function(left, right) return left.tab < right.tab end)
  return { disposed = self.disposed, sessions = sessions, resources = self.scope:inventory() }
end

function Controller:dispose()
  if self.disposed then return false end
  self.disposed = true
  local active_sessions = {}
  for _, active in pairs(self.sessions) do active_sessions[#active_sessions + 1] = active end
  for _, active in ipairs(active_sessions) do
    if active.view then self.layout:close("workbench-symbols", active.tab) end
    active.scope:dispose()
  end
  self.sessions = {}
  self.scope:dispose()
  if self.owns_actions then self.actions = nil end
  return true
end

return M
