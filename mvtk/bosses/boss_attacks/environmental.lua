--- Boss environmental attack executor.
-- Broadcasts an arena event so hazard spawners / interactive tiles can react
-- (e.g. collapse pillars, trigger falling rocks). Consumers subscribe via the
-- arena's event bus or by listening for mvtk_arena_event on their object.
-- @module boss_attacks.environmental

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local env = pattern.environmental or {}
    local event = env.event or "arena_hazard_pulse"
    local targets = env.spawner_ids or {}

    C.print(string.format("[BOSS_ATTACKS] Environmental: %s (%d targets)",
        event, #targets))

    local payload = {
        event = event,
        boss_id = boss.boss_id,
        arena_id = boss.arena_id,
        duration = env.duration or 2.0,
        intensity = env.intensity or 1.0,
    }

    local arena_url = boss.arena_url
    if arena_url then
        pcall(msg.post, arena_url, hash("mvtk_arena_event"), payload)
    end

    for _, spawner_id in ipairs(targets) do
        local ok, target_url = pcall(msg.url, spawner_id)
        if ok then
            pcall(msg.post, target_url, hash("mvtk_arena_event"), payload)
        end
    end
end

return M
