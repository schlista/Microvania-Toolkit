-- All player teleports pass through this gate in the player's script context.
-- Room preparation continues on the streamer's update; a cancelled request
-- releases its pin and can never deliver an old position later.
local C = require "mvtk.core.constants"
local M = {}

-- The player's message handler, registered by player.script while its chunk is
-- still running. It cannot be passed in from the player's update(): the engine
-- nils every lifecycle global once it has extracted the callbacks, so a global
-- `on_message` read at runtime is always nil.
local registered_dispatch = nil

--- Register the handler that replays a queued arrival message.
function M.set_dispatch(fn)
    registered_dispatch = (type(fn) == "function") and fn or nil
    return registered_dispatch ~= nil
end

function M.get_dispatch()
    return registered_dispatch
end

local function notify(message, success)
    if message.restart_request then
        pcall(msg.post, "main:/main_go#script", hash("mvtk_arrival_finished"), {
            request = message.restart_request, success = success,
        })
    end
end

local function finish_fade(message)
    if message.arrival_fade and C.URL and C.URL.FADE_GUI then
        pcall(msg.post, C.URL.FADE_GUI, C.MSG.FADE_FROM_BLACK, { duration = 0.3 })
    end
end

local function report(message, reason)
    notify(message, false)
    print("[ROOM_ARRIVAL] " .. tostring(reason))
    pcall(msg.post, "main:/toast_gui#toast", hash("toast"), {
        text = "Room could not be loaded. Please try again.", duration = 4,
    })
    finish_fade(message)
end

function M.cancel(self, manager)
    local pending = self._room_arrival
    if pending then
        manager.finish_arrival(pending.token, false)
        notify(pending.message, false)
        finish_fade(pending.message)
        self._room_arrival = nil
    end
end

function M.intercept(self, manager, id, message, sender)
    if self._applying_room_arrival or not manager or not manager.begin_arrival then return false end
    local position
    if id == hash("mvtk_set_position") then position = message.position or message.pos
    elseif id == hash("mvtk_restore_health") then position = message.respawn_pos end
    if not position then return false end
    M.cancel(self, manager)
    local token, err = manager.begin_arrival(go.get_id(), message.room_id, position)
    if not token then report(message, err); return true end
    local copy = {}
    for key, value in pairs(message) do copy[key] = value end
    self._room_arrival = { token = token, id = id, message = copy, sender = sender }
    return true
end

-- Returns true while the player must stay still. Deliver synchronously so
-- input, camera and health cannot get a frame ahead of the actual arrival.
function M.update(self, manager, deliver)
    if not manager or not manager.begin_arrival then return false end
    deliver = deliver or registered_dispatch
    local pending = self._room_arrival
    if pending then
        local ready, err = manager.arrival_status(pending.token)
        if err then
            manager.finish_arrival(pending.token, false)
            self._room_arrival = nil
            report(pending.message, err)
        elseif ready then
            manager.finish_arrival(pending.token, true)
            self._room_arrival = nil
            self._applying_room_arrival = true
            if deliver then
                deliver(self, pending.id, pending.message, pending.sender)
            else
                -- Never leave the player pinned because the handler is missing:
                -- finish the arrival, and say so instead of failing silently.
                print("[ROOM_ARRIVAL] no message handler registered; arrival position not applied")
            end
            self._applying_room_arrival = nil
            self._room_start_ready = true
            local position = pending.message.position or pending.message.pos or pending.message.respawn_pos
            if pending.message.update_camera ~= false and C.URL and C.URL.CAMERA then
                pcall(msg.post, C.URL.CAMERA, C.MSG.REQUEST_RESPAWN, { position = position })
            end
            finish_fade(pending.message)
            notify(pending.message, true)
        end
        return true
    end
    if not self._room_start_ready then
        local room = manager.get_room_for_position(self.pos)
        if room and manager.is_room_enterable(room) then
            self._room_start_ready = true
        else
            local err = room and manager.get_room_error(room)
            if err and self._room_start_error ~= err then
                self._room_start_error = err
                report({}, err)
            end
            return true
        end
    end
    return false
end

return M
