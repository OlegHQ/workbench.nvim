local Scope = require("workbench.core.scope")
local RootPolicy = require("workbench.core.root_policy")
local Workspace = require("workbench.core.workspace")
local UiSearch = require("workbench.ui.search")
local Resource, Location, BufferSnapshots

local function resource_module()
  Resource = Resource or require("workbench.core.resource")
  return Resource
end

local function location_module()
  Location = Location or require("workbench.core.location")
  return Location
end

local function buffer_snapshots()
  BufferSnapshots = BufferSnapshots or require("workbench.services.buffers")
  return BufferSnapshots
end

local M = { debounce_ms = 80, history_limit = 10, initial_page_size = UiSearch.page_size }
local Controller = {}
Controller.__index = Controller

local function copy(value)
  return vim.deepcopy(value)
end

local function current_editor_window(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(win) then
      local config = vim.api.nvim_win_get_config(win)
      local buf = vim.api.nvim_win_get_buf(win)
      if config.relative == "" and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and not vim.b[buf].workbench_preview then
        return win
      end
    end
  end
end

local function capture_origin(tab)
  local win = current_editor_window(tab)
  if not win then return nil end
  return {
    win = win,
    buf = vim.api.nvim_win_get_buf(win),
    cursor = vim.api.nvim_win_get_cursor(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    tab = tab,
  }
end

local function scope_key(workspace, tab)
  return workspace.id .. "\0" .. tostring(tab)
end

local function buffer_path(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return nil end
  local path = vim.api.nvim_buf_get_name(buffer)
  if path == "" then return nil end
  local normalized = vim.fs.normalize(path)
  return normalized:sub(1, 1) == "/" and normalized or nil
end

local function scope_contains(scope, path, root)
  if scope.kind == "file" then return vim.fs.normalize(scope.path or "") == path end
  if scope.kind == "folder" then return RootPolicy.contains(scope.path, path) end
  return RootPolicy.contains(root, path)
end

local function modified_count(workspace, scope)
  local root = workspace.roots[1].path
  local count = 0
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
      local path = buffer_path(buffer)
      if path and scope_contains(scope, path, root) then count = count + 1 end
    end
  end
  return count
end

local function normalized_scope(scope, workspace)
  scope = copy(scope or workspace.scope)
  if scope.kind == "all_roots" then return { kind = "all_roots", explicit = true } end
  if scope.kind == "folder" or scope.kind == "file" then
    local path = scope.path or (scope.resource and scope.resource.path)
    if type(path) ~= "string" then return nil, { code = "invalid_scope", message = scope.kind .. " scope requires a native path" } end
    path = vim.fs.normalize(path)
    local inside, err = RootPolicy.contains(workspace.roots[1].path, path)
    if not inside then return nil, { code = "outside_root", message = err or "scope lies outside the selected workspace" } end
    if scope.kind == "folder" then
      local stat = (vim.uv or vim.loop).fs_lstat(path)
      if not stat or stat.type ~= "directory" then return nil, { code = "invalid_scope", message = "folder scope must be an existing directory" } end
    end
    return { kind = scope.kind, explicit = true, path = path }
  end
  if scope.kind == "open_buffers" then return { kind = "open_buffers", explicit = true } end
  return nil, { code = "invalid_scope", message = "search scope must be workspace, folder, current file, or open buffers" }
end

local function entry_query(entry)
  return entry and entry.options and entry.options.query or ""
end

function M.new(deps)
  deps = deps or {}
  if type(deps.layout) ~= "table" or type(deps.layout.mount) ~= "function" then return nil, "Search controller requires a native layout manager" end
  if type(deps.provider) ~= "table" or type(deps.provider.start) ~= "function" then return nil, "Search controller requires a structured search provider" end
  if type(deps.store) ~= "table" or type(deps.store.create) ~= "function" or type(deps.store.page) ~= "function" then
    return nil, "Search controller requires the shared bounded result store"
  end
  if type(deps.navigation) ~= "table" or type(deps.navigation.preview) ~= "function"
    or type(deps.navigation.open) ~= "function" or type(deps.navigation.return_to_origin) ~= "function" then
    return nil, "Search controller requires the preview/open/return navigation service"
  end
  if deps.actions ~= nil and type(deps.actions.register) ~= "function" then return nil, "actions must be a shared action registry" end
  if deps.replacement ~= nil and (type(deps.replacement) ~= "table" or type(deps.replacement.prepare) ~= "function"
    or type(deps.replacement.review) ~= "function" or type(deps.replacement.apply) ~= "function"
    or type(deps.replacement.cancel) ~= "function") then
    return nil, "replacement must implement prepare, review, apply and cancel"
  end

  local self = setmetatable({
    layout = deps.layout,
    provider = deps.provider,
    store = deps.store,
    navigation = deps.navigation,
    get_preview_settings = deps.get_preview_settings,
    get_search_settings = deps.get_search_settings,
    get_history_limit = deps.get_history_limit,
    buffer_list_factory = type(deps.buffer_list_factory) == "function" and deps.buffer_list_factory or nil,
    replacement = deps.replacement,
    owns_replacement = deps.replacement == nil,
    replacement_options = deps.replacement_options,
    actions = deps.actions or require("workbench.core.actions").new(),
    owns_actions = deps.actions == nil,
    get_workspace = type(deps.get_workspace) == "function" and deps.get_workspace or function() return deps.workspace end,
    update_policy = deps.update_policy,
    input = type(deps.input) == "function" and deps.input or vim.ui.input,
    select = type(deps.select) == "function" and deps.select or vim.ui.select,
    notify = deps.notify,
    debounce = math.max(0, math.min(300, tonumber(deps.debounce_ms) or M.debounce_ms)),
    scope = Scope.new("workbench-search-controller"),
    investigations = {},
    active = {},
    capabilities = {},
    buffer_controller = nil,
    next_id = 0,
    disposed = false,
  }, Controller)

  local palette, palette_err
  if deps.palette then palette = deps.palette
  else palette, palette_err = require("workbench.ui.palette").new({
    layout = self.layout,
    actions = self.actions,
    context = function() return self:_action_context() end,
    input = self.input,
  })
  end
  if not palette then self.scope:dispose(); return nil, palette_err or "action palette could not be created" end
  self.palette = palette
  self.owns_palette = deps.palette == nil
  self.palette.bindings = vim.tbl_extend("force", self.palette.bindings or {}, {
    ["search.rerun"] = "Search: r",
    ["search.cancel"] = "Search: x",
    ["search.resume"] = "Search: u",
    ["search.replace_selected"] = "Search: X",
    ["search.current_file"] = "Search: F",
    ["search.toggle_literal"] = "Search: l",
    ["search.toggle_word"] = "Search: w",
    ["search.cycle_case"] = "Search: c",
    ["search.toggle_hidden"] = "Search: H",
    ["search.toggle_ignored"] = "Search: I",
    ["search.palette"] = "Search: P",
  })
  local registered, register_err = self:_register_actions()
  if not registered then self.scope:dispose(); return nil, register_err end
  return self
end

function Controller:_capability(workspace)
  local key = workspace.id
  local cached = self.capabilities[key]
  if cached and cached.generation == workspace.generation and vim.deep_equal(cached.policy, workspace.policy) then return cached.value end
  local capability = self.provider:capabilities({ workspace = workspace })
  self.capabilities[key] = { generation = workspace.generation, policy = copy(workspace.policy), value = copy(capability) }
  return self.capabilities[key].value
end

function Controller:_investigation(workspace, tab)
  local key = scope_key(workspace, tab)
  local investigation = self.investigations[key]
  if not investigation then
    self.next_id = self.next_id + 1
    investigation = { key = key, id = "search-" .. self.next_id, workspace = copy(workspace), tab = tab, history = {}, current = nil, generation = 0 }
    self.investigations[key] = investigation
  else
    investigation.workspace = copy(workspace)
  end
  return investigation
end

function Controller:_action_context(overrides)
  local tab = vim.api.nvim_get_current_tabpage()
  local active = self.active[tab]
  local workspace = overrides and overrides.workspace or (active and active.investigation.workspace) or self.get_workspace()
  local win = overrides and overrides.win
  local bufnr = overrides and overrides.bufnr
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
    or vim.api.nvim_win_get_buf(win) ~= bufnr then
    win, bufnr = nil, nil
    local current = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_tabpage(current) == tab
      and vim.api.nvim_win_get_config(current).relative == "" then
      local current_buf = vim.api.nvim_win_get_buf(current)
      if vim.bo[current_buf].buftype == "" and not vim.b[current_buf].workbench_preview then win, bufnr = current, current_buf end
    end
    if not win and active and active.navigation_target and vim.api.nvim_win_is_valid(active.navigation_target)
      and vim.api.nvim_win_get_tabpage(active.navigation_target) == tab then
      local target_buf = vim.api.nvim_win_get_buf(active.navigation_target)
      if vim.bo[target_buf].buftype == "" and not vim.b[target_buf].workbench_preview then win, bufnr = active.navigation_target, target_buf end
    end
    if not win then
      win = current_editor_window(tab)
      if win then bufnr = vim.api.nvim_win_get_buf(win) end
    end
  end
  local current_file = bufnr and buffer_path(bufnr) or nil
  return vim.tbl_extend("force", {
    controller = self,
    actions = self.actions,
    workspace = workspace,
    search = active,
    bufnr = bufnr,
    win = win,
    path = overrides and overrides.path,
    current_file = current_file,
    capability = workspace and self:_capability(workspace) or nil,
  }, overrides or {})
end

function Controller:_register(action)
  return self.actions:register(action, { scope = self.scope })
end

function Controller:_register_actions()
  local controller = self
  local actions = {
    {
      id = "search.workspace", title = "Search workspace", category = "Search", scope = "workspace",
      available = function(ctx)
        local ready = type(ctx.workspace) == "table" and ctx.capability and ctx.capability.state == "ready"
        return { enabled = ready == true, reason = ctx.capability and ctx.capability.reason or "no workspace is active", code = ctx.capability and ctx.capability.state }
      end,
      run = function(ctx) return controller:open({ workspace = ctx.workspace, query = "" }) end,
    },
    {
      id = "search.in_folder", title = "Search in folder", category = "Search", scope = "item",
      available = function(ctx)
        local ready = type(ctx.workspace) == "table" and type(ctx.path) == "string" and ctx.capability and ctx.capability.state == "ready"
        return { enabled = ready == true, reason = type(ctx.path) ~= "string" and "select a folder in Files first" or ctx.capability and ctx.capability.reason or "workspace is unavailable" }
      end,
      run = function(ctx) return controller:search_in_folder(ctx.workspace, ctx.path) end,
    },
    {
      id = "search.current_file", title = "Search current file", category = "Search", scope = "buffer",
      available = function(ctx)
        local ready = type(ctx.workspace) == "table" and ctx.workspace.roots and #ctx.workspace.roots == 1
          and type(ctx.current_file) == "string" and ctx.capability and ctx.capability.state == "ready"
        return { enabled = ready == true, reason = type(ctx.current_file) ~= "string" and "no named editor file is active" or ctx.capability and ctx.capability.reason or "workspace is unavailable" }
      end,
      run = function(ctx) return controller:search_current_file(ctx.workspace, ctx.current_file) end,
    },
    {
      id = "search.open_buffers", title = "Search open buffers", category = "Search", scope = "workspace",
      available = function(ctx)
        local ready = type(ctx.workspace) == "table" and ctx.capability and ctx.capability.state == "ready"
        return ready and { enabled = true } or { enabled = false, reason = ctx.capability and ctx.capability.reason or "no workspace is active" }
      end,
      run = function(ctx) return controller:search_open_buffers(ctx.workspace, ctx) end,
    },
    {
      id = "buffers.list", title = "Open or recent buffer list", category = "Buffers", scope = "workspace",
      available = function(ctx)
        if type(ctx.workspace) ~= "table" then return { enabled = false, reason = "no workspace is active" } end
        return type(controller.buffer_list_factory) == "function"
          and { enabled = true }
          or { enabled = false, reason = "the buffer-list view is not installed" }
      end,
      run = function(ctx) return controller:open_buffer_list(ctx) end,
    },
    {
      id = "search.rerun", title = "Rerun current search", category = "Search", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil and ctx.search.investigation.current ~= nil, reason = "there is no retained search to rerun" } end,
      run = function(ctx) return controller:rerun(ctx.search) end,
    },
    {
      id = "search.replace_selected", title = "Review literal replacement", category = "Search", scope = "view",
      available = function(ctx)
        local enabled, reason = controller:_replacement_available(ctx.search)
        return { enabled = enabled, reason = reason }
      end,
      args_schema = { type = "object", properties = { replacement = { type = "string" } }, additional_properties = false },
      run = function(ctx, args) return controller:replace_selected(ctx.search, args and args.replacement) end,
    },
    {
      id = "search.cancel", title = "Cancel current search", category = "Search", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil and ctx.search.request ~= nil, reason = "there is no active search" } end,
      run = function(ctx) return controller:cancel(ctx.search) end,
    },
    {
      id = "search.resume", title = "Resume a retained search", category = "Search", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil and #ctx.search.investigation.history > 0, reason = "there is no retained search history" } end,
      run = function(ctx) return controller:prompt_resume(ctx.search) end,
    },
    {
      id = "search.toggle_literal", title = "Toggle literal/regex matching", category = "Search Flags", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil, reason = "open a Search view first" } end,
      checked = function(ctx) return ctx.search and ctx.search.flags.fixed or false end,
      run = function(ctx) return controller:toggle_flag(ctx.search, "fixed") end,
    },
    {
      id = "search.toggle_word", title = "Toggle whole-word matching", category = "Search Flags", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil, reason = "open a Search view first" } end,
      checked = function(ctx) return ctx.search and ctx.search.flags.word or false end,
      run = function(ctx) return controller:toggle_flag(ctx.search, "word") end,
    },
    {
      id = "search.cycle_case", title = "Cycle case matching", category = "Search Flags", scope = "view",
      available = function(ctx) return { enabled = ctx.search ~= nil, reason = "open a Search view first" } end,
      run = function(ctx) return controller:cycle_case(ctx.search) end,
    },
    {
      id = "search.toggle_hidden", title = "Toggle hidden files", category = "Search Policy", scope = "workspace",
      available = function(ctx) return { enabled = type(ctx.workspace) == "table" and ctx.search ~= nil, reason = ctx.search and "no workspace is active" or "open a Search view first" } end,
      checked = function(ctx) return ctx.workspace and ctx.workspace.policy.hidden == "include" or false end,
      run = function(ctx) return controller:toggle_policy(ctx.search, "hidden") end,
    },
    {
      id = "search.toggle_ignored", title = "Toggle ignored files", category = "Search Policy", scope = "workspace",
      available = function(ctx)
        if not ctx.workspace or not ctx.search then return { enabled = false, reason = "open a Search view first" } end
        if ctx.search and ctx.search.scope.kind == "file" then
          return { enabled = false, code = "explicit_file_scope", reason = "an explicitly targeted current file follows ripgrep direct-file semantics; the ignored toggle does not change it" }
        end
        return { enabled = true }
      end,
      checked = function(ctx) return ctx.workspace and ctx.workspace.policy.ignored == "include" or false end,
      run = function(ctx) return controller:toggle_policy(ctx.search, "ignored") end,
    },
    {
      id = "search.palette", title = "Open action palette", category = "Workbench", scope = "global",
      available = function() return { enabled = controller.palette ~= nil, reason = "action palette is unavailable" } end,
      run = function(ctx) return controller.palette and controller.palette:open({ context = ctx }) end,
    },
  }
  for _, action in ipairs(actions) do
    local handle, err = self:_register(action)
    if not handle then self.registration_error = err; return nil, err end
  end
  return true
end

function Controller:_action_result(id, active, args)
  local result = self.actions:execute(id, self:_action_context({
    workspace = active and active.investigation.workspace or self.get_workspace(),
    search = active,
    path = args and args.path,
    ui = active and active.view,
  }), args or {})
  if not result.ok and active and not active.closed then
    active.notice = { id = id, label = "Action unavailable: " .. tostring(result.error.message), detail = result.error.code }
    self:_render(active)
  end
  return result
end

function Controller:_new_ui(investigation, opts)
  local child, child_err = self.scope:child("view:" .. investigation.id .. ":" .. tostring(investigation.tab))
  if not child then return nil, child_err end
  local active = {
    investigation = investigation,
    tab = investigation.tab,
    scope_owner = child,
    view = nil,
    preview = nil,
    request = nil,
    request_scope = nil,
    timer_scope = nil,
    render_ticket = nil,
    query = opts.query or (investigation.current and entry_query(investigation.current)) or "",
    flags = copy(opts.flags or (investigation.current and investigation.current.options.flags) or { fixed = true, case = "smart", word = false }),
    scope = assert(normalized_scope(opts.scope or (investigation.current and investigation.current.options.scope) or investigation.workspace.scope, investigation.workspace)),
    visible_limit = investigation.current and investigation.current.view_state and investigation.current.view_state.visible_limit or UiSearch.page_size,
    offset = investigation.current and investigation.current.view_state and investigation.current.view_state.offset or 0,
    expanded = investigation.current and investigation.current.view_state and copy(investigation.current.view_state.expanded) or {},
    phase = investigation.current and "Resumed" or "Ready",
    notice = nil,
    modified_count = 0,
    snapshot_count = nil,
    snapshot_skipped_count = 0,
    runner = nil,
    origin = capture_origin(investigation.tab),
    selected_id = investigation.current and investigation.current.view_state and investigation.current.view_state.selected_id
      or (investigation.current and investigation.current.store_session.selected_id) or nil,
    marked_matches = {},
    closed = false,
  }
  local existing = self.active[active.tab]
  if existing and not existing.closed and not opts.replace then
    child:dispose()
    return nil, { code = "search_view_open", message = "a Search view is already open in this tab" }
  end
  self.active[active.tab] = active
  child:defer(function() self:_dispose_ui(active) end, "search-ui:" .. investigation.id, "session")

  if self.navigation then
    local preview_settings = self.get_preview_settings and self.get_preview_settings(active) or {}
    local preview, preview_err = require("workbench.ui.preview").new({
      navigation = self.navigation,
      session_id = investigation.id,
      enabled = preview_settings.enabled,
      max_bytes = preview_settings.max_bytes,
    })
    if not preview then child:dispose(); return nil, preview_err end
    active.preview = preview
    child:defer(function() preview:dispose() end, "search-preview:" .. investigation.id, "view")
  end

  local help = UiSearch.help_lines(self.actions:list(self:_action_context({ workspace = investigation.workspace, search = active })))
  local view, mount_err = self.layout:mount({
    id = "workbench-search",
    replace = opts.replace,
    title = "Search",
    kind = "tree",
    placement = "results",
    focus = opts.focus ~= false,
    model = { status = "ready", items = {} },
    help_lines = help,
    keymaps = self:_keymaps(active),
    on_select = function(id, row, committed) return self:_select(active, id, row, committed) end,
    on_toggle = function(id, expanded) return self:_toggle_group(active, id, expanded) end,
    on_dispose = function()
      self:_dispose_ui(active)
      child:dispose()
    end,
  })
  if not view then
    active.closed = true
    self.active[active.tab] = nil
    child:dispose()
    return nil, mount_err
  end
  active.view = view

  local entry = investigation.current
  if entry and entry.store_session then
    local resumed, resume_err = self.store:resume(entry.store_session.id)
    if not resumed then
      active.notice = { id = "resume-error", label = "Previous search is unavailable", detail = resume_err }
      investigation.current = nil
      entry = nil
    else
      entry.store_session = resumed
      active.query = opts.query ~= nil and opts.query or entry_query(entry)
      active.flags = copy(opts.flags or entry.options.flags)
      active.scope = copy(opts.scope or entry.options.scope)
      active.phase = self:_phase_for(entry)
    end
  end
  if entry and active.selected_id then entry.store_session:select(active.selected_id) end
  active.search_settings = self.get_search_settings and self.get_search_settings(active) or nil
  self:_render(active, true)
  local changed = entry and (active.query ~= entry_query(entry)
    or not vim.deep_equal(active.scope, entry.options.scope)
    or not vim.deep_equal(active.flags, entry.options.flags)
    or (active.search_settings and active.search_settings.max_results ~= entry.max_results)
    or (entry.workspace_generation and entry.workspace_generation ~= investigation.workspace.generation))
  if changed or (not entry and active.query ~= "") then self:set_query(active, active.query) end
  return view
end

function Controller:open(opts)
  opts = opts or {}
  if self.disposed then return nil, { code = "disposed", message = "Search controller is disposed" } end
  if type(opts) ~= "table" then return nil, { code = "invalid_options", message = "Search options must be a table" } end
  if opts.query ~= nil and (type(opts.query) ~= "string" or opts.query:find("\0", 1, true)) then
    return nil, { code = "invalid_query", message = "query must be a string without NUL bytes" }
  end
  local workspace = opts.workspace or self.get_workspace()
  if type(workspace) ~= "table" then return nil, { code = "workspace_unavailable", message = "an explicit workspace snapshot is required" } end
  local capability = self:_capability(workspace)
  if capability.state == "unsupported" then
    return nil, { code = capability.reason or "search_unsupported", message = capability.reason or "search is unsupported for this workspace" }
  end
  local tab = opts.tab or vim.api.nvim_get_current_tabpage()
  local active = self.active[tab]
  local same_workspace = active and not active.closed and vim.deep_equal(active.investigation.workspace, workspace)
  local previous = self.investigations[scope_key(workspace, tab)]
  local normalized, scope_err = normalized_scope(opts.scope or (same_workspace and active.scope)
    or (previous and previous.current and previous.current.options.scope) or workspace.scope, workspace)
  if not normalized then return nil, scope_err end
  if same_workspace then
    local query = opts.query ~= nil and opts.query or active.query
    local flags = opts.flags or active.flags
    local changed = query ~= active.query or not vim.deep_equal(normalized, active.scope)
      or not vim.deep_equal(flags, active.flags)
    if changed then
      active.scope, active.flags = normalized, copy(flags)
      active.selected_id = nil
      local updated, update_error = self:set_query(active, query, true)
      if not updated then return nil, update_error end
    end
    if opts.focus ~= false and active.view.window and vim.api.nvim_win_is_valid(active.view.window) then
      vim.api.nvim_set_current_win(active.view.window)
    end
    return active.view
  end
  local previous_workspace = previous and copy(previous.workspace)
  local investigation = self:_investigation(workspace, tab)
  opts = vim.tbl_extend("force", opts, { scope = normalized, replace = active and not active.closed or false })
  local view, err = self:_new_ui(investigation, opts)
  if not view then
    if active and not active.closed then self.active[tab] = active end
    if previous_workspace then investigation.workspace = previous_workspace
    elseif not investigation.current then self.investigations[investigation.key] = nil end
    return nil, err
  end
  return view
end

function Controller:search_in_folder(workspace, path, opts)
  if type(workspace) ~= "table" or type(path) ~= "string" then return nil, { code = "invalid_scope", message = "folder search requires a workspace snapshot and path" } end
  return self:open(vim.tbl_extend("force", opts or {}, { workspace = workspace, scope = { kind = "folder", explicit = true, path = path } }))
end

function Controller:search_current_file(workspace, path, opts)
  workspace = workspace or self.get_workspace()
  if type(workspace) ~= "table" then return nil, { code = "workspace_unavailable", message = "an explicit workspace snapshot is required" } end
  if not path then
    local win = current_editor_window(vim.api.nvim_get_current_tabpage())
    if not win then return nil, { code = "file_unavailable", message = "no named editor file is active" } end
    path = buffer_path(vim.api.nvim_win_get_buf(win))
  end
  if not path then return nil, { code = "file_unavailable", message = "current buffer has no native file path" } end
  return self:open(vim.tbl_extend("force", opts or {}, { workspace = workspace, scope = { kind = "file", explicit = true, path = path } }))
end

function Controller:search_open_buffers(workspace, opts)
  workspace = workspace or self.get_workspace()
  if type(workspace) ~= "table" then return nil, { code = "workspace_unavailable", message = "an explicit workspace snapshot is required" } end
  local tab = opts and opts.tab or vim.api.nvim_get_current_tabpage()
  local active = self.active[tab]
  if active and not active.closed then return self:set_scope(active, { kind = "open_buffers", explicit = true }) end
  return self:open(vim.tbl_extend("force", opts or {}, { workspace = workspace, scope = { kind = "open_buffers", explicit = true } }))
end

function Controller:open_buffer_list(opts)
  if self.disposed then return nil, { code = "disposed", message = "Search controller is disposed" } end
  if not self.buffer_controller then
    if not self.buffer_list_factory then
      return nil, { code = "capability_unavailable", message = "the buffer-list view is not installed" }
    end
    local ok, controller, err = pcall(self.buffer_list_factory, { layout = self.layout, navigation = self.navigation })
    if not ok then return nil, { code = "buffer_list_factory_failed", message = tostring(controller) } end
    if not controller then return nil, err or { code = "buffer_list_factory_failed", message = "buffer-list controller could not be created" } end
    if type(controller.open) ~= "function" or type(controller.dispose) ~= "function" then
      pcall(function() if type(controller.dispose) == "function" then controller:dispose() end end)
      return nil, { code = "invalid_buffer_list_factory", message = "the buffer-list factory returned an invalid controller" }
    end
    self.buffer_controller = controller
    local _, defer_err = self.scope:defer(function() controller:dispose() end, "open-buffer-list-controller", "controller")
    if defer_err then controller:dispose(); self.buffer_controller = nil; return nil, defer_err end
  end
  return self.buffer_controller:open(opts)
end

function Controller:_keymaps(active)
  return {
    ["/"] = { desc = "Set search query", run = function() self:_prompt_query(active) end },
    r = { desc = "Rerun search", run = function() self:rerun(active) end },
    x = { desc = "Cancel search", run = function() self:cancel(active) end },
    p = { desc = "Preview selected match", run = function() self:preview_selected(active) end },
    o = { desc = "Open selected match in a split", run = function() self:open_selected(active) end },
    R = { desc = "Return to the search origin", run = function() self:return_to_origin(active) end },
    a = { desc = "Load the next result page", run = function() self:load_more(active) end },
    z = { desc = "Load the previous result page", run = function() self:load_previous(active) end },
    l = { desc = "Toggle literal/regex", run = function() self:toggle_flag(active, "fixed") end },
    c = { desc = "Cycle case mode", run = function() self:cycle_case(active) end },
    w = { desc = "Toggle whole-word matches", run = function() self:toggle_flag(active, "word") end },
    H = { desc = "Toggle hidden files", run = function() self:toggle_policy(active, "hidden") end },
    I = { desc = "Toggle ignored files", run = function() self:toggle_policy(active, "ignored") end },
    s = { desc = "Set folder scope", run = function() self:_prompt_folder(active) end },
    F = { desc = "Search current file", run = function() self:_current_file_scope(active) end },
    B = { desc = "Search open buffers", run = function() self:set_scope(active, { kind = "open_buffers", explicit = true }) end },
    u = { desc = "Resume a retained search", run = function() self:prompt_resume(active) end },
    m = { desc = "Mark/unmark selected match for replacement", run = function() return self:toggle_replacement_mark(active) end },
    X = { desc = "Review literal replacement for marked/selected matches", run = function() return self:replace_selected(active) end },
    ["+"] = { desc = "Add include glob", run = function() self:_prompt_glob(active, "include") end },
    ["-"] = { desc = "Add exclude glob", run = function() self:_prompt_glob(active, "exclude") end },
    P = { desc = "Open action palette", run = function() if self.palette then self.palette:open({ context = self:_action_context({ workspace = active.investigation.workspace, search = active }) }) end end },
    h = nil,
  }
end

function Controller:toggle_replacement_mark(active)
  if not active or active.closed or not active.selected_id then return false end
  local item = self:_entry_for_item(active, active.selected_id)
  if not item or item.kind ~= "match" then return false end
  active.marked_matches = active.marked_matches or {}
  active.marked_matches[item.id] = not active.marked_matches[item.id] and true or nil
  return self:_render(active)
end

function Controller:_replacement_available(active)
  if not active or active.closed then return false, "open a Search view first" end
  if not active.flags.fixed then return false, "literal search is required; regex replacement is unavailable" end
  if active.query == "" then return false, "enter a non-empty literal search first" end
  local entry = active.investigation.current
  if not entry then return false, "run a literal search first" end
  if not vim.deep_equal(entry.options, { query = active.query, flags = active.flags, scope = active.scope }) then
    return false, "current results do not match the visible literal query; wait for the rerun to finish"
  end
  local summary = self.store:summary(entry.result_id)
  if not summary or summary.status ~= "complete" then return false, "wait for a complete search before replacing matches" end
  local marked_count = 0
  for _ in pairs(active.marked_matches or {}) do marked_count = marked_count + 1 end
  local ids = marked_count > 0 and active.marked_matches or { [active.selected_id or ""] = true }
  for id, enabled in pairs(ids) do
    if enabled and id ~= "" then
      local item = self.store:item(entry.result_id, id)
      if item and item.kind == "match" and item.payload and item.payload.provider_id == "rg" then return true end
    end
  end
  return false, "select or mark at least one ripgrep match"
end

function Controller:_replacement_service()
  if self.replacement then return self.replacement end
  local service, err = require("workbench.services.replacement").new(self.replacement_options)
  if not service then return nil, { code = "replacement_unavailable", message = tostring(err) } end
  self.replacement = service
  return service
end

function Controller:_replacement_selection(active)
  local available, reason = self:_replacement_available(active)
  if not available then return nil, { code = "replacement_unavailable", message = reason } end
  local entry = active.investigation.current
  local ids = {}
  for id, marked in pairs(active.marked_matches or {}) do if marked then ids[#ids + 1] = id end end
  if #ids == 0 then ids[1] = active.selected_id end
  table.sort(ids)
  local selected = {}
  for _, id in ipairs(ids) do
    local item = self.store:item(entry.result_id, id)
    if not item then return nil, { code = "selection_unavailable", message = "a marked match is no longer retained; clear marks and select a current result" } end
    local source = item.payload and item.payload.source_snapshot
    local snapshot = source and entry.source_snapshots and entry.source_snapshots[source.id] or nil
    selected[#selected + 1] = { item = item, source_snapshot = snapshot }
  end
  return selected, nil, entry
end

function Controller:_replacement_plan(active, replacement)
  local selected, selection_error, entry = self:_replacement_selection(active)
  if not selected then return nil, selection_error end
  local service, service_error = self:_replacement_service()
  if not service then return nil, service_error end
  local plan, prepare_error = service:prepare(active.investigation.workspace, selected, replacement, { literal = true })
  if not plan then return nil, prepare_error end
  active.pending_replacement = plan
  active.pending_replacement_entry = entry
  return plan, nil, service, entry
end

function Controller:replace_selected(active, replacement)
  local available, reason = self:_replacement_available(active)
  if not available then
    local unavailable = { code = "replacement_unavailable", message = reason }
    if active and not active.closed then
      active.notice = { id = "replacement-unavailable", label = "Replacement unavailable", detail = reason }
      self:_render(active)
    end
    return nil, unavailable
  end
  local function review(value)
    if value == nil or active.closed or not active.scope_owner.alive then return false end
    local plan, plan_error, service, entry = self:_replacement_plan(active, value)
    if not plan then
      active.notice = { id = "replacement-error", label = "Could not prepare replacement", detail = plan_error and plan_error.message or tostring(plan_error) }
      self:_render(active)
      return nil, plan_error
    end
    local labels = { "Apply this exact replacement", "Cancel" }
    local selected, select_error = pcall(self.select, labels, {
      prompt = "Review exact literal replacement; multi-file apply is sequential, not atomic:\n" .. plan.review
        .. "\n\nSelect the first item to apply; any other choice cancels.",
      format_item = function(item) return item end,
    }, function(choice)
      if active.pending_replacement ~= plan then service:cancel(plan); return end
      active.pending_replacement, active.pending_replacement_entry = nil, nil
      if active.closed or not active.scope_owner.alive or active.investigation.current ~= entry then
        service:cancel(plan)
        return
      end
      if choice ~= labels[1] then service:cancel(plan); self:_render(active); return end
      local reviewed, review_error = service:review(plan)
      if not reviewed then
        active.notice = { id = "replacement-stale", label = "Replacement review expired", detail = review_error and review_error.message or "prepare the diff again" }
        self:_render(active)
        return
      end
      local okay, result = service:apply(plan)
      active.last_replacement = plan
      if okay then active.last_replacement_error = nil else active.last_replacement_error = result end
      active.marked_matches = {}
      if okay then
        active.notice = { id = "replacement-applied", label = "Replacement applied", detail = tostring(plan.matched_count) .. " selected match(es); rerun search to refresh results" }
      else
        local report = plan.recovery or {}
        active.notice = {
          id = "replacement-failed",
          label = plan.state == "partial" and "Replacement partially applied" or "Replacement not applied",
          detail = string.format("%d resource(s) applied, %d unapplied · %s", #(report.applied or {}), #(report.unapplied or {}), result and result.message or "inspect the recovery ledger"),
        }
      end
      self:_render(active)
    end)
    if not selected then
      if active.pending_replacement == plan then active.pending_replacement, active.pending_replacement_entry = nil, nil end
      service:cancel(plan)
      active.notice = { id = "replacement-review-error", label = "Replacement review UI failed", detail = tostring(select_error) }
      self:_render(active)
      return nil, { code = "review_ui_failed", message = tostring(select_error) }
    end
    if active.closed or not active.scope_owner.alive then
      if active.pending_replacement == plan then active.pending_replacement, active.pending_replacement_entry = nil, nil end
      service:cancel(plan)
    end
    return plan
  end
  if type(replacement) == "string" then return review(replacement) end
  self.input({ prompt = "Literal replacement (single line; regex expansion unavailable): " }, function(value)
    if value ~= nil and not active.closed and active.scope_owner.alive then review(value) end
  end)
  return true
end

function Controller:_phase_for(entry)
  if not entry then return "Ready" end
  local summary = self.store:summary(entry.result_id)
  if not summary then return "History unavailable" end
  if summary.status == "running" then return "Searching" end
  if summary.status == "complete" then return "Complete" end
  if summary.status == "partial" then return "Partial" end
  if summary.status == "cancelled" then return "Cancelled" end
  return "Error"
end

function Controller:_message(active, label, detail, id)
  active.notice = label and { id = id or "state", label = label, detail = detail } or nil
  return self:_render(active)
end

function Controller:_model(active)
  local investigation = active.investigation
  local entry = investigation.current
  local matching = entry and vim.deep_equal(entry.options, { query = active.query, flags = active.flags, scope = active.scope })
  local page, summary
  if matching and entry.result_id then
    summary = self.store:summary(entry.result_id)
    if summary then page = self.store:page(entry.result_id, active.offset or 0, active.visible_limit) end
  end
  local stale = entry and not matching and entry.result_id and self.store:summary(entry.result_id)
  if stale then
    summary = stale
    page = self.store:page(entry.result_id, active.offset or 0, active.visible_limit)
  end
  active.total = summary and summary.item_count or 0
  active.completeness = summary and summary.completeness or nil
  local notice = active.notice
  if not notice and stale then
    notice = { id = "previous", label = "Previous query results (not current)", detail = "Press / to continue or r to rerun the visible query" }
  elseif not notice and not entry and active.query == "" then
    notice = { id = "ready", label = "Enter / to search the selected scope", detail = "Literal search; disk contents only" }
  elseif not notice and active.query == "" then
    notice = { id = "empty", label = "Empty query · no repository scan was started", detail = "Type a query with /" }
  elseif not notice and summary and summary.status == "error" then
    notice = { id = "error", label = "Search failed", detail = summary.error and summary.error.message or "search provider failed" }
  elseif not notice and summary and summary.status == "partial" then
    notice = { id = "partial", label = "Partial results", detail = summary.error and summary.error.message or "provider reached a configured cap" }
  elseif not notice and summary and summary.status == "cancelled" then
    notice = { id = "cancelled", label = "Search cancelled; received results are retained", detail = "Press r to rerun" }
  elseif not notice and summary and summary.status == "complete" and summary.item_count == 0 then
    notice = { id = "empty-results", label = "No matches", detail = "Search completed successfully" }
  elseif not notice and summary and summary.status == "running" and summary.item_count == 0 then
    notice = { id = "running", label = "Searching…", detail = "Results stream in while this panel remains interactive" }
  elseif not notice and active.phase == "Debouncing" and not matching then
    notice = { id = "debounce", label = "Waiting for query debounce", detail = "Previous results are labelled as stale" }
  end
  local items, expanded, projection
  local projected_notice = notice
  if page and #page.items > 0 and notice then projected_notice = nil end
  items, expanded, projection = UiSearch.project(page or { items = {} }, {
    notice = projected_notice,
    marked = active.marked_matches,
    root_path = investigation.workspace.roots[1].path,
  })
  active.projection = projection
  active.expanded = active.expanded or {}
  for id in pairs(expanded) do if active.expanded[id] == nil then active.expanded[id] = true end end
  local state = {
    workspace = investigation.workspace,
    scope = active.scope,
    query = active.query,
    flags = active.flags,
    phase = active.phase,
    total = active.total,
    completeness = active.completeness,
    visible_limit = active.visible_limit,
    offset = projection and projection.offset or 0,
    visible_matches = projection and projection.visible_matches or 0,
    modified_count = active.modified_count,
    snapshot_count = active.snapshot_count,
    snapshot_skipped_count = active.snapshot_skipped_count,
    snapshot_stale_count = 0,
    policy_override = active.scope.kind == "file" and investigation.workspace.policy.ignored == "exclude",
  }
  if entry and entry.source_snapshots then
    for _, snapshot in pairs(entry.source_snapshots) do
      if not buffer_snapshots().is_current(snapshot) then state.snapshot_stale_count = state.snapshot_stale_count + 1 end
    end
  end
  local header = UiSearch.header(state)
  if page and #page.items > 0 and notice then
    local detail = notice.detail and notice.detail ~= "" and (" · " .. notice.detail) or ""
    header[4] = UiSearch.compact((header[4] or "") .. " · " .. tostring(notice.label or "Search state") .. detail, 240)
  end
  return { status = "ready", title = UiSearch.title(state), header = header, items = items }, expanded
end

function Controller:_render(active, immediate)
  if self.disposed or active.closed or not active.scope_owner.alive or not active.view or active.view.closed then return false end
  if immediate and active.render_ticket and active.render_ticket.active then
    active.render_ticket:cancel()
    active.render_ticket = nil
  elseif active.render_ticket and active.render_ticket.active then
    return true
  end
  local function render()
    active.render_ticket = nil
    if self.disposed or active.closed or not active.scope_owner.alive or not active.view or active.view.closed then return false end
    local model, expanded = self:_model(active)
    for id in pairs(expanded) do
      if active.expanded[id] == nil then active.expanded[id] = true end
      active.view.expanded[id] = active.expanded[id] ~= false
    end
    if active.selected_id then active.view.selected_id = active.selected_id end
    active.view:update(model)
    if not active.selected_id or not active.view.row_index[active.selected_id] then
      active.selected_id = nil
      for _, row in ipairs(active.view.rows) do
        if row.kind == "match" then active.selected_id = row.id; active.view.selected_id = row.id; break end
      end
      if active.selected_id then
        local entry = active.investigation.current
        if entry and entry.store_session then
          entry.store_session:select(active.selected_id)
          entry.view_state = entry.view_state or {}
          entry.view_state.selected_id = active.selected_id
        end
        self:preview_selected(active)
      end
    end
    return true
  end
  if immediate then return render() end
  local ticket = active.scope_owner:schedule(render)
  if ticket then active.render_ticket = ticket end
  return ticket ~= nil
end

function Controller:_entry_for_item(active, item_id)
  local entry = active.investigation.current
  if not entry or not entry.result_id then return nil end
  return self.store:item(entry.result_id, item_id), entry
end

function Controller:_select(active, id, row, committed)
  if active.closed or not id then return nil end
  if type(row) == "table" and row.kind == "file" then return true end
  local item, entry = self:_entry_for_item(active, id)
  if not item or not entry then return nil end
  if not self:_snapshot_is_current(active, entry, item) then return false end
  active.selected_id = id
  entry.store_session:select(id)
  entry.view_state = entry.view_state or {}
  entry.view_state.selected_id = id
  if committed then return self:open_selected(active) end
  return self:preview_selected(active)
end

function Controller:_snapshot_is_current(active, entry, item)
  local payload = item and item.payload
  local source = payload and payload.source_snapshot
  if not source then return true end
  local snapshot = entry and entry.source_snapshots and entry.source_snapshots[source.id]
  if snapshot and buffer_snapshots().is_current(snapshot) then return true end
  active.notice = {
    id = "stale-buffer-snapshot",
    label = "Result is from an older buffer snapshot",
    detail = "The source changed after capture; rerun Search before opening or replacing this match",
  }
  self:_render(active)
  return false
end

function Controller:_toggle_group(active, id, expanded)
  local entry = active.investigation.current
  if entry and entry.store_session then entry.store_session:set_expanded(id, expanded) end
  active.expanded = active.expanded or {}
  active.expanded[id] = expanded and true or false
  if entry then
    entry.view_state = entry.view_state or {}
    entry.view_state.expanded = copy(active.expanded)
  end
  return true
end

function Controller:set_workspace(snapshot, tab)
  local changed = false
  for _, investigation in pairs(self.investigations) do
    if investigation.tab == tab and investigation.workspace.id == snapshot.id
      and not vim.deep_equal(investigation.workspace, snapshot) then
      investigation.workspace = copy(snapshot)
      changed = true
    end
  end
  local active = self.active[tab]
  if changed and active and not active.closed and active.investigation.workspace.id == snapshot.id then
    self:set_query(active, active.query, true)
  end
  return changed
end

function Controller:_trim_history(investigation, limit)
  while #investigation.history > limit do
    local index = investigation.history[1] == investigation.current and 2 or 1
    local old = table.remove(investigation.history, index)
    if not old then break end
    if old.store_session then old.store_session:dispose() end
  end
end

function Controller:apply_settings()
  if self.disposed then return nil, { code = "disposed", message = "Search controller is disposed" } end
  for _, active in pairs(self.active) do
    if not active.closed and active.preview and self.get_preview_settings then
      local opts = self.get_preview_settings(active)
      local applied, err, changed = active.preview:configure(opts)
      if not applied then return nil, { code = "preview_config_failed", message = tostring(err) } end
      if changed and opts.enabled and active.tab == vim.api.nvim_get_current_tabpage() then self:preview_selected(active) end
    end
    if not active.closed and self.get_search_settings then
      local opts = self.get_search_settings(active)
      local previous = active.search_settings
      active.search_settings = opts
      if previous and (previous.max_results ~= opts.max_results
        or (active.timer_scope and previous.debounce_ms ~= opts.debounce_ms)) then
        self:set_query(active, active.query, false)
      end
    end
  end
  if self.get_history_limit then
    for _, investigation in pairs(self.investigations) do
      self:_trim_history(investigation, self.get_history_limit(investigation))
    end
  end
  return true
end

function Controller:preview_selected(active)
  if not active or not active.preview or active.preview.enabled == false or not self.navigation or not active.selected_id then return false end
  local item, entry = self:_entry_for_item(active, active.selected_id)
  if not item or not item.location or not entry then return false end
  if not self:_snapshot_is_current(active, entry, item) then return false end
  entry.store_session:preview(item.id)
  local restore_search_focus = active.view and active.view.window and vim.api.nvim_win_is_valid(active.view.window)
    and vim.api.nvim_get_current_win() == active.view.window
  local request, err = active.preview:preview(item.location, entry.navigation_id, function(result)
    if active.closed or not active.scope_owner.alive or active.investigation.current ~= entry then return end
    if type(result) == "table" and result.code then
      active.notice = { id = "preview-error", label = "Preview unavailable", detail = result.message or result.code }
      self:_render(active)
    end
  end)
  if restore_search_focus and active.view.window and vim.api.nvim_win_is_valid(active.view.window) then
    pcall(vim.api.nvim_set_current_win, active.view.window)
  end
  return request, err
end

function Controller:open_selected(active)
  if not active or active.closed or not self.navigation or not active.selected_id then return nil, { code = "selection_unavailable", message = "select a match first" } end
  local item, entry = self:_entry_for_item(active, active.selected_id)
  if not item or not item.location or not entry then return nil, { code = "selection_unavailable", message = "selected result is not a navigable match" } end
  if not self:_snapshot_is_current(active, entry, item) then return nil, { code = "stale_buffer_snapshot", message = "the source buffer changed after this result was captured" } end
  local snapshot = item.payload and item.payload.source_snapshot
  local opened, err
  if snapshot then
    opened, err = self.navigation:open_buffer(snapshot.bufnr, "split", active.origin, entry.navigation_id, item.location)
  else
    opened, err = self.navigation:open(item.location, "split", active.origin, entry.navigation_id)
  end
  if not opened then
    active.notice = { id = "open-error", label = "Could not open result", detail = type(err) == "table" and err.message or err }
    self:_render(active)
    return nil, err
  end
  if opened then active.navigation_target = opened.win end
  return opened
end

function Controller:return_to_origin(active)
  if not self.navigation then return nil, { code = "navigation_unavailable", message = "navigation service is unavailable" } end
  local entry = active and active.investigation.current
  if not entry then return nil, { code = "history_unavailable", message = "there is no active search investigation" } end
  local restored, err = self.navigation:return_to_origin(entry.navigation_id)
  if not restored then
    active.notice = { id = "return-error", label = "Could not return to search origin", detail = err.message or err.code }
    self:_render(active)
  end
  return restored, err
end

function Controller:load_more(active)
  if not active or active.closed then return false end
  local entry = active.investigation.current
  if not entry then return false end
  local page = self.store:page(entry.result_id, active.offset or 0, active.visible_limit)
  if not page or not page.next_offset then return false end
  if active.visible_limit < UiSearch.max_page_size then
    active.visible_limit = math.min(UiSearch.max_page_size, active.visible_limit + UiSearch.page_size)
  else
    active.offset = page.next_offset
    active.visible_limit = UiSearch.page_size
  end
  active.selected_id = nil
  entry.view_state = { offset = active.offset or 0, visible_limit = active.visible_limit, expanded = copy(active.expanded or {}) }
  active.notice = nil
  return self:_render(active)
end

function Controller:load_previous(active)
  if not active or active.closed or not active.offset or active.offset == 0 then return false end
  active.offset = math.max(0, active.offset - UiSearch.page_size)
  active.selected_id = nil
  local entry = active.investigation.current
  if entry then entry.view_state = { offset = active.offset, visible_limit = active.visible_limit, expanded = copy(active.expanded or {}) } end
  active.notice = nil
  return self:_render(active)
end

function Controller:_cancel_timer(active)
  if active.timer_scope then active.timer_scope:dispose(); active.timer_scope = nil end
end

function Controller:_cancel_request(active, reason)
  local scope = active.request_scope
  active.request_scope, active.request = nil, nil
  active.runner = nil
  if scope then
    if scope.alive and active.investigation.current then
      local entry = active.investigation.current
      local summary = entry.result_id and self.store:summary(entry.result_id)
      if summary and summary.status == "running" then
        self.store:finish(entry.result_id, "cancelled", "unknown", { code = "cancelled", message = reason or "search cancelled" })
      end
    end
    scope:dispose()
  end
end

function Controller:_ensure_entry(active)
  local investigation = active.investigation
  local history_limit = self.get_history_limit and self.get_history_limit(investigation) or M.history_limit
  -- Release an old reference before allocating at the store's bounded capacity.
  if self.store.limits then
    self:_trim_history(investigation, math.max(1, self.store.limits.max_sets - 1))
  end
  local options = { query = active.query, flags = copy(active.flags), scope = copy(active.scope) }
  investigation.generation = investigation.generation + 1
  self.next_id = self.next_id + 1
  local id = "rg-" .. self.next_id
  local query = { query = options.query, flags = options.flags, scope = options.scope, policy = copy(investigation.workspace.policy) }
  local created, create_err = self.store:create({
    id = id,
    provider_id = "rg",
    workspace_id = investigation.workspace.id,
    generation = investigation.generation,
    query = query,
    status = "running",
    completeness = "unknown",
    max_items = active.search_settings and active.search_settings.max_results,
  })
  if not created then return nil, { code = "result_store_full", message = tostring(create_err) } end
  local store_session, session_err = self.store:open_session(id, { id = id .. ":view", origin = { investigation = investigation.id } })
  if not store_session then return nil, { code = "result_session_full", message = tostring(session_err) } end
  local entry = {
    id = id,
    result_id = id,
    store_session = store_session,
    options = options,
    max_results = active.search_settings and active.search_settings.max_results,
    workspace_generation = investigation.workspace.generation,
    navigation_id = investigation.id .. ":" .. tostring(investigation.generation),
    status = "running",
    error = nil,
    source_snapshots = {},
    view_state = { offset = 0, visible_limit = UiSearch.page_size, expanded = {} },
  }
  if investigation.current and investigation.current.store_session then investigation.current.store_session:close() end
  investigation.history[#investigation.history + 1] = entry
  investigation.current = entry
  self:_trim_history(investigation, history_limit)
  active.selected_id = nil
  active.marked_matches = {}
  active.visible_limit = UiSearch.page_size
  active.offset = 0
    active.offset = 0
  return entry
end

function Controller:_terminal(active, entry, status, completeness, err)
  local done, finish_err = self.store:finish(entry.result_id, status, completeness, err)
  if not done then
    active.notice = { id = "store-error", label = "Could not retain search status", detail = tostring(finish_err) }
  else
    entry.status, entry.error = status, err
    active.phase = status == "complete" and "Complete" or status == "partial" and "Partial" or status == "cancelled" and "Cancelled" or "Error"
    active.notice = nil
  end
  if active.request_scope then active.request_scope:dispose(); active.request_scope = nil end
  active.request = nil
  active.runner = nil
  self:_render(active)
end

local function source_snapshot_record(snapshot)
  local token = vim.fn.sha256(snapshot.id)
  return token, {
    id = token,
    bufnr = snapshot.bufnr,
    path = snapshot.path,
    uri = snapshot.uri,
    changedtick = snapshot.changedtick,
    fileformat = snapshot.fileformat,
    endofline = snapshot.endofline,
    bomb = snapshot.bomb,
    fileencoding = snapshot.fileencoding,
    encoding = snapshot.encoding,
    content_hash = vim.fn.sha256(snapshot.content),
  }
end

local function remap_snapshot_items(items, staged, workspace, entry, runner)
  local Resources, Locations = resource_module(), location_module()
  local mapped = {}
  for _, original in ipairs(items or {}) do
    local temp_path = original.location and original.location.resource and original.location.resource.path
    local record = temp_path and staged.by_path[vim.fs.normalize(temp_path)]
    if record then
      local resource, resource_err = Resources.from_path(record.original_path, { workspace_id = workspace.id })
      if not resource then return nil, { code = "snapshot_resource_invalid", message = resource_err } end
      local location, location_err = Locations.new(resource, {
        range = original.location.range,
        encoding = original.location.encoding,
      })
      if not location then return nil, { code = "snapshot_location_invalid", message = location_err } end
      local item = copy(original)
      item.location = location
      local range = location.range and location.range.start or { line = 0, character = 0 }
      local payload = item.payload or {}
      payload.raw_path = record.original_path
      payload.source_snapshot = copy(record.source)
      item.payload = payload
      item.id = table.concat({ "rg-buffer", workspace.id, tostring(entry.generation), resource.uri,
        tostring(range.line + 1), tostring(range.character), tostring(payload.occurrence or 1) }, "\0")
      item.detail = resource.display_path .. ":" .. tostring(range.line + 1)
      runner.included[resource.uri] = true
      mapped[#mapped + 1] = item
    end
  end
  return mapped
end

function Controller:_start_search(active, generation)
  local BufferSnapshots = buffer_snapshots()
  local Resource = resource_module()
  if active.closed or not active.scope_owner.alive or generation ~= active.query_generation then return false end
  self:_cancel_timer(active)
  local query = active.query
  if query == "" then
    active.phase = "Empty"
    active.notice = { id = "empty", label = "Empty query · no repository scan was started", detail = "Type a query with /" }
    self:_render(active)
    return true
  end
  local workspace = active.investigation.workspace
  local capability = self:_capability(workspace)
  if capability.state ~= "ready" then
    active.phase = "Unavailable"
    active.notice = { id = "unavailable", label = "Search unavailable", detail = capability.reason or capability.state }
    self:_render(active)
    return false
  end
  local entry, entry_err = self:_ensure_entry(active)
  if not entry then
    active.phase = "Error"
    active.notice = { id = "history", label = "Search could not start", detail = entry_err.message }
    self:_render(active)
    return false
  end
  local open_buffers = active.scope.kind == "open_buffers"
  local direct_file = active.scope.kind == "file"
  active.modified_count = open_buffers and 0 or modified_count(workspace, active.scope)
  active.snapshot_count = nil
  active.snapshot_skipped_count = 0
  active.phase = "Searching"
  active.notice = nil
  self:_render(active)
  local child, child_err = active.scope_owner:child("request:" .. entry.id)
  if not child then
    self:_terminal(active, entry, "error", "unknown", { code = "scope_error", message = tostring(child_err) })
    return false
  end
  active.request_scope = child
  local result_generation = entry.options and active.investigation.generation or 1
  local captured, capture_err = BufferSnapshots.capture({
    workspace_root = workspace.roots[1].path,
    scope = active.scope,
    modified_only = not open_buffers,
  })
  if not captured then
    self:_terminal(active, entry, "error", "unknown", capture_err or { code = "snapshot_failed", message = "buffer snapshots could not be captured" })
    return false
  end
  active.snapshot_count = #captured.snapshots
  active.snapshot_skipped_count = captured.skipped_count

  local staged
  if #captured.snapshots > 0 then
    local stage_err
    staged, stage_err = BufferSnapshots.stage(captured.snapshots, {
      workspace_root = workspace.roots[1].path,
      mirror_ignore = not open_buffers,
    })
    if not staged then
      self:_terminal(active, entry, "error", "unknown", stage_err or { code = "snapshot_stage_failed", message = "buffer snapshots could not be staged" })
      return false
    end
    child:defer(function() staged:dispose() end, "buffer-snapshots:" .. entry.id, "resource")
    for _, record in ipairs(staged.files) do
      local token, source = source_snapshot_record(record.snapshot)
      record.source = source
      entry.source_snapshots[token] = {
        id = token,
        bufnr = source.bufnr,
        path = source.path,
        uri = source.uri,
        changedtick = source.changedtick,
        fileformat = source.fileformat,
        endofline = source.endofline,
        bomb = source.bomb,
        fileencoding = source.fileencoding,
      }
    end
  end

  local runner = {
    entry = entry,
    lanes = {},
    expected = (open_buffers and 0 or 1) + (staged and 1 or 0) + (staged and not open_buffers and not direct_file and 1 or 0),
    completed = 0,
    finalized = false,
    included = {},
    candidate_uris = {},
    skipped_uris = {},
    disk_items = {},
    errors = {},
  }
  for _, snapshot in ipairs(captured.snapshots) do runner.candidate_uris[snapshot.uri] = true end
  for _, uri in ipairs(captured.skipped_uris or {}) do
    runner.candidate_uris[uri] = true
    runner.skipped_uris[uri] = true
  end
  if direct_file then
    for _, snapshot in ipairs(captured.snapshots) do runner.included[snapshot.uri] = true end
  end
  active.runner = runner

  local function merge(items)
    if #items == 0 then return true end
    local merged, merge_err = self.store:merge(entry.result_id, items)
    if not merged then
      runner.finalized = true
      self:_terminal(active, entry, "error", "unknown", { code = "result_merge_failed", message = tostring(merge_err) })
      return false
    end
    if merged.status == "partial" then
      runner.finalized = true
      self:_terminal(active, entry, "partial", merged.completeness, merged.error)
      return false
    end
    self:_render(active)
    return true
  end

  local function finish_if_ready()
    if runner.finalized or runner.completed < runner.expected then return end
    runner.finalized = true
    local overlay = runner.lanes.overlay
    local eligibility = runner.lanes.eligible
    local filtered = {}
    for _, item in ipairs(runner.disk_items) do
      local uri = item.location and item.location.resource and item.location.resource.uri
      local superseded = runner.included[uri] or runner.skipped_uris[uri]
        or ((overlay and overlay.error or eligibility and eligibility.error) and runner.candidate_uris[uri])
      if not superseded then filtered[#filtered + 1] = item end
    end
    if not merge(filtered) then return end

    local partial, terminal_error, completeness = captured.skipped_count > 0, nil, "complete"
    local has_search_lanes, all_search_lanes_failed = false, true
    for _, lane in pairs(runner.lanes) do
      local is_search_lane = lane.id ~= "eligible"
      if is_search_lane then
        has_search_lanes = true
        if lane.status ~= "error" then all_search_lanes_failed = false end
      end
      if lane.status == "partial" then
        partial = true
        completeness = "truncated"
        terminal_error = terminal_error or { code = lane.error and lane.error.code or "result_limit", message = lane.error and lane.error.message or "Search reached a configured result cap" }
      elseif lane.status == "error" then
        partial = true
        completeness = "reported-only"
        terminal_error = terminal_error or lane.error or { code = "rg_failed", message = "ripgrep failed" }
      end
    end
    if captured.skipped_count > 0 then
      completeness = completeness == "complete" and "reported-only" or completeness
      terminal_error = terminal_error or { code = "snapshot_limit", message = string.format("%d named buffers exceeded snapshot limits", captured.skipped_count) }
    end
    local status = partial and "partial" or "complete"
    local summary = self.store:summary(entry.result_id)
    if has_search_lanes and all_search_lanes_failed and captured.skipped_count == 0 and summary and summary.item_count == 0 then
      status, completeness = "error", "unknown"
    end
    self:_terminal(active, entry, status, completeness, terminal_error)
  end

  local function lane_sink(lane, event)
    if active.closed or not active.scope_owner.alive or generation ~= active.query_generation
      or active.investigation.current ~= entry or event.generation ~= result_generation then return end
    if event.kind == "status" then
      if event.status == "running" then active.phase = "Searching" end
      self:_render(active)
    elseif event.kind == "file" and (lane.id == "overlay" or lane.id == "eligible") then
      local record = staged and staged.by_path[vim.fs.normalize(event.path)]
      if record then runner.included[record.snapshot.uri] = true end
    elseif event.kind == "batch" then
      if lane.id == "disk" and staged then
        for _, item in ipairs(event.items or {}) do runner.disk_items[#runner.disk_items + 1] = item end
      elseif lane.id == "disk" then
        merge(event.items or {})
      else
        local mapped, map_err = remap_snapshot_items(event.items, staged, workspace, entry, runner)
        if not mapped then
          runner.finalized = true
          self:_terminal(active, entry, "error", "unknown", map_err)
          return
        end
        if not merge(mapped) then return end
      end
    elseif event.kind == "done" then
      if not lane.complete then
        lane.complete = true
        lane.status = event.status == "partial" and "partial" or "complete"
        lane.error = event.status == "partial" and { code = event.limit_reason or "result_limit", message = "Search reached a configured result cap" } or nil
        runner.completed = runner.completed + 1
        finish_if_ready()
      end
    elseif event.kind == "error" and not lane.complete then
      lane.complete = true
      lane.status = event.status == "partial" and "partial" or "error"
      lane.error = event.error or { code = "rg_failed", message = "ripgrep failed" }
      runner.errors[#runner.errors + 1] = lane.error
      runner.completed = runner.completed + 1
      finish_if_ready()
    end
  end

  if runner.expected == 0 then
    self:_terminal(active, entry, captured.skipped_count > 0 and "partial" or "complete",
      captured.skipped_count > 0 and "reported-only" or "complete",
      captured.skipped_count > 0 and { code = "snapshot_limit", message = "no open buffer could be captured within configured limits" } or nil)
    return true
  end

  local requests = {}
  local function start_lane(id, request)
    if id ~= "eligible" then request.max_items = active.search_settings and active.search_settings.max_results end
    local lane = { id = id, complete = false }
    runner.lanes[id] = lane
    local handle, start_err = self.provider:start(request, function(event) lane_sink(lane, event) end)
    if not handle then
      runner.finalized = true
      self:_terminal(active, entry, "error", "unknown", start_err or { code = "start_failed", message = "search provider could not start" })
      return false
    end
    requests[#requests + 1] = handle
    if child.alive then
      child:defer(function() handle:cancel("search view closed or query superseded") end,
        "request-handle:" .. entry.id .. ":" .. id, "process")
    else
      handle:cancel("search became stale before process ownership completed")
    end
    return true
  end

  if not open_buffers then
    if not start_lane("disk", {
      workspace = workspace,
      query = query,
      flags = copy(active.flags),
      scope = copy(active.scope),
      generation = result_generation,
      session_id = entry.id .. ":disk",
    }) then return false end
  end
  if staged then
    local overlay_id = workspace.id .. ":buffers:" .. entry.id
    local overlay_root, root_err = Resource.from_path(staged.root, { workspace_id = overlay_id })
    if not overlay_root then
      runner.finalized = true
      self:_terminal(active, entry, "error", "unknown", { code = "snapshot_root_invalid", message = root_err })
      return false
    end
    local overlay_workspace = copy(workspace)
    overlay_workspace.id = overlay_id
    overlay_workspace.roots = { overlay_root }
    overlay_workspace.scope = { kind = "all_roots", explicit = true }
    overlay_workspace.policy = copy(workspace.policy)
    if open_buffers then
      overlay_workspace.policy.hidden = "include"
      overlay_workspace.policy.ignored = "include"
      overlay_workspace.policy.include = {}
      overlay_workspace.policy.exclude = {}
    elseif direct_file then
      overlay_workspace.policy.hidden = "include"
      overlay_workspace.policy.ignored = "include"
      overlay_workspace.policy.include = {}
      overlay_workspace.policy.exclude = {}
    end
    if not open_buffers and not direct_file then
      local eligible_id = overlay_id .. ":eligible"
      local eligible_workspace = copy(overlay_workspace)
      eligible_workspace.id = eligible_id
      eligible_workspace.roots = { assert(Resource.from_path(staged.root, { workspace_id = eligible_id })) }
      local allowed_paths = {}
      for _, record in ipairs(staged.files) do allowed_paths[#allowed_paths + 1] = record.staged_path end
      if not start_lane("eligible", {
        workspace = eligible_workspace,
        query = query,
        flags = copy(active.flags),
        scope = { kind = "all_roots", explicit = true },
        generation = result_generation,
        session_id = entry.id .. ":eligible",
        enumerate_files = true,
        allowed_paths = allowed_paths,
      }) then return false end
    end
    if not start_lane("overlay", {
      workspace = overlay_workspace,
      query = query,
      flags = copy(active.flags),
      scope = { kind = "all_roots", explicit = true },
      generation = result_generation,
      session_id = entry.id .. ":overlay",
      emit_files = false,
    }) then return false end
  end
  if child.alive and active.scope_owner.alive and active.investigation.current == entry and generation == active.query_generation then
    active.request = {
      cancel = function(_, reason)
        if active.request_scope ~= child then return false end
        return child:dispose(reason or "search cancelled")
      end,
    }
  end
  return true
end

function Controller:set_query(active, query, immediate)
  if not active or active.closed then return nil, { code = "view_closed", message = "Search view is closed" } end
  if type(query) ~= "string" or query:find("\0", 1, true) then return nil, { code = "invalid_query", message = "query must be a string without NUL bytes" } end
  active.search_settings = self.get_search_settings and self.get_search_settings(active) or nil
  local debounce = active.search_settings and active.search_settings.debounce_ms or self.debounce
  active.query_generation = (active.query_generation or 0) + 1
  local generation = active.query_generation
  self:_cancel_timer(active)
  self:_cancel_request(active, "query changed")
  active.query = query
  active.notice = nil
  if query == "" then
    active.phase = "Empty"
    self:_render(active)
    return true
  end
  if immediate or debounce == 0 then
    active.phase = "Searching"
    return self:_start_search(active, generation)
  end
  active.phase = "Debouncing"
  local child, child_err = active.scope_owner:child("debounce:" .. generation)
  if not child then return nil, child_err end
  active.timer_scope = child
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  if not timer then child:dispose(); active.timer_scope = nil; return nil, { code = "timer_unavailable", message = "query debounce timer could not be allocated" } end
  child:defer(function() timer:stop(); timer:close() end, "search-debounce-timer", "timer")
  timer:start(debounce, 0, function()
    if not child.alive then return end
    active.scope_owner:schedule(function() self:_start_search(active, generation) end)
  end)
  self:_render(active)
  return true
end

function Controller:_prompt_query(active)
  local scope = active.scope.kind == "folder" and "folder"
    or active.scope.kind == "file" and "current file"
    or active.scope.kind == "open_buffers" and "open buffers"
    or "workspace"
  self.input({ prompt = "Search " .. scope .. ": ", default = active.query }, function(value)
    if value ~= nil and not active.closed and active.scope_owner.alive then self:set_query(active, value) end
  end)
end

function Controller:rerun(active)
  if not active or active.closed then return nil, { code = "view_closed", message = "Search view is closed" } end
  local query = active.query
  if query == "" and active.investigation.current then query = entry_query(active.investigation.current) end
  return self:set_query(active, query, true)
end

function Controller:cancel(active)
  if not active or active.closed then return false end
  active.query_generation = (active.query_generation or 0) + 1
  self:_cancel_timer(active)
  self:_cancel_request(active, "cancelled by user")
  active.phase = "Cancelled"
  active.notice = { id = "cancelled", label = "Search cancelled; received results are retained", detail = "Press r to rerun" }
  return self:_render(active)
end

function Controller:toggle_flag(active, flag)
  if not active or active.closed then return false end
  active.flags[flag] = not active.flags[flag]
  return self:set_query(active, active.query, true)
end

function Controller:cycle_case(active)
  if not active or active.closed then return false end
  active.flags.case = active.flags.case == "smart" and "sensitive" or active.flags.case == "sensitive" and "insensitive" or "smart"
  return self:set_query(active, active.query, true)
end

function Controller:_snapshot_with_policy(active, key, value)
  local old = active.investigation.workspace
  local fields = copy(old)
  fields.generation = fields.generation + 1
  fields.policy[key] = value
  local next_workspace, err
  if self.update_policy then next_workspace, err = self.update_policy(old, { [key] = value })
  else next_workspace, err = Workspace.new(fields) end
  if not next_workspace then return nil, { code = "policy_update_failed", message = tostring(err) } end
  active.investigation.workspace = copy(next_workspace)
  self:_capability(next_workspace)
  return next_workspace
end

function Controller:toggle_policy(active, key)
  if not active or active.closed then return false end
  if key ~= "hidden" and key ~= "ignored" then return nil, { code = "invalid_policy", message = "only hidden and ignored policy can be toggled" } end
  if key == "ignored" and active.scope.kind == "file" then
    self:_unavailable(active, "an explicitly targeted current file follows ripgrep direct-file semantics; ignored policy does not change it")
    return false
  end
  local current = active.investigation.workspace.policy[key] or "exclude"
  local _, err = self:_snapshot_with_policy(active, key, current == "include" and "exclude" or "include")
  if err then active.notice = { id = "policy-error", label = "Search policy could not be updated", detail = err.message }; self:_render(active); return nil, err end
  return self:set_query(active, active.query, true)
end

function Controller:set_scope(active, scope)
  if not active or active.closed then return false end
  local normalized, err = normalized_scope(scope, active.investigation.workspace)
  if not normalized then active.notice = { id = err.code, label = "Scope unavailable", detail = err.message }; self:_render(active); return nil, err end
  active.scope = normalized
  active.selected_id = nil
  return self:set_query(active, active.query, true)
end

function Controller:_prompt_folder(active)
  self.input({ prompt = "Search folder (absolute path): ", default = active.scope.kind == "folder" and active.scope.path or active.investigation.workspace.roots[1].path }, function(value)
    if value and not active.closed and active.scope_owner.alive then self:set_scope(active, { kind = "folder", path = value, explicit = true }) end
  end)
end

function Controller:_current_file_scope(active)
  local win = current_editor_window(active.tab)
  if not win then self:_unavailable(active, "no named editor file is active"); return false end
  local path = buffer_path(vim.api.nvim_win_get_buf(win))
  if not path then self:_unavailable(active, "current buffer has no native file path"); return false end
  return self:set_scope(active, { kind = "file", path = path, explicit = true })
end

function Controller:_unavailable(active, reason)
  if active then active.notice = { id = "unavailable", label = "Capability unavailable", detail = reason }; self:_render(active) end
  return nil, { code = "unavailable", message = reason }
end

function Controller:_prompt_glob(active, field)
  local existing = active.investigation.workspace.policy[field] or {}
  self.input({ prompt = (field == "include" and "Include" or "Exclude") .. " glob: " }, function(value)
    if not value or value == "" or active.closed or not active.scope_owner.alive then return end
    if active.scope.kind == "file" and field == "include" then
      self:_unavailable(active, "current-file search cannot safely combine with workspace include globs")
      return
    end
    local list = copy(existing)
    list[#list + 1] = value
    self:_set_glob_policy(active, field, list)
  end)
end

function Controller:_set_glob_policy(active, field, values)
  local workspace = active.investigation.workspace
  local fields = copy(workspace)
  fields.generation = fields.generation + 1
  fields.policy[field] = values
  local next_workspace, err
  if self.update_policy then next_workspace, err = self.update_policy(workspace, { [field] = values })
  else next_workspace, err = Workspace.new(fields) end
  if not next_workspace then self:_unavailable(active, tostring(err)); return nil end
  active.investigation.workspace = copy(next_workspace)
  return self:set_query(active, active.query, true)
end

function Controller:resume(active, index)
  if not active or active.closed then return nil, { code = "view_closed", message = "Search view is closed" } end
  local history = active.investigation.history
  local entry = type(index) == "number" and history[index] or nil
  if type(index) == "string" then for _, item in ipairs(history) do if item.id == index then entry = item; break end end end
  if not entry then return nil, { code = "history_unavailable", message = "search history entry is unavailable" } end
  self:_cancel_timer(active)
  self:_cancel_request(active, "resuming a different search")
  if active.investigation.current and active.investigation.current.store_session then active.investigation.current.store_session:close() end
  local resumed, err = self.store:resume(entry.store_session.id)
  if not resumed then return nil, { code = "history_unavailable", message = tostring(err) } end
  entry.store_session = resumed
  active.investigation.current = entry
  active.query = entry.options.query
  active.flags = copy(entry.options.flags)
  active.scope = copy(entry.options.scope)
  active.selected_id = resumed.selected_id
  active.view_state = entry.view_state or { offset = 0, visible_limit = UiSearch.page_size, expanded = {} }
  active.offset = active.view_state.offset or 0
  active.visible_limit = active.view_state.visible_limit or UiSearch.page_size
  active.expanded = copy(active.view_state.expanded or {})
  active.phase = "Resumed"
  active.notice = nil
  self:_render(active)
  return true
end

function Controller:prompt_resume(active)
  local choices, lookup = {}, {}
  for index = #active.investigation.history, 1, -1 do
    local entry = active.investigation.history[index]
    local summary = self.store:summary(entry.result_id)
    choices[#choices + 1] = string.format("%s · %d matches · %s", entry.options.query, summary and summary.item_count or 0, self:_phase_for(entry))
    lookup[#choices] = entry
  end
  self.select(choices, { prompt = "Resume search:" }, function(_, index)
    local entry = index and lookup[index]
    if entry and not active.closed and active.scope_owner.alive then self:resume(active, entry.id) end
  end)
end

function Controller:status()
  local active = {}
  for tab, session in pairs(self.active) do
    if not session.closed then
      active[#active + 1] = {
        tab = tab,
        query = session.query,
        phase = session.phase,
        request_active = session.request ~= nil,
        generation = session.query_generation or 0,
        resources = session.scope_owner:inventory(),
        view = session.view and not session.view.closed,
      }
    end
  end
  table.sort(active, function(a, b) return a.tab < b.tab end)
  local investigations = 0
  for _ in pairs(self.investigations) do investigations = investigations + 1 end
  return { disposed = self.disposed, active_views = #active, investigations = investigations, sessions = active, resources = self.scope:inventory() }
end

function Controller:_dispose_ui(active)
  if active.closed then return false end
  active.closed = true
  active.query_generation = (active.query_generation or 0) + 1
  self:_cancel_timer(active)
  self:_cancel_request(active, "search view closed")
  local current = active.investigation.current
  if active.pending_replacement and self.replacement then
    self.replacement:cancel(active.pending_replacement)
    active.pending_replacement, active.pending_replacement_entry = nil, nil
  end
  if current then
    current.view_state = current.view_state or {}
    current.view_state.offset = active.offset or 0
    current.view_state.visible_limit = active.visible_limit or UiSearch.page_size
    current.view_state.selected_id = active.selected_id or (active.view and active.view.selected_id)
    current.view_state.expanded = copy(active.expanded or (active.view and active.view.expanded) or {})
    if current.store_session then current.store_session:select(current.view_state.selected_id) end
  end
  if active.investigation.current and active.investigation.current.store_session then active.investigation.current.store_session:close() end
  if active.preview and not active.preview.disposed then active.preview:dispose() end
  if self.active[active.tab] == active then self.active[active.tab] = nil end
  active.view = nil
  if not vim.api.nvim_tabpage_is_valid(active.tab) then
    for _, entry in ipairs(active.investigation.history) do
      if entry.store_session then entry.store_session:dispose() end
    end
    self.investigations[active.investigation.key] = nil
  end
  return true
end

function Controller:dispose()
  if self.disposed then return false end
  self.disposed = true
  local tabs = {}
  for tab, active in pairs(self.active) do if not active.closed then tabs[#tabs + 1] = { tab = tab, active = active } end end
  for _, record in ipairs(tabs) do
    self.layout:close("workbench-search", record.tab)
    self:_dispose_ui(record.active)
  end
  for _, investigation in pairs(self.investigations) do
    for _, entry in ipairs(investigation.history) do if entry.store_session then entry.store_session:dispose() end end
  end
  self.investigations = {}
  if self.owns_palette and self.palette then self.palette:dispose() end
  self.scope:dispose()
  if self.owns_replacement and self.replacement then self.replacement:dispose(); self.replacement = nil end
  if self.owns_actions then self.actions = nil end
  return true
end

return M
