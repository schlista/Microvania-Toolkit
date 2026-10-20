-- Fog of war shared by the panel minimap and full world map.
local Tile = require "developer.config.tile_settings"
return {
    enabled = true,           -- False displays the whole map (progress still records).
    -- Every mode reveals the camera's visible area in ready, enabled rooms.
    mode = "nearby",         -- "nearby" adds the radius below; "room" reveals the whole room on entry.
    cell_size = (Tile.width or 128) * 2, -- World pixels per discovery cell; saved with the slot.
    reveal_radius = (Tile.width or 128) * 4, -- Extra world-pixel radius around the player, in addition to the visible screen.
    -- World-pixel radius of rounded, feathered edges on both maps; 0 keeps hard edges.
    -- Visual only: changing this does not change saved discovery or marker visibility.
    edge_softness = (Tile.width or 128),
    -- Maximum fog-texture side; 512 keeps soft-mask rebuilds light.
    -- Increase for finer detail on very large maps. Rebuilt only on discovery/bounds changes.
    texture_max_size = 512,
    -- Seconds between fog-texture rebuilds while exploring reveals new cells.
    -- 0 rebuilds on every change. Visual only: saved discovery is unaffected.
    rebuild_interval = 0.25,
}
