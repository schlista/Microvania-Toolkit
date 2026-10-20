-- mvtk/abilities/ability_manager.lua-- Central manager for ability definitions, unlock flow, and stamina budget.

local Util = require "mvtk.core.util"
local Debug = Util.require_config('developer.config.debug_config')
local ability_log = Util.make_debug_log("[ABILITY]", function()
    return Debug.global.enable or (Debug.gameplay and Debug.gameplay.ability_manager)
end)

-- Debug-gate all print() calls in this module so they only fire when enabled.
local _orig_print = print
local function print(...)  -- luacheck: ignore 121
    if Debug.gameplay and Debug.gameplay.ability_manager then
        _orig_print(...)
    end
end

local FlagsOk, Flags = pcall(require, "mvtk.core.flags")

-- Force require abilities.lua so Defold compiles it into the bundle
-- Using direct require to ensure the dependency is tracked
local AbilityConfig = nil
local HasConfig = false
do
    -- Try to require normally first
    local ok, result = pcall(function()
        return require("developer.config.abilities")
    end)
    if ok and type(result) == "table" then
        AbilityConfig = result
        HasConfig = true
    else
        print("[ABILITY_MANAGER] Failed to load abilities config: " .. tostring(result))
    end
end

print(string.format("[ABILITY_MANAGER] LOAD: HasConfig=%s, AbilityConfig type=%s", tostring(HasConfig), type(AbilityConfig)))
if not HasConfig then
    print("[ABILITY_MANAGER] LOAD ERROR: abilities.lua not found or invalid")
elseif AbilityConfig and AbilityConfig.abilities then
    local count = 0
    for _ in pairs(AbilityConfig.abilities) do count = count + 1 end
    print(string.format("[ABILITY_MANAGER] LOAD: Found %d abilities in config", count))
end
local RuntimeSettingsOk, RuntimeSettings = pcall(require, "developer.config.runtime_settings")
-- Ability start defaults come from project settings or compiled defaults.
-- Read at use time so RuntimeSettings.use_project can replace the snapshot.
-- Creator edits need Prepare & Check and Build before playing.
local function current_ability_defaults()
    if not RuntimeSettingsOk or not RuntimeSettings or not RuntimeSettings.get_ability_defaults then
        return nil
    end
    local ok, defaults = pcall(RuntimeSettings.get_ability_defaults)
    if ok and type(defaults) == "table" and type(defaults.abilities) == "table" then
        return defaults
    end
    return nil
end

-- Start-only unlocks that ProgressionManager revoked because the current
-- settings no longer grant them. A saved abilities payload must not re-grant
-- them (see mvtk/abilities/ability_provenance.lua).
local revoked_start_unlocks = {}

local FALLBACK_STAMINA = {
    max = 100,
    regen_per_sec = 25,
}

-- Only used if developer/config/abilities.lua is missing.
local FALLBACK_ABILITIES = {
    double_jump = {
        name = "Double Jump",
        description = "Jump again while in the air",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
    air_dash = {
        name = "Air Dash",
        description = "Dash through the air in any direction",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 1.0,
        stamina_cost = 10,
    },
    wall_climb = {
        name = "Wall Climb",
        description = "Cling to and climb walls",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 5,
    },
    slide = {
        name = "Slide",
        description = "Slide along the ground at high speed",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0.5,
        stamina_cost = 5,
    },
    extended_jump = {
        name = "Extended Jump",
        description = "Hold jump for extra height and hang time",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
    grapple = {
        name = "Grapple",
        description = "Latch onto anchors and pull yourself forward",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 3.0,
        stamina_cost = 15,
    },
    glide = {
        name = "Glide",
        description = "Hold JUMP while falling to glide",
        category = "movement",
        starts_unlocked = false,  -- Must be picked up
        enabled = true,
        cooldown = 0,
        stamina_cost = 2,
    },

    charge_attack = {
        name = "Charge Attack",
        description = "Hold attack to charge up a powerful strike",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 2.0,
        stamina_cost = 20,
    },
    down_strike = {
        name = "Down Strike",
        description = "Strike downward while in the air",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 1.5,
        stamina_cost = 15,
    },
    ranged_attack = {
        name = "Ranged Attack",
        description = "Launch projectiles at enemies",
        category = "combat",
        enabled = true,
        starts_unlocked = false,  -- Must be picked up
        cooldown = 0.8,
        stamina_cost = 10,
    },
    slide_iframes = {
        name = "Slide Invincibility",
        description = "Become invulnerable during slide",
        category = "defensive",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
    air_dash_iframes = {
        name = "Dash Invincibility",
        description = "Become invulnerable during air dash",
        category = "defensive",
        enabled = true,
        cooldown = 0,
        stamina_cost = 0,
    },
}

local deep_copy = Util.deep_copy
local normalize_ability_id = Util.normalize_ability_id

local function resolve_registry()
    if HasConfig and AbilityConfig and type(AbilityConfig.abilities) == "table" then
        local count = 0
        for _ in pairs(AbilityConfig.abilities) do count = count + 1 end
        print(string.format("[ABILITY_MANAGER] Loaded %d ability definitions", count))
        return deep_copy(AbilityConfig.abilities)
    end
    print("[ABILITY_MANAGER] INFO: developer/config/abilities.lua not found - using fallback abilities")
    print("[ABILITY_MANAGER] HINT: Create this file to define custom abilities (double_jump, dash, wall_climb, etc.)")
    return deep_copy(FALLBACK_ABILITIES)
end

local function resolve_stamina()
    if HasConfig and AbilityConfig and type(AbilityConfig.stamina) == "table" then
        local cfg = AbilityConfig.stamina
        return {
            max = tonumber(cfg.max) or FALLBACK_STAMINA.max,
            regen_per_sec = tonumber(cfg.regen_per_sec) or FALLBACK_STAMINA.regen_per_sec,
        }
    end
    ability_log("[ABILITY_MANAGER] Using fallback stamina defaults")
    return Util.shallow_copy(FALLBACK_STAMINA)
end

local ABILITIES = resolve_registry()

local player_abilities = {}
local ability_cooldowns = {}
local stamina = FALLBACK_STAMINA.max
local max_stamina = FALLBACK_STAMINA.max
local stamina_regen_per_sec = FALLBACK_STAMINA.regen_per_sec

local listeners = {}
local next_listener_token = 0
local initialized = false

local M = {}

local function notify(event, ability_id)
    -- A nil id represents a complete restore/reset rather than one ability.
    local state = player_abilities[ability_id]
    local definition = ABILITIES[ability_id]
    for token, cb in pairs(listeners) do
        local ok, err = pcall(cb, event, ability_id, state, definition)
        if not ok then
            ability_log(string.format("[ABILITY_MANAGER] listener %s error: %s", tostring(token), tostring(err)))
        end
    end
end

local function sync_flag(ability_id, unlocked)
    if not (FlagsOk and Flags and ability_id) then return end
    local name = normalize_ability_id(ability_id) or tostring(ability_id)
    if unlocked then
        Flags.set(name, true)
    else
        Flags.clear(name)
    end
end

local function sync_all_flags()
    for ability_id, state in pairs(player_abilities) do
        sync_flag(ability_id, state.unlocked)
    end
end

local function ability_state_from_hint(ability_id, hint)
    if type(hint) ~= "table" then return nil end
    local direct = hint[ability_id]
    if direct == nil then return nil end
    if type(direct) == "table" then return direct end
    return { unlocked = direct and true or false }
end

local function ensure_registry()
    ABILITIES = resolve_registry()
end

local function apply_stamina_settings(settings)
    stamina_regen_per_sec = tonumber(settings.regen_per_sec) or stamina_regen_per_sec
    max_stamina = tonumber(settings.max) or max_stamina
    stamina = Util.clamp(stamina, 0, max_stamina)
end

local function mark_initialized()
    initialized = true
    sync_all_flags()
end

local function reset_state()
    player_abilities = {}
    ability_cooldowns = {}
end

local function init_tables(opts)
    print("[ABILITY_MANAGER] ========== INIT_TABLES START ==========")
    ensure_registry()
    reset_state()

    local unlocked_hint
    local stamina_hint

    if type(opts) == "table" then
        unlocked_hint = opts.unlocked or opts.abilities
        stamina_hint = opts.stamina
    end
    local ability_defaults = current_ability_defaults()
    local defaults_hint = ability_defaults and ability_defaults.abilities
    print(string.format("[ABILITY_MANAGER] DefaultsOk=%s, has_defaults_hint=%s", tostring(ability_defaults ~= nil), tostring(defaults_hint ~= nil)))
    if type(defaults_hint) == "table" then
        if unlocked_hint == nil or (type(unlocked_hint) == "table" and next(unlocked_hint) == nil) then
            print("[ABILITY_MANAGER] Using defaults_hint as unlocked_hint (no save data)")
            unlocked_hint = defaults_hint
        end
    end

    local stamina_settings = resolve_stamina()
    apply_stamina_settings(stamina_settings)

    if type(stamina_hint) == "table" then
        if stamina_hint.max then
            max_stamina = Util.clamp(tonumber(stamina_hint.max) or max_stamina, 1, math.huge)
        end
        if stamina_hint.current or stamina_hint.value then
            stamina = Util.clamp(tonumber(stamina_hint.current or stamina_hint.value) or stamina, 0, max_stamina)
        elseif stamina_hint.stamina then
            stamina = Util.clamp(tonumber(stamina_hint.stamina) or stamina, 0, max_stamina)
        end
        if stamina_hint.regen_per_sec then
            stamina_regen_per_sec = tonumber(stamina_hint.regen_per_sec) or stamina_regen_per_sec
        end
    end

    -- Log key abilities initialization
    local key_abilities = { "double_jump", "air_dash", "wall_climb", "slide", "glide" }

    for ability_id, def in pairs(ABILITIES) do
        local override = ability_state_from_hint(ability_id, unlocked_hint)
        local unlocked = override and override.unlocked
        local unlock_reason = "override"
        if unlocked == nil then
            if def.starts_unlocked then
                unlocked = true
                unlock_reason = "starts_unlocked=true"
            else
                unlocked = false
                unlock_reason = "pickup or configured start unlock required"
            end
        end

        local enabled = def.enabled ~= false
        if override and override.enabled ~= nil then
            enabled = override.enabled and true or false
        end

        player_abilities[ability_id] = {
            unlocked = unlocked,
            enabled = enabled,
        }

        -- Log key abilities
        for _, key_id in ipairs(key_abilities) do
            if ability_id == key_id then
                print(string.format("[ABILITY_MANAGER] INIT %s: unlocked=%s (reason: %s), enabled=%s, starts_unlocked=%s",
                    ability_id, tostring(unlocked), unlock_reason, tostring(enabled), tostring(def.starts_unlocked)))
            end
        end

        ability_cooldowns[ability_id] = (override and override.current_cooldown) and math.max(0, override.current_cooldown) or 0
    end

    local ability_count = 0
    for _ in pairs(player_abilities) do
        ability_count = ability_count + 1
    end
    print(string.format('[ABILITY_MANAGER] Ability system initialized (abilities=%d)', ability_count))
    print("[ABILITY_MANAGER] ========== INIT_TABLES END ==========")

    mark_initialized()
end

-- Public API ---------------------------------------------------------------------------------------------------------

function M.reset()
    initialized = false
    revoked_start_unlocks = {}
    reset_state()
    ability_cooldowns = {}
    stamina = FALLBACK_STAMINA.max
    max_stamina = FALLBACK_STAMINA.max
    stamina_regen_per_sec = FALLBACK_STAMINA.regen_per_sec
    notify("reset", nil)
end

function M.init(opts)
  if initialized and (opts == nil) then
    return
  end
  init_tables(opts)
end

--- Called by ProgressionManager.init with the start-only unlocks it revoked.
-- load_save_data keeps these locked even if an older payload unlocked them.
function M.set_revoked_start_unlocks(set)
    revoked_start_unlocks = {}
    for ability_id, revoked in pairs(set or {}) do
        if revoked then revoked_start_unlocks[ability_id] = true end
    end
end

function M.register_listener(callback)
    if type(callback) ~= "function" then return nil end
    next_listener_token = next_listener_token + 1
    listeners[next_listener_token] = callback
    return next_listener_token
end

function M.unregister_listener(token)
    listeners[token] = nil
end

local function ensure_init()
    if not initialized then
        M.init(1)
    end
end

function M.unlock_ability(ability_id, opts)
    local raw_id = ability_id
    ability_id = normalize_ability_id(ability_id)
    print(string.format("[ABILITY_MANAGER] unlock_ability(%s -> %s) called, opts.enabled=%s",
        tostring(raw_id), tostring(ability_id), tostring(opts and opts.enabled)))
    if not ability_id then
        print("[ABILITY_MANAGER] unlock_ability aborted: invalid ability id")
        return false
    end
    ensure_init()
    local state = player_abilities[ability_id]
    print(string.format("[ABILITY_MANAGER] Current state for %s: %s", tostring(ability_id), state and string.format("unlocked=%s enabled=%s", tostring(state.unlocked), tostring(state.enabled)) or "nil"))
    if not state then return false end
    if state.unlocked then
        print(string.format("[ABILITY_MANAGER] Ability %s already unlocked, returning false", ability_id))
        if opts and opts.enabled ~= nil then
            M.set_ability_enabled(ability_id, opts.enabled)
        end
        return false
    end
    state.unlocked = true
    revoked_start_unlocks[ability_id] = nil
    if opts and opts.enabled ~= nil then
        state.enabled = opts.enabled and true or false
    end
    sync_flag(ability_id, true)
    notify("unlock", ability_id)
    print(string.format("[ABILITY_MANAGER] Ability UNLOCKED: %s (unlocked=%s enabled=%s)", ability_id, tostring(state.unlocked), tostring(state.enabled)))
    
    -- Autosave to persist ability unlock immediately (survives quit/death without save point)
    local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if ok_cp and Checkpoint and Checkpoint.autosave then
        pcall(Checkpoint.autosave, "ability_unlock")
        print(string.format("[ABILITY_MANAGER] Autosaved after unlocking %s", ability_id))
    end
    
    return true
end

function M.can_use_ability(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return false end
    ensure_init()
    local state = player_abilities[ability_id]
    local def = ABILITIES[ability_id]
    if not state or not def then return false end
    if not state.unlocked or not state.enabled then return false end
    if ability_cooldowns[ability_id] > 0 then return false end
    if stamina < (def.stamina_cost or 0) then return false end
    return true
end

function M.use_ability(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return false end
    ensure_init()
    if not M.can_use_ability(ability_id) then return false end
    local def = ABILITIES[ability_id]
    ability_cooldowns[ability_id] = def.cooldown or 0
    stamina = Util.clamp(stamina - (def.stamina_cost or 0), 0, max_stamina)
    notify("use", ability_id)
    ability_log(string.format("[ABILITY_MANAGER] Used ability: %s (stamina %.1f/%.1f)", def.name or ability_id, stamina, max_stamina))
    return true
end

function M.set_ability_enabled(ability_id, enabled)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return end
    ensure_init()
    local state = player_abilities[ability_id]
    if not state then return end
    local new_enabled = enabled and true or false
    if state.enabled == new_enabled then return end
    state.enabled = new_enabled
    notify("toggle", ability_id)
    ability_log(string.format("[ABILITY_MANAGER] %s ability: %s", new_enabled and "Enabled" or "Disabled", ability_id))
end

function M.get_ability_info(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return nil end
    ensure_init()
    local def = ABILITIES[ability_id]
    local state = player_abilities[ability_id]
    if not def or not state then return nil end
    return {
        id = ability_id,
        name = def.name,
        description = def.description,
        category = def.category,
        unlocked = state.unlocked,
        enabled = state.enabled,
        cooldown = def.cooldown,
        stamina_cost = def.stamina_cost,
        current_cooldown = ability_cooldowns[ability_id] or 0,
    }
end

function M.get_abilities_by_category(category)
    ensure_init()
    local list = {}
    for ability_id, def in pairs(ABILITIES) do
        if def.category == category then
            table.insert(list, M.get_ability_info(ability_id))
        end
    end
    return list
end

function M.get_unlocked_abilities()
    ensure_init()
    local list = {}
    for ability_id, state in pairs(player_abilities) do
        if state.unlocked then
            table.insert(list, M.get_ability_info(ability_id))
        end
    end
    return list
end

function M.update(dt)
    ensure_init()
    if dt and dt > 0 then
        for ability_id, cooldown in pairs(ability_cooldowns) do
            if cooldown > 0 then
                ability_cooldowns[ability_id] = math.max(0, cooldown - dt)
            end
        end
        if stamina < max_stamina then
            local regen = stamina_regen_per_sec * dt
            stamina = Util.clamp(stamina + regen, 0, max_stamina)
        end
    end
end

function M.get_stamina()
    ensure_init()
    return stamina, max_stamina
end

function M.set_stamina(current, maximum)
    ensure_init()
    if maximum ~= nil then
        max_stamina = Util.clamp(tonumber(maximum) or max_stamina, 1, math.huge)
    end
    if current ~= nil then
        stamina = Util.clamp(tonumber(current) or stamina, 0, max_stamina)
    end
end

function M.get_save_data()
    ensure_init()
    local abilities = {}
    for ability_id, state in pairs(player_abilities) do
        abilities[ability_id] = {
            unlocked = state.unlocked,
            enabled = state.enabled,
            current_cooldown = ability_cooldowns[ability_id] or 0,
        }
    end
    return {
        abilities = abilities,
        stamina = stamina,
        max_stamina = max_stamina,
        regen_per_sec = stamina_regen_per_sec,
    }
end

function M.load_save_data(save_data)
    print("[ABILITY_MANAGER] ========== LOAD_SAVE_DATA START ==========")
    ensure_init()
    if type(save_data) ~= "table" then
        print("[ABILITY_MANAGER] save_data is not a table, returning")
        return
    end

    local key_abilities = { "double_jump", "air_dash", "wall_climb", "slide", "glide" }
    local ability_defaults = current_ability_defaults()
    local start_defaults = ability_defaults and ability_defaults.abilities or {}

    if type(save_data.abilities) == "table" then
        for ability_key, saved_state in pairs(save_data.abilities) do
            local ability_id = normalize_ability_id(ability_key) or tostring(ability_key)
            if ability_id ~= tostring(ability_key) then
                print(string.format("[ABILITY_MANAGER] Normalized save ability key %s -> %s",
                    tostring(ability_key), tostring(ability_id)))
            end
            local state = player_abilities[ability_id]
            if state and type(saved_state) == "table" then
                local def = ABILITIES[ability_id]
                local before_unlocked = state.unlocked
                if saved_state.unlocked ~= nil then
                    state.unlocked = saved_state.unlocked and true or false
                end
                if saved_state.enabled ~= nil then
                    state.enabled = saved_state.enabled and true or false
                end
                if def and def.starts_unlocked then
                    -- Enforce config default even if old save says otherwise
                    print(string.format("[ABILITY_MANAGER] WARN: %s has starts_unlocked=true, forcing unlock", ability_id))
                    state.unlocked = true
                    if def.enabled ~= nil then
                        state.enabled = def.enabled and true or false
                    end
                elseif start_defaults[ability_id] == true and not state.unlocked then
                    -- ability_defaults.lua calls itself the single source of truth for
                    -- what is unlocked at game start, so a developer flipping an entry
                    -- to `true` must take effect on saves written before the change --
                    -- otherwise the switch appears to do nothing and the only way to
                    -- test the ability is to delete the save. This only ever unlocks.
                    print(string.format("[ABILITY_MANAGER] %s is start-unlocked in ability_defaults.lua; overriding saved lock", ability_id))
                    state.unlocked = true
                end
                ability_cooldowns[ability_id] = math.max(0, tonumber(saved_state.current_cooldown) or 0)

                -- Log key abilities
                for _, key_id in ipairs(key_abilities) do
                    if ability_id == key_id then
                        print(string.format("[ABILITY_MANAGER] LOAD %s: save_unlocked=%s -> final_unlocked=%s, enabled=%s",
                            ability_id, tostring(saved_state.unlocked), tostring(state.unlocked), tostring(state.enabled)))
                    end
                end
            end
        end
    end
    -- Start-only unlocks the current settings no longer grant stay locked even
    -- when this (older) payload says unlocked; ProgressionManager decided this
    -- from the save's recorded sources.
    for ability_id in pairs(revoked_start_unlocks) do
        local state = player_abilities[ability_id]
        if state and state.unlocked and not (ABILITIES[ability_id] and ABILITIES[ability_id].starts_unlocked) then
            state.unlocked = false
            print(string.format("[ABILITY_MANAGER] %s re-locked: it was only a start unlock and the current settings no longer grant it", ability_id))
        end
    end
    if save_data.max_stamina then
        max_stamina = Util.clamp(tonumber(save_data.max_stamina) or max_stamina, 1, math.huge)
    end
    if save_data.stamina then
        stamina = Util.clamp(tonumber(save_data.stamina) or stamina, 0, max_stamina)
    end
    if save_data.regen_per_sec then
        stamina_regen_per_sec = tonumber(save_data.regen_per_sec) or stamina_regen_per_sec
    end
    sync_all_flags()
    notify("load", nil)
    print("[ABILITY_MANAGER] ========== LOAD_SAVE_DATA END ==========")
end

function M.is_ability_unlocked(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return false end
    ensure_init()
    local state = player_abilities[ability_id]
    return state and state.unlocked or false
end

function M.has_ability(ability_id)
    -- Backwards-compatible alias used by other systems (e.g. gate manager)
    return M.is_ability_unlocked(ability_id)
end

function M.get_ability_cooldown(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return 0 end
    ensure_init()
    return ability_cooldowns[ability_id] or 0
end

function M.force_unlock_ability(ability_id)
    ability_id = normalize_ability_id(ability_id)
    if not ability_id then return end
    ensure_init()
    if M.unlock_ability(ability_id) then
        ability_log(string.format("[ABILITY_MANAGER] Force unlocked ability: %s", ability_id))
    end
end

local function register_with_checkpoint()
    local ok, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok or not Checkpoint or not Checkpoint.register_provider then
        return
    end
    -- A restore that carries no `abilities` payload (a save written before a
    -- pickup, a legacy slot, a defaults restore) wipes every runtime unlock.
    -- ProgressionManager still holds the authoritative list in that case, so
    -- re-seed from it instead of leaving the two stores disagreeing -- a
    -- divergence the player experiences as an ability they collected no longer
    -- working. Required lazily: progression_manager requires this module at
    -- load, so a top-level require here would be a cycle.
    local function reset_and_reseed_from_progression()
        M.reset()
        local ok_prog, Progression = pcall(require, "mvtk.game.progression.progression_manager")
        if ok_prog and Progression and Progression.resync_ability_manager then
            pcall(Progression.resync_ability_manager)
        end
    end

    Checkpoint.register_provider("abilities", {
        capture = function()
            return M.get_save_data()
        end,
        apply = function(payload)
            if type(payload) == "table" then
                M.load_save_data(payload)
            else
                reset_and_reseed_from_progression()
            end
        end,
        defaults = reset_and_reseed_from_progression,
        version = 1,
        order = 50,
        mirror_key = "abilities",
        description = "Ability unlocks & stamina",
    })
end

register_with_checkpoint()
return M
