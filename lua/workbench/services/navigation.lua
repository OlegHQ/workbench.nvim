local Location = require("workbench.core.location")

local M = {}
local Navigation = {}
Navigation.__index = Navigation

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, normalized = pcall(vim.fs.normalize, path)
  return ok and normalized or nil
end

local function paths_equal(left, right)
  local a, b = normalize_path(left), normalize_path(right)
  if not a or not b then return false end
  if a == b then return true end
  local uv = vim.uv or vim.loop
  local real_a, real_b = uv.fs_realpath(a), uv.fs_realpath(b)
  return real_a ~= nil and real_a == real_b
end

local function normalize_location(location)
  if type(location) ~= "table" or type(location.resource) ~= "table" then
    return nil, "navigation requires a structured location"
  end
  local source = location.resource
  if type(source.uri) ~= "string" or type(source.scheme) ~= "string" then
    return nil, "location resource requires a URI and scheme"
  end
  for _, field in ipairs({ "workspace_id", "display_path" }) do
    if source[field] ~= nil and type(source[field]) ~= "string" then return nil, "resource " .. field .. " must be a string" end
  end
  local resource = {
    uri = source.uri,
    scheme = source.scheme,
    path = source.path,
    workspace_id = source.workspace_id,
    display_path = source.display_path,
  }
  local opts = {}
  for _, field in ipairs({ "range", "encoding", "version", "client_id" }) do
    if location[field] ~= nil then opts[field] = location[field] end
  end
  local normalized, err = Location.new(resource, opts)
  if not normalized then return nil, err end
  if normalized.resource.scheme == "file" then
    local path, path_err = normalize_path(normalized.resource.path)
    if not path then return nil, path_err or "file resource requires an absolute native path" end
    local ok, expected_uri = pcall(vim.uri_from_fname, path)
    if not ok or expected_uri ~= normalized.resource.uri then
      return nil, "file resource URI does not match its native path"
    end
    normalized.resource.path = path
  end
  return normalized
end

local function path_for(location)
  if type(location) ~= "table" or type(location.resource) ~= "table" then
    return nil, "navigation requires a structured location"
  end
  local resource = location.resource
  if resource.scheme ~= "file" or type(resource.path) ~= "string" or resource.path == "" then
    return nil, "only file resources support preview and editor navigation"
  end
  if type(resource.uri) ~= "string" then return nil, "file location is missing its URI" end
  return normalize_path(resource.path)
end

local function is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  local config = vim.api.nvim_win_get_config(win)
  if config.relative ~= "" then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= "" or vim.b[buf].workbench_preview then return false end
  return true
end

local function loaded_buffer(path)
  local uv = vim.uv or vim.loop
  local canonical = uv.fs_realpath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local normalized_name = name ~= "" and normalize_path(name) or nil
      if normalized_name == path or (canonical and normalized_name == canonical) then return buf end
      if canonical and normalized_name and uv.fs_realpath(name) == canonical then return buf end
    end
  end
end

local function any_buffer(path)
  local uv = vim.uv or vim.loop
  local canonical = uv.fs_realpath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local normalized_name = name ~= "" and normalize_path(name) or nil
      if normalized_name == path or (canonical and normalized_name == canonical) then return buf end
      if canonical and normalized_name and uv.fs_realpath(name) == canonical then return buf end
    end
  end
end

local function discard_preflight_buffer(buf, owned)
  if not owned or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].modified then return end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then return end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function split_lines(raw)
  local result = {}
  raw = raw or ""
  if raw == "" then return { "" } end
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    result[#result + 1] = line
  end
  if raw:sub(-1) == "\n" then result[#result] = "" end
  return result
end

local function preview_from_lines(path, lines, target_line, opts, source, modified, truncated)
  local count = #lines
  if target_line >= count then
    return nil, { code = "line_unavailable", message = "requested preview line is outside the available file content", truncated = truncated or false }
  end
  local first = math.max(0, target_line - opts.context_before)
  local last = math.min(count - 1, target_line + opts.context_after)
  if last - first + 1 > opts.max_lines then
    local before = math.min(target_line - first, math.floor((opts.max_lines - 1) / 2))
    first = target_line - before
    last = math.min(count - 1, first + opts.max_lines - 1)
    if target_line > last then first = target_line - opts.max_lines + 1; last = target_line end
    truncated = true
  end
  local function line_at(index)
    local line = lines[index + 1] or ""
    local cap = math.min(opts.max_line_bytes, opts.max_output_bytes)
    if #line > cap then line = line:sub(1, cap); truncated = true end
    return line
  end
  local selected, bytes = { [target_line] = line_at(target_line) }, 0
  bytes = #selected[target_line]
  local before_open, after_open = true, true
  for distance = 1, opts.max_lines do
    local before_index, after_index = target_line - distance, target_line + distance
    if before_index >= first and before_open then
      local line = line_at(before_index)
      if bytes + #line <= opts.max_output_bytes then
        selected[before_index] = line
        bytes = bytes + #line
      else
        before_open, truncated = false, true
      end
    end
    if after_index <= last and after_open then
      local line = line_at(after_index)
      if bytes + #line <= opts.max_output_bytes then
        selected[after_index] = line
        bytes = bytes + #line
      else
        after_open, truncated = false, true
      end
    end
    if before_index < first and after_index > last then break end
  end
  local context = {}
  local actual_first = target_line
  while selected[actual_first - 1] ~= nil do actual_first = actual_first - 1 end
  local actual_last = target_line
  while selected[actual_last + 1] ~= nil do actual_last = actual_last + 1 end
  for index = actual_first, actual_last do context[#context + 1] = selected[index] end
  return {
    path = path,
    source = source,
    modified = modified or false,
    lines = context,
    first_line = actual_first,
    target_line = target_line,
    target_index = target_line - actual_first + 1,
    truncated = truncated or false,
    total_bytes = bytes,
  }
end

local function session_key(session)
  local key
  if type(session) == "table" then key = session.id or session.session_id or "default"
  elseif type(session) == "string" and session ~= "" then key = session
  else key = "default" end
  if type(key) ~= "string" or key == "" or #key > 128 then return nil, "session ID must be a non-empty string of at most 128 bytes" end
  return key
end

local function jumplist_count(win)
  local ok, result = pcall(function()
    local value = vim.fn.getjumplist(win or 0)
    return type(value) == "table" and type(value[1]) == "table" and #value[1] or nil
  end)
  return ok and result or nil
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "navigation options must be a table" end
  local limits = {
    context_before = opts.context_before or 3,
    context_after = opts.context_after or 3,
    max_lines = opts.max_lines or 100,
    max_line_bytes = opts.max_line_bytes or 16 * 1024,
    max_output_bytes = opts.max_output_bytes or 256 * 1024,
    max_scan_bytes = opts.max_scan_bytes or 4 * 1024 * 1024,
    chunk_bytes = opts.chunk_bytes or 64 * 1024,
    max_pending_previews = opts.max_pending_previews or 8,
    max_history_sessions = opts.max_history_sessions or 16,
    max_entries_per_session = opts.max_entries_per_session or 32,
  }
  for name, value in pairs(limits) do
    local minimum = (name == "context_before" or name == "context_after") and 0 or 1
    if type(value) ~= "number" or value < minimum or value % 1 ~= 0 then
      return nil, name .. " must be a non-negative/positive integer"
    end
  end
  return setmetatable({ limits = limits, previews = {}, requests = {}, histories = {}, disposed = false }, Navigation)
end

function Navigation:_is_active(request)
  return not self.disposed and not request.cancelled and self.previews[request.session_id] == request
end

function Navigation:_complete_preview(request, result)
  if request.fd then
    local fd = request.fd
    request.fd = nil
    pcall((vim.uv or vim.loop).fs_close, fd, function() end)
  end
  if self.previews[request.session_id] == request then self.previews[request.session_id] = nil end
  self.requests[request] = nil
  if request.cancelled or self.disposed then return end
  vim.schedule(function()
    if request.cancelled or self.disposed or request.delivered then return end
    request.delivered = true
    if request.callback then
      local ok, err = pcall(request.callback, result)
      if not ok then request.callback_error = tostring(err) end
    end
  end)
end

function Navigation:cancel_preview(session)
  local key = session_key(session)
  if not key then return false end
  local request = self.previews[key]
  if not request then return false end
  self.previews[key] = nil
  request.cancelled = true
  -- In-flight libuv reads complete against their descriptor; their callback closes it.
  if request.fd and not request.reading then
    local fd = request.fd
    request.fd = nil
    pcall((vim.uv or vim.loop).fs_close, fd, function() end)
  end
  return true
end

function Navigation:preview(location, session, callback, opts)
  if self.disposed then return nil, { code = "disposed", message = "navigation service is disposed" } end
  if callback ~= nil and type(callback) ~= "function" then return nil, { code = "invalid_callback", message = "preview callback must be a function" } end
  local limits = self.limits
  if opts ~= nil then
    if type(opts) ~= "table" or type(opts.max_output_bytes) ~= "number"
      or opts.max_output_bytes < 1 or opts.max_output_bytes % 1 ~= 0 then
      return nil, { code = "invalid_preview_options", message = "max_output_bytes must be a positive integer" }
    end
    for key in pairs(opts) do
      if key ~= "max_output_bytes" then return nil, { code = "invalid_preview_options", message = "unknown preview option: " .. tostring(key) } end
    end
    limits = vim.tbl_extend("force", limits, { max_output_bytes = math.min(opts.max_output_bytes, limits.max_output_bytes) })
  end
  local normalized, location_err = normalize_location(location)
  if not normalized then return nil, { code = "invalid_location", message = location_err } end
  location = normalized
  local path, path_err = path_for(location)
  if not path then return nil, { code = "unsupported_location", message = path_err or "location path is invalid" } end
  local line = 0
  if location.range then line = location.range.start and location.range.start.line or -1 end
  if type(line) ~= "number" or line < 0 or line % 1 ~= 0 then return nil, { code = "invalid_location", message = "preview line must be a non-negative integer" } end
  local key, key_err = session_key(session)
  if not key then return nil, { code = "invalid_session", message = key_err } end
  self:cancel_preview(key)
  local pending = 0
  for _ in pairs(self.requests) do pending = pending + 1 end
  if pending >= limits.max_pending_previews then
    return nil, { code = "preview_capacity", message = "too many bounded preview reads are still draining" }
  end
  local request = { session_id = key, callback = callback, cancelled = false }
  self.previews[key] = request
  self.requests[request] = true

  local buf = loaded_buffer(path)
  if buf then
    local total = vim.api.nvim_buf_line_count(buf)
    local first = math.max(0, line - limits.context_before)
    local last = math.min(total, line + limits.context_after + 1)
    local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local result, err = preview_from_lines(path, lines, line - first, limits, "buffer", vim.bo[buf].modified, false)
    if result then result.first_line = first; result.target_line = line; result.target_index = line - first + 1 end
    vim.schedule(function()
      if self:_is_active(request) then
        if result then self:_complete_preview(request, result)
        else self:_complete_preview(request, err) end
      else
        self.requests[request] = nil
      end
    end)
    return request
  end

  local uv = vim.uv or vim.loop
  uv.fs_open(path, "r", 438, function(open_err, fd)
    if not self:_is_active(request) then
      if fd then pcall(uv.fs_close, fd, function() end) end
      self.requests[request] = nil
      return
    end
    if open_err or not fd then
      self:_complete_preview(request, { code = "read_error", message = tostring(open_err or "could not open file for preview") })
      return
    end
    request.fd = fd
    request.raw = ""
    request.offset = 0
    request.line_breaks = 0
    request.read_next = function()
      if not self:_is_active(request) then
        request.reading = false
        self:_complete_preview(request, nil)
        return
      end
      local remaining = limits.max_scan_bytes - request.offset
      if remaining <= 0 then
        local result, err = preview_from_lines(path, split_lines(request.raw), line, limits, "disk", false, true)
        self:_complete_preview(request, result or err)
        return
      end
      local amount = math.min(limits.chunk_bytes, remaining)
      request.reading = true
      uv.fs_read(fd, amount, request.offset, function(read_err, data)
        request.reading = false
        if not self:_is_active(request) then self:_complete_preview(request, nil); return end
        if read_err then self:_complete_preview(request, { code = "read_error", message = tostring(read_err) }); return end
        if not data or #data == 0 then
          local result, err = preview_from_lines(path, split_lines(request.raw), line, limits, "disk", false, false)
          self:_complete_preview(request, result or err)
          return
        end
        request.raw = request.raw .. data
        request.offset = request.offset + #data
        request.line_breaks = request.line_breaks + select(2, data:gsub("\n", ""))
        local needed_breaks = line + limits.context_after + 1
        if request.line_breaks >= needed_breaks then
          local result, err = preview_from_lines(path, split_lines(request.raw), line, limits, "disk", false, false)
          self:_complete_preview(request, result or err)
          return
        end
        request.read_next()
      end)
    end
    request.read_next()
  end)
  return request
end

local function capture_origin(win)
  if not is_editor_window(win) then return nil, "origin must be a normal editor window" end
  local buf = vim.api.nvim_win_get_buf(win)
  return {
    win = win,
    buf = buf,
    cursor = vim.api.nvim_win_get_cursor(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    tab = vim.api.nvim_win_get_tabpage(win),
  }
end

local function choose_origin(origin)
  local win = type(origin) == "number" and origin or (type(origin) == "table" and origin.win) or vim.api.nvim_get_current_win()
  if not win or not is_editor_window(win) then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
      if is_editor_window(candidate) then win = candidate; break end
    end
  end
  if not win or not is_editor_window(win) then return nil, "no normal editor window is available for navigation" end
  if type(origin) == "table" and origin.buf and origin.cursor then
    local record = vim.deepcopy(origin)
    record.win = win
    record.tab = vim.api.nvim_win_get_tabpage(win)
    return record
  end
  return capture_origin(win)
end

local function rollback_destination(mode, origin, dest_win)
  if mode ~= "current" and dest_win and vim.api.nvim_win_is_valid(dest_win) then
    pcall(vim.api.nvim_win_close, dest_win, true)
  elseif vim.api.nvim_win_is_valid(origin.win) and vim.api.nvim_buf_is_valid(origin.buf) then
    pcall(vim.api.nvim_win_set_buf, origin.win, origin.buf)
    pcall(vim.api.nvim_win_set_cursor, origin.win, origin.cursor)
    pcall(vim.api.nvim_win_call, origin.win, function() vim.fn.winrestview(origin.view) end)
  end
end

local function resolve_cursor(location, buf)
  if not location.range then return { 1, 0 } end
  local first_line, last_line = location.range.start.line, location.range.finish.line
  local lines = {}
  for _, line in ipairs({ first_line, last_line }) do
    if lines[line + 1] == nil then
      lines[line + 1] = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
    end
  end
  local range, err = Location.resolve_range(location, lines)
  if not range then return nil, err end
  return { range.start.line + 1, range.start.character }
end

local function create_destination(mode, origin)
  vim.api.nvim_set_current_win(origin.win)
  if mode == "current" then return origin.win end
  if mode == "split" or mode == "horizontal" then
    vim.api.nvim_cmd({ cmd = "split" }, {})
  elseif mode == "vsplit" or mode == "vertical" then
    vim.api.nvim_cmd({ cmd = "vsplit" }, {})
  elseif mode == "tab" then
    vim.api.nvim_cmd({ cmd = "tabnew" }, {})
  else
    return nil, "mode must be current, split, vsplit, or tab"
  end
  return vim.api.nvim_get_current_win()
end

function Navigation:open(location, mode, origin, session)
  if self.disposed then return nil, { code = "disposed", message = "navigation service is disposed" } end
  local normalized, location_err = normalize_location(location)
  if not normalized then return nil, { code = "invalid_location", message = location_err } end
  location = normalized
  local path, path_err = path_for(location)
  if not path then return nil, { code = "unsupported_location", message = path_err or "location path is invalid" } end
  mode = mode or "current"
  if mode == "horizontal" then mode = "split" elseif mode == "vertical" then mode = "vsplit" end
  if mode ~= "current" and mode ~= "split" and mode ~= "vsplit" and mode ~= "tab" then
    return nil, { code = "invalid_mode", message = "mode must be current, split, vsplit, or tab" }
  end
  local captured, origin_err = choose_origin(origin)
  if not captured then return nil, { code = "invalid_origin", message = origin_err } end
  local key, key_err = session_key(session or (type(origin) == "table" and origin.session_id) or nil)
  if not key then return nil, { code = "invalid_session", message = key_err } end
  local history = self.histories[key]
  if not history then
    local sessions = 0
    for _ in pairs(self.histories) do sessions = sessions + 1 end
    if sessions >= self.limits.max_history_sessions then
      return nil, { code = "history_capacity", message = "navigation history reached its retained session limit" }
    end
  elseif #history >= self.limits.max_entries_per_session then
    return nil, { code = "history_capacity", message = "navigation history reached its retained entry limit" }
  end
  if mode == "current" and vim.bo[captured.buf].modified and not paths_equal(vim.api.nvim_buf_get_name(captured.buf), path) then
    return nil, { code = "modified_origin", message = "origin buffer has unsaved changes; choose split, vsplit, or tab" }
  end
  local preflight_buf, preflight_owned
  if location.range then
    preflight_buf = any_buffer(path)
    if not preflight_buf then
      preflight_buf = vim.fn.bufadd(path)
      preflight_owned = true
      if not preflight_buf or preflight_buf < 1 then
        return nil, { code = "open_error", message = "could not allocate a hidden target buffer for range validation" }
      end
      vim.bo[preflight_buf].buflisted = false
    end
    local loaded, load_result = pcall(vim.fn.bufload, preflight_buf)
    if not loaded or not vim.api.nvim_buf_is_loaded(preflight_buf) then
      discard_preflight_buffer(preflight_buf, preflight_owned)
      return nil, { code = "open_error", message = tostring(load_result or "target buffer could not be loaded for validation") }
    end
    local _, range_err = resolve_cursor(location, preflight_buf)
    if range_err then
      discard_preflight_buffer(preflight_buf, preflight_owned)
      return nil, { code = "stale_location", message = range_err }
    end
  end
  local ok_dest, dest_win, dest_err = pcall(create_destination, mode, captured)
  if not ok_dest or not dest_win then
    discard_preflight_buffer(preflight_buf, preflight_owned)
    return nil, { code = "window_error", message = tostring(dest_err or dest_win) }
  end
  local before = jumplist_count(dest_win)
  local current_buf = vim.api.nvim_win_get_buf(dest_win)
  local same_file = paths_equal(vim.api.nvim_buf_get_name(current_buf), path)
  local ok_open, open_err = true, nil
  if not same_file then
    ok_open, open_err = pcall(vim.api.nvim_win_call, dest_win, function()
      vim.api.nvim_cmd({ cmd = "edit", args = { path } }, {})
    end)
  end
  if not ok_open then
    rollback_destination(mode, captured, dest_win)
    discard_preflight_buffer(preflight_buf, preflight_owned)
    return nil, { code = "open_error", message = tostring(open_err) }
  end
  local target_buf = vim.api.nvim_win_get_buf(dest_win)
  local cursor, cursor_err = resolve_cursor(location, target_buf)
  if not cursor then
    rollback_destination(mode, captured, dest_win)
    discard_preflight_buffer(preflight_buf, preflight_owned)
    return nil, { code = "stale_location", message = cursor_err }
  end
  local line_count = vim.api.nvim_buf_line_count(target_buf)
  cursor[1] = math.min(math.max(1, cursor[1]), line_count)
  local line = vim.api.nvim_buf_get_lines(target_buf, cursor[1] - 1, cursor[1], false)[1] or ""
  cursor[2] = math.min(cursor[2], #line)
  if same_file then
    local current_cursor = vim.api.nvim_win_get_cursor(dest_win)
    if current_cursor[1] ~= cursor[1] then
      vim.api.nvim_win_call(dest_win, function()
        vim.api.nvim_cmd({ cmd = "normal", bang = true, args = { tostring(cursor[1]) .. "G" } }, {})
      end)
    end
  end
  vim.api.nvim_win_set_cursor(dest_win, cursor)
  local after = jumplist_count(dest_win)
  local entry = {
    origin = captured,
    target_win = dest_win,
    target_buf = target_buf,
    mode = mode,
    location = location,
    jumps_added = before and after and math.max(0, after - before) or nil,
  }
  self.histories[key] = self.histories[key] or {}
  self.histories[key][#self.histories[key] + 1] = entry
  return {
    win = dest_win,
    buf = target_buf,
    cursor = vim.deepcopy(cursor),
    mode = mode,
    jumps_added = entry.jumps_added,
    origin_win = captured.win,
  }
end

function Navigation:open_buffer(bufnr, mode, origin, session, location)
  local Resource = require("workbench.core.resource")
  if self.disposed then return nil, { code = "disposed", message = "navigation service is disposed" } end
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr)
    or vim.bo[bufnr].buftype ~= "" then
    return nil, { code = "buffer_unavailable", message = "buffer navigation requires a loaded normal buffer" }
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  local normalized, path_err = Resource.normalize_absolute_path(path)
  if not normalized then return nil, { code = "unsupported_location", message = path_err or "buffer has no native file path" } end
  path = normalized
  local normalized_location
  if location ~= nil then
    local location_err
    normalized_location, location_err = normalize_location(location)
    if not normalized_location then return nil, { code = "invalid_location", message = location_err } end
    local target_path = path_for(normalized_location)
    if not target_path or not paths_equal(target_path, path) then
      return nil, { code = "buffer_location_mismatch", message = "location does not identify the requested buffer" }
    end
  end
  mode = mode or "current"
  if mode == "horizontal" then mode = "split" elseif mode == "vertical" then mode = "vsplit" end
  if mode ~= "current" and mode ~= "split" and mode ~= "vsplit" and mode ~= "tab" then
    return nil, { code = "invalid_mode", message = "mode must be current, split, vsplit, or tab" }
  end
  local captured, origin_err = choose_origin(origin)
  if not captured then return nil, { code = "invalid_origin", message = origin_err } end
  local key, key_err = session_key(session or (type(origin) == "table" and origin.session_id) or nil)
  if not key then return nil, { code = "invalid_session", message = key_err } end
  local history = self.histories[key]
  if not history then
    local sessions = 0
    for _ in pairs(self.histories) do sessions = sessions + 1 end
    if sessions >= self.limits.max_history_sessions then
      return nil, { code = "history_capacity", message = "navigation history reached its retained session limit" }
    end
  elseif #history >= self.limits.max_entries_per_session then
    return nil, { code = "history_capacity", message = "navigation history reached its retained entry limit" }
  end
  if mode == "current" and vim.bo[captured.buf].modified and captured.buf ~= bufnr then
    return nil, { code = "modified_origin", message = "origin buffer has unsaved changes; choose split, vsplit, or tab" }
  end
  local okay, dest_win, dest_err = pcall(create_destination, mode, captured)
  if not okay or not dest_win then return nil, { code = "window_error", message = tostring(dest_err or dest_win) } end
  local before = jumplist_count(dest_win)
  local set_ok, set_err = pcall(vim.api.nvim_win_set_buf, dest_win, bufnr)
  if not set_ok then
    rollback_destination(mode, captured, dest_win)
    return nil, { code = "open_error", message = tostring(set_err) }
  end
  local cursor = { 1, 0 }
  if normalized_location and normalized_location.range then
    local resolved, range_err = resolve_cursor(normalized_location, bufnr)
    if not resolved then
      rollback_destination(mode, captured, dest_win)
      return nil, { code = "stale_location", message = range_err }
    end
    cursor = resolved
  end
  cursor[1] = math.min(math.max(1, cursor[1]), vim.api.nvim_buf_line_count(bufnr))
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  cursor[2] = math.min(cursor[2], #line)
  vim.api.nvim_win_set_cursor(dest_win, cursor)
  local after = jumplist_count(dest_win)
  local entry = {
    origin = captured,
    target_win = dest_win,
    target_buf = bufnr,
    mode = mode,
    location = normalized_location,
    jumps_added = before and after and math.max(0, after - before) or nil,
  }
  self.histories[key] = self.histories[key] or {}
  self.histories[key][#self.histories[key] + 1] = entry
  return {
    win = dest_win,
    buf = bufnr,
    cursor = vim.deepcopy(cursor),
    mode = mode,
    jumps_added = entry.jumps_added,
    origin_win = captured.win,
  }
end

local function windows()
  local result = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if is_editor_window(win) then result[#result + 1] = { win = win, tab = tab } end
      end
    end
  end
  return result
end

local function restore_origin(origin)
  if not vim.api.nvim_buf_is_valid(origin.buf) then return nil, "origin buffer was wiped" end
  local win = origin.win
  local fallback = false
  if not win or not vim.api.nvim_win_is_valid(win) then
    fallback = true
    local candidates = windows()
    local candidate
    for _, value in ipairs(candidates) do
      if value.tab == origin.tab then candidate = value; break end
    end
    candidate = candidate or candidates[1]
    if candidate then
      vim.api.nvim_set_current_win(candidate.win)
      vim.api.nvim_cmd({ cmd = "split" }, {})
      win = vim.api.nvim_get_current_win()
    else
      local current = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(current) then return nil, "no editor window remains to restore navigation" end
      vim.api.nvim_cmd({ cmd = "split" }, {})
      win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_win_set_buf(win, origin.buf)
  elseif vim.api.nvim_win_get_buf(win) ~= origin.buf then
    vim.api.nvim_win_set_buf(win, origin.buf)
  end
  if not vim.api.nvim_win_is_valid(win) then return nil, "origin window is unavailable" end
  vim.api.nvim_set_current_win(win)
  local count = vim.api.nvim_buf_line_count(origin.buf)
  local cursor = origin.cursor or { 1, 0 }
  vim.api.nvim_win_set_cursor(win, { math.min(math.max(1, cursor[1]), count), math.max(0, cursor[2]) })
  if origin.view then pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(origin.view) end) end
  return { win = win, buf = origin.buf, fallback = fallback }
end

function Navigation:return_to_origin(session)
  if self.disposed then return nil, { code = "disposed", message = "navigation service is disposed" } end
  local key, key_err = session_key(session)
  if not key then return nil, { code = "invalid_session", message = key_err } end
  local history = self.histories[key]
  if not history or #history == 0 then return nil, { code = "no_navigation", message = "there is no committed navigation to return from" } end
  local entry = history[#history]
  local restored, restore_err = restore_origin(entry.origin)
  if not restored then return nil, { code = "origin_unavailable", message = restore_err } end
  table.remove(history)
  if #history == 0 then self.histories[key] = nil end
  return restored
end

function Navigation:status()
  local active = 0
  for _ in pairs(self.previews) do active = active + 1 end
  local commits = 0
  for _, history in pairs(self.histories) do commits = commits + #history end
  local pending = 0
  for _ in pairs(self.requests) do pending = pending + 1 end
  return { disposed = self.disposed, active_previews = active, pending_reads = pending, navigation_entries = commits }
end

function Navigation:dispose()
  if self.disposed then return false end
  local keys = {}
  for key in pairs(self.previews) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do self:cancel_preview(key) end
  self.histories = {}
  self.disposed = true
  return true
end

return M
