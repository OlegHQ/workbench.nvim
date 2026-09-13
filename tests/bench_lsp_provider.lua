local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
local uv = vim.uv or vim.loop

local function percentile(values, fraction)
  table.sort(values)
  local rank = math.max(1, math.ceil(#values * fraction))
  return values[rank]
end

local function summary(values)
  return {
    p50_ms = percentile(vim.deepcopy(values), 0.50),
    p95_ms = percentile(vim.deepcopy(values), 0.95),
    min_ms = math.min(unpack(values)),
    max_ms = math.max(unpack(values)),
  }
end

local method = "textDocument/documentSymbol"
local path = vim.fn.tempname() .. "-workbench-lsp-bench.lua"
local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, path)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local benchmark = true" })
local client = {
  id = 1,
  name = "workbench-lsp-bench",
  offset_encoding = "utf-16",
  attached_buffers = { [bufnr] = "lua" },
}
function client:supports_method(candidate, buffer)
  return candidate == method and self.attached_buffers[buffer] ~= nil
end
function client:request(_, _, handler)
  self.handler = handler
  self.next_request_id = (self.next_request_id or 0) + 1
  return true, self.next_request_id
end
function client:cancel_request() end

local provider = assert(require("workbench.providers.lsp").new({ get_clients = function() return { client } end }))
local uri = vim.uri_from_bufnr(bufnr)
local total, batch_size = 2000, 64
local symbols = {}
for index = 1, total do
  local position = { line = 0, character = index % 18 }
  symbols[index] = {
    name = "BenchmarkSymbol" .. index,
    detail = "bounded synthetic LSP symbol payload",
    kind = 12,
    range = { start = position, ["end"] = { line = 0, character = position.character + 1 } },
    selectionRange = { start = position, ["end"] = { line = 0, character = position.character + 1 } },
  }
end

local samples, first_batch_samples, max_slice_samples = {}, {}, {}
local observed_items, observed_batches = 0, 0
local observed_slices, yielded_before_done = 0, false
local runs, warmup = 10, 2
for run = 1, runs + warmup do
  collectgarbage("collect")
  local events, first_batch_at, did_yield = {}, nil, false
  local started = uv.hrtime()
  local handle = assert(provider:start({
    bufnr = bufnr,
    method = method,
    params = { textDocument = { uri = uri } },
  }, function(event)
    events[#events + 1] = event
    if event.kind == "batch" and first_batch_at == nil then
      first_batch_at = uv.hrtime()
      vim.schedule(function()
        if not events[#events] or events[#events].kind ~= "done" then did_yield = true end
      end)
    end
  end))
  client.handler(nil, symbols)
  assert(vim.wait(30000, function() return events[#events] and events[#events].kind == "done" end, 1), "LSP benchmark request timed out")
  local elapsed_ms = (uv.hrtime() - started) / 1000000
  assert(not handle:is_active())
  local items, batches = 0, 0
  for _, event in ipairs(events) do
    if event.kind == "batch" then
      items = items + #event.items
      batches = batches + 1
    end
  end
  assert(items == total and batches >= math.ceil(total / batch_size), vim.inspect({ items = items, batches = batches }))
  assert(did_yield, "normalization did not yield between result slices")
  if run > warmup then
    samples[#samples + 1] = elapsed_ms
    first_batch_samples[#first_batch_samples + 1] = (first_batch_at - started) / 1000000
    local status = handle:status()
    max_slice_samples[#max_slice_samples + 1] = status.normalization_max_slice_ms
    observed_items, observed_batches = items, batches
    observed_slices = status.normalization_slices
    yielded_before_done = did_yield
  end
end

method = "workspace/symbol"
local workspace_symbols = {}
for index = 1, total do
  workspace_symbols[index] = {
    name = "DeferredBenchmarkSymbol" .. index,
    kind = 12,
    containerName = "benchmark.module",
    data = { resolver_token = "token-" .. index },
    location = { uri = "file:///workbench-benchmark/module.lua" },
  }
end
local workspace_samples, workspace_first_batch_samples, workspace_slice_samples = {}, {}, {}
local workspace_observed_items, workspace_observed_batches, workspace_observed_slices = 0, 0, 0
for run = 1, runs + warmup do
  collectgarbage("collect")
  local events, first_batch_at, did_yield = {}, nil, false
  local started = uv.hrtime()
  local handle = assert(provider:start({
    bufnr = bufnr,
    method = method,
    params = { query = "DeferredBenchmarkSymbol" },
  }, function(event)
    events[#events + 1] = event
    if event.kind == "batch" and first_batch_at == nil then
      first_batch_at = uv.hrtime()
      vim.schedule(function()
        if not events[#events] or events[#events].kind ~= "done" then did_yield = true end
      end)
    end
  end))
  client.handler(nil, workspace_symbols)
  assert(vim.wait(30000, function() return events[#events] and events[#events].kind == "done" end, 1), "workspace-symbol benchmark request timed out")
  local elapsed_ms = (uv.hrtime() - started) / 1000000
  assert(not handle:is_active())
  local items, batches = 0, 0
  for _, event in ipairs(events) do
    if event.kind == "batch" then
      items = items + #event.items
      batches = batches + 1
      for _, item in ipairs(event.items) do
        assert(item.kind == "symbol" and item.location == nil and item.payload.shape == "unresolved_workspace_symbol")
      end
    end
  end
  assert(items == total and batches >= math.ceil(total / batch_size), vim.inspect({ items = items, batches = batches }))
  assert(did_yield, "workspace-symbol normalization did not yield between result slices")
  if run > warmup then
    workspace_samples[#workspace_samples + 1] = elapsed_ms
    workspace_first_batch_samples[#workspace_first_batch_samples + 1] = (first_batch_at - started) / 1000000
    local status = handle:status()
    workspace_slice_samples[#workspace_slice_samples + 1] = status.normalization_max_slice_ms
    workspace_observed_items, workspace_observed_batches = items, batches
    workspace_observed_slices = status.normalization_slices
  end
end

local resources = provider:status().resources.resource_count
provider:dispose()
assert(provider:status().resources.resource_count == 0)
print(vim.json.encode({
  nvim = vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
  os = vim.uv.os_uname().sysname .. " " .. vim.uv.os_uname().machine,
  fixture = "warm 2,000 flat DocumentSymbol items; UTF-16; 64-item sink batches; stable file URI",
  warmup_runs = warmup,
  measured_runs = runs,
  normalized_items = observed_items,
  emitted_batches = observed_batches,
  normalization_slices = observed_slices,
  yielded_before_done = yielded_before_done,
  end_to_end_response = summary(samples),
  first_batch = summary(first_batch_samples),
  max_normalization_slice = summary(max_slice_samples),
  resources_before_dispose = resources,
  resources_after_dispose = provider:status().resources.resource_count,
  workspace_symbol_fixture = "warm 2,000 unresolved LSP 3.17 WorkspaceSymbol partial locations with per-symbol resolver tokens; UTF-16; 64-item sink batches",
  workspace_symbol_items = workspace_observed_items,
  workspace_symbol_batches = workspace_observed_batches,
  workspace_symbol_normalization_slices = workspace_observed_slices,
  workspace_symbol_end_to_end_response = summary(workspace_samples),
  workspace_symbol_first_batch = summary(workspace_first_batch_samples),
  workspace_symbol_max_normalization_slice = summary(workspace_slice_samples),
}))
vim.cmd("qa!")
