-- mvtk/map/minimap/fast_travel_markers.lua
-- Minimap integration for showing fast travel points
-- Shows fast travel stations with different colors based on locked/unlocked state

local FastTravel = require "mvtk.core.fast_travel"
local Time = require "mvtk.core.time"
local Util = require "mvtk.core.util"
local Debug = Util.require_config("developer.config.debug_config")

local M = {}

-- Color scheme for fast travel markers
M.COLORS = {
  LOCKED = vmath.vector4(0.5, 0.5, 0.5, 0.7),      -- Gray - not discovered yet
  UNLOCKED = vmath.vector4(0.2, 0.6, 1.0, 0.9),    -- Blue - unlocked
  SELECTED = vmath.vector4(0.4, 0.8, 1.0, 1.0),    -- Bright blue - currently selected
  CURRENT = vmath.vector4(1.0, 1.0, 0.3, 0.9),     -- Yellow - player's current location
}

-- Fast travel marker visual settings
M.MARKER_SIZE = 10  -- Pixels
M.MARKER_SHAPE = "diamond"  -- "square", "circle", "diamond"
M.SHOW_LOCKED = false  -- Hide markers for locked/undiscovered stations
M.PULSE_UNLOCKED = true  -- Pulse animation for unlocked stations
M.PULSE_SELECTED = true  -- Pulse animation for selected station

local selected_station_id = nil
local current_station_id = nil

local ft_log = Util.make_debug_log("[FT_MARKERS]", function()
  return (Debug.minimap and Debug.minimap.markers) or (Debug.global and Debug.global.enable)
end)

-----------------------------------------------------------
-- Selection Management
-----------------------------------------------------------

function M.set_selected(station_id)
  selected_station_id = station_id
  ft_log(string.format("[FT_MARKERS] Selected: %s", tostring(station_id)))
end

function M.get_selected()
  return selected_station_id
end

function M.set_current(station_id)
  current_station_id = station_id
  ft_log(string.format("[FT_MARKERS] Current location: %s", tostring(station_id)))
end

function M.get_current()
  return current_station_id
end

-- Get next unlocked station (for dpad cycling)
function M.get_next_unlocked(current_id)
  local unlocked_ids = FastTravel.get_unlocked_ids()
  if #unlocked_ids == 0 then
    return nil
  end

  if not current_id then
    return unlocked_ids[1]
  end

  -- Find current index
  local current_index = nil
  for i, id in ipairs(unlocked_ids) do
    if id == current_id then
      current_index = i
      break
    end
  end

  if not current_index then
    return unlocked_ids[1]
  end

  -- Return next (wrap around)
  local next_index = (current_index % #unlocked_ids) + 1
  return unlocked_ids[next_index]
end

-- Get previous unlocked station (for dpad cycling)
function M.get_previous_unlocked(current_id)
  local unlocked_ids = FastTravel.get_unlocked_ids()
  if #unlocked_ids == 0 then
    return nil
  end

  if not current_id then
    return unlocked_ids[1]
  end

  -- Find current index
  local current_index = nil
  for i, id in ipairs(unlocked_ids) do
    if id == current_id then
      current_index = i
      break
    end
  end

  if not current_index then
    return unlocked_ids[1]
  end

  -- Return previous (wrap around)
  local prev_index = ((current_index - 2) % #unlocked_ids) + 1
  return unlocked_ids[prev_index]
end

-----------------------------------------------------------
-- Minimap Integration
-----------------------------------------------------------

function M.draw_fast_travel_markers(minimap_context)
  -- Called by minimap during rendering
  local all_ids = FastTravel.get_all_ids()

  for _, station_id in ipairs(all_ids) do
    local point = FastTravel.get_point(station_id)
    if point and M.should_draw_station(station_id, point) then
      M.draw_station_marker(minimap_context, station_id, point)
    end
  end
end

function M.should_draw_station(station_id, point)
  local is_unlocked = FastTravel.is_unlocked(station_id)

  if point and point.show_on_map == false then
    return false
  end

  -- Don't show locked stations if setting is off
  if not is_unlocked and not M.SHOW_LOCKED then
    return false
  end

  -- Always show unlocked stations
  return true
end

-----------------------------------------------------------
-- Drawing Functions
-----------------------------------------------------------

function M.draw_station_marker(ctx, station_id, point)
  local pos = point.pos
  if not pos then return end

  -- Convert world position to minimap coordinates
  local minimap_x, minimap_y = M.world_to_minimap(ctx, pos.x, pos.y)

  -- Determine color based on station state
  local color, size = M.get_station_visual(station_id, point)

  -- Draw marker shape
  if M.MARKER_SHAPE == "square" then
    M.draw_square(ctx, minimap_x, minimap_y, size, color)
  elseif M.MARKER_SHAPE == "circle" then
    M.draw_circle(ctx, minimap_x, minimap_y, size / 2, color)
  elseif M.MARKER_SHAPE == "diamond" then
    M.draw_diamond(ctx, minimap_x, minimap_y, size, color)
  end

  -- Draw label for selected station
  if station_id == selected_station_id and ctx.draw_text then
    ctx.draw_text(minimap_x, minimap_y - size, point.name or station_id,
      vmath.vector4(1, 1, 1, 1))
  end
end

function M.get_station_visual(station_id, point)
  local is_unlocked = FastTravel.is_unlocked(station_id)
  local is_selected = (station_id == selected_station_id)
  local is_current = (station_id == current_station_id)
  local size = M.MARKER_SIZE

  -- Current location - yellow, larger
  if is_current then
    local color = M.COLORS.CURRENT
    if M.PULSE_UNLOCKED then
      local pulse = math.abs(math.sin(Time.gettime() * 2))
      size = M.MARKER_SIZE * (1.0 + pulse * 0.3)
      color = vmath.vector4(color.x, color.y, color.z, 0.8 + pulse * 0.2)
    end
    return color, size
  end

  -- Selected station - bright blue, larger
  if is_selected then
    local color = M.COLORS.SELECTED
    if M.PULSE_SELECTED then
      local pulse = math.abs(math.sin(Time.gettime() * 4))
      size = M.MARKER_SIZE * (1.2 + pulse * 0.2)
      color = vmath.vector4(color.x, color.y, color.z, 0.9 + pulse * 0.1)
    end
    return color, size
  end

  -- Unlocked station - blue, slight pulse
  if is_unlocked then
    local color = M.COLORS.UNLOCKED
    if M.PULSE_UNLOCKED then
      local pulse = math.abs(math.sin(Time.gettime() * 2 + station_id:byte(1)))
      color = vmath.vector4(color.x, color.y, color.z, 0.7 + pulse * 0.2)
    end
    return color, size
  end

  -- Locked station - gray
  return M.COLORS.LOCKED, size * 0.8
end

function M.world_to_minimap(ctx, world_x, world_y)
  -- Convert world coordinates to minimap pixel coordinates
  local scale = ctx.scale or 0.1
  local offset_x = ctx.offset_x or 0
  local offset_y = ctx.offset_y or 0

  local minimap_x = (world_x * scale) + offset_x
  local minimap_y = (world_y * scale) + offset_y

  return minimap_x, minimap_y
end

-----------------------------------------------------------
-- Shape Drawing Helpers
-----------------------------------------------------------

function M.draw_square(ctx, x, y, size, color)
  if ctx.draw_rect then
    ctx.draw_rect(x - size/2, y - size/2, size, size, color)
  end
end

function M.draw_circle(ctx, x, y, radius, color)
  if ctx.draw_circle then
    ctx.draw_circle(x, y, radius, color)
  end
end

function M.draw_diamond(ctx, x, y, size, color)
  if ctx.draw_polygon then
    local half = size / 2
    local points = {
      {x = x, y = y + half},        -- Top
      {x = x + half, y = y},        -- Right
      {x = x, y = y - half},        -- Bottom
      {x = x - half, y = y}         -- Left
    }
    ctx.draw_polygon(points, color)
  elseif ctx.draw_lines then
    -- Fallback: draw as lines
    local half = size / 2
    ctx.draw_lines({
      x, y + half, x + half, y,
      x + half, y, x, y - half,
      x, y - half, x - half, y,
      x - half, y, x, y + half
    }, color)
  end
end

return M
