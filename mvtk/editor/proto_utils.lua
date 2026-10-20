-- mvtk/editor/proto_utils.lua
-- Text-formatting helpers for generating and parsing Defold proto (.go /
-- .collection / .tilemap) content. Called from multiple editor hook files.

local ResourceText = require "mvtk.editor.resource_text"
local M = {}

-- Format a number for proto text output (short, no trailing zeros, safe
-- against inf/nan which Java's proto parser rejects).
function M.fmt_num(n)
    n = tonumber(n) or 0
    if n ~= n then n = 0 end
    if n == math.huge then n = 0 end
    if n == -math.huge then n = 0 end
    local s = string.format("%.6f", n)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

-- Escape a Lua string for embedding inside a proto double-quoted literal.
function M.proto_escape(value)
    local s = tostring(value or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\t", "\\t")
    s = s:gsub('"', '\\"')
    return s
end

-- Coerce a value to "true"/"false" using the same rules as Tiled property
-- conventions (accepts booleans, 0/1, yes/no, on/off). Falls back to the
-- supplied default when the value is nil or unrecognized.
function M.bool_to_proto(value, default)
    if value == nil then
        value = default
    end
    local t = type(value)
    if t == "boolean" then
        return value and "true" or "false"
    end
    if t == "number" then
        return value ~= 0 and "true" or "false"
    end
    local s = tostring(value or ""):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then
        return "true"
    end
    if s == "false" or s == "0" or s == "no" or s == "off" then
        return "false"
    end
    return default and "true" or "false"
end

-- Split on "\n" only. A trailing empty line caused by a terminating newline
-- is discarded so callers can rebuild the file with join + final "\n".
function M.split_proto_lines(text)
    local lines = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if #lines > 0 and lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines
end

-- CRLF-aware splitter. Normalizes CRLF → LF before splitting. The trailing
-- empty slot introduced by the terminating newline is retained (matches the
-- long-standing behavior of this variant in editor_core.lua).
function M.split_text_lines(text)
    local out = {}
    local src = tostring(text or ""):gsub("\r\n", "\n")
    for line in (src .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    return out
end

-- CRLF-aware splitter that also reports whether the original used CRLF line
-- endings so callers that rewrite the file can preserve the original style.
-- Drops the trailing empty slot.
function M.split_lines_with_crlf(text)
    local out = {}
    local src = tostring(text or "")
    local use_crlf = src:find("\r\n", 1, true) ~= nil
    src = src:gsub("\r\n", "\n")
    for line in (src .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
    end
    if #out > 0 and out[#out] == "" then
        out[#out] = nil
    end
    return out, use_crlf
end

-- Signed count of structural braces on a single proto text line. Embedded
-- component data and resource names may contain literal braces; comments and
-- quoted strings must not affect the surrounding resource's nesting depth.
function M.brace_delta(line)
    local delta, pos, quoted = 0, 1, false
    while pos <= #line do
        local c = line:sub(pos, pos)
        if quoted then
            if c == "\\" then pos = pos + 1
            elseif c == '"' then quoted = false end
        elseif c == '"' then quoted = true
        elseif c == "#" or line:sub(pos, pos + 1) == "//" then break
        elseif c == "{" then delta = delta + 1
        elseif c == "}" then delta = delta - 1 end
        pos = pos + 1
    end
    return delta
end

-- Remove embedded component blocks whose id is exactly "sprite". Referenced
-- components and differently named sprite effects (for example water's
-- "distortion") are intentionally untouched. Returns original text unchanged
-- when no matching block exists, preserving byte stability for default-on
-- generation paths.
function M.strip_sprite_components(text)
    local source = tostring(text or "")
    local doc = ResourceText.parse(source)
    local removed = 0
    for _, field in ipairs(ResourceText.all(doc.root, "embedded_components")) do
        if field.node and ResourceText.value(field.node, "id") == "sprite" then
            local first, last = field.start, field.finish
            -- Keep the established output for blocks occupying whole lines,
            -- including CRLF. Compact blocks can share a line with a retained
            -- component, so only remove their exact span in that case.
            local line_start = first
            while line_start > 1 and source:sub(line_start - 1, line_start - 1) ~= "\n" do
                line_start = line_start - 1
            end
            local line_end = source:find("\n", last + 1, true) or (#source + 1)
            if source:sub(line_start, first - 1):match("^[ \t]*$")
                and source:sub(last + 1, line_end - 1):match("^[ \t\r]*$") then
                first, last = line_start, math.min(line_end, #source)
            end
            ResourceText.remove(doc, { start = first, finish = last })
            removed = removed + 1
        end
    end
    if removed == 0 then return source, 0 end
    return ResourceText.render(doc), removed
end

return M
