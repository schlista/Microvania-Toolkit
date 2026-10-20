-- mvtk/elevators/elevator_identity.lua
--
-- Stable registry keys for authored elevator and node ids. Defold can reverse
-- hashes in debug bundles, but deliberately omits that lookup table in release
-- bundles. Registry identity must therefore be derived from the hash value,
-- never from tostring(hash) or a recovered debug name.

local M = {}

local ELEVATOR_PREFIX = "@elevator_hash:"
local NODE_PREFIX = "@elevator_node_hash:"

local function trim(value)
    if value == nil then return nil end
    local text = tostring(value):match("^%s*(.-)%s*$") or ""
    return text ~= "" and text or nil
end

local function usable_hex(value)
    local converter = rawget(_G, "hash_to_hex")
    if type(converter) ~= "function" then return nil end
    local ok, result = pcall(converter, value)
    if not ok then return nil end
    local text = trim(result)
    if not text then return nil end
    text = text:gsub("^0[xX]", ""):lower()
    if text == "" or text:match("^0+$") then return nil end
    return text
end

local function canonical_key(value, prefix)
    if value == nil then return nil end
    if type(value) == "string" and value:sub(1, #prefix) == prefix then
        return value
    end

    local source = value
    if type(value) == "string" then
        local text = trim(value)
        if not text or text == "0000000000000000" then return nil end
        local hasher = rawget(_G, "hash")
        if type(hasher) == "function" then
            local ok, hashed = pcall(hasher, text)
            if ok then source = hashed end
        else
            return prefix .. "name:" .. text
        end
    end

    local hex = usable_hex(source)
    if hex then return prefix .. hex end

    -- Plain-Lua tests commonly model hash() as the identity function. Keep
    -- that environment deterministic while production Defold uses the hex
    -- branch above. Opaque userdata remains a stable table key as a final
    -- compatibility fallback, though supported Defold versions expose
    -- hash_to_hex().
    if type(source) == "string" or type(source) == "number" then
        local text = trim(source)
        if not text or text == "0000000000000000" then return nil end
        return prefix .. "name:" .. text
    end
    return source
end

function M.elevator_key(value)
    return canonical_key(value, ELEVATOR_PREFIX)
end

function M.node_key(value)
    return canonical_key(value, NODE_PREFIX)
end

-- Authored strings are retained only for diagnostics, generated resource
-- paths, persistence, and public snapshots. They are never used as the
-- production registry key.
function M.authored_id(value)
    if type(value) ~= "string" then return nil end
    if value:sub(1, #ELEVATOR_PREFIX) == ELEVATOR_PREFIX
        or value:sub(1, #NODE_PREFIX) == NODE_PREFIX
    then
        return nil
    end
    local text = trim(value)
    if not text or text == "0000000000000000" then return nil end
    return text
end

M.ELEVATOR_PREFIX = ELEVATOR_PREFIX
M.NODE_PREFIX = NODE_PREFIX

return M
