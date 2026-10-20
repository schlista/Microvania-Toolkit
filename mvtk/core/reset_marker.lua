-- mvtk/core/reset_marker.lua
--
-- Project > Reset Project to Empty cannot call sys.get_save_file() from the
-- editor-script VM. It writes mvtk_reset_pending instead; the next game launch
-- consumes that marker before any save/layout modules are required.

local M = {}
local SavePaths = require "mvtk.core.save_paths"

M.MARKER_PATH = "./mvtk_reset_pending"
M.DEFAULT_MAX_SLOTS = 3

function M.saved_targets(max_slots)
    local player = SavePaths.app_id()
    local layout = SavePaths.app_id("layout")
    local targets = {
        { app = layout, file = "world_layout.json" },
        { app = layout, file = "rooms_auto" },
        { app = player, file = "mvtk_last_slot" },
        { app = player, file = "mvtk_last_slot.bak" },
        { app = player, file = "mvtk_last_slot_backup" },
        { app = player, file = "mvtk_settings" },
        { app = player, file = "mvtk_bindings_v2" },
        { app = SavePaths.app_id("wizard"), file = "wizard_settings" },
    }
    for slot = 1, tonumber(max_slots) or M.DEFAULT_MAX_SLOTS do
        local base = "mvtk_save_slot_" .. tostring(slot)
        targets[#targets + 1] = { app = player, file = base }
        targets[#targets + 1] = { app = player, file = base .. ".bak" }
        targets[#targets + 1] = { app = player, file = base .. "_backup" }
    end
    return targets
end

local function default_exists(path, sys_api, io_api)
    if sys_api and type(sys_api.exists) == "function" then
        local ok, value = pcall(sys_api.exists, path)
        if ok then return value and true or false end
    end
    if io_api and type(io_api.open) == "function" then
        local ok, handle = pcall(io_api.open, path, "rb")
        if ok and handle then
            if type(handle.close) == "function" then pcall(handle.close, handle) end
            return true
        end
    end
    return false
end

function M.consume(options)
    options = options or {}
    local sys_api = options.sys or sys
    local os_api = options.os or os
    local io_api = options.io or io
    local marker_path = options.marker_path or M.MARKER_PATH
    local exists = options.exists or function(path)
        return default_exists(path, sys_api, io_api)
    end
    local remove = options.remove or function(path)
        return os_api.remove(path)
    end
    local logger = options.logger or function(message) print(message) end

    if not exists(marker_path) then
        return false, { consumed = false, removed = {}, failed = {} }
    end

    local report = { consumed = false, removed = {}, failed = {} }
    local paths = {}
    if sys_api and type(sys_api.get_save_file) == "function" then
        for _, target in ipairs(M.saved_targets(options.max_slots)) do
            local ok, path = pcall(sys_api.get_save_file, target.app, target.file)
            if ok and type(path) == "string" and path ~= "" then
                paths[#paths + 1] = path
            else
                report.failed[#report.failed + 1] = target.app .. "/" .. target.file
            end
        end
    else
        report.failed[#report.failed + 1] = "sys.get_save_file is unavailable"
    end
    -- Legacy shared/relative saves are intentionally left untouched.

    local seen = {}
    for _, path in ipairs(paths) do
        if not seen[path] then
            seen[path] = true
            if exists(path) then
                local ok, removed, remove_error = pcall(remove, path)
                if ok and removed then
                    report.removed[#report.removed + 1] = path
                else
                    report.failed[#report.failed + 1] = path .. ": "
                        .. tostring(remove_error or removed or "remove failed")
                end
            end
        end
    end

    if #report.failed == 0 then
        local ok, removed, remove_error = pcall(remove, marker_path)
        if ok and removed then
            report.consumed = true
        else
            report.failed[#report.failed + 1] = marker_path .. ": "
                .. tostring(remove_error or removed or "remove failed")
        end
    end

    if report.consumed then
        logger("[RESET] Cleared saved game and Layout Editor state from the previous project reset.")
    else
        logger("[RESET] Could not clear all saved state; reset marker retained for the next launch.")
    end
    return report.consumed, report
end

return M
