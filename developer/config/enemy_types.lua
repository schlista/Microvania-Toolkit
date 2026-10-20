-- developer/config/enemy_types.lua
-- Starter enemy pack wired to existing behaviors/FX.
--
-- Each top-level key is the `enemy_type` referenced from Tiled exports and
-- room_enemies.lua. Treat the entries below as archetypes — duplicate one,
-- rename it, and tweak the numeric fields rather than editing in place.
--
-- Tuning ranges (the slime entry below is the baseline archetype):
--   health             1-50 hits-to-kill at base damage; pair with damage_dealt_mult.
--   damage             1-30 damage to player per contact/attack.
--   speed              30-200 px/s for ground; 100-400 for fliers.
--   detection_range    80-400 px. >400 reads as "always sees you".
--   chase_speed        usually 1.2-2.0x `speed`.
--   patrol_distance    60-400 px back-and-forth distance.
--   behavior           fallback behavior if a Tiled object omits movement/attack_pattern.
--   scale              0.5-2.0 visual scale. Keep 1.0 when the art is drawn at
--                      its in-game size (as the shipped skins are).
--   color              vmath.vector4(r, g, b, a). Used only when tint_skinned is enabled.
--   skin               optional default custom art skin id from Sync Enemy Art.
--                      Leave unset to use the shipped `default` enemy skin.
--   audio              optional combat SFX ids from the audio controller, e.g.
--                      audio = { hurt = "enemy_hurt", death = "enemy_death" }
--                      Set either value to false to silence that enemy sound.

local vmath = _G.vmath or { vector4 = function(...) return {...} end }

return {
    -- Slime (basic ground enemy)
    slime = {
        health = 2,
        damage = 1,
        speed = 50,

        behavior = "ground_patrol_chase",
        detection_range = 140,
        chase_speed = 80,
        patrol_distance = 180,
        scale = 0.9,
        color = vmath.vector4(0.3, 0.8, 0.3, 1.0),  -- Green slime
        animation_idle = "idle",
        animation_walk = "walk",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 180,
        knockback_resistance = 0.2,
        invincibility_time = 0.4,

        drops = { currency = { min = 1, max = 5, chance = 0.9 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Tumbleweed (rolling contact charger)
    -- Uses the matching developer/assets/enemies/tumbleweed_enemy art folder.
    tumbleweed_enemy = {
        health = 5,
        damage = 2,
        speed = 85,

        behavior = "chase_player,dash_attack",
        grounded_movement = true,
        detection_range = 360,
        chase_speed = 135,
        charge_speed = 240,
        charge_distance = 96,   -- Pixels traveled during each rolling charge.
        charge_cooldown = 2.0,  -- Seconds between charge starts.
        scale = 1.0,
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "walk",
        animation_attack = "charge",
        animation_charge = "charge",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 2,
        contact_damage_cooldown = 0.8,
        knockback_force = 280,
        knockback_resistance = 0.35,
        invincibility_time = 0.35,

        drops = { currency = { min = 4, max = 9, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Cactus (stationary radial needle shooter)
    -- `projectile_visual` selects the needle art without changing other enemy shots.
    cactus_enemy = {
        health = 6,
        damage = 1,
        speed = 0,

        behavior = "idle,shoot_circle",
        detection_range = 480,
        shoot_cooldown = 2.4,
        projectile_damage = 1,
        projectile_speed = 260,
        projectile_visual = "needle_projectile",
        scale = 1.0,
        animation_idle = "idle",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        contact_damage_cooldown = 0.8,
        knockback_force = 180,
        knockback_resistance = 0.5,
        invincibility_time = 0.4,

        drops = { currency = { min = 5, max = 12, chance = 1.0 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Bat enemy (ceiling ambush flyer)
    -- Place it at the ceiling height you want it to hang from. It stays in its
    -- hanging `idle` animation until the player enters detection_range, then
    -- swoops once and keeps darting left/right for the rest of the encounter.
    bat_enemy = {
        health = 3,
        damage = 1,
        speed = 150,

        behavior = "swoop_attack",
        ignores_terrain = true,
        detection_range = 320,
        swoop_speed = 300,       -- Initial diagonal dive speed in pixels/second.
        swoop_duration = 0.55,   -- Time spent on the first dive toward the player.
        dart_speed = 230,        -- Horizontal speed after the opening swoop.
        dart_interval = 0.85,    -- Seconds before reversing its dart direction.
        dart_vertical_speed = 95, -- How quickly later darts track the player's height.
        scale = 1.0,             -- Frames are drawn at in-game size (136 x 109).
        animation_idle = "idle",
        animation_walk = "fly",
        animation_run = "fly",
        animation_attack = "attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        contact_damage_cooldown = 0.65,
        knockback_force = 220,
        knockback_resistance = 0.1,
        invincibility_time = 0.35,

        drops = { currency = { min = 2, max = 6, chance = 0.9 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Ghost enemy (slow aerial follower with a proximity rise)
    -- The ghost begins with a gentle hover, follows once detected, and climbs
    -- above nearby players instead of firing a projectile attack.
    ghost_enemy = {
        health = 3,
        damage = 1,
        speed = 62,

        behavior = "ghost_float",
        ignores_terrain = true,
        detection_range = 280,
        chase_speed = 76,
        chase_speed_mult = 1.15,
        rise_range = 104,        -- Player distance that triggers the upward evade.
        rise_height = 88,        -- Desired height above a nearby player.
        rise_speed = 115,        -- Maximum upward evade speed in pixels/second.
        patrol_distance = 128,
        scale = 1.0,             -- Frames are drawn at in-game size (144 x 173).
        animation_idle = "fly_idle",
        animation_walk = "fly",
        animation_run = "fly",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        contact_damage_cooldown = 0.9,
        knockback_force = 170,
        knockback_resistance = 0.15,
        invincibility_time = 0.45,

        drops = { currency = { min = 3, max = 7, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Mummy enemy (slow ground pursuer with a timed arm swipe)
    -- The swipe uses the normal enemy damage payload after its short wind-up;
    -- attack_range/attack_height define the simple rectangular reach check.
    mummy_enemy = {
        health = 7,
        damage = 2,
        speed = 38,

        behavior = "chase_player,melee_swipe",
        grounded_movement = true,
        detection_range = 260,
        chase_speed = 46,
        attack_range = 76,
        attack_height = 58,
        attack_windup = 0.28,
        attack_cooldown = 1.45,
        scale = 1.0,             -- Frames are drawn at in-game size (152 x 182).
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "walk",
        animation_attack = "attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 2,
        contact_damage_cooldown = 1.0,
        knockback_force = 250,
        knockback_resistance = 0.55,
        invincibility_time = 0.4,

        drops = { currency = { min = 5, max = 11, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- ------------------------------------------------------------------
    -- Inkreach hand-drawn enemies. Their art lives in
    -- developer/assets/enemies/ink_* (drawn by
    -- developer/tools/tiled/inkreach_enemies.py). Each reuses a proven
    -- behavior above; only stats and art differ.
    -- ------------------------------------------------------------------

    -- Lantern moth (Whisperwood flyer): the bat's swoop-and-dart pattern.
    

    -- Ember imp (Cinder Works flyer): a faster, tougher moth.
    

    -- Drowned wisp (Sanctum and Catacombs ghost): the ghost's float and rise.
    

    -- Thorn crawler (Whisperwood walker): the mummy's chase and swipe, quicker
    -- and lighter.
    

    -- Slagling (Cinder Works walker): a heavier, glowing crawler.
    

    -- Bone walker (Catacombs walker): the mummy's chase and arm swipe.
    

    -- ===================== Lanternfall (pixel-art glow creatures) =====================
    -- Skins drawn by developer/tools/tiled/lanternfall_enemies.py at 160 x 128.
    
    
    
    
    
    

    -- Ground patrol
    crawler = {
        health = 3,
        damage = 1,
        speed = 60,

        behavior = "ground_patrol_chase",
        detection_range = 160,
        chase_speed = 90,
        patrol_distance = 220,
        scale = 1.0,
        color = vmath.vector4(0.2, 0.8, 0.3, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 200,
        knockback_resistance = 0.3,
        invincibility_time = 0.4,

        drops = { currency = { min = 3, max = 8, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Flyer (chase)
    screecher = {
        health = 2,
        damage = 1,
        speed = 110,

        behavior = "flying_chase",
        detection_range = 220,
        chase_speed = 140,
        hover_height = 60,
        scale = 0.9,
        color = vmath.vector4(0.4, 0.3, 0.6, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "run",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 240,
        knockback_resistance = 0.15,
        invincibility_time = 0.5,

        drops = { currency = { min = 2, max = 6, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Charger (rush attack)
    charger = {
        health = 5,
        damage = 2,
        speed = 40,

        behavior = "charger",
        detection_range = 260,
        charge_speed = 220,
        charge_distance = 360,
        charge_cooldown = 2.6,
        scale = 1.1,
        color = vmath.vector4(0.8, 0.4, 0.2, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "run",
        animation_attack = "charge",
        animation_charge = "charge",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 2,
        knockback_force = 320,
        knockback_resistance = 0.5,
        invincibility_time = 0.35,

        drops = { currency = { min = 8, max = 16, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
        aggro_sound = "ui_click",
    },

    -- Ranged skirmisher (projectile)
    marksman = {
        health = 4,
        damage = 1,
        speed = 70,

        behavior = "flying_patrol",
        detection_range = 260,
        chase_speed = 0, -- stays near patrol points
        patrol_points = {}, -- optional list of waypoints
        hover_height = 90,
        scale = 1.0,
        color = vmath.vector4(0.5, 0.7, 0.8, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 180,
        knockback_resistance = 0.25,
        invincibility_time = 0.35,

        shoots_projectiles = true,
        shoot_cooldown = 1.8,
        projectile_damage = 1,
        projectile_speed = 240,

        drops = { currency = { min = 5, max = 12, chance = 1.0 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Heavy bruiser (high knockback resist)
    bruiser = {
        health = 8,
        damage = 3,
        speed = 55,

        behavior = "ground_patrol_chase",
        detection_range = 220,
        chase_speed = 90,
        patrol_distance = 200,
        scale = 1.2,
        color = vmath.vector4(0.9, 0.7, 0.3, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 3,
        knockback_force = 260,
        knockback_resistance = 0.8,
        invincibility_time = 0.25,

        drops = { currency = { min = 10, max = 20, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Bat (fast flyer)
    bat = {
        health = 2,
        damage = 1,
        speed = 140,

        behavior = "chase",
        detection_range = 220,
        scale = 0.8,
        color = vmath.vector4(0.55, 0.35, 0.75, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "run",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 200,
        knockback_resistance = 0.1,
        invincibility_time = 0.35,

        drops = { currency = { min = 2, max = 5, chance = 0.9 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Bomber (spread shot patrol)
    bomber = {
        health = 3,
        damage = 1,
        speed = 70,

        behavior = "bomber",
        detection_range = 240,
        scale = 1.0,
        color = vmath.vector4(0.9, 0.4, 0.2, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 220,
        knockback_resistance = 0.2,
        invincibility_time = 0.35,

        drops = { currency = { min = 4, max = 9, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Ghost (floats through platforms, patrols + chases player)
    ghost = {
        health = 3,
        damage = 1,
        speed = 90,

        behavior = "ghost_float,shoot_random",
        detection_range = 240,
        chase_speed_mult = 1.2,     -- speed multiplier when chasing vs patrol
        ignores_terrain = true,     -- phases through platforms and ground tiles
        scale = 0.95,
        color = vmath.vector4(0.7, 0.9, 1.0, 0.75),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 180,
        knockback_resistance = 0.15,
        invincibility_time = 0.45,

        drops = { currency = { min = 3, max = 7, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Goblin (quick melee dasher)
    goblin = {
        health = 4,
        damage = 1,
        speed = 110,

        behavior = "patrol,dash",
        detection_range = 200,
        scale = 0.95,
        color = vmath.vector4(0.2, 0.7, 0.2, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "run",
        animation_attack = "charge",
        animation_charge = "charge",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 220,
        knockback_resistance = 0.25,
        invincibility_time = 0.35,

        drops = { currency = { min = 3, max = 7, chance = 0.9 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Skeleton (ranged patrol)
    skeleton = {
        health = 4,
        damage = 1,
        speed = 70,

        behavior = "ranged_patrol",
        detection_range = 240,
        scale = 1.0,
        color = vmath.vector4(0.9, 0.9, 0.8, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 200,
        knockback_resistance = 0.2,
        invincibility_time = 0.35,

        drops = { currency = { min = 4, max = 8, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Knight (heavy guard with shield + dash)
    knight = {
        health = 7,
        damage = 2,
        speed = 60,

        behavior = "guardian,dash",
        detection_range = 220,
        scale = 1.2,
        color = vmath.vector4(0.4, 0.5, 0.8, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_run = "run",
        animation_attack = "charge",
        animation_charge = "charge",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 2,
        knockback_force = 260,
        knockback_resistance = 0.6,
        invincibility_time = 0.3,

        drops = { currency = { min = 7, max = 14, chance = 1.0 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Spider (ground skirmisher)
    spider = {
        health = 3,
        damage = 1,
        speed = 70,

        behavior = "patrol",
        detection_range = 200,
        scale = 0.95,
        color = vmath.vector4(0.45, 0.35, 0.25, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 200,
        knockback_resistance = 0.2,
        invincibility_time = 0.4,

        drops = { currency = { min = 3, max = 7, chance = 0.9 } },
        hit_sound = "hit_melee",
        death_sound = "hit_melee",
    },

    -- Wizard (ranged caster)
    wizard = {
        health = 4,
        damage = 1,
        speed = 60,

        behavior = "ranged_patrol",
        detection_range = 260,
        scale = 1.0,
        color = vmath.vector4(0.6, 0.45, 0.9, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_attack = "ranged_attack",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 180,
        knockback_resistance = 0.2,
        invincibility_time = 0.4,

        drops = { currency = { min = 6, max = 14, chance = 1.0 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },

    -- Flying patrol (hovering scout)
    flying_patrol = {
        health = 2,
        damage = 1,
        speed = 90,

        behavior = "hover",
        detection_range = 220,
        hover_height = 48,
        scale = 0.9,
        color = vmath.vector4(0.45, 0.6, 0.9, 1.0),
        animation_idle = "idle",
        animation_walk = "walk",
        animation_hit = "hurt",
        animation_death = "death",

        contact_damage = 1,
        knockback_force = 220,
        knockback_resistance = 0.15,
        invincibility_time = 0.45,

        drops = { currency = { min = 2, max = 6, chance = 0.9 } },
        hit_sound = "hit_projectile",
        death_sound = "hit_projectile",
    },
}
