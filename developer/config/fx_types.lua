-- developer/config/fx_types.lua
-- ============================================================================
-- Particle effect registry consumed by mvtk/fx/fx_manager.script.
-- ============================================================================
-- Each entry maps a logical fx_type (the string the gameplay code posts via
-- `play_fx` / `spawn_effect`) to one or more particlefx component ids that
-- live on the fx_manager game object. The fx_manager tries components in
-- order and stops at the first that resolves successfully, so list a
-- "primary" component followed by progressively-more-generic fallbacks.
--
-- Adding a new effect:
--   1. Add a `particlefx` component to fx_manager.go in the editor.
--   2. Add an entry below mapping your fx_type to that component id.
--   3. (Optional) list fallback ids in case the primary component is missing
--      from a stripped distribution.
--
-- Component ids are resolved via Defold's `#component` syntax internally;
-- list them WITHOUT the leading `#` here. The fx_manager prepends it.
--
-- `default_fallback` is used by anything not explicitly listed below.
-- Keep it pointing at a known-safe component (e.g. a generic sparkle) so
-- gameplay code can fire-and-forget without missing-component errors.
-- ============================================================================

local M = {}

M.default_fallback = { "sparkle", "unlock_sparkle" }

-- Aliases let several fx_type strings share the same effect (useful for
-- backward compatibility when renaming an effect). Keys are the alias,
-- values are the canonical fx_type to dispatch as.
M.aliases = {
    dash_trail = "dash",
    hit_impact = "crit_hit",
    unlock_sparkle = "unlock",
    marker_ping = "marker_placed",
}

-- Effects that need a vertical offset applied to the supplied position
-- before the particle plays. Keys are fx_type, values are a vector offset
-- (numeric y; full vector3 also accepted).
M.position_offsets = {
    land = { x = 0, y = -8, z = 0 },
    ground_pound = { x = 0, y = -8, z = 0 },
}

-- Effects that should stop any active instance before re-playing. Useful for
-- one-shot bursts that overlap awkwardly when re-triggered too quickly.
M.stop_before_play = {
    death_explosion = true,
}

-- Default minimum z used to ensure FX render in front of tilemap layers when
-- the caller passes position.z = 0.
M.default_min_z = 0.5
M.effects_needing_min_z = {
    death_explosion = true,
    ground_pound = true,   -- dust must draw in front of the floor tiles
}

-- Main registry. Each entry: { components = {primary, fallback1, fallback2, ...} }
-- Keep the most-specific component first.
M.effects = {
    land             = { components = { "land_puff" } },
    ground_pound     = { components = { "dust_cloud", "land_puff" } },  -- Ground Pound landing dust
    dash             = { components = { "dash_puff" } },
    crit_hit         = { components = { "crit_hit" } },
    unlock           = { components = { "unlock_sparkle", "sparkle" } },
    marker_placed    = { components = { "marker_ping", "ping" } },
    wall_break       = { components = { "wall_break", "dust_cloud" } },
    secret_reveal    = { components = { "secret_reveal", "unlock_sparkle" } },
    ambient_sparkle  = { components = { "ambient_sparkle", "sparkle" } },
    collectible_sparkle = { components = { "sparkle", "unlock_sparkle" } },
    death_explosion  = { components = { "death_explosion", "sparkle" } },
    boss_phase_transition = { components = { "boss_phase_transition" } },

    -- Hazard / status aliases configured in developer/config/hazard_types.lua.
    -- These reuse existing components so we never dispatch to missing ids.
    burn             = { components = { "crit_hit", "sparkle" } },
    blood_splat      = { components = { "crit_hit", "sparkle" } },
    acid_splash      = { components = { "crit_hit", "sparkle" } },
    ice_crystals     = { components = { "crit_hit", "sparkle" } },
    lightning_flash  = { components = { "crit_hit", "sparkle" } },
    sparks           = { components = { "crit_hit", "sparkle" } },
}

return M
