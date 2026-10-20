-- mvtk/tiled/object_props.lua
--
-- Single source of truth for Tiled object property *aliases*.
--
-- Across the toolkit, many Tiled properties have historically been accepted
-- under several names (e.g. `damage_cooldown` / `damage_interval`). Those
-- aliases used to live as scattered inline `a or b` chains in the spawners and
-- the editor generators, with no documentation of the "real" name.
--
-- This module centralizes the alias *groups* (interchangeable names for one
-- concept) and a resolver that preserves each call site's precedence: it tries
-- the requested name first, then the rest of that name's group. So a site that
-- previously did `props.radius or props.light_radius` calls
-- `OP.get(props, "radius", default)` and a site that did the reverse calls
-- `OP.get(props, "light_radius", default)` -- both behave exactly as before,
-- but the alias set now lives in one runtime source of truth. Creator-facing
-- properties are generated from the live .tx files into tiled/templates/README.html.
--
-- To add an alias: add the name to its group below (or add a new group). The
-- generated property reference picks it up automatically.

local M = {}

-- Each inner list is a set of interchangeable property names for one concept.
-- The first entry is treated as the *recommended canonical* name in docs.
-- NOTE: a property name must appear in at most one group (enforced below).
-- `label` is intentionally NOT grouped: it is used both as a prompt alias and an
-- npc-name alias in different object types, so it stays an explicit inline read.
M.groups = {
    { "damage_interval", "damage_cooldown" },
    { "wait", "wait_time" },
    { "loop_mode", "mode" },
    { "motor_speed", "speed" },
    { "knockback_force", "knockback" },
    { "radius", "light_radius" },
    { "intensity", "level", "light_intensity" },
    { "boss_type", "boss_preset" },
    { "boss_id", "boss_tag" },
    { "recharge_time", "cooldown" },
    { "cost_currency", "cost" },
    { "required_resistance", "immunity_ability" },
    { "restore_amount", "energy_amount" },
    { "restore_percent", "energy_percent" },
    { "music", "Music", "ambience", "Ambience" },
    { "biome", "Biome" },
    { "require_ability", "requires_ability" },
    { "requires_key", "key_required", "required_key" },
    { "swap_width", "swap_tile_width" },
    { "swap_height", "swap_tile_height" },
    { "max_simultaneous", "max_active" },
    { "battle_music", "combat_music" },
    { "gain", "volume" },
    { "ambience_id", "sound_id" },
    { "spawn_id", "registration_id" },
    { "contents", "loot_table", "loot", "loot_table_id" },
}

-- Build name -> group lookup once, refusing duplicate names across groups
-- (which would make resolution depend on table order).
local NAME_TO_GROUP = {}
for _, group in ipairs(M.groups) do
    for _, name in ipairs(group) do
        assert(NAME_TO_GROUP[name] == nil,
            "object_props: alias '" .. tostring(name) .. "' appears in more than one group")
        NAME_TO_GROUP[name] = group
    end
end

-- Resolve a property from a flat props table (runtime spawner shape).
-- Tries `name` first, then the rest of its alias group, then `default`.
function M.get(props, name, default)
    if type(props) ~= "table" then
        return default
    end
    if props[name] ~= nil then
        return props[name]
    end
    local group = NAME_TO_GROUP[name]
    if group then
        for _, alt in ipairs(group) do
            if props[alt] ~= nil then
                return props[alt]
            end
        end
    end
    return default
end

-- Resolve using an arbitrary value-getter `getter(obj, field)` -- for the editor
-- generators, which read Tiled objects of several shapes via get_prop_value.
function M.get_via(getter, obj, name, default)
    local v = getter(obj, name)
    if v ~= nil then
        return v
    end
    local group = NAME_TO_GROUP[name]
    if group then
        for _, alt in ipairs(group) do
            v = getter(obj, alt)
            if v ~= nil then
                return v
            end
        end
    end
    return default
end

-- Return the alias group containing `name` (or nil). Useful for docs/tools.
function M.group_for(name)
    return NAME_TO_GROUP[name]
end

return M
