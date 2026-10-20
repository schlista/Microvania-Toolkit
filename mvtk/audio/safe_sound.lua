-- Pcall-wrapped sound API helpers.

local M = {}

local function clamp01(value)
    local n = tonumber(value) or 0
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

function M.play(url, opts)
    if not url then
        return false, "missing url"
    end
    return pcall(sound.play, url, opts)
end

function M.stop(url)
    if not url then
        return false, "missing url"
    end
    return pcall(sound.stop, url)
end

function M.set_gain(url, gain)
    if not url then
        return false, "missing url"
    end
    return pcall(sound.set_gain, url, clamp01(gain))
end

return M
