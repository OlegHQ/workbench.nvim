local resource = require("workbench.core.resource")

local M = {}

local origins = { explicit = true, git = true, marker = true, cwd = true }

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

function M.id_for_roots(roots)
  local parts = { "workspace:" }
  for _, root in ipairs(roots) do
    parts[#parts + 1] = tostring(#root.uri)
    parts[#parts + 1] = ":"
    parts[#parts + 1] = root.uri
    parts[#parts + 1] = ";"
  end
  return table.concat(parts)
end

function M.new(fields)
  if type(fields) ~= "table" then return nil, "workspace fields are required" end
  if type(fields.id) ~= "string" or fields.id == "" then return nil, "workspace id is required" end
  if type(fields.generation) ~= "number" or fields.generation < 1 or fields.generation % 1 ~= 0 then
    return nil, "workspace generation must be a positive integer"
  end
  if type(fields.roots) ~= "table" or #fields.roots == 0 then return nil, "workspace requires at least one root" end
  if not origins[fields.root_origin] then return nil, "workspace root origin must be explicit, git, marker, or cwd" end

  local roots = {}
  local active_found = false
  for index, root in ipairs(fields.roots) do
    if type(root) ~= "table" or root.scheme ~= "file" or type(root.path) ~= "string" or type(root.uri) ~= "string" then
      return nil, "workspace roots must be file resources with native paths"
    end
    roots[index] = resource.copy(root)
    roots[index].workspace_id = fields.id
    if root.uri == fields.active_root_uri then active_found = true end
  end
  if fields.id ~= M.id_for_roots(roots) then return nil, "workspace id does not match its ordered roots" end
  if type(fields.active_root_uri) ~= "string" or not active_found then
    return nil, "active root URI must identify a workspace root"
  end
  if type(fields.scope) ~= "table" or fields.scope.explicit ~= true
    or (fields.scope.kind ~= "all_roots" and fields.scope.kind ~= "folder") then
    return nil, "workspace scope must be explicit and all_roots or folder"
  end
  if type(fields.policy) ~= "table" then return nil, "workspace policy snapshot is required" end

  return {
    id = fields.id,
    generation = fields.generation,
    roots = roots,
    active_root_uri = fields.active_root_uri,
    root_origin = fields.root_origin,
    scope = copy(fields.scope),
    policy = copy(fields.policy),
  }
end

function M.copy_snapshot(snapshot)
  if type(snapshot) ~= "table" then return nil end
  return copy(snapshot)
end

function M.execution_capability(snapshot, operation)
  if type(snapshot) ~= "table" or type(snapshot.roots) ~= "table" then
    return { state = "unsupported", reason = "workspace_snapshot_unavailable", operations = {} }
  end
  if #snapshot.roots ~= 1 then
    return {
      state = "unsupported",
      reason = "multi_root_execution_not_implemented",
      operations = {},
    }
  end
  return { state = "ready", operations = operation and { operation } or {} }
end

return M
