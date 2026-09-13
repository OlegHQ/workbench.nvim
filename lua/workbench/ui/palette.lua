local Scope = require("workbench.core.scope")

local M = {}
local Palette = {}
Palette.__index = Palette

local function contains(haystack, needle)
  if needle == "" then return true end
  return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

local function action_items(palette)
  local projection = palette.actions:list(palette.context())
  local items, by_id = {}, {}
  for _, action in ipairs(projection) do
    local enabled = action.available.enabled
    local checked = action.checked == nil and "" or (action.checked and " · on" or " · off")
    local availability = enabled and "available" or ("unavailable: " .. tostring(action.available.reason or action.available.code or "unknown"))
    local item = {
      id = action.id,
      kind = "action",
      label = action.title,
      detail = table.concat({ palette.bindings[action.id] or "", action.category, action.scope, availability .. checked }, " · "),
      payload = { action = action },
    }
    by_id[action.id] = action
    if contains(table.concat({ action.id, action.title, action.category, availability }, " "), palette.filter) then
      items[#items + 1] = item
    end
  end
  return items, by_id
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then return nil, "palette requires a native layout manager" end
  if type(deps.actions) ~= "table" or type(deps.actions.list) ~= "function" or type(deps.actions.execute) ~= "function" then
    return nil, "palette requires the shared action registry"
  end
  return setmetatable({
    layout = deps.layout,
    actions = deps.actions,
    bindings = deps.bindings or {},
    context = type(deps.context) == "function" and deps.context or function() return deps.context or {} end,
    input = type(deps.input) == "function" and deps.input or vim.ui.input,
    on_result = deps.on_result,
    scope = Scope.new("workbench-action-palette"),
    active = {},
    disposed = false,
  }, Palette)
end

function Palette:_show(palette)
  if palette.closed or not palette.scope.alive then return false end
  local items, by_id = action_items(palette)
  palette.by_id = by_id
  local title = "Actions · Enter runs · / filters · disabled actions explain why"
  if palette.error then title = title .. " · " .. palette.error end
  palette.view.title = title
  if palette.error then
    table.insert(items, 1, { id = "palette-message", kind = "notice", label = palette.error, selectable = false })
  end
  return palette.view:update({ status = "ready", items = items })
end

function Palette:_close(palette)
  if palette.closed then return false end
  palette.closed = true
  self.active[palette.tab] = nil
  if palette.scope.alive then palette.scope:dispose() end
  return true
end

function Palette:open(opts)
  opts = opts or {}
  if self.disposed then return nil, { code = "disposed", message = "action palette is disposed" } end
  local tab = opts.tab or vim.api.nvim_get_current_tabpage()
  if self.active[tab] and not self.active[tab].closed then return self.active[tab].view end
  local scope, scope_err = self.scope:child("palette:" .. tostring(tab))
  if not scope then return nil, scope_err end
  local palette = {
    tab = tab,
    scope = scope,
    actions = self.actions,
    bindings = self.bindings,
    filter = opts.filter or "",
    context_value = opts.context,
    error = nil,
    closed = false,
  }
  palette.context = function()
    if type(palette.context_value) == "function" then return palette.context_value() end
    return palette.context_value or self.context()
  end
  local function close()
    self:_close(palette)
    return self.layout:close("workbench-palette", tab)
  end
  local function filter(view)
    self.input({ prompt = "Filter actions: ", default = palette.filter }, function(value)
      if palette.closed or not palette.scope.alive or value == nil then return end
      palette.filter = value
      palette.error = nil
      self:_show(palette)
    end)
  end
  local options = {
    id = "workbench-palette",
    title = "Action Palette",
    kind = "list",
    placement = "results",
    model = { status = "ready", items = {} },
    focus = opts.focus ~= false,
    help_lines = { "Enter: execute action", "/: filter by title/category/ID", "Unavailable actions remain visible with their reason", "q: close palette" },
    keymaps = {
      ["/"] = { desc = "Filter workbench actions", run = filter },
      ["<CR>"] = { desc = "Execute selected action", run = function(view)
        view:_sync_selection()
        local selected = palette.by_id and palette.by_id[view.selected_id]
        if not selected then return end
        if not selected.available.enabled then
          palette.error = selected.available.reason or "action is unavailable"
          self:_show(palette)
          return
        end
        local result = self.actions:execute(selected.id, palette.context(), {})
        if self.on_result then pcall(self.on_result, selected.id, result) end
        if not result.ok then
          palette.error = result.error.message
          self:_show(palette)
          return
        end
        self:_close(palette)
        self.layout:close("workbench-palette", tab)
      end },
    },
    on_dispose = function() self:_close(palette) end,
  }
  local view, mount_err = self.layout:mount(options)
  if not view then scope:dispose(); return nil, mount_err end
  palette.view = view
  self.active[tab] = palette
  self:_show(palette)
  return view
end

function Palette:close(tab)
  local target = tab or vim.api.nvim_get_current_tabpage()
  local palette = self.active[target]
  if not palette then return false end
  self:_close(palette)
  return self.layout:close("workbench-palette", target)
end

function Palette:status()
  local active = 0
  for _, palette in pairs(self.active) do if not palette.closed then active = active + 1 end end
  return { disposed = self.disposed, active = active, resources = self.scope:inventory() }
end

function Palette:dispose()
  if self.disposed then return false end
  self.disposed = true
  local tabs = {}
  for tab in pairs(self.active) do tabs[#tabs + 1] = tab end
  for _, tab in ipairs(tabs) do self:close(tab) end
  self.scope:dispose()
  return true
end

return M
