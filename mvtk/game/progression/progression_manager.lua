-- mvtk/developer/game/progression/progression_manager.lua
-- Progression manager tracking unlocks and milestones

local Util = require "mvtk.core.util"
local Debug = Util.require_config('developer.config.debug_config')
-- Start unlocks come from the merged Project > Game Settings... + ability_defaults.lua
-- settings (never the raw baseline file) and are re-evaluated on load.
local Provenance = require "mvtk.abilities.ability_provenance"
local AbilityManager = Util.require_module("mvtk.abilities.ability_manager")
local M = {}

-- Start-only unlocks removed by the last init() because the current settings
-- no longer start-unlock them. Pushed to AbilityManager so its own saved
-- payload cannot re-grant them.
local revoked_start_unlocks = {}

local prog_log = Util.make_debug_log("[PROGRESSION]", function()
    return (Debug.global and Debug.global.enable) or (Debug.gameplay and Debug.gameplay.progression)
end)

local function new_progression_data()
    return {
        unlocked_abilities = {},
        completed_areas = {},
        boss_defeats = {},
        collectibles_found = {},
    }
end

local progression_data = new_progression_data()

local normalize_ability_id = Util.normalize_ability_id

local function retain_defined_abilities(data)
    if not (AbilityManager and AbilityManager.get_ability_info) then return end
    for ability_id in pairs(data.unlocked_abilities) do
        if not AbilityManager.get_ability_info(ability_id) then
            data.unlocked_abilities[ability_id] = nil
            data.ability_sources[ability_id] = nil
        end
    end
end

local function normalize_progression_data(save_data)
    local normalized = new_progression_data()
    if type(save_data) == "table" then
        for key in pairs(normalized) do
            if type(save_data[key]) == "table" then normalized[key] = Util.deep_copy(save_data[key]) end
        end
        normalized.ability_sources = type(save_data.ability_sources) == "table"
            and Util.deep_copy(save_data.ability_sources) or {}
        normalized.ability_sources_version = save_data.ability_sources_version
    end

    normalized.unlocked_abilities = type(normalized.unlocked_abilities) == "table"
        and normalized.unlocked_abilities or {}
    normalized.completed_areas = type(normalized.completed_areas) == "table"
        and normalized.completed_areas or {}
    normalized.boss_defeats = type(normalized.boss_defeats) == "table"
        and normalized.boss_defeats or {}
    normalized.collectibles_found = type(normalized.collectibles_found) == "table"
        and normalized.collectibles_found or {}

    -- Saved IDs without a current definition are ignored during restoration.
    retain_defined_abilities(normalized)
    return normalized
end

local function get_ability_info(ability_id)
    if not (AbilityManager and AbilityManager.get_ability_info) then
        return nil
    end
    local ok, info = pcall(AbilityManager.get_ability_info, ability_id)
    if ok then
        return info
    end
    return nil
end

local function sync_progression_from_ability_manager()
    if not (AbilityManager and AbilityManager.get_unlocked_abilities) then
        return
    end
    local ok, unlocked = pcall(AbilityManager.get_unlocked_abilities)
    if not ok or type(unlocked) ~= "table" then
        return
    end
    local start_defaults = Provenance.start_defaults()
    for _, info in ipairs(unlocked) do
        local id = nil
        if type(info) == "table" and info.id then
            id = tostring(info.id)
        elseif type(info) == "string" then
            id = info
        end
        -- A revoked start unlock can still be present in AbilityManager's own
        -- saved payload; it must not flow back into progression.
        if id and not revoked_start_unlocks[id] then
            if not progression_data.unlocked_abilities[id] then
                Provenance.record(progression_data, id,
                    start_defaults[id] == true and Provenance.START or Provenance.REWARD)
            end
            progression_data.unlocked_abilities[id] = true
        end
    end
end

--- Push progression's unlock list back into AbilityManager.
-- The reverse of sync_progression_from_ability_manager. AbilityManager's
-- checkpoint provider calls AbilityManager.reset() whenever a restore carries
-- no `abilities` payload (a save written before a pickup, a legacy slot, a
-- defaults restore), which drops every runtime unlock while this module still
-- holds them. Without this push the two disagree for the rest of the session
-- and ability gates read as locked.
function M.resync_ability_manager()
    if not (AbilityManager and AbilityManager.unlock_ability) then
        return 0
    end
    local restored = 0
    for ability_id, unlocked in pairs(progression_data.unlocked_abilities or {}) do
        if unlocked then
            local already = false
            if AbilityManager.is_ability_unlocked then
                local ok, state = pcall(AbilityManager.is_ability_unlocked, ability_id)
                already = ok and state and true or false
            end
            if not already then
                local ok = pcall(AbilityManager.unlock_ability, ability_id, { enabled = true })
                if ok then
                    restored = restored + 1
                    prog_log(string.format("[PROGRESSION] Restored ability into AbilityManager: %s", tostring(ability_id)))
                end
            end
        end
    end
    return restored
end

local function apply_checkpoint_ability_payload()
    local ok_cp, Checkpoint = pcall(require, "mvtk.core.checkpoint")
    if not ok_cp or not Checkpoint or not Checkpoint.data then
        return
    end
    local modules = Checkpoint.data.modules
    local entry = modules and modules.abilities
    local payload = entry and entry.data or nil
    if type(payload) == "table" and AbilityManager and AbilityManager.load_save_data then
        pcall(AbilityManager.load_save_data, payload)
    end
end

function M.init(save_data)
    prog_log("[PROGRESSION] Initializing progression system...")

    progression_data = normalize_progression_data(save_data)

    -- New game: seed start unlocks from the merged settings. Loaded save:
    -- drop start-only unlocks the current settings no longer grant, so their
    -- pickups reappear. Legacy saves are only tagged, never revoked.
    revoked_start_unlocks = Provenance.reconcile(progression_data, Provenance.start_defaults(), not save_data)
    -- Old Wizard overrides can still mention IDs whose definitions were removed.
    retain_defined_abilities(progression_data)
    for ability_id in pairs(revoked_start_unlocks) do
        print(string.format(
            "[PROGRESSION] %s was only a start unlock and the current Project > Game Settings... settings no longer grant it; its pickup can appear again.",
            tostring(ability_id)))
    end
    if AbilityManager and AbilityManager.set_revoked_start_unlocks then
        pcall(AbilityManager.set_revoked_start_unlocks, revoked_start_unlocks)
    end

    if AbilityManager and AbilityManager.init then
        pcall(AbilityManager.init, {
            unlocked = progression_data.unlocked_abilities,
        })
    end
    -- Ensure save-loaded ability provider data wins over defaults/init ordering.
    apply_checkpoint_ability_payload()
    sync_progression_from_ability_manager()

    -- ...and push the merged list back, so a reset AbilityManager regains any
    -- unlock that only survived here.
    M.resync_ability_manager()

end

function M.reset()
    M.init(nil)
    return M.get_save_data()
end

--- Unlock an ability. opts.source records provenance ("pickup",
-- "reward"; default "reward"). Earned unlocks are never revoked on load.
function M.unlock_ability(ability, opts)
    if not ability then return end
    local id = normalize_ability_id(ability) or tostring(ability)
    if AbilityManager and AbilityManager.get_ability_info and not get_ability_info(id) then return false end
    progression_data.unlocked_abilities[id] = true
    Provenance.record(progression_data, id, type(opts) == "table" and opts.source or nil)
    revoked_start_unlocks[id] = nil

    local enabled_opt = nil
    if type(opts) == "table" and opts.enabled ~= nil then
        enabled_opt = opts.enabled and true or false
    end

    if AbilityManager and AbilityManager.unlock_ability then
        if enabled_opt ~= nil then
            AbilityManager.unlock_ability(id, { enabled = enabled_opt })
        else
            AbilityManager.unlock_ability(id)
        end
    end

    local info = get_ability_info(id)
    local label = (info and info.name) or id:gsub('_', ' ')
    local enabled_state = (info and info.enabled) or enabled_opt

    prog_log(string.format("[PROGRESSION] Unlocked ability: %s (enabled=%s)", label, tostring(enabled_state)))

    pcall(msg.post, msg.url("main:/mode_hud#mode_hud"), hash("ability_unlocked"), {
        ability = id,
        label = label
    })
end

function M.is_ability_unlocked(ability)
    local id = normalize_ability_id(ability) or ability
    return progression_data.unlocked_abilities[id] == true
end

--- Where an unlock came from ("start", "pickup", "reward",
-- "legacy"), or nil when the ability is not unlocked.
function M.get_ability_source(ability)
    local id = normalize_ability_id(ability) or ability
    if progression_data.unlocked_abilities[id] ~= true then return nil end
    local sources = progression_data.ability_sources
    return type(sources) == "table" and sources[id] or Provenance.LEGACY
end

--- Start-only unlocks revoked by the last init(); { [ability_id] = true }.
function M.get_revoked_start_unlocks()
    local out = {}
    for id in pairs(revoked_start_unlocks) do out[id] = true end
    return out
end

function M.complete_area(area_id)
    if not progression_data.completed_areas[area_id] then
        progression_data.completed_areas[area_id] = true
        prog_log(string.format("[PROGRESSION] Area completed: %s", area_id))

    end
end


function M.defeat_boss(boss_id)
    if not progression_data.boss_defeats[boss_id] then
        progression_data.boss_defeats[boss_id] = true
        prog_log(string.format("[PROGRESSION] Boss defeated: %s", boss_id))

    end
end


function M.find_collectible(collectible_id)
    if not progression_data.collectibles_found[collectible_id] then
        progression_data.collectibles_found[collectible_id] = true
        prog_log(string.format("[PROGRESSION] Collectible found: %s", collectible_id))

    end
end


function M.get_save_data()
    return progression_data
end

local function restore_legacy_progression_or_defaults()
    -- Saves written before progression became a checkpoint provider kept the
    -- payload at the top level. Preserve that shape long enough to migrate it
    -- into modules.progression on the next save.
    local Checkpoint = Util.require_module("mvtk.core.checkpoint")
    local legacy = Checkpoint and Checkpoint.data and Checkpoint.data.progression
    if type(legacy) == "table" and next(legacy) ~= nil then
        M.init(legacy)
    else
        M.reset()
    end
end

Util.register_checkpoint_provider("progression", {
    capture = function()
        return M.get_save_data()
    end,
    apply = function(data)
        M.init(data)
    end,
    defaults = restore_legacy_progression_or_defaults,
    version = 1,
    order = 45,
    mirror_key = "progression",
    description = "Ability unlocks and progression milestones",
})

return M
