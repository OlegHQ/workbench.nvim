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
  ["create plans require exact review and exclusive destinations"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-create'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local snapshot = { id = 'workspace-create', generation = 1, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new())
      local callback_plan
      local prepared = service:prepare(snapshot, 'create_file', { parent = root, name = 'created.txt' }, function(plan, err)
        assert(not err, err and err.message); callback_plan = plan
      end)
      assert(prepared == callback_plan and prepared.state == 'validated')
      local premature, premature_error = service:apply(prepared)
      assert(not premature and premature_error.code == 'review_required')
      assert(not vim.uv.fs_lstat(root .. '/created.txt'))
      local overlapping_error
      local overlapping = service:prepare(snapshot, 'create_file', { parent = root, name = 'created.txt' }, function(_, err) overlapping_error = err end)
      assert(overlapping.state == 'failed' and overlapping_error.code == 'operation_overlap')
      assert(service:review(prepared))
      assert(service:apply(prepared))
      local created = vim.uv.fs_lstat(root .. '/created.txt')
      local directory = assert(service:prepare(snapshot, 'create_directory', { parent = root, name = 'created-dir' }, function() end))
      assert(service:review(directory))
      assert(service:apply(directory))
      local directory_stat = uv.fs_lstat(root .. '/created-dir')
      local collision, collision_error = service:prepare(snapshot, 'create_file', { parent = root, name = 'created.txt' }, function() end)
      local status = service:status()
      service:dispose()
      vim.fn.delete(root, 'rf')
      return { state = prepared.state, created = created and created.type, directory = directory_stat and directory_stat.type,
        payload_released = prepared.workspace == nil and prepared.args == nil and prepared.lsp == nil,
        collision = collision == nil, collision_code = collision_error.code, active = status.active }
    ]])
    expect.equality(result.state, "applied")
    expect.equality(result.created, "file")
    expect.equality(result.directory, "directory")
    expect.equality(result.payload_released, true)
    expect.equality(result.collision, true)
    expect.equality(result.collision_code, "destination_exists")
    expect.equality(result.active, 0)
  end,

  ["copy move rename and case-only rename preserve bytes permissions and open-buffer undo"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-local'
      assert(vim.fn.mkdir(root .. '/destination', 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source = root .. '/source.txt'
      assert(vim.fn.writefile({ 'payload', 'second line' }, source) == 0)
      local snapshot = { id = 'workspace-local', generation = 2, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new())
      local function execute(kind, args)
        local plan, prepare_error
        local returned
        returned, prepare_error = service:prepare(snapshot, kind, args, function(value, err) plan, prepare_error = value, err end)
        assert(returned, prepare_error and prepare_error.message)
        assert(plan and plan.state == 'validated')
        assert(service:review(plan))
        local okay, apply_error = service:apply(plan)
        assert(okay, apply_error and apply_error.message)
        return plan
      end
      local copy = root .. '/destination/copied.txt'
      execute('copy', { source = source, destination = copy })
      local copied_mode = uv.fs_stat(copy).mode % 512
      local source_mode = uv.fs_stat(source).mode % 512
      local copy_lines = vim.fn.readfile(copy)
      execute('move', { source = source, destination = root .. '/destination' })
      local moved = root .. '/destination/source.txt'
      local moved_stat, missing_source = uv.fs_stat(moved), uv.fs_lstat(source)
      local buffer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buffer, moved)
      vim.api.nvim_buf_call(buffer, function() vim.cmd('edit') end)
      vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { 'undo result' })
      vim.api.nvim_buf_call(buffer, function() vim.cmd('write!') end)
      local renamed = root .. '/destination/renamed.txt'
      execute('rename', { source = moved, name = 'renamed.txt' })
      local buffer_name = vim.api.nvim_buf_get_name(buffer)
      local buffer_lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      vim.api.nvim_buf_call(buffer, function() vim.cmd('undo') end)
      local undo_lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      assert(vim.fn.writefile({ 'case' }, root .. '/Case.txt') == 0)
      execute('rename', { source = root .. '/Case.txt', name = 'case.txt' })
      local names = vim.fn.readdir(root)
      local case_path = vim.tbl_contains(names, 'case.txt') and not vim.tbl_contains(names, 'Case.txt')
      local report = { copy_lines = copy_lines, copied_mode = copied_mode, source_mode = source_mode,
        moved_same_inode = moved_stat and moved_stat.ino == uv.fs_stat(copy).ino, source_removed = missing_source == nil,
        buffer_name = buffer_name, buffer_lines = buffer_lines, undo_lines = undo_lines, renamed_exists = uv.fs_stat(renamed) ~= nil,
        target = renamed, case_rename = case_path }
      service:dispose()
      vim.fn.delete(root, 'rf')
      return report
    ]])
    expect.equality(result.copy_lines, { "payload", "second line" })
    expect.equality(result.copied_mode, result.source_mode)
    expect.equality(result.source_removed, true)
    expect.equality(result.renamed_exists, true)
    expect.equality(result.buffer_name, result.target)
    expect.equality(result.buffer_lines, { "payload", "undo result" })
    expect.equality(result.undo_lines, { "payload", "second line" })
    expect.equality(result.case_rename, true)
  end,

  ["collisions stale inputs dirty buffers symlinks and cyclic directories fail before mutation"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-preflight'
      assert(vim.fn.mkdir(root .. '/dir', 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, collision = root .. '/source.txt', root .. '/collision.txt'
      assert(vim.fn.writefile({ 'old' }, source) == 0)
      assert(vim.fn.writefile({ 'safe' }, collision) == 0)
      assert(uv.fs_link(source, root .. '/hardlink.txt'))
      assert(uv.fs_symlink(source, root .. '/linked.txt'))
      local snapshot = { id = 'workspace-preflight', generation = 3, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new())
      local collision_plan, collision_error = service:prepare(snapshot, 'copy', { source = source, destination = collision }, function() end)
      local hardlink_plan, hardlink_error = service:prepare(snapshot, 'copy', { source = source, destination = root .. '/hardlink.txt' }, function() end)
      local stale = assert(service:prepare(snapshot, 'rename', { source = source, name = 'renamed.txt' }, function() end))
      assert(service:review(stale))
      assert(vim.fn.writefile({ 'new' }, source) == 0)
      local stale_ok, stale_error = service:apply(stale)
      local generation_stale = assert(service:prepare(snapshot, 'rename', { source = source, name = 'generation-stale.txt' }, function() end))
      assert(service:review(generation_stale))
      generation_stale.workspace_generation = snapshot.generation + 1
      local generation_ok, generation_error = service:apply(generation_stale)
      local linked_plan, symlink_error = service:prepare(snapshot, 'copy', { source = root .. '/linked.txt', destination = root .. '/copy.txt' }, function() end)
      local outside, outside_error = service:prepare(snapshot, 'copy', { source = source, destination = vim.fn.tempname() }, function() end)
      local cyclic, cyclic_error = service:prepare(snapshot, 'move', { source = root .. '/dir', destination = root .. '/dir' }, function() end)
      local dirty_buffer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(dirty_buffer, source)
      vim.api.nvim_buf_set_lines(dirty_buffer, 0, -1, false, { 'unsaved' })
      local modified_value = vim.api.nvim_get_option_value('modified', { buf = dirty_buffer })
      local dirty, dirty_error = service:prepare(snapshot, 'rename', { source = source, name = 'dirty.txt' }, function() end)
      local values = { collision = collision_plan == nil, collision_code = collision_error.code,
        hardlink_collision = hardlink_plan == nil, hardlink_code = hardlink_error and hardlink_error.code,
        safe_contents = vim.fn.readfile(collision), stale = not stale_ok, stale_code = stale_error.code,
        generation_stale = not generation_ok, generation_code = generation_error.code,
        no_rename = uv.fs_lstat(root .. '/renamed.txt') == nil, symlink = linked_plan == nil, symlink_code = symlink_error.code,
        outside = outside == nil, outside_code = outside_error.code, cyclic = cyclic == nil, cyclic_code = cyclic_error.code,
        dirty = dirty == nil, dirty_code = dirty_error and dirty_error.code or 'none', modified_value = modified_value }
      service:dispose()
      vim.fn.delete(root, 'rf')
      return values
    ]])
    expect.equality(result.collision, true)
    expect.equality(result.collision_code, "destination_exists")
    expect.equality(result.safe_contents, { "safe" })
    expect.equality(result.hardlink_collision, true)
    expect.equality(result.hardlink_code, "destination_exists")
    expect.equality(result.stale, true)
    expect.equality(result.stale_code, "stale_preimage")
    expect.equality(result.generation_stale, true)
    expect.equality(result.generation_code, "workspace_changed")
    expect.equality(result.no_rename, true)
    expect.equality(result.symlink, true)
    expect.equality(result.symlink_code, "symlink_unsupported")
    expect.equality(result.outside, true)
    expect.equality(result.outside_code, "outside_root")
    expect.equality(result.cyclic, true)
    expect.equality(result.cyclic_code, "cyclic_move")
    expect.equality(result.dirty, true)
    expect.equality(result.dirty_code, "dirty_buffer")
  end,

  ["partial copy removes only its owned destination and records recovery"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-partial'
      assert(vim.fn.mkdir(root .. '/destination', 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, target = root .. '/source.bin', root .. '/copy.bin'
      assert(vim.fn.writefile({ string.rep('x', 100) }, source, 'b') == 0)
      local writes = 0
      local fake_uv = setmetatable({ fs_write = function(fd, bytes, offset)
        writes = writes + 1
        if writes == 1 then return uv.fs_write(fd, bytes:sub(1, 17), offset) end
        return nil, 'ENOSPC: injected partial write'
      end }, { __index = uv })
      local snapshot = { id = 'workspace-partial', generation = 4, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new({ uv = fake_uv }))
      local plan = assert(service:prepare(snapshot, 'copy', { source = source, destination = target }, function() end))
      assert(service:review(plan))
      local okay, err = service:apply(plan)
      local target_exists = uv.fs_lstat(target) ~= nil
      local ledger = vim.deepcopy(plan.recovery.ledger)
      service:dispose()
      vim.fn.delete(root, 'rf')
      return { okay = okay == true, code = err.code, state = plan.state, target_exists = target_exists, ledger = ledger }
    ]])
    expect.equality(result.okay, false)
    expect.equality(result.code, "partial_copy")
    expect.equality(result.state, "failed")
    expect.equality(result.target_exists, false)
    expect.equality(result.ledger[1].status, "recovered")
    expect.equality(result.ledger[#result.ledger].status, "recovered")
  end,

  ["permission errors cross-device refusal and recoverable-trash policy are explicit"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-limits'
      assert(vim.fn.mkdir(root .. '/destination', 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source = root .. '/source.txt'
      assert(vim.fn.writefile({ 'keep' }, source) == 0)
      local snapshot = { id = 'workspace-limits', generation = 5, roots = { { path = root } } }
      local no_write = setmetatable({ fs_access = function() return nil, 'EACCES: denied' end }, { __index = uv })
      local denied_service = assert(require('workbench.services.operations').new({ uv = no_write }))
      local denied, denied_error = denied_service:prepare(snapshot, 'create_file', { parent = root, name = 'x' }, function() end)
      denied_service:dispose()
      local cross_uv = setmetatable({ fs_link = function() return nil, 'EXDEV: cross-device link' end }, { __index = uv })
      local cross_service = assert(require('workbench.services.operations').new({ uv = cross_uv }))
      local cross = assert(cross_service:prepare(snapshot, 'move', { source = source, destination = root .. '/destination' }, function() end))
      assert(cross_service:review(cross))
      local moved, cross_error = cross_service:apply(cross)
      local target_exists = uv.fs_lstat(root .. '/source.txt') ~= nil
      local trash, trash_error = cross_service:prepare(snapshot, 'trash', { source = source }, function() end)
      cross_service:dispose()
      local default_service = assert(require('workbench.services.operations').new())
      local unavailable, unavailable_error = default_service:prepare(snapshot, 'trash', { source = source }, function() end)
      default_service:dispose()
      vim.fn.delete(root, 'rf')
      return { denied = denied == nil, denied_code = denied_error.code, moved = moved == true, cross_code = cross_error.code,
        source_remains = target_exists, target_exists = uv.fs_lstat(root .. '/source.txt') ~= nil,
        trash_with_adapter = trash == nil, trash_code = trash_error and trash_error.code,
        trash_unavailable = unavailable == nil, trash_unavailable_code = unavailable_error.code }
    ]])
    expect.equality(result.denied, true)
    expect.equality(result.denied_code, "permission_denied")
    expect.equality(result.moved, false)
    expect.equality(result.cross_code, "unsupported_cross_device")
    expect.equality(result.source_remains, true)
    expect.equality(result.trash_unavailable, true)
    expect.equality(result.trash_unavailable_code, "trash_unavailable")
  end,

  ["LSP workspace edit is reviewed and applied before rename notification"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-lsp'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, reference = root .. '/source.lua', root .. '/reference.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      assert(vim.fn.writefile({ 'old reference' }, reference) == 0)
      local reference_buffer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(reference_buffer, reference)
      vim.api.nvim_buf_set_lines(reference_buffer, 0, -1, false, { 'old reference' })
      vim.api.nvim_set_option_value('modified', false, { buf = reference_buffer })
      local events = {}
      local lsp = {}
      function lsp:prepare_file_rename(from, to, buffer, callback)
        events[#events + 1] = 'will'
        local edit = { changes = { [vim.uri_from_fname(reference)] = {
          { range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 3 } }, newText = 'new' },
        } } }
        callback({ edit = edit,
          encoding = 'utf-8', affected_paths = { reference }, review = { vim.uri_from_fname(reference) .. '\n  1:1-1:4 → new' }, clients = {} })
        return { cancel = function() return true end }
      end
      function lsp:did_rename_files(from, to)
        assert(vim.uv.fs_lstat(to), 'filesystem rename must precede didRenameFiles')
        events[#events + 1] = 'did'
        return true
      end
      local snapshot = { id = 'workspace-lsp', generation = 6, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new({ lsp = lsp }))
      local plan = assert(service:prepare(snapshot, 'rename', { source = source, name = 'renamed.lua' }, function() end))
      local review = plan.review
      assert(review:find('reference.lua', 1, true) and review:find('→ new', 1, true))
      assert(service:review(plan))
      local okay = service:apply(plan)
      local lines = vim.api.nvim_buf_get_lines(reference_buffer, 0, -1, false)
      local order = table.concat(events, ',')
      service:dispose()
      vim.fn.delete(root, 'rf')
      return { okay = okay == true, lines = lines, order = order, renamed = plan.target }
    ]])
    expect.equality(result.okay, true)
    expect.equality(result.lines, { "new reference" })
    expect.equality(result.order, "will,did")
    expect.equality(result.renamed:match("renamed%.lua$") ~= nil, true)
  end,

  ["failed LSP workspace edits retain manual recovery state and suppress rename notification"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-lsp-partial'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, reference = root .. '/source.lua', root .. '/reference.lua'
      assert(vim.fn.writefile({ 'source' }, source) == 0)
      assert(vim.fn.writefile({ 'old reference' }, reference) == 0)
      local events, lsp = {}, {}
      function lsp:prepare_file_rename(from, to, buffer, callback)
        callback({ edit = { changes = { [vim.uri_from_fname(reference)] = {} } }, encoding = 'utf-16',
          affected_paths = { reference }, review = { vim.uri_from_fname(reference) .. '\\n(empty edit)' }, clients = {} })
        return { cancel = function() return true end }
      end
      function lsp:did_rename_files() events[#events + 1] = 'did'; return true end
      local snapshot = { id = 'workspace-lsp-partial', generation = 7, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new({ lsp = lsp }))
      local plan = assert(service:prepare(snapshot, 'rename', { source = source, name = 'renamed.lua' }, function() end))
      assert(service:review(plan))
      local original = vim.lsp.util.apply_workspace_edit
      vim.lsp.util.apply_workspace_edit = function() error('injected workspace edit failure') end
      local okay, apply_error = service:apply(plan)
      vim.lsp.util.apply_workspace_edit = original
      local ledger = vim.deepcopy(plan.recovery.ledger)
      local values = { okay = okay == true, code = apply_error and apply_error.code, state = plan.state,
        ledger_status = ledger[1] and ledger[1].status, did = #events > 0,
        source_exists = uv.fs_lstat(source) ~= nil, target_exists = uv.fs_lstat(root .. '/renamed.lua') ~= nil,
        reference_lines = vim.fn.readfile(reference) }
      service:dispose()
      vim.fn.delete(root, 'rf')
      return values
    ]])
    expect.equality(result.okay, false)
    expect.equality(result.code, "lsp_edit_failed")
    expect.equality(result.state, "partial")
    expect.equality(result.ledger_status, "manual_recovery")
    expect.equality(result.did, false)
    expect.equality(result.source_exists, true)
    expect.equality(result.target_exists, false)
    expect.equality(result.reference_lines, { "old reference" })
  end,

  ["recoverable-trash adapter receives an exact review and returns its recovery receipt"] = function()
    local result = evaluate([[
      local uv = vim.uv
      local root = vim.fn.tempname() .. '-wb-operations-trash'
      assert(vim.fn.mkdir(root .. '/.trash', 'p') == 1)
      root = assert(uv.fs_realpath(root))
      local source, destination = root .. '/source.txt', root .. '/.trash/source.txt'
      assert(vim.fn.writefile({ 'recover me' }, source) == 0)
      local adapter = {}
      function adapter:preview(path, preimage)
        assert(path == source and preimage.type == 'file')
        return { display_target = destination, recoverable = true }
      end
      function adapter:move(plan)
        assert(plan.state == 'applying' and plan.review:find(destination, 1, true))
        assert(uv.fs_link(plan.source, destination))
        assert(uv.fs_unlink(plan.source))
        return { recoverable = true, location = destination, token = 'receipt-1' }
      end
      local snapshot = { id = 'workspace-trash', generation = 8, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new({ trash = adapter }))
      local plan = assert(service:prepare(snapshot, 'trash', { source = source }, function() end))
      local review_contains_destination = plan.review:find(destination, 1, true) ~= nil
      assert(service:review(plan))
      local okay, recovery = service:apply(plan)
      local values = { okay = okay == true, review = review_contains_destination,
        source_removed = uv.fs_lstat(source) == nil, destination_exists = uv.fs_lstat(destination) ~= nil,
        receipt = recovery.ledger[1].receipt }
      service:dispose()
      vim.fn.delete(root, 'rf')
      return values
    ]])
    expect.equality(result.okay, true)
    expect.equality(result.review, true)
    expect.equality(result.source_removed, true)
    expect.equality(result.destination_exists, true)
    expect.equality(result.receipt.token, "receipt-1")
  end,

  ["active operation plans have a bounded count and disposal cancels them"] = function()
    local result = evaluate([[
      local root = vim.fn.tempname() .. '-wb-operations-plan-limit'
      assert(vim.fn.mkdir(root, 'p') == 1)
      root = assert(vim.uv.fs_realpath(root))
      local snapshot = { id = 'workspace-plan-limit', generation = 9, roots = { { path = root } } }
      local service = assert(require('workbench.services.operations').new())
      local plans = {}
      for index = 1, 32 do
        plans[index] = assert(service:prepare(snapshot, 'create_file', { parent = root, name = 'file-' .. index }, function() end))
        assert(plans[index].state == 'validated')
      end
      local limit_error
      local excess = service:prepare(snapshot, 'create_file', { parent = root, name = 'excess' }, function(_, err) limit_error = err end)
      local before = service:status()
      service:dispose()
      local cancelled = true
      for _, plan in ipairs(plans) do if plan.state ~= 'cancelled' then cancelled = false end end
      vim.fn.delete(root, 'rf')
      return { excess_failed = excess.state == 'failed', code = limit_error and limit_error.code,
        active_count = before.plan_count, cancelled = cancelled, resources = service:status().resources.resource_count }
    ]])
    expect.equality(result.excess_failed, true)
    expect.equality(result.code, "operation_limit")
    expect.equality(result.active_count, 32)
    expect.equality(result.cancelled, true)
    expect.equality(result.resources, 0)
  end,
})
