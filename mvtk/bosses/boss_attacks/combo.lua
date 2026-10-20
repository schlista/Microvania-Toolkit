--- Boss combo attack executor.
-- Schedules sub-patterns by delay and re-enters the dispatcher via
-- C.execute_pattern so each combo step uses the same code path as the
-- standalone version of that attack.
-- @module boss_attacks.combo

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local steps = pattern.combo or {}
    C.print(string.format("[BOSS_ATTACKS] Combo attack with %d steps", #steps))

    for _, step in ipairs(steps) do
        local delay = tonumber(step.delay) or 0
        C.delay(delay, function()
            local step_pattern = nil
            if type(step.pattern) == "string" and boss.get_attack_pattern then
                step_pattern = boss:get_attack_pattern(step.pattern)
            elseif type(step) == "table" and step.type then
                step_pattern = step
            end

            if not step_pattern then
                C.print(string.format("[BOSS_ATTACKS] Combo step missing pattern: %s",
                    tostring(step.pattern)))
                return
            end

            local merged = C.merge_step_pattern(step_pattern, step)
            C.execute_pattern(boss, merged, { play_animation = true })
        end)
    end
end

return M
