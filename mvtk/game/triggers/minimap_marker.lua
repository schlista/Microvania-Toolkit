-- mvtk/game/triggers/minimap_marker.lua

local M = {}
local Ctx = nil

function M.configure(ctx)
    Ctx = ctx or Ctx
end

local function ctx()
    assert(Ctx, "mvtk.game.triggers.minimap_marker is not configured")
    return Ctx
end

function M.register_marker_in_minimap_module(entry)
    local mini = rawget(_G, "MINIMAP_MODULE")
    if type(mini) ~= "table" or type(mini.register_marker) ~= "function" then
        return false, "minimap_module_unavailable"
    end

    local ok, marker, err = pcall(mini.register_marker, entry)
    if not ok then
        return false, marker
    end
    if not marker then
        return false, err or "register_marker_failed"
    end
    return true
end

function M.queue_pending_map_marker(self, entry)
    if not self or not entry then
        return
    end
    self.pending_map_markers = self.pending_map_markers or {}
    self.pending_map_markers[#self.pending_map_markers + 1] = entry
end

function M.flush_pending_map_markers(self)
    if not self or type(self.pending_map_markers) ~= "table" or #self.pending_map_markers == 0 then
        return
    end

    local C = ctx()
    local next_pending = {}
    for i = 1, #self.pending_map_markers do
        local entry = self.pending_map_markers[i]
        local ok, err = M.register_marker_in_minimap_module(entry)
        if ok then
            C.main_log(string.format("[MAIN] Flushed pending map marker '%s' to MINIMAP_MODULE", tostring(entry and entry.id)))
        else
            next_pending[#next_pending + 1] = entry
            C.main_log(string.format("[MAIN] Pending map marker '%s' still waiting: %s",
                tostring(entry and entry.id), tostring(err)))
        end
    end
    self.pending_map_markers = next_pending
end

function M.on_trigger(self, trigger_data)
    return false
end

function M.on_message(self, msg_id, msg, sender)
    if msg_id ~= hash("register_map_marker") then
        return false
    end

    local C = ctx()
    local ok, err = M.register_marker_in_minimap_module(msg)
    if not ok then
        M.queue_pending_map_marker(self, msg)
        C.main_log(string.format("[MAIN] Queued map marker '%s' (reason=%s)",
            tostring(msg and msg.id), tostring(err)))
    end

    C.main_log(string.format("[MAIN] Registered map marker '%s'", tostring(msg and msg.id)))
    return true
end

return M
