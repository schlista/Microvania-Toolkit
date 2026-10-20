-- developer/config/boss_defaults.lua
-- Centralized defaults for boss behaviour.
--
-- These values are used whenever an individual boss (in developer/config/boss_types.lua)
-- or an attack pattern (in mvtk/bosses/patterns/attack_patterns.lua) does not provide
-- its own value. Tuning these affects *every* boss that relies on defaults.
--
-- All distances are in pixels. All times are in seconds.

return {
    -- -------------------------------------------------------------------------
    -- MOVEMENT
    -- -------------------------------------------------------------------------

    -- How fast a boss chases the player in its MOVING state (pixels / sec).
    chase_speed = 120,

    -- Boss stops to attack when within this distance of the player.
    attack_range = 150,

    -- Boss will not intentionally close the gap below this distance
    -- (prevents the boss from clipping into the player).
    min_chase_distance = 80,

    -- -------------------------------------------------------------------------
    -- ATTACKS & TELEGRAPHS
    -- -------------------------------------------------------------------------

    -- How long a telegraph/wind-up plays before the attack fires.
    -- Override per-attack via `telegraph_time` in the attack pattern.
    telegraph_time = 0.5,

    -- How long an attack's "active" portion lasts after the telegraph.
    -- Override per-attack via `duration` in the attack pattern.
    attack_duration = 1.0,

    -- Default range for melee boss attacks when a pattern omits `range`.
    melee_range = 120,

    -- -------------------------------------------------------------------------
    -- INVULNERABILITY / I-FRAMES
    -- -------------------------------------------------------------------------

    -- After the boss takes damage, how long it is immune to further hits.
    -- Prevents multi-hit moves from stunlocking or deleting health.
    iframes_on_hit = 0.20,

    -- How long the boss is invulnerable at the start of a boss phase transition.
    -- Gives the player a moment to read the new boss phase.
    iframes_on_phase_transition = 1.5,

    -- How often the invulnerability flash toggles the sprite tint.
    iframe_flash_period = 0.08,

    -- -------------------------------------------------------------------------
    -- DEFEAT / CLEANUP
    -- -------------------------------------------------------------------------

    -- Delay between the "defeat started" cinematic and full cleanup.
    -- Gives cutscene / loot / fade time to play.
    defeat_cleanup_delay = 2.0,

    -- -------------------------------------------------------------------------
    -- CONTACT DAMAGE (boss body -> player collision)
    -- -------------------------------------------------------------------------

    -- Damage applied when the player's hitbox overlaps the boss body.
    -- Per-boss override: boss_types[type].contact_damage in developer/config/boss_types.lua.
    contact_damage = 2,

    -- Horizontal knockback magnitude applied to the player on contact.
    -- Directed away from the boss, regardless of its current facing.
    contact_knockback_x = 120,

    -- Vertical knockback magnitude applied to the player on contact.
    contact_knockback_y = 80,

    -- Player recovery lock after boss contact or an attack without stun_t.
    -- Seconds; an individual attack may set stun_t = 0 to disable the lock.
    default_hit_stun = 0.20,

    -- -------------------------------------------------------------------------
    -- ATTACK DEFAULTS (used when an attack pattern omits the value)
    -- Pattern-level fields always win; these are the last-resort fallback.
    -- -------------------------------------------------------------------------

    default_melee_damage      = 2,
    default_melee_width       = 60,   -- hitbox half-width  (pixels)
    default_melee_height      = 80,   -- hitbox half-height (pixels)
    default_melee_knockback_x = 200,
    default_melee_knockback_y = 100,

    default_projectile_damage = 1,
    default_projectile_speed  = 300,  -- pixels / second
    default_projectile_life   = 3.0,  -- seconds before despawn

    default_aoe_damage        = 3,
    default_aoe_radius        = 150,
    default_aoe_delay         = 0.5,
    default_aoe_knockback     = 150,

    default_beam_damage       = 2,
    default_beam_length       = 400,
    default_beam_width        = 40,
    default_beam_duration     = 1.5,
    default_beam_windup       = 0.5,

    -- Fallback attack interval when a boss phase omits attack_interval.
    -- State machine uses (min, max) to jitter the gap between attacks.
    attack_interval_min = 2.0,
    attack_interval_max = 4.0,

    -- Safety valve: if state machine stays IDLE (no ready attack) for longer
    -- than this many seconds, log a warning. Prevents silent "boss just stands
    -- there" bugs in misconfigured encounters.
    idle_deadman_seconds = 8.0,

    -- -------------------------------------------------------------------------
    -- VISUALS
    -- -------------------------------------------------------------------------

    -- Source-art size the boss sprite was authored at. Used to compute runtime
    -- scale when a boss_types entry specifies a target size.
    default_sprite_size = 64,

    -- Tint color flashed over the sprite on hit (vmath.vector4 table form).
    hurt_flash_color = { 1.0, 0.25, 0.25, 1.0 },

    -- How long the hurt flash holds before reverting to white.
    hurt_flash_duration = 0.20,

    -- -------------------------------------------------------------------------
    -- UI
    -- -------------------------------------------------------------------------

    -- Whether the boss health bar is shown by default.
    show_health_bar = true,
}
