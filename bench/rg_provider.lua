local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local uv = vim.uv or vim.loop
local fixture = assert(vim.env.WB09_FIXTURE, "WB09_FIXTURE must point to a generated normal fixture")
local workspace_root = fixture .. "/workspace"
local repetitions = tonumber(vim.env.WB09_REPETITIONS) or 20
assert(repetitions >= 10 and repetitions <= 100, "WB09_REPETITIONS must be between 10 and 100")
local Workspace = require("workbench.services.workspace")
local workspace = assert(Workspace.new({
  root_service = { canonicalize = function(_, path) return path end },
  ignore_service = { snapshot = function() return { hidden = "exclude", ignored = "exclude", symlinks = "never", include = {}, exclude = {} } end },
}))
local snapshot = assert(workspace:open({ explicit_root = workspace_root }))

local function percentile(values, fraction)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.max(1, math.ceil(#sorted * fraction))]
end

local function summary(values)
  return {
    n = #values,
    p50_ms = percentile(values, 0.50),
    p95_ms = percentile(values, 0.95),
    max_ms = math.max(unpack(values)),
  }
end

local function now_ms()
  return uv.hrtime() / 1000000
end

local search_provider = assert(require("workbench.providers.rg").new())
local first_batch_ms, completion_ms = {}, {}
local max_item_count, max_result_bytes, max_pending_bytes, max_lua_kib = 0, 0, 0, 0
local full_status_counts = {}
local limit_reasons = {}
for index = 1, repetitions do
  collectgarbage("collect")
  local began = now_ms()
  local first_batch, finished
  local event_items = 0
  local handle = assert(search_provider:start({
    workspace = snapshot,
    query = "payload=",
    flags = { fixed = true, case = "sensitive" },
    generation = index,
    session_id = "search-" .. index,
  }, function(event)
    if event.kind == "batch" then
      event_items = event_items + #event.items
      if not first_batch then first_batch = now_ms() end
    elseif event.kind == "done" then
      finished = event
      if event.limit_reason then limit_reasons[event.limit_reason] = (limit_reasons[event.limit_reason] or 0) + 1 end
      if first_batch then
        completion_ms[#completion_ms + 1] = now_ms() - began
      end
    elseif event.kind == "error" then
      error("real rg search failed: " .. vim.inspect(event.error))
    end
    local active = search_provider:status().requests[1]
    if active then max_pending_bytes = math.max(max_pending_bytes, active.pending_bytes) end
  end))
  assert(vim.wait(30000, function() return finished ~= nil end, 2), "real ripgrep search timed out")
  assert(first_batch, "real ripgrep search emitted no result batch")
  first_batch_ms[#first_batch_ms + 1] = first_batch - began
  max_item_count = math.max(max_item_count, finished.total or event_items)
  max_result_bytes = math.max(max_result_bytes, finished.bytes or 0)
  max_lua_kib = math.max(max_lua_kib, collectgarbage("count"))
  full_status_counts[finished.status] = (full_status_counts[finished.status] or 0) + 1
  assert(not handle.active, "completed search request retained active ownership")
end
local post_search_inventory = search_provider:status()
assert(post_search_inventory.active_requests == 0, "search provider retained active requests after completion")
search_provider:dispose()

local cancellation_exit
local cancellation_probe
local function observed_system(argv, options, on_exit)
  return vim.system(argv, options, function(result)
    if cancellation_probe then cancellation_probe.exit_ms = now_ms() end
    on_exit(result)
  end)
end
local cancel_provider = assert(require("workbench.providers.rg").new({ system = observed_system }))
local cancellation_ms = {}
for index = 1, repetitions do
  cancellation_probe = {}
  local handle = assert(cancel_provider:start({
    workspace = snapshot,
    query = "payload=",
    flags = { fixed = true, case = "sensitive" },
    generation = repetitions + index,
    session_id = "cancel-" .. index,
  }, function() end))
  cancellation_probe.cancel_ms = now_ms()
  assert(handle:cancel("benchmark"))
  assert(vim.wait(5000, function() return cancellation_probe.exit_ms ~= nil end, 1), "cancelled rg process was not reaped")
  cancellation_ms[#cancellation_ms + 1] = cancellation_probe.exit_ms - cancellation_probe.cancel_ms
  assert(cancel_provider:status().active_requests == 0, "cancelled request remained active")
end
cancel_provider:dispose()

local output = {
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  rg = vim.fn.system({ "rg", "--version" }):match("[^\r\n]+"),
  fixture = fixture,
  fixture_tier = "normal",
  fixture_files = 10000,
  fixture_content_bytes = 20480000,
  query = "payload= (fixed string)",
  cache = repetitions .. " sequential warm searches and cancellation runs; no debounce included",
  repetitions = repetitions,
  first_batch = summary(first_batch_ms),
  completion = summary(completion_ms),
  cancellation_to_process_exit = summary(cancellation_ms),
  maximum_items = max_item_count,
  maximum_accounted_result_bytes = max_result_bytes,
  maximum_pending_output_bytes = max_pending_bytes,
  lua_heap_after_completion_kib = max_lua_kib,
  statuses = full_status_counts,
  limit_reasons = limit_reasons,
  limits = post_search_inventory.limits,
}
print(vim.json.encode(output))
vim.cmd("qa!")
