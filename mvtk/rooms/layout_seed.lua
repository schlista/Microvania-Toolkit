-- mvtk/developer/rooms/layout_seed.lua
-- Utility to append any rooms missing from the saved layout using the
-- factories list in developer/config/rooms_config.lua. Intended to be invoked manually
-- from a debug console or a one-off menu button in the layout editor.

local Util = require "mvtk.core.util"
local RoomsCF = Util.require_config("developer.config.rooms_config")
local LayoutIO = require("mvtk.rooms.layout_io")

local M = {}

local function list_factory_ids()
    local t = {}
    for k, _ in pairs((RoomsCF and RoomsCF.factories) or {}) do
        -- keys look like "developer/rooms/room_01" -> normalize to "room_01"
        local id = tostring(k):gsub("^developer/rooms/", "")
        t[#t+1] = id
    end
    table.sort(t)
    return t
end

return M



