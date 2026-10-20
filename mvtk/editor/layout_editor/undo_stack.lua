-- mvtk/editor/layout_editor/undo_stack.lua
-- Undo/Redo system for layout editor operations

local M = {}

local MAX_UNDO_STACK = 50  -- Limit memory usage

local undo_stack = {}
local redo_stack = {}
local current_group = nil  -- For grouping multiple operations

--- Initialize undo system
function M.init()
    undo_stack = {}
    redo_stack = {}
    current_group = nil
end

--- Record an operation that can be undone
-- @param operation Table with {undo = function(), redo = function(), description = string}
function M.record(operation)
    if not operation.undo or not operation.redo then
        print("[UNDO] Error: Operation must have undo() and redo() functions")
        return
    end

    -- Add to undo stack
    table.insert(undo_stack, operation)

    -- Limit stack size
    if #undo_stack > MAX_UNDO_STACK then
        table.remove(undo_stack, 1)
    end

    -- Clear redo stack when new operation is recorded
    redo_stack = {}

    print(string.format("[UNDO] Recorded: %s (stack: %d)", operation.description or "operation", #undo_stack))
end

--- Begin a group of operations (will be undone/redone together)
-- @param description Group description
function M.begin_group(description)
    current_group = {
        operations = {},
        description = description or "group"
    }
end

--- End current operation group
function M.end_group()
    if not current_group or #current_group.operations == 0 then
        current_group = nil
        return
    end

    -- Create compound operation
    local group = current_group
    local compound = {
        description = group.description,
        undo = function()
            -- Undo in reverse order
            for i = #group.operations, 1, -1 do
                group.operations[i].undo()
            end
        end,
        redo = function()
            -- Redo in forward order
            for i = 1, #group.operations do
                group.operations[i].redo()
            end
        end
    }

    M.record(compound)
    current_group = nil
end

--- Undo last operation
-- @return true if undid something
function M.undo()
    if #undo_stack == 0 then
        print("[UNDO] Nothing to undo")
        return false
    end

    local operation = table.remove(undo_stack)
    operation.undo()
    table.insert(redo_stack, operation)

    print(string.format("[UNDO] Undid: %s", operation.description or "operation"))
    return true
end

--- Redo last undone operation
-- @return true if redid something
function M.redo()
    if #redo_stack == 0 then
        print("[REDO] Nothing to redo")
        return false
    end

    local operation = table.remove(redo_stack)
    operation.redo()
    table.insert(undo_stack, operation)

    print(string.format("[REDO] Redid: %s", operation.description or "operation"))
    return true
end

--- Check if undo is available
-- @return true if can undo
function M.can_undo()
    return #undo_stack > 0
end

--- Check if redo is available
-- @return true if can redo
function M.can_redo()
    return #redo_stack > 0
end

--- Get undo stack size
-- @return Number of undoable operations
function M.get_undo_count()
    return #undo_stack
end

--- Get redo stack size
-- @return Number of redoable operations
function M.get_redo_count()
    return #redo_stack
end

--- Clear all undo/redo history
function M.clear()
    undo_stack = {}
    redo_stack = {}
    current_group = nil
    print("[UNDO] Cleared all history")
end

--- Get description of next undo operation
-- @return Description string or nil
function M.get_undo_description()
    if #undo_stack == 0 then return nil end
    return undo_stack[#undo_stack].description
end

--- Get description of next redo operation
-- @return Description string or nil
function M.get_redo_description()
    if #redo_stack == 0 then return nil end
    return redo_stack[#redo_stack].description
end

--- Helper: Create move room operation
-- @param room Room object
-- @param old_pos Old position
-- @param new_pos New position
-- @return Operation table
function M.create_move_operation(room, old_pos, new_pos)
    return {
        description = string.format("Move room %s", room.id),
        undo = function()
            room.base_pos = vmath.vector3(old_pos)
        end,
        redo = function()
            room.base_pos = vmath.vector3(new_pos)
        end
    }
end

--- Helper: Create add room operation
-- @param controller Layout controller
-- @param room_id Room ID
-- @return Operation table
function M.create_add_room_operation(controller, room_id)
    return {
        description = string.format("Add room %s", room_id),
        undo = function()
            -- Remove room
            local room = controller.rooms[room_id]
            if room and room.group then
                go.delete(room.group)
            end
            controller.rooms[room_id] = nil
            -- Remove from order
            for i, id in ipairs(controller.room_order) do
                if id == room_id then
                    table.remove(controller.room_order, i)
                    break
                end
            end
        end,
        redo = function()
            -- Re-add room (would need spawn logic)
            -- This is simplified - actual implementation needs spawn_room call
        end
    }
end

--- Helper: Create delete room operation
-- @param controller Layout controller
-- @param room_id Room ID
-- @param room_data Saved room data
-- @return Operation table
function M.create_delete_room_operation(controller, room_id, room_data)
    return {
        description = string.format("Delete room %s", room_id),
        undo = function()
            -- Restore room (simplified)
            controller.rooms[room_id] = room_data
            table.insert(controller.room_order, room_id)
        end,
        redo = function()
            -- Delete room
            local room = controller.rooms[room_id]
            if room and room.group then
                go.delete(room.group)
            end
            controller.rooms[room_id] = nil
            for i, id in ipairs(controller.room_order) do
                if id == room_id then
                    table.remove(controller.room_order, i)
                    break
                end
            end
        end
    }
end

return M
