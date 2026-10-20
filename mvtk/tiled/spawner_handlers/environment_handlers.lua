-- mvtk/tiled/spawner_handlers/environment_handlers.lua
-- ============================================================================
-- Object Spawner: Environment Handler Category
-- ============================================================================
-- This module demonstrates the external handler pattern for object_spawner.
-- Handlers defined here are automatically loaded by object_spawner.load_handler_modules().
--
-- To create a new handler category:
--   1. Create a new file in this directory (e.g., platform_handlers.lua)
--   2. Return a function(H) that returns a table of { type_name = handler_fn }
--   3. Register the module path in object_spawner.load_handler_modules()
--
-- The helpers table (H) provides shared utilities from object_spawner:
--   H.get_props(object)           - Extract properties from Tiled object
--   H.make_id(props, key, ...)    - Generate unique ID
--   H.world_point(object, room)   - Get position for point objects
--   H.world_rect(object, room, w, h) - Get position for rect objects
--   H.spawn_factory(name, pos, props, scale, label) - Spawn via factory
--   H.apply_scale(instance, w, h, ...) - Scale spawned object
--   H.send_tiled_props(instance, props) - Forward Tiled props to instance
--   H.log_spawn(type, id, x, y)  - Log spawn event
--   H.log_register(type, id, x, y) - Log registration event
--   H.to_bool(value, default)     - Parse boolean property
--   H.Util                        - mvtk.core.util module
--
-- NOTE: Handlers here are only loaded if they are NOT already defined
-- in object_spawner.lua (built-in handlers take priority). This module
-- currently serves as a template. To migrate handlers here, remove them
-- from object_spawner.lua first.
-- ============================================================================

return function(H)
  local handlers = {}

  -- Example: environment handlers would look like this once migrated:
  --
  -- function handlers.music_trigger(object, room_id)
  --   local props = H.get_props(object)
  --   local trigger_id = H.make_id(props, "trigger_id", "music", object, room_id)
  --   local pos = H.world_rect(object, room_id, 128, 128)
  --   local instance = H.spawn_factory("music_trigger_factory", pos, {
  --     trigger_id = hash(trigger_id),
  --     music_id = hash(props.music_id or ""),
  --     ...
  --   }, 1, "music trigger")
  --   if not instance then return nil end
  --   H.send_tiled_props(instance, props)
  --   H.apply_scale(instance, object.width or 128, object.height or 128, 64, 64, 128, 128)
  --   H.log_spawn("music trigger", trigger_id, pos.x, pos.y)
  --   return instance
  -- end

  return handlers
end
