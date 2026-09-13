local Scope = require("workbench.core.scope")
local resource = require("workbench.core.resource")
local root_policy = require("workbench.core.root_policy")

local M = {}
local Controller = {}
Controller.__index = Controller

local function copy_map(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function reveal_relative(session, path)
  local normalized = resource.normalize_absolute_path(path)
  if not normalized then return nil end
  local relative = vim.fs.relpath(session.root_path, normalized)
  if relative and relative ~= ".." and relative:sub(1, 3) ~= "../" then return relative end
  local canonical = (vim.uv or vim.loop).fs_realpath(normalized)
  if not canonical then return nil end
  relative = vim.fs.relpath(session.root_path, canonical)
  if relative and relative ~= ".." and relative:sub(1, 3) ~= "../" then return relative end
end

local DIAGNOSTIC_SEVERITIES = { "error", "warning", "information", "hint" }

local function apply_counts(target, counts, multiplier)
  for _, name in ipairs(DIAGNOSTIC_SEVERITIES) do
    target[name] = math.max(0, (target[name] or 0) + ((counts and counts[name]) or 0) * multiplier)
  end
  target.total = math.max(0, (target.total or 0) + ((counts and counts.total) or 0) * multiplier)
end

local function new_counts()
  return { error = 0, warning = 0, information = 0, hint = 0, total = 0 }
end

local function diagnostic_badge(counts)
  if not counts or counts.total == 0 then return nil end
  local parts = {}
  for _, pair in ipairs({ { "error", "E" }, { "warning", "W" }, { "information", "I" }, { "hint", "H" } }) do
    if counts[pair[1]] > 0 then parts[#parts + 1] = pair[2] .. counts[pair[1]] end
  end
  return table.concat(parts, " ")
end

local function root_item(snapshot)
  local root = snapshot.roots[1]
  local label = root.display_path or root.path
  label = label:gsub("[\\/]+$", "")
  label = label:match("([^\\/]+)$") or label
  return {
    id = "file:" .. root.uri,
    kind = "directory",
    label = resource.escape_display(label),
    expandable = true,
    payload = { resource = root, lexical_path = root.path, raw_name = label, ancestors = { root.path } },
  }
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then
    return nil, "Files controller requires a native layout manager"
  end
  if type(deps.provider) ~= "table" or type(deps.provider.enumerate) ~= "function" then
    return nil, "Files controller requires a filesystem provider"
  end
  local operations, operations_error = deps.operations, nil
  local owns_operations = operations == nil
  if owns_operations then
    local module = require("workbench.services.operations")
    operations, operations_error = module.new({ lsp = deps.lsp, trash = deps.trash })
  end
  return setmetatable({
    layout = deps.layout,
    provider = deps.provider,
    diagnostics = deps.diagnostics,
    update_policy = deps.update_policy,
    on_open = deps.on_open,
    on_search = deps.on_search,
    get_follow_active_file = deps.get_follow_active_file,
    operations = operations,
    operations_error = operations_error,
    owns_operations = owns_operations,
    input = deps.input or vim.ui.input,
    select = deps.select or vim.ui.select,
    notify = deps.notify or vim.notify,
    scope = Scope.new("workbench-files-controller"),
    sessions = {},
    disposed = false,
  }, Controller)
end

function Controller:_session_key(snapshot, tab)
  return snapshot.id .. "\0" .. tostring(tab)
end

function Controller:_new_session(snapshot, tab, old)
  local scope, err = self.scope:child("files:" .. snapshot.id .. ":" .. tostring(tab))
  if not scope then return nil, err end
  local root = root_item(snapshot)
  local session = {
    key = self:_session_key(snapshot, tab),
    scope = scope,
    tab = tab,
    workspace = snapshot,
    root_path = snapshot.roots[1].path,
    root_id = root.id,
    nodes = { [root.id] = root },
    children = { [root.id] = {} },
    loaded = {},
    loading = {},
    requests = {},
    save_buffers = {},
    expanded = old and copy_map(old.expanded) or { [root.id] = true },
    selected_id = old and old.selected_id or root.id,
    filter = old and old.filter or "",
    filter_expanded = nil,
    view = nil,
    origin_window = nil,
    last_error = nil,
    open_count = 0,
    diagnostic_reports = {},
    diagnostic_file_counts = {},
    diagnostic_aggregates = {},
    diagnostic_path_nodes = {},
    diagnostic_base_details = {},
    diagnostic_scope = nil,
    disposed = false,
  }
  session.diagnostic_path_nodes[root.payload.lexical_path] = root.id
  session.diagnostic_base_details[root.id] = root.detail
  local selected = session.selected_id
  if selected and selected ~= root.id then
    -- Node IDs are root-scoped URI identities. If the new root differs, do
    -- not carry an unrelated selection across it.
    local previous_root = old and old.root_id
    if previous_root ~= root.id then session.selected_id = root.id end
  end
  scope:defer(function() self:_dispose_session(session) end, "files-session:" .. tostring(tab), "session")
  return session
end

function Controller:_cancel_directory(session, parent_id)
  local request = session.requests[parent_id]
  if request then
    session.requests[parent_id] = nil
    pcall(request.cancel, request)
  end
  local transient = session.loading[parent_id]
  if transient then
    session.loading[parent_id] = nil
    local ids = session.children[parent_id] or {}
    for index = #ids, 1, -1 do
      if ids[index] == transient then table.remove(ids, index); break end
    end
    session.nodes[transient] = nil
  end
end

function Controller:_dispose_session(session)
  if session.disposed then return false end
  session.disposed = true
  if session.pending_operation and self.operations then
    self.operations:cancel(session.pending_operation)
    session.pending_operation = nil
  end
  local parents = {}
  for parent_id in pairs(session.requests) do parents[#parents + 1] = parent_id end
  for _, parent_id in ipairs(parents) do self:_cancel_directory(session, parent_id) end
  if session.diagnostic_scope then session.diagnostic_scope:dispose(); session.diagnostic_scope = nil end
  if session.view then
    session.selected_id = session.view.selected_id or session.selected_id
    session.expanded = copy_map(session.view.expanded)
    session.view = nil
  end
  session.save_buffers = {}
  return true
end

function Controller:_schedule_closed_tab_cleanup(session)
  if self.disposed or session.disposed then return end
  local function cleanup()
    if session.disposed or session.view or vim.api.nvim_tabpage_is_valid(session.tab) then return end
    if self.sessions[session.key] == session then self.sessions[session.key] = nil end
    if session.scope.alive then session.scope:dispose() end
  end
  if not vim.api.nvim_tabpage_is_valid(session.tab) then
    cleanup()
    return
  end
  self.scope:schedule(cleanup)
end

function Controller:_watch_buffer_write(session, buffer, path)
  if not session.view or not vim.api.nvim_buf_is_valid(buffer) or session.save_buffers[buffer] then return end
  local group = vim.api.nvim_create_augroup("WorkbenchFilesSave" .. tostring(buffer) .. tostring(session), { clear = true })
  local directory = vim.fs.dirname(path)
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buffer,
    callback = function()
      if session.scope.alive and session.view and not session.view.closed then self.provider:invalidate(directory) end
    end,
  })
  session.save_buffers[buffer] = group
  session.view.scope:defer(function()
    if session.save_buffers[buffer] == group then session.save_buffers[buffer] = nil end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end, "files-buffer-save:" .. buffer, "autocmd")
end

function Controller:_remove_subtree(session, id)
  local children = session.children[id] or {}
  for _, child in ipairs(children) do self:_remove_subtree(session, child) end
  local item = session.nodes[id]
  local path = item and item.payload and item.payload.lexical_path
  if path and session.diagnostic_path_nodes[path] == id then session.diagnostic_path_nodes[path] = nil end
  session.children[id] = nil
  session.nodes[id] = nil
  session.loaded[id] = nil
  session.loading[id] = nil
  session.expanded[id] = nil
end

function Controller:_set_children(session, parent_id, items)
  local old = session.children[parent_id] or {}
  local next_ids = {}
  for _, item in ipairs(items) do next_ids[item.id] = true end
  for _, child_id in ipairs(old) do if not next_ids[child_id] then self:_remove_subtree(session, child_id) end end
  local ids = {}
  for _, item in ipairs(items) do
    item.parent_id = parent_id
    local previous = session.nodes[item.id]
    if item.expandable then
      if session.expanded[item.id] == nil then session.expanded[item.id] = false end
      if session.view and session.view.expanded[item.id] == nil then
        session.view.expanded[item.id] = session.expanded[item.id]
      end
      if previous and previous.payload then item.payload.ancestors = previous.payload.ancestors or item.payload.ancestors end
    end
    session.nodes[item.id] = item
    local path = item.payload and item.payload.lexical_path
    if path then
      session.diagnostic_path_nodes[path] = item.id
      session.diagnostic_base_details[item.id] = item.detail
      self:_refresh_diagnostic_badge(session, path)
    end
    if item.expandable and not session.children[item.id] then session.children[item.id] = {} end
    ids[#ids + 1] = item.id
  end
  session.children[parent_id] = ids
end

function Controller:_directory_paths(session, path)
  local result = {}
  local current = vim.fs.dirname(path)
  while current do
    local inside = root_policy.contains(session.root_path, current)
    if not inside then break end
    result[#result + 1] = current
    if current == session.root_path then break end
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  return result
end

function Controller:_refresh_diagnostic_badge(session, path)
  local id = session.diagnostic_path_nodes[path]
  local item = id and session.nodes[id]
  if not item then return false end
  local counts = item.kind == "directory" and session.diagnostic_aggregates[path]
    or session.diagnostic_file_counts[path]
  local base = session.diagnostic_base_details[id]
  local badge = diagnostic_badge(counts)
  item.badges = badge and { diagnostics = badge } or nil
  item.detail = base and badge and (base .. " · " .. badge) or base or badge
  return true
end

function Controller:_apply_diagnostic_change(session, event, should_render)
  local resource_value = event and event.resource
  if type(resource_value) ~= "table" or type(resource_value.path) ~= "string" then return false end
  local path, uri = resource_value.path, resource_value.uri
  local previous = uri and session.diagnostic_reports[uri] or nil
  if previous then
    local file_counts = session.diagnostic_file_counts[path]
    if file_counts then apply_counts(file_counts, previous.counts, -1) end
    if file_counts and file_counts.total == 0 then session.diagnostic_file_counts[path] = nil end
    for _, parent in ipairs(self:_directory_paths(session, path)) do
      local counts = session.diagnostic_aggregates[parent] or new_counts()
      apply_counts(counts, previous.counts, -1)
      if counts.total == 0 then session.diagnostic_aggregates[parent] = nil else session.diagnostic_aggregates[parent] = counts end
    end
    session.diagnostic_reports[uri] = nil
  end
  local report = event.report
  if type(report) == "table" and type(report.counts) == "table" and report.counts.total > 0 then
    session.diagnostic_reports[uri] = report
    local file_counts = session.diagnostic_file_counts[path] or new_counts()
    apply_counts(file_counts, report.counts, 1)
    session.diagnostic_file_counts[path] = file_counts
    for _, parent in ipairs(self:_directory_paths(session, path)) do
      local counts = session.diagnostic_aggregates[parent] or new_counts()
      apply_counts(counts, report.counts, 1)
      session.diagnostic_aggregates[parent] = counts
    end
  end
  self:_refresh_diagnostic_badge(session, path)
  for _, parent in ipairs(self:_directory_paths(session, path)) do self:_refresh_diagnostic_badge(session, parent) end
  if should_render and session.view and not session.view.closed then self:_render(session) end
  return true
end

function Controller:_release_diagnostics(session)
  local scope = session.diagnostic_scope
  session.diagnostic_scope = nil
  if scope then scope:dispose() end
end

function Controller:_bind_diagnostics(session)
  self:_release_diagnostics(session)
  session.diagnostic_reports = {}
  session.diagnostic_file_counts = {}
  session.diagnostic_aggregates = {}
  for id, detail in pairs(session.diagnostic_base_details) do
    local item = session.nodes[id]
    if item then item.detail, item.badges = detail, nil end
  end
  if not self.diagnostics then return true end
  local scope, scope_err = session.scope:child("diagnostics-badges:" .. tostring(session.tab))
  if not scope then return nil, scope_err end
  session.diagnostic_scope = scope
  local lease, lease_err = self.diagnostics:subscribe(session.workspace, function(event)
    if not scope.alive or session.diagnostic_scope ~= scope or session.disposed then return end
    self:_apply_diagnostic_change(session, event, true)
  end)
  if not lease then
    scope:dispose()
    session.diagnostic_scope = nil
    session.last_error = lease_err
    return nil, lease_err
  end
  local _, defer_err = scope:defer(function() lease:release() end, "files-diagnostics-lease", "subscription")
  if defer_err then scope:dispose(); session.diagnostic_scope = nil; return nil, defer_err end
  local snapshot, snapshot_err = lease:snapshot()
  if not snapshot then
    scope:dispose()
    session.diagnostic_scope = nil
    session.last_error = snapshot_err
    return nil, snapshot_err
  end
  for _, report in ipairs(snapshot.reports) do
    self:_apply_diagnostic_change(session, { resource = report.resource, report = report }, false)
  end
  return true
end

function Controller:_all_items(session, filtered)
  local items, seen = {}, {}
  local function visit(id)
    if seen[id] then return end
    seen[id] = true
    local item = session.nodes[id]
    if item then
      if not filtered or filtered[id] then items[#items + 1] = item end
      for _, child in ipairs(session.children[id] or {}) do visit(child) end
    end
  end
  visit(session.root_id)
  for id, item in pairs(session.nodes) do
    if not seen[id] and (not filtered or filtered[id]) then items[#items + 1] = item end
  end
  return items
end

function Controller:_filter_nodes(session)
  if session.filter == "" then return nil end
  local query = vim.fn.tolower(session.filter)
  local included = { [session.root_id] = true }
  local matches = {}
  for id, item in pairs(session.nodes) do
    if item.selectable ~= false then
      local label = vim.fn.tolower(item.label or "")
      local path = item.payload and item.payload.resource and item.payload.resource.display_path or ""
      if label:find(query, 1, true) or vim.fn.tolower(path):find(query, 1, true) then matches[id] = true end
    end
  end
  for id in pairs(matches) do
    local current = id
    local visited = {}
    while current and not visited[current] do
      visited[current] = true
      included[current] = true
      local node = session.nodes[current]
      current = node and node.parent_id or nil
    end
  end
  return included, next(matches) ~= nil
end

function Controller:_render(session)
  if not session.view or session.view.closed then return end
  local filtered, has_match = self:_filter_nodes(session)
  if session.filter ~= "" and not has_match then
    local id = "workbench:filter-empty:" .. session.root_id
    session.nodes[id] = {
      id = id, kind = "status", label = "No loaded items match the filter",
      parent_id = session.root_id, selectable = false,
      payload = { transient = true, filter = session.filter },
    }
    local children = session.children[session.root_id] or {}
    local present = false
    for _, child in ipairs(children) do if child == id then present = true; break end end
    if not present then children[#children + 1] = id end
    session.children[session.root_id] = children
    filtered[id] = true
  elseif session.filter == "" or has_match then
    local id = "workbench:filter-empty:" .. session.root_id
    session.nodes[id] = nil
    local children = session.children[session.root_id] or {}
    for index = #children, 1, -1 do if children[index] == id then table.remove(children, index) end end
  end
  session.view.title = session.filter ~= "" and ("Files · loaded tree filter: " .. session.filter) or "Files"
  local items = self:_all_items(session, filtered)
  return session.view:update({ status = "ready", items = items })
end

function Controller:_status_item(session, parent_id, suffix, label, kind)
  local parent = session.nodes[parent_id]
  if not parent then return nil end
  local id = "workbench:" .. suffix .. ":" .. parent_id
  return {
    id = id,
    kind = kind or "status",
    label = label,
    parent_id = parent_id,
    selectable = false,
    payload = { transient = true, parent_id = parent_id },
  }
end

function Controller:_loading(session, parent_id)
  self:_cancel_directory(session, parent_id)
  local item = self:_status_item(session, parent_id, "loading", "Loading directory…", "status")
  if not item then return end
  session.nodes[item.id] = item
  session.loading[parent_id] = item.id
  session.children[parent_id] = session.children[parent_id] or {}
  session.children[parent_id][#session.children[parent_id] + 1] = item.id
  self:_render(session)
end

function Controller:_load(session, parent_id, refresh)
  if session.disposed or not session.scope.alive then return nil, { code = "session_disposed", message = "Files session is closed" } end
  local parent = session.nodes[parent_id]
  if not parent or not parent.payload or not parent.payload.lexical_path then
    return nil, { code = "not_directory", message = "selected item is not an expandable directory" }
  end
  if session.loaded[parent_id] and not refresh then return false end
  if session.requests[parent_id] and not refresh then return session.requests[parent_id] end
  self:_loading(session, parent_id)
  local request, request_error = self.provider:enumerate(session.workspace, parent.payload.lexical_path, {
    refresh = refresh == true,
    parent_id = parent_id,
    ancestors = parent.payload.ancestors or {},
  }, function(event)
    if session.disposed or not session.scope.alive or self.sessions[session.key] ~= session then return end
    if event.kind == "batch" then
      local loading_id = session.loading[parent_id]
      if loading_id then
        session.nodes[loading_id] = nil
        session.loading[parent_id] = nil
      end
      self:_set_children(session, parent_id, event.items or {})
      session.loaded[parent_id] = true
      self:_render(session)
      local pending = session.pending_reveal
      if pending and pending.parent_id == parent_id then
        session.pending_reveal = nil
        local ok, continuation_error = pcall(pending.continuation)
        if not ok then session.last_error = { code = "reveal_failed", message = tostring(continuation_error) } end
      end
      for _, item in ipairs(event.items or {}) do
        if item.expandable and session.expanded[item.id] then self:_load(session, item.id, false) end
      end
    elseif event.kind == "done" then
      session.loaded[parent_id] = true
      session.loading[parent_id] = nil
      session.requests[parent_id] = nil
      session.last_completeness = event.completeness
      self:_render(session)
    elseif event.kind == "error" then
      session.requests[parent_id] = nil
      session.loaded[parent_id] = false
      local loading_id = session.loading[parent_id]
      if loading_id then
        session.nodes[loading_id] = nil
        session.loading[parent_id] = nil
      end
      local old = session.children[parent_id] or {}
      local kept = {}
      for _, id in ipairs(old) do
        if id ~= loading_id then kept[#kept + 1] = id end
      end
      session.children[parent_id] = kept
      local error_row = self:_status_item(session, parent_id, "error", "Unavailable: " .. tostring(event.error.message), "error")
      if error_row then
        session.nodes[error_row.id] = error_row
        session.children[parent_id][#session.children[parent_id] + 1] = error_row.id
      end
      session.last_error = event.error
      self:_render(session)
    end
  end)
  if not request then
    session.last_error = request_error
    return nil, request_error
  end
  session.requests[parent_id] = request
  return request
end

function Controller:_activate(session, id, row)
  local node = session.nodes[id]
  if not node or not node.payload then return nil end
  if node.kind == "directory" then
    if session.view then session.view:toggle_expanded(id) end
    return true
  end
  if node.kind == "status" or node.kind == "error" or node.kind == "limit" then return nil end
  local path = node.payload.lexical_path
  if self.on_open then return self.on_open(node.payload.resource, session, row) end
  local target = session.origin_window
  if not target or not vim.api.nvim_win_is_valid(target) then
    return nil, { code = "editor_window_unavailable", message = "the originating editor window is no longer available" }
  end
  local okay, open_error = pcall(vim.api.nvim_win_call, target, function()
    vim.cmd({ cmd = "edit", args = { path } })
  end)
  if not okay then
    session.last_error = { code = "open_failed", message = tostring(open_error) }
    return nil, session.last_error
  end
  self:_watch_buffer_write(session, vim.api.nvim_win_get_buf(target), path)
  pcall(vim.api.nvim_set_current_win, target)
  return true
end

function Controller:_toggle_directory(session, id, expanded)
  local item = session.nodes[id]
  if not item or not item.expandable then return false end
  session.expanded[id] = expanded == true
  if expanded then return self:_load(session, id, false) end
  self:_cancel_directory(session, id)
  return true
end

function Controller:_set_filter(session, value)
  value = type(value) == "string" and value or ""
  if value ~= "" and session.filter == "" then
    session.filter_expanded = copy_map(session.view and session.view.expanded or session.expanded)
  end
  session.filter = value
  if session.view then
    if value ~= "" then
      local included = self:_filter_nodes(session)
      for id in pairs(included or {}) do
        local item = session.nodes[id]
        if item and item.expandable then session.view.expanded[id] = true end
      end
    elseif session.filter_expanded then
      session.view.expanded = copy_map(session.filter_expanded)
      session.filter_expanded = nil
    end
    session.expanded = copy_map(session.view.expanded)
  end
  return self:_render(session)
end

function Controller:_toggle_policy(session, name)
  if type(self.update_policy) ~= "function" then
    session.last_error = { code = "policy_update_unavailable", message = "workspace policy changes are unavailable in this composition" }
    vim.notify(session.last_error.message, vim.log.levels.WARN, { title = "Workbench Files" })
    return nil, session.last_error
  end
  local current = session.workspace.policy[name] or "exclude"
  local next_value = current == "exclude" and "include" or "exclude"
  local snapshot, err = self.update_policy(session.workspace, { [name] = next_value })
  if not snapshot then
    session.last_error = err or { code = "policy_update_failed", message = "workspace policy could not be updated" }
    vim.notify(session.last_error.message, vim.log.levels.WARN, { title = "Workbench Files" })
    return nil, session.last_error
  end
  self:set_workspace(snapshot, session.tab)
  return true
end

function Controller:_operation_message(session, message, level)
  if session and session.scope.alive then
    session.last_error = { code = "filesystem_operation", message = tostring(message) }
  end
  self.notify(tostring(message), level or vim.log.levels.WARN, { title = "Workbench Files" })
end

function Controller:_refresh_after_operation(session, plan)
  local paths, seen = {}, {}
  local function add(path)
    if not path then return end
    local parent = vim.fs.dirname(path)
    if not seen[parent] then seen[parent] = true; paths[#paths + 1] = parent end
  end
  add(plan.source)
  add(plan.target)
  for _, entry in ipairs(plan.recovery and plan.recovery.ledger or {}) do
    if entry.step == "apply_lsp_workspace_edit" then
      for _, path in ipairs(entry.resources or {}) do add(path) end
    end
  end
  for _, path in ipairs(paths) do
    self.provider:invalidate(path)
    for id, item in pairs(session.nodes) do
      if item.expandable and item.payload and item.payload.lexical_path == path and session.loaded[id] then
        self:_load(session, id, true)
        break
      end
    end
  end
end

function Controller:_selected_file(session, kind)
  local node = session.nodes[session.view and session.view.selected_id]
  if not node or not node.payload then return nil, nil, nil, { code = "no_selection", message = "select a filesystem item first" } end
  local path = node.payload.lexical_path
  if kind == "create_file" or kind == "create_directory" then
    local parent = node.kind == "directory" and path or vim.fs.dirname(path)
    return nil, parent, node
  end
  if node.kind ~= "file" then
    return nil, nil, nil, { code = "unsupported_source_type", message = "select a regular file; directory mutations are unavailable" }
  end
  return path, nil, node
end

function Controller:_run_operation(session, kind, args)
  local operations = self.operations
  if not operations then
    self:_operation_message(session, self.operations_error or "filesystem operations are unavailable")
    return nil
  end
  local plan
  local function prepared(candidate, err)
    if not candidate then
      if session.disposed or not session.view or session.view.closed then return end
      self:_operation_message(session, err and err.message or "operation could not be prepared")
      return
    end
    plan = candidate
    if session.disposed or not session.view or session.view.closed then operations:cancel(plan); return end
    session.pending_operation = plan
    local labels = { "Apply this exact operation", "Cancel" }
    local selected, select_error = pcall(self.select, labels, {
      prompt = "Review this exact filesystem change:\n" .. plan.review .. "\n\nSelect the first item to apply; any other choice cancels.",
      format_item = function(item) return item end,
    }, function(choice)
      if session.pending_operation ~= plan then operations:cancel(plan); return end
      session.pending_operation = nil
      if choice ~= labels[1] then operations:cancel(plan); return end
      local reviewed, review_error = operations:review(plan)
      if not reviewed then self:_operation_message(session, review_error and review_error.message or "operation review expired"); return end
      local okay, apply_error = operations:apply(plan)
      if okay or plan.state == "partial" then self:_refresh_after_operation(session, plan) end
      if not okay then self:_operation_message(session, apply_error and apply_error.message or "filesystem operation failed")
      else
        session.last_error = nil
        self.notify(kind:gsub("_", " ") .. " completed", vim.log.levels.INFO, { title = "Workbench Files" })
      end
    end)
    if not selected then
      if session.pending_operation == plan then session.pending_operation = nil end
      operations:cancel(plan)
      self:_operation_message(session, "operation review UI failed: " .. tostring(select_error))
      return
    end
    if session.disposed or not session.view or session.view.closed then
      if session.pending_operation == plan then session.pending_operation = nil end
      operations:cancel(plan)
    end
  end
  local prepared_plan, prepare_error = operations:prepare(session.workspace, kind, args, prepared)
  if prepared_plan and (prepared_plan.state == "draft" or prepared_plan.state == "validated") and session.view and not session.view.closed then
    session.pending_operation = prepared_plan
  end
  if not prepared_plan and prepare_error then self:_operation_message(session, prepare_error.message) end
  return prepared_plan, prepare_error
end

function Controller:_request_operation(session, kind)
  if not session.view or session.view.closed then return nil end
  local source, parent, node, selection_error = self:_selected_file(session, kind)
  if selection_error then self:_operation_message(session, selection_error.message); return nil, selection_error end
  if kind == "trash" then return self:_run_operation(session, kind, { source = source }) end
  local input = self.input
  local prompt, default
  if kind == "create_file" or kind == "create_directory" then
    prompt = (kind == "create_file" and "Create file in " or "Create directory in ") .. parent .. ": "
  elseif kind == "rename" then
    prompt, default = "Rename " .. source .. " to: ", node.payload.raw_name
  elseif kind == "move" then
    prompt, default = "Move " .. source .. " into directory: ", vim.fs.dirname(source)
  elseif kind == "copy" then
    prompt, default = "Copy " .. source .. " to exact path: ", source .. ".copy"
  end
  input({ prompt = prompt, default = default }, function(value)
    if value == nil then return end
    local args
    if kind == "create_file" or kind == "create_directory" then args = { parent = parent, name = value }
    elseif kind == "rename" then args = { source = source, name = value }
    elseif kind == "move" then args = { source = source, destination = value }
    else args = { source = source, destination = value } end
    self:_run_operation(session, kind, args)
  end)
  return true
end

function Controller:_keymaps(session)
  local function selected_path()
    local node = session.nodes[session.view and session.view.selected_id]
    return node and node.payload and node.payload.lexical_path, node
  end
  local keymaps = {
    ["/"] = {
      desc = "Workbench Files: filter loaded tree",
      run = function()
        vim.ui.input({ prompt = "Filter loaded Files tree: " }, function(value)
          if value ~= nil then self:_set_filter(session, value) end
        end)
      end,
    },
    r = { desc = "Workbench Files: refresh selected directory", run = function()
      local path, node = selected_path()
      if node and node.kind == "directory" then self.provider:invalidate(path); self:_load(session, node.id, true)
      elseif node and node.parent_id then
        local parent = session.nodes[node.parent_id]
        if parent then self.provider:invalidate(parent.payload.lexical_path); self:_load(session, parent.id, true) end
      end
    end },
    R = { desc = "Workbench Files: refresh root", run = function()
      self.provider:invalidate()
      self:_load(session, session.root_id, true)
    end },
    H = { desc = "Workbench Files: toggle hidden policy", run = function() self:_toggle_policy(session, "hidden") end },
    I = { desc = "Workbench Files: toggle ignored policy", run = function() self:_toggle_policy(session, "ignored") end },
    y = { desc = "Workbench Files: copy absolute path", run = function()
      local path = selected_path()
      if path then vim.fn.setreg('"', path) end
    end },
    Y = { desc = "Workbench Files: copy workspace-relative path", run = function()
      local path = selected_path()
      local relative = path and vim.fs.relpath(session.root_path, path)
      if relative then vim.fn.setreg('"', relative) end
    end },
    s = { desc = "Workbench Files: search selected folder", run = function()
      local path, node = selected_path()
      if node and node.kind == "directory" then
        if self.on_search then self.on_search(session.workspace, path, session)
        else vim.notify("Search-in-folder is unavailable until the search capability is enabled", vim.log.levels.INFO, { title = "Workbench Files" }) end
      end
    end },
    a = { desc = "Workbench Files: create file (reviewed)", run = function() self:_request_operation(session, "create_file") end },
    A = { desc = "Workbench Files: create directory (reviewed)", run = function() self:_request_operation(session, "create_directory") end },
    n = { desc = "Workbench Files: rename file (reviewed)", run = function() self:_request_operation(session, "rename") end },
    m = { desc = "Workbench Files: move file (reviewed)", run = function() self:_request_operation(session, "move") end },
    c = { desc = "Workbench Files: copy file (reviewed)", run = function() self:_request_operation(session, "copy") end },
  }
  local capabilities = self.operations and self.operations.capabilities and self.operations:capabilities()
  if capabilities and vim.tbl_contains(capabilities.operations or {}, "trash_file") then
    keymaps.d = { desc = "Workbench Files: move file to recoverable trash", run = function() self:_request_operation(session, "trash") end }
  end
  return keymaps
end

function Controller:_apply_follow(session)
  local enabled = self.get_follow_active_file and self.get_follow_active_file(session) == true
  if session.follow_scope and (not enabled or not session.view) then
    session.follow_scope:dispose()
    session.follow_scope = nil
  end
  if not enabled or not session.view or session.follow_scope then return end
  local owner = assert(session.view.scope:child("follow-active-file"))
  session.follow_scope = owner
  local group = vim.api.nvim_create_augroup("WorkbenchFilesFollow" .. tostring(owner), { clear = true })
  owner:defer(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if session.follow_reveal_generation == session.reveal_generation then
      session.reveal_generation = (session.reveal_generation or 0) + 1
      session.pending_reveal = nil
    end
    session.follow_reveal_generation = nil
    session.follow_path = nil
    if session.follow_scope == owner then session.follow_scope = nil end
  end, "follow-active-file-events", "autocmd")
  local function follow(win)
    if not owner.alive or session.tab ~= vim.api.nvim_get_current_tabpage() or not session.view then return end
    win = win or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then return end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype ~= "" or vim.b[buf].workbench_preview then return end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" or path == session.follow_path then return end
    session.follow_path = path
    self:reveal(path, session.tab)
    session.follow_reveal_generation = session.reveal_generation
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, { group = group, callback = function() follow() end })
  local current = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(current)
  if vim.bo[buf].buftype == "" and not vim.b[buf].workbench_preview
    and vim.api.nvim_win_get_config(current).relative == "" then
    follow(current)
  else
    follow(session.origin_window)
  end
end

function Controller:apply_settings()
  for _, session in pairs(self.sessions) do self:_apply_follow(session) end
  return true
end

function Controller:open(snapshot, opts)
  opts = opts or {}
  if self.disposed or not self.scope.alive then return nil, { code = "controller_disposed", message = "Files controller is disposed" } end
  if type(snapshot) ~= "table" or type(snapshot.roots) ~= "table" or #snapshot.roots ~= 1 then
    return nil, { code = "workspace_unavailable", message = "Files requires a single-root workspace" }
  end
  local tab = opts.tabpage or vim.api.nvim_get_current_tabpage()
  local key = self:_session_key(snapshot, tab)
  local session = self.sessions[key]
  local replacing
  if not session then
    for _, candidate in pairs(self.sessions) do
      if candidate.tab == tab and not candidate.disposed then
        if candidate.view and not candidate.view.closed
          and candidate.workspace.roots[1].uri ~= snapshot.roots[1].uri then
          replacing = candidate
          session = assert(self:_new_session(snapshot, tab, candidate))
          self.sessions[key] = session
        else
          self:set_workspace(snapshot, tab)
          session = self.sessions[key]
        end
        break
      end
    end
    if not session then
      session = assert(self:_new_session(snapshot, tab))
      self.sessions[key] = session
    end
  else
    self:set_workspace(snapshot, tab)
  end
  if session.view and not session.view.closed then
    if opts.focus ~= false and session.view.window and vim.api.nvim_win_is_valid(session.view.window) then
      vim.api.nvim_set_current_win(session.view.window)
    end
    return session.view
  end
  session.origin_window = vim.api.nvim_get_current_win()
  local view, err = self.layout:mount({
    id = opts.view_id or "files",
    replace = replacing ~= nil,
    title = "Files",
    kind = "tree",
    placement = "sidebar",
    focus = opts.focus ~= false,
    selected_id = session.selected_id,
    scroll_offset = session.scroll_offset,
    expanded = session.expanded,
    model = { status = "ready", items = self:_all_items(session, self:_filter_nodes(session)) },
    help_lines = {
      "j/k or arrows: move; l/Right expand; h/Left parent",
      "Enter: open file or expand directory; Space toggles",
      "/ filter loaded tree; r refresh; R refresh root",
      "H/I toggle hidden/project ignores; y/Y copy",
      "Global and .git/info excludes unavailable",
      "s searches selected folder",
      self.operations and self.operations.trash and "a/A create; n rename; m move; c copy; d recoverable trash"
        or "a/A create; n rename; m move; c copy; trash unavailable (no recoverable adapter)",
      "Every filesystem action shows an exact review first; directory moves/copies unavailable",
      "q closes Files; ? hides help",
    },
    keymaps = self:_keymaps(session),
  })
  if not view then
    if replacing then
      if self.sessions[key] == session then self.sessions[key] = nil end
      if session.scope.alive then session.scope:dispose() end
    end
    return nil, err
  end
  if replacing then
    if self.sessions[replacing.key] == replacing then self.sessions[replacing.key] = nil end
    if replacing.scope.alive then replacing.scope:dispose() end
  end
  session.view = view
  session.open_count = session.open_count + 1
  view.on_select = function(id, row, activate)
    session.selected_id = id
    if activate then return self:_activate(session, id, row) end
  end
  view.on_toggle = function(id, expanded) return self:_toggle_directory(session, id, expanded) end
  view.scope:defer(function()
    if session.view == view then
      if session.pending_operation and self.operations then
        self.operations:cancel(session.pending_operation)
        session.pending_operation = nil
      end
      session.selected_id = view.selected_id or session.selected_id
      session.scroll_offset = view.scroll_offset
      session.expanded = copy_map(view.expanded)
      session.view = nil
      session.reveal_generation = (session.reveal_generation or 0) + 1
      session.pending_reveal = nil
      self:_release_diagnostics(session)
      local pending = {}
      for parent_id in pairs(session.requests) do pending[#pending + 1] = parent_id end
      for _, parent_id in ipairs(pending) do self:_cancel_directory(session, parent_id) end
      self:_schedule_closed_tab_cleanup(session)
    end
  end, "files-view-state:" .. session.key, "state")
  local _, diagnostic_error = self:_bind_diagnostics(session)
  if diagnostic_error then session.last_error = diagnostic_error end
  if session.filter ~= "" then self:_set_filter(session, session.filter) end
  if not session.loaded[session.root_id] then self:_load(session, session.root_id, false) end
  self:_apply_follow(session)
  return view
end

function Controller:set_workspace(snapshot, tab)
  if type(snapshot) ~= "table" or type(snapshot.roots) ~= "table" or #snapshot.roots ~= 1 then
    return nil, { code = "workspace_unavailable", message = "Files requires a single-root workspace" }
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  local old_key = self:_session_key(snapshot, tab)
  local session = self.sessions[old_key]
  if not session then
    for _, candidate in pairs(self.sessions) do
      if candidate.tab == tab then session = candidate; break end
    end
  end
  if not session then return nil, { code = "files_session_unavailable", message = "Files is not open in this tab" } end
  local root_changed = session.workspace.roots[1].uri ~= snapshot.roots[1].uri
  local generation_changed = session.workspace.generation ~= snapshot.generation
  if root_changed or generation_changed then
    if session.pending_operation and self.operations then
      self.operations:cancel(session.pending_operation)
      session.pending_operation = nil
    end
    local pending = {}
    for id in pairs(session.requests) do pending[#pending + 1] = id end
    for _, id in ipairs(pending) do self:_cancel_directory(session, id) end
    session.workspace = snapshot
    self.provider:invalidate()
    if root_changed then
      local previous_key = session.key
      self.sessions[previous_key] = nil
      session.root_path = snapshot.roots[1].path
      local root = root_item(snapshot)
      session.root_id = root.id
      session.nodes = { [root.id] = root }
      session.children = { [root.id] = {} }
      session.loaded = {}
      session.expanded = { [root.id] = true }
      session.selected_id = root.id
      session.filter = ""
      session.filter_expanded = nil
      session.diagnostic_path_nodes = { [root.payload.lexical_path] = root.id }
      session.diagnostic_base_details = { [root.id] = root.detail }
      session.key = self:_session_key(snapshot, tab)
      self.sessions[session.key] = session
    else
      local root = root_item(snapshot)
      local expanded = copy_map(session.expanded)
      session.nodes = { [root.id] = root }
      session.children = { [root.id] = {} }
      session.loaded = {}
      session.loading = {}
      session.expanded = expanded
      session.expanded[root.id] = true
      session.selected_id = session.selected_id or root.id
      session.diagnostic_path_nodes = { [root.payload.lexical_path] = root.id }
      session.diagnostic_base_details = { [root.id] = root.detail }
    end
  end
  if session.view then
    session.view.expanded = copy_map(session.expanded)
    self:_bind_diagnostics(session)
    self:_render(session)
    if not session.loaded[session.root_id] then self:_load(session, session.root_id, true) end
  end
  return session
end

function Controller:set_filter(value, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for _, session in pairs(self.sessions) do
    if session.tab == tab and session.view then return self:_set_filter(session, value) end
  end
  return nil, { code = "files_session_unavailable", message = "Files view is not open in this tab" }
end

function Controller:refresh(path, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for _, session in pairs(self.sessions) do
    if session.tab == tab and session.view then
      local parent_id
      if path then
        for id, item in pairs(session.nodes) do
          if item.payload and item.payload.lexical_path == path then parent_id = id; break end
        end
      else
        parent_id = session.root_id
        path = session.root_path
      end
      if not parent_id then return nil, { code = "directory_not_loaded", message = "directory is not in the loaded Files tree" } end
      self.provider:invalidate(path)
      return self:_load(session, parent_id, true)
    end
  end
  return nil, { code = "files_session_unavailable", message = "Files view is not open in this tab" }
end

function Controller:reveal(path, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local session
  for _, candidate in pairs(self.sessions) do if candidate.tab == tab and candidate.view then session = candidate; break end end
  if not session then return nil, { code = "files_session_unavailable", message = "Files view is not open in this tab" } end
  session.reveal_generation = (session.reveal_generation or 0) + 1
  session.pending_reveal = nil
  local generation, view, workspace_generation = session.reveal_generation, session.view, session.workspace.generation
  local function current()
    return not session.disposed and session.scope.alive and session.view == view and not view.closed
      and generation == session.reveal_generation and session.workspace.generation == workspace_generation
  end
  local relative = reveal_relative(session, path)
  if relative == nil then
    return nil, { code = "outside_root", message = "resource lies outside this workspace; select its parent as a workspace root", action = "select_root" }
  end
  if relative == "." then session.selected_id = session.root_id; self:_render(session); return true end
  local parts = {}
  for part in relative:gmatch("[^/\\\\]+") do parts[#parts + 1] = part end
  local current_id, index = session.root_id, 1
  local function step()
    if not current() then return end
    if index > #parts then
      session.selected_id = current_id
      local item = session.nodes[current_id]
      if item and item.expandable then session.view.expanded[current_id] = true; self:_load(session, current_id, false) end
      session.view.selected_id = current_id
      self:_render(session)
      return true
    end
    local parent_id = current_id
    local name = parts[index]
    local function select_child()
      if not current() then return end
      for _, child_id in ipairs(session.children[parent_id] or {}) do
        local child = session.nodes[child_id]
        if child and child.payload and child.payload.raw_name == name then
          current_id = child_id
          index = index + 1
          session.view.expanded[parent_id] = true
          session.expanded[parent_id] = true
          return step()
        end
      end
      session.last_error = { code = "resource_missing", message = "resource disappeared before it could be revealed" }
      return nil, session.last_error
    end
    if session.loaded[parent_id] then return select_child() end
    session.view.expanded[parent_id] = true
    session.expanded[parent_id] = true
    local request, err = self:_load(session, parent_id, false)
    if not request then return nil, err end
    local original = session.requests[parent_id]
    local prior_loaded = session.loaded[parent_id]
    if prior_loaded then return select_child() end
    session.pending_reveal = { parent_id = parent_id, continuation = select_child, request = original }
    return true
  end
  return step()
end

function Controller:status()
  local sessions = {}
  for key, session in pairs(self.sessions) do
    sessions[#sessions + 1] = {
      key = key,
      workspace_id = session.workspace.id,
      generation = session.workspace.generation,
      root = session.root_path,
      loaded_nodes = vim.tbl_count(session.nodes),
      active_requests = vim.tbl_count(session.requests),
      mounted = session.view ~= nil and not session.view.closed,
      selection = session.selected_id,
      filter = session.filter,
      last_error = session.last_error,
    }
  end
  table.sort(sessions, function(left, right) return left.key < right.key end)
  return {
    disposed = self.disposed,
    sessions = sessions,
    session_count = #sessions,
    provider = self.provider:status(),
    policy_limitations = { "global-ignore-sources", "git-info-exclude" },
  }
end

function Controller:dispose()
  if self.disposed then return false end
  self.disposed = true
  for _, session in pairs(self.sessions) do self:_dispose_session(session) end
  self.sessions = {}
  if self.owns_operations and self.operations then self.operations:dispose() end
  return self.scope:dispose()
end

return M
