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
  ["scope disposes in reverse order, continues after failures and handles late resources"] = function()
    local result = evaluate([[
      local Scope = require('workbench.core.scope')
      local events = {}
      local scope = Scope.new('test-root')
      scope:defer(function() events[#events + 1] = 'first' end, 'first')
      scope:defer(function() events[#events + 1] = 'throws'; error('cleanup failed') end, 'throws')
      scope:defer(function() events[#events + 1] = 'last' end, 'last')
      local report = scope:dispose()
      local second = scope:dispose()
      local late_count = 0
      local late, late_error = scope:defer(function() late_count = late_count + 1 end, 'late')
      return {
        events = table.concat(events, ','),
        report = report,
        second = second,
        late = late,
        late_error = late_error,
        late_count = late_count,
        inventory = scope:inventory(),
      }
    ]])
    expect.equality(result.events, "last,throws,first")
    expect.equality(result.report.ok, false)
    expect.equality(result.report.error_count, 1)
    expect.equality(result.report.errors[1].label, "throws")
    expect.equality(result.report.disposed_count, 3)
    expect.equality(result.second.already_disposed, true)
    expect.equality(result.second.disposed_count, 3)
    expect.equality(result.late, nil)
    expect.equality(result.late_error.code, "scope_disposed")
    expect.equality(result.late_count, 1)
    expect.equality(result.inventory.resource_count, 0)
  end,

  ["scope disposal can be reentered by owned cleanup without losing remaining disposers"] = function()
    local result = evaluate([[
      local scope = require('workbench.core.scope').new('reentrant')
      local events, nested = {}, nil
      assert(scope:defer(function() events[#events + 1] = 'first' end, 'first'))
      assert(scope:defer(function()
        events[#events + 1] = 'reentrant'
        nested = scope:dispose()
        events[#events + 1] = 'returned'
      end, 'reentrant'))
      local report = scope:dispose()
      return {report=report,nested=nested,events=events,inventory=scope:inventory()}
    ]])
    expect.equality(result.events, { "reentrant", "returned", "first" })
    expect.equality(result.nested.already_disposed, true)
    expect.equality(result.report.ok, true)
    expect.equality(result.report.error_count, 0)
    expect.equality(result.report.disposed_count, 2)
    expect.equality(result.inventory.resource_count, 0)
  end,

  ["child scopes release parent ownership and inventories show live resources"] = function()
    local result = evaluate([[
      local Scope = require('workbench.core.scope')
      local parent = Scope.new('parent')
      local child = assert(parent:child('view:files'))
      local resource = { id = 'timer-1' }
      local owned = assert(child:own(resource, function(value) value.disposed = true end, 'refresh-timer', 'timer'))
      local before = parent:inventory()
      local child_before = child:inventory()
      local child_report = child:dispose()
      local after = parent:inventory()
      local parent_report = parent:dispose()
      return {
        same_resource = owned.id == resource.id,
        disposed = resource.disposed,
        before = before,
        child_before = child_before,
        after = after,
        child_report = child_report,
        parent_report = parent_report,
      }
    ]])
    expect.equality(result.same_resource, true)
    expect.equality(result.disposed, true)
    expect.equality(result.before.resource_count, 1)
    expect.equality(result.before.resources[1].kind, "scope")
    expect.equality(result.child_before.resource_count, 1)
    expect.equality(result.child_before.resources[1].label, "refresh-timer")
    expect.equality(result.child_report.disposed_count, 1)
    expect.equality(result.after.resource_count, 0)
    expect.equality(result.parent_report.disposed_count, 0)
  end,

  ["scheduled callbacks are invalidated on cancellation and scope disposal"] = function()
    local result = evaluate([[
      local Scope = require('workbench.core.scope')
      local scope = Scope.new('scheduled')
      local queue, calls = {}, 0
      local function enqueue(callback) queue[#queue + 1] = callback end
      local cancelled = assert(scope:schedule(function() calls = calls + 10 end, enqueue))
      local first_pending = scope:inventory().pending_callbacks
      cancelled:cancel()
      local after_cancel = scope:inventory().pending_callbacks
      local delayed = assert(scope:schedule(function() calls = calls + 1 end, enqueue))
      local report = scope:dispose()
      local pending_after_dispose = scope:inventory().pending_callbacks
      queue[1]()
      queue[2]()
      return {
        calls = calls,
        first_pending = first_pending,
        after_cancel = after_cancel,
        pending_after_dispose = pending_after_dispose,
        delayed_active = delayed.active,
        queue_count = #queue,
        report = report,
        late_ticket = scope:schedule(function() calls = calls + 100 end, enqueue),
      }
    ]])
    expect.equality(result.first_pending, 1)
    expect.equality(result.after_cancel, 0)
    expect.equality(result.pending_after_dispose, 0)
    expect.equality(result.delayed_active, false)
    expect.equality(result.queue_count, 2)
    expect.equality(result.calls, 0)
    expect.equality(result.report.ok, true)
    expect.equality(result.late_ticket, nil)
  end,

  ["action metadata, schema validation and unavailable reasons stay typed"] = function()
    local result = evaluate([[
      local Actions = require('workbench.core.actions')
      local registry = Actions.new()
      local available_calls, runs = 0, 0
      local handle = assert(registry:register({
        id = 'search.query',
        title = 'Search workspace',
        category = 'Search',
        scope = 'workspace',
        available = function()
          available_calls = available_calls + 1
          return { enabled = false, code = 'missing_dependency', reason = 'ripgrep is not installed' }
        end,
        checked = function() return false end,
        args_schema = {
          type = 'object',
          properties = { query = { type = 'string', min_length = 1 }, case_sensitive = { type = 'boolean' } },
          required = { 'query' },
        },
        run = function() runs = runs + 1 end,
      }))
      local inventory = registry:inventory()
      local calls_after_inventory = available_calls
      local projection = registry:list({})
      local unavailable = registry:execute('search.query', {}, { query = 'needle' })
      local unknown = registry:execute('search.missing', {}, {})
      return {
        handle_active = handle:is_active(),
        inventory = inventory,
        calls_after_inventory = calls_after_inventory,
        projection = projection[1],
        unavailable = unavailable,
        unknown = unknown,
        runs = runs,
        available_calls = available_calls,
      }
    ]])
    expect.equality(result.handle_active, true)
    expect.equality(result.inventory[1], "search.query")
    expect.equality(result.calls_after_inventory, 0)
    expect.equality(result.projection.available.enabled, false)
    expect.equality(result.projection.available.code, "missing_dependency")
    expect.equality(result.projection.available.reason, "ripgrep is not installed")
    expect.equality(result.projection.checked, false)
    expect.equality(result.projection.args_schema.type, "object")
    expect.equality(result.unavailable.ok, false)
    expect.equality(result.unavailable.error.code, "missing_dependency")
    expect.equality(result.unknown.error.code, "unknown_action")
    expect.equality(result.runs, 0)
    expect.equality(result.available_calls, 2)
  end,

  ["action execution validates arguments and catches availability and handler errors"] = function()
    local result = evaluate([[
      local registry = require('workbench.core.actions').new()
      local contexts, values = 0, {}
      assert(registry:register({
        id = 'files.open',
        title = 'Open file',
        category = 'Files',
        scope = 'item',
        available = function(context) contexts = contexts + 1; return { enabled = context.allowed == true } end,
        args_schema = {
          type = 'object',
          properties = { path = { type = 'string', min_length = 1 }, line = { type = 'integer', minimum = 1 } },
          required = { 'path' },
        },
        run = function(_, args) values[#values + 1] = args.path; return args.line or 1 end,
      }))
      assert(registry:register({
        id = 'test.faulty_availability',
        title = 'Faulty availability',
        category = 'Test',
        scope = 'global',
        available = function() error('availability exploded') end,
        run = function() error('must not execute') end,
      }))
      assert(registry:register({
        id = 'test.faulty_handler',
        title = 'Faulty handler',
        category = 'Test',
        scope = 'global',
        available = function() return { enabled = true } end,
        run = function() error('handler exploded') end,
      }))
      local disabled = registry:execute('files.open', { allowed = false }, { path = '/tmp/a' })
      local missing = registry:execute('files.open', { allowed = true }, {})
      local unexpected = registry:execute('files.open', { allowed = true }, { path = '/tmp/a', extra = true })
      local success = registry:execute('files.open', { allowed = true }, { path = '/tmp/a', line = 4 })
      local availability_error = registry:execute('test.faulty_availability', {}, {})
      local handler_error = registry:execute('test.faulty_handler', {}, {})
      return {
        disabled = disabled,
        missing = missing,
        unexpected = unexpected,
        success = success,
        values = values,
        contexts = contexts,
        availability_error = availability_error,
        handler_error = handler_error,
      }
    ]])
    expect.equality(result.disabled.error.code, "unavailable")
    expect.equality(result.missing.error.code, "invalid_arguments")
    expect.equality(result.unexpected.error.code, "invalid_arguments")
    expect.equality(result.success.ok, true)
    expect.equality(result.success.value, 4)
    expect.equality(result.values[1], "/tmp/a")
    expect.equality(result.contexts, 4)
    expect.equality(result.availability_error.error.code, "availability_error")
    expect.equality(result.handler_error.error.code, "action_error")
  end,

  ["replacements restore only live owners and leave sibling actions intact"] = function()
    local result = evaluate([[
      local registry = require('workbench.core.actions').new()
      local function action(id, title, value)
        return {
          id = id, title = title, category = 'Test', scope = 'global',
          available = function() return { enabled = true } end,
          run = function() return value end,
        }
      end
      local original = assert(registry:register(action('test.shared', 'Original', 'original')))
      local sibling = assert(registry:register(action('test.sibling', 'Sibling', 'sibling')))
      local duplicate, duplicate_error = registry:register(action('test.shared', 'Duplicate', 'bad'))
      local replacement = assert(registry:register(action('test.shared', 'Replacement', 'replacement'), { replace = true }))
      local top_value = registry:execute('test.shared', {}, {}).value
      original:dispose()
      replacement:dispose()
      local after_old_owner_disposed = registry:execute('test.shared', {}, {})
      local sibling_value = registry:execute('test.sibling', {}, {}).value
      local again = registry:register(action('test.shared', 'A', 'a'))
      local newer = assert(registry:register(action('test.shared', 'B', 'b'), { replace = true }))
      again:dispose()
      newer:dispose()
      return {
        duplicate = duplicate,
        duplicate_error = duplicate_error,
        top_value = top_value,
        after_old_owner_disposed = after_old_owner_disposed,
        sibling_value = sibling_value,
        sibling_active = sibling:is_active(),
        current_ids = registry:inventory(),
      }
    ]])
    expect.equality(result.duplicate, nil)
    expect.equality(result.duplicate_error.code, "duplicate_action")
    expect.equality(result.top_value, "replacement")
    expect.equality(result.after_old_owner_disposed.error.code, "unknown_action")
    expect.equality(result.sibling_value, "sibling")
    expect.equality(result.sibling_active, true)
    expect.equality(#result.current_ids, 1)
    expect.equality(result.current_ids[1], "test.sibling")
  end,

  ["synthetic capabilities own their actions and disposal never alters a sibling"] = function()
    local result = evaluate([[
      local App = require('workbench.compose').new()
      local cleanups = { a = 0, b = 0 }
      local function installer(id)
        return function(context)
          local handle, err = context.actions:register({
            id = 'synthetic.' .. id,
            title = 'Synthetic ' .. id,
            category = 'Test',
            scope = 'global',
            available = function() return { enabled = true } end,
            run = function() return id end,
          }, { scope = context.scope })
          assert(handle, err and err.message)
          return function() cleanups[id] = cleanups[id] + 1 end
        end
      end
      App:set_enabled(true)
      local a = assert(App:register_capability('cap_a', installer('a')))
      local b = assert(App:register_capability('cap_b', installer('b')))
      local duplicate, duplicate_error = App:register_capability('cap_a', installer('a'))
      local before = App:get_status()
      local result_a = App:execute('synthetic.a', {}, {}).value
      a:dispose()
      local after_a = App:get_status()
      local missing_a = App:execute('synthetic.a', {}, {})
      local result_b = App:execute('synthetic.b', {}, {}).value
      local failed, failed_error = App:register_capability('cap_fail', function(context)
        assert(context.actions:register({
          id = 'synthetic.failed', title = 'Failed', category = 'Test', scope = 'global',
          available = function() return { enabled = true } end,
          run = function() return true end,
        }, { scope = context.scope }))
        error('installation failed')
      end)
      local after_failure = App:get_status()
      b:dispose()
      local final = App:get_status()
      App:dispose()
      return {
        duplicate = duplicate,
        duplicate_error = duplicate_error,
        before = before,
        result_a = result_a,
        result_b = result_b,
        after_a = after_a,
        missing_a = missing_a,
        failed = failed,
        failed_error = failed_error,
        after_failure = after_failure,
        final = final,
        cleanups = cleanups,
        b_active = b:is_active(),
        resources_after_dispose = App.scope:inventory(),
        actions_after_dispose = App.actions:inventory(),
      }
    ]])
    expect.equality(result.duplicate, nil)
    expect.equality(result.duplicate_error.code, "duplicate_capability")
    expect.equality(result.before.state, "enabled")
    expect.equality(#result.before.capabilities, 2)
    expect.equality(result.before.resources.resource_count, 3)
    expect.equality(result.result_a, "a")
    expect.equality(result.result_b, "b")
    expect.equality(#result.after_a.capabilities, 1)
    expect.equality(result.after_a.capabilities[1].id, "cap_b")
    expect.equality(result.missing_a.error.code, "unknown_action")
    expect.equality(result.failed, nil)
    expect.equality(result.failed_error.code, "capability_install_failed")
    expect.equality(#result.after_failure.capabilities, 1)
    expect.equality(#result.after_failure.actions, 4)
    expect.equality(result.after_failure.actions[4].id, "synthetic.b")
    expect.equality(result.final.resources.resource_count, 1)
    expect.equality(#result.final.actions, 3)
    expect.equality(result.final.actions[1].id, "settings.toggle_completion")
    expect.equality(result.final.actions[2].id, "settings.toggle_diagnostics")
    expect.equality(result.final.actions[3].id, "settings.toggle_formatting")
    expect.equality(result.resources_after_dispose.resource_count, 0)
    expect.equality(#result.actions_after_dispose, 0)
    expect.equality(result.cleanups.a, 1)
    expect.equality(result.cleanups.b, 1)
    expect.equality(result.b_active, false)
    expect.equality(result.final.resources.resources[1].label, "child:settings-controller")
  end,

  ["three capability disable and re-enable cycles leave one hook and preserve a sibling"] = function()
    local result = evaluate([[
      local App = require('workbench.compose').new()
      local toggled, sibling = 0, 0
      local groups = {}
      local function count_group(group)
        local count = 0
        for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'User', pattern = 'WorkbenchToggleProbe' })) do
          if autocmd.group == group then count = count + 1 end
        end
        return count
      end
      local function install(id, callback)
        return function(context)
          local group = vim.api.nvim_create_augroup('WorkbenchTest_' .. id, { clear = true })
          groups[id] = group
          vim.api.nvim_create_autocmd('User', {
            group = group,
            pattern = 'WorkbenchToggleProbe',
            callback = callback,
          })
          assert(context.scope:defer(function() pcall(vim.api.nvim_del_augroup_by_id, group) end, id .. '-hook', 'autocmd'))
          local action, err = context.actions:register({
            id = 'toggle.' .. id,
            title = id,
            category = 'Test',
            scope = 'global',
            available = function() return { enabled = true } end,
            run = function() return true end,
          }, { scope = context.scope })
          assert(action, err and err.message)
        end
      end

      App:set_enabled(true)
      local sibling_handle = assert(App:register_capability('sibling', install('sibling', function() sibling = sibling + 1 end)))
      local cycles, active_hook_counts, disposed_hook_counts = 0, {}, {}
      for _ = 1, 3 do
        local handle = assert(App:register_capability('toggle', install('toggle', function() toggled = toggled + 1 end)))
        active_hook_counts[#active_hook_counts + 1] = count_group(groups.toggle)
        assert(App:execute('toggle.toggle', {}, {}).ok)
        vim.api.nvim_exec_autocmds('User', { pattern = 'WorkbenchToggleProbe' })
        handle:dispose()
        disposed_hook_counts[#disposed_hook_counts + 1] = count_group(groups.toggle)
        local disabled_action = App:execute('toggle.toggle', {}, {})
        assert(disabled_action.error.code == 'unknown_action')
        vim.api.nvim_exec_autocmds('User', { pattern = 'WorkbenchToggleProbe' })
        cycles = cycles + 1
      end
      local sibling_action = App:execute('toggle.sibling', {}, {})
      local sibling_hooks = count_group(groups.sibling)
      sibling_handle:dispose()
      local final_hooks = #vim.api.nvim_get_autocmds({ event = 'User', pattern = 'WorkbenchToggleProbe' })
      return {
        cycles = cycles,
        active_hook_counts = active_hook_counts,
        disposed_hook_counts = disposed_hook_counts,
        toggled = toggled,
        sibling = sibling,
        sibling_action = sibling_action,
        sibling_hooks = sibling_hooks,
        final_hooks = final_hooks,
        resources = App.scope:inventory(),
        actions_before_dispose = App.actions:inventory(),
        disposed = App:dispose(),
        resources_after_dispose = App.scope:inventory(),
        actions_after_dispose = App.actions:inventory(),
      }
    ]])
    expect.equality(result.cycles, 3)
    expect.equality(result.active_hook_counts, { 1, 1, 1 })
    expect.equality(result.disposed_hook_counts, { 0, 0, 0 })
    expect.equality(result.toggled, 3)
    expect.equality(result.sibling, 6)
    expect.equality(result.sibling_action.ok, true)
    expect.equality(result.sibling_hooks, 1)
    expect.equality(result.final_hooks, 0)
    expect.equality(result.resources.resource_count, 1)
    expect.equality(result.resources.resources[1].label, "child:settings-controller")
    expect.equality(#result.actions_before_dispose, 3)
    expect.equality(result.resources_after_dispose.resource_count, 0)
    expect.equality(#result.actions_after_dispose, 0)
  end,

  ["public command stays dormant and setup false is distinct from absent"] = function()
    local result = evaluate([[
      local api = require('workbench')
      local before = api.get_status()
      local unloaded_before_setup = package.loaded['workbench.compose'] == nil
        and package.loaded['workbench.core.scope'] == nil
        and package.loaded['workbench.core.actions'] == nil
      vim.cmd('runtime plugin/workbench.lua')
      local has_command = vim.fn.exists(':Workbench') == 2
      vim.cmd('Workbench status')
      local after_command = api.get_status()
      local still_lazy = package.loaded['workbench.compose'] == nil
      local invalid, invalid_error = api.setup({ unknown_option = true })
      local after_invalid = api.get_status()
      local configured = assert(api.setup({ enabled = false }))
      local capability = assert(api.register_capability('public_test', function(context)
        assert(context.actions:register({
          id = 'public.ping', title = 'Ping', category = 'Test', scope = 'global',
          available = function() return { enabled = true } end,
          run = function(_, args) return args.value end,
        }, { scope = context.scope }))
      end))
      local disabled = api.execute('public.ping', { value = 'pong' })
      local enabled = assert(api.setup({ enabled = true }))
      local execution = api.execute('public.ping', { value = 'pong' })
      local absent_preserves = assert(api.setup({}))
      local disabled_again = assert(api.setup({ enabled = false }))
      local no_provider_loaded = package.loaded['workbench.providers.rg'] == nil
      capability:dispose()
      return {
        before = before,
        unloaded_before_setup = unloaded_before_setup,
        has_command = has_command,
        after_command = after_command,
        still_lazy = still_lazy,
        invalid = invalid,
        invalid_error = invalid_error,
        after_invalid = after_invalid,
        configured = configured,
        disabled = disabled,
        enabled = enabled,
        execution = execution,
        absent_preserves = absent_preserves,
        disabled_again = disabled_again,
        no_provider_loaded = no_provider_loaded,
      }
    ]])
    expect.equality(result.before.state, "disabled")
    expect.equality(result.before.reason, "not_setup")
    expect.equality(result.unloaded_before_setup, true)
    expect.equality(result.has_command, true)
    expect.equality(result.after_command.state, "disabled")
    expect.equality(result.still_lazy, true)
    expect.equality(result.invalid, nil)
    expect.equality(result.invalid_error.code, "invalid_config")
    expect.equality(result.after_invalid.state, "disabled")
    expect.equality(result.configured.state, "disabled")
    expect.equality(result.disabled.error.code, "disabled")
    expect.equality(result.enabled.state, "enabled")
    expect.equality(result.execution.ok, true)
    expect.equality(result.execution.value, "pong")
    expect.equality(result.absent_preserves.state, "enabled")
    expect.equality(result.disabled_again.state, "disabled")
    expect.equality(result.no_provider_loaded, true)
  end,

  ["corrupt session state is untouched during setup and public restore is explicit and inert"] = function()
    local result = evaluate([[
      local temp=vim.fn.tempname()..'-wb23-api'; assert(vim.fn.mkdir(temp,'p')==1); temp=assert((vim.uv or vim.loop).fs_realpath(temp))
      vim.env.XDG_STATE_HOME=temp..'/state'
      local state_dir=vim.fs.joinpath(vim.fn.stdpath('state'),'workbench','sessions')
      assert(vim.fn.mkdir(state_dir,'p')==1); assert(vim.fn.writefile({'{broken'},state_dir..'/session-broken.json')==0)
      local workspace=temp..'/workspace'; assert(vim.fn.mkdir(workspace,'p')==1); workspace=assert((vim.uv or vim.loop).fs_realpath(workspace))
      local api=require('workbench'); local before=api.get_status()
      local before_loaded=package.loaded['workbench.services.persistence']==nil
      assert(api.setup({enabled=false,session={persist=true}}))
      local setup_loaded=package.loaded['workbench.services.persistence']==nil
      local configured=api.get_status()
      local records=assert(api.list_sessions())
      local restored,restore_error=api.restore_session('broken')
      local saved=assert(api.save_session({workspaces={{root=workspace,view={active='files'}}}}))
      local roundtrip=assert(api.restore_session(saved.id))
      local deleted=assert(api.delete_session(saved.id))
      local after=api.get_status()
      local no_provider=package.loaded['workbench.providers.rg']==nil and package.loaded['workbench.providers.git']==nil
      vim.fn.delete(temp,'rf')
      return {before=before.state,before_loaded=before_loaded,setup_loaded=setup_loaded,configured=configured.state,
        records=#records,corrupt_state=records[1].state,restore_nil=restored==nil,restore_code=restore_error.code,
        saved_id=saved.id,available=roundtrip.snapshot.workspaces[1].available,automatic=roundtrip.automatic_execution,
        deleted=deleted,final_state=after.state,no_provider=no_provider}
    ]])
    expect.equality(result.before, "disabled")
    expect.equality(result.before_loaded, true)
    expect.equality(result.setup_loaded, true)
    expect.equality(result.configured, "disabled")
    expect.equality(result.records, 1)
    expect.equality(result.corrupt_state, "corrupt")
    expect.equality(result.restore_nil, true)
    expect.equality(result.restore_code, "corrupt_state")
    expect.equality(type(result.saved_id), "string")
    expect.equality(result.available, true)
    expect.equality(result.automatic, false)
    expect.equality(result.deleted, true)
    expect.equality(result.final_state, "disabled")
    expect.equality(result.no_provider, true)
  end,

  ["one hundred scope and capability cycles return resource inventory to zero"] = function()
    local result = evaluate([[
      local App = require('workbench.compose').new()
      local failures = 0
      for index = 1, 100 do
        local id = 'cycle_' .. index
        local handle, err = App:register_capability(id, function(context)
          local action, action_error = context.actions:register({
            id = 'cycle.' .. id, title = id, category = 'Test', scope = 'global',
            available = function() return { enabled = true } end,
            run = function() return true end,
          }, { scope = context.scope })
          assert(action, action_error and action_error.message)
        end)
        assert(handle, err and err.message)
        handle:dispose()
      end
      return {
        scope = App.scope:inventory(),
        capabilities = #App:get_status().capabilities,
        actions = App.actions:inventory(),
        failures = failures,
        disposed = App:dispose(),
        scope_after_dispose = App.scope:inventory(),
        actions_after_dispose = App.actions:inventory(),
      }
    ]])
    expect.equality(result.scope.resource_count, 1)
    expect.equality(result.scope.resources[1].label, "child:settings-controller")
    expect.equality(result.scope.pending_callbacks, 0)
    expect.equality(result.capabilities, 0)
    expect.equality(#result.actions, 3)
    expect.equality(result.scope_after_dispose.resource_count, 0)
    expect.equality(#result.actions_after_dispose, 0)
    expect.equality(result.failures, 0)
  end,
})
