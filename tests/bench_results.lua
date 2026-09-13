local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
local uv = vim.uv or vim.loop

local function percentile(values, fraction)
  table.sort(values)
  local rank = math.max(1, math.ceil(#values * fraction))
  return values[rank]
end

local store = assert(require("workbench.services.results").new())
local started = uv.hrtime()
assert(store:create({ id = "bench-10k", provider_id = "synthetic", workspace_id = "bench", generation = 1 }))
local batch_size, total = 512, 10000
for first = 1, total, batch_size do
  local batch = {}
  for index = first, math.min(total, first + batch_size - 1) do
    batch[#batch + 1] = { id = "match-" .. index, kind = "match", label = "result line " .. index }
  end
  local snapshot = assert(store:merge("bench-10k", batch))
  assert(snapshot.status == "running")
end
local ingestion_ms = (uv.hrtime() - started) / 1000000
local session = assert(store:open_session("bench-10k", { selected_id = "match-1" }))
local selection_samples = {}
for index = 1, 1000 do
  local before = uv.hrtime()
  assert(session:select("match-" .. ((index % total) + 1)))
  selection_samples[index] = (uv.hrtime() - before) / 1000
end
local selection = {
  operations = #selection_samples,
  p50_us = percentile(vim.deepcopy(selection_samples), 0.50),
  p95_us = percentile(selection_samples, 0.95),
}
collectgarbage("collect")
local snapshot_samples = {}
for index = 1, 25 do
  local before = uv.hrtime()
  assert(store:get("bench-10k"))
  snapshot_samples[index] = (uv.hrtime() - before) / 1000
end
local snapshot = {
  p50_us = percentile(vim.deepcopy(snapshot_samples), 0.50),
  p95_us = percentile(snapshot_samples, 0.95),
}
local page_samples = {}
for index = 1, 100 do
  local before = uv.hrtime()
  assert(store:page("bench-10k", 0, 100))
  page_samples[index] = (uv.hrtime() - before) / 1000
end
local page = {
  items = 100,
  p50_us = percentile(vim.deepcopy(page_samples), 0.50),
  p95_us = percentile(page_samples, 0.95),
}
local inventory = store:status()
assert(inventory.items == total and inventory.bytes <= 32 * 1024 * 1024)
local view_cycles = 100
for index = 1, view_cycles do
  local view = assert(store:open_session("bench-10k"))
  assert(view:close())
  assert(view:dispose())
end
local final = store:status()
assert(final.sessions == 1 and final.items == total)
store:dispose()

print(vim.json.encode({
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  cache = "warm Lua/module; 10k stable synthetic results in 512-item batches; collectgarbage before snapshot samples",
  result_items = total,
  accounted_bytes = inventory.bytes,
  ingest_ms = ingestion_ms,
  cached_selection = selection,
  defensive_snapshot = snapshot,
  bounded_page = page,
  view_session_cycles = view_cycles,
  retained_sessions_after_cycles = final.sessions,
  total_store_byte_limit = 32 * 1024 * 1024,
}))
vim.cmd("qa!")
