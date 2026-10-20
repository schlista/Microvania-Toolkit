local Viewport = require "mvtk.ui.viewport"
-- mvtk/ui/minimap/screenshot_marker_renderer.lua
-- Renders screenshot markers on the minimap and world map
--
-- Creates visual nodes for each screenshot marker with:
-- - Camera icon or colored marker
-- - Hover detection for thumbnail preview
-- - Selection highlight

local ScreenshotMarkers = require "mvtk.map.screenshot_markers"
local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

-- Marker node pool
local marker_nodes = {}  -- Array of { box = node, icon = node, marker_id = id }
local preview_node = nil  -- Thumbnail preview node (created on demand)
local preview_visible = false
local hovered_marker_id = nil

local function ss_render_log(...)
    if (Debug.minimap and Debug.minimap.markers) or (Debug.global and Debug.global.enable) then
        print(...)
    end
end

-----------------------------------------------------------
-- Node Creation
-----------------------------------------------------------

-- Create a marker node for the minimap
-- @param parent: Parent GUI node (optional, for parenting)
-- @return { box = node, marker_id = nil }
local function create_marker_node()
    local config = ScreenshotMarkers.get_config()
    local size = config.marker_size or 12
    local color = config.marker_color or vmath.vector4(1, 0.8, 0.2, 0.95)

    -- Create box node for the marker
    local box = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(size, size, 0))
    gui.set_color(box, color)
    gui.set_pivot(box, gui.PIVOT_CENTER)
    gui.set_visible(box, false)

    -- Create inner icon (camera shape approximation using smaller box)
    local icon_size = size * 0.6
    local icon = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(icon_size, icon_size * 0.7, 0))
    gui.set_color(icon, vmath.vector4(0, 0, 0, 0.8))
    gui.set_pivot(icon, gui.PIVOT_CENTER)
    gui.set_parent(icon, box)
    gui.set_visible(icon, true)

    return {
        box = box,
        icon = icon,
        marker_id = nil,
    }
end

-- Ensure we have enough marker nodes for all markers
local function ensure_node_pool(count)
    while #marker_nodes < count do
        local node = create_marker_node()
        table.insert(marker_nodes, node)
    end
end

-----------------------------------------------------------
-- Thumbnail Preview
-----------------------------------------------------------

-- Create the thumbnail preview node (larger, shows screenshot)
local function create_preview_node()
    if preview_node then return end

    local config = ScreenshotMarkers.get_config()
    local size = config.thumbnail_size or 128

    -- Background box
    preview_node = gui.new_box_node(vmath.vector3(0, 0, 0), vmath.vector3(size + 8, size + 8, 0))
    gui.set_color(preview_node, vmath.vector4(0.1, 0.1, 0.12, 0.95))
    gui.set_pivot(preview_node, gui.PIVOT_SW)  -- Anchor to bottom-left so it appears above/right of cursor
    gui.set_visible(preview_node, false)

    -- Note: Actual screenshot texture would be applied here if we have image data
    -- For now, this is a temporary box that shows marker info

    ss_render_log("[SCREENSHOT_RENDERER] Created preview node")
end

-- Show thumbnail preview for a marker at a raw window-pixel position.
function M.show_preview(marker_id, screen_x, screen_y)
    if not preview_node then
        create_preview_node()
    end

    local marker = ScreenshotMarkers.get_marker(marker_id)
    if not marker then return end

    -- Convert raw screen pixels to the GUI design grid, then keep the preview
    -- inside the picture even when its marker is at the top/right edge.
    local x, y = Viewport.to_design(screen_x, screen_y)
    if not x then return end
    hovered_marker_id = marker_id
    preview_visible = true
    local w, h = Viewport.design_size()
    local size = gui.get_size(preview_node)
    x = math.max(0, math.min(x + 20, w - size.x))
    y = math.max(0, math.min(y + 20, h - size.y))
    gui.set_position(preview_node, vmath.vector3(x, y, 0))
    gui.set_visible(preview_node, true)

    -- TODO: Screenshot thumbnail rendering
    -- To implement actual screenshot thumbnails:
    -- 1. marker.screenshot_data would contain base64-encoded PNG/JPG
    -- 2. Use Defold's resource.create_texture() to create a dynamic texture
    -- 3. Set the texture on preview_node via gui.set_texture()
    -- 4. Handle cleanup when hiding preview to avoid texture leaks
    -- For now, the box indicates a marker exists without the visual overhead

    ss_render_log("[SCREENSHOT_RENDERER] Showing preview for marker #" .. marker_id)
end

-- Hide thumbnail preview
function M.hide_preview()
    if preview_node then
        gui.set_visible(preview_node, false)
    end
    preview_visible = false
    hovered_marker_id = nil
end

-----------------------------------------------------------
-- Rendering
-----------------------------------------------------------

-- Update marker positions on the minimap
-- @param world_to_minimap: function(world_pos) -> minimap_pos
-- @param visible_room_ids: table of room IDs currently visible on minimap (optional)
function M.update_minimap(world_to_minimap, visible_room_ids)
    local all_markers = ScreenshotMarkers.get_all()
    local config = ScreenshotMarkers.get_config()

    if not config.show_on_minimap then
        -- Hide all markers
        for _, node_data in ipairs(marker_nodes) do
            gui.set_visible(node_data.box, false)
        end
        return
    end

    ensure_node_pool(#all_markers)

    local visible_count = 0

    for i, marker in ipairs(all_markers) do
        local node_data = marker_nodes[i]

        -- Check if marker's room is visible (if filter provided)
        local room_visible = true
        if visible_room_ids then
            room_visible = visible_room_ids[marker.room_id] == true
        end

        if room_visible then
            visible_count = visible_count + 1

            -- Convert world position to minimap position
            local minimap_pos = world_to_minimap(marker.pos)

            if minimap_pos then
                gui.set_position(node_data.box, minimap_pos)
                gui.set_visible(node_data.box, true)
                node_data.marker_id = marker.id
            else
                gui.set_visible(node_data.box, false)
            end
        else
            gui.set_visible(node_data.box, false)
        end
    end

    -- Hide unused nodes
    for i = #all_markers + 1, #marker_nodes do
        gui.set_visible(marker_nodes[i].box, false)
        marker_nodes[i].marker_id = nil
    end
end

-- Update marker positions on the world map
-- @param world_to_map: function(world_pos) -> map_screen_pos
-- @param explored_rooms: table of room_id -> true for explored rooms (optional)
function M.update_world_map(world_to_map, explored_rooms)
    local all_markers = ScreenshotMarkers.get_all()
    local config = ScreenshotMarkers.get_config()

    if not config.show_on_world_map then
        for _, node_data in ipairs(marker_nodes) do
            gui.set_visible(node_data.box, false)
        end
        return
    end

    ensure_node_pool(#all_markers)

    for i, marker in ipairs(all_markers) do
        local node_data = marker_nodes[i]

        -- Only show markers in explored rooms (if filter provided)
        local room_explored = true
        if explored_rooms then
            room_explored = explored_rooms[marker.room_id] == true
        end

        if room_explored then
            local map_pos = world_to_map(marker.pos)

            if map_pos then
                gui.set_position(node_data.box, map_pos)
                gui.set_visible(node_data.box, true)
                node_data.marker_id = marker.id
            else
                gui.set_visible(node_data.box, false)
            end
        else
            gui.set_visible(node_data.box, false)
        end
    end

    -- Hide unused nodes
    for i = #all_markers + 1, #marker_nodes do
        gui.set_visible(marker_nodes[i].box, false)
        marker_nodes[i].marker_id = nil
    end
end

-----------------------------------------------------------
-- Input Handling
-----------------------------------------------------------

-- Check if a screen position hits any marker
-- @param x, y: Screen coordinates
-- @return marker_id or nil
function M.pick_marker(x, y)
    for _, node_data in ipairs(marker_nodes) do
        if node_data.marker_id and gui.is_visible(node_data.box) then
            if gui.pick_node(node_data.box, x, y) then
                return node_data.marker_id
            end
        end
    end
    return nil
end

-- Handle hover (call from GUI update)
function M.on_hover(x, y)
    local marker_id = M.pick_marker(x, y)

    if marker_id then
        if marker_id ~= hovered_marker_id then
            -- x/y are Defold pick coordinates. Anchor the preview to the
            -- marker's actual screen position rather than mixing spaces.
            for _, data in ipairs(marker_nodes) do
                if data.marker_id == marker_id then
                    local pos = gui.get_screen_position(data.box)
                    M.show_preview(marker_id, pos.x, pos.y)
                    break
                end
            end
        end
    elseif hovered_marker_id then
        M.hide_preview()
    end
end

-- Handle click (for selecting/deleting markers)
-- @return marker_id if a marker was clicked, nil otherwise
function M.on_click(x, y)
    return M.pick_marker(x, y)
end

-----------------------------------------------------------
-- Cleanup
-----------------------------------------------------------

function M.cleanup()
    -- Delete all created nodes
    for _, node_data in ipairs(marker_nodes) do
        if node_data.box then
            gui.delete_node(node_data.box)
        end
    end
    marker_nodes = {}

    if preview_node then
        gui.delete_node(preview_node)
        preview_node = nil
    end

    preview_visible = false
    hovered_marker_id = nil

    ss_render_log("[SCREENSHOT_RENDERER] Cleaned up all nodes")
end

-----------------------------------------------------------
-- State Queries
-----------------------------------------------------------

function M.get_hovered_marker()
    return hovered_marker_id
end

function M.is_preview_visible()
    return preview_visible
end

function M.get_marker_count()
    return ScreenshotMarkers.count()
end

return M
