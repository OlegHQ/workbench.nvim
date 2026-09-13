local M = {}
local app

local function normalize_config(config)
  if config == nil then config = {} end
  local Settings = require("workbench.services.settings")
  return Settings.validate_config(config)
end

local function normalize_options(options)
  if options == nil then return { source = "setup" } end
  if type(options) ~= "table" then return nil, { code = "invalid_config", message = "setup metadata must be a table" } end
  for key in pairs(options) do
    if key ~= "source" and key ~= "replace_source" then
      return nil, { code = "invalid_config", message = "unknown setup metadata: " .. tostring(key) }
    end
  end
  if options.replace_source ~= nil and type(options.replace_source) ~= "boolean" then
    return nil, { code = "invalid_config", message = "replace_source must be boolean" }
  end
  local source = options.source or "setup"
  if type(source) ~= "string" or source == "" or #source > 64 then
    return nil, { code = "invalid_config", message = "setup source must be a non-empty short string" }
  end
  return { source = source, replace_source = options.replace_source }
end

function M.validate_config(config)
  return normalize_config(config)
end

function M.setup(config, options)
  local normalized, validation_error = normalize_config(config)
  if not normalized then return nil, validation_error end
  local metadata, metadata_error = normalize_options(options)
  if not metadata then return nil, metadata_error end
  if not app then
    local ok, compose = pcall(require, "workbench.compose")
    if not ok then return nil, { code = "composition_error", message = tostring(compose) } end
    local candidate, compose_error = compose.new()
    if not candidate then return nil, compose_error or { code = "composition_error", message = "could not construct workbench" } end
    local ok, err = candidate:configure(normalized, metadata)
    if not ok then candidate:dispose(); return nil, err end
    app = candidate
  else
    local ok, err = app:configure(normalized, metadata)
    if not ok then return nil, err end
  end
  return M.get_status()
end

function M.execute(action_id, args, context)
  if not app then
    return { ok = false, error = { code = "disabled", message = "workbench is not set up" } }
  end
  return app:execute(action_id, context, args)
end

function M.open(view_id, options)
  if not app then
    return nil, { code = "not_setup", message = "workbench is not set up; run :Workbench enable before opening a view" }
  end
  return app:open(view_id, options)
end

function M.close(view_id)
  if not app then return false end
  return app:close(view_id)
end

function M.register_capability(id, installer)
  if not app then
    return nil, { code = "not_setup", message = "call setup() before registering capabilities" }
  end
  return app:register_capability(id, installer)
end

function M.register_setting_adapter(id, adapter, options)
  if not app then
    return nil, { code = "not_setup", message = "call setup() before registering setting adapters" }
  end
  return app:register_setting_adapter(id, adapter, options)
end

function M.get_config()
  if not app then return nil end
  return app:get_config()
end

function M.restore_config(snapshot)
  if not app then return nil, { code = "not_setup", message = "workbench is not set up" } end
  local ok, err = app:restore_config(snapshot)
  if not ok then return nil, err end
  return M.get_status()
end

function M.list_sessions()
  if not app then return nil, { code = "not_setup", message = "call setup() before listing saved workbench sessions" } end
  return app:list_sessions()
end

function M.save_session(snapshot)
  if not app then return nil, { code = "not_setup", message = "call setup() before saving a workbench session" } end
  return app:save_session(snapshot)
end

function M.restore_session(id)
  if not app then return nil, { code = "not_setup", message = "call setup() before restoring a workbench session" } end
  return app:restore_session(id)
end

function M.delete_session(id)
  if not app then return nil, { code = "not_setup", message = "call setup() before deleting a workbench session" } end
  return app:delete_session(id)
end

function M.get_status(context)
  if not app then
    local settings = require("workbench.services.settings").new()
    local config = {
      settings = settings:list(context),
      editor_settings = settings:adapter_snapshot(),
    }
    settings:dispose()
    return {
      state = "disabled",
      reason = "not_setup",
      capabilities = {},
      actions = {},
      resources = { name = "workbench", alive = false, resources = {}, resource_count = 0, pending_callbacks = 0 },
      settings = config.settings,
      editor_settings = config.editor_settings,
    }
  end
  return app:get_status(context)
end

function M.command(arguments)
  local command = type(arguments) == "string" and vim.trim(arguments) or ""
  if command == "" or command == "status" then
    local status = M.get_status()
    local message = "Workbench: " .. status.state
    if status.reason then message = message .. " (" .. status.reason .. ")" end
    vim.notify(message, vim.log.levels.INFO)
    return status
  end

  if command == "enable" or command == "disable" then
    local enabled = command == "enable"
    local status, err = M.setup({ enabled = enabled }, { source = "command", replace_source = true })
    if not status then
      vim.notify("Workbench " .. command .. " failed: " .. tostring(err and err.message or err), vim.log.levels.ERROR)
      return nil, err
    end
    vim.notify(enabled and "Workbench enabled" or "Workbench disabled", vim.log.levels.INFO)
    return status
  end

  if command == "files" or command == "search" or command == "outline" or command == "problems" then
    local view, err = M.open(command)
    if not view then
      vim.notify("Workbench " .. command .. " unavailable: " .. tostring(err and err.message or err), vim.log.levels.WARN)
      return nil, err
    end
    return view
  end

  if command == "close" then
    local closed, err = M.close()
    if err then vim.notify("Workbench close failed: " .. tostring(err.message or err), vim.log.levels.WARN) end
    return closed, err
  end

  vim.notify("Usage: :Workbench [status|enable|disable|files|outline|problems|search|close]", vim.log.levels.ERROR)
  return nil, { code = "invalid_command", message = "unsupported Workbench command" }
end

return M
