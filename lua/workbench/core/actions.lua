local M = {}
local Registry = {}
Registry.__index = Registry

local scopes = { global = true, workspace = true, buffer = true, view = true, item = true }
local MAX_MESSAGE_LENGTH = 384

local function message(value)
  local result = tostring(value)
  if #result > MAX_MESSAGE_LENGTH then result = result:sub(1, MAX_MESSAGE_LENGTH - 3) .. "..." end
  return result
end

local function error_result(code, text)
  return { ok = false, error = { code = code, message = text } }
end

local function is_array(value)
  if type(value) ~= "table" then return false end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return count == maximum
end

local function valid_schema(schema, depth)
  depth = depth or 0
  if depth > 16 or type(schema) ~= "table" then return false, "argument schema must be a bounded table" end
  local accepted = { object = true, array = true, string = true, boolean = true, number = true, integer = true }
  if not accepted[schema.type] then return false, "argument schema type is unsupported" end
  if schema.enum ~= nil and (not is_array(schema.enum) or #schema.enum == 0) then
    return false, "argument schema enum must be a non-empty array"
  end
  if schema.enum then
    for _, value in ipairs(schema.enum) do
      if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
        return false, "argument schema enum values must be scalar"
      end
    end
  end
  if schema.type == "string" then
    for _, key in ipairs({ "min_length", "max_length" }) do
      local value = schema[key]
      if value ~= nil and (type(value) ~= "number" or value < 0 or value % 1 ~= 0) then
        return false, key .. " must be a non-negative integer"
      end
    end
    if schema.min_length and schema.max_length and schema.min_length > schema.max_length then
      return false, "min_length cannot exceed max_length"
    end
  elseif schema.type == "number" or schema.type == "integer" then
    for _, key in ipairs({ "minimum", "maximum" }) do
      local value = schema[key]
      if value ~= nil and (type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge) then
        return false, key .. " must be a finite number"
      end
    end
    if schema.minimum and schema.maximum and schema.minimum > schema.maximum then
      return false, "minimum cannot exceed maximum"
    end
  end
  if schema.type == "object" then
    if schema.properties ~= nil and type(schema.properties) ~= "table" then
      return false, "object schema properties must be a table"
    end
    for name, child in pairs(schema.properties or {}) do
      if type(name) ~= "string" or name == "" then return false, "object schema property names must be strings" end
      local ok, err = valid_schema(child, depth + 1)
      if not ok then return false, name .. ": " .. err end
    end
    if schema.required ~= nil and not is_array(schema.required) then
      return false, "object schema required must be an array"
    end
    for _, name in ipairs(schema.required or {}) do
      if type(name) ~= "string" or not (schema.properties or {})[name] then
        return false, "required fields must name declared object properties"
      end
    end
    if schema.additional_properties ~= nil and type(schema.additional_properties) ~= "boolean" then
      return false, "additional_properties must be boolean"
    end
  elseif schema.type == "array" and schema.items ~= nil then
    local ok, err = valid_schema(schema.items, depth + 1)
    if not ok then return false, "array item: " .. err end
  end
  return true
end

local function valid_action_id(id)
  if type(id) ~= "string" then return false end
  local segments = 0
  for segment in (id .. "."):gmatch("(.-)%.") do
    if not segment:match("^[a-z][a-z0-9_-]*$") then return false end
    segments = segments + 1
  end
  return segments > 1
end

local function validate_value(schema, value, path, depth)
  depth = depth or 0
  if depth > 16 then return "argument value is nested too deeply" end
  local expected = schema.type
  local actual = type(value)
  local valid = expected == "object" and actual == "table" and (not is_array(value) or next(value) == nil)
    or expected == "array" and is_array(value)
    or expected == "string" and actual == "string"
    or expected == "boolean" and actual == "boolean"
    or expected == "number" and actual == "number"
    or expected == "integer" and actual == "number" and value % 1 == 0
  if not valid then return path .. " must be " .. expected end

  if schema.enum then
    local found = false
    for _, option in ipairs(schema.enum) do
      if value == option then found = true; break end
    end
    if not found then return path .. " must match one of the declared values" end
  end
  if expected == "string" then
    if schema.min_length and #value < schema.min_length then return path .. " is shorter than its minimum length" end
    if schema.max_length and #value > schema.max_length then return path .. " is longer than its maximum length" end
  elseif expected == "number" or expected == "integer" then
    if schema.minimum and value < schema.minimum then return path .. " is below its minimum" end
    if schema.maximum and value > schema.maximum then return path .. " is above its maximum" end
  elseif expected == "array" and schema.items then
    for index, item in ipairs(value) do
      local err = validate_value(schema.items, item, path .. "[" .. index .. "]", depth + 1)
      if err then return err end
    end
  elseif expected == "object" then
    local properties = schema.properties or {}
    for _, name in ipairs(schema.required or {}) do
      if value[name] == nil then return path .. "." .. name .. " is required" end
    end
    for name, item in pairs(value) do
      local property = properties[name]
      if not property then
        if schema.additional_properties ~= true then return path .. "." .. tostring(name) .. " is not allowed" end
      else
        local err = validate_value(property, item, path .. "." .. name, depth + 1)
        if err then return err end
      end
    end
  end
  return nil
end

local function validate_action(action)
  if type(action) ~= "table" then return nil, "action must be a plain record" end
  if not valid_action_id(action.id) then
    return nil, "action id must be a namespaced lowercase identifier"
  end
  for _, field in ipairs({ "title", "category" }) do
    if type(action[field]) ~= "string" or action[field] == "" then return nil, "action " .. field .. " is required" end
  end
  if not scopes[action.scope] then return nil, "action scope is unsupported" end
  if type(action.available) ~= "function" then return nil, "action available(ctx) is required" end
  if type(action.run) ~= "function" then return nil, "action run(ctx, args) is required" end
  if action.checked ~= nil and type(action.checked) ~= "function" then return nil, "action checked(ctx) must be a function" end
  if action.args_schema ~= nil then
    local ok, err = valid_schema(action.args_schema)
    if not ok then return nil, err end
  end
  return true
end

local function copy_action(action)
  return {
    id = action.id,
    title = action.title,
    category = action.category,
    scope = action.scope,
    available = action.available,
    checked = action.checked,
    run = action.run,
    args_schema = action.args_schema and vim.deepcopy(action.args_schema) or nil,
  }
end

local function availability(record, context)
  local ok, state = pcall(record.action.available, context or {})
  if not ok then return { enabled = false, code = "availability_error", reason = message(state) } end
  if type(state) ~= "table" or type(state.enabled) ~= "boolean" then
    return { enabled = false, code = "invalid_availability", reason = "action returned no boolean enabled state" }
  end
  local result = { enabled = state.enabled }
  if state.reason ~= nil then result.reason = message(state.reason) end
  if state.code ~= nil then result.code = message(state.code) end
  return result
end

function M.new()
  return setmetatable({ registrations = {} }, Registry)
end

function Registry:register(action, opts)
  opts = opts or {}
  local valid, validation_error = validate_action(action)
  if not valid then return nil, { code = "invalid_action", message = validation_error } end
  local previous = self.registrations[action.id]
  if previous and opts.replace ~= true then
    return nil, { code = "duplicate_action", message = "action is already registered: " .. action.id }
  end
  if opts.scope ~= nil and (type(opts.scope) ~= "table" or type(opts.scope.defer) ~= "function") then
    return nil, { code = "invalid_scope", message = "action owner must be a disposable scope" }
  end

  local id = action.id
  local record = { id = id, action = copy_action(action), previous = previous, active = true }
  self.registrations[id] = record
  local registry = self
  local handle = {}
  function handle:dispose()
    if not record.active then return false end
    record.active = false
    if registry.registrations[id] == record then
      local fallback = record.previous
      while fallback and not fallback.active do fallback = fallback.previous end
      registry.registrations[id] = fallback
    end
    return true
  end
  function handle:is_active()
    return record.active
  end

  if opts.scope then
    local owner, owner_error = opts.scope:defer(function() handle:dispose() end, "action:" .. id, "action")
    if not owner then
      handle:dispose()
      return nil, owner_error or { code = "scope_disposed", message = "action owner scope is disposed" }
    end
  end
  return handle
end

function Registry:execute(id, context, args)
  local record = self.registrations[id]
  if not record or not record.active then return error_result("unknown_action", "action is not registered: " .. tostring(id)) end
  local available = availability(record, context)
  if not available.enabled then
    return error_result(available.code or "unavailable", available.reason or "action is unavailable")
  end

  if args == nil then args = {} end
  if record.action.args_schema then
    local argument_error = validate_value(record.action.args_schema, args, "args")
    if argument_error then return error_result("invalid_arguments", argument_error) end
  elseif type(args) ~= "table" then
    return error_result("invalid_arguments", "args must be a table")
  end

  local ok, result, run_error = pcall(record.action.run, context or {}, vim.deepcopy(args))
  if not ok then return error_result("action_error", message(result)) end
  if result == nil and type(run_error) == "table" and type(run_error.code) == "string" and type(run_error.message) == "string" then
    return error_result(run_error.code, message(run_error.message))
  end
  return { ok = true, value = result }
end

function Registry:list(context)
  local ids = {}
  for id, record in pairs(self.registrations) do
    if record.active then ids[#ids + 1] = id end
  end
  table.sort(ids)

  local result = {}
  for _, id in ipairs(ids) do
    local action = self.registrations[id].action
    local projection = {
      id = action.id,
      title = action.title,
      category = action.category,
      scope = action.scope,
      available = availability(self.registrations[id], context),
      args_schema = action.args_schema and vim.deepcopy(action.args_schema) or nil,
    }
    if action.checked then
      local ok, checked = pcall(action.checked, context or {})
      if ok and type(checked) == "boolean" then
        projection.checked = checked
      else
        projection.checked_error = ok and "checked(ctx) must return a boolean" or message(checked)
      end
    end
    result[#result + 1] = projection
  end
  return result
end

function Registry:inventory()
  local result = {}
  for id, record in pairs(self.registrations) do
    if record.active then result[#result + 1] = id end
  end
  table.sort(result)
  return result
end

return M
