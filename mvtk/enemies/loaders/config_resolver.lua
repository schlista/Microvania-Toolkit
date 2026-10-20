-- mvtk/enemies/loaders/config_resolver.lua
-- Room enemy config loading and per-spawn config merging for EnemyManager.

local M = {}

local function log(logger, msg)
    if logger then
        logger(msg)
    end
end

local function copy_table(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        if type(v) == "table" then
            out[k] = copy_table(v)
        else
            out[k] = v
        end
    end
    return out
end

function M.load_room_configs(logger)
    local ok_configs, configs = pcall(require, "developer.config.room_enemies")
    if ok_configs and type(configs) == "table" then
        log(logger, string.format("Loaded enemy configurations for %d rooms", M.count_keys(configs)))
        return configs
    end

    log(logger, "No enemy configurations found (developer/config/room_enemies.lua)")
    return {}
end

function M.count_keys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

function M.merge_enemy_config(enemy_type, enemy_config)
    local merged = copy_table(enemy_type or {})
    local drops_disabled = type(enemy_config and enemy_config.drops) == "table"
        and next(enemy_config.drops) == nil

    for k, v in pairs(enemy_config or {}) do
        if k == "drops" and type(v) == "table" and next(v) == nil then
            -- An explicit empty drops table means "no drops". Deep-merging it
            -- would silently retain the enemy-type preset's drop entries.
            merged[k] = {}
        elseif type(v) == "table" and type(merged[k]) == "table" then
            for kk, vv in pairs(v) do
                if type(vv) == "table" then
                    merged[k][kk] = copy_table(vv)
                else
                    merged[k][kk] = vv
                end
            end
        elseif type(v) == "table" then
            merged[k] = copy_table(v)
        else
            merged[k] = v
        end
    end

    if drops_disabled then
        -- The normalized `drops = none` sentinel disables rewards outright,
        -- including a loot table inherited from the enemy type preset.
        merged.loot_table = nil
    end

    return merged
end

function M.get_room_config(enemy_configs, room_id)
    if not room_id then
        return nil
    end
    return enemy_configs and enemy_configs[room_id] or nil
end

function M.position_from_config(enemy_config)
    local pos = enemy_config and enemy_config.position
    if not pos then
        return nil
    end
    return vmath.vector3(pos.x, pos.y, pos.z or 0)
end

return M
