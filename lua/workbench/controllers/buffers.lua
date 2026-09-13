local Scope = require("workbench.core.scope")
local WorkingSet = require("workbench.services.buffers")

local M = {}
local Controller = {}
Controller.__index = Controller

local function error_value(code, message)
  return { code = code, message = message }
end

local function editor_window(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.bo[bufnr].buftype == "" and not vim.b[bufnr].workbench_preview then return win end
    end
  end
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then
    return nil, error_value("invalid_dependency", "Buffers controller requires the shared layout manager")
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.open_buffer) ~= "function"
    or type(deps.navigation.return_to_origin) ~= "function" then
    return nil, error_value("invalid_dependency", "Buffers controller requires shared buffer navigation")
  end
  return setmetatable({
    layout = deps.layout,
    navigation = deps.navigation,
    scope = Scope.new("workbench-buffers-controller"),
    sessions = {},
    next_id = 0,
    disposed = false,
  }, Controller)
end

function Controller:_rows(session)
  local items = {}
  for _, buffer in ipairs(session.snapshot.items) do
    local state = buffer.modified and "modified" or "saved"
    local detail = string.format("%s · %s · %s", buffer.filetype ~= "" and buffer.filetype or "plain text", state,
      buffer.visible and "visible" or "hidden")
    items[#items + 1] = {
      id = "buffer:" .. buffer.uri,
      kind = "buffer",
      label = buffer.path,
      detail = detail,
      payload = { bufnr = buffer.bufnr, uri = buffer.uri, path = buffer.path, modified = buffer.modified, changedtick = buffer.changedtick },
    }
  end
  if session.snapshot.truncated then
    items[#items + 1] = { id = "buffers:limit", kind = "notice", label = "Recent buffer list capped", detail = "Only the most recently used named buffers are shown", selectable = false }
  end
  return items
end

function Controller:_model(session)
  local count = session.snapshot.total
  local details = string.format("%d named loaded buffer%s", count, count == 1 and "" or "s")
  if session.snapshot.excluded.unnamed > 0 then details = details .. string.format(" · %d unnamed excluded", session.snapshot.excluded.unnamed) end
  if session.snapshot.excluded.special > 0 then details = details .. string.format(" · %d special excluded", session.snapshot.excluded.special) end
  if session.error then details = details .. " · " .. tostring(session.error.message or session.error.code or "buffer navigation failed") end
  return {
    status = "ready",
    title = "Buffers",
    header = { "Open and recent buffers", details },
    items = self:_rows(session),
  }
end

function Controller:_select(session, id, row, committed)
  if not committed then return true end
  local found
  for _, item in ipairs(session.snapshot.items) do
    if id == "buffer:" .. item.uri then found = item; break end
  end
  if not found then return false end
  local origin = session.origin
  local mode = origin and vim.api.nvim_buf_is_valid(origin.buf) and vim.bo[origin.buf].modified and origin.buf ~= found.bufnr and "split" or "current"
  local opened, err = self.navigation:open_buffer(found.bufnr, mode, origin, session.navigation_id)
  if not opened then
    session.error = err
    session.view:update(self:_model(session))
    return nil, err
  end
  session.last_opened = found.bufnr
  return opened
end

function Controller:open(opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, error_value("disposed", "Buffers controller is disposed") end
  local tab = opts.tab or vim.api.nvim_get_current_tabpage()
  if self.sessions[tab] then return self.sessions[tab].view end
  local origin_win = opts.win or editor_window(tab)
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    return nil, error_value("no_editor_window", "an editor window is required to open the buffer list")
  end
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  self.next_id = self.next_id + 1
  local id = "buffers:" .. tostring(self.next_id)
  local scope, scope_err = self.scope:child(id .. ":" .. tostring(tab))
  if not scope then return nil, scope_err end
  local session = {
    id = id,
    tab = tab,
    scope = scope,
    origin = { win = origin_win, buf = origin_buf, cursor = vim.api.nvim_win_get_cursor(origin_win),
      view = vim.api.nvim_win_call(origin_win, vim.fn.winsaveview), tab = tab },
    navigation_id = id .. ":navigation",
    snapshot = WorkingSet.list(),
  }
  self.sessions[tab] = session
  local owner = self
  scope:defer(function() if owner.sessions[tab] == session then owner.sessions[tab] = nil end end, "buffer-list-session:" .. id, "session")
  scope:defer(function() if session.last_opened then owner.navigation:return_to_origin(session.navigation_id) end end, "buffer-list-navigation:" .. id, "navigation")
  local view, view_err = self.layout:mount({
    id = "workbench-buffers",
    title = "Buffers",
    kind = "list",
    placement = "results",
    focus = opts.focus ~= false,
    model = self:_model(session),
    help_lines = { "j/k: recent buffers · Enter/o: open selected buffer · R: return · q: close" },
    keymaps = {
      o = { desc = "Open selected buffer", run = function() return session.view:activate(true) end },
      R = { desc = "Return from opened buffer", run = function()
        local restored, err = self.navigation:return_to_origin(session.navigation_id)
        if not restored and err and err.code ~= "no_navigation" then session.error = err end
        session.view:update(self:_model(session))
        return restored
      end },
    },
    on_select = function(selected_id, row, committed) return self:_select(session, selected_id, row, committed) end,
    on_dispose = function() scope:dispose() end,
  })
  if not view then scope:dispose(); return nil, view_err end
  session.view = view
  return view, session
end

function Controller:status()
  local sessions = {}
  for _, session in pairs(self.sessions) do
    sessions[#sessions + 1] = { id = session.id, tab = session.tab, buffers = session.snapshot.total, view = session.view and not session.view.closed }
  end
  table.sort(sessions, function(left, right) return tostring(left.tab) < tostring(right.tab) end)
  return { disposed = self.disposed, session_count = #sessions, sessions = sessions, resources = self.scope:inventory() }
end

function Controller:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  self.disposal_report = self.scope:dispose()
  return self.disposal_report
end

return M
