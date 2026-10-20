-- mvtk/editor/layout_editor/controller_state.lua
--
-- Selection and room-order state helpers for the layout editor controller.

local Selection = require "mvtk.editor.layout_editor.selection"

local M = {}

M.canon_id = Selection.canon_id
M.find_by_canon = Selection.find_by_canon
M.deselect_current = Selection.deselect_current
M.resolve = Selection.resolve
M.clear_all = Selection.clear_all
M.toggle = Selection.toggle
M.range_select = Selection.range_select
M.set = Selection.set

function M.promote_room_order(self, cid)
    if not self or not cid then return end
    local order = self.room_order
    local index = self.room_order_index
    if not order or not index then return end

    local idx = index[cid]
    if not idx or idx == #order then return end

    local room_id = order[idx]
    table.remove(order, idx)
    order[#order + 1] = room_id

    for i, rid in ipairs(order) do
        index[rid] = i
    end
end

function M.remove_room_from_order(self, cid)
    if not (self and cid and self.room_order_index and self.room_order) then
        return
    end

    local idx = self.room_order_index[cid]
    if not idx then
        return
    end

    table.remove(self.room_order, idx)
    self.room_order_index = {}
    for i, rid in ipairs(self.room_order) do
        self.room_order_index[rid] = i
    end
end

function M.clear_manual_door_insets(room)
    if not room or not room.doors_meta then return end
    for _, meta in ipairs(room.doors_meta) do
        if meta then
            meta.manual_inset_px = nil
        end
    end
end

function M.clear_all_manual_door_insets(self)
    if not self or not self.rooms then return end
    for _, room in pairs(self.rooms) do
        M.clear_manual_door_insets(room)
    end
end

function M.remove_deleted_room_from_selection(self, cid, target_id, logf)
    if cid and self.selected_room_id == cid then
        M.deselect_current(self)
    end

    if not (cid and self.selected_rooms) then
        return
    end

    if self.selected_rooms[cid] then
        self.selected_rooms[cid] = nil
        if logf then logf("Removed deleted room %s from multi-selection", cid) end
    end

    if target_id ~= cid and self.selected_rooms[target_id] then
        self.selected_rooms[target_id] = nil
        if logf then logf("Removed deleted room %s from multi-selection", target_id) end
    end

    if self.last_selected_room_id ~= cid and self.last_selected_room_id ~= target_id then
        return
    end

    if next(self.selected_rooms) then
        for _, ordered_id in ipairs(self.room_order or {}) do
            if self.selected_rooms[ordered_id] then
                self.last_selected_room_id = ordered_id
                self.selected_room_id = ordered_id
                self.selected_room = self.selected_rooms[ordered_id]
                if logf then logf("Updated primary selection to %s after deletion", ordered_id) end
                break
            end
        end
    else
        self.last_selected_room_id = nil
    end
end

return M
