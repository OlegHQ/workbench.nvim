local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local Scope = require("workbench.core.scope")
local Actions = require("workbench.core.actions")
local Compose = require("workbench.compose")

local sample_count = 25
local iterations = 500
local registry = Actions.new()
local app = Compose.new()
local args = { query = "needle", include_hidden = false }
for index = 1, 50 do
  local action = {
    id = "bench.action_" .. index,
    title = "Benchmark action " .. index,
    category = "Benchmark",
    scope = "workspace",
    available = function() return { enabled = true } end,
    args_schema = {
      type = "object",
      properties = { query = { type = "string", min_length = 1 }, include_hidden = { type = "boolean" } },
      required = { "query" },
    },
    run = function(_, value) return value.query end,
  }
  assert(registry:register(action))
  assert(app.actions:register(action))
end

local function percentile(values, fraction)
  table.sort(values)
  return values[math.max(1, math.ceil(#values * fraction))]
end

local function measure(callback)
  local values = {}
  for sample = 1, sample_count do
    collectgarbage("collect")
    local started = vim.uv.hrtime()
    for _ = 1, iterations do callback() end
    values[sample] = (vim.uv.hrtime() - started) / iterations / 1000
  end
  local median = percentile(vim.deepcopy(values), 0.5)
  local p95 = percentile(values, 0.95)
  return { p50_us_per_operation = median, p95_us_per_operation = p95 }
end

local function scope_cycle()
  local scope = Scope.new("benchmark")
  for index = 1, 8 do scope:defer(function() return index end, "resource:" .. index) end
  assert(scope:dispose().ok)
end

local report = {
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  actions = #registry:inventory(),
  samples = sample_count,
  iterations_per_sample = iterations,
  cache = "warm Lua/module state; each sample forces Lua GC before timing",
  metrics = {
    action_execute = measure(function() assert(registry:execute("bench.action_1", {}, args).ok) end),
    list_50_actions = measure(function() assert(#registry:list({}) == 50) end),
    application_status_50_actions = measure(function() assert(#app:get_status().actions == 50) end),
    scope_create_dispose_8_resources = measure(scope_cycle),
  },
  action_count_after_runs = #registry:inventory(),
  application_resources = app.scope:inventory().resource_count,
}

print(vim.json.encode(report))
