-- mvtk/game/triggers/cutscene.lua

local M = {}
local Ctx = nil

function M.configure(ctx)
    Ctx = ctx or Ctx
end

local function ctx()
    assert(Ctx, "mvtk.game.triggers.cutscene is not configured")
    return Ctx
end

function M.on_trigger(self, trigger)
    local C = ctx()
    local debug_id = C.trigger_debug_id(trigger)
    local requires_flag = C.normalize_hash_string(C.trigger_prop(trigger, "requires_flag"))
    if requires_flag and not C.Flags.has(requires_flag) then
        C.trigger_log(string.format("[TRIGGER] cutscene_blocked zone=%s reason=requires_flag_missing flag=%s",
            tostring(debug_id), tostring(requires_flag)))
        return false
    end

    local skip_if_flag = C.normalize_hash_string(C.trigger_prop(trigger, "skip_if_flag"))
    if skip_if_flag and C.Flags.has(skip_if_flag) then
        C.trigger_log(string.format("[TRIGGER] cutscene_skipped zone=%s reason=skip_if_flag_set flag=%s",
            tostring(debug_id), tostring(skip_if_flag)))
        return true
    end

    local cutscene_raw = C.trigger_prop(trigger, "cutscene_id")
    local cutscene_id = C.resolve_cutscene_id(cutscene_raw)
    if not cutscene_id then
        C.main_log(string.format("[MAIN] Cutscene trigger '%s' missing cutscene_id", tostring(C.resolve_trigger_key(trigger))))
        C.trigger_log(string.format(
            "[TRIGGER] cutscene_blocked zone=%s reason=missing_cutscene_id raw=%s raw_type=%s known_cutscenes=%d",
            tostring(debug_id), tostring(cutscene_raw), tostring(type(cutscene_raw)), #C.cutscene_ids()))
        return false
    end

    C.trigger_log(string.format("[TRIGGER] cutscene_fire zone=%s cutscene_id=%s", tostring(debug_id), tostring(cutscene_id)))
    C.post_play_cutscene(cutscene_id)

    local set_flag = C.normalize_hash_string(C.trigger_prop(trigger, "set_flag"))
    if set_flag then
        C.Flags.set(set_flag, true)
        C.trigger_log(string.format("[TRIGGER] cutscene_set_flag zone=%s flag=%s", tostring(debug_id), tostring(set_flag)))
    end
    C.post_trigger_toast(trigger, "Cutscene Trigger Fired")
    return true
end

function M.on_message(self, msg_id, msg, sender)
    return false
end

return M
