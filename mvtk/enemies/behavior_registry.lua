-- mvtk/enemies/behavior_registry.lua
-- Static registry for built-in enemy behaviors.
-- Ensures Defold bundles behavior modules referenced via dynamic require.

local M = {}

local registry = {
    charger = require "mvtk.enemies.behaviors.charger",
    composed_behavior = require "mvtk.enemies.behaviors.composed_behavior",
    flying_chase = require "mvtk.enemies.behaviors.flying_chase",
    formation = require "mvtk.enemies.behaviors.formation",
    ground_patrol = require "mvtk.enemies.behaviors.ground_patrol",
    jumper = require "mvtk.enemies.behaviors.jumper",
    swarm = require "mvtk.enemies.behaviors.swarm",
}

function M.get(name)
    if not name then
        return nil
    end
    return registry[name]
end

function M.register(name, behavior)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if type(behavior) ~= "table" then
        return false
    end
    registry[name] = behavior
    return true
end

function M.list()
    local out = {}
    for key in pairs(registry) do
        table.insert(out, key)
    end
    table.sort(out)
    return out
end

return M
