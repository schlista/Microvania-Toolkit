-- Minimap discovery for authored secret gameobjects.
local Util = require "mvtk.core.util"

local M = {}

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local _Dbg = Util.require_config("developer.config.debug_config")
local function print(...)  -- luacheck: ignore 121
    if _Dbg.collectibles and _Dbg.collectibles.secret then
        _orig_print(...)
    end
end

--- Reveal secret on minimap
-- @param room_id Room to reveal
-- @param entrance_position Optional entrance marker position
function M.reveal_on_minimap(room_id, entrance_position)
    print(string.format("[SECRET_DETECTOR] Revealing room %s on minimap", room_id))

    -- Update minimap via global MINIMAP_MODULE
    if _G.MINIMAP_MODULE and _G.MINIMAP_MODULE.add_marker then
        local marker_pos = entrance_position or vmath.vector3(0, 0, 0)
        _G.MINIMAP_MODULE.add_marker(marker_pos, {
            label = "Secret",
            source = "secret_discovery"
        })
        print(string.format("[SECRET_DETECTOR] Added minimap marker at (%.0f, %.0f)", marker_pos.x, marker_pos.y))
    end
    
    -- Mark room as explored if it wasn't already
    require("mvtk.map.discovery").visit(room_id, entrance_position)
end

return M
