local Scope = require("workbench.core.scope")
local View = require("workbench.ui.view")

local M = {}
local Layout = {}
Layout.__index = Layout

local function win_key(win)
  return tostring(win)
end

local function valid_window(win, tab)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
    and (not tab or vim.api.nvim_win_get_tabpage(win) == tab)
end

local function is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  local buffer = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == ""
end

local function error_value(code, message)
  return { code = code, message = message }
end

function M.new(opts)
  opts = opts or {}
  local manager = setmetatable({
    scope = Scope.new("workbench-ui-layout"),
    tabs = {},
    windows = {},
    views = 0,
    hooks = nil,
    resize_ticket = nil,
    disposed = false,
    get_sidebar_settings = opts.get_sidebar_settings,
    options = {
      sidebar_width = math.max(16, math.min(80, tonumber(opts.sidebar_width) or 32)),
      sidebar_position = opts.sidebar_position or "left",
      results_height = math.max(6, math.min(16, tonumber(opts.results_height) or 8)),
      min_editor_width = math.max(40, tonumber(opts.min_editor_width) or 60),
      min_editor_height = math.max(6, tonumber(opts.min_editor_height) or 8),
      overlay_width = math.max(24, tonumber(opts.overlay_width) or 64),
    },
  }, Layout)
  return manager
end

function Layout:_install_hooks()
  if self.hooks then return true end
  if self.disposed then return nil, error_value("layout_disposed", "layout manager has been disposed") end
  local group = vim.api.nvim_create_augroup("WorkbenchLayout" .. tostring(self), { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = group,
    callback = function() self:_schedule_reflow() end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local record = self.windows[args.match]
      if record and not record.moving and record.active then
        local state = record.tab_state
        record.scope:dispose()
        if next(state.views) == nil and state.scope.alive then state.scope:dispose() end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      local closed_number = tonumber(vim.v.event.tab)
      if not closed_number then return end
      local closing = {}
      for _, state in pairs(self.tabs) do if state.tab_number == closed_number then closing[#closing + 1] = state end end
      for _, state in ipairs(closing) do state.scope:dispose() end
    end,
  })
  local handle, err = self.scope:defer(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    self.hooks = nil
  end, "layout-lifecycle-autocmds", "autocmd")
  if not handle then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return nil, err
  end
  self.hooks = handle
  return true
end

function Layout:_release_hooks_if_idle()
  if self.views ~= 0 or not self.hooks then return end
  local handle = self.hooks
  self.hooks = nil
  handle:dispose()
end

function Layout:_schedule_reflow()
  if self.disposed or self.resize_ticket then return end
  local ticket, err = self.scope:schedule(function()
    self.resize_ticket = nil
    local current_tab = vim.api.nvim_get_current_tabpage()
    local state = self.tabs[current_tab]
    if not state or not state.scope.alive then return end
    local records = {}
    for _, record in pairs(state.views) do records[#records + 1] = record end
    for _, record in ipairs(records) do
      if record.active then self:_place(record, true) end
    end
  end)
  if ticket then self.resize_ticket = ticket else self.last_error = err end
end

function Layout:_tab_state(tab)
  local state = self.tabs[tab]
  if state then return state end
  local scope, err = self.scope:child("tab:" .. tostring(tab))
  if not scope then return nil, err end
  state = {
    tab = tab,
    tab_number = vim.api.nvim_tabpage_get_number(tab),
    scope = scope,
    views = {},
    return_window = nil,
    return_buffer = nil,
  }
  local state_ref = state
  local _, state_error = scope:defer(function()
    if self.tabs[tab] == state_ref then self.tabs[tab] = nil end
  end, "tab-registration:" .. tostring(tab), "registration")
  if state_error then scope:dispose(); return nil, state_error end
  self.tabs[tab] = state
  return state
end

function Layout:_editor_target(state)
  if valid_window(state.return_window, state.tab) and is_editor_window(state.return_window) then
    return state.return_window
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if not self.windows[win_key(win)] and is_editor_window(win) then
      state.return_window = win
      state.return_buffer = vim.api.nvim_win_get_buf(win)
      return win
    end
  end
  return nil
end

function Layout:_geometry(view)
  local columns = vim.o.columns
  local lines = vim.o.lines
  local editor_width = self.options.min_editor_width
  local editor_height = self.options.min_editor_height
  local sidebar = self.get_sidebar_settings and self.get_sidebar_settings(vim.api.nvim_get_current_tabpage()) or {}
  local sidebar_width = sidebar.width or self.options.sidebar_width
  local sidebar_position = sidebar.position or self.options.sidebar_position
  if view.placement == "sidebar" and columns >= sidebar_width + editor_width + 1
    and lines >= editor_height + 5 then
    local width = math.min(sidebar_width, columns - editor_width - 1)
    return { mode = "split", command = sidebar_position == "right" and "botright vsplit" or "topleft vsplit", width = width }
  end
  if view.placement == "results" and lines >= self.options.results_height + editor_height + 5 then
    local height = math.min(self.options.results_height, lines - editor_height - 3)
    return { mode = "split", command = "botright split", height = height }
  end

  local width = math.max(1, math.min(self.options.overlay_width, columns - 4))
  local height = math.max(1, math.min(math.max(8, lines - 8), lines - 4))
  return {
    mode = "overlay",
    config = {
      relative = "editor",
      row = math.max(0, math.floor((lines - height) / 2)),
      col = math.max(0, math.floor((columns - width) / 2)),
      width = width,
      height = height,
      style = "minimal",
      border = "single",
      focusable = true,
    },
  }
end

function Layout:_forget_window(record, win)
  self.windows[win_key(win)] = nil
  if record.window == win then
    record.window = nil
    record.view:set_window(nil, nil)
  end
end

function Layout:_close_window(record, moving)
  local win = record.window
  local handle = record.window_handle
  record.window = nil
  record.window_handle = nil
  record.moving = moving == true
  if win then self.windows[win_key(win)] = nil end
  if handle then handle:dispose()
  elseif win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if record.view and record.view.window ~= nil then record.view:set_window(nil, nil) end
  record.moving = false
end

function Layout:_place(record, preserve_focus)
  if not record.active or not record.scope.alive then return nil, error_value("view_closed", "view is closed") end
  local state, view = record.tab_state, record.view
  if not vim.api.nvim_tabpage_is_valid(state.tab) then return nil, error_value("tab_closed", "view tab has closed") end
  local current_tab = vim.api.nvim_get_current_tabpage()
  if current_tab ~= state.tab then return true end

  local old_win = record.window
  local keep_focus = preserve_focus and old_win and vim.api.nvim_get_current_win() == old_win or false
  local restore_win = vim.api.nvim_get_current_win()
  local target = self:_editor_target(state)
  if not target then return nil, error_value("no_editor_window", "no normal editor window is available for this view") end
  if not valid_window(target, state.tab) then return nil, error_value("no_editor_window", "view return target is no longer valid") end

  local geometry = self:_geometry(view)
  if old_win then self:_close_window(record, true) end
  local buffer = view.buffer
  local desired_focus
  if preserve_focus then desired_focus = keep_focus else desired_focus = record.focus_on_mount end
  local opened, window_or_error
  if geometry.mode == "overlay" then
    opened, window_or_error = pcall(vim.api.nvim_open_win, buffer, desired_focus, geometry.config)
  else
    opened, window_or_error = pcall(vim.api.nvim_win_call, target, function()
      vim.cmd(geometry.command)
      local split = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(split, buffer)
      if geometry.width then vim.api.nvim_win_set_width(split, geometry.width) end
      if geometry.height then vim.api.nvim_win_set_height(split, geometry.height) end
      return split
    end)
  end
  if not opened then
    if valid_window(restore_win, state.tab) then pcall(vim.api.nvim_set_current_win, restore_win) end
    return nil, error_value("window_create_failed", tostring(window_or_error))
  end
  local window = window_or_error
  if not vim.api.nvim_win_is_valid(window) then return nil, error_value("window_create_failed", "Neovim returned an invalid panel window") end
  record.window = window
  record.mode = geometry.mode
  record.geometry = geometry
  record.window_key = win_key(window)
  record.moving = false
  self.windows[record.window_key] = record
  view:set_window(window, geometry.mode)
  if geometry.mode == "split" then
    if geometry.width then vim.wo[window].winfixwidth = true end
    if geometry.height then vim.wo[window].winfixheight = true end
  end
  local handle, err = record.scope:defer(function()
    self:_forget_window(record, window)
    if vim.api.nvim_win_is_valid(window) then pcall(vim.api.nvim_win_close, window, true) end
  end, "view-window:" .. record.id, "window")
  if not handle then
    self.windows[record.window_key] = nil
    pcall(vim.api.nvim_win_close, window, true)
    record.window = nil
    record.mode = nil
    return nil, err or error_value("scope_disposed", "view scope is disposed")
  end
  record.window_handle = handle

  if desired_focus and vim.api.nvim_win_is_valid(window) then
    pcall(vim.api.nvim_set_current_win, window)
  elseif valid_window(restore_win, state.tab) and restore_win ~= window then
    pcall(vim.api.nvim_set_current_win, restore_win)
  elseif valid_window(target, state.tab) then
    pcall(vim.api.nvim_set_current_win, target)
  end
  return true
end

function Layout:apply_settings()
  if self.disposed then return nil, error_value("layout_disposed", "layout manager has been disposed") end
  local state = self.tabs[vim.api.nvim_get_current_tabpage()]
  if not state then return true end
  for _, record in pairs(state.views) do
    if record.active and record.view.placement == "sidebar"
      and not vim.deep_equal(record.geometry, self:_geometry(record.view)) then
      local applied, err = self:_place(record, true)
      if not applied then return nil, err end
    end
  end
  return true
end

function Layout:_remove_record(record)
  if not record.active then return end
  record.active = false
  record.view.closed = true
  if record.tab_state.views[record.id] == record then record.tab_state.views[record.id] = nil end
  self.views = math.max(0, self.views - 1)
  self:_release_hooks_if_idle()
end

function Layout:_close_record(record)
  if not record.active then return false end
  local current = vim.api.nvim_get_current_win()
  local was_focused = record.window and current == record.window
  local target = record.tab_state.return_window
  self:_close_window(record, false)
  local report = record.scope:dispose()
  if was_focused and valid_window(target, record.tab_state.tab) then pcall(vim.api.nvim_set_current_win, target) end
  if next(record.tab_state.views) == nil and record.tab_state.scope.alive then record.tab_state.scope:dispose() end
  return report
end

function Layout:mount(opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, error_value("layout_disposed", "layout manager has been disposed") end
  if vim.fn.getcmdtype() ~= "" or vim.fn.getcmdwintype() ~= "" or vim.fn.mode():match("^[cRr!]") then
    return nil, error_value("prompt_active", "cannot open a workbench view over an active prompt")
  end
  if type(opts.id) ~= "string" or opts.id == "" then return nil, error_value("invalid_view", "view id is required") end
  if opts.placement ~= nil and opts.placement ~= "sidebar" and opts.placement ~= "results" then
    return nil, error_value("invalid_view", "placement must be sidebar or results")
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local state, state_error = self:_tab_state(current_tab)
  if not state then return nil, state_error end
  local replaced = state.views[opts.id]
  if replaced and opts.replace ~= true then return nil, error_value("duplicate_view", "view is already mounted: " .. opts.id) end
  local current_win = vim.api.nvim_get_current_win()
  if not self.windows[win_key(current_win)] and is_editor_window(current_win) then
    state.return_window = current_win
    state.return_buffer = vim.api.nvim_win_get_buf(current_win)
  end
  if not self:_editor_target(state) then
    if next(state.views) == nil then state.scope:dispose() end
    return nil, error_value("no_editor_window", "a normal editor window is required to mount a workbench view")
  end

  local hooks_ok, hooks_error = self:_install_hooks()
  if not hooks_ok then
    if next(state.views) == nil then state.scope:dispose() end
    return nil, hooks_error
  end
  local scope, scope_error = state.scope:child("view:" .. opts.id)
  if not scope then
    if next(state.views) == nil then state.scope:dispose() end
    self:_release_hooks_if_idle()
    return nil, scope_error
  end
  local record = {
    id = opts.id,
    scope = scope,
    tab_state = state,
    active = true,
    focus_on_mount = opts.focus ~= false,
    mode = nil,
  }
  local view_options = vim.tbl_extend("force", opts, {
    scope = scope,
    on_close = function() return self:_close_record(record) end,
  })
  local created, view_or_error, view_error = pcall(View.new, view_options)
  if not created or not view_or_error then
    scope:dispose()
    if next(state.views) == nil and state.scope.alive then state.scope:dispose() end
    self:_release_hooks_if_idle()
    return nil, error_value("view_create_failed", tostring(created and view_error or view_or_error))
  end
  record.view = view_or_error
  record.placement = record.view.placement
  local _, registration_error = scope:defer(function() self:_remove_record(record) end, "view-registration:" .. opts.id, "registration")
  if registration_error then
    scope:dispose()
    self:_release_hooks_if_idle()
    return nil, registration_error
  end
  if type(opts.on_dispose) == "function" then
    local _, disposal_error = scope:defer(function() opts.on_dispose(record.view) end, "view-dispose-callback:" .. opts.id, "callback")
    if disposal_error then
      scope:dispose()
      self:_release_hooks_if_idle()
      return nil, disposal_error
    end
  end
  state.views[opts.id] = record
  self.views = self.views + 1
  local placed, placement_error = self:_place(record, false)
  if not placed then
    if replaced and replaced.active then state.views[opts.id] = replaced end
    self:_close_record(record)
    if valid_window(current_win, current_tab) then pcall(vim.api.nvim_set_current_win, current_win) end
    return nil, placement_error
  end
  if replaced and replaced.active then self:_close_record(replaced) end
  return record.view
end

function Layout:get(id, tab)
  local state = self.tabs[tab or vim.api.nvim_get_current_tabpage()]
  local record = state and state.views[id]
  return record and record.view or nil
end

function Layout:close(id, tab)
  local state = self.tabs[tab or vim.api.nvim_get_current_tabpage()]
  local record = state and state.views[id]
  if not record then return false end
  return self:_close_record(record)
end

function Layout:status()
  local views = {}
  for tab, state in pairs(self.tabs) do
    for _, record in pairs(state.views) do
      views[#views + 1] = {
        id = record.id,
        tabpage = tab,
        window = record.window,
        buffer = record.view.buffer,
        mode = record.mode,
        placement = record.view.placement,
        selected_id = record.view.selected_id,
        resources = record.scope:inventory(),
      }
    end
  end
  table.sort(views, function(left, right)
    if left.tabpage == right.tabpage then return left.id < right.id end
    return left.tabpage < right.tabpage
  end)
  return { disposed = self.disposed, active_views = self.views, resources = self.scope:inventory(), views = views }
end

function Layout:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  self.disposal_report = self.scope:dispose()
  self.windows = {}
  self.tabs = {}
  self.views = 0
  self.hooks = nil
  self.resize_ticket = nil
  return self.disposal_report
end

return M
