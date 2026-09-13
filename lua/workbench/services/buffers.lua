local Resource = require("workbench.core.resource")
local RootPolicy = require("workbench.core.root_policy")

local M = {
  max_listed = 512,
  max_capture_buffers = 128,
  max_buffer_bytes = 2 * 1024 * 1024,
  max_total_bytes = 16 * 1024 * 1024,
  max_ignore_bytes = 1024 * 1024,
}

local function normalized_name(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then return nil end
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then return nil end
  local path = Resource.normalize_absolute_path(name)
  if not path then return nil end
  local resource = Resource.from_path(path)
  if not resource then return nil end
  return path, resource.uri
end

local function visible_windows()
  local visible = {}
  local current = vim.api.nvim_get_current_buf()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buffer = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buffer) then visible[buffer] = visible[buffer] or win end
  end
  return visible, current
end

function M.list(opts)
  opts = opts or {}
  local maximum = math.max(1, math.min(tonumber(opts.max_items) or M.max_listed, M.max_listed))
  local visible, current = visible_windows()
  local info = {}
  for _, entry in ipairs(vim.fn.getbufinfo()) do info[entry.bufnr] = entry end

  local items, excluded = {}, { unnamed = 0, unloaded = 0, special = 0, non_file = 0 }
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.api.nvim_buf_is_valid(buffer) or not vim.api.nvim_buf_is_loaded(buffer) then
      excluded.unloaded = excluded.unloaded + 1
    elseif vim.bo[buffer].buftype ~= "" then
      excluded.special = excluded.special + 1
    else
      local path, uri = normalized_name(buffer)
      if not path then
        excluded.unnamed = excluded.unnamed + 1
      else
        local details = info[buffer] or {}
        items[#items + 1] = {
          bufnr = buffer,
          path = path,
          uri = uri,
          label = vim.fs.basename(path),
          filetype = vim.bo[buffer].filetype,
          modified = vim.bo[buffer].modified,
          changedtick = vim.api.nvim_buf_get_changedtick(buffer),
          lastused = tonumber(details.lastused) or 0,
          listed = vim.bo[buffer].buflisted,
          current = buffer == current,
          visible = visible[buffer] ~= nil,
          win = visible[buffer],
        }
      end
    end
  end
  table.sort(items, function(left, right)
    if left.current ~= right.current then return left.current end
    if left.lastused ~= right.lastused then return left.lastused > right.lastused end
    return left.bufnr > right.bufnr
  end)
  local total = #items
  local truncated = total > maximum
  while #items > maximum do items[#items] = nil end
  return { items = items, total = total, truncated = truncated, excluded = excluded }
end

local function in_scope(path, opts)
  local scope = opts.scope or { kind = "workspace" }
  if scope.kind == "open_buffers" then return true end
  if scope.kind == "file" then return vim.fs.normalize(scope.path or "") == path end
  if scope.kind == "folder" then return RootPolicy.contains(scope.path or "", path) == true end
  return RootPolicy.contains(opts.workspace_root or "", path) == true
end

local function capture_one(item, limits, used)
  local buffer = item.bufnr
  if not vim.api.nvim_buf_is_valid(buffer) or not vim.api.nvim_buf_is_loaded(buffer) then
    return nil, "buffer_unavailable"
  end
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  local lines, byte_count = {}, 0
  local line_count = vim.api.nvim_buf_line_count(buffer)
  for first = 0, line_count - 1, 256 do
    local chunk = vim.api.nvim_buf_get_lines(buffer, first, math.min(line_count, first + 256), false)
    for _, line in ipairs(chunk) do
      byte_count = byte_count + #line + 1
      if byte_count > limits.max_buffer_bytes or used + byte_count > limits.max_total_bytes then
        return nil, "snapshot_limit"
      end
      lines[#lines + 1] = line
    end
  end
  local after_tick = vim.api.nvim_buf_get_changedtick(buffer)
  if tick ~= after_tick then return nil, "buffer_changed_during_capture" end
  local ff = vim.bo[buffer].fileformat
  local separator = ff == "dos" and "\r\n" or ff == "mac" and "\r" or "\n"
  local content = table.concat(lines, separator)
  if vim.bo[buffer].endofline then content = content .. separator end
  if #content > limits.max_buffer_bytes or used + #content > limits.max_total_bytes then return nil, "snapshot_limit" end
  local snapshot_id = table.concat({ item.uri, tostring(buffer), tostring(tick), ff,
    vim.bo[buffer].endofline and "eol" or "noeol", vim.bo[buffer].bomb and "bomb" or "plain" }, "\n")
  return {
    id = snapshot_id,
    bufnr = buffer,
    path = item.path,
    uri = item.uri,
    changedtick = tick,
    fileformat = ff,
    endofline = vim.bo[buffer].endofline,
    bomb = vim.bo[buffer].bomb,
    fileencoding = vim.bo[buffer].fileencoding,
    encoding = "utf-8",
    line_count = line_count,
    byte_size = #content,
    modified = vim.bo[buffer].modified,
    content = content,
  }
end

function M.capture(opts)
  opts = opts or {}
  local limits = {
    max_buffers = math.max(1, math.min(tonumber(opts.max_buffers) or M.max_capture_buffers, M.max_capture_buffers)),
    max_buffer_bytes = math.max(1, math.min(tonumber(opts.max_buffer_bytes) or M.max_buffer_bytes, M.max_buffer_bytes)),
    max_total_bytes = math.max(1, math.min(tonumber(opts.max_total_bytes) or M.max_total_bytes, M.max_total_bytes)),
  }
  local listed = M.list({ max_items = M.max_listed })
  local snapshots, used = {}, 0
  local candidates, over_limit, seen, skipped_uris = 0, 0, {}, {}
  for _, item in ipairs(listed.items) do
    if (not opts.modified_only or item.modified) and in_scope(item.path, opts) and not seen[item.uri] then
      seen[item.uri] = true
      candidates = candidates + 1
      if #snapshots >= limits.max_buffers then
        over_limit = over_limit + 1
        skipped_uris[#skipped_uris + 1] = item.uri
      else
        local snapshot, err = capture_one(item, limits, used)
        if snapshot then
          snapshots[#snapshots + 1] = snapshot
          used = used + snapshot.byte_size
        elseif err == "buffer_changed_during_capture" then
          return nil, { code = err, message = "a named buffer changed while its immutable search snapshot was being captured", bufnr = item.bufnr }
        elseif err == "snapshot_limit" then
          over_limit = over_limit + 1
          skipped_uris[#skipped_uris + 1] = item.uri
        end
      end
    end
  end
  return {
    snapshots = snapshots,
    candidate_count = candidates,
    skipped_count = over_limit + math.max(0, listed.total - #listed.items),
    skipped_uris = skipped_uris,
    total_bytes = used,
    excluded = listed.excluded,
    limits = limits,
  }
end

function M.is_current(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.bufnr) ~= "number"
    or not vim.api.nvim_buf_is_valid(snapshot.bufnr) or not vim.api.nvim_buf_is_loaded(snapshot.bufnr) then
    return false
  end
  local path = normalized_name(snapshot.bufnr)
  return path == snapshot.path
    and vim.api.nvim_buf_get_changedtick(snapshot.bufnr) == snapshot.changedtick
    and vim.bo[snapshot.bufnr].fileformat == snapshot.fileformat
    and vim.bo[snapshot.bufnr].endofline == snapshot.endofline
    and vim.bo[snapshot.bufnr].bomb == snapshot.bomb
    and vim.bo[snapshot.bufnr].fileencoding == snapshot.fileencoding
end

local function read_file(path, limit)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_lstat(path)
  if not stat then return nil end
  if stat.type ~= "file" then return nil, { code = "ignore_file_unsupported", message = "ignore rules must be regular files to mirror a buffer search" } end
  if stat.size > limit then return nil, { code = "ignore_file_too_large", message = "an ignore file exceeded the buffer-search mirror limit" } end
  local fd, open_err = uv.fs_open(path, "r", 0)
  if not fd then return nil, { code = "ignore_read_failed", message = tostring(open_err) } end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then return nil, { code = "ignore_read_failed", message = tostring(read_err) } end
  return data
end

local function write_file(path, value)
  local uv = vim.uv or vim.loop
  local parent = vim.fs.dirname(path)
  local made = vim.fn.mkdir(parent, "p", 448)
  if made ~= 1 and made ~= 2 then return nil, { code = "snapshot_directory_failed", message = "snapshot directory could not be created" } end
  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then return nil, { code = "snapshot_write_failed", message = tostring(open_err) } end
  local written, write_err = uv.fs_write(fd, value, 0)
  uv.fs_close(fd)
  if written ~= #value then return nil, { code = "snapshot_write_failed", message = tostring(write_err or "short snapshot write") } end
  return true
end

local function relative_for(snapshot, opts)
  local relative = opts.workspace_root and vim.fs.relpath(opts.workspace_root, snapshot.path) or nil
  if relative and relative ~= ".." and not relative:match("^%.%.[/\\]") then return relative, true end
  local name = vim.fs.basename(snapshot.path)
  return vim.fs.joinpath("external", vim.fn.sha256(snapshot.uri):sub(1, 20), name), false
end

local function mirror_ignore_rules(snapshots, root, opts)
  if not opts.mirror_ignore or type(opts.workspace_root) ~= "string" then return true end
  local seen, root_path = {}, opts.workspace_root
  local names = { ".gitignore", ".ignore", ".rgignore" }
  for _, snapshot in ipairs(snapshots) do
    local relative = vim.fs.relpath(root_path, snapshot.path)
    if relative and relative ~= ".." and not relative:match("^%.%.[/\\]") then
      local parent = vim.fs.dirname(relative)
      local ancestors = { "" }
      if parent ~= "." then
        local current = ""
        for part in parent:gmatch("[^/\\]+") do
          current = current == "" and part or vim.fs.joinpath(current, part)
          ancestors[#ancestors + 1] = current
        end
      end
      for _, directory in ipairs(ancestors) do
        for _, name in ipairs(names) do
          local relative_ignore = directory == "" and name or vim.fs.joinpath(directory, name)
          if not seen[relative_ignore] then
            seen[relative_ignore] = true
            local source = vim.fs.joinpath(root_path, relative_ignore)
            local contents, read_err = read_file(source, M.max_ignore_bytes)
            if read_err then return nil, read_err end
            if contents then
              local okay, write_err = write_file(vim.fs.joinpath(root, relative_ignore), contents)
              if not okay then return nil, write_err end
            end
          end
        end
      end
    end
  end
  return true
end

function M.stage(snapshots, opts)
  opts = opts or {}
  if type(snapshots) ~= "table" or #snapshots == 0 then return nil, { code = "empty_snapshot", message = "no buffer snapshots were supplied" } end
  local uv = vim.uv or vim.loop
  local temp = vim.fs.joinpath(vim.env.TMPDIR or "/tmp", "workbench-buffer-search-XXXXXX")
  local root, temp_err = uv.fs_mkdtemp(temp)
  if not root then return nil, { code = "snapshot_directory_failed", message = tostring(temp_err or "temporary directory could not be created") } end
  local staged = { root = vim.fs.normalize(root), files = {}, by_path = {}, disposed = false }
  function staged:dispose()
    if self.disposed then return false end
    self.disposed = true
    local stat = uv.fs_lstat(self.root)
    if stat and stat.type == "directory" then pcall(vim.fn.delete, self.root, "rf") end
    self.files, self.by_path = {}, {}
    return true
  end

  local okay, stage_err = mirror_ignore_rules(snapshots, staged.root, opts)
  if not okay then staged:dispose(); return nil, stage_err end
  for _, snapshot in ipairs(snapshots) do
    local relative, inside = relative_for(snapshot, opts)
    local path = vim.fs.normalize(vim.fs.joinpath(staged.root, relative))
    local contained = RootPolicy.contains(staged.root, path)
    if not contained then staged:dispose(); return nil, { code = "snapshot_path_invalid", message = "a buffer path could not be mirrored safely" } end
    local wrote, write_err = write_file(path, snapshot.content)
    if not wrote then staged:dispose(); return nil, write_err end
    local record = { snapshot = snapshot, original_path = snapshot.path, staged_path = path, relative_path = relative, inside_workspace = inside }
    staged.files[#staged.files + 1] = record
    staged.by_path[path] = record
  end
  return staged
end

return M
