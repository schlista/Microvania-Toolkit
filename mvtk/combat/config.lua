-- mvtk/combat/config.lua
-- Runtime combat config resolution and attack lookup.

local Util = require "mvtk.core.util"
local RuntimeSettings = require "developer.config.runtime_settings"
local PlayerScale = require "mvtk.player.player_scale"

local COMBAT_CONFIG_MODULE = "developer.config.combat_config"

local function load_combat_source()
    return PlayerScale.convert_units(Util.require_config(COMBAT_CONFIG_MODULE) or {},
        "combat_config", RuntimeSettings.get_player_settings())
end

local CombatConfig = load_combat_source()

local M = {}

local cached = nil
local cached_revision = nil
local FEATURE_DEFAULTS = {
    combo_chaining = true,
    mixed_finishers = true,
    attack_cancels = true,
    parry = true,
    perfect_parry = true,
    parry_counter = true,
    aerial_attacks = true,
    aerial_juggle = true,
}

local function clone(tbl)
    return Util.deep_copy(tbl or {})
end

-- Wizard-generated combat overrides live in developer/config/combat_overrides.lua.
-- Treat its absence as "no overrides" so projects that haven't run the wizard
-- still load. Loaded fresh each call so a hot-reload (F7) re-reads the file
-- after package.loaded["developer.config.combat_overrides"] has been nilled.
local COMBAT_OVERRIDES_MODULE = "developer.config.combat_overrides"

local function load_wizard_overrides()
    local ok, data = pcall(require, COMBAT_OVERRIDES_MODULE)
    if ok and type(data) == "table" then
        data = PlayerScale.convert_units(data, "combat_overrides", RuntimeSettings.get_player_settings())
        return data.combat or {}
    end
    return {}
end

local function get_runtime_overrides()
    local merged = {}
    -- 1. File-based wizard overrides (canonical, version-controlled).
    Util.deep_merge(merged, load_wizard_overrides())
    -- 2. Published project-owned creator overrides.
    local runtime = RuntimeSettings.load and RuntimeSettings.load() or nil
    if runtime and runtime.combat then
        Util.deep_merge(merged, runtime.combat)
    end
    return merged
end

local function apply_attack_runtime_overrides(config, runtime)
    local attacks = config.attacks or {}
    local light = runtime.melee_light or {}
    local heavy = runtime.melee_heavy or {}
    local ranged = runtime.ranged or {}
    local parry = runtime.parry or {}

    -- Helper: walk to attack.timeline.active_windows[1].hitboxes[1] and apply
    -- damage / hitbox width / hitbox height overrides if provided. Keeps the
    -- existing damage-override behavior and adds size handling for the wizard
    -- generated overrides table.
    local function apply_melee_overrides(attack, src)
        if not attack or not src then return end
        if src.cooldown ~= nil then
            attack.cooldown = tonumber(src.cooldown) or attack.cooldown
        end
        local windows = attack.timeline and attack.timeline.active_windows or nil
        local hitboxes = windows and windows[1] and windows[1].hitboxes or nil
        local hb = hitboxes and hitboxes[1] or nil
        if not hb then return end
        if src.damage ~= nil then
            hb.damage = tonumber(src.damage) or hb.damage
        end
        local size = src.hitbox
        if type(size) == "table" then
            if size.width ~= nil then
                hb.width = tonumber(size.width) or hb.width
            end
            if size.height ~= nil then
                hb.height = tonumber(size.height) or hb.height
            end
        end
    end

    apply_melee_overrides(attacks.light_1, light)
    apply_melee_overrides(attacks.heavy_1, heavy)
    if attacks.ranged_shot then
        attacks.ranged_shot.cooldown = tonumber(ranged.cooldown) or attacks.ranged_shot.cooldown
        local windows = attacks.ranged_shot.timeline and attacks.ranged_shot.timeline.active_windows or nil
        local projectile = windows and windows[1] and windows[1].projectile or nil
        if projectile then
            projectile.damage = tonumber(ranged.damage) or projectile.damage
            projectile.speed = tonumber(ranged.projectile_speed) or projectile.speed
        end
    end
    if config.parry then
        config.parry.window = tonumber(parry.window) or config.parry.window
        config.parry.cooldown = tonumber(parry.cooldown) or config.parry.cooldown
        config.parry.perfect_window = tonumber(parry.perfect_window) or config.parry.perfect_window
    end

    -- Player attack geometry follows the same one-knob body scale as the
    -- baked sprite/colliders. This runs after wizard/runtime overrides so all
    -- configured dimensions remain base-scale values.
    if not config._player_scale_applied then
        local player = RuntimeSettings.get_player_settings()
        local scale = tonumber(player and player.player_scale) or 1.0
        if scale < PlayerScale.MIN_SCALE then scale = PlayerScale.MIN_SCALE end
        if scale > PlayerScale.MAX_SCALE then scale = PlayerScale.MAX_SCALE end

        local function scale_melee_hitbox(attack)
            local windows = attack and attack.timeline and attack.timeline.active_windows or nil
            local hitboxes = windows and windows[1] and windows[1].hitboxes or nil
            local hitbox = hitboxes and hitboxes[1] or nil
            if not hitbox then return end
            if type(hitbox.width) == "number" then hitbox.width = hitbox.width * scale end
            if type(hitbox.height) == "number" then hitbox.height = hitbox.height * scale end
        end

        scale_melee_hitbox(attacks.light_1)
        scale_melee_hitbox(attacks.heavy_1)
        if player and player.scale_movement ~= false and attacks.ranged_shot then
            local windows = attacks.ranged_shot.timeline and attacks.ranged_shot.timeline.active_windows or nil
            local projectile = windows and windows[1] and windows[1].projectile or nil
            if projectile and type(projectile.speed) == "number" then
                projectile.speed = projectile.speed * scale
            end
        end
        config._player_scale_applied = true
    end
end

local function normalize_features(config, runtime)
    local combo_cfg = config.combo or {}
    local runtime_features = runtime.features or {}
    local runtime_combo = runtime.combo or {}

    config.features = clone(config.features or {})
    local features = config.features

    if features.combo_chaining == nil then
        features.combo_chaining = combo_cfg.enabled ~= false
    end
    if features.mixed_finishers == nil then
        features.mixed_finishers = combo_cfg.mixed_combos ~= false
    end
    for key, default in pairs(FEATURE_DEFAULTS) do
        if features[key] == nil then
            features[key] = default
        end
    end

    for key, _ in pairs(FEATURE_DEFAULTS) do
        if runtime_features[key] ~= nil then
            features[key] = runtime_features[key] and true or false
        end
    end

    if runtime_combo.enabled ~= nil and runtime_features.combo_chaining == nil then
        features.combo_chaining = runtime_combo.enabled and true or false
    end
    if runtime_combo.mixed_combos ~= nil and runtime_features.mixed_finishers == nil then
        features.mixed_finishers = runtime_combo.mixed_combos and true or false
    end

    features.combo_chaining = features.combo_chaining ~= false
    features.mixed_finishers = features.combo_chaining and (features.mixed_finishers ~= false)
    features.parry = features.parry ~= false
    features.perfect_parry = features.parry and (features.perfect_parry ~= false)
    features.parry_counter = features.parry and (features.parry_counter ~= false)
    features.aerial_attacks = features.aerial_attacks ~= false
    features.aerial_juggle = features.aerial_attacks and (features.aerial_juggle ~= false)

    config.combo = config.combo or {}
    config.combo.enabled = features.combo_chaining
    config.combo.mixed_combos = features.mixed_finishers
end

local function build_cache()
    local config = clone(CombatConfig)
    config.attacks = config.attacks or {}
    config.attack_sets = config.attack_sets or {}
    config.feedback = config.feedback or {}
    config.parry = config.parry or {}
    local runtime = get_runtime_overrides()
    apply_attack_runtime_overrides(config, runtime)
    normalize_features(config, runtime)
    return config
end

function M.reload()
    -- Drop the resolved cache AND the underlying source-table caches so the
    -- next get() walks the file system again. Without nilling
    -- package.loaded[...] the require would short-circuit and reload would
    -- be a no-op for live edits to combat_config.lua / combat_overrides.lua.
    package.loaded[COMBAT_CONFIG_MODULE] = nil
    package.loaded[COMBAT_OVERRIDES_MODULE] = nil
    CombatConfig = load_combat_source()
    cached = build_cache()
    cached_revision = RuntimeSettings.revision()
    return cached
end

function M.get()
    if not cached or cached_revision ~= RuntimeSettings.revision() then
        cached = build_cache()
        cached_revision = RuntimeSettings.revision()
    end
    return cached
end

function M.features()
    local config = M.get()
    return (config and config.features) or {}
end

function M.feature_enabled(key, fallback)
    local features = M.features()
    local value = features[key]
    if value == nil then
        if fallback == nil then
            return true
        end
        return fallback and true or false
    end
    return value and true or false
end

function M.resolve_attack(attack_id)
    local config = M.get()
    local attacks = config.attacks or {}
    local base = attacks[attack_id]
    if not base then
        return nil
    end

    local out = clone(base)
    out.attack_id = out.attack_id or attack_id
    return out
end

function M.resolve_attack_set()
    local config = M.get()
    local attack_sets = config.attack_sets or {}
    local set_id = config.default_attack_set
    local attack_set = attack_sets[set_id]
    if attack_set then
        return attack_set, set_id
    end
    return attack_sets.default or {}, set_id or "default"
end

function M.resolve_attack_for_input(intent, ctx)
    local config = M.get()
    local attack_set = select(1, M.resolve_attack_set())
    local features = config.features or {}
    local grounded = ctx and ctx.grounded
    local aerial_enabled = features.aerial_attacks ~= false
    local juggle_enabled = aerial_enabled and (features.aerial_juggle ~= false)
    local counter_enabled = features.parry_counter ~= false
    local mode = (grounded or not aerial_enabled) and "grounded" or "aerial"
    local bucket = attack_set[mode] or attack_set.default or {}

    if intent == "light" and ctx and ctx.want_down_strike and aerial_enabled and bucket.down_strike then
        return bucket.down_strike
    end
    if intent == "light" and ctx and ctx.want_charged and bucket.charged then
        return bucket.charged
    end
    if ctx and ctx.counter_window and counter_enabled and attack_set.parry and attack_set.parry.counter and (intent == "light" or intent == "heavy") then
        return attack_set.parry.counter
    end

    local attack_id = bucket[intent] or (attack_set.default and attack_set.default[intent]) or (config.default_inputs and config.default_inputs[intent])
    if (not grounded) and aerial_enabled and (not juggle_enabled) and intent == "heavy" then
        local aerial_heavy = attack_set.aerial and attack_set.aerial.heavy
        if attack_id == aerial_heavy then
            local grounded_bucket = attack_set.grounded or attack_set.default or {}
            attack_id = grounded_bucket[intent] or attack_id
        end
    end
    return attack_id
end

return M
