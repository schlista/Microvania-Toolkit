-- developer/config/ambient_zones.lua
-- Ambient audio zone definitions.
-- Each zone entry fades in a looping ambience track while the player is inside the area.
-- Fields:
--   id   : unique identifier used by save/stream systems
--   area : biome/room tag this zone applies to
--   bus  : audio bus to route to ("sfx", "music", etc.)
--   gain : volume multiplier (0..1)
--   loop : sound id from developer/config/ambience_tracks.lua

return {
    zones = {
        { id = "forest_edge", area = "forest", bus = "sfx", gain = 0.8, loop = "amb_forest" },
        { id = "catacombs", area = "catacombs", bus = "sfx", gain = 0.7, loop = "amb_caves" },
        { id = "village", area = "village", bus = "sfx", gain = 0.6, loop = "amb_village" },
        { id = "water_shallows", area = "water_world", bus = "sfx", gain = 0.7, loop = "amb_underwater" },
    },
}
