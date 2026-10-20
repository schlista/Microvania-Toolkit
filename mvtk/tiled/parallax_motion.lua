-- Shared camera hook for independently baked scenery GOs. Never creates objects.
local CameraState = require "mvtk.camera.camera_state"
local M = {}
local entries = {}
local hook = "tiled_parallax_motion"

local function apply(entry, x, y)
    local p = entry.position
    p.x = entry.base.x + (x - entry.anchor.x) * (1 - entry.factor_x)
    p.y = entry.base.y + (y - entry.anchor.y) * (1 - entry.factor_y)
    -- Z is authored draw order, independent of scrolling speed.
    go.set_position(p, entry.id)
end

local function publish(x, y)
    for _, entry in pairs(entries) do apply(entry, x, y) end
end

function M.register(id, base, anchor, factor_x, factor_y)
    local entry = {id=id, base=vmath.vector3(base), position=vmath.vector3(base),
        anchor=vmath.vector3(anchor), factor_x=factor_x, factor_y=factor_y}
    entries[id] = entry
    CameraState.on_publish(hook, publish)
    local ready, x, y = CameraState.get()
    if ready then apply(entry, x, y) end
    return entry
end

function M.unregister(entry)
    if entry and entries[entry.id] == entry then entries[entry.id] = nil end
    if not next(entries) then CameraState.off_publish(hook) end
end

return M
