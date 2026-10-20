--- Time Utility Module
-- Provides cross-platform time functions with fallbacks
-- Handles optional LuaSocket dependency gracefully
--
-- @module time

local M = {}

-- Try to load socket for high-precision timing
local socket_available, socket = pcall(require, "socket")

--- Get current time in seconds with high precision
-- Falls back to os.clock if LuaSocket is not available
-- @return Time in seconds (float)
function M.gettime()
    if socket_available and socket and socket.gettime then
        return socket.gettime()
    else
        -- Fallback to os.clock (less accurate but always available)
        return os.clock()
    end
end

--- Get time since a previous timestamp
-- @param start_time Previous time from gettime()
-- @return Elapsed time in seconds
function M.elapsed(start_time)
    return M.gettime() - start_time
end

--- Check if high-precision timing is available
-- @return true if LuaSocket is available
function M.has_high_precision()
    return socket_available and socket and socket.gettime ~= nil
end

--- Get the current time implementation being used
-- @return String: "socket.gettime" or "os.clock"
function M.get_implementation()
    if socket_available and socket and socket.gettime then
        return "socket.gettime"
    else
        return "os.clock"
    end
end

return M
