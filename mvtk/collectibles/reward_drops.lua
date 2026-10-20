-- mvtk/collectibles/reward_drops.lua
-- Turns reward contents (chest loot) into real pickups.
--
-- CollectibleManager.spawn_collectible only records data; nothing ever
-- materialised chest loot, so opening a chest granted nothing and showed
-- nothing. Rewards are runtime drops (not Tiled objects), so they spawn from
-- the room manager's collectible factory, exactly like enemy drops.
local M = {}
local Settings = require "developer.config.reward_drop_settings"

M.FACTORY_URL = "main:/room_manager#collectible_factory"
M.SPACING = Settings.spacing

--- Expand { {type=, amount=}, ... } into individual drops with stable ids.
-- Currency types become ONE pickup worth amount x value (so "currency:25" is
-- 25 coins, not 25 objects); other types spawn `amount` separate pickups.
-- @param items             list of { type = string, amount = number }
-- @param collectible_types developer/config/collectible_types.lua table
-- @param id_prefix         stable prefix, e.g. "chest_pt4_7_chest_loot_"
function M.plan(items, collectible_types, id_prefix)
    local drops = {}
    local n = 0
    for _, item in ipairs(items or {}) do
        local kind = item and item.type
        if type(kind) == "string" and kind ~= "" then
            local def = type(collectible_types) == "table" and collectible_types[kind] or nil
            local count = math.max(1, math.floor(tonumber(item.amount) or 1))
            if type(def) == "table" and def.category == "currency" then
                n = n + 1
                drops[#drops + 1] = { type = kind, value = count * (tonumber(def.value) or 1), id = id_prefix .. n }
            else
                for _ = 1, count do
                    n = n + 1
                    drops[#drops + 1] = { type = kind, id = id_prefix .. n }
                end
            end
        end
    end
    return drops
end

--- Horizontal spread offset (px) for drop `index` of `total`.
function M.offset_x(index, total, spacing)
    return (index - ((total or 1) + 1) / 2) * (spacing or M.SPACING)
end

--- Spawn planned drops above `origin` (vector3). Already-collected ids are
-- skipped. Returns the number of pickups created.
function M.spawn(drops, origin, opts)
    opts = opts or {}
    local ok_mgr, CollectibleManager = pcall(require, "mvtk.collectibles.collectible_manager")
    local url = msg.url(opts.factory_url or M.FACTORY_URL)
    local created = 0
    for i, drop in ipairs(drops or {}) do
        local collected = ok_mgr and CollectibleManager and CollectibleManager.is_collected
            and CollectibleManager.is_collected(drop.id)
        if not collected then
            local pos = vmath.vector3(
                origin.x + M.offset_x(i, #drops, opts.spacing),
                origin.y + (opts.lift or Settings.lift),
                origin.z or 0)
            local props = {
                collectible_type = drop.type,
                collectible_id = drop.id,
            }
            if drop.value then props.amount = drop.value end
            local ok, err = pcall(factory.create, url, pos, nil, props, 1)
            if ok then
                created = created + 1
            else
                print(string.format("[REWARD_DROPS] Failed to spawn '%s': %s", tostring(drop.type), tostring(err)))
            end
        end
    end
    return created
end

return M
