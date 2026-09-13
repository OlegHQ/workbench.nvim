local Scope = require("workbench.core.scope")
local Location = require("workbench.core.location")

local M = {
  max_depth = 8,
  max_children = 200,
  max_edges = 2000,
}

local Controller = {}
Controller.__index = Controller

local PREPARE = "textDocument/prepareCallHierarchy"
local METHODS = {
  incoming = "callHierarchy/incomingCalls",
  outgoing = "callHierarchy/outgoingCalls",
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
    if real_buffer(bufnr) then return bufnr, win end
  end
  if not vim.api.nvim_tabpage_is_valid(tab) then return nil end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if real_buffer(bufnr) then return bufnr, win end
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

local function short(value, limit)
  value = tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " ")
  if #value > limit then return value:sub(1, limit - 3) .. "..." end
  return value
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

local function position_key(position)
  if type(position) ~= "table" then return "?" end
  return tostring(position.line or "?") .. ":" .. tostring(position.character or "?")
end

local function symbol_key(call_item)
  local range = type(call_item) == "table" and call_item.selectionRange or nil
  return table.concat({
    tostring(call_item and call_item.uri or ""),
    tostring(call_item and call_item.name or ""),
    tostring(call_item and call_item.kind or ""),
    position_key(range and range.start),
    position_key(range and (range["end"] or range.finish)),
  }, "\0")
end

local function range_to_location(item, range)
  local location = item and item.location
  if not location or not location.resource or type(range) ~= "table" then return location end
  local normalized = {
    start = range.start and { line = range.start.line, character = range.start.character } or nil,
    finish = range["end"] and { line = range["end"].line, character = range["end"].character }
      or range.finish and { line = range.finish.line, character = range.finish.character } or nil,
  }
  if not normalized.start or not normalized.finish then return location end
  local result = Location.new(location.resource, {
    range = normalized,
    encoding = location.encoding,
    client_id = location.client_id,
    version = location.version,
  })
  return result or location
end

local function location_detail(location)
  if type(location) ~= "table" or type(location.resource) ~= "table" then return nil end
  local text = location.resource.display_path
  if location.range then text = text .. ":" .. tostring(location.range.start.line + 1) end
  return text
end

local function normalize_limit(value, default, maximum)
  if value == nil then return default end
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then return nil end
  return math.min(value, maximum)
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" or type(deps.layout.close) ~= "function" then
    return nil, error_value("invalid_dependency", "Calls controller requires the shared layout manager")
  end
  if type(deps.provider) ~= "table" or type(deps.provider.capabilities) ~= "function" or type(deps.provider.start) ~= "function" then
    return nil, error_value("invalid_dependency", "Calls controller requires the native LSP discovery provider")
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.open) ~= "function"
    or type(deps.navigation.return_to_origin) ~= "function" then
    return nil, error_value("invalid_dependency", "Calls controller requires shared semantic navigation")
  end
  if deps.actions ~= nil and type(deps.actions.register) ~= "function" then
    return nil, error_value("invalid_dependency", "actions must be a shared action registry")
  end
  local max_depth = normalize_limit(deps.max_depth, M.max_depth, 32)
  local max_children = normalize_limit(deps.max_children, M.max_children, 1000)
  local max_edges = normalize_limit(deps.max_edges, M.max_edges, 10000)
  if not max_depth or not max_children or not max_edges then
    return nil, error_value("invalid_limit", "call hierarchy limits must be positive integers")
  end

  next_controller_id = next_controller_id + 1
  local self = setmetatable({
    id = next_controller_id,
    layout = deps.layout,
    provider = deps.provider,
    navigation = deps.navigation,
    actions = deps.actions or require("workbench.core.actions").new(),
    owns_actions = deps.actions == nil,
    get_workspace = type(deps.get_workspace) == "function" and deps.get_workspace or function() return deps.workspace end,
    max_depth = max_depth,
    max_children = max_children,
    max_edges = max_edges,
    sessions = {},
    next_session = 0,
    disposed = false,
    scope = Scope.new("workbench-calls-controller:" .. next_controller_id),
  }, Controller)
  local registered, register_err = self:_register_actions()
  if not registered then self:dispose(); return nil, register_err end
  return self
end

function Controller:_source(overrides)
  overrides = overrides or {}
  local tab = overrides.tab or vim.api.nvim_get_current_tabpage()
  local bufnr, win = overrides.bufnr, overrides.win
  if not real_buffer(bufnr) or not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    bufnr, win = current_editor(tab)
  end
  if not real_buffer(bufnr) or not win then
    return nil, nil, error_value("no_source_buffer", "call hierarchy requires a named, loaded editor buffer")
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

function Controller:_action_context(overrides)
  overrides = overrides or {}
  local tab = overrides.tab or vim.api.nvim_get_current_tabpage()
  local active = self.sessions[tab]
  local bufnr, win = self:_source({
    bufnr = overrides.bufnr or (active and active.bufnr),
    win = overrides.win or (active and active.source_win),
    tab = tab,
  })
  local workspace = overrides.workspace or (active and active.workspace) or self.get_workspace()
  return vim.tbl_extend("force", {
    controller = self,
    actions = self.actions,
    workspace = workspace,
    bufnr = bufnr,
    win = win,
    calls = active,
    capability = workspace and bufnr and self:_capability(bufnr, PREPARE) or nil,
  }, overrides)
end

function Controller:_register(action)
  return self.actions:register(action, { scope = self.scope })
end

function Controller:_register_actions()
  local controller = self
  local handle, err = self:_register({
    id = "calls.hierarchy",
    title = "Open call hierarchy",
    category = "Symbols",
    scope = "buffer",
    available = function(ctx)
      if type(ctx.workspace) ~= "table" then return { enabled = false, code = "no_workspace", reason = "no workbench workspace is active" } end
      if not real_buffer(ctx.bufnr) then return { enabled = false, code = "no_source_buffer", reason = "a named, loaded editor buffer is required" } end
      local capability = controller:_capability(ctx.bufnr, PREPARE)
      return { enabled = capability.state == "ready", code = capability.code or capability.state, reason = capability.reason }
    end,
    run = function(ctx, args)
      return controller:open(ctx.workspace, ctx.bufnr, ctx.win, { direction = args and args.direction })
    end,
    args_schema = {
      type = "object",
      properties = { direction = { type = "string", enum = { "incoming", "outgoing" } } },
      additional_properties = false,
    },
  })
  if not handle then return nil, err end
  return true
end

function Controller:_new_session(workspace, bufnr, win, tab, direction)
  local previous = self.sessions[tab]
  if previous then
    if previous.view and not previous.view.closed then self.layout:close("workbench-calls", tab) end
    self:_dispose_session(previous)
  end
  self.next_session = self.next_session + 1
  local scope, scope_err = self.scope:child("session:" .. self.next_session .. ":tab:" .. tostring(tab))
  if not scope then return nil, scope_err end
  local active = {
    id = "calls-" .. self.id .. "-" .. self.next_session,
    workspace = copy(workspace),
    workspace_generation = workspace.generation,
    tab = tab,
    bufnr = bufnr,
    source_win = win,
    source_version = vim.api.nvim_buf_get_changedtick(bufnr),
    scope = scope,
    view = nil,
    roots = {},
    nodes = {},
    requests = {},
    direction = direction == "incoming" and "incoming" or "outgoing",
    direction_epoch = 1,
    generation = 0,
    edge_count = 0,
    phase = "Ready",
    notice = nil,
    navigation_id = nil,
    origin = nil,
    disposed = false,
    cleaned = false,
  }
  scope:defer(function() self:_cleanup_session(active) end, "calls-session:" .. active.id, "session")
  self.sessions[tab] = active
  return active
end

function Controller:_cancel_request(active, key, reason)
  local record = active.requests[key]
  if not record then return false end
  active.requests[key] = nil
  record.cancelled = true
  if record.scope and record.scope.alive then record.scope:dispose() end
  return true
end

function Controller:_cancel_expansions(active, reason)
  local keys = {}
  for key in pairs(active.requests) do if key ~= "prepare" then keys[#keys + 1] = key end end
  for _, key in ipairs(keys) do self:_cancel_request(active, key, reason) end
end

function Controller:_cancel_descendant_requests(active, node, reason)
  for _, child in ipairs(node.children or {}) do
    if not child.notice then
      self:_cancel_descendant_requests(active, child, reason)
      if active.requests[child.id] then
        self:_cancel_request(active, child.id, reason)
        child.expansion = "idle"
        self:_remove_notice(child, "loading")
      end
    end
  end
end

function Controller:_cancel_all(active, reason)
  local keys = {}
  for key in pairs(active.requests) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do self:_cancel_request(active, key, reason) end
end

function Controller:_cleanup_session(active)
  if not active or active.cleaned then return false end
  active.cleaned = true
  active.disposed = true
  active.generation = active.generation + 1
  self:_cancel_all(active, "call hierarchy session disposed")
  if self.sessions[active.tab] == active then self.sessions[active.tab] = nil end
  return true
end

function Controller:_dispose_session(active)
  if not active or active.disposed then return false end
  self:_cleanup_session(active)
  if active.scope.alive then active.scope:dispose() end
  return true
end

function Controller:_help(active)
  return {
    "Space/l: expand lazily or collapse · j/k: move",
    "I/O: incoming/outgoing · o: open source · R: return · x: cancel · q: close",
    "Call items remain tied to their original LSP client; no whole-graph request is made.",
  }
end

function Controller:_mount(active, focus)
  if active.view and not active.view.closed then return active.view end
  local expanded = {}
  for _, node in ipairs(active.roots) do expanded[node.id] = false end
  local view, view_err = self.layout:mount({
    id = "workbench-calls",
    title = "Call hierarchy",
    kind = "tree",
    placement = "results",
    focus = focus ~= false,
    expanded = expanded,
    model = self:_model(active),
    help_lines = self:_help(active),
    keymaps = {
      ["I"] = { desc = "Workbench: incoming calls", run = function() self:set_direction(active, "incoming") end },
      ["O"] = { desc = "Workbench: outgoing calls", run = function() self:set_direction(active, "outgoing") end },
      ["o"] = { desc = "Workbench: open selected call location", run = function() self:open_selected(active) end },
      ["R"] = { desc = "Workbench: return to call hierarchy origin", run = function() self:return_to_origin(active) end },
      ["x"] = { desc = "Workbench: cancel pending call requests", run = function() self:cancel(active) end },
    },
    on_select = function(id, row, committed) if committed then return self:open_selected(active, id) end end,
    on_toggle = function(id, opening) return self:_toggle(active, id, opening) end,
    on_dispose = function() active.view = nil; self:_dispose_session(active) end,
  })
  if not view then return nil, view_err end
  active.view = view
  return view
end

function Controller:_row(node)
  if node.notice then
    return {
      id = node.id,
      parent_id = node.parent_id,
      kind = "notice",
      label = short(node.label, 220),
      selectable = false,
    }
  end
  local detail = node.call_item.detail
  local path = location_detail(node.location)
  if path then detail = (detail and (short(detail, 100) .. " · ") or "") .. path end
  if node.cycle then detail = (detail and (detail .. " · ") or "") .. "cycle detected" end
  if node.depth >= self.max_depth and not node.cycle then detail = (detail and (detail .. " · ") or "") .. "depth cap" end
  if node.expansion == "loading" then detail = (detail and (detail .. " · ") or "") .. "loading calls…" end
  return {
    id = node.id,
    parent_id = node.parent_id,
    kind = "call",
    label = short(node.call_item.name or "Call", 220) .. (node.cycle and " ↻" or ""),
    detail = detail and short(detail, 220) or nil,
    location = node.location,
    expandable = not node.cycle and node.depth < self.max_depth
      and (node.expansion == "idle" or node.expansion == "loading" or node.expansion == "error"),
    payload = { client_id = node.client_id, direction = node.direction, cycle = node.cycle },
  }
end

function Controller:_append_rows(items, node)
  items[#items + 1] = self:_row(node)
  for _, child in ipairs(node.children or {}) do self:_append_rows(items, child) end
end

function Controller:_model(active)
  local items = {}
  for _, root in ipairs(active.roots) do self:_append_rows(items, root) end
  local status = active.phase == "Preparing" and #items == 0 and "running"
    or active.phase == "Unavailable" and #items == 0 and "unavailable"
    or active.phase == "Error" and #items == 0 and "error" or #items == 0 and "empty" or "ready"
  local header = {
    "Direction: " .. (active.direction == "incoming" and "Incoming (I)" or "Outgoing (O)"),
    string.format("State: %s · %d root%s · %d/%d expanded edge%s", active.phase,
      #active.roots, #active.roots == 1 and "" or "s", active.edge_count, self.max_edges, active.edge_count == 1 and "" or "s"),
  }
  if active.notice then header[#header + 1] = short(active.notice, 200) end
  if active.phase == "Complete" and #active.roots == 0 then header[#header + 1] = "No call hierarchy items at the source position." end
  return { status = status, title = "Call hierarchy", header = header, items = items,
    error = active.phase == "Error" and active.notice or nil }
end

function Controller:_render(active)
  if not active.view or active.view.closed then return false end
  local okay, err = active.view:update(self:_model(active))
  if not okay then active.last_error = err end
  return okay ~= nil
end

function Controller:_remove_children(active, node)
  for _, child in ipairs(node.children or {}) do
    if active.nodes[child.id] then self:_remove_children(active, child); active.nodes[child.id] = nil end
  end
  node.children = {}
end

function Controller:_remove_notices(node)
  local keep = {}
  for _, child in ipairs(node.children or {}) do if not child.notice then keep[#keep + 1] = child end end
  node.children = keep
end

function Controller:_remove_notice(node, suffix)
  local id = node.id .. ":notice:" .. suffix
  local keep = {}
  for _, child in ipairs(node.children or {}) do if child.id ~= id then keep[#keep + 1] = child end end
  node.children = keep
end

local function call_child_count(node)
  local count = 0
  for _, child in ipairs(node.children or {}) do if not child.notice then count = count + 1 end end
  return count
end

function Controller:_notice(active, node, label, suffix)
  local id = node.id .. ":notice:" .. (suffix or hash(label))
  for _, existing in ipairs(node.children) do if existing.id == id then existing.label = label; return existing end end
  local notice = { id = id, parent_id = node.id, label = label, notice = true }
  node.children[#node.children + 1] = notice
  return notice
end

function Controller:_node_for_item(active, item, parent, location, range_index)
  local call_item = item.payload and item.payload.call_item
  local client_id = item.payload and item.payload.client_id
  if type(call_item) ~= "table" or type(client_id) ~= "number" or not location then return nil end
  local path_key = symbol_key(call_item)
  local cycle = parent.ancestors[path_key] == true
  local seed = table.concat({ parent.id, item.id, tostring(range_index or 0) }, "\0")
  local id = "call:" .. hash(seed)
  local collision = 1
  while active.nodes[id] do
    collision = collision + 1
    id = "call:" .. hash(seed) .. ":" .. collision
  end
  local ancestors = copy(parent.ancestors)
  ancestors[path_key] = true
  local node = {
    id = id,
    parent_id = parent.id,
    call_item = copy(call_item),
    client_id = client_id,
    location = copy(location),
    depth = parent.depth + 1,
    ancestors = ancestors,
    cycle = cycle,
    direction = parent.direction,
    expansion = "idle",
    children = {},
    source_call_range = item.payload.call_ranges and item.payload.call_ranges[range_index],
    edge_item_id = item.id,
  }
  active.nodes[id] = node
  if active.view then active.view.expanded[id] = false end
  return node
end

function Controller:_accept_edge_batch(active, parent, event)
  for _, item in ipairs(event.items or {}) do
    if active.edge_count >= self.max_edges then
      active.capped = true
      parent.expansion = "partial"
      self:_remove_notice(parent, "loading")
      self:_notice(active, parent, string.format("Result cap reached (%d edges)", self.max_edges), "result-cap")
      return false
    end
    local call_item = item.payload and item.payload.call_item
    if type(call_item) ~= "table" then
      self:_notice(active, parent, "A server returned a malformed call item", "invalid-item")
    else
      local ranges = item.payload.call_ranges or {}
      local count = math.max(1, #ranges)
      for range_index = 1, count do
        if call_child_count(parent) >= self.max_children or active.edge_count >= self.max_edges then
          parent.child_cap = true
          parent.expansion = "partial"
          self:_remove_notice(parent, "loading")
          self:_notice(active, parent,
            string.format("Showing at most %d call edges; this server has no call-hierarchy paging", self.max_children), "child-cap")
          active.capped = active.edge_count >= self.max_edges
          return false
        end
        local location = item.location
        if active.direction == "incoming" and ranges[range_index] then
          location = range_to_location(item, ranges[range_index])
        end
        local node = self:_node_for_item(active, item, parent, location, range_index)
        if node then
          self:_remove_notice(parent, "loading")
          parent.children[#parent.children + 1] = node
          active.edge_count = active.edge_count + 1
        else
          self:_notice(active, parent, "A server returned a call item without a usable file location", "invalid-location")
        end
      end
      if #ranges > self.max_children then
        parent.child_cap = true
        self:_notice(active, parent,
          string.format("Showing at most %d call edges; this server has no call-hierarchy paging", self.max_children), "child-cap")
        return false
      end
    end
  end
  return true
end

function Controller:_finish_request(active, key, record)
  if active.requests[key] ~= record then return false end
  active.requests[key] = nil
  if record.scope and record.scope.alive then record.scope:dispose() end
  return true
end

function Controller:_request(active, key, method, result_kind, params, client_ids, direction, max_items)
  local request_scope, scope_err = active.scope:child("request:" .. key)
  if not request_scope then return nil, scope_err end
  local record = {
    scope = request_scope,
    generation = active.generation,
    direction_epoch = active.direction_epoch,
    method = method,
  }
  active.requests[key] = record
  local controller = self
  local request, start_err = self.provider:start({
    bufnr = active.bufnr,
    method = method,
    params = params,
    result_kind = result_kind,
    client_ids = client_ids,
    direction = direction,
    max_items = max_items,
    workspace = active.workspace,
    workspace_id = active.workspace.id,
    workspace_generation = active.workspace_generation,
    generation = active.generation,
    session_id = active.id .. ":" .. key .. ":" .. active.generation .. ":" .. active.direction_epoch,
    is_current = function()
      return not active.disposed and active.scope.alive and active.requests[key] == record
        and active.generation == record.generation and active.workspace.generation == active.workspace_generation
        and (key == "prepare" or active.direction_epoch == record.direction_epoch)
        and vim.api.nvim_buf_is_valid(active.bufnr)
        and vim.api.nvim_buf_get_changedtick(active.bufnr) == active.source_version
    end,
  }, function(event) controller:_on_event(active, key, record, event) end)
  if not request then
    active.requests[key] = nil
    request_scope:dispose()
    return nil, start_err
  end
  record.handle = request
  local _, defer_err = request_scope:defer(function() request:dispose() end, "lsp-call-request:" .. key, "lsp-request")
  if defer_err then
    active.requests[key] = nil
    request_scope:dispose()
    return nil, defer_err
  end
  return request
end

function Controller:_on_event(active, key, record, event)
  if active.disposed or not active.scope.alive or active.requests[key] ~= record
    or active.generation ~= record.generation or active.direction_epoch ~= record.direction_epoch and key ~= "prepare"
    or type(event) ~= "table" or event.generation ~= active.generation then
    return false
  end
  if key == "prepare" then
    if event.kind == "batch" then
      for _, item in ipairs(event.items or {}) do
        local call_item = item.payload and item.payload.call_item
        if type(call_item) == "table" and item.location and item.payload.client_id then
          local root_key = symbol_key(call_item)
          local root = {
            id = "call:root:" .. hash(item.id .. "\0" .. tostring(#active.roots + 1)),
            call_item = copy(call_item),
            client_id = item.payload.client_id,
            location = copy(item.location),
            depth = 0,
            ancestors = { [root_key] = true },
            direction = active.direction,
            expansion = "idle",
            children = {},
          }
          active.roots[#active.roots + 1] = root
          active.nodes[root.id] = root
          if active.view then active.view.expanded[root.id] = false end
        end
      end
      self:_render(active)
    elseif event.kind == "done" then
      self:_finish_request(active, key, record)
      if event.status == "complete" then active.phase = "Complete"
      elseif event.status == "partial" then active.phase = "Partial"; active.notice = event.error and event.error.message or "Some language servers did not return call items"
      elseif event.status == "cancelled" then active.phase = "Cancelled"
      else active.phase = "Error"; active.notice = event.error and event.error.message or "Call hierarchy preparation failed" end
      self:_render(active)
    end
    return true
  end

  local node = active.nodes[key]
  if not node then return false end
  if event.kind == "batch" then
    self:_accept_edge_batch(active, node, event)
    if not node.child_cap and not active.capped then node.expansion = "loading" end
    self:_render(active)
    if node.child_cap or active.capped then self:_cancel_request(active, key, "call hierarchy result cap reached") end
  elseif event.kind == "done" then
    self:_finish_request(active, key, record)
    if record.cancelled then return false end
    self:_remove_notice(node, "loading")
    if event.status == "complete" then
      node.expansion = #node.children == 0 and "empty" or "complete"
    elseif event.status == "partial" then
      node.expansion = "partial"
      local message = event.error and event.error.message or "Some call edges could not be read"
      self:_notice(active, node, "Partial result: " .. short(message, 144), "partial")
    elseif event.status == "cancelled" then
      node.expansion = "idle"
      self:_remove_notices(node)
    else
      node.expansion = "error"
      local message = event.error and event.error.message or "Call expansion failed"
      self:_notice(active, node, "Error: " .. short(message, 160), "error")
    end
    self:_render(active)
  end
  return true
end

function Controller:_start_prepare(active)
  local capability = self:_capability(active.bufnr, PREPARE)
  if capability.state ~= "ready" then
    active.phase = "Unavailable"
    active.notice = capability.reason or "call hierarchy is not supported by an attached language server"
    self:_render(active)
    return nil, error_value(capability.code or "unsupported_method", active.notice)
  end
  if type(vim.lsp.util.make_position_params) ~= "function" then
    active.phase = "Error"
    active.notice = "Neovim cannot build LSP position parameters"
    self:_render(active)
    return nil, error_value("position_params_unavailable", active.notice)
  end
  local params_by_client = {}
  local client_ids = {}
  for _, client in ipairs(capability.clients or {}) do
    local okay, params = pcall(vim.lsp.util.make_position_params, active.source_win, client.encoding)
    if okay and type(params) == "table" then
      params_by_client[client.id] = params
      client_ids[#client_ids + 1] = client.id
    end
  end
  if next(params_by_client) == nil then
    active.phase = "Error"
    active.notice = "Neovim could not capture the source position for an attached LSP client"
    self:_render(active)
    return nil, error_value("position_params_failed", active.notice)
  end
  active.phase = "Preparing"
  active.generation = active.generation + 1
  active.navigation_id = active.id .. ":navigation:" .. active.generation
  active.origin = capture_origin(active.bufnr, active.source_win, active.navigation_id)
  active.source_version = vim.api.nvim_buf_get_changedtick(active.bufnr)
  self:_render(active)
  local request, start_err = self:_request(active, "prepare", PREPARE, "call_item", function(client)
    local params = params_by_client[client.id]
    return params and copy(params) or nil
  end, client_ids, nil, nil)
  if not request then
    active.phase = "Error"
    active.notice = start_err and start_err.message or "call hierarchy preparation could not start"
    self:_render(active)
    return nil, start_err
  end
  return request
end

function Controller:open(workspace, bufnr, win, opts)
  opts = opts or {}
  if self.disposed then return nil, error_value("controller_disposed", "Calls controller is disposed") end
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or type(workspace.generation) ~= "number" then
    return nil, error_value("no_workspace", "call hierarchy requires an active Workbench workspace")
  end
  if not real_buffer(bufnr) or not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    local source_err
    bufnr, win, source_err = self:_source(opts)
    if not bufnr then return nil, source_err end
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local active, session_err = self:_new_session(workspace, bufnr, win, tab, opts.direction)
  if not active then return nil, session_err end
  local view, view_err = self:_mount(active, opts.focus)
  if not view then self:_dispose_session(active); return nil, view_err end
  local request, start_err = self:_start_prepare(active)
  if not request then return view, start_err end
  return view, active
end

function Controller:_toggle(active, id, opening)
  local node = active.nodes[id]
  if not node then return false end
  if not opening then
    self:_cancel_descendant_requests(active, node, "ancestor call branch collapsed")
    if active.requests[id] then
      self:_cancel_request(active, id, "call branch collapsed")
      node.expansion = "idle"
    end
    self:_remove_notice(node, "loading")
    self:_render(active)
    return true
  end
  if node.cycle or node.depth >= self.max_depth or node.expansion == "complete" or node.expansion == "partial"
    or node.expansion == "empty" or node.expansion == "loading" then
    return true
  end
  if active.edge_count >= self.max_edges then
    active.capped = true
    self:_notice(active, node, string.format("Result cap reached (%d edges)", self.max_edges), "result-cap")
    self:_render(active)
    return false
  end
  if not vim.api.nvim_buf_is_valid(active.bufnr) or vim.api.nvim_buf_get_changedtick(active.bufnr) ~= active.source_version then
    node.expansion = "error"
    self:_notice(active, node, "Source document changed; reopen call hierarchy to refresh", "stale-source")
    self:_render(active)
    return nil, error_value("stale_document", "source document changed after call hierarchy preparation")
  end
  self:_remove_notices(node)
  node.expansion = "loading"
  self:_notice(active, node, "Loading calls…", "loading")
  self:_render(active)
  local method = METHODS[active.direction]
  local capability = self:_capability(active.bufnr, method, { node.client_id })
  if capability.state ~= "ready" then
    node.expansion = "error"
    self:_remove_notices(node)
    self:_notice(active, node, "Unavailable: " .. short(capability.reason or "originating LSP client detached", 160), "unavailable")
    self:_render(active)
    return nil, error_value(capability.code or "unsupported_method", capability.reason or "call hierarchy expansion is unavailable")
  end
  node.direction = active.direction
  local request, start_err = self:_request(active, id, method, "call_edge", function()
    return { item = copy(node.call_item) }
  end, { node.client_id }, active.direction, self.max_children + 1)
  if not request then
    node.expansion = "error"
    self:_remove_notices(node)
    self:_notice(active, node, "Error: " .. short(start_err and start_err.message or "call request could not start", 160), "start-error")
    self:_render(active)
    return nil, start_err
  end
  return request
end

function Controller:set_direction(active, direction)
  if not active or active.disposed or (direction ~= "incoming" and direction ~= "outgoing") then
    return nil, error_value("invalid_direction", "direction must be incoming or outgoing")
  end
  if active.direction == direction then return false end
  active.direction = direction
  active.direction_epoch = active.direction_epoch + 1
  self:_cancel_expansions(active, "call hierarchy direction changed")
  active.edge_count = 0
  active.capped = false
  for _, root in ipairs(active.roots) do
    self:_remove_children(active, root)
    root.direction = direction
    root.expansion = "idle"
    if active.view then active.view.expanded[root.id] = false end
  end
  active.notice = nil
  active.phase = "Ready"
  self:_render(active)
  return true
end

function Controller:open_selected(active, id)
  if not active or active.disposed then return nil, error_value("session_unavailable", "call hierarchy session is no longer active") end
  id = id or (active.view and active.view.selected_id)
  local node = id and active.nodes[id]
  if not node or not node.location then return nil, error_value("location_unavailable", "select a call item with a source location first") end
  return self.navigation:open(node.location, "split", active.origin, active.navigation_id)
end

function Controller:return_to_origin(active)
  if not active or not active.navigation_id then return nil, error_value("origin_unavailable", "there is no call hierarchy navigation origin") end
  return self.navigation:return_to_origin(active.navigation_id)
end

function Controller:cancel(active)
  if not active then return false end
  local count = 0
  if active.requests.prepare then
    active.generation = active.generation + 1
    if self:_cancel_request(active, "prepare", "call hierarchy preparation cancelled") then count = count + 1 end
    active.phase = "Cancelled"
  end
  local keys = {}
  for key in pairs(active.requests) do if key ~= "prepare" then keys[#keys + 1] = key end end
  for _, key in ipairs(keys) do
    local node = active.nodes[key]
    if self:_cancel_request(active, key, "call hierarchy expansion cancelled") then count = count + 1 end
    if node then node.expansion = "idle"; self:_remove_notices(node) end
  end
  if count > 0 then self:_render(active) end
  return count > 0
end

function Controller:status()
  local sessions = {}
  for tab, active in pairs(self.sessions) do
    if not active.disposed then
      local pending = 0
      for _ in pairs(active.requests) do pending = pending + 1 end
      sessions[#sessions + 1] = {
        tab = tab,
        direction = active.direction,
        phase = active.phase,
        roots = #active.roots,
        edges = active.edge_count,
        pending_requests = pending,
        view = active.view ~= nil and not active.view.closed,
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
  local sessions = {}
  for _, active in pairs(self.sessions) do sessions[#sessions + 1] = active end
  for _, active in ipairs(sessions) do
    if active.view and not active.view.closed then self.layout:close("workbench-calls", active.tab) end
    self:_dispose_session(active)
  end
  self.sessions = {}
  self.scope:dispose()
  if self.owns_actions then self.actions = nil end
  return true
end

return M
