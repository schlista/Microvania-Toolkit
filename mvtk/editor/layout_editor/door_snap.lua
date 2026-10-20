-- mvtk/editor/layout_editor/door_snap.lua
--
-- Snaps a dragged room (R) so its doors align with a neighboring room's
-- doors. Two modes are supported via developer/config/layout_editor_settings:
--   * S.snap.overlap = true  -> door centers align (rooms overlap visually)
--   * S.snap.overlap = false -> door bars touch edge-to-edge with a small gap
--
-- The "simple" snap is the only live implementation in the layout editor;
-- two earlier variants (try_snap_to_doors and try_snap_to_doors_better) were
-- removed in Phase 2.1d as dead code.
--
-- Public API:
--   M.MANUAL_INSET_PX                    -- default manual door-inset (15)
--   M.side_compat(a, b)                  -- true iff door sides A/B can pair
--   M.apply_manual_inset(room, door_index, inset_px)
--                                        -- annotate room.doors_meta with the
--                                        -- manual inset that snap applied
--   M.try_snap(self, R)                  -- mutates R.base_pos on success;
--                                           returns true if snap occurred

local Util = require "mvtk.core.util"
local S = Util.require_config("developer.config.layout_editor_settings")
local Render = require "mvtk.editor.layout_editor.render"

local Logger = require "mvtk.core.logger"
local log = Logger.get_logger("layout_editor.door_snap")
local function logf(fmt, ...) log.debug(fmt, ...) end

local M = {}

M.MANUAL_INSET_PX = 15

function M.side_compat(a, b)
    return (a=="left" and b=="right") or (a=="right" and b=="left")
        or (a=="up"   and b=="down")  or (a=="down"  and b=="up")
end

function M.apply_manual_inset(room, door_index, inset_px)
    if not room or not room.doors_meta then return end
    local meta = room.doors_meta[door_index]
    if meta then
        meta.manual_inset_px = inset_px or M.MANUAL_INSET_PX
    end
end

-- Minimal, strict snapper using room edges for butt joints and door centers
-- for overlap.
function M.try_snap(self, R)
    logf("=== SNAP DEBUG START (Simple) ===")
    if not (S.snap and S.snap.enabled) then
        logf("snap disabled, returning false")
        return false
    end
    local doorsA = R.shape.doors or {}
    if #doorsA == 0 then
        logf("no doors on moving room, returning false")
        return false
    end
    logf("room %s has %d doors", R.id, #doorsA)

    local thresh_world   = tonumber(S.snap.threshold_px) or 150
    local center_tol     = tonumber(S.snap.center_tolerance_px) or 128
    local gap_px         = tonumber(S.snap.edge_gap_px) or 0
    local overlap_doors  = (S.snap and S.snap.overlap) and true or false
    local cross_slack    = tonumber(S.snap.crossing_slack_px) or 200

    logf("snap settings: threshold=%dpx, center_tol=%dpx, overlap=%s", thresh_world, center_tol, tostring(overlap_doors))

    local best = nil
    local room_count = 0

    for idB, RB in pairs(self.rooms) do
        if RB ~= R then
            room_count = room_count + 1
            local doorsB = RB.shape.doors or {}
            logf("checking against room %s with %d doors", idB, #doorsB)

            for ai, da in ipairs(doorsA) do
                for bi, db in ipairs(doorsB) do
                    local compat = M.side_compat(da.side, db.side)
                    logf("door A#%d(%s) vs door B#%d(%s) - compatible: %s", ai, da.side, bi, db.side, tostring(compat))

                    if compat then
                        local horiz = (da.side=="left" and db.side=="right") or (da.side=="right" and db.side=="left")
                        local a_cx = R.base_pos.x + da.cx
                        local a_cy = R.base_pos.y + da.cy
                        local b_cx = RB.base_pos.x + db.cx
                        local b_cy = RB.base_pos.y + db.cy
                        local seam_delta = horiz and math.abs(a_cy - b_cy) or math.abs(a_cx - b_cx)

                        logf("door positions: A=(%.1f,%.1f) B=(%.1f,%.1f) seam_delta=%.1f", a_cx, a_cy, b_cx, b_cy, seam_delta)

                        if overlap_doors then
                            -- For overlap mode: doors should perfectly align (door centers match)
                            local normal = horiz and math.abs(a_cx - b_cx) or math.abs(a_cy - b_cy)
                            logf("overlap mode: normal=%.1f (thresh=%d) seam=%.1f (tol=%d)", normal, thresh_world, seam_delta, center_tol)
                            if normal <= thresh_world and seam_delta <= center_tol then
                                local inset_px = (S.door and S.door.overlap_inset_px) or 10

                                local function apply_door_inset(cx, cy, side)
                                    if side == "left" then return cx + inset_px, cy
                                    elseif side == "right" then return cx - inset_px, cy
                                    elseif side == "up" then return cx, cy - inset_px
                                    elseif side == "down" then return cx, cy + inset_px
                                    end
                                    return cx, cy
                                end

                                local da_visual_cx, da_visual_cy = apply_door_inset(da.cx, da.cy, da.side)
                                local db_visual_cx, db_visual_cy = apply_door_inset(db.cx, db.cy, db.side)

                                local desired = RB.base_pos + vmath.vector3(db_visual_cx - da_visual_cx, db_visual_cy - da_visual_cy, 0)
                                local score = normal + 0.05 * seam_delta
                                logf("*** SNAP CANDIDATE (overlap with inset): score=%.2f inset=%.1fpx ***", score, inset_px)
                                logf("*** DEBUG: Target room %s at (%.1f,%.1f), desired position for %s: (%.1f,%.1f)",
                                RB.id, RB.base_pos.x, RB.base_pos.y, R.id, desired.x, desired.y)
                                logf("*** DEBUG: Door geometry: A=(%.1f,%.1f) B=(%.1f,%.1f), Visual: A=(%.1f,%.1f) B=(%.1f,%.1f)",
                                da.cx, da.cy, db.cx, db.cy, da_visual_cx, da_visual_cy, db_visual_cx, db_visual_cy)
                                if not best or score < best.score then
                                    best = {
                                        pos = desired,
                                        score = score,
                                        target_room_id = idB,
                                        door_a = da,
                                        door_b = db,
                                        door_a_index = ai,
                                        door_b_index = bi
                                    }
                                end
                            else
                                logf("overlap reject: normal=%.1f>%d OR seam=%.1f>%d", normal, thresh_world, seam_delta, center_tol)
                            end
                        else
                            -- Butt mode: room edges should touch with gap_px separation
                            local sgap
                            if horiz then
                                if     (da.side=="right" and db.side=="left")  then sgap = RB.base_pos.x - (R.base_pos.x + R.shape.w_px)
                                elseif (da.side=="left"  and db.side=="right") then sgap = R.base_pos.x - (RB.base_pos.x + RB.shape.w_px) end
                            else
                                if     (da.side=="up"    and db.side=="down")  then sgap = RB.base_pos.y - (R.base_pos.y + R.shape.h_px)
                                elseif (da.side=="down"  and db.side=="up")    then sgap = R.base_pos.y - (RB.base_pos.y + RB.shape.h_px) end
                            end

                            logf("butt mode: sgap=%.1f seam=%.1f", sgap or -9999, seam_delta)

                            if sgap and sgap >= -cross_slack and seam_delta <= center_tol then
                                local gap_abs = math.abs(sgap)
                                logf("butt check: gap_abs=%.1f (thresh=%d)", gap_abs, thresh_world)
                                if gap_abs <= thresh_world then
                                    -- DOOR-EDGE APPROACH: make door edges touch, not centers
                                    local t_outline = (S.preview and S.preview.outline_thick_px) or 6
                                    local t_door = t_outline * ((S.door and S.door.thickness_scale) or 1.0)
                                    local extend = t_door * ((S.door and S.door.extend_ratio) or 0.25)
                                    local half_door_thickness = (t_door + 2 * extend) / 2

                                    local desired = vmath.vector3(R.base_pos)

                                    local extra_gap = 20  -- additional 20px separation for visual clarity

                                    if horiz then
                                        if (da.side=="right" and db.side=="left") then
                                            desired.x = RB.base_pos.x + db.cx - da.cx - gap_px - half_door_thickness - extra_gap
                                            desired.y = RB.base_pos.y + db.cy - da.cy
                                        elseif (da.side=="left" and db.side=="right") then
                                            desired.x = RB.base_pos.x + db.cx - da.cx + gap_px + half_door_thickness + extra_gap
                                            desired.y = RB.base_pos.y + db.cy - da.cy
                                        end
                                    else
                                        if (da.side=="up" and db.side=="down") then
                                            desired.y = RB.base_pos.y + db.cy - da.cy - gap_px - half_door_thickness - extra_gap
                                            desired.x = RB.base_pos.x + db.cx - da.cx
                                        elseif (da.side=="down" and db.side=="up") then
                                            desired.y = RB.base_pos.y + db.cy - da.cy + gap_px + half_door_thickness + extra_gap
                                            desired.x = RB.base_pos.x + db.cx - da.cx
                                        end
                                    end

                                    local score = gap_abs + 0.05 * seam_delta
                                    logf("*** SNAP CANDIDATE (butt): half_door_thickness=%.1fpx extra_gap=%dpx total_sep=%.1fpx ***", half_door_thickness, extra_gap, half_door_thickness + extra_gap)
                                    if not best or score < best.score then
                                        best = {
                                            pos = desired,
                                            score = score,
                                            target_room_id = idB,
                                            door_a = da,
                                            door_b = db,
                                            door_a_index = ai,
                                            door_b_index = bi
                                        }
                                    end
                                else
                                    logf("butt reject: gap_abs=%.1f > thresh=%d", gap_abs, thresh_world)
                                end
                            else
                                logf("butt reject: sgap=%.1f < -slack=%d OR seam=%.1f > tol=%d", sgap or -9999, cross_slack, seam_delta, center_tol)
                            end
                        end
                    end
                end
            end
        end
    end

    logf("checked %d other rooms", room_count)
    if best then
        logf("*** SNAPPING with score=%.2f ***", best.score)

        logf("=== DOOR POSITIONS BEFORE SNAP ===")
        for i, da in ipairs(doorsA) do
            local a_cx = R.base_pos.x + da.cx
            local a_cy = R.base_pos.y + da.cy
            logf("Door A#%d (%s): center=(%.1f,%.1f)", i, da.side, a_cx, a_cy)
        end

        -- Apply seam_bias_px to push rooms further apart (config knob)
        local seam_bias = (S.door and S.door.seam_bias_px) or 0
        local final_pos = vmath.vector3(best.pos)

        if seam_bias ~= 0 and best.door_a and best.door_b then
            if best.door_a.side == "left" then
                final_pos.x = final_pos.x - seam_bias
            elseif best.door_a.side == "right" then
                final_pos.x = final_pos.x + seam_bias
            elseif best.door_a.side == "up" then
                final_pos.y = final_pos.y + seam_bias
            elseif best.door_a.side == "down" then
                final_pos.y = final_pos.y - seam_bias
            end
            logf("applied seam_bias=%.1fpx, final room separation increased", seam_bias)
        end

        R.base_pos = final_pos
        logf("*** DEBUG: Room %s base_pos set to (%.1f, %.1f) [door_snap.try_snap]", R.id, final_pos.x, final_pos.y)

        logf("=== DOOR POSITIONS AFTER SNAP ===")
        for i, da in ipairs(doorsA) do
            local a_cx = R.base_pos.x + da.cx
            local a_cy = R.base_pos.y + da.cy
            logf("Door A#%d (%s): center=(%.1f,%.1f)", i, da.side, a_cx, a_cy)
        end

        local target_room = self.rooms[best.target_room_id]
        if best.door_a_index and best.door_b_index and target_room then
            M.apply_manual_inset(R, best.door_a_index, M.MANUAL_INSET_PX)
            M.apply_manual_inset(target_room, best.door_b_index, M.MANUAL_INSET_PX)
            Render.recolor_doors_for_overlaps(self)
        end
        if target_room then
            logf("=== TARGET ROOM DOOR POSITIONS ===")
            for i, db in ipairs(target_room.shape.doors or {}) do
                local b_cx = target_room.base_pos.x + db.cx
                local b_cy = target_room.base_pos.y + db.cy
                logf("Door B#%d (%s): center=(%.1f,%.1f)", i, db.side, b_cx, b_cy)
            end

            logf("=== ROOM EDGE ANALYSIS ===")
            if best.door_a.side == "right" and best.door_b.side == "left" then
                local a_right_edge = R.base_pos.x + R.shape.w_px
                local b_left_edge = target_room.base_pos.x
                local room_gap = b_left_edge - a_right_edge
                logf("Room gap (A.right to B.left): %.3fpx", room_gap)
            elseif best.door_a.side == "left" and best.door_b.side == "right" then
                local a_left_edge = R.base_pos.x
                local b_right_edge = target_room.base_pos.x + target_room.shape.w_px
                local room_gap = a_left_edge - b_right_edge
                logf("Room gap (A.left to B.right): %.3fpx", room_gap)
            elseif best.door_a.side == "up" and best.door_b.side == "down" then
                local a_top_edge = R.base_pos.y + R.shape.h_px
                local b_bottom_edge = target_room.base_pos.y
                local room_gap = b_bottom_edge - a_top_edge
                logf("Room gap (A.top to B.bottom): %.3fpx", room_gap)
            elseif best.door_a.side == "down" and best.door_b.side == "up" then
                local a_bottom_edge = R.base_pos.y
                local b_top_edge = target_room.base_pos.y + target_room.shape.h_px
                local room_gap = a_bottom_edge - b_top_edge
                logf("Room gap (A.bottom to B.top): %.3fpx", room_gap)
            end

            for i, da in ipairs(doorsA) do
                for j, db in ipairs(target_room.shape.doors or {}) do
                    if M.side_compat(da.side, db.side) then
                        local a_cx = R.base_pos.x + da.cx
                        local a_cy = R.base_pos.y + da.cy
                        local b_cx = target_room.base_pos.x + db.cx
                        local b_cy = target_room.base_pos.y + db.cy
                        local dist = math.sqrt((a_cx - b_cx)^2 + (a_cy - b_cy)^2)
                        logf("Distance A#%d to B#%d: %.1fpx", i, j, dist)
                    end
                end
            end
        end

        logf("=== SNAP DEBUG END (SUCCESS) ===")
        return true
    else
        logf("no snap candidates found")
        logf("=== SNAP DEBUG END (NO SNAP) ===")
        return false
    end
end

return M
