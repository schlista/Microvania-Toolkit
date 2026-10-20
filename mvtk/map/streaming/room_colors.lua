-- mvtk/map/streaming/room_colors.lua
-- Pure render-clear-color helpers extracted from room_manager.lua as part
-- of Phase 5 step 32. No closures over module-local state.

local M = {}

--- Build a vmath.vector4 (or a plain {x,y,z,w} table when vmath is absent
-- — keeps the helper unit-testable from a vanilla Lua interpreter).
function M.make_color4(x, y, z, w)
    if vmath and vmath.vector4 then
        return vmath.vector4(x, y, z, w)
    end
    return {
        x = x or 0,
        y = y or 0,
        z = z or 0,
        w = w or 0,
    }
end

--- Defensive copy of an authored color4 (e.g. from a Tiled room metadata
-- table). Returns nil if any of x/y/z is missing or non-numeric. Defaults
-- alpha (w) to 1.0 when not present.
function M.copy_color4(color)
    if color == nil then
        return nil
    end

    local x = tonumber(color.x)
    local y = tonumber(color.y)
    local z = tonumber(color.z)
    local w = tonumber(color.w)
    if x == nil or y == nil or z == nil then
        return nil
    end

    return M.make_color4(x, y, z, w or 1.0)
end

--- Read the project default render clear color from sys.get_config_number.
-- Falls back to opaque black when sys is unavailable (test environments).
function M.get_default_render_clear_color()
    local get_number = sys and sys.get_config_number
    return M.make_color4(
        get_number and get_number("render.clear_color_red", 0) or 0,
        get_number and get_number("render.clear_color_green", 0) or 0,
        get_number and get_number("render.clear_color_blue", 0) or 0,
        get_number and get_number("render.clear_color_alpha", 0) or 0
    )
end

return M
