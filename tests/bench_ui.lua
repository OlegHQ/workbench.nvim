local uv = vim.uv or vim.loop
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local function summarize(values)
  table.sort(values)
  local function percentile(p)
    local rank = (math.max(1, #values) - 1) * p + 1
    local lower = math.floor(rank)
    local upper = math.ceil(rank)
    return values[lower] + (values[upper] - values[lower]) * (rank - lower)
  end
  return { p50_us = percentile(0.50), p95_us = percentile(0.95), samples = #values }
end

local function measure(iterations, samples, callback)
  local values = {}
  for sample = 1, samples do
    collectgarbage("collect")
    local started = uv.hrtime()
    for _ = 1, iterations do callback() end
    values[sample] = (uv.hrtime() - started) / iterations / 1000
  end
  return summarize(values)
end

vim.o.columns = 160
vim.o.lines = 50
local started = uv.hrtime()
local Layout = require("workbench.ui.layout")
local cold_require_us = (uv.hrtime() - started) / 1000
local layout = Layout.new()
local first = assert(layout:mount({
  id = "first-use",
  title = "Files",
  kind = "list",
  placement = "sidebar",
  focus = false,
  model = { status = "ready", items = { { id = "item.one", label = "one" } } },
}))
local cold_mount_us = (uv.hrtime() - started) / 1000
assert(first:close())

local small_items = {}
for index = 1, 20 do small_items[index] = { id = "small." .. index, label = "item " .. index } end
local warm_mount = measure(1, 25, function()
  local view = assert(layout:mount({ id = "warm", title = "Files", kind = "list", focus = false, model = { status = "ready", items = small_items } }))
  assert(view:close())
end)

local many = {}
for index = 1, 10000 do many[index] = { id = "result." .. index, label = "result " .. index } end
local Projection = require("workbench.ui.projection")
local list_10k = measure(1, 25, function() assert(Projection.list(many, 20000)) end)
local tree_items = { { id = "root", label = "root", kind = "directory" } }
for index = 1, 9999 do tree_items[#tree_items + 1] = { id = "child." .. index, label = "child " .. index, parent_id = "root" } end
local tree_10k = measure(1, 25, function() assert(Projection.tree(tree_items, { root = true }, 20000)) end)

local scrolling = assert(layout:mount({
  id = "scroll-bench",
  title = "Results",
  kind = "list",
  placement = "results",
  focus = true,
  model = { status = "ready", items = many },
}))
local movement_samples = {}
for index = 1, 1000 do
  local before = uv.hrtime()
  assert(scrolling:move(1))
  movement_samples[index] = (uv.hrtime() - before) / 1000
end
local cached_selection = summarize(movement_samples)
assert(scrolling:close())

local cycles = 100
for index = 1, cycles do
  local view = assert(layout:mount({ id = "cycle-" .. index, title = "Cycle", focus = false, model = { status = "ready", items = small_items } }))
  assert(view:close())
end
local final = layout:status()
assert(final.active_views == 0 and final.resources.resource_count == 0)
layout:dispose()

print(vim.json.encode({
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  cache = "warm operation samples after first lazy require; collectgarbage before each batch",
  cold_first_view = { require_us = cold_require_us, require_and_mount_us = cold_mount_us },
  warm_mount_close_20_items = warm_mount,
  projection_list_10k = list_10k,
  projection_tree_10k = tree_10k,
  cached_selection_render_10k = cached_selection,
  cached_selection_operations = 1000,
  lifecycle_cycles = cycles,
  final_resources = final.resources.resource_count,
}))
vim.cmd("qa!")
