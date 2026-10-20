-- mvtk/developer/rooms/minimap_outline.lua
-- Minimap outline generation using bounds layer tiles (like layout editor)
-- Extracts actual room shapes instead of simple rectangles

local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")

local M = {}
local ok_cfg, Config = pcall(require, "settings.config")
local VERBOSE = ok_cfg and Config and Config.debug and Config.debug.prints

local function DBG(fmt, ...)
    if VERBOSE then
        print("[MM_OUTLINE_DBG] " .. string.format(fmt, ...))
    end
end

-- Extra explicit line logging requested by user
local LINE_DEBUG = ok_cfg and Config and Config.debug and (
    (Config.debug.debug and Config.debug.debug.bounds) or Config.debug.draw_bounds or Config.debug.prints
)
local function LDBG(fmt, ...)
    if LINE_DEBUG then
        print("[line debug] " .. string.format(fmt, ...))
    end
end

local function read_text(path)
    if not path or path == "" then return nil end
    if path:sub(1,1) ~= "/" then path = "/" .. path end
    local ok, txt = pcall(sys.load_resource, path)
    return (ok and txt and #txt > 0) and txt or nil
end

local function parse_tilesource_tile_size(ts_text)
    local tw = tonumber(ts_text and ts_text:match("tile_width:%s*(%d+)")) or Tile.width
    local th = tonumber(ts_text and ts_text:match("tile_height:%s*(%d+)")) or Tile.height
    return tw, th
end

local SLOPE_TILES = { [170] = true, [171] = true, [299] = true }

local function scan_layer_cells(tilemap_text, layer_id)
    local cells, in_layer, in_cell = {}, false, false
    local cur = {}
    for line in tilemap_text:gmatch("[^\r\n]+") do
        local lid = line:match('^%s*id:%s*"([^"]+)"')
        if lid then
            in_layer = (lid == layer_id)
        elseif in_layer then
            if line:match('^%s*cell%s*{') then
                in_cell, cur = true, {}
            elseif in_cell and line:match('^%s*}%s*$') then
                if cur.x and cur.y then
                    -- Determine slope orientation after flips/rotation
                    if cur.tile and SLOPE_TILES[cur.tile] then
                        local flips = (cur.h_flip and 1 or 0) + (cur.v_flip and 1 or 0) + (cur.rotate90 and 1 or 0)
                        cur.slope = (flips % 2 == 0) and "\\" or "/"
                    end
                    cells[#cells+1] = cur
                end
                in_cell, cur = false, {}
            elseif in_cell then
                local v = line:match('^%s*x:%s*(-?%d+)%s*$')
                if v then
                    cur.x = tonumber(v)
                else
                    v = line:match('^%s*y:%s*(-?%d+)%s*$')
                    if v then
                        cur.y = tonumber(v)
                    else
                        v = line:match('^%s*tile:%s*(%d+)%s*$')
                        if v then
                            cur.tile = tonumber(v)
                        else
                            v = line:match('^%s*h_flip:%s*(%d+)%s*$')
                            if v then
                                cur.h_flip = (tonumber(v) ~= 0)
                            else
                                v = line:match('^%s*v_flip:%s*(%d+)%s*$')
                                if v then
                                    cur.v_flip = (tonumber(v) ~= 0)
                                else
                                    v = line:match('^%s*rotate90:%s*(%d+)%s*$')
                                    if v then
                                        cur.rotate90 = (tonumber(v) ~= 0)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return cells
end

-- Build merged world-space fill rectangles from a set of tile coords
local function build_fill_rects_from_bounds(bounds, tm_pos, tile_w, tile_h)
    if not bounds or #bounds == 0 then return {} end
    DBG("build_fill_rects_from_bounds: %d tiles", #bounds)
    -- Group tiles by row
    local rows = {}
    local min_ty, max_ty = math.huge, -math.huge
    for _, c in ipairs(bounds) do
        local ty = c.y; local tx = c.x
        local row = rows[ty]
        if not row then row = {}; rows[ty] = row end
        row[#row+1] = tx
        if ty < min_ty then min_ty = ty end
        if ty > max_ty then max_ty = ty end
    end
    -- Sort each row and turn into runs [x0..x1]
    local runs_by_row = {}
    for ty, xs in pairs(rows) do
        table.sort(xs)
        local runs = {}
        local x0, prev = nil, nil
        for _, x in ipairs(xs) do
            if not x0 then x0, prev = x, x
            elseif x == prev + 1 then prev = x
            else
                runs[#runs+1] = { x0 = x0, x1 = prev }
                x0, prev = x, x
            end
        end
        if x0 then runs[#runs+1] = { x0 = x0, x1 = prev } end
        runs_by_row[ty] = runs
    end
    -- Merge vertically for identical [x0..x1] across consecutive rows
    local out = {}
    local active = {}
    local function key_for(r) return r.x0 .. ":" .. r.x1 end
    for ty = min_ty, max_ty do
        local next_active = {}
        local runs = runs_by_row[ty] or {}
        for _, r in ipairs(runs) do
            local key = key_for(r)
            local cur = active[key]
            if cur then
                -- Extend existing rectangle one more row
                cur.ty1 = ty
                next_active[key] = cur
                active[key] = nil
            else
                -- Start a new rectangle at this row
                next_active[key] = { x0 = r.x0, x1 = r.x1, ty0 = ty, ty1 = ty }
            end
        end
        -- Flush any active not continued on this row
        for _, cur in pairs(active) do
            local x = tm_pos.x + ((cur.x0 - 1) * tile_w)
            local y = tm_pos.y + ((cur.ty0 - 1) * tile_h)
            local w = (cur.x1 - cur.x0 + 1) * tile_w
            local h = (cur.ty1 - cur.ty0 + 1) * tile_h
            out[#out+1] = { x = x, y = y, w = w, h = h }
            DBG("fill rect: x=%.1f y=%.1f w=%.1f h=%.1f", x, y, w, h)
        end
        active = next_active
    end
    -- Flush remaining active
    for _, cur in pairs(active) do
        local x = tm_pos.x + ((cur.x0 - 1) * tile_w)
        local y = tm_pos.y + ((cur.ty0 - 1) * tile_h)
        local w = (cur.x1 - cur.x0 + 1) * tile_w
        local h = (cur.ty1 - cur.ty0 + 1) * tile_h
        out[#out+1] = { x = x, y = y, w = w, h = h }
        DBG("fill rect: x=%.1f y=%.1f w=%.1f h=%.1f", x, y, w, h)
    end
    DBG("total fill rects: %d", #out)
    return out
end

-- Simply pass through segments without merging to preserve room shapes
-- Merge a list of 1-tile edges into maximal collinear segments
local function merge_collinear_segments(segments)
    if not segments or #segments == 0 then return {} end
    -- Separate by orientation and anchor coordinate
    local horiz_by_y, vert_by_x = {}, {}
    for _, e in ipairs(segments) do
        if e.dir == "horizontal" then
            local y = e.y
            local list = horiz_by_y[y] or {}
            list[#list+1] = { x0 = e.x0, x1 = e.x1 }
            horiz_by_y[y] = list
        elseif e.dir == "vertical" then
            local x = e.x
            local list = vert_by_x[x] or {}
            list[#list+1] = { y0 = e.y0, y1 = e.y1 }
            vert_by_x[x] = list
        end
    end

    local out = {}
    -- Merge horizontal runs on each scanline
    for y, list in pairs(horiz_by_y) do
        table.sort(list, function(a,b) return a.x0 < b.x0 end)
        local cur = nil
        for _, seg in ipairs(list) do
            if not cur then
                cur = { x0 = seg.x0, x1 = seg.x1 }
            elseif seg.x0 <= cur.x1 + 1e-6 then
                -- contiguous or overlapping
                if seg.x1 > cur.x1 then cur.x1 = seg.x1 end
            else
                out[#out+1] = { dir = "horizontal", y = y, x0 = cur.x0, x1 = cur.x1 }
                cur = { x0 = seg.x0, x1 = seg.x1 }
            end
        end
        if cur then out[#out+1] = { dir = "horizontal", y = y, x0 = cur.x0, x1 = cur.x1 } end
    end
    -- Merge vertical runs on each column
    for x, list in pairs(vert_by_x) do
        table.sort(list, function(a,b) return a.y0 < b.y0 end)
        local cur = nil
        for _, seg in ipairs(list) do
            if not cur then
                cur = { y0 = seg.y0, y1 = seg.y1 }
            elseif seg.y0 <= cur.y1 + 1e-6 then
                if seg.y1 > cur.y1 then cur.y1 = seg.y1 end
            else
                out[#out+1] = { dir = "vertical", x = x, y0 = cur.y0, y1 = cur.y1 }
                cur = { y0 = seg.y0, y1 = seg.y1 }
            end
        end
        if cur then out[#out+1] = { dir = "vertical", x = x, y0 = cur.y0, y1 = cur.y1 } end
    end
    return out
end

-- Trace outline polygon from bounds tiles (like layout editor)
-- Option A: connect-the-dots polyline through tile centers (captures diagonals/slopes)
-- Option B: exposed cell-edge outline (axis-aligned); kept as fallback

-- Build an ordered closed polyline by walking 8-neighborhood through the set of cells.
-- Returns points in WORLD space.
local function polyline_from_bounds_centers(bounds, min_x, min_y, tile_w, tile_h, go_pos)
    if not bounds or #bounds == 0 then return {} end
    DBG("polyline_from_bounds_centers: %d tiles", #bounds)
    -- index by tile coord
    local key = function(x,y) return x .. ":" .. y end
    local nodes = {}
    for _, c in ipairs(bounds) do nodes[key(c.x,c.y)] = { x=c.x, y=c.y, n={} } end
    local OFFS = {
        {-1,-1},{0,-1},{1,-1},
        {-1, 0},        {1, 0},
        {-1, 1},{0, 1},{1, 1},
    }
    for _, c in ipairs(bounds) do
        local me = nodes[key(c.x,c.y)]
        for _, d in ipairs(OFFS) do
            local nb = nodes[key(c.x+d[1], c.y+d[2])]
            if nb then me.n[#me.n+1] = nb end
        end
    end
    -- choose deterministic start (leftmost, then lowest)
    local start
    for _, n in pairs(nodes) do
        if (not start) or (n.x < start.x) or (n.x == start.x and n.y < start.y) then start = n end
    end
    if not start then return {} end
    DBG("start node: (%d,%d)", start.x, start.y)
    local prev = { x = start.x - 1, y = start.y }
    local cur  = start
    local poly = {}
    local guard = 0
    repeat
        -- World position of the tile CENTER at (tx,ty): origin + (tx-0.5, ty-0.5) * tile_size
        poly[#poly+1] = {
            x = go_pos.x + ((cur.x - 0.5) * tile_w),
            y = go_pos.y + ((cur.y - 0.5) * tile_h),
        }
        -- pick neighbor that best continues current direction
        local vx, vy = (cur.x - prev.x), (cur.y - prev.y)
        local best, best_dp = nil, -1e9
        for _, nb in ipairs(cur.n) do
            if not (nb.x == prev.x and nb.y == prev.y) then
                local wx, wy = (nb.x - cur.x), (nb.y - cur.y)
                local denom = math.sqrt(vx*vx + vy*vy) * math.sqrt(wx*wx + wy*wy)
                local dp = (denom > 0) and ((vx*wx + vy*wy) / denom) or -1e9
                if dp > best_dp then best, best_dp = nb, dp end
            end
        end
        prev, cur = cur, best
        guard = guard + 1
        if guard > 10000 then break end
    until (not cur) or (cur.x == start.x and cur.y == start.y)

    if #poly > 0 then poly[#poly+1] = { x = poly[1].x, y = poly[1].y } end
    DBG("polyline points: %d", #poly)
    for i, p in ipairs(poly) do
        DBG("poly[%d] = (%.1f, %.1f)", i, p.x, p.y)
    end
    return poly
end

-- Build axis-aligned line segments from bounds tiles by emitting exposed cell edges
local function bounds_to_segments_from_edges(bounds, min_x, min_y, tile_w, tile_h, go_pos)
    if not bounds or #bounds == 0 then return {} end
    DBG("bounds_to_segments_from_edges: %d tiles", #bounds)
    -- Build lookup grid for adjacency checks
    local grid = {}
    for _, c in ipairs(bounds) do
        grid[c.x] = grid[c.x] or {}
        grid[c.x][c.y] = c
    end

    local function world_center(tx, ty)
        return go_pos.x + (tx - 0.5) * tile_w, go_pos.y + (ty - 0.5) * tile_h
    end

    local segments = {}
    for _, c in ipairs(bounds) do
        local tx, ty = c.x, c.y
        local cx, cy = world_center(tx, ty)

        local function connect(dx, dy)
            local nx, ny = tx + dx, ty + dy
            if grid[nx] and grid[nx][ny] then
                local nx_cx, nx_cy = world_center(nx, ny)
                segments[#segments+1] = { x1 = cx, y1 = cy, x2 = nx_cx, y2 = nx_cy }
                DBG("edge seg: (%.1f, %.1f) -> (%.1f, %.1f)", cx, cy, nx_cx, nx_cy)
            end
        end

        connect(1, 0)
        connect(0, 1)

        if c.slope == "\\" then
            connect(1, 1)
        elseif c.slope == "/" then
            connect(1, -1)
        end
    end
    DBG("edge segments total: %d", #segments)
    return segments
end

-- Generate a list of line segments representing the room outline.
-- Prefers a detailed polyline (which preserves sloped edges) and falls back
-- to a simple edge walk if the polyline can't be produced.
local function bounds_to_line_segments(bounds, min_x, min_y, tile_w, tile_h, go_pos)
    DBG("bounds_to_line_segments: %d tiles", #bounds)
    -- Try the detailed polyline first (captures diagonal/slope appearance)
    local poly = polyline_from_bounds_centers(bounds, min_x, min_y, tile_w, tile_h, go_pos)
    if poly and #poly >= 2 then
        DBG("polyline attempt produced %d points", #poly)
        local segs = {}
        for i = 1, #poly - 1 do
            local p1 = poly[i]
            local p2 = poly[i + 1]
            segs[#segs + 1] = { x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y }
            LDBG("poly seg %d: (%.1f, %.1f) -> (%.1f, %.1f)", i, p1.x, p1.y, p2.x, p2.y)
        end
        if #segs > 0 then
            DBG("using %d polyline segments", #segs)
            return segs
        end
    else
        DBG("polyline attempt failed")
    end
    -- Fallback: exposed edges (axis-aligned with optional diagonal connectors)
    DBG("falling back to edge walk")
    local segs = bounds_to_segments_from_edges(bounds, min_x, min_y, tile_w, tile_h, go_pos)
    for i, s in ipairs(segs) do
        LDBG("edge seg %d: (%.1f, %.1f) -> (%.1f, %.1f)", i, s.x1 or 0, s.y1 or 0, s.x2 or 0, s.y2 or 0)
    end
    return segs
end

function M.extract_room_outline(room_path, go_pos)
    if not room_path or room_path == "" then
        return nil, "no_room_path"
    end

    local canonical = Util.normalize_room_id(room_path)
    if canonical == "" then
        return nil, "no_room_path"
    end
    canonical = "developer/rooms/" .. canonical

    local tilemap_path = canonical .. ".tilemap"
    local tm_text = read_text(tilemap_path)
    if not tm_text then
        DBG("extract_room_outline(file) missing tilemap: %s", tilemap_path)
        return nil, "tilemap_not_found"
    end

    local tileset_path = tm_text:match('tile_set:%s*"([^"]+)"')
    local ts_text = read_text(tileset_path)
    local tile_w, tile_h = parse_tilesource_tile_size(ts_text)

    local bounds = scan_layer_cells(tm_text, "bounds")
    if #bounds == 0 then
        DBG("extract_room_outline(file) no bounds in %s", tilemap_path)
        return nil, "no_bounds"
    end

    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(bounds) do
        if c.x < minx then minx = c.x end
    	if c.y < miny then miny = c.y end
    	if c.x > maxx then maxx = c.x end
    	if c.y > maxy then maxy = c.y end
    end

    local origin = go_pos or vmath.vector3(0,0,0)
    local segments = bounds_to_line_segments(bounds, minx, miny, tile_w, tile_h, origin)
    local fill_rects = build_fill_rects_from_bounds(bounds, origin, tile_w, tile_h)

    local world_bounds = {
        min_x = origin.x + ((minx - 1) * tile_w),
        min_y = origin.y + ((miny - 1) * tile_h),
        max_x = origin.x + (maxx * tile_w),
        max_y = origin.y + (maxy * tile_h),
    }

    return {
        segments = segments,
        fill_rects = fill_rects,
        bounds = world_bounds,
        tile_count = #bounds,
    }
end

-- Extract outline from runtime tilemap components
function M.extract_room_outline_from_runtime(created, go_pos)
    if not created or not go_pos then return nil end
    
    -- Find tilemap component in the created objects
    local tilemap_url = nil
    local tilemap_pos = nil
    
    for _, go_url in pairs(created) do
        if go_url and go.exists(go_url) then
            -- Try common tilemap component names
            local candidates = { "tilemap", "tm", "level", "map" }
            local u = msg.url(go_url)
            for _, comp_name in ipairs(candidates) do
                local test_url = msg.url(u.socket, u.path, hash(comp_name))
                local ok = pcall(tilemap.get_bounds, test_url)
                if ok then
                    tilemap_url = test_url
                    -- Always use WORLD position of the GO that owns the tilemap
                    local okp, comp_pos = pcall(go.get_world_position, go_url)
                    tilemap_pos = (okp and comp_pos) or go.get_position(go_url)
                    break
                end
            end
            if tilemap_url then break end
        end
    end
    
    if not tilemap_url then
        if VERBOSE then print("[MINIMAP_OUTLINE] No tilemap found in runtime objects") end
        return nil
    end
    
    if VERBOSE then print(string.format("[MINIMAP_OUTLINE] Found runtime tilemap: %s at pos(%.1f,%.1f)", 
          tostring(tilemap_url), tilemap_pos.x, tilemap_pos.y)) end
    
    -- Get bounds layer tiles from the runtime tilemap
    -- Check layer existence first to avoid GAMESYS "Could not find layer" errors
    local bounds_layer_hash = hash("bounds")
    -- This runtime outline has never run in-engine: it relied on
    -- tilemap.get_layers, which Defold does not provide, so the minimap has
    -- always used the published layout outline. Enabling it would change the
    -- minimap and is out of scope for the PT4 fix pass (see
    -- docs/archive/PT4_TOUR_IMPLEMENTATION_LOG.md); keep the proven behaviour.
    local has_bounds_layer = false
    if not has_bounds_layer then
        if VERBOSE then print("[MINIMAP_OUTLINE] No 'bounds' layer in tilemap") end
        return nil
    end
    local ok, min_tx, min_ty, w, h = pcall(tilemap.get_bounds, tilemap_url, bounds_layer_hash)
    if not (ok and w and h and w > 0 and h > 0) then
        if VERBOSE then print("[MINIMAP_OUTLINE] Could not get tilemap bounds") end
        return nil
    end
    
    -- Scan bounds layer tiles
    local bounds = {}
    local layer_hash = bounds_layer_hash
    -- Optional: respect stream_settings clamp so minimap matches layout_editor/camera
    local clamp_min_y = nil
    local okS, S = pcall(require, "settings.stream_settings")
    if okS and S and S.bounds then clamp_min_y = S.bounds.min_tile_y end

    for ty = min_ty, min_ty + h - 1 do
        if (not clamp_min_y) or (ty >= clamp_min_y) then
        for tx = min_tx, min_tx + w - 1 do
            local tid = tilemap.get_tile(tilemap_url, layer_hash, tx, ty) or 0
            if tid ~= 0 then
                bounds[#bounds+1] = { x = tx, y = ty }
            end
        end
        end
    end

    DBG("runtime extraction: found %d bounds tiles", #bounds)
    if #bounds == 0 then
        if VERBOSE then print("[MINIMAP_OUTLINE] No bounds layer tiles found") end
        return nil
    end

    if VERBOSE then print(string.format("[MINIMAP_OUTLINE] Found %d bounds tiles", #bounds)) end
    
    -- Calculate extents
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs(bounds) do
        minx = math.min(minx, c.x)
        miny = math.min(miny, c.y)
        maxx = math.max(maxx, c.x)
        maxy = math.max(maxy, c.y)
    end
    
    -- Use configured tile size as fallback if runtime tileset read fails
    local tile_w, tile_h = Tile.width, Tile.height
    
    -- Generate line segments for the outline and merged fill rects
    local segments = bounds_to_line_segments(bounds, minx, miny, tile_w, tile_h, tilemap_pos)
    local fill_rects = build_fill_rects_from_bounds(bounds, tilemap_pos, tile_w, tile_h)
    DBG("runtime outline produced %d segments and %d fill rects", #segments, #fill_rects)
    
    -- Calculate world bounds (fixed coordinates)
    local world_bounds = {
        -- Left/bottom are at gridlines (minx-1, miny-1)
        min_x = tilemap_pos.x + ( (minx - 1) * tile_w ),
        min_y = tilemap_pos.y + ( (miny - 1) * tile_h ),
        max_x = tilemap_pos.x + ( maxx * tile_w ),
        max_y = tilemap_pos.y + ( maxy * tile_h )
    }
    
    if VERBOSE then print(string.format("[MINIMAP_OUTLINE] Runtime extraction: %d segments", #segments)) end

    -- Debug: log segment details for problematic rooms
    for i, seg in ipairs(segments) do
        LDBG("runtime seg %d: (%.1f, %.1f) -> (%.1f, %.1f)", i, seg.x1 or 0, seg.y1 or 0, seg.x2 or 0, seg.y2 or 0)
    end
    
    return {
        segments = segments,
        fill_rects = fill_rects,
        bounds = world_bounds,
        tile_count = #bounds
    }
end

return M




