--- Boss shield attack executor.
-- Adds a damage-absorb HP pool that must be depleted before further hits
-- reach the boss. boss.shield_hp / boss.shield_expires_at are read by the
-- boss damage handler. Automatically drops when depleted or on timeout.
-- @module boss_attacks.shield

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local shield = pattern.shield or {}
    local shield_hp = shield.hp or C.Defaults.default_shield_hp
    local duration = shield.duration or C.Defaults.default_shield_duration

    C.print(string.format("[BOSS_ATTACKS] Shield up: %d HP / %.1fs", shield_hp, duration))

    boss.shield_hp = shield_hp
    boss.shield_expires_at = socket and socket.gettime and (socket.gettime() + duration)
    C.play_resolved_animation(boss, "shield_up", true)

    C.delay(duration, function()
        if boss and (boss.shield_hp or 0) > 0 then
            boss.shield_hp = 0
            C.play_resolved_animation(boss, "shield_down", true)
            C.print("[BOSS_ATTACKS] Shield expired")
        end
    end)
end

return M
