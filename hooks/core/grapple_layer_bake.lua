-- Painted grapple tags become editable static room instances, never runtime spawns.
local TilemapRegen = require "mvtk.editor.tilemap_regen"
local M = {}

local function gid(value)
    if type(value) == "table" then value = value.gid or value.tile or value.value end
    return tonumber(value) or 0
end

-- Sparse, one-based row-major data; every nonzero gid counts, including flips.
function M.runs(cells, width)
    local runs = {}
    width = tonumber(width) or 0
    if type(cells) ~= "table" or width < 1 or width ~= math.floor(width) then return runs end
    local last = 0
    for index in pairs(cells) do
        if type(index) == "number" and index > last and index == math.floor(index) then last = index end
    end
    local start, count, row
    local function flush()
        if start then runs[#runs + 1] = { row = row, col = start, count = count } end
        start, count = nil, 0
    end
    for index = 1, last do
        local col = (index - 1) % width
        if col == 0 then flush(); row = math.floor((index - 1) / width) end
        if gid(cells[index]) ~= 0 then
            if not start then start, count = col, 0 end
            count = count + 1
        else flush() end
    end
    flush()
    return runs
end

local function coordinate(value)
    if value == math.floor(value) then return string.format("%d", value) end
    return tostring(value):gsub("%.0+$", "")
end

function M.instance_id(run)
    return "grapple_layer_" .. coordinate(run.row) .. "_" .. coordinate(run.col)
end

-- Combine layers in Tiled pixel coordinates, including inherited offsets.
-- Horizontal intervals at the same height merge regardless of their layer.
function M.collect(map)
    local strips, painted, cell_count = {}, {}, 0
    local tw = tonumber(map and map.tilewidth) or 0
    local th = tonumber(map and map.tileheight) or tw
    local function walk(layers, px, py, pfx, pfy)
        for _, layer in ipairs(layers or {}) do
            if type(layer) == "table" then
                local ox, oy = px + (tonumber(layer.offsetx) or 0), py + (tonumber(layer.offsety) or 0)
                local fx, fy = pfx * (tonumber(layer.parallaxx) or 1), pfy * (tonumber(layer.parallaxy) or 1)
                if layer.type == "group" then
                    walk(layer.layers, ox, oy, fx, fy)
                elseif layer.type == "tilelayer" and TilemapRegen.normalize_layer_name(layer.name) == "grapple" then
                    assert(tw > 0 and th > 0, "Grapple layer requires positive map tile dimensions")
                    assert(map.infinite ~= true and not layer.chunks, "Grapple layers require a finite Tiled map")
                    assert(fx == 1 and fy == 1, "Parallax on grapple gameplay tile layers is unsupported; keep it at 1")
                    local width = tonumber(layer.width) or tonumber(map.width) or 0
                    assert(width > 0 and width == math.floor(width), "Grapple layer requires a positive finite width")
                    local data, err = TilemapRegen.decode_tiled_layer_data(layer, map.room_id, layer.name)
                    assert(type(data) == "table", "Could not decode grapple layer '" .. tostring(layer.name) .. "': " .. tostring(err))
                    local lx, ly = ox + (tonumber(layer.x) or 0) * tw, oy + (tonumber(layer.y) or 0) * th
                    for _, run in ipairs(M.runs(data, width)) do
                        local x, y = lx + run.col * tw, ly + run.row * th
                        strips[#strips + 1] = { x = x, y = y, w = run.count * tw, h = th }
                        for col = 0, run.count - 1 do
                            local key = coordinate(y) .. ":" .. coordinate(x + col * tw)
                            if not painted[key] then painted[key] = true; cell_count = cell_count + 1 end
                        end
                    end
                end
            end
        end
    end
    walk(map and map.layers, 0, 0, 1, 1)
    table.sort(strips, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        if a.x ~= b.x then return a.x < b.x end
        return a.w < b.w
    end)
    local merged = {}
    for _, strip in ipairs(strips) do
        local last = merged[#merged]
        if last and last.y == strip.y and strip.x <= last.x + last.w then
            last.w = math.max(last.x + last.w, strip.x + strip.w) - last.x
        else merged[#merged + 1] = strip end
    end
    for _, run in ipairs(merged) do
        run.row, run.col, run.count = run.y / th, run.x / tw, run.w / tw
    end
    return merged, cell_count
end

function M.append(context, rows, rid, map)
    local runs, cells = M.collect(map)
    local tw = tonumber(map.tilewidth) or 0
    local th = tonumber(map.tileheight) or tw
    local map_height = (tonumber(map.height) or 0) * th
    local seen = {}
    for _, run in ipairs(runs) do
        local id = M.instance_id(run)
        assert(not seen[id], "Duplicate grapple strip coordinates: " .. id)
        seen[id] = true
        local obj = { x = run.x, y = run.y, width = run.w, height = run.h }
        local px, py, _, _, w, h = context.rect_center_and_scale(obj, map_height - obj.y, tw, th, 128, 8, 256, 16)
        local filename = tostring(rid) .. "_" .. id .. ".go"
        assert(context.write_sized_rect_generated_go(context.join(context.PATH.generated_go, filename),
            "/developer/game/prefabs/grapple_surface.go", w, h, 128, 8, 256, 16))
        context.add_prefab_instance(rows, id, "/developer/rooms/generated/" .. filename, px, py)
    end
    context.info(string.format("[CREATE ROOMS] room %s: grapple layer %d cells -> %d strips", tostring(rid), cells, #runs))
    return runs
end

return M
