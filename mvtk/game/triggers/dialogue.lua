-- mvtk/game/triggers/dialogue.lua

local M = {}
local Ctx = nil

function M.configure(ctx)
    Ctx = ctx or Ctx
end

local function ctx()
    assert(Ctx, "mvtk.game.triggers.dialogue is not configured")
    return Ctx
end

function M.on_trigger(self, trigger)
    local C = ctx()
    local debug_id = C.trigger_debug_id(trigger)
    local requires_flag = C.normalize_hash_string(C.trigger_prop(trigger, "requires_flag"))
    if requires_flag and not C.Flags.has(requires_flag) then
        C.trigger_log(string.format("[TRIGGER] dialogue_blocked zone=%s reason=requires_flag_missing flag=%s",
            tostring(debug_id), tostring(requires_flag)))
        return false
    end

    local skip_if_flag = C.normalize_hash_string(C.trigger_prop(trigger, "skip_if_flag"))
    if skip_if_flag and C.Flags.has(skip_if_flag) then
        C.trigger_log(string.format("[TRIGGER] dialogue_skipped zone=%s reason=skip_if_flag_set flag=%s",
            tostring(debug_id), tostring(skip_if_flag)))
        return true
    end

    local dialogue_id = C.normalize_hash_string(C.trigger_prop(trigger, "dialogue_id"))
    if not dialogue_id then
        C.main_log(string.format("[MAIN] Dialogue trigger '%s' missing dialogue_id", tostring(C.resolve_trigger_key(trigger))))
        C.trigger_log(string.format("[TRIGGER] dialogue_blocked zone=%s reason=missing_dialogue_id", tostring(debug_id)))
        return false
    end

    local payload = {
        dialogue_id = dialogue_id,
        npc_id = C.normalize_hash_string(C.trigger_prop(trigger, "npc_id")),
        source_trigger_id = C.resolve_trigger_key(trigger),
    }
    C.trigger_log(string.format("[TRIGGER] dialogue_fire zone=%s dialogue_id=%s npc_id=%s",
        tostring(debug_id), tostring(dialogue_id), tostring(payload.npc_id)))

    local delay_s = tonumber(C.trigger_prop(trigger, "delay")) or 0
    if delay_s > 0 then
        C.trigger_log(string.format("[TRIGGER] dialogue_delayed zone=%s delay=%.3f", tostring(debug_id), delay_s))
        timer.delay(delay_s, false, function()
            pcall(msg.post, "main:/dialogue_manager#dialogue", hash("start_dialogue"), payload)
        end)
    else
        pcall(msg.post, "main:/dialogue_manager#dialogue", hash("start_dialogue"), payload)
    end

    local set_flag = C.normalize_hash_string(C.trigger_prop(trigger, "set_flag"))
    if set_flag then
        C.Flags.set(set_flag, true)
        C.trigger_log(string.format("[TRIGGER] dialogue_set_flag zone=%s flag=%s", tostring(debug_id), tostring(set_flag)))
    end
    C.post_trigger_toast(trigger, "Dialogue Trigger Fired")
    return true
end

function M.on_message(self, msg_id, msg, sender)
    return false
end

return M
