-- mvtk/editor/layout_editor/selection.lua
--
-- Room selection state for the layout editor: single, multi (Ctrl+click),
-- and range (Shift+click). Operates on the controller `self` so callers
-- read/write the same fields the rest of the editor expects:
--   self.rooms                  - id -> room table
--   self.room_order             - ordered array of room ids (for range select)
--   self.selected_room_id       - canonical id of primary selection, or nil
--   self.selected_room          - primary selected room table, or nil
--   self.selected_rooms         - cid -> room table for multi-selection
--   self.last_selected_room_id  - anchor for Shift+click range
--
-- Public API:
--   M.canon_id(id)                       -> normalized canonical room id
--   M.find_by_canon(self, cid)           -> room, raw_id (or nil)
--   M.resolve(self, room_or_id)          -> cid, room (or nils)
--   M.deselect_current(self)             -> clear primary selection
--   M.clear_all(self)                    -> clear primary + multi
--   M.toggle(self, room_or_id)           -> Ctrl+click: add/remove from multi
--   M.range_select(self, room_or_id)     -> Shift+click: select range
--   M.set(self, room_or_id, opts)        -> primary selection (opts.ctrl/shift
--                                           dispatch to toggle/range_select)
--
-- Note: the legacy `align_view` opt on the previous `set_selected_room` was
-- never used by any caller and has been removed. Callers that want to align
-- the camera should do so explicitly after calling Selection.set.

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local LayoutIO = require "mvtk.rooms.layout_io"
local Render = require "mvtk.editor.layout_editor.render"

local Logger = require "mvtk.core.logger"
local log = Logger.get_logger("layout_editor.selection")
local function logf(fmt, ...) log.debug(fmt, ...) end

local M = {}

--- Canonical room id used for runtime (e.g. "/room_4" -> "room_04")
function M.canon_id(id)
    return LayoutIO.normalize_id(id, S.rooms_zero_pad or 2)
end

function M.find_by_canon(self, cid)
    for id, R in pairs(self.rooms or {}) do
        if M.canon_id(id) == cid then return R, id end
    end
    return nil, nil
end

function M.deselect_current(self)
    if not self or not self.selected_room_id then
        return
    end
    local cid = self.selected_room_id
    local room = select(1, M.find_by_canon(self, cid))
    if not room and self.rooms then
        room = self.rooms[cid]
    end
    if room then
        room.selected = false
        Render.update_room_outline_color(room)
    end
    self.selected_room_id = nil
    self.selected_room = nil
end

function M.resolve(self, room_or_id)
    if type(room_or_id) == "table" then
        local cid = M.canon_id(room_or_id.id)
        if not cid then return nil, nil end
        local resolved = select(1, M.find_by_canon(self, cid))
        if not resolved and self.rooms then
            resolved = self.rooms[cid]
                or self.rooms[room_or_id.id]
        end
        return cid, resolved or room_or_id
    else
        local cid = M.canon_id(room_or_id)
        if not cid then return nil, nil end
        local resolved = select(1, M.find_by_canon(self, cid))
        if not resolved and self.rooms then
            resolved = self.rooms[cid] or self.rooms[room_or_id]
        end
        return cid, resolved
    end
end

function M.clear_all(self)
    -- Clear multi-selection
    for _, room in pairs(self.selected_rooms) do
        if room then
            room.selected = false
            Render.update_room_outline_color(room)
        end
    end
    self.selected_rooms = {}

    -- Clear single selection
    if self.selected_room_id then
        M.deselect_current(self)
    end
    self.last_selected_room_id = nil
end

-- Toggle room in multi-selection (Ctrl+click behavior)
function M.toggle(self, room_or_id)
    local cid, room = M.resolve(self, room_or_id)
    if not cid or not room then return end

    -- Promote single selection into multi-set on first toggle.
    if not next(self.selected_rooms) then
        if self.selected_room_id and self.selected_room then
            self.selected_rooms[self.selected_room_id] = self.selected_room
        end
    end

    if self.selected_rooms[cid] then
        -- Deselect this room
        room.selected = false
        self.selected_rooms[cid] = nil
        Render.update_room_outline_color(room)
        logf("Deselected room from multi-selection: %s", cid)

        -- Find new primary selection using deterministic ordering (room_order)
        if next(self.selected_rooms) then
            local new_cid = nil
            local new_room = nil

            for _, ordered_id in ipairs(self.room_order) do
                if self.selected_rooms[ordered_id] then
                    new_cid = ordered_id
                    new_room = self.selected_rooms[ordered_id]
                    break
                end
            end

            if new_cid then
                self.last_selected_room_id = new_cid
                self.selected_room_id = new_cid
                self.selected_room = new_room
                logf("New primary selection: %s (deterministic)", new_cid)
            else
                self.last_selected_room_id = nil
                self.selected_room_id = nil
                self.selected_room = nil
            end
        else
            self.last_selected_room_id = nil
            self.selected_room_id = nil
            self.selected_room = nil
        end
    else
        -- Add to selection
        room.selected = true
        self.selected_rooms[cid] = room
        self.last_selected_room_id = cid
        Render.update_room_outline_color(room)
        logf("Added room to multi-selection: %s", cid)
    end

    -- Sync primary selection to last touched room.
    if self.last_selected_room_id then
        self.selected_room_id = self.last_selected_room_id
        self.selected_room = self.selected_rooms[self.last_selected_room_id]
    else
        self.selected_room_id = nil
        self.selected_room = nil
    end
end

-- Range selection (Shift+click behavior)
function M.range_select(self, room_or_id)
    if not self.last_selected_room_id then
        -- No previous selection, just toggle this one
        M.toggle(self, room_or_id)
        return
    end

    local cid, room = M.resolve(self, room_or_id)
    if not cid or not room then return end

    -- Find range between last_selected and current in room_order
    local start_idx, end_idx
    for i, ordered_id in ipairs(self.room_order) do
        if ordered_id == self.last_selected_room_id then
            start_idx = i
        end
        if ordered_id == cid then
            end_idx = i
        end
    end

    if not start_idx or not end_idx then return end

    if start_idx > end_idx then
        start_idx, end_idx = end_idx, start_idx
    end

    -- Select all rooms in range
    for i = start_idx, end_idx do
        local range_id = self.room_order[i]
        local range_room = self.rooms[range_id]
        if range_room then
            range_room.selected = true
            self.selected_rooms[range_id] = range_room
            Render.update_room_outline_color(range_room)
        end
    end

    self.last_selected_room_id = cid
    self.selected_room_id = cid
    self.selected_room = room

    logf("Range selected %d rooms", end_idx - start_idx + 1)
end

function M.set(self, room_or_id, opts)
    logf("=== SET_SELECTED_ROOM START ===")
    logf("room_or_id type: %s, value: %s", type(room_or_id), tostring(room_or_id))
    if type(room_or_id) == "table" and room_or_id.id then
        logf("room_or_id.id: %s", room_or_id.id)
    end

    if not self then
        logf("ERROR: self is nil")
        return
    end
    opts = opts or {}

    logf("opts.ctrl = %s, opts.shift = %s", tostring(opts.ctrl), tostring(opts.shift))

    -- Modifier dispatch
    if opts.ctrl then
        logf("CTRL detected - calling toggle")
        M.toggle(self, room_or_id)
        return
    end

    if opts.shift then
        logf("SHIFT detected - calling range_select")
        M.range_select(self, room_or_id)
        return
    end

    logf("No modifiers - doing normal single selection")
    -- Normal single selection - clear multi-selection first
    M.clear_all(self)

    local cid, room = M.resolve(self, room_or_id)
    logf("resolve returned cid: %s, room: %s", tostring(cid), tostring(room))
    if room and room.id then
        logf("room.id: %s", room.id)
    end

    if not room and self.rooms then
        logf("Room not found by resolve, trying self.rooms[%s]", tostring(cid))
        room = self.rooms[cid]
    end

    if not cid or not room then
        logf("ERROR: Cannot select room - cid=%s, room=%s", tostring(cid), tostring(room))
        return
    end

    self.selected_room_id = cid
    self.selected_room = room
    self.last_selected_room_id = cid
    room.selected = true
    Render.update_room_outline_color(room)
    logf("Set self.selected_room_id = %s", tostring(self.selected_room_id))

    logf("=== SET_SELECTED_ROOM END ===")
end

return M
