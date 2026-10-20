-- mvtk/core/inventory.lua
-- moved from modules/core/inventory.lua

local Util = require "mvtk.core.util"
local C = require "mvtk.core.constants"
local KeyIds = require "mvtk.core.key_ids"

local M = {}

local items = {}
local currency = 0

local function canonical_id(id)
    -- Authored key aliases still resolve to their canonical text item IDs.
    -- An opaque hash cannot supply a saved identity for a custom item.
    return KeyIds.canonicalize(id) or ""
end

local function post_hud_currency()
    Util.safe_post(msg.url("main:/mode_hud#mode_hud"), C.MSG.HUD_CURRENCY, { value = currency })
end

function M.add_currency(amount)
    currency = math.max(0, currency + (amount or 0))
    post_hud_currency()
end

function M.get_currency()
    return currency
end

function M.set_currency(v)
    currency = math.max(0, v or 0)
    post_hud_currency()
end

function M.add_item(id, count)
    if not id then return end
    local key = canonical_id(id)
    if key == "" then return end
    count = count or 1
    items[key] = (items[key] or 0) + count
end

function M.remove_item(id, count)
    if not id then return end
    local key = canonical_id(id)
    if key == "" then return end
    count = count or 1
    local c = (items[key] or 0) - count
    if c <= 0 then
        items[key] = nil
    else
        items[key] = c
    end
end

function M.consume(id, count)
    if not id then return false end
    local key = canonical_id(id)
    if key == "" then return false end
    count = tonumber(count) or 1
    if count <= 0 then
        return false
    end
    if (items[key] or 0) < count then
        return false
    end
    M.remove_item(key, count)
    return true
end

function M.count(id)
    local key = canonical_id(id)
    if key == "" then return 0 end
    return items[key] or 0
end

function M.has(id, count)
    local key = canonical_id(id)
    if key == "" then return false end
    return (items[key] or 0) >= (count or 1)
end

function M.has_item(id, count)
    -- Alias for external systems expecting has_item()
    return M.has(id, count)
end

function M.all()
    return Util.shallow_copy(items)
end

function M.reset()
    items = {}
    currency = 0
    post_hud_currency()
end

function M.export()
    return {
        items = Util.shallow_copy(items),
        currency = currency,
    }
end

function M.import(data)
    M.reset()
    if type(data) ~= "table" then
        return
    end
    if type(data.items) == "table" then
        for k, v in pairs(data.items) do
            local key = canonical_id(k)
            local count = tonumber(v) or 0
            if key ~= "" and count > 0 then
                -- Old saves may contain both a short authored ID and a legacy
                -- alias. Merge them instead of dropping either stack.
                items[key] = (items[key] or 0) + count
            end
        end
    end
    if data.currency ~= nil then
        currency = math.max(0, tonumber(data.currency) or 0)
    end
    post_hud_currency()
end

Util.register_checkpoint_provider("inventory", {
    capture = function()
        return M.export()
    end,
    apply = function(data)
        M.import(data)
    end,
    defaults = function()
        M.reset()
    end,
    version = 1,
    order = 40,
    mirror_key = "inventory",
    description = "Inventory & currency",
})

return M
