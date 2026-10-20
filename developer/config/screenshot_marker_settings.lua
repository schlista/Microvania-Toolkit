-- developer/config/screenshot_marker_settings.lua
-- Configuration for the screenshot map marker system
--
-- This feature allows players to capture screenshots of the game world
-- and pin them to locations on the map for later reference.
-- (Similar to Prince of Persia: The Lost Crown and Biomorph)

return {
    -- Maximum number of screenshot markers the player can have
    -- Oldest marker is auto-removed when limit is reached
    max_markers = 10,

    -- Marker appearance on minimap/world map
    marker_size = 12,  -- Pixels
    marker_color = vmath.vector4(1.0, 0.8, 0.2, 0.95),  -- Gold/yellow
    marker_shape = "camera",  -- "camera", "square", "circle", "diamond"

    -- Thumbnail settings
    thumbnail_size = 128,  -- Resolution of captured thumbnails (square)

    -- Display settings
    show_on_minimap = false,    -- Don't show markers on minimap (too cluttered)
    show_on_world_map = true,   -- Show markers on the world map only

    -- Capture settings
    capture_delay = 0.1,        -- Seconds to wait before capture (allows UI to hide)
    flash_on_capture = true,    -- White flash effect when capturing
    sound_on_capture = "ui_screenshot",  -- Sound effect ID (set to nil to disable)

    -- Preview settings (when hovering over a marker)
    preview_size = 160,         -- Size of the thumbnail preview popup
    preview_offset_x = 20,      -- X offset from cursor
    preview_offset_y = 20,      -- Y offset from cursor

    -- Label settings
    allow_custom_labels = true,  -- Allow players to add text labels to markers
    max_label_length = 32,       -- Maximum characters in a label
}
