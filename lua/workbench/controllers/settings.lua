local M = {}
local Controller = {}
Controller.__index = Controller

local editor_settings = {
  { id = "completion", title = "Toggle completion", action = "settings.toggle_completion" },
  { id = "formatting", title = "Toggle format on save", action = "settings.toggle_formatting" },
  { id = "diagnostics", title = "Toggle inline diagnostics", action = "settings.toggle_diagnostics" },
}

local function unavailable(reason)
  return { enabled = false, reason = reason }
end

function M.new(deps)
  if type(deps) ~= "table" or type(deps.settings) ~= "table" or type(deps.actions) ~= "table"
    or type(deps.actions.register) ~= "function" or type(deps.scope) ~= "table" or type(deps.scope.child) ~= "function" then
    return nil, { code = "invalid_dependencies", message = "settings controller requires settings, actions, and an owner scope" }
  end
  local scope, scope_error = deps.scope:child("settings-controller")
  if not scope then return nil, scope_error end
  local self = setmetatable({ settings = deps.settings, actions = deps.actions, scope = scope, disposed = false }, Controller)

  for _, spec in ipairs(editor_settings) do
    local adapter_id = spec.id
    local action = {
      id = spec.action,
      title = spec.title,
      category = "Settings",
      scope = "global",
      available = function(context)
        local state, err = self.settings:adapter_state(adapter_id, context)
        if not state then return unavailable(err and err.message or "editor setting is unavailable") end
        if not state.available then return unavailable(state.reason or "editor setting is unavailable") end
        return { enabled = true, reason = state.state == "pending" and state.reason or nil }
      end,
      checked = function(context)
        local state = self.settings:adapter_state(adapter_id, context)
        return state ~= nil and state.effective == true
      end,
      args_schema = {
        type = "object",
        properties = { enabled = { type = "boolean" } },
        additional_properties = false,
      },
      run = function(context, args)
        local state, err = self.settings:adapter_state(adapter_id, context)
        if not state or not state.available then
          return nil, err or { code = "adapter_unavailable", message = state and state.reason or "editor setting is unavailable" }
        end
        local value = args.enabled
        if value == nil then value = not state.effective end
        return self.settings:set_adapter(adapter_id, value, context)
      end,
    }
    local handle, register_error = self.actions:register(action, { scope = scope })
    if not handle then
      scope:dispose()
      return nil, register_error
    end
  end
  return self
end

function Controller:dispose()
  if self.disposed then return false end
  self.disposed = true
  return self.scope:dispose()
end

function Controller:status()
  local result = {}
  for _, spec in ipairs(editor_settings) do
    result[#result + 1] = self.settings:adapter_state(spec.id)
  end
  return { disposed = self.disposed, adapters = result, resources = self.scope:inventory() }
end

return M
