local Scope = require("workbench.core.scope")
local resource = require("workbench.core.resource")
local root_policy = require("workbench.core.root_policy")

local M = {}
local Provider = {}
Provider.__index = Provider

local BATCH_SIZE = 128
local STAT_CONCURRENCY = 16
local MAX_DIRECTORY_ENTRIES = 50000
local MAX_VISIBLE_ENTRIES = 20000
local MAX_CAPTURE_BYTES = 16 * 1024 * 1024
local MAX_CACHE_DIRECTORIES = 64
local MAX_CACHE_ITEMS = 50000

local function error_value(code, message, retryable)
  return { code = code, message = message, retryable = retryable == true }
end

local function path_key(path)
  local normalized = vim.fs.normalize(path):gsub("\\", "/")
  if #normalized > 1 then normalized = normalized:gsub("/$", "") end
  return normalized
end

local function policy_key(policy)
  local fields = { policy.hidden or "exclude", policy.ignored or "exclude", policy.symlinks or "never" }
  for _, name in ipairs({ "include", "exclude" }) do
    local values = vim.deepcopy(policy[name] or {})
    table.sort(values)
    fields[#fields + 1] = name .. "=" .. table.concat(values, "\0")
  end
  return table.concat(fields, "\1")
end

local function clone_items(items)
  local result = {}
  for index, item in ipairs(items) do
    result[index] = {
      id = item.id,
      kind = item.kind,
      label = item.label,
      parent_id = item.parent_id,
      detail = item.detail,
      expandable = item.expandable,
      selectable = item.selectable,
      payload = item.payload and vim.deepcopy(item.payload) or nil,
    }
  end
  return result
end

local function fs_error_code(err)
  local value = tostring(err or "")
  if value:find("ENOENT", 1, true) or value:find("no such file", 1, true) then return "directory_vanished" end
  if value:find("EACCES", 1, true) or value:find("permission denied", 1, true) then return "directory_inaccessible" end
  return "filesystem_error"
end

local function join_relative(base, name)
  if base == "" or base == "." then return name end
  return base:gsub("/$", "") .. "/" .. name
end

local function is_hidden(name)
  return name:sub(1, 1) == "."
end

local function parse_ignore_debug(stderr, candidates)
  local ignored = {}
  local unmatched = false
  for line in (stderr .. "\n"):gmatch("(.-)\n") do
    if line:find("ignoring ", 1, true) then
      local relative = line:match("^.* ignoring (.*): Ignore%(")
      if relative then
        relative = path_key(relative)
        if candidates[relative] then ignored[relative] = true end
      else
        -- Do not guess if an upstream debug format or a control-character
        -- path makes the diagnostic ambiguous; callers fail closed.
        unmatched = true
      end
    end
  end
  if unmatched then return nil, "ripgrep ignore diagnostics could not be decoded safely" end
  return ignored
end

local function starts_with_path(root, path)
  local relative = vim.fs.relpath(root, path)
  if relative == nil then return nil end
  if relative == "." then return "" end
  if relative == ".." or relative:sub(1, 3) == "../" or relative:sub(1, 3) == "..\\" then return nil end
  return relative:gsub("\\", "/")
end

local function sort_entries(entries)
  table.sort(entries, function(left, right)
    local left_directory = left.kind == "directory"
    local right_directory = right.kind == "directory"
    if left_directory ~= right_directory then return left_directory end
    local left_name = left.sort_name or left.name or ""
    local right_name = right.sort_name or right.name or ""
    if left_name ~= right_name then return left_name < right_name end
    return (left.id or "") < (right.id or "")
  end)
  for _, entry in ipairs(entries) do entry.sort_name = nil end
  return entries
end

function M.new(opts)
  opts = opts or {}
  local uv = opts.uv or vim.uv or vim.loop
  if type(uv) ~= "table" or type(uv.fs_scandir) ~= "function" then
    return nil, "libuv filesystem operations are unavailable"
  end
  local provider = setmetatable({
    uv = uv,
    scope = Scope.new("workbench-filesystem-provider"),
    system = opts.system or vim.system,
    executable = opts.executable or function(name) return vim.fn.exepath(name) end,
    cache = {},
    cache_items = 0,
    use_clock = 0,
    fs_generation = 1,
    requests = {},
    next_request = 0,
    options = {
      max_directory_entries = math.max(1, math.min(MAX_DIRECTORY_ENTRIES, tonumber(opts.max_directory_entries) or MAX_DIRECTORY_ENTRIES)),
      max_visible_entries = math.max(1, math.min(MAX_VISIBLE_ENTRIES, tonumber(opts.max_visible_entries) or MAX_VISIBLE_ENTRIES)),
      max_cache_directories = math.max(1, math.min(MAX_CACHE_DIRECTORIES, tonumber(opts.max_cache_directories) or MAX_CACHE_DIRECTORIES)),
      max_cache_items = math.max(1, math.min(MAX_CACHE_ITEMS, tonumber(opts.max_cache_items) or MAX_CACHE_ITEMS)),
      max_capture_bytes = math.max(4096, math.min(MAX_CAPTURE_BYTES, tonumber(opts.max_capture_bytes) or MAX_CAPTURE_BYTES)),
    },
    disposed = false,
  }, Provider)
  return provider
end

function Provider:_cache_key(snapshot, path)
  local uri = vim.uri_from_fname(path)
  return table.concat({ snapshot.id, tostring(snapshot.generation), policy_key(snapshot.policy or {}), tostring(self.fs_generation), uri }, "\2")
end

function Provider:_cached(key)
  local entry = self.cache[key]
  if not entry then return nil end
  self.use_clock = self.use_clock + 1
  entry.used = self.use_clock
  return entry.items
end

function Provider:_remember(key, items)
  if self.disposed or #items > self.options.max_cache_items then return end
  local previous = self.cache[key]
  if previous then self.cache_items = self.cache_items - #previous.items end
  self.use_clock = self.use_clock + 1
  self.cache[key] = { items = clone_items(items), used = self.use_clock }
  self.cache_items = self.cache_items + #items
  while self.cache_items > self.options.max_cache_items or vim.tbl_count(self.cache) > self.options.max_cache_directories do
    local oldest_key, oldest_used
    for candidate, entry in pairs(self.cache) do
      if not oldest_used or entry.used < oldest_used then oldest_key, oldest_used = candidate, entry.used end
    end
    if not oldest_key then break end
    self.cache_items = self.cache_items - #self.cache[oldest_key].items
    self.cache[oldest_key] = nil
  end
end

function Provider:invalidate(path)
  if path == nil then
    self.fs_generation = self.fs_generation + 1
    self.cache = {}
    self.cache_items = 0
    return true
  end
  local normalized = path_key(path)
  for key, entry in pairs(self.cache) do
    local uri = key:match("\2([^\2]+)$")
    local cached_path = uri and path_key(vim.uri_to_fname(uri)) or ""
    if cached_path == normalized or cached_path:sub(1, #normalized + 1) == normalized .. "/" then
      self.cache_items = self.cache_items - #entry.items
      self.cache[key] = nil
    end
  end
  return true
end

function Provider:_request(snapshot, path, opts, sink)
  if self.disposed or not self.scope.alive then return nil, error_value("provider_disposed", "filesystem provider is disposed") end
  if type(snapshot) ~= "table" or type(snapshot.id) ~= "string" or type(snapshot.generation) ~= "number"
    or type(snapshot.roots) ~= "table" or #snapshot.roots ~= 1 or type(snapshot.roots[1].path) ~= "string"
    or type(snapshot.policy) ~= "table" then
    return nil, error_value("workspace_unavailable", "a single-root workspace snapshot is required")
  end
  if type(path) ~= "string" then return nil, error_value("invalid_path", "directory path must be a native string") end
  local root = snapshot.roots[1].path
  local normalized, normalize_error = resource.normalize_absolute_path(path)
  if not normalized then return nil, error_value("invalid_path", normalize_error) end
  local inside, contains_error = root_policy.contains(root, normalized)
  if not inside then return nil, error_value("outside_root", contains_error or "directory is outside the selected workspace root") end
  if type(sink) ~= "function" then return nil, error_value("invalid_sink", "filesystem request sink must be a function") end

  self.next_request = self.next_request + 1
  local id = self.next_request
  local request_scope, scope_error = self.scope:child("directory:" .. id)
  if not request_scope then return nil, scope_error end
  local request = { id = id, scope = request_scope, active = true, process = nil, callback_count = 0 }
  self.requests[id] = request
  request_scope:defer(function()
    request.active = false
    self.requests[id] = nil
    if request.process then
      pcall(request.process.kill, request.process, "sigterm")
      request.process = nil
    end
  end, "filesystem-request:" .. id, "request")

  function request:cancel()
    if not self.active then return false end
    return self.scope:dispose()
  end
  request.dispose = request.cancel

  local function emit(event, terminal)
    if not request.active then return false end
    local ticket, err = request.scope:schedule(function()
      if not request.active then return end
      request.callback_count = request.callback_count + 1
      local ok, sink_error = pcall(sink, event)
      if not ok then request.scope:_record_error("filesystem sink", sink_error) end
      if terminal and request.active then request.scope:dispose() end
    end)
    if not ticket then
      request.last_error = err
      request.scope:dispose()
      return nil
    end
    return ticket
  end

  return request, emit, normalized, root
end

local function stat_type(stat)
  if type(stat) ~= "table" then return nil end
  return stat.type
end

function Provider:_ignore_arguments(snapshot, directory)
  local root = snapshot.roots[1].path
  local relative = starts_with_path(root, directory)
  if relative == nil then return nil, "ignore scan directory escaped the workspace" end
  local args = {
    "--no-config", "--no-require-git", "--no-ignore-global", "--no-ignore-exclude",
    "--debug", "--files", "--null", "--max-depth", "1",
  }
  if snapshot.policy.ignored == "include" then args[#args + 1] = "--no-ignore" end
  if snapshot.policy.hidden == "include" then args[#args + 1] = "--hidden" end
  for _, pattern in ipairs(snapshot.policy.include or {}) do
    args[#args + 1] = "--glob"
    args[#args + 1] = pattern
  end
  for _, pattern in ipairs(snapshot.policy.exclude or {}) do
    args[#args + 1] = "--glob"
    args[#args + 1] = "!" .. pattern
  end
  args[#args + 1] = "--glob"
  args[#args + 1] = "!**/.git/**"
  args[#args + 1] = "--glob"
  args[#args + 1] = "!/.git/"
  args[#args + 1] = "--"
  args[#args + 1] = relative == "" and "." or relative
  return args
end

function Provider:_classify_ignored(snapshot, directory, entries, request, emit, complete)
  local policy = snapshot.policy
  if policy.ignored == "include" and #(policy.include or {}) == 0 and #(policy.exclude or {}) == 0 then
    return complete({}, {})
  end
  local rg = self.executable("rg")
  if type(rg) ~= "string" or rg == "" then
    return emit({ kind = "error", error = error_value("ignore_provider_unavailable", "ripgrep is required to apply the workspace ignore policy", true) }, true)
  end
  local args, argument_error = self:_ignore_arguments(snapshot, directory)
  if not args then return emit({ kind = "error", error = error_value("ignore_policy_unavailable", argument_error, true) }, true) end

  local candidates, by_relative = {}, {}
  for _, entry in ipairs(entries) do
    local relative = entry.relative
    if relative then candidates[path_key(relative)] = true; by_relative[path_key(relative)] = entry end
  end
  local visible = {}
  local stdout_tail, stderr_tail = "", ""
  local output_bytes, error_bytes = 0, 0
  local capture_error

  local okay, process_or_error = pcall(self.system, { rg, unpack(args) }, {
    cwd = snapshot.roots[1].path,
    text = false,
    stdout = function(read_error, data)
      if read_error then capture_error = tostring(read_error); return end
      if type(data) ~= "string" or data == "" then return end
      output_bytes = output_bytes + #data
      if output_bytes > self.options.max_capture_bytes then
        capture_error = "ripgrep file-list output exceeded the bounded capture budget"
        if request.process then pcall(request.process.kill, request.process, "sigterm") end
        return
      end
      local combined = stdout_tail .. data
      local start = 1
      while true do
        local finish = combined:find("\0", start, true)
        if not finish then break end
        local value = combined:sub(start, finish - 1)
        if value ~= "" then visible[path_key(value)] = true end
        start = finish + 1
      end
      stdout_tail = combined:sub(start)
    end,
    stderr = function(read_error, data)
      if read_error then capture_error = tostring(read_error); return end
      if type(data) ~= "string" or data == "" then return end
      error_bytes = error_bytes + #data
      if error_bytes > self.options.max_capture_bytes then
        capture_error = "ripgrep ignore diagnostics exceeded the bounded capture budget"
        if request.process then pcall(request.process.kill, request.process, "sigterm") end
        return
      end
      stderr_tail = stderr_tail .. data
    end,
  }, function(result)
    request.process = nil
    if not request.active then return end
    if capture_error then
      return emit({ kind = "error", error = error_value("ignore_scan_failed", capture_error, true) }, true)
    end
    if #stdout_tail > 0 then visible[path_key(stdout_tail)] = true end
    local code = type(result) == "table" and result.code or nil
    if code ~= 0 and code ~= 1 then
      local detail = stderr_tail ~= "" and stderr_tail:sub(-512):gsub("%s+$", "") or "ripgrep could not read the workspace ignore state"
      return emit({ kind = "error", error = error_value("ignore_scan_failed", detail, true) }, true)
    end
    local ignored, parse_error = parse_ignore_debug(stderr_tail, candidates)
    if not ignored then
      return emit({ kind = "error", error = error_value("ignore_diagnostics_unsupported", parse_error, true) }, true)
    end
    for relative, entry in pairs(by_relative) do
      if (policy.ignored == "exclude" or #(policy.include or {}) > 0 or #(policy.exclude or {}) > 0)
        and entry.kind == "file" and not visible[relative] then entry.ignored = true end
      if ignored[relative] then entry.ignored = true end
    end
    complete(ignored, visible)
  end)
  if not okay or type(process_or_error) ~= "table" then
    local detail = tostring(okay and "ripgrep process could not be started" or process_or_error)
    return emit({ kind = "error", error = error_value("ignore_scan_failed", detail, true) }, true)
  end
  request.process = process_or_error
  request.scope:defer(function()
    if request.process then pcall(request.process.kill, request.process, "sigterm"); request.process = nil end
  end, "ripgrep-process:" .. request.id, "process")
end

function Provider:enumerate(snapshot, directory, opts, sink)
  opts = opts or {}
  local request, emit, normalized, root = self:_request(snapshot, directory, opts, sink)
  if not request then return nil, emit end
  local key = self:_cache_key(snapshot, normalized)
  local cached = not opts.refresh and self:_cached(key) or nil
  if cached then
    emit({ kind = "batch", items = clone_items(cached), cached = true })
    emit({ kind = "done", completeness = "complete", total = #cached, cached = true }, true)
    return request
  end

  local uv = self.uv
  local rows = {}
  local truncated = false
  local scan
  local function fail(err)
    local code = fs_error_code(err)
    emit({ kind = "error", error = error_value(code, tostring(err), code == "directory_inaccessible" or code == "directory_vanished") }, true)
  end
  local function build_rows()
    if not request.active then return end
    local policy = snapshot.policy
    local selected = {}
    for _, entry in ipairs(rows) do
      if not entry.vanished and not entry.ignored
        and (policy.hidden == "include" or not is_hidden(entry.name))
        and entry.name ~= ".git" then
        selected[#selected + 1] = entry
      end
    end
    sort_entries(selected)
    if #selected > self.options.max_visible_entries then
      truncated = true
      for index = #selected, self.options.max_visible_entries + 1, -1 do selected[index] = nil end
    end
    local items = {}
    for _, entry in ipairs(selected) do items[#items + 1] = entry.item end
    if truncated then
      items[#items + 1] = {
        id = "limit:" .. vim.uri_from_fname(normalized),
        kind = "limit",
        label = "Directory listing capped at " .. self.options.max_visible_entries .. " entries",
        parent_id = opts.parent_id,
        selectable = false,
        payload = { limit = self.options.max_visible_entries },
      }
    end
    self:_remember(key, items)
    emit({ kind = "batch", items = clone_items(items), cached = false })
    emit({ kind = "done", completeness = truncated and "truncated" or "complete", total = #selected, cached = false }, true)
  end
  local function classify()
    if not request.active then return end
    self:_classify_ignored(snapshot, normalized, rows, request, emit, function()
      if not request.active then return end
      local result = {}
      for _, entry in ipairs(rows) do
        if not entry.vanished then
          local item_resource = resource.from_path(entry.path)
          if item_resource then
            local kind = entry.kind
            local expandable = kind == "directory" and not entry.cycle and not entry.external_blocked
            local detail = entry.detail
            if entry.cycle then detail = "symlink cycle"; kind = "symlink_cycle" end
            if entry.external_blocked then detail = "external symlink; traversal disabled by workspace policy" end
            local item = {
              id = "file:" .. item_resource.uri,
              kind = kind,
              label = resource.escape_display(entry.name),
              detail = detail,
              parent_id = opts.parent_id,
              expandable = expandable,
              selectable = true,
              payload = {
                resource = item_resource,
                lexical_path = entry.path,
                raw_name = entry.name,
                canonical_identity = entry.identity,
                external = entry.external == true,
                symlink = entry.is_link == true,
                ancestors = vim.deepcopy(opts.ancestors or {}),
              },
              sort_name = entry.name,
            }
            if expandable then item.payload.ancestors[#item.payload.ancestors + 1] = entry.identity or entry.path end
            entry.item = item
            result[#result + 1] = entry
          end
        end
      end
      rows = result
      build_rows()
    end)
  end
  local function stat_unknown()
    local unknown = {}
    for _, entry in ipairs(rows) do if entry.kind == "unknown" or entry.kind == "" then unknown[#unknown + 1] = entry end end
    if #unknown == 0 then return classify() end
    local next_index, active, completed = 1, 0, 0
    local function worker()
      if not request.active then return end
      while active < STAT_CONCURRENCY and next_index <= #unknown do
        local entry = unknown[next_index]
        next_index = next_index + 1
        active = active + 1
        uv.fs_lstat(entry.path, function(err, stat)
          active = active - 1
          completed = completed + 1
          if err or not stat then entry.vanished = true else entry.kind = stat_type(stat) or "other" end
          if completed == #unknown then classify() else worker() end
        end)
      end
    end
    worker()
  end
  local function follow_links()
    local links = {}
    if snapshot.policy.symlinks == "never" then return stat_unknown() end
    for _, entry in ipairs(rows) do if entry.kind == "link" then links[#links + 1] = entry end end
    if #links == 0 then return stat_unknown() end
    local next_index, active, completed = 1, 0, 0
    local function worker()
      if not request.active then return end
      while active < STAT_CONCURRENCY and next_index <= #links do
        local entry = links[next_index]
        next_index = next_index + 1
        active = active + 1
        uv.fs_realpath(entry.path, function(realpath_error, realpath)
          if realpath_error or type(realpath) ~= "string" then
            entry.kind = "symlink_cycle"
            entry.cycle = true
            entry.detail = "symlink target cannot be resolved"
            active = active - 1
            completed = completed + 1
            if completed == #links then stat_unknown() else worker() end
            return
          end
          local identity = path_key(realpath)
          entry.identity = identity
          local ancestors = {}
          for _, ancestor in ipairs(opts.ancestors or {}) do ancestors[ancestor] = true end
          local visit = root_policy.directory_visit(root, entry.path, ancestors, {
            follow_symlinks = true,
            realpath = function() return identity end,
          })
          entry.external = visit and visit.external or false
          entry.cycle = visit and visit.cycle or false
          if entry.external and snapshot.policy.symlinks ~= "all" then
            entry.external_blocked = true
            entry.kind = "symlink"
          elseif entry.cycle then
            entry.kind = "symlink_cycle"
          else
            uv.fs_stat(entry.path, function(stat_error, stat)
              if not stat_error and stat and stat_type(stat) == "directory" then
                entry.kind = "directory"
              else
                entry.kind = "symlink"
                if stat_error then entry.detail = "symlink target is unavailable" end
              end
              active = active - 1
              completed = completed + 1
              if completed == #links then stat_unknown() else worker() end
            end)
            return
          end
          active = active - 1
          completed = completed + 1
          if completed == #links then stat_unknown() else worker() end
        end)
      end
    end
    worker()
  end
  local function read_chunk()
    if not request.active then return end
    local read = 0
    while read < BATCH_SIZE and #rows < self.options.max_directory_entries do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then
        scan = nil
        return follow_links()
      end
      if name ~= "." and name ~= ".." then
        read = read + 1
        local child = vim.fs.joinpath(normalized, name)
        rows[#rows + 1] = {
          name = name,
          path = child,
          relative = join_relative(starts_with_path(root, normalized) or "", name),
          kind = kind or "unknown",
          is_link = kind == "link",
          identity = kind == "directory" and path_key(child) or nil,
        }
      end
    end
    if #rows >= self.options.max_directory_entries then
      local extra = uv.fs_scandir_next(scan)
      truncated = extra ~= nil
      return follow_links()
    end
    local ticket, schedule_error = request.scope:schedule(read_chunk)
    if not ticket then fail(schedule_error and schedule_error.message or "directory read was cancelled") end
  end

  uv.fs_scandir(normalized, function(err, handle)
    if not request.active then return end
    if err or not handle then return fail(err or "directory disappeared during enumeration") end
    scan = handle
    read_chunk()
  end)
  return request
end

function Provider:status()
  return {
    disposed = self.disposed,
    active_requests = vim.tbl_count(self.requests),
    cache_directories = vim.tbl_count(self.cache),
    cache_items = self.cache_items,
    filesystem_generation = self.fs_generation,
  }
end

function Provider:dispose()
  if self.disposed then return false end
  self.disposed = true
  self.cache = {}
  self.cache_items = 0
  return self.scope:dispose()
end

M.constants = {
  batch_size = BATCH_SIZE,
  stat_concurrency = STAT_CONCURRENCY,
  max_directory_entries = MAX_DIRECTORY_ENTRIES,
  max_visible_entries = MAX_VISIBLE_ENTRIES,
  max_cache_directories = MAX_CACHE_DIRECTORIES,
  max_cache_items = MAX_CACHE_ITEMS,
}

return M
