-- mvtk/developer/rooms/tile_doors.lua

-- Two-layer door scheme:

--   * Every room has: door_left, door_right (and optionally door_top/bottom). Keep them present (can be empty).

--   * You can paint MULTIPLE tiles on each side for multiple doors.

-- This module finds the best (nearest) door pair across a seam AND gives seam edges

-- derived from the door layers themselves (so we can flush without using whole-map bounds).



local Util = require "mvtk.core.util"
local Tile = Util.require_config("developer.config.tile_settings")
local S = Util.require_config("developer.config.stream_settings")
local Config = Util.require_config("developer.config.resolved_config")
local TileFrame = require("mvtk.rooms.tile_frame")
local LockCfg = Util.require_config("developer.config.locked_door_settings")
local Debug = Util.require_config("developer.config.debug_config")

local seam_log = Util.make_debug_log("[SEAM]", function()
    return (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.seam)
        or (LockCfg and LockCfg.debug and LockCfg.debug.prints)
end)

local M = {}

local log = Util.make_debug_log("[DOORS]", function()
    return (Debug.global and Debug.global.enable) or (Debug.rooms and Debug.rooms.door_debug)
end)



local CANDIDATE_COMPONENTS = { "tilemap", "tm", "map" }
local LEVEL_GO_ID = hash("level")

local function is_level_root(go_url)
    if not (go_url and go.exists(go_url)) then return false end
    local ok, id = pcall(go.get_id, go_url)
    if ok and id == LEVEL_GO_ID then
        return true
    end
    local ok_url, u = pcall(msg.url, go_url)
    if ok_url and u and u.path then
        local path = tostring(u.path)
        if path:find("/level") then
            return true
        end
    end
    return false
end

local function resolve_tilemap(go_url)
    if not (go_url and go.exists(go_url)) then return nil, nil end
    local u = msg.url(go_url)
    for _, comp in ipairs(CANDIDATE_COMPONENTS) do
        local tm_url = msg.url(u.socket, u.path, hash(comp))
        local ok = pcall(tilemap.get_bounds, tm_url)
        if ok then
            local pos = go.get_world_position(go_url)
            return tm_url, pos
        end
    end
    return nil, nil
end



local function first_tilemap(created)

	if type(created) ~= "table" then
        local tm_url, pos = resolve_tilemap(created)
        if tm_url and pos then
            log("first_tilemap: single root tilemap %s (pos=%.1f,%.1f)", tostring(tm_url), pos.x, pos.y)
        end
        return tm_url, pos
    end

    local fallback_tm, fallback_pos, fallback_go = nil, nil, nil
    for _, go_url in pairs(created) do
        local tm_url, pos = resolve_tilemap(go_url)
        if tm_url then
            if is_level_root(go_url) then
                log("first_tilemap: picked level tilemap %s (go=%s pos=%.1f,%.1f)", tostring(tm_url), tostring(go_url), pos.x, pos.y)
                return tm_url, pos
            end
            if not fallback_tm then
                fallback_tm, fallback_pos, fallback_go = tm_url, pos, go_url
            end
        end
    end

    if fallback_tm then
        log("first_tilemap: fallback tilemap %s (go=%s pos=%.1f,%.1f)", tostring(fallback_tm), tostring(fallback_go), fallback_pos.x, fallback_pos.y)
    end
    return fallback_tm, fallback_pos

end



-- Scan one layer: return { points = {vec3,...}, edge = number | nil }

-- edge is the extreme world coordinate for that side, computed from the door tiles themselves:

--   left  -> min (center.x - tw/2)

--   right -> max (center.x + tw/2)

--   top   -> max (center.y + th/2)

--   bottom-> min (center.y - th/2)

local function scan_side(frame, side, layer_name)
    local out = { points = {}, edge = nil, frame = frame }
    if not (frame and layer_name and layer_name ~= "") then return out end

    local lh = hash(layer_name)
    if not TileFrame.layer_exists(frame, lh) then
        log("scan_side: skipping missing layer %s on side %s", tostring(layer_name), tostring(side))
        return out
    end

    local function update_edge(cx, cy)
        local tw, th = frame.tile_w, frame.tile_h
        if     side == "left"   then out.edge = (out.edge and math.min(out.edge, cx - 0.5 * tw)) or (cx - 0.5 * tw)
        elseif side == "right"  then out.edge = (out.edge and math.max(out.edge, cx + 0.5 * tw)) or (cx + 0.5 * tw)
        elseif side == "top"    then out.edge = (out.edge and math.max(out.edge, cy + 0.5 * th)) or (cy + 0.5 * th)
        elseif side == "bottom" then out.edge = (out.edge and math.min(out.edge, cy - 0.5 * th)) or (cy - 0.5 * th) end
    end

    for ty = frame.min_ty, frame.max_ty do
        for tx = frame.min_tx, frame.max_tx do
            local ok, tid = pcall(tilemap.get_tile, frame.tilemap, lh, tx, ty)
            if ok and (tid or 0) ~= 0 then
                local local_tx = tx - frame.min_tx
                local local_ty = ty - frame.min_ty
                local cx, cy = TileFrame.local_to_world_center(frame, local_tx, local_ty)
                local point = {
                    world    = vmath.vector3(cx, cy, 0),
                    map_tx   = tx,
                    map_ty   = ty,
                    local_tx = local_tx,
                    local_ty = local_ty,
                }
                log("scan_side: found door tile at (%d,%d) -> world (%.1f,%.1f) on layer %s", tx, ty, cx, cy, layer_name)
                out.points[#out.points + 1] = point
                update_edge(cx, cy)
            end
        end
    end

    return out
end

local function collect(created, side)
    local tm_url, tm_pos = first_tilemap(created)
    if not (tm_url and tm_pos) then return { points = {}, edge = nil, frame = nil } end

    local layer =
        (side == "left"   and (S.doors and S.doors.layer_left))  or
        (side == "right"  and (S.doors and S.doors.layer_right)) or
        (side == "top"    and (S.doors and S.doors.layer_top))   or
        (side == "bottom" and (S.doors and S.doors.layer_bottom))

    local frame = TileFrame.build(tm_url, tm_pos)
    log("collect: scanning %s side, layer=%s, tilemap=%s, pos=(%.1f,%.1f)", side, layer or "nil", tostring(tm_url), tm_pos.x, tm_pos.y)
    local result = scan_side(frame, side, layer or "")
    result.frame = frame
    log("collect: found %d door points on %s side", #result.points, side)
    return result
end

local function door_edge_for(frame, side, world_pos)
    if not (frame and world_pos) then return nil end
    local tw = frame.tile_w
    local th = frame.tile_h
    if     side == "left"   then return world_pos.x - 0.5 * tw
    elseif side == "right"  then return world_pos.x + 0.5 * tw
    elseif side == "top"    then return world_pos.y + 0.5 * th
    elseif side == "bottom" then return world_pos.y - 0.5 * th end
    return nil
end

-- choose nearest across the seam (minimize perpendicular delta)

local function choose_pair(side, Apts, Bpts)
    if not (Apts and #Apts > 0 and Bpts and #Bpts > 0) then return nil end

    local best, best_d = nil, math.huge
    for _, a in ipairs(Apts) do
        local aw = a.world
        for _, b in ipairs(Bpts) do
            local bw = b.world
            local d = (side == "left" or side == "right") and math.abs(aw.y - bw.y) or math.abs(aw.x - bw.x)
            if d < best_d then
                best_d = d
                best = { a = a, b = b }
            end
        end
    end
    return best
end



-- PUBLIC: returns

-- { a=vec3, b=vec3, a_edge=number|nil, b_edge=number|nil }

function M.find_pair(center_created, neighbor_created, side)

	local opposite = (side == "left" and "right") or (side == "right" and "left")

	or (side == "top" and "bottom") or (side == "bottom" and "top")

	if not opposite then return nil end



	local A = collect(center_created, side)     -- our side (e.g. right)
	local B = collect(neighbor_created, opposite) -- neighbor opposite (e.g. left)

	

	log("find_pair: side=%s opposite=%s A_points=%d B_points=%d", side, opposite, #A.points, #B.points)

	

	local pair_points = choose_pair(side, A.points, B.points)

	if not pair_points then 

		log("find_pair: no pair found (A has %d points, B has %d points)", #A.points, #B.points)

		log(string.format("[ROOM_ALIGN] no match side=%s points_a=%d points_b=%d", tostring(side), #A.points, #B.points))

		return nil 

	end

    local result = {
        a = pair_points.a.world,
        b = pair_points.b.world,
        a_edge = door_edge_for(A.frame, side, pair_points.a.world) or A.edge,
        b_edge = door_edge_for(B.frame, opposite, pair_points.b.world) or B.edge,
        a_tile = {
            map_tx = pair_points.a.map_tx,
            map_ty = pair_points.a.map_ty,
            local_tx = pair_points.a.local_tx,
            local_ty = pair_points.a.local_ty,
        },
        b_tile = {
            map_tx = pair_points.b.map_tx,
            map_ty = pair_points.b.map_ty,
            local_tx = pair_points.b.local_tx,
            local_ty = pair_points.b.local_ty,
        },
        frame_a = A.frame,
        frame_b = B.frame,
    }

	log(string.format("[ROOM_ALIGN] pick side=%s a=(%.1f,%.1f) b=(%.1f,%.1f) edges=(%s,%s)",
		tostring(side), result.a.x or 0, result.a.y or 0, result.b.x or 0, result.b.y or 0, tostring(result.a_edge), tostring(result.b_edge)))

    log(("pair on %s: a(%.1f,%.1f) b=(%.1f,%.1f)  edges a=%s b=%s")
    :format(side, result.a.x, result.a.y, result.b.x, result.b.y,
    tostring(result.a_edge), tostring(result.b_edge)))

    -- Extra debug: dump tile coords and local mapping around door cells
    do
        if result.frame_a then TileFrame.debug_dump(result.frame_a, 'A') end
        if result.frame_b then TileFrame.debug_dump(result.frame_b, 'B') end
        seam_log(string.format('[SEAM_DBG] A tile map=(%d,%d) local=(%d,%d); B tile map=(%d,%d) local=(%d,%d)'
            , result.a_tile.map_tx or -1, result.a_tile.map_ty or -1
            , result.a_tile.local_tx or -1, result.a_tile.local_ty or -1
            , result.b_tile.map_tx or -1, result.b_tile.map_ty or -1
            , result.b_tile.local_tx or -1, result.b_tile.local_ty or -1))
        local layer_left   = S.doors and S.doors.layer_left or 'door_left'
        local layer_right  = S.doors and S.doors.layer_right or 'door_right'
        local layer_top    = S.doors and S.doors.layer_top or 'door_top'
        local layer_bottom = S.doors and S.doors.layer_bottom or 'door_bottom'
        local la = (side == 'left' and layer_left) or (side == 'right' and layer_right) or (side == 'top' and layer_top) or layer_bottom
        local lb = (side == 'left' and layer_right) or (side == 'right' and layer_left) or (side == 'top' and layer_bottom) or layer_top
        if result.frame_a and result.a_tile.map_tx and la then
            seam_log('[SEAM_DBG] A door neighborhood:')
        if LockCfg and LockCfg.debug and LockCfg.debug.prints then
            log(TileFrame.sample_layer_by_name(result.frame_a, la, result.a_tile.map_tx, result.a_tile.map_ty, 2))
        end
        end
        if result.frame_b and result.b_tile.map_tx and lb then
            seam_log('[SEAM_DBG] B door neighborhood:')
        if LockCfg and LockCfg.debug and LockCfg.debug.prints then
            log(TileFrame.sample_layer_by_name(result.frame_b, lb, result.b_tile.map_tx, result.b_tile.map_ty, 2))
        end
        end
    end

    return result

end



return M

 

 


