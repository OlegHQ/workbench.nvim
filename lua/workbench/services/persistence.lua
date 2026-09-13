local M = {}
local Service = {}
Service.__index = Service

local SCHEMA = 1
local LEGACY_SCHEMA = 0
local MAX_SESSIONS = 32
local MAX_TOTAL_BYTES = 4 * 1024 * 1024
local MAX_RECORD_BYTES = 256 * 1024
local MAX_WORKSPACES = 16
local MAX_EXPANDED_PATHS = 256
local MAX_RELATIVE_PATH_BYTES = 4096
local MAX_QUERY_BYTES = 4096
local SERIAL = 0

local VIEW_NAMES = { files = true, search = true, outline = true, problems = true, git = true, buffers = true }
local SCOPE_NAMES = { workspace = true, folder = true, file = true, open_buffers = true }

local function failure(code, message, extra)
  local result = { code = code, message = message }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count, maximum = count + 1, math.max(maximum, key)
  end
  return count == maximum
end

local function integer(value, minimum, maximum)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end

local function bounded_string(value, maximum, label, allow_empty)
  if type(value) ~= "string" or #value > maximum or (not allow_empty and value == "") or value:find("%z") then
    return nil, failure("invalid_session", label .. " must be a string of at most " .. maximum .. " bytes")
  end
  return value
end

local function normalize_root(value)
  local root, err = bounded_string(value, MAX_RELATIVE_PATH_BYTES, "workspace root")
  if not root then return nil, err end
  if vim.fn.isabsolutepath(root) ~= 1 then return nil, failure("invalid_session", "workspace root must be absolute") end
  return vim.fs.normalize(root)
end

local function normalize_relative(value, label, allow_empty)
  local path, err = bounded_string(value, MAX_RELATIVE_PATH_BYTES, label, allow_empty)
  if not path then return nil, err end
  if path == "" then return "" end
  if path:match("^[/\\]") or path:match("^[A-Za-z]:") then return nil, failure("invalid_session", label .. " must be relative to its workspace root") end
  path = path:gsub("\\", "/")
  for part in path:gmatch("[^/]+") do
    if part == ".." or part == "." then return nil, failure("invalid_session", label .. " cannot traverse workspace boundaries") end
  end
  return path
end

local function normalize_search(search)
  if search == nil then return nil end
  if type(search) ~= "table" then return nil, failure("invalid_session", "search state must be a table") end
  local query, query_error = bounded_string(search.query or "", MAX_QUERY_BYTES, "search query", true)
  if not query then return nil, query_error end
  local flags = search.flags or {}
  if type(flags) ~= "table" then return nil, failure("invalid_session", "search flags must be a table") end
  local normalized_flags = {}
  for _, name in ipairs({ "fixed", "ignore_case", "smart_case", "whole_word", "hidden", "ignored" }) do
    local value = flags[name]
    if value ~= nil and type(value) ~= "boolean" then return nil, failure("invalid_session", "search flag " .. name .. " must be boolean") end
    normalized_flags[name] = value == true
  end
  local scope = search.scope or { kind = "workspace" }
  if type(scope) ~= "table" or not SCOPE_NAMES[scope.kind] then
    return nil, failure("invalid_session", "search scope kind is unsupported")
  end
  local normalized_scope = { kind = scope.kind }
  if scope.kind == "folder" or scope.kind == "file" then
    local path, path_error = normalize_relative(scope.path, "search scope path")
    if not path then return nil, path_error end
    normalized_scope.path = path
  end
  local result = { query = query, flags = normalized_flags, scope = normalized_scope }
  if type(search.selection) == "table" then
    local path, path_error = normalize_relative(search.selection.path, "search selection path")
    if not path then return nil, path_error end
    local line = search.selection.line
    if not integer(line, 0, 1000000000) then return nil, failure("invalid_session", "search selection line must be a non-negative integer") end
    result.selection = { path = path, line = line }
  elseif search.selection ~= nil then
    return nil, failure("invalid_session", "search selection must contain only a relative path and line")
  end
  return result
end

local function normalize_workspace(workspace)
  if type(workspace) ~= "table" then return nil, failure("invalid_session", "each workspace entry must be a table") end
  local root, root_error = normalize_root(workspace.root)
  if not root then return nil, root_error end
  local view = workspace.view or {}
  if type(view) ~= "table" then return nil, failure("invalid_session", "workspace view state must be a table") end
  local active = view.active or "files"
  if type(active) ~= "string" or not VIEW_NAMES[active] then return nil, failure("invalid_session", "active view is unsupported") end
  local normalized_view = { active = active }
  if view.selected_path ~= nil then
    local selected, selected_error = normalize_relative(view.selected_path, "view selection path")
    if not selected then return nil, selected_error end
    normalized_view.selected_path = selected
  end
  if view.expanded_paths ~= nil then
    if not dense_array(view.expanded_paths) or #view.expanded_paths > MAX_EXPANDED_PATHS then
      return nil, failure("session_limit", "expanded paths must be a dense list of at most " .. MAX_EXPANDED_PATHS .. " entries")
    end
    normalized_view.expanded_paths = {}
    local seen = {}
    for index, entry in ipairs(view.expanded_paths) do
      local relative, path_error = normalize_relative(entry, "expanded path")
      if not relative then return nil, path_error end
      if not seen[relative] then
        normalized_view.expanded_paths[#normalized_view.expanded_paths + 1] = relative
        seen[relative] = true
      end
    end
  else
    normalized_view.expanded_paths = {}
  end
  if view.scroll_line ~= nil then
    if not integer(view.scroll_line, 0, 1000000000) then return nil, failure("invalid_session", "view scroll line must be a non-negative integer") end
    normalized_view.scroll_line = view.scroll_line
  end
  local search, search_error = normalize_search(workspace.search)
  if search_error then return nil, search_error end
  return { root = root, view = normalized_view, search = search }
end

local function normalize_snapshot(snapshot)
  if type(snapshot) ~= "table" or not dense_array(snapshot.workspaces) or #snapshot.workspaces == 0 then
    return nil, failure("invalid_session", "session snapshot requires a non-empty dense workspaces list")
  end
  if #snapshot.workspaces > MAX_WORKSPACES then return nil, failure("session_limit", "session cannot contain more than " .. MAX_WORKSPACES .. " workspaces") end
  local result = { workspaces = {} }
  local roots = {}
  for index, workspace in ipairs(snapshot.workspaces) do
    local normalized, err = normalize_workspace(workspace)
    if not normalized then return nil, err end
    if roots[normalized.root] then return nil, failure("invalid_session", "workspace roots must be unique") end
    roots[normalized.root] = true
    result.workspaces[index] = normalized
  end
  return result
end

local function session_id_valid(value)
  return type(value) == "string" and #value >= 1 and #value <= 96 and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function generate_id(uv)
  SERIAL = SERIAL + 1
  local pid = uv.os_getpid and uv.os_getpid() or 0
  local hrtime = uv.hrtime and uv.hrtime() or math.floor(os.clock() * 1000000000)
  return string.format("%d-%d-%d-%d", pid, os.time(), hrtime, SERIAL)
end

local function stat_signature(stat)
  if not stat then return nil end
  return table.concat({ tostring(stat.type), tostring(stat.dev), tostring(stat.ino), tostring(stat.size), tostring(stat.mtime.sec), tostring(stat.mtime.nsec) }, ":")
end

local function missing_error(err)
  local message = tostring(err or ""):lower()
  return message == "" or message:find("enoent", 1, true) ~= nil or message:find("no such file", 1, true) ~= nil
end

local function valid_timestamp(value)
  if integer(value, 0, 9007199254740991) then return value end
end

local function schema_error(document)
  if type(document) ~= "table" then return failure("corrupt_state", "saved session root must be a JSON object") end
  if document.schema ~= SCHEMA and document.schema ~= LEGACY_SCHEMA then
    return failure("unsupported_version", "saved session schema is not supported", { schema = document.schema })
  end
end

function M.normalize_snapshot(snapshot)
  return normalize_snapshot(snapshot)
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, failure("invalid_options", "persistence options must be a table") end
  for key in pairs(opts) do
    if key ~= "state_dir" and key ~= "session_id" and key ~= "uv" and key ~= "max_sessions" and key ~= "max_total_bytes" and key ~= "max_record_bytes" then
      return nil, failure("invalid_options", "unknown persistence option: " .. tostring(key))
    end
  end
  local uv = opts.uv or vim.uv or vim.loop
  for _, name in ipairs({ "fs_lstat", "fs_stat", "fs_open", "fs_close", "fs_fstat", "fs_read", "fs_write", "fs_mkdir", "fs_rename", "fs_unlink", "fs_scandir", "fs_scandir_next" }) do
    if type(uv[name]) ~= "function" then return nil, failure("invalid_options", "libuv adapter is missing " .. name) end
  end
  local state_dir = opts.state_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "workbench", "sessions")
  if type(state_dir) ~= "string" or state_dir == "" or state_dir:find("%z") then
    return nil, failure("invalid_options", "state_dir must be a non-empty path")
  end
  local limits = {
    max_sessions = opts.max_sessions or MAX_SESSIONS,
    max_total_bytes = opts.max_total_bytes or MAX_TOTAL_BYTES,
    max_record_bytes = opts.max_record_bytes or MAX_RECORD_BYTES,
  }
  if not integer(limits.max_sessions, 1, MAX_SESSIONS) or not integer(limits.max_record_bytes, 1024, MAX_RECORD_BYTES)
    or not integer(limits.max_total_bytes, limits.max_record_bytes, MAX_TOTAL_BYTES) then
    return nil, failure("invalid_options", "persistence limits may only lower the supported limits")
  end
  local session_id = opts.session_id or generate_id(uv)
  if not session_id_valid(session_id) then return nil, failure("invalid_options", "session_id must be a short alphanumeric identifier") end
  SERIAL = SERIAL + 1
  return setmetatable({
    uv = uv,
    state_dir = vim.fs.normalize(state_dir),
    session_id = session_id,
    owner_token = table.concat({ session_id, tostring(uv.os_getpid and uv.os_getpid() or 0), tostring(uv.hrtime and uv.hrtime() or SERIAL) }, "-"),
    limits = limits,
    disposed = false,
  }, Service)
end

function Service:_live()
  if self.disposed then return nil, failure("service_disposed", "session persistence service has been disposed") end
  return true
end

function Service:_file_path(id)
  if not session_id_valid(id) then return nil, failure("invalid_session_id", "session id is not a valid stored-session identifier") end
  return vim.fs.joinpath(self.state_dir, "session-" .. id .. ".json")
end

function Service:_ensure_directory()
  local made = vim.fn.mkdir(self.state_dir, "p", 448)
  if made ~= 1 and made ~= 2 then return nil, failure("state_unavailable", "could not create the session state directory") end
  local stat, err = self.uv.fs_lstat(self.state_dir)
  if not stat then return nil, failure("state_unavailable", tostring(err or "session state directory is missing")) end
  if stat.type ~= "directory" then return nil, failure("unsafe_state_path", "session state path must be a real directory") end
  return true
end

function Service:_scan()
  local stat, stat_error = self.uv.fs_lstat(self.state_dir)
  if not stat then
    if missing_error(stat_error) then return {} end
    return nil, failure("state_unavailable", tostring(stat_error), { path = self.state_dir })
  end
  if stat.type ~= "directory" then return nil, failure("unsafe_state_path", "session state path must be a real directory") end
  local scan, scan_error = self.uv.fs_scandir(self.state_dir)
  if not scan then return nil, failure("state_unavailable", tostring(scan_error or "could not read the session directory")) end
  local records = {}
  while true do
    local name = self.uv.fs_scandir_next(scan)
    if not name then break end
    local id = name:match("^session%-([A-Za-z0-9_-]+)%.json$")
    if id then
      if #records >= self.limits.max_sessions + 128 then
        return nil, failure("session_limit", "session directory contains too many records to inspect safely")
      end
      local path = vim.fs.joinpath(self.state_dir, name)
      local file_stat, stat_error = self.uv.fs_lstat(path)
      if file_stat then
        records[#records + 1] = { id = id, name = name, path = path, stat = file_stat }
      elseif stat_error then
        return nil, failure("state_unavailable", tostring(stat_error), { path = path })
      end
    end
  end
  table.sort(records, function(left, right) return left.id < right.id end)
  return records
end

function Service:_read(path)
  local stat, stat_error = self.uv.fs_lstat(path)
  if not stat then
    local code = missing_error(stat_error) and "session_missing" or "state_unavailable"
    return nil, failure(code, tostring(stat_error or "saved session does not exist"), { path = path })
  end
  if stat.type ~= "file" then return nil, failure("unsafe_state_file", "saved session must be a regular file", { path = path }) end
  if stat.size > self.limits.max_record_bytes then return nil, failure("session_limit", "saved session exceeds the per-record byte cap", { path = path, size = stat.size }) end
  local fd, open_error = self.uv.fs_open(path, "r", 0)
  if not fd then return nil, failure("state_unavailable", tostring(open_error or "could not open saved session"), { path = path }) end
  local opened = self.uv.fs_fstat(fd)
  if not opened or opened.dev ~= stat.dev or opened.ino ~= stat.ino then
    self.uv.fs_close(fd)
    return nil, failure("stale_session_file", "saved session changed while opening", { path = path })
  end
  local chunks, offset = {}, 0
  while offset < stat.size do
    local bytes, read_error = self.uv.fs_read(fd, math.min(64 * 1024, stat.size - offset), offset)
    if not bytes or #bytes == 0 then
      self.uv.fs_close(fd)
      return nil, failure("state_read_failed", tostring(read_error or "saved session became shorter while reading"), { path = path })
    end
    chunks[#chunks + 1] = bytes
    offset = offset + #bytes
  end
  local after = self.uv.fs_fstat(fd)
  self.uv.fs_close(fd)
  if offset ~= stat.size or stat_signature(after) ~= stat_signature(stat) then
    return nil, failure("stale_session_file", "saved session changed while reading", { path = path })
  end
  return table.concat(chunks), stat
end

function Service:_decode(record)
  local contents, read_error = self:_read(record.path)
  if not contents then return nil, read_error end
  local okay, document = pcall(vim.json.decode, contents)
  if not okay then return nil, failure("corrupt_state", "saved session JSON is malformed", { path = record.path, cause = tostring(document) }) end
  local invalid_schema = schema_error(document)
  if invalid_schema then return nil, invalid_schema end
  if document.schema == SCHEMA then
    if document.session_id ~= record.id then return nil, failure("corrupt_state", "saved session id does not match its filename", { path = record.path }) end
    if type(document.owner_token) ~= "string" or type(document.snapshot) ~= "table" then
      return nil, failure("corrupt_state", "saved session is missing its owner or snapshot", { path = record.path })
    end
    local _, snapshot_error = normalize_snapshot(document.snapshot)
    if snapshot_error then return nil, failure("corrupt_state", "saved session snapshot is invalid", { path = record.path, cause = snapshot_error.message }) end
  end
  return document, nil, contents, record.stat
end

function Service:_atomic_write(path, contents, expected_signature)
  local existing, existing_error = self.uv.fs_lstat(path)
  if existing_error and existing_error:find("ENOENT", 1, true) == nil then
    return nil, failure("state_unavailable", tostring(existing_error), { path = path })
  end
  if existing and existing.type ~= "file" then return nil, failure("unsafe_state_file", "session target must be a regular file", { path = path }) end
  if stat_signature(existing) ~= expected_signature then return nil, failure("concurrent_write", "session file changed since it was inspected", { path = path }) end
  local temp = path .. ".tmp-" .. self.owner_token:gsub("[^A-Za-z0-9_-]", "-") .. "-" .. tostring(self.uv.hrtime and self.uv.hrtime() or SERIAL)
  local fd, open_error = self.uv.fs_open(temp, "wx", 384)
  if not fd then return nil, failure("state_write_failed", tostring(open_error or "could not create session temporary file"), { path = temp }) end
  local offset, write_error = 0, nil
  while offset < #contents do
    local written, err = self.uv.fs_write(fd, contents:sub(offset + 1), offset)
    if not written or written <= 0 then write_error = err or "session temporary write made no progress"; break end
    offset = offset + written
  end
  if not write_error and self.uv.fs_fsync then
    local synced, err = self.uv.fs_fsync(fd)
    if synced == nil then write_error = err or "session temporary fsync failed" end
  end
  local closed, close_error = self.uv.fs_close(fd)
  if not write_error and closed == nil then write_error = close_error or "session temporary close failed" end
  if not write_error and self.uv.fs_chmod then
    local changed, err = self.uv.fs_chmod(temp, 384)
    if changed == nil then write_error = err or "session temporary chmod failed" end
  end
  if write_error then
    self.uv.fs_unlink(temp)
    return nil, failure("state_write_failed", tostring(write_error), { path = temp })
  end
  local staged, staged_error = self:_read(temp)
  if not staged then self.uv.fs_unlink(temp); return nil, staged_error end
  if staged ~= contents then
    self.uv.fs_unlink(temp)
    return nil, failure("state_write_failed", "session temporary file did not verify", { path = temp })
  end
  local current, current_error = self.uv.fs_lstat(path)
  if current_error and current_error:find("ENOENT", 1, true) == nil then
    self.uv.fs_unlink(temp)
    return nil, failure("state_unavailable", tostring(current_error), { path = path })
  end
  if stat_signature(current) ~= expected_signature then
    self.uv.fs_unlink(temp)
    return nil, failure("concurrent_write", "session file changed before atomic replacement", { path = path })
  end
  local renamed, rename_error = self.uv.fs_rename(temp, path)
  if not renamed then
    self.uv.fs_unlink(temp)
    return nil, failure("state_write_failed", tostring(rename_error or "could not atomically replace session file"), { path = path })
  end
  return true
end

function Service:save(snapshot)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local normalized, normalize_error = normalize_snapshot(snapshot)
  if not normalized then return nil, normalize_error end
  local directory_ok, directory_error = self:_ensure_directory()
  if not directory_ok then return nil, directory_error end
  local records, scan_error = self:_scan()
  if not records then return nil, scan_error end
  local target, path_error = self:_file_path(self.session_id)
  if not target then return nil, path_error end
  local own
  local total_bytes = 0
  for _, record in ipairs(records) do
    total_bytes = total_bytes + (record.stat.size or 0)
    if record.id == self.session_id then own = record end
  end
  if #records >= self.limits.max_sessions and not own then
    return nil, failure("session_limit", "session history reached its record cap; delete an old session explicitly")
  end
  local expected_signature = nil
  local created_at = os.time()
  if own then
    if own.stat.type ~= "file" then return nil, failure("unsafe_state_file", "session target must be a regular file", { path = target }) end
    local document, decode_error = self:_decode(own)
    if not document then return nil, decode_error end
    if document.owner_token ~= self.owner_token then
      return nil, failure("session_conflict", "another Neovim session owns this session file", { path = target })
    end
    expected_signature = stat_signature(own.stat)
    total_bytes = total_bytes - own.stat.size
    created_at = document.created_at or created_at
  end
  local document = {
    schema = SCHEMA,
    session_id = self.session_id,
    owner_token = self.owner_token,
    process_id = self.uv.os_getpid and self.uv.os_getpid() or 0,
    created_at = created_at,
    written_at = os.time(),
    snapshot = normalized,
  }
  local okay, encoded = pcall(vim.json.encode, document)
  if not okay then return nil, failure("invalid_session", "session state could not be encoded", { cause = tostring(encoded) }) end
  if #encoded > self.limits.max_record_bytes then return nil, failure("session_limit", "session exceeds the per-record byte cap", { bytes = #encoded }) end
  if total_bytes + #encoded > self.limits.max_total_bytes then return nil, failure("session_limit", "session history would exceed the total byte cap") end
  local saved, save_error = self:_atomic_write(target, encoded, expected_signature)
  if not saved then return nil, save_error end
  return { id = self.session_id, path = target, bytes = #encoded, written_at = document.written_at, workspace_count = #normalized.workspaces }
end

local function list_record(self, record)
  local document, err, contents = self:_decode(record)
  if not document then
    return { id = record.id, state = err.code == "unsupported_version" and "unsupported" or "corrupt", bytes = record.stat.size, error = err }
  end
  local workspace_count = document.schema == SCHEMA and #document.snapshot.workspaces or 1
  local created_at = valid_timestamp(document.created_at)
  local written_at = valid_timestamp(document.written_at) or created_at
  return {
    id = record.id,
    state = "available",
    schema = document.schema,
    created_at = created_at,
    written_at = written_at,
    workspace_count = workspace_count,
    bytes = #contents,
  }
end

function Service:list()
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local records, scan_error = self:_scan()
  if not records then return nil, scan_error end
  if #records > self.limits.max_sessions then return nil, failure("session_limit", "session history exceeds the configured record cap") end
  local total_bytes, result = 0, {}
  for _, record in ipairs(records) do
    total_bytes = total_bytes + (record.stat.size or 0)
    result[#result + 1] = list_record(self, record)
  end
  table.sort(result, function(left, right)
    if (left.written_at or 0) == (right.written_at or 0) then return left.id > right.id end
    return (left.written_at or 0) > (right.written_at or 0)
  end)
  return result, { records = #result, bytes = total_bytes, max_records = self.limits.max_sessions, max_bytes = self.limits.max_total_bytes }
end

local function migrate_legacy(document)
  local root = document.root
  local search
  if type(document.query) == "string" then
    search = {
      query = document.query,
      flags = document.flags or {},
      scope = type(document.scope) == "table" and document.scope or { kind = "workspace" },
    }
  end
  local workspace = { root = root, view = document.view or { active = "files" }, search = search }
  return { workspaces = { workspace } }
end

function Service:restore(id)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local path, path_error = self:_file_path(id)
  if not path then return nil, path_error end
  local record_stat, stat_error = self.uv.fs_lstat(path)
  if not record_stat then
    local code = missing_error(stat_error) and "session_missing" or "state_unavailable"
    return nil, failure(code, tostring(stat_error or "saved session does not exist"), { id = id })
  end
  local document, decode_error = self:_decode({ id = id, path = path, stat = record_stat })
  if not document then return nil, decode_error end
  local snapshot
  local migrated_from
  if document.schema == LEGACY_SCHEMA then
    snapshot, decode_error = normalize_snapshot(migrate_legacy(document))
    migrated_from = LEGACY_SCHEMA
  else
    snapshot, decode_error = normalize_snapshot(document.snapshot)
  end
  if not snapshot then return nil, decode_error or failure("corrupt_state", "saved session snapshot is invalid") end
  for _, workspace in ipairs(snapshot.workspaces) do
    local stat = self.uv.fs_lstat(workspace.root)
    workspace.available = stat ~= nil and stat.type == "directory"
    if not workspace.available then workspace.unavailable_reason = "workspace root is missing or unavailable" end
    if workspace.search then
      workspace.search.result_state = "stale"
      workspace.search.rerun_required = true
    end
  end
  return {
    id = id,
    schema = SCHEMA,
    migrated_from = migrated_from,
    created_at = valid_timestamp(document.created_at),
    written_at = valid_timestamp(document.written_at) or valid_timestamp(document.created_at),
    snapshot = snapshot,
    automatic_execution = false,
  }
end

function Service:delete(id)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local path, path_error = self:_file_path(id)
  if not path then return nil, path_error end
  local stat, stat_error = self.uv.fs_lstat(path)
  if not stat then
    local code = missing_error(stat_error) and "session_missing" or "state_unavailable"
    return nil, failure(code, tostring(stat_error or "saved session does not exist"), { id = id })
  end
  if stat.type ~= "file" then return nil, failure("unsafe_state_file", "only regular session files can be deleted", { path = path }) end
  local removed, remove_error = self.uv.fs_unlink(path)
  if not removed then return nil, failure("state_delete_failed", tostring(remove_error or "could not remove saved session"), { path = path }) end
  return true
end

function Service:status()
  return { disposed = self.disposed, session_id = self.session_id, state_dir = self.state_dir }
end

function Service:dispose()
  if self.disposed then return false end
  self.disposed = true
  self.owner_token = nil
  return true
end

return M
