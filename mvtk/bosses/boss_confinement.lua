-- mvtk/bosses/boss_confinement.lua
-- Keeps a boss inside its fight area. Before this, boss movement had no bounds
-- (get_arena_center was a stub and leash_radius was never applied), so a boss
-- could chase the player out of the room.
--
-- Area: the boss's Tiled boss_arena rectangle (BossArena bounds), or the
-- boss's room rectangle when it has no arena. Pure clamp logic is unit-tested.
local M = {}

--- { min_x, min_y, max_x, max_y } from BossArena bounds { x, y, width, height }.
function M.rect_from_arena_bounds(bounds)
    if type(bounds) ~= "table" then return nil end
    local x, y = tonumber(bounds.x), tonumber(bounds.y)
    local w, h = tonumber(bounds.width), tonumber(bounds.height)
    if not (x and y and w and h) or w <= 0 or h <= 0 then return nil end
    return { min_x = x, min_y = y, max_x = x + w, max_y = y + h }
end

--- Clamp a position so a box of half extents (hw, hh) stays inside rect.
-- Returns x, y (unchanged when rect is nil or narrower than the box).
function M.clamp(x, y, rect, hw, hh)
    if type(rect) ~= "table" then return x, y end
    hw, hh = math.max(0, tonumber(hw) or 0), math.max(0, tonumber(hh) or 0)
    local min_x, max_x = rect.min_x + hw, rect.max_x - hw
    local min_y, max_y = rect.min_y + hh, rect.max_y - hh
    if min_x <= max_x then x = math.max(min_x, math.min(max_x, x)) end
    if min_y <= max_y then y = math.max(min_y, math.min(max_y, y)) end
    return x, y
end

--- Resolve the confinement rectangle for a boss config (arena, then room).
function M.resolve_rect(config)
    config = config or {}
    local arena_id = config.arena_id or config.arena
    if arena_id then
        local ok, BossArena = pcall(require, "mvtk.bosses.boss_arena")
        local arena = ok and BossArena and BossArena.get_arena and BossArena.get_arena(arena_id) or nil
        -- Only authored (Tiled) rectangles; setup_arena's placeholder is not a place.
        local authored = arena and arena.config and arena.config.bounds_authored == true
        local rect = authored and M.rect_from_arena_bounds(arena.bounds) or nil
        if rect then return rect, "arena" end
    end
    if config.room_id then
        local ok, RoomManager = pcall(require, "mvtk.map.streaming.room_manager")
        local bounds = ok and RoomManager and RoomManager.get_room_bounds and RoomManager.get_room_bounds(config.room_id)
        if type(bounds) == "table" and bounds.min_x and bounds.max_x and bounds.min_y and bounds.max_y then
            return { min_x = bounds.min_x, min_y = bounds.min_y, max_x = bounds.max_x, max_y = bounds.max_y }, "room"
        end
    end
    return nil, nil
end

return M
