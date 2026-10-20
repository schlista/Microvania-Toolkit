--- Boss melee attack executor.
-- Spawns a hitbox in front of the boss using `#melee_hitbox_factory` when
-- present, or falls back to an axis-aligned distance check.
-- @module boss_attacks.melee

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    C.print("[BOSS_ATTACKS] Executing melee attack")

    local pos = go.get_position()
    local damage = (pattern.damage or C.Defaults.default_melee_damage) * C.damage_mult(boss)
    local range  = pattern.range  or C.Defaults.melee_range or 80
    local width  = pattern.width  or C.Defaults.default_melee_width
    local height = pattern.height or C.Defaults.default_melee_height
    local knockback_x = pattern.knockback or C.Defaults.default_melee_knockback_x
    local knockback_y = pattern.knockback_y or C.Defaults.default_melee_knockback_y

    local have_factory, factory_url = C.factory_exists("#melee_hitbox_factory")
    if have_factory then
        local hitbox_pos = vmath.vector3(pos.x + range * 0.5 * boss.facing, pos.y, pos.z)
        local props = {
            boss_id = boss.boss_id or "",
            source_actor = boss.self_url,
            lifetime = pattern.duration or 0.14,
            damage = damage,
            knockback = knockback_x,
            dir = boss.facing,
            stun_t = pattern.stun_t or 0.10,
            parryable = pattern.parryable == true,
            reaction_type = pattern.reaction_type or "",
        }
        pcall(factory.create, factory_url, hitbox_pos, nil, props)
        return
    end

    local player_pos = C.Detection.get_player_position()
    if not player_pos then return end

    local hitbox_pos = vmath.vector3(pos.x + range * 0.5 * boss.facing, pos.y, pos.z)
    if C.Geometry.point_in_box(hitbox_pos, width, height, player_pos) then
        local kx = knockback_x * boss.facing
        local payload = C.build_payload(boss, pattern, damage, kx, knockback_y)
        C.post_damage(payload)
        C.print(string.format("[BOSS_ATTACKS] Melee hit player for %d damage", damage))
    end
end

return M
