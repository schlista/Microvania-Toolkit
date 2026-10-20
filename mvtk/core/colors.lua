-- Shared color/vector4 coercion helpers.

local M = {}

local function fallback_components(fallback)
    if type(fallback) == "table" then
        return {
            x = tonumber(fallback.x or fallback[1]) or 1,
            y = tonumber(fallback.y or fallback[2]) or 1,
            z = tonumber(fallback.z or fallback[3]) or 1,
            w = tonumber(fallback.w or fallback[4]) or 1,
        }
    elseif fallback ~= nil then
        local ok, v = pcall(vmath.vector4, fallback)
        if ok and v then
            return {
                x = tonumber(v.x) or 1,
                y = tonumber(v.y) or 1,
                z = tonumber(v.z) or 1,
                w = tonumber(v.w) or 1,
            }
        end
    end
    return { x = 1, y = 1, z = 1, w = 1 }
end

function M.to_v4(value, fallback)
    local fb = fallback_components(fallback)
    if type(value) == "table" then
        return vmath.vector4(
            tonumber(value.x or value[1]) or fb.x,
            tonumber(value.y or value[2]) or fb.y,
            tonumber(value.z or value[3]) or fb.z,
            tonumber(value.w or value[4]) or fb.w
        )
    elseif value ~= nil then
        local ok, v = pcall(vmath.vector4, value)
        if ok and v and tonumber(v.x) and tonumber(v.y) and tonumber(v.z) and tonumber(v.w) then
            return v
        end
    end
    return vmath.vector4(fb.x, fb.y, fb.z, fb.w)
end

function M.premultiply_alpha(value, fallback)
    local v = M.to_v4(value, fallback)
    local a = tonumber(v.w) or 1
    return vmath.vector4((v.x or 0) * a, (v.y or 0) * a, (v.z or 0) * a, a)
end

return M
