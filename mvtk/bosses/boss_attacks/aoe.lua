--- Boss AOE attack executor.
-- Telegraphs an area of effect at the boss or at the player's position, then
-- damages the player after `aoe.delay` if they remain inside the radius.
-- @module boss_attacks.aoe

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

local function hits_aoe(center, radius, aoe, player_pos)
    if aoe.ground_only then
        local vertical_clearance = math.max(0,
            tonumber(aoe.vertical_clearance or aoe.jump_clearance) or 96)
        return math.abs(player_pos.x - center.x) <= radius
            and math.abs(player_pos.y - center.y) <= vertical_clearance
    end
    return C.Geometry.point_in_circle(center, radius, player_pos)
end

local function knockback_for(center, aoe, magnitude, player_pos)
    if aoe.ground_only then
        local direction = player_pos.x >= center.x and 1 or -1
        return direction * magnitude, tonumber(aoe.knockback_y) or magnitude * 0.5
    end

    local dx = player_pos.x - center.x
    local dy = player_pos.y - center.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0.0001 then
        return magnitude, 0
    end
    return (dx / length) * magnitude, (dy / length) * magnitude
end

function M.execute(boss, pattern)
    C.print("[BOSS_ATTACKS] AOE attack")

    local pos = go.get_position()
    local aoe = pattern.aoe or {}
    local radius = aoe.radius or C.Defaults.default_aoe_radius
    local damage = (pattern.damage or C.Defaults.default_aoe_damage) * C.damage_mult(boss)
    local knockback_mag = aoe.knockback or C.Defaults.default_aoe_knockback
    local delay = aoe.delay or C.Defaults.default_aoe_delay
    local center_pos = pos

    if aoe.target == "player" then
        local player_pos = C.Detection.get_player_position()
        if player_pos then center_pos = player_pos end
    end

    C.delay(delay, function()
        local player_pos = C.Detection.get_player_position()
        if player_pos and hits_aoe(center_pos, radius, aoe, player_pos) then
            local kx, ky = knockback_for(center_pos, aoe, knockback_mag, player_pos)
            local payload = C.build_payload(boss, pattern, damage, kx, ky)
            C.post_damage(payload)
            C.print(string.format("[BOSS_ATTACKS] AOE hit player for %d damage", damage))
        end

        local effect_ok, effect_url = C.factory_exists("#aoe_effect_factory")
        if effect_ok then
            local effect_pos = vmath.vector3(center_pos.x, center_pos.y, (center_pos.z or 0) + 0.1)
            pcall(factory.create, effect_url, effect_pos, nil, {
                radius = radius,
                duration = tonumber(aoe.effect_duration) or 0.45,
            })
        end
    end)
end

M._hits_aoe = hits_aoe

return M
