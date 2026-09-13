local Projection = require("workbench.ui.projection")

local M = {}
local View = {}
View.__index = View

local next_buffer_id = 0
local highlight_namespace
local MAX_PROJECTED_ITEMS = 20000
local HIGHLIGHTS = {
  WorkbenchNormal = "Normal",
  WorkbenchMuted = "Comment",
  WorkbenchBorder = "WinSeparator",
  WorkbenchDirectory = "Directory",
  WorkbenchMatch = "Search",
  WorkbenchWarning = "DiagnosticWarn",
  WorkbenchInfo = "DiagnosticInfo",
  WorkbenchGitAdded = "DiffAdd",
  WorkbenchGitModified = "DiffChange",
  WorkbenchGitDeleted = "DiffDelete",
  WorkbenchDisabled = "Comment",
  WorkbenchLoading = "MoreMsg",
  WorkbenchTitle = "Title",
  WorkbenchItem = "Normal",
  WorkbenchSelection = "CursorLine",
  WorkbenchEnclosingSymbol = "Underlined",
  WorkbenchHelp = "Comment",
  WorkbenchError = "ErrorMsg",
  WorkbenchDetail = "NonText",
}

local function set_highlights()
  for name, target in pairs(HIGHLIGHTS) do
    pcall(vim.api.nvim_set_hl, 0, name, { link = target, default = true })
  end
end

local function display_width(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, text)
  return ok and width or #text
end

local function truncate_cells(value, width)
  width = math.max(0, width)
  local text = vim.fn.strtrans(value)
  if display_width(text) <= width then return text end
  if width == 0 then return "" end
  local suffix = width == 1 and "…" or "…"
  local budget = math.max(0, width - display_width(suffix))
  local count = vim.fn.strchars(text)
  local low, high = 0, count
  while low < high do
    local middle = math.floor((low + high + 1) / 2)
    local prefix = vim.fn.strcharpart(text, 0, middle, true)
    if display_width(prefix) <= budget then low = middle else high = middle - 1 end
  end
  return vim.fn.strcharpart(text, 0, low, true) .. suffix
end

local function status_lines(model)
  if model.status == "loading" or model.status == "running" then return { "Loading…" }, "WorkbenchLoading" end
  if model.status == "error" then
    local message = type(model.error) == "table" and model.error.message or model.error
    return { "Error: " .. tostring(message or "operation failed") }, "WorkbenchError"
  end
  if model.status == "empty" or model.status == "ready" then return { "No items" }, "WorkbenchMuted" end
  if model.status == "idle" then return { "Not started" }, "WorkbenchMuted" end
  return { "Unavailable: " .. tostring(model.reason or "unsupported state") }, "WorkbenchError"
end

local function row_highlight(row)
  if row.selectable == false then return "WorkbenchDisabled" end
  if row.kind == "directory" then return "WorkbenchDirectory" end
  if row.kind == "diagnostic" then
    local severity = row.payload and row.payload.severity
    if severity == "error" then return "WorkbenchError" end
    if severity == "warning" then return "WorkbenchWarning" end
    if severity == "information" or severity == "hint" then return "WorkbenchInfo" end
  elseif row.kind == "git_status" then
    local record = row.payload and row.payload.record
    if record and record.untracked then return "WorkbenchGitAdded" end
    if record and type(record.xy) == "string" and record.xy:find("D", 1, true) then return "WorkbenchGitDeleted" end
    return "WorkbenchGitModified"
  elseif row.kind == "match" or row.kind == "search_match" then
    return "WorkbenchMatch"
  elseif row.kind == "notice" then
    return "WorkbenchInfo"
  end
  return "WorkbenchNormal"
end

local function valid_model(model)
  if type(model) ~= "table" then return nil, "view model must be a table" end
  if model.status ~= nil and type(model.status) ~= "string" then return nil, "view status must be a string" end
  if model.items ~= nil and type(model.items) ~= "table" then return nil, "view items must be an array" end
  if model.header ~= nil and type(model.header) ~= "table" then return nil, "view header must be an array of strings" end
  for index, line in ipairs(model.header or {}) do
    if type(line) ~= "string" then return nil, "view header line " .. index .. " must be a string" end
  end
  return true
end

local function is_ready(model)
  return model.status == nil or model.status == "ready"
end

local function index_rows(rows)
  local index = {}
  for position, row in ipairs(rows) do index[row.id] = position end
  return index
end

function M.new(opts)
  opts = opts or {}
  if type(opts.scope) ~= "table" or type(opts.scope.defer) ~= "function" then
    return nil, { code = "invalid_scope", message = "view requires an owned disposable scope" }
  end
  if type(opts.id) ~= "string" or opts.id == "" then
    return nil, { code = "invalid_view", message = "view requires a stable id" }
  end
  local okay, err = valid_model(opts.model or {})
  if not okay then return nil, { code = "invalid_view", message = err } end

  next_buffer_id = next_buffer_id + 1
  local buffer = vim.api.nvim_create_buf(false, true)
  local view = setmetatable({
    id = opts.id,
    title = type(opts.title) == "string" and opts.title or opts.id,
    kind = opts.kind == "list" and "list" or "tree",
    scope = opts.scope,
    buffer = buffer,
    window = nil,
    placement = opts.placement == "results" and "results" or "sidebar",
    on_select = opts.on_select,
    on_toggle = opts.on_toggle,
    on_close = opts.on_close,
    keymaps = opts.keymaps or {},
    help_lines = opts.help_lines or {
      "j/k or arrows: move selection",
      "Enter: activate selected item",
      "Space/l: expand or collapse a branch",
      "q: close this view; ?: hide help",
    },
    selected_id = opts.selected_id,
    expanded = vim.deepcopy(opts.expanded or {}),
    model = vim.deepcopy(opts.model or { status = "ready", items = {} }),
    rows = {},
    row_index = {},
    projection_info = { truncated = false, total = 0 },
    visible_rows = {},
    visible_row_lines = {},
    row_by_line = {},
    scroll_offset = type(opts.scroll_offset) == "number" and opts.scroll_offset >= 0
      and opts.scroll_offset < math.huge and math.floor(opts.scroll_offset) or 0,
    help_visible = false,
    closed = false,
    render_error = nil,
    mode = nil,
    render_generation = 0,
    render_ticket = nil,
  }, View)

  vim.api.nvim_buf_set_name(buffer, string.format("workbench://view/%s/%d", opts.id:gsub("[^%w_.-]", "_"), next_buffer_id))
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].buflisted = false
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = "workbench"
  local _, buffer_error = opts.scope:defer(function()
    if vim.api.nvim_buf_is_valid(buffer) then pcall(vim.api.nvim_buf_delete, buffer, { force = true }) end
  end, "view-buffer:" .. opts.id, "buffer")
  if buffer_error then
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    return nil, { code = buffer_error.code or "scope_disposed", message = buffer_error.message }
  end

  view:_install_interactions()
  set_highlights()
  view:update(opts.model or { status = "ready", items = {} })
  return view
end

function View:_install_interactions()
  local view, buffer, scope = self, self.buffer, self.scope
  local mappings = {
    q = function() view:close() end,
    j = function() view:move(1) end,
    ["<Down>"] = function() view:move(1) end,
    k = function() view:move(-1) end,
    ["<Up>"] = function() view:move(-1) end,
    ["<CR>"] = function() view:activate() end,
    ["<Space>"] = function() view:toggle_expanded() end,
    l = function() view:toggle_expanded() end,
    ["<Right>"] = function() view:toggle_expanded() end,
    h = function() view:collapse_or_parent() end,
    ["<Left>"] = function() view:collapse_or_parent() end,
    ["?"] = function() view:toggle_help() end,
  }
  for key, mapping in pairs(self.keymaps) do
    local custom_mapping = mapping
    if type(custom_mapping) == "function" then mappings[key] = function() custom_mapping(view) end
    elseif type(custom_mapping) == "table" and type(custom_mapping.run) == "function" then
      mappings[key] = function() custom_mapping.run(view) end
    end
  end
  for key, callback in pairs(mappings) do
    local custom = self.keymaps[key]
    local desc = type(custom) == "table" and custom.desc or ("Workbench " .. key)
    vim.keymap.set("n", key, callback, { buffer = buffer, silent = true, nowait = true, desc = desc })
    scope:defer(function()
      if vim.api.nvim_buf_is_valid(buffer) then pcall(vim.keymap.del, "n", key, { buffer = buffer }) end
    end, "view-mapping:" .. self.id .. ":" .. key, "mapping")
  end

  local group = vim.api.nvim_create_augroup("WorkbenchView" .. tostring(buffer), { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buffer,
    callback = function() view:_sync_selection() end,
  })
  scope:defer(function() pcall(vim.api.nvim_del_augroup_by_id, group) end, "view-cursor-autocmd:" .. self.id, "autocmd")
end

function View:_format_row(row, width)
  local indent = string.rep("  ", math.min(row.depth or 0, 24))
  local marker = row.has_children and (self.expanded[row.id] == false and "> " or "v ") or "  "
  local text = indent .. marker .. row.label
  if row.detail and width > 16 then text = text .. "  " .. row.detail end
  return truncate_cells(text, width)
end

function View:_content_width()
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    local ok, width = pcall(vim.api.nvim_win_get_width, self.window)
    if ok then return math.max(8, width - 2) end
  end
  return math.max(8, vim.o.columns - 4)
end

function View:_project()
  local rows, info
  if self.kind == "list" then
    rows, info = Projection.list(self.model.items or {}, MAX_PROJECTED_ITEMS)
  else
    rows, info = Projection.tree(self.model.items or {}, self.expanded, MAX_PROJECTED_ITEMS)
  end
  if not rows then return nil, info end
  return rows, info
end

function View:_ensure_selection_visible()
  if #self.rows == 0 then self.scroll_offset = 0; return end
  local selected_index = self.row_index[self.selected_id]
  if not selected_index then self.scroll_offset = 0; return end
  local height = self.window and vim.api.nvim_win_is_valid(self.window) and vim.api.nvim_win_get_height(self.window) or vim.o.lines - 2
  local help_rows = self.help_visible and #self.help_lines or 0
  local available = math.max(1, height - #(self.model.header or {}) - help_rows - 2)
  local first = math.max(1, math.min(#self.rows, self.scroll_offset + 1))
  local before = first > 1
  local slots = available - (before and 1 or 0)
  local after = first + slots - 1 < #self.rows
  if after then slots = slots - 1 end
  slots = math.max(1, slots)
  local last = math.min(#self.rows, first + slots - 1)
  if selected_index < first or selected_index > last then
    self.scroll_offset = selected_index - 1
  end
  self.scroll_offset = math.max(0, math.min(self.scroll_offset, #self.rows - 1))
end

function View:update(model)
  if self.closed then return nil, { code = "view_closed", message = "view is closed" } end
  local okay, validation_error = valid_model(model)
  if not okay then return nil, { code = "invalid_model", message = validation_error } end
  self.render_generation = self.render_generation + 1
  if self.render_ticket then self.render_ticket:cancel(); self.render_ticket = nil end
  local previous = self.rows
  self.model = vim.deepcopy(model)
  if type(model.title) == "string" then self.title = model.title end
  if #previous > 0 and #(model.items or {}) == 0 and model.status ~= "ready" and model.status ~= "empty" then
    self.render_error = nil
    return self:render()
  end
  local rows, projection_info = self:_project()
  if not rows then
    self.render_error = projection_info
    self.rows = {}
    self.row_index = {}
    self.projection_info = { truncated = false, total = 0 }
  else
    self.render_error = nil
    self.rows = rows
    self.row_index = index_rows(rows)
    self.projection_info = projection_info
    self.selected_id = Projection.reconcile_selection(rows, self.selected_id, previous)
    self:_ensure_selection_visible()
  end
  return self:render()
end

function View:render_later(model, scheduler)
  if self.closed then return nil, { code = "view_closed", message = "view is closed" } end
  local okay, validation_error = valid_model(model)
  if not okay then return nil, { code = "invalid_model", message = validation_error } end
  if self.render_ticket then self.render_ticket:cancel() end
  self.render_generation = self.render_generation + 1
  local generation = self.render_generation
  local snapshot = vim.deepcopy(model)
  local view = self
  local ticket, err = self.scope:schedule(function()
    if view.closed or not view.scope.alive or generation ~= view.render_generation then return end
    view.render_ticket = nil
    view:update(snapshot)
  end, scheduler)
  if not ticket then
    self.render_ticket = nil
    return nil, err
  end
  self.render_ticket = ticket
  return ticket
end

function View:render()
  if self.closed or not vim.api.nvim_buf_is_valid(self.buffer) then return nil, { code = "view_closed", message = "view is closed" } end
  local width = self:_content_width()
  local content = {}
  local highlights = {}
  local row_by_line = {}
  local help = self.help_visible and self.help_lines or nil
  local selected_line

  content[#content + 1] = truncate_cells(" " .. self.title, width)
  highlights[1] = "WorkbenchTitle"
  for _, line in ipairs(self.model.header or {}) do
    content[#content + 1] = truncate_cells(" " .. line, width)
    highlights[#content] = "WorkbenchDetail"
  end
  if help then
    for _, line in ipairs(help) do
      content[#content + 1] = truncate_cells(" " .. line, width)
      highlights[#content] = "WorkbenchHelp"
    end
  end

  local available = math.max(1, (self.window and vim.api.nvim_win_is_valid(self.window) and vim.api.nvim_win_get_height(self.window) or vim.o.lines - 2) - #content - 1)
  local status = self.render_error and "error" or (self.model.status or "ready")
  self.visible_rows = {}
  self.visible_row_lines = {}
  if #self.rows == 0 or status ~= "ready" then
    local state_rows, group = status_lines({ status = status, error = self.render_error or self.model.error, reason = self.model.reason })
    content[#content + 1] = truncate_cells(" " .. state_rows[1], width)
    highlights[#content] = group
  else
    local first = math.max(1, math.min(#self.rows, self.scroll_offset + 1))
    local before = first > 1
    local item_slots = available - (before and 1 or 0)
    local after = first + item_slots - 1 < #self.rows
    if after then item_slots = item_slots - 1 end
    item_slots = math.max(1, item_slots)
    if before then
      local parent_index = self.rows[first].parent_id and self.row_index[self.rows[first].parent_id]
      local parent = parent_index and parent_index < first and self.rows[parent_index]
      content[#content + 1] = truncate_cells(" … " .. (parent and parent.label or "previous items"), width)
      highlights[#content] = "WorkbenchDetail"
    end
    for index = first, math.min(#self.rows, first + item_slots - 1) do
      local row = self.rows[index]
      self.visible_rows[#self.visible_rows + 1] = row
      content[#content + 1] = self:_format_row(row, width)
      self.visible_row_lines[row.id] = #content
      highlights[#content] = row.id == self.model.active_id and "WorkbenchEnclosingSymbol" or row_highlight(row)
      if row.id == self.selected_id then highlights[#content] = "WorkbenchSelection" end
      if row.selectable ~= false then row_by_line[#content] = row.id end
      if row.id == self.selected_id then selected_line = #content end
    end
    if after then
      local more = self.projection_info.truncated and " … projection capped at 20k rows" or " … more items"
      content[#content + 1] = truncate_cells(more, width)
      highlights[#content] = "WorkbenchDetail"
    end
  end

  local hint = self.help_visible and " ? hides help " or " j/k move  Enter select  ? help "
  content[#content + 1] = truncate_cells(hint, width)
  highlights[#content] = "WorkbenchHelp"
  self.row_by_line = row_by_line
  self.visible_selection_line = selected_line

  local was_modifiable = vim.bo[self.buffer].modifiable
  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, content)
  if not highlight_namespace then highlight_namespace = vim.api.nvim_create_namespace("workbench.ui.view") end
  vim.api.nvim_buf_clear_namespace(self.buffer, highlight_namespace, 0, -1)
  for line, group in pairs(highlights) do
    vim.api.nvim_buf_add_highlight(self.buffer, highlight_namespace, group, line - 1, 0, -1)
  end
  vim.bo[self.buffer].modifiable = was_modifiable
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    vim.wo[self.window].cursorline = true
    vim.wo[self.window].number = false
    vim.wo[self.window].relativenumber = false
    vim.wo[self.window].signcolumn = "no"
    vim.wo[self.window].wrap = false
    vim.wo[self.window].winhl = "Normal:WorkbenchNormal,CursorLine:WorkbenchSelection,EndOfBuffer:WorkbenchNormal,FloatBorder:WorkbenchBorder"
    if selected_line then pcall(vim.api.nvim_win_set_cursor, self.window, { selected_line, 0 }) end
  end
  return true
end

function View:update_dynamic(active_id, header)
  if self.closed then return nil, { code = "view_closed", message = "view is closed" } end
  if type(header) ~= "table" then return nil, { code = "invalid_model", message = "dynamic header must be an array" } end
  for index, line in ipairs(header) do
    if type(line) ~= "string" then return nil, { code = "invalid_model", message = "dynamic header line " .. index .. " must be a string" } end
  end
  self.render_generation = self.render_generation + 1
  if self.render_ticket then self.render_ticket:cancel(); self.render_ticket = nil end
  self.model.active_id = active_id
  self.model.header = vim.deepcopy(header)
  return self:render()
end

function View:_sync_selection()
  if self.closed or not self.scope.alive or not self.window or not vim.api.nvim_win_is_valid(self.window) then return end
  if vim.api.nvim_get_current_win() ~= self.window then return end
  local okay, cursor = pcall(vim.api.nvim_win_get_cursor, self.window)
  if not okay then return end
  local id = self.row_by_line[cursor[1]]
  if not id or id == self.selected_id then return end
  self.selected_id = id
  if self.on_select then
    local row
    for _, candidate in ipairs(self.visible_rows) do if candidate.id == id then row = candidate; break end end
    local ok, err = pcall(self.on_select, id, row)
    if not ok then self.last_error = tostring(err) end
  end
end

function View:move(delta)
  if self.closed or not is_ready(self.model) or self.render_error or not self.window or not vim.api.nvim_win_is_valid(self.window) then return false end
  if #self.rows == 0 then return false end
  local index = self.row_index[self.selected_id] or 0
  if index == 0 then index = delta < 0 and (#self.rows + 1) or 0 end
  local next_index = math.max(1, math.min(#self.rows, index + (delta < 0 and -1 or 1)))
  if next_index == index then return false end
  local candidate = self.rows[next_index]
  local step = delta < 0 and -1 or 1
  while candidate and candidate.selectable == false do
    next_index = next_index + step
    if next_index < 1 or next_index > #self.rows then return false end
    candidate = self.rows[next_index]
  end
  if not candidate then return false end
  self.selected_id = candidate.id
  self:_ensure_selection_visible()
  self:render()
  local target
  for line, id in pairs(self.row_by_line) do if id == self.selected_id then target = line; break end end
  if not target then return false end
  vim.api.nvim_win_set_cursor(self.window, { target, 0 })
  if self.on_select then
    local ok, err = pcall(self.on_select, candidate.id, candidate)
    if not ok then self.last_error = tostring(err) end
  end
  return true
end

function View:activate()
  if self.closed or not is_ready(self.model) or self.render_error or not self.window or not vim.api.nvim_win_is_valid(self.window) then return nil end
  self:_sync_selection()
  local id = self.selected_id
  if not id then return nil end
  local row
  for _, candidate in ipairs(self.visible_rows) do if candidate.id == id then row = candidate; break end end
  if not row then return nil end
  if row.has_children then return self:toggle_expanded(id) end
  if self.on_select then
    local ok, result = pcall(self.on_select, id, row, true)
    if not ok then self.last_error = tostring(result); return nil, self.last_error end
    return result
  end
  return id
end

function View:toggle_expanded(id)
  if self.closed or not is_ready(self.model) or self.render_error or self.kind ~= "tree" then return false end
  id = id or self.selected_id
  if not id then return false end
  local selected
  for _, row in ipairs(self.rows) do if row.id == id then selected = row; break end end
  if not selected or not selected.has_children then return false end
  local opening = self.expanded[id] == false
  self.expanded[id] = opening and true or false
  local rows, err = self:_project()
  if not rows then self.render_error = err; return nil, err end
  local previous = self.rows
  self.rows = rows
  self.row_index = index_rows(rows)
  self.projection_info = err
  self.selected_id = Projection.reconcile_selection(rows, self.selected_id, previous)
  self:_ensure_selection_visible()
  local rendered = self:render()
  if rendered and self.on_toggle then
    local ok, callback_error = pcall(self.on_toggle, id, opening, selected)
    if not ok then self.last_error = tostring(callback_error) end
  end
  return rendered
end

function View:collapse_or_parent()
  if self.closed or not is_ready(self.model) then return false end
  local selected = self.selected_id and self.row_index[self.selected_id] and self.rows[self.row_index[self.selected_id]]
  if selected and selected.has_children and self.expanded[selected.id] ~= false then
    return self:toggle_expanded(selected.id)
  end
  local parent = selected and selected.parent_id
  if parent and self.row_index[parent] then
    local index = self.row_index[parent]
    self.selected_id = parent
    self:_ensure_selection_visible()
    self:render()
    local target
    for line, id in pairs(self.row_by_line) do if id == parent then target = line; break end end
    if target then vim.api.nvim_win_set_cursor(self.window, { target, 0 }) end
    if self.on_select then pcall(self.on_select, parent, self.rows[index]) end
    return true
  end
  return false
end

function View:toggle_help()
  if self.closed then return false end
  self.help_visible = not self.help_visible
  self:_ensure_selection_visible()
  return self:render()
end

function View:set_window(window, mode)
  self.window = window
  self.mode = mode
  self:_ensure_selection_visible()
  self:render()
end

function View:close()
  if self.closed then return false end
  if self.on_close then return self.on_close(self) end
  self.closed = true
  return self.scope:dispose()
end

return M
