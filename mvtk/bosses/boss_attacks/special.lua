--- Boss "special" attack executor.
-- Routes legacy aliases (charge / hazard / combo) and the per-pattern
-- callback escape hatch. Unknown special.types fall back to an AOE at the
-- player position so misconfigured presets still register.
-- @module boss_attacks.special

local C = require "mvtk.bosses.boss_attacks.common"
local Charge = require "mvtk.bosses.boss_attacks.charge"
local Hazard = require "mvtk.bosses.boss_attacks.hazard"
local Combo  = require "mvtk.bosses.boss_attacks.combo"
local AOE    = require "mvtk.bosses.boss_attacks.aoe"

local M = {}

function M.execute(boss, pattern)
    if pattern.type == "charge" then
        return Charge.execute(boss, pattern)
    end
    if pattern.type == "hazard" then
        return Hazard.execute(boss, pattern)
    end
    if pattern.type == "combo" then
        return Combo.execute(boss, pattern)
    end

    local special = pattern.special or {}
    if type(special.callback) == "function" then
        pcall(special.callback, boss, pattern)
        return
    end

    local special_type = special.type or "unknown"
    C.print(string.format("[BOSS_ATTACKS] Special attack: %s", special_type))

    local player_pos = C.Detection.get_player_position()
    if player_pos then
        AOE.execute(boss, {
            damage = pattern.damage or C.Defaults.default_aoe_damage,
            aoe = {
                target = "player",
                radius = special.radius or 100,
                delay = special.delay or 0.8,
            },
        })
    end
end

return M
