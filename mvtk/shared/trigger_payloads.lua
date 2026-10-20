local Util = require "mvtk.core.util"

local M = {}

local DEFAULT_SIZE = 64

local function as_id(value)
    local normalized = Util.normalize_hash_string(value)
    if normalized then
        return normalized
    end
    if value == nil then
        return nil
    end
    local raw = Util.trim(value)
    if raw == "" then
        return nil
    end
    return raw
end

local function as_string(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function as_number(value, default)
    local n = tonumber(value)
    if n == nil then
        return default
    end
    return n
end

local function as_dimension(value, default)
    local n = tonumber(value) or default
    if n <= 0 then
        return default
    end
    return n
end

local function copy_properties(source)
    if type(source) ~= "table" then
        return {}
    end
    return Util.shallow_copy(source)
end

local function stamp(properties, values)
    for key, value in pairs(values or {}) do
        if value ~= nil then
            properties[key] = value
        end
    end
end

local function build_common(opts)
    opts = opts or {}

    local props = copy_properties(opts.properties)
    local payload = {
        id = opts.id,
        trigger_id = as_id(opts.trigger_id) or as_id(opts.id) or "",
        once_flag = as_id(opts.once_flag) or "",
        position = opts.position,
        width = as_dimension(opts.width, opts.default_width or DEFAULT_SIZE),
        height = as_dimension(opts.height, opts.default_height or DEFAULT_SIZE),
        room_id = as_id(opts.room_id) or "",
        trigger_once = Util.to_bool(opts.trigger_once, opts.default_trigger_once == true),
        consume_on_fire = Util.to_bool(opts.consume_on_fire, opts.default_consume_on_fire == true),
        -- URL of the baked trigger script that registered this zone (optional).
        -- mark_zone_fired notifies it instead of posting to the registration id.
        owner = opts.owner,
        properties = props,
    }

    if opts.persist_once ~= nil or opts.default_persist_once ~= nil then
        payload.persist_once = Util.to_bool(opts.persist_once, opts.default_persist_once == true)
    end

    stamp(props, {
        trigger_id = payload.trigger_id,
        trigger_once = payload.trigger_once,
        consume_on_fire = payload.consume_on_fire,
        persist_once = payload.persist_once,
        once_flag = payload.once_flag,
    })

    return payload, props
end

function M.cutscene(opts)
    local payload, props = build_common(Util.merge({
        default_trigger_once = true,
        default_consume_on_fire = true,
        default_persist_once = true,
    }, opts))

    payload.cutscene_id = as_id(opts.cutscene_id) or ""
    payload.cutscene_name = as_string(opts.cutscene_name)
    payload.auto_play = Util.to_bool(opts.auto_play, true)
    payload.requires_flag = as_id(opts.requires_flag) or ""
    payload.skip_if_flag = as_id(opts.skip_if_flag) or ""
    payload.set_flag = as_id(opts.set_flag) or ""
    payload.video_id = as_id(opts.video_id) or ""
    payload.video_uri = as_string(opts.video_uri)
    payload.video_play_sound = Util.to_bool(opts.video_play_sound, false)
    payload.video_timeout = as_number(opts.video_timeout, 12)
    payload.cutscene_dialogue_id = as_id(opts.cutscene_dialogue_id) or ""
    payload.cutscene_use_fade = Util.to_bool(opts.cutscene_use_fade, true)
    payload.cutscene_wait = as_number(opts.cutscene_wait, 0.2)

    stamp(props, {
        cutscene_id = payload.cutscene_id,
        cutscene_name = payload.cutscene_name,
        auto_play = payload.auto_play,
        requires_flag = payload.requires_flag,
        skip_if_flag = payload.skip_if_flag,
        set_flag = payload.set_flag,
        video_id = payload.video_id,
        video_uri = payload.video_uri,
        video_play_sound = payload.video_play_sound,
        video_timeout = payload.video_timeout,
        cutscene_dialogue_id = payload.cutscene_dialogue_id,
        cutscene_use_fade = payload.cutscene_use_fade,
        cutscene_wait = payload.cutscene_wait,
    })

    return payload
end

function M.dialogue(opts)
    local payload, props = build_common(Util.merge({
        default_trigger_once = true,
        default_consume_on_fire = true,
    }, opts))

    payload.dialogue_id = as_id(opts.dialogue_id) or ""
    payload.auto_play = Util.to_bool(opts.auto_play, true)
    payload.delay = as_number(opts.delay, 0)
    payload.requires_flag = as_id(opts.requires_flag) or ""
    payload.skip_if_flag = as_id(opts.skip_if_flag) or ""
    payload.set_flag = as_id(opts.set_flag) or ""
    payload.npc_id = as_id(opts.npc_id) or ""

    stamp(props, {
        dialogue_id = payload.dialogue_id,
        auto_play = payload.auto_play,
        delay = payload.delay,
        requires_flag = payload.requires_flag,
        skip_if_flag = payload.skip_if_flag,
        set_flag = payload.set_flag,
        npc_id = payload.npc_id,
    })

    return payload
end

return M
