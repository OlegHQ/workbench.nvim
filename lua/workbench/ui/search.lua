local Resource = require("workbench.core.resource")

local M = { page_size = 200, max_page_size = 1000 }

local function compact(value, limit)
  value = tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " ")
  if #value > limit then
    local low, high = 0, vim.fn.strchars(value)
    while low < high do
      local middle = math.floor((low + high + 1) / 2)
      if #vim.fn.strcharpart(value, 0, middle, true) <= limit - 3 then low = middle else high = middle - 1 end
    end
    value = vim.fn.strcharpart(value, 0, low, true) .. "..."
  end
  return value
end

M.compact = compact

local function scope_label(scope, workspace)
  if type(scope) ~= "table" then return "scope unavailable" end
  if scope.kind == "all_roots" then return "workspace" end
  local root = workspace.roots[1].path
  if scope.kind == "open_buffers" then return "open buffers" end
  local path = scope.path or (scope.resource and scope.resource.path) or ""
  if scope.kind == "folder" then
    local relative = vim.fs.relpath(root, path)
    return "folder:" .. Resource.escape_display(relative == "." and "." or relative or path)
  end
  if scope.kind == "file" then
    return "current file:" .. Resource.escape_display(vim.fs.basename(path))
  end
  return tostring(scope.kind)
end

function M.title(state)
  return "Search"
end

function M.header(state)
  local query = compact(state.query, 80)
  if query == "" then query = "(empty query)" end
  local flags = state.flags or {}
  local policy = state.workspace.policy or {}
  local include = policy.include or {}
  local exclude = policy.exclude or {}
  local function patterns(list)
    local values = {}
    for index = 1, math.min(#list, 3) do values[#values + 1] = compact(list[index], 36) end
    if #list > 3 then values[#values + 1] = "…" end
    return #values == 0 and "none" or table.concat(values, ",")
  end
  local lines = {
    "Query: " .. compact(query, 160),
    string.format("Scope: %s  ·  %s  ·  %s-case%s%s", scope_label(state.scope, state.workspace), flags.fixed and "literal" or "regex", flags.case or "smart", flags.word and " · whole word" or "", state.policy_override and " · explicit current-file target overrides ignore rules" or ""),
    state.scope.kind == "open_buffers" and "Policy: explicit named-buffer set · workspace hidden/ignore globs do not apply" or string.format("Policy: hidden %s · ignored %s · include [%s] · exclude [%s]", policy.hidden or "exclude", policy.ignored or "exclude", patterns(include), patterns(exclude)),
    string.format("State: %s%s", state.phase or "Ready", state.total and state.total > 0 and string.format(" · matches %d-%d of %d", (state.offset or 0) + 1, math.min((state.offset or 0) + (state.visible_matches or 0), state.total), state.total) or ""),
  }
  if state.completeness == "truncated" then lines[4] = lines[4] .. " · partial/capped" end
  if state.scope.kind == "open_buffers" then
    lines[#lines + 1] = string.format("Source: in-memory text of %d named loaded buffer snapshot%s%s", state.snapshot_count or 0,
      (state.snapshot_count or 0) == 1 and "" or "s",
      state.snapshot_stale_count and state.snapshot_stale_count > 0 and string.format(" · %d changed since capture", state.snapshot_stale_count) or "")
  elseif state.snapshot_count ~= nil and state.snapshot_count > 0 then
    lines[#lines + 1] = string.format("Source: disk plus %d modified buffer snapshot%s%s", state.snapshot_count, state.snapshot_count == 1 and "" or "s",
      state.snapshot_stale_count and state.snapshot_stale_count > 0 and string.format(" · %d changed since capture", state.snapshot_stale_count) or "")
  elseif state.snapshot_count ~= nil and state.modified_count and state.modified_count > 0 then
    lines[#lines + 1] = string.format("Source: no modified snapshot captured · %d buffer%s omitted", state.modified_count, state.modified_count == 1 and "" or "s")
  elseif state.modified_count and state.modified_count > 0 then
    lines[#lines + 1] = string.format("Disk contents only; %d modified buffer%s not captured", state.modified_count, state.modified_count == 1 and "" or "s")
  end
  if state.snapshot_skipped_count and state.snapshot_skipped_count > 0 then
    lines[#lines + 1] = string.format("Incomplete working set · %d buffer%s exceeded snapshot limits", state.snapshot_skipped_count, state.snapshot_skipped_count == 1 and "" or "s")
  end
  return lines
end

function M.project(page, opts)
  opts = opts or {}
  local groups, ordered_groups = {}, {}
  for _, item in ipairs(page and page.items or {}) do
    local location = item.location or {}
    local resource = location.resource or {}
    local uri = resource.uri or ("missing:" .. item.id)
    local group = groups[uri]
    if not group then
      local label = resource.display_path or "[unknown file]"
      if resource.path then
        local relative = opts.root_path and vim.fs.relpath(opts.root_path, resource.path)
        label = Resource.escape_display(relative or resource.path)
      end
      group = {
        id = "file:" .. uri,
        kind = "file",
        label = label,
        detail = "0 matches",
        expandable = true,
        payload = { uri = uri, path = resource.path },
        count = 0,
      }
      groups[uri] = group
      ordered_groups[#ordered_groups + 1] = group
    end
    group.count = group.count + 1
    local line = item.payload and item.payload.line_number or (location.range and location.range.start.line + 1) or "?"
    local column = location.range and location.range.start.character + 1 or nil
    local detail = column and string.format("%s:%s", line, column) or tostring(line)
    group._items = group._items or {}
    group._items[#group._items + 1] = {
      id = item.id,
      kind = "match",
      parent_id = group.id,
      label = (opts.marked and opts.marked[item.id] and "[x] " or "") .. compact(item.label, 240),
      detail = detail,
      location = item.location,
      payload = item.payload,
    }
  end

  local result = {}
  if opts.notice then
    result[#result + 1] = {
      id = "notice:" .. tostring(opts.notice.id or "state"),
      kind = "notice",
      label = compact(opts.notice.label or "", 240),
      detail = compact(opts.notice.detail or "", 120),
      selectable = false,
    }
  end
  local expanded = {}
  for _, group in ipairs(ordered_groups) do
    group.detail = string.format("%d match%s", group.count, group.count == 1 and "" or "es")
    result[#result + 1] = {
      id = group.id,
      kind = group.kind,
      label = group.label,
      detail = group.detail,
      expandable = true,
      payload = group.payload,
    }
    expanded[group.id] = true
    for _, item in ipairs(group._items) do result[#result + 1] = item end
  end
  return result, expanded, {
    visible_matches = page and #page.items or 0,
    offset = page and page.offset or 0,
    next_offset = page and page.next_offset or nil,
    total_matches = page and page.total or 0,
  }
end

function M.help_lines(action_projection)
  local lines = {
    "/: query   r: rerun   x: cancel   a/z: next/previous results",
    "Enter/o: open result   p: preview   R: return to origin",
    "s: folder scope   F: current file   B: open buffers   u: resume history",
    "l: literal/regex   c: case   H: hidden   I: ignored",
    "Open-buffer search uses one captured ripgrep-matched snapshot set; modified files replace disk matches.",
    "m: mark/unmark match   X: review literal replacement (single-line only)",
  }
  for _, action in ipairs(action_projection or {}) do
    local state = action.available.enabled and "available" or (action.available.reason or "unavailable")
    lines[#lines + 1] = string.format("%s — %s (%s)", action.id, action.title, compact(state, 96))
    if #lines >= 14 then break end
  end
  return lines
end

return M
