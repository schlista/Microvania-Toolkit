-- mvtk/map/screenshot_markers.lua
-- Screenshot-to-map marker system
-- Allows players to capture screenshots and pin them to locations on the map
--
-- Features:
--   - Capture current game view as a marker
--   - Store screenshots with position and room metadata
--   - Display markers on minimap and world map
--   - Hover/click to view screenshot thumbnail
--   - Persistence via checkpoint system
--   - Configurable marker limit

local C = require "mvtk.core.constants"
local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

-- Configuration defaults (can be overridden by developer/config/screenshot_marker_settings.lua)
local CONFIG = {
    max_markers = 10,           -- Maximum number of screenshot markers
    marker_size = 12,           -- Marker size in pixels on minimap
    marker_color = vmath.vector4(1.0, 0.8, 0.2, 0.95),  -- Gold/yellow
    marker_shape = "camera",    -- "camera", "square", "circle", "diamond"
    thumbnail_size = 128,       -- Thumbnail resolution (square)
    show_on_minimap = true,     -- Show markers on minimap
    show_on_world_map = true,   -- Show markers on world map
    capture_delay = 0.1,        -- Delay before capture (to hide UI)
    flash_on_capture = true,    -- Screen flash effect on capture
    sound_on_capture = "ui_screenshot",  -- Sound effect ID
}

-- Load custom configuration
local function load_config()
    local ok, custom = pcall(require, "developer.config.screenshot_marker_settings")
    if ok and type(custom) == "table" then
        custom=require("developer.config.runtime_settings").section("screenshot_markers",custom)
        for k, v in pairs(custom) do
            CONFIG[k] = v
        end
        print(string.format("[SCREENSHOT_MARKERS] Loaded config: max=%d markers", CONFIG.max_markers))
    end
end

load_config()

-- Internal state
local markers = {}  -- Array of marker data
local next_id = 1   -- Auto-incrementing ID
local capture_pending = false
local capture_callback = nil
local current_slot = nil  -- Track which slot markers belong to

local ss_log = Util.make_debug_log("[SCREENSHOT_MARKERS]", function()
    return (Debug.minimap and Debug.minimap.markers) or (Debug.global and Debug.global.enable)
end)

-----------------------------------------------------------
-- Marker Data Structure
-----------------------------------------------------------
-- Each marker contains:
-- {
--     id = number,              -- Unique marker ID
--     pos = vector3,            -- World position
--     room_id = string,         -- Room where marker was placed
--     timestamp = number,       -- Unix timestamp when created
--     label = string,           -- Optional user label
--     screenshot_path = string, -- Path to saved screenshot (or nil if using buffer)
--     screenshot_data = string, -- Base64 encoded screenshot data (for save/load)
-- }

-----------------------------------------------------------
-- Screenshot Capture
-----------------------------------------------------------

-- Request a screenshot capture at the current player position
-- @param player_pos: vector3 - Player's world position
-- @param room_id: string - Current room ID
-- @param label: string (optional) - User label for the marker
-- @param callback: function (optional) - Called when capture completes
function M.capture(player_pos, room_id, label, callback)
    if capture_pending then
        ss_log("[SCREENSHOT_MARKERS] Capture already pending, ignoring request")
        return false
    end

    -- Check marker limit - user must manually delete markers from world map
    if #markers >= CONFIG.max_markers then
        ss_log("[SCREENSHOT_MARKERS] Marker limit reached (" .. CONFIG.max_markers .. "). Delete markers from world map to make room.")
        return false, "limit_reached"
    end

    capture_pending = true
    capture_callback = callback

    -- Create marker data (screenshot will be added after capture)
    local marker = {
        id = next_id,
        pos = vmath.vector3(player_pos),
        room_id = room_id or "unknown",
        timestamp = os.time(),
        label = label or "",
        screenshot_path = nil,
        screenshot_data = nil,
    }

    next_id = next_id + 1

    -- Delay capture slightly to allow UI to hide
    timer.delay(CONFIG.capture_delay, false, function()
        M._do_capture(marker)
    end)

    return true
end

-- Base64 encoding for screenshot data (simple implementation)
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_encode(data)
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
        return b64chars:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- Base64 decoding
local b64lookup = {}
for i = 1, #b64chars do
    b64lookup[b64chars:sub(i, i)] = i - 1
end

local function base64_decode(data)
    if not data then return nil end
    -- Remove padding and whitespace
    data = data:gsub('[^' .. b64chars .. '=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local v = b64lookup[x]
        if not v then return '' end
        local r = ''
        for i = 6, 1, -1 do
            r = r .. (v % 2^i - v % 2^(i-1) > 0 and '1' or '0')
        end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do
            c = c + (x:sub(i, i) == '1' and 2^(8-i) or 0)
        end
        return string.char(c)
    end))
end

-- Internal: Perform the actual screenshot capture using defold-screenshot extension
function M._do_capture(marker)
    -- Try to use the screenshot extension
    local screenshot_ok, screenshot = pcall(require, "screenshot")
    if not screenshot_ok then
        -- Extension not available, create marker without screenshot
        ss_log("[SCREENSHOT_MARKERS] Screenshot extension not available, creating marker without thumbnail")
        marker.screenshot_data = nil
        M._finish_capture(marker)
        return
    end

    -- Capture the screen as PNG
    local capture_ok, png_data = pcall(screenshot.png)
    if capture_ok and png_data and type(png_data) == "string" and #png_data > 0 then
        -- Encode as base64 for JSON serialization
        marker.screenshot_data = base64_encode(png_data)
        ss_log(string.format("[SCREENSHOT_MARKERS] Captured screenshot: raw=%d bytes, base64=%d chars",
            #png_data, #marker.screenshot_data))
        -- Verify PNG header (should start with PNG signature)
        local header = png_data:sub(1, 8)
        local is_png = header:byte(1) == 0x89 and header:byte(2) == 0x50 and header:byte(3) == 0x4E and header:byte(4) == 0x47
        ss_log(string.format("[SCREENSHOT_MARKERS] PNG validation: %s (header bytes: %02X %02X %02X %02X)",
            is_png and "valid" or "INVALID", header:byte(1) or 0, header:byte(2) or 0, header:byte(3) or 0, header:byte(4) or 0))
    else
        ss_log(string.format("[SCREENSHOT_MARKERS] Screenshot capture failed: ok=%s, type=%s, len=%s",
            tostring(capture_ok), type(png_data), png_data and #png_data or "nil"))
        marker.screenshot_data = nil
    end

    M._finish_capture(marker)
end

-- Called by render script when screenshot is ready
-- @param marker_id: number - ID of the marker being captured
-- @param image_data: string - Base64 encoded PNG data (or nil if failed)
function M.on_screenshot_ready(marker_id, image_data)
    -- Find the pending marker
    local marker = nil
    for _, m in ipairs(markers) do
        if m.id == marker_id then
            marker = m
            break
        end
    end

    -- If marker wasn't added yet (capture in progress), it's in the callback closure
    if not marker then
        -- The marker is created in _do_capture and passed to _finish_capture
        ss_log("[SCREENSHOT_MARKERS] Screenshot ready for marker " .. marker_id)
        return
    end

    marker.screenshot_data = image_data
    ss_log("[SCREENSHOT_MARKERS] Screenshot data attached to marker " .. marker_id)
end

-- Finish capture and add marker to list
function M._finish_capture(marker)
    table.insert(markers, marker)
    capture_pending = false

    ss_log(string.format("[SCREENSHOT_MARKERS] Created marker #%d at (%.0f, %.0f) in room '%s' - Total markers: %d",
        marker.id, marker.pos.x, marker.pos.y, marker.room_id, #markers))

    -- Play capture sound
    if CONFIG.sound_on_capture then
        local ok, Audio = pcall(require, "mvtk.audio.audio")
        if ok and Audio and Audio.sfx then
            pcall(Audio.sfx, CONFIG.sound_on_capture)
        end
    end

    -- Flash effect
    if CONFIG.flash_on_capture then
        pcall(function()
            msg.post(C.url("FADE_GUI") or msg.url("main:/ui#fade"), "flash", { duration = 0.15 })
        end)
    end

    -- Notify callback
    if capture_callback then
        capture_callback(marker)
        capture_callback = nil
    end

    -- Notify UI to refresh
    M._notify_update()

    -- Autosave immediately so markers persist even if game crashes or user quits without saving
    local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if ok_cp and Checkpoint and Checkpoint.autosave then
        pcall(Checkpoint.autosave, "screenshot_marker_placed")
    end
end

-----------------------------------------------------------
-- Marker Management
-----------------------------------------------------------

-- Get all markers
function M.get_all()
    return markers
end

-- Get markers for a specific room
function M.get_for_room(room_id)
    local result = {}
    for _, m in ipairs(markers) do
        if m.room_id == room_id then
            table.insert(result, m)
        end
    end
    return result
end

-- Get marker by ID
function M.get_marker(id)
    for _, m in ipairs(markers) do
        if m.id == id then
            return m
        end
    end
    return nil
end

-- Remove a marker by ID
function M.remove_marker(id)
    for i, m in ipairs(markers) do
        if m.id == id then
            table.remove(markers, i)
            ss_log("[SCREENSHOT_MARKERS] Removed marker #" .. id)
            M._notify_update()
            -- Autosave after removing a marker
            local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
            if ok_cp and Checkpoint and Checkpoint.autosave then
                pcall(Checkpoint.autosave, "screenshot_marker_removed")
            end
            return true
        end
    end
    return false
end

-- Update marker label
function M.set_label(id, label)
    local marker = M.get_marker(id)
    if marker then
        marker.label = label or ""
        ss_log("[SCREENSHOT_MARKERS] Updated label for marker #" .. id)
        -- Autosave after label change
        local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
        if ok_cp and Checkpoint and Checkpoint.autosave then
            pcall(Checkpoint.autosave, "screenshot_marker_label_changed")
        end
        return true
    end
    return false
end

-- Clear all markers
function M.clear_all()
    markers = {}
    ss_log("[SCREENSHOT_MARKERS] Cleared all markers")
    M._notify_update()
    -- Autosave after clearing all markers
    local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if ok_cp and Checkpoint and Checkpoint.autosave then
        pcall(Checkpoint.autosave, "screenshot_markers_cleared")
    end
end

-- Get marker count
function M.count()
    return #markers
end

-- Get max markers allowed
function M.max_count()
    return CONFIG.max_markers
end

-----------------------------------------------------------
-- Configuration Access
-----------------------------------------------------------

function M.get_config()
    return CONFIG
end

function M.get_marker_size()
    return CONFIG.marker_size
end

function M.get_marker_color()
    return CONFIG.marker_color
end

-- Decode screenshot data from base64 to raw PNG bytes
function M.decode_screenshot(marker_or_data)
    local data = marker_or_data
    if type(marker_or_data) == "table" then
        data = marker_or_data.screenshot_data
    end
    if not data or type(data) ~= "string" or #data == 0 then
        return nil
    end
    return base64_decode(data)
end

-----------------------------------------------------------
-- Persistence (Checkpoint Integration)
-----------------------------------------------------------

-- Capture state for saving
function M.capture_state()
    local state = {
        markers = {},
        next_id = next_id,
    }

    for _, m in ipairs(markers) do
        table.insert(state.markers, {
            id = tostring(m.id),  -- Persist marker identity as text; runtime ids remain numeric.
            pos = { x = m.pos.x, y = m.pos.y },
            room_id = m.room_id,
            timestamp = m.timestamp,
            label = m.label,
            screenshot_data = m.screenshot_data,  -- Base64 encoded
        })
    end

    return state
end

-- Apply saved state
function M.apply_state(state, ctx)
    -- Track which slot this data belongs to
    local slot = ctx and ctx.slot or nil
    if slot then
        current_slot = slot
    end
    
    if not state then 
        -- No data means reset
        M.reset()
        return 
    end

    markers = {}
    next_id = state.next_id or 1

    if state.markers then
        for _, saved in ipairs(state.markers) do
            local marker = {
                id = tonumber(saved.id),
                pos = vmath.vector3(saved.pos.x, saved.pos.y, 0),
                room_id = saved.room_id,
                timestamp = saved.timestamp,
                label = saved.label or "",
                screenshot_data = saved.screenshot_data,
            }
            table.insert(markers, marker)
        end
    end

    ss_log(string.format("[SCREENSHOT_MARKERS] Loaded %d markers from save (slot %s)", #markers, tostring(slot)))
    M._notify_update()
end

-- Reset to initial state
function M.reset()
    markers = {}
    next_id = 1
    capture_pending = false
    capture_callback = nil
    current_slot = nil
    ss_log("[SCREENSHOT_MARKERS] Reset to initial state")
end

-- Validate that markers belong to current slot, reset if not
function M.validate_slot()
    local ok, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok or not Checkpoint then return end
    
    local active_slot = Checkpoint.slot
    if active_slot and current_slot and active_slot ~= current_slot then
        ss_log(string.format("[SCREENSHOT_MARKERS] Slot mismatch! Have slot %s data but active slot is %s - resetting", 
            tostring(current_slot), tostring(active_slot)))
        M.reset()
        -- Re-apply from checkpoint data for current slot
        if Checkpoint.data and Checkpoint.data.modules and Checkpoint.data.modules.screenshot_markers then
            local payload = Checkpoint.data.modules.screenshot_markers
            if payload and payload.data then
                M.apply_state(payload.data, { slot = active_slot })
            end
        end
    end
end

-----------------------------------------------------------
-- UI Notifications
-----------------------------------------------------------

function M._notify_update()
    -- Notify minimap to refresh markers
    pcall(function()
        msg.post(msg.url("main:/minimap_gui#minimap"), "refresh_screenshot_markers", {})
    end)
    -- Notify world map to refresh markers
    pcall(function()
        msg.post(msg.url("main:/world_map_gui#world_map"), "refresh_screenshot_markers", {})
    end)
end

-----------------------------------------------------------
-- Checkpoint Provider Registration
-----------------------------------------------------------

-- Register with checkpoint system for automatic save/load
local function register_checkpoint_provider()
    local ok, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if ok and Checkpoint and Checkpoint.register_provider then
        Checkpoint.register_provider("screenshot_markers", {
            order = 50,  -- After core systems, before UI
            capture = function()
                return M.capture_state()
            end,
            apply = function(data, ctx)
                ss_log("[SCREENSHOT_MARKERS] apply() called with data: " .. tostring(data and #(data.markers or {}) or "nil") .. " for slot " .. tostring(ctx and ctx.slot))
                M.apply_state(data, ctx)
            end,
            defaults = function(ctx)
                -- Reset to empty state when starting a new game or loading empty slot
                ss_log("[SCREENSHOT_MARKERS] defaults() called for slot " .. tostring(ctx and ctx.slot) .. " - resetting markers")
                M.reset()
                if ctx and ctx.slot then
                    current_slot = ctx.slot
                end
            end,
        })
        ss_log("[SCREENSHOT_MARKERS] Registered with checkpoint system")
        
        -- Validate slot on registration (in case module was cached from different slot)
        M.validate_slot()
    end
end

register_checkpoint_provider()

return M
