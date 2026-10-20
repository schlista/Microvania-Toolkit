-- mvtk/enemies/loaders/spawn_coordinator.lua
-- Enemy spawn bookkeeping: IDs, room caps, stat scaling, active registry.

local M = {}

function M.new_state()
    return {
        active_enemies = {},
        active_room_counts = {},
        next_enemy_id = 1,
    }
end

function M.reset(state)
    state.active_enemies = state.active_enemies or {}
    state.active_room_counts = state.active_room_counts or {}
    for k in pairs(state.active_enemies) do state.active_enemies[k] = nil end
    for k in pairs(state.active_room_counts) do state.active_room_counts[k] = nil end
    state.next_enemy_id = 1
end

function M.resolve_limit(config, default_limit)
    local limit = tonumber(default_limit) or 0
    if config and config.max_enemies_per_room ~= nil then
        limit = tonumber(config.max_enemies_per_room) or limit
    end
    return limit
end

function M.can_spawn(state, room_id, limit)
    if not room_id or not limit or limit <= 0 then
        return true
    end
    return (state.active_room_counts[room_id] or 0) < limit
end

function M.next_enemy_id(state)
    local enemy_id = string.format("enemy_%d", state.next_enemy_id or 1)
    state.next_enemy_id = (state.next_enemy_id or 1) + 1
    return enemy_id
end

local function scale_positive_int(value, multiplier, fallback)
    value = tonumber(value) or fallback or 1
    multiplier = tonumber(multiplier) or 1.0
    return math.max(1, math.floor(value * multiplier + 0.5))
end

function M.apply_spawn_multipliers(config)
    config = config or {}
    local scaled = {
        health = scale_positive_int(config.health, config.health_multiplier, 1),
        damage = scale_positive_int(config.damage, config.damage_multiplier, 1),
        contact_damage = scale_positive_int(
            config.contact_damage or config.damage,
            config.contact_damage_multiplier,
            config.damage or 1
        ),
    }

    -- Preserve the historical contract: config.health remains the authored
    -- base value, while damage/contact_damage are materialized onto
    -- the config consumed by enemy scripts.
    config.damage = scaled.damage
    config.contact_damage = scaled.contact_damage
    return scaled
end

function M.build_enemy(enemy_id, enemy_type_id, position, config, spawned_at, scaled_stats)
    local health = scaled_stats and scaled_stats.health or tonumber(config.health) or 1
    return {
        id = enemy_id,
        type_id = enemy_type_id,
        config = config,
        url = nil,

        health = health,
        max_health = health,
        state = "idle",
        alive = true,

        invincible = false,
        invincible_timer = 0,

        position = vmath.vector3(position),
        velocity = vmath.vector3(0, 0, 0),
        facing = 1,

        behavior_data = {},
        target_player = nil,
        aggro_timer = 0,

        room_id = config.room_id,
        spawned_at = spawned_at,
    }
end

function M.track(state, enemy)
    if not enemy or not enemy.id then
        return false
    end

    state.active_enemies[enemy.id] = enemy
    if enemy.room_id then
        state.active_room_counts[enemy.room_id] = (state.active_room_counts[enemy.room_id] or 0) + 1
    end
    return true
end

function M.untrack(state, enemy_id)
    local enemy = state.active_enemies[enemy_id]
    if not enemy then
        return nil
    end

    if enemy.room_id then
        local current = state.active_room_counts[enemy.room_id]
        if current then
            current = current - 1
            if current <= 0 then
                state.active_room_counts[enemy.room_id] = nil
            else
                state.active_room_counts[enemy.room_id] = current
            end
        end
    end

    state.active_enemies[enemy_id] = nil
    return enemy
end

return M
