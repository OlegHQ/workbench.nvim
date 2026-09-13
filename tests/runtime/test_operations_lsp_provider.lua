local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  return child.lua(source, { ... })
end

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua([[local repo_root, test_root = ...; vim.opt.runtimepath:prepend(repo_root); vim.opt.runtimepath:append(test_root)]], { root, root .. "/tests" })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["willRename uses registered file filters encoding and didRename only after preparation"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-lsp-operation-success'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, target = root .. '/rename-source.lua', root .. '/rename-target.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(bufnr, source)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'source' })
      vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
      local filter = { scheme = 'file', pattern = { glob = '**/*.LUA', matches = 'file', options = { ignoreCase = true } } }
      local calls = {}
      local client = { id = 41, name = 'file-ops', offset_encoding = 'utf-8', calls = calls,
        server_capabilities = { workspace = { fileOperations = { willRename = { filters = { filter } }, didRename = { filters = { filter } } } } } }
      function client:supports_method(method, buffer) return buffer == bufnr and (method == 'workspace/willRenameFiles' or method == 'workspace/didRenameFiles') end
      function client:request(method, params, handler, buffer)
        calls[#calls + 1] = { method = method, params = params, handler = handler, buffer = buffer }
        return true, 900 + #calls
      end
      function client:cancel_request(id) self.cancelled = id; return true end
      function client:notify(method, params, buffer)
        self.notification = { method = method, params = params, buffer = buffer }
        return true
      end
      local provider = assert(require('workbench.providers.lsp').new({ get_all_clients = function() return { client } end }))
      local prepared, prepare_error
      local handle = assert(provider:prepare_file_rename(source, target, bufnr, function(value, err) prepared, prepare_error = value, err end))
      local request = calls[1]
      local params_ok = request and request.method == 'workspace/willRenameFiles'
        and request.params.files[1].oldUri == vim.uri_from_fname(source)
        and request.params.files[1].newUri == vim.uri_from_fname(target)
        and request.buffer == bufnr
      local edit = { changes = { [vim.uri_from_fname(source)] = {
        { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 6 } }, newText = 'renamed' },
      } } }
      request.handler(nil, edit)
      local prepared_ok = prepared and not prepare_error and prepared.encoding == 'utf-8'
        and prepared.edit.changes[vim.uri_from_fname(source)][1].newText == 'renamed'
        and prepared.affected_paths[1] == source and #prepared.clients == 1 and handle.active == false
      assert(provider:did_rename_files(source, target, prepared))
      local notified = client.notification and client.notification.method == 'workspace/didRenameFiles'
        and client.notification.params.files[1].oldUri == vim.uri_from_fname(source)
        and client.notification.params.files[1].newUri == vim.uri_from_fname(target)
        and client.notification.buffer == bufnr
      provider:dispose()
      vim.fn.delete(root, 'rf')
      return { params_ok = params_ok, prepared_ok = prepared_ok, notified = notified, resources = provider:status().resources.resource_count }
    ]])
    expect.equality(result.params_ok, true)
    expect.equality(result.prepared_ok, true)
    expect.equality(result.notified, true)
    expect.equality(result.resources, 0)
  end,

  ["file-operation filters suppress unrelated paths and conflicting server edits fail closed"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-lsp-fileop'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, other, target = root .. '/source.lua', root .. '/other.txt', root .. '/target.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      assert(vim.fn.writefile({ 'other' }, other) == 0)
      local source_buffer, other_buffer = vim.api.nvim_create_buf(true, false), vim.api.nvim_create_buf(true, false)
      for buffer, path in pairs({ [source_buffer] = source, [other_buffer] = other }) do
        vim.api.nvim_buf_set_name(buffer, path)
        vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { 'source' })
        vim.api.nvim_set_option_value('modified', false, { buf = buffer })
      end
      local filter = { scheme = 'file', pattern = { glob = '**/*.lua', matches = 'file' } }
      local function make_client(id, text)
        local client = { id = id, name = 'client-' .. id, offset_encoding = 'utf-16', calls = {},
          server_capabilities = { workspace = { fileOperations = { willRename = { filters = { filter } } } } } }
        function client:supports_method(method) return method == 'workspace/willRenameFiles' end
        function client:request(method, params, handler)
          self.calls[#self.calls + 1] = { params = params, handler = handler }
          return true, id * 10 + #self.calls
        end
        function client:cancel_request(request_id) self.cancelled = request_id; return true end
        client.edit = { changes = { [vim.uri_from_fname(other)] = {
          { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } }, newText = text },
        } } }
        return client
      end
      local first, second = make_client(51, 'first'), make_client(52, 'second')
      local clients = { first, second }
      local provider = assert(require('workbench.providers.lsp').new({ get_all_clients = function() return clients end }))
      local filtered, filtered_error
      local filtered_handle = assert(provider:prepare_file_rename(other, root .. '/other.txt', other_buffer, function(value, err) filtered, filtered_error = value, err end))
      local no_request = #first.calls == 0 and #second.calls == 0 and filtered and not filtered_error and #filtered.clients == 0
      local conflict, conflict_error
      assert(provider:prepare_file_rename(source, target, source_buffer, function(value, err) conflict, conflict_error = value, err end))
      first.calls[1].handler(nil, first.edit)
      second.calls[1].handler(nil, second.edit)
      local rejected = not conflict and conflict_error and conflict_error.code == 'lsp_edit_conflict'
      local source_exists = uv.fs_lstat(source) ~= nil
      provider:dispose()
      vim.fn.delete(root, 'rf')
      return { filtered = no_request, filtered_handle_done = filtered_handle.active == false, conflict = rejected,
        no_mutation = uv.fs_lstat(target) == nil, source_exists = source_exists }
    ]])
    expect.equality(result.filtered, true)
    expect.equality(result.filtered_handle_done, true)
    expect.equality(result.conflict, true)
    expect.equality(result.no_mutation, true)
    expect.equality(result.source_exists, true)
  end,

  ["cancelled file-operation requests are cancelled and late server replies are ignored"] = function()
    local result = evaluate([[
      local root = vim.fn.tempname() .. '-wb-lsp-cancel'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(vim.uv.fs_realpath(root))
      local source, target = root .. '/source.lua', root .. '/target.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(bufnr, source)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'source' })
      vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
      local filter = { scheme = 'file', pattern = { glob = '**/*.lua', matches = 'file' } }
      local client = { id = 61, name = 'cancel-client', offset_encoding = 'utf-16',
        server_capabilities = { workspace = { fileOperations = { willRename = { filters = { filter } } } } } }
      function client:supports_method(method, buffer) return method == 'workspace/willRenameFiles' and buffer == bufnr end
      function client:request(method, params, handler) self.handler = handler; return true, 123 end
      function client:cancel_request(id) self.cancelled = id; return true end
      local provider = assert(require('workbench.providers.lsp').new({ get_all_clients = function() return { client } end }))
      local callback_count = 0
      local handle = assert(provider:prepare_file_rename(source, target, bufnr, function() callback_count = callback_count + 1 end))
      assert(handle:cancel())
      client.handler(nil, nil)
      vim.wait(25)
      provider:dispose()
      local status = provider:status()
      vim.fn.delete(root, 'rf')
      return { cancelled = client.cancelled, callbacks = callback_count, active = handle.active, resources = status.resources.resource_count }
    ]])
    expect.equality(result.cancelled, 123)
    expect.equality(result.callbacks, 1)
    expect.equality(result.active, false)
    expect.equality(result.resources, 0)
  end,

  ["resource operations in willRename edits fail closed"] = function()
    local result = evaluate([[
      local root = vim.fn.tempname() .. '-wb-lsp-resource-edit'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(vim.uv.fs_realpath(root))
      local source, target = root .. '/source.lua', root .. '/target.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(bufnr, source)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'source' })
      vim.api.nvim_set_option_value('modified', false, { buf = bufnr })
      local filter = { scheme = 'file', pattern = { glob = '**/*.lua', matches = 'file' } }
      local client = { id = 71, name = 'resource-edit', offset_encoding = 'utf-16',
        server_capabilities = { workspace = { fileOperations = { willRename = { filters = { filter } } } } } }
      function client:supports_method(method) return method == 'workspace/willRenameFiles' end
      function client:request(method, params, handler) self.handler = handler; return true, 171 end
      function client:cancel_request() return true end
      local provider = assert(require('workbench.providers.lsp').new({ get_all_clients = function() return { client } end }))
      local prepared, prepare_error
      assert(provider:prepare_file_rename(source, target, bufnr, function(value, err) prepared, prepare_error = value, err end))
      client.handler(nil, { documentChanges = { { kind = 'create', uri = vim.uri_from_fname(root .. '/unsafe.txt') } } })
      local rejected = prepared == nil and prepare_error and prepare_error.code == 'unsupported_lsp_resource_operation'
      local malformed, malformed_error
      assert(provider:prepare_file_rename(source, target, bufnr, function(value, err) malformed, malformed_error = value, err end))
      client.handler(nil, { changes = 'not-a-map' })
      local malformed_rejected = malformed == nil and malformed_error and malformed_error.code == 'invalid_lsp_workspace_edit'
      local source_exists = vim.uv.fs_lstat(source) ~= nil
      provider:dispose()
      vim.fn.delete(root, 'rf')
      return { rejected = rejected, malformed_rejected = malformed_rejected,
        code = prepare_error and prepare_error.code, message = prepare_error and prepare_error.message,
        got_value = prepared ~= nil, handler = type(client.handler), source_exists = source_exists }
    ]])
    expect.equality(result.rejected, true)
    expect.equality(result.code, "unsupported_lsp_resource_operation")
    expect.equality(result.malformed_rejected, true)
    expect.equality(result.source_exists, true)
  end,
})
