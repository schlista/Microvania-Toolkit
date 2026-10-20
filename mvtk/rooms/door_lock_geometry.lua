-- mvtk/rooms/door_lock_geometry.lua
-- Where to place tile-sized blockers so a locked room's doors are fully shut.
--
-- Door markers come from two scans:
--   * runtime scan: one marker per painted door tile (already tile-sized);
--   * file scan:   one marker per door RUN, at the run's centre, carrying the
--                  run length in `span` (pixels along the door axis).
-- A single tile-sized blocker at a 3-tile run's centre leaves the top and
-- bottom tiles open, and the player walked out under it during boss fights.
-- Runs are therefore split into one blocker per tile (uniform scale only:
-- no reliance on non-uniform collision scaling).
--
-- Pure Lua; unit-tested in test/pt4_tour_fix_tests.lua.
local M = {}

local HORIZONTAL_SIDES = { top = true, bottom = true, up = true, down = true }

-- doors:  list of { x, y, side?, span? } (world-space centres)
-- tile_w: tile width in px
-- tile_h: tile height in px
-- Returns a list of { x, y, w, h, tag }.
function M.blocker_rects(doors, tile_w, tile_h)
    local rects = {}
    tile_w = tonumber(tile_w) or 128
    tile_h = tonumber(tile_h) or 128
    local seen = {}
    local function add(x, y, tag)
        -- Runtime and file markers can describe the same tile; skip overlaps.
        local key = string.format("%d:%d", math.floor(x + 0.5), math.floor(y + 0.5))
        if seen[key] then return end
        seen[key] = true
        rects[#rects + 1] = { x = x, y = y, w = tile_w, h = tile_h, tag = tag }
    end
    for i, d in ipairs(doors or {}) do
        if type(d) == "table" and d.x and d.y then
            local span = tonumber(d.span)
            local horizontal = HORIZONTAL_SIDES[tostring(d.side or "")] == true
            local step = horizontal and tile_w or tile_h
            local count = (span and span > step) and math.max(1, math.floor(span / step + 0.5)) or 1
            for k = 1, count do
                -- Offsets centred on the run: -(count-1)/2 .. +(count-1)/2 tiles.
                local offset = (k - (count + 1) / 2) * step
                local x = horizontal and (d.x + offset) or d.x
                local y = horizontal and d.y or (d.y + offset)
                add(x, y, string.format("door_%d_%d", i, k))
            end
        end
    end
    return rects
end

return M
