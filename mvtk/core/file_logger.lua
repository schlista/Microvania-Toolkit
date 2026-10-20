-- mvtk/core/file_logger.lua
-- Simple file logger for debugging

local M = {}

-- Try to write to user's Documents folder or temp directory
local log_path = require("mvtk.core.save_paths").path("game_debug.txt")
local log_file = nil
local buffer = {}
local buffer_max = 20  -- Write to file every 20 messages

function M.init()
    -- Open log file in write mode (overwrite each session for fresh logs)
    log_file = io.open(log_path, "w")
    if log_file then
        log_file:write("=== Game Session Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
        log_file:write("Log file location: " .. log_path .. "\n")
        log_file:write("===============================================\n\n")
        log_file:flush()
        print("[FILE_LOGGER] Log file created at: " .. log_path)
    else
        print("[FILE_LOGGER] Failed to create log file at: " .. log_path)
    end
end

function M.log(message)
    if not log_file then M.init() end

    local timestamp = os.date("%H:%M:%S")
    local full_msg = string.format("[%s] %s\n", timestamp, tostring(message))

    -- Also print to console
    print(full_msg)

    -- Write to file
    if log_file then
        log_file:write(full_msg)

        -- Periodically flush to ensure data is written
        table.insert(buffer, full_msg)
        if #buffer >= buffer_max then
            log_file:flush()
            buffer = {}
        end
    end
end

function M.close()
    if log_file then
        log_file:flush()
        log_file:close()
        log_file = nil
    end
end

return M
