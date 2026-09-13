local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")
local Location = require("workbench.core.location")

local M = {}
local Provider = {}
Provider.__index = Provider

local DEFAULTS = {
  max_active_requests = 8,
  max_items = 2000,
  max_batch_items = 64,
  max_result_bytes = 8 * 1024 * 1024,
  max_errors = 16,
  request_timeout_ms = 15000,
  max_items_per_slice = 128,
  max_slice_ms = 4,
}

local HARD_MAX = {
  max_active_requests = 32,
  max_items = 10000,
  max_batch_items = 512,
  max_result_bytes = 32 * 1024 * 1024,
  max_errors = 64,
  request_timeout_ms = 120000,
  max_items_per_slice = 2048,
  max_slice_ms = 16,
}

local MAX_RENAME_WORKSPACE_EDIT_BYTES = 256 * 1024

local next_provider_id = 0
local create_autocmds

local SUPPORTED_RESULT_KINDS = {
  auto = true,
  location = true,
  symbol = true,
  call_item = true,
  call_edge = true,
  raw = true,
}

local function error_value(code, message, extra)
  local result = { code = code, message = message }
  if type(extra) == "table" then
    for key, value in pairs(extra) do result[key] = value end
  end
  return result
end

local function positive_integer(value)
  return type(value) == "number" and value % 1 == 0 and value > 0
end

local function option(opts, name)
  local value = opts[name]
  if value == nil then return DEFAULTS[name] end
  if not positive_integer(value) then return nil, name .. " must be a positive integer" end
  return math.min(value, HARD_MAX[name])
end

local function bounded_text(value, limit)
  if type(value) ~= "string" then return nil end
  value = Resource.escape_display(value)
  if #value > limit then return value:sub(1, limit - 3) .. "..." end
  return value
end

local function estimate_size(value, remaining, depth)
  if remaining <= 0 then return nil end
  depth = depth or 0
  if depth > 16 then return nil end
  local kind = type(value)
  if kind == "string" then
    if #value > remaining then return nil end
    return #value + 2
  elseif kind == "number" or kind == "boolean" then
    return 8
  elseif kind ~= "table" then
    return 1
  end

  local size, entries = 2, 0
  for key, child in pairs(value) do
    entries = entries + 1
    if entries > 4096 then return nil end
    local key_size = estimate_size(key, remaining - size, depth + 1)
    if not key_size then return nil end
    size = size + key_size
    local child_size = estimate_size(child, remaining - size, depth + 1)
    if not child_size then return nil end
    size = size + child_size
    if size > remaining then return nil end
  end
  return size
end

local function method_supports(client, method, bufnr)
  if type(client) ~= "table" or type(client.supports_method) ~= "function" then return false end
  local ok, supported = pcall(client.supports_method, client, method, bufnr)
  return ok and supported == true
end

local function normalize_range(range)
  if type(range) ~= "table" or type(range.start) ~= "table" then return nil end
  local finish = range["end"] or range.finish
  if type(finish) ~= "table" then return nil end
  return {
    start = { line = range.start.line, character = range.start.character },
    finish = { line = finish.line, character = finish.character },
  }
end

local function result_kind_for(request)
  if request.result_kind ~= "auto" then return request.result_kind end
  if request.method == "textDocument/documentSymbol" or request.method == "workspace/symbol"
    or request.method == "workspaceSymbol/resolve" then
    return "symbol"
  end
  if request.method == "textDocument/prepareCallHierarchy" then return "call_item" end
  if request.method == "callHierarchy/incomingCalls" or request.method == "callHierarchy/outgoingCalls" then return "call_edge" end
  return "location"
end

local function location_parts(raw, kind)
  if type(raw) ~= "table" then return nil, "LSP result item must be an object" end
  local uri, range, name, detail, shape
  if type(raw.targetUri) == "string" then
    uri = raw.targetUri
    range = raw.targetSelectionRange or raw.targetRange
    shape = "location_link"
  elseif type(raw.location) == "table" then
    local nested = raw.location
    uri = nested.uri or nested.targetUri
    range = nested.range or nested.targetSelectionRange or nested.targetRange
    shape = type(nested.targetUri) == "string" and "location_link" or "symbol_information"
  elseif type(raw.uri) == "string" then
    uri = raw.uri
    range = raw.selectionRange or raw.range
    shape = "location"
  else
    return nil, "LSP result item has no supported URI/location"
  end

  if kind == "symbol" or type(raw.name) == "string" then
    name = raw.name
    detail = raw.detail or raw.containerName
  end
  if range ~= nil and not normalize_range(range) then
    return nil, "LSP result has an invalid range"
  end
  return {
    uri = uri,
    range = range,
    name = name,
    detail = detail,
    shape = shape,
  }
end

local function make_location(uri, range, client, request, source_uri)
  if type(uri) ~= "string" then return nil, error_value("invalid_uri", "LSP result URI must be a string") end
  local resource, resource_err = Resource.from_uri(uri, { workspace_id = request.workspace_id })
  if not resource then return nil, error_value("invalid_uri", resource_err or "LSP result URI is invalid") end
  if resource.scheme ~= "file" or type(resource.path) ~= "string" then
    return nil, error_value("unsupported_uri_scheme", "LSP result uses an unsupported virtual URI scheme: " .. resource.scheme, { uri = uri })
  end

  local normalized_range = normalize_range(range)
  if range ~= nil and not normalized_range then
    return nil, error_value("invalid_range", "LSP result range is malformed", { uri = uri })
  end
  local encoding = client.offset_encoding
  local opts = {
    client_id = client.id,
    version = uri == source_uri and request.document_version or nil,
  }
  if normalized_range then
    opts.range = normalized_range
    opts.encoding = encoding
  end
  local location, location_err = Location.new(resource, opts)
  if not location then
    return nil, error_value("invalid_location", location_err, { uri = uri })
  end
  return location
end

local function stable_id(client_id, uri, name, range, ordinal)
  local start = range and range.start or {}
  local finish = range and (range["end"] or range.finish) or {}
  local seed = table.concat({
    tostring(client_id), uri, name or "", tostring(start.line or ""), tostring(start.character or ""),
    tostring(finish.line or ""), tostring(finish.character or ""), tostring(ordinal or ""),
  }, "\0")
  local first, second = 2166136261, 5381
  for index = 1, #seed do
    local byte = seed:byte(index)
    first = (first * 33 + byte) % 4294967291
    second = (second * 65599 + byte) % 4294967279
  end
  return "lsp:" .. tostring(client_id) .. ":" .. string.format("%08x%08x", first, second)
end

local function source_uri(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  local ok, uri = pcall(vim.uri_from_bufnr, bufnr)
  return ok and uri or nil
end

local function request_is_current(provider, state)
  if state.terminal or not state.scope.alive then return false, "cancelled" end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then return false, "buffer_closed" end
  local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, state.bufnr)
  if not ok or changedtick ~= state.document_version then return false, "document_changed" end

  if type(state.request.is_current) == "function" then
    local valid_ok, valid = pcall(state.request.is_current, state.request)
    if not valid_ok or valid ~= true then return false, "workspace_changed" end
  elseif type(state.request.workspace) == "table"
    and state.request.workspace.generation ~= nil
    and state.request.workspace.generation ~= state.workspace_generation then
    return false, "workspace_changed"
  end
  return true
end

local function client_is_attached(provider, state, client_id)
  local clients = provider:_read_clients(state.bufnr)
  if not clients then return false end
  for _, client in ipairs(clients) do
    if client.id == client_id then return true end
  end
  return false
end

local function safe_sink(state, event)
  if type(state.sink) ~= "function" then return end
  local ok, err = pcall(state.sink, event)
  if not ok and not state.sink_error then state.sink_error = bounded_text(err, 384) end
end

local maybe_finish, cancel_state, finish_request

local function request_error(state, client, code, message, extra)
  if #state.errors >= state.provider.limits.max_errors then return end
  local item = {
    code = code,
    message = bounded_text(message, 384) or "LSP request failed",
    client_id = client and client.id or nil,
    client_name = client and bounded_text(client.name, 128) or nil,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do item[key] = value end
  end
  state.errors[#state.errors + 1] = item
end

local function close_timeout(record)
  if not record.timeout_handle then return false end
  local handle = record.timeout_handle
  record.timeout_handle = nil
  record.timer = nil
  handle:dispose()
  return true
end

local function arm_timeout(state, record)
  local uv = vim.uv or vim.loop
  if not uv or type(uv.new_timer) ~= "function" then
    return nil, error_value("timeout_unavailable", "Neovim does not provide an LSP request timer")
  end
  local ok, timer = pcall(uv.new_timer)
  if not ok or not timer then
    return nil, error_value("timeout_setup_failed", tostring(timer or "could not create LSP request timer"))
  end
  local handle, defer_error = state.scope:defer(function()
    pcall(timer.stop, timer)
    if not timer:is_closing() then timer:close() end
  end, "lsp-timeout:" .. tostring(record.client.id), "timer")
  if not handle then
    pcall(timer.close, timer)
    return nil, error_value("timeout_setup_failed", defer_error and defer_error.message or "could not own LSP request timer")
  end
  record.timer = timer
  record.timeout_handle = handle
  local started, start_error = pcall(timer.start, timer, state.provider.limits.request_timeout_ms, 0, function()
    local ticket = state.scope:schedule(function()
      record.timeout_ticket = nil
      close_timeout(record)
      if state.terminal or record.completed or record.received then return end
      if record.request_id ~= nil and type(record.client.cancel_request) == "function" then
        pcall(record.client.cancel_request, record.client, record.request_id)
      end
      record.completed = true
      request_error(state, record.client, "timeout", "LSP request exceeded the configured timeout", {
        timeout_ms = state.provider.limits.request_timeout_ms,
      })
      maybe_finish(state)
    end)
    if ticket then record.timeout_ticket = ticket end
  end)
  if not started then
    close_timeout(record)
    return nil, error_value("timeout_setup_failed", tostring(start_error))
  end
  return true
end

local function flush_batch(state, client_id)
  if #state.batch == 0 then return end
  local items = state.batch
  state.batch = {}
  safe_sink(state, {
    kind = "batch",
    generation = state.generation,
    session_id = state.session_id,
    client_id = client_id,
    document_version = state.document_version,
    workspace_generation = state.workspace_generation,
    items = items,
  })
end

local function add_item(state, client, item)
  local estimate = estimate_size(item, state.provider.limits.max_result_bytes - state.result_bytes)
  if state.item_count >= state.max_items or not estimate
    or state.result_bytes + estimate > state.provider.limits.max_result_bytes then
    state.truncated = true
    request_error(state, client, "result_limit", "LSP result exceeded the configured item or payload limit")
    return false
  end

  state.item_count = state.item_count + 1
  state.result_bytes = state.result_bytes + estimate
  state.batch[#state.batch + 1] = item
  if #state.batch >= state.provider.limits.max_batch_items then flush_batch(state, client.id) end
  return true
end

local function opaque_data(raw, state, client)
  if raw.data == nil then return nil end
  local size = estimate_size(raw.data, state.provider.limits.max_result_bytes - state.result_bytes)
  if not size then
    state.truncated = true
    request_error(state, client, "result_limit", "LSP opaque symbol data exceeded the configured payload limit")
    return nil
  end
  return vim.deepcopy(raw.data)
end

local function make_item(state, client, raw, ordinal, parent_id, forced_name)
  local kind = result_kind_for(state.request)
  if kind == "call_item" or kind == "call_edge" then
    local call_item, call_ranges, direction = raw, {}, nil
    if kind == "call_edge" then
      direction = state.request.direction
      local target_key = direction == "incoming" and "from" or direction == "outgoing" and "to" or nil
      if not target_key then
        request_error(state, client, "invalid_direction", "call hierarchy edge requests require incoming or outgoing direction", { ordinal = ordinal })
        return nil
      end
      call_item = type(raw) == "table" and raw[target_key] or nil
      call_ranges = type(raw) == "table" and raw.fromRanges or nil
      if type(call_ranges) ~= "table" then
        request_error(state, client, "invalid_call_ranges", "call hierarchy edges require a fromRanges array", { ordinal = ordinal })
        return nil
      end
    end
    if type(call_item) ~= "table" or type(call_item.name) ~= "string" or type(call_item.uri) ~= "string"
      or type(call_item.selectionRange) ~= "table" or not normalize_range(call_item.selectionRange)
      or type(call_item.range) ~= "table" or not normalize_range(call_item.range) then
      request_error(state, client, "invalid_call_item", "call hierarchy item requires a name, URI and valid ranges", { ordinal = ordinal })
      return nil
    end
    local normalized_ranges = {}
    for range_index, range in ipairs(call_ranges) do
      if range_index > state.max_items then break end
      local normalized = normalize_range(range)
      if not normalized then
        request_error(state, client, "invalid_call_range", "call hierarchy fromRanges contains a malformed range", { ordinal = ordinal, range = range_index })
        return nil
      end
      normalized_ranges[#normalized_ranges + 1] = normalized
    end
    local item_range = kind == "call_item" and call_item.selectionRange
      or direction == "incoming" and (call_ranges[1] or call_item.selectionRange)
      or call_item.selectionRange
    local location, location_err = make_location(call_item.uri, item_range, client, state, state.source_uri)
    if not location then
      request_error(state, client, location_err.code, location_err.message, { uri = call_item.uri, ordinal = ordinal })
      return nil
    end
    if not estimate_size(call_item, state.provider.limits.max_result_bytes - state.result_bytes) then
      state.truncated = true
      request_error(state, client, "result_limit", "call hierarchy item exceeded the configured payload limit", { ordinal = ordinal })
      return nil
    end
    local copied = vim.deepcopy(call_item)
    local name = bounded_text(call_item.name, 512) or "Call hierarchy item"
    local detail = bounded_text(call_item.detail, 1024)
    local payload = {
      method = state.method,
      client_id = client.id,
      buffer = state.bufnr,
      buffer_version = state.document_version,
      workspace_generation = state.workspace_generation,
      encoding = client.offset_encoding,
      shape = kind == "call_item" and "call_hierarchy_item" or "call_hierarchy_edge",
      call_item = copied,
      call_ranges = normalized_ranges,
      direction = direction,
      symbol_kind = type(call_item.kind) == "number" and call_item.kind or nil,
      tags = type(call_item.tags) == "table" and vim.deepcopy(call_item.tags) or nil,
    }
    return {
      id = stable_id(client.id, call_item.uri, name, item_range, ordinal),
      kind = "call",
      label = name,
      detail = detail,
      parent_id = parent_id,
      location = location,
      payload = payload,
    }
  end

  if kind == "raw" then
    local size = estimate_size(raw, state.provider.limits.max_result_bytes - state.result_bytes)
    if not size then
      state.truncated = true
      request_error(state, client, "result_limit", "LSP result exceeded the configured payload limit")
      return nil
    end
    local copied = vim.deepcopy(raw)
    local id = stable_id(client.id, "raw", tostring(ordinal), nil, ordinal)
    return {
      id = id,
      kind = "lsp",
      label = bounded_text(forced_name or raw.name or "LSP result", 256),
      parent_id = parent_id,
      payload = {
        method = state.method,
        client_id = client.id,
        buffer = state.bufnr,
        buffer_version = state.document_version,
        workspace_generation = state.workspace_generation,
        encoding = client.offset_encoding,
        value = copied,
      },
    }
  end

  -- LSP 3.17 permits a WorkspaceSymbol to omit its location when it can be
  -- resolved later. Keep the opaque resolver input and client provenance so
  -- discovery can resolve it without guessing which server produced it.
  local partial_location = type(raw) == "table" and type(raw.location) == "table"
    and type(raw.location.uri) == "string" and raw.location.range == nil
  if kind == "symbol" and state.method == "workspace/symbol"
    and type(raw) == "table" and type(raw.name) == "string"
    and ((raw.location == nil and type(raw.uri) ~= "string") or partial_location) then
    local copied_data = raw.data ~= nil and opaque_data(raw, state, client) or nil
    local resolve_item = {
      name = raw.name,
      kind = raw.kind,
      tags = type(raw.tags) == "table" and vim.deepcopy(raw.tags) or nil,
      containerName = raw.containerName,
      data = copied_data,
      location = partial_location and { uri = raw.location.uri } or nil,
    }
    local payload = {
      method = state.method,
      client_id = client.id,
      buffer = state.bufnr,
      buffer_version = state.document_version,
      workspace_generation = state.workspace_generation,
      encoding = client.offset_encoding,
      shape = "unresolved_workspace_symbol",
      symbol_kind = type(raw.kind) == "number" and raw.kind or nil,
      container_name = bounded_text(raw.containerName, 1024),
      data = copied_data,
      resolve_item = resolve_item,
    }
    if type(raw.tags) == "table" then payload.tags = vim.deepcopy(raw.tags) end
    local range = raw.range or raw.selectionRange
    return {
      id = stable_id(client.id, "workspace-symbol:" .. raw.name, raw.name, range, ordinal),
      kind = "symbol",
      label = bounded_text(raw.name, 512) or "Workspace symbol",
      detail = bounded_text(raw.containerName, 1024),
      parent_id = parent_id,
      payload = payload,
    }
  end

  local parts, parts_err = location_parts(raw, kind)
  if not parts then
    request_error(state, client, "invalid_result", parts_err, { ordinal = ordinal })
    return nil
  end
  local uri = parts.uri
  if type(uri) ~= "string" then
    request_error(state, client, "invalid_uri", "LSP result has no URI", { ordinal = ordinal })
    return nil
  end
  local location, location_err = make_location(uri, parts.range, client, state, state.source_uri)
  if not location then
    request_error(state, client, location_err.code, location_err.message, { uri = uri, ordinal = ordinal })
    return nil
  end

  local name = forced_name or parts.name or location.resource.display_path
  local payload = {
    method = state.method,
    client_id = client.id,
    buffer = state.bufnr,
    buffer_version = state.document_version,
    workspace_generation = state.workspace_generation,
    encoding = client.offset_encoding,
    shape = parts.shape,
  }
  if type(raw.kind) == "number" then payload.symbol_kind = raw.kind end
  if type(raw.tags) == "table" then payload.tags = vim.deepcopy(raw.tags) end
  if raw.deprecated ~= nil then payload.deprecated = raw.deprecated == true end
  if type(parts.detail) == "string" then payload.container_name = parts.detail end
  if type(raw.data) ~= "nil" then payload.data = opaque_data(raw, state, client) end
  if kind == "symbol" and state.method == "workspace/symbol" then
    payload.resolve_item = {
      name = raw.name,
      kind = raw.kind,
      tags = type(raw.tags) == "table" and vim.deepcopy(raw.tags) or nil,
      containerName = raw.containerName,
      data = payload.data,
      location = raw.location and vim.deepcopy(raw.location) or nil,
      uri = raw.uri,
      range = raw.range and vim.deepcopy(raw.range) or nil,
      selectionRange = raw.selectionRange and vim.deepcopy(raw.selectionRange) or nil,
    }
  end

  local range = parts.range
  if raw.selectionRange then payload.selection_range = vim.deepcopy(raw.selectionRange) end
  if raw.symbolRange then payload.symbol_range = vim.deepcopy(raw.symbolRange)
  elseif raw.range then payload.symbol_range = vim.deepcopy(raw.range) end
  if raw.targetRange then payload.target_range = vim.deepcopy(raw.targetRange) end
  if raw.originSelectionRange then payload.origin_selection_range = vim.deepcopy(raw.originSelectionRange) end

  return {
    id = stable_id(client.id, uri, name, range, ordinal),
    kind = kind == "symbol" and "symbol" or "location",
    label = bounded_text(name, 512) or location.resource.display_path,
    detail = bounded_text(parts.detail, 1024),
    parent_id = parent_id,
    location = location,
    payload = payload,
  }
end

local function normalization_walk(state, client, result)
  local walk = { stack = {}, ordinal = 0 }
  if result == nil or result == vim.NIL then return walk end
  if type(result) ~= "table" then
    request_error(state, client, "invalid_result", "LSP result must be an object or array")
    return walk
  end
  if next(result) == nil then return walk end
  local root = { parent_id = nil, uri = state.source_uri, depth = 1 }
  if type(result[1]) == "table" then
    root.values = result
    root.index = 1
  else
    root.single = result
    root.consumed = false
  end
  walk.stack[1] = root
  return walk
end

local function next_normalization_item(walk)
  while #walk.stack > 0 do
    local frame = walk.stack[#walk.stack]
    local value
    if frame.values then
      value = frame.values[frame.index]
      frame.index = frame.index + 1
    elseif not frame.consumed then
      frame.consumed = true
      value = frame.single
    end
    if value ~= nil then return value, frame.parent_id, frame.uri, frame.depth end
    walk.stack[#walk.stack] = nil
  end
  return nil
end

local function normalization_current(state, record)
  if state.terminal or record.completed then return false end
  local current, reason = request_is_current(state.provider, state)
  if not current then
    cancel_state(state, reason)
    return false
  end
  if not client_is_attached(state.provider, state, record.client.id) then
    record.completed = true
    request_error(state, record.client, "client_detached", "LSP client detached before its response was accepted")
    maybe_finish(state)
    return false
  end
  if not method_supports(record.client, state.method, state.bufnr) then
    record.completed = true
    request_error(state, record.client, "unsupported_method", "LSP method support changed before the response was accepted")
    maybe_finish(state)
    return false
  end
  return true
end

local function process_normalization_slice(state, record, walk, validate)
  if validate and not normalization_current(state, record) then return end
  local uv = vim.uv or vim.loop
  local started = uv.hrtime()
  local processed = 0
  local kind = result_kind_for(state.request)
  while not state.truncated and #walk.stack > 0 do
    if processed >= state.provider.limits.max_items_per_slice then break end
    if processed > 0 and (uv.hrtime() - started) / 1000000 >= state.provider.limits.max_slice_ms then break end
    local raw, parent_id, uri_for_document_symbol, depth = next_normalization_item(walk)
    if raw == nil then break end
    processed = processed + 1
    walk.ordinal = walk.ordinal + 1
    if depth > 32 then
      request_error(state, record.client, "nesting_limit", "LSP symbol nesting exceeded 32 levels")
    else
      local is_document_symbol = kind == "symbol" and state.method == "textDocument/documentSymbol"
        and type(raw) == "table" and type(raw.name) == "string"
        and type(raw.range) == "table" and type(raw.selectionRange) == "table"
      local item_raw = raw
      if is_document_symbol then
        item_raw = {
          name = raw.name,
          detail = raw.detail,
          kind = raw.kind,
          tags = raw.tags,
          deprecated = raw.deprecated,
          uri = uri_for_document_symbol,
          range = raw.selectionRange,
          selectionRange = raw.selectionRange,
          symbolRange = raw.range,
          data = raw.data,
        }
      end

      local item = make_item(state, record.client, item_raw, walk.ordinal, parent_id)
      local item_id = item and item.id
      if state.truncated then break end
      if item and not add_item(state, record.client, item) then break end
      if type(raw) == "table" and type(raw.children) == "table" then
        if not is_document_symbol then
          request_error(state, record.client, "invalid_symbol", "nested LSP symbols require DocumentSymbol ranges")
        elseif #raw.children > 0 then
          walk.stack[#walk.stack + 1] = {
            values = raw.children,
            index = 1,
            parent_id = item_id or parent_id,
            uri = uri_for_document_symbol,
            depth = depth + 1,
          }
        end
      end
    end
  end

  if state.terminal or record.completed then return end
  flush_batch(state, record.client.id)
  local slice_ms = (uv.hrtime() - started) / 1000000
  state.normalization_slices = state.normalization_slices + 1
  state.normalization_max_slice_ms = math.max(state.normalization_max_slice_ms, slice_ms)
  if state.terminal or record.completed then return end
  if state.truncated then
    finish_request(state, state.item_count > 0 and "partial" or "error", "result_limit", "LSP result limit reached")
  elseif #walk.stack == 0 then
    record.completed = true
    maybe_finish(state)
  else
    local ticket = state.scope:schedule(function()
      record.normalization_ticket = nil
      local ok, failure = xpcall(function() process_normalization_slice(state, record, walk, true) end, debug.traceback)
      if not ok and not state.terminal then
        record.completed = true
        request_error(state, record.client, "normalization_error", failure)
        maybe_finish(state)
      end
    end)
    if ticket then
      record.normalization_ticket = ticket
    elseif not state.terminal then
      record.completed = true
      request_error(state, record.client, "provider_disposed", "LSP normalization could not continue after request disposal")
      maybe_finish(state)
    end
  end
end

finish_request = function(state, status, error_code, error_message)
  if state.terminal then return false end
  state.terminal = true
  state.final_status = status
  if error_code then
    request_error(state, nil, error_code, error_message or error_code)
  end

  for _, record in ipairs(state.records) do
    if not record.completed and record.request_id ~= nil and type(record.client.cancel_request) == "function" then
      pcall(record.client.cancel_request, record.client, record.request_id)
    end
    record.completed = true
  end
  flush_batch(state, nil)
  state.provider.requests[state.id] = nil
  state.provider.request_count = math.max(0, (state.provider.request_count or 1) - 1)
  state.scope:dispose()

  local error_detail
  if #state.errors > 0 then
    local default_code = status == "error" and "lsp_error" or "lsp_partial"
    error_detail = { code = error_code or default_code, message = error_message or "one or more LSP requests did not complete", clients = state.errors }
  end
  safe_sink(state, {
    kind = "done",
    status = status,
    completeness = status == "complete" and "complete" or (status == "partial" and "partial" or "unknown"),
    generation = state.generation,
    session_id = state.session_id,
    document_version = state.document_version,
    workspace_generation = state.workspace_generation,
    item_count = state.item_count,
    error = error_detail,
  })
  state.sink = nil
  return true
end

cancel_state = function(state, reason)
  if state.terminal then return false end
  local code = reason == "document_changed" and "stale_document"
    or reason == "workspace_changed" and "stale_workspace"
    or reason == "buffer_closed" and "buffer_closed"
    or reason == "client_detached" and "client_detached"
    or reason == "provider_disposed" and "provider_disposed"
    or "cancelled"
  return finish_request(state, "cancelled", code, reason or "LSP request cancelled")
end

maybe_finish = function(state)
  if state.terminal or state.dispatching then return end
  for _, record in ipairs(state.records) do
    if not record.completed then return end
  end

  local status
  if #state.errors > 0 or state.truncated then
    status = state.item_count > 0 and "partial" or "error"
  else
    status = "complete"
  end
  finish_request(state, status, nil, nil)
end

local function handle_response(state, record, err, result)
  if state.terminal or record.completed then return end
  close_timeout(record)
  if not normalization_current(state, record) then return end

  if err ~= nil then
    record.completed = true
    local code = type(err) == "table" and (err.code or err.message) or err
    local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
    request_error(state, record.client, "client_error", message, { lsp_code = code })
    maybe_finish(state)
    return
  end

  state.successful_responses = state.successful_responses + 1
  local walk = normalization_walk(state, record.client, result)
  process_normalization_slice(state, record, walk, false)
end

local function schedule_response(state, record, err, result)
  if state.terminal or record.completed or record.received then return end
  record.received = true
  local ticket = state.scope:schedule(function()
    record.ticket = nil
    local ok, failure = xpcall(function() handle_response(state, record, err, result) end, debug.traceback)
    if not ok and not state.terminal then
      record.completed = true
      request_error(state, record.client, "normalization_error", failure)
      maybe_finish(state)
    end
  end)
  if not ticket then
    record.completed = true
    request_error(state, record.client, "provider_disposed", "LSP response arrived after request disposal")
    maybe_finish(state)
  else
    record.ticket = ticket
  end
end

local function request_params(request, client, bufnr)
  if type(request.params) == "function" then return request.params(client, bufnr) end
  return type(request.params) == "table" and vim.deepcopy(request.params) or {}
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "LSP provider options must be a table" end
  local limits = {}
  for name in pairs(DEFAULTS) do
    local value, err = option(opts, name)
    if not value then return nil, err end
    limits[name] = value
  end
  if opts.get_clients ~= nil and type(opts.get_clients) ~= "function" then
    return nil, "get_clients must be a function"
  end
  if opts.get_all_clients ~= nil and type(opts.get_all_clients) ~= "function" then
    return nil, "get_all_clients must be a function"
  end
  local provider = setmetatable({
    limits = limits,
    get_clients = opts.get_clients or function(bufnr) return vim.lsp.get_clients({ bufnr = bufnr }) end,
    get_all_clients = opts.get_all_clients or function() return vim.lsp.get_clients({}) end,
    scope = Scope.new("workbench-lsp-provider"),
    requests = {},
    client_cache = {},
    next_request = 0,
    request_count = 0,
    disposed = false,
  }, Provider)
  local ok, autocmd_error = create_autocmds(provider)
  if not ok then
    provider:dispose()
    return nil, error_value("autocmd_setup_failed", tostring(autocmd_error))
  end
  return provider
end

function Provider:_live()
  if self.disposed or not self.scope.alive then
    return nil, error_value("provider_disposed", "LSP provider is disposed")
  end
  return true
end

function Provider:_read_clients(bufnr)
  local ok, clients = pcall(self.get_clients, bufnr)
  if not ok or type(clients) ~= "table" then return nil end
  local ordered = {}
  for _, client in ipairs(clients) do ordered[#ordered + 1] = client end
  table.sort(ordered, function(left, right)
    return (tonumber(left.id) or math.huge) < (tonumber(right.id) or math.huge)
  end)
  return ordered
end

function Provider:_clients(bufnr, refresh)
  if not refresh and self.client_cache[bufnr] then return self.client_cache[bufnr] end
  local clients = self:_read_clients(bufnr)
  if not clients then return nil end
  self.client_cache[bufnr] = clients
  return clients
end

function Provider:capabilities(context)
  local alive, alive_error = self:_live()
  if not alive then return { state = "unavailable", reason = alive_error.message, code = alive_error.code, operations = {} } end
  if type(context) ~= "table" or not positive_integer(context.bufnr) or type(context.method) ~= "string" or context.method == "" then
    return { state = "unavailable", reason = "LSP capability checks require an explicit buffer and method", code = "invalid_context", operations = {} }
  end
  if not vim.api.nvim_buf_is_valid(context.bufnr) then
    return { state = "unavailable", reason = "LSP target buffer is no longer valid", code = "invalid_buffer", operations = {} }
  end
  local clients = self:_clients(context.bufnr)
  if not clients then
    return { state = "error", reason = "Neovim could not inspect attached LSP clients", code = "client_lookup_failed", operations = {} }
  end
  local attached, supported = {}, {}
  local requested_clients = context.client_ids
  local requested = nil
  if requested_clients ~= nil then
    if type(requested_clients) ~= "table" then
      return { state = "unavailable", reason = "client_ids must be an array of LSP client IDs", code = "invalid_client_ids", operations = {} }
    end
    requested = {}
    for _, client_id in ipairs(requested_clients) do
      if not positive_integer(client_id) then
        return { state = "unavailable", reason = "client_ids must contain positive integer IDs", code = "invalid_client_ids", operations = {} }
      end
      requested[client_id] = true
    end
  end
  for _, client in ipairs(clients) do
    attached[#attached + 1] = { id = client.id, name = bounded_text(client.name, 128) }
    if (not requested or requested[client.id]) and method_supports(client, context.method, context.bufnr) then
      supported[#supported + 1] = { id = client.id, name = bounded_text(client.name, 128), encoding = client.offset_encoding }
    end
  end
  if #supported == 0 then
    local selected_attached = not requested
    if requested then
      for _, client in ipairs(attached) do if requested[client.id] then selected_attached = true; break end end
    end
    local code = #attached == 0 and "no_attached_client" or (not selected_attached and "client_detached" or "unsupported_method")
    local reason = code == "no_attached_client" and "no language server is attached to this buffer"
      or code == "client_detached" and "the originating language server is no longer attached to this buffer"
      or "attached language servers do not support " .. context.method
    return { state = "unavailable", reason = reason, code = code, clients = attached, operations = {} }
  end
  return { state = "ready", clients = supported, operations = { "request" } }
end

local function filter_matches(filter, uris)
  if type(filter) ~= "table" or (filter.scheme ~= nil and filter.scheme ~= "file") then return false end
  local pattern = filter.pattern
  if type(pattern) == "string" then pattern = { glob = pattern } end
  if type(pattern) ~= "table" or type(pattern.glob) ~= "string" then return false end
  if pattern.matches ~= nil and pattern.matches ~= "file" then return false end
  local glob = pattern.glob
  local ignore_case = type(pattern.options) == "table" and pattern.options.ignoreCase == true
  if ignore_case then glob = glob:lower() end
  if type(vim.glob) ~= "table" or type(vim.glob.to_lpeg) ~= "function" then return false end
  local ok, compiled = pcall(vim.glob.to_lpeg, glob)
  if not ok or not compiled then return false end
  local base
  if pattern.baseUri ~= nil then
    local base_value = type(pattern.baseUri) == "table" and pattern.baseUri.uri or pattern.baseUri
    local base_resource = type(base_value) == "string" and Resource.from_uri(base_value) or nil
    if not base_resource or base_resource.scheme ~= "file" then return false end
    base = base_resource.path
  end
  for _, file_uri in ipairs(uris) do
    local resource = Resource.from_uri(file_uri)
    if resource and resource.scheme == "file" then
      local candidate = resource.path
      if base then
        local relative = vim.fs.relpath(base, candidate)
        if relative == nil or relative == ".." or relative:sub(1, 3) == "../" or relative:sub(1, 3) == "..\\" then
          candidate = nil
        else
          candidate = relative == "." and "" or relative
        end
      end
      if candidate and compiled:match(ignore_case and candidate:lower() or candidate) ~= nil then return true end
    end
  end
  return false
end

local function validate_edit_array(edits)
  if type(edits) ~= "table" then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit text changes must be arrays") end
  local count, maximum = 0, 0
  for index in pairs(edits) do
    if not positive_integer(index) then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit text changes contain a non-array entry") end
    count, maximum = count + 1, math.max(maximum, index)
  end
  if count ~= maximum then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit text changes contain a gap") end
  local function coordinate(value)
    return type(value) == "number" and value % 1 == 0 and value >= 0
  end
  for _, item in ipairs(edits) do
    local range = type(item) == "table" and item.range
    local start = type(range) == "table" and range.start
    local finish = type(range) == "table" and range["end"]
    if type(item) ~= "table" or type(item.newText) ~= "string" or type(start) ~= "table" or type(finish) ~= "table"
      or not coordinate(start.line) or not coordinate(start.character)
      or not coordinate(finish.line) or not coordinate(finish.character) then
      return nil, error_value("invalid_lsp_workspace_edit", "workspace edit contains an invalid text edit")
    end
  end
  return true
end

local function validate_workspace_edit(edit, max_bytes)
  if edit == nil then return true end
  if type(edit) ~= "table" then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit response must be an object") end
  if not estimate_size(edit, max_bytes) then return nil, error_value("lsp_edit_too_large", "workspace edit exceeds the configured rename-review limit (maximum 256 KiB)") end
  if edit.changes ~= nil then
    if type(edit.changes) ~= "table" then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit changes must be a URI-to-edits map") end
    for uri, edits in pairs(edit.changes) do
      if type(uri) ~= "string" then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit contains a non-string URI key") end
      local valid, validation_error = validate_edit_array(edits)
      if not valid then return nil, validation_error end
    end
  end
  if edit.documentChanges ~= nil then
    if type(edit.documentChanges) ~= "table" then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit documentChanges must be an array") end
    local count, maximum = 0, 0
    for index in pairs(edit.documentChanges) do
      if not positive_integer(index) then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit documentChanges contain a non-array entry") end
      count, maximum = count + 1, math.max(maximum, index)
    end
    if count ~= maximum then return nil, error_value("invalid_lsp_workspace_edit", "workspace edit documentChanges contain a gap") end
    for _, change in ipairs(edit.documentChanges) do
      if type(change) ~= "table" or type(change.textDocument) ~= "table" or type(change.textDocument.uri) ~= "string" then
        return nil, error_value("unsupported_lsp_resource_operation", "LSP rename edits containing file create, rename, or delete operations are not supported")
      end
      local valid, validation_error = validate_edit_array(change.edits)
      if not valid then return nil, validation_error end
    end
  end
  return true
end

local function client_file_operation_matches(client, method, uris)
  local key = method == "workspace/willRenameFiles" and "willRename" or "didRename"
  local workspace = client.server_capabilities and client.server_capabilities.workspace
  local file_operations = workspace and workspace.fileOperations
  local registrations = {}
  local static = file_operations and file_operations[key]
  if type(static) == "table" and type(static.filters) == "table" then
    for _, filter in ipairs(static.filters) do registrations[#registrations + 1] = filter end
  end
  for _, list in pairs(client.registrations or {}) do
    for _, registration in ipairs(list) do
      if registration.method == method and type(registration.registerOptions) == "table" then
        for _, filter in ipairs(registration.registerOptions.filters or {}) do registrations[#registrations + 1] = filter end
      end
    end
  end
  for _, filter in ipairs(registrations) do if filter_matches(filter, uris) then return true end end
  return false
end

function Provider:prepare_file_rename(source_path, target_path, bufnr, callback)
  local alive, alive_error = self:_live()
  if not alive then return nil, alive_error end
  if type(callback) ~= "function" then return nil, error_value("invalid_callback", "file rename preparation requires a callback") end
  local source_uri_ok, old_uri = pcall(vim.uri_from_fname, source_path)
  local target_uri_ok, new_uri = pcall(vim.uri_from_fname, target_path)
  if not source_uri_ok or not target_uri_ok then return nil, error_value("invalid_uri", "file rename paths cannot be represented as LSP URIs") end
  if bufnr ~= nil and (not positive_integer(bufnr) or not vim.api.nvim_buf_is_valid(bufnr)) then
    return nil, error_value("invalid_buffer", "file rename requires a valid source buffer when one is provided")
  end
  local clients_ok, clients = pcall(self.get_all_clients)
  if not clients_ok or type(clients) ~= "table" then return nil, error_value("client_lookup_failed", "Neovim could not inspect active LSP clients") end
  local ordered = {}
  for _, client in ipairs(clients) do ordered[#ordered + 1] = client end
  table.sort(ordered, function(left, right) return (tonumber(left.id) or math.huge) < (tonumber(right.id) or math.huge) end)
  local rename_uris = { old_uri, new_uri }
  local records, will_count = {}, 0
  for _, client in ipairs(ordered) do
    local will = method_supports(client, "workspace/willRenameFiles", bufnr)
      and client_file_operation_matches(client, "workspace/willRenameFiles", rename_uris)
    local did = method_supports(client, "workspace/didRenameFiles", bufnr)
      and client_file_operation_matches(client, "workspace/didRenameFiles", rename_uris)
    if will or did then
      local record = { client = client, will = will, did = did, encoding = client.offset_encoding or "utf-16" }
      records[#records + 1] = record
      if will then will_count = will_count + 1 end
    end
  end
  local scope, scope_error = self.scope:child("file-rename:" .. tostring(source_path))
  if not scope then return nil, error_value("request_scope_failed", scope_error and scope_error.message or "could not own file operation requests") end
  local handle = { active = true }
  local completed, pending, results = false, will_count, {}
  local function finish(error_result)
    if completed then return end
    completed = true
    handle.active = false
    if error_result then
      scope:dispose()
      callback(nil, error_result)
      return
    end
    local chosen, chosen_encoding
    for _, record in ipairs(records) do
      local response = record.result
      if type(response) == "table" and (next(response.changes or {}) or next(response.documentChanges or {})) then
        if chosen and (not vim.deep_equal(chosen, response) or chosen_encoding ~= record.encoding) then
          scope:dispose()
          callback(nil, error_value("lsp_edit_conflict", "language servers returned conflicting workspace edits; no filesystem or LSP changes were applied"))
          return
        end
        chosen, chosen_encoding = response, record.encoding
      end
    end
    local edit_uris, affected_paths = {}, {}
    if chosen then
      for _, change in ipairs(chosen.documentChanges or {}) do
        if type(change) ~= "table" or type(change.textDocument) ~= "table" or type(change.textDocument.uri) ~= "string" then
          scope:dispose()
          callback(nil, error_value("unsupported_lsp_resource_operation", "LSP rename edits containing file create, rename, or delete operations are not supported"))
          return
        end
      end
      for file_uri in pairs(chosen.changes or {}) do edit_uris[file_uri] = true end
      for _, change in ipairs(chosen.documentChanges or {}) do
        if change.textDocument and type(change.textDocument.uri) == "string" then edit_uris[change.textDocument.uri] = true end
      end
    end
    for file_uri in pairs(edit_uris) do
      local resource, resource_error = Resource.from_uri(file_uri)
      if not resource or resource.scheme ~= "file" then
        scope:dispose()
        callback(nil, error_value("unsupported_lsp_edit_resource", resource_error or "LSP rename edit targets a non-file URI"))
        return
      end
      affected_paths[#affected_paths + 1] = resource.path
    end
    table.sort(affected_paths)
    local summary = {}
    if chosen then
      -- Rendering is intentionally textual so the operation prompt shows the exact server edits being reviewed.
      for file_uri, edits in pairs(chosen.changes or {}) do
        local lines = {}
        for _, item in ipairs(edits) do
          local range, text = item.range or {}, tostring(item.newText or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
          if #text > 160 then text = text:sub(1, 157) .. "..." end
          local start, finish_range = range.start or {}, range["end"] or {}
          lines[#lines + 1] = string.format("  %d:%d-%d:%d → %s", (start.line or 0) + 1, (start.character or 0) + 1,
            (finish_range.line or start.line or 0) + 1, (finish_range.character or start.character or 0) + 1, text)
        end
        table.sort(lines)
        summary[#summary + 1] = file_uri .. "\n" .. table.concat(lines, "\n")
      end
      for _, change in ipairs(chosen.documentChanges or {}) do
        if change.textDocument and type(change.textDocument.uri) == "string" then
          local lines = {}
          for _, item in ipairs(change.edits or {}) do
            local range, text = item.range or {}, tostring(item.newText or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
            if #text > 160 then text = text:sub(1, 157) .. "..." end
            local start, finish_range = range.start or {}, range["end"] or {}
            lines[#lines + 1] = string.format("  %d:%d-%d:%d → %s", (start.line or 0) + 1, (start.character or 0) + 1,
              (finish_range.line or start.line or 0) + 1, (finish_range.character or start.character or 0) + 1, text)
          end
          table.sort(lines)
          summary[#summary + 1] = change.textDocument.uri .. "\n" .. table.concat(lines, "\n")
        end
      end
      table.sort(summary)
    end
    local did_clients = {}
    for _, record in ipairs(records) do
      if record.did then did_clients[#did_clients + 1] = { client = record.client, encoding = record.encoding } end
    end
    scope:dispose()
    callback({
      clients = did_clients,
      bufnr = bufnr,
      edit = chosen and vim.deepcopy(chosen) or nil,
      encoding = chosen_encoding,
      affected_paths = affected_paths,
      review = summary,
    })
  end
  function handle:cancel()
    if not self.active then return false end
    self.active = false
    scope:dispose()
    completed = true
    callback(nil, error_value("cancelled", "LSP file operation preparation was cancelled"))
    return true
  end
  function handle:dispose() return self:cancel() end
  if will_count == 0 then
    finish()
    return handle
  end
  local timeout_ms = self.limits.request_timeout_ms
  for _, record in ipairs(records) do
    if record.will then
      local timer
      local timer_ok, timer_value = pcall((vim.uv or vim.loop).new_timer)
      if timer_ok then timer = timer_value end
      if not timer then
        finish(error_value("timeout_setup_failed", "could not create LSP file-operation timer"))
        break
      end
      local timer_owner = scope:defer(function()
        pcall(timer.stop, timer)
        if not timer:is_closing() then timer:close() end
      end, "file-operation-timeout:" .. tostring(record.client.id), "timer")
      if not timer_owner then
        pcall(timer.close, timer)
        finish(error_value("timeout_setup_failed", "could not own LSP file-operation timer"))
        break
      end
      local record_done = false
      local request_owner
      local function complete_record(err, result)
        if record_done or completed then return end
        record_done = true
        if request_owner then request_owner:forget(); request_owner = nil end
        timer_owner:dispose()
        if err then
          finish(error_value("lsp_will_rename_failed", tostring(err.message or err), { client_id = record.client.id }))
          return
        end
        local valid, validation_error = validate_workspace_edit(result, math.min(self.limits.max_result_bytes, MAX_RENAME_WORKSPACE_EDIT_BYTES))
        if not valid then finish(validation_error); return end
        record.result = result
        pending = pending - 1
        if pending == 0 then finish() end
      end
      local started, timer_error = pcall(timer.start, timer, timeout_ms, 0, function()
        vim.schedule(function()
          if record.request_id and type(record.client.cancel_request) == "function" then
            pcall(record.client.cancel_request, record.client, record.request_id)
          end
          complete_record({ message = "workspace/willRenameFiles timed out" })
        end)
      end)
      if not started then
        complete_record({ message = tostring(timer_error) })
      else
        request_owner = scope:defer(function()
          if not record_done and record.request_id and type(record.client.cancel_request) == "function" then
            pcall(record.client.cancel_request, record.client, record.request_id)
          end
        end, "file-operation-request:" .. tostring(record.client.id), "lsp-request")
        if not request_owner then
          complete_record({ message = "could not own LSP file-operation request" })
        else
        local request_ok, sent, request_id = pcall(record.client.request, record.client, "workspace/willRenameFiles",
          { files = { { oldUri = old_uri, newUri = new_uri } } }, complete_record, bufnr)
        if not request_ok or sent ~= true then
          complete_record({ message = request_ok and "LSP client is shutting down" or tostring(sent) })
        else
          record.request_id = request_id
        end
        end
      end
    end
  end
  return handle
end

function Provider:did_rename_files(source_path, target_path, prepared)
  local alive, alive_error = self:_live()
  if not alive then return nil, alive_error end
  if type(prepared) ~= "table" or type(prepared.clients) ~= "table" then return true end
  local source_uri_ok, old_uri = pcall(vim.uri_from_fname, source_path)
  local target_uri_ok, new_uri = pcall(vim.uri_from_fname, target_path)
  if not source_uri_ok or not target_uri_ok then return nil, error_value("invalid_uri", "renamed paths cannot be represented as LSP URIs") end
  local params = { files = { { oldUri = old_uri, newUri = new_uri } } }
  local errors = {}
  for _, record in ipairs(prepared.clients) do
    local client = record.client
    if method_supports(client, "workspace/didRenameFiles", prepared.bufnr)
      and client_file_operation_matches(client, "workspace/didRenameFiles", { old_uri, new_uri }) then
      local okay, notified = pcall(client.notify, client, "workspace/didRenameFiles", params, prepared.bufnr)
      if not okay or notified == false then errors[#errors + 1] = tostring(okay and "client rejected notification" or notified) end
    end
  end
  if #errors > 0 then return nil, error_value("lsp_notification_failed", table.concat(errors, "; ")) end
  return true
end

function Provider:start(request, sink)
  local alive, alive_error = self:_live()
  if not alive then return nil, alive_error end
  if type(request) ~= "table" then return nil, error_value("invalid_request", "LSP request must be a table") end
  if type(sink) ~= "function" then return nil, error_value("invalid_sink", "LSP request requires a result callback") end

  local bufnr = request.bufnr
  if not positive_integer(bufnr) or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, error_value("invalid_buffer", "LSP request requires an explicit valid buffer")
  end
  local method = request.method
  if type(method) ~= "string" or method == "" or #method > 256 then
    return nil, error_value("invalid_method", "LSP request method must be a non-empty string")
  end
  local result_kind = request.result_kind or "auto"
  if not SUPPORTED_RESULT_KINDS[result_kind] then
    return nil, error_value("invalid_result_kind", "result_kind must be auto, location, symbol, call_item, call_edge, or raw")
  end
  local max_items = request.max_items
  if max_items ~= nil and not positive_integer(max_items) then
    return nil, error_value("invalid_item_limit", "request max_items must be a positive integer")
  end
  max_items = math.min(max_items or self.limits.max_items, self.limits.max_items)
  local direction = request.direction
  local expected_direction = method == "callHierarchy/incomingCalls" and "incoming"
    or method == "callHierarchy/outgoingCalls" and "outgoing" or nil
  if (result_kind == "call_edge" and not expected_direction)
    or (expected_direction and direction ~= expected_direction) then
    return nil, error_value("invalid_direction", "call edge requests require a matching incoming or outgoing method and direction")
  end
  local generation = request.generation or 1
  if not positive_integer(generation) then return nil, error_value("invalid_generation", "LSP request generation must be a positive integer") end
  local session_id = request.session_id or ("lsp-" .. tostring(generation))
  if type(session_id) ~= "string" or session_id == "" or #session_id > 128 then
    return nil, error_value("invalid_session", "LSP session ID must be a non-empty string of at most 128 bytes")
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    return nil, error_value("unnamed_buffer", "LSP request requires a named source buffer")
  end
  if vim.in_fast_event() then return nil, error_value("fast_event", "LSP requests must be started on the main loop") end
  if self.request_count and self.request_count >= self.limits.max_active_requests then
    return nil, error_value("request_capacity", "LSP provider active request limit reached")
  end
  local clients = self:_clients(bufnr)
  if not clients then return nil, error_value("client_lookup_failed", "Neovim could not inspect attached LSP clients") end
  local eligible = {}
  local requested_clients = request.client_ids
  local requested = nil
  if requested_clients ~= nil then
    if type(requested_clients) ~= "table" then
      return nil, error_value("invalid_client_ids", "client_ids must be an array of LSP client IDs")
    end
    requested = {}
    for _, client_id in ipairs(requested_clients) do
      if not positive_integer(client_id) then
        return nil, error_value("invalid_client_ids", "client_ids must contain positive integer IDs")
      end
      requested[client_id] = true
    end
  end
  for _, client in ipairs(clients) do
    if (not requested or requested[client.id]) and method_supports(client, method, bufnr) then eligible[#eligible + 1] = client end
  end
  if #eligible == 0 then
    local selected_attached = not requested
    if requested then
      for _, client in ipairs(clients) do if requested[client.id] then selected_attached = true; break end end
    end
    local code = #clients == 0 and "no_attached_client" or (not selected_attached and "client_detached" or "unsupported_method")
    local message = code == "no_attached_client" and "no language server is attached to this buffer"
      or code == "client_detached" and "the originating language server is no longer attached to this buffer"
      or "attached language servers do not support " .. method
    return nil, error_value(code, message, { method = method, bufnr = bufnr })
  end

  self.next_request = self.next_request + 1
  local id = self.next_request
  local workspace = request.workspace
  local workspace_generation = request.workspace_generation
  if workspace_generation == nil and type(workspace) == "table" then workspace_generation = workspace.generation end
  if workspace_generation == nil then workspace_generation = 0 end
  if type(workspace_generation) ~= "number" or workspace_generation < 0 or workspace_generation % 1 ~= 0 then
    return nil, error_value("invalid_workspace_generation", "workspace generation must be a non-negative integer")
  end
  local workspace_id = request.workspace_id or (type(workspace) == "table" and workspace.id) or nil
  local document_version = vim.api.nvim_buf_get_changedtick(bufnr)
  local normalized_request = vim.tbl_extend("force", request, {
    bufnr = bufnr,
    method = method,
    result_kind = result_kind,
    generation = generation,
    session_id = session_id,
    workspace_id = workspace_id,
    workspace_generation = workspace_generation,
    document_version = document_version,
    max_items = max_items,
  })
  local request_scope, scope_error = self.scope:child("request:" .. id)
  if not request_scope then return nil, error_value("request_scope_failed", scope_error and scope_error.message or "cannot create request scope") end
  local state = {
    id = id,
    provider = self,
    scope = request_scope,
    request = normalized_request,
    bufnr = bufnr,
    method = method,
    generation = generation,
    session_id = session_id,
    workspace_generation = workspace_generation,
    document_version = document_version,
    source_uri = source_uri(bufnr),
    sink = sink,
    records = {},
    errors = {},
    batch = {},
    item_count = 0,
    max_items = max_items,
    result_bytes = 0,
    successful_responses = 0,
    normalization_slices = 0,
    normalization_max_slice_ms = 0,
    dispatching = true,
    terminal = false,
  }
  self.requests[id] = state
  self.request_count = (self.request_count or 0) + 1

  local handle = {}
  function handle:cancel(reason)
    return cancel_state(state, reason or "cancelled")
  end
  function handle:dispose()
    return self:cancel("cancelled")
  end
  function handle:is_active()
    return not state.terminal
  end
  function handle:status()
    return {
      id = state.id,
      active = not state.terminal,
      method = state.method,
      bufnr = state.bufnr,
      generation = state.generation,
      document_version = state.document_version,
      completed_clients = state.completed_clients or 0,
      item_count = state.item_count,
      errors = #state.errors,
      normalization_slices = state.normalization_slices,
      normalization_max_slice_ms = state.normalization_max_slice_ms,
      resources = state.scope:inventory(),
    }
  end
  state.handle = handle

  for _, client in ipairs(eligible) do
    local record = { client = client, completed = false, received = false, request_id = nil }
    state.records[#state.records + 1] = record
    local _, cancel_error = request_scope:defer(function()
      if not record.completed and record.request_id ~= nil and type(client.cancel_request) == "function" then
        pcall(client.cancel_request, client, record.request_id)
      end
    end, "lsp-request:" .. tostring(client.id), "lsp-request")
    if cancel_error then
      record.completed = true
      request_error(state, client, cancel_error.code, cancel_error.message)
    else
      local params_ok, params = pcall(request_params, normalized_request, client, bufnr)
      if not params_ok then
        record.completed = true
        request_error(state, client, "invalid_params", params)
      elseif type(params) ~= "table" then
        record.completed = true
        request_error(state, client, "invalid_params", "LSP params callback must return a table")
      else
        local timeout_ok, timeout_error = arm_timeout(state, record)
        if not timeout_ok then
          record.completed = true
          request_error(state, client, timeout_error.code, timeout_error.message)
        else
          local request_ok, sent, request_id = pcall(client.request, client, method, params, function(err, result)
            schedule_response(state, record, err, result)
          end, bufnr)
          if not request_ok or sent ~= true then
            record.completed = true
            close_timeout(record)
            request_error(state, client, "request_failed", request_ok and "Neovim LSP client is shutting down" or sent)
          else
            record.request_id = request_id
          end
        end
      end
    end
  end

  state.dispatching = false
  maybe_finish(state)
  return handle
end

function Provider:_on_attach(bufnr)
  if type(bufnr) == "number" then self.client_cache[bufnr] = nil end
end

function Provider:_on_detach(bufnr, client_id)
  if type(bufnr) ~= "number" then return end
  self.client_cache[bufnr] = nil
  for _, state in pairs(self.requests) do
    if state.bufnr == bufnr and not state.terminal then
      for _, record in ipairs(state.records) do
        if (client_id == nil or record.client.id == client_id) and not record.completed then
          close_timeout(record)
          if record.timeout_ticket then record.timeout_ticket:cancel(); record.timeout_ticket = nil end
          if record.ticket then record.ticket:cancel(); record.ticket = nil end
          if record.normalization_ticket then record.normalization_ticket:cancel(); record.normalization_ticket = nil end
          if record.request_id ~= nil and type(record.client.cancel_request) == "function" then
            pcall(record.client.cancel_request, record.client, record.request_id)
          end
          record.completed = true
          request_error(state, record.client, "client_detached", "LSP client detached before its response was accepted")
        end
      end
      maybe_finish(state)
    end
  end
end

function Provider:status()
  local active = 0
  for _ in pairs(self.requests) do active = active + 1 end
  return {
    disposed = self.disposed,
    active_requests = active,
    cached_buffers = vim.tbl_count(self.client_cache),
    resources = self.scope:inventory(),
  }
end

function Provider:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  local pending = {}
  for _, state in pairs(self.requests) do pending[#pending + 1] = state end
  for _, state in ipairs(pending) do cancel_state(state, "provider_disposed") end
  self.client_cache = {}
  self.disposal_report = self.scope:dispose()
  return self.disposal_report
end

create_autocmds = function(provider)
  next_provider_id = next_provider_id + 1
  local group = vim.api.nvim_create_augroup("WorkbenchLspProvider_" .. next_provider_id, { clear = true })
  local ok, err = pcall(function()
    vim.api.nvim_create_autocmd("LspAttach", {
      group = group,
      callback = function(event) provider:_on_attach(event.buf) end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
      group = group,
      callback = function(event)
        local client_id = type(event.data) == "table" and event.data.client_id or nil
        provider:_on_detach(event.buf, client_id)
      end,
    })
  end)
  if not ok then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return nil, err
  end
  local cleanup, cleanup_error = provider.scope:defer(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end, "lsp-client-lifecycle", "autocmd")
  if not cleanup then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return nil, cleanup_error and cleanup_error.message or "could not own LSP lifecycle autocmds"
  end
  return true
end

return M
