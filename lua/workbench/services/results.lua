local M = {}
local Store = {}
Store.__index = Store
local Session = {}
Session.__index = Session

local function is_integer(value, minimum)
  return type(value) == "number" and value % 1 == 0 and value >= (minimum or 0)
end

local function dense_length(value)
  if type(value) ~= "table" then return nil end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if not is_integer(key, 1) then return nil end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then return nil end
  return maximum
end

local function clean_value(value, depth, budget)
  if depth > 8 then return nil, "value exceeds the maximum nesting depth" end
  local kind = type(value)
  if kind == "nil" or kind == "boolean" or kind == "number" then
    if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
      return nil, "non-finite numbers are not retained"
    end
    budget.bytes = budget.bytes + 8
    return value
  end
  if kind == "string" then
    budget.bytes = budget.bytes + #value
    if budget.bytes > budget.max_bytes then return nil, "result item exceeds the retained byte limit" end
    return value
  end
  if kind ~= "table" then return nil, "result data must contain only plain values" end
  if budget.seen[value] then return nil, "cyclic result data is not retained" end
  budget.seen[value] = true
  local result = {}
  for key, nested in pairs(value) do
    if type(key) ~= "string" and not is_integer(key, 1) then
      budget.seen[value] = nil
      return nil, "result data keys must be strings or positive integers"
    end
    if type(key) == "string" then budget.bytes = budget.bytes + #key end
    local copied, err = clean_value(nested, depth + 1, budget)
    if err then budget.seen[value] = nil; return nil, err end
    result[key] = copied
    if budget.bytes > budget.max_bytes then budget.seen[value] = nil; return nil, "result item exceeds the retained byte limit" end
  end
  budget.seen[value] = nil
  return result
end

local function copy_item(item, max_bytes)
  if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
    return nil, "each result item requires a non-empty stable string id"
  end
  if type(item.kind) ~= "string" or item.kind == "" or type(item.label) ~= "string" then
    return nil, "each result item requires a kind and label"
  end
  local budget = { bytes = 0, max_bytes = max_bytes, seen = {} }
  local result, err = clean_value(item, 1, budget)
  if not result then return nil, err end
  return result, budget.bytes
end

local function touch(list, id)
  for index = #list, 1, -1 do
    if list[index] == id then table.remove(list, index) end
  end
  list[#list + 1] = id
end

local function remove_id(list, id)
  for index = #list, 1, -1 do
    if list[index] == id then table.remove(list, index) end
  end
end

local function status_is_terminal(status)
  return status == "complete" or status == "partial" or status == "cancelled" or status == "error"
end

local function valid_status(status)
  return status == "idle" or status == "running" or status_is_terminal(status)
end

local function valid_completeness(value)
  return value == "complete" or value == "reported-only" or value == "truncated" or value == "unknown"
end

local function result_summary(set, changes)
  return {
    id = set.id,
    provider_id = set.provider_id,
    workspace_id = set.workspace_id,
    generation = set.generation,
    revision = set.revision,
    status = set.status,
    completeness = set.completeness,
    item_count = #set.order,
    bytes = set.bytes,
    error = set.error and vim.deepcopy(set.error) or nil,
    changes = changes and vim.deepcopy(changes) or nil,
  }
end

function M.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "result-store options must be a table" end
  local limits = {
    max_sets = opts.max_sets or 16,
    max_sessions = opts.max_sessions or 16,
    max_items = opts.max_items or 10000,
    max_bytes = opts.max_bytes or 8 * 1024 * 1024,
    max_total_bytes = opts.max_total_bytes or 32 * 1024 * 1024,
    max_item_bytes = opts.max_item_bytes or 256 * 1024,
    max_batch_items = opts.max_batch_items or (type(opts.max_items) == "number" and math.min(opts.max_items, 512) or 512),
    max_expanded_ids = opts.max_expanded_ids or 2048,
    max_expanded_bytes = opts.max_expanded_bytes or 64 * 1024,
  }
  for name, value in pairs(limits) do
    if not is_integer(value, 1) then return nil, name .. " must be a positive integer" end
  end
  return setmetatable({
    limits = limits,
    sets = {},
    set_order = {},
    sessions = {},
    session_order = {},
    next_session = 0,
    total_bytes = 0,
    disposed = false,
  }, Store)
end

function Store:_live()
  if self.disposed then return nil, "result store is disposed" end
  return true
end

function Store:_session_refs(result_id)
  for _, session_id in ipairs(self.session_order) do
    local session = self.sessions[session_id]
    if session and session.result_set_id == result_id then return true end
  end
  return false
end

function Store:_make_set_room(required_bytes)
  required_bytes = required_bytes or 0
  if required_bytes > self.limits.max_total_bytes then return nil, "result query exceeds the total result-store byte limit" end
  local reclaimable, unreferenced = 0, 0
  for _, result_id in ipairs(self.set_order) do
    if not self:_session_refs(result_id) then
      unreferenced = unreferenced + 1
      reclaimable = reclaimable + (self.sets[result_id] and self.sets[result_id].bytes or 0)
    end
  end
  local needed_sets = math.max(0, #self.set_order - self.limits.max_sets + 1)
  if unreferenced < needed_sets then return nil, "result history is full; close an old view session before starting another search" end
  if self.total_bytes + required_bytes - reclaimable > self.limits.max_total_bytes then
    return nil, "result store is full; close/evict retained results before starting another search"
  end
  while #self.set_order >= self.limits.max_sets or self.total_bytes + required_bytes > self.limits.max_total_bytes do
    local evicted
    for _, result_id in ipairs(self.set_order) do
      if not self:_session_refs(result_id) then
        evicted = result_id
        break
      end
    end
    if not evicted then return nil, "result store cannot reclaim enough bounded history" end
    self.total_bytes = self.total_bytes - (self.sets[evicted] and self.sets[evicted].bytes or 0)
    self.sets[evicted] = nil
    remove_id(self.set_order, evicted)
  end
  return true
end

function Store:create(spec)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  spec = spec or {}
  if type(spec) ~= "table" then return nil, "result-set specification must be a table" end
  if type(spec.id) ~= "string" or spec.id == "" then return nil, "result set requires a stable id" end
  if self.sets[spec.id] then return nil, "result set id already exists" end
  for _, field in ipairs({ "provider_id", "workspace_id" }) do
    if type(spec[field]) ~= "string" or spec[field] == "" then return nil, "result set requires " .. field end
  end
  if not is_integer(spec.generation, 0) then return nil, "result set generation must be a non-negative integer" end
  if spec.max_items ~= nil and not is_integer(spec.max_items, 1) then return nil, "max_items must be a positive integer" end
  local status = spec.status or "running"
  local completeness = spec.completeness or "unknown"
  if not valid_status(status) or not valid_completeness(completeness) then return nil, "invalid initial result status or completeness" end
  if status_is_terminal(status) then return nil, "create result sets as idle/running and finish them through the lifecycle API" end
  local safe_query, query_bytes = nil, 0
  if spec.query ~= nil then
    local budget = { bytes = 0, max_bytes = math.min(64 * 1024, self.limits.max_bytes), seen = {} }
    local query_err
    safe_query, query_err = clean_value(spec.query, 1, budget)
    if not safe_query then return nil, "result query: " .. query_err end
    query_bytes = budget.bytes
  end
  if spec.items ~= nil then
    local count = dense_length(spec.items)
    if count == nil then return nil, "initial result items must be a dense array" end
    if count <= self.limits.max_batch_items then
      for index = 1, count do
        local item, size_or_error = copy_item(spec.items[index], self.limits.max_item_bytes)
        if not item then return nil, "initial item " .. index .. ": " .. size_or_error end
      end
    end
  end
  local room, room_err = self:_make_set_room(query_bytes)
  if not room then return nil, room_err end
  local set = {
    id = spec.id,
    provider_id = spec.provider_id,
    workspace_id = spec.workspace_id,
    generation = spec.generation,
    max_items = math.min(spec.max_items or self.limits.max_items, self.limits.max_items),
    revision = 0,
    status = status,
    completeness = completeness,
    items = {},
    item_bytes = {},
    positions = {},
    order = {},
    bytes = query_bytes,
    error = nil,
    query = safe_query,
    created_at = (vim.uv or vim.loop).hrtime(),
  }
  self.sets[set.id] = set
  self.set_order[#self.set_order + 1] = set.id
  self.total_bytes = self.total_bytes + query_bytes
  if spec.items ~= nil then
    local merged, merge_err = self:merge(set.id, spec.items)
    if not merged then self.sets[set.id] = nil; remove_id(self.set_order, set.id); return nil, merge_err end
  end
  return result_summary(self.sets[set.id])
end

function Store:get(result_id)
  local set = self.sets[result_id]
  if not set then return nil end
  touch(self.set_order, result_id)
  local result = {
    id = set.id,
    provider_id = set.provider_id,
    workspace_id = set.workspace_id,
    generation = set.generation,
    revision = set.revision,
    status = set.status,
    completeness = set.completeness,
    items = vim.deepcopy(set.items),
    order = vim.deepcopy(set.order),
    bytes = set.bytes,
    error = set.error and vim.deepcopy(set.error) or nil,
    query = set.query and vim.deepcopy(set.query) or nil,
  }
  return result
end

Store.snapshot = Store.get

function Store:summary(result_id)
  local set = self.sets[result_id]
  if not set then return nil end
  touch(self.set_order, result_id)
  return result_summary(set)
end

function Store:item(result_id, item_id)
  local set = self.sets[result_id]
  local item = set and set.items[item_id]
  if not item then return nil end
  touch(self.set_order, result_id)
  return vim.deepcopy(item)
end

function Store:page(result_id, offset, limit)
  local set = self.sets[result_id]
  if not set then return nil, "result set is unavailable" end
  if not is_integer(offset, 0) then return nil, "result page offset must be a non-negative integer" end
  if not is_integer(limit, 1) or limit > 1000 then return nil, "result page limit must be between 1 and 1000" end
  touch(self.set_order, result_id)
  local items = {}
  local first = offset + 1
  local last = math.min(#set.order, offset + limit)
  for index = first, last do
    local id = set.order[index]
    items[#items + 1] = vim.deepcopy(set.items[id])
  end
  local next_offset = last < #set.order and last or nil
  return {
    id = set.id,
    revision = set.revision,
    status = set.status,
    completeness = set.completeness,
    items = items,
    offset = offset,
    next_offset = next_offset,
    total = #set.order,
  }
end

function Store:merge(result_id, items)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  local set = self.sets[result_id]
  if not set then return nil, "result set is unavailable" end
  if status_is_terminal(set.status) then return nil, "terminal result sets cannot accept more batches" end
  local count = dense_length(items)
  if count == nil then return nil, "result batches must be dense arrays" end
  if count > self.limits.max_batch_items then
    set.status, set.completeness = "partial", "truncated"
    set.error = { code = "result_batch_limit", message = "provider batch exceeded the configured retained batch limit" }
    set.revision = set.revision + 1
    self:_reconcile_sessions(set)
    return result_summary(set)
  end
  local updates = {}
  for index = 1, count do
    local item, size_or_error = copy_item(items[index], self.limits.max_item_bytes)
    if not item then return nil, "item " .. index .. ": " .. size_or_error end
    updates[#updates + 1] = { item = item, bytes = size_or_error }
  end
  local changed, added_ids, updated_ids = false, {}, {}
  for _, update in ipairs(updates) do
    local item = update.item
    local previous = set.items[item.id]
    local old_bytes = previous and (set.item_bytes[item.id] or 0) or 0
    local next_bytes = set.bytes - old_bytes + update.bytes
    if not previous and #set.order >= set.max_items then
      set.status, set.completeness = "partial", "truncated"
      set.error = { code = "result_item_limit", message = "result history reached its retained item limit" }
      changed = true
      break
    elseif next_bytes > self.limits.max_bytes then
      set.status, set.completeness = "partial", "truncated"
      set.error = { code = "result_byte_limit", message = "result history reached its retained byte limit" }
      changed = true
      break
    elseif self.total_bytes - old_bytes + update.bytes > self.limits.max_total_bytes then
      set.status, set.completeness = "partial", "truncated"
      set.error = { code = "result_store_byte_limit", message = "result store reached its total retained byte limit" }
      changed = true
      break
    end
    if not previous then
      set.order[#set.order + 1] = item.id
      set.positions[item.id] = #set.order
      added_ids[#added_ids + 1] = item.id
    else
      updated_ids[#updated_ids + 1] = item.id
    end
    set.items[item.id] = item
    set.item_bytes[item.id] = update.bytes
    set.bytes = next_bytes
    self.total_bytes = self.total_bytes - old_bytes + update.bytes
    changed = true
  end
  if changed then
    set.revision = set.revision + 1
    self:_reconcile_sessions(set)
  end
  return result_summary(set, { added = added_ids, updated = updated_ids })
end

function Store:_reconcile_sessions(set)
  for _, session_id in ipairs(self.session_order) do
    local session = self.sessions[session_id]
    if session and session.result_set_id == set.id and session.selected_id and not set.items[session.selected_id] then
      local old_order = session.last_order or {}
      local selected_index = session.last_selected_index or 0
      local selected_parent = session.last_selected_parent
      local next_id, previous_id
      for index = selected_index + 1, #old_order do
        local id = old_order[index]
        if set.items[id] and (set.items[id].parent_id or nil) == selected_parent then next_id = id; break end
      end
      for index = selected_index - 1, 1, -1 do
        local id = old_order[index]
        if set.items[id] and (set.items[id].parent_id or nil) == selected_parent then previous_id = id; break end
      end
      if next_id then session.selected_id = next_id
      elseif previous_id then session.selected_id = previous_id
      elseif selected_parent and set.items[selected_parent] then session.selected_id = selected_parent
      else session.selected_id = set.order[1] end
      if session.preview_id and not set.items[session.preview_id] then session.preview_id = nil end
    end
    if session and session.result_set_id == set.id then
      session.last_order = nil
      local selected = session.selected_id and set.items[session.selected_id]
      session.last_selected_parent = selected and selected.parent_id or nil
      session.last_selected_index = session.selected_id and (set.positions[session.selected_id] or 0) or 0
    end
  end
end

function Store:remove_items(result_id, ids)
  local set = self.sets[result_id]
  if not set then return nil, "result set is unavailable" end
  if status_is_terminal(set.status) then return nil, "terminal result sets cannot be changed" end
  local count = dense_length(ids)
  if not count then return nil, "removed IDs must be a dense array" end
  local remove = {}
  for _, id in ipairs(ids) do
    if type(id) ~= "string" or id == "" then return nil, "removed result IDs must be non-empty strings" end
    remove[id] = true
  end
  local old_order = set.order
  for _, session_id in ipairs(self.session_order) do
    local session = self.sessions[session_id]
    if session and session.result_set_id == result_id and session.selected_id and remove[session.selected_id] then
      session.last_order = old_order
      local selected = set.items[session.selected_id]
      session.last_selected_parent = selected and selected.parent_id or nil
      session.last_selected_index = set.positions[session.selected_id] or 0
    end
  end
  local removed = {}
  if count > 0 then
    local next_order, next_positions = {}, {}
    for _, id in ipairs(old_order) do
      if remove[id] and set.items[id] then
        local item_bytes = set.item_bytes[id] or 0
        set.bytes = set.bytes - item_bytes
        self.total_bytes = self.total_bytes - item_bytes
        set.item_bytes[id], set.items[id], removed[id] = nil, nil, true
      else
        next_order[#next_order + 1] = id
        next_positions[id] = #next_order
      end
    end
    set.order, set.positions = next_order, next_positions
  end
  if next(removed) then
    for _, session_id in ipairs(self.session_order) do
      local session = self.sessions[session_id]
      if session and session.result_set_id == result_id then
        for id in pairs(removed) do
          if session.expanded[id] then
            session.expanded[id] = nil
            session.expanded_count = math.max(0, session.expanded_count - 1)
            session.expanded_bytes = math.max(0, session.expanded_bytes - #id)
          end
        end
      end
    end
    set.revision = set.revision + 1
    self:_reconcile_sessions(set)
  end
  local removed_ids = {}
  for _, id in ipairs(ids) do if removed[id] then removed_ids[#removed_ids + 1] = id end end
  return result_summary(set, { removed = removed_ids })
end

function Store:finish(result_id, status, completeness, err)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  local set = self.sets[result_id]
  if not set then return nil, "result set is unavailable" end
  if status_is_terminal(set.status) then
    if set.status == status and (completeness == nil or completeness == set.completeness) then return result_summary(set) end
    return nil, "terminal result status cannot be changed"
  end
  if not status_is_terminal(status) then return nil, "finish requires a terminal status" end
  if not valid_completeness(completeness or set.completeness) then return nil, "invalid result completeness" end
  if status == "complete" and completeness and completeness ~= "complete" then
    return nil, "complete results must declare complete completeness"
  end
  if status ~= "complete" and completeness == "complete" then
    return nil, "non-complete result status cannot declare complete completeness"
  end
  if status == "error" and type(err) ~= "table" then return nil, "error results require a structured error record" end
  local safe_error
  if err ~= nil then
    local safe, safe_err = clean_value(err, 1, { bytes = 0, max_bytes = 4096, seen = {} })
    if not safe then return nil, "invalid result error: " .. safe_err end
    safe_error = safe
  end
  set.status = status
  set.completeness = completeness or (status == "complete" and "complete" or set.completeness)
  if safe_error then set.error = safe_error end
  set.revision = set.revision + 1
  return result_summary(set)
end

function Store:_make_session_room()
  while #self.session_order >= self.limits.max_sessions do
    local evicted
    for _, id in ipairs(self.session_order) do
      local session = self.sessions[id]
      if session and not session.mounted then evicted = id; break end
    end
    if not evicted then return nil, "view session history is full; close an old view before opening another" end
    self.sessions[evicted] = nil
    remove_id(self.session_order, evicted)
  end
  return true
end

function Store:open_session(result_id, opts)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  local set = self.sets[result_id]
  if not set then return nil, "result set is unavailable" end
  opts = opts or {}
  if type(opts) ~= "table" then return nil, "view session options must be a table" end
  local id = opts.id or ("view-" .. (self.next_session + 1))
  if type(id) ~= "string" or id == "" or self.sessions[id] then return nil, "view session ID must be unique and non-empty" end
  if opts.selected_id ~= nil and (type(opts.selected_id) ~= "string" or not set.items[opts.selected_id]) then
    return nil, "initial selected result item is unavailable"
  end
  local safe_origin
  local room_err
  if opts.origin ~= nil then
    safe_origin, room_err = clean_value(opts.origin, 1, { bytes = 0, max_bytes = 4096, seen = {} })
    if not safe_origin then return nil, "view session origin: " .. room_err end
  end
  local room, room_err = self:_make_session_room()
  if not room then return nil, room_err end
  self.next_session = self.next_session + 1
  local session = setmetatable({
    store = self,
    id = id,
    result_set_id = result_id,
    selected_id = opts.selected_id or set.order[1],
    preview_id = nil,
    expanded = {},
    expanded_bytes = 0,
    expanded_count = 0,
    filter = "",
    scroll_anchor = nil,
    origin = safe_origin,
    mounted = true,
    last_order = nil,
    last_selected_index = 0,
    last_selected_parent = nil,
  }, Session)
  if session.selected_id and not set.items[session.selected_id] then session.selected_id = set.order[1] end
  self.sessions[id] = session
  self.session_order[#self.session_order + 1] = id
  local selected = session.selected_id and set.items[session.selected_id]
  session.last_selected_parent = selected and selected.parent_id or nil
  session.last_selected_index = session.selected_id and (set.positions[session.selected_id] or 0) or 0
  return session
end

function Store:resume(session_id)
  local live, live_err = self:_live()
  if not live then return nil, live_err end
  local session = self.sessions[session_id]
  if not session then return nil, "view session is unavailable" end
  if not self.sets[session.result_set_id] then return nil, "view session result history was evicted" end
  session.mounted = true
  touch(self.session_order, session_id)
  self:_reconcile_sessions(self.sets[session.result_set_id])
  return session
end

function Store:session_snapshot(session_id)
  local session = self.sessions[session_id]
  if not session then return nil end
  return {
    id = session.id,
    result_set_id = session.result_set_id,
    selected_id = session.selected_id,
    preview_id = session.preview_id,
    expanded = vim.deepcopy(session.expanded),
    filter = session.filter,
    scroll_anchor = session.scroll_anchor and vim.deepcopy(session.scroll_anchor) or nil,
    origin = session.origin and vim.deepcopy(session.origin) or nil,
    mounted = session.mounted,
  }
end

function Store:status()
  local result = { disposed = self.disposed, result_sets = #self.set_order, sessions = #self.session_order, items = 0, bytes = self.total_bytes }
  for _, set in pairs(self.sets) do result.items = result.items + #set.order end
  return result
end

function Store:dispose()
  if self.disposed then return false end
  self.disposed = true
  self.sets, self.set_order, self.sessions, self.session_order = {}, {}, {}, {}
  self.total_bytes = 0
  return true
end

function Session:_set()
  if self.store.disposed then return nil, "result store is disposed" end
  local set = self.store.sets[self.result_set_id]
  if not set then return nil, "view session result history was evicted" end
  return set
end

function Session:select(item_id)
  local set, err = self:_set()
  if not set then return nil, err end
  if item_id ~= nil and not set.items[item_id] then return nil, "selected result item is unavailable" end
  self.selected_id = item_id
  local selected = item_id and set.items[item_id]
  self.last_selected_parent = selected and selected.parent_id or nil
  self.last_selected_index = item_id and (set.positions[item_id] or 0) or 0
  self.last_order = nil
  return true
end

function Session:preview(item_id)
  local set, err = self:_set()
  if not set then return nil, err end
  if item_id ~= nil and (not set.items[item_id] or not set.items[item_id].location) then
    return nil, "preview requires a result item with a location"
  end
  self.preview_id = item_id
  return true
end

function Session:set_filter(filter)
  local live, err = self:_set()
  if not live then return nil, err end
  if type(filter) ~= "string" then return nil, "view filter must be a string" end
  if #filter > 4096 then return nil, "view filter exceeds the retained byte limit" end
  self.filter = filter
  return true
end

function Session:set_expanded(item_id, expanded)
  local live, err = self:_set()
  if not live then return nil, err end
  if type(item_id) ~= "string" or item_id == "" or type(expanded) ~= "boolean" then return nil, "expanded state requires an item ID and boolean" end
  if #item_id > 512 then return nil, "expanded item ID exceeds the retained byte limit" end
  if expanded and not self.expanded[item_id] then
    if self.expanded_count >= self.store.limits.max_expanded_ids or self.expanded_bytes + #item_id > self.store.limits.max_expanded_bytes then
      return nil, "expanded view state reached its retained count/byte limit"
    end
    self.expanded_count = self.expanded_count + 1
    self.expanded_bytes = self.expanded_bytes + #item_id
  elseif not expanded and self.expanded[item_id] then
    self.expanded_count = math.max(0, self.expanded_count - 1)
    self.expanded_bytes = math.max(0, self.expanded_bytes - #item_id)
  end
  self.expanded[item_id] = expanded or nil
  return true
end

function Session:set_scroll_anchor(anchor)
  local live, live_err = self:_set()
  if not live then return nil, live_err end
  if anchor ~= nil and type(anchor) ~= "table" then return nil, "scroll anchor must be a data record" end
  if anchor == nil then self.scroll_anchor = nil; return true end
  local safe, err = clean_value(anchor, 1, { bytes = 0, max_bytes = 1024, seen = {} })
  if not safe then return nil, err end
  self.scroll_anchor = safe
  return true
end

function Session:snapshot()
  return self.store:session_snapshot(self.id)
end

function Session:close()
  if self.store.disposed or self.store.sessions[self.id] ~= self then return false end
  self.mounted = false
  return true
end

function Session:dispose()
  if self.store.disposed or self.store.sessions[self.id] ~= self then return false end
  self.store.sessions[self.id] = nil
  remove_id(self.store.session_order, self.id)
  return true
end

return M
