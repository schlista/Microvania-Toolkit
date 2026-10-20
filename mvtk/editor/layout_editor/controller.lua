local Viewport = require "mvtk.ui.viewport"
print('[LE.CTL] controller module loaded')
-- mvtk/editor/layout_editor/controller.lua
-- Layout Editor Controller (vZ42)
-- Responsibilities:
--  * Lifecycle (init/update/on_message/on_input)
--  * Camera (zoom/pan), save/load layout
--  * Snapping between doors
--  * Resolve tilemap path + spawn/reload rooms
--  * Delegates: UI (nodes/sidebar/canvas), Render (draw + locks)

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local Outline = require "mvtk.editor.room_outline"
local Doors   = require "mvtk.editor.room_doors"
local LockedDoorReader = require "mvtk.editor.locked_door_reader"
local MINIMAP_CFG = Util.require_config("developer.config.minimap_settings")
local Tile = Util.require_config("developer.config.tile_settings")
local TileSettingsWriter = require "mvtk.editor.tile_settings_writer"
local RoomManager = Util.require_module("mvtk.map.streaming.room_manager")

local UI      = require "mvtk.editor.layout_editor.ui"
local Render  = require "mvtk.editor.layout_editor.render"
local RoomRegistry = require "mvtk.editor.layout_editor.room_registry"
local LayoutIO = require "mvtk.rooms.layout_io"
local TagExport = require "mvtk.editor.layout_editor.tag_export"
local TiledRegistry = require "mvtk.tiled.tiled_room_registry"
local StreamPaths = require "mvtk.rooms.stream_paths"

-- Pure helpers split out of this controller to keep it focused on coordination.
local LuaSerializer = require "mvtk.editor.layout_editor.lua_serializer"
local SpawnCursor   = require "mvtk.editor.layout_editor.spawn_cursor"
local ControllerState = require "mvtk.editor.layout_editor.controller_state"
local DoorSnap      = require "mvtk.editor.layout_editor.door_snap"
local Camera        = require "mvtk.editor.layout_editor.controller_camera"
local ControllerInput = require "mvtk.editor.layout_editor.controller_input"
local ProgressionPanel = require "mvtk.editor.layout_editor.progression_panel"

local function project_tile_width()
    local w = tonumber(Tile and (Tile.width or Tile.tile_width or Tile.size))
    return (w and w > 0) and w or 128
end

local function project_tile_height()
    local h = tonumber(Tile and (Tile.height or Tile.tile_height or Tile.size))
    return (h and h > 0) and h or project_tile_width()
end

-- State helpers re-exported under their historical names while the controller
-- is split into focused modules.
local canon_id              = ControllerState.canon_id
local find_room_by_canon    = ControllerState.find_by_canon
local deselect_current_room = ControllerState.deselect_current
local resolve_room          = ControllerState.resolve
local clear_all_selections  = ControllerState.clear_all
local toggle_room_selection = ControllerState.toggle
local range_select_rooms    = ControllerState.range_select
local set_selected_room     = ControllerState.set

-- Door-snap helpers re-exported under their historical names.
local try_snap_to_doors_simple = DoorSnap.try_snap

-- Professional logging system
local Logger = require "mvtk.core.logger"
local log = Logger.get_logger("layout_editor.controller")
local function logf(fmt, ...) log.debug(fmt, ...) end

-- Undo/Redo system
local ControllerUndo = require "mvtk.editor.layout_editor.controller_undo"

-- State validation system
local StateValidator = require "mvtk.editor.layout_editor.state_validator"

-- ============================================================================================================================================================
-- Messages
local MSG_MANIFEST_SAVED = hash("manifest_saved")
local MSG_UI_RESCAN      = hash("rescan_rooms")

local SAVE_FILE

-- Forward declarations for helpers referenced before their definitions.
local align_view_on_room
local delete_room

-- ============================================================================================================================================================
-- Utilities (local)

local PROJECT_ROOT_CACHE = nil

local function normalize_path(path)
    if not path or path == "" then
        return nil
    end
    return path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
end

local function resolve_project_root()
    if PROJECT_ROOT_CACHE ~= nil then
        return PROJECT_ROOT_CACHE or nil
    end

    local candidates = {}

    if debug and debug.getinfo then
        local src = debug.getinfo(1, "S").source
        if src then
            src = src:gsub("^@", "")
            src = normalize_path(src)
            local base = src and src:match("^(.*)/mvtk/editor/layout_editor/controller.lua$")
            if base then
                candidates[#candidates + 1] = base
            end
        end
    end

    local env = os.getenv("MVTK_PROJECT_ROOT")
    if env and env ~= "" then
        candidates[#candidates + 1] = env
    end

    if S and S.project_root then
        candidates[#candidates + 1] = S.project_root
    end

    candidates[#candidates + 1] = "."

    local seen = {}
    for _, base in ipairs(candidates) do
        base = normalize_path(base)
        if base and base ~= "" and not seen[base] then
            seen[base] = true
            local fh = io.open(base .. "/game.project", "r")
            if fh then
                fh:close()
                PROJECT_ROOT_CACHE = base
                log.debug("[LE.EXPORT] Project root resolved: %s", base)
                return base
            end
        end
    end

    log.debug("[LE.EXPORT] Unable to resolve project root; using working directory")
    PROJECT_ROOT_CACHE = false
    return nil
end

local function return_to_menu()
    local function post(target, msg_id, payload)
        local ok_url, url = pcall(msg.url, target)
        if ok_url and url then
            local ok_post = pcall(msg.post, url, msg_id, payload or {})
            if ok_post then
                return true
            end
        end
        return false
    end

    local host_targets = {
        "boot:/host#script",
        "/host#script",
        "main:/host#script",
    }

    for _, target in ipairs(host_targets) do
        if post(target, hash("back_to_menu"), {}) then
            return
        end
    end

    for _, target in ipairs(host_targets) do
        if post(target, hash("menu_show"), {}) then
            return
        end
    end
end

local function disable_keep_all_loaded(self)
    if not (RoomManager and RoomManager.set_keep_all_loaded and RoomManager.get_keep_all_loaded) then
        return
    end
    if self.keep_all_loaded_restore ~= nil then
        return
    end
    local current = RoomManager.get_keep_all_loaded()
    self.keep_all_loaded_restore = current
    if current then
        RoomManager.set_keep_all_loaded(false)
    end
end

local function restore_keep_all_loaded(self)
    if self.keep_all_loaded_restore == nil then
        return
    end
    if RoomManager and RoomManager.set_keep_all_loaded then
        RoomManager.set_keep_all_loaded(self.keep_all_loaded_restore)
    end
    self.keep_all_loaded_restore = nil
end

local function room_list_scroll_metrics(self)
    local item_h = tonumber(S.sidebar and S.sidebar.item_h_px) or 22
    local gap = tonumber(S.sidebar and S.sidebar.item_gap_px) or 6
    local num_items = #(self.sidebar_items or {})

    local clip_height = 0
    if self.n_room_list_clip then
        local ok, size = pcall(gui.get_size, self.n_room_list_clip)
        if ok and size then
            clip_height = size.y or 0
        end
    end
    if clip_height <= 0 then
        clip_height = tonumber(S.sidebar and S.sidebar.visible_height_px) or 600
    end

    local total_height = math.max(0, (num_items * item_h) + math.max(0, num_items - 1) * gap)
    local max_offset = math.max(0, total_height - clip_height)

    return item_h, gap, num_items, clip_height, total_height, max_offset
end

local function apply_camera(self)
    return Camera.apply(self)
end

local function default_room_spawn_base(self, shape)
    return Camera.default_room_spawn_base(self, shape)
end

local function promote_room_order(self, cid)
    return ControllerState.promote_room_order(self, cid)
end

align_view_on_room = Camera.align_view_on_room

-- Build neighbor pairs based on current positions and door geometry
local function build_neighbors(self)
    return require("developer.tools.layout_geometry").neighbors(self.rooms, S)
end

local function prepare_tags_for_save(tags)
    if not tags then
        return nil
    end
    local clone = RoomRegistry.clone_tags(tags)

    local marker = clone.marker or {}
    local offset = marker.offset or { x = 0, y = 0 }
    local has_marker = marker.enabled
        or (marker.label and marker.label ~= "")
        or (marker.type and marker.type ~= "custom")
        or math.abs(tonumber(offset.x) or 0) > 0.001
        or math.abs(tonumber(offset.y) or 0) > 0.001

    if has_marker then
        clone.marker = {
            enabled = marker.enabled and true or false,
            type = marker.type or "custom",
            label = marker.label,
            offset = {
                x = tonumber(offset.x) or 0,
                y = tonumber(offset.y) or 0,
            },
        }
        if marker.color then
            local col = marker.color
            clone.marker.color = {
                r = tonumber(col.r or col.x or col[1]) or 0,
                g = tonumber(col.g or col.y or col[2]) or 0,
                b = tonumber(col.b or col.z or col[3]) or 0,
                a = tonumber(col.a or col.w or col[4]) or 1,
            }
        end
    else
        clone.marker = nil
    end

    if not has_marker then
        return nil
    end
    return {
        marker = clone.marker,
    }
end

local function save_layout(self, preview_only)
    if self.world_read_only and not preview_only then return false, "Tiled owns placement. Choose Edit Here to take a manual copy." end
    log.debug("=== SAVE_LAYOUT FUNCTION START ===")
    local room_count = 0
    if self.rooms then
        for _ in pairs(self.rooms) do room_count = room_count + 1 end
    end
    log.debug("Available rooms: %d", room_count)

    local tile_validation = TileSettingsWriter.validate_layout_shapes(self.rooms, Tile)
    if not tile_validation.ok then
        local message = tile_validation.error or string.format(
            "Layout tile size does not match tile_settings.lua (%dx%d)",
            tonumber(tile_validation.expected_width) or 0,
            tonumber(tile_validation.expected_height) or 0
        )
        for _, mismatch in ipairs(tile_validation.mismatches or {}) do
            log.debug(
                "ERROR: Room %s shape uses %dx%d tiles; tile_settings.lua is %dx%d",
                tostring(mismatch.room_id),
                tonumber(mismatch.width) or 0,
                tonumber(mismatch.height) or 0,
                tonumber(tile_validation.expected_width) or 0,
                tonumber(tile_validation.expected_height) or 0
            )
        end
        log.debug("ERROR: %s", message)
        return false, message
    end
    
    local neighbors = build_neighbors(self)
    local out = { version = LayoutIO.VERSION, rooms = {}, preserve_origin=self.preserve_origin }

    -- ensure stable placement order (first placed = start)
    local order = self.room_order or {}
    local seen = {}

    local function append_room(cid)
        if seen[cid] then return end
        local R = find_room_by_canon(self, cid)
        if not R then return end
        -- Preserve the saved layout anchor and its bounds offsets. Baked
        -- content uses a separate displacement to the zero-based tile origin.
        local shape = R.shape or {}
        local tw = project_tile_width()
        local th = project_tile_height()
        local minx = tonumber(shape.min_x) or 1
        local miny = tonumber(shape.min_y) or 1
        local ox = (minx - 1) * tw
        local oy = (miny - 1) * th
        local collection_offset_x, collection_offset_y =
            require("mvtk.map.streaming.room_geometry").collection_offsets(shape, tw, th)

        local base = R.base_pos or vmath.vector3()
        local orig_x = base.x or 0
        local orig_y = base.y or 0
        -- Disable grid snapping to prevent unwanted movement after door snapping
        -- local snapped_base_x = snap_to_step(orig_x, tw)
        -- local snapped_base_y = snap_to_step(orig_y, th)

        -- if math.abs(snapped_base_x - orig_x) > 0.001 or math.abs(snapped_base_y - orig_y) > 0.001 then
        --     log.debug("snap base %s (%.1f, %.1f) -> (%.1f, %.1f)", cid, orig_x, orig_y, snapped_base_x, snapped_base_y)
        --     base.x = snapped_base_x
        --     base.y = snapped_base_y
        --     R.base_pos = base
        --     log.debug("*** DEBUG: Room %s base_pos set to (%.1f, %.1f) [snap_and_position_rooms]", cid, base.x, base.y)
        -- end

        local door_payload = {}
        for _, door in ipairs(shape.doors or {}) do
            door_payload[#door_payload+1] = {
                side = door.side,
                cx   = tonumber(door.cx) or 0,
                cy   = tonumber(door.cy) or 0,
                len  = tonumber(door.len_px or door.len) or 0,
            }
        end

        local rec = {
            id   = cid,
            path = LayoutIO.path_for_id(cid),
            -- Layout anchor; x+ox/y+oy locate the bounds corner.
            x    = orig_x - ox,
            y    = orig_y - oy,
            -- Persist dimensions and offsets for robust re-load in editor and diagnostics
            w    = shape.w_px or nil,
            h    = shape.h_px or nil,
            ox   = ox,
            oy   = oy,
            collection_offset_x = collection_offset_x,
            collection_offset_y = collection_offset_y,
            tw   = tw,
            th   = th,
            neighbors = neighbors[cid] or {},
        }
        if #door_payload > 0 then rec.doors = door_payload end
        local tag_payload = prepare_tags_for_save(R.tags)
        if tag_payload then
            rec.tags = tag_payload
        end
        out.rooms[#out.rooms+1] = rec
        seen[cid] = true
    end

    for _, cid in ipairs(order) do append_room(canon_id(cid)) end
    -- include any other rooms that might have been added without order tracking
    for id,_ in pairs(self.rooms or {}) do append_room(canon_id(id)) end

    log.debug("=== ABOUT TO SAVE DATA ===")
    log.debug("Output data rooms count: %d", #out.rooms)
    for i, rec in ipairs(out.rooms) do
        log.debug("Room %d: id=%s, x=%.1f, y=%.1f, neighbors=%d",
             i, rec.id or "nil", rec.x or -9999, rec.y or -9999, #(rec.neighbors or {}))
    end
    
    if preview_only then return true,out end
    local save_result = LayoutIO.save(out)
    if save_result then
        local Preparation=require "developer.tools.preparation"
        local recorded,err=pcall(Preparation.commit,{root=resolve_project_root() or "."},"runtime/layout/draft_revision.lua",out)
        if not recorded then error("Could not record draft revision: "..tostring(err)) end
    end
    local export_ok, export_err = pcall(TagExport.write, out)
    if not export_ok then
        log.debug("TAG EXPORT FAILED: %s", tostring(export_err))
    else
        self.tags_dirty = false
    end
    log.debug("LayoutIO.save returned: %s", tostring(save_result))
    log.debug("layout saved (rooms=%d): %s", #out.rooms, SAVE_FILE)
    log.debug("=== SAVE_LAYOUT FUNCTION END ===")
    self._last_saved_layout = out
    return true, out
end


-- UI helpers -----------------------------------------------------------------
local function design_size()
    return Viewport.design_size()
end

local function ensure_export_overlay(self)
    if self.n_export_overlay and self.n_export_label then return end
    local w, h = design_size()
    local root = self.n_root or gui.get_node("root")
    local overlay = gui.new_box_node(vmath.vector3(w * 0.5, h * 0.5, -0.9), vmath.vector3(w, h, 0))
    gui.set_parent(overlay, root, false)
    gui.set_pivot(overlay, gui.PIVOT_CENTER)
    gui.set_color(overlay, vmath.vector4(0, 0, 0, 0.65))

    local label = gui.new_text_node(vmath.vector3(0, 0, -1.0), "Exporting minimap…")
    gui.set_parent(label, overlay, false)
    gui.set_pivot(label, gui.PIVOT_CENTER)
    gui.set_color(label, vmath.vector4(1, 1, 1, 1))
    gui.set_scale(label, vmath.vector3(1.1, 1.1, 1))
    UI.set_z(overlay, 0.95)
    UI.set_z(label, 0.96)
    self.n_export_overlay = overlay
    self.n_export_label = label
end

local function show_export_overlay(self, text)
    ensure_export_overlay(self)
    local w, h = design_size()
    if self.n_export_overlay then
        gui.set_position(self.n_export_overlay, vmath.vector3(w * 0.5, h * 0.5, -0.9))
        gui.set_size(self.n_export_overlay, vmath.vector3(w, h, 0))
        gui.set_color(self.n_export_overlay, vmath.vector4(0, 0, 0, 0.65))
        gui.set_enabled(self.n_export_overlay, true)
    end
    if self.n_export_label then
        gui.set_size(self.n_export_label, vmath.vector3(w * 0.8 / 1.1, h * 0.8 / 1.1, 0))
        gui.set_line_break(self.n_export_label, true)
        gui.set_text(self.n_export_label, text or "Exporting minimap…")
        gui.set_color(self.n_export_label, vmath.vector4(1, 1, 1, 1))
        gui.set_enabled(self.n_export_label, true)
    end
end

-- Button state helpers -------------------------------------------------------

local function capture_button_state(node, text)
    if not node then return nil end
    local col = gui.get_color(node)
    col.w = 1
    local text_col = text and gui.get_color(text)
    if text_col then text_col.w = 1 end
    return {
        box = node,
        text = text,
        base_color = col,
        text_base_color = text_col,
    }
end

local function set_button_state(btn, enabled, dim_alpha)
    if not btn then return end
    local a = enabled and (btn.base_color.w or 1) or (dim_alpha or 0.35)
    local b = btn.base_color
    gui.set_color(btn.box, vmath.vector4(b.x, b.y, b.z, a))
    gui.set_alpha(btn.box, a)
    if btn.text and btn.text_base_color then
        local t = btn.text_base_color
        gui.set_color(btn.text, vmath.vector4(t.x, t.y, t.z, a))
        gui.set_alpha(btn.text, a)
    end
end

local function hide_export_overlay(self)
    if self.n_export_overlay then
        gui.set_color(self.n_export_overlay, vmath.vector4(0,0,0,0))
        gui.set_enabled(self.n_export_overlay, false)
    end
    if self.n_export_label then
        gui.set_color(self.n_export_label, vmath.vector4(0,0,0,0))
        gui.set_enabled(self.n_export_label, false)
    end
end

local function set_export_disabled(self, disabled)
    self.export_in_progress = disabled and true or false
    local enabled = not disabled
    local dim = 0.35
    if self.button_states then
        set_button_state(self.button_states.rescan, enabled, dim)
        set_button_state(self.button_states.export, enabled, dim)
        set_button_state(self.button_states.clear,  enabled, dim)
    elseif self.n_btn_export then
        local col = gui.get_color(self.n_btn_export)
        local alpha = enabled and 1.0 or dim
        gui.set_color(self.n_btn_export, vmath.vector4(col.x, col.y, col.z, alpha))
        gui.set_alpha(self.n_btn_export, alpha)
    end
end

local function begin_export(self, label)
    self.export_in_progress = true
    set_export_disabled(self, true)
    if self.button_states and self.button_states.menu then
        set_button_state(self.button_states.menu, false, 0.35)
    end
    show_export_overlay(self, label or "Exporting minimap…")
end

local function update_export_status(self, label)
    if self.export_in_progress then
        show_export_overlay(self, label or "Exporting minimap…")
    end
end

local function end_export(self)
    hide_export_overlay(self)
    set_export_disabled(self, false)
    if self.button_states and self.button_states.menu then
        set_button_state(self.button_states.menu, true)
    end
end



-- Shared tilemap helpers for minimap export
local TILEMAP_TEXT_CACHE = {}

local function load_text_cached(path, cache)
    if not path or path == "" then return nil end
    if cache[path] ~= nil then return cache[path] end
    local normalized = path
    if normalized:sub(1, 1) ~= "/" then normalized = "/" .. normalized end
    local ok, txt = pcall(sys.load_resource, normalized)
    if ok and type(txt) == "string" and #txt > 0 then
        cache[path] = txt
    else
        cache[path] = nil
    end
    return cache[path]
end

-- Platform parsing -----------------------------------------------------------

local function export_minimap_direct(self)
    -- If we somehow got stuck in "exporting", clear it so the user can retry.
    if self.export_in_progress then
        local now = os.clock()
        local stale = (self.last_export_start or 0) > 0 and (now - self.last_export_start) > 10
        if stale then
            log.debug("[LE.EXPORT] Stale export flag detected; clearing and retrying")
            self.export_in_progress = false
        else
            log.debug("[LE.EXPORT] export_minimap_direct called while export_in_progress=true; aborting")
            return
        end
    end

    self.last_export_start = os.clock()
    begin_export(self, "Preparing minimap export…")
    log.debug("[LE.EXPORT] export_minimap_direct entered")
    print("[LE.EXPORT] export_minimap_direct entered")

    local function progress(msg)
        update_export_status(self, msg)
        print("[LE.EXPORT] " .. tostring(msg))
        coroutine.yield()  -- Yield to allow frame to render with updated progress
    end

    local function finalize(ok, err)
        end_export(self)
        self.export_in_progress = false
        if ok then
            log.debug("[LE.EXPORT] Export finalized OK")
        else
            log.debug("[LE.EXPORT] Export finalized with ERROR: %s", tostring(err))
            self.relationship_error_visible = true
            show_export_overlay(self, require("mvtk.editor.layout_editor.export_error").message(err))
        end
    end

    -- Create coroutine for export process
    self.export_coroutine = coroutine.create(function()
    local ok_all, err_all = xpcall(function()
    log.debug("=== EXPORT MINIMAP DIRECT START ===")

    local saved_layout = nil
    progress("Saving layout…")
    local ok_save, save_ok, save_err = pcall(save_layout, self)
    if not ok_save then
        log.debug("ERROR: save_layout failed prior to export: %s", tostring(save_err))
        finalize(false, "Layout save failed before export")
        return
    elseif save_ok == false then
        log.debug("ERROR: save_layout blocked export: %s", tostring(save_err))
        finalize(false, save_err or "Layout tile size mismatch")
        return
    else
        saved_layout = self._last_saved_layout
    end

    if not self.rooms or next(self.rooms) == nil then
        log.debug("ERROR: No rooms in layout to export")
        print("[LE.EXPORT] ERROR: No rooms in layout to export")
        finalize(false, "No rooms in layout to export")
        return
    end

    progress("Checking authored relationships…")
    local published_rooms = {}
    require("developer.tools.preparation").require_built_sources({root=resolve_project_root() or "."})
    local publication_inputs=require("developer.tools.preparation").snapshot({root=resolve_project_root() or "."})
    for room_id in pairs(self.rooms or {}) do published_rooms[room_id] = true end
    require("developer.tools.relationship_project").require_valid({
        root=resolve_project_root() or ".", published_rooms=published_rooms, log=print, publish_report=true,
    })

    local room_count = 0
    for _ in pairs(self.rooms or {}) do room_count = room_count + 1 end
    print(string.format('[MINIMAP_EXPORT] Begin export (rooms=%d)', room_count))
    log.debug("Exporting minimap for %d rooms", room_count)
    progress(string.format("Scanning %d rooms…", room_count))

    local root = resolve_project_root() or "."
    local result = require("developer.tools.layout_minimap").render(self.rooms, {
        root=root,tile_width=project_tile_width(),tile_height=project_tile_height(),
        settings=MINIMAP_CFG,progress=progress,
        read=function(path) return load_text_cached(path, TILEMAP_TEXT_CACHE) end,
    })
    local width,height=result.width,result.height
    result.files[#result.files+1]={path="runtime/layout/world_layout.local.lua",content=LuaSerializer.serialize_layout_to_lua(saved_layout)}
    require("developer.tools.layout_publication").publish(root,saved_layout,result.files,
        {log=print,publish_report=true,expected_inputs=publication_inputs})

    progress("Finalizing export…")

    -- The layout editor and game run as mutually-exclusive collection proxies
    -- (see mvtk/boot/simple_manager.script). The game minimap is not loaded
    -- during editor export; it reads the freshly-exported minimap files the
    -- next time game mode loads. Posting to main:/... here only targets an
    -- unloaded socket and produces ERROR:GAMEOBJECT noise.
    log.debug("Export complete; game minimap will pick up new files on next game load.")

    log.debug("=== EXPORT MINIMAP DIRECT COMPLETE ===")
    print(string.format('[MINIMAP_EXPORT] Export complete (image=%dx%d)', width, height))
    end, debug.traceback) -- xpcall body
    if not ok_all then
        log.debug("ERROR during export: %s", tostring(err_all))
        print("[LE.EXPORT] ERROR during export:\n" .. tostring(err_all))
    end
    finalize(ok_all, err_all)
    end) -- end coroutine.create
end
-- ============================================================================================================================================================
-- Tilemap path resolution + room spawn/reload

local function try_load_text(path)
    local ok,txt = pcall(sys.load_resource,path)
    if ok and type(txt)=="string" and #txt>0 then return txt end
    return nil
end

local function resolve_tilemap_path(self, room_id)
    local raw = room_id:gsub("^/+", "")
    local ext = S.rooms_tilemap_ext or ".tilemap"

    local pad_w = tonumber(S.rooms_zero_pad) or 2
    local padded = nil
    local prefix, num = raw:match("^(.-)_(%d+)$")
    if prefix and num then
        padded = string.format("%s_%0"..pad_w.."d", prefix, tonumber(num))
        if padded == raw then padded = nil end
    end

    local candidates = {}
    local entry = self.room_index and self.room_index[room_id]
    if entry and entry.tilemap then candidates[#candidates+1] = entry.tilemap end

    local bases = {}
    if type(S.rooms_path_candidates) == "table" then
        for _,b in ipairs(S.rooms_path_candidates) do bases[#bases+1] = b end
    end
    bases[#bases+1] = S.rooms_path or StreamPaths.tiled_maps_dir()

    for _, base in ipairs(bases) do
        local b = base; if b:sub(-1) ~= "/" then b = b .. "/" end
        candidates[#candidates+1] = b .. raw .. ext
        if padded then candidates[#candidates+1] = b .. padded .. ext end
    end

    local seen, uniq = {}, {}
    for _, c in ipairs(candidates) do
        if not seen[c] then seen[c]=true; uniq[#uniq+1]=c end
    end
    candidates = uniq

    log.debug("resolve tilemap for %s; raw=%s padded=%s; trying %d candidates", room_id, raw, tostring(padded), #candidates)
    for _, c in ipairs(candidates) do
        local txt = try_load_text(c)
        if txt then log.debug("resolved %s =†’ %s", room_id, c); return c end
        log.debug("candidate missing: %s", c)
    end
    return nil, candidates
end

local function spawn_room(self, room_id, opts)
    opts = opts or {}

    log.debug(">>> spawn_room CALLED with room_id=%s", room_id)
    log.debug("    Current self.rooms keys: %s", table.concat(self.rooms and (function() local k={}; for id,_ in pairs(self.rooms) do k[#k+1]=id end; return k end)() or {}, ", "))

    -- Guard: Don't spawn if room already exists (unless force_respawn is set)
    if not (opts and opts.force_respawn) then
        local cid = canon_id(room_id)
        log.debug("    Checking if room exists - room_id=%s, cid=%s", room_id, tostring(cid))
        if cid and self.rooms and self.rooms[cid] then
            log.debug("    Room %s already exists under cid=%s, returning existing room", room_id, cid)
            return self.rooms[cid]
        end
        if self.rooms and self.rooms[room_id] then
            log.debug("    Room %s already exists under room_id, returning existing room", room_id)
            return self.rooms[room_id]
        end
        log.debug("    Room does not exist, proceeding with spawn")
    end

    local tilemap_path, tried = resolve_tilemap_path(self, room_id)
    if not tilemap_path then
        log.debug("[ERR] No readable tilemap for %s. Tried: %s", room_id, table.concat(tried or {}, " | "))
        return nil
    end

    local want_fill = true
    local max_rects = (S.preview and S.preview.max_rects_per_room) or 4096
    local shape, err = Outline.read_shape(tilemap_path, want_fill, max_rects)
    if not shape then
        log.debug("[ERR] read_shape failed for %s : %s", room_id, tostring(err))
        return nil
    end
    shape.id = room_id

    shape.doors = Doors.from_tilemap_file(tilemap_path, shape)

    local parent = UI.ensure_canvas_root(self)
    local group = gui.new_box_node(vmath.vector3(0,0,0), vmath.vector3(shape.w_px, shape.h_px, 0))
    gui.set_parent(group, parent, false)
    gui.set_pivot(group, gui.PIVOT_SW)
    gui.set_color(group, vmath.vector4(0,0,0,0))

    local base = default_room_spawn_base(self, shape)
    if not opts.skip_spawn_cursor then
        base = SpawnCursor.next_slot(self, base, shape)
    end
    local inherited = opts.tags_override
    if not inherited and self.rooms and self.rooms[room_id] and self.rooms[room_id].tags then
        inherited = RoomRegistry.clone_tags(self.rooms[room_id].tags)
    end
    local R = RoomRegistry.create(room_id, tilemap_path, group, shape, base, { tags = inherited })
    Render.draw_room(self, R, shape)
    RoomRegistry.store(self, R)

    self.room_order_index = self.room_order_index or {}
    self.room_order = self.room_order or {}
    local cid = canon_id(room_id)
    if cid and not self.room_order_index[cid] then
        self.room_order[#self.room_order+1] = cid
        self.room_order_index[cid] = #self.room_order
    end
    log.debug("spawned %s  px=(%dx%d) cells=(%dx%d) nodes: fill=%d outline=%d doors=%d",
        room_id, shape.w_px, shape.h_px, shape.w_cells, shape.h_cells,
        #R.fill_nodes, #R.outline_nodes, #R.door_nodes)

    -- Record undo operation (unless loading from save)
    if not (opts and opts.skip_undo) then
        ControllerUndo.record_spawn(self, room_id, delete_room, spawn_room)
    end

    if not (opts and opts.defer_camera) then
        apply_camera(self)
    end
    return R
end

local function reload_existing_rooms(self)
    for id, old in pairs(self.rooms or {}) do
        local base = old.base_pos
        local tags = old.tags and RoomRegistry.clone_tags(old.tags) or nil
        Render.release_room_resources(old)
        UI.delete_safe(old.group)
        self.rooms[id] = nil
        local R = spawn_room(self, id, { skip_undo = true, skip_spawn_cursor = true, tags_override = tags, defer_camera = true })
        if R then
            R.base_pos = vmath.vector3(base)
            local cid = canon_id(id)
            if cid and self.selected_rooms and self.selected_rooms[cid] then
                self.selected_rooms[cid] = R
                R.selected = true
            end
            if cid and self.selected_room_id == cid then
                self.selected_room = R
                R.selected = true
            end
        end
    end
    apply_camera(self)
end

-- ============================================================================================================================================================
-- Popup Dialog Functions (defined before load_saved_layout which uses them)

local function show_popup(self, title, message)
    if not self.n_popup_overlay then return end

    -- Set text if provided
    if title and self.n_popup_title then
        gui.set_text(self.n_popup_title, title)
    end
    if message and self.n_popup_message then
        gui.set_text(self.n_popup_message, message)
    end

    -- Show all popup nodes
    gui.set_enabled(self.n_popup_overlay, true)
    gui.set_enabled(self.n_popup_box, true)
    gui.set_enabled(self.n_popup_title, true)
    gui.set_enabled(self.n_popup_message, true)
    gui.set_enabled(self.n_popup_ok_btn, true)
    gui.set_enabled(self.n_popup_ok_text, true)

    self.popup_visible = true
    log.info("Showing popup: %s", title or "Popup")
end

local function hide_popup(self)
    if not self.n_popup_overlay then return end

    gui.set_enabled(self.n_popup_overlay, false)
    gui.set_enabled(self.n_popup_box, false)
    gui.set_enabled(self.n_popup_title, false)
    gui.set_enabled(self.n_popup_message, false)
    gui.set_enabled(self.n_popup_ok_btn, false)
    gui.set_enabled(self.n_popup_ok_text, false)

    self.popup_visible = false
end

local function handle_popup_ok(self)
    hide_popup(self)
    -- Stay in layout editor so user can fix the missing starting room
    log.info("Popup dismissed - staying in layout editor to fix starting room")
end

-- Load a previously saved layout and respawn rooms at saved positions
local function load_saved_layout(self)
    local owner = require("developer.tools.world_layout").source({root=resolve_project_root() or "."})
    self.world_read_only = owner.owner == "tiled"
    local data = LayoutIO.load(self.world_read_only and {runtime_preferred=true,read_only=true} or nil)
    self.preserve_origin = data and data.preserve_origin
    if self.world_read_only then
        gui.set_text(UI.get_node_safe("txt_export"), "Edit Here")
        gui.set_text(UI.get_node_safe("txt_clear"), "Restore Draft")
    end
    local rooms = (data and data.rooms) or {}
    if type(rooms) ~= "table" or #rooms == 0 then
        log.debug("no saved layout found (or empty)")
        return
    end
    for _, rec in ipairs(rooms) do
        local rid = rec.id or (type(rec.path)=="string" and rec.path:match("developer/rooms/(.+)$")) or nil
        if rid then
            local R = self.rooms[rid] or spawn_room(self, rid, { skip_undo = true, skip_spawn_cursor = true, defer_camera = true })
            if R then
                local rx = tonumber(rec.x)
                local ry = tonumber(rec.y)
                if rx and ry then
                    -- LayoutIO only accepts current-format saves. Restore the
                    -- editor-facing base position from collection-root coords plus
                    -- the saved room-shape offset.
                    local ox = tonumber(rec.ox)
                    local oy = tonumber(rec.oy)
                    if not ox or not oy then
                        local tw = (R.shape and R.shape.tile_w) or 0
                        local th = (R.shape and R.shape.tile_h) or 0
                        local minx = (R.shape and R.shape.min_x) or 1
                        local miny = (R.shape and R.shape.min_y) or 1
                        ox = (minx - 1) * tw
                        oy = (miny - 1) * th
                    end
                    R.base_pos.x = rx + ox
                    R.base_pos.y = ry + oy
                end
                if rec.tags then
                    R.tags = RoomRegistry.clone_tags(rec.tags)
                else
                    R.tags = RoomRegistry.clone_tags(nil)
                end
                local current_cid = canon_id(rid)
                if current_cid and self.selected_room_id == current_cid then
                    self.selected_room = R
                    R.selected = true
                end
                -- ensure order matches saved
                local cid = canon_id(rid)
                if cid and not self.room_order_index[cid] then
                    self.room_order[#self.room_order+1] = cid
                    self.room_order_index[cid] = #self.room_order
                end
            end
        end
    end

    -- Prefer starting room, otherwise use first room in layout
    if TiledRegistry and TiledRegistry.refresh then
        pcall(TiledRegistry.refresh)
    end
    local starting_room_id = TiledRegistry.get_starting_room({ rooms = rooms })
    local spawn_room_id = starting_room_id

    if not spawn_room_id and type(rooms) == "table" and #rooms > 0 then
        local first = rooms[1]
        if type(first) == "table" then
            local from_path
            if type(first.path) == "string" then
                from_path = first.path:match("developer/rooms/(.+)$")
            end
            spawn_room_id = first.id or from_path
        end
    end

    if spawn_room_id then
        local R = self.rooms and self.rooms[spawn_room_id] or nil
        if not R then
            local canonical = canon_id(spawn_room_id)
            if canonical then
                R = select(1, find_room_by_canon(self, canonical))
            end
        end
        if R then
            align_view_on_room(self, R, "center")
            -- Auto-select the starting room
            if starting_room_id then
                set_selected_room(self, R)
            end
        end
    end

    apply_camera(self)
    UI.rebuild_rooms_sidebar(self)
    SpawnCursor.reset(self, 0)
    log.debug("loaded saved layout: %d rooms", #rooms)

    -- Check if starting room exists in layout, show warning popup if not
    if not starting_room_id then
        self.missing_starting_room = true
        log.warn("No starting room identified from Tiled export!")
        show_popup(self,
            "No Starting Room Defined",
            "Use Tiled to create a Starting Room.\nAdd 'is_starting_room' property or\na 'player_start' object to a room.")
    elseif starting_room_id then
        -- Allow canonical ID matching (e.g. "start_room" vs "developer/rooms/start_room").
        local has_start_room = self.rooms[starting_room_id] ~= nil
        if not has_start_room then
            local canonical = canon_id(starting_room_id)
            if canonical then
                local found = select(1, find_room_by_canon(self, canonical))
                has_start_room = (found ~= nil)
            end
        end

        if not has_start_room then
            -- Starting room exists in Tiled but not in layout
            self.missing_starting_room = true
            log.warn("Starting room '%s' not in layout!", starting_room_id)
            show_popup(self,
                "Starting Room Not In Layout",
                string.format("Starting room '%s' is not in\nthe layout. Add it from the sidebar\nor export from Tiled.", starting_room_id))
        else
            self.missing_starting_room = false
        end
    else
        self.missing_starting_room = false
    end
end

local function set_trash_highlight(self, active)
    if not self.n_trash or not self.trash_base_color or not self.trash_hover_color then return end
    if self.trash_highlight == active then return end
    local col = active and self.trash_hover_color or self.trash_base_color
    gui.set_color(self.n_trash, col)
    self.trash_highlight = active
end

delete_room = function(self, room_id, opts)
    opts = opts or {}
    if not self.rooms then return false end
    local target_id = room_id
    local R = self.rooms[target_id]
    if not R then
        local wanted = canon_id(room_id)
        for id, room in pairs(self.rooms) do
            if canon_id(id) == wanted then
                target_id = id
                R = room
                break
            end
        end
    end
    if not R then return false end

    -- Protect the starting room from deletion
    if TiledRegistry.is_starting_room(target_id) then
        log.warn("Cannot delete starting room: %s", target_id)
        print("[LAYOUT_EDITOR] Cannot delete the starting room. It must remain in the layout.")
        show_popup(self,
            "Starting Room Protected",
            "The Tiled starting room cannot be deleted\nfrom the layout. Assign a different\nstarting room in Tiled first.")
        return false
    end

    -- Capture state for undo (before deletion)
    if not opts.skip_undo then
        local saved_pos = vmath.vector3(R.base_pos)
        local saved_tags = R.tags and RoomRegistry.clone_tags(R.tags) or nil
        ControllerUndo.record_delete(self, target_id, saved_pos, saved_tags, spawn_room, delete_room, apply_camera)
    end

    Render.release_room_resources(R)
    UI.delete_safe(R.group)
    self.rooms[target_id] = nil

    local cid = canon_id(target_id)

    ControllerState.remove_deleted_room_from_selection(self, cid, target_id, logf)
    ControllerState.remove_room_from_order(self, cid)

    -- Validate state after deletion
    StateValidator.assert_no_stale_selections(self)

    return true
end

local function clear_all_manual_door_insets(self)
    return ControllerState.clear_all_manual_door_insets(self)
end

-- ============================================================================================================================================================
-- Zoom helper

local function zoom_step(self, factor, mouse_x, mouse_y)
    return Camera.zoom_step(self, factor, mouse_x, mouse_y)
end

-- ============================================================================================================================================================
-- Public API

local M = {}

function M.init(self)
    print('[LE.CTL] init start')
    -- Module state is shared between GUI instances; old callbacks refer to
    -- nodes and rooms belonging to the previous editor session.
    ControllerUndo.init()
    -- GUI node refs
    self.n_root       = UI.get_node_safe("root")
    self.n_btn_export = UI.get_node_safe("btn_export")
    self.n_btn_clear  = UI.get_node_safe("btn_clear")
    self.n_btn_rescan = UI.get_node_safe("btn_rescan")
    self.n_btn_menu   = UI.get_node_safe("btn_menu")
    self.n_btn_menu_label = UI.get_node_safe("btn_menu_label")
    self.n_button_container = UI.get_node_safe("button_container")
    self.n_room_list_container = UI.get_node_safe("room_list_container")
    self.n_room_list_clip = UI.get_node_safe("room_list_clip")
    self.n_lbl_rooms  = UI.get_node_safe("lbl_rooms")
    self.n_btn_zoom_in  = UI.get_node_safe("btn_zoom_in")
    self.n_btn_zoom_out = UI.get_node_safe("btn_zoom_out")
    self.n_trash      = UI.get_node_safe("trash_zone")
    self.n_trash_label = UI.get_node_safe("txt_trash")
    if self.n_trash then
        local base = gui.get_color(self.n_trash)
        self.trash_base_color = vmath.vector4(base.x, base.y, base.z, base.w)
        self.trash_hover_color = vmath.vector4(math.min(1, base.x + 0.25), math.min(1, base.y + 0.15), math.min(1, base.z + 0.15), math.min(1, base.w + 0.2))
        self.trash_highlight = false
    end

    -- Popup dialog nodes for "No Starting Room" warning
    self.n_popup_overlay = UI.get_node_safe("popup_overlay")
    self.n_popup_box = UI.get_node_safe("popup_box")
    self.n_popup_title = UI.get_node_safe("popup_title")
    self.n_popup_message = UI.get_node_safe("popup_message")
    self.n_popup_ok_btn = UI.get_node_safe("popup_ok_btn")
    self.n_popup_ok_text = UI.get_node_safe("popup_ok_text")
    self.popup_visible = false

    -- DEBUG: report button node availability
    log.debug("nodes: menu=%s clear=%s rescan=%s export=%s zoom_in=%s zoom_out=%s",
        tostring(self.n_btn_menu~=nil), tostring(self.n_btn_clear~=nil), tostring(self.n_btn_rescan~=nil),
        tostring(self.n_btn_export~=nil),
        tostring(self.n_btn_zoom_in~=nil), tostring(self.n_btn_zoom_out~=nil))

    if self.n_root then gui.set_alpha(self.n_root, 1) end
    if self.n_button_container then gui.set_alpha(self.n_button_container, 1) end
    UI.ensure_canvas_root(self)
    if UI.position_chrome then UI.position_chrome(self) end

    -- Capture button states and reset alpha to fully enabled
    self.button_states = {
        rescan = capture_button_state(self.n_btn_rescan, UI.get_node_safe("txt_scan")),
        export = capture_button_state(self.n_btn_export, UI.get_node_safe("txt_export")),
        clear  = capture_button_state(self.n_btn_clear, UI.get_node_safe("txt_clear")),
        menu   = capture_button_state(self.n_btn_menu, UI.get_node_safe("btn_menu_label")),
    }
    for _, st in pairs(self.button_states) do
        set_button_state(st, true)
    end

    UI.set_z(self.n_btn_export, 0.7)
    UI.set_z(self.n_btn_clear,  0.7)
    UI.set_z(self.n_btn_rescan, 0.7)
    UI.set_z(self.n_btn_menu,   0.7)
    UI.set_z(self.n_trash,      0.7)
    UI.set_z(self.n_room_list_container, 0.7)
    UI.set_z(self.n_lbl_rooms,  0.7)

    self.zoom  = S.canvas.zoom or 1.0
    self.pan   = vmath.vector3(0,0,0)
    self.rooms, self.sidebar_items, self.grid_nodes = {}, {}, {}
    self.room_order, self.room_order_index = {}, {}
    self.room_list_scroll_offset = 0  -- Tracks vertical scroll offset for room list
    self.selected_room_id = nil
    self.selected_room = nil
    self.selected_rooms = {}  -- Multi-selection: table of room_id -> room
    self.last_selected_room_id = nil  -- For Shift+click range selection
    self.mod_ctrl_down = false
    self.mod_shift_down = false
    self.tags_dirty = false
    SpawnCursor.reset(self, 0)

    SAVE_FILE = sys.get_save_file(S.app_id, S.layout_filename)
    log.debug("save file path: %s", tostring(SAVE_FILE))

    UI.compute_canvas_rect(self)
    msg.post(".", "acquire_input_focus")
    UI.rebuild_rooms_sidebar(self)
    apply_camera(self)
    -- Auto-load last saved layout
    load_saved_layout(self)
    ProgressionPanel.init(self,function() return resolve_project_root() or "." end,function()
        local ok,layout=save_layout(self,true)
        assert(ok,layout)
        return layout
    end)

    log.debug("init done. canvas=%dx%d  save_file=%s", self.canvas.w, self.canvas.h, SAVE_FILE)
end

function M.update(self, dt)
    ProgressionPanel.update(self)
    -- keep input focus (original behavior)
    msg.post(".", "acquire_input_focus")

    -- Resume export coroutine if running
    if self.export_coroutine then
        local ok, err = coroutine.resume(self.export_coroutine)
        if not ok then
            log.debug("[LE.EXPORT] Coroutine error: %s", tostring(err))
            print("[LE.EXPORT] Coroutine error: " .. tostring(err))
            end_export(self)
            self.export_coroutine = nil
            self.export_in_progress = false
        elseif coroutine.status(self.export_coroutine) == "dead" then
            -- Coroutine finished
            self.export_coroutine = nil
            -- Note: end_export will be called by the coroutine's finalize function
        end
    end

    -- Periodic state validation (every 5 seconds in debug mode)
    self.validation_timer = (self.validation_timer or 0) + dt
    if self.validation_timer > 5.0 then
        self.validation_timer = 0
        local valid, errors = StateValidator.validate_controller(self)
        if not valid then
            log.error("State validation failed:")
            for _, err in ipairs(errors) do
                log.error("  - %s", err)
            end
        end
    end

end

function M.on_message(self, msg_id, message, sender)
    if msg_id == hash("window_resized") then
        UI.compute_canvas_rect(self)
        ProgressionPanel.resize(self)
        if UI.position_chrome then UI.position_chrome(self) end
        apply_camera(self)
    elseif msg_id == MSG_MANIFEST_SAVED or msg_id == hash("rooms_refresh") or msg_id == MSG_UI_RESCAN then
        log.debug("manifest_saved =†' rebuild sidebar + reload visuals")
        -- Don't rebuild sidebar if we're in the middle of processing a sidebar click
        -- (it will be rebuilt by the click handler itself)
        if not self.sidebar_click_in_progress then
            UI.rebuild_rooms_sidebar(self)
        else
            log.debug("Skipping sidebar rebuild - click in progress")
        end
        -- DON'T reload existing rooms if we're in the middle of adding a room from sidebar
        -- (the room was just spawned, no need to reload it)
        if not self.sidebar_click_in_progress then
            reload_existing_rooms(self)
        else
            log.debug("Skipping reload_existing_rooms - click in progress")
        end
        apply_camera(self)
    end
end
function M.on_input(self, action_id, action)
    if not self.world_read_only and not self.export_in_progress and ProgressionPanel.on_input(self,action_id,action) then return true end
    if self.relationship_error_visible and action and action.pressed then
        self.relationship_error_visible = false
        hide_export_overlay(self)
        return true
    end
    return ControllerInput.on_input(self, action_id, action, {
        take_manual = function()
            local root=resolve_project_root() or "."
            local previous=LayoutIO.load({read_only=true})
            require("developer.tools.world_layout").take_manual({root=root},previous)
            self.world_read_only=false
            gui.set_text(UI.get_node_safe("txt_export"),"Layout Export")
            gui.set_text(UI.get_node_safe("txt_clear"),"Clear")
            local ok,err=save_layout(self);assert(ok,err)
            show_popup(self,"Manual layout saved",
                "To add rooms outside the Tiled world: stop the game, run Prepare & Check, then Build. Reopen Layout Editor and Rescan Rooms.")
        end,
        restore_manual = function()
            local root=resolve_project_root() or "."
            local previous=require("developer.tools.preparation").load({root=root},"runtime/layout/manual_backup.lua")
            if not previous then
                local saved=LayoutIO.load({read_only=true})
                if not (saved.source and saved.source.kind=="tiled") then previous=saved end
            end
            if not previous or not previous.rooms or #previous.rooms==0 then
                show_popup(self,"Restore Draft","No saved manual draft is available. Edit Here takes a copy of this world.")
                return
            end
            assert(LayoutIO.save(previous),"Could not restore the manual draft")
            require("developer.tools.world_layout").take_manual({root=root})
            self.world_read_only=false
            clear_all_selections(self)
            ControllerUndo.init()
            for _,room in pairs(self.rooms) do Render.release_room_resources(room);UI.delete_safe(room.group) end
            self.rooms={};self.room_order={};self.room_order_index={}
            load_saved_layout(self)
            gui.set_text(UI.get_node_safe("txt_export"),"Layout Export")
            gui.set_text(UI.get_node_safe("txt_clear"),"Clear")
            local ok,err=save_layout(self);assert(ok,err)
            apply_camera(self)
            show_popup(self,"Manual draft restored",
                "To add rooms outside the Tiled world: stop the game, run Prepare & Check, then Build. Reopen Layout Editor and Rescan Rooms.")
        end,
        logf = logf,
        handle_popup_ok = handle_popup_ok,
        room_list_scroll_metrics = room_list_scroll_metrics,
        zoom_step = zoom_step,
        export_minimap_direct = export_minimap_direct,
        return_to_menu = return_to_menu,
        clear_all_selections = clear_all_selections,
        save_layout = save_layout,
        spawn_room = spawn_room,
        apply_camera = apply_camera,
        canon_id = canon_id,
        set_selected_room = set_selected_room,
        find_room_by_canon = find_room_by_canon,
        clear_all_manual_door_insets = clear_all_manual_door_insets,
        disable_keep_all_loaded = disable_keep_all_loaded,
        promote_room_order = promote_room_order,
        set_trash_highlight = set_trash_highlight,
        delete_room = delete_room,
        restore_keep_all_loaded = restore_keep_all_loaded,
        try_snap_to_doors_simple = try_snap_to_doors_simple,
    })
end

return M
