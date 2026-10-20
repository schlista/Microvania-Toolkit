-- Shared world-default contract for preparation and runtime. No disk/engine APIs.
local OP = require "mvtk.tiled.object_props"
local M = {}
local active, members = {}, {}

local function selected(value)
    return value ~= nil and value ~= "" and value ~= "inherit"
end

function M.validate(properties)
    local result = {}
    for _, key in ipairs({"world_name", "default_biome", "default_music", "default_ambience", "default_map_color"}) do
        local value = (properties or {})[key]
        if value ~= nil then
            assert(type(value) == "string", "World property " .. key .. " must be a string")
            if key == "default_map_color" and value ~= "" then
                assert(value:match("^#%x%x%x%x%x%x$") or value:match("^#%x%x%x%x%x%x%x%x$"),
                    "default_map_color must be a Tiled Color (#RRGGBB or #AARRGGBB)")
            end
            result[key] = value
        end
    end
    return result
end

function M.resolve(properties, world)
    properties, world = properties or {}, world or {}
    local result = {}
    for key, value in pairs(properties) do result[key] = value end
    local function inherit(key, value, default)
        result[key] = selected(value) and value or (selected(default) and default or nil)
    end
    inherit("biome", OP.get(properties, "biome"), world.default_biome)
    inherit("music", OP.get(properties, "music"), world.default_music)
    -- `ambience` is a legacy music alias. Ambient loops use their own property.
    inherit("ambient_sound", properties.ambient_sound, world.default_ambience)
    local tint = world.default_map_color
    -- Transparent world color means inherit the biome/project color. Room
    -- biome_color keeps its existing RGB-only behavior, regardless of alpha.
    if tint and tint:match("^#00%x%x%x%x%x%x$") then tint = nil end
    inherit("biome_color", properties.biome_color, tint)
    return result
end

-- Called with the published layout; defaults never leak to unrelated rooms or
-- another world. Reading a cached room again resolves against the new snapshot.
function M.set_layout(layout)
    active, members = {}, {}
    if layout and layout.source and layout.source.kind == "tiled" then
        active = M.validate(layout.world_properties)
        for _, room in ipairs(layout.rooms or {}) do members[room.id] = true end
    end
end

function M.for_room(id)
    return members[id] and active or {}
end

function M.validate_domains(world, config)
    local function check(key, filename, entries)
        local value = world[key]
        if not selected(value) or value == "none" or value == "hush" then return end
        local domain = config(filename)
        domain = entries and domain[entries] or domain
        assert(type(domain) == "table" and domain[value] ~= nil,
            "Unknown " .. key .. " '" .. value .. "' in developer/config/" .. filename .. ".lua")
    end
    check("default_biome", "biomes")
    check("default_music", "music_tracks_generated", "tracks")
    check("default_ambience", "ambient_sounds")
end

return M
