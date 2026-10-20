-- Scale transitions advanced only by the owning boss's gameplay update.
-- No engine animation completion can teleport/change a boss during menu pause.
local Pause = require "mvtk.core.pause"
local M = {}
local active = {}

local function key(url)
    local u = msg.url(url)
    return tostring(u.socket) .. ":" .. tostring(u.path)
end

function M.scale(url, target, duration, easing, pingpong, complete)
    active[key(url)] = {
        url = url, from = go.get_scale(url), target = target,
        duration = math.max(0, duration), elapsed = 0,
        easing = easing, pingpong = pingpong, complete = complete,
    }
end

function M.clear(url)
    active[key(url)] = nil
end

function M.update(url, dt)
    if Pause.get() then return end
    local id = key(url)
    local motion = active[id]
    if not motion then return end
    motion.elapsed = motion.elapsed + math.max(0, dt)
    local t = motion.duration > 0 and math.min(1, motion.elapsed / motion.duration) or 1
    local progress = motion.pingpong and (t < 0.5 and t * 2 or (1 - t) * 2) or t
    if motion.easing == "in_cubic" then progress = progress ^ 3
    elseif motion.easing == "out_cubic" then progress = 1 - (1 - progress) ^ 3
    elseif motion.easing == "out_quad" then progress = 1 - (1 - progress) ^ 2 end
    go.set_scale(motion.from + (motion.target - motion.from) * progress, url)
    if t >= 1 then
        active[id] = nil
        if motion.complete then motion.complete() end
    end
end

return M
