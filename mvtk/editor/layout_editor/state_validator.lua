-- mvtk/editor/layout_editor/state_validator.lua
-- Runtime state validation to catch bugs early

local M = {}

local validation_enabled = true
local error_count = 0
local warning_count = 0

--- Enable/disable validation
function M.set_enabled(enabled)
    validation_enabled = enabled
end

--- Validate room state
-- @param room Room object to validate
-- @return true if valid, false + error message otherwise
function M.validate_room(room)
    if not validation_enabled then return true end

    if not room then
        return false, "Room is nil"
    end

    if not room.id then
        return false, "Room missing id"
    end

    if not room.base_pos then
        return false, string.format("Room %s missing base_pos", room.id)
    end

    local function is_vector3(v)
        if type(v) == "userdata" then return true end
        if type(v) == "table" and v.x ~= nil and v.y ~= nil and v.z ~= nil then return true end
        return false
    end

    if not is_vector3(room.base_pos) then
        return false, string.format("Room %s base_pos is not a vector3 (type: %s)", room.id, type(room.base_pos))
    end

    if room.group then
        local ok, exists = pcall(go.exists, room.group)
        if ok and not exists then
            return false, string.format("Room %s has invalid group reference", room.id)
        end
    end

    return true
end

--- Validate controller state
-- @param controller Layout editor controller
-- @return true if valid, false + errors otherwise
function M.validate_controller(controller)
    if not validation_enabled then return true end

    local errors = {}

    -- Check basic structure
    if not controller then
        table.insert(errors, "Controller is nil")
        return false, errors
    end

    if not controller.rooms then
        table.insert(errors, "Controller missing rooms table")
    end

    if not controller.room_order then
        table.insert(errors, "Controller missing room_order")
    end

    -- Validate selected room consistency
    if controller.selected_room_id then
        if not controller.rooms[controller.selected_room_id] then
            table.insert(errors, string.format("Selected room ID '%s' not in rooms table", controller.selected_room_id))
        end

        if controller.selected_room then
            if controller.selected_room.id ~= controller.selected_room_id then
                table.insert(errors, string.format("Selected room ID mismatch: %s vs %s",
                    controller.selected_room_id, controller.selected_room.id))
            end
        end
    end

    -- Validate multi-selection consistency
    if controller.selected_rooms then
        for room_id, room in pairs(controller.selected_rooms) do
            if not controller.rooms[room_id] then
                table.insert(errors, string.format("Multi-selected room '%s' not in rooms table", room_id))
            end

            if not room.selected then
                table.insert(errors, string.format("Room '%s' in selected_rooms but selected=false", room_id))
            end
        end
    end

    -- Validate room_order consistency
    if controller.rooms and controller.room_order then
        for _, room_id in ipairs(controller.room_order) do
            if not controller.rooms[room_id] then
                table.insert(errors, string.format("Room ID '%s' in room_order but not in rooms", room_id))
            end
        end
    end

    -- Validate each room
    if controller.rooms then
        for room_id, room in pairs(controller.rooms) do
            local valid, err = M.validate_room(room)
            if not valid then
                table.insert(errors, string.format("Room %s: %s", room_id, err))
            end
        end
    end

    if #errors > 0 then
        error_count = error_count + #errors
        return false, errors
    end

    return true
end

--- Assert room validity (throws error if invalid)
-- @param room Room to validate
-- @param context Optional context message
function M.assert_room(room, context)
    if not validation_enabled then return end

    local valid, err = M.validate_room(room)
    if not valid then
        local msg = string.format("[VALIDATION ERROR] %s: %s", context or "Room validation failed", err)
        error(msg)
    end
end

--- Assert controller validity (throws error if invalid)
-- @param controller Controller to validate
-- @param context Optional context message
function M.assert_controller(controller, context)
    if not validation_enabled then return end

    local valid, errors = M.validate_controller(controller)
    if not valid then
        local msg = string.format("[VALIDATION ERROR] %s:\n  - %s",
            context or "Controller validation failed",
            table.concat(errors, "\n  - "))
        error(msg)
    end
end

--- Validate and log warnings (non-fatal)
-- @param controller Controller to validate
-- @param context Optional context message
function M.check_controller(controller, context)
    if not validation_enabled then return true end

    local valid, errors = M.validate_controller(controller)
    if not valid then
        warning_count = warning_count + #errors
        print(string.format("[VALIDATION WARNING] %s:", context or "Controller check"))
        for _, err in ipairs(errors) do
            print(string.format("  - %s", err))
        end
        return false
    end

    return true
end

--- Get validation statistics
-- @return Table with error/warning counts
function M.get_stats()
    return {
        errors = error_count,
        warnings = warning_count,
        enabled = validation_enabled
    }
end

--- Reset statistics
function M.reset_stats()
    error_count = 0
    warning_count = 0
end

--- Validate door connections
-- @param controller Controller to validate
-- @return true if all doors properly connected
function M.validate_door_connections(controller)
    if not validation_enabled then return true end

    local errors = {}

    for room_id, room in pairs(controller.rooms or {}) do
        if room.doors then
            for _, door in ipairs(room.doors) do
                if door.connected_room then
                    -- Check if connected room exists
                    if not controller.rooms[door.connected_room] then
                        table.insert(errors, string.format(
                            "Room %s door connects to non-existent room %s",
                            room_id, door.connected_room))
                    end
                end
            end
        end
    end

    if #errors > 0 then
        return false, errors
    end

    return true
end

--- Assert no stale selections (throws error if found)
-- Called after room deletion to ensure no deleted rooms remain in selection state
-- @param controller Controller to validate
function M.assert_no_stale_selections(controller)
    if not validation_enabled then return end

    local errors = {}

    -- Check multi-selection for stale references
    if controller.selected_rooms then
        for room_id, room in pairs(controller.selected_rooms) do
            if not controller.rooms[room_id] then
                table.insert(errors, string.format(
                    "Stale selection: Room '%s' in selected_rooms but not in rooms table",
                    room_id))
            end
        end
    end

    -- Check primary selection
    if controller.selected_room_id and not controller.rooms[controller.selected_room_id] then
        table.insert(errors, string.format(
            "Stale selection: selected_room_id '%s' not in rooms table",
            controller.selected_room_id))
    end

    -- Check last selected
    if controller.last_selected_room_id and not controller.rooms[controller.last_selected_room_id] then
        table.insert(errors, string.format(
            "Stale selection: last_selected_room_id '%s' not in rooms table",
            controller.last_selected_room_id))
    end

    if #errors > 0 then
        error_count = error_count + #errors
        local msg = string.format("[VALIDATION ERROR] Stale selections detected:\n  - %s",
            table.concat(errors, "\n  - "))
        error(msg)
    end
end

return M
