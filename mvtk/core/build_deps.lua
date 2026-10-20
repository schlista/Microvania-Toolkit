-- mvtk/core/build_deps.lua
-- BUILD DEPENDENCY MANIFEST
--
-- This module tells the Defold build system (bob) about all developer config
-- files that the mvtk framework loads via pcall(require, ...) at runtime.
--
-- Problem: Defold's bob builder uses static text analysis to find require()
-- calls and determine which .lua files to include in the game archive.
-- pcall(require, "module") is NOT detected as a dependency, so those
-- modules get silently excluded from the bundle.
--
-- Solution: This file contains explicit require() statements inside an
-- unreachable code block. The build system's scanner finds them and
-- includes the files, but they never execute at runtime. The actual
-- loading is done safely via pcall in the framework scripts.
--
-- IMPORTANT: When adding new developer config files that are loaded via
-- pcall(require, ...) in any mvtk/ script, add them here too.

-- Never executes, but build system scans for require("...") patterns
if false then
    ---------------------------------------------------------
    -- Core configs (non-optional, game won't start without these)
    ---------------------------------------------------------
    require("developer.config.resolved_config")
    require("developer.config.game_completion")
    require("developer.config.player_settings")
    require("developer.config.player_actions")
    require("developer.config.default_bindings")
    require("developer.config.debug_config")
    require("developer.config.tile_settings")
    require("developer.config.collectible_types")
    require("developer.config.items")
    require("developer.config.narrative.cutscenes")
    require("developer.config.narrative.dialogues")
    require("developer.config.narrative.cutscenes_generated")
    require("developer.config.narrative.videos")

    ---------------------------------------------------------
    -- Gameplay configs
    ---------------------------------------------------------
    require("developer.config.abilities")
    require("developer.config.combat_config")
    require("developer.config.difficulty_settings")
    require("developer.config.gameplay_constants")
    require("developer.config.hazard_types")
    require("developer.config.interaction")
    require("developer.config.loot_tables")

    ---------------------------------------------------------
    -- Player & input
    ---------------------------------------------------------
    require("developer.config.runtime_settings")
    require("developer.config.settings_defaults")
    require("developer.config.swim_settings")

    ---------------------------------------------------------
    -- Enemy & NPC configs
    ---------------------------------------------------------
    require("developer.config.enemy_settings")
    require("developer.config.enemy_types")
    require("developer.config.boss_types")
    require("developer.config.npc_types")
    require("developer.config.room_enemies")
    require("developer.config.tiled_enemy_overrides")

    ---------------------------------------------------------
    -- World & room configs
    ---------------------------------------------------------
    require("developer.config.biomes")
    require("developer.config.camera_zones")
    require("developer.config.gate_types")
    require("developer.config.gates")
    require("developer.config.layer_settings")
    require("developer.config.map_markers")
    require("developer.config.rooms_config")
    require("developer.config.room_tilemap_layers_generated")
    require("mvtk.rooms.tilemap_layers")
    require("developer.config.elevators_generated")
    require("developer.config.stream_settings")
    require("developer.config.tiled_object_config")
    require("developer.config.water_zones")

    ---------------------------------------------------------
    -- Collectibles & objects
    ---------------------------------------------------------
    require("developer.config.chest_inline_contents")
    require("developer.config.locked_door_settings")
    require("developer.config.secret_settings")
    require("developer.config.secret_types")

    ---------------------------------------------------------
    -- Audio
    ---------------------------------------------------------
    require("developer.config.sound_bank")
    require("developer.config.ambient_sounds")
    require("developer.config.ambient_zones")

    ---------------------------------------------------------
    -- UI & visual
    ---------------------------------------------------------
    require("developer.config.hud_layout")
    require("developer.config.localization")
    require("developer.config.minimap_settings")
    require("developer.config.particle_effects")
    require("developer.config.screenshot_marker_settings")
    require("developer.config.tutorial_popups")
    require("developer.config.ui_theme")

    ---------------------------------------------------------
    -- Editor & tools (only needed in dev builds)
    ---------------------------------------------------------
    require("developer.config.layout_editor_settings")
    require("developer.tools.setup_wizard")
    require("developer.tools.dev_helpers")
end

return true
