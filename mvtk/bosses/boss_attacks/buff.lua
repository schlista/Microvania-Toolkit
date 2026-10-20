--- Boss buff attack executor.
-- Applies temporary multipliers to the boss's damage_multiplier and/or
-- speed_multiplier and a flat defense bonus for `duration` seconds, then
-- reverts. Each call captures the pre-buff values it will restore on expiry.
-- @module boss_attacks.buff

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local buff = pattern.buff or {}
    local duration = buff.duration or C.Defaults.default_buff_duration
    local data = boss.boss_data
    if not data then return end

    local damage_bonus = buff.damage_multiplier
    local speed_bonus = buff.speed_multiplier
    local defense_bonus = buff.defense_bonus

    local prev_damage = data.damage_multiplier
    local prev_speed = data.speed_multiplier
    local prev_defense = data.defense

    if damage_bonus then data.damage_multiplier = (prev_damage or 1.0) * damage_bonus end
    if speed_bonus then data.speed_multiplier = (prev_speed or 1.0) * speed_bonus end
    if defense_bonus then data.defense = (prev_defense or 0) + defense_bonus end

    C.print(string.format("[BOSS_ATTACKS] Buff applied for %.2fs (dmg x%s, spd x%s)",
        duration, tostring(damage_bonus), tostring(speed_bonus)))

    C.delay(duration, function()
        if not boss or not boss.boss_data then return end
        if damage_bonus then boss.boss_data.damage_multiplier = prev_damage end
        if speed_bonus then boss.boss_data.speed_multiplier = prev_speed end
        if defense_bonus then boss.boss_data.defense = prev_defense end
        C.print("[BOSS_ATTACKS] Buff expired")
    end)
end

return M
