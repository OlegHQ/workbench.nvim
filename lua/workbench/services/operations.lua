local Scope = require("workbench.core.scope")
local Resource = require("workbench.core.resource")
local root_policy = require("workbench.core.root_policy")

local M = {}
local Service = {}
Service.__index = Service

local MAX_COPY_BYTES = 64 * 1024 * 1024
local COPY_CHUNK_BYTES = 64 * 1024
local MAX_ACTIVE_PLANS = 32
local MAX_RETAINED_PLANS = 32

local function error_value(code, message, extra)
  local result = { code = code, message = message }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

local function normalize(path)
  return Resource.normalize_absolute_path(path)
end

local function same_stat(left, right)
  if not left or not right then return left == right end
  return left.type == right.type and left.dev == right.dev and left.ino == right.ino
    and left.mode == right.mode and left.size == right.size
    and left.mtime.sec == right.mtime.sec and left.mtime.nsec == right.mtime.nsec
    and left.ctime.sec == right.ctime.sec and left.ctime.nsec == right.ctime.nsec
end

local function stat_copy(stat)
  if not stat then return nil end
  return {
    type = stat.type, dev = stat.dev, ino = stat.ino, mode = stat.mode, size = stat.size,
    mtime = { sec = stat.mtime.sec, nsec = stat.mtime.nsec },
    ctime = { sec = stat.ctime.sec, nsec = stat.ctime.nsec },
  }
end

local function lstat(uv, path)
  local stat, err = uv.fs_lstat(path)
  if not stat then return nil, err end
  return stat_copy(stat)
end

local function path_is_ancestor(parent, path)
  if path == parent then return true end
  return path:sub(1, #parent + 1) == parent:gsub("[/\\]+$", "") .. package.config:sub(1, 1)
end

local function path_components(relative)
  local result = {}
  for part in relative:gmatch("[^/\\]+") do result[#result + 1] = part end
  return result
end

local function safe_basename(value)
  return type(value) == "string" and value ~= "" and value ~= "." and value ~= ".."
    and not value:find("[/\\%z]")
end

local function path_signature(stat)
  if not stat then return "absent" end
  return table.concat({ stat.type or "?", stat.dev or "?", stat.ino or "?", stat.mode or "?", stat.size or "?",
    stat.mtime.sec or "?", stat.mtime.nsec or "?", stat.ctime.sec or "?", stat.ctime.nsec or "?" }, ":")
end

function M.new(opts)
  opts = opts or {}
  local uv = opts.uv or vim.uv or vim.loop
  for _, name in ipairs({ "fs_lstat", "fs_stat", "fs_access", "fs_open", "fs_close", "fs_fstat", "fs_read", "fs_write", "fs_mkdir", "fs_link", "fs_unlink" }) do
    if type(uv[name]) ~= "function" then return nil, "filesystem operation is unavailable: " .. name end
  end
  if opts.trash ~= nil and (type(opts.trash) ~= "table" or type(opts.trash.preview) ~= "function" or type(opts.trash.move) ~= "function") then
    return nil, "trash adapter must implement preview(path, preimage) and move(reviewed_plan)"
  end
  return setmetatable({
    uv = uv,
    trash = opts.trash,
    lsp = opts.lsp,
    buffers = opts.buffers or vim.api,
    input = opts.input or vim.ui.input,
    scope = Scope.new("workbench-operations"),
    plans = {},
    next_id = 0,
    disposed = false,
    active = 0,
    next_temp = 0,
  }, Service)
end

function Service:_live()
  if self.disposed or not self.scope.alive then return nil, error_value("service_disposed", "filesystem operation service is disposed") end
  return true
end

function Service:_workspace(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.id) ~= "string" or type(snapshot.generation) ~= "number"
    or type(snapshot.roots) ~= "table" or #snapshot.roots ~= 1 or type(snapshot.roots[1].path) ~= "string" then
    return nil, error_value("workspace_unavailable", "filesystem operations require a single-root workspace snapshot")
  end
  local root, err = normalize(snapshot.roots[1].path)
  if not root then return nil, error_value("invalid_root", err) end
  return root
end

function Service:_inspect_path(root, path, allow_missing)
  local normalized, normalize_error = normalize(path)
  if not normalized then return nil, error_value("invalid_path", normalize_error) end
  local inside, contains_error = root_policy.contains(root, normalized)
  if not inside then return nil, error_value("outside_root", contains_error or "path is outside the selected workspace") end
  if normalized == root then return nil, error_value("root_operation_refused", "the workspace root itself cannot be changed") end
  local relative = vim.fs.relpath(root, normalized)
  local components = path_components(relative)
  if #components == 0 then return nil, error_value("invalid_path", "path does not name a workspace child") end
  local current = root
  for index, component in ipairs(components) do
    current = vim.fs.joinpath(current, component)
    local final = index == #components
    local stat, stat_error = lstat(self.uv, current)
    if not stat then
      if final and allow_missing then return { path = normalized, parent = vim.fs.dirname(normalized), stat = nil } end
      return nil, error_value("source_missing", "path no longer exists: " .. normalized, { cause = tostring(stat_error) })
    end
    if stat.type == "link" then
      return nil, error_value("symlink_unsupported", "filesystem operations do not follow or mutate symlinks", { path = current })
    end
    if not final and stat.type ~= "directory" then
      return nil, error_value("parent_not_directory", "a path parent is not a directory", { path = current })
    end
    if final then return { path = normalized, parent = vim.fs.dirname(normalized), stat = stat } end
  end
end

function Service:_check_parent(root, path)
  local normalized, normalize_error = normalize(path)
  if not normalized then return nil, error_value("invalid_parent", normalize_error) end
  if normalized == root then
    local stat, stat_error = lstat(self.uv, root)
    if not stat then return nil, error_value("parent_missing", "workspace root is unavailable", { cause = tostring(stat_error) }) end
    if stat.type ~= "directory" then return nil, error_value("parent_not_directory", "workspace root is not a directory") end
    local okay, access_error = self.uv.fs_access(root, "W")
    if not okay then return nil, error_value("permission_denied", "workspace root is not writable", { path = root, cause = tostring(access_error) }) end
    return { path = root, stat = stat }
  end
  local parent, err = self:_inspect_path(root, path, false)
  if not parent then return nil, err end
  if not parent.stat or parent.stat.type ~= "directory" then
    return nil, error_value("parent_not_directory", "destination parent is not an existing directory", { path = path })
  end
  local okay, access_error = self.uv.fs_access(path, "W")
  if not okay then return nil, error_value("permission_denied", "destination directory is not writable", { path = path, cause = tostring(access_error) }) end
  return parent
end

function Service:_find_buffer(path)
  for _, buffer in ipairs(self.buffers.nvim_list_bufs()) do
    if self.buffers.nvim_buf_is_valid(buffer) then
      local name = self.buffers.nvim_buf_get_name(buffer)
      local normalized = name ~= "" and normalize(name) or nil
      if normalized == path then return buffer end
    end
  end
end

function Service:_modified_buffers(paths)
  for _, path in ipairs(paths) do
    local buffer = self:_find_buffer(path)
    if buffer and self.buffers.nvim_get_option_value("modified", { buf = buffer }) then
      return nil, error_value("dirty_buffer", "save or discard the modified buffer before changing this filesystem resource", { path = path, bufnr = buffer })
    end
  end
  return true
end

function Service:_operation_paths(root, kind, args)
  args = args or {}
  if kind == "create_file" or kind == "create_directory" then
    local parent, parent_error = normalize(args.parent)
    if not parent then return nil, error_value("invalid_parent", parent_error) end
    if not safe_basename(args.name) then return nil, error_value("invalid_name", "new item name must be one path component") end
    local parent_info, err = self:_check_parent(root, parent)
    if not parent_info then return nil, err end
    local target = vim.fs.joinpath(parent, args.name)
    local target_info, target_error = self:_inspect_path(root, target, true)
    if not target_info then return nil, target_error end
    if target_info.stat then return nil, error_value("destination_exists", "destination already exists; nothing was changed", { path = target }) end
    return { target = target, target_before = nil, parent = parent, parent_before = parent_info.stat }
  end

  if kind == "trash" and not self.trash then
    return nil, error_value("trash_unavailable", "recoverable trash is unavailable; permanent deletion is not exposed")
  end
  if kind ~= "rename" and kind ~= "move" and kind ~= "copy" and kind ~= "trash" then
    return nil, error_value("unsupported_operation", "unknown filesystem operation: " .. tostring(kind))
  end
  local source, source_error = normalize(args.source)
  if not source then return nil, error_value("invalid_source", source_error) end
  local source_info, inspect_error = self:_inspect_path(root, source, false)
  if not source_info then return nil, inspect_error end
  if source_info.stat.type ~= "file" then
    if kind == "move" and source_info.stat.type == "directory" then
      local destination = normalize(args.destination)
      if destination and path_is_ancestor(source, destination) then
        return nil, error_value("cyclic_move", "a directory cannot be moved into itself or a descendant")
      end
    end
    return nil, error_value("unsupported_source_type", "only regular files can be renamed, moved, copied, or trashed in this release", { path = source, type = source_info.stat.type })
  end
  if source_info.stat.size > MAX_COPY_BYTES and kind == "copy" then
    return nil, error_value("copy_limit", "file exceeds the bounded 64 MiB copy limit", { size = source_info.stat.size })
  end
  local clean, dirty_error = self:_modified_buffers({ source })
  if not clean then return nil, dirty_error end
  if (kind == "rename" or kind == "move") and not self.lsp then
    local buffer = self:_find_buffer(source)
    local clients = buffer and vim.lsp and type(vim.lsp.get_clients) == "function" and vim.lsp.get_clients({ bufnr = buffer }) or {}
    if #clients > 0 then return nil, error_value("lsp_file_operations_unavailable", "an LSP client is attached but file-operation ordering is unavailable; configure the Workbench LSP provider") end
  end

  if kind == "trash" then
    local okay, review, trash_error = pcall(self.trash.preview, self.trash, source, source_info.stat)
    if not okay then trash_error, review = review, nil end
    if type(review) ~= "table" then return nil, error_value("trash_plan_failed", tostring(trash_error or "trash adapter returned no review record")) end
    return { source = source, source_before = source_info.stat, trash_review = vim.deepcopy(review) }
  end

  local target
  if kind == "rename" then
    if not safe_basename(args.name) then return nil, error_value("invalid_name", "new name must be one path component") end
    target = vim.fs.joinpath(vim.fs.dirname(source), args.name)
  elseif kind == "move" then
    local destination, destination_error = normalize(args.destination)
    if not destination then return nil, error_value("invalid_destination", destination_error) end
    local destination_info, err = self:_inspect_path(root, destination, false)
    if not destination_info then return nil, err end
    if destination_info.stat.type ~= "directory" then return nil, error_value("destination_not_directory", "move destination must be an existing directory") end
    local writable, access_error = self:_check_parent(root, destination)
    if not writable then return nil, access_error end
    target = vim.fs.joinpath(destination, vim.fs.basename(source))
  elseif kind == "copy" then
    local destination, destination_error = normalize(args.destination)
    if not destination then return nil, error_value("invalid_destination", destination_error) end
    target = destination
  end
  if target then
    target = normalize(target)
    local inside, contains_error = root_policy.contains(root, target)
    if not inside then return nil, error_value("outside_root", contains_error or "destination is outside the selected workspace") end
    if target == source then return nil, error_value("same_path", "source and destination are identical") end
    if kind == "move" and path_is_ancestor(source, target) then
      return nil, error_value("cyclic_move", "a directory cannot be moved into itself or a descendant")
    end
    local parent, parent_error = self:_check_parent(root, vim.fs.dirname(target))
    if not parent then return nil, parent_error end
    local target_info, target_error = self:_inspect_path(root, target, true)
    if not target_info then return nil, target_error end
    local same_file = target_info.stat ~= nil and target_info.stat.dev == source_info.stat.dev and target_info.stat.ino == source_info.stat.ino
    local case_only = false
    if same_file then
      local listed, names = pcall(vim.fn.readdir, vim.fs.dirname(target))
      if not listed then return nil, error_value("destination_ambiguous", "cannot distinguish a case-only rename from an existing hard link") end
      case_only = not vim.tbl_contains(names, vim.fs.basename(target))
    end
    if target_info.stat and not case_only then
      return nil, error_value("destination_exists", "destination already exists; nothing was changed", { path = target })
    end
    if kind == "copy" and target_info.stat then
      return nil, error_value("destination_exists", "copy destination already exists; nothing was changed", { path = target })
    end
    local paths_clean, buffer_error = self:_modified_buffers({ target })
    if not paths_clean then return nil, buffer_error end
    return {
      source = source, source_before = source_info.stat, target = target,
      target_before = target_info.stat, parent = vim.fs.dirname(target), parent_before = parent.stat,
      case_only = case_only,
    }
  end
end

local function plan_review(plan)
  local lines = { "Operation: " .. plan.operation }
  if plan.source then lines[#lines + 1] = "From: " .. plan.source end
  if plan.target then lines[#lines + 1] = "To: " .. plan.target end
  if plan.trash_review then lines[#lines + 1] = "Recoverable destination: " .. tostring(plan.trash_review.display_target or "provided by trash adapter") end
  lines[#lines + 1] = "Preimage: " .. (plan.source_before and path_signature(plan.source_before) or "not applicable")
  if plan.lsp and plan.lsp.edit then
    lines[#lines + 1] = "LSP workspace edits (reviewed before filesystem step):"
    for _, item in ipairs(plan.lsp.review or {}) do lines[#lines + 1] = item end
  end
  local result = {}
  for _, line in ipairs(lines) do if line then result[#result + 1] = line end end
  return table.concat(result, "\n")
end

function Service:_locked(paths)
  for _, record in pairs(self.plans) do
    if record.plan.state ~= "applied" and record.plan.state ~= "failed" and record.plan.state ~= "partial" and record.plan.state ~= "cancelled" then
      for _, held in ipairs(record.paths) do
        for _, candidate in ipairs(paths) do
          if path_is_ancestor(held, candidate) or path_is_ancestor(candidate, held) then return record.plan.id end
        end
      end
    end
  end
end

function Service:_release_record(record)
  if not record then return end
  record.paths, record.data, record.workspace, record.args = {}, nil, nil, nil
  local plan = record.plan
  if plan then
    plan.workspace, plan.args, plan.lsp = nil, nil, nil
    plan.trash_review, plan.affected_resources, plan.steps = nil, nil, nil
    plan.source_before, plan.target_before, plan.parent_before, plan.preconditions = nil, nil, nil, nil
  end
  local terminal = {}
  for id, candidate in pairs(self.plans) do
    local state = candidate.plan.state
    if state == "applied" or state == "failed" or state == "partial" or state == "cancelled" then
      terminal[#terminal + 1] = { id = id, ordinal = tonumber(id:match("(%d+)$")) or 0 }
    end
  end
  if #terminal > MAX_RETAINED_PLANS then
    table.sort(terminal, function(left, right) return left.ordinal < right.ordinal end)
    for index = 1, #terminal - MAX_RETAINED_PLANS do self.plans[terminal[index].id] = nil end
  end
end

function Service:_finish_prepare(plan, data, callback)
  local active_plans = 0
  for _, record in pairs(self.plans) do
    local state = record.plan.state
    if state ~= "applied" and state ~= "failed" and state ~= "partial" and state ~= "cancelled" then active_plans = active_plans + 1 end
  end
  if active_plans >= MAX_ACTIVE_PLANS then
    plan.state = "failed"
    callback(nil, error_value("operation_limit", "too many reviewed filesystem operations are still active; cancel or finish one first"))
    return
  end
  local paths = {}
  if data.source then paths[#paths + 1] = data.source end
  if data.target then paths[#paths + 1] = data.target end
  for _, path in ipairs(data.lsp_preimages and vim.tbl_keys(data.lsp_preimages) or {}) do paths[#paths + 1] = path end
  local conflict = self:_locked(paths)
  if conflict then
    plan.state = "failed"
    callback(nil, error_value("operation_overlap", "another reviewed operation owns an overlapping path", { plan_id = conflict }))
    return
  end
  self.next_id = self.next_id + 1
  plan.id = "operation-" .. tostring(self.next_id)
  plan.workspace_id = plan.workspace.id
  plan.workspace_generation = plan.workspace.generation
  plan.operation = plan._kind
  plan.source = data.source
  plan.target = data.target
  plan.source_before = stat_copy(data.source_before)
  plan.target_before = stat_copy(data.target_before)
  plan.parent = data.parent
  plan.parent_before = stat_copy(data.parent_before)
  plan.case_only = data.case_only == true
  plan.trash_review = data.trash_review
  plan.preconditions = { source = path_signature(data.source_before), target = path_signature(data.target_before), parent = path_signature(data.parent_before) }
  if plan.operation == "move" or plan.operation == "rename" then
    plan.steps = { "link_destination_exclusively", "unlink_source" }
  elseif plan.operation == "copy" then
    plan.steps = { "read_verified_source", "create_destination_exclusively", "write_and_sync", "verify_destination" }
  elseif plan.operation == "trash" then
    plan.steps = { "recoverable_trash_adapter" }
  else
    plan.steps = { "create_exclusively" }
  end
  plan.affected_resources = { source = plan.source, target = plan.target }
  plan.lsp = data.lsp
  plan.review = plan_review(plan)
  plan.state = "validated"
  local paths_to_hold = {}
  if data.source then paths_to_hold[#paths_to_hold + 1] = data.source end
  if data.target then paths_to_hold[#paths_to_hold + 1] = data.target end
  local frozen_data = {}
  for key, value in pairs(data) do frozen_data[key] = key == "lsp" and value or vim.deepcopy(value) end
  self.plans[plan.id] = {
    plan = plan,
    paths = paths_to_hold,
    data = frozen_data,
    workspace = vim.deepcopy(plan.workspace),
    args = vim.deepcopy(plan.args),
    review = plan.review,
    operation = plan.operation,
  }
  callback(plan)
end

function Service:prepare(snapshot, kind, args, callback)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  if type(callback) ~= "function" then return nil, error_value("invalid_callback", "operation preparation requires a callback") end
  local root, root_error = self:_workspace(snapshot)
  if not root then return nil, root_error end
  local data, data_error = self:_operation_paths(root, kind, args)
  if not data then return nil, data_error end
  local plan = { state = "draft", workspace = vim.deepcopy(snapshot), _kind = kind, args = vim.deepcopy(args or {}) }
  local function complete(prepared, err)
    if not self.scope.alive or plan.state == "cancelled" then return end
    if err then callback(nil, err); return end
    if prepared.lsp then
      prepared.lsp_preimages = {}
      for _, path in ipairs(prepared.lsp.affected_paths or {}) do
        local inside, contains_error = root_policy.contains(root, path)
        if not inside then callback(nil, error_value("lsp_edit_outside_root", contains_error or "LSP rename edit leaves the selected workspace", { path = path })); return end
        local info, inspect_err = self:_inspect_path(root, path, false)
        if not info then callback(nil, inspect_err); return end
        if info.stat.type ~= "file" then callback(nil, error_value("lsp_edit_unsupported_resource", "LSP rename edits may target regular files only", { path = path })); return end
        local clean, dirty_error = self:_modified_buffers({ path })
        if not clean then callback(nil, dirty_error); return end
        prepared.lsp_preimages[path] = info.stat
      end
    end
    self:_finish_prepare(plan, prepared, callback)
  end
  if (kind == "rename" or kind == "move") and self.lsp and type(self.lsp.prepare_file_rename) == "function" then
    local buffer = self:_find_buffer(data.source)
    local handle, lsp_error = self.lsp:prepare_file_rename(data.source, data.target, buffer, function(lsp_data, err)
      if err then complete(nil, err); return end
      data.lsp = lsp_data
      complete(data)
    end)
    if not handle and lsp_error then return nil, lsp_error end
    plan.prepare_handle = handle
  else
    complete(data)
  end
  return plan
end

function Service:review(plan)
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return nil, error_value("unknown_plan", "operation plan is not owned by this service") end
  if plan.state ~= "validated" then return nil, error_value("invalid_plan_state", "only a validated operation plan can be reviewed") end
  if plan.review ~= record.review or plan.operation ~= record.operation or plan.source ~= record.data.source or plan.target ~= record.data.target
    or not same_stat(plan.source_before, record.data.source_before) or not same_stat(plan.target_before, record.data.target_before)
    or plan.workspace_id ~= record.workspace.id or plan.workspace_generation ~= record.workspace.generation
    or not vim.deep_equal(plan.trash_review, record.data.trash_review) then
    return nil, error_value("plan_changed", "operation details changed after validation; prepare a new plan")
  end
  plan.state = "reviewed"
  return true
end

function Service:cancel(plan)
  if type(plan) == "table" and plan.id == nil and plan.state == "draft" then
    if plan.prepare_handle then pcall(plan.prepare_handle.cancel or plan.prepare_handle.dispose, plan.prepare_handle); plan.prepare_handle = nil end
    plan.state = "cancelled"
    return true
  end
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return false end
  if plan.state == "applying" or plan.state == "applied" or plan.state == "failed" or plan.state == "partial" or plan.state == "cancelled" then return false end
  if plan.prepare_handle then pcall(plan.prepare_handle.cancel or plan.prepare_handle.dispose, plan.prepare_handle); plan.prepare_handle = nil end
  plan.state = "cancelled"
  plan.recovery = { ledger = { { step = "cancel", status = "no_mutation" } } }
  self:_release_record(record)
  return true
end

function Service:_revalidate(record)
  local plan, data = record.plan, record.data
  if plan.operation ~= record.operation or plan.source ~= data.source or plan.target ~= data.target
    or not same_stat(plan.source_before, data.source_before) or not same_stat(plan.target_before, data.target_before)
    or not same_stat(plan.parent_before, data.parent_before) or not vim.deep_equal(plan.trash_review, data.trash_review) then
    return nil, error_value("plan_changed", "reviewed operation data changed after preparation")
  end
  if plan.workspace_id ~= record.workspace.id or plan.workspace_generation ~= record.workspace.generation then
    return nil, error_value("workspace_changed", "workspace identity changed after operation preparation")
  end
  local root, root_error = self:_workspace(record.workspace)
  if not root then return nil, root_error end
  local fresh, err = self:_operation_paths(root, plan.operation, record.args)
  if not fresh then return nil, err end
  if not same_stat(fresh.source_before, plan.source_before) or not same_stat(fresh.target_before, plan.target_before)
    or not same_stat(fresh.parent_before, plan.parent_before) or fresh.target ~= plan.target or fresh.source ~= plan.source then
    return nil, error_value("stale_preimage", "a reviewed source, destination, or parent changed; prepare and review the operation again")
  end
  for path, expected in pairs(data.lsp_preimages or {}) do
    local info, path_error = self:_inspect_path(root, path, false)
    if not info then return nil, path_error end
    if not same_stat(info.stat, expected) then return nil, error_value("stale_lsp_preimage", "an LSP edit target changed after review", { path = path }) end
  end
  return fresh
end

function Service:_cleanup_created(path, identity)
  local current = self.uv.fs_lstat(path)
  if not current or current.dev ~= identity.dev or current.ino ~= identity.ino then
    return nil, "partial target changed identity; it was left untouched for manual recovery"
  end
  local okay, err = self.uv.fs_unlink(path)
  if not okay then return nil, tostring(err or "could not remove partial destination") end
  return true
end

function Service:_copy_file(plan, ledger)
  local uv = self.uv
  local src_fd, source_error = uv.fs_open(plan.source, "r", 0)
  if not src_fd then return nil, error_value("source_open_failed", tostring(source_error)) end
  local source_fstat = uv.fs_fstat(src_fd)
  if not source_fstat or source_fstat.dev ~= plan.source_before.dev or source_fstat.ino ~= plan.source_before.ino then
    uv.fs_close(src_fd)
    return nil, error_value("stale_source", "source identity changed before copy began")
  end
  local chunks, offset = {}, 0
  while offset < plan.source_before.size do
    local length = math.min(COPY_CHUNK_BYTES, plan.source_before.size - offset)
    local bytes, read_error = uv.fs_read(src_fd, length, offset)
    if not bytes then uv.fs_close(src_fd); return nil, error_value("source_read_failed", tostring(read_error)) end
    if #bytes == 0 then uv.fs_close(src_fd); return nil, error_value("source_changed", "source became shorter during copy") end
    chunks[#chunks + 1] = bytes
    offset = offset + #bytes
  end
  local trailing = uv.fs_read(src_fd, 1, offset)
  local after = uv.fs_fstat(src_fd)
  uv.fs_close(src_fd)
  if trailing and #trailing > 0 or not same_stat(stat_copy(after), plan.source_before) then
    return nil, error_value("source_changed", "source content or metadata changed during copy")
  end
  local data = table.concat(chunks)
  if #data ~= plan.source_before.size then return nil, error_value("source_changed", "source size changed during copy") end
  local mode = plan.source_before.mode % 512
  local target_fd, create_error = uv.fs_open(plan.target, "wx", mode)
  if not target_fd then
    local code = tostring(create_error):find("EXDEV", 1, true) and "unsupported_cross_device" or "destination_create_failed"
    return nil, error_value(code, tostring(create_error))
  end
  local target_stat = uv.fs_fstat(target_fd)
  local target_identity = target_stat and { dev = target_stat.dev, ino = target_stat.ino } or nil
  local create_entry = { step = "create_destination_exclusively", status = "applied", path = plan.target, identity = target_identity }
  ledger[#ledger + 1] = create_entry
  local written = 0
  local write_error
  while written < #data do
    local bytes, err = uv.fs_write(target_fd, data:sub(written + 1, written + COPY_CHUNK_BYTES), written)
    if not bytes or bytes <= 0 then write_error = err or "write returned no progress"; break end
    written = written + bytes
  end
  if not write_error and type(uv.fs_fsync) == "function" then
    local okay, err = uv.fs_fsync(target_fd)
    if not okay then write_error = err or "fsync failed" end
  end
  if not write_error and type(uv.fs_chmod) == "function" then
    local okay, err = uv.fs_chmod(plan.target, mode)
    if not okay then write_error = err or "could not preserve file mode" end
  end
  uv.fs_close(target_fd)
  local copied_fd_stat
  if not write_error then
    local verify_fd, verify_open_error = uv.fs_open(plan.target, "r", 0)
    if not verify_fd then
      write_error = verify_open_error or "could not reopen copied destination for verification"
    else
      local verify_offset = 0
      copied_fd_stat = uv.fs_fstat(verify_fd)
      if not target_identity or not copied_fd_stat or copied_fd_stat.dev ~= target_identity.dev or copied_fd_stat.ino ~= target_identity.ino then
        write_error = "destination identity changed before copy verification"
      end
      while not write_error and verify_offset < #data do
        local expected = data:sub(verify_offset + 1, verify_offset + COPY_CHUNK_BYTES)
        local actual, read_error = uv.fs_read(verify_fd, #expected, verify_offset)
        if not actual then write_error = read_error or "could not read copied destination for verification"; break end
        if actual ~= expected then write_error = "copied destination bytes differ from source"; break end
        verify_offset = verify_offset + #expected
      end
      local verified_stat = uv.fs_fstat(verify_fd)
      if not write_error and not same_stat(stat_copy(verified_stat), stat_copy(copied_fd_stat)) then
        write_error = "destination metadata changed during copy verification"
      end
      uv.fs_close(verify_fd)
    end
  end
  if write_error then
    local cleaned, cleanup_error = target_identity and self:_cleanup_created(plan.target, target_identity)
    create_entry.status = cleaned and "recovered" or "manual_recovery"
    ledger[#ledger + 1] = { step = "remove_partial_destination", status = cleaned and "recovered" or "manual_recovery", path = plan.target, error = cleanup_error }
    return nil, error_value("partial_copy", "copy failed after creating its destination", { cause = tostring(write_error), cleanup = cleanup_error, written_bytes = written, recovered = cleaned == true })
  end
  local verify_stat, verify_error = lstat(uv, plan.target)
  if not verify_stat or verify_stat.type ~= "file" or verify_stat.size ~= plan.source_before.size
    or verify_stat.mode % 512 ~= mode or not target_identity or not copied_fd_stat or copied_fd_stat.dev ~= target_identity.dev
    or copied_fd_stat.ino ~= target_identity.ino or copied_fd_stat.size ~= plan.source_before.size then
    local cleaned, cleanup_error = target_identity and self:_cleanup_created(plan.target, target_identity)
    create_entry.status = cleaned and "recovered" or "manual_recovery"
    ledger[#ledger + 1] = { step = "verify_destination", status = "failed", error = tostring(verify_error or "destination size/type mismatch") }
    ledger[#ledger + 1] = { step = "remove_partial_destination", status = cleaned and "recovered" or "manual_recovery", path = plan.target, error = cleanup_error }
    return nil, error_value("copy_verification_failed", "copied file did not match the source bytes, mode, identity, or planned size", { cleanup = cleanup_error, recovered = cleaned == true })
  end
  ledger[#ledger + 1] = { step = "verify_destination", status = "applied", size = verify_stat.size, mode = verify_stat.mode }
  return true
end

function Service:_next_temp(directory)
  for _ = 1, 100 do
    self.next_temp = self.next_temp + 1
    local candidate = vim.fs.joinpath(directory, ".workbench-rename-" .. tostring(self.next_temp) .. ".tmp")
    if not self.uv.fs_lstat(candidate) then return candidate end
  end
end

function Service:_rename_file(plan, ledger)
  local uv = self.uv
  if plan.case_only then
    local temporary = self:_next_temp(vim.fs.dirname(plan.source))
    if not temporary then return nil, error_value("temporary_name_unavailable", "could not reserve a case-only rename path") end
    local okay, err = uv.fs_link(plan.source, temporary)
    if not okay then return nil, error_value("rename_failed", tostring(err)) end
    local temp_stat = uv.fs_lstat(temporary)
    local temp_entry = { step = "link_temporary", status = "applied", path = temporary, identity = temp_stat and { dev = temp_stat.dev, ino = temp_stat.ino } }
    ledger[#ledger + 1] = temp_entry
    local unlinked, unlink_error = uv.fs_unlink(plan.source)
    if not unlinked then
      local cleanup = temp_stat and self:_cleanup_created(temporary, temp_stat)
      temp_entry.status = cleanup and "recovered" or "manual_recovery"
      return nil, error_value("rename_failed", tostring(unlink_error), { cleanup = cleanup, recovered = cleanup == true })
    end
    local source_entry = { step = "unlink_source_for_case_rename", status = "applied", path = plan.source }
    ledger[#ledger + 1] = source_entry
    local linked, link_error = uv.fs_link(temporary, plan.target)
    if not linked then
      local restored, restore_error = uv.fs_link(temporary, plan.source)
      local removed, remove_error
      if restored then removed, remove_error = uv.fs_unlink(temporary) else remove_error = restore_error end
      if restored and not removed then remove_error = remove_error or "temporary link could not be removed" end
      ledger[#ledger + 1] = { step = "restore_original_name", status = restored and removed and "recovered" or "manual_recovery", path = plan.source, error = remove_error }
      temp_entry.status = restored and removed and "recovered" or "manual_recovery"
      source_entry.status = restored and removed and "recovered" or "manual_recovery"
      return nil, error_value("partial_rename", tostring(link_error), { recovery = restored and removed and "source name restored" or tostring(remove_error), recovered = restored and removed })
    end
    ledger[#ledger + 1] = { step = "link_case_destination", status = "applied", path = plan.target }
    local removed, remove_error = uv.fs_unlink(temporary)
    ledger[#ledger + 1] = { step = "remove_temporary_link", status = removed and "applied" or "manual_recovery", path = temporary, error = remove_error }
    if not removed then return nil, error_value("partial_rename", tostring(remove_error), { recovery = "destination exists and temporary hard link remains" }) end
    return true
  end
  local linked, link_error = uv.fs_link(plan.source, plan.target)
  if not linked then
    local code = tostring(link_error):find("EXDEV", 1, true) and "unsupported_cross_device" or "rename_failed"
    return nil, error_value(code, tostring(link_error), { mutation = "none" })
  end
  local destination_stat = uv.fs_lstat(plan.target)
  ledger[#ledger + 1] = { step = "link_destination_exclusively", status = "applied", path = plan.target, identity = destination_stat and { dev = destination_stat.dev, ino = destination_stat.ino } }
  local unlinked, unlink_error = uv.fs_unlink(plan.source)
  if not unlinked then
    local cleaned, cleanup_error = destination_stat and self:_cleanup_created(plan.target, destination_stat)
    ledger[#ledger].status = cleaned and "recovered" or "manual_recovery"
    ledger[#ledger + 1] = { step = "remove_destination_after_source_unlink_failure", status = cleaned and "recovered" or "manual_recovery", path = plan.target, error = cleanup_error }
    return nil, error_value("rename_failed", tostring(unlink_error), { cleanup = cleanup_error, recovered = cleaned == true })
  end
  ledger[#ledger + 1] = { step = "unlink_source", status = "applied", path = plan.source }
  return true
end

function Service:_apply_lsp(plan, ledger)
  if not plan.lsp or not plan.lsp.edit then return true end
  if type(vim.lsp.util) ~= "table" or type(vim.lsp.util.apply_workspace_edit) ~= "function" then
    return nil, error_value("lsp_apply_unavailable", "Neovim cannot apply the reviewed LSP workspace edit")
  end
  local edit = plan.lsp.edit
  for _, item in ipairs(plan.lsp.affected_paths or {}) do
    local buffer = self:_find_buffer(item)
    if buffer and self.buffers.nvim_get_option_value("modified", { buf = buffer }) then
      return nil, error_value("dirty_lsp_buffer", "an LSP edit targets a modified buffer; save it before retrying", { path = item })
    end
  end
  local entry = { step = "apply_lsp_workspace_edit", status = "started", resources = plan.lsp.affected_paths or {} }
  ledger[#ledger + 1] = entry
  local ok, err = pcall(vim.lsp.util.apply_workspace_edit, edit, plan.lsp.encoding or "utf-16")
  if not ok then
    entry.status = "manual_recovery"
    entry.error = tostring(err)
    return nil, error_value("lsp_edit_failed", "Neovim failed while applying a reviewed LSP edit; inspect affected files and buffers before retrying", { cause = tostring(err) })
  end
  entry.status = "applied"
  return true
end

function Service:apply(plan)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return nil, error_value("unknown_plan", "operation plan is not owned by this service") end
  if plan.state ~= "reviewed" then return nil, error_value("review_required", "the exact operation must be reviewed before apply") end
  local fresh, preflight_error = self:_revalidate(record)
  if not fresh then
    plan.state = "failed"
    plan.recovery = { ledger = { { step = "preflight", status = "no_mutation", error = preflight_error.message } } }
    self:_release_record(record)
    return nil, preflight_error
  end
  plan.state = "applying"
  self.active = self.active + 1
  local ledger = {}
  plan.recovery = { ledger = ledger }
  local okay, result, operation_error = xpcall(function()
    if plan.operation == "create_file" then
      local fd, err = self.uv.fs_open(plan.target, "wx", 420)
      if not fd then return nil, error_value("create_failed", tostring(err)) end
      self.uv.fs_close(fd)
      ledger[#ledger + 1] = { step = "create_exclusively", status = "applied", path = plan.target }
      return true
    elseif plan.operation == "create_directory" then
      local made, err = self.uv.fs_mkdir(plan.target, 493)
      if not made then return nil, error_value("create_failed", tostring(err)) end
      ledger[#ledger + 1] = { step = "create_directory_exclusively", status = "applied", path = plan.target }
      return true
    elseif plan.operation == "copy" then
      return self:_copy_file(plan, ledger)
    elseif plan.operation == "rename" or plan.operation == "move" then
      local lsp_ok, lsp_error = self:_apply_lsp(plan, ledger)
      if not lsp_ok then return nil, lsp_error end
      local renamed, rename_error = self:_rename_file(plan, ledger)
      if not renamed then return nil, rename_error end
      local buffer = self:_find_buffer(plan.source)
      if buffer then
        local name_ok, name_error = pcall(self.buffers.nvim_buf_set_name, buffer, plan.target)
        if not name_ok then
          ledger[#ledger + 1] = { step = "preserve_open_buffer_name", status = "manual_recovery", error = tostring(name_error) }
          return nil, error_value("buffer_rebind_failed", "filesystem rename succeeded but the clean open buffer could not be rebound", { recovery = "close or rename the still-open buffer manually" })
        end
        ledger[#ledger + 1] = { step = "preserve_open_buffer_name", status = "applied", bufnr = buffer, path = plan.target }
      end
      if self.lsp and type(self.lsp.did_rename_files) == "function" then
        local notified, notify_error = self.lsp:did_rename_files(plan.source, plan.target, plan.lsp)
        if not notified then
          ledger[#ledger + 1] = { step = "notify_did_rename", status = "failed", error = notify_error and notify_error.message or tostring(notify_error) }
          return nil, error_value("lsp_notification_failed", "filesystem rename succeeded but a language server was not notified", { recovery = "filesystem path now exists at " .. plan.target })
        end
        ledger[#ledger + 1] = { step = "notify_did_rename", status = "applied" }
      end
      return true
    elseif plan.operation == "trash" then
      ledger[#ledger + 1] = { step = "recoverable_trash_adapter", status = "started", path = plan.source }
      local okay, receipt, err = pcall(self.trash.move, self.trash, vim.deepcopy(plan))
      if not okay then err, receipt = receipt, nil end
      if type(receipt) ~= "table" or receipt.recoverable ~= true then
        return nil, error_value("trash_failed", tostring(err or "trash adapter did not confirm a recoverable receipt"), { mutation = "adapter outcome requires inspection" })
      end
      ledger[#ledger].status = "applied"
      ledger[#ledger].receipt = vim.deepcopy(receipt)
      return true
    end
    return nil, error_value("unsupported_operation", "operation is not implemented")
  end, debug.traceback)
  self.active = math.max(0, self.active - 1)
  if not okay then
    operation_error = error_value("operation_exception", tostring(result))
    result = nil
  end
  if result then
    plan.state = "applied"
    if self.lsp and type(self.lsp.did_rename_files) == "function" and (plan.operation == "rename" or plan.operation == "move") then
      -- didRenameFiles is emitted by the ordered branch above when LSP is injected.
    end
    self:_release_record(record)
    return true, vim.deepcopy(plan.recovery)
  end
  if type(operation_error) ~= "table" then operation_error = error_value("operation_failed", tostring(operation_error or "filesystem operation failed")) end
  local unrecovered = false
  for _, entry in ipairs(ledger) do
    if entry.status == "manual_recovery" or (entry.status == "applied" and entry.step == "apply_lsp_workspace_edit") then unrecovered = true end
  end
  plan.state = (unrecovered or operation_error.recovered ~= true and #ledger > 0) and "partial" or "failed"
  plan.recovery.error = operation_error.message
  self:_release_record(record)
  return nil, operation_error, vim.deepcopy(plan.recovery)
end

function Service:capabilities()
  local operations = { "create_file", "create_directory", "rename_file", "move_file", "copy_file" }
  if self.trash then operations[#operations + 1] = "trash_file" end
  return { state = "ready", operations = operations, limitations = {
    "directory rename/move/copy unsupported", "cross-device move unsupported", "symlinks unsupported",
    not self.trash and "recoverable trash unavailable; no permanent delete" or nil,
  } }
end

function Service:status()
  local plans = {}
  for _, record in pairs(self.plans) do plans[#plans + 1] = { id = record.plan.id, state = record.plan.state, operation = record.plan.operation } end
  table.sort(plans, function(a, b) return a.id < b.id end)
  return { disposed = self.disposed, active = self.active, plan_count = #plans, plans = plans, resources = self.scope:inventory() }
end

function Service:dispose()
  if self.disposed then return false end
  self.disposed = true
  for _, record in pairs(self.plans) do
    if record.plan.state ~= "applied" and record.plan.state ~= "failed" and record.plan.state ~= "partial" then self:cancel(record.plan) end
  end
  self.plans = {}
  return self.scope:dispose()
end

M.constants = { max_copy_bytes = MAX_COPY_BYTES, copy_chunk_bytes = COPY_CHUNK_BYTES }
return M
