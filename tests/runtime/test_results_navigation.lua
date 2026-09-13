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
  ["per-result caps preserve shared limits and reject invalid values before eviction"] = function()
    local result=evaluate([[
      local store=assert(require('workbench.services.results').new({max_items=3,max_batch_items=3}))
      for _,invalid in ipairs({0,-1,1.5,'1',false}) do
        assert(not store:create({id='bad',provider_id='test',workspace_id='ws',generation=1,max_items=invalid}))
      end
      assert(store:create({id='small',provider_id='test',workspace_id='ws',generation=1,max_items=1}))
      assert(store:create({id='large',provider_id='test',workspace_id='ws',generation=1,max_items=100}))
      local items={{id='1',kind='match',label='one'},{id='2',kind='match',label='two'},{id='3',kind='match',label='three'}}
      local small=assert(store:merge('small',items))
      local large=assert(store:merge('large',items))
      assert(small.item_count==1 and small.status=='partial' and small.completeness=='truncated')
      assert(large.item_count==3 and large.status=='running' and store.limits.max_items==3)
      store:dispose()
      return true
    ]])
    expect.equality(result,true)
  end,

  ["streamed result merges preserve stable order and session state through close and resume"] = function()
    local result = evaluate([[
      local store = assert(require('workbench.services.results').new({max_sets=2,max_sessions=2,max_items=8,max_bytes=8192}))
      local created = assert(store:create({id='search-1',provider_id='rg',workspace_id='ws',generation=3,query={text='needle'}}))
      assert(created.status == 'running' and created.revision == 0)
      local first_delta=assert(store:merge('search-1', {
        {id='parent',kind='file',label='parent'},
        {id='one',kind='match',label='one',parent_id='parent'},
        {id='two',kind='match',label='two',parent_id='parent'},
      }))
      local first_page=assert(store:page('search-1',0,2))
      first_page.items[1].label='caller mutation'
      local page_copy_safe=store:item('search-1','parent').label=='parent'
      local session = assert(store:open_session('search-1',{id='view-a',selected_id='two',origin={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}}))
      assert(session:set_filter('needle'))
      assert(session:set_expanded('parent',true))
      assert(session:set_scroll_anchor({id='two',offset=2}))
      local old_revision = store:get('search-1').revision
      local merge_delta=assert(store:merge('search-1', {
        {id='two',kind='match',label='two updated',parent_id='parent'},
        {id='three',kind='match',label='three',parent_id='parent'},
      }))
      local merged = assert(store:get('search-1'))
      local stream_stable = merged.order[1] == 'parent' and merged.order[2] == 'one'
        and merged.order[3] == 'two' and merged.order[4] == 'three'
        and session.selected_id == 'two' and merged.items.two.label == 'two updated'
      assert(store:remove_items('search-1',{'two'}))
      local selected_after_remove = session.selected_id
      assert(session:close())
      local closed_snapshot = session:snapshot()
      local resumed = assert(store:resume('view-a'))
      local resume_state = resumed.selected_id == 'three' and resumed.filter == 'needle'
        and resumed.expanded.parent == true and resumed.scroll_anchor.offset == 2
      assert(store:remove_items('search-1',{'three'}))
      local previous_sibling = session.selected_id
      assert(store:remove_items('search-1',{'one'}))
      local parent_fallback = session.selected_id
      assert(store:finish('search-1','cancelled','unknown',{code='cancelled',message='user cancelled'}))
      local complete_after_cancel, complete_error = store:finish('search-1','complete','complete')
      local batch_after_cancel = store:merge('search-1',{{id='late',kind='match',label='late'}})
      local snapshot = assert(store:get('search-1'))
      local output = {
        stable_stream = stream_stable,
        compact_batch_delta = #first_delta.changes.added==3 and #merge_delta.changes.added==1
          and #merge_delta.changes.updated==1 and page_copy_safe,
        old_revision = old_revision,
        revision = merged.revision,
        selected_after_remove = selected_after_remove,
        previous_sibling = previous_sibling,
        parent_fallback = parent_fallback,
        closed_retained = closed_snapshot.mounted == false,
        resumed_state = resume_state,
        cancelled_not_complete = snapshot.status == 'cancelled' and complete_after_cancel == nil
          and complete_error:find('terminal',1,true) ~= nil and batch_after_cancel == nil,
        item_count = #snapshot.order,
      }
      store:dispose()
      local status = store:status()
      return output
    ]])
    expect.equality(result.stable_stream, true)
    expect.equality(result.compact_batch_delta, true)
    expect.equality(result.selected_after_remove, "three")
    expect.equality(result.closed_retained, true)
    expect.equality(result.resumed_state, true)
    expect.equality(result.cancelled_not_complete, true)
    expect.equality(result.previous_sibling, "one")
    expect.equality(result.parent_fallback, "parent")
    expect.equality(result.item_count, 1)
  end,

  ["result item caps produce visible truncation and history evicts only unreferenced closed sessions"] = function()
    local result = evaluate([[
      local store=assert(require('workbench.services.results').new({max_sets=1,max_sessions=1,max_items=2,max_batch_items=3,max_bytes=4096,max_item_bytes=512}))
      assert(store:create({id='bounded',provider_id='test',workspace_id='ws',generation=1}))
      local overflow=assert(store:merge('bounded',{
        {id='one',kind='match',label='one'},
        {id='two',kind='match',label='two'},
        {id='three',kind='match',label='three'},
      }))
      local session=assert(store:open_session('bounded'))
      local blocked,blocked_err=store:create({id='blocked',provider_id='test',workspace_id='ws',generation=2})
      session:close(); session:dispose()
      local next_set=assert(store:create({id='next',provider_id='test',workspace_id='ws',generation=2}))
      local empty=assert(store:finish('next','complete','complete'))
      local old_present=store:get('bounded')~=nil
      store:dispose()
      local aggregate=assert(require('workbench.services.results').new({max_sets=2,max_sessions=2,max_items=4,max_batch_items=2,max_bytes=512,max_total_bytes=96,max_item_bytes=128}))
      assert(aggregate:create({id='first',provider_id='test',workspace_id='ws',generation=1}))
      assert(aggregate:create({id='second',provider_id='test',workspace_id='ws',generation=1}))
      local accepted=assert(aggregate:merge('first',{{id='first-item',kind='match',label=string.rep('a',40)}}))
      local aggregate_overflow=assert(aggregate:merge('second',{{id='second-item',kind='match',label=string.rep('b',40)}}))
      local aggregate_status=aggregate:status()
      aggregate:dispose()
      return {
        visible_overflow=overflow.status=='partial' and overflow.completeness=='truncated' and overflow.item_count==2,
        referenced_history_protected=blocked==nil and blocked_err:find('history is full',1,true)~=nil,
        unreferenced_history_evicted=not old_present,
        empty_complete_is_complete=empty.status=='complete' and empty.item_count==0,
        aggregate_limit_visible=accepted.bytes<=96 and aggregate_overflow.status=='partial'
          and aggregate_overflow.completeness=='truncated' and aggregate_overflow.item_count==0 and aggregate_status.bytes<=96,
      }
    ]])
    expect.equality(result.visible_overflow, true)
    expect.equality(result.referenced_history_protected, true)
    expect.equality(result.unreferenced_history_evicted, true)
    expect.equality(result.empty_complete_is_complete, true)
    expect.equality(result.aggregate_limit_visible, true)
  end,

  ["preview is read-only and commit preserves native jumps and modified origin state"] = function()
    local result = evaluate([[
      local uv = vim.uv or vim.loop
      local base = vim.fn.tempname() .. '-wb08-navigation'
      assert(vim.fn.mkdir(base,'p') == 1)
      local origin_path = base .. '/origin.txt'
      local target_path = base .. '/result: target.txt'
      assert(vim.fn.writefile({'disk origin'},origin_path) == 0)
      assert(vim.fn.writefile({'first','emoji 😀 target','last'},target_path) == 0)
      vim.api.nvim_cmd({cmd='edit',args={origin_path}}, {})
      local origin_win, origin_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(origin_buf,0,-1,false,{'unsaved user line','second user line'})
      vim.bo[origin_buf].modified = true
      vim.api.nvim_win_set_cursor(origin_win,{2,3})
      local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
      local resource = assert(require('workbench.core.resource').from_path(target_path))
      local origin_resource = assert(require('workbench.core.resource').from_path(origin_path))
      local Location = require('workbench.core.location')
      local target_line = 'emoji 😀 target'
      local target_col = assert(target_line:find('target',1,true)) - 1
      local target = assert(Location.new(resource,{range={start={line=1,character=target_col},finish={line=1,character=target_col+6}},encoding='utf-8'}))
      local modified = assert(Location.new(origin_resource,{range={start={line=0,character=0},finish={line=0,character=4}},encoding='utf-8'}))
      local nav = assert(require('workbench.services.navigation').new({context_before=1,context_after=1}))
      local jumps_before = #vim.fn.getjumplist(0)[1]
      local seen
      assert(nav:preview(modified,'view',function(value) seen=value end))
      assert(vim.wait(3000,function() return seen ~= nil end,5))
      local jumps_after_preview = #vim.fn.getjumplist(0)[1]
      local preview_ok = seen.source == 'buffer' and seen.modified == true and seen.lines[1] == 'unsaved user line'
        and vim.api.nvim_buf_get_lines(origin_buf,0,-1,false)[1] == 'unsaved user line'
        and vim.bo[origin_buf].modified == true and vim.api.nvim_get_current_win() == origin_win
        and jumps_before == jumps_after_preview
      local rejected = nav:open(target,'current',origin_win,'view')
      local split = assert(nav:open(target,'vsplit',origin_win,'view'))
      local destination = vim.api.nvim_win_get_buf(split.win)
      local split_target_line = vim.api.nvim_win_get_cursor(split.win)[1]
      local returned = assert(nav:return_to_origin('view'))
      local return_origin_ok = returned.win == origin_win and vim.api.nvim_get_current_win() == origin_win
      local native_jump_before = #vim.fn.getjumplist(split.win)[1]
      vim.api.nvim_set_current_win(split.win)
      vim.api.nvim_cmd({cmd='normal',bang=true,args={string.char(15)}}, {})
      local native_jump_ok = vim.api.nvim_get_current_buf() == origin_buf
        or vim.api.nvim_get_current_win() == origin_win
      local origin_preserved = vim.api.nvim_buf_get_lines(origin_buf,0,-1,false)[1] == 'unsaved user line'
        and vim.bo[origin_buf].modified == true and vim.api.nvim_win_get_cursor(origin_win)[1] == origin_cursor[1]
      local values = {
        preview_read_only = preview_ok,
        preview_jump_delta = jumps_after_preview - jumps_before,
        modified_current_open_rejected = rejected == nil,
        split_commit_jump_delta = split.jumps_added,
        split_target_line = split_target_line,
        destination_valid = vim.api.nvim_buf_is_valid(destination),
        return_origin = return_origin_ok,
        origin_preserved = origin_preserved,
        native_jump_compatible = native_jump_ok and native_jump_before == 1,
      }
      nav:dispose()
      pcall(vim.api.nvim_win_close,split.win,true)
      pcall(vim.api.nvim_buf_delete,destination,{force=true})
      vim.bo[origin_buf].modified = false
      pcall(vim.api.nvim_win_close,origin_win,true)
      vim.fn.delete(base,'rf')
      return values
    ]])
    expect.equality(result.preview_read_only, true)
    expect.equality(result.preview_jump_delta, 0)
    expect.equality(result.modified_current_open_rejected, true)
    expect.equality(result.split_commit_jump_delta, 1)
    expect.equality(result.split_target_line, 2)
    expect.equality(result.destination_valid, true)
    expect.equality(result.return_origin, true)
    expect.equality(result.origin_preserved, true)
    expect.equality(result.native_jump_compatible, true)
  end,

  ["committing a same-buffer location creates exactly one native jump"] = function()
    local result = evaluate([[
      local path=vim.fn.tempname()..'-wb08-same-buffer'
      vim.fn.writefile({'one','two','three','four','five'},path)
      vim.api.nvim_cmd({cmd='edit',args={path}}, {})
      local win,buf=vim.api.nvim_get_current_win(),vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_cursor(win,{2,1})
      local before=#vim.fn.getjumplist(win)[1]
      local resource=assert(require('workbench.core.resource').from_path(path))
      local location=assert(require('workbench.core.location').new(resource,{range={start={line=4,character=1},finish={line=4,character=2}},encoding='utf-8'}))
      local nav=assert(require('workbench.services.navigation').new())
      local opened=assert(nav:open(location,'current',win,'same-buffer'))
      local jump_delta=opened.jumps_added
      local target_cursor=vim.api.nvim_win_get_cursor(win)
      vim.api.nvim_cmd({cmd='normal',bang=true,args={string.char(15)}}, {})
      local native_back=vim.api.nvim_get_current_buf()==buf and vim.api.nvim_win_get_cursor(win)[1]==2
      local returned=assert(nav:return_to_origin('same-buffer'))
      local values={jump_delta=jump_delta,target_line=target_cursor[1],native_back=native_back,return_window=returned.win==win}
      nav:dispose(); vim.bo[buf].modified=false; pcall(vim.api.nvim_win_close,win,true); vim.fn.delete(path)
      return values
    ]])
    expect.equality(result.jump_delta, 1)
    expect.equality(result.target_line, 5)
    expect.equality(result.native_back, true)
    expect.equality(result.return_window, true)
  end,

  ["stale ranges are rejected before an editor window or native jumplist is mutated"] = function()
    local result = evaluate([[
      local path=vim.fn.tempname()..'-wb08-stale'
      vim.fn.writefile({'only line'},path)
      local win,buf=vim.api.nvim_get_current_win(),vim.api.nvim_get_current_buf()
      local cursor=vim.api.nvim_win_get_cursor(win)
      local before=vim.fn.getjumplist(win)
      local location=assert(require('workbench.core.location').new(assert(require('workbench.core.resource').from_path(path)),{range={start={line=8,character=0},finish={line=8,character=1}},encoding='utf-8'}))
      local nav=assert(require('workbench.services.navigation').new())
      local opened,err=nav:open(location,'current',win,'stale')
      local after=vim.fn.getjumplist(win)
      local values={
        rejected=opened==nil and err.code=='stale_location' and err.message:find('outside',1,true)~=nil,
        focus_preserved=vim.api.nvim_get_current_win()==win and vim.api.nvim_win_get_buf(win)==buf,
        cursor_preserved=vim.deep_equal(vim.api.nvim_win_get_cursor(win),cursor),
        jump_history_preserved=vim.deep_equal(before,after),
        preflight_buffer_released=vim.fn.bufnr(path)<0,
      }
      nav:dispose(); vim.fn.delete(path)
      return values
    ]])
    expect.equality(result.rejected, true)
    expect.equality(result.focus_preserved, true)
    expect.equality(result.cursor_preserved, true)
    expect.equality(result.jump_history_preserved, true)
    expect.equality(result.preflight_buffer_released, true)
  end,

  ["vanished origins fall back without destroying the target and closed targets remain harmless"] = function()
    local result = evaluate([[
      local base = vim.fn.tempname() .. '-wb08-fallback'
      assert(vim.fn.mkdir(base,'p') == 1)
      local origin_path, target_path = base .. '/origin.txt', base .. '/target.txt'
      assert(vim.fn.writefile({'origin'},origin_path) == 0)
      assert(vim.fn.writefile({'target'},target_path) == 0)
      vim.api.nvim_cmd({cmd='edit',args={origin_path}}, {})
      local origin_win, origin_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local resource = assert(require('workbench.core.resource').from_path(target_path))
      local target = assert(require('workbench.core.location').new(resource))
      local nav = assert(require('workbench.services.navigation').new())
      local split = assert(nav:open(target,'split',origin_win,'view'))
      local target_buf = split.buf
      vim.api.nvim_win_close(origin_win,true)
      local restored = assert(nav:return_to_origin('view'))
      local fallback_ok = restored.fallback == true and vim.api.nvim_win_is_valid(restored.win)
        and vim.api.nvim_win_get_buf(restored.win) == origin_buf and vim.api.nvim_buf_is_valid(target_buf)
      local second = assert(nav:open(target,'tab',restored.win,'view'))
      local target_tab = vim.api.nvim_win_get_tabpage(second.win)
      local tab_jumps = second.jumps_added
      vim.api.nvim_win_close(second.win,true)
      local closed = nav:return_to_origin('view')
      local closed_target_safe = closed ~= nil and not vim.api.nvim_tabpage_is_valid(target_tab)
      nav:dispose()
      vim.fn.delete(base,'rf')
      return {fallback_origin=fallback_ok,closed_target_safe=closed_target_safe,tab_jumps=tab_jumps}
    ]])
    expect.equality(result.fallback_origin, true)
    expect.equality(result.closed_target_safe, true)
    expect.equality(result.tab_jumps, 1)
  end,

  ["preview reads are bounded, stale callbacks are rejected, and disposal releases pending requests"] = function()
    local result = evaluate([[
      local base = vim.fn.tempname() .. '-wb08-bounded-preview'
      assert(vim.fn.mkdir(base,'p') == 1)
      local first_path, second_path, huge_path = base..'/first.txt',base..'/second.txt',base..'/huge.txt'
      vim.fn.writefile({'first result'},first_path)
      vim.fn.writefile({'second result'},second_path)
      vim.fn.writefile({string.rep('x',1024*1024)},huge_path)
      local Resource=require('workbench.core.resource')
      local Location=require('workbench.core.location')
      local first=assert(Location.new(assert(Resource.from_path(first_path))))
      local second=assert(Location.new(assert(Resource.from_path(second_path))))
      local huge=assert(Location.new(assert(Resource.from_path(huge_path))))
      local nav=assert(require('workbench.services.navigation').new({max_scan_bytes=32,max_line_bytes=12,max_output_bytes=32,context_before=0,context_after=0,chunk_bytes=8}))
      local stale, latest
      assert(nav:preview(first,'churn',function(value) stale=value end))
      assert(nav:preview(second,'churn',function(value) latest=value end))
      assert(vim.wait(3000,function() return latest~=nil end,5))
      assert(vim.wait(3000,function() return nav:status().pending_reads==0 end,5))
      local bounded
      assert(nav:preview(huge,'bounded',function(value) bounded=value end))
      assert(vim.wait(3000,function() return bounded~=nil end,5))
      local pending_callback=false
      assert(nav:preview(huge,'dispose-me',function() pending_callback=true end))
      local before_dispose=nav:status().pending_reads
      nav:dispose()
      assert(vim.wait(3000,function() return nav:status().pending_reads==0 end,5))
      local output={
        stale_rejected=stale==nil,
        latest_is_second=latest.source=='disk' and latest.lines[1]=='second resul' and latest.truncated==true,
        bounded_complete_line=bounded.source=='disk' and bounded.truncated==true and #bounded.lines[1]<=12,
        pending_was_owned=before_dispose==1,
        disposed_callback_rejected=not pending_callback,
        no_pending_after_dispose=nav:status().pending_reads==0,
      }
      vim.fn.delete(base,'rf')
      return output
    ]])
    expect.equality(result.stale_rejected, true)
    expect.equality(result.latest_is_second, true)
    expect.equality(result.bounded_complete_line, true)
    expect.equality(result.pending_was_owned, true)
    expect.equality(result.disposed_callback_rejected, true)
    expect.equality(result.no_pending_after_dispose, true)
  end,

  ["quickfix export appends a typed snapshot after unrelated history without opening the list"] = function()
    local result = evaluate([[
      local one = vim.fn.tempname() .. '-qf-one'
      local two = vim.fn.tempname() .. '-qf-two'
      vim.fn.writefile({'one'},one); vim.fn.writefile({'two'},two)
      assert(vim.fn.setqflist({},' ',{items={{filename=one,lnum=1,col=1,text='user first'}},title='user first'}) == 0)
      assert(vim.fn.setqflist({},' ',{items={{filename=two,lnum=1,col=1,text='user second'}},title='user second'}) == 0)
      local first_id = vim.fn.getqflist({nr=1,id=0}).id
      local second_id = vim.fn.getqflist({nr=2,id=0}).id
      local path = vim.fn.tempname() .. '-qf-result.txt'
      vim.fn.writefile({'one','emoji 😀 x'},path)
      local resource = assert(require('workbench.core.resource').from_path(path))
      local location = assert(require('workbench.core.location').new(resource,{range={start={line=1,character=2},finish={line=1,character=4}},encoding='utf-8'}))
      local utf16 = assert(require('workbench.core.location').new(resource,{range={start={line=1,character=9},finish={line=1,character=10}},encoding='utf-16'}))
      local store = assert(require('workbench.services.results').new())
      assert(store:create({id='snapshot-1',provider_id='test',workspace_id='ws',generation=1}))
      assert(store:merge('snapshot-1',{
        {id='match-1',kind='match',label='  result\nlabel ',location=location},
        {id='match-2',kind='match',label='utf16',location=utf16},
        {id='folder',kind='file',label='folder'},
      }))
      local snapshot = assert(store:get('snapshot-1'))
      local before = vim.fn.win_getid()
      local exported = assert(require('workbench.adapters.quickfix').export(snapshot))
      local first_after = vim.fn.getqflist({nr=1,id=0,title=0})
      local second_after = vim.fn.getqflist({nr=2,id=0,title=0})
      local latest = vim.fn.getqflist({nr=0,id=0,title=0,context=0,items=1})
      local qf_win = vim.fn.getqflist({nr=0,winid=0}).winid
      local values = {
        appended_number=exported.number,
        previous_ids_preserved=first_after.id==first_id and second_after.id==second_id,
        previous_titles_preserved=first_after.title=='user first' and second_after.title=='user second',
        new_list_title=latest.title,
        context_id=latest.context.result_set_id,
        location_line=latest.items[1].lnum,
        location_column=latest.items[1].col,
        text=latest.items[1].text,
        item_id=latest.items[1].user_data.workbench_item_id,
        utf16_column_omitted=latest.items[2].col==0,
        no_qf_window=qf_win==nil or qf_win==0,
        focus_preserved=vim.fn.win_getid()==before,
        exported_count=exported.exported,
        skipped_no_location=exported.skipped.no_location,
      }
      store:dispose(); vim.fn.delete(one); vim.fn.delete(two); vim.fn.delete(path)
      return values
    ]])
    expect.equality(result.appended_number, 3)
    expect.equality(result.previous_ids_preserved, true)
    expect.equality(result.previous_titles_preserved, true)
    expect.equality(result.new_list_title, "Workbench: snapshot-1")
    expect.equality(result.context_id, "snapshot-1")
    expect.equality(result.location_line, 2)
    expect.equality(result.location_column, 3)
    expect.equality(result.text, "result label")
    expect.equality(result.item_id, "match-1")
    expect.equality(result.no_qf_window, true)
    expect.equality(result.focus_preserved, true)
    expect.equality(result.utf16_column_omitted, true)
    expect.equality(result.exported_count, 2)
    expect.equality(result.skipped_no_location, 1)
  end,

  ["preview view owns only a read-only scratch split and closes idempotently"] = function()
    local result = evaluate([[
      local path = vim.fn.tempname() .. '-wb08-preview-ui'
      vim.fn.writefile({'disk text'},path)
      local origin_win, origin_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local nav = assert(require('workbench.services.navigation').new())
      local view = assert(require('workbench.ui.preview').new({navigation=nav}))
      local location = assert(require('workbench.core.location').new(assert(require('workbench.core.resource').from_path(path))))
      local seen
      assert(view:preview(location,'preview-ui',function(value) seen=value end))
      assert(vim.wait(3000,function() return seen~=nil end,5))
      local status = view:status()
      local view_buf = status.buf
      local lines = vim.api.nvim_buf_get_lines(view_buf,0,-1,false)
      local output = {
        source_focus_kept=vim.api.nvim_get_current_win()==origin_win,
        source_buffer_kept=vim.api.nvim_win_get_buf(origin_win)==origin_buf,
        preview_nofile=vim.bo[view_buf].buftype=='nofile' and vim.b[view_buf].workbench_preview==true,
        preview_read_only=vim.bo[view_buf].modifiable==false and vim.bo[view_buf].modified==false,
        body_visible=table.concat(lines,'\n'):find('disk text',1,true)~=nil,
        preview_window_valid=vim.api.nvim_win_is_valid(status.win),
      }
      view:close(); view:close()
      output.closed=view:status().open==false
      view:dispose(); nav:dispose(); vim.fn.delete(path)
      return output
    ]])
    expect.equality(result.source_focus_kept, true)
    expect.equality(result.source_buffer_kept, true)
    expect.equality(result.preview_nofile, true)
    expect.equality(result.preview_read_only, true)
    expect.equality(result.body_visible, true)
    expect.equality(result.preview_window_valid, true)
    expect.equality(result.closed, true)
  end,

  ["preview rendering escapes terminal controls and keeps clipped UTF-8 valid"] = function()
    local result = evaluate([[
      local render=require('workbench.ui.preview').render_lines
      local raw='safe '..string.char(27)..'[2J '..string.char(255)..' 🙂'
      local rendered=render({path='line\nbreak',target_line=0,first_line=0,target_index=1,lines={raw}},80)
      local body=rendered[2]:match('│ (.*)') or ''
      local clipped=render({path='x',target_line=0,first_line=0,target_index=1,lines={'a🙂b'}},3)[2]:match('│ (.*)') or ''
      local path_header=rendered[1]
      return {
        escapes_escape=not body:find(string.char(27),1,true) and body:find('\\x1B',1,true)~=nil,
        escapes_invalid_byte=body:find('\\xFF',1,true)~=nil,
        preserves_unicode=body:find('🙂',1,true)~=nil,
        escapes_path_newline=path_header:find('\\x0A',1,true)~=nil,
        clipped_bytes=#clipped,
        clipped_prefix=clipped=='a',
      }
    ]])
    expect.equality(result.escapes_escape, true)
    expect.equality(result.escapes_invalid_byte, true)
    expect.equality(result.preserves_unicode, true)
    expect.equality(result.escapes_path_newline, true)
    expect.equality(result.clipped_bytes <= 3, true)
    expect.equality(result.clipped_prefix, true)
  end,

  ["preview view renders loading and actionable read-error states"] = function()
    local result = evaluate([[
      local path=vim.fn.tempname()..'-wb08-preview-states'
      vim.fn.writefile({'source'},path)
      local pending
      local navigation={
        preview=function(_,location,session,callback)
          pending=callback
          return {cancel=function() return true end}
        end,
        cancel_preview=function() return true end,
      }
      local view=assert(require('workbench.ui.preview').new({navigation=navigation,orientation='horizontal'}))
      local location=assert(require('workbench.core.location').new(assert(require('workbench.core.resource').from_path(path))))
      assert(view:preview(location,'states'))
      local loading=table.concat(vim.api.nvim_buf_get_lines(view.buf,0,-1,false),'\n')
      pending({code='read_error',message='permission denied'})
      local error=table.concat(vim.api.nvim_buf_get_lines(view.buf,0,-1,false),'\n')
      local output={loading=loading:find('Loading bounded source context',1,true)~=nil,read_error=error:find('permission denied',1,true)~=nil}
      view:dispose(); vim.fn.delete(path)
      return output
    ]])
    expect.equality(result.loading, true)
    expect.equality(result.read_error, true)
  end,

  ["one hundred preview-window cycles leave no view buffers or user-window changes"] = function()
    local result = evaluate([[
      vim.o.columns,vim.o.lines=120,35
      local win,buf=vim.api.nvim_get_current_win(),vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf,0,-1,false,{'USER CONTENT'})
      vim.bo[buf].modified=true
      local original_windows=#vim.api.nvim_list_wins()
      local nav=assert(require('workbench.services.navigation').new())
      local released=0
      for cycle=1,100 do
        local view=assert(require('workbench.ui.preview').new({navigation=nav,session_id='cycle-'..cycle}))
        assert(view:show({path='/tmp/example.txt',target_line=0,first_line=0,target_index=1,lines={'preview'}}))
        local owned=view.buf
        assert(view:close())
        if not vim.api.nvim_buf_is_valid(owned) then released=released+1 end
        assert(view:dispose())
      end
      local output={
        released_buffers=released,
        window_count=#vim.api.nvim_list_wins(),
        original_windows=original_windows,
        original_focus=vim.api.nvim_get_current_win()==win,
        original_buffer=vim.api.nvim_win_get_buf(win)==buf,
        modified=vim.bo[buf].modified,
        content=vim.api.nvim_buf_get_lines(buf,0,1,false)[1],
      }
      nav:dispose(); vim.bo[buf].modified=false
      return output
    ]])
    expect.equality(result.released_buffers, 100)
    expect.equality(result.window_count, result.original_windows)
    expect.equality(result.original_focus, true)
    expect.equality(result.original_buffer, true)
    expect.equality(result.modified, true)
    expect.equality(result.content, "USER CONTENT")
  end,

  ["buffer navigation opens the exact unsaved buffer and returns to its captured origin"] = function()
    local result = evaluate([[
      local root=vim.fn.tempname()..'-wb18-buffer-nav'; assert(vim.fn.mkdir(root,'p')==1)
      local origin_path,target_path=root..'/origin.txt',root..'/dirty.txt'
      vim.fn.writefile({'origin'},origin_path); vim.fn.writefile({'disk version'},target_path)
      vim.api.nvim_cmd({cmd='edit',args={origin_path}}, {})
      local origin=vim.api.nvim_get_current_win(); local origin_buf=vim.api.nvim_get_current_buf()
      local target=vim.fn.bufadd(target_path); vim.fn.bufload(target)
      vim.api.nvim_buf_set_lines(target,0,-1,false,{'unsaved first','unsaved second needle'})
      vim.bo[target].modified=true
      local resource=assert(require('workbench.core.resource').from_path(target_path))
      local location=assert(require('workbench.core.location').new(resource,{range={start={line=1,character=15},finish={line=1,character=21}},encoding='utf-8'}))
      local nav=assert(require('workbench.services.navigation').new())
      local opened=assert(nav:open_buffer(target,'split',origin,'buffer-navigation',location))
      local exact=vim.api.nvim_win_get_buf(opened.win)==target and vim.bo[target].modified
        and vim.api.nvim_buf_get_lines(target,0,-1,false)[1]=='unsaved first'
        and vim.api.nvim_win_get_cursor(opened.win)[1]==2
      local returned=assert(nav:return_to_origin('buffer-navigation'))
      local back=returned.win==origin and vim.api.nvim_get_current_win()==origin and vim.api.nvim_get_current_buf()==origin_buf
      nav:dispose(); pcall(vim.api.nvim_win_close,opened.win,true); vim.bo[target].modified=false
      vim.api.nvim_buf_delete(target,{force=true}); vim.fn.delete(root,'rf')
      return {exact=exact,returned=back}
    ]])
    expect.equality(result.exact, true)
    expect.equality(result.returned, true)
  end,
})
