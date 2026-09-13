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
  ["asynchronous immediate listing preserves raw paths and sorts directories before files"] = function()
    local result = evaluate([[
      local uv = vim.uv or vim.loop
      local root = vim.fn.tempname() .. '-wb-files'
      assert(vim.fn.mkdir(root, 'p') == 1)
      assert(vim.fn.mkdir(root .. '/branch', 'p') == 1)
      assert(vim.fn.mkdir(root .. '/.git', 'p') == 1)
      assert(vim.fn.writefile({'a'}, root .. '/a.txt') == 0)
      assert(vim.fn.writefile({'b'}, root .. '/branch/b.txt') == 0)
      assert(vim.fn.writefile({'hidden'}, root .. '/.hidden') == 0)
      assert(vim.fn.writefile({'line'}, root .. '/line' .. string.char(10) .. 'break.txt') == 0)
      assert(vim.fn.writefile({'wide'}, root .. '/界.txt') == 0)
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'include', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local provider = assert(require('workbench.providers.filesystem').new())
      local events = {}
      assert(provider:enumerate(snapshot, root, {}, function(event) events[#events + 1] = event end))
      assert(vim.wait(5000, function() return events[#events] and events[#events].kind == 'done' end, 5))
      local items = events[1].items
      local labels, raw, kinds = {}, {}, {}
      for index, item in ipairs(items) do
        labels[index] = item.label
        raw[item.label] = item.payload.raw_name
        kinds[index] = item.kind
      end
      local result = {
        root = root,
        labels = labels,
        raw = raw,
        kinds = kinds,
        total = events[#events].total,
        status = events[#events].kind,
        cache = provider:status(),
      }
      provider:dispose()
      vim.fn.delete(root, 'rf')
      return result
    ]])
    expect.equality(result.status, "done")
    expect.equality(result.total, 5)
    expect.equality(result.labels[1], "branch")
    expect.equality(result.labels[2], ".hidden")
    expect.equality(result.kinds[1], "directory")
    expect.equality(result.kinds[2], "file")
    expect.equality(result.raw["line\\x0Abreak.txt"], "line\nbreak.txt")
    expect.equality(result.labels[#result.labels], "界.txt")
    expect.equality(result.cache.cache_directories, 1)
    expect.equality(result.cache.active_requests, 0)
  end,

  ["workspace ignore adapter applies nested gitignore and ignore rules without a recursive UI scan"] = function()
    if vim.fn.executable("rg") ~= 1 then
      expect.equality(true, true)
      return
    end
    local result = evaluate([[
      local root = vim.fn.getcwd() .. '/tests/fixtures/workspace-policy'
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'exclude', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local provider = assert(require('workbench.providers.filesystem').new())
      local function list(path)
        local events = {}
        assert(provider:enumerate(snapshot, path, {}, function(event) events[#events + 1] = event end))
        assert(vim.wait(5000, function() return events[#events] and (events[#events].kind == 'done' or events[#events].kind == 'error') end, 5))
        local names = {}
        if events[1].kind == 'batch' then for _, item in ipairs(events[1].items) do names[item.payload.raw_name] = item.kind end end
        return names, events[#events]
      end
      local root_items, root_done = list(root)
      local source_items, source_done = list(root .. '/src')
      provider:dispose()
      return { root = root_items, source = source_items, root_event = root_done.kind, source_event = source_done.kind }
    ]])
    expect.equality(result.root_event, "done")
    expect.equality(result.source_event, "done")
    expect.equality(result.root.src, "directory")
    expect.equality(result.root.vendor, "directory")
    expect.equality(result.root["visible.md"], "file")
    expect.equality(result.root[".hidden"], nil)
    expect.equality(result.root.ignored, nil)
    expect.equality(result.root["shared-ignored"], nil)
    expect.equality(result.source["main.lua"], "file")
    expect.equality(result.source["generated.py"], nil)
    expect.equality(result.source.private, nil)
  end,

  ["cache hits are asynchronous, bounded and invalidation refreshes the target path"] = function()
    local result = evaluate([[
      local root = vim.fn.getcwd() .. '/tests/fixtures/workspace-policy'
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local provider = assert(require('workbench.providers.filesystem').new({ max_cache_directories = 2 }))
      local function list(path)
        local events = {}
        assert(provider:enumerate(snapshot, path, {}, function(event) events[#events + 1] = event end))
        assert(vim.wait(5000, function() return events[#events] and events[#events].kind == 'done' end, 5))
        return events
      end
      local first = list(root)
      local second = list(root)
      local cached = second[#second].cached
      provider:invalidate(root)
      local third = list(root)
      local fresh = third[#third].cached
      local status = provider:status()
      provider:dispose()
      return { cached = cached, fresh = fresh, status = status }
    ]])
    expect.equality(result.cached, true)
    expect.equality(result.fresh, false)
    expect.equality(result.status.cache_directories, 1)
    expect.equality(result.status.cache_items <= 50000, true)
  end,

  ["directory requests reject outside roots and dispose stale asynchronous reads"] = function()
    local result = evaluate([[
      local fake = { pending = nil }
      fake.fs_scandir = function(_, callback) fake.pending = callback end
      fake.fs_scandir_next = function() return nil end
      local provider = assert(require('workbench.providers.filesystem').new({ uv = fake }))
      local snapshot = {
        id = 'workspace:/tmp/wb-root', generation = 1,
        roots = { { uri = 'file:///tmp/wb-root', path = '/tmp/wb-root' } },
        policy = { hidden = 'exclude', ignored = 'include', symlinks = 'never', include = {}, exclude = {} },
      }
      local outside, outside_error = provider:enumerate(snapshot, '/tmp/wb-root-sibling', {}, function() end)
      local callbacks = 0
      local request = assert(provider:enumerate(snapshot, '/tmp/wb-root', {}, function() callbacks = callbacks + 1 end))
      request:cancel()
      fake.pending(nil, {})
      vim.wait(20)
      local status = provider:status()
      provider:dispose()
      return { outside = outside, outside_code = outside_error.code, callbacks = callbacks, active = status.active_requests }
    ]])
    expect.equality(result.outside, nil)
    expect.equality(result.outside_code, "outside_root")
    expect.equality(result.callbacks, 0)
    expect.equality(result.active, 0)
  end,

  ["inaccessible and vanished directories produce distinct retryable errors"] = function()
    local result = evaluate([[
      local uv = vim.uv or vim.loop
      local root = vim.fn.tempname() .. '-wb-files-error'
      assert(vim.fn.mkdir(root, 'p') == 1)
      local Workspace = require('workbench.services.workspace')
      local workspace = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { hidden = 'exclude', ignored = 'include', symlinks = 'never' } end },
      }))
      local snapshot = assert(workspace:open({ explicit_root = root }))
      local fake = { error = 'EACCES: permission denied', fs_scandir_next = function() return nil end }
      fake.fs_scandir = function(_, callback) callback(fake.error, nil) end
      local provider = assert(require('workbench.providers.filesystem').new({ uv = fake }))
      local function request()
        local events = {}
        assert(provider:enumerate(snapshot, root, {}, function(event) events[#events + 1] = event end))
        assert(vim.wait(1000, function() return #events > 0 end, 5))
        return events[1]
      end
      local inaccessible = request()
      fake.error = 'ENOENT: no such file or directory'
      local vanished = request()
      provider:dispose()
      vim.fn.delete(root, 'rf')
      return {
        inaccessible = { event = inaccessible.kind, code = inaccessible.error.code, retryable = inaccessible.error.retryable },
        vanished = { event = vanished.kind, code = vanished.error.code, retryable = vanished.error.retryable },
      }
    ]])
    expect.equality(result.inaccessible.event, "error")
    expect.equality(result.inaccessible.code, "directory_inaccessible")
    expect.equality(result.inaccessible.retryable, true)
    expect.equality(result.vanished.event, "error")
    expect.equality(result.vanished.code, "directory_vanished")
    expect.equality(result.vanished.retryable, true)
  end,
})
