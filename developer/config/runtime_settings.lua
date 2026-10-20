-- developer/config/runtime_settings.lua
-- Project-owned Project > Game Settings... overrides over authored baseline configuration.
-- Legacy local overrides remain available to the compatibility review API;
-- Game Settings does not adopt machine-local data.

local M = {}

local SavePaths = require "mvtk.core.save_paths"
local SETTINGS_FILE = "wizard_settings"

local Util = require("mvtk.core.util")
local GameConfig = require("developer.config.game_config")
local PlayerScale = require("mvtk.player.player_scale")
local CreatorModel = require "mvtk.core.creator_settings_model"
local ProjectSettings = CreatorModel.load_document(require "developer.config.creator_settings",
    require "developer.config.player_settings")
-- The creator settings bundled into this build. Project > Game Settings... Save swaps
-- ProjectSettings in memory; comparing against this shows a Build is needed.
local CompiledProject = CreatorModel.copy(ProjectSettings)
local resolved_cache = {}
local revision = 0

function M.invalidate()
    resolved_cache = {}
    revision = revision + 1
    package.loaded["developer.config.resolved_config"] = nil
end

function M.revision() return revision end

function M.reload()
    ProjectSettings = CreatorModel.load_document(require "developer.config.creator_settings",
        require "developer.config.player_settings")
    GameConfig = require "developer.config.game_config"
    M.invalidate()
end

-- Called only after a successful authoring transaction. Never writes local saves.
function M.use_project(doc)
    ProjectSettings = CreatorModel.copy(CreatorModel.validate(doc))
    package.loaded["developer.config.creator_settings"] = ProjectSettings
    M.invalidate()
end

function M.project_document() return CreatorModel.copy(ProjectSettings) end
function M.compiled_document() return CreatorModel.copy(CompiledProject) end

-- ============================================================================
-- CORE LOAD / SAVE / CLEAR
-- ============================================================================

-- Read retired machine-local settings for compatibility review only
function M.load()
    return CreatorModel.copy(ProjectSettings.published and ProjectSettings.overrides or {})
end

function M.load_legacy()
    if not sys or type(sys.load) ~= "function" then return nil end
    local path = SavePaths.path(SETTINGS_FILE, "wizard")
    local ok, data = pcall(sys.load, path)
    if ok and data and next(data) then
        return data
    end
    return nil
end

-- Legacy compatibility API. Game Settings saves use the project writer.
function M.save(settings)
    local path = SavePaths.path(SETTINGS_FILE, "wizard")
    print("[RUNTIME_SETTINGS] Saving to " .. tostring(path))
    local ok, err = pcall(sys.save, path, settings)
    if not ok then
        print("[RUNTIME_SETTINGS] Failed to save: " .. tostring(err))
        return false
    end
    print("[RUNTIME_SETTINGS] Save complete")
    return true
end

-- Clear only legacy local overrides; published project settings are unchanged.
function M.clear()
    local path = SavePaths.path(SETTINGS_FILE, "wizard")
    pcall(sys.save, path, {})
end

-- ============================================================================
-- SIMPLE GETTERS (runtime override → authored config module)
-- ============================================================================

local function runtime_section(key)
    local runtime = M.load()
    local value = runtime and runtime[key]
    if type(value) == "table" then
        return Util.deep_copy(value)
    end
    return value
end

-- Returns the project override for `key`, or the authored fallback.
-- IMPORTANT: callers must pass the fallback as an already-required module table,
-- using a string-literal require() at the call site. Defold's bob build tool
-- finds bundled .lua modules via static text analysis of require("literal"),
-- so requiring through a variable here would hide the dependency from the
-- bundler and the module would be missing at runtime (module not found).
local function runtime_or_module(key, fallback)
    local value = runtime_section(key)
    if type(value) == "table" and type(fallback) == "table" then
        local merged = Util.deep_copy(fallback)
        return Util.deep_merge(merged, value)
    end
    if value ~= nil then
        return value
    end
    if type(fallback) == "table" then
        return Util.deep_copy(fallback)
    end
    return fallback
end

local function runtime_or_game_config(runtime_key, config_key)
    return runtime_or_module(runtime_key,GameConfig[config_key] or {})
end

-- Shared resolver for creator-owned presentation/configuration modules. Literal
-- baseline requires remain at call sites so Defold includes their resources.
function M.section(key,baseline) return runtime_or_module(key,baseline) end

-- Get base player settings, preferring project overrides over the authored
-- config. These are the values authoring tools should display and save; no
-- player_scale multiplication has been applied yet.
function M.get_player_settings_base()
    return runtime_or_module("player", require("developer.config.player_settings"))
end

-- Get the runtime-scaled player settings used by gameplay consumers.
function M.get_player_settings()
    return PlayerScale.apply(M.get_player_settings_base())
end

-- Get ability defaults, preferring runtime over compiled
function M.get_ability_defaults()
    local abilities = runtime_section("abilities")
    if abilities then
        local baseline = require("developer.config.ability_defaults")
        return { abilities = CreatorModel.merge(CreatorModel.copy(baseline.abilities or {}), abilities) }
    end
    return require("developer.config.ability_defaults")
end

-- Tile settings are derived from imported tilesource art. Do not let old wizard
-- runtime saves override the generated project config.
function M.get_tile_settings()
    return require("developer.config.tile_settings")
end

-- Enemy settings are not configured by Game Settings (static placement is authored in Tiled).
-- Exposed here for code that uses runtime spawners or wave-based systems.
function M.get_enemy_settings()
    return require("developer.config.enemy_settings")
end

-- ============================================================================
-- COMBAT SETTINGS (custom transformation from player_actions)
-- ============================================================================

local function default_combat_features(CC)
    local cfg_features = (CC and CC.features) or {}
    local combo = (CC and CC.combo) or {}
    local features = {
        combo_chaining = cfg_features.combo_chaining,
        mixed_finishers = cfg_features.mixed_finishers,
        attack_cancels = cfg_features.attack_cancels,
        parry = cfg_features.parry,
        perfect_parry = cfg_features.perfect_parry,
        parry_counter = cfg_features.parry_counter,
        aerial_attacks = cfg_features.aerial_attacks,
        aerial_juggle = cfg_features.aerial_juggle,
    }

    if features.combo_chaining == nil then features.combo_chaining = combo.enabled ~= false end
    if features.mixed_finishers == nil then features.mixed_finishers = combo.mixed_combos ~= false end
    if features.attack_cancels == nil then features.attack_cancels = true end
    if features.parry == nil then features.parry = true end
    if features.perfect_parry == nil then features.perfect_parry = true end
    if features.parry_counter == nil then features.parry_counter = true end
    if features.aerial_attacks == nil then features.aerial_attacks = true end
    if features.aerial_juggle == nil then features.aerial_juggle = true end

    features.combo_chaining = features.combo_chaining ~= false
    features.mixed_finishers = features.combo_chaining and (features.mixed_finishers ~= false)
    features.parry = features.parry ~= false
    features.perfect_parry = features.parry and (features.perfect_parry ~= false)
    features.parry_counter = features.parry and (features.parry_counter ~= false)
    features.aerial_attacks = features.aerial_attacks ~= false
    features.aerial_juggle = features.aerial_attacks and (features.aerial_juggle ~= false)

    return features
end

local function build_default_combat_settings(CC)
    local attacks = (CC and CC.attacks) or {}
    local light = attacks.light_1
    local heavy = attacks.heavy_1
    local ranged = attacks.ranged_shot
    local ranged_projectile = ranged
        and ranged.timeline
        and ranged.timeline.active_windows
        and ranged.timeline.active_windows[1]
        and ranged.timeline.active_windows[1].projectile
        or nil
    local features = default_combat_features(CC)

    return {
        melee_light = {
            damage = light
                and light.timeline
                and light.timeline.active_windows
                and light.timeline.active_windows[1]
                and light.timeline.active_windows[1].hitboxes
                and light.timeline.active_windows[1].hitboxes[1]
                and light.timeline.active_windows[1].hitboxes[1].damage
                or 1,
            cooldown = light and light.cooldown or 0.18,
        },
        melee_heavy = {
            damage = heavy
                and heavy.timeline
                and heavy.timeline.active_windows
                and heavy.timeline.active_windows[1]
                and heavy.timeline.active_windows[1].hitboxes
                and heavy.timeline.active_windows[1].hitboxes[1]
                and heavy.timeline.active_windows[1].hitboxes[1].damage
                or 2,
        },
        ranged = {
            damage = ranged_projectile and ranged_projectile.damage or 1,
            projectile_speed = ranged_projectile and ranged_projectile.speed or 1200,
        },
        parry = {
            window = CC and CC.parry and CC.parry.window or 0.18,
            cooldown = CC and CC.parry and CC.parry.cooldown or 0.15,
            perfect_window = CC and CC.parry and CC.parry.perfect_window or 0.08,
        },
        combo = {
            enabled = features.combo_chaining,
            mixed_combos = features.mixed_finishers,
        },
        features = features,
    }
end

local function merge_combat_settings(defaults, runtime_combat)
    local merged = Util.deep_copy(defaults)
    if type(runtime_combat) ~= "table" then
        return merged
    end

    for _, key in ipairs({ "melee_light", "melee_heavy", "ranged", "parry" }) do
        if type(runtime_combat[key]) == "table" then
            Util.deep_merge(merged[key], runtime_combat[key])
        end
    end

    local has_feature_overrides = type(runtime_combat.features) == "table"
    if has_feature_overrides then
        Util.deep_merge(merged.features, runtime_combat.features)
    end

    if type(runtime_combat.combo) == "table" then
        Util.deep_merge(merged.combo, runtime_combat.combo)
        if not has_feature_overrides then
            if runtime_combat.combo.enabled ~= nil then
                merged.features.combo_chaining = runtime_combat.combo.enabled and true or false
            end
            if runtime_combat.combo.mixed_combos ~= nil then
                merged.features.mixed_finishers = runtime_combat.combo.mixed_combos and true or false
            end
        end
    end

    merged.features.combo_chaining = merged.features.combo_chaining ~= false
    merged.features.mixed_finishers = merged.features.combo_chaining and (merged.features.mixed_finishers ~= false)
    merged.features.parry = merged.features.parry ~= false
    merged.features.perfect_parry = merged.features.parry and (merged.features.perfect_parry ~= false)
    merged.features.parry_counter = merged.features.parry and (merged.features.parry_counter ~= false)
    merged.features.aerial_attacks = merged.features.aerial_attacks ~= false
    merged.features.aerial_juggle = merged.features.aerial_attacks and (merged.features.aerial_juggle ~= false)

    merged.combo.enabled = merged.features.combo_chaining
    merged.combo.mixed_combos = merged.features.mixed_finishers

    return merged
end

-- Get combat settings, preferring runtime over compiled
function M.get_combat_settings()
    local player = M.get_player_settings_base()
    local defaults = build_default_combat_settings(PlayerScale.convert_units(
        require("developer.config.combat_config"), "combat_config", player))
    local authored = PlayerScale.convert_units(require("developer.config.combat_overrides"),
        "combat_overrides", player)
    defaults = merge_combat_settings(defaults, authored.combat)
    local runtime = M.load()
    if runtime and runtime.combat then
        return merge_combat_settings(defaults, runtime.combat)
    end
    return defaults
end

-- ============================================================================
-- GAME SETTINGS (custom transformation from settings_defaults)
-- ============================================================================

-- Get game settings (camera shake, damage numbers, etc.)
function M.get_game_settings()
    local runtime = runtime_section("game_settings")
    local SD = require("developer.config.settings_defaults")
    return CreatorModel.merge({
        camera_shake = SD.gameplay.camera_shake ~= false,
        damage_numbers = SD.gameplay.damage_numbers == true,
        icon_theme = SD.gameplay.icon_theme or "xbox",
    }, runtime or {})
end

-- Unscaled authored defaults for inheritance and the migration comparison.
-- These literal dependencies are also visible to Defold's module bundler.
function M.authored_snapshot()
    local player = CreatorModel.copy(require "developer.config.player_settings")
    -- Companion files share the project's saved movement-scaling switch while
    -- the returned player table stays the authored inheritance baseline.
    local unit_context = M.get_player_settings_base()
    local combat = build_default_combat_settings(PlayerScale.convert_units(
        require("developer.config.combat_config"), "combat_config", unit_context))
    combat = merge_combat_settings(combat, PlayerScale.convert_units(
        require("developer.config.combat_overrides"), "combat_overrides", unit_context).combat)
    return {
        player = player,
        abilities = CreatorModel.copy(require("developer.config.ability_defaults").abilities),
        combat = combat,
        game_completion = CreatorModel.copy(require "developer.config.game_completion"),
        camera = CreatorModel.copy(GameConfig.camera),
        progression = CreatorModel.copy(GameConfig.progression),
        hud_layout = CreatorModel.copy(require "developer.config.hud_layout"),
        ui_theme = CreatorModel.copy(require "developer.config.ui_theme"),
        map_discovery = CreatorModel.copy(require "developer.config.map_discovery_settings"),
        minimap = CreatorModel.copy(require "developer.config.minimap_settings"),
        world_map = CreatorModel.copy(require "developer.config.world_map_settings"),
        player_art = CreatorModel.copy(PlayerScale.convert_units(require "developer.config.player_art",
            "player_art", unit_context)),
        movement_test = CreatorModel.copy(require "developer.config.movement_test"),
        screenshot_markers = CreatorModel.copy(require "developer.config.screenshot_marker_settings"),
        game_settings = CreatorModel.copy(require("developer.config.settings_defaults").gameplay),
    }
end

-- ============================================================================
-- GAME CONFIG GETTERS (runtime override → authored game_config)
-- ============================================================================
-- These expose game_config.lua sections with project overrides when present.

-- Get elite enemy configuration (health/damage multipliers, etc.)
function M.get_elite_config()
    return runtime_or_game_config("elite", "elite")
end

-- Get attack hitbox configuration (offsets, lifetimes, stun times)
function M.get_hitbox_config()
    return runtime_or_game_config("attack_hitbox", "attack_hitbox")
end

-- Get camera configuration
function M.get_camera_config()
    return runtime_or_game_config("camera", "camera")
end

-- Get visual toggle settings (parallax, particles, etc.)
function M.get_visual_config()
    return runtime_or_game_config("visual", "visual")
end

-- Get spawn/respawn configuration (custom transformation)
function M.get_spawn_config()
    local player_cfg = runtime_section("player") or Util.deep_copy(GameConfig.player or {})
    return {
        spawn_room = player_cfg.spawn_room,
        spawn_marker = player_cfg.spawn_marker,
        player_type = player_cfg.player_type,
    }
end

-- Resolve once per revision; callers receive copies so mutation cannot pollute
-- another consumer. A successful apply or explicit reload invalidates these.
for _, name in ipairs({ "get_player_settings_base", "get_player_settings", "get_ability_defaults",
    "get_combat_settings", "get_game_settings", "authored_snapshot", "get_camera_config",
    "get_visual_config", "get_elite_config", "get_hitbox_config", "get_spawn_config" }) do
    local resolve = M[name]
    M[name] = function()
        if resolved_cache[name] == nil then resolved_cache[name] = resolve() end
        return CreatorModel.copy(resolved_cache[name])
    end
end

return M
