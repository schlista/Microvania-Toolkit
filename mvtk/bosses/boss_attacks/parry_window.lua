--- Boss parry-window attack executor.
-- Opens a counter-attack window. If the boss is hit during the window the
-- boss.parry_active flag signals the damage handler to play the "counter"
-- animation and fire `pattern.parry_window.counter_pattern` at the attacker.
-- @module boss_attacks.parry_window

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local pw = pattern.parry_window or {}
    local window = pw.window or C.Defaults.default_parry_window

    C.print(string.format("[BOSS_ATTACKS] Parry window open %.2fs", window))

    boss.parry_active = true
    boss.parry_counter_pattern = pw.counter_pattern
    C.play_resolved_animation(boss, "parry", true)

    C.delay(window, function()
        if boss and boss.parry_active then
            boss.parry_active = false
            boss.parry_counter_pattern = nil
            C.print("[BOSS_ATTACKS] Parry window closed")
        end
    end)
end

return M
