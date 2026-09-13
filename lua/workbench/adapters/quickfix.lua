local M = {}

local function one_line(value)
  if type(value) ~= "string" then return "" end
  local text = value:gsub("[%c]", " "):gsub("%s+", " ")
  return vim.trim(text)
end

local function qf_item(item, result_set_id)
  local location = item.location
  if type(location) ~= "table" or type(location.resource) ~= "table" then return nil, "no_location" end
  local resource = location.resource
  if resource.scheme ~= "file" or type(resource.path) ~= "string" or resource.path == "" then
    return nil, "unsupported_resource"
  end
  local entry = {
    filename = resource.path,
    lnum = 0,
    col = 0,
    text = one_line(type(item.label) == "string" and item.label ~= "" and item.label or item.detail),
    valid = 1,
    user_data = { workbench_result_set_id = result_set_id, workbench_item_id = item.id },
  }
  if type(location.range) == "table" and type(location.range.start) == "table" then
    local start = location.range.start
    if type(start.line) ~= "number" or start.line < 0 or start.line % 1 ~= 0 then return nil, "invalid_location" end
    entry.lnum = start.line + 1
    if location.encoding == "utf-8" then
      if type(start.character) ~= "number" or start.character < 0 or start.character % 1 ~= 0 then return nil, "invalid_location" end
      entry.col = start.character + 1
    end
  end
  return entry
end

---Append one explicit, immutable result snapshot to the end of Neovim's quickfix history.
---This never opens the quickfix window and never replaces the current/older lists.
function M.export(result_set, opts)
  opts = opts or {}
  if type(opts) ~= "table" then return nil, { code = "invalid_options", message = "quickfix export options must be a table" } end
  if type(result_set) ~= "table" or type(result_set.id) ~= "string" or type(result_set.items) ~= "table"
    or type(result_set.order) ~= "table" then
    return nil, { code = "invalid_snapshot", message = "quickfix export requires a result-set snapshot" }
  end
  local count, maximum = 0, 0
  for key, id in pairs(result_set.order) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(id) ~= "string" or id == "" then
      return nil, { code = "invalid_snapshot", message = "quickfix result order must be a dense string-ID array" }
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum or count > 10000 then
    return nil, { code = "invalid_snapshot", message = "quickfix result order must be dense and contain at most 10,000 rows" }
  end
  local title = opts.title
  if title == nil then title = "Workbench: " .. result_set.id end
  if type(title) ~= "string" or title == "" then
    return nil, { code = "invalid_title", message = "quickfix snapshot title must be a non-empty string" }
  end
  title = one_line(title)
  if title == "" or #title > 256 then return nil, { code = "invalid_title", message = "quickfix snapshot title must contain at most 256 visible bytes" } end
  local items, skipped = {}, { no_location = 0, unsupported_resource = 0 }
  local seen = {}
  for _, id in ipairs(result_set.order) do
    if seen[id] then return nil, { code = "invalid_snapshot", message = "quickfix result order contains a duplicate ID" } end
    seen[id] = true
    local item = result_set.items[id]
    if type(item) == "table" then
      local entry, reason = qf_item(item, result_set.id)
      if entry then items[#items + 1] = entry
      elseif skipped[reason] ~= nil then skipped[reason] = skipped[reason] + 1
      else return nil, { code = "invalid_snapshot", message = "result item " .. tostring(id) .. " has an invalid location" } end
    else
      return nil, { code = "invalid_snapshot", message = "result order refers to a missing item" }
    end
  end
  local what = {
    nr = "$",
    items = items,
    title = title,
    context = {
      workbench = true,
      result_set_id = result_set.id,
      revision = result_set.revision,
      provider_id = result_set.provider_id,
      workspace_id = result_set.workspace_id,
    },
  }
  local ok, err = pcall(vim.fn.setqflist, {}, " ", what)
  if not ok then return nil, { code = "quickfix_error", message = tostring(err) } end
  local current = vim.fn.getqflist({ nr = 0, id = 0 })
  return {
    id = current.id,
    number = current.nr,
    title = title,
    exported = #items,
    skipped = skipped,
  }
end

M.export_snapshot = M.export

return M
