-- mvtk/tiled/retired_types.lua
-- Identifiers recognized only to explain old maps; these types have no runtime
-- handler or baker. Keep genuine unknown types on the existing error path.
local M = {}

M.MESSAGE = "retired object type, not part of Microvania v1"

-- Compatibility identifiers, not supported authoring types.
local OBJECT_TYPES = {
    death_drop = true,
    bloodstain = true,
    bank = true,
    offering_altar = true,
    shop = true,
    shop_npc = true,
    skill_trainer = true,
    upgrade_station = true,
    quest_trigger = true,
    zip_line = true,
    wind_current = true,
    ice_floor = true,
    pendulum_hazard = true,
    warp_statue = true,
    enemy_nest = true,
    spawn_wave = true,
    enemy_spawner = true,
    turret_rotating = true,
    arena_hazard_spawner = true,
    background_interactable = true,
    ambient_sound = true,
}

-- Saved and authored identifiers retained solely for compatibility diagnostics.
local ABILITY_IDS = { high_jump = true, phase = true }

local function normalize(value)
    local id = tostring(value or ""):match("^%s*(.-)%s*$"):lower()
    return id:gsub("[%s%-]+", "_"):gsub("_+", "_")
end

function M.is_object_type(value)
    return OBJECT_TYPES[normalize(value)] == true
end

function M.is_ability(value)
    return ABILITY_IDS[normalize(value)] == true
end

function M.required_ability_warning(object, room_id, value)
    if not M.is_ability(value) then return nil end
    return string.format("%s: object id=%s required_ability='%s': %s",
        tostring(room_id or "<room>"), tostring(object and object.id),
        tostring(value), M.MESSAGE)
end

function M.object_type_ids()
    local ids = {}
    for id in pairs(OBJECT_TYPES) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function M.warning(object, room_id)
    local object_type
    for _, field in ipairs({ "type", "class", "className" }) do
        if object and normalize(object[field]) ~= "" then
            object_type = object[field]
            break
        end
    end
    return string.format("%s: object id=%s type='%s': %s",
        tostring(room_id or "<room>"), tostring(object and object.id),
        tostring(object_type), M.MESSAGE)
end

return M
