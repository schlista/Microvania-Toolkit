-- mvtk/editor/layout_editor/lua_serializer.lua
--
-- Pretty-printer for Lua tables, used by the layout editor when writing
-- world_layout.lua and similar export artifacts. Output is human-editable Lua
-- (sorted keys, deterministic indentation, integers without decimal noise).
--
-- Extracted verbatim from controller.lua so the controller stops carrying
-- generic data-format helpers.
--
-- Public API:
--   M.serialize_value(value)            - returns the value as a Lua expression
--   M.serialize_layout_to_lua(layout)   - returns "return <value>\n" (module form)

local M = {}

local function is_array(tbl)
    if type(tbl) ~= "table" then return false end
    local count = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    return count == #tbl
end

local function format_number(n)
    if type(n) ~= "number" then return tostring(n) end
    -- Snap near-integer floats so the export reads as `42` not `42.0000`.
    if math.abs(n - math.floor(n + 0.5)) < 1e-6 then
        return string.format("%d", math.floor(n + 0.5))
    end
    return string.format("%.4f", n)
end

local function serialize_value(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "number" then
        return format_number(value)
    elseif t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        local next_indent = indent .. "  "
        if is_array(value) then
            if #value == 0 then return "{}" end
            local parts = {"{\n"}
            for i, v in ipairs(value) do
                parts[#parts + 1] = next_indent .. serialize_value(v, next_indent)
                parts[#parts + 1] = (i < #value) and ",\n" or "\n"
            end
            parts[#parts + 1] = indent .. "}"
            return table.concat(parts)
        else
            local keys = {}
            for k, _ in pairs(value) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            if #keys == 0 then return "{}" end
            local parts = {"{\n"}
            for i, key in ipairs(keys) do
                local serialized = serialize_value(value[key], next_indent)
                parts[#parts + 1] = string.format("%s%s = %s", next_indent, key, serialized)
                parts[#parts + 1] = (i < #keys) and ",\n" or "\n"
            end
            parts[#parts + 1] = indent .. "}"
            return table.concat(parts)
        end
    else
        return "nil"
    end
end

function M.serialize_value(value)
    return serialize_value(value, "")
end

function M.serialize_layout_to_lua(layout)
    return "return " .. serialize_value(layout, "") .. "\n"
end

return M
