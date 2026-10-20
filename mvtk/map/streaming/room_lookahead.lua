-- Choose one connected room ahead of actual player motion. This is preparation
-- only: it must never change room ownership, visibility, or map discovery.
local M = {}

function M.select(position, previous, bounds, neighbors, tile_w, tile_h, tiles, get_bounds)
    if not position or not previous or not bounds or (tiles or 0) <= 0 then return nil end
    local dx, dy = position.x - previous.x, position.y - previous.y
    local lead_x = math.min(tiles * tile_w, (bounds.max_x - bounds.min_x) * 0.5)
    local lead_y = math.min(tiles * tile_h, (bounds.max_y - bounds.min_y) * 0.5)
    local chosen, best
    for _, edge in ipairs(neighbors or {}) do
        local distance, lead, motion
        local horizontal = math.abs(dx) >= math.abs(dy)
        if edge.side == "right" and dx > 0 and horizontal then
            distance, lead, motion = bounds.max_x - position.x, lead_x, dx
        elseif edge.side == "left" and dx < 0 and horizontal then
            distance, lead, motion = position.x - bounds.min_x, lead_x, -dx
        elseif (edge.side == "up" or edge.side == "top") and dy > 0 and not horizontal then
            distance, lead, motion = bounds.max_y - position.y, lead_y, dy
        elseif (edge.side == "down" or edge.side == "bottom") and dy < 0 and not horizontal then
            distance, lead, motion = position.y - bounds.min_y, lead_y, -dy
        end
        -- Several connections can share a side. Prepare the room across the
        -- player's lane, not an unrelated doorway above/below (or left/right).
        local target = distance and get_bounds and get_bounds(edge.id)
        if target then
            local across = horizontal and position.y or position.x
            local low = horizontal and target.min_y or target.min_x
            local high = horizontal and target.max_y or target.max_x
            if across < low or across > high then distance = nil end
        end
        if distance and distance >= 0 and distance <= lead then
            local score = distance / motion
            if not best or score < best then chosen, best = edge.id, score end
        end
    end
    return chosen
end

return M
