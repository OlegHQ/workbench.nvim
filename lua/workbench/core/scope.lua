local M = {}
local Scope = {}
Scope.__index = Scope

local MAX_ERRORS = 16
local MAX_ERROR_LENGTH = 384

local function safe_message(value)
  local message = tostring(value)
  if #message > MAX_ERROR_LENGTH then
    message = message:sub(1, MAX_ERROR_LENGTH - 3) .. "..."
  end
  return message
end

local function copy_report(report, already_disposed)
  local result = {
    name = report.name,
    ok = report.ok,
    already_disposed = already_disposed or false,
    disposed_count = report.disposed_count,
    error_count = report.error_count,
    errors = {},
  }
  for index, error in ipairs(report.errors) do
    result.errors[index] = { label = error.label, message = error.message }
  end
  return result
end

function M.new(name)
  return setmetatable({
    name = type(name) == "string" and name ~= "" and name or "scope",
    alive = true,
    generation = 1,
    entries = {},
    scheduled = {},
    pending_callbacks = 0,
    errors = {},
    error_count = 0,
    parent_handle = nil,
    report = nil,
  }, Scope)
end

function Scope:_record_error(label, message)
  self.error_count = self.error_count + 1
  if #self.errors < MAX_ERRORS then
    self.errors[#self.errors + 1] = { label = safe_message(label), message = safe_message(message) }
  end
end

function Scope:_detach(entry)
  if not entry.active then return false end
  entry.active = false
  local disposer = entry.disposer
  entry.disposer = nil
  for index = #self.entries, 1, -1 do
    if self.entries[index] == entry then
      table.remove(self.entries, index)
      break
    end
  end
  return disposer
end

local function make_handle(scope, entry)
  local handle = {}
  function handle:dispose()
    local disposer = scope:_detach(entry)
    if not disposer then return false end
    local ok, err = pcall(disposer)
    if not ok then
      scope:_record_error(entry.label, err)
      return nil, safe_message(err)
    end
    return true
  end
  function handle:forget()
    return scope:_detach(entry) ~= false
  end
  function handle:is_active()
    return entry.active
  end
  return handle
end

function Scope:defer(disposer, label, kind)
  if type(disposer) ~= "function" then
    return nil, { code = "invalid_disposer", message = "scope resource disposer must be a function" }
  end
  label = type(label) == "string" and label ~= "" and label or "resource"
  kind = type(kind) == "string" and kind ~= "" and kind or "resource"
  if not self.alive then
    local ok, err = pcall(disposer)
    if not ok then self:_record_error(label, err) end
    return nil, {
      code = "scope_disposed",
      message = ok and "scope is disposed; late resource was disposed immediately"
        or "scope is disposed; late resource disposer failed: " .. safe_message(err),
    }
  end

  local entry = { disposer = disposer, label = label, kind = kind, active = true }
  self.entries[#self.entries + 1] = entry
  return make_handle(self, entry)
end

function Scope:own(resource, disposer, label, kind)
  if type(disposer) ~= "function" then
    return nil, { code = "invalid_disposer", message = "owned resource requires a disposer function" }
  end
  local handle, err = self:defer(function() return disposer(resource) end, label, kind)
  if not handle then return nil, err end
  return resource, handle
end

function Scope:child(name)
  if not self.alive then
    return nil, { code = "scope_disposed", message = "cannot create a child under a disposed scope" }
  end
  local child = M.new(name or (self.name .. "/child"))
  local handle, err = self:defer(function() child:dispose() end, "child:" .. child.name, "scope")
  if not handle then
    child:dispose()
    return nil, err
  end
  child.parent_handle = handle
  return child
end

function Scope:schedule(callback, scheduler)
  if type(callback) ~= "function" then
    return nil, { code = "invalid_callback", message = "scheduled callback must be a function" }
  end
  if not self.alive then
    return nil, { code = "scope_disposed", message = "cannot schedule work in a disposed scope" }
  end
  scheduler = scheduler or vim.schedule
  if type(scheduler) ~= "function" then
    return nil, { code = "invalid_scheduler", message = "scheduler must be a function" }
  end

  local scope = self
  local ticket = { active = true, callback = callback, generation = self.generation }
  local function finish(run, ...)
    if not ticket.active then return false end
    ticket.active = false
    scope.scheduled[ticket] = nil
    scope.pending_callbacks = math.max(0, scope.pending_callbacks - 1)
    local scheduled_callback = ticket.callback
    ticket.callback = nil
    if not run or not scope.alive or ticket.generation ~= scope.generation then return false end
    local ok, err = pcall(scheduled_callback, ...)
    if not ok then
      scope:_record_error("scheduled callback", err)
      return nil, safe_message(err)
    end
    return true
  end
  function ticket:cancel()
    return finish(false)
  end

  self.scheduled[ticket] = true
  self.pending_callbacks = self.pending_callbacks + 1
  local ok, err = pcall(scheduler, function(...) return finish(true, ...) end)
  if not ok then
    ticket:cancel()
    return nil, { code = "schedule_failed", message = safe_message(err) }
  end
  return ticket
end

function Scope:inventory()
  local resources = {}
  for _, entry in ipairs(self.entries) do
    if entry.active then resources[#resources + 1] = { label = entry.label, kind = entry.kind } end
  end
  table.sort(resources, function(left, right)
    if left.kind == right.kind then return left.label < right.label end
    return left.kind < right.kind
  end)
  return {
    name = self.name,
    alive = self.alive,
    resources = resources,
    resource_count = #resources,
    pending_callbacks = self.pending_callbacks,
  }
end

function Scope:dispose()
  if not self.alive then return copy_report(self.report, true) end
  -- Owned cleanup may reenter disposal before the final report is available.
  self.report = {
    name = self.name,
    ok = self.error_count == 0,
    disposed_count = 0,
    error_count = self.error_count,
    errors = self.errors,
  }
  self.alive = false
  self.generation = self.generation + 1

  local scheduled = self.scheduled
  self.scheduled = {}
  for ticket in pairs(scheduled) do ticket:cancel() end

  local entries = self.entries
  self.entries = {}
  local disposed_count = 0
  for index = #entries, 1, -1 do
    local entry = entries[index]
    if entry.active then
      local disposer = entry.disposer
      entry.active = false
      entry.disposer = nil
      disposed_count = disposed_count + 1
      local ok, err = pcall(disposer)
      if not ok then self:_record_error(entry.label, err) end
    end
  end

  if self.parent_handle then
    self.parent_handle:forget()
    self.parent_handle = nil
  end
  self.report = {
    name = self.name,
    ok = self.error_count == 0,
    disposed_count = disposed_count,
    error_count = self.error_count,
    errors = self.errors,
  }
  return copy_report(self.report, false)
end

return M
