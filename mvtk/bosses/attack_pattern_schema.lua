--- Attack Pattern Schema
-- Validates and normalises boss attack patterns from
-- mvtk/bosses/patterns/attack_patterns.lua (or any user-supplied source).
--
-- A valid pattern is a table with at minimum `type`. All other fields have
-- documented defaults in developer/config/boss_defaults.lua.
--
-- Supported fields (all optional unless noted):
--   type            — REQUIRED. "melee" | "projectile" | "aoe" | "beam"
--                     | "summon" | "special" | "charge" | "hazard" | "combo"
--                     | "grab" | "heal" | "buff" | "shield"
--                     | "parry_window" | "environmental" | "mine" | "wave"
--   telegraph_time  — seconds of wind-up before hit frames
--   duration        — seconds of active hit frames
--   cooldown        — seconds before this pattern can fire again
--   damage          — base damage (multiplied by boss.damage_multiplier)
--   range           — max horizontal reach / spawn distance
--   width, height   — hitbox half-extents for melee/AOE
--   knockback       — horizontal knockback impulse
--   knockback_y     — vertical knockback impulse
--   iframes_on_hit  — override boss_defaults.iframes_on_hit for this attack
--   hitbox_group    — collision group for the spawned physics hitbox
--   telegraph_shape — "line" | "circle" | "cone" (boss_telegraph.lua)
--   telegraph_color — vmath.vector4 tint for the telegraph
--   telegraph_size  — { x = w, y = h } override
--   projectiles     — { count, spread, speed, lifetime, factory }
--   aoe             — { radius, delay, knockback, factory }
--   summon          — { count, enemy_type, spawn_radius, factory }
--   animation       — sprite animation id to play on the boss
--   sequence        — multi-step attack (array of sub-steps)
--
-- @module attack_pattern_schema

local M = {}

local VALID_TYPES = {
    melee = true, projectile = true, aoe = true, beam = true,
    summon = true, special = true,
    charge = true, hazard = true, combo = true,
    grab = true, heal = true, buff = true, shield = true,
    parry_window = true, environmental = true, mine = true, wave = true,
}

-- Validate a pattern. Returns (true) or (false, error_msg).
function M.validate(pattern, name)
    name = name or "?"
    if type(pattern) ~= "table" then
        return false, string.format("pattern '%s' is not a table", name)
    end
    if not pattern.type or not VALID_TYPES[pattern.type] then
        return false, string.format("pattern '%s' has invalid type '%s'",
            name, tostring(pattern.type))
    end
    if pattern.telegraph_time and pattern.telegraph_time < 0 then
        return false, string.format("pattern '%s' telegraph_time must be >= 0", name)
    end
    if pattern.type == "combo" and pattern.combo and type(pattern.combo) ~= "table" then
        return false, string.format("pattern '%s' combo must be a table", name)
    end
    if pattern.type == "hazard" and pattern.hazard and type(pattern.hazard) ~= "table" then
        return false, string.format("pattern '%s' hazard must be a table", name)
    end
    return true
end

-- Validate every entry in a patterns module. Returns count + error list.
function M.validate_all(patterns)
    local errors = {}
    local count = 0
    for name, pat in pairs(patterns or {}) do
        if type(pat) == "table" then
            count = count + 1
            local ok, err = M.validate(pat, name)
            if not ok then
                errors[#errors + 1] = err
            end
        end
    end
    return count, errors
end

return M
