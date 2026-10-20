--- Per-tile collision geometry (Tiled "Tile Collision Editor" shapes).
--
-- Pure string/math helpers -- no Defold or filesystem dependencies -- so they
-- are unit-testable and reusable by the editor-time build hook
-- (hooks.core.tilesource) that bakes per-tile collision into generated rooms.
--
-- Tiled stores collision shapes as an <objectgroup> inside a <tile> element of
-- a .tsx tileset. We read those shapes and convert them into Defold-ready
-- convex hull points so that painting a tile "just works" as collision, with
-- the shape decoupled from the art pixels (Workflow 2).
--
-- Coordinate systems:
--   * Tiled tile-local: origin at the tile's TOP-LEFT, +Y downward, pixels.
--   * Defold cell-local: origin at the cell CENTER, +Y upward, pixels.
--
-- @module tile_collision

local M = {}

-- Box2D (Defold 2D physics) polygon limits.
M.MAX_HULL_VERTS = 8
local GEOM_EPS = 1e-6
local DEDUPE_EPS = 1e-3

local function parse_attributes(attr_text)
    local attrs = {}
    if type(attr_text) ~= "string" then
        return attrs
    end
    for name, _, value in attr_text:gmatch("([%w_:%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[name] = value
    end
    return attrs
end

local function same_point(a, b, eps)
    eps = eps or DEDUPE_EPS
    return a and b
        and math.abs((tonumber(a.x) or 0) - (tonumber(b.x) or 0)) <= eps
        and math.abs((tonumber(a.y) or 0) - (tonumber(b.y) or 0)) <= eps
end

-- Drop consecutive duplicate vertices, including the wrap-around case where the
-- last point coincides with the first. Tiled lets an author close a polygon by
-- clicking the start vertex again, which writes it twice (e.g. the slope
-- "0,0 64,-64 64,0 0,0"). The repeated vertex becomes a zero-length edge that
-- fails Box2D's b2PolygonShape::Set assertion (edge.LengthSquared() > epsilon)
-- and ABORTS the whole engine at room load. Compared with a small pixel epsilon
-- so float-rounding duplicates fold too; authored vertices are whole pixels
-- apart, so this only removes true duplicates and never reshapes a real hull.
local function dedupe_consecutive(points)
    local out = {}
    for _, p in ipairs(points or {}) do
        local q = { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0 }
        local prev = out[#out]
        if not same_point(prev, q) then
            out[#out + 1] = q
        end
    end
    while #out >= 2 and same_point(out[1], out[#out]) do
        out[#out] = nil
    end
    return out
end

local function parse_point_string(points_text, ox, oy)
    local pts = {}
    if type(points_text) ~= "string" then
        return pts
    end
    ox = tonumber(ox) or 0
    oy = tonumber(oy) or 0
    for px, py in points_text:gmatch("(-?[%d%.]+)%s*,%s*(-?[%d%.]+)") do
        pts[#pts + 1] = { x = ox + tonumber(px), y = oy + tonumber(py) }
    end
    return pts
end

local function add_diag(diagnostics, kind, message)
    diagnostics[#diagnostics + 1] = { kind = kind, message = message }
end

local function make_ellipse_points(x, y, w, h)
    local pts = {}
    local cx = (tonumber(x) or 0) + (tonumber(w) or 0) * 0.5
    local cy = (tonumber(y) or 0) + (tonumber(h) or 0) * 0.5
    local rx = (tonumber(w) or 0) * 0.5
    local ry = (tonumber(h) or 0) * 0.5
    if rx <= 0 or ry <= 0 then
        return pts
    end
    for i = 0, 7 do
        local a = (math.pi * 2 * i) / 8
        pts[#pts + 1] = { x = cx + math.cos(a) * rx, y = cy + math.sin(a) * ry }
    end
    return pts
end

local function append_polygon_shape(shapes, diagnostics, pts, degenerate_kind)
    pts = dedupe_consecutive(pts)
    if #pts >= 3 then
        shapes[#shapes + 1] = { kind = "polygon", points = pts }
        return true
    end
    add_diag(diagnostics, degenerate_kind or "degenerate_polygon", "polygon has fewer than 3 unique points")
    return false
end

--- Parse the per-tile collision shapes from a single <tile>...</tile> block.
-- Returns a list of shapes in TILE-LOCAL Tiled coordinates (top-left origin,
-- +Y down, pixels), or nil when the tile has no collision objects.
--   rectangle -> { kind = "rect", x, y, w, h }
--   polygon   -> { kind = "polygon", points = { {x=, y=}, ... } }  (absolute)
-- @param tile_block string  XML text of one <tile> element
-- @return table|nil, table|nil diagnostics
function M.parse_tile_collision_shapes(tile_block)
    if type(tile_block) ~= "string" then
        return nil, nil
    end
    local objectgroup = tile_block:match("<objectgroup.->(.-)</objectgroup>")
    if not objectgroup then
        return nil, nil
    end

    local shapes = {}
    local diagnostics = {}

    -- Child-shape objects: <object x= y=> <polygon|polyline|ellipse .../> </object>
    for obj_attr, obj_body in objectgroup:gmatch("<object%s+([^>]-)>(.-)</object>") do
        local a = parse_attributes(obj_attr)
        local ox = tonumber(a.x) or 0
        local oy = tonumber(a.y) or 0
        local polygon_attr = obj_body:match("<polygon%s+([^>]*)")
        local polyline_attr = obj_body:match("<polyline%s+([^>]*)")
        local ellipse = obj_body:match("<ellipse[%s>/]")
        if polygon_attr then
            local poly = parse_attributes(polygon_attr).points
            append_polygon_shape(shapes, diagnostics, parse_point_string(poly, ox, oy), "degenerate_polygon")
        elseif polyline_attr then
            local line = parse_attributes(polyline_attr).points
            if append_polygon_shape(shapes, diagnostics, parse_point_string(line, ox, oy), "degenerate_polyline") then
                add_diag(diagnostics, "polyline_auto_closed", "polyline auto-closed -- prefer the polygon tool")
            end
        elseif ellipse then
            local w = tonumber(a.width)
            local h = tonumber(a.height)
            if w and h and w > 0 and h > 0 then
                shapes[#shapes + 1] = { kind = "polygon", points = make_ellipse_points(ox, oy, w, h) }
                add_diag(diagnostics, "ellipse_approximated", "ellipse approximated with an 8-point polygon")
            else
                add_diag(diagnostics, "degenerate_ellipse", "ellipse has invalid width/height")
            end
        else
            local w = tonumber(a.width)
            local h = tonumber(a.height)
            if w and h and w > 0 and h > 0 then
                shapes[#shapes + 1] = { kind = "rect", x = ox, y = oy, w = w, h = h }
            end
        end
    end

    -- Rectangle objects are self-closing: <object x= y= width= height= .../>
    for obj_attr in objectgroup:gmatch("<object%s+([^>]-)/>") do
        local a = parse_attributes(obj_attr)
        local w = tonumber(a.width)
        local h = tonumber(a.height)
        if w and h and w > 0 and h > 0 then
            shapes[#shapes + 1] = {
                kind = "rect",
                x = tonumber(a.x) or 0,
                y = tonumber(a.y) or 0,
                w = w,
                h = h,
            }
        end
    end

    if #shapes == 0 then
        if #diagnostics == 0 then
            add_diag(diagnostics, "empty_objectgroup", "objectgroup has no supported collision shapes")
        end
        return nil, diagnostics
    end
    return shapes, (#diagnostics > 0 and diagnostics or nil)
end

--- Parse per-tile collision shapes from Tiled's Lua-export objectGroup table.
-- Returns the same tile-local Tiled coordinate shape format as
-- parse_tile_collision_shapes(), or nil when no supported collision objects are
-- present.
-- @param object_group table  Tiled Lua objectGroup with an `objects` array
-- @return table|nil, table|nil diagnostics
function M.parse_tile_collision_shapes_from_objectgroup(object_group)
    if type(object_group) ~= "table" or type(object_group.objects) ~= "table" then
        return nil, nil
    end

    local shapes = {}
    local diagnostics = {}
    for _, object in ipairs(object_group.objects) do
        if type(object) == "table" then
            local ox = tonumber(object.x) or 0
            local oy = tonumber(object.y) or 0
            local polygon = object.polygon
            if type(polygon) == "table" then
                if #polygon >= 3 then
                    local pts = {}
                    for _, p in ipairs(polygon) do
                        if type(p) == "table" then
                            pts[#pts + 1] = {
                                x = ox + (tonumber(p.x) or 0),
                                y = oy + (tonumber(p.y) or 0),
                            }
                        end
                    end
                    append_polygon_shape(shapes, diagnostics, pts, "degenerate_polygon")
                else
                    add_diag(diagnostics, "degenerate_polygon", "polygon has fewer than 3 unique points")
                end
            elseif type(object.polyline) == "table" then
                local pts = {}
                for _, p in ipairs(object.polyline) do
                    if type(p) == "table" then
                        pts[#pts + 1] = {
                            x = ox + (tonumber(p.x) or 0),
                            y = oy + (tonumber(p.y) or 0),
                        }
                    end
                end
                if append_polygon_shape(shapes, diagnostics, pts, "degenerate_polyline") then
                    add_diag(diagnostics, "polyline_auto_closed", "polyline auto-closed -- prefer the polygon tool")
                end
            else
                local w = tonumber(object.width)
                local h = tonumber(object.height)
                local shape = tostring(object.shape or "")
                if shape == "ellipse" then
                    if w and h and w > 0 and h > 0 then
                        shapes[#shapes + 1] = { kind = "polygon", points = make_ellipse_points(ox, oy, w, h) }
                        add_diag(diagnostics, "ellipse_approximated", "ellipse approximated with an 8-point polygon")
                    else
                        add_diag(diagnostics, "degenerate_ellipse", "ellipse has invalid width/height")
                    end
                elseif w and h and w > 0 and h > 0
                    and (shape == "rectangle" or object.polygon == nil) then
                    shapes[#shapes + 1] = {
                        kind = "rect",
                        x = ox,
                        y = oy,
                        w = w,
                        h = h,
                    }
                end
            end
        end
    end

    if #shapes == 0 then
        if #diagnostics == 0 then
            add_diag(diagnostics, "empty_objectgroup", "objectgroup has no supported collision shapes")
        end
        return nil, diagnostics
    end
    return shapes, (#diagnostics > 0 and diagnostics or nil)
end

-- Signed area (shoelace). Positive == counter-clockwise in a +Y-up system.
local function signed_area(points)
    local area = 0
    local n = #points
    for i = 1, n do
        local a = points[i]
        local b = points[(i % n) + 1]
        area = area + (a.x * b.y - b.x * a.y)
    end
    return area * 0.5
end

local function reversed(points)
    local out = {}
    for i = #points, 1, -1 do
        out[#out + 1] = points[i]
    end
    return out
end

--- True when the polygon is convex (all cross products share one sign).
-- Collinear vertices are tolerated.
function M.is_convex(points)
    local n = #points
    if n < 3 then
        return false
    end
    local sign = 0
    for i = 1, n do
        local a = points[i]
        local b = points[(i % n) + 1]
        local c = points[((i + 1) % n) + 1]
        local cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        if math.abs(cross) > GEOM_EPS then
            local s = (cross > 0) and 1 or -1
            if sign == 0 then
                sign = s
            elseif s ~= sign then
                return false
            end
        end
    end
    return true
end

--- Axis-aligned bounding box of a point list, as 4 CCW points (Defold space).
function M.bounding_box(points)
    local minx, miny = math.huge, math.huge
    local maxx, maxy = -math.huge, -math.huge
    for _, p in ipairs(points) do
        if p.x < minx then minx = p.x end
        if p.y < miny then miny = p.y end
        if p.x > maxx then maxx = p.x end
        if p.y > maxy then maxy = p.y end
    end
    return {
        { x = minx, y = miny },
        { x = maxx, y = miny },
        { x = maxx, y = maxy },
        { x = minx, y = maxy },
    }
end

local function copy_points(points)
    local out = {}
    for _, p in ipairs(points or {}) do
        out[#out + 1] = { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0 }
    end
    return out
end

local function cross3(a, b, c)
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function rewind_ccw(points)
    if signed_area(points) < 0 then
        return reversed(points)
    end
    return points
end

local function remove_collinear(points)
    local out = copy_points(points)
    local changed = true
    while changed and #out > 3 do
        changed = false
        for i = 1, #out do
            local prev = out[((i - 2) % #out) + 1]
            local curr = out[i]
            local nextp = out[(i % #out) + 1]
            if math.abs(cross3(prev, curr, nextp)) <= GEOM_EPS then
                table.remove(out, i)
                changed = true
                break
            end
        end
    end
    return out
end

local function round_key_number(n)
    n = tonumber(n) or 0
    if n >= 0 then
        return math.floor(n * 1000000 + 0.5)
    end
    return math.ceil(n * 1000000 - 0.5)
end

local function point_key(p)
    return tostring(round_key_number(p.x)) .. "," .. tostring(round_key_number(p.y))
end

local function point_on_segment(p, a, b)
    if math.abs(cross3(a, b, p)) > GEOM_EPS then
        return false
    end
    return p.x >= math.min(a.x, b.x) - GEOM_EPS
        and p.x <= math.max(a.x, b.x) + GEOM_EPS
        and p.y >= math.min(a.y, b.y) - GEOM_EPS
        and p.y <= math.max(a.y, b.y) + GEOM_EPS
end

local function segments_intersect(a, b, c, d)
    local c1 = cross3(a, b, c)
    local c2 = cross3(a, b, d)
    local c3 = cross3(c, d, a)
    local c4 = cross3(c, d, b)
    if ((c1 > GEOM_EPS and c2 < -GEOM_EPS) or (c1 < -GEOM_EPS and c2 > GEOM_EPS))
        and ((c3 > GEOM_EPS and c4 < -GEOM_EPS) or (c3 < -GEOM_EPS and c4 > GEOM_EPS)) then
        return true
    end
    return (math.abs(c1) <= GEOM_EPS and point_on_segment(c, a, b))
        or (math.abs(c2) <= GEOM_EPS and point_on_segment(d, a, b))
        or (math.abs(c3) <= GEOM_EPS and point_on_segment(a, c, d))
        or (math.abs(c4) <= GEOM_EPS and point_on_segment(b, c, d))
end

local function polygon_self_intersects(points)
    local n = #points
    local seen = {}
    for i, p in ipairs(points) do
        local key = point_key(p)
        if seen[key] then
            return true
        end
        seen[key] = i
    end
    for i = 1, n do
        local a1 = points[i]
        local a2 = points[(i % n) + 1]
        for j = i + 1, n do
            local adjacent = j == i
                or j == ((i % n) + 1)
                or i == ((j % n) + 1)
            if not adjacent then
                local b1 = points[j]
                local b2 = points[(j % n) + 1]
                if segments_intersect(a1, a2, b1, b2) then
                    return true
                end
            end
        end
    end
    return false
end

local function point_in_triangle(p, a, b, c)
    return cross3(a, b, p) >= -GEOM_EPS
        and cross3(b, c, p) >= -GEOM_EPS
        and cross3(c, a, p) >= -GEOM_EPS
end

local function ear_clip(points)
    local verts = copy_points(points)
    local triangles = {}
    local guard = 0
    while #verts > 3 do
        guard = guard + 1
        if guard > (#points * #points * 2) then
            return nil, "ear clipping did not converge"
        end
        local clipped = false
        for i = 1, #verts do
            local prev_i = ((i - 2) % #verts) + 1
            local next_i = (i % #verts) + 1
            local a, b, c = verts[prev_i], verts[i], verts[next_i]
            if cross3(a, b, c) > GEOM_EPS then
                local contains = false
                for j = 1, #verts do
                    if j ~= prev_i and j ~= i and j ~= next_i
                        and point_in_triangle(verts[j], a, b, c) then
                        contains = true
                        break
                    end
                end
                if not contains then
                    triangles[#triangles + 1] = { { x = a.x, y = a.y }, { x = b.x, y = b.y }, { x = c.x, y = c.y } }
                    table.remove(verts, i)
                    clipped = true
                    break
                end
            end
        end
        if not clipped then
            return nil, "no ear found"
        end
    end
    if #verts == 3 and math.abs(signed_area(verts)) > GEOM_EPS then
        triangles[#triangles + 1] = copy_points(verts)
    end
    return triangles
end

local function try_merge_polygons(a, b, max_verts)
    local edges = {}
    local shared = 0
    local function add_edge(p1, p2)
        local k1 = point_key(p1)
        local k2 = point_key(p2)
        local key = k1 .. "|" .. k2
        local reverse = k2 .. "|" .. k1
        if edges[reverse] then
            edges[reverse] = nil
            shared = shared + 1
        else
            edges[key] = { a = { x = p1.x, y = p1.y }, b = { x = p2.x, y = p2.y } }
        end
    end
    for _, poly in ipairs({ a, b }) do
        for i = 1, #poly do
            add_edge(poly[i], poly[(i % #poly) + 1])
        end
    end
    if shared == 0 then
        return nil
    end

    local edge_list = {}
    for _, edge in pairs(edges) do
        edge_list[#edge_list + 1] = edge
    end
    if #edge_list < 3 or #edge_list > max_verts then
        return nil
    end

    local by_start = {}
    for i, edge in ipairs(edge_list) do
        local key = point_key(edge.a)
        if by_start[key] then
            return nil
        end
        by_start[key] = i
    end

    local first = edge_list[1]
    local start_key = point_key(first.a)
    local current = first
    local used = {}
    local ordered = {}
    for _ = 1, #edge_list do
        if used[current] then
            return nil
        end
        used[current] = true
        ordered[#ordered + 1] = { x = current.a.x, y = current.a.y }
        local next_key = point_key(current.b)
        if next_key == start_key then
            current = nil
            break
        end
        local next_index = by_start[next_key]
        if not next_index then
            return nil
        end
        current = edge_list[next_index]
    end
    if current ~= nil or #ordered < 3 then
        return nil
    end

    ordered = dedupe_consecutive(remove_collinear(ordered))
    if #ordered < 3 or #ordered > max_verts or math.abs(signed_area(ordered)) <= GEOM_EPS then
        return nil
    end
    ordered = rewind_ccw(ordered)
    if not M.is_convex(ordered) then
        return nil
    end
    return ordered
end

local function merge_triangles(triangles)
    local hulls = {}
    for _, tri in ipairs(triangles or {}) do
        hulls[#hulls + 1] = rewind_ccw(remove_collinear(tri))
    end

    local changed = true
    while changed do
        changed = false
        for i = 1, #hulls do
            local merged = false
            for j = i + 1, #hulls do
                local candidate = try_merge_polygons(hulls[i], hulls[j], M.MAX_HULL_VERTS)
                if candidate then
                    hulls[i] = candidate
                    table.remove(hulls, j)
                    changed = true
                    merged = true
                    break
                end
            end
            if merged then break end
        end
    end
    return hulls
end

--- Decompose a Defold-space polygon into valid Box2D hulls.
-- Returns a list of hulls plus a reason tag: "ok", "decomposed:N", or "bbox".
-- Degenerate input returns nil.
function M.decompose_polygon_to_hulls(points)
    local pts = dedupe_consecutive(remove_collinear(points))
    if #pts < 3 then
        return nil, nil
    end
    if polygon_self_intersects(pts) then
        return { M.bounding_box(pts) }, "bbox"
    end
    if math.abs(signed_area(pts)) <= GEOM_EPS then
        return nil, nil
    end
    pts = rewind_ccw(pts)

    if #pts <= M.MAX_HULL_VERTS and M.is_convex(pts) then
        return { pts }, "ok"
    end

    local triangles = ear_clip(pts)
    if not triangles or #triangles == 0 then
        return { M.bounding_box(pts) }, "bbox"
    end

    local hulls = merge_triangles(triangles)
    if not hulls or #hulls == 0 then
        return { M.bounding_box(pts) }, "bbox"
    end
    for i, hull in ipairs(hulls) do
        hulls[i] = rewind_ccw(dedupe_consecutive(remove_collinear(hull)))
        if #hulls[i] < 3 or #hulls[i] > M.MAX_HULL_VERTS
            or math.abs(signed_area(hulls[i])) <= GEOM_EPS
            or not M.is_convex(hulls[i]) then
            return { M.bounding_box(pts) }, "bbox"
        end
    end
    return hulls, "decomposed:" .. tostring(#hulls)
end

--- Convert a tile-local shape into Defold cell-local hull points.
-- Output: origin at the cell CENTER, +Y up, ordered counter-clockwise (the
-- order Box2D requires). Returns hulls, reason where reason is:
--   "ok"             convex, <= MAX_HULL_VERTS -- use the hull directly
--   "decomposed:N"   shape emitted N convex hulls
--   "bbox"           decomposition failed; hull is its AABB
--   nil      degenerate / unsupported (caller should skip)
-- @param shape  table   from parse_tile_collision_shapes
-- @param tile_w number
-- @param tile_h number
-- @return table|nil hulls, string|nil reason
function M.tile_shape_to_defold_points(shape, tile_w, tile_h, h_flip, v_flip, rotate90)
    tile_w = tonumber(tile_w) or 0
    tile_h = tonumber(tile_h) or 0
    if type(shape) ~= "table" or tile_w <= 0 or tile_h <= 0 then
        return nil, nil
    end

    local raw = {}
    if shape.kind == "rect" then
        local x, y, w, h = shape.x, shape.y, shape.w, shape.h
        raw = {
            { x = x, y = y },
            { x = x + w, y = y },
            { x = x + w, y = y + h },
            { x = x, y = y + h },
        }
    elseif shape.kind == "polygon" and type(shape.points) == "table" then
        for _, p in ipairs(shape.points) do
            raw[#raw + 1] = { x = p.x, y = p.y }
        end
    else
        return nil, nil
    end
    if #raw < 3 then
        return nil, nil
    end

    -- Tiled (top-left origin, +Y down) -> Defold (cell center, +Y up).
    local hw, hh = tile_w * 0.5, tile_h * 0.5
    local pts = {}
    for _, p in ipairs(raw) do
        pts[#pts + 1] = { x = p.x - hw, y = hh - p.y }
    end

    -- A repeated/closing vertex (or a shape that collapses to a line) would emit
    -- a zero-length edge or zero-area hull and crash Box2D at load.
    pts = dedupe_consecutive(pts)
    if #pts < 3 then
        return nil, nil
    end

    -- Apply painted-cell orientation before decomposition so concave shapes are
    -- split in the same space they will be baked.
    pts = rewind_ccw(pts)
    pts = M.transform_cell_local_points(pts, h_flip, v_flip, rotate90)
    return M.decompose_polygon_to_hulls(pts)
end

--- Apply a painted cell's Defold flip/rotate flags to cell-center-local hull
-- points so the baked collision matches the rendered (flipped/rotated) tile.
-- Operates in the space tile_shape_to_defold_points returns: origin at the cell
-- CENTER, +Y up. The flags are Defold's own .tilemap cell fields, and this
-- mirrors how Defold renders them on the hull: flip horizontally, flip
-- vertically, then rotate 90 CLOCKWISE. (Confirmed in-editor: a counter-
-- clockwise hull rotation landed the collider 180 degrees off the rendered
-- slope, i.e. the wrong way, on pure-rotate cells.) An odd number of reflections
-- inverts the winding, so the result is re-wound counter-clockwise for Box2D.
-- No-op (returns the input) when all flags are clear, so un-flipped rooms bake
-- byte-identically to before.
-- @param points   table   list of { x=, y= } in cell-center-local space
-- @param h_flip   number|boolean
-- @param v_flip   number|boolean
-- @param rotate90 number|boolean
-- @return table  transformed points (counter-clockwise)
function M.transform_cell_local_points(points, h_flip, v_flip, rotate90)
    if type(points) ~= "table" then
        return points
    end
    local hf = h_flip == true or (tonumber(h_flip) or 0) ~= 0
    local vf = v_flip == true or (tonumber(v_flip) or 0) ~= 0
    local rot = rotate90 == true or (tonumber(rotate90) or 0) ~= 0
    if not hf and not vf and not rot then
        return points
    end

    local out = {}
    for _, p in ipairs(points) do
        local x = tonumber(p.x) or 0
        local y = tonumber(p.y) or 0
        if hf then x = -x end
        if vf then y = -y end
        if rot then x, y = y, -x end  -- 90 degrees clockwise
        out[#out + 1] = { x = x, y = y }
    end

    -- Box2D wants counter-clockwise winding; a reflection flips it.
    if signed_area(out) < 0 then
        out = reversed(out)
    end
    return out
end

-- Rotate a local point (px, py) around the object origin by `rotation` degrees
-- using Tiled's convention (positive = clockwise in its +Y-down space). The
-- common 90-degree increments are handled exactly so a rotated slope bakes to
-- clean integer coordinates (e.g. 180 deg maps 64 -> -64 exactly, never
-- -63.9999... from sin/cos rounding).
local function rotate_point_tiled(px, py, rotation)
    local deg = (tonumber(rotation) or 0) % 360
    if deg == 0 then
        return px, py
    elseif deg == 90 then
        return -py, px
    elseif deg == 180 then
        return -px, -py
    elseif deg == 270 then
        return py, -px
    end
    local rad = math.rad(deg)
    local cos_r = math.cos(rad)
    local sin_r = math.sin(rad)
    return px * cos_r - py * sin_r, px * sin_r + py * cos_r
end

--- Convert a Tiled OBJECT-layer polygon into Defold room-local hull points.
-- Unlike tile_shape_to_defold_points (which centers on a tile cell), object
-- polygons are placed by absolute room position: the object's (x, y) is the
-- polygon origin in Tiled space (top-left origin, +Y down) and each point is
-- relative to it. When the object is rotated in Tiled, `rotation` (degrees,
-- clockwise) is applied around that origin before the Y flip so the baked hull
-- matches the shape the author sees. Output points are room-local absolute,
-- +Y up, ordered counter-clockwise (the order Box2D requires). Returns
-- hulls, reason:
--   "ok"             convex, <= MAX_HULL_VERTS -- use the hull directly
--   "decomposed:N"   shape emitted N convex hulls
--   "bbox"           decomposition failed; hull is its AABB (caller warns)
--   nil      degenerate / unsupported (caller should skip)
-- @param polygon    table   list of { x=, y= } relative to the object origin
-- @param object_x   number  object x in Tiled space
-- @param object_y   number  object y in Tiled space
-- @param map_height number  full map height in pixels (for the Y flip)
-- @param rotation   number  object rotation in degrees (Tiled clockwise); optional
-- @return table|nil hulls, string|nil reason
function M.object_polygon_to_defold_points(polygon, object_x, object_y, map_height, rotation)
    object_x = tonumber(object_x) or 0
    object_y = tonumber(object_y) or 0
    map_height = tonumber(map_height) or 0
    if type(polygon) ~= "table" or #polygon < 3 then
        return nil, nil
    end

    -- Tiled (top-left origin, +Y down, point relative to object origin, rotated
    -- clockwise around it) -> Defold room-local absolute (+Y up).
    local pts = {}
    for _, p in ipairs(polygon) do
        local px = tonumber(p.x) or 0
        local py = tonumber(p.y) or 0
        local rx, ry = rotate_point_tiled(px, py, rotation)
        pts[#pts + 1] = { x = object_x + rx, y = map_height - (object_y + ry) }
    end
    if #pts < 3 then
        return nil, nil
    end

    -- Strip a repeated/closing vertex (and reject a collapsed line) so we never
    -- hand Box2D a zero-length edge, which aborts the engine at load.
    pts = dedupe_consecutive(pts)
    if #pts < 3 then
        return nil, nil
    end

    pts = rewind_ccw(pts)
    return M.decompose_polygon_to_hulls(pts)
end

--- Convert a Tiled OBJECT-layer rectangle (Solid Box) into Defold room-local
-- hull points, honoring the object's rotation around its top-left origin
-- (Tiled clockwise). The rectangle's local corners are (0,0), (w,0), (w,h),
-- (0,h) relative to the origin; width/height fall back to 128 when absent.
-- Output matches object_polygon_to_defold_points: room-local absolute, +Y up,
-- wound counter-clockwise for Box2D.
-- @param object_x   number  rectangle origin x in Tiled space (top-left)
-- @param object_y   number  rectangle origin y in Tiled space (top-left)
-- @param width      number  rectangle width in pixels (defaults to 128)
-- @param height     number  rectangle height in pixels (defaults to 128)
-- @param map_height number  full map height in pixels (for the Y flip)
-- @param rotation   number  object rotation in degrees (Tiled clockwise); optional
-- @return table points (4 corners, counter-clockwise)
function M.object_rect_to_defold_points(object_x, object_y, width, height, map_height, rotation)
    local w = tonumber(width) or 0
    local h = tonumber(height) or 0
    if w <= 0 then w = 128 end
    if h <= 0 then h = 128 end
    local rect = {
        { x = 0, y = 0 },
        { x = w, y = 0 },
        { x = w, y = h },
        { x = 0, y = h },
    }
    local hulls = M.object_polygon_to_defold_points(rect, object_x, object_y, map_height, rotation)
    return hulls and hulls[1] or nil
end

--- True when `shape` is a rectangle covering the whole tile cell (origin 0,0 and
-- the cell's full width/height, within `eps` pixels). Such tiles are uniformly
-- solid, so many adjacent ones can be merged into a single collider rather than
-- one collision object per cell. `eps` defaults to 0.5px to tolerate Tiled's
-- integer rounding.
function M.shape_is_full_cell(shape, tile_w, tile_h, eps)
    eps = tonumber(eps) or 0.5
    if type(shape) ~= "table" or shape.kind ~= "rect" then
        return false
    end
    local tw = tonumber(tile_w) or 0
    local th = tonumber(tile_h) or 0
    if tw <= 0 or th <= 0 then
        return false
    end
    return math.abs((tonumber(shape.x) or 0)) <= eps
        and math.abs((tonumber(shape.y) or 0)) <= eps
        and math.abs((tonumber(shape.w) or 0) - tw) <= eps
        and math.abs((tonumber(shape.h) or 0) - th) <= eps
end

--- True when a tile's shape list makes the whole cell solid -- i.e. at least one
-- shape is a full-cell rectangle. Extra within-cell shapes (e.g. a full box plus
-- a decorative sub-rect) are redundant for solidity, so the cell is still treated
-- as a mergeable full-solid cell.
function M.tile_shapes_contain_full_cell(shapes, tile_w, tile_h, eps)
    if type(shapes) ~= "table" then
        return false
    end
    for _, s in ipairs(shapes) do
        if M.shape_is_full_cell(s, tile_w, tile_h, eps) then
            return true
        end
    end
    return false
end

--- Greedy-merge a set of solid grid cells into a small list of axis-aligned
-- rectangles, so a run/field of full-solid tiles becomes a handful of colliders
-- instead of one per cell. Pure (integer grid math only) and order-independent.
-- @param cells table  list of { x=<int cell col>, y=<int cell row> } (dupes ok)
-- @return table  list of { x, y, w, h } in cell units (x,y = bottom-left cell)
function M.merge_cell_rectangles(cells)
    local lookup = {}
    local list = {}
    for _, c in ipairs(cells or {}) do
        local cx, cy = tonumber(c.x), tonumber(c.y)
        if cx and cy then
            local key = cx .. "," .. cy
            if not lookup[key] then
                lookup[key] = true
                list[#list + 1] = { x = cx, y = cy }
            end
        end
    end

    -- Deterministic scan order: bottom-to-top, left-to-right.
    table.sort(list, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    local consumed = {}
    local rects = {}
    for _, c in ipairs(list) do
        local start_key = c.x .. "," .. c.y
        if not consumed[start_key] then
            -- Extend right along the row.
            local w = 1
            while true do
                local k = (c.x + w) .. "," .. c.y
                if lookup[k] and not consumed[k] then
                    w = w + 1
                else
                    break
                end
            end
            -- Extend up while every cell of the candidate row is free.
            local function row_free(yy)
                for xx = c.x, c.x + w - 1 do
                    local k = xx .. "," .. yy
                    if not lookup[k] or consumed[k] then
                        return false
                    end
                end
                return true
            end
            local h = 1
            while row_free(c.y + h) do
                h = h + 1
            end
            for yy = c.y, c.y + h - 1 do
                for xx = c.x, c.x + w - 1 do
                    consumed[xx .. "," .. yy] = true
                end
            end
            rects[#rects + 1] = { x = c.x, y = c.y, w = w, h = h }
        end
    end
    return rects
end

return M
