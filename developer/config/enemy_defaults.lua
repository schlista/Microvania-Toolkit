-- developer/config/enemy_defaults.lua
-- Centralized defaults for regular (non-boss) enemy behaviour.
--
-- Used as fallbacks whenever a specific enemy in developer/config/enemy_types.lua
-- (or a per-instance Tiled override) does not specify a value. Bosses have their
-- own defaults in boss_defaults.lua.
--
-- Distances are in pixels, except keys ending in _tiles: those count tiles of
-- the project's tile size (developer/config/tile_settings.lua, written by
-- Import Assets), so they keep working when the tile size changes.
-- All times are in seconds.

return {
    -- Default aggro/chase speed when an enemy does not define its own.
    chase_speed = 80,

    -- Ground-moving enemies stop at drops instead of walking onto air.
    -- Patrollers turn back at the edge. Enemy types can override this switch.
    stop_at_ledges = true,

    -- Distance between the enemy's centre and the edge where it stops, in
    -- tiles (of tile width). 0.25 is a quarter tile: 16 pixels on 64-pixel
    -- tiles, 4 pixels on 16-pixel tiles. Raise it if your enemies are wide
    -- for your tiles and hang over edges. An enemy type can set its own
    -- distance in pixels with ledge_margin in enemy_types.lua, for one
    -- unusually wide or narrow enemy.
    ledge_margin_tiles = 0.25,

    -- How far below the enemy's centre to look for the ground it stands on,
    -- in tiles (of tile height). It must reach past the enemy's feet: 4 tiles
    -- covers enemies up to about 8 tiles tall. If it is too short for an
    -- enemy, the check turns itself off for that enemy and it can walk onto
    -- air again.
    ledge_probe_depth_tiles = 4,

    -- Largest step down that still counts as the same floor, in tiles (of
    -- tile height). 0.125 is an eighth of a tile: 8 pixels on 64-pixel tiles.
    -- Ground movers never move down to follow the floor, so an accepted step
    -- leaves them this far above the lower floor; larger drops stop them.
    ledge_step_tolerance_tiles = 0.125,

    -- How long an enemy is invulnerable after taking a hit.
    -- Keeps fast multi-hit weapons from deleting enemies in one swing.
    iframes_on_hit = 0.15,

    -- How often the invulnerability flash toggles the sprite tint.
    iframe_flash_period = 0.06,

    -- Default telegraph time for enemy attacks that don't specify one.
    telegraph_time = 0.3,

    -- Default active duration for enemy attacks that don't specify one.
    attack_duration = 0.6,

    -- Seconds before the enemy's corpse / game object is removed after death.
    cleanup_delay = 0.8,
}
