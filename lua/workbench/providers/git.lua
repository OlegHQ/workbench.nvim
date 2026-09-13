local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")

local M = {}
local Provider = {}
Provider.__index = Provider

local DEFAULTS = {
  max_status_bytes = 8 * 1024 * 1024,
  max_status_items = 50000,
  max_diff_bytes = 256 * 1024,
  max_diff_lines = 2000,
  max_error_bytes = 4096,
  cache_ttl_ms = 1000,
  max_cache_repositories = 32,
}

local HARD_MAX = {
  max_status_bytes = 128 * 1024 * 1024,
  max_status_items = 100000,
  max_diff_bytes = 8 * 1024 * 1024,
  max_diff_lines = 20000,
  max_error_bytes = 16384,
  cache_ttl_ms = 60000,
  max_cache_repositories = 256,
}

local function error_value(code, message, retryable)
  return { code = code, message = message, retryable = retryable == true }
end

local function is_absolute(path)
  if package.config:sub(1, 1) == "\\" then
    return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
  end
  return path:sub(1, 1) == "/"
end

local function normalized_root(path)
  local normalized, err = Resource.normalize_absolute_path(path)
  if not normalized then return nil, err end
  return normalized
end

local function validate_workspace(workspace)
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or workspace.id == ""
    or type(workspace.generation) ~= "number" or type(workspace.roots) ~= "table"
    or #workspace.roots ~= 1 or type(workspace.roots[1]) ~= "table"
    or type(workspace.roots[1].path) ~= "string" then
    return nil, error_value("workspace_unavailable", "Git requires a single-root workspace with a native path")
  end
  local root, path_error = normalized_root(workspace.roots[1].path)
  if not root then return nil, error_value("invalid_workspace", path_error) end
  return root
end

local function fields_and_path(record, field_count)
  local fields, cursor = {}, 1
  for index = 1, field_count do
    local separator = record:find(" ", cursor, true)
    if not separator then return nil end
    fields[index] = record:sub(cursor, separator - 1)
    cursor = separator + 1
  end
  return fields, record:sub(cursor)
end

local function valid_xy(value, accepted)
  if type(value) ~= "string" or #value ~= 2 then return false end
  return accepted[value:sub(1, 1)] == true and accepted[value:sub(2, 2)] == true
end

local function valid_submodule(value)
  return value == "N..." or value:match("^S[%.C][%.M][%.U]$") ~= nil
end

local function new_aggregate()
  return { total = 0, staged = 0, unstaged = 0, untracked = 0, conflicts = 0, renames = 0, submodules = 0 }
end

local function add_record(snapshot, record)
  if #snapshot.files >= snapshot.max_items then
    return nil, error_value("status_item_limit", "Git status exceeded the configured file-count limit")
  end
  record.id = "git:" .. record.kind .. ":" .. record.path .. (record.original_path and ("\0" .. record.original_path) or "")
  record.display_path = Resource.escape_display(record.path)
  record.detail = table.concat(record.states, " · ")
  snapshot.files[#snapshot.files + 1] = record
  local aggregate = snapshot.aggregate
  aggregate.total = aggregate.total + 1
  if record.staged then aggregate.staged = aggregate.staged + 1 end
  if record.unstaged then aggregate.unstaged = aggregate.unstaged + 1 end
  if record.untracked then aggregate.untracked = aggregate.untracked + 1 end
  if record.conflict then aggregate.conflicts = aggregate.conflicts + 1 end
  if record.renamed then aggregate.renames = aggregate.renames + 1 end
  if record.submodule then aggregate.submodules = aggregate.submodules + 1 end
  return true
end

local function make_states(record)
  local states = {}
  if record.untracked then states[#states + 1] = "untracked" end
  if record.conflict then states[#states + 1] = "conflict" end
  if record.staged then states[#states + 1] = "staged" end
  if record.unstaged then states[#states + 1] = "unstaged" end
  if record.renamed then states[#states + 1] = "renamed" end
  if record.submodule then states[#states + 1] = "submodule" end
  if #states == 0 then states[1] = "changed" end
  return states
end

local function parse_status_record(parser, value)
  if value == "" then return true end
  if parser.pending_rename then
    parser.pending_rename.original_path = value
    parser.pending_rename.states = make_states(parser.pending_rename)
    local ok, err = add_record(parser.snapshot, parser.pending_rename)
    parser.pending_rename = nil
    return ok, err
  end

  local tag = value:sub(1, 1)
  local record
  if tag == "1" then
    local fields, path = fields_and_path(value, 8)
    if not fields or not valid_xy(fields[2], { ["."] = true, M = true, T = true, A = true, D = true, R = true, C = true, U = true })
      or not valid_submodule(fields[3]) or path == "" then
      return nil, error_value("malformed_status", "Git emitted a malformed ordinary porcelain-v2 record")
    end
    local x, y = fields[2]:sub(1, 1), fields[2]:sub(2, 2)
    record = {
      kind = fields[3]:sub(1, 1) == "S" and "submodule" or "file",
      path = path,
      xy = fields[2],
      staged = x ~= ".",
      unstaged = y ~= ".",
      submodule = fields[3]:sub(1, 1) == "S",
      conflict = false,
      untracked = false,
      renamed = false,
    }
  elseif tag == "2" then
    local fields, path = fields_and_path(value, 9)
    if not fields or not valid_xy(fields[2], { ["."] = true, M = true, T = true, A = true, D = true, R = true, C = true, U = true })
      or not valid_submodule(fields[3]) or path == "" then
      return nil, error_value("malformed_status", "Git emitted a malformed rename/copy porcelain-v2 record")
    end
    local x, y = fields[2]:sub(1, 1), fields[2]:sub(2, 2)
    local score = fields[9]
    if not score:match("^[RC]%d+$") or tonumber(score:sub(2)) > 100 then
      return nil, error_value("malformed_status", "Git emitted an invalid rename/copy score")
    end
    record = {
      kind = score:sub(1, 1) == "C" and "copy" or "rename",
      path = path,
      xy = fields[2],
      score = score,
      staged = x ~= ".",
      unstaged = y ~= ".",
      submodule = fields[3]:sub(1, 1) == "S",
      conflict = false,
      untracked = false,
      renamed = true,
    }
    parser.pending_rename = record
    return true
  elseif tag == "u" then
    local fields, path = fields_and_path(value, 10)
    if not fields or not valid_xy(fields[2], { D = true, A = true, U = true, M = true })
      or not valid_submodule(fields[3]) or path == "" then
      return nil, error_value("malformed_status", "Git emitted a malformed unmerged porcelain-v2 record")
    end
    local x, y = fields[2]:sub(1, 1), fields[2]:sub(2, 2)
    record = {
      kind = "conflict",
      path = path,
      xy = fields[2],
      staged = x ~= "." and x ~= "U",
      unstaged = y ~= "." and y ~= "U",
      submodule = fields[3]:sub(1, 1) == "S",
      conflict = true,
      untracked = false,
      renamed = false,
    }
  elseif value:sub(1, 2) == "? " then
    local path = value:sub(3)
    if path == "" then return nil, error_value("malformed_status", "Git emitted an empty untracked path") end
    record = {
      kind = "untracked",
      path = path,
      xy = "??",
      staged = false,
      unstaged = false,
      submodule = false,
      conflict = false,
      untracked = true,
      renamed = false,
    }
  elseif value:sub(1, 2) == "! " then
    return true
  else
    return nil, error_value("unknown_status_record", "Git emitted an unsupported porcelain-v2 record type")
  end

  record.states = make_states(record)
  return add_record(parser.snapshot, record)
end

local function new_parser(max_items)
  return {
    tail = "",
    pending_rename = nil,
    max_items = max_items,
    snapshot = { files = {}, aggregate = new_aggregate(), max_items = max_items },
  }
end

local function feed_status(parser, chunk)
  local value = parser.tail .. chunk
  local start = 1
  while true do
    local finish = value:find("\0", start, true)
    if not finish then break end
    local okay, err = parse_status_record(parser, value:sub(start, finish - 1))
    if not okay then return nil, err end
    start = finish + 1
  end
  parser.tail = value:sub(start)
  return true
end

local function finish_status(parser)
  if parser.pending_rename then return nil, error_value("malformed_status", "Git omitted a rename/copy original path") end
  if parser.tail ~= "" then return nil, error_value("malformed_status", "Git status output ended before a NUL record terminator") end
  parser.snapshot.max_items = nil
  return parser.snapshot
end

function M.parse_status(data, opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then return nil, error_value("invalid_options", "status parser options must be a table") end
  if type(data) ~= "string" then return nil, error_value("invalid_status", "porcelain-v2 input must be a byte string") end
  local max_bytes = opts.max_bytes or DEFAULTS.max_status_bytes
  local max_items = opts.max_items or DEFAULTS.max_status_items
  if type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes % 1 ~= 0
    or type(max_items) ~= "number" or max_items < 1 or max_items % 1 ~= 0 then
    return nil, error_value("invalid_options", "status byte and item limits must be positive integers")
  end
  if #data > max_bytes then return nil, error_value("status_output_limit", "Git status exceeded the configured byte limit") end
  local parser = new_parser(max_items)
  local okay, err = feed_status(parser, data)
  if not okay then return nil, err end
  return finish_status(parser)
end

local function decode_lines(value)
  local result = {}
  for line in (value .. "\n"):gmatch("(.-)\n") do
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    result[#result + 1] = line
  end
  return result
end

local function now_ns(uv)
  if uv and type(uv.hrtime) == "function" then return uv.hrtime() end
  return math.floor(os.clock() * 1e9)
end

local function copy_event(event)
  return vim.deepcopy(event)
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, error_value("invalid_options", "Git provider options must be a table") end
  local uv = opts.uv or vim.uv or vim.loop
  local system = opts.system or vim.system
  if type(system) ~= "function" then return nil, error_value("unsupported_runtime", "vim.system is required for the read-only Git provider") end
  local options = {}
  for key, fallback in pairs(DEFAULTS) do
    local value = opts[key] == nil and fallback or tonumber(opts[key])
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      return nil, error_value("invalid_options", key .. " must be a positive integer")
    end
    options[key] = math.min(value, HARD_MAX[key])
  end
  return setmetatable({
    scope = Scope.new("workbench-git-provider"),
    uv = uv,
    system = system,
    executable = opts.executable or function(name) return vim.fn.exepath(name) end,
    options = options,
    cache = {},
    cache_clock = 0,
    requests = {},
    active_roots = {},
    next_request = 0,
    disposed = false,
  }, Provider)
end

function Provider:_executable()
  if type(self.executable) == "string" then return self.executable ~= "" and self.executable or nil end
  if type(self.executable) ~= "function" then return nil end
  local ok, executable = pcall(self.executable, "git")
  if ok and type(executable) == "string" and executable ~= "" then return executable end
  return nil
end

function Provider:capabilities()
  if self.disposed then return { state = "disabled", reason = "Git provider is disposed", operations = {} } end
  if not self:_executable() then
    return { state = "unavailable", reason = "git executable was not found on PATH", operations = {} }
  end
  return { state = "ready", operations = { "status", "diff" }, read_only = true }
end

function Provider:_new_subscriber(sink, generation, operation)
  self.next_request = self.next_request + 1
  local id = self.next_request
  local scope, scope_error = self.scope:child("git-subscriber:" .. id)
  if not scope then return nil, scope_error end
  local subscriber = { id = id, scope = scope, sink = sink, generation = generation, active = true, terminal = false }
  if operation then operation.subscribers[id] = subscriber end
  local provider = self
  local handle = {}
  function handle:cancel()
    if not subscriber.active then return false end
    subscriber.active = false
    if operation then
      operation.subscribers[id] = nil
      if operation.active and next(operation.subscribers) == nil then provider:_cancel_operation(operation) end
    end
    if subscriber.scope.alive then subscriber.scope:dispose() end
    return true
  end
  handle.dispose = handle.cancel
  function handle:is_active() return subscriber.active end
  subscriber.handle = handle
  return subscriber
end

function Provider:_deliver(subscriber, event, terminal)
  if not subscriber.active or (subscriber.terminal and not terminal) then return false end
  local result = copy_event(event)
  result.generation = subscriber.generation
  if terminal then subscriber.terminal = true end
  local _, err = subscriber.scope:schedule(function()
    if not subscriber.active then return end
    local ok, sink_error = pcall(subscriber.sink, result)
    if not ok then subscriber.scope:_record_error("Git sink", sink_error) end
    if terminal then
      subscriber.active = false
      if operation then operation.subscribers[subscriber.id] = nil end
      if subscriber.scope.alive then subscriber.scope:dispose() end
    end
  end)
  if err then subscriber.scope:dispose(); subscriber.active = false; return nil end
  return true
end

function Provider:_emit(operation, event, terminal)
  for _, subscriber in pairs(operation.subscribers) do
    self:_deliver(subscriber, event, terminal)
  end
end

function Provider:_new_operation(kind, root_key)
  if not self.scope.alive then return nil, error_value("provider_disposed", "Git provider is disposed") end
  self.next_request = self.next_request + 1
  local id = self.next_request
  local scope, scope_error = self.scope:child("git-" .. kind .. ":" .. id)
  if not scope then return nil, scope_error end
  local operation = {
    id = id,
    kind = kind,
    root_key = root_key,
    scope = scope,
    subscribers = {},
    active = true,
    finished = false,
    process = nil,
    spawned = 0,
    stderr = "",
  }
  self.requests[id] = operation
  local provider = self
  function operation:cancel() return provider:_cancel_operation(self) end
  local _, defer_error = scope:defer(function()
    operation.active = false
    if operation.process then pcall(operation.process.kill, operation.process, "sigterm"); operation.process = nil end
    provider.requests[id] = nil
    if root_key and provider.active_roots[root_key] == operation then provider.active_roots[root_key] = nil end
  end, "git-operation:" .. kind .. ":" .. id, "request")
  if defer_error then scope:dispose(); return nil, defer_error end
  return operation
end

function Provider:_cancel_operation(operation)
  if not operation.active then return false end
  operation.active = false
  if operation.root_key and self.active_roots[operation.root_key] == operation then self.active_roots[operation.root_key] = nil end
  if operation.scope.alive then operation.scope:dispose() end
  return true
end

function Provider:_finish(operation, event, cache_snapshot)
  if not operation.active then return false end
  operation.active = false
  operation.finished = true
  operation.process = nil
  if operation.root_key and self.active_roots[operation.root_key] == operation then self.active_roots[operation.root_key] = nil end
  self:_emit(operation, event, true)
  if cache_snapshot then self:_remember(cache_snapshot) end
  if operation.scope.alive then operation.scope:dispose() end
  return true
end

function Provider:_append_stderr(operation, read_error, data)
  if not operation.active or read_error or type(data) ~= "string" or data == "" then return end
  local limit = self.options.max_error_bytes
  if #operation.stderr < limit then
    local take = math.min(#data, limit - #operation.stderr)
    operation.stderr = operation.stderr .. data:sub(1, take)
  end
end

function Provider:_spawn(operation, argv, cwd, stdout, on_exit)
  if not operation.active then return nil, error_value("cancelled", "Git request was cancelled") end
  local provider = self
  local okay, process_or_error = pcall(self.system, argv, {
    cwd = cwd,
    text = false,
    stdout = stdout,
    stderr = function(read_error, data) provider:_append_stderr(operation, read_error, data) end,
  }, function(result)
    operation.process = nil
    if not operation.active then return end
    on_exit(result)
  end)
  if not okay or type(process_or_error) ~= "table" then
    local detail = tostring(okay and "Git process could not be started" or process_or_error):sub(1, self.options.max_error_bytes)
    return nil, error_value("spawn_failed", detail, true)
  end
  operation.process = process_or_error
  operation.spawned = operation.spawned + 1
  operation.scope:defer(function()
    if operation.process then pcall(operation.process.kill, operation.process, "sigterm"); operation.process = nil end
  end, "git-process:" .. operation.id .. ":" .. operation.spawned, "process")
  return process_or_error
end

function Provider:_remember(snapshot)
  local repository_key = snapshot.repository.root
  local workspace_key = snapshot.repository.workspace_root or repository_key
  local aliases = {}
  for key, old_entry in pairs(self.cache) do
    if old_entry.snapshot.repository.root == repository_key then
      aliases[#aliases + 1] = key
      self.cache[key] = nil
    end
  end
  self.cache_clock = self.cache_clock + 1
  local entry = { snapshot = vim.deepcopy(snapshot), created = now_ns(self.uv), used = self.cache_clock }
  self.cache[repository_key] = entry
  self.cache[workspace_key] = entry
  for _, alias in ipairs(aliases) do self.cache[alias] = entry end
  local function entries()
    local seen = {}
    for _, cached in pairs(self.cache) do seen[cached] = true end
    return vim.tbl_count(seen)
  end
  while entries() > self.options.max_cache_repositories do
    local oldest, oldest_used
    for _, cached in pairs(self.cache) do
      if not oldest_used or cached.used < oldest_used then oldest, oldest_used = cached, cached.used end
    end
    if not oldest then break end
    for key, cached in pairs(self.cache) do if cached == oldest then self.cache[key] = nil end end
  end
end

function Provider:_remove_cache_entry(entry)
  if not entry then return end
  for key, cached in pairs(self.cache) do if cached == entry then self.cache[key] = nil end end
end

function Provider:_cached(root, workspace)
  local entry = self.cache[root]
  if not entry then return nil end
  local ttl_ns = self.options.cache_ttl_ms * 1e6
  if now_ns(self.uv) - entry.created > ttl_ns then self:_remove_cache_entry(entry); return nil end
  self.cache_clock = self.cache_clock + 1
  entry.used = self.cache_clock
  local snapshot = vim.deepcopy(entry.snapshot)
  snapshot.workspace_id = workspace.id
  snapshot.workspace_generation = workspace.generation
  snapshot.repository.workspace_root = root
  return snapshot
end

function Provider:invalidate(root)
  if root == nil then self.cache = {}; return true end
  local normalized, err = normalized_root(root)
  if not normalized then return nil, error_value("invalid_path", err) end
  self:_remove_cache_entry(self.cache[normalized])
  return true
end

function Provider:_read_status(operation, executable, repository, workspace, parser, output_bytes)
  operation.stderr = ""
  local argv = { executable, "-C", repository.root, "status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=none" }
  local function stdout(read_error, data)
    if not operation.active then return end
    if read_error then operation.stream_error = tostring(read_error); return end
    if type(data) ~= "string" or data == "" then return end
    output_bytes.value = output_bytes.value + #data
    if output_bytes.value > self.options.max_status_bytes then
      operation.limit_error = error_value("status_output_limit", "Git status exceeded the configured byte limit", true)
      if operation.process then pcall(operation.process.kill, operation.process, "sigterm") end
      return
    end
    local okay, parse_error = feed_status(parser, data)
    if not okay then
      operation.parse_error = parse_error
      if operation.process then pcall(operation.process.kill, operation.process, "sigterm") end
    end
  end
  local process, spawn_error = self:_spawn(operation, argv, repository.root, stdout, function(result)
    if operation.stream_error then
      return self:_finish(operation, { kind = "error", error = error_value("git_read_failed", operation.stream_error, true) })
    end
    if operation.limit_error then return self:_finish(operation, { kind = "error", error = operation.limit_error }) end
    if operation.parse_error then return self:_finish(operation, { kind = "error", error = operation.parse_error }) end
    if result.code ~= 0 then
      local stderr = operation.stderr ~= "" and Resource.escape_display(operation.stderr) or "git status failed"
      return self:_finish(operation, { kind = "error", error = error_value("git_status_failed", stderr, true) })
    end
    local parsed, parse_error = finish_status(parser)
    if not parsed then return self:_finish(operation, { kind = "error", error = parse_error }) end
    local snapshot = {
      workspace_id = workspace.id,
      workspace_generation = workspace.generation,
      repository = repository,
      files = parsed.files,
      aggregate = parsed.aggregate,
      status = "ready",
      captured_at_ns = now_ns(self.uv),
    }
    self:_finish(operation, { kind = "done", status = "ready", snapshot = snapshot }, snapshot)
  end)
  if not process then self:_finish(operation, { kind = "error", error = spawn_error }); return nil, spawn_error end
  return process
end

function Provider:_identify(operation, executable, workspace, root)
  local argv = { executable, "-C", root, "rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", "--show-superproject-working-tree" }
  local output, output_bytes = {}, 0
  local stdout = function(read_error, data)
    if not operation.active then return end
    if read_error then operation.identify_error = error_value("git_read_failed", tostring(read_error), true); return end
    if type(data) ~= "string" then return end
    output_bytes = output_bytes + #data
    if output_bytes > 64 * 1024 then
      operation.identify_error = error_value("repository_identity_limit", "Git repository identity output exceeded its byte limit")
      if operation.process then pcall(operation.process.kill, operation.process, "sigterm") end
      return
    end
    output[#output + 1] = data
  end
  local process, spawn_error = self:_spawn(operation, argv, root, stdout, function(result)
    if operation.identify_error then return self:_finish(operation, { kind = "error", error = operation.identify_error }) end
    if result.code ~= 0 then
      local stderr = operation.stderr or ""
      if stderr:lower():find("not a git repository", 1, true) then
        self:_finish(operation, {
          kind = "done", status = "not_repository",
          error = { code = "not_repository", message = "workspace root is not inside a Git worktree", retryable = false },
        })
      else
        local message = stderr ~= "" and Resource.escape_display(stderr) or "git repository identity could not be read"
        self:_finish(operation, { kind = "error", error = error_value("git_identity_failed", message, true) })
      end
      return
    end
    local lines = decode_lines(table.concat(output))
    local repo_root, git_dir, common_dir, superproject = lines[1], lines[2], lines[3], lines[4]
    if type(repo_root) ~= "string" or repo_root == "" or type(git_dir) ~= "string" or git_dir == ""
      or type(common_dir) ~= "string" or common_dir == "" then
      return self:_finish(operation, { kind = "error", error = error_value("repository_identity_invalid", "Git returned an incomplete repository identity") })
    end
    repo_root = vim.fs.normalize(repo_root)
    if not is_absolute(git_dir) then git_dir = vim.fs.normalize(repo_root .. "/" .. git_dir) end
    if not is_absolute(common_dir) then common_dir = vim.fs.normalize(repo_root .. "/" .. common_dir) end
    local repository = {
      root = repo_root,
      git_dir = vim.fs.normalize(git_dir),
      common_dir = vim.fs.normalize(common_dir),
      superproject_root = superproject ~= "" and vim.fs.normalize(superproject) or nil,
      is_worktree = vim.fs.normalize(git_dir) ~= vim.fs.normalize(common_dir) and superproject == "",
      is_submodule = superproject ~= "",
      workspace_root = root,
      identity = table.concat({ repo_root, git_dir, common_dir }, "\0"),
    }
    self:_read_status(operation, executable, repository, workspace, new_parser(self.options.max_status_items), { value = 0 })
  end)
  if not process then self:_finish(operation, { kind = "error", error = spawn_error }); return nil, spawn_error end
  return process
end

function Provider:refresh(workspace, opts, sink)
  if self.disposed or not self.scope.alive then return nil, error_value("provider_disposed", "Git provider is disposed") end
  if type(opts) == "function" and sink == nil then sink, opts = opts, {} end
  if opts == nil then opts = {} end
  if type(opts) ~= "table" or (opts.force ~= nil and type(opts.force) ~= "boolean") then
    return nil, error_value("invalid_request", "Git refresh options must be a table with an optional boolean force")
  end
  if type(sink) ~= "function" then return nil, error_value("invalid_sink", "Git refresh sink must be a function") end
  local root, workspace_error = validate_workspace(workspace)
  if not root then return nil, workspace_error end
  local executable = self:_executable()
  if not executable then return nil, error_value("missing_dependency", "git executable was not found on PATH", true) end
  local active = self.active_roots[root]
  if active and active.active then
    local subscriber, subscriber_error = self:_new_subscriber(sink, opts.generation, active)
    if subscriber then self:_deliver(subscriber, { kind = "status", status = "running" }, false) end
    return subscriber and subscriber.handle or nil, subscriber_error
  end
  if opts.force ~= true then
    local cached = self:_cached(root, workspace)
    if cached then
      local subscriber, subscriber_error = self:_new_subscriber(sink, opts.generation)
      if not subscriber then return nil, subscriber_error end
      self:_deliver(subscriber, { kind = "done", status = "ready", cached = true, snapshot = cached }, true)
      return subscriber.handle
    end
  end
  local operation, operation_error = self:_new_operation("status", root)
  if not operation then return nil, operation_error end
  local subscriber, subscriber_error = self:_new_subscriber(sink, opts.generation, operation)
  if not subscriber then operation:cancel(); return nil, subscriber_error end
  self.active_roots[root] = operation
  self:_emit(operation, { kind = "status", status = "running" }, false)
  self:_identify(operation, executable, workspace, root)
  return subscriber.handle
end

local function diff_commands(provider, executable, repository, record)
  local path = record.path
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or is_absolute(path) then
    return nil, error_value("invalid_path", "Git diff requires a non-empty repository-relative path")
  end
  for component in path:gmatch("[^/\\]+") do
    if component == "." or component == ".." then
      return nil, error_value("invalid_path", "Git diff path must remain inside the repository")
    end
  end
  local common = { executable, "--literal-pathspecs", "-C", repository.root, "diff", "--no-ext-diff", "--no-textconv", "--unified=3" }
  local function append_pathspec(argv)
    argv[#argv + 1] = "--"
    argv[#argv + 1] = path
    if record.renamed and type(record.original_path) == "string" then
      argv[#argv + 1] = record.original_path
    end
  end
  if record.untracked then
    local absolute = vim.fs.normalize(repository.root .. "/" .. path)
    local filesystem = provider.uv or vim.uv or vim.loop
    if type(filesystem.fs_lstat) ~= "function" then
      return nil, error_value("diff_unsupported", "untracked preview requires native file metadata")
    end
    local okay, stat = pcall(filesystem.fs_lstat, absolute)
    if not okay or not stat then return nil, error_value("diff_file_unavailable", "untracked file is no longer available", true) end
    if stat.type ~= "file" then return nil, error_value("diff_unsupported_file", "only regular untracked files can be previewed", false) end
    return { { executable, "-C", repository.root, "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--unified=3", "--", "/dev/null", absolute } }, { allow_exit_one = true }
  end
  if record.conflict then
    local argv = vim.deepcopy(common)
    argv[#argv + 1] = "--cc"
    append_pathspec(argv)
    return { argv }
  end
  local commands = {}
  if record.staged then
    local argv = vim.deepcopy(common)
    table.insert(argv, 7, "--cached")
    append_pathspec(argv)
    commands[#commands + 1] = argv
  end
  if record.unstaged then
    local argv = vim.deepcopy(common)
    append_pathspec(argv)
    commands[#commands + 1] = argv
  end
  if #commands == 0 then return nil, error_value("diff_unavailable", "this Git status entry has no previewable diff", false) end
  return commands
end

function Provider:diff(snapshot, record, opts, sink)
  if self.disposed or not self.scope.alive then return nil, error_value("provider_disposed", "Git provider is disposed") end
  if type(opts) == "function" and sink == nil then sink, opts = opts, {} end
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then return nil, error_value("invalid_request", "Git diff options must be a table") end
  if type(sink) ~= "function" then return nil, error_value("invalid_sink", "Git diff sink must be a function") end
  if type(snapshot) ~= "table" or type(snapshot.repository) ~= "table" or type(snapshot.repository.root) ~= "string" then
    return nil, error_value("repository_unavailable", "Git diff requires a repository status snapshot")
  end
  if type(record) ~= "table" then return nil, error_value("invalid_record", "Git diff requires a selected status entry") end
  local selected = false
  for _, candidate in ipairs(snapshot.files or {}) do
    if candidate == record or (candidate.id ~= nil and candidate.id == record.id and candidate.path == record.path) then
      selected = true
      break
    end
  end
  if not selected then return nil, error_value("invalid_record", "Git diff accepts only an entry from the supplied status snapshot") end
  local executable = self:_executable()
  if not executable then return nil, error_value("missing_dependency", "git executable was not found on PATH", true) end
  local commands, command_options = diff_commands(self, executable, snapshot.repository, record)
  if not commands then return nil, command_options end
  local operation, operation_error = self:_new_operation("diff", nil)
  if not operation then return nil, operation_error end
  local subscriber, subscriber_error = self:_new_subscriber(sink, opts.generation, operation)
  if not subscriber then operation:cancel(); return nil, subscriber_error end
  self:_emit(operation, { kind = "status", status = "running" }, false)
  local chunks, output_bytes, output_lines = {}, 0, 0
  local command_index = 0

  local function finish()
    local raw = table.concat(chunks)
    local line_count = raw == "" and 0 or select(2, raw:gsub("\n", "")) + (raw:sub(-1) == "\n" and 0 or 1)
    self:_finish(operation, {
      kind = "done",
      status = operation.truncated and "partial" or "ready",
      truncated = operation.truncated == true,
      text = raw,
      lines = line_count,
      bytes = output_bytes,
    })
  end

  local run_next
  run_next = function()
    if not operation.active then return end
    command_index = command_index + 1
    local argv = commands[command_index]
    if not argv then return finish() end
    if command_index > 1 then chunks[#chunks + 1] = "\n──── unstaged ────\n" end
    if #commands > 1 and command_index == 1 then chunks[#chunks + 1] = "──── staged ────\n" end
    operation.stderr = ""
    local process, spawn_error = self:_spawn(operation, argv, snapshot.repository.root, function(read_error, data)
      if not operation.active then return end
      if read_error then operation.stream_error = tostring(read_error); return end
      if type(data) ~= "string" or data == "" then return end
      local remaining = self.options.max_diff_bytes - output_bytes
      local take = math.min(#data, math.max(0, remaining))
      local chunk = data:sub(1, take)
      local newline_count = select(2, chunk:gsub("\n", ""))
      if output_lines + newline_count > self.options.max_diff_lines then
        local wanted = self.options.max_diff_lines - output_lines
        local position = 1
        for _ = 1, math.max(0, wanted) do
          position = chunk:find("\n", position, true)
          if not position then break end
          position = position + 1
        end
        chunk = wanted <= 0 and "" or (position and chunk:sub(1, position - 1) or chunk)
        operation.truncated = true
      end
      chunks[#chunks + 1] = chunk
      output_bytes = output_bytes + #chunk
      output_lines = output_lines + select(2, chunk:gsub("\n", ""))
      if take < #data or output_bytes >= self.options.max_diff_bytes then operation.truncated = true end
      if operation.truncated and operation.process then pcall(operation.process.kill, operation.process, "sigterm") end
    end, function(result)
      if operation.stream_error then return self:_finish(operation, { kind = "error", error = error_value("git_diff_read_failed", operation.stream_error, true) }) end
      local accepted_exit = result.code == 0 or (command_options and command_options.allow_exit_one and result.code == 1)
      if not accepted_exit and not operation.truncated then
        local stderr = operation.stderr ~= "" and Resource.escape_display(operation.stderr) or "git diff failed"
        return self:_finish(operation, { kind = "error", error = error_value("git_diff_failed", stderr, true) })
      end
      if operation.truncated then finish() else run_next() end
    end)
    if not process then self:_finish(operation, { kind = "error", error = spawn_error }) end
  end
  run_next()
  return subscriber.handle
end

function Provider:status()
  local active, processes = 0, 0
  local requests = {}
  local cached = {}
  for id, operation in pairs(self.requests) do
    if operation.active then
      active = active + 1
      if operation.process then processes = processes + 1 end
      requests[#requests + 1] = { id = id, kind = operation.kind, process_active = operation.process ~= nil, subscribers = vim.tbl_count(operation.subscribers) }
    end
  end
  for _, entry in pairs(self.cache) do cached[entry] = true end
  table.sort(requests, function(left, right) return left.id < right.id end)
  return { state = self.disposed and "disposed" or "ready", active_requests = active, active_processes = processes, cached_repositories = vim.tbl_count(cached), requests = requests }
end

function Provider:dispose()
  if self.disposed then return self.disposal_report end
  self.disposed = true
  self.cache = {}
  self.active_roots = {}
  self.disposal_report = self.scope:dispose()
  return self.disposal_report
end

return M
