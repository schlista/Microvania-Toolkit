--- Boss beam attack executor.
-- Telegraphs and fires a directional beam. Hit-tests the player at fire-time
-- and again half-way through the active duration so the damage window is
-- not a single instant.
-- @module boss_attacks.beam

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    C.print("[BOSS_ATTACKS] Firing beam")

    local pos = go.get_position()
    local beam = pattern.beam or {}
    local length = beam.length or C.Defaults.default_beam_length
    local width = beam.width or C.Defaults.default_beam_width
    local damage = (pattern.damage or C.Defaults.default_beam_damage) * C.damage_mult(boss)
    local duration = beam.duration or C.Defaults.default_beam_duration
    local windup = beam.windup or C.Defaults.default_beam_windup

    local beam_dir = vmath.vector3(boss.facing, 0, 0)
    if beam.target == "player" then
        local player_pos = C.Detection.get_player_position()
        if player_pos then
            beam_dir = C.Geometry.aim_vector(pos, player_pos)
        end
    end

    C.delay(windup, function()
        local hit_applied = false

        local function check_beam_hit()
            if hit_applied then return end
            local player_pos = C.Detection.get_player_position()
            if not player_pos then return end

            if C.Geometry.point_in_beam(pos, beam_dir, length, width, player_pos) then
                local kb = beam_dir * 100
                local payload = C.build_payload(boss, pattern, damage, kb.x, kb.y)
                C.post_damage(payload)
                C.print(string.format("[BOSS_ATTACKS] Beam hit player for %d damage", damage))
                hit_applied = true
            end
        end

        check_beam_hit()
        C.delay(duration / 2, check_beam_hit)

        local beam_ok, beam_url = C.factory_exists("#beam_effect_factory")
        if beam_ok then
            local beam_end = pos + beam_dir * length
            pcall(factory.create, beam_url, pos, nil, {
                end_pos = beam_end,
                width = width,
                duration = duration,
            })
        end
    end)
end

return M
