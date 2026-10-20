-- mvtk/player/player_jump_math.lua
-- Pure jump-speed math extracted from player_state.lua as part of Phase 5
-- step 31. These helpers compute initial vertical velocity from the
-- authored jump_height + gravity values using the standard kinematics
-- equation v = sqrt(2 * |g| * h). They take all inputs as arguments and
-- have no side effects, so they are safe to call from any context.

local M = {}

--- Compute the initial jump speed for the configured jump height.
-- If `cfg.jump_speed` is provided and positive it is returned verbatim
-- (lets creators override the derived speed). Otherwise derives from
-- gravity and jump_height with sensible fallbacks.
function M.compute_jump_speed(cfg)
    cfg = cfg or {}
    if cfg.jump_speed and cfg.jump_speed > 0 then
        return cfg.jump_speed
    end
    local g = math.abs(cfg.gravity or 1200)
    local h = cfg.jump_height or 256
    return math.sqrt(2 * g * h)
end

--- Compute the extended-jump speed bonus from cfg.extended_jump_height.
-- Used when the player holds the jump button for the extended-jump
-- mechanic. Falls back to gravity=1200, height=64 to match the prior
-- inline defaults.
function M.compute_extended_jump_speed(cfg)
    cfg = cfg or {}
    local g = math.abs(cfg.gravity or 1200)
    local extended_h = cfg.extended_jump_height or 64
    return math.sqrt(2 * g * extended_h)
end

return M
