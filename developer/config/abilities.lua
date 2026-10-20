-- developer/config/abilities.lua
-- Centralised ability metadata consumed by mvtk.abilities.ability_manager

local AbilityConfig = {
    stamina = {
        max = 100,
        regen_per_sec = 25,
    },
    abilities = {
        -- Movement
        double_jump = {
        name = "Double Jump",
        description = "Jump again while in the air",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
        air_dash = {
        name = "Air Dash",
        description = "Dash through the air in any direction",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 1.0,
        stamina_cost = 10,
    },
        wall_climb = {
        name = "Wall Climb",
        description = "Cling to and climb walls",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 5,
    },
        slide = {
        name = "Slide",
        description = "Slide along the ground at high speed",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0.5,
        stamina_cost = 5,
    },
        extended_jump = {
        name = "Extended Jump",
        description = "Hold jump for extra height and hang time",
        category = "movement",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },

        grapple = {
        name = "Grapple",
        description = "Hold to catch any ceiling; steer to swing and release to leap",
        category = "movement",
        enabled = true,
        -- Must be picked up: Lanternfall grants it at the Rite of the Hook.
        -- true here would force-unlock it on every save load, overriding
        -- ability_defaults.lua (see ability_manager.load_save_data).
        starts_unlocked = false,
        cooldown = 0, -- Continuous ceiling chains never wait on ability cooldown.
        stamina_cost = 0, -- Exploration grapples do not consume a limited resource.
    },


        -- Combat
        charge_attack = {
        name = "Charge Attack",
        description = "Hold attack to charge up a powerful strike",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 2.0,
        stamina_cost = 20,
    },
        down_strike = {
        name = "Down Strike",
        description = "Strike downward while in the air",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 1.5,
        stamina_cost = 15,
    },
        ranged_attack = {
        name = "Ranged Attack",
        description = "Launch projectiles at enemies",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 0.8,
        stamina_cost = 10,
    },

        dash = {
        name = "Dash",
        description = "Hold Slide after a ground slide to run at Run Speed",
        category = "movement",
        enabled = true,
        cooldown = 0.5,
        stamina_cost = 5,
    },

        glide = {
        name = "Glide",
        description = "Hold JUMP while falling to glide",
        category = "movement",
        enabled = true,
        cooldown = 0,
        stamina_cost = 2,
    },

        ground_pound = {
        name = "Ground Pound",
        description = "Press DOWN while airborne to slam downward",
        category = "combat",
        enabled = true,
        cooldown = 1.0,
        stamina_cost = 10,
    },

        swim = {
        name = "Swim",
        description = "Move through water",
        category = "movement",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },

        wall_jump = {
        name = "Wall Jump",
        description = "Jump off walls",
        category = "movement",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },

        -- Defensive / utility
        slide_iframes = {
        name = "Slide Invincibility",
        description = "Become invulnerable during slide",
        category = "defensive",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
        },
        air_dash_iframes = {
        name = "Dash Invincibility",
        description = "Become invulnerable during air dash",
        category = "defensive",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
    }
}

return AbilityConfig
