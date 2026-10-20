-- Engine boundary for GUI layout and raw pointer coordinates. The pure geometry
-- module is also used by the renderer; do not derive another fit policy here.
local Letterbox = require "mvtk.render.letterbox"
local Config = require "developer.config.game_config"
local Logger = require "mvtk.core.logger"
Logger.configure_from_debug_config()
local Log = Logger.get_logger("gameplay.camera")
local M = {}
local cached, previous_w, previous_h, previous_dw, previous_dh

function M.design_size()
    -- The validator requires these defaults to match game.project. Explicit
    -- project values remain authoritative; defaults also support headless tools.
    return sys.get_config_int("display.width", Config.window.target_width),
        sys.get_config_int("display.height", Config.window.target_height)
end

function M.rect()
    if not window or type(window.get_size) ~= "function" then return nil end
    local w, h = window.get_size()
    local dw, dh = M.design_size()
    if w ~= previous_w or h ~= previous_h or dw ~= previous_dw or dh ~= previous_dh then
        cached = Letterbox.rect(w, h, dw, dh)
        previous_w, previous_h, previous_dw, previous_dh = w, h, dw, dh
        if cached then
            Log.debug("letterbox gui window=%dx%d design=%dx%d rect=%d,%d,%d,%d scale=%.9f",
                w, h, dw, dh, cached.x, cached.y, cached.w, cached.h, cached.scale)
        else
            Log.debug("letterbox gui inactive window=%s,%s", tostring(w), tostring(h))
        end
    end
    return cached
end

function M.to_screen(dx, dy, rect)
    return Letterbox.design_to_screen(dx, dy, rect or M.rect())
end

function M.to_design(px, py, rect)
    return Letterbox.screen_to_design(px, py, rect or M.rect())
end

function M.pointer(action, rect)
    if not action or action.screen_x == nil or action.screen_y == nil then return nil, nil, false end
    rect = rect or M.rect()
    if not rect then return nil, nil, false end
    local x, y = Letterbox.screen_to_design(action.screen_x, action.screen_y, rect)
    -- Do not clamp: an already active drag must continue and release in a bar.
    local inside = action.screen_x >= rect.x and action.screen_y >= rect.y
        and action.screen_x < rect.x + rect.w and action.screen_y < rect.y + rect.h
    return x, y, inside
end

return M
