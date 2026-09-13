local M = {}
local search_cache = setmetatable({}, { __mode = "k" })

local function position_number(line, column)
  return line * 1000000000 + column
end

local function position_before(line, column, position)
  return line < position.line or (line == position.line and column < position.character)
end

local function position_distance(start, finish)
  local line_delta = finish.line - start.line
  local column_delta = finish.character - start.character
  if line_delta == 0 then return math.max(0, column_delta) end
  return line_delta * 1000000000 + finish.character - start.character
end

local function scan_enclosing(items, line, column)
  if type(items) ~= "table" or type(line) ~= "number" or type(column) ~= "number" then return nil end
  local best_id, best_distance
  for _, item in ipairs(items) do
    local range = item.payload and item.payload.source_range_bytes
    if range and range.start and range.finish
      and not position_before(line, column, range.start)
      and position_before(line, column, range.finish) then
      local distance = position_distance(range.start, range.finish)
      if not best_distance or distance < best_distance then
        best_id, best_distance = item.id, distance
      end
    end
  end
  return best_id
end

local function build_tree(entries, first, last)
  if first > last then return nil end
  local middle = math.floor((first + last) / 2)
  local entry = entries[middle]
  local node = {
    entry = entry,
    left = build_tree(entries, first, middle - 1),
    right = build_tree(entries, middle + 1, last),
    max_finish = entry.finish,
  }
  if node.left then node.max_finish = math.max(node.max_finish, node.left.max_finish) end
  if node.right then node.max_finish = math.max(node.max_finish, node.right.max_finish) end
  return node
end

function M.build_enclosing_index(items)
  if type(items) ~= "table" then return nil, "outline items must be an array" end
  local entries, by_id = {}, {}
  for order, item in ipairs(items) do
    by_id[item.id] = item
    local range = item.payload and item.payload.source_range_bytes
    if range and range.start and range.finish then
      local start = position_number(range.start.line, range.start.character)
      local finish = position_number(range.finish.line, range.finish.character)
      if finish > start then entries[#entries + 1] = { id = item.id, start = start, finish = finish, order = order } end
    end
  end
  table.sort(entries, function(left, right)
    if left.start ~= right.start then return left.start < right.start end
    if left.finish ~= right.finish then return left.finish > right.finish end
    return left.order > right.order
  end)

  local stack, laminar = {}, true
  for _, entry in ipairs(entries) do
    while #stack > 0 and stack[#stack].finish <= entry.start do stack[#stack] = nil end
    if #stack > 0 and entry.finish > stack[#stack].finish then laminar = false; break end
    stack[#stack + 1] = entry
  end
  return { indexed = true, laminar = laminar, root = laminar and build_tree(entries, 1, #entries) or nil, count = #entries, by_id = by_id }
end

local function indexed_enclosing(index, point)
  local function find(node)
    if not node or node.max_finish <= point then return nil end
    local entry = node.entry
    if entry.start > point then return find(node.left) end
    local inner = find(node.right)
    if inner then return inner end
    if entry.finish > point then return entry end
    return find(node.left)
  end
  local entry = find(index.root)
  return entry and entry.id or nil
end

function M.enclosing(items, line, column, index)
  if type(index) == "table" and index.indexed and index.laminar then
    if type(line) ~= "number" or type(column) ~= "number" then return nil end
    return indexed_enclosing(index, position_number(line, column))
  end
  return scan_enclosing(items, line, column)
end

function M.breadcrumbs(items, active_id, index)
  local by_id = type(index) == "table" and index.by_id or nil
  if not by_id then
    by_id = {}
    for _, item in ipairs(items or {}) do by_id[item.id] = item end
  end
  local chain, seen = {}, {}
  local item = active_id and by_id[active_id]
  while item and not seen[item.id] do
    seen[item.id] = true
    chain[#chain + 1] = item
    item = item.parent_id and by_id[item.parent_id] or nil
  end
  local result = {}
  for index = #chain, 1, -1 do result[#result + 1] = chain[index] end
  return result
end

local function search_text(item)
  local cached = search_cache[item]
  if not cached or cached.label ~= item.label or cached.detail ~= item.detail then
    local label = item.label or ""
    local detail = item.detail or ""
    cached = {
      label = item.label,
      detail = item.detail,
      lower_label = vim.fn.tolower(label),
      lower_search = vim.fn.tolower(label .. " " .. detail),
    }
    search_cache[item] = cached
  end
  return cached
end

local function source_before(left, left_index, right, right_index)
  local left_source = left.payload and left.payload.source_order or left_index
  local right_source = right.payload and right.payload.source_order or right_index
  if left_source ~= right_source then return left_source < right_source end
  local left_client = left.payload and left.payload.client_id or 0
  local right_client = right.payload and right.payload.client_id or 0
  if left_client ~= right_client then return left_client < right_client end
  return left.id < right.id
end

local function order_items(items, order)
  if order == "source" then
    local sorted = true
    for index = 2, #items do
      if source_before(items[index], index, items[index - 1], index - 1) then sorted = false; break end
    end
    if sorted then return items end
  end
  local ordered = {}
  for index, item in ipairs(items) do
    ordered[index] = { item = item, index = index, lower_label = search_text(item).lower_label }
  end
  table.sort(ordered, function(left, right)
    local a, b = left.item, right.item
    if order == "name" then
      local a_name, b_name = left.lower_label, right.lower_label
      if a_name ~= b_name then return a_name < b_name end
    end
    return source_before(a, left.index, b, right.index)
  end)
  for index, entry in ipairs(ordered) do ordered[index] = entry.item end
  return ordered
end

function M.header(opts)
  opts = opts or {}
  local header = {}
  if opts.breadcrumbs_enabled ~= false and type(opts.breadcrumbs) == "table" and #opts.breadcrumbs > 0 then
    local names = {}
    for _, item in ipairs(opts.breadcrumbs) do names[#names + 1] = item.label end
    header[#header + 1] = "Breadcrumbs: " .. table.concat(names, " › ")
  end
  if type(opts.partial_message) == "string" and opts.partial_message ~= "" then
    header[#header + 1] = "Partial results: " .. opts.partial_message
  end
  return header
end

function M.project(items, opts)
  opts = opts or {}
  if type(items) ~= "table" then return nil, "outline items must be an array" end
  local order = opts.order == "name" and "name" or "source"
  local filter = type(opts.filter) == "string" and vim.fn.tolower(opts.filter) or ""
  local ordered = order_items(items, order)
  local by_id, matches = {}, {}
  for _, item in ipairs(ordered) do
    by_id[item.id] = item
    if filter == "" or search_text(item).lower_search:find(filter, 1, true) then matches[item.id] = true end
  end

  if filter ~= "" then
    for id in pairs(matches) do
      local item, visited = by_id[id], {}
      while item and item.parent_id and not visited[item.parent_id] do
        visited[item.parent_id] = true
        matches[item.parent_id] = true
        item = by_id[item.parent_id]
      end
    end
  end

  local visible = {}
  for _, item in ipairs(ordered) do
    if filter == "" or matches[item.id] then visible[#visible + 1] = item end
  end

  local title = order == "name" and "Outline · name order" or "Outline · source order"
  if filter ~= "" then title = title .. " · filter: " .. opts.filter end
  return {
    status = opts.status or "ready",
    reason = opts.reason,
    error = opts.error,
    title = title,
    header = M.header(opts),
    active_id = opts.active_id,
    items = visible,
  }
end

return M
