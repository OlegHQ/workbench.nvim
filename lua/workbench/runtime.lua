local Scope = require("workbench.core.scope")

local M = {}
local Runtime = {}
Runtime.__index = Runtime
local sidebar_views = { files = "files", outline = "outline", problems = "workbench-problems" }

local function error_value(code, message)
  return { code = code, message = tostring(message or code) }
end

local function module_new(name, opts)
  local ok, module = pcall(require, name)
  if not ok then return nil, error_value("dependency_unavailable", module) end
  local created, value, err = pcall(module.new, opts)
  if not created then return nil, error_value("composition_error", value) end
  if not value then return nil, error_value("composition_error", err or (name .. " could not be constructed")) end
  return value
end

local function setting(settings, path, context)
  local state, err = settings:get(path, context)
  if not state then return nil, err end
  return state.effective
end

local function editor_file(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then return nil end
  local current = vim.api.nvim_get_current_win()
  local windows = vim.api.nvim_tabpage_list_wins(tab)
  if vim.api.nvim_win_get_tabpage(current) == tab then
    for index, win in ipairs(windows) do
      if win == current then table.remove(windows, index); break end
    end
    table.insert(windows, 1, current)
  end
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) then
      local config = vim.api.nvim_win_get_config(win)
      local buffer = vim.api.nvim_win_get_buf(win)
      if config.relative == "" and vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == ""
        and not vim.b[buffer].workbench_preview then
        local name = vim.api.nvim_buf_get_name(buffer)
        if name ~= "" and name:sub(1, 1) == "/" then return name end
      end
    end
  end
end

local function path_directory(path)
  if not path then return vim.fn.getcwd() end
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if stat and stat.type == "directory" then return path end
  return vim.fs.dirname(path)
end

local function root_adapter()
  local uv = vim.uv or vim.loop
  local markers = { "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Makefile" }
  return {
    cwd = function() return vim.fn.getcwd() end,
    canonicalize = function(_, path)
      local canonical = uv.fs_realpath(path)
      if not canonical then return nil, "workspace root does not exist: " .. tostring(path) end
      local stat = uv.fs_stat(canonical)
      if not stat or stat.type ~= "directory" then return nil, "workspace root must be a directory: " .. tostring(path) end
      return canonical
    end,
    nearest_git_root = function(_, path)
      local base = path_directory(path)
      local matches = vim.fs.find(".git", { path = base, upward = true, limit = 1 })
      return matches[1] and vim.fs.dirname(matches[1]) or nil
    end,
    nearest_marker_root = function(_, path)
      local base = path_directory(path)
      local matches = vim.fs.find(markers, { path = base, upward = true, limit = 1 })
      return matches[1] and vim.fs.dirname(matches[1]) or nil
    end,
  }
end

function M.new(app)
  if type(app) ~= "table" or type(app.settings) ~= "table" then
    return nil, error_value("invalid_runtime_owner", "runtime requires the Workbench application settings owner")
  end
  return setmetatable({ app = app, disposed = false, bundle = nil, policy_overrides = {}, tab_workspaces = {} }, Runtime)
end

function Runtime:_dispose_bundle()
  local bundle = self.bundle
  self.bundle = nil
  if bundle then bundle.scope:dispose() end
end

function Runtime:_settings_context(tab, workspace)
  local bundle = self.bundle
  workspace = workspace or self.tab_workspaces[tab]
  local active = bundle and bundle.search and bundle.search.active[tab]
  if not workspace and active then workspace = active.investigation.workspace end
  if not workspace and bundle and bundle.files then
    for _, session in pairs(bundle.files.sessions) do
      if session.tab == tab then workspace = session.workspace; break end
    end
  end
  local layout_tab = bundle and bundle.layout.tabs[tab]
  return {
    workspace_id = workspace and workspace.id,
    session_id = tostring(tab),
    bufnr = active and active.origin and active.origin.buf or (layout_tab and layout_tab.return_buffer),
  }
end

function Runtime:_preview_settings(active)
  local context = self:_settings_context(active.tab, active.investigation.workspace)
  return {
    enabled = setting(self.app.settings, "preview.enabled", context),
    max_bytes = setting(self.app.settings, "preview.max_bytes", context),
  }
end

function Runtime:_search_settings(active)
  local context = self:_settings_context(active.tab, active.investigation.workspace)
  return {
    debounce_ms = setting(self.app.settings, "search.debounce_ms", context),
    max_results = setting(self.app.settings, "search.max_results", context),
  }
end

function Runtime:apply_settings()
  local bundle = self.bundle
  if self.disposed or not bundle then return true end
  bundle.layout.options.sidebar_width = setting(self.app.settings, "sidebar.width")
  bundle.layout.options.sidebar_position = setting(self.app.settings, "sidebar.position")
  local applied, err = bundle.layout:apply_settings()
  if not applied then return nil, err end
  for tab, snapshot in pairs(self.tab_workspaces) do
    local updated = self:_policy_snapshot(snapshot, tab)
    if updated ~= snapshot then
      self.tab_workspaces[tab] = updated
      bundle.files:set_workspace(updated, tab)
      bundle.search:set_workspace(updated, tab)
    end
  end
  local search_applied, search_error = bundle.search:apply_settings()
  if not search_applied then return nil, search_error end
  for tab in pairs(self.tab_workspaces) do
    local allowed = setting(self.app.settings, "sidebar.views", self:_settings_context(tab)) or {}
    for name, id in pairs(sidebar_views) do
      if not vim.tbl_contains(allowed, name) then bundle.layout:close(id, tab) end
    end
  end
  return bundle.files:apply_settings()
end

function Runtime:_sidebar_controller(name)
  local bundle = self.bundle
  if bundle[name] then return bundle[name] end
  local owner, owner_error = bundle.scope:child("sidebar:" .. name)
  if not owner then return nil, owner_error end
  local provider, err = module_new(name == "outline" and "workbench.providers.lsp" or "workbench.providers.diagnostics")
  if not provider then owner:dispose(); return nil, err end
  owner:defer(function() provider:dispose() end, name .. "-provider", "provider")
  local controller, controller_error = module_new(name == "outline" and "workbench.controllers.outline" or "workbench.controllers.problems", {
    layout = bundle.layout, provider = provider, navigation = bundle.navigation, actions = self.app.actions,
    register_open_action = false,
  })
  if not controller then owner:dispose(); return nil, controller_error end
  owner:defer(function() controller:dispose() end, name .. "-controller", "controller")
  bundle[name] = controller
  return controller
end

function Runtime:_bind_sidebar_navigation(view, name)
  if view.sidebar_navigation_bound then return end
  view.sidebar_navigation_bound = true
  local tab = vim.api.nvim_get_current_tabpage()
  for _, entry in ipairs({ { "]v", 1, "next" }, { "[v", -1, "previous" } }) do
    local key, direction = entry[1], entry[2]
    vim.keymap.set("n", key, function()
      if self.disposed or view.closed or not view.scope.alive or vim.api.nvim_get_current_tabpage() ~= tab then return end
      local allowed = setting(self.app.settings, "sidebar.views", self:_settings_context(tab)) or {}
      if #allowed < 2 then return end
      local index = 1
      for position, candidate in ipairs(allowed) do if candidate == name then index = position; break end end
      local next_name = allowed[((index - 1 + direction) % #allowed) + 1]
      local opened, err = self:open(next_name)
      if not opened and err then vim.notify(err.message, vim.log.levels.WARN, { title = "Workbench" }) end
    end, { buffer = view.buffer, silent = true, nowait = true, desc = "Workbench: " .. entry[3] .. " sidebar view" })
    view.scope:defer(function()
      if vim.api.nvim_buf_is_valid(view.buffer) then pcall(vim.keymap.del, "n", key, { buffer = view.buffer }) end
    end, "sidebar-cycle:" .. key, "mapping")
  end
end

function Runtime:_policy_snapshot(snapshot, tab)
  local context = self:_settings_context(tab, snapshot)
  local policy = vim.deepcopy(snapshot.policy)
  policy.hidden = setting(self.app.settings, "search.hidden", context) and "include" or "exclude"
  policy.ignored = setting(self.app.settings, "search.ignored", context) and "include" or "exclude"
  policy.symlinks = setting(self.app.settings, "search.follow_symlinks", context) and "all" or "never"
  for key, value in pairs(self.policy_overrides[snapshot.roots[1].path] or {}) do policy[key] = vim.deepcopy(value) end
  if vim.deep_equal(policy, snapshot.policy) then return snapshot end
  local updated = vim.deepcopy(snapshot)
  updated.policy = policy
  updated.generation = snapshot.generation + 1
  return updated
end

function Runtime:_update_policy(snapshot, changes, source)
  if self.disposed or not self.bundle or type(snapshot) ~= "table" or type(changes) ~= "table" then
    return nil, error_value("runtime_unavailable", "workspace policy cannot be updated before runtime activation")
  end
  local root = snapshot.roots and snapshot.roots[1] and snapshot.roots[1].path
  if not root then return nil, error_value("workspace_unavailable", "workspace root is unavailable") end
  local policy = vim.deepcopy(self.policy_overrides[root] or {})
  for key, value in pairs(changes) do
    if key == "include" or key == "exclude" then
      if type(value) ~= "table" or #value > self.bundle.rg.limits.max_globs then
        return nil, error_value("invalid_policy", "globs must be a bounded array")
      end
      for index, pattern in pairs(value) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value
          or type(pattern) ~= "string" or pattern == "" or pattern:find("\0", 1, true)
          or #pattern > self.bundle.rg.limits.max_glob_bytes then
          return nil, error_value("invalid_policy", "globs must be a dense array of bounded nonempty strings")
        end
      end
      for index = 1, #value do
        if value[index] == nil then return nil, error_value("invalid_policy", "globs must be a dense array") end
      end
    elseif key ~= "hidden" and key ~= "ignored" then
      return nil, error_value("invalid_policy", "unsupported workspace policy: " .. tostring(key))
    elseif value ~= "include" and value ~= "exclude" then
      return nil, error_value("invalid_policy", key .. " policy must be include or exclude")
    end
    policy[key] = vim.deepcopy(value)
  end
  self.policy_overrides[root] = policy
  local current_tab = vim.api.nvim_get_current_tabpage()
  local updated = self:_policy_snapshot(snapshot, current_tab)
  for tab, previous in pairs(self.tab_workspaces) do
    if previous.id == snapshot.id then
      local next_snapshot = self:_policy_snapshot(previous, tab)
      self.tab_workspaces[tab] = next_snapshot
      if source ~= "files" or tab ~= current_tab then self.bundle.files:set_workspace(next_snapshot, tab) end
      if source ~= "search" or tab ~= current_tab then self.bundle.search:set_workspace(next_snapshot, tab) end
      if tab == current_tab then updated = next_snapshot end
    end
  end
  return vim.deepcopy(updated)
end

function Runtime:_construct()
  if self.bundle then return self.bundle end
  if self.disposed then return nil, error_value("runtime_disposed", "workbench runtime has been disposed") end

  local bundle = { scope = Scope.new("workbench-runtime") }
  local function own(value, label)
    local handle, err = bundle.scope:defer(function()
      if type(value.dispose) == "function" then value:dispose() end
    end, label, "runtime")
    if not handle then return nil, err end
    return value
  end
  local function fail(err)
    bundle.scope:dispose()
    return nil, type(err) == "table" and err or error_value("composition_error", err)
  end

  local workspace_module_ok, Workspace = pcall(require, "workbench.services.workspace")
  if not workspace_module_ok then return fail(error_value("dependency_unavailable", Workspace)) end
  local workspace, workspace_error = Workspace.new({
    root_service = root_adapter(),
    ignore_service = { snapshot = function(_, root)
      local root_path = root.path
      local override = self.policy_overrides[root_path]
      local hidden = setting(self.app.settings, "search.hidden")
      local ignored = setting(self.app.settings, "search.ignored")
      local symlinks = setting(self.app.settings, "search.follow_symlinks")
      return {
        hidden = override and override.hidden or (hidden and "include" or "exclude"),
        ignored = override and override.ignored or (ignored and "include" or "exclude"),
        symlinks = symlinks and "all" or "never",
        include = {},
        exclude = {},
      }
    end },
  })
  if not workspace then return fail(workspace_error) end
  bundle.workspace = workspace

  local sidebar_width = setting(self.app.settings, "sidebar.width") or 32
  local layout, err = module_new("workbench.ui.layout", {
    sidebar_width = sidebar_width,
    sidebar_position = setting(self.app.settings, "sidebar.position"),
    get_sidebar_settings = function(tab)
      local context = self:_settings_context(tab)
      return {
        width = setting(self.app.settings, "sidebar.width", context),
        position = setting(self.app.settings, "sidebar.position", context),
      }
    end,
  })
  if not layout then return fail(err) end
  bundle.layout = own(layout, "layout")
  if not bundle.layout then return fail("could not register layout ownership") end

  local filesystem, filesystem_error = module_new("workbench.providers.filesystem")
  if not filesystem then return fail(filesystem_error) end
  bundle.filesystem = own(filesystem, "filesystem-provider")
  if not bundle.filesystem then return fail("could not register filesystem provider ownership") end

  local rg, rg_error = module_new("workbench.providers.rg")
  if not rg then return fail(rg_error) end
  bundle.rg = own(rg, "ripgrep-provider")
  if not bundle.rg then return fail("could not register ripgrep provider ownership") end

  local store, store_error = module_new("workbench.services.results")
  if not store then return fail(store_error) end
  bundle.store = own(store, "result-store")
  if not bundle.store then return fail("could not register result-store ownership") end

  local navigation, navigation_error = module_new("workbench.services.navigation")
  if not navigation then return fail(navigation_error) end
  bundle.navigation = own(navigation, "navigation")
  if not bundle.navigation then return fail("could not register navigation ownership") end

  local files_module_ok, Files = pcall(require, "workbench.controllers.files")
  if not files_module_ok then return fail(error_value("dependency_unavailable", Files)) end
  local files, files_new_error = Files.new({
    layout = bundle.layout,
    provider = bundle.filesystem,
    get_follow_active_file = function(session)
      return setting(self.app.settings, "sidebar.follow_active_file", self:_settings_context(session.tab, session.workspace))
    end,
    update_policy = function(snapshot, changes) return self:_update_policy(snapshot, changes, "files") end,
    on_search = function(snapshot, path)
      return self:open("search", { workspace = snapshot, scope = { kind = "folder", path = path } })
    end,
  })
  if not files then return fail(error_value("composition_error", files_new_error)) end
  bundle.files = own(files, "files-controller")
  if not bundle.files then return fail("could not register Files controller ownership") end

  local search_module_ok, Search = pcall(require, "workbench.controllers.search")
  if not search_module_ok then return fail(error_value("dependency_unavailable", Search)) end
  local debounce_ms = setting(self.app.settings, "search.debounce_ms") or 80
  local search, search_new_error = Search.new({
    layout = bundle.layout,
    provider = bundle.rg,
    store = bundle.store,
    navigation = bundle.navigation,
    actions = self.app.actions,
    get_workspace = function()
      local snapshot = self.tab_workspaces[vim.api.nvim_get_current_tabpage()]
      return snapshot and vim.deepcopy(snapshot) or nil
    end,
    update_policy = function(snapshot, changes) return self:_update_policy(snapshot, changes, "search") end,
    debounce_ms = debounce_ms,
    get_preview_settings = function(active) return self:_preview_settings(active) end,
    get_search_settings = function(active) return self:_search_settings(active) end,
    get_history_limit = function(investigation)
      return setting(self.app.settings, "session.max_results_history", { session_id = tostring(investigation.tab) })
    end,
  })
  if not search then return fail(error_value("composition_error", search_new_error)) end
  bundle.search = own(search, "search-controller")
  if not bundle.search then return fail("could not register Search controller ownership") end

  local action, action_error = self.app.actions:register({
    id = "problems.open", title = "Open reported Problems", category = "Workspace", scope = "workspace",
    available = function(context)
      if type(context.workspace) ~= "table" then
        return { enabled = false, code = "no_workspace", reason = "no workbench workspace is active" }
      end
      local allowed = setting(self.app.settings, "sidebar.views",
        self:_settings_context(vim.api.nvim_get_current_tabpage(), context.workspace)) or {}
      if not vim.tbl_contains(allowed, "problems") then
        return { enabled = false, code = "view_disabled", reason = "Problems is not enabled in sidebar.views" }
      end
      return { enabled = true }
    end,
    run = function(context) return self:open("problems", { workspace = context.workspace }) end,
  }, { scope = bundle.scope })
  if not action then return fail(action_error) end

  local group_ok, group = pcall(vim.api.nvim_create_augroup, "WorkbenchRuntime" .. tostring(self), { clear = true })
  if not group_ok then return fail(error_value("runtime_lifecycle_failed", group)) end
  local _, group_error = bundle.scope:defer(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    self.tab_workspaces = {}
  end, "runtime-tab-workspaces", "autocmd")
  if group_error then return fail(group_error) end
  local autocmd_ok, autocmd_error = pcall(vim.api.nvim_create_autocmd, "TabClosed", {
    group = group,
    callback = function()
      if next(self.tab_workspaces) == nil then return end
      bundle.scope:schedule(function()
        local removed, retained = {}, {}
        for tab, snapshot in pairs(self.tab_workspaces) do
          if vim.api.nvim_tabpage_is_valid(tab) then retained[snapshot.id] = true
          else
            removed[snapshot.id] = snapshot
            self.tab_workspaces[tab] = nil
            if bundle.outline then bundle.outline:forget_tab(tab) end
          end
        end
        for id, snapshot in pairs(removed) do
          if not retained[id] then
            workspace:remove(id)
            self.policy_overrides[snapshot.roots[1].path] = nil
          end
        end
      end)
    end,
  })
  if not autocmd_ok then return fail(error_value("runtime_lifecycle_failed", autocmd_error)) end
  self.bundle = bundle
  return bundle
end

function Runtime:_workspace(bundle, opts, view_id)
  opts = opts or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local previous = self.tab_workspaces[tab]
  local prepared_view
  local function accept(candidate)
    if sidebar_views[view_id] then
      local allowed = setting(self.app.settings, "sidebar.views", self:_settings_context(tab, candidate)) or {}
      if not vim.tbl_contains(allowed, view_id) then
        return nil, error_value("view_disabled", view_id .. " is not enabled in sidebar.views")
      end
      local controller, controller_error = self:_sidebar_controller(view_id)
      if not controller then return nil, controller_error end
      local view, err
      local prepared = self:_policy_snapshot(candidate, tab)
      if view_id == "outline" then
        view, err = controller:open({ workspace = prepared, focus = opts.focus ~= false })
      else
        view, err = controller:open(prepared, { focus = opts.focus ~= false })
      end
      if not view then return nil, err end
      prepared_view = view
    elseif view_id == "search" then
      local view, err = bundle.search:open({
        workspace = self:_policy_snapshot(candidate, tab), scope = opts.scope,
        query = opts.query, focus = opts.focus ~= false,
      })
      if not view then return nil, err end
      prepared_view = view
    end
    return true
  end
  if opts.workspace == nil and opts.root == nil and previous then
    local accepted, err = accept(previous)
    if not accepted then return nil, err end
    return vim.deepcopy(previous), nil, prepared_view
  end
  local snapshot, err
  if opts.workspace ~= nil then
    snapshot, err = require("workbench.core.workspace").new(opts.workspace)
    if snapshot and #snapshot.roots ~= 1 then return nil, error_value("multi_root_unsupported", "runtime requires one workspace root") end
    if snapshot then
      local accepted, accept_error = accept(snapshot)
      if not accepted then return nil, accept_error end
    end
  else
    local initial_file = editor_file(tab)
    local root_opts = initial_file and { initial_file = initial_file } or {}
    if opts.root ~= nil then root_opts = { explicit_root = opts.root } end
    snapshot, err = bundle.workspace:open(root_opts, accept)
  end
  if not snapshot then
    return nil, type(err) == "table" and err or error_value("workspace_unavailable", err)
  end
  snapshot = self:_policy_snapshot(snapshot, tab)
  self.tab_workspaces[tab] = vim.deepcopy(snapshot)
  if previous and not vim.deep_equal(previous, snapshot) then
    if view_id ~= "search" then bundle.layout:close("workbench-search", tab) end
    if view_id ~= "outline" then bundle.layout:close("outline", tab) end
    if view_id ~= "problems" then bundle.layout:close("workbench-problems", tab) end
    bundle.files:set_workspace(snapshot, tab)
  end
  if previous and previous.id ~= snapshot.id then
    local retained = false
    for _, other in pairs(self.tab_workspaces) do if other.id == previous.id then retained = true; break end end
    if not retained then
      bundle.workspace:remove(previous.id)
      self.policy_overrides[previous.roots[1].path] = nil
    end
  end
  return vim.deepcopy(snapshot), nil, prepared_view
end

function Runtime:open(view_id, opts)
  if self.disposed then return nil, error_value("runtime_disposed", "workbench runtime has been disposed") end
  if not sidebar_views[view_id] and view_id ~= "search" then
    return nil, error_value("unknown_view", "supported views are files, outline, problems and search")
  end
  opts = opts or {}
  if type(opts) ~= "table" then return nil, error_value("invalid_options", "view options must be a table") end
  for key in pairs(opts) do
    if key ~= "root" and key ~= "workspace" and key ~= "scope" and key ~= "query" and key ~= "focus" then
      return nil, error_value("invalid_options", "unsupported view option: " .. tostring(key))
    end
  end
  if opts.root ~= nil and opts.workspace ~= nil then return nil, error_value("invalid_options", "supply either root or workspace") end
  if opts.focus ~= nil and type(opts.focus) ~= "boolean" then return nil, error_value("invalid_options", "focus must be boolean") end
  if opts.query ~= nil and (type(opts.query) ~= "string" or opts.query:find("\0", 1, true)) then
    return nil, error_value("invalid_query", "query must be a string without NUL bytes")
  end
  local bundle, runtime_error = self:_construct()
  if not bundle then return nil, runtime_error end
  local snapshot, workspace_error, prepared_view = self:_workspace(bundle, opts, view_id)
  if not snapshot then return nil, workspace_error end
  if sidebar_views[view_id] then
    local tab = vim.api.nvim_get_current_tabpage()
    local controller = bundle[view_id]
    local view, err = prepared_view
    if not view then
      if view_id == "outline" then view, err = controller:open({ workspace = snapshot, focus = opts.focus ~= false })
      else view, err = controller:open(snapshot, { focus = opts.focus ~= false }) end
    end
    if not view then return nil, err end
    self:_bind_sidebar_navigation(view, view_id)
    for name, id in pairs(sidebar_views) do if name ~= view_id then bundle.layout:close(id, tab) end end
    return view
  end
  return prepared_view
end

function Runtime:close(view_id)
  if self.disposed then return false end
  if view_id ~= nil and not sidebar_views[view_id] and view_id ~= "search" then
    return nil, error_value("unknown_view", "supported views are files, outline, problems and search")
  end
  local bundle = self.bundle
  if not bundle then return false end
  local tab = vim.api.nvim_get_current_tabpage()
  local closed = false
  for name, id in pairs(sidebar_views) do
    if view_id == nil or view_id == name then closed = bundle.layout:close(id, tab) or closed end
  end
  if view_id == nil or view_id == "search" then closed = bundle.layout:close("workbench-search", tab) or closed end
  return closed
end

function Runtime:status()
  local bundle = self.bundle
  return {
    disposed = self.disposed,
    initialized = bundle ~= nil,
    resources = bundle and bundle.scope:inventory() or { name = "workbench-runtime", alive = false, resources = {}, resource_count = 0, pending_callbacks = 0 },
    layout = bundle and bundle.layout:status() or nil,
    files = bundle and bundle.files:status() or nil,
    search = bundle and bundle.search:status() or nil,
    workspaces = vim.deepcopy(self.tab_workspaces),
  }
end

function Runtime:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  local bundle = self.bundle
  self.bundle = nil
  if bundle then self.disposal_report = bundle.scope:dispose() end
  self.policy_overrides = {}
  self.tab_workspaces = {}
  return self.disposal_report or { name = "workbench-runtime", alive = false, resources = {}, resource_count = 0, pending_callbacks = 0 }
end

return M
