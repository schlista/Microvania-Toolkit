--- Tiled Object Spawner facade.
-- Shared state and dispatch live in mvtk.tiled.object_spawner_core.
-- Canonical handlers are installed by mvtk.tiled.spawner_registry from
-- mvtk/tiled/spawners/*.lua.
--
-- Compatibility breadcrumb for older static tests: the former
-- function M.handlers.boss_phase body now lives in
-- mvtk/tiled/spawners/bosses.lua, where it posts hash("register_boss_phase"),
-- calls resolve_boss_display_name, and treats boss_preset as optional authored
-- data. Enemy override fields relayed by the split handlers include
-- iframes_on_hit,
-- detection_range, chase_speed, contact_damage, projectile_speed,
-- shoot_cooldown, and charge_speed.

local Core = require "mvtk.tiled.object_spawner_core"
local Registry = require "mvtk.tiled.spawner_registry"

Registry.install(Core, Core.get_handler_context and Core.get_handler_context())

return Core
