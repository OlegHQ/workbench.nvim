local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

local fake_helpers = [[
  local function fake_client(id, bufnr, encoding, supported)
    local client = {
      id = id,
      name = 'fake-' .. id,
      offset_encoding = encoding,
      attached_buffers = { [bufnr] = 'lua' },
      supported = supported or {},
      calls = {},
      cancelled = {},
    }
    function client:supports_method(method, buffer)
      return self.attached_buffers[buffer] ~= nil and self.supported[method] == true
    end
    function client:request(method, params, handler, buffer)
      self.calls[#self.calls + 1] = { method = method, params = params, handler = handler, bufnr = buffer }
      return true, #self.calls
    end
    function client:cancel_request(request_id)
      self.cancelled[#self.cancelled + 1] = request_id
      return true
    end
    return client
  end
  local function make_provider(clients, opts)
    opts = vim.tbl_extend('force', opts or {}, {
      get_clients = function(bufnr)
        local result = {}
        for _, client in ipairs(clients) do
          if client.attached_buffers[bufnr] then result[#result + 1] = client end
        end
        return result
      end,
    })
    local provider = assert(require('workbench.providers.lsp').new(opts))
    return provider
  end
  local function source_buffer(name, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { 'a😀b' })
    return buf
  end
  local function wait_done(events)
    local ok = vim.wait(1000, function() return events[#events] and events[#events].kind == 'done' end, 5)
    if not ok then error('LSP provider did not finish: events=' .. vim.inspect(events)) end
  end
  local function all_items(events)
    local result = {}
    for _, event in ipairs(events) do
      if event.kind == 'batch' then
        for _, item in ipairs(event.items) do result[#result + 1] = item end
      end
    end
    return result
  end
  local function supported(method)
    return { [method] = true }
  end
]]

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], {
        root,
        root .. "/tests",
      })
    end,
    post_case = function()
      if child then
        pcall(child.stop)
        child = nil
      end
    end,
  },
}, {
  ["capability lookup rechecks dynamic support and routes only attached clients"] = function()
    local result = evaluate(fake_helpers .. [[
      local bufnr = source_buffer(vim.fn.tempname() .. '.lua')
      local clients = {}
      local provider = make_provider(clients)
      local absent = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      local client = fake_client(11, bufnr, 'utf-16', {})
      clients[1] = client
      vim.api.nvim_exec_autocmds('LspAttach', { buffer = bufnr, data = { client_id = client.id } })
      local unsupported = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      client.supported['textDocument/documentSymbol'] = true
      local ready = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      client.supported['textDocument/documentSymbol'] = false
      local rejected, rejected_error = provider:start({ bufnr = bufnr, method = 'textDocument/documentSymbol' }, function() end)
      client.supported['textDocument/documentSymbol'] = true
      local events = {}
      local handle = assert(provider:start({ bufnr = bufnr, method = 'textDocument/documentSymbol', generation = 4, session_id = 'outline' }, function(event) events[#events + 1] = event end))
      local routed = client.calls[1].method == 'textDocument/documentSymbol' and client.calls[1].bufnr == bufnr
      client.calls[1].handler(nil, nil)
      wait_done(events)
      local result = {
        absent = absent,
        unsupported = unsupported,
        ready = ready,
        rejected = rejected == nil,
        rejected_code = rejected_error and rejected_error.code,
        routed = routed,
        status = events[#events].status,
        generation = events[#events].generation,
        session_id = events[#events].session_id,
        handle_active = handle:is_active(),
        active_requests = provider:status().active_requests,
      }
      provider:dispose()
      result.disposed_resources = provider:status().resources.resource_count
      return result
    ]])
    expect.equality(result.absent.code, "no_attached_client")
    expect.equality(result.unsupported.code, "unsupported_method")
    expect.equality(result.ready.state, "ready")
    expect.equality(result.ready.clients[1].encoding, "utf-16")
    expect.equality(result.rejected, true)
    expect.equality(result.rejected_code, "unsupported_method")
    expect.equality(result.routed, true)
    expect.equality(result.status, "complete")
    expect.equality(result.generation, 4)
    expect.equality(result.session_id, "outline")
    expect.equality(result.handle_active, false)
    expect.equality(result.active_requests, 0)
    expect.equality(result.disposed_resources, 0)
  end,

  ["document symbols normalize hierarchy, ranges, encoding, client ID and source version"] = function()
    local result = evaluate(fake_helpers .. [[
      local path = vim.fn.tempname() .. '-mixed.lua'
      local bufnr = source_buffer(path)
      local version = vim.api.nvim_buf_get_changedtick(bufnr)
      local method = 'textDocument/documentSymbol'
      local clients = {
        fake_client(21, bufnr, 'utf-8', supported(method)),
        fake_client(22, bufnr, 'utf-16', supported(method)),
      }
      local provider = make_provider(clients)
      local events = {}
      assert(provider:start({ bufnr = bufnr, method = method, workspace = { id = 'mixed', generation = 9 } }, function(event) events[#events + 1] = event end))
      local function symbol(client_id, encoding, start_col, end_col)
        return {
          name = 'Emoji', kind = 13,
          detail = encoding,
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = end_col + 1 } },
          selectionRange = { start = { line = 0, character = start_col }, ['end'] = { line = 0, character = end_col } },
          children = {
            {
              name = 'Child', kind = 12,
              range = { start = { line = 0, character = start_col }, ['end'] = { line = 0, character = end_col } },
              selectionRange = { start = { line = 0, character = start_col }, ['end'] = { line = 0, character = end_col } },
            },
          },
        }
      end
      clients[1].calls[1].handler(nil, { symbol(21, 'utf-8', 1, 5) })
      clients[2].calls[1].handler(nil, { symbol(22, 'utf-16', 1, 3) })
      wait_done(events)
      local items = all_items(events)
      local by_client = {}
      for _, item in ipairs(items) do
        local cid = item.payload.client_id
        by_client[cid] = by_client[cid] or {}
        by_client[cid][#by_client[cid] + 1] = item
      end
      local utf8_parent, utf16_parent = by_client[21][1], by_client[22][1]
      local output = {
        status = events[#events].status,
        count = #items,
        utf8 = { encoding = utf8_parent.location.encoding, start = utf8_parent.location.range.start.character, finish = utf8_parent.location.range.finish.character, version = utf8_parent.location.version, payload_version = utf8_parent.payload.buffer_version, child_parent = by_client[21][2].parent_id == utf8_parent.id },
        utf16 = { encoding = utf16_parent.location.encoding, start = utf16_parent.location.range.start.character, finish = utf16_parent.location.range.finish.character, version = utf16_parent.location.version, child_parent = by_client[22][2].parent_id == utf16_parent.id },
        unique_client_ids = utf8_parent.id ~= utf16_parent.id,
        workspace_generation = events[1].workspace_generation,
      }
      provider:dispose()
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 4)
    expect.equality(result.utf8.encoding, "utf-8")
    expect.equality(result.utf8.start, 1)
    expect.equality(result.utf8.finish, 5)
    expect.equality(result.utf8.version, result.utf8.payload_version)
    expect.equality(result.utf8.child_parent, true)
    expect.equality(result.utf16.encoding, "utf-16")
    expect.equality(result.utf16.start, 1)
    expect.equality(result.utf16.finish, 3)
    expect.equality(result.utf16.version, result.utf8.version)
    expect.equality(result.utf16.child_parent, true)
    expect.equality(result.unique_client_ids, true)
    expect.equality(result.workspace_generation, 9)
  end,

  ["reverse-order two-client responses preserve each negotiated encoding and provenance"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = source_buffer(vim.fn.tempname() .. '-source.lua')
      local target = vim.fn.tempname() .. '-target.lua'
      vim.fn.writefile({ 'target' }, target)
      local method = 'textDocument/definition'
      local clients = {
        fake_client(31, source, 'utf-8', supported(method)),
        fake_client(32, source, 'utf-16', supported(method)),
      }
      local provider = make_provider(clients)
      local events = {}
      local workspace = { id = 'links', generation = 3 }
      assert(provider:start({ bufnr = source, method = method, workspace = workspace }, function(event) events[#events + 1] = event end))
      local target_uri = vim.uri_from_fname(target)
      -- Deliver the second client's response first. The provider schedules each
      -- normalization independently, so the winning event order must not leak
      -- the first client's UTF-8 encoding into the UTF-16 result (or vice versa).
      clients[2].calls[1].handler(nil, { { uri = target_uri, range = { start = { line = 0, character = 2 }, ['end'] = { line = 0, character = 4 } } } })
      clients[1].calls[1].handler(nil, { {
        targetUri = target_uri,
        targetRange = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 6 } },
        targetSelectionRange = { start = { line = 0, character = 1 }, ['end'] = { line = 0, character = 3 } },
        originSelectionRange = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
      } })
      wait_done(events)
      local items = all_items(events)
      local output = {
        status = events[#events].status,
        count = #items,
        first = { shape = items[1].payload.shape, client = items[1].location.client_id, encoding = items[1].location.encoding, start = items[1].location.range.start.character, version = items[1].location.version, target_range = items[1].payload.target_range, origin = items[1].payload.origin_selection_range, path = items[1].location.resource.path },
        second = { shape = items[2].payload.shape, client = items[2].location.client_id, encoding = items[2].location.encoding, start = items[2].location.range.start.character, version = items[2].location.version, target_range = items[2].payload.target_range, origin = items[2].payload.origin_selection_range },
      }
      provider:dispose()
      vim.fn.delete(target)
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 2)
    expect.equality(result.first.shape, "location")
    expect.equality(result.first.client, 32)
    expect.equality(result.first.encoding, "utf-16")
    expect.equality(result.first.start, 2)
    expect.equality(result.first.version, nil)
    expect.equality(result.second.shape, "location_link")
    expect.equality(result.second.client, 31)
    expect.equality(result.second.encoding, "utf-8")
    expect.equality(result.second.start, 1)
    expect.equality(result.second.version, nil)
    expect.equality(result.second.target_range.start.line, 0)
    expect.equality(result.second.origin.start.character, 0)
  end,

  ["flat SymbolInformation preserves container, location, encoding and resolve data"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = source_buffer(vim.fn.tempname() .. '-workspace-symbol.lua')
      local target = vim.fn.tempname() .. '-symbol-target.lua'
      vim.fn.writefile({ 'return FlatThing' }, target)
      local method = 'workspace/symbol'
      local client = fake_client(35, source, 'utf-8', supported(method))
      local provider = make_provider({ client })
      local events = {}
      assert(provider:start({ bufnr = source, method = method, params = { query = 'FlatThing' } }, function(event) events[#events + 1] = event end))
      client.calls[1].handler(nil, { {
        name = 'FlatThing',
        kind = 5,
        containerName = 'lib',
        data = { server_key = 'opaque-resolve-token' },
        location = {
          uri = vim.uri_from_fname(target),
          range = { start = { line = 0, character = 7 }, ['end'] = { line = 0, character = 16 } },
        },
      } })
      wait_done(events)
      local item = all_items(events)[1]
      local output = {
        status = events[#events].status,
        kind = item and item.kind,
        label = item and item.label,
        detail = item and item.detail,
        shape = item and item.payload.shape,
        encoding = item and item.location.encoding,
        client_id = item and item.location.client_id,
        start = item and item.location.range.start.character,
        finish = item and item.location.range.finish.character,
        container = item and item.payload.container_name,
        resolve_data = item and item.payload.data,
        path = item and item.location.resource.path,
      }
      provider:dispose()
      vim.fn.delete(target)
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.kind, "symbol")
    expect.equality(result.label, "FlatThing")
    expect.equality(result.detail, "lib")
    expect.equality(result.shape, "symbol_information")
    expect.equality(result.encoding, "utf-8")
    expect.equality(result.client_id, 35)
    expect.equality(result.start, 7)
    expect.equality(result.finish, 16)
    expect.equality(result.container, "lib")
    expect.equality(result.resolve_data.server_key, "opaque-resolve-token")
    expect.equality(result.path:find("symbol-target.lua", 1, true) ~= nil, true)
  end,

  ["locationless workspace symbols retain bounded resolver input"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = source_buffer(vim.fn.tempname() .. '-unresolved-workspace-symbol.lua')
      local method = 'workspace/symbol'
      local client = fake_client(41, source, 'utf-16', supported(method))
      local provider = make_provider({ client })
      local events = {}
      assert(provider:start({ bufnr = source, method = method, params = { query = 'Deferred' } }, function(event) events[#events + 1] = event end))
      client.calls[1].handler(nil, { {
        name = 'Deferred', kind = 13, containerName = 'package', tags = { 1 },
        data = { opaque = 'resolve-on-select' },
      } })
      wait_done(events)
      local item = all_items(events)[1]
      local absent = provider:capabilities({ bufnr = source, method = 'workspaceSymbol/resolve', client_ids = { 99 } })
      local output = { count = #all_items(events), status = events[#events].status,
        location = item and item.location, kind = item and item.kind, label = item and item.label,
        shape = item and item.payload.shape, client = item and item.payload.client_id,
        token = item and item.payload.resolve_item.data.opaque,
        name = item and item.payload.resolve_item.name,
        absent_code = absent.code }
      provider:dispose()
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 1)
    expect.equality(result.location, nil)
    expect.equality(result.kind, "symbol")
    expect.equality(result.label, "Deferred")
    expect.equality(result.shape, "unresolved_workspace_symbol")
    expect.equality(result.client, 41)
    expect.equality(result.token, "resolve-on-select")
    expect.equality(result.name, "Deferred")
    expect.equality(result.absent_code, "client_detached")
  end,

  ["LSP 3.17 partial workspace-symbol locations stay deferred until resolve"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = source_buffer(vim.fn.tempname() .. '-partial-workspace-symbol.lua')
      local method = 'workspace/symbol'
      local client = fake_client(43, source, 'utf-16', supported(method))
      local provider = make_provider({ client })
      local events = {}
      assert(provider:start({ bufnr = source, method = method, params = { query = 'Deferred' } }, function(event) events[#events + 1] = event end))
      client.calls[1].handler(nil, { {
        name = 'Deferred', kind = 13, data = { opaque = 'partial-location' },
        location = { uri = 'file:///workspace/deferred.py' },
      } })
      wait_done(events)
      local item = all_items(events)[1]
      local output = { count = #all_items(events), status = events[#events].status,
        location = item and item.location, shape = item and item.payload.shape,
        resolve_uri = item and item.payload.resolve_item.location.uri,
        resolve_data = item and item.payload.resolve_item.data.opaque }
      provider:dispose()
      return output
    ]])
    expect.equality(result.status, "complete")
    expect.equality(result.count, 1)
    expect.equality(result.location, nil)
    expect.equality(result.shape, "unresolved_workspace_symbol")
    expect.equality(result.resolve_uri, "file:///workspace/deferred.py")
    expect.equality(result.resolve_data, "partial-location")
  end,

  ["client targeted resolve capability and request never cross to sibling servers"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = source_buffer(vim.fn.tempname() .. '-targeted-resolve.lua')
      local target = vim.fn.tempname() .. '-resolved.lua'
      vim.fn.writefile({ 'return Resolved' }, target)
      local method = 'workspaceSymbol/resolve'
      local first = fake_client(51, source, 'utf-16', supported(method))
      local second = fake_client(52, source, 'utf-8', supported(method))
      local provider = make_provider({ first, second })
      local capability = provider:capabilities({ bufnr = source, method = method, client_ids = { 52 } })
      local events = {}
      assert(provider:start({ bufnr = source, method = method, client_ids = { 52 },
        params = { name = 'Resolved', kind = 13, data = { token = 'from-52' } } }, function(event) events[#events + 1] = event end))
      second.calls[1].handler(nil, { name = 'Resolved', kind = 13, data = { token = 'from-52' }, location = {
        uri = vim.uri_from_fname(target), range = { start = { line = 0, character = 7 }, ['end'] = { line = 0, character = 15 } },
      } })
      wait_done(events)
      local item = all_items(events)[1]
      local wrong_client, wrong_error = provider:start({ bufnr = source, method = method, client_ids = { 99 }, params = {} }, function() end)
      local output = { capability = capability.state, clients = capability.clients, first_calls = #first.calls,
        second_calls = #second.calls, result_client = item and item.payload.client_id,
        path = item and item.location.resource.path, wrong_rejected = wrong_client == nil,
        wrong_code = wrong_error and wrong_error.code }
      provider:dispose()
      vim.fn.delete(target)
      return output
    ]])
    expect.equality(result.capability, "ready")
    expect.equality(#result.clients, 1)
    expect.equality(result.clients[1].id, 52)
    expect.equality(result.first_calls, 0)
    expect.equality(result.second_calls, 1)
    expect.equality(result.result_client, 52)
    expect.equality(result.path:find("resolved.lua", 1, true) ~= nil, true)
    expect.equality(result.wrong_rejected, true)
    expect.equality(result.wrong_code, "client_detached")
  end,

  ["null and partial per-client errors remain distinct from empty success"] = function()
    local result = evaluate(fake_helpers .. [[
      local bufnr = source_buffer(vim.fn.tempname() .. '-partial.lua')
      local method = 'textDocument/definition'
      local clients = {
        fake_client(41, bufnr, 'utf-16', supported(method)),
        fake_client(42, bufnr, 'utf-16', supported(method)),
        fake_client(43, bufnr, 'utf-16', supported(method)),
      }
      local provider = make_provider(clients)
      local events = {}
      assert(provider:start({ bufnr = bufnr, method = method }, function(event) events[#events + 1] = event end))
      clients[1].calls[1].handler(nil, nil)
      clients[2].calls[1].handler({ code = -32603, message = 'controlled client failure' }, nil)
      local uri = vim.uri_from_bufnr(bufnr)
      clients[3].calls[1].handler(nil, { { uri = uri, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } } })
      wait_done(events)
      local partial = events[#events]
      local item_count = #all_items(events)
      local empty_events = {}
      assert(provider:start({ bufnr = bufnr, method = method, generation = 2 }, function(event) empty_events[#empty_events + 1] = event end))
      for _, client in ipairs(clients) do client.calls[2].handler(nil, nil) end
      wait_done(empty_events)
      local output = {
        partial = partial.status,
        partial_count = item_count,
        error_code = partial.error.clients[1].code,
        error_client = partial.error.clients[1].client_id,
        null_all_status = empty_events[#empty_events].status,
        null_all_count = empty_events[#empty_events].item_count,
      }
      provider:dispose()
      return output
    ]])
    expect.equality(result.partial, "partial")
    expect.equality(result.partial_count, 1)
    expect.equality(result.error_code, "client_error")
    expect.equality(result.error_client, 42)
    expect.equality(result.null_all_status, "complete")
    expect.equality(result.null_all_count, 0)
  end,

  ["virtual URIs fail closed while valid file results remain partial and usable"] = function()
    local result = evaluate(fake_helpers .. [[
      local bufnr = source_buffer(vim.fn.tempname() .. '-virtual.lua')
      local method = 'textDocument/definition'
      local client = fake_client(51, bufnr, 'utf-16', supported(method))
      local provider = make_provider({ client })
      local events = {}
      assert(provider:start({ bufnr = bufnr, method = method }, function(event) events[#events + 1] = event end))
      local file_uri = vim.uri_from_bufnr(bufnr)
      client.calls[1].handler(nil, {
        { uri = 'jdt://contents/SomeType.class', range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } },
        { uri = file_uri, range = { start = { line = 0, character = 1 }, ['end'] = { line = 0, character = 2 } } },
      })
      wait_done(events)
      local items = all_items(events)
      local done = events[#events]
      local output = {
        status = done.status,
        count = #items,
        scheme = items[1] and items[1].location.resource.scheme,
        error_code = done.error.clients[1].code,
        reason = done.error.clients[1].message,
      }
      provider:dispose()
      return output
    ]])
    expect.equality(result.status, "partial")
    expect.equality(result.count, 1)
    expect.equality(result.scheme, "file")
    expect.equality(result.error_code, "unsupported_uri_scheme")
    expect.equality(result.reason:find("virtual URI scheme", 1, true) ~= nil, true)
  end,

  ["detach and changed document invalidate active work and reject late callbacks"] = function()
    local result = evaluate(fake_helpers .. [[
      local method = 'textDocument/documentSymbol'
      local bufnr = source_buffer(vim.fn.tempname() .. '-detach.lua')
      local client = fake_client(61, bufnr, 'utf-16', supported(method))
      local provider = make_provider({ client })
      local detached_events = {}
      local detached = assert(provider:start({ bufnr = bufnr, method = method, session_id = 'detach' }, function(event) detached_events[#detached_events + 1] = event end))
      vim.api.nvim_exec_autocmds('LspDetach', { buffer = bufnr, data = { client_id = client.id } })
      wait_done(detached_events)
      client.attached_buffers[bufnr] = nil
      client.calls[1].handler(nil, { { name = 'late', kind = 12, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } }, selectionRange = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } } })
      local detached_items = #all_items(detached_events)

      local changed_buf = source_buffer(vim.fn.tempname() .. '-changed.lua')
      client.attached_buffers[changed_buf] = 'lua'
      local changed_events = {}
      local changed = assert(provider:start({ bufnr = changed_buf, method = method, session_id = 'changed' }, function(event) changed_events[#changed_events + 1] = event end))
      vim.api.nvim_buf_set_lines(changed_buf, 0, -1, false, { 'changed while pending' })
      client.calls[2].handler(nil, { { name = 'stale', kind = 12, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } }, selectionRange = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } } })
      wait_done(changed_events)
      local workspace_buf = source_buffer(vim.fn.tempname() .. '-workspace-generation.lua')
      client.attached_buffers[workspace_buf] = 'lua'
      local workspace = { id = 'mutable-workspace', generation = 8 }
      local workspace_events = {}
      local stale_workspace = assert(provider:start({ bufnr = workspace_buf, method = method, workspace = workspace }, function(event) workspace_events[#workspace_events + 1] = event end))
      workspace.generation = 9
      client.calls[3].handler(nil, { { name = 'stale workspace', kind = 12, range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } }, selectionRange = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } } })
      wait_done(workspace_events)
      local output = {
        detached_status = detached_events[#detached_events].status,
        detached_error = detached_events[#detached_events].error and detached_events[#detached_events].error.clients and detached_events[#detached_events].error.clients[1] and detached_events[#detached_events].error.clients[1].code,
        detached_root_error = detached_events[#detached_events].error and detached_events[#detached_events].error.code,
        detached_cancelled = #client.cancelled >= 1,
        detached_items = detached_items,
        detached_handle_active = detached:is_active(),
        changed_status = changed_events[#changed_events].status,
        changed_error = changed_events[#changed_events].error and changed_events[#changed_events].error.code,
        changed_items = #all_items(changed_events),
        changed_handle_active = changed:is_active(),
        workspace_status = workspace_events[#workspace_events].status,
        workspace_error = workspace_events[#workspace_events].error.code,
        workspace_items = #all_items(workspace_events),
        workspace_handle_active = stale_workspace:is_active(),
        active_requests = provider:status().active_requests,
      }
      provider:dispose()
      return output
    ]])
    expect.equality(result.detached_status, "error")
    expect.equality(result.detached_error, "client_detached")
    expect.equality(result.detached_cancelled, true)
    expect.equality(result.detached_items, 0)
    expect.equality(result.detached_handle_active, false)
    expect.equality(result.changed_status, "cancelled")
    expect.equality(result.changed_error, "stale_document")
    expect.equality(result.changed_items, 0)
    expect.equality(result.changed_handle_active, false)
    expect.equality(result.workspace_status, "cancelled")
    expect.equality(result.workspace_error, "stale_workspace")
    expect.equality(result.workspace_items, 0)
    expect.equality(result.workspace_handle_active, false)
    expect.equality(result.active_requests, 0)
  end,

  ["explicit cancellation and provider disposal cancel requests and reject late results"] = function()
    local result = evaluate(fake_helpers .. [[
      local method = 'textDocument/documentSymbol'
      local first = source_buffer(vim.fn.tempname() .. '-cancel.lua')
      local second = source_buffer(vim.fn.tempname() .. '-dispose.lua')
      local client = fake_client(71, first, 'utf-16', supported(method))
      client.attached_buffers[second] = 'lua'
      local provider = make_provider({ client })
      local cancel_events, dispose_events = {}, {}
      local cancelled = assert(provider:start({ bufnr = first, method = method }, function(event) cancel_events[#cancel_events + 1] = event end))
      local cancel_request_id = client.calls[1].request_id
      cancelled:cancel('user_cancel')
      client.calls[1].handler(nil, { { uri = vim.uri_from_bufnr(first) } })
      local disposed = assert(provider:start({ bufnr = second, method = method }, function(event) dispose_events[#dispose_events + 1] = event end))
      local dispose_request_id = client.calls[2].request_id
      provider:dispose()
      client.calls[2].handler(nil, { { uri = vim.uri_from_bufnr(second) } })
      local result = {
        cancel_status = cancel_events[#cancel_events] and cancel_events[#cancel_events].status,
        cancel_error = cancel_events[#cancel_events] and cancel_events[#cancel_events].error.code,
        cancel_id = client.cancelled[1],
        cancel_items = #all_items(cancel_events),
        cancel_active = cancelled:is_active(),
        dispose_status = dispose_events[#dispose_events] and dispose_events[#dispose_events].status,
        dispose_error = dispose_events[#dispose_events] and dispose_events[#dispose_events].error.code,
        dispose_id = client.cancelled[2],
        dispose_items = #all_items(dispose_events),
        dispose_active = disposed:is_active(),
        active_requests = provider:status().active_requests,
        resources = provider:status().resources.resource_count,
      }
      return result
    ]])
    expect.equality(result.cancel_status, "cancelled")
    expect.equality(result.cancel_error, "cancelled")
    expect.equality(result.cancel_id, 1)
    expect.equality(result.cancel_items, 0)
    expect.equality(result.cancel_active, false)
    expect.equality(result.dispose_status, "cancelled")
    expect.equality(result.dispose_error, "provider_disposed")
    expect.equality(result.dispose_id, 2)
    expect.equality(result.dispose_items, 0)
    expect.equality(result.dispose_active, false)
    expect.equality(result.active_requests, 0)
    expect.equality(result.resources, 0)
  end,

  ["a slow client times out independently without erasing a fast client's result"] = function()
    local result = evaluate(fake_helpers .. [[
      local bufnr = source_buffer(vim.fn.tempname() .. '-timeout.lua')
      local method = 'textDocument/definition'
      local fast = fake_client(81, bufnr, 'utf-8', supported(method))
      local slow = fake_client(82, bufnr, 'utf-16', supported(method))
      local provider = make_provider({ fast, slow }, { request_timeout_ms = 20 })
      local events = {}
      assert(provider:start({ bufnr = bufnr, method = method }, function(event) events[#events + 1] = event end))
      fast.calls[1].handler(nil, { { uri = vim.uri_from_bufnr(bufnr), range = { start = { line = 0, character = 1 }, ['end'] = { line = 0, character = 3 } } } })
      wait_done(events)
      local done = events[#events]
      local timeout
      for _, err in ipairs(done.error.clients) do
        if err.client_id == slow.id then timeout = err end
      end
      local count_before_late = #events
      slow.calls[1].handler(nil, { { uri = vim.uri_from_bufnr(bufnr), range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } } } })
      vim.wait(20, function() return #events > count_before_late end, 1)
      local output = {
        status = done.status,
        count = #all_items(events),
        timeout_code = timeout and timeout.code,
        timeout_client = timeout and timeout.client_id,
        timeout_ms = timeout and timeout.timeout_ms,
        cancelled_request = slow.cancelled[1],
        no_late_event = #events == count_before_late,
        active_requests = provider:status().active_requests,
      }
      provider:dispose()
      output.resources = provider:status().resources.resource_count
      return output
    ]])
    expect.equality(result.status, "partial")
    expect.equality(result.count, 1)
    expect.equality(result.timeout_code, "timeout")
    expect.equality(result.timeout_client, 82)
    expect.equality(result.timeout_ms, 20)
    expect.equality(result.cancelled_request, 1)
    expect.equality(result.no_late_event, true)
    expect.equality(result.active_requests, 0)
    expect.equality(result.resources, 0)
  end,

  ["native Neovim LSP client interoperates with the controllable stdio fake server"] = function()
    local result = evaluate([[
      local root, server = ...
      local workspace = vim.fn.tempname() .. '-lsp-provider'
      assert(vim.fn.mkdir(workspace, 'p') == 1)
      local path = workspace .. '/sample.lua'
      vim.fn.writefile({ 'local value = 1' }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      local python = vim.fn.exepath('python3')
      assert(python ~= '', 'python3 is required by the development test environment')
      local client_id = assert(vim.lsp.start({
        name = 'workbench-test-lsp',
        cmd = { python, server },
        root_dir = workspace,
        capabilities = vim.lsp.protocol.make_client_capabilities(),
      }, { bufnr = bufnr }))
      assert(vim.wait(5000, function()
        local client = vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[bufnr]
      end, 10), 'native Neovim LSP client did not initialize and attach')
      local client = assert(vim.lsp.get_client_by_id(client_id))
      local provider = assert(require('workbench.providers.lsp').new())
      local capability = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      local events = {}
      local handle = assert(provider:start({
        bufnr = bufnr,
        method = 'textDocument/documentSymbol',
        params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
        workspace = { id = 'fake-server', generation = 7 },
      }, function(event) events[#events + 1] = event end))
      assert(vim.wait(5000, function() return events[#events] and events[#events].kind == 'done' end, 10), 'native client request did not complete')
      local items = {}
      for _, event in ipairs(events) do
        if event.kind == 'batch' then for _, item in ipairs(event.items) do items[#items + 1] = item end end
      end
      local output = {
        capability = capability.state,
        client_id = client.id,
        encoding = client.offset_encoding,
        status = events[#events].status,
        generation = events[#events].workspace_generation,
        count = #items,
        parent = items[1] and items[1].label,
        child = items[2] and items[2].label,
        parent_link = items[2] and items[2].parent_id == items[1].id,
        item_client = items[1] and items[1].location.client_id,
        item_encoding = items[1] and items[1].location.encoding,
        source_version = items[1] and items[1].location.version,
        buffer_version = vim.api.nvim_buf_get_changedtick(bufnr),
        handle_active = handle:is_active(),
      }
      provider:dispose()
      vim.lsp.stop_client(client_id, true)
      vim.wait(1000, function() return vim.lsp.get_client_by_id(client_id) == nil end, 10)
      output.resources = provider:status().resources.resource_count
      vim.fn.delete(workspace, 'rf')
      return output
    ]], root, root .. "/tests/fixtures/lsp_server.py")
    expect.equality(result.capability, "ready")
    expect.equality(result.client_id > 0, true)
    expect.equality(result.encoding, "utf-16")
    expect.equality(result.status, "complete")
    expect.equality(result.generation, 7)
    expect.equality(result.count, 2)
    expect.equality(result.parent, "FakeRoot")
    expect.equality(result.child, "FakeChild")
    expect.equality(result.parent_link, true)
    expect.equality(result.item_client, result.client_id)
    expect.equality(result.item_encoding, result.encoding)
    expect.equality(result.source_version, result.buffer_version)
    expect.equality(result.handle_active, false)
    expect.equality(result.resources, 0)
  end,

  ["configured Pyright server interoperates when installed"] = function()
    local command = vim.fn.exepath("pyright-langserver")
    if command == "" then MiniTest.skip("pyright-langserver is not installed on this host") end
    local result = evaluate(fake_helpers .. [[
      local command = ...
      local workspace = vim.fn.tempname() .. '-configured-pyright'
      assert(vim.fn.mkdir(workspace, 'p') == 1)
      local path = workspace .. '/sample.py'
      vim.fn.writefile({ 'class ConfiguredAlpha:', '    def configured_method(self) -> int:', '        return 1' }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      local client_id, start_error = vim.lsp.start({
        name = 'workbench-configured-pyright-test',
        cmd = { command, '--stdio' },
        root_dir = workspace,
        capabilities = vim.lsp.protocol.make_client_capabilities(),
      }, { bufnr = bufnr })
      assert(client_id, vim.inspect(start_error))
      assert(vim.wait(20000, function()
        local client = vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[bufnr]
      end, 10), 'configured Pyright server did not initialize and attach')
      local client = assert(vim.lsp.get_client_by_id(client_id))
      local provider = assert(require('workbench.providers.lsp').new())
      local capability = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      assert(capability.state == 'ready', vim.inspect(capability))
      local events = {}
      local handle = assert(provider:start({
        bufnr = bufnr,
        method = 'textDocument/documentSymbol',
        params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
      }, function(event) events[#events + 1] = event end))
      assert(vim.wait(20000, function() return events[#events] and events[#events].kind == 'done' end, 10), 'configured Pyright document-symbol request timed out')
      local items = all_items(events)
      local output = {
        client_name = client.name,
        encoding = client.offset_encoding,
        status = events[#events].status,
        item_count = #items,
        labels = vim.tbl_map(function(item) return item.label end, items),
        source_version = items[1] and items[1].location.version,
        buffer_version = vim.api.nvim_buf_get_changedtick(bufnr),
        handle_active = handle:is_active(),
      }
      provider:dispose()
      vim.lsp.stop_client(client_id, true)
      vim.wait(1000, function() return vim.lsp.get_client_by_id(client_id) == nil end, 10)
      vim.fn.delete(workspace, 'rf')
      return output
    ]], command)
    expect.equality(result.client_name, "workbench-configured-pyright-test")
    expect.equality(result.status, "complete")
    expect.equality(result.item_count > 0, true)
    expect.equality(vim.tbl_contains(result.labels, "ConfiguredAlpha"), true)
    expect.equality(result.source_version, result.buffer_version)
    expect.equality(result.handle_active, false)
  end,

  ["configured TypeScript language server returns real symbols and exact unsupported capability"] = function()
    local command = vim.fn.exepath("typescript-language-server")
    if command == "" then MiniTest.skip("typescript-language-server is not installed on this host") end
    local result = evaluate(fake_helpers .. [[
      local command = ...
      local workspace = vim.fn.tempname() .. '-configured-typescript'
      assert(vim.fn.mkdir(workspace, 'p') == 1)
      assert(vim.fn.writefile({ '{"name":"workbench-discovery-ts","version":"1.0.0"}' }, workspace .. '/package.json') == 0)
      assert(vim.fn.writefile({ '{"compilerOptions":{"target":"ES2020"},"include":["src"]}' }, workspace .. '/tsconfig.json') == 0)
      assert(vim.fn.mkdir(workspace .. '/src', 'p') == 1)
      local path = workspace .. '/src/sample.ts'
      vim.fn.writefile({ 'export class ConfiguredAlpha {', '  configuredMethod(): number { return 1 }', '}' }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      local client_id, start_error = vim.lsp.start({
        name = 'workbench-discovery-typescript-test',
        cmd = { command, '--stdio' },
        root_dir = workspace,
        capabilities = vim.lsp.protocol.make_client_capabilities(),
      }, { bufnr = bufnr })
      assert(client_id, vim.inspect(start_error))
      assert(vim.wait(30000, function()
        local client = vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[bufnr]
      end, 10), 'TypeScript language server did not initialize and attach')
      local client = assert(vim.lsp.get_client_by_id(client_id))
      local provider = assert(require('workbench.providers.lsp').new())
      local capability = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      local unsupported_method, unsupported
      for _, method in ipairs({ 'textDocument/linkedEditingRange', 'textDocument/codeLens', 'textDocument/documentLink', 'textDocument/foldingRange', 'textDocument/moniker', 'textDocument/semanticTokens/full' }) do
        local checked = provider:capabilities({ bufnr = bufnr, method = method })
        if checked.state == 'unavailable' then unsupported_method, unsupported = method, checked; break end
      end
      assert(unsupported, 'TypeScript server unexpectedly advertised every capability probe')
      assert(capability.state == 'ready', vim.inspect(capability))
      local events = {}
      local handle = assert(provider:start({ bufnr = bufnr, method = 'textDocument/documentSymbol',
        params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } } }, function(event) events[#events + 1] = event end))
      assert(vim.wait(30000, function() return events[#events] and events[#events].kind == 'done' end, 10), 'TypeScript document-symbol request timed out')
      local items = all_items(events)
      local output = { client_name = client.name, encoding = client.offset_encoding, status = events[#events].status,
        item_count = #items, labels = vim.tbl_map(function(item) return item.label end, items),
        unsupported = unsupported, unsupported_method = unsupported_method, handle_active = handle:is_active() }
      provider:dispose()
      vim.lsp.stop_client(client_id, true)
      vim.wait(1000, function() return vim.lsp.get_client_by_id(client_id) == nil end, 10)
      vim.fn.delete(workspace, 'rf')
      return output
    ]], command)
    expect.equality(result.client_name, "workbench-discovery-typescript-test")
    expect.equality(result.status, "complete")
    expect.equality(result.item_count > 0, true)
    expect.equality(vim.tbl_contains(result.labels, "ConfiguredAlpha"), true)
    expect.equality(result.unsupported.state, "unavailable")
    expect.equality(result.unsupported.code, "unsupported_method")
    expect.equality(result.unsupported.reason, "attached language servers do not support " .. result.unsupported_method)
    expect.equality(result.handle_active, false)
  end,

  ["configured rust-analyzer returns real symbols and exact unsupported capability"] = function()
    local command = vim.fn.exepath("rust-analyzer")
    if command == "" then MiniTest.skip("rust-analyzer is not installed on this host") end
    local result = evaluate(fake_helpers .. [[
      local command = ...
      local workspace = vim.fn.tempname() .. '-configured-rust'
      assert(vim.fn.mkdir(workspace, 'p') == 1)
      assert(vim.fn.mkdir(workspace .. '/src', 'p') == 1)
      assert(vim.fn.writefile({ '[package]', 'name = "workbench_discovery_rust"', 'version = "0.1.0"', 'edition = "2021"' }, workspace .. '/Cargo.toml') == 0)
      local path = workspace .. '/src/lib.rs'
      vim.fn.writefile({ 'pub struct ConfiguredAlpha;', 'pub fn configured_alpha() -> i32 { 1 }' }, path)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      local client_id, start_error = vim.lsp.start({
        name = 'workbench-discovery-rust-analyzer-test',
        cmd = { command },
        root_dir = workspace,
        capabilities = vim.lsp.protocol.make_client_capabilities(),
        settings = { ['rust-analyzer'] = { cargo = { allFeatures = false } } },
      }, { bufnr = bufnr })
      assert(client_id, vim.inspect(start_error))
      assert(vim.wait(45000, function()
        local client = vim.lsp.get_client_by_id(client_id)
        return client and client.initialized and client.attached_buffers[bufnr]
      end, 10), 'rust-analyzer did not initialize and attach')
      local client = assert(vim.lsp.get_client_by_id(client_id))
      local provider = assert(require('workbench.providers.lsp').new())
      local capability = provider:capabilities({ bufnr = bufnr, method = 'textDocument/documentSymbol' })
      local unsupported_method, unsupported
      for _, method in ipairs({ 'textDocument/linkedEditingRange', 'textDocument/codeLens', 'textDocument/documentLink', 'textDocument/foldingRange', 'textDocument/moniker', 'textDocument/semanticTokens/full' }) do
        local checked = provider:capabilities({ bufnr = bufnr, method = method })
        if checked.state == 'unavailable' then unsupported_method, unsupported = method, checked; break end
      end
      assert(unsupported, 'rust-analyzer unexpectedly advertised every capability probe')
      assert(capability.state == 'ready', vim.inspect(capability))
      local events = {}
      local handle = assert(provider:start({ bufnr = bufnr, method = 'textDocument/documentSymbol',
        params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } } }, function(event) events[#events + 1] = event end))
      assert(vim.wait(45000, function() return events[#events] and events[#events].kind == 'done' end, 10), 'rust-analyzer document-symbol request timed out')
      local items = all_items(events)
      local output = { client_name = client.name, encoding = client.offset_encoding, status = events[#events].status,
        item_count = #items, labels = vim.tbl_map(function(item) return item.label end, items),
        unsupported = unsupported, unsupported_method = unsupported_method, handle_active = handle:is_active() }
      provider:dispose()
      vim.lsp.stop_client(client_id, true)
      vim.wait(1000, function() return vim.lsp.get_client_by_id(client_id) == nil end, 10)
      vim.fn.delete(workspace, 'rf')
      return output
    ]], command)
    expect.equality(result.client_name, "workbench-discovery-rust-analyzer-test")
    expect.equality(result.status, "complete")
    expect.equality(result.item_count > 0, true)
    expect.equality(vim.tbl_contains(result.labels, "ConfiguredAlpha"), true)
    expect.equality(result.unsupported.state, "unavailable")
    expect.equality(result.unsupported.code, "unsupported_method")
    expect.equality(result.unsupported.reason, "attached language servers do not support " .. result.unsupported_method)
    expect.equality(result.handle_active, false)
  end,

  ["call hierarchy preparation and directional edges retain client payload and direction-specific locations"] = function()
    local result = evaluate(fake_helpers .. [[
      local source = vim.fn.tempname() .. '-calls.lua'
      local bufnr = source_buffer(source)
      local methods = {
        ['textDocument/prepareCallHierarchy'] = true,
        ['callHierarchy/incomingCalls'] = true,
        ['callHierarchy/outgoingCalls'] = true,
      }
      local client = fake_client(91, bufnr, 'utf-16', methods)
      local provider = make_provider({ client })
      local function call_item(name, path, start, finish, token)
        return {
          name = name, kind = 12, uri = vim.uri_from_fname(path), detail = 'mod.' .. name,
          range = { start = { line = 0, character = start }, ['end'] = { line = 0, character = finish } },
          selectionRange = { start = { line = 0, character = start + 1 }, ['end'] = { line = 0, character = finish - 1 } },
          data = { token = token },
        }
      end
      local root = call_item('root', source, 0, 8, 'root-data')
      local caller = call_item('caller', source, 0, 8, 'caller-data')
      local callee = call_item('callee', source, 0, 8, 'callee-data')
      local prepared = {}
      assert(provider:start({ bufnr = bufnr, method = 'textDocument/prepareCallHierarchy' }, function(event) prepared[#prepared + 1] = event end))
      client.calls[1].handler(nil, { root })
      wait_done(prepared)
      local prepared_item = all_items(prepared)[1]
      local incoming = {}
      assert(provider:start({ bufnr = bufnr, method = 'callHierarchy/incomingCalls', direction = 'incoming',
        params = { item = root } }, function(event) incoming[#incoming + 1] = event end))
      client.calls[2].handler(nil, { { from = caller, fromRanges = {
        { start = { line = 3, character = 2 }, ['end'] = { line = 3, character = 8 } },
        { start = { line = 6, character = 1 }, ['end'] = { line = 6, character = 7 } },
      } } })
      wait_done(incoming)
      local incoming_item = all_items(incoming)[1]
      local outgoing = {}
      assert(provider:start({ bufnr = bufnr, method = 'callHierarchy/outgoingCalls', direction = 'outgoing',
        params = { item = root } }, function(event) outgoing[#outgoing + 1] = event end))
      client.calls[3].handler(nil, { { to = callee, fromRanges = {
        { start = { line = 1, character = 4 }, ['end'] = { line = 1, character = 10 } },
      } } })
      wait_done(outgoing)
      local outgoing_item = all_items(outgoing)[1]
      local output = {
        prepare_kind = prepared_item.kind,
        prepare_shape = prepared_item.payload.shape,
        prepare_client = prepared_item.payload.client_id,
        prepare_token = prepared_item.payload.call_item.data.token,
        prepare_start = prepared_item.location.range.start.character,
        prepare_encoding = prepared_item.location.encoding,
        incoming_kind = incoming_item.kind,
        incoming_name = incoming_item.label,
        incoming_direction = incoming_item.payload.direction,
        incoming_token = incoming_item.payload.call_item.data.token,
        incoming_range_count = #incoming_item.payload.call_ranges,
        incoming_start = incoming_item.location.range.start.character,
        incoming_finish = incoming_item.location.range.finish.character,
        outgoing_direction = outgoing_item.payload.direction,
        outgoing_name = outgoing_item.label,
        outgoing_token = outgoing_item.payload.call_item.data.token,
        outgoing_start = outgoing_item.location.range.start.character,
        outgoing_ranges_start = outgoing_item.payload.call_ranges[1].start.character,
        statuses = { prepared[#prepared].status, incoming[#incoming].status, outgoing[#outgoing].status },
      }
      provider:dispose()
      output.active = provider:status().active_requests
      return output
    ]])
    expect.equality(result.prepare_kind, "call")
    expect.equality(result.prepare_shape, "call_hierarchy_item")
    expect.equality(result.prepare_client, 91)
    expect.equality(result.prepare_token, "root-data")
    expect.equality(result.prepare_start, 1)
    expect.equality(result.prepare_encoding, "utf-16")
    expect.equality(result.incoming_kind, "call")
    expect.equality(result.incoming_name, "caller")
    expect.equality(result.incoming_direction, "incoming")
    expect.equality(result.incoming_token, "caller-data")
    expect.equality(result.incoming_range_count, 2)
    expect.equality(result.incoming_start, 2)
    expect.equality(result.incoming_finish, 8)
    expect.equality(result.outgoing_direction, "outgoing")
    expect.equality(result.outgoing_name, "callee")
    expect.equality(result.outgoing_token, "callee-data")
    expect.equality(result.outgoing_start, 1)
    expect.equality(result.outgoing_ranges_start, 4)
    expect.equality(result.statuses, { "complete", "complete", "complete" })
    expect.equality(result.active, 0)
  end,
})
