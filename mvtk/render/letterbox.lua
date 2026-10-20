-- Shared, engine-free design-view geometry. Coordinates use a bottom-left origin.
local M = {}

local function positive(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
end

function M.rect(window_w, window_h, design_w, design_h)
    if not positive(window_w) or not positive(window_h)
        or not positive(design_w) or not positive(design_h) then return nil end
    local scale = math.min(window_w / design_w, window_h / design_h)
    -- Round the fitted extent to the nearest pixel; put an odd spare pixel at
    -- the top/right. Conversions retain the same uniform (unrounded) scale.
    local w = math.floor(design_w * scale + 0.5)
    local h = math.floor(design_h * scale + 0.5)
    return {
        x = math.floor((window_w - w) / 2), y = math.floor((window_h - h) / 2),
        w = w, h = h, scale = scale,
        design_w = design_w, design_h = design_h,
        window_w = window_w, window_h = window_h,
    }
end

function M.screen_to_design(px, py, rect)
    if not rect or not positive(rect.scale) or px == nil or py == nil then return nil end
    return (px - rect.x) / rect.scale, (py - rect.y) / rect.scale
end

function M.design_to_screen(dx, dy, rect)
    if not rect or not positive(rect.scale) or dx == nil or dy == nil then return nil end
    return rect.x + dx * rect.scale, rect.y + dy * rect.scale
end

return M
