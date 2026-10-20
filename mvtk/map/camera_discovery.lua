-- Discover the gameplay camera's final frame view. Intermediate camera-message
-- publications never grant discovery. The streaming host owns this subscription
-- and supplies its ready/enabled room policy.
local CameraState = require "mvtk.camera.camera_state"
local Discovery = require "mvtk.map.discovery"
local M = {}
local rooms

local function room_visible(id)
    return rooms and rooms.is_room_enterable(id) == true
end

local function reveal_view(_, _, _, view)
    if view then Discovery.reveal_view(view, room_visible) end
end

function M.start(room_manager)
    assert(type(room_manager) == "table" and type(room_manager.is_room_enterable) == "function",
        "Camera discovery requires the streaming room visibility policy")
    rooms = room_manager
    return CameraState.on_commit("map_discovery", reveal_view)
end

function M.stop()
    rooms = nil
    return CameraState.off_commit("map_discovery")
end

return M
