--- Tiled Object Conversion Configuration
-- Defines settings for converting Tiled objects to Defold game objects
-- Used by hooks.editor_script during build-time collection generation

return {
    -- Tiled export file paths (relative to project root)
    paths = {
        -- Directory where Tiled exports .lua map files
        tiled_lua_maps = "developer/assets/tiled/maps",

        -- Directory where Tiled exports .tmx or tilemap files (if needed)
        tiled_tilemaps = "developer/assets/tiled/maps",
    },

    -- Y-axis offsets for object positioning
    -- Tiled uses point positions, but Defold collision shapes are centered
    -- These offsets move objects up so their bottom aligns with the Tiled point
    y_offsets = {
        collectible = 64,  -- Sphere collision radius 
        ability = 64,      -- Sphere collision radius 
        enemy = 64,        -- Box collision half-height 
        save_point = 64,   -- Match sprite offset in prefab
        chest = 48,        -- Box collision half-height for chests
        boss_add_spawner = 0, -- Keep point spawner at exact Tiled position
        joint_platform = 0, -- Rectangle-authored platform uses explicit center conversion
        rail_elevator = 0, -- Alias of joint_platform
        light_source = 0,  -- Point-authored light sources should stay exactly on the placed point
        default = 64,       -- Default for unknown object types
    },

    -- Add more Tiled conversion settings here as needed
    -- For example:
    -- z_layer_offsets = { ... },
    -- rotation_conversion = { ... },
}
