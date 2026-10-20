-- developer/config/enemy_settings.lua
-- Room limits for regular enemies registered with EnemyManager.
-- Boss summons and helper-spawned enemies use this default cap unless their
-- spawn configuration supplies max_enemies_per_room for that instance.
--
-- Enemies placed in Tiled are baked into editable room gameobjects. Their
-- script registers them with a zero limit so every authored enemy remains
-- present; this setting does not remove enemies from the room collection.

return {
    -- Maximum registered enemies in a room for spawns using the default cap.
    -- Zero disables the cap; a per-spawn value overrides this default.
    -- Lower positive values reduce the number of simultaneous boss summons.
    max_enemies_per_room = 25,
}
