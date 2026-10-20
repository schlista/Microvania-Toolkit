#!/usr/bin/env lua

local function dirname(path)
    return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local function join_path(a, b)
    if not a or a == "" or a == "." then
        return b
    end
    local last = a:sub(-1)
    if last == "/" or last == "\\" then
        return a .. b
    end
    return a .. "/" .. b
end

local function file_exists(path)
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function read_file(path, mode)
    local fh, err = io.open(path, mode or "rb")
    if not fh then
        return nil, err
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function write_file(path, data, mode)
    local fh, err = io.open(path, mode or "wb")
    if not fh then
        return nil, err
    end
    if package.loaded["hooks.core.io_stats"] then package.loaded["hooks.core.io_stats"].add("raw_writes") end
    fh:write(data)
    fh:close()
    return true
end

local function ensure_dir(path)
    local sep = package.config:sub(1, 1)
    local cmd
    if sep == "\\" then
        local win_path = path:gsub("/", "\\")
        cmd = string.format('cmd /c if not exist "%s" mkdir "%s"', win_path, win_path)
    else
        cmd = string.format('mkdir -p "%s"', path)
    end
    return os.execute(cmd)
end

local function script_dir_from_arg0()
    local arg0 = (arg and arg[0]) or ""
    return dirname(arg0)
end

local function resolve_project_root()
    local script_dir = script_dir_from_arg0()
    local project_root = script_dir:gsub("[/\\]developer[/\\]tools$", "")
    if project_root == script_dir then
        return "."
    end
    return project_root
end

local PROJECT_ROOT = resolve_project_root()
package.path = join_path(PROJECT_ROOT, "?.lua") .. ";" .. join_path(PROJECT_ROOT, "?/init.lua") .. ";" .. package.path
local adler32 = require("mvtk.core.adler32").checksum
local TileSettingsWriter = require "mvtk.editor.tile_settings_writer"
local MapColors = require "developer.tools.map_colors"

local tile_validation = TileSettingsWriter.validate_consistency({
    root = PROJECT_ROOT,
    maps_dir = join_path(PROJECT_ROOT, "developer/assets/tiled/maps"),
    tilemaps_dir = join_path(PROJECT_ROOT, "developer/assets/tiled/maps"),
    tilesheets_dir = join_path(PROJECT_ROOT, "developer/assets/tilesheets"),
    tile_settings_path = join_path(PROJECT_ROOT, "developer/config/tile_settings.lua"),
    require_tile_settings_match = true,
})
if not tile_validation.ok then
    io.stderr:write("Tile-size consistency check failed; minimap regeneration aborted.\n")
    for _, message in ipairs(TileSettingsWriter.format_validation_messages(tile_validation)) do
        io.stderr:write("  - " .. tostring(message) .. "\n")
    end
    io.stderr:write("Run Prepare & Check to regenerate developer/config/tile_settings.lua from imported art.\n")
    os.exit(1)
end

local TILE = dofile(join_path(PROJECT_ROOT, "developer/config/tile_settings.lua"))
local TILE_W = tonumber(TILE.width) or 128
local TILE_H = tonumber(TILE.height) or TILE_W
local TARGET_MAX = 1024

local function parse_args()
    local opts = {
        layout = join_path(PROJECT_ROOT, "developer/runtime/layout/world_layout.local.lua"),
        fallback_layout = join_path(PROJECT_ROOT, "export/developer/runtime/layout/world_layout.lua"),
        out_dir = join_path(PROJECT_ROOT, "developer/assets/minimap"),
    }
    local i = 1
    while arg and i <= #arg do
        local a = arg[i]
        if a == "--layout" and arg[i + 1] then
            opts.layout = arg[i + 1]
            i = i + 1
        elseif a == "--out-dir" and arg[i + 1] then
            opts.out_dir = arg[i + 1]
            i = i + 1
        elseif a == "--help" or a == "-h" then
            opts.help = true
        end
        i = i + 1
    end
    return opts
end

local function normalize_room_id(room)
    local id = room.id
    if id and id ~= "" then
        return tostring(id)
    end
    local path = room.path or ""
    path = tostring(path):gsub("^developer/rooms/", "")
    path = path:gsub("%.collection$", "")
    return path
end

local function room_tilemap_path(room_id)
    return join_path(PROJECT_ROOT, string.format("developer/assets/tiled/maps/%s.tilemap", room_id))
end

local function parse_bounds_cells(tilemap_path)
    local text, err = read_file(tilemap_path, "rb")
    if not text then
        return nil, err
    end

    local cells = {}
    local current_layer = nil
    local in_cell = false
    local cell_x, cell_y = nil, nil

    for line in text:gmatch("[^\r\n]+") do
        local layer_id = line:match('^%s*id:%s*"([^"]+)"')
        if layer_id then
            current_layer = layer_id
        elseif line:match('^%s*layers%s*{') then
            current_layer = nil
        end

        if current_layer == "bounds" then
            if line:match('^%s*cell%s*{') then
                in_cell = true
                cell_x, cell_y = nil, nil
            elseif in_cell then
                local x = line:match('^%s*x:%s*(-?%d+)')
                if x then
                    cell_x = tonumber(x)
                end
                local y = line:match('^%s*y:%s*(-?%d+)')
                if y then
                    cell_y = tonumber(y)
                end
                local tile = line:match('^%s*tile:%s*(-?%d+)')
                if tile then
                    tile = tonumber(tile)
                    if tile and tile >= 0 and cell_x and cell_y then
                        cells[#cells + 1] = { x = cell_x, y = cell_y }
                    end
                elseif line:match('^%s*}%s*$') then
                    in_cell = false
                end
            end
        end
    end

    return cells
end

local function key_xy(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

local function build_room_occupancy(room, bounds_cells)
    local min_tx, min_ty, max_tx, max_ty = nil, nil, nil, nil
    for _, cell in ipairs(bounds_cells or {}) do
        if not min_tx or cell.x < min_tx then min_tx = cell.x end
        if not max_tx or cell.x > max_tx then max_tx = cell.x end
        if not min_ty or cell.y < min_ty then min_ty = cell.y end
        if not max_ty or cell.y > max_ty then max_ty = cell.y end
    end

    if not min_tx then
        min_tx = 0
        min_ty = 0
        max_tx = math.max(0, math.floor(((tonumber(room.w) or TILE_W) / TILE_W) + 0.5) - 1)
        max_ty = math.max(0, math.floor(((tonumber(room.h) or TILE_H) / TILE_H) + 0.5) - 1)
    end

    local width_cells = math.max(1, max_tx - min_tx + 1)
    local height_cells = math.max(1, max_ty - min_ty + 1)
    local boundary = {}

    for _, cell in ipairs(bounds_cells or {}) do
        boundary[key_xy(cell.x - min_tx, cell.y - min_ty)] = true
    end

    local occupied = {}
    if next(boundary) == nil then
        for y = 0, height_cells - 1 do
            for x = 0, width_cells - 1 do
                occupied[key_xy(x, y)] = true
            end
        end
        return {
            min_tx = min_tx,
            min_ty = min_ty,
            width_cells = width_cells,
            height_cells = height_cells,
            occupied = occupied,
        }
    end

    local function expanded_key(x, y)
        return tostring(x) .. "," .. tostring(y)
    end

    local visited = {}
    local queue_x, queue_y = { 0 }, { 0 }
    local head, tail = 1, 1
    visited[expanded_key(0, 0)] = true
    local dirs = {
        { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    }

    while head <= tail do
        local ex = queue_x[head]
        local ey = queue_y[head]
        head = head + 1

        for _, dir in ipairs(dirs) do
            local nx = ex + dir[1]
            local ny = ey + dir[2]
            if nx >= 0 and nx <= width_cells + 1 and ny >= 0 and ny <= height_cells + 1 then
                local ek = expanded_key(nx, ny)
                if not visited[ek] then
                    local cell_x = nx - 1
                    local cell_y = ny - 1
                    local blocked = false
                    if cell_x >= 0 and cell_x < width_cells and cell_y >= 0 and cell_y < height_cells then
                        blocked = boundary[key_xy(cell_x, cell_y)] == true
                    end
                    if not blocked then
                        visited[ek] = true
                        tail = tail + 1
                        queue_x[tail] = nx
                        queue_y[tail] = ny
                    end
                end
            end
        end
    end

    for y = 0, height_cells - 1 do
        for x = 0, width_cells - 1 do
            local k = key_xy(x, y)
            if boundary[k] or not visited[expanded_key(x + 1, y + 1)] then
                occupied[k] = true
            end
        end
    end

    return {
        min_tx = min_tx,
        min_ty = min_ty,
        width_cells = width_cells,
        height_cells = height_cells,
        occupied = occupied,
    }
end

local function build_fill_runs(shape)
    local runs = {}
    for y = 0, shape.height_cells - 1 do
        local x = 0
        while x < shape.width_cells do
            local key = key_xy(x, y)
            if shape.occupied[key] then
                local x0 = x
                while x + 1 < shape.width_cells and shape.occupied[key_xy(x + 1, y)] do
                    x = x + 1
                end
                runs[#runs + 1] = { x0 = x0, x1 = x, y = y }
            end
            x = x + 1
        end
    end
    return runs
end

local function build_outline_segments(shape, room_left, room_bottom)
    local segments = {}
    local function has_cell(x, y)
        if x < 0 or x >= shape.width_cells or y < 0 or y >= shape.height_cells then
            return false
        end
        return shape.occupied[key_xy(x, y)] == true
    end

    for y = 0, shape.height_cells - 1 do
        for x = 0, shape.width_cells - 1 do
            if has_cell(x, y) then
                local world_x = room_left + (x * TILE_W)
                local world_y = room_bottom + (y * TILE_H)
                if not has_cell(x - 1, y) then
                    segments[#segments + 1] = { x0 = world_x, y0 = world_y, x1 = world_x, y1 = world_y + TILE_H }
                end
                if not has_cell(x + 1, y) then
                    segments[#segments + 1] = { x0 = world_x + TILE_W, y0 = world_y, x1 = world_x + TILE_W, y1 = world_y + TILE_H }
                end
                if not has_cell(x, y - 1) then
                    segments[#segments + 1] = { x0 = world_x, y0 = world_y, x1 = world_x + TILE_W, y1 = world_y }
                end
                if not has_cell(x, y + 1) then
                    segments[#segments + 1] = { x0 = world_x, y0 = world_y + TILE_H, x1 = world_x + TILE_W, y1 = world_y + TILE_H }
                end
            end
        end
    end

    return segments
end

local function room_left_bottom(room)
    local left = (tonumber(room.x) or 0) + (tonumber(room.ox) or 0)
    local bottom = (tonumber(room.y) or 0) + (tonumber(room.oy) or 0)
    return left, bottom
end

local function collect_geometry(layout)
    local room_shapes = {}
    local fill_runs = {}
    local outlines = {}
    local doors = {}
    local min_x, min_y = math.huge, math.huge
    local max_x, max_y = -math.huge, -math.huge

    local function include_rect(x0, y0, x1, y1)
        if x0 < min_x then min_x = x0 end
        if y0 < min_y then min_y = y0 end
        if x1 > max_x then max_x = x1 end
        if y1 > max_y then max_y = y1 end
    end

    for _, room in ipairs(layout.rooms or {}) do
        local room_id = normalize_room_id(room)
        local left, bottom = room_left_bottom(room)

        local bounds_cells = {}
        local tilemap_path = room_tilemap_path(room_id)
        if file_exists(tilemap_path) then
            local parsed = parse_bounds_cells(tilemap_path)
            if parsed then
                bounds_cells = parsed
            end
        end

        local shape = build_room_occupancy(room, bounds_cells)
        local width = shape.width_cells * TILE_W
        local height = shape.height_cells * TILE_H
        include_rect(left, bottom, left + width, bottom + height)
        room_shapes[#room_shapes + 1] = { id = room_id, left = left, bottom = bottom, shape = shape }

        local runs = build_fill_runs(shape)
        local fill_color = MapColors.from_tiled(room_tilemap_path(room_id):gsub("%.tilemap$", ".lua"), layout.world_properties)
        for _, run in ipairs(runs) do
            fill_runs[#fill_runs + 1] = {
                color = fill_color,
                x = left + (run.x0 * TILE_W),
                y = bottom + (run.y * TILE_H),
                w = (run.x1 - run.x0 + 1) * TILE_W,
                h = TILE_H,
            }
        end

        local room_outlines = build_outline_segments(shape, left, bottom)
        for _, seg in ipairs(room_outlines) do
            outlines[#outlines + 1] = seg
        end

        for _, door in ipairs(room.doors or {}) do
            local side = door.side
            local cx = tonumber(door.cx) or 0
            local cy = tonumber(door.cy) or 0
            local len = tonumber(door.len) or TILE_H
            local world_cx = left + cx
            local world_cy = bottom + cy
            if side == "left" or side == "right" then
                doors[#doors + 1] = {
                    x0 = world_cx,
                    y0 = world_cy - (len * 0.5),
                    x1 = world_cx,
                    y1 = world_cy + (len * 0.5),
                }
            else
                doors[#doors + 1] = {
                    x0 = world_cx - (len * 0.5),
                    y0 = world_cy,
                    x1 = world_cx + (len * 0.5),
                    y1 = world_cy,
                }
            end
        end
    end

    if min_x == math.huge or min_y == math.huge then
        return nil, "no rooms in layout"
    end

    return {
        fill_runs = fill_runs,
        outlines = outlines,
        doors = doors,
        min_x = min_x,
        min_y = min_y,
        max_x = max_x,
        max_y = max_y,
        room_shapes = room_shapes,
    }
end

local function u32be(n)
    n = n % 4294967296
    local b1 = math.floor(n / 16777216) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 256) % 256
    local b4 = n % 256
    return string.char(b1, b2, b3, b4)
end

local function u16le(n)
    n = n % 65536
    local b1 = n % 256
    local b2 = math.floor(n / 256) % 256
    return string.char(b1, b2)
end

local CRC32_TABLE = nil
local POLY = 0xEDB88320

local function bxor(a, b)
    a = a % 4294967296
    b = b % 4294967296
    local result = 0
    local bit = 1
    while a > 0 or b > 0 do
        local abit = a % 2
        local bbit = b % 2
        if abit ~= bbit then
            result = result + bit
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
    end
    return result % 4294967296
end

local function rshift(value, bits)
    return math.floor((value % 4294967296) / (2 ^ bits))
end

local function crc32_init()
    CRC32_TABLE = {}
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if crc % 2 == 1 then
                crc = bxor(POLY, rshift(crc, 1))
            else
                crc = rshift(crc, 1)
            end
        end
        CRC32_TABLE[i] = crc
    end
end

local function crc32(bytes)
    if not CRC32_TABLE then
        crc32_init()
    end
    local crc = 0xFFFFFFFF
    for i = 1, #bytes do
        local byte = bytes:byte(i)
        local index = bxor(crc, byte) % 256
        crc = bxor(CRC32_TABLE[index], rshift(crc, 8))
    end
    return bxor(crc, 0xFFFFFFFF) % 4294967296
end

local function zlib_stored(data)
    local chunks = {}
    local total = #data
    local pos = 1
    while pos <= total do
        local size = math.min(65535, total - pos + 1)
        local last = (pos + size - 1 == total) and 1 or 0
        local block = {
            string.char(last),
            u16le(size),
            u16le(0xFFFF - size),
            data:sub(pos, pos + size - 1),
        }
        chunks[#chunks + 1] = table.concat(block)
        pos = pos + size
    end
    local body = table.concat(chunks)
    return string.char(0x78, 0x01) .. body .. u32be(adler32(data))
end

local function buffer_to_bytes(buf)
    local parts = {}
    local chunk = {}
    for i = 1, #buf do
        chunk[#chunk + 1] = string.char(buf[i] or 0)
        if #chunk >= 4096 then
            parts[#parts + 1] = table.concat(chunk)
            chunk = {}
        end
    end
    if #chunk > 0 then
        parts[#parts + 1] = table.concat(chunk)
    end
    return table.concat(parts)
end

local function encode_png(width, height, pixel_bytes)
    local signature = "\137PNG\r\n\026\n"
    local chunks = { signature }
    local function append_chunk(ctype, data)
        chunks[#chunks + 1] = u32be(#data) .. ctype .. data .. u32be(crc32(ctype .. data))
    end
    local ihdr = u32be(width) .. u32be(height) .. string.char(8, 6, 0, 0, 0)
    append_chunk("IHDR", ihdr)
    local scanlines = {}
    local row_stride = width * 4
    for y = 0, height - 1 do
        local src_row = height - 1 - y
        local start = src_row * row_stride + 1
        local stop = start + row_stride - 1
        scanlines[#scanlines + 1] = string.char(0) .. pixel_bytes:sub(start, stop)
    end
    local raw = table.concat(scanlines)
    append_chunk("IDAT", zlib_stored(raw))
    append_chunk("IEND", "")
    return table.concat(chunks)
end

local function draw_pixel(buf, width, height, x, y, color)
    if x < 0 or y < 0 or x >= width or y >= height then
        return
    end
    local idx = (y * width + x) * 4 + 1
    buf[idx] = color[1]
    buf[idx + 1] = color[2]
    buf[idx + 2] = color[3]
    buf[idx + 3] = color[4]
end

local function draw_rect(buf, width, height, x0, y0, x1, y1, color)
    local sx = math.floor(math.min(x0, x1) + 0.5)
    local ex = math.ceil(math.max(x0, x1) - 0.5)
    local sy = math.floor(math.min(y0, y1) + 0.5)
    local ey = math.ceil(math.max(y0, y1) - 0.5)
    if sx < 0 then sx = 0 end
    if sy < 0 then sy = 0 end
    if ex >= width then ex = width - 1 end
    if ey >= height then ey = height - 1 end
    for py = sy, ey do
        for px = sx, ex do
            draw_pixel(buf, width, height, px, py, color)
        end
    end
end

local function draw_line(buf, width, height, x0, y0, x1, y1, color, thickness)
    thickness = math.max(1, math.floor(thickness or 1))
    x0 = math.floor(x0 + 0.5)
    y0 = math.floor(y0 + 0.5)
    x1 = math.floor(x1 + 0.5)
    y1 = math.floor(y1 + 0.5)
    local dx = math.abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    local offset_start = -math.floor(thickness / 2)
    local offset_end = math.ceil(thickness / 2) - 1
    local dominant_axis
    if dx == 0 and dy == 0 then
        dominant_axis = nil
    elseif math.abs(dx) >= math.abs(dy) then
        dominant_axis = "horizontal"
    else
        dominant_axis = "vertical"
    end

    local function plot(px, py)
        if dominant_axis == "horizontal" then
            for oy = offset_start, offset_end do
                draw_pixel(buf, width, height, px, py + oy, color)
            end
        elseif dominant_axis == "vertical" then
            for ox = offset_start, offset_end do
                draw_pixel(buf, width, height, px + ox, py, color)
            end
        else
            for ox = offset_start, offset_end do
                for oy = offset_start, offset_end do
                    draw_pixel(buf, width, height, px + ox, py + oy, color)
                end
            end
        end
    end

    while true do
        plot(x0, y0)
        if x0 == x1 and y0 == y1 then
            break
        end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x0 = x0 + sx
        end
        if e2 <= dx then
            err = err + dx
            y0 = y0 + sy
        end
    end
end

local function generate_minimap(layout)
    local geo, err = collect_geometry(layout)
    if not geo then
        return nil, err
    end

    local pad_x = TILE_W * 0.5
    local pad_y = TILE_H * 0.5
    local padding_world = math.max(pad_x, pad_y)

    local min_x = geo.min_x - pad_x
    local min_y = geo.min_y - pad_y
    local max_x = geo.max_x + pad_x
    local max_y = geo.max_y + pad_y

    local snap_x = TILE_W * 0.5
    local snap_y = TILE_H * 0.5
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
    local span_tiles_x = math.max(1, math.ceil(world_w / TILE_W))
    local span_tiles_y = math.max(1, math.ceil(world_h / TILE_H))

    local pixels_per_tile = math.min(
        math.floor(TARGET_MAX / span_tiles_x),
        math.floor(TARGET_MAX / span_tiles_y)
    )
    if pixels_per_tile < 1 then
        pixels_per_tile = 1
    end
    if pixels_per_tile % 2 == 1 and pixels_per_tile > 1 then
        pixels_per_tile = pixels_per_tile - 1
    end
    if pixels_per_tile < 1 then
        pixels_per_tile = 1
    end

    local width = math.max(1, span_tiles_x * pixels_per_tile)
    local height = math.max(1, span_tiles_y * pixels_per_tile)
    local scale_x = width / world_w
    local scale_y = height / world_h

    local function world_to_pixel(wx, wy)
        return (wx - min_x) * scale_x, (wy - min_y) * scale_y
    end

    local pixels = {}
    for i = 1, width * height * 4 do
        pixels[i] = 0
    end

    local outline_color = { 210, 238, 255, 255 }
    local door_color = { 255, 240, 96, 255 }

    for _, rect in ipairs(geo.fill_runs) do
        local x0, y0 = world_to_pixel(rect.x, rect.y)
        local x1, y1 = world_to_pixel(rect.x + rect.w, rect.y + rect.h)
        draw_rect(pixels, width, height, x0, y0, x1, y1, rect.color)
    end

    for _, seg in ipairs(geo.outlines) do
        local x0, y0 = world_to_pixel(seg.x0, seg.y0)
        local x1, y1 = world_to_pixel(seg.x1, seg.y1)
        draw_line(pixels, width, height, x0, y0, x1, y1, outline_color, 3)
    end

    for _, seg in ipairs(geo.doors) do
        local x0, y0 = world_to_pixel(seg.x0, seg.y0)
        local x1, y1 = world_to_pixel(seg.x1, seg.y1)
        draw_line(pixels, width, height, x0, y0, x1, y1, door_color, 3)
    end

    local pixel_bytes = buffer_to_bytes(pixels)
    local png_data = encode_png(width, height, pixel_bytes)
    local meta = string.format([[return {
  world_name = %q,
  width = %d,
  height = %d,
  world_min = { x = %.4f, y = %.4f },
  world_max = { x = %.4f, y = %.4f },
  scale = { x = %.6f, y = %.6f },
  padding_world = %.4f,
}
]], (layout.world_properties or {}).world_name or "", width, height, min_x, min_y, max_x, max_y, scale_x, scale_y, padding_world)

    return {
        png_data = png_data,
        meta = meta,
        width = width,
        height = height,
        world_min_x = min_x,
        world_min_y = min_y,
        world_max_x = max_x,
        world_max_y = max_y,
        scale_x = scale_x,
        scale_y = scale_y,
    }
end

local function load_layout(layout_path, fallback_path)
    local path = layout_path
    if not file_exists(path) and fallback_path and file_exists(fallback_path) then
        path = fallback_path
    end
    if not file_exists(path) then
        return nil, string.format("layout file not found: %s", tostring(layout_path))
    end
    local ok, data = pcall(dofile, path)
    if not ok then
        return nil, data
    end
    if type(data) ~= "table" or type(data.rooms) ~= "table" then
        return nil, "layout file did not return a rooms table"
    end
    return data, path
end

local function main()
    local opts = parse_args()
    if opts.help then
        print("Usage: lua developer/tools/regenerate_minimap.lua [--layout path] [--out-dir path]")
        return 0
    end

    local layout, layout_path_or_err = load_layout(opts.layout, opts.fallback_layout)
    if not layout then
        io.stderr:write("Failed to load layout: " .. tostring(layout_path_or_err) .. "\n")
        return 1
    end

    local result, err = generate_minimap(layout)
    if not result then
        io.stderr:write("Failed to generate minimap: " .. tostring(err) .. "\n")
        return 1
    end

    ensure_dir(opts.out_dir)

    local layout_png = join_path(opts.out_dir, "layout_map.png")
    local layout_meta = join_path(opts.out_dir, "layout_map.lua")
    local updated_png = join_path(opts.out_dir, "updated_map.png")
    local updated_meta = join_path(opts.out_dir, "updated_map.lua")
    local updated_atlas = join_path(opts.out_dir, "updated_map.atlas")
    local updated_atlas_content = [[animations { id: "updated_map" images { image: "/developer/assets/minimap/updated_map.png" } playback: PLAYBACK_NONE fps: 1 }
margin: 0
]]

    assert(write_file(layout_png, result.png_data, "wb"))
    assert(write_file(layout_meta, result.meta, "w"))
    assert(write_file(updated_png, result.png_data, "wb"))
    assert(write_file(updated_meta, result.meta, "w"))
    assert(write_file(updated_atlas, updated_atlas_content, "w"))

    print(string.format(
        "Regenerated minimap from %s -> %s (%dx%d, world=(%.1f,%.1f)-(%.1f,%.1f))",
        layout_path_or_err,
        opts.out_dir,
        result.width,
        result.height,
        result.world_min_x,
        result.world_min_y,
        result.world_max_x,
        result.world_max_y
    ))
    return 0
end

os.exit(main())
