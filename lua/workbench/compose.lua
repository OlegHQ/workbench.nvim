local Scope = require("workbench.core.scope")
local ActionRegistry = require("workbench.core.actions")
local Settings = require("workbench.services.settings")
local SettingsController = require("workbench.controllers.settings")

local M = {}
local App = {}
App.__index = App

local function error_value(code, text)
  return { code = code, message = text }
end

local function dispose_installed(scope, id, message)
  local report = scope:dispose()
  local details = message
  if report.error_count > 0 then details = details .. "; cleanup reported " .. report.error_count .. " error(s)" end
  return nil, error_value("capability_install_failed", details)
end

function M.new()
  local scope = Scope.new("workbench")
  local actions = ActionRegistry.new()
  local app
  local settings = Settings.new({ apply = function()
    if app and app.runtime and app.settings:get("enabled").effective then return app.runtime:apply_settings() end
    return true
  end })
  local settings_controller, controller_error = SettingsController.new({ settings = settings, actions = actions, scope = scope })
  if not settings_controller then
    scope:dispose()
    return nil, controller_error
  end
  app = setmetatable({
    scope = scope,
    actions = actions,
    settings = settings,
    settings_controller = settings_controller,
    runtime = nil,
    persistence = nil,
    capabilities = {},
    state = "disabled",
    disposed = false,
  }, App)
  return app
end

function App:set_enabled(enabled)
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  if type(enabled) ~= "boolean" then return nil, error_value("invalid_config", "enabled must be boolean") end
  return self:configure({ enabled = enabled })
end

function App:configure(config, options)
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  local was_enabled = self.state == "enabled"
  local configured, configure_error = self.settings:configure(config, options)
  if not configured then return nil, configure_error end
  local enabled = self.settings:get("enabled").effective
  self.state = enabled and "enabled" or "disabled"
  if was_enabled and not enabled and self.runtime then
    self.runtime:dispose()
    self.runtime = nil
  end
  return true
end

function App:_runtime()
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  if self.state ~= "enabled" then
    return nil, error_value("disabled", "workbench is disabled; run :Workbench enable before opening a view")
  end
  if self.runtime then return self.runtime end
  local ok, module = pcall(require, "workbench.runtime")
  if not ok then return nil, error_value("runtime_unavailable", tostring(module)) end
  local runtime, err = module.new(self)
  if not runtime then return nil, err or error_value("runtime_unavailable", "workbench runtime could not be created") end
  self.runtime = runtime
  return runtime
end

function App:open(view_id, opts)
  local runtime, err = self:_runtime()
  if not runtime then return nil, err end
  return runtime:open(view_id, opts)
end

function App:close(view_id)
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  if self.state ~= "enabled" then return false end
  if not self.runtime then return false end
  return self.runtime:close(view_id)
end

function App:get_config()
  return self.settings:config_snapshot()
end

function App:_persistence_service()
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  if self.persistence then return self.persistence end
  local ok, module = pcall(require, "workbench.services.persistence")
  if not ok then return nil, error_value("persistence_unavailable", tostring(module)) end
  local service, service_error = module.new()
  if not service then return nil, service_error or error_value("persistence_unavailable", "could not construct session persistence") end
  self.persistence = service
  return service
end

function App:list_sessions()
  local service, service_error = self:_persistence_service()
  if not service then return nil, service_error end
  return service:list()
end

function App:save_session(snapshot)
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  local persist = self.settings:get("session.persist", { session_id = tostring(vim.api.nvim_get_current_tabpage()) })
  if not persist or not persist.effective then
    return nil, error_value("persistence_disabled", "enable session.persist before saving a session")
  end
  local service, service_error = self:_persistence_service()
  if not service then return nil, service_error end
  return service:save(snapshot)
end

function App:restore_session(id)
  local service, service_error = self:_persistence_service()
  if not service then return nil, service_error end
  return service:restore(id)
end

function App:delete_session(id)
  local service, service_error = self:_persistence_service()
  if not service then return nil, service_error end
  return service:delete(id)
end

function App:restore_config(snapshot)
  if self.disposed then return nil, error_value("app_disposed", "workbench application has been disposed") end
  local was_enabled = self.state == "enabled"
  local restored, restore_error = self.settings:restore_config(snapshot)
  if not restored then return nil, restore_error end
  local enabled = self.settings:get("enabled").effective
  self.state = enabled and "enabled" or "disabled"
  if was_enabled and not enabled and self.runtime then
    self.runtime:dispose()
    self.runtime = nil
  end
  return true
end

function App:register_setting_adapter(id, adapter, options)
  if self.disposed or not self.scope.alive then
    return nil, error_value("app_disposed", "workbench application has been disposed")
  end
  if options ~= nil and type(options) ~= "table" then
    return nil, error_value("invalid_adapter", "setting adapter options must be a table")
  end
  for key in pairs(options or {}) do
    if key ~= "replace" then
      return nil, error_value("invalid_adapter", "unknown setting adapter option: " .. tostring(key))
    end
  end
  if options and options.replace ~= nil and type(options.replace) ~= "boolean" then
    return nil, error_value("invalid_adapter", "setting adapter replace option must be boolean")
  end
  local opts = { scope = self.scope, replace = options and options.replace }
  return self.settings:register_adapter(id, adapter, opts)
end

function App:register_capability(id, installer)
  if self.disposed or not self.scope.alive then
    return nil, error_value("app_disposed", "workbench application has been disposed")
  end
  if type(id) ~= "string" or not id:match("^[a-z][a-z0-9_-]*$") then
    return nil, error_value("invalid_capability", "capability id must be a lowercase identifier")
  end
  if type(installer) ~= "function" then
    return nil, error_value("invalid_capability", "capability installer must be a function")
  end
  if self.capabilities[id] then
    return nil, error_value("duplicate_capability", "capability is already registered: " .. id)
  end

  local scope, scope_error = self.scope:child("capability:" .. id)
  if not scope then return nil, scope_error end
  local context = { id = id, scope = scope, actions = self.actions }
  local ok, cleanup, install_error = pcall(installer, context)
  if not ok then return dispose_installed(scope, id, tostring(cleanup)) end
  if cleanup == false or (cleanup == nil and install_error ~= nil) then
    return dispose_installed(scope, id, tostring(install_error or "capability installer declined registration"))
  end
  if cleanup ~= nil and cleanup ~= true and type(cleanup) ~= "function"
    and not (type(cleanup) == "table" and type(cleanup.dispose) == "function") then
    return dispose_installed(scope, id, "installer must return a disposer, disposable handle, or nil")
  end
  if not scope.alive then return nil, error_value("capability_install_failed", "installer disposed its capability scope") end
  if type(cleanup) == "function" then
    local _, err = scope:defer(cleanup, "capability-disposer:" .. id, "capability")
    if err then return dispose_installed(scope, id, err.message) end
  elseif type(cleanup) == "table" then
    local _, err = scope:defer(function() cleanup:dispose() end, "capability-disposer:" .. id, "capability")
    if err then return dispose_installed(scope, id, err.message) end
  end

  local entry = { id = id, scope = scope, active = true }
  local app = self
  local registration_cleanup, registration_error = scope:defer(function()
    entry.active = false
    if app.capabilities[id] == entry then app.capabilities[id] = nil end
  end, "capability-registration:" .. id, "registration")
  if not registration_cleanup then
    return dispose_installed(scope, id, registration_error and registration_error.message or "could not own capability registration")
  end
  self.capabilities[id] = entry

  local handle = {}
  function handle:dispose()
    if not entry.active then return false end
    return scope:dispose()
  end
  function handle:is_active()
    return entry.active
  end
  return handle
end

function App:execute(action_id, context, args)
  if self.disposed then return { ok = false, error = error_value("app_disposed", "workbench application has been disposed") } end
  if self.state ~= "enabled" then
    return { ok = false, error = error_value("disabled", "workbench is disabled; setup must explicitly enable it") }
  end
  return self.actions:execute(action_id, context, args)
end

function App:get_status(context)
  local capabilities = {}
  for id, entry in pairs(self.capabilities) do
    if entry.active then
      capabilities[#capabilities + 1] = {
        id = id,
        state = "registered",
        resources = entry.scope:inventory(),
      }
    end
  end
  table.sort(capabilities, function(left, right) return left.id < right.id end)
  return {
    state = self.disposed and "disabled" or self.state,
    reason = self.disposed and "disposed" or (self.state == "disabled" and "not_enabled" or nil),
    capabilities = capabilities,
    actions = self.actions:list(context),
    settings = self.settings:list(context),
    editor_settings = self.settings:adapter_snapshot(),
    settings_controller = self.settings_controller:status(),
    resources = self.scope:inventory(),
    runtime = self.runtime and self.runtime:status() or nil,
  }
end

function App:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  self.state = "disabled"
  if self.runtime then self.runtime:dispose(); self.runtime = nil end
  self.disposal_report = self.scope:dispose()
  if self.persistence then self.persistence:dispose(); self.persistence = nil end
  self.settings:dispose()
  return self.disposal_report
end

return M
