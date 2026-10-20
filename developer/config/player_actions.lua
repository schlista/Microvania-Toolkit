-- developer/config/player_actions.lua
-- Tunables for player abilities/actions. Read by gameplay when implemented.

local M = {
  -- Melee
  melee_light = {
    cooldown = 0.18,
    damage = 1,
    range_px = 48,
    knockback_px = 80,
    -- Optional: action barrier tag sent as attack_type in damage payload.
    -- Example: set to "dash" so this move can open required_action="dash" barriers.
    action_tag = "",
    active = 0.18,
    recovery = 0.14,
    stun_t = 0.12,
    -- Animation lock (seconds). Safety cap only - anim.done releases the lock early.
    -- Keep this short: if anim.done fails to fire, player is frozen this long.
    anim_lock = 0.35,
  },

  -- Down Strike / Pogo
  down_strike = {
    enabled = true,
    trigger = "light_melee",   -- use LIGHT_MELEE when holding down
    require_down_threshold = 0.6,
    bounce_speed = 1000,        -- vertical bounce on hit
    -- Optional: action barrier tag sent as attack_type.
    action_tag = "",
    hitbox_lifetime = 0.18,
    damage = 1,
    knockback_px = 0,           -- usually no horizontal knockback on pogo
    stun_t = 0.15,
    -- Animation lock safety cap - anim.done releases early.
    anim_lock = 0.45,
  },

  melee_heavy = {
    cooldown = 0.40,
    damage = 2,
    range_px = 56,
    knockback_px = 140,
    -- Optional: action barrier tag sent as attack_type.
    action_tag = "",
    active = 0.35,
    recovery = 0.22,
    stun_t = 0.25,
    -- Animation lock safety cap - anim.done releases early.
    anim_lock = 0.55,
  },

  -- Ranged
  ranged = {
    cooldown = 0.35,
    damage = 1,
    -- Optional: action barrier tag sent as attack_type.
    action_tag = "",
    projectile_speed = 1200,
    lifetime = 1.5,
    offset = { x = 24, y = 18 },
  },

  -- Movement Contact Attacks
  -- These let movement abilities emit attack payloads for action barriers.
  -- Set `required_action` on the barrier in Tiled to match `action_tag` below.
  air_dash = {
    contact_attack = {
      enabled = true,         -- default on so dash barriers work out of the box
      action_tag = "dash",    -- matches gate.required_action
      damage = 0,             -- set > 0 if dash should also deal damage
      knockback_px = 80,
      stun_t = 0.08,
      hit_enemy = false,      -- set true if dash should also damage enemies
      hit_breakable = true,   -- allows hitting action barriers/breakables
      offset_x = 0,           -- local offset from player center
      offset_y = 0,
      lifetime_pad = 0.04,    -- extra time added to current dash state
    },
  },

  slide = {
    contact_attack = {
      enabled = true,
      action_tag = "slide",
      damage = 1,
      knockback_px = 60,
      stun_t = 0.08,
      hit_enemy = false,
      hit_breakable = true,
      offset_x = 0,
      offset_y = 0,
      lifetime_pad = 0.04,
    },
  },

  backdash = {
    contact_attack = {
      enabled = false,
      action_tag = "backdash",
      damage = 0,
      knockback_px = 60,
      stun_t = 0.08,
      hit_enemy = false,
      hit_breakable = true,
      offset_x = 0,
      offset_y = 0,
      lifetime_pad = 0.04,
    },
  },

  ground_pound = {
    contact_attack = {
      enabled = true,         -- Active only during a slam; hits enemies and pound-only floors.
      action_tag = "ground_pound",
      damage = 2,             -- Health points dealt to enemies during the slam.
      knockback_px = 90,
      stun_t = 0.14,
      hit_enemy = true,
      hit_breakable = true,
      offset_x = 0,
      -- "feet": offset_y is measured from the player's feet, so the 100 px tall
      -- hitbox reaches half into the floor at any body size. "origin" measures
      -- from the player's origin, like the other movement hitboxes.
      anchor = "feet",
      offset_y = 0,            -- Pixels above (+) or below (-) the anchor; safe -100..100.
      -- Safety cap in seconds (safe 3..10), for a slam that never ends.
      -- Landing or cancellation clears the hitbox sooner.
      lifetime = 3.0,
    },
    -- Slam feedback (presentation only). "" or 0 turns a part off.
    feedback = {
      -- Player animation state shown while slamming, in place of the fall
      -- pose. Any state the player has (crouch_idle, roll, air_spin...); ""
      -- keeps the fall pose.
      slam_animation = "crouch_idle",
      -- Effects from developer/config/fx_types.lua played at the feet on
      -- landing: a list of names, or "" for none.
      impact_fx = { "ground_pound", "crit_hit" },
      impact_shake = 10,          -- Camera shake on landing in pixels (0 = none; safe 0..30). Needs Camera Shake on.
      impact_shake_time = 0.16,   -- Seconds the shake lasts; safe 0..1.
      impact_hitstop = 0.03,      -- Freeze-frame on landing in seconds (0 = none; safe 0..0.1).
      impact_rumble = 0.45,       -- Controller rumble strength (0 = none; safe 0..1).
      impact_rumble_ms = 120,     -- Rumble length in milliseconds; safe 0..500.
    },
  },

  -- Parry
  parry = {
    window = 0.18,      -- press-to-parry active window
    cooldown = 0.15,
    perfect_window = 0.08,
  },

  -- Grapple targeting, timing and appearance. Movement and rope dimensions
  -- live in player_settings.grapple, where player_scale applies once.
  grapple = {
    range_px = 800, -- Fallback reach; creator player.grapple is the runtime override.
    pull_speed = 1000, -- Used when selecting mode="pull" instead of swinging.
    cooldown = 0.08, -- Minimum delay before a newly released hook can fire again.
    latch_groups = { "solid", "world" }, -- Terrain undersides accepted only in targets="ceilings"; tagged grapple is always targeted.
    block_groups = { "solid", "world" }, -- Stops the hook and cuts the rope; excludes one-way platforms.
    default_aim = "up", -- Neutral and Up aim up; sides aim diagonally up. Down is ignored. "forward" aims toward facing when neutral.
    diagonal_angle_deg = 45, -- Diagonal aim angle above horizontal.
    aim_assist_deg = 12, -- Maximum grounded assist angle; zero disables grounded extra rays.
    aim_assist_air_deg = 20, -- Maximum airborne assist angle, replacing aim_assist_deg in the air; zero disables airborne extra rays.
    aim_assist_step_deg = 6, -- Assist ray spacing in degrees, trying the input/facing side first.
    ceiling_normal_min = 0.5, -- Minimum downward normal for untagged ceiling faces.
    wall_normal_min = 0.7, -- Minimum horizontal normal for untagged walls when allowed.
    attach_grace_s = 0.12, -- Ignore impact release immediately after attaching, in seconds.
    ladder_grab_delay_s = 0.25, -- Seconds before a ladder may catch after a momentum-preserving release.
    rope_check = true, -- Check each frame that the anchor still exists and terrain does not cut the rope.
    aim_deadzone = 0.3, -- Ignore small controller stick drift while aiming.
    -- Grapple style and Stay hooked are configured in player_settings.grapple.
    release_on_jump = true, -- Jump also lets go, useful for chained aerial moves.
    release_carry_brake = 0.35, -- Fraction of normal air braking when steering against released swing momentum.
    max_duration = 0, -- Zero allows unlimited attachment while the button is held.
    rope_enabled = true, -- Draw the actual rope using the player prefab's baked sprite.
    rope_width_px = 3, -- Thin rope remains readable against dark backgrounds.
    rope_color = { 1.0, 0.84, 0.44, 1.0 }, -- Warm gold RGBA, values from zero to one.
    -- Offset from player Z (0.90 here). Keep the total inside the camera's
    -- -1..1 depth range and below the foreground scenery at 0.96.
    rope_z = 0.02,
  },

  -- Interact (contextual)
  interact = {
    hold_time = 0.0,    -- 0 = tap
  },

  -- Consumables
  potion = {
    heal_amount = 1,
    cooldown = 0.1,
    item_id = "potion_small",
    alternate_item = "potion_large",
  },

  -- Charge Attack (hold light, release for charged strike)
  charge_attack = {
    enabled = true,
    threshold = 0.45,      -- seconds to charge
    damage_mult = 2.5,
    knockback_mult = 1.8,
    -- Optional: action barrier tag sent as attack_type.
    action_tag = "",
    -- Animation lock safety cap - anim.done releases early.
    anim_lock = 0.55,
  },
}

return M
