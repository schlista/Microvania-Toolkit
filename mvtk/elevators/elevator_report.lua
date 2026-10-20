-- mvtk/elevators/elevator_report.lua
-- Readable elevator start-up failures and status lines.
--
-- ElevatorManager.initialize_from_generated returns either an error string, a
-- layout result with resolver diagnostics, or per-elevator registration errors
-- (for example "persistent cabin spawn failed: ..."). The stream manager used
-- to print only the top-level code, so a lift that failed to spawn left no
-- trace. These helpers turn every shape into lines naming the elevator and the
-- code. Pure Lua (no Defold globals) except show_dev_error, so it is unit-tested.
local M = {}

local MAX_TOAST_LINES = 3

local function position_text(position)
    if type(position) ~= "table" then return "?" end
    return string.format("(%.0f, %.0f)", tonumber(position.x) or 0, tonumber(position.y) or 0)
end

--- Lines describing a failed initialize_from_generated result.
function M.failure_lines(result)
    local lines = {}
    if type(result) ~= "table" then
        lines[1] = tostring(result or "unknown elevator error")
        return lines
    end
    for _, diagnostic in ipairs(result.diagnostics or {}) do
        if diagnostic.severity == "error" then
            lines[#lines + 1] = string.format("%s [%s] room=%s: %s",
                tostring(diagnostic.elevator_id or "-"),
                tostring(diagnostic.code or result.code or "elevator_layout_invalid"),
                tostring(diagnostic.room_id or diagnostic.from_room_id or "-"),
                tostring(diagnostic.message or ""))
        end
    end
    for _, entry in ipairs(result.errors or {}) do
        lines[#lines + 1] = string.format("%s: %s",
            tostring(entry.elevator_id or "-"), tostring(entry.error or "registration failed"))
    end
    if #lines == 0 then
        lines[1] = tostring(result.code or result.error or "invalid generated elevator layout")
    end
    return lines
end

--- One status line per elevator (for Debug.rooms.stream_manager logs).
-- `all` is ElevatorManager.get_all().
function M.status_lines(all)
    local ids = {}
    for id in pairs(all or {}) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    local lines = {}
    for _, id in ipairs(ids) do
        local view = all[id] or {}
        local snapshot = view.snapshot or {}
        lines[#lines + 1] = string.format("%s: stop=%s pos=%s bottom=%s top=%s cabin=%s%s",
            id, tostring(snapshot.current_stop or "-"), position_text(snapshot.position),
            position_text(view.bottom and view.bottom.position),
            position_text(view.top and view.top.position),
            view.cabin_url and "spawned" or (view.spawn_pending and "pending" or "missing"),
            view.definition_error and (" error=" .. tostring(view.definition_error)) or "")
    end
    return lines
end

--- Debug builds only: show the first failure lines on screen as a toast.
function M.show_dev_error(lines, prefix)
    if type(lines) ~= "table" or #lines == 0 then return false end
    local ok, PU = pcall(require, "mvtk.prefabs.prefab_utils")
    if not ok or not PU or not PU.is_dev_build or not PU.is_dev_build() then return false end
    local shown = {}
    for i = 1, math.min(#lines, MAX_TOAST_LINES) do shown[i] = lines[i] end
    if #lines > MAX_TOAST_LINES then
        shown[#shown + 1] = string.format("(+%d more in the console)", #lines - MAX_TOAST_LINES)
    end
    PU.toast((prefix or "Elevator error") .. ":\n" .. table.concat(shown, "\n"), 8.0)
    return true
end

return M
