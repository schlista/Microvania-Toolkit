--- Boss Attack Patterns
-- Defines reusable attack patterns for bosses
-- Patterns can be mixed and matched across different bosses
--
-- @module attack_patterns

local M = {}

-- Minimal asset-free patterns used by default_boss and the shipped Tiled
-- fixture. Keep these ids stable: they are the safe first-run boss contract.
M.test_melee = {
    type = "melee",
    telegraph_time = 0.35,
    duration = 0.35,
    cooldown = 1.5,
    damage = 1,
    range = 72,
    width = 56,
    height = 64,
    knockback = 120,
    animation = "attack",
}

M.test_projectile = {
    type = "projectile",
    telegraph_time = 0.45,
    duration = 0.3,
    cooldown = 2.0,
    damage = 1,
    projectiles = {
        count = 1,
        speed = 220,
        damage = 1,
        lifetime = 3.0,
    },
    animation = "ranged_attack",
}

--[[============================================================================
    STARTER PATTERNS (Atlas-friendly)
    These align with animations in /developer/assets/atlas/boss.atlas
==============================================================================]]

M.sentinel_swipe = {
    type = "melee",
    telegraph_time = 0.4,
    duration = 0.6,
    cooldown = 2.5,

    damage = 3,
    range = 90,
    width = 90,
    height = 80,
    animation = "attack",
}

M.sentinel_burst = {
    type = "projectile",
    telegraph_time = 0.5,
    duration = 0.4,
    cooldown = 3.0,

    damage = 2,
    projectiles = {
        count = 3,
        spread = 20,
        speed = 260,
        lifetime = 4.0,
    },

    animation = "ranged_attack",
}

M.sentinel_slam = {
    type = "aoe",
    telegraph_time = 0.7,
    duration = 0.6,
    cooldown = 4.5,

    damage = 4,
    aoe = {
        radius = 140,
        delay = 0.3,
        knockback = 220,
    },

    animation = "slam",
}

M.sentinel_summon = {
    type = "summon",
    telegraph_time = 0.8,
    duration = 0.5,
    cooldown = 6.0,

    summon = {
        count = 2,
        enemy_type = "slime",
        spawn_radius = 120,
    },

    animation = "summon",
}

--[[============================================================================
    CACTUS COLOSSUS PATTERNS
    These map directly to the three clips in cactus_boss.atlas.
==============================================================================]]

M.cactus_ground_slam = {
    type = "aoe",
    telegraph_time = 0.55,
    duration = 0.5,
    cooldown = 3.8,

    damage = 3,
    aoe = {
        -- Match (and slightly exceed) the 320px attack commitment range so
        -- the cactus cannot choose a guaranteed-miss slam at max range.
        radius = 340,
        ground_only = true,
        vertical_clearance = 110,
        -- attack_1 runs at 8 FPS; frame three lands 0.25 seconds in.
        delay = 0.25,
        knockback = 300,
        knockback_y = 140,
        effect_duration = 0.5,
    },

    animation = "attack_1",
}

M.cactus_needle_volley = {
    type = "projectile",
    telegraph_time = 0.6,
    duration = 0.5,
    cooldown = 3.8,

    damage = 1,
    projectiles = {
        count = 8,
        -- Eight evenly spaced needles form a full radial burst.
        spread = 315,
        speed = 380,
        lifetime = 4.0,
    },

    animation = "attack_2",
}

M.cactus_charge = {
    type = "charge",
    telegraph_time = 0.6,
    duration = 0.8,
    cooldown = 5.5,

    -- Cross most of the arena quickly after a readable wind-up. The low
    -- vertical lane makes a committed jump the intended counter.
    dash_speed = 1650,
    dash_distance = 900,
    hitbox_half_width = 78,
    hitbox_half_height = 105,
    recovery = 0.18,
    edge_padding = 80,
    damage = 2,
    knockback = 340,
    knockback_y = 130,
    animation = "attack_3",
}

--[[============================================================================
    MELEE PATTERNS
==============================================================================]]

M.sword_combo = {
    type = "melee",
    telegraph_time = 0.5,
    duration = 1.2,
    cooldown = 3.0,

    sequence = {
        {action = "slash", delay = 0.0, damage = 2, animation = "slash_1"},
        {action = "slash", delay = 0.4, damage = 2, animation = "slash_2"},
        {action = "thrust", delay = 0.8, damage = 3, animation = "thrust"},
    },
}

M.vine_whip = {
    type = "melee",
    telegraph_time = 0.3,
    duration = 0.8,
    cooldown = 2.5,

    sequence = {
        {action = "whip", delay = 0.0, damage = 2, range = 80, animation = "vine_attack"},
    },
}

M.berserk_whip = {
    type = "melee",
    telegraph_time = 0.2,
    duration = 1.5,
    cooldown = 2.0,

    sequence = {
        {action = "whip", delay = 0.0, damage = 3, range = 100, animation = "vine_fury_1"},
        {action = "whip", delay = 0.3, damage = 3, range = 100, animation = "vine_fury_2"},
        {action = "whip", delay = 0.6, damage = 3, range = 100, animation = "vine_fury_3"},
        {action = "whip", delay = 0.9, damage = 4, range = 120, animation = "vine_fury_4"},
    },
}

M.ground_slam = {
    type = "aoe",
    telegraph_time = 1.0,
    duration = 1.5,
    cooldown = 6.0,

    jump_height = 150,
    jump_duration = 0.5,
    slam_speed = 600,

    damage_waves = {
        {delay = 0.0, radius = 60, damage = 5, knockback = 200},
        {delay = 0.2, radius = 120, damage = 3, knockback = 150},
        {delay = 0.4, radius = 180, damage = 2, knockback = 100},
    },

    camera_shake = {intensity = 10, duration = 0.8},
}

M.crystal_slam = {
    type = "aoe",
    telegraph_time = 1.2,
    duration = 1.5,
    cooldown = 5.0,

    jump_height = 100,
    damage_waves = {
        {delay = 0.0, radius = 80, damage = 4, knockback = 180},
        {delay = 0.3, radius = 140, damage = 3, knockback = 120},
    },

    spawn_crystals = true,  -- Spawns damaging crystal spikes
    camera_shake = {intensity = 8, duration = 0.6},
}

M.dash_slash = {
    type = "charge",
    telegraph_time = 0.8,
    duration = 0.6,
    cooldown = 4.0,

    dash_speed = 500,
    dash_distance = 200,
    damage = 3,
    knockback = 250,
    animation = "dash_attack",
}

--[[============================================================================
    PROJECTILE PATTERNS
==============================================================================]]

M.crystal_throw = {
    type = "projectile",
    telegraph_time = 0.6,
    duration = 0.4,
    cooldown = 3.5,

    projectiles = {
        count = 1,
        speed = 300,
        damage = 3,
        size = {width = 16, height = 16},
        homing = false,
        lifetime = 5.0,
    },

    animation = "throw",
}

M.crystal_barrage = {
    type = "projectile",
    telegraph_time = 1.0,
    duration = 2.0,
    cooldown = 7.0,

    projectiles = {
        count = 12,
        spawn_interval = 0.15,  -- Time between each projectile
        speed = 350,
        damage = 2,
        size = {width = 12, height = 12},
        spread_pattern = "rain",  -- "spread", "circle", "rain"
        homing = false,
        lifetime = 6.0,
    },

    animation = "barrage",
}

M.dark_wave = {
    type = "projectile",
    telegraph_time = 0.7,
    duration = 0.5,
    cooldown = 4.0,

    projectiles = {
        count = 5,
        spread_angle = 60,  -- Total spread in degrees
        speed = 250,
        damage = 3,
        size = {width = 20, height = 20},
        homing = false,
        lifetime = 5.0,
    },

    animation = "cast_dark",
}

M.shadow_bolt = {
    type = "projectile",
    telegraph_time = 0.4,
    duration = 0.3,
    cooldown = 2.5,

    projectiles = {
        count = 1,
        speed = 400,
        damage = 2,
        homing = true,
        homing_strength = 200,  -- Turn rate
        lifetime = 4.0,
    },

    animation = "shadow_cast",
}

M.shadow_barrage = {
    type = "projectile",
    telegraph_time = 1.0,
    duration = 1.5,
    cooldown = 6.0,

    projectiles = {
        count = 8,
        spread_pattern = "circle",
        speed = 300,
        damage = 3,
        homing = true,
        homing_strength = 150,
        lifetime = 5.0,
    },

    animation = "shadow_burst",
}

M.laser_shot = {
    type = "beam",
    telegraph_time = 1.0,
    duration = 0.5,
    cooldown = 4.0,

    beam_length = 400,
    beam_width = 10,
    damage = 4,
    pierce = true,  -- Hits multiple targets

    animation = "laser_charge",
}

M.laser_sweep = {
    type = "beam",
    telegraph_time = 1.5,
    duration = 2.0,
    cooldown = 8.0,

    beam_length = 500,
    beam_width = 15,
    damage = 3,
    sweep_angle = 180,  -- Sweeps 180 degrees
    sweep_speed = 90,  -- Degrees per second

    animation = "laser_sweep",
}

--[[============================================================================
    SUMMON PATTERNS
==============================================================================]]

M.summon_thorns = {
    type = "summon",
    telegraph_time = 1.0,
    duration = 1.0,
    cooldown = 12.0,

    summon = {
        enemy_type = "thorn_minion",
        count = 3,
        spawn_delay = 0.3,  -- Time between each spawn
        spawn_pattern = "circle",  -- "circle", "corners", "edges", "random"
        max_active = 6,  -- Won't summon if this many already alive
    },

    animation = "summon",
}

M.summon_shadows = {
    type = "summon",
    telegraph_time = 1.2,
    duration = 1.5,
    cooldown = 15.0,

    summon = {
        enemy_type = "shadow_spawn",
        count = 4,
        spawn_delay = 0.4,
        spawn_pattern = "corners",
        max_active = 8,
    },

    animation = "summon_dark",
}

M.summon_crystals = {
    type = "summon",
    telegraph_time = 0.8,
    duration = 1.0,
    cooldown = 10.0,

    summon = {
        enemy_type = "crystal_shard_enemy",
        count = 5,
        spawn_delay = 0.2,
        spawn_pattern = "circle",
        max_active = 10,
    },

    animation = "crystal_summon",
}

--[[============================================================================
    AOE / HAZARD PATTERNS
==============================================================================]]

M.poison_cloud = {
    type = "hazard",
    telegraph_time = 0.8,
    duration = 0.5,
    cooldown = 8.0,

    hazard = {
        type = "poison_cloud",
        radius = 100,
        damage_per_second = 2,
        lifetime = 8.0,  -- Cloud lasts 8 seconds
        position = "player",  -- "boss", "player", "random", {x, y}
    },

    animation = "poison_cast",
}

M.fire_wave = {
    type = "hazard",
    telegraph_time = 1.0,
    duration = 1.0,
    cooldown = 6.0,

    hazard = {
        type = "fire_wave",
        width = 800,  -- Entire arena width
        height = 40,
        damage = 4,
        speed = 200,  -- Wave travel speed
        direction = "horizontal",  -- "horizontal", "vertical"
    },

    animation = "fire_cast",
}

M.root_spike = {
    type = "hazard",
    telegraph_time = 0.7,
    duration = 0.8,
    cooldown = 3.5,

    hazard = {
        type = "spike_trap",
        count = 5,  -- Number of spikes
        damage = 3,
        telegraph_duration = 0.5,  -- Warning markers
        active_duration = 1.0,  -- How long spikes stay up
        pattern = "line_to_player",  -- "line_to_player", "circle", "random"
    },

    animation = "root_attack",
}

--[[============================================================================
    SPECIAL / UNIQUE PATTERNS
==============================================================================]]

M.shadow_clones = {
    type = "special",
    telegraph_time = 1.5,
    duration = 10.0,  -- Clones last 10 seconds
    cooldown = 20.0,

    special = {
        type = "clone",
        count = 2,
        clone_health_percent = 0.3,  -- Clones have 30% of boss health
        clone_damage_percent = 0.5,  -- Clones deal 50% damage
        mirror_attacks = true,  -- Clones copy boss attacks
    },

    animation = "split",
}

M.blade_storm = {
    type = "special",
    telegraph_time = 2.0,
    duration = 5.0,
    cooldown = 15.0,

    special = {
        type = "blade_storm",
        projectile_count = 30,
        spawn_rate = 6,  -- Projectiles per second
        damage = 2,
        speed = 300,
        pattern = "spiral",  -- "spiral", "random", "burst"
    },

    animation = "blade_storm",
}

M.teleport_strike = {
    type = "special",
    telegraph_time = 0.6,
    duration = 0.4,
    cooldown = 5.0,

    special = {
        type = "teleport_attack",
        teleport_to = "behind_player",  -- "behind_player", "random", "arena_center"
        attack_damage = 4,
        attack_range = 60,
    },

    animation = "teleport",
}

M.dark_beam = {
    type = "beam",
    telegraph_time = 2.0,
    duration = 3.0,
    cooldown = 10.0,

    beam_length = 600,
    beam_width = 30,
    damage_per_second = 3,
    tracking = true,  -- Beam follows player
    tracking_speed = 45,  -- Degrees per second

    animation = "dark_beam",
}

M.overload = {
    type = "special",
    telegraph_time = 1.5,
    duration = 0.5,
    cooldown = 999,  -- One-time attack

    special = {
        type = "explosion",
        radius = 200,
        damage = 10,
        self_damage = 20,  -- Boss damages itself
        knockback = 400,
    },

    animation = "overload",
}

--[[============================================================================
    COMBO / SEQUENCE PATTERNS
==============================================================================]]

M.berserk_combo = {
    type = "combo",
    telegraph_time = 0.4,
    duration = 2.5,
    cooldown = 5.0,

    combo = {
        {pattern = "dash_slash", delay = 0.0},
        {pattern = "sword_combo", delay = 0.8},
        {pattern = "ground_slam", delay = 1.8},
    },

    animation = "berserk_start",
}

M.ultimate_combo = {
    type = "combo",
    telegraph_time = 1.0,
    duration = 5.0,
    cooldown = 12.0,

    combo = {
        {pattern = "teleport_strike", delay = 0.0},
        {pattern = "shadow_barrage", delay = 1.0},
        {pattern = "dash_slash", delay = 2.5},
        {pattern = "dark_beam", delay = 3.5},
    },

    animation = "ultimate",
}

--[[============================================================================
    GRAB / THROW PATTERNS
    These pin the player on contact, hold them for `duration`, then release
    with a throw knockback. Requires grab_start/grab_hold/grab_throw
    animation keys on the boss rig.
==============================================================================]]

M.grab_and_throw = {
    type = "grab",
    telegraph_time = 0.6,
    duration = 1.8,  -- total pattern duration (includes hold + throw)
    cooldown = 7.0,

    grab = {
        reach = 110,
        width = 110,
        height = 90,
        damage = 4,
        duration = 1.0,           -- how long the player is held
        throw_knockback = 420,
        throw_knockback_y = 240,
    },

    animation = "grab_start",
}

M.titan_grab_slam = {
    -- Grab then immediately slam: held duration is short, throw knockback
    -- is mostly vertical so the player is smashed into the ground.
    type = "grab",
    telegraph_time = 0.8,
    duration = 2.2,
    cooldown = 10.0,

    grab = {
        reach = 140,
        width = 140,
        height = 120,
        damage = 6,
        duration = 0.6,
        throw_knockback = 120,
        throw_knockback_y = -600,
    },

    animation = "grab_start",
}

--[[============================================================================
    HEAL PATTERNS
==============================================================================]]

M.boss_self_heal = {
    type = "heal",
    telegraph_time = 1.2,
    duration = 2.5,
    cooldown = 18.0,

    heal = {
        amount = 8,
        ticks = 5,
        interval = 0.4,
    },

    animation = "heal",
}

--[[============================================================================
    BUFF PATTERNS
    Temporary multipliers applied to the boss itself — no damage to player.
==============================================================================]]

M.enrage_buff = {
    type = "buff",
    telegraph_time = 0.6,
    duration = 1.2,
    cooldown = 15.0,

    buff = {
        duration = 6.0,
        damage_multiplier = 1.5,
        speed_multiplier = 1.3,
    },

    animation = "enrage",
}

M.defensive_stance = {
    type = "buff",
    telegraph_time = 0.4,
    duration = 1.0,
    cooldown = 12.0,

    buff = {
        duration = 5.0,
        defense_bonus = 2,
        speed_multiplier = 0.8,
    },

    animation = "shield_up",
}

--[[============================================================================
    SHIELD PATTERNS
    Absorbs incoming damage until HP pool is depleted or duration expires.
==============================================================================]]

M.absorb_shield = {
    type = "shield",
    telegraph_time = 0.5,
    duration = 1.0,
    cooldown = 14.0,

    shield = {
        hp = 30,
        duration = 6.0,
    },

    animation = "shield_up",
}

--[[============================================================================
    PARRY WINDOW PATTERNS
    Opens a counter-attack window; if struck during the window, the boss
    fires `counter_pattern` at the attacker.
==============================================================================]]

M.counter_stance = {
    type = "parry_window",
    telegraph_time = 0.3,
    duration = 0.8,
    cooldown = 6.0,

    parry_window = {
        window = 0.5,
        counter_pattern = "dash_slash",
    },

    animation = "parry",
}

--[[============================================================================
    ENVIRONMENTAL PATTERNS
    Trigger arena hazards / collapse / falling rocks through the arena event
    bus. Targeted hazards listen for mvtk_arena_event.
==============================================================================]]

M.ceiling_collapse = {
    type = "environmental",
    telegraph_time = 1.5,
    duration = 3.0,
    cooldown = 20.0,

    environmental = {
        event = "ceiling_collapse",
        spawner_ids = {},  -- leave empty to broadcast to arena only
        duration = 3.0,
        intensity = 1.0,
    },

    animation = "roar",
}

M.arena_pulse = {
    type = "environmental",
    telegraph_time = 0.6,
    duration = 1.5,
    cooldown = 10.0,

    environmental = {
        event = "hazard_pulse",
        intensity = 1.5,
    },

    animation = "taunt",
}

--[[============================================================================
    MINE / TRAP PATTERNS
    Deploy stationary hitboxes that trigger on player contact.
==============================================================================]]

M.plant_mine = {
    type = "mine",
    telegraph_time = 0.4,
    duration = 0.5,
    cooldown = 5.0,

    mine = {
        radius = 56,
        damage = 3,
        lifetime = 8.0,
        arm_delay = 0.6,
        position = "boss",   -- or "player" to plant at player feet
        knockback = 280,
    },

    animation = "cast_start",
}

M.shadow_trap = {
    type = "mine",
    telegraph_time = 0.3,
    duration = 0.4,
    cooldown = 4.0,

    mine = {
        radius = 40,
        damage = 2,
        lifetime = 12.0,
        arm_delay = 0.3,
        position = "player",
    },

    animation = "summon",
}

--[[============================================================================
    WAVE PATTERNS
    Expanding ring AOEs — players caught inside any active ring take damage.
==============================================================================]]

M.shockwave = {
    type = "wave",
    telegraph_time = 0.8,
    duration = 1.6,
    cooldown = 9.0,

    wave = {
        rings = 3,
        ring_delay = 0.35,
        radius_step = 90,
        thickness = 44,
        damage = 3,
        knockback = 260,
    },

    animation = "slam",
}

M.pulse_nova = {
    type = "wave",
    telegraph_time = 1.0,
    duration = 2.5,
    cooldown = 12.0,

    wave = {
        rings = 5,
        ring_delay = 0.3,
        radius_step = 70,
        thickness = 36,
        damage = 2,
    },

    animation = "cast_loop",
}

return M
