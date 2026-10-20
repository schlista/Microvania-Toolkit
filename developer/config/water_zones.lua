-- developer/config/water_zones.lua
-- Water zone configurations for swimming areas

local M = {}

-- Water zone presets
M.zone_types = {
    -- Normal water (safe)
    normal_water = {
        oxygen_enabled = true,
        oxygen_max = 10.0,  -- 10 seconds
        oxygen_drain_rate = 1.0,
        oxygen_refill_rate = 2.0,
        current_x = 0,
        current_y = 0,
        tint_color = vmath.vector4(0.3, 0.5, 0.8, 0.3),
        damage_per_second = 0,
        enable_particles = true,
        swim_speed = 200,
        swim_dash_speed = 400
    },

    -- Fast current water
    river_current = {
        oxygen_enabled = true,
        oxygen_max = 15.0,
        oxygen_drain_rate = 0.8,
        oxygen_refill_rate = 2.0,
        current_x = 300,  -- Strong horizontal current
        current_y = 0,
        tint_color = vmath.vector4(0.3, 0.5, 0.8, 0.3),
        damage_per_second = 0,
        enable_particles = true,
        swim_speed = 200,
        swim_dash_speed = 400
    },

    -- Toxic water (damages player)
    acid_pool = {
        oxygen_enabled = false,  -- Don't need oxygen, damage kills you first
        current_x = 0,
        current_y = 0,
        tint_color = vmath.vector4(0.5, 0.8, 0.2, 0.5),  -- Green tint
        damage_per_second = 5,  -- 5 damage per second
        enable_particles = true,
        swim_speed = 150,  -- Slower movement
        swim_dash_speed = 300
    },

    -- Lava (instant death or heavy damage)
    lava = {
        oxygen_enabled = false,
        current_x = 0,
        current_y = 0,
        tint_color = vmath.vector4(1, 0.3, 0, 0.6),  -- Orange/red tint
        damage_per_second = 20,  -- Very high damage
        enable_particles = true,
        swim_speed = 100,  -- Very slow
        swim_dash_speed = 200
    },

    -- Deep ocean (long oxygen duration)
    deep_ocean = {
        oxygen_enabled = true,
        oxygen_max = 30.0,  -- 30 seconds
        oxygen_drain_rate = 1.0,
        oxygen_refill_rate = 3.0,
        current_x = 0,
        current_y = -50,  -- Slight downward current
        tint_color = vmath.vector4(0.1, 0.2, 0.5, 0.4),  -- Dark blue
        damage_per_second = 0,
        enable_particles = true,
        swim_speed = 180,
        swim_dash_speed = 380
    },

    -- Underwater cave (no oxygen limit, used with upgrade)
    cave_water = {
        oxygen_enabled = false,  -- Player has infinite breath upgrade
        current_x = 0,
        current_y = 0,
        tint_color = vmath.vector4(0.2, 0.3, 0.4, 0.3),
        damage_per_second = 0,
        enable_particles = true,
        swim_speed = 220,
        swim_dash_speed = 420
    }
}

-- Specific water zones in your game (map to room IDs or positions)
M.zones = {
    -- Example: Define water zones by room
    {
        room_id = "room_lake_1",
        type = "normal_water",
        surface_y_offset = 0,  -- Surface at game object Y position
    },
    {
        room_id = "room_river_1",
        type = "river_current",
        surface_y_offset = 0,
    },
    {
        room_id = "room_acid_1",
        type = "acid_pool",
        surface_y_offset = 0,
    },
    {
        room_id = "room_volcano_1",
        type = "lava",
        surface_y_offset = 0,
    },
    {
        room_id = "room_ocean_1",
        type = "deep_ocean",
        surface_y_offset = 50,  -- Surface 50 pixels above game object
    }
}

return M
