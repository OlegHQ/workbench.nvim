local Resource = require("workbench.core.resource")

local M = {}
local Preview = {}
Preview.__index = Preview

local function editor_window(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and not vim.b[buf].workbench_preview
end

local function source_window()
  local current = vim.api.nvim_get_current_win()
  if editor_window(current) then return current end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    if editor_window(win) then return win end
  end
end

local function utf8_width(value, index)
  local first = value:byte(index)
  if first < 0x80 then return 1 end
  local width, minimum, codepoint
  if first >= 0xC2 and first <= 0xDF then width, minimum, codepoint = 2, 0x80, first - 0xC0
  elseif first >= 0xE0 and first <= 0xEF then width, minimum, codepoint = 3, 0x800, first - 0xE0
  elseif first >= 0xF0 and first <= 0xF4 then width, minimum, codepoint = 4, 0x10000, first - 0xF0
  else return nil end
  if index + width - 1 > #value then return nil end
  for offset = 1, width - 1 do
    local byte = value:byte(index + offset)
    if byte < 0x80 or byte > 0xBF then return nil end
    codepoint = codepoint * 64 + byte - 0x80
  end
  if codepoint < minimum or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then return nil end
  return width
end

local function display_line(value, cap)
  local result = {}
  local index, bytes, truncated = 1, 0, false
  local function push(text)
    if bytes + #text > cap then truncated = true; return false end
    result[#result + 1] = text
    bytes = bytes + #text
    return true
  end
  while index <= #value do
    local byte = value:byte(index)
    if byte < 32 or byte == 127 then
      if not push(string.format("\\x%02X", byte)) then break end
      index = index + 1
    elseif byte >= 0x80 then
      local width = utf8_width(value, index)
      if width then
        if not push(value:sub(index, index + width - 1)) then break end
        index = index + width
      else
        if not push(string.format("\\x%02X", byte)) then break end
        index = index + 1
      end
    else
      if not push(value:sub(index, index)) then break end
      index = index + 1
    end
  end
  local line = table.concat(result)
  if truncated and bytes + #"…" <= cap then line = line .. "…" end
  return line
end

local function render_lines(result, max_line_bytes)
  if type(result) == "table" and result.status == "loading" then
    local file = Resource.escape_display(result.path or "")
    return {
      string.format("[Preview] %s:%d", file, (result.target_line or 0) + 1),
      "Loading bounded source context…",
    }
  end
  if type(result) ~= "table" or type(result.lines) ~= "table" then
    local message = type(result) == "table" and result.message or "preview unavailable"
    return { "[Preview unavailable] " .. display_line(tostring(message), max_line_bytes) }
  end
  local file = Resource.escape_display(result.path or "")
  local marker = result.modified and " [modified buffer]" or ""
  local lines = { string.format("[Preview] %s:%d%s", file, (result.target_line or 0) + 1, marker) }
  for index, value in ipairs(result.lines) do
    local number = (result.first_line or 0) + index
    local selected = index == result.target_index and "▶" or " "
    local body = type(value) == "string" and value or tostring(value)
    lines[#lines + 1] = string.format("%s %5d │ %s", selected, number, display_line(body, max_line_bytes))
  end
  if result.truncated then lines[#lines + 1] = "… preview truncated by the configured read limit …" end
  return lines
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "preview options must be a table" end
  if type(opts.navigation) ~= "table" or type(opts.navigation.preview) ~= "function" then
    return nil, "an injected navigation service is required"
  end
  if opts.orientation ~= nil and opts.orientation ~= "vertical" and opts.orientation ~= "horizontal" then
    return nil, "preview orientation must be vertical or horizontal"
  end
  local max_line_bytes = opts.max_line_bytes or 4096
  if type(max_line_bytes) ~= "number" or max_line_bytes < 1 or max_line_bytes % 1 ~= 0 then
    return nil, "preview max_line_bytes must be a positive integer"
  end
  local session_id = opts.session_id or "default"
  if type(session_id) ~= "string" or session_id == "" or #session_id > 128 then
    return nil, "preview session_id must be a non-empty string of at most 128 bytes"
  end
  return setmetatable({
    navigation = opts.navigation,
    orientation = opts.orientation,
    max_line_bytes = max_line_bytes,
    session_id = session_id,
    source_win = nil,
    win = nil,
    buf = nil,
    request = nil,
    generation = 0,
    last_preview = nil,
    disposed = false,
    enabled = opts.enabled ~= false,
    max_bytes = opts.max_bytes,
  }, Preview)
end

function Preview:_valid()
  return not self.disposed and self.enabled
end

function Preview:configure(opts)
  if self.disposed then return nil, "preview view is disposed" end
  if type(opts) ~= "table" or type(opts.enabled) ~= "boolean"
    or (opts.max_bytes ~= nil and (type(opts.max_bytes) ~= "number" or opts.max_bytes < 1 or opts.max_bytes % 1 ~= 0)) then
    return nil, "preview settings require enabled and a positive max_bytes limit"
  end
  local changed = self.enabled ~= opts.enabled or self.max_bytes ~= opts.max_bytes
  if changed then self:close(); self.last_preview = nil end
  self.enabled, self.max_bytes = opts.enabled, opts.max_bytes
  return true, nil, changed
end

function Preview:_ensure_window()
  if self.win and vim.api.nvim_win_is_valid(self.win) and self.buf and vim.api.nvim_buf_is_valid(self.buf) then return true end
  local source = source_window()
  if not source then return nil, "no normal editor window is available for preview" end
  local columns = vim.o.columns
  local orientation = self.orientation or (columns >= 100 and "vertical" or "horizontal")
  if orientation == "vertical" then vim.api.nvim_set_current_win(source); vim.api.nvim_cmd({ cmd = "vsplit" }, {})
  else vim.api.nvim_set_current_win(source); vim.api.nvim_cmd({ cmd = "split" }, {}) end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local name_id = self.session_id:gsub("[^%w_.%-]", "_")
  vim.api.nvim_buf_set_name(buf, "workbench://preview/" .. name_id)
  vim.b[buf].workbench_preview = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_win_set_buf(win, buf)
  local window_config = { cursorline = true, number = false, relativenumber = false, wrap = false, foldenable = false }
  for name, value in pairs(window_config) do pcall(function() vim.wo[win][name] = value end) end
  if orientation == "vertical" then
    local width = math.min(52, math.max(24, math.floor(columns * 0.36)))
    pcall(vim.api.nvim_win_set_width, win, width)
  else
    local height = math.min(12, math.max(4, math.floor((vim.o.lines - 3) * 0.32)))
    pcall(vim.api.nvim_win_set_height, win, height)
  end
  self.source_win, self.win, self.buf = source, win, buf
  vim.api.nvim_set_current_win(source)
  return true
end

function Preview:show(result)
  if not self:_valid() then return nil, "preview view is disposed" end
  local focus_window = vim.api.nvim_get_current_win()
  local ok, err = self:_ensure_window()
  if not ok then return nil, err end
  local lines = render_lines(result, self.max_line_bytes)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  vim.bo[self.buf].modified = false
  self.last_preview = result
  if result.target_index and result.target_index >= 1 then
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.min(#lines, result.target_index + 1), 0 })
  end
  if vim.api.nvim_win_is_valid(focus_window) then pcall(vim.api.nvim_set_current_win, focus_window) end
  return true
end

function Preview:preview(location, session, callback)
  if not self:_valid() then return nil, "preview view is disposed" end
  local ok, err = self:_ensure_window()
  if not ok then return nil, err end
  self.generation = self.generation + 1
  local generation = self.generation
  self.session_id = type(session) == "table" and session.id or (type(session) == "string" and session or self.session_id)
  if self.request and self.request.cancel then self.request:cancel() end
  local resource = type(location) == "table" and location.resource or nil
  local range = type(location) == "table" and location.range or nil
  self:show({
    status = "loading",
    path = resource and (resource.path or resource.display_path) or "",
    target_line = type(range) == "table" and range.start.line or 0,
  })
  local request, request_err = self.navigation:preview(location, self.session_id, function(result)
    if not self:_valid() or generation ~= self.generation then return end
    self.request = nil
    local shown, show_err = self:show(result)
    if callback then callback(shown and result or { code = "preview_view_error", message = tostring(show_err) }) end
  end, self.max_bytes and { max_output_bytes = self.max_bytes } or nil)
  if not request then self:show(request_err); return nil, request_err end
  self.request = request
  return request
end

function Preview:close()
  if self.disposed then return false end
  self.generation = self.generation + 1
  if self.request and self.request.cancel then self.request:cancel() end
  self.request = nil
  if self.navigation.cancel_preview then self.navigation:cancel_preview(self.session_id) end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    if vim.api.nvim_get_current_win() == self.win and self.source_win and vim.api.nvim_win_is_valid(self.source_win) then
      vim.api.nvim_set_current_win(self.source_win)
    end
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) and not vim.api.nvim_buf_is_loaded(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.win, self.buf, self.source_win = nil, nil, nil
  return true
end

function Preview:status()
  local win_valid = self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
  local buf_valid = self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
  return { disposed = self.disposed, open = win_valid and buf_valid, win = win_valid and self.win or nil, buf = buf_valid and self.buf or nil, pending = self.request ~= nil }
end

function Preview:dispose()
  if self.disposed then return false end
  self:close()
  self.disposed = true
  return true
end

M.render_lines = render_lines

return M
