-- mvtk/audio/ambient_zones.lua
-- Simple ambient loop manager keyed by zone id.

local Audio = require "mvtk.audio.audio"
local ConfigOk, Config = pcall(require, "developer.config.ambient_zones")

local zones = {}
local current

local function load()
    if ConfigOk and Config then
        zones = Config.zones or zones
    end
end

load()

local M = {}

function M.enter(zone_id)
    if not zone_id or current == zone_id then return end
    local def = zones and zones[zone_id]
    if def then
        if def.loop then
            Audio.sfx(def.loop, { gain = def.gain or 1.0, bus = def.bus })
        end
        if def.music then
            Audio.music(def.music)
        elseif def.area then
            Audio.set_area_theme(def.area)
        end
        current = zone_id
    end
end

function M.leave(zone_id)
    if current == zone_id then
        current = nil
    end
end

return M
