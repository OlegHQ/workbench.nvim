local Resource = require("workbench.core.resource")

local M = {}

local encodings = { ["utf-8"] = true, ["utf-16"] = true, ["utf-32"] = true }

local function integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function copy_range(range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range.finish) ~= "table" then
    return nil, "range must have start and finish positions"
  end
  local result = {}
  for _, name in ipairs({ "start", "finish" }) do
    local position = range[name]
    if not integer(position.line) or not integer(position.character) then
      return nil, name .. " position must use non-negative integer line and character values"
    end
    result[name] = { line = position.line, character = position.character }
  end
  return result
end

function M.new(resource, opts)
  opts = opts or {}
  if type(resource) ~= "table" or type(resource.uri) ~= "string" or type(resource.scheme) ~= "string" then
    return nil, "location requires a valid resource"
  end

  local result = { resource = Resource.copy(resource) }
  if opts.range ~= nil then
    if not encodings[opts.encoding] then return nil, "range encoding must be utf-8, utf-16, or utf-32" end
    local range, err = copy_range(opts.range)
    if not range then return nil, err end
    if range.finish.line < range.start.line
      or (range.finish.line == range.start.line and range.finish.character < range.start.character) then
      return nil, "range finish precedes range start"
    end
    result.range = range
    result.encoding = opts.encoding
  elseif opts.encoding ~= nil then
    return nil, "encoding is only valid when a range is present"
  end

  for _, name in ipairs({ "version", "client_id" }) do
    local value = opts[name]
    if value ~= nil then
      if not integer(value) then return nil, name .. " must be a non-negative integer" end
      result[name] = value
    end
  end
  return result
end

local function codepoint_width(text, index)
  local first = text:byte(index)
  if not first then return nil end
  if first < 0x80 then return 1, 1 end

  local width, minimum, value
  if first >= 0xC2 and first <= 0xDF then
    width, minimum, value = 2, 0x80, first - 0xC0
  elseif first >= 0xE0 and first <= 0xEF then
    width, minimum, value = 3, 0x800, first - 0xE0
  elseif first >= 0xF0 and first <= 0xF4 then
    width, minimum, value = 4, 0x10000, first - 0xF0
  else
    return nil, "target text contains invalid UTF-8"
  end

  if index + width - 1 > #text then return nil, "target text contains truncated UTF-8" end
  for offset = 1, width - 1 do
    local byte = text:byte(index + offset)
    if byte < 0x80 or byte > 0xBF then return nil, "target text contains invalid UTF-8" end
    value = value * 64 + byte - 0x80
  end
  if value < minimum or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) then
    return nil, "target text contains invalid UTF-8"
  end
  return width, value
end

local function to_byte_column(text, character, encoding)
  if character == 0 then return 0 end
  if encoding == "utf-8" then
    if character > #text then return nil, "UTF-8 column exceeds target line" end
    local index, column = 1, 0
    while index <= #text and column < character do
      local width, err = codepoint_width(text, index)
      if not width then return nil, err end
      index, column = index + width, column + width
    end
    if column ~= character then return nil, "UTF-8 column splits a code point" end
    return character
  end

  local index, units = 1, 0
  while index <= #text do
    local width, codepoint_or_error = codepoint_width(text, index)
    if not width then return nil, codepoint_or_error end
    local codepoint = codepoint_or_error
    local consumed = encoding == "utf-16" and codepoint > 0xFFFF and 2 or 1
    if units + consumed > character then return nil, "column splits an encoded code point" end
    if units + consumed == character then return index + width - 1 end
    units, index = units + consumed, index + width
  end
  if units == character then return #text end
  return nil, encoding:upper() .. " column exceeds target line"
end

function M.resolve_range(location, lines)
  if type(location) ~= "table" or type(location.range) ~= "table" or not encodings[location.encoding] then
    return nil, "location has no explicitly encoded range"
  end
  if type(lines) ~= "table" then return nil, "target buffer lines are unavailable" end
  local resolved = {}
  for _, name in ipairs({ "start", "finish" }) do
    local position = location.range[name]
    local text = lines[position.line + 1]
    if type(text) ~= "string" then return nil, name .. " line is outside the target buffer" end
    local column, err = to_byte_column(text, position.character, location.encoding)
    if column == nil then return nil, name .. ": " .. err end
    resolved[name] = { line = position.line, character = column }
  end
  if resolved.finish.line < resolved.start.line
    or (resolved.finish.line == resolved.start.line and resolved.finish.character < resolved.start.character) then
    return nil, "resolved range finish precedes start"
  end
  return resolved
end

return M
