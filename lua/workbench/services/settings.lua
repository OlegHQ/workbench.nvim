local M = {}
local Settings = {}
Settings.__index = Settings

local defaults = {
  enabled = false,
  sidebar = {
    position = "left",
    width = 32,
    views = { "files", "outline", "problems" },
    follow_active_file = false,
  },
  search = {
    debounce_ms = 80,
    max_results = 10000,
    hidden = false,
    ignored = false,
    follow_symlinks = false,
  },
  preview = { enabled = true, max_bytes = 262144 },
  session = { persist = false, max_results_history = 10 },
}

local fields = {
  enabled = { type = "boolean", scope = "global", overridable = false },
  ["sidebar.position"] = { type = "string", values = { left = true, right = true }, scope = "session", override_scopes = { workspace = true, session = true } },
  ["sidebar.width"] = { type = "integer", minimum = 16, maximum = 80, scope = "session", override_scopes = { workspace = true, session = true } },
  ["sidebar.views"] = { type = "array", item_values = { files = true, outline = true, problems = true }, scope = "session", override_scopes = { workspace = true, session = true } },
  ["sidebar.follow_active_file"] = { type = "boolean", scope = "buffer", override_scopes = { workspace = true, session = true, buffer = true } },
  ["search.debounce_ms"] = { type = "integer", minimum = 0, maximum = 300, scope = "session", override_scopes = { workspace = true, session = true, buffer = true } },
  ["search.max_results"] = { type = "integer", minimum = 1, maximum = 10000, scope = "session", override_scopes = { workspace = true, session = true, buffer = true } },
  ["search.hidden"] = { type = "boolean", scope = "buffer", override_scopes = { workspace = true, session = true, buffer = true } },
  ["search.ignored"] = { type = "boolean", scope = "buffer", override_scopes = { workspace = true, session = true, buffer = true } },
  ["search.follow_symlinks"] = { type = "boolean", scope = "buffer", override_scopes = { workspace = true, session = true, buffer = true } },
  ["preview.enabled"] = { type = "boolean", scope = "session", override_scopes = { workspace = true, session = true } },
  ["preview.max_bytes"] = { type = "integer", minimum = 1024, maximum = 1048576, scope = "session", override_scopes = { workspace = true, session = true } },
  ["session.persist"] = { type = "boolean", scope = "session", override_scopes = { session = true } },
  ["session.max_results_history"] = { type = "integer", minimum = 1, maximum = 16, scope = "session", override_scopes = { session = true } },
}

local adapter_ids = { completion = true, formatting = true, diagnostics = true }
local adapter_scopes = { global = true, workspace = true, session = true, buffer = true }
local override_scopes = { workspace = true, session = true, buffer = true }
local scope_context = { workspace = "workspace_id", session = "session_id", buffer = "bufnr" }

local function copy(value)
  return vim.deepcopy(value)
end

local function path_error(path, reason)
  return nil, { code = "invalid_config", path = path, message = path .. " " .. reason }
end

local function is_dense_array(value)
  if type(value) ~= "table" then return false end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function is_object(value)
  return type(value) == "table" and (next(value) == nil or not is_dense_array(value))
end

local function validate_leaf(path, value)
  local field = fields[path]
  if not field then return path_error(path, "is not a supported setting") end
  local kind = type(value)
  if field.type == "array" then
    if not is_dense_array(value) or #value == 0 then return path_error(path, "must be a non-empty array") end
    local seen = {}
    local result = {}
    for index, item in ipairs(value) do
      if type(item) ~= "string" or not field.item_values[item] then
        return path_error(path .. "[" .. index .. "]", "must be one of files, outline, or problems")
      end
      if seen[item] then return path_error(path .. "[" .. index .. "]", "duplicates a view") end
      seen[item] = true
      result[index] = item
    end
    return result
  end
  if field.type == "integer" then
    if kind ~= "number" then return path_error(path, "must be integer") end
  elseif kind ~= field.type then
    return path_error(path, "must be " .. field.type)
  end
  if field.type == "string" and not field.values[value] then
    return path_error(path, "must be left or right")
  end
  if field.type == "integer" then
    if value ~= value or value == math.huge or value == -math.huge then return path_error(path, "must be finite") end
    if value % 1 ~= 0 then return path_error(path, "must be an integer") end
    if value < field.minimum or value > field.maximum then
      return path_error(path, string.format("must be between %d and %d", field.minimum, field.maximum))
    end
  end
  return value
end

local section_fields = {
  sidebar = { position = "sidebar.position", width = "sidebar.width", views = "sidebar.views", ["follow_active_file"] = "sidebar.follow_active_file" },
  search = { debounce_ms = "search.debounce_ms", max_results = "search.max_results", hidden = "search.hidden", ignored = "search.ignored", follow_symlinks = "search.follow_symlinks" },
  preview = { enabled = "preview.enabled", max_bytes = "preview.max_bytes" },
  session = { persist = "session.persist", max_results_history = "session.max_results_history" },
}

local function validate_config(config)
  if not is_object(config) then return nil, { code = "invalid_config", path = "config", message = "setup config must be a table" } end
  local result = {}
  for key, value in pairs(config) do
    if key == "enabled" then
      local normalized, err = validate_leaf("enabled", value)
      if normalized == nil then return nil, err end
      result.enabled = normalized
    else
      local spec = section_fields[key]
      if not spec then return path_error("config." .. tostring(key), "is not a supported section") end
      if not is_object(value) then return path_error(key, "must be a table") end
      local section = {}
      for name, item in pairs(value) do
        local path = spec[name]
        if not path then return path_error(key .. "." .. tostring(name), "is not a supported setting") end
        local normalized, err = validate_leaf(path, item)
        if normalized == nil then return nil, err end
        section[name] = normalized
      end
      result[key] = section
    end
  end
  return result
end

local function merge_update(base, override)
  local result = copy(base)
  for key, value in pairs(override) do
    if is_object(value) and is_object(result[key] or {}) then
      result[key] = merge_update(result[key] or {}, value)
    else
      result[key] = copy(value)
    end
  end
  return result
end

local function record_sources(value, prefix, sources, source)
  for key, item in pairs(value) do
    local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    if type(item) == "table" and not is_dense_array(item) then
      record_sources(item, path, sources, source)
    else
      sources[path] = source
    end
  end
end

local function compose_layers(layers)
  local ordered = {}
  for source, layer in pairs(layers) do
    ordered[#ordered + 1] = { source = source, layer = layer }
  end
  table.sort(ordered, function(left, right)
    if left.layer.order == right.layer.order then return left.source < right.source end
    return left.layer.order < right.layer.order
  end)
  local values, sources = {}, {}
  for _, item in ipairs(ordered) do
    values = merge_update(values, item.layer.values)
    record_sources(item.layer.values, "", sources, item.source)
  end
  return values, sources
end

local function read_path(root, path)
  local value = root
  for part in path:gmatch("[^%.]+") do
    if type(value) ~= "table" then return nil end
    value = value[part]
  end
  return value
end

local function write_path(root, path, value)
  local parts = {}
  for part in path:gmatch("[^%.]+") do parts[#parts + 1] = part end
  local current = root
  for index = 1, #parts - 1 do
    current[parts[index]] = current[parts[index]] or {}
    current = current[parts[index]]
  end
  current[parts[#parts]] = copy(value)
end

local function owner_id(scope, id)
  if scope == "buffer" then
    if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then return nil end
    return tostring(id)
  end
  if type(id) ~= "string" or id == "" or #id > 256 then return nil end
  return id
end

local function live_fallback(record)
  local fallback = record.previous
  while fallback and not fallback.active do fallback = fallback.previous end
  return fallback
end

function M.validate_config(config)
  return validate_config(config)
end

function M.defaults()
  return copy(defaults)
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    user = {},
    sources = {},
    layers = {},
    next_layer_order = 0,
    overrides = { workspace = {}, session = {}, buffer = {} },
    adapters = {},
    next_id = 0,
    disposed = false,
    apply = opts.apply,
    applying = false,
  }, Settings)
end

function Settings:_apply_change(rollback)
  if not self.apply then return true end
  self.applying = true
  local ok, applied, err = pcall(self.apply)
  if ok and applied then self.applying = false; return true end
  rollback()
  local restored, value, restore_error = pcall(self.apply)
  self.applying = false
  local failure = {
    code = "setting_apply_failed",
    message = tostring(ok and (type(err) == "table" and err.message or err) or applied),
  }
  if not restored or not value then
    failure.rollback_error = tostring(restored and (type(restore_error) == "table" and restore_error.message or restore_error) or value)
  end
  return nil, failure
end

function Settings:configure(config, options)
  if self.disposed then return nil, { code = "settings_disposed", message = "settings service has been disposed" } end
  if self.applying then return nil, { code = "settings_busy", message = "settings application is already in progress" } end
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, { code = "invalid_config", message = "settings options must be a table" } end
  for key in pairs(options) do
    if key ~= "source" and key ~= "replace_source" then
      return nil, { code = "invalid_config", message = "unknown settings option: " .. tostring(key) }
    end
  end
  if options.replace_source ~= nil and type(options.replace_source) ~= "boolean" then
    return nil, { code = "invalid_config", message = "replace_source must be boolean" }
  end
  local source = options.source or "setup"
  if type(source) ~= "string" or source == "" or #source > 64 then
    return nil, { code = "invalid_config", message = "settings source must be a non-empty short string" }
  end
  local normalized, err = validate_config(config)
  if not normalized then return nil, err end
  local layers = copy(self.layers)
  local prior = layers[source] and layers[source].values or {}
  local values = options.replace_source and copy(normalized) or merge_update(prior, normalized)
  local old_layers, old_user, old_sources, old_order = self.layers, self.user, self.sources, self.next_layer_order
  self.next_layer_order = self.next_layer_order + 1
  layers[source] = { values = values, order = self.next_layer_order }
  local candidate, sources = compose_layers(layers)
  self.layers, self.user, self.sources = layers, candidate, sources
  return self:_apply_change(function()
    self.layers, self.user, self.sources, self.next_layer_order = old_layers, old_user, old_sources, old_order
  end)
end

function Settings:config_snapshot()
  return {
    values = copy(self.user),
    sources = copy(self.sources),
    layers = copy(self.layers),
    next_layer_order = self.next_layer_order,
  }
end

function Settings:restore_config(snapshot)
  if self.disposed then return nil, { code = "settings_disposed", message = "settings service has been disposed" } end
  if self.applying then return nil, { code = "settings_busy", message = "settings application is already in progress" } end
  if type(snapshot) ~= "table" or type(snapshot.values) ~= "table" or type(snapshot.sources) ~= "table"
    or type(snapshot.layers) ~= "table" or type(snapshot.next_layer_order) ~= "number" then
    return nil, { code = "invalid_snapshot", message = "settings snapshot is invalid" }
  end
  local normalized, err = validate_config(snapshot.values)
  if not normalized then return nil, err end
  local sources = {}
  for path, source in pairs(snapshot.sources) do
    if not fields[path] or type(source) ~= "string" or source == "" or #source > 64 then
      return nil, { code = "invalid_snapshot", message = "settings snapshot contains invalid provenance" }
    end
    sources[path] = source
  end
  if snapshot.next_layer_order % 1 ~= 0 or snapshot.next_layer_order < 0 then
    return nil, { code = "invalid_snapshot", message = "settings snapshot layer order is invalid" }
  end
  local layers = {}
  for source, layer in pairs(snapshot.layers) do
    if type(source) ~= "string" or source == "" or #source > 64 or type(layer) ~= "table"
      or type(layer.order) ~= "number" or layer.order % 1 ~= 0 or layer.order < 1
      or layer.order > snapshot.next_layer_order or type(layer.values) ~= "table" then
      return nil, { code = "invalid_snapshot", message = "settings snapshot contains an invalid source layer" }
    end
    local layer_values, layer_error = validate_config(layer.values)
    if not layer_values then return nil, { code = "invalid_snapshot", message = layer_error.message } end
    layers[source] = { values = layer_values, order = layer.order }
  end
  local composed_values, composed_sources = compose_layers(layers)
  if not vim.deep_equal(composed_values, normalized) or not vim.deep_equal(composed_sources, sources) then
    return nil, { code = "invalid_snapshot", message = "settings snapshot layers do not match its effective values" }
  end
  local old_layers, old_user, old_sources, old_order = self.layers, self.user, self.sources, self.next_layer_order
  self.layers, self.user, self.sources = layers, normalized, sources
  self.next_layer_order = snapshot.next_layer_order
  return self:_apply_change(function()
    self.layers, self.user, self.sources, self.next_layer_order = old_layers, old_user, old_sources, old_order
  end)
end

function Settings:get(path, context)
  local field = fields[path]
  if not field then return nil, { code = "unknown_setting", message = "unknown setting: " .. tostring(path) } end
  context = context or {}
  if type(context) ~= "table" then return nil, { code = "invalid_context", message = "settings context must be a table" } end
  local base = copy(defaults)
  local user_value = read_path(self.user, path)
  local value, source
  if user_value == nil then
    value, source = read_path(base, path), "default"
  else
    value, source = copy(user_value), self.sources[path] or "setup"
  end
  local selected_scope

  if field.overridable ~= false then
    for _, scope in ipairs({ "workspace", "session", "buffer" }) do
      local context_key = scope_context[scope]
      local id = owner_id(scope, context[context_key])
      local record = id and self.overrides[scope][id] and self.overrides[scope][id][path]
      if record and record.active then
        value = copy(record.value)
        source = scope .. ":" .. id
        selected_scope = scope
      end
    end
  end

  return {
    path = path,
    requested = copy(value),
    effective = copy(value),
    value = copy(value),
    provenance = source,
    scope = selected_scope or field.scope,
    apply_mode = "live",
    restart_required = false,
    overrideable = field.overridable ~= false,
  }
end

function Settings:list(context)
  local paths = {}
  for path in pairs(fields) do paths[#paths + 1] = path end
  table.sort(paths)
  local result = {}
  for _, path in ipairs(paths) do
    local state = self:get(path, context)
    result[#result + 1] = state
  end
  return result
end

function Settings:set_override(scope, id, path, value)
  if self.disposed then return nil, { code = "settings_disposed", message = "settings service has been disposed" } end
  if self.applying then return nil, { code = "settings_busy", message = "settings application is already in progress" } end
  if not override_scopes[scope] then return nil, { code = "invalid_scope", message = "override scope must be workspace, session, or buffer" } end
  local key = owner_id(scope, id)
  if not key then return nil, { code = "invalid_owner", message = "override owner is invalid for scope " .. scope } end
  local field = fields[path]
  if not field then return nil, { code = "unknown_setting", message = "unknown setting: " .. tostring(path) } end
  if field.overridable == false then return nil, { code = "not_overridable", message = "setting cannot be overridden: " .. path } end
  if field.override_scopes and not field.override_scopes[scope] then
    return nil, { code = "override_scope_not_allowed", message = "setting " .. path .. " cannot be overridden at " .. scope .. " scope" }
  end
  local normalized, err = validate_leaf(path, value)
  if normalized == nil then return nil, err end
  local owner = self.overrides[scope][key]
  if not owner then owner = {}; self.overrides[scope][key] = owner end
  self.next_id = self.next_id + 1
  local record = { id = self.next_id, value = copy(normalized), previous = owner[path], active = true }
  owner[path] = record
  local applied, apply_error = self:_apply_change(function()
    owner[path] = record.previous
    record.active = false
    if next(owner) == nil then self.overrides[scope][key] = nil end
  end)
  if not applied then return nil, apply_error end
  local service = self
  local handle = {}
  function handle:dispose()
    if not record.active then return false end
    if service.applying then return nil, { code = "settings_busy", message = "settings application is already in progress" } end
    local previous = owner[path]
    record.active = false
    if owner[path] == record then owner[path] = live_fallback(record) end
    if next(owner) == nil and service.overrides[scope][key] == owner then
      service.overrides[scope][key] = nil
    end
    return service:_apply_change(function()
      record.active = true
      owner[path] = previous
      service.overrides[scope][key] = owner
    end)
  end
  function handle:is_active() return record.active end
  return handle
end

function Settings:register_adapter(id, adapter, options)
  if self.disposed then return nil, { code = "settings_disposed", message = "settings service has been disposed" } end
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, { code = "invalid_adapter", message = "setting adapter options must be a table" } end
  if not adapter_ids[id] then return nil, { code = "unknown_adapter", message = "unsupported editor setting adapter: " .. tostring(id) } end
  if type(adapter) ~= "table" or type(adapter.get) ~= "function" or type(adapter.set) ~= "function"
    or type(adapter.capabilities) ~= "function" or not adapter_scopes[adapter.scope] then
    return nil, { code = "invalid_adapter", message = "setting adapter requires get, set, capabilities and a supported scope" }
  end
  for key in pairs(options) do
    if key ~= "replace" and key ~= "scope" then
      return nil, { code = "invalid_adapter", message = "unknown setting adapter option: " .. tostring(key) }
    end
  end
  if options.replace ~= nil and type(options.replace) ~= "boolean" then
    return nil, { code = "invalid_adapter", message = "replace must be boolean" }
  end
  local previous = self.adapters[id]
  if previous and options.replace ~= true then
    return nil, { code = "duplicate_adapter", message = "setting adapter is already registered: " .. id }
  end
  self.next_id = self.next_id + 1
  local record = { id = self.next_id, adapter = adapter, previous = previous, active = true }
  self.adapters[id] = record
  local service = self
  local owner_handle, owner_error
  local handle = {}
  function handle:dispose()
    if not record.active then return false end
    record.active = false
    if service.adapters[id] == record then service.adapters[id] = live_fallback(record) end
    if owner_handle then owner_handle:forget(); owner_handle = nil end
    return true
  end
  function handle:is_active() return record.active end
  if options.scope ~= nil then
    if type(options.scope) ~= "table" or type(options.scope.defer) ~= "function" then
      handle:dispose()
      return nil, { code = "invalid_scope", message = "setting adapter owner must be a disposable scope" }
    end
    owner_handle, owner_error = options.scope:defer(function() handle:dispose() end, "setting-adapter:" .. id, "setting-adapter")
    if not owner_handle then
      handle:dispose()
      return nil, owner_error or { code = "scope_disposed", message = "adapter owner scope is disposed" }
    end
  end
  return handle
end

local function normalize_adapter_state(id, record, context)
  if not record or not record.active then
    return { id = id, available = false, state = "unavailable", reason = "no autoconf editor-setting adapter is registered" }
  end
  local adapter = record.adapter
  local ok_capability, capability = pcall(adapter.capabilities, context or {})
  if not ok_capability or type(capability) ~= "table" or type(capability.available) ~= "boolean" then
    return { id = id, available = false, state = "error", reason = "setting adapter returned an invalid capability state" }
  end
  local ok_state, current = pcall(adapter.get, context or {})
  if not ok_state or type(current) ~= "table" or type(current.requested) ~= "boolean" or type(current.effective) ~= "boolean" then
    return { id = id, available = false, state = "error", reason = "setting adapter returned no boolean requested/effective state" }
  end
  local result = {
    id = id,
    available = capability.available,
    state = type(capability.state) == "string" and capability.state or (capability.available and "ready" or "unavailable"),
    requested = current.requested,
    effective = current.effective,
    provenance = type(current.provenance) == "string" and current.provenance or "autoconf",
    restart_required = current.restart_required == true,
    scope = adapter.scope,
  }
  if type(capability.reason) == "string" then result.reason = capability.reason
  elseif type(current.reason) == "string" then result.reason = current.reason end
  if type(current.runtime_state) == "string" then result.runtime_state = current.runtime_state end
  return result
end

function Settings:adapter_state(id, context)
  if context ~= nil and type(context) ~= "table" then return nil, { code = "invalid_context", message = "settings context must be a table" } end
  if not adapter_ids[id] then return nil, { code = "unknown_adapter", message = "unsupported editor setting adapter: " .. tostring(id) } end
  return normalize_adapter_state(id, self.adapters[id], context)
end

function Settings:set_adapter(id, value, context)
  if type(value) ~= "boolean" then return nil, { code = "invalid_setting", message = "editor setting value must be boolean" } end
  if context ~= nil and type(context) ~= "table" then return nil, { code = "invalid_context", message = "settings context must be a table" } end
  local record = self.adapters[id]
  local before = normalize_adapter_state(id, record, context)
  if not before.available then return nil, { code = "adapter_unavailable", message = before.reason or "setting adapter is unavailable" } end
  local adapter = record.adapter
  local context_key = scope_context[adapter.scope]
  if context_key and not owner_id(adapter.scope, (context or {})[context_key]) then
    return nil, { code = "missing_scope", message = "setting adapter requires " .. context_key }
  end
  local ok_set, accepted, set_error = pcall(adapter.set, value, context or {})
  if not ok_set or accepted ~= true then
    local rollback_ok, rollback_accepted = pcall(adapter.set, before.requested, context or {})
    local failure_code = type(set_error) == "table" and set_error.code or "adapter_set_failed"
    local failure_message = type(set_error) == "table" and set_error.message
      or tostring(not ok_set and accepted or set_error or "setting adapter rejected the value")
    return nil, {
      code = failure_code,
      message = failure_message,
      rollback = rollback_ok and rollback_accepted == true,
    }
  end
  local after = normalize_adapter_state(id, record, context)
  if not after.available or after.requested ~= value or after.effective ~= value then
    local rollback_ok, rollback_accepted = pcall(adapter.set, before.requested, context or {})
    return nil, {
      code = "adapter_state_mismatch",
      message = "setting adapter did not report the applied value as requested and effective",
      rollback = rollback_ok and rollback_accepted == true,
    }
  end
  return after
end

function Settings:adapter_snapshot()
  local result = {}
  for id in pairs(adapter_ids) do result[id] = self:adapter_state(id) end
  return result
end

function Settings:save()
  return nil, {
    code = "read_only_config",
    message = "no writable workbench TOML target was supplied; live settings were not persisted",
  }
end

function Settings:dispose()
  if self.disposed then return false end
  self.disposed = true
  self.apply = nil
  for _, record in pairs(self.adapters) do
    while record do record.active = false; record = record.previous end
  end
  for _, scopes in pairs(self.overrides) do
    for _, owner in pairs(scopes) do
      for _, record in pairs(owner) do
        while record do record.active = false; record = record.previous end
      end
    end
  end
  self.adapters = {}
  self.overrides = { workspace = {}, session = {}, buffer = {} }
  return true
end

return M
