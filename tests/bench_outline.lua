local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
local uv = vim.uv or vim.loop

local function percentile(values, fraction)
  table.sort(values)
  return values[math.max(1, math.ceil(#values * fraction))]
end

local function summarize(samples)
  return {
    operations = #samples,
    p50_us = percentile(vim.deepcopy(samples), 0.50),
    p95_us = percentile(samples, 0.95),
  }
end

local function fixture(total)
  local items, line_count = {}, math.max(1, total - math.floor(total / 10))
  local child_count = 0
  for index = 1, total do
    if index % 11 == 1 then
      local line = math.floor(index / 11)
      items[#items + 1] = {
        id = "group-" .. index,
        label = string.format("group %05d", index),
        payload = { source_order = index, source_range_bytes = { start = { line = 0, character = 0 }, finish = { line = line_count, character = 80 } } },
      }
    else
      child_count = child_count + 1
      local parent = index - ((index - 1) % 11)
      local line = child_count
      items[#items + 1] = {
        id = "symbol-" .. index,
        label = string.format("symbol %05d", index),
        parent_id = "group-" .. parent,
        payload = { source_order = index, source_range_bytes = { start = { line = line, character = 0 }, finish = { line = line, character = 40 } } },
      }
    end
  end
  return items
end

local Outline = require("workbench.ui.outline")
local reports = {}
for _, total in ipairs({ 2000, 10000 }) do
  local items = fixture(total)
  local index_started = uv.hrtime()
  local range_index = assert(Outline.build_enclosing_index(items))
  local index_build_us = (uv.hrtime() - index_started) / 1000
  local cursor_samples = {}
  for index = 1, 500 do
    local before = uv.hrtime()
    local active = Outline.enclosing(items, math.floor(total * 0.43), 8, range_index)
    cursor_samples[index] = (uv.hrtime() - before) / 1000
    assert(active ~= nil)
  end
  local scan_samples = {}
  for index = 1, 50 do
    local before = uv.hrtime()
    assert(Outline.enclosing(items, math.floor(total * 0.43), 8))
    scan_samples[index] = (uv.hrtime() - before) / 1000
  end
  local source_samples, name_samples, filter_samples = {}, {}, {}
  for index = 1, 12 do
    local before = uv.hrtime()
    assert(Outline.project(items, { order = "source", status = "ready" }))
    source_samples[index] = (uv.hrtime() - before) / 1000

    before = uv.hrtime()
    assert(Outline.project(items, { order = "name", status = "ready" }))
    name_samples[index] = (uv.hrtime() - before) / 1000

    before = uv.hrtime()
    local filtered = assert(Outline.project(items, { order = "source", filter = "symbol 000", status = "ready" }))
    filter_samples[index] = (uv.hrtime() - before) / 1000
    assert(#filtered.items > 0)
  end
  reports[#reports + 1] = {
    symbols = total,
    range_index_build_us = index_build_us,
    cursor_enclosing = summarize(cursor_samples),
    cursor_enclosing_linear_scan = summarize(scan_samples),
    projection_source_order = summarize(source_samples),
    projection_name_order = summarize(name_samples),
    projection_filter_and_ancestors = summarize(filter_samples),
  }
end

vim.o.columns, vim.o.lines = 120, 35
local view_reports = {}
for _, total in ipairs({ 2000, 10000 }) do
  local items = fixture(total)
  local layout = assert(require("workbench.ui.layout").new({ min_editor_width = 30, min_editor_height = 8 }))
  local before_mount = uv.hrtime()
  local view = assert(layout:mount({
    id = "outline-bench-" .. total,
    title = "Outline · source order",
    kind = "tree",
    placement = "sidebar",
    focus = false,
    help_lines = {},
    model = { status = "ready", items = items, active_id = "group-1", header = { "Breadcrumbs: group 1" } },
  }))
  local mount_ms = (uv.hrtime() - before_mount) / 1000000
  local dynamic_samples = {}
  for index = 1, 300 do
    local active_id = index % 2 == 0 and "group-1" or "symbol-2"
    local header = { "Breadcrumbs: " .. active_id }
    local before = uv.hrtime()
    assert(view:update_dynamic(active_id, header))
    dynamic_samples[index] = (uv.hrtime() - before) / 1000
  end
  view_reports[#view_reports + 1] = {
    symbols = total,
    view_mount_ms = mount_ms,
    visible_rows = #view.visible_rows,
    cursor_dynamic_update = summarize(dynamic_samples),
  }
  layout:dispose()
end

collectgarbage("collect")
print(vim.json.encode({
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  cache = "warm Outline module; 500 indexed cursor queries, 12 projections per mode, and 300 real View dynamic updates at 2k/10k symbols",
  measurements = reports,
  view_measurements = view_reports,
}))
vim.cmd("qa!")
