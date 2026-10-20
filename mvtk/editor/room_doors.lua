-- mvtk/editor/room_doors.lua

--scriptname: /mvtk/editor/room_doors.lua
-- Door extractor (rollback z17rb): geometry pre-inset matches earlier working build.
-- Base inset = 0.5 * bar_px (bar_px = outline_thick_px * thickness_scale).
-- Extra inset = S.door.door_position_offset (pixels, positive = toward interior).
-- This reproduces logs like: base=3.00 when outline=6, scale=1.0.
-- 2025-09-01 (z17rb)

local function create(S, LockCfg, Tile)
local function logf(fmt, ...)
    if LockCfg and LockCfg.debug and LockCfg.debug.prints then
        print(string.format("[LE.Doors] " .. fmt, ...))
    end
end

local outline_px = 6
local bar_scale  = 1.0
local seam_bias  = 0
local door_offset = 0

if S.preview and type(S.preview.outline_thick_px) == "number" then outline_px = S.preview.outline_thick_px end
if S.door and type(S.door.thickness_scale) == "number" then bar_scale  = S.door.thickness_scale end
if S.door and type(S.door.seam_bias_px)    == "number" then seam_bias  = S.door.seam_bias_px end
if S.door and type(S.door.door_position_offset) == "number" then door_offset = S.door.door_position_offset end


local bar_px      = outline_px * bar_scale
local base_inset  = 0.5 * bar_px             -- earlier working formula (yields 3.0 with defaults)
local extra_inset = door_offset               -- door-specific positioning offset (independent of walls)
local total_inset = base_inset + extra_inset

logf("door positioning: outline=%.2f bar_scale=%.2f bar_px=%.2f base=%.2f extra=%.2f total=%.2f seam_bias=%.2f",
     outline_px, bar_scale, bar_px, base_inset, extra_inset, total_inset, seam_bias)

local Doors = {}

local function load_text(path)
    local ok, txt = pcall(sys.load_resource, path)
    if ok and type(txt) == "string" and #txt > 0 then return txt end
    logf("[dbg] sys.load_resource failed/empty: %s", tostring(path))
    return nil
end

local function each_block(src, head) return src:gmatch(head .. "%s*%b{}") end

local function _norm_id(id)
    local s = (id or ""):lower()
    s = s:gsub("[%s%-]+", "_"):gsub("__+", "_")
    return s
end

local function _canonical_side(nid)
    if nid:match("^doors?_left$")  or nid:match("^left_doors?$")  or nid=="door_l" then return "left" end
    if nid:match("^doors?_right$") or nid:match("^right_doors?$") or nid=="door_r" then return "right" end
    if nid:match("^doors?_up$")    or nid:match("^up_doors?$")    or nid:match("^doors?_top$") or nid=="door_u" then return "up" end
    if nid:match("^doors?_down$")  or nid:match("^down_doors?$")  or nid:match("^doors?_bottom$") or nid=="door_d" then return "down" end
    return nil
end

local function parse_cells(block_text)
    local cells = {}
    for c in block_text:gmatch("cell%s*%b{}") do
        local x = tonumber(c:match("x:%s*(-?%d+)"))
        local y = tonumber(c:match("y:%s*(-?%d+)"))
        -- In Defold's .tilemap text format, every `cell {}` block is a painted
        -- tile and `tile:` is a 0-based index (0 = first tile of the tilesource,
        -- i.e. Tiled gid 1). Do NOT treat tile==0 as empty: door-marker tiles
        -- authored with the first tile of a sheet export as `tile: 0` and would
        -- otherwise be dropped, hiding the door entirely.
        if x and y then cells[#cells+1] = { x=x, y=y } end
    end
    return cells
end

local function bounds_bbox(text)
    local minx, miny = math.huge, math.huge
    local maxx, maxy = -math.huge, -math.huge
    local found = false
    for layer in each_block(text, "layers") do
        local id = (layer:match('id:%s*"(.-)"') or layer:match('name:%s*"(.-)"'))
        if id and _norm_id(id) == "bounds" then
            for c in layer:gmatch("cell%s*%b{}") do
                local x = tonumber(c:match("x:%s*(-?%d+)"))
                local y = tonumber(c:match("y:%s*(-?%d+)"))
                -- Every present cell is a real tile; tile index 0 is valid
                -- (see parse_cells). Bounds tiles are commonly the first sheet
                -- tile and export as `tile: 0`, so don't filter them out.
                if x and y then
                    found = true
                    if x < minx then minx = x end
                    if y < miny then miny = y end
                    if x > maxx then maxx = x end
                    if y > maxy then maxy = y end
                end
            end
            break
        end
    end
    if not found then return nil end
    return minx, miny, (maxx - minx + 1), (maxy - miny + 1)
end

local function group_runs(sorted_indices)
    local runs, i = {}, 1
    while i <= #sorted_indices do
        local a, j = sorted_indices[i], i
        while j+1 <= #sorted_indices and sorted_indices[j+1] == sorted_indices[j] + 1 do
            j = j + 1
        end
        runs[#runs+1] = { i0 = a, i1 = sorted_indices[j] }
        i = j + 1
    end
    return runs
end

local function rows_with_any(cells, h_cells)
    local mark = {}
    for _,c in ipairs(cells or {}) do
        if c.y >= 0 and (not h_cells or c.y < h_cells) then mark[c.y] = true end
    end
    local rows = {}
    if h_cells then for y=0,h_cells-1 do if mark[y] then rows[#rows+1] = y end end
    else for y,_ in pairs(mark) do rows[#rows+1] = y end; table.sort(rows) end
    return rows
end

local function cols_with_any(cells, w_cells)
    local mark = {}
    for _,c in ipairs(cells or {}) do
        if c.x >= 0 and (not w_cells or c.x < w_cells) then mark[c.x] = true end
    end
    local cols = {}
    if w_cells then for x=0,w_cells-1 do if mark[x] then cols[#cols+1] = x end end
    else for x,_ in pairs(mark) do cols[#cols+1] = x end; table.sort(cols) end
    return cols
end

local function apply_pre_inset(doors, W, H, inset)
    for _,d in ipairs(doors) do
        if d.side == "left"  then d.x0 = d.x0 + inset; d.x1 = d.x1 + inset; d.cx = d.cx + inset end
        if d.side == "right" then d.x0 = d.x0 - inset; d.x1 = d.x1 - inset; d.cx = d.cx - inset end
        if d.side == "up"    then d.y0 = d.y0 - inset; d.y1 = d.y1 - inset; d.cy = d.cy - inset end
        if d.side == "down"  then d.y0 = d.y0 + inset; d.y1 = d.y1 + inset; d.cy = d.cy + inset end
    end
end

function Doors.from_tilemap_text(text, shape)
    if not text or text == "" then return {} end

    local bx, by, bw, bh = bounds_bbox(text)
    local min_cx, min_cy = bx, by
    local w_cells = (shape and shape.w_cells) or bw
    local h_cells = (shape and shape.h_cells) or bh

    local ts = (shape and (shape.tile_h or shape.tile_w)) or Tile.width
    local W  = (shape and shape.w_px) or ((w_cells or 0) * ts)
    local H  = (shape and shape.h_px) or ((h_cells or 0) * ts)
    -- Door centers are derived from door layer tile centers. Apply an inward
    -- pre-inset based on outline thickness plus door_position_offset to keep
    -- the bar aligned to the wall while allowing fine-tuning.
    local offset_bias = 0
    if S.door and type(S.door.door_position_offset)=="number" then
        offset_bias = S.door.door_position_offset
    elseif type(door_offset)=="number" then
        offset_bias = door_offset
    end
    local total_inset = base_inset + offset_bias

    local left_cells, right_cells, up_cells, down_cells = {}, {}, {}, {}
    local unknown = {}

    for layer in each_block(text, "layers") do
        local raw_id = (layer:match('id:%s*"(.-)"') or layer:match('name:%s*"(.-)"'))
        if raw_id then
            local id = _norm_id(raw_id)
            local side = _canonical_side(id)
            if side then
                local raw = parse_cells(layer)
                local out = {}
                for _,c in ipairs(raw) do
                    out[#out+1] = { x = (min_cx and (c.x - min_cx) or c.x), y = (min_cy and (c.y - min_cy) or c.y) }
                end
                if side == "left"  then left_cells  = out end
                if side == "right" then right_cells = out end
                if side == "up"    then up_cells    = out end
                if side == "down"  then down_cells  = out end
            else
                if id:find("door") and id ~= "locked_door" and id ~= "doors_locked" and id ~= "door_locked" then
                    unknown[#unknown+1] = { id = raw_id, norm = id, count = select(2, layer:gsub("cell%s*%b{}", "")) }
                end
            end
        end
    end

    local function report()
        local L,R,U,D = #left_cells, #right_cells, #up_cells, #down_cells
        logf("layers scan: L=%d R=%d U=%d D=%d", L,R,U,D)
        for _,u in ipairs(unknown) do
            logf("NOTE: door-like layer not matched: id='%s' (norm='%s') cells=%s", u.id, u.norm, tostring(u.count))
        end
    end
    report()

    local doors = {}

    if #left_cells > 0 then
        local rows = rows_with_any(left_cells, h_cells)
        for _, run in ipairs(group_runs(rows)) do
            local y0, y1 = run.i0*ts, (run.i1+1)*ts
            -- Find the actual X coordinate of the door cells (already relative to bounds)
            local actual_x = nil
            for _, c in ipairs(left_cells) do
                if c.y >= run.i0 and c.y <= run.i1 then
                    actual_x = c.x * ts + ts * 0.5  -- Use actual door cell X position (already relative)
                    break
                end
            end
            local door_x = actual_x or 0
            doors[#doors+1] = { side="left",  x0=door_x, y0=y0, x1=door_x, y1=y1, cx=door_x, cy=0.5*(y0+y1), len_px=(y1-y0) }
        end
    end

    if #right_cells > 0 then
        local rows = rows_with_any(right_cells, h_cells)
        for _, run in ipairs(group_runs(rows)) do
            local y0, y1 = run.i0*ts, (run.i1+1)*ts
            -- Find the actual X coordinate of the door cells (already relative to bounds)
            local actual_x = nil
            for _, c in ipairs(right_cells) do
                if c.y >= run.i0 and c.y <= run.i1 then
                    actual_x = c.x * ts + ts * 0.5  -- Use actual door cell X position (already relative)
                    break
                end
            end
            local door_x = actual_x or W
            doors[#doors+1] = { side="right", x0=door_x, y0=y0, x1=door_x, y1=y1, cx=door_x, cy=0.5*(y0+y1), len_px=(y1-y0) }
        end
    end

    if #up_cells > 0 then
        local cols = cols_with_any(up_cells, w_cells)
        for _, run in ipairs(group_runs(cols)) do
            local x0, x1 = run.i0*ts, (run.i1+1)*ts
            -- Find the actual Y coordinate of the door cells (already relative to bounds)
            local actual_y = nil
            for _, c in ipairs(up_cells) do
                if c.x >= run.i0 and c.x <= run.i1 then
                    actual_y = c.y * ts + ts * 0.5  -- Use actual door cell Y position (already relative)
                    break
                end
            end
            local door_y = actual_y or H
            doors[#doors+1] = { side="up", x0=x0, y0=door_y, x1=x1, y1=door_y, cx=0.5*(x0+x1), cy=door_y, len_px=(x1-x0) }
        end
    end

    if #down_cells > 0 then
        local cols = cols_with_any(down_cells, w_cells)
        for _, run in ipairs(group_runs(cols)) do
            local x0, x1 = run.i0*ts, (run.i1+1)*ts
            -- Find the actual Y coordinate of the door cells (already relative to bounds)
            local actual_y = nil
            for _, c in ipairs(down_cells) do
                if c.x >= run.i0 and c.x <= run.i1 then
                    actual_y = c.y * ts + ts * 0.5  -- Use actual door cell Y position (already relative)
                    break
                end
            end
            local door_y = actual_y or 0
            doors[#doors+1] = { side="down", x0=x0, y0=door_y, x1=x1, y1=door_y, cx=0.5*(x0+x1), cy=door_y, len_px=(x1-x0) }
        end
    end

    for idx, d in ipairs(doors) do
        if idx <= 2 then
            logf("[dbg] door#%d before inset side=%s  seg=(%.1f,%.1f)-(%.1f,%.1f)", idx, d.side, d.x0, d.y0, d.x1, d.y1)
        end
    end

    if total_inset ~= 0 then
        apply_pre_inset(doors, W, H, total_inset)
    end

    -- Final safety: snap each door center to the nearest colinear outline segment
    -- so render aligns perfectly to the visible wall line even if settings drift.
    local function snap_to_outline()
        local P = (shape and shape.poly) or {}
        if not P or #P < 2 then return end
        local eps = 0.001
        for _,d in ipairs(doors) do
            if d.side == "up" or d.side == "down" then
                local target_y, best_dy = nil, 1e9
                for i=1,#P-1 do
                    local a, b = P[i], P[i+1]
                    if math.abs(a.y - b.y) <= eps then
                        local y = a.y
                        local x0, x1 = math.min(a.x, b.x), math.max(a.x, b.x)
                        if d.cx >= x0 - 0.5 and d.cx <= x1 + 0.5 then
                            local dy = math.abs(y - d.cy)
                            if dy < best_dy then best_dy = dy; target_y = y end
                        end
                    end
                end
                if target_y and math.abs(target_y - d.cy) > 0.01 then
                    logf("snap door(%s) y: %.2f -> %.2f", d.side, d.cy, target_y)
                    d.y0, d.y1, d.cy = target_y, target_y, target_y
                end
            elseif d.side == "left" or d.side == "right" then
                local target_x, best_dx = nil, 1e9
                for i=1,#P-1 do
                    local a, b = P[i], P[i+1]
                    if math.abs(a.x - b.x) <= eps then
                        local x = a.x
                        local y0, y1 = math.min(a.y, b.y), math.max(a.y, b.y)
                        if d.cy >= y0 - 0.5 and d.cy <= y1 + 0.5 then
                            local dx = math.abs(x - d.cx)
                            if dx < best_dx then best_dx = dx; target_x = x end
                        end
                    end
                end
                if target_x and math.abs(target_x - d.cx) > 0.01 then
                    logf("snap door(%s) x: %.2f -> %.2f", d.side, d.cx, target_x)
                    d.x0, d.x1, d.cx = target_x, target_x, target_x
                end
            end
        end
    end
    snap_to_outline()

    for idx, d in ipairs(doors) do
        if idx <= 2 or d.side == "down" then
            logf("[dbg] door#%d AFTER inset (%.2f px) side=%s seg=(%.1f,%.1f)-(%.1f,%.1f)  cx,cy=(%.1f,%.1f)",
                 idx, total_inset, d.side, d.x0, d.y0, d.x1, d.y1, d.cx, d.cy)
        end
    end

    logf("doors found: %d (applied inset = %.2f px toward interior)", #doors, total_inset)
    return doors
end

function Doors.from_tilemap_file(path, shape)
    local text = load_text(path)
    return Doors.from_tilemap_text(text, shape)
end

return Doors
end
local M={with_settings=create}
local function runtime()
    local Util=require "mvtk.core.util"
    return create(Util.require_config("developer.config.layout_editor_settings"),
        Util.require_config("developer.config.locked_door_settings"),Util.require_config("developer.config.tile_settings"))
end
function M.from_tilemap_text(...) return runtime().from_tilemap_text(...) end
function M.from_tilemap_file(...) return runtime().from_tilemap_file(...) end
return M
