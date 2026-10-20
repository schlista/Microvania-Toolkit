-- developer/config/boss_animations.lua
-- ============================================================================
-- Boss Animation Contract
-- ============================================================================
-- The boss runtime uses internal semantic keys like:
--   walk, hurt, parry, summon, phase_transition
--
-- New bosses use ONE standard generic contract.
--
-- Author these clips on the rig:
--   idle
--   move
--   hit
--   defend
--   boss phase transition clip (configured in the table below)
--   death
--   attack_1
--   attack_2
--   attack_3
--   attack_4
--   attack_5
--
-- Slot guidance:
--   attack_1 = primary / light / melee
--   attack_2 = ranged / mobile / dash
--   attack_3 = heavy / beam / impact
--   attack_4 = utility / summon / heal / grab
--   attack_5 = special / finisher / taunt / victory
--   boss phase transition slot = transition / teleport-style clips
--
-- Spawn intro stays optional. If you want one, set the boss object's
-- `intro_animation` property explicitly.
--
-- `defend` is the only public defensive slot. Internal keys like `block`,
-- `parry`, `shield_up`, and `counter` collapse onto it when the generic
-- contract is active.
--
-- Toolkit rule:
--   Tiled-authored bosses always use this generic contract. There are no
--   animation-set variants or compatibility modes.
-- ============================================================================

return {
    idle     = "idle",
    move     = "move",
    hit      = "hit",
    defend   = "defend",
    phase    = "phase",
    death    = "death",
    attack_1 = "attack_1",
    attack_2 = "attack_2",
    attack_3 = "attack_3",
    attack_4 = "attack_4",
    attack_5 = "attack_5",
}
