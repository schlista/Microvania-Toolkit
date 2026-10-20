-- developer/config/map_markers.lua
-- Static map markers to seed the minimap/world map.
--
-- Add per-room marker tables here, keyed by room id. Each entry is a table
-- with world-space coordinates and an optional label/flags.
--
-- Example:
--   micro_desert3 = {
--       { x = 1024, y = 512, label = "Save" },
--       { x = 2048, y = 256, label = "Chest", show_on_world_map = true },
--   },
--
-- Supported per-marker fields:
--   x, y                  - world-space coordinates (required)
--   label                 - text shown in tooltips / world map
--   show_on_world_map     - default false
--   visible_from_start    - default true (config markers reveal at boot)
--   discovery_radius      - radius in pixels at which the player auto-discovers it

return {}
