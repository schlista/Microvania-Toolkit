-- Persistent integrity checks must not depend on Defold's debug reverse-hash
-- cache. Hash keys and values use their numeric identity, even after a restart.
local M = {}

local function scalar(value)
    local kind = type(value)
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind == "number" then return "n" .. (value == 0 and "0" or string.format("%.17g", value)) .. ";" end
    if kind == "boolean" then return value and "b1" or "b0" end
    if kind == "userdata" then return "h" .. hash_to_hex(value) .. ";" end
    error("Unsupported save checksum type: " .. kind)
end

function M.compute(data)
    local buffer = {}
    local function visit(value, depth, is_meta)
        if type(value) ~= "table" then
            buffer[#buffer+1] = scalar(value)
            return
        end
        buffer[#buffer+1] = "{"
        local keys = {}
        for key in pairs(value) do
            if not (is_meta and key == "checksum") then
                keys[#keys+1] = {key=key, encoded=scalar(key)}
            end
        end
        table.sort(keys, function(a,b) return a.encoded < b.encoded end)
        for _,entry in ipairs(keys) do
            buffer[#buffer+1] = entry.encoded
            visit(value[entry.key], depth+1, depth == 0 and entry.key == "meta")
        end
        buffer[#buffer+1] = "}"
    end
    visit(data, 0, false)
    -- The prefix versions the checksum algorithm, independently of save schema.
    return "v2:" .. hash_to_hex(hash(table.concat(buffer)))
end

return M
