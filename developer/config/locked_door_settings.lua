-- developer/config/locked_door_settings.lua
-- Locked-door configuration.
--
-- NOTE: Locked doors are now authored as rectangle objects in Tiled using
-- tiled/templates/environment/locked_door.tx. Each object carries its own
-- unlock requirements (ability / key / item), so the per-room:side
-- `requirements` map and auto-spawn `ability_rewards`/`key_collectible_type`
-- fields have been removed from this file.
--
-- What's kept here is only what other subsystems still consume:
--   - `tile`: seam/frame math in tile_doors, tile_frame,
--     room_outline, room_doors, and the layout-editor overlays.
--   - `factories`: runtime factory URLs (door_blocker factory is still used
--     by any dynamic/boss lock spawn paths).
--   - `runtime_lock`: base pixel size for authored blocker prefabs.
--   - `editor`: marker, overlap, and draw-offset settings used by the
--     layout-editor renderer.
--   - `debug`: print toggles.

local Tile = require "developer.config.tile_settings"
local Debug = require('developer.config.debug_config')

local okS, S = pcall(require, "developer.config.layout_editor_settings")

local outline_px = 6
local bar_scale  = 1.0

if okS and type(S) == "table" then
    if S.preview and type(S.preview.outline_thick_px) == "number" then
        outline_px = S.preview.outline_thick_px
    end
    if S.door and type(S.door.thickness_scale) == "number" then
        bar_scale = S.door.thickness_scale
    end
end

local bar_px = outline_px * bar_scale

local LDSET = {}

local function lock_log(...)
    if Debug.global.enable or Debug.rooms.door_debug then
        print(...)
    end
end

-- Runtime factories for any non-authored (e.g. scripted/boss) blocker spawns.
-- Should match the embedded factories in developer/game/main.collection.
LDSET.factories = {
    blocker        = "main:/room_manager#door_blocker_factory",
    unlock_trigger = "main:/room_manager#door_unlock_trigger_factory",
    room_unlock_test = "main:/room_manager#door_unlock_test_factory",
}

-- Authored blocker base pixel size (from door_blocker.go).
LDSET.runtime_lock = {
    base_px = 128,
}

-- GUI/seam math expects tile dimensions here.
LDSET.tile = { w = Tile.width, h = Tile.height }

LDSET.editor = {
    -- Inward correction: cancel outward bias (+bar_px/2) and also move by
    -- -outline/2 so the bar's outer edge sits on the drawn wall centerline.
    door_draw_offset_px = -0.5 * (outline_px + bar_px),

    overlap_recolor_enabled = false,
    overlap_px = 8,
    recolor_on_proximity = false,
    true_overlap_px = 1,

    marker = {
        enabled      = true,
        len_px       = 14,
        thickness_px = 3,
        color        = vmath.vector4(1.0, 0.35, 0.10, 1.0),
        z_offset     = 0.08,
    },
}

LDSET.debug = { prints = true }

lock_log(string.format("[LE.Lock] door_draw_offset_px=%.2f (inset = -0.5 * (outline=%.2f + bar=%.2f))",
    LDSET.editor.door_draw_offset_px, outline_px, bar_px))

return LDSET
