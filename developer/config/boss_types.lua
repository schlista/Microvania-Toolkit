--- Boss Type Definitions
-- Defines reusable boss presets: stats, fallback boss phases, rewards, audio, and
-- default visuals for the boss Tiled template.
--
-- AUTHORING NOTE
-- ============================================================================
-- New encounters should usually be authored in Tiled with:
--   boss.tx         - encounter-wide identity, visuals, rewards, audio
--   boss_arena.tx   - arena bounds, lock/camera behavior, shared music
--   boss_phase.tx   - attacks, movement, and transitions for each boss phase
--
-- boss_types.lua is the reusable preset layer under those Tiled objects.
-- Use it for starter bosses, shared defaults, and encounter families that
-- multiple rooms can reuse without copy/pasting values.
-- Boss HUD defaults can also live here with `show_health_bar` and
-- `health_bar_position` ("top" or "bottom"), then be overridden per
-- boss object in Tiled.
-- Optional attack_pixel_scale sets the framework attack's pixel multiplier
-- (unitless, safe >0..16). Omit it to use the project's tile width / 64.
-- It scales pixel speeds, sizes and knockback; times, angles and damage stay
-- unchanged. Authored charge_* overrides remain absolute world pixels.
--
-- VISUAL AUTHORING
-- ============================================================================
-- The active visual fields are:
--   boss_visual_type = "sprite" or "spine"
--   visual_component = "<component id on boss_runtime.go>"
--
-- Example sprite setup:
--   boss_visual_type = "sprite"
--   visual_component = "sprite_gate_warden"
--
-- Example Spine setup:
--   boss_visual_type = "spine"
--   visual_component = "spine"
--   rig clips = idle, move, hit, defend, death, attack_1..attack_5,
--   plus the boss phase transition clip configured in boss_animations.lua
--
-- `visual_component` must match a component id that exists on
-- developer/game/prefabs/boss_runtime.go and is registered in
-- developer/config/boss_visuals.lua.
-- The shared boss animation contract lives in
-- developer/config/boss_animations.lua and lets a Spine boss run with this
-- compact clip list:
--   idle, move, hit, defend, death, attack_1, attack_2, attack_3,
--   attack_4, attack_5, and the configured boss phase transition clip
--
-- See docs/CREATOR_WORKFLOW.html for the supported Tiled-first boss workflow.
-- ============================================================================
--
-- Public toolkit-facing preset ids follow the `<biome>_boss` convention:
--   default_boss, graveyard_boss, desert_boss, foundry_boss,
--   forest_boss, catacombs_boss, sanctum_boss, factory_boss, ruins_boss
-- Every preset uses only attacks defined in mvtk/bosses/patterns/attack_patterns.lua
-- (or your developer/config/attack_patterns.lua) and sets the flag
-- `<preset id>_defeated` when the boss falls. Author arena locking, item drops
-- and encounter-specific flags on the Tiled boss/boss_arena objects
-- (reward_drops, reward_unlock_flag) rather than in these shared presets.
--
-- @module boss_types

local BossTypes = {
    --[[========================================================================
        EXAMPLE BOSS - READY TO USE (No assets required)
    ========================================================================]]

    default_boss = {
        name = "Default Boss",
        description = "Asset-free starter boss for trying out a new encounter (no art needed)",

        -- Stats
        max_health = 50,
        defense = 0,
        damage_resistance = 1.0,

        -- Single boss phase (simple)
        phases = {
            {
                health_range = {min = 0.0, max = 1.0},
                attacks = {"test_melee", "test_projectile"},
                attack_interval = {min = 2.0, max = 4.0},
                behavior = "aggressive",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite_test",
        size = {width = 64, height = 64},

        -- No audio required
        audio = nil,

        -- Rewards
        on_defeat = {
            currency = {min = 50, max = 100},
            unlock_flag = "default_boss_defeated",
        },

        arena = nil,
    },

    --[[========================================================================
        STARTER BOSS: GATE WARDEN (uses starter atlas)
    ========================================================================]]
    graveyard_boss = {
        name = "Gate Warden",
        description = "A bulky sentinel that guards early-game routes",
        max_health = 80,
        defense = 1,
        damage_resistance = 1.0,

        phases = {
            {
                health_range = { min = 0.5, max = 1.0 },
                attacks = { "sword_combo", "dash_slash" },
                attack_interval = { min = 2.4, max = 3.6 },
                behavior = "cautious",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = { min = 0.0, max = 0.5 },
                attacks = { "ground_slam", "dash_slash", "sword_combo" },
                attack_interval = { min = 1.8, max = 3.0 },
                behavior = "aggressive",
                speed_multiplier = 1.1,
                damage_multiplier = 1.2,
                transition = {
                    type = "rage",
                    duration = 1.5,
                    invulnerable = true,
                    camera_shake = { intensity = 8, duration = 1.0 },
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite_gate_warden",
        size = { width = 96, height = 96 },
        audio = nil, -- use default/no audio

        on_defeat = {
            currency = { min = 80, max = 150 },
            unlock_flag = "graveyard_boss_defeated",
        },
        arena = nil,
    },

    --[[========================================================================
        DESERT BOSS: CACTUS COLOSSUS
    ========================================================================]]
    desert_boss = {
        name = "Cactus Colossus",
        description = "A relentless desert bruiser with slams, needle volleys, and charges",
        max_health = 110,
        defense = 1,
        damage_resistance = 1.0,
        -- Brisk repositioning keeps the long charge from creating several
        -- seconds of dead time when the player jumps it cleanly.
        chase_speed = 260,

        phases = {
            {
                health_range = { min = 0.5, max = 1.0 },
                attacks = { "cactus_ground_slam", "cactus_needle_volley" },
                attack_interval = { min = 1.4, max = 2.0 },
                attack_range = 320,
                behavior = "aggressive",
                movement_profile = "ground_chase",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = { min = 0.0, max = 0.5 },
                attacks = { "cactus_charge", "cactus_needle_volley", "cactus_ground_slam" },
                attack_interval = { min = 0.8, max = 1.4 },
                attack_range = 320,
                behavior = "berserk",
                movement_profile = "ground_chase",
                speed_multiplier = 1.1,
                damage_multiplier = 1.25,
                transition = {
                    type = "rage",
                    animation = "idle",
                    duration = 0.75,
                    invulnerable = true,
                    camera_shake = { intensity = 6, duration = 0.4 },
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite_cactus_boss",
        -- 64/64 means no GO scaling; the authored frames are already 362px.
        size = { width = 64, height = 64 },
        audio = nil,

        on_defeat = {
            currency = { min = 75, max = 125 },
            unlock_flag = "desert_boss_defeated",
        },
        arena = nil,
    },

    --[[========================================================================
        STARTER BOSS: ARENA SENTINEL (uses the starter boss art)
    ========================================================================]]
    foundry_boss = {
        name = "Arena Sentinel",
        description = "A sentinel construct that swipes, fires bursts and summons help",
        max_health = 120,
        defense = 1,
        damage_resistance = 1.0,

        phases = {
            {
                health_range = { min = 0.5, max = 1.0 },
                attacks = { "sentinel_swipe", "sentinel_burst" },
                attack_interval = { min = 2.2, max = 3.2 },
                behavior = "cautious",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = { min = 0.0, max = 0.5 },
                attacks = { "sentinel_slam", "sentinel_summon", "sentinel_burst" },
                attack_interval = { min = 1.6, max = 2.6 },
                behavior = "aggressive",
                speed_multiplier = 1.1,
                damage_multiplier = 1.2,
                transition = {
                    type = "rage",
                    animation = "phase_transition",
                    duration = 1.2,
                    invulnerable = true,
                    camera_shake = { intensity = 8, duration = 0.8 },
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite_arena_sentinel",
        audio = nil, -- use default/no audio

        on_defeat = {
            currency = { min = 80, max = 140 },
            unlock_flag = "foundry_boss_defeated",
        },
        arena = nil,
    },

    --[[========================================================================
        EARLY GAME BOSS (WARNING: Requires custom assets)
    ========================================================================]]

    forest_boss = {
        name = "Forest Guardian",
        description = "Ancient protector of the sacred grove",

        -- Stats
        max_health = 80,
        defense = 1,
        damage_resistance = 0.9,

        -- Boss phases
        phases = {
            {
                health_range = {min = 0.60, max = 1.0},
                attacks = {"vine_whip", "root_spike"},
                attack_interval = {min = 2.5, max = 4.0},
                behavior = "cautious",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = {min = 0.25, max = 0.60},
                attacks = {"vine_whip", "root_spike", "summon_thorns"},
                attack_interval = {min = 2.0, max = 3.0},
                behavior = "aggressive",
                speed_multiplier = 1.2,
                damage_multiplier = 1.2,
                transition = {
                    type = "cutscene",
                    animation = "grow_vines",
                    duration = 2.0,
                    invulnerable = true,
                    camera_shake = {intensity = 5, duration = 1.5},
                },
            },
            {
                health_range = {min = 0.0, max = 0.25},
                attacks = {"berserk_whip", "root_spike", "summon_thorns", "poison_cloud"},
                attack_interval = {min = 1.5, max = 2.5},
                behavior = "berserk",
                speed_multiplier = 1.5,
                damage_multiplier = 1.5,
                transition = {
                    type = "cutscene",
                    animation = "enrage",
                    duration = 2.5,
                    invulnerable = true,
                    camera_shake = {intensity = 10, duration = 2.0},
                },
            },
        },

        -- Replace `sprite` with your own sprite/spine component id when you
        -- wire in custom boss art.
        boss_visual_type = "sprite",
        visual_component = "sprite",
        size = {width = 128, height = 128},

        audio = nil,

        -- Rewards
        on_defeat = {
            currency = {min = 150, max = 250},
            unlock_flag = "forest_boss_defeated",
        },

        arena = nil,
    },

    --[[========================================================================
        MID GAME BOSS (WARNING: Requires custom assets)
    ========================================================================]]

    catacombs_boss = {
        name = "Crystal Golem",
        description = "Guardian of the underground crystal mines",

        max_health = 150,
        defense = 3,
        damage_resistance = 0.8,

        phases = {
            {
                health_range = {min = 0.70, max = 1.0},
                attacks = {"crystal_slam", "crystal_throw"},
                attack_interval = {min = 3.0, max = 5.0},
                behavior = "defensive",
                speed_multiplier = 0.8,
                damage_multiplier = 1.0,
            },
            {
                health_range = {min = 0.35, max = 0.70},
                attacks = {"crystal_slam", "crystal_throw", "laser_sweep"},
                attack_interval = {min = 2.5, max = 4.0},
                behavior = "aggressive",
                speed_multiplier = 1.0,
                damage_multiplier = 1.3,
                transition = {
                    type = "shield",
                    animation = "charge_crystal",
                    duration = 3.0,
                    invulnerable = true,
                    camera_shake = {intensity = 7, duration = 2.0},
                    spawn_hazards = {"crystal_spikes"},
                },
            },
            {
                health_range = {min = 0.0, max = 0.35},
                attacks = {"ground_slam", "crystal_barrage", "laser_sweep", "summon_crystals"},
                attack_interval = {min = 1.5, max = 3.0},
                behavior = "berserk",
                speed_multiplier = 1.3,
                damage_multiplier = 1.5,
                transition = {
                    type = "transform",
                    animation = "shatter_reform",
                    duration = 3.5,
                    invulnerable = true,
                    camera_shake = {intensity = 12, duration = 3.0},
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite",
        size = {width = 160, height = 160},
        audio = nil,

        on_defeat = {
            currency = {min = 300, max = 500},
            unlock_flag = "catacombs_boss_defeated",
        },

        arena = nil,
    },

    --[[========================================================================
        LATE GAME BOSS (WARNING: Requires custom assets)
    ========================================================================]]

    sanctum_boss = {
        name = "Shadow Knight",
        description = "Corrupted champion of the dark castle",

        max_health = 200,
        defense = 4,
        damage_resistance = 0.85,

        phases = {
            {
                health_range = {min = 0.75, max = 1.0},
                attacks = {"sword_combo", "dash_slash", "dark_wave"},
                attack_interval = {min = 2.0, max = 3.5},
                behavior = "skilled",
                speed_multiplier = 1.2,
                damage_multiplier = 1.0,
            },
            {
                health_range = {min = 0.40, max = 0.75},
                attacks = {"sword_combo", "dash_slash", "dark_wave", "summon_shadows"},
                attack_interval = {min = 1.5, max = 3.0},
                behavior = "aggressive",
                speed_multiplier = 1.4,
                damage_multiplier = 1.3,
                transition = {
                    type = "teleport",
                    animation = "shadow_merge",
                    duration = 2.0,
                    invulnerable = true,
                    teleport_to = "arena_center",
                },
            },
            {
                health_range = {min = 0.20, max = 0.40},
                attacks = {"berserk_combo", "shadow_clones", "dark_wave", "summon_shadows"},
                attack_interval = {min = 1.0, max = 2.5},
                behavior = "relentless",
                speed_multiplier = 1.6,
                damage_multiplier = 1.5,
                transition = {
                    type = "rage",
                    animation = "shadow_burst",
                    duration = 2.5,
                    invulnerable = true,
                    camera_shake = {intensity = 15, duration = 2.0},
                    arena_darkness = true,
                },
            },
            {
                health_range = {min = 0.0, max = 0.20},
                attacks = {"berserk_combo", "shadow_clones", "dark_wave", "blade_storm"},
                attack_interval = {min = 0.8, max = 2.0},
                behavior = "desperate",
                speed_multiplier = 1.8,
                damage_multiplier = 2.0,
                transition = {
                    type = "desperation",
                    animation = "final_form",
                    duration = 3.0,
                    invulnerable = true,
                    camera_shake = {intensity = 20, duration = 2.5},
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite",
        size = {width = 96, height = 128},
        audio = nil,

        on_defeat = {
            currency = {min = 500, max = 800},
            unlock_flag = "sanctum_boss_defeated",
        },

        arena = nil,
    },

    --[[========================================================================
        MINI-BOSS (WARNING: Requires custom assets)
    ========================================================================]]

    factory_boss = {
        name = "Corrupted Sentinel",
        description = "Malfunctioning guardian construct",

        max_health = 60,
        defense = 2,
        damage_resistance = 0.95,

        phases = {
            {
                health_range = {min = 0.50, max = 1.0},
                attacks = {"laser_shot", "dash_slash"},
                attack_interval = {min = 2.0, max = 3.5},
                behavior = "patrol",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = {min = 0.0, max = 0.50},
                attacks = {"laser_sweep", "dash_slash", "overload"},
                attack_interval = {min = 1.5, max = 2.5},
                behavior = "erratic",
                speed_multiplier = 1.3,
                damage_multiplier = 1.2,
                transition = {
                    type = "malfunction",
                    animation = "sparking",
                    duration = 1.5,
                    invulnerable = true,
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite",
        size = {width = 96, height = 96},
        audio = nil,

        on_defeat = {
            currency = {min = 80, max = 120},
            unlock_flag = "factory_boss_defeated",
        },

        arena = nil,
    },

    --[[========================================================================
        FINAL BOSS (WARNING: Requires custom assets)
    ========================================================================]]

    ruins_boss = {
        name = "The Dark Lord",
        description = "Ancient evil awakened",

        max_health = 300,
        defense = 5,
        damage_resistance = 0.75,

        phases = {
            {
                health_range = {min = 0.75, max = 1.0},
                attacks = {"sword_combo", "shadow_bolt", "teleport_strike"},
                attack_interval = {min = 2.5, max = 4.0},
                behavior = "testing",
                speed_multiplier = 1.0,
                damage_multiplier = 1.0,
            },
            {
                health_range = {min = 0.50, max = 0.75},
                attacks = {"sword_combo", "shadow_bolt", "teleport_strike", "summon_shadows"},
                attack_interval = {min = 2.0, max = 3.5},
                behavior = "aggressive",
                speed_multiplier = 1.2,
                damage_multiplier = 1.2,
                transition = {
                    type = "power_up",
                    animation = "dark_aura",
                    duration = 3.0,
                    invulnerable = true,
                    camera_shake = {intensity = 10, duration = 2.5},
                },
            },
            {
                health_range = {min = 0.25, max = 0.50},
                attacks = {"berserk_combo", "shadow_barrage", "teleport_strike", "summon_shadows", "dark_beam"},
                attack_interval = {min = 1.5, max = 3.0},
                behavior = "relentless",
                speed_multiplier = 1.4,
                damage_multiplier = 1.5,
                transition = {
                    type = "transform",
                    animation = "second_form",
                    duration = 4.0,
                    invulnerable = true,
                    camera_shake = {intensity = 15, duration = 3.0},
                    cutscene = true,
                },
            },
            {
                health_range = {min = 0.0, max = 0.25},
                attacks = {"ultimate_combo", "shadow_barrage", "dark_beam", "summon_shadows"},
                attack_interval = {min = 1.0, max = 2.5},
                behavior = "desperate",
                speed_multiplier = 1.6,
                damage_multiplier = 2.0,
                transition = {
                    type = "final_form",
                    animation = "ultimate_power",
                    duration = 5.0,
                    invulnerable = true,
                    camera_shake = {intensity = 20, duration = 4.0},
                    cutscene = true,
                },
            },
        },

        boss_visual_type = "sprite",
        visual_component = "sprite",
        size = {width = 192, height = 192},
        audio = nil,

        on_defeat = {
            currency = {min = 1000, max = 1500},
            unlock_flag = "ruins_boss_defeated",
        },

        arena = nil,
    },
}

return BossTypes
