local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")

local M = {}
local Controller = {}
Controller.__index = Controller

local function error_value(code, message)
  return { code = code, message = message }
end

local function basename(path)
  return (path:gsub("[\\/]+$", ""):match("([^\\/]+)$") or path)
end

local function aggregate_text(aggregate)
  aggregate = aggregate or {}
  local parts = { string.format("%d changed", aggregate.total or 0) }
  for _, field in ipairs({
    { "staged", "staged" }, { "unstaged", "unstaged" }, { "untracked", "untracked" },
    { "conflicts", "conflicts" }, { "renames", "renames" }, { "submodules", "submodules" },
  }) do
    local count = aggregate[field[1]] or 0
    if count > 0 then parts[#parts + 1] = count .. " " .. field[2] end
  end
  return table.concat(parts, " · ")
end

local function status_model(session, status, error_info)
  local snapshot = session.snapshot
  if status == "unavailable" then
    return { status = "unavailable", title = "Git", reason = error_info and error_info.message or "Git is unavailable", items = {} }
  elseif status == "error" then
    return { status = "error", title = "Git", error = error_info, items = {} }
  elseif status == "running" or not snapshot then
    return {
      status = "running",
      title = "Git",
      header = { Resource.escape_display(session.workspace.roots[1].path) },
      items = {},
    }
  elseif snapshot.status == "not_repository" then
    return {
      status = "unavailable",
      title = "Git",
      reason = "workspace root is not inside a Git worktree",
      header = { Resource.escape_display(session.workspace.roots[1].path) },
      items = {},
    }
  end
  local repository = snapshot.repository
  local descriptor = repository.is_submodule and "submodule"
    or (repository.is_worktree and "linked worktree" or "repository")
  local items = {}
  for _, record in ipairs(snapshot.files) do
    items[#items + 1] = {
      id = record.id,
      kind = "git_status",
      label = record.display_path,
      detail = record.detail,
      badges = {
        staged = record.staged and "S" or nil,
        unstaged = record.unstaged and "U" or nil,
        untracked = record.untracked and "?" or nil,
        conflict = record.conflict and "!" or nil,
      },
      payload = { record = record },
    }
  end
  if #items == 0 then
    items[1] = { id = "git:clean", kind = "notice", label = "Working tree clean", selectable = false }
  end
  local title = "Git · " .. Resource.escape_display(basename(repository.root))
  return {
    status = "ready",
    title = title,
    header = {
      descriptor .. " · " .. Resource.escape_display(repository.root),
      aggregate_text(snapshot.aggregate),
    },
    items = items,
  }
end

local function diff_model(record, event)
  local path = Resource.escape_display(record.path)
  if event.kind == "status" then
    return { status = "running", title = "Git diff", header = { path, "Reading selected file only…" }, items = {} }
  elseif event.kind == "error" then
    return { status = "error", title = "Git diff · " .. path, error = event.error, items = {} }
  end
  local items = {}
  local index = 0
  for line in (event.text .. (event.text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
    index = index + 1
    items[index] = {
      id = "git-diff:" .. index,
      kind = "diff_line",
      label = Resource.escape_display(line),
    }
  end
  if #items == 0 then
    items[1] = { id = "git-diff:empty", kind = "notice", label = "No diff for this path", selectable = false }
  end
  return {
    status = "ready",
    title = "Git diff · " .. path,
    header = {
      string.format("%s · %d lines · %d bytes",
        event.truncated and "Bounded preview · truncated" or "Bounded read-only preview",
        event.lines or #items, event.bytes or 0),
    },
    items = items,
  }
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" or type(deps.layout.close) ~= "function" then
    return nil, error_value("invalid_dependency", "Git controller requires the shared layout manager")
  end
  if type(deps.provider) ~= "table" or type(deps.provider.refresh) ~= "function"
    or type(deps.provider.diff) ~= "function" or type(deps.provider.capabilities) ~= "function" then
    return nil, error_value("invalid_dependency", "Git controller requires the read-only Git provider")
  end
  if deps.actions ~= nil and type(deps.actions.register) ~= "function" then
    return nil, error_value("invalid_dependency", "actions must be a shared action registry")
  end
  local self = setmetatable({
    layout = deps.layout,
    provider = deps.provider,
    actions = deps.actions or require("workbench.core.actions").new(),
    sessions = {},
    disposed = false,
    scope = Scope.new("workbench-git-controller"),
  }, Controller)
  local controller = self
  local registration, register_error = self.actions:register({
    id = "git.open",
    title = "Open Git status",
    category = "Workspace",
    scope = "workspace",
    available = function(context)
      if controller.disposed then return { enabled = false, code = "controller_disposed", reason = "Git is disabled" } end
      if type(context.workspace) ~= "table" then
        return { enabled = false, code = "no_workspace", reason = "no workbench workspace is active" }
      end
      local capability = controller.provider:capabilities({ workspace = context.workspace })
      if capability.state ~= "ready" then
        return { enabled = false, code = "missing_dependency", reason = capability.reason or "Git is unavailable" }
      end
      return { enabled = true }
    end,
    run = function(context)
      return controller:open(context.workspace, { tab = context.tab, win = context.win })
    end,
  }, { scope = self.scope })
  if not registration then self:dispose(); return nil, register_error end
  return self
end

function Controller:_dispose_session(session)
  if session.disposed then return false end
  session.disposed = true
  if session.request then session.request:cancel(); session.request = nil end
  if session.request_scope then session.request_scope:dispose(); session.request_scope = nil end
  if session.diff_request then session.diff_request:cancel(); session.diff_request = nil end
  if session.diff_view_scope then session.diff_view_scope:dispose(); session.diff_view_scope = nil end
  if session.diff_request_scope then session.diff_request_scope:dispose(); session.diff_request_scope = nil end
  if session.diff_view and not session.diff_view.closed then
    self.layout:close("workbench-git-diff", session.tab)
  end
  session.diff_view = nil
  if session.view and not session.view.closed then
    session.selected_id = session.view.selected_id
    session.view = nil
  end
  if self.sessions[session.tab] == session then self.sessions[session.tab] = nil end
  return true
end

function Controller:_request_status(session, force)
  if session.disposed then return nil, error_value("session_disposed", "Git view session is closed") end
  local capability = self.provider:capabilities({ workspace = session.workspace })
  if capability.state ~= "ready" then
    local unavailable = error_value("missing_dependency", capability.reason or "Git is unavailable")
    session.error = unavailable
    if session.view then session.view:update(status_model(session, "unavailable", unavailable)) end
    return nil, unavailable
  end
  session.generation = session.generation + 1
  local generation = session.generation
  if session.request then session.request:cancel(); session.request = nil end
  if session.request_scope then session.request_scope:dispose(); session.request_scope = nil end
  local request_scope, scope_error = session.scope:child("git-status:" .. generation)
  if not request_scope then return nil, scope_error end
  session.request_scope = request_scope
  session.error = nil
  if session.view then session.view:update(status_model(session, "running")) end
  local handle, request_error = self.provider:refresh(session.workspace, {
    force = force == true,
    generation = generation,
  }, function(event)
    if session.disposed or not request_scope.alive or session.generation ~= generation then return end
    if event.kind == "status" then
      if session.view then session.view:update(status_model(session, "running")) end
      return
    end
    session.request = nil
    request_scope:dispose()
    session.request_scope = nil
    if event.kind == "done" and event.snapshot then
      session.snapshot = event.snapshot
      session.error = nil
      if session.view then session.view:update(status_model(session)) end
    elseif event.kind == "done" and event.status == "not_repository" then
      session.snapshot = { status = "not_repository" }
      session.error = event.error
      if session.view then session.view:update(status_model(session)) end
    else
      session.error = event.error or error_value("git_failed", "Git status failed")
      if session.view then session.view:update(status_model(session, "error", session.error)) end
    end
  end)
  if not handle then
    session.error = request_error
    if session.view then session.view:update(status_model(session, "error", request_error)) end
    request_scope:dispose()
    session.request_scope = nil
    return nil, request_error
  end
  session.request = handle
  return handle
end

function Controller:_close_diff(session)
  if session.diff_request then session.diff_request:cancel(); session.diff_request = nil end
  if session.diff_request_scope then session.diff_request_scope:dispose(); session.diff_request_scope = nil end
  if session.diff_view and not session.diff_view.closed then
    self.layout:close("workbench-git-diff", session.tab)
  end
  session.diff_view = nil
  if session.diff_view_scope then session.diff_view_scope:dispose(); session.diff_view_scope = nil end
end

function Controller:_show_diff(session, record, model)
  if session.disposed then return nil end
  if session.diff_view and not session.diff_view.closed then
    session.diff_view:update(model)
    return session.diff_view
  end
  local scope, scope_error = session.scope:child("git-diff-view")
  if not scope then return nil, scope_error end
  session.diff_view_scope = scope
  local view
  local view_error
  view, view_error = self.layout:mount({
    id = "workbench-git-diff",
    title = "Git diff",
    kind = "list",
    placement = "results",
    model = model,
    focus = true,
    help_lines = { "Read-only selected-file diff · q: close preview" },
    on_dispose = function()
      if session.diff_view == view then session.diff_view = nil end
      if session.diff_view_scope == scope then session.diff_view_scope = nil end
      if scope.alive then scope:dispose() end
      session.scope:schedule(function()
        if session.disposed or not session.view or session.view.closed or not session.view.window then return end
        if vim.api.nvim_win_is_valid(session.view.window) then pcall(vim.api.nvim_set_current_win, session.view.window) end
      end)
    end,
  })
  if not view then scope:dispose(); session.diff_view_scope = nil; return nil, view_error end
  session.diff_view = view
  return view
end

function Controller:_preview(session)
  if session.disposed or not session.snapshot or not session.view then return nil end
  local selected_id = session.view.selected_id
  local record
  for _, candidate in ipairs(session.snapshot.files or {}) do
    if candidate.id == selected_id then record = candidate; break end
  end
  if not record then return nil, error_value("no_selection", "select a changed file before previewing its diff") end
  self:_close_diff(session)
  session.diff_generation = session.diff_generation + 1
  local generation = session.diff_generation
  local loading = diff_model(record, { kind = "status" })
  local view, view_error = self:_show_diff(session, record, loading)
  if not view then return nil, view_error end
  local scope, scope_error = session.scope:child("git-diff-request:" .. generation)
  if not scope then return nil, scope_error end
  session.diff_request_scope = scope
  local request_scope = scope
  local handle, request_error = self.provider:diff(session.snapshot, record, { generation = generation }, function(event)
    if session.disposed or not request_scope.alive or session.diff_generation ~= generation then return end
    if event.kind == "status" then
      if session.diff_view then session.diff_view:update(diff_model(record, event)) end
      return
    end
    session.diff_request = nil
    request_scope:dispose()
    if session.diff_request_scope == request_scope then session.diff_request_scope = nil end
    if session.diff_view then session.diff_view:update(diff_model(record, event)) end
  end)
  if not handle then
    request_scope:dispose()
    if session.diff_request_scope == request_scope then session.diff_request_scope = nil end
    if session.diff_view then session.diff_view:update(diff_model(record, { kind = "error", error = request_error })) end
    return nil, request_error
  end
  session.diff_request = handle
  return view
end

function Controller:open(workspace, opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, error_value("controller_disposed", "Git controller is disposed") end
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or type(workspace.generation) ~= "number"
    or type(workspace.roots) ~= "table" or #workspace.roots ~= 1 then
    return nil, error_value("invalid_workspace", "Git requires a single-root workspace snapshot")
  end
  local tab = opts.tab or vim.api.nvim_get_current_tabpage()
  local existing = self.sessions[tab]
  if existing and existing.workspace.id == workspace.id and existing.workspace.generation == workspace.generation
    and existing.view and not existing.view.closed then
    if opts.refresh then self:_request_status(existing, true) end
    return existing.view, existing
  end
  if existing then
    if existing.view and not existing.view.closed then self.layout:close("workbench-git", tab) end
    self:_dispose_session(existing)
  end
  local origin_win = opts.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(origin_win) or vim.api.nvim_win_get_tabpage(origin_win) ~= tab
    or vim.bo[vim.api.nvim_win_get_buf(origin_win)].buftype ~= "" then
    return nil, error_value("no_editor_window", "an editor window is required to open Git status")
  end
  local scope, scope_error = self.scope:child("git:" .. workspace.id .. ":" .. tostring(tab))
  if not scope then return nil, scope_error end
  local session = {
    scope = scope,
    tab = tab,
    workspace = vim.deepcopy(workspace),
    snapshot = nil,
    generation = 0,
    diff_generation = 0,
    selected_id = nil,
    disposed = false,
  }
  self.sessions[tab] = session
  scope:defer(function() self:_dispose_session(session) end, "git-session:" .. tostring(tab), "session")
  local controller = self
  local view, view_error = self.layout:mount({
    id = "workbench-git",
    title = "Git",
    kind = "list",
    placement = "sidebar",
    focus = opts.focus ~= false,
    model = status_model(session, "running"),
    selected_id = session.selected_id,
    help_lines = { "j/k: move without Git work · d/Enter: preview selected diff · r: refresh · q: close" },
    keymaps = {
      d = { desc = "Preview selected Git diff", run = function() return controller:_preview(session) end },
      r = { desc = "Refresh Git status", run = function() return controller:_request_status(session, true) end },
      ["<CR>"] = { desc = "Preview selected Git diff", run = function() return controller:_preview(session) end },
    },
    on_dispose = function()
      if session.view then session.selected_id = session.view.selected_id end
      if scope.alive then scope:dispose() end
    end,
  })
  if not view then scope:dispose(); return nil, view_error end
  session.view = view
  local capability = self.provider:capabilities({ workspace = session.workspace })
  if capability.state ~= "ready" then
    session.error = error_value("missing_dependency", capability.reason or "Git is unavailable")
    view:update(status_model(session, "unavailable", session.error))
    return view, session
  end
  local _, selection_error = scope:defer(function() session.selected_id = view.selected_id end, "git-selection:" .. tostring(tab), "state")
  if selection_error then self.layout:close("workbench-git", tab); return nil, selection_error end
  local request, request_error = self:_request_status(session, false)
  if not request then session.error = request_error end
  return view, session
end

function Controller:status()
  local sessions = {}
  for tab, session in pairs(self.sessions) do
    sessions[#sessions + 1] = {
      tab = tab,
      workspace_id = session.workspace.id,
      state = session.disposed and "disposed" or (session.snapshot and session.snapshot.status or "loading"),
      files = session.snapshot and #(session.snapshot.files or {}) or 0,
      selected_id = session.view and session.view.selected_id or session.selected_id,
      diff_open = session.diff_view ~= nil and not session.diff_view.closed,
    }
  end
  table.sort(sessions, function(left, right) return left.tab < right.tab end)
  return { disposed = self.disposed, session_count = #sessions, sessions = sessions, resources = self.scope:inventory() }
end

function Controller:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  self.disposal_report = self.scope:dispose()
  return self.disposal_report
end

return M
