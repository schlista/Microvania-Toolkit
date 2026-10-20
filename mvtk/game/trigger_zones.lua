-- mvtk/game/trigger_zones.lua
-- Trigger-zone geometry, once/consume state, and service dispatch helpers.

local M = {}

local PLAYER_TRIGGER_HALF_WIDTH = 0
local PLAYER_TRIGGER_HALF_HEIGHT = 0
local normalize_hash_string = function(value) return value end
local coerce_bool = function(value, default) return value == nil and default or value end
local trigger_log = function() end
local Flags = {
    has = function() return false end,
    set = function() end,
}
local TriggerServices = {}

function M.configure(opts)
    opts = opts or {}
    PLAYER_TRIGGER_HALF_WIDTH = opts.PLAYER_TRIGGER_HALF_WIDTH or PLAYER_TRIGGER_HALF_WIDTH
    PLAYER_TRIGGER_HALF_HEIGHT = opts.PLAYER_TRIGGER_HALF_HEIGHT or PLAYER_TRIGGER_HALF_HEIGHT
    normalize_hash_string = opts.normalize_hash_string or normalize_hash_string
    coerce_bool = opts.coerce_bool or coerce_bool
    trigger_log = opts.trigger_log or trigger_log
    Flags = opts.Flags or Flags
    TriggerServices = opts.TriggerServices or TriggerServices
end

function M.point_in_bounds(point, zone, half_w, half_h)
    if not point or not zone then
        return false
    end
    local pos = zone.position or vmath.vector3(0, 0, 0)
    local width = tonumber(zone.width) or 0
    local height = tonumber(zone.height) or 0
    if width <= 0 then width = 64 end
    if height <= 0 then height = 64 end

    local zone_min_x = pos.x
    local zone_max_x = pos.x + width
    local zone_min_y = pos.y
    local zone_max_y = pos.y + height

    local hw = tonumber(half_w) or 0
    local hh = tonumber(half_h) or 0
    if hw > 0 or hh > 0 then
        local p_min_x = point.x - hw
        local p_max_x = point.x + hw
        local p_min_y = point.y - hh
        local p_max_y = point.y + hh
        return p_max_x >= zone_min_x and
               p_min_x <= zone_max_x and
               p_max_y >= zone_min_y and
               p_min_y <= zone_max_y
    end

    return point.x >= zone_min_x and
           point.x <= zone_max_x and
           point.y >= zone_min_y and
           point.y <= zone_max_y
end

function M.player_overlaps_zone(player_pos, zone)
    return M.point_in_bounds(player_pos, zone, PLAYER_TRIGGER_HALF_WIDTH, PLAYER_TRIGGER_HALF_HEIGHT)
end

function M.trigger_prop(zone, key)
    if not zone or not key then
        return nil
    end
    local direct = zone[key]
    if direct ~= nil then
        return direct
    end
    local props = zone.properties
    if type(props) == "table" then
        return props[key]
    end
    return nil
end

function M.trigger_once_zone(zone)
    return coerce_bool(M.trigger_prop(zone, "trigger_once"), false)
end

local function sanitize_flag_fragment(value)
    local s = tostring(value or ""):lower()
    s = s:gsub("[^%w_]+", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    if s == "" then
        s = "unknown"
    end
    return s
end

function M.resolve_trigger_key(zone)
    local explicit = normalize_hash_string(M.trigger_prop(zone, "trigger_id"))
    if explicit then
        return explicit
    end
    local raw_id = zone and zone.id
    if raw_id ~= nil then
        return tostring(raw_id)
    end
    return nil
end

function M.resolve_once_flag(zone)
    local explicit = normalize_hash_string(M.trigger_prop(zone, "once_flag"))
    if explicit then
        return explicit
    end

    local persist_once = M.trigger_prop(zone, "persist_once")
    if persist_once ~= nil and not coerce_bool(persist_once, true) then
        return nil
    end
    if not M.trigger_once_zone(zone) then
        return nil
    end

    local room_key = sanitize_flag_fragment(normalize_hash_string(zone and zone.room_id) or "global")
    local kind_key = sanitize_flag_fragment(normalize_hash_string(zone and zone.kind) or "trigger")
    local trigger_key = sanitize_flag_fragment(M.resolve_trigger_key(zone) or "anon")
    return string.format("mvtk_trigger_once_%s_%s_%s", room_key, kind_key, trigger_key)
end

function M.trigger_debug_id(zone)
    local kind = normalize_hash_string(zone and zone.kind) or "trigger"
    local key = M.resolve_trigger_key(zone) or tostring(zone and zone.id or "unknown")
    return string.format("%s:%s", kind, tostring(key))
end

function M.post_trigger_toast(trigger, fallback)
    local show = M.trigger_prop(trigger, "debug_toast")
    if not coerce_bool(show, false) then
        return
    end

    local text = M.trigger_prop(trigger, "toast_text")
    if text == nil or tostring(text) == "" then
        text = fallback or ("Triggered: " .. tostring(M.resolve_trigger_key(trigger) or "unknown"))
    end
    local duration = tonumber(M.trigger_prop(trigger, "toast_duration")) or 1.6

    pcall(msg.post, msg.url("main:/toast_gui#toast"), hash("toast"), {
        text = tostring(text),
        duration = duration,
    })
end

function M.can_fire_zone(zone)
    if not zone then
        trigger_log("[TRIGGER] can_fire_zone=false reason=nil_zone")
        return false
    end
    if zone.disabled then
        trigger_log(string.format("[TRIGGER] can_fire_zone=false zone=%s reason=disabled", M.trigger_debug_id(zone)))
        return false
    end
    if M.trigger_once_zone(zone) then
        if zone.triggered then
            trigger_log(string.format("[TRIGGER] can_fire_zone=false zone=%s reason=already_triggered", M.trigger_debug_id(zone)))
            return false
        end
        local once_flag = M.resolve_once_flag(zone)
        if once_flag and Flags.has(once_flag) then
            zone.triggered = true
            trigger_log(string.format("[TRIGGER] can_fire_zone=false zone=%s reason=once_flag_set once_flag=%s",
                M.trigger_debug_id(zone), tostring(once_flag)))
            return false
        end
    end
    return true
end

function M.zone_should_consume_on_fire(zone)
    return coerce_bool(M.trigger_prop(zone, "consume_on_fire"), false)
end

function M.mark_zone_fired(self, zone)
    if not zone then
        return
    end

    if M.trigger_once_zone(zone) then
        zone.triggered = true
        local once_flag = M.resolve_once_flag(zone)
        if once_flag then
            Flags.set(once_flag, true)
        end
        trigger_log(string.format("[TRIGGER] mark_zone_fired zone=%s once_flag=%s",
            M.trigger_debug_id(zone), tostring(once_flag or "")))
    end

    if M.zone_should_consume_on_fire(zone) then
        zone.disabled = true
        zone.player_inside = false
        local zone_id = zone.id
        -- Baked zones register a stable id that is NOT a game-object path;
        -- posting "disable" to it (from main_go) logged "Instance '<unknown>'
        -- could not be found". Tell the owning script instead, and only delete
        -- runtime-spawned zone objects that really exist.
        if zone.owner then
            pcall(msg.post, zone.owner, hash("mvtk_zone_consumed"), { id = zone_id })
        end
        if type(zone_id) == "string" and zone_id:sub(1, 1) == "/" and not zone_id:find("#", 1, true) then
            local ok_exists, exists = pcall(go.exists, zone_id)
            if ok_exists and exists then
                pcall(go.delete, zone_id)
                trigger_log(string.format("[TRIGGER] zone_delete_post zone=%s id=%s",
                    M.trigger_debug_id(zone), tostring(zone_id)))
            end
        end
        trigger_log(string.format("[TRIGGER] zone_consumed zone=%s consume_on_fire=%s",
            M.trigger_debug_id(zone), tostring(M.trigger_prop(zone, "consume_on_fire"))))
    end
end

function M.process_cutscene_trigger(trigger)
    return TriggerServices.cutscene.on_trigger(nil, trigger)
end

function M.process_dialogue_trigger(trigger)
    return TriggerServices.dialogue.on_trigger(nil, trigger)
end

return M
