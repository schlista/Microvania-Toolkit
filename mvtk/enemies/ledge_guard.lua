-- Stop supported ground movers before a drop without changing vertical motion.
local SurfaceClassifier = require "mvtk.core.surface_classifier"

local M = {}

-- Used only when tile_settings.lua gives no usable size.
local FALLBACK_TILE_SIZE = 64

local function positive(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

-- Ledge settings for one enemy, in world pixels. The project defaults
-- (enemy_defaults.lua) are in tiles, so they are multiplied by the project
-- tile size (tile_settings.lua): the margin by tile width, the probe depth and
-- step tolerance by tile height. The enemy type can override the switch and,
-- in pixels, the margin. Older creator defaults may not have the ledge keys
-- yet, so missing values keep the shipped ones.
function M.settings(type_cfg, defaults, tile)
    type_cfg = type_cfg or {}
    defaults = defaults or {}
    tile = tile or {}
    local tile_w = positive(tile.width) or positive(tile.tile_width) or positive(tile.size)
        or FALLBACK_TILE_SIZE
    local tile_h = positive(tile.height) or positive(tile.tile_height) or positive(tile.size)
        or tile_w
    local enabled = type_cfg.stop_at_ledges
    if enabled == nil then
        enabled = defaults.stop_at_ledges ~= false
    end
    return {
        enabled = enabled == true,
        margin = tonumber(type_cfg.ledge_margin)
            or tile_w * (tonumber(defaults.ledge_margin_tiles) or 0.25),
        probe_depth = tile_h * (tonumber(defaults.ledge_probe_depth_tiles) or 4),
        step_tolerance = tile_h * (tonumber(defaults.ledge_step_tolerance_tiles) or 0.125),
    }
end

function M.apply(self, dt, raycast)
    self._ledge_blocked_dir = nil
    local ledge = self._ledge
    if not ledge or ledge.enabled ~= true
        or self._grounded_movement ~= true or self._ignores_terrain == true
        or self.vel.x == 0 or dt <= 0 then
        return
    end

    -- Resolve at call time so runtime/test replacements are honored.
    raycast = raycast or physics.raycast
    local pos = self.pos
    local bottom_y = pos.y - ledge.probe_depth
    local z = pos.z or 0
    local groups = SurfaceClassifier.RAYCAST.GROUND
    local support = raycast(vmath.vector3(pos.x, pos.y, z),
        vmath.vector3(pos.x, bottom_y, z), groups)
    if not SurfaceClassifier.is_ground_collision(support) then
        -- Air-authored enemies and bodies taller than the probe keep moving.
        return
    end

    local dir = self.vel.x > 0 and 1 or -1
    local ahead_x = pos.x + self.vel.x * dt + dir * ledge.margin
    local ahead = raycast(vmath.vector3(ahead_x, pos.y, z),
        vmath.vector3(ahead_x, bottom_y, z), groups)
    if SurfaceClassifier.is_ground_collision(ahead)
        and ahead.position.y >= support.position.y - ledge.step_tolerance then
        return
    end

    self.vel.x = 0
    self._ledge_blocked_dir = dir
end

return M
