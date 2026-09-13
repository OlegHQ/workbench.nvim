local MiniTest = require("mini.test")
local expect = MiniTest.expect
local child
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function evaluate(source, ...)
  local wrapped = "local args={...}; local unpack_fn=unpack or table.unpack; local ok,result=xpcall(function(...)\n" .. source .. "\nend,debug.traceback,unpack_fn(args)); if not ok then return {__child_error=result} end; return result"
  local result = child.lua(wrapped, { ... })
  if type(result) == "table" and result.__child_error then error("settings child evaluation failed: " .. vim.inspect(result.__child_error), 2) end
  return result
end

return MiniTest.new_set({
  hooks = {
    pre_case = function()
      child = MiniTest.new_child_neovim()
      child.start({}, { nvim_executable = assert(vim.env.NVIM_TEST_BINARY) })
      child.lua("vim.opt.runtimepath:prepend(...)", { root })
    end,
    post_case = function()
      if child then pcall(child.stop); child = nil end
    end,
  },
}, {
  ["settings schema preserves false, replaces arrays and rejects unknown or out-of-range values atomically"] = function()
    local result = evaluate([[
      local settings = require('workbench.services.settings').new()
      local defaults = settings:get('enabled')
      local configured = assert(settings:configure({
        enabled=true,
        sidebar={views={'files'},['follow_active_file']=false},
        search={hidden=false,ignored=true,['debounce_ms']=0},
      }, {source='autoconf.toml'}))
      local before = settings:config_snapshot()
      local unknown, unknown_error = settings:configure({search={mystery=true}})
      local range, range_error = settings:configure({enabled=false,search={debounce_ms=301}})
      local enabled = settings:get('enabled')
      local hidden = settings:get('search.hidden')
      local ignored = settings:get('search.ignored')
      local delay = settings:get('search.debounce_ms')
      local views = settings:get('sidebar.views')
      local after = settings:config_snapshot()
      return {
        configured=configured, defaults=defaults, unknown=unknown, unknown_error=unknown_error,
        range=range, range_error=range_error, enabled=enabled, hidden=hidden, ignored=ignored,
        delay=delay, views=views, unchanged=vim.deep_equal(before,after),
      }
    ]])
    expect.equality(result.configured, true)
    expect.equality(result.defaults.effective, false)
    expect.equality(result.enabled.effective, true)
    expect.equality(result.enabled.provenance, "autoconf.toml")
    expect.equality(result.hidden.effective, false)
    expect.equality(result.hidden.provenance, "autoconf.toml")
    expect.equality(result.ignored.effective, true)
    expect.equality(result.delay.effective, 0)
    expect.equality(result.views.effective, { "files" })
    expect.equality(result.unknown, nil)
    expect.equality(result.unknown_error.path, "search.mystery")
    expect.equality(result.range, nil)
    expect.equality(result.range_error.path, "search.debounce_ms")
    expect.equality(result.unchanged, true)
  end,

  ["replacing a provenance source restores omitted fields and snapshots restore all source layers"] = function()
    local result = evaluate([[
      local settings = require('workbench.services.settings').new()
      assert(settings:configure({sidebar={width=44},search={hidden=true}}, {source='setup'}))
      assert(settings:configure({search={hidden=false},preview={enabled=false}}, {source='autoconf.toml',replace_source=true}))
      local prior = settings:config_snapshot()
      assert(settings:configure({enabled=true}, {source='autoconf.toml',replace_source=true}))
      local fallback = settings:get('search.hidden')
      local preview = settings:get('preview.enabled')
      local width = settings:get('sidebar.width')
      local restored = settings:restore_config(prior)
      local restored_hidden = settings:get('search.hidden')
      local restored_preview = settings:get('preview.enabled')
      local restored_width = settings:get('sidebar.width')
      settings:dispose()
      return {fallback=fallback,preview=preview,width=width,restored=restored,
        restored_hidden=restored_hidden,restored_preview=restored_preview,restored_width=restored_width}
    ]])
    expect.equality(result.fallback.effective, true)
    expect.equality(result.fallback.provenance, "setup")
    expect.equality(result.preview.effective, true)
    expect.equality(result.preview.provenance, "default")
    expect.equality(result.width.effective, 44)
    expect.equality(result.width.provenance, "setup")
    expect.equality(result.restored, true)
    expect.equality(result.restored_hidden.effective, false)
    expect.equality(result.restored_hidden.provenance, "autoconf.toml")
    expect.equality(result.restored_preview.effective, false)
    expect.equality(result.restored_preview.provenance, "autoconf.toml")
    expect.equality(result.restored_width.effective, 44)
  end,

  ["workspace, session and buffer overrides compose by precedence and dispose back to their predecessor"] = function()
    local result = evaluate([[
      local settings = require('workbench.services.settings').new()
      assert(settings:configure({search={hidden=false,ignored=false}}))
      local workspace = assert(settings:set_override('workspace','ws-1','search.hidden',true))
      local session = assert(settings:set_override('session','view-1','search.hidden',false))
      local buffer = assert(settings:set_override('buffer',17,'search.hidden',true))
      local context = {workspace_id='ws-1',session_id='view-1',bufnr=17}
      local top = settings:get('search.hidden',context)
      buffer:dispose()
      local middle = settings:get('search.hidden',context)
      workspace:dispose()
      session:dispose()
      local fallback = settings:get('search.hidden',context)
      local invalid, invalid_error = settings:set_override('global','user','search.hidden',true)
      local enabled, enabled_error = settings:set_override('buffer',17,'enabled',true)
      local invalid_position, invalid_position_error = settings:set_override('buffer',17,'sidebar.position','right')
      local second_dispose = session:dispose()
      return {top=top,middle=middle,fallback=fallback,invalid=invalid,invalid_error=invalid_error,
        enabled=enabled,enabled_error=enabled_error,invalid_position=invalid_position,
        invalid_position_error=invalid_position_error,second_dispose=second_dispose}
    ]])
    expect.equality(result.top.effective, true)
    expect.equality(result.top.provenance, "buffer:17")
    expect.equality(result.middle.effective, false)
    expect.equality(result.middle.provenance, "session:view-1")
    expect.equality(result.fallback.effective, false)
    expect.equality(result.fallback.provenance, "setup")
    expect.equality(result.invalid, nil)
    expect.equality(result.invalid_error.code, "invalid_scope")
    expect.equality(result.enabled, nil)
    expect.equality(result.enabled_error.code, "not_overridable")
    expect.equality(result.invalid_position, nil)
    expect.equality(result.invalid_position_error.code, "override_scope_not_allowed")
    expect.equality(result.second_dispose, false)
  end,

  ["disposing an override preserves sibling paths and skips disposed predecessors"] = function()
    local result = evaluate([[
      local settings = require('workbench.services.settings').new()
      local checked = 0
      for _, spec in ipairs({
        {'workspace', 'ws-1', {workspace_id='ws-1'}},
        {'session', 'view-1', {session_id='view-1'}},
        {'buffer', 17, {bufnr=17}},
      }) do
        local scope, id, context = unpack(spec)
        local first = assert(settings:set_override(scope,id,'search.hidden',true))
        local sibling = assert(settings:set_override(scope,id,'search.ignored',true))
        local replacement = assert(settings:set_override(scope,id,'search.hidden',false))
        assert(first:dispose())
        assert(settings:get('search.hidden',context).effective == false)
        assert(replacement:dispose())
        assert(settings:get('search.hidden',context).provenance == 'default')
        assert(settings:get('search.ignored',context).effective == true, 'sibling override was lost')
        local next_override = assert(settings:set_override(scope,id,'search.hidden',true))
        assert(sibling:dispose())
        assert(settings:get('search.hidden',context).effective == true)
        assert(not replacement:dispose())
        assert(next_override:dispose())
        assert(next(settings.overrides[scope]) == nil)
        checked = checked + 1
      end
      settings:dispose()
      return checked
    ]])
    expect.equality(result, 3)
  end,

  ["runtime application failures restore configuration and override ownership"] = function()
    local result = evaluate([[
      local settings, rejected, actual
      local context={session_id='view'}
      settings=require('workbench.services.settings').new({apply=function()
        local width=settings:get('sidebar.width',context).effective
        local recursive,recursive_error=settings:configure({sidebar={width=60}})
        assert(not recursive and recursive_error.code=='settings_busy')
        if width==rejected then return nil,{message='injected width failure'} end
        actual=width
        return true
      end})
      assert(settings:configure({sidebar={width=40}}))
      local before=settings:config_snapshot()
      rejected=44
      local changed,err=settings:configure({sidebar={width=44}})
      assert(not changed and err.code=='setting_apply_failed' and actual==40)
      assert(vim.deep_equal(before,settings:config_snapshot()))
      local sibling=assert(settings:set_override('session','view','preview.enabled',false))
      local bad,bad_error=settings:set_override('session','view','sidebar.width',44)
      assert(not bad and bad_error.code=='setting_apply_failed')
      assert(settings:get('sidebar.width',context).effective==40)
      assert(settings:get('preview.enabled',context).effective==false)
      local width=assert(settings:set_override('session','view','sidebar.width',48))
      assert(actual==48)
      rejected=40
      local disposed,dispose_error=width:dispose()
      assert(not disposed and dispose_error.code=='setting_apply_failed')
      assert(width:is_active() and actual==48)
      rejected=nil
      assert(width:dispose() and actual==40)
      assert(sibling:is_active() and settings:get('preview.enabled',context).effective==false)
      assert(sibling:dispose())
      assert(settings:configure({sidebar={width=42}}))
      rejected=40
      local restored,restore_error=settings:restore_config(before)
      assert(not restored and restore_error.code=='setting_apply_failed' and actual==42)
      assert(settings:get('sidebar.width').effective==42)
      settings:dispose()
      assert(settings.apply==nil)
      return true
    ]])
    expect.equality(result,true)
  end,

  ["standalone actions disclose absent host adapters and adapter failure rolls back without touching siblings"] = function()
    local result = evaluate([[
      local app = assert(require('workbench.compose').new())
      local status = app:get_status()
      local available = {}
      for _, action in ipairs(status.actions) do
        if action.id:match('^settings%.toggle_') then available[action.id] = action.available end
      end
      assert(app:configure({enabled=true}))
      local values = {completion=true,formatting=false,diagnostics=false}
      local function adapter(id, setter)
        return {
          scope='global',
          capabilities=function() return {available=true,state='ready'} end,
          get=function() return {requested=values[id],effective=values[id],provenance='test-host'} end,
          set=setter or function(value) values[id]=value; return true end,
        }
      end
      local completion = assert(app:register_setting_adapter('completion',adapter('completion')))
      local broken = assert(app:register_setting_adapter('formatting',adapter('formatting',function(value)
        if value then values.formatting=true; return false,{code='test_veto',message='format adapter vetoed'} end
        values.formatting=false; return true
      end)))
      assert(app:register_setting_adapter('diagnostics',adapter('diagnostics')))
      local before = app:get_status().editor_settings
      local failure = app:execute('settings.toggle_formatting',{}, {enabled=true})
      local untouched = app:execute('settings.toggle_diagnostics',{}, {enabled=true})
      local toggled = app:execute('settings.toggle_completion',{}, {})
      local after = app:get_status().editor_settings
      local duplicate, duplicate_error = app:register_setting_adapter('completion',adapter('completion'))
      local report = app:dispose()
      return {available=available,before=before,failure=failure,untouched=untouched,toggled=toggled,after=after,
        duplicate=duplicate,duplicate_error=duplicate_error,completion_active=completion:is_active(),broken_active=broken:is_active(),
        cleanup=report}
    ]])
    expect.equality(result.available["settings.toggle_completion"].enabled, false)
    expect.equality(result.available["settings.toggle_completion"].reason, "no autoconf editor-setting adapter is registered")
    expect.equality(result.before.completion.available, true)
    expect.equality(result.failure.ok, false)
    expect.equality(result.failure.error.code, "test_veto")
    expect.equality(result.failure.error.message, "format adapter vetoed")
    expect.equality(result.untouched.value.effective, true)
    expect.equality(result.toggled.value.effective, false)
    expect.equality(result.after.formatting.effective, false)
    expect.equality(result.after.diagnostics.effective, true)
    expect.equality(result.after.completion.effective, false)
    expect.equality(result.duplicate, nil)
    expect.equality(result.duplicate_error.code, "duplicate_adapter")
    expect.equality(result.completion_active, false)
    expect.equality(result.broken_active, false)
    expect.equality(result.cleanup.ok, true)
  end,

  ["failed app configuration preserves enabled state and settings save refuses to write an unknown target"] = function()
    local result = evaluate([[
      local app = assert(require('workbench.compose').new())
      assert(app:configure({enabled=true,search={debounce_ms=0}}))
      local before = app:get_status()
      local before_search_delay = app.settings:get('search.debounce_ms').effective
      local changed, err = app:configure({enabled=false,search={debounce_ms=301}})
      local after = app:get_status()
      local settings = require('workbench.services.settings').new()
      local saved, save_error = settings:save()
      settings:dispose()
      local after_search_delay = app.settings:get('search.debounce_ms').effective
      app:dispose()
      return {changed=changed,error=err,before_state=before.state,after_state=after.state,
        before_search_delay=before_search_delay,after_search_delay=after_search_delay,
        saved=saved,save_error=save_error}
    ]])
    expect.equality(result.changed, nil)
    expect.equality(result.error.path, "search.debounce_ms")
    expect.equality(result.before_state, "enabled")
    expect.equality(result.after_state, "enabled")
    expect.equality(result.before_search_delay, 0)
    expect.equality(result.after_search_delay, 0)
    expect.equality(result.saved, nil)
    expect.equality(result.save_error.code, "read_only_config")
    expect.equality(result.save_error.message:find("no writable workbench TOML target", 1, true) ~= nil, true)
  end,

  ["invalid public setup does not create or enable the singleton application"] = function()
    local result = evaluate([[
      local workbench = require('workbench')
      local before = workbench.get_status()
      local configured, err = workbench.setup({enabled=true,search={max_results=10001}})
      local after = workbench.get_status()
      return {before=before,configured=configured,error=err,after=after}
    ]])
    expect.equality(result.before.reason, "not_setup")
    expect.equality(result.configured, nil)
    expect.equality(result.error.path, "search.max_results")
    expect.equality(result.after.reason, "not_setup")
    expect.equality(result.after.state, "disabled")
  end,
})
