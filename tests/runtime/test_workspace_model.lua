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
      if child then
        pcall(child.stop)
        child = nil
      end
    end,
  },
}, {
  ["file resources round-trip escaped paths and keep terminal labels safe"] = function()
    local result = evaluate([[
      local resource = require('workbench.core.resource')
      local path = '/tmp/wb root/a:b' .. string.char(10) .. 'c.txt'
      local item = assert(resource.from_path(path))
      local decoded = assert(resource.from_uri(item.uri))
      local raw_byte = assert(resource.from_path('/tmp/raw-' .. string.char(255) .. '.txt'))
      return { item = item, decoded = decoded, raw_byte = raw_byte }
    ]])
    expect.equality(result.decoded.path, "/tmp/wb root/a:b\nc.txt")
    expect.equality(result.decoded.uri, result.item.uri)
    expect.equality(result.item.display_path, "/tmp/wb root/a\\:b\\x0Ac.txt")
    expect.equality(result.item.uri:find("%%20") ~= nil, true)
    expect.equality(result.item.uri:find("%%0a") ~= nil, true)
    expect.equality(result.item.workspace_id, nil)
    expect.equality(result.raw_byte.display_path, "/tmp/raw-\\xFF.txt")
    expect.equality(result.raw_byte.uri:find("%%ff%.txt$") ~= nil, true)
  end,

  ["non-file URI remains a virtual resource without a native path"] = function()
    local result = evaluate([[
      local resource = require('workbench.core.resource')
      return assert(resource.from_uri('untitled:buffer-1'))
    ]])
    expect.equality(result.scheme, "untitled")
    expect.equality(result.path, nil)
    expect.equality(result.uri, "untitled:buffer-1")
  end,

  ["locations preserve protocol encoding until target text is supplied"] = function()
    local result = evaluate([[
      local resource = assert(require('workbench.core.resource').from_path('/tmp/coords.txt'))
      local location = require('workbench.core.location')
      local text = 'A😀é界\tZ\r'
      local original = assert(location.new(resource, {
        range = { start = { line = 0, character = 3 }, finish = { line = 0, character = 5 } },
        encoding = 'utf-16', version = 7, client_id = 12,
      }))
      local utf16 = assert(location.resolve_range(original, { text }))
      local utf32 = assert(location.resolve_range(assert(location.new(resource, {
        range = { start = { line = 0, character = 2 }, finish = { line = 0, character = 4 } },
        encoding = 'utf-32',
      })), { text }))
      local utf8 = assert(location.resolve_range(assert(location.new(resource, {
        range = { start = { line = 5, character = 1 }, finish = { line = 5, character = 4 } },
        encoding = 'utf-8',
      })), { '', '', '', '', '', '\t界\r' }))
      local split = location.resolve_range(assert(location.new(resource, {
        range = { start = { line = 0, character = 2 }, finish = { line = 0, character = 3 } },
        encoding = 'utf-16',
      })), { text })
      local bytesplit = location.resolve_range(assert(location.new(resource, {
        range = { start = { line = 0, character = 2 }, finish = { line = 0, character = 5 } },
        encoding = 'utf-8',
      })), { text })
      local absent = location.resolve_range(original, nil)
      return {
        original = original,
        utf16 = utf16,
        utf32 = utf32,
        utf8 = utf8,
        split = split,
        bytesplit = bytesplit,
        absent = absent,
      }
    ]])
    expect.equality(result.original.range.start.character, 3)
    expect.equality(result.original.encoding, "utf-16")
    expect.equality(result.original.version, 7)
    expect.equality(result.original.client_id, 12)
    expect.equality(result.utf16.start.character, 5)
    expect.equality(result.utf16.finish.character, 8)
    expect.equality(result.utf32.start.character, 5)
    expect.equality(result.utf32.finish.character, 8)
    expect.equality(result.utf8.start.character, 1)
    expect.equality(result.utf8.finish.character, 4)
    expect.equality(result.split, nil)
    expect.equality(result.bytesplit, nil)
    expect.equality(result.absent, nil)
  end,

  ["malformed resources, ranges and policy values fail with actionable reasons"] = function()
    local result = evaluate([[
      local resource = require('workbench.core.resource')
      local location = require('workbench.core.location')
      local root = assert(resource.from_path('/repo'))
      local relative, relative_error = resource.from_path('relative.lua')
      local missing_encoding, encoding_error = location.new(root, {
        range = { start = { line = 0, character = 0 }, finish = { line = 0, character = 1 } },
      })
      local reversed, reversed_error = location.new(root, {
        range = { start = { line = 2, character = 0 }, finish = { line = 1, character = 0 } },
        encoding = 'utf-8',
      })
      local service = assert(require('workbench.services.workspace').new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return { symlinks = 'magic' } end },
      }))
      local invalid_policy, policy_error = service:open({ explicit_root = '/repo' })
      return {
        relative = relative,
        relative_error = relative_error,
        missing_encoding = missing_encoding,
        encoding_error = encoding_error,
        reversed = reversed,
        reversed_error = reversed_error,
        invalid_policy = invalid_policy,
        policy_error = policy_error,
        generation = service.generation,
      }
    ]])
    expect.equality(result.relative, nil)
    expect.equality(result.relative_error:find("absolute") ~= nil, true)
    expect.equality(result.missing_encoding, nil)
    expect.equality(result.encoding_error:find("encoding") ~= nil, true)
    expect.equality(result.reversed, nil)
    expect.equality(result.reversed_error:find("precedes") ~= nil, true)
    expect.equality(result.invalid_policy, nil)
    expect.equality(result.policy_error:find("policy") ~= nil, true)
    expect.equality(result.generation, 0)
  end,

  ["root selection respects precedence, nested repositories and display aliases"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local adapter = {
        canonical_calls = 0,
        cwd_calls = 0,
        canonicalize = function(self, path)
          self.canonical_calls = self.canonical_calls + 1
          return ({ ['/alias/project'] = '/physical/project' })[path] or path
        end,
        nearest_git_root = function(_, path)
          if path:find('/submodule/', 1, true) then return '/repo/submodule' end
          if path:find('/repo/', 1, true) then return '/repo' end
        end,
        nearest_marker_root = function() return '/marker' end,
        cwd = function(self) self.cwd_calls = self.cwd_calls + 1; return '/ambient/cwd' end,
      }
      local ignore = { snapshot = function() return { hidden = 'exclude', ignored = 'include' } end }
      local service = assert(Workspace.new({ root_service = adapter, ignore_service = ignore }))
      local alias = assert(service:open({ explicit_root = '/alias/project' }))
      local nested = assert(service:open({ initial_file = '/repo/submodule/file.lua', launch_cwd = '/elsewhere' }))
      local parent = assert(service:open({ initial_file = '/repo/src/file.lua', launch_cwd = '/elsewhere' }))
      return {
        alias = alias,
        nested = nested,
        parent = parent,
        canonical_calls = adapter.canonical_calls,
        cwd_calls = adapter.cwd_calls,
      }
    ]])
    expect.equality(result.alias.roots[1].path, "/physical/project")
    expect.equality(result.alias.roots[1].display_path, "/alias/project")
    expect.equality(result.alias.root_origin, "explicit")
    expect.equality(result.nested.roots[1].path, "/repo/submodule")
    expect.equality(result.nested.root_origin, "git")
    expect.equality(result.parent.roots[1].path, "/repo")
    expect.equality(result.parent.root_origin, "git")
    expect.equality(result.cwd_calls, 0)
    expect.equality(result.canonical_calls, 3)
  end,

  ["a selected submodule folder is scope, not an implicit workspace replacement"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local adapter = {
        canonicalize = function(_, path) return path end,
        nearest_git_root = function() return '/repo' end,
      }
      local ignore = { snapshot = function() return {} end }
      local service = assert(Workspace.new({ root_service = adapter, ignore_service = ignore }))
      return assert(service:open({
        initial_file = '/repo/submodule/src/a.lua',
        scope = { kind = 'folder', path = '/repo/submodule' },
      }))
    ]])
    expect.equality(result.roots[1].path, "/repo")
    expect.equality(result.scope.resource.path, "/repo/submodule")
  end,

  ["marker and injected launch cwd are ordered root fallbacks"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local adapter = {
        cwd_calls = 0,
        canonicalize = function(_, path) return path end,
        nearest_git_root = function() return nil end,
        nearest_marker_root = function(_, path, markers)
          assert(path == '/project/src/main.lua')
          assert(markers[1] == 'Cargo.toml')
          return '/project'
        end,
        cwd = function(self) self.cwd_calls = self.cwd_calls + 1; return '/launch-here' end,
      }
      local service = assert(Workspace.new({
        root_service = adapter,
        ignore_service = { snapshot = function() return {} end },
      }))
      local marked = assert(service:open({
        initial_file = '/project/src/main.lua',
        markers = { 'Cargo.toml' },
      }))
      local launched = assert(service:open({}))
      return { marked = marked, launched = launched, cwd_calls = adapter.cwd_calls }
    ]])
    expect.equality(result.marked.roots[1].path, "/project")
    expect.equality(result.marked.root_origin, "marker")
    expect.equality(result.launched.roots[1].path, "/launch-here")
    expect.equality(result.launched.root_origin, "cwd")
    expect.equality(result.cwd_calls, 1)
  end,

  ["snapshots share stable generations until refresh and remain isolated copies"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local fixture = require('fixtures.policy')
      local adapter = {
        cwd_calls = 0,
        canonical_calls = 0,
        canonicalize = function(self, path)
          self.canonical_calls = self.canonical_calls + 1
          return path
        end,
        cwd = function(self) self.cwd_calls = self.cwd_calls + 1; return '/launch' end,
      }
      local ignore = { snapshot = function() return vim.deepcopy(fixture.policy) end }
      local service = assert(Workspace.new({ root_service = adapter, ignore_service = ignore }))
      local first = assert(service:open({ launch_cwd = '/workspace' }))
      local attached = assert(service:open({ launch_cwd = '/workspace' }))
      local consumer_a, consumer_b = service:snapshot(), service:snapshot()
      local equal_before = vim.deep_equal(consumer_a, consumer_b)
      consumer_a.roots[1].path = '/corrupted'
      consumer_a.policy.include[1] = 'corrupted'
      local isolated = consumer_b.roots[1].path == '/workspace'
        and consumer_b.policy.include[1] == fixture.policy.include[1]
      local canonical_before_refresh = adapter.canonical_calls
      local second = assert(service:refresh(first.id))
      return {
        first = first,
        attached = attached,
        consumer_b = consumer_b,
        equal_before = equal_before,
        isolated = isolated,
        second = second,
        current = service:is_current(first),
        new_current = service:is_current(second),
        generation = second.generation,
        cwd_calls = adapter.cwd_calls,
        canonical_before_refresh = canonical_before_refresh,
        canonical_calls = adapter.canonical_calls,
      }
    ]])
    expect.equality(result.equal_before, true)
    expect.equality(result.isolated, true)
    expect.equality(result.consumer_b.roots[1].path, "/workspace")
    expect.equality(result.attached.generation, result.first.generation)
    expect.equality(result.current, false)
    expect.equality(result.new_current, true)
    expect.equality(result.generation, result.first.generation + 1)
    expect.equality(result.cwd_calls, 0)
    expect.equality(result.canonical_before_refresh, 1)
    expect.equality(result.canonical_calls, 2)
  end,

  ["shared file and search consumers receive identical explicit policy data"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local fixture = require('fixtures.policy')
      local fixture_root = ...
      local fixture_files_exist = true
      for _, entry in ipairs(fixture.entries) do
        fixture_files_exist = fixture_files_exist and vim.uv.fs_stat(fixture_root .. '/' .. entry.path) ~= nil
      end
      for _, path in ipairs(fixture.ignore_files) do
        fixture_files_exist = fixture_files_exist and vim.uv.fs_stat(fixture_root .. '/' .. path) ~= nil
      end
      local service = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return vim.deepcopy(fixture.policy) end },
      }))
      local files_snapshot = service:open({ explicit_root = '/policy-fixture' })
      local search_snapshot = service:snapshot()
      return {
        name = fixture.name,
        expected = fixture.expectations,
        fixture_entries = #fixture.entries,
        fixture_files_exist = fixture_files_exist,
        equal_policy = vim.deep_equal(files_snapshot.policy, search_snapshot.policy),
        policy = files_snapshot.policy,
      }
    ]], root .. "/tests/fixtures/workspace-policy")
    expect.equality(result.name, "shared-workspace-file-search-policy-v1")
    expect.equality(result.equal_policy, true)
    expect.equality(result.policy.hidden, "exclude")
    expect.equality(result.policy.ignored, "include")
    expect.equality(result.policy.symlinks, "internal")
    expect.equality(result.expected.external_symlink, false)
    expect.equality(result.fixture_entries, 8)
    expect.equality(result.fixture_files_exist, true)
  end,

  ["path containment is component-aware and followed symlink visits detect cycles"] = function()
    local result = evaluate([[
      local policy = require('workbench.core.root_policy')
      local contains_repo = policy.contains('/repo', '/repo/src/a.lua')
      local contains_prefix_sibling = policy.contains('/repo', '/repo2/a.lua')
      local lexical = assert(policy.directory_visit('/repo', '/repo/link', {}, {
        follow_symlinks = false,
        realpath = function() error('must not resolve when following is disabled') end,
      }))
      local cycle = assert(policy.directory_visit('/physical/repo', '/repo/back', {
        ['/physical/repo'] = true,
      }, {
        follow_symlinks = true,
        realpath = function() return '/physical/repo' end,
      }))
      local external = assert(policy.directory_visit('/physical/repo', '/repo/out', {}, {
        follow_symlinks = true,
        realpath = function() return '/outside/target' end,
      }))
      return {
        contains_repo = contains_repo,
        contains_prefix_sibling = contains_prefix_sibling,
        lexical = lexical,
        cycle = cycle,
        external = external,
      }
    ]])
    expect.equality(result.contains_repo, true)
    expect.equality(result.contains_prefix_sibling, false)
    expect.equality(result.lexical.identity, "/repo/link")
    expect.equality(result.lexical.follow, false)
    expect.equality(result.cycle.cycle, true)
    expect.equality(result.external.external, true)
  end,

  ["multi-root snapshots retain order but execution reports the single-root limit"] = function()
    local result = evaluate([[
      local resource = require('workbench.core.resource')
      local workspace = require('workbench.core.workspace')
      local roots = {
        assert(resource.from_path('/one')),
        assert(resource.from_path('/two')),
      }
      local snapshot = assert(workspace.new({
        id = workspace.id_for_roots(roots),
        generation = 1,
        roots = roots,
        active_root_uri = roots[1].uri,
        root_origin = 'explicit',
        scope = { kind = 'all_roots', explicit = true },
        policy = {},
      }))
      return {
        first = snapshot.roots[1].path,
        second = snapshot.roots[2].path,
        capability = workspace.execution_capability(snapshot, 'search'),
      }
    ]])
    expect.equality(result.first, "/one")
    expect.equality(result.second, "/two")
    expect.equality(result.capability.state, "unsupported")
    expect.equality(result.capability.reason, "multi_root_execution_not_implemented")
  end,

  ["workspace resource identities preserve path case"] = function()
    local result = evaluate([[
      local resource = require('workbench.core.resource')
      local workspace = require('workbench.core.workspace')
      local upper = assert(resource.from_path('/Repo'))
      local lower = assert(resource.from_path('/repo'))
      return {
        upper_path = upper.path,
        lower_path = lower.path,
        upper_id = workspace.id_for_roots({ upper }),
        lower_id = workspace.id_for_roots({ lower }),
      }
    ]])
    expect.equality(result.upper_path, "/Repo")
    expect.equality(result.lower_path, "/repo")
    expect.no_equality(result.upper_id, result.lower_id)
  end,

  ["failed root refresh does not replace the last valid generation"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local adapter = {
        missing = false,
        canonicalize = function(self, path)
          if self.missing then return nil, 'root vanished' end
          return path
        end,
      }
      local service = assert(Workspace.new({
        root_service = adapter,
        ignore_service = { snapshot = function() return {} end },
      }))
      local before = assert(service:open({ explicit_root = '/stable' }))
      adapter.missing = true
      local failed = service:refresh()
      local current = service:snapshot()
      return {
        failed = failed,
        current = current,
        still_current = service:is_current(before),
        generation = service.generation,
      }
    ]])
    expect.equality(result.failed, nil)
    expect.equality(result.current.roots[1].path, "/stable")
    expect.equality(result.still_current, true)
    expect.equality(result.generation, 1)
  end,

  ["refreshing a symlink alias to a new canonical root invalidates the old identity"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local adapter = {
        target = '/physical/one',
        canonicalize = function(self) return self.target end,
      }
      local service = assert(Workspace.new({
        root_service = adapter,
        ignore_service = { snapshot = function() return {} end },
      }))
      local before = assert(service:open({ explicit_root = '/alias/project' }))
      adapter.target = '/physical/two'
      local after = assert(service:refresh(before.id))
      return {
        before = before,
        after = after,
        old_current = service:is_current(before),
        old_snapshot = service:snapshot(before.id),
        new_current = service:is_current(after),
        active = service:snapshot().id,
      }
    ]])
    expect.no_equality(result.before.id, result.after.id)
    expect.equality(result.before.roots[1].display_path, "/alias/project")
    expect.equality(result.after.roots[1].path, "/physical/two")
    expect.equality(result.after.roots[1].display_path, "/alias/project")
    expect.equality(result.old_current, false)
    expect.equality(result.old_snapshot, nil)
    expect.equality(result.new_current, true)
    expect.equality(result.active, result.after.id)
  end,

  ["separate tab workspaces remain independently current"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local service = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return {} end },
      }))
      local first = assert(service:open({ explicit_root = '/tab-one' }))
      local second = assert(service:open({ explicit_root = '/tab-two' }))
      local second_active = service:snapshot()
      assert(service:activate(first.id))
      return {
        first_current = service:is_current(first),
        second_current = service:is_current(second),
        second_active = second_active.roots[1].path,
        activated = service:snapshot().roots[1].path,
        first_again = service:snapshot(first.id),
      }
    ]])
    expect.equality(result.first_current, true)
    expect.equality(result.second_current, true)
    expect.equality(result.second_active, "/tab-two")
    expect.equality(result.activated, "/tab-one")
    expect.equality(result.first_again.roots[1].path, "/tab-one")
  end,

  ["repeated workspace open and removal leaves no retained workspace records"] = function()
    local result = evaluate([[
      local Workspace = require('workbench.services.workspace')
      local service = assert(Workspace.new({
        root_service = { canonicalize = function(_, path) return path end },
        ignore_service = { snapshot = function() return {} end },
      }))
      local previous
      for index = 1, 100 do
        local snapshot = assert(service:open({ explicit_root = '/cycle-' .. index }))
        assert(service:remove(snapshot.id))
        assert(not service:is_current(snapshot))
        assert(not service:remove(snapshot.id))
        previous = snapshot
      end
      return {
        active = service:snapshot(),
        records = vim.tbl_count(service.workspaces),
        generation = service.generation,
        previous_current = service:is_current(previous),
      }
    ]])
    expect.equality(result.active, nil)
    expect.equality(result.records, 0)
    expect.equality(result.generation, 100)
    expect.equality(result.previous_current, false)
  end,
})
