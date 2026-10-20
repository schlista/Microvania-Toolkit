-- mvtk/abilities/ability_provenance.lua
-- Records where each ability unlock came from, so start unlocks can follow the
-- current Project > Game Settings... settings while earned unlocks stay permanent.
--
-- Sources:
--   start  - granted at game start by the merged ability defaults
--            (developer/config/ability_defaults.lua + Project > Game Settings... overrides).
--            Re-evaluated on every load: unticking an ability in Game Settings
--            removes it from saves where it was only a start unlock, so its
--            pickup appears again.
--   pickup - collected from an ability pickup. Never revoked.
--   reward - any other grant (boss, dialogue, debug). Never revoked.
--   legacy - present in a save written before sources were recorded. Never
--            revoked: we cannot prove it was only a start unlock.
--
-- Pure Lua (no Defold globals) so it can be unit-tested headlessly.
local M = {}

M.VERSION = 1
M.START = "start"
M.PICKUP = "pickup"
M.REWARD = "reward"
M.LEGACY = "legacy"

--- Current merged start-unlock table: { [ability_id] = true|false }.
-- Read at call time (not module load) to use the current project snapshot.
-- After saving Game Settings, Prepare & Check and Build before playing.
function M.start_defaults()
    local ok, RuntimeSettings = pcall(require, "developer.config.runtime_settings")
    if ok and type(RuntimeSettings) == "table" and RuntimeSettings.get_ability_defaults then
        local ok_defaults, defaults = pcall(RuntimeSettings.get_ability_defaults)
        if ok_defaults and type(defaults) == "table" and type(defaults.abilities) == "table" then
            return defaults.abilities
        end
    end
    local ok_raw, raw = pcall(require, "developer.config.ability_defaults")
    if ok_raw and type(raw) == "table" and type(raw.abilities) == "table" then
        return raw.abilities
    end
    return {}
end

local function add_missing_start_unlocks(data, start_defaults)
    for ability_id, on in pairs(start_defaults or {}) do
        if on == true and not data.unlocked_abilities[ability_id] then
            data.unlocked_abilities[ability_id] = true
            data.ability_sources[ability_id] = M.START
        end
    end
end

--- Reconcile a progression table with the current start defaults.
-- Mutates data.unlocked_abilities / data.ability_sources /
-- data.ability_sources_version and returns the set of revoked ids.
-- @param data            progression save table (already normalized)
-- @param start_defaults  { [ability_id] = bool } from M.start_defaults()
-- @param is_new_game     true when there is no save to load
function M.reconcile(data, start_defaults, is_new_game)
    data.unlocked_abilities = type(data.unlocked_abilities) == "table" and data.unlocked_abilities or {}
    data.ability_sources = type(data.ability_sources) == "table" and data.ability_sources or {}
    start_defaults = start_defaults or {}
    local revoked = {}

    if is_new_game then
        add_missing_start_unlocks(data, start_defaults)
    elseif (tonumber(data.ability_sources_version) or 0) < M.VERSION then
        -- Legacy save: keep everything the player owns; only record it.
        for ability_id, on in pairs(data.unlocked_abilities) do
            if on and data.ability_sources[ability_id] == nil then
                data.ability_sources[ability_id] = M.LEGACY
            end
        end
        add_missing_start_unlocks(data, start_defaults)
    else
        for ability_id, source in pairs(data.ability_sources) do
            if source == M.START and start_defaults[ability_id] ~= true then
                revoked[ability_id] = true
            end
        end
        for ability_id in pairs(revoked) do
            data.unlocked_abilities[ability_id] = nil
            data.ability_sources[ability_id] = nil
        end
        add_missing_start_unlocks(data, start_defaults)
    end

    data.ability_sources_version = M.VERSION
    return revoked
end

--- Record a grant. Earned sources replace "start"; "start" never replaces
-- an earned source.
function M.record(data, ability_id, source)
    if not ability_id then return end
    data.ability_sources = type(data.ability_sources) == "table" and data.ability_sources or {}
    source = source or M.REWARD
    local current = data.ability_sources[ability_id]
    if source == M.START then
        if current == nil then data.ability_sources[ability_id] = M.START end
    else
        data.ability_sources[ability_id] = source
    end
end

return M
