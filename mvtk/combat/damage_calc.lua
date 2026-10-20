-- mvtk/combat/damage_calc.lua
-- Apply the global difficulty scalar to numeric damage.

local DifficultyOk, Difficulty = pcall(require, "mvtk.core.difficulty")

local M = {}

-- The second argument is retained for callers that pass a hit classification.
-- opts.target = "player"|"enemy"|nil
function M.apply(amount, dtype, opts)
    local a = tonumber(amount) or 0
    local diff_mult = 1.0
    if DifficultyOk then
        if opts and opts.target == "player" then
            diff_mult = Difficulty.damage_taken_mult()
        else
            diff_mult = Difficulty.damage_dealt_mult()
        end
    end
    return a * diff_mult
end

return M
