-- developer/config/player_spine_map.lua
-- ============================================================================
-- Player Spine Animation Name Map
-- ============================================================================
-- Maps the logical animation keys used by the PLAYER runtime (idle, run,
-- jump, dash, attack, …) to the actual animation names baked into the
-- player's Spine skeleton.
--
-- WHY THIS IS PLAYER-ONLY:
--   Bosses have their own per-boss mapping in
--   developer/config/boss_animations.lua. A shared global map used to live
--   inside mvtk/animation/animation_controller.script, but it was written
--   for the player rig and silently remapped boss animations (e.g. a boss
--   that legitimately had a "dash" animation got rewritten to "air_dash").
--   Keeping this table here, loaded only for the player flow, keeps player
--   and boss animation name spaces independent.
--
-- When the animation controller is running for the player
-- (auto_resolve_player_type = 1) and a logical key has an entry below, the
-- controller plays the mapped name instead. Keys without an entry play
-- through unchanged.
--
-- Safe to edit. Add entries to match the exact names in your Spine skeleton.
-- ============================================================================

return {
    idle          = "Idle",
    walk          = "Walk",
    run           = "Run",
    jump          = "Jump",
    double_jump   = "jump_2",
    fall          = "Falling",
    land          = "Land",
    roll          = "Roll",
    dash          = "Roll",
    air_dash      = "Roll",
    air_dash_right= "Roll",
    slide         = "Skid",
    wall_cling    = "Wall_Idle",
    wall_slide    = "Wall_Idle",
    climb_up      = "Climb_Up",
    climb_down    = "Climb_Down",
    climb_idle    = "Climb_Idle",
    climb         = "Climb_Idle",   -- Safety net for third-party callers.
    grapple       = "Falling",
    swim_idle     = "Swim_Idle",
    swim_move     = "Swim",
    crouch_idle   = "Crouch_Idle",
    crouch_walk   = "Crouch_Walk",
    push          = "push",
    pushpull_idle_state = "Push_Idle",
    pull          = "Pull",
    pull_idle     = "Pull_Idle",
    hang          = "Edge_Idle",
    ledge_grab_climb = "Edge_Climb",
    death         = "Death",
    hurt          = "Hit1",
    punch         = "Punch_1",
    punch_jab     = "punch2",
    punch_cross   = "punch3",
    weapon_attack = "Melee_Swing1",
    sword_attack  = "Melee_Swing2",
    sword_stab    = "Melee_Swing3",
    attack        = "Punch_1",
    attack_alt    = "Melee_Swing2",
    air_spin      = "Melee_Swing3",
    shoot         = "Gun_Shoot",
    running_shooting = "Gun_Shoot",
    parry         = "Block",
    parry_success = "Block_Hit",
    celebrate     = "Celebration",
    taunt         = "Idle_Tired",
}
