local Resource = require("workbench.core.resource")
local RootPolicy = require("workbench.core.root_policy")

local M = {}
local Service = {}
Service.__index = Service

local MAX_MATCHES = 10000
local MAX_FILE_BYTES = 16 * 1024 * 1024
local MAX_PLAN_BYTES = 64 * 1024 * 1024
local MAX_JOURNAL_BYTES = 64 * 1024 * 1024
local MAX_JOURNAL_RECORDS = 32
local MAX_JOURNAL_RECORD_BYTES = 1024 * 1024
local JOURNAL_TTL_SECONDS = 7 * 24 * 60 * 60

local function failure(code, message, extra)
  local result = { code = code, message = message }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count, max_index = count + 1, math.max(max_index, key)
  end
  return count == max_index
end

local function copy_stat(stat)
  if not stat then return nil end
  return {
    type = stat.type, dev = stat.dev, ino = stat.ino, mode = stat.mode, size = stat.size,
    mtime = { sec = stat.mtime.sec, nsec = stat.mtime.nsec },
    ctime = { sec = stat.ctime.sec, nsec = stat.ctime.nsec },
  }
end

local function mode_writable(mode)
  mode = mode % 512
  return math.floor(mode / 128) % 2 == 1 or math.floor(mode / 16) % 2 == 1 or math.floor(mode / 2) % 2 == 1
end

local function path_components(path)
  local parts = {}
  for part in path:gmatch("[^/\\]+") do parts[#parts + 1] = part end
  return parts
end

local function same_stat(left, right)
  if not left or not right then return left == right end
  return left.type == right.type and left.dev == right.dev and left.ino == right.ino
    and left.mode == right.mode and left.size == right.size
    and left.mtime.sec == right.mtime.sec and left.mtime.nsec == right.mtime.nsec
    and left.ctime.sec == right.ctime.sec and left.ctime.nsec == right.ctime.nsec
end

local function valid_utf8(value)
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    if first == 0 then return false end
    if first < 0x80 then
      index = index + 1
    else
      local width, second_min, second_max
      if first >= 0xC2 and first <= 0xDF then width, second_min, second_max = 2, 0x80, 0xBF
      elseif first == 0xE0 then width, second_min, second_max = 3, 0xA0, 0xBF
      elseif first >= 0xE1 and first <= 0xEC or first >= 0xEE and first <= 0xEF then width, second_min, second_max = 3, 0x80, 0xBF
      elseif first == 0xED then width, second_min, second_max = 3, 0x80, 0x9F
      elseif first == 0xF0 then width, second_min, second_max = 4, 0x90, 0xBF
      elseif first >= 0xF1 and first <= 0xF3 then width, second_min, second_max = 4, 0x80, 0xBF
      elseif first == 0xF4 then width, second_min, second_max = 4, 0x80, 0x8F
      else return false end
      if index + width - 1 > #value then return false end
      local second = value:byte(index + 1)
      if second < second_min or second > second_max then return false end
      for offset = 2, width - 1 do
        local byte = value:byte(index + offset)
        if byte < 0x80 or byte > 0xBF then return false end
      end
      index = index + width
    end
  end
  return true
end

local function line_bounds(content, line)
  local current, start, index = 0, 1, 1
  while index <= #content do
    local byte = content:byte(index)
    if byte == 10 or byte == 13 then
      if current == line then return start, index - 1 end
      if byte == 13 and content:byte(index + 1) == 10 then index = index + 1 end
      current, index, start = current + 1, index + 1, index + 1
    else
      index = index + 1
    end
  end
  if current == line and start <= #content + 1 then return start, #content end
end

local function file_read(uv, path)
  local before, stat_error = uv.fs_lstat(path)
  if not before then return nil, failure("source_missing", "replacement target disappeared", { path = path, cause = tostring(stat_error) }) end
  if before.type == "link" then return nil, failure("symlink_unsupported", "replacement does not follow symlinks", { path = path }) end
  if before.type ~= "file" then return nil, failure("not_regular_file", "replacement target must be a regular file", { path = path }) end
  if before.size > MAX_FILE_BYTES then return nil, failure("file_limit", "replacement target exceeds the 16 MiB per-file limit", { path = path, size = before.size }) end
  local fd, open_error = uv.fs_open(path, "r", 0)
  if not fd then return nil, failure("source_open_failed", tostring(open_error), { path = path }) end
  local opened = uv.fs_fstat(fd)
  if not opened or opened.dev ~= before.dev or opened.ino ~= before.ino then
    uv.fs_close(fd)
    return nil, failure("stale_preimage", "replacement target identity changed while opening", { path = path })
  end
  local chunks, offset = {}, 0
  while offset < before.size do
    local bytes, read_error = uv.fs_read(fd, math.min(64 * 1024, before.size - offset), offset)
    if not bytes or #bytes == 0 then
      uv.fs_close(fd)
      return nil, failure("source_read_failed", tostring(read_error or "file became shorter during read"), { path = path })
    end
    chunks[#chunks + 1] = bytes
    offset = offset + #bytes
  end
  local after = uv.fs_fstat(fd)
  uv.fs_close(fd)
  if offset ~= before.size or not same_stat(copy_stat(after), copy_stat(before)) then
    return nil, failure("stale_preimage", "replacement target changed while reading", { path = path })
  end
  return table.concat(chunks), copy_stat(before)
end

local function buffer_for_path(api, path)
  local found
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
      local name = api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local normalized = Resource.normalize_absolute_path(name)
        if normalized == path then
          if found then return nil, failure("ambiguous_buffer", "multiple loaded buffers name the replacement target", { path = path }) end
          found = bufnr
        end
      end
    end
  end
  return found
end

local function buffer_text(api, bufnr, include_bom)
  local options = vim.bo[bufnr]
  local encoding = tostring(options.fileencoding or ""):lower()
  if encoding ~= "" and encoding ~= "utf-8" and encoding ~= "utf8" then
    return nil, failure("encoding_unsupported", "replacement currently supports UTF-8 buffers only", { encoding = encoding })
  end
  local separator = options.fileformat == "dos" and "\r\n" or options.fileformat == "mac" and "\r" or "\n"
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, separator)
  if options.endofline then text = text .. separator end
  if include_bom and options.bomb then text = "\239\187\191" .. text end
  return text, {
    bufnr = bufnr,
    changedtick = api.nvim_buf_get_changedtick(bufnr),
    fileformat = options.fileformat,
    endofline = options.endofline,
    bomb = options.bomb,
    fileencoding = options.fileencoding,
  }
end

local function buffer_undo_levels(bufnr)
  local value = vim.bo[bufnr].undolevels
  return value == -123456 and vim.o.undolevels or value
end

local function stat_signature(stat)
  if not stat then return "buffer snapshot" end
  return table.concat({ stat.dev, stat.ino, stat.mode, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ":")
end

local function plan_fields(plan)
  return {
    workspace_id = plan.workspace_id,
    workspace_generation = plan.workspace_generation,
    replacement = plan.replacement,
    matched_count = plan.matched_count,
    affected_resources = plan.affected_resources,
    diff = plan.diff,
    review = plan.review,
    preconditions = plan.preconditions,
  }
end

function M.new(opts)
  opts = opts or {}
  local uv = opts.uv or vim.uv or vim.loop
  local buffers = opts.buffers or vim.api
  for _, name in ipairs({ "fs_lstat", "fs_stat", "fs_access", "fs_open", "fs_close", "fs_fstat", "fs_read", "fs_write", "fs_rename", "fs_unlink", "fs_mkdir", "fs_scandir", "fs_scandir_next", "fs_chmod" }) do
    if type(uv[name]) ~= "function" then return nil, "replacement filesystem operation is unavailable: " .. name end
  end
  local state_dir = opts.state_dir or vim.fs.joinpath(vim.fn.stdpath("state"), "workbench", "replacement-recovery")
  local normalized, path_error = Resource.normalize_absolute_path(state_dir)
  if not normalized then return nil, "replacement state directory must be absolute: " .. tostring(path_error) end
  return setmetatable({
    uv = uv,
    buffers = buffers,
    state_dir = normalized,
    journal_enabled = opts.journal ~= false,
    plans = {},
    next_id = 0,
    disposed = false,
  }, Service)
end

function Service:_live()
  if self.disposed then return nil, failure("service_disposed", "replacement service is disposed") end
  return true
end

function Service:_snapshot_buffer(path, snapshot)
  if type(snapshot) ~= "table" or type(snapshot.id) ~= "string" or type(snapshot.bufnr) ~= "number"
    or snapshot.path ~= path or not self.buffers.nvim_buf_is_valid(snapshot.bufnr)
    or not self.buffers.nvim_buf_is_loaded(snapshot.bufnr) then
    return nil, failure("stale_buffer_snapshot", "the captured source buffer is no longer available", { path = path })
  end
  local bufnr = snapshot.bufnr
  local actual_path = self.buffers.nvim_buf_get_name(bufnr)
  actual_path = actual_path ~= "" and Resource.normalize_absolute_path(actual_path) or nil
  if actual_path ~= path then return nil, failure("stale_buffer_snapshot", "the captured source buffer was renamed", { path = path }) end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return nil, failure("buffer_not_writable", "the captured source buffer is not editable", { path = path, bufnr = bufnr })
  end
  if buffer_undo_levels(bufnr) < 0 then return nil, failure("undo_unavailable", "replacement requires undo history to be enabled for buffer edits", { path = path, bufnr = bufnr }) end
  local text, metadata = buffer_text(self.buffers, bufnr, false)
  if not text then return nil, metadata end
  if metadata.changedtick ~= snapshot.changedtick or metadata.fileformat ~= snapshot.fileformat
    or metadata.endofline ~= snapshot.endofline or metadata.bomb ~= snapshot.bomb
    or metadata.fileencoding ~= snapshot.fileencoding or vim.fn.sha256(text) ~= snapshot.content_hash then
    return nil, failure("stale_buffer_snapshot", "the buffer changed after the search snapshot was captured", { path = path, bufnr = bufnr })
  end
  return { kind = "buffer", path = path, bufnr = bufnr, snapshot = vim.deepcopy(snapshot), before = text, metadata = metadata }
end

function Service:_new_group(path, snapshot)
  if snapshot then return self:_snapshot_buffer(path, snapshot) end
  local content, stat = file_read(self.uv, path)
  if not content then return nil, stat end
  if not valid_utf8(content) then
    return nil, failure("encoding_unsupported", "unloaded replacement targets must be valid UTF-8 text without NUL bytes", { path = path })
  end
  local bufnr, buffer_error = buffer_for_path(self.buffers, path)
  if buffer_error then return nil, buffer_error end
  if bufnr then
    if self.buffers.nvim_get_option_value("modified", { buf = bufnr }) then
      return nil, failure("dirty_buffer", "disk search results cannot replace a subsequently modified buffer; search its captured buffer snapshot", { path = path, bufnr = bufnr })
    end
    if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
      return nil, failure("buffer_not_writable", "the loaded replacement buffer is not editable", { path = path, bufnr = bufnr })
    end
    if buffer_undo_levels(bufnr) < 0 then return nil, failure("undo_unavailable", "replacement requires undo history to be enabled for buffer edits", { path = path, bufnr = bufnr }) end
    local text, metadata = buffer_text(self.buffers, bufnr, true)
    if not text then return nil, metadata end
    if text ~= content then return nil, failure("stale_loaded_buffer", "the loaded buffer differs from the searched disk preimage", { path = path, bufnr = bufnr }) end
    return { kind = "buffer", path = path, bufnr = bufnr, before = text, metadata = metadata, disk_before = content, disk_stat = stat }
  end
  local parent = vim.fs.dirname(path)
  local okay, access_error = self.uv.fs_access(parent, "W")
  if not okay or not mode_writable(stat.mode) then
    return nil, failure("permission_denied", "replacement requires a writable file and parent directory", { path = path, cause = tostring(access_error or "file mode has no write permission bits") })
  end
  return { kind = "disk", path = path, before = content, disk_stat = stat }
end

function Service:_safe_target(root, path, allow_missing_final)
  local relative = vim.fs.relpath(root, path)
  if not relative or relative == "." or relative == ".." or relative:match("^%.%.[/\\]") then
    return nil, failure("outside_root", "replacement target is not a workspace child", { path = path })
  end
  local components = path_components(relative)
  local current = root
  for index, component in ipairs(components) do
    current = vim.fs.joinpath(current, component)
    local stat, stat_error = self.uv.fs_lstat(current)
    if not stat then
      if index == #components and allow_missing_final then return true end
      return nil, failure("source_missing", "replacement path no longer exists", { path = current, cause = tostring(stat_error) })
    end
    if stat.type == "link" then return nil, failure("symlink_unsupported", "replacement does not traverse symlink path components", { path = current }) end
    if index < #components and stat.type ~= "directory" then
      return nil, failure("parent_not_directory", "a replacement parent is not a directory", { path = current })
    end
    if index == #components and stat.type ~= "file" then
      return nil, failure("not_regular_file", "replacement target must remain a regular file", { path = current })
    end
  end
  return true
end

local function make_edit(content, location, replacement, item, source_snapshot)
  local range = location and location.range
  if not range or not range.start or not range.finish or location.encoding ~= "utf-8"
    or type(range.start.line) ~= "number" or range.start.line < 0 or range.start.line % 1 ~= 0
    or range.finish.line ~= range.start.line
    or type(range.start.character) ~= "number" or range.start.character < 0 or range.start.character % 1 ~= 0
    or type(range.finish.character) ~= "number" or range.finish.character <= range.start.character or range.finish.character % 1 ~= 0 then
    return nil, failure("unsupported_match_range", "replacement requires a non-empty, single-line UTF-8 byte range", { item_id = item.id })
  end
  local first, last = line_bounds(content, range.start.line)
  if not first then return nil, failure("stale_preimage", "the searched line no longer exists", { item_id = item.id, path = location.resource.path }) end
  local start_col, end_col = range.start.character, range.finish.character
  local body_length = last - first + 1
  if start_col + 1 > body_length + 1 or end_col > body_length then
    return nil, failure("stale_preimage", "the searched byte range is outside the current line", { item_id = item.id, path = location.resource.path })
  end
  local original = content:sub(first + start_col, first + end_col - 1)
  if original == "" or not valid_utf8(original) then
    return nil, failure("unsupported_match", "empty or non-UTF-8 matches cannot be replaced", { item_id = item.id })
  end
  local payload = item.payload or {}
  if payload.provider_id ~= "rg" or type(payload.byte_start) ~= "number" then
    return nil, failure("unsupported_match", "replacement requires a raw ripgrep match result", { item_id = item.id })
  end
  if payload.byte_start ~= start_col or payload.byte_end ~= end_col then
    return nil, failure("unsupported_match_range", "result range disagrees with its ripgrep byte offsets", { item_id = item.id })
  end
  local expected = payload.match_bytes
  if type(expected) == "string" and not payload.match_truncated and expected ~= original then
    return nil, failure("stale_preimage", "the match bytes differ from the captured search result", { item_id = item.id })
  end
  return {
    id = item.id,
    line = range.start.line,
    start_col = start_col,
    end_col = end_col,
    preimage = original,
    replacement = replacement,
    absolute_start = first - 1 + start_col,
    absolute_end = first - 1 + end_col,
    source_snapshot_id = source_snapshot and source_snapshot.id or nil,
  }
end

local function make_output(group)
  table.sort(group.edits, function(left, right)
    if left.line ~= right.line then return left.line < right.line end
    if left.start_col ~= right.start_col then return left.start_col < right.start_col end
    return left.end_col < right.end_col
  end)
  local previous
  for _, edit in ipairs(group.edits) do
    if previous and edit.line == previous.line and edit.start_col < previous.end_col then
      return nil, failure("overlapping_matches", "selected replacement ranges overlap", { path = group.path, first = previous.id, second = edit.id })
    end
    previous = edit
  end
  local by_line, lines_seen = {}, {}
  for _, edit in ipairs(group.edits) do
    by_line[edit.line] = by_line[edit.line] or {}
    by_line[edit.line][#by_line[edit.line] + 1] = edit
    lines_seen[edit.line] = true
  end
  local diffs = {}
  for _, line_number in ipairs(vim.tbl_keys(lines_seen)) do
    table.insert(diffs, line_number)
  end
  table.sort(diffs)
  local review_lines = {}
  for _, line_number in ipairs(diffs) do
    local start, finish = line_bounds(group.before, line_number)
    local old = group.before:sub(start, finish)
    local new = old
    local edits = by_line[line_number]
    for index = #edits, 1, -1 do
      local edit = edits[index]
      local from = edit.start_col + 1
      local to = edit.end_col
      new = new:sub(1, from - 1) .. edit.replacement .. new:sub(to + 1)
    end
    review_lines[#review_lines + 1] = string.format("@@ %s:%d @@", Resource.escape_display(group.display_path or group.path), line_number + 1)
    review_lines[#review_lines + 1] = "- " .. Resource.escape_display(old)
    review_lines[#review_lines + 1] = "+ " .. Resource.escape_display(new)
  end
  group.output = group.before
  for index = #group.edits, 1, -1 do
    local edit = group.edits[index]
    if group.kind == "disk" then
      group.output = group.output:sub(1, edit.absolute_start) .. edit.replacement .. group.output:sub(edit.absolute_end + 1)
    end
  end
  group.review = table.concat(review_lines, "\n")
  return true
end

function Service:prepare(workspace, selected, replacement, opts)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  opts = opts or {}
  if type(workspace) ~= "table" or type(workspace.id) ~= "string" or type(workspace.generation) ~= "number"
    or type(workspace.roots) ~= "table" or #workspace.roots ~= 1 or type(workspace.roots[1].path) ~= "string" then
    return nil, failure("workspace_unavailable", "replacement requires an explicit single-root workspace")
  end
  local root = Resource.normalize_absolute_path(workspace.roots[1].path)
  if not root then return nil, failure("invalid_root", "replacement workspace root must be absolute") end
  if opts.literal ~= true then return nil, failure("literal_required", "regex replacement is unavailable; use a literal search") end
  if type(replacement) ~= "string" or replacement:find("[\r\n%z]") or not valid_utf8(replacement) then
    return nil, failure("invalid_replacement", "replacement must be valid UTF-8 on a single line")
  end
  if not dense_array(selected) or #selected == 0 or #selected > MAX_MATCHES then
    return nil, failure("invalid_selection", "select between one and 10,000 literal search matches")
  end
  local groups, group_order, ids, total_bytes = {}, {}, {}, 0
  for _, selected_match in ipairs(selected) do
    if type(selected_match) ~= "table" or type(selected_match.item) ~= "table" then
      return nil, failure("invalid_selection", "replacement selection entries must include typed search items")
    end
    local item = selected_match.item
    if type(item.id) ~= "string" or ids[item.id] then return nil, failure("duplicate_selection", "replacement selection contains a missing or duplicate match ID") end
    ids[item.id] = true
    local location = item.location
    local resource = location and location.resource
    if not resource or resource.scheme ~= "file" or type(resource.path) ~= "string" then
      return nil, failure("unsupported_resource", "replacement only supports local file match resources", { item_id = item.id })
    end
    local path, path_error = Resource.normalize_absolute_path(resource.path)
    if not path then return nil, failure("invalid_path", path_error, { item_id = item.id }) end
    local source = item.payload and item.payload.source_snapshot
    local inside, contains_error = RootPolicy.contains(root, path)
    if not inside then return nil, failure("outside_root", contains_error or "replacement match is outside the workspace", { path = path }) end
    local safe, safe_error = self:_safe_target(root, path, source ~= nil)
    if not safe then return nil, safe_error end
    local metadata = selected_match.source_snapshot
    if source and (type(metadata) ~= "table" or source.id ~= metadata.id) then
      return nil, failure("stale_buffer_snapshot", "the exact search snapshot metadata is unavailable", { path = path })
    end
    local group_key = path
    local existing = groups[group_key]
    if not existing then
      local group, group_error = self:_new_group(path, source and metadata or nil)
      if not group then return nil, group_error end
      group.display_path = vim.fs.relpath(root, path) or path
      group.edits, group.match_ids = {}, {}
      group.source_snapshot_id = source and metadata.id or nil
      groups[group_key] = group
      group_order[#group_order + 1] = group_key
      existing = group
      total_bytes = total_bytes + #existing.before
      if total_bytes > MAX_PLAN_BYTES then return nil, failure("plan_limit", "replacement preimages exceed the 64 MiB plan limit") end
    elseif existing.source_snapshot_id ~= (source and metadata.id or nil) then
      return nil, failure("mixed_source_snapshots", "one file cannot combine disk and different buffer snapshots in a replacement plan", { path = path })
    end
    local edit, edit_error = make_edit(existing.before, location, replacement, item, source and metadata or nil)
    if not edit then return nil, edit_error end
    existing.edits[#existing.edits + 1] = edit
    existing.match_ids[#existing.match_ids + 1] = item.id
  end
  table.sort(group_order)
  local reviews, resources, preconditions, match_count = {}, {}, {}, 0
  for _, path in ipairs(group_order) do
    local group = groups[path]
    local okay, output_error = make_output(group)
    if not okay then return nil, output_error end
    match_count = match_count + #group.edits
    reviews[#reviews + 1] = group.review
    resources[#resources + 1] = path
    preconditions[#preconditions + 1] = {
      path = path,
      kind = group.kind,
      signature = stat_signature(group.disk_stat),
      changedtick = group.metadata and group.metadata.changedtick or nil,
      content_hash = vim.fn.sha256(group.before),
      match_count = #group.edits,
    }
    for _, record in pairs(self.plans) do
      if record.plan.state == "validated" or record.plan.state == "reviewed" then
        for _, held in ipairs(record.paths) do
          if held == path then return nil, failure("operation_overlap", "another reviewed replacement already owns this resource", { path = path, plan_id = record.plan.id }) end
        end
      end
    end
  end
  local review = table.concat({
    "Literal single-line replacement",
    "Regex/capture and multiline replacement are unavailable.",
    "Multi-file apply is sequential, not atomic; stale or failed steps stop later changes.",
    "Selected matches: " .. match_count,
    table.concat(reviews, "\n"),
  }, "\n")
  if #review > 256 * 1024 then return nil, failure("review_limit", "replacement review exceeds the 256 KiB review limit") end
  self.next_id = self.next_id + 1
  local unique_clock = type(self.uv.hrtime) == "function" and self.uv.hrtime() or math.floor(os.clock() * 1000000000)
  local plan = {
    id = table.concat({ "replacement", tostring(os.time()), string.format("%.0f", unique_clock), tostring(self.next_id) }, "-"),
    state = "validated",
    workspace_id = workspace.id,
    workspace_generation = workspace.generation,
    replacement = replacement,
    matched_count = match_count,
    affected_resources = resources,
    diff = table.concat(reviews, "\n"),
    review = review,
    preconditions = preconditions,
  }
  local locked = {}
  for _, path in ipairs(group_order) do locked[#locked + 1] = path end
  self.plans[plan.id] = {
    plan = plan,
    immutable = vim.deepcopy(plan_fields(plan)),
    groups = groups,
    paths = locked,
    workspace = { id = workspace.id, generation = workspace.generation, root = root },
  }
  return plan
end

function Service:review(plan)
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return nil, failure("unknown_plan", "replacement plan is not owned by this service") end
  if plan.state ~= "validated" then return nil, failure("invalid_plan_state", "only a validated replacement plan can be reviewed") end
  if not vim.deep_equal(plan_fields(plan), record.immutable) then
    return nil, failure("plan_changed", "replacement details changed after preparation; prepare and review a new plan")
  end
  plan.state = "reviewed"
  return true
end

function Service:cancel(plan)
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return false end
  if plan.state == "applying" or plan.state == "applied" or plan.state == "partial" or plan.state == "failed" or plan.state == "cancelled" then return false end
  plan.state = "cancelled"
  record.groups, record.paths, record.workspace = nil, {}, nil
  plan.recovery = { state = "cancelled", ledger = {}, applied = {}, unapplied = vim.deepcopy(plan.affected_resources) }
  return true
end

function Service:_verify_group(group, root)
  local safe, safe_error = self:_safe_target(root, group.path, group.snapshot ~= nil)
  if not safe then return nil, safe_error end
  if group.kind == "buffer" then
    local bufnr = group.bufnr
    if not self.buffers.nvim_buf_is_valid(bufnr) or not self.buffers.nvim_buf_is_loaded(bufnr) then
      return nil, failure("stale_buffer_snapshot", "an affected buffer was unloaded after review", { path = group.path })
    end
    local current_path = self.buffers.nvim_buf_get_name(bufnr)
    current_path = current_path ~= "" and Resource.normalize_absolute_path(current_path) or nil
    if current_path ~= group.path then return nil, failure("stale_buffer_snapshot", "an affected buffer was renamed after review", { path = group.path }) end
    if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
      return nil, failure("buffer_not_writable", "an affected buffer is no longer editable", { path = group.path, bufnr = bufnr })
    end
    local text, metadata = buffer_text(self.buffers, bufnr, group.disk_before ~= nil)
    if not text then return nil, metadata end
    if text ~= group.before or metadata.changedtick ~= group.metadata.changedtick
      or metadata.fileformat ~= group.metadata.fileformat or metadata.endofline ~= group.metadata.endofline
      or metadata.bomb ~= group.metadata.bomb or metadata.fileencoding ~= group.metadata.fileencoding then
      return nil, failure("stale_preimage", "an affected buffer changed after replacement review", { path = group.path, bufnr = bufnr })
    end
    if group.disk_before then
      local disk, stat = file_read(self.uv, group.path)
      if not disk then return nil, stat end
      if disk ~= group.disk_before or not same_stat(stat, group.disk_stat) then
        return nil, failure("stale_preimage", "the saved file changed after replacement review", { path = group.path })
      end
    end
    return true
  end
  local content, stat = file_read(self.uv, group.path)
  if not content then return nil, stat end
  if content ~= group.before or not same_stat(stat, group.disk_stat) then
    return nil, failure("stale_preimage", "an affected file changed after replacement review", { path = group.path })
  end
  local parent_ok, parent_err = self.uv.fs_access(vim.fs.dirname(group.path), "W")
  if not parent_ok or not mode_writable(group.disk_stat.mode) then
    return nil, failure("permission_denied", "replacement requires a writable file and parent directory", { path = group.path, cause = tostring(parent_err) })
  end
  return true
end

local function write_all(uv, fd, bytes)
  local offset = 0
  while offset < #bytes do
    local written, err = uv.fs_write(fd, bytes:sub(offset + 1, offset + 64 * 1024), offset)
    if not written or written <= 0 then return nil, tostring(err or "write returned no progress") end
    offset = offset + written
  end
  return true
end

function Service:_write_exclusive(path, bytes, mode)
  local fd, open_error = self.uv.fs_open(path, "wx", mode)
  if not fd then return nil, tostring(open_error) end
  local okay, write_error = write_all(self.uv, fd, bytes)
  if okay and type(self.uv.fs_fsync) == "function" then
    local synced, sync_error = self.uv.fs_fsync(fd)
    if not synced then okay, write_error = nil, tostring(sync_error or "fsync failed") end
  end
  self.uv.fs_close(fd)
  if not okay then self.uv.fs_unlink(path); return nil, write_error end
  return true
end

function Service:_journal_scan()
  local stat = self.uv.fs_lstat(self.state_dir)
  if not stat then return { records = 0, bytes = 0 } end
  if stat.type ~= "directory" then return nil, failure("journal_unavailable", "replacement journal path is not a directory") end
  local scan, scan_error = self.uv.fs_scandir(self.state_dir)
  if not scan then return nil, failure("journal_unavailable", tostring(scan_error)) end
  local result = { records = 0, bytes = 0 }
  while true do
    local name = self.uv.fs_scandir_next(scan)
    if not name then break end
    if name:match("^replacement%-%d[%d%-]*%.json$") then result.records = result.records + 1 end
    local entry = self.uv.fs_lstat(vim.fs.joinpath(self.state_dir, name))
    if entry and entry.type == "file" then result.bytes = result.bytes + entry.size end
  end
  return result
end

function Service:_unique_journal_temp(target)
  for suffix = 0, 49 do
    local candidate = target .. ".tmp-" .. tostring(suffix)
    if not self.uv.fs_lstat(candidate) then return candidate end
  end
end

function Service:_journal_prune()
  local stat = self.uv.fs_lstat(self.state_dir)
  if not stat then return true end
  if stat.type ~= "directory" then return nil, failure("journal_unavailable", "replacement journal path is not a directory") end
  local scan, scan_error = self.uv.fs_scandir(self.state_dir)
  if not scan then return nil, failure("journal_unavailable", tostring(scan_error)) end
  while true do
    local name = self.uv.fs_scandir_next(scan)
    if not name then break end
    if name:match("^replacement%-%d[%d%-]*%.json$") then
      local path = vim.fs.joinpath(self.state_dir, name)
      local stat_now = self.uv.fs_lstat(path)
      if stat_now and stat_now.type == "file" and stat_now.size <= 1024 * 1024 then
        local fd = self.uv.fs_open(path, "r", 0)
        local contents = fd and self.uv.fs_read(fd, stat_now.size, 0) or nil
        if fd then self.uv.fs_close(fd) end
        local ok, record = pcall(vim.json.decode, contents or "")
        if ok and type(record) == "table" and type(record.created_at) == "number"
          and os.time() - record.created_at > JOURNAL_TTL_SECONDS then
          for _, sidecar in ipairs(record.preimages or {}) do
            if type(sidecar) == "string" and sidecar:match("^replacement%-%d[%d%-]*%.preimage%-%d+$") then
              self.uv.fs_unlink(vim.fs.joinpath(self.state_dir, sidecar))
            end
          end
          self.uv.fs_unlink(path)
        end
      end
    end
  end
  return true
end

function Service:_journal_record(record)
  local plan, groups = record.plan, record.groups
  local okay, prune_error = self:_journal_prune()
  if not okay then return nil, prune_error end
  local made = vim.fn.mkdir(self.state_dir, "p", 448)
  if made ~= 1 and made ~= 2 then return nil, failure("journal_unavailable", "could not create the replacement recovery directory") end
  local dir_stat = self.uv.fs_lstat(self.state_dir)
  if not dir_stat or dir_stat.type ~= "directory" then return nil, failure("journal_unavailable", "replacement recovery path is not a safe directory") end
  local usage, usage_error = self:_journal_scan()
  if not usage then return nil, usage_error end
  if usage.records >= MAX_JOURNAL_RECORDS then return nil, failure("journal_limit", "replacement journal contains 32 retained operations; expire history before applying") end
  local document = {
    schema = 1,
    id = plan.id,
    created_at = os.time(),
    state = "applying",
    workspace_id = plan.workspace_id,
    workspace_generation = plan.workspace_generation,
    replacement = plan.replacement,
    matched_count = plan.matched_count,
    resources = {},
    ledger = {},
    preimages = {},
    automatic_apply_on_restart = false,
  }
  local needed = 0
  for index, path in ipairs(plan.affected_resources) do
    local group = groups[path]
    local file = nil
    if group.kind == "disk" then
      file = plan.id .. ".preimage-" .. tostring(index)
      needed = needed + #group.before
      document.preimages[#document.preimages + 1] = file
    end
    document.resources[#document.resources + 1] = {
      path = path,
      kind = group.kind,
      state = "unapplied",
      match_count = #group.edits,
      preimage_file = file,
      preimage_sha256 = file and vim.fn.sha256(group.before) or nil,
      postimage_sha256 = group.kind == "disk" and vim.fn.sha256(group.output) or nil,
    }
  end
  local metadata_bytes = #vim.json.encode(document)
  if metadata_bytes > MAX_JOURNAL_RECORD_BYTES then
    return nil, failure("journal_limit", "replacement recovery metadata exceeds the 1 MiB per-record limit")
  end
  if usage.bytes + needed + metadata_bytes > MAX_JOURNAL_BYTES then
    return nil, failure("journal_limit", "replacement preimages would exceed the 64 MiB journal budget")
  end
  for index, path in ipairs(plan.affected_resources) do
    local group = groups[path]
    if group.kind == "disk" then
      local sidecar = vim.fs.joinpath(self.state_dir, document.resources[index].preimage_file)
      local saved, save_error = self:_write_exclusive(sidecar, group.before, 384)
      if not saved then
        for _, name in ipairs(document.preimages) do self.uv.fs_unlink(vim.fs.joinpath(self.state_dir, name)) end
        return nil, failure("journal_write_failed", "could not preserve a disk preimage for recovery", { cause = save_error, path = path })
      end
    end
  end
  local json_path = vim.fs.joinpath(self.state_dir, plan.id .. ".json")
  local temp = self:_unique_journal_temp(json_path)
  if not temp then
    for _, name in ipairs(document.preimages) do self.uv.fs_unlink(vim.fs.joinpath(self.state_dir, name)) end
    return nil, failure("journal_write_failed", "could not allocate a unique recovery-record temporary file")
  end
  local serialized = vim.json.encode(document)
  local written, write_error = self:_write_exclusive(temp, serialized, 384)
  if not written then
    for _, name in ipairs(document.preimages) do self.uv.fs_unlink(vim.fs.joinpath(self.state_dir, name)) end
    return nil, failure("journal_write_failed", "could not create the replacement recovery record", { cause = write_error })
  end
  local renamed, rename_error = self.uv.fs_rename(temp, json_path)
  if not renamed then
    self.uv.fs_unlink(temp)
    for _, name in ipairs(document.preimages) do self.uv.fs_unlink(vim.fs.joinpath(self.state_dir, name)) end
    return nil, failure("journal_write_failed", tostring(rename_error or "could not install the recovery record"))
  end
  record.journal = document
  return true
end

function Service:_save_journal(record)
  local document = record.journal
  if not document then return true end
  document.state = record.plan.state == "applying" and "applying" or record.plan.state
  local json_path = vim.fs.joinpath(self.state_dir, record.plan.id .. ".json")
  local temp = self:_unique_journal_temp(json_path)
  if not temp then return nil, failure("journal_write_failed", "could not allocate a unique recovery-record temporary file") end
  local written, write_error = self:_write_exclusive(temp, vim.json.encode(document), 384)
  if not written then return nil, failure("journal_write_failed", tostring(write_error)) end
  local renamed, rename_error = self.uv.fs_rename(temp, json_path)
  if not renamed then self.uv.fs_unlink(temp); return nil, failure("journal_write_failed", tostring(rename_error)) end
  return true
end

function Service:_temp_path(path, plan_id, index)
  local directory = vim.fs.dirname(path)
  for suffix = 0, 49 do
    local name = string.format(".workbench-replace-%s-%d-%d.tmp", plan_id:match("%d+$"), index, suffix)
    local candidate = vim.fs.joinpath(directory, name)
    if not self.uv.fs_lstat(candidate) then return candidate end
  end
end

function Service:_apply_disk(group, plan, index, steps)
  local temp = self:_temp_path(group.path, plan.id, index)
  if not temp then return nil, failure("temporary_name_unavailable", "could not allocate a unique sibling replacement file", { path = group.path }), false end
  local fd, open_error = self.uv.fs_open(temp, "wx", 384)
  if not fd then return nil, failure("temporary_create_failed", tostring(open_error), { path = group.path }), false end
  local identity = self.uv.fs_fstat(fd)
  steps[#steps + 1] = { step = "create_sibling_temporary", status = "applied", path = temp, identity = identity and { dev = identity.dev, ino = identity.ino } }
  local okay, write_error = write_all(self.uv, fd, group.output)
  if not okay then
    self.uv.fs_close(fd)
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "write_temporary", status = "failed", error = write_error }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("replacement_write_failed", write_error, { path = group.path }), false
  end
  if type(self.uv.fs_fsync) == "function" then
    local synced, sync_error = self.uv.fs_fsync(fd)
    if not synced then
      self.uv.fs_close(fd); self.uv.fs_unlink(temp)
      steps[#steps + 1] = { step = "sync_temporary", status = "failed", error = tostring(sync_error) }
      steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
      return nil, failure("replacement_sync_failed", tostring(sync_error), { path = group.path }), false
    end
  end
  self.uv.fs_close(fd)
  local chmod_ok, chmod_error = self.uv.fs_chmod(temp, group.disk_stat.mode % 512)
  if not chmod_ok then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "preserve_file_mode", status = "failed", error = tostring(chmod_error) }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("replacement_metadata_failed", tostring(chmod_error), { path = group.path }), false
  end
  local verify_fd, verify_error = self.uv.fs_open(temp, "r", 0)
  if not verify_fd then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "verify_temporary", status = "failed", error = tostring(verify_error) }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("replacement_verify_failed", tostring(verify_error), { path = group.path }), false
  end
  local actual = self.uv.fs_read(verify_fd, #group.output, 0) or ""
  local verified_stat = self.uv.fs_fstat(verify_fd)
  self.uv.fs_close(verify_fd)
  if actual ~= group.output or not verified_stat or verified_stat.size ~= #group.output or verified_stat.mode % 512 ~= group.disk_stat.mode % 512 then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "verify_temporary", status = "failed", error = "bytes or mode did not match the reviewed output" }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("replacement_verify_failed", "temporary replacement bytes or mode did not match", { path = group.path }), false
  end
  steps[#steps + 1] = { step = "verify_temporary", status = "applied", bytes = #group.output, mode = verified_stat.mode % 512 }
  local fresh, fresh_stat = file_read(self.uv, group.path)
  if not fresh then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "reverify_preimage", status = "failed", error = fresh_stat.message }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, fresh_stat, false
  end
  if fresh ~= group.before or not same_stat(fresh_stat, group.disk_stat) then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "reverify_preimage", status = "failed", error = "source changed after review" }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("stale_preimage", "file changed while its replacement was staged", { path = group.path }), false
  end
  steps[#steps + 1] = { step = "reverify_preimage", status = "applied", path = group.path }
  local replaced, replace_error = self.uv.fs_rename(temp, group.path)
  if not replaced then
    self.uv.fs_unlink(temp)
    steps[#steps + 1] = { step = "atomic_replace", status = "failed", error = tostring(replace_error) }
    steps[#steps + 1] = { step = "remove_temporary", status = "recovered", path = temp }
    return nil, failure("atomic_replace_failed", tostring(replace_error), { path = group.path }), false
  end
  steps[#steps + 1] = { step = "atomic_replace", status = "applied", path = group.path }
  return true, nil, true
end

function Service:_apply_buffer(group, steps)
  local edits = {}
  for _, edit in ipairs(group.edits) do edits[#edits + 1] = edit end
  table.sort(edits, function(left, right)
    if left.line ~= right.line then return left.line > right.line end
    return left.start_col > right.start_col
  end)
  local applied = 0
  local ok, err = pcall(self.buffers.nvim_buf_call, group.bufnr, function()
    local undo_break = vim.api.nvim_replace_termcodes("i<C-G>u<Esc>", true, false, true)
    vim.api.nvim_feedkeys(undo_break, "nx", false)
    for _, edit in ipairs(edits) do
      if applied > 0 then vim.cmd("undojoin") end
      self.buffers.nvim_buf_set_text(group.bufnr, edit.line, edit.start_col, edit.line, edit.end_col, { edit.replacement })
      applied = applied + 1
    end
  end)
  if not ok then
    steps[#steps + 1] = { step = "apply_buffer_edits", status = applied > 0 and "partial" or "failed", path = group.path, applied_matches = applied, total_matches = #edits, error = tostring(err) }
    return nil, failure(applied > 0 and "partial_buffer_apply" or "buffer_apply_failed", tostring(err), { path = group.path, applied_matches = applied, total_matches = #edits }), applied > 0
  end
  steps[#steps + 1] = { step = "apply_buffer_edits", status = "applied", path = group.path, applied_matches = applied, total_matches = #edits, undo_grouped = true }
  return true, nil, true
end

local function recovery_summary(groups, ledger)
  local applied, unapplied = {}, {}
  for path, state in pairs(groups) do
    if state == "applied" then applied[#applied + 1] = path else unapplied[#unapplied + 1] = path end
  end
  table.sort(applied); table.sort(unapplied)
  return { applied = applied, unapplied = unapplied, ledger = ledger }
end

function Service:apply(plan)
  local live, live_error = self:_live()
  if not live then return nil, live_error end
  local record = type(plan) == "table" and self.plans[plan.id] or nil
  if not record or record.plan ~= plan then return nil, failure("unknown_plan", "replacement plan is not owned by this service") end
  if plan.state ~= "reviewed" then return nil, failure("review_required", "the exact replacement diff must be reviewed before apply") end
  if not vim.deep_equal(plan_fields(plan), record.immutable) then
    plan.state = "failed"
    record.groups = nil
    return nil, failure("plan_changed", "replacement plan changed after review")
  end
  local checked = {}
  for _, path in ipairs(plan.affected_resources) do
    local group = record.groups[path]
    local okay, verify_error = self:_verify_group(group, record.workspace.root)
    if not okay then
      local states = {}; for _, resource in ipairs(plan.affected_resources) do states[resource] = "unapplied" end
      local ledger = { { step = "preflight", resource = path, status = "failed", error = verify_error.message } }
      plan.state = "failed"
      plan.recovery = recovery_summary(states, ledger)
      plan.recovery.state = "failed"
      record.groups = nil
      return nil, verify_error
    end
    checked[#checked + 1] = path
  end
  if self.journal_enabled then
    local journal_ok, journal_error = self:_journal_record(record)
    if not journal_ok then
      plan.state = "failed"
      local states = {}; for _, path in ipairs(plan.affected_resources) do states[path] = "unapplied" end
      plan.recovery = recovery_summary(states, { { step = "journal", status = "failed", error = journal_error.message } })
      plan.recovery.state = "failed"
      record.groups = nil
      return nil, journal_error
    end
  end
  plan.state = "applying"
  local state_by_path, ledger, did_mutate = {}, {}, false
  for index, path in ipairs(checked) do
    local group = record.groups[path]
    local steps = {}
    local fresh, fresh_error = self:_verify_group(group, record.workspace.root)
    if not fresh then
      ledger[#ledger + 1] = { step = "preimage", resource = path, status = "failed", error = fresh_error.message }
      state_by_path[path] = "unapplied"
      for later = index + 1, #checked do state_by_path[checked[later]] = "unapplied" end
      plan.state = did_mutate and "partial" or "failed"
      plan.recovery = recovery_summary(state_by_path, ledger)
      plan.recovery.state = plan.state
      if record.journal then
        record.journal.state = plan.state
        record.journal.ledger = vim.deepcopy(ledger)
        for _, resource in ipairs(record.journal.resources) do resource.state = state_by_path[resource.path] or "unapplied" end
        local saved, save_error = self:_save_journal(record)
        if not saved then plan.recovery.journal_error = save_error.message end
      end
      record.groups = nil
      return nil, fresh_error
    end
    local okay, apply_error, mutated
    if group.kind == "disk" then okay, apply_error, mutated = self:_apply_disk(group, plan, index, steps)
    else okay, apply_error, mutated = self:_apply_buffer(group, steps) end
    did_mutate = did_mutate or mutated == true
    for _, step in ipairs(steps) do ledger[#ledger + 1] = vim.tbl_extend("force", { resource = path }, step) end
    state_by_path[path] = okay and "applied" or (mutated and "partial" or "unapplied")
    if record.journal then
      record.journal.ledger = vim.deepcopy(ledger)
      for _, resource in ipairs(record.journal.resources) do resource.state = state_by_path[resource.path] or "unapplied" end
      local saved, save_error = self:_save_journal(record)
      if not saved and not apply_error then apply_error = save_error end
    end
    if not okay or apply_error then
      for later = index + 1, #checked do state_by_path[checked[later]] = "unapplied" end
      plan.state = did_mutate and "partial" or "failed"
      plan.recovery = recovery_summary(state_by_path, ledger)
      plan.recovery.state = plan.state
      if record.journal then
        record.journal.state = plan.state
        record.journal.ledger = vim.deepcopy(ledger)
        for _, resource in ipairs(record.journal.resources) do resource.state = state_by_path[resource.path] or "unapplied" end
        local saved, save_error = self:_save_journal(record)
        if not saved then plan.recovery.journal_error = save_error.message end
      end
      record.groups = nil
      return nil, apply_error or failure("replacement_failed", "replacement failed", { path = path })
    end
  end
  plan.state = "applied"
  plan.recovery = recovery_summary(state_by_path, ledger)
  plan.recovery.state = "applied"
  if record.journal then
    record.journal.state = "applied"
    record.journal.ledger = vim.deepcopy(ledger)
    for _, resource in ipairs(record.journal.resources) do resource.state = "applied" end
    local saved, save_error = self:_save_journal(record)
    if not saved then plan.recovery.journal_error = save_error.message end
  end
  record.groups = nil
  return true, plan.recovery
end

function Service:recoveries()
  if not self.journal_enabled then return {}, { code = "journal_disabled", message = "replacement recovery history is disabled" } end
  local stat = self.uv.fs_lstat(self.state_dir)
  if not stat then return {} end
  if stat.type ~= "directory" then return nil, failure("journal_unavailable", "replacement recovery path is not a directory") end
  local scan, scan_error = self.uv.fs_scandir(self.state_dir)
  if not scan then return nil, failure("journal_unavailable", tostring(scan_error)) end
  local records = {}
  while true do
    local name = self.uv.fs_scandir_next(scan)
    if not name then break end
    if name:match("^replacement%-%d[%d%-]*%.json$") then
      local path = vim.fs.joinpath(self.state_dir, name)
      local file_stat = self.uv.fs_lstat(path)
      if file_stat and file_stat.type == "file" and file_stat.size <= 1024 * 1024 then
        local fd = self.uv.fs_open(path, "r", 0)
        local contents = fd and self.uv.fs_read(fd, file_stat.size, 0) or nil
        if fd then self.uv.fs_close(fd) end
        local okay, document = pcall(vim.json.decode, contents or "")
        if okay and type(document) == "table" and document.schema == 1 and type(document.id) == "string" then
          local result = {
            id = document.id,
            state = document.state == "applying" and "interrupted" or document.state,
            created_at = document.created_at,
            workspace_id = document.workspace_id,
            matched_count = document.matched_count,
            resources = vim.deepcopy(document.resources or {}),
            ledger = vim.deepcopy(document.ledger or {}),
            automatic_apply_on_restart = false,
            requires_manual_inspection = document.state == "applying" or document.state == "partial",
          }
          records[#records + 1] = result
        end
      end
    end
  end
  table.sort(records, function(left, right) return left.id < right.id end)
  return records
end

function Service:capabilities()
  return { state = "ready", operations = { "literal_single_line_replace" }, limitations = {
    "regex replacement and capture expansion are unavailable",
    "multi-file apply is sequential and not atomic",
    "only UTF-8 text and selected non-empty single-line matches are supported",
    "recovery history stores bounded disk preimages for seven days and never auto-applies on restart",
  } }
end

function Service:status()
  local active, plans = 0, {}
  for _, record in pairs(self.plans) do
    local state = record.plan.state
    if state == "validated" or state == "reviewed" or state == "applying" then active = active + 1 end
    plans[#plans + 1] = { id = record.plan.id, state = state, matched_count = record.plan.matched_count }
  end
  table.sort(plans, function(left, right) return left.id < right.id end)
  return { disposed = self.disposed, journal_enabled = self.journal_enabled, active = active, plans = plans }
end

function Service:dispose()
  if self.disposed then return false end
  self.disposed = true
  for _, record in pairs(self.plans) do
    if record.plan.state == "validated" or record.plan.state == "reviewed" then self:cancel(record.plan) end
    record.groups, record.paths, record.workspace = nil, {}, nil
  end
  return true
end

return M
