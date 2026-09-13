local M = {}

local DEFAULT_LIMIT = 4096

local function normalize(items, tree)
  if type(items) ~= "table" then return nil, "projection items must be an array" end
  local count, maximum = 0, 0
  for key in pairs(items) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return nil, "projection items must be a dense array" end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then return nil, "projection items must be a dense array" end
  local by_id = {}
  for index, item in ipairs(items) do
    if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
      return nil, "projection item " .. index .. " must have a stable non-empty id"
    end
    if by_id[item.id] then return nil, "duplicate projection id: " .. item.id end
    if type(item.label) ~= "string" then return nil, "projection item " .. item.id .. " must have a label" end
    if item.parent_id ~= nil and type(item.parent_id) ~= "string" then
      return nil, "projection parent_id must be a string"
    end
    by_id[item.id] = item
  end

  local children
  if tree then
    children = {}
    for _, node in ipairs(items) do
      if node.parent_id and by_id[node.parent_id] then
        local siblings = children[node.parent_id]
        if not siblings then siblings = {}; children[node.parent_id] = siblings end
        siblings[#siblings + 1] = node
      end
    end

    -- A malformed parent cycle must not make a tree disappear silently.
    local state, path, path_length = {}, {}, 0
    for _, node in ipairs(items) do
      local current = node
      while current do
        local id = current.id
        if state[id] == 2 then break end
        if state[id] == 1 then return nil, "projection contains a parent cycle at " .. id end
        state[id] = 1
        path_length = path_length + 1
        path[path_length] = id
        current = current.parent_id and by_id[current.parent_id] or nil
      end
      for index = path_length, 1, -1 do state[path[index]] = 2; path[index] = nil end
      path_length = 0
    end
  end
  return items, by_id, children
end

local function row_for(node, depth, child_count)
  return {
    id = node.id,
    label = node.label,
    detail = type(node.detail) == "string" and node.detail or nil,
    kind = type(node.kind) == "string" and node.kind or "item",
    parent_id = node.parent_id,
    depth = depth,
    has_children = child_count > 0 or node.expandable == true,
    selectable = node.selectable ~= false,
    payload = node.payload,
  }
end

function M.list(items, limit)
  local nodes, err = normalize(items, false)
  if not nodes then return nil, err end
  limit = type(limit) == "number" and math.max(1, math.floor(limit)) or DEFAULT_LIMIT
  local rows = {}
  local count = math.min(#nodes, limit)
  for index = 1, count do rows[index] = row_for(nodes[index], 0, 0) end
  return rows, { truncated = #nodes > count, total = #nodes }
end

function M.tree(items, expanded, limit)
  local nodes, by_id, children = normalize(items, true)
  if not nodes then return nil, by_id end
  expanded = type(expanded) == "table" and expanded or {}
  limit = type(limit) == "number" and math.max(1, math.floor(limit)) or DEFAULT_LIMIT

  local roots = {}
  for _, node in ipairs(nodes) do
    if not node.parent_id or not by_id[node.parent_id] then roots[#roots + 1] = node end
  end

  local rows, stack = {}, {}
  for index = #roots, 1, -1 do stack[#stack + 1] = { node = roots[index], depth = 0 } end
  while #stack > 0 and #rows < limit do
    local current = stack[#stack]
    stack[#stack] = nil
    local descendants = children[current.node.id] or {}
    rows[#rows + 1] = row_for(current.node, current.depth, #descendants)
    local is_expanded = expanded[current.node.id]
    if #descendants > 0 and is_expanded ~= false then
      for index = #descendants, 1, -1 do
        stack[#stack + 1] = { node = descendants[index], depth = current.depth + 1 }
      end
    end
  end
  return rows, { truncated = #stack > 0, total = #nodes }
end

function M.reconcile_selection(rows, selected_id, previous_rows)
  if type(rows) ~= "table" or #rows == 0 then return nil end
  local new_index, new_by_id = {}, {}
  for index, row in ipairs(rows) do new_index[row.id] = index; new_by_id[row.id] = row end
  if selected_id and new_index[selected_id] then return selected_id end

  local previous_index, old_by_id = {}, {}
  for index, row in ipairs(previous_rows or {}) do previous_index[row.id] = index; old_by_id[row.id] = row end
  local old = selected_id and old_by_id[selected_id]
  if old then
    local peers = {}
    for index, row in ipairs(previous_rows) do
      if row.parent_id == old.parent_id and new_by_id[row.id] then peers[#peers + 1] = { id = row.id, old_index = index } end
    end
    table.sort(peers, function(left, right) return left.old_index < right.old_index end)
    local old_position = previous_index[selected_id]
    for _, peer in ipairs(peers) do if peer.old_index > old_position then return peer.id end end
    for index = #peers, 1, -1 do if peers[index].old_index < old_position then return peers[index].id end end
    local parent = old.parent_id
    while parent do
      if new_index[parent] then return parent end
      local previous_parent = old_by_id[parent]
      parent = previous_parent and previous_parent.parent_id or nil
    end
  end

  for _, row in ipairs(rows) do if row.selectable then return row.id end end
  return rows[1].id
end

return M
