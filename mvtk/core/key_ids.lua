-- Shared key/item ID canonicalization.
--
-- Tiled deliberately exposes short, creator-friendly enum values while the
-- inventory uses stable item IDs.  Keep that translation in one place so
-- pickups and every kind of key consumer agree, including legacy saves.

local Util = require "mvtk.core.util"

local M = {}

M.CANONICAL_IDS = {
    "key",
    "key_boss",
    "key_red",
    "key_blue",
    "key_gold",
}

M.AUTHORED_TO_CANONICAL = {
    none = "",
    normal = "key",
    boss = "key_boss",
    red = "key_red",
    blue = "key_blue",
    gold = "key_gold",
}

M.LEGACY_ALIASES = {
    boss_key = "key_boss",
    red_key = "key_red",
    blue_key = "key_blue",
    gold_key = "key_gold",
}

local aliases = {}
local canonical_set = {}
for _, id in ipairs(M.CANONICAL_IDS) do
    aliases[id] = id
    canonical_set[id] = true
end
for id, canonical in pairs(M.AUTHORED_TO_CANONICAL) do
    aliases[id] = canonical
end
for id, canonical in pairs(M.LEGACY_ALIASES) do
    aliases[id] = canonical
end

local known_hashes = nil

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local unwrap_hash_text = Util.normalize_hash_string

local function ensure_hash_lookup()
    if known_hashes ~= nil then
        return known_hashes
    end
    known_hashes = {}
    if type(hash) ~= "function" then
        return known_hashes
    end
    for alias, canonical in pairs(aliases) do
        known_hashes[hash(alias)] = canonical
    end
    known_hashes[hash("")] = ""
    return known_hashes
end

--- Convert an authored, canonical, or legacy key ID to its inventory ID.
-- Unknown non-key strings are returned unchanged so this helper is safe at
-- mixed item/key boundaries. Known empty/none sentinels return "". Unknown
-- hash userdata returns nil when its text cannot be resolved.
function M.canonicalize(value)
    if value == nil then
        return ""
    end

    if type(value) == "userdata" then
        local known = ensure_hash_lookup()[value]
        if known ~= nil then
            return known
        end
    end

    local raw = unwrap_hash_text(value)
    if raw == nil then
        if type(value) == "string" and trim(value) == "" then
            return ""
        end
        return nil
    end

    local canonical = aliases[string.lower(raw)]
    if canonical ~= nil then
        return canonical
    end
    return raw
end

function M.is_canonical(value)
    local canonical = M.canonicalize(value)
    return canonical ~= nil and canonical_set[canonical] == true
end

function M.canonical_ids()
    local out = {}
    for index, id in ipairs(M.CANONICAL_IDS) do
        out[index] = id
    end
    return out
end

--- Build a Defold hash -> canonical string lookup for script properties.
-- Extra IDs allow consumers such as chests to retain creator-defined keys
-- registered in collectible configuration without another alias table.
function M.build_hash_lookup(extra_ids)
    local out = {}
    if type(hash) ~= "function" then
        return out
    end
    for alias, canonical in pairs(aliases) do
        if canonical ~= "" then
            out[hash(alias)] = canonical
        end
    end
    for _, id in ipairs(extra_ids or {}) do
        local canonical = M.canonicalize(id)
        if canonical and canonical ~= "" then
            out[hash(tostring(id))] = canonical
            out[hash(canonical)] = canonical
        end
    end
    return out
end

return M
