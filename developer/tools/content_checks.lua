-- developer/tools/content_checks.lua
-- Validate All content checks for authoring mistakes that used to fail
-- silently in play (see docs/archive/PT4_TOUR_PLAYTEST_FIX_PLAN.md section 6):
--
--   ability_pickup_starts_unlocked   warning  pickup deletes itself on a new game
--   boss_without_arena               info     boss starts when the player enters its room
--                                             (the whole room is the fight area)
--   gate_energy_unaffordable         warning  energy cost above the player's max energy
--   chest_inline_contents_unregistered error  chest contents not in the generated lookup
--
-- Pure Lua: takes the content index built by developer/tools/content_relationships
-- plus already-loaded config tables, so it runs in the editor, headless and in tests.
local M = {}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function merged(base, override)
    local out = {}
    for k, v in pairs(base or {}) do out[k] = v end
    for k, v in pairs(override or {}) do out[k] = v end
    return out
end

--- Effective start-of-game settings: baseline files plus published Setup
-- Wizard overrides (developer/config/creator_settings.lua).
-- inputs: { ability_defaults = <ability_defaults.lua table>,
--           player_settings = <player_settings.lua table>,
--           creator = <creator_settings.lua table or nil> }
function M.effective_settings(inputs)
    inputs = inputs or {}
    local overrides = (type(inputs.creator) == "table" and inputs.creator.published == true
        and type(inputs.creator.overrides) == "table") and inputs.creator.overrides or {}
    local abilities = merged((inputs.ability_defaults or {}).abilities, overrides.abilities)
    local player = merged(inputs.player_settings, overrides.player)
    return { abilities = abilities, max_energy = tonumber(player.max_energy) }
end

--- Run every check.
-- index: content index ({ objects = { {type, room, file, layer, object_id, name, visible, properties} } })
-- cfg: { abilities = {id = bool}, max_energy = number, gate_types = table,
--        chest_inline = list of strings or nil (file missing) }
function M.validate(index, cfg)
    cfg = cfg or {}
    local ds = {}
    local function issue(severity, code, o, property, message, fix)
        ds[#ds + 1] = { severity = severity, code = code, message = message, fix = fix,
            file = o and o.file, room = o and o.room, layer = o and o.layer,
            object_id = o and o.object_id, property = property }
    end

    local objects = (index and index.objects) or {}
    local arenas_by_room = {}
    for _, o in ipairs(objects) do
        if o.visible ~= false and o.type == "boss_arena" and o.room then arenas_by_room[o.room] = true end
    end

    local registered
    if type(cfg.chest_inline) == "table" then
        registered = {}
        for _, value in ipairs(cfg.chest_inline) do registered[trim(value)] = true end
    end

    for _, o in ipairs(objects) do
        local p = o.properties or {}
        if o.visible ~= false then
            if o.type == "ability" then
                local id = trim(p.ability_id)
                if id ~= "" and cfg.abilities and cfg.abilities[id] == true then
                    issue("warning", "ability_pickup_starts_unlocked", o, "ability_id",
                        string.format("'%s' starts unlocked, so this pickup removes itself on a new game.", id),
                        "Untick it under Project > Game Settings... > Abilities, Save, Build, then start a New Game; or remove the pickup.")
                end
            elseif o.type == "boss" then
                if trim(p.arena_id) == "" and not arenas_by_room[o.room] then
                    issue("info", "boss_without_arena", o, "arena_id",
                        "Boss has no boss_arena, so the fight starts when the player enters this room and the whole room is the fight area.",
                        "Place a boss_arena in this room and set arena_id to start the fight on entering a smaller area.")
                end
            elseif o.type == "gate" then
                local preset = type(cfg.gate_types) == "table" and cfg.gate_types[trim(p.gate_type)] or nil
                if type(preset) == "table" and preset.required_resource == "energy" then
                    local authored = tonumber(p.required_energy)
                    local cost = (authored and authored >= 0) and authored or tonumber(preset.resource_amount) or 0
                    local max_energy = tonumber(cfg.max_energy)
                    if max_energy and cost > max_energy then
                        issue("warning", "gate_energy_unaffordable", o, "required_energy",
                            string.format("Gate costs %s energy but the player holds at most %s, so it can never open.",
                                tostring(cost), tostring(max_energy)),
                            "Lower requirements.required_energy on the gate, or raise max_energy in Project > Game Settings... > Player.")
                    end
                end
            elseif o.type == "chest" and registered then
                local contents = trim(p.contents)
                if contents:find(":", 1, true) and not registered[contents] then
                    issue("error", "chest_inline_contents_unregistered", o, "contents",
                        string.format("Chest contents '%s' are missing from developer/config/chest_inline_contents.lua, so release builds drop no loot.", contents),
                        "Run Project > Prepare & Check to regenerate the chest contents list.")
                end
            end
        end
    end
    return ds
end

return M
