--- Boss summon attack executor.
-- Spawns enemy minions evenly around the boss using the EnemyManager.
-- @module boss_attacks.summon

local C = require "mvtk.bosses.boss_attacks.common"

local M = {}

function M.execute(boss, pattern)
    local summon = pattern.summon or {}
    local count = summon.count or 2
    local enemy_type = summon.enemy_type or "slime"

    C.print(string.format("[BOSS_ATTACKS] Summoning %d %s", count, enemy_type))

    local pos = go.get_position()
    local spawn_radius = summon.spawn_radius or 100

    local EnemyManager = C.Util.require_module("mvtk.enemies.enemy_manager")
    if not (EnemyManager and EnemyManager.spawn_enemy) then
        C.print("[BOSS_ATTACKS] EnemyManager not available, cannot summon minions")
        return
    end

    local positions = C.Geometry.ring_positions(pos, spawn_radius, count)
    for _, spawn_pos in ipairs(positions) do
        local enemy_id = EnemyManager.spawn_enemy(enemy_type, spawn_pos)
        if enemy_id then
            C.print(string.format("[BOSS_ATTACKS] Spawned minion %s at (%.0f, %.0f)",
                enemy_type, spawn_pos.x, spawn_pos.y))
        end
    end
end

return M
