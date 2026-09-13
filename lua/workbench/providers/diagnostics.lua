local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")
local RootPolicy = require("workbench.core.root_policy")

local M = {}
local Provider = {}
Provider.__index = Provider

local SEVERITY = {
  [1] = "error",
  [2] = "warning",
  [3] = "information",
  [4] = "hint",
}
local next_provider_id = 0

local function count_record()
  return { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
end

local function copy_counts(counts)
  return {
    error = counts.error or 0,
    warning = counts.warning or 0,
    information = counts.information or 0,
    hint = counts.hint or 0,
    total = counts.total or 0,
  }
end

local function increment(counts, other, multiplier)
  for key, value in pairs(other or {}) do counts[key] = (counts[key] or 0) + value * multiplier end
end

local function compare_diagnostics(left, right)
  if left.severity ~= right.severity then return left.severity < right.severity end
  if left.lnum ~= right.lnum then return left.lnum < right.lnum end
  if left.col ~= right.col then return left.col < right.col end
  if left.end_lnum ~= right.end_lnum then return left.end_lnum < right.end_lnum end
  if left.end_col ~= right.end_col then return left.end_col < right.end_col end
  if left.source ~= right.source then return (left.source or "") < (right.source or "") end
  if left.code ~= right.code then return tostring(left.code or "") < tostring(right.code or "") end
  return left.message < right.message
end

local function copy_diagnostic(item)
  return {
    lnum = item.lnum,
    col = item.col,
    end_lnum = item.end_lnum,
    end_col = item.end_col,
    severity = item.severity,
    source = item.source,
    code = item.code,
    message = item.message,
    namespace = item.namespace,
    namespace_name = item.namespace_name,
  }
end

local function copy_report(report)
  local result = {
    resource = Resource.copy(report.resource),
    counts = copy_counts(report.counts),
    namespaces = {},
  }
  for _, namespace in ipairs(report.namespaces) do
    local copied = { id = namespace.id, name = namespace.name, counts = copy_counts(namespace.counts), diagnostics = {} }
    for index, diagnostic in ipairs(namespace.diagnostics) do copied.diagnostics[index] = copy_diagnostic(diagnostic) end
    result.namespaces[#result.namespaces + 1] = copied
  end
  return result
end

local function valid_integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function namespace_name(namespaces, namespace)
  local entry = namespaces[namespace]
  return type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" and entry.name or ("namespace " .. namespace)
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, { code = "invalid_options", message = "diagnostics options must be a table" } end
  local diagnostic = opts.diagnostic or vim.diagnostic
  local api = opts.api or vim.api
  if type(diagnostic) ~= "table" or type(diagnostic.get) ~= "function"
    or type(diagnostic.get_namespaces) ~= "function" then
    return nil, { code = "diagnostics_unavailable", message = "Neovim native diagnostics are unavailable" }
  end
  if type(api) ~= "table" or type(api.nvim_list_bufs) ~= "function"
    or type(api.nvim_buf_is_valid) ~= "function" or type(api.nvim_buf_get_name) ~= "function"
    or type(api.nvim_create_augroup) ~= "function" or type(api.nvim_create_autocmd) ~= "function"
    or type(api.nvim_del_augroup_by_id) ~= "function" then
    return nil, { code = "api_unavailable", message = "Neovim diagnostic event APIs are unavailable" }
  end
  return setmetatable({
    id = (function() next_provider_id = next_provider_id + 1; return next_provider_id end)(),
    diagnostic = diagnostic,
    api = api,
    scope = Scope.new("workbench-diagnostics-provider"),
    leases = {},
    buffers = {},
    namespace_cache = nil,
    next_lease_id = 0,
    active_scope = nil,
    group = nil,
    disposed = false,
    last_error = nil,
  }, Provider)
end

function Provider:_normalize(bufnr, diagnostics)
  if not self.api.nvim_buf_is_valid(bufnr) then return nil end
  local ok, name = pcall(self.api.nvim_buf_get_name, bufnr)
  if not ok or type(name) ~= "string" or name == "" then return nil end
  local resource = Resource.from_path(name)
  if not resource then return nil end

  if not self.namespace_cache then
    local namespaces_ok, namespaces = pcall(self.diagnostic.get_namespaces)
    self.namespace_cache = namespaces_ok and namespaces or {}
  end
  local namespaces = self.namespace_cache
  local grouped, total = {}, 0
  for _, raw in ipairs(type(diagnostics) == "table" and diagnostics or {}) do
    if type(raw) == "table" and valid_integer(raw.lnum) and valid_integer(raw.col)
      and type(raw.message) == "string" then
      local severity = valid_integer(raw.severity) and raw.severity or 1
      local severity_name = SEVERITY[severity]
      if severity_name then
        local namespace = valid_integer(raw.namespace) and raw.namespace or 0
        if namespaces[namespace] == nil then
          local refreshed_ok, refreshed = pcall(self.diagnostic.get_namespaces)
          if refreshed_ok and type(refreshed) == "table" then
            self.namespace_cache = refreshed
            namespaces = refreshed
          end
        end
        local group = grouped[namespace]
        if not group then
          group = { id = namespace, name = namespace_name(namespaces, namespace), counts = count_record(), diagnostics = {} }
          grouped[namespace] = group
        end
        local item = {
          lnum = raw.lnum,
          col = raw.col,
          end_lnum = valid_integer(raw.end_lnum) and raw.end_lnum or raw.lnum,
          end_col = valid_integer(raw.end_col) and raw.end_col or raw.col,
          severity = severity,
          source = type(raw.source) == "string" and raw.source or nil,
          code = (type(raw.code) == "string" or type(raw.code) == "number") and raw.code or nil,
          message = Resource.escape_display(raw.message),
          namespace = namespace,
          namespace_name = group.name,
        }
        group.diagnostics[#group.diagnostics + 1] = item
        group.counts[severity_name] = group.counts[severity_name] + 1
        group.counts.total = group.counts.total + 1
        total = total + 1
      end
    end
  end

  local ordered = {}
  local counts = count_record()
  for _, group in pairs(grouped) do
    table.sort(group.diagnostics, compare_diagnostics)
    increment(counts, group.counts, 1)
    ordered[#ordered + 1] = group
  end
  table.sort(ordered, function(left, right)
    if left.name == right.name then return left.id < right.id end
    return left.name < right.name
  end)
  if total == 0 then return nil, resource end
  return { resource = resource, counts = counts, namespaces = ordered }, resource
end

function Provider:_within(lease, path)
  if type(path) ~= "string" then return false end
  local contained = false
  for _, root in ipairs(lease.roots) do
    if RootPolicy.contains(root.path, path) then contained = true; break end
  end
  if not contained then return false end
  local scope = lease.workspace.scope
  if scope and scope.kind == "folder" then
    local folder_path = scope.resource and scope.resource.path
    return type(folder_path) == "string" and RootPolicy.contains(folder_path, path) or false
  end
  return true
end

function Provider:_publish(bufnr, diagnostics)
  local previous = self.buffers[bufnr]
  local next_report, resource = self:_normalize(bufnr, diagnostics)
  if not next_report and not previous then return false end
  if not resource and not previous then return false end
  local current_resource = resource or (previous and previous.resource)
  local function notify(changed_resource, report)
    if not changed_resource then return end
    local recipients = {}
    for _, lease in pairs(self.leases) do
      if lease.active and self:_within(lease, changed_resource.path) then recipients[#recipients + 1] = lease end
    end
    for _, lease in ipairs(recipients) do
      if lease.active then
        local okay, err = pcall(lease.callback, {
          kind = "changed",
          resource = Resource.copy(changed_resource),
          report = report and copy_report(report) or nil,
          coverage = "reported-only",
        })
        if not okay and not self.last_error then self.last_error = tostring(err) end
      end
    end
  end
  if previous and current_resource
    and (previous.resource.uri ~= current_resource.uri or previous.resource.path ~= current_resource.path) then
    notify(previous.resource, nil)
  end
  if next_report then
    self.buffers[bufnr] = next_report
  else
    self.buffers[bufnr] = nil
  end
  if not current_resource then return false end
  notify(current_resource, next_report)
  return true
end

function Provider:_read_buffer(bufnr)
  if not self.api.nvim_buf_is_valid(bufnr) then return self:_publish(bufnr, {}) end
  local ok, diagnostics = pcall(self.diagnostic.get, bufnr)
  if not ok then
    self.last_error = tostring(diagnostics)
    return false
  end
  return self:_publish(bufnr, diagnostics)
end

function Provider:_scan_buffers()
  local ok, buffers = pcall(self.api.nvim_list_bufs)
  if not ok or type(buffers) ~= "table" then
    self.last_error = tostring(buffers or "could not list existing buffers")
    return nil, { code = "buffer_scan_failed", message = "existing diagnostic buffers could not be read" }
  end
  for _, bufnr in ipairs(buffers) do
    if self.api.nvim_buf_is_valid(bufnr) then
      local name_ok, name = pcall(self.api.nvim_buf_get_name, bufnr)
      if name_ok and type(name) == "string" and name ~= "" then self:_read_buffer(bufnr) end
    end
  end
  return true
end

function Provider:_start()
  if self.active_scope then return true end
  local scope, scope_err = self.scope:child("diagnostics-leases")
  if not scope then return nil, scope_err end
  self.active_scope = scope
  local group_ok, group = pcall(self.api.nvim_create_augroup, "WorkbenchDiagnostics" .. tostring(self.id), { clear = true })
  if not group_ok then
    scope:dispose()
    self.active_scope = nil
    return nil, { code = "diagnostics_listener_failed", message = tostring(group) }
  end
  self.group = group
  local dispose_group, defer_err = scope:defer(function()
    pcall(self.api.nvim_del_augroup_by_id, group)
    if self.group == group then self.group = nil end
  end, "diagnostics-events", "autocmd")
  if not dispose_group then
    scope:dispose()
    self.active_scope = nil
    return nil, defer_err
  end
  local callbacks = {
    DiagnosticChanged = function(event)
      if not scope.alive then return end
      -- Event data is only the namespace being changed on some Nvim versions;
      -- read the current buffer snapshot to retain sibling namespace reports.
      self:_read_buffer(event.buf)
    end,
    BufWipeout = function(event)
      if not scope.alive then return end
      local previous = self.buffers[event.buf]
      if previous then self:_publish(event.buf, {}) end
    end,
  }
  for event_name, callback in pairs(callbacks) do
    local autocmd_ok, autocmd_id = pcall(self.api.nvim_create_autocmd, event_name, { group = group, callback = callback })
    if not autocmd_ok or type(autocmd_id) ~= "number" then
      scope:dispose()
      self.active_scope = nil
      return nil, { code = "diagnostics_listener_failed", message = tostring(autocmd_id) }
    end
  end
  local scanned, scan_err = self:_scan_buffers()
  if not scanned then
    scope:dispose()
    self.active_scope = nil
    self.buffers = {}
    return nil, scan_err
  end
  return true
end

function Provider:_stop_if_idle()
  if next(self.leases) ~= nil then return false end
  local active = self.active_scope
  self.active_scope = nil
  if active then active:dispose() end
  self.buffers = {}
  self.namespace_cache = nil
  return true
end

local Lease = {}
Lease.__index = Lease

function Lease:snapshot()
  if not self.active then return nil, { code = "lease_released", message = "diagnostics lease has been released" } end
  local reports = {}
  for _, report in pairs(self.provider.buffers) do
    if self.provider:_within(self, report.resource.path) then reports[#reports + 1] = copy_report(report) end
  end
  table.sort(reports, function(left, right) return left.resource.display_path < right.resource.display_path end)
  return { coverage = "reported-only", completeness = "unknown", reports = reports }
end

function Lease:release()
  if not self.active then return false end
  self.active = false
  self.provider.leases[self.id] = nil
  self.provider:_stop_if_idle()
  return true
end

Lease.dispose = Lease.release

function Provider:subscribe(workspace, callback)
  if self.disposed or not self.scope.alive then
    return nil, { code = "provider_disposed", message = "diagnostics provider is disposed" }
  end
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or type(workspace.roots) ~= "table" or #workspace.roots == 0 then
    return nil, { code = "invalid_workspace", message = "diagnostics require a workspace snapshot with roots" }
  end
  if type(callback) ~= "function" then return nil, { code = "invalid_callback", message = "diagnostics subscription requires a callback" } end
  local roots = {}
  for _, root in ipairs(workspace.roots) do
    if type(root) ~= "table" or type(root.path) ~= "string" then
      return nil, { code = "invalid_workspace", message = "diagnostic roots require native file paths" }
    end
    local path, path_err = Resource.normalize_absolute_path(root.path)
    if not path then return nil, { code = "invalid_workspace", message = path_err } end
    roots[#roots + 1] = { path = path, uri = root.uri }
  end
  local started, start_err = self:_start()
  if not started then return nil, start_err end
  self.next_lease_id = self.next_lease_id + 1
  local lease = setmetatable({
    id = self.next_lease_id,
    provider = self,
    workspace = workspace,
    roots = roots,
    callback = callback,
    active = true,
  }, Lease)
  self.leases[lease.id] = lease
  return lease
end

function Provider:status()
  local lease_count = 0
  for _ in pairs(self.leases) do lease_count = lease_count + 1 end
  return {
    disposed = self.disposed,
    active = self.active_scope ~= nil and self.active_scope.alive,
    lease_count = lease_count,
    buffer_count = vim.tbl_count(self.buffers),
    autocmd_groups = self.group and 1 or 0,
    hook_count = self.active_scope and 2 or 0,
    resources = self.active_scope and self.active_scope:inventory() or nil,
    last_error = self.last_error,
  }
end

function Provider:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  for _, lease in pairs(self.leases) do lease.active = false end
  self.leases = {}
  if self.active_scope then self.active_scope:dispose(); self.active_scope = nil end
  self.buffers = {}
  self.disposal_report = self.scope:dispose()
  return self.disposal_report
end

return M
