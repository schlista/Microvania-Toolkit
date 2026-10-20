-- developer/config/hazard_types.lua
-- ============================================================================
-- MV Toolkit . Hazard Type Definitions (data-only)
-- All hazard zones configurable here - spikes, lava, acid, electricity, etc.
-- Each hazard can have immunity granted by an ability or item.
-- ============================================================================

return {
    -- =========================================================================
    -- INSTANT DAMAGE HAZARDS
    -- =========================================================================
    
    spikes = {
        name = "Spikes",
        damage = 1,
        damage_interval = 0.0,  -- 0 = single hit on contact
        knockback = 300,
        knockback_direction = "up",  -- "up", "away", "none"
        -- Player recovery seconds. A Tiled hazard's stun_t overrides this;
        -- -1 inherits combat_config.feedback.hurt.stun_t, 0 disables recovery.
        stun_t = -1,
        instant_kill = false,
        
        -- Immunity
        immunity_ability = nil,  -- no ability grants immunity
        immunity_item = "spike_boots",  -- or get this item
        
        -- Visuals
        sprite = "hazard_spikes",
        particle_on_hit = "blood_splat",
        sound_on_hit = "spike_hit",
        
        -- Tiled layer/tile detection
        tile_ids = { 401, 402, 403 },  -- tile IDs that are this hazard
        layer_name = "hazards",
    },
    
    -- =========================================================================
    -- DAMAGE-OVER-TIME HAZARDS
    -- =========================================================================
    
    lava = {
        name = "Lava",
        damage = 2,
        damage_interval = 0.5,  -- damage every 0.5 seconds
        knockback = 400,
        knockback_direction = "up",
        instant_kill = false,
        
        
        -- Immunity
        immunity_ability = "lava_walk",
        immunity_item = "heat_suit",
        
        -- Visuals
        sprite = "hazard_lava",
        particle_ambient = "lava_bubbles",
        particle_on_hit = "burn",
        sound_ambient = "lava_loop",
        sound_on_hit = "burn_sizzle",
        
        tile_ids = { 410, 411, 412 },
        layer_name = "hazards",
    },
    
    acid = {
        name = "Acid",
        damage = 1,
        damage_interval = 0.3,
        knockback = 200,
        knockback_direction = "up",
        instant_kill = false,
        
        
        -- Slow effect while in acid
        slow_multiplier = 0.5,
        
        immunity_ability = "acid_immunity",
        immunity_item = "hazmat_suit",
        
        sprite = "hazard_acid",
        particle_ambient = "acid_bubbles",
        particle_on_hit = "acid_splash",
        sound_ambient = "acid_loop",
        sound_on_hit = "acid_burn",
        
        tile_ids = { 420, 421, 422 },
        layer_name = "hazards",
    },
    
    cold = {
        name = "Freezing Water",
        damage = 1,
        damage_interval = 1.0,
        knockback = 0,
        knockback_direction = "none",
        instant_kill = false,
        
        
        -- Slow effect
        slow_multiplier = 0.3,
        
        immunity_ability = "cold_resist",
        immunity_item = "thermal_suit",
        
        sprite = "hazard_cold_water",
        particle_ambient = "frost_mist",
        particle_on_hit = "ice_crystals",
        sound_ambient = "cold_wind",
        sound_on_hit = "freeze_crack",
        
        tile_ids = { 430, 431, 432 },
        layer_name = "hazards",
    },
    
    electricity = {
        name = "Electricity",
        damage = 2,
        damage_interval = 0.0,  -- single burst
        knockback = 500,
        knockback_direction = "away",
        instant_kill = false,
        
        
        -- May arc to player from distance
        arc_range = 64,
        arc_chance = 0.3,
        
        immunity_ability = "shock_immunity",
        immunity_item = "rubber_boots",
        
        sprite = "hazard_electric",
        particle_ambient = "sparks",
        particle_on_hit = "lightning_flash",
        sound_ambient = "electric_hum",
        sound_on_hit = "electric_shock",
        
        tile_ids = { 440, 441, 442 },
        layer_name = "hazards",
    },
    
    -- =========================================================================
    -- INSTANT KILL HAZARDS
    -- =========================================================================
    
    void = {
        name = "Void / Pit",
        damage = 999,
        damage_interval = 0.0,
        knockback = 0,
        knockback_direction = "none",
        instant_kill = true,
        
        -- Respawn behavior
        respawn_at_checkpoint = true,
        respawn_at_room_entrance = false,
        
        -- Can be crossed with certain abilities
        immunity_ability = "hover",  -- or "glide"
        
        sprite = nil,  -- usually invisible / off-screen
        particle_on_death = "void_fade",
        sound_on_death = "fall_scream",
        
        tile_ids = { 450 },
        layer_name = "void",
    },
    
    -- =========================================================================
    -- MOVING/MECHANICAL HAZARDS
    -- =========================================================================
    
    crusher = {
        name = "Crusher",
        damage = 5,
        damage_interval = 0.0,
        knockback = 0,
        knockback_direction = "none",
        instant_kill = false,  -- set to true for instant death crushers
        
        -- Crusher timing
        cycle_time = 3.0,  -- full cycle duration
        warn_time = 0.5,  -- visual warning before crush
        crush_hold_time = 1.0,  -- time crusher stays down
        
        immunity_ability = nil,  -- no immunity, must avoid
        
        sprite = "hazard_crusher",
        particle_on_crush = "dust_cloud",
        sound_warn = "crusher_warn",
        sound_crush = "crusher_impact",
        
        tile_ids = { 460 },
        layer_name = "hazards",
    },
    
    saw_blade = {
        name = "Saw Blade",
        damage = 2,
        damage_interval = 0.2,  -- rapid damage if touching
        knockback = 400,
        knockback_direction = "away",
        instant_kill = false,
        
        
        immunity_ability = nil,
        
        sprite = "hazard_saw",
        particle_on_hit = "sparks",
        sound_ambient = "saw_spin",
        sound_on_hit = "saw_cut",
        
        tile_ids = { 470, 471 },
        layer_name = "hazards",
    },
    
    -- =========================================================================
    -- TIMED/PERIODIC HAZARDS
    -- =========================================================================
    
    flame_jet = {
        name = "Flame Jet",
        damage = 2,
        damage_interval = 0.3,
        knockback = 200,
        knockback_direction = "away",
        instant_kill = false,
        
        
        -- Timing
        on_duration = 2.0,
        off_duration = 3.0,
        
        immunity_ability = "fire_immunity",
        immunity_item = "heat_suit",
        
        sprite = "hazard_flame_jet",
        particle_active = "fire_jet",
        sound_active = "flame_whoosh",
        sound_ignite = "flame_start",
        
        tile_ids = { 480, 481 },
        layer_name = "hazards",
    },
    
    poison_gas = {
        name = "Poison Gas",
        damage = 1,
        damage_interval = 0.5,
        knockback = 0,
        knockback_direction = "none",
        instant_kill = false,
        
        
        -- Visual obstruction
        visibility_reduction = 0.5,  -- 50% visibility in gas
        
        immunity_ability = "gas_mask",
        immunity_item = "gas_mask",
        
        sprite = "hazard_gas",
        particle_ambient = "gas_cloud",
        sound_ambient = "gas_hiss",
        sound_on_hit = "cough",
        
        tile_ids = { 490, 491 },
        layer_name = "hazards",
    },
    
    -- =========================================================================
    -- WATER/LIQUID HAZARDS
    -- =========================================================================
    
    deep_water = {
        name = "Deep Water",
        damage = 0,  -- no direct damage
        damage_interval = 0.0,
        knockback = 0,
        knockback_direction = "none",
        instant_kill = false,
        
        -- Drowning mechanic
        enable_drowning = true,
        oxygen_drain_rate = 20,  -- units per second
        drowning_damage = 1,
        drowning_interval = 1.0,
        
        -- Movement in water
        swim_enabled = true,
        swim_speed_mult = 0.6,
        gravity_mult = 0.3,
        
        immunity_ability = "swim",
        immunity_item = "diving_gear",
        
        sprite = nil,  -- uses water shader
        particle_ambient = "bubbles",
        particle_surface = "water_ripples",
        sound_enter = "water_splash",
        sound_swim = "water_swim",
        
        tile_ids = { 500, 501, 502 },
        layer_name = "water",
    },
    
    -- =========================================================================
    -- GLOBAL HAZARD SETTINGS
    -- =========================================================================
    settings = {
        -- Universal iframes after hazard damage
        hazard_iframes = 0.5,
        
        -- Flash color when damaged
        damage_flash_color = { 1.0, 0.3, 0.3, 1.0 },
        damage_flash_duration = 0.1,
        
        -- Screen shake on hazard damage
        screen_shake_enabled = true,
        screen_shake_intensity = 5,
        
        -- Audio
        default_hit_sound = "hazard_hit",
    },
}
