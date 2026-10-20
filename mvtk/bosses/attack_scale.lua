-- Framework boss patterns use 64-pixel tiles. Resolve pixel values into the
-- project's units without changing angles, timing, damage or the shared source.
local M = {}

M.PIXEL_KEYS = {
    speed = true,             -- px/s: projectile, hazard or special movement
    dash_speed = true,        -- px/s: charge movement
    slam_speed = true,        -- px/s: downward movement
    dash_distance = true,     -- px: charge travel
    range = true,             -- px: attack range
    attack_range = true,      -- px: special attack range
    reach = true,             -- px: melee reach
    width = true,             -- px: attack width
    height = true,            -- px: attack height
    hitbox_half_width = true, -- px: horizontal hitbox half-size
    hitbox_half_height = true, -- px: vertical hitbox half-size
    radius = true,            -- px: circular attack radius
    radius_step = true,       -- px: radius increment
    spawn_radius = true,      -- px: spawn distance from the boss
    beam_length = true,       -- px: beam length
    beam_width = true,        -- px: beam width
    thickness = true,         -- px: ring or wave thickness
    jump_height = true,       -- px: attack jump height
    vertical_clearance = true, -- px: vertical space required by the attack
    edge_padding = true,      -- px: arena-edge clearance
    knockback = true,         -- px or px/s: horizontal knockback
    knockback_y = true,       -- px or px/s: vertical knockback
    throw_knockback = true,   -- px or px/s: horizontal throw knockback
    throw_knockback_y = true, -- px or px/s: vertical throw knockback
}

-- Recursive independent copy, including nested attack tables and arrays.
-- k is a positive, unitless factor supplied by the boss pattern resolver.
function M.scale_pattern(pattern, k)
    local out = {}
    for key, value in pairs(pattern) do
        if type(value) == "table" then
            out[key] = M.scale_pattern(value, k)
        elseif type(value) == "number" and M.PIXEL_KEYS[key] then
            out[key] = value * k
        else
            out[key] = value
        end
    end
    return out
end

return M
