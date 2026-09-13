local M = {}

local function utf8_sequence(value, index)
  local first = value:byte(index)
  local width, minimum, codepoint
  if first >= 0xC2 and first <= 0xDF then
    width, minimum, codepoint = 2, 0x80, first - 0xC0
  elseif first >= 0xE0 and first <= 0xEF then
    width, minimum, codepoint = 3, 0x800, first - 0xE0
  elseif first >= 0xF0 and first <= 0xF4 then
    width, minimum, codepoint = 4, 0x10000, first - 0xF0
  else
    return nil
  end
  if index + width - 1 > #value then return nil end
  for offset = 1, width - 1 do
    local byte = value:byte(index + offset)
    if byte < 0x80 or byte > 0xBF then return nil end
    codepoint = codepoint * 64 + byte - 0x80
  end
  if codepoint < minimum or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
    return nil
  end
  return width, codepoint
end

local function escape_display(value)
  local non_ascii = "[" .. string.char(0x80) .. "-" .. string.char(0xFF) .. "]"
  if not value:find(":", 1, true) and not value:find("\\", 1, true)
    and not value:find("%c") and not value:find(non_ascii) then
    return value
  end
  local out = {}
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    if byte == 92 then
      out[#out + 1] = "\\\\"
    elseif byte == 58 then
      out[#out + 1] = "\\:"
    elseif byte < 32 or byte == 127 then
      out[#out + 1] = string.format("\\x%02X", byte)
    elseif byte >= 0x80 then
      local width, codepoint = utf8_sequence(value, index)
      if not width then
        out[#out + 1] = string.format("\\x%02X", byte)
      elseif codepoint >= 0x80 and codepoint <= 0x9F then
        out[#out + 1] = string.format("\\u%04X", codepoint)
        index = index + width - 1
      else
        out[#out + 1] = value:sub(index, index + width - 1)
        index = index + width - 1
      end
    else
      out[#out + 1] = value:sub(index, index)
    end
    index = index + 1
  end
  return table.concat(out)
end

function M.normalize_absolute_path(path)
  if type(path) ~= "string" or path == "" then
    return nil, "path must be a non-empty absolute path"
  end
  local separator = package.config:sub(1, 1)
  local absolute
  if separator == "\\" then
    absolute = path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
  else
    absolute = path:sub(1, 1) == "/"
  end
  if not absolute then
    return nil, "path must be absolute; pass an explicit workspace base"
  end
  return vim.fs.normalize(path)
end

function M.from_path(path, opts)
  opts = opts or {}
  local normalized, err = M.normalize_absolute_path(path)
  if not normalized then return nil, err end

  local alias = opts.display_path or path
  local normalized_alias, alias_err = M.normalize_absolute_path(alias)
  if not normalized_alias then return nil, "display alias: " .. alias_err end

  local ok, uri = pcall(vim.uri_from_fname, normalized)
  if not ok then return nil, "Neovim could not encode the file path as a URI" end
  return {
    uri = uri,
    scheme = "file",
    path = normalized,
    workspace_id = opts.workspace_id,
    display_path = escape_display(normalized_alias),
  }
end

function M.from_uri(uri, opts)
  opts = opts or {}
  if type(uri) ~= "string" then return nil, "URI must be a string" end
  local scheme = uri:match("^([%a][%w+%.%-]*):")
  if not scheme then return nil, "URI must have a valid scheme" end
  scheme = scheme:lower()

  if scheme == "file" then
    local ok, path = pcall(vim.uri_to_fname, uri)
    if not ok or type(path) ~= "string" then return nil, "invalid file URI" end
    return M.from_path(path, { workspace_id = opts.workspace_id, display_path = opts.display_path or path })
  end

  return {
    uri = uri,
    scheme = scheme,
    workspace_id = opts.workspace_id,
    display_path = escape_display(opts.display_path or uri),
  }
end

function M.copy(resource)
  if type(resource) ~= "table" then return nil end
  local result = {}
  for key, value in pairs(resource) do result[key] = value end
  return result
end

function M.escape_display(value)
  if type(value) ~= "string" then return "" end
  return escape_display(value)
end

return M
