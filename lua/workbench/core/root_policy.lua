local resource = require("workbench.core.resource")

local M = {}

local function path_separator()
  return package.config:sub(1, 1)
end

local function trim_separator(path)
  local separator = path_separator()
  while #path > 1 and path:sub(-1) == separator do path = path:sub(1, -2) end
  return path
end

function M.contains(root_path, candidate_path)
  local root, root_err = resource.normalize_absolute_path(root_path)
  if not root then return false, root_err end
  local candidate, candidate_err = resource.normalize_absolute_path(candidate_path)
  if not candidate then return false, candidate_err end
  root, candidate = trim_separator(root), trim_separator(candidate)
  if candidate == root then return true end
  local separator = path_separator()
  if root == separator then return candidate:sub(1, 1) == separator end
  return candidate:sub(1, #root + 1) == root .. separator
end

function M.resolve(root_service, opts, canonical_cache, force_canonicalize)
  if type(root_service) ~= "table" or type(root_service.canonicalize) ~= "function" then
    return nil, "root service must provide canonicalize(path)"
  end
  opts = opts or {}
  local candidate, origin
  if opts.explicit_root ~= nil then
    candidate, origin = opts.explicit_root, "explicit"
  elseif opts.initial_file then
    if type(root_service.nearest_git_root) == "function" then
      candidate = root_service:nearest_git_root(opts.initial_file)
      if candidate then origin = "git" end
    end
    if not candidate and type(root_service.nearest_marker_root) == "function" then
      candidate = root_service:nearest_marker_root(opts.initial_file, opts.markers or {})
      if candidate then origin = "marker" end
    end
  end
  if not candidate then
    candidate = opts.launch_cwd
    if not candidate and type(root_service.cwd) == "function" then candidate = root_service:cwd() end
    if candidate then origin = "cwd" end
  end
  if type(candidate) ~= "string" then return nil, "no explicit root, detected root, or launch cwd is available" end

  local alias, alias_err = resource.normalize_absolute_path(candidate)
  if not alias then return nil, alias_err end
  canonical_cache = canonical_cache or {}
  local canonical = not force_canonicalize and canonical_cache[alias] or nil
  if not canonical then
    local err
    canonical, err = root_service:canonicalize(alias)
    if type(canonical) ~= "string" then return nil, err or "root canonicalization failed" end
  end
  local normalized, canonical_err = resource.normalize_absolute_path(canonical)
  if not normalized then return nil, "canonical root: " .. canonical_err end
  canonical_cache[alias] = normalized
  return { path = normalized, alias = alias, origin = origin }
end

-- Child resources deliberately keep their lexical identity. Canonical identities
-- are used only by this opt-in followed-symlink traversal check.
function M.directory_visit(root_path, child_path, ancestors, opts)
  opts, ancestors = opts or {}, ancestors or {}
  local lexical, err = resource.normalize_absolute_path(child_path)
  if not lexical then return nil, err end
  if opts.follow_symlinks ~= true then
    return { follow = false, identity = lexical, cycle = false, external = false }
  end
  if type(opts.realpath) ~= "function" then return nil, "following symlinks requires an injected realpath function" end
  local identity, realpath_err = opts.realpath(lexical)
  if type(identity) ~= "string" then return nil, realpath_err or "symlink target cannot be resolved" end
  local canonical, canonical_err = resource.normalize_absolute_path(identity)
  if not canonical then return nil, canonical_err end
  local root, root_err = resource.normalize_absolute_path(root_path)
  if not root then return nil, root_err end
  local inside = M.contains(root, canonical)
  return {
    follow = true,
    identity = canonical,
    cycle = ancestors[canonical] == true,
    external = not inside,
  }
end

return M
