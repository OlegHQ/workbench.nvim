local resource = require("workbench.core.resource")
local root_policy = require("workbench.core.root_policy")
local workspace = require("workbench.core.workspace")

local M = {}
local Service = {}
Service.__index = Service

local function policy_snapshot(ignore_service, root)
  local policy, err = ignore_service:snapshot(root)
  if type(policy) ~= "table" then return nil, err or "ignore policy snapshot is unavailable" end
  local result = {
    hidden = policy.hidden or "exclude",
    ignored = policy.ignored or "exclude",
    symlinks = policy.symlinks or "never",
    include = vim.deepcopy(policy.include or {}),
    exclude = vim.deepcopy(policy.exclude or {}),
  }
  if (result.hidden ~= "include" and result.hidden ~= "exclude")
    or (result.ignored ~= "include" and result.ignored ~= "exclude")
    or (result.symlinks ~= "never" and result.symlinks ~= "internal" and result.symlinks ~= "all") then
    return nil, "ignore service returned an unsupported workspace policy"
  end
  if type(result.include) ~= "table" or type(result.exclude) ~= "table" then
    return nil, "ignore policy include/exclude values must be arrays"
  end
  for _, list in ipairs({ result.include, result.exclude }) do
    local count, maximum = 0, 0
    for key, value in pairs(list) do
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "string" then
        return nil, "ignore policy include/exclude values must be string arrays"
      end
      count = count + 1
      maximum = math.max(maximum, key)
    end
    if count ~= maximum then return nil, "ignore policy include/exclude arrays cannot have holes" end
  end
  return result
end

local function normalize_scope(scope, root)
  if scope == nil then return { kind = "all_roots", explicit = true } end
  if type(scope) ~= "table" then return nil, "scope must be an explicit scope record" end
  if scope.kind == "all_roots" then return { kind = "all_roots", explicit = true } end
  if scope.kind ~= "folder" then return nil, "scope kind must be all_roots or folder" end
  local folder_path = scope.path or (type(scope.resource) == "table" and scope.resource.path)
  if type(folder_path) ~= "string" then return nil, "folder scope requires a native path" end
  local inside, err = root_policy.contains(root.path, folder_path)
  if not inside then return nil, err or "folder scope lies outside the selected workspace root" end
  local folder, resource_err = resource.from_path(folder_path)
  if not folder then return nil, resource_err end
  return { kind = "folder", explicit = true, resource = folder }
end

local function remember_root_alias(self, workspace_id, alias)
  local previous = self.root_aliases[workspace_id]
  if previous and previous ~= alias then
    local still_used = false
    for id, other_alias in pairs(self.root_aliases) do
      if id ~= workspace_id and other_alias == previous then still_used = true; break end
    end
    if not still_used then self.canonical_roots[previous] = nil end
  end
  self.root_aliases[workspace_id] = alias
end

function M.new(deps)
  deps = deps or {}
  if type(deps.root_service) ~= "table" then return nil, "an injected root_service is required" end
  if type(deps.ignore_service) ~= "table" or type(deps.ignore_service.snapshot) ~= "function" then
    return nil, "an injected ignore_service with snapshot(root) is required"
  end
  return setmetatable({
    root_service = deps.root_service,
    ignore_service = deps.ignore_service,
    generation = 0,
    workspaces = {},
    active_id = nil,
    last_options = {},
    canonical_roots = {},
    root_aliases = {},
  }, Service)
end

function Service:_open(opts, force_generation, accept)
  opts = opts or {}
  local pending_roots = setmetatable({}, { __index = self.canonical_roots })
  local root, root_err = root_policy.resolve(self.root_service, opts, pending_roots, force_generation)
  if not root then return nil, root_err end
  local root_resource, resource_err = resource.from_path(root.path, { display_path = root.alias })
  if not root_resource then return nil, resource_err end
  local scope, scope_err = normalize_scope(opts.scope, root)
  if not scope then return nil, scope_err end
  local policy, policy_err = policy_snapshot(self.ignore_service, root_resource)
  if not policy then return nil, policy_err end

  local roots = { root_resource }
  local id = workspace.id_for_roots(roots)
  local previous = self.workspaces[id]
  local generation = previous and previous.generation or self.generation + 1
  local candidate, workspace_err = workspace.new({
    id = id,
    generation = generation,
    roots = roots,
    active_root_uri = root_resource.uri,
    root_origin = root.origin,
    scope = scope,
    policy = policy,
  })
  if not candidate then return nil, workspace_err end
  if accept then
    local accepted, accept_error = accept(workspace.copy_snapshot(candidate))
    if not accepted then return nil, accept_error end
  end
  for alias, path in pairs(pending_roots) do self.canonical_roots[alias] = path end
  local unchanged = previous and not force_generation and vim.deep_equal(previous, candidate)
  if unchanged then
    self.active_id = id
    self.last_options[id] = vim.deepcopy(opts)
    remember_root_alias(self, id, root.alias)
    return workspace.copy_snapshot(previous)
  end
  if previous then candidate.generation = self.generation + 1 end
  self.generation = candidate.generation
  self.workspaces[id] = candidate
  self.active_id = id
  self.last_options[id] = vim.deepcopy(opts)
  remember_root_alias(self, id, root.alias)
  return workspace.copy_snapshot(candidate)
end

function Service:open(opts, accept)
  return self:_open(opts, false, accept)
end

function Service:refresh(workspace_id)
  local id = workspace_id or self.active_id
  local opts = id and self.last_options[id]
  if not opts then return nil, "workspace has not been opened" end
  local refreshed, err = self:_open(opts, true)
  if refreshed and refreshed.id ~= id then self:remove(id) end
  return refreshed, err
end

function Service:snapshot(workspace_id)
  local id = workspace_id or self.active_id
  return workspace.copy_snapshot(id and self.workspaces[id])
end

function Service:activate(workspace_id)
  if self.workspaces[workspace_id] == nil then return nil, "workspace snapshot is unavailable" end
  self.active_id = workspace_id
  return self:snapshot(workspace_id)
end

function Service:remove(workspace_id)
  if self.workspaces[workspace_id] == nil then return false end
  self.workspaces[workspace_id] = nil
  self.last_options[workspace_id] = nil
  local alias = self.root_aliases[workspace_id]
  self.root_aliases[workspace_id] = nil
  if alias then
    local retained = false
    for _, other_alias in pairs(self.root_aliases) do
      if other_alias == alias then retained = true; break end
    end
    if not retained then self.canonical_roots[alias] = nil end
  end
  if self.active_id == workspace_id then self.active_id = nil end
  return true
end

function Service:is_current(snapshot)
  local current = type(snapshot) == "table" and self.workspaces[snapshot.id] or nil
  return current ~= nil and snapshot.generation == current.generation
end

function Service:capabilities(snapshot, operation)
  if not self:is_current(snapshot) then
    return { state = "unsupported", reason = "stale_workspace_generation", operations = {} }
  end
  return workspace.execution_capability(snapshot, operation)
end

return M
