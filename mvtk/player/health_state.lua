-- Shared read-only view for stations; the player owns health mutations.
-- Unknown/uninitialized health must never suppress an authored station.
local M = {}
local current_health, max_health

function M.set(hp, maximum)
    current_health = tonumber(hp)
    max_health = tonumber(maximum)
end

function M.get()
    return current_health, max_health
end

function M.is_full()
    return current_health ~= nil and max_health ~= nil and max_health > 0
        and current_health >= max_health
end

return M
