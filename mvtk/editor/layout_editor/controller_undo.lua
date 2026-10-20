-- mvtk/editor/layout_editor/controller_undo.lua
--
-- Controller-level undo/redo commands for layout editor room operations.

local UndoStack = require "mvtk.editor.layout_editor.undo_stack"

local Logger = require "mvtk.core.logger"
local log = Logger.get_logger("layout_editor.controller_undo")

local M = {}

local ID_KEY_Z = hash("key_z")
local ID_KEY_Y = hash("key_y")

function M.init()
    UndoStack.init()
end

function M.handle_shortcut(action_id, action, ctrl_down, on_changed)
    if not (action and action.pressed and ctrl_down) then
        return false
    end

    if action_id == ID_KEY_Z then
        if UndoStack.undo() then
            log.info("Undo successful")
            if on_changed then on_changed() end
        else
            log.warn("Nothing to undo")
        end
        return true
    end

    if action_id == ID_KEY_Y then
        if UndoStack.redo() then
            log.info("Redo successful")
            if on_changed then on_changed() end
        else
            log.warn("Nothing to redo")
        end
        return true
    end

    return false
end

function M.record_spawn(self, room_id, delete_room, spawn_room)
    local room_id_copy = room_id
    UndoStack.record({
        description = "Add room: " .. room_id_copy,
        undo = function()
            log.info("Undo: Deleting room %s", room_id_copy)
            delete_room(self, room_id_copy, { skip_undo = true })
        end,
        redo = function()
            log.info("Redo: Adding room %s", room_id_copy)
            spawn_room(self, room_id_copy, { skip_undo = true })
        end,
    })
end

function M.record_delete(self, room_id, saved_pos, saved_tags, spawn_room, delete_room, apply_camera)
    local room_id_copy = room_id
    UndoStack.record({
        description = "Delete room: " .. room_id_copy,
        undo = function()
            log.info("Undo: Restoring room %s", room_id_copy)
            local restored = spawn_room(self, room_id_copy, {
                skip_undo = true,
                skip_spawn_cursor = true,
                tags_override = saved_tags,
            })
            if restored then
                restored.base_pos = saved_pos
                apply_camera(self)
            end
        end,
        redo = function()
            log.info("Redo: Deleting room %s", room_id_copy)
            delete_room(self, room_id_copy, { skip_undo = true })
        end,
    })
end

function M.record_move(self, room_id, old_pos, final_pos, apply_camera)
    if not (room_id and old_pos and final_pos) then
        return
    end

    local moved_distance = vmath.length(final_pos - old_pos)
    if moved_distance <= 1 then
        return
    end

    UndoStack.record({
        description = string.format("Move room: %s", room_id),
        undo = function()
            log.info("Undo: Moving room %s back to (%.1f, %.1f)", room_id, old_pos.x, old_pos.y)
            local room = self.rooms[room_id]
            if room then
                room.base_pos = vmath.vector3(old_pos)
                apply_camera(self)
            end
        end,
        redo = function()
            log.info("Redo: Moving room %s to (%.1f, %.1f)", room_id, final_pos.x, final_pos.y)
            local room = self.rooms[room_id]
            if room then
                room.base_pos = vmath.vector3(final_pos)
                apply_camera(self)
            end
        end,
    })
end

return M
