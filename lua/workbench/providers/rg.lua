local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")
local Location = require("workbench.core.location")
local RootPolicy = require("workbench.core.root_policy")

local M = {}
local Provider = {}
Provider.__index = Provider

local MiB = 1024 * 1024
local DEFAULTS = {
  max_active_requests = 8,
  max_concurrent_per_workspace = 2,
  max_query_bytes = 4096,
  max_globs = 128,
  max_glob_bytes = 4096,
  max_json_line_bytes = 1024 * 1024,
  max_pending_output_bytes = 1024 * 1024,
  max_output_bytes = 64 * MiB,
  max_stderr_bytes = 64 * 1024,
  max_error_bytes = 2048,
  max_snippet_bytes = 4096,
  max_match_bytes = 4096,
  max_submatches_per_line = 256,
  max_items = 10000,
  max_result_bytes = 8 * MiB,
  max_batch_items = 128,
  max_batch_bytes = 128 * 1024,
  max_messages_per_slice = 128,
  max_slice_ms = 4,
  timeout_ms = 30000,
}

local HARD_MAX = {
  max_active_requests = 8,
  max_concurrent_per_workspace = 2,
  max_query_bytes = 64 * 1024,
  max_globs = 256,
  max_glob_bytes = 16 * 1024,
  max_json_line_bytes = 4 * MiB,
  max_pending_output_bytes = 4 * MiB,
  max_output_bytes = 128 * MiB,
  max_stderr_bytes = 256 * 1024,
  max_error_bytes = 8192,
  max_snippet_bytes = 16 * 1024,
  max_match_bytes = 16 * 1024,
  max_submatches_per_line = 1024,
  max_items = 10000,
  max_result_bytes = 16 * MiB,
  max_batch_items = 512,
  max_batch_bytes = 512 * 1024,
  max_messages_per_slice = 512,
  max_slice_ms = 16,
  timeout_ms = 10 * 60 * 1000,
}

local function error_value(code, message, retryable, extra)
  local result = { code = code, message = message, retryable = retryable == true }
  if type(extra) == "table" then
    for key, value in pairs(extra) do result[key] = value end
  end
  return result
end

local function is_integer(value, minimum)
  return type(value) == "number" and value % 1 == 0 and value >= (minimum or 0)
end

local function bounded_option(opts, name)
  local value = opts[name]
  if value == nil then return DEFAULTS[name] end
  if not is_integer(value, 1) then return nil, name .. " must be a positive integer" end
  return math.min(value, HARD_MAX[name])
end

local function dense_strings(value, name, max_count, max_item_bytes)
  if type(value) ~= "table" then return nil, name .. " must be a string array" end
  local count, maximum = 0, 0
  for key, item in pairs(value) do
    if not is_integer(key, 1) then return nil, name .. " must be a dense string array" end
    if type(item) ~= "string" or item == "" or item:find("\0", 1, true) then
      return nil, name .. " contains an invalid pattern"
    end
    if #item > max_item_bytes then return nil, name .. " pattern exceeds its byte limit" end
    count, maximum = count + 1, math.max(maximum, key)
  end
  if count ~= maximum then return nil, name .. " must be a dense string array" end
  if count > max_count then return nil, name .. " exceeds its pattern count limit" end
  return value
end

local function validate_search_path(root, scope_path, relative, scope_kind)
  local uv = vim.uv or vim.loop
  local function check(path, expected)
    local stat = uv.fs_lstat(path)
    if not stat then return nil, error_value("scope_unavailable", "search root or folder is missing or inaccessible", true) end
    if stat.type == "link" then
      return nil, error_value("symlink_scope_unsupported", "search scope cannot be a symlink when symlink traversal is disabled")
    end
    if stat.type ~= expected then
      return nil, error_value("invalid_scope", expected == "file" and "file scope must identify a regular file" or "search root and folder scopes must be directories")
    end
    return true
  end

  local valid, err = check(root, "directory")
  if not valid then return nil, err end
  if relative == "." then
    if scope_kind == "file" then return nil, error_value("invalid_scope", "file scope must identify a file below the workspace root") end
    return true
  end
  local current = root
  local components = {}
  for component in relative:gmatch("[^/\\]+") do components[#components + 1] = component end
  for index, component in ipairs(components) do
    current = vim.fs.joinpath(current, component)
    local expected = scope_kind == "file" and index == #components and "file" or "directory"
    valid, err = check(current, expected)
    if not valid then return nil, err end
  end
  if vim.fs.normalize(current) ~= vim.fs.normalize(scope_path) then
    return nil, error_value("invalid_scope", "folder scope path could not be resolved component by component")
  end
  return true
end

local function decode_raw(value, label)
  if type(value) ~= "table" then return nil, label .. " must be a ripgrep text/bytes object" end
  if type(value.text) == "string" and value.bytes == nil then return value.text end
  if type(value.bytes) == "string" and value.text == nil then
    local ok, decoded = pcall(vim.base64.decode, value.bytes)
    if ok and type(decoded) == "string" then return decoded end
    return nil, label .. " contains invalid base64 bytes"
  end
  return nil, label .. " must contain exactly one text or bytes field"
end

local function trim_line_ending(value)
  if value:sub(-1) == "\n" then value = value:sub(1, -2) end
  if value:sub(-1) == "\r" then value = value:sub(1, -2) end
  return value
end

local function excerpt(value, start, cap)
  if #value <= cap then return value end
  local before = math.floor(cap / 2)
  local first = math.max(1, math.min(start - before, #value - cap + 1))
  local last = math.min(#value, first + cap - 1)
  local result = value:sub(first, last)
  if first > 1 then result = "…" .. result end
  if last < #value then result = result .. "…" end
  return result
end

local function normalize_request(request, limits)
  if type(request) ~= "table" then return nil, error_value("invalid_request", "search request must be a table") end
  if request.max_items ~= nil and not is_integer(request.max_items, 1) then
    return nil, error_value("invalid_request", "max_items must be a positive integer")
  end
  local workspace = request.workspace
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or workspace.id == ""
    or not is_integer(workspace.generation, 1) or type(workspace.roots) ~= "table" then
    return nil, error_value("workspace_unavailable", "a current workspace snapshot is required", true)
  end
  if #workspace.roots ~= 1 then
    return nil, error_value("unsupported_workspace", "ripgrep currently supports one explicit workspace root", false)
  end
  local root = workspace.roots[1]
  if type(root) ~= "table" or root.scheme ~= "file" or type(root.path) ~= "string" then
    return nil, error_value("workspace_unavailable", "workspace root must be a file resource with a native path")
  end
  local normalized_root, root_err = Resource.normalize_absolute_path(root.path)
  if not normalized_root then return nil, error_value("invalid_workspace_root", root_err) end

  local scope = request.scope or workspace.scope
  if type(scope) ~= "table" or scope.explicit ~= true then
    return nil, error_value("scope_required", "search requires an explicit all-roots or folder scope")
  end
  local scope_path = normalized_root
  if scope.kind == "folder" or scope.kind == "file" then
    scope_path = scope.path or (type(scope.resource) == "table" and scope.resource.path)
    if type(scope_path) ~= "string" then return nil, error_value("invalid_scope", "folder scope requires a native path") end
    local normalized, normalize_err = Resource.normalize_absolute_path(scope_path)
    if not normalized then return nil, error_value("invalid_scope", normalize_err) end
    scope_path = normalized
  elseif scope.kind ~= "all_roots" then
    return nil, error_value("invalid_scope", "scope kind must be all_roots, folder, or file")
  end
  local inside, contains_err = RootPolicy.contains(normalized_root, scope_path)
  if not inside then return nil, error_value("outside_root", contains_err or "search scope lies outside the workspace root") end

  local policy = workspace.policy
  if type(policy) ~= "table" then return nil, error_value("policy_unavailable", "workspace search policy is unavailable") end
  local hidden = policy.hidden or "exclude"
  local ignored = policy.ignored or "exclude"
  local symlinks = policy.symlinks or "never"
  if (hidden ~= "include" and hidden ~= "exclude") or (ignored ~= "include" and ignored ~= "exclude") then
    return nil, error_value("policy_unsupported", "workspace hidden/ignored policy is unsupported")
  end
  if symlinks ~= "never" then
    return nil, error_value("symlink_policy_unsupported", "search cannot safely traverse symlinks under the current workspace policy")
  end
  local includes, include_err = dense_strings(policy.include or {}, "include globs", limits.max_globs, limits.max_glob_bytes)
  if not includes then return nil, error_value("invalid_policy", include_err) end
  local excludes, exclude_err = dense_strings(policy.exclude or {}, "exclude globs", limits.max_globs, limits.max_glob_bytes)
  if not excludes then return nil, error_value("invalid_policy", exclude_err) end
  if scope.kind == "file" and #includes > 0 then
    return nil, error_value("file_scope_policy_unsupported", "current-file search cannot safely combine a file scope with workspace include globs")
  end

  local query = request.query
  if type(query) ~= "string" then return nil, error_value("invalid_query", "search query must be a string") end
  if #query > limits.max_query_bytes then return nil, error_value("query_too_large", "search query exceeds its byte limit") end
  if query:find("\0", 1, true) then return nil, error_value("invalid_query", "search query cannot contain NUL bytes") end
  if query:find("\n", 1, true) or query:find("\r", 1, true) then
    return nil, error_value("multiline_unsupported", "multiline search patterns are not supported by this provider")
  end
  local generation = request.generation
  if not is_integer(generation, 1) then return nil, error_value("invalid_generation", "search generation must be a positive integer") end
  local session_id = request.session_id or "default"
  if type(session_id) ~= "string" or session_id == "" or #session_id > 128 then
    return nil, error_value("invalid_session", "search session ID must be a non-empty string of at most 128 bytes")
  end
  local flags = request.flags or {}
  if type(flags) ~= "table" then return nil, error_value("invalid_flags", "search flags must be a table") end
  local case = flags.case or "smart"
  if case ~= "smart" and case ~= "sensitive" and case ~= "insensitive" then
    return nil, error_value("invalid_flags", "case must be smart, sensitive, or insensitive")
  end
  for _, flag in ipairs({ "fixed", "word" }) do
    if flags[flag] ~= nil and type(flags[flag]) ~= "boolean" then
      return nil, error_value("invalid_flags", flag .. " must be boolean")
    end
  end
  if request.emit_files ~= nil and type(request.emit_files) ~= "boolean" then
    return nil, error_value("invalid_request", "emit_files must be boolean")
  end
  if request.enumerate_files ~= nil and type(request.enumerate_files) ~= "boolean" then
    return nil, error_value("invalid_request", "enumerate_files must be boolean")
  end
  if request.emit_files == true and request.enumerate_files == true then
    return nil, error_value("invalid_request", "emit_files and enumerate_files cannot be combined")
  end
  local allowed_paths
  if request.allowed_paths ~= nil then
    local paths, paths_err = dense_strings(request.allowed_paths, "allowed file paths", 512, 32768)
    if not paths then return nil, error_value("invalid_request", paths_err) end
    allowed_paths = {}
    for _, path in ipairs(paths) do
      local normalized, path_err = Resource.normalize_absolute_path(path)
      if not normalized then return nil, error_value("invalid_request", "allowed file path: " .. tostring(path_err)) end
      local inside = RootPolicy.contains(normalized_root, normalized)
      if not inside then return nil, error_value("outside_root", "allowed file path lies outside the search root") end
      allowed_paths[normalized] = true
    end
  end
  if request.enumerate_files == true and allowed_paths == nil then
    return nil, error_value("invalid_request", "file enumeration requires a bounded allowlist")
  end

  local relative = vim.fs.relpath(normalized_root, scope_path)
  if relative == nil then return nil, error_value("outside_root", "search scope cannot be made relative to the workspace root") end
  if relative == "." then relative = "." end
  local valid_scope, scope_err = validate_search_path(normalized_root, scope_path, relative, scope.kind)
  if not valid_scope then return nil, scope_err end
  return {
    workspace = workspace,
    workspace_id = workspace.id,
    workspace_generation = workspace.generation,
    root = normalized_root,
    scope_path = scope_path,
    relative_scope = relative,
    scope_kind = scope.kind,
    policy = policy,
    include = includes,
    exclude = excludes,
    query = query,
    flags = { case = case, fixed = flags.fixed == true, word = flags.word == true },
    emit_files = request.emit_files == true,
    enumerate_files = request.enumerate_files == true,
    allowed_paths = allowed_paths,
    max_items = math.min(request.max_items or limits.max_items, limits.max_items),
    generation = generation,
    session_id = session_id,
  }
end

local function command_for(executable, normalized)
  local argv = normalized.enumerate_files and {
    executable, "--files", "--null", "--no-config", "--no-require-git", "--no-ignore-global", "--no-ignore-exclude",
  } or {
    executable, "--json", "--line-number", "--column", "--no-config", "--no-require-git", "--no-ignore-global", "--no-ignore-exclude",
  }
  if normalized.policy.hidden == "include" then argv[#argv + 1] = "--hidden" end
  if normalized.policy.ignored == "include" then argv[#argv + 1] = "--no-ignore" end
  if normalized.flags.case == "smart" then argv[#argv + 1] = "--smart-case"
  elseif normalized.flags.case == "sensitive" then argv[#argv + 1] = "--case-sensitive"
  else argv[#argv + 1] = "--ignore-case" end
  if normalized.flags.fixed then argv[#argv + 1] = "--fixed-strings" end
  if normalized.flags.word then argv[#argv + 1] = "--word-regexp" end
  for _, pattern in ipairs(normalized.include) do
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = pattern
  end
  if normalized.scope_kind == "file" then
    local escaped = normalized.relative_scope:gsub("([\\%*%?%[%]{}!])", "\\%1")
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = escaped
  end
  for _, pattern in ipairs(normalized.exclude) do
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = "!" .. pattern
  end
  if normalized.policy.hidden == "exclude" then
    -- CLI glob inclusions can opt hidden paths back in, so reassert the
    -- independent hidden policy after user patterns (including dot-directories).
    for _, pattern in ipairs({ "!.*", "!**/.*", "!**/.*/**" }) do
      argv[#argv + 1] = "--glob"
      argv[#argv + 1] = pattern
    end
  end
  -- Files deliberately never treats .git metadata as workspace source, even
  -- when hidden files are included or ignore files are disabled.
  argv[#argv + 1] = "--glob"
  argv[#argv + 1] = "!**/.git/**"
  argv[#argv + 1] = "--glob"
  argv[#argv + 1] = "!/.git/"
  if not normalized.enumerate_files then
    argv[#argv + 1] = "-e"
    argv[#argv + 1] = normalized.query
  end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = normalized.scope_kind == "file" and "." or normalized.relative_scope
  return argv
end

local function session_key(workspace_id, session_id)
  return workspace_id .. "\0" .. session_id
end

local function escaped_message(value, limit)
  local safe = Resource.escape_display(tostring(value or "")):gsub("%s+", " ")
  if #safe > limit then safe = safe:sub(1, limit - 3) .. "..." end
  return safe
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "ripgrep provider options must be a table" end
  local limits = {}
  for name in pairs(DEFAULTS) do
    local value, err = bounded_option(opts, name)
    if not value then return nil, err end
    limits[name] = value
  end
  if limits.max_concurrent_per_workspace > limits.max_active_requests then
    return nil, "per-workspace concurrency cannot exceed total active request capacity"
  end
  if limits.max_batch_bytes > limits.max_result_bytes then limits.max_batch_bytes = limits.max_result_bytes end
  if opts.system ~= nil and type(opts.system) ~= "function" then return nil, "system must be a function" end
  if opts.executable ~= nil and type(opts.executable) ~= "function" then return nil, "executable must be a function" end
  return setmetatable({
    limits = limits,
    system = opts.system or vim.system,
    executable = opts.executable or function(name) return vim.fn.exepath(name) end,
    scope = Scope.new("workbench-rg-provider"),
    requests = {},
    sessions = {},
    next_request = 0,
    disposed = false,
  }, Provider)
end

function Provider:_live()
  if self.disposed or not self.scope.alive then
    return nil, error_value("provider_disposed", "ripgrep provider is disposed")
  end
  return true
end

function Provider:_executable()
  local ok, executable = pcall(self.executable, "rg")
  if not ok or type(executable) ~= "string" or executable == "" then return nil end
  return executable
end

function Provider:capabilities(context)
  local live = self:_live()
  if not live then return { state = "unsupported", reason = "provider_disposed", operations = {} } end
  if type(context) == "table" and context.workspace ~= nil then
    local roots = type(context.workspace) == "table" and context.workspace.roots or nil
    if type(roots) ~= "table" or #roots ~= 1 then
      return { state = "unsupported", reason = "multi_root_execution_not_implemented", operations = {} }
    end
  end
  if not self:_executable() then
    return { state = "unavailable", reason = "ripgrep executable 'rg' was not found on PATH", operations = {} }
  end
  if type(context) == "table" and type(context.workspace) == "table"
    and context.workspace.policy and context.workspace.policy.symlinks and context.workspace.policy.symlinks ~= "never" then
    return { state = "unsupported", reason = "symlink_policy_unsupported", operations = {} }
  end
  return { state = "ready", operations = { "search" } }
end

function Provider:_emit(request, event)
  if not request.active then return false end
  event.generation = request.generation
  event.request_id = request.id
  event.workspace_id = request.workspace_id
  event.workspace_generation = request.workspace_generation
  local ok, err = pcall(request.sink, event)
  if not ok then
    request.sink_error = tostring(err)
    request.scope:_record_error("ripgrep sink", err)
    request.scope:dispose()
    return nil
  end
  return true
end

function Provider:_remove(request)
  request.active = false
  self.requests[request.id] = nil
  if self.sessions[request.key] == request then self.sessions[request.key] = nil end
end

function Provider:_terminate(request)
  local process = request.process
  if process then pcall(process.kill, process, "sigterm") end
end

function Provider:_clear_input(request)
  request.chunks = {}
  request.chunk_head = 1
  request.chunk_tail = 0
  request.queue_bytes = 0
  request.current_chunk = nil
  request.current_offset = 1
  request.json_tail = ""
  request.pending_limit = nil
end

function Provider:_flush_batch(request)
  if #request.batch == 0 then return true end
  local items = request.batch
  request.batch = {}
  request.batch_bytes = 0
  return self:_emit(request, { kind = "batch", items = items })
end

function Provider:_mark_truncated(request, code, message)
  if request.limit_reason or not request.active then return false end
  request.limit_reason = code
  request.accept_output = false
  self:_flush_batch(request)
  self:_emit(request, {
    kind = "status",
    status = "partial",
    completeness = "truncated",
    reason = code,
    message = message,
    item_count = request.item_count,
  })
  self:_clear_input(request)
  self:_terminate(request)
  return true
end

function Provider:_fail_parse(request, code, message)
  if request.parse_error or not request.active then return false end
  request.parse_error = error_value(code, message, false, { partial = request.item_count > 0 })
  request.accept_output = false
  self:_flush_batch(request)
  self:_clear_input(request)
  self:_terminate(request)
  return true
end

function Provider:_add_item(request, item, accounted_bytes)
  if not request.active then return false end
  if request.item_count >= request.max_items then
    return self:_mark_truncated(request, "result_count_limit", "search results reached the configured item limit")
  end
  if request.result_bytes + accounted_bytes > self.limits.max_result_bytes then
    return self:_mark_truncated(request, "result_byte_limit", "search results reached the configured byte limit")
  end
  if accounted_bytes > self.limits.max_batch_bytes then
    return self:_mark_truncated(request, "item_batch_limit", "a single search result exceeded the configured batch byte limit")
  end
  if #request.batch >= self.limits.max_batch_items or request.batch_bytes + accounted_bytes > self.limits.max_batch_bytes then
    if not self:_flush_batch(request) then return false end
  end
  request.batch[#request.batch + 1] = item
  request.batch_bytes = request.batch_bytes + accounted_bytes
  request.item_count = request.item_count + 1
  request.result_bytes = request.result_bytes + accounted_bytes
  if #request.batch >= self.limits.max_batch_items or request.batch_bytes >= self.limits.max_batch_bytes then
    return self:_flush_batch(request)
  end
  return true
end

function Provider:_match_message(request, data)
  if type(data) ~= "table" or not is_integer(data.line_number, 1) or type(data.path) ~= "table"
    or type(data.lines) ~= "table" or type(data.submatches) ~= "table" then
    return self:_fail_parse(request, "invalid_match_record", "ripgrep emitted a malformed match record")
  end
  local submatch_count, max_index = 0, 0
  for key in pairs(data.submatches) do
    if not is_integer(key, 1) then return self:_fail_parse(request, "invalid_match_record", "ripgrep submatches were not a dense array") end
    submatch_count, max_index = submatch_count + 1, math.max(max_index, key)
  end
  if submatch_count ~= max_index then return self:_fail_parse(request, "invalid_match_record", "ripgrep submatches were not a dense array") end
  if submatch_count > self.limits.max_submatches_per_line then
    self:_mark_truncated(request, "submatch_limit", "a result line exceeded the submatch limit")
    return false
  end

  local raw_path, path_err = decode_raw(data.path, "match path")
  if not raw_path then return self:_fail_parse(request, "invalid_match_path", path_err) end
  local raw_line, line_err = decode_raw(data.lines, "match line")
  if not raw_line then return self:_fail_parse(request, "invalid_match_line", line_err) end
  local full_path = raw_path:sub(1, 1) == "/" and raw_path or vim.fs.joinpath(request.root, raw_path)
  local normalized_path, normalize_err = Resource.normalize_absolute_path(full_path)
  if not normalized_path then return self:_fail_parse(request, "invalid_match_path", normalize_err) end
  local inside, contains_err = RootPolicy.contains(request.root, normalized_path)
  if not inside then return self:_fail_parse(request, "path_outside_root", contains_err or "ripgrep returned a path outside the workspace") end
  local item_resource, resource_err = Resource.from_path(normalized_path, { workspace_id = request.workspace_id })
  if not item_resource then return self:_fail_parse(request, "invalid_match_path", resource_err) end

  local body = trim_line_ending(raw_line)
  local display_path = item_resource.display_path
  for index, submatch in ipairs(data.submatches) do
    if not request.active then return false end
    if type(submatch) ~= "table" or not is_integer(submatch.start, 0) or type(submatch.match) ~= "table" then
      return self:_fail_parse(request, "invalid_submatch", "ripgrep emitted a malformed submatch")
    end
    local match_bytes, match_err = decode_raw(submatch.match, "submatch")
    if not match_bytes then return self:_fail_parse(request, "invalid_submatch", match_err) end
    if submatch.start > #body or submatch.start + #match_bytes > #body then
      return self:_fail_parse(request, "invalid_submatch_range", "ripgrep byte range falls outside its reported line")
    end
    -- rg positions are byte offsets. Derive the exclusive end from the raw
    -- submatch bytes instead of assuming Unicode codepoints are byte units.
    local finish = submatch.start + #match_bytes
    if submatch["end"] ~= nil and (not is_integer(submatch["end"], 0) or submatch["end"] ~= finish) then
      return self:_fail_parse(request, "invalid_submatch_range", "ripgrep's reported byte range does not match its raw submatch bytes")
    end
    local location, location_err = Location.new(item_resource, {
      range = {
        start = { line = data.line_number - 1, character = submatch.start },
        finish = { line = data.line_number - 1, character = finish },
      },
      encoding = "utf-8",
    })
    if not location then return self:_fail_parse(request, "invalid_location", location_err) end
    local line_excerpt = excerpt(body, submatch.start + 1, self.limits.max_snippet_bytes)
    local match_excerpt = #match_bytes > self.limits.max_match_bytes and match_bytes:sub(1, self.limits.max_match_bytes) or match_bytes
    local label = Resource.escape_display(line_excerpt)
    local detail = display_path .. ":" .. tostring(data.line_number)
    local item = {
      id = table.concat({ "rg", request.workspace_id, tostring(request.generation), item_resource.uri,
        tostring(data.line_number), tostring(submatch.start), tostring(index) }, "\0"),
      kind = "match",
      label = label,
      detail = detail,
      location = location,
      payload = {
        provider_id = "rg",
        raw_path = raw_path,
        raw_line = body:sub(1, self.limits.max_snippet_bytes),
        match_bytes = match_excerpt,
        match_truncated = #match_bytes > #match_excerpt,
        line_number = data.line_number,
        byte_start = submatch.start,
        byte_end = finish,
        reported_byte_end = submatch["end"],
        occurrence = index,
      },
    }
    local size = #item.id + #item.label + #item.detail + #raw_path + #item.payload.raw_line + #match_excerpt + 160
    if not self:_add_item(request, item, size) then return false end
  end
  return true
end

function Provider:_file_path(request, raw_path, allowed)
  if type(raw_path) ~= "string" or raw_path == "" then return true end
  if #raw_path > self.limits.max_json_line_bytes then
    self:_mark_truncated(request, "file_path_limit", "ripgrep emitted an oversized file path")
    return false
  end
  local full_path = raw_path:sub(1, 1) == "/" and raw_path or vim.fs.joinpath(request.root, raw_path)
  local normalized_path, normalize_err = Resource.normalize_absolute_path(full_path)
  if not normalized_path then return self:_fail_parse(request, "invalid_file_record", normalize_err) end
  local inside, contains_err = RootPolicy.contains(request.root, normalized_path)
  if not inside then return self:_fail_parse(request, "path_outside_root", contains_err or "ripgrep returned a path outside the workspace") end
  if allowed and not allowed[normalized_path] then return true end
  request.file_count = request.file_count + 1
  if request.file_count > request.max_items then
    self:_mark_truncated(request, "file_limit", "ripgrep file enumeration reached its configured limit")
    return false
  end
  return self:_emit(request, { kind = "file", path = normalized_path }) ~= nil
end

function Provider:_json_line(request, line)
  if line == "" then return true end
  if #line > self.limits.max_json_line_bytes then
    self:_mark_truncated(request, "json_line_limit", "ripgrep output contained an oversized JSON record")
    return false
  end
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" or type(message.type) ~= "string" then
    return self:_fail_parse(request, "invalid_json", "ripgrep emitted invalid JSON Lines output")
  end
  if message.type == "match" then
    return self:_match_message(request, message.data)
  elseif message.type == "begin" and request.emit_files then
    local data = message.data
    if type(data) ~= "table" or type(data.path) ~= "table" then
      return self:_fail_parse(request, "invalid_file_record", "ripgrep emitted a malformed file record")
    end
    local raw_path, path_err = decode_raw(data.path, "file path")
    if not raw_path then return self:_fail_parse(request, "invalid_file_record", path_err) end
    return self:_file_path(request, raw_path)
  elseif message.type == "summary" then
    local stats = type(message.data) == "table" and message.data.stats or nil
    if type(stats) == "table" then
      request.stats = {
        matches = is_integer(stats.matches, 0) and stats.matches or nil,
        matched_lines = is_integer(stats.matched_lines, 0) and stats.matched_lines or nil,
        searches = is_integer(stats.searches, 0) and stats.searches or nil,
        searches_with_match = is_integer(stats.searches_with_match, 0) and stats.searches_with_match or nil,
      }
    end
  elseif message.type ~= "begin" and message.type ~= "end" and message.type ~= "context" then
    -- The JSON protocol may gain message types; unknown bounded records do
    -- not affect the match model.
    request.unknown_messages = request.unknown_messages + 1
  end
  return true
end

function Provider:_drain(request)
  if not request.active or request.draining then return end
  if request.limit_reason or request.parse_error then
    if request.exit_result then self:_finish(request, request.exit_result) end
    return
  end
  request.draining = true
  if request.pending_limit then
    local pending = request.pending_limit
    request.pending_limit = nil
    self:_mark_truncated(request, pending.code, pending.message)
  end
  local uv = vim.uv or vim.loop
  local started = uv.hrtime()
  local processed = 0
  while request.active and processed < self.limits.max_messages_per_slice do
    if not request.current_chunk then
      if request.chunk_head > request.chunk_tail then break end
      request.current_chunk = request.chunks[request.chunk_head]
      request.chunks[request.chunk_head] = nil
      request.chunk_head = request.chunk_head + 1
      request.current_offset = 1
      request.queue_bytes = math.max(0, request.queue_bytes - #request.current_chunk)
    end
    local chunk = request.current_chunk
    local start = request.current_offset
    local delimiter = request.enumerate_files and "\0" or "\n"
    local newline = chunk:find(delimiter, start, true)
    if newline then
      local fragment = chunk:sub(start, newline - 1)
      local line = request.json_tail .. fragment
      request.json_tail = ""
      request.current_offset = newline + 1
      if request.current_offset > #chunk then request.current_chunk = nil; request.current_offset = 1 end
      if #line > self.limits.max_json_line_bytes then
        self:_mark_truncated(request, "json_line_limit", "ripgrep output contained an oversized JSON record")
        break
      end
      local accepted
      if request.enumerate_files then
        accepted = self:_file_path(request, line, request.allowed_paths)
      else
        accepted = self:_json_line(request, line)
      end
      if not accepted then break end
      processed = processed + 1
    else
      local fragment = chunk:sub(start)
      request.json_tail = request.json_tail .. fragment
      request.current_chunk = nil
      request.current_offset = 1
      if #request.json_tail > self.limits.max_json_line_bytes then
        self:_mark_truncated(request, "json_line_limit", "ripgrep output contained an oversized JSON record")
        break
      end
    end
    if (uv.hrtime() - started) / 1000000 >= self.limits.max_slice_ms then break end
  end
  request.draining = false
  if not request.active then return end
  if not request.limit_reason and not request.parse_error and not request.exit_result and #request.batch > 0 then
    if not self:_flush_batch(request) or not request.active then return end
  end
  if request.limit_reason or request.parse_error then
    self:_flush_batch(request)
    if request.exit_result then self:_finish(request, request.exit_result) end
  elseif request.chunk_head <= request.chunk_tail or request.current_chunk then
    self:_schedule_drain(request)
  elseif request.exit_result then
    if #request.json_tail > 0 then
      local tail = request.json_tail
      request.json_tail = ""
      if #tail > self.limits.max_json_line_bytes then
        self:_mark_truncated(request, "json_line_limit", "ripgrep output contained an oversized JSON record")
      else
        local accepted
        if request.enumerate_files then accepted = self:_file_path(request, tail, request.allowed_paths)
        else accepted = self:_json_line(request, tail) end
        if not accepted then request.parse_error = request.parse_error or error_value("invalid_json", "ripgrep emitted invalid trailing output", false) end
      end
    end
    self:_finish(request, request.exit_result)
  end
end

function Provider:_schedule_drain(request)
  if not request.active or request.drain_scheduled then return end
  request.drain_scheduled = true
  local ticket, schedule_err = request.scope:schedule(function()
    request.drain_scheduled = false
    request.drain_ticket = nil
    self:_drain(request)
  end)
  if ticket then
    request.drain_ticket = ticket
  else
    request.drain_scheduled = false
    if request.active then
      request.schedule_error = schedule_err and schedule_err.message or "could not schedule ripgrep output processing"
      request.pending_limit = {
        code = "schedule_failed",
        message = escaped_message(request.schedule_error, self.limits.max_error_bytes),
      }
      request.accept_output = false
      self:_terminate(request)
    end
  end
end

function Provider:_enqueue_stdout(request, read_error, data)
  if not request.active or not request.accept_output then return end
  if read_error then
    request.stream_error = tostring(read_error)
    request.accept_output = false
    self:_terminate(request)
    return
  end
  if type(data) ~= "string" or data == "" then return end
  request.output_bytes = request.output_bytes + #data
  if request.output_bytes > self.limits.max_output_bytes then
    request.pending_limit = { code = "output_byte_limit", message = "ripgrep output exceeded the configured byte limit" }
    request.accept_output = false
    self:_terminate(request)
    return self:_schedule_drain(request)
  end
  local pending = request.queue_bytes + (request.current_chunk and (#request.current_chunk - request.current_offset + 1) or 0) + #request.json_tail
  if pending + #data > self.limits.max_pending_output_bytes then
    request.pending_limit = { code = "output_queue_limit", message = "search output exceeded the bounded parser queue" }
    request.accept_output = false
    self:_terminate(request)
    return self:_schedule_drain(request)
  end
  request.chunk_tail = request.chunk_tail + 1
  request.chunks[request.chunk_tail] = data
  request.queue_bytes = request.queue_bytes + #data
  if request.chunk_head > 128 and request.chunk_head > request.chunk_tail / 2 then
    local compact = {}
    local count = 0
    for index = request.chunk_head, request.chunk_tail do
      count = count + 1
      compact[count] = request.chunks[index]
    end
    request.chunks, request.chunk_head, request.chunk_tail = compact, 1, count
  end
  self:_schedule_drain(request)
end

function Provider:_append_stderr(request, read_error, data)
  if not request.active then return end
  if read_error then
    request.stderr_read_error = tostring(read_error)
    return
  end
  if type(data) ~= "string" or data == "" then return end
  request.stderr_bytes = request.stderr_bytes + #data
  local remaining = self.limits.max_stderr_bytes - #request.stderr
  if remaining > 0 then request.stderr = request.stderr .. data:sub(1, remaining) end
  if request.stderr_bytes > self.limits.max_stderr_bytes then request.stderr_truncated = true end
end

function Provider:_terminate_failure(request, code, message)
  request.parse_error = error_value(code, message, false, { partial = request.item_count > 0 })
  request.accept_output = false
  self:_flush_batch(request)
  self:_clear_input(request)
  self:_terminate(request)
end

function Provider:_finish(request, result)
  if not request.active or request.finished then return end
  request.finished = true
  if request.limit_reason then
    self:_flush_batch(request)
    self:_emit(request, {
      kind = "done",
      status = "partial",
      completeness = "truncated",
      total = request.item_count,
      bytes = request.result_bytes,
      limit_reason = request.limit_reason,
      stats = request.stats,
    })
  elseif request.parse_error or request.stream_error then
    self:_flush_batch(request)
    local problem = request.parse_error or error_value("stdout_read_error", escaped_message(request.stream_error, self.limits.max_error_bytes), true)
    self:_emit(request, { kind = "error", status = request.item_count > 0 and "partial" or "error", error = problem })
  else
    self:_flush_batch(request)
    local code = type(result) == "table" and result.code or nil
    local signal = type(result) == "table" and result.signal or 0
    if code == 0 or code == 1 then
      self:_emit(request, {
        kind = "done",
        status = "complete",
        completeness = "complete",
        total = request.item_count,
        bytes = request.result_bytes,
        stats = request.stats,
      })
    else
      local stderr = request.stderr
      if request.stderr_read_error then stderr = (stderr .. " " .. request.stderr_read_error):sub(-self.limits.max_stderr_bytes) end
      local lowered = stderr:lower()
      local error_code = (lowered:find("regex parse error", 1, true) or lowered:find("error parsing regex", 1, true)) and "invalid_regex"
        or code == 124 and "search_timeout"
        or "rg_failed"
      local detail = stderr ~= "" and escaped_message(stderr, self.limits.max_error_bytes) or "ripgrep exited with code " .. tostring(code) .. " signal " .. tostring(signal)
      if request.stderr_truncated then detail = detail .. " (stderr capped)" end
      self:_emit(request, {
        kind = "error",
        status = request.item_count > 0 and "partial" or "error",
        error = error_value(error_code, detail, error_code ~= "invalid_regex", {
          partial = request.item_count > 0,
          exit_code = code,
          signal = signal,
          stderr_truncated = request.stderr_truncated,
        }),
      })
    end
  end
  request.process = nil
  request.scope:dispose()
end

function Provider:_new_request(normalized, sink, key)
  self.next_request = self.next_request + 1
  local child, child_err = self.scope:child("search:" .. self.next_request)
  if not child then return nil, child_err end
  local request = {
    id = self.next_request,
    scope = child,
    provider = self,
    key = key,
    workspace_id = normalized.workspace_id,
    workspace_generation = normalized.workspace_generation,
    root = normalized.root,
    query = normalized.query,
    generation = normalized.generation,
    session_id = normalized.session_id,
    emit_files = normalized.emit_files,
    enumerate_files = normalized.enumerate_files,
    allowed_paths = normalized.allowed_paths,
    max_items = normalized.max_items,
    file_count = 0,
    sink = sink,
    active = true,
    accept_output = true,
    chunks = {},
    chunk_head = 1,
    chunk_tail = 0,
    queue_bytes = 0,
    current_offset = 1,
    json_tail = "",
    drain_scheduled = false,
    draining = false,
    output_bytes = 0,
    stderr = "",
    stderr_bytes = 0,
    stderr_truncated = false,
    batch = {},
    batch_bytes = 0,
    item_count = 0,
    result_bytes = 0,
    unknown_messages = 0,
  }
  self.requests[request.id] = request
  self.sessions[key] = request
  child:defer(function()
    request.active = false
    self:_terminate(request)
    request.process = nil
    self:_remove(request)
    self:_clear_input(request)
    request.batch = {}
    request.batch_bytes = 0
    request.stderr = ""
    request.stats = nil
    request.drain_scheduled = false
    request.drain_ticket = nil
    request.sink = nil
    request.query = nil
    request.root = nil
    request.allowed_paths = nil
    request.provider = nil
  end, "ripgrep-request:" .. request.id, "process")
  function request:cancel(reason)
    if not self.active or self.finished or self.cancelling then return false end
    self.cancelling = true
    self.provider:_emit(self, {
      kind = "status",
      status = "cancelled",
      completeness = "unknown",
      reason = escaped_message(type(reason) == "string" and reason or "cancelled", self.provider.limits.max_error_bytes),
      item_count = self.item_count,
    })
    return self.scope:dispose()
  end
  request.dispose = request.cancel
  return request
end

function Provider:start(request, sink)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  if type(sink) ~= "function" then return nil, error_value("invalid_sink", "search sink must be a function") end
  local normalized, normalize_err = normalize_request(request, self.limits)
  if not normalized then return nil, normalize_err end

  local key = session_key(normalized.workspace_id, normalized.session_id)
  local previous = self.sessions[key]
  if previous and previous.active then previous:cancel("superseded") end
  local active, workspace_active = 0, 0
  for _, current in pairs(self.requests) do
    if current.active then
      active = active + 1
      if current.workspace_id == normalized.workspace_id then workspace_active = workspace_active + 1 end
    end
  end
  if active >= self.limits.max_active_requests or workspace_active >= self.limits.max_concurrent_per_workspace then
    return nil, error_value("request_capacity", "ripgrep request capacity is full", true, { active = active, workspace_active = workspace_active })
  end

  local executable = self:_executable()
  if normalized.query ~= "" and not executable then
    return nil, error_value("missing_dependency", "ripgrep executable 'rg' was not found on PATH", true)
  end
  local handle, handle_err = self:_new_request(normalized, sink, key)
  if not handle then return nil, handle_err end
  if normalized.query == "" then
    handle.status = "empty"
    local ticket, schedule_err = handle.scope:schedule(function()
      if not handle.active then return end
      self:_emit(handle, { kind = "status", status = "empty", completeness = "complete", reason = "empty_query" })
      self:_emit(handle, { kind = "done", status = "complete", completeness = "complete", total = 0, bytes = 0 })
      handle.process = nil
      handle.scope:dispose()
    end)
    if not ticket then handle.scope:dispose(); return nil, schedule_err end
    return handle
  end

  local normalized_command, argv_err = command_for(executable, normalized)
  if not normalized_command then
    handle.scope:dispose()
    return nil, argv_err
  end
  self:_emit(handle, { kind = "status", status = "running", completeness = "unknown" })
  local okay, process_or_error = pcall(self.system, normalized_command, {
    cwd = normalized.root,
    text = false,
    timeout = self.limits.timeout_ms,
    stdout = function(read_error, data) self:_enqueue_stdout(handle, read_error, data) end,
    stderr = function(read_error, data) self:_append_stderr(handle, read_error, data) end,
  }, function(result)
    handle.process = nil
    if not handle.active then return end
    handle.exit_result = result
    self:_schedule_drain(handle)
  end)
  if not okay or type(process_or_error) ~= "table" then
    handle.process = nil
    local detail = escaped_message(okay and "ripgrep process could not be started" or process_or_error, self.limits.max_error_bytes)
    local error_result = error_value("spawn_failed", detail, true)
    self:_emit(handle, { kind = "error", status = "error", error = error_result })
    handle.scope:dispose()
    return nil, error_result
  end
  handle.process = process_or_error
  if handle.limit_reason or handle.parse_error or handle.stream_error then self:_terminate(handle) end
  handle.scope:defer(function()
    self:_terminate(handle)
    handle.process = nil
  end, "ripgrep-process:" .. handle.id, "process")
  return handle
end

function Provider:status()
  local active, by_workspace = 0, {}
  local requests = {}
  for _, request in pairs(self.requests) do
    if request.active then
      active = active + 1
      by_workspace[request.workspace_id] = (by_workspace[request.workspace_id] or 0) + 1
      requests[#requests + 1] = {
        id = request.id,
        workspace_id = request.workspace_id,
        generation = request.generation,
        session_id = request.session_id,
        process_active = request.process ~= nil,
        output_bytes = request.output_bytes,
        pending_bytes = request.queue_bytes + (request.current_chunk and (#request.current_chunk - request.current_offset + 1) or 0) + #request.json_tail,
        stderr_bytes = #request.stderr,
        items = request.item_count,
        retained_bytes = request.result_bytes,
        pending_callbacks = request.scope.pending_callbacks,
        limit_reason = request.limit_reason,
      }
    end
  end
  table.sort(requests, function(left, right) return left.id < right.id end)
  return { disposed = self.disposed, active_requests = active, workspaces = by_workspace, requests = requests, limits = vim.deepcopy(self.limits) }
end

function Provider:dispose()
  if self.disposed then return false end
  self.disposed = true
  self.scope:dispose()
  return true
end

M.Provider = Provider
return M
