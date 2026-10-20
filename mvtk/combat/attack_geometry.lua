-- mvtk/combat/attack_geometry.lua
-- Shared geometry helpers for enemy & boss attacks.
--
-- Pure math, no side effects. Used by:
--   * mvtk/bosses/boss_attacks.lua     (multi-type boss attacks)
--   * mvtk/enemies/patterns/attack_patterns.lua (enemy pattern execution)
--
-- Keeping these in one place avoids the "copy-paste angle math" drift between
-- boss and enemy code that the robustness review flagged.

local M = {}

-- Compute a list of angles (radians) for a spread/fan attack.
-- count: number of projectiles to spawn (>=1)
-- arc_deg: total arc of the spread in degrees (0 = all on base_angle)
-- base_angle: center angle in radians (e.g. atan2(dy, dx) toward the player)
-- Returns a list of `count` radian angles.
--
--   M.compute_spread_angles(1, 0, 0)          --> {0}
--   M.compute_spread_angles(3, 30, 0)         --> {-0.26, 0, 0.26} approx
function M.compute_spread_angles(count, arc_deg, base_angle)
    count = math.max(1, math.floor(tonumber(count) or 1))
    arc_deg = tonumber(arc_deg) or 0
    base_angle = tonumber(base_angle) or 0

    local angles = {}
    if count == 1 or arc_deg == 0 then
        for i = 1, count do angles[i] = base_angle end
        return angles
    end

    local arc_rad = math.rad(arc_deg)
    local step = arc_rad / (count - 1)
    local start = base_angle - arc_rad * 0.5
    for i = 1, count do
        angles[i] = start + step * (i - 1)
    end
    return angles
end

-- Normalized 2D aim vector from `from` to `to`.
-- Accepts anything with .x/.y (vector3, vector2, table). Returns vmath.vector3(1,0,0)
-- when the two points coincide, so callers can safely multiply by a speed.
function M.aim_vector(from, to)
    local dx = (to.x or 0) - (from.x or 0)
    local dy = (to.y or 0) - (from.y or 0)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then
        return vmath.vector3(1, 0, 0)
    end
    return vmath.vector3(dx / len, dy / len, 0)
end

function M.distance_2d(from, to)
    local dx = (to.x or 0) - (from.x or 0)
    local dy = (to.y or 0) - (from.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end

-- Circle hit-test — is `point` within `radius` of `center`?
-- Uses squared distance to avoid a sqrt.
function M.point_in_circle(center, radius, point)
    local dx = (point.x or 0) - (center.x or 0)
    local dy = (point.y or 0) - (center.y or 0)
    local r = tonumber(radius) or 0
    return (dx * dx + dy * dy) <= (r * r)
end

-- Axis-aligned box hit-test — is `point` inside the hitbox centered on `center`?
-- half_w/half_h are HALF-extents (i.e. full width = 2*half_w).
function M.point_in_box(center, half_w, half_h, point)
    return math.abs((point.x or 0) - (center.x or 0)) <= (tonumber(half_w) or 0)
       and math.abs((point.y or 0) - (center.y or 0)) <= (tonumber(half_h) or 0)
end

-- Beam hit-test — is `point` inside the beam swept from `origin` along `dir`
-- for `length` units, with `width` total width (centered on the beam line)?
--
-- Extracted from boss_attacks.lua dot-product logic (was inline, fragile).
-- `dir` must be normalized (e.g. from M.aim_vector).
function M.point_in_beam(origin, dir, length, width, point)
    local to = vmath.vector3((point.x or 0) - (origin.x or 0),
                             (point.y or 0) - (origin.y or 0), 0)
    local proj = vmath.dot(to, dir)
    if proj <= 0 or proj >= (tonumber(length) or 0) then
        return false
    end
    -- Perpendicular component magnitude.
    local perp = to - dir * proj
    local half_w = (tonumber(width) or 0) * 0.5
    return vmath.length(perp) <= half_w
end

-- Evenly distribute `count` points on a circle of `radius` around `center`.
-- Used by summon attacks to place minions.
function M.ring_positions(center, radius, count)
    count = math.max(1, math.floor(tonumber(count) or 1))
    radius = tonumber(radius) or 0
    local out = {}
    for i = 1, count do
        local angle = (math.pi * 2 / count) * i
        out[i] = vmath.vector3(
            (center.x or 0) + math.cos(angle) * radius,
            (center.y or 0) + math.sin(angle) * radius,
            center.z or 0
        )
    end
    return out
end

return M
