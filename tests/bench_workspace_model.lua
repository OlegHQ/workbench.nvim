local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local Resource = require("workbench.core.resource")
local Location = require("workbench.core.location")
local Workspace = require("workbench.services.workspace")
local WorkspaceModel = require("workbench.core.workspace")

local sample_count = 25
local iterations = 500
local path = "/tmp/workbench-model-benchmark/src/example.lua"
local service = assert(Workspace.new({
  root_service = { canonicalize = function(_, value) return value end },
  ignore_service = { snapshot = function() return { include = { "src/**" }, exclude = {} } end },
}))
local snapshot = assert(service:open({ explicit_root = "/tmp/workbench-model-benchmark" }))
local resource = assert(Resource.from_path(path))
local location = assert(Location.new(resource, {
  range = { start = { line = 0, character = 9 }, finish = { line = 0, character = 10 } },
  encoding = "utf-16",
}))
local line = "prefix 😀é界\tvalue"

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

local report = {
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  samples = sample_count,
  iterations_per_sample = iterations,
  cache = "warm Lua/module and filesystem metadata; each sample forces Lua GC before timing",
  metrics = {
    uri_helper_baseline = measure(function() vim.uri_from_fname(path) end),
    resource_constructor = measure(function() assert(Resource.from_path(path)) end),
    deepcopy_snapshot_baseline = measure(function() vim.deepcopy(snapshot) end),
    workspace_snapshot_copy = measure(function() assert(service:snapshot()) end),
    workspace_attach = measure(function() assert(service:open({ explicit_root = "/tmp/workbench-model-benchmark" })) end),
    workspace_refresh = measure(function() assert(service:refresh()) end),
    utf16_to_nvim_byte_range = measure(function() assert(Location.resolve_range(location, { line })) end),
  },
  final_generation = service.generation,
}

print(vim.json.encode(report))
