-- mvtk/bosses/arena_mechanics.lua
-- ============================================================================
-- DEPRECATED WRAPPER
-- ============================================================================
-- This module used to own a parallel arena-state store (active_arenas,
-- arena_hazards, destructible_objects). That state has been merged into
-- `mvtk.bosses.boss_arena`, which is now the single source of truth for
-- arena lock state, active phase, hazards, and boundaries.
--
-- This wrapper forwards every call to BossArena so existing call sites keep
-- working during the Phase 1 transition. New code should require
-- `mvtk.bosses.boss_arena` directly.
--
-- Functions that had no BossArena equivalent (add_destructible,
-- damage_destructible, phase_transition, remove_arena) remain here as
-- no-op stubs until Phase 4 replaces them with object-driven hazards.
-- ============================================================================

local BossArena = require "mvtk.bosses.boss_arena"

local M = {}

--- Initialize arena mechanics system (no-op; BossArena initializes lazily).
function M.init() end

function M.register_arena(arena_id, config)
    return BossArena.register_arena(arena_id, config)
end

function M.lock_arena(arena_id)
    BossArena.lock_arena(arena_id)
end

function M.unlock_arena(arena_id)
    BossArena.unlock_arena(arena_id)
end

function M.activate_phase_hazards(arena_id, phase)
    -- BossArena.activate_phase_hazards operates on the active arena; ensure
    -- the named arena is active before delegating.
    local active = BossArena.get_active_arena and BossArena.get_active_arena()
    if not active or active.id ~= arena_id then
        BossArena.lock_arena(arena_id)
    end
    BossArena.activate_phase_hazards(phase)
end

function M.spawn_hazard(arena_id, hazard_config)
    local hazard_id = hazard_config and hazard_config.id or hazard_config and hazard_config.type
    if hazard_id then
        BossArena.spawn_hazard(hazard_id, hazard_config)
    end
end

function M.trigger_arena_effect(arena_id, effect_type, params)
    BossArena.trigger_arena_effect(arena_id, effect_type, params)
end

function M.phase_transition(arena_id, from_phase, to_phase, transition_config)
    BossArena.transition_to_phase(to_phase, transition_config and transition_config.transition_time)
end

function M.update(arena_id, dt)
    BossArena.update(dt)
end

function M.get_arena(arena_id)
    return BossArena.get_arena(arena_id)
end

function M.remove_arena(arena_id)
    local active = BossArena.get_active_arena and BossArena.get_active_arena()
    if active and active.id == arena_id then
        BossArena.deactivate_arena()
    end
end

-- Destructibles are not (currently) owned by BossArena. No live call site
-- exercises these, but retained as no-ops for safety. Phase 4 will replace
-- this pathway with object-driven Tiled hazards.
function M.add_destructible() return nil end
function M.damage_destructible() return false end

return M
