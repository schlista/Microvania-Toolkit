-- developer/config/ambient_sounds.lua
-- Maps ambient sound IDs (from Tiled) to sound component names in the audio game object.
--
-- HOW TO USE:
-- 1. Add a sound component to your audio game object (main:/audio)
-- 2. Name it something like "ambient_waterfall"
-- 3. Add an entry here mapping the Tiled ambience_id or room ambient_sound value to that component name
--
-- The editor script detects ambience_zone IDs and room ambience from your Tiled maps
-- and adds placeholder entries here. You just need to:
-- 1. Create the sound components in Defold
-- 2. Update the component_name to match
--
-- Example Tiled object:
--   Type: ambience_zone
--   ambience_id: waterfall
--
-- This config maps "waterfall" -> "ambient_waterfall" component

local M = {
    -- Format: [sound_id] = { component = "component_name", group = "ambient" }
    --
    -- sound_id: The Tiled ambience_id or room ambient_sound value
    -- component: The name of the sound component in the audio game object
    -- group: (optional) Sound group for volume control, defaults to "ambient"

    ["cave"] = {
        component = "ambient_cave",
        group = "ambient",
    },

    -- NEW: Auto-added from Tiled export
    ["collect_map"] = {
        component = "ambient_collect_map",
        group = "ambient",
    },

    ["electricity"] = {
        component = "ambient_electricity",
        group = "ambient",
    },

    ["fire"] = {
        component = "ambient_fire",
        group = "ambient",
    },

    ["forest"] = {
        component = "ambient_forest",
        group = "ambient",
    },

    ["lava"] = {
        component = "ambient_lava",
        group = "ambient",
    },

    ["machine"] = {
        component = "ambient_machine",
        group = "ambient",
    },

    ["rain"] = {
        component = "ambient_rain",
        group = "ambient",
    },

    -- NEW: Auto-added from Tiled export
    ["ui_confirm"] = {
        component = "ambient_ui_confirm",
        group = "ambient",
    },

    ["water_drip"] = {
        component = "ambient_water_drip",
        group = "ambient",
    },

    ["waterfall"] = {
        component = "ambient_waterfall",
        group = "ambient",
    },

    ["wind"] = {
        component = "ambient_wind",
        group = "ambient",
    },

    -- Add more ambient sounds here as needed
    -- The editor script will auto-add entries when it finds new sound_ids in Tiled
}

return M