--- Boss hazard attack executor.
-- Maps authored hazard presets onto the AOE/beam executors so they remain
-- playable even without a dedicated arena hazard prefab.
-- @module boss_attacks.hazard

local C = require "mvtk.bosses.boss_attacks.common"
local Beam = require "mvtk.bosses.boss_attacks.beam"
local AOE  = require "mvtk.bosses.boss_attacks.aoe"

local M = {}

function M.execute(boss, pattern)
    local hazard = pattern.hazard or {}
    local hazard_type = tostring(hazard.type or "")
    C.print(string.format("[BOSS_ATTACKS] Hazard attack: %s",
        hazard_type ~= "" and hazard_type or "generic"))

    if hazard_type == "fire_wave" then
        return Beam.execute(boss, {
            damage = hazard.damage or pattern.damage or C.Defaults.default_beam_damage,
            beam = {
                length = hazard.width or pattern.range or C.Defaults.default_beam_length,
                width = hazard.height or C.Defaults.default_beam_width,
                duration = pattern.duration or 1.0,
                windup = 0,
            },
        })
    end

    local target = hazard.position == "boss" and nil or "player"
    local radius = hazard.radius
        or (hazard.width and hazard.width * 0.25)
        or (hazard.count and math.max(48, hazard.count * 18))
        or C.Defaults.default_aoe_radius
    local delay = hazard.telegraph_duration or hazard.delay or 0
    local knockback = hazard.knockback or pattern.knockback or C.Defaults.default_aoe_knockback
    local damage = hazard.damage_per_second or hazard.damage or pattern.damage or C.Defaults.default_aoe_damage

    return AOE.execute(boss, {
        damage = damage,
        aoe = {
            target = target,
            radius = radius,
            delay = delay,
            knockback = knockback,
        },
    })
end

return M
