--- Boss heal attack executor.
-- Restores boss HP by posting `mvtk_apply_heal` to the boss. Supports a
-- one-shot heal or over-duration ticks via heal.ticks / heal.interval.
-- @module boss_attacks.heal

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local heal = pattern.heal or {}
    local amount = heal.amount
        or (boss.boss_data and boss.boss_data.heal_per_tick)
        or C.Defaults.default_heal_amount
    local ticks = heal.ticks or 1
    local interval = heal.interval or 0.3

    C.print(string.format("[BOSS_ATTACKS] Heal %d x %d (interval %.2f)",
        amount, ticks, interval))

    local boss_url = boss.self_url or msg.url()
    for i = 1, ticks do
        C.delay(interval * (i - 1), function()
            pcall(msg.post, boss_url, hash("mvtk_apply_heal"), {
                amount = amount,
                source = boss.boss_id,
            })
        end)
    end
end

return M
