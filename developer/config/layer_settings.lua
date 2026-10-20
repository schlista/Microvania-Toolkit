--- Layer Settings Configuration
-- Default properties for special tilemap layers
-- Override these on a per-layer basis using Tiled layer custom properties
--
-- Note: All properties should be strings (not booleans or hashes) for consistency
-- with Defold's go.property string type.
--
-- @module layer_settings

return {
    -- Breakables layer - tiles that can be destroyed
    breakables = {
        wall_type = "cracked",          -- "cracked", "bomb_only", "subtle", "invisible"
        health = 3,                      -- hits to destroy
        required_ability = "",           -- ability needed to break (e.g. "bomb", "charge_attack")
        reveals_secret = "",             -- secret area ID if breaking reveals a secret
        drop_collectible = "",           -- collectible type to drop when destroyed
        swap_tiles_on_break = true,      -- clear wall layer and apply broken-wall tiles
        wall_layer = "solid",            -- source layer to replace
        broken_wall_layer = "broken_wall", -- pre-authored replacement tiles
    },
    
    -- Hazards layer - tiles that damage the player
    hazards = {
        hazard_type = "spikes",          -- "spikes", "lava", "acid", "electricity", "cold"
        damage = 1,                      -- damage per tick
        damage_interval = 0.5,           -- seconds between damage ticks
        knockback_force = 300,           -- knockback on contact
        required_resistance = "",        -- ability that grants immunity
        instant_kill = false,            -- if true, kills player instantly
    },
    
    -- Example: Lava layer (override hazards defaults)
    lava = {
        hazard_type = "lava",
        damage = 2,
        damage_interval = 0.3,
        knockback_force = 400,
        required_resistance = "lava_resistance",
    },
    
    -- Example: Bomb-only walls with secret
    bomb_walls = {
        wall_type = "bomb_only",
        health = 1,                      -- one bomb destroys
        required_ability = "bomb",
        reveals_secret = "bomb_secret",  -- marks as secret discovered
        drop_collectible = "",           -- no drop by default
    },
}
