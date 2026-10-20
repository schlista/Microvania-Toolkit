-- One color resolver for Layout Export and the command-line map regenerator.
local Config = require "developer.config.map_colors"
local Biomes = require "developer.config.biomes"
local Source = require "developer.tools.project_source"
local M = {}

function M.resolve(properties, config, biomes)
    config, biomes = config or Config, biomes or Biomes
    properties = properties or {}
    local fallback = config.default_fill
    local color = {fallback[1], fallback[2], fallback[3], fallback[4]}
    if config.biome_colors_enabled == false then return color end
    local hex = type(properties.biome_color) == "string" and properties.biome_color:match("^#(%x+)$")
    -- Tiled serializes Color properties as #AARRGGBB (or #RRGGBB).
    -- Biome tint is RGB; opacity is shared across rooms via default_fill.
    if hex and #hex == 8 then hex = hex:sub(3) end
    if hex and #hex == 6 then
        for i=1,3 do color[i] = tonumber(hex:sub(i*2-1,i*2),16) end
    else
        local biome = biomes[properties.biome]
        local tint = biome and biome.color
        if tint then
            color[1] = math.floor(math.max(0,math.min(1,tint.x))*255+0.5)
            color[2] = math.floor(math.max(0,math.min(1,tint.y))*255+0.5)
            color[3] = math.floor(math.max(0,math.min(1,tint.z))*255+0.5)
        end
    end
    return color
end

function M.from_tiled(path, world_properties)
    local text = Source.read(path)
    if not text then return M.resolve(require("mvtk.tiled.world_properties").resolve({},world_properties)) end
    local map, err = Source.load_table(text, path)
    assert(map, err)
    return M.resolve(require("mvtk.tiled.world_properties").resolve(map.properties,world_properties))
end

return M
