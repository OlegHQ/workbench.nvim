local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")
local Location = require("workbench.core.location")
local RootPolicy = require("workbench.core.root_policy")

local M = {}
local Controller = {}
Controller.__index = Controller

local MAX_ROWS = 10000
local SEVERITIES = {
  [1] = { name = "error", short = "E" },
  [2] = { name = "warning", short = "W" },
  [3] = { name = "information", short = "I" },
  [4] = { name = "hint", short = "H" },
}

local function error_value(code, message)
  return { code = code, message = message }
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

local function adjust_counts(target, counts, multiplier)
  for _, key in ipairs({ "error", "warning", "information", "hint", "total" }) do
    target[key] = math.max(0, (target[key] or 0) + ((counts and counts[key]) or 0) * multiplier)
  end
end

local function counts_for(reports)
  local total = { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
  for _, entry in pairs(reports) do adjust_counts(total, entry.report.counts, 1) end
  return total
end

local function basename(path)
  return path:gsub("[\\/]+$", ""):match("([^\\/]+)$") or path
end

local function root_for(workspace, path)
  local best
  for _, root in ipairs(workspace.roots or {}) do
    if type(root.path) == "string" and RootPolicy.contains(root.path, path)
      and (not best or #root.path > #best.path) then best = root end
  end
  return best
end

local function tuple_key(values)
  local parts = {}
  for index, value in ipairs(values) do
    value = tostring(value)
    parts[index] = tostring(#value) .. ":" .. value
  end
  return table.concat(parts)
end

local function stable_diag_id(uri, diagnostic, occurrence)
  return "problems:diagnostic:" .. tuple_key({
    uri, diagnostic.namespace or 0, diagnostic.severity or 1, diagnostic.lnum, diagnostic.col,
    diagnostic.end_lnum, diagnostic.end_col, diagnostic.source or "", diagnostic.code or "", occurrence,
  })
end

local function source_of(diagnostic)
  local source = diagnostic.source
  if type(source) ~= "string" or source == "" then source = diagnostic.namespace_name or "Unknown source" end
  return Resource.escape_display(source)
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" or type(deps.layout.close) ~= "function" then
    return nil, error_value("invalid_dependency", "Problems controller requires the shared layout manager")
  end
  if type(deps.provider) ~= "table" or type(deps.provider.subscribe) ~= "function" then
    return nil, error_value("invalid_dependency", "Problems controller requires the native diagnostics provider")
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.open) ~= "function"
    or type(deps.navigation.return_to_origin) ~= "function" then
    return nil, error_value("invalid_dependency", "Problems controller requires shared navigation")
  end
  if deps.actions ~= nil and type(deps.actions.register) ~= "function" then
    return nil, error_value("invalid_dependency", "actions must be a shared action registry")
  end
  local next_id = M.next_controller_id + 1
  M.next_controller_id = next_id
  local self = setmetatable({
    id = next_id,
    layout = deps.layout,
    provider = deps.provider,
    navigation = deps.navigation,
    actions = deps.actions or require("workbench.core.actions").new(),
    owns_actions = deps.actions == nil,
    sessions = {},
    disposed = false,
    scope = Scope.new("workbench-problems-controller:" .. next_id),
  }, Controller)
  if deps.register_open_action ~= false then
    local registration, registration_err = self.actions:register({
      id = "problems.open",
      title = "Open reported Problems",
      category = "Workspace",
      scope = "workspace",
      available = function(context)
        if self.disposed then return { enabled = false, code = "controller_disposed", reason = "Problems is disabled" } end
        if type(context.workspace) ~= "table" then
          return { enabled = false, code = "no_workspace", reason = "no workbench workspace is active" }
        end
        if deps.view_available and not deps.view_available(context.workspace) then
          return { enabled = false, code = "view_disabled", reason = "Problems is not enabled in sidebar.views" }
        end
        return { enabled = true }
      end,
      run = function(context)
        if deps.open_view then return deps.open_view(context.workspace) end
        return self:open(context.workspace, { bufnr = context.bufnr, win = context.win })
      end,
    }, { scope = self.scope })
    if not registration then self:dispose(); return nil, registration_err end
  end
  return self
end

function Controller:_session_key(workspace, tab)
  return workspace.id .. "\0" .. tostring(tab)
end

function Controller:_session(workspace, tab, retain_replaced)
  local key = self:_session_key(workspace, tab)
  local existing = self.sessions[key]
  if existing then return existing end
  local replaced
  for old_key, candidate in pairs(self.sessions) do
    if candidate.tab == tab then
      replaced = candidate
      if not retain_replaced then
        self:_dispose_session(candidate)
        self.sessions[old_key] = nil
      end
      break
    end
  end
  local scope, err = self.scope:child("problems:" .. workspace.id .. ":" .. tostring(tab))
  if not scope then return nil, err end
  local session = {
    key = key,
    id = "problems:" .. tostring(self.id) .. ":" .. tostring(tab),
    scope = scope,
    workspace = workspace,
    tab = tab,
    reports = {},
    root_counts = {},
    filters = { severity = nil, source = nil, root_uri = nil },
    expanded = {},
    origin = nil,
    view = nil,
    lease_scope = nil,
    lease = nil,
    render_ticket = nil,
    selected_id = nil,
    disposed = false,
    last_error = nil,
  }
  for _, root in ipairs(workspace.roots) do session.root_counts[root.uri] = { error = 0, warning = 0, information = 0, hint = 0, total = 0 } end
  local _, defer_err = scope:defer(function() self:_dispose_session(session) end, "problems-session:" .. tostring(tab), "session")
  if defer_err then scope:dispose(); return nil, defer_err end
  self.sessions[key] = session
  return session, nil, replaced
end

function Controller:_dispose_session(session)
  if session.disposed then return false end
  session.disposed = true
  if session.render_ticket then session.render_ticket:cancel(); session.render_ticket = nil end
  if session.lease_scope then session.lease_scope:dispose(); session.lease_scope = nil end
  if session.view and not session.view.closed then self.layout:close("workbench-problems", session.tab) end
  session.view = nil
  self.sessions[session.key] = nil
  if session.scope.alive then session.scope:dispose() end
  return true
end

function Controller:_apply_change(session, event, render)
  local resource = event and event.resource
  if type(resource) ~= "table" or type(resource.uri) ~= "string" or type(resource.path) ~= "string" then return false end
  local uri = resource.uri
  local previous = session.reports[uri]
  if previous then
    local counts = session.root_counts[previous.root_uri]
    if counts then adjust_counts(counts, previous.report.counts, -1) end
    session.reports[uri] = nil
  end
  local root = root_for(session.workspace, resource.path)
  local report = event.report
  if root and type(report) == "table" and type(report.counts) == "table" and report.counts.total > 0 then
    session.reports[uri] = { report = report, root_uri = root.uri }
    local counts = session.root_counts[root.uri]
    if counts then adjust_counts(counts, report.counts, 1) end
  end
  if render then self:_schedule_render(session) end
  return true
end

function Controller:_bind(session)
  if session.lease_scope then session.lease_scope:dispose(); session.lease_scope = nil end
  session.lease = nil
  session.reports = {}
  for _, root in ipairs(session.workspace.roots) do
    session.root_counts[root.uri] = { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
  end
  local lease_scope, scope_err = session.scope:child("problems-reports:" .. tostring(session.tab))
  if not lease_scope then return nil, scope_err end
  session.lease_scope = lease_scope
  local lease, lease_err = self.provider:subscribe(session.workspace, function(event)
    if session.disposed or not lease_scope.alive or session.lease_scope ~= lease_scope then return end
    self:_apply_change(session, event, true)
  end)
  if not lease then
    lease_scope:dispose()
    session.lease_scope = nil
    return nil, lease_err
  end
  session.lease = lease
  local _, defer_err = lease_scope:defer(function() lease:release() end, "problems-diagnostic-lease", "subscription")
  if defer_err then lease_scope:dispose(); session.lease_scope = nil; session.lease = nil; return nil, defer_err end
  local snapshot, snapshot_err = lease:snapshot()
  if not snapshot then lease_scope:dispose(); session.lease_scope = nil; session.lease = nil; return nil, snapshot_err end
  session.coverage = snapshot.coverage
  for _, report in ipairs(snapshot.reports) do
    self:_apply_change(session, { resource = report.resource, report = report }, false)
  end
  return true
end

function Controller:_source_options(session)
  local sources, seen = {}, {}
  for _, entry in pairs(session.reports) do
    for _, namespace in ipairs(entry.report.namespaces) do
      for _, diagnostic in ipairs(namespace.diagnostics) do
        local source = diagnostic.source or diagnostic.namespace_name or "Unknown source"
        if not seen[source] then seen[source] = true; sources[#sources + 1] = source end
      end
    end
  end
  table.sort(sources)
  return sources
end

function Controller:_filtered_diagnostics(session)
  local result = {}
  for uri, entry in pairs(session.reports) do
    if not session.filters.root_uri or entry.root_uri == session.filters.root_uri then
      for _, namespace in ipairs(entry.report.namespaces) do
        for _, diagnostic in ipairs(namespace.diagnostics) do
          local severity_ok = not session.filters.severity or diagnostic.severity == session.filters.severity
          local source = diagnostic.source or diagnostic.namespace_name or "Unknown source"
          local source_ok = not session.filters.source or source == session.filters.source
          if severity_ok and source_ok then result[#result + 1] = { uri = uri, report = entry.report, root_uri = entry.root_uri, diagnostic = diagnostic } end
        end
      end
    end
  end
  table.sort(result, function(left, right)
    local a, b = left.diagnostic, right.diagnostic
    if left.root_uri ~= right.root_uri then return left.root_uri < right.root_uri end
    if left.report.resource.display_path ~= right.report.resource.display_path then
      return left.report.resource.display_path < right.report.resource.display_path
    end
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    if a.col ~= b.col then return a.col < b.col end
    if (a.source or "") ~= (b.source or "") then return (a.source or "") < (b.source or "") end
    if a.message ~= b.message then return a.message < b.message end
    return (a.namespace or 0) < (b.namespace or 0)
  end)
  return result
end

function Controller:_items(session)
  local diagnostics = self:_filtered_diagnostics(session)
  local items = {
    {
      id = "problems:coverage:" .. session.key,
      kind = "status",
      label = "Reported diagnostics only · workspace completeness unknown",
      selectable = false,
    },
  }
  if #diagnostics == 0 then
    local filtered = session.filters.severity or session.filters.source or session.filters.root_uri
    items[#items + 1] = {
      id = "problems:empty:" .. session.key,
      kind = "status",
      label = filtered and "No reported diagnostics match these filters"
        or "No diagnostics reported · this does not prove every file is clean",
      selectable = false,
    }
    return items
  end

  local visible = math.min(#diagnostics, MAX_ROWS)
  local roots_by_uri, roots_added, files_added, occurrences = {}, {}, {}, {}
  local root_filter_counts, file_filter_counts = {}, {}
  for _, root in ipairs(session.workspace.roots) do roots_by_uri[root.uri] = root end
  for _, entry in ipairs(diagnostics) do
    local severity = SEVERITIES[entry.diagnostic.severity]
    if severity then
      local root_counts = root_filter_counts[entry.root_uri] or { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
      root_counts[severity.name] = root_counts[severity.name] + 1
      root_counts.total = root_counts.total + 1
      root_filter_counts[entry.root_uri] = root_counts
      local file_counts = file_filter_counts[entry.uri] or { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
      file_counts[severity.name] = file_counts[severity.name] + 1
      file_counts.total = file_counts.total + 1
      file_filter_counts[entry.uri] = file_counts
    end
  end
  for index = 1, visible do
    local entry = diagnostics[index]
    local root = entry.root_uri
    local root_record = roots_by_uri[root]
    if root_record then
      local root_id = "problems:root:" .. root
      if not roots_added[root] then
        roots_added[root] = true
        local root_counts = session.root_counts[root] or {}
        local filter_counts = root_filter_counts[root] or counts_for({})
        items[#items + 1] = {
          id = root_id,
          kind = "directory",
          label = "Root: " .. Resource.escape_display(basename(root_record.path)),
          detail = string.format("%d reported", filter_counts.total),
          expandable = true,
          payload = { root_uri = root, counts = copy_counts(root_counts) },
        }
      end
      local file_id = "problems:file:" .. entry.uri
      if not files_added[entry.uri] then
        files_added[entry.uri] = true
        local relative = vim.fs.relpath(root_record.path, entry.report.resource.path) or entry.report.resource.display_path
        items[#items + 1] = {
          id = file_id,
          kind = "file",
          label = Resource.escape_display(relative),
          parent_id = root_id,
          detail = string.format("%d reported", (file_filter_counts[entry.uri] or {}).total or 0),
          expandable = true,
          payload = { uri = entry.uri, resource = Resource.copy(entry.report.resource) },
        }
      end
      local diagnostic = entry.diagnostic
      local severity = SEVERITIES[diagnostic.severity] or SEVERITIES[1]
      local occurrence_key = tuple_key({ entry.uri, diagnostic.namespace or 0, diagnostic.severity, diagnostic.lnum,
        diagnostic.col, diagnostic.source or "", diagnostic.code or "" })
      occurrences[occurrence_key] = (occurrences[occurrence_key] or 0) + 1
      local id = stable_diag_id(entry.uri, diagnostic, occurrences[occurrence_key])
      local resource = Resource.copy(entry.report.resource)
      local finish_line = math.max(diagnostic.lnum, diagnostic.end_lnum or diagnostic.lnum)
      local finish_col = diagnostic.end_col or diagnostic.col
      if finish_line == diagnostic.lnum then finish_col = math.max(diagnostic.col, finish_col) end
      local location = Location.new(resource, {
        range = {
          start = { line = diagnostic.lnum, character = diagnostic.col },
          finish = { line = finish_line, character = finish_col },
        },
        encoding = "utf-8",
      })
      if location then
        local source = source_of(diagnostic)
        local label = string.format("%s %d:%d %s", severity.short, diagnostic.lnum + 1, diagnostic.col + 1, diagnostic.message)
        items[#items + 1] = {
          id = id,
          kind = "diagnostic",
          label = label,
          detail = source .. " · " .. Resource.escape_display(diagnostic.namespace_name or "namespace " .. tostring(diagnostic.namespace or 0)),
          parent_id = file_id,
          location = location,
          payload = { severity = severity.name, source = source, namespace = diagnostic.namespace, code = diagnostic.code },
        }
      end
    end
  end
  if #diagnostics > visible then
    items[#items + 1] = { id = "problems:limit:" .. session.key, kind = "status",
      label = string.format("Showing first %d of %d diagnostics", visible, #diagnostics), selectable = false }
  end
  return items
end

function Controller:_model(session)
  local filters = session.filters
  local filter_labels = {}
  if filters.severity then filter_labels[#filter_labels + 1] = "severity " .. (SEVERITIES[filters.severity] and SEVERITIES[filters.severity].name or "?") end
  if filters.source then filter_labels[#filter_labels + 1] = "source " .. Resource.escape_display(filters.source) end
  if filters.root_uri then filter_labels[#filter_labels + 1] = "root " .. Resource.escape_display(basename((function()
    for _, root in ipairs(session.workspace.roots) do if root.uri == filters.root_uri then return root.path end end
    return filters.root_uri
  end)())) end
  local header = { "Reported only · unopened/unreported files are unknown" }
  if #filter_labels > 0 then header[#header + 1] = "Filters: " .. table.concat(filter_labels, " · ") end
  local items = self:_items(session)
  session.item_by_id = {}
  for _, item in ipairs(items) do session.item_by_id[item.id] = item end
  return {
    status = "ready",
    title = "Reported Problems",
    header = header,
    items = items,
  }
end

function Controller:_render(session)
  if not session.view or session.view.closed then return false end
  return session.view:update(self:_model(session))
end

function Controller:_schedule_render(session)
  if session.render_ticket or not session.view or session.view.closed then return false end
  local view = session.view
  local ticket = session.scope:schedule(function()
    session.render_ticket = nil
    if session.view == view and view.scope.alive then self:_render(session) end
  end)
  if not ticket then return false end
  session.render_ticket = ticket
  return true
end

function Controller:_severity(value)
  if value == nil or value == "all" or value == 0 then return nil end
  if type(value) == "string" then
    local name = value:lower()
    for number, severity in pairs(SEVERITIES) do if severity.name == name then return number end end
    return nil
  end
  return SEVERITIES[value] and value or nil
end

function Controller:set_filter(session, name, value)
  if type(session) ~= "table" or session.disposed or self.sessions[session.key] ~= session then
    return nil, error_value("session_unavailable", "Problems session is no longer active")
  end
  if name == "severity" then
    if value ~= nil and value ~= "all" and value ~= 0 and not self:_severity(value) then
      return nil, error_value("invalid_filter", "severity must be error, warning, information, hint, or all")
    end
    session.filters.severity = self:_severity(value)
  elseif name == "source" then
    if value ~= nil and (type(value) ~= "string" or #value > 128) then
      return nil, error_value("invalid_filter", "source must be a string of at most 128 bytes")
    end
    session.filters.source = value ~= "" and value or nil
  elseif name == "root" then
    if value ~= nil then
      local found = false
      for _, root in ipairs(session.workspace.roots) do if root.uri == value then found = true; break end end
      if not found then return nil, error_value("invalid_filter", "root filter must match a workspace root URI") end
    end
    session.filters.root_uri = value
  elseif name == "clear" then
    session.filters = { severity = nil, source = nil, root_uri = nil }
  else
    return nil, error_value("invalid_filter", "filter must be severity, source, root, or clear")
  end
  return self:_render(session)
end

function Controller:_cycle_root(session)
  local roots = session.workspace.roots
  if #roots == 0 then return false end
  local current_index = 0
  for index, root in ipairs(roots) do if root.uri == session.filters.root_uri then current_index = index; break end end
  if current_index >= #roots then return self:set_filter(session, "root", nil) end
  return self:set_filter(session, "root", roots[current_index + 1].uri)
end

function Controller:_keymaps(session)
  local controller = self
  local mappings = {
    ["1"] = { desc = "Workbench Problems: errors", run = function() controller:set_filter(session, "severity", "error") end },
    ["2"] = { desc = "Workbench Problems: warnings", run = function() controller:set_filter(session, "severity", "warning") end },
    ["3"] = { desc = "Workbench Problems: information", run = function() controller:set_filter(session, "severity", "information") end },
    ["4"] = { desc = "Workbench Problems: hints", run = function() controller:set_filter(session, "severity", "hint") end },
    ["0"] = { desc = "Workbench Problems: all severities", run = function() controller:set_filter(session, "severity", "all") end },
    ["r"] = { desc = "Workbench Problems: cycle workspace root filter", run = function() controller:_cycle_root(session) end },
    ["f"] = { desc = "Workbench Problems: filter by source", run = function()
      vim.ui.input({ prompt = "Diagnostic source (blank clears): ", default = session.filters.source or "" }, function(value)
        if value ~= nil and not session.disposed then controller:set_filter(session, "source", value) end
      end)
    end },
    ["C"] = { desc = "Workbench Problems: clear all filters", run = function() controller:set_filter(session, "clear") end },
    ["R"] = { desc = "Workbench Problems: return to origin", run = function() controller:return_to_origin(session) end },
  }
  return mappings
end

function Controller:_capture_origin(opts, tab)
  local bufnr, win = opts.bufnr, opts.win
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
    or vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = nil
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buffer = vim.api.nvim_win_get_buf(candidate)
      if vim.api.nvim_win_get_config(candidate).relative == "" and vim.bo[buffer].buftype == ""
        and not vim.b[buffer].workbench_preview then
        win, bufnr = candidate, buffer
        break
      end
    end
  end
  if not win or not bufnr then
    return nil, error_value("no_editor_buffer", "Problems requires a real editor buffer for safe navigation")
  end
  return {
    win = win,
    buf = bufnr,
    cursor = vim.api.nvim_win_get_cursor(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    tab = tab,
  }
end

function Controller:_activate(session, id)
  local row
  for _, candidate in ipairs(session.view and session.view.rows or {}) do if candidate.id == id then row = candidate; break end end
  local item = session.item_by_id and session.item_by_id[id]
  if not row or row.kind ~= "diagnostic" or not item or not item.location then return nil end
  return self.navigation:open(item.location, "current", session.origin, session.id)
end

function Controller:open(workspace, opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, error_value("controller_disposed", "Problems controller is disposed") end
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or type(workspace.roots) ~= "table" or #workspace.roots == 0 then
    return nil, error_value("workspace_unavailable", "Problems requires a workspace snapshot with file roots")
  end
  for _, root in ipairs(workspace.roots) do
    if type(root) ~= "table" or type(root.uri) ~= "string" or type(root.path) ~= "string" then
      return nil, error_value("workspace_unavailable", "Problems roots require file URIs and native paths")
    end
  end
  local tab = opts.tabpage or vim.api.nvim_get_current_tabpage()
  local retain_replaced = self.layout:get("workbench-problems", tab) ~= nil
  local session, session_err, replaced = self:_session(workspace, tab, retain_replaced)
  if not session then return nil, session_err end
  if session.workspace.generation ~= workspace.generation then
    session.workspace = workspace
    local rebound, rebind_err = self:_bind(session)
    if not rebound then session.last_error = rebind_err; return nil, rebind_err end
    if session.view then self:_render(session) end
  end
  if session.view and not session.view.closed then
    if opts.focus ~= false and vim.api.nvim_win_is_valid(session.view.window) then vim.api.nvim_set_current_win(session.view.window) end
    return session.view, session
  end
  local origin, origin_err = self:_capture_origin(opts, tab)
  if not origin then self:_dispose_session(session); return nil, origin_err end
  session.origin = origin
  local bound, bind_err = self:_bind(session)
  if not bound then
    session.last_error = bind_err
    self:_dispose_session(session)
    return nil, bind_err
  end
  local model = self:_model(session)
  session.expanded = session.expanded or {}
  for _, item in ipairs(model.items) do
    if item.kind == "directory" and session.expanded[item.id] == nil then session.expanded[item.id] = true end
    if item.kind == "file" and session.expanded[item.id] == nil then session.expanded[item.id] = false end
  end
  local view
  local view_err
  view, view_err = self.layout:mount({
    id = "workbench-problems",
    replace = replaced ~= nil,
    title = "Reported Problems",
    kind = "tree",
    placement = "sidebar",
    focus = opts.focus ~= false,
    selected_id = session.selected_id,
    scroll_offset = session.scroll_offset,
    expanded = session.expanded,
    model = model,
    help_lines = {
      "1/2/3/4 filter severity · 0 all severities",
      "f filter source · r cycle root · C clear filters",
      "Enter opens a diagnostic · R returns to origin",
      "Only reported diagnostics are shown; coverage may be incomplete",
      "q closes Problems and releases its diagnostic lease",
    },
    keymaps = self:_keymaps(session),
    on_select = function(id, _, committed)
      session.selected_id = id
      if committed then return self:_activate(session, id) end
    end,
    on_dispose = function()
      if session.view and session.view.buffer == view.buffer then
        session.selected_id = session.view.selected_id or session.selected_id
        session.scroll_offset = session.view.scroll_offset
        session.expanded = vim.deepcopy(session.view.expanded)
        session.view = nil
        if session.render_ticket then session.render_ticket:cancel(); session.render_ticket = nil end
        if session.lease_scope then session.lease_scope:dispose(); session.lease_scope = nil end
        session.lease = nil
        self:_schedule_closed_tab_cleanup(session)
      end
    end,
  })
  if not view then
    if session.lease_scope then session.lease_scope:dispose(); session.lease_scope = nil; session.lease = nil end
    return nil, view_err
  end
  session.view = view
  view.expanded = vim.deepcopy(session.expanded)
  self:_render(session)
  if replaced and not replaced.disposed then self:_dispose_session(replaced) end
  return view, session
end

function Controller:_schedule_closed_tab_cleanup(session)
  if session.disposed or not self.scope.alive then return end
  self.scope:schedule(function()
    if session.disposed or session.view or vim.api.nvim_tabpage_is_valid(session.tab) then return end
    self:_dispose_session(session)
  end)
end

function Controller:open_selected(session, id)
  if type(session) ~= "table" or session.disposed then return nil, error_value("session_unavailable", "Problems session is no longer active") end
  id = id or (session.view and session.view.selected_id)
  return self:_activate(session, id)
end

function Controller:return_to_origin(session)
  if type(session) ~= "table" or session.disposed then return nil, error_value("session_unavailable", "Problems session is no longer active") end
  return self.navigation:return_to_origin(session.id)
end

function Controller:status()
  local sessions = {}
  for _, session in pairs(self.sessions) do
    if not session.disposed then
      sessions[#sessions + 1] = {
        key = session.key,
        tab = session.tab,
        workspace_id = session.workspace.id,
        coverage = session.coverage or "reported-only",
        diagnostics = counts_for(session.reports),
        mounted = session.view ~= nil and not session.view.closed,
        filter = { severity = session.filters.severity, source = session.filters.source, root_uri = session.filters.root_uri },
        lease_active = session.lease ~= nil and session.lease.active,
      }
    end
  end
  table.sort(sessions, function(left, right) return left.key < right.key end)
  return { disposed = self.disposed, sessions = sessions, session_count = #sessions, provider = self.provider:status() }
end

function Controller:dispose()
  if self.disposed then return false end
  self.disposed = true
  local sessions = {}
  for _, session in pairs(self.sessions) do sessions[#sessions + 1] = session end
  for _, session in ipairs(sessions) do
    if session.view and not session.view.closed then self.layout:close("workbench-problems", session.tab) end
    self:_dispose_session(session)
  end
  self.sessions = {}
  self.scope:dispose()
  if self.owns_actions then self.actions = nil end
  return true
end

M.next_controller_id = 0
return M
