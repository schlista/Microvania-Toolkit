-- Shared CPU minimap renderer. Reads prepared resources through the caller; no writes or engine APIs.
local PngWriter = require "mvtk.editor.layout_editor.png_writer"
local MapColors = require "developer.tools.map_colors"
local LockedDoorReader = require "mvtk.editor.locked_door_reader"
local StreamPaths = require "mvtk.rooms.stream_paths"
local M = {}
function M.render(rooms, opts)
    opts = opts or {}
    opts.root = opts.root or "."
    local MINIMAP_CFG = opts.settings or require "developer.config.minimap_settings"
    local progress = opts.progress or function() end
    local log = {debug=function() end}
    local room_ids = {}; for id in pairs(rooms) do room_ids[#room_ids+1]=id end; table.sort(room_ids)
    local room_count = #room_ids
    assert(room_count > 0, "No rooms to render")
    local function project_tile_width() return assert(opts.tile_width) end
    local function project_tile_height() return assert(opts.tile_height) end
    local TILEMAP_TEXT_CACHE, TILESET_TEXT_CACHE, TILESET_PLATFORM_CACHE = {}, {}, {}
    local function load_text_cached(path, cache)
        if not path then return nil end
        if cache[path] == nil then cache[path] = opts.read(path) or false end
        return cache[path] or nil
    end
local function platform_tile_ids(tileset_path)
    if not tileset_path or tileset_path == "" then return {} end
    if TILESET_PLATFORM_CACHE[tileset_path] then
        return TILESET_PLATFORM_CACHE[tileset_path]
    end
    local ts_text = load_text_cached(tileset_path, TILESET_TEXT_CACHE)
    local ids = {}
    if ts_text then
        for block in ts_text:gmatch("tile%s*%b{}") do
            local id = tonumber(block:match("id%s*:%s*(%d+)"))
            local cg = block:match('collision_group%s*:%s*"([^"]+)"')
            local cgs = block:match('collision_groups%s*:%s*"([^"]+)"')
            local group = cg or cgs
            if id and group and group:lower():find("platform") then
                ids[id] = true
            end
        end
    end
    TILESET_PLATFORM_CACHE[tileset_path] = ids
    return ids
end

local function platform_cells_from_tilemap(tm_text, platform_ids)
    if not (tm_text and platform_ids and next(platform_ids)) then return {} end
    local cells = {}
    local function add_if_platform(body)
        local tid = tonumber(body:match("tile%s*:%s*(-?%d+)") or body:match("id%s*:%s*(-?%d+)"))
        -- Defold .tilemap `tile:` is a 0-based index (0 = first tile of the
        -- tilesource), and tilesource collision ids are 0-based too, so a
        -- platform painted with the first sheet tile is a valid `tile: 0`.
        -- The platform_ids membership check is the real filter; don't drop 0.
        if tid and platform_ids[tid] then
            local x = tonumber(body:match("x%s*:%s*(-?%d+)") or body:match("x:%s*(-?%d+)"))
            local y = tonumber(body:match("y%s*:%s*(-?%d+)") or body:match("y:%s*(-?%d+)"))
            if x and y then cells[#cells + 1] = { x = x, y = y } end
        end
    end
    for layer in tm_text:gmatch("layers%s*%b{}") do
        for t in layer:gmatch("tile%s*%b{}") do add_if_platform(t) end
        for c in layer:gmatch("cell%s*%b{}") do add_if_platform(c) end
    end
    return cells
end

local function build_platform_segments(platform_cells, shape, base_x, base_y)
    if not (platform_cells and shape and base_x and base_y) then return {} end
    local by_row = {}
    for _, c in ipairs(platform_cells) do
        local row = by_row[c.y] or {}
        row[#row + 1] = c.x
        by_row[c.y] = row
    end
    local segments = {}
    local min_x = shape.min_x or 0
    local min_y = shape.min_y or 0
    local tw = project_tile_width()
    local th = project_tile_height()
    for ty, xs in pairs(by_row) do
        table.sort(xs)
        local run_start, prev = nil, nil
        for _, tx in ipairs(xs) do
            if not run_start then
                run_start, prev = tx, tx
            elseif tx == prev + 1 then
                prev = tx
            else
                local wx0 = base_x + (run_start - min_x) * tw
                local wx1 = base_x + ((prev - min_x + 1) * tw)
                local wy  = base_y + (ty - min_y + 1) * th
                segments[#segments + 1] = { x1 = wx0, y1 = wy, x2 = wx1, y2 = wy }
                run_start, prev = tx, tx
            end
        end
        if run_start then
            local wx0 = base_x + (run_start - min_x) * tw
            local wx1 = base_x + ((prev - min_x + 1) * tw)
            local wy  = base_y + (ty - min_y + 1) * th
            segments[#segments + 1] = { x1 = wx0, y1 = wy, x2 = wx1, y2 = wy }
        end
    end
    return segments
end


    local outlines, door_segments = {}, {}
    local platform_segments = {}
    local room_polys = {}
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge
    local base_tile_w, base_tile_h = nil, nil

    local function include_point(wx, wy)
        if wx < min_x then min_x = wx end
        if wy < min_y then min_y = wy end
        if wx > max_x then max_x = wx end
        if wy > max_y then max_y = wy end
    end

    local function include_rect(x0, y0, x1, y1)
        include_point(x0, y0)
        include_point(x1, y1)
    end

    local processed_rooms = 0
    for _, room_id in ipairs(room_ids) do
        local room_data = rooms[room_id]
        local shape = room_data.shape
        local base = room_data.base_pos
        local base_x = (base and base.x) or 0
        local base_y = (base and base.y) or 0

        if shape then
            processed_rooms = processed_rooms + 1
            if room_count > 0 then
                progress(string.format("Processing room %d/%d: %s…", processed_rooms, room_count, tostring(room_id)))
            end
            local tile_w = project_tile_width()
            local tile_h = project_tile_height()
            if not base_tile_w then base_tile_w = tile_w end
            if not base_tile_h then base_tile_h = tile_h end
            local tm_text = nil
            if room_data.tilemap_path then
                tm_text = load_text_cached(room_data.tilemap_path, TILEMAP_TEXT_CACHE)
            end
            local rects = shape.rects or {}
            local doors = shape.doors or {}
            local poly = shape.poly or {}
            local shape_w = shape.w_px or 0
            local shape_h = shape.h_px or 0

            log.debug("Room %s: pos(%.1f, %.1f) px=(%d x %d) poly=%d rects=%d doors=%d",
                room_id, base_x, base_y, shape_w, shape_h, math.max(#poly - 1, 0), #rects, #doors)

            include_rect(base_x, base_y, base_x + shape_w, base_y + shape_h)

            local poly_loop = nil
            if #poly >= 3 then
                local poly_world = {}
                for i = 1, #poly do
                    local p = poly[i]
                    poly_world[#poly_world + 1] = { x = base_x + p.x, y = base_y + p.y }
                end
                local reduced = PngWriter.poly_reduce_colinear(poly_world, 0.9995)
                if reduced and #reduced >= 3 then
                    local first = reduced[1]
                    local last = reduced[#reduced]
                    if math.abs(first.x - last.x) > 0.01 or math.abs(first.y - last.y) > 0.01 then
                        reduced[#reduced + 1] = { x = first.x, y = first.y }
                    end
                    poly_loop = reduced
                    local fill_poly = {}
                    for i = 1, #reduced - 1 do
                        local rp = reduced[i]
                        fill_poly[#fill_poly + 1] = { x = rp.x, y = rp.y }
                    end
                    if #fill_poly >= 3 then
                        room_polys[#room_polys + 1] = fill_poly
                    end
                end
            end

            if not poly_loop then
                poly_loop = {
                    { x = base_x,           y = base_y },
                    { x = base_x + shape_w, y = base_y },
                    { x = base_x + shape_w, y = base_y + shape_h },
                    { x = base_x,           y = base_y + shape_h },
                    { x = base_x,           y = base_y },
                }
                room_polys[#room_polys + 1] = {
                    { x = base_x,           y = base_y },
                    { x = base_x + shape_w, y = base_y },
                    { x = base_x + shape_w, y = base_y + shape_h },
                    { x = base_x,           y = base_y + shape_h },
                }
            end

            for i = 1, #poly_loop - 1 do
                local p1 = poly_loop[i]
                local p2 = poly_loop[i + 1]
                outlines[#outlines + 1] = { x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y }
                include_point(p1.x, p1.y)
                include_point(p2.x, p2.y)
            end

            local door_states = LockedDoorReader.classify_locked_doors(room_data.tilemap_path, shape, doors, opts.read)

            for idx, door in ipairs(doors) do
                local x0 = base_x + door.x0
                local y0 = base_y + door.y0
                local x1 = base_x + door.x1
                local y1 = base_y + door.y1
                local state = door_states[idx] or "open"
                door_segments[#door_segments + 1] = { x1 = x0, y1 = y0, x2 = x1, y2 = y1, state = state }
                include_point(x0, y0)
                include_point(x1, y1)
            end

            if tm_text and shape.min_x and shape.min_y and room_data.tilemap_path then
                local tileset_path = tm_text:match('tile_set%s*:%s*"([^"]+)"')
                local plat_ids = platform_tile_ids(tileset_path)
                local plat_cells = platform_cells_from_tilemap(tm_text, plat_ids)
                local segs = build_platform_segments(plat_cells, shape, base_x, base_y)
                for _, seg in ipairs(segs) do
                    platform_segments[#platform_segments + 1] = seg
                end
            end
        else
            local w = room_data.w_px or 1024
            local h = room_data.h_px or 1024
            local x0 = base_x
            local y0 = base_y
            local x1 = base_x + w
            local y1 = base_y + h

            log.debug("Room %s: missing shape; using bounds (%.1f, %.1f) -> (%.1f, %.1f)", room_id, x0, y0, x1, y1)

            include_rect(x0, y0, x1, y1)

            room_polys[#room_polys + 1] = {
                { x = x0, y = y0 },
                { x = x1, y = y0 },
                { x = x1, y = y1 },
                { x = x0, y = y1 },
            }

            local poly_loop = {
                { x = x0, y = y0 },
                { x = x1, y = y0 },
                { x = x1, y = y1 },
                { x = x0, y = y1 },
                { x = x0, y = y0 },
            }

            for i = 1, #poly_loop - 1 do
                local p1 = poly_loop[i]
                local p2 = poly_loop[i + 1]
                outlines[#outlines + 1] = { x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y }
                include_point(p1.x, p1.y)
                include_point(p2.x, p2.y)
            end
        end
        local tiled_path = room_data.tilemap_path and room_data.tilemap_path:gsub("%.tilemap$", ".lua")
            or (StreamPaths.tiled_maps_dir() .. "/" .. room_id .. ".lua")
        room_polys[#room_polys].fill_color = room_data.map_properties and MapColors.resolve(room_data.map_properties)
            or MapColors.from_tiled(opts.root .. "/" .. tiled_path:gsub("^/", ""))
    end
    if #outlines == 0 then
        log.debug("ERROR: No room geometry to draw")
        error("No room geometry to draw")
        return
    end

    if min_x == math.huge or min_y == math.huge then
        log.debug("ERROR: Unable to compute minimap bounds")
        error("Unable to compute minimap bounds")
        return
    end

    local tile_w_ref = base_tile_w or project_tile_width()
    local tile_h_ref = base_tile_h or project_tile_height()

    local pad_tiles_x = 0.5
    local pad_tiles_y = 0.5
    local pad_x = tile_w_ref * pad_tiles_x
    local pad_y = tile_h_ref * pad_tiles_y
    local padding_world = math.max(pad_x, pad_y)

    min_x = min_x - pad_x
    min_y = min_y - pad_y
    max_x = max_x + pad_x
    max_y = max_y + pad_y

    local snap_x = tile_w_ref * 0.5
    local snap_y = tile_h_ref * 0.5
    if snap_x > 0 then
        min_x = math.floor(min_x / snap_x) * snap_x
        max_x = math.ceil(max_x / snap_x) * snap_x
    end
    if snap_y > 0 then
        min_y = math.floor(min_y / snap_y) * snap_y
        max_y = math.ceil(max_y / snap_y) * snap_y
    end

    local world_w = math.max(max_x - min_x, 1)
    local world_h = math.max(max_y - min_y, 1)
    local target_max = 1024

    local span_tiles_x = math.max(1, math.ceil(world_w / tile_w_ref))
    local span_tiles_y = math.max(1, math.ceil(world_h / tile_h_ref))

    local pixels_per_tile = math.min(
        math.floor(target_max / span_tiles_x),
        math.floor(target_max / span_tiles_y)
    )
    if pixels_per_tile < 1 then pixels_per_tile = 1 end
    if pixels_per_tile % 2 == 1 and pixels_per_tile > 1 then
        pixels_per_tile = pixels_per_tile - 1
    end
    if pixels_per_tile < 1 then pixels_per_tile = 1 end

    local width = math.max(1, span_tiles_x * pixels_per_tile)
    local height = math.max(1, span_tiles_y * pixels_per_tile)
    local scale_x = width / world_w
    local scale_y = height / world_h

    log.debug("World bounds: (%.1f,%.1f) to (%.1f,%.1f)", min_x, min_y, max_x, max_y)
    log.debug("Image size: %dx%d, tile_px=%d, scale=(%.5f,%.5f)", width, height, pixels_per_tile, scale_x, scale_y)
    print(string.format('[MINIMAP_EXPORT] Bounds=(%.1f,%.1f)-(%.1f,%.1f) image=%dx%d px_per_tile=%d scale=(%.5f,%.5f)', min_x, min_y, max_x, max_y, width, height, pixels_per_tile, scale_x, scale_y))
    local function world_to_pixel(wx, wy)
        local px = (wx - min_x) * scale_x
        local py = (wy - min_y) * scale_y
        return px, py
    end

    local pixels = {}
    for i = 1, width * height * 4 do
        pixels[i] = 0
    end

    progress("Rasterizing rooms (this may take a moment)…")
    local outline_px = {}
    for _, seg in ipairs(outlines) do
        local x0, y0 = world_to_pixel(seg.x1, seg.y1)
        local x1, y1 = world_to_pixel(seg.x2, seg.y2)
        outline_px[#outline_px + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end

    local pixel_polys = {}
    for _, poly_world in ipairs(room_polys) do
        if poly_world and #poly_world >= 3 then
            local poly_px = {fill_color = poly_world.fill_color}
            for i = 1, #poly_world do
                local p = poly_world[i]
                local px, py = world_to_pixel(p.x, p.y)
                poly_px[i] = { x = px, y = py }
            end
            pixel_polys[#pixel_polys + 1] = poly_px
        end
    end

    local function point_in_poly(px, py, poly)
        local inside = false
        local n = #poly
        if n < 3 then return false end
        local j = n
        local EPS = 1e-6
        for i = 1, n do
            local pi = poly[i]
            local pj = poly[j]
            local xi, yi = pi.x, pi.y
            local xj, yj = pj.x, pj.y
            if ((yi > py) ~= (yj > py)) then
                local denom = (yj - yi)
                if math.abs(denom) < 1e-9 then
                    denom = denom >= 0 and 1e-9 or -1e-9
                end
                local x_intersect = (py - yi) * (xj - xi) / denom + xi
                if px <= x_intersect + EPS then inside = not inside end
            end
            j = i
        end
        return inside
    end

    -- Expanded supersampling grid (center, corners, edge midpoints) to keep sloped edges consistent
    local coverage_samples = {
        { 0.5, 0.5 },
        { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.25, 0.75 }, { 0.75, 0.75 },
        { 0.5, 0.25 }, { 0.5, 0.75 }, { 0.25, 0.5 }, { 0.75, 0.5 },
    }
    local sample_count = #coverage_samples

    for _, poly_px in ipairs(pixel_polys) do
        local fill_color = poly_px.fill_color
        local inv_fill_alpha = fill_color[4] > 0 and (1 / fill_color[4]) or 0
        local min_px, max_px = math.huge, -math.huge
        local min_py, max_py = math.huge, -math.huge
        for i = 1, #poly_px do
            local p = poly_px[i]
            if p.x < min_px then min_px = p.x end
            if p.x > max_px then max_px = p.x end
            if p.y < min_py then min_py = p.y end
            if p.y > max_py then max_py = p.y end
        end
        local start_y = math.ceil(min_py - 0.5)
        local end_y = math.floor(max_py - 0.5)
        if start_y < 0 then start_y = 0 end
        if end_y >= height then end_y = height - 1 end
        if start_y <= end_y then
            for py = start_y, end_y do
                local row_base = py * width * 4
                local start_x = math.ceil(min_px - 0.5)
                local end_x = math.floor(max_px - 0.5)
                if start_x < 0 then start_x = 0 end
                if end_x >= width then end_x = width - 1 end
                if start_x <= end_x then
                    for px = start_x, end_x do
                        local coverage = 0
                        for i_sample = 1, sample_count do
                            local sample = coverage_samples[i_sample]
                            if point_in_poly(px + sample[1], py + sample[2], poly_px) then
                                coverage = coverage + 1
                            end
                        end
                        if coverage > 0 then
                            local coverage_norm = coverage / sample_count
                            local idx = row_base + px * 4
                            local should_update = true
                            if inv_fill_alpha > 0 then
                                local existing_alpha = pixels[idx + 4] or 0
                                local existing_coverage = existing_alpha * inv_fill_alpha
                                if coverage_norm <= existing_coverage + 1e-4 then
                                    should_update = false
                                end
                            end
                            if should_update then
                                pixels[idx + 1] = math.floor(fill_color[1] * coverage_norm + 0.5)
                                pixels[idx + 2] = math.floor(fill_color[2] * coverage_norm + 0.5)
                                pixels[idx + 3] = math.floor(fill_color[3] * coverage_norm + 0.5)
                                pixels[idx + 4] = math.floor(fill_color[4] * coverage_norm + 0.5)
                            end
                        end
                    end
                end
            end
        end
    end
    local function normalize_thickness(px)
        local n = tonumber(px)
        if not n then return 1 end
        n = math.max(1, math.floor(n + 0.5))
        if n % 2 == 0 then
            n = n + 1  -- keep stroke centered on pixels
        end
        return n
    end

    progress("Drawing outlines and features…")
    local outline_color = { 210, 238, 255, 255 }
    local outline_thickness = normalize_thickness((MINIMAP_CFG and (MINIMAP_CFG.export_outline_px or MINIMAP_CFG.outline_px)) or 3)
    for _, seg in ipairs(outline_px) do
        PngWriter.draw_line(pixels, width, height, seg.x0, seg.y0, seg.x1, seg.y1, outline_color, outline_thickness)
    end
    if #platform_segments > 0 then
        local platform_color = { 180, 255, 255, 255 }
        local platform_thickness = normalize_thickness(math.max((MINIMAP_CFG and MINIMAP_CFG.platform_thickness) or 0, 3))
        for _, seg in ipairs(platform_segments) do
            local x0, y0 = world_to_pixel(seg.x1, seg.y1)
            local x1, y1 = world_to_pixel(seg.x2, seg.y2)
            PngWriter.draw_line(pixels, width, height, x0, y0, x1, y1, platform_color, platform_thickness)
        end
    end

    if #door_segments > 0 then
        local door_color = { 255, 240, 96, 255 }
        local locked_color = { 255, 96, 96, 255 }
        local door_thickness = normalize_thickness(math.max((MINIMAP_CFG and MINIMAP_CFG.doors and MINIMAP_CFG.doors.thickness) or 0, 3))
        for _, seg in ipairs(door_segments) do
            local x0, y0 = world_to_pixel(seg.x1, seg.y1)
            local x1, y1 = world_to_pixel(seg.x2, seg.y2)
            local color = (seg.state == "locked") and locked_color or door_color
            PngWriter.draw_line(pixels, width, height, x0, y0, x1, y1, color, door_thickness)
        end
    end

    progress("Encoding PNG image…")
    local pixel_bytes = PngWriter.buffer_to_bytes(pixels)
    log.debug("Pixel buffer size: %d bytes", #pixel_bytes)

    local png_data = PngWriter.encode_png(width, height, pixel_bytes)
    log.debug("PNG data size: %d bytes", #png_data)
    progress("Writing files to disk…")

    local root = opts.root
    local updated_atlas_content = [[animations { id: "updated_map" images { image: "/developer/assets/minimap/updated_map.png" } playback: PLAYBACK_NONE fps: 1 }
margin: 0
]]
    local meta_content = string.format([[return {
  world_name = %q,
  width = %d,
  height = %d,
  world_min = { x = %.4f, y = %.4f },
  world_max = { x = %.4f, y = %.4f },
  scale = { x = %.6f, y = %.6f },
  padding_world = %.4f,
}
]], opts.world_name or "", width, height, min_x, min_y, max_x, max_y, scale_x, scale_y, padding_world)
    return {width=width,height=height,files={
        {path="assets/minimap/layout_map.png",content=png_data},
        {path="assets/minimap/updated_map.png",content=png_data},
        {path="assets/minimap/updated_map.atlas",content=updated_atlas_content},
        {path="assets/minimap/layout_map.lua",content=meta_content},
        {path="assets/minimap/updated_map.lua",content=meta_content},
    }}
end
return M
