-- developer/config/world_map_settings.lua
-- Tuning for world map GUI colors, fog behavior, and label offsets

local v4 = vmath and vmath.vector4 or function(r,g,b,a) return { x=r, y=g, z=b, w=a } end

local M = {
  enabled = true, -- Allow opening the world map (including its fast-travel view).
  fit_mode = "contain",  -- keep whole map visible
  margin_px = 0,
  scale_multiplier = 0.3, -- original zoom level
  max_screen_fraction = { w = 1.0, h = 1.0 }, -- allow full screen usage
  min_scale = 0.2,
  show_border = false,  -- no border frame
  show_title = false,   -- no title text
  show_legend = false,  -- no legend/hints text
  colors = {
    bg      = v4(0.00, 0.00, 0.00, 1.0),  -- solid black background
    frame   = v4(0.80, 0.93, 0.99, 0.35),
    outline = v4(0.80, 0.93, 0.99, 1.00),
    unexplored = v4(0.60, 0.60, 0.70, 0.35),
    icon_bench = v4(1.00, 0.92, 0.20, 0.95),
    icon_boss  = v4(0.95, 0.30, 0.30, 0.95),
    icon_custom= v4(0.70, 0.40, 0.95, 0.95),
  },
  fog = {
    darken = 0.65,  -- multiply biome RGB by this for fog color
    alpha  = 0.28,  -- fog opacity
  },
  labels = {
    poi_offset = { x = 10, y = 6 },  -- offset from icon center
  },
  player_offset_px = { x = 0, y = 8 },
}

return M
