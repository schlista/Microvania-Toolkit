--- Boss wave attack executor.
-- Expanding-ring AOE: fires `rings` successive AOE pulses at the boss
-- position with growing radius. The player takes damage once per ring they
-- are inside.
-- @module boss_attacks.wave

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local wave = pattern.wave or {}
    local rings = wave.rings or C.Defaults.default_wave_rings
    local ring_delay = wave.ring_delay or C.Defaults.default_wave_ring_delay
    local step = wave.radius_step or C.Defaults.default_wave_radius_step
    local thickness = wave.thickness or 40
    local damage = (wave.damage or pattern.damage or C.Defaults.default_wave_damage) * C.damage_mult(boss)
    local knockback = wave.knockback or C.Defaults.default_aoe_knockback

    local origin = go.get_position()

    C.print(string.format("[BOSS_ATTACKS] Wave: %d rings, step %.0f", rings, step))

    for i = 1, rings do
        C.delay(ring_delay * (i - 1), function()
            local outer = step * i
            local inner = math.max(0, outer - thickness)
            local effect_ok, effect_url = C.factory_exists("#aoe_effect_factory")
            if effect_ok then
                pcall(factory.create, effect_url, origin, nil, {
                    radius = outer,
                    thickness = thickness,
                })
            end
            local player_pos = C.Detection.get_player_position()
            if not player_pos then return end
            local dist = vmath.length(player_pos - origin)
            if dist >= inner and dist <= outer then
                local kb_dir = vmath.normalize(player_pos - origin)
                local kb = kb_dir * knockback
                local payload = C.build_payload(boss, pattern, damage, kb.x, kb.y)
                C.post_damage(payload)
                C.print(string.format("[BOSS_ATTACKS] Wave ring %d hit player for %d", i, damage))
            end
        end)
    end
end

return M
