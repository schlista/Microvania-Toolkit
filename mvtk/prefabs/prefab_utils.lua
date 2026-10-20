------------------------------------------------------------------------
-- mvtk/prefabs/prefab_utils.lua
-- Shared utility functions used across prefab scripts.
-- Centralised here to avoid duplication.
------------------------------------------------------------------------
local M = {}
local Util = require "mvtk.core.util"

------------------------------------------------------------------------
-- Hash / ID helpers
------------------------------------------------------------------------

--- Convert a hash or string value to a plain string, returning nil for
--- empty, unknown, or zero hashes.
function M.normalize_hash_string(value)
    return Util.normalize_hash_string(value)
end

--- Normalize an optional sound/particle/music-style ID. The Tiled enum uses
-- the literal "none" as its unset sentinel; consumers must not dispatch it.
function M.optional_id(value)
    if value == nil then return nil end
    if type(hash) == "function" and (value == hash("") or value == hash("none")) then
        return nil
    end
    local id = M.normalize_hash_string(value)
    if id and string.lower(id) == "none" then
        return nil
    end
    return id
end

function M.parse_id_list(value)
    return Util.parse_id_list(value)
end

function M.title_case_id(id)
    return Util.title_case_id(id)
end

function M.resolve_url(value)
    return Util.resolve_url(value)
end

function M.resolve_first_url(...)
    return Util.resolve_first_url(...)
end

--- Resolve a property value (hash or string) to a usable ID string.
--- Returns nil for empty / unset values.
function M.resolve_id(value)
    return Util.resolve_id(value)
end

------------------------------------------------------------------------
-- Audio helper
------------------------------------------------------------------------

--- Play a sound effect by id (string or hash). Safely requires the
--- audio module the first time it is called.
local _Audio = nil
local _audio_loaded = false

--- true when room_id is the room the player is in, or cannot be determined.
-- Streaming keeps neighbouring rooms loaded, so their timers (a timed door
-- closing, a crumble respawning) must not play sounds in the player's room.
function M.is_current_room(room_id)
    if room_id == nil or room_id == "" then return true end
    if type(hash) == "function" and room_id == hash("") then return true end
    local ok, RoomManager = pcall(require, "mvtk.map.streaming.room_manager")
    if not ok or type(RoomManager) ~= "table" or not RoomManager.get_current_room then return true end
    local current = RoomManager.get_current_room()
    if current == nil or current == "" then return true end
    local current_id = Util.normalize_room_id(current)
    if type(room_id) == "string" then
        return Util.normalize_room_id(room_id) == current_id
    end
    -- Baked room_id properties are hashes (not reversible in release builds).
    return type(hash) == "function" and hash(current_id) == room_id
end

--- opts.room_id: only play while the player is in that room (see above).
function M.play_sound(sound_id, opts)
    local id = M.optional_id(sound_id)
    if not id then return end
    if type(opts) == "table" and opts.room_id ~= nil and not M.is_current_room(opts.room_id) then
        return
    end
    if not _audio_loaded then
        local ok, mod = pcall(require, "mvtk.audio.audio")
        _Audio = ok and mod or false
        _audio_loaded = true
    end
    if _Audio and _Audio.sfx then
        pcall(_Audio.sfx, id)
    end
end

------------------------------------------------------------------------
-- Interaction manager (lazy-loaded)
------------------------------------------------------------------------
local _Interaction = nil

--- Return the interaction manager module, or false if unavailable.
function M.get_interaction()
    if _Interaction ~= nil then return _Interaction end
    local ok, mgr = pcall(require, "mvtk.game.interaction_manager")
    _Interaction = ok and mgr or false
    return _Interaction
end

function M.register_interaction(label, range, priority, url)
    local mgr = M.get_interaction()
    if not (mgr and mgr.register) then return false end
    mgr.register(url or msg.url(), {
        label = label,
        range = tonumber(range) or 96,
        priority = priority or 4,
        position_fn = function(position_url)
            return go.get_world_position(position_url)
        end,
    })
    return true
end

function M.update_interaction_label(label, url)
    return M.update_interaction({ label = label }, url)
end

function M.update_interaction(props, url)
    local mgr = M.get_interaction()
    if not (mgr and mgr.update) then return false end
    mgr.update(url or msg.url(), props or {})
    return true
end

function M.unregister_interaction(url)
    local mgr = M.get_interaction()
    if not (mgr and mgr.unregister) then return false end
    mgr.unregister(url or msg.url())
    return true
end

------------------------------------------------------------------------
-- URL helper
------------------------------------------------------------------------

function M.resolve_existing_component_url(candidates)
    for _, target in ipairs(candidates or {}) do
        local ok_url, url = pcall(msg.url, target)
        if ok_url and url then
            local go_url = msg.url(url.socket, url.path, nil)
            local ok_exists, exists = pcall(go.exists, go_url)
            if ok_exists and exists then
                return url
            end
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Cost helpers
------------------------------------------------------------------------

function M.positive_count(value, default)
    local count = tonumber(value) or default or 1
    if count <= 0 then count = default or 1 end
    return count
end

function M.can_pay_cost(source, inventory, opts)
    opts = opts or {}
    source = source or {}

    if not inventory then
        return false, opts.inventory_reason or "Inventory unavailable"
    end

    local cost = tonumber(source.cost_currency) or 0
    if cost > 0 and (inventory.get_currency() or 0) < cost then
        if opts.currency_reason then
            return false, opts.currency_reason
        end
        return false, string.format(opts.currency_format or "Need $%d", cost)
    end

    local item_id = M.normalize_hash_string(source.cost_item)
    if item_id and item_id ~= "" then
        local count = M.positive_count(source.cost_item_count, 1)
        if not inventory.has(item_id, count) then
            if opts.item_reason then
                return false, opts.item_reason
            end
            return false, string.format(opts.item_format or "Need %dx %s", count, Util.title_case_id(item_id))
        end
    end

    return true
end

function M.pay_cost(source, inventory)
    source = source or {}
    if not inventory then return false end

    local cost = tonumber(source.cost_currency) or 0
    if cost > 0 then
        inventory.set_currency((inventory.get_currency() or 0) - cost)
    end

    local item_id = M.normalize_hash_string(source.cost_item)
    if item_id and item_id ~= "" then
        inventory.remove_item(item_id, M.positive_count(source.cost_item_count, 1))
    end
    return true
end

------------------------------------------------------------------------
-- Toast helper
------------------------------------------------------------------------

--- true in debug (development) builds; creator-facing hints use this so
-- shipped release builds never show them.
function M.is_dev_build()
    if type(sys) ~= "table" or type(sys.get_engine_info) ~= "function" then return false end
    local ok, info = pcall(sys.get_engine_info)
    return ok and type(info) == "table" and info.is_debug == true
end

--- Show a brief toast/notification message to the player.
function M.toast(text, duration)
    if not text or text == "" then return end
    pcall(msg.post, msg.url("main:/toast_gui#toast"), hash("toast"), {
        text = text,
        duration = duration or 2.0,
    })
end

------------------------------------------------------------------------
-- Player URL helper
------------------------------------------------------------------------
local C_ok, C = pcall(require, "mvtk.core.constants")
if not C_ok then C = {} end

--- Return the player script URL.
function M.get_player_url()
    return C.URL and C.URL.PLAYER or nil
end

return M
