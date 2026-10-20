-- mvtk/editor/tileset_selection.lua
--
-- Shared Tiled tileset selection helpers used by editor generation and
-- validation. Keep this dependency-light: tools/validate_tiled_export.lua
-- loads it from plain Lua as well as from Defold editor hooks.

local M = {}

local TILED_FLIP_H_BIT = 2147483648  -- 0x80000000
local TILED_FLIP_V_BIT = 1073741824  -- 0x40000000
local TILED_FLIP_D_BIT = 536870912   -- 0x20000000
local TILED_GID_MASK   = 536870911   -- 0x1FFFFFFF

M.TILED_GID_MASK = TILED_GID_MASK

-- key = h*4 + v*2 + d -> { h_flip, v_flip, rotate90 }
-- Defold's rotate90 is COUNTER-CLOCKWISE (confirmed in-editor: a tile rotated
-- 90 CW in Tiled rendered 90 the wrong way until this convention was applied),
-- so every diagonal (d=1) row differs from a naive bit copy. d=0 rows are pure
-- flips/180 and are unaffected.
local TILED_TO_DEFOLD_ORIENT = {
    [0] = { 0, 0, 0 },
    [4] = { 1, 0, 0 }, -- H
    [2] = { 0, 1, 0 }, -- V
    [6] = { 1, 1, 0 }, -- H+V (180)
    [1] = { 0, 1, 1 }, -- D
    [5] = { 0, 0, 1 }, -- H+D (90 CCW in Tiled)
    [3] = { 1, 1, 1 }, -- V+D (90 CW in Tiled)
    [7] = { 1, 0, 1 }, -- H+V+D
}

-- Convert Tiled's H/V/D flip bits to Defold's h_flip/v_flip/rotate90 fields.
-- Tiled's diagonal bit is a transpose flag, not Defold's rotate90 flag.
local function tiled_flags_to_defold(h, v, d)
    local function is_set(value)
        if value == true then return true end
        if value == false or value == nil then return false end
        local n = tonumber(value)
        return n ~= nil and n ~= 0
    end
    local key = (is_set(h) and 4 or 0)
        + (is_set(v) and 2 or 0)
        + (is_set(d) and 1 or 0)
    local out = TILED_TO_DEFOLD_ORIENT[key] or TILED_TO_DEFOLD_ORIENT[0]
    return out[1], out[2], out[3]
end
M.tiled_flags_to_defold = tiled_flags_to_defold

local function get_tiled_property(properties, key)
    if type(properties) ~= "table" or not key or key == "" then
        return nil
    end

    local direct = properties[key]
    if direct ~= nil then
        if type(direct) == "table" then
            if direct.value ~= nil then return direct.value end
            if direct.Value ~= nil then return direct.Value end
        end
        return direct
    end

    for _, entry in ipairs(properties) do
        if type(entry) == "table" then
            local name = entry.name or entry.Name
            if name == key then
                if entry.value ~= nil then return entry.value end
                if entry.Value ~= nil then return entry.Value end
            end
        end
    end

    return nil
end
M.get_tiled_property = get_tiled_property

local function is_image_collection_tileset_entry(tileset_entry)
    if type(tileset_entry) ~= "table" then
        return false
    end
    if tileset_entry.image and tileset_entry.image ~= "" then
        return false
    end
    if type(tileset_entry.tiles) ~= "table" then
        return false
    end
    for _, tile in ipairs(tileset_entry.tiles) do
        if type(tile) == "table" and tile.image and tile.image ~= "" then
            return true
        end
    end
    return false
end
M.is_image_collection_tileset_entry = is_image_collection_tileset_entry

local function first_non_collection_tileset(tilesets)
    if type(tilesets) ~= "table" then
        return nil
    end
    for _, ts in ipairs(tilesets) do
        if type(ts) == "table" and not is_image_collection_tileset_entry(ts) then
            return ts
        end
    end
    for _, ts in ipairs(tilesets) do
        if type(ts) == "table" then
            return ts
        end
    end
    return nil
end
M.first_non_collection_tileset = first_non_collection_tileset

local function decode_gid_value(raw)
    local value = tonumber(raw) or 0
    if value >= TILED_FLIP_H_BIT then value = value - TILED_FLIP_H_BIT end
    if value >= TILED_FLIP_V_BIT then value = value - TILED_FLIP_V_BIT end
    if value >= TILED_FLIP_D_BIT then value = value - TILED_FLIP_D_BIT end
    if value < 0 then value = 0 end
    if value > TILED_GID_MASK then value = value % (TILED_GID_MASK + 1) end
    return value
end
M.decode_gid_value = decode_gid_value

local function select_primary_tileset(tiled_data, get_property_fn)
    if type(tiled_data) ~= "table" or type(tiled_data.tilesets) ~= "table" then
        return nil, "no_tilesets"
    end

    local getter = type(get_property_fn) == "function" and get_property_fn or get_tiled_property
    local biome = getter(tiled_data.properties, "biome")
    if biome ~= nil and tostring(biome) ~= "" then
        local biome_name = tostring(biome):lower()
        for _, ts in ipairs(tiled_data.tilesets) do
            if type(ts) == "table" and tostring(ts.name or ""):lower() == biome_name then
                return ts, "biome"
            end
        end
    end

    local first_single_image = first_non_collection_tileset(tiled_data.tilesets)
    if first_single_image then
        return first_single_image, "first_non_collection"
    end

    return nil, "no_tilesets"
end
M.select_primary_tileset = select_primary_tileset

local function get_tileset_gid_range(tiled_data, tileset, fallback_lastgid)
    local firstgid = tonumber(type(tileset) == "table" and tileset.firstgid or nil) or 1
    local lastgid = tonumber(fallback_lastgid) or TILED_GID_MASK

    if type(tiled_data) == "table" and type(tiled_data.tilesets) == "table" then
        for _, ts in ipairs(tiled_data.tilesets) do
            if ts ~= tileset then
                local other_first = tonumber(type(ts) == "table" and ts.firstgid or nil)
                if other_first and other_first > firstgid and other_first - 1 < lastgid then
                    lastgid = other_first - 1
                end
            end
        end
    end

    return firstgid, lastgid
end
M.get_tileset_gid_range = get_tileset_gid_range

local function find_tileset_for_gid(tiled_data, gid)
    local value = tonumber(gid) or 0
    if value <= 0 or type(tiled_data) ~= "table" or type(tiled_data.tilesets) ~= "table" then
        return nil
    end

    local selected = nil
    local selected_firstgid = nil
    for _, ts in ipairs(tiled_data.tilesets) do
        local firstgid = tonumber(type(ts) == "table" and ts.firstgid or nil)
        if firstgid and firstgid <= value and (not selected_firstgid or firstgid > selected_firstgid) then
            selected = ts
            selected_firstgid = firstgid
        end
    end

    if not selected then
        return nil
    end

    local _, lastgid = get_tileset_gid_range(tiled_data, selected, TILED_GID_MASK)
    if value > lastgid then
        return nil
    end

    return selected, value - selected_firstgid, selected_firstgid, lastgid
end
M.find_tileset_for_gid = find_tileset_for_gid

return M
