-- mvtk/game/loot_resolver.lua
-- Loot table parsing helpers extracted from main.script.

local M = {}

local trim_string = function(value)
    if value == nil then
        return nil
    end
    local s = tostring(value):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

local require_config = function(module_name)
    local ok, cfg = pcall(require, module_name)
    return ok and cfg or {}
end

function M.configure(opts)
    opts = opts or {}
    trim_string = opts.trim_string or trim_string
    require_config = opts.require_config or require_config
end

function M.parse_drop_amount(value)
    local raw = trim_string(value)
    if not raw then
        return nil, nil
    end
    local min_s, max_s = raw:match("^(%-?%d+)%s*%-%s*(%-?%d+)$")
    if min_s and max_s then
        local min_n = tonumber(min_s)
        local max_n = tonumber(max_s)
        if min_n and max_n then
            if max_n < min_n then
                max_n = min_n
            end
            return min_n, max_n
        end
    end
    local amount = tonumber(raw)
    if amount then
        return amount, amount
    end
    return nil, nil
end

function M.parse_drop_table(raw)
    local drops = {}
    local source = trim_string(raw)
    if not source then
        return nil
    end

    for entry in source:gmatch("[^,]+") do
        local token = trim_string(entry)
        if token then
            local drop_id, amount_str, chance_str = token:match("^([^:]+):([^:]+):([^:]+)$")
            if not drop_id then
                drop_id, amount_str = token:match("^([^:]+):([^:]+)$")
            end
            if not drop_id then
                drop_id = token
            end

            drop_id = trim_string(drop_id)
            if drop_id then
                local min_amount, max_amount = M.parse_drop_amount(amount_str)
                local chance = tonumber(chance_str) or 1.0
                local drop = {
                    chance = chance,
                    amount = min_amount or 1,
                }
                if min_amount then
                    drop.min = min_amount
                    drop.max = max_amount or min_amount
                end
                drops[drop_id] = drop
            end
        end
    end

    return next(drops) and drops or nil
end

local function drop_amounts(cfg)
    local amount = tonumber(cfg.amount) or tonumber(cfg.min) or 1
    local min_amount = tonumber(cfg.min) or amount
    local max_amount = tonumber(cfg.max) or min_amount
    return amount, min_amount, max_amount
end

function M.merge_drop_tables(base, extra)
    if type(extra) ~= "table" then
        return base
    end
    base = base or {}

    for drop_id, cfg in pairs(extra) do
        if type(cfg) == "table" and drop_id then
            local current = base[drop_id]
            local add_amount, add_min, add_max = drop_amounts(cfg)
            if current then
                -- Resolve all three original values before changing amount.
                -- Fixed rewards contribute to both endpoints of a range.
                local current_amount, current_min, current_max = drop_amounts(current)
                current.amount = current_amount + add_amount
                current.min = current_min + add_min
                current.max = current_max + add_max
                current.chance = math.max(tonumber(current.chance) or 1.0, tonumber(cfg.chance) or 1.0)
            else
                base[drop_id] = {
                    amount = add_amount,
                    min = tonumber(cfg.min),
                    max = tonumber(cfg.max),
                    chance = tonumber(cfg.chance) or 1.0,
                }
            end
        end
    end

    return base
end

function M.build_loot_table_drops(loot_table_id)
    loot_table_id = trim_string(loot_table_id)
    if not loot_table_id then
        return nil
    end

    local LootTables = require_config("developer.config.loot_tables")

    local table_def = LootTables[loot_table_id]
    local items = table_def and table_def.items
    if type(items) ~= "table" then
        return nil
    end

    local drops = {}
    for _, item in ipairs(items) do
        if type(item) == "table" and item.type then
            drops[item.type] = {
                amount = tonumber(item.amount) or 1,
                chance = tonumber(item.chance) or 1.0,
            }
        end
    end

    return next(drops) and drops or nil
end

return M
