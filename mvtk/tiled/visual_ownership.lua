-- mvtk/tiled/visual_ownership.lua
-- Canonical ownership rules for placeholder sprites baked from curated Tiled
-- templates. This module is deliberately Defold-independent so editor hooks,
-- validators, and runtime spawners can share the exact same behavior.

local M = {}

M.PROPERTY = "use_defold_sprite"

local DEFAULTS = {
    ability = true,
    boss_weak_point = true,
    bounce_pad = false,
    breakable_wall = false,
    chest = true,
    collectible = true,
    conveyor = false,
    energy_station = true,
    gate = false,
    health_station = true,
    hint_stone = true,
    lever = true,
    lore_item = true,
    map_station = true,
    npc = true,
    one_way_platform = false,
    pressure_plate = false,
    secret = true,
    sign = true,
    teleporter = true,
    timed_door = false,
    wall_jump_surface = false,
    water_volume = false,
}

local function normalize_type(value)
    if value == nil then return nil end
    local s = tostring(value):lower()
    s = s:gsub("[%s%-]+", "_")
    s = s:gsub("[^%w_]", "")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    return s ~= "" and s or nil
end

local function unwrap(value)
    if type(value) == "table" and value.value ~= nil then
        return value.value
    end
    return value
end

-- Read either the keyed property representation used by Tiled Lua exports or
-- the array-of-records representation used by scripted exporters. Explicit
-- records win over inherited template defaults.
function M.property_value(object_or_properties, name)
    name = name or M.PROPERTY
    local properties = object_or_properties
    if type(properties) == "table" and properties.properties ~= nil then
        properties = properties.properties
    end
    if type(properties) ~= "table" then return nil end

    if properties[name] ~= nil then
        return unwrap(properties[name])
    end
    if properties.name == name and properties.value ~= nil then
        return unwrap(properties.value)
    end

    local inherited_value = nil
    for _, entry in ipairs(properties) do
        if type(entry) == "table" and (entry.name or entry.Name) == name then
            local value = entry.value
            if value == nil then value = entry.Value end
            value = unwrap(value)
            if value ~= nil then
                local inherited = entry.inherited
                if inherited == nil then inherited = entry.Inherited end
                if inherited == false or inherited == 0 or tostring(inherited):lower() == "false" then
                    return value
                end
                if inherited_value == nil then inherited_value = value end
            end
        end
    end
    return inherited_value
end

function M.to_bool(value, default)
    if value == nil then return default end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    local s = tostring(value):lower()
    if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return default
end

function M.supports(object_type)
    return DEFAULTS[normalize_type(object_type)] ~= nil
end

function M.default_for(object_type)
    return DEFAULTS[normalize_type(object_type)]
end

function M.uses_defold_sprite(object_or_properties, object_type)
    -- All world-object artwork is authored in Tiled. Legacy switches cannot
    -- resurrect placeholders. Character rendering is the only exception.
    local kind = normalize_type(object_type)
    return kind == "player" or kind == "enemy" or kind == "boss"
end

-- Retained only for reading old exports; new templates no longer offer this
-- switch. Callers must use uses_defold_sprite for the current contract.
function M.legacy_uses_defold_sprite(object_or_properties, object_type)
    -- Navigation markers carry behavior only. Older exports may still request
    -- a placeholder sprite; artwork for these objects is always authored in Tiled.
    local kind = normalize_type(object_type)
    if kind == "checkpoint" or kind == "save_point" or kind == "spawn_point"
        or kind == "player_start" or kind == "player_spawn" or kind == "respawn_point" then
        return false
    end
    local default = M.default_for(object_type)
    if default == nil then return true end
    local value = M.property_value(object_or_properties, M.PROPERTY)
    if value == nil then
        value = M.property_value(object_or_properties, "show_sprite")
    end
    return M.to_bool(value, default)
end

function M.normalize_type(value)
    return normalize_type(value)
end

function M.defaults()
    local copy = {}
    for key, value in pairs(DEFAULTS) do copy[key] = value end
    return copy
end

return M
