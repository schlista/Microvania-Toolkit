local Viewport = require "mvtk.ui.viewport"
-- mvtk/editor/layout_editor/controller_input.lua
--
-- Mouse, keyboard, sidebar, pan, and drag handling for the layout editor.

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")

local UI = require "mvtk.editor.layout_editor.ui"
local Render = require "mvtk.editor.layout_editor.render"
local SpawnCursor = require "mvtk.editor.layout_editor.spawn_cursor"
local ControllerUndo = require "mvtk.editor.layout_editor.controller_undo"

local M = {}

local ID_TOUCH   = hash("touch")
local ID_MB1     = hash("mouse_button_1")
local ID_MB2     = hash("mouse_button_2")
local ID_MB3     = hash("mouse_button_3")
local ID_LCTRL   = hash("key_lctrl")
local ID_RCTRL   = hash("key_rctrl")
local ID_LSHIFT  = hash("key_lshift")
local ID_RSHIFT  = hash("key_rshift")
local ID_WHL_UP  = hash("mouse_wheel_up")
local ID_WHL_DN  = hash("mouse_wheel_down")
local ID_SPACE   = hash("key_space")
local ID_KEY_M   = hash("key_m")

local MSG_RESCAN = hash("rescan")

local function is_lmb(id)
    return id == ID_TOUCH or id == ID_MB1
end

local function is_rmb(id)
    return id == ID_MB2 or id == ID_MB3
end

local function room_keys(rooms)
    local keys = {}
    for id, _ in pairs(rooms or {}) do
        keys[#keys + 1] = id
    end
    return table.concat(keys, ", ")
end

function M.on_input(self, action_id, action, deps)
    if not action then return end
    deps = deps or {}
    -- Keep Defold pick coordinates for gui.pick_node, and use raw screen
    -- pixels converted to design coordinates for canvas movement.
    local design_x, design_y, inside = Viewport.pointer(action)
    local pointer_button = is_lmb(action_id) or is_rmb(action_id)
        or action_id == ID_WHL_UP or action_id == ID_WHL_DN
    if pointer_button and action.pressed and not inside then return true end

    local logf = deps.logf or function() end
    local handle_popup_ok = deps.handle_popup_ok
    local room_list_scroll_metrics = deps.room_list_scroll_metrics
    local zoom_step = deps.zoom_step
    local export_minimap_direct = deps.export_minimap_direct
    local return_to_menu = deps.return_to_menu
    local clear_all_selections = deps.clear_all_selections
    local save_layout = deps.save_layout
    local spawn_room = deps.spawn_room
    local apply_camera = deps.apply_camera
    local canon_id = deps.canon_id
    local set_selected_room = deps.set_selected_room
    local find_room_by_canon = deps.find_room_by_canon
    local clear_all_manual_door_insets = deps.clear_all_manual_door_insets
    local disable_keep_all_loaded = deps.disable_keep_all_loaded
    local promote_room_order = deps.promote_room_order
    local set_trash_highlight = deps.set_trash_highlight
    local delete_room = deps.delete_room
    local restore_keep_all_loaded = deps.restore_keep_all_loaded
    local try_snap_to_doors_simple = deps.try_snap_to_doors_simple

    if self.world_read_only and not self.popup_visible then
        -- Inspection has no draft side effects. Only navigation and the explicit
        -- Edit Here ownership action are available until a manual copy is made.
        if action_id==ID_WHL_UP and action.pressed then zoom_step(self,1+(S.canvas.zoom_step or .10),design_x,design_y)
        elseif action_id==ID_WHL_DN and action.pressed then zoom_step(self,1/(1+(S.canvas.zoom_step or .10)),design_x,design_y)
        elseif action.pressed and is_lmb(action_id) and action.x then
            if self.n_btn_export and UI.point_in_node(self.n_btn_export,action.x,action.y) then deps.take_manual(self)
            elseif self.n_btn_clear and UI.point_in_node(self.n_btn_clear,action.x,action.y) then deps.restore_manual(self)
            elseif self.n_btn_menu and UI.point_in_node(self.n_btn_menu,action.x,action.y) then return_to_menu()
            elseif self.n_btn_zoom_in and UI.point_in_node(self.n_btn_zoom_in,action.x,action.y) then zoom_step(self,1+(S.canvas.zoom_step or .10))
            elseif self.n_btn_zoom_out and UI.point_in_node(self.n_btn_zoom_out,action.x,action.y) then zoom_step(self,1/(1+(S.canvas.zoom_step or .10))) end
        elseif action.pressed and is_rmb(action_id) then
            self.pan_drag=true;self.pan_start={x=design_x,y=design_y};self.pan_base={x=self.pan.x,y=self.pan.y}
        elseif self.pan_drag and design_x then
            if action.released then self.pan_drag=false
            else self.pan.x=self.pan_base.x+design_x-self.pan_start.x;self.pan.y=self.pan_base.y+design_y-self.pan_start.y;apply_camera(self) end
        end
        return true
    end

    if self.popup_visible then
        if action.pressed and is_lmb(action_id) then
            if self.n_popup_ok_btn and gui.pick_node(self.n_popup_ok_btn, action.x, action.y) then
                handle_popup_ok(self)
                return true
            end
            if self.n_popup_overlay and gui.pick_node(self.n_popup_overlay, action.x, action.y) then
                handle_popup_ok(self)
                return true
            end
        end
        return true
    end

    if action_id == ID_LCTRL or action_id == ID_RCTRL then
        if action.pressed then
            self.mod_ctrl_down = true
        elseif action.released then
            self.mod_ctrl_down = false
        end
    elseif action_id == ID_LSHIFT or action_id == ID_RSHIFT then
        if action.pressed then
            self.mod_shift_down = true
        elseif action.released then
            self.mod_shift_down = false
        end
    end

    if action.released and is_lmb(action_id) then
        self.sidebar_click_debounce = false
    end

    if ControllerUndo.handle_shortcut(action_id, action, self.mod_ctrl_down, function()
        apply_camera(self)
        save_layout(self)
        UI.rebuild_rooms_sidebar(self)
    end) then
        return true
    end

    if action.pressed and is_lmb(action_id) then
        logf("=== ACTION DEBUG ===")
        logf("action_id: %s", tostring(action_id))
        logf("action.ctrl: %s (state=%s)", tostring(action.ctrl), tostring(self.mod_ctrl_down))
        logf("action.shift: %s (state=%s)", tostring(action.shift), tostring(self.mod_shift_down))
        logf("action.alt: %s", tostring(action.alt))
        logf("action.pressed: %s", tostring(action.pressed))
        logf("===================")
    end

    local over_room_list = false
    if inside then
        local w = Viewport.design_size()
        local sidebar_width = 300
        local sidebar_left = w - sidebar_width
        if design_x >= sidebar_left and #(self.sidebar_items or {}) > 0 then
            over_room_list = true
        end
    end

    if action_id == ID_WHL_UP and action.pressed then
        if over_room_list then
            local item_h, gap, num_items, clip_height, total_height, max_offset = room_list_scroll_metrics(self)
            local scroll_amount = item_h + gap
            local old_offset = self.room_list_scroll_offset or 0
            self.room_list_scroll_offset = old_offset + scroll_amount
            if self.room_list_scroll_offset > max_offset then
                self.room_list_scroll_offset = max_offset
            end
            logf("SCROLL UP: offset %d -> %d (max: %d, items: %d, total_h: %.1f, clip_h: %.1f)", old_offset, self.room_list_scroll_offset, max_offset, num_items, total_height, clip_height)
            UI.update_room_list_scroll(self)
            return
        end

        zoom_step(self, 1 + (S.canvas.zoom_step or 0.10), design_x, design_y)
        return
    end

    if action_id == ID_WHL_DN and action.pressed then
        if over_room_list then
            local item_h, gap = room_list_scroll_metrics(self)
            local scroll_amount = item_h + gap
            local old_offset = self.room_list_scroll_offset or 0
            self.room_list_scroll_offset = old_offset - scroll_amount
            if self.room_list_scroll_offset < 0 then
                self.room_list_scroll_offset = 0
            end
            logf("SCROLL DOWN: offset %d -> %d (min: 0)", old_offset, self.room_list_scroll_offset)
            UI.update_room_list_scroll(self)
            return
        end

        zoom_step(self, 1 / (1 + (S.canvas.zoom_step or 0.10)), design_x, design_y)
        return
    end

    if action_id == ID_SPACE then
        self.space_down = action.pressed or (not action.released and self.space_down)
        return
    end

    if action_id == ID_KEY_M and action.pressed then
        if self.export_in_progress then
            logf("[LE.EXPORT] Hotkey pressed but export is already running; ignoring.")
            return
        end
        logf("[LE.EXPORT] Hotkey pressed; starting export_minimap_direct()")
        print("[LE.EXPORT] Hotkey pressed; starting export_minimap_direct()")
        export_minimap_direct(self)
        return
    end

    if action.x == nil or design_x == nil then return end

    local x, y = action.x, action.y

    if action.pressed then
        logf("=== BUTTON CLICK DEBUG ===")
        logf("Click at (%.1f, %.1f)", x, y)
        logf("btn_rescan node: %s", self.n_btn_rescan and "exists" or "nil")
        if self.n_btn_rescan then
            logf("btn_rescan point_in_node: %s", UI.point_in_node(self.n_btn_rescan, x, y) and "YES" or "NO")
        end
        logf("=== END BUTTON CLICK DEBUG ===")

        if self.n_btn_menu and UI.point_in_node(self.n_btn_menu, x, y) then
            msg.post(".", "release_input_focus")
            return_to_menu()
            return true
        end

        if self.n_btn_rescan and UI.point_in_node(self.n_btn_rescan, x, y) then
            msg.post("layout_editor:/manifest_loader#manifest_loader", MSG_RESCAN)
            logf("Rescan clicked")
            return
        end

        if self.n_btn_export and UI.point_in_node(self.n_btn_export, x, y) then
            if self.export_in_progress then
                local now = os.clock()
                local stale = (self.last_export_start or 0) > 0 and (now - self.last_export_start) > 10
                if stale then
                    logf("[LE.EXPORT] Stale export detected in button handler; clearing flag and retrying")
                    self.export_in_progress = false
                else
                    logf("[LE.EXPORT] Click ignored - already exporting (flag still true)")
                    print("[LE.EXPORT] Click ignored - already exporting (flag still true)")
                    return
                end
            end
            logf("[LE.EXPORT] Export button clicked; starting export_minimap_direct()")
            print("[LE.EXPORT] Export button clicked; starting export_minimap_direct()")
            self.last_export_click = { t = os.clock(), x = x, y = y }
            export_minimap_direct(self)
            logf("[LE.EXPORT] export_minimap_direct() dispatched")
            print("[LE.EXPORT] export_minimap_direct() dispatched")
            return
        end

        if self.n_btn_clear and UI.point_in_node(self.n_btn_clear, x, y) then
            clear_all_selections(self)
            for _, R in pairs(self.rooms) do
                Render.release_room_resources(R)
                UI.delete_safe(R.group)
            end
            self.rooms = {}
            self.room_order, self.room_order_index = {}, {}
            ControllerUndo.init()
            SpawnCursor.reset(self, 0)
            save_layout(self)
            logf("cleared all rooms")
            UI.rebuild_rooms_sidebar(self)
            return
        end

        if self.n_btn_zoom_out and UI.point_in_node(self.n_btn_zoom_out, x, y) then
            zoom_step(self, 1 / (1 + (S.canvas.zoom_step or 0.10)))
            return
        end

        if self.n_btn_zoom_in and UI.point_in_node(self.n_btn_zoom_in, x, y) then
            zoom_step(self, 1 + (S.canvas.zoom_step or 0.10))
            return
        end
    end

    if action.pressed and is_lmb(action_id) then
        if self.sidebar_click_debounce then
            logf(">>> SIDEBAR CLICK HANDLER SKIPPED (debounce active) action=%s at (%.1f, %.1f)", tostring(action_id), x, y)
            return
        end

        self.sidebar_click_counter = (self.sidebar_click_counter or 0) + 1
        logf(">>> SIDEBAR CLICK HANDLER CALLED #%d at (%.1f, %.1f)", self.sidebar_click_counter, x, y)

        if self.sidebar_click_in_progress then
            logf("!!! Ignoring sidebar click #%d - already processing another sidebar click", self.sidebar_click_counter)
            return
        end

        local matched_count = 0
        for _, it in ipairs(self.sidebar_items) do
            local pick = it.hit or it.node
            local inside = UI.point_in_node(pick, x, y)
            if inside then
                matched_count = matched_count + 1
                logf("  Matched item #%d: id=%s", matched_count, it.id)
            end
        end
        logf("Total matched items: %d", matched_count)

        if matched_count > 1 then
            logf("!!! WARNING: Multiple sidebar items matched the same click!")
        end

        for _, it in ipairs(self.sidebar_items) do
            local pick = it.hit or it.node
            local inside = UI.point_in_node(pick, x, y)
            if inside then
                self.sidebar_click_debounce = true
                self.sidebar_click_in_progress = true

                logf("=== SIDEBAR ROOM ADD START (click #%d) ===", self.sidebar_click_counter)
                logf("sidebar click: %s", it.id)

                local cid = canon_id(it.id)
                local already_present = false
                if cid and self.rooms and self.rooms[cid] then
                    already_present = true
                elseif self.rooms and self.rooms[it.id] then
                    already_present = true
                end

                logf("already_present: %s (checked both it.id=%s and cid=%s)", tostring(already_present), it.id, tostring(cid))
                logf("self.rooms keys before spawn: %s", room_keys(self.rooms))

                local R = (cid and self.rooms[cid]) or self.rooms[it.id] or spawn_room(self, it.id)
                if R then
                    logf("Room spawned/retrieved: %s", R.id)
                    local ctrl_pressed = self.mod_ctrl_down or action.ctrl or false
                    local shift_pressed = self.mod_shift_down or action.shift or false
                    logf("Sidebar click - Modifiers - Ctrl: %s, Shift: %s", tostring(ctrl_pressed), tostring(shift_pressed))
                    set_selected_room(self, it.id, { ctrl = ctrl_pressed, shift = shift_pressed })
                    apply_camera(self)
                    if not already_present then
                        logf("Saving layout and triggering rescan for new room")
                        save_layout(self)
                        logf("Posting MSG_RESCAN to manifest_loader")
                        msg.post("layout_editor:/manifest_loader#manifest_loader", MSG_RESCAN)
                        logf("Rebuilding rooms sidebar (new room added)")
                        UI.rebuild_rooms_sidebar(self)
                    else
                        logf("Room was already present, skipping save, rescan, and sidebar rebuild")
                    end
                    logf("self.rooms keys after add: %s", room_keys(self.rooms))
                else
                    logf("ERROR: Failed to spawn/retrieve room %s", it.id)
                end
                logf("=== SIDEBAR ROOM ADD END ===")

                self.sidebar_click_in_progress = false
                return
            end
        end
    end

    if action.pressed and ((self.space_down and is_lmb(action_id)) or is_rmb(action_id)) then
        self.pan_drag = true
        self.pan_start = vmath.vector3(design_x, design_y, 0)
        self.pan_base = vmath.vector3(self.pan)
        logf("pan start at (%.1f,%.1f)", x, y)
        return
    end

    if self.pan_drag then
        if action.released then
            self.pan_drag = false
            logf("pan end -> pan=(%.1f,%.1f)", self.pan.x, self.pan.y)
        else
            local d = vmath.vector3(design_x, design_y, 0) - self.pan_start
            self.pan = self.pan_base + d
            apply_camera(self)
        end
        return
    end

    if action.pressed and is_lmb(action_id) then
        logf("=== DRAG/SELECT ROOM START (LMB pressed at %.1f, %.1f) ===", x, y)

        local ctrl_pressed = self.mod_ctrl_down or action.ctrl or false
        local shift_pressed = self.mod_shift_down or action.shift or false
        local is_multi_select = ctrl_pressed or shift_pressed

        logf("Modifiers - Ctrl: %s, Shift: %s, Multi-select mode: %s", tostring(ctrl_pressed), tostring(shift_pressed), tostring(is_multi_select))

        self.drag_room = nil
        local clicked_room = nil

        if self.room_order and #self.room_order > 0 then
            logf("Checking room_order (count: %d)", #self.room_order)
            for idx = #self.room_order, 1, -1 do
                local cid = self.room_order[idx]
                local R = select(1, find_room_by_canon(self, cid))
                if R and UI.point_in_node(R.group, x, y) then
                    logf("Found room in room_order: %s (cid: %s)", R.id, cid)
                    clicked_room = R
                    break
                end
            end
        end

        if not clicked_room then
            logf("Not found in room_order, checking all rooms")
            for room_id, R in pairs(self.rooms or {}) do
                if UI.point_in_node(R.group, x, y) then
                    logf("Found room in self.rooms: %s (key: %s)", R.id, room_id)
                    clicked_room = R
                    break
                end
            end
        end

        if clicked_room then
            if is_multi_select then
                logf("Multi-select click on room: %s", clicked_room.id)
                set_selected_room(self, clicked_room, { ctrl = ctrl_pressed, shift = shift_pressed })
                return
            end

            logf("Drag room found: %s", clicked_room.id)
            self.drag_room = clicked_room
            self.drag_offset = vmath.vector3(design_x, design_y, 0) - gui.get_position(self.drag_room.group)
            self.drag_start_pos = vmath.vector3(clicked_room.base_pos)
            clear_all_manual_door_insets(self)
            Render.recolor_doors_for_overlaps(self)
            disable_keep_all_loaded(self)
            local cid = canon_id(self.drag_room.id)
            logf("Canon ID of drag room: %s", cid)
            promote_room_order(self, cid)
            logf("Calling set_selected_room with drag_room (id=%s)", self.drag_room.id)
            set_selected_room(self, self.drag_room)
            logf("drag start: %s", self.drag_room.id)
            return
        end

        logf("No room found under cursor")
    end

    if self.drag_room then
        local hovering_trash = self.n_trash and UI.point_in_node(self.n_trash, x, y) or false
        set_trash_highlight(self, hovering_trash)

        if action.released then
            local dragged = self.drag_room
            local old_pos = self.drag_start_pos
            logf("drag end: %s", dragged and dragged.id or "<nil> (unexpected)")
            local dropped_in_trash = hovering_trash
            set_trash_highlight(self, false)

            if dragged and self.drag_offset and action.x and action.y then
                local drop_pos = vmath.vector3(design_x, design_y, 0)
                local new_pos = drop_pos - self.drag_offset
                local origin = vmath.vector3(self.canvas.x, self.canvas.y, 0)
                local zoom = self.zoom or 1
                if zoom == 0 then zoom = 1 end
                dragged.base_pos = (new_pos - origin - self.pan) / zoom
                dragged.base_pos.z = 0
                logf("*** DEBUG: Room %s base_pos set to (%.1f, %.1f) [drag_release]", dragged.id, dragged.base_pos.x, dragged.base_pos.y)
            end

            self.drag_room = nil
            self.drag_offset = nil
            self.drag_start_pos = nil

            if dropped_in_trash and dragged then
                logf("room trashed: %s", tostring(dragged.id))
                -- Treat drag-to-trash as one deletion; restoring it should put
                -- the room back where the drag began, including protected rooms.
                if old_pos then dragged.base_pos = vmath.vector3(old_pos) end
                if delete_room(self, dragged.id) then
                    save_layout(self)
                    UI.rebuild_rooms_sidebar(self)
                end
                apply_camera(self)
                restore_keep_all_loaded(self)
                return
            end

            local snapped = dragged and try_snap_to_doors_simple(self, dragged) or false
            logf("snap attempt: %s", tostring(snapped))
            -- Snapping is part of the move, so redo must restore the final
            -- placement rather than the mouse's unsnapped release position.
            if dragged and old_pos then
                ControllerUndo.record_move(self, dragged.id, old_pos, vmath.vector3(dragged.base_pos), apply_camera)
            end
            apply_camera(self)
            save_layout(self)
            restore_keep_all_loaded(self)
        else
            local new_pos = vmath.vector3(design_x, design_y, 0) - self.drag_offset
            local origin = vmath.vector3(self.canvas.x, self.canvas.y, 0)
            local old_pos = self.drag_room.base_pos
            self.drag_room.base_pos = (new_pos - origin - self.pan) / self.zoom
            logf("*** DEBUG: Room %s base_pos set to (%.1f, %.1f) [drag_update] from (%.1f, %.1f)",
                self.drag_room.id, self.drag_room.base_pos.x, self.drag_room.base_pos.y, old_pos.x, old_pos.y)
            apply_camera(self)
            gui.set_position(self.drag_room.group, new_pos)
            gui.set_scale(self.drag_room.group, vmath.vector3(self.zoom, self.zoom, 1))
        end
        return
    end

    set_trash_highlight(self, false)
end

return M
