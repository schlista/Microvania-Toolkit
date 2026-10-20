-- mvtk/collectibles/hidden_pickup_notice.lua
-- Explains why an ability pickup is missing. A pickup removes itself when the
-- current save already owns its ability; without this notice a tester only
-- sees an empty spot. The message is always logged; the on-screen toast only
-- appears in debug (development) builds, once per ability per session.
local M = {}

-- Intentionally module-wide: "once per session" spans every pickup instance.
local announced = {}

local SOURCE_TEXT = {
    start = "your starting abilities (Project > Game Settings... > Abilities)",
    pickup = "an earlier pickup",
    level = "a level-up",
    reward = "a reward",
    legacy = "an older save",
}

function M.is_dev_build()
    if type(sys) ~= "table" or type(sys.get_engine_info) ~= "function" then return false end
    local ok, info = pcall(sys.get_engine_info)
    return ok and type(info) == "table" and info.is_debug == true
end

local function ability_label(ability_id)
    local ok, AbilityManager = pcall(require, "mvtk.abilities.ability_manager")
    if ok and AbilityManager and AbilityManager.get_ability_info then
        local ok_info, info = pcall(AbilityManager.get_ability_info, ability_id)
        if ok_info and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    return (tostring(ability_id):gsub("_", " "):gsub("^%l", string.upper))
end

local function ability_source(ability_id)
    local ok, Progression = pcall(require, "mvtk.game.progression.progression_manager")
    if ok and Progression and Progression.get_ability_source then
        local ok_source, source = pcall(Progression.get_ability_source, ability_id)
        if ok_source then return source end
    end
    return nil
end

--- Build the notice text (pure; unit-tested).
function M.message(label, source)
    local from = SOURCE_TEXT[source or ""] or "this save"
    return string.format(
        "%s pickup hidden: this save already has it (from %s).\nStart a New Game on an empty slot to test the pickup.",
        tostring(label), from)
end

--- Announce once per ability per session. Returns true when a notice was issued.
function M.announce(ability_id)
    if not ability_id or ability_id == "" or announced[ability_id] then return false end
    announced[ability_id] = true
    local text = M.message(ability_label(ability_id), ability_source(ability_id))
    print("[COLLECTIBLE] " .. text:gsub("\n", " "))
    if M.is_dev_build() then
        local ok, PU = pcall(require, "mvtk.prefabs.prefab_utils")
        if ok and PU and PU.toast then PU.toast(text, 6.0) end
    end
    return true
end

function M.reset()
    announced = {}
end

return M
