--- Boss mine attack executor.
-- Drops a stationary trigger at the boss (or player) position that damages
-- the player on contact and disappears on trigger or after lifetime. Uses
-- the aoe_effect_factory as the visual and a polling tick for damage.
-- @module boss_attacks.mine

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local mine = pattern.mine or {}
    local radius = mine.radius or C.Defaults.default_mine_radius
    local damage = (mine.damage or pattern.damage or C.Defaults.default_mine_damage) * C.damage_mult(boss)
    local lifetime = mine.lifetime or C.Defaults.default_mine_lifetime
    local poll = mine.poll or 0.1
    local arm_delay = mine.arm_delay or 0.4

    local pos = go.get_position()
    local plant_pos
    if mine.position == "player" then
        plant_pos = C.Detection.get_player_position() or pos
    else
        plant_pos = vmath.vector3(pos.x, pos.y, pos.z)
    end

    C.print(string.format("[BOSS_ATTACKS] Mine planted (radius %.0f, lifetime %.1fs)",
        radius, lifetime))

    local effect_ok, effect_url = C.factory_exists("#aoe_effect_factory")
    if effect_ok then
        pcall(factory.create, effect_url, plant_pos, nil, {
            radius = radius,
            lifetime = lifetime,
        })
    end

    local expired = false
    local triggered = false

    C.delay(lifetime, function() expired = true end)

    local function tick()
        if expired or triggered then return end
        local player_pos = C.Detection.get_player_position()
        if player_pos and C.Geometry.point_in_circle(plant_pos, radius, player_pos) then
            triggered = true
            local kb = vmath.normalize(player_pos - plant_pos) *
                (mine.knockback or C.Defaults.default_aoe_knockback)
            local payload = C.build_payload(boss, pattern, damage, kb.x, kb.y)
            C.post_damage(payload)
            C.print(string.format("[BOSS_ATTACKS] Mine triggered for %d damage", damage))
            return
        end
        C.delay(poll, tick)
    end

    C.delay(arm_delay, tick)
end

return M
