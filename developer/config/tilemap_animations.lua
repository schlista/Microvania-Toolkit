-- developer/config/tilemap_animations.lua
-- Optional fallback tile animation definitions for tilemap_animator.
--
-- Preferred workflow:
-- Tiled animated tiles are auto-generated into
-- developer/config/tilemap_animations_generated.lua during the build hook.
-- Author "tile_animations" custom properties in Tiled when you need explicit
-- per-layer overrides from the map itself.
-- This file is for manual defaults or overrides when generated metadata is not
-- enough.
--
-- Entry fields:
--   layer      : Tile layer name in the Defold tilemap
--   seed_tile  : Tile ID to search for (1-based tile index in Defold)
--   frames     : Frame tile IDs to cycle through (table of 1-based IDs)
--   fps        : Playback rate
--   frame_durations_ms : Optional per-frame timings from Tiled in milliseconds
--   frame_durations    : Optional per-frame timings in seconds
--   mode       : "loop", "pingpong", "once"
--                aliases: "ping_pong", "play_once", "once_forward", "oneshot", "one_shot"
--
-- Example:
-- M.rooms["environment_test"] = {
--     { layer = "solid", seed_tile = 401, frames = {401, 402, 403, 404}, fps = 8, mode = "loop" },
-- }

local M = {
    -- Applied to every room.
    defaults = {
        -- { layer = "hazards", seed_tile = 560, frames = {560, 561, 562, 563}, fps = 10, mode = "loop" },
    },

    -- Per-room overrides/definitions keyed by room id.
    rooms = {
        -- environment_test = {
        --     { layer = "solid", seed_tile = 401, frames = {401, 402, 403, 404}, fps = 8, mode = "pingpong" },
        -- },
    },
}

return M
