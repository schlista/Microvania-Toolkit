-- Shared door matching for manual layouts. Tiled placement uses exact seams.
local M={}
local function side_compat(a,b) return (a=="left" and b=="right") or (a=="right" and b=="left") or (a=="up" and b=="down") or (a=="down" and b=="up") end
function M.neighbors(rooms, S)
    local neighbors = {}      -- cid -> array of { id=cidB, side = 'right'|'left'|'up'|'down', door=<src>, mate=<dst> }
    local function clone_door_meta(d)
        if not d then return nil end
        return {
            side = d.side,
            cx   = tonumber(d.cx) or 0,
            cy   = tonumber(d.cy) or 0,
            len  = tonumber(d.len_px or d.len) or 0,
        }
    end

    local overlap_doors  = (S.snap and (S.snap.overlap ~= nil)) and S.snap.overlap or false
    local thresh_world   = tonumber(S.snap and S.snap.threshold_px) or 150
    local center_tol     = tonumber(S.snap and S.snap.center_tolerance_px) or 128
    local cross_slack    = tonumber(S.snap and S.snap.crossing_slack_px) or 200
    local gap_px         = tonumber(S.snap and S.snap.edge_gap_px) or 0

    local function add_edge(a, b, side, door_a, door_b)
        neighbors[a] = neighbors[a] or {}
        -- de-dup simple
        for _, e in ipairs(neighbors[a]) do
            if e.id == b and e.side == side then
                return
            end
        end
        neighbors[a][#neighbors[a]+1] = {
            id   = b,
            side = side,
            door = clone_door_meta(door_a),
            mate = clone_door_meta(door_b),
        }
    end

    for idA, RA in pairs(rooms or {}) do
        local cidA = idA
        local doorsA = (RA.shape and RA.shape.doors) or {}
        for idB, RB in pairs(rooms or {}) do
            if RA ~= RB then
                local cidB = idB
                local doorsB = (RB.shape and RB.shape.doors) or {}

                for _, da in ipairs(doorsA) do
                    for _, db in ipairs(doorsB) do
                        if side_compat(da.side, db.side) then
                            local horiz = (da.side=="left" and db.side=="right") or (da.side=="right" and db.side=="left")
                            local a_cx = RA.base_pos.x + da.cx
                            local a_cy = RA.base_pos.y + da.cy
                            local b_cx = RB.base_pos.x + db.cx
                            local b_cy = RB.base_pos.y + db.cy
                            local seam_delta = horiz and math.abs(a_cy - b_cy) or math.abs(a_cx - b_cx)

                            if overlap_doors then
                                local normal = horiz and math.abs(a_cx - b_cx) or math.abs(a_cy - b_cy)
                                if normal <= thresh_world and seam_delta <= center_tol then
                                    -- A sees B on its side
                                    local side
                                    if     da.side=="right" then side = "right"
                                    elseif da.side=="left"  then side = "left"
                                    elseif da.side=="up"    then side = "up"
                                    elseif da.side=="down"  then side = "down" end
                                    if side then
                                        add_edge(cidA, cidB, side, da, db)
                                    end
                                end
                            else
                                -- Butt-join mode: check edge separation
                                local sgap
                                if horiz then
                                    if     (da.side=="right" and db.side=="left")  then sgap = RB.base_pos.x - (RA.base_pos.x + (RA.shape and RA.shape.w_px or 0))
                                    elseif (da.side=="left"  and db.side=="right") then sgap = RA.base_pos.x - (RB.base_pos.x + (RB.shape and RB.shape.w_px or 0)) end
                                else
                                    if     (da.side=="up"    and db.side=="down")  then sgap = RB.base_pos.y - (RA.base_pos.y + (RA.shape and RA.shape.h_px or 0))
                                    elseif (da.side=="down"  and db.side=="up")    then sgap = RA.base_pos.y - (RB.base_pos.y + (RB.shape and RB.shape.h_px or 0)) end
                                end
                                if sgap ~= nil and sgap >= -cross_slack and math.abs(sgap) <= thresh_world and seam_delta <= center_tol then
                                    local side
                                    if     da.side=="right" then side = "right"
                                    elseif da.side=="left"  then side = "left"
                                    elseif da.side=="up"    then side = "up"
                                    elseif da.side=="down"  then side = "down" end
                                    if side then
                                        add_edge(cidA, cidB, side, da, db)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return neighbors
end

return M
