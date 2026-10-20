-- developer/config/boss_visuals.lua
-- ============================================================================
-- Boss Visual Component Registry
-- ============================================================================
-- Lists every visual component id that exists on the shared boss runtime
-- prefab (developer/game/prefabs/boss_runtime.go). The boss runtime script
-- enables the ONE component a given boss uses (named in boss_types.lua via
-- `boss_visual_type` + `visual_component`) and disables the rest — so they
-- don't all render on top of each other.
--
-- HOW TO ADD A NEW BOSS WITH ITS OWN ATLAS:
--   1. Add a new sprite (or spine) component to boss_runtime.go pointing at
--      your atlas / spine scene. Give it a unique id, e.g. "sprite_my_boss".
--   2. Add that id to the `visual_components` list below.
--      Sprite components with their own atlas should also be added to
--      `sprite_atlases` so missing-animation checks inspect the right atlas.
--   3. In developer/config/boss_types.lua, set:
--        boss_visual_type = "sprite"
--        visual_component = "sprite_my_boss"
--      or:
--        boss_visual_type = "spine"
--        visual_component = "spine_my_boss"
-- ============================================================================

return {
    -- ------------------------------------------------------------------------
    -- Every sprite / spine component id present on boss_runtime.go.
    -- The runtime enables the one the active boss uses and disables the rest.
    -- Order doesn't matter; duplicates are harmless.
    -- ------------------------------------------------------------------------
    visual_components = {
        "sprite",
        "sprite_test",
        "sprite_gate_warden",
        "sprite_sky_tyrant",
        "sprite_arena_sentinel",
        "sprite_cactus_boss",
    },

    -- Atlas used by sprite components that do not use the shared boss atlas.
    -- The animation controller uses this to avoid asking the engine to play
    -- clips that are not present on the selected boss sprite.
    -- Every sprite component needs its atlas here: an unlisted component was
    -- checked against the wrong atlas and logged "Unable to play animation".
    sprite_atlases = {
        sprite = "/developer/assets/atlas/boss.atlas",
        sprite_test = "/developer/assets/atlas/test_boss_placeholder.atlas",
        sprite_gate_warden = "/developer/assets/atlas/gate_warden_placeholder.atlas",
        sprite_sky_tyrant = "/developer/assets/atlas/sky_tyrant_placeholder.atlas",
        sprite_arena_sentinel = "/developer/assets/atlas/arena_sentinel_placeholder.atlas",
        sprite_cactus_boss = "/developer/assets/atlas/cactus_boss.atlas",
    },
}
